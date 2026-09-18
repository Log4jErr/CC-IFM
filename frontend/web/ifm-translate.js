// IFM :: web/ifm-translate.js
// 物品名翻译（英 → 简体中文）：用 Bergamot（@browsermt/bergamot-translator 的 WebAssembly 版 Marian NMT）
// 在浏览器端**离线**翻译。blocksitems 接口只给英文名，所以这里把英文显示名翻成中文，
// 供资源网格 / 悬停详情 / 库存选择器显示；搜索时**翻译前后都能搜到**（见主脚本的 matchesSearch）。
//
// 说明：
//  * 模型取自 Mozilla 的翻译数据桶（与 Firefox 本地翻译同款）：清单是
//      https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json
//    Mozilla 重新生成过这份清单，结构与文件格式都变了：
//      models["en-zh"] = [ { releaseStatus, architecture, files: { model:{path,uncompressedSize},
//                            srcVocab:{path}, trgVocab:{path}, lexicalShortlist:{path} } } ]
//    文件一律是 .gz（桶里没有未压缩版），所以下载后要在浏览器端解压
//    （DecompressionStream；首次约 30MB 压缩 → 43MB 解压，之后走浏览器缓存）。
//    旧结构（Remote Settings records / 旧版桶清单）仍然兼容，见 normalizeManifest。
//  * wasm 运行时取自 jsDelivr 上的 @browsermt/bergamot-translator@0.4.9/worker/bergamot-translator-worker.js。
//  * 翻译结果缓存在 localStorage：翻过的名字不会再翻第二次（页面刷新也保留）。
//  * 全部是**懒加载**：开关关闭时不会下载任何东西，也不会发任何请求。
(function () {
    'use strict';

    const WASM_BASE = 'https://cdn.jsdelivr.net/npm/@browsermt/bergamot-translator@0.4.9/worker/';
    // 模型清单：Firefox 翻译数据桶（Mozilla 自己发布的那份 db/models.json）。
    // 旧的 Remote Settings records 接口内容等价、结构不同；normalizeManifest 三种结构都认。
    const RECORDS_URL = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json';
    const ATTACH_BASE = 'https://firefox-settings-attachments.cdn.mozilla.net/';
    const STORAGE_ENABLED = 'ifm_translate_enabled';
    const STORAGE_CACHE = 'ifm_translate_cache_v1';
    const STORAGE_MODEL = 'ifm_translate_model_v1';
    const MAX_CACHE_ENTRIES = 4000;
    const BATCH_SIZE = 8;
    // Marian 参数：与 bergamot 官方示例一致（单批、int8 GEMM，速度与 Mozilla 模型匹配）
    const MODEL_CONFIG = [
        'beam-size: 1',
        'normalize: 1.0',
        'word-penalty: 0',
        'alignment: soft',
        'max-length-break: 128',
        'mini-batch-words: 1024',
        'workspace: 128',
        'max-length-factor: 2.0',
        'skip-cost: true',
        'gemm-precision: int8shiftAll',
    ].join('\n');

    let enabled = false;
    let status = 'off';        // off | loading | ready | failed
    let message = '';
    let progress = null;       // {received, total}
    let engine = null;         // Emscripten Module（含 AlignedMemory / TranslationModel / TranslationService）
    let enginePromise = null;
    let modelPromise = null;
    let service = null;
    let model = null;
    const cache = {};          // 英文显示名 -> 中文
    const pending = [];        // 待翻译的英文显示名
    let translating = false;
    let saveTimer = null;

    function notify() {
        if (typeof window.ifmOnTranslateUpdate === 'function') window.ifmOnTranslateUpdate();
    }

    function readJson(key) {
        try {
            const raw = localStorage.getItem(key);
            return raw ? JSON.parse(raw) : null;
        } catch (err) {
            return null;
        }
    }

    function writeJson(key, value) {
        try {
            localStorage.setItem(key, JSON.stringify(value));
        } catch (err) { /* 隐私模式 / 配额满：忽略即可，翻译仍能用，只是不持久化 */ }
    }

    function loadState() {
        try {
            enabled = localStorage.getItem(STORAGE_ENABLED) === '1';
        } catch (err) {
            enabled = false;
        }
        const saved = readJson(STORAGE_CACHE);
        if (saved && saved.items && typeof saved.items === 'object') {
            Object.keys(saved.items).forEach(function (key) {
                if (typeof saved.items[key] === 'string' && saved.items[key]) cache[key] = saved.items[key];
            });
        }
    }

    function saveCacheSoon() {
        if (saveTimer) return;
        saveTimer = setTimeout(function () {
            saveTimer = null;
            saveCache();
        }, 2000);
    }

    function saveCache() {
        const keys = Object.keys(cache);
        // 超出上限时丢掉最早的条目（对象键顺序即插入顺序）
        if (keys.length > MAX_CACHE_ENTRIES) {
            keys.slice(0, keys.length - MAX_CACHE_ENTRIES).forEach(function (key) { delete cache[key]; });
        }
        writeJson(STORAGE_CACHE, { version: 1, items: cache });
    }
    // ===================== 运行时与模型加载 =====================

    function loadScript(url) {
        return new Promise(function (resolve, reject) {
            const node = document.createElement('script');
            node.src = url;
            node.async = true;
            node.onload = function () { resolve(); };
            node.onerror = function () { reject(new Error('无法加载 ' + url)); };
            document.head.appendChild(node);
        });
    }

    function withTimeout(promise, ms, text) {
        return new Promise(function (resolve, reject) {
            const timer = setTimeout(function () { reject(new Error(text)); }, ms);
            promise.then(function (value) {
                clearTimeout(timer);
                resolve(value);
            }, function (err) {
                clearTimeout(timer);
                reject(err);
            });
        });
    }

    // 带进度的二进制下载（模型文件较大，界面上要能看到进度）。
    // 顺带看门：60 秒内一个字节都没涨（CDN 卡死 / 被墙）就报错，别让界面永远停在“正在加载”。
    async function fetchBytes(url) {
        const response = await fetch(url);
        if (!response.ok) throw new Error('HTTP ' + response.status + ' ' + url);
        const total = Number(response.headers.get('content-length')) || 0;
        if (!response.body || typeof response.body.getReader !== 'function') {
            const buffer = await response.arrayBuffer();
            addProgress(buffer.byteLength, total || buffer.byteLength);
            return new Uint8Array(buffer);
        }
        const reader = response.body.getReader();
        const chunks = [];
        let received = 0;
        let lastGrowth = Date.now();
        let lastSeen = 0;
        const watchdog = setInterval(function () {
            if (received !== lastSeen) {
                lastSeen = received;
                lastGrowth = Date.now();
            } else if (Date.now() - lastGrowth > 60000) {
                clearInterval(watchdog);
                try { reader.cancel(); } catch (err) { /* 忽略 */ }
                console.warn('[IFM] 下载卡住 60 秒：' + url);
            }
        }, 5000);
        try {
            for (;;) {
                const result = await reader.read();
                if (result.done) break;
                chunks.push(result.value);
                received += result.value.length;
                addProgress(result.value.length, total);
                if (received === lastSeen) lastSeen = received;      // 有进展就刷新看门狗
            }
        } finally {
            clearInterval(watchdog);
        }
        const out = new Uint8Array(received);
        let offset = 0;
        chunks.forEach(function (chunk) {
            out.set(chunk, offset);
            offset += chunk.length;
        });
        return out;
    }

    function addProgress(bytes, total) {
        if (!progress) progress = { received: 0, total: 0 };
        progress.received += bytes;
        if (total) progress.total += total;
        notify();
    }

    // 运行时（wasm + 胶水代码）：**本地优先**（frontend/web/bergamot/，随前端一起部署），
    // 本地缺失/打不开才退回 jsDelivr —— 以前每次都从 CDN 拉 ~10MB，慢或被墙时界面就卡在
    // “正在加载翻译引擎”，看起来像“下载进度卡住”。
    const LOCAL_WASM_BASE = 'web/bergamot/';

    async function fetchRuntime() {
        const failures = [];
        const bases = [LOCAL_WASM_BASE, WASM_BASE];
        for (let index = 0; index < bases.length; index += 1) {
            const base = bases[index];
            try {
                const wasmBinary = await fetchBytes(base + 'bergamot-translator-worker.wasm');
                console.info('[IFM] 翻译引擎来源：' + base);
                return { base: base, wasmBinary: wasmBinary };
            } catch (err) {
                failures.push(base + ' → ' + ((err && err.message) || err));
                progress = { received: 0, total: 0 };
                notify();
            }
        }
        throw new Error('翻译引擎下载失败：' + failures.join(' | '));
    }

    // bergamot 的 wasm 依赖一个名为 `wasm_gemm` 的**导入模块**（intgemm 的 int8 函数）。
    // 官方用法是在 Web Worker 里跑 worker/translator-worker.js，由它把这个模块补进 import 对象
    // （native: Firefox 的 WebAssembly.mozIntGemm；否则用 wasm 自己导出的 *Fallback 函数重映射）。
    // 我们为了进度条直接在主页面加载胶水代码，所以必须自己补上这一步 ——
    // 少了它浏览器会直接报：import object field 'wasm_gemm' is not an Object（见 GEMM_MAP）。
    const GEMM_MAP = {
        'int8_prepare_a': 'int8PrepareAFallback',
        'int8_prepare_b': 'int8PrepareBFallback',
        'int8_prepare_b_from_transposed': 'int8PrepareBFromTransposedFallback',
        'int8_prepare_b_from_quantized_transposed': 'int8PrepareBFromQuantizedTransposedFallback',
        'int8_prepare_bias': 'int8PrepareBiasFallback',
        'int8_multiply_and_add_bias': 'int8MultiplyAndAddBiasFallback',
        'int8_select_columns_of_b': 'int8SelectColumnsOfBFallback',
    };

    /** wasm 里自带的朴素 int8 gemm（导出名 int8*Fallback），按 gemm 期望的名字重新映射 */
    function fallbackGemm() {
        const out = {};
        Object.keys(GEMM_MAP).forEach(function (name) {
            out[name] = function () {
                const asm = window.Module && window.Module.asm;
                const target = asm && asm[GEMM_MAP[name]];
                if (!target) throw new Error('wasm 里没有 ' + GEMM_MAP[name]);
                return target.apply(null, arguments);
            };
        });
        return out;
    }

    /** 给 emscripten 的 import 对象补上 wasm_gemm（优先用 Firefox 的 mozIntGemm，失败就退回朴素实现） */
    function withWasmGemm(imports) {
        let gemm = null;
        if (WebAssembly.mozIntGemm) {
            try {
                const instance = new WebAssembly.Instance(WebAssembly.mozIntGemm(), {
                    '': { memory: imports.env && imports.env.memory },
                });
                const missing = Object.keys(GEMM_MAP).filter(function (name) {
                    return !instance.exports[name];
                });
                if (missing.length === 0) gemm = instance.exports;
                else console.warn('[bergamot] 原生 intgemm 缺少函数，改用 wasm 内置实现');
            } catch (err) {
                console.warn('[bergamot] mozIntGemm 不可用（' + ((err && err.message) || err) + '），改用 wasm 内置实现');
            }
        }
        if (!gemm) gemm = fallbackGemm();
        return Object.assign({}, imports, { wasm_gemm: gemm });
    }

    async function ensureEngine() {
        if (engine) return engine;
        if (enginePromise) return enginePromise;
        enginePromise = (async function () {
            progress = { received: 0, total: 0 };
            message = 'translateLoadingRuntime';
            notify();
            const runtime = await fetchRuntime();
            let runtimeReady;
            const ready = new Promise(function (resolve) { runtimeReady = resolve; });
            // Emscripten 胶水代码必须在执行前就在全局看到 Module（含 wasmBinary）
            const moduleRef = {
                wasmBinary: runtime.wasmBinary,
                print: function (text) { console.log('[bergamot] ' + text); },
                printErr: function (text) { console.warn('[bergamot] ' + text); },
                /**
                 * 自己实例化 wasm：这样才来得及把 wasm_gemm 塞进 import 对象。
                 * （返回 {} 是 emscripten 约定的“实例化是异步的，等 accept 回调”。）
                 */
                instantiateWasm: function (imports, accept) {
                    WebAssembly.instantiate(runtime.wasmBinary, withWasmGemm(imports))
                        .then(function (result) { accept(result.instance); })
                        .catch(function (err) {
                            console.error('[bergamot] wasm 实例化失败：' + ((err && err.message) || err));
                            message = 'translateError';
                            status = 'failed';
                            notify();
                        });
                    return {};
                },
                onRuntimeInitialized: function () { runtimeReady(); },
            };
            window.Module = moduleRef;
            await loadScript(runtime.base + 'bergamot-translator-worker.js');
            await withTimeout(ready, 30000, '翻译引擎初始化超时（wasm 没能启动：检查 web/bergamot/ 是否随前端一起部署）');
            engine = moduleRef;
            return engine;
        })().catch(function (err) {
            enginePromise = null;
            throw err;
        });
        return enginePromise;
    }
    // 清单里的文件地址（相对路径）：优先用清单自己给的 baseUrl（2025 起的新结构带这个字段），
    // 没有就按清单来源推：Google 桶清单与附件同源，Remote Settings 的附件走 CDN。
    function attachmentUrl(location, baseUrl) {
        if (!location) return '';
        if (/^[a-z]+:\/\//i.test(location)) return location;
        const root = baseUrl || (RECORDS_URL.indexOf('storage.googleapis.com') >= 0
            ? RECORDS_URL.replace(/\/[^\/]*$/, '/')
            : ATTACH_BASE);
        return String(root).replace(/\/?$/, '/') + String(location).replace(/^\.?\//, '');
    }

    // 把清单摊平成统一记录：{ group, fileType, location, size, from, to, release, architecture }
    // group 用来把“同一个语言对条目”的文件归到一起（新旧结构都可能有多个候选，见 modelFileSets）。
    // 支持三代结构：
    //   * 现行（Mozilla 重新生成的桶清单）：
    //       { baseUrl, models: { "en-zh": [ { sourceLanguage, targetLanguage, releaseStatus,
    //         architecture, files: { model: { path, uncompressedSize }, srcVocab: { path },
    //         trgVocab: { path }, lexicalShortlist: { path } } } ] } }
    //     —— 词表拆成了 srcVocab / trgVocab，文件一律是 .gz（桶里没有未压缩版）。
    //   * 旧版桶清单：{ "en-zh": { model: { location }, vocab: { location }, lex: { location } } }
    //   * Remote Settings：{ data: [ { fileType, attachment, fromLang, toLang, name } ] }
    function normalizeManifest(body) {
        const out = [];
        const typeOf = function (name) {
            if (name === 'model') return 'model';
            if (name === 'vocab' || name === 'srcVocab') return 'vocab';
            if (name === 'trgVocab') return 'vocabTrg';
            if (name === 'lex' || name === 'lexicalShortlist') return 'lex';
            return '';
        };
        const addFile = function (group, fileType, info, baseUrl, extra) {
            const location = info && (info.location || info.path);
            if (!fileType || !location) return;
            out.push(Object.assign({
                group: group,
                fileType: fileType,
                location: attachmentUrl(location, baseUrl),
                size: Number(info.size || info.uncompressedSize) || 0,
                from: '', to: '', release: '', architecture: ''
            }, extra || {}));
        };

        if (body && typeof body === 'object' && body.models && typeof body.models === 'object') {
            // 现行结构：一个语言对可以有多个候选（不同 architecture / 是否 Release）
            Object.keys(body.models).forEach(function (pair) {
                const entries = Array.isArray(body.models[pair]) ? body.models[pair] : [body.models[pair]];
                entries.forEach(function (entry, index) {
                    if (!entry || typeof entry !== 'object' || !entry.files) return;
                    const group = pair + '#' + index;
                    const extra = {
                        from: entry.sourceLanguage || '',
                        to: entry.targetLanguage || '',
                        release: entry.releaseStatus || '',
                        architecture: entry.architecture || ''
                    };
                    Object.keys(entry.files).forEach(function (name) {
                        addFile(group, typeOf(name), entry.files[name], body.baseUrl, extra);
                    });
                });
            });
            return out;
        }

        // 旧版桶清单：顶层键就是语言对
        Object.keys(body || {}).forEach(function (pair) {
            const value = body[pair];
            if (!value || typeof value !== 'object') return;
            const langs = String(pair).split('-');
            Object.keys(value).forEach(function (name) {
                addFile('pair#' + pair, typeOf(name), value[name], '',
                    { from: langs[0] || '', to: langs[1] || '' });
            });
        });

        // Remote Settings：顶层数组或 { data: [...] } —— 一条记录就是**一个文件**，
        // 所以同一语言对的文件要归到同一个 group（否则每个文件各成一组，拼不出完整模型）。
        const records = Array.isArray(body) ? body : (body && Array.isArray(body.data) ? body.data : []);
        records.forEach(function (record, index) {
            if (!record || typeof record !== 'object') return;
            const fileType = typeOf(record.fileType) || record.fileType || '';
            const from = record.fromLang || '';
            const to = record.toLang || '';
            addFile('lang#' + from + '-' + to, fileType, record.attachment || '', '',
                { from: from, to: to });
        });
        return out;
    }

    // 从记录里拼出可用的「文件组」：一组 = 一个语言对条目（model + 词表 [+ 短名单]）。
    // 排序与 Firefox 的挑选规则一致：Release 优先，其次是 architecture == 'base'；
    // 排在后面的组是“前面那个加载失败时的备选”（例如 base-memory 在当前 wasm 上构造不出来）。
    function modelFileSets(records) {
        const groups = new Map();
        records.forEach(function (record) {
            if (record.from !== 'en' || (record.to !== 'zh' && record.to !== 'zh-Hans')) return;
            if (!groups.has(record.group)) groups.set(record.group, []);
            groups.get(record.group).push(record);
        });
        const sets = [];
        groups.forEach(function (items, group) {
            const byType = {};
            items.forEach(function (record) {
                if (!byType[record.fileType]) byType[record.fileType] = record;
            });
            if (!byType.model) return;
            // 现行模型是「分词表分离」的（srcVocab + trgVocab）；老模型只有一个 vocab
            const vocabs = [];
            if (byType.vocab) vocabs.push(byType.vocab.location);
            if (byType.vocabTrg) vocabs.push(byType.vocabTrg.location);
            if (vocabs.length === 0) return;
            sets.push({
                group: group,
                model: byType.model.location,
                vocabs: vocabs,
                shortlist: byType.lex ? byType.lex.location : '',
                size: items.reduce(function (sum, record) { return sum + (record.size || 0); }, 0),
                release: items.some(function (record) { return record.release === 'Release'; }),
                base: items.some(function (record) { return record.architecture === 'base'; })
            });
        });
        sets.sort(function (a, b) {
            if (a.release !== b.release) return a.release ? -1 : 1;
            if (a.base !== b.base) return a.base ? -1 : 1;
            return 0;
        });
        return sets;
    }

    // ===== 模型文件来源：**本地优先** =====
    // 把 Mozilla 的模型随前端一起发布（frontend/web/models/en-zh/）时优先用它：
    // 走本机/局域网，比从 Google 存储桶拉 33MB 快得多，也不依赖外网。
    // 本地没有（或本地文件坏了，见 ensureModel 的回退）时才去请求 Mozilla 清单。
    const LOCAL_MODEL_DIR = 'web/models/en-zh/';
    const LOCAL_MODEL_FILES = {
        model: 'model.enzh.bin.gz',
        vocabs: ['srcvocab.enzh.spm.gz', 'trgvocab.enzh.spm.gz'],
        shortlist: 'lex.enzh.s2t.bin.gz',
    };
    let localModelChecked = false;     // 是否已经探测过
    let localModelUsable = false;

    function localModelSet() {
        const prefix = LOCAL_MODEL_DIR;
        return {
            group: 'local',
            local: true,
            model: prefix + LOCAL_MODEL_FILES.model,
            vocabs: LOCAL_MODEL_FILES.vocabs.map(function (name) { return prefix + name; }),
            shortlist: prefix + LOCAL_MODEL_FILES.shortlist,
            size: 0,
            release: true,
            base: true,
        };
    }

    // 本地模型在不在？先 HEAD 探主模型（33MB 的 GET 太浪费）；有些静态服务器禁用 HEAD，
    // 那就用一个很小的词表文件 GET 兜底判断。
    async function localModelAvailable() {
        if (localModelChecked) return localModelUsable;
        localModelChecked = true;
        const probe = async function (url, method) {
            try {
                const response = await fetch(url, method === 'HEAD' ? { method: 'HEAD' } : undefined);
                return !!response.ok;
            } catch (err) {
                return false;
            }
        };
        localModelUsable = (await probe(localModelSet().model, 'HEAD'))
            || (await probe(LOCAL_MODEL_DIR + LOCAL_MODEL_FILES.vocabs[0], 'GET'));
        if (localModelUsable) {
            console.info('[IFM] 使用本地翻译模型：' + LOCAL_MODEL_DIR);
        }
        return localModelUsable;
    }

    // 远端：Mozilla 清单 → 挑出 en→zh 的候选文件组（结果记在 localStorage，一周内不重复请求）
    async function resolveRemoteModelFiles() {
        const cached = readJson(STORAGE_MODEL);
        if (cached && Array.isArray(cached.sets) && cached.sets.length > 0 &&
            (Date.now() - (cached.at || 0) < 7 * 24 * 3600 * 1000)) {
            return cached;
        }
        const response = await fetch(RECORDS_URL);
        if (!response.ok) throw new Error('无法获取模型清单（HTTP ' + response.status + '）');
        const sets = modelFileSets(normalizeManifest(await response.json()));
        if (sets.length === 0) {
            throw new Error('模型清单里没有 English→中文 的模型（需要 en-zh 的 model 与词表）');
        }
        const files = { at: Date.now(), sets: sets };
        writeJson(STORAGE_MODEL, files);
        return files;
    }

    // 模型清单：本地优先，缺失时才走远端清单
    async function resolveModelFiles() {
        if (await localModelAvailable()) {
            return { at: Date.now(), sets: [localModelSet()] };
        }
        return resolveRemoteModelFiles();
    }

    // Mozilla 的模型文件全是 .gz（桶里没有未压缩版），解压后再交给 wasm
    async function maybeGunzip(bytes, url) {
        if (!/\.gz$/i.test(url)) return bytes;
        if (typeof DecompressionStream !== 'function') {
            throw new Error('这个浏览器不支持 gzip 解压（DecompressionStream）：' +
                '请用较新的 Chrome / Edge / Firefox / Safari');
        }
        const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    function createService(api) {
        // 0.4.9 的 wasm 里导出的类是 **BlockingService**（官方 worker/translator-worker.js 就是这么用的：
        //   new this.module.BlockingService({ cacheSize })）；
        // 旧版/别的构建才叫 TranslationService。以前只试 TranslationService，于是加载模型时
        // 报 “api.TranslationService is not a constructor”，本地模型白白下载完却用不了（1.6.9 修）。
        const attempts = [
            ['BlockingService', [{ cacheSize: 0 }]],
            ['BlockingService', []],
            ['TranslationService', [{ cacheSize: 0 }]],
            ['TranslationService', []],
            ['TranslationService', [1, 0]],
        ];
        const construct = function (Ctor, args) {
            if (args.length === 0) return new Ctor();
            if (args.length === 1) return new Ctor(args[0]);
            return new Ctor(args[0], args[1]);
        };
        let lastError = null;
        const tried = [];
        for (let index = 0; index < attempts.length; index += 1) {
            const name = attempts[index][0];
            const Ctor = api && api[name];
            if (typeof Ctor !== 'function') continue;
            try {
                return construct(Ctor, attempts[index][1]);
            } catch (err) {
                lastError = err;
                tried.push(name + ': ' + ((err && err.message) || err));
            }
        }
        throw new Error('翻译引擎里没有可用的服务类（BlockingService / TranslationService）' +
            (tried.length ? '：' + tried.join(' | ') : '') +
            (lastError ? '' : '（wasm 可能没加载成功）'));
    }

    // 加载一个候选文件组：下载 → 解压 → 建 TranslationModel + TranslationService
    async function loadModelSet(api, files) {
        // 进度条总量按每个响应的 content-length 累加（压缩后大小），所以比例是估算值
        progress = { received: 0, total: 0 };
        notify();
        const modelBytes = await maybeGunzip(await fetchBytes(files.model), files.model);
        const vocabBytes = [];
        for (let index = 0; index < files.vocabs.length; index += 1) {
            const url = files.vocabs[index];
            vocabBytes.push(await maybeGunzip(await fetchBytes(url), url));
        }
        let shortlistBytes = null;
        if (files.shortlist) {
            try {
                shortlistBytes = await maybeGunzip(await fetchBytes(files.shortlist), files.shortlist);
            } catch (err) {
                // 短名单只是加速用：拿不到也能翻译，忽略
                console.warn('[IFM] 未能下载 shortlist（lex）文件，翻译会稍慢：' + err.message);
            }
        }
        const toMemory = function (bytes, alignment) {
            if (!bytes) return null;
            const memory = new api.AlignedMemory(bytes.length, alignment);
            memory.getByteArrayView().set(bytes);
            return memory;
        };
        const modelMem = toMemory(modelBytes, 256);
        const shortlistMem = toMemory(shortlistBytes, 64);
        const vocabs = new api.AlignedMemoryList();
        vocabBytes.forEach(function (bytes) { vocabs.push_back(toMemory(bytes, 64)); });
        model = new api.TranslationModel(MODEL_CONFIG, modelMem, shortlistMem, vocabs, null);
        service = createService(api);
    }

    async function ensureModel() {
        if (model && service) return;
        if (modelPromise) return modelPromise;
        modelPromise = (async function () {
            const api = await ensureEngine();
            let sets = (await resolveModelFiles()).sets;
            message = 'translateLoadingModel';
            notify();
            const failures = [];
            let triedRemote = sets.some(function (set) { return !set.local; });
            // 可能有多条候选（本地 / 多种 architecture）：逐个试，第一个能构造出来的就算成功
            for (let index = 0; index < sets.length; index += 1) {
                const files = sets[index];
                try {
                    await loadModelSet(api, files);
                    console.info('[IFM] 翻译模型已加载：' + files.group +
                        '（release=' + files.release + ', base=' + files.base + '）');
                    progress = null;
                    notify();
                    return;
                } catch (err) {
                    // 失败时清掉半成品，避免之后被当成“已经加载好了”
                    model = null;
                    service = null;
                    failures.push(files.group + ': ' + ((err && err.message) || err));
                    console.warn('[IFM] 模型 ' + files.group + ' 加载失败，试下一个候选：' + err);
                    // 本地模型坏了 / 不完整：自动退回 Mozilla 清单再试一遍（只回退一次）
                    if (files.local && !triedRemote) {
                        triedRemote = true;
                        try {
                            const remote = await resolveRemoteModelFiles();
                            sets = sets.concat(remote.sets);
                            console.info('[IFM] 本地模型不可用，改用 Mozilla 清单（' + remote.sets.length + ' 个候选）');
                        } catch (remoteErr) {
                            // Mozilla 的清单放在 Google 存储桶上，**没有 CORS 头** —— 浏览器会直接拦下这次请求
                            // （控制台里那条 “CORS Missing Allow Origin” 就是它）。所以本地模型缺失时，
                            // 唯一可靠的办法是手动把模型放到 web/models/en-zh/ 下，而不是靠远端回退。
                            failures.push('remote manifest: ' + ((remoteErr && remoteErr.message) || remoteErr) +
                                '（Mozilla 清单不允许跨域读取：请把模型放到 ' + LOCAL_MODEL_DIR + ' 下）');
                        }
                    }
                }
            }
            progress = null;
            throw new Error('所有候选模型都无法加载（' + failures.join(' / ') + '）');
        })().catch(function (err) {
            modelPromise = null;
            throw err;
        });
        return modelPromise;
    }
    // ===================== 翻译 =====================

    // 物品名是短语而不是句子：去掉模型可能补上的尾随标点与多余空格
    function tidy(text) {
        return String(text || '')
            .replace(/\s+/g, ' ')
            .replace(/[\s。．，,、；;：:!！?？"'“”‘’]+$/g, '')
            .trim();
    }

    function translateBatch(texts) {
        const input = new engine.VectorString();
        texts.forEach(function (text) { input.push_back(text); });
        const options = new engine.VectorResponseOptions();
        texts.forEach(function () { options.push_back({ alignment: false, html: false, qualityScores: false }); });
        let output = null;
        try {
            output = service.translate(model, input, options);
            const out = [];
            for (let index = 0; index < output.size(); index += 1) {
                out.push(tidy(output.get(index).getTranslatedText()));
            }
            return out;
        } finally {
            try { input.delete(); } catch (err) { /* ignore */ }
            try { options.delete(); } catch (err) { /* ignore */ }
            if (output) {
                try { output.delete(); } catch (err) { /* ignore */ }
            }
        }
    }

    async function pump() {
        if (translating || status !== 'ready' || pending.length === 0) return;
        translating = true;
        try {
            while (pending.length > 0) {
                const batch = pending.splice(0, BATCH_SIZE);
                const translated = translateBatch(batch);
                batch.forEach(function (name, index) {
                    const text = translated[index];
                    if (text) cache[name] = text;
                });
                saveCacheSoon();
                notify();
                // 让出主线程：一次翻上百个名字时界面依然可用
                await new Promise(function (resolve) { setTimeout(resolve, 0); });
            }
        } catch (err) {
            status = 'failed';
            message = '翻译失败：' + ((err && err.message) || err);
            notify();
        } finally {
            translating = false;
        }
    }

    // 交给翻译模型的文本**只能是“英文显示名”**：绝不能把模组名/注册名（create:andesite_casing）
    // 或下划线原样丢给模型（翻出来的东西会莫名其妙）。调用方通常已经传了 display_name，
    // 这里再兜一层：去掉命名空间前缀、下划线换空格（"create:andesite_casing" → "andesite casing"）。
    function cleanTranslateInput(text) {
        let value = String(text === undefined || text === null ? '' : text).trim();
        if (!value) return '';
        if (value.indexOf(':') >= 0) value = value.split(':').pop();
        return value.replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
    }

    function queueNames(names) {
        if (!enabled || status !== 'ready') return;
        let added = false;
        (names || []).forEach(function (name) {
            const text = cleanTranslateInput(name);
            if (!text || cache[text] || pending.indexOf(text) >= 0) return;
            pending.push(text);
            added = true;
        });
        if (added) pump();
    }

    async function start() {
        if (status === 'loading' || status === 'ready') return;
        status = 'loading';
        message = 'translateLoading';
        notify();
        try {
            await ensureModel();
            status = 'ready';
            message = 'translateReady';
            notify();
            pump();
        } catch (err) {
            status = 'failed';
            message = '翻译不可用：' + ((err && err.message) || err);
            notify();
        }
    }

    function setEnabled(on) {
        enabled = !!on;
        try {
            localStorage.setItem(STORAGE_ENABLED, enabled ? '1' : '0');
        } catch (err) { /* ignore */ }
        if (enabled) {
            start();
        } else if (status !== 'ready') {
            status = 'off';
            message = '';
        }
        notify();
    }

    window.IFMTranslate = {
        isEnabled: function () { return enabled; },
        status: function () { return status; },
        message: function () { return message; },
        progressPercent: function () {
            if (!progress || !progress.total) return null;
            return Math.max(1, Math.min(99, Math.round(progress.received / progress.total * 100)));
        },
        nameFor: function (englishName) {
            if (!enabled || !englishName) return null;
            return cache[englishName] || null;
        },
        queueNames: queueNames,
        translatedCount: function () { return Object.keys(cache).length; },
        setEnabled: setEnabled,
        clearCache: function () {
            Object.keys(cache).forEach(function (key) { delete cache[key]; });
            saveCache();
            notify();
        },
        init: function () {
            loadState();
            if (enabled) start();
        },
    };
})();
