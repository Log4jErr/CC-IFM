'use strict';

    const metaHints = { network: false, missing: false };

    // There is no fallback: if Font Awesome did not load, the icons are simply
    // missing and the console says so.
    function probeFontAwesome() {
        let missing = false;
        try {
            const probe = document.createElement('i');
            probe.className = 'fa fa-cube';
            probe.style.position = 'absolute';
            probe.style.left = '-9999px';
            document.body.appendChild(probe);
            const content = window.getComputedStyle(probe, '::before').content;
            document.body.removeChild(probe);
            missing = !(content && content !== 'none' && content !== 'normal');
        } catch (err) {
            missing = false;
        }
        if (missing) {
            console.error('[IFM] Font Awesome did not load (CDN blocked / offline): toolbar icons will be ' +
                'missing. There is no text fallback any more - fix the CDN or ship the font locally.');
        }
    }

    function iconGlyphClass(kind) {
        if (kind === 'fluid') return 'fa-tint';
        if (kind === 'filter') return 'fa-filter';
        if (kind === 'placeholder') return 'fa-thumb-tack';
        if (kind === 'virtual') return 'fa-cog';
        if (kind === 'abstract') return 'fa-cog';
        return 'fa-cube';
    }

    function iconFallbackText(name) {
        let label = String(name === null || name === undefined ? '' : name).trim();
        if (!label) return '?';
        label = label.replace(/^[a-z0-9_.\-]+:/i, '');
        if (!label) return '?';
        if (/[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]/.test(label)) {
            return label.slice(0, 4);
        }
        const words = label.split(/[\s_\-/.:]+/).filter(function (part) { return part.length > 0; });
        if (words.length === 0) return '?';
        if (words.length === 1) return words[0].slice(0, 4).toUpperCase();
        return words.slice(0, 4).map(function (word) {
            return word.charAt(0).toUpperCase();
        }).join('');
    }

    function iconLabelOf(kind, name) {
        try {
            const shown = displayName(kind, name);
            if (shown) return shown;
        } catch (err) {  }
        return String(name || '');
    }

    function faGlyphHtml(kind, name) {
        const text = iconFallbackText(iconLabelOf(kind, name));
        return '<span class="icon-text" data-fallback-len="' + text.length + '">' + escapeHtml(text) + '</span>';
    }

    function metaState(key) {
        const meta = metaCache.get(key);
        if (meta === 'missing') return 'missing';
        return meta ? 'ready' : 'unknown';
    }

    const ICON_LAZY_PLACEHOLDER = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
    function iconExportPending() {
        return !iconExportIndex && !iconExportUnavailable && !!iconExportLoadingLang;
    }

    function iconImgTagHtml(kind, name, extraAttrs, exportedFile) {
        const file = (exportedFile === undefined) ? iconExportFile(kind, name) : exportedFile;
        const pending = !file && iconExportPending();
        const src = file ? iconExportUrl(file) : (pending ? ICON_LAZY_PLACEHOLDER : iconUrl(kind, name));
        return '<img src="' + src + '" alt="" data-icon-key="' + escapeHtml(resourceKey(kind, name)) +
            '" data-icon-tier="' + (file ? 'export' : (pending ? 'lazy' : 'api')) + '"' + (extraAttrs || '') +
            ' onerror="window.ifmIconFallback(this, \'' + kind + '\')">';
    }

    function iconImgHtml(kind, name, className, exportedFile) {
        return '<span class="' + className + '">' + iconImgTagHtml(kind, name, '', exportedFile) + '</span>';
    }

    function faSpanHtml(kind, name, className) {
        return '<span class="' + className + '">' + faGlyphHtml(kind, name) + '</span>';
    }

    function iconHtml(kind, name, extraClass, forceChar) {
        const className = 'icon ' + (extraClass || '');
        const key = resourceKey(kind, name);
        const state = metaState(key);
        const exported = forceChar ? null : iconExportFile(kind, name);
        if (!forceChar && (exported || (state !== 'missing' && !iconFailedKeys.has(key)))) {
            return iconImgHtml(kind, name, className, exported);
        }
        queueMeta(kind, name);
        return faSpanHtml(kind, name, className);
    }

    // Machine type icons are plain item icons with a defined "not found" look:
    // the icon is meant to make the machine recognisable, so a made-up
    // abbreviation (the generic first-letters fallback) would be misleading -
    // a question mark says "no icon for that registry name".
    function machineIconHtml(icon, className) {
        const name = String(icon === null || icon === undefined ? '' : icon).trim();
        if (!name) return '';
        const cls = 'ifm-machine-icon' + (className ? ' ' + className : '');
        const key = resourceKey('item', name);
        queueMeta('item', name);
        if (metaState(key) === 'missing') {
            return '<i class="fa fa-question ' + cls + '" title="' + escapeHtml(name) + '"></i>';
        }
        const exported = iconExportFile('item', name);
        return '<img class="' + cls + '" src="' + (exported ? iconExportUrl(exported) : iconUrl('item', name)) +
            '" data-machine-icon="' + escapeHtml(name) + '" data-icon-key="' + escapeHtml(key) +
            '" data-icon-tier="' + (exported ? 'export' : 'api') + '" alt="" title="' + escapeHtml(name) +
            '" onerror="window.ifmMachineIconFallback(this)">';
    }

    // export image missing -> the blocksitems API once -> question mark.
    window.ifmMachineIconFallback = function (img) {
        const tier = String(img.getAttribute('data-icon-tier') || '');
        const name = String(img.getAttribute('data-machine-icon') || '');
        if (tier === 'export') iconExportMarkFailed(iconExportFileFromUrl(img.getAttribute('src')));
        if (tier !== 'api' && name) {
            img.setAttribute('data-icon-tier', 'api');
            img.setAttribute('src', iconUrl('item', name));
            return;
        }
        const key = img.getAttribute('data-icon-key') || '';
        if (key && name && metaState(key) === 'unknown') {
            iconFailedKeys.add(key);
            queueMeta('item', name);
        } else if (key) {
            metaCache.set(key, 'missing');
        }
        const holder = img.parentNode;
        if (!holder) return;
        const replacement = document.createElement('i');
        replacement.className = 'fa fa-question' + (img.className ? ' ' + img.className : '');
        replacement.setAttribute('title', name);
        holder.replaceChild(replacement, img);
    };

    window.ifmIconFallback = function (img, kind) {
        const holder = img.parentNode;
        if (!holder) return;
        const tier = img.getAttribute('data-icon-tier') || '';
        if (tier === 'export') {
            const key = img.getAttribute('data-icon-key') || '';
            const parts1 = splitKey(key);
            const failedFile = iconExportFileFromUrl(img.getAttribute('src'));
            const resourceKind = kind || parts1[0] || 'item';
            const resourceName = parts1[1] || '';
            const listed = iconExportListedFile(resourceKind, resourceName);
            iconExportMarkFailed(failedFile);
            const nextFile = iconExportFile(resourceKind, resourceName);
            console.info('[IFM] icon-exports image failed to load: ' + failedFile +
                (listed ? ' (metadata lists this image, but the file is not in icon-exports/: the export may be incomplete)'
                    : ' (no metadata entry for it; the name was guessed by convention)') +
                (nextFile ? ' -> trying another export image with the same registry name: ' + nextFile
                    : ' -> falling back to the blocksitems API: ' + resourceKind + ':' + resourceName));
            if (nextFile) {
                img.setAttribute('src', iconExportUrl(nextFile));
                return;
            }
            img.setAttribute('data-icon-tier', 'api');
            img.setAttribute('src', iconUrl(resourceKind, resourceName));
            return;
        }
        const key = img.getAttribute('data-icon-key');
        if (key) {
            if (metaState(key) === 'unknown') {
                iconFailedKeys.add(key);
                const parts0 = splitKey(key);
                queueMeta(parts0[0] || kind || 'item', parts0[1] || '');
            } else {
                metaCache.set(key, 'missing');
            }
        }
        const title = img.getAttribute('title') || '';
        const parts = splitKey(key || '');
        const fallbackKind = kind || parts[0] || 'item';
        const label = title || iconLabelOf(fallbackKind, parts[1] || '');
        const text = iconFallbackText(label);
        const replacement = document.createElement('span');
        replacement.className = 'icon-text';
        replacement.setAttribute('data-fallback-len', text.length);
        replacement.textContent = text;
        if (title) replacement.setAttribute('title', title);
        holder.replaceChild(replacement, img);
    };

    function queueMeta(kind, name) {
        if (!name) return;
        const key = resourceKey(kind, name);
        if (metaCache.has(key) || metaQueue.indexOf(key) >= 0) return;
        metaQueue.push(key);
        pumpMetaQueue();
    }

    function pumpMetaQueue() {
        while (metaActive < MAX_META_FETCH && metaQueue.length > 0) {
            const key = metaQueue.shift();
            if (metaCache.has(key)) continue;
            const parts = splitKey(key);
            metaActive += 1;
            fetchMeta(parts[0], parts[1]).finally(function () {
                metaActive -= 1;
                pumpMetaQueue();
            });
        }
    }

    function fetchMeta(kind, name) {
        const key = resourceKey(kind, name);
        return fetch(API_BASE + '/' + metaEndpoint(kind) + '/lookup/' + encodeURIComponent(name))
            .then(function (response) {
                if (response.status === 404) {
                    setMetaMissing(key);
                    return null;
                }
                if (!response.ok) throw new Error('http ' + response.status);
                return response.json();
            })
            .then(function (body) {
                if (!body) return;
                if (body.status === 'ok' && body.found && body.data) {
                    metaCache.set(key, body.data);
                    iconFailedKeys.delete(key);
                    markDirty('resources');
                    markDirty('peripherals');
                    markDirty('machines');
                    scheduleRender();
                } else if (body.status === 'ok') {
                    if (!metaHints.missing) {
                        metaHints.missing = true;
                        console.info('[IFM] the blocksitems API has no entry for this resource (for example ' + key +
                            '): it can only use the generic font glyph. This is the case for every mod the API does not index.');
                    }
                    setMetaMissing(key);
                    iconFailedKeys.delete(key);
                    scheduleRender();
                }
            })
            .catch(function (err) {
                if (!metaHints.network) {
                    metaHints.network = true;
                    console.warn('[IFM] cannot fetch blocksitems metadata (' + ((err && err.message) || err) +
                        '): the page may be opened via file://, the API may not send CORS headers, or you may be offline. ' +
                        'Icons will use the image URL directly and fall back to the name (first 4 characters / first letters of each word).');
                    ['resources', 'peripherals', 'processes', 'deliveries'].forEach(markDirty);
                    scheduleRender();
                }
            });
    }

    function resetMetaCache() {
        metaCache.clear();
        metaQueue = [];
        missingMetaKeys.clear();
        iconFailedKeys.clear();
        iconExportIndex = null;
        iconExportIndexLang = null;
        iconExportUnavailable = false;
        iconExportLoadingLang = null;
        Object.keys(iconExportLangCache).forEach(function (code) { delete iconExportLangCache[code]; });
        iconExportFailedFiles.clear();
        try { localStorage.removeItem(MISSING_META_STORAGE); } catch (err) {  }
    }

    function setMetaMissing(key) {
        metaCache.set(key, 'missing');
        if (missingMetaKeys.has(key)) return;
        missingMetaKeys.add(key);
        try {
            localStorage.setItem(MISSING_META_STORAGE, JSON.stringify(Array.from(missingMetaKeys)));
        } catch (err) {  }
    }

    function loadMissingMeta() {
        try {
            const raw = localStorage.getItem(MISSING_META_STORAGE);
            if (!raw) return;
            JSON.parse(raw).forEach(function (key) {
                if (typeof key === 'string' && !metaCache.has(key)) metaCache.set(key, 'missing');
            });
        } catch (err) {  }
    }

    const ICON_EXPORTS_BASE = 'icon-exports/';
    const ICON_EXPORTS_META_DIR = 'icon-exports-metadata/';
    const ICON_EXPORTS_META_DIRS = ['icon-exports-metadata/', 'icon-export-metadata/', 'icon-exports-metadata', 'icon-exports/'];
    const ICON_EXPORT_LANGS = ['zh', 'en'];
    let iconExportIndex = null;
    let iconExportIndexLang = null;
    let iconExportLoadingLang = null;
    let iconExportUnavailable = false;
    const iconExportLangCache = {};
    const iconExportFailedFiles = new Set();

    function iconExportUrl(file) {
        const name = String(file || '');
        return ICON_EXPORTS_BASE +
            encodeURI(name).replace(/#/g, '%23').replace(/\?/g, '%3F');
    }

    function iconExportFileFromUrl(src) {
        const encoded = String(src || '').replace(ICON_EXPORTS_BASE, '');
        try {
            return decodeURIComponent(encoded);
        } catch (err) {
            return encoded;
        }
    }

    function iconExportKey(kind, name) {
        return (kind === 'fluid' ? 'fluid' : 'item') + '|' + String(name || '').toLowerCase();
    }

    function iconExportConventionalFile(kind, name) {
        const text = String(name || '');
        if (!text) return null;
        const colon = text.indexOf(':');
        const namespace = (colon >= 0 ? text.slice(0, colon) : 'minecraft').toLowerCase();
        const path = (colon >= 0 ? text.slice(colon + 1) : text).toLowerCase();
        if (!path) return null;
        const prefix = (kind === 'fluid') ? 'fluid__' : '';
        return prefix + namespace + '__' + path.replace(/\//g, '__') + '.png';
    }

    function iconExportLanguageOrder() {
        const first = (lang === 'en') ? 'en' : 'zh';
        return [first].concat(ICON_EXPORT_LANGS.filter(function (code) { return code !== first; }));
    }

    function iconExportUsableName(text) {
        const value = String(text || '').trim();
        if (!value || value.indexOf('\ufffd') >= 0) return '';
        return value;
    }

    function iconExportCanonical(value) {
        if (Array.isArray(value)) {
            return value.map(iconExportCanonical);
        }
        if (value && typeof value === 'object') {
            const sorted = {};
            Object.keys(value).sort().forEach(function (key) { sorted[key] = iconExportCanonical(value[key]); });
            return sorted;
        }
        return value;
    }

    function iconExportComponentsKey(components) {
        if (!components || typeof components !== 'object') return '';
        try {
            return JSON.stringify(iconExportCanonical(components));
        } catch (err) {
            return '';
        }
    }

    function iconExportComponentShape(components) {
        const shape = { keys: [], leaves: [] };
        const walk = function (node, prefix) {
            if (Array.isArray(node)) {
                if (node.length === 0) { shape.keys.push(prefix); shape.leaves.push(prefix); return; }
                node.forEach(function (item, index) { walk(item, prefix + '[' + index + ']'); });
                return;
            }
            if (node && typeof node === 'object') {
                const names = Object.keys(node);
                if (names.length === 0) { shape.keys.push(prefix); shape.leaves.push(prefix); return; }
                names.forEach(function (name) { walk(node[name], prefix + '.' + name); });
                return;
            }
            shape.keys.push(prefix);
            shape.leaves.push(prefix + '=' + String(node));
        };
        if (!components || typeof components !== 'object') return shape;
        try {
            walk(iconExportCanonical(components), '');
        } catch (err) {
            return { keys: [], leaves: [] };
        }
        return shape;
    }

    // Two component trees are compared by their LEAF nodes only (Jaccard): a leaf
    // is one concrete "path=value" pair of the stack's components. Counting the
    // property paths as well used to reward trees that merely shared their shape
    // (two different enchanted books have identical keys), so an unrelated
    // variant could beat the one that actually matches. Leaves are what
    // identifies the stack; extra leaves in the candidate are penalised by the
    // union, which keeps a superset from scoring as high as an exact match.
    function iconExportSimilarity(wanted, candidate) {
        if (!wanted || !candidate || wanted.leaves.length === 0 || candidate.leaves.length === 0) return 0;
        const candidateLeaves = new Set(candidate.leaves);
        let shared = 0;
        wanted.leaves.forEach(function (leaf) { if (candidateLeaves.has(leaf)) shared += 1; });
        const union = wanted.leaves.length + candidate.leaves.length - shared;
        return union > 0 ? shared / union : 0;
    }

    function iconExportOrderedVariants(record, wantedKey) {
        const list = record.variants.slice();
        if (!wantedKey || list.length <= 1) return list;
        let exact = -1;
        for (let i = 0; i < list.length; i += 1) {
            if (list[i].components === wantedKey) { exact = i; break; }
        }
        if (exact === 0) return list;
        if (exact > 0) {
            list.unshift(list.splice(exact, 1)[0]);
            return list;
        }
        const wantedShape = iconExportComponentShape(JSON.parse(wantedKey));
        const scored = list.map(function (variant, index) {
            if (!variant.shape) variant.shape = iconExportComponentShape(JSON.parse(variant.components));
            return { variant: variant, index: index,
                score: iconExportSimilarity(wantedShape, variant.shape) };
        });
        scored.sort(function (a, b) { return (b.score - a.score) || (a.index - b.index); });
        return scored.map(function (item) { return item.variant; });
    }

    function iconExportCandidateFiles(record, wantedKey) {
        const files = [];
        const push = function (file) {
            if (file && files.indexOf(file) < 0) files.push(file);
        };
        if (wantedKey) {
            iconExportOrderedVariants(record, wantedKey).forEach(function (variant) { push(variant.file); });
            push(record.plain);
        } else {
            push(record.plain);
            iconExportOrderedVariants(record, '').forEach(function (variant) { push(variant.file); });
        }
        return files;
    }

    function buildIconExportIndex(meta, metaLang) {
        const index = new Map();
        const byPath = new Map();
        meta.forEach(function (entry) {
            if (!entry || !entry.id || !entry.image_file) return;
            const kind = entry.type === 'fluid' ? 'fluid' : 'item';
            const key = iconExportKey(kind, entry.id);
            let record = index.get(key);
            if (!record) {
                record = { plain: null, variants: [] };
                index.set(key, record);
            }
            const name = iconExportUsableName(entry.local_name);
            if (name && !record.name) record.name = name;
            const components = iconExportComponentsKey(entry.components);
            if (components) record.variants.push({ components: components, file: entry.image_file });
            else if (!record.plain) record.plain = entry.image_file;
            if (kind === 'item') {
                const path = String(entry.id).split(':').pop().toLowerCase();
                const ids = byPath.get(path);
                if (!ids) byPath.set(path, [String(entry.id)]);
                else if (ids.indexOf(String(entry.id)) < 0) ids.push(String(entry.id));
            }
        });
        index.lang = metaLang;
        index.byPath = byPath;
        return index;
    }

    function iconExportUniqueIdByPath(path) {
        if (!ensureIconExports() || !iconExportIndex.byPath) return '';
        const ids = iconExportIndex.byPath.get(String(path || '').toLowerCase());
        return (ids && ids.length === 1) ? ids[0] : '';
    }

    function loadIconExports() {
        if (iconExportUnavailable) return;
        const wanted = (lang === 'en') ? 'en' : 'zh';
        const current = iconExportLangCache[wanted];
        if (current && current.index) {
            iconExportIndex = current.index;
            iconExportIndexLang = wanted;
            return;
        }
        if (current && current.failed) return;
        if (iconExportLoadingLang) return;

        const order = iconExportLanguageOrder().filter(function (code) {
            const cached = iconExportLangCache[code];
            return !(cached && (cached.index || cached.failed));
        });
        if (order.length === 0) {
            iconExportUnavailable = true;
            console.info('[IFM] no usable icon-exports metadata (' + ICON_EXPORTS_META_DIR +
                iconExportLanguageOrder().join('.json / ') + '.json): icons keep using the blocksitems API / name fallback');
            return;
        }

        const tryLanguage = function (position) {
            if (position >= order.length) {
                iconExportLoadingLang = null;
                return;
            }
            const code = order[position];
            iconExportLoadingLang = code;
            const tryDir = function (dirIndex) {
                if (dirIndex >= ICON_EXPORTS_META_DIRS.length) {
                    iconExportLangCache[code] = { failed: true };
                    iconExportLoadingLang = null;
                    tryLanguage(position + 1);
                    return;
                }
                const url = ICON_EXPORTS_META_DIRS[dirIndex] + code + '.json';
                fetch(url)
                    .then(function (response) {
                        if (!response.ok) throw new Error('HTTP ' + response.status);
                        return response.json();
                    })
                    .then(function (body) {
                        const meta = body && asArray(body.meta);
                        if (meta.length === 0) throw new Error('metadata is empty');
                        const index = buildIconExportIndex(meta, code);
                        iconExportLangCache[code] = { index: index };
                        iconExportIndex = index;
                        iconExportIndexLang = code;
                        iconExportLoadingLang = null;
                        console.info('[IFM] icon-exports metadata loaded: ' + url + ' (' + index.size + ' item icons' +
                            (code === wanted ? ', item names come from it too' : ', icons only: no file for the current language') + ')');
                        ['resources', 'peripherals', 'processes', 'deliveries', 'machines'].forEach(markDirty);
                        scheduleRender();
                    })
                    .catch(function (err) {
                        console.info('[IFM] icon-exports metadata unavailable (' + url + ': ' +
                            ((err && err.message) || err) + '), trying the next candidate directory');
                        tryDir(dirIndex + 1);
                    });
            };
            tryDir(0);
        };
        tryLanguage(0);
    }

    function ensureIconExports() {
        if (iconExportUnavailable) return false;
        if (!iconExportIndex || iconExportIndexLang !== ((lang === 'en') ? 'en' : 'zh')) loadIconExports();
        return !!iconExportIndex;
    }

    function iconExportEntry(kind, name) {
        if (!ensureIconExports()) return null;
        const record = iconExportIndex.get(iconExportKey(kind, name));
        return record || null;
    }

    function iconExportListedFile(kind, name) {
        const record = iconExportEntry(kind, name);
        if (!record) return null;
        return record.plain || (record.variants.length > 0 ? record.variants[0].file : null);
    }

    function iconExportFile(kind, name, components) {
        const record = iconExportEntry(kind, name);
        if (record) {
            const wanted = iconExportComponentsKey(components);
            const files = iconExportCandidateFiles(record, wanted);
            for (let i = 0; i < files.length; i += 1) {
                if (!iconExportFailedFiles.has(String(files[i]).toLowerCase())) return files[i];
            }
        }
        if (iconExportIndex) {
            const guess = iconExportConventionalFile(kind, name);
            if (guess && !iconExportFailedFiles.has(guess.toLowerCase())) return guess;
        }
        return null;
    }

    function iconExportName(kind, name, nbt) {
        const record = iconExportEntry(kind, name);
        if (!record) return '';
        if (iconExportIndexLang !== ((lang === 'en') ? 'en' : 'zh')) return '';
        return record.name || '';
    }

    function iconExportMarkFailed(file) {
        if (file) iconExportFailedFiles.add(String(file).toLowerCase());
    }
