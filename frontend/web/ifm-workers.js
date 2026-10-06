'use strict';

    function workerStateTag(worker) {
        // The page only receives the summary now (no task texts, no per-second
        // age), so the state is decided from the stable flags the server sends.
        if (worker.stale === true) return { text: t('workerStale'), kind: 'missing' };
        if (worker.waiting === true) return { text: t('workerWaiting'), kind: 'waiting' };
        if (worker.busy || (worker.load || 0) > 0 || (worker.peak || 0) > 0) {
            return { text: t('workerWorking'), kind: 'running' };
        }
        return { text: t('idle'), kind: 'idle' };
    }

    function renderWorkers() {
        const list = el('workerList');
        if (!list) return;
        const workers = Array.from(stores.workers.values()).sort(function (a, b) {
            return String(a.id).localeCompare(String(b.id), undefined, { numeric: true });
        });
        const hint = el('workerHint');
        if (workers.length === 0) {
            // No worker means no instruction can run at all (the master no longer
            // executes anything itself), so this is a warning, not a quiet "none".
            list.innerHTML = '<div class="worker-warn"><i class="fa fa-exclamation-triangle"></i> ' +
                escapeHtml(t('workerWarning')) + '</div>';
            if (hint) hint.textContent = '';
            renderWorkerTotalLoad([]);
            return;
        }
        list.innerHTML = workers.map(function (worker) {
            const tag = workerStateTag(worker);
            const info = [];
            const mismatch = worker.versionMismatch === true;
            if (mismatch) {
                info.push({ bad: true, text: t('workerVersionMismatch', {
                    worker: worker.version || '?', server: IFM_CLIENT_VERSION
                }) });
            } else if (worker.version) {
                info.push({ text: t('workerVersion', { version: worker.version }) });
            }
            const slots = typeof worker.slots === 'number' ? worker.slots : 0;
            const peak = typeof worker.peak === 'number' ? worker.peak : null;
            const avg = typeof worker.avg === 'number' ? worker.avg : null;
            const loadValue = Math.max(0, Number(worker.load) || 0);
            let barHtml = '';
            if (slots > 1) {
                const percent = Math.min(100, Math.round(loadValue / slots * 100));
                const barClass = percent >= 100 ? 'bad' : (percent > 0 ? ' warn' : '');
                const title = t('workerLoadTitle', { slots: slots }) +
                    (peak === null ? '' : ' · peak ' + Math.round(peak)) +
                    (avg === null ? '' : ' · avg ' + avg.toFixed(1));
                barHtml = '<div class="progress worker-load" title="' +
                    escapeHtml(title) + '">' +
                    '<div class="bar' + barClass + '" style="width:' + percent + '%"></div></div>';
                info.push(t('workerLoad', { load: loadValue, slots: slots }));
            }
            if (worker.stale === true) {
                const silentFor = typeof worker.silentFor === 'number' ? worker.silentFor : 0;
                info.push({ bad: true, text: t('workerSilentFor', { n: silentFor }) });
            }
            // Task texts and the last query stay on the master (only the terminal
            // diagnose prints them): the panel shows load and counters only.
            if (worker.busy || (worker.pending || 0) > 0 || (worker.pendingQueries || 0) > 0) {
                info.push(t('workerWaitingReply', {
                    moves: worker.pending || 0,
                    queries: worker.pendingQueries || 0
                }));
            }
            const lines = { plain: [], bad: [] };
            info.forEach(function (entry) {
                if (typeof entry === 'string') {
                    lines.plain.push(entry);
                } else if (entry && entry.text) {
                    (entry.bad ? lines.bad : lines.plain).push(entry.text);
                }
            });
            // The stuck count is not a warning line of its own: it rides along with
            // the counters on the right, so the row keeps one text line less.
            let countersText = t('workerCounters', {
                jobs: fmtCount(worker.jobs || 0),
                moved: fmtCount(worker.moved || 0),
                queries: fmtCount(worker.queries || 0),
                details: fmtCount(worker.detailItems || 0),
                pending: fmtCount(worker.pending || 0)
            });
            if ((worker.stuck || 0) > 0) {
                countersText += ' · ' + t('workerStuck', { n: worker.stuck });
            }
            return '<div class="flow-row' + (worker.stale === true ? ' idle' : '') +
                (mismatch ? ' worker-mismatch' : '') + '">' +
                '<span class="state-tag ' + escapeHtml(tag.kind) + '">' + escapeHtml(tag.text) + '</span>' +
                '<span class="grow">' +
                '<strong>#' + escapeHtml(String(worker.id)) + ' ' + escapeHtml(worker.name || '') + '</strong> ' +
                barHtml +
                (lines.bad.length > 0 ? '<div class="worker-warn">' + escapeHtml(lines.bad.join(' · ')) + '</div>' : '') +
                (lines.plain.length > 0 ? '<div class="muted">' + escapeHtml(lines.plain.join(' · ')) + '</div>' : '') +
                '</span>' +
                '<span class="muted">' + escapeHtml(countersText) + '</span>' +
                '</div>';
        }).join('');
        if (hint) {
            hint.textContent = t('workerSummary', { n: workers.length });
        }
        renderWorkerTotalLoad(workers);
    }

    function renderWorkerTotalLoad(workers) {
        const bar = el('workerLoadBar');
        const text = el('workerLoadText');
        if (!bar || !text) return;
        let load = 0;
        let slots = 0;
        asArray(workers).forEach(function (worker) {
            const workerSlots = typeof worker.slots === 'number' ? worker.slots : 0;
            slots += Math.max(0, workerSlots);
            load += Math.max(0, Number(worker.load) || 0);
        });
        if (slots <= 0) {
            bar.style.display = 'none';
            text.textContent = '';
            text.removeAttribute('title');
            bar.removeAttribute('title');
            return;
        }
        const percent = Math.min(100, Math.round(load / slots * 100));
        const barNode = bar.firstElementChild;
        if (barNode) {
            barNode.className = 'bar' + (percent >= 100 ? 'bad' : (percent > 0 ? 'warn' : ''));
            barNode.style.width = percent + '%';
        }
        bar.style.display = '';
        const title = t('workerTotalLoadTitle', { slots: fmtCount(slots) });
        bar.setAttribute('title', title);
        text.setAttribute('title', title);
        text.textContent = t('workerTotalLoad', {
            load: fmtCount(load), slots: fmtCount(slots), percent: percent
        });
    }
