'use strict';

    const IFM_CLIENT_VERSION = '487';
    const DEFAULT_RELAY = 'wss://itty.ws/c/';
    const API_BASE = 'https://blocksitems.com/api/v1';
    const API_ORIGIN = 'https://blocksitems.com';
    const MAX_META_FETCH = 6;
    const ROTATE_MS = 1000;
    const STALL_MS = 15000;
    // A brand new process starts at the largest multiplier the editor offers:
    // players may still lower it, but asking for "as many as fit in one go" is
    // the common case (see the wiki, "Max multiplier").
    const DEFAULT_MAX_MULTIPLIER = 64;

    const stores = {
        containers: new Map(),
        signals: new Map(),
        filters: new Map(),
        machineTypes: new Map(),
        machines: new Map(),
        processes: new Map(),
        peripherals: new Map(),
        missing: new Map(),
        resources: new Map(),
        runtime: new Map(),
    materials: new Map(),
    plan: new Map(),
        deliveries: new Map(),
        workers: new Map(),
    };

    function machineIsReadOnly(name) {
        const machine = stores.machines.get(String(name || ''));
        return !!(machine && machine.virtual === true);
    }

    function machineTypeIsReadOnly(typeName) {
        return String(typeName || '') === 'turtle_crafter';
    }

    const IFM_ABSTRACT_ID = 'abstract';

    function elementIsAbstract(element) {
        if (!element) return false;
        if (element.kind !== 'item' && element.kind !== 'fluid') return false;
        return String(element.id || '').trim().toLowerCase() === IFM_ABSTRACT_ID;
    }

    function processIsAbstract(process) {
        if (!process) return false;
        return asArray(process.inputs).concat(asArray(process.outputs)).some(elementIsAbstract);
    }
    const sendList = new Map();
    const metaCache = new Map();
    const iconIndex = new Map();
    const nodeProcess = new Map();
    const nodeTooltip = new Map();
    const pendingRequests = new Map();
    let ws = null;
    let room = '';
    let relayBase = DEFAULT_RELAY;
    let connected = false;
    let requestSeq = Math.floor(Math.random() * 0x7fffffff);
    let heartbeatTimer = null;
    let lastHeartbeatAt = 0;
    let lastServerDataAt = 0;
    let lastForcedReconnectAt = 0;
    let serverSeen = false;
    let everSeenServer = false;
    let stallNotified = false;
    let status = {};
    let serverVersion = '';
    let versionMismatch = false;
    let sortMode = 'countDesc';
    let peripheralSortMode = 'peripheral';
    let searchText = '';
    let peripheralSearchText = '';
    let graphSearchText = '';
    let processSearchText = '';
    let graphSearchEmptyNotified = false;
    let dirty = {};
    let renderTimer = null;
    let metaQueue = [];
    let metaActive = 0;
    let graphRendering = false;
    // Every render uses a fresh id: mermaid writes the id it is given onto the
    // generated <svg> and looks elements up by it (`select('body').select('#'+id)`),
    // so reusing one id while the previous SVG still sits in the panel made it clear
    // that older element out mid-render (the graph blinked away until the swap).
    let graphRenderSeq = 0;
    const LANG_STORAGE = 'ifm_lang';
    let lang = 'zh';
    try {
        const savedLang = localStorage.getItem(LANG_STORAGE);
        if (savedLang === 'en' || savedLang === 'zh') lang = savedLang;
    } catch (err) {  }
    let connectionStatusKind = 'offline';
    let statusUpdatedAt = 0;
    let compactOptimistic = null;
    const MISSING_META_STORAGE = 'ifm_missing_meta_v2';
    const missingMetaKeys = new Set();
    const iconFailedKeys = new Set();

    function messageText(value) {
        if (value === undefined || value === null) return '';
        if (Array.isArray(value)) return value.map(messageText).join(t('listSeparator'));
        if (typeof value === 'object' && typeof value.key === 'string') return t(value.key, value.params || {});
        // Message parameters travel ASCII-escaped (\\uXXXX) like every other
        // server text, so a Chinese machine/container name has to be decoded here.
        return unescapeAsciiText(String(value));
    }

    function describeMessage(value) {
        if (value === undefined || value === null) return '';
        if (typeof value === 'string') return unescapeAsciiText(value);
        return messageText(value);
    }

    function t(key, params) {
        const pack = MSG[lang] || {};
        const labels = I18N[lang] || {};
        let text = pack[key] || labels[key] || key;
        if (params) {
            Object.keys(params).forEach(function (name) {
                text = text.split('{' + name + '}').join(messageText(params[name]));
            });
        }
        return text;
    }

    function el(id) {
        return document.getElementById(id);
    }

    function escapeHtml(text) {
        return String(text === null || text === undefined ? '' : text)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#39;');
    }

    function keyOf(category, item) {
        if (category === 'resources') {
            return resourceKey(item.kind || '', item.name || '', item.nbt);
        }
        if (category === 'peripherals' || category === 'missing') {
            return (item.kind || '') + ':' + (item.name || '');
        }
        if (category === 'deliveries') {
            return String(item.id);
        }
        if (category === 'workers') {
            return String(item.id);
        }
        if (category === 'containers') {
            return containerKeyOf(item);
        }
        return item.name;
    }

    function containerKeyOf(item) {
        const kind = item && item.kind === 'fluid' ? 'fluid' : 'item';
        return kind + ':' + ((item && item.name) || '');
    }

    function containerByKey(key) {
        if (!key || !stores.containers) return null;
        return stores.containers.get(key) || null;
    }

    function containerByName(name, kind) {
        if (!name) return null;
        const plain = String(name).replace(/^(item|fluid):/, '');
        if (kind) return containerByKey(containerKeyOf({ kind: kind, name: plain }));
        return containerByKey(containerKeyOf({ kind: 'item', name: plain }))
            || containerByKey(containerKeyOf({ kind: 'fluid', name: plain }));
    }

    function resourceKey(kind, name, nbt) {
        return kind + ':' + name + (nbt ? '@' + nbt : '');
    }

    function splitKey(key) {
        const index = key.indexOf(':');
        const kind = key.slice(0, index);
        let rest = key.slice(index + 1);
        let nbt = '';
        const at = rest.indexOf('@');
        if (at >= 0) {
            nbt = rest.slice(at + 1);
            rest = rest.slice(0, at);
        }
        return [kind, rest, nbt];
    }

    function hex4(code) {
        let text = code.toString(16).toUpperCase();
        while (text.length < 4) text = '0' + text;
        return '\\u' + text;
    }

    function escapeUnicodeForServer(text) {
        const value = String(text === null || text === undefined ? '' : text);
        let out = '';
        for (let i = 0; i < value.length; i += 1) {
            const code = value.charCodeAt(i);
            if (code === 0x5C) {
                out += '\\u005C';
            } else if (code >= 0x20 && code <= 0x7E) {
                out += value.charAt(i);
            } else {
                out += hex4(code);
            }
        }
        return out;
    }

    function unescapeAsciiText(text) {
        const value = String(text === null || text === undefined ? '' : text);
        let out = '';
        let i = 0;
        while (i < value.length) {
            if (value.charAt(i) === '\\' && value.charAt(i + 1) === 'u') {
                const hex = value.substr(i + 2, 4);
                if (/^[0-9A-Fa-f]{4}$/.test(hex)) {
                    out += String.fromCharCode(parseInt(hex, 16));
                    i += 6;
                    continue;
                }
            }
            out += value.charAt(i);
            i += 1;
        }
        return out;
    }

    const OUTBOUND_TEXT_PATHS = {
        set_container: ['name', 'data.peripheral'],
        set_signal: ['name', 'data.peripheral'],
        set_machine_type: ['name', 'data.icon'],
        set_filter: ['name', 'data.rules[].id'],
        set_machine: ['name', 'data.type', 'data.itemInputs[]', 'data.fluidInputs[]',
            'data.itemOutputs[]', 'data.fluidOutputs[]', 'data.signals[]'],
        set_process: ['name', 'data.machineType', 'data.inputs[].id', 'data.inputs[].name',
            'data.outputs[].id', 'data.outputs[].name'],
        delete_container: ['name'], delete_signal: ['name'], delete_filter: ['name'],
        delete_machine_type: ['name'], delete_machine: ['name'], delete_process: ['name'],
        cancel_process: ['name'],
        craft_resource: ['name'],
        send_items: ['container', 'items[].name'],
        delete_deliveries: [],
    };

    const CATEGORY_TEXT_PATHS = {
        containers: ['name', 'peripheral'],
        signals: ['name', 'peripheral'],
        machineTypes: ['name', 'icon'],
        filters: ['name', 'rules[].id'],
        machines: ['name', 'type', 'itemInputs[]', 'fluidInputs[]', 'itemOutputs[]', 'fluidOutputs[]', 'signals[]'],
        processes: ['name', 'machineType', 'inputs[].id', 'inputs[].name', 'outputs[].id', 'outputs[].name'],
        peripherals: ['name', 'containers[].name', 'signals[].name',
            'containers[].peripheral', 'signals[].peripheral'],
        missing: ['name', 'peripheral'],
        resources: ['name', 'samples[].name'],
        runtime: ['name', 'machine', 'progress[].id', 'lastError', 'current.id', 'current.name',
            'instanceList[].machine', 'instanceList[].lastError', 'instanceList[].current.id',
            'instanceList[].current.name', 'instanceList[].current.item', 'instanceList[].progress[].id'],
        deliveries: ['name', 'container', 'processName', 'lastError'],
    };

    const RESPONSE_TEXT_PATHS = [
        'error', 'result.error', 'result.name', 'result.process',
        'result.info.process', 'result.info.name', 'result.info.canceled',
        'result.results[].name', 'result.results[].error', 'result.lines[]',
        'result.slotInfo[].item',
    ];

    function applyTextPaths(target, paths, fn) {
        if (!target || typeof target !== 'object' || !paths) return target;
        paths.forEach(function (path) { walkTextPath(target, path.split('.'), 0, fn); });
        return target;
    }

    function walkTextPath(node, parts, index, fn) {
        if (!node || typeof node !== 'object') return;
        const part = parts[index];
        const last = index === parts.length - 1;
        const isArray = part.slice(-2) === '[]';
        const key = isArray ? part.slice(0, -2) : part;
        const value = node[key];
        if (value === undefined || value === null) return;
        if (isArray) {
            if (!Array.isArray(value)) return;
            if (last) {
                for (let i = 0; i < value.length; i += 1) {
                    if (typeof value[i] === 'string') value[i] = fn(value[i]);
                }
                return;
            }
            value.forEach(function (item) { walkTextPath(item, parts, index + 1, fn); });
            return;
        }
        if (last) {
            if (typeof value === 'string') node[key] = fn(value);
            return;
        }
        walkTextPath(value, parts, index + 1, fn);
    }

    function escapePayloadForServer(payload) {
        if (!payload || typeof payload !== 'object') return payload;
        applyTextPaths(payload, OUTBOUND_TEXT_PATHS[payload.action], escapeUnicodeForServer);
        return payload;
    }

    function decodeFrameFromServer(data) {
        if (!data || typeof data !== 'object') return data;
        if (data.action === 'incremental_update' && data.changes && typeof data.changes === 'object') {
            Object.keys(data.changes).forEach(function (category) {
                const list = data.changes[category];
                if (!Array.isArray(list)) return;
                const paths = CATEGORY_TEXT_PATHS[category];
                if (!paths) return;
                list.forEach(function (item) { applyTextPaths(item, paths, unescapeAsciiText); });
            });
            return data;
        }
        applyTextPaths(data, RESPONSE_TEXT_PATHS, unescapeAsciiText);
        return data;
    }

    function asArray(value) {
        return Array.isArray(value) ? value : [];
    }

    const ARRAY_FIELDS = {
        filters: ['rules'],
        machines: ['itemInputs', 'fluidInputs', 'signals', 'itemOutputs', 'fluidOutputs'],
        processes: ['inputs', 'outputs'],
        peripherals: ['containers', 'signals'],
        resources: ['samples', 'tags'],
        runtime: ['progress'],
    };

    const NESTED_ARRAY_FIELDS = {
        processes: { inputs: ['sides'], outputs: ['sides'] },
    };

    function normalizeItemArrays(category, item) {
        if (!item || typeof item !== 'object') return item;
        asArray(ARRAY_FIELDS[category]).forEach(function (field) {
            if (item[field] !== undefined) item[field] = asArray(item[field]);
        });
        const nested = NESTED_ARRAY_FIELDS[category];
        if (nested) {
            Object.keys(nested).forEach(function (field) {
                if (!Array.isArray(item[field])) {
                    item[field] = [];
                    return;
                }
                item[field].forEach(function (element) {
                    if (!element || typeof element !== 'object') return;
                    nested[field].forEach(function (inner) {
                        if (element[inner] !== undefined) element[inner] = asArray(element[inner]);
                    });
                });
            });
        }
        return item;
    }

    function setText(id, value) {
        const node = el(id);
        if (node) node.textContent = value;
        return node;
    }

    function setDisplay(id, value) {
        const node = el(id);
        if (node) node.style.display = value;
        return node;
    }

    function toastAreaNode() {
        let node = el('toastArea');
        if (!node) {
            node = document.createElement('div');
            node.id = 'toastArea';
            const parent = document.body || document.documentElement;
            if (!parent) return node;
            parent.appendChild(node);
        }
        return node;
    }

    function toast(message, type) {
        const box = document.createElement('div');
        box.className = 'toast-msg ' + (type || 'info');
        box.textContent = message;
        toastAreaNode().appendChild(box);
        setTimeout(function () {
            box.remove();
        }, 4200);
    }

    function setLang(next) {
        lang = next === 'en' ? 'en' : 'zh';
        try { localStorage.setItem(LANG_STORAGE, lang); } catch (err) {  }
        return lang;
    }

    function setConnectionStatus(kind) {
        connectionStatusKind = kind;
        const dot = el('statusDot');
        if (dot) {
            dot.className = 'status-dot ' + (kind === 'online' ? 'online' : (kind === 'connecting' ? 'connecting' : ''));
        }
        const text = kind === 'online' ? t('connected') : (kind === 'connecting' ? t('connecting') : t('disconnected'));
        setText('statusText', text);
        if (kind !== 'connecting' && window.ifmSetConnectBusy) {
            window.ifmSetConnectBusy(false);
        }
    }

    // Re-render the status line in the current language: the kind alone is stable,
    // but setConnectionStatus() is what turns it into text (so a language switch
    // has to run it again).
    function refreshConnectionStatus() {
        setConnectionStatus(connectionStatusKind);
    }

    function markServerSeen() {
        lastHeartbeatAt = Date.now();
        lastServerDataAt = lastHeartbeatAt;
        everSeenServer = true;
        if (versionMismatch) {
            // A mismatched server is not "seen": stay on the login page (the
            // connection is dropped by applyServerVersion).
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
            return;
        }
        if (serverSeen) return;
        serverSeen = true;
        setDisplay('loginOverlay', 'none');
        setDisplay('app', 'block');
        setConnectionStatus('online');
        toast(t('connectedTo', { room: '****' }), 'success');
    }

    function fmtCount(value) {
        const number = Number(value);
        if (!isFinite(number)) return t('noValue');
        const abs = Math.abs(number);
        if (abs >= 1000000000) return (number / 1000000000).toFixed(2) + 'b';
        if (abs >= 1000000) return (number / 1000000).toFixed(2) + 'm';
        if (abs >= 1000) return (number / 1000).toFixed(2) + 'k';
        return String(Math.round(number));
    }

    // The exact integer with thousands separators: the capacity bars abbreviate a
    // big count ("1.23k"), the tooltip next to them spells it out.
    function fmtExact(value) {
        const number = Number(value);
        if (!isFinite(number)) return t('noValue');
        return String(Math.round(number)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }

    // Same shape as fmtCount, but every step truncates towards zero instead of
    // rounding: the resource grid shows the stock it really holds, never a rounded-up
    // number.
    function fmtCountFloor(value) {
        const number = Number(value);
        if (!isFinite(number)) return t('noValue');
        const abs = Math.abs(number);
        const trunc = function (scaled) {
            return (Math.floor(scaled * 100) / 100).toFixed(2);
        };
        if (abs >= 1000000000) return trunc(number / 1000000000) + 'b';
        if (abs >= 1000000) return trunc(number / 1000000) + 'm';
        if (abs >= 1000) return trunc(number / 1000) + 'k';
        return String(Math.floor(number));
    }

    // Amounts that may legitimately be fractional - an expected yield like 1.5,
    // or the min/max pair of a chance craft. fmtCount() rounds those to integers,
    // which made a 1.5 expectation read as 2.
    function fmtAmount(value) {
        const number = Number(value);
        if (!isFinite(number)) return t('noValue');
        if (Number.isInteger(number) || Math.abs(number) >= 1000) return fmtCount(number);
        return String(Math.round(number * 100) / 100);
    }

    function metaOf(kind, name) {
        const meta = metaCache.get(resourceKey(kind, name));
        return (meta && meta !== 'missing') ? meta : null;
    }

    function isMetaPending(kind, name) {
        const key = resourceKey(kind, name);
        if (metaCache.has(key)) return false;
        if (metaQueue.indexOf(key) >= 0) return true;
        return metaActive > 0;
    }

    function displayName(kind, name) {
        // A placeholder is not a registry entry: the icon export index would fold its
        // kind into "item" and answer with an *item* that happens to share the name,
        // renaming the placeholder to that item. Its own name is what has to be shown
        // (the referenced item is a separate line wherever it matters).
        const exported = (kind === 'placeholder') ? '' : iconExportName(kind, name);
        if (exported) return exported;
        const english = englishName(kind, name);
        const translator = window.IFMTranslate;
        if (translator && translator.isEnabled()) {
            const translated = translator.nameFor(english);
            if (translated) return translated;
        }
        return english;
    }

    function englishName(kind, name) {
        const meta = metaOf(kind, name);
        if (meta && meta.display_name) return meta.display_name;
        const path = String(name || '').split(':').pop();
        return path ? path.replace(/_/g, ' ') : String(name || '');
    }

    function queueTranslateNames(list) {
        const translator = window.IFMTranslate;
        if (!translator || !translator.isEnabled() || translator.status() !== 'ready') return;
        const names = [];
        asArray(list).forEach(function (entry) {
            const meta = metaOf(entry.kind, entry.name);
            // Only entries the API cannot name are handed to the translator: when
            // the API/icon export already provides an English name there is
            // nothing to translate, and the bergamot pass stays cheap.
            if (meta) return;
            if (isMetaPending(entry.kind, entry.name)) return;
            names.push(englishName(entry.kind, entry.name));
        });
        if (names.length > 0) translator.queueNames(names);
    }

    function translateMessageText(message) {
        if (!message) return '';
        if (typeof message === 'object') return describeMessage(message);
        const pack = I18N[lang] || {};
        return pack[message] || message;
    }

    function renderTranslateButton() {
        const node = el('translateLabel');
        const button = el('translateBtn');
        if (!node || !button) return;
        const translator = window.IFMTranslate;
        if (!translator) {
            button.style.display = 'none';
            return;
        }
        if (!translator.isEnabled()) {
            node.textContent = t('translateOff');
            button.title = t('translateTitle');
            return;
        }
        const status = translator.status();
        if (status === 'ready') {
            node.textContent = t('translateOn', { n: fmtCount(translator.translatedCount()) });
            button.title = t('translateTitle');
            return;
        }
        if (status === 'failed') {
            node.textContent = t('translateFailed');
            button.title = translateMessageText(translator.message()) || t('translateTitle');
            return;
        }
        const percent = translator.progressPercent();
        node.textContent = percent ? t('translateLoadingPercent', { n: percent }) : t('translateLoading');
        button.title = translateMessageText(translator.message()) || t('translateTitle');
    }

    function renderVersionLabel() {
        const label = el('versionLabel');
        if (label) {
            label.textContent = versionMismatch
                ? t('versionMismatchShort')
                : t('versionLabel', { client: IFM_CLIENT_VERSION });
            label.title = t('versionLabel', { client: IFM_CLIENT_VERSION }) +
                (serverVersion ? ' · ' + t('versionServer', { server: serverVersion }) : '');
            label.style.color = versionMismatch ? 'var(--bad)' : '';
        }
        const hint = el('versionHint');
        if (hint) {
            hint.textContent = t('versionLabel', { client: IFM_CLIENT_VERSION }) +
                (serverVersion ? ' · ' + t('versionServer', { server: serverVersion }) : '');
        }
    }

    function statusStatHtml(glyph, value, hint) {
        const tip = hint
            ? ' title="' + escapeHtml(hint) + '" data-tip-text="' + escapeHtml(hint) + '"'
            : '';
        return '<i class="fa ' + glyph + ' status-icon"' + tip + '></i>' +
            '<span class="status-value"' + tip + '>' +
            escapeHtml(value === null || value === undefined ? '' : String(value)) + '</span>';
    }

    function setHtmlIfChanged(node, html) {
        if (!node || node.__ifmHtml === html) return node;
        node.__ifmHtml = html;
        node.innerHTML = html;
        return node;
    }

    function renderTransferInfo() {
        const node = el('transferInfo');
        if (!node) return;
        const info = status ? status.transfer : null;
        if (info && info.available) {
            const scan = info.scan || {};
            const workers = info.workers || 0;
            const pending = info.pending || 0;
            setHtmlIfChanged(node, statusStatHtml('fa-truck', workers, t('transferWorkersHint')) +
                statusStatHtml('fa-hourglass-half', pending, t('transferInFlight', { pending: pending })) +
                statusStatHtml('fa-magnifying-glass', scan.cached || 0, t('transferScanHint', {
                    cached: scan.cached || 0,
                    containers: scan.containers || 0,
                    localOnly: scan.localOnly || 0,
                    blind: scan.blind || 0,
                    paused: scan.pauseLeft || 0
                })));
            node.title = t('transferHint', {
                channel: info.channel,
                done: info.done || 0,
                failed: info.failed || 0
            }) + '\n' + t('transferScanHint', {
                cached: scan.cached || 0,
                containers: scan.containers || 0,
                localOnly: scan.localOnly || 0,
                blind: scan.blind || 0,
                paused: scan.pauseLeft || 0
            });
            node.style.color = ((scan.blind || 0) > 0 || (scan.paused || 0) > 0) ? 'var(--warn)' : '';
            return;
        }
        node.innerHTML = info ? statusStatHtml('fa-desktop', t('transferNone'), t('transferHintNone')) : '';
        node.__ifmHtml = node.innerHTML;
        node.title = t('transferHintNone');
        node.style.color = '';
    }

    // No fallback: a key that is missing from the active language is returned as-is
    // (the message checker guarantees both languages carry the same key set).
    function dispatchI18n(key) {
        return t(key);
    }

    function dispatchQueueLabel(name) {
        const raw = String(name || '?');
        const key = 'scheduleQueue' + raw.charAt(0).toUpperCase() + raw.slice(1);
        return dispatchI18n(key, raw);
    }

    function dispatchModeLabel(mode) {
        const raw = String(mode || '?');
        const key = 'dispatchMode' + raw.charAt(0).toUpperCase() + raw.slice(1);
        return dispatchI18n(key, dispatchI18n('dispatchModeUnknown', raw));
    }

    function dispatchQueueGlyph(name) {
        if (name === 'storageScan') return 'fa-archive';
        if (name === 'containerSize') return 'fa-ruler-combined';
        if (name === 'slotLimit') return 'fa-ruler';
        if (name === 'inputScan') return 'fa-sign-in';
        if (name === 'interactionScan') return 'fa-cubes';
        if (name === 'outputScan') return 'fa-sign-out';
        if (name === 'inventoryIn') return 'fa-arrow-down';
        if (name === 'inventoryOut') return 'fa-arrow-up';
        if (name === 'compact') return 'fa-compress';
        if (name === 'stackScan') return 'fa-layer-group';
        if (name === 'detail') return 'fa-info-circle';
        if (name === 'manual') return 'fa-hand-pointer';
        return 'fa-list';
    }

    function dispatchModeGlyph(mode) {
        if (mode === 'local') return 'fa-desktop';
        if (mode === 'remote') return 'fa-server';
        if (mode === 'mixed') return 'fa-random';
        if (mode === 'paused') return 'fa-pause';
        return 'fa-question';
    }

    function renderDispatchInfo() {
        const node = el('dispatchInfo');
        if (!node) return;
        const info = status && status.dispatch;
        if (!info) {
            node.innerHTML = '';
            node.removeAttribute('title');
            return;
        }
        const short = [];
        const detail = [];
        asArray(info.queues).forEach(function (queue) {
            const depth = queue.depth || 0;
            const inflight = queue.inflight || 0;
            if (depth > 0 || inflight > 0) {
                short.push(statusStatHtml(dispatchQueueGlyph(queue.name), depth + inflight,
                    t('statusQueue', {
                        queue: dispatchQueueLabel(queue.name),
                        depth: depth,
                        inflight: inflight
                    })));
            }
            detail.push(dispatchQueueLabel(queue.name) + ': depth=' + depth + ' (active=' + (queue.active || 0) +
                ' waiting=' + (queue.waiting || 0) + ') inflight=' + inflight +
                ' weight=' + (queue.slice || 1) + ' runs=' +
                (typeof queue.remaining === 'number' ? (Math.round(queue.remaining * 100) / 100) : '?') +
                ' served=' + (queue.served || 0) +
                ' dropped=' + (queue.dropped || 0) + ' retried=' + (queue.retried || 0) +
                ' promoted=' + (queue.promoted || 0) +
                ' needs=' + (queue.needs || 'none') + ' policy=' + (queue.policy || 'retry'));
        });
        const tip = t('dispatchHint', {
            mode: dispatchModeLabel(info.mode), steps: info.steps || 0,
            last: Math.round((info.lastMs || 0) * 10) / 10,
            max: Math.round((info.maxMs || 0) * 10) / 10,
            writes: info.writes || 0
        }) + (detail.length > 0 ? '\n' + detail.join('\n') : '');
        // The per-queue breakdown is long, so it hangs off this small "?" icon
        // instead of the whole header span: hovering the background now shows
        // nothing, only hovering the icon shows the detail.
        node.innerHTML = statusStatHtml(dispatchModeGlyph(info.mode), '',
                t('dispatchMode', { mode: dispatchModeLabel(info.mode), steps: fmtCount(info.steps || 0) })) +
            statusStatHtml('fa-forward-step', fmtCount(info.steps || 0), t('dispatchSteps')) +
            short.join('') +
            (tip
                ? '<i class="fa fa-circle-question status-icon dispatch-help" title="' +
                    escapeHtml(tip) + '"></i>'
                : '');
        node.__ifmHtml = node.innerHTML;
        node.removeAttribute('title');
    }

    function kindBadgeGlyph(kind) {
        if (kind === 'fluid') return 'fa-tint';
        if (kind === 'filter') return 'fa-filter';
        if (kind === 'placeholder') return 'fa-thumb-tack';
        if (kind === 'signal') return 'fa-bolt';
        return 'fa-cube';
    }

    function absoluteApiUrl(url) {
        if (!url) return '';
        return url.charAt(0) === '/' ? API_ORIGIN + url : url;
    }

    function iconUrl(kind, name) {
        const meta = metaOf(kind, name);
        if (meta && meta.icon_url) return absoluteApiUrl(meta.icon_url);
        return API_BASE + '/' + metaEndpoint(kind) + '/' + encodeURIComponent(name) + '/icon';
    }

    function metaEndpoint(kind) {
        return (kind === 'fluid' || kind === 'block') ? 'blocks' : 'items';
    }

    function blockIdOf(peripheralName) {
        return String(peripheralName || '').replace(/_\d+$/, '');
    }

    const BLOCK_ID_NAMESPACES = ['computercraft', 'minecraft'];

    const PERIPHERAL_BLOCK_OVERRIDES = { turtle: 'computercraft:turtle_advanced' };

    function blockIdCandidates(peripheralName) {
        const raw = blockIdOf(peripheralName);
        if (!raw) return [];
        const override = PERIPHERAL_BLOCK_OVERRIDES[raw];
        if (override) return [override];
        if (raw.indexOf(':') >= 0) return [raw];
        const candidates = BLOCK_ID_NAMESPACES.map(function (namespace) { return namespace + ':' + raw; });
        const unique = iconExportUniqueIdByPath(raw);
        if (unique) candidates.push(unique);
        candidates.push(raw);
        return candidates;
    }

    function resolvedBlockIdOf(peripheralName) {
        const candidates = blockIdCandidates(peripheralName);
        if (candidates.length <= 1) return candidates[0] || '';
        for (let i = 0; i < candidates.length; i += 1) {
            if (iconExportEntry('block', candidates[i])) return candidates[i];
        }
        for (let i = 0; i < candidates.length; i += 1) {
            if (metaState(resourceKey('block', candidates[i])) === 'ready') return candidates[i];
        }
        return candidates[0];
    }

    function blockIconHtml(peripheralName) {
        const blockId = resolvedBlockIdOf(peripheralName);
        if (!blockId) return faGlyphHtml('block', peripheralName);
        const key = resourceKey('block', blockId);
        const exported = iconExportFile('block', blockId);
        if (exported || (metaState(key) !== 'missing' && !iconFailedKeys.has(key))) {
            return iconImgTagHtml('block', blockId, ' title="' + escapeHtml(blockId) +
                '" style="width:20px;height:20px;image-rendering:pixelated"', exported);
        }
        queueMeta('block', blockId);
        return faGlyphHtml('block', peripheralName);
    }
