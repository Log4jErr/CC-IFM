// IFM :: frontend/run_icon_tests.js
// 图标优先级自测（Node 直跑，不需要浏览器、不需要起 web 服务）：
//     node run_icon_tests.js
//
// 为什么要有这个脚本：第 ① 层图标（frontend/icon-exports/ 里的本地导出图 +
// frontend/icon-exports-metadata/<lang>.json）必须对每一条渲染路径都生效 —— 资源网格主图标 /
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

// 深度反转对象键顺序（数组保持原序）：验证 components 比较是递归键顺序无关的
function reverseKeysDeep(value) {
    if (Array.isArray(value)) return value.map(reverseKeysDeep);
    if (value && typeof value === 'object') {
        const out = {};
        Object.keys(value).reverse().forEach(function (key) { out[key] = reverseKeysDeep(value[key]); });
        return out;
    }
    return value;
}

// 元数据里某个 id 的条目（按登记顺序），用于挑测试数据
function metaEntries(id) {
    const meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')).meta;
    return meta.filter(function (entry) { return entry && entry.id === id; });
}

// 返回的文件名是否就是该 id 的某条元数据条目登记的图片。
// 注意：导出器（IconExporter）现在用**哈希后缀**命名带 NBT 的变体（`id__<hash>.png`），
// 不再是旧的 `id__{components}.png` 约定 —— 所以这里校验"确实是这个 id 的导出图"，
// 而不是去猜文件名长什么样。
function isMetaFileFor(id, file) {
    return !!file && metaEntries(id).some(function (entry) { return entry.image_file === file; });
}

// 规范化 JSON（键排序）：比较 components 是否完全一致（与前后端"递归键顺序无关"的约定一致）
function canonical(value) {
    if (Array.isArray(value)) {
        return '[' + value.map(canonical).join(',') + ']';
    }
    if (value && typeof value === 'object') {
        return '{' + Object.keys(value).sort().map(function (key) {
            return JSON.stringify(key) + ':' + canonical(value[key]);
        }).join(',') + '}';
    }
    return JSON.stringify(value);
}

// 最小 DOM 桩：图标兜底（ifmIconFallback）要读属性、换 src、替换父节点里的子节点；
// ifmAddElement 这类“拼好 HTML 再取 firstChild 塞进列表”的代码还要 children/firstChild。
function fakeNode() {
    const node = {
        attrs: {}, style: {}, className: '', textContent: '',
        children: [], parentNode: null, replaced: null,
        setAttribute: function (key, value) { node.attrs[key] = String(value); },
        getAttribute: function (key) {
            return Object.prototype.hasOwnProperty.call(node.attrs, key) ? node.attrs[key] : null;
        },
        removeAttribute: function (key) { delete node.attrs[key]; },
        appendChild: function (child) {
            if (!child) throw new Error('appendChild(null)');
            child.parentNode = node;
            node.children.push(child);
            return child;
        },
        removeChild: function (child) { child.parentNode = null; },
        replaceChild: function (next, prev) { next.parentNode = node; prev.parentNode = null; node.replaced = next; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; }
    };
    // innerHTML 只做一层（够用）：写入时造一个子节点，firstChild 就能拿到
    Object.defineProperty(node, 'innerHTML', {
        get: function () { return ''; },
        set: function (value) {
            node.children = String(value) ? [fakeNode()] : [];
            if (node.children[0]) node.children[0].parentNode = node;
        }
    });
    Object.defineProperty(node, 'firstChild', {
        get: function () { return node.children[0] || null; }
    });
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
    // 注册名 → { total, missing, usable }：一个注册名下的图片全部缺失时，
    // 前端也只能退到接口层/名称字形（长文件名的导出图在 Windows 上常常写不出来）
    const byId = new Map();
    meta.forEach(function (entry) {
        if (!entry || !entry.image_file) return;
        listed += 1;
        const exists = files.has(String(entry.image_file).toLowerCase());
        if (!exists) missing += 1;
        const record = byId.get(entry.id) || { missing: 0, total: 0, usable: 0 };
        record.total += 1;
        if (exists) record.usable += 1; else record.missing += 1;
        byId.set(entry.id, record);
    });
    console.log('info: zh.json registers ' + listed + ' icons; ' + missing + ' of them have no png on disk');
    const deadIds = [];
    const partialIds = [];
    byId.forEach(function (record, id) {
        if (record.usable === 0) deadIds.push(id);
        else if (record.missing > 0) partialIds.push(id + '(' + record.missing + '/' + record.total + ')');
    });
    if (partialIds.length > 0) {
        console.log('info: ' + partialIds.length + ' ids have *some* png missing (the frontend tries the ' +
            'remaining variants of the same id): ' + partialIds.slice(0, 8).join(', '));
    }
    if (deadIds.length > 0) {
        console.log('info: ' + deadIds.length + ' ids have no png at all -> only the API/name glyph can be ' +
            'shown (re-export on a machine that can write long file names): ' + deadIds.join(', '));
    }
    return files;
}

function finish() {
    console.log('');
    console.log(passed + ' passed, ' + failed + ' failed');
    process.exitCode = failed > 0 ? 1 : 0;
}

async function main() {
    // 图标导出（frontend/icon-exports/ 的 png + frontend/icon-exports-metadata/<lang>.json）是
    // 可选的大文件：没导出 / 被清理掉时不要抛栈报错，直接说明原因并跳过这一套自测
    // （前端会自动退回接口图标层，功能不受影响）。
    if (!fs.existsSync(metaFile)) {
        console.log('info: icon export metadata is missing: ' + metaFile);
        console.log('info: skipping the icon self-test - export from IconExporter and put <lang>.json ' +
            'into frontend/icon-exports-metadata/ (images into frontend/icon-exports/).');
        process.exitCode = 0;
        return;
    }
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

    // ===== 同一个注册名优先：item-metadata 里有这个 id 就不回退到 blocksitems =====
    // laowu:cat_pancake 在元数据里只有带 NBT 的那一条（没有无 components 的通用条目），
    // 而存储里的猫饼 NBT 与它不同：只要注册名对得上就该用它 —— blocksitems 根本没有这个物品。
    const pancake = run(context, 'iconExportFile("item", "laowu:cat_pancake")');
    check('same registry name wins even when the NBT differs (laowu:cat_pancake)',
        isMetaFileFor('laowu:cat_pancake', pancake), 'got ' + JSON.stringify(pancake));
    const pancakeIcon = run(context, 'iconHtml("item", "laowu:cat_pancake")');
    check('an NBT item stays on the export tier in iconHtml (no blocksitems)',
        contains(pancakeIcon, 'icon-exports/laowu__cat_pancake__') &&
        contains(pancakeIcon, 'data-icon-tier="export"') && !contains(pancakeIcon, 'blocksitems.com'),
        pancakeIcon);
    const pancakeBlue = run(context, 'iconExportFile("item", "laowu:cat_pancake", ' +
        JSON.stringify({ 'minecraft:custom_data': { LaoWuCatVariant: 'minecraft:blue' } }) + ')');
    check('a caller-supplied (different) NBT still resolves to the same registry name',
        isMetaFileFor('laowu:cat_pancake', pancakeBlue), 'got ' + JSON.stringify(pancakeBlue));

    // NBT 比较必须递归键顺序无关（嵌套对象以前只排顶层键 → 同一份 NBT 匹配不上）
    const pancakeComponents = metaEntries('laowu:cat_pancake')[0].components;
    const orderedKey = run(context, 'iconExportComponentsKey(' + JSON.stringify(pancakeComponents) + ')');
    const reversedKey = run(context, 'iconExportComponentsKey(' +
        JSON.stringify(reverseKeysDeep(pancakeComponents)) + ')');
    check('iconExportComponentsKey ignores nested key order',
        !!orderedKey && orderedKey === reversedKey, 'ordered=' + orderedKey + ' reversed=' + reversedKey);
    check('a deeply reordered NBT still hits the same variant',
        run(context, 'iconExportFile("item", "laowu:cat_pancake", ' +
            JSON.stringify(reverseKeysDeep(pancakeComponents)) + ')') === pancake);

    // ===== “NBT 最接近”的变体选择（不再随手用 variants[0]）=====
    // ① 精确命中：给出一条变体的 components，就必须是那一条（哪怕不在第 0 位）
    const hissingComponents = { 'minecraft:potion_contents': { potion: 'laowu:hissing' } };
    const hissing = run(context, 'iconExportFile("item", "minecraft:potion", ' +
        JSON.stringify(hissingComponents) + ')');
    const potions = metaEntries('minecraft:potion');
    const hissingEntry = potions.filter(function (entry) {
        return canonical(entry.components) === canonical(hissingComponents);
    })[0];
    check('an exact NBT match picks that very variant (not the first one)',
        !!hissingEntry && hissing === hissingEntry.image_file &&
        (!potions[0] || hissing !== potions[0].image_file),
        'got ' + JSON.stringify(hissing) + ' expected ' +
        JSON.stringify(hissingEntry && hissingEntry.image_file));

    // ② 没有完全一致的：把某条卷轴变体只改一个字段 → 最“接近”的那条胜出
    const scrollVariants = JSON.parse(run(context,
        'JSON.stringify(iconExportEntry("item", "irons_spellbooks:scroll").variants.map(function (v) {' +
        ' return { file: v.file, components: v.components }; }))'));
    let scrollIndex = -1;
    for (let i = 0; i < scrollVariants.length; i += 1) {
        if (contains(scrollVariants[i].components, 'blood_needles')) { scrollIndex = i; break; }
    }
    check('the scroll variant used by the near-miss test exists', scrollIndex >= 1,
        'index=' + scrollIndex + ' of ' + scrollVariants.length);
    if (scrollIndex >= 1) {
        const near = JSON.parse(scrollVariants[scrollIndex].components);
        near['irons_spellbooks:spell_container'].maxSpells = 999;
        const nearFile = run(context, 'iconExportFile("item", "irons_spellbooks:scroll", ' +
            JSON.stringify(near) + ')');
        check('a near-miss NBT picks the closest variant',
            nearFile === scrollVariants[scrollIndex].file && nearFile !== scrollVariants[0].file,
            'got ' + JSON.stringify(nearFile));
        const nearIcon = run(context, 'plainIconImg("item", "irons_spellbooks:scroll", ' +
            JSON.stringify(near) + ')');
        check('a near-miss NBT keeps the export tier (no blocksitems)',
            contains(nearIcon, 'icon-exports/') && !contains(nearIcon, 'blocksitems.com'), nearIcon);
    }

    // ③ 没有 NBT 时保持旧行为：通用（无 components）图在前；给了 NBT 就变体优先
    check('without NBT the generic (no-components) icon still wins (unchanged)',
        run(context, 'iconExportFile("item", "minecraft:painting")') === 'minecraft__painting.png');
    check('with an unknown NBT a variant is preferred over the generic icon',
        contains(run(context, 'iconExportFile("item", "minecraft:painting", { "x:y": 1 })'),
            'minecraft__painting__'));

    // ===== 404 的导出图：先换同一注册名的另一张导出图，再退到 blocksitems =====
    // （以前直接退到接口层：同名物品的其它变体明明有图，却因为这一张 404 就不用了）
    const scrollFirstFile = scrollVariants[0].file;
    check('the scroll variants[0] png exists on disk', files.has(String(scrollFirstFile).toLowerCase()));
    run(context, 'iconExportMarkFailed(' + JSON.stringify(scrollFirstFile) + ')');
    const holderNext = fakeNode();
    const imgNext = fakeNode();
    imgNext.setAttribute('src', run(context, 'iconExportUrl(' + JSON.stringify(scrollFirstFile) + ')'));
    imgNext.setAttribute('data-icon-tier', 'export');
    imgNext.setAttribute('data-icon-key', 'item:irons_spellbooks:scroll');
    holderNext.appendChild(imgNext);
    context.__testImgNext = imgNext;
    run(context, 'window.ifmIconFallback(__testImgNext, "item")');
    check('a 404 export image switches to another variant of the same registry name',
        imgNext.getAttribute('data-icon-tier') === 'export' &&
        contains(decodeURIComponent(imgNext.getAttribute('src')), 'irons_spellbooks__scroll__') &&
        !contains(imgNext.getAttribute('src'), 'blocksitems.com'), imgNext.getAttribute('src'));

    // 带 { } 的长文件名要能被“记住”：键必须是元数据里的原始文件名
    // （以前只还原 %23/%3F，%7B/%7D 留在键里 → 对不上，每次重画都再 404 一次）
    check('iconExportFileFromUrl restores the raw metadata file name',
        run(context, 'iconExportFileFromUrl(' +
            JSON.stringify(run(context, 'iconExportUrl(' + JSON.stringify(pancake) + ')')) + ')') === pancake);

    // ===== 外设方块图标：不带命名空间的外设名也要找到方块（红石继电器）=====
    // CC:T 对红石继电器给出的外设名是 redstone_relay_0，以前按 "redstone_relay" 去查元数据
    // / 接口，两边都没有 → 卡片只剩名称字形。
    const relayIcon = run(context, 'blockIconHtml("redstone_relay_0")');
    check('a namespace-less peripheral name resolves to computercraft:redstone_relay',
        contains(relayIcon, 'icon-exports/computercraft__redstone_relay.png'), relayIcon);
    check('computercraft__redstone_relay.png exists on disk', files.has('computercraft__redstone_relay.png'));
    const relayTitle = run(context, 'peripheralTitleHtml("redstone_relay_0")');
    check('the peripheral card shows the block name (computercraft:redstone_relay / 红石继电器)',
        contains(relayTitle, 'computercraft:redstone_relay') && contains(relayTitle, '红石继电器'),
        relayTitle);
    check('another computercraft block (speaker_0) resolves the same way',
        contains(run(context, 'blockIconHtml("speaker_0")'), 'icon-exports/computercraft__speaker.png'));
    check('a namespace-less vanilla block falls back to minecraft:chest',
        contains(run(context, 'blockIconHtml("chest_0")'), 'icon-exports/minecraft__chest.png'));
    // 路径在本地导出里唯一命中时，也用来把命名空间找回来（模组方块，例如 create:depot）
    check('a uniquely named modded block is resolved through the export index (depot_0)',
        contains(run(context, 'blockIconHtml("depot_0")'), 'icon-exports/create__depot.png'));
    check('a namespaced peripheral name is untouched (create:basin)',
        run(context, 'resolvedBlockIdOf("create:basin_0")') === 'create:basin');

    // ===== 编辑流程的元素行：列表 id 不能和页面里的固定 id 撞名 =====
    // （页面里的 #inputList 是「外设与定义」的输入容器卡片，而且在 DOM 里排在编辑弹窗前面：
    //  el('inputList') 先拿到它，新加的材料行被塞进那个隐藏板块 —— 表现就是“加不了输入材料”。）
    const pageHtml = fs.readFileSync(path.join(frontendDir, 'index.html'), 'utf8');
    const pickerSource = fs.readFileSync(path.join(webDir, 'ifm-picker.js'), 'utf8');
    ['elementInputList', 'elementOutputList'].forEach(function (id) {
        check('editor element list id "' + id + '" does not clash with a page id',
            pageHtml.indexOf('id="' + id + '"') < 0 && contains(pickerSource, "'" + id + "'"));
    });
    // 真跑一遍「+ 添加」：材料行必须落进编辑弹窗的元素列表，而不是页面里的 #inputList
    const lists = {
        inputList: fakeNode(),                    // 页面上的「输入容器」卡片列表（外设与定义）
        elementInputList: fakeNode(),
        elementOutputList: fakeNode()
    };
    context.__lists = lists;
    run(context, 'document.getElementById = function (id) { return __lists[id] || null; };');
    run(context, 'window.ifmAddElement("input")');
    check('ifmAddElement("input") appends to the editor element list',
        lists.elementInputList.children.length === 1 && lists.elementInputList.children[0].parentNode === lists.elementInputList);
    check('ifmAddElement("input") does not touch the page #inputList (input-container card)',
        lists.inputList.children.length === 0);
    run(context, 'window.ifmAddElement("output")');
    check('ifmAddElement("output") appends to the editor output list',
        lists.elementOutputList.children.length === 1);

    finish();
}

main().catch(function (err) {
    console.error(err);
    process.exitCode = 1;
});
