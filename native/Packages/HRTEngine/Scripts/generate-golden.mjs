// Regenerate the Swift tests from the checked-out Web engine with Node and tsc:
// node native/Packages/HRTEngine/Scripts/generate-golden.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../../', import.meta.url));
const output = new URL('../Tests/HRTEngineTests/Resources/golden.json', import.meta.url);
const FIXED_NOW_MS = Date.UTC(2026, 11, 1, 0, 0, 0);
const scratch = mkdtempSync(join(tmpdir(), 'hrt-golden-'));
const definitions = new Map();
const modules = new Map();

function define(id, dependencies, factory) {
    definitions.set(id, { dependencies, factory });
}

function load(id) {
    if (modules.has(id)) return modules.get(id);
    const definition = definitions.get(id);
    if (!definition) throw new Error('Unknown compiled module ' + id);
    const exports = {};
    modules.set(id, exports);
    definition.factory(
        ...definition.dependencies.map(key => (key === 'require' ? load : key === 'exports' ? exports : load(key))),
    );
    return exports;
}

try {
    const amd = join(scratch, 'engine.js');
    const projectCompiler = join(root, 'node_modules', '.bin', 'tsc');
    execFileSync(
        existsSync(projectCompiler) ? projectCompiler : 'tsc',
        [
            '--module',
            'amd',
            '--moduleResolution',
            'node',
            '--target',
            'ES2022',
            '--skipLibCheck',
            '--strict',
            '--outFile',
            amd,
            'src/domain/simulation/runSimulation.ts',
            'src/domain/simulation/interpolate.ts',
            'src/domain/calibration/index.ts',
            'src/domain/shared/activeParams.ts',
        ],
        { cwd: root, stdio: 'inherit' },
    );
    class FixedDate extends Date {
        static now() {
            return FIXED_NOW_MS;
        }
    }
    new Function('define', 'Date', readFileSync(amd, 'utf8'))(define, FixedDate);
} finally {
    rmSync(scratch, { recursive: true });
}

const { Route, Ester, ExtraKey } = load('src/domain/types');
const { DEFAULT_PK_PARAMS, CorePK } = load('src/domain/constants');
const { runSimulation } = load('src/domain/simulation/runSimulation');
const { computeCalibration } = load('src/domain/calibration/index');
const { interpolateConcentration_E2, interpolateConcentration_CPA, interpolateConcentration_T } = load(
    'src/domain/simulation/interpolate',
);
const { applyPKOverrides } = load('src/domain/shared/activeParams');
const { resolveParams } = load('src/domain/dispatch');
const { PrecomputedEventModel } = load('src/domain/shared/eventModel');

const T0 = Date.UTC(2026, 10, 1, 0, 0, 0) / 3600000;
let seq = 0;
const ev = (route, ester, offH, doseMG, extras = {}) => ({
    id: `e${++seq}`,
    route,
    ester,
    timeH: T0 + offH,
    doseMG,
    extras,
});
const repeat = (n, f) => Array.from({ length: n }, (_, i) => f(i));
const fixtures = [
    {
        name: 'patch_2x50ug_q48h',
        weight: 70,
        birthYear: null,
        events: repeat(7, i => [
            ev(Route.patchApply, Ester.E2, i * 48, 0, {
                [ExtraKey.releaseRateUGPerDay]: 50,
                [ExtraKey.patchWearH]: 48,
            }),
            ev(Route.patchApply, Ester.E2, i * 48, 0, {
                [ExtraKey.releaseRateUGPerDay]: 50,
                [ExtraKey.patchWearH]: 48,
            }),
        ]).flat(),
        sampleOffsetsH: [1, 6, 12, 24, 47, 48.5, 72, 96, 168, 240, 312, 335, 336, 360, 400],
    },
    {
        name: 'patch_100ug_q84h',
        weight: 70,
        birthYear: null,
        events: repeat(8, i =>
            ev(Route.patchApply, Ester.E2, i * 84, 0, {
                [ExtraKey.releaseRateUGPerDay]: 100,
                [ExtraKey.patchWearH]: 84,
            }),
        ),
        sampleOffsetsH: [2, 12, 24, 84, 168, 336, 600, 672, 700, 800],
    },
    {
        name: 'patch_apply_remove_pairing',
        weight: 70,
        birthYear: null,
        events: [
            ev(Route.patchApply, Ester.E2, 0, 0, { [ExtraKey.releaseRateUGPerDay]: 50 }),
            ev(Route.patchRemove, Ester.E2, 72, 0),
            ev(Route.patchApply, Ester.E2, 72, 0, { [ExtraKey.releaseRateUGPerDay]: 50 }),
            ev(Route.patchRemove, Ester.E2, 144, 0),
        ],
        sampleOffsetsH: [6, 24, 71, 73, 100, 143, 145, 170, 200],
    },
    {
        name: 'patch_total_dose_mode',
        weight: 70,
        birthYear: null,
        events: repeat(5, i => ev(Route.patchApply, Ester.E2, i * 48, 1.44, { [ExtraKey.patchWearH]: 48 })),
        sampleOffsetsH: [6, 24, 48, 96, 192, 240, 260],
    },
    {
        name: 'patch_age_1992',
        weight: 70,
        birthYear: 1992,
        events: repeat(7, i => [
            ev(Route.patchApply, Ester.E2, i * 48, 0, {
                [ExtraKey.releaseRateUGPerDay]: 50,
                [ExtraKey.patchWearH]: 48,
            }),
            ev(Route.patchApply, Ester.E2, i * 48, 0, {
                [ExtraKey.releaseRateUGPerDay]: 50,
                [ExtraKey.patchWearH]: 48,
            }),
        ]).flat(),
        sampleOffsetsH: [24, 96, 168, 312, 336, 400],
    },
    {
        name: 'patch_weight_55kg',
        weight: 55,
        birthYear: null,
        events: repeat(4, i =>
            ev(Route.patchApply, Ester.E2, i * 84, 0, {
                [ExtraKey.releaseRateUGPerDay]: 100,
                [ExtraKey.patchWearH]: 84,
            }),
        ),
        sampleOffsetsH: [24, 84, 168, 300, 336, 360],
    },
    {
        name: 'patch_plus_cpa_6_25',
        weight: 70,
        birthYear: null,
        events: [
            ...repeat(7, i => [
                ev(Route.patchApply, Ester.E2, i * 48, 0, {
                    [ExtraKey.releaseRateUGPerDay]: 50,
                    [ExtraKey.patchWearH]: 48,
                }),
                ev(Route.patchApply, Ester.E2, i * 48, 0, {
                    [ExtraKey.releaseRateUGPerDay]: 50,
                    [ExtraKey.patchWearH]: 48,
                }),
            ]).flat(),
            ...repeat(14, i => ev(Route.oral, Ester.CPA, i * 24 + 8, 6.25)),
        ],
        sampleOffsetsH: [9, 12, 24, 100, 200, 320, 330, 336, 360],
    },
    {
        name: 'cpa_12_5_daily',
        weight: 70,
        birthYear: null,
        events: repeat(21, i => ev(Route.oral, Ester.CPA, i * 24, 12.5)),
        sampleOffsetsH: [1, 2, 4, 24, 240, 482, 484, 504, 600],
    },
    {
        name: 'ev_inj_5mg_q7d',
        weight: 70,
        birthYear: null,
        events: repeat(6, i => ev(Route.injection, Ester.EV, i * 168, 5)),
        sampleOffsetsH: [6, 24, 48, 168, 500, 840, 864, 1000, 1100],
    },
    {
        name: 'ec_inj_5mg_q14d',
        weight: 70,
        birthYear: null,
        events: repeat(4, i => ev(Route.injection, Ester.EC, i * 336, 5)),
        sampleOffsetsH: [24, 96, 336, 700, 1008, 1100, 1300],
    },
    {
        name: 'eb_inj_1mg_q3d',
        weight: 70,
        birthYear: null,
        events: repeat(5, i => ev(Route.injection, Ester.EB, i * 72, 1)),
        sampleOffsetsH: [2, 8, 24, 72, 290, 300, 400],
    },
    {
        name: 'oral_e2_2mg_bid',
        weight: 70,
        birthYear: null,
        events: repeat(20, i => ev(Route.oral, Ester.E2, i * 12, 2)),
        sampleOffsetsH: [1, 3, 12, 120, 228, 230, 240, 300],
    },
    {
        name: 'oral_ev_2mg_daily',
        weight: 70,
        birthYear: null,
        events: repeat(10, i => ev(Route.oral, Ester.EV, i * 24, 2)),
        sampleOffsetsH: [2, 6, 24, 216, 220, 240, 280],
    },
    {
        name: 'sl_e2_2mg_tiers',
        weight: 70,
        birthYear: null,
        events: [0, 1, 2, 3]
            .map(t => ev(Route.sublingual, Ester.E2, t * 48, 2, { [ExtraKey.sublingualTier]: t }))
            .concat([ev(Route.sublingual, Ester.E2, 192, 2, { [ExtraKey.sublingualTheta]: 0.3 })]),
        sampleOffsetsH: [0.25, 0.5, 1, 2, 6, 48.5, 49, 96.5, 97, 144.5, 145, 192.5, 193, 200, 240],
    },
    {
        name: 'sl_ev_2mg',
        weight: 70,
        birthYear: null,
        events: repeat(3, i => ev(Route.sublingual, Ester.EV, i * 24, 2, { [ExtraKey.sublingualTier]: 2 })),
        sampleOffsetsH: [0.5, 1, 3, 24, 49, 52, 72, 96],
    },
    {
        name: 'gel_e2_1_5mg_arm',
        weight: 70,
        birthYear: null,
        events: [
            ...repeat(10, i => ev(Route.gel, Ester.E2, i * 24, 1.5, { [ExtraKey.gelSite]: 0 })),
            ...repeat(3, i => ev(Route.gel, Ester.E2, 240 + i * 24, 1.5, { [ExtraKey.gelSite]: 2 })),
        ],
        sampleOffsetsH: [4, 12, 24, 216, 240, 250, 300, 320],
    },
    {
        name: 'custom_pk_params',
        weight: 70,
        birthYear: null,
        pk: { e2_kClear: 0.3 },
        events: repeat(4, i =>
            ev(Route.patchApply, Ester.E2, i * 84, 0, {
                [ExtraKey.releaseRateUGPerDay]: 100,
                [ExtraKey.patchWearH]: 84,
            }),
        ),
        sampleOffsetsH: [24, 84, 168, 300, 336, 360],
    },
    {
        name: 'tc_inj_100mg_q7d',
        weight: 70,
        birthYear: null,
        events: repeat(6, i => ev(Route.injection, Ester.TC, i * 168, 100)),
        sampleOffsetsH: [12, 48, 168, 840, 900, 1008, 1100],
    },
];
// Calibration fixtures: lab results against the patch regimen.
const calBase = fixtures[0];
const labs = vals => vals.map(([offH, v], i) => ({ id: `l${i + 1}`, timeH: T0 + offH, concValue: v, unit: 'pg/ml' }));
function exactE2(events, weight, birthYear, tH) {
    const sorted = [...events].sort((a, b) => a.timeH - b.timeH);
    let e2 = 0,
        cpa = 0;
    for (const e of sorted) {
        if (e.route === Route.patchRemove) continue;
        const p = resolveParams(e, birthYear, weight);
        const amt = new PrecomputedEventModel(e, sorted, p).amount(tH);
        if (e.ester === Ester.CPA) cpa += amt;
        else if (![Ester.T, Ester.TC, Ester.TE, Ester.TU].includes(e.ester)) e2 += amt;
    }
    return {
        e2: (e2 * 1e9) / (CorePK.vdPerKG * weight * 1000),
        cpa: (cpa * 1e6) / (CorePK.vdPerKG_CPA * weight * 1000),
    };
}
const r = x => (x === null ? null : Number(x.toPrecision(12)));
const out = {
    generatedBy: 'native/Packages/HRTEngine/Scripts/generate-golden.mjs',
    fixedNowMs: FIXED_NOW_MS,
    T0H: T0,
    fixtures: [],
    calibration: [],
};
for (const f of fixtures) {
    const params = { ...DEFAULT_PK_PARAMS, ...(f.pk ?? {}) };
    applyPKOverrides(params);
    const sim = runSimulation(f.events, f.weight, f.birthYear);
    const samples = f.sampleOffsetsH.map(off => {
        const t = T0 + off;
        const ex = exactE2(f.events, f.weight, f.birthYear, t);
        return {
            offsetH: off,
            exactE2: r(ex.e2),
            exactCPA: r(ex.cpa),
            simE2: r(interpolateConcentration_E2(sim, t)),
            simCPA: r(interpolateConcentration_CPA(sim, t)),
            simT: r(interpolateConcentration_T(sim, t)),
        };
    });
    out.fixtures.push({
        name: f.name,
        weight: f.weight,
        birthYear: f.birthYear,
        pk: f.pk ?? null,
        events: f.events.map(e => ({ ...e, timeH: e.timeH })),
        gridLen: sim.timeH.length,
        auc: r(sim.auc),
        samples,
    });
    applyPKOverrides(null);
}
const calCases = [
    { name: 'mipd_retro_1lab', method: 'mipd', history: 'retrospective', labs: labs([[335, 110]]) },
    {
        name: 'mipd_retro_3labs',
        method: 'mipd',
        history: 'retrospective',
        labs: labs([
            [95, 90],
            [215, 120],
            [335, 105],
        ]),
    },
    {
        name: 'ekf_retro_3labs',
        method: 'ekf',
        history: 'retrospective',
        labs: labs([
            [95, 90],
            [215, 120],
            [335, 105],
        ]),
    },
    {
        name: 'mipd_forward_3labs',
        method: 'mipd',
        history: 'forward',
        labs: labs([
            [95, 90],
            [215, 120],
            [335, 105],
        ]),
    },
    {
        name: 'ou_kalman_retro_3labs',
        method: 'ou_kalman',
        history: 'retrospective',
        labs: labs([
            [95, 90],
            [215, 120],
            [335, 105],
        ]),
    },
];
for (const c of calCases) {
    const sim = runSimulation(calBase.events, calBase.weight, null);
    const cal = computeCalibration(sim, calBase.events, calBase.weight, c.labs, c.method, c.history, null);
    const at = [100, 220, 336, 400].map(off => ({
        offsetH: off,
        factor: r(cal.factorFn(T0 + off)),
        calibratedE2: r((interpolateConcentration_E2(sim, T0 + off) ?? 0) * cal.factorFn(T0 + off)),
    }));
    out.calibration.push({
        name: c.name,
        baseFixture: calBase.name,
        method: c.method,
        historyMode: c.history,
        labs: c.labs,
        scale: r(cal.scale),
        kMul: r(cal.kMul),
        halfLifeDeltaPct: r(cal.halfLifeDeltaPct),
        fitErrPct: r(cal.fitErrPct),
        points: cal.points.map(p => ({ offsetH: p.timeH - T0, obs: r(p.obs), pred: r(p.pred), ratio: r(p.ratio) })),
        at,
    });
}

out.sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
writeFileSync(output, JSON.stringify(out, null, 2) + '\n');
console.log(
    'Generated ' + out.fixtures.length + ' simulation and ' + out.calibration.length + ' calibration fixtures.',
);
