'use strict';

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

    // Expressions are evaluated with exact rationals: "1/3*3" is 1 and
    // "(128+64)/3*3" is 192, never 191.99999999999997. Doubles only come back at
    // the very end, and because every prompt asks for an integer count the value
    // that is finally applied is that rational rounded UP (64/3 is 22, not 21).
    const RATIONAL_LIMIT = 9007199254740991;

    function gcdOf(left, right) {
        let a = Math.abs(left);
        let b = Math.abs(right);
        while (b > 0) {
            const rest = a % b;
            a = b;
            b = rest;
        }
        return a;
    }

    // Numerator and denominator stay integers: past the 2^53 range the arithmetic
    // would silently fall back to floats, so such a step fails the whole
    // expression instead of returning a wrong number.
    function rationalOf(numerator, denominator) {
        if (!isFinite(numerator) || !isFinite(denominator) || denominator === 0) return null;
        if (!Number.isInteger(numerator) || !Number.isInteger(denominator)) return null;
        let n = numerator;
        let d = denominator;
        if (d < 0) {
            n = -n;
            d = -d;
        }
        const divisor = gcdOf(n, d) || 1;
        n /= divisor;
        d /= divisor;
        if (Math.abs(n) > RATIONAL_LIMIT || Math.abs(d) > RATIONAL_LIMIT) return null;
        return { n: n, d: d };
    }

    function rationalNegate(value) {
        return value ? { n: -value.n, d: value.d } : null;
    }

    function rationalAdd(a, b) {
        return rationalOf(a.n * b.d + b.n * a.d, a.d * b.d);
    }

    function rationalMultiply(a, b) {
        return rationalOf(a.n * b.n, a.d * b.d);
    }

    function rationalDivide(a, b) {
        return b.n === 0 ? null : rationalOf(a.n * b.d, a.d * b.n);
    }

    // a % b = a - trunc(a / b) * b, which stays exact for fractions too.
    function rationalModulo(a, b) {
        if (b.n === 0) return null;
        const quotient = (a.n * b.d) / (a.d * b.n);
        if (!isFinite(quotient)) return null;
        return rationalAdd(a, rationalMultiply(rationalOf(-Math.trunc(quotient), 1), b));
    }

    function ceilRational(value) {
        const whole = Math.trunc(value.n / value.d);
        return (whole * value.d < value.n) ? whole + 1 : whole;
    }

    // The exact value of an expression, or null when the text is not a valid one.
    function evalRational(text) {
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
            const literal = source.slice(start, index);
            if (literal === '' || literal === '.' || !/^[0-9]*\.?[0-9]*$/.test(literal)) {
                bad = true;
                return null;
            }
            const dot = literal.indexOf('.');
            if (dot < 0) {
                const whole = rationalOf(Number(literal), 1);
                if (!whole) bad = true;
                return whole;
            }
            const decimals = literal.length - dot - 1;
            if (decimals > 15) {
                bad = true;
                return null;
            }
            const digits = literal.slice(0, dot) + literal.slice(dot + 1);
            const value = rationalOf(Number(digits === '' ? '0' : digits), Math.pow(10, decimals));
            if (!value) bad = true;
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
                return rationalNegate(parseFactor());
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
                if (!right) {
                    bad = true;
                    return null;
                }
                if (char === '*') value = rationalMultiply(value, right);
                else if (char === '/') value = rationalDivide(value, right);
                else value = rationalModulo(value, right);
                if (!value) {
                    bad = true;
                    return null;
                }
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
                if (!right) {
                    bad = true;
                    return null;
                }
                value = (char === '+') ? rationalAdd(value, right)
                    : rationalAdd(value, rationalNegate(right));
                if (!value) {
                    bad = true;
                    return null;
                }
            }
            return value;
        }

        const result = parseSum();
        if (bad || !result || index !== source.length) return null;
        return result;
    }

    // Every prompt asks for an integer count, so the value that is handed to
    // onConfirm (and shown in the preview) is the exact result rounded UP: a
    // request for "64/3" units is a request for 22, never for 21.
    function evalPromptInteger(text) {
        const value = evalRational(text);
        return value ? ceilRational(value) : null;
    }

    function isPlainNumber(text) {
        return /^[0-9]+(\.[0-9]+)?$/.test(text);
    }

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
        const value = evalPromptInteger(raw);
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
            el('promptModal').addEventListener('shown.bs.modal', function () {
                input.focus();
                if (typeof input.select === 'function') input.select();
            }, { once: true });
        }
        instance.show();
    }

    function confirmPrompt() {
        console.log('[IFM] confirmPrompt fired: promptState=' + (promptState ? 'set' : 'null'));
        if (!promptState) return;
        const options = promptState;
        const raw = String(el('promptInput').value || '').trim();
        const value = raw === '' ? 0 : evalPromptInteger(raw);
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

    // A searchable replacement for selectHtml: a visible search box (with the shared
    // suggestion panel) plus a hidden input that keeps the original id and value, so
    // readValue(id) and an onchange passed in attrs are unchanged. Used for the machine
    // type dropdown, whose list must be filtered by name / label / pinyin.
    function searchableSelectHtml(id, options, value, attrs) {
        let label = '';
        asArray(options).forEach(function (option) {
            if (String(option.value) === String(value)) label = option.label;
        });
        return '<span class="searchable-select">' +
            '<input type="text" class="ss-input" id="' + id + 'Search" autocomplete="off"' +
            ' data-ac-provider="machineType" data-ac-value-target="' + id + '"' +
            ' value="' + escapeHtml(label) + '" placeholder="' + escapeHtml(t('search')) + '">' +
            '<input type="hidden" id="' + id + '" value="' +
            escapeHtml(value === undefined || value === null ? '' : value) + '"' +
            (attrs ? ' ' + attrs : '') + '>' +
            '</span>';
    }

    const pickerState = new Map();
    const pickerOptions = new Map();

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
        Array.prototype.forEach.call(
            document.querySelectorAll('#editorBody input.e-id, #editorBody input.rule-value,' +
                ' #editorBody #toolResource, #editorBody [data-ac-provider]'),
            function (input) { attachAutocomplete(input); }
        );
    }

    const AC_LIMIT = 12;
    let acPanel = null;
    let acState = null;
    let acApplying = false;

    function closeAutocomplete() {
        if (acPanel && acPanel.parentNode) acPanel.parentNode.removeChild(acPanel);
        acPanel = null;
        acState = null;
    }

    function acCandidates(query, source) {
        const text = String(query || '').trim().toLowerCase();
        const kind = source || 'any';
        const pool = [];
        const tagPool = [];
        Array.from(stores.resources.values()).forEach(function (entry) {
            const entryKind = entry.kind === 'fluid' ? 'fluid' : 'item';
            if (kind === 'any' || kind === entryKind) pool.push(entry.name);
            asArray(entry.tags).forEach(function (tag) { tagPool.push(String(tag)); });
        });
        if (kind === 'any') {
            Array.from(stores.filters.values()).forEach(function (entry) { pool.push(entry.name); });
        }
        if (kind === 'any' || kind === 'tag') {
            AC_TAG_HINTS.forEach(function (tag) { tagPool.push(tag); });
        }
        const list = (kind === 'tag' ? tagPool : pool);
        const seen = {};
        const out = [];
        list.forEach(function (value) {
            const candidate = String(value || '');
            if (!candidate || seen[candidate]) return;
            seen[candidate] = true;
            if (text && candidate.toLowerCase().indexOf(text) < 0) return;
            out.push(candidate);
        });
        return out.slice(0, AC_LIMIT);
    }

    const AC_TAG_HINTS = ['c:ingots', 'c:ores', 'c:stones', 'c:plates', 'c:water', 'minecraft:logs'];

    function acSourceForInput(input) {
        // An input that pins its resource kind (the container tool's resource field,
        // the machine type icon) only suggests that kind.
        const stockKind = (input && input.getAttribute) ? input.getAttribute('data-stock-kind') : null;
        if (stockKind === 'item' || stockKind === 'fluid') return stockKind;
        const row = input && input.closest ? input.closest('.rule-row') : null;
        if (!row) return 'any';
        const select = row.querySelector('.rule-type');
        const ruleType = select ? String(select.value || '') : '';
        if (ruleType.indexOf('Tag_') >= 0) return 'tag';
        if (ruleType.indexOf('item_') === 0) return 'item';
        if (ruleType.indexOf('fluid_') === 0) return 'fluid';
        return 'any';
    }

    // Extra candidate sources for inputs carrying data-ac-provider (the searchable
    // machine type select and the filter-reference fields). Each returns
    // [{value, label}] and matches the query against value, label and - only in the
    // Chinese UI - pinyin (pinyinSearchHit itself refuses when lang is not zh).
    const AC_PROVIDERS = {
        machineType: function (query) {
            return acFilterOptions(machineTypeOptions(), query);
        },
        filterIds: function (query) {
            return acFilterOptions(filterOptions(editorState.name).map(function (row) {
                return { value: row.value, label: row.label };
            }), query, function (row) { return displayName('filter', row.value); });
        },
    };

    function acFilterOptions(rows, query, extraLabel) {
        const text = String(query || '').trim().toLowerCase();
        return asArray(rows).filter(function (row) {
            if (!text) return true;
            const value = String(row.value || '').toLowerCase();
            const label = String(row.label || '').toLowerCase();
            if (value.indexOf(text) >= 0 || label.indexOf(text) >= 0) return true;
            if (lang !== 'zh') return false;
            const targets = [row.label];
            if (extraLabel) targets.push(extraLabel(row));
            for (let i = 0; i < targets.length; i += 1) {
                try {
                    if (pinyinSearchHit(text, String(targets[i] || ''), '')) return true;
                } catch (err) {  }
            }
            return false;
        }).slice(0, AC_LIMIT);
    }

    function acItemsFor(input) {
        const providerName = (input && input.getAttribute) ? input.getAttribute('data-ac-provider') : null;
        const provider = providerName ? AC_PROVIDERS[providerName] : null;
        const query = String((input && input.value) || '').trim();
        if (provider) return provider(query);
        return acCandidates(query, acSourceForInput(input)).map(function (value) {
            return { value: value, label: value };
        });
    }

    function renderAcPanel() {
        if (!acState) return;
        acState.panel.innerHTML = acState.items.map(function (item, index) {
            return '<div class="ifm-ac-item' + (index === acState.index ? ' active' : '') +
                '" data-ac-index="' + index + '">' + escapeHtml(item.label) + '</div>';
        }).join('');
        const active = acState.panel.querySelector('.ifm-ac-item.active');
        if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
    }

    function applyAcIndex(index) {
        if (!acState) return;
        const item = acState.items[index];
        if (item === undefined) return;
        const input = acState.input;
        const targetId = input.getAttribute ? input.getAttribute('data-ac-value-target') : null;
        const target = targetId ? el(targetId) : null;
        closeAutocomplete();
        input.value = item.label;
        acApplying = true;
        // A searchable select keeps its real value in a hidden input (the one carrying
        // the original id): write it and let its onchange run.
        if (target) {
            target.value = item.value;
            target.dispatchEvent(new window.Event('change', { bubbles: true }));
        }
        input.dispatchEvent(new window.Event('input', { bubbles: true }));
        acApplying = false;
    }

    function openAutocomplete(input, index) {
        const items = acItemsFor(input);
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
                applyAcIndex(acState.index);
                event.preventDefault();
                event.stopPropagation();
                return;
            }
            if (key === 'Escape') {
                closeAutocomplete();
                event.stopPropagation();
            }
        });
    }

    // The candidate panel has to disappear when the user clicks anywhere else: the
    // input's blur alone is not enough (some handlers cancel mousedown, and a
    // re-render can leave a panel whose input is already detached).
    document.addEventListener('pointerdown', function (event) {
        if (!acState) return;
        const target = event.target;
        if (acState.input === target || (acState.panel && acState.panel.contains(target))) return;
        closeAutocomplete();
    }, true);
    window.addEventListener('scroll', function () { closeAutocomplete(); }, true);
    window.addEventListener('resize', function () { closeAutocomplete(); });
    if (el('editorModal')) {
        el('editorModal').addEventListener('hidden.bs.modal', function () { closeAutocomplete(); });
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
        if (pickerState.has(id)) return pickerState.get(id).slice();
        const node = el(id);
        if (!node) return [];
        return Array.prototype.slice.call(node.selectedOptions || []).map(function (option) { return option.value; });
    }

    const KIND_LABEL_KEY = {
        containers: 'container', signals: 'signal', filters: 'filter',
        machineTypes: 'machineType', machines: 'machine', processes: 'processKind'
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
    const OP_LABELS = { gt: '>', ge: '≥', eq: '=', le: '≤', lt: '<' };
    const ELEMENT_KINDS = ['item', 'fluid', 'filter', 'placeholder', 'waitSignal', 'emitSignal', 'emitPulse', 'waitTime'];
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

    const EDITOR_MACHINE_TYPE_LABEL_KEYS = {
        turtle_crafter: 'machineTypeTurtleCrafter',
        type_conversion: 'machineTypeTypeConversion'
    };
    function machineTypeLabel(name) {
        const key = EDITOR_MACHINE_TYPE_LABEL_KEYS[String(name)];
        if (!key) return String(name);
        const text = t(key);
        return (text && text !== key) ? text : String(name);
    }

    function machineTypeOptions(includeConversion) {
        return byName(Array.from(stores.machineTypes.values()).filter(function (item) {
            // The type conversion type is virtual: it cannot back a real machine, so
            // the machine editor must not offer it (the process editor may).
            return includeConversion !== false || String(item.name) !== 'type_conversion';
        })).map(function (item) {
            const label = machineTypeLabel(item.name);
            return { value: item.name, label: label === item.name ? item.name : (label + ' (' + item.name + ')') };
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

    function peripheralKindsOf(name) {
        const kinds = [];
        Array.from(stores.peripherals.values()).forEach(function (item) {
            if (item.name === name && kinds.indexOf(item.kind) < 0) kinds.push(item.kind);
        });
        return kinds;
    }

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
        return base + t('wrapParen', { text: kinds.join(' / ') });
    }

    function readOnlyRow(label, value, hint) {
        return '<div class="editor-row"><label>' + escapeHtml(label) + '</label><div>' +
            '<input type="text" value="' + escapeHtml(value) + '" readonly disabled>' +
            (hint ? ' <span class="muted">' + escapeHtml(hint) + '</span>' : '') +
            '</div></div>';
    }

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
            '<div class="editor-block" id="toolMoveBlock">' +
            '<h4><i class="fa fa-exchange"></i> ' + escapeHtml(t('containerMoveTitle')) + '</h4>' +
            '<div class="editor-row"><label>' + escapeHtml(t('resourceLabel')) + '</label>' +
            '<span class="search-wrap">' +
            '<input type="text" id="toolResource" data-stock-kind="item" placeholder="' +
            escapeHtml(t('item') + ' / ' + t('fluid')) + '" autocomplete="off">' +
            '<button class="btn-pixel search-clear" id="toolResourceClear" type="button" title="' +
            escapeHtml(t('searchClear')) + '" style="display:none"><i class="fa fa-times"></i></button>' +
            '<button class="btn-pixel" id="toolResourcePick" type="button" data-stock-target="#toolResource" ' +
            'title="' + escapeHtml(t('pickResource')) + '" onclick="window.ifmOpenStockPicker(this)">' +
            '<i class="fa fa-box-open"></i></button>' +
            '</span></div>' +
            '<div class="editor-row"><label>' + escapeHtml(t('count')) + '</label>' +
            '<input type="number" id="toolCount" value="1" min="1"></div>' +
            '<div class="editor-row"><label>' + escapeHtml(t('nbtHash')) + '</label>' +
            '<input type="text" id="toolNbt" placeholder="' + escapeHtml(t('nbtAny')) + '" title="' +
            escapeHtml(t('toolNbtHint')) + '" autocomplete="off"></div>' +
            // One container-level put button, shown for fluid containers only: a fluid
            // has no slot to put into, so the take side keeps its per-row buttons and
            // the put side lives here, outside the contents list.
            '<div class="editor-row" id="toolPutRow" style="display:none">' +
            '<button class="btn-pixel" id="toolPutGlobal" type="button"><i class="fa fa-sign-in"></i> ' +
            escapeHtml(t('containerPut')) + '</button></div>' +
            // Container-wide slot capacity multiplier: the value applies to every slot
            // without a per-slot override; an empty value clears it.
            '<div class="editor-row" id="toolSlotMultRow" style="display:none">' +
            '<label>' + escapeHtml(t('slotMultiplierAllLabel')) + '</label>' +
            '<span style="display:inline-flex;gap:6px;align-items:center">' +
            '<input type="number" id="toolSlotMultAll" min="0" step="1" style="width:90px" placeholder="' +
            escapeHtml(t('slotMultiplierEmptyHint')) + '">' +
            '<button class="btn-pixel" id="toolSlotMultAllBtn" type="button"><i class="fa fa-check"></i> ' +
            escapeHtml(t('slotMultiplierApplyAll')) + '</button></span></div>' +
            '<div class="muted">' + escapeHtml(t('containerTakeHint')) + '</div>' +
            '</div>' +
            '<div style="margin-top:6px">' +
            '<button class="btn-pixel" id="toolRefreshBtn" type="button"><i class="fa fa-refresh"></i> ' +
            escapeHtml(t('refresh')) + '</button>' +
            '</div>' +
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
        const roleSelect = '<select id="fldRole" style="width:100%" onchange="window.ifmContainerRoleChanged(this)">' +
            ROLE_VALUES.map(function (value) {
                return '<option value="' + escapeHtml(value) + '"' + (value === roleValue ? ' selected' : '') +
                    '>' + escapeHtml(roleLabel(value)) + '</option>';
            }).join('') + '</select>';
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
        return fieldRow(t('peripheral'), selectHtml('fldPeripheral', peripheralOptions(['redstone_relay']), data.peripheral)) +
            '<div class="muted">' + escapeHtml(t('signalNameHint')) + '</div>';
    }

    // The icon is an item registry name; it may be typed or picked from stock
    // (the stock picker writes the registry name into the named input).
    function machineTypeIconControl(value) {
        return '<div class="editor-row"><label>' + escapeHtml(t('machineTypeIcon')) + '</label>' +
            '<span class="search-wrap">' +
            '<input type="text" id="fldMachineTypeIcon" value="' + escapeHtml(value || '') +
            '" placeholder="mod:name" autocomplete="off" title="' +
            escapeHtml(t('machineTypeIconHint')) + '">' +
            '<button class="btn-pixel" type="button" data-stock-target="#fldMachineTypeIcon" ' +
            'data-stock-kind="item" onclick="window.ifmOpenStockPicker(this)">' +
            '<i class="fa fa-box-open"></i> ' + escapeHtml(t('pickResource')) + '</button>' +
            '</span></div>';
    }

    function buildMachineTypeEditor(data, name) {
        return nameRow(name || data.name) +
            machineTypeIconControl(data.icon) +
            '<div class="muted">' + escapeHtml(t('machineTypeIconHint')) + '</div>' +
            '<div class="muted">' + escapeHtml(t('machineTypeRotateHint')) + '</div>';
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
        if (kind === 'processes') bindElementRowSorting();
        if (kind === 'containers' && window.ifmContainerToolMount) {
            window.ifmContainerToolMount(name || null, data.peripheral || null);
        }
        editorModalInstance().show();
    }

    function uniqueDefinitionName(kind, requested, currentName) {
        const store = stores[kind];
        const base = String(requested || '').trim();
        if (!store || !base) return base;
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

    function isNamedContainerRole() {
        const role = readValue('fldRole') || (editorState.data && editorState.data.role) || 'storage';
        return role === 'output';
    }

    function saveEditor() {
        const kind = editorState.kind;
        if (!kind) return;
        const currentName = editorState.name;
        let requested = readValue('fldName');
        if (kind === 'containers' && !isNamedContainerRole()) {
            requested = (editorState.locked && editorState.locked.peripheral) || currentName || '';
        }
        if (kind === 'signals') {
            requested = readValue('fldPeripheral') || currentName || '';
        }
        if (!requested && currentName) requested = currentName;
        if (!requested) requested = autoDefinitionName(kind);
        if (!requested) {
            toast(t('name') + ' ?', 'error');
            return;
        }
        const name = kind === 'signals' ? requested : uniqueDefinitionName(kind, requested, currentName);
        if (name !== requested) {
            const field = el('fldName');
            if (field) field.value = name;
            toast(t('autoRenamed', { old: requested, name: name }), 'info');
        }
        const payload = collectPayload(kind);
        if (!payload) return;
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
        if (kind === 'containers') {
            const locked = editorState.locked || {};
            payload.kind = locked.kind === 'fluid' ? 'fluid' : 'item';
            name = String(name).replace(/^(item|fluid):/, '');
        }
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
            waitSignal: t('waitSignal'), emitSignal: t('emitSignal'), emitPulse: t('emitPulse'), waitTime: t('waitTime')
        };
        return labels[kind] || String(kind || '');
    }

    function processCopyCandidates(machineType) {
        const type = String(machineType || '');
        if (!type) return [];
        return Array.from(stores.processes.values())
            .filter(function (process) { return String(process.machineType || '') === type; })
            .sort(function (a, b) {
                const left = processIsAbstract(a) ? 0 : 1;
                const right = processIsAbstract(b) ? 0 : 1;
                if (left !== right) return left - right;
                return String(a.name).localeCompare(String(b.name));
            });
    }

    function processCopyLabel(process) {
        const title = processTitleText(process);
        return (processIsAbstract(process) ? '[' + t('abstractProcess') + '] ' : '') +
            String(process.name) + (title && title !== process.name ? ' · ' + title : '');
    }

    function validateProcessDraft(payload) {
        const machineType = String(payload.machineType || '').trim();
        if (!machineType) return t('processNeedMachineType');
        if (!stores.machineTypes.has(machineType)) return t('processUnknownMachineType', { name: machineType });
        const machines = machinesOfType(machineType);
        // A process may be prepared before its machine exists: the machine type
        // only has to be defined, so the limits below are skipped when there is
        // no machine to derive them from.
        const hasMachines = machines.length > 0;
        const itemInputs = maxListLength(machines, 'itemInputs');
        const fluidInputs = maxListLength(machines, 'fluidInputs');
        const itemOutputs = maxListLength(machines, 'itemOutputs');
        const fluidOutputs = maxListLength(machines, 'fluidOutputs');
        const maxSignals = maxListLength(machines, 'signals');
        const check = function (element, index, side) {
            const kind = element.kind || 'item';
            const at = t('processElementPrefix', {
                side: side === 'input' ? t('inputs') : t('outputs'),
                index: index + 1,
                kind: elementKindLabel(kind)
            }) + t('labelSeparator');
            if (kind === 'item' || kind === 'fluid' || kind === 'filter') {
                const id = String(element.id || '').trim();
                if (!id) return at + t('processMissingResource');
                if (kind === 'filter' && !stores.filters.has(id)) {
                    return at + t('processUnknownFilter', { name: id });
                }
                // Both sides may pin a machine container (inputs and outputs);
                // the count check only exists on the input side.
                const limit = kind === 'fluid'
                    ? (side === 'input' ? fluidInputs : fluidOutputs)
                    : (side === 'input' ? itemInputs : itemOutputs);
                const containerIndex = Number(element.containerIndex);
                if (hasMachines && isFinite(containerIndex) && containerIndex > limit) {
                    return at + t('processContainerIndexTooBig', { n: limit });
                }
                if (side === 'input') {
                    if (!(Number(element.count) > 0)) return at + t('processBadCount');
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
            } else if (kind === 'waitSignal' || kind === 'emitSignal' || kind === 'emitPulse') {
                const signalIndex = Number(element.machineSignalIndex || 0);
                if (!(signalIndex >= 1)) return at + t('processBadSignalIndex');
                if (hasMachines && maxSignals === 0) return at + t('processNoSignals');
                if (hasMachines && signalIndex > maxSignals) return at + t('processSignalIndexTooBig', { n: maxSignals });
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
            return { icon: readValue('fldMachineTypeIcon') };
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
            const ioModeField = el('fldIoMode');
            const payload = {
                machineType: readValue('fldMachineType'),
                maxMultiplier: Math.max(1, Math.floor(readNumber('fldMaxMultiplier', 1))),
                ioMode: ioModeField ? String(ioModeField.value || 'sequential') : 'sequential',
                inputs: collectElements('input'),
                outputs: collectElements('output')
            };
            const problem = validateProcessDraft(payload);
            if (problem) {
                toast(problem, 'error');
                return null;
            }
            return payload;
        }
        return null;
    }

    const RULE_LABELS = {
        item_include: 'filterModeItemInclude',
        item_exclude: 'filterModeItemExclude',
        fluid_include: 'filterModeFluidInclude',
        fluid_exclude: 'filterModeFluidExclude',
        itemTag_include: 'filterModeItemTagInclude',
        itemTag_exclude: 'filterModeItemTagExclude',
        fluidTag_include: 'filterModeFluidTagInclude',
        fluidTag_exclude: 'filterModeFluidTagExclude',
        filter_include: 'filterModeFilterInclude',
        filter_exclude: 'filterModeFilterExclude'
    };

    function ruleLabel(type) {
        const key = RULE_LABELS[type];
        return key ? t(key) : type;
    }

    function isFilterRefRule(type) {
        return type === 'filter_include' || type === 'filter_exclude';
    }

    function ruleValueHtml(type, value) {
        if (isFilterRefRule(type)) {
            // A free text field with the shared suggestion panel: the filter list can be
            // searched (and pinyin-matched) instead of scrolling a native dropdown.
            return '<input type="text" class="rule-value" data-ac-provider="filterIds" value="' +
                escapeHtml(value || '') + '" placeholder="' + escapeHtml(t('search')) +
                '" style="flex:1 1 150px">';
        }
        return '<input type="text" class="rule-value" value="' + escapeHtml(value || '') +
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
        const input = slot.querySelector('input.rule-value');
        if (input) attachAutocomplete(input);
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
        const row = holder.firstChild;
        list.appendChild(row);
        // the row is created after initPickers() ran, so attach the suggestion
        // panel here (it is the only candidate source now)
        const input = row.querySelector('input.rule-value');
        if (input) attachAutocomplete(input);
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
        return nameRow(name || data.name) +
            '<div class="editor-block">' +
            '<h4>' + escapeHtml(t('rules')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddRule()"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="ruleList">' + rules.map(function (rule) {
                return ruleRowHtml(rule.type, rule.id, rule.ignoreNbt, rule.nbt);
            }).join('') + '</div>' +
            '<div class="muted">' +
            escapeHtml(t('filterSemanticsHint')) +
            '</div></div>';
    }

    function buildMachineEditor(data, name) {
        const itemContainers = containerOptions('interaction', 'item');
        const fluidContainers = containerOptions('interaction', 'fluid');
        return fieldRow(t('machineTypeField'), searchableSelectHtml('fldType', machineTypeOptions(false), data.type)) +
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
            '<div class="muted">' + escapeHtml(t('machineRoleHint')) + '</div>';
    }

    function selectForClass(className, values, value, labels) {
        return '<select class="' + className + '">' + values.map(function (item) {
            const label = (labels && labels[item]) ? labels[item] : item;
            return '<option value="' + escapeHtml(item) + '"' + (String(item) === String(value) ? ' selected' : '') +
                '>' + escapeHtml(label) + '</option>';
        }).join('') + '</select>';
    }

    function sideCheckboxes(selected) {
        const chosen = asArray(selected);
        const useAll = chosen.length === 0;
        return SIDE_VALUES.map(function (side) {
            const on = useAll || chosen.indexOf(side) >= 0;
            return '<label class="muted" style="margin-right:6px"><input type="checkbox" class="e-side" value="' +
                side + '"' + (on ? ' checked' : '') + '> ' + escapeHtml(t('side_' + side)) + '</label>';
        }).join('');
    }

    function elementIdControl(kind, value) {
        if (kind === 'filter') {
            // A free text field with the shared suggestion panel: the filter list can be
            // searched (and pinyin-matched) instead of scrolling a native dropdown.
            return '<input type="text" class="e-id" data-ac-provider="filterIds" value="' +
                escapeHtml(value || '') + '" placeholder="' + escapeHtml(t('search')) +
                '" style="flex:1 1 130px">';
        }
        const input = '<input type="text" class="e-id" value="' + escapeHtml(value || '') +
            '" placeholder="mod:name" style="flex:1 1 130px">';
        if (kind === 'item' || kind === 'fluid') {
            return input + '<button class="btn-pixel" type="button" data-stock-kind="' + kind + '" ' +
                'onclick="window.ifmOpenStockPicker(this)"><i class="fa fa-box-open"></i> ' +
                escapeHtml(t('pickResource')) + '</button>';
        }
        return input;
    }
