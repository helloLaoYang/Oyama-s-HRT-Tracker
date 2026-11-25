import { describe, expect, it } from 'vitest';
import {
    costStart,
    stockForecast,
    stockLedger,
    stockSpecifications,
    stockTotals,
    stockUnitPrice,
} from '../src/utils/stockLedger';
import { draftToItem, itemToDraft, normalizePlanItem, planEvent, regimensFromPlan } from '../src/utils/plan';
import { Route, Ester } from '../logic';
import { specLabel, stockMoney } from '../src/components/StockPurchaseFields';
import { regimenLabel, patchStrengthLabel } from '../src/utils/regimenText';
import { TRANSLATIONS } from '../src/i18n/translations';
import type { Supply } from '../src/utils/regimen';
import { parsePurchase, priceDraft } from '../src/components/StockPurchaseFields';

describe('medication cost', () => {
    it('displays unit prices to two decimal places and calculates from the full purchase price', () => {
        const price = stockUnitPrice({ currency: 'CNY', unitsPerPack: 8, packCount: 1, totalMinor: 1001 })!;
        expect(stockMoney(price, 'CNY', true)).toMatch(/1[.,]25(?:\D|$)/);
        expect(stockMoney(2, 'JPY', true)).toMatch(/2[.,]00(?:\D|$)/);
        expect(stockMoney(price * 8, 'CNY')).toMatch(/10[.,]01(?:\D|$)/);
    });
    it('matches two 50 µg/day patches by per-patch release, even with a 100 µg/day box on the shelf', () => {
        const lot = (rate: number): Supply => ({
            id: 'patch-' + rate,
            route: Route.patchApply,
            ester: Ester.E2,
            pack: { kind: 'patch', releaseRateUGPerDay: rate },
            count: 10,
            startedAt: 0,
            purchase: { unitsPerPack: 10, packCount: 1, totalMinor: 8000, currency: 'CNY' },
        });
        const stock = [lot(100), lot(50)];
        const plan = {
            id: 'p',
            route: Route.patchApply,
            ester: Ester.E2,
            doseMG: 0,
            everyDays: 2,
            timesPerDay: 1,
            extras: { releaseRateUGPerDay: 100, patchCount: 2 },
        };
        const event = planEvent(plan, 'change', 3_600_000);
        const { uses, remaining } = stockLedger(stock, [event], 2);
        expect(uses[0].parts.map(p => [p.supply.id, p.units, p.cost])).toEqual([['patch-50', 2, 16]]);
        expect([...remaining.values()]).toEqual([10, 8]);
        expect(stockLedger([lot(100)], [event], 2).uses[0].missingStock).toBe(true);
        expect(stockSpecifications(stock).selected(plan)?.id).toBe('patch-50');
        for (const [locale, messages] of Object.entries(TRANSLATIONS)) {
            const dictionary: Record<string, string> = messages;
            const t = (key: string) => dictionary[key] ?? key;
            const unit = t('dose.guide.unit.ug_day');
            if (locale === 'zh') expect(unit).toBe('µg/天');
            if (locale === 'en') expect(unit).toBe('µg/day');
            expect(specLabel(stock[1].pack, t)).toBe('50 ' + unit);
            expect(regimenLabel(plan, t)).toContain('50 ' + unit + ' × 2');
            expect(patchStrengthLabel(t)).toContain(unit);
        }
        expect(itemToDraft(plan)).toMatchObject({ dose: '50', patchCount: 2 });
    });
    it('can explicitly use oral tablet stock for a sublingual dose while preserving the recorded route', () => {
        const supply: Supply = {
            id: 'oral',
            route: Route.oral,
            ester: Ester.EV,
            count: 8,
            startedAt: 0,
            pack: { kind: 'pill', mg: 2 },
            purchase: { unitsPerPack: 8, packCount: 1, totalMinor: 1600, currency: 'CNY' },
        };
        const event = { id: 'e', route: Route.sublingual, ester: Ester.EV, doseMG: 1, timeH: 1, extras: {} };
        expect(stockLedger([supply], [event], 2).uses[0].needsSpecification).toBe(true);
        const used = stockLedger([supply], [{ ...event, inventorySupplyId: supply.id }], 2);
        expect(used.uses[0].event.route).toBe(Route.sublingual);
        expect(used.uses[0].parts[0].cost).toBe(1);
        expect(used.remaining.get(supply.id)).toBe(15);
    });
    it('links a plan to a strength, forecasts its stock, and charges only recorded doses', () => {
        const base = { route: Route.oral, ester: Ester.E2, startedAt: 1 };
        const lots: Supply[] = [
            { ...base, id: 'one', count: 28, pack: { kind: 'pill', mg: 1 } },
            {
                ...base,
                id: 'two',
                count: 2,
                pack: { kind: 'pill', mg: 2 },
                purchase: { currency: 'CNY', unitsPerPack: 28, packCount: 1, totalMinor: 5600 },
            },
        ];
        const plan = { ...base, id: 'plan', doseMG: 1, extras: {}, everyDays: 1, timesPerDay: 1 };
        expect(stockSpecifications(lots).selected(plan)).toBeUndefined();
        const draft = { ...itemToDraft(plan), inventorySupplyId: 'two' };
        const linked = normalizePlanItem(draftToItem(draft, plan.id))!;
        expect(linked.inventorySupplyId).toBe('two');
        const event = planEvent(linked, 'record', 2 * 3_600_000);
        expect(event.inventorySupplyId).toBe('two');
        const regimens = regimensFromPlan([linked], [], 2);
        const before = stockLedger(lots, [], 2);
        const forecast = stockForecast(lots, before.remaining, regimens, 2);
        expect(forecast.combined.map(s => [s.supply.id, s.remaining, s.dailyUse])).toEqual([['two', 4, 1]]);
        expect(forecast.lots[0].dailyUse).toBeNull();
        const after = stockLedger(lots, [event], 2);
        expect(after.uses[0].parts.map(p => [p.supply.id, p.units, p.cost])).toEqual([['two', 0.5, 1]]);
        expect(after.remaining.get('one')).toBe(28);
        expect(after.remaining.get('two')).toBe(3);
        const refill = { ...lots[1], id: 'refill', startedAt: 2 };
        const restocked = stockLedger([lots[0], { ...lots[1], archivedAt: 1 }, refill], [event], 2);
        expect(restocked.uses[0].parts[0].supply.id).toBe('refill');
        expect(before.uses).toEqual([]);
    });
    it('keeps patch count, total release rate and wear time when only the stock selection changes', () => {
        const patch = {
            id: 'p',
            route: Route.patchApply,
            ester: Ester.E2,
            doseMG: 0,
            extras: { patchCount: 2, releaseRateUGPerDay: 100, patchWearH: 72 },
            everyDays: 2,
            timesPerDay: 1,
        };
        expect(draftToItem({ ...itemToDraft(patch), inventorySupplyId: 'patches' }, patch.id)).toEqual({
            ...patch,
            inventorySupplyId: 'patches',
        });
    });
    it('distinguishes an unknown price, a free lot and an unrepresentable fraction', () => {
        const draft = priceDraft();
        expect(parsePurchase(draft, 28)?.totalMinor).toBeUndefined();
        expect(parsePurchase({ ...draft, total: '0' }, 28)?.totalMinor).toBe(0);
        expect(parsePurchase({ ...draft, total: '56.00' }, 28)?.totalMinor).toBe(5600);
        expect(parsePurchase({ ...draft, total: '0.000000001' }, 28)).toBeUndefined();
        expect(parsePurchase({ ...draft, currency: 'JPY', total: '0.5' }, 28)).toBeUndefined();
    });
    it('uses inclusive local calendar days for today, seven days, thirty days and all records', () => {
        const now = new Date(2026, 2, 10, 12).getTime() / 3_600_000;
        expect(costStart('today', now)).toEqual(new Date(2026, 2, 10).getTime() / 3_600_000);
        expect(costStart('last7', now)).toEqual(new Date(2026, 2, 4).getTime() / 3_600_000);
        expect(costStart('last30', now)).toEqual(new Date(2026, 1, 9).getTime() / 3_600_000);
        expect(costStart('all', now)).toBe(-Infinity);
    });
    it('prices a partial vial and leaves the excess unmatched', () => {
        const vial: Supply = {
            id: 'v',
            route: Route.injection,
            ester: Ester.EV,
            startedAt: 1,
            count: 0.1,
            pack: { kind: 'vial', ml: 5, mgPerMl: 20 },
            purchase: { unitsPerPack: 2, packCount: 1, currency: 'USD', totalMinor: 5000 },
        };
        const dose = { id: 'd', timeH: 10, route: Route.injection, ester: Ester.EV, doseMG: 15, extras: {} };
        const ledger = stockLedger([vial], [dose], 11);
        expect(ledger.uses[0].missingStock).toBe(true);
        expect(stockTotals(ledger.uses[0].parts).get('USD')).toBe(2.5);
        expect(ledger.remaining.get('v')).toBe(0);
        const orphan = stockLedger([vial], [{ ...dose, inventorySupplyId: 'not-in-this-backup' }], 11);
        expect(orphan.uses[0].needsSpecification).toBe(true);
        expect(orphan.uses[0].parts).toHaveLength(0);
    });
});
