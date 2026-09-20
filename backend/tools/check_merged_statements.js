// IFM :: backend/tools/check_merged_statements.js
// 静态检查：找出"两条语句被挤到同一行"的历史损坏。
//
//     node tools/check_merged_statements.js
//
// 为什么需要它：早期的批量补丁（PowerShell 的 Get-Content/Set-Content + 正则替换）曾经把
// 相邻两行合并成一行，最典型的一次是把
//     dispatch:addQueue("storageScan", { ..., run = scanTaskRunner })
//     dispatch:addQueue("storageScan", { needs = "query", policy = "retry" })
// 合成 `...run = scanTaskRunner })dispatch:addQueue("storageScan", {...})` ——
// 于是第二条（不带 run 的"默认空跑"）把第一条覆盖掉：worker 永远空闲、扫描从不发生、
// 网页资源一片空白，而且不会报任何错。语法检查也查不出来（合并后的代码语法是合法的）。
'use strict';
const fs = require('fs');
const path = require('path');

const here = __dirname;
const backendDir = path.join(here, '..');

const files = ['IFMMaster.lua', 'IFMWorker.lua'].map(function (f) { return path.join(backendDir, f); });
fs.readdirSync(path.join(backendDir, 'modules'))
    .filter(function (f) { return f.endsWith('.lua'); })
    .forEach(function (f) { files.push(path.join(backendDir, 'modules', f)); });

const patterns = [
    { name: ')identifier', re: /\)[A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z_])?/ },
    { name: 'endidentifier', re: /\bend[A-Za-z_]/ },
    { name: 'twoStatements', re: /\bend\s{4,}(if|for|while|local|return|self\.|dispatch|store|cache)/ },
];

let hits = 0;
files.forEach(function (file) {
    const lines = fs.readFileSync(file, 'utf8').split('\n');
    lines.forEach(function (line, index) {
        const trimmed = line.trim();
        if (trimmed.indexOf('--') === 0) return;                 // 纯注释行不管
        patterns.forEach(function (p) {
            if (p.re.test(line)) {
                hits += 1;
                console.log(path.relative(backendDir, file) + ':' + (index + 1) +
                    ' [' + p.name + '] ' + trimmed.slice(0, 120));
            }
        });
    });
});
console.log(hits === 0
    ? 'merged-statement check: clean (' + files.length + ' files)'
    : 'merged-statement check: ' + hits + ' suspicious line(s) above');
process.exit(hits === 0 ? 0 : 1);
