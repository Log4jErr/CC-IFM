// IFM :: web/ifm-resources.js
// 资源网格 / 搜索语法 / 悬停详情 / 待发送面板
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 资源网格 =====================
    // 正在合成的物品（运行中流程的产物）：排到最前面，并用彩色边框高亮
    let activeCraftKeys = new Set();

    function craftingKeys() {
        const keys = new Set();
        stores.processes.forEach(function (process) {
            const record = stores.runtime.get(process.name) || {};
            const active = (record.state && record.state !== 'idle') || (record.batch || 0) > 0 ||
                (record.remaining || 0) > 0 || (record.userCount || 0) > 0 || (record.downstreamCount || 0) > 0;
            if (!active) return;
            asArray(process.outputs).forEach(function (output) {
                if ((output.kind === 'item' || output.kind === 'fluid') && output.id) {
                    keys.add(resourceKey(output.kind, output.id));
                } else if (output.kind === 'placeholder' && output.item) {
                    keys.add(resourceKey('item', output.item));
                }
            });
        });
        return keys;
    }

    function isCrafting(entry) {
        if (!entry) return false;
        return activeCraftKeys.has(resourceKey(entry.kind === 'fluid' ? 'fluid' : 'item', entry.name));
    }

    // 资源排序（1.6.11）：三种模式统一在 visibleResources() 里实现；
    // 正在合成的资源仍然带 .crafting 高亮（这是视觉标记，不再参与排序）。

    // ===================== 搜索语法：关键词 / @模组 / #标签 =====================
    // 空格分隔的多个条件同时满足（AND）：
    //   cobble           → 名称 / 显示名 / 标签里包含 cobble
    //   @create          → 只看 create 这个模组的物品
    //   #minecraft:logs  → 只看带该标签的物品（写 #logs 也能匹配 minecraft:logs）
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

    // 标签匹配：#ingot 既能匹配 minecraft:ingot / c:ingot，也能匹配 c:ingots/copper 这类
    // “同一命名空间下更长的路径”，所以这里是包含匹配而不是只比相等；
    // 反过来写完整标签（#c:ingots/copper、#minecraft:ingot）也照样能匹配。
    function tagMatches(tag, token) {
        const value = String(tag || '').toLowerCase();
        if (!value) return false;
        if (value === token) return true;
        const colon = value.indexOf(':');
        const namespace = colon >= 0 ? value.slice(0, colon) : 'minecraft';
        const path = colon >= 0 ? value.slice(colon + 1) : value;
        if (path === token || namespace === token) return true;
        if (value === 'minecraft:' + token) return true;
        // 部分匹配：#ingot → c:ingots/copper、minecraft:ingot；#minecraft:ingot → minecraft:ingots
        if (path.indexOf(token) >= 0) return true;
        return value.indexOf(token) >= 0;
    }

    // 标签文本（悬停详情用）：最多显示 limit 条，超出的用省略号
    function tagText(tags, limit) {
        const list = asArray(tags);
        const max = limit || 12;
        const shown = list.slice(0, max).map(function (tag) { return '#' + tag; }).join(' ');
        return list.length > max ? shown + ' …' : shown;
    }

    // ===================== 中文拼音搜索（任务 7，1.6.11）=====================
    // 只在中文界面 + pinyinlite 可用时生效。pinyinlite 由 index.html 里的
    // <script src="dist/pinyinlite_full.min.js"> 提供：pinyinlite('增长') => [['ceng','zeng'],['zhang','chang']]
    // 匹配规则（用户给出的例子，逐条实现）：
    //   * 忽略声调（pinyinlite 给的就是无声调音节），**任意读音都算**（孳生读音全都要试）；
    //   * 查询串按空格切成若干段，每段吃「1 个或多个连续音节」，每个音节可以只吃它读音的**前缀**
    //     （所以 "g" 能匹配 gong、"zt" 能匹配 gong+zuo+tai 的第 2、3 个音节的声母）；
    //   * 段与段之间必须**紧挨**（不许跳音节）："gt" ✗、"gong tai" ✗；但可以从中间开始："tai" ✓、"zt" ✓。
    const pinyinCache = new Map();

    function pinyinAvailable() {
        return typeof window.pinyinlite === 'function';
    }

    function pinyinSyllables(text) {
        const key = String(text || '');
        if (!key) return [];
        if (pinyinCache.has(key)) return pinyinCache.get(key);
        let rows = [];
        try {
            rows = window.pinyinlite(key) || [];
        } catch (err) {
            rows = [];
        }
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

    // 一段（seg）能否恰好由 syllables[start..start+count-1] 拼出来。
    // 规则：每个音节只吃它读音的**前缀**（≥1 个字符），片与片之间紧挨着（不许跳音节）；
    // 本音节吃过至少一个字符后，可以结束这一片、到下一个音节继续吃（这就是 "gzt" = g|z|t 的由来）。
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
                // ① 继续在当前音节里吃字符
                if (state.index < limit) {
                    const readings = syllables[state.index] || [];
                    for (let r = 0; r < readings.length; r += 1) {
                        if (readings[r].charAt(state.used) !== char) continue;
                        if (state.used + 1 >= readings[r].length) push({ index: state.index + 1, used: 0 });
                        else push({ index: state.index, used: state.used + 1 });
                    }
                }
                // ② 本音节已经吃过字符：可以结束这一片，转入下一个音节（下一个音节必须紧挨着）
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
        // 必须**吃满** count 个音节（最后一个可以只吃一半，但必须至少吃了一个字符）：
        // 否则片段会“假装”跨过中间音节，出现 "gong tai" 这种越位匹配。
        return states.some(function (state) {
            if (state.index === limit) return true;
            return state.index === limit - 1 && state.used > 0;
        });
    }

    function pinyinMatches(text, query) {
        if (!pinyinAvailable()) return false;
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

    // 中/英任何一个名字命中拼音都算（只在中文界面开启）
    function pinyinSearchHit(query, label, englishLabel) {
        if (lang !== 'zh' || !pinyinAvailable()) return false;
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
        // 注册名的**路径部分**（去掉模组命名空间）：搜索 "create" 不该命中所有 create 模组的物品，
        // 想按模组搜请写 @create（用户第 5 项要求）；标签同理，必须写 #tag。
        const colon = name.indexOf(':');
        const namePath = colon >= 0 ? name.slice(colon + 1) : name;
        const label = displayName(entry.kind, entry.name).toLowerCase();
        // 翻译开关打开时：中文译名与英文原名都能搜到
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

    function visibleResources() {
        let list = Array.from(stores.resources.values());
        if (searchText) {
            const query = parseSearchQuery(searchText);
            list = list.filter(function (entry) { return matchesSearch(entry, query); });
        }
        list.sort(function (a, b) {
            if (sortMode === 'name') {
                return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name), undefined,
                    { numeric: true, sensitivity: 'base' });
            }
            // 数量升序 / 降序（1.6.11 的新默认）：数量相同的按名字排，保证顺序稳定
            const diff = (Number(a.count) || 0) - (Number(b.count) || 0);
            if (diff !== 0) return sortMode === 'countAsc' ? diff : -diff;
            return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name), undefined,
                { numeric: true, sensitivity: 'base' });
        });
        return list;
    }

    // 排序按钮的图标与提示：跟着当前模式变（点击顺序 数量降序 → 数量升序 → 字典序 → 数量降序）
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
        button.title = t('sortTitle') + '：' + label;
        button.innerHTML = '<i class="fa ' + sortModeIcon(sortMode) + '"></i>';
    }

    function plainIconImg(kind, name) {
        const realKind = kind === 'fluid' ? 'fluid' : 'item';
        const key = resourceKey(realKind, name);
        queueMeta(realKind, name);
        // 三档优先级（1.6.12，任务 8）：① icon-exports 本地导出图片（离线可用、与游戏里一致；
        // NBT 变体优先匹配）→ ② blocksitems 接口图标 → ③ 名称字形兜底（见 ifmIconFallback）。
        // 出图统一走 iconImgTagHtml：与资源网格主图标 / 外设方块卡是同一个实现，
        // 免得哪条路径漏掉第 ① 层（导出图就会“有文件却没被引用”）。
        const exported = iconExportFile(realKind, name);
        // 本地也没有、接口又明确说“没有这个资源”时别白刷一次 404，直接用名称字形
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

    function resourceIconHtml(entry) {
        if (entry.kind === 'filter') return filterIconHtml(entry);
        if (entry.kind === 'placeholder') {
            const itemName = entry.item || entry.name;
            queueMeta('item', itemName);
            return '<span class="icon">' + plainIconImg('item', itemName) + '</span>';
        }
        queueMeta(entry.kind, entry.name);
        asArray(entry.samples).forEach(function (sample) { queueMeta(sample.kind, sample.name); });
        return iconHtml(entry.kind, entry.name);
    }

    function resourceKindLabel(kind) {
        if (kind === 'item') return t('itemKind');
        if (kind === 'fluid') return t('fluidKind');
        if (kind === 'filter') return t('filterKind2');
        return t('placeholderKind');
    }

    // 类型徽标（资源卡片左上角 / 机器容器芯片共用）：字形见 kindBadgeGlyph（核心文件里）
    function kindBadgeHtml(kind, extraClass) {
        return '<span class="kind-badge kind-' + escapeHtml(kind) + (extraClass ? ' ' + extraClass : '') +
            '" title="' + escapeHtml(resourceKindLabel(kind)) + '"><i class="fa ' + kindBadgeGlyph(kind) + '"></i></span>';
    }

    function resourceCardHtml(entry) {
        const key = resourceKey(entry.kind, entry.name);
        const isPlaceholder = entry.kind === 'placeholder';
        const countHtml = isPlaceholder ? '' : '<span class="grid-count">' + fmtCount(entry.count || 0) + '</span>';
        const plusHtml = entry.craftable
            ? '<span class="grid-mark" data-craft="' + escapeHtml(key) + '" title="' + escapeHtml(t('craftOnly')) + '">+</span>'
            : '';
        // 左上角标出项目类型（物品 / 流体 / 过滤器 / 占位符）
        const kindBadge = kindBadgeHtml(entry.kind);
        // 仿 meweb：格子里只放图标，左上角类型徽标，右上角 +（可合成），右下角数量，详情悬停显示
        // 正在合成的物品加 crafting 类：彩色边框 + 呼吸动画
        return '<div class="grid-item' + (isCrafting(entry) ? ' crafting' : '') +
            '" data-resource="' + escapeHtml(key) + '" data-tip-resource="' + escapeHtml(key) + '">' +
            kindBadge + plusHtml + resourceIconHtml(entry) + countHtml + '</div>';
    }

    function renderResources() {
        // 正在合成的物品仍然会被标上 .crafting 高亮：每次重画前按运行中的流程重算一遍
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

    // ===================== 悬停详情（仿 meweb 的 item-tooltip） =====================
    // 网格里只显示图标，名称 / 注册名 / 数量 / 操作说明等都在悬停时用这个悬浮框显示。
    const TIP_SELECTOR = '[data-tip-resource],[data-tip-send],[data-tip-graph]';
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
        return label + '：' + text;
    }

    function tipBoxHtml(title, lines) {
        let html = '<div class="tip-name">' + escapeHtml(title || '') + '</div>';
        asArray(lines).forEach(function (line) {
            if (line === '') {
                html += '<div style="height:5px"></div>';
                return;
            }
            if (line === undefined || line === null) return;
            html += '<div class="tip-reg">' + escapeHtml(String(line)) + '</div>';
        });
        return html;
    }

    // 悬停内容依据当前的本地数据实时生成（不会显示旧值）
    function tipHtmlFor(node) {
        const resourceAttr = node.getAttribute('data-tip-resource');
        if (resourceAttr) {
            const parts = splitKey(resourceAttr);
            const entry = stores.resources.get(resourceAttr) || {};
            const lines = [
                tipField(t('tipRegistry'), parts[1]),
                tipField(t('tipKind'), resourceKindLabel(parts[0])),
            ];
            if (isCrafting(entry)) lines.push(t('craftingNow'));
            const tags = entryTags(entry);
            if (tags.length > 0) lines.push(tipField(t('tipTags'), tagText(tags)));
            if (parts[0] !== 'placeholder') lines.push(tipField(t('tipStored'), fmtCount(entry.count || 0)));
            const pending = sendList.get(resourceAttr);
            if (pending) lines.push(tipField(t('tipSendAmount'), fmtCount(pending.count)));
            if (entry.craftable) lines.push(tipField(t('craftable'), t('craftOnly')));
            lines.push('', t('tipResourceClick'));
            if (entry.craftable) lines.push(t('tipCraftClick'));
            return tipBoxHtml(resourceLabel(parts[0], parts[1]), lines);
        }
        const sendAttr = node.getAttribute('data-tip-send');
        if (sendAttr) {
            const parts = splitKey(sendAttr);
            const entry = sendList.get(sendAttr) || {};
            const stock = stores.resources.get(sendAttr) || {};
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

    // 网格重画后悬停的格子会被替换掉：按鼠标位置找回新格子，悬停信息不会卡住
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

    // ===================== 待发送网格 =====================
    function sendCap(kind, name) {
        const entry = stores.resources.get(resourceKey(kind, name));
        if (!entry) return 0;
        return entry.craftable ? Infinity : Math.max(0, entry.count || 0);
    }

    function addSend(kind, name, delta) {
        const key = resourceKey(kind, name);
        const entry = sendList.get(key) || { kind: kind, name: name, count: 0 };
        let next = entry.count + delta;
        const cap = sendCap(kind, name);
        if (next > cap) next = cap;
        if (next <= 0) {
            sendList.delete(key);
        } else {
            entry.count = next;
            sendList.set(key, entry);
        }
        renderSend();
    }

    function setSend(kind, name, count) {
        const key = resourceKey(kind, name);
        let next = Math.max(0, Math.floor(count) || 0);
        const cap = sendCap(kind, name);
        if (next > cap) next = cap;
        if (next <= 0) {
            sendList.delete(key);
        } else {
            sendList.set(key, { kind: kind, name: name, count: next });
        }
        renderSend();
    }

    // ===================== 发送面板：待发送（左，先进先出）+ 发送中（右，最新提交的排最前） =====================
    // 刚点「发送」时服务端队列要等它下一 tick 才回传，这里先放一条“乐观项”，
    // 让材料立刻出现在「发送中」；服务端回传同一种材料后它就退休（见 deliveryEntries）。
    let optimisticDeliveries = [];

    function sendKeyOf(entry) {
        return resourceKey(entry.kind, entry.name);
    }

    function addOptimisticDeliveries(items) {
        items.forEach(function (item) {
            const key = sendKeyOf(item);
            optimisticDeliveries = optimisticDeliveries.filter(function (other) {
                return sendKeyOf(other) !== key;
            });
            optimisticDeliveries.push({ kind: item.kind, name: item.name, count: item.count, at: Date.now() });
        });
    }

    function dropOptimisticDeliveries(items) {
        const keys = {};
        items.forEach(function (item) { keys[sendKeyOf(item)] = true; });
        optimisticDeliveries = optimisticDeliveries.filter(function (entry) {
            return !keys[sendKeyOf(entry)];
        });
    }

    // ===== 乐观占位的“增量核对”（1.6.12，任务 5）=====
    // 后台真正发完物品后，界面上的「发送中」偶尔会一直留着那条占位：以前只在渲染时按时间猜
    // （“服务端 1.5 秒后又推过队列”），没有推送就不会重算。
    // 现在改成确定性做法：
    //   ① 服务端**确认收到**这次发送请求之后（send_items 的响应回来）才“武装”这些占位；
    //   ② 之后每收到一次发送队列的增量更新，就核对一次：队列里没有它 = 已经发完/被拒 → 立刻退休，
    //      并主动重画（不再等下一次渲染）。这就是它要求的“相同的增量更新行为”。
    let optimisticArmed = false;
    let optimisticArmedAt = 0;
    let optimisticSweeps = 0;

    function armOptimisticDeliveries() {
        optimisticArmed = true;
        optimisticArmedAt = Date.now();
        optimisticSweeps = 0;
    }

    /// 核对并移除已经不在服务端队列里的占位；返回是否真的移除了（调用方据此重画）
    function reconcileOptimisticDeliveries() {
        if (!optimisticArmed || optimisticDeliveries.length === 0) return false;
        optimisticSweeps += 1;
        // 响应回来之后的**第 1 次**推送，内容可能是在服务端处理这条请求之前收集的，
        // 那时队列里当然还没有它 —— 所以再等一次推送（或 1.5 秒）才敢把“队列里没有它”
        // 当成“已经发完 / 被拒”，避免刚发出的东西立刻从「发送中」闪掉。
        const settled = optimisticSweeps >= 2 || (Date.now() - optimisticArmedAt) >= 1500;
        if (!settled) return false;
        const before = optimisticDeliveries.length;
        // 队列里有它 → 由服务端的真实条目接管；队列里没有它 → 已经发完/被拒 → 退休。
        // 两种情况都该把本地占位清掉（否则就是一直留着的那条“发送中”）。
        optimisticDeliveries = [];
        return before !== 0;
    }

    // 发送中：乐观项（最新提交的排最前）+ 服务端队列（按 id 从后往前 = 最新提交的排最前）
    function deliveryEntries() {
        const out = [];
        const real = {};
        Array.from(stores.deliveries.values()).forEach(function (item) {
            real[sendKeyOf(item)] = item;
        });
        // 服务端已经有这种材料了（或增量核对发现它已经不在队列里）：乐观项退休。
        // 实测兜底：超过 1 分钟还没对上就当它已经不在队列里（离线/丢包时不会永远残留）。
        const nowMs = Date.now();
        optimisticDeliveries = optimisticDeliveries.filter(function (entry) {
            if (real[sendKeyOf(entry)]) return false;
            return nowMs - (Number(entry.at) || 0) < 60000;
        });
        optimisticDeliveries.slice().reverse().forEach(function (entry) {
            out.push({ kind: entry.kind, name: entry.name, count: entry.count, pending: true });
        });
        Array.from(stores.deliveries.values())
            .sort(function (a, b) { return (Number(b.id) || 0) - (Number(a.id) || 0); })
            .forEach(function (item) {
                out.push({
                    id: item.id,
                    kind: item.kind,
                    name: item.name,
                    count: Number(item.remaining || item.total || 0),
                    container: item.container,
                    process: item.processName,
                    error: item.lastError
                });
            });
        return out;
    }

    function deliveryItemHtml(entry) {
        const tip = entry.error || entry.container || entry.process || '';
        // 取消按钮：只有服务端队列里的条目才有 id（刚点发送的乐观占位还没拿到 id，不能取消）
        const cancel = entry.id
            ? '<span class="grid-mark danger" data-delivery-cancel="' + escapeHtml(String(entry.id)) + '" title="' +
              escapeHtml(t('deliveryCancel')) + '">×</span>'
            : '';
        return '<div class="grid-item delivery-item' + (entry.pending ? ' pending' : '') + '"' +
            ' data-delivery="' + escapeHtml(sendKeyOf(entry)) + '"' +
            (entry.id ? ' data-delivery-id="' + escapeHtml(String(entry.id)) + '"' : '') +
            (tip ? ' title="' + escapeHtml(tip) + '"' : '') + '>' +
            cancel +
            kindBadgeHtml(entry.kind) +
            resourceIconHtml(entry) +
            '<span class="grid-count">' + fmtCount(entry.count) + '</span>' +
            '</div>';
    }

    function renderSend() {
        const entries = Array.from(sendList.values());
        const deliveries = deliveryEntries();
        const panel = el('deliveryPanel');
        const hasAny = entries.length > 0 || deliveries.length > 0;
        // 两栏都空时整块面板隐藏（用户要求），页面下方不再留一条空 dock；
        // 只在真的变化时才写 display：反复写同一个值也会让浏览器重新算布局
        if (panel) {
            const display = hasAny ? '' : 'none';
            if (panel.style.display !== display) panel.style.display = display;
        }
        const grid = el('sendGrid');
        const deliveryGrid = el('deliveryGrid');
        if (!grid || !deliveryGrid) return;
        if (!hasAny) {
            grid.innerHTML = '';
            deliveryGrid.innerHTML = '';
            syncDeliveryPanelSpacing();
            return;
        }
        grid.innerHTML = entries.map(function (entry) {
            const key = resourceKey(entry.kind, entry.name);
            // 与资源网格同样的显示方式：类型徽标 + 图标 + 右上角 ×（移除）+ 右下角数量。
            // 必须用 resourceIconHtml：过滤器/占位符不是物品，按 item 去查图标接口会 404，
            // 结果就只能显示名称兜底（以前“待发送”里的过滤器图标不显示就是这个原因）。
            return '<div class="grid-item" data-send="' + escapeHtml(key) + '" data-tip-send="' + escapeHtml(key) + '">' +
                kindBadgeHtml(entry.kind) +
                '<span class="grid-mark danger" data-send-remove="' + escapeHtml(key) + '" title="' +
                escapeHtml(t('pickerRemove')) + '">×</span>' +
                resourceIconHtml(entry) +
                '<span class="grid-count">' + fmtCount(entry.count) + '</span>' +
                '</div>';
        }).join('');
        deliveryGrid.innerHTML = deliveries.map(deliveryItemHtml).join('');
        syncDeliveryPanelSpacing();
    }

    // 点「发送」时的滑动动画：待发送卡片的一份副本从原位置飞到「发送中」里的对应位置（经典 FLIP）
    // 1.6.11 修复「动画丢失」：以前只在 append 后直接 requestAnimationFrame 改 transform ——
    // 如果 append 和改样式落在同一帧里，浏览器从没画过“初始位置”，transition 就不会触发（等于没动画）。
    // 现在 append 之后先强制一次布局（读 offsetWidth）把初始样式落地，再在下一帧改 transform。
    function animateSendToDelivery(pairs) {
        const ghosts = [];
        pairs.forEach(function (pair) {
            if (!pair.fromRect || !pair.node) return;
            if (!pair.fromRect.width && !pair.fromRect.height) return;      // 起点量不到（面板刚显示）：不做动画
            const ghost = pair.node.cloneNode(true);
            ghost.classList.add('send-ghost');
            ghost.style.left = pair.fromRect.left + 'px';
            ghost.style.top = pair.fromRect.top + 'px';
            ghost.style.width = pair.fromRect.width + 'px';
            ghost.style.height = pair.fromRect.height + 'px';
            document.body.appendChild(ghost);
            // 关键：强制同步布局，保证浏览器已经用“起点样式”算过一遍这个元素
            void ghost.offsetWidth;
            // 终点量不到（例如占位卡片还没画出来）时退到「发送中」这一栏的左上角，至少飞向正确区域
            let toRect = pair.toRect;
            if (!toRect || (!toRect.width && !toRect.height)) {
                const grid = el('deliveryGrid');
                toRect = grid ? grid.getBoundingClientRect() : null;
            }
            if (!toRect) {
                ghost.remove();
                return;
            }
            ghosts.push({ node: ghost, from: pair.fromRect, to: toRect });
        });
        if (ghosts.length === 0) return;
        // 下一帧再改位置，保证 transition 真的生效
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
        // output 角色的容器：同名物品/流体容器靠“种类:名称”键区分，所以下拉值用键
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


    
