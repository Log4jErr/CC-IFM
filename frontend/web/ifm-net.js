// IFM :: web/ifm-net.js
// 服务端日志通道 / WebSocket 协议 / 渲染调度
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 服务端日志 =====================
    // 服务端把日志推过来（不写文件、不刷屏 CC:T 终端），这里输出到浏览器控制台
    const serverLogLines = [];        // 保留最近若干条，便于在控制台里回看
    function serverLog(line) {
        serverLogLines.push(line);
        while (serverLogLines.length > 500) serverLogLines.shift();
        if (window.console && console.log) {
            console.log(line);
        }
    }
    window.ifmServerLog = function () { return serverLogLines.slice(); };

    // ===================== WebSocket =====================
    // 所有出站消息都带上前端版本号：服务端据此在日志里提示版本不一致（网页自己也会先断开）
    function withClientVersion(payload) {
        if (payload && typeof payload === 'object' && payload.version === undefined) {
            payload.version = IFM_CLIENT_VERSION;
        }
        return payload;
    }

    function sendRaw(payload) {
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify(escapePayloadForServer(withClientVersion(payload))));
            return true;
        }
        return false;
    }

    // 已发出、还没收到响应的请求数：按钮点下去就能看到“请求中 N”，不必等结果
    let pendingCount = 0;

    function updatePendingInfo() {
        const node = el('pendingInfo');
        if (!node) return;
        node.textContent = pendingCount > 0 ? t('pendingRequests', { n: pendingCount }) : '';
    }

    function sendRequest(action, data) {
        return new Promise(function (resolve, reject) {
            if (!ws || ws.readyState !== WebSocket.OPEN) {
                reject(new Error('disconnected'));
                return;
            }
            const id = ++requestSeq;
            // 注意顺序：请求关联 id 与 action **必须最后写入**，否则 payload 里同名的字段
            // （例如 delete_delivery 的 { id = 发货 id }）会把关联 id 覆盖掉 ——
            // 响应确实回来了，但网页按错误的 id 找不到等待中的请求，只能干等 30 秒超时
            //（用户实测：“request delete_delivery got no response in 30s”就是这么来的）。
            const payload = Object.assign({}, data || {}, { id: id, action: action });
            const finish = function () {
                pendingCount = Math.max(0, pendingCount - 1);
                updatePendingInfo();
            };
            pendingRequests.set(id, function (value) {
                finish();
                resolve(value);
            });
            pendingCount += 1;
            updatePendingInfo();
            ws.send(JSON.stringify(escapePayloadForServer(withClientVersion(payload))));
            setTimeout(function () {
                if (pendingRequests.has(id)) {
                    pendingRequests.delete(id);
                    finish();
                    // 超时：服务端可能其实已经执行了（只是响应没回来）——顺手做一次全量同步
                    serverLog('[IFM] request ' + action + ' got no response in 30s, requesting a full sync');
                    sendRaw({ action: 'full_request' });
                    reject(new Error(t('requestTimeout', { action: action })));
                }
            }, 30000);
        });
    }

    function sendHeartbeat() {
        if (connected) sendRaw({ action: 'heartbeat' });
    }

    function handleIncoming(raw) {
        let data;
        try {
            data = JSON.parse(raw);
        } catch (err) {
            return;
        }
        if (data.message && typeof data.message === 'object') {
            data = data.message;
        } else if (typeof data.message === 'string') {
            try { data = JSON.parse(data.message); } catch (err) { /* keep */ }
        }
        // 传输层里的名称字段是 ASCII 转义形式：只把这些字段还原成真正的字符
        data = decodeFrameFromServer(data);
        if (data.type === 'join' || data.type === 'leave') return;
        // 带 action 的帧只可能来自 IFM 服务端：收到它才把状态切成“已连接”（同时刷新看门狗时间）
        if (data.action) markServerSeen();
        // 服务端日志：没有任何文件写入，全部由服务端推送到这里，直接在浏览器控制台打印
        if (data.action === 'log') {
            asArray(data.lines).forEach(function (line) {
                const text = unescapeAsciiText(String(line));
                serverLog(text);
                // 诊断报告：在 begin/end 标记之间收集，收齐后渲染到诊断窗口
                if (text.indexOf('===== IFM diagnose begin') >= 0) {
                    diagnoseBuffer = [text];
                    if (diagnoseTimer) clearTimeout(diagnoseTimer);
                    diagnoseTimer = setTimeout(finishDiagnose, 20000);
                    return;
                }
                if (diagnoseBuffer) {
                    diagnoseBuffer.push(text);
                    if (text.indexOf('===== IFM diagnose end') >= 0) finishDiagnose();
                }
            });
            return;
        }
        if (data.action === 'full_sync_start') {
            // 全量同步开始：**先不清空**本地数据（清空会让所有列表瞬间变空 → 整页闪一下）。
            // 服务端只要房间里有客户端加入/重连就会广播一次全量，清空式处理会让“闪一下”反复发生。
            beginFullSync();
            return;
        }
        if (data.action === 'full_sync_end') {
            finishFullSync();
            return;
        }
        if (data.action === 'incremental_update' && data.changes) {
            if (fullSyncBuffer) bufferFullSyncChanges(data.changes); else applyChanges(data.changes);
            return;
        }
        if (data.id && pendingRequests.has(data.id)) {
            const resolver = pendingRequests.get(data.id);
            pendingRequests.delete(data.id);
            resolver(data);
        }
    }

    function applyStatus(next) {
        status = next || {};
        statusUpdatedAt = Date.now();
        // 服务端版本号：不一致就弹警告并停止连接（见 applyServerVersion）
        applyServerVersion(status.version);
        markDirty('status');
    }

    function applyChanges(changes) {
        Object.keys(changes).forEach(function (category) {
            if (category === 'status') {
                applyStatus(changes.status);
                return;
            }
            const store = stores[category];
            if (!store) return;
            const list = Array.isArray(changes[category]) ? changes[category] : [];
            list.forEach(function (item) {
                const key = keyOf(category, item);
                if (item._deleted) store.delete(key); else store.set(key, normalizeItemArrays(category, item));
            });
            markDirty(category);
            // 发送队列的增量更新到了：立刻核对「发送中」里的乐观占位
            // （后台已经发完的物品要马上从界面上消失，任务 5 / 1.6.12）
            if (category === 'deliveries') reconcileOptimisticDeliveries();
        });
        scheduleRender();
    }

    // ===================== 全量同步（无闪） =====================
    // 服务端全量 = full_sync_start → 分批 incremental_update → full_sync_end。
    // 这里在 start..end 之间把数据先收进缓冲，end（或超时兜底）时**整体替换**并只重画一次：
    // 页面不会再出现“列表先变空、再填回来”的闪烁，中途发失败也不会把界面清空。
    let fullSyncBuffer = null;      // { changes: { [category]: [...] }, timer }
    // 1.6.12：发送队列的乐观占位不再按“服务端推送时间”猜退休时机，
    // 改成 send_items 响应后“武装”，之后每次收到 deliveries 增量更新就核对（见 ifm-resources.js）。

    function beginFullSync() {
        if (fullSyncBuffer) clearTimeout(fullSyncBuffer.timer);
        fullSyncBuffer = {
            changes: {},
            timer: setTimeout(finishFullSync, 1500)     // 兜底：万一没收到 full_sync_end
        };
    }

    function bufferFullSyncChanges(changes) {
        if (!fullSyncBuffer) beginFullSync();
        Object.keys(changes).forEach(function (category) {
            if (category === 'status') {
                fullSyncBuffer.changes.status = changes.status;   // 标量类别：直接覆盖
                return;
            }
            const list = fullSyncBuffer.changes[category] || (fullSyncBuffer.changes[category] = []);
            asArray(changes[category]).forEach(function (item) {
                list.push(item);
            });
        });
    }

    function finishFullSync() {
        const buffer = fullSyncBuffer;
        if (!buffer) return;
        fullSyncBuffer = null;
        clearTimeout(buffer.timer);
        let touched = false;
        Object.keys(buffer.changes).forEach(function (category) {
            if (category === 'status') {
                applyStatus(buffer.changes.status);
                return;
            }
            const store = stores[category];
            if (!store) return;
            // 只替换这一轮真的收到数据的类别（没出现的类别保持原样，避免误清空）
            store.clear();
            asArray(buffer.changes[category]).forEach(function (item) {
                if (item && item._deleted) return;                // 全量里不该有墓碑
                store.set(keyOf(category, item), normalizeItemArrays(category, item));
            });
            markDirty(category);
            if (category === 'deliveries') reconcileOptimisticDeliveries();
            touched = true;
        });
        if (touched) scheduleRender();
    }

    // ===================== 版本比对 =====================
    // 服务端版本号随 status.version 下发（后端 IFMMaster.lua 的 buildStatus 写入）。
    // 与前端 IFM_CLIENT_VERSION 不一致时：弹警告 + 主动断开 + 不再自动重连，
    // 避免“新前端配旧后端”这种组合产生各种难以定位的怪现象。
    function applyServerVersion(version) {
        if (!version || typeof version !== 'string') return;
        if (serverVersion === version && versionMismatch === (version !== IFM_CLIENT_VERSION)) return;
        serverVersion = version;
        if (version === IFM_CLIENT_VERSION) {
            renderVersionLabel();
            return;
        }
        versionMismatch = true;
        const message = t('versionMismatch', { client: IFM_CLIENT_VERSION, server: version });
        serverLog('[IFM] ' + message);
        toast(message, 'error');
        setText('loginError', message);
        setDisplay('loginOverlay', 'flex');
        setDisplay('app', 'none');
        connected = false;
        serverSeen = false;
        if (heartbeatTimer) {
            clearInterval(heartbeatTimer);
            heartbeatTimer = null;
        }
        setConnectionStatus('offline');
        renderVersionLabel();
        if (ws) {
            const socket = ws;
            ws = null;
            try { socket.close(); } catch (err) { /* ignore */ }
        }
    }

    function normalizeRelay(value) {
        let text = (value || '').trim() || DEFAULT_RELAY;
        if (!/^wss?:\/\//i.test(text)) {
            text = 'wss://' + text;
        }
        if (text.slice(-1) !== '/') {
            text = text + '/';
        }
        return text;
    }

    function connect(roomName) {
        // 版本不一致时拒绝再连（applyServerVersion 已经提示过原因，这里只保证不会偷偷重连）
        if (versionMismatch) {
            setText('loginError', t('versionMismatch', { client: IFM_CLIENT_VERSION, server: serverVersion || '?' }));
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
            setConnectionStatus('offline');
            return;
        }
        if (ws) {
            try { ws.close(); } catch (err) { /* ignore */ }
            ws = null;
        }
        room = (roomName || '').trim();
        if (!room) {
            setText('loginError', t('loginHint'));
            return;
        }
        const relayField = el('relayInput');
        relayBase = normalizeRelay(relayField ? relayField.value : relayBase);
        if (relayField) relayField.value = relayBase;
        setCookie('ifm_room', room, 365);
        setCookie('ifm_relay', relayBase, 365);
        setConnectionStatus('connecting');
        setText('loginError', '');
        setText('roomLabel', '#' + room);
        setText('relayLabel', relayBase);
        let socket;
        try {
            socket = new WebSocket(relayBase + encodeURIComponent(room));
        } catch (err) {
            setText('loginError', String(err.message || err));
            setConnectionStatus('offline');
            return;
        }
        ws = socket;
        // 每个回调都先确认“自己还是当前这条连接”：
        // 看门狗为了刷新连接会主动重建 WebSocket，被换掉的旧连接稍后仍会触发 onclose/onerror，
        // 那时绝不能再改界面 —— 否则登录遮罩与主界面会来回切换（服务端离线时页面一直闪就是这么来的）。
        const isCurrent = function () { return ws === socket; };
        socket.onopen = function () {
            if (!isCurrent()) return;
            connected = true;
            serverSeen = false;
            stallNotified = false;
            // 中继连上 ≠ 服务端在线：先显示“连接中…”。
            // 只有“本页曾经收到过服务端数据”（重连场景）才立刻切回主界面；
            // 否则留在登录框等服务端开口，避免空界面与登录框来回闪。
            setConnectionStatus('connecting');
            if (everSeenServer) {
                setDisplay('loginOverlay', 'none');
                setDisplay('app', 'block');
            }
            lastHeartbeatAt = Date.now();
            if (heartbeatTimer) clearInterval(heartbeatTimer);
            heartbeatTimer = setInterval(sendHeartbeat, 5000);
            sendHeartbeat();
            sendRaw({ action: 'full_request' });
        };
        socket.onmessage = function (event) {
            if (!isCurrent()) return;
            handleIncoming(event.data);
        };
        socket.onerror = function () {
            if (!isCurrent()) return;
            setConnectionStatus('offline');
            setText('loginError', t('wsError', { relay: relayBase }));
        };
        socket.onclose = function (event) {
            if (!isCurrent()) return;
            const wasConnected = connected;
            connected = false;
            if (heartbeatTimer) {
                clearInterval(heartbeatTimer);
                heartbeatTimer = null;
            }
            setConnectionStatus('offline');
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
            if (!wasConnected) {
                setText('loginError', t('wsClosed', {
                    code: (event && event.code) || 0,
                    reason: (event && event.reason) || '-'
                }));
            }
        };
    }

    function disconnect() {
        if (ws) {
            // 先摘掉引用：close() 触发的 onclose 会因为“不是当前连接”而被忽略
            const socket = ws;
            ws = null;
            try { socket.close(); } catch (err) { /* ignore */ }
        }
        connected = false;
        serverSeen = false;
        setConnectionStatus('offline');
        // 断开是用户主动点的：界面切回登录框由这里负责（onclose 已被忽略，不再切界面）
        setDisplay('loginOverlay', 'flex');
        setDisplay('app', 'none');
    }

    function setCookie(name, value, days) {
        const expires = new Date(Date.now() + days * 864e5).toUTCString();
        document.cookie = name + '=' + encodeURIComponent(value) + '; expires=' + expires + '; path=/';
    }

    function getCookie(name) {
        return document.cookie.split('; ').reduce(function (result, entry) {
            const parts = entry.split('=');
            return parts[0] === name ? decodeURIComponent(parts[1]) : result;
        }, '');
    }

    // ===================== 渲染调度 =====================
    function markDirty(name) {
        dirty[name] = true;
    }

    function scheduleRender() {
        if (renderTimer) return;
        renderTimer = setTimeout(function () {
            renderTimer = null;
            renderAll();
        }, 200);
    }

    function renderAll() {
        if (dirty.resources) {
            renderResources();
            renderSend();
        }
        if (dirty.processes || dirty.runtime) {
            // 合成状态会影响资源网格的排序与高亮（正在合成的排最前面）
            renderResources();
            renderProcesses();
            renderSend();
        }
        if (dirty.deliveries) {
            // 底部面板的「发送中」栏（与「待发送」共用一次渲染：面板显隐、高度都靠它同步）
            renderSend();
        }
        // 「外设与定义」板块里还含机器类型 / 机器卡片（层级：机器类型 → 机器 → 输入/输出/信号 → 外设）
        if (dirty.peripherals || dirty.containers || dirty.signals || dirty.missing ||
            dirty.machines || dirty.machineTypes) {
            renderPeripherals();
            renderSendContainerSelect();
        }
        // 「过滤器」是独立面板：图标要用资源里的 samples，所以资源变化时也要重画
        if (dirty.filters || dirty.resources) {
            renderFilterPanel();
        }
        if (dirty.processes || dirty.resources || dirty.machines || dirty.machineTypes) {
            renderGraph();
        }
        if (dirty.status) renderStatus();
        if (dirty.status) renderSettings();
        if (dirty.workers) renderWorkers();
        dirty = {};
        refreshTooltip();
    }

    // 顶部状态：标签缓存 / 存储整理进度（整理进度有独立的进度条，见 renderCompactProgress）
    function renderStatus() {
        const node = el('tagInfo');
        if (node) {
            const scan = status ? status.tagScan : null;
            if (scan && scan.queued > 0) {
                node.textContent = t('tagScanning', { done: scan.scanned, total: scan.queued }) +
                    // 其中有多少是 worker 代查回来的（主控没做阻塞的 getItemDetail）
                    (scan.fromWorkers ? ' · ' + t('tagScanByWorkers', { n: scan.fromWorkers }) : '');
            } else if (status && status.tags) {
                node.textContent = t('tagsCached', { n: status.tags });
            } else {
                node.textContent = '';
            }
        }
        renderCapacity();
        renderCompactProgress();
        renderVersionLabel();
        renderTransferInfo();
    }

    // 资源浏览的容量信息：已存储物品总数 / 可存储物品总数、已占用槽位数 / 总槽位数（进度条）
    function capacityRowHtml(label, used, total) {
        const percent = total > 0 ? Math.max(0, Math.min(100, Math.round(used / total * 100))) : 0;
        const cls = percent >= 90 ? 'bad' : (percent >= 60 ? 'warn' : '');
        return '<div class="capacity-row">' +
            '<span class="capacity-label">' + escapeHtml(label) + '</span>' +
            '<div class="progress"><div class="bar ' + cls + '" style="width:' + percent + '%"></div></div>' +
            '<span class="capacity-label">' + escapeHtml(fmtCount(used) + ' / ' + fmtCount(total) + '（' + percent + '%）') + '</span>' +
            '</div>';
    }

    function renderCapacity() {
        const node = el('capacityBars');
        if (!node) return;
        const capacity = status ? status.capacity : null;
        if (!capacity) {
            node.innerHTML = '';
            return;
        }
        node.innerHTML =
            capacityRowHtml(t('capacityItems'), capacity.items || 0, capacity.itemCapacity || 0) +
            capacityRowHtml(t('capacitySlots'), capacity.slots || 0, capacity.totalSlots || 0);
    }

    // 按钮即时反馈：点下去立刻禁用 + 图标转起来，响应回来后再恢复（避免“点了没反应”）
    function setButtonBusyById(id, busy) {
        const button = el(id);
        if (!button) return;
        const icon = button.querySelector('i');
        if (busy) {
            button.disabled = true;
            if (icon && icon.className.indexOf('fa-spin') < 0) icon.className += ' fa-spin';
        } else {
            button.disabled = false;
            if (icon) icon.className = icon.className.replace(' fa-spin', '');
        }
    }

    function busyButton(id, promise) {
        setButtonBusyById(id, true);
        const restore = function () { setButtonBusyById(id, false); };
        return promise.then(function (value) {
            restore();
            return value;
        }, function (err) {
            restore();
            throw err;
        });
    }

    // 「整理」进行中：按钮禁用并让图标转起来，避免重复点击
    function setCompactButtonBusy(busy) {
        setButtonBusyById('compactBtn', busy);
    }

    // 存储整理进度（服务端 status.compact）：进度条 + 已合并物品数，整理期间一直显示。
    // 计划是分批算的（见 ifm/recipe.lua 的 startCompact）：planning 阶段显示“正在计算搬运计划（扫描容器 3/19）” ——
    // 这样点「整理」之后立刻就有反应，而不是等服务端算完计划（十几秒里界面像没反应、浏览器还会判定掉线）。
    function renderCompactProgress() {
        const node = el('compactProgress');
        if (!node) return;
        let job = status ? status.compact : null;
        if (job) {
            compactOptimistic = null;
        } else if (compactOptimistic && statusUpdatedAt < compactOptimistic.at) {
            // 服务端还没回传新的状态：先用本地占位，界面不会看起来“点了没反应”
            job = compactOptimistic;
        } else {
            compactOptimistic = null;
        }
        if (!job) {
            node.style.display = 'none';
            node.innerHTML = '';
            setCompactButtonBusy(false);
            return;
        }
        if (job.planning || !job.total) {
            // 计划还在算：显示已扫描容器数 / 已探测种类数（没有进度条，因为总步数还不知道）
            const scanned = job.containersTotal
                ? t('compactPlanningContainers', { done: job.containersDone || 0, total: job.containersTotal })
                : '';
            const probed = job.groupsTotal
                ? t('compactPlanningKinds', { done: job.groupsDone || 0, total: job.groupsTotal })
                : '';
            const detail = [scanned, probed].filter(function (text) { return !!text; }).join(' · ');
            node.style.display = '';
            node.innerHTML = '<div class="capacity-row">' +
                '<span class="capacity-label">' + escapeHtml(t('compactPlanning')) + '</span>' +
                '<span class="capacity-label">' + escapeHtml(detail) + '</span>' +
                '</div>';
            setCompactButtonBusy(true);
            return;
        }
        const total = job.total;
        const done = Math.max(0, Math.min(total, job.done || 0));
        const percent = Math.round(done / total * 100);
        const mergedText = job.items
            ? t('compactMergedOf', { moved: fmtCount(job.moved || 0), items: fmtCount(job.items) })
            : t('compactMerged', { n: fmtCount(job.moved || 0) });
        node.style.display = '';
        node.innerHTML = '<div class="capacity-row">' +
            '<span class="capacity-label">' + escapeHtml(t('compactRunning', { done: done, total: total })) + '</span>' +
            '<div class="progress"><div class="bar warn" style="width:' + percent + '%"></div></div>' +
            '<span class="capacity-label">' + escapeHtml(mergedText) + '</span>' +
            '</div>';
        setCompactButtonBusy(true);
    }


    
