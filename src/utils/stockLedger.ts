import { Route, type DoseEvent } from '../../logic';
import { packUnitMG, stockQuantity, type Pack, type StockCurrency, type StockPurchase, type Supply } from './regimen';

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
        const key = stockGroup(s);
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
        const key = stockGroup(e);
        const lots = (groups.get(key) ?? []).filter(
            s => s.startedAt / HOUR <= e.timeH && (s.archivedAt === undefined || s.archivedAt / HOUR >= e.timeH),
        );
        const choices = new Map<string, Supply>();
        for (const s of lots) {
            const spec = stockSpec(s.pack);
            if (remaining.get(s.id)! > 0 && !choices.has(spec)) choices.set(spec, s);
        }
        const anchor = e.inventorySupplyId ? byID.get(e.inventorySupplyId) : undefined;
        const selected = e.inventorySupplyId
            ? anchor && stockGroup(anchor) === key
                ? anchor
                : undefined
            : choices.size === 1
              ? choices.values().next().value
              : undefined;
        if (selected && !choices.has(stockSpec(selected.pack))) choices.set(stockSpec(selected.pack), selected);
        const needsSpecification = !selected && choices.size > 0;
        let needed = stockQuantity(e);
        const parts: StockAllocation[] = [];
        if (selected) {
            const spec = stockSpec(selected.pack);
            for (const s of lots) {
                if (stockSpec(s.pack) !== spec) continue;
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
