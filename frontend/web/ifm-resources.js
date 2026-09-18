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

    function resourceOrder(entry) {
        // 正在合成的项目永远排最前面（用户要求）
        if (isCrafting(entry)) return 0;
        if (entry.kind === 'placeholder') return 1;
        if (entry.kind === 'filter') return 2;
        if (entry.kind === 'fluid' && entry.craftable) return 3;
        if (entry.kind === 'item' && entry.craftable) return 4;
        if (entry.kind === 'fluid') return 5;
        return 6;
    }

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

    function matchesSearch(entry, query) {
        if (searchQueryEmpty(query)) return true;
        const name = String(entry.name || '').toLowerCase();
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
            const hit = name.indexOf(term) >= 0 || label.indexOf(term) >= 0 ||
                englishLabel.indexOf(term) >= 0 ||
                tags.some(function (tag) { return String(tag).toLowerCase().indexOf(term) >= 0; });
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
                return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name));
            }
            if (sortMode === 'count') {
                return (b.count || 0) - (a.count || 0);
            }
            const rankA = resourceOrder(a);
            const rankB = resourceOrder(b);
            if (rankA !== rankB) return rankA - rankB;
            return (b.count || 0) - (a.count || 0);
        });
        return list;
    }

    function plainIconImg(kind, name) {
        const realKind = kind === 'fluid' ? 'fluid' : 'item';
        const key = resourceKey(realKind, name);
        queueMeta(realKind, name);
        // 与 iconHtml 一致：接口没明确说“没有这个资源”就先请求图片（过滤器轮换图标也走这条路）
        if (metaState(key) !== 'missing' && !iconFailedKeys.has(key)) {
            return '<img src="' + iconUrl(realKind, name) + '" alt="" title="' + escapeHtml(name || '') +
                '" data-icon-key="' + escapeHtml(key) +
                '" onerror="window.ifmIconFallback(this, \'' + realKind + '\')">';
        }
        return faGlyphHtml(realKind, name);
    }

    function filterIconHtml(entry) {
        const samples = asArray(entry.samples);
        if (samples.length === 0) {
            return '<span class="icon" title="' + escapeHtml(entry.name) + '">' +
                faGlyphHtml('filter', entry.name) + '</span>';
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
        // 正在合成的物品要排最前面：每次重画前按运行中的流程重算一遍
        activeCraftKeys = craftingKeys();
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

    // 发送中：乐观项（最新提交的排最前）+ 服务端队列（按 id 从后往前 = 最新提交的排最前）
    function deliveryEntries() {
        const out = [];
        const real = {};
        Array.from(stores.deliveries.values()).forEach(function (item) {
            real[sendKeyOf(item)] = item;
        });
        // 服务端已经有这种材料了：乐观项退休（否则会一直重复显示）
        // 另外两种情况也要退休（1.6.10 修“全量刷新后发送中一直残留”）：
        //   * 服务端在我这条占位之后**又推过一次发送队列**（说明它已经看过我的请求）：
        //     队列里没有这种材料 = 已经发完或被拒了；
        //   * 兜底：超过 1 分钟还没对上，就当它已经不在队列里（离线/丢包时不会永远残留）。
        const syncedAt = Number(typeof deliveriesSyncedAt === 'number' ? deliveriesSyncedAt : 0);
        const nowMs = Date.now();
        optimisticDeliveries = optimisticDeliveries.filter(function (entry) {
            const at = Number(entry.at) || 0;
            if (real[sendKeyOf(entry)]) return false;
            // 给服务端 1.5 秒的处理时间：推送可能在我们发出请求之前就生成了
            if (syncedAt > at + 1500) return false;
            return nowMs - at < 60000;
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
    function animateSendToDelivery(pairs) {
        const ghosts = [];
        pairs.forEach(function (pair) {
            if (!pair.fromRect || !pair.toRect || !pair.node) return;
            const ghost = pair.node.cloneNode(true);
            ghost.classList.add('send-ghost');
            ghost.style.left = pair.fromRect.left + 'px';
            ghost.style.top = pair.fromRect.top + 'px';
            ghost.style.width = pair.fromRect.width + 'px';
            ghost.style.height = pair.fromRect.height + 'px';
            document.body.appendChild(ghost);
            ghosts.push({ node: ghost, from: pair.fromRect, to: pair.toRect });
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


    
