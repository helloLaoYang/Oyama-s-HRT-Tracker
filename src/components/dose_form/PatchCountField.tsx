import CustomSelect from '../CustomSelect';
import { useTranslation } from '../../contexts/LanguageContext';

export default function PatchCountField({ count, onChange }: { count: number; onChange: (n: number) => void }) {
    const { t } = useTranslation();
    const counts = Array.from({ length: 10 }, (_, i) => i + 1);
    if (count > 10) counts.push(count);
    return (
        <CustomSelect
            label={t('plan.patchCount')}
            value={String(count)}
            onChange={n => onChange(Number(n))}
            options={counts.map(n => ({ value: String(n), label: String(n) }))}
        />
    );
}
