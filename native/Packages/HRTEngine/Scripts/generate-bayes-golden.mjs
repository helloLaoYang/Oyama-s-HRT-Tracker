// Regenerate the Full Bayes reference fixture from the checked-out Web implementation:
// node native/Packages/HRTEngine/Scripts/generate-bayes-golden.mjs
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { format, resolveConfig } from 'prettier';

const root = fileURLToPath(new URL('../../../../', import.meta.url));
const output = new URL('../Tests/HRTEngineTests/Resources/bayes-golden.json', import.meta.url);
const nowMs = Date.UTC(2026, 11, 1);
const nowH = nowMs / 3_600_000;
const scratch = mkdtempSync(join(tmpdir(), 'hrt-bayes-golden-'));
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
    const amd = join(scratch, 'reference.js');
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
        ],
        { cwd: root, stdio: 'inherit' },
    );
    class FixedDate extends Date {
        static now() {
            return nowMs;
        }
    }
    new Function('define', 'Date', readFileSync(amd, 'utf8'))(define, FixedDate);
} finally {
    rmSync(scratch, { recursive: true });
}

const { runSimulation } = load('src/domain/simulation/runSimulation');
const { interpolateConcentration_E2 } = load('src/domain/simulation/interpolate');
const { computeCalibration } = load('src/domain/calibration/index');
const events = Array.from({ length: 10 }, (_, index) => ({
    id: 'e' + index,
    route: 'injection',
    ester: 'EV',
    timeH: nowH - 84 - (9 - index) * 168,
    doseMG: 5,
    extras: {},
}));
const weight = 70;
const simulation = runSimulation(events, weight);
const offsets = [-1000, -800, -560, -400, -230, -100];
const assays = ['lcms', 'immuno', 'chemi', null, 'lcms', 'immuno'];

function reading(id, offset, ratio, assay) {
    const timeH = nowH + offset;
    return { id, timeH, concValue: interpolateConcentration_E2(simulation, timeH) * ratio, unit: 'pg/ml', assay };
}

function readings(ratios) {
    return ratios.map((ratio, index) => reading('lab' + index, offsets[index], ratio, assays[index]));
}

const changed = readings([2, 2, 2, 1, 1, 1]);
const scenarios = [
    ['changed_retrospective', 'retrospective', changed],
    ['changed_forward', 'forward', changed],
    ['one_outlier', 'retrospective', readings([1, 1, 1, 10, 1, 1])],
    ['single_lcms', 'retrospective', [reading('assay', -100, 1.5, 'lcms')]],
    ['single_immuno', 'retrospective', [reading('assay', -100, 1.5, 'immuno')]],
];
const cases = scenarios.map(([name, history, labs]) => {
    const fit = computeCalibration(simulation, events, weight, labs, 'bayes', history);
    const samples = [-1100, -900, -650, -300, -100, 0, 336, 2160].map(offset => {
        const timeH = nowH + offset;
        return { timeH, factor: fit.factorFn(timeH), sd: fit.factorSdFn(timeH) };
    });
    return {
        name,
        history,
        labs,
        scale: fit.scale,
        kMul: fit.kMul,
        fitErrPct: fit.fitErrPct,
        interval: fit.latestInterval,
        discounted: fit.discounted,
        drift: fit.drift,
        samples,
    };
});
const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const fixture = { sourceCommit, source: 'src/domain/calibration/bayes.ts', nowH, events, cases };
const filepath = fileURLToPath(output);
const config = await resolveConfig(filepath);
writeFileSync(output, await format(JSON.stringify(fixture), { ...config, filepath }));
console.log('Generated ' + cases.length + ' Full Bayes calibration fixtures.');
