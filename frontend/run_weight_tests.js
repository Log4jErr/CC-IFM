// 调度权重自测（1.8.0）：把 web/ifm-app.js 里的权重归一化工具（clampWeight / equalWeights /
// normalizeWeights / rebalanceWeights / weightMax）原样抽出来跑断言。
// 校验的不变量：取值范围 0.01 ~ 1-0.01n（**不允许 0** —— 全 0 就没法归一化）、
// 任何一次拖动/归一化之后"所有队列合计正好 1"、而且每条都不低于 0.01。
// 运行：node frontend/run_weight_tests.js
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, 'web', 'ifm-app.js'), 'utf8');

function grab(name) {
    const start = src.indexOf('function ' + name + '(');
    if (start < 0) throw new Error('missing function ' + name);
    let depth = 0;
    for (let i = src.indexOf('{', start); i < src.length; i += 1) {
        if (src[i] === '{') depth += 1;
        else if (src[i] === '}') {
            depth -= 1;
            if (depth === 0) return src.slice(start, i + 1);
        }
    }
    throw new Error('unterminated ' + name);
}

const names = ['process', 'storageScan', 'inputScan', 'interactionScan', 'outputScan', 'inventoryIn',
    'inventoryOut', 'compact', 'stackScan', 'detail', 'manual'];
const code = 'const WEIGHT_MIN = 0.01; const WEIGHT_ROUND = 100; const SCHEDULE_QUEUES = ' +
    JSON.stringify(names) + ';\n' +
    ['roundWeight', 'weightMax', 'clampWeight', 'equalWeights', 'normalizeWeights', 'rebalanceWeights']
        .map(grab).join('\n') + '\nreturn { roundWeight, weightMax, clampWeight, equalWeights, normalizeWeights, rebalanceWeights };';

const helpers = new Function(code)();
let failed = 0;
function check(label, ok, detail) {
    console.log((ok ? '  ok   ' : '  FAIL ') + label + (ok ? '' : ' -> ' + detail));
    if (!ok) failed += 1;
}
function sum(weights) {
    return Object.keys(weights).reduce(function (acc, key) { return acc + weights[key]; }, 0);
}
function allAbove(weights, min) {
    return Object.keys(weights).every(function (key) { return weights[key] >= min - 1e-9; });
}

check('max = 1 - 0.01n = 0.89', helpers.weightMax() === 0.89, String(helpers.weightMax()));
const equal = helpers.equalWeights();
check('equal split sums to exactly 1 and never uses 0',
    Math.abs(sum(equal) - 1) < 1e-9 && allAbove(equal, 0.01), JSON.stringify(equal));

const half = helpers.rebalanceWeights(equal, 'process', 0.5);
check('dragging one slider to 0.5 keeps the total at 1 and that slider at 0.5',
    half.process === 0.5 && Math.abs(sum(half) - 1) < 1e-9 && allAbove(half, 0.01),
    JSON.stringify(half));

const maxed = helpers.rebalanceWeights(equal, 'process', 1);
check('dragging to 1 clamps to 0.89 and the rest still get at least 0.01',
    maxed.process === 0.89 && Math.abs(sum(maxed) - 1) < 1e-9 && allAbove(maxed, 0.01),
    JSON.stringify(maxed));

const zeroed = helpers.rebalanceWeights(equal, 'process', 0);
check('dragging to 0 is clamped to 0.01 (a queue can never be switched off)',
    zeroed.process === 0.01 && Math.abs(sum(zeroed) - 1) < 1e-9 && allAbove(zeroed, 0.01),
    JSON.stringify(zeroed));

const many = helpers.rebalanceWeights(equal, 'process', 0.89);
check('with the maximum fixed the other 10 queues share 0.11 (each >= 0.01)',
    Math.abs(sum(many) - 1) < 1e-9 && allAbove(many, 0.01), JSON.stringify(many));

// 用户第 3 项：归一化必须作用在**每一条**其它滑条上 ——
// 以前按整数分分配，把一条从 0.11 减到 0.05 时只够给前 6 条各加 1 分，后两条看着一动不动。
const watchers = names.filter(function (name) { return name !== 'process'; });
const lowered = helpers.rebalanceWeights(equal, 'process', 0.05);
check('lowering one slider raises EVERY other slider (no queue is left behind)',
    watchers.every(function (name) { return lowered[name] > equal[name] + 1e-9; }) &&
        Math.abs(sum(lowered) - 1) < 1e-9 && allAbove(lowered, 0.01),
    JSON.stringify(lowered));
check('raising one slider lowers EVERY other slider',
    watchers.every(function (name) { return many[name] < equal[name] + 1e-9; }) &&
        Math.abs(sum(many) - 1) < 1e-9,
    JSON.stringify(many));
check('a tiny change is spread over all queues instead of a few cents',
    (function () {
        const before = helpers.rebalanceWeights(equal, 'process', 0.11);
        const after = helpers.rebalanceWeights(equal, 'process', 0.10);
        return watchers.every(function (name) {
            return after[name] > before[name] + 1e-9;
        }) && watchers.every(function (name) { return after[name] - before[name] < 0.01; });
    })(), 'moved by less than one cent each');

const allZero = helpers.normalizeWeights({});
check('normalizing an empty/all-zero table falls back to an equal split',
    Math.abs(sum(allZero) - 1) < 1e-9 && allAbove(allZero, 0.01), JSON.stringify(allZero));

const skewed = helpers.normalizeWeights({ process: 5, storageScan: 3, inputScan: 1 });
check('normalizing skews sums to exactly 1 and keeps every queue >= 0.01',
    Math.abs(sum(skewed) - 1) < 1e-9 && allAbove(skewed, 0.01), JSON.stringify(skewed));

console.log('');
console.log(failed > 0 ? failed + ' failed' : '0 failed');
process.exit(failed > 0 ? 1 : 0);
