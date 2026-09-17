// IFM :: web/ifm-workers.js
// IFMWorker（分布式工作节点）面板：列出每台 worker 的能力、当前工作与计数
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

    // 能力标签：搬运 / 查询（1.5.0 起 worker 只做这两件事；老版本 worker 只会上报搬运）
    function workerCapLabels(worker) {
        return [
            worker.move ? t('capMove') : null,
            worker.query ? t('capQuery') : null
        ].filter(Boolean);
    }

    function workerStateTag(worker) {
        // 主控已经判定它掉线（阈值 = 摘除它的超时）：直接显示失联
        if (worker.stale === true) return { text: t('workerStale'), kind: 'missing' };
        // 否则用「多久没听到任何消息」；老后端没有这两个字段时退回「等待状态」
        let age = null;
        if (typeof worker.stateAge === 'number') age = worker.stateAge;
        else if (typeof worker.age === 'number') age = worker.age;
        if (age === null) return { text: t('workerWaiting'), kind: 'waiting' };
        if (age > 30) return { text: t('workerStale'), kind: 'missing' };
        if (worker.busy || asArray(worker.tasks).length > 0) return { text: t('workerWorking'), kind: 'running' };
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
            list.innerHTML = '<span class="muted">' + escapeHtml(t('workerNone')) + '</span>';
            if (hint) hint.textContent = '';
            return;
        }
        list.innerHTML = workers.map(function (worker) {
            const tasks = asArray(worker.tasks);
            const tag = workerStateTag(worker);
            const caps = workerCapLabels(worker).join(' · ');
            const info = [];
            const mismatch = worker.versionMismatch === true;
            if (mismatch) {
                // 版本与主控不一致：版本号标红 + 说清后果（主控不会把搬运/查询交给它）
                info.push({ bad: true, text: t('workerVersionMismatch', {
                    worker: worker.version || '?', server: IFM_CLIENT_VERSION
                }) });
            } else if (worker.version) {
                info.push({ text: t('workerVersion', { version: worker.version }) });
            }
            if (tasks.length > 0) {
                info.push(t('workerCurrent', { task: tasks.join(' | ') }));
            } else if (worker.busy) {
                // 主控认为它忙、它自己却没上报任何任务：多半是回报丢了（主控在等超时回收）。
                // 显示出来，免得只看到「工作中」却不知道在等什么。
                info.push(t('workerWaitingReply', {
                    moves: worker.pending || 0,
                    queries: worker.pendingQueries || 0
                }));
            }
            if (worker.lastQuery && worker.lastQuery.mode) {
                const stacks = worker.lastQuery.stacks || 0;
                const scanned = worker.lastQuery.scanned || 0;
                if (stacks > 0) {
                    // 一条查询只查一个容器：这里显示容器名（老数据没有该字段时退回 mode）
                    info.push(t('workerLastQuery', {
                        container: String(worker.lastQuery.container || worker.lastQuery.mode || '?'),
                        stacks: fmtCount(stacks),
                        ms: worker.lastQuery.elapsed || 0
                    }));
                } else if (scanned === 0) {
                    // 查询回来了、却一个容器都没看到：这台 worker 看不到主控的容器
                    // （多半不和主控在同一有线网络上）→ 容器代扫对它永远无效
                    info.push(t('workerScanBlind'));
                } else {
                    info.push(t('workerLastQueryEmpty', { scanned: fmtCount(scanned) }));
                }
            }
            // 普通信息一行、异常信息（红字）一行：版本不匹配时能一眼看出来
            const lines = { plain: [], bad: [] };
            info.forEach(function (entry) {
                if (typeof entry === 'string') {
                    lines.plain.push(entry);
                } else if (entry && entry.text) {
                    (entry.bad ? lines.bad : lines.plain).push(entry.text);
                }
            });
            return '<div class="flow-row' + (worker.stale === true ? ' idle' : '') +
                (mismatch ? ' worker-mismatch' : '') + '">' +
                '<span class="state-tag ' + escapeHtml(tag.kind) + '">' + escapeHtml(tag.text) + '</span>' +
                '<span class="grow">' +
                '<strong>#' + escapeHtml(String(worker.id)) + ' ' + escapeHtml(worker.name || '') + '</strong> ' +
                '<span class="muted">' + escapeHtml(caps) + '</span>' +
                (lines.bad.length > 0 ? '<div class="worker-warn">' + escapeHtml(lines.bad.join(' · ')) + '</div>' : '') +
                (lines.plain.length > 0 ? '<div class="muted">' + escapeHtml(lines.plain.join(' · ')) + '</div>' : '') +
                '</span>' +
                '<span class="muted">' + escapeHtml(t('workerCounters', {
                    jobs: fmtCount(worker.jobs || 0),
                    moved: fmtCount(worker.moved || 0),
                    queries: fmtCount(worker.queries || 0),
                    details: fmtCount(worker.detailItems || 0),
                    pending: fmtCount(worker.pending || 0)
                })) + '</span>' +
                '</div>';
        }).join('');
        if (hint) {
            const queriers = workers.filter(function (worker) { return worker.query; }).length;
            hint.textContent = t('workerSummary', { n: workers.length, query: queriers });
        }
    }
