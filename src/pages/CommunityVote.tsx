import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import PageHeader, { PAGE_COLUMN } from '../components/PageHeader';
import { Check, Copy, Lock } from '../components/icons';
import { useTranslation } from '../contexts/LanguageContext';
import { Lang } from '../i18n/translations';
import { apiEndpoint, apiErrorFrom } from '../services/apiClient';
import { fill } from '../utils/regimenText';
import { donationService, type DonationConfig } from '../services/donation';
import {
    ADDITIONAL_CURRENCIES,
    ADDITIONAL_CURRENCY_MAJORITY,
    ALWAYS_SUPPORTED_CURRENCY,
    MIN_MAINTAINER_SHARE,
    resolveVoteOutcome,
    SPLIT_OPTIONS,
    type AdditionalCurrencyId,
    type VotePublic,
    type VoteTally,
} from '../../communityVote';

const REFRESH_INTERVAL_MS = 30_000;

const LOCALE: Record<Lang, string> = {
    zh: 'zh-CN',
    'zh-TW': 'zh-TW',
    yue: 'zh-HK',
    en: 'en',
    ja: 'ja',
    ko: 'ko',
    tr: 'tr',
    ru: 'ru',
    uk: 'uk',
};

const formatDateTime = (seconds: number, lang: Lang) =>
    new Date(seconds * 1000).toLocaleString(LOCALE[lang], {
        year: 'numeric',
        month: 'short',
        day: 'numeric',
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23',
        timeZone: 'UTC',
    });

const splitText = (option: (typeof SPLIT_OPTIONS)[number], t: (key: string) => string): string =>
    fill(t('vote.split.option'), {
        fantuan: option.fantuanmtf,
        smirnova: option.smirnovaoyama,
        project: option.project,
        project_label: t('vote.project'),
    });

const currencyLabel = (id: AdditionalCurrencyId | typeof ALWAYS_SUPPORTED_CURRENCY, t: (key: string) => string) => {
    if (id === 'monero') return t('vote.currency.monero');
    if (id === 'bitcoin') return t('vote.currency.bitcoin');
    if (id === 'ethereum') return t('vote.currency.ethereum');
    return t('vote.currency.bitcoin_cash');
};

const Section: React.FC<{ title: string; children: React.ReactNode }> = ({ title, children }) => (
    <section className="border-t-(length:--hairline) border-[var(--border)] pt-7">
        <h2 className="text-sm font-semibold text-[var(--text)]">{title}</h2>
        <div className="mt-2 space-y-2.5 text-sm leading-relaxed text-[var(--text-muted)]">{children}</div>
    </section>
);

const Card: React.FC<{ children: React.ReactNode; className?: string }> = ({ children, className = '' }) => (
    <div className={`rounded-[var(--radius-lg)] border-(length:--hairline) border-[var(--border)] p-5 ${className}`}>
        {children}
    </div>
);

const AddressRow: React.FC<{
    label: string;
    address: string;
    t: (key: string) => string;
}> = ({ label, address, t }) => {
    const [copied, setCopied] = useState(false);
    const copy = async () => {
        try {
            await navigator.clipboard.writeText(address);
            setCopied(true);
            window.setTimeout(() => setCopied(false), 2000);
        } catch {
            // Selecting the text by hand still works.
        }
    };
    return (
        <div className="rounded-[var(--radius-md)] border-(length:--hairline) border-[var(--border)] p-3">
            <div className="flex items-baseline justify-between gap-3">
                <span className="text-xs font-semibold text-[var(--text)]">{label}</span>
                <button
                    onClick={() => void copy()}
                    className="inline-flex items-center gap-1 text-xs text-[var(--accent-ink)]"
                >
                    {copied ? <Check size={14} /> : <Copy size={14} />}
                    {copied ? t('vote.donation.copied') : t('vote.donation.copy')}
                </button>
            </div>
            <p className="mt-1.5 break-all font-mono text-xs leading-relaxed text-[var(--text)]">{address}</p>
        </div>
    );
};

const Bar: React.FC<{ value: number; total: number }> = ({ value, total }) => (
    <div className="mt-1.5 h-1.5 overflow-hidden rounded-full bg-[var(--surface-muted)]">
        <div
            className="h-full rounded-full bg-[var(--accent)]"
            style={{ width: `${total > 0 ? Math.round((value / total) * 100) : 0}%` }}
        />
    </div>
);

const TallySplit: React.FC<{ tally: VoteTally; t: (key: string) => string }> = ({ tally, t }) => (
    <div className="space-y-3">
        {SPLIT_OPTIONS.map(option => (
            <div key={option.id}>
                <div className="flex items-baseline justify-between gap-4">
                    <span className="text-sm text-[var(--text)]">{splitText(option, t)}</span>
                    <span className="shrink-0 text-sm tabular-nums text-[var(--text-muted)]">
                        {tally.split[option.id]}
                    </span>
                </div>
                <Bar value={tally.split[option.id]} total={tally.ballots} />
            </div>
        ))}
    </div>
);

const TallyCurrencies: React.FC<{ tally: VoteTally; t: (key: string) => string }> = ({ tally, t }) => (
    <div className="space-y-3">
        <div className="flex items-baseline justify-between gap-4">
            <span className="text-sm text-[var(--text)]">{currencyLabel(ALWAYS_SUPPORTED_CURRENCY, t)}</span>
            <span className="shrink-0 text-xs text-[var(--accent-ink)]">{t('vote.currency.always')}</span>
        </div>
        {ADDITIONAL_CURRENCIES.map(id => {
            const count = tally.currencies[id];
            const passed = tally.ballots > 0 && count / tally.ballots > ADDITIONAL_CURRENCY_MAJORITY;
            return (
                <div key={id}>
                    <div className="flex items-baseline justify-between gap-4">
                        <span className="text-sm text-[var(--text)]">{currencyLabel(id, t)}</span>
                        <span className="flex shrink-0 gap-3 text-xs tabular-nums text-[var(--text-muted)]">
                            {passed && <span className="text-[var(--accent-ink)]">{t('vote.tally.pass')}</span>}
                            {count > 0 && <span>{count}</span>}
                            <span>{tally.ballots > 0 ? `${Math.round((count / tally.ballots) * 100)}%` : '0%'}</span>
                        </span>
                    </div>
                    <Bar value={count} total={tally.ballots} />
                </div>
            );
        })}
    </div>
);

const TallyAccept: React.FC<{ tally: VoteTally; t: (key: string) => string }> = ({ tally, t }) => (
    <div className="space-y-2">
        <div className="flex items-baseline justify-between gap-4 text-sm">
            <span className="text-[var(--text)]">{t('vote.tally.yes')}</span>
            <span className="flex gap-3 tabular-nums text-[var(--text-muted)]">
                <span>{tally.accept.yes}</span>
                <span>{tally.ballots > 0 ? Math.round((tally.accept.yes / tally.ballots) * 100) : 0}%</span>
            </span>
        </div>
        <Bar value={tally.accept.yes} total={tally.ballots} />
        <div className="flex items-baseline justify-between gap-4 text-sm">
            <span className="text-[var(--text)]">{t('vote.tally.no')}</span>
            <span className="flex gap-3 tabular-nums text-[var(--text-muted)]">
                <span>{tally.accept.no}</span>
                <span>{tally.ballots > 0 ? Math.round((tally.accept.no / tally.ballots) * 100) : 0}%</span>
            </span>
        </div>
        <Bar value={tally.accept.no} total={tally.ballots} />
    </div>
);

interface CommunityVoteProps {
    onBack: () => void;
}

const CommunityVote: React.FC<CommunityVoteProps> = ({ onBack }) => {
    const { t, lang } = useTranslation();

    const [vote, setVote] = useState<VotePublic | null>(null);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const publicRequest = useRef(0);

    const loadPublic = useCallback(
        async (signal?: AbortSignal) => {
            const request = ++publicRequest.current;
            if (signal) setLoading(true);
            try {
                const res = await fetch(apiEndpoint('/api/vote'), { signal, cache: 'no-store' });
                if (!res.ok) throw await apiErrorFrom(res);
                const data = (await res.json()) as VotePublic;
                if (request !== publicRequest.current) return;
                setVote(data);
                setError(null);
            } catch (e) {
                if (e instanceof Error && e.name === 'AbortError') return;
                if (request !== publicRequest.current) return;
                setError(t('vote.error.load'));
            } finally {
                if (signal && request === publicRequest.current) setLoading(false);
            }
        },
        [t],
    );

    useEffect(() => {
        const ctrl = new AbortController();
        void loadPublic(ctrl.signal);
        const timer = window.setInterval(() => void loadPublic(), REFRESH_INTERVAL_MS);
        return () => {
            publicRequest.current++;
            ctrl.abort();
            window.clearInterval(timer);
        };
    }, [loadPublic]);

    const status = vote?.vote.status ?? 'upcoming';

    const final = useMemo(() => {
        if (!vote || status !== 'closed') return null;
        const outcome = resolveVoteOutcome(vote.tally);
        const split = SPLIT_OPTIONS.find(option => option.id === outcome.split) ?? SPLIT_OPTIONS[0];
        return { split, accepted: outcome.accepted, added: outcome.addedCurrencies };
    }, [status, vote]);

    const [donation, setDonation] = useState<DonationConfig | null>(null);
    const [donationFailed, setDonationFailed] = useState(false);
    const [invoiceBusy, setInvoiceBusy] = useState(false);
    const [invoiceError, setInvoiceError] = useState(false);
    const [otherTicker, setOtherTicker] = useState('');
    const [otherNetwork, setOtherNetwork] = useState('');

    // The addresses are only meaningful once the vote has passed. The page
    // asks for them once; the vote itself keeps polling above.
    useEffect(() => {
        if (status !== 'closed' || !final?.accepted) return;
        let cancelled = false;
        setDonationFailed(false);
        void donationService
            .get()
            .then(value => {
                if (!cancelled) setDonation(value);
            })
            .catch(() => {
                if (!cancelled) setDonationFailed(true);
            });
        return () => {
            cancelled = true;
        };
    }, [status, final?.accepted]);

    const startInvoice = async (ticker: string, network: string) => {
        setInvoiceBusy(true);
        setInvoiceError(false);
        try {
            const invoice = await donationService.createInvoice(ticker, network);
            // `noopener` makes window.open() return null even when the tab
            // opened, which would also navigate this page in the fallback.
            // Open the tab, then cut the opener reference instead.
            const opened = window.open(invoice.url, '_blank');
            if (opened) opened.opener = null;
            else window.location.assign(invoice.url);
        } catch {
            setInvoiceError(true);
        } finally {
            setInvoiceBusy(false);
        }
    };

    if (loading && !vote) {
        return (
            <div className="md:pb-32">
                <PageHeader onBack={onBack} title={t('vote.title')} />
                <div className={`${PAGE_COLUMN} mt-3`}>
                    <p className="text-sm text-[var(--text-muted)]">{t('vote.loading')}</p>
                </div>
            </div>
        );
    }

    if (!vote) {
        return (
            <div className="md:pb-32">
                <PageHeader onBack={onBack} title={t('vote.title')} />
                <div className={`${PAGE_COLUMN} mt-3`}>
                    <p className="text-sm text-[var(--danger)]">{error ?? t('vote.error.load')}</p>
                    <button onClick={() => void loadPublic()} className="btn-secondary mt-4">
                        {t('vote.error.retry')}
                    </button>
                </div>
            </div>
        );
    }

    const { vote: proposal, tally } = vote;
    const early = proposal.status === 'upcoming' && proposal.acceptsBallots;
    const statusLabel = early ? t('vote.status.early') : t(`vote.status.${proposal.status}`);
    const dateRange = fill(t('vote.date_range'), {
        open: formatDateTime(proposal.opensAt, lang),
        close: formatDateTime(proposal.closesAt, lang),
    });

    return (
        <div className="md:pb-32">
            <PageHeader
                onBack={onBack}
                title={t('vote.title')}
                subtitle={dateRange}
                actions={
                    <span
                        className={`text-sm ${
                            proposal.acceptsBallots ? 'text-[var(--accent-ink)]' : 'text-[var(--text-muted)]'
                        }`}
                    >
                        {statusLabel}
                    </span>
                }
            />

            <div className={`${PAGE_COLUMN} mt-3 space-y-7`}>
                <p className="text-sm leading-relaxed text-[var(--text)]">
                    {final ? t('vote.intro.closed') : t('vote.intro')}
                </p>

                {final && (
                    <Card className="bg-[var(--surface-muted)]">
                        <h2 className="text-sm font-semibold text-[var(--text)]">{t('vote.tally.final')}</h2>
                        {tally.ballots === 0 ? (
                            <p className="mt-2 text-sm text-[var(--text-muted)]">{t('vote.tally.none')}</p>
                        ) : (
                            <div className="mt-3 space-y-2 text-sm leading-relaxed text-[var(--text)]">
                                <p>{splitText(final.split, t)}</p>
                                <p>
                                    {final.accepted
                                        ? t('vote.tally.final_accept_yes')
                                        : t('vote.tally.final_accept_no')}
                                </p>
                                {final.accepted && (
                                    <p>
                                        {fill(t('vote.tally.final_currencies'), {
                                            currencies: [
                                                currencyLabel(ALWAYS_SUPPORTED_CURRENCY, t),
                                                ...final.added.map(id => currencyLabel(id, t)),
                                            ].join(t('list.sep')),
                                        })}
                                    </p>
                                )}
                            </div>
                        )}
                        <p className="mt-3 text-xs leading-relaxed text-[var(--text-muted)]">
                            {t('vote.tally.final_note')}
                        </p>
                    </Card>
                )}

                {final?.accepted && (
                    <Card>
                        <h2 className="text-sm font-semibold text-[var(--text)]">{t('vote.donation.title')}</h2>
                        <p className="mt-1.5 text-sm leading-relaxed text-[var(--text-muted)]">
                            {t('vote.donation.body')}
                        </p>
                        {donation && (donation.monero || donation.trocador) ? (
                            <>
                                {donation.monero && (
                                    <div className="mt-4">
                                        <AddressRow
                                            label={currencyLabel(ALWAYS_SUPPORTED_CURRENCY, t)}
                                            address={donation.monero}
                                            t={t}
                                        />
                                        <p className="mt-1.5 text-[11px] leading-relaxed text-[var(--text-muted)]">
                                            {t('vote.donation.direct_note')}
                                        </p>
                                    </div>
                                )}
                                {donation.trocador ? (
                                    <div className="mt-4 space-y-3">
                                        <button
                                            type="button"
                                            onClick={() => void startInvoice('btc', 'Mainnet')}
                                            disabled={invoiceBusy}
                                            className="btn-primary w-full"
                                        >
                                            {invoiceBusy ? t('vote.donation.creating') : t('vote.donation.bitcoin')}
                                        </button>
                                        <p className="text-[11px] leading-relaxed text-[var(--text-muted)]">
                                            {t('vote.donation.swap_note')}
                                        </p>
                                        <form
                                            className="space-y-2"
                                            onSubmit={event => {
                                                event.preventDefault();
                                                if (!otherTicker.trim() || !otherNetwork.trim() || invoiceBusy) return;
                                                void startInvoice(otherTicker.trim(), otherNetwork.trim());
                                            }}
                                        >
                                            <p className="text-xs font-medium text-[var(--text)]">
                                                {t('vote.donation.other')}
                                            </p>
                                            <div className="flex flex-col gap-2 sm:flex-row">
                                                <input
                                                    value={otherTicker}
                                                    onChange={event => setOtherTicker(event.target.value)}
                                                    placeholder={t('vote.donation.ticker_placeholder')}
                                                    autoComplete="off"
                                                    autoCapitalize="none"
                                                    spellCheck={false}
                                                    maxLength={12}
                                                    className="input-base flex-1"
                                                />
                                                <input
                                                    value={otherNetwork}
                                                    onChange={event => setOtherNetwork(event.target.value)}
                                                    placeholder={t('vote.donation.network_placeholder')}
                                                    autoComplete="off"
                                                    spellCheck={false}
                                                    maxLength={32}
                                                    list="donation-networks"
                                                    className="input-base flex-1"
                                                />
                                                <datalist id="donation-networks">
                                                    <option value="Mainnet" />
                                                    <option value="TRC20" />
                                                    <option value="ERC20" />
                                                    <option value="BEP20" />
                                                </datalist>
                                                <button
                                                    type="submit"
                                                    disabled={
                                                        invoiceBusy || !otherTicker.trim() || !otherNetwork.trim()
                                                    }
                                                    className="btn-primary w-full sm:w-auto"
                                                >
                                                    {invoiceBusy
                                                        ? t('vote.donation.creating')
                                                        : t('vote.donation.continue')}
                                                </button>
                                            </div>
                                            <p className="text-[11px] leading-relaxed text-[var(--text-muted)]">
                                                {t('vote.donation.network_hint')}
                                            </p>
                                        </form>
                                    </div>
                                ) : (
                                    <p className="mt-3 text-xs leading-relaxed text-[var(--text-muted)]">
                                        {t('vote.donation.trocador_unavailable')}
                                    </p>
                                )}
                                {invoiceError && (
                                    <p className="mt-2 text-sm text-[var(--danger)]">
                                        {t('vote.donation.invoice_failed')}
                                    </p>
                                )}
                                <p className="mt-3 text-xs leading-relaxed text-[var(--text-muted)]">
                                    {t('vote.donation.risk_note')}
                                </p>
                                <p className="mt-2 text-xs leading-relaxed text-[var(--text-muted)]">
                                    {t('vote.donation.split_note')}
                                </p>
                                <a
                                    href="https://github.com/xunxunProjects/Oyama-s-HRT-Tracker/blob/main/DONATE.md"
                                    target="_blank"
                                    rel="noreferrer"
                                    className="mt-3 inline-block text-xs text-[var(--accent-ink)] underline"
                                >
                                    {t('vote.donation.verify')}
                                </a>
                            </>
                        ) : donationFailed ? (
                            <p className="mt-3 text-sm text-[var(--danger)]">{t('vote.donation.unavailable')}</p>
                        ) : donation ? (
                            <p className="mt-3 text-sm text-[var(--text-muted)]">{t('vote.donation.unavailable')}</p>
                        ) : (
                            <p className="mt-3 text-sm text-[var(--text-muted)]">{t('vote.loading')}</p>
                        )}
                    </Card>
                )}

                <Section title={t('vote.why.title')}>
                    <p>{t('vote.why.body')}</p>
                </Section>

                <Section title={t('vote.split.title')}>
                    <p>{t('vote.split.body')}</p>
                    <div className="rounded-[var(--radius-md)] bg-[var(--surface-muted)] p-4">
                        <p className="text-sm font-medium text-[var(--text)]">{splitText(SPLIT_OPTIONS[0], t)}</p>
                        <p className="mt-1 text-xs text-[var(--text-muted)]">{t('vote.split.proposed')}</p>
                    </div>
                    <p className="text-xs">{t('vote.split.rule')}</p>
                    <p className="text-xs">{fill(t('vote.split.floor'), { min: MIN_MAINTAINER_SHARE })}</p>
                </Section>

                <Section title={t('vote.currency.title')}>
                    <p>{t('vote.currency.body')}</p>
                    <div className="flex flex-wrap gap-x-4 gap-y-1">
                        <span className="inline-flex items-center gap-1.5 text-sm text-[var(--accent-ink)]">
                            <Lock size={14} />
                            {currencyLabel(ALWAYS_SUPPORTED_CURRENCY, t)}
                        </span>
                        {ADDITIONAL_CURRENCIES.map(id => (
                            <span key={id} className="text-sm text-[var(--text-muted)]">
                                {currencyLabel(id, t)}
                            </span>
                        ))}
                    </div>
                    <p className="text-xs">{t('vote.currency.rule')}</p>
                </Section>

                <Section title={t('vote.transparency.title')}>
                    <p>{t('vote.transparency.body')}</p>
                </Section>

                <section className="border-t-(length:--hairline) border-[var(--border)] pt-7">
                    <div className="flex items-baseline justify-between gap-4">
                        <h2 className="text-sm font-semibold text-[var(--text)]">{t('vote.tally.title')}</h2>
                        <span className="text-xs tabular-nums text-[var(--text-muted)]">
                            {fill(t(tally.ballots === 1 ? 'vote.tally.ballots_one' : 'vote.tally.ballots'), {
                                n: tally.ballots,
                            })}
                        </span>
                    </div>

                    {tally.ballots === 0 ? (
                        <p className="mt-3 text-sm text-[var(--text-muted)]">{t('vote.tally.none')}</p>
                    ) : (
                        <div className="mt-5 space-y-6">
                            <div>
                                <h3 className="mb-2 text-xs font-semibold text-[var(--text-muted)]">
                                    {t('vote.tally.split')}
                                </h3>
                                <TallySplit tally={tally} t={t} />
                            </div>
                            <div>
                                <h3 className="mb-2 text-xs font-semibold text-[var(--text-muted)]">
                                    {t('vote.tally.currencies')}
                                </h3>
                                <TallyCurrencies tally={tally} t={t} />
                                <p className="mt-2 text-xs text-[var(--text-muted)]">{t('vote.tally.threshold')}</p>
                            </div>
                            <div>
                                <h3 className="mb-2 text-xs font-semibold text-[var(--text-muted)]">
                                    {t('vote.tally.accept')}
                                </h3>
                                <TallyAccept tally={tally} t={t} />
                                <p className="mt-2 text-xs text-[var(--text-muted)]">{t('vote.accept.rule')}</p>
                            </div>
                        </div>
                    )}

                    {status !== 'closed' && (
                        <p className="mt-5 text-xs text-[var(--text-muted)]">{t('vote.tally.not_final')}</p>
                    )}
                </section>

                <p className="border-t-(length:--hairline) border-[var(--border)] pt-5 text-xs leading-relaxed text-[var(--text-muted)]">
                    {t('vote.footer')}
                </p>
            </div>
        </div>
    );
};

export default CommunityVote;
