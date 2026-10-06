'use strict';

    // Which processes show their instances: instances are folded away by default (the
    // process row then carries their count) and the folded state is kept in the browser,
    // so it survives a reload. What is stored is the set of *expanded* processes - a
    // process nobody ever opened stays folded.
    const EXPANDED_STORAGE = 'ifmExpandedProcesses';
    let expandedProcesses = null;

    function expandedProcessSet() {
        if (expandedProcesses) return expandedProcesses;
        expandedProcesses = new Set();
        try {
            const raw = localStorage.getItem(EXPANDED_STORAGE);
            if (raw) JSON.parse(raw).forEach(function (name) { expandedProcesses.add(String(name)); });
        } catch (err) {  }
        return expandedProcesses;
    }

    function processInstancesExpanded(name) {
        return expandedProcessSet().has(String(name));
    }

    function setProcessInstancesExpanded(name, expanded) {
        const set = expandedProcessSet();
        if (expanded) set.add(String(name));
        else set.delete(String(name));
        try {
            localStorage.setItem(EXPANDED_STORAGE, JSON.stringify(Array.from(set)));
        } catch (err) {  }
    }

    // The instance list of one process, for the toggle in bindProcessList: keyed by the
    // process name, which may contain characters a selector cannot carry.
    function instanceListOf(name) {
        const lists = document.querySelectorAll('#processList [data-process-instances]');
        for (let i = 0; i < lists.length; i += 1) {
            if (lists[i].getAttribute('data-process-instances') === String(name)) return lists[i];
        }
        return null;
    }

    function stateLabel(state) {
        if (state === 'running') return t('running');
        if (state === 'waiting') return t('waiting');
        if (state === 'missing') return t('missing');
        return t('idle');
    }

    function resourceLabel(kind, name) {
        if (kind === 'filter') return t('filterKind2') + ' ' + name;
        return displayName(kind, name);
    }

    function progressBarHtml(item) {
        // The bar is scaled to the extraction maximum (max x batch, `target`): the
        // produced part is produced/target, and the two tick marks show where the
        // guaranteed minimum and the expected yield sit on that scale.
        const max = Math.max(0, Number(item.target !== undefined && item.target !== null
            ? item.target : (item.max || 0)) || 0);
        const produced = Math.max(0, Number(item.produced !== undefined && item.produced !== null
            ? item.produced : (item.current || 0)) || 0);
        const expected = Math.max(0, Number(item.expected !== undefined && item.expected !== null
            ? item.expected : 0) || 0);
        const min = Math.max(0, Number(item.min || 0) || 0);
        const pct = function (value) {
            if (!(max > 0)) return 0;
            return Math.max(0, Math.min(100, Math.round(value / max * 100)));
        };
        // Colour still follows "did this batch reach its expected yield".
        const cls = (expected > 0 && produced >= expected) ? '' : (produced > 0 ? 'warn' : 'bad');
        return '<div style="margin-top:6px">' +
            '<div style="display:flex;justify-content:space-between">' +
            '<span>' + escapeHtml(resourceLabel(item.kind, item.id)) + '</span>' +
            '<span>' + fmtAmount(produced) + ' / ' + fmtAmount(expected) + '</span>' +
            '</div>' +
            '<div class="progress"><div class="bar ' + cls + '" style="width:' + pct(produced) + '%"></div>' +
            '<span class="progress-tick" style="left:' + pct(min) + '%"></span>' +
            '<span class="progress-tick expect" style="left:' + pct(expected) + '%"></span></div>' +
            '</div>';
    }

    function processTitleText(process) {
        const outputs = asArray(process.outputs).filter(function (element) {
            return element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter';
        });
        if (outputs.length === 0) {
            return String(process.machineType || process.name || '');
        }
        return outputs.map(function (element) {
            if (element.kind === 'filter') return t('filterKind2') + ' ' + element.id;
            return displayName(element.kind, element.id);
        }).join(' + ');
    }

    function processTitle(process) {
        return escapeHtml(processTitleText(process));
    }

    function processPhaseText(record) {
        const wait = record.waitKind;
        if (wait === 'materials') return t('processWaitMaterials');
        if (wait === 'machine') return t('processWaitMachine');
        if (wait === 'signal') return t('processWaitSignal');
        if (wait === 'time') return t('processWaitTime');
        const current = record.current;
        if (!current) return '';
        if (elementIsAbstract(current)) return t('abstractOp') + ' ' + (current.id || '');
        if (current.kind === 'item' || current.kind === 'fluid' || current.kind === 'filter') {
            const name = current.kind === 'filter'
                ? (t('filterKind2') + ' ' + (current.id || ''))
                : displayName(current.kind, current.id);
            const params = {
                name: name,
                done: fmtAmount(current.done || 0),
                target: fmtAmount(current.expect !== undefined && current.expect !== null
                    ? current.expect : (current.target || 0))
            };
            return current.phase === 'output' ? t('processExtracting', params) : t('processSending', params);
        }
        if (current.kind === 'placeholder') return t('placeholderKind') + ' ' + (current.name || '');
        if (current.kind === 'waitTime') return t('processWaitTime') + ' ' + fmtCount(current.seconds || 0) + 's';
        if (current.kind === 'waitSignal') return t('processWaitSignal');
        if (current.kind === 'emitSignal') return t('emitSignal');
        return '';
    }

    function processPerBatch(process) {
        let per = 0;
        asArray(process.outputs).forEach(function (element) {
            if (element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter') {
                per = Math.max(per, Math.max(0, Number(element.expect !== undefined && element.expect !== null
                    ? element.expect : element.max) || 0));
            }
        });
        return Math.max(1, per);
    }

    function processInstanceRowHtml(process, instance) {
        const state = instance.state || 'running';
        const batch = instance.multiplier || 0;
        const phaseText = processPhaseText(instance);
        const bars = asArray(instance.progress).map(progressBarHtml).join('');
        const id = (instance.id === undefined || instance.id === null) ? 0 : instance.id;
        return '<div class="flow-row instance-row">' +
            '<span class="state-tag ' + escapeHtml(state) + '">' + escapeHtml(stateLabel(state)) + '</span>' +
            '<span class="grow">' +
            '<strong>' + escapeHtml(t('instanceLabel')) + ' #' + escapeHtml(String(id)) + '</strong> ' +
            (instance.machine ? '<span class="muted">@' + escapeHtml(unescapeAsciiText(String(instance.machine))) + '</span> ' : '') +
            (batch > 0 ? '<span class="muted">' + escapeHtml(t('processBatch', { n: fmtCount(batch) })) + '</span>' : '') +
            (phaseText ? '<div class="muted">' + escapeHtml(phaseText) + '</div>' : '') +
            (instance.lastError ? '<div class="muted">' + escapeHtml(describeMessage(instance.lastError)) + '</div>' : '') +
            bars +
            '</span>' +
            '<button class="btn-pixel danger" data-instance-cancel="' + escapeHtml(process.name) + '"' +
            ' data-instance-id="' + escapeHtml(String(id)) + '" title="' +
            escapeHtml(t('instanceAbortHint')) + '"><i class="fa fa-stop"></i></button>' +
            '</div>';
    }

    // The material ledger of one process row: what is asked for, what the factory
    // below still needs and what is being crafted - per product.
    function materialSummaryHtml(record) {
        const rows = asArray(record.materials).filter(function (row) {
            if (!row || !row.id) return false;
            return ((Number(row.queryCount) || 0) + (Number(row.automateCount) || 0) +
                (Number(row.craftingCount) || 0)) > 0;
        });
        if (rows.length === 0) return '';
        return rows.map(function (row) {
            return '<span class="muted" title="' + escapeHtml(t('materialCountsHint')) + '">' +
                escapeHtml(String(row.id)) + ' ' + escapeHtml(t('materialCounts', {
                    query: fmtCount(row.queryCount || 0),
                    automate: fmtCount(row.automateCount || 0),
                    crafting: fmtCount(row.craftingCount || 0)
                })) + '</span>';
        }).join(' ');
    }

    // Searchable texts of one process: its machine (the running instance and the
    // machine type), every produced resource (registry name plus display name) and
    // the process name / product title. Chinese labels ride along as pinyin pairs
    // so a player can type latin syllables, exactly like the resource panel does.
    function processSearchTexts(process, record) {
        const texts = [];
        const pinyin = [];
        const push = function (value) {
            const text = String(value === undefined || value === null ? '' : value).trim().toLowerCase();
            if (text) texts.push(text);
        };
        const addPinyin = function (zh, en) {
            // Pinyin search is a Chinese-UI feature only: pinyinSearchHit refuses in other
            // languages anyway, so do not even build the pairs there.
            if (lang !== 'zh') return;
            const label = String(zh === undefined || zh === null ? '' : zh);
            if (label) pinyin.push({ zh: label, en: String(en === undefined || en === null ? '' : en) });
        };
        push(process && process.name);
        const machine = (record && record.machine) ? unescapeAsciiText(String(record.machine)) : '';
        push(machine);
        const typeName = String((process && process.machineType) || '');
        push(typeName);
        if (typeName) {
            try {
                const label = machineTypeLabel(typeName);
                push(label);
                addPinyin(label, '');
            } catch (err) {  }
        }
        try {
            const title = processTitleText(process);
            push(title);
            addPinyin(title, '');
        } catch (err) {  }
        asArray(process && process.outputs).forEach(function (element) {
            if (!element || elementIsAbstract(element)) return;
            if (element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter') {
                const name = String(element.id || '');
                push(name);
                if (name) {
                    try {
                        const label = displayName(element.kind, name);
                        push(label);
                        addPinyin(label, englishName(element.kind, name));
                    } catch (err) {  }
                }
                return;
            }
            if (element.kind === 'placeholder') {
                const name = String(element.name || '');
                const item = String(element.item || '');
                push(name);
                push(item);
                addPinyin(name, name);
                try { addPinyin(displayName('item', item), englishName('item', item)); } catch (err) {  }
            }
        });
        return { texts: texts, pinyin: pinyin };
    }

    // A process is a hit when every search term matches one of its texts (or its
    // Chinese label by pinyin).
    function processSearchHit(process, record, query) {
        const info = processSearchTexts(process, record);
        for (let i = 0; i < query.terms.length; i += 1) {
            const term = query.terms[i];
            let hit = false;
            for (let j = 0; j < info.texts.length && !hit; j += 1) {
                if (info.texts[j].indexOf(term) >= 0) hit = true;
            }
            const pairs = info.pinyin;
            for (let j = 0; j < pairs.length && !hit; j += 1) {
                try {
                    if (pinyinSearchHit(term, pairs[j].zh, pairs[j].en)) hit = true;
                } catch (err) {
                    // The optional pinyin dictionary is missing: keep the plain
                    // substring behaviour instead of breaking the render.
                    hit = false;
                }
            }
            if (!hit) return false;
        }
        return true;
    }

    function renderProcesses() {
        const query = parseSearchQuery(processSearchText);
        const filtering = !searchQueryEmpty(query);
        const processes = Array.from(stores.processes.values()).filter(function (process) {
            const record = stores.runtime.get(process.name);
            if (!record) return false;
            const state = record.state || 'idle';
            const remaining = Math.max(0, Number(record.remaining) || 0);
            const materials = asArray(record.materials);
            return state !== 'idle' || (record.batch || 0) > 0 || remaining > 0 || materials.length > 0;
        });
        if (processes.length === 0) {
            el('processList').innerHTML = '<span class="muted">' + escapeHtml(t('noProcessRunning')) + '</span>';
            return;
        }
        // Search never hides a process here: a hit moves to the front and everything
        // that does not match stays below, dimmed (the visible set itself is unchanged).
        const hitOf = new Map();
        processes.forEach(function (process) {
            hitOf.set(process.name, !filtering ||
                processSearchHit(process, stores.runtime.get(process.name) || {}, query));
        });
        processes.sort(function (a, b) {
            if (filtering) {
                const left = hitOf.get(a.name) ? 0 : 1;
                const right = hitOf.get(b.name) ? 0 : 1;
                if (left !== right) return left - right;
            }
            return a.name.localeCompare(b.name);
        });
        el('processList').innerHTML = processes.map(function (process) {
            const record = stores.runtime.get(process.name) || {};
            const state = record.state || 'idle';
            const bars = asArray(record.progress).map(progressBarHtml).join('');
            const batch = record.batch || 0;
            const phaseText = processPhaseText(record);
            const remaining = Math.max(0, record.remaining || 0);
            const perBatch = processPerBatch(process);
            const instances = asArray(record.instanceList);
            const expanded = processInstancesExpanded(process.name);
            const toggleHtml = instances.length === 0 ? '' :
                '<button class="btn-pixel instance-toggle" data-process-toggle="' + escapeHtml(process.name) +
                '" aria-expanded="' + (expanded ? 'true' : 'false') + '" title="' +
                escapeHtml(t('instanceLabel')) + '"><i class="fa fa-chevron-' +
                (expanded ? 'down' : 'right') + '"></i> ' + fmtCount(instances.length) + '</button>';
            const rowHtml = '<div class="flow-row">' +
                '<span class="state-tag ' + escapeHtml(state) + '">' + escapeHtml(stateLabel(state)) + '</span>' +
                '<span class="grow">' +
                '<strong>' + processTitle(process) + '</strong> ' +
                (record.machine ? '<span class="muted">@' + escapeHtml(unescapeAsciiText(String(record.machine))) + '</span> ' : '') +
                (batch > 0 ? '<span class="muted">' + escapeHtml(t('processBatch', { n: fmtCount(batch) })) + '</span>' : '') +
                (phaseText ? '<div class="muted">' + escapeHtml(phaseText) + '</div>' : '') +
                (record.lastError ? '<div class="muted">' + escapeHtml(describeMessage(record.lastError)) + '</div>' : '') +
                bars +
                '</span>' +
                '<span>' + escapeHtml(t('processRemaining', {
                    batches: fmtCount(remaining),
                    products: fmtAmount(remaining * perBatch)
                })) + '</span>' +
                materialSummaryHtml(record) +
                toggleHtml +
                '<button class="btn-pixel danger" data-process-cancel="' + escapeHtml(process.name) + '" title="' +
                escapeHtml(t('cancelProcess') + ' · ' + t('processAbortHint')) +
                '"><i class="fa fa-stop"></i></button>' +
                '</div>';
            const instanceRows = instances.map(function (instance) {
                return processInstanceRowHtml(process, instance);
            }).join('');
            const listHtml = instances.length === 0 ? '' :
                '<div class="instance-list"' + (expanded ? '' : ' hidden') +
                ' data-process-instances="' + escapeHtml(process.name) + '">' + instanceRows + '</div>';
            const dim = filtering && !hitOf.get(process.name);
            return '<div class="process-block' + (dim ? ' process-dim' : '') + '">' + rowHtml + listHtml + '</div>';
        }).join('');
    }

    // Every fixed bottom bar (the page search toolbar and, on the resources page, the
    // send / delivery toolbar of web/ifm-resources.js) reserves room at the bottom of
    // the body, otherwise the last row would sit behind it. The search toolbar stacks
    // on top of the delivery toolbar whenever both are on screen.
    function syncBottomBars() {
        const searchBar = el('searchToolbar');
        const delivery = el('deliveryPanel');
        const searchVisible = !!searchBar && searchBar.style.display !== 'none' && searchBar.offsetHeight > 0;
        const deliveryVisible = !!delivery && delivery.style.display !== 'none' && delivery.offsetHeight > 0;
        const searchHeight = searchVisible ? (searchBar.offsetHeight || 0) : 0;
        const deliveryHeight = deliveryVisible ? (delivery.offsetHeight || 0) : 0;
        if (searchBar && searchVisible) {
            const bottom = deliveryHeight + 'px';
            if (searchBar.style.bottom !== bottom) searchBar.style.bottom = bottom;
        }
        const total = searchHeight + deliveryHeight;
        // The graph panel sizes itself from the room the bottom bars take (ifm.css:
        // section.panel[data-panel-page="graph"]).
        const root = document.documentElement;
        if (root && root.style && root.style.setProperty) {
            root.style.setProperty('--ifm-bottom-bars', (total > 0 ? total : 0) + 'px');
        }
        // The graph page sizes its own panel from --ifm-bottom-bars and must not also
        // carry the body reserve (stylesheet default 48px included): pin it to 0.
        const padding = graphPageActive() ? '0px' : (total > 0 ? (total + 18) + 'px' : '');
        if (document.body.style.paddingBottom !== padding) {
            document.body.style.paddingBottom = padding;
        }
    }

    // The graph panel sizes itself from --ifm-bottom-bars (ifm.css), so it must not also
    // carry the body reserve: that would add a stray scrollbar under the graph.
    function graphPageActive() {
        return typeof currentPanel === 'function' && currentPanel() === 'graph';
    }

    function syncDeliveryPanelSpacing() {
        syncBottomBars();
    }

    function roleLabel(role) {
        if (role === 'storage') return t('storage');
        if (role === 'input') return t('inputRole');
        if (role === 'interaction') return t('interaction');
        if (role === 'output') return t('output');
        return role || '';
    }

    function peripheralTitleHtml(peripheralName) {
        const blockId = resolvedBlockIdOf(peripheralName);
        if (blockId) queueMeta('block', blockId);
        const label = blockId ? displayName('block', blockId) : String(peripheralName || '');
        return '<h3>' + blockIconHtml(peripheralName) + ' ' + escapeHtml(label) +
            ' <span class="muted" title="' + escapeHtml(t('peripheralNameHint')) + '">' +
            escapeHtml(String(peripheralName || '')) + '</span></h3>';
    }

    // Texts + pinyin pairs of a peripheral block: the block name as registered, the
    // derived block id / registry name and its (Chinese) display name, plus the names
    // of the container / signal definitions it carries.
    function peripheralSearchTexts(block) {
        const raw = blockIdOf(block.name) || '';
        const blockId = resolvedBlockIdOf(block.name) || raw;
        const texts = [String(block.name || ''), raw, blockId];
        const pinyin = [];
        try {
            const label = displayName('block', blockId);
            const english = englishName('block', blockId);
            texts.push(label, english);
            if (label) pinyin.push({ zh: label, en: english });
        } catch (err) {  }
        asArray(block.containers).forEach(function (def) { texts.push(String(def.name || '')); });
        asArray(block.signals).forEach(function (def) { texts.push(String(def.name || '')); });
        return normalizeSearchInfo(texts, pinyin);
    }

    // One place that answers "does this card match the query": a plain token hits any
    // text (substring) or a Chinese label by pinyin; #tag / @mod work on the texts.
    function normalizeSearchInfo(texts, pinyin) {
        const clean = [];
        asArray(texts).forEach(function (text) {
            const value = String(text === undefined || text === null ? '' : text).trim().toLowerCase();
            if (value) clean.push(value);
        });
        const pairs = [];
        if (lang === 'zh') {
            asArray(pinyin).forEach(function (pair) {
                if (pair && pair.zh) pairs.push({ zh: pair.zh, en: pair.en || '' });
            });
        }
        return { texts: clean, pinyin: pairs };
    }

    function searchInfoMatch(info, query) {
        for (let i = 0; i < query.mods.length; i += 1) {
            if (!info.texts.some(function (text) { return modOfName(text) === query.mods[i]; })) return false;
        }
        for (let i = 0; i < query.tags.length; i += 1) {
            if (!info.texts.some(function (text) { return text.indexOf(query.tags[i]) >= 0; })) return false;
        }
        for (let i = 0; i < query.terms.length; i += 1) {
            const term = query.terms[i];
            let hit = info.texts.some(function (text) { return text.indexOf(term) >= 0; });
            for (let j = 0; j < info.pinyin.length && !hit; j += 1) {
                try {
                    if (pinyinSearchHit(term, info.pinyin[j].zh, info.pinyin[j].en)) hit = true;
                } catch (err) {
                    // The optional pinyin dictionary is missing: keep the plain
                    // substring behaviour instead of breaking the render.
                    hit = false;
                }
            }
            if (!hit) return false;
        }
        return true;
    }

    function peripheralMatchesSearch(block, query) {
        if (searchQueryEmpty(query)) return true;
        return searchInfoMatch(peripheralSearchTexts(block), query);
    }

    // Searchable texts of a machine type: its own name (and Chinese label) plus the
    // name / registry name of the icon it was configured with (an item registry name).
    function machineTypeSearchTexts(item) {
        const texts = [String(item.name || '')];
        const pinyin = [];
        try {
            const label = machineTypeLabel(item.name);
            texts.push(label);
            if (label) pinyin.push({ zh: label, en: '' });
        } catch (err) {  }
        const icon = machineTypeIconName(item.name, item.icon);
        if (icon) {
            texts.push(icon);
            try {
                texts.push(displayName('item', icon), englishName('item', icon));
                pinyin.push({ zh: displayName('item', icon), en: englishName('item', icon) });
            } catch (err) {  }
        }
        return normalizeSearchInfo(texts, pinyin);
    }

    function machineTypeMatchesSearch(item, query) {
        if (searchQueryEmpty(query)) return true;
        return searchInfoMatch(machineTypeSearchTexts(item), query);
    }

    // Searchable texts of a container / signal definition card (storage / input /
    // output): the definition name and the peripheral block it points at.
    function containerDefSearchTexts(def) {
        const name = String((def && def.name) || '');
        const peripheral = String((def && def.peripheral) || '');
        const kind = (def && def.kind === 'fluid') ? 'fluid' : 'item';
        const texts = [name, peripheral];
        const pinyin = [];
        try {
            const label = displayName(kind, name);
            const english = englishName(kind, name);
            texts.push(label, english);
            if (label) pinyin.push({ zh: label, en: english });
        } catch (err) {  }
        return normalizeSearchInfo(texts, pinyin);
    }

    function containerDefMatchesSearch(def, query) {
        if (searchQueryEmpty(query)) return true;
        return searchInfoMatch(containerDefSearchTexts(def), query);
    }

    function peripheralSortLabelText() {
        if (peripheralSortMode === 'block') return t('sortPeripheralBlock');
        if (peripheralSortMode === 'defs') return t('sortPeripheralDefs');
        return t('sortPeripheralPeripheral');
    }

    function sortPeripheralList(list) {
        const byName = function (a, b) { return String(a.name).localeCompare(String(b.name)); };
        if (peripheralSortMode === 'block') {
            return list.sort(function (a, b) {
                const left = displayName('block', resolvedBlockIdOf(a.name)) || a.name;
                const right = displayName('block', resolvedBlockIdOf(b.name)) || b.name;
                const diff = String(left).localeCompare(String(right));
                return diff !== 0 ? diff : byName(a, b);
            });
        }
        if (peripheralSortMode === 'defs') {
            return list.sort(function (a, b) {
                const left = asArray(a.containers).length + asArray(a.signals).length;
                const right = asArray(b.containers).length + asArray(b.signals).length;
                return (right - left) || byName(a, b);
            });
        }
        return list.sort(byName);
    }

    function missingMatchesSearch(item, query) {
        if (searchQueryEmpty(query)) return true;
        const texts = [String(item.name || ''), String(item.peripheral || '')]
            .map(function (text) { return text.toLowerCase(); });
        for (let i = 0; i < query.terms.length; i += 1) {
            if (!texts.some(function (text) { return text.indexOf(query.terms[i]) >= 0; })) return false;
        }
        for (let i = 0; i < query.tags.length; i += 1) {
            if (!texts.some(function (text) { return text.indexOf(query.tags[i]) >= 0; })) return false;
        }
        return true;
    }

    function missingChipHtml(item) {
        if (item.kind === 'machine') {
            const machine = unescapeAsciiText(String(item.machine || ''));
            const name = unescapeAsciiText(String(item.name || ''));
            const hint = t('missingMachineRef', { machine: machine || '?' });
            return '<span class="chip missing" title="' + escapeHtml(hint) + '">' +
                escapeHtml(name) +
                ' <span class="muted">' + escapeHtml(hint) + '</span>' +
                '<button class="btn-pixel danger chip-del" type="button" title="' +
                escapeHtml(t('missingMachineRemove')) + '"' +
                ' data-delete-missing="' + escapeHtml(String(item.name || '')) + '"' +
                ' data-missing-kind="machine"' +
                ' data-missing-machine="' + escapeHtml(String(item.machine || '')) + '">' +
                '<i class="fa fa-trash"></i></button></span>';
        }
        const isSignal = item.kind === 'signal';
        const defName = unescapeAsciiText(String(item.name || ''));
        const peripheralName = unescapeAsciiText(String(item.peripheral || ''));
        return '<span class="chip missing" title="' + escapeHtml(peripheralName) + '">' +
            escapeHtml(defName) + ' → ' + escapeHtml(peripheralName) +
            ' <span class="muted">' + escapeHtml(isSignal ? t('signal') : t('container')) + '</span>' +
            '<button class="btn-pixel danger chip-del" type="button" title="' + escapeHtml(t('missingDelete')) + '"' +
            ' data-delete-missing="' + escapeHtml(item.name) + '"' +
            ' data-missing-kind="' + (isSignal ? 'signals' : 'containers') + '"' +
            ' data-missing-container-kind="' + escapeHtml(item.containerKind === 'fluid' ? 'fluid' : 'item') + '">' +
            '<i class="fa fa-trash"></i></button></span>';
    }

    // Which (peripheral, kind) pairs the machines already use. A machine stores
    // the name of a container definition, and a definition defaults to the
    // peripheral name, so both spellings are resolved back to the peripheral -
    // but per kind: a work pot that offers item *and* fluid storage must stay
    // listed while one of its two sides is still free.
    function machineUsedPeripheralRefs() {
        const defs = new Map();
        Array.from(stores.containers.values()).forEach(function (def) {
            defs.set(containerKeyOf(def), def);
        });
        const used = {};
        const mark = function (kind, rawName) {
            const text = String(rawName === undefined || rawName === null ? '' : rawName);
            if (text === '') return;
            const prefixed = /^(item|fluid):(.*)$/.exec(text);
            const refKind = prefixed ? prefixed[1] : kind;
            const plain = prefixed ? prefixed[2] : text;
            if (plain === '') return;
            used[refKind + ':' + plain] = true;
            const def = defs.get(refKind + ':' + plain);
            if (def) used[refKind + ':' + String(def.peripheral || '')] = true;
        };
        Array.from(stores.machines.values()).forEach(function (machine) {
            [['item', machine.itemInputs], ['fluid', machine.fluidInputs],
             ['item', machine.itemOutputs], ['fluid', machine.fluidOutputs]].forEach(function (pair) {
                asArray(pair[1]).forEach(function (name) { mark(pair[0], name); });
            });
        });
        return used;
    }

    function peripheralUsedByMachine(refs, kind, peripheral) {
        const name = String(peripheral === undefined || peripheral === null ? '' : peripheral);
        return name !== '' && refs[kind + ':' + name] === true;
    }

    function machineUsedSignalNames() {
        const used = {};
        Array.from(stores.machines.values()).forEach(function (machine) {
            asArray(machine.signals).forEach(function (name) { used[String(name)] = true; });
        });
        return used;
    }

    function peripheralUnassignedChips(block) {
        const blockName = String(block.name || '');
        const defs = Array.from(stores.containers.values()).filter(function (def) {
            const peripheral = String(def.peripheral || '');
            const name = String(def.name || '');
            return peripheral === blockName || (peripheral === '' && name === blockName);
        });
        const signalDefs = Array.from(stores.signals.values()).filter(function (def) {
            const peripheral = String(def.peripheral || '');
            const name = String(def.name || '');
            return peripheral === blockName || (peripheral === '' && name === blockName);
        });
        const definedByKind = {};
        defs.forEach(function (def) {
            definedByKind[def.kind === 'fluid' ? 'fluid' : 'item'] = def;
        });
        const usedByMachine = machineUsedPeripheralRefs();
        const chips = [];
        const reasons = [];
        [['item', 'inventory', 'itemContainer', 'fa-archive'],
         ['fluid', 'fluid_storage', 'fluidContainer', 'fa-tint']].forEach(function (info) {
            if (peripheralUsedByMachine(usedByMachine, info[0], blockName)) return;
            if (block.kinds.indexOf(info[1]) < 0 || definedByKind[info[0]]) return;
            reasons.push(info[0] + '-unassigned');
            chips.push('<span class="chip unassigned"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '"' +
                ' data-drag-kind="' + info[0] + '"' +
                ' title="' + escapeHtml(t('unassignedHint')) + '">' +
                '<i class="fa ' + info[3] + '"></i> ' + escapeHtml(t(info[2])) +
                ' <span class="muted">' + escapeHtml(t('unassigned')) + '</span>' +
                '<button class="btn-pixel" data-new-container="' + escapeHtml(block.name) +
                '" data-container-kind="' + info[0] + '" title="' + escapeHtml(t('createDefinition')) +
                '"><i class="fa fa-plus"></i></button></span>');
        });
        const usedSignals = machineUsedSignalNames();
        if (block.kinds.indexOf('redstone_relay') >= 0 && !usedSignals[blockName] &&
            !usedSignals[String(signalDefs.length ? signalDefs[0].name : '')]) {
            const legacy = signalDefs[0] || null;
            reasons.push('signal-unassigned');
            chips.push('<span class="chip' + (legacy ? ' def-chip' : '') + ' def-signal"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '" data-drag-kind="signal"' +
                (legacy ? ' data-edit-signal="' + escapeHtml(legacy.name) + '"' : '') +
                ' title="' + escapeHtml(t('signalChipHint')) + '">' +
                '<i class="fa fa-bolt"></i> ' + escapeHtml(block.name) +
                ' <span class="muted">' + escapeHtml(t('signal')) + '</span></span>');
        }
        defs.forEach(function (def) {
            const role = String(def.role || 'storage');
            if (role === 'storage') return;
            if (role === 'input') return;
            if (role === 'output') return;
            if (role === 'interaction' && usedByMachine[containerKeyOf(def)] === true) return;
            reasons.push('isolated-def:' + String(def.name) + ' role=' + role);
            const kind = def.kind === 'fluid' ? 'fluid' : 'item';
            chips.push('<span class="chip def-chip def-' + kind + '"' +
                ' data-edit-container="' + escapeHtml(containerKeyOf(def)) + '"' +
                ' data-drag-peripheral="' + escapeHtml(String(def.peripheral || '')) + '"' +
                ' data-drag-kind="' + kind + '"' +
                ' data-drag-def="' + escapeHtml(containerKeyOf(def)) + '"' +
                ' title="' + escapeHtml(t('clickToEdit')) + '">' +
                '<i class="fa ' + (kind === 'fluid' ? 'fa-tint' : 'fa-cube') + '"></i> ' +
                escapeHtml(unescapeAsciiText(String(def.name || ''))) +
                ' <span class="muted">' + escapeHtml(roleLabel(role)) + '</span>' +
                '</span>');
        });
        signalDefs.slice(1).forEach(function (def) {
            chips.push('<span class="chip def-chip def-signal" data-edit-signal="' + escapeHtml(def.name) +
                '" title="' + escapeHtml(t('clickToEdit')) + '">' +
                '<i class="fa fa-bolt"></i> ' + escapeHtml(def.name) + '</span>');
        });
        block.chipReasons = reasons;
        return chips;
    }

    let lastUnassignedReport = '';
    function reportUnassignedBlocks(blocks) {
        const signature = blocks.map(function (block) { return String(block.name || ''); }).join(',');
        if (signature === lastUnassignedReport) return;
        lastUnassignedReport = signature;
        if (blocks.length === 0) return;
        serverLog('[IFM] ' + blocks.length + ' peripheral block card(s) shown: ' +
            blocks.map(function (block) {
                return block.name + ' [' + asArray(block.chipReasons).join(' | ') + ']';
            }).join('  '));
    }

    // Peripherals whose slot information (slot count or slot capacity) has not been read
    // yet, straight from the server status. Cached per status object: the chip builders
    // below run once per container card.
    let capacityPendingSrc = null;
    let capacityPendingIssueSrc = null;
    let capacityPendingSet = new Set();
    let containerIssueSrc = null;
    let containerIssueMap = new Map();
    // Peripherals with a reported container problem (capability mismatch, missing
    // snapshot on an always-scanned role, ...), keyed by peripheral name: the
    // reason-aware half of the "needs attention" set below.
    function containerIssueMapOf() {
        const src = asArray(status && status.containerIssues);
        if (containerIssueSrc !== src) {
            containerIssueSrc = src;
            containerIssueMap = new Map();
            src.forEach(function (entry) {
                if (entry && entry.peripheral) containerIssueMap.set(String(entry.peripheral), entry);
            });
        }
        return containerIssueMap;
    }
    function capacityPendingPeripherals() {
        const src = asArray(status && status.capacityPending);
        const issues = containerIssueMapOf();
        if (capacityPendingSrc !== src || capacityPendingIssueSrc !== containerIssueSrc) {
            capacityPendingSrc = src;
            capacityPendingIssueSrc = containerIssueSrc;
            capacityPendingSet = new Set(src.map(String));
            issues.forEach(function (_entry, peripheral) { capacityPendingSet.add(peripheral); });
        }
        return capacityPendingSet;
    }
    // The reason text for one peripheral, or null when only the generic slot-scan tip
    // applies (a pure capacity-pending peripheral carries no reason).
    function containerIssueReasonText(peripheral) {
        const entry = containerIssueMapOf().get(String(peripheral));
        if (entry && entry.reason) {
            try { return describeMessage(entry.reason); } catch (err) { return null; }
        }
        return null;
    }

    function containerRoleCardsHtml(role, config, query) {
        const defs = [];
        Array.from(stores.containers.values()).forEach(function (def) {
            if (def.role === role) defs.push(def);
        });
        defs.sort(function (a, b) {
            const kindA = a.kind === 'fluid' ? 'fluid' : 'item';
            const kindB = b.kind === 'fluid' ? 'fluid' : 'item';
            if (kindA !== kindB) return kindA < kindB ? -1 : 1;
            return (Number(b.priority || 0) - Number(a.priority || 0)) ||
                String(a.name).localeCompare(String(b.name));
        });
        const pendingSet = capacityPendingPeripherals();
        const chips = defs.map(function (def) {
            const peripheral = String(def.peripheral || '');
            const kind = def.kind === 'fluid' ? 'fluid' : 'item';
            const priority = Number(def.priority || 0);
            const defLabel = String(def.name || '');
            const hasLabel = defLabel !== '' && defLabel !== peripheral;
            const badge = (role === 'storage' && priority !== 0)
                ? ' <span class="muted" title="' + escapeHtml(t('containerPriority')) + '">P' +
                  escapeHtml(String(priority)) + '</span>'
                : '';
            const scanPending = pendingSet.has(peripheral);
            const issueText = scanPending
                ? (containerIssueReasonText(peripheral) || t('peripheralCapacityScanning'))
                : null;
            return '<span class="chip pc-chip' + (scanPending ? ' capacity-pending' : '') + '"' +
                ' data-pc-peripheral="' + escapeHtml(peripheral) + '"' +
                ' data-pc-def="' + escapeHtml(def.name) + '"' +
                ' data-pc-kind="' + escapeHtml(kind) + '"' +
                ' data-pc-role="' + escapeHtml(role) + '"' +
                ' data-edit-container="' + escapeHtml(containerKeyOf(def)) + '"' +
                (issueText
                    ? ' data-tip-text="' + escapeHtml(issueText) + '"'
                    : '') +
                ' title="' + escapeHtml(peripheral + (hasLabel ? ' (' + defLabel + ')' : '') + ' · ' +
                    t(config.roleLabelKey) + ' · ' + t('clickToEdit')) + '">' +
                // Same shape as a machine peripheral chip: the container-type badge
                // and the block icon together, then the peripheral name.
                '<span class="chip-badge kind-' + escapeHtml(kind) + '-' + escapeHtml(role) + '" title="' +
                escapeHtml(kind === 'fluid' ? t('fluidKind') : t('itemKind')) + '">' +
                '<i class="fa ' + (kind === 'fluid' ? 'fa-tint' : 'fa-cube') + '"></i></span>' +
                (peripheral ? blockIconHtml(peripheral) : '') +
                ' <span class="chip-text">' + escapeHtml(peripheral || def.name) + '</span>' +
                (hasLabel ? '<span class="muted"> ' + escapeHtml(defLabel) + '</span>' : '') + badge +
                '<button class="btn-pixel danger chip-del" type="button" data-pc-role-remove="' + escapeHtml(role) + '" title="' +
                escapeHtml(t(config.removeKey)) + '"><i class="fa fa-times"></i></button>' +
                '</span>';
        }).join('');
        const dropAttr = ' data-' + role + '-drop="any"';
        const filtering = !searchQueryEmpty(query);
        const hit = filtering && defs.some(function (def) { return containerDefMatchesSearch(def, query); });
        return '<div class="card-block storage-card' +
            (filtering ? (hit ? ' ifm-search-hit' : ' ifm-search-dim') : '') + '"' + dropAttr + '>' +
            '<div class="card-head">' +
            '<h3><i class="fa ' + (config.icon || 'fa-archive') + '"></i> ' + escapeHtml(t(config.cardKey)) +
            ' <span class="muted">' + defs.length + '</span></h3>' +
            '</div>' +
            '<div class="chip-list">' + (chips ||
                ('<span class="muted slot-empty">' + escapeHtml(t(config.hintKey)) + '</span>')) +
            '</div></div>';
    }

    function storageCardsHtml(query) {
        return containerRoleCardsHtml('storage', {
            cardKey: 'storageCard', icon: 'fa-archive',
            hintKey: 'storageDropHint', removeKey: 'storageRemove', roleLabelKey: 'storage',
        }, query);
    }

    function inputCardsHtml(query) {
        return containerRoleCardsHtml('input', {
            cardKey: 'inputCard', icon: 'fa-download',
            hintKey: 'inputDropHint', removeKey: 'inputRemove', roleLabelKey: 'inputRole',
        }, query);
    }

    function outputCardsHtml(query) {
        return containerRoleCardsHtml('output', {
            cardKey: 'outputCard', icon: 'fa-upload',
            hintKey: 'outputDropHint', removeKey: 'outputRemove', roleLabelKey: 'outputRole',
        }, query);
    }

    const selectedPeripheralCards = new Set();

    function peripheralSelected(name) {
        return selectedPeripheralCards.has(String(name || ''));
    }

    function peripheralSelection() {
        return Array.from(selectedPeripheralCards);
    }

    function togglePeripheralSelection(name) {
        const key = String(name || '');
        if (!key) return;
        if (selectedPeripheralCards.has(key)) {
            selectedPeripheralCards.delete(key);
        } else {
            selectedPeripheralCards.add(key);
        }
        renderPeripherals();
    }

    function setPeripheralSelection(names, additive) {
        if (!additive) selectedPeripheralCards.clear();
        asArray(names).forEach(function (name) {
            if (name) selectedPeripheralCards.add(String(name));
        });
        renderPeripherals();
    }

    function clearPeripheralSelection() {
        if (selectedPeripheralCards.size === 0) return;
        selectedPeripheralCards.clear();
        renderPeripherals();
    }

    function machinePeripheralNames() {
        const present = {};
        Array.from(stores.machines.values()).forEach(function (machine) {
            ['in', 'out'].forEach(function (slotId) {
                machineSlotEntries(machine, slotId).forEach(function (entry) {
                    if (entry.peripheral) present[String(entry.peripheral)] = true;
                });
            });
            machineSlotEntries(machine, 'signal').forEach(function (entry) {
                if (entry.peripheral) present[String(entry.peripheral)] = true;
            });
        });
        return present;
    }

    function prunePeripheralSelection(blocks) {
        if (selectedPeripheralCards.size === 0) return;
        const present = machinePeripheralNames();
        asArray(blocks).forEach(function (block) { present[String(block.name)] = true; });
        selectedPeripheralCards.forEach(function (name) {
            if (!present[name]) selectedPeripheralCards.delete(name);
        });
    }

    function renderPeripheralSelectionHint() {
        const node = el('peripheralSelHint');
        if (!node) return;
        const count = selectedPeripheralCards.size;
        node.textContent = count > 0 ? t('peripheralSelected', { n: count }) : '';
        node.title = count > 0 ? t('peripheralSelectedHint') : '';
    }

    // Every card family the peripherals page can mark as a search hit, in the order
    // they are drawn - Enter walks this list (focusPeripheralSearchHit).
    const PERIPHERAL_SEARCH_CONTAINERS =
        ['machineTypeList', 'storageList', 'inputList', 'outputList', 'peripheralList'];

    let peripheralSearchHitNodes = [];
    let peripheralSearchFocusIndex = -1;

    function collectPeripheralSearchHits() {
        const nodes = [];
        PERIPHERAL_SEARCH_CONTAINERS.forEach(function (id) {
            const box = el(id);
            if (!box) return;
            Array.prototype.forEach.call(box.querySelectorAll('.card-block.ifm-search-hit'), function (node) {
                nodes.push(node);
            });
        });
        peripheralSearchHitNodes = nodes;
        peripheralSearchFocusIndex = -1;
    }

    function topBarsHeight() {
        const header = document.querySelector ? document.querySelector('.app-header') : null;
        return (header && header.offsetHeight) || 0;
    }

    function bottomBarsHeight() {
        let total = 0;
        ['searchToolbar', 'deliveryPanel'].forEach(function (id) {
            const node = el(id);
            if (node && node.style.display !== 'none' && node.offsetHeight > 0) total += node.offsetHeight;
        });
        return total;
    }

    // Bring a normal-flow card into the middle of the visible area, keeping clear of
    // the sticky header and the bottom toolbar (this page scrolls with the document).
    function scrollCardIntoView(node) {
        if (!node || !node.getBoundingClientRect) return;
        const top = topBarsHeight();
        const bottom = Math.max(top + 40, (window.innerHeight || 0) - bottomBarsHeight());
        const rect = node.getBoundingClientRect();
        const delta = (rect.top + rect.height / 2) - (top + (bottom - top) / 2);
        if (Math.abs(delta) <= 1 || typeof window.scrollBy !== 'function') return;
        try {
            window.scrollBy({ top: delta, behavior: 'smooth' });
            return;
        } catch (err) {  }
        window.scrollBy(0, delta);
    }

    // Enter in the peripheral search walks through the highlighted cards: every press
    // focuses the next one and scrolls it into view; it wraps around at the end.
    function focusPeripheralSearchHit() {
        if (peripheralSearchHitNodes.length === 0) return false;
        peripheralSearchFocusIndex = (peripheralSearchFocusIndex + 1) % peripheralSearchHitNodes.length;
        const node = peripheralSearchHitNodes[peripheralSearchFocusIndex];
        if (!node) return false;
        peripheralSearchHitNodes.forEach(function (other) {
            if (other !== node) other.classList.remove('ifm-search-focus');
        });
        node.classList.add('ifm-search-focus');
        scrollCardIntoView(node);
        return true;
    }

    function renderPeripherals() {
        const blocks = new Map();
        Array.from(stores.peripherals.values()).forEach(function (item) {
            const block = blocks.get(item.name) || { name: item.name, kinds: [], containers: [], signals: [] };
            if (block.kinds.indexOf(item.kind) < 0) block.kinds.push(item.kind);
            asArray(item.containers).forEach(function (def) {
                const exists = block.containers.some(function (other) {
                    return other.name === def.name && other.kind === def.kind;
                });
                if (!exists) block.containers.push(def);
            });
            asArray(item.signals).forEach(function (def) {
                const exists = block.signals.some(function (other) { return other.name === def.name; });
                if (!exists) block.signals.push(def);
            });
            blocks.set(item.name, block);
        });
        const query = parseSearchQuery(peripheralSearchText);
        const allBlocks = Array.from(blocks.values())
            .map(function (block) {
                block.chips = peripheralUnassignedChips(block);
                return block;
            })
            // Keep a card for a fully assigned peripheral as long as its slot information
            // is still being read: that card is the only place the warning can be shown.
            .filter(function (block) {
                return block.chips.length > 0 ||
                    capacityPendingPeripherals().has(String(block.name));
            });
        reportUnassignedBlocks(allBlocks);
        prunePeripheralSelection(allBlocks);
        const filtering = !searchQueryEmpty(query);
        // Search never hides a card on this page: matching cards keep their place with a
        // highlight and the rest dim (Enter walks the hits, see focusPeripheralSearchHit).
        const list = sortPeripheralList(allBlocks);
        const pendingScan = capacityPendingPeripherals();
        const html = list.map(function (block) {
            const selected = peripheralSelected(block.name);
            const hit = !filtering || peripheralMatchesSearch(block, query);
            // A container peripheral whose slot information (slot count or slot capacity)
            // has not been read yet: outline its card in the warn colour and explain why.
            const scanPending = pendingScan.has(String(block.name));
            const issueText = scanPending
                ? (containerIssueReasonText(block.name) || t('peripheralCapacityScanning'))
                : null;
            const bodyChips = block.chips.length > 0 ? block.chips
                : ['<span class="chip capacity-pending"><i class="fa fa-hourglass-half"></i> ' +
                    escapeHtml(t('peripheralSlotScanPending')) + '</span>'];
            return '<div class="card-block' + (selected ? ' selected' : '') +
                (scanPending ? ' capacity-pending' : '') +
                (filtering ? (hit ? ' ifm-search-hit' : ' ifm-search-dim') : '') + '"' +
                ' data-peripheral-card="' + escapeHtml(block.name) + '"' +
                (issueText
                    ? ' data-tip-text="' + escapeHtml(issueText) + '"'
                    : '') + '>' +
                '<div class="peripheral-card-head"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '"' +
                ' title="' + escapeHtml(t('peripheralDragHint')) + '">' +
                peripheralTitleHtml(block.name) + '</div>' +
                '<div class="chip-list">' + bodyChips.join('') + '</div>' +
                '</div>';
        }).join('');
        el('peripheralList').innerHTML = html ||
            ('<span class="muted">' + escapeHtml(t('peripheralsAllAssigned')) + '</span>');
        renderPeripheralSelectionHint();

        const machineBox = el('machineTypeList');
        if (machineBox) machineBox.innerHTML = machinesHtml(query);
        const storageBox = el('storageList');
        if (storageBox) storageBox.innerHTML = storageCardsHtml(query);
        const inputBox = el('inputList');
        if (inputBox) inputBox.innerHTML = inputCardsHtml(query);
        const outputBox = el('outputList');
        if (outputBox) outputBox.innerHTML = outputCardsHtml(query);
        const missing = Array.from(stores.missing.values()).filter(function (item) {
            return missingMatchesSearch(item, query);
        }).sort(function (a, b) { return String(a.name).localeCompare(String(b.name)); });
        const missingBox = el('missingList');
        if (missingBox) {
            missingBox.innerHTML = missing.length > 0
                ? ('<div class="card-block" style="border-color:var(--bad)">' +
                    '<div class="card-head">' +
                    '<h3><i class="fa fa-exclamation-triangle"></i> ' + escapeHtml(t('missingPeripheral')) +
                    ' <span class="muted">' + missing.length + '</span></h3>' +
                    '<button class="btn-pixel danger" type="button" data-delete-missing-all="1" title="' +
                    escapeHtml(t('missingDeleteAllHint')) + '"><i class="fa fa-trash"></i> ' +
                    escapeHtml(t('missingDeleteAll')) + '</button>' +
                    '</div>' +
                    '<div class="chip-list">' + missing.map(missingChipHtml).join('') + '</div></div>')
                : '';
        }
        const sortLabel = el('peripheralSortLabel');
        if (sortLabel) sortLabel.textContent = peripheralSortLabelText();
        // The cards just changed: rebuild the Enter-focus list from the fresh DOM.
        collectPeripheralSearchHits();
    }

    const MACHINE_SLOTS = [
        { id: 'in', icon: 'fa-sign-in', label: 'machineSlotIn' },
        { id: 'out', icon: 'fa-sign-out', label: 'machineSlotOut' },
        { id: 'signal', icon: 'fa-bolt', label: 'machineSlotSignal' },
    ];

    function missingReferenceSet() {
        const set = new Set();
        Array.from(stores.missing.values()).forEach(function (item) {
            set.add(String(item.kind || '') + ':' + String(item.name || ''));
        });
        return set;
    }

    function machineSlotEntries(machine, slotId, missingRefs) {
        const refs = missingRefs || missingReferenceSet();
        const out = [];
        if (slotId === 'signal') {
            asArray(machine.signals).forEach(function (name) {
                const def = stores.signals.get(name);
                out.push({
                    defName: name,
                    kind: 'signal',
                    peripheral: def ? String(def.peripheral || '') : String(name || ''),
                    missing: refs.has('signal:' + String(name || ''))
                });
            });
            return out;
        }
        const pairs = slotId === 'in'
            ? [['item', machine.itemInputs], ['fluid', machine.fluidInputs]]
            : [['item', machine.itemOutputs], ['fluid', machine.fluidOutputs]];
        pairs.forEach(function (pair) {
            asArray(pair[1]).forEach(function (name) {
                const def = containerByName(name, pair[0]);
                out.push({
                    defName: name,
                    kind: pair[0],
                    peripheral: def ? String(def.peripheral || '') : String(name || ''),
                    missing: refs.has('container:' + String(name || '')) ||
                        refs.has('machine:' + String(name || ''))
                });
            });
        });
        return out;
    }

    function machinePeripheralCardHtml(machine, slotId, entry, readOnly) {
        const kind = entry.kind;
        const badgeTitle = kind === 'signal' ? t('machineSlotSignal')
            : t(slotId === 'in'
                ? (kind === 'fluid' ? 'fluidInputs' : 'itemInputs')
                : (kind === 'fluid' ? 'fluidOutputs' : 'itemOutputs'));
        const badgeClass = kind === 'signal' ? 'chip-badge kind-signal' : 'chip-badge kind-' + kind + '-' + slotId;
        const badgeIcon = kind === 'fluid' ? 'fa-tint' : (kind === 'signal' ? 'fa-bolt' : 'fa-cube');
        const peripheral = String(entry.peripheral || '');
        const missing = peripheral === '' || entry.missing === true;
        const text = missing ? entry.defName : peripheral;
        const defLabel = String(entry.defName || '');
        const hasLabel = !missing && defLabel !== '' && defLabel !== peripheral;
        const title = (missing ? t('missingPeripheral') + ': ' + entry.defName : peripheral) +
            (hasLabel ? ' (' + defLabel + ')' : '') + ' · ' + badgeTitle;
        const selectedChip = peripheral !== '' && peripheralSelected(peripheral);
        const scanPending = peripheral !== '' && capacityPendingPeripherals().has(peripheral);
        return '<span class="chip pc-chip' + (readOnly ? ' chip-readonly' : '') +
            (missing ? ' chip-missing' : '') +
            (scanPending ? ' capacity-pending' : '') +
            (selectedChip ? ' selected' : '') + '"' +
            (scanPending
                ? ' data-tip-text="' + escapeHtml(t('peripheralCapacityScanning')) + '"'
                : '') +
            ' data-pc-peripheral="' + escapeHtml(peripheral) + '"' +
            ' data-pc-machine="' + escapeHtml(machine.name) + '"' +
            ' data-pc-slot="' + escapeHtml(slotId) + '"' +
            ' data-pc-kind="' + escapeHtml(kind) + '"' +
            ' data-pc-def="' + escapeHtml(entry.defName) + '"' +
            (readOnly ? ' data-pc-readonly="1"' : '') +
            ' title="' + escapeHtml(title) + '">' +
            '<span class="' + badgeClass + '" title="' + escapeHtml(badgeTitle) + '">' +
            '<i class="fa ' + badgeIcon + '"></i></span>' +
            (missing ? '' : blockIconHtml(peripheral)) +
            ' <span class="chip-text">' + escapeHtml(text) + '</span>' +
            (hasLabel ? '<span class="muted"> ' + escapeHtml(defLabel) + '</span>' : '') +
            (readOnly ? '' :
                '<button class="btn-pixel danger chip-del" type="button" data-pc-remove="1" title="' +
                escapeHtml(t('machineRemove')) + '"><i class="fa fa-times"></i></button>') +
            '</span>';
    }
    const TURTLE_CRAFTER_TYPE = 'turtle_crafter';
    const TYPE_CONVERSION_TYPE = 'type_conversion';

    const MACHINE_TYPE_LABEL_KEYS = {
        turtle_crafter: 'machineTypeTurtleCrafter',
        type_conversion: 'machineTypeTypeConversion'
    };
    function machineTypeLabel(name) {
        const key = MACHINE_TYPE_LABEL_KEYS[String(name)];
        if (!key) return String(name);
        const text = t(key);
        return (text && text !== key) ? text : String(name);
    }

    // The icon a machine type defines (an item registry name), or '' when it has
    // none - then the machine type card and the flow graph show no icon at all.
    // The turtle crafter is the exception: a turtle running IFMCrafter is a
    // crafting table on wheels, so it shows that icon unless one is set explicitly.
    // Type conversion is a virtual chest-like bridge, so it shows a chest.
    const DEFAULT_MACHINE_TYPE_ICONS = {
        turtle_crafter: 'minecraft:crafting_table',
        type_conversion: 'minecraft:chest'
    };

    function machineTypeIconName(typeName, icon) {
        const own = String(icon === undefined || icon === null ? '' : icon).trim();
        if (own) return own;
        return DEFAULT_MACHINE_TYPE_ICONS[String(typeName || '')] || '';
    }

    function machineIconNameOf(typeName) {
        const def = stores.machineTypes.get(String(typeName || ''));
        return machineTypeIconName(typeName, def ? def.icon : '');
    }

    // The generic "cubes" glyph and a real machine icon are alternatives, not a
    // pair: rendering both put two icons left of the machine type name.
    function machineTypeCardIconHtml(typeName, icon) {
        const name = machineTypeIconName(typeName, icon);
        if (name) return machineIconHtml(name);
        return '<i class="fa fa-cubes"></i> ';
    }

    function machinesHtml(query) {
        const filtering = !searchQueryEmpty(query);
        const machines = Array.from(stores.machines.values());
        machines.sort(function (a, b) { return a.name.localeCompare(b.name); });
        const missingRefs = missingReferenceSet();
        const machineCard = function (machine) {
            const parallel = machine.parallel || 1;
            const running = machine.running || 0;
            const percent = Math.min(100, Math.round(running / Math.max(1, parallel) * 100));
            const readOnly = machine.virtual === true || machineTypeIsReadOnly(machine.type);
            const slotInfos = readOnly ? MACHINE_SLOTS.filter(function (info) {
                return info.id !== 'signal';
            }) : MACHINE_SLOTS;
            const slots = slotInfos.map(function (info) {
                const entries = machineSlotEntries(machine, info.id, missingRefs);
                const cards = entries.map(function (entry) {
                    return machinePeripheralCardHtml(machine, info.id, entry, readOnly);
                }).join('');
                const slotMissing = entries.some(function (entry) {
                    return String(entry.peripheral || '') === '' || entry.missing === true;
                });
                return '<div class="machine-slot' + (slotMissing ? ' slot-missing' : '') + '"' +
                    ' data-machine-slot="' + escapeHtml(info.id) + '"' +
                    ' data-machine="' + escapeHtml(machine.name) + '">' +
                    '<div class="slot-head"><i class="fa ' + info.icon + '"></i> ' +
                    escapeHtml(t(info.label)) + '</div>' +
                    '<div class="slot-body">' + (cards ||
                        ('<span class="muted slot-empty">' + escapeHtml(t('machineSlotEmpty')) + '</span>')) +
                    '</div></div>';
            }).join('');
            return '<div class="machine-card"' + (readOnly ? '' :
                ' data-edit-machine="' + escapeHtml(machine.name) + '"') +
                ' data-machine-card="' + escapeHtml(machine.name) + '">' +
                '<h4><i class="fa fa-cog"></i> ' + escapeHtml(machine.name) +
                (machine.usable === false ? ' <span class="muted">(' + escapeHtml(t('missingPeripheral')) + ')</span>' : '') +
                (readOnly ? ' <span class="muted" title="' + escapeHtml(t('machineReadOnlyHint')) + '">(' +
                    escapeHtml(t('machineReadOnly')) + ')</span>' : '') +
                ' <span class="muted">' + escapeHtml(t('machineUsed')) + ' ' + running + '/' + parallel + '</span></h4>' +
                '<div class="progress"><div class="bar' + (percent >= 100 ? ' bad' : (percent > 0 ? ' warn' : '')) +
                '" style="width:' + percent + '%"></div></div>' +
                '<div class="machine-slots">' + slots + '</div>' +
                '</div>';
        };

        const addMachineButton = function (type) {
            if (type === TURTLE_CRAFTER_TYPE) {
                return '<span class="muted">' + escapeHtml(t('machineAutoTurtle')) + '</span>';
            }
            return '<button class="btn-pixel primary" type="button" data-add-machine="' + escapeHtml(type) +
                '" title="' + escapeHtml(t('addMachineHint')) + '"><i class="fa fa-plus"></i> ' +
                escapeHtml(t('machine')) + '</button>';
        };
        // The type conversion type is virtual (no machine, no peripheral): it is not
        // a card of its own here.
        const types = Array.from(stores.machineTypes.values()).filter(function (item) {
            return String(item.name) !== TYPE_CONVERSION_TYPE;
        });
        types.sort(function (a, b) { return a.name.localeCompare(b.name); });
        const usedTypes = {};
        let html = types.map(function (item) {
            const children = machines.filter(function (machine) { return machine.type === item.name; });
            if (children.length > 0) usedTypes[item.name] = true;
            const typeLabel = machineTypeLabel(item.name);
            const typeEditable = !machineTypeIsReadOnly(item.name);
            const hit = !filtering || machineTypeMatchesSearch(item, query);
            return '<div class="card-block' +
                (filtering ? (hit ? ' ifm-search-hit' : ' ifm-search-dim') : '') + '"' + (typeEditable
                ? ' data-edit-machine-type="' + escapeHtml(item.name) + '"'
                : ' data-machine-type-card="' + escapeHtml(item.name) + '"') +
                '>' +
                '<div class="card-head">' +
                '<h3>' + machineTypeCardIconHtml(item.name, item.icon) + escapeHtml(typeLabel) +
                (typeLabel === item.name ? '' :
                    ' <span class="muted">(' + escapeHtml(item.name) + ')</span>') +
                ' <span class="muted">' + children.length + ' ' + escapeHtml(t('machine')) + '</span></h3>' +
                addMachineButton(item.name) +
                '</div>' +
                (children.length > 0
                    ? '<div class="machine-list">' + children.map(machineCard).join('') + '</div>'
                    : '<div class="meta">' + escapeHtml(t('noData')) + '</div>') +
                '</div>';
        }).join('');
        const orphans = machines.filter(function (machine) { return !usedTypes[machine.type]; });
        if (orphans.length > 0) {
            html += '<div class="card-block' + (filtering ? ' ifm-search-dim' : '') +
                '" style="border-color:var(--warn)">' +
                '<div class="card-head">' +
                '<h3><i class="fa fa-cubes"></i> ' + escapeHtml(t('machineTypeField')) + ' ?</h3>' +
                addMachineButton('') +
                '</div>' +
                '<div class="machine-list">' + orphans.map(machineCard).join('') + '</div></div>';
        }
        return html;
    }

    function filterPanelIconHtml(filterName) {
        const entry = stores.resources.get(resourceKey('filter', filterName));
        return filterIconHtml({ name: filterName, samples: entry ? asArray(entry.samples) : [] });
    }

    function renderFilterPanel() {
        const filters = Array.from(stores.filters.values());
        filters.sort(function (a, b) { return a.name.localeCompare(b.name); });
        const filtersHtml = filters.map(function (item) {
            return '<span class="chip" data-edit-filter="' + escapeHtml(item.name) + '">' +
                filterPanelIconHtml(item.name) +
                ' <span class="chip-text">' + escapeHtml(displayName('filter', item.name)) + '</span>' +
                ' <span class="muted">' + asArray(item.rules).length + '</span></span>';
        }).join('');
        el('filterList').innerHTML = filtersHtml || ('<span class="muted">' + escapeHtml(t('noData')) + '</span>');
    }

    function materialNodeLabel(kind, id) {
        if (kind === 'filter') return t('filterKind2') + ' ' + id;
        return displayName(kind, id);
    }

    const GRAPH_ICON_HOLDER =
        "<span class='ifm-graph-icon' style='display:inline-block;width:26px;height:26px'></span>";

    function graphIconContentHtml(kind, id) {
        if (kind === 'filter') {
            // Same idea as the resource panel: cycle through the matching
            // resources (the shared iconIndex keeps graph and panel in step).
            // The rotating holder is emitted even before the samples are known
            // (with the generic glyph inside): rotateFilterIcons() later pulls the
            // freshest samples from the resource store, which a plain glyph could
            // never start doing.
            const entry = stores.resources.get(resourceKey('filter', id));
            const samples = entry ? asArray(entry.samples) : [];
            if (samples.length === 0) {
                return "<span data-filter-icon='" + escapeHtml(id) + "' data-samples='[]'>" +
                    "<i class='fa " + iconGlyphClass(kind) + "' style='font-size:20px'></i></span>";
            }
            const sample = samples[(iconIndex.get(id) || 0) % samples.length];
            queueMeta(sample.kind, sample.name);
            return "<span data-filter-icon='" + escapeHtml(id) + "' data-samples='" +
                escapeHtml(JSON.stringify(samples)) + "'>" +
                plainIconImg(sample.kind, sample.name) + '</span>';
        }
        if (kind !== 'item' && kind !== 'fluid') {
            return "<i class='fa " + iconGlyphClass(kind) + "' style='font-size:20px'></i>";
        }
        queueMeta(kind, id);
        return plainIconImg(kind, id);
    }

    function applyGraphIcons(container) {
        Array.prototype.forEach.call(container.querySelectorAll('g.node'), function (node) {
            const id = String(node.id || '');
            const processMatch = /(^|-)P(\d+)(-|$)/.exec(id);
            if (processMatch) {
                // The process node shows its machine type icon instead of the dot;
                // without an icon (or while the icon is not known yet) the dot stays.
                const icon = nodeMachineIcon.get('P' + processMatch[2]);
                if (!icon) return;
                const iconHolder = node.querySelector('.ifm-graph-machine-icon');
                if (iconHolder) iconHolder.innerHTML = machineIconHtml(icon);
                return;
            }
            const match = /(^|-)M(\d+)(-|$)/.exec(id);
            if (!match) return;
            const material = nodeMaterial.get('M' + match[2]);
            if (!material) return;
            const holder = node.querySelector('.ifm-graph-icon') || node.querySelector('.nodeLabel') ||
                node.querySelector('.label');
            if (!holder) return;
            if (holder.classList && holder.classList.contains('ifm-graph-icon')) {
                holder.innerHTML = graphIconContentHtml(material.kind, material.id);
                return;
            }
            holder.innerHTML = "<span class='ifm-graph-icon' style='display:inline-block;width:26px;height:26px'>" +
                graphIconContentHtml(material.kind, material.id) + "</span>";
        });
    }

    // --- flow graph search --------------------------------------------------
    // A node is a hit when *every* token matches one of its searchable texts:
    //   plain token -> registry name / display name / machine type name
    //   @token      -> the namespace (mod) of a registry name
    function graphNodeSearchTexts(nodeId) {
        const id = String(nodeId || '');
        const texts = [];
        const mods = [];
        // Pinyin is matched against the *displayed* (Chinese) label, so it is kept
        // apart from the lowercased substring texts above.
        const pinyin = [];
        const addPinyin = function (zh, en) {
            const label = String(zh === undefined || zh === null ? '' : zh);
            if (label) pinyin.push({ zh: label, en: String(en === undefined || en === null ? '' : en) });
        };
        const material = nodeMaterial.get(id);
        if (material) {
            const name = String(material.id || '');
            if (name) {
                texts.push(name.toLowerCase());
                mods.push(modOfName(name));
            }
            const placeholder = String(material.placeholder || '');
            const label = placeholder
                ? t('placeholderKind') + ' ' + placeholder
                : materialNodeLabel(material.kind, name);
            try {
                texts.push(String(label).toLowerCase());
                if (placeholder) {
                    // Both names are searchable: the placeholder's own and the item
                    // it stands for (the node itself is drawn with the item's icon).
                    texts.push(placeholder.toLowerCase());
                    addPinyin(placeholder, placeholder);
                    addPinyin(displayName('item', name), englishName('item', name));
                } else {
                    addPinyin(displayName(material.kind, name), englishName(material.kind, name));
                }
            } catch (err) {  }
            return { texts: texts, mods: mods, pinyin: pinyin };
        }
        const processName = nodeProcess.get(id);
        if (!processName) return { texts: texts, mods: mods, pinyin: pinyin };
        const process = stores.processes.get(processName) || {};
        texts.push(String(processName).toLowerCase());
        const typeName = String(process.machineType || '');
        if (typeName) {
            texts.push(typeName.toLowerCase());
            texts.push(String(machineTypeLabel(typeName)).toLowerCase());
            mods.push(modOfName(typeName));
            try { addPinyin(machineTypeLabel(typeName), ''); } catch (err) {  }
        }
        try {
            texts.push(String(processTitleText(process)).toLowerCase());
            addPinyin(processTitleText(process), '');
        } catch (err) {  }
        return { texts: texts, mods: mods, pinyin: pinyin };
    }

    function graphNodeMatches(nodeId, query) {
        const info = graphNodeSearchTexts(nodeId);
        const allHit = function (list, terms) {
            for (let i = 0; i < terms.length; i += 1) {
                let found = false;
                for (let j = 0; j < list.length && !found; j += 1) {
                    if (list[j].indexOf(terms[i]) >= 0) found = true;
                }
                if (!found) return false;
            }
            return true;
        };
        const termHit = function (term) {
            for (let i = 0; i < info.texts.length; i += 1) {
                if (info.texts[i].indexOf(term) >= 0) return true;
            }
            // Pinyin (Chinese mode only): the node shows a Chinese name while the
            // player types its latin initials/syllables.
            const pairs = info.pinyin || [];
            for (let i = 0; i < pairs.length; i += 1) {
                try {
                    if (pinyinSearchHit(term, pairs[i].zh, pairs[i].en)) return true;
                } catch (err) {
                    // The optional pinyin dictionary is missing: keep the plain
                    // substring behaviour instead of breaking the graph render.
                    return false;
                }
            }
            return false;
        };
        for (let i = 0; i < query.terms.length; i += 1) {
            if (!termHit(query.terms[i])) return false;
        }
        return allHit(info.mods, query.mods);
    }

    // The nodes the last applyGraphSearch marked as hits, in document order: Enter in
    // the search box walks through them (focusGraphSearchHit).
    let graphSearchHitNodes = [];
    let graphSearchFocusIndex = -1;

    // Returns the number of hits, or -1 while the search box is empty (then every
    // node is shown undimmed).
    function applyGraphSearch(container) {
        const root = container || el('graph');
        if (!root || !root.querySelectorAll) return -1;
        const query = parseSearchQuery(graphSearchText);
        const empty = searchQueryEmpty(query);
        graphSearchHitNodes = [];
        graphSearchFocusIndex = -1;
        Array.prototype.forEach.call(root.querySelectorAll('g.node'), function (node) {
            const match = /(^|-)([PM]\d+)(-|$)/.exec(String(node.id || ''));
            const nodeId = match ? match[2] : '';
            const hit = !empty && nodeId !== '' && graphNodeMatches(nodeId, query);
            if (node.classList) {
                node.classList.remove('ifm-graph-focus');
                node.classList.toggle('ifm-graph-hit', hit);
                node.classList.toggle('ifm-graph-dim', !empty && !hit);
            }
            if (hit) graphSearchHitNodes.push(node);
        });
        return empty ? -1 : graphSearchHitNodes.length;
    }

    function scrollGraphNodeIntoView(node) {
        const container = el('graph');
        if (!container || !node || !node.getBoundingClientRect) return;
        const box = container.getBoundingClientRect();
        const rect = node.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) return;
        const targetLeft = container.scrollLeft + (rect.left - box.left) - (box.width - rect.width) / 2;
        const targetTop = container.scrollTop + (rect.top - box.top) - (box.height - rect.height) / 2;
        const left = Math.max(0, targetLeft);
        const top = Math.max(0, targetTop);
        if (typeof container.scrollTo === 'function') {
            try {
                container.scrollTo({ left: left, top: top, behavior: 'smooth' });
                return;
            } catch (err) {  }
        }
        container.scrollLeft = left;
        container.scrollTop = top;
    }

    // Enter in the graph search walks through the hits: every press focuses the next
    // match and scrolls #graph so the node is centred; it wraps around at the end.
    function focusGraphSearchHit() {
        if (graphSearchHitNodes.length === 0) return false;
        graphSearchFocusIndex = (graphSearchFocusIndex + 1) % graphSearchHitNodes.length;
        const node = graphSearchHitNodes[graphSearchFocusIndex];
        if (!node) return false;
        graphSearchHitNodes.forEach(function (other) {
            if (other !== node) other.classList.remove('ifm-graph-focus');
        });
        node.classList.add('ifm-graph-focus');
        scrollGraphNodeIntoView(node);
        return true;
    }

    // --- flow graph SVG export ----------------------------------------------
    const GRAPH_FONT_CSS_URL =
        'https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.5.2/css/all.min.css';
    let graphFontCssPromise = null;

    function mimeOfUrl(url) {
        const match = /\.([a-z0-9]+)(?:[?#]|$)/i.exec(String(url));
        const ext = match ? match[1].toLowerCase() : '';
        if (ext === 'woff2') return 'font/woff2';
        if (ext === 'woff') return 'font/woff';
        if (ext === 'ttf') return 'font/ttf';
        if (ext === 'otf') return 'font/otf';
        if (ext === 'eot') return 'application/vnd.ms-fontobject';
        if (ext === 'svg') return 'image/svg+xml';
        if (ext === 'png') return 'image/png';
        if (ext === 'gif') return 'image/gif';
        if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg';
        if (ext === 'webp') return 'image/webp';
        return 'application/octet-stream';
    }

    function bytesToBase64(buffer) {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        const chunk = 0x8000;
        for (let index = 0; index < bytes.length; index += chunk) {
            binary += String.fromCharCode.apply(null, bytes.subarray(index, index + chunk));
        }
        return btoa(binary);
    }

    // Downloads a referenced asset and returns it as a data: URI. A downloaded
    // SVG is opened far away from this page, so every icon/font it references has
    // to travel inside the file instead of pointing at a url.
    function fetchAsDataUrl(url) {
        return fetch(url).then(function (response) {
            if (!response.ok) throw new Error('HTTP ' + response.status);
            return response.arrayBuffer();
        }).then(function (buffer) {
            return 'data:' + mimeOfUrl(url) + ';base64,' + bytesToBase64(buffer);
        });
    }

    // Font Awesome is a font: its CSS only carries url(...) references to the
    // woff2 files, so they are fetched and embedded too (falling back to the
    // absolute url if a fetch fails). The mermaid labels are HTML
    // (<foreignObject>) and use those glyphs: without the embedded sheet a
    // downloaded file shows empty boxes.
    function embedCssAssets(css, cssUrl) {
        const urls = [];
        const tokens = {};
        const withTokens = String(css).replace(/url\((['"]?)([^'")]+)\1\)/g, function (all, quote, url) {
            if (/^(data:|#)/i.test(url)) return all;
            let absolute = url;
            try { absolute = new URL(url, cssUrl).href; } catch (err) {  }
            let token = tokens[absolute];
            if (!token) {
                token = '__IFM_ASSET_' + urls.length + '__';
                tokens[absolute] = token;
                urls.push(absolute);
            }
            return 'url(' + quote + token + quote + ')';
        });
        if (urls.length === 0) return Promise.resolve(withTokens);
        return Promise.all(urls.map(function (url) {
            return fetchAsDataUrl(url).catch(function (err) {
                serverLog('[IFM] graph export: cannot inline ' + url + ' (' +
                    ((err && err.message) || err) + ')');
                return url;
            });
        })).then(function (results) {
            const map = {};
            urls.forEach(function (url, index) { map['__IFM_ASSET_' + index + '__'] = results[index]; });
            return withTokens.replace(/__IFM_ASSET_\d+__/g, function (token) {
                return map[token] || token;
            });
        });
    }

    function inlineGraphFontCss(svgElement) {
        if (!window.fetch) return Promise.resolve();
        if (!graphFontCssPromise) {
            graphFontCssPromise = fetch(GRAPH_FONT_CSS_URL)
                .then(function (response) {
                    if (!response.ok) throw new Error('HTTP ' + response.status);
                    return response.text();
                })
                .then(function (css) {
                    return embedCssAssets(css, GRAPH_FONT_CSS_URL);
                })
                .catch(function (err) {
                    graphFontCssPromise = null;
                    serverLog('[IFM] graph export: cannot inline the Font Awesome stylesheet (' +
                        ((err && err.message) || err) + '): the exported SVG has no icons');
                    return '';
                });
        }
        return graphFontCssPromise.then(function (css) {
            if (!css || !svgElement) return;
            const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
            style.textContent = css;
            svgElement.insertBefore(style, svgElement.firstChild);
        });
    }

    // The <img> icons (icon exports / blocksitems API) are embedded as data:
    // URIs; a failed fetch falls back to the absolute url so the export still
    // happens, just with a couple of remote references.
    function inlineGraphImages(svgElement) {
        if (!svgElement || !window.fetch) return Promise.resolve();
        const jobs = [];
        Array.prototype.forEach.call(svgElement.querySelectorAll('img'), function (img) {
            const src = img.getAttribute('src');
            if (!src || /^data:/i.test(src)) return;
            let absolute = src;
            try { absolute = new URL(String(src), document.baseURI).href; } catch (err) {  }
            jobs.push(fetchAsDataUrl(absolute).then(function (dataUrl) {
                img.setAttribute('src', dataUrl);
            }).catch(function (err) {
                img.setAttribute('src', absolute);
                serverLog('[IFM] graph export: cannot inline ' + absolute + ' (' +
                    ((err && err.message) || err) + ')');
            }));
        });
        return Promise.all(jobs);
    }

    // The exported file is opened away from this page, so it does not carry
    // ifm.css: the icon boxes (26px node icons, 20/24px machine icons, the pixel
    // rendering) have to be frozen as inline styles, otherwise an <img> falls back
    // to its intrinsic pixel size and the node label clips it (only the top-left
    // part stays visible).
    const GRAPH_BOX_SELECTOR =
        'img, .ifm-graph-icon, .ifm-machine-icon, .ifm-graph-machine-icon, .ifm-graph-dot';

    function freezeGraphBoxes(liveRoot, cloneRoot) {
        if (!liveRoot || !cloneRoot || !window.getComputedStyle) return;
        const liveNodes = liveRoot.querySelectorAll(GRAPH_BOX_SELECTOR);
        const cloneNodes = cloneRoot.querySelectorAll(GRAPH_BOX_SELECTOR);
        const count = Math.min(liveNodes.length, cloneNodes.length);
        for (let index = 0; index < count; index += 1) {
            const live = liveNodes[index];
            const clone = cloneNodes[index];
            if (!live || !clone) continue;
            const computed = window.getComputedStyle(live);
            if (!computed) continue;
            const parts = [];
            ['width', 'height', 'objectFit', 'display', 'imageRendering'].forEach(function (name) {
                const value = computed[name];
                if (!value) return;
                parts.push(name.replace(/[A-Z]/g, function (ch) {
                    return '-' + ch.toLowerCase();
                }) + ':' + value);
            });
            if (parts.length === 0) continue;
            const existing = clone.getAttribute('style');
            clone.setAttribute('style',
                (existing ? existing.replace(/;\s*$/, '') + ';' : '') + parts.join(';'));
        }
    }

    // A safety net beside the frozen inline styles: the character fallback glyphs
    // are sized by ifm.css too, and an unconstrained image must never overflow.
    const GRAPH_EXPORT_FALLBACK_CSS = [
        'img { max-width: 100%; max-height: 100%; object-fit: contain; }',
        '.icon-text { line-height: 1; }',
        '.icon-text[data-fallback-len="1"] { font-size: 20px; }',
        '.icon-text[data-fallback-len="2"] { font-size: 16px; }',
        '.icon-text[data-fallback-len="3"] { font-size: 12px; }',
        '.icon-text[data-fallback-len="4"] { font-size: 10px; }',
        '.ifm-graph-icon, .ifm-graph-machine-icon { display: inline-flex; align-items: center;' +
            ' justify-content: center; }',
        // Exported node backgrounds are transparent: on the page the panel colour is
        // painted behind the graph, but a downloaded SVG is opened somewhere else, so
        // a baked-in dark fill would show up as an unwanted box.
        '.node .label-container, .node rect, .node circle, .node ellipse, .node polygon' +
            ' { fill: transparent !important; }',
    ].join('\n');

    function injectExportStyle(svgElement, css) {
        if (!svgElement || !css) return;
        const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
        style.textContent = css;
        svgElement.insertBefore(style, svgElement.firstChild);
    }

    function graphSvgExportText() {
        const container = el('graph');
        const live = container ? container.querySelector('svg') : null;
        if (!live) return Promise.resolve('');
        const clone = live.cloneNode(true);
        clone.setAttribute('xmlns', 'http://www.w3.org/2000/svg');
        clone.setAttribute('xmlns:xlink', 'http://www.w3.org/1999/xlink');
        freezeGraphBoxes(live, clone);
        injectExportStyle(clone, GRAPH_EXPORT_FALLBACK_CSS);
        return inlineGraphImages(clone).then(function () {
            return inlineGraphFontCss(clone);
        }).then(function () {
            return new XMLSerializer().serializeToString(clone);
        });
    }

    // Exported file name: "IFMGraph-<room hash>-<timestamp>.svg". The room name is
    // hashed (djb2, 8 hex digits) so the file stays recognisable without leaking the
    // room name itself into a shared download.
    function graphExportFileName() {
        const roomName = String((typeof room === 'string' && room) || '').trim() || 'room';
        let hash = 5381;
        for (let i = 0; i < roomName.length; i += 1) {
            hash = ((hash * 33) ^ roomName.charCodeAt(i)) >>> 0;
        }
        const now = new Date();
        const pad = function (value) { return (value < 10 ? '0' : '') + value; };
        const stamp = String(now.getFullYear()) + pad(now.getMonth() + 1) + pad(now.getDate()) + '-' +
            pad(now.getHours()) + pad(now.getMinutes()) + pad(now.getSeconds());
        return 'IFMGraph-' + hash.toString(16) + '-' + stamp + '.svg';
    }

    function downloadGraphSvg() {
        // The export has to fetch and embed every icon/font, which takes a moment:
        // answer the click right away (spinner on the button + a toast) instead of
        // leaving the button looking dead until the file is ready.
        const button = el('graphSvgBtn');
        const setBusy = function (busy) {
            if (button) setButtonBusyById('graphSvgBtn', busy);
        };
        setBusy(true);
        toast(t('graphDownloading'), 'info');
        return graphSvgExportText().then(function (svgText) {
            if (!svgText) {
                toast(t('graphDownloadEmpty'), 'error');
                setBusy(false);
                return;
            }
            const blob = new Blob(['<?xml version="1.0" encoding="UTF-8"?>\n' + svgText],
                { type: 'image/svg+xml;charset=utf-8' });
            const url = URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = url;
            link.download = graphExportFileName();
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
            toast(t('graphDownloaded'), 'success');
            setBusy(false);
        }, function (err) {
            serverLog('[IFM] graph export failed: ' + ((err && err.message) || err));
            toast(t('graphDownloadEmpty'), 'error');
            setBusy(false);
        });
    }
    window.ifmDownloadGraphSvg = downloadGraphSvg;

    // The dot has no text, so its size must be inline (or globally styled): mermaid
    // measures the label in a temporary container where #graph-scoped CSS does not
    // apply, and a 0-size placeholder would make the measured node differ from the
    // rendered one.
    const GRAPH_DOT = "<span class='ifm-graph-dot' style='display:inline-block;width:9px;" +
        "height:9px;border-radius:50%;background:var(--accent);vertical-align:middle'></span>";

    // The synthetic node of an auto-discovered containment (an output material that
    // is a subset of an input filter): a clickable "+" that opens the process editor
    // prefilled with a type conversion process.
    const GRAPH_BRIDGE = "<span class='ifm-graph-bridge' style='display:inline-block;width:20px;" +
        "height:20px;line-height:18px;box-sizing:border-box;border:1px dashed #c9a4ff;" +
        "border-radius:4px;color:#c9a4ff;vertical-align:middle'>+</span>";

    // Same idea as the material icons, but for the process nodes of a machine type
    // that carries an icon: the holder is filled after mermaid rendered the label
    // (an inline onerror handler inside a mermaid label is not reliable).
    const GRAPH_MACHINE_ICON_HOLDER = "<span class='ifm-graph-machine-icon' " +
        "style='display:inline-block;width:24px;height:24px;vertical-align:middle'></span>";
    const nodeMachineIcon = new Map();

    const nodeMaterial = new Map();
    // Synthetic bridge node id -> { input, filter } for the prefilled editor.
    const nodeConversion = new Map();

    // ---- filter containment (mirrors backend/modules/filter.lua) --------------
    // The dependency graph has to know when one process's output (item/fluid/filter)
    // is a subset of another process's input filter. It is derived from the filter
    // rules here, best effort: item tags come from the resources the server shipped,
    // so a tag rule whose members are unknown simply never matches. The backend stays
    // authoritative for the actual planning; this only draws the edges.
    const FILTER_INCLUDE_TYPES = {
        item_include: true, fluid_include: true, itemTag_include: true,
        fluidTag_include: true, filter_include: true
    };
    let filterCache = { key: null, dnf: {}, subset: {}, active: {} };

    function filtersSignature() {
        const parts = [];
        stores.filters.forEach(function (def) {
            const rules = asArray(def.rules).map(function (rule) {
                return [rule.type, rule.id, rule.nbt || '', rule.ignoreNbt ? 1 : 0].join('~');
            }).join(',');
            parts.push(String(def.name) + '=' + rules);
        });
        parts.sort();
        return parts.join('|');
    }

    // Editing any filter changes the signature, which drops every memoised DNF and
    // subset answer at once - the same "filter changed, cache cleared" rule as the
    // backend revision key.
    function ensureFilterCache() {
        const key = filtersSignature();
        if (key !== filterCache.key) {
            filterCache = { key: key, dnf: {}, subset: {}, active: {} };
        }
    }

    function resourceTagsOf(kind, name) {
        if (kind !== 'item') return [];
        const entry = stores.resources.get(resourceKey('item', name));
        return entry ? asArray(entry.tags) : [];
    }

    function resourceHasTag(resource, tag) {
        const own = asArray(resource.tags);
        const tags = own.length ? own : resourceTagsOf(resource.kind, resource.name);
        return tags.indexOf(tag) >= 0;
    }

    function filterSampleHit(filterName, resource) {
        const entry = stores.resources.get(resourceKey('filter', filterName));
        if (!entry) return false;
        return asArray(entry.samples).some(function (sample) {
            return sample.kind === resource.kind && sample.name === resource.name;
        });
    }

    function filterLiteralOfRule(rule) {
        let kind, literalType;
        if (rule.type === 'item_include' || rule.type === 'item_exclude') {
            kind = 'item'; literalType = 'item';
        } else if (rule.type === 'fluid_include' || rule.type === 'fluid_exclude') {
            kind = 'fluid'; literalType = 'item';
        } else if (rule.type === 'itemTag_include' || rule.type === 'itemTag_exclude') {
            kind = 'item'; literalType = 'tag';
        } else if (rule.type === 'fluidTag_include' || rule.type === 'fluidTag_exclude') {
            kind = 'fluid'; literalType = 'tag';
        } else if (rule.type === 'filter_include' || rule.type === 'filter_exclude') {
            kind = 'filter'; literalType = 'filter';
        } else {
            return null;
        }
        return { kind: kind, type: literalType, id: rule.id, nbt: rule.nbt, ignoreNbt: !!rule.ignoreNbt };
    }

    function filterRuleMatches(rule, resource, seen, depth) {
        const type = rule.type;
        if (type === 'item_include' || type === 'item_exclude') {
            if (resource.kind !== 'item' || resource.name !== rule.id) return false;
            if (rule.ignoreNbt) return true;
            return String(rule.nbt || '') === String(resource.nbt || '');
        }
        if (type === 'fluid_include' || type === 'fluid_exclude') {
            if (resource.kind !== 'fluid' || resource.name !== rule.id) return false;
            if (rule.ignoreNbt) return true;
            return String(rule.nbt || '') === String(resource.nbt || '');
        }
        if (type === 'itemTag_include' || type === 'itemTag_exclude') {
            return resource.kind === 'item' && resourceHasTag(resource, rule.id);
        }
        if (type === 'fluidTag_include' || type === 'fluidTag_exclude') {
            return resource.kind === 'fluid' && resourceHasTag(resource, rule.id);
        }
        if (type === 'filter_include' || type === 'filter_exclude') {
            return filterMatches(rule.id, resource, seen, depth);
        }
        return false;
    }

    function filterMatches(filterName, resource, seen, depth) {
        const def = stores.filters.get(String(filterName));
        if (!def) return false;
        seen = seen || {};
        depth = depth || 0;
        if (depth > 16 || seen[filterName]) return false;
        seen[filterName] = true;
        let hasInclude = false, matched = false, excluded = false;
        asArray(def.rules).forEach(function (rule) {
            const include = FILTER_INCLUDE_TYPES[rule.type] === true;
            if (include) hasInclude = true;
            if (filterRuleMatches(rule, resource, seen, depth + 1)) {
                if (include) matched = true;
                else excluded = true;
            }
        });
        seen[filterName] = false;
        if (!hasInclude) matched = true;
        if (!(matched && !excluded) && filterSampleHit(filterName, resource)) {
            // The server listed this stored resource as a match; trust it over a rule
            // whose tag membership is simply not known on the client.
            return true;
        }
        return matched && !excluded;
    }

    function filterLiteralImplies(l2, l1) {
        if (!l2 || !l1) return false;
        if (l2.type === 'filter' || l1.type === 'filter') {
            if (l2.type === 'filter' && l1.type === 'filter') {
                return l2.id === l1.id || filterIsSubset(l2.id, l1.id);
            }
            return false;
        }
        if (l2.kind !== l1.kind) return false;
        if (l1.type === 'item') {
            if (l2.type !== 'item' || l2.id !== l1.id) return false;
            if (l1.ignoreNbt) return true;
            if (l2.ignoreNbt) return false;
            return String(l2.nbt || '') === String(l1.nbt || '');
        }
        if (l1.type === 'tag') {
            if (l2.type === 'item') {
                return resourceHasTag({ kind: l2.kind, name: l2.id }, l1.id);
            }
            if (l2.type === 'tag') return l2.id === l1.id;
        }
        return false;
    }

    function filterLiteralDisjoint(l2, l1) {
        if (!l2 || !l1) return false;
        if (l2.type === 'filter' || l1.type === 'filter') return false;
        if (l2.kind !== l1.kind) return true;
        if (l2.type === 'item' && l1.type === 'item') {
            if (l2.id !== l1.id) return true;
            if (l2.ignoreNbt || l1.ignoreNbt) return false;
            return String(l2.nbt || '') !== String(l1.nbt || '');
        }
        let item = null, tag = null;
        if (l2.type === 'item' && l1.type === 'tag') { item = l2; tag = l1; }
        else if (l2.type === 'tag' && l1.type === 'item') { item = l1; tag = l2; }
        if (item) return !resourceHasTag({ kind: item.kind, name: item.id }, tag.id);
        return false;
    }

    function filterTermSubset(term, other) {
        const otherPos = other.pos || [];
        for (let i = 0; i < otherPos.length; i += 1) {
            let ok = false;
            const pos = term.pos || [];
            for (let j = 0; j < pos.length; j += 1) {
                if (filterLiteralImplies(pos[j], otherPos[i])) { ok = true; break; }
            }
            if (!ok) return false;
        }
        const otherNeg = other.neg || [];
        for (let i = 0; i < otherNeg.length; i += 1) {
            let covered = false;
            const neg = term.neg || [];
            for (let j = 0; j < neg.length; j += 1) {
                if (filterLiteralImplies(otherNeg[i], neg[j])) { covered = true; break; }
            }
            if (!covered) {
                const pos = term.pos || [];
                if (pos.length === 0) return false;
                for (let j = 0; j < pos.length; j += 1) {
                    if (!filterLiteralDisjoint(otherNeg[i], pos[j])) return false;
                }
            }
        }
        return true;
    }

    function filterAbsorbTerms(terms) {
        if (terms.length <= 1) return terms;
        const drop = {};
        for (let i = 0; i < terms.length; i += 1) {
            for (let j = 0; j < terms.length; j += 1) {
                if (i === j || drop[j]) continue;
                if (filterTermSubset(terms[i], terms[j])) {
                    if (!filterTermSubset(terms[j], terms[i]) || j < i) { drop[i] = true; break; }
                }
            }
        }
        const kept = [];
        for (let i = 0; i < terms.length; i += 1) {
            if (!drop[i]) kept.push(terms[i]);
        }
        return kept.length ? kept : [terms[0]];
    }

    function filterDnfTerms(name, seen, depth) {
        const def = stores.filters.get(String(name));
        if (!def) return null;
        seen = seen || {};
        depth = depth || 0;
        if (depth > 16 || seen[name]) return [];
        seen[name] = true;
        const includes = [], excludes = [];
        asArray(def.rules).forEach(function (rule) {
            if (FILTER_INCLUDE_TYPES[rule.type] === true) {
                includes.push(rule);
            } else {
                const literal = filterLiteralOfRule(rule);
                if (literal) excludes.push(literal);
            }
        });
        const terms = [];
        if (includes.length === 0) {
            terms.push({ pos: [], neg: excludes.slice() });
        } else {
            includes.forEach(function (rule) {
                if (rule.type === 'filter_include') {
                    const nested = filterDnfTerms(rule.id, seen, depth + 1) || [];
                    nested.forEach(function (nestedTerm) {
                        terms.push({
                            pos: (nestedTerm.pos || []).slice(),
                            neg: (nestedTerm.neg || []).concat(excludes)
                        });
                    });
                } else {
                    const literal = filterLiteralOfRule(rule);
                    if (literal) terms.push({ pos: [literal], neg: excludes.slice() });
                }
            });
        }
        seen[name] = false;
        return filterAbsorbTerms(terms);
    }

    function filterDnf(name) {
        ensureFilterCache();
        if (filterCache.dnf[name]) return filterCache.dnf[name];
        const terms = filterDnfTerms(name);
        if (terms) filterCache.dnf[name] = terms;
        return terms;
    }

    function filterIsSubset(subName, superName) {
        if (subName === superName) return true;
        ensureFilterCache();
        const pair = String(subName) + '\u0001' + String(superName);
        if (Object.prototype.hasOwnProperty.call(filterCache.subset, pair)) {
            return filterCache.subset[pair];
        }
        if (filterCache.active[pair]) return false;
        filterCache.active[pair] = true;
        let result = false;
        const subTerms = filterDnf(subName);
        const superTerms = filterDnf(superName);
        if (subTerms && superTerms) {
            result = subTerms.every(function (subTerm) {
                return superTerms.some(function (superTerm) {
                    return filterTermSubset(subTerm, superTerm);
                });
            });
        }
        filterCache.active[pair] = false;
        filterCache.subset[pair] = result;
        return result;
    }

    // "That output material can feed an input filter." Items/fluids go through the
    // matcher; a filter output has to be a subset of the input filter.
    function materialSatisfiesFilter(element, filterName) {
        if (!element) return false;
        if (element.kind === 'item' || element.kind === 'fluid') {
            return filterMatches(filterName, {
                kind: element.kind, name: element.id, nbt: element.nbt,
                ignoreNbt: element.ignoreNbt, tags: element.tags
            });
        }
        if (element.kind === 'filter') {
            return element.id === filterName || filterIsSubset(element.id, filterName);
        }
        if (element.kind === 'placeholder' && element.item) {
            return filterMatches(filterName, { kind: 'item', name: element.item });
        }
        return false;
    }

    // Mermaid keeps the order in which nodes are declared, so declaring the
    // processes in dependency order (a producer before the processes that consume
    // its output) is what keeps the drawn graph from crossing itself: an
    // alphabetical order puts unrelated chains next to each other and forces long
    // back arrows across the whole panel.
    function processGraphOrder(processes) {
        const byName = new Map();
        const edges = new Map();
        const indegree = new Map();
        const producers = new Map();
        const materialKeyOf = function (element) {
            if (elementIsAbstract(element)) return null;
            if (element.kind === 'item' || element.kind === 'fluid') return element.kind + ':' + element.id;
            if (element.kind === 'filter') return 'filter:' + element.id;
            if (element.kind === 'placeholder' && element.item) return 'item:' + element.item;
            return null;
        };
        processes.forEach(function (process) {
            const name = String(process.name);
            byName.set(name, process);
            edges.set(name, {});
            indegree.set(name, 0);
        });
        // The producer list keyed by material (identity) plus every output element, so
        // an input filter can also be matched against the outputs that are a subset of
        // it.
        const outputElements = [];
        processes.forEach(function (process) {
            const name = String(process.name);
            asArray(process.outputs).forEach(function (element) {
                if (element.craft === false) return;
                const key = materialKeyOf(element);
                if (!key) return;
                if (!producers.has(key)) producers.set(key, []);
                producers.get(key).push(name);
                outputElements.push({ producer: name, element: element });
            });
        });
        const link = function (producer, consumer) {
            // A process that feeds itself is not a dependency.
            if (producer === consumer) return;
            const out = edges.get(producer);
            if (!out || out[consumer]) return;
            out[consumer] = true;
            indegree.set(consumer, indegree.get(consumer) + 1);
        };
        processes.forEach(function (process) {
            const name = String(process.name);
            asArray(process.inputs).forEach(function (element) {
                const key = materialKeyOf(element);
                if (!key) return;
                asArray(producers.get(key)).forEach(function (producer) {
                    link(producer, name);
                });
                // Filter containment: an item/fluid/filter output that is a subset of
                // this input filter makes its producer an upstream dependency too.
                if (element.kind === 'filter') {
                    outputElements.forEach(function (entry) {
                        if (materialSatisfiesFilter(entry.element, element.id)) {
                            link(entry.producer, name);
                        }
                    });
                }
            });
        });
        const pending = processes.slice().sort(function (a, b) {
            return String(a.name).localeCompare(String(b.name));
        });
        const ready = pending.filter(function (process) {
            return indegree.get(String(process.name)) === 0;
        });
        const ordered = [];
        const placed = {};
        while (ready.length > 0) {
            const next = ready.shift();
            const name = String(next.name);
            ordered.push(next);
            placed[name] = true;
            Object.keys(edges.get(name) || {}).sort().forEach(function (consumer) {
                const left = indegree.get(consumer) - 1;
                indegree.set(consumer, left);
                if (left === 0) ready.push(byName.get(consumer));
            });
        }
        // A dependency cycle leaves the rest without a zero indegree: append those
        // in name order instead of dropping them from the graph.
        pending.forEach(function (process) {
            if (!placed[String(process.name)]) ordered.push(process);
        });
        return ordered;
    }

    // ---- graph layout (elk / dagre) -----------------------------------------
    // The dependency graph can be laid out by the bundled ELK engine (default, since
    // mermaid 12) or the classic dagre engine. The button in the panel header toggles
    // it, and the choice is remembered per browser.
    const GRAPH_LAYOUT_STORAGE = 'ifm.graphLayout';
    const GRAPH_LAYOUTS = ['elk', 'dagre'];
    let graphLayout = readSavedGraphLayout();

    function readSavedGraphLayout() {
        try {
            const saved = localStorage.getItem(GRAPH_LAYOUT_STORAGE);
            if (GRAPH_LAYOUTS.indexOf(saved) >= 0) return saved;
        } catch (err) { }
        return 'elk';
    }

    function graphLayoutLabelKey() {
        return graphLayout === 'dagre' ? 'graphLayoutDagre' : 'graphLayoutElk';
    }

    function renderGraphLayoutButton() {
        const label = el('graphLayoutLabel');
        if (label) label.textContent = t(graphLayoutLabelKey());
    }
    window.ifmRenderGraphLayoutButton = renderGraphLayoutButton;

    function setGraphLayout(next) {
        if (GRAPH_LAYOUTS.indexOf(next) < 0 || next === graphLayout) return;
        graphLayout = next;
        try { localStorage.setItem(GRAPH_LAYOUT_STORAGE, next); } catch (err) { }
        renderGraphLayoutButton();
        graphCodeCache = null;
        graphLangCache = null;
        renderGraph();
    }

    window.ifmToggleGraphLayout = function () {
        setGraphLayout(graphLayout === 'elk' ? 'dagre' : 'elk');
    };

    function buildGraphCode() {
        const processes = processGraphOrder(Array.from(stores.processes.values()));
        // layout: ELK (default) places nodes with its layered algorithm and routes the
        // edges itself; dagre is the classic engine, kept as a fallback the user can
        // switch to. look classic + small padding/minNodeWidth keep the nodes tight.
        // useMaxWidth off: mermaid must not squeeze a long chain down to the panel
        // width, #graph scrolls horizontally instead.
        const layoutInit = graphLayout === 'dagre'
            ? '"layout": "dagre",'
            : '"layout": "elk", "elk": {"nodePlacementStrategy": "BRANDES_KOEPF"},';
        const lines = [
            '%%{init: {"htmlLabels": true, "look": "classic", ' + layoutInit +
                ' "flowchart": {"look": "classic", "useMaxWidth": false, "nodeSpacing": 45, "rankSpacing": 70,' +
                ' "padding": 4, "wrappingWidth": 48, "minNodeWidth": 0}}}%%',
            'flowchart LR',
        ];
        nodeProcess.clear();
        nodeTooltip.clear();
        nodeMaterial.clear();
        nodeMachineIcon.clear();
        nodeConversion.clear();
        const materialIds = new Map();
        const materialLines = [];
        const edgeLines = [];
        const inputLinks = [];
        const outputLinks = [];
        const subsetLinks = [];

        const materialKindOf = function (element) {
            return element.kind === 'placeholder' ? 'item' : element.kind;
        };
        const materialIdOf = function (element) {
            return element.kind === 'placeholder' ? element.item : element.id;
        };
        // The tooltip of one material node. A placeholder-backed node is titled with
        // the placeholder's own name and spells out the item it stands for; the icon
        // and the craft request follow that item / that placeholder.
        const materialTooltip = function (entry) {
            const kind = entry.kind;
            const id = entry.id;
            const placeholder = entry.placeholder || '';
            // No craft counters on materials: they describe the processes that
            // produce this resource, so they are shown on those process nodes.
            const details = [tipField(t('tipRegistry'), id)];
            if (placeholder) {
                details.push(tipField(t('tipKind'), resourceKindLabel('placeholder')));
                details.push(tipField(t('tipPlaceholderItem'), displayName('item', id)));
            } else {
                details.push(tipField(t('tipKind'), resourceKindLabel(kind)));
            }
            // Filters show their stored total as well: the master sums every
            // matching item/fluid into the filter's resource entry.
            details.push(tipField(t('tipStored'), fmtCount(resourceStockByName(kind, id))));
            if (kind === 'item' || kind === 'fluid' || kind === 'filter') {
                details.push('', t('tipGraphCraft'));
            }
            return {
                title: placeholder ? t('placeholderKind') + ' ' + placeholder : materialNodeLabel(kind, id),
                lines: details,
            };
        };
        const materialNode = function (kind, id, element) {
            if (!id) return null;
            // A placeholder shares its node with the concrete item it stands for (the
            // engine treats them as one material flow, so splitting them would break
            // the drawn chain). The placeholder's own name is remembered on the node
            // and wins for the label; the icon stays the item's.
            const placeholder = (element && element.kind === 'placeholder' && element.name)
                ? String(element.name) : '';
            const key = kind + ':' + id;
            if (materialIds.has(key)) {
                const existing = materialIds.get(key);
                const seen = nodeMaterial.get(existing);
                if (placeholder && seen && !seen.placeholder) {
                    seen.placeholder = placeholder;
                    nodeTooltip.set(existing, materialTooltip(seen));
                }
                return existing;
            }
            const nodeId = 'M' + materialIds.size;
            materialIds.set(key, nodeId);
            const node = { kind: kind, id: id };
            if (placeholder) node.placeholder = placeholder;
            nodeMaterial.set(nodeId, node);
            nodeTooltip.set(nodeId, materialTooltip(node));
            materialLines.push('    ' + nodeId + '["' + GRAPH_ICON_HOLDER.replace(/"/g, '&quot;') + '"]');
            return nodeId;
        };
        const isMaterial = function (element) {
            if (elementIsAbstract(element)) return false;
            return element.kind === 'item' || element.kind === 'fluid' ||
                element.kind === 'filter' || element.kind === 'placeholder';
        };

        processes.forEach(function (process, index) {
            const record = stores.runtime.get(process.name) || {};
            const nodeId = 'P' + index;
            nodeProcess.set(nodeId, process.name);
            const batch = record.batch || 0;
            const demand = Number(record.needCount) || 0;
            const crafting = Number(record.activeCount) || 0;
            const left = Math.max(0, Number(record.remaining) || 0);
            const details = [tipField(t('tipState'), stateLabel(record.state || 'idle'))];
            // The tooltip title is the process's machine type (not the name the
            // editor derives from its products); the process name stays visible as
            // the first line so the node is still identifiable.
            details.unshift(tipField(t('processName'), String(process.name)));
            if (batch > 0) details.push(tipField(t('tipBatch'), fmtCount(batch)));
            if (record.machine) details.push(tipField(t('tipMachine'), record.machine));
            if (crafting > 0) details.push(tipField(t('tipCrafting'), fmtCount(crafting)));
            if (demand > 0) details.push(tipField(t('tipDemand'), fmtCount(demand)));
            if (left > 0) details.push(tipField(t('tipRemaining'), fmtCount(left)));
            details.push('', t('tipGraphClick'));
            nodeTooltip.set(nodeId, { title: machineTypeLabel(process.machineType), lines: details });
            // "crafting/demand" belongs to the process: how many craft units are
            // running right now and how many the demand adds up to.
            const countHtml = (crafting > 0 || demand > 0)
                ? "<span class='ifm-graph-count'>" +
                    escapeHtml(fmtCount(crafting) + '/' + fmtCount(demand)) + '</span>'
                : '';
            // A machine type may carry an icon: then its process nodes show that
            // icon instead of the plain dot.
            const machineIcon = machineIconNameOf(process.machineType);
            if (machineIcon) nodeMachineIcon.set(nodeId, machineIcon);
            const marker = machineIcon ? GRAPH_MACHINE_ICON_HOLDER : GRAPH_DOT;
            lines.push('    ' + nodeId + '(("' + marker + countHtml.replace(/"/g, '&quot;') + '"))');
            const materialEdges = function (list, amountOf) {
                const totals = new Map();
                const order = [];
                asArray(list).forEach(function (element) {
                    if (!isMaterial(element)) return;
                    const materialId = materialNode(materialKindOf(element), materialIdOf(element), element);
                    if (!materialId) return;
                    const amounts = amountOf(element);
                    if (!totals.has(materialId)) {
                        totals.set(materialId, { min: 0, expect: 0, max: 0 });
                        order.push(materialId);
                    }
                    const total = totals.get(materialId);
                    total.min += amounts.min;
                    total.expect += amounts.expect;
                    total.max += amounts.max;
                });
                return order.map(function (materialId) {
                    return { materialId: materialId, amounts: totals.get(materialId) };
                });
            };
            const inputAmount = function (element) {
                const count = Math.max(1, Math.round(Number(element.count) || 1));
                return { min: count, expect: count, max: count };
            };
            // A probabilistic output (the three amounts differ) is labelled
            // "expect(min~max)x", a plain one stays "expectx".
            const amountNumber = function (value, fallback) {
                const number = Number(value);
                return isFinite(number) ? number : fallback;
            };
            const outputAmount = function (element) {
                const expectRaw = element.expect !== undefined && element.expect !== null
                    ? element.expect : element.max;
                const minRaw = element.min !== undefined && element.min !== null ? element.min : expectRaw;
                const maxRaw = element.max !== undefined && element.max !== null ? element.max : expectRaw;
                // decimals are kept on purpose: a chance craft may expect 1.5 and
                // extract up to 2.5, and rounding here would misreport the recipe
                return {
                    min: Math.max(0, amountNumber(minRaw, 0)),
                    expect: amountNumber(expectRaw, 0) > 0 ? amountNumber(expectRaw, 1) : 1,
                    max: amountNumber(maxRaw, 0) > 0 ? amountNumber(maxRaw, 1) : 1
                };
            };
            const amountLabel = function (amounts) {
                const expect = fmtAmount(amounts.expect);
                if (amounts.min === amounts.expect && amounts.max === amounts.expect) return expect + 'x';
                return expect + '(' + fmtAmount(amounts.min) + '~' + fmtAmount(amounts.max) + ')x';
            };
            materialEdges(process.inputs, inputAmount).forEach(function (edge) {
                inputLinks.push(edgeLines.length);
                edgeLines.push('    ' + edge.materialId + ' -->|"' + escapeHtml(amountLabel(edge.amounts)) +
                    '"| ' + nodeId);
            });
            materialEdges(process.outputs, outputAmount).forEach(function (edge) {
                outputLinks.push(edgeLines.length);
                edgeLines.push('    ' + nodeId + ' -->|"' + escapeHtml(amountLabel(edge.amounts)) +
                    '"| ' + edge.materialId);
            });
        });
        // Auto-discovered containment: an output material that is a subset of an input
        // filter is shown through a synthetic "bridge" node between the two material
        // nodes (O -> C -> F). Clicking it opens the process editor prefilled with a
        // type conversion process, so the relation becomes an explicit process instead
        // of relying on tag matching. Same-process pairs are skipped (they would always
        // close a two-node cycle).
        const producerOutputs = [];
        processes.forEach(function (process) {
            asArray(process.outputs).forEach(function (element) {
                if (element.craft === false || !isMaterial(element)) return;
                producerOutputs.push({ process: String(process.name), element: element });
            });
        });
        const bridgeKey = function (element, filterId) {
            return materialKindOf(element) + ':' + materialIdOf(element) + '>' + String(filterId);
        };
        // An explicit type conversion process already covers this pair: no synthetic
        // bridge node then.
        const explicitBridges = {};
        processes.forEach(function (process) {
            if (String(process.machineType) !== TYPE_CONVERSION_TYPE) return;
            const input = asArray(process.inputs)[0];
            const output = asArray(process.outputs)[0];
            if (!input || !output) return;
            explicitBridges[bridgeKey(input, output.id)] = true;
        });
        const subsetSeen = {};
        processes.forEach(function (process) {
            const consumer = String(process.name);
            asArray(process.inputs).forEach(function (element) {
                if (element.kind !== 'filter' || !element.id) return;
                const toNode = materialNode('filter', element.id, element);
                if (!toNode) return;
                producerOutputs.forEach(function (entry) {
                    if (entry.process === consumer) return;
                    if (!materialSatisfiesFilter(entry.element, element.id)) return;
                    const fromNode = materialNode(materialKindOf(entry.element),
                        materialIdOf(entry.element), entry.element);
                    if (!fromNode || fromNode === toNode) return;
                    const seenKey = fromNode + '>' + toNode;
                    if (subsetSeen[seenKey]) return;
                    subsetSeen[seenKey] = true;
                    if (explicitBridges[bridgeKey(entry.element, element.id)]) return;
                    const bridgeId = 'C' + nodeConversion.size;
                    nodeConversion.set(bridgeId, { input: entry.element, filter: String(element.id) });
                    nodeTooltip.set(bridgeId, {
                        title: t('graphBridgeTitle'),
                        lines: [t('graphBridgeHint')]
                    });
                    lines.push('    ' + bridgeId + '(["' +
                        GRAPH_BRIDGE.replace(/"/g, '&quot;') + '"])');
                    subsetLinks.push(edgeLines.length);
                    edgeLines.push('    ' + fromNode + ' --> ' + bridgeId);
                    subsetLinks.push(edgeLines.length);
                    edgeLines.push('    ' + bridgeId + ' --> ' + toNode);
                });
            });
        });
        processes.forEach(function (process, index) {
            lines.push('    click P' + index + ' call ifmEditProcess()');
        });
        // Some crossings stay unavoidable in a factory graph (one material feeds
        // several processes), so the two directions each get a colour: "blue goes
        // in, green comes out" is what keeps such a crossing readable.
        const styleLines = [];
        if (inputLinks.length > 0) styleLines.push('    linkStyle ' + inputLinks.join(',') + ' stroke:#6fc3ff');
        if (outputLinks.length > 0) styleLines.push('    linkStyle ' + outputLinks.join(',') + ' stroke:#8fd18f');
        if (subsetLinks.length > 0) {
            // A subset feed is a "virtual" edge between two material nodes: dashed and
            // violet, so it is visibly different from a plain item/fluid flow.
            styleLines.push('    linkStyle ' + subsetLinks.join(',') +
                ' stroke:#c9a4ff,stroke-dasharray:5 3');
        }
        return lines.concat(materialLines, edgeLines, styleLines).join('\n');
    }

    // Pan the dependency graph by dragging empty space with the left button. The
    // container scrolls (mermaid renders the svg at its own size, see useMaxWidth
    // above), so a long chain stays readable instead of being scaled down. Node
    // clicks are untouched: panning only starts when the pointer is not on a node
    // and pointerdown is never default-prevented.
    function bindGraphPan(container) {
        if (container.dataset.panBound) return;
        container.dataset.panBound = '1';
        let panning = false;
        let startX = 0;
        let startY = 0;
        let startLeft = 0;
        let startTop = 0;
        container.addEventListener('pointerdown', function (event) {
            if (event.button !== 0) return;
            if (event.target.closest && (event.target.closest('g.node') || event.target.closest('a'))) return;
            panning = true;
            startX = event.clientX;
            startY = event.clientY;
            startLeft = container.scrollLeft;
            startTop = container.scrollTop;
            container.classList.add('panning');
            if (container.setPointerCapture) {
                try { container.setPointerCapture(event.pointerId); } catch (err) { }
            }
        });
        container.addEventListener('pointermove', function (event) {
            if (!panning) return;
            container.scrollLeft = startLeft - (event.clientX - startX);
            container.scrollTop = startTop - (event.clientY - startY);
            event.preventDefault();
        });
        const stopPan = function (event) {
            if (!panning) return;
            panning = false;
            container.classList.remove('panning');
            if (container.releasePointerCapture && event.pointerId !== undefined) {
                try { container.releasePointerCapture(event.pointerId); } catch (err) { }
            }
        };
        container.addEventListener('pointerup', stopPan);
        container.addEventListener('pointercancel', stopPan);
    }

    function openConversionBridge(nodeId) {
        const entry = nodeConversion.get(nodeId);
        if (!entry) return;
        const element = entry.input || {};
        const input = (element.kind === 'placeholder')
            ? { kind: 'item', id: element.item, count: 1, containerIndex: -1, slot: -1 }
            : {
                kind: element.kind, id: element.id, nbt: element.nbt,
                ignoreNbt: element.ignoreNbt === undefined ? true : element.ignoreNbt,
                count: 1, containerIndex: -1, slot: -1
            };
        if (!input.id) return;
        // Prefill a type conversion process: high multiplier (one big batch instead of
        // many tiny instances), unordered IO (streams the output while the input is
        // still arriving), the discovered input and the input filter as the output.
        openEditor('processes', null, {
            machineType: TYPE_CONVERSION_TYPE,
            maxMultiplier: 1000000,
            ioMode: 'unordered',
            inputs: [input],
            outputs: [{ kind: 'filter', id: entry.filter, min: 1, expect: 1, max: 1,
                containerIndex: -1, slot: -1 }]
        });
    }

    function bindGraphClicks(container) {
        Array.prototype.forEach.call(container.querySelectorAll('g.node'), function (node) {
            const match = /(^|-)P(\d+)(-|$)/.exec(node.id || '');
            const materialMatch = /(^|-)M(\d+)(-|$)/.exec(node.id || '');
            const bridgeMatch = /(^|-)C(\d+)(-|$)/.exec(node.id || '');
            const nodeId = match ? ('P' + match[2]) : (materialMatch ? ('M' + materialMatch[2])
                : (bridgeMatch ? ('C' + bridgeMatch[2]) : null));
            if (!nodeId || !nodeTooltip.has(nodeId)) return;
            node.setAttribute('data-tip-graph', nodeId);
            if (bridgeMatch) {
                node.style.cursor = 'pointer';
                node.addEventListener('click', function (event) {
                    event.stopPropagation();
                    openConversionBridge(nodeId);
                });
                return;
            }
            if (!match) {
                const material = nodeMaterial.get(nodeId);
                if (!material) return;
                if (material.kind !== 'item' && material.kind !== 'fluid' && material.kind !== 'filter') return;
                node.style.cursor = 'pointer';
                node.addEventListener('click', function (event) {
                    event.stopPropagation();
                    // Always offer the prompt: a material with no stock is usually
                    // just missing from the resource list (that list only holds what
                    // a container really carries), so asking stores.resources for
                    // "craftable" would answer no for resources the backend is
                    // perfectly able to queue. A process that cannot produce it is
                    // reported by the backend ("no process can produce it").
                    // A placeholder-backed node asks for the placeholder itself: the
                    // engine registers that key for the producing process, so the
                    // request cannot land on a material nobody produces.
                    openCraftPrompt(material.placeholder
                        ? { kind: 'placeholder', name: material.placeholder }
                        : { kind: material.kind, name: material.id });
                });
                return;
            }
            const processName = nodeProcess.get(nodeId);
            if (!processName) return;
            node.style.cursor = 'pointer';
            node.addEventListener('click', function (event) {
                event.stopPropagation();
                openEditor('processes', processName);
            });
        });
    }

    window.ifmEditProcess = function (nodeId) {
        const name = nodeProcess.get(nodeId);
        if (name) openEditor('processes', name);
    };

    let graphCodeCache = null;
    let graphLangCache = null;

    // One-shot diagnostic: prints the rendered SVG size, one node's shape size and its
    // label's measured size, and whether the label's HTML leaked out as literal text
    // (which is what makes nodes grow huge). Visible in the browser devtools console.
    function logGraphDebug(container) {
        try {
            if (!container || !console || !console.log) return;
            const svg = container.querySelector('svg');
            if (!svg) return;
            const node = container.querySelector('g.node');
            let shape = null;
            if (node) {
                const el = node.querySelector('rect, circle, ellipse, polygon, path');
                if (el) {
                    shape = { tag: el.tagName, w: el.getAttribute('width'), h: el.getAttribute('height'),
                        r: el.getAttribute('r') };
                    if (el.getBBox) {
                        const box = el.getBBox();
                        shape.bbox = Math.round(box.width) + 'x' + Math.round(box.height);
                    }
                }
            }
            const label = container.querySelector('g.node .nodeLabel') ||
                container.querySelector('g.node span.nodeLabel');
            let labelInfo = null;
            if (label && label.getBoundingClientRect) {
                const rect = label.getBoundingClientRect();
                labelInfo = { w: Math.round(rect.width), h: Math.round(rect.height),
                    html: String(label.innerHTML || '').slice(0, 60) };
            }
            // The node is sized from the label's <foreignObject> div, not the span: show
            // that div (and its <p>) so a mismatch is visible. Computed styles help.
            let box = null;
            if (node) {
                const fo = node.querySelector('foreignObject');
                const div = fo && fo.firstElementChild;
                const p = div && div.querySelector('p');
                const rectOf = function (el) {
                    if (!el || !el.getBoundingClientRect) return null;
                    const r = el.getBoundingClientRect();
                    return Math.round(r.width) + 'x' + Math.round(r.height);
                };
                const cs = div && window.getComputedStyle ? window.getComputedStyle(div) : null;
                box = {
                    fo: fo ? (fo.getAttribute('width') + 'x' + fo.getAttribute('height')) : '?',
                    div: rectOf(div), divDisplay: cs ? cs.display : '?',
                    divMaxW: cs ? cs.maxWidth : '?', divWhiteSpace: cs ? cs.whiteSpace : '?',
                    p: rectOf(p), pMargin: p && window.getComputedStyle
                        ? window.getComputedStyle(p).margin : '?'
                };
            }
            console.log('[IFM graph] svg=' + (svg.getAttribute('width') || '?') + 'x' +
                (svg.getAttribute('height') || '?') + ' viewBox=' + (svg.getAttribute('viewBox') || '?') +
                ' style=' + (svg.getAttribute('style') || '-'),
                'node=' + (node ? (node.id || '?') : 'none'), 'shape=', shape, 'label=', labelInfo,
                'box=', box, 'literalHtml=' + (String(svg.textContent || '').indexOf('<span') >= 0));
        } catch (err) { }
    }

    // mermaid builds the svg in a temporary container that it appends to <body> itself -
    // the third argument of its render() is that container. The node disappears only once
    // the drawing is ready, and since the panels became pages the document is short enough
    // for that spot to sit in view: it showed up as a blinking element at the bottom of
    // the page (the svg is called ifmGraphSvg*). Handing mermaid an off-screen sink keeps
    // its label measurement - and therefore the node sizes - exactly as it was while
    // nothing of it can be seen; the stylesheet hides a stray container of a mermaid build
    // that ignores the argument.
    function graphRenderSink() {
        let sink = document.getElementById('graphRenderSink');
        if (!sink) {
            sink = document.createElement('div');
            sink.id = 'graphRenderSink';
            sink.className = 'graph-render-sink';
            document.body.appendChild(sink);
        }
        return sink;
    }

    function clearGraphRenderSink() {
        const sink = document.getElementById('graphRenderSink');
        if (sink) sink.innerHTML = '';
    }

    function renderGraph() {
        renderGraphLayoutButton();
        const processes = Array.from(stores.processes.values());
        const container = el('graph');
        if (processes.length === 0) {
            graphCodeCache = null;
            container.innerHTML = '<span class="muted">' + escapeHtml(t('noProcess')) + '</span>';
            return;
        }
        if (!window.mermaid) {
            container.innerHTML = '<span class="muted">' + escapeHtml(t('graphMermaidMissing')) + '</span>';
            return;
        }
        if (graphRendering) return;
        let code;
        try {
            code = buildGraphCode();
        } catch (err) {
            return;
        }
        if (code === graphCodeCache && graphLangCache === lang) {
            return;
        }
        graphRendering = true;
        graphCodeCache = code;
        graphLangCache = lang;
        try {
            const initOptions = { startOnLoad: false, securityLevel: 'loose', theme: 'dark',
                htmlLabels: true, look: 'classic', layout: graphLayout,
                flowchart: { look: 'classic', useMaxWidth: false, nodeSpacing: 45, rankSpacing: 70,
                    padding: 4, wrappingWidth: 48, minNodeWidth: 0 } };
            if (graphLayout === 'elk') {
                initOptions.elk = { nodePlacementStrategy: 'BRANDES_KOEPF' };
            }
            mermaid.initialize(initOptions);
            graphRenderSeq += 1;
            // Never reuse the id of an SVG that is still in the page (see
            // graphRenderSeq): mermaid would find that older element instead of the
            // one it is building and remove it, so the panel went blank until the
            // new drawing was swapped in.
            const renderId = 'ifmGraphSvg' + graphRenderSeq;
            mermaid.render(renderId, code, graphRenderSink()).then(function (result) {
                clearGraphRenderSink();
                if (!result || !result.svg) {
                    // Nothing drawable came back: keep the drawing that is already
                    // there instead of wiping the panel.
                    graphCodeCache = null;
                    graphRendering = false;
                    return;
                }
                // Capture the scroll the user has *right now*: mermaid took a while to
                // draw and they may have panned (drag) or dragged the scrollbar since the
                // render started. Restoring a position captured before the render is what
                // made the graph snap back while processes kept running (running
                // instances change resource stock -> renderGraph re-runs every tick).
                const scrollLeft = container.scrollLeft;
                const scrollTop = container.scrollTop;
                container.innerHTML = result.svg;
                applyGraphIcons(container);
                applyGraphSearch(container);
                bindGraphPan(container);
                bindGraphClicks(container);
                logGraphDebug(container);
                const restoreScroll = function () {
                    if (container.scrollLeft !== scrollLeft) container.scrollLeft = scrollLeft;
                    if (container.scrollTop !== scrollTop) container.scrollTop = scrollTop;
                };
                restoreScroll();
                if (typeof window.requestAnimationFrame === 'function') {
                    window.requestAnimationFrame(restoreScroll);
                }
                graphRendering = false;
            }).catch(function (err) {
                clearGraphRenderSink();
                graphCodeCache = null;
                container.innerHTML = '<span class="muted">' + escapeHtml(String((err && err.message) || err)) + '</span>';
                graphRendering = false;
            });
        } catch (err) {
            clearGraphRenderSink();
            graphCodeCache = null;
            container.innerHTML = '<span class="muted">' + escapeHtml(String(err.message || err)) + '</span>';
            graphRendering = false;
        }
    }
