'use strict';

    const serverLogLines = [];
    function serverLog(line) {
        serverLogLines.push(line);
        while (serverLogLines.length > 500) serverLogLines.shift();
        if (!window.console || !console.log) return;
        const text = String(line);
        const match = /^\[[^\]]*\]\s*\[(warn|error)\]\s/.exec(text);
        const level = match ? match[1] : 'info';
        const isDebug = /^\[[^\]]*\]\s*\[debug\]\s/.test(text);
        if (level === 'error') {
            (console.error || console.log).call(console, '%c' + text, 'color:#ff6b6b');
        } else if (level === 'warn') {
            (console.warn || console.log).call(console, '%c' + text, 'color:#e0b050');
        } else if (isDebug) {
            (console.debug || console.log).call(console, '%c' + text, 'color:#8b8b8b');
        } else {
            console.log(text);
        }
    }
    window.ifmServerLog = function () { return serverLogLines.slice(); };

    const SESSION_TOKEN = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);

    function withClientVersion(payload) {
        if (payload && typeof payload === 'object') {
            if (payload.version === undefined) {
                payload.version = IFM_CLIENT_VERSION;
            }
            if (payload.session === undefined) {
                payload.session = SESSION_TOKEN;
            }
        }
        return payload;
    }

    // Every request the UI fires (a button click, the container tool poll, the
    // diagnose button) gives up after this long. Nobody wants a button to stay
    // disabled for half a minute because the master went quiet; the log lines
    // tell the player which request was dropped.
    const REQUEST_TIMEOUT_MS = 5000;

    let outbox = [];

    // No batching delay: every frame goes out as soon as it is queued.
    function queueFrame(payload) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return false;
        outbox.push(escapePayloadForServer(withClientVersion(payload)));
        flushOutbox();
        return true;
    }

    function flushOutbox() {
        if (outbox.length === 0) return;
        const batch = outbox;
        outbox = [];
        if (!ws || ws.readyState !== WebSocket.OPEN) return;
        try {
            ws.send(JSON.stringify(batch.length === 1 ? batch[0] : batch));
        } catch (err) {
            serverLog("[IFM] outbox send failed: " + (err && err.message));
        }
    }

    function sendRaw(payload) {
        return queueFrame(payload);
    }

    let pendingCount = 0;

    let myUid = null;

    let batchCount = 0;
    let frameTotal = 0;
    let unknownFrameCount = 0;
    let parseFailCount = 0;
    let messageParseFailCount = 0;

    function updatePendingInfo() {
        const node = el('pendingInfo');
        if (!node) return;
        node.textContent = pendingCount > 0 ? t('pendingRequests', { n: pendingCount }) : '';
    }

    function maskText(id, value, shown) {
        const node = el(id);
        if (!node) return;
        const text = (value === null || value === undefined) ? '' : String(value);
        node.textContent = text ? (shown || '****') : '';
        node.title = text;
        if (text) {
            node.setAttribute('data-tip-text', text);
        } else {
            node.removeAttribute('data-tip-text');
        }
        node.classList.toggle('masked', text !== '');
    }

    function sendRequest(action, data) {
        return new Promise(function (resolve, reject) {
            if (!ws || ws.readyState !== WebSocket.OPEN) {
                reject(new Error('disconnected'));
                return;
            }
            const id = ++requestSeq;
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
            queueFrame(payload);
            setTimeout(function () {
                if (pendingRequests.has(id)) {
                    pendingRequests.delete(id);
                    finish();
                    serverLog('[IFM] request ' + action + ' got no response in '
                        + Math.round(REQUEST_TIMEOUT_MS / 1000) + 's - giving up on it '
                        + '(connection problem?); NOT re-syncing silently');
                    reject(new Error(t('requestTimeout', { action: action })));
                }
            }, REQUEST_TIMEOUT_MS);
        });
    }

    function sendHeartbeat() {
        if (connected) sendRaw({ action: 'heartbeat' });
    }

    let lastBundleSeq = null;
    function unpackServerText(text) {
        if (typeof text !== 'string' || text.lastIndexOf('BDPK', 0) !== 0) return false;
        let body = text.slice(4);
        let seq = null;
        const prefixMatch = /^([0-9]+):/.exec(body);
        if (prefixMatch) {
            seq = Number(prefixMatch[1]);
            body = body.slice(prefixMatch[0].length);
        }
        if (seq !== null) {
            if (lastBundleSeq !== null && seq > lastBundleSeq + 1) {
                serverLog('[IFM] LOST ' + (seq - lastBundleSeq - 1) + ' bundle(s) (#'
                    + (lastBundleSeq + 1) + '..#' + (seq - 1) + '): the transport dropped them'
                    + ' - look up their sizes in the master log (bundle #N: B bytes, K frame(s))');
            } else if (lastBundleSeq !== null && seq <= lastBundleSeq) {
                serverLog('[IFM] bundle sequence restarted at #' + seq + ' (the master restarted?)');
            }
            lastBundleSeq = seq;
        }
        const parts = body === '' ? [] : body.split('==+');
        batchCount += 1;
        frameTotal += parts.length;
        if (batchCount <= 3 || batchCount % 100 === 0) {
            serverLog('[IFM] bundle frames: received ' + batchCount + ' bundle(s), '
                + frameTotal + ' frame(s) total');
        }
        for (let i = 0; i < parts.length; i += 1) {
            let frame;
            try {
                frame = JSON.parse(parts[i].split('=+').join('='));
            } catch (err) {
                parseFailCount += 1;
                if (parseFailCount <= 3 || parseFailCount % 100 === 0) {
                    serverLog('[IFM] DROPPED a bundled frame that is not valid JSON (#'
                        + parseFailCount + '): ' + String(parts[i]).slice(0, 120));
                }
                continue;
            }
            handleFrame(frame);
        }
        return true;
    }

    function handleIncoming(raw) {
        if (unpackServerText(raw)) return;
        let data;
        try {
            data = JSON.parse(raw);
        } catch (err) {
            parseFailCount += 1;
            if (parseFailCount <= 3 || parseFailCount % 100 === 0) {
                serverLog('[IFM] DROPPED a frame that is not valid JSON (#'
                    + parseFailCount + '): ' + String(raw).slice(0, 120));
            }
            return;
        }
        if (Array.isArray(data)) {
            batchCount += 1;
            frameTotal += data.length;
            if (batchCount <= 3 || batchCount % 100 === 0) {
                serverLog('[IFM] batch frames: received ' + batchCount + ' batch(es), '
                    + frameTotal + ' frame(s) total');
            }
            for (let i = 0; i < data.length; i += 1) handleFrame(data[i]);
            return;
        }
        handleFrame(data);
    }

    function handleFrame(data) {
        const frameType = data && data.type;
        const fromUid = data && data.uid != null ? String(data.uid) : null;
        if (frameType === 'join' && data.self) {
            myUid = fromUid;
        } else if (frameType === 'leave' && fromUid && fromUid === myUid) {
            myUid = null;
        }
        if (fromUid && myUid && fromUid === myUid) return;
        if (data.message && typeof data.message === 'object') {
            data = data.message;
        } else if (typeof data.message === 'string') {
            if (unpackServerText(data.message)) return;
            try {
                data = JSON.parse(data.message);
            } catch (err) {
                messageParseFailCount += 1;
                if (messageParseFailCount <= 3 || messageParseFailCount % 100 === 0) {
                    serverLog('[IFM] DROPPED a wrapped frame whose message is not JSON (#'
                        + messageParseFailCount + '): ' + String(data.message).slice(0, 120));
                }
                return;
            }
        }
        if (Array.isArray(data)) {
            batchCount += 1;
            frameTotal += data.length;
            if (batchCount <= 3 || batchCount % 100 === 0) {
                serverLog('[IFM] batch frames: received ' + batchCount + ' batch(es), '
                    + frameTotal + ' frame(s) total');
            }
            for (let i = 0; i < data.length; i += 1) handleFrame(data[i]);
            return;
        }
        data = decodeFrameFromServer(data);
        if (data.type === 'join' || data.type === 'leave') return;
        if (data.type === 'keepalive') return;
        if (data.action) markServerSeen();
        if (data.action === 'log') {
            asArray(data.lines).forEach(function (line) {
                const text = unescapeAsciiText(String(line));
                serverLog(text);
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
        if (data.action === 'state_clear') {
            beginStateClear(data.categories);
            return;
        }
        if (data.action === 'full_sync_start') {
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
            return;
        }
        if (!data.action && !data.type && !data.id) {
            if (unknownFrameCount < 5) {
                unknownFrameCount += 1;
                serverLog('[IFM] unknown frame shape (ignored): ' + JSON.stringify(data).slice(0, 200));
            }
        }
    }

    function applyStatus(next) {
        const prevPending = JSON.stringify(status && status.capacityPending || []);
        const prevKeep = JSON.stringify(status && status.keepStock || {});
        status = next || {};
        statusUpdatedAt = Date.now();
        applyServerVersion(status.version);
        markDirty('status');
        // The peripheral cards are highlighted from status.capacityPending, so a change
        // there has to re-render that panel too (dirty.status alone would not).
        if (JSON.stringify(status.capacityPending || []) !== prevPending) markDirty('peripherals');
        // The resource panel draws the stock-keeping number from status.keepStock, so
        // a change there has to re-render the grid too.
        if (JSON.stringify(status.keepStock || {}) !== prevKeep) markDirty('resources');
    }

    // No tolerance for a missing protocol field: the UI reads the fields as they
    // arrive (a build mismatch must be visible, not silently patched over).
    function checkProtocolFields() {
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
                checkProtocolFields(category, item);
                const key = keyOf(category, item);
                if (item._deleted) store.delete(key); else store.set(key, normalizeItemArrays(category, item));
            });
            markDirty(category);
            if (category === 'deliveries') reconcileOptimisticDeliveries();
        });
        scheduleRender();
    }

    let fullSyncBuffer = null;

    function beginFullSync() {
        if (fullSyncBuffer) clearTimeout(fullSyncBuffer.timer);
        fullSyncBuffer = {
            changes: {},
            timer: setTimeout(finishFullSync, 1500)
        };
    }

    function beginStateClear(categories) {
        if (!fullSyncBuffer) beginFullSync();
        fullSyncBuffer.clearAll = true;
        fullSyncBuffer.clearedCategories = Array.isArray(categories) ? categories.slice() : null;
    }

    function bufferFullSyncChanges(changes) {
        if (!fullSyncBuffer) beginFullSync();
        Object.keys(changes).forEach(function (category) {
            if (category === 'status') {
                fullSyncBuffer.changes.status = changes.status;
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
        // state_clear tells the page which categories the server cleared. A
        // category whose new list is empty produces no incremental_update frame at
        // all, so clearing only the categories that arrived with changes would keep
        // the rows of the previous sync in the panel forever.
        const cleared = {};
        asArray(buffer.clearedCategories).forEach(function (category) { cleared[category] = true; });
        Object.keys(buffer.changes).forEach(function (category) { cleared[category] = true; });
        Object.keys(cleared).forEach(function (category) {
            if (category === 'status') {
                if (buffer.changes.status !== undefined) applyStatus(buffer.changes.status);
                return;
            }
            const store = stores[category];
            if (!store) return;
            store.clear();
            asArray(buffer.changes[category]).forEach(function (item) {
                if (item && item._deleted) return;
                checkProtocolFields(category, item);
                store.set(keyOf(category, item), normalizeItemArrays(category, item));
            });
            markDirty(category);
            if (category === 'deliveries') reconcileOptimisticDeliveries();
            touched = true;
        });
        if (touched) scheduleRender();
    }

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
        renderVersionLabel();
        // Never keep talking to a build this page cannot understand: drop the
        // connection and go back to the login page (clicking Connect again retries
        // after the server has been updated).
        disconnect();
        setText('loginError', message);
        setDisplay('loginOverlay', 'flex');
        setDisplay('app', 'none');
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
        if (versionMismatch) {
            // A previous attempt hit another build. The user may have updated the
            // server since: clear the flag and try again (a new mismatch drops the
            // connection again right away).
            versionMismatch = false;
            serverVersion = '';
            renderVersionLabel();
        }
        if (ws) {
            try { ws.close(); } catch (err) {  }
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
        maskText('roomLabel', '#' + room + ' @ ' + relayBase, '****@****');
        const relayNode = el('relayLabel');
        if (relayNode) {
            relayNode.textContent = '';
            relayNode.title = '';
            relayNode.removeAttribute('data-tip-text');
            relayNode.hidden = true;
        }
        let socket;
        try {
            socket = new WebSocket(relayBase + encodeURIComponent(room));
        } catch (err) {
            setText('loginError', String(err.message || err));
            setConnectionStatus('offline');
            return;
        }
        ws = socket;
        // A failed handshake fires onerror and then onclose(1006). onclose runs
        // last, so without this flag it overwrites the more useful "cannot reach
        // the relay" text (wsError) with the generic "connection closed" one
        // (wsClosed). The connection-failure text has to win.
        let connectFailed = false;
        const isCurrent = function () { return ws === socket; };
        socket.onopen = function () {
            if (!isCurrent()) return;
            connected = true;
            serverSeen = false;
            stallNotified = false;
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
            connectFailed = true;
            setConnectionStatus('offline');
            setText('loginError', t('wsError', { relay: relayBase }));
        };
        socket.onclose = function (event) {
            if (!isCurrent()) return;
            const wasConnected = connected;
            connected = false;
            myUid = null;
            if (heartbeatTimer) {
                clearInterval(heartbeatTimer);
                heartbeatTimer = null;
            }
            setConnectionStatus('offline');
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
            if (!wasConnected) {
                const code = (event && event.code) || 0;
                // Never opened + code 1006 means the browser could not reach the
                // relay at all (DNS / TLS / blocked / wrong scheme), so report the
                // connection failure instead of the generic closed-connection text.
                if (connectFailed || code === 1006) {
                    setText('loginError', t('wsError', { relay: relayBase }));
                } else {
                    setText('loginError', t('wsClosed', {
                        code: code,
                        reason: (event && event.reason) || '-'
                    }));
                }
            }
        };
    }

    function disconnect() {
        if (ws) {
            const socket = ws;
            ws = null;
            try { socket.close(); } catch (err) {  }
        }
        connected = false;
        serverSeen = false;
        setConnectionStatus('offline');
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
            renderResources();
            renderProcesses();
            renderSend();
        }
        if (dirty.deliveries) {
            renderSend();
        }
        if (dirty.peripherals || dirty.containers || dirty.signals || dirty.missing ||
            dirty.machines || dirty.machineTypes) {
            renderPeripherals();
            renderSendContainerSelect();
        }
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

    function renderStatus() {
        const node = el('tagInfo');
        if (node) {
            const scan = status ? status.tagScan : null;
            if (scan && scan.queued > 0) {
                setHtmlIfChanged(node, statusStatHtml('fa-spinner fa-spin',
                    fmtCount(scan.scanned) + '/' + fmtCount(scan.queued),
                    t('tagScanning', { done: scan.scanned, total: scan.queued }) +
                    (scan.fromWorkers ? ' · ' + t('tagScanByWorkers', { n: scan.fromWorkers }) : '')));
                node.title = t('tagScanning', { done: scan.scanned, total: scan.queued });
            } else if (status && status.tags) {
                setHtmlIfChanged(node, statusStatHtml('fa-tags', fmtCount(status.tags), t('statusTags')));
                node.title = t('tagsCached', { n: status.tags });
            } else {
                node.innerHTML = '';
                node.__ifmHtml = '';
                node.title = '';
                node.removeAttribute('data-tip-text');
            }
        }
        renderCapacity();
        renderCompactProgress();
        renderVersionLabel();
        renderTransferInfo();
    renderDispatchInfo();
    }

    function capacityRowHtml(label, used, total) {
        const percent = total > 0 ? Math.max(0, Math.min(100, Math.round(used / total * 100))) : 0;
        const cls = percent >= 90 ? 'bad' : (percent >= 60 ? 'warn' : '');
        // The bar abbreviates a large count; the tooltip spells the exact numbers out.
        const tip = t('capacityTip', {
            label: label, used: fmtExact(used), total: fmtExact(total), percent: percent
        });
        return '<div class="capacity-row" title="' + escapeHtml(tip) +
            '" data-tip-text="' + escapeHtml(tip) + '">' +
            '<span class="capacity-label">' + escapeHtml(label) + '</span>' +
            '<div class="progress"><div class="bar ' + cls + '" style="width:' + percent + '%"></div></div>' +
            '<span class="capacity-label">' + escapeHtml(fmtCount(used) + ' / ' + fmtCount(total) + t('wrapParen', { text: percent + '%' })) + '</span>' +
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
        const unsized = capacity.unsized || 0;
        const unsizedTip = t('capacityUnsized', { n: fmtExact(unsized) });
        node.innerHTML =
            capacityRowHtml(t('capacityItems'), capacity.items || 0, capacity.itemCapacity || 0) +
            capacityRowHtml(t('capacitySlots'), capacity.slots || 0, capacity.totalSlots || 0) +
            (unsized > 0
                ? '<div class="capacity-row" title="' + escapeHtml(unsizedTip) +
                    '" data-tip-text="' + escapeHtml(unsizedTip) + '"><span class="capacity-label">' +
                    escapeHtml(t('capacityUnsized', { n: fmtCount(unsized) })) + '</span></div>'
                : '');
    }

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

    function renderCompactProgress() {
        const node = el('compactProgress');
        if (!node) return;
        const job = status ? status.compact : null;
        if (!job) {
            node.style.display = 'none';
            node.innerHTML = '';
            return;
        }
        if (job.waiting === 'slotCount') {
            // Compaction is held back until every storage container reported its slot
            // count: show why instead of hiding the bar.
            node.style.display = '';
            node.innerHTML = '<div class="capacity-row">' +
                '<span class="capacity-label">' + escapeHtml(t('compactWaitingSlotCount', {
                    n: fmtCount(job.pendingSlotCount || 0)
                })) + '</span>' +
                '</div>';
            return;
        }
        if (job.waiting === 'capacity') {
            // Compaction is held back until every storage container reported its slot
            // capacities: show why instead of hiding the bar.
            node.style.display = '';
            node.innerHTML = '<div class="capacity-row">' +
                '<span class="capacity-label">' + escapeHtml(t('compactWaitingCapacity', {
                    n: fmtCount(job.pendingCapacity || 0)
                })) + '</span>' +
                '</div>';
            return;
        }
        if (job.planning) {
            const scanned = job.containersTotal
                ? t('compactPlanningContainers', { done: job.containersDone || 0, total: job.containersTotal })
                : '';
            // The slot cursor of the running compaction pass: how far the planner has
            // walked through the storage slots (groupsDone/groupsTotal - one slot per
            // pass call).
            const total = Number(job.groupsTotal) || 0;
            const done = Math.max(0, Math.min(total, Number(job.groupsDone) || 0));
            const percent = total > 0 ? Math.round(done / total * 100) : 0;
            const slotLine = total > 0
                ? '<div class="capacity-row">' +
                    '<span class="capacity-label">' + escapeHtml(t('compactPlanningSlots')) + '</span>' +
                    '<div class="progress"><div class="bar" style="width:' + percent + '%"></div></div>' +
                    '<span class="capacity-label">' + escapeHtml(fmtCount(done) + ' / ' + fmtCount(total) +
                        t('wrapParen', { text: percent + '%' })) + '</span>' +
                    '</div>'
                : '';
            node.style.display = '';
            node.innerHTML = '<div class="capacity-row">' +
                '<span class="capacity-label">' + escapeHtml(t('compactPlanning')) + '</span>' +
                '<span class="capacity-label">' + escapeHtml(scanned) + '</span>' +
                '</div>' + slotLine;
            return;
        }
        node.style.display = '';
        node.innerHTML = '<div class="capacity-row">' +
            '<span class="capacity-label">' + escapeHtml(t('compactAuto')) + '</span>' +
            '<span class="capacity-label">' + escapeHtml(t('compactQueue', {
                queued: fmtCount(job.queued || job.total || 0),
                pending: fmtCount(job.pendingMoves || 0),
                done: fmtCount(job.movesDone || 0)
            })) + '</span>' +
            '</div>';
    }
