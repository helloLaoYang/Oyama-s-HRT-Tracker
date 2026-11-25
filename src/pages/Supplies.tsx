import React, { useMemo, useState } from 'react';
import { v4 as uuidv4 } from 'uuid';
import { ChevronDown, ChevronRight } from '../components/icons';
import { DoseEvent, Ester, Route } from '../../logic';
import { AddCancelLabel } from '../components/StableLabel';
import PageHeader, { PAGE_COLUMN, headerAction, headerActionAccent } from '../components/PageHeader';
import CustomSelect from '../components/CustomSelect';
import Segmented from '../components/Segmented';
import { settingsSection } from '../components/SettingsListItem';
import { useTranslation } from '../contexts/LanguageContext';
import { appLocale } from '../i18n/locale';
import { useHRTMode } from '../contexts/HRTModeContext';
import { useDialog } from '../contexts/DialogContext';
import {
    Regimen,
    Supply,
    Pack,
    PackKind,
    type SupplyStatus,
    packKindsFor,
    defaultPack,
    packUnitMG,
} from '../utils/regimen';
import {
    supplyLabel,
    intervalLabel,
    dueLabel,
    fill,
    fillNodes,
    remainingLabel,
    packUnit,
    patchStrengthLabel,
} from '../utils/regimenText';
import { PLAN_DRUGS, usualFor } from '../utils/plan';
import { inertWhen } from '../utils/inert';
import {
    currencyScale,
    groupStockPurchases,
    recordedStrength,
    specificationKey,
    stockForecast,
    stockGroup,
    stockLedger,
    stockPurchaseDateLimit,
    stockSpec,
    stockSpecifications,
    stockUnitPrice,
} from '../utils/stockLedger';
import {
    parsePurchase,
    priceDraft,
    specLabel,
    stockMoney,
    StockPurchaseFields,
    type StockTarget,
} from '../components/StockPurchaseFields';

const on = 'text-[var(--text)]';
const muted = 'text-[var(--text-muted)]';
// Fields as the selects beside them have them (CustomSelect): the label in
// body colour at medium weight, flush with the box, and the box .input-base,
// 44px and field-filled with a terracotta focus. A label of its own style
// and a 38px transparent box made the paired fields look unrelated.
const inputCls = 'input-base tabular-nums';
const labelCls = `block text-xs font-medium mb-1.5 ${on}`;
// The same pair the lab form closes with.
const cancelBtn = 'min-w-[88px] px-4 py-2 text-sm text-[var(--text-muted)] hover:bg-[var(--surface-hover)] rounded-md';
const confirmBtn = 'btn-primary min-w-[88px]';

const LEAD_DAYS = [7, 14, 30] as const;

interface SuppliesProps {
    target?: StockTarget;
    onBack: () => void;
    supplies: Supply[];
    onSave: (s: Supply, forDoseId?: string) => void;
    onDelete: (id: string) => void;
    events: DoseEvent[];
    regimens: Regimen[];
    nowH: number;
    leadDays: number;
    onLeadDaysChange: (d: number) => void;
}

/**
 * A box of medicine with an ampoule beside it and a blister strip lying in
 * front, for the empty list. Drawn in the same hand as DoseDoodle (see there
 * for the rules): one line colour, one flat wash, paths a little off true,
 * outlines that overshoot where they close. The ampoule is Doodle's, stood
 * upright and brought up to this size, its line kept at this drawing's weight.
 */
const StockDoodle: React.FC<{ className?: string }> = ({ className = '' }) => (
    <svg
        viewBox="0 0 96 72"
        aria-hidden="true"
        focusable="false"
        fill="none"
        stroke="currentColor"
        strokeWidth={2.4}
        strokeLinecap="round"
        strokeLinejoin="round"
        className={`text-[var(--illustration-line)] ${className}`}
    >
        {/* The box's label, laid in just inside the line. */}
        <path
            className="fill-[var(--illustration-wash)]"
            stroke="none"
            d="M12.6 33 C 18 32.4, 26 33.4, 34.4 32.6 C 34.2 36.4, 34.6 40.4, 34.4 44 C 26 44.6, 18 43.8, 12.5 44.4 C 12.8 40.4, 12.4 36.4, 12.6 33 Z"
        />
        {/* Box: front, lid, side */}
        <path d="M12.4 16.4 C 18 15.8, 26 16.8, 34.2 16 C 34.8 32, 33.8 50, 34.6 66.8 C 26 67.4, 18 66.6, 12.2 67.2 C 11.6 50, 12.6 32, 12 15.6" />
        <path d="M12.4 16.4 C 14.2 14.2, 16 11.8, 17.8 9.8 C 24 9.4, 32 10, 40.2 9.4 C 38.4 11.8, 36.2 13.8, 34.2 16" />
        <path d="M40.2 9.4 C 40.6 25, 39.8 44, 40.4 60.2 C 38.6 62.6, 36.6 64.8, 34.6 66.8" />
        {/* The label's edges and the cross on it */}
        <path d="M12.6 33 C 18 32.4, 26 33.4, 34.4 32.6" strokeWidth={1.8} />
        <path d="M12.5 44.4 C 18 43.8, 26 44.6, 34.4 44" strokeWidth={1.8} />
        <path d="M20.6 38.7 C 22.4 38.5, 24.4 38.7, 26.2 38.5" strokeWidth={1.8} />
        <path d="M23.4 35.8 C 23.2 37.6, 23.6 39.6, 23.4 41.4" strokeWidth={1.8} />

        {/* An ampoule, standing */}
        <g transform="translate(52.6 67.6) scale(1.45) translate(-20 -34.4)" strokeWidth={1.65}>
            <path
                className="fill-[var(--illustration-wash)]"
                stroke="none"
                d="M14.8 23.8 C 18 23.4, 22 24, 25.2 23.6 C 25 26, 25.4 28.6, 25.2 30.4 C 25 32.4, 22.8 33.2, 20 33 C 17.2 33.2, 15 32.4, 14.8 30.4 C 14.6 28.6, 15 26, 14.8 23.8 Z"
            />
            <path d="M17.2 9.6 C 16.4 7.2, 17.6 5.8, 20 5.8 C 22.4 5.8, 23.6 7.2, 22.8 9.6 C 23 11.4, 22.6 13.2, 22.8 15 C 25.2 16.2, 26.6 18, 26.6 20.2 C 26.4 24, 26.8 28, 26.4 30.4 C 26.2 33.2, 23.6 34.4, 20 34.2 C 16.4 34.4, 13.8 33.2, 13.6 30.4 C 13.2 28, 13.6 24, 13.4 20.2 C 13.4 18, 14.8 16.2, 17.2 15 C 17.4 13.2, 17 11.4, 17.1 9.2" />
            <path d="M16.4 13 C 18 12.6, 21.2 13.2, 23.6 12.8" strokeWidth={1.25} />
            <path d="M14.4 24 C 18 23.4, 22 24.2, 25.6 23.6" strokeWidth={1.25} />
            <path d="M16.6 26.4 C 16.4 27.8, 16.8 29.4, 17.1 30.8" strokeWidth={1.25} />
        </g>

        {/* A blister strip lying in front: two tablets left, and the foil
            torn where the third was pressed out */}
        <g transform="translate(1.4 0) rotate(-5 76.6 60)">
            <path d="M63.6 54.6 C 70 54, 80 54.8, 89.4 54.2 C 90 57.4, 89.6 61.4, 89.8 65 C 80 65.6, 70 64.8, 63.4 65.4 C 63 62, 63.8 58.4, 63.4 53.8" />
            <path
                className="fill-[var(--illustration-wash)]"
                strokeWidth={1.6}
                d="M69 57 C 70.9 57, 72 58.1, 71.9 59.9 C 72 61.7, 70.8 62.9, 69 62.8 C 67.2 62.9, 66.1 61.7, 66.1 59.9 C 66.1 58.1, 67.2 57, 69.2 57.1"
            />
            <path
                className="fill-[var(--illustration-wash)]"
                strokeWidth={1.6}
                d="M76.4 57 C 78.3 57, 79.4 58.1, 79.3 59.9 C 79.4 61.7, 78.2 62.9, 76.4 62.8 C 74.6 62.9, 73.5 61.7, 73.5 59.9 C 73.5 58.1, 74.6 57, 76.6 57.1"
            />
            <path
                strokeWidth={1.6}
                d="M83.8 57 C 85.7 57, 86.8 58.1, 86.7 59.9 C 86.8 61.7, 85.6 62.9, 83.8 62.8 C 82 62.9, 80.9 61.7, 80.9 59.9 C 80.9 58.1, 82 57, 84 57.1"
            />
            <path strokeWidth={1.4} d="M82 59.4 L 83.1 60.6 L 84.3 59.3 L 85.5 60.5" />
        </g>

        {/* The ground they stand on */}
        <path d="M10 68.4 C 24 66.8, 38 69.6, 52 67.8 S 74 68.6, 88 67.2" strokeWidth={1.8} />
    </svg>
);

const num = (v: string) => {
    const n = parseFloat(v);
    return Number.isFinite(n) ? n : NaN;
};
const trim = (n: number) => String(Number(n.toFixed(2)));
const quantityFormat = (n: number) => new Intl.NumberFormat(appLocale(), { maximumFractionDigits: 6 }).format(n);
const purchaseDateTime = (ms: number) =>
    new Intl.DateTimeFormat(appLocale(), { dateStyle: 'medium', timeStyle: 'short' }).format(ms);

/**
 * What's left, as remainingLabel puts it, except that an opened vial with no
 * whole one behind it is just what is in it ("5 mg"): "0 vials and 5 mg"
 * read as if nothing were left.
 */
const leftLabel = (s: Supply, remaining: number, t: (k: string) => string) =>
    s.pack.kind === 'vial' && remaining >= 0.05 && remaining / packUnitMG(s.pack) + 1e-9 < 1
        ? `${Number(remaining.toFixed(1))} mg`
        : remainingLabel(s, remaining, t);

/** What one unit of the pack holds. A vial needs two numbers, a pill one, a patch or plain mg none. */
const PackFields: React.FC<{ pack: Pack; onChange: (p: Pack) => void; t: (k: string) => string }> = ({
    pack,
    onChange,
    t,
}) => {
    const field = (label: string, value: number, set: (n: number) => void, className = '') => (
        <label className={`block ${className}`}>
            <span className={labelCls}>{label}</span>
            <input
                type="number"
                inputMode="decimal"
                min="0"
                step="any"
                value={value}
                onChange={e => set(num(e.target.value))}
                className={inputCls}
                style={{ fontSize: '16px' }}
            />
        </label>
    );
    if (pack.kind === 'vial')
        return (
            <>
                {field(t('supplies.vial_ml'), pack.ml, ml => onChange({ ...pack, ml }))}
                {field(t('supplies.mg_per_ml'), pack.mgPerMl, mgPerMl => onChange({ ...pack, mgPerMl }))}
            </>
        );
    if (pack.kind === 'pill' || pack.kind === 'pump' || pack.kind === 'sachet') {
        // English units are plural for counts ("24 pills"); the label wants one.
        return field(
            fill(t('supplies.mg_each'), { unit: packUnit(pack, t).replace(/s$/, '') }),
            pack.mg,
            mg => onChange({ ...pack, mg }),
            'col-span-2',
        );
    }
    if (pack.kind === 'patch')
        return (
            <label className="col-span-2 block">
                <span className={labelCls}>{patchStrengthLabel(t)}</span>
                <input
                    type="number"
                    inputMode="decimal"
                    min="0"
                    step="any"
                    className={inputCls}
                    value={pack.releaseRateUGPerDay ?? ''}
                    onChange={e =>
                        onChange(
                            e.target.value === ''
                                ? { kind: 'patch' }
                                : { kind: 'patch', releaseRateUGPerDay: Number(e.target.value) },
                        )
                    }
                />
            </label>
        );
    return null;
};

function localDateTime(ms: number) {
    const date = new Date(ms);
    return new Date(ms - date.getTimezoneOffset() * 60_000).toISOString().slice(0, 19);
}

const Supplies: React.FC<SuppliesProps> = ({
    target,
    onBack,
    supplies,
    onSave,
    onDelete,
    events,
    regimens,
    nowH,
    leadDays,
    onLeadDaysChange,
}) => {
    const { t, lang } = useTranslation();
    const { mode } = useHRTMode();
    const { showDialog } = useDialog();
    const targetDose = target && 'dose' in target ? target.dose : undefined;
    const targetId = target && 'priceId' in target ? target.priceId : undefined;
    const targetSupply = supplies.find(s => s.id === targetId);
    const anchor = targetDose?.inventorySupplyId ? stockSpecifications(supplies).selected(targetDose) : undefined;

    // Whatever is in use now first, then everything else that can be logged.
    const options = useMemo(() => {
        const seen = new Set<string>();
        const out: { value: string; label: string; description?: string }[] = [];
        const add = (route: Route, ester: Ester, description?: string) => {
            const value = `${route}|${ester}`;
            if (seen.has(value)) return;
            seen.add(value);
            out.push({ value, label: supplyLabel({ route, ester }, t), description });
        };
        regimens.forEach(r => add(r.route, r.ester, intervalLabel(r.intervalH, t)));
        supplies.forEach(s => add(s.route, s.ester));
        if (targetDose) add(targetDose.route, targetDose.ester);
        for (const route of Object.keys(PLAN_DRUGS[mode]) as Route[]) {
            for (const ester of PLAN_DRUGS[mode][route] ?? []) add(route, ester);
        }
        return out;
    }, [regimens, mode, t, targetDose, supplies]);

    // A pack as it starts out for this drug. A tablet holds the planned dose
    // of it when there is one, else its usual dose: defaultPack's 2 mg is an
    // estradiol tablet, and taken as a cyproterone one it counted a fraction
    // of the stock, so the run-out warning came days early.
    const packFor = (kind: PackKind, route: Route, ester: Ester): Pack => {
        const p = defaultPack(kind);
        if (p.kind !== 'pill') return p;
        const planned = regimens.find(r => r.route === route && r.ester === ester)?.doseMG ?? 0;
        const mg = planned > 0 ? planned : parseFloat(usualFor(route, ester).dose);
        return mg > 0 ? { kind: 'pill', mg } : p;
    };

    const [adding, setAdding] = useState(!!targetDose);
    const [group, setGroup] = useState(() => (targetSupply ? stockGroup(targetSupply) : null));
    const [showArchived, setShowArchived] = useState(targetSupply?.archivedAt !== undefined);
    const [pick, setPick] = useState(() =>
        targetDose ? (anchor?.route ?? targetDose.route) + '|' + targetDose.ester : (options[0]?.value ?? ''),
    );
    const [pickRoute, pickEster] = pick.split('|') as [Route, Ester];
    const [pack, setPack] = useState<Pack>(() => {
        if (anchor) return anchor.pack;
        const strength = targetDose && recordedStrength(targetDose);
        const pack = packFor(packKindsFor(pickRoute)[0], pickRoute, pickEster);
        if (strength && pack.kind === 'patch') return { ...pack, releaseRateUGPerDay: strength };
        if (strength && pack.kind === 'vial') return { ...pack, mgPerMl: strength };
        return pack;
    });
    const [count, setCount] = useState('');
    const defaultCurrency = [...supplies].reverse().find(s => s.purchase)?.purchase?.currency ?? 'CNY';
    const [newPrice, setNewPrice] = useState(() => priceDraft(undefined, defaultCurrency));
    const [started, setStarted] = useState(() => localDateTime((targetDose?.timeH ?? nowH) * 3_600_000));
    const [pickedSpec, setPickedSpec] = useState(anchor ? stockSpec(anchor.pack) : '');
    const [openId, setOpenId] = useState<string | null>(targetId ?? null);
    const [editMode, setEditMode] = useState<'price' | 'count'>(targetId ? 'price' : 'count');
    const [editPrice, setEditPrice] = useState(() => priceDraft(targetSupply?.purchase, defaultCurrency));
    const [editStarted, setEditStarted] = useState(() => (targetSupply ? localDateTime(targetSupply.startedAt) : ''));
    const [patchRate, setPatchRate] = useState('');
    const [recount, setRecount] = useState('');
    const [recountMg, setRecountMg] = useState('');

    // A tablet's strength belongs to the drug, so choosing another drug
    // starts it again; a vial's size and concentration are kept.
    const choose = (value: string) => {
        setPick(value);
        setPickedSpec('');
        const [route, ester] = value.split('|') as [Route, Ester];
        if (!packKindsFor(route).includes(pack.kind)) setPack(packFor(packKindsFor(route)[0], route, ester));
        else if (pack.kind === 'pill') setPack(packFor('pill', route, ester));
    };
    const packValid = (p: Pack) =>
        (p.kind !== 'patch' || p.releaseRateUGPerDay === undefined || p.releaseRateUGPerDay > 0) &&
        (p.kind !== 'vial' || (p.ml > 0 && p.mgPerMl > 0)) &&
        Number.isFinite(packUnitMG(p)) &&
        packUnitMG(p) > 0;
    const countNum = num(count);
    const bought = parsePurchase(newPrice, countNum);
    const startMs = new Date(started).getTime();
    const canAdd =
        !!pick &&
        countNum > 0 &&
        Number.isFinite(countNum * packUnitMG(pack)) &&
        packValid(pack) &&
        !!bought &&
        startMs > 0 &&
        startMs <= nowH * 3_600_000;
    const add = () => {
        if (!canAdd) return;
        onSave(
            {
                id: uuidv4(),
                route: pickRoute,
                ester: pickEster,
                pack,
                count: countNum,
                startedAt: startMs,
                purchase: bought,
            },
            targetDose?.id,
        );
        setCount('');
        setNewPrice(priceDraft(undefined, newPrice.currency));
        setStarted(localDateTime(nowH * 3_600_000));
        setGroup(pick);
        setAdding(false);
    };

    const ledger = useMemo(() => stockLedger(supplies, events, nowH), [supplies, events, nowH]);
    const { groups, summary } = useMemo(() => {
        const forecast = stockForecast(supplies, ledger.remaining, regimens, nowH);
        return {
            groups: groupStockPurchases(forecast.lots),
            summary: new Map(forecast.combined.map(status => [specificationKey(status.supply), status])),
        };
    }, [supplies, ledger.remaining, regimens, nowH]);
    const current = group ? groups.get(group) : undefined;
    const knownPacks = [
        ...new Map(
            supplies.filter(s => s.route === pickRoute && s.ester === pickEster).map(s => [stockSpec(s.pack), s.pack]),
        ).values(),
    ];
    const packOptions = packKindsFor(pickRoute).map(k => ({ value: k, label: t(`supplies.pack.${k}`) }));

    const toggleAdd = () => {
        if (!adding) {
            setCount('');
            setStarted(localDateTime(nowH * 3_600_000));
            setNewPrice(priceDraft(undefined, defaultCurrency));
            setOpenId(null);
            const candidate = current && (current.active[0] ?? current.archived[0]);
            if (candidate) {
                setPick(stockGroup(candidate.supply));
                setPack(candidate.supply.pack);
                setPickedSpec(stockSpec(candidate.supply.pack));
            }
        }
        setAdding(!adding);
    };

    const openGroup = (key: string | null) => {
        setGroup(key);
        setAdding(false);
        setOpenId(null);
        setShowArchived(false);
    };

    const openRow = (s: Supply, remaining: number) => {
        if (openId === s.id) {
            setOpenId(null);
            return;
        }
        setOpenId(s.id);
        setEditMode('price');
        setEditPrice(priceDraft(s.purchase, defaultCurrency));
        setEditStarted(localDateTime(s.startedAt));
        setPatchRate('');
        const unit = packUnitMG(s.pack);
        if (s.pack.kind === 'vial') {
            const whole = Math.floor(remaining / unit + 1e-9);
            setRecount(String(whole));
            setRecountMg(trim(remaining - whole * unit));
        } else {
            setRecount(trim(remaining / unit));
            setRecountMg('');
        }
    };
    const applyRecount = (s: Supply) => {
        const whole = num(recount);
        if (!(whole >= 0)) return;
        const extra = s.pack.kind === 'vial' ? (num(recountMg) || 0) / packUnitMG(s.pack) : 0;
        if (extra < 0 || !Number.isFinite(whole + extra)) return;
        const at = Date.now();
        onSave({ ...s, recounts: [...(s.recounts ?? []).filter(c => c.at !== at), { at, count: whole + extra }] });
        setOpenId(null);
    };

    const renderLot = ({ supply, remaining }: SupplyStatus) => {
        const open = openId === supply.id;
        const archived = supply.archivedAt !== undefined;
        const price = stockUnitPrice(supply.purchase);
        const purchased = supply.purchase ? supply.purchase.unitsPerPack * supply.purchase.packCount : supply.count;
        const edited = parsePurchase(editPrice, supply.count);
        const purchaseEntered =
            !!supply.purchase ||
            editPrice.units !== '' ||
            editPrice.packs !== '1' ||
            editPrice.total !== '' ||
            editPrice.currency !== defaultCurrency;
        const maxDate = stockPurchaseDateLimit(supply, nowH * 3_600_000);
        const editedDate =
            editStarted === localDateTime(supply.startedAt) ? supply.startedAt : new Date(editStarted).getTime();
        const canSave =
            !!edited &&
            editedDate > 0 &&
            (editedDate === supply.startedAt || editedDate <= maxDate) &&
            (patchRate === '' || Number(patchRate) > 0);
        return (
            <div key={supply.id}>
                <button
                    type="button"
                    onClick={() => openRow(supply, remaining)}
                    aria-expanded={open}
                    className="flex min-h-11 w-full items-center gap-3 py-3 text-start"
                >
                    <div className="min-w-0 flex-1">
                        <p className={`text-sm font-medium ${on}`}>{specLabel(supply.pack, t)}</p>
                        <p className={`mt-0.5 text-xs ${muted}`}>{purchaseDateTime(supply.startedAt)}</p>
                        <p className={`mt-0.5 text-xs ${muted}`}>
                            {fill(t(supply.purchase ? 'supplies.purchasedQuantity' : 'supplies.openingQuantity'), {
                                quantity: quantityFormat(purchased) + ' ' + packUnit(supply.pack, t),
                            })}
                            {' · '}
                            {supply.purchase?.totalMinor != null
                                ? stockMoney(
                                      supply.purchase.totalMinor / currencyScale(supply.purchase.currency),
                                      supply.purchase.currency,
                                  )
                                : t('cost.needsPrice')}
                        </p>
                    </div>
                    <span className={`shrink-0 text-end text-sm tabular-nums ${on}`}>
                        {!archived && fill(t('supplies.left'), { n: leftLabel(supply, remaining, t) })}
                        {price !== undefined && (
                            <span className={`block text-xs ${muted}`}>
                                {stockMoney(price, supply.purchase!.currency, true)}/{packUnit(supply.pack, t)}
                            </span>
                        )}
                    </span>
                    <ChevronDown size={16} className={`chev ${muted} shrink-0 ${open ? 'rotate-180' : ''}`} />
                </button>
                <div className="disclosure" data-open={open} {...inertWhen(!open)}>
                    <div className="disclosure-inner">
                        {open && (
                            <div className="space-y-3 pb-3">
                                {!archived && (
                                    <Segmented
                                        value={editMode}
                                        onChange={setEditMode}
                                        options={[
                                            { id: 'price', label: t('cost.purchase') },
                                            { id: 'count', label: t('cost.recount') },
                                        ]}
                                    />
                                )}
                                {editMode === 'price' ? (
                                    <>
                                        <label className="block">
                                            <span className={labelCls}>{t('cost.starts')}</span>
                                            <input
                                                className={inputCls}
                                                type="datetime-local"
                                                step="1"
                                                max={localDateTime(maxDate)}
                                                value={editStarted}
                                                onChange={e => setEditStarted(e.target.value)}
                                            />
                                        </label>
                                        <p className={`text-xs ${muted}`}>{t('supplies.stockStartsHint')}</p>
                                        {supply.pack.kind === 'patch' && !supply.pack.releaseRateUGPerDay && (
                                            <label className="block">
                                                <span className={labelCls}>{patchStrengthLabel(t)}</span>
                                                <input
                                                    type="number"
                                                    step="any"
                                                    min="0"
                                                    className={inputCls}
                                                    value={patchRate}
                                                    onChange={e => setPatchRate(e.target.value)}
                                                />
                                            </label>
                                        )}
                                        <StockPurchaseFields
                                            pack={supply.pack}
                                            basis={supply.count}
                                            draft={editPrice}
                                            onChange={setEditPrice}
                                        />
                                        <div className="flex justify-end">
                                            <button
                                                type="button"
                                                className={confirmBtn}
                                                disabled={!canSave}
                                                onClick={() => {
                                                    if (!canSave) return;
                                                    const pack =
                                                        supply.pack.kind === 'patch' && patchRate
                                                            ? { ...supply.pack, releaseRateUGPerDay: Number(patchRate) }
                                                            : supply.pack;
                                                    onSave({
                                                        ...supply,
                                                        pack,
                                                        purchase: purchaseEntered ? edited : undefined,
                                                        startedAt: editedDate,
                                                    });
                                                    setOpenId(null);
                                                }}
                                            >
                                                {t('btn.save')}
                                            </button>
                                        </div>
                                    </>
                                ) : (
                                    <>
                                        <p className={`text-xs ${muted}`}>{t('supplies.left_now')}</p>
                                        <div className="flex flex-wrap items-end gap-3">
                                            <label className="block">
                                                <span className={labelCls}>{packUnit(supply.pack, t)}</span>
                                                <input
                                                    type="number"
                                                    inputMode="decimal"
                                                    min="0"
                                                    step="any"
                                                    value={recount}
                                                    onChange={e => setRecount(e.target.value)}
                                                    className={inputCls}
                                                    style={{ fontSize: '16px', width: '6rem' }}
                                                />
                                            </label>
                                            {supply.pack.kind === 'vial' && (
                                                <label className="block">
                                                    <span className={labelCls}>{t('supplies.opened_mg')}</span>
                                                    <input
                                                        type="number"
                                                        inputMode="decimal"
                                                        min="0"
                                                        step="any"
                                                        value={recountMg}
                                                        onChange={e => setRecountMg(e.target.value)}
                                                        className={inputCls}
                                                        style={{ fontSize: '16px', width: '6rem' }}
                                                    />
                                                </label>
                                            )}
                                        </div>
                                        <div className="flex items-center justify-end gap-1">
                                            <button
                                                type="button"
                                                onClick={() =>
                                                    showDialog(
                                                        'confirm',
                                                        t('cost.removeConfirm'),
                                                        () => {
                                                            onDelete(supply.id);
                                                            setOpenId(null);
                                                        },
                                                        {
                                                            danger: true,
                                                            title: supplyLabel(supply, t),
                                                            confirmLabel: t('cost.remove'),
                                                        },
                                                    )
                                                }
                                                className={`${headerAction} text-[var(--danger)]`}
                                            >
                                                {t('cost.remove')}
                                            </button>
                                            <button
                                                type="button"
                                                disabled={!(num(recount) >= 0)}
                                                onClick={() => applyRecount(supply)}
                                                className={`${headerActionAccent} disabled:opacity-40`}
                                            >
                                                {t('btn.save')}
                                            </button>
                                        </div>
                                    </>
                                )}
                            </div>
                        )}
                    </div>
                </div>
            </div>
        );
    };

    return (
        <div className="relative md:pb-32">
            <PageHeader
                onBack={current && !target ? () => openGroup(null) : onBack}
                title={current ? supplyLabel(current.supply, t) : t('supplies.title')}
                actions={
                    <button type="button" onClick={toggleAdd} className={headerActionAccent}>
                        <AddCancelLabel
                            open={adding}
                            add={t(current ? 'supplies.addPurchase' : 'supplies.add')}
                            cancel={t('btn.cancel')}
                        />
                    </button>
                }
            />

            <div className="disclosure" data-open={adding} {...inertWhen(!adding)}>
                <div className="disclosure-inner">
                    <div className={`${PAGE_COLUMN} mt-3 mb-6`}>
                        <div className="grid grid-cols-2 gap-3">
                            {!current && (
                                <div className="col-span-2">
                                    <CustomSelect
                                        label={t('supplies.drug')}
                                        value={pick}
                                        onChange={choose}
                                        options={options}
                                    />
                                </div>
                            )}
                            {knownPacks.length > 0 && (
                                <div className="col-span-2">
                                    <CustomSelect
                                        label={t('cost.reuse')}
                                        value={pickedSpec}
                                        options={[
                                            { value: '', label: t('cost.custom') },
                                            ...knownPacks.map(p => ({ value: stockSpec(p), label: specLabel(p, t) })),
                                        ]}
                                        onChange={v => {
                                            setPickedSpec(v);
                                            const next = knownPacks.find(p => stockSpec(p) === v);
                                            setPack(next ?? packFor(pack.kind, pickRoute, pickEster));
                                        }}
                                    />
                                </div>
                            )}
                            {!pickedSpec && (
                                <>
                                    <CustomSelect
                                        label={t('supplies.pack')}
                                        value={pack.kind}
                                        onChange={k => setPack(packFor(k as PackKind, pickRoute, pickEster))}
                                        options={packOptions}
                                    />
                                    <PackFields pack={pack} onChange={setPack} t={t} />
                                </>
                            )}
                            <label className="col-span-2 block">
                                <span className={labelCls}>
                                    {t('supplies.openingStock')} ({packUnit(pack, t)})
                                </span>
                                <input
                                    type="number"
                                    inputMode="decimal"
                                    min="0"
                                    step="any"
                                    value={count}
                                    onChange={e => setCount(e.target.value)}
                                    onKeyDown={e => {
                                        if (e.key === 'Enter') add();
                                    }}
                                    className={inputCls}
                                    style={{ fontSize: '16px' }}
                                />
                            </label>
                        </div>
                        <label className="my-3 block">
                            <span className={labelCls}>{t('cost.starts')}</span>
                            <input
                                className={inputCls}
                                type="datetime-local"
                                step="1"
                                value={started}
                                max={localDateTime(nowH * 3_600_000)}
                                onChange={e => setStarted(e.target.value)}
                            />
                        </label>
                        <p className={`mb-3 text-xs ${muted}`}>{t('supplies.stockStartsHint')}</p>
                        <StockPurchaseFields pack={pack} basis={countNum} draft={newPrice} onChange={setNewPrice} />
                        <div className="mt-4 flex justify-end gap-2">
                            <button type="button" onClick={() => setAdding(false)} className={cancelBtn}>
                                {t('btn.cancel')}
                            </button>
                            <button type="button" onClick={add} disabled={!canAdd} className={confirmBtn}>
                                {t('supplies.confirm_add')}
                            </button>
                        </div>
                    </div>
                </div>
            </div>

            <div className={`${PAGE_COLUMN} mt-3 space-y-8`}>
                {current ? (
                    <>
                        <section className="space-y-2">
                            <h2 className={`text-xs font-medium ${muted}`}>{t('supplies.bySpecification')}</h2>
                            {current.balances.length ? (
                                current.balances.map(status => {
                                    const { supply, remaining } = status;
                                    const key = specificationKey(supply);
                                    const runOutH = summary.get(key)?.runOutH ?? null;
                                    const low = runOutH !== null && (remaining <= 0 || runOutH - nowH < leadDays * 24);
                                    return (
                                        <div key={key} className="flex items-start justify-between gap-3 text-sm">
                                            <div>
                                                <p>{specLabel(supply.pack, t)}</p>
                                                <p className={`text-xs ${low ? 'text-[var(--warning)]' : muted}`}>
                                                    {runOutH === null
                                                        ? t('supplies.not_in_use')
                                                        : fillNodes(t('supplies.runs_out'), {
                                                              n: Math.max(0, Math.round((runOutH - nowH) / 24)),
                                                              date: (
                                                                  <span className="whitespace-nowrap">
                                                                      {dueLabel(runOutH, lang, false, nowH)}
                                                                  </span>
                                                              ),
                                                          })}
                                                </p>
                                            </div>
                                            <span className="shrink-0 tabular-nums">
                                                {fill(t('supplies.left'), { n: leftLabel(supply, remaining, t) })}
                                            </span>
                                        </div>
                                    );
                                })
                            ) : (
                                <p className={`text-sm ${muted}`}>{t('supplies.noActivePurchases')}</p>
                            )}
                        </section>
                        {current.active.length > 0 && (
                            <section className="space-y-2">
                                <h2 className={`text-xs font-medium ${muted}`}>
                                    {fill(t('supplies.purchaseCount'), { n: current.active.length })}
                                </h2>
                                <div className={settingsSection}>{current.active.map(renderLot)}</div>
                            </section>
                        )}
                        {current.archived.length > 0 && (
                            <section>
                                <button
                                    type="button"
                                    onClick={() => setShowArchived(!showArchived)}
                                    aria-expanded={showArchived}
                                    className="flex min-h-11 w-full items-center justify-between gap-3 text-start text-sm"
                                >
                                    {fill(t('supplies.archivedPurchases'), { n: current.archived.length })}
                                    <ChevronDown
                                        size={16}
                                        className={`chev ${muted} ${showArchived ? 'rotate-180' : ''}`}
                                    />
                                </button>
                                <div className="disclosure" data-open={showArchived} {...inertWhen(!showArchived)}>
                                    <div className="disclosure-inner">
                                        <div className={settingsSection}>
                                            {showArchived && current.archived.map(renderLot)}
                                        </div>
                                    </div>
                                </div>
                            </section>
                        )}
                    </>
                ) : (
                    <>
                        {groups.size === 0 ? (
                            <div className={`flex flex-col items-center py-16 text-center ${muted}`}>
                                <StockDoodle className="w-24 h-auto mb-6" />
                                <p className="text-sm">{t('supplies.empty_list')}</p>
                                <p className="mt-1 max-w-xs text-xs text-balance">{t('supplies.empty_hint')}</p>
                            </div>
                        ) : (
                            <div className={settingsSection}>
                                {[...groups].map(([key, purchases]) => (
                                    <button
                                        key={key}
                                        type="button"
                                        onClick={() => openGroup(key)}
                                        className="flex min-h-11 w-full items-center gap-3 py-3 text-start"
                                    >
                                        <div className="min-w-0 flex-1">
                                            <p className={`text-sm font-medium ${on}`}>
                                                {supplyLabel(purchases.supply, t)}
                                            </p>
                                            <p className={`mt-0.5 text-xs ${muted}`}>
                                                {fill(t('supplies.purchaseCount'), {
                                                    n: purchases.active.length + purchases.archived.length,
                                                })}
                                            </p>
                                            {purchases.balances.map(({ supply, remaining }) => (
                                                <p key={specificationKey(supply)} className={`text-xs ${muted}`}>
                                                    {specLabel(supply.pack, t)} ·{' '}
                                                    {fill(t('supplies.left'), { n: leftLabel(supply, remaining, t) })}
                                                </p>
                                            ))}
                                        </div>
                                        <ChevronRight size={16} className={`shrink-0 ${muted}`} />
                                    </button>
                                ))}
                            </div>
                        )}
                        <section className="flex items-center justify-between gap-4">
                            <p className={`text-sm ${on}`}>{t('supplies.lead')}</p>
                            <Segmented
                                options={LEAD_DAYS.map(d => ({
                                    id: String(d),
                                    label: fill(t('supplies.days'), { n: d }),
                                }))}
                                value={String(
                                    LEAD_DAYS.includes(leadDays as (typeof LEAD_DAYS)[number]) ? leadDays : 14,
                                )}
                                onChange={v => onLeadDaysChange(Number(v))}
                            />
                        </section>
                    </>
                )}
            </div>
        </div>
    );
};

export default Supplies;
