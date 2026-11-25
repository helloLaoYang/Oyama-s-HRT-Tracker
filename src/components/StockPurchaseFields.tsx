import React from 'react';
import type { DoseEvent, Route } from '../../logic';
import { appLocale } from '../i18n/locale';
import { useTranslation } from '../contexts/LanguageContext';
import { STOCK_CURRENCIES, type Pack, type StockCurrency, type StockPurchase, type Supply } from '../utils/regimen';
import { currencyScale, stockUnitPrice } from '../utils/stockLedger';
import { packUnit } from '../utils/regimenText';
import CustomSelect from './CustomSelect';

export function stockMoney(amount: number, currency: StockCurrency, unit = false) {
    return new Intl.NumberFormat(appLocale(), {
        style: 'currency',
        currency,
        ...(unit ? { maximumFractionDigits: 6 } : {}),
    }).format(amount);
}

export function specLabel(pack: Pack, t: (key: string) => string) {
    if (pack.kind === 'vial') return pack.mgPerMl + ' mg/mL, ' + pack.ml + ' mL';
    if (pack.kind === 'patch')
        return pack.releaseRateUGPerDay
            ? pack.releaseRateUGPerDay + ' ' + t('dose.guide.unit.ug_day')
            : t('supplies.pack.patch');
    if (pack.kind === 'bulk') return t('supplies.pack.bulk');
    return pack.mg + ' mg/' + packUnit(pack, t);
}

export const purchaseUnit = (pack: Pack, t: (key: string) => string) =>
    t(pack.kind === 'pump' ? 'cost.bottle' : pack.kind === 'bulk' ? 'cost.pack' : 'cost.box');

export const stockChoiceLabel = (s: Supply, route: Route, t: (key: string) => string) =>
    specLabel(s.pack, t) + (s.route === route ? '' : ' · ' + t('regimen.route.' + s.route));

export type StockTarget = { priceId: string } | { dose: DoseEvent };

export function priceDraft(p?: StockPurchase, defaultCurrency: StockCurrency = 'CNY') {
    return {
        units: p ? String(p.unitsPerPack) : '',
        packs: String(p?.packCount ?? 1),
        total: p?.totalMinor == null ? '' : String(p.totalMinor / currencyScale(p.currency)),
        currency: p?.currency ?? defaultCurrency,
    };
}
type PriceDraft = ReturnType<typeof priceDraft>;

export function parsePurchase(draft: PriceDraft, basis: number): StockPurchase | undefined {
    const unitsPerPack = draft.units === '' ? Math.max(1, basis || 1) : Number(draft.units);
    const packCount = Number(draft.packs);
    const units = unitsPerPack * packCount;
    if (!(unitsPerPack > 0 && packCount > 0 && units > 0 && Number.isFinite(units))) return undefined;
    const result: StockPurchase = { unitsPerPack, packCount, currency: draft.currency };
    if (draft.total !== '') {
        if (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(draft.total)) return undefined;
        const [whole, fraction = ''] = draft.total.split('.');
        const digits = currencyScale(draft.currency) === 1 ? 0 : 2;
        if (/[1-9]/.test(fraction.slice(digits))) return undefined;
        const minor = Number((whole || '0') + fraction.padEnd(digits, '0').slice(0, digits));
        if (!Number.isSafeInteger(minor)) return undefined;
        result.totalMinor = minor;
    }
    return result;
}

export function StockPurchaseFields({
    draft,
    onChange,
    pack,
    basis,
}: {
    draft: PriceDraft;
    onChange: (d: PriceDraft) => void;
    pack: Pack;
    basis: number;
}) {
    const { t } = useTranslation();
    const price = stockUnitPrice(parsePurchase(draft, basis));
    const numeric = (name: 'units' | 'packs' | 'total', label: string, placeholder?: string) => (
        <label className="block text-sm">
            <span className="mb-1 block">{label}</span>
            <input
                className="input-base tabular-nums"
                type="number"
                min="0"
                step="any"
                inputMode="decimal"
                value={draft[name]}
                placeholder={placeholder}
                onChange={e => onChange({ ...draft, [name]: e.target.value })}
            />
        </label>
    );
    return (
        <div className="grid gap-3 sm:grid-cols-2">
            {numeric('units', t('cost.units') + ' (' + packUnit(pack, t) + ')', String(Math.max(1, basis || 1)))}
            {numeric('packs', t('cost.packs') + ' (' + purchaseUnit(pack, t) + ')')}
            {numeric('total', t('cost.totalPaid'), '—')}
            <CustomSelect
                label={t('cost.currency')}
                value={draft.currency}
                options={STOCK_CURRENCIES.map(c => ({ value: c, label: c }))}
                onChange={v => {
                    const currency = STOCK_CURRENCIES.find(c => c === v);
                    if (currency) onChange({ ...draft, currency });
                }}
            />
            {price !== undefined && (
                <p className="text-sm tabular-nums text-[var(--text-muted)] sm:col-span-2">
                    {t('cost.unitPrice')} {stockMoney(price, draft.currency, true)}/{packUnit(pack, t)}
                </p>
            )}
        </div>
    );
}
