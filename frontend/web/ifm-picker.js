'use strict';

    let stockInstance = null;
    let stockTargetInput = null;
    let stockKind = 'item';
    let stockRefreshTimer = null;

    function stockModalInstance() {
        if (!stockInstance) stockInstance = new bootstrap.Modal(el('stockModal'));
        return stockInstance;
    }

    function stockEntries() {
        const list = Array.from(stores.resources.values())
            .filter(function (entry) { return entry.kind === stockKind; });
        // Products that are not in storage yet but can be crafted by some process
        // are offered too (count 0), exactly like the resources panel does. The
        // hash-agnostic key makes a stocked variant always win over the synthesis.
        const stocked = new Set();
        stores.resources.forEach(function (entry) {
            stocked.add(resourceKey(entry.kind, entry.name));
        });
        craftableMaterials().forEach(function (entry, key) {
            if (entry.kind !== stockKind || stocked.has(key)) return;
            list.push(entry);
        });
        return list.sort(function (a, b) {
            const countA = a.count || 0;
            const countB = b.count || 0;
            if (countA !== countB) return countB - countA;
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
            const query = parseSearchQuery(rawQuery);
            entries = entries.filter(function (entry) { return matchesSearch(entry, query); });
        }
        queueTranslateNames(entries);
        list.innerHTML = entries.length
            ? entries.map(function (entry) {
                const nbt = String(entry.nbt || '');
                // The same item with different hashes are different entries: show
                // which one is which and carry the hash onto the picked element.
                const hashHint = nbt
                    ? '<span class="muted" title="' + escapeHtml(nbt) + '">@' +
                        escapeHtml(nbt.slice(0, 8)) + '</span>'
                    : '';
                return '<button class="stock-item" type="button" data-stock-pick="' + escapeHtml(entry.name) +
                    '" data-stock-nbt="' + escapeHtml(nbt) + '">' +
                    iconHtml(entry.kind, entry.name) +
                    '<span class="stock-name" title="' + escapeHtml(entry.name) + '">' +
                    escapeHtml(displayName(entry.kind, entry.name)) + '</span>' + hashHint +
                    '<span class="stock-count' + (entry.craftable ? ' craftable' : '') + '"' +
                    (entry.craftable ? ' title="' + escapeHtml(t('craftOnly')) + '"' : '') + '>' +
                    escapeHtml(entry.craftable ? t('craftable') : fmtCount(entry.count || 0)) + '</span>' +
                    '</button>';
            }).join('')
            : '<span class="muted">' + escapeHtml(t('noData')) + '</span>';
        const hint = el('stockHint');
        if (hint) hint.textContent = t('stockCount', { n: entries.length });
        if (!stockRefreshTimer && entries.some(function (entry) {
            return metaState(resourceKey(entry.kind, entry.name)) === 'unknown';
        })) {
            stockRefreshTimer = setTimeout(function () {
                stockRefreshTimer = null;
                renderStockList();
            }, 1200);
        }
    }

    function focusStockSearch() {
        const search = el('stockSearch');
        if (!search) return;
        search.focus();
        if (search.select) search.select();
    }

    window.ifmOpenStockPicker = function (button) {
        // Element rows pass the button and rely on the surrounding .id-slot; the
        // container tool names its target explicitly (data-stock-target), because
        // its resource field is a plain #toolResource input.
        const explicit = button && button.getAttribute
            ? String(button.getAttribute('data-stock-target') || '') : '';
        const explicitTarget = explicit ? document.querySelector(explicit) : null;
        if (explicitTarget) {
            stockTargetInput = explicitTarget;
        } else {
            const slot = button.closest('.id-slot');
            // The placeholder row's item field is a .e-pitem input, the item/fluid
            // rows use .e-id; both live in their own .id-slot, so neither can pick
            // the other row's field.
            stockTargetInput = slot ? (slot.querySelector('.e-pitem') || slot.querySelector('.e-id')) : null;
        }
        stockKind = button.getAttribute('data-stock-kind') === 'fluid' ? 'fluid' : 'item';
        const search = el('stockSearch');
        if (search) search.value = '';
        syncSearchClear('stockSearch');
        renderStockList();
        const modal = el('stockModal');
        if (modal && !modal.__ifmFocusBound) {
            // Focusing right after show() loses against bootstrap's focus trap
            // (this picker opens on top of the element editor's modal), so wait
            // for the transition to finish; the timeout below only covers cases
            // where the event never fires. data-bs-focus="false" on #stockModal
            // and #editorModal keeps both traps from stealing the caret back.
            modal.__ifmFocusBound = true;
            modal.addEventListener('shown.bs.modal', function () { focusStockSearch(); });
            modal.addEventListener('hidden.bs.modal', function () {
                // The container tool's resource field is a plain input, so give
                // the caret back once the picker closes (element rows open their
                // own suggestion panel and must not be refocused here).
                if (stockTargetInput && stockTargetInput.id === 'toolResource') {
                    stockTargetInput.focus();
                }
            });
        }
        stockModalInstance().show();
        setTimeout(focusStockSearch, 300);
    };

    function pickStock(button) {
        const name = button ? String(button.getAttribute('data-stock-pick') || '') : '';
        if (!name) return;
        const nbt = button ? String(button.getAttribute('data-stock-nbt') || '') : '';
        const label = displayName(stockKind, name);
        if (stockTargetInput) stockTargetInput.value = name;
        // The container tool has its own NBT field next to the resource field: a
        // picked stack carries its hash over, so "put exactly this variant in"
        // works without typing it by hand.
        if (stockTargetInput && stockTargetInput.id === 'toolResource') {
            const nbtField = el('toolNbt');
            if (nbtField) nbtField.value = nbt;
        }
        // A placeholder's item field has no hash of its own (the element model is
        // just kind/name/item), so the picked hash is only carried over for the
        // resource fields that really have one.
        if (!stockTargetInput || !stockTargetInput.classList ||
            !stockTargetInput.classList.contains('e-pitem')) {
            applyStockNbt(stockTargetInput, nbt);
        }
        // The editor rows refresh their icon from an input/change event (see
        // ifm-app.js's editorBody listener), and assigning .value fires none:
        // dispatch them so a stock pick updates the icon without extra typing.
        if (stockTargetInput && typeof stockTargetInput.dispatchEvent === 'function') {
            stockTargetInput.dispatchEvent(new Event('input', { bubbles: true }));
            stockTargetInput.dispatchEvent(new Event('change', { bubbles: true }));
        }
        stockModalInstance().hide();
        toast(t('stockPicked', { name: label }), 'success');
    }

    // A stock entry is a concrete (kind, name, nbt) triple, so picking one also
    // pins the element's hash instead of leaving whatever was typed before.
    function applyStockNbt(input, nbt) {
        if (!input || !input.closest) return;
        const row = input.closest('.element-row');
        if (!row) return;
        const hashBox = row.querySelector('.e-nbt');
        if (hashBox) hashBox.value = nbt;
        const ignoreBox = row.querySelector('.e-ignore-nbt');
        if (ignoreBox) ignoreBox.checked = nbt === '';
        applyElementNbtVisibility(row);
    }

    // `title` (8th argument) only exists to explain the container/slot fields; the
    // older call sites pass 7 arguments and keep their plain tooltip-free look.
    function numberField(when, label, className, value, width, step, onInput, title) {
        return '<span data-when="' + when + '" class="muted">' + escapeHtml(label) +
            ' <input type="number" class="' + className + '" value="' + escapeHtml(value === undefined || value === null ? '' : value) +
            '" style="width:' + width + 'px"' + (step ? ' step="' + step + '"' : '') +
            (onInput ? ' oninput="' + onInput + '"' : '') +
            (title ? ' title="' + escapeHtml(title) + '"' : '') + '></span>';
    }

    function textField(when, label, className, value, width) {
        return '<span data-when="' + when + '" class="muted">' + escapeHtml(label) +
            ' <input type="text" class="' + className + '" value="' + escapeHtml(value || '') +
            '" style="width:' + width + 'px"></span>';
    }

    function elementRowListId(side) {
        return side === 'input' ? 'elementInputList' : 'elementOutputList';
    }

    function elementRowHtml(side, element) {
        const data = element || {};
        const kind = data.kind || 'item';
        const kinds = ELEMENT_KINDS.filter(function (item) {
            return side === 'output' || (item !== 'placeholder');
        });
        const kindOptions = kinds.map(function (item) {
            return '<option value="' + item + '"' + (item === kind ? ' selected' : '') + '>' +
                escapeHtml(t(item)) + '</option>';
        }).join('');

        const parts = [];
        parts.push('<span class="element-icon" data-element-icon></span>');
        parts.push('<span data-when="item fluid filter"><span class="muted">' + escapeHtml(t('name')) +
            '</span> <span class="id-slot">' + elementIdControl(kind, data.id) + '</span></span>');
        parts.push('<span class="e-nbt-slot muted" data-when="item fluid filter">' + escapeHtml(t('nbtHash')) +
            ' <input type="text" class="e-nbt" value="' + escapeHtml(data.nbt || '') + '" style="width:120px" placeholder="' +
            escapeHtml(t('nbtAny')) + '"></span>');
        parts.push('<label data-when="item fluid filter" class="muted">' + escapeHtml(t('ignoreNbt')) +
            ' <input type="checkbox" class="e-ignore-nbt"' + (data.ignoreNbt === false ? '' : ' checked') +
            ' onchange="window.ifmElementIgnoreNbtChanged(this)"></label>');
        const containerValue = (data.containerIndex === undefined || data.containerIndex === -1)
            ? '' : data.containerIndex;
        const slotValue = (data.slot === undefined || data.slot === -1) ? '' : data.slot;
        if (side === 'input') {
            parts.push(numberField('item fluid filter', t('amount'), 'e-count', data.count === undefined ? 1 : data.count, 70));
            parts.push(numberField('item fluid filter', t('containerIndex'), 'e-container', containerValue, 60,
                null, null, t('containerIndexHint')));
            parts.push(numberField('item filter', t('slot'), 'e-slot', slotValue, 60,
                null, null, t('slotHint')));
            // "Mix resources" only matters for material filters: with it off the
            // engine binds the element to one concrete resource when the instance
            // is created (see recipe.createInstance), so a batch never mixes two
            // resources of the same tag.
            if (kind === 'filter') {
                parts.push('<label data-when="filter" class="muted" title="' +
                    escapeHtml(t('allowMixHint')) + '">' + escapeHtml(t('allowMix')) +
                    ' <input type="checkbox" class="e-allow-mix"' +
                    (data.allowMix === false ? '' : ' checked') + '></label>');
            }
            // "Catalyst": the amount is not multiplied by the instance batch multiplier.
            parts.push('<label data-when="item fluid filter" class="muted" title="' +
                escapeHtml(t('catalystHint')) + '">' + escapeHtml(t('catalyst')) +
                ' <input type="checkbox" class="e-catalyst"' +
                (data.catalyst === true ? ' checked' : '') + '></label>');
            // "Skippable": try once per instance, then skip when it cannot be delivered.
            parts.push('<label data-when="item fluid filter" class="muted" title="' +
                escapeHtml(t('skippableHint')) + '">' + escapeHtml(t('skippable')) +
                ' <input type="checkbox" class="e-skip"' +
                (data.skip === true ? ' checked' : '') + '></label>');
        } else {
            const minValue = data.min === undefined || data.min === null ? 1 : data.min;
            const expectValue = data.expect === undefined || data.expect === null ? (data.max || 1) : data.expect;
            const maxValue = data.max === undefined || data.max === null ? 1 : data.max;
            // "Chance craft": the three fields only differ for probabilistic
            // outputs, so an equal triple (the normal case) hides min/max behind
            // the switch and lets them follow the expected amount.
            const chance = elementChanceCraft(kind, minValue, expectValue, maxValue);
            parts.push('<label data-when="item fluid filter" class="muted" title="' +
                escapeHtml(t('chanceCraftHint')) + '">' + escapeHtml(t('chanceCraft')) +
                ' <input type="checkbox" class="e-chance"' + (chance ? ' checked' : '') +
                ' onchange="window.ifmElementChanceChanged(this)"></label>');
            parts.push('<span data-chance-field="min" data-when="item fluid filter">' +
                numberField('item fluid filter', t('min'), 'e-min', minValue, 60, '0.01') + '</span>');
            parts.push(numberField('item fluid filter', t('expect'), 'e-expect', expectValue, 60, '0.01',
                'window.ifmElementExpectChanged(this)'));
            parts.push('<span data-chance-field="max" data-when="item fluid filter">' +
                numberField('item fluid filter', t('max'), 'e-max', maxValue, 60, '0.01') + '</span>');
            const craftOn = data.craft === undefined || data.craft === null ? true : data.craft !== false;
            parts.push('<label data-when="item fluid filter" class="muted" title="' +
                escapeHtml(t('craftRefHint')) + '">' + escapeHtml(t('craftRef')) +
                ' <input type="checkbox" class="e-craft"' + (craftOn ? ' checked' : '') + '></label>');
            // Extraction side: an output may name the machine output container it
            // has to take from - and, for items, the slot inside it. Empty means
            // "any", exactly like the input side.
            parts.push(numberField('item fluid filter', t('containerIndex'), 'e-container', containerValue, 60,
                null, null, t('containerIndexHint')));
            parts.push(numberField('item filter', t('slot'), 'e-slot', slotValue, 60,
                null, null, t('slotHint')));
            parts.push(textField('placeholder', t('placeholder'), 'e-pname', data.name, 120));
            // The referenced item is a real item: it is picked from storage like any
            // other resource (the button sits in the same .id-slot the item/fluid rows
            // use, so ifmOpenStockPicker finds the .e-pitem input next to it).
            parts.push('<span data-when="placeholder" class="muted">' + escapeHtml(t('item')) +
                ' <span class="id-slot"><input type="text" class="e-pitem" value="' +
                escapeHtml(data.item || '') + '" placeholder="mod:name" style="flex:1 1 140px">' +
                '<button class="btn-pixel" type="button" data-stock-kind="item" ' +
                'onclick="window.ifmOpenStockPicker(this)"><i class="fa fa-box-open"></i> ' +
                escapeHtml(t('pickResource')) + '</button></span></span>');
        }
        parts.push(numberField('waitSignal emitSignal emitPulse', t('machineSignalIndex'), 'e-msignal',
            (data.machineSignalIndex === undefined || data.machineSignalIndex === null) ? 1 : data.machineSignalIndex, 60));
        parts.push('<span data-when="waitSignal emitSignal emitPulse" class="muted">' + escapeHtml(t('sides')) + '<br>' +
            sideCheckboxes(data.sides) + '</span>');
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
        // Both helpers narrow that kind visibility further: the hash box hides
        // behind "ignore NBT", and the min/max pair only shows for item/fluid/filter
        // outputs with the chance switch on.
        applyElementChanceVisibility(row);
        applyElementNbtVisibility(row);
        const idSlot = row.querySelector('.id-slot');
        if (idSlot) {
            const control = idSlot.querySelector('input, select');
            idSlot.innerHTML = elementIdControl(kind, control ? control.value : '');
            // elementIdControl() just replaced the input, so the suggestion panel
            // (the only candidate source now that the native datalists are gone)
            // has to be attached to the fresh node.
            const next = idSlot.querySelector('input.e-id');
            if (next) attachAutocomplete(next);
        }
        refreshElementIcons();
    };

    function elementChanceCraft(kind, min, expect, max) {
        if (kind !== 'item' && kind !== 'fluid' && kind !== 'filter') return false;
        return !(Number(min) === Number(expect) && Number(expect) === Number(max));
    }

    function elementRowChance(row) {
        const box = row ? row.querySelector('.e-chance') : null;
        return !!(box && box.checked);
    }

    function applyElementChanceVisibility(row) {
        if (!row) return;
        const kindSelect = row.querySelector('.e-kind');
        const kind = kindSelect ? kindSelect.value : '';
        const usesChance = kind === 'item' || kind === 'fluid' || kind === 'filter';
        const on = usesChance && elementRowChance(row);
        Array.prototype.forEach.call(row.querySelectorAll('[data-chance-field]'), function (node) {
            node.style.display = on ? '' : 'none';
        });
        if (usesChance && !on) {
            // min/max are not editable while the switch is off: they mirror the
            // expected amount, so the hidden inputs already hold the right value.
            const expectNode = row.querySelector('.e-expect');
            const value = expectNode ? String(expectNode.value) : '1';
            ['min', 'max'].forEach(function (name) {
                const node = row.querySelector('.e-' + name);
                if (node) node.value = value;
            });
        }
    }

    function applyElementNbtVisibility(row) {
        if (!row) return;
        const kindSelect = row.querySelector('.e-kind');
        const kind = kindSelect ? kindSelect.value : '';
        const box = row.querySelector('.e-ignore-nbt');
        const slot = row.querySelector('.e-nbt-slot');
        if (!box || !slot) return;
        const kindShows = kind === 'item' || kind === 'fluid' || kind === 'filter';
        slot.style.display = (kindShows && !box.checked) ? '' : 'none';
    }

    window.ifmElementChanceChanged = function (box) {
        const row = box && box.closest ? box.closest('.element-row') : null;
        applyElementChanceVisibility(row);
    };

    window.ifmElementExpectChanged = function (input) {
        const row = input && input.closest ? input.closest('.element-row') : null;
        if (row && !elementRowChance(row)) applyElementChanceVisibility(row);
    };

    window.ifmElementIgnoreNbtChanged = function (box) {
        const row = box && box.closest ? box.closest('.element-row') : null;
        applyElementNbtVisibility(row);
    };

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
                holder.innerHTML = '<i class="fa ' + iconGlyphClass('abstract') + '"></i>';
                holder.setAttribute('title', t('abstractHint'));
                return;
            }
            if (kind === 'placeholder') {
                // A placeholder is drawn with the icon of the item it stands for; the
                // placeholder's own name stays in the tooltip. Only an empty item
                // field falls back to the generic thumb-tack glyph.
                const itemNode = row.querySelector('.e-pitem');
                const itemName = itemNode ? String(itemNode.value || '').trim() : '';
                const nameNode = row.querySelector('.e-pname');
                const placeholderName = nameNode ? String(nameNode.value || '').trim() : '';
                if (!itemName) {
                    holder.innerHTML = '<i class="fa ' + iconGlyphClass(kind) + '"></i>';
                    holder.setAttribute('title', t('placeholderKind'));
                    return;
                }
                queueMeta('item', itemName);
                holder.innerHTML = plainIconImg('item', itemName);
                holder.setAttribute('title', (placeholderName ? placeholderName + ' → ' : '') +
                    displayName('item', itemName));
                if (metaState(resourceKey('item', itemName)) === 'unknown') pending = true;
                return;
            }
            if ((kind !== 'item' && kind !== 'fluid') || !id) {
                holder.innerHTML = ELEMENT_ICON_EMPTY;
                holder.removeAttribute('title');
                return;
            }
            const realKind = kind === 'fluid' ? 'fluid' : 'item';
            queueMeta(realKind, id);
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
        const list = el(elementRowListId(side));
        if (!list) return;
        const holder = document.createElement('div');
        holder.innerHTML = elementRowHtml(side, { kind: 'item' });
        const row = holder.firstChild;
        list.appendChild(row);
        const kindSelect = row.querySelector('.e-kind');
        if (kindSelect) window.ifmElementKindChanged(kindSelect);
    };

    // Operation (element) cards can be re-ordered by dragging their background: the
    // saved order is the DOM order (collectElements walks it), so dragging a card up
    // or down is what changes the order the process runs its operations in. A pointer
    // based drag is used instead of native HTML5 drag & drop so the mouse wheel keeps
    // working (the editor body scrolls) - same reasoning as bindPeripheralDrag.
    function elementRowDropBefore(list, row, y) {
        const rows = Array.prototype.filter.call(list.children, function (node) {
            return node !== row && node.classList && node.classList.contains('element-row');
        });
        for (let index = 0; index < rows.length; index += 1) {
            const rect = rows[index].getBoundingClientRect();
            if (y < rect.top + rect.height / 2) return rows[index];
        }
        return null;
    }

    function bindElementRowSorting() {
        [elementRowListId('input'), elementRowListId('output')].forEach(function (listId) {
            const list = el(listId);
            if (!list || list.dataset.sortBound) return;
            list.dataset.sortBound = '1';
            let drag = null;
            list.addEventListener('pointerdown', function (event) {
                if (event.button !== 0 || drag) return;
                // Only the card background starts a drag: a press inside a control
                // (input / select / button / label) edits that field as usual.
                if (event.target.closest && event.target.closest('input, select, button, textarea, a, label')) {
                    return;
                }
                const row = event.target.closest ? event.target.closest('.element-row') : null;
                if (!row || row.parentNode !== list) return;
                drag = { row: row, startX: event.clientX, startY: event.clientY,
                    active: false, pointerId: event.pointerId, list: list };
            });
            list.addEventListener('pointermove', function (event) {
                if (!drag || event.pointerId !== drag.pointerId) return;
                if (!drag.active) {
                    const dx = event.clientX - drag.startX;
                    const dy = event.clientY - drag.startY;
                    if (dx * dx + dy * dy < 16) return;
                    drag.active = true;
                    drag.row.classList.add('dragging');
                    if (list.setPointerCapture) {
                        try { list.setPointerCapture(event.pointerId); } catch (err) { }
                    }
                }
                const before = elementRowDropBefore(list, drag.row, event.clientY);
                if (before) {
                    list.insertBefore(drag.row, before);
                } else {
                    list.appendChild(drag.row);
                }
                event.preventDefault();
            });
            const stopDrag = function (event) {
                if (!drag || (event.pointerId !== undefined && event.pointerId !== drag.pointerId)) return;
                const active = drag.active;
                const row = drag.row;
                drag = null;
                row.classList.remove('dragging');
                if (list.releasePointerCapture && event.pointerId !== undefined) {
                    try { list.releasePointerCapture(event.pointerId); } catch (err) { }
                }
                if (active) refreshElementIcons();
            };
            list.addEventListener('pointerup', stopDrag);
            list.addEventListener('pointercancel', stopDrag);
        });
    }

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
        if (raw === '') return fallback;
        const value = Number(raw);
        return isFinite(value) ? value : fallback;
    }

    function elementRowIgnoreNbt(row) {
        const box = row.querySelector('.e-ignore-nbt');
        return box ? !!box.checked : true;
    }

    // "Mix resources" defaults to on: an element without the switch (older data,
    // non-filter kinds) keeps the classic "any matching resource" behaviour.
    function elementRowAllowMix(row) {
        const box = row.querySelector('.e-allow-mix');
        return box ? !!box.checked : true;
    }

    // "Catalyst" / "Skippable" default to off: an element without the switch (older
    // data) is a normal input.
    function elementRowChecked(row, selector) {
        const box = row.querySelector(selector);
        return box ? !!box.checked : false;
    }

    function collectElements(side) {
        const out = [];
        Array.prototype.forEach.call(document.querySelectorAll('#editorBody .element-row[data-side="' + side + '"]'), function (row) {
            const kindSelect = row.querySelector('.e-kind');
            if (!kindSelect) return;
            const kind = kindSelect.value;
            if (kind === 'item' || kind === 'fluid' || kind === 'filter') {
                // Slot only means something for items and filters (both name a
                // slot inside the machine container); fluids keep the container
                // index but ignore the slot.
                const usesSlot = kind === 'item' || kind === 'filter';
                const entry = {
                    kind: kind,
                    id: elementRowValue(row, '.e-id'),
                    nbt: elementRowValue(row, '.e-nbt'),
                    ignoreNbt: elementRowIgnoreNbt(row),
                    containerIndex: elementRowNumber(row, '.e-container', -1),
                    slot: usesSlot ? elementRowNumber(row, '.e-slot', -1) : -1
                };
                if (!entry.id) return;
                if (side === 'input') {
                    entry.count = elementRowNumber(row, '.e-count', 0);
                    entry.catalyst = elementRowChecked(row, '.e-catalyst');
                    entry.skip = elementRowChecked(row, '.e-skip');
                    if (kind === 'filter') {
                        entry.allowMix = elementRowAllowMix(row);
                    }
                } else {
                    const usesChance = kind === 'item' || kind === 'fluid' || kind === 'filter';
                    entry.expect = elementRowNumber(row, '.e-expect', 1);
                    const craftBox = row.querySelector('.e-craft');
                    entry.craft = craftBox ? craftBox.checked === true : true;
                    if (usesChance && !elementRowChance(row)) {
                        // chance switch off: min/max always equal the expected amount
                        entry.min = entry.expect;
                        entry.max = entry.expect;
                    } else {
                        entry.min = elementRowNumber(row, '.e-min', usesChance ? entry.expect : 0);
                        entry.max = elementRowNumber(row, '.e-max', usesChance ? entry.expect : 1);
                    }
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
            toast(t('copyProcessOtherType'), 'error');
            return;
        }
        const maxField = el('fldMaxMultiplier');
        if (maxField) maxField.value = Math.max(1, Math.floor(Number(source.maxMultiplier) || 1));
        const ioModeField = el('fldIoMode');
        if (ioModeField) ioModeField.value = String(source.ioMode || 'sequential');
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

    function buildProcessEditor(data, name) {
        const inputs = asArray(data.inputs);
        const outputs = asArray(data.outputs);
        // A preset (an auto-discovered bridge draft) can name its IO mode; otherwise a
        // process starts in sequential IO (an existing one keeps its saved mode).
        const ioMode = String(data.ioMode || 'sequential');
        const copyRow = fieldRow(t('copyProcessFrom'),
            '<span style="display:inline-flex;gap:6px;align-items:center;flex-wrap:wrap">' +
            '<select id="fldCopyFrom" style="min-width:200px">' +
            processCopyOptionsHtml(data.machineType, null) + '</select>' +
            '<button class="btn-pixel" type="button" onclick="window.ifmProcessCopySettings()">' +
            '<i class="fa fa-clone"></i> ' + escapeHtml(t('copyProcessApply')) + '</button></span>') +
            '<div class="muted" style="margin:-4px 0 6px 0">' + escapeHtml(t('copyProcessHint')) + '</div>';
        const abstractRow = fieldRow(t('abstractOp'),
            '<span style="display:inline-flex;gap:6px;align-items:center;flex-wrap:wrap">' +
            '<button class="btn-pixel danger" type="button" onclick="window.ifmClearAbstractOps()">' +
            '<i class="fa fa-eraser"></i> ' + escapeHtml(t('clearAbstractOps')) + '</button>' +
            '<span class="muted">' + escapeHtml(t('clearAbstractOpsHint')) + '</span></span>');
        return fieldRow(t('machineTypeField'), searchableSelectHtml('fldMachineType', machineTypeOptions(), data.machineType,
                'onchange="window.ifmProcessMachineTypeChanged(this)"')) +
            copyRow +
            abstractRow +
            fieldRow(t('maxMultiplier'),
                numberInput('fldMaxMultiplier', data.maxMultiplier || DEFAULT_MAX_MULTIPLIER, 1, 1)) +
            fieldRow(t('ioMode'),
                '<select id="fldIoMode" style="min-width:200px">' +
                ['sequential', 'two_phase', 'unordered'].map(function (value) {
                    return '<option value="' + value + '"' + (value === ioMode ? ' selected' : '') + '>' +
                        escapeHtml(t('ioMode_' + value)) + '</option>';
                }).join('') +
                '</select><div class="muted">' + escapeHtml(t('ioModeHint')) + '</div>') +
            '<div class="editor-block"><h4>' + escapeHtml(t('inputs')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddElement(\'input\')"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="' + elementRowListId('input') + '">' + inputs.map(function (item) { return elementRowHtml('input', item); }).join('') + '</div>' +
            '<div class="muted">' + escapeHtml(t('processEditorHint')) + '</div>' +
            '<div class="muted">' + escapeHtml(t('abstractHint')) + '</div>' +
            '</div>' +
            '<div class="editor-block"><h4>' + escapeHtml(t('outputs')) +
            '<button class="btn-pixel" type="button" onclick="window.ifmAddElement(\'output\')"><i class="fa fa-plus"></i> ' +
            escapeHtml(t('add')) + '</button></h4>' +
            '<div id="' + elementRowListId('output') + '">' + outputs.map(function (item) { return elementRowHtml('output', item); }).join('') + '</div>' +
            '<div class="muted">' + escapeHtml(t('resourcePickerHint')) + '</div>' +
            '</div>';
    }
