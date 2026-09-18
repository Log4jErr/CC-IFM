// IFM :: web/ifm-editor.js
// 编辑器（表单 / 各类定义 / 流程元素）
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 模态框基础设施 =====================
    let editorInstance = null;
    let promptInstance = null;
    let diagnoseInstance = null;
    let editorState = { kind: null, name: null, data: {} };
    let promptState = null;

    function editorModalInstance() {
        if (!editorInstance) editorInstance = new bootstrap.Modal(el('editorModal'));
        return editorInstance;
    }

    function promptModalInstance() {
        if (!promptInstance) promptInstance = new bootstrap.Modal(el('promptModal'));
        return promptInstance;
    }

    function diagnoseModalInstance() {
        if (!diagnoseInstance) diagnoseInstance = new bootstrap.Modal(el('diagnoseModal'));
        return diagnoseInstance;
    }

    // ===================== 数量表达式（网页端求解） =====================
    // 待发送数量 / 合成数量 / 批次数等输入框里可以直接写算式，点确定时在网页端求出结果：
    //   2*64+32   ·   (128+64)/2   ·   3*9-4   ·   100/4
    // 只接受数字与 + - * / % ( )，不用 eval（安全、跨浏览器行为一致）。
    function evalExpression(text) {
        const source = String(text === undefined || text === null ? '' : text).replace(/\s+/g, '');
        if (source === '') return null;
        let index = 0;
        let bad = false;

        function peek() {
            return source.charAt(index);
        }

        function parseNumber() {
            const start = index;
            while (index < source.length && /[0-9.]/.test(source.charAt(index))) index += 1;
            if (start === index) {
                bad = true;
                return 0;
            }
            const value = Number(source.slice(start, index));
            if (!isFinite(value)) bad = true;
            return value;
        }

        function parseFactor() {
            const char = peek();
            if (char === '+') {
                index += 1;
                return parseFactor();
            }
            if (char === '-') {
                index += 1;
                return -parseFactor();
            }
            if (char === '(') {
                index += 1;
                const value = parseSum();
                if (peek() === ')') {
                    index += 1;
                } else {
                    bad = true;
                }
                return value;
            }
            return parseNumber();
        }

        function parseProduct() {
            let value = parseFactor();
            while (!bad) {
                const char = peek();
                if (char !== '*' && char !== '/' && char !== '%') break;
                index += 1;
                const right = parseFactor();
                if ((char === '/' || char === '%') && right === 0) {
                    bad = true;
                    return 0;
                }
                if (char === '*') value = value * right;
                else if (char === '/') value = value / right;
                else value = value % right;
            }
            return value;
        }

        function parseSum() {
            let value = parseProduct();
            while (!bad) {
                const char = peek();
                if (char !== '+' && char !== '-') break;
                index += 1;
                const right = parseProduct();
                value = (char === '+') ? value + right : value - right;
            }
            return value;
        }

        const result = parseSum();
        if (bad || index !== source.length || !isFinite(result)) return null;
        return result;
    }

    function isPlainNumber(text) {
        return /^[0-9]+(\.[0-9]+)?$/.test(text);
    }

    // 数量框下方的实时提示：普通数字时提示“支持四则运算”，写了算式就显示求解结果
    function updatePromptPreview() {
        const node = el('promptPreview');
        const input = el('promptInput');
        if (!node || !input) return;
        const raw = String(input.value || '').trim();
        if (raw === '' || isPlainNumber(raw)) {
            node.textContent = t('exprHint');
            node.style.color = 'var(--text-dim)';
            return;
        }
        const value = evalExpression(raw);
        if (value === null) {
            node.textContent = t('exprInvalid', { text: raw });
            node.style.color = 'var(--bad)';
            return;
        }
        node.textContent = t('exprEquals', { value: fmtCount(value) });
        node.style.color = 'var(--good)';
    }

    function openPrompt(options) {
        promptState = options;
        el('promptTitle').textContent = options.title || '';
        el('promptLabel').textContent = options.label || '';
        const input = el('promptInput');
        input.value = (options.value === undefined || options.value === null) ? 1 : options.value;
        input.style.display = options.selectOptions ? 'none' : '';
        updatePromptPreview();
        const select = el('promptSelect');
        if (options.selectOptions) {
            select.style.display = 'block';
            select.innerHTML = options.selectOptions.map(function (option) {
                return '<option value="' + escapeHtml(option.value) + '">' + escapeHtml(option.label) + '</option>';
            }).join('');
            if (options.selectValue) select.value = options.selectValue;
        } else {
            select.style.display = 'none';
            select.innerHTML = '';
        }
        el('promptHint').textContent = options.hint || '';
        const instance = promptModalInstance();
        if (!options.selectOptions) {
            // 弹窗真正显示后再聚焦并把内容全选：这样“合成物品”的数量可以直接键入覆盖
            el('promptModal').addEventListener('shown.bs.modal', function () {
                input.focus();
                if (typeof input.select === 'function') input.select();
            }, { once: true });
        }
        instance.show();
    }

    function confirmPrompt() {
        if (!promptState) return;
        const options = promptState;
        const raw = String(el('promptInput').value || '').trim();
        // 空输入按 0 处理（与旧行为一致）；否则按表达式求值，非法表达式保持弹窗打开让用户改
        const value = raw === '' ? 0 : evalExpression(raw);
        if (value === null) {
            toast(t('exprInvalid', { text: raw }), 'error');
            updatePromptPreview();
            const input = el('promptInput');
            if (input) input.focus();
            return;
        }
        promptState = null;
        const selectValue = el('promptSelect').value;
        promptModalInstance().hide();
        if (typeof options.onConfirm === 'function') {
            options.onConfirm(value, selectValue);
        }
    }

    // ===================== 表单控件 =====================
    function fieldRow(label, control) {
        return '<div class="editor-row"><label>' + escapeHtml(label) + '</label><div>' + control + '</div></div>';
    }

    function textInput(id, value, placeholder) {
        return '<input type="text" id="' + id + '" value="' + escapeHtml(value || '') + '" placeholder="' +
            escapeHtml(placeholder || '') + '" style="width:100%">';
    }

    function numberInput(id, value, min, step) {
        const safe = (value === undefined || value === null) ? 0 : value;
        return '<input type="number" id="' + id + '" value="' + escapeHtml(safe) + '" min="' +
            (min === undefined ? 0 : min) + '" step="' + (step || 1) + '">';
    }

    function selectHtml(id, options, value, allowEmpty, attrs) {
        let html = '<select id="' + id + '"' + (attrs ? ' ' + attrs : '') + ' style="width:100%">';
        if (allowEmpty) html += '<option value="">—</option>';
        options.forEach(function (option) {
            html += '<option value="' + escapeHtml(option.value) + '"' +
                (String(option.value) === String(value) ? ' selected' : '') + '>' +
                escapeHtml(option.label) + '</option>';
        });
        return html + '</select>';
    }

    // ===================== 有序多选（机器的输入/输出容器） =====================
    // 需求：容器既能多选，顺序也由用户决定（顺序就是机器列表里的选择次序）。
    // 原生 <select multiple> 既难多选、也没法调序，所以自己画一个：已选列表（↑ / ↓ / ×）+ 添加下拉。
    const pickerState = new Map();      // id -> 已选值数组（顺序即用户顺序）
    const pickerOptions = new Map();    // id -> [{ value, label }] 全部候选

    function orderedPickerHtml(id, options, values) {
        const chosen = asArray(values).map(String);
        pickerState.set(id, chosen);
        pickerOptions.set(id, options);
        return '<div class="ordered-picker" data-picker="' + id + '">' +
            '<div class="picker-chosen" id="' + id + 'Chosen"></div>' +
            '<div class="picker-add">' +
            '<select id="' + id + 'Add"></select>' +
            '<button class="btn-pixel" type="button" onclick="window.ifmPickerAdd(\'' + id + '\')">' +
            '<i class="fa fa-plus"></i> ' + escapeHtml(t('add')) + '</button>' +
            '</div>' +
            '</div>';
    }

    function pickerLabelOf(id, value) {
        const options = pickerOptions.get(id) || [];
        for (let index = 0; index < options.length; index += 1) {
            if (String(options[index].value) === String(value)) return options[index].label;
        }
        return value;
    }

    function pickerAddOptionHtml(id, chosen) {
        const options = pickerOptions.get(id) || [];
        return '<option value="">' + escapeHtml(t('pickerAddHint')) + '</option>' + options.filter(function (item) {
            return chosen.indexOf(String(item.value)) < 0;
        }).map(function (item) {
            return '<option value="' + escapeHtml(item.value) + '">' + escapeHtml(item.label) + '</option>';
        }).join('');
    }

    // 只重画某一个选择器（其它表单控件的内容不受影响）
    function renderOrderedPicker(id) {
        const chosen = pickerState.get(id) || [];
        const holder = el(id + 'Chosen');
        if (holder) {
            holder.innerHTML = chosen.length
                ? chosen.map(function (value, index) {
                    return '<div class="picker-item">' +
                        '<span class="picker-index">' + (index + 1) + '</span>' +
                        '<span class="picker-name" title="' + escapeHtml(String(value)) + '">' +
                        escapeHtml(pickerLabelOf(id, value)) + '</span>' +
                        '<button class="btn-pixel" type="button" title="' + escapeHtml(t('moveUp')) +
                        '" onclick="window.ifmPickerMove(\'' + id + '\',' + index + ',-1)">' +
                        '<i class="fa fa-arrow-up"></i></button>' +
                        '<button class="btn-pixel" type="button" title="' + escapeHtml(t('moveDown')) +
                        '" onclick="window.ifmPickerMove(\'' + id + '\',' + index + ',1)">' +
                        '<i class="fa fa-arrow-down"></i></button>' +
                        '<button class="btn-pixel danger" type="button" title="' + escapeHtml(t('pickerRemove')) +
                        '" onclick="window.ifmPickerRemove(\'' + id + '\',' + index + ')">' +
                        '<i class="fa fa-times"></i></button>' +
                        '</div>';
                }).join('')
                : '<div class="muted">' + escapeHtml(t('pickerEmpty')) + '</div>';
        }
        const add = el(id + 'Add');
        if (add) add.innerHTML = pickerAddOptionHtml(id, chosen);
    }

    function initPickers() {
        Array.prototype.forEach.call(document.querySelectorAll('#editorBody [data-picker]'), function (node) {
            renderOrderedPicker(node.getAttribute('data-picker'));
        });
        // 文本输入框的候选列表（物品/流体/过滤器/标签…）：见 attachAutocomplete
        Array.prototype.forEach.call(
            document.querySelectorAll('#editorBody input[list="ifmSuggestions"], #editorBody input.rule-value,' +
                ' #editorBody #toolResource'),
            function (input) { attachAutocomplete(input); }
        );
    }

    // ===================== 输入候选（自动补全，1.6.10）=====================
    // 需求（用户第 16 项）：输入物品 / 流体 / 过滤器 / 标签…时，根据**已有的资源**给出候选，
    // 候选以列表形式排在输入框**上方或下方**（取决于输入框在屏幕中的位置），并且支持：
    //   ↑ / ↓ 选择候选项 · Tab 用候选补全输入框 · Enter 采用候选项 · Esc 关闭 · 鼠标点击采用
    // 原生 <datalist> 做不到“列表随位置上下翻转 + Tab 补全 + 自定义样式”，所以这里自己画一个浮层。
    const AC_LIMIT = 12;
    let acPanel = null;            // 当前打开的候选浮层（同一时刻只开一个）
    let acState = null;            // { input, items, index, panel }
    let acApplying = false;        // 正在把候选项写回输入框（此时不要再自动弹出候选）

    function closeAutocomplete() {
        if (acPanel && acPanel.parentNode) acPanel.parentNode.removeChild(acPanel);
        acPanel = null;
        acState = null;
    }

    // 候选池：资源名（物品/流体）+ 过滤器名 + 常见标签 + 资源上已经出现过的 #标签
    function acCandidates(query) {
        const text = String(query || '').trim().toLowerCase();
        const pool = suggestionValues();
        Array.from(stores.resources.values()).forEach(function (entry) {
            asArray(entry.tags).forEach(function (tag) { pool.push('#' + String(tag)); });
        });
        const seen = {};
        const out = [];
        pool.forEach(function (value) {
            const candidate = String(value || '');
            if (!candidate || seen[candidate]) return;
            seen[candidate] = true;
            if (text && candidate.toLowerCase().indexOf(text) < 0) return;
            out.push(candidate);
        });
        return out.slice(0, AC_LIMIT);
    }

    function renderAcPanel() {
        if (!acState) return;
        acState.panel.innerHTML = acState.items.map(function (value, index) {
            return '<div class="ifm-ac-item' + (index === acState.index ? ' active' : '') +
                '" data-ac-index="' + index + '">' + escapeHtml(value) + '</div>';
        }).join('');
        const active = acState.panel.querySelector('.ifm-ac-item.active');
        if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
    }

    function applyAcIndex(index) {
        if (!acState) return;
        const value = acState.items[index];
        if (value === undefined) return;
        const input = acState.input;
        closeAutocomplete();
        input.value = value;
        // 通知其它监听器（例如工具输入框的变更处理）：期间不要再次弹出候选（否则列表会“补全后又弹回来”）
        acApplying = true;
        input.dispatchEvent(new window.Event('input', { bubbles: true }));
        acApplying = false;
    }

    function openAutocomplete(input, index) {
        const items = acCandidates(input.value);
        if (items.length === 0) {
            closeAutocomplete();
            return;
        }
        if (!acPanel || !acState || acState.input !== input) {
            closeAutocomplete();
            const panel = document.createElement('div');
            panel.className = 'ifm-ac';
            document.body.appendChild(panel);
            acPanel = panel;
            acState = { input: input, items: items, index: 0, panel: panel };
            // 鼠标点候选项：直接采用
            panel.addEventListener('mousedown', function (event) {
                const node = event.target.closest('[data-ac-index]');
                if (!node || !acState) return;
                event.preventDefault();
                applyAcIndex(Number(node.getAttribute('data-ac-index')));
            });
        }
        acState.items = items;
        if (typeof index === 'number') {
            acState.index = Math.max(0, Math.min(items.length - 1, index));
        } else if (acState.index >= items.length) {
            acState.index = 0;
        }
        // 位置：默认贴在输入框下面；下面放不下（离屏幕底部太近）就翻到上面
        const rect = input.getBoundingClientRect();
        acState.panel.style.width = Math.max(140, Math.round(rect.width)) + 'px';
        renderAcPanel();
        const height = acState.panel.offsetHeight || 180;
        const below = rect.bottom + 4;
        const flip = below + height > window.innerHeight - 8 && rect.top - height - 4 > 0;
        acState.panel.style.left = Math.round(rect.left) + 'px';
        acState.panel.style.top = Math.round(flip ? rect.top - height - 4 : below) + 'px';
    }

    function attachAutocomplete(input) {
        if (!input || input.getAttribute('data-ac-ready') === '1') return;
        input.setAttribute('data-ac-ready', '1');
        input.setAttribute('autocomplete', 'off');
        input.addEventListener('input', function () {
            if (acApplying) return;
            openAutocomplete(input);
        });
        input.addEventListener('focus', function () {
            if (acApplying) return;
            openAutocomplete(input);
        });
        input.addEventListener('blur', function () { closeAutocomplete(); });
        input.addEventListener('keydown', function (event) {
            const key = event.key;
            if (key === 'ArrowDown' || key === 'ArrowUp') {
                // ↑/↓：打开候选（还没打开时）或上下移动选择
                if (!acState || acState.input !== input) {
                    openAutocomplete(input, 0);
                } else {
                    openAutocomplete(input, acState.index + (key === 'ArrowDown' ? 1 : -1));
                }
                event.preventDefault();
                event.stopPropagation();
                return;
            }
            if (!acState || acState.input !== input) {
                if (key === 'Escape') closeAutocomplete();
                return;
            }
            if (key === 'Tab' || key === 'Enter') {
                // Tab / Enter：用当前选中的候选项补全输入框
                applyAcIndex(acState.index);
                event.preventDefault();
                event.stopPropagation();      // 别再触发编辑器的“回车即保存”
                return;
            }
            if (key === 'Escape') {
                closeAutocomplete();
                event.stopPropagation();
            }
        });
    }

    window.ifmPickerAdd = function (id) {
        const add = el(id + 'Add');
        const value = add ? String(add.value) : '';
        if (!value) return;
        const chosen = pickerState.get(id) || [];
        if (chosen.indexOf(value) < 0) chosen.push(value);
        pickerState.set(id, chosen);
        renderOrderedPicker(id);
    };

    window.ifmPickerMove = function (id, index, delta) {
        const chosen = pickerState.get(id) || [];
        const target = index + delta;
        if (index < 0 || index >= chosen.length || target < 0 || target >= chosen.length) return;
        const value = chosen[index];
        chosen[index] = chosen[target];
        chosen[target] = value;
        pickerState.set(id, chosen);
        renderOrderedPicker(id);
    };

    window.ifmPickerRemove = function (id, index) {
        const chosen = pickerState.get(id) || [];
        if (index < 0 || index >= chosen.length) return;
        chosen.splice(index, 1);
        pickerState.set(id, chosen);
        renderOrderedPicker(id);
    };

    function readValue(id) {
        const node = el(id);
        return node ? node.value.trim() : '';
    }

    function readNumber(id, fallback) {
        const node = el(id);
        if (!node) return fallback;
        const value = Number(node.value);
        return isFinite(value) ? value : fallback;
    }

    function readMulti(id) {
        // 机器编辑器用的是“有序多选”（见 orderedPickerHtml）：值存在 pickerState 里
        if (pickerState.has(id)) return pickerState.get(id).slice();
        const node = el(id);
        if (!node) return [];
        return Array.prototype.slice.call(node.selectedOptions || []).map(function (option) { return option.value; });
    }

    // ===================== 编辑器：通用 =====================
    const KIND_LABEL_KEY = {
        containers: 'container', signals: 'signal', filters: 'filter',
        machineTypes: 'machineType', machines: 'machine', processes: 'processes'
    };
    const SAVE_ACTION = {
        containers: 'set_container', signals: 'set_signal', filters: 'set_filter',
        machineTypes: 'set_machine_type', machines: 'set_machine', processes: 'set_process'
    };
    const DELETE_ACTION = {
        containers: 'delete_container', signals: 'delete_signal', filters: 'delete_filter',
        machineTypes: 'delete_machine_type', machines: 'delete_machine', processes: 'delete_process'
    };
    const ROLE_VALUES = ['storage', 'input', 'interaction', 'output'];
    const SIDE_VALUES = ['top', 'bottom', 'left', 'right', 'front', 'back'];
    const OP_VALUES = ['gt', 'ge', 'eq', 'le', 'lt'];
    // 比较符号直接显示数学符号（gt/ge/eq/le/lt 对用户没有意义）
    const OP_LABELS = { gt: '>', ge: '≥', eq: '=', le: '≤', lt: '<' };
    const ELEMENT_KINDS = ['item', 'fluid', 'filter', 'placeholder', 'virtual', 'waitSignal', 'emitSignal', 'emitPulse', 'waitTime'];
    const RULE_TYPES = [
        'item_include', 'item_exclude', 'fluid_include', 'fluid_exclude',
        'itemTag_include', 'itemTag_exclude', 'fluidTag_include', 'fluidTag_exclude',
        'filter_include', 'filter_exclude'
    ];

    function kindLabel(kind) {
        return t(KIND_LABEL_KEY[kind] || kind);
    }

    function deepClone(value) {
        return JSON.parse(JSON.stringify(value === undefined ? {} : value));
    }

    function byName(list) {
        return list.slice().sort(function (a, b) { return a.name.localeCompare(b.name); });
    }

    function peripheralOptions(kinds) {
        return byName(Array.from(stores.peripherals.values()).filter(function (item) {
            return kinds.indexOf(item.kind) >= 0;
        })).map(function (item) {
            return { value: item.name, label: item.name + ' (' + item.kind + ')' };
        });
    }

    function containerOptions(role, kind) {
        return byName(Array.from(stores.containers.values()).filter(function (item) {
            const matchesRole = !role || item.role === role;
            const itemKind = item.kind === 'fluid' ? 'fluid' : 'item';
            const matchesKind = !kind || itemKind === kind;
            return matchesRole && matchesKind;
        })).map(function (item) {
            const kindLabel = item.kind === 'fluid' ? t('fluidKind') : t('itemKind');
            return { value: item.name, label: item.name + ' [' + roleLabel(item.role) + ' · ' + kindLabel + ']' };
        });
    }

    function signalOptions() {
        return byName(Array.from(stores.signals.values())).map(function (item) {
            return { value: item.name, label: item.name + ' (' + item.peripheral + ')' };
        });
    }

    function machineTypeOptions() {
        return byName(Array.from(stores.machineTypes.values())).map(function (item) {
            return { value: item.name, label: item.name };
        });
    }

    function filterOptions(excludeName) {
        return byName(Array.from(stores.filters.values()).filter(function (item) {
            return item.name !== excludeName;
        })).map(function (item) {
            return { value: item.name, label: item.name };
        });
    }

    function nameRow(name) {
        return fieldRow(t('name'), textInput('fldName', name || '', 'unique name'));
    }

    // ===== 容器定义：容器种类与外设名都不允许手动设置 =====
    // 外设（方块）当前提供的外设类型：inventory / fluid_storage / redstone_relay
    function peripheralKindsOf(name) {
        const kinds = [];
        Array.from(stores.peripherals.values()).forEach(function (item) {
            if (item.name === name && kinds.indexOf(item.kind) < 0) kinds.push(item.kind);
        });
        return kinds;
    }

    // 容器种类由外设实际提供的能力决定；两种都提供时沿用调用方给的种类（在外设卡片上点哪一行就是哪种）
    function containerKindOfPeripheral(peripheralName, fallback) {
        const kinds = peripheralKindsOf(peripheralName);
        const hasItem = kinds.indexOf('inventory') >= 0;
        const hasFluid = kinds.indexOf('fluid_storage') >= 0;
        if (hasItem && !hasFluid) return 'item';
        if (hasFluid && !hasItem) return 'fluid';
        return fallback === 'fluid' ? 'fluid' : 'item';
    }

    function containerKindLabel(peripheralName, kind) {
        const wanted = kind === 'fluid' ? 'fluid_storage' : 'inventory';
        const kinds = peripheralKindsOf(peripheralName);
        const base = kind === 'fluid' ? t('fluidContainer') : t('itemContainer');
        if (kinds.indexOf(wanted) < 0) return base;
        return base + '（' + kinds.join(' / ') + '）';
    }

    // 只读字段：用户能看到值，但不能手动改（浏览器禁用输入框仍然可以读取 value）
    function readOnlyRow(label, value, hint) {
        return '<div class="editor-row"><label>' + escapeHtml(label) + '</label><div>' +
            '<input type="text" value="' + escapeHtml(value) + '" readonly disabled>' +
            (hint ? ' <span class="muted">' + escapeHtml(hint) + '</span>' : '') +
            '</div></div>';
    }

    // 容器管理块（只看/只搬已经保存过的定义）：新建时只显示一行提示
    function containerToolBlock(name) {
        if (!name) {
            return '<div class="editor-block">' +
                '<h4><i class="fa fa-archive"></i> ' + escapeHtml(t('containerManage')) + '</h4>' +
                '<div class="muted">' + escapeHtml(t('containerToolUnsaved')) + '</div>' +
                '</div>';
        }
        return '<div class="editor-block">' +
            '<h4><i class="fa fa-archive"></i> ' + escapeHtml(t('containerManage')) + '</h4>' +
            '<div id="toolMeta"></div>' +
            '<div class="editor-block">' +
            '<h4><i class="fa fa-exchange"></i> ' + escapeHtml(t('containerMoveTitle')) + '</h4>' +
            '<div class="editor-row"><label>' + escapeHtml(t('resourceLabel')) + '</label>' +
            '<span class="search-wrap">' +
            '<input type="text" id="toolResource" placeholder="' + escapeHtml(t('item') + ' / ' + t('fluid')) +
            '" list="toolSuggestions" autocomplete="off">' +
            '<button class="btn-pixel search-clear" id="toolResourceClear" type="button" title="' +
            escapeHtml(t('searchClear')) + '" style="display:none"><i class="fa fa-times"></i></button>' +
            '</span></div>' +
            '<div class="editor-row"><label>' + escapeHtml(t('count')) + '</label>' +
            '<input type="number" id="toolCount" value="64" min="1"></div>' +
            '<datalist id="toolSuggestions"></datalist>' +
            '<div class="muted">' + escapeHtml(t('containerTakeHint')) + '</div>' +
            '<div style="margin-top:6px">' +
            '<button class="btn-pixel" id="toolRefreshBtn" type="button"><i class="fa fa-refresh"></i> ' +
            escapeHtml(t('refresh')) + '</button> ' +
            '<button class="btn-pixel primary" id="toolPutBtn" type="button"><i class="fa fa-arrow-down"></i> ' +
            escapeHtml(t('containerPut')) + '</button> ' +
            '<button class="btn-pixel" id="toolTakeBtn" type="button"><i class="fa fa-arrow-up"></i> ' +
            escapeHtml(t('containerTake')) + '</button>' +
            '</div></div>' +
            '<div class="editor-block">' +
            '<h4><i class="fa fa-list"></i> ' + escapeHtml(t('containerContents')) + '</h4>' +
            '<div id="toolContents"></div></div>' +
            '<span class="muted" id="toolHint"></span>' +
            '</div>';
    }

    function buildContainerEditor(data, name) {
        const peripheralName = data.peripheral || '';
        const kindValue = containerKindOfPeripheral(peripheralName, data.kind === 'fluid' ? 'fluid' : 'item');
        const roleValue = data.role || 'storage';
        const priorityValue = Number(data.priority || 0);
        // 角色用带 onchange 的下拉框：切换后决定要不要填名称（存储容器不需要名称）
        const roleSelect = '<select id="fldRole" style="width:100%" onchange="window.ifmContainerRoleChanged(this)">' +
            ROLE_VALUES.map(function (value) {
                return '<option value="' + escapeHtml(value) + '"' + (value === roleValue ? ' selected' : '') +
                    '>' + escapeHtml(roleLabel(value)) + '</option>';
            }).join('') + '</select>';
        // 存储优先级是可选的（可填负数：越小越先被取出）；用原生 input，免得被 min=0 限制住
        const priorityInput = '<input type="number" id="fldPriority" step="1" style="width:120px" value="' +
            escapeHtml(String(priorityValue)) + '">';
        const nameVisible = roleValue === 'output';
        return '<div id="containerNameRow"' + (nameVisible ? '' : ' style="display:none"') + '>' +
            nameRow(data.name || name) + '</div>' +
            readOnlyRow(t('peripheral'), peripheralName, t('peripheralLocked')) +
            readOnlyRow(t('containerKind'), containerKindLabel(peripheralName, kindValue), t('containerKindLocked')) +
            fieldRow(t('role'), roleSelect) +
            '<div id="containerNameHint" class="muted"' + (nameVisible ? ' style="display:none"' : '') + '>' +
            escapeHtml(t('storageNameAuto')) + '</div>' +
            fieldRow(t('containerPriority'), priorityInput) +
            '<div class="muted">' + escapeHtml(t('containerPriorityHint')) + '</div>' +
            containerToolBlock(name);
    }

    // 角色切换：只有输出容器需要名称；存储 / 交互容器都用外设名作定义名（服务端自动推导）
    window.ifmContainerRoleChanged = function (select) {
        const named = select.value === 'output';
        const row = el('containerNameRow');
        if (row) row.style.display = named ? '' : 'none';
        const hint = el('containerNameHint');
        if (hint) hint.style.display = named ? 'none' : '';
        if (named && !readValue('fldName')) {
            const field = el('fldName');
            if (field) field.focus();
        }
    };

    function buildSignalEditor(data, name) {
        // 红石信号不需要命名（1.6.9）：名称就是中继器外设名，同一个中继器可以给多台机器用。
        return fieldRow(t('peripheral'), selectHtml('fldPeripheral', peripheralOptions(['redstone_relay']), data.peripheral)) +
            '<div class="muted">' + escapeHtml(t('signalNameHint')) + '</div>';
    }

    function buildMachineTypeEditor(data, name) {
        return nameRow(name || data.name) +
            '<div class="muted">' + escapeHtml(t('machineType') + '：同类机器之间会轮流选取，轮换次序由服务端持久化记忆') + '</div>';
    }

    function buildEditor(kind, data, name) {
        if (kind === 'containers') return buildContainerEditor(data, name);
        if (kind === 'signals') return buildSignalEditor(data, name);
        if (kind === 'machineTypes') return buildMachineTypeEditor(data, name);
        if (kind === 'filters') return buildFilterEditor(data, name);
        if (kind === 'machines') return buildMachineEditor(data, name);
        if (kind === 'processes') return buildProcessEditor(data, name);
        return '';
    }

    function openEditor(kind, name, preset) {
        const store = stores[kind];
        if (!store) return;
        const data = preset ? deepClone(preset) : deepClone(name ? (store.get(name) || {}) : {});
        editorState = { kind: kind, name: name || null, data: data };
        if (kind === 'containers') {
            // 容器种类与外设名不允许手动设置：只读展示，保存/删除时也用这里的值
            const peripheralName = data.peripheral || '';
            editorState.locked = {
                peripheral: peripheralName,
                kind: containerKindOfPeripheral(peripheralName, data.kind === 'fluid' ? 'fluid' : 'item')
            };
        }
        el('editorTitle').textContent = name
            ? t('editorEdit', { kind: kindLabel(kind) })
            : t('editorNew', { kind: kindLabel(kind) });
        el('editorDeleteBtn').style.display = name ? '' : 'none';
        el('editorBody').innerHTML = buildEditor(kind, data, name);
        initPickers();
        applyElementVisibility();
        refreshElementIcons();
        // 容器定义：把「容器管理」（内容物 / 手动搬运）一起挂进这个弹窗
        if (kind === 'containers' && window.ifmContainerToolMount) {
            window.ifmContainerToolMount(name || null);
        }
        editorModalInstance().show();
    }

    // 新增/重命名定义时避免重名：已存在“木桶”就改为“木桶2”，已存在“木桶2”就改为“木桶3”……
    // （服务端 Store:set 以名称为键，同名会直接覆盖旧定义，所以保存前先取一个未被占用的名字）
    function uniqueDefinitionName(kind, requested, currentName) {
        const store = stores[kind];
        const base = String(requested || '').trim();
        if (!store || !base) return base;
        // 容器定义在数据里以“种类:名称”为键（物品容器与流体容器允许同名），其它定义直接用名称
        const lockedKind = (editorState.locked && editorState.locked.kind) === 'fluid' ? 'fluid' : 'item';
        const keyOfName = function (value) {
            return kind === 'containers' ? (lockedKind === 'fluid' ? 'fluid:' : 'item:') + value : value;
        };
        const currentKey = kind === 'containers'
            ? keyOfName(String(currentName || '').replace(/^(item|fluid):/, ''))
            : currentName;
        const taken = function (candidate) {
            return keyOfName(candidate) !== currentKey && store.has(keyOfName(candidate));
        };
        if (!taken(base)) return base;
        let index = 2;
        while (taken(base + index)) {
            index += 1;
        }
        return base + index;
    }

    // 机器 / 流程定义没有“名称”字段：按机器类型 / 首个产物自动推导（保存时再自动去重）
    function autoDefinitionName(kind) {
        if (kind === 'machines') {
            return readValue('fldType') || t('machine');
        }
        if (kind === 'processes') {
            const outputs = collectElements('output').filter(function (element) {
                return element.kind === 'item' || element.kind === 'fluid' || element.kind === 'filter';
            });
            if (outputs.length > 0 && outputs[0].id) {
                return String(outputs[0].id).split(':').pop();
            }
            return readValue('fldMachineType') || t('processes');
        }
        return '';
    }

    // 当前编辑的容器需不需要名称：**只有输出容器需要**（机器按名字引用它、发送也要选它）；
    // 存储 / 交互容器都用外设名作定义名，不显示也不接受名称输入
    function isNamedContainerRole() {
        const role = readValue('fldRole') || (editorState.data && editorState.data.role) || 'storage';
        return role === 'output';
    }

    function saveEditor() {
        const kind = editorState.kind;
        if (!kind) return;
        const currentName = editorState.name;
        let requested = readValue('fldName');
        // 存储容器没有名称输入框：直接拿外设名提交（服务端也是这么推导的）
        if (kind === 'containers' && !isNamedContainerRole()) {
            requested = (editorState.locked && editorState.locked.peripheral) || currentName || '';
        }
        // 红石信号不需要命名（1.6.9）：名字就是中继器外设名（同一个中继器只保留一个定义）
        if (kind === 'signals') {
            requested = readValue('fldPeripheral') || currentName || '';
        }
        // 机器 / 流程没有名称字段：编辑既有定义时沿用原名，新建时按类型/产物自动推导
        if (!requested && currentName) requested = currentName;
        if (!requested) requested = autoDefinitionName(kind);
        if (!requested) {
            toast(t('name') + ' ?', 'error');
            return;
        }
        // 信号名恒等于外设名：不做“重名自动加序号”（服务端会把同一中继器的旧定义顶掉）
        const name = kind === 'signals' ? requested : uniqueDefinitionName(kind, requested, currentName);
        if (name !== requested) {
            const field = el('fldName');
            if (field) field.value = name;
            toast(t('autoRenamed', { old: requested, name: name }), 'info');
        }
        const payload = collectPayload(kind);
        if (!payload) return;
        // previous = 编辑前的键（容器是“种类:名称”）：服务端据此把旧定义摘掉，
        // 这样改名（编辑）不会再撞上“同一外设每种容器只能用一个名字”的校验
        const request = { name: name, data: payload };
        if (currentName) request.previous = currentName;
        busyButton('editorSaveBtn', sendRequest(SAVE_ACTION[kind], request)).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('saved'), 'success');
            editorModalInstance().hide();
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function deleteEditor() {
        const kind = editorState.kind;
        let name = editorState.name;
        if (!kind || !name) return;
        const payload = { name: name };
        // 容器定义以“种类:名称”为键，删除时要带上种类（同名物品/流体容器互不影响）
        if (kind === 'containers') {
            const locked = editorState.locked || {};
            payload.kind = locked.kind === 'fluid' ? 'fluid' : 'item';
            name = String(name).replace(/^(item|fluid):/, '');
        }
        // 容器 / 信号定义允许强制删除（换外设时用：引用它的流程会被冻结，重新建出同名定义就恢复）
        if (kind === 'containers' || kind === 'signals') payload.force = true;
        if (!window.confirm(t('deleteConfirm', { name: name }))) return;
        busyButton('editorDeleteBtn', sendRequest(DELETE_ACTION[kind], payload)).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('saved'), 'success');
            editorModalInstance().hide();
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    // ===================== 流程校验（前端先挡一遍，服务端保存时还会再校验一次） =====================
    // 机器类型：必须存在，并且至少有一台机器在用（否则流程永远等不到机器）。
    // 材料参数：资源名必须填；输入数目 > 0；产物“最多数目”> 0 且“最少”≤“最多”；占位符要填名称与关联物品；
    //           红石元素要指定机器信号序号（不能超过该机器类型下机器配置的条数）；等待时长不能为负；
    //           输入元素的容器序号不能超过机器对应种类的输入容器数量（超了就永远等不到材料）。
    function machinesOfType(typeName) {
        return Array.from(stores.machines.values()).filter(function (machine) {
            return String(machine.type || '') === String(typeName || '');
        });
    }

    function maxListLength(machines, field) {
        return machines.reduce(function (best, machine) {
            return Math.max(best, asArray(machine[field]).length);
        }, 0);
    }

    function elementKindLabel(kind) {
        const labels = {
            item: t('item'), fluid: t('fluid'), filter: t('filterKind'), placeholder: t('placeholder'),
            virtual: t('virtual'),
            waitSignal: t('waitSignal'), emitSignal: t('emitSignal'), emitPulse: t('emitPulse'), waitTime: t('waitTime')
        };
        return labels[kind] || String(kind || '');
    }

    // ===================== 流程设置复制 / 抽象模板 =====================
    // 流程里只要有一个“虚操作”元素，它就是**抽象模板**：不能合成（服务端也会拒绝下单），
    // 只用来把整套输入/输出设置复制到别的流程里（见 ifm-picker.js 的复制下拉框）。
    function processHasVirtual(process) {
        if (!process) return false;
        return asArray(process.inputs).concat(asArray(process.outputs)).some(function (element) {
            return element && element.kind === 'virtual';
        });
    }

    // 可以复制的来源流程：**只限同一个机器类型**；带虚操作的模板排在最前（用户要求优先显示）
    function processCopyCandidates(machineType) {
        const type = String(machineType || '');
        if (!type) return [];
        return Array.from(stores.processes.values())
            .filter(function (process) { return String(process.machineType || '') === type; })
            .sort(function (a, b) {
                const left = processHasVirtual(a) ? 0 : 1;
                const right = processHasVirtual(b) ? 0 : 1;
                if (left !== right) return left - right;
                return String(a.name).localeCompare(String(b.name));
            });
    }

    function processCopyLabel(process) {
        const title = processTitleText(process);
        return (processHasVirtual(process) ? '[' + t('template') + '] ' : '') +
            String(process.name) + (title && title !== process.name ? ' · ' + title : '');
    }

    function validateProcessDraft(payload) {
        const machineType = String(payload.machineType || '').trim();
        if (!machineType) return t('processNeedMachineType');
        if (!stores.machineTypes.has(machineType)) return t('processUnknownMachineType', { name: machineType });
        const machines = machinesOfType(machineType);
        if (machines.length === 0) return t('processNoMachineOfType', { name: machineType });
        const itemInputs = maxListLength(machines, 'itemInputs');
        const fluidInputs = maxListLength(machines, 'fluidInputs');
        const maxSignals = maxListLength(machines, 'signals');
        const check = function (element, index, side) {
            const kind = element.kind || 'item';
            const at = t('processElementPrefix', {
                side: side === 'input' ? t('inputs') : t('outputs'),
                index: index + 1,
                kind: elementKindLabel(kind)
            }) + '：';
            if (kind === 'item' || kind === 'fluid' || kind === 'filter') {
                const id = String(element.id || '').trim();
                if (!id) return at + t('processMissingResource');
                if (kind === 'filter' && !stores.filters.has(id)) {
                    return at + t('processUnknownFilter', { name: id });
                }
                if (side === 'input') {
                    if (!(Number(element.count) > 0)) return at + t('processBadCount');
                    const limit = kind === 'fluid' ? fluidInputs : itemInputs;
                    const containerIndex = Number(element.containerIndex);
                    if (isFinite(containerIndex) && containerIndex > limit) {
                        return at + t('processContainerIndexTooBig', { n: limit });
                    }
                } else {
                    const min = Number(element.min || 0);
                    const max = Number(element.max || 0);
                    if (!(max > 0)) return at + t('processBadMax');
                    if (min > max) return at + t('processMinOverMax');
                }
            } else if (kind === 'placeholder') {
                if (!String(element.name || '').trim() || !String(element.item || '').trim()) {
                    return at + t('processBadPlaceholder');
                }
            } else if (kind === 'virtual') {
                // 虚操作（抽象模板元素）：输入/输出都能放，只要一个名字（复制到别的流程后靠它认出来）
                if (!String(element.name || '').trim()) {
                    return at + t('virtualNeedName');
                }
            } else if (kind === 'waitSignal' || kind === 'emitSignal' || kind === 'emitPulse') {
                const signalIndex = Number(element.machineSignalIndex || 0);
                if (!(signalIndex >= 1)) return at + t('processBadSignalIndex');
                if (maxSignals === 0) return at + t('processNoSignals');
                if (signalIndex > maxSignals) return at + t('processSignalIndexTooBig', { n: maxSignals });
            } else if (kind === 'waitTime') {
                if (!(Number(element.seconds) >= 0)) return at + t('processBadSeconds');
            }
            return null;
        };
        const inputs = asArray(payload.inputs);
        const outputs = asArray(payload.outputs);
        for (let i = 0; i < inputs.length; i += 1) {
            const problem = check(inputs[i], i, 'input');
            if (problem) return problem;
        }
        for (let i = 0; i < outputs.length; i += 1) {
            const problem = check(outputs[i], i, 'output');
            if (problem) return problem;
        }
        return null;
    }

    function collectPayload(kind) {
        if (kind === 'containers') {
            const locked = editorState.locked || {};
            if (!locked.peripheral) {
                // 容器定义只能从“外设与定义”里某个外设的「+ 容器」进入（外设名不能手填）
                toast(t('needFreePeripheral'), 'error');
                return null;
            }
            return {
                peripheral: locked.peripheral,
                kind: locked.kind === 'fluid' ? 'fluid' : 'item',
                role: readValue('fldRole'),
                priority: Math.round(readNumber('fldPriority', 0))
            };
        }
        if (kind === 'signals') {
            return { peripheral: readValue('fldPeripheral') };
        }
        if (kind === 'machineTypes') {
            return {};
        }
        if (kind === 'filters') {
            return { rules: collectRules() };
        }
        if (kind === 'machines') {
            return {
                type: readValue('fldType'),
                itemInputs: readMulti('fldItemInputs'),
                fluidInputs: readMulti('fldFluidInputs'),
                signals: readMulti('fldSignals'),
                itemOutputs: readMulti('fldItemOutputs'),
                fluidOutputs: readMulti('fldFluidOutputs'),
                parallel: Math.max(1, Math.floor(readNumber('fldParallel', 1)))
            };
        }
        if (kind === 'processes') {
            const payload = {
                machineType: readValue('fldMachineType'),
                maxMultiplier: Math.max(1, Math.floor(readNumber('fldMaxMultiplier', 1))),
                inputs: collectElements('input'),
                outputs: collectElements('output')
            };
            // 前端先校验一遍（机器类型 / 材料参数），服务端保存时还会再校验一次
            const problem = validateProcessDraft(payload);
            if (problem) {
                toast(problem, 'error');
                return null;
            }
            return payload;
        }
        return null;
    }

    // ===================== 编辑器：过滤器规则 =====================
    const RULE_LABELS = {
        item_include: { zh: '包含物品', en: 'Include item' },
        item_exclude: { zh: '排除物品', en: 'Exclude item' },
        fluid_include: { zh: '包含流体', en: 'Include fluid' },
        fluid_exclude: { zh: '排除流体', en: 'Exclude fluid' },
        itemTag_include: { zh: '包含物品标签', en: 'Include item tag' },
        itemTag_exclude: { zh: '排除物品标签', en: 'Exclude item tag' },
        fluidTag_include: { zh: '包含流体标签', en: 'Include fluid tag' },
        fluidTag_exclude: { zh: '排除流体标签', en: 'Exclude fluid tag' },
        filter_include: { zh: '包含过滤器', en: 'Include filter' },
        filter_exclude: { zh: '排除过滤器', en: 'Exclude filter' }
    };

    function ruleLabel(type) {
        const entry = RULE_LABELS[type];
        return entry ? (entry[lang] || entry.zh) : type;
    }

    function isFilterRefRule(type) {
        return type === 'filter_include' || type === 'filter_exclude';
    }

    function suggestionValues() {
        const values = [];
        Array.from(stores.resources.values()).forEach(function (entry) {
            if (entry.kind === 'item' || entry.kind === 'fluid') values.push(entry.name);
        });
        Array.from(stores.filters.values()).forEach(function (entry) { values.push(entry.name); });
        values.push('c:ores/gold', 'c:ingots/iron', 'c:water');
        return values.sort();
    }

    function ruleValueHtml(type, value) {
        if (isFilterRefRule(type)) {
            const options = filterOptions(editorState.name).map(function (option) {
                return '<option value="' + escapeHtml(option.value) + '"' +
                    (String(option.value) === String(value) ? ' selected' : '') + '>' + escapeHtml(option.label) + '</option>';
            }).join('');
            return '<select class="rule-value" style="flex:1 1 150px"><option value="">—</option>' + options + '</select>';
        }
        return '<input type="text" class="rule-value" list="ifmSuggestions" value="' + escapeHtml(value || '') +
            '" placeholder="mod:name / tag" style="flex:1 1 150px">';
    }

    function ruleRowHtml(type, value, ignoreNbt, nbt) {
        const options = RULE_TYPES.map(function (ruleType) {
            return '<option value="' + ruleType + '"' + (ruleType === type ? ' selected' : '') + '>' +
                escapeHtml(ruleLabel(ruleType)) + '</option>';
        }).join('');
        return '<div class="rule-row">' +
            '<select class="rule-type" onchange="window.ifmRuleTypeChanged(this)">' + options + '</select>' +
            '<span class="rule-value-slot">' + ruleValueHtml(type, value) + '</span>' +
            '<label class="muted">' + escapeHtml(t('ignoreNbt')) +
            ' <input type="checkbox" class="rule-nbt"' + (ignoreNbt ? ' checked' : '') + '></label>' +
            '<input type="text" class="rule-hash" value="' + escapeHtml(nbt || '') + '" style="width:130px" placeholder="' +
            escapeHtml(t('nbtHash')) + '">' +
            '<button class="btn-pixel danger" type="button" onclick="window.ifmRemoveRule(this)"><i class="fa fa-times"></i></button>' +
            '</div>';
    }

    window.ifmRuleTypeChanged = function (select) {
        const row = select.closest('.rule-row');
        if (!row) return;
        const slot = row.querySelector('.rule-value-slot');
        const current = slot.querySelector('input, select');
        slot.innerHTML = ruleValueHtml(select.value, current ? current.value : '');
    };

    window.ifmRemoveRule = function (button) {
        const row = button.closest('.rule-row');
        if (row) row.remove();
    };

    window.ifmAddRule = function () {
        const list = el('ruleList');
        if (!list) return;
        const holder = document.createElement('div');
        holder.innerHTML = ruleRowHtml('item_include', '', false, '');
        list.appendChild(holder.firstChild);
    };

    function collectRules() {
        const rules = [];
        Array.prototype.forEach.call(document.querySelectorAll('#ruleList .rule-row'), function (row) {
            const typeSelect = row.querySelector('.rule-type');
            const control = row.querySelector('.rule-value-slot input, .rule-value-slot select');
            const nbtBox = row.querySelector('.rule-nbt');
            const hashBox = row.querySelector('.rule-hash');
            const value = control ? String(control.value).trim() : '';
            if (!typeSelect || !value) return;
            rules.push({
                type: typeSelect.value,
                id: value,
                nbt: hashBox ? String(hashBox.value).trim() : '',
                ignoreNbt: !!(nbtBox && nbtBox.checked)
            });
        });
        return rules;
    }

    function buildFilterEditor(data, name) {
        const rules = asArray(data.rules);
        const suggestions = suggestionValues().map(function (value) {
            return '<option value="' + escapeHtml(value) + '"></option>';
        }).join('');
        return nameRow(name || data.name) +
            '<datalist id="ifmSuggestions">' + suggestions + '</datalist>' +
            '<div class="editor-block">' +
            '<h4>' + escapeHtml(t('rules')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddRule()"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="ruleList">' + rules.map(function (rule) {
                return ruleRowHtml(rule.type, rule.id, rule.ignoreNbt, rule.nbt);
            }).join('') + '</div>' +
            '<div class="muted">' +
            escapeHtml('语义：存在包含规则时必须命中其一；没有任何包含规则时视为包含一切；命中任一排除规则即不匹配。' +
                '标签直接填写标签名（如 c:ores/gold）。') +
            '</div></div>';
    }

    // ===================== 编辑器：机器 =====================
    // 机器没有“名称”字段：保存时按机器类型自动命名（见 autoDefinitionName）
    function buildMachineEditor(data, name) {
        const itemContainers = containerOptions('interaction', 'item');
        const fluidContainers = containerOptions('interaction', 'fluid');
        return fieldRow(t('machineTypeField'), selectHtml('fldType', machineTypeOptions(), data.type, true)) +
            fieldRow(t('parallel'), numberInput('fldParallel', data.parallel || 1, 1, 1)) +
            '<div class="editor-block"><h4>' + escapeHtml(t('inputs')) + '</h4>' +
            fieldRow(t('itemInputs'), orderedPickerHtml('fldItemInputs', itemContainers, data.itemInputs)) +
            fieldRow(t('fluidInputs'), orderedPickerHtml('fldFluidInputs', fluidContainers, data.fluidInputs)) +
            '</div>' +
            '<div class="editor-block"><h4>' + escapeHtml(t('outputs')) + '</h4>' +
            fieldRow(t('itemOutputs'), orderedPickerHtml('fldItemOutputs', itemContainers, data.itemOutputs)) +
            fieldRow(t('fluidOutputs'), orderedPickerHtml('fldFluidOutputs', fluidContainers, data.fluidOutputs)) +
            '</div>' +
            '<div class="editor-block"><h4>' + escapeHtml(t('signalsField')) + '</h4>' +
            fieldRow(t('signalsField'), orderedPickerHtml('fldSignals', signalOptions(), data.signals)) +
            '</div>' +
            '<div class="muted">' + escapeHtml('机器引用到的容器定义必须使用 interaction 角色；' +
                '物品输入/输出只列出物品容器，流体输入/输出只列出流体容器。' +
                '可多选，列表里的上下箭头用于调整顺序（序号 1 优先）。') + '</div>';
    }

    // ===================== 编辑器：流程元素 =====================
    function selectForClass(className, values, value, labels) {
        return '<select class="' + className + '">' + values.map(function (item) {
            const label = (labels && labels[item]) ? labels[item] : item;
            return '<option value="' + escapeHtml(item) + '"' + (String(item) === String(value) ? ' selected' : '') +
                '>' + escapeHtml(label) + '</option>';
        }).join('') + '</select>';
    }

    function sideCheckboxes(selected) {
        const chosen = asArray(selected);
        // 没有任何配置（新建元素）默认六面全开；已有配置就按配置显示
        const useAll = chosen.length === 0;
        return SIDE_VALUES.map(function (side) {
            const on = useAll || chosen.indexOf(side) >= 0;
            return '<label class="muted" style="margin-right:6px"><input type="checkbox" class="e-side" value="' +
                side + '"' + (on ? ' checked' : '') + '> ' + escapeHtml(t('side_' + side)) + '</label>';
        }).join('');
    }

    function elementIdControl(kind, value) {
        if (kind === 'filter') {
            const options = byName(Array.from(stores.filters.values())).map(function (item) {
                return '<option value="' + escapeHtml(item.name) + '"' +
                    (String(item.name) === String(value) ? ' selected' : '') + '>' + escapeHtml(item.name) + '</option>';
            }).join('');
            return '<select class="e-id" style="flex:1 1 130px"><option value="">—</option>' + options + '</select>';
        }
        const input = '<input type="text" class="e-id" list="ifmSuggestions" value="' + escapeHtml(value || '') +
            '" placeholder="mod:name" style="flex:1 1 130px">';
        if (kind === 'item' || kind === 'fluid') {
            // 「从库存选择」改为弹窗（图标 + 名称 + 搜索框），比原生下拉好找得多
            return input + '<button class="btn-pixel" type="button" data-stock-kind="' + kind + '" ' +
                'onclick="window.ifmOpenStockPicker(this)"><i class="fa fa-box-open"></i> ' +
                escapeHtml(t('pickResource')) + '</button>';
        }
        return input;
    }

    