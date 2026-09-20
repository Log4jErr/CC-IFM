// IFM :: run_i18n_tests.js
// i18n 审计（用户第 4 项）：前端大量未使用的 i18n 字符串 + en 部分条目与 zh 不同步。
//
// 做什么：
//   1) 从 web/ifm-core.js 里把 `const I18N = { ... }` 原样取出来（大括号配平），当数据求值；
//   2) 扫描 web/*.js + index.html 里出现的**字符串字面量**（排除 I18N 表本身）——
//      一个键只要以字面量形式出现在别处就算"用到"（`t('x')`、`label: 'x'`、
//      `MACHINE_TYPE_LABEL_KEYS = { turtle_crafter: 'machineTypeTurtleCrafter' }` 都算）；
//   3) 报告：zh / en 各自的键数、只在一边存在的键（硬错误）、en 表缺失的键（硬错误）、
//      以及"两边都没有人用"的键（可删，列出清单）。
//
// 用法：node run_i18n_tests.js        （退出码 1 = 存在键集不一致）
//       node run_i18n_tests.js --list （额外打印全部未使用键，便于清理）
'use strict';

const fs = require('fs');
const path = require('path');
const dir = __dirname;

function readWebFiles() {
    const webDir = path.join(dir, 'web');
    return fs.readdirSync(webDir).filter((name) => name.endsWith('.js'))
        .map((name) => ({ name: 'web/' + name, text: fs.readFileSync(path.join(webDir, name), 'utf8') }));
}

const coreName = 'web/ifm-core.js';
const webFiles = readWebFiles();
const core = webFiles.find((file) => file.name === coreName);
if (!core) {
    console.error('ERROR: web/ifm-core.js not found');
    process.exit(1);
}

// ---- 1) 取出 I18N 表（大括号配平；跳过字符串与注释）----
function extractI18N(text) {
    const anchor = text.indexOf('const I18N = {');
    if (anchor < 0) throw new Error('const I18N = { not found');
    const open = text.indexOf('{', anchor);
    let depth = 0;
    let index = open;
    let inString = null;
    let inLineComment = false;
    let inBlockComment = false;
    for (; index < text.length; index += 1) {
        const ch = text[index];
        const next = text[index + 1];
        if (inLineComment) {
            if (ch === '\n') inLineComment = false;
            continue;
        }
        if (inBlockComment) {
            if (ch === '*' && next === '/') { inBlockComment = false; index += 1; }
            continue;
        }
        if (inString) {
            if (ch === '\\') { index += 1; continue; }
            if (ch === inString) inString = null;
            continue;
        }
        if (ch === '/' && next === '/') { inLineComment = true; index += 1; continue; }
        if (ch === '/' && next === '*') { inBlockComment = true; index += 1; continue; }
        if (ch === "'" || ch === '"' || ch === '`') { inString = ch; continue; }
        if (ch === '{') depth += 1;
        else if (ch === '}') {
            depth -= 1;
            if (depth === 0) return { block: text.slice(open, index + 1), end: index + 1 };
        }
    }
    throw new Error('I18N table is not balanced');
}

const extracted = extractI18N(core.text);
const I18N = new Function('return ' + extracted.block)();

// ---- 2) 收集别处出现的字符串字面量（I18N 表本身排除在外）----
const coreWithoutI18N = core.text.slice(0, core.text.indexOf('const I18N = {')) +
    core.text.slice(extracted.end);
const otherSources = webFiles.filter((file) => file.name !== coreName).map((file) => file.text);
const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
const haystack = [coreWithoutI18N].concat(otherSources).concat([html]).join('\n');

const used = new Set();
const literalRe = /'([^'\\\n]{3,})'|"([^"\\\n]{3,})"/g;
let match;
while ((match = literalRe.exec(haystack)) !== null) {
    used.add(match[1] !== undefined ? match[1] : match[2]);
}

/// 键是否被用到：**在 I18N 表之外**出现这个键名即可（不要求带引号）。
/// 为什么用子串而不是"必须是字面量"：像 `MACHINE_SLOTS` 里的 `label: 'machineSlotIn'`、
/// `MACHINE_TYPE_LABEL_KEYS = { turtle_crafter: 'machineTypeTurtleCrafter' }` 这类表驱动用法
/// 是静态可见的，但正则容易被引号/转义细节漏掉；反过来，纯粹靠拼接生成的键（`'dispatchMode' .. mode`）
/// 任何静态手段都抓不到 —— 那种必须人工确认（脚本会把它们列出来）。
function keyUsed(key) {
    if (used.has(key)) return true;
    return haystack.indexOf(key) >= 0;
}

// ---- 3) 对比 ----
const langs = Object.keys(I18N);
const zh = I18N.zh || {};
const en = I18N.en || {};
const zhKeys = Object.keys(zh);
const enKeys = Object.keys(en);

const onlyZh = zhKeys.filter((key) => !Object.prototype.hasOwnProperty.call(en, key));
const onlyEn = enKeys.filter((key) => !Object.prototype.hasOwnProperty.call(zh, key));
const unused = zhKeys.filter((key) => !keyUsed(key));

const notes = [];
notes.push('languages: ' + langs.join(', '));
notes.push('keys: zh=' + zhKeys.length + ' en=' + enKeys.length);
notes.push('unused (no literal outside the I18N tables): ' + unused.length);
notes.push('only in zh (missing from en): ' + onlyZh.length + (onlyZh.length ? ' -> ' + onlyZh.slice(0, 20).join(', ') : ''));
notes.push('only in en (missing from zh): ' + onlyEn.length + (onlyEn.length ? ' -> ' + onlyEn.slice(0, 20).join(', ') : ''));
notes.forEach((line) => console.log('  ' + line));

if (process.argv.includes('--list') || unused.length <= 200) {
    if (unused.length) {
        console.log('  unused keys:');
        unused.sort().forEach((key) => console.log('    - ' + key));
    }
}

const problems = [];
if (onlyZh.length) problems.push(onlyZh.length + ' key(s) exist in zh but not in en');
if (onlyEn.length) problems.push(onlyEn.length + ' key(s) exist in en but not in zh');

// ---- 4) 疑似"en 没跟着 zh 更新"的条目（用户第 4 项）----
// 判据：中文写了很长一句、英文只有很短一段（或完全一样），多半是中文后来加了解释而英文没跟上。
// 这只是**提示**（不判定失败）：逐条改写需要人来看，脚本负责把候选列出来。
const stale = [];
zhKeys.forEach((key) => {
    const zhText = String(zh[key] === undefined ? '' : zh[key]);
    const enText = String(en[key] === undefined ? '' : en[key]);
    if (!enText || enText === key) {
        stale.push({ key: key, why: 'en missing/key-like' });
        return;
    }
    // 中文里的 CJK 字符数 vs 英文单词数：中文长句 + 英文几个词 = 大概率没同步
    const cjk = (zhText.match(/[\u4e00-\u9fff]/g) || []).length;
    const enWords = (enText.match(/[A-Za-z]+/g) || []).length;
    if (zhText === enText) {
        stale.push({ key: key, why: 'en identical to zh' });
    } else if (cjk >= 12 && enWords <= Math.max(3, Math.floor(cjk / 5))) {
        stale.push({ key: key, why: 'zh=' + cjk + ' CJK chars, en=' + enWords + ' word(s)' });
    }
});
notes.push('possibly stale en entries (zh much longer than en): ' + stale.length);
if (stale.length) {
    stale.slice(0, 60).forEach((entry) => console.log('    ? ' + entry.key + ' (' + entry.why + ')'));
    if (stale.length > 60) console.log('    ... ' + (stale.length - 60) + ' more');
}

if (problems.length) {
    console.log('\ni18n audit FAILED:');
    problems.forEach((line) => console.log('  * ' + line));
    process.exit(1);
}
console.log('\ni18n audit passed (zh/en key sets match)');
