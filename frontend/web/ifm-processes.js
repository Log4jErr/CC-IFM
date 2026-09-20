// IFM :: web/ifm-processes.js
// 进程 / 外设与定义 / 机器 / 过滤器 / 依赖图
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 进程 =====================
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
        const percent = Math.max(0, Math.min(100, Math.round((item.percent || 0) * 100)));
        const cls = percent >= 100 ? '' : (percent > 0 ? 'warn' : 'bad');
        return '<div style="margin-top:6px">' +
            '<div style="display:flex;justify-content:space-between">' +
            '<span>' + escapeHtml(resourceLabel(item.kind, item.id)) + '</span>' +
            '<span>' + fmtCount(item.current || 0) + ' / ' + fmtCount(item.target || 0) + '</span>' +
            '</div>' +
            '<div class="progress"><div class="bar ' + cls + '" style="width:' + percent + '%"></div></div>' +
            '</div>';
    }

    // 流程标题由“产物”推导（流程定义没有名称字段）：Text 版返回纯文本，用于悬停详情
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

    // 当前阶段状态文本：正在发送/抽取 xxx、等待材料/机器/信号、定时等待
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
            const params = { name: name, done: fmtCount(current.done || 0), target: fmtCount(current.target || 0) };
            return current.phase === 'output' ? t('processExtracting', params) : t('processSending', params);
        }
        if (current.kind === 'placeholder') return t('placeholderKind') + ' ' + (current.name || '');
        if (current.kind === 'waitTime') return t('processWaitTime') + ' ' + fmtCount(current.seconds || 0) + 's';
        if (current.kind === 'waitSignal') return t('processWaitSignal');
        if (current.kind === 'emitSignal') return t('emitSignal');
        return '';
    }

    // 流程每批大约产出多少产物（取各产物元素的最多数目；用于把“批次数”换算成“产物数量”）
    function processPerBatch(process) {
        let per = 0;
        asArray(process.outputs).forEach(function (element) {
            if (element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter') {
                per = Math.max(per, Math.max(0, Number(element.max) || 0));
            }
        });
        return Math.max(1, per);
    }

    function renderProcesses() {
        // 只显示“有事可做”的流程（进行中 / 等待中 / 缺失）：服务端也只会下发这些（见 Recipe:idleRecord），
        // 空闲流程占了绝大多数，网页与推送都不要再管它们；流程定义永远能在「流程依赖图」里看到。
        const processes = Array.from(stores.processes.values()).filter(function (process) {
            const record = stores.runtime.get(process.name);
            if (!record) return false;
            const state = record.state || 'idle';
            const remaining = (record.userCount || 0) + (record.downstreamCount || 0);
            return state !== 'idle' || (record.batch || 0) > 0 || remaining > 0;
        });
        if (processes.length === 0) {
            el('processList').innerHTML = '<span class="muted">' + escapeHtml(t('noProcessRunning')) + '</span>';
            return;
        }
        processes.sort(function (a, b) {
            return a.name.localeCompare(b.name);
        });
        el('processList').innerHTML = processes.map(function (process) {
            const record = stores.runtime.get(process.name) || {};
            const state = record.state || 'idle';
            const bars = asArray(record.progress).map(progressBarHtml).join('');
            const batch = record.batch || 0;
            const phaseText = processPhaseText(record);
            // 引擎里的计数单位是“批次”，这里同时换算成“大约多少产物”，与下单时填的产物数量对齐
            const remaining = Math.max(0, record.remaining || 0);
            const perBatch = processPerBatch(process);
            return '<div class="flow-row">' +
                '<span class="state-tag ' + escapeHtml(state) + '">' + escapeHtml(stateLabel(state)) + '</span>' +
                '<span class="grow">' +
                '<strong>' + processTitle(process) + '</strong> ' +
                (record.machine ? '<span class="muted">@' + escapeHtml(record.machine) + '</span> ' : '') +
                (batch > 0 ? '<span class="muted">' + escapeHtml(t('processBatch', { n: fmtCount(batch) })) + '</span>' : '') +
                (phaseText ? '<div class="muted">' + escapeHtml(phaseText) + '</div>' : '') +
                (record.lastError ? '<div class="muted">' + escapeHtml(record.lastError) + '</div>' : '') +
                bars +
                '</span>' +
                '<span>' + escapeHtml(t('processRemaining', {
                    batches: fmtCount(remaining),
                    products: fmtCount(remaining * perBatch)
                })) + '</span>' +
                '<button class="btn-pixel danger" data-process-cancel="' + escapeHtml(process.name) + '" title="' +
                escapeHtml(t('cancelProcess')) + '"><i class="fa fa-stop"></i></button>' +
                '</div>';
        }).join('');
    }

    // ===================== 底部面板（待发送 / 发送中已取消显示） =====================
    // 队列面板固定在窗口底部，用它的高度补偿 body 下内边距，避免遮住页面内容
    // （待发送为空时面板整块隐藏，此时不需要任何补偿）
    function syncDeliveryPanelSpacing() {
        const panel = el('deliveryPanel');
        if (!panel) return;
        const hidden = panel.style.display === 'none' || panel.offsetHeight === 0;
        // 只在真的变化时才写：同一个值反复写也可能触发无谓的重排（面板高度每帧都在变时最容易看出来）
        const padding = hidden ? '' : ((panel.offsetHeight || 0) + 18) + 'px';
        if (document.body.style.paddingBottom !== padding) {
            document.body.style.paddingBottom = padding;
        }
    }

    // ===================== 外设与定义 =====================
    function roleLabel(role) {
        if (role === 'storage') return t('storage');
        if (role === 'input') return t('inputRole');
        if (role === 'interaction') return t('interaction');
        if (role === 'output') return t('output');
        return role || '';
    }


    // 外设卡片标题：主标题显示方块名（走 blocksitems 的方块接口，和物品一样），
    // 拿不到元信息时回落成方块注册名；灰色小字显示外设名（minecraft:chest_13）——
    // 定义、容器管理、诊断里用的都是这个名字，写方块注册名（minecraft:chest）对不上。
    function peripheralTitleHtml(peripheralName) {
        // resolvedBlockIdOf：不带命名空间的外设名（redstone_relay_0）会先按 candidates 找到
        // 真正存在的方块 id（computercraft:redstone_relay），这样标题与图标都正确
        // （见 ifm-core.js 的 blockIdCandidates）。
        const blockId = resolvedBlockIdOf(peripheralName);
        if (blockId) queueMeta('block', blockId);
        const label = blockId ? displayName('block', blockId) : String(peripheralName || '');
        return '<h3>' + blockIconHtml(peripheralName) + ' ' + escapeHtml(label) +
            ' <span class="muted" title="' + escapeHtml(t('peripheralNameHint')) + '">' +
            escapeHtml(String(peripheralName || '')) + '</span></h3>';
    }

    // 外设搜索用的文本池：外设名 / 方块名 / 方块注册名 / 定义名（容器与信号）
    function peripheralSearchTexts(block) {
        const raw = blockIdOf(block.name) || '';
        const blockId = resolvedBlockIdOf(block.name) || raw;
        const texts = [
            String(block.name || ''),
            raw,
            blockId,
            displayName('block', blockId),
            englishName('block', blockId)
        ];
        asArray(block.containers).forEach(function (def) { texts.push(String(def.name || '')); });
        asArray(block.signals).forEach(function (def) { texts.push(String(def.name || '')); });
        return texts.filter(function (text) { return !!text; })
            .map(function (text) { return String(text).toLowerCase(); });
    }

    function peripheralMatchesSearch(block, query) {
        if (searchQueryEmpty(query)) return true;
        const texts = peripheralSearchTexts(block);
        for (let i = 0; i < query.mods.length; i += 1) {
            if (!texts.some(function (text) { return modOfName(text) === query.mods[i]; })) return false;
        }
        for (let i = 0; i < query.tags.length; i += 1) {
            // 外设/方块没有标签数据：#xxx 就按“名称里包含”处理（与资源搜索的标签匹配保持一致）
            if (!texts.some(function (text) { return text.indexOf(query.tags[i]) >= 0; })) return false;
        }
        for (let i = 0; i < query.terms.length; i += 1) {
            if (!texts.some(function (text) { return text.indexOf(query.terms[i]) >= 0; })) return false;
        }
        return true;
    }

    function peripheralSortLabelText() {
        if (peripheralSortMode === 'block') return t('sortPeripheralBlock');
        if (peripheralSortMode === 'defs') return t('sortPeripheralDefs');
        return t('sortPeripheralPeripheral');
    }

    // 排序：外设名（默认，字典序）| 方块名 | 定义数量（多→少）；同值都回落到外设名
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

    // 缺失外设的搜索匹配：定义名 或 期望的外设名 命中即可
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

    // 缺失外设的条目：定义名 → 期望的外设名 + 类型 + 「删除该定义」按钮
    // （外设缺失时以前只能干看着：这里允许直接把背后的定义删掉）
    // 用户第 3 项（本轮）：机器直接引用的外设没有"定义"可删，所以那条只显示
    // "哪台机器在引用它"（提示用户去把机器的容器换成新的外设名 / 重新拖一次）。
    function missingChipHtml(item) {
        if (item.kind === 'machine') {
            const machine = String(item.machine || '');
            const hint = t('missingMachineRef', { machine: machine || '?' });
            return '<span class="chip missing" title="' + escapeHtml(hint) + '">' +
                escapeHtml(String(item.name || '')) +
                ' <span class="muted">' + escapeHtml(hint) + '</span></span>';
        }
        const isSignal = item.kind === 'signal';
        return '<span class="chip missing" title="' + escapeHtml(String(item.peripheral || '')) + '">' +
            escapeHtml(item.name) + ' → ' + escapeHtml(String(item.peripheral || '')) +
            ' <span class="muted">' + escapeHtml(isSignal ? t('signal') : t('container')) + '</span>' +
            '<button class="btn-pixel danger chip-del" type="button" title="' + escapeHtml(t('missingDelete')) + '"' +
            ' data-delete-missing="' + escapeHtml(item.name) + '"' +
            ' data-missing-kind="' + (isSignal ? 'signals' : 'containers') + '"' +
            ' data-missing-container-kind="' + escapeHtml(item.containerKind === 'fluid' ? 'fluid' : 'item') + '">' +
            '<i class="fa fa-trash"></i></button></span>';
    }

    // ===== 未分配功能 / 孤立定义 =====
    // “已分配”= 这个外设的这个功能已经有对应定义，而且被用起来了：
    // 存储容器归到存储卡片、机器容器/信号归到机器卡片。这里算出：
    //   * 还没定义的功能（未分配）——
    //   * 有定义但谁也不引用的（孤立：output 容器、没进机器的 interaction 容器）——
    // 两者都要能在方块卡片上找到，否则用户没法再操作它们。
    function machineUsedContainerNames() {
        const used = {};
        Array.from(stores.machines.values()).forEach(function (machine) {
            [machine.itemInputs, machine.fluidInputs, machine.itemOutputs, machine.fluidOutputs]
                .forEach(function (list) {
                    asArray(list).forEach(function (name) { used[String(name)] = true; });
                });
        });
        return used;
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
        // 定义以 stores.containers / stores.signals 为准：乐观更新后界面立刻正确，
        // 不必等服务端把 peripherals（含定义）推回来
        const defs = Array.from(stores.containers.values()).filter(function (def) {
            return String(def.peripheral || '') === blockName;
        });
        const signalDefs = Array.from(stores.signals.values()).filter(function (def) {
            return String(def.peripheral || '') === blockName;
        });
        const definedByKind = {};
        defs.forEach(function (def) {
            definedByKind[def.kind === 'fluid' ? 'fluid' : 'item'] = def;
        });
        const usedByMachine = machineUsedContainerNames();
        const chips = [];
        // 用户第 5 项（本轮）：机器**直接**引用了这个外设（例如输入列表里写着 minecraft:chest_109）时，
        // 它已经在用了 —— 以前这里还会画一张"未分配功能"的方块卡片，看起来像什么都没配。
        // （引用坏了的情况由"外设缺失"面板负责提示，见 Containers:missingPeripherals。）
        const referencedByMachine = usedByMachine[blockName] === true;
        // 1) 功能还没定义 → 未分配。
        //    chip 自己可拖拽（拖到存储卡片 / 机器位置 = 把这个功能分配过去），
        //    方块卡片本身不再整体可拖拽（否则拖里面任何地方都会带动整张卡片）。
        [['item', 'inventory', 'itemContainer', 'fa-archive'],
         ['fluid', 'fluid_storage', 'fluidContainer', 'fa-tint']].forEach(function (info) {
            if (referencedByMachine) return;
            if (block.kinds.indexOf(info[1]) < 0 || definedByKind[info[0]]) return;
            chips.push('<span class="chip unassigned" draggable="true"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '"' +
                ' data-drag-kind="' + info[0] + '"' +
                ' title="' + escapeHtml(t('unassignedHint')) + '">' +
                '<i class="fa ' + info[3] + '"></i> ' + escapeHtml(t(info[2])) +
                ' <span class="muted">' + escapeHtml(t('unassigned')) + '</span>' +
                '<button class="btn-pixel" data-new-container="' + escapeHtml(block.name) +
                '" data-container-kind="' + info[0] + '" title="' + escapeHtml(t('createDefinition')) +
                '"><i class="fa fa-plus"></i></button></span>');
        });
        // 红石中继器：一个可拖拽的“信号”芯片（拖到机器的红石信号卡片 = 让那台机器用它）。
        // 已经被机器引用的中继器不再显示方块卡片——被机器引用后卡片应当消失；
        // 想再给别的机器用，就从已引用它的那台机器的信号卡片拖过去（拖拽=复制归属）。
        const usedSignals = machineUsedSignalNames();
        if (block.kinds.indexOf('redstone_relay') >= 0 && !usedSignals[blockName] &&
            !usedSignals[String(signalDefs.length ? signalDefs[0].name : '')]) {
            const legacy = signalDefs[0] || null;
            // 有旧定义时可点击编辑（def-chip 的样式）；没有定义时就是一个纯拖拽源。
            chips.push('<span class="chip' + (legacy ? ' def-chip' : '') + ' def-signal" draggable="true"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '" data-drag-kind="signal"' +
                (legacy ? ' data-edit-signal="' + escapeHtml(legacy.name) + '"' : '') +
                ' title="' + escapeHtml(t('signalChipHint')) + '">' +
                '<i class="fa fa-bolt"></i> ' + escapeHtml(block.name) +
                ' <span class="muted">' + escapeHtml(t('signal')) + '</span></span>');
        }
        // 2) 有定义、但谁也不引用（output 容器 / 没进机器的 interaction 容器）：不能让它从界面上消失
        defs.forEach(function (def) {
            if (def.role === 'storage') return;                                        // 在存储卡片里
            if (def.role === 'input') return;                                          // 在输入卡片里
            if (def.role === 'output') return;                                         // 在输出卡片里（1.8.0）
            if (def.role === 'interaction' && usedByMachine[String(def.name)]) return;  // 在机器卡片里
            const kind = def.kind === 'fluid' ? 'fluid' : 'item';
            chips.push('<span class="chip def-chip def-' + kind + '" draggable="true"' +
                ' data-edit-container="' + escapeHtml(containerKeyOf(def)) + '"' +
                ' data-drag-peripheral="' + escapeHtml(String(def.peripheral || '')) + '"' +
                ' data-drag-kind="' + kind + '"' +
                ' data-drag-def="' + escapeHtml(containerKeyOf(def)) + '"' +
                ' title="' + escapeHtml(t('clickToEdit')) + '">' +
                '<i class="fa ' + (kind === 'fluid' ? 'fa-tint' : 'fa-cube') + '"></i> ' +
                escapeHtml(def.name) + ' <span class="muted">' + escapeHtml(roleLabel(def.role)) + '</span>' +
                '</span>');
        });
        // 3) 多余的旧信号定义（同一个中继器只该有一个定义）：万一旧配置里留了多个，
        //    仍然显示出来以便编辑/删除（第一个已经在上面的可拖拽芯片里了）。
        signalDefs.slice(1).forEach(function (def) {
            chips.push('<span class="chip def-chip def-signal" data-edit-signal="' + escapeHtml(def.name) +
                '" title="' + escapeHtml(t('clickToEdit')) + '">' +
                '<i class="fa fa-bolt"></i> ' + escapeHtml(def.name) + '</span>');
        });
        return chips;
    }

    // 存储 / 输入 / 输出 容器卡片（用户第 5/6 项）：
    //   一**张**卡片按角色聚合（物品容器与流体容器不再分成两张），拖外设卡片进来的含义：
    //     role=storage / input → 直接把它设成该角色的容器（种类按芯片/能力判定）；
    //     role=output          → 弹出"已经填好外设与角色"的容器定义卡片，名称留给用户填。
    //   拖出去（或点 ×）= 删掉这条定义。
    function containerRoleCardsHtml(role, config) {
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
        const chips = defs.map(function (def) {
            const peripheral = String(def.peripheral || '');
            const kind = def.kind === 'fluid' ? 'fluid' : 'item';
            const priority = Number(def.priority || 0);
            // 用户第 2 项：输出容器可以自己命名（存储 / 输入容器的定义名就是外设名）——
            // 名字和外设名不同时额外显示，一眼认出这条定义。
            const defLabel = String(def.name || '');
            const hasLabel = defLabel !== '' && defLabel !== peripheral;
            const badge = (role === 'storage' && priority !== 0)
                ? ' <span class="muted" title="' + escapeHtml(t('containerPriority')) + '">P' +
                  escapeHtml(String(priority)) + '</span>'
                : '';
            return '<span class="chip pc-chip" draggable="true"' +
                ' data-pc-peripheral="' + escapeHtml(peripheral) + '"' +
                ' data-pc-def="' + escapeHtml(def.name) + '"' +
                ' data-pc-kind="' + escapeHtml(kind) + '"' +
                ' data-pc-role="' + escapeHtml(role) + '"' +
                ' data-edit-container="' + escapeHtml(containerKeyOf(def)) + '"' +
                ' title="' + escapeHtml(peripheral + (hasLabel ? ' (' + defLabel + ')' : '') + ' · ' +
                    t(config.roleLabelKey) + ' · ' + t('clickToEdit')) + '">' +
                '<i class="fa ' + (kind === 'fluid' ? 'fa-tint' : 'fa-archive') + '"></i>' +
                ' <span class="chip-text">' + escapeHtml(peripheral || def.name) + '</span>' +
                (hasLabel ? '<span class="muted"> ' + escapeHtml(defLabel) + '</span>' : '') + badge +
                '<button class="btn-pixel danger chip-del" type="button" data-pc-role-remove="' + escapeHtml(role) + '" title="' +
                escapeHtml(t(config.removeKey)) + '"><i class="fa fa-times"></i></button>' +
                '</span>';
        }).join('');
        const dropAttr = ' data-' + role + '-drop="any"';
        return '<div class="card-block storage-card"' + dropAttr + '>' +
            '<div class="card-head">' +
            '<h3><i class="fa ' + (config.icon || 'fa-archive') + '"></i> ' + escapeHtml(t(config.cardKey)) +
            ' <span class="muted">' + defs.length + '</span></h3>' +
            '</div>' +
            '<div class="chip-list">' + (chips ||
                ('<span class="muted slot-empty">' + escapeHtml(t(config.hintKey)) + '</span>')) +
            '</div></div>';
    }

    function storageCardsHtml() {
        return containerRoleCardsHtml('storage', {
            cardKey: 'storageCard', icon: 'fa-archive',
            hintKey: 'storageDropHint', removeKey: 'storageRemove', roleLabelKey: 'storage',
        });
    }

    // 输入容器卡片（1.6.10）：与存储卡片同构，但角色是 input
    function inputCardsHtml() {
        return containerRoleCardsHtml('input', {
            cardKey: 'inputCard', icon: 'fa-download',
            hintKey: 'inputDropHint', removeKey: 'inputRemove', roleLabelKey: 'inputRole',
        });
    }

    // 输出容器卡片（1.8.0，用户第 6 项）：所有 role=output 的容器外设。
    // 拖外设进来不直接建定义，而是打开容器定义弹窗（外设/种类/角色=输出已填好，名称等用户填）。
    function outputCardsHtml() {
        return containerRoleCardsHtml('output', {
            cardKey: 'outputCard', icon: 'fa-upload',
            hintKey: 'outputDropHint', removeKey: 'outputRemove', roleLabelKey: 'outputRole',
        });
    }

    // ===================== 外设卡片的批量选择（用户第 6 项） =====================
    //   * Ctrl / Cmd + 左键点**外设芯片**（方块卡片里的"未分配功能"芯片 / 机器卡片里的外设芯片）= 加入或移出选择；
    //   * 在外设面板或机器面板里按住**右键拖动** = 框选（松开时把框到的芯片设为选择；按住 Ctrl 则追加）；
    //   * 选中多个时，拖其中任意一个 = 把选中的全部一起拖过去（类型不匹配的自动忽略并汇总提示）；
    //   * 点面板空白处 / Esc = 清空选择。
    // 本轮第 3 项：命中目标是**外设卡片（芯片）**而不是方块卡片 —— 这样能只选某个方块的某个外设；
    // 并且机器卡片里的外设芯片也能框选（以前不行）。
    // 选择只按外设名记在内存里：重画（每秒都可能发生）后依然保留，卡片不在了就自动移出。
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

    /// 整体替换选择（框选用）
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

    /// 机器卡片里当前看得见的外设名（本轮第 3 项：机器内的外设卡片也参与框选，
    /// 所以"选择清理"必须把它们算作仍然可见，否则选完下一秒重画就被清掉）
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

    /// 卡片已经不在面板里（被分配进机器/容器、或外设拔出）→ 从选择里去掉，别"看不见却被拖着走"。
    /// 机器卡片里的外设芯片也是"看得见的外设卡片"（本轮第 3 项），所以一并算进 present。
    function prunePeripheralSelection(blocks) {
        if (selectedPeripheralCards.size === 0) return;
        const present = machinePeripheralNames();
        asArray(blocks).forEach(function (block) { present[String(block.name)] = true; });
        selectedPeripheralCards.forEach(function (name) {
            if (!present[name]) selectedPeripheralCards.delete(name);
        });
    }

    /// 面板标题旁的"已选 N 张外设卡片"提示（让用户知道拖一下会带走几张）
    function renderPeripheralSelectionHint() {
        const node = el('peripheralSelHint');
        if (!node) return;
        const count = selectedPeripheralCards.size;
        node.textContent = count > 0 ? t('peripheralSelected', { n: count }) : '';
        node.title = count > 0 ? t('peripheralSelectedHint') : '';
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
        // 只显示“还有未分配功能 / 还有孤立定义”的方块卡片（不再显示物品容器、流体容器那些单独的块）
        const allBlocks = Array.from(blocks.values())
            .map(function (block) {
                block.chips = peripheralUnassignedChips(block);
                return block;
            })
            .filter(function (block) { return block.chips.length > 0; });
        // 选择里已经不存在的卡片（被分配进机器/容器后卡片消失）→ 自动移出
        prunePeripheralSelection(allBlocks);
        const list = sortPeripheralList(allBlocks.filter(function (block) {
            return peripheralMatchesSearch(block, query);
        }));
        const html = list.map(function (block) {
            // 注意：卡片本身不可拖拽（用户反馈：拖卡片内部的外设芯片时会把整张卡片拖走）。
            // 拖拽源是卡片里的每个芯片（未分配功能 / 孤立定义），见 peripheralUnassignedChips。
            // 用户第 6 项：卡片支持批量选择（Ctrl+点击 / 右键框选），选中的卡片带 .selected 高亮，
            // 它的芯片样式由 CSS（.card-block.selected .chip）统一处理。
            const selected = peripheralSelected(block.name);
            return '<div class="card-block' + (selected ? ' selected' : '') + '"' +
                ' data-peripheral-card="' + escapeHtml(block.name) + '">' +
                // 标题行本身可拖（用户第 6 项）：拖卡片标题 = 把这张（或选中的那一批）外设拖到机器/容器卡片上；
                // 卡片里的芯片仍然各自可拖（带各自的种类）。不写 data-drag-kind：种类按外设自己的能力推断。
                '<div class="peripheral-card-head" draggable="true"' +
                ' data-drag-peripheral="' + escapeHtml(block.name) + '"' +
                ' title="' + escapeHtml(t('peripheralDragHint')) + '">' +
                peripheralTitleHtml(block.name) + '</div>' +
                '<div class="chip-list">' + block.chips.join('') + '</div>' +
                '</div>';
        }).join('');
        el('peripheralList').innerHTML = html ||
            ('<span class="muted">' + escapeHtml(t('peripheralsAllAssigned')) + '</span>');
        renderPeripheralSelectionHint();

        // 机器类型卡片、存储容器卡片、缺失外设：各自一块（显示顺序由 index.html 决定）
        const machineBox = el('machineTypeList');
        if (machineBox) machineBox.innerHTML = machinesHtml();
        const storageBox = el('storageList');
        if (storageBox) storageBox.innerHTML = storageCardsHtml();
        // 输入容器卡片（1.6.10）：与存储卡片同构，角色是 input
        const inputBox = el('inputList');
        if (inputBox) inputBox.innerHTML = inputCardsHtml();
        // 输出容器卡片（1.8.0，用户第 6 项）：role=output —— 拖外设进来会弹出容器定义弹窗
        const outputBox = el('outputList');
        if (outputBox) outputBox.innerHTML = outputCardsHtml();
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
                    // 用户第 2 项：一键删除 —— 所有缺失定义一次删掉（单条删除是 chip 里的垃圾桶按钮）
                    '<button class="btn-pixel danger" type="button" data-delete-missing-all="1" title="' +
                    escapeHtml(t('missingDeleteAllHint')) + '"><i class="fa fa-trash"></i> ' +
                    escapeHtml(t('missingDeleteAll')) + '</button>' +
                    '</div>' +
                    '<div class="chip-list">' + missing.map(missingChipHtml).join('') + '</div></div>')
                : '';
        }
        // 排序按钮上显示当前模式
        const sortLabel = el('peripheralSortLabel');
        if (sortLabel) sortLabel.textContent = peripheralSortLabelText();
    }

    // ===================== 机器 =====================
    // 机器卡片里的三个“位置卡片”：输入容器 / 输出容器 / 红石信号（每个位置内部放外设卡片）
    const MACHINE_SLOTS = [
        { id: 'in', icon: 'fa-sign-in', label: 'machineSlotIn' },
        { id: 'out', icon: 'fa-sign-out', label: 'machineSlotOut' },
        { id: 'signal', icon: 'fa-bolt', label: 'machineSlotSignal' },
    ];

    // 用户第 3 项：机器槽位里的外设卡片要能标出"这个引用指向的外设已经不在了"（红框）。
    // 判定来源是服务端的「外设缺失」列表（Containers:missingPeripherals）：它给出的条目是
    // { kind = "container" | "signal", name = 定义名 } —— 卡片上的键与它一一对应。
    // 用服务端下发的列表（而不是前端自己猜"定义没了/外设没了"）可以避免推送还没到时的闪烁。
    function missingReferenceSet() {
        const set = new Set();
        Array.from(stores.missing.values()).forEach(function (item) {
            set.add(String(item.kind || '') + ':' + String(item.name || ''));
        });
        return set;
    }

    // 某个位置上的外设卡片清单（容器定义 → 背后的外设；信号定义 → 背后的红石外设）
    function machineSlotEntries(machine, slotId, missingRefs) {
        const refs = missingRefs || missingReferenceSet();
        const out = [];
        if (slotId === 'signal') {
            asArray(machine.signals).forEach(function (name) {
                const def = stores.signals.get(name);
                out.push({
                    defName: name,
                    kind: 'signal',
                    // 信号定义还没回推时用定义名兜底（信号定义名通常就是外设名）
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
                    // 非输出容器的定义名就是外设名（服务端 Store:containerNameFor）：
                    // 定义还没回推时也能直接显示成外设名，不会闪一下“缺失外设”
                    peripheral: def ? String(def.peripheral || '') : String(name || ''),
                    // 用户第 2 项（本轮）：服务端现在也会把"机器直接引用、但外设已经不在了"的名字
                    // 放进缺失列表（kind = "machine"）—— 有线调制解调器重连后外设重新编号时就是它。
                    missing: refs.has('container:' + String(name || '')) ||
                        refs.has('machine:' + String(name || ''))
                });
            });
        });
        return out;
    }

    // 位置卡片里的外设卡片：可拖拽 —— 拖到别的位置 = 换位置，拖到机器卡片外 = 从这台机器移出。
    // 只读机器（用户第 3 项：海龟合成器）里的卡片例外：不能拖、也没有 × 删除按钮 ——
    // 这些外设是后端按海龟自动生成/收回的归属，人工删掉没有意义。
    function machinePeripheralCardHtml(machine, slotId, entry, readOnly) {
        const kind = entry.kind;
        const badgeTitle = kind === 'signal' ? t('machineSlotSignal')
            : t(slotId === 'in'
                ? (kind === 'fluid' ? 'fluidInputs' : 'itemInputs')
                : (kind === 'fluid' ? 'fluidOutputs' : 'itemOutputs'));
        const badgeClass = kind === 'signal' ? 'chip-badge kind-signal' : 'chip-badge kind-' + kind + '-' + slotId;
        const badgeIcon = kind === 'fluid' ? 'fa-tint' : (kind === 'signal' ? 'fa-bolt' : 'fa-cube');
        const peripheral = String(entry.peripheral || '');
        // 用户第 3 项：这条引用指向的外设不在了（服务端的缺失列表里有它）→ 卡片加红框
        const missing = peripheral === '' || entry.missing === true;
        const text = missing ? entry.defName : peripheral;
        // 用户第 2 项：输出容器允许自己命名 —— 名字和外设名不一样时补一个灰色标签，
        // 机器卡片里也能一眼看出这个位置接的是哪条定义。
        const defLabel = String(entry.defName || '');
        const hasLabel = !missing && defLabel !== '' && defLabel !== peripheral;
        // 标题里写清“哪个外设 / 哪条定义 + 在机器的哪个位置”：名字太长被省略号截断时靠它看全
        const title = (missing ? t('missingPeripheral') + ': ' + entry.defName : peripheral) +
            (hasLabel ? ' (' + defLabel + ')' : '') + ' · ' + badgeTitle;
        // 本轮第 3 项：机器卡片里的外设芯片也能被选中（框选 / Ctrl+点击）—— 选中的带 .selected
        const selectedChip = peripheral !== '' && peripheralSelected(peripheral);
        return '<span class="chip pc-chip' + (readOnly ? ' chip-readonly' : '') +
            (missing ? ' chip-missing' : '') +
            (selectedChip ? ' selected' : '') + '"' +
            (readOnly ? '' : ' draggable="true"') +
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
    // 机器类型卡片（含机器卡片）+ 没有归属类型的机器：拼进「外设与定义」板块的末尾
    // 层级：机器类型卡片 → 机器卡片 → 输入容器 / 输出容器 / 红石信号 → 外设卡片
    // 预设机器类型（后端 Store.TURTLE_CRAFTER_TYPE）：机器由海龟自动出现
    const TURTLE_CRAFTER_TYPE = 'turtle_crafter';

    /// 机器类型显示名（用户第 1 项）：预设类型在网页上本地化（turtle_crafter → 海龟合成器），
    /// 用户自定义类型原样显示（没有译文就退回原始类型名）。
    const MACHINE_TYPE_LABEL_KEYS = { turtle_crafter: 'machineTypeTurtleCrafter' };
    function machineTypeLabel(name) {
        const key = MACHINE_TYPE_LABEL_KEYS[String(name)];
        if (!key) return String(name);
        const text = t(key);
        return (text && text !== key) ? text : String(name);
    }

    function machinesHtml() {
        const machines = Array.from(stores.machines.values());
        machines.sort(function (a, b) { return a.name.localeCompare(b.name); });
        // 用户第 3 项：机器卡片里的外设卡片 / 位置框靠它标红（= 服务端「缺失外设」列表里的定义）
        const missingRefs = missingReferenceSet();
        const machineCard = function (machine) {
            const parallel = machine.parallel || 1;
            const running = machine.running || 0;
            const percent = Math.min(100, Math.round(running / Math.max(1, parallel) * 100));
            // 只读机器（用户第 5 项 / 本轮第 1 项）：自动生成的机器（virtual = true，海龟合成器）
            // **以及预设类型的机器**都只读 —— 不能点开编辑、不给红石信号位置
            //（信号只能人工配置；海龟机器的输入/输出就是海龟自己）。
            // 以前只按 virtual 判定：手工建的 / 旧配置里的同类型机器照样显示红石信号。
            const readOnly = machine.virtual === true || machineTypeIsReadOnly(machine.type);
            const slotInfos = readOnly ? MACHINE_SLOTS.filter(function (info) {
                return info.id !== 'signal';
            }) : MACHINE_SLOTS;
            const slots = slotInfos.map(function (info) {
                const entries = machineSlotEntries(machine, info.id, missingRefs);
                const cards = entries.map(function (entry) {
                    return machinePeripheralCardHtml(machine, info.id, entry, readOnly);
                }).join('');
                // 用户第 3 项：这个位置里有"外设已缺失"的卡片 → 位置框也标红
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

        // 机器类型卡片右上角的「+ 机器」：新建的机器自动属于该类型（机器名仍按类型自动推导）。
        // 预设类型 turtle_crafter 例外（用户第 1 项）：它的机器由海龟自己出现（后端 syncTurtleCrafters），
        // 手工加机器没有意义 —— 这里只显示一句说明，不给按钮。
        const addMachineButton = function (type) {
            if (type === TURTLE_CRAFTER_TYPE) {
                return '<span class="muted">' + escapeHtml(t('machineAutoTurtle')) + '</span>';
            }
            return '<button class="btn-pixel primary" type="button" data-add-machine="' + escapeHtml(type) +
                '" title="' + escapeHtml(t('addMachineHint')) + '"><i class="fa fa-plus"></i> ' +
                escapeHtml(t('machine')) + '</button>';
        };
        const types = Array.from(stores.machineTypes.values());
        types.sort(function (a, b) { return a.name.localeCompare(b.name); });
        const usedTypes = {};
        let html = types.map(function (item) {
            const children = machines.filter(function (machine) { return machine.type === item.name; });
            if (children.length > 0) usedTypes[item.name] = true;
            const typeLabel = machineTypeLabel(item.name);
            // 用户第 3 项：预设类型（海龟合成器）的卡片不给编辑入口 —— 它没有人工可配的东西
            //（机器由海龟自动出现）。属性不写，点击委托里也再挡一次（见 ifm-app.js）。
            const typeEditable = !machineTypeIsReadOnly(item.name);
            return '<div class="card-block"' + (typeEditable
                ? ' data-edit-machine-type="' + escapeHtml(item.name) + '"'
                : ' data-machine-type-card="' + escapeHtml(item.name) + '"') +
                '>' +
                '<div class="card-head">' +
                '<h3><i class="fa fa-cubes"></i> ' + escapeHtml(typeLabel) +
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
            html += '<div class="card-block" style="border-color:var(--warn)">' +
                '<div class="card-head">' +
                '<h3><i class="fa fa-cubes"></i> ' + escapeHtml(t('machineTypeField')) + ' ?</h3>' +
                addMachineButton('') +
                '</div>' +
                '<div class="machine-list">' + orphans.map(machineCard).join('') + '</div></div>';
        }
        return html;
    }

    // ===================== 过滤器 =====================
    // 过滤器芯片的图标与资源网格里的“过滤器”项完全一致：用它自己的 samples 轮流显示
    // （data-filter-icon / data-samples 会被 rotateFilterIcons 定时轮换）
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

    // ===================== 流程依赖图（mermaid） =====================
    // 某个材料（kind:id）由哪些流程产出 → 这台材料“正在合成 / 剩余目标”的合计。
    //   正在合成 = 各产出流程当前批次里材料已送到机器的份数（后端 record.active）
    //   剩余目标 = 各产出流程还需要合成的份数（后端 record.remaining）
    // 例：下游流程要 10 份 + 用户手动要 15 份、已合成 3 份 → 剩余 22；当前已送料 9 份 → 显示 9/22
    function materialCraftCounts(kind, id) {
        let active = 0;
        let target = 0;
        Array.from(stores.processes.values()).forEach(function (process) {
            const produces = asArray(process.outputs).some(function (element) {
                const elementKind = element.kind === 'placeholder' ? 'item' : element.kind;
                const elementId = element.kind === 'placeholder' ? element.item : element.id;
                return elementKind === kind && String(elementId || '') === String(id || '');
            });
            if (!produces) return;
            const record = stores.runtime.get(process.name);
            if (!record) return;
            active += Number(record.active) || 0;
            target += Number(record.remaining) || 0;
        });
        return { active: active, target: target };
    }

    function materialNodeLabel(kind, id) {
        if (kind === 'filter') return t('filterKind2') + ' ' + id;
        return displayName(kind, id);
    }

    // 材料节点的图标：在 mermaid 渲染完成后再写进 DOM（见 applyGraphIcons）。
    // 为什么不直接写在 mermaid 的节点标签里：节点标签会被 mermaid 自己加工（HTML 标签在它手里
    // 不可靠：实测 <img> 到不了最终 SVG 里），于是标签只剩一个定尺占位符，
    // 渲染完拿到真正的 DOM 之后再把图标塞进去 —— 和资源网格用的是同一套图标逻辑
    // （乐观图片 + 加载失败时换成名称兜底）。
    //
    // 占位符自带 inline 宽高：mermaid 量节点尺寸时看得到它（CSS 里的 #graph svg ... 选择器
    // 在量尺寸的临时容器里不生效），所以节点大小仍然按 26×26 的图标算。
    // 同时图里用 %%{init}%% 强制 htmlLabels：这样占位符是 HTML 元素、量出来的尺寸才准。
    const GRAPH_ICON_HOLDER =
        "<span class='ifm-graph-icon' style='display:inline-block;width:26px;height:26px'></span>";

    // 图标内容（写进占位符里的东西）：物品/流体用接口图片，其它用类型字形
    function graphIconContentHtml(kind, id) {
        if (kind !== 'item' && kind !== 'fluid') {
            return "<i class='fa " + iconGlyphClass(kind) + "' style='font-size:20px'></i>";
        }
        queueMeta(kind, id);
        // plainIconImg：单张图片 + data-icon-key + onerror → ifmIconFallback（名称兜底），
        // 与资源网格、库存选择弹窗完全一致
        return plainIconImg(kind, id);
    }

    // 渲染后把图标写进材料节点：先找占位符（能保住 class 时最省事），找不到就退回到标签容器
    function applyGraphIcons(container) {
        Array.prototype.forEach.call(container.querySelectorAll('g.node'), function (node) {
            const match = /(^|-)M(\d+)(-|$)/.exec(node.id || '');
            if (!match) return;
            const material = nodeMaterial.get('M' + match[2]);
            if (!material) return;
            const holder = node.querySelector('.ifm-graph-icon') || node.querySelector('.nodeLabel') ||
                node.querySelector('.label');
            if (!holder) return;
            if (holder.classList && holder.classList.contains('ifm-graph-icon')) {
                // 占位符还在：只换里面的内容（外面的定尺样式保留）
                holder.innerHTML = graphIconContentHtml(material.kind, material.id);
                return;
            }
            holder.innerHTML = "<span class='ifm-graph-icon' style='display:inline-block;width:26px;height:26px'>" +
                graphIconContentHtml(material.kind, material.id) + "</span>";
        });
    }

    // 依赖图：材料节点 ↔ 流程节点交替连接（流程之间不直连、材料之间也不直连）
    //   材料节点：正方形，只显示物品图标       流程节点：圆形，不带文本
    // 两类节点的详细信息（名称 / 库存 / 状态 / 批次…）都在鼠标悬停时显示。
    const GRAPH_DOT = "<span class='ifm-graph-dot'></span>";

    // 材料节点 id（M0 / M1 …）→ { kind, id }：渲染完成后点节点图标时用它弹「合成 N 个」
    const nodeMaterial = new Map();

    function buildGraphCode() {
        const processes = Array.from(stores.processes.values());
        processes.sort(function (a, b) { return a.name.localeCompare(b.name); });
        const lines = [
            // 强制 mermaid 用 HTML 标签：材料节点的标签是一个定尺 <span>（见 GRAPH_ICON_HOLDER），
            // HTML 标签下量出来的尺寸才是 26×26；否则标签会被当成纯文本量尺寸，节点大小不对。
            '%%{init: {"flowchart": {"htmlLabels": true}}}%%',
            'flowchart LR',
        ];
        nodeProcess.clear();
        nodeTooltip.clear();
        nodeMaterial.clear();
        const materialIds = new Map();
        const materialLines = [];
        const edgeLines = [];

        const materialKindOf = function (element) {
            return element.kind === 'placeholder' ? 'item' : element.kind;
        };
        const materialIdOf = function (element) {
            return element.kind === 'placeholder' ? element.item : element.id;
        };
        const materialNode = function (kind, id) {
            if (!id) return null;
            const key = kind + ':' + id;
            if (materialIds.has(key)) return materialIds.get(key);
            const nodeId = 'M' + materialIds.size;
            materialIds.set(key, nodeId);
            // 记下这个节点代表哪个资源：渲染完成后点图标就能直接弹「合成 N 个」
            nodeMaterial.set(nodeId, { kind: kind, id: id });
            const entry = stores.resources.get(resourceKey(kind, id)) || {};
            // 「正在合成 / 剩余目标」（例如 9/22）：只有真的有活时才显示，空闲的材料节点保持干净
            const craft = materialCraftCounts(kind, id);
            const showCount = craft.target > 0 || craft.active > 0;
            const countHtml = showCount
                ? "<span class='ifm-graph-count'>" + escapeHtml(fmtCount(craft.active) + '/' + fmtCount(craft.target)) + '</span>'
                : '';
            // 正方形材料节点里只放图标：详情（注册名 / 种类 / 库存）放进悬停信息
            const details = [
                tipField(t('tipRegistry'), id),
                tipField(t('tipKind'), resourceKindLabel(kind)),
            ];
            if (kind !== 'filter') details.push(tipField(t('tipStored'), fmtCount(entry.count || 0)));
            if (showCount) {
                details.push(tipField(t('tipCrafting'), fmtCount(craft.active)));
                details.push(tipField(t('tipCraftTarget'), fmtCount(craft.target)));
            }
            if (kind === 'item' || kind === 'fluid') details.push('', t('tipGraphCraft'));
            nodeTooltip.set(nodeId, { title: materialNodeLabel(kind, id), lines: details });
            // 标签里只放定尺占位符：真正的图标在渲染完成之后由 applyGraphIcons 写进去
            materialLines.push('    ' + nodeId + '["' + GRAPH_ICON_HOLDER.replace(/"/g, '&quot;') +
                countHtml.replace(/"/g, '&quot;') + '"]');
            return nodeId;
        };
        const isMaterial = function (element) {
            // 抽象操作（注册名 = abstract 的物品/流体元素）不是真实资源：它在依赖图里连节点都不建
            if (elementIsAbstract(element)) return false;
            return element.kind === 'item' || element.kind === 'fluid' ||
                element.kind === 'filter' || element.kind === 'placeholder';
        };

        processes.forEach(function (process, index) {
            const record = stores.runtime.get(process.name) || {};
            const nodeId = 'P' + index;
            nodeProcess.set(nodeId, process.name);
            const batch = record.batch || 0;
            const remaining = (record.userCount || 0) + (record.downstreamCount || 0);
            // 圆形流程节点不带文本：状态 / 批次 / 机器等详情放进悬停信息
            const details = [tipField(t('tipState'), stateLabel(record.state || 'idle'))];
            if (batch > 0) details.push(tipField(t('tipBatch'), fmtCount(batch)));
            if (record.machine) details.push(tipField(t('tipMachine'), record.machine));
            if (remaining > 0) details.push(tipField(t('tipRemaining'), fmtCount(remaining)));
            details.push('', t('tipGraphClick'));
            nodeTooltip.set(nodeId, { title: processTitleText(process), lines: details });
            lines.push('    ' + nodeId + '(("' + GRAPH_DOT + '"))');
            // 用户第 1/2 项：同一种材料在同一个流程里可能出现在多条元素上（例如 9 条 1x Iron Nugget）。
            //   ① **聚合**：材料 ↔ 流程之间每个材料只留一条连线（以前 N 条重复连线叠在一起）；
            //   ② 连线两端都标注"这个流程合成一次消耗 / 产出的此项目总数"（Σ 各条数量）。
            const materialEdges = function (list, amountOf) {
                const totals = new Map();
                const order = [];
                asArray(list).forEach(function (element) {
                    if (!isMaterial(element)) return;
                    const materialId = materialNode(materialKindOf(element), materialIdOf(element));
                    if (!materialId) return;
                    if (!totals.has(materialId)) {
                        totals.set(materialId, 0);
                        order.push(materialId);
                    }
                    totals.set(materialId, totals.get(materialId) + amountOf(element));
                });
                return order.map(function (materialId) {
                    return { materialId: materialId, amount: totals.get(materialId) };
                });
            };
            const inputAmount = function (element) {
                return Math.max(1, Math.round(Number(element.count) || 1));
            };
            const outputAmount = function (element) {
                return Math.max(1, Math.round(Number(element.max) || 1));
            };
            // 用户第 2 项：连线两端都标注"这个流程合成一次消耗 / 产出的此项目总数"（Σ 各条数量）：
            //   材料 → 流程  = 消耗总数（Σ count）        流程 → 产物 = 产出总数（Σ max）
            materialEdges(process.inputs, inputAmount).forEach(function (edge) {
                edgeLines.push('    ' + edge.materialId + ' -->|"' + escapeHtml(fmtCount(edge.amount)) + 'x"| ' + nodeId);
            });
            materialEdges(process.outputs, outputAmount).forEach(function (edge) {
                edgeLines.push('    ' + nodeId + ' -->|"' + escapeHtml(fmtCount(edge.amount)) + 'x"| ' + edge.materialId);
            });
        });
        // mermaid 的 JS 回调必须写成 `click <id> call <fn>()`（写成 `click <id> <fn>` 会被当成链接）
        processes.forEach(function (process, index) {
            lines.push('    click P' + index + ' call ifmEditProcess()');
        });
        return lines.concat(materialLines, edgeLines).join('\n');
    }

    // 渲染完成后自己绑定点选（不依赖 mermaid 回调参数）：点流程节点即可编辑流程；
    // 材料节点（正方形）与流程节点（圆形）都带上 data-tip-graph，悬停时用同一个悬浮框显示详情
    function bindGraphClicks(container) {
        Array.prototype.forEach.call(container.querySelectorAll('g.node'), function (node) {
            const match = /(^|-)P(\d+)(-|$)/.exec(node.id || '');
            const materialMatch = /(^|-)M(\d+)(-|$)/.exec(node.id || '');
            const nodeId = match ? ('P' + match[2]) : (materialMatch ? ('M' + materialMatch[2]) : null);
            if (!nodeId || !nodeTooltip.has(nodeId)) return;
            node.setAttribute('data-tip-graph', nodeId);
            if (!match) {
                // 材料节点（正方形）：点它 = 给这个物品填「合成 N 个」（与资源格里中键同一个弹窗）
                const material = nodeMaterial.get(nodeId);
                if (!material) return;
                if (material.kind !== 'item' && material.kind !== 'fluid') return;   // 过滤器不能合成
                node.style.cursor = 'pointer';
                node.addEventListener('click', function (event) {
                    event.stopPropagation();
                    openCraftPrompt({ kind: material.kind, name: material.id });
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

    // 依赖图重画缓存：mermaid.render 会重建整块 SVG，内容没变的重画在网页上就是“闪烁”，
    // 所以只有图内容（或界面语言）真的变了才重画。
    let graphCodeCache = null;
    let graphLangCache = null;

    function renderGraph() {
        const processes = Array.from(stores.processes.values());
        const container = el('graph');
        if (processes.length === 0) {
            graphCodeCache = null;
            container.innerHTML = '<span class="muted">' + escapeHtml(t('noProcess')) + '</span>';
            return;
        }
        if (!window.mermaid) {
            container.innerHTML = '<span class="muted">mermaid 未加载</span>';
            return;
        }
        if (graphRendering) return;
        let code;
        try {
            code = buildGraphCode();
        } catch (err) {
            return;
        }
        // 内容与语言都没变：直接返回（不再重建 SVG —— 这就是之前依赖图闪烁的原因）
        if (code === graphCodeCache && graphLangCache === lang) {
            return;
        }
        graphRendering = true;
        graphCodeCache = code;
        graphLangCache = lang;
        try {
            mermaid.initialize({ startOnLoad: false, securityLevel: 'loose', theme: 'dark' });
            mermaid.render('ifmGraphSvg', code).then(function (result) {
                container.innerHTML = result.svg;
                applyGraphIcons(container);
                bindGraphClicks(container);
                graphRendering = false;
            }).catch(function (err) {
                graphCodeCache = null;      // 失败：下次重新试
                container.innerHTML = '<span class="muted">' + escapeHtml(String((err && err.message) || err)) + '</span>';
                graphRendering = false;
            });
        } catch (err) {
            graphCodeCache = null;
            container.innerHTML = '<span class="muted">' + escapeHtml(String(err.message || err)) + '</span>';
            graphRendering = false;
        }
    }


    
