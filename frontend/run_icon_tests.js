// IFM :: frontend/run_icon_tests.js
// 图标优先级自测（Node 直跑，不需要浏览器、不需要起 web 服务）：
//     node run_icon_tests.js
//
// 为什么要有这个脚本：第 ① 层图标（frontend/icon-exports/ 里的本地导出图 +
// frontend/icon-exports-metadata/<lang>.json）必须对**每一条**渲染路径都生效 —— 资源网格主图标 /
// 库存弹窗 / 编辑器元素行 / 流程图节点 / 外设方块卡。1.6.12 只把第 ① 层接进了 plainIconImg，
// 资源网格主图标走的是另一个入口 iconHtml，于是 laowu:cat_fur 明明有 laowu__cat_fur.png，
// 界面上却一直没引用它（回归点 = 下面 iconHtml 那几条）。
//
// 做法：按 index.html 的顺序把 web/ifm-core.js + web/ifm-meta.js + web/ifm-net.js +
// web/ifm-resources.js 塞进一个 vm 上下文（只桩掉 document / window / localStorage / fetch /
// 定时器），用真实的 icon-exports-metadata/zh.json 建索引，再逐条检查各图标入口产出的 HTML。
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const frontendDir = __dirname;
const webDir = path.join(frontendDir, 'web');
const iconDir = path.join(frontendDir, 'icon-exports');
const metaFile = path.join(frontendDir, 'icon-exports-metadata', 'zh.json');

let passed = 0;
let failed = 0;

// 打印只用 ASCII：Windows 控制台默认不是 UTF-8，中文会变乱码（脚本文件本身是 UTF-8，没问题）
function check(name, ok, detail) {
    if (ok) {
        passed += 1;
        console.log('  ok   ' + name);
        return;
    }
    failed += 1;
    console.error('  FAIL ' + name + (detail ? ' -> ' + detail : ''));
}

function contains(haystack, needle) {
    return String(haystack).indexOf(needle) >= 0;
}

// 最小 DOM 桩：图标兜底（ifmIconFallback）要读属性、换 src、替换父节点里的子节点
function fakeNode() {
    const node = {
        attrs: {}, style: {}, className: '', textContent: '', innerHTML: '',
        parentNode: null, replaced: null,
        setAttribute: function (key, value) { node.attrs[key] = String(value); },
        getAttribute: function (key) {
            return Object.prototype.hasOwnProperty.call(node.attrs, key) ? node.attrs[key] : null;
        },
        removeAttribute: function (key) { delete node.attrs[key]; },
        appendChild: function (child) { child.parentNode = node; return child; },
        removeChild: function (child) { child.parentNode = null; },
        replaceChild: function (next, prev) { next.parentNode = node; prev.parentNode = null; node.replaced = next; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; }
    };
    return node;
}

function makeSandbox() {
    const sandbox = {};
    sandbox.window = sandbox;
    // ifm-app.js 末尾靠 document.readyState 决定 init() 是否立刻跑：置成 loading，
    // 让它走 DOMContentLoaded（我们的桩直接丢掉回调），测试里就不会真的去启动界面
    sandbox.addEventListener = function () {};
    // 页面自己打给浏览器控制台的 console.info（元数据加载 / 接口缺资源）这里不需要
    sandbox.console = { log: console.log, info: function () {}, warn: function () {}, error: console.error };
    // 定时器全部桩掉：测试只直接调图标函数，不跑重画
    sandbox.setTimeout = function () { return 0; };
    sandbox.clearTimeout = function () {};
    sandbox.setInterval = function () { return 0; };
    sandbox.clearInterval = function () {};
    sandbox.localStorage = {
        getItem: function () { return null; },
        setItem: function () {},
        removeItem: function () {}
    };
    sandbox.document = {
        readyState: 'loading',
        getElementById: function () { return null; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        createElement: fakeNode,
        addEventListener: function () {}
    };
    sandbox.document.body = sandbox.document;
    sandbox.document.documentElement = sandbox.document;
    const metaJson = fs.readFileSync(metaFile, 'utf8');
    sandbox.fetch = function (url) {
        const target = String(url);
        if (target.indexOf('icon-exports-metadata/') === 0) {
            return Promise.resolve({
                ok: true,
                status: 200,
                json: function () { return Promise.resolve(JSON.parse(metaJson)); }
            });
        }
        // blocksitems 接口一律当成「接口里没有这个资源」—— 自建 / 小众模组就是这个处境，
        // 只有本地导出图能救它（laowu:cat_fur 正是这种物品）
        return Promise.resolve({
            ok: true,
            status: 200,
            json: function () { return Promise.resolve({ status: 'ok', found: false, data: null }); }
        });
    };
    return sandbox;
}

function makeContext() {
    const context = vm.createContext(makeSandbox());
    // 顺序 = index.html 里的加载顺序（10 个文件全部塞进来：既跑图标检查，也顺带验证每个文件都能加载）
    ['ifm-translate.js', 'ifm-core.js', 'ifm-meta.js', 'ifm-net.js', 'ifm-resources.js',
        'ifm-processes.js', 'ifm-editor.js', 'ifm-picker.js', 'ifm-workers.js', 'ifm-app.js'
    ].forEach(function (name) {
        vm.runInContext(fs.readFileSync(path.join(webDir, name), 'utf8'), context, { filename: name });
    });
    return context;
}

function run(context, code) {
    return vm.runInContext(code, context);
}

async function waitFor(context, expression, timeoutMs) {
    const deadline = Date.now() + (timeoutMs || 10000);
    while (Date.now() < deadline) {
        if (run(context, expression)) return true;
        await new Promise(function (resolve) { setImmediate(resolve); });
    }
    return false;
}

// 磁盘上的导出图片名（小写；导出工具的大小写不一定和元数据一致）
function diskFiles() {
    const set = new Set();
    fs.readdirSync(iconDir).forEach(function (name) { set.add(name.toLowerCase()); });
    return set;
}


// 元数据登记 vs 磁盘实际（登记了却没有 png = “导出不完整”，不是前端引用的问题）
function coverageReport() {
    const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')).meta;
    const files = diskFiles();
    let listed = 0;
    let missing = 0;
    meta.forEach(function (entry) {
        if (!entry || !entry.image_file) return;
        listed += 1;
        if (!files.has(String(entry.image_file).toLowerCase())) missing += 1;
    });
    console.log('info: zh.json registers ' + listed + ' icons; ' + missing + ' of them have no png on disk');
    return files;
}

function finish() {
    console.log('');
    console.log(passed + ' passed, ' + failed + ' failed');
    process.exitCode = failed > 0 ? 1 : 0;
}

async function main() {
    const files = coverageReport();
    const context = makeContext();

    run(context, 'ensureIconExports()');            // 界面重画就是这个入口触发懒加载
    const loaded = await waitFor(context, '!!iconExportIndex');
    check('metadata index builds (icon-exports-metadata/zh.json)', loaded);
    if (!loaded) {
        finish();
        return;
    }

    const exported = run(context, 'iconExportFile("item", "laowu:cat_fur")');
    check('metadata maps laowu:cat_fur -> laowu__cat_fur.png',
        exported === 'laowu__cat_fur.png', 'got ' + JSON.stringify(exported));
    check('laowu__cat_fur.png exists on disk', files.has('laowu__cat_fur.png'));

    const plain = run(context, 'plainIconImg("item", "laowu:cat_fur")');
    check('plainIconImg references icon-exports/laowu__cat_fur.png',
        contains(plain, 'icon-exports/laowu__cat_fur.png'), plain);
    check('plainIconImg marks the image as tier 1 (export)', contains(plain, 'data-icon-tier="export"'));

    // 回归点：资源网格主图标 / 库存弹窗走的是 iconHtml
    const cardIcon = run(context, 'iconHtml("item", "laowu:cat_fur")');
    check('iconHtml (resource grid card) references icon-exports/laowu__cat_fur.png',
        contains(cardIcon, 'icon-exports/laowu__cat_fur.png'), cardIcon);
    check('iconHtml keeps the <span class="icon"> wrapper', contains(cardIcon, '<span class="icon '), cardIcon);

    // 接口明确说“没有这个资源”（会写进 localStorage 的那套）也不该挡住本地导出图
    run(context, 'setMetaMissing("item:laowu:cat_fur")');
    check('iconHtml still uses the export when the API says "missing"',
        contains(run(context, 'iconHtml("item", "laowu:cat_fur")'), 'icon-exports/laowu__cat_fur.png'));

    // 接口有 icon_url 时，本地导出图仍然是第 ① 层
    run(context, 'metaCache.set("item:laowu:cat_fur", { display_name: "Cat Fur", icon_url: "/api/v1/images/deadbeef" })');
    const both = run(context, 'iconHtml("item", "laowu:cat_fur")');
    check('export image wins over the API icon_url',
        contains(both, 'icon-exports/laowu__cat_fur.png') && !contains(both, 'deadbeef'), both);

    // 外设方块卡：方块的图标接口（/blocks/<id>/icon）收不全，本地导出图同样优先
    const blockIcon = run(context, 'blockIconHtml("create:basin_0")');
    check('blockIconHtml references icon-exports/create__basin.png',
        contains(blockIcon, 'icon-exports/create__basin.png'), blockIcon);

    // 本地也没有这个物品（猜出来的文件名已经 404 记过账）：退回接口层，不再反复请求
    run(context, 'iconExportMarkFailed("fake__not_in_export.png")');
    const guessed = run(context, 'iconHtml("item", "fake:not_in_export")');
    check('a failed export guess falls back to the API tier',
        contains(guessed, 'blocksitems.com') && contains(guessed, 'data-icon-tier="api"'), guessed);

    console.log('');
    console.log('info: iconHtml("item", "laowu:cat_fur") = ' + run(context, 'iconHtml("item", "laowu:cat_fur")'));

    // 导出图真的 404 时（元数据登记了、磁盘上却没有）：ifmIconFallback 要把 src 从 icon-exports/...
    // 换成接口地址（第 ① 层 → 第 ② 层），而不是直接掉到名称兜底
    const holder = fakeNode();
    const img = fakeNode();
    img.setAttribute('src', 'icon-exports/laowu__cat_fur.png');
    img.setAttribute('data-icon-tier', 'export');
    img.setAttribute('data-icon-key', 'item:laowu:cat_fur');
    holder.appendChild(img);
    context.__testImg = img;
    run(context, 'window.ifmIconFallback(__testImg, "item")');
    check('a 404 export image downgrades to the API tier (not straight to the name glyph)',
        img.getAttribute('data-icon-tier') === 'api' && contains(img.getAttribute('src'), 'blocksitems.com'),
        img.getAttribute('src'));
    check('the failed export file is remembered (no repeated 404s)',
        run(context, 'iconExportFile("item", "laowu:cat_fur")') === null);

    finish();
}

main().catch(function (err) {
    console.error(err);
    process.exitCode = 1;
});
