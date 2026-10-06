(function () {
    'use strict';

    const WASM_BASE = 'https://cdn.jsdelivr.net/npm/@browsermt/bergamot-translator@0.4.9/worker/';
    const RECORDS_URL = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/db/models.json';
    const ATTACH_BASE = 'https://firefox-settings-attachments.cdn.mozilla.net/';
    const STORAGE_ENABLED = 'ifm_translate_enabled';
    const STORAGE_CACHE = 'ifm_translate_cache_v1';
    const STORAGE_MODEL = 'ifm_translate_model_v1';
    const MAX_CACHE_ENTRIES = 4000;
    const BATCH_SIZE = 8;
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
    let status = 'off';
    let message = '';
    let progress = null;
    let engine = null;
    let enginePromise = null;
    let modelPromise = null;
    let service = null;
    let model = null;
    const cache = {};
    const pending = [];
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
        } catch (err) {  }
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
        if (keys.length > MAX_CACHE_ENTRIES) {
            keys.slice(0, keys.length - MAX_CACHE_ENTRIES).forEach(function (key) { delete cache[key]; });
        }
        writeJson(STORAGE_CACHE, { version: 1, items: cache });
    }

    function loadScript(url) {
        return new Promise(function (resolve, reject) {
            const node = document.createElement('script');
            node.src = url;
            node.async = true;
            node.onload = function () { resolve(); };
            node.onerror = function () { reject(new Error(t('translateLoadScriptFailed', { url: url }))); };
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
                try { reader.cancel(); } catch (err) {  }
                console.warn('[IFM] download stalled for 60s: ' + url);
            }
        }, 5000);
        try {
            for (;;) {
                const result = await reader.read();
                if (result.done) break;
                chunks.push(result.value);
                received += result.value.length;
                addProgress(result.value.length, total);
                if (received === lastSeen) lastSeen = received;
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

    const LOCAL_WASM_BASE = 'web/bergamot/';

    async function fetchRuntime() {
        const failures = [];
        const bases = [LOCAL_WASM_BASE, WASM_BASE];
        for (let index = 0; index < bases.length; index += 1) {
            const base = bases[index];
            try {
                const wasmUrl = base + 'bergamot-translator-worker.wasm';
                const wasmBinary = await fetchBytes(wasmUrl);
                console.info('[IFM] translation engine source: ' + base);
                return { base: base, wasmBinary: wasmBinary, wasmUrl: wasmUrl };
            } catch (err) {
                failures.push(base + ' → ' + ((err && err.message) || err));
                progress = { received: 0, total: 0 };
                notify();
            }
        }
        throw new Error(t('translateEngineDownloadFailed', { reason: failures.join(' | ') }));
    }

    const GEMM_FUNCTIONS = [
        'int8_prepare_a',
        'int8_prepare_b',
        'int8_prepare_b_from_transposed',
        'int8_prepare_b_from_quantized_transposed',
        'int8_prepare_bias',
        'int8_multiply_and_add_bias',
        'int8_select_columns_of_b',
    ];

    // No fallback: the native intgemm implementation is required. If the browser does
    // not provide it (or provides an incomplete one), translation fails loudly.
    function withWasmGemm(imports) {
        if (!WebAssembly.mozIntGemm) {
            throw new Error(t('translateGemmMissing', { name: 'mozIntGemm' }));
        }
        const instance = new WebAssembly.Instance(WebAssembly.mozIntGemm(), {
            '': { memory: imports.env && imports.env.memory },
        });
        const missing = GEMM_FUNCTIONS.filter(function (name) {
            return !instance.exports[name];
        });
        if (missing.length > 0) {
            throw new Error(t('translateGemmMissing', { name: missing.join(', ') }));
        }
        return Object.assign({}, imports, { wasm_gemm: instance.exports });
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
            const moduleRef = {
                wasmBinary: runtime.wasmBinary,
                print: function (text) { console.log('[bergamot] ' + text); },
                printErr: function (text) { console.warn('[bergamot] ' + text); },
                instantiateWasm: function (imports, accept) {
                    const fail = function (err) {
                        console.error('[bergamot] wasm instantiation failed: ' + ((err && err.message) || err));
                        message = 'translateError';
                        status = 'failed';
                        notify();
                    };
                    const fromBytes = function () {
                        WebAssembly.instantiate(runtime.wasmBinary, withWasmGemm(imports))
                            .then(function (result) { accept(result.instance); })
                            .catch(fail);
                    };
                    if (runtime.wasmUrl && typeof WebAssembly.instantiateStreaming === 'function') {
                        WebAssembly.instantiateStreaming(fetch(runtime.wasmUrl), withWasmGemm(imports))
                            .then(function (result) { accept(result.instance); })
                            .catch(function () { fromBytes(); });
                    } else {
                        fromBytes();
                    }
                    return {};
                },
                onRuntimeInitialized: function () { runtimeReady(); },
            };
            window.Module = moduleRef;
            await loadScript(runtime.base + 'bergamot-translator-worker.js');
            await withTimeout(ready, 30000, t('translateEngineTimeout'));
            engine = moduleRef;
            return engine;
        })().catch(function (err) {
            enginePromise = null;
            throw err;
        });
        return enginePromise;
    }
    function attachmentUrl(location, baseUrl) {
        if (!location) return '';
        if (/^[a-z]+:\/\//i.test(location)) return location;
        const root = baseUrl || (RECORDS_URL.indexOf('storage.googleapis.com') >= 0
            ? RECORDS_URL.replace(/\/[^\/]*$/, '/')
            : ATTACH_BASE);
        return String(root).replace(/\/?$/, '/') + String(location).replace(/^\.?\//, '');
    }

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

        Object.keys(body || {}).forEach(function (pair) {
            const value = body[pair];
            if (!value || typeof value !== 'object') return;
            const langs = String(pair).split('-');
            Object.keys(value).forEach(function (name) {
                addFile('pair#' + pair, typeOf(name), value[name], '',
                    { from: langs[0] || '', to: langs[1] || '' });
            });
        });

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

    const LOCAL_MODEL_DIR = 'web/models/en-zh/';
    const LOCAL_MODEL_FILES = {
        model: 'model.enzh.bin.gz',
        vocabs: ['srcvocab.enzh.spm.gz', 'trgvocab.enzh.spm.gz'],
        shortlist: 'lex.enzh.s2t.bin.gz',
    };
    let localModelChecked = false;
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
            console.info('[IFM] using the local translation model: ' + LOCAL_MODEL_DIR);
        }
        return localModelUsable;
    }

    async function resolveRemoteModelFiles() {
        const cached = readJson(STORAGE_MODEL);
        if (cached && Array.isArray(cached.sets) && cached.sets.length > 0 &&
            (Date.now() - (cached.at || 0) < 7 * 24 * 3600 * 1000)) {
            return cached;
        }
        const response = await fetch(RECORDS_URL);
        if (!response.ok) throw new Error(t('translateManifestHttp', { status: response.status }));
        const sets = modelFileSets(normalizeManifest(await response.json()));
        if (sets.length === 0) {
            throw new Error(t('translateManifestNoModel'));
        }
        const files = { at: Date.now(), sets: sets };
        writeJson(STORAGE_MODEL, files);
        return files;
    }

    async function resolveModelFiles() {
        if (await localModelAvailable()) {
            return { at: Date.now(), sets: [localModelSet()] };
        }
        return resolveRemoteModelFiles();
    }

    async function maybeGunzip(bytes, url) {
        if (!/\.gz$/i.test(url)) return bytes;
        if (typeof DecompressionStream !== 'function') {
            throw new Error(t('translateNoGzip'));
        }
        const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'));
        return new Uint8Array(await new Response(stream).arrayBuffer());
    }

    function createService(api) {
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
        throw new Error(t('translateNoService') +
            (tried.length ? t('translateNoServiceTried', { tried: tried.join(' | ') }) : '') +
            (lastError ? '' : t('translateNoServiceHint')));
    }

    async function loadModelSet(api, files) {
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
                console.warn('[IFM] could not download the shortlist (lex) file; translation will be slower: ' + err.message);
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
            for (let index = 0; index < sets.length; index += 1) {
                const files = sets[index];
                try {
                    await loadModelSet(api, files);
                    console.info('[IFM] translation model loaded: ' + files.group +
                        ' (release=' + files.release + ', base=' + files.base + ')');
                    progress = null;
                    notify();
                    return;
                } catch (err) {
                    model = null;
                    service = null;
                    failures.push(files.group + ': ' + ((err && err.message) || err));
                    console.warn('[IFM] model ' + files.group + ' failed to load; trying the next candidate: ' + err);
                    if (files.local && !triedRemote) {
                        triedRemote = true;
                        try {
                            const remote = await resolveRemoteModelFiles();
                            sets = sets.concat(remote.sets);
                            console.info('[IFM] local model unavailable; using the Mozilla manifest (' + remote.sets.length + ' candidates)');
                        } catch (remoteErr) {
                            failures.push('remote manifest: ' + ((remoteErr && remoteErr.message) || remoteErr) +
                                t('translateCorsDetail', { dir: LOCAL_MODEL_DIR }));
                        }
                    }
                }
            }
            progress = null;
            throw new Error(t('translateAllModelsFailed', { failures: failures.join(' / ') }));
        })().catch(function (err) {
            modelPromise = null;
            throw err;
        });
        return modelPromise;
    }

    function tidy(text) {
        return String(text || '')
            .replace(/\s+/g, ' ')
            // ifm-checker: allow-non-ascii（这是"去掉词尾标点"的字符类，不是文案）
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
            try { input.delete(); } catch (err) {  }
            try { options.delete(); } catch (err) {  }
            if (output) {
                try { output.delete(); } catch (err) {  }
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
                await new Promise(function (resolve) { setTimeout(resolve, 0); });
            }
        } catch (err) {
            status = 'failed';
            message = { key: 'translateFailedDetail', params: { error: (err && err.message) || err } };
            notify();
        } finally {
            translating = false;
        }
    }

    function cleanTranslateInput(text) {
        let value = String(text === undefined || text === null ? '' : text).trim();
        if (!value) return '';
        if (value.indexOf(':') >= 0) value = value.split(':').pop();
        return value.replace(/_/g, ' ').replace(/\s+/g, ' ').trim();
    }

    async function translateText(text, options) {
        const source = cleanTranslateInput(text);
        if (!source) return '';
        const opts = options || {};
        if (opts.cached !== false && cache[source]) return cache[source];
        if (!enabled) throw new Error(t('translateDisabled'));
        await start();
        if (status !== 'ready') {
            throw new Error(t('translateNotReady', {
                status: status,
                message: message ? describeMessage(message) : ''
            }));
        }
        const translated = translateBatch([source])[0] || '';
        if (translated) {
            cache[source] = translated;
            saveCacheSoon();
            notify();
        }
        return translated;
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
            message = { key: 'translateUnavailableDetail', params: { error: (err && err.message) || err } };
            notify();
        }
    }

    function setEnabled(on) {
        enabled = !!on;
        try {
            localStorage.setItem(STORAGE_ENABLED, enabled ? '1' : '0');
        } catch (err) {  }
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
        translateText: translateText,
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
