// IFM :: frontend/fix_formatter_comments.js
// 修复"格式化工具把 // 注释改坏"的情况（2026-09 实际发生过：网页点了连接没反应）。
//
//     node fix_formatter_comments.js        # 修完请务必再跑 node run_dom_smoke.js
//
// 损坏形态（本脚本按这两个模式还原成 `// 文字`）：
//   ①  `/ 文字 */`                      —— 本应是 `// 文字`（工具只写了一个斜杠，又在行尾补了 `*/`）
//   ②  单独一行 `/`，后面若干 `* 文字`，直到一个 `*/` 行
// 后果：JS 直接语法错误 → 整个脚本不执行 → init() 不跑 → 所有按钮（含连接）都没绑上事件，
// 页面看起来正常但点了没反应。`node --check web/*.js` 与 `node run_dom_smoke.js` 都能立刻发现。
'use strict';
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, 'frontend', 'web');
const files = fs.readdirSync(dir).filter(function (f) { return f.endsWith('.js'); });

let fixedLines = 0;
const touched = [];

files.forEach(function (file) {
    const full = path.join(dir, file);
    const lines = fs.readFileSync(full, 'utf8').split('\n');
    const out = [];
    let changed = 0;
    for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i];
        // ① `/ 文字 */`
        const one = line.match(/^(\s*)\/\s+(.*?)\s*\*\/\s*$/);
        if (one) {
            out.push(one[1] + '// ' + one[2]);
            changed += 1;
            continue;
        }
        // ② 单独的 `/` 行，后面跟 `* 文字` 直到 `*/`
        if (/^\s*\/\s*$/.test(line)) {
            const block = [];
            let j = i + 1;
            while (j < lines.length && /^\s*\*/.test(lines[j])) {
                block.push(lines[j].replace(/^\s*\*\s?/, ''));
                j += 1;
            }
            if (j < lines.length && /^\s*\*\/\s*$/.test(lines[j]) && block.length > 0) {
                const indent = line.match(/^(\s*)/)[1];
                block.forEach(function (text) { out.push(indent + '// ' + text); });
                changed += block.length + 2;
                i = j;
                continue;
            }
        }
        out.push(line);
    }
    fs.writeFileSync(full, out.join('\n'), 'utf8');
    if (changed > 0) {
        touched.push(file + ' (' + changed + ' lines)');
        fixedLines += changed;
    }
});
console.log('repaired: ' + (touched.join(', ') || '(nothing)'));
console.log('total repaired lines: ' + fixedLines);
