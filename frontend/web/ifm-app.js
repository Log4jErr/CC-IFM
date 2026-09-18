// IFM :: web/ifm-app.js
// 交互动作 / 诊断 / 工具栏绑定 / 启动入口
// （由 index.html 拆分而来；所有文件按顺序在页面里加载，共享同一份全局作用域）
'use strict';

// ===================== 交互动作 =====================
    function resourceFromKey(key) {
        const parts = splitKey(key);
        return { kind: parts[0], name: parts[1] };
    }

    function resourceStock(kind, name) {
        const entry = stores.resources.get(resourceKey(kind, name));
        return entry ? Math.max(0, entry.count || 0) : 0;
    }

    function resourceCraftable(kind, name) {
        const entry = stores.resources.get(resourceKey(kind, name));
        return !!(entry && entry.craftable);
    }

    function handleAddByClick(resource) {
        if (resource.kind === 'placeholder') return;
        const stock = resourceStock(resource.kind, resource.name);
        if (stock <= 0 && !resourceCraftable(resource.kind, resource.name)) {
            toast(t('notCraftable'), 'error');
            return;
        }
        addSend(resource.kind, resource.name, 1);
    }

    function openSendCountPrompt(resource) {
        const key = resourceKey(resource.kind, resource.name);
        const current = sendList.get(key);
        const stock = resourceStock(resource.kind, resource.name);
        const cap = sendCap(resource.kind, resource.name);
        // 默认值 = 该物品当前的数量：已在待发送里就用待发送数量，否则用库存数量（可合成但库存为 0 时填 1）
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
                setSend(resource.kind, resource.name, value);
            }
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

    // 资源格子的鼠标操作：
    //   左键 +1 · Shift+左键 +64 · 右键 -1 · Shift+右键 -64
    //   中键 = 设置合成数量（标题「合成 <物品名>」）· Shift+中键 = 设置待发送数量（标题「发送 <物品名>」）
    //   右上角「+」= 同中键（只合成，不发送）
    function bindResourceGrid() {
        const grid = el('resourceGrid');
        grid.addEventListener('click', function (event) {
            const plus = event.target.closest('.grid-mark');
            if (plus) {
                const craftKey = plus.getAttribute('data-craft');
                if (craftKey) openCraftPrompt(resourceFromKey(craftKey));
                return;
            }
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            if (event.shiftKey) {
                addSend(resource.kind, resource.name, 64);
                return;
            }
            handleAddByClick(resource);
        });
        grid.addEventListener('contextmenu', function (event) {
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            addSend(resource.kind, resource.name, event.shiftKey ? -64 : -1);
        });
        grid.addEventListener('mousedown', function (event) {
            if (event.button !== 1) return;
            const card = event.target.closest('[data-resource]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-resource'));
            if (resource.kind === 'placeholder') return;
            // 中键 = 设置发送数量；Shift+中键 = 设置合成数量（1.6.12：与以往相反，用户要求对调）
            if (event.shiftKey) {
                openCraftPrompt(resource);
                return;
            }
            openSendCountPrompt(resource);
        });
    }

    function bindSendGrid() {
        const grid = el('sendGrid');
        // 「发送中」栏的取消按钮（每项右侧的 ×）：删掉服务端那条发送队列
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
                sendList.delete(resourceKey(resource.kind, resource.name));
                renderSend();
                return;
            }
            const card = event.target.closest('[data-send]');
            if (!card) return;
            const resource = resourceFromKey(card.getAttribute('data-send'));
            addSend(resource.kind, resource.name, 1);
        });
        grid.addEventListener('contextmenu', function (event) {
            const card = event.target.closest('[data-send]');
            if (!card) return;
            event.preventDefault();
            const resource = resourceFromKey(card.getAttribute('data-send'));
            addSend(resource.kind, resource.name, -1);
        });
    }

    // 取消「发送中」的一项：服务端把它从发送队列里删掉（已经送进目标容器的部分不会退回）
    function cancelDelivery(id) {
        const key = String(id);
        const before = stores.deliveries.get(key);
        if (!before) return;
        stores.deliveries.delete(key);          // 乐观移除，失败再放回
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
            return { kind: entry.kind, name: entry.name, count: entry.count };
        });
        // 动画起点：先记下每张待发送卡片当前的位置（下面清空/重画之后就量不到了）
        const fromRects = {};
        Array.prototype.forEach.call(el('sendGrid').querySelectorAll('[data-send]'), function (node) {
            fromRects[node.getAttribute('data-send')] = node.getBoundingClientRect();
        });
        // 乐观更新：点下去立刻清空待发送、并在「发送中」放一条占位（服务端下一 tick 才回传真实队列）；
        // 发送失败则原样放回待发送、撤掉占位
        const backup = items.map(function (entry) { return Object.assign({}, entry); });
        const restoreSend = function () {
            dropOptimisticDeliveries(backup);
            sendList.clear();
            backup.forEach(function (entry) {
                setSend(entry.kind, entry.name, entry.count);
            });
            renderSend();
        };
        sendList.clear();
        addOptimisticDeliveries(items);
        renderSend();
        // 材料从「待发送」滑到「发送中」：量一下占位卡片的位置，让副本从旧位置飞过去。
        // 先强制一次布局：底部面板可能是刚被 renderSend 显示出来的（display 从 none 变回来），
        // 不先读取一次布局的话 getBoundingClientRect 会拿到全 0（动画就飞不见了，1.6.11 修）。
        const deliveryGrid = el('deliveryGrid');
        if (deliveryGrid) void deliveryGrid.offsetHeight;
        const pairs = items.map(function (entry) {
            const key = resourceKey(entry.kind, entry.name);
            const grid = el('deliveryGrid');
            const node = grid ? grid.querySelector('[data-delivery="' + key + '"]') : null;
            return { fromRect: fromRects[key], toRect: node ? node.getBoundingClientRect() : null, node: node };
        });
        animateSendToDelivery(pairs);
        busyButton('sendBtn', sendRequest('send_items', { container: container, items: items })).then(function (response) {
            const result = response.result || {};
            // 服务端已经收到并处理了这次发送：现在开始用“发送队列的增量更新”核对乐观占位
            // （发完/被拒的物品会随下一次增量更新从「发送中」里消失，任务 5 / 1.6.12）
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
                    hint: t('processBatchesHint'),
                    onConfirm: function (value) {
                        const count = Math.max(1, Math.floor(value) || 1);
                        // 乐观更新：弹窗关掉就立刻在进程面板里看到这一行（服务端随后推送真实状态覆盖）
                        const previousRecord = stores.runtime.get(name);
                        stores.runtime.set(name, Object.assign({}, previousRecord || {}, {
                            name: name,
                            batch: ((previousRecord && previousRecord.batch) || 0) + count,
                            remaining: ((previousRecord && previousRecord.remaining) || 0) + count,
                            userCount: ((previousRecord && previousRecord.userCount) || 0) + count,
                            lastError: null,
                        }));
                        markDirty('processes');
                        scheduleRender();
                        sendRequest('start_process', {
                            name: name,
                            count: count
                        }).then(function (response) {
                            const result = response.result || {};
                            if (result.error) {
                                if (previousRecord) {
                                    stores.runtime.set(name, previousRecord);
                                } else {
                                    stores.runtime.delete(name);
                                }
                                markDirty('processes');
                                scheduleRender();
                                toast(t('requestFailed', { error: result.error }), 'error');
                                return;
                            }
                            toast(t('saved'), 'success');
                        }).catch(function (err) {
                            if (previousRecord) {
                                stores.runtime.set(name, previousRecord);
                            } else {
                                stores.runtime.delete(name);
                            }
                            markDirty('processes');
                            scheduleRender();
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
            const cancel = event.target.closest('[data-process-cancel]');
            if (cancel) {
                const name = cancel.getAttribute('data-process-cancel');
                // 乐观更新：点下去立刻把这一行从面板去掉（服务端随后推送真实状态覆盖）
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

    // 删除「外设缺失」条目的定义：容器要带上种类（item/fluid），信号只按名字
    function deleteMissingDefinition(button) {
        const name = button.getAttribute('data-delete-missing');
        const kind = button.getAttribute('data-missing-kind') === 'signals' ? 'signals' : 'containers';
        if (!name) return;
        if (!window.confirm(t('deleteConfirm', { name: name }))) return;
        const payload = { name: name, force: true };
        if (kind === 'containers') {
            payload.kind = button.getAttribute('data-missing-container-kind') === 'fluid' ? 'fluid' : 'item';
        }
        button.disabled = true;
        sendRequest(DELETE_ACTION[kind], payload).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                button.disabled = false;
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            toast(t('missingDeleted', { name: name }), 'success');
            markDirty('peripherals');
            markDirty('containers');
            markDirty('signals');
            markDirty('missing');
            scheduleRender();
        }).catch(function (err) {
            button.disabled = false;
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function bindDefinitionLists() {
        // 「外设与定义」板块被拆成了四个容器（缺失 / 机器类型 / 存储 / 未分配），
        // 点击委托必须**每个容器都绑一遍** —— 以前只绑了 peripheralList，
        // 结果机器类型卡片上的「+ 机器」与机器卡片都点不动（1.6.5 修）。
        ['peripheralList', 'machineTypeList', 'storageList', 'inputList', 'missingList'].forEach(function (id) {
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
            // 存储 / 输入 卡片里的「×」：删掉这条容器定义（外设回到“未分配”）
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
            // 机器位置里的「×」：从这台机器移出
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
            const machine = event.target.closest('[data-edit-machine]');
            if (machine) {
                openEditor('machines', machine.getAttribute('data-edit-machine'));
                return;
            }
            // 机器类型卡片右上角的「+ 机器」：先于卡片本身（编辑机器类型）判定
            const addMachine = event.target.closest('[data-add-machine]');
            if (addMachine) {
                openEditor('machines', null, {
                    type: addMachine.getAttribute('data-add-machine'),
                    parallel: 1
                });
                return;
            }
            const machineType = event.target.closest('[data-edit-machine-type]');
            if (machineType) {
                openEditor('machineTypes', machineType.getAttribute('data-edit-machine-type'));
                return;
            }
            // 外设缺失：允许直接把背后的定义删掉（外设缺失时其它编辑都没有意义）
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
            // 注：红石信号不再需要“新建定义”（1.6.9）—— 中继器芯片直接拖到机器的信号卡片即可，
            // 所以这里没有 data-new-signal 分支了。
        }
    }

    // ===================== 诊断（结果走日志通道分块送回来） =====================
    let diagnoseBuffer = null;        // 非 null 表示正在收集诊断行
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

    // 诊断：请求服务端执行，报告行由日志通道分块送来（见 handleIncoming 的 'log' 分支）
    // 返回请求的 Promise（按钮的“忙碌”状态要等它结束）
    function runDiagnose(mode) {
        diagnoseMode = mode || 'report';
        const requestedAt = Date.now();
        const out = el('diagnoseOutput');
        if (out) out.textContent = t('diagnoseRunning');
        if (diagnoseModalInstance()) diagnoseModalInstance().show();
        return sendRequest('diagnose', { mode: diagnoseMode }).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                if (out) out.textContent = 'ERROR: ' + result.error;
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            // 兜底：如果 3 秒内没收到任何 begin 标记（日志通道不通），就用响应里带回的行
            setTimeout(function () {
                if (diagnoseLastFinish >= requestedAt) return;
                const lines = asArray(result.lines);
                if (out) out.textContent = lines.length ? lines.join('\n') : '(no output: 日志通道与响应都没有内容)';
                const hint = el('diagnoseHint');
                if (hint) hint.textContent = t('diagnoseDone', { mode: diagnoseMode, n: lines.length });
            }, 3000);
        }).catch(function (err) {
            if (out) out.textContent = 'ERROR: ' + err.message;
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }
    // 控制台可直接调用：ifmDiagnose('report') / ifmDiagnose('tick') / ifmDiagnose('move')
    window.ifmDiagnose = runDiagnose;

    // 搜索框右侧的「×」：清空输入并重画对应列表；输入为空时隐藏按钮
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

    // ===================== 容器管理（内嵌在「编辑容器定义」弹窗里） =====================
    // 以前它是外设卡片上的一个独立小工具（另开弹窗），入口拿到的定义经常对不上号；
    // 现在只在“编辑容器定义”里出现，并且以服务端的“种类:名称”键为准（不再靠种类猜测）。
    let containerTarget = null;      // { key, name, kind }

    function parseContainerKey(key) {
        const text = String(key || '');
        return {
            key: text,
            kind: text.indexOf('fluid:') === 0 ? 'fluid' : 'item',
            name: text.replace(/^(item|fluid):/, '')
        };
    }

    function containerRowHtml(kind, name, count, ref) {
        queueMeta(kind, name);
        return '<div class="stock-item" data-take-resource="' + escapeHtml(name) + '" data-take-count="' +
            escapeHtml(String(count || 0)) + '">' +
            '<span class="icon">' + plainIconImg(kind, name) + '</span>' +
            '<span class="stock-name" title="' + escapeHtml(name) + '">' + escapeHtml(displayName(kind, name)) + '</span>' +
            '<span class="stock-count">' + escapeHtml(fmtCount(count || 0)) + '</span>' +
            '<button class="btn-pixel" type="button" data-take-now="' + escapeHtml(String(ref)) + '">' +
            escapeHtml(t('containerTake')) + '</button>' +
            '</div>';
    }

    function renderContainerSuggestions(view) {
        const list = el('toolSuggestions');
        if (!list) return;
        const names = new Set();
        if (view) {
            asArray(view.items).forEach(function (entry) { names.add(entry.name); });
            asArray(view.fluids).forEach(function (entry) { names.add(entry.name); });
        }
        Array.from(stores.resources.values()).forEach(function (entry) {
            if (entry.kind === 'filter' || entry.kind === 'placeholder') return;
            if (containerTarget && entry.kind !== containerTarget.kind) return;
            names.add(entry.name);
        });
        list.innerHTML = Array.from(names).map(function (name) {
            return '<option value="' + escapeHtml(name) + '"></option>';
        }).join('');
    }

    function renderContainerTool(view) {
        const meta = el('toolMeta');
        const hint = el('toolHint');
        if (hint) hint.textContent = t('containerTool');
        const contents = el('toolContents');
        if (!meta || !contents) return;      // 编辑器没打开 / 当前编辑的不是已保存的容器定义
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
                addRow(t('tipState'), t('containerUnusable', { reason: view.problem || '-' }), true);
            }
            meta.innerHTML = rows.join('');
        }
        if (!view || view.error) {
            contents.innerHTML = '<span class="muted">' + escapeHtml((view && view.error) || t('noData')) + '</span>';
            return;
        }
        const rows = [];
        asArray(view.items).forEach(function (entry) {
            rows.push(containerRowHtml('item', entry.name, entry.count, entry.slot));
        });
        asArray(view.fluids).forEach(function (entry) {
            rows.push(containerRowHtml('fluid', entry.name, entry.amount, entry.tank));
        });
        contents.innerHTML = rows.length
            ? '<div class="stock-list">' + rows.join('') + '</div>'
            : '<span class="muted">' + escapeHtml(t('containerEmpty')) + '</span>';
        renderContainerSuggestions(view);
    }

    // 编辑器（「编辑容器定义」）打开时调用：key = 服务端的“种类:名称”
    // key 为空 = 新建（还没保存），此时只显示一行提示（见 buildContainerEditor）
    window.ifmContainerToolMount = function (key) {
        containerTarget = key ? parseContainerKey(key) : null;
        const input = el('toolResource');
        if (input) input.value = '';
        syncSearchClear('toolResource');
        if (!containerTarget) return;
        renderContainerTool(null);
        refreshContainerTool();
    };

    function refreshContainerTool() {
        if (!containerTarget) return;
        const meta = el('toolMeta');
        if (meta) meta.innerHTML = '<div class="muted">…</div>';
        sendRequest('container_view', {
            name: containerTarget.name,
            kind: containerTarget.kind,
            key: containerTarget.key
        }).then(function (response) {
            // 服务端返回的定义可能纠正了种类（按名称回退查找），这里跟着更新
            const result = response.result || {};
            if (!result.error && result.name && result.kind) {
                containerTarget.name = result.name;
                containerTarget.kind = result.kind;
            }
            renderContainerTool(result);
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    // dir = 'in'（从存储容器放进这个容器）/ 'out'（把这个容器里的搬回存储容器）
    function containerMoveRequest(dir) {
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
        const action = dir === 'in' ? 'container_put' : 'container_take';
        const buttonId = dir === 'in' ? 'toolPutBtn' : 'toolTakeBtn';
        busyButton(buttonId, sendRequest(action, {
            name: containerTarget.name,
            kind: containerTarget.kind,
            key: containerTarget.key,
            resource: resource,
            count: count
        })).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            const moved = result.moved || 0;
            toast(t('containerMoved', { n: fmtCount(moved) }) + (result.reason ? ' · ' + result.reason : ''),
                moved > 0 ? 'success' : 'info');
            refreshContainerTool();
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    // ===================== 机器：拖拽外设卡片设置输入/输出/信号 =====================
    // 层级（都在「外设与定义」板块里）：机器类型卡片 → 机器卡片 → 输入容器/输出容器/红石信号 → 外设卡片。
    // 拖外设卡片（板块里的整张卡片）到某个位置 = 把这个外设加进那台机器的那个位置；
    // 拖位置里的外设卡片到机器卡片外 = 从这台机器移出；拖到同一台机器的另一个位置 = 换位置。
    let dragPayload = null;      // { peripheral, fromMachine, fromSlot, fromKind, fromDef, dropped }

    // 这个外设支持哪些功能（同一个方块可能同时是物品容器 + 流体容器）
    function peripheralCapabilities(peripheralName) {
        const caps = {};
        Array.from(stores.peripherals.values()).forEach(function (item) {
            if (item.name === peripheralName && item.kind) caps[item.kind] = true;
        });
        return caps;
    }

    // 机器里的容器定义名：非输出容器都用**外设名**作定义名（服务端 Store:containerNameFor），
    // 所以这里统一按外设名找/建。外设现在还是别的角色（存储 / 输出）时顺手改成 interaction ——
    // 机器的输入输出容器必须是 interaction，否则保存会被服务端拒绝。
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
            if (result.error) throw new Error(result.error);
            // 本地乐观补上这条定义：拖拽后位置卡片要立刻显示成“已归属”，
            // 不必等服务端把 containers 推回来（推回来时会覆盖这里）
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

    // 机器里引用的是**红石中继器的外设名**（1.6.9：信号不再需要命名，也不再需要“信号定义”）。
    // 直接把中继器拖到机器的红石信号卡片上就是这个外设名；同一个中继器可以给多台机器用。
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

    // 改机器的输入/输出/信号归属：本地先乐观更新（拖拽要看得到即时效果），失败回滚并提示
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

    // 位置 + 种类 → 机器数据里的字段名
    function machineSlotField(slot, kind) {
        if (slot === 'signal') return 'signals';
        if (slot === 'in') return kind === 'fluid' ? 'fluidInputs' : 'itemInputs';
        return kind === 'fluid' ? 'fluidOutputs' : 'itemOutputs';
    }

    // 从机器里移出某个位置上的外设（拖到机器卡片外 / 点位置卡片里的 ×）
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

    // 把外设加进机器的某个位置（必要时先建好容器/信号定义，并把容器角色改成 interaction）
    // dragKind：拖拽来源明确指定了功能种类（item/fluid/signal）时只处理这一种；
    // 不传（例如从别处调用）就按外设能力推断。
    function addPeripheralToMachine(machineName, slot, peripheral, dragKind) {
        const caps = peripheralCapabilities(peripheral);
        if (slot === 'signal' && !caps.redstone_relay) {
            toast(t('machineSlotNeedSignal', { name: peripheral }), 'error');
            return Promise.resolve(false);
        }
        if (slot !== 'signal' && dragKind === 'signal') {
            toast(t('machineSlotNeedContainer', { name: peripheral }), 'error');
            return Promise.resolve(false);
        }
        if (slot === 'signal' && dragKind && dragKind !== 'signal') {
            toast(t('machineSlotNeedSignal', { name: peripheral }), 'error');
            return Promise.resolve(false);
        }
        if (slot !== 'signal' && !dragKind && !caps.inventory && !caps.fluid_storage) {
            toast(t('machineSlotNeedContainer', { name: peripheral }), 'error');
            return Promise.resolve(false);
        }
        // 拖拽来源指定了种类就用它（拖“流体容器”芯片不会顺手把物品容器也加进去）；
        // 否则：一个方块同时是物品容器 + 流体容器时，两种容器都归到这台机器
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
            }, t('machinePeripheralAdded', { name: peripheral, machine: machineName }));
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
            return false;
        });
    }

    // 当前拖拽的芯片能被这个位置 / 存储卡片接收吗？
    // 判定与 drop 分支 / addPeripheralToMachine 完全一致（种类不匹配就不该高亮）：
    //   * signal 芯片 → 只有红石信号位置；
    //   * item / fluid 芯片 → 同种类的存储卡片 + 机器的输入/输出位置（位置自己不区分种类）；
    //   * 存储卡片里的芯片（老版本没有 data-pc-kind 时按外设能力推断）。
    function dragAcceptable(target, payload) {
        const caps = peripheralCapabilities(payload.peripheral);
        const kind = payload.dragKind === 'signal'
            ? 'signal'
            : (payload.dragKind ? payload.dragKind : (caps.inventory && !caps.fluid_storage ? 'item'
                : (caps.fluid_storage && !caps.inventory ? 'fluid' : null)));
        const storageKind = target.getAttribute('data-storage-drop');
        if (storageKind) {
            // 存储卡片：只收同种类的容器芯片（信号芯片不收）
            return kind !== null && kind === (storageKind === 'fluid' ? 'fluid' : 'item');
        }
        const inputKind = target.getAttribute('data-input-drop');
        if (inputKind) {
            // 输入容器卡片：规则与存储卡片一样（只收同种类的容器芯片）
            return kind !== null && kind === (inputKind === 'fluid' ? 'fluid' : 'item');
        }
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

    // 拖拽开始：把**所有能接收当前芯片**的位置 / 存储卡片都标出来（.drop-ok 边框高亮），
    // 这样不用一个个试就知道能放到哪里；不能接收的（比如流体芯片拖到物品存储卡片）不亮。
    function markDropTargets(payload) {
        const nodes = document.querySelectorAll('[data-machine-slot], [data-storage-drop], [data-input-drop]');
        Array.prototype.forEach.call(nodes, function (node) {
            node.classList.toggle('drop-ok', dragAcceptable(node, payload));
        });
    }

    // 拖拽绑定：document 级（卡片每次重画都会重建，委托绑定最省事）
    function bindPeripheralDrag() {
        const clearHighlight = clearDropHighlight;
        document.addEventListener('dragstart', function (event) {
            const card = event.target.closest('[data-drag-peripheral]');
            const chip = event.target.closest('[data-pc-peripheral]');
            if (!card && !chip) return;
            dragPayload = card
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
                    // 存储 / 输入容器卡片上的芯片：记下它属于哪种角色（拖出卡片 = 删掉这条定义）
                    fromContainerRole: chip.getAttribute('data-pc-role') ||
                        (chip.getAttribute('data-pc-storage') ? 'storage' : null),
                    dragKind: chip.getAttribute('data-pc-kind'),
                    fromKey: chip.getAttribute('data-edit-container') };
            dragPayload.dropped = false;
            (card || chip).classList.add('dragging');
            if (event.dataTransfer) {
                event.dataTransfer.effectAllowed = 'move';
                try { event.dataTransfer.setData('text/plain', dragPayload.peripheral || ''); } catch (err) { /* 忽略 */ }
            }
            markDropTargets(dragPayload);
        });
        document.addEventListener('dragover', function (event) {
            if (!dragPayload) return;
            const target = event.target.closest('[data-machine-slot]') ||
                event.target.closest('[data-storage-drop]') || event.target.closest('[data-input-drop]');
            if (!target) return;
            // 不 preventDefault 的话浏览器不认为这里是可放置目标（drop 事件也不会来）
            event.preventDefault();
            if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
            // 只有能接收的目标才把边框点亮（不能接收的保持原样，放开时会提示原因）
            if (dragAcceptable(target, dragPayload)) {
                if (!target.classList.contains('drop-active')) {
                    Array.prototype.forEach.call(document.querySelectorAll('.drop-active'), function (node) {
                        node.classList.remove('drop-active');
                    });
                    target.classList.add('drop-active');
                }
            } else if (target.classList.contains('drop-active')) {
                target.classList.remove('drop-active');
            }
        });
        document.addEventListener('drop', function (event) {
            const payload = dragPayload;
            if (!payload) return;
            const slot = event.target.closest('[data-machine-slot]');
            const storage = event.target.closest('[data-storage-drop]');
            // 输入容器卡片（1.6.10）：与存储卡片同构，只是角色不一样
            const input = event.target.closest('[data-input-drop]');
            if (!slot && !storage && !input) return;
            event.preventDefault();
            payload.dropped = true;
            clearHighlight();
            // 拖到「存储/输入 物品/流体容器」卡片：设成该角色 + 该种类的容器
            if (storage || input) {
                const role = storage ? 'storage' : 'input';
                const card = storage || input;
                const kind = card.getAttribute(role === 'storage' ? 'data-storage-drop' : 'data-input-drop') === 'fluid'
                    ? 'fluid' : 'item';
                // 拖的是明确种类的芯片（物品容器/流体容器）时，种类必须与卡片一致
                if (payload.dragKind === 'signal' || (payload.dragKind && payload.dragKind !== kind)) {
                    toast(t('storageNeedKind', {
                        name: payload.peripheral,
                        kind: t(kind === 'fluid' ? 'fluidContainer' : 'itemContainer')
                    }), 'error');
                    return;
                }
                const add = function () { return addPeripheralToContainerRole(role, kind, payload.peripheral); };
                // 拖回同一种卡片（同角色同种类）：什么都不做
                if (payload.fromContainerRole === role && payload.fromKind === kind) return;
                if (payload.fromMachine) {
                    // 从机器位置拖到存储/输入卡片：这是“移出机器”的意图，先摘掉机器归属
                    removePeripheralFromMachine(payload, true).then(add);
                    return;
                }
                add();
                return;
            }
            const machineName = slot.getAttribute('data-machine');
            const slotId = slot.getAttribute('data-machine-slot');
            if (payload.fromMachine) {
                // 拖回原位：什么都不做
                if (payload.fromMachine === machineName && payload.fromSlot === slotId) return;
                // 拖到**另一个位置**（同一台机器的另一个槽位，或另一台机器）= **复制归属**（1.6.10）：
                // 输入容器的外设拖到输出容器时，输入容器那张卡片要保留（用户明确要求）；
                // 交互容器与红石中继器本来就允许被多处引用。
                // 想从某个位置移除：把它拖到机器卡片外面（dragend 里处理），或点卡片上的 ×。
                addPeripheralToMachine(machineName, slotId, payload.peripheral, payload.dragKind).then(function (ok) {
                    if (ok) {
                        toast(t('machinePeripheralShared', { name: payload.peripheral, machine: machineName }), 'info');
                    }
                });
                return;
            }
            addPeripheralToMachine(machineName, slotId, payload.peripheral, payload.dragKind);
        });
        document.addEventListener('dragend', function () {
            clearHighlight();
            Array.prototype.forEach.call(document.querySelectorAll('.dragging'), function (node) {
                node.classList.remove('dragging');
            });
            const payload = dragPayload;
            dragPayload = null;
            if (!payload) return;
            if (payload.dropped) return;
            // 拖到机器卡片外（没落在任何位置上）＝ 从这台机器移出
            if (payload.fromMachine) {
                removePeripheralFromMachine(payload);
                return;
            }
            // 拖到存储 / 输入卡片外 ＝ 删掉这条容器定义（这个外设回到“未分配”）
            if (payload.fromContainerRole || payload.fromStorage) {
                removeStorageContainer(payload.fromKey, payload.peripheral);
            }
        });
    }

    // ===== 存储 / 输入 容器卡片：拖外设卡片进来 = 设成该角色的容器；拖出去（或点 ×）= 删掉这条定义 =====
    function addPeripheralToContainerRole(role, kind, peripheral) {
        const caps = peripheralCapabilities(peripheral);
        const capability = kind === 'fluid' ? 'fluid_storage' : 'inventory';
        const kindLabel = t(kind === 'fluid' ? 'fluidContainer' : 'itemContainer');
        if (!caps[capability]) {
            toast(t('storageNeedKind', { name: peripheral, kind: kindLabel }), 'error');
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
            if (result.error) throw new Error(result.error);
            const optimistic = Object.assign({}, existing || {}, {
                name: name, peripheral: peripheral, kind: kind, role: role, priority: priority
            });
            stores.containers.set(containerKeyOf(optimistic), optimistic);
            markDirty('containers');
            renderPeripherals();
            toast(t('containerRoleSet', {
                name: peripheral,
                kind: kindLabel,
                role: t(role === 'input' ? 'inputRole' : 'storage')
            }), 'success');
            return true;
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
            return false;
        });
    }

    // 兼容旧调用：存储容器
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

    // ===== 设置面板：容器扫描间隔（1.6.11，任务 8）=====
    // 存储容器扫描间隔 = 主控读容器内容的缓存时长；输入容器扫描间隔 = 输入容器“排空扫描”的节奏。
    // 两个值都由服务端持久化（config.json -> settings.scan）并通过 status.scanSettings 回传。
    function renderSettings() {
        const body = el('settingsBody');
        if (!body) return;
        const settings = (status && status.scanSettings) || {};
        const storage = Number(settings.storageScanMs) || 1200;
        const input = Number(settings.inputScanMs) || 2000;
        const signature = storage + '/' + input;
        if (body.getAttribute('data-scan') === signature) return;             // 值没变：不重画
        if (document.activeElement && body.contains(document.activeElement)) return;  // 正在输入：不打断
        body.setAttribute('data-scan', signature);
        body.innerHTML =
            '<div class="editor-row"><label for="settingsStorageMs">' + escapeHtml(t('settingsStorageScan')) +
            '</label><input type="number" id="settingsStorageMs" min="250" max="600000" step="50" value="' +
            escapeHtml(String(storage)) + '"></div>' +
            '<div class="editor-row"><label for="settingsInputMs">' + escapeHtml(t('settingsInputScan')) +
            '</label><input type="number" id="settingsInputMs" min="250" max="600000" step="50" value="' +
            escapeHtml(String(input)) + '"></div>' +
            '<div class="muted" style="margin:-2px 0 8px 0">' + escapeHtml(t('settingsHint')) + '</div>' +
            '<button class="btn-pixel primary" type="button" id="settingsSaveBtn"><i class="fa fa-check"></i> ' +
            escapeHtml(t('save')) + '</button>';
        const button = el('settingsSaveBtn');
        if (button) button.addEventListener('click', saveScanSettings);
    }

    function saveScanSettings() {
        const storage = Number(el('settingsStorageMs') && el('settingsStorageMs').value);
        const input = Number(el('settingsInputMs') && el('settingsInputMs').value);
        if (!isFinite(storage) || !isFinite(input)) {
            toast(t('settingsHint'), 'error');
            return;
        }
        busyButton('settingsSaveBtn', sendRequest('set_scan_settings', {
            storageScanMs: Math.round(storage),
            inputScanMs: Math.round(input),
        })).then(function (response) {
            const result = response.result || {};
            if (result.error) {
                toast(t('requestFailed', { error: result.error }), 'error');
                return;
            }
            if (status && result.scanSettings) status.scanSettings = result.scanSettings;
            const applied = result.scanSettings || { storageScanMs: storage, inputScanMs: input };
            renderSettings();
            toast(t('settingsSaved', { storage: applied.storageScanMs, input: applied.inputScanMs }), 'success');
        }).catch(function (err) {
            toast(t('requestFailed', { error: err.message }), 'error');
        });
    }

    function bindToolbar() {
        el('connectBtn').addEventListener('click', function () {
            connect(el('roomInput').value);
        });
        el('roomInput').addEventListener('keydown', function (event) {
            if (event.key === 'Enter') el('connectBtn').click();
        });
        el('disconnectBtn').addEventListener('click', disconnect);
        el('refreshBtn').addEventListener('click', function (event) {
            // 只请求全量数据：**不清空图标缓存**（缓存里“这个资源没有图标”的结论也保留，避免再刷一堆请求）
            // Shift+点击才清空图标缓存，用于“图标当时因网络抖动/限流被判定为缺失”的情况
            if (event.shiftKey) resetMetaCache();
            markDirty('resources');
            markDirty('peripherals');
            sendRaw({ action: 'full_request' });
            toast(event.shiftKey ? t('iconsRetried') : t('refreshRequested'), 'info');
        });
        // 等外部资源（含 Font Awesome CSS）加载完，再确认字体是否真的可用：
        // 不可用时工具栏图标会缺失，资源图标仍会用名称兜底显示，不会出现整片空白
        window.addEventListener('load', function () { setTimeout(probeFontAwesome, 0); });
        setTimeout(probeFontAwesome, 4000);
        el('saveBtn').addEventListener('click', function () {
            busyButton('saveBtn', sendRequest('save', {})).then(function (response) {
                const result = response.result || {};
                toast(result.success ? t('saved') : t('saveFailed'), result.success ? 'success' : 'error');
            }).catch(function (err) {
                toast(t('requestFailed', { error: err.message }), 'error');
            });
        });
        el('rescanBtn').addEventListener('click', function () {
            busyButton('rescanBtn', sendRequest('rescan_peripherals', {})).then(function () {
                toast(t('rescanDone'), 'info');
            }).catch(function () { /* ignore */ });
        });
        el('diagnoseBtn').addEventListener('click', function () {
            busyButton('diagnoseBtn', runDiagnose('report'));
        });
        // 物品名翻译开关（Bergamot 英→简中）：点一下开/关，Shift+点击清空翻译缓存
        el('translateBtn').addEventListener('click', function (event) {
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
        el('langBtn').addEventListener('click', function () {
            lang = lang === 'zh' ? 'en' : 'zh';
            el('langLabel').textContent = lang === 'zh' ? '中' : 'EN';
            applyI18n();
            markDirty('resources');
            markDirty('processes');
            markDirty('peripherals');
            markDirty('machines');
            markDirty('deliveries');
            scheduleRender();
        });
        el('sendBtn').addEventListener('click', sendPendingItems);
        el('clearSendBtn').addEventListener('click', function () {
            sendList.clear();
            renderSend();
            toast(t('clearSendList'), 'info');
        });
        el('resourceSearch').addEventListener('input', function (event) {
            searchText = event.target.value.trim();
            renderResources();
        });
        bindSearchClear('resourceSearch', function () {
            searchText = '';
            renderResources();
        });
        // 「外设与定义」：搜索（外设名 / 方块名 / 定义名）+ 排序（默认按外设名字典序）
        el('peripheralSearch').addEventListener('input', function (event) {
            peripheralSearchText = event.target.value.trim();
            renderPeripherals();
        });
        bindSearchClear('peripheralSearch', function () {
            peripheralSearchText = '';
            renderPeripherals();
        });
        el('peripheralSortBtn').addEventListener('click', function () {
            peripheralSortMode = peripheralSortMode === 'peripheral' ? 'block'
                : (peripheralSortMode === 'block' ? 'defs' : 'peripheral');
            renderPeripherals();
            toast(peripheralSortLabelText(), 'info');
        });
        el('resourceSortBtn').addEventListener('click', function () {
            // 数量降序（默认）→ 数量升序 → 字典序 → 数量降序（1.6.11：
            // 以前 'default' 与 'count' 都是“数量降序”，点两下才能回到数量排序，现在一轮只有三种模式）
            const index = SORT_MODES.indexOf(sortMode);
            sortMode = SORT_MODES[(index < 0 ? 0 : index + 1) % SORT_MODES.length];
            renderResources();
            toast(t('sortTitle') + '：' + sortModeLabel(sortMode), 'info');
        });
        el('editorSaveBtn').addEventListener('click', saveEditor);
        el('editorDeleteBtn').addEventListener('click', deleteEditor);
        // 编辑器里按 Enter 直接提交（1.6.9）：例如「新建机器类型」填好名字回车即可保存。
        // 排除容器管理里的资源搜索框（#toolResource，它自己有“放入/取出”按钮）
        // 与勾选框/单选框（Enter 对它们没有“提交”的含义）。
        el('editorBody').addEventListener('keydown', function (event) {
            if (event.key !== 'Enter' && event.keyCode !== 13) return;
            const target = event.target;
            if (!target || String(target.tagName || '').toUpperCase() !== 'INPUT') return;
            if (target.id === 'toolResource') return;
            const type = String(target.type || 'text').toLowerCase();
            if (type === 'checkbox' || type === 'radio') return;
            event.preventDefault();
            saveEditor();
        });
        el('promptConfirmBtn').addEventListener('click', confirmPrompt);
        // 数量框支持四则运算：边输入边显示求解结果
        el('promptInput').addEventListener('input', updatePromptPreview);
        el('promptInput').addEventListener('keydown', function (event) {
            if (event.key === 'Enter') confirmPrompt();
        });
        // 存储整理：把同一种物品（同名同 NBT）散落在多个槽位、可以跨容器的堆按数量升序合并
        el('compactBtn').addEventListener('click', function () {
            busyButton('compactBtn', sendRequest('compact_storage', {})).then(function (response) {
                const result = response.result || {};
                if (result.error) {
                    toast(t('requestFailed', { error: result.error }), 'error');
                    return;
                }
                if (result.planning) {
                    // 1.5.5：整理计划由服务端**分批计算**（不再一口气算十几秒），这里立刻给个反馈，
                    // 进度由 status.compact 随推送更新（“正在计算搬运计划（扫描容器 3/19）”→“整理存储 12/263”）
                    toast(t('compactPlanning'), 'info');
                    compactOptimistic = { planning: true, total: 0, done: 0, moved: 0, items: 0, kinds: 0, at: Date.now() };
                    renderCompactProgress();
                    return;
                }
                if (result.delegated) {
                    // 整理交给了 IFMWorker：进度由 worker 回报（网页进度条照样显示）
                    toast(t('compactDelegated', { worker: result.worker || '?' }), 'info');
                    return;
                }
                const moves = result.moves || 0;
                const items = result.items || 0;
                const kinds = result.kinds || 0;
                toast(t('compactRequested', { n: moves, items: fmtCount(items), kinds: fmtCount(kinds) }), 'info');
                if (moves > 0) {
                    // 服务端下一次状态推送之前，先显示本地占位进度，界面不会看起来没反应
                    compactOptimistic = { total: moves, done: 0, moved: 0, items: items, kinds: kinds, at: Date.now() };
                    renderCompactProgress();
                }
            }).catch(function (err) {
                toast(t('requestFailed', { error: err.message }), 'error');
            });
        });
        el('addMachineTypeBtn').addEventListener('click', function () {
            openEditor('machineTypes', null, {});
        });
        el('addFilterBtn').addEventListener('click', function () {
            openEditor('filters', null, { rules: [] });
        });
        el('stockSearch').addEventListener('input', renderStockList);
        bindSearchClear('stockSearch', renderStockList);
        // 容器管理（在「编辑容器定义」弹窗内）：编辑器 DOM 每次打开都会重建，所以用事件委托绑定
        el('editorBody').addEventListener('click', function (event) {
            if (event.target.closest('#toolRefreshBtn')) {
                refreshContainerTool();
                return;
            }
            if (event.target.closest('#toolPutBtn')) {
                containerMoveRequest('in');
                return;
            }
            if (event.target.closest('#toolTakeBtn')) {
                containerMoveRequest('out');
                return;
            }
            if (event.target.closest('#toolResourceClear')) {
                const field = el('toolResource');
                if (field) field.value = '';
                syncSearchClear('toolResource');
                return;
            }
            const row = event.target.closest('#toolContents [data-take-resource]');
            if (!row) return;
            const field = el('toolResource');
            if (field) field.value = row.getAttribute('data-take-resource') || '';
            const countField = el('toolCount');
            if (countField) countField.value = row.getAttribute('data-take-count') || '1';
            syncSearchClear('toolResource');
            // 点条目里的「取出」按钮：按这一堆的数量立刻搬回存储容器
            if (event.target.closest('[data-take-now]')) containerMoveRequest('out');
        });
        el('editorBody').addEventListener('input', function (event) {
            if (event.target && event.target.id === 'toolResource') syncSearchClear('toolResource');
        });
        // 流程编辑器里改了材料/产物名称：立刻刷新左侧图标
        ['input', 'change'].forEach(function (type) {
            el('editorBody').addEventListener(type, function (event) {
                const node = event.target;
                if (node && node.classList && node.classList.contains('e-id')) refreshElementIcons();
            });
        });
        el('stockList').addEventListener('click', function (event) {
            const pick = event.target.closest('[data-stock-pick]');
            if (pick) pickStock(pick.getAttribute('data-stock-pick'));
        });
        const newProcess = function () {
            // 没有机器类型 / 没有机器时先提醒：这种流程建出来也跑不起来（后端保存时还会再校验一次）
            if (stores.machineTypes.size === 0) {
                toast(t('processNoMachineTypes'), 'error');
                return;
            }
            openEditor('processes', null, { maxMultiplier: 1, inputs: [], outputs: [] });
        };
        // “进程”面板不提供新建：流程只由下单创建（物品/流体 +1、只合成、发送时自动触发）
        el('addProcessBtn').addEventListener('click', newProcess);
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
            peripheralSearch.title = t('searchSyntax');
        }
        // 只需要设置 title 的元素（搜索框的「×」按钮、外设排序按钮等）
        Array.prototype.forEach.call(document.querySelectorAll('[data-i18n-title]'), function (node) {
            node.title = t(node.getAttribute('data-i18n-title'));
        });
        ['resourceSearch', 'peripheralSearch', 'stockSearch'].forEach(syncSearchClear);
        renderVersionLabel();
        setText('langLabel', lang === 'zh' ? '中' : 'EN');
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
            if (!samples || samples.length === 0) return;
            const next = ((iconIndex.get(name) || 0) + 1) % samples.length;
            iconIndex.set(name, next);
            node.innerHTML = plainIconImg(samples[next].kind, samples[next].name);
        });
    }

    // 翻译模块的回调：翻好一批就重画（资源网格 / 悬停详情 / 库存选择器 / 工具栏状态）
    window.ifmOnTranslateUpdate = function () {
        markDirty('resources');
        markDirty('peripherals');
        markDirty('machines');
        scheduleRender();
        refreshElementIcons();
        renderTranslateButton();
        if (document.querySelector('#stockModal.show')) renderStockList();
    };

    // 启动艺术字（与后端 IFMMaster.lua / IFMWorker.lua 用同一份：控制台一眼认出版本）
    const IFM_ART = [
        '     _/_/_/  _/_/_/_/  _/      _/   ',
        '      _/    _/        _/_/  _/_/    ',
        '     _/    _/_/_/    _/  _/  _/     ',
        '    _/    _/        _/      _/      ',
        ' _/_/_/  _/        _/      _/        ',
    ];

    /** 前端启动时把 IFM 艺术字打到浏览器控制台（与后端启动时打的那份一致） */
    function printBanner() {
        IFM_ART.forEach(function (line) { console.log(line); });
        console.log('IFM web client v' + IFM_CLIENT_VERSION + ' - Integrated Factory Manager');
        console.log('room: ' + (room || (new URLSearchParams(window.location.search).get('room') || '')) +
            '  relay: ' + (relayBase || DEFAULT_RELAY) + '  (F12 里能看到服务端日志)');
    }

    function init() {
        printBanner();
        bindResourceGrid();
        bindSendGrid();
        bindProcessList();
        bindDefinitionLists();
        bindPeripheralDrag();
        bindToolbar();
        bindIconTooltips();
        applyI18n();
        loadMissingMeta();
        // icon-exports 元数据（≈7MB）延后一点再拉：先让首屏用接口图标画出来，
        // 索引建好后会自动重画一次换成第 ① 层图标（任务 8）
        setTimeout(loadIconExports, 900);
        syncDeliveryPanelSpacing();
        // 先画一次外设/过滤器面板：没有数据时也能看到「暂无数据」与排序模式
        renderPeripherals();
        renderFilterPanel();
        renderWorkers();
        // 物品名翻译：按上次的开关状态初始化（开启时会自动补翻译并重画界面）
        if (window.IFMTranslate) window.IFMTranslate.init();
        renderTranslateButton();
        window.addEventListener('resize', syncDeliveryPanelSpacing);
        setConnectionStatus('offline');
        setInterval(rotateFilterIcons, ROTATE_MS);
        setInterval(function () {
            // 看门狗：中继静默断开时浏览器不会触发 onclose，页面会一直显示旧快照、
            // 发出去的请求也进不去服务端。超过 STALL_MS 没收到服务端任何数据就主动重连一次；
            // 超过 4 × STALL_MS（默认 60 秒）仍然没有任何数据 → 认定服务端长时间失联，
            // 收起界面回到登录页（同时清掉 everSeenServer：服务端回来时重新走一遍“先等数据再切界面”）。
            const silentMs = Date.now() - (lastServerDataAt || 0);
            const longLost = everSeenServer && silentMs > STALL_MS * 4;
            if (longLost) {
                // 长时间失联：收起界面回到登录页（清掉 everSeenServer，服务端回来时重新“先等数据再切界面”）
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
                // 已经在登录页：仍然按 20 秒一次重连（服务端回来后 markServerSeen 会自动切回主界面）
                if (!longLost) return;
                if (Date.now() - lastForcedReconnectAt < 20000) return;
                lastForcedReconnectAt = Date.now();
                if (room) connect(room);
                return;
            }
            // 中继可能连得上（WebSocket 已 open）而服务端并不在线：这时绝不能继续显示“已连接”
            setConnectionStatus('connecting');
            const stallText = serverSeen ? t('wsStalled') : t('wsNoServer', { room: room });
            setText('loginError', stallText);
            // 从没收到过服务端数据（服务端没在跑）：把登录遮罩摆回来并**稳定停在那里**，
            // 后台仍然按 20 秒一次重连。注意只在“本页从未见过服务端”时才切界面，
            // 否则中继抖动会把正在使用的界面顶掉（以前还会因为旧连接的回调而反复闪）。
            if (!serverSeen && !everSeenServer) {
                setDisplay('loginOverlay', 'flex');
                setDisplay('app', 'none');
            }
            if (!stallNotified) {
                stallNotified = true;
                toast(stallText, 'error');
            }
            if (Date.now() - lastForcedReconnectAt < 20000) return;
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
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
