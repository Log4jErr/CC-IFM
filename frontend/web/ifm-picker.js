// IFM :: web/ifm-picker.js
// 库存选择弹窗与元素行图标
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 「从库存选择」弹窗 =====================
    // 流程元素行的资源名可以从这里挑：列出图标 + 名称 + 库存数，带搜索框（按显示名或完整 ID 过滤）
    let stockInstance = null;
    let stockTargetInput = null;
    let stockKind = 'item';
    let stockRefreshTimer = null;

    function stockModalInstance() {
        if (!stockInstance) stockInstance = new bootstrap.Modal(el('stockModal'));
        return stockInstance;
    }

    function stockEntries() {
        return Array.from(stores.resources.values())
            .filter(function (entry) { return entry.kind === stockKind; })
            .sort(function (a, b) {
                const countA = a.count || 0;
                const countB = b.count || 0;
                if (countA !== countB) return countB - countA;            // 有库存的排前面
                return displayName(a.kind, a.name).localeCompare(displayName(b.kind, b.name));
            });
    }

    function renderStockList() {
        const list = el('stockList');
        if (!list) return;
        const search = el('stockSearch');
        const rawQuery = String((search && search.value) || '').trim();
        let entries = stockEntries();
        if (rawQuery) {
            // 与资源网格同一套语法：#标签 / @模组 / 关键词
            const query = parseSearchQuery(rawQuery);
            entries = entries.filter(function (entry) { return matchesSearch(entry, query); });
        }
        queueTranslateNames(entries);
        list.innerHTML = entries.length
            ? entries.map(function (entry) {
                return '<button class="stock-item" type="button" data-stock-pick="' + escapeHtml(entry.name) + '">' +
                    iconHtml(entry.kind, entry.name) +
                    '<span class="stock-name" title="' + escapeHtml(entry.name) + '">' +
                    escapeHtml(displayName(entry.kind, entry.name)) + '</span>' +
                    '<span class="stock-count">' + fmtCount(entry.count || 0) + '</span>' +
                    '</button>';
            }).join('')
            : '<span class="muted">' + escapeHtml(t('noData')) + '</span>';
        const hint = el('stockHint');
        if (hint) hint.textContent = t('stockCount', { n: entries.length });
        // 图标元信息是异步拉的：列表里还有“元信息未就绪”的项时，稍后自动重画一次，
        // 这样打开弹窗后图标会从字形补成真实图标，不用关掉再开
        if (!stockRefreshTimer && entries.some(function (entry) {
            return metaState(resourceKey(entry.kind, entry.name)) === 'unknown';
        })) {
            stockRefreshTimer = setTimeout(function () {
                stockRefreshTimer = null;
                renderStockList();
            }, 1200);
        }
    }

    window.ifmOpenStockPicker = function (button) {
        const slot = button.closest('.id-slot');
        stockTargetInput = slot ? slot.querySelector('.e-id') : null;
        stockKind = button.getAttribute('data-stock-kind') === 'fluid' ? 'fluid' : 'item';
        const search = el('stockSearch');
        if (search) search.value = '';
        syncSearchClear('stockSearch');
        renderStockList();
        stockModalInstance().show();
        setTimeout(function () { if (search) search.focus(); }, 300);
    };

    function pickStock(name) {
        if (!name) return;
        const label = displayName(stockKind, name);
        if (stockTargetInput) stockTargetInput.value = name;
        stockModalInstance().hide();
        toast(t('stockPicked', { name: label }), 'success');
    }

    function numberField(when, label, className, value, width, step) {
        return '<span data-when="' + when + '" class="muted">' + escapeHtml(label) +
            ' <input type="number" class="' + className + '" value="' + escapeHtml(value === undefined || value === null ? '' : value) +
            '" style="width:' + width + 'px"' + (step ? ' step="' + step + '"' : '') + '></span>';
    }

    function textField(when, label, className, value, width) {
        return '<span data-when="' + when + '" class="muted">' + escapeHtml(label) +
            ' <input type="text" class="' + className + '" value="' + escapeHtml(value || '') +
            '" style="width:' + width + 'px"></span>';
    }

    // 元素行列表的容器 id：必须与 index.html 里的固定 id 不重名
    // （#inputList 是「外设与定义」板块的输入容器卡片，页面里排在编辑弹窗前面 ——
    // 重名时 el('inputList') 拿到的是它，新加的材料行会被塞进那个隐藏板块，
    // 表现就是“新建流程时加不了输入材料”，见 window.ifmAddElement）。
    function elementRowListId(side) {
        return side === 'input' ? 'elementInputList' : 'elementOutputList';
    }

    function elementRowHtml(side, element) {
        const data = element || {};
        const kind = data.kind || 'item';
        // 占位符只在输出里（输入里放占位符没有意义）；其余种类输入/输出都能放
        const kinds = ELEMENT_KINDS.filter(function (item) {
            return side === 'output' || (item !== 'placeholder');
        });
        const kindOptions = kinds.map(function (item) {
            return '<option value="' + item + '"' + (item === kind ? ' selected' : '') + '>' +
                escapeHtml(t(item)) + '</option>';
        }).join('');

        const parts = [];
        // 材料 / 产物图标：由本行的「种类 + 名称」决定，名称一改就重画（见 refreshElementIcons）
        parts.push('<span class="element-icon" data-element-icon></span>');
        parts.push('<span data-when="item fluid filter"><span class="muted">' + escapeHtml(t('name')) +
            '</span> <span class="id-slot">' + elementIdControl(kind, data.id) + '</span></span>');
        parts.push('<span data-when="item fluid filter" class="muted">' + escapeHtml(t('nbtHash')) +
            ' <input type="text" class="e-nbt" value="' + escapeHtml(data.nbt || '') + '" style="width:120px" placeholder="' +
            escapeHtml(t('nbtAny')) + '"></span>');
        parts.push('<label data-when="item fluid filter" class="muted">' + escapeHtml(t('ignoreNbt')) +
            ' <input type="checkbox" class="e-ignore-nbt"' + (data.ignoreNbt === false ? '' : ' checked') + '></label>');
        if (side === 'input') {
            parts.push(numberField('item fluid filter', t('amount'), 'e-count', data.count === undefined ? 1 : data.count, 70));
            parts.push(numberField('item fluid filter', t('containerIndex'), 'e-container',
                (data.containerIndex === undefined || data.containerIndex === -1) ? '' : data.containerIndex, 60));
            // 用户第 2 项：**流体从不指定槽位** —— 「槽位序号」只对物品元素显示
            // （输出侧的流体抽取也从不指定槽位，见 modules/recipe.lua）。
            parts.push(numberField('item', t('slot'), 'e-slot',
                (data.slot === undefined || data.slot === -1) ? '' : data.slot, 60));
        } else {
            parts.push(numberField('item fluid filter', t('min'), 'e-min', data.min || 0, 60));
            parts.push(numberField('item fluid filter', t('max'), 'e-max', data.max || 1, 60));
            parts.push(numberField('item fluid filter', t('priority'), 'e-priority', data.priority || 0, 60));
            parts.push(textField('placeholder', t('placeholder'), 'e-pname', data.name, 120));
            parts.push(textField('placeholder', t('item'), 'e-pitem', data.item, 140));
        }
        parts.push(numberField('waitSignal emitSignal emitPulse', t('machineSignalIndex'), 'e-msignal',
            (data.machineSignalIndex === undefined || data.machineSignalIndex === null) ? 1 : data.machineSignalIndex, 60));
        parts.push('<span data-when="waitSignal emitSignal emitPulse" class="muted">' + escapeHtml(t('sides')) + '<br>' +
            sideCheckboxes(data.sides) + '</span>');
        // 比较 / 阈值 只对“等待红石信号”有意义，设置红石信号与发出红石脉冲只用“强度”
        parts.push('<span data-when="waitSignal" class="muted">' + escapeHtml(t('op')) + ' ' +
            selectForClass('e-op', OP_VALUES, data.op || 'ge', OP_LABELS) + '</span>');
        parts.push(numberField('waitSignal', t('threshold'), 'e-threshold', data.threshold || 0, 60));
        parts.push(numberField('emitSignal emitPulse', t('strength'), 'e-strength', data.strength === undefined ? 15 : data.strength, 60));
        parts.push('<span data-when="waitSignal emitSignal emitPulse" class="muted">' + escapeHtml(t('signalHint')) + '</span>');
        parts.push(numberField('waitTime', t('seconds'), 'e-seconds', data.seconds === undefined ? 1 : data.seconds, 70, 0.1));

        return '<div class="element-row" data-side="' + side + '">' +
            '<select class="e-kind" onchange="window.ifmElementKindChanged(this)">' + kindOptions + '</select>' +
            parts.join('') +
            '<button class="btn-pixel danger" type="button" onclick="window.ifmRemoveElement(this)"><i class="fa fa-times"></i></button>' +
            '</div>';
    }

    window.ifmElementKindChanged = function (select) {
        const row = select.closest('.element-row');
        if (!row) return;
        const kind = select.value;
        Array.prototype.forEach.call(row.querySelectorAll('[data-when]'), function (node) {
            const allowed = node.getAttribute('data-when').split(' ');
            node.style.display = allowed.indexOf(kind) >= 0 ? '' : 'none';
        });
        const idSlot = row.querySelector('.id-slot');
        if (idSlot) {
            const control = idSlot.querySelector('input, select');
            idSlot.innerHTML = elementIdControl(kind, control ? control.value : '');
        }
        refreshElementIcons();
    };

    // ===================== 元素行的材料 / 产物图标 =====================
    // 图标元信息（blocksitems.com）是异步拉的：还没拉到就先显示字形，稍后自动补一次
    let elementIconTimer = null;
    const ELEMENT_ICON_EMPTY = '<i class="fa fa-question"></i>';

    function refreshElementIcons() {
        const body = el('editorBody');
        if (!body) return;
        let pending = false;
        Array.prototype.forEach.call(body.querySelectorAll('.element-row'), function (row) {
            const holder = row.querySelector('[data-element-icon]');
            if (!holder) return;
            const kindSelect = row.querySelector('.e-kind');
            const kind = kindSelect ? kindSelect.value : 'item';
            const idNode = row.querySelector('.e-id');
            const id = idNode ? String(idNode.value || '').trim() : '';
            if (elementIsAbstract({ kind: kind, id: id })) {
                // 抽象操作（注册名 = abstract）：不是真实资源，显示一个字形即可（也不去查图标接口）
                holder.innerHTML = '<i class="fa ' + iconGlyphClass('abstract') + '"></i>';
                holder.setAttribute('title', t('abstractHint'));
                return;
            }
            if (kind === 'placeholder') {
                holder.innerHTML = '<i class="fa ' + iconGlyphClass(kind) + '"></i>';
                holder.setAttribute('title', t('placeholderKind'));
                return;
            }
            if ((kind !== 'item' && kind !== 'fluid') || !id) {
                holder.innerHTML = ELEMENT_ICON_EMPTY;
                holder.removeAttribute('title');
                return;
            }
            const realKind = kind === 'fluid' ? 'fluid' : 'item';
            queueMeta(realKind, id);
            // 元素行的「NBT 哈希」也一起交给图标层：能对上就挑 NBT 最接近的导出变体，
            // 对不上（CC:T 只给哈希、导出侧是 components 表）就用同一个注册名的图标
            const nbtNode = row.querySelector('.e-nbt');
            holder.innerHTML = plainIconImg(realKind, id, nbtNode ? String(nbtNode.value || '').trim() : '');
            holder.setAttribute('title', displayName(kind, id));
            if (metaState(resourceKey(realKind, id)) === 'unknown') pending = true;
        });
        if (pending && !elementIconTimer) {
            elementIconTimer = setTimeout(function () {
                elementIconTimer = null;
                refreshElementIcons();
            }, 1200);
        }
    }

    // 用户第 3 项：一键清掉所有"注册名 = abstract"的物品/流体操作（输入与输出一起清）。
    // 抽象操作只是"以后要换成真实材料/产物"的占位步骤（见 ifm-core.js 的 elementIsAbstract）。
    window.ifmClearAbstractOps = function () {
        let removed = 0;
        Array.prototype.forEach.call(document.querySelectorAll('#editorBody .element-row'), function (row) {
            const kindSelect = row.querySelector('.e-kind');
            const kind = kindSelect ? kindSelect.value : '';
            if (kind !== 'item' && kind !== 'fluid') return;
            const idNode = row.querySelector('.e-id');
            const id = idNode ? String(idNode.value || '').trim() : '';
            if (id.toLowerCase() !== IFM_ABSTRACT_ID) return;
            if (row.parentNode) row.parentNode.removeChild(row);
            removed += 1;
        });
        if (removed > 0) {
            refreshElementIcons();
            toast(t('clearAbstractOpsDone', { n: removed }), 'success');
            return;
        }
        toast(t('clearAbstractOpsNone'), 'info');
    };

    window.ifmRemoveElement = function (button) {
        const row = button.closest('.element-row');
        if (row) row.remove();
    };

    window.ifmAddElement = function (side) {
        // 注意：这里不能叫 inputList / outputList —— 页面里「外设与定义」板块的输入容器卡片
        // 也叫 #inputList，而它在 DOM 里排在编辑弹窗前面，`el('inputList')` 会先拿到它，
        // 新加的材料行就被塞进那个隐藏板块（看起来“加不了材料”，只有产物能加）。见 elementRowListId。
        const list = el(elementRowListId(side));
        if (!list) return;
        const holder = document.createElement('div');
        holder.innerHTML = elementRowHtml(side, { kind: 'item' });
        const row = holder.firstChild;
        list.appendChild(row);
        const kindSelect = row.querySelector('.e-kind');
        if (kindSelect) window.ifmElementKindChanged(kindSelect);
    };

    function applyElementVisibility() {
        Array.prototype.forEach.call(document.querySelectorAll('#editorBody .element-row'), function (row) {
            const kindSelect = row.querySelector('.e-kind');
            if (kindSelect) window.ifmElementKindChanged(kindSelect);
        });
    }

    function elementRowValue(row, selector) {
        const node = row.querySelector(selector);
        return node ? String(node.value).trim() : '';
    }

    function elementRowNumber(row, selector, fallback) {
        const node = row.querySelector(selector);
        if (!node) return fallback;
        const raw = String(node.value).trim();
        // 留空 = 使用缺省值（容器序号/槽位缺省为 -1：任意容器/任意空槽）
        if (raw === '') return fallback;
        const value = Number(raw);
        return isFinite(value) ? value : fallback;
    }

    // 是否忽略 NBT：未勾选时要求 NBT 相等（同时无 NBT 或哈希相同）
    function elementRowIgnoreNbt(row) {
        const box = row.querySelector('.e-ignore-nbt');
        return box ? !!box.checked : true;
    }

    function collectElements(side) {
        const out = [];
        Array.prototype.forEach.call(document.querySelectorAll('#editorBody .element-row[data-side="' + side + '"]'), function (row) {
            const kindSelect = row.querySelector('.e-kind');
            if (!kindSelect) return;
            const kind = kindSelect.value;
            if (kind === 'item' || kind === 'fluid' || kind === 'filter') {
                const entry = {
                    kind: kind,
                    id: elementRowValue(row, '.e-id'),
                    nbt: elementRowValue(row, '.e-nbt'),
                    ignoreNbt: elementRowIgnoreNbt(row),
                    containerIndex: elementRowNumber(row, '.e-container', -1),
                    // 用户第 2 项：流体从不指定槽位（这一栏只对物品元素存在）——
                    // 其它种类一律记成 -1 = 未指定，老配置里残留的槽位也在这里被丢掉。
                    slot: kind === 'item' ? elementRowNumber(row, '.e-slot', -1) : -1
                };
                if (!entry.id) return;
                if (side === 'input') {
                    entry.count = elementRowNumber(row, '.e-count', 0);
                } else {
                    entry.min = elementRowNumber(row, '.e-min', 0);
                    entry.max = elementRowNumber(row, '.e-max', 1);
                    entry.priority = elementRowNumber(row, '.e-priority', 0);
                }
                out.push(entry);
            } else if (kind === 'placeholder') {
                const placeholderName = elementRowValue(row, '.e-pname');
                const placeholderItem = elementRowValue(row, '.e-pitem');
                if (!placeholderName || !placeholderItem) return;
                out.push({ kind: kind, name: placeholderName, item: placeholderItem });
            } else if (kind === 'waitSignal' || kind === 'emitSignal' || kind === 'emitPulse') {
                const sides = [];
                Array.prototype.forEach.call(row.querySelectorAll('.e-side'), function (box) {
                    if (box.checked) sides.push(box.value);
                });
                out.push({
                    kind: kind,
                    machineSignalIndex: elementRowNumber(row, '.e-msignal', 1),
                    sides: sides,
                    threshold: elementRowNumber(row, '.e-threshold', 0),
                    op: elementRowValue(row, '.e-op') || 'ge',
                    strength: elementRowNumber(row, '.e-strength', 15)
                });
            } else if (kind === 'waitTime') {
                out.push({ kind: kind, seconds: Math.max(0, elementRowNumber(row, '.e-seconds', 1)) });
            }
        });
        return out;
    }

    // 复制来源下拉框的选项：同机器类型的流程（模板排最前，见 processCopyCandidates）
    function processCopyOptionsHtml(machineType, selected) {
        const candidates = processCopyCandidates(machineType);
        if (candidates.length === 0) {
            return '<option value="">' + escapeHtml(t('copyProcessOnlyOne')) + '</option>';
        }
        return '<option value="">—</option>' + candidates.map(function (process) {
            return '<option value="' + escapeHtml(process.name) + '"' +
                (String(process.name) === String(selected) ? ' selected' : '') + '>' +
                escapeHtml(processCopyLabel(process)) + '</option>';
        }).join('');
    }

    // 机器类型一改，可复制的来源也变了：只重画那个下拉框（其它表单控件不受影响）
    window.ifmProcessMachineTypeChanged = function (select) {
        refreshProcessCopyOptions();
    };

    function refreshProcessCopyOptions() {
        const copySelect = el('fldCopyFrom');
        if (!copySelect) return;
        const previous = copySelect.value;
        copySelect.innerHTML = processCopyOptionsHtml(readValue('fldMachineType'), previous);
        if (previous && processCopyCandidates(readValue('fldMachineType')).some(function (process) {
            return process.name === previous;
        })) {
            copySelect.value = previous;
        }
    }

    // 「复制」按钮：把来源流程的输入/输出元素与最大翻倍数拷进当前编辑的流程（机器类型保持不变）
    window.ifmProcessCopySettings = function () {
        const copySelect = el('fldCopyFrom');
        const sourceName = copySelect ? String(copySelect.value || '') : '';
        if (!sourceName) {
            toast(t('copyProcessNothing'), 'error');
            return;
        }
        const source = stores.processes.get(sourceName);
        if (!source) return;
        const machineType = readValue('fldMachineType');
        if (String(source.machineType || '') !== machineType) {
            // 服务端按机器类型决定容器与信号，跨类型复制出来的流程根本跑不起来，所以这里直接拒绝
            toast(t('copyProcessOtherType'), 'error');
            return;
        }
        const maxField = el('fldMaxMultiplier');
        if (maxField) maxField.value = Math.max(1, Math.floor(Number(source.maxMultiplier) || 1));
        const inputList = el(elementRowListId('input'));
        const outputList = el(elementRowListId('output'));
        if (inputList) {
            inputList.innerHTML = asArray(source.inputs).map(function (item) {
                return elementRowHtml('input', deepClone(item));
            }).join('');
        }
        if (outputList) {
            outputList.innerHTML = asArray(source.outputs).map(function (item) {
                return elementRowHtml('output', deepClone(item));
            }).join('');
        }
        applyElementVisibility();
        refreshElementIcons();
        toast(t('copyProcessDone', { name: sourceName }), 'success');
    };

    // 流程没有“名称”字段：保存时按首个产物自动命名（见 autoDefinitionName）
    function buildProcessEditor(data, name) {
        const inputs = asArray(data.inputs);
        const outputs = asArray(data.outputs);
        const suggestions = suggestionValues().map(function (value) {
            return '<option value="' + escapeHtml(value) + '"></option>';
        }).join('');
        // 复制来源：只列同一机器类型的流程；抽象流程排在最前（见 processCopyCandidates）
        const copyRow = fieldRow(t('copyProcessFrom'),
            '<span style="display:inline-flex;gap:6px;align-items:center;flex-wrap:wrap">' +
            '<select id="fldCopyFrom" style="min-width:200px">' +
            processCopyOptionsHtml(data.machineType, null) + '</select>' +
            '<button class="btn-pixel" type="button" onclick="window.ifmProcessCopySettings()">' +
            '<i class="fa fa-clone"></i> ' + escapeHtml(t('copyProcessApply')) + '</button></span>') +
            '<div class="muted" style="margin:-4px 0 6px 0">' + escapeHtml(t('copyProcessHint')) + '</div>';
        // 用户第 3 项：一键清除所有 abstract 操作（输入与输出里的物品/流体注册名 = abstract）
        const abstractRow = fieldRow(t('abstractOp'),
            '<span style="display:inline-flex;gap:6px;align-items:center;flex-wrap:wrap">' +
            '<button class="btn-pixel danger" type="button" onclick="window.ifmClearAbstractOps()">' +
            '<i class="fa fa-eraser"></i> ' + escapeHtml(t('clearAbstractOps')) + '</button>' +
            '<span class="muted">' + escapeHtml(t('clearAbstractOpsHint')) + '</span></span>');
        return fieldRow(t('machineTypeField'), selectHtml('fldMachineType', machineTypeOptions(), data.machineType, true,
                'onchange="window.ifmProcessMachineTypeChanged(this)"')) +
            copyRow +
            abstractRow +
            fieldRow(t('maxMultiplier'), numberInput('fldMaxMultiplier', data.maxMultiplier || 1, 1, 1)) +
            '<datalist id="ifmSuggestions">' + suggestions + '</datalist>' +
            '<div class="editor-block"><h4>' + escapeHtml(t('inputs')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddElement(\'input\')"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="' + elementRowListId('input') + '">' + inputs.map(function (item) { return elementRowHtml('input', item); }).join('') + '</div>' +
            '<div class="muted">' + escapeHtml('流程名会按首个产物自动生成；材料名可手输，也可从“从库存选择…”下拉里挑选；' +
                '容器序号/槽位留空等同 -1（任意容器 / 任意空槽）；输入为空表示流程只输出产物。') + '</div>' +
            '<div class="muted">' + escapeHtml(t('abstractHint')) + '</div>' +
            '</div>' +
            '<div class="editor-block"><h4>' + escapeHtml(t('outputs')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddElement(\'output\')"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="' + elementRowListId('output') + '">' + outputs.map(function (item) { return elementRowHtml('output', item); }).join('') + '</div>' +
            '<div class="muted">' + escapeHtml('抽取按“最多数目”进行，达到“最少数目”即视为该产物完成；优先级越大越先被选作上游。') + '</div>' +
            '</div>';
    }


    
