import React, { useState } from 'react';
import { type DoseEvent } from '../../logic';
import { useTranslation } from '../contexts/LanguageContext';
import { appLocale } from '../i18n/locale';
import { fill, packUnit, supplyLabel } from '../utils/regimenText';
import {
    costStart,
    stockGroup,
    stockSpec,
    stockTotals,
    stockUseComplete,
    type CostRange,
    type StockUse,
    type StockAllocation,
} from '../utils/stockLedger';
import { packUnitMG, stockQuantity, type Supply } from '../utils/regimen';
import { specLabel, stockMoney, type StockTarget } from './StockPurchaseFields';
import Segmented from './Segmented';
import CustomSelect from './CustomSelect';
import { ChevronDown, ChevronRight } from './icons';

const periods: CostRange[] = ['today', 'last7', 'last30', 'all'];
const day = (timeH: number) =>
    new Date(timeH * 3_600_000).toLocaleDateString(appLocale(), { month: 'short', day: 'numeric' });
const link = 'inline-flex min-h-11 items-center gap-1 text-sm text-[var(--accent-ink)]';

export default function MedicationCost({
    uses,
    nowH,
    openStock,
    assignDose,
    range,
    setRange,
}: {
    uses: StockUse[];
    nowH: number;
    openStock: (target?: StockTarget) => void;
    assignDose: (e: DoseEvent) => void;
    range: CostRange;
    setRange: (range: CostRange) => void;
}) {
    const { t } = useTranslation();
    const [choosing, setChoosing] = useState<string>();
    const [expanded, setExpanded] = useState(false);
    const start = costStart(range, nowH);
    const rows = uses.filter(u => u.event.timeH >= start);
    const complete = rows.filter(stockUseComplete).length;
    const parts = rows.flatMap(u => u.parts);
    const totals = stockTotals(parts);
    const prices = new Map<string, Supply>();
    const pending = new Map<string, StockUse>();
    const groups = new Map<string, StockAllocation[]>();
    for (const part of parts) {
        if (part.cost === undefined) prices.set(part.supply.id, part.supply);
        const key = stockGroup(part.supply) + '|' + stockSpec(part.supply.pack);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key)!.push(part);
    }
    for (const row of rows) {
        if (!row.needsSpecification && !row.missingStock) continue;
        const key = stockGroup(row.event) + (row.needsSpecification ? '|spec' : '|stock');
        if (!pending.has(key)) pending.set(key, row);
    }
    const caption = range === 'all' ? t('cost.all') : range === 'today' ? day(nowH) : day(start) + ' – ' + day(nowH);
    const task = (key: string, title: string, note: string, action: string, click: () => void) => (
        <button
            key={key}
            type="button"
            onClick={click}
            className="flex min-h-12 w-full items-center justify-between gap-3 py-2 text-start"
        >
            <span className="min-w-0">
                <span className="block font-medium">{title}</span>
                <span className="block text-sm text-[var(--text-muted)]">{note}</span>
            </span>
            <span className={link + ' shrink-0'}>
                {action}
                <ChevronRight size={15} />
            </span>
        </button>
    );
    return (
        <section className="mt-5 border-t border-[var(--border)] pt-4 text-[var(--text)]" aria-label={t('cost.title')}>
            <div className="flex flex-wrap items-center justify-between gap-2">
                <h2 className="text-base font-semibold">{t('cost.title')}</h2>
                <Segmented
                    options={periods.map(id => ({ id, label: t('cost.' + id) }))}
                    value={range}
                    onChange={setRange}
                    aria-label={t('cost.title')}
                />
            </div>
            <div className="my-3" aria-live="polite">
                <p className="text-sm text-[var(--text-muted)]">
                    {t(complete < rows.length ? 'cost.subtotal' : 'cost.estimate')}
                </p>
                {totals.size ? (
                    [...totals].map(([currency, amount]) => (
                        <div key={currency} className="flex flex-wrap items-baseline gap-2">
                            <span className="text-4xl font-light tabular-nums">{stockMoney(amount, currency)}</span>
                            <span className="text-sm text-[var(--text-muted)]">{currency}</span>
                        </div>
                    ))
                ) : (
                    <p>{t(rows.length ? 'cost.pending' : 'cost.empty')}</p>
                )}
                <p className="mt-1 text-sm text-[var(--text-muted)]">
                    {caption}
                    {rows.length ? ' · ' + fill(t('cost.coverage'), { n: complete, total: rows.length }) : ''}
                </p>
            </div>
            {[...prices.values()].map(s =>
                task(
                    'price-' + s.id,
                    t('cost.needsPrice'),
                    supplyLabel(s, t) + ' · ' + specLabel(s.pack, t),
                    t('cost.addPrice'),
                    () => openStock({ priceId: s.id }),
                ),
            )}
            {[...pending.values()].map(u => (
                <React.Fragment key={u.event.id}>
                    {task(
                        u.event.id,
                        t(u.needsSpecification ? 'cost.needsSpec' : 'cost.missingStock'),
                        day(u.event.timeH) + ' · ' + supplyLabel(u.event, t),
                        t(u.needsSpecification ? 'cost.choose' : 'supplies.add'),
                        () =>
                            u.needsSpecification
                                ? setChoosing(choosing === u.event.id ? undefined : u.event.id)
                                : openStock({ dose: u.event }),
                    )}
                    {choosing === u.event.id && u.needsSpecification && (
                        <CustomSelect
                            label={t('cost.spec')}
                            value=""
                            onChange={id => {
                                if (id) assignDose({ ...u.event, inventorySupplyId: id });
                                setChoosing(undefined);
                            }}
                            options={[
                                { value: '', label: t('cost.later') },
                                ...u.choices.map(s => ({
                                    value: s.id,
                                    label: specLabel(s.pack, t),
                                    description:
                                        Number((stockQuantity(u.event) / packUnitMG(s.pack)).toFixed(6)) +
                                        ' ' +
                                        packUnit(s.pack, t),
                                })),
                            ]}
                        />
                    )}
                </React.Fragment>
            ))}
            <button
                type="button"
                className={link + ' mt-2 w-full justify-between'}
                aria-expanded={expanded}
                onClick={() => setExpanded(!expanded)}
            >
                {t('cost.details')}
                <ChevronDown size={16} className={expanded ? 'rotate-180' : ''} />
            </button>
            {expanded &&
                (groups.size ? (
                    [...groups].map(([key, items]) => {
                        const s = items[0].supply;
                        return (
                            <div key={key} className="flex items-center justify-between gap-3 py-2 text-sm">
                                <div>
                                    {supplyLabel(s, t)}
                                    <p className="text-[var(--text-muted)]">
                                        {specLabel(s.pack, t)} ·{' '}
                                        {Number(items.reduce((n, p) => n + p.units, 0).toFixed(6))}{' '}
                                        {packUnit(s.pack, t)}
                                    </p>
                                </div>
                                <div className="text-end tabular-nums">
                                    {[...stockTotals(items)].map(([c, n]) => (
                                        <p key={c}>
                                            {stockMoney(n, c)} {c}
                                        </p>
                                    ))}
                                    {items.some(p => p.cost === undefined) && t('cost.needsPrice')}
                                </div>
                            </div>
                        );
                    })
                ) : (
                    <p className="text-sm text-[var(--text-muted)]">{t('cost.noMatch')}</p>
                ))}
            <button type="button" className={link + ' w-full justify-between'} onClick={() => openStock()}>
                {t('supplies.title')}
                <ChevronRight size={15} />
            </button>
        </section>
    );
}
