'use strict';

    function resourceFromKey(key) {
        const parts = splitKey(key);
        return { kind: parts[0], name: parts[1], nbt: parts[2] || '' };
    }

    function resourceArgs(a, b, c) {
        if (a && typeof a === 'object') return [a.kind, a.name, a.nbt];
        return [a, b, c];
    }

    function resourceStock(a, b, c) {
        const args = resourceArgs(a, b, c);
        // resourceView also knows the craftable-but-empty entries the resources
        // panel shows (see craftableMaterials): their stock is 0, not "unknown".
        const entry = resourceView(resourceKey(args[0], args[1], args[2]));
        return entry ? Math.max(0, entry.count || 0) : 0;
    }

    function resourceCraftable(a, b, c) {
        const args = resourceArgs(a, b, c);
        const entry = resourceView(resourceKey(args[0], args[1], args[2]));
        return !!(entry && entry.craftable);
    }

    function resourceStockByName(kind, name) {
        let total = 0;
        const prefix = kind + ':' + name;
        stores.resources.forEach(function (entry, key) {
            if (key === prefix || key.slice(0, prefix.length + 1) === prefix + '@') {
                total += Number(entry.count) || 0;
            }
        });
        return total;
    }

    function handleAddByClick(resource) {
        if (resource.kind === 'placeholder') return;
        const stock = resourceStock(resource);
        if (stock <= 0 && !resourceCraftable(resource)) {
            toast(t('notCraftable'), 'error');
            return;
        }
        addSend(resource, 1);
    }

    function openSendCountPrompt(resource) {
        const key = resourceKey(resource.kind, resource.name, resource.nbt);
        const current = sendList.get(key);
        const stock = resourceStock(resource);
        const cap = sendCap(resource);
        const suggested = (current && current.count > 0) ? current.count : (stock > 0 ? stock : 1);
        openPrompt({
            title: t('sendCountTitle', { name: displayName(resource.kind, resource.name) }),
            label: displayName(resource.kind, resource.name),
            value: suggested,
            min: 0,
            max: isFinite(cap) ? cap : '',
            hint: t('sendCountHint', {
                pending: fmtCount(current ? current.count : 0),
                stock: fmtCount(stock),
                cap: isFinite(cap) ? fmtCount(cap) : '∞'
            }),
            onConfirm: function (value) {
                const count = Math.max(0, Math.floor(Number(value) || 0));
                if (count <= 0) {
                    // 0 keeps its old meaning: drop the pending amount, send nothing.
                    setSend(resource, 0);
                    return;
                }
                // Middle click: the entered amount is sent right away (only this
                // resource), skipping the "add to list + press send" path.
                sendResourceNow(resource, count);
            }
        });
    }

    // Send exactly one resource right away. Mirrors sendPendingItems (optimistic
    // delivery + the fly-to-delivery animation) but never touches the pending list.
    function sendResourceNow(resource, count) {
        if (!resource || resource.kind === 'placeholder') return;
        const select = el('sendContainer');
        const container = select ? select.value : '';
        if (!container) {
            toast(t('noOutputContainer'), 'error');
            return;
        }
        const entry = {
            kind: resource.kind,
            name: resource.name,
            nbt: resource.nbt,
            count: Math.max(1, Math.floor(Number(count) || 1))
        };
        const items = [entry];
        const key = resourceKey(entry.kind, entry.name, entry.nbt);
        const card = document.querySelector ? document.querySelector(
            '#resourceGrid [data-resource="' + key.replace(/"/g, '\\"') + '"]') : null;
        const fromRect = card ? card.getBoundingClientRect() : null;
        addOptimisticDeliveries(items);
        renderSend();
        const deliveryGrid = el('deliveryGrid');
        if (deliveryGrid) void deliveryGrid.offsetHeight;
        const node = deliveryGrid ? deliveryGrid.querySelector('[data-delivery="' + key + '"]') : null;
        animateSendToDelivery([{
            fromRect: fromRect,
            toRect: node ? node.getBoundingClientRect() : null,
            node: node
        }]);
        sendRequest('send_items', { container: container, items: items }).then(function (response) {
            const result = response.result || {};
            armOptimisticDeliveries();
            if (result.error) {
                dropOptimisticDeliveries(items);
                renderSend();
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            const failures = asArray(result.results).filter(function (item) { return item.error; });
            if (failures.length > 0) {
                toast(t('requestFailed', { error: failures[0].error }), 'error');
            }
            toast(t('sent'), 'success');
        }).catch(function (err) {
            dropOptimisticDeliveries(items);
            renderSend();
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function openCraftPrompt(resource) {
        openPrompt({
            title: t('craftCountTitle', { name: displayName(resource.kind, resource.name) }),
            label: displayName(resource.kind, resource.name),
            value: 1,
            min: 1,
            hint: t('craftOnly') + ' · ' + t('craftAmountHint'),
            onConfirm: function (value) {
                const count = Math.max(1, Math.floor(value) || 1);
                sendRequest('craft_resource', {
                    kind: resource.kind,
                    name: resource.name,
                    count: count
                }).then(function (response) {
                    const result = response.result || {};
                    if (result.error) {
                        toast(t('requestFailed', { error: result.error }), 'error');
                        return;
                    }
                    toast(t('sent'), 'success');
                }).catch(function (err) {
                    toast(t('requestFailed', { error: err.message }), 'error');
                });
            }
        });
    }

    function bindResourceGrid() {
        const grid = el('resourceGrid');
        // Track which resource the pointer is over, so pressing K can open the
        // stock-keeping prompt for exactly that card.
        grid.addEventListener('mouseover', function (event) {
            const card = event.target.closest('[data-resource]');
            hoveredResourceKey = card ? String(card.getAttribute('data-resource') || '') : '';
        });
        grid.addEventListener('mouseleave', function () {
            hoveredResourceKey = '';
        });
        grid.addEventListener('click', function (event) {
            // The craft "+" is a pure indicator now: it has no click handler.
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            if (event.shiftKey) {
                // A placeholder has no stock of its own, so it can never be sent:
                // only the send list is reached from here.
                if (resource.kind === 'placeholder') return;
                addSend(resource, 64);
                return;
            }
            handleAddByClick(resource);
        });
        grid.addEventListener('contextmenu', function (event) {
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            addSend(resource, event.shiftKey ? -64 : -1);
        });
        grid.addEventListener('mousedown', function (event) {
            if (event.button !== 1) return;
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            if (event.shiftKey) {
                // Shift+middle is "craft only": a resource that cannot be crafted
                // must not react to it at all. A placeholder IS craftable - it is
                // requested under its own key ("placeholder:<name>"), which is the
                // one the producing process is registered under.
                if (!resourceCraftable(resource)) return;
                openCraftPrompt(resource);
                return;
            }
            // Plain middle click sends from storage; a placeholder holds no stock of
            // its own, so only the craft gesture above applies to it.
            if (resource.kind === 'placeholder') return;
            openSendCountPrompt(resource);
        });
    }

    function bindSendGrid() {
        const grid = el('sendGrid');
        const deliveryGrid = el('deliveryGrid');
        if (deliveryGrid) {
            deliveryGrid.addEventListener('click', function (event) {
                const cancel = event.target.closest('[data-delivery-cancel]');
                if (!cancel) return;
                event.stopPropagation();
                cancelDelivery(Number(cancel.getAttribute('data-delivery-cancel')));
            });
        }
        grid.addEventListener('click', function (event) {
            const remove = event.target.closest('[data-send-remove]');
            if (remove) {
                const resource = resourceFromKey(remove.getAttribute('data-send-remove'));
                sendList.delete(resourceKey(resource.kind, resource.name, resource.nbt));
                renderSend();
                return;
            }
            const card = event.target.closest('[data-send]');
            if (!card) return;
            const resource = resourceFromKey(card.getAttribute('data-send'));
            addSend(resource, 1);
        });
        grid.addEventListener('contextmenu', function (event) {
            const card = event.target.closest('[data-send]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-send'));
            addSend(resource, -1);
        });
    }

    function cancelDelivery(id) {
        const key = String(id);
        const before = stores.deliveries.get(key);
        if (!before) return;
        stores.deliveries.delete(key);
        renderSend();
        sendRequest('delete_delivery', { deliveryId: id }).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                stores.deliveries.set(key, before);
                renderSend();
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('deliveryCancelled', { name: displayName(before.kind, before.name) }), 'info');
        }).catch(function (err) {
            stores.deliveries.set(key, before);
            renderSend();
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function clearAllDeliveries() {
        if (stores.deliveries.size === 0 && optimisticDeliveries.length === 0) {
            toast(t('deliveriesEmpty'), 'info');
            return;
        }
        const backup = new Map(stores.deliveries);
        stores.deliveries.clear();
        settleOptimisticDeliveries();
        renderSend();
        sendRequest('delete_deliveries', {}).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                backup.forEach(function (value, key) { stores.deliveries.set(key, value); });
                renderSend();
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('deliveriesCleared', { n: fmtCount(result.removed || 0) }), 'info');
        }).catch(function (err) {
            backup.forEach(function (value, key) { stores.deliveries.set(key, value); });
            renderSend();
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function sendPendingItems() {
        if (sendList.size === 0) {
            toast(t('noSend'), 'error');
            return;
        }
        const container = el('sendContainer').value;
        if (!container) {
            toast(t('noOutputContainer'), 'error');
            return;
        }
        const items = Array.from(sendList.values()).map(function (entry) {
            return { kind: entry.kind, name: entry.name, nbt: entry.nbt, count: entry.count };
        });
        const fromRects = {};
        Array.prototype.forEach.call(el('sendGrid').querySelectorAll('[data-send]'), function (node) {
            fromRects[node.getAttribute('data-send')] = node.getBoundingClientRect();
        });
        const backup = items.map(function (entry) { return Object.assign({}, entry); });
        const restoreSend = function () {
            dropOptimisticDeliveries(backup);
            sendList.clear();
            backup.forEach(function (entry) {
                setSend(entry, entry.count);
            });
            renderSend();
        };
        sendList.clear();
        addOptimisticDeliveries(items);
        renderSend();
        const deliveryGrid = el('deliveryGrid');
        if (deliveryGrid) void deliveryGrid.offsetHeight;
        const pairs = items.map(function (entry) {
            const key = resourceKey(entry.kind, entry.name, entry.nbt);
            const grid = el('deliveryGrid');
            const node = grid ? grid.querySelector('[data-delivery="' + key + '"]') : null;
            return { fromRect: fromRects[key], toRect: node ? node.getBoundingClientRect() : null, node: node };
        });
        animateSendToDelivery(pairs);
        busyButton('sendBtn', sendRequest('send_items', { container: container, items: items })).then(function (response) {
            const result = response.result || {};
            armOptimisticDeliveries();
            if (result.error) {
                restoreSend();
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            const failures = asArray(result.results).filter(function (item) { return item.error; });
            if (failures.length > 0) {
                toast(t('requestFailed', { error: failures[0].error }), 'error');
            }
            toast(t('sent'), 'success');
            sendList.clear();
            renderSend();
        }).catch(function (err) {
            restoreSend();
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function bindProcessList() {
        el('processList').addEventListener('click', function (event) {
            const start = event.target.closest('[data-process-start]');
            if (start) {
                const name = start.getAttribute('data-process-start');
                openPrompt({
                    title: t('addProcess'),
                    label: name,
                    value: 1,
                    min: 1,
                    hint: t('processRequestHint'),
                    onConfirm: function (value) {
                        const count = Math.max(1, Math.floor(value) || 1);
                        const process = stores.processes.get(name) || {};
                        const outputs = asArray(process.outputs).filter(function (output) {
                            return output && output.id &&
                                (output.kind === 'item' || output.kind === 'fluid' || output.kind === 'filter');
                        });
                        if (outputs.length === 0) {
                            toast(t('requestFailed', { error: t('noCraftableOutput') }), 'error');
                            return;
                        }
                        // The ledger is per material now: requesting "N batches of
                        // that process" means requesting N of each of its products.
                        const requests = outputs.map(function (output) {
                            return sendRequest('craft_resource', {
                                kind: output.kind,
                                name: output.id,
                                count: count
                            }).then(function (response) {
                                const result = response.result || {};
                                if (result.error) throw new Error(result.error);
                            });
                        });
                        Promise.all(requests).then(function () {
                            toast(t('saved'), 'success');
                        }).catch(function (err) {
                            toast(t('requestFailed', { error: err.message }), 'error');
                        });
                    }
                });
                return;
            }
            const edit = event.target.closest('[data-process-edit]');
            if (edit) {
                openEditor('processes', edit.getAttribute('data-process-edit'));
                return;
            }
            const toggle = event.target.closest('[data-process-toggle]');
            if (toggle) {
                // Folding happens in place: no re-render of the list, so the rest of the
                // panel does not move under the pointer while it is being clicked.
                const name = toggle.getAttribute('data-process-toggle');
                const expanded = !processInstancesExpanded(name);
                setProcessInstancesExpanded(name, expanded);
                toggle.setAttribute('aria-expanded', expanded ? 'true' : 'false');
                const icon = toggle.querySelector('i');
                if (icon) icon.className = 'fa fa-chevron-' + (expanded ? 'down' : 'right');
                const list = instanceListOf(name);
                if (list) list.hidden = !expanded;
                return;
            }
            const abortInstance = event.target.closest('[data-instance-cancel]');
            if (abortInstance) {
                const name = abortInstance.getAttribute('data-instance-cancel');
                const id = Number(abortInstance.getAttribute('data-instance-id'));
                const previous = stores.runtime.get(name);
                const rollback = function () {
                    if (previous) stores.runtime.set(name, previous);
                    markDirty('processes');
                    scheduleRender();
                };
                if (previous && Array.isArray(previous.instanceList)) {
                    stores.runtime.set(name, Object.assign({}, previous, {
                        instanceList: previous.instanceList.filter(function (item) {
                            return Number(item.id) !== id;
                        }),
                    }));
                    markDirty('processes');
                    scheduleRender();
                }
                sendRequest('cancel_instance', { name: name, id: id }).then(function (response) {
                    const result = response.result || {};
                    if (result.error) {
                        rollback();
                        toast(t('requestFailed', { error: result.error }), 'error');
                        return;
                    }
                    toast(t('instanceAborted', { id: id }), 'success');
                }).catch(function (err) {
                    rollback();
                    toast(t('requestFailed', { error: err.message }), 'error');
                });
                return;
            }
            const cancel = event.target.closest('[data-process-cancel]');
            if (cancel) {
                const name = cancel.getAttribute('data-process-cancel');
                const previousRecord = stores.runtime.get(name);
                stores.runtime.delete(name);
                markDirty('processes');
                scheduleRender();
                sendRequest('cancel_process', { name: name })
                    .then(function (response) {
                        const result = response.result || {};
                        if (result.error) {
                            if (previousRecord) stores.runtime.set(name, previousRecord);
                            markDirty('processes');
                            scheduleRender();
                            toast(t('requestFailed', { error: result.error }), 'error');
                            return;
                        }
                        toast(t('processCanceled'), 'success');
                    }).catch(function (err) {
                        if (previousRecord) stores.runtime.set(name, previousRecord);
                        markDirty('processes');
                        scheduleRender();
                        toast(t('requestFailed', { error: err.message }), 'error');
                    });
            }
        });
    }

    function missingDeleteRequest(item) {
        if (item.kind === 'machine') {
            return { action: 'remove_machine_peripheral', payload: { peripheral: item.name } };
        }
        const isSignal = item.kind === 'signal';
        const payload = { name: item.name, force: true };
        if (!isSignal) {
            payload.kind = item.containerKind === 'fluid' ? 'fluid' : 'item';
        }
        return { action: DELETE_ACTION[isSignal ? 'signals' : 'containers'], payload: payload };
    }

    function deleteMissingEntry(item) {
        const request = missingDeleteRequest(item);
        return sendRequest(request.action, request.payload).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return false;
            }
            return true;
        });
    }

    function afterMissingDelete() {
        markDirty('peripherals');
        markDirty('containers');
        markDirty('signals');
        markDirty('missing');
        scheduleRender();
        if (connected) sendRaw({ action: 'full_request' });
    }

    function dropMissingEntry(item) {
        stores.missing.delete(keyOf('missing', item));
    }

    function deleteMissingDefinition(button) {
        const name = button.getAttribute('data-delete-missing');
        const machineKind = button.getAttribute('data-missing-kind') === 'machine';
        const kind = machineKind ? 'machine'
            : (button.getAttribute('data-missing-kind') === 'signals' ? 'signals' : 'containers');
        if (!name) return;
        if (!window.confirm(t(machineKind ? 'missingMachineRemoveConfirm' : 'deleteConfirm',
                { name: unescapeAsciiText(String(name)) }))) return;
        button.disabled = true;
        const entry = {
            name: name,
            kind: kind === 'machine' ? 'machine' : (kind === 'signals' ? 'signal' : 'container'),
            containerKind: button.getAttribute('data-missing-container-kind') === 'fluid' ? 'fluid' : 'item'
        };
        deleteMissingEntry(entry).then(function (ok) {
            if (!ok) {
                button.disabled = false;
                return;
            }
            dropMissingEntry(entry);
            toast(t('missingDeleted', { name: name }), 'success');
            afterMissingDelete();
        }).catch(function (err) {
            button.disabled = false;
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function visibleMissingEntries() {
        const query = parseSearchQuery(peripheralSearchText);
        return Array.from(stores.missing.values()).filter(function (item) {
            return missingMatchesSearch(item, query);
        });
    }

    function deleteAllMissingDefinitions(button) {
        const entries = visibleMissingEntries();
        if (entries.length === 0) return;
        if (!window.confirm(t('missingDeleteAllConfirm', { n: entries.length }))) return;
        button.disabled = true;
        const seen = {};
        const queue = entries.filter(function (item) {
            const key = keyOf('missing', item);
            if (seen[key]) return false;
            seen[key] = true;
            return true;
        });
        let removed = 0;
        let failed = 0;
        const finish = function () {
            button.disabled = false;
            if (failed > 0) {
                toast(t('missingDeletedSome', { deleted: removed, failed: failed }), 'error');
            } else {
                toast(t('missingDeletedAll', { n: removed }), 'success');
            }
            afterMissingDelete();
        };
        Promise.all(queue.map(function (item) {
            return deleteMissingEntry(item).then(function (ok) {
                if (ok) {
                    removed += 1;
                    dropMissingEntry(item);
                } else {
                    failed += 1;
                }
                return null;
            }).catch(function (err) {
                failed += 1;
                toast(t('requestFailed', { error: err.message }), 'error');
                return null;
            });
        })).then(finish, finish);
    }

    function bindDefinitionLists() {
        ['peripheralList', 'machineTypeList', 'storageList', 'inputList', 'outputList', 'missingList'].forEach(function (id) {
            const node = el(id);
            if (node) node.addEventListener('click', handleDefinitionClick);
        });
        el('filterList').addEventListener('click', function (event) {
            const chip = event.target.closest('[data-edit-filter]');
            if (chip) openEditor('filters', chip.getAttribute('data-edit-filter'));
        });
    }

    function handleDefinitionClick(event) {
        {
            const readOnlyCard = event.target.closest('[data-machine-card]');
            if (readOnlyCard && machineIsReadOnly(readOnlyCard.getAttribute('data-machine-card'))) return;
            const removeStorage = event.target.closest('[data-pc-role-remove], [data-pc-storage-remove]');
            if (removeStorage) {
                event.stopPropagation();
                const chip = removeStorage.closest('[data-pc-peripheral]');
                if (chip) {
                    removeStorageContainer(chip.getAttribute('data-edit-container'),
                        chip.getAttribute('data-pc-peripheral'));
                }
                return;
            }
            const removeFromMachine = event.target.closest('[data-pc-remove]');
            if (removeFromMachine) {
                const chip = removeFromMachine.closest('[data-pc-peripheral]');
                if (chip) {
                    removePeripheralFromMachine({
                        peripheral: chip.getAttribute('data-pc-peripheral'),
                        fromMachine: chip.getAttribute('data-pc-machine'),
                        fromSlot: chip.getAttribute('data-pc-slot'),
                        fromKind: chip.getAttribute('data-pc-kind'),
                        fromDef: chip.getAttribute('data-pc-def')
                    });
                }
                return;
            }
            const machineChip = event.target.closest('[data-pc-peripheral][data-pc-machine]');
            if (machineChip) {
                const defName = String(machineChip.getAttribute('data-pc-def') || '');
                if (defName) {
                    openEditor('containers', defName);
                }
                return;
            }
            const machine = event.target.closest('[data-edit-machine]');
            if (machine) {
                openEditor('machines', machine.getAttribute('data-edit-machine'));
                return;
            }
            const addMachine = event.target.closest('[data-add-machine]');
            if (addMachine) {
                const type = String(addMachine.getAttribute('data-add-machine') || '');
                if (!type) {
                    openEditor('machines', null, { type: '', parallel: 1 });
                    return;
                }
                const name = uniqueDefinitionName('machines', type, null);
                const fields = ['itemInputs', 'fluidInputs', 'signals', 'itemOutputs', 'fluidOutputs'];
                const data = { type: type, parallel: 1 };
                fields.forEach(function (field) { data[field] = []; });
                stores.machines.set(name, Object.assign({ name: name, running: 0, usable: true }, data));
                renderPeripherals();
                sendRequest('set_machine', { name: name, data: data }).then(function (response) {
                    const result = response.result || {};
                    if (result.error) {
                        stores.machines.delete(name);
                        renderPeripherals();
                        toast(t('requestFailed', { error: result.error }), 'error');
                        return;
                    }
                    if (result.name && result.name !== name) stores.machines.delete(name);
                    markDirty('machines');
                    scheduleRender();
                    toast(t('machineAdded', { name: result.name || name }), 'success');
                }).catch(function (err) {
                    stores.machines.delete(name);
                    renderPeripherals();
                    toast(t('requestFailed', { error: err.message }), 'error');
                });
                return;
            }
            const machineType = event.target.closest('[data-edit-machine-type]');
            if (machineType) {
                if (machineTypeIsReadOnly(machineType.getAttribute('data-edit-machine-type'))) return;
                openEditor('machineTypes', machineType.getAttribute('data-edit-machine-type'));
                return;
            }
            const removeAllMissing = event.target.closest('[data-delete-missing-all]');
            if (removeAllMissing) {
                deleteAllMissingDefinitions(removeAllMissing);
                return;
            }
            const removeMissing = event.target.closest('[data-delete-missing]');
            if (removeMissing) {
                deleteMissingDefinition(removeMissing);
                return;
            }
            const editContainer = event.target.closest('[data-edit-container]');
            if (editContainer) {
                openEditor('containers', editContainer.getAttribute('data-edit-container'));
                return;
            }
            const editSignal = event.target.closest('[data-edit-signal]');
            if (editSignal) {
                openEditor('signals', editSignal.getAttribute('data-edit-signal'));
                return;
            }
            const newContainer = event.target.closest('[data-new-container]');
            if (newContainer) {
                openEditor('containers', null, {
                    peripheral: newContainer.getAttribute('data-new-container'),
                    kind: newContainer.getAttribute('data-container-kind') === 'fluid' ? 'fluid' : 'item',
                    role: 'storage'
                });
                return;
            }
        }
    }

    let diagnoseBuffer = null;
    let diagnoseTimer = null;
    let diagnoseMode = 'report';
    let diagnoseLastFinish = 0;

    function finishDiagnose() {
        if (diagnoseTimer) { clearTimeout(diagnoseTimer); diagnoseTimer = null; }
        const lines = diagnoseBuffer || [];
        diagnoseBuffer = null;
        diagnoseLastFinish = Date.now();
        const out = el('diagnoseOutput');
        if (out) out.textContent = lines.length > 1 ? lines.join('\n') : '(no output)';
        const hint = el('diagnoseHint');
        if (hint) hint.textContent = t('diagnoseDone', { mode: diagnoseMode, n: lines.length });
        if (diagnoseModalInstance()) diagnoseModalInstance().show();
    }

    function runDiagnose(mode) {
        diagnoseMode = mode || 'report';
        const requestedAt = Date.now();
        const out = el('diagnoseOutput');
        if (out) out.textContent = t('diagnoseRunning');
        if (diagnoseModalInstance()) diagnoseModalInstance().show();
        return sendRequest('diagnose', { mode: diagnoseMode }).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                if (out) out.textContent = 'ERROR: ' + describeMessage(result.error);
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            setTimeout(function () {
                if (diagnoseLastFinish >= requestedAt) return;
                const lines = asArray(result.lines);
                if (out) out.textContent = lines.length ? lines.join('\n') : t('diagnoseNoOutput');
                const hint = el('diagnoseHint');
                if (hint) hint.textContent = t('diagnoseDone', { mode: diagnoseMode, n: lines.length });
            }, 3000);
        }).catch(function (err) {
            if (out) out.textContent = 'ERROR: ' + err.message;
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }
    window.ifmDiagnose = runDiagnose;

    function syncSearchClear(inputId) {
        const input = el(inputId);
        const button = el(inputId + 'Clear');
        if (!button) return;
        const hasText = !!(input && String(input.value || '').length > 0);
        button.style.display = hasText ? '' : 'none';
    }

    function bindSearchClear(inputId, onChange) {
        const input = el(inputId);
        const button = el(inputId + 'Clear');
        if (input) {
            input.addEventListener('input', function () { syncSearchClear(inputId); });
        }
        if (button) {
            button.addEventListener('click', function () {
                if (input) {
                    input.value = '';
                    input.focus();
                }
                syncSearchClear(inputId);
                onChange();
            });
        }
        syncSearchClear(inputId);
    }

    let containerTarget = null;
    // The last container_view that arrived: the slot multiplier editor reads the
    // current override from it.
    let containerToolView = null;

    function containerClaimBadge(claim) {
        if (!claim) return '';
        const dir = claim.dir === 'in' ? t('claimIn') : t('claimOut');
        const colour = claim.dir === 'in' ? '#6fc3ff' : '#e8b23a';
        const title = t('claimTitle', {
            dir: dir,
            n: fmtCount(claim.amount || 0),
            ms: Math.max(0, Math.round((claim.ageMs || 0) / 1000))
        });
        return '<span class="claim-badge" style="color:' + colour + ';border:1px solid ' + colour +
            ';border-radius:3px;padding:0 4px;margin-left:4px;font-size:10px;white-space:nowrap" title="' +
            escapeHtml(title) + '">' + escapeHtml(dir) + '</span>';
    }

    // Every slot carries its own put/take button: manual moves always name the
    // slot they act on (the old "let the device pick" buttons are gone). The
    // buttons are only rendered for containers the backend accepts manual moves
    // on (storage role containers are move sources/targets only, never the tool).
    function currentSlotInfo(slot) {
        if (!containerToolView) return null;
        const list = asArray(containerToolView.slotInfo);
        for (let i = 0; i < list.length; i += 1) {
            if (Math.floor(Number(list[i] && list[i].slot) || 0) === Math.floor(Number(slot) || 0)) {
                return list[i];
            }
        }
        return null;
    }

    // Save a user-set slot multiplier. amount <= 0 (or empty) clears the setting.
    function sendSlotMultiplier(slot, amount, all) {
        if (!containerTarget) return;
        const value = (amount === null || amount === undefined || !isFinite(Number(amount)) || Number(amount) <= 0)
            ? 0 : Math.floor(Number(amount));
        const payload = { name: containerTarget.name, kind: containerTarget.kind, amount: value };
        if (all) payload.all = true;
        else payload.slot = Math.floor(Number(slot) || 0);
        sendRequest('set_slot_multiplier', payload).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('slotMultiplierSaved', {
                value: value > 0 ? fmtCount(value) : t('slotMultiplierCleared')
            }), 'success');
            if (all) {
                const field = el('toolSlotMultAll');
                if (field) field.value = '';
            }
            refreshContainerTool();
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function openSlotMultiplierPrompt(slot) {
        if (!containerTarget) return;
        const info = currentSlotInfo(slot);
        const override = (info && info.override !== undefined && info.override !== null) ? info.override : '';
        openPrompt({
            title: t('slotMultiplierTitlePrompt', { n: slot }),
            label: t('slotMultiplierLabel'),
            value: override,
            min: 0,
            hint: t('slotMultiplierPromptHint'),
            onConfirm: function (value) {
                sendSlotMultiplier(slot, value, false);
            }
        });
    }

    // The capacity multiplier badge of one slot, from the container_view slotInfo:
    // the effective value (user override / scan / 1x default), clickable to edit.
    function slotMultiplierHtml(info) {
        if (!info) return '';
        const slot = Math.floor(Number(info.slot) || 0);
        const multiplier = (info.multiplier === undefined || info.multiplier === null)
            ? null : Number(info.multiplier);
        const limit = (info.limit === undefined || info.limit === null) ? '' : String(info.limit);
        const item = info.item ? String(info.item).split('\u0000').filter(Boolean).join(' @') : '';
        const override = info.override !== undefined && info.override !== null;
        const known = multiplier !== null && isFinite(multiplier);
        const title = t('slotMultiplierTitle', {
            mult: known ? String(Math.round(multiplier * 1000) / 1000) : '?',
            limit: limit || '-',
            item: item || '-'
        }) + ' · ' + (override ? t('slotMultiplierUser') : (known ? t('slotMultiplierAuto') : t('slotMultiplierUnknown')))
            + ' · ' + t('slotMultiplierEditHint');
        const text = known ? '×' + String(Math.round(multiplier * 1000) / 1000) : '×?';
        return '<span class="slot-mult' + (override ? ' user' : '') + '" data-slot-mult="' +
            escapeHtml(String(slot)) + '" title="' + escapeHtml(title) + '">' + escapeHtml(text) + '</span>';
    }

    function containerCellHtml(slot, entry, kind, claim, canMove, info) {
        const head = '<span class="slot-index" title="' + escapeHtml(t('slotNumber', { n: slot })) + '">#' +
            escapeHtml(String(slot)) + '</span>' + slotMultiplierHtml(info);
        const buttons = canMove
            ? '<span class="slot-actions">' +
                '<button class="btn-pixel" type="button" data-put-now="' + escapeHtml(String(slot)) + '" title="' +
                escapeHtml(t('containerPutToSlot', { n: slot })) + '">' + escapeHtml(t('containerPut')) + '</button>' +
                (entry
                    ? '<button class="btn-pixel" type="button" data-take-now="' + escapeHtml(String(entry.slot)) +
                        '" title="' + escapeHtml(t('containerTakeFromSlot', { n: slot })) + '">' +
                        escapeHtml(t('containerTake')) + '</button>'
                    : '') +
                '</span>'
            : '';
        if (!entry) {
            return '<div class="slot-cell empty' + (claim ? ' claimed' : '') + '">' + head +
                containerClaimBadge(claim) +
                '<span class="slot-empty">' + escapeHtml(t('containerEmptySlot')) + '</span>' + buttons + '</div>';
        }
        const isFluid = kind === 'fluid';
        const itemKind = isFluid ? 'fluid' : 'item';
        const name = entry.name;
        const count = isFluid ? entry.amount : entry.count;
        queueMeta(itemKind, name);
        return '<div class="slot-cell' + (claim ? ' claimed' : '') + '" data-take-resource="' + escapeHtml(name) +
            '" data-take-count="' + escapeHtml(String(count || 0)) + '">' + head + containerClaimBadge(claim) +
            '<span class="slot-icon">' + plainIconImg(itemKind, name, entry.nbt) + '</span>' +
            '<span class="slot-name" title="' + escapeHtml(name) + '">' +
            escapeHtml(displayName(itemKind, name)) + '</span>' +
            '<span class="slot-count">' + escapeHtml(fmtCount(count || 0)) + '</span>' +
            buttons +
            '</div>';
    }

    function containerSlotGridHtml(view, canMove) {
        const total = Math.max(0, Math.floor(Number(view.slots) || 0));
        const bySlot = {};
        asArray(view.items).forEach(function (entry) {
            const slot = Math.floor(Number(entry.slot) || 0);
            if (slot > 0) bySlot[slot] = entry;
        });
        const byClaim = {};
        asArray(view.claims && view.claims.slots).forEach(function (claim) {
            const slot = Math.floor(Number(claim.index) || 0);
            if (slot > 0) byClaim[slot] = claim;
        });
        const byInfo = {};
        asArray(view.slotInfo).forEach(function (info) {
            const slot = info ? Math.floor(Number(info.slot) || 0) : 0;
            if (slot > 0) byInfo[slot] = info;
        });
        const cells = [];
        for (let slot = 1; slot <= total; slot += 1) {
            cells.push(containerCellHtml(slot, bySlot[slot], 'item', byClaim[slot], canMove, byInfo[slot]));
        }
        Object.keys(bySlot).map(Number).sort(function (a, b) { return a - b; }).forEach(function (slot) {
            if (slot > total) cells.push(containerCellHtml(slot, bySlot[slot], 'item', byClaim[slot], canMove, byInfo[slot]));
        });
        return '<div class="slot-grid">' + cells.join('') + '</div>';
    }

    function parseContainerKey(key) {
        const text = String(key || '');
        return {
            key: text,
            kind: text.indexOf('fluid:') === 0 ? 'fluid' : 'item',
            name: text.replace(/^(item|fluid):/, '')
        };
    }

    function containerRowHtml(kind, name, count, ref, nbt, claim, claimedCount, canMove, showPut) {
        queueMeta(kind, name);
        const badges = containerClaimBadge(claim) + ((claimedCount || 0) > 0
            ? '<span class="claim-badge" style="color:#e8b23a;border:1px solid #e8b23a;border-radius:3px;' +
                'padding:0 4px;margin-left:4px;font-size:10px;white-space:nowrap" title="' +
                escapeHtml(t('claimSummary')) + '">' +
                escapeHtml(t('claimItemCount', { n: fmtCount(claimedCount || 0) })) + '</span>'
            : '');
        // These rows are tanks / slotless containers. A put button only carries no
        // slot (the device picks the free slot itself); for fluids the put action
        // lives on one container-level button outside the list instead (showPut
        // false), so every fluid row keeps its own 取出 button only.
        const takeButton = canMove
            ? '<button class="btn-pixel" type="button" data-take-now="' + escapeHtml(String(ref)) + '">' +
                escapeHtml(t('containerTake')) + '</button>'
            : '';
        const putButton = (canMove && showPut !== false)
            ? '<button class="btn-pixel" type="button" data-put-now="">' + escapeHtml(t('containerPut')) + '</button>'
            : '';
        const buttons = putButton + takeButton;
        return '<div class="stock-item" data-take-resource="' + escapeHtml(name) + '" data-take-count="' +
            escapeHtml(String(count || 0)) + '">' + badges +
            '<span class="icon">' + plainIconImg(kind, name, nbt) + '</span>' +
            '<span class="stock-name" title="' + escapeHtml(name) + '">' + escapeHtml(displayName(kind, name)) + '</span>' +
            '<span class="stock-count">' + escapeHtml(fmtCount(count || 0)) + '</span>' +
            buttons +
            '</div>';
    }

    function containerClaimListsHtml(view) {
        const claims = (view && view.claims) || {};
        const parts = [];
        const row = function (label, name, claim, kind) {
            const dirs = [];
            if (claim.out) dirs.push(t('claimDirOut', { n: fmtCount(claim.out) }));
            if (claim.inCount) dirs.push(t('claimDirIn', { n: fmtCount(claim.inCount) }));
            parts.push('<div class="claim-list-row">' +
                '<span class="claim-list-kind muted">' + escapeHtml(label) + '</span>' +
                '<span class="claim-list-name" title="' + escapeHtml(String(name || '')) + '">' +
                escapeHtml(displayName(kind, name)) + '</span>' +
                '<span class="muted">' + escapeHtml(dirs.join(' · ')) + '</span></div>');
        };
        asArray(claims.items).forEach(function (claim) {
            row(t('claimItemsLabel'), claim.name, claim, 'item');
        });
        asArray(claims.fluids).forEach(function (claim) {
            row(t('claimFluidsLabel'), claim.name, claim, 'fluid');
        });
        if (parts.length === 0) return '';
        return '<div class="claim-list">' + parts.join('') + '</div>';
    }

    function renderContainerTool(view) {
        const meta = el('toolMeta');
        const hint = el('toolHint');
        if (view && !view.error) containerToolView = view;
        const role = view && !view.error ? String(view.role || '') : '';
        // Storage containers can never be the manual move source or target (the
        // backend role rules reject it), so the put/take block is hidden for them.
        const storageOnly = role === 'storage';
        if (hint) hint.textContent = storageOnly ? t('containerToolStorage') : t('containerTool');
        const moveBlock = el('toolMoveBlock');
        if (moveBlock) moveBlock.style.display = storageOnly ? 'none' : '';
        // The resource field and the stock modal button must offer the same resource
        // kind as the container, so both learn it from the view instead of the
        // markup (the field's autocomplete reads data-stock-kind too).
        const kind = view && !view.error && view.kind === 'fluid' ? 'fluid' : 'item';
        const pickButton = el('toolResourcePick');
        if (pickButton) pickButton.setAttribute('data-stock-kind', kind);
        const resourceField = el('toolResource');
        if (resourceField) resourceField.setAttribute('data-stock-kind', kind);
        // Fluids have no slot cell, so their one 放入 button sits outside the list
        // (shown only for a movable fluid container).
        const putRow = el('toolPutRow');
        if (putRow) {
            putRow.style.display = (!storageOnly && view && !view.error && kind === 'fluid') ? '' : 'none';
        }
        // The container-wide slot multiplier control only makes sense for item slots.
        const multRow = el('toolSlotMultRow');
        if (multRow) {
            multRow.style.display = (view && !view.error && kind === 'item') ? '' : 'none';
        }
        const canMove = !storageOnly && !!view && !view.error;
        const contents = el('toolContents');
        if (!meta || !contents) return;
        if (!view || view.error) {
            meta.innerHTML = '<div class="muted">' + escapeHtml((view && view.error) || '…') + '</div>';
        } else {
            const rows = [];
            const addRow = function (key, value, bad) {
                rows.push('<div class="info-row"><span class="info-key">' + escapeHtml(key) + '</span>' +
                    '<span class="info-value' + (bad ? ' bad' : '') + '">' + escapeHtml(value) + '</span></div>');
            };
            addRow(t('peripheral'), view.peripheral || '-');
            addRow(t('role'), roleLabel(view.role || ''));
            addRow(t('containerKind'), view.kind === 'fluid' ? t('fluidContainer') : t('itemContainer'));
            if (view.kind === 'item' && view.slots) {
                addRow(t('slot'), t('containerSlots', { used: asArray(view.items).length, total: view.slots }));
            }
            if (view.usable === false) {
                addRow(t('tipState'), t('containerUnusable', { reason: describeMessage(view.problem) || '-' }), true);
            }
            const manual = view.manual || null;
            if (manual) {
                // A manual move runs exactly once: this is where its outcome shows
                // up (success, failure reason or the timeout note).
                const dirLabel = manual.dir === 'out' ? t('containerTake') : t('containerPut');
                const text = manual.ok
                    ? dirLabel + ' · ' + t('containerMoved', { n: fmtCount(manual.moved || 0) })
                    : dirLabel + ' · ' + (manual.reason || t('noData'));
                addRow(t('containerManualLast'), text, !manual.ok);
            }
            const claimInfo = view.claims || {};
            const claimSummary = claimInfo.summary || null;
            if (claimSummary && (claimSummary.slots || claimSummary.tanks || claimSummary.items ||
                claimSummary.inFlight)) {
                addRow(t('claimSummary'), t('claimSummaryValue', {
                    slots: claimSummary.slots || 0,
                    items: claimSummary.items || 0,
                    fluids: claimSummary.fluids || 0,
                    inflight: claimSummary.inFlight || 0,
                    oldest: Math.round((claimSummary.oldestMs || 0) / 1000)
                }), true);
            }
            meta.innerHTML = rows.join('');
        }
        if (!view || view.error) {
            contents.innerHTML = '<span class="muted">' + escapeHtml((view && view.error) || t('noData')) + '</span>';
            return;
        }
        const claimLists = containerClaimListsHtml(view);
        if (view.kind === 'item' && Math.floor(Number(view.slots) || 0) > 0) {
            contents.innerHTML = claimLists + containerSlotGridHtml(view, canMove);
        } else {
            const rows = [];
            const claimList = (view.claims || {});
            const claimsByFluid = {};
            const claimsByItem = {};
            asArray(claimList.fluids).forEach(function (claim) {
                claimsByFluid[String(claim.name || '')] = claim;
            });
            asArray(claimList.items).forEach(function (claim) {
                claimsByItem[String(claim.name) + '|' + String(claim.nbt || '')] =
                    (claim.out || 0) + (claim.inCount || 0);
            });
            asArray(view.items).forEach(function (entry) {
                rows.push(containerRowHtml('item', entry.name, entry.count, entry.slot, entry.nbt, null,
                    claimsByItem[String(entry.name) + '|' + String(entry.nbt || '')] || 0, canMove));
            });
            asArray(view.fluids).forEach(function (entry) {
                // showPut = false: a fluid row only takes; the single 放入 button
                // lives on the container-level control (toolPutRow).
                rows.push(containerRowHtml('fluid', entry.name, entry.amount, entry.tank, null,
                    claimsByFluid[String(entry.name || '')], 0, canMove, false));
            });
            contents.innerHTML = claimLists + (rows.length
                ? '<div class="stock-list">' + rows.join('') + '</div>'
                : '<span class="muted">' + escapeHtml(t('containerEmpty')) + '</span>');
        }
    }

    window.ifmContainerToolMount = function (key, peripheralHint) {
        // The tool identifies a container by its peripheral name: that is the only
        // stable handle (a definition's name changes with its role, and existing
        // machine / process references are not rewritten when that happens).
        const text = key ? String(key) : '';
        const def = text ? containerByName(text) : null;
        const parsed = text ? parseContainerKey(text) : null;
        const peripheral = String((def && def.peripheral) || peripheralHint || text || '');
        containerTarget = text
            ? {
                key: text,
                peripheral: peripheral,
                kind: def ? (def.kind === 'fluid' ? 'fluid' : 'item') : (parsed.kind || 'item'),
                name: def ? String(def.name || '') : (parsed.name || text)
            }
            : null;
        const input = el('toolResource');
        if (input) input.value = '';
        const nbtInput = el('toolNbt');
        if (nbtInput) nbtInput.value = '';
        syncSearchClear('toolResource');
        if (!containerTarget) {
            stopContainerToolPolling();
            return;
        }
        renderContainerTool(null);
        refreshContainerTool(true);
        // Polling container_view while the tool is open doubles as the "keep
        // scanning this container" lease for the backend: the master only scans
        // interaction containers that an active process instance needs, or that
        // the manual tool is watching.
        startContainerToolPolling();
        setTimeout(function () { if (containerTarget) refreshContainerTool(); }, 800);
    };

    const CONTAINER_TOOL_POLL_MS = 2000;
    let containerToolTimer = null;

    function startContainerToolPolling() {
        stopContainerToolPolling();
        if (!containerTarget) return;
        containerToolTimer = setInterval(refreshContainerTool, CONTAINER_TOOL_POLL_MS);
    }

    function stopContainerToolPolling() {
        if (containerToolTimer) {
            clearInterval(containerToolTimer);
            containerToolTimer = null;
        }
    }

    if (el('editorModal')) {
        el('editorModal').addEventListener('hidden.bs.modal', function () {
            stopContainerToolPolling();
        });
    }

    // The poll above fires every 2s, so with the 3s request timeout one stalled
    // master would otherwise turn into an error toast every other second. Only
    // the first failure of a storm is announced; an explicit refresh button press
    // always reports its own result.
    let containerToolErrorAt = 0;

    function refreshContainerTool(showBusy) {
        if (!containerTarget) return;
        const meta = el('toolMeta');
        if (meta && showBusy) meta.innerHTML = '<div class="muted">…</div>';
        sendRequest('container_view', {
            name: containerTarget.name,
            kind: containerTarget.kind,
            key: containerTarget.key,
            peripheral: containerTarget.peripheral
        }).then(function (response) {
            const result = response.result || {};
            if (!result.error && result.name && result.kind) {
                containerTarget.name = result.name;
                containerTarget.kind = result.kind;
            }
            if (!result.error && result.peripheral) {
                containerTarget.peripheral = String(result.peripheral);
            }
            containerToolErrorAt = 0;
            renderContainerTool(result);
        }).catch(function (err) {
            const recent = containerToolErrorAt > 0 &&
                (Date.now() - containerToolErrorAt) < CONTAINER_TOOL_POLL_MS * 5;
            if (!showBusy && recent) {
                serverLog('[IFM] container_view poll failed: ' + err.message);
                return;
            }
            containerToolErrorAt = Date.now();
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    // Clicking a row still fills the resource/count fields; the slot buttons just
    // call the move with the slot they belong to.
    function fillToolRow(row) {
        if (!row) return;
        const field = el('toolResource');
        if (field) field.value = row.getAttribute('data-take-resource') || '';
        const countField = el('toolCount');
        if (countField) countField.value = row.getAttribute('data-take-count') || '1';
        syncSearchClear('toolResource');
    }

    function slotOfButton(button, attribute) {
        if (!button) return null;
        const raw = String(button.getAttribute(attribute) || '');
        if (raw === '') return null;
        const value = Math.floor(Number(raw));
        return isFinite(value) && value >= 1 ? value : null;
    }

    function containerMoveRequest(dir, slot) {
        if (!containerTarget) return;
        const input = el('toolResource');
        const resource = String((input && input.value) || '').trim();
        const countField = el('toolCount');
        const count = Math.max(1, Math.floor(Number(countField ? countField.value : 1) || 1));
        if (!resource) {
            toast(t('containerTakeHint'), 'error');
            if (input) input.focus();
            return;
        }
        const payload = {
            name: containerTarget.name,
            kind: containerTarget.kind,
            key: containerTarget.key,
            peripheral: containerTarget.peripheral,
            resource: resource,
            count: count
        };
        const nbtField = el('toolNbt');
        const nbt = String((nbtField && nbtField.value) || '').trim();
        if (nbt) {
            // Optional hash: only stacks with that exact NBT take part.
            payload.nbt = nbt;
        }
        const slotNumber = Math.floor(Number(slot));
        if (isFinite(slotNumber) && slotNumber >= 1) {
            // The slot only means something for items: it is the slot inside this
            // container (put) or the one the item is taken from (take). Fluids
            // ignore it.
            payload.slot = slotNumber;
        }
        const action = dir === 'in' ? 'container_put' : 'container_take';
        sendRequest(action, payload).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            const moved = result.moved || 0;
            if (result.queued) {
                toast(t('containerQueued', { n: fmtCount(count) }), 'info');
                refreshContainerTool();
                setTimeout(function () { refreshContainerTool(); }, 600);
                return;
            }
            toast(t('containerMoved', { n: fmtCount(moved) }) + (result.reason ? ' · ' + describeMessage(result.reason) : ''),
                moved > 0 ? 'success' : 'info');
            refreshContainerTool();
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    let dragPayload = null;

    function peripheralCapabilities(peripheralName) {
        const caps = {};
        Array.from(stores.peripherals.values()).forEach(function (item) {
            if (item.name === peripheralName && item.kind) caps[item.kind] = true;
        });
        return caps;
    }

    function ensureMachineContainer(peripheral, kind) {
        const name = String(peripheral).replace(/^(item|fluid):/, '');
        const existing = containerByName(name, kind);
        if (existing && existing.role === 'interaction') {
            return Promise.resolve(name);
        }
        const request = {
            name: name,
            data: {
                peripheral: peripheral,
                kind: kind,
                role: 'interaction',
                priority: existing ? Number(existing.priority || 0) : 0
            }
        };
        if (existing) request.previous = containerKeyOf(existing);
        return sendRequest('set_container', request).then(function (response) {
            const result = response.result || {};
            if (result.error) throw new Error(describeMessage(result.error));
            const optimistic = Object.assign({}, existing || {}, {
                name: name, peripheral: peripheral, kind: kind, role: 'interaction',
                priority: existing ? Number(existing.priority || 0) : 0
            });
            const key = containerKeyOf(optimistic);
            if (!stores.containers.has(key)) {
                stores.containers.set(key, optimistic);
                markDirty('containers');
                scheduleRender();
            }
            return name;
        });
    }

    function ensureMachineSignal(peripheral) {
        return Promise.resolve(String(peripheral));
    }

    function machinePayload(machine) {
        return {
            type: machine.type || '',
            itemInputs: asArray(machine.itemInputs).slice(),
            fluidInputs: asArray(machine.fluidInputs).slice(),
            signals: asArray(machine.signals).slice(),
            itemOutputs: asArray(machine.itemOutputs).slice(),
            fluidOutputs: asArray(machine.fluidOutputs).slice(),
            parallel: Math.max(1, Math.round(Number(machine.parallel) || 1))
        };
    }

    function updateMachine(machineName, mutate, successText) {
        const machine = stores.machines.get(machineName);
        if (!machine) return Promise.resolve(false);
        const before = machinePayload(machine);
        const data = machinePayload(machine);
        mutate(data);
        stores.machines.set(machineName, Object.assign({}, machine, data));
        renderPeripherals();
        renderSendContainerSelect();
        return sendRequest('set_machine', { name: machineName, data: data, previous: machineName })
            .then(function (response) {
                const result = response.result || {};
                if (result.error) {
                    stores.machines.set(machineName, Object.assign({}, machine, before));
                    renderPeripherals();
                    toast(t('requestFailed', { error: result.error }), 'error');
                    return false;
                }
                markDirty('machines');
                scheduleRender();
                if (successText) toast(successText, 'success');
                return true;
            })
            .catch(function (err) {
                stores.machines.set(machineName, Object.assign({}, machine, before));
                renderPeripherals();
                toast(t('requestFailed', { error: err.message }), 'error');
                return false;
            });
    }

    function machineSlotField(slot, kind) {
        if (slot === 'signal') return 'signals';
        if (slot === 'in') return kind === 'fluid' ? 'fluidInputs' : 'itemInputs';
        return kind === 'fluid' ? 'fluidOutputs' : 'itemOutputs';
    }

    function removePeripheralFromMachine(payload, quiet) {
        const fromMachine = payload.fromMachine || payload.machine;
        const slot = payload.fromSlot || payload.slot;
        const kind = payload.fromKind || payload.kind;
        const defName = payload.fromDef || payload.def;
        const field = machineSlotField(slot, kind);
        return updateMachine(fromMachine, function (data) {
            data[field] = data[field].filter(function (name) { return name !== defName; });
        }, quiet ? null : t('machinePeripheralRemoved', {
            name: payload.peripheral || defName,
            machine: fromMachine
        }));
    }

    function addPeripheralToMachine(machineName, slot, peripheral, dragKind, quiet) {
        const warn = function (key, params) {
            if (!quiet) toast(t(key, params), 'error');
        };
        const caps = peripheralCapabilities(peripheral);
        if (slot === 'signal' && !caps.redstone_relay) {
            warn('machineSlotNeedSignal', { name: peripheral });
            return Promise.resolve(false);
        }
        if (slot !== 'signal' && dragKind === 'signal') {
            warn('machineSlotNeedContainer', { name: peripheral });
            return Promise.resolve(false);
        }
        if (slot === 'signal' && dragKind && dragKind !== 'signal') {
            warn('machineSlotNeedSignal', { name: peripheral });
            return Promise.resolve(false);
        }
        if (slot !== 'signal' && !dragKind && !caps.inventory && !caps.fluid_storage) {
            warn('machineSlotNeedContainer', { name: peripheral });
            return Promise.resolve(false);
        }
        const kinds = slot === 'signal'
            ? ['signal']
            : (dragKind
                ? [dragKind === 'fluid' ? 'fluid' : 'item']
                : (caps.inventory && caps.fluid_storage ? ['item', 'fluid'] : (caps.inventory ? ['item'] : ['fluid'])));
        return Promise.all(kinds.map(function (kind) {
            return kind === 'signal'
                ? ensureMachineSignal(peripheral)
                : ensureMachineContainer(peripheral, kind);
        })).then(function (defNames) {
            return updateMachine(machineName, function (data) {
                kinds.forEach(function (kind, index) {
                    const field = machineSlotField(slot, kind);
                    const defName = defNames[index];
                    if (data[field].indexOf(defName) < 0) {
                        data[field].push(defName);
                    }
                });
            }, quiet ? null : t('machinePeripheralAdded', { name: peripheral, machine: machineName }));
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
            return false;
        });
    }

    function dragAcceptable(target, payload) {
        const caps = peripheralCapabilities(payload.peripheral);
        const kind = payload.dragKind === 'signal'
            ? 'signal'
            : (payload.dragKind ? payload.dragKind : (caps.inventory && !caps.fluid_storage ? 'item'
                : (caps.fluid_storage && !caps.inventory ? 'fluid' : null)));
        const containerTargets = [
            ['data-storage-drop', 'storage'],
            ['data-input-drop', 'input'],
            ['data-output-drop', 'output'],
        ];
        for (let i = 0; i < containerTargets.length; i += 1) {
            const mark = target.getAttribute(containerTargets[i][0]);
            if (!mark) continue;
            if (kind === 'signal') return false;
            if (mark === 'any') {
                return kind !== null || !!caps.inventory || !!caps.fluid_storage;
            }
            return kind !== null && kind === (mark === 'fluid' ? 'fluid' : 'item');
        }
        const machineSlotId = target.getAttribute('data-machine-slot');
        if (machineSlotId && machineIsReadOnly(target.getAttribute('data-machine'))) return false;
        const slotId = target.getAttribute('data-machine-slot');
        if (!slotId) return false;
        if (slotId === 'signal') {
            return kind === 'signal' || (kind === null && !!caps.redstone_relay);
        }
        if (kind === 'signal') return false;
        return kind !== null || !!caps.inventory || !!caps.fluid_storage;
    }

    function clearDropHighlight() {
        Array.prototype.forEach.call(document.querySelectorAll('.drop-active, .drop-ok'), function (node) {
            node.classList.remove('drop-active');
            node.classList.remove('drop-ok');
        });
    }

    function markDropTargets(payload) {
        const nodes = document.querySelectorAll('[data-machine-slot], [data-storage-drop], [data-input-drop], [data-output-drop]');
        Array.prototype.forEach.call(nodes, function (node) {
            node.classList.toggle('drop-ok', dragAcceptable(node, payload));
        });
    }

    function bindPeripheralSelection() {
        const SELECTABLE_PANEL_SELECTOR = '.panel.peripheral-panel';
        const HIT_SELECTOR = SELECTABLE_PANEL_SELECTOR + ' .chip[data-drag-peripheral], ' +
            SELECTABLE_PANEL_SELECTOR + ' .pc-chip[data-pc-peripheral]';
        const panelOf = function (node) {
            if (!node || !node.closest) return null;
            return node.closest(SELECTABLE_PANEL_SELECTOR);
        };
        const chipUnder = function (node) {
            return node && node.closest ? node.closest(HIT_SELECTOR) : null;
        };
        const chipName = function (chip) {
            if (!chip || !chip.getAttribute) return '';
            const machine = chip.getAttribute('data-pc-peripheral');
            const value = machine !== null && machine !== '' ? machine : chip.getAttribute('data-drag-peripheral');
            return String(value || '');
        };

        document.addEventListener('click', function (event) {
            if (!event.ctrlKey && !event.metaKey) return;
            if (!panelOf(event.target)) return;
            const name = chipName(chipUnder(event.target));
            if (!name) return;
            event.preventDefault();
            event.stopPropagation();
            if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
            togglePeripheralSelection(name);
        }, true);

        document.addEventListener('click', function (event) {
            if (event.ctrlKey || event.metaKey) return;
            if (!panelOf(event.target)) return;
            if (chipUnder(event.target)) return;
            clearPeripheralSelection();
        });

        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') clearPeripheralSelection();
        });

        let marquee = null;
        const marqueeNode = function () {
            let node = el('selectMarquee');
            if (!node) {
                node = document.createElement('div');
                node.id = 'selectMarquee';
                document.body.appendChild(node);
            }
            return node;
        };
        const hideMarquee = function () {
            const node = el('selectMarquee');
            if (node) node.style.display = 'none';
        };
        const clearMarqueeHits = function () {
            Array.prototype.forEach.call(document.querySelectorAll('.marquee-hit'), function (chip) {
                chip.classList.remove('marquee-hit');
            });
        };
        const updateMarquee = function (event) {
            if (!marquee) return;
            const left = Math.min(marquee.startX, event.clientX);
            const top = Math.min(marquee.startY, event.clientY);
            const width = Math.abs(event.clientX - marquee.startX);
            const height = Math.abs(event.clientY - marquee.startY);
            const node = marqueeNode();
            node.style.display = 'block';
            node.style.left = left + 'px';
            node.style.top = top + 'px';
            node.style.width = width + 'px';
            node.style.height = height + 'px';
            const box = { left: left, top: top, right: left + width, bottom: top + height };
            Array.prototype.forEach.call(document.querySelectorAll(HIT_SELECTOR), function (chip) {
                const rect = chip.getBoundingClientRect();
                const hit = !(rect.right < box.left || rect.left > box.right ||
                    rect.bottom < box.top || rect.top > box.bottom);
                chip.classList.toggle('marquee-hit', hit);
            });
        };
        const finishMarquee = function (event) {
            if (!marquee) return;
            const additive = marquee.additive || event.ctrlKey || event.metaKey;
            const hits = [];
            Array.prototype.forEach.call(document.querySelectorAll(HIT_SELECTOR), function (chip) {
                if (!chip.classList.contains('marquee-hit')) return;
                const name = chipName(chip);
                if (name) hits.push(name);
            });
            marquee = null;
            hideMarquee();
            clearMarqueeHits();
            setPeripheralSelection(hits, additive);
        };

        document.addEventListener('mousedown', function (event) {
            if (event.button !== 2 || !panelOf(event.target)) return;
            event.preventDefault();
            event.stopPropagation();
            marquee = { startX: event.clientX, startY: event.clientY, additive: event.ctrlKey || event.metaKey };
            updateMarquee(event);
        }, true);
        document.addEventListener('mousemove', function (event) {
            if (!marquee) return;
            updateMarquee(event);
        }, true);
        document.addEventListener('mouseup', function (event) {
            if (!marquee || event.button !== 2) return;
            finishMarquee(event);
        }, true);
        document.addEventListener('contextmenu', function (event) {
            if (marquee || panelOf(event.target)) event.preventDefault();
        }, true);
    }

    function dragPeripheralList(payload) {
        const out = [{ peripheral: payload.peripheral, dragKind: payload.dragKind }];
        if (!payload.peripheral || selectedPeripheralCards.size < 2) return out;
        if (!selectedPeripheralCards.has(String(payload.peripheral))) return out;
        selectedPeripheralCards.forEach(function (name) {
            if (String(name) !== String(payload.peripheral)) {
                out.push({ peripheral: name, dragKind: null });
            }
        });
        return out;
    }

    function addPeripheralsToMachine(machineName, slot, entries) {
        let chain = Promise.resolve();
        let added = 0;
        let skipped = 0;
        entries.forEach(function (entry) {
            chain = chain.then(function () {
                const caps = peripheralCapabilities(entry.peripheral);
                const acceptable = slot === 'signal'
                    ? (!!caps.redstone_relay && (entry.dragKind === 'signal' || !entry.dragKind))
                    : (entry.dragKind !== 'signal' &&
                        (entry.dragKind === 'item' || entry.dragKind === 'fluid' ||
                            !!caps.inventory || !!caps.fluid_storage));
                if (!acceptable) {
                    skipped += 1;
                    return null;
                }
                const quiet = added > 0;
                return addPeripheralToMachine(machineName, slot, entry.peripheral, entry.dragKind, quiet)
                    .then(function (ok) {
                        if (ok) added += 1; else skipped += 1;
                        return null;
                    });
            });
        });
        return chain.then(function () {
            if (entries.length > 1 || (added === 0 && skipped > 0)) {
                if (added > 0) {
                    toast(t('machinePeripheralsAdded', { n: added, machine: machineName }) +
                        (skipped > 0 ? ' · ' + t('machinePeripheralsSkipped', { n: skipped }) : ''), 'info');
                } else {
                    toast(t('machinePeripheralsNone', { machine: machineName }), 'error');
                }
            }
            return added > 0;
        });
    }

    function bindPeripheralDrag() {
        const clearHighlight = clearDropHighlight;
        // Native HTML5 drag & drop is deliberately not used here: during a drag
        // session the browser swallows the wheel, so the page cannot be scrolled
        // while a peripheral card is being carried around. A pointer based drag
        // keeps the wheel (and touch) working; the drop semantics are unchanged.
        const payloadOf = function (node) {
            if (!node || !node.closest) return null;
            const card = node.closest('[data-drag-peripheral]');
            const chip = node.closest('[data-pc-peripheral]');
            if (!card && !chip) return null;
            if (chip && chip.getAttribute('data-pc-readonly')) return null;
            const payload = card
                ? { peripheral: card.getAttribute('data-drag-peripheral'), fromMachine: null, fromSlot: null,
                    fromKind: null, fromDef: null, fromStorage: card.getAttribute('data-pc-storage'),
                    dragKind: card.getAttribute('data-drag-kind'),
                    fromKey: card.getAttribute('data-drag-def') }
                : { peripheral: chip.getAttribute('data-pc-peripheral'),
                    fromMachine: chip.getAttribute('data-pc-machine'),
                    fromSlot: chip.getAttribute('data-pc-slot'),
                    fromKind: chip.getAttribute('data-pc-kind'),
                    fromDef: chip.getAttribute('data-pc-def'),
                    fromStorage: chip.getAttribute('data-pc-storage'),
                    fromContainerRole: chip.getAttribute('data-pc-role') ||
                        (chip.getAttribute('data-pc-storage') ? 'storage' : null),
                    dragKind: chip.getAttribute('data-pc-kind'),
                    fromKey: chip.getAttribute('data-edit-container') };
            payload.dropped = false;
            payload.node = card || chip;
            return payload;
        };
        const dropTargetAt = function (x, y) {
            const node = document.elementFromPoint(x, y);
            if (!node || !node.closest) return null;
            return node.closest('[data-machine-slot]') ||
                node.closest('[data-storage-drop]') || node.closest('[data-input-drop]') ||
                node.closest('[data-output-drop]');
        };
        const highlightDropTarget = function (target, payload) {
            if (!target) return;
            if (dragAcceptable(target, payload)) {
                if (!target.classList.contains('drop-active')) {
                    Array.prototype.forEach.call(document.querySelectorAll('.drop-active'), function (node) {
                        node.classList.remove('drop-active');
                    });
                    target.classList.add('drop-active');
                }
            } else if (target.classList.contains('drop-active')) {
                target.classList.remove('drop-active');
            }
        };
        const finishDrag = function () {
            clearHighlight();
            Array.prototype.forEach.call(document.querySelectorAll('.dragging'), function (node) {
                node.classList.remove('dragging');
            });
            document.body.classList.remove('ifm-dragging');
        };
        const applyDrop = function (target, payload) {
            const slot = target.closest('[data-machine-slot]');
            const containerCard = target.closest('[data-storage-drop]') ||
                target.closest('[data-input-drop]') || target.closest('[data-output-drop]');
            if (!slot && !containerCard) return;
            payload.dropped = true;
            clearHighlight();
            if (slot && machineIsReadOnly(slot.getAttribute('data-machine'))) return;
            if (containerCard) {
                const role = containerCard.getAttribute('data-storage-drop') ? 'storage'
                    : (containerCard.getAttribute('data-input-drop') ? 'input' : 'output');
                const kind = containerDropKind(containerCard, role, payload);
                if (!kind) {
                    toast(t('storageNeedKind', {
                        name: payload.peripheral,
                        kind: t('itemContainer')
                    }), 'error');
                    return;
                }
                if (payload.fromContainerRole === role && dragPeripheralList(payload).length < 2) {
                    return;
                }
                if (role === 'output') {
                    if (dragPeripheralList(payload).length > 1) {
                        toast(t('containerRoleOneByOne'), 'info');
                    }
                    openContainerForRole(role, kind, payload.peripheral);
                    return;
                }
                const entries = dragPeripheralList(payload);
                if (payload.fromMachine) {
                    removePeripheralFromMachine(payload, true).then(function () {
                        addPeripheralsToContainerRole(role, entries);
                    });
                    return;
                }
                addPeripheralsToContainerRole(role, entries);
                return;
            }
            const machineName = slot.getAttribute('data-machine');
            const slotId = slot.getAttribute('data-machine-slot');
            const batch = dragPeripheralList(payload);
            if (payload.fromMachine) {
                if (payload.fromMachine === machineName && payload.fromSlot === slotId &&
                    batch.length < 2) {
                    return;
                }
                addPeripheralsToMachine(machineName, slotId, batch).then(function (ok) {
                    if (ok && payload.fromMachine !== machineName) {
                        toast(t('machinePeripheralShared', {
                            name: payload.peripheral, machine: machineName
                        }), 'info');
                    }
                });
                return;
            }
            addPeripheralsToMachine(machineName, slotId, batch);
        };
        let dragState = null;
        let suppressClick = false;
        // A pointer drag ends with a click event on the card (native drag & drop
        // used to swallow it); that click must not open the editor.
        document.addEventListener('click', function (event) {
            if (!suppressClick) return;
            suppressClick = false;
            event.stopPropagation();
            event.preventDefault();
        }, true);
        document.addEventListener('pointerdown', function (event) {
            if (event.button !== 0 || dragState) return;
            const payload = payloadOf(event.target);
            if (!payload) return;
            dragState = { payload: payload, startX: event.clientX, startY: event.clientY,
                active: false, pointerId: event.pointerId };
        }, true);
        document.addEventListener('pointermove', function (event) {
            if (!dragState || event.pointerId !== dragState.pointerId) return;
            const payload = dragState.payload;
            if (!dragState.active) {
                const dx = event.clientX - dragState.startX;
                const dy = event.clientY - dragState.startY;
                if (dx * dx + dy * dy < 16) return;
                dragState.active = true;
                dragPayload = payload;
                if (payload.node) payload.node.classList.add('dragging');
                document.body.classList.add('ifm-dragging');
                markDropTargets(payload);
            }
            // The wheel has to keep working while a card is carried (that is the
            // whole point of not using HTML5 drag & drop), so this only suppresses
            // text selection / native touch scrolling.
            event.preventDefault();
            highlightDropTarget(dropTargetAt(event.clientX, event.clientY), payload);
        });
        const endDrag = function (event, canceled) {
            if (!dragState || (event.pointerId !== undefined && event.pointerId !== dragState.pointerId)) return;
            const state = dragState;
            dragState = null;
            dragPayload = null;
            const target = (state.active && !canceled) ? dropTargetAt(event.clientX, event.clientY) : null;
            finishDrag();
            if (!state.active) return;
            suppressClick = true;
            const payload = state.payload;
            if (target) {
                applyDrop(target, payload);
                return;
            }
            if (canceled) return;
            // Released over empty space: the card / chip leaves where it came from,
            // exactly like a dragend without a drop used to behave.
            if (payload.fromMachine) {
                removePeripheralFromMachine(payload);
                return;
            }
            if (payload.fromContainerRole || payload.fromStorage) {
                removeStorageContainer(payload.fromKey, payload.peripheral);
            }
        };
        document.addEventListener('pointerup', function (event) { endDrag(event, false); });
        document.addEventListener('pointercancel', function (event) { endDrag(event, true); });
    }

    function containerDropKind(card, role, payload) {
        const mark = card.getAttribute('data-' + role + '-drop');
        if (mark === 'item' || mark === 'fluid') return mark;
        if (payload.dragKind === 'item' || payload.dragKind === 'fluid') return payload.dragKind;
        if (payload.fromKind === 'item' || payload.fromKind === 'fluid') return payload.fromKind;
        const caps = peripheralCapabilities(payload.peripheral);
        if (caps.inventory) return 'item';
        if (caps.fluid_storage) return 'fluid';
        return null;
    }

    function openContainerForRole(role, kind, peripheral) {
        const name = String(peripheral).replace(/^(item|fluid):/, '');
        const existing = containerByName(name, kind);
        if (existing) {
            openEditor('containers', containerKeyOf(existing));
            return;
        }
        openEditor('containers', null, { peripheral: peripheral, kind: kind, role: role, priority: 0 });
        toast(t('containerDefineHint', { name: peripheral, role: t(roleLabel(role)) }), 'info');
    }

    function addPeripheralToContainerRole(role, kind, peripheral, quiet) {
        const caps = peripheralCapabilities(peripheral);
        const capability = kind === 'fluid' ? 'fluid_storage' : 'inventory';
        const kindLabel = t(kind === 'fluid' ? 'fluidContainer' : 'itemContainer');
        if (!caps[capability]) {
            if (!quiet) toast(t('storageNeedKind', { name: peripheral, kind: kindLabel }), 'error');
            return Promise.resolve(false);
        }
        const name = String(peripheral).replace(/^(item|fluid):/, '');
        const existing = containerByName(name, kind);
        const priority = existing ? Number(existing.priority || 0) : 0;
        const request = {
            name: name,
            data: { peripheral: peripheral, kind: kind, role: role, priority: priority }
        };
        if (existing) request.previous = containerKeyOf(existing);
        return sendRequest('set_container', request).then(function (response) {
            const result = response.result || {};
            if (result.error) throw new Error(describeMessage(result.error));
            const optimistic = Object.assign({}, existing || {}, {
                name: name, peripheral: peripheral, kind: kind, role: role, priority: priority
            });
            stores.containers.set(containerKeyOf(optimistic), optimistic);
            markDirty('containers');
            renderPeripherals();
            if (!quiet) {
                toast(t('containerRoleSet', {
                    name: peripheral,
                    kind: kindLabel,
                    role: roleLabel(role)
                }), 'success');
            }
            return true;
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
            return false;
        });
    }

    function addPeripheralsToContainerRole(role, entries) {
        let chain = Promise.resolve();
        let added = 0;
        let skipped = 0;
        entries.forEach(function (entry) {
            chain = chain.then(function () {
                const caps = peripheralCapabilities(entry.peripheral);
                const kind = entry.dragKind === 'fluid' || entry.dragKind === 'item'
                    ? entry.dragKind
                    : (caps.inventory ? 'item' : (caps.fluid_storage ? 'fluid' : null));
                if (!kind) {
                    skipped += 1;
                    return null;
                }
                const quiet = added > 0;
                return addPeripheralToContainerRole(role, kind, entry.peripheral, quiet).then(function (ok) {
                    if (ok) added += 1; else skipped += 1;
                    return null;
                });
            });
        });
        return chain.then(function () {
            if (entries.length > 1 || (added === 0 && skipped > 0)) {
                if (added > 0) {
                    toast(t('containerRoleAdded', { n: added, role: roleLabel(role) }) +
                        (skipped > 0 ? ' · ' + t('machinePeripheralsSkipped', { n: skipped }) : ''), 'info');
                } else {
                    toast(t('machinePeripheralsNone', { machine: roleLabel(role) }), 'error');
                }
            }
            return added > 0;
        });
    }

    function addPeripheralToStorage(kind, peripheral) {
        return addPeripheralToContainerRole('storage', kind, peripheral);
    }

    function removeStorageContainer(defKey, peripheral) {
        const before = defKey ? stores.containers.get(defKey) : null;
        if (!before) return Promise.resolve(false);
        stores.containers.delete(defKey);
        markDirty('containers');
        renderPeripherals();
        return sendRequest('delete_container', { name: before.name, kind: before.kind, force: true })
            .then(function (response) {
                const result = response.result || {};
                if (result.error) {
                    stores.containers.set(defKey, before);
                    renderPeripherals();
                    toast(t('requestFailed', { error: result.error }), 'error');
                    return false;
                }
                toast(t('storageRemoved', { name: peripheral || before.name }), 'info');
                return true;
            })
            .catch(function (err) {
                stores.containers.set(defKey, before);
                renderPeripherals();
                toast(t('requestFailed', { error: err.message }), 'error');
                return false;
            });
    }

    const SCHEDULE_QUEUES = ['storageScan', 'inputScan', 'interactionScan', 'outputScan',
        'containerSize', 'slotLimit',
        'inventoryIn', 'inventoryOut', 'compact', 'stackScan', 'detail', 'manual'];
    const WEIGHT_MIN = 0.01;
    // Weights live as fractions in the model and are shown as percent with 4
    // decimals (0.0125 <-> "1.2500"): the round factor keeps 1e-6 of a fraction.
    const WEIGHT_ROUND = 1000000;

    function scheduleQueueLabelKey(name) {
        return 'scheduleQueue' + name.charAt(0).toUpperCase() + name.slice(1);
    }

    function roundWeight(value) {
        return Math.round(Number(value) * WEIGHT_ROUND) / WEIGHT_ROUND;
    }

    function weightMax() {
        return roundWeight(1 - WEIGHT_MIN * SCHEDULE_QUEUES.length);
    }

    function clampWeight(value) {
        const number = Number(value);
        if (!isFinite(number) || number < WEIGHT_MIN) return WEIGHT_MIN;
        return Math.min(weightMax(), roundWeight(number));
    }

    function displayWeight(value) {
        const number = Number(value);
        if (!isFinite(number) || number < WEIGHT_MIN) return WEIGHT_MIN;
        return Math.min(weightMax(), Math.round(number * 1e6) / 1e6);
    }

    // The UI shows percent with 4 decimals; the model keeps the 0..1 fraction.
    function weightPercent(value) {
        return Math.round(Number(value) * 100 * 1e4) / 1e4;
    }

    function weightPercentText(value) {
        return weightPercent(value).toFixed(4);
    }

    function percentToWeight(percent) {
        const number = Number(percent);
        return isFinite(number) ? number / 100 : WEIGHT_MIN;
    }

    // The compact free-slot threshold is a 0..1 ratio in the model and a percent
    // in the UI (0.3 <-> 30).
    function formatCompactPercent(ratio) {
        const number = Number(ratio);
        return String(Math.round((isFinite(number) ? number : 0) * 1e4) / 100);
    }

    function equalWeights() {
        const count = SCHEDULE_QUEUES.length;
        const each = Math.floor(100 / count);
        const extra = 100 - each * count;
        const out = {};
        SCHEDULE_QUEUES.forEach(function (name, index) {
            out[name] = (each + (index < extra ? 1 : 0)) / 100;
        });
        return out;
    }

    function normalizeWeights(slices) {
        const names = SCHEDULE_QUEUES;
        const count = names.length;
        const maxCents = 100 - count;
        const cents = {};
        let total = 0;
        names.forEach(function (name) {
            const value = Math.max(0, Number(slices && slices[name]) || 0);
            cents[name] = value;
            total += value;
        });
        if (total <= 0) {
            return equalWeights();
        }
        let assigned = 0;
        const remainders = [];
        names.forEach(function (name) {
            const exact = cents[name] / total * 100;
            const whole = Math.max(1, Math.min(maxCents, Math.floor(exact)));
            cents[name] = whole;
            assigned += whole;
            remainders.push({ name: name, frac: exact - Math.floor(exact) });
        });
        remainders.sort(function (a, b) { return b.frac - a.frac; });
        let guard = 0;
        while (assigned > 100 && guard < 4096) {
            guard += 1;
            let biggest = names[0];
            names.forEach(function (name) { if (cents[name] > cents[biggest]) biggest = name; });
            if (cents[biggest] <= 1) break;
            cents[biggest] -= 1;
            assigned -= 1;
        }
        let index = 0;
        while (assigned < 100 && guard < 4096) {
            guard += 1;
            cents[remainders[index % remainders.length].name] += 1;
            assigned += 1;
            index += 1;
        }
        const out = {};
        names.forEach(function (name) { out[name] = cents[name] / 100; });
        return out;
    }

    function scheduleSendLog() {
        const schedule = (status && status.schedule) || {};
        return schedule.sendLog === true;
    }

    function scheduleCompactFreeRatio() {
        const schedule = (status && status.schedule) || {};
        const value = Number(schedule.compactFreeRatio);
        if (!isFinite(value) || value < 0) return 0.3;
        return Math.min(1, value);
    }

    function scheduleSlices() {
        const schedule = (status && status.schedule) || {};
        const saved = schedule.slices || {};
        const out = {};
        let total = 0;
        SCHEDULE_QUEUES.forEach(function (name) {
            out[name] = clampWeight(saved[name]);
            total += out[name];
        });
        if (total <= 0) return equalWeights();
        return out;
    }

    function rebalanceWeights(slices, fixedName, value) {
        const fixed = Math.min(weightMax(), Math.max(WEIGHT_MIN, Number(value) || 0));
        const others = SCHEDULE_QUEUES.filter(function (name) { return name !== fixedName; });
        const alpha = others.map(function (name) {
            return Math.max(0, Number(slices && slices[name]) || 0);
        });
        let sum = 0;
        alpha.forEach(function (item) { sum += item; });
        if (sum <= 0) {
            alpha.forEach(function (_, index) { alpha[index] = 1; });
            sum = others.length;
        }
        const budget = 1 - fixed;
        const out = {};
        out[fixedName] = fixed;
        const frozen = {};
        let free = budget;
        others.forEach(function (name, index) {
            const share = budget * (alpha[index] / sum);
            if (share < WEIGHT_MIN) {
                frozen[index] = true;
                free -= WEIGHT_MIN;
            }
        });
        let freeSum = 0;
        let freeCount = 0;
        others.forEach(function (name, index) {
            if (frozen[index]) return;
            freeSum += alpha[index];
            freeCount += 1;
        });
        others.forEach(function (name, index) {
            if (frozen[index]) {
                out[name] = WEIGHT_MIN;
                return;
            }
            const weight = freeSum > 0 ? free * (alpha[index] / freeSum) : free / Math.max(1, freeCount);
            out[name] = Math.max(WEIGHT_MIN, weight);
        });
        return out;
    }

    function applyWeightValues(slices) {
        SCHEDULE_QUEUES.forEach(function (name) {
            const value = weightPercentText(displayWeight(slices[name]));
            const range = el('sliceRange_' + name);
            const number = el('slice_' + name);
            const label = el('sliceLabel_' + name);
            if (range) range.value = value;
            if (number && document.activeElement !== number) number.value = value;
            const off = Number(slices[name]) <= WEIGHT_MIN + 1e-9;
            if (label) {
                label.className = 'settings-label' + (off ? ' warn' : '');
                label.title = off ? t('scheduleZeroWarning', { queue: t(scheduleQueueLabelKey(name)) }) : '';
                const icon = label.querySelector ? label.querySelector('.warn-icon') : null;
                if (icon) icon.style.display = off ? '' : 'none';
            }
        });
    }

    // --- data files (download / upload) --------------------------------------
    // The server hands a file out as hex in ~16 KiB chunks. One frame is capped
    // (protocol.lua: WS_LIMIT_BYTES) and the text fields of a frame are escape
    // decoded on the way in/out, which would corrupt a config.json that contains
    // literal \\uXXXX sequences - hex is ASCII and survives the transport untouched.
    let dataFiles = [];
    const DATA_FILE_CHUNK = 16384;

    function bytesToHex(bytes) {
        let out = '';
        for (let i = 0; i < bytes.length; i += 1) {
            out += (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16);
        }
        return out;
    }

    function hexToBytes(hex) {
        const text = String(hex || '');
        const length = Math.floor(text.length / 2);
        const bytes = new Uint8Array(length);
        for (let i = 0; i < length; i += 1) {
            bytes[i] = parseInt(text.substr(i * 2, 2), 16) || 0;
        }
        return bytes;
    }

    function bytesToText(bytes) {
        if (window.TextDecoder) return new TextDecoder('utf-8').decode(bytes);
        let out = '';
        for (let i = 0; i < bytes.length; i += 1) out += String.fromCharCode(bytes[i]);
        return out;
    }

    function textToBytes(text) {
        if (window.TextEncoder) return new TextEncoder().encode(String(text));
        const value = String(text);
        const out = [];
        for (let i = 0; i < value.length; i += 1) {
            const code = value.charCodeAt(i);
            if (code < 128) {
                out.push(code);
            } else if (code < 2048) {
                out.push(192 | (code >> 6), 128 | (code & 63));
            } else {
                out.push(224 | (code >> 12), 128 | ((code >> 6) & 63), 128 | (code & 63));
            }
        }
        return new Uint8Array(out);
    }

    // The data-file list arrives from the server asynchronously: keep asking
    // until one request succeeds, so the settings panel always ends up with a
    // real list instead of sitting on the fallback forever.
    let dataFileListLoaded = false;
    let dataFileRefreshTimer = null;

    function dataFileListRetry() {
        if (dataFileListLoaded || dataFileRefreshTimer) return;
        dataFileRefreshTimer = setTimeout(function () {
            dataFileRefreshTimer = null;
            if (!connected) {
                dataFileListRetry();
                return;
            }
            safeStep('refreshDataFiles', refreshDataFiles);
        }, 5000);
    }

    function dataFileEntry(name) {
        const wanted = String(name || '');
        for (let i = 0; i < dataFiles.length; i += 1) {
            if (String(dataFiles[i].name) === wanted) return dataFiles[i];
        }
        return null;
    }

    function refreshDataFiles() {
        return sendRequest('list_data_files', {}).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                dataFileListRetry();
                return;
            }
            dataFileListLoaded = true;
            dataFiles = asArray(result.files);
            renderSettings();
        }).catch(function (err) {
            serverLog('[IFM] list_data_files failed: ' + err.message);
            dataFileListRetry();
        });
    }

    // Chunked download: the reply carries "offset/next" so a big config.json is
    // reassembled from several frames instead of one oversized one.
    function readDataFile(name) {
        const chunks = [];
        let offset = 0;
        const step = function () {
            return sendRequest('data_file_read', { file: name, offset: offset, max: DATA_FILE_CHUNK })
                .then(function (response) {
                    const result = response.result || {};
                    if (result.error) throw new Error(describeMessage(result.error));
                    const bytes = hexToBytes(result.hex);
                    for (let i = 0; i < bytes.length; i += 1) chunks.push(bytes[i]);
                    const next = (result.next === undefined || result.next === null) ? null : Number(result.next);
                    if (next === null || bytes.length === 0) return;
                    offset = next;
                    return step();
                });
        };
        return step().then(function () { return new Uint8Array(chunks); });
    }

    // Chunked upload: the server appends every chunk to a temporary file and only
    // replaces the real file once the last chunk arrived and the JSON parsed - an
    // aborted or invalid upload therefore never damages the live definitions.
    function writeDataFile(name, bytes) {
        let offset = 0;
        const step = function () {
            const slice = bytes.subarray(offset, offset + DATA_FILE_CHUNK);
            const done = (offset + slice.length) >= bytes.length;
            const payload = { file: name, offset: offset, hex: bytesToHex(slice), done: done };
            return sendRequest('data_file_upload', payload).then(function (response) {
                const result = response.result || {};
                if (result.error) throw new Error(describeMessage(result.error));
                offset += slice.length;
                if (!done) return step();
                return result;
            });
        };
        return step();
    }

    function downloadDataFile(name) {
        const entry = dataFileEntry(name);
        readDataFile(name).then(function (bytes) {
            const blob = new Blob([bytes], { type: 'application/json' });
            const url = URL.createObjectURL(blob);
            const link = document.createElement('a');
            link.href = url;
            link.download = entry ? String(entry.name) : String(name);
            document.body.appendChild(link);
            link.click();
            document.body.removeChild(link);
            setTimeout(function () { URL.revokeObjectURL(url); }, 4000);
            toast(t('dataFileDownloaded', { file: name }), 'success');
        }).catch(function (err) {
            toast(t('dataFileReadFailed', { file: name, error: err.message }), 'error');
        });
    }

    function uploadDataFile(name, text) {
        const bytes = textToBytes(text);
        writeDataFile(name, bytes).then(function () {
            toast(t('dataFileUploaded', { file: name, size: bytes.length }), 'success');
            sendRaw({ action: 'full_request' });
            refreshDataFiles();
        }).catch(function (err) {
            toast(t('dataFileWriteFailed', { file: name, error: err.message }), 'error');
        });
    }

    function pickDataFileToUpload(name) {
        const input = el('dataFileInput');
        if (!input) return;
        input.value = '';
        input.onchange = function () {
            const file = input.files && input.files[0];
            if (!file) return;
            const reader = new FileReader();
            reader.onload = function () {
                const text = String(reader.result === null || reader.result === undefined ? '' : reader.result);
                if (!window.confirm(t('dataFileUploadConfirm', { file: name }))) return;
                uploadDataFile(name, text);
            };
            reader.onerror = function () {
                toast(t('dataFileReadFailed', { file: file.name, error: 'FileReader' }), 'error');
            };
            reader.readAsText(file, 'utf-8');
        };
        input.click();
    }

    function dataFileRowHtml() {
        const options = dataFiles.map(function (entry) {
            return '<option value="' + escapeHtml(entry.name) + '">' + escapeHtml(entry.name) +
                ' (' + escapeHtml(fmtCount(entry.size || 0)) + ')</option>';
        }).join('');
        // The panel never hides the controls when the server list is empty: the
        // download button has to stay usable, with config.json - the file the
        // master always writes - as the fallback name.
        const selectHtml = options
            ? '<select id="dataFileName">' + options + '</select>'
            : '<select id="dataFileName"><option value="config.json">config.json</option></select>';
        return '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('dataFilesTitle')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px;flex-wrap:wrap">' +
            selectHtml +
            '<button class="btn-pixel" type="button" data-data-download="1"><i class="fa fa-download"></i> ' +
            escapeHtml(t('dataFileDownload')) + '</button>' +
            '<button class="btn-pixel danger" type="button" data-data-upload="1"><i class="fa fa-upload"></i> ' +
            escapeHtml(t('dataFileUpload')) + '</button>' +
            '<button class="btn-pixel" type="button" data-data-refresh="1"><i class="fa fa-refresh"></i> ' +
            escapeHtml(t('dataFileRefresh')) + '</button>' +
            '<span class="muted">' + escapeHtml(options ? t('dataFileHint') : t('dataFileEmpty')) + '</span>' +
            '</label>';
    }

    // Delegated, because renderSettings() rewrites #settingsBody wholesale.
    function bindDataFileButtons() {
        const body = el('settingsBody');
        if (!body || body.dataset.dataFileBound) return;
        body.dataset.dataFileBound = '1';
        body.addEventListener('click', function (event) {
            const download = event.target.closest('[data-data-download]');
            const upload = event.target.closest('[data-data-upload]');
            const refresh = event.target.closest('[data-data-refresh]');
            if (!download && !upload && !refresh) return;
            if (refresh) {
                refreshDataFiles();
                return;
            }
            const select = el('dataFileName');
            const name = select ? String(select.value || '') : '';
            if (!name) return;
            if (download) downloadDataFile(name);
            else pickDataFileToUpload(name);
        });
    }

    function renderSettings() {
        const body = el('settingsBody');
        if (!body) return;
        const slices = scheduleSlices();
        const sliceSignature = SCHEDULE_QUEUES.map(function (name) { return slices[name]; }).join(',');
        const signature = lang + '|' + sliceSignature +
            '|log=' + (scheduleSendLog() ? '1' : '0') +
            '|cf=' + scheduleCompactFreeRatio() +
            '|df=' + dataFiles.map(function (entry) {
                return String(entry.name) + ':' + (entry.size || 0);
            }).join(',');
        if (body.getAttribute('data-scan') === signature) return;
        if (document.activeElement && body.contains(document.activeElement)) return;
        body.setAttribute('data-scan', signature);
        body.style.display = 'grid';
        body.style.gridTemplateColumns = 'max-content 1fr 72px';
        body.style.alignItems = 'center';
        body.style.gap = '4px 10px';
        const maxWeight = weightMax();
        const rowHtml = SCHEDULE_QUEUES.map(function (name) {
            const value = displayWeight(slices[name]);
            const off = value <= WEIGHT_MIN + 1e-9;
            const warning = t('scheduleZeroWarning', { queue: t(scheduleQueueLabelKey(name)) });
            return '<span class="settings-label' + (off ? ' warn' : '') + '" id="sliceLabel_' + name + '"' +
                ' title="' + (off ? escapeHtml(warning) : '') + '">' +
                escapeHtml(t(scheduleQueueLabelKey(name))) +
                '<i class="fa fa-exclamation-triangle warn-icon"' + (off ? '' : ' style="display:none"') +
                ' title="' + escapeHtml(t('scheduleZeroWarningShort')) + '"></i>' +
                '</span>' +
                '<input type="range" id="sliceRange_' + name + '" min="' + weightPercentText(WEIGHT_MIN) +
                '" max="' + weightPercentText(maxWeight) + '" step="any" value="' + weightPercentText(value) +
                '" title="' + escapeHtml(t('scheduleSliderHint')) + '">' +
                '<input type="number" id="slice_' + name + '" min="' + weightPercentText(WEIGHT_MIN) +
                '" max="' + weightPercentText(maxWeight) + '" step="any" value="' + weightPercentText(value) + '">';
        }).join('');
        body.innerHTML =
            '<div style="grid-column:1 / -1"><strong>' + escapeHtml(t('scheduleTitle')) + '</strong>' +
            '<div class="muted" style="margin:2px 0 6px">' + escapeHtml(t('scheduleHint')) + ' ' +
            escapeHtml(t('scheduleHint2')) + '</div></div>' + rowHtml +
            '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('settingSendLog')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px">' +
            '<input type="checkbox" data-send-log="1"' + (scheduleSendLog() ? ' checked' : '') + '>' +
            escapeHtml(t('settingSendLogHint')) + '</label>' +
            '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('settingCompactFree')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px">' +
            '<input type="number" id="compactFreeRatio" min="0" max="100" step="1" style="width:72px"' +
            ' value="' + escapeHtml(formatCompactPercent(scheduleCompactFreeRatio())) + '"> %' +
            escapeHtml(t('settingCompactFreeHint')) + '</label>' +
            dataFileRowHtml();
        applyWeightValues(slices);
        let current = slices;
        SCHEDULE_QUEUES.forEach(function (name) {
            const range = el('sliceRange_' + name);
            const number = el('slice_' + name);
            if (range) {
                range.addEventListener('input', function () {
                    current = rebalanceWeights(current, name, percentToWeight(range.value));
                    applyWeightValues(current);
                });
                range.addEventListener('change', function () { saveScheduleSettings(current); });
            }
            if (number) {
                number.addEventListener('input', function () {
                    current = rebalanceWeights(current, name, percentToWeight(number.value));
                    applyWeightValues(current);
                });
                number.addEventListener('change', function () { saveScheduleSettings(current); });
            }
        });
        const logBox = document.querySelector ? document.querySelector('[data-send-log]') : null;
        if (logBox) {
            logBox.addEventListener('change', function () {
                saveScheduleSettings(current, { sendLog: logBox.checked });
            });
        }
        const freeBox = document.getElementById ? document.getElementById('compactFreeRatio') : null;
        if (freeBox) {
            freeBox.addEventListener('change', function () {
                const percent = Math.min(100, Math.max(0, Number(freeBox.value)));
                const safe = isFinite(percent) ? Math.round(percent) / 100 : scheduleCompactFreeRatio();
                freeBox.value = formatCompactPercent(safe);
                saveScheduleSettings(current, { compactFreeRatio: safe });
            });
        }
    }

    function saveScheduleSettings(weights, options) {
        const slices = {};
        SCHEDULE_QUEUES.forEach(function (name) { slices[name] = displayWeight(weights[name]); });
        const payload = { slices: slices };
        if (options && typeof options.sendLog === 'boolean') payload.sendLog = options.sendLog;
        if (options && typeof options.compactFreeRatio === 'number') {
            payload.compactFreeRatio = Math.min(1, Math.max(0, options.compactFreeRatio));
        }
        sendRequest('set_schedule_settings', payload).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            if (status && result.schedule) status.schedule = result.schedule;
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function reportBootError(step, err) {
        const message = '[IFM] init step "' + step + '" failed: ' +
            (err && err.message ? err.message : String(err));
        try {
            if (window.console && console.error) console.error(message, err);
        } catch (ignored) {  }
        const node = el('loginError');
        if (node) node.textContent = message;
        try {
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
        } catch (ignored2) {  }
    }

    function safeStep(step, fn) {
        try {
            fn();
        } catch (err) {
            reportBootError(step, err);
        }
    }
    window.ifmSafeStep = safeStep;

    const IFM_APP_BUILD = '487';
    function pageBuild() {
        try {
            return document.documentElement && document.documentElement.getAttribute
                ? document.documentElement.getAttribute('data-ifm-build') : null;
        } catch (err) {
            return null;
        }
    }
    function pageProbe() {
        try {
            const ids = ['connectBtn', 'roomInput', 'disconnectBtn',
                'sendBtn', 'clearSendBtn', 'sendGrid', 'deliveryPanel'];
            const found = {};
            ids.forEach(function (id) { found[id] = !!el(id); });
            const scripts = [];
            if (document.scripts) {
                for (let i = 0; i < document.scripts.length; i += 1) {
                    const node = document.scripts[i];
                    if (node && node.src) {
                        scripts.push(String(node.src).replace(/^https?:\/\/[^/]+/, '').replace(/\?.*$/, ''));
                    }
                }
            }
            const url = (window.location && window.location.href) || '?';
            return 'url=' + url + ' htmlBuild=' + String(pageBuild()) + ' jsBuild=' + IFM_APP_BUILD +
                ' scripts=[' + scripts.join(' ') + '] found=' + JSON.stringify(found);
        } catch (err) {
            return 'probe failed: ' + (err && err.message ? err.message : String(err));
        }
    }
    function checkBuildStamp() {
        const html = pageBuild();
        if (!html || html === IFM_APP_BUILD) return;
        const message = '[IFM] index.html is build ' + html + ' but web/*.js is build ' + IFM_APP_BUILD +
            ' - redeploy index.html together with web/*.js (frontend files are half-updated)';
        try {
            if (window.console && console.error) console.error(message);
        } catch (ignored) {  }
        const node = el('loginError');
        if (node) node.textContent = message;
    }
    window.ifmPageProbe = pageProbe;

    const missingElements = [];
    function reportMissingElement(id) {
        if (missingElements.indexOf(id) >= 0) return;
        missingElements.push(id);
        const message = '[IFM] this page is missing element #' + id +
            ' - the frontend files are probably out of date (redeploy index.html together with web/*.js)';
        try {
            if (window.console && console.warn) {
                console.warn(message, missingElements.slice());
                console.warn('[IFM] page probe: ' + pageProbe());
            }
        } catch (ignored) {  }
        const node = el('loginError');
        if (node) {
            node.textContent = '[IFM] missing element(s): #' + missingElements.join(', #') +
                ' - redeploy index.html together with web/*.js';
        }
    }
    window.ifmMissingElements = function () { return missingElements.slice(); };

    function on(id, type, fn) {
        const node = el(id);
        if (!node || typeof node.addEventListener !== 'function') {
            reportMissingElement(id);
            return null;
        }
        node.addEventListener(type, fn);
        return node;
    }
    window.ifmOn = on;
    window.ifmWeights = {
        min: WEIGHT_MIN,
        max: weightMax(),
        clamp: clampWeight,
        equal: equalWeights,
        normalize: normalizeWeights,
        rebalance: rebalanceWeights,
    };

    function setConnectBusy(busy) {
        const button = el('connectBtn');
        setButtonBusyById('connectBtn', busy);
        if (!button) return;
        const label = button.querySelector('span');
        if (label) label.textContent = busy ? t('connecting') : t('connect');
    }
    window.ifmSetConnectBusy = setConnectBusy;

    function bindToolbar() {
        on('connectBtn', 'click', function () {
            setConnectBusy(true);
            setText('loginError', '');
            window.setTimeout(function () {
                if (el('connectBtn') && el('connectBtn').disabled) setConnectBusy(false);
            }, 12000);
            connect(el('roomInput') ? el('roomInput').value : '');
        });
        on('roomInput', 'keydown', function (event) {
            if (event.key === 'Enter') { const btn = el('connectBtn'); if (btn) btn.click(); }
        });
        on('disconnectBtn', 'click', disconnect);
        window.addEventListener('load', function () { setTimeout(probeFontAwesome, 0); });
        setTimeout(probeFontAwesome, 4000);
        on('diagnoseBtn', 'click', function () {
            busyButton('diagnoseBtn', runDiagnose('report'));
        });
        on('translateBtn', 'click', function (event) {
            const translator = window.IFMTranslate;
            if (!translator) return;
            if (event.shiftKey) {
                translator.clearCache();
                toast(t('translateCacheCleared'), 'info');
                renderTranslateButton();
                return;
            }
            translator.setEnabled(!translator.isEnabled());
            toast(translator.isEnabled() ? t('translateLoading') : t('translateOff'), 'info');
            renderTranslateButton();
        });
        const toggleLang = function () {
            setLang(lang === 'zh' ? 'en' : 'zh');
            el('langLabel').textContent = t('langLabel');
            applyI18n();
            refreshConnectionStatus();
            renderTranslateButton();
            markDirty('resources');
            markDirty('processes');
            markDirty('peripherals');
            markDirty('machines');
            markDirty('deliveries');
            markDirty('status');
            scheduleRender();
        };
        on('langBtn', 'click', toggleLang);
        // The same switch is reachable from the login page: the app header (and its
        // language button) stays hidden until a server was seen.
        on('loginLangBtn', 'click', toggleLang);
        on('sendBtn', 'click', sendPendingItems);
        on('clearSendBtn', 'click', function () {
            sendList.clear();
            renderSend();
            toast(t('clearSendList'), 'info');
        });
        on('clearDeliveriesBtn', 'click', clearAllDeliveries);
        on('processSearch', 'input', function (event) {
            processSearchText = event.target.value.trim();
            renderProcesses();
        });
        bindSearchClear('processSearch', function () {
            processSearchText = '';
            renderProcesses();
        });
        on('resourceSearch', 'input', function (event) {
            searchText = event.target.value.trim();
            renderResources();
        });
        bindSearchClear('resourceSearch', function () {
            searchText = '';
            renderResources();
        });
        on('peripheralSearch', 'input', function (event) {
            peripheralSearchText = event.target.value.trim();
            renderPeripherals();
        });
        bindSearchClear('peripheralSearch', function () {
            peripheralSearchText = '';
            renderPeripherals();
        });
        on('peripheralSearch', 'keydown', function (event) {
            if (event.key !== 'Enter' && event.keyCode !== 13) return;
            event.preventDefault();
            // Enter walks through the highlighted machine type / peripheral cards.
            focusPeripheralSearchHit();
        });
        on('peripheralSortBtn', 'click', function () {
            peripheralSortMode = peripheralSortMode === 'peripheral' ? 'block'
                : (peripheralSortMode === 'block' ? 'defs' : 'peripheral');
            renderPeripherals();
            toast(peripheralSortLabelText(), 'info');
        });
        on('resourceSortBtn', 'click', function () {
            const index = SORT_MODES.indexOf(sortMode);
            sortMode = SORT_MODES[(index < 0 ? 0 : index + 1) % SORT_MODES.length];
            renderResources();
            toast(t('sortTitle') + t('labelSeparator') + sortModeLabel(sortMode), 'info');
        });
        on('editorSaveBtn', 'click', saveEditor);
        on('editorDeleteBtn', 'click', deleteEditor);
        on('editorBody', 'keydown', function (event) {
            if (event.key !== 'Enter' && event.keyCode !== 13) return;
            const target = event.target;
            if (!target || String(target.tagName || '').toUpperCase() !== 'INPUT') return;
            if (target.id === 'toolResource') return;
            const type = String(target.type || 'text').toLowerCase();
            if (type === 'checkbox' || type === 'radio') return;
            event.preventDefault();
            saveEditor();
        });
        on('promptConfirmBtn', 'click', confirmPrompt);
        on('promptInput', 'input', updatePromptPreview);
        on('promptInput', 'keydown', function (event) {
            if (event.key === 'Enter') confirmPrompt();
        });
        on('addMachineTypeBtn', 'click', function () {
            openEditor('machineTypes', null, {});
        });
        on('addFilterBtn', 'click', function () {
            openEditor('filters', null, { rules: [] });
        });
        on('stockSearch', 'input', renderStockList);
        bindSearchClear('stockSearch', renderStockList);
        on('editorBody', 'click', function (event) {
            if (event.target.closest('#toolRefreshBtn')) {
                refreshContainerTool(true);
                return;
            }
            if (event.target.closest('#toolResourceClear')) {
                const field = el('toolResource');
                if (field) field.value = '';
                syncSearchClear('toolResource');
                return;
            }
            // Slot multiplier badge: click to set/clear that slot's multiplier.
            const multBadge = event.target.closest('[data-slot-mult]');
            if (multBadge) {
                event.preventDefault();
                openSlotMultiplierPrompt(Number(multBadge.getAttribute('data-slot-mult')));
                return;
            }
            // Container-wide multiplier: empty input clears it (falls back to the scan
            // or the 1x default).
            if (event.target.closest('#toolSlotMultAllBtn')) {
                event.preventDefault();
                const field = el('toolSlotMultAll');
                const raw = String((field && field.value) || '').trim();
                sendSlotMultiplier(null, raw === '' ? 0 : Number(raw), true);
                return;
            }
            // The container-level "put" button of a fluid container: the resource
            // name comes from the field, the backend picks the tank.
            if (event.target.closest('#toolPutGlobal')) {
                containerMoveRequest('in', null);
                return;
            }
            // Slot buttons act on the slot they live in; fluids carry no slot, so
            // their button sends the move without one (backend picks the tank).
            const putButton = event.target.closest('#toolContents [data-put-now]');
            if (putButton) {
                fillToolRow(putButton.closest('#toolContents [data-take-resource]'));
                containerMoveRequest('in', slotOfButton(putButton, 'data-put-now'));
                return;
            }
            const row = event.target.closest('#toolContents [data-take-resource]');
            if (!row) return;
            fillToolRow(row);
            const takeButton = event.target.closest('[data-take-now]');
            if (takeButton) containerMoveRequest('out', slotOfButton(takeButton, 'data-take-now'));
        });
        on('editorBody', 'input', function (event) {
            if (event.target && event.target.id === 'toolResource') syncSearchClear('toolResource');
        });
        ['input', 'change'].forEach(function (type) {
            on('editorBody', type, function (event) {
                const node = event.target;
                // .e-pitem is the placeholder's referenced item: typing/picking it
                // changes the row icon (it is drawn with that item's icon).
                if (node && node.classList &&
                    (node.classList.contains('e-id') || node.classList.contains('e-pitem'))) {
                    refreshElementIcons();
                }
            });
        });
        on('stockList', 'click', function (event) {
            const pick = event.target.closest('[data-stock-pick]');
            if (pick) pickStock(pick);
        });
        // Stock keeping: pressing K over a craftable resource card opens its
        // maintenance prompt. Placeholders and resources that cannot be crafted are
        // ignored, and the key does nothing while typing or while a modal is open.
        document.addEventListener('keydown', function (event) {
            if (event.key !== 'k' && event.key !== 'K') return;
            if (event.ctrlKey || event.metaKey || event.altKey) return;
            const target = event.target;
            const tag = target && target.tagName ? String(target.tagName).toUpperCase() : '';
            if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' ||
                (target && target.isContentEditable)) return;
            if (document.querySelector && document.querySelector('.modal.show')) return;
            if (!hoveredResourceKey) return;
            const entry = resourceView(hoveredResourceKey);
            if (!entry) return;
            // A craftable material can get a target; a material that already has one
            // stays reachable so it can be changed or cleared after it stopped being
            // craftable. A placeholder always qualifies: its target is what keeps the
            // producing process running.
            if (entry.kind !== 'placeholder' && !entry.craftable && keepAmountOf(entry) <= 0) return;
            event.preventDefault();
            openKeepStockPrompt(entry);
        });
        const newProcess = function () {
            if (stores.machineTypes.size === 0) {
                toast(t('processNoMachineTypes'), 'error');
                return;
            }
            openEditor('processes', null,
                { maxMultiplier: DEFAULT_MAX_MULTIPLIER, inputs: [], outputs: [] });
        };
        on('addProcessBtn', 'click', newProcess);
        on('graphLayoutBtn', 'click', function () {
            window.ifmToggleGraphLayout();
        });
        on('graphSvgBtn', 'click', function () {
            window.ifmDownloadGraphSvg();
        });
        on('graphSearch', 'input', function (event) {
            graphSearchText = String(event.target.value || '').trim();
            const hits = applyGraphSearch();
            if (hits === 0 && !graphSearchEmptyNotified) {
                graphSearchEmptyNotified = true;
                toast(t('graphSearchEmpty'), 'info');
            } else if (hits !== 0) {
                graphSearchEmptyNotified = false;
            }
        });
        on('graphSearch', 'keydown', function (event) {
            if (event.key !== 'Enter' && event.keyCode !== 13) return;
            event.preventDefault();
            // Enter walks through the hits; with nothing to focus, surface the same
            // "no match" hint the input shows instead of doing nothing silently.
            if (focusGraphSearchHit()) return;
            if (!graphSearchEmptyNotified && !searchQueryEmpty(parseSearchQuery(graphSearchText))) {
                graphSearchEmptyNotified = true;
                toast(t('graphSearchEmpty'), 'info');
            }
        });
        bindSearchClear('graphSearch', function () {
            graphSearchText = '';
            graphSearchEmptyNotified = false;
            applyGraphSearch();
        });
    }

    function applyI18n() {
        Array.prototype.forEach.call(document.querySelectorAll('[data-i18n]'), function (node) {
            node.textContent = t(node.getAttribute('data-i18n'));
        });
        const searchHint = t('search');
        const search = el('resourceSearch');
        if (search) {
            search.placeholder = searchHint;
            search.title = t('searchSyntax');
        }
        const stockSearch = el('stockSearch');
        if (stockSearch) {
            stockSearch.placeholder = searchHint;
            stockSearch.title = t('searchSyntax');
        }
        const peripheralSearch = el('peripheralSearch');
        if (peripheralSearch) {
            peripheralSearch.placeholder = searchHint;
            peripheralSearch.title = t('peripheralSearchSyntax');
        }
        const graphSearch = el('graphSearch');
        if (graphSearch) {
            graphSearch.placeholder = t('graphSearchHint');
            graphSearch.title = t('graphSearchHint');
        }
        const processSearch = el('processSearch');
        if (processSearch) {
            processSearch.placeholder = searchHint;
            processSearch.title = t('processSearchSyntax');
        }
        Array.prototype.forEach.call(document.querySelectorAll('[data-i18n-title]'), function (node) {
            node.title = t(node.getAttribute('data-i18n-title'));
        });
        if (window.ifmRenderGraphLayoutButton) window.ifmRenderGraphLayoutButton();
        ['resourceSearch', 'peripheralSearch', 'stockSearch', 'graphSearch', 'processSearch'].forEach(syncSearchClear);
        document.title = 'IFM - ' + t('appTitle');
        renderVersionLabel();
        setText('langLabel', t('langLabel'));
        // The translate button label is not a [data-i18n] node (it depends on the
        // engine state), so it has to be re-rendered on every language change.
        renderTranslateButton();
    }

    function rotateFilterIcons() {
        Array.prototype.forEach.call(document.querySelectorAll('[data-filter-icon]'), function (node) {
            const name = node.getAttribute('data-filter-icon');
            let samples = [];
            try {
                samples = JSON.parse(node.getAttribute('data-samples') || '[]');
            } catch (err) {
                samples = [];
            }
            if (!samples || samples.length === 0) {
                // The holder may have been rendered before the resource table knew
                // the samples (the flow graph renders once): pull the freshest set
                // from the shared store so the rotation can start late.
                const entry = stores.resources.get(resourceKey('filter', name));
                samples = entry ? asArray(entry.samples) : [];
                if (!samples || samples.length === 0) return;
                node.setAttribute('data-samples', JSON.stringify(samples));
            }
            const next = ((iconIndex.get(name) || 0) + 1) % samples.length;
            iconIndex.set(name, next);
            node.innerHTML = plainIconImg(samples[next].kind, samples[next].name);
        });
    }

    window.ifmOnTranslateUpdate = function () {
        markDirty('resources');
        markDirty('peripherals');
        markDirty('machines');
        scheduleRender();
        refreshElementIcons();
        renderTranslateButton();
        if (document.querySelector('#stockModal.show')) renderStockList();
    };

    const IFM_ART = [
        '     _/_/_/  _/_/_/_/  _/      _/   ',
        '      _/    _/        _/_/  _/_/    ',
        '     _/    _/_/_/    _/  _/  _/     ',
        '    _/    _/        _/      _/      ',
        ' _/_/_/  _/        _/      _/        ',
    ];

    function printBanner() {
        IFM_ART.forEach(function (line) { console.log(line); });
        console.log('IFM web client v' + IFM_CLIENT_VERSION + ' - Integrated Factory Manager');
        console.log('room: ' + (room || (new URLSearchParams(window.location.search).get('room') || '')) +
            '  relay: ' + (relayBase || DEFAULT_RELAY) + '  (server logs are visible in the browser console, F12)');
    }

    function init() {
        safeStep('build stamp', checkBuildStamp);
        safeStep('banner', printBanner);
        safeStep('bindResourceGrid', bindResourceGrid);
        safeStep('bindSendGrid', bindSendGrid);
        safeStep('bindProcessList', bindProcessList);
        safeStep('bindDefinitionLists', bindDefinitionLists);
        safeStep('bindPeripheralDrag', bindPeripheralDrag);
        safeStep('bindPeripheralSelection', bindPeripheralSelection);
        safeStep('bindToolbar', bindToolbar);
        safeStep('bindDataFileButtons', bindDataFileButtons);
        // The data file list comes from the server, so wait for the first status
        // frame (before that the request would only time out); refreshDataFiles
        // only marks the list loaded once a request really succeeded.
        setInterval(function () {
            if (dataFileListLoaded || !connected) return;
            safeStep('refreshDataFiles', refreshDataFiles);
        }, 2000);
        safeStep('bindIconTooltips', bindIconTooltips);
        safeStep('applyI18n', applyI18n);
        safeStep('loadMissingMeta', loadMissingMeta);
        setTimeout(function () { safeStep('loadIconExports', loadIconExports); }, 900);
        safeStep('syncDeliveryPanelSpacing', syncDeliveryPanelSpacing);
        safeStep('initPanelNav', initPanelNav);
        safeStep('renderPeripherals', renderPeripherals);
        safeStep('renderFilterPanel', renderFilterPanel);
        safeStep('renderWorkers', renderWorkers);
        if (window.IFMTranslate) safeStep('IFMTranslate.init', function () { window.IFMTranslate.init(); });
        safeStep('renderTranslateButton', renderTranslateButton);
        window.addEventListener('resize', syncDeliveryPanelSpacing);
        safeStep('setConnectionStatus', function () { setConnectionStatus('offline'); });
        setInterval(rotateFilterIcons, ROTATE_MS);
        setInterval(function () {
            const silentMs = Date.now() - (lastServerDataAt || 0);
            const longLost = everSeenServer && silentMs > STALL_MS * 4;
            if (longLost) {
                everSeenServer = false;
                serverSeen = false;
                stallNotified = false;
                serverLog('[IFM] no server data for ' + Math.round(silentMs / 1000) + 's - back to the login page');
                setText('loginError', t('serverLost', { n: Math.round(silentMs / 1000) }));
                setDisplay('loginOverlay', 'flex');
                setDisplay('app', 'none');
                setConnectionStatus('offline');
            }
            if (!connected || Date.now() - lastHeartbeatAt <= STALL_MS) {
                if (!longLost) return;
                lastForcedReconnectAt = Date.now();
                if (room) connect(room);
                return;
            }
            setConnectionStatus('connecting');
            const stallText = serverSeen ? t('wsStalled') : t('wsNoServer', { room: room });
            setText('loginError', stallText);
            if (!serverSeen && !everSeenServer) {
                setDisplay('loginOverlay', 'flex');
                setDisplay('app', 'none');
            }
            if (!stallNotified) {
                stallNotified = true;
                toast(stallText, 'error');
            }
            lastForcedReconnectAt = Date.now();
            serverLog('[IFM] ' + Math.round(STALL_MS / 1000) + 's without any server data - reconnecting to room ' + room);
            if (room) connect(room);
        }, 3000);
        const params = new URLSearchParams(window.location.search);
        const roomParam = params.get('room') || getCookie('ifm_room') || '';
        const relayParam = params.get('relay') || getCookie('ifm_relay') || DEFAULT_RELAY;
        relayBase = normalizeRelay(relayParam);
        const roomField = el('roomInput');
        if (roomField) roomField.value = roomParam;
        const relayField = el('relayInput');
        if (relayField) relayField.value = relayBase;
        if (params.get('auto') === '1' && roomParam) {
            setTimeout(function () { connect(roomParam); }, 300);
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { safeStep('init', init); });
    } else {
        safeStep('init', init);
    }
