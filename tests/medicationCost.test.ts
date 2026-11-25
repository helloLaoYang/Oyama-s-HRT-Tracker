import { describe, expect, it } from 'vitest';
import { costStart, stockLedger, stockTotals } from '../src/utils/stockLedger';
import { Route, Ester } from '../logic';
import type { Supply } from '../src/utils/regimen';
import { parsePurchase, priceDraft } from '../src/components/StockPurchaseFields';

describe('medication cost', () => {
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
