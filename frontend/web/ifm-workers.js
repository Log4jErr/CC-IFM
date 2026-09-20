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
        // 本轮第 6 项：任务很短（常常 1 个游戏刻），"这一刻的任务表"多半是空的 ——
        // 但只要这一秒里跑过东西（peak > 0）就是"工作中"，别再显示成空闲。
        if (worker.busy || asArray(worker.tasks).length > 0 || (worker.peak || 0) > 0) {
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
            list.innerHTML = '<span class="muted">' + escapeHtml(t('workerNone')) + '</span>';
            if (hint) hint.textContent = '';
            renderWorkerTotalLoad([]);
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
            // 并发槽位（1.8.0）：64 条的 worker 一次能同时跑很多条任务 ——
            // 只显示「空闲/工作中」会让人以为它闲着，这里把负载写清楚。
            // 本轮第 5/6 项：负载改成"这一秒的峰值并发"并配一条进度条 ——
            // worker 的任务往往 1 个游戏刻就结束，只显示"上报这一刻"的数永远是 0。
            const slots = typeof worker.slots === 'number' ? worker.slots : 0;
            const peak = typeof worker.peak === 'number' ? worker.peak : null;
            const loadValue = Math.max(Number(worker.load) || 0, peak || 0);
            let barHtml = '';
            if (slots > 1) {
                const percent = Math.min(100, Math.round(loadValue / slots * 100));
                const barClass = percent >= 100 ? 'bad' : (percent > 0 ? ' warn' : '');
                barHtml = '<div class="progress worker-load" title="' +
                    escapeHtml(t('workerLoadTitle', { slots: slots })) + '">' +
                    '<div class="bar' + barClass + '" style="width:' + percent + '%"></div></div>';
                info.push(peak === null
                    ? t('workerLoad', { load: loadValue, slots: slots })
                    : t('workerLoadPeak', { load: loadValue, slots: slots }));
            }
            // 卡住被摘掉的任务（1.8.0）：某个容器/外设长时间不响应时，worker 会摘掉这些任务
            // 把槽位还回来。不显示的话，用户只会看到“搬运老是超时”而不知道是哪个方块的问题。
            if ((worker.stuck || 0) > 0) {
                info.push({ bad: true, text: t('workerStuck', { n: worker.stuck }) });
            }
            // 失联（用户第 1 项）：卡片不再消失，但要把"多久没消息了"写清楚 ——
            // 一眼能看出是链路抖了一下（几秒后就自己恢复）还是真的掉线了。
            if (worker.stale === true) {
                const ageText = typeof worker.stateAge === 'number'
                    ? worker.stateAge
                    : (typeof worker.age === 'number' ? worker.age : 0);
                info.push({ bad: true, text: t('workerSilentFor', { n: ageText }) });
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
                const container = String(worker.lastQuery.container || worker.lastQuery.mode || '?');
                const ms = worker.lastQuery.elapsed || 0;
                if (scanned === 0) {
                    // 查询回来了、却一个容器都没看到：这台 worker 看不到主控的容器
                    // （多半不和主控在同一有线网络上）→ 容器代扫对它永远无效
                    info.push(t('workerScanBlind'));
                } else if (stacks > 0) {
                    info.push(t('workerLastQuery', {
                        container: container,
                        stacks: fmtCount(stacks),
                        ms: ms
                    }));
                } else {
                    // 扫到的容器是空的：也要显示外设名与用时（任务 6：以前只显示“扫过 N 个容器”）
                    info.push(t('workerLastQueryEmpty', { container: container, ms: ms }));
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
                barHtml +
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
        renderWorkerTotalLoad(workers);
    }

    /// 用户第 4 项：从节点"总负载"进度条（放在「从节点」面板标题右侧）。
    /// 只统计从节点自己的槽位与负载 —— 主控本机那 32 个槽位不计入（它压根不在 stores.workers 里，
    /// 见 Transfer:workersForUi / Transfer:localStatus）。负载口径与单卡一致：max(load, peak)。
    function renderWorkerTotalLoad(workers) {
        const bar = el('workerLoadBar');
        const text = el('workerLoadText');
        if (!bar || !text) return;
        let load = 0;
        let slots = 0;
        asArray(workers).forEach(function (worker) {
            const workerSlots = typeof worker.slots === 'number' ? worker.slots : 0;
            const peak = typeof worker.peak === 'number' ? worker.peak : 0;
            slots += Math.max(0, workerSlots);
            load += Math.max(Number(worker.load) || 0, peak);
        });
        if (slots <= 0) {
            // 没有从节点（或都不支持并发）：不显示进度条，避免留一条永远为 0 的空条
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
