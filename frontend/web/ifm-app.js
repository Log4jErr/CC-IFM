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
            // 中键 = 设置发送数量；Shift+中键 = 设置合成数量（1.6.12：与以往相反，对调）
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

    // 用户第 6 项：「发送中」栏也配一个"全部删除"（以前只有「待发送」有清空按钮）。
    // 服务端 delete_deliveries 一次清掉整条发送队列（同时清掉每条的"在飞搬运"记忆）。
    function clearAllDeliveries() {
        if (stores.deliveries.size === 0 && optimisticDeliveries.length === 0) {
            toast(t('deliveriesEmpty'), 'info');
            return;
        }
        if (!window.confirm(t('clearDeliveriesConfirm'))) return;
        const backup = new Map(stores.deliveries);
        stores.deliveries.clear();              // 乐观清空，失败再放回
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
    /// 一条缺失定义对应的删除请求（action + payload）：单条删除与「一键删除」共用
    function missingDeleteRequest(item) {
        // 用户第 4 项（本轮）：机器直接引用的外设没有"定义"可删 —— 删的是机器里那条引用
        // （服务端会把它从该机器的输入/输出/信号列表里移除）。
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

    /// 删除一条缺失定义：返回 true = 服务端确实删掉了（单条 / 一键删除都走它）
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

    /// 删掉缺失定义之后要重画的面板（外设 / 定义 / 资源都可能跟着变）
    /// 顺带请求一次全量同步（用户第 2 项）：网页上的"外设缺失"列表可能比服务端旧
    /// （推送丢过 / 服务端返回过"定义不存在"），同步一次就能把失效条目一次收干净。
    function afterMissingDelete() {
        markDirty('peripherals');
        markDirty('containers');
        markDirty('signals');
        markDirty('missing');
        scheduleRender();
        if (connected) sendRaw({ action: 'full_request' });
    }

    /// 删除成功后立刻把这张卡片从本地列表移掉（服务端的全量同步随后还会覆盖一遍）——
    /// 用户第 1 项：服务端删掉之后网页却还挂着那张卡片，用户会以为"没删掉"。
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

    // 用户第 2 项：外设缺失卡片上的「一键删除」—— 把**这一屏显示的**缺失定义一次删掉
    // （与卡片标题上的数量一致：有搜索条件时只删匹配到的那些，和被隐藏的条目无关）。
    // 逐条**串行**发请求：前一条失败不会连带后面的条目一起失败（服务端每个请求都是独立处理的），
    // 结果逐条汇总给用户。
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
        // 用户第 1/3 项：逐条**并行**发请求。以前这里是串行 Promise 链（chain = chain.then(...)）——
        // 只要有一条请求没回来（超时 / 丢包 / 服务端处理慢），后面的条目就永远轮不到发：
        // 现场表现正是"两个缺失外设只删掉一个、再点一下还是那一个（already gone）、刷新网页才恢复"。
        // 现在：去重 → 并行发 → 无论成功失败都同步一次（把失效卡片收干净），并乐观移除已删的卡片。
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
        // 「外设与定义」板块被拆成了四个容器（缺失 / 机器类型 / 存储 / 未分配），
        // 点击委托必须每个容器都绑一遍 —— 以前只绑了 peripheralList，
        // 结果机器类型卡片上的「+ 机器」与机器卡片都点不动（1.6.5 修）。
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
            // 用户第 3 项：只读机器（海龟合成器）**整张卡片内部**都不响应点击 ——
            // 机器卡片 / 机器类型卡片 / 里面的外设卡片都不该弹出编辑页（机器是自动生成的，不给人工改）。
            // 必须放在最前面：机器卡片嵌在机器类型卡片里，不拦住的话点击会一路冒泡到类型卡片。
            const readOnlyCard = event.target.closest('[data-machine-card]');
            if (readOnlyCard && machineIsReadOnly(readOnlyCard.getAttribute('data-machine-card'))) return;
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
            // 用户第 1 项：机器卡片**里面**的外设卡片，点开的是「容器定义」，不是这台机器 ——
            // 必须放在 [data-edit-machine] 之前判定（以前点芯片会被机器卡片接走，弹出机器编辑页）。
            // 只认机器位置里的芯片（带 data-pc-machine），别处的芯片各有自己的分支。
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
            // 机器类型卡片右上角的「+ 机器」：先于卡片本身（编辑机器类型）判定
            const addMachine = event.target.closest('[data-add-machine]');
            if (addMachine) {
                // 本轮第 2 项：不再弹「新建机器」窗口 —— 直接按默认参数建一台（parallel = 1，
                // 输入/输出/信号都留空），用户可以立刻把外设拖进它的位置，之后点机器卡片再改设置。
                // 名字与编辑器里的规则完全一致：按类型推导 + 自动去重（机器 → 机器2 …）。
                const type = String(addMachine.getAttribute('data-add-machine') || '');
                if (!type) {
                    // 「机器类型 ?」那块（类型已经没了的孤立机器）没有类型可推导 → 仍然走编辑器选类型
                    openEditor('machines', null, { type: '', parallel: 1 });
                    return;
                }
                const name = uniqueDefinitionName('machines', type, null);
                const fields = ['itemInputs', 'fluidInputs', 'signals', 'itemOutputs', 'fluidOutputs'];
                const data = { type: type, parallel: 1 };
                fields.forEach(function (field) { data[field] = []; });
                // 用户第 1 项：按钮要**立刻有反应** —— 先在本地把这台机器建出来并立即重画
                //（机器卡片当场出现，不用等服务端回包）。服务端拒绝时再回滚并提示。
                // 写法与 updateMachine 的乐观更新保持一致（本地改 store → renderPeripherals → 失败回滚）。
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
                    // 以服务端为准（它可能改名去重）：拿到最终定义后重画一次
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
                // 用户第 3 项：预设类型（海龟合成器）不给编辑入口 —— 渲染时本来就不写这个属性，
                // 这里再挡一次（旧缓存 / 手工改 DOM 也进不来）。
                if (machineTypeIsReadOnly(machineType.getAttribute('data-edit-machine-type'))) return;
                openEditor('machineTypes', machineType.getAttribute('data-edit-machine-type'));
                return;
            }
            // 外设缺失卡片右上角的「一键删除」：所有缺失定义一次删掉（用户第 2 项）
            // 必须先于单条删除判定：这个按钮在卡片头里，不在任何 chip 上
            const removeAllMissing = event.target.closest('[data-delete-missing-all]');
            if (removeAllMissing) {
                deleteAllMissingDefinitions(removeAllMissing);
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

    /// 用户第 5 项：容器管理里按**槽位**画格子 —— 有东西的格子显示物品与「取出」，
    /// 空格子写「空槽位」。每格左上角都标 #槽位号；服务端只发"有东西的槽位"，空格子由前端补全。
    function containerCellHtml(slot, entry, kind) {
        const head = '<span class="slot-index" title="' + escapeHtml(t('slotNumber', { n: slot })) + '">#' +
            escapeHtml(String(slot)) + '</span>';
        if (!entry) {
            return '<div class="slot-cell empty">' + head +
                '<span class="slot-empty">' + escapeHtml(t('containerEmptySlot')) + '</span></div>';
        }
        const isFluid = kind === 'fluid';
        const itemKind = isFluid ? 'fluid' : 'item';
        const name = entry.name;
        const count = isFluid ? entry.amount : entry.count;
        const ref = isFluid ? entry.tank : entry.slot;
        queueMeta(itemKind, name);
        return '<div class="slot-cell" data-take-resource="' + escapeHtml(name) + '" data-take-count="' +
            escapeHtml(String(count || 0)) + '">' + head +
            '<span class="slot-icon">' + plainIconImg(itemKind, name, entry.nbt) + '</span>' +
            '<span class="slot-name" title="' + escapeHtml(name) + '">' +
            escapeHtml(displayName(itemKind, name)) + '</span>' +
            '<span class="slot-count">' + escapeHtml(fmtCount(count || 0)) + '</span>' +
            '<button class="btn-pixel" type="button" data-take-now="' + escapeHtml(String(ref)) + '">' +
            escapeHtml(t('containerTake')) + '</button>' +
            '</div>';
    }

    /// 按槽位总数把整张网格画出来（1 … view.slots）。
    /// 服务端只发有东西的槽位；槽位号超出 view.slots 的（槽位数那一刻读不准）也照画，不能把东西藏起来。
    function containerSlotGridHtml(view) {
        const total = Math.max(0, Math.floor(Number(view.slots) || 0));
        const bySlot = {};
        asArray(view.items).forEach(function (entry) {
            const slot = Math.floor(Number(entry.slot) || 0);
            if (slot > 0) bySlot[slot] = entry;
        });
        const cells = [];
        for (let slot = 1; slot <= total; slot += 1) {
            cells.push(containerCellHtml(slot, bySlot[slot], 'item'));
        }
        Object.keys(bySlot).map(Number).sort(function (a, b) { return a - b; }).forEach(function (slot) {
            if (slot > total) cells.push(containerCellHtml(slot, bySlot[slot], 'item'));
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

    function containerRowHtml(kind, name, count, ref, nbt) {
        queueMeta(kind, name);
        // nbt = 这个槽位的 NBT（CC:T 只给哈希）：拿它去 icon-exports 里挑“NBT 最接近”的变体图标，
        // 挑不到就退到同一个注册名的图标（不会因为 NBT 不同而改用 blocksitems 的图）
        return '<div class="stock-item" data-take-resource="' + escapeHtml(name) + '" data-take-count="' +
            escapeHtml(String(count || 0)) + '">' +
            '<span class="icon">' + plainIconImg(kind, name, nbt) + '</span>' +
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
        // 用户第 5 项：物品容器一律画成"槽位网格"（含空槽位 + #槽位号）；
        // 流体容器没有槽位总数的数据，退回原来的行列表（每行也带 #储罐号）。
        if (view.kind === 'item' && Math.floor(Number(view.slots) || 0) > 0) {
            contents.innerHTML = containerSlotGridHtml(view);
        } else {
            const rows = [];
            asArray(view.items).forEach(function (entry) {
                rows.push(containerRowHtml('item', entry.name, entry.count, entry.slot, entry.nbt));
            });
            asArray(view.fluids).forEach(function (entry) {
                rows.push(containerRowHtml('fluid', entry.name, entry.amount, entry.tank));
            });
            contents.innerHTML = rows.length
                ? '<div class="stock-list">' + rows.join('') + '</div>'
                : '<span class="muted">' + escapeHtml(t('containerEmpty')) + '</span>';
        }
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
            // 1.7.0：手动搬运进「手动操作队列」异步执行（有 worker 时交给 worker）——
            // 这里先给一个"已排队"的提示，稍后再刷新一次容器内容（那时搬运多半已经做完）
            if (result.queued) {
                toast(t('containerQueued', { n: fmtCount(count) }), 'info');
                refreshContainerTool();
                setTimeout(function () { refreshContainerTool(); }, 600);
                return;
            }
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

    // 机器里的容器定义名：非输出容器都用外设名作定义名（服务端 Store:containerNameFor），
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

    // 机器里引用的是红石中继器的外设名（1.6.9：信号不再需要命名，也不再需要“信号定义”）。
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
    /// quiet = true：不加也不报错（批量拖拽时用）：类型不匹配只记数，由 addPeripheralsToMachine 汇总
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
            }, quiet ? null : t('machinePeripheralAdded', { name: peripheral, machine: machineName }));
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
        // 1.8.0：卡片按角色合并了（物品/流体同一张），drop 属性的值是 "any" —— 种类由芯片自己带
        // （新版本的外设芯片一定有 data-drag-kind；老版本没有时按外设能力推断）。
        const containerTargets = [
            ['data-storage-drop', 'storage'],
            ['data-input-drop', 'input'],
            ['data-output-drop', 'output'],
        ];
        for (let i = 0; i < containerTargets.length; i += 1) {
            const mark = target.getAttribute(containerTargets[i][0]);
            if (!mark) continue;
            if (kind === 'signal') return false;                 // 红石中继器不是容器
            if (mark === 'any') {
                return kind !== null || !!caps.inventory || !!caps.fluid_storage;
            }
            return kind !== null && kind === (mark === 'fluid' ? 'fluid' : 'item');
        }
        // 用户第 3 项：只读机器（海龟合成器）的输入/输出位置不接受任何拖入 ——
        // 不判定为可接收（边框不会高亮），放开时也被 drop 处理器吞掉。
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

    // 拖拽开始：把所有能接收当前芯片的位置 / 存储卡片都标出来（.drop-ok 边框高亮），
    // 这样不用一个个试就知道能放到哪里；不能接收的（比如流体芯片拖到物品存储卡片）不亮。
    function markDropTargets(payload) {
        const nodes = document.querySelectorAll('[data-machine-slot], [data-storage-drop], [data-input-drop], [data-output-drop]');
        Array.prototype.forEach.call(nodes, function (node) {
            node.classList.toggle('drop-ok', dragAcceptable(node, payload));
        });
    }

    // 拖拽绑定：document 级（卡片每次重画都会重建，委托绑定最省事）
    // ===== 外设卡片的批量选择（用户第 6 项）：Ctrl+点击 / 右键框选 =====
    // 框选：在外设面板里按住右键拖出一个虚线框，松开时框到的卡片成为选择（Ctrl 追加）。
    // 鼠标事件用 capture 阶段监听并阻止默认行为（右键菜单、文本选择、以及面板里原有的点击处理）。
    function bindPeripheralSelection() {
        /// 用户第 1/3 项：**整个「外设与定义」面板**都是框选区域（以前只认 peripheralList /
        /// machineTypeList 两个列表）——
        ///   * 在存储容器卡片（卡片本体，不是卡片里的芯片）上右键时框选起不来；
        ///   * 输入容器卡片、输出容器卡片"附近"（卡片之间的空白、卡片右侧）也起不来。
        /// 面板级判定把这些问题一次解决：卡片本体、卡片之间的间隙、列表外的空白都能起手，
        /// 框选目标则是面板里所有"代表外设的芯片"（方块卡片芯片 + 机器/容器卡片里的 pc-chip）。
        /// 面板用 **class** 标记而不是 id：run_dom_smoke.js 的"结构漂移"检查比对每个 id 的
        /// 祖先链（tag + id），给 <section> 加 id 会让它的所有子元素的链都变一次 → 被判成"元素搬家"。
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
        /// 芯片代表的外设名（机器里的芯片用 data-pc-peripheral，外设面板的芯片用 data-drag-peripheral）
        const chipName = function (chip) {
            if (!chip || !chip.getAttribute) return '';
            const machine = chip.getAttribute('data-pc-peripheral');
            const value = machine !== null && machine !== '' ? machine : chip.getAttribute('data-drag-peripheral');
            return String(value || '');
        };

        // Ctrl / Cmd + 左键：切换这个外设的选中状态（capture 阶段拦下，避免同时打开编辑器/开始拖拽）
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

        // 点面板空白处：清空选择
        document.addEventListener('click', function (event) {
            if (event.ctrlKey || event.metaKey) return;
            if (!panelOf(event.target)) return;
            if (chipUnder(event.target)) return;
            clearPeripheralSelection();
        });

        // Esc：清空选择
        document.addEventListener('keydown', function (event) {
            if (event.key === 'Escape') clearPeripheralSelection();
        });

        let marquee = null;      // { startX, startY, additive }
        const marqueeNode = function () {
            let node = el('selectMarquee');
            if (!node) {
                /// index.html 里本来就有这个元素；万一被改没了就现场补一个
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
            /// 实时高亮框到的芯片（松开时才真的改选择）
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
            // 只在两个面板里、且是右键时开始框选（左键留给"拖动卡片"）
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
        // 右键拖动期间不许弹浏览器右键菜单（面板里的右键只用于框选）
        document.addEventListener('contextmenu', function (event) {
            if (marquee || panelOf(event.target)) event.preventDefault();
        }, true);
    }

    /// 当前拖拽要带过去的全部外设（用户第 6 项：拖着选中的其中一张 = 把选中的全部一起带走）。
    /// 返回 [{ peripheral, dragKind }, ...]；"手上拖的那张"永远排第一个。
    function dragPeripheralList(payload) {
        const out = [{ peripheral: payload.peripheral, dragKind: payload.dragKind }];
        if (!payload.peripheral || selectedPeripheralCards.size < 2) return out;
        if (!selectedPeripheralCards.has(String(payload.peripheral))) return out;
        selectedPeripheralCards.forEach(function (name) {
            if (String(name) !== String(payload.peripheral)) {
                /// 其余卡片不带"来源芯片的种类"：各按自己的能力推断（混选物品 + 流体容器时不会互相带偏）
                out.push({ peripheral: name, dragKind: null });
            }
        });
        return out;
    }

    /// 批量把外设加进机器的某个位置：类型不匹配的直接忽略（只汇总一条提示，不弹一屏错误）。
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
                /// 只有第一张弹"已加入"提示，其余安静加入，最后统一汇总（避免一屏 toast）
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
        document.addEventListener('dragstart', function (event) {
            const card = event.target.closest('[data-drag-peripheral]');
            const chip = event.target.closest('[data-pc-peripheral]');
            if (!card && !chip) return;
            // 用户第 3 项：只读机器（海龟合成器）里的外设卡片不能拖（渲染时就没写 draggable，
            // 这里再挡一次：拖选文本也可能触发原生 dragstart）
            if (chip && chip.getAttribute('data-pc-readonly')) return;
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
                event.target.closest('[data-storage-drop]') || event.target.closest('[data-input-drop]') ||
                // 用户第 1 项：漏了输出容器卡片 —— 不 preventDefault 时浏览器不认这个放置目标，
                // drop 事件根本不会来（表现就是"拖到输出卡片上没有任何反应"）
                event.target.closest('[data-output-drop]');
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
            const containerCard = event.target.closest('[data-storage-drop]') ||
                event.target.closest('[data-input-drop]') || event.target.closest('[data-output-drop]');
            if (!slot && !containerCard) return;
            event.preventDefault();
            payload.dropped = true;
            clearHighlight();
            // 用户第 3 项：只读机器（海龟合成器）不接受拖入 —— 这里必须把 dropped 置真再返回，
            // 否则 dragend 会把它当成"拖到机器外面"= 从原来的机器里移出（把用户的外设弄丢）。
            if (slot && machineIsReadOnly(slot.getAttribute('data-machine'))) return;
            // 拖到「存储 / 输入 / 输出 容器」卡片（1.8.0：一张卡片按角色合并了物品与流体）
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
                    return;                                          // 拖回同一张卡片：什么都不做
                }
                if (role === 'output') {
                    // 用户第 6 项：输出角色要给每条定义起名字，一次只弹一个弹窗；
                    // 批量选择时只处理手上拖的那张，剩下的提示用户逐个来。
                    if (dragPeripheralList(payload).length > 1) {
                        toast(t('containerRoleOneByOne'), 'info');
                    }
                    // 用户第 6 项：拖进输出卡片 = 弹出"外设/种类/角色（输出）已填好"的定义弹窗，名称等用户填
                    openContainerForRole(role, kind, payload.peripheral);
                    return;
                }
                const entries = dragPeripheralList(payload);
                if (payload.fromMachine) {
                    // 从机器位置拖到容器卡片：这是“移出机器”的意图，先摘掉机器归属
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
                // 拖回原位：什么都不做
                if (payload.fromMachine === machineName && payload.fromSlot === slotId &&
                    batch.length < 2) {
                    return;
                }
                // 拖到另一个位置（同一台机器的另一个槽位，或另一台机器）= 复制归属（1.6.10）：
                // 输入容器的外设拖到输出容器时，输入容器那张卡片要保留（用户明确要求）；
                // 交互容器与红石中继器本来就允许被多处引用。
                // 想从某个位置移除：把它拖到机器卡片外面（dragend 里处理），或点卡片上的 ×。
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

    // ===== 存储 / 输入 / 输出 容器卡片：拖外设卡片进来 = 设成该角色的容器；拖出去（或点 ×）= 删掉这条定义 =====
    /// 拖到按角色合并的卡片上时，判断要建哪种容器定义：芯片种类 → 外设能力 → 兜底物品容器
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

    /// 打开"外设 / 种类 / 角色已填好"的容器定义弹窗（1.8.0，用户第 6 项：名称等用户填）。
    /// 已经存在这个外设的同种类定义时，直接打开那条定义让用户改角色。
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

    /// quiet = true：不加提示（批量拖拽时用），由 addPeripheralsToContainerRole 汇总一条
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
            if (result.error) throw new Error(result.error);
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

    /// 批量把外设设成某个角色的容器（用户第 6 项）：种类按每张卡片自己的能力推断，
    /// 能力不匹配的忽略，最后汇总一条提示。
    function addPeripheralsToContainerRole(role, entries) {
        let chain = Promise.resolve();
        let added = 0;
        let skipped = 0;
        entries.forEach(function (entry) {
            chain = chain.then(function () {
                const caps = peripheralCapabilities(entry.peripheral);
                /// 拖拽来源带种类就用它，否则按能力（同时是物品+流体容器时优先物品，和单张拖拽一致）
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

    // ===== 设置面板 =====
    // 调度权重（1.8.0）：每条队列 0 ~ 1 的小数，**所有队列加起来 = 1**。
    //   * 滑动一条滑条会按比例影响其它滑条（归一化）：例如把 A 从 0.2 拉到 0.5，
    //     其余队列各自的权重会按原比例缩小，使总和仍然是 1；
    //   * 0 = 这条队列本轮完全不参与轮转：该行文字变红 + 警告图标 + 悬停说明；
    //   * 非 0 的最小值是 0.01（n 条队列时单条最大 = 1 - 0.01*(n-1)）。
    const SCHEDULE_QUEUES = ['process', 'storageScan', 'inputScan', 'interactionScan', 'outputScan',
        'inventoryIn', 'inventoryOut', 'compact', 'stackScan', 'detail', 'manual'];
    const WEIGHT_MIN = 0.01;
    const WEIGHT_ROUND = 100;                 // 四舍五入到两位小数

    function scheduleQueueLabelKey(name) {
        return 'scheduleQueue' + name.charAt(0).toUpperCase() + name.slice(1);
    }

    function roundWeight(value) {
        return Math.round(Number(value) * WEIGHT_ROUND) / WEIGHT_ROUND;
    }

    /// 单条队列的最大权重：其它队列每条至少留 0.01 ⇒ 1 - 0.01n（n = 滑条总数）
    function weightMax() {
        return roundWeight(1 - WEIGHT_MIN * SCHEDULE_QUEUES.length);
    }

    /// 把任意值收成合法权重：0.01 ~ weightMax()、两位小数。
    /// **不允许 0**（用户要求）：一旦允许，用户可能把所有滑条都拖到 0 → 没法归一化（除零）。
    function clampWeight(value) {
        const number = Number(value);
        if (!isFinite(number) || number < WEIGHT_MIN) return WEIGHT_MIN;
        return Math.min(weightMax(), roundWeight(number));
    }

    /// 界面（拖滑条）用的权重：只收拢范围，**不要**四舍五入到两位小数（用户第 3 项）——
    /// 量化到整数分会让"稍微减一点"变成"只给前几条各加 1 分"。服务端保存时仍按整数分归一化，
    /// 所以保存后面板回到 0.01 的整数倍是正常的（拖动过程是连续的）。
    function displayWeight(value) {
        const number = Number(value);
        if (!isFinite(number) || number < WEIGHT_MIN) return WEIGHT_MIN;
        return Math.min(weightMax(), Math.round(number * 1e6) / 1e6);
    }

    /// 平均分（按整数分算，保证合计正好 1）
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

    /// 把任意一组权重收成"每条 ≥ 0.01、合计正好 1"（整数分算法，无四舍五入误差）
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

    /// 主控本机协程池开关（用户第 1 项）：服务端设置，**缺省关**（用户第 3 项）。
    /// 关掉后主控不再自己处理任务 —— 但**只在有 worker 在线时**才被尊重（后端保证）。
    function scheduleLocalPool() {
        const schedule = (status && status.schedule) || {};
        return schedule.localPool === true;
    }

    /// 给网页发日志的开关（用户第 1 项）：服务端设置，**缺省关**（用户第 3 项）。
    function scheduleSendLog() {
        const schedule = (status && status.schedule) || {};
        return schedule.sendLog === true;
    }

    /// 自动整理的空槽位阈值（用户第 4 项）：服务端设置，缺省 0.3（存储容器空槽位不足 30% 才整理）。
    function scheduleCompactFreeRatio() {
        const schedule = (status && status.schedule) || {};
        const value = Number(schedule.compactFreeRatio);
        if (!isFinite(value) || value < 0) return 0.3;
        return Math.min(1, value);
    }

    /// 服务端当前的权重（缺失 / 旧数据时收进合法范围；全 0 时平均分）
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

    /// 归一化：fixedName 固定为 value，其它队列**按当前值比例分摊**剩下的权重（合计正好 1）。
    /// 用户第 3 项：不再量化到整数分 —— 整数分下"把一条从 0.11 减到 0.05"只会让前 6 条各加 1 分、
    /// 后两条看着一动不动；改成按比例（浮点）后，其它每一条都会按同一比例变化。
    /// 下限保护：任何一条都不低于 WEIGHT_MIN（weightMax() 保证剩下的一定够，钉下限只是保险）。
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


    /// 把一组权重写回界面（不改 DOM 结构，只改值/颜色/图标 —— 拖动过程中不会打断）
    function applyWeightValues(slices) {
        SCHEDULE_QUEUES.forEach(function (name) {
            const value = String(displayWeight(slices[name]));
            const range = el('sliceRange_' + name);
            const number = el('slice_' + name);
            const label = el('sliceLabel_' + name);
            if (range) range.value = value;
            if (number && document.activeElement !== number) number.value = value;
            const off = Number(slices[name]) <= WEIGHT_MIN + 1e-9;      // 已经到最小值（几乎轮不到）
            if (label) {
                label.className = 'settings-label' + (off ? ' warn' : '');
                label.title = off ? t('scheduleZeroWarning', { queue: t(scheduleQueueLabelKey(name)) }) : '';
                const icon = label.querySelector ? label.querySelector('.warn-icon') : null;
                if (icon) icon.style.display = off ? '' : 'none';
            }
        });
    }

    function renderSettings() {
        const body = el('settingsBody');
        if (!body) return;
        const slices = scheduleSlices();
        const sliceSignature = SCHEDULE_QUEUES.map(function (name) { return slices[name]; }).join(',');
        // 签名带上语言：中/英切换时按新语言重画（只比数值的话切语言不刷新，面板会停在旧语言）
        const signature = lang + '|' + sliceSignature + '|pool=' + (scheduleLocalPool() ? '1' : '0') +
            '|log=' + (scheduleSendLog() ? '1' : '0') +
            '|cf=' + scheduleCompactFreeRatio();
        if (body.getAttribute('data-scan') === signature) return;             // 值没变：不重画
        if (document.activeElement && body.contains(document.activeElement)) return;  // 正在输入：不打断
        body.setAttribute('data-scan', signature);
        // 每行的文本 / 滑条 / 数字框**直接作为同一个 Grid 的子项**（用户第 1 项）：
        // 三列由 Grid 自己对齐（标签列 = max-content），不再手算文字宽度 —— 换语言/字号都不会错位。
        body.style.display = 'grid';
        body.style.gridTemplateColumns = 'max-content 1fr 72px';
        body.style.alignItems = 'center';
        body.style.gap = '4px 10px';
        const maxWeight = weightMax();               // 用户第 4 项：滑条最右 = 1 - 0.01n
        const rowHtml = SCHEDULE_QUEUES.map(function (name) {
            const value = displayWeight(slices[name]);
            const off = value <= WEIGHT_MIN + 1e-9;                      // 最小值：标红 + 警告图标
            const warning = t('scheduleZeroWarning', { queue: t(scheduleQueueLabelKey(name)) });
            // 用户第 4 项：滑条两端就是真实边界 —— 最左 = 0.01，最右 = 1-0.01n（不再是 0 ~ 1）
            return '<span class="settings-label' + (off ? ' warn' : '') + '" id="sliceLabel_' + name + '"' +
                ' title="' + (off ? escapeHtml(warning) : '') + '">' +
                escapeHtml(t(scheduleQueueLabelKey(name))) +
                '<i class="fa fa-exclamation-triangle warn-icon"' + (off ? '' : ' style="display:none"') +
                ' title="' + escapeHtml(t('scheduleZeroWarningShort')) + '"></i>' +
                '</span>' +
                '<input type="range" id="sliceRange_' + name + '" min="' + WEIGHT_MIN + '" max="' + maxWeight +
                '" step="any" value="' + value + '" title="' + escapeHtml(t('scheduleSliderHint')) + '">' +
                '<input type="number" id="slice_' + name + '" min="' + WEIGHT_MIN + '" max="' + maxWeight +
                '" step="any" value="' + value + '">';
        }).join('');
        body.innerHTML =
            '<div style="grid-column:1 / -1"><strong>' + escapeHtml(t('scheduleTitle')) + '</strong>' +
            '<div class="muted" style="margin:2px 0 6px">' + escapeHtml(t('scheduleHint')) + ' ' +
            escapeHtml(t('scheduleHint2')) + '</div></div>' + rowHtml +
            // 用户第 1 项：主控本机协程池开关（只在有 worker 在线时才被尊重，后端保证）
            '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('settingLocalPool')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px">' +
            '<input type="checkbox" data-local-pool="1"' + (scheduleLocalPool() ? ' checked' : '') + '>' +
            escapeHtml(t('settingLocalPoolHint')) + '</label>' +
            // 用户第 1 项：给网页发日志的开关（日志是 WS 上最大的一块流量）
            '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('settingSendLog')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px">' +
            '<input type="checkbox" data-send-log="1"' + (scheduleSendLog() ? ' checked' : '') + '>' +
            escapeHtml(t('settingSendLogHint')) + '</label>' +
            // 用户第 4 项：自动整理的空槽位阈值（输入框，0 ~ 1；空槽位比例低于它才整理）
            '<span class="settings-label" style="grid-column:1">' + escapeHtml(t('settingCompactFree')) + '</span>' +
            '<label class="muted" style="grid-column:2 / -1;display:flex;align-items:center;gap:8px">' +
            '<input type="number" id="compactFreeRatio" min="0" max="1" step="0.01" style="width:72px"' +
            ' value="' + escapeHtml(String(scheduleCompactFreeRatio())) + '">' +
            escapeHtml(t('settingCompactFreeHint')) + '</label>';
        // 用户第 5 项：去掉「保存」按钮 —— 松开滑条 / 改开关立即生效（见下面的 change 监听）
        applyWeightValues(slices);
        // 滑条：拖动时重新归一化（其它滑条按比例变化）；数字框同样归一化（非 0 至少 0.01）
        let current = slices;
        SCHEDULE_QUEUES.forEach(function (name) {
            const range = el('sliceRange_' + name);
            const number = el('slice_' + name);
            if (range) {
                range.addEventListener('input', function () {
                    current = rebalanceWeights(current, name, Number(range.value));
                    applyWeightValues(current);
                });
                // 用户第 5 项：松开滑条立即生效（不需要再按保存）
                range.addEventListener('change', function () { saveScheduleSettings(current); });
            }
            if (number) {
                number.addEventListener('input', function () {
                    current = rebalanceWeights(current, name, Number(number.value));
                    applyWeightValues(current);
                });
                number.addEventListener('change', function () { saveScheduleSettings(current); });
            }
        });
        // 开关：勾/取消立即提交（权重沿用当前面板值）
        const poolBox = document.querySelector ? document.querySelector('[data-local-pool]') : null;
        if (poolBox) {
            poolBox.addEventListener('change', function () {
                saveScheduleSettings(current, { localPool: poolBox.checked });
            });
        }
        const logBox = document.querySelector ? document.querySelector('[data-send-log]') : null;
        if (logBox) {
            logBox.addEventListener('change', function () {
                saveScheduleSettings(current, { sendLog: logBox.checked });
            });
        }
        // 用户第 4 项：自动整理的空槽位阈值（输入框）：改完（回车 / 失焦）立即生效
        const freeBox = document.getElementById ? document.getElementById('compactFreeRatio') : null;
        if (freeBox) {
            freeBox.addEventListener('change', function () {
                const value = Math.min(1, Math.max(0, Number(freeBox.value)));
                const safe = isFinite(value) ? Math.round(value * 100) / 100 : scheduleCompactFreeRatio();
                freeBox.value = String(safe);
                saveScheduleSettings(current, { compactFreeRatio: safe });
            });
        }
    }

    /// 保存调度设置（权重 + 可选的开关）。**立即生效**：不按小数位截断任何值（用户第 2/5 项），
    /// 只把每条收拢到 [0.01, 1-0.01n]；服务端会按同一套规则归一化到合计 1。
    function saveScheduleSettings(weights, options) {
        const slices = {};
        SCHEDULE_QUEUES.forEach(function (name) { slices[name] = displayWeight(weights[name]); });
        const payload = { slices: slices };
        if (options && typeof options.localPool === 'boolean') payload.localPool = options.localPool;
        if (options && typeof options.sendLog === 'boolean') payload.sendLog = options.sendLog;
        // 用户第 4 项：自动整理的空槽位阈值（0 ~ 1）
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


    // ===================== 启动自检 / 错误可见化 =====================
    // 需求背景：以前任何一步初始化抛错，后面的绑定（含连接按钮）就全都不会执行，
    // 用户只会看到"点连接没反应"，完全不知道哪里坏了。这里把每一步单独保护起来，
    // 并把错误直接写到登录框上（同时进控制台），坏一处不会连带整页按钮失灵。
    function reportBootError(step, err) {
        const message = '[IFM] init step "' + step + '" failed: ' +
            (err && err.message ? err.message : String(err));
        try {
            if (window.console && console.error) console.error(message, err);
        } catch (ignored) { /* ignore */ }
        const node = el('loginError');
        if (node) node.textContent = message;
        try {
            setDisplay('loginOverlay', 'flex');
            setDisplay('app', 'none');
        } catch (ignored2) { /* ignore */ }
    }

    function safeStep(step, fn) {
        try {
            fn();
        } catch (err) {
            reportBootError(step, err);
        }
    }
    window.ifmSafeStep = safeStep;

    // ===================== 版本对账 / 页面探针 =====================
    // 踩过的坑：网页只更新了一半（旧 index.html + 新 web/*.js）时，JS 找不到元素，
    // 只报 "el(...) is null"，完全看不出是"哪个文件旧了"。这里做两件事：
    //   ① 版本对账：index.html 上写了 data-ifm-build，和 JS 里这份构建号比对，不一致就直接说明；
    //   ② 页面探针：把当前 URL、实际加载到的脚本路径、关键元素在不在打印出来。
    const IFM_APP_BUILD = '214';
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
    // 启动时对账：index.html 与 web/*.js 是不是同一次构建（不一致时页面会明确说出来）
    function checkBuildStamp() {
        const html = pageBuild();
        if (!html || html === IFM_APP_BUILD) return;
        const message = '[IFM] index.html is build ' + html + ' but web/*.js is build ' + IFM_APP_BUILD +
            ' - redeploy index.html together with web/*.js (frontend files are half-updated)';
        try {
            if (window.console && console.error) console.error(message);
        } catch (ignored) { /* ignore */ }
        const node = el('loginError');
        if (node) node.textContent = message;
    }
    window.ifmPageProbe = pageProbe;

    // 而是把缺的 id 明确报出来。踩过的坑：网页只更新了一半（旧 index.html + 新 web/*.js），
    // 报错只说 "el(...) is null"，用户完全看不出是哪个元素、也不知道该更新哪个文件。
    // 元素绑定（1.7.0 修复）：某个 id 在当前 index.html 里不存在时，不要抛异常把后面的绑定全带走，
    const missingElements = [];
    function reportMissingElement(id) {
        if (missingElements.indexOf(id) >= 0) return;
        missingElements.push(id);
        const message = '[IFM] this page is missing element #' + id +
            ' - the frontend files are probably out of date (redeploy index.html together with web/*.js)';
        try {
            if (window.console && console.warn) {
                console.warn(message, missingElements.slice());
                // 把"我实际加载了什么"一起打出来：能区分"页面旧了"与"部署路径不对"
                console.warn('[IFM] page probe: ' + pageProbe());
            }
        } catch (ignored) { /* ignore */ }
        const node = el('loginError');
        if (node) {
            node.textContent = '[IFM] missing element(s): #' + missingElements.join(', #') +
                ' - redeploy index.html together with web/*.js';
        }
    }
    window.ifmMissingElements = function () { return missingElements.slice(); };

    // 绑定事件：元素不存在时报告缺失并返回 null（绝不抛异常）
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
    // 调度权重的小工具（调试 / 自测用）：取值范围 0.01 ~ 1-0.01n，合计恒为 1，不允许 0
    window.ifmWeights = {
        min: WEIGHT_MIN,
        max: weightMax,
        clamp: clampWeight,
        equal: equalWeights,
        normalize: normalizeWeights,
        rebalance: rebalanceWeights,
    };

    /// 登录按钮的"连接中"状态（用户第 3 项）：点下去立刻禁用 + 图标转圈 + 文字变"连接中…"，
    /// 连接成功或失败（见 ifm-core.js 的 setConnectionStatus）都会自动恢复。
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
            // 先给反馈（同步），再去做异步的连接 —— 用户不会再看到"点了没反应"
            setConnectBusy(true);
            setText('loginError', '');
            window.setTimeout(function () {
                // 兜底：中继卡住时按钮不会一直转圈（12 秒后自动恢复）
                if (el('connectBtn') && el('connectBtn').disabled) setConnectBusy(false);
            }, 12000);
            connect(el('roomInput') ? el('roomInput').value : '');
        });
        on('roomInput', 'keydown', function (event) {
            if (event.key === 'Enter') { const btn = el('connectBtn'); if (btn) btn.click(); }
        });
        on('disconnectBtn', 'click', disconnect);
        // 等外部资源（含 Font Awesome CSS）加载完，再确认字体是否真的可用：
        // 不可用时工具栏图标会缺失，资源图标仍会用名称兜底显示，不会出现整片空白
        window.addEventListener('load', function () { setTimeout(probeFontAwesome, 0); });
        setTimeout(probeFontAwesome, 4000);
        // 用户第 2 项：已移除「刷新全部数据」与「重新扫描外设」两个手动按钮（数据由推送自动保持最新）
        on('diagnoseBtn', 'click', function () {
            busyButton('diagnoseBtn', runDiagnose('report'));
        });
        // 物品名翻译开关（Bergamot 英→简中）：点一下开/关，Shift+点击清空翻译缓存
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
        on('langBtn', 'click', function () {
            lang = lang === 'zh' ? 'en' : 'zh';
            el('langLabel').textContent = lang === 'zh' ? '中' : 'EN';
            applyI18n();
            markDirty('resources');
            markDirty('processes');
            markDirty('peripherals');
            markDirty('machines');
            markDirty('deliveries');
            markDirty('status');            // 设置面板的标题/说明也要跟着换语言（renderSettings）
            scheduleRender();
        });
        on('sendBtn', 'click', sendPendingItems);
        on('clearSendBtn', 'click', function () {
            sendList.clear();
            renderSend();
            toast(t('clearSendList'), 'info');
        });
        // 用户第 6 项：「发送中」栏的"全部删除"（服务端 delete_deliveries）
        on('clearDeliveriesBtn', 'click', clearAllDeliveries);
        on('resourceSearch', 'input', function (event) {
            searchText = event.target.value.trim();
            renderResources();
        });
        bindSearchClear('resourceSearch', function () {
            searchText = '';
            renderResources();
        });
        // 「外设与定义」：搜索（外设名 / 方块名 / 定义名）+ 排序（默认按外设名字典序）
        on('peripheralSearch', 'input', function (event) {
            peripheralSearchText = event.target.value.trim();
            renderPeripherals();
        });
        bindSearchClear('peripheralSearch', function () {
            peripheralSearchText = '';
            renderPeripherals();
        });
        on('peripheralSortBtn', 'click', function () {
            peripheralSortMode = peripheralSortMode === 'peripheral' ? 'block'
                : (peripheralSortMode === 'block' ? 'defs' : 'peripheral');
            renderPeripherals();
            toast(peripheralSortLabelText(), 'info');
        });
        on('resourceSortBtn', 'click', function () {
            // 数量降序（默认）→ 数量升序 → 字典序 → 数量降序（1.6.11：
            // 以前 'default' 与 'count' 都是“数量降序”，点两下才能回到数量排序，现在一轮只有三种模式）
            const index = SORT_MODES.indexOf(sortMode);
            sortMode = SORT_MODES[(index < 0 ? 0 : index + 1) % SORT_MODES.length];
            renderResources();
            toast(t('sortTitle') + '：' + sortModeLabel(sortMode), 'info');
        });
        on('editorSaveBtn', 'click', saveEditor);
        on('editorDeleteBtn', 'click', deleteEditor);
        // 编辑器里按 Enter 直接提交（1.6.9）：例如「新建机器类型」填好名字回车即可保存。
        // 排除容器管理里的资源搜索框（#toolResource，它自己有“放入/取出”按钮）
        // 与勾选框/单选框（Enter 对它们没有“提交”的含义）。
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
        // 数量框支持四则运算：边输入边显示求解结果
        on('promptInput', 'input', updatePromptPreview);
        on('promptInput', 'keydown', function (event) {
            if (event.key === 'Enter') confirmPrompt();
        });
        // 存储整理（1.8.0）：不再有「整理」按钮 —— 整理是自动的：
        // compact 队列为空时服务端会算一遍计划并把搬运任务排进队列（网页进度条照旧显示）。
        on('addMachineTypeBtn', 'click', function () {
            openEditor('machineTypes', null, {});
        });
        on('addFilterBtn', 'click', function () {
            openEditor('filters', null, { rules: [] });
        });
        on('stockSearch', 'input', renderStockList);
        bindSearchClear('stockSearch', renderStockList);
        // 容器管理（在「编辑容器定义」弹窗内）：编辑器 DOM 每次打开都会重建，所以用事件委托绑定
        on('editorBody', 'click', function (event) {
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
        on('editorBody', 'input', function (event) {
            if (event.target && event.target.id === 'toolResource') syncSearchClear('toolResource');
        });
        // 流程编辑器里改了材料/产物名称：立刻刷新左侧图标
        ['input', 'change'].forEach(function (type) {
            on('editorBody', type, function (event) {
                const node = event.target;
                if (node && node.classList && node.classList.contains('e-id')) refreshElementIcons();
            });
        });
        on('stockList', 'click', function (event) {
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
        on('addProcessBtn', 'click', newProcess);
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

    // 前端启动时把 IFM 艺术字打到浏览器控制台（与后端启动时打的那份一致）
    function printBanner() {
        IFM_ART.forEach(function (line) { console.log(line); });
        console.log('IFM web client v' + IFM_CLIENT_VERSION + ' - Integrated Factory Manager');
        console.log('room: ' + (room || (new URLSearchParams(window.location.search).get('room') || '')) +
            '  relay: ' + (relayBase || DEFAULT_RELAY) + '  (F12 里能看到服务端日志)');
    }

    function init() {
        // 每一步都用 safeStep 包住：任何一步失败都不会让后面的绑定（尤其是连接按钮）失效，
        // 错误会直接显示在登录框上（见 reportBootError）。
        safeStep('build stamp', checkBuildStamp);
        safeStep('banner', printBanner);
        safeStep('bindResourceGrid', bindResourceGrid);
        safeStep('bindSendGrid', bindSendGrid);
        safeStep('bindProcessList', bindProcessList);
        safeStep('bindDefinitionLists', bindDefinitionLists);
        safeStep('bindPeripheralDrag', bindPeripheralDrag);
        safeStep('bindPeripheralSelection', bindPeripheralSelection);
        safeStep('bindToolbar', bindToolbar);
        safeStep('bindIconTooltips', bindIconTooltips);
        safeStep('applyI18n', applyI18n);
        safeStep('loadMissingMeta', loadMissingMeta);
        // icon-exports 元数据（≈7MB）延后一点再拉：先让首屏用接口图标画出来，
        // 索引建好后会自动重画一次换成第 ① 层图标（任务 8）
        setTimeout(function () { safeStep('loadIconExports', loadIconExports); }, 900);
        safeStep('syncDeliveryPanelSpacing', syncDeliveryPanelSpacing);
        // 先画一次外设/过滤器面板：没有数据时也能看到「暂无数据」与排序模式
        safeStep('renderPeripherals', renderPeripherals);
        safeStep('renderFilterPanel', renderFilterPanel);
        safeStep('renderWorkers', renderWorkers);
        // 物品名翻译：按上次的开关状态初始化（开启时会自动补翻译并重画界面）
        if (window.IFMTranslate) safeStep('IFMTranslate.init', function () { window.IFMTranslate.init(); });
        safeStep('renderTranslateButton', renderTranslateButton);
        window.addEventListener('resize', syncDeliveryPanelSpacing);
        safeStep('setConnectionStatus', function () { setConnectionStatus('offline'); });
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
            // 从没收到过服务端数据（服务端没在跑）：把登录遮罩摆回来并稳定停在那里，
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
        document.addEventListener('DOMContentLoaded', function () { safeStep('init', init); });
    } else {
        safeStep('init', init);
    }
