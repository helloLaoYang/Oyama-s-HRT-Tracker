import { Route, type DoseEvent } from '../../logic';
import {
    canSupply,
    packUnitMG,
    stockQuantity,
    supplyStatus,
    type Pack,
    type Regimen,
    type StockCurrency,
    type StockPurchase,
    type Supply,
} from './regimen';

const HOUR = 3_600_000;
export const stockGroup = (s: Pick<Supply, 'route' | 'ester'>) => s.route + '|' + s.ester;
export function stockSpec(pack: Pack): string {
    switch (pack.kind) {
        case 'vial':
            return [pack.kind, pack.ml, pack.mgPerMl].join('|');
        case 'pill':
        case 'pump':
        case 'sachet':
            return pack.kind + '|' + pack.mg;
        case 'patch':
            return 'patch|' + (pack.releaseRateUGPerDay ?? '');
        case 'bulk':
            return pack.kind;
    }
}

export const currencyScale = (currency: StockCurrency) => (currency === 'JPY' ? 1 : 100);

export const specificationKey = (s: Supply) => stockGroup(s) + '|' + stockSpec(s.pack);
type StockSelection = Pick<DoseEvent, 'route' | 'ester' | 'inventorySupplyId'> & { extras?: DoseEvent['extras'] };

export function recordedStrength(dose: StockSelection) {
    const extras = dose.extras ?? {};
    if (dose.route === Route.patchApply && (extras.releaseRateUGPerDay ?? 0) > 0) {
        return extras.releaseRateUGPerDay! / stockQuantity({ route: dose.route, doseMG: 0, extras });
    }
    if (dose.route === Route.injection && (extras.concentrationMGmL ?? 0) > 0) return extras.concentrationMGmL;
}

export function matchesStrength(s: Supply, dose: StockSelection) {
    const used = recordedStrength(dose);
    const strength =
        s.pack.kind === 'patch' ? s.pack.releaseRateUGPerDay : s.pack.kind === 'vial' ? s.pack.mgPerMl : undefined;
    if (used === undefined || strength === undefined) return undefined;
    return Math.abs(used - strength) <= Math.max(used, strength) * 1e-9;
}

function automaticStock(choices: Supply[], dose: StockSelection) {
    const sameRoute = choices.filter(s => s.route === dose.route && matchesStrength(s, dose) !== false);
    const exact = sameRoute.filter(s => matchesStrength(s, dose) === true);
    const candidates = exact.length ? exact : sameRoute;
    return candidates.length === 1 ? candidates[0] : undefined;
}

export function stockSpecifications(supplies: Supply[]) {
    const byID = new Map(supplies.map(s => [s.id, s]));
    const bySpec = new Map<string, Supply>();
    for (const s of supplies) {
        if (s.archivedAt === undefined && !bySpec.has(specificationKey(s))) bySpec.set(specificationKey(s), s);
    }
    const active = [...bySpec.values()];
    const matching = (item: StockSelection) =>
        active.filter(s => canSupply(s, item) && matchesStrength(s, item) !== false);
    const selected = (item: StockSelection) => {
        if (item.inventorySupplyId) {
            const lot = byID.get(item.inventorySupplyId);
            return lot && canSupply(lot, item) && matchesStrength(lot, item) !== false ? lot : undefined;
        }
        return automaticStock(matching(item), item);
    };
    return { active, matching, selected };
}

export function stockForecast(supplies: Supply[], remaining: Map<string, number>, regimens: Regimen[], nowH: number) {
    const specs = stockSpecifications(supplies);
    const groups = new Map<string, { supply: Supply; regimens: Regimen[]; remaining: number }>();
    for (const regimen of regimens) {
        const supply = specs.selected(regimen);
        if (!supply) continue;
        const key = specificationKey(supply);
        const group = groups.get(key) ?? { supply, regimens: [], remaining: 0 };
        group.regimens.push(regimen);
        groups.set(key, group);
    }
    const lots = supplies.map(s => {
        const group = groups.get(specificationKey(s));
        const balance = remaining.get(s.id) ?? 0;
        if (group && s.archivedAt === undefined) group.remaining += balance;
        return supplyStatus(s, balance, group?.regimens ?? [], nowH);
    });
    const combined = [...groups.values()].map(g => supplyStatus(g.supply, g.remaining, g.regimens, nowH));
    return { lots, combined };
}
export const stockUnitPrice = (purchase?: StockPurchase) =>
    purchase?.totalMinor == null
        ? undefined
        : purchase.totalMinor / currencyScale(purchase.currency) / purchase.unitsPerPack / purchase.packCount;

export interface StockAllocation {
    supply: Supply;
    units: number;
    cost?: number;
}
export interface StockUse {
    event: DoseEvent;
    choices: Supply[];
    selected?: Supply;
    needsSpecification: boolean;
    missingStock: boolean;
    parts: StockAllocation[];
}

export function stockLedger(supplies: Supply[], events: DoseEvent[], nowH: number) {
    const ordered = [...supplies].sort((a, b) => a.startedAt - b.startedAt || compareID(a.id, b.id));
    const byID = new Map(ordered.map(s => [s.id, s]));
    const groups = new Map<string, Supply[]>();
    for (const s of ordered) {
        const key = s.ester;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key)!.push(s);
    }
    const remaining = new Map(ordered.map(s => [s.id, s.count * packUnitMG(s.pack)]));
    const counts = ordered
        .flatMap(s =>
            (s.recounts ?? []).map(c => ({ timeH: c.at / HOUR, id: s.id, amount: c.count * packUnitMG(s.pack) })),
        )
        .sort((a, b) => a.timeH - b.timeH);
    let cursor = 0;
    function applyCounts(timeH: number, inclusive: boolean) {
        while (cursor < counts.length) {
            const c = counts[cursor];
            if (c.timeH > timeH || (!inclusive && c.timeH === timeH)) break;
            remaining.set(c.id, c.amount);
            cursor++;
        }
    }
    const uses: StockUse[] = [];
    for (const e of events
        .filter(e => e.route !== Route.patchRemove && e.timeH <= nowH && stockQuantity(e) > 0)
        .sort((a, b) => a.timeH - b.timeH || compareID(a.id, b.id))) {
        applyCounts(e.timeH, false);
        const lots = (groups.get(e.ester) ?? []).filter(
            s =>
                canSupply(s, e) &&
                s.startedAt / HOUR <= e.timeH &&
                (s.archivedAt === undefined || s.archivedAt / HOUR >= e.timeH),
        );
        const choices = new Map<string, Supply>();
        for (const s of lots) {
            const spec = specificationKey(s);
            if (remaining.get(s.id)! > 0 && matchesStrength(s, e) !== false && !choices.has(spec)) choices.set(spec, s);
        }
        const anchor = e.inventorySupplyId ? byID.get(e.inventorySupplyId) : undefined;
        const selected = e.inventorySupplyId
            ? anchor && canSupply(anchor, e) && matchesStrength(anchor, e) !== false
                ? anchor
                : undefined
            : automaticStock([...choices.values()], e);
        if (selected && !choices.has(specificationKey(selected))) choices.set(specificationKey(selected), selected);
        const needsSpecification = !selected && choices.size > 0;
        let needed = stockQuantity(e);
        const parts: StockAllocation[] = [];
        if (selected) {
            const spec = specificationKey(selected);
            for (const s of lots) {
                if (specificationKey(s) !== spec) continue;
                const left = remaining.get(s.id)!;
                const take = Math.min(needed, left);
                if (take <= 0) continue;
                const units = take / packUnitMG(s.pack);
                const price = stockUnitPrice(s.purchase);
                parts.push({ supply: s, units, cost: price === undefined ? undefined : units * price });
                const rest = left - take;
                remaining.set(s.id, rest <= left * Number.EPSILON * 4 ? 0 : rest);
                needed -= take;
                if (needed <= 0) break;
            }
        }
        uses.push({
            event: e,
            choices: [...choices.values()],
            selected,
            needsSpecification,
            missingStock: !needsSpecification && needed > stockQuantity(e) * 1e-12,
            parts,
        });
    }
    applyCounts(nowH, true);
    return { remaining, uses };
}

function compareID(a: string, b: string) {
    return a < b ? -1 : a > b ? 1 : 0;
}

export function previewStockUse(event: DoseEvent, supplies: Supply[], events: DoseEvent[]) {
    const lots = supplies.filter(s => s.ester === event.ester);
    if (!lots.length || event.route === Route.patchRemove) return undefined;
    const history = events.filter(e => e.id !== event.id && e.ester === event.ester);
    return stockLedger(lots, [...history, event], event.timeH).uses.find(u => u.event.id === event.id);
}

export function stockTotals(parts: StockAllocation[]) {
    const result = new Map<StockCurrency, number>();
    for (const p of parts) {
        if (p.cost !== undefined && p.supply.purchase) {
            const c = p.supply.purchase.currency;
            result.set(c, (result.get(c) ?? 0) + p.cost);
        }
    }
    return result;
}

export const stockUseComplete = (u: StockUse) =>
    !u.missingStock && !u.needsSpecification && u.parts.every(p => p.cost !== undefined);

export type CostRange = 'today' | 'last7' | 'last30' | 'all';
export function costStart(range: CostRange, nowH: number): number {
    if (range === 'all') return -Infinity;
    const start = new Date(nowH * HOUR);
    start.setHours(0, 0, 0, 0);
    start.setDate(start.getDate() - (range === 'last7' ? 6 : range === 'last30' ? 29 : 0));
    return start.getTime() / HOUR;
}
