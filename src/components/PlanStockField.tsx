import { useState } from 'react';
import { v4 as uuidv4 } from 'uuid';
import { Route, type DoseEvent } from '../../logic';
import type { Supply } from '../utils/regimen';
import { draftToItem, planEvent, type PlanDraft } from '../utils/plan';
import { packUnit } from '../utils/regimenText';
import { previewStockUse, specificationKey, stockSpecifications, stockTotals } from '../utils/stockLedger';
import { useTranslation } from '../contexts/LanguageContext';
import CustomSelect from './CustomSelect';
import PatchCountField from './dose_form/PatchCountField';
import { stockChoiceLabel, stockMoney } from './StockPurchaseFields';

export default function PlanStockField({
    draft,
    supplies,
    events,
    onChange,
}: {
    draft: PlanDraft;
    supplies: Supply[];
    events: DoseEvent[];
    onChange: (patch: Partial<PlanDraft>) => void;
}) {
    const { t } = useTranslation();
    const [preview] = useState(() => ({ id: uuidv4(), at: Date.now() }));
    const specs = stockSpecifications(supplies);
    const item = draftToItem(draft, preview.id);
    const selected = specs.selected(item ?? draft);
    const choices = specs
        .matching(item ?? draft)
        .filter(s => !selected || specificationKey(s) !== specificationKey(selected));
    if (selected) choices.push(selected);
    if (!choices.length && draft.route !== Route.patchApply) return null;
    const use =
        item &&
        selected &&
        previewStockUse(planEvent({ ...item, inventorySupplyId: selected.id }, item.id, preview.at), supplies, events);
    return (
        <div className="space-y-2">
            {draft.route === Route.patchApply && (
                <PatchCountField count={draft.patchCount ?? 1} onChange={patchCount => onChange({ patchCount })} />
            )}
            {choices.length > 0 && (
                <CustomSelect
                    label={t('plan.stockSpec')}
                    value={selected?.id ?? ''}
                    onChange={id => {
                        if (id) onChange({ inventorySupplyId: id });
                    }}
                    options={[
                        ...(!selected ? [{ value: '', label: t('cost.choose') }] : []),
                        ...choices.map(s => ({ value: s.id, label: stockChoiceLabel(s, draft.route, t) })),
                    ]}
                />
            )}
            {use && selected && (
                <p className="text-sm text-muted">
                    {Number(use.parts.reduce((sum, p) => sum + p.units, 0).toFixed(6))} {packUnit(selected.pack, t)}
                    {[...stockTotals(use.parts)].map(([c, n]) => ' · ' + stockMoney(n, c) + ' ' + c).join('')}
                    {use.parts.some(p => p.cost === undefined) && ' · ' + t('cost.needsPrice')}
                    {use.missingStock && ' · ' + t('cost.missingStock')}
                </p>
            )}
        </div>
    );
}
