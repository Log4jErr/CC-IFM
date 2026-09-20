// IFM :: frontend/run_dom_smoke.js
// 前端冒烟测试（不需要浏览器）：用一套极小的 DOM/浏览器桩，按 index.html 的顺序原样加载
// web/*.js，然后模拟"在登录页点连接按钮"。
//
//     node run_dom_smoke.js        （在 IFM/frontend/ 下执行）
//
// 它专门抓那种"页面看起来正常、某个按钮却毫无反应"的问题：
//   * 加载期异常（脚本报错后，后面的绑定都不会执行 —— 表现就是按钮全死）；
//   * init() 中途抛错（例如在 bindToolbar 之前就炸了，连接按钮根本没绑上事件）；
//   * 点连接后没有真的建立 WebSocket（connect() 被别的同名函数覆盖 / 提前 return 等）。
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dir = __dirname;
const problems = [];
const notes = [];
const rawHtml = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');

// 像浏览器一样剥掉 HTML 注释：注释里的 <script> 根本不会执行。
// 特别注意"注释没闭合"的情况（少写一个 `-->`）—— 浏览器会把后面整个文件都当成注释吃掉，
// 于是所有脚本都不加载：页面看着正常，点连接按钮毫无反应。这正是 2026-09 报的那个问题，
// 所以这里必须用扫描器实现，而不是一句非贪婪正则（正则碰到未闭合注释会匹配失败、假装没事）。
function stripHtmlComments(text) {
    let out = '';
    let index = 0;
    while (index < text.length) {
        const start = text.indexOf('<!--', index);
        if (start < 0) {
            out += text.slice(index);
            break;
        }
        out += text.slice(index, start);
        const end = text.indexOf('-->', start + 4);
        if (end < 0) {
            return { text: out, unterminated: true };
        }
        index = end + 3;
    }
    return { text: out, unterminated: false };
}
const stripped = stripHtmlComments(rawHtml);
const html = stripped.text;
if (stripped.unterminated) {
    problems.push('index.html has an UNTERMINATED HTML comment (<!-- without -->): ' +
        'everything after it is commented out, so the page loads no scripts at all');
}
if (rawHtml.length !== html.length) {
    notes.push('stripped ' + (rawHtml.length - html.length) + ' chars of HTML comments before reading <script> tags');
}

// index.html 里按顺序引入的本地脚本（跳过 CDN 与 dist/pinyinlite）
const scripts = [];
const scriptRe = /<script[^>]*src="([^"]+)"[^>]*>/g;
let match;
while ((match = scriptRe.exec(html)) !== null) {
    const src = match[1];
    if (/^https?:/.test(src)) continue;
    if (!/^web\//.test(src)) continue;
    scripts.push(src.replace(/\?.*$/, ''));
}

function makeElement(id) {
    const listeners = {};
    let html = '';
    const element = {
        id: id || '',
        tagName: 'DIV',
        value: '',
        textContent: '',
        innerText: '',
        checked: false,
        disabled: false,
        hidden: false,
        placeholder: '',
        title: '',
        className: '',
        href: '',
        src: '',
        type: 'text',
        step: '1',
        min: '0',
        max: '100',
        files: [],
        options: [],
        children: [],
        childNodes: [],
        selectedIndex: 0,
        style: {},
        dataset: {},
        classList: {
            add: function () {}, remove: function () {}, toggle: function () {}, contains: function () { return false; },
        },
        addEventListener: function (type, fn) {
            (listeners[type] = listeners[type] || []).push(fn);
        },
        removeEventListener: function () {},
        dispatch: function (type, event) {
            const list = listeners[type] || [];
            for (let i = 0; i < list.length; i += 1) {
                list[i](event || { type: type, preventDefault: function () {}, stopPropagation: function () {}, target: element });
            }
            return list.length;
        },
        listenerCount: function (type) { return (listeners[type] || []).length; },
        hasListener: function (type) { return (listeners[type] || []).length > 0; },
        appendChild: function (child) { element.children.push(child); return child; },
        removeChild: function () {},
        insertBefore: function (child) { return child; },
        replaceChild: function () {},
        remove: function () {},
        setAttribute: function () {},
        getAttribute: function () { return null; },
        hasAttribute: function () { return false; },
        removeAttribute: function () {},
        focus: function () {},
        blur: function () {},
        click: function () { element.dispatch('click'); },
        getBoundingClientRect: function () {
            return { width: 100, height: 20, top: 0, left: 0, bottom: 20, right: 100, x: 0, y: 0 };
        },
        querySelector: function () { return makeElement('query'); },
        querySelectorAll: function () { return []; },
        closest: function () { return null; },
        contains: function () { return false; },
        scrollIntoView: function () {},
        animate: function () { return { finished: Promise.resolve(), cancel: function () {} }; },
        insertAdjacentHTML: function () {},
        cloneNode: function () { return makeElement(element.id); },
        matches: function () { return false; },
        getContext: function () { return null; },
    };
    // innerHTML / insertAdjacentHTML：像浏览器一样"创建"里面出现的 id（本桩不解析结构，
    // 只登记 id，这样 el('动态生成的 id') 之后就能取到元素）
    Object.defineProperty(element, 'innerHTML', {
        get: function () { return html; },
        set: function (value) {
            html = value === undefined || value === null ? '' : String(value);
            const re = /id="([^"]+)"/g;
            let m;
            while ((m = re.exec(html)) !== null) registerId(m[1]);
        },
    });
    element.insertAdjacentHTML = function (position, value) { element.innerHTML = String(value || ''); };
    return element;
}

const elements = new Map();
// 登记一个 id（index.html 里声明的 / 动态 innerHTML 里出现的）——只有登记过的 id 才"存在"
function registerId(id) {
    if (!id || elements.has(id)) return;
    elements.set(id, makeElement(id));
}
// 像浏览器一样：没登记的 id 一律返回 null（这样 init() 中途遇到缺元素就会真的抛错）
function elementFor(id) {
    return elements.has(id) ? elements.get(id) : null;
}

// index.html 里出现的 id 先建好（并记录），方便区分"HTML 里有"与"JS 动态建"
const declaredIds = new Set();
const idRe = /id="([^"]+)"/g;
while ((match = idRe.exec(html)) !== null) {
    declaredIds.add(match[1]);
    registerId(match[1]);
}
notes.push('index.html declares ' + declaredIds.size + ' element ids');

const sockets = [];
class FakeWebSocket {
    constructor(url) {
        this.url = url;
        this.readyState = 0;
        this.sent = [];
        sockets.push(this);
    }
    send(data) { this.sent.push(data); }
    close() { this.readyState = 3; }
    addEventListener() {}
    removeEventListener() {}
}
FakeWebSocket.CONNECTING = 0;
FakeWebSocket.OPEN = 1;
FakeWebSocket.CLOSING = 2;
FakeWebSocket.CLOSED = 3;

const storage = {
    store: {},
    getItem: function (key) { return Object.prototype.hasOwnProperty.call(storage.store, key) ? storage.store[key] : null; },
    setItem: function (key, value) { storage.store[key] = String(value); },
    removeItem: function (key) { delete storage.store[key]; },
    clear: function () { storage.store = {}; },
    key: function (index) { return Object.keys(storage.store)[index] || null; },
    get length() { return Object.keys(storage.store).length; },
};

const documentStub = {
    readyState: 'complete',
    cookie: '',
    title: '',
    visibilityState: 'visible',
    hidden: false,
    // 脚本清单（pageProbe 会打印它：能一眼看出实际加载的是哪份文件）
    scripts: scripts.map(function (rel) {
        return { src: 'http://localhost/IFM/' + rel + '?v=' + ((rawHtml.match(/\?v=(\d+)/) || [])[1] || '0') };
    }),
    documentElement: makeElement('html'),
    body: makeElement('body'),
    head: makeElement('head'),
    getElementById: function (id) { return elementFor(id); },
    querySelector: function () { return makeElement('query'); },
    querySelectorAll: function () { return []; },
    createElement: function (tag) { const node = makeElement(''); node.tagName = String(tag).toUpperCase(); return node; },
    createElementNS: function () { return makeElement(''); },
    createDocumentFragment: function () { return makeElement('fragment'); },
    createTextNode: function (text) { const node = makeElement(''); node.textContent = text; return node; },
    addEventListener: function () {},
    removeEventListener: function () {},
    dispatchEvent: function () { return true; },
    execCommand: function () {},
};

const sandboxNotes = [];
const bootErrors = [];
const sandboxConsole = {
    log: function () { console.log.apply(console, arguments); },
    info: function () { console.log.apply(console, arguments); },
    debug: function () { console.log.apply(console, arguments); },
    warn: function () {
        const text = Array.prototype.map.call(arguments, String).join(' ');
        bootErrors.push('warn: ' + text);
        console.log('  [page warn] ' + text);
    },
    error: function () {
        const text = Array.prototype.map.call(arguments, String).join(' ');
        bootErrors.push('error: ' + text);
        console.log('  [page error] ' + text);
    },
};

const sandbox = {
    console: sandboxConsole,
    document: documentStub,
    navigator: { userAgent: 'node-dom-smoke', language: 'zh-CN', languages: ['zh-CN'], clipboard: { writeText: function () { return Promise.resolve(); } } },
    location: { href: 'http://localhost/IFM/index.html', search: '', hash: '', origin: 'http://localhost', protocol: 'http:', host: 'localhost', pathname: '/IFM/index.html' },
    localStorage: storage,
    sessionStorage: storage,
    WebSocket: FakeWebSocket,
    URLSearchParams: URLSearchParams,
    URL: URL,
    setTimeout: function () { return 0; },        // 不真的排队：冒烟测试只看"点击当下的反应"
    clearTimeout: function () {},
    setInterval: function () { return 0; },
    clearInterval: function () {},
    requestAnimationFrame: function () { return 0; },
    cancelAnimationFrame: function () {},
    requestIdleCallback: function () { return 0; },
    fetch: function () {
        return Promise.resolve({ ok: false, status: 404, json: function () { return Promise.resolve({}); }, text: function () { return Promise.resolve(''); } });
    },
    getComputedStyle: function () { return { getPropertyValue: function () { return ''; } }; },
    matchMedia: function () { return { matches: false, addEventListener: function () {}, addListener: function () {}, removeEventListener: function () {} }; },
    alert: function () {},
    confirm: function () { return false; },
    prompt: function () { return null; },
    atob: function (value) { return Buffer.from(String(value), 'base64').toString('binary'); },
    btoa: function (value) { return Buffer.from(String(value), 'binary').toString('base64'); },
    Image: class { constructor() { this.onload = null; this.onerror = null; } set src(value) { this._src = value; } get src() { return this._src; } addEventListener() {} },
    MutationObserver: class { observe() {} disconnect() {} },
    DOMParser: class { parseFromString() { return { querySelector: function () { return null; }, querySelectorAll: function () { return []; } }; } },
    XMLHttpRequest: class { open() {} send() {} setRequestHeader() {} addEventListener() {} },
    window: null,               // 下面会指向 sandbox 自己
    addEventListener: function () {},
    removeEventListener: function () {},
    dispatchEvent: function () { return true; },
    scrollTo: function () {},
    focus: function () {},
    blur: function () {},
    close: function () {},
    open: function () { return null; },
    print: function () {},
    stop: function () {},
    history: { pushState: function () {}, replaceState: function () {}, back: function () {} },
    screen: { width: 1920, height: 1080, availWidth: 1920, availHeight: 1080 },
    devicePixelRatio: 1,
    innerWidth: 1920,
    innerHeight: 1080,
    outerWidth: 1920,
    outerHeight: 1080,
    scrollX: 0,
    scrollY: 0,
    performance: { now: function () { return Date.now(); } },
    sandboxSockets: sockets,
    sandboxElements: elements,
    sandboxDeclaredIds: declaredIds,
};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.top = sandbox;
sandbox.parent = sandbox;

const context = vm.createContext(sandbox);

scripts.forEach(function (rel) {
    const file = path.join(dir, rel);
    const code = fs.readFileSync(file, 'utf8');
    try {
        vm.runInContext(code, context, { filename: rel });
    } catch (err) {
        const frame = String(err.stack || '').split('\n')[1] || '';
        problems.push('LOAD ERROR in ' + rel + ': ' + err.message + ' @' + frame.trim());
    }
});
notes.push('loaded ' + scripts.length + ' scripts: ' + scripts.join(', '));
// index.html 里应当引入 10 个 web/*.js（少一个就说明有脚本被注释吃掉了 / 被删了）
if (scripts.length < 10) {
    problems.push('index.html only loads ' + scripts.length + ' of 10 web/*.js scripts ' +
        '(an unclosed HTML comment or a removed <script> tag would do this)');
}

// 1) 连接按钮绑上了吗
const connectBtn = elementFor('connectBtn');
if (!connectBtn || !connectBtn.hasListener('click')) {
    problems.push('connectBtn has NO click listener -> clicking it does nothing (init() threw before bindToolbar)');
} else {
    notes.push('connectBtn click listeners: ' + connectBtn.listenerCount('click'));
}

// 2) 点一下：应当建立一条 WebSocket
const before = sockets.length;
const roomField = elementFor('roomInput');
if (roomField) roomField.value = 'smoke-room';
try {
    connectBtn.click();
} catch (err) {
    problems.push('clicking connectBtn threw: ' + err.message);
}
notes.push('websockets opened by a single click: ' + (sockets.length - before));
if (sockets.length === before && !problems.length) {
    problems.push('clicking connectBtn opened no WebSocket');
}

// 3) 已连接时重复点击不应重复建连
const afterFirst = sockets.length;
connectBtn.click();
connectBtn.click();
notes.push('extra sockets after 2 more clicks: ' + (sockets.length - afterFirst));

// 3b) 中继回声过滤：中继会把我们**自己发出的帧**也回声回来（房间广播包含发送者）。
//     这些帧必须按 uid 丢掉 —— 否则自己请求的回声会被当成响应认领（点了没反应），
//     服务端那种"回声响应"还会被当成 full_sync_start/full_sync_end（列表莫名清空再填回）。
(function checkSelfEchoFilter() {
    const live = sockets[sockets.length - 1];
    if (!live || typeof live.onmessage !== 'function') {
        problems.push('the connected socket has no onmessage handler (cannot verify the echo filter)');
        return;
    }
    if (typeof sandbox.ifmServerLog !== 'function') {
        problems.push('window.ifmServerLog is missing (cannot verify the echo filter)');
        return;
    }
    const frame = function (outer) { return { data: JSON.stringify(outer) }; };
    // 中继给自己的 join 帧带 self=true 与自己的 uid
    live.onmessage(frame({ type: 'join', uid: 'me', self: true, total: 2 }));
    const before = sandbox.ifmServerLog().length;
    // ① 自己 uid 的帧（回声）：必须忽略
    live.onmessage(frame({ type: 'message', uid: 'me', message: JSON.stringify({ action: 'log', lines: ['echo must be ignored'] }) }));
    const afterSelf = sandbox.ifmServerLog().length;
    // ② 别人 uid 的帧（真的服务端日志）：照常处理
    live.onmessage(frame({ type: 'message', uid: 'master', message: JSON.stringify({ action: 'log', lines: ['master log is visible'] }) }));
    const afterOther = sandbox.ifmServerLog().length;
    notes.push('self-echo filter: own frame added ' + (afterSelf - before) + ' log line(s), other member added ' +
        (afterOther - afterSelf));
    if (afterSelf !== before) {
        problems.push('a frame echoed back from our own uid was NOT ignored (it was treated as server data)');
    }
    if (afterOther !== afterSelf + 1) {
        problems.push('a frame from another member was ignored too (the filter is too broad)');
    }
}());

// 4) 其它关键绑定（没有监听器 = 点了没反应）
['disconnectBtn', 'roomInput'].forEach(function (id) {
    const node = elementFor(id);
    if (!node) {
        problems.push('#' + id + ' does not exist in index.html');
        return;
    }
    const any = ['click', 'keydown'].some(function (type) { return node.hasListener(type); });
    if (!any) problems.push('#' + id + ' has no click/keydown listener');
});

// 0) 自检：注释扫描器真的能认出"没闭合的注释"（本次 bug 的形态）
//    否则这个冒烟测试本身也会像浏览器一样被注释骗过去。
(function selfTestCommentScanner() {
    const brokenSample = '<!-- 说明\n<script src="web/ifm-app.js"></script>\n';
    const okSample = '<!-- 说明 -->\n<script src="web/ifm-app.js"></script>\n';
    const broken = stripHtmlComments(brokenSample);
    const ok = stripHtmlComments(okSample);
    if (!broken.unterminated || (broken.text.match(/src="web\//g) || []).length !== 0) {
        problems.push('self-test failed: an unterminated comment must swallow the rest of the file');
    }
    if (ok.unterminated || (ok.text.match(/src="web\//g) || []).length !== 1) {
        problems.push('self-test failed: a properly closed comment must not swallow the script tag');
    }
}());

// 5) 页面自己有没有报"哪一步初始化失败 / 缺哪个元素"
//    （这两个信号以前被静默吞掉：用户只看到"点了没反应"）
bootErrors.forEach(function (line) {
    if (/init step|missing element/i.test(line)) {
        problems.push('the page reported a boot problem: ' + line);
    }
});
const missing = (typeof sandbox.ifmMissingElements === 'function') ? sandbox.ifmMissingElements() : [];
if (missing.length) {
    problems.push('missing element(s) reported by the page: #' + missing.join(', #'));
}
notes.push('boot errors logged by the page: ' + bootErrors.length);

// 5c) 抽象操作 / 抽象流程（用户第 3 项）：注册名 = abstract 的物品/流体元素就是抽象操作；
//     旧的"虚操作"（元素 kind = virtual）必须彻底消失（编辑器不再提供、判定按新规则走）。
(function checkAbstractOps() {
    let probe = null;
    try {
        probe = vm.runInContext([
            '(function () {',
            '  const real = { kind: "item", id: "minecraft:iron_ingot" };',
            '  return {',
            '      item: elementIsAbstract({ kind: "item", id: "abstract" }),',
            '      fluid: elementIsAbstract({ kind: "fluid", id: "abstract" }),',
            '      filter: elementIsAbstract({ kind: "filter", id: "abstract" }),',
            '      real: elementIsAbstract(real),',
            '      process: processIsAbstract({ inputs: [{ kind: "item", id: "abstract" }], outputs: [real] }),',
            '      plain: processIsAbstract({ inputs: [real], outputs: [] }),',
            '      clearFn: typeof window.ifmClearAbstractOps === "function",',
            '      virtualKind: ELEMENT_KINDS.indexOf("virtual") >= 0',
            '  };',
            '}())',
        ].join('\n'), context, { filename: 'abstract-probe' });
    } catch (err) {
        problems.push('the abstract-operation probe failed: ' + err.message);
        return;
    }
    if (!probe.item || !probe.fluid || probe.filter || probe.real) {
        problems.push('elementIsAbstract must only accept item/fluid elements whose registry name is "abstract"');
    }
    if (!probe.process || probe.plain) {
        problems.push('processIsAbstract must detect a process containing an abstract operation');
    }
    if (!probe.clearFn) {
        problems.push('window.ifmClearAbstractOps is missing (the process editor button would do nothing)');
    }
    if (probe.virtualKind) {
        problems.push('the removed "virtual" element kind is still offered by the process editor');
    }
}());

// 5d) 用户第 3 项：机器槽位里"指向已缺失外设"的卡片要标红（chip-missing / slot-missing）——
//     判定来源是服务端的「外设缺失」列表（containers:missingPeripherals）。
(function checkMachineMissingHighlight() {
    let html = '';
    try {
        html = vm.runInContext([
            '(function () {',
            '  const key = containerKeyOf({ kind: "item", name: "basin" });',
            '  stores.containers.set(key, { name: "basin", peripheral: "create:basin", kind: "item", role: "storage" });',
            '  stores.machines.set("mixer", { name: "mixer", type: "smoke_type", parallel: 1, usable: false,',
            '      itemInputs: ["basin"], fluidInputs: [], itemOutputs: [], fluidOutputs: [], signals: [] });',
            '  const withoutMissing = machinesHtml();',
            '  stores.missing.set("container:basin", { kind: "container", containerKind: "item", name: "basin",',
            '      peripheral: "create:basin" });',
            '  const withMissing = machinesHtml();',
            '  stores.missing.delete("container:basin");',
            '  stores.machines.delete("mixer");',
            '  stores.containers.delete(key);',
            '  return { withoutMissing: withoutMissing, withMissing: withMissing };',
            '}())',
        ].join('\n'), context, { filename: 'missing-highlight-probe' });
    } catch (err) {
        problems.push('the machine missing-highlight probe failed: ' + err.message);
        return;
    }
    if (html.withoutMissing.indexOf('chip-missing') >= 0) {
        problems.push('a machine slot must not be flagged as missing while the peripheral is fine');
    }
    if (html.withMissing.indexOf('chip-missing') < 0 || html.withMissing.indexOf('slot-missing') < 0) {
        problems.push('a machine slot pointing at a missing peripheral must get the red chip-missing/slot-missing marks');
    }
}());

// 5b) 流程依赖图（用户第 1/2 项）：
//     * 同一种材料在同一个流程里出现多次（例如 9 条 1x Iron Nugget）→ 只留一条聚合连线；
//     * 材料 → 流程的连线上要标注"这个流程合成一次消耗的此项目总数"（Σ 各条 count）；
//     * 抽象操作（注册名 = abstract）不是真实资源 → 图上连节点都不建。
(function checkGraphEdges() {
    let code = '';
    try {
        code = vm.runInContext([
            '(function () {',
            '  const probe = { name: "smoke_process", machineType: "smoke_type", maxMultiplier: 1,',
            '      inputs: [], outputs: [{ kind: "item", id: "minecraft:iron_ingot", min: 1, max: 1, priority: 0 }] };',
            '  for (let i = 0; i < 9; i += 1) {',
            '      probe.inputs.push({ kind: "item", id: "minecraft:iron_nugget", count: 1 });',
            '  }',
            '  probe.inputs.push({ kind: "item", id: "abstract", count: 1 });',
            '  stores.processes.set(probe.name, probe);',
            '  const graph = buildGraphCode();',
            '  stores.processes.delete(probe.name);',
            '  return graph;',
            '}())',
        ].join('\n'), context, { filename: 'graph-probe' });
    } catch (err) {
        problems.push('buildGraphCode() threw: ' + err.message);
        return;
    }
    const edges = String(code).split('\n').map(function (line) { return line.trim(); })
        .filter(function (line) { return line.indexOf('-->') >= 0; });
    notes.push('graph probe: ' + edges.length + ' edge(s) -> ' + edges.join(' | '));
    if (edges.length !== 2) {
        problems.push('the dependency graph must fold repeated materials into ONE edge per material (expected 2 edges ' +
            'for one input material + one output material, got ' + edges.length + ')');
    }
    const labelled = edges.filter(function (line) { return line.indexOf('|"9x"|') >= 0; });
    if (labelled.length !== 1) {
        problems.push('the material -> process edge must carry the total amount consumed per craft (expected exactly ' +
            'one "9x" edge, got ' + labelled.length + ')');
    }
    // 用户第 2 项：流程 → 产物 的连线也要标注"合成一次产出的总数"（9 条 1x 输入 / 1 条 1x 产物）
    const produced = edges.filter(function (line) { return line.indexOf('|"1x"|') >= 0; });
    if (produced.length !== 1) {
        problems.push('the process -> product edge must carry the total amount produced per craft (expected exactly ' +
            'one "1x" edge, got ' + produced.length + ')');
    }
    if (String(code).indexOf('abstract') >= 0) {
        problems.push('an abstract operation (registry name "abstract") must not be drawn in the dependency graph');
    }
}());

// 6) 构建号三处必须一致：index.html 的 data-ifm-build、web/*.js 的 IFM_APP_BUILD、?v= 缓存号
//    （改前端时若只改了两处，就会出现"页面与脚本不同构建"的半更新状态）
(function checkBuildStamp() {
    const htmlBuild = (rawHtml.match(/data-ifm-build="([^"]+)"/) || [])[1];
    const jsBuild = (fs.readFileSync(path.join(dir, 'web', 'ifm-app.js'), 'utf8')
        .match(/IFM_APP_BUILD = '([^']+)'/) || [])[1];
    const vBuild = (rawHtml.match(/\?v=(\d+)/) || [])[1];
    notes.push('build stamps: index.html=' + String(htmlBuild) + ' js=' + String(jsBuild) + ' ?v=' + String(vBuild));
    if (!htmlBuild || !jsBuild) {
        problems.push('missing build stamp: index.html needs data-ifm-build and web/ifm-app.js needs IFM_APP_BUILD');
    } else if (htmlBuild !== jsBuild || htmlBuild !== vBuild) {
        problems.push('build stamps differ: index.html=' + htmlBuild + ' js=' + jsBuild + ' ?v=' + String(vBuild) +
            ' (bump all three together)');
    }
}());

// 7) 真实解析器检查（jsdom/parse5，与浏览器同规则）—— 这一条才是能抓住
//    "元素写在 HTML 里、但被解析器吞掉了"（引号/`<` 被编码事故吃掉）的检查。
//    文本搜索是抓不住的：曾经 id="sendBtn" 明明在文件里，解析后却不存在。
(function realParseCheck() {
    let JSDOM = null;
    try {
        JSDOM = require('jsdom').JSDOM;
    } catch (err) {
        // 也可以装在 backend/（那里有 package.json，node_modules 更不容易被清掉）
        try {
            JSDOM = require(path.join(dir, '..', 'backend', 'node_modules', 'jsdom')).JSDOM;
        } catch (err2) {
            notes.push('jsdom not installed -> skipped the real-parser check (npm install jsdom --no-save)');
            return;
        }
    }
    // 编码事故（中文变乱码 / 字符丢失）在这里能被发现
    const fffd = (rawHtml.match(/\uFFFD/g) || []).length;
    const mojibake = (rawHtml.match(/[\u9349\u6d29\u9528]\u0000?|\u9500\u9525/g) || []).length;
    if (fffd > 0) {
        problems.push('index.html contains ' + fffd + ' U+FFFD replacement characters (file was re-encoded badly)');
    }
    if (mojibake > 0) {
        problems.push('index.html contains mojibake text (looks like a UTF-8 file was rewritten as ANSI)');
    }

    const dom = new JSDOM(rawHtml);
    const doc = dom.window.document;

    // JS 里静态引用的 id 必须真的解析出来（模板里动态生成的除外）
    const staticIds = new Set();
    const templatedIds = new Set();
    const jsFiles = fs.readdirSync(path.join(dir, 'web')).filter(function (f) { return f.endsWith('.js'); });
    jsFiles.forEach(function (f) {
        const src = fs.readFileSync(path.join(dir, 'web', f), 'utf8');
        let m;
        const re = /(?:el|byId|getElementById)\(\s*'([A-Za-z0-9_\-]+)'\s*\)/g;
        while ((m = re.exec(src)) !== null) staticIds.add(m[1]);
        const re2 = /id="([^"]+)"/g;
        while ((m = re2.exec(src)) !== null) templatedIds.add(m[1]);
    });
    const vanished = Array.from(staticIds).filter(function (id) {
        return !doc.getElementById(id) && !templatedIds.has(id) && !/^fld/.test(id);
    });
    notes.push('real-parser check: ' + staticIds.size + ' ids referenced by JS, ' + vanished.length + ' missing');
    if (vanished.length) {
        problems.push('these ids exist in the JS but not in the parsed DOM: #' + vanished.join(', #') +
            ' (broken markup or a half-updated index.html)');
    }

    // 关键元素点名（连接 / 发送 / 面板）
    ['connectBtn', 'roomInput', 'disconnectBtn', 'sendBtn', 'clearSendBtn', 'sendGrid',
        'clearDeliveriesBtn', 'deliveryPanel', 'workerList', 'workerHint', 'workerLoadBar', 'workerLoadText',
        'peripheralList', 'machineTypeList', 'storageList', 'inputList',
        'missingList', 'filterList', 'settingsBody', 'dispatchInfo', 'editorBody', 'promptInput',
        'stockList', 'diagnoseOutput'].forEach(function (id) {
        if (!doc.getElementById(id)) problems.push('critical element #' + id + ' is missing from the parsed page');
    });
    // 「外设与定义」面板用 class 标记（用户第 1/2/3 项：面板级框选 + 卡片合流布局）——
    // 加 id 会被"结构漂移"检查判成元素搬家，所以这里单独点名这个 class。
    if (!doc.querySelector('.panel.peripheral-panel')) {
        problems.push('the 外设与定义 panel lost its .peripheral-panel class (right-drag selection zone)');
    }
    // 中文是否还原正确（挑两个不会变的）
    if (doc.title.indexOf('集成工厂管理终端') < 0) {
        problems.push('index.html <title> is not valid UTF-8 Chinese: ' + doc.title);
    }
}());

// 9) 与 git 里的版本做DOM 结构比对（只比层级，不比文字/属性）：
//    曾经在重建 index.html 时把整块顺序搞乱（文件尾部出现孤儿 <div>/</header>），
//    浏览器解析出来的 DOM 一塌糊涂、样式全废。这一条能拦住那种事故。
(function structureDriftCheck() {
    let JSDOM = null;
    try {
        JSDOM = require('jsdom').JSDOM;
    } catch (err) {
        try {
            JSDOM = require(path.join(dir, '..', 'backend', 'node_modules', 'jsdom')).JSDOM;
        } catch (err2) {
            notes.push('structure drift check skipped (jsdom missing)');
            return;
        }
    }
    const execFileSync = require('child_process').execFileSync;
    let committed = null;
    try {
        committed = execFileSync('git', ['show', 'HEAD:frontend/index.html'], {
            cwd: path.join(dir, '..'), encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
        });
    } catch (err) {
        notes.push('structure drift check skipped (no git / not a repo)');
        return;
    }
    if (!committed || committed.indexOf('<html') < 0) {
        notes.push('structure drift check skipped (no committed index.html)');
        return;
    }
    const before = new JSDOM(committed).window.document;
    const after = new JSDOM(rawHtml).window.document;
    const chain = function (doc, id) {
        let node = doc.getElementById(id);
        if (!node) return null;
        const parts = [];
        while (node && node.tagName !== '#document') {
            parts.push(node.tagName + (node.id ? '#' + node.id : ''));
            node = node.parentElement;
        }
        return parts.reverse().join('>');
    };
    const ids = [];
    before.querySelectorAll('[id]').forEach(function (node) { ids.push(node.id); });
    // 有意移除的元素（用户要求删掉的）：结构漂移检查里不算问题。
    // saveBtn = 「立即写盘」按钮（用户第 2 项要求移除，写盘交给主控自动做）。
    // refreshBtn / rescanBtn = 「刷新全部数据」与「重新扫描外设」（用户最新要求移除：数据由推送保持最新）。
    const intentionallyRemoved = ['saveBtn', 'compactBtn', 'refreshBtn', 'rescanBtn'];
    const drifted = ids.filter(function (id) {
        if (intentionallyRemoved.indexOf(id) >= 0) return false;
        return chain(before, id) !== chain(after, id);
    });
    const removed = ids.filter(function (id) { return intentionallyRemoved.indexOf(id) >= 0 && !after.getElementById(id); });
    if (removed.length) {
        notes.push('intentionally removed elements: #' + removed.join(', #'));
    }
    notes.push('structure drift vs git HEAD: ' + (ids.length - drifted.length) + '/' + ids.length + ' ids in the same place');
    if (drifted.length) {
        problems.push('index.html structure drifted from the committed version: #' + drifted.slice(0, 8).join(', #') +
            (drifted.length > 8 ? ' …' : '') + ' (elements moved to another parent - the page will look broken)');
    }
}());

console.log('--- notes ---');
notes.forEach(function (line) { console.log('  ' + line); });
if (problems.length) {
    console.log('--- problems ---');
    problems.forEach(function (line) { console.log('  FAIL ' + line); });
    console.log('\n' + problems.length + ' problem(s)');
    process.exit(1);
}
console.log('\nDOM smoke test passed: login page, connect button and core bindings are alive');
