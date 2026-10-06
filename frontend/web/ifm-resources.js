'use strict';

    let activeCraftKeys = new Set();

    function craftingKeys() {
        const keys = new Set();
        // The ledger is per material now, so "is something being done about this
        // resource" is a direct question to stores.materials.
        stores.materials.forEach(function (material) {
            if (!material || !material.id) return;
            const pending = (Number(material.queryCount) || 0) + (Number(material.automateCount) || 0) +
                (Number(material.craftingCount) || 0);
            if (pending <= 0) return;
            // A filter is its own resource kind; only placeholders fall back to item.
            const kind = material.kind === 'placeholder' ? 'item' : material.kind;
            keys.add(resourceKey(kind, material.id));
            // A placeholder's own card pulses too: the request ("craft N of that
            // placeholder") is made against the placeholder key, not the item.
            if (material.kind === 'placeholder') {
                keys.add(resourceKey('placeholder', material.id));
            }
        });
        return keys;
    }

    function isCrafting(entry) {
        if (!entry) return false;
        // A filter is its own resource kind; only placeholders fall back to item.
        const kind = entry.kind === 'placeholder' ? 'item' : entry.kind;
        if (activeCraftKeys.has(resourceKey(kind, entry.name))) return true;
        return entry.kind === 'placeholder' && activeCraftKeys.has(resourceKey('placeholder', entry.name));
    }

    function parseSearchQuery(text) {
        const query = { terms: [], mods: [], tags: [] };
        String(text === undefined || text === null ? '' : text).trim().toLowerCase().split(/\s+/)
            .forEach(function (token) {
                if (!token) return;
                if (token.charAt(0) === '#') {
                    if (token.length > 1) query.tags.push(token.slice(1));
                    return;
                }
                if (token.charAt(0) === '@') {
                    if (token.length > 1) query.mods.push(token.slice(1));
                    return;
                }
                query.terms.push(token);
            });
        return query;
    }

    function searchQueryEmpty(query) {
        return query.terms.length === 0 && query.mods.length === 0 && query.tags.length === 0;
    }

    function entryTags(entry) {
        return asArray(entry && entry.tags);
    }

    function modOfName(name) {
        const value = String(name || '').toLowerCase();
        const colon = value.indexOf(':');
        return colon >= 0 ? value.slice(0, colon) : value;
    }

    function tagMatches(tag, token) {
        const value = String(tag || '').toLowerCase();
        if (!value) return false;
        if (value === token) return true;
        const colon = value.indexOf(':');
        const namespace = colon >= 0 ? value.slice(0, colon) : 'minecraft';
        const path = colon >= 0 ? value.slice(colon + 1) : value;
        if (path === token || namespace === token) return true;
        if (value === 'minecraft:' + token) return true;
        if (path.indexOf(token) >= 0) return true;
        return value.indexOf(token) >= 0;
    }

    function tagText(tags, limit) {
        const list = asArray(tags);
        const max = limit || 12;
        const shown = list.slice(0, max).map(function (tag) { return '#' + tag; }).join(' ');
        return list.length > max ? shown + ' …' : shown;
    }

    const pinyinCache = new Map();

    function pinyinSyllables(text) {
        const key = String(text || '');
        if (!key) return [];
        if (pinyinCache.has(key)) return pinyinCache.get(key);
        if (typeof window.pinyinlite !== 'function') {
            throw new Error('[IFM] pinyinlite_full.min.js is missing: pinyin search cannot work. ' +
                'There is no keyword fallback any more - put the dictionary into frontend/web/dist/.');
        }
        const rows = window.pinyinlite(key) || [];
        const out = rows.map(function (row) {
            return (Array.isArray(row) ? row : []).map(function (item) {
                return String(item || '').toLowerCase();
            }).filter(Boolean);
        });
        if (pinyinCache.size > 4000) pinyinCache.clear();
        pinyinCache.set(key, out);
        return out;
    }

    function hasHanzi(text) {
        return /[\u3400-\u4dbf\u4e00-\u9fff]/.test(String(text || ''));
    }

    function pinyinSegmentFits(seg, syllables, start, count) {
        const limit = start + count;
        let states = [{ index: start, used: 0 }];
        for (let position = 0; position < seg.length; position += 1) {
            const char = seg.charAt(position);
            const next = [];
            const seen = {};
            const push = function (state) {
                const key = state.index + ':' + state.used;
                if (seen[key]) return;
                seen[key] = true;
                next.push(state);
            };
            for (let s = 0; s < states.length; s += 1) {
                const state = states[s];
                if (state.index < limit) {
                    const readings = syllables[state.index] || [];
                    for (let r = 0; r < readings.length; r += 1) {
                        if (readings[r].charAt(state.used) !== char) continue;
                        if (state.used + 1 >= readings[r].length) push({ index: state.index + 1, used: 0 });
                        else push({ index: state.index, used: state.used + 1 });
                    }
                }
                if (state.used > 0 && state.index + 1 < limit) {
                    const readings = syllables[state.index + 1] || [];
                    for (let r = 0; r < readings.length; r += 1) {
                        if (readings[r].charAt(0) !== char) continue;
                        if (readings[r].length === 1) push({ index: state.index + 2, used: 0 });
                        else push({ index: state.index + 1, used: 1 });
                    }
                }
            }
            states = next;
            if (states.length === 0) return false;
        }
        return states.some(function (state) {
            if (state.index === limit) return true;
            return state.index === limit - 1 && state.used > 0;
        });
    }

    function pinyinMatches(text, query) {
        const syllables = pinyinSyllables(text);
        if (syllables.length === 0) return false;
        const segments = String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
        if (segments.length === 0) return true;
        const memo = {};
        const rest = function (from, segmentIndex) {
            if (segmentIndex >= segments.length) return true;
            const key = from + '/' + segmentIndex;
            if (memo[key] !== undefined) return memo[key];
            const seg = segments[segmentIndex];
            let ok = false;
            for (let end = from; end < syllables.length && !ok; end += 1) {
                if (!pinyinSegmentFits(seg, syllables, from, end - from + 1)) continue;
                ok = rest(end + 1, segmentIndex + 1);
            }
            memo[key] = ok;
            return ok;
        };
        for (let start = 0; start < syllables.length; start += 1) {
            if (rest(start, 0)) return true;
        }
        return false;
    }

    function pinyinSearchHit(query, label, englishLabel) {
        if (lang !== 'zh') return false;
        const text = String(query || '').trim();
        if (!text) return false;
        const targets = [label, englishLabel].filter(function (value) {
            return value && hasHanzi(value);
        });
        for (let i = 0; i < targets.length; i += 1) {
            if (pinyinMatches(targets[i], text)) return true;
        }
        return false;
    }

    function matchesSearch(entry, query) {
        if (searchQueryEmpty(query)) return true;
        const name = String(entry.name || '').toLowerCase();
        const colon = name.indexOf(':');
        const namePath = colon >= 0 ? name.slice(colon + 1) : name;
        const label = displayName(entry.kind, entry.name).toLowerCase();
        const englishLabel = englishName(entry.kind, entry.name).toLowerCase();
        const tags = entryTags(entry);
        for (let i = 0; i < query.mods.length; i += 1) {
            if (modOfName(name) !== query.mods[i]) return false;
        }
        for (let i = 0; i < query.tags.length; i += 1) {
            const token = query.tags[i];
            if (!tags.some(function (tag) { return tagMatches(tag, token); })) return false;
        }
        for (let i = 0; i < query.terms.length; i += 1) {
            const term = query.terms[i];
            const hit = namePath.indexOf(term) >= 0 || label.indexOf(term) >= 0 ||
                englishLabel.indexOf(term) >= 0 ||
                pinyinSearchHit(term, label, englishLabel);
            if (!hit) return false;
        }
        return true;
    }

    // Something the storage is empty of is still craftable, so the panel lists it
    // with a count of 0 instead of hiding it (the old behaviour made a product
    // disappear exactly when the player was about to ask for it). The entries are
    // derived from the processes on every render - nothing to keep in sync - and a
    // resource that really sits in a container always wins over the synthesised one.
    function craftableMaterials() {
        const out = new Map();
        Array.from(stores.processes.values()).forEach(function (process) {
            if (processIsAbstract(process)) return;
            asArray(process.outputs).forEach(function (element) {
                let kind = null;
                let name = '';
                if (element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter') {
                    kind = element.kind;
                    name = String(element.id || '');
                } else if (element.kind === 'placeholder') {
                    // A placeholder outputs the concrete item it stands for.
                    kind = 'item';
                    name = String(element.item || '');
                }
                // "Craft reference" off: that output of the process is not an offer.
                if (!kind || !name || element.craft === false) return;
                const key = resourceKey(kind, name);
                if (out.has(key)) return;
                out.set(key, {
                    kind: kind,
                    name: name,
                    nbt: '',
                    count: 0,
                    craftable: true,
                    samples: [],
                    tags: [],
                });
            });
        });
        return out;
    }

    // One lookup for "what does this key mean to the panel": storage first, then the
    // synthesised craftable entry. Everything that resolves a resource key has to
    // ask this, otherwise a listing that the panel shows would be refused by the
    // click / send / tooltip code as "not craftable, nothing in stock".
    function resourceView(key) {
        const stored = stores.resources.get(key);
        if (stored) return stored;
        return craftableMaterials().get(key) || null;
    }

    function visibleResources() {
        let list = Array.from(stores.resources.values());
        // Any hash variant in storage counts as "we have this resource": listing the
        // bare name next to it would show the same item twice.
        const stocked = new Set();
        stores.resources.forEach(function (entry) {
            stocked.add(resourceKey(entry.kind, entry.name));
        });
        craftableMaterials().forEach(function (entry, key) {
            if (stocked.has(key)) return;
            list.push(entry);
        });
        // A material that was set for stock keeping but is neither stocked nor
        // craftable any more still has to be listed: its grey target stays visible
        // (and can be cleared with K, which needs the card to be hoverable).
        if (status && status.keepStock) {
            Object.keys(status.keepStock).forEach(function (keepKey) {
                if (stocked.has(keepKey)) return;
                const parts = splitKey(keepKey);
                if (parts[0] !== 'item' && parts[0] !== 'fluid' && parts[0] !== 'filter' &&
                    parts[0] !== 'placeholder') return;
                if (!parts[1]) return;
                const key = resourceKey(parts[0], parts[1]);
                if (list.some(function (entry) { return resourceKey(entry.kind, entry.name) === key; })) return;
                list.push({
                    kind: parts[0],
                    name: parts[1],
                    nbt: '',
                    count: 0,
                    craftable: false,
                    samples: [],
                    tags: [],
                });
            });
        }
        if (searchText) {
            const query = parseSearchQuery(searchText);
            list = list.filter(function (entry) { return matchesSearch(entry, query); });
        }
        const rank = function (entry) {
            if (entry.kind === 'placeholder') return 0;
            if (entry.kind === 'filter') return 1;
            if (entry.craftable) return 2;
            return 3;
        };
        list.sort(function (a, b) {
            const byRank = rank(a) - rank(b);
            if (byRank !== 0) return byRank;
            if (sortMode === 'name') {
                return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name), undefined,
                    { numeric: true, sensitivity: 'base' });
            }
            const diff = (Number(a.count) || 0) - (Number(b.count) || 0);
            if (diff !== 0) return sortMode === 'countAsc' ? diff : -diff;
            return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name), undefined,
                { numeric: true, sensitivity: 'base' });
        });
        return list;
    }

    const SORT_MODES = ['countDesc', 'countAsc', 'name'];
    function sortModeLabel(mode) {
        if (mode === 'countAsc') return t('sortCountAsc');
        if (mode === 'name') return t('sortName');
        return t('sortCountDesc');
    }

    function sortModeIcon(mode) {
        if (mode === 'countAsc') return 'fa-sort-amount-asc';
        if (mode === 'name') return 'fa-sort-alpha-asc';
        return 'fa-sort-amount-desc';
    }

    function renderResourceSortButton() {
        const button = el('resourceSortBtn');
        if (!button) return;
        const label = sortModeLabel(sortMode);
        button.title = t('sortTitle') + t('labelSeparator') + label;
        button.innerHTML = '<i class="fa ' + sortModeIcon(sortMode) + '"></i>';
    }

    function plainIconImg(kind, name, components) {
        const realKind = kind === 'fluid' ? 'fluid' : 'item';
        const key = resourceKey(realKind, name);
        queueMeta(realKind, name);
        const exported = iconExportFile(realKind, name, components);
        if (exported || (metaState(key) !== 'missing' && !iconFailedKeys.has(key))) {
            return iconImgTagHtml(realKind, name, '', exported);
        }
        return faGlyphHtml(realKind, name);
    }

    function filterIconHtml(entry) {
        const samples = asArray(entry.samples);
        if (samples.length === 0) {
            return '<span class="icon">' + faGlyphHtml('filter', entry.name) + '</span>';
        }
        const current = iconIndex.get(entry.name) || 0;
        const sample = samples[current % samples.length];
        queueMeta(sample.kind, sample.name);
        return '<span class="icon" data-filter-icon="' + escapeHtml(entry.name) + '" data-samples="' +
            escapeHtml(JSON.stringify(samples)) + '">' + plainIconImg(sample.kind, sample.name) + '</span>';
    }

    // 待发送/交付列表里的条目只存了 kind/name/nbt/count（addSend / setSend /
    // addOptimisticDeliveries 都不带展示字段），因此过滤器拿不到 samples，会退化成
    // 字符图标（而资源网格显示的是样本物品图标）。渲染时以资源表里的最新条目为准，
    // 取不到再退回条目自身——这样待发送区、交付区与网格的过滤器图标完全一致，
    // 也会跟着 rotateFilterIcons 一起轮换。
    function iconSourceOf(entry) {
        if (entry.kind !== 'filter' && entry.kind !== 'placeholder') return entry;
        const latest = stores.resources.get(resourceKey(entry.kind, entry.name, entry.nbt));
        return latest || entry;
    }

    // The item a placeholder stands for: its icon is what a placeholder is drawn
    // with everywhere (grid, tooltips, send list). A placeholder carries no stock of
    // its own, so this never falls back to the placeholder name.
    function placeholderItemOf(entry) {
        if (!entry || entry.kind !== 'placeholder') return '';
        const latest = stores.resources.get(resourceKey('placeholder', entry.name, entry.nbt));
        const direct = (latest && latest.item) || entry.item;
        if (direct) return String(direct);
        // A synthesised row (stock-keeping only) or a stale store entry may have lost
        // the field: the processes that output this placeholder still know it.
        let found = '';
        stores.processes.forEach(function (process) {
            if (found) return;
            asArray(process.outputs).forEach(function (element) {
                if (found) return;
                if (element.kind === 'placeholder' && element.item &&
                    String(element.name) === String(entry.name)) {
                    found = String(element.item);
                }
            });
        });
        return found;
    }

    function resourceIconHtml(entry) {
        const source = iconSourceOf(entry);
        if (source.kind === 'filter') return filterIconHtml(source);
        if (source.kind === 'placeholder') {
            const itemName = placeholderItemOf(source);
            if (!itemName) {
                // Nothing known to draw yet: the generic placeholder glyph, never the
                // placeholder name looked up as an item.
                return '<span class="icon"><i class="fa ' + iconGlyphClass('placeholder') + '"></i></span>';
            }
            queueMeta('item', itemName);
            return '<span class="icon">' + plainIconImg('item', itemName) + '</span>';
        }
        queueMeta(source.kind, source.name);
        asArray(source.samples).forEach(function (sample) { queueMeta(sample.kind, sample.name); });
        return iconHtml(source.kind, source.name);
    }

    function resourceKindLabel(kind) {
        if (kind === 'item') return t('itemKind');
        if (kind === 'fluid') return t('fluidKind');
        if (kind === 'filter') return t('filterKind2');
        return t('placeholderKind');
    }

    function kindBadgeHtml(kind, extraClass) {
        return '<span class="kind-badge kind-' + escapeHtml(kind) + (extraClass ? ' ' + extraClass : '') +
            '" title="' + escapeHtml(resourceKindLabel(kind)) + '"><i class="fa ' + kindBadgeGlyph(kind) + '"></i></span>';
    }

    // The stock-keeping target of one resource, read from the server status
    // ("kind:name" -> amount). 0 means "not maintained" (nothing is drawn).
    function keepAmountOf(entry) {
        if (!entry || !status || !status.keepStock) return 0;
        const value = Number(status.keepStock[String(entry.kind) + ':' + String(entry.name)]);
        return (isFinite(value) && value > 0) ? Math.floor(value) : 0;
    }

    // One enchantment of an item: its display label and whether it is a curse. The
    // registry name (name) decides "curse" (e.g. minecraft:vanishing_curse); the
    // label is the displayName, translated by bergamot when it is on (queued while
    // not cached yet) and shown as the English name otherwise.
    function enchantmentInfo(enchantment) {
        if (!enchantment) return { label: '', cursed: false };
        const registry = String(enchantment.name || enchantment.id || '').toLowerCase();
        const cursed = registry.indexOf('curse') >= 0;
        const raw = String(enchantment.displayName || enchantment.name || enchantment.id || '').trim();
        if (!raw) return { label: '', cursed: cursed };
        const translator = window.IFMTranslate;
        if (translator && typeof translator.isEnabled === 'function' && translator.isEnabled()) {
            const translated = typeof translator.nameFor === 'function' ? translator.nameFor(raw) : null;
            if (translated) return { label: translated, cursed: cursed };
            if (typeof translator.queueNames === 'function') translator.queueNames([raw]);
        }
        return { label: raw, cursed: cursed };
    }

    // Durability colour: interpolate red (empty) -> orange -> yellow -> green (full)
    // by the remaining fraction.
    const DURABILITY_STOPS = [
        { at: 0, rgb: [255, 107, 107] },
        { at: 0.33, rgb: [255, 182, 72] },
        { at: 0.66, rgb: [255, 209, 102] },
        { at: 1, rgb: [89, 217, 138] },
    ];
    function durabilityColour(ratio) {
        const value = Math.max(0, Math.min(1, Number(ratio) || 0));
        let lo = DURABILITY_STOPS[0];
        let hi = DURABILITY_STOPS[DURABILITY_STOPS.length - 1];
        for (let i = 0; i < DURABILITY_STOPS.length - 1; i += 1) {
            if (value >= DURABILITY_STOPS[i].at && value <= DURABILITY_STOPS[i + 1].at) {
                lo = DURABILITY_STOPS[i];
                hi = DURABILITY_STOPS[i + 1];
                break;
            }
        }
        const span = (hi.at - lo.at) || 1;
        const t2 = (value - lo.at) / span;
        const rgb = [0, 1, 2].map(function (channel) {
            return Math.round(lo.rgb[channel] + (hi.rgb[channel] - lo.rgb[channel]) * t2);
        });
        return 'rgb(' + rgb.join(',') + ')';
    }

    // The item's maximum durability: the blocksitems API reports it as max_damage
    // (an item type property); when that is not loaded yet it is derived from the
    // per-stack detail as damage / (1 - durability). null when neither is usable.
    function maxDamageOf(entry) {
        const detail = entry && entry.detail;
        if (!detail) return null;
        const damage = Number(detail.damage);
        const durability = Number(detail.durability);
        const meta = typeof metaOf === 'function' ? metaOf('item', entry.name) : null;
        const maxDamage = meta ? Number(meta.max_damage) : NaN;
        if (isFinite(maxDamage) && maxDamage > 0) return Math.round(maxDamage);
        if (isFinite(damage) && isFinite(durability) && durability < 1) {
            const total = damage / (1 - durability);
            if (isFinite(total) && total > 0) return Math.round(total);
        }
        return null;
    }

    function resourceCardHtml(entry) {
        const key = resourceKey(entry.kind, entry.name, entry.nbt);
        const isPlaceholder = entry.kind === 'placeholder';
        const countHtml = isPlaceholder ? '' : '<span class="grid-count">' + fmtCountFloor(entry.count || 0) + '</span>';
        // The "+" is only an indicator: crafting is started from the middle-click /
        // shift middle-click gesture, the mark itself is not clickable any more.
        const plusHtml = entry.craftable
            ? '<span class="grid-mark craft-mark" title="' + escapeHtml(t('craftOnly')) + '">+</span>'
            : '';
        const detail = entry.detail || null;
        const enchanted = !!(detail && asArray(detail.enchantments).length > 0);
        const durability = detail ? Number(detail.durability) : NaN;
        const hasDurability = isFinite(durability);
        let durabilityHtml = '';
        if (hasDurability) {
            const percent = Math.round(Math.max(0, Math.min(1, durability)) * 100);
            const barClass = percent >= 50 ? '' : (percent >= 20 ? ' warn' : ' bad');
            durabilityHtml = '<span class="durability" title="' + escapeHtml(t('tipDurability') +
                t('labelSeparator') + percent + '%') + '"><span class="durability-in' + barClass +
                '" style="width:' + percent + '%"></span></span>';
        }
        const keep = keepAmountOf(entry);
        let keepHtml = '';
        if (keep > 0) {
            // A placeholder has no real stock, so its target never turns green/red:
            // the badge stays grey ("off").
            const state = (isPlaceholder || !entry.craftable) ? 'off'
                : ((Number(entry.count) || 0) >= keep ? 'ok' : 'short');
            keepHtml = '<span class="grid-keep ' + state + '" title="' + escapeHtml(t('keepStockNumber', {
                keep: fmtCount(keep)
            })) + '">' + fmtCount(keep) + '</span>';
        }
        const kindBadge = kindBadgeHtml(entry.kind);
        const icon = '<span class="card-icon' + (enchanted ? ' enchant-glint' : '') + '">' +
            resourceIconHtml(entry) + '</span>';
        return '<div class="grid-item' + (isCrafting(entry) ? ' crafting' : '') +
            '" data-resource="' + escapeHtml(key) + '" data-tip-resource="' + escapeHtml(key) + '">' +
            kindBadge + plusHtml + icon + durabilityHtml + keepHtml + countHtml + '</div>';
    }

    function renderResources() {
        activeCraftKeys = craftingKeys();
        renderResourceSortButton();
        const list = visibleResources();
        queueTranslateNames(list);
        if (list.length === 0) {
            el('resourceGrid').innerHTML = '<span class="muted">' + escapeHtml(t('noData')) + '</span>';
            return;
        }
        el('resourceGrid').innerHTML = list.map(resourceCardHtml).join('');
    }

    // The resource card under the pointer: pressing K opens the stock-keeping prompt
    // for it. Cleared when the pointer leaves the grid.
    let hoveredResourceKey = '';

    function keepStockKeyOf(entry) {
        return String(entry.kind) + ':' + String(entry.name);
    }

    function openKeepStockPrompt(entry) {
        if (!entry) return;
        const isPlaceholder = entry.kind === 'placeholder';
        const key = keepStockKeyOf(entry);
        openPrompt({
            title: t('keepStockTitle', { name: displayName(entry.kind, entry.name) }),
            label: t('keepStockLabel'),
            value: keepAmountOf(entry),
            min: 0,
            // A placeholder has no stock to compare against: its target is a rolling
            // demand that keeps the producing process running.
            hint: isPlaceholder ? t('keepStockPlaceholderHint')
                : t('keepStockHint', { stock: fmtCount(entry.count || 0) }),
            onConfirm: function (value) {
                const amount = Math.max(0, Math.floor(value) || 0);
                sendRequest('set_keep_stock', {
                    kind: entry.kind,
                    name: entry.name,
                    amount: amount
                }).then(function (response) {
                    const result = response.result || {};
                    if (result.error) {
                        toast(t('requestFailed', { error: result.error }), 'error');
                        return;
                    }
                    status = status || {};
                    if (!status.keepStock) status.keepStock = {};
                    if (amount > 0) status.keepStock[key] = amount;
                    else delete status.keepStock[key];
                    renderResources();
                    toast(t('keepStockSaved', {
                        name: displayName(entry.kind, entry.name),
                        amount: fmtCount(amount)
                    }), 'success');
                }).catch(function (err) {
                    toast(t('requestFailed', { error: err.message }), 'error');
                });
            }
        });
    }

    const TIP_SELECTOR = '[data-tip-resource],[data-tip-send],[data-tip-graph],[data-tip-text]';
    let tooltipNode = null;
    let tooltipTarget = null;
    let tooltipAt = { x: 0, y: 0 };

    function tooltipBox() {
        if (!tooltipNode) {
            tooltipNode = document.createElement('div');
            tooltipNode.className = 'icon-tooltip';
            tooltipNode.style.display = 'none';
            const parent = document.body || document.documentElement;
            if (parent) parent.appendChild(tooltipNode);
        }
        return tooltipNode;
    }

    function tipField(label, value) {
        const text = (value === undefined || value === null) ? '' : String(value);
        return label + t('labelSeparator') + text;
    }

    function tipBoxHtml(title, lines) {
        let html = '<div class="tip-name">' + escapeHtml(title || '') + '</div>';
        asArray(lines).forEach(function (line) {
            if (line === '') {
                html += '<div style="height:5px"></div>';
                return;
            }
            if (line === undefined || line === null) return;
            // A plain string uses the dim registry style. An object is one detail
            // line: { text, cls } picks a class (tip-detail = white, tip-curse =
            // red), { text, color } an explicit colour (the durability gradient).
            if (typeof line === 'object') {
                if (line.text === undefined || line.text === null) return;
                if (line.color) {
                    html += '<div class="tip-detail" style="color:' + escapeHtml(String(line.color)) + '">' +
                        escapeHtml(String(line.text)) + '</div>';
                } else {
                    html += '<div class="' + escapeHtml(line.cls || 'tip-detail') + '">' +
                        escapeHtml(String(line.text)) + '</div>';
                }
                return;
            }
            html += '<div class="tip-reg">' + escapeHtml(String(line)) + '</div>';
        });
        return html;
    }

    function tipHtmlFor(node) {
        const plainTip = node.getAttribute('data-tip-text');
        if (plainTip) {
            return tipBoxHtml(plainTip, []);
        }
        const resourceAttr = node.getAttribute('data-tip-resource');
        if (resourceAttr) {
            const parts = splitKey(resourceAttr);
            const entry = resourceView(resourceAttr) || {};
            const isPlaceholder = parts[0] === 'placeholder';
            const detail = entry.detail || null;
            // Title (larger): display name + stored count.
            const title = resourceLabel(parts[0], parts[1]) +
                (isPlaceholder ? '' : ' x' + fmtCount(entry.count || 0));
            const lines = [];
            // Kind + registry on their own (white) line.
            lines.push({ cls: 'tip-detail', text: resourceKindLabel(parts[0]) + ' ' + parts[1] });
            if (isPlaceholder) {
                // The placeholder's own name is the title; the item it stands for is
                // spelled out here (that item is also what its icon shows).
                const item = placeholderItemOf(entry);
                if (item) {
                    lines.push({ cls: 'tip-detail', text: tipField(t('tipPlaceholderItem'),
                        displayName('item', item)) });
                }
            }
            if (isCrafting(entry)) lines.push({ cls: 'tip-detail', text: t('craftingNow') });
            if (detail) {
                // Enchantments: one line each; a curse (its registry name contains
                // "curse") is red.
                asArray(detail.enchantments).forEach(function (enchantment) {
                    const info = enchantmentInfo(enchantment);
                    if (info.label) {
                        lines.push({ cls: info.cursed ? 'tip-curse' : 'tip-detail', text: info.label });
                    }
                });
                // Durability: remaining / max (percent), coloured red -> orange ->
                // yellow -> green. Without a known max only the used points are
                // shown, in white.
                const damage = Number(detail.damage);
                const maxDamage = maxDamageOf(entry);
                if (maxDamage !== null) {
                    const usedPoints = isFinite(damage) ? Math.round(damage) : 0;
                    const remaining = Math.max(0, maxDamage - usedPoints);
                    const ratio = maxDamage > 0 ? (remaining / maxDamage) : 0;
                    lines.push({
                        text: t('tipDurability') + ' ' + remaining + ' / ' + maxDamage +
                            ' (' + Math.round(ratio * 100) + '%)',
                        color: durabilityColour(ratio),
                    });
                } else if (isFinite(damage) && damage >= 0) {
                    lines.push({ cls: 'tip-detail', text: t('tipDurabilityLoss') + ' ' + Math.round(damage) });
                }
            }
            // Tags: one per line.
            entryTags(entry).forEach(function (tag) {
                lines.push({ cls: 'tip-detail', text: '#' + tag });
            });
            if (parts[2]) lines.push({ cls: 'tip-detail', text: t('nbt') + ' ' + parts[2] });
            const pending = sendList.get(resourceAttr);
            if (pending) {
                lines.push({ cls: 'tip-detail', text: tipField(t('tipSendAmount'), fmtCount(pending.count)) });
            }
            if (entry.craftable) {
                lines.push({ cls: 'tip-detail', text: tipField(t('craftable'), t('craftOnly')) });
            }
            const keep = keepAmountOf(entry);
            if (keep > 0) {
                lines.push({ cls: 'tip-detail', text: tipField(t('keepStockNumber', { keep: fmtCount(keep) }), fmtCount(keep)) });
            }
            lines.push('', t('tipResourceClick'));
            if (entry.craftable) lines.push(t('tipCraftClick'));
            return tipBoxHtml(title, lines);
        }
        const sendAttr = node.getAttribute('data-tip-send');
        if (sendAttr) {
            const parts = splitKey(sendAttr);
            const entry = sendList.get(sendAttr) || {};
            const stock = resourceView(sendAttr) || {};
            const lines = [
                tipField(t('tipRegistry'), parts[1]),
                tipField(t('tipKind'), resourceKindLabel(parts[0])),
            ];
            const tags = entryTags(stock);
            if (tags.length > 0) lines.push(tipField(t('tipTags'), tagText(tags)));
            lines.push(tipField(t('tipStored'), fmtCount(stock.count || 0)));
            lines.push(tipField(t('tipSendAmount'), fmtCount(entry.count || 0)));
            lines.push('');
            lines.push(t('tipSendClick'));
            return tipBoxHtml(resourceLabel(parts[0], parts[1]), lines);
        }
        const graphAttr = node.getAttribute('data-tip-graph');
        if (graphAttr) {
            const info = nodeTooltip.get(graphAttr);
            if (!info) return '';
            return tipBoxHtml(info.title, info.lines);
        }
        return '';
    }
    function positionTooltip(x, y) {
        tooltipAt = { x: x, y: y };
        const node = tooltipBox();
        const width = node.offsetWidth || 0;
        const height = node.offsetHeight || 0;
        let left = x + 16;
        let top = y + 16;
        if (left + width > window.innerWidth - 8) left = Math.max(8, window.innerWidth - width - 8);
        if (top + height > window.innerHeight - 8) top = Math.max(8, window.innerHeight - height - 8);
        node.style.left = left + 'px';
        node.style.top = top + 'px';
    }

    function showTooltip(target, x, y) {
        const html = tipHtmlFor(target);
        if (!html) {
            hideTooltip();
            return;
        }
        tooltipTarget = target;
        const node = tooltipBox();
        node.innerHTML = html;
        node.style.display = 'block';
        positionTooltip(x, y);
    }

    function hideTooltip() {
        tooltipTarget = null;
        if (tooltipNode) tooltipNode.style.display = 'none';
    }

    function refreshTooltip() {
        if (!tooltipTarget) return;
        if (document.contains(tooltipTarget)) {
            positionTooltip(tooltipAt.x, tooltipAt.y);
            return;
        }
        const under = document.elementFromPoint ? document.elementFromPoint(tooltipAt.x, tooltipAt.y) : null;
        const target = (under && under.closest) ? under.closest(TIP_SELECTOR) : null;
        if (!target) {
            hideTooltip();
            return;
        }
        showTooltip(target, tooltipAt.x, tooltipAt.y);
    }

    function bindIconTooltips() {
        document.addEventListener('mouseover', function (event) {
            const target = (event.target && event.target.closest) ? event.target.closest(TIP_SELECTOR) : null;
            if (!target || target === tooltipTarget) return;
            showTooltip(target, event.clientX, event.clientY);
        });
        document.addEventListener('mousemove', function (event) {
            if (!tooltipTarget) return;
            if (!document.contains(tooltipTarget)) {
                hideTooltip();
                return;
            }
            positionTooltip(event.clientX, event.clientY);
        });
        document.addEventListener('mouseout', function (event) {
            const target = (event.target && event.target.closest) ? event.target.closest(TIP_SELECTOR) : null;
            if (!target || target !== tooltipTarget) return;
            hideTooltip();
        });
        window.addEventListener('scroll', hideTooltip, true);
        window.addEventListener('resize', hideTooltip);
    }

    function sendCap(a, b, c) {
        const args = resourceArgs(a, b, c);
        const entry = resourceView(resourceKey(args[0], args[1], args[2]));
        if (!entry) return 0;
        return entry.craftable ? Infinity : Math.max(0, entry.count || 0);
    }

    function addSend(a, b, c) {
        let resource, delta;
        if (a && typeof a === 'object') {
            resource = a;
            delta = b;
        } else {
            resource = { kind: a, name: b };
            delta = c;
        }
        const key = resourceKey(resource.kind, resource.name, resource.nbt);
        const entry = sendList.get(key) || { kind: resource.kind, name: resource.name, nbt: resource.nbt, count: 0 };
        let next = entry.count + delta;
        const cap = sendCap(resource);
        if (next > cap) next = cap;
        if (next <= 0) {
            sendList.delete(key);
        } else {
            entry.count = next;
            sendList.set(key, entry);
        }
        renderSend();
    }

    function setSend(a, b, c) {
        let resource, count;
        if (a && typeof a === 'object') {
            resource = a;
            count = b;
        } else {
            resource = { kind: a, name: b };
            count = c;
        }
        const key = resourceKey(resource.kind, resource.name, resource.nbt);
        let next = Math.max(0, Math.floor(count) || 0);
        const cap = sendCap(resource);
        if (next > cap) next = cap;
        if (next <= 0) {
            sendList.delete(key);
        } else {
            sendList.set(key, { kind: resource.kind, name: resource.name, nbt: resource.nbt, count: next });
        }
        renderSend();
    }

    let optimisticDeliveries = [];

    function sendKeyOf(entry) {
        return resourceKey(entry.kind, entry.name, entry.nbt);
    }

    function addOptimisticDeliveries(items) {
        items.forEach(function (item) {
            const key = sendKeyOf(item);
            optimisticDeliveries = optimisticDeliveries.filter(function (other) {
                return sendKeyOf(other) !== key;
            });
            optimisticDeliveries.push({
                kind: item.kind, name: item.name, nbt: item.nbt, count: item.count, at: Date.now()
            });
        });
    }

    function dropOptimisticDeliveries(items) {
        const keys = {};
        items.forEach(function (item) { keys[sendKeyOf(item)] = true; });
        optimisticDeliveries = optimisticDeliveries.filter(function (entry) {
            return !keys[sendKeyOf(entry)];
        });
    }

    let optimisticArmed = false;
    let optimisticArmedAt = 0;
    let optimisticSweeps = 0;
    let optimisticTimer = null;
    const OPTIMISTIC_SETTLE_MS = 2500;

    function clearOptimisticTimer() {
        if (optimisticTimer) {
            clearTimeout(optimisticTimer);
            optimisticTimer = null;
        }
    }

    function armOptimisticDeliveries() {
        optimisticArmed = true;
        optimisticArmedAt = Date.now();
        optimisticSweeps = 0;
        clearOptimisticTimer();
        optimisticTimer = setTimeout(function () {
            optimisticTimer = null;
            const before = optimisticDeliveries.length;
            settleOptimisticDeliveries();
            if (before > 0) {
                markDirty('deliveries');
                scheduleRender();
            }
        }, OPTIMISTIC_SETTLE_MS);
    }

    function settleOptimisticDeliveries() {
        clearOptimisticTimer();
        const before = optimisticDeliveries.length;
        optimisticDeliveries = [];
        optimisticSweeps = 0;
        return before > 0;
    }

    function reconcileOptimisticDeliveries(force) {
        if (!optimisticArmed || optimisticDeliveries.length === 0) return false;
        optimisticSweeps += 1;
        const settled = force === true || optimisticSweeps >= 2 ||
            (Date.now() - optimisticArmedAt) >= 1500;
        if (!settled) return false;
        return settleOptimisticDeliveries();
    }

    function deliveryEntries() {
        const out = [];
        const real = {};
        Array.from(stores.deliveries.values()).forEach(function (item) {
            real[sendKeyOf(item)] = item;
        });
        const nowMs = Date.now();
        optimisticDeliveries = optimisticDeliveries.filter(function (entry) {
            if (real[sendKeyOf(entry)]) return false;
            return nowMs - (Number(entry.at) || 0) < 60000;
        });
        optimisticDeliveries.slice().reverse().forEach(function (entry) {
            out.push({ kind: entry.kind, name: entry.name, nbt: entry.nbt, count: entry.count, pending: true });
        });
        Array.from(stores.deliveries.values())
            .sort(function (a, b) { return (Number(b.id) || 0) - (Number(a.id) || 0); })
            .forEach(function (item) {
                out.push({
                    id: item.id,
                    kind: item.kind,
                    name: item.name,
                    nbt: item.nbt,
                    count: Number(item.remaining || item.total || 0),
                    total: Number(item.total || 0),
                    container: item.container,
                    process: item.processName,
                    error: describeMessage(item.lastError)
                });
            });
        return out;
    }

    function deliveryItemHtml(entry) {
        const tip = entry.error || entry.container || entry.process || '';
        const cancel = entry.id
            ? '<span class="grid-mark danger" data-delivery-cancel="' + escapeHtml(String(entry.id)) + '" title="' +
              escapeHtml(t('deliveryCancel')) + '">×</span>'
            : '';
        const total = Number(entry.total || 0);
        const countText = fmtCount(entry.count) +
            (total > 0 && total !== Number(entry.count || 0)
                ? '<span class="delivery-total" title="' + escapeHtml(t('deliveryTotalTitle')) + '">/' +
                  fmtCount(total) + '</span>'
                : '');
        const errorMark = entry.error
            ? '<span class="grid-mark danger delivery-error-mark" title="' + escapeHtml(entry.error) + '">!</span>'
            : '';
        return '<div class="grid-item delivery-item' + (entry.pending ? ' pending' : '') +
            (entry.error ? ' error' : '') + '"' +
            ' data-delivery="' + escapeHtml(sendKeyOf(entry)) + '"' +
            (entry.id ? ' data-delivery-id="' + escapeHtml(String(entry.id)) + '"' : '') +
            (tip ? ' title="' + escapeHtml(tip) + '"' : '') + '>' +
            cancel +
            errorMark +
            kindBadgeHtml(entry.kind) +
            resourceIconHtml(entry) +
            '<span class="grid-count">' + countText + '</span>' +
            '</div>';
    }

    const HIDE_GRACE_MS = 600;
    let panelHideTimer = null;
    let deliveryPanelWanted = false;
    let lastSendHtml = '';
    let lastDeliveryHtml = '';

    // The send list and the deliveries are the bottom toolbar of the resources page: it is
    // shown while that page is on screen and there is something in it (or was, within the
    // grace period of a just emptied list). Everything goes through
    // refreshDeliveryPanelVisibility, so a page switch and a data change can never fight
    // over the same style property.
    function deliveryPanelVisible() {
        const onResources = typeof currentPanel === 'function' ? currentPanel() === 'resources' : true;
        return onResources && deliveryPanelWanted;
    }

    function refreshDeliveryPanelVisibility() {
        const panel = el('deliveryPanel');
        if (!panel) return;
        const show = deliveryPanelVisible();
        if (show && panelHideTimer) {
            clearTimeout(panelHideTimer);
            panelHideTimer = null;
        }
        const want = show ? '' : 'none';
        if (panel.style.display !== want) panel.style.display = want;
        syncDeliveryPanelSpacing();
    }

    function scheduleDeliveryPanelHide() {
        if (!deliveryPanelWanted || panelHideTimer) return;
        panelHideTimer = setTimeout(function () {
            panelHideTimer = null;
            if (!serverSeen) return;
            const grid = el('sendGrid');
            const deliveryGrid = el('deliveryGrid');
            const stillEmpty = (!grid || grid.innerHTML === '') &&
                (!deliveryGrid || deliveryGrid.innerHTML === '');
            if (!stillEmpty) return;
            deliveryPanelWanted = false;
            refreshDeliveryPanelVisibility();
        }, HIDE_GRACE_MS);
    }

    function syncDeliveryPanelVisibility(hasAny) {
        deliveryPanelWanted = hasAny === true;
        if (deliveryPanelWanted) {
            refreshDeliveryPanelVisibility();
            return;
        }
        if (!deliveryPanelVisible()) {
            // Another page is on screen, so the toolbar is hidden anyway: no grace.
            if (panelHideTimer) {
                clearTimeout(panelHideTimer);
                panelHideTimer = null;
            }
            refreshDeliveryPanelVisibility();
            return;
        }
        scheduleDeliveryPanelHide();
    }

    function renderSend() {
        const entries = Array.from(sendList.values());
        const deliveries = deliveryEntries();
        const hasAny = entries.length > 0 || deliveries.length > 0;
        syncDeliveryPanelVisibility(hasAny);
        const grid = el('sendGrid');
        const deliveryGrid = el('deliveryGrid');
        if (!grid || !deliveryGrid) return;
        if (!hasAny) {
            if (lastSendHtml !== '') {
                grid.innerHTML = '';
                lastSendHtml = '';
            }
            if (lastDeliveryHtml !== '') {
                deliveryGrid.innerHTML = '';
                lastDeliveryHtml = '';
            }
            syncDeliveryPanelSpacing();
            return;
        }
        const sendHtml = entries.map(function (entry) {
            const key = resourceKey(entry.kind, entry.name, entry.nbt);
            return '<div class="grid-item" data-send="' + escapeHtml(key) + '" data-tip-send="' + escapeHtml(key) + '">' +
                kindBadgeHtml(entry.kind) +
                '<span class="grid-mark danger" data-send-remove="' + escapeHtml(key) + '" title="' +
                escapeHtml(t('pickerRemove')) + '">×</span>' +
                resourceIconHtml(entry) +
                '<span class="grid-count">' + fmtCount(entry.count) + '</span>' +
                '</div>';
        }).join('');
        const deliveryHtml = deliveries.map(deliveryItemHtml).join('');
        if (sendHtml !== lastSendHtml) {
            grid.innerHTML = sendHtml;
            lastSendHtml = sendHtml;
        }
        if (deliveryHtml !== lastDeliveryHtml) {
            deliveryGrid.innerHTML = deliveryHtml;
            lastDeliveryHtml = deliveryHtml;
        }
        syncDeliveryPanelSpacing();
    }

    function animateSendToDelivery(pairs) {
        const ghosts = [];
        pairs.forEach(function (pair) {
            if (!pair.fromRect || !pair.node) return;
            if (!pair.fromRect.width && !pair.fromRect.height) return;
            const ghost = pair.node.cloneNode(true);
            ghost.classList.add('send-ghost');
            ghost.style.left = pair.fromRect.left + 'px';
            ghost.style.top = pair.fromRect.top + 'px';
            ghost.style.width = pair.fromRect.width + 'px';
            ghost.style.height = pair.fromRect.height + 'px';
            document.body.appendChild(ghost);
            void ghost.offsetWidth;
            let toRect = pair.toRect;
            if (!toRect || (!toRect.width && !toRect.height)) {
                const grid = el('deliveryGrid');
                toRect = grid ? grid.getBoundingClientRect() : null;
            }
            // The send list is a panel page and may well be hidden while something is put
            // on it: its rect is all zeros then, and the animation would fly the ghost
            // into the corner of the window. Skip such a pair instead.
            if (!toRect || (!toRect.width && !toRect.height)) {
                ghost.remove();
                return;
            }
            ghosts.push({ node: ghost, from: pair.fromRect, to: toRect });
        });
        if (ghosts.length === 0) return;
        requestAnimationFrame(function () {
            ghosts.forEach(function (item) {
                const scale = item.from.width > 0 ? (item.to.width / item.from.width) : 1;
                item.node.style.transform = 'translate(' + (item.to.left - item.from.left) + 'px,' +
                    (item.to.top - item.from.top) + 'px) scale(' + scale + ')';
                item.node.style.opacity = '.25';
            });
            setTimeout(function () {
                ghosts.forEach(function (item) { item.node.remove(); });
            }, 480);
        });
    }

    function renderSendContainerSelect() {
        const select = el('sendContainer');
        const previous = select.value;
        const options = Array.from(stores.containers.values())
            .filter(function (item) { return item.role === 'output'; })
            .sort(function (a, b) { return containerKeyOf(a).localeCompare(containerKeyOf(b)); });
        select.innerHTML = options.map(function (item) {
            const kindLabel = item.kind === 'fluid' ? t('fluidKind') : t('itemKind');
            return '<option value="' + escapeHtml(containerKeyOf(item)) + '">' +
                escapeHtml(item.name + ' [' + kindLabel + ']') + '</option>';
        }).join('');
        if (previous && options.some(function (item) { return containerKeyOf(item) === previous; })) {
            select.value = previous;
        }
    }
