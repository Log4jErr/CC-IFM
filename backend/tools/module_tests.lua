-- IFM :: tools/module_tests.lua
-- 1.7.0 模块自测的断言（由 tools/run_module_tests.js 在真 Lua 虚拟机里加载执行）。
-- 只依赖被加载进来的模块（DispatchModule / ContainersModule）与桩，不碰任何外设。

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        print('  ok   ' .. name)
    else
        failed = failed + 1
        print('  FAIL ' .. name .. (detail and (' -> ' .. tostring(detail)) or ''))
    end
end

local Dispatch = DispatchModule
local Containers = ContainersModule
local Protocol = ProtocolModule
local Queue = QueueModule

--- 桩 worker：workerCount / idleCount(feature)
local function stubTransfer(workers, idleTotal, idleMove, idleQuery)
    return {
        workerCount = function() return workers end,
        idleCount = function(_, feature)
            if feature == 'move' then return idleMove or 0 end
            if feature == 'query' then return idleQuery or 0 end
            return idleTotal or 0
        end,
    }
end

local function newDispatcher(opts)
    opts = opts or {}
    return Dispatch.new({ log = function() end, Queue = Queue, transfer = stubTransfer(opts.workers, opts.idle,
        opts.idleMove, opts.idleQuery) })
end

-- 1) 轮转公平：三条队列各一条任务，一个 tick 各服务一次
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2, idleQuery = 2 })
    local served = {}
    local function add(name)
        d:addQueue(name, { needs = 'none', policy = 'retry', run = function()
            served[name] = (served[name] or 0) + 1
            return false
        end })
        d:enqueue(name, { key = name .. ':1' })
    end
    add('a'); add('b'); add('c')
    local steps = d:tick()
    check('round-robin serves every non-empty queue once per round',
        steps == 3 and served.a == 1 and served.b == 1 and served.c == 1,
        'steps=' .. tostring(steps))
    check('queues are empty after their one task ran',
        d:depth('a') == 0 and d:depth('b') == 0 and d:depth('c') == 0)
end

-- 2) 权重 → 步数上限（1.8.0：权重是 0~1 的小数，本机队列按 ceil(权重 * MASTER_STEPS_PER_TICK) 折算）
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    -- 0.05 → ceil(0.05 * 32) = 2 步
    d:addQueue('q', { needs = 'none', policy = 'retry', slice = 0.05, run = function() return false end })
    for i = 1, 5 do d:enqueue('q', { key = 'k' .. i }) end
    local steps = d:tick()
    check('the weight turns into a step limit for local queues', steps == 2 and d:depth('q') == 3,
        'steps=' .. tostring(steps) .. ' depth=' .. tostring(d:depth('q')))
end

-- 3) 失败回队尾（retry）
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    local order = {}
    d:addQueue('q', { needs = 'none', policy = 'retry', slice = 0.05, run = function(task)
        order[#order + 1] = task.key
        return task.key == 'first'
    end })
    d:enqueue('q', { key = 'first' })
    d:enqueue('q', { key = 'second' })
    d:tick()
    check('a retried task goes to the tail of its queue',
        #order == 2 and order[1] == 'first' and order[2] == 'second' and
        d:isQueued('q', 'first') and not d:isQueued('q', 'second'), table.concat(order, ','))
    check('retry is counted in the queue stats', d:status().queues[1].retried == 1)
end

-- 4) 失败丢弃（"drop"）
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() return 'drop' end })
    d:enqueue('q', { key = 'k' })
    d:tick()
    check('"drop" discards the task (no requeue)',
        d:depth('q') == 0 and d:status().queues[1].dropped == 1, tostring(d:depth('q')))
end

-- 5) 有 worker 但全忙 → 本次不推进
do
    local d = newDispatcher({ workers = 3, idle = 0, idleMove = 0, idleQuery = 0 })
    local ran = 0
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() ran = ran + 1; return false end })
    d:enqueue('q', { key = 'k' })
    local steps = d:tick()
    check('all workers busy -> no queue advancement this run',
        steps == 0 and ran == 0 and d:depth('q') == 1 and d:status().paused == 1,
        'steps=' .. tostring(steps) .. ' ran=' .. tostring(ran))
end

-- 6) 没有 worker → 本机执行，且一次调度只推进一步
do
    local d = newDispatcher({ workers = 0 })
    local ran = 0

-- 7) 同 key 去重
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() return false end })
    d:enqueue('q', { key = 'same' })
    d:enqueue('q', { key = 'same' })
    check('enqueue deduplicates by key', d:depth('q') == 1, tostring(d:depth('q')))
end

-- 8) 在飞（"inflight"）：任务离开队列，回报后由 finishInflight 取回
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() return 'inflight' end })
    d:enqueue('q', { key = 'k' })
    d:tick()
    local status = d:status()
    check('an inflight task leaves the queue and is counted',
        d:depth('q') == 0 and status.queues[1].inflight == 1 and status.inflight == 1)
    local task = d:finishInflight('q', 'k')
    check('finishInflight returns the task and clears the counter',
        type(task) == 'table' and task.key == 'k' and d:status().inflight == 0)
end

-- 9) 能力门控：需要 query 的队列在没有空闲 query worker 时不推进
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2, idleQuery = 0 })
    local ran = 0
    d:addQueue('scan', { needs = 'query', policy = 'retry', run = function() ran = ran + 1; return false end })
    d:enqueue('scan', { key = 'c1' })
    local steps = d:tick()
    check('a queue needing query waits when no query worker is idle',
        steps == 0 and ran == 0 and d:depth('scan') == 1, 'steps=' .. tostring(steps))
end

-- 10) 权重设置（网页「设置」保存路径）：0.01 ~ 1-0.01n 的小数，不允许 0
do
    local d = newDispatcher({ workers = 1, idle = 1 })
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() return false end })
    d:applySlices({ q = 0.35 })
    check('applySlices updates the weight', d:status().queues[1].slice == 0.35,
        tostring(d:status().queues[1].slice))
    check('setSlice rejects 0 (a queue can never be switched off) and out-of-range / nil',
        d:setSlice('q', 0) == false and d:setSlice('q', 0.005) == false and
        d:setSlice('q', 1) == false and d:setSlice('q', nil) == false and
        d:status().queues[1].slice == 0.35)
    check('setSlice accepts the minimum 0.01', d:setSlice('q', 0.01) == true and
        d:status().queues[1].slice == 0.01)
end

    for _, name in ipairs({ 'a', 'b' }) do
        d:addQueue(name, { needs = 'none', policy = 'retry', run = function() ran = ran + 1; return false end })
        d:enqueue(name, { key = name .. ':1' })
        d:enqueue(name, { key = name .. ':2' })
    end
    local steps = d:tick()
    check('no worker (local mode) -> exactly one step per scheduler run',
        steps == 1 and ran == 1, 'steps=' .. tostring(steps) .. ' ran=' .. tostring(ran))
    check('local mode is reported by status', d:status().mode == 'local', d:status().mode)

-- ===================== 容器快照（containers.lua） =====================
-- 桩：外设/存储/过滤器都不参与快照逻辑，只要满足构造要求
local peripheralsStub = {
    exists = function() return true end,
    isInventory = function() return false end,
    isFluid = function() return false end,
    names = function() return {} end,
    invalidate = function() end,
    lastScan = 0,
}
local storeStub = {
    list = function() return {} end,
    findContainer = function() return nil end,   -- 容器定义不存在 -> 搬运干净失败
}

local function newContainers()
    return Containers.new({
        Util = { kindOfDef = function() return 'item' end },
        Peripherals = peripheralsStub,
        Store = storeStub,
        Filter = {},
        log = function() end,
    })
end

-- 11) 出库预留 / 结算：不会超发，按实际搬运量归还
do
    local c = newContainers()
    local name = 'minecraft:chest_1'
    c:applyScan(name, { { slot = 1, name = 'minecraft:cobblestone', count = 10 } }, nil, os.epoch('utc'))
    local model = c:modelOf(name)
    check('applyScan writes the authoritative base', c:visibleSlotCount(model, 1) == 10)

    local reserved = c:reserveOut(name, 1, 4, 'item')
    check('reserveOut marks the slot dirty but leaves the snapshot alone (user item 8)',
        reserved == 4 and c:visibleSlotCount(model, 1) == 10 and c:isDirtySlot(name, 1) == true,
        'reserved=' .. tostring(reserved) .. ' visible=' .. tostring(c:visibleSlotCount(model, 1)))

    local second = c:reserveOut(name, 1, 99, 'item')
    check('a second out-task can only claim what the first one left (no oversell)',
        second == 6, 'second=' .. tostring(second))

    c:settleMove({ kind = 'item', from = name, fromIndex = 1, to = 'other', toIndex = 1,
        reserved = 4, item = 'minecraft:cobblestone' }, 1)
    check('settling subtracts what really moved and frees the slot',
        c:visibleSlotCount(model, 1) == 9 and c:isDirtySlot(name, 1) == false,
        tostring(c:visibleSlotCount(model, 1)))

    c:settleMove({ kind = 'item', from = name, fromIndex = 1, to = 'other', toIndex = 1,
        reserved = 6, item = 'minecraft:cobblestone' }, 3)
    check('the rest stays reserved until its own settlement',
        c:visibleSlotCount(model, 1) == 6, tostring(c:visibleSlotCount(model, 1)))
end

-- 12) 扫描只清理"结算早于这次扫描开始"的乐观变更
do
    local c = newContainers()
    local name = 'minecraft:chest_2'
    local t0 = os.epoch('utc')
    c:applyScan(name, { { slot = 1, name = 'minecraft:iron_ingot', count = 20 } }, nil, t0)
    local model = c:modelOf(name)
    c:reserveOut(name, 1, 5, 'item')
    c:settleMove({ kind = 'item', from = name, fromIndex = 1, to = 'x', toIndex = 1,
        reserved = 5, item = 'minecraft:iron_ingot' }, 5)
    c:applyScan(name, { { slot = 1, name = 'minecraft:iron_ingot', count = 15 } }, nil, os.epoch('utc'))
    check('a scan started after the settlement drops that pending entry (scan is truth)',
        c:visibleSlotCount(model, 1) == 15, tostring(c:visibleSlotCount(model, 1)))

    c:applyScan(name, { { slot = 1, name = 'minecraft:iron_ingot', count = 15 } }, nil, t0)
    local reserved = c:reserveOut(name, 1, 4, 'item')
    check('reservation works again after a rescan (and the snapshot still is not touched)',
        reserved == 4 and c:visibleSlotCount(model, 1) == 15,
        'reserved=' .. tostring(reserved) .. ' visible=' .. tostring(c:visibleSlotCount(model, 1)))
    c:settleMove({ kind = 'item', from = name, fromIndex = 1, to = 'x', toIndex = 1,
        reserved = 4, item = 'minecraft:iron_ingot' }, 0)
    c:applyScan(name, { { slot = 1, name = 'minecraft:iron_ingot', count = 15 } }, nil, t0)
    check('a failed move (moved = 0) leaves the snapshot untouched',
        c:visibleSlotCount(model, 1) == 15, tostring(c:visibleSlotCount(model, 1)))
    c:applyScan(name, { { slot = 1, name = 'minecraft:iron_ingot', count = 15 } }, nil, os.epoch('utc'))
    check('a later scan clears it', c:visibleSlotCount(model, 1) == 15, tostring(c:visibleSlotCount(model, 1)))
end

-- 13) 按轮次判断新鲜度 + 在飞记录兜底清理
do
    local c = newContainers()
    local name = 'minecraft:chest_3'
    c:advanceTick()
    check('a container that was never scanned needs a scan', c:needsScan(name, 20) == true)
    c:applyScan(name, { { slot = 1, name = 'minecraft:dirt', count = 1 } }, nil, os.epoch('utc'))
    check('a freshly scanned container does not need a scan', c:needsScan(name, 20) == false)
    for _ = 1, 25 do c:advanceTick() end
    check('after maxAgeTicks rounds it needs a scan again (tick based, no milliseconds)',
        c:needsScan(name, 20) == true)

    c:applyScan(name, { { slot = 1, name = 'minecraft:dirt', count = 8 } }, nil, os.epoch('utc'))
    local model = c:modelOf(name)
    c.moveInflight['stale'] = { kind = 'item', from = name, fromIndex = 1, to = 'x', toIndex = 1,
        reserved = 3, item = 'minecraft:dirt', at = 0 }
    c:reserveOut(name, 1, 3, 'item')
    c:advanceTick()
    local dbgVisible = c:visibleSlotCount(model, 1)
    check('a stale inflight record is settled (reservation refunded) and dropped',
        c.moveInflight['stale'] == nil and dbgVisible == 8, tostring(dbgVisible))
end

-- 14) 手动搬运（pushItem / executeMove）：没有调度器时本机执行，失败要干净地返回错误
do
    local c = newContainers()
    local name = 'minecraft:chest_4'
    c:applyScan(name, { { slot = 1, name = 'minecraft:oak_log', count = 5 } }, nil, os.epoch('utc'))
    c:setDispatcher(nil)
    local okCall, moved, reason = pcall(c.pushItem, c, 'chest_4', 1, 5, 'chest_5')
    check('pushItem without a dispatcher fails cleanly (no crash, no exception)',
        okCall == true and (moved == nil or moved == 0), tostring(moved) .. ' / ' .. tostring(reason))
end

-- 15) 中继连接的生命周期：我们自己关掉的旧连接，它的关闭事件迟到时不能把新连接判死
--     （这就是"每隔几秒 WebSocket closed, will reconnect"的根因：CC:T 的 websocket_closed
--      只带 url、不带句柄，重连时"关旧 → 开新"之后旧连接的关闭事件会迟到到来）
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    local function fakeSocket()
        return { close = function() end, send = function() end }
    end
    p:onEvent('websocket_success', 'wss://relay/room', fakeSocket())
    check('socket 1 is up after websocket_success', p.connected == true and p.ws ~= nil)

    --- 重连：关掉旧的（closeAcks +1）、开新的（旧连接的关闭事件还没到）
    p:connect()
    p:onEvent('websocket_success', 'wss://relay/room', fakeSocket())
    check('socket 2 is up after a reconnect', p.connected == true and p.ws ~= nil)

    --- 迟到的旧连接关闭事件：必须被认领（ownCloses），连接状态保持不变
    p:onEvent('websocket_closed', 'wss://relay/room', 'Closed', 'by user')
    check('a late close event of our own socket is ignored (no reconnect loop)',
        p.connected == true and p.ws ~= nil and (p.stats.ownCloses or 0) == 1,
        'connected=' .. tostring(p.connected) .. ' ownCloses=' .. tostring(p.stats.ownCloses))

    --- 真正的中继关闭：清状态，等下一个 update 重连
    p:onEvent('websocket_closed', 'wss://relay/room', 'Connection closed by remote host')
    check('a real relay close clears the connection',
        p.connected == false and p.ws == nil and p.stats.closes == 2 and p.lastCloseReason ~= nil,
        tostring(p.lastCloseReason))

    --- 重复/无效的关闭事件：只记数
    p:onEvent('websocket_closed', 'wss://relay/room', 'Closed again')
    check('a duplicate close event is counted as stale', (p.stats.staleCloses or 0) == 1)

    --- 浏览器心跳超时（后台标签页）不再重连中继、更不会关掉好连接
    local p2 = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    p2:onEvent('websocket_success', 'wss://relay/room', fakeSocket())
    p2.clientActive = true
    p2.lastHeartbeat = 0
    local before = p2.ws
    p2:update(os.epoch('utc'))
    check('client timeout keeps the relay socket (used to close it every 40s)',
        p2.ws == before and p2.connected == true and p2.clientActive == false and
        (p2.stats.reconnects or 0) == 0,
        'wsKept=' .. tostring(p2.ws == before) .. ' reconnects=' .. tostring(p2.stats.reconnects))
end

-- 16) 连接请求纪律（1.7.1）：同一条连接绝不重复发请求；迟到的失败/关闭事件不能影响在用的连接
--     （用户现场：中继日志里出现同一台计算机的多条连接 → 网页"加入又离开" → 中继回 `Could not connect`）
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    __wsRequests = 0
    p:update(os.epoch('utc'))
    check('the first update issues exactly one connect request', __wsRequests == 1, tostring(__wsRequests))
    p:update(os.epoch('utc'))
    p:update(os.epoch('utc'))
    check('a pending handshake is never duplicated',
        __wsRequests == 1 and (p.pendingAcks or 0) == 1,
        'requests=' .. tostring(__wsRequests) .. ' pending=' .. tostring(p.pendingAcks))

    --- 超过连接超时（35s）：放弃这条请求、允许重发（迟到的结果由 closeAcks 认领）
    __nowAdvance(40000)
    p:update(os.epoch('utc'))
    check('after the connect timeout the request is abandoned and retried',
        (p.stats.abandoned or 0) == 1 and (p.closeAcks or 0) == 1,
        'abandoned=' .. tostring(p.stats.abandoned) .. ' acks=' .. tostring(p.closeAcks))

    --- 在用连接 + 旧请求的成功事件（多出来的句柄）：关掉多出来的，保留在用的那条
    local liveA = { close = function() end, send = function() end }
    p:onEvent('websocket_success', 'wss://relay/room', liveA)
    local requestsBefore = __wsRequests
    p:update(os.epoch('utc'))
    check('no new request while a live connection exists', __wsRequests == requestsBefore,
        'requests=' .. tostring(__wsRequests))
end

-- 17) 迟到的 websocket_failure（中继的 Could not connect）不能把正在用的连接判死
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    local socket = { close = function() end, send = function() end }
    p:onEvent('websocket_success', 'wss://relay/room', socket)
    check('the live connection is up', p.connected == true and p.ws == socket)
    p:onEvent('websocket_failure', 'wss://relay/room', 'Could not connect')
    check('a late failure of an old attempt does not kill the live connection',
        p.connected == true and p.ws == socket and (p.stats.staleCloses or 0) == 1,
        'connected=' .. tostring(p.connected) .. ' stale=' .. tostring(p.stats.staleCloses))
    --- 真正的失败（没有在用连接时）仍然要清状态，等下个周期重连
    p.ws = nil
    p.connected = false
    p:onEvent('websocket_failure', 'wss://relay/room', 'Could not connect')
    check('a real failure still clears the state', p.connected == false and p.ws == nil)
end

-- 18) 应用层保活：没人在网页上时也要定期发一条，免得中继按"空闲"把连接踢掉
--     （用户现场：没人看网页时每 35 秒被中继关一次，一打开网页就稳定）
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    local sent = 0
    local socket = { close = function() end, send = function() sent = sent + 1 end }
    p:onEvent('websocket_success', 'wss://relay/room', socket)
    check('no keepalive right after connecting', (p.stats.keepalives or 0) == 0)
    __nowAdvance(25000)
    p:update(os.epoch('utc'))
    check('an idle connection sends an application-level keepalive',
        (p.stats.keepalives or 0) == 1 and sent == 1,
        'keepalives=' .. tostring(p.stats.keepalives) .. ' sent=' .. tostring(sent))
    p:update(os.epoch('utc'))
    check('keepalives are rate limited to keepaliveInterval', (p.stats.keepalives or 0) == 1,
        tostring(p.stats.keepalives))
end

-- 19) 平滑加权轮转（用户第 2 项）：权重大的队列不会被连续跑一大段，而是按比例铺开
do
    local d = newDispatcher({ workers = 2, idle = 2 })
    local order = {}
    d:addQueue('p', { needs = 'none', policy = 'retry', run = function() order[#order + 1] = 'p'; return false end })
    d:addQueue('s', { needs = 'none', policy = 'retry', run = function() order[#order + 1] = 's'; return false end })
    d:applySlices({ p = 0.7, s = 0.3 })
    for i = 1, 40 do d:enqueue('p', { key = 'p' .. i }) end
    for i = 1, 40 do d:enqueue('s', { key = 's' .. i }) end
    d:tick()
    local served = table.concat(order, '')
    local pCount, sCount = 0, 0
    for i = 1, #order do
        if order[i] == 'p' then pCount = pCount + 1 else sCount = sCount + 1 end
    end
    --- 最大连续段：流程 50 / 扫描 20 的旧实现会是 "P×50"，新实现必须是小段交错
    local maxRun = 0
    local run = 0
    for i = 1, #order do
        if i > 1 and order[i] == order[i - 1] then run = run + 1 else run = 1 end
        if run > maxRun then maxRun = run end
    end
    check('weighted rotation interleaves the queues (no long bursts)',
        #order > 0 and maxRun <= 3 and sCount > 0 and pCount > sCount,
        'order=' .. served .. ' (maxRun=' .. maxRun .. ')')
end

-- 20) 用户第 2 项 + 第 5 项：一轮里把任务喂给所有空闲 worker —— 现在是"一直喂到没容量为止"
--     （以前一轮最多 = 空闲 worker **台数**，27 个容器要好几轮才派得完、并发永远个位数）
do
    local d = newDispatcher({ workers = 3, idle = 3, idleQuery = 3 })
    local served = 0
    d:addQueue('scan', { needs = 'query', policy = 'retry', run = function() served = served + 1; return false end })
    for i = 1, 10 do d:enqueue('scan', { key = 'c' .. i }) end
    local steps = d:tick()
    check('one round hands every pending task to the workers (drains until they are full)',
        steps == 10 and served == 10, 'steps=' .. tostring(steps) .. ' served=' .. tostring(served))
end

-- 21) 用户第 1 项：重复注册队列不再把 run 悄悄换成默认空跑；没给 run 的队列要报错计数
do
    local d = newDispatcher({ workers = 2, idle = 2 })
    local served = 0
    d:addQueue('q', { needs = 'none', policy = 'retry', run = function() served = served + 1; return false end })
    d:addQueue('q', { needs = 'none', policy = 'retry' })            -- 重复注册（不带 run）
    d:enqueue('q', { key = 'k' })
    d:tick()
    local status = d:status()
    check('re-registering a queue keeps its runner (no silent no-op)',
        served == 1 and (status.duplicateQueues or 0) == 1,
        'served=' .. tostring(served) .. ' duplicateQueues=' .. tostring(status.duplicateQueues))

    local d2 = newDispatcher({ workers = 2, idle = 2 })
    d2:addQueue('norun', { needs = 'none', policy = 'retry' })       -- 没给 run：未定义行为
    d2:enqueue('norun', { key = 'k' })
    d2:tick()
    local status2 = d2:status()
    check('a queue without a runner is reported, not silently ignored',
        (status2.missingRunner or 0) >= 1 and d2:depth('norun') == 0,
        'missingRunner=' .. tostring(status2.missingRunner))
end

-- 22) 用户第 3 项：worker 全忙时主控自己并行做（mode = "mixed"，队列不再整条停住）
do
    local d = newDispatcher({ workers = 2, idle = 0, idleMove = 0, idleQuery = 0 })
    d.transfer.localFreeSlots = function() return 32 end
    local served = 0
    d:addQueue('move', { needs = 'move', policy = 'retry', run = function()
        served = served + 1
        return false
    end })
    for i = 1, 5 do d:enqueue('move', { key = 'm' .. i }) end
    local steps = d:tick()
    check('all workers at capacity -> the master runs the queue itself (mixed mode)',
        d:status().mode == 'mixed' and steps > 1 and served == steps,
        'mode=' .. tostring(d:status().mode) .. ' steps=' .. tostring(steps))
end

-- 23) 用户第 3 项：worker 全忙 + 本机协程位也满了 → 才是 paused（谁都没空位）
do
    local d = newDispatcher({ workers = 2, idle = 0, idleMove = 0 })
    d.transfer.localFreeSlots = function() return 0 end
    local served = 0
    d:addQueue('move', { needs = 'move', policy = 'retry', run = function() served = served + 1; return false end })
    d:enqueue('move', { key = 'm1' })
    local steps = d:tick()
    check('workers at capacity AND no local slot -> paused (nothing can run)',
        d:status().mode == 'paused' and steps == 0 and served == 0,
        'mode=' .. tostring(d:status().mode) .. ' steps=' .. tostring(steps))
end

-- 24) 用户第 3 项：没有 worker 时主控本机也是并行推进（本机协程池的位子就是本轮上限）
do
    local d = newDispatcher({ workers = 0 })
    d.transfer.localFreeSlots = function() return 8 end
    local served = 0
    d:addQueue('move', { needs = 'move', policy = 'retry', run = function() served = served + 1; return false end })
    for i = 1, 20 do d:enqueue('move', { key = 'm' .. i }) end
    d:tick()
    check('no workers -> the master feeds its own coroutine slots (8), not just 1 per round',
        served == 8, 'served=' .. tostring(served))
end

-- 25) 用户第 3 项：主控本机的搬运协程池（request → 本机协程执行 → 结果按同一个 key 取回）
do
    local t = TransferModule.new({
        log = function() end,
        Modems = {
            find = function() return nil end,
            asModem = function() return nil end,
            transmit = function() return true end,
        },
    })
    t:setContext({ version = 'test' })
    local calls = 0
    t.executeLocal = function()
        calls = calls + 1
        coroutine.yield()                    -- 模拟“外设调用要等 1 个游戏刻”
        return 5, nil
    end
    local job = { action = 'push_item', from = 'a', fromSlot = 1, limit = 5, to = 'b' }
    local s1 = t:request(job)
    check('no worker -> the master takes the job into its own coroutine pool', s1 == 'pending',
        'state=' .. tostring(s1))
    check('the job really runs in a coroutine (not finished until the pool is pumped)',
        calls == 1 and t:request(job) == 'pending' and t:localFreeSlots() == t.localPool.slots - 1,
        'calls=' .. tostring(calls) .. ' free=' .. tostring(t:localFreeSlots()))
    t:pumpLocal('timer', 1)                  -- 事件轮到它：继续跑完
    local s2, moved = t:request(job)
    check('after pumping, the same key returns the result (done, moved=5)',
        s2 == 'done' and moved == 5, 'state=' .. tostring(s2) .. ' moved=' .. tostring(moved))
    check('the coroutine slot is released again', t:localFreeSlots() == t.localPool.slots,
        'free=' .. tostring(t:localFreeSlots()))
end

-- 26) 本机协程池满了：新任务只是等下一轮（不执行、也不丢）
do
    local t = TransferModule.new({
        log = function() end, localSlots = 1,
        Modems = {
            find = function() return nil end,
            asModem = function() return nil end,
            transmit = function() return true end,
        },
    })
    t.executeLocal = function()
        coroutine.yield()
        return 1, nil
    end
    local first = { action = 'push_item', from = 'a', fromSlot = 1, limit = 1, to = 'b' }
    local second = { action = 'push_item', from = 'c', fromSlot = 1, limit = 1, to = 'd' }
    local s1 = t:request(first)
    local s2 = t:request(second)
    check('the local pool has a hard slot limit (1 here)',
        s1 == 'pending' and s2 == 'pending' and t:localFreeSlots() == 0 and
            (t:localStatus().rejected or 0) == 1,
        'free=' .. tostring(t:localFreeSlots()) .. ' rejected=' .. tostring(t:localStatus().rejected))
    t:pumpLocal('timer', 1)
    local state, moved = t:request(first)
    check('the first job completes and frees its slot', state == 'done' and moved == 1,
        'state=' .. tostring(state) .. ' moved=' .. tostring(moved))
end

-- 27) 用户第 4 项：双队列 —— 重试的任务进"另一个队列"，同一个 tick 不会再被执行
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2, idleQuery = 2 })
    local task = { key = 'chest_1', name = 'chest_1' }
    d:addQueue('scan', { needs = 'query', policy = 'retry', slice = 5, run = function()
        task.runs = (task.runs or 0) + 1
        return true                       -- 还没完（例如在等 worker 回报）：进"另一个队列"
    end })
    d:enqueue('scan', task)
    local first = d:tick()
    check('a retried task runs once per tick even with a big weight',
        first == 1 and task.runs == 1, 'steps=' .. tostring(first) .. ' runs=' .. tostring(task.runs))
    check('the retried task waits in the second queue until the next tick',
        d:depth('scan') == 1 and d:activeDepth('scan') == 0 and d:waitingDepth('scan') == 1,
        'depth=' .. tostring(d:depth('scan')) .. ' active=' .. tostring(d:activeDepth('scan')) ..
        ' waiting=' .. tostring(d:waitingDepth('scan')))
    local second = d:tick()
    check('it is promoted back into the active queue and runs again on the next tick',
        second == 1 and task.runs == 2 and d:activeDepth('scan') == 0 and d:waitingDepth('scan') == 1,
        'steps=' .. tostring(second) .. ' runs=' .. tostring(task.runs))
    check('the promotion is counted', (d:status().promoted or 0) >= 1,
        'promoted=' .. tostring(d:status().promoted))
end

-- 28) 同一个 tick 里，不同的任务照旧各推进一次（公平性不受影响）
do
    local d = newDispatcher({ workers = 4, idle = 4, idleMove = 4 })
    local runs = 0
    d:addQueue('move', { needs = 'move', policy = 'retry', slice = 4, run = function()
        runs = runs + 1
        return true
    end })
    for i = 1, 4 do d:enqueue('move', { key = 'm' .. i }) end
    local steps = d:tick()
    check('different tasks in one queue each get one step in the same tick',
        steps == 4 and runs == 4, 'steps=' .. tostring(steps) .. ' runs=' .. tostring(runs))
end

-- 29) policy="drop"（入库 / 整理 / 详情 / 手动）：run 返回 true 就直接丢弃，不进"另一个队列"
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2 })
    local runs = 0
    d:addQueue('in', { needs = 'move', policy = 'drop', run = function()
        runs = runs + 1
        return true
    end })
    d:enqueue('in', { key = 'i1' })
    local steps = d:tick()
    check('a drop-policy queue removes the task even when the step is unfinished',
        steps == 1 and runs == 1 and d:depth('in') == 0,
        'steps=' .. tostring(steps) .. ' depth=' .. tostring(d:depth('in')))
end

-- 30) "pending"（在等 worker 回报）在任何策略下都保留到下一个 tick（否则那笔搬运没人结算）
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2 })
    local runs = 0
    d:addQueue('in', { needs = 'move', policy = 'drop', run = function()
        runs = runs + 1
        return 'pending'
    end })
    d:enqueue('in', { key = 'i2' })
    d:tick()
    check('a pending task is kept in the waiting queue (not dropped)',
        d:depth('in') == 1 and d:waitingDepth('in') == 1 and runs == 1,
        'depth=' .. tostring(d:depth('in')) .. ' runs=' .. tostring(runs))
    local steps = d:tick()
    check('and it is picked up again on the next tick', steps == 1 and runs == 2,
        'steps=' .. tostring(steps) .. ' runs=' .. tostring(runs))
end

-- 31) 队列账本：大量出队 + 回队列之后 depth 仍然准确（环形队列 + 双队列都不许丢任务）
do
    local d = newDispatcher({ workers = 4, idle = 4, idleMove = 4 })
    local runs = 0
    d:addQueue('q', { needs = 'move', policy = 'retry', slice = 4, run = function()
        runs = runs + 1
        return true
    end })
    for i = 1, 100 do d:enqueue('q', { key = 'k' .. i }) end
    local seen = 0
    for _ = 1, 60 do
        seen = seen + d:tick()
    end
    check('depth stays consistent after many pops + retries (no task is ever lost)',
        d:depth('q') == 100 and seen == runs,
        'depth=' .. tostring(d:depth('q')) .. ' seen=' .. tostring(seen) .. ' runs=' .. tostring(runs))
end

-- 32) 容器外设被移除：removeKey 把任务从两个队列里都撤掉（扫描任务据此清理）
do
    local d = newDispatcher({ workers = 2, idle = 2, idleQuery = 2 })
    d:addQueue('scan', { needs = 'query', policy = 'retry', run = function() return true end })
    d:enqueue('scan', { key = 'chest_1', name = 'chest_1' })
    d:enqueue('scan', { key = 'chest_2', name = 'chest_2' })
    d:tick()                                     -- 两条各跑一步 → 都进 waiting
    check('both scan tasks are waiting after one tick',
        d:waitingDepth('scan') == 2, 'waiting=' .. tostring(d:waitingDepth('scan')))
    check('removeKey removes a task from either queue',
        d:removeKey('scan', 'chest_1') == 1 and d:depth('scan') == 1 and
            not d:isQueued('scan', 'chest_1'),
        'depth=' .. tostring(d:depth('scan')))
end

-- 33) promote：active 空 → 交换；active 非空 → 附加到尾部（等待中的任务不会饿死）
do
    local d = newDispatcher({ workers = 2, idle = 2, idleMove = 2 })
    d:addQueue('q', { needs = 'move', policy = 'retry', run = function() return true end })
    d:enqueue('q', { key = 'first' })
    d:tick()                                     -- 'first' → waiting，active 空
    d:enqueue('q', { key = 'second' })           -- 新任务进 active
    local promoted = d:promote('q')              -- active 非空 → 附加，不交换
    check('promote appends to a non-empty active queue (nothing starves)',
        promoted == 1 and d:activeDepth('q') == 2,
        'promoted=' .. tostring(promoted) .. ' active=' .. tostring(d:activeDepth('q')))
    d:tick()
    check('both tasks ran in that tick (the promoted one was not lost)',
        d:waitingDepth('q') == 2, 'waiting=' .. tostring(d:waitingDepth('q')))
end

-- 34) 环形队列（modules/queue.lua）：顺序 / 扩容 / 回绕 / 删除 / 合并
do
    local q = Queue.new(4)
    check('a new queue starts empty', q:isEmpty() and q:len() == 0 and q:peek() == nil)
    for i = 1, 100 do q:push(i) end
    check('the queue grows past its initial capacity and keeps the order',
        q:len() == 100 and q:peek() == 1, 'len=' .. tostring(q:len()) .. ' peek=' .. tostring(q:peek()))
    local order = {}
    for i = 1, 60 do order[i] = q:pop() end
    for i = 101, 140 do q:push(i) end                  -- 回绕：先出一批再入一批
    local rest = {}
    for i = 1, 80 do rest[i] = q:pop() end
    local okOrder = order[1] == 1 and order[60] == 60 and rest[1] == 61 and rest[40] == 100 and
        rest[41] == 101 and rest[80] == 140
    check('FIFO order survives wrap-around (pop then push)', okOrder and q:isEmpty(),
        'order60=' .. tostring(order[60]) .. ' rest41=' .. tostring(rest[41]) .. ' rest80=' .. tostring(rest[80]))

    local r = Queue.new(4)
    for i = 1, 10 do r:push({ key = 'k' .. i }) end
    local removed = r:removeWhere(function(task) return task.key == 'k3' or task.key == 'k7' end)
    check('removeWhere removes exactly the matching entries and keeps the order',
        removed == 2 and r:len() == 8 and r:peek().key == 'k1',
        'removed=' .. tostring(removed) .. ' len=' .. tostring(r:len()))

    local a, b = Queue.new(2), Queue.new(2)
    for i = 1, 3 do a:push('a' .. i) end
    for i = 1, 3 do b:push('b' .. i) end
    local moved = a:append(b)
    check('append moves every element in order and clears the source',
        moved == 3 and a:len() == 6 and b:isEmpty() and a:peek() == 'a1',
        'moved=' .. tostring(moved) .. ' len=' .. tostring(a:len()))
    local array = a:toArray()
    check('toArray returns the queue in dequeue order',
        array[1] == 'a1' and array[4] == 'b1' and array[6] == 'b3',
        'first=' .. tostring(array[1]) .. ' fourth=' .. tostring(array[4]))
    a:clear()
    check('clear empties the queue', a:isEmpty() and a:len() == 0)
end

-- ===================== 交互容器（海龟）与内容快照（用户第 2/3 项）=====================
-- 1.9.0：交互容器也会被扫描 / 上报 → 有内容快照；抽取与推送**一律按快照决策**，
-- 旧的"盲搬/盲抽"（不读内容、只按成功量记账、槽位靠猜）已整条删除：
-- 拿不到快照 → 直接失败，不派活、不猜槽位。
do
    local turtlePeripherals = {
        --- 同样注意：Containers 用 `self.Peripherals:xxx(...)` 调用 → 桩的第一个参数是 self
        exists = function(_, name) return name == 'turtle_0' or name == 'chest_1' or name == 'mill_1' end,
        isInventory = function(_, name) return name == 'chest_1' or name == 'mill_1' end,
        isFluid = function() return false end,
        isTurtle = function(_, name) return name == 'turtle_0' end,
        names = function() return {} end,
        invalidate = function() end,
        --- slotCount / insertSlotFor 会包装外设问 size()：这里给一个"什么都没有"的句柄，
        --- 于是槽位数只能来自快照（model.size —— 海龟上报的格数）
        wrap = function() return {} end,
        lastScan = 0,
    }
    local turtleStore = {
        list = function() return {} end,
        --- 注意：Containers 是 `self.Store:findContainer(...)` 调用的 —— 桩要留出第一个 self 参数
        findContainer = function(_, name)
            if name == 'turtle_0' then
                return { name = 'turtle_0', peripheral = 'turtle_0', kind = 'item', role = 'interaction' }
            end
            if name == 'chest_1' then
                return { name = 'chest_1', peripheral = 'chest_1', kind = 'item', role = 'input' }
            end
            if name == 'mill_1' then
                --- 真的 inventory 外设，但角色是 interaction（机器输入）→ 盲搬（读不到或不该读）
                return { name = 'mill_1', peripheral = 'mill_1', kind = 'item', role = 'interaction' }
            end
            return nil
        end,
    }
    local c = Containers.new({
        Util = { kindOfDef = function() return 'item' end },
        Peripherals = turtlePeripherals,
        Store = turtleStore,
        Filter = {},
        log = function() end,
    })
    check('a turtle is accepted as an interaction container', c:supports('turtle_0', 'item') == true)
    check('nothing has a snapshot before it is scanned / reported',
        c:hasSnapshot('turtle_0') == false and c:hasSnapshot('chest_1') == false)

    local submitted = {}
    c.dispatch = {
        enqueue = function(_, queueName, record)
            submitted[#submitted + 1] = record
            return true
        end,
    }
    --- 用户第 2 项（1.9.0）：**没有快照就不搬** —— 旧的盲搬/盲抽路径已整条删除，
    --- 拿不到内容快照时 pushItem 直接失败（不猜槽位、不派活）。
    local _, errNoSnapshot = c:pushItem('turtle_0', nil, 2, 'chest_1', nil, nil, 'test',
        { name = 'minecraft:cobblestone' })
    check('a move without a content snapshot is refused (the blind path is gone)',
        errNoSnapshot ~= 'pending' and #submitted == 0, 'err=' .. tostring(errNoSnapshot))

    --- 目标容器先扫一次（普通箱子也要先有快照，抽取才有依据）
    c:applyScan('chest_1', { { slot = 1, name = 'minecraft:cobblestone', count = 8 } }, nil,
        os.epoch('utc'))
    --- ① 海龟上报物品栏 → 写进它自己的内容快照（size = 16 格）
    c:applyScan('turtle_0', { { slot = 4, name = 'minecraft:cobblestone', count = 2 } }, nil,
        os.epoch('utc'), 16)
    check('the turtle report becomes its content snapshot (and carries the slot count)',
        c:hasSnapshot('turtle_0') == true and c:slotCount('turtle_0') == 16,
        'slotCount=' .. tostring(c:slotCount('turtle_0')))
    --- ①b 抽取按快照决策：槽位来自海龟自己的上报，actor = "to"（由对面容器 pullItems）
    local _, err = c:pushItem('turtle_0', nil, 2, 'chest_1', nil, nil, 'test',
        { name = 'minecraft:cobblestone' })
    check('pulling from a turtle uses the slot from its own snapshot (actor = "to")',
        err == 'pending' and #submitted == 1 and submitted[1].actor == 'to' and submitted[1].fromIndex == 4,
        'err=' .. tostring(err) .. ' n=' .. tostring(#submitted) ..
            ' actor=' .. tostring(submitted[1] and submitted[1].actor) ..
            ' slot=' .. tostring(submitted[1] and submitted[1].fromIndex))
    check('the source slot is marked dirty before the move (user item 3)',
        c:isDirtySlot('turtle_0', 4, false) == true)
    --- ①c 同一格已认领的量不会被第二条任务重复抽取（reserveOut 只放行剩余量）
    local _, errClaimed = c:pushItem('turtle_0', 4, 1, 'chest_1', nil, nil, 'test',
        { name = 'minecraft:cobblestone' })
    check('the amount already claimed by another task is not extracted twice',
        errClaimed ~= 'pending' and #submitted == 1, 'err=' .. tostring(errClaimed))
    c:clearDirty(c:modelOf('turtle_0'), 4, false)

    --- ② 海龟作为目标：源是 inventory（箱子）→ actor = "from"（箱子推入；同样不对海龟调用方法）。
    --- 用户第 3 项：推送物品同样按快照挑目标槽位并**标脏**（同一个格子不会被两条入库任务塞）。
    submitted = {}
    local _, err2 = c:pushItem('chest_1', 1, 4, 'turtle_0', nil, c.INSERT_SPEED, 'test')
    check('pushing into a turtle keeps the inventory side as the actor',
        err2 == 'pending' and #submitted == 1 and submitted[1].actor == 'from',
        'err=' .. tostring(err2) .. ' actor=' .. tostring(submitted[1] and submitted[1].actor))
    local task2 = submitted[1]
    check('the target slot comes from the target snapshot and is marked dirty right away',
        task2 ~= nil and tonumber(task2.toIndex) ~= nil and
            c:isDirtySlot('turtle_0', task2.toIndex, false) == true,
        task2 and ('toIndex=' .. tostring(task2.toIndex)))

    --- ③ 角色是 interaction 的**真** inventory（机器输入容器）：同样按快照决策 ——
    --- 没有快照 → 直接失败；被扫过一次之后才派活（actor 仍是 "from"：源侧是 inventory）。
    submitted = {}
    local _, errNoScan = c:pushItem('chest_1', 1, 4, 'mill_1', nil, c.INSERT_SPEED, 'test')
    check('pushing into an interaction container without a snapshot is refused',
        errNoScan ~= 'pending' and #submitted == 0, 'err=' .. tostring(errNoScan))
    c:applyScan('mill_1', nil, nil, os.epoch('utc'), 9)
    local _, err = c:pushItem('chest_1', 1, 4, 'mill_1', nil, c.INSERT_SPEED, 'test')
    check('after the interaction container is scanned the push is dispatched',
        err == 'pending' and #submitted == 1, 'err=' .. tostring(err) .. ' n=' .. tostring(#submitted))
    local task = submitted[1]
    check('the task carries what the source snapshot says (item name + reserved amount)',
        task and task.reserved == 4 and task.item == 'minecraft:cobblestone',
        task and ('reserved=' .. tostring(task.reserved) .. ' item=' .. tostring(task.item)))
    check('an interaction container that really is an inventory keeps actor = "from"',
        task and task.actor == 'from', task and tostring(task.actor))
end

-- ===================== 虚拟定义（turtle_crafter 预设类型，用户第 3 项）=====================
do
    local Store = StoreModule
    local fake = setmetatable({ data = { containers = {}, machines = {}, machineTypes = {} } },
        { __index = Store })
    fake.markDirty = function() end
    fake:setVirtual('machineTypes', { { name = 'turtle_crafter' } })
    check('the preset machine type is visible through get/list',
        fake:get('machineTypes', 'turtle_crafter') ~= nil and #fake:list('machineTypes') == 1)
    check('turtle_crafter is recognised as the turtle crafter machine type',
        Store.isTurtleCrafter({ type = 'turtle_crafter' }) == true and
        Store.isTurtleCrafter({ type = 'other' }) == false)

    fake:setVirtual('containers', { { name = 'turtle_0', peripheral = 'turtle_0', kind = 'item',
        role = 'interaction' } })
    fake:setVirtual('machines', { { name = 'turtle_0', type = 'turtle_crafter', parallel = 1,
        itemInputs = { 'turtle_0' }, itemOutputs = { 'turtle_0' } } })
    check('a virtual container resolves by name and by kind',
        fake:get('containers', 'turtle_0', 'item') ~= nil and fake:findContainer('turtle_0') ~= nil)
    check('virtual definitions show up in list() but never enter the saved data',
        #fake:list('containers') == 1 and #fake:list('machines') == 1 and
        fake.data.machines['turtle_0'] == nil)
    check('the preset type shows up in the machine type names (processes can pick it)',
        fake:names('machineTypes')[1] == 'turtle_crafter')
end

-- ===================== 配置只读保护（读不出来时绝不覆盖用户数据）=====================
-- 现场风险：config.json 被写坏 / 手工改坏时，Store:load 会退回"空配置"；
-- 只要之后有任何一处标脏写盘，用户的整座工厂就被一份空配置覆盖了（静默数据丢失）。
do
    local Store = StoreModule
    local fake = setmetatable({ data = {}, virtual = {}, readOnly = true }, { __index = Store })
    local wrote = 0
    fake.file = { flush = function() wrote = wrote + 1; return true end }
    local ok, err = fake:flush()
    check('a read-only store never writes the empty config back over a broken file',
        ok == false and wrote == 0 and tostring(err):find('refusing') ~= nil, tostring(err))

    --- 虚拟定义不标脏（它们不落盘）：否则 config.json 读不出来时会被这份"变更"顺手写坏
    local clean = setmetatable({ data = {}, virtual = {} }, { __index = Store })
    local dirty = 0
    clean.markDirty = function() dirty = dirty + 1 end
    clean:setVirtual('machines', { { name = 'turtle_0', type = 'turtle_crafter' } })
    check('setVirtual never marks the store dirty (virtual definitions are not persisted)',
        dirty == 0, 'markDirty calls=' .. tostring(dirty))
end

-- ===================== 入库槽位预留（用户第 4 项）=====================
-- 两个入库任务原本可能都选中同一个空格子（其中一个搬不进去）；现在派任务前先把目标槽位"占"住：
-- 预留是 +amount 的乐观变更 → 其它任务看到的余量已经扣掉了这一笔。
do
    local StoreStub = {
        list = function() return {} end,
        findContainer = function(_, name)
            --- 交互容器（海龟）与存储容器分开：跨角色的搬运要更新数量快照（用户第 9 项）
            local role = (tostring(name):find('turtle') and 'interaction') or 'storage'
            return { name = name, peripheral = name, kind = 'item', role = role }
        end,
    }
    local PeripheralsStub = {
        exists = function() return true end,
        isInventory = function() return true end,
        isFluid = function() return false end,
        isTurtle = function() return false end,
        names = function() return {} end,
        invalidate = function() end,
        lastScan = 0,
    }
    local c = Containers.new({
        Util = { kindOfDef = function() return 'item' end },
        Peripherals = PeripheralsStub,
        Store = StoreStub,
        Filter = {},
        log = function() end,
    })
    local name = 'minecraft:chest_1'
    local model = c:modelOf(name)
    c:applyScan(name, { { slot = 1, name = 'minecraft:cobblestone', count = 0 } }, nil, os.epoch('utc'))
    c:reserveIn(name, 1, 10, 'item', 'minecraft:cobblestone')
    check('an inbound reservation only marks the slot dirty - it writes no count (user item 9)',
        c:visibleSlotCount(model, 1) == 0 and c:isDirtySlot(name, 1) == true,
        'visible=' .. tostring(c:visibleSlotCount(model, 1)) .. ' dirty=' .. tostring(c:isDirtySlot(name, 1)))
    c:settleMove({ kind = 'item', from = 'turtle_0', fromIndex = 1, to = name, toIndex = 1,
        reserved = 10, item = 'minecraft:cobblestone' }, 10)
    check('the successful inbound amount is added to the snapshot when the move settles',
        c:visibleSlotCount(model, 1) == 10 and c:isDirtySlot(name, 1) == false,
        tostring(c:visibleSlotCount(model, 1)))
end

-- ===================== 调度设置：局部更新（用户第 5 项）=====================
-- 现场问题：网页提交设置时只带"本次改动的键"，而 Store:set 是**整条替换** ——
-- 于是"关掉给网页发日志"会把 localPool 这个键一起抹掉，读回来又回落成默认 true，
-- 表现就是"关掉一个开关，另一个自己打开，两个永远不能同时关闭"。
-- 修法：走 Store:patchSettings（读出现有内容 → 覆盖本次的键 → 整条写回）。
do
    local Store = StoreModule
    local function newStore(settings)
        local fake = setmetatable({
            data = { settings = { schedule = settings } },
            log = function() end,
            --- Store:set 只用得上 trim + deepcopy（settings 这个 kind 不做容器/信号那套名字推导）。
            --- 注意：模块里是按 Util.trim(x) / Util.deepcopy(x) 调的（点调用，没有 self）。
            Util = {
                trim = function(value) return value end,
                deepcopy = function(value)
                    if type(value) ~= 'table' then return value end
                    local copy = {}
                    for key, item in pairs(value) do copy[key] = item end
                    return copy
                end,
            },
        }, { __index = Store })
        fake.markDirty = function() end
        return fake
    end
    local store = newStore({ slices = { process = 0.5, storageScan = 0.5 },
        localPool = false, sendLog = false, compactFreeRatio = 0.25 })
    local ok, err = store:patchSettings(Store.SCHEDULE_NAME, { sendLog = true })
    local after = store:get('settings', Store.SCHEDULE_NAME)
    check('patchSettings only touches the keys it was given (the other settings survive)',
        ok == true and after.localPool == false and after.sendLog == true and
            after.compactFreeRatio == 0.25,
        'localPool=' .. tostring(after.localPool) .. ' sendLog=' .. tostring(after.sendLog) ..
            ' compactFreeRatio=' .. tostring(after.compactFreeRatio) .. ' err=' .. tostring(err))

    store:patchSettings(Store.SCHEDULE_NAME, { sendLog = false })
    store:patchSettings(Store.SCHEDULE_NAME, { localPool = false })
    local applied = store:scheduleSettings()
    check('both switches can be off at the same time',
        applied.localPool == false and applied.sendLog == false,
        'localPool=' .. tostring(applied.localPool) .. ' sendLog=' .. tostring(applied.sendLog))

    local function ratioOf(value)
        return newStore({ slices = {}, compactFreeRatio = value }):scheduleSettings().compactFreeRatio
    end
    check('the auto compact free-slot threshold defaults to 0.30', ratioOf(nil) == 0.30,
        tostring(ratioOf(nil)))
    check('a saved free-slot threshold is kept as is', ratioOf(0.35) == 0.35, tostring(ratioOf(0.35)))
    check('a free-slot threshold above 1 is clamped to 1', ratioOf(7) == 1, tostring(ratioOf(7)))
end

-- ===================== 自动整理的空槽位阈值（用户第 4 项）=====================
-- 要求：存储容器的**空槽位比例低于阈值**才整理（空槽位还够多就不搬），阈值在网页设置里可改。
do
    local Recipe = RecipeModule
    local function newEngine(used, total)
        return Recipe.new({
            log = function() end,
            Cache = { markDirty = function() end },
            Containers = {
                capacityStats = function()
                    return { items = 0, itemCapacity = 0, slots = used or 0, totalSlots = total or 0 }
                end,
            },
        })
    end

    --- 空槽位 90%：不该整理（阈值默认 0.30：空槽位还多就不搬）
    local plenty = newEngine(10, 100)
    local calls = 0
    plenty.startCompact = function(self) calls = calls + 1; self.compact = { state = 'done' }; return true end
    check('compaction is skipped while storage still has plenty of free slots',
        plenty:autoCompactStep(os.epoch('utc')) == 0 and calls == 0, 'startCompact calls=' .. tostring(calls))

    --- 空槽位 3% < 30%：该整理（startCompact 被调用，计划为空 → 立刻收尾）
    local tight = newEngine(97, 100)
    local calls2 = 0
    tight.startCompact = function(self)
        calls2 = calls2 + 1
        self.compact = { state = 'done', plan = {} }
        return true
    end
    check('compaction runs when the free slots drop below the threshold',
        tight:autoCompactStep(os.epoch('utc')) == 0 and calls2 == 1 and tight.compact == nil,
        'startCompact calls=' .. tostring(calls2))

    check('the free-slot ratio comes from the storage capacity stats',
        math.abs(plenty:storageFreeRatio() - 0.9) < 1e-9, tostring(plenty:storageFreeRatio()))
    check('an unknown storage size counts as "not full" (no compaction)',
        newEngine(0, 0):storageFreeRatio() == nil)

    check('the threshold can be changed at runtime and is clamped to 0..1',
        plenty:setCompactFreeRatio(0.25) == 0.25 and plenty:setCompactFreeRatio(-3) == 0 and
            plenty:setCompactFreeRatio(9) == 1, tostring(plenty.compactFreeRatio))
end

-- ===================== 散堆合并（用户第 4 项）=====================
-- 现场问题：整理只把整堆搬进**空槽位**，所以"3 个槽位各 10 个"永远合不成"1 个槽位 30 个"。
-- 现在：同一种物品（同名同 NBT）就地合并 —— 数量最多的那几堆当目标槽位，
-- 剩下的堆往目标的剩余空间里塞；要的槽位数 = ceil(总数 / 单槽堆叠上限)。
do
    local defs = {
        { name = 'chest_a', peripheral = 'chest_a', kind = 'item', role = 'storage' },
        { name = 'chest_b', peripheral = 'chest_b', kind = 'item', role = 'storage' },
    }
    local PeripheralsStub = {
        exists = function() return true end,
        isInventory = function() return true end,
        isFluid = function() return false end,
        isTurtle = function() return false end,
        names = function() return {} end,
        invalidate = function() end,
        -- slotCount 会走这里：size() = 每台 9 个槽位（空槽位也算容器容量）
        wrap = function() return { size = function() return 9 end } end,
        lastScan = 0,
    }
    local StoreStub = {
        list = function() return defs end,
        findContainer = function(_, name)
            for _, def in ipairs(defs) do
                if def.name == name then return def end
            end
            return nil
        end,
    }
    local function newPlanner()
        local c = Containers.new({
            Util = { kindOfDef = function() return 'item' end },
            Peripherals = PeripheralsStub,
            Store = StoreStub,
            Filter = {},
            log = function() end,
        })
        c:absorbItemDetails({ { name = 'minecraft:cobblestone',
            detail = { name = 'minecraft:cobblestone', maxCount = 64 } } })
        return c
    end
    local function stacksOf(plan)
        local out = {}
        for _, move in ipairs(plan) do
            out[#out + 1] = tostring(move.fromContainer) .. ':' .. tostring(move.fromSlot) .. '->' ..
                tostring(move.toContainer) .. ':' .. tostring(move.toSlot) .. ' x' .. tostring(move.amount)
        end
        table.sort(out)
        return table.concat(out, ', ')
    end

    --- 1) 三个散堆（各 10 个）合并成一堆：只搬 2 次，全部并进数量最多的那一堆所在的槽位
    local c = newPlanner()
    c:applyScan('chest_a', {
        { slot = 1, name = 'minecraft:cobblestone', count = 10 },
        { slot = 2, name = 'minecraft:cobblestone', count = 10 },
        { slot = 3, name = 'minecraft:cobblestone', count = 10 },
    }, nil, os.epoch('utc'))
    local plan = c:compactPlanSimple('storage')
    local merged, movedTotal = true, 0
    for _, move in ipairs(plan) do
        movedTotal = movedTotal + move.amount
        if move.toContainer ~= 'chest_a' or move.toSlot ~= 1 then merged = false end
    end
    check('scattered stacks of the same item are merged into one slot (user item 4)',
        #plan == 2 and merged and movedTotal == 20, stacksOf(plan))

    --- 2) 已经并好的堆不再空搬（每一堆都装得下就不该有任何搬运）
    local c2 = newPlanner()
    c2:applyScan('chest_a', {
        { slot = 1, name = 'minecraft:cobblestone', count = 33 },
        { slot = 2, name = 'minecraft:cobblestone', count = 33 },
    }, nil, os.epoch('utc'))
    local plan2 = c2:compactPlanSimple('storage')
    check('well packed stacks are left alone (no pointless moves to empty slots)',
        #plan2 == 0, stacksOf(plan2))

    --- 3) 满堆 + 散堆：只把散堆并进还有空间的那些堆（满堆一间房都没有，不选它）
    local c3 = newPlanner()
    c3:applyScan('chest_a', {
        { slot = 1, name = 'minecraft:cobblestone', count = 64 },
        { slot = 2, name = 'minecraft:cobblestone', count = 10 },
    }, nil, os.epoch('utc'))
    c3:applyScan('chest_b', { { slot = 1, name = 'minecraft:cobblestone', count = 10 } }, nil, os.epoch('utc'))
    local plan3 = c3:compactPlanSimple('storage')
    check('a source stack goes into the partial stack with room, never into a full slot',
        #plan3 == 1 and plan3[1].amount == 10 and plan3[1].fromContainer == 'chest_b' and
            plan3[1].toContainer == 'chest_a' and plan3[1].toSlot == 2,
        stacksOf(plan3))

    --- 4) 正在被搬的槽位（脏）不碰：那一堆既不当目标也不当源
    local c4 = newPlanner()
    c4:applyScan('chest_a', {
        { slot = 1, name = 'minecraft:cobblestone', count = 10 },
        { slot = 2, name = 'minecraft:cobblestone', count = 10 },
        { slot = 3, name = 'minecraft:cobblestone', count = 10 },
    }, nil, os.epoch('utc'))
    c4:reserveOut('chest_a', 1, 10, 'item')          -- 槽位 1 有在飞任务
    local plan4 = c4:compactPlanSimple('storage')
    local touchedDirty = false
    for _, move in ipairs(plan4) do
        if move.fromSlot == 1 or (move.toContainer == 'chest_a' and move.toSlot == 1) then
            touchedDirty = true
        end
    end
    check('slots with an in-flight move are left alone by the planner',
        touchedDirty == false and #plan4 > 0, stacksOf(plan4))
end

-- ===================== 容器移除后立刻清除读到的内容（用户第 3 项）=====================
-- 现场问题：容器外设被移除之后，之前从这里读到的物品还留在内容模型里
-- （整理计划 / 槽位数量 / 容器管理面板继续按旧内容算账）。
do
    local present = true
    local defs = { { name = 'chest_a', peripheral = 'chest_a', kind = 'item', role = 'storage' } }
    local PeripheralsStub = {
        exists = function() return present end,
        isInventory = function() return present end,
        isFluid = function() return false end,
        isTurtle = function() return false end,
        names = function() return {} end,
        invalidate = function() end,
        lastScan = 0,
    }
    local StoreStub = {
        list = function() return defs end,
        findContainer = function(_, name)
            for _, def in ipairs(defs) do
                if def.name == name then return def end
            end
            return nil
        end,
    }
    local c = Containers.new({
        Util = { kindOfDef = function() return 'item' end },
        Peripherals = PeripheralsStub,
        Store = StoreStub,
        Filter = {},
        log = function() end,
    })
    c:applyScan('chest_a', { { slot = 1, name = 'minecraft:cobblestone', count = 64 } }, nil, os.epoch('utc'))
    check('the item read from the container is there before it is removed',
        #c:stacksPeripheral('chest_a') == 1 and #c:resources() == 1)

    --- 在飞的搬运引用着这个外设：外设一没，它必须被结算掉（否则预留会挂到 60 秒兜底清理）
    c.moveInflight['inflight'] = { key = 'inflight', kind = 'item', from = 'chest_a', fromIndex = 1,
        to = 'chest_b', toIndex = 1, reserved = 8, item = 'minecraft:cobblestone' }

    --- 外设被拔掉：下一个扫到它的地方就是 pruneMissingPeripherals
    present = false
    local dropped = c:pruneMissingPeripherals('test: peripheral removed')
    check('removing the peripheral clears the contents read from it (user item 3)',
        dropped == 1 and c:modelOf('chest_a').slots[1] == nil and #c:stacksPeripheral('chest_a') == 0 and
            #c:resources() == 0,
        'dropped=' .. tostring(dropped) .. ' slot1=' .. tostring(c:modelOf('chest_a').slots[1] ~= nil))
    check('in-flight moves of a removed peripheral are settled immediately',
        c.moveInflight['inflight'] == nil)

    --- 外设还在、但定义被删了：同样不再算它的内容
    present = true
    c:applyScan('chest_a', { { slot = 1, name = 'minecraft:cobblestone', count = 64 } }, nil, os.epoch('utc'))
    defs = {}
    local dropped2 = c:pruneMissingPeripherals('test: definition deleted')
    check('deleting the definition also clears what was read from that peripheral',
        dropped2 >= 1 and #c:stacksPeripheral('chest_a') == 0 and #c:resources() == 0,
        'dropped=' .. tostring(dropped2))

    --- 再调用一次不会冒出内容来（清理是幂等的：读到的物品始终是空的）
    c:pruneMissingPeripherals('test: again')
    check('pruning again leaves nothing behind (contents stay empty)',
        #c:resources() == 0 and #c:stacksPeripheral('chest_a') == 0,
        'resources=' .. tostring(#c:resources()))
end

-- ===================== 删除条目立即下发（用户第 1 / 3 项）=====================
-- 延迟确认（3 秒）是为了防扫描抖动，但"发送队列的条目消失"与"容器被移除后资源消失"是
-- **确定**的删除：网页上不该再挂着它们（用户看到的是"东西发完了还写着发送中"）。
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    p.needFullSync = false          -- 已经全量同步过：下面测的是增量里的删除
    p.snapshot.deliveries = { { id = 1, kind = 'item', name = 'minecraft:cobblestone', remaining = 8 } }
    local changes = p:diffCategory('deliveries', {})
    check('a finished delivery is tombstoned immediately (no 3s delay)',
        #changes == 1 and changes[1]._deleted == true and changes[1].id == 1, tostring(#changes))

    --- 资源默认仍然走延迟确认（防扫描抖动）
    p.snapshot.resources = { { kind = 'item', name = 'minecraft:cobblestone', count = 64 } }
    check('resources still use the delayed tombstone by default',
        #p:diffCategory('resources', {}) == 0)

    --- expediteDeletions：下一次推送把消失的资源立刻删掉（容器移除后网页上要立刻清）
    p.snapshot.resources = { { kind = 'item', name = 'minecraft:cobblestone', count = 64 } }
    p:expediteDeletions()
    local urgent = p:diffCategory('resources', {}, p.expediteTombstones)
    check('expediteDeletions tombstones the vanished resources right away',
        #urgent == 1 and urgent[1]._deleted == true and urgent[1].name == 'minecraft:cobblestone',
        tostring(#urgent))
end

-- ===================== worker 失联口径（用户第 1 项：时而在线时而不在线）=====================
-- 现场：worker 安静十几秒就被**摘掉**（网页上的卡片消失、再出现时计数清零），
-- 但 15 秒只是"无线链路抖了一下"的量级。现在两个阈值分开：
--   15 秒  = 标失联（卡片留着、红字提示，也不再派新活）；
--   90 秒  = 才真正摘掉（它的任务早就各自超时失败了）。
-- 另外主控自己卡住（一次同步写盘能把主循环停几十秒）时，这段时间要扣掉 —— 那是我们没在听。
do
    local function newTransfer()
        return TransferModule.new({
            log = function() end,
            Modems = {
                find = function() return nil end,
                asModem = function() return nil end,
                transmit = function() return true end,
            },
        })
    end

    local t = newTransfer()
    t:setContext({ version = 'test' })
    local now = os.epoch('utc')          -- workerUsable 内部用真实时钟，所以基准也用真实时钟
    t.lastTickAt = now
    t.workers[7] = { id = 7, lastSeen = now - 20000, stateAt = now - 20000, slots = 4, inFlight = 0 }

    check('a worker that has been silent for 20s counts as stale (and gets no new jobs)',
        t:workerStale(t.workers[7], now) == true and t:workerUsable(t.workers[7]) == false)

    t:tick(now)
    check('a 20s silence does NOT remove it yet (stale at 15s, removed at 30s)',
        t.workers[7] ~= nil and t.stats.workersDropped == nil,
        'workers=' .. tostring(t.workers[7] and 1 or 0))

    --- 又听到它了：失联标记清掉，重新可用
    t.workers[7].lastSeen = now
    t.workers[7].stateAt = now
    check('a fresh report makes it usable again', t:workerStale(t.workers[7], now) == false and
        t:workerUsable(t.workers[7]) == true)

    --- 主控自己卡了 30 秒：这段时间不算"worker 失联"
    local stallNow = now + 30000
    t.workers[7].lastSeen = now
    t.workers[7].stateAt = now
    t:tick(stallNow)
    check('a 30s master stall does not evict the worker (we were the ones not listening)',
        t.workers[7] ~= nil and t.lastStallMs >= 30000, 'stall=' .. tostring(t.lastStallMs))

    --- 用户第 2 项：**到点即移除**，不一直等它恢复（静默 > 30 秒就摘掉）。
    --- 先看边界：25 秒只是标失联，仍在列表里。
    --- 注意这几轮之间都只有 1 秒（不是"主控自己卡住"），静默时间才不会被扣掉。
    local almost = stallNow + 25000
    t.lastTickAt = almost - 1000
    t.workers[7].lastSeen = almost - 25000
    t.workers[7].stateAt = almost - 25000
    t:tick(almost)
    check('25s of silence is not enough to remove the worker (grace period before eviction)',
        t.workers[7] ~= nil, 'workers=' .. tostring(t.workers[7] and 1 or 0))

    --- 超过 30 秒：摘掉；它手上的搬运失败、查询作废**并通知主控**（onQueryDropped）——
    --- 不通知的话，那条容器的代扫会永远卡在 inflight，那个容器再也不更新。
    local dropped = {}
    t.onQueryDropped = function(key, reason) dropped[#dropped + 1] = { key = key, reason = reason } end
    local gone = almost + 40000
    t.lastTickAt = gone - 1000
    t.workers[7].lastSeen = gone - 100000
    t.workers[7].stateAt = gone - 100000
    t.jobs = { { id = 1, worker = 7, state = 'pending', at = gone - 100000, key = 'k' } }
    t.queries = { [1] = { id = 1, key = 'scan:chest_9', worker = 7, at = gone - 100000 } }
    t.queryRunning['scan:chest_9'] = 1
    t:tick(gone)
    check('after 30s+ of silence the worker is really removed and its jobs fail',
        t.workers[7] == nil and t.jobs[1].state == 'failed' and t.stats.failed == 1,
        'workers=' .. tostring(t.workers[7] and 1 or 0) .. ' job=' .. tostring(t.jobs[1].state) ..
            ' failed=' .. tostring(t.stats.failed))
    check('the scan it was running is reported as dropped so the scan queue can retry it',
        #dropped == 1 and dropped[1].key == 'scan:chest_9' and
            tostring(dropped[1].reason):find('offline', 1, true) ~= nil and
            t.queryRunning['scan:chest_9'] == nil,
        'n=' .. tostring(#dropped) .. ' key=' .. tostring(dropped[1] and dropped[1].key))

    --- 另一条触发路径：worker 还在线，但某条查询自己超时（QUERY_TIMEOUT = 10s）→ 同样通知
    dropped = {}
    t.workers[8] = { id = 8, lastSeen = gone, stateAt = gone, slots = 4, inFlight = 0, version = 'test' }
    t.queries = { [2] = { id = 2, key = 'scan:chest_10', worker = 8, at = gone - 60000 } }
    t.queryRunning['scan:chest_10'] = 2
    t:tick(gone + 1000)
    check('a query that times out is reported as dropped too (scan queue can retry it)',
        #dropped == 1 and dropped[1].key == 'scan:chest_10' and
            tostring(dropped[1].reason):find('timeout', 1, true) ~= nil,
        'n=' .. tostring(#dropped) .. ' reason=' .. tostring(dropped[1] and dropped[1].reason))
    t.onQueryDropped = nil

    --- 本轮第 6 项：网页的负载条要用 worker 上报的"整秒峰值并发"（load 只是上报那一刻的值，
    --- 任务很短 → 永远是 0，用户看到的就是"永远空闲、负载 0/64"）。这里确认主控把它带进快照。
    t.workers[7] = { id = 7, lastSeen = now, stateAt = now, slots = 64, inFlight = 0, load = 0, peak = 5 }
    local uiWorker
    for _, entry in ipairs(t:workersForUi()) do
        if entry.id == 7 then
            uiWorker = entry
        end
    end
    check('workersForUi passes the worker peak load through (web load bar)',
        uiWorker ~= nil and uiWorker.peak == 5 and uiWorker.load == 0 and uiWorker.slots == 64,
        uiWorker and ('peak=' .. tostring(uiWorker.peak) .. ' load=' .. tostring(uiWorker.load)))
end

-- ===================== 读取规则：interaction / output 绝不可读（用户规则）=====================
-- 规则（写在 modules/containers.lua 顶部）：
--   * 只有 storage / input 角色参与扫描与读取；
--   * interaction / output 绝不读、绝不扫：盲搬 / 盲抽 + 只按成功搬运量记账；
--   * 任何试图读它们的路径都必须**直接报错**（编码规范：未定义行为不许静默失败）。
do
    local defs = {
        { name = 'store_1', peripheral = 'chest_1', kind = 'item', role = 'storage' },
        { name = 'in_1', peripheral = 'barrel_1', kind = 'item', role = 'input' },
        { name = 'machine_1', peripheral = 'millstone_1', kind = 'item', role = 'interaction' },
        { name = 'out_1', peripheral = 'chute_1', kind = 'item', role = 'output' },
        { name = 'turtle_1', peripheral = 'turtle_1', kind = 'item', role = 'interaction' },
    }
    local function defOf(name)
        for _, def in ipairs(defs) do
            if def.name == name then return def end
        end
        return nil
    end
    local PeripheralsStub = {
        --- 注意：交互/输出容器也当成真 inventory（它们现在**也会被扫描**）；
        --- 只有海龟不是 inventory 外设（它的内容由它自己上报）
        exists = function() return true end,
        isInventory = function(_, name) return name ~= 'turtle_1' end,
        isFluid = function() return false end,
        isTurtle = function(_, name) return name == 'turtle_1' end,
        names = function() return {} end,
        invalidate = function() end,
        wrap = function() return {} end,
        lastScan = 0,
    }
    local StoreStub = {
        list = function() return defs end,
        findContainer = function(_, name) return defOf(name) end,
    }
    local c = Containers.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Peripherals = PeripheralsStub,
        Store = StoreStub,
        Filter = { specMatches = function() return true end },
        log = function() end,
    })

    --- 用户第 2 项（1.9.0）：每个角色都可读 —— 都会被扫描（海龟那类由它自己上报物品栏）
    check('every role is readable now (storage / input / interaction / output)',
        Containers.roleIsReadable('storage') and Containers.roleIsReadable('input') and
            Containers.roleIsReadable('interaction') and Containers.roleIsReadable('output'))

    --- 扫描目标：按角色分**四条**队列（interaction 与 output 各自一条 —— 用户第 1 项）
    local targets = c:scanQueueTargets()
    local storageList, inputList, interactionList, outputList = {}, {}, {}, {}
    for name in pairs(targets.storageScan) do storageList[#storageList + 1] = name end
    for name in pairs(targets.inputScan) do inputList[#inputList + 1] = name end
    for name in pairs(targets.interactionScan) do interactionList[#interactionList + 1] = name end
    for name in pairs(targets.outputScan) do outputList[#outputList + 1] = name end
    table.sort(interactionList)
    table.sort(outputList)
    check('scan targets follow the roles (storage / input / interaction / output)',
        #storageList == 1 and storageList[1] == 'chest_1' and
            #inputList == 1 and inputList[1] == 'barrel_1' and
            #interactionList == 1 and interactionList[1] == 'millstone_1' and
            #outputList == 1 and outputList[1] == 'chute_1',
        'storageScan=' .. table.concat(storageList, ',') .. ' inputScan=' .. table.concat(inputList, ',') ..
            ' interactionScan=' .. table.concat(interactionList, ',') ..
            ' outputScan=' .. table.concat(outputList, ','))

    --- 读守卫：按定义读 interaction / output 必须报错（不许静默返回空）
    local function fails(fn, ...)
        local ok = pcall(fn, ...)
        return ok == false
    end
    --- 用户第 2 项（1.9.0）：读守卫已删除 —— 交互容器 / 输出容器**都能读**（它们都会被扫描），
    --- 海龟那类没有 inventory 的容器由它自己上报，同样有一份内容快照。
    check('every role can be read now (storage / interaction / output)',
        not fails(c.snapshot, c, 'interaction') and not fails(c.stacks, c, 'machine_1') and
            not fails(c.countIn, c, 'machine_1', { kind = 'item', id = 'x' }) and
            not fails(c.stackAt, c, 'machine_1', 1) and
            not fails(c.stacks, c, 'out_1') and not fails(c.tanks, c, 'out_1') and
            not fails(c.stacks, c, 'store_1') and not fails(c.snapshot, c, 'storage'))
    check('interaction / output containers are still recognised by role', 
        c:isInteractionContainer('machine_1', 'item') == true and
            c:isInteractionContainer('store_1', 'item') == false and
            c:hasSnapshot('machine_1') == false)

    --- 扫描队列（用户第 1/2 项）：按角色分四条 —— interaction 与 output **各自一条**；
    --- storage 进 storageScan、input 进 inputScan；扫不了的外设（海龟）不在任何队列里。
    local targets = c:scanQueueTargets()
    check('scan queues are split by role (interaction / output each get their own queue)',
        targets.interactionScan['millstone_1'] == true and
            targets.outputScan['chute_1'] == true and
            targets.storageScan['chest_1'] == true and
            targets.interactionScan['chute_1'] == nil and
            targets.outputScan['millstone_1'] == nil,
        'interaction=' .. tostring(next(targets.interactionScan or {})) ..
            ' output=' .. tostring(next(targets.outputScan or {})))

    --- worker 扫描回报的字段兼容（修 bug：主控以前只读 scanned，worker 从来不发它）
    check('scan reply count: new worker (scanned) and old worker (scannedContainers) both work',
        Containers.scanCountOfReply({ scanned = 1 }) == 1 and
            Containers.scanCountOfReply({ scannedContainers = { 'chest_1' } }) == 1 and
            Containers.scanCountOfReply({ scanned = 0 }) == 0)
    check('scan reply with neither field returns nil (the caller must report the version mismatch)',
        Containers.scanCountOfReply({}) == nil and Containers.scanCountOfReply(nil) == nil)
end

-- ===================== 抽取产物：一律按内容快照决策（用户第 2/3 项）=====================
-- 1.9.0 起所有角色的容器都会被扫描（interaction / output 也一样；海龟由它自己上报），
-- 抽取因此是**有依据**的：
--   * 只抽快照里与产物匹配的槽位（同名 + 同 NBT）；拿不到快照 → 直接失败（不猜、不盲抽）；
--   * 已被其它任务认领的脏槽位不抽；抽取前把源槽位标脏（用户第 3 项）；
--   * 流程"输出产物"里填的槽位序号现在只是**限定**：填了就只抽那一个槽位。
do
    local Recipe = RecipeModule
    local defs = {
        { name = 'machine_1', peripheral = 'millstone_1', kind = 'item', role = 'interaction' },
        { name = 'out_1', peripheral = 'chute_1', kind = 'item', role = 'output' },
        { name = 'out_2', peripheral = 'chute_2', kind = 'item', role = 'output' },
        { name = 'store_1', peripheral = 'chest_1', kind = 'item', role = 'storage' },
        { name = 'store_2', peripheral = 'chest_2', kind = 'item', role = 'storage' },
    }
    local reads, pushes = 0, {}
    local fakePeripheral = {
        pushItems = function(to, fromSlot, limit, toSlot)
            pushes[#pushes + 1] = { to = to, fromSlot = fromSlot, limit = limit, toSlot = toSlot }
            return limit
        end,
    }
    local PeripheralsStub = {
        exists = function() return true end,
        --- 交互容器也是真 inventory：证明"盲"是按角色判定的，不是按能力
        isInventory = function() return true end,
        isFluid = function() return false end,
        isTurtle = function() return false end,
        names = function() return {} end,
        invalidate = function() end,
        wrap = function() return fakePeripheral end,
        lastScan = 0,
    }
    local StoreStub = {
        list = function() return defs end,
        findContainer = function(_, name)
            for _, def in ipairs(defs) do
                if def.name == name then return def end
            end
            return nil
        end,
    }
    local c = Containers.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Peripherals = PeripheralsStub,
        Store = StoreStub,
        Filter = { specMatches = function() return true end },
        log = function() end,
    })
    --- 读计数：抽取现在**本来就该读快照**（不再是"零读"）—— 这里仍数一下调用次数，
    --- 用来断言"这次抽取确实走了快照路径"。
    local realStacks = c.stacksPeripheral
    c.stacksPeripheral = function(self_, ...)
        reads = reads + 1
        return realStacks(self_, ...)
    end

    local engine = Recipe.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Store = StoreStub,
        Cache = { markDirty = function() end },
        Peripherals = PeripheralsStub,
        Containers = c,
        Filter = { specMatches = function() return true end },
        log = function() end,
    })
    local function machineWith(output)
        return { name = 'm1', itemInputs = {}, fluidInputs = {}, itemOutputs = { output }, fluidOutputs = {} }
    end
    local spec = { kind = 'item', id = 'minecraft:flour' }

    --- 1) interaction 输出容器：**没有快照 = 什么都不做**（旧盲抽路径已删除，不猜槽位）
    reads, pushes = 0, {}
    local _, reasonNoSnap = engine:transferOut(spec, machineWith('machine_1'), 4, 'tok-nosnap')
    check('without a content snapshot nothing is extracted (no blind pull, no guessing)',
        #pushes == 0 and reasonNoSnap == nil,
        'pushes=' .. tostring(#pushes) .. ' reason=' .. tostring(reasonNoSnap))

    --- 1b) 交互容器被扫过一次（真 inventory → interactionScan 队列）→ 抽取按快照来：
    ---     产物在第 2 槽 → 只从第 2 槽抽；抽取前把源槽位标脏（用户第 3 项）
    c:applyScan('millstone_1', { { slot = 2, name = 'minecraft:flour', count = 4 } }, nil, os.epoch('utc'))
    reads, pushes = 0, {}
    local _, reason1 = engine:transferOut(spec, machineWith('machine_1'), 4, 'tok-snap')
    check('the interaction container is extracted from the slot its snapshot points at',
        reads >= 1 and #pushes == 1 and pushes[1].fromSlot == 2 and pushes[1].limit == 4 and
            reason1 == 'pending',
        'reads=' .. tostring(reads) .. ' pushes=' .. tostring(#pushes) ..
            ' fromSlot=' .. tostring(pushes[1] and pushes[1].fromSlot) .. ' reason=' .. tostring(reason1))
    --- 说明："抽取前把源槽位标脏"由容器层的用例覆盖（那里把派活截下来，能直接看到脏标记）；
    --- 这里任务被同步执行完了（脏标记也随之解除），所以可观察的结果是**快照被扣减**。
    check('the snapshot is decremented by the extracted amount (the move really happened)',
        c:stackAt('machine_1', 2) == nil, tostring(c:stackAt('machine_1', 2)))

    --- 2) 同一次抽取再问一次（token 相同）：取回结果，绝不再搬一遍
    local moved2 = engine:transferOut(spec, machineWith('machine_1'), 4, 'tok-snap')
    check('the same extraction token books the result instead of moving twice',
        moved2 == 4 and #pushes == 1, 'moved=' .. tostring(moved2) .. ' pushes=' .. tostring(#pushes))

    --- 3) 流程里填了槽位序号 = 只抽那一个槽位（限定；不再是"盲抽的槽位来源"）
    c:applyScan('millstone_1', { { slot = 2, name = 'minecraft:flour', count = 4 } }, nil, os.epoch('utc'))
    reads, pushes = 0, {}
    engine:transferOut(spec, machineWith('machine_1'), 2, 'tok-slot3', { fromSlot = 3 })
    check('a configured slot that does not hold the product is not extracted',
        #pushes == 0, 'pushes=' .. tostring(#pushes))
    reads, pushes = 0, {}
    engine:transferOut(spec, machineWith('machine_1'), 2, 'tok-slot2', { fromSlot = 2 })
    check('the configured slot is used when the snapshot confirms the product is there',
        #pushes == 1 and pushes[1].fromSlot == 2,
        'pushes=' .. tostring(#pushes) .. ' fromSlot=' .. tostring(pushes[1] and pushes[1].fromSlot))
    check('the snapshot reflects the extraction (4 - 2 = 2 left in that slot)',
        c:stackAt('machine_1', 2) ~= nil and c:stackAt('machine_1', 2).count == 2,
        tostring(c:stackAt('machine_1', 2) and c:stackAt('machine_1', 2).count))

    --- 4) output 角色的容器：一样按快照抽取（它也在 interactionScan 队列里）
    c:applyScan('chute_1', { { slot = 1, name = 'minecraft:flour', count = 1 } }, nil, os.epoch('utc'))
    reads, pushes = 0, {}
    engine:transferOut(spec, machineWith('out_1'), 1, 'tok-out')
    check('an output-role container is extracted from its snapshot too',
        #pushes == 1 and pushes[1].fromSlot == 1,
        'pushes=' .. tostring(#pushes) .. ' slot=' .. tostring(pushes[1] and pushes[1].fromSlot))

    --- 4b) 另一个 output 容器还没被扫过（没有快照）→ 什么都不做，绝不盲抽
    reads, pushes = 0, {}
    local _, reasonNoSnap2 = engine:transferOut(spec, machineWith('out_2'), 1, 'tok-nosnap2')
    check('a container with no snapshot is not extracted either',
        #pushes == 0 and reasonNoSnap2 == nil,
        'pushes=' .. tostring(#pushes) .. ' reason=' .. tostring(reasonNoSnap2))

    --- 5) storage 角色的输出容器：同一条路径（快照 + 产物匹配；注意源与目标必须是不同外设，
    ---    所以这里用 store_2 当机器输出、store_1 当目标）
    c:applyScan('chest_2', { { slot = 1, name = 'minecraft:flour', count = 7 } }, nil, os.epoch('utc'))
    reads, pushes = 0, {}
    engine:transferOut(spec, machineWith('store_2'), 3, 'tok-storage')
    check('a storage output container is extracted through the same snapshot path',
        reads >= 1 and #pushes == 1 and pushes[1].fromSlot == 1 and pushes[1].limit == 3,
        'reads=' .. tostring(reads) .. ' pushes=' .. tostring(#pushes))

    --- 6) machineRemaining：按快照统计（所有角色都可读 —— 不再有"恒 0"的特例）。
    ---    第 5 步从 chest_2 抽走了 3 个，所以这里应当剩 4 个（记账与快照一致）。
    reads, pushes = 0, {}
    local remaining = engine:machineRemaining(spec, machineWith('store_2'))
    check('machineRemaining counts what the snapshot holds (7 - 3 = 4 after the extraction)',
        remaining == 4 and reads >= 1,
        'remaining=' .. tostring(remaining) .. ' reads=' .. tostring(reads))
end

-- ===================== 中继回声过滤（自己发的帧必须丢掉）=====================
-- 现场：主控刷屏 `request: full_sync_start / incremental_update / log` —— 那是主控**收到了自己
-- 发出的帧**（itty 房间广播包含发送者）。这些帧被当成客户端请求后，主控会回一条同 action 的响应；
-- 网页先按 action 分派，于是把它当成真的 full_sync_start/full_sync_end ⇒ 随机开始/结束一次
-- "全量缓冲" ⇒ 对缓冲里的类别 store.clear() 再只放回有变化的条目 ⇒ worker 卡片"消失又出现"。
-- 处理方式与服务端/worker 的既有约定一致（IFMWorker.lua：`message.from == computerId` 就 return）：
-- 按发送者 uid 丢掉自己的帧，不做任何自定义协议扩展。
do
    local p = Protocol.new({ Util = { now = os.epoch }, log = function() end,
        url = 'wss://relay/room', collect = function() return {} end })
    local sent, requests = {}, {}
    --- 注意调用约定：协议层是 `pcall(self.onRequest, payload)`（没有 self）、
    --- 而日志是 `self.log(format, ...)`（同样没有 self）—— 桩的参数顺序要和它们一致。
    p.onRequest = function(payload)
        requests[#requests + 1] = payload
        return { handled = payload.action }
    end
    p:onEvent('websocket_success', 'wss://relay/room', {
        close = function() end,
        --- 真实 CC:T 句柄是 `socket.send(json)`（点号调用，没有 self）—— 桩也要这样收参数
        send = function(json) sent[#sent + 1] = json end,
    })
    check('a freshly opened socket knows no uid yet (nothing can be filtered)', p.selfUid == nil)
    p.selfUid = 'uid-master'

    --- 中继的 JSON 桩在测试里换成"直接收表"（本用例只关心过滤逻辑，不关心编解码）
    local realUnserialize = textutils.unserializeJSON
    textutils.unserializeJSON = function(raw) return raw end

    --- ① 自己的回声：丢掉 —— 不进 onRequest、不回响应、计数进 recvSelf
    p:handleMessage({ type = 'message', uid = 'uid-master', message = { action = 'full_sync_start' } })
    check('our own echoed frame is dropped (no request, no reply)',
        #requests == 0 and #sent == 0 and (p.stats.recvSelf or 0) == 1 and p.selfEchoLogged == true,
        'requests=' .. tostring(#requests) .. ' sent=' .. tostring(#sent) ..
            ' recvSelf=' .. tostring(p.stats.recvSelf))

    --- ② 别人的帧（浏览器请求）：照常处理并回响应
    p:handleMessage({ type = 'message', uid = 'uid-browser', message = { action = 'ping', id = 7 } })
    check('a frame from another member is still handled normally',
        #requests == 1 and requests[1].action == 'ping' and #sent == 1 and (p.stats.recvSelf or 0) == 1,
        'requests=' .. tostring(#requests) .. ' sent=' .. tostring(#sent))

    --- ③ 没有 uid 的帧：不知道是谁 → 不误杀（按普通请求处理），但必须留一行日志
    ---（这正是"字段名对不上 / 还没收到自己的 join"时唯一能看见线索的地方）
    local logged = {}
    local function capture(fmt, ...)
        logged[#logged + 1] = tostring(fmt)
    end
    --- 注意：分级日志是"可调用的表"（log.warn / log.error），测试桩也要照这个形状给
    p.log = setmetatable({ warn = capture, error = capture },
        { __call = function(_, ...) return capture(...) end })
    local function warningCount()
        local n = 0
        for _, line in ipairs(logged) do
            if line:find('could not recognise', 1, true) ~= nil then
                n = n + 1
            end
        end
        return n
    end
    p:handleMessage({ type = 'message', message = { action = 'incremental_update' } })
    check('a server-only action without a usable uid is warned about (with the frame fields)',
        #requests == 2 and p.unknownEchoWarned == true and warningCount() == 1,
        table.concat(logged, ' | '))

    --- ④ 回声提示每连接只出现一次（新连接时由 onSocketOpened 重置）
    local before = #logged
    p:handleMessage({ type = 'message', uid = 'uid-master', message = { action = 'log' } })
    p:handleMessage({ type = 'message', uid = 'uid-master', message = { action = 'log' } })
    check('the echo hint is logged once per connection (no log spam)',
        warningCount() == 1 and (p.stats.recvSelf or 0) == 3,
        'logged=' .. tostring(#logged) .. ' warnings=' .. tostring(warningCount()))
    --- 真的换了一条连接（旧句柄已经失效）：提示要能再出现一次
    p.ws = nil
    p.connected = false
    p:onEvent('websocket_success', 'wss://relay/room', {
        close = function() end,
        send = function() end,
    })
    check('a new connection resets the once-per-connection hints',
        p.selfEchoLogged == false and p.unknownEchoWarned == false)

    textutils.unserializeJSON = realUnserialize
end

-- ===================== 一轮调度：轮转到底（用户第 5 项）=====================
-- 现场：挂了 27 个存储容器，网页上的并发却只有个位数。原因是权重被当成了"每轮最多几步"的预算
-- （权重 0.1 → 一轮只轮得到 3 条），27 个容器要好几轮才派得完。
-- 现在的语义（用户原话）：一次调度**不断轮转**地派发，直到"所有队列都已空"或"所有 worker
-- 负载已满（启用主控分担任务时再加上主控本机池的负载）"为止 —— 权重只决定顺序，不限制总数。
do
    local d = newDispatcher({ workers = 5, idle = 5, idleQuery = 5, idleMove = 5 })
    local scanServed, moveServed = 0, 0
    d:addQueue('storageScan', {
        needs = 'query', policy = 'retry', slice = 0.1,
        run = function() scanServed = scanServed + 1 return false end,
    })
    d:addQueue('delivery', {
        needs = 'move', policy = 'retry', slice = 0.1,
        run = function() moveServed = moveServed + 1 return false end,
    })
    for i = 1, 27 do
        d:enqueue('storageScan', { key = 'chest_' .. i, name = 'chest_' .. i })
    end
    for i = 1, 5 do
        d:enqueue('delivery', { key = 'd' .. i })
    end
    local steps = d:tick(os.epoch('utc'))
    check('one round drains every queue until the queues are empty (weights only order them)',
        scanServed == 27 and moveServed == 5 and steps == 32,
        'scan=' .. tostring(scanServed) .. ' move=' .. tostring(moveServed) .. ' steps=' .. tostring(steps))

    --- worker 全满（没有空闲 worker）→ 这一轮什么也不派（mode=paused 由 tick 直接返回 0）
    local full = newDispatcher({ workers = 2, idle = 0, idleQuery = 0, idleMove = 0 })
    local served = 0
    full:addQueue('storageScan', {
        needs = 'query', policy = 'retry', slice = 0.1,
        run = function() served = served + 1 return false end,
    })
    for i = 1, 10 do
        full:enqueue('storageScan', { key = 'c' .. i })
    end
    local fullSteps = full:tick(os.epoch('utc'))
    check('while every worker is full the round dispatches nothing',
        served == 0 and fullSteps == 0, 'served=' .. tostring(served) .. ' steps=' .. tostring(fullSteps))

    --- 本机队列（needs=none）保留旧的 32 步预算：按权重折算（0.5 → ceil(0.5*32) = 16）
    local localQ = newDispatcher({ workers = 1, idle = 1 })
    local localServed = 0
    localQ:addQueue('process', {
        needs = 'none', policy = 'retry', slice = 0.5,
        run = function() localServed = localServed + 1 return false end,
    })
    for i = 1, 100 do
        localQ:enqueue('process', { key = 'p' .. i })
    end
    localQ:tick(os.epoch('utc'))
    check('local queues keep the 32-step budget per tick (weight-scaled, as before)',
        localServed == 16, 'served=' .. tostring(localServed))
end

-- ===================== 出站打包：多条任务 = 一次 modem 调用（用户第 5 项）=====================
-- 为什么重要：CC:T 的事件队列超过 256 条就开始丢事件。以前每条查询/搬运都是一次 modem send，
-- 27 个容器 = 27 个 modem_message 事件/轮，很容易堆到上限（扫描结果时有时无）。
-- 现在同一 tick 内发给同一台 worker 的任务合并成一条 { op = "jobs", jobs = {...} }。
do
    local transmits = {}
    local fakeModem = { open = function() end, isOpen = function() return true end, close = function() end }
    local t = TransferModule.new({
        log = function() end,
        Modems = {
            find = function() return fakeModem, 'back' end,
            asModem = function() return fakeModem, 'back' end,
            transmit = function(_, _, message) transmits[#transmits + 1] = message return true end,
        },
    })
    t:setContext({ version = 'test' })
    t.workers[7] = { id = 7, lastSeen = os.epoch('utc'), stateAt = os.epoch('utc'), slots = 64,
        inFlight = 0, caps = { move = true, query = true }, busy = false }
    t.modem = fakeModem
    t.listenReady = true
    t.channel = 41000
    for i = 1, 4 do
        t:queueTo(t.workers[7], { proto = 'ifm_transfer', op = 'query', id = i, container = 'chest_' .. i })
    end
    local envelopes, batched = t:flushOutbox()
    local sentJobs = transmits[1] and transmits[1].jobs
    check('four tasks for one worker leave as ONE modem message (batched jobs envelope)',
        #transmits == 1 and envelopes == 1 and batched == 4 and
            transmits[1].op == 'jobs' and sentJobs ~= nil and #sentJobs == 4 and
            sentJobs[1].op == 'query',
        'transmits=' .. tostring(#transmits) .. ' envelopes=' .. tostring(envelopes) ..
            ' batched=' .. tostring(batched))

    --- 用户第 1 项：即使只有 1 条任务也走**同一个信封**（单条 job/query/detail 的单发格式已删除）
    transmits = {}
    t:queueTo(t.workers[7], { proto = 'ifm_transfer', op = 'query', id = 99, container = 'chest_9' })
    local lone, loneBatched = t:flushOutbox()
    check('a lone task is packed into a jobs envelope too (no single-task format any more)',
        #transmits == 1 and lone == 1 and loneBatched == 1 and transmits[1].op == 'jobs' and
            #(transmits[1].jobs or {}) == 1 and transmits[1].jobs[1].op == 'query',
        'transmits=' .. tostring(#transmits) .. ' op=' .. tostring(transmits[1] and transmits[1].op))
end

-- ===================== 发货合并（用户第 5 项）=====================
-- 同一目标容器 + 同一资源的多次发送会合并成一条（remaining/total 相加）—— 网页上那条
-- "381 变成 762"的记录就是两次 381 并起来的。网页据此显示"剩余/总共"（ifm-resources.js）。
do
    local Recipe = RecipeModule
    local list = {}
    local seq = 0
    local engine = Recipe.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Store = { list = function() return {} end, findContainer = function() return nil end },
        Cache = {
            deliveries = function() return list end,
            addDelivery = function(_, entry)
                seq = seq + 1
                entry.id = seq
                list[#list + 1] = entry
                return entry
            end,
            markDirty = function() end,
        },
        log = function() end,
    })
    local first = engine:addDelivery({ kind = 'item', name = 'minecraft:iron_nugget',
        container = 'out_1', remaining = 381, total = 381 })
    check('the first delivery keeps the requested amount',
        first.id == 1 and first.remaining == 381 and first.total == 381,
        'remaining=' .. tostring(first.remaining) .. ' total=' .. tostring(first.total))

    local merged = engine:addDelivery({ kind = 'item', name = 'minecraft:iron_nugget',
        container = 'out_1', remaining = 381, total = 381 })
    check('a repeated send to the same container merges into one entry (remaining/total add up)',
        #list == 1 and merged.id == 1 and merged.remaining == 762 and merged.total == 762,
        'entries=' .. tostring(#list) .. ' remaining=' .. tostring(merged.remaining) ..
            ' total=' .. tostring(merged.total))

    local other = engine:addDelivery({ kind = 'item', name = 'minecraft:iron_nugget',
        container = 'out_2', remaining = 10, total = 10 })
    check('the same resource for another target container is a separate delivery',
        #list == 2 and other.id == 2 and other.remaining == 10,
        'entries=' .. tostring(#list) .. ' id=' .. tostring(other.id))
end


-- ===================== 输入容器入库（用户第 7 项）=====================
-- 现场问题："输入容器中的物品始终没有被取走"。根因在 IFMMaster：扫描之后生成后续任务
-- （输入容器 → 入库）的 afterScan 只在"主控本机扫描"那条路径上被调用，worker 代扫回报时漏掉了
-- —— 有 worker 的现场扫描基本都交给 worker，于是 drainInputContainers 从来不被触发。
-- 这里钉住 drainInputContainers 本身的行为（触发时机由 IFMMaster 的 onQueryResult 修）。
do
    local Recipe = RecipeModule
    local function newDrain(opts)
        opts = opts or {}
        local pushes = {}
        local stacksBySource = opts.stacks or {
            in_1 = { { slot = 3, name = 'minecraft:iron_nugget', count = 64 } },
        }
        local c = Containers.new({
            Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
            Peripherals = {
                exists = function() return true end,
                isInventory = function() return true end,
                isFluid = function() return false end,
                isTurtle = function() return false end,
                names = function() return {} end,
                invalidate = function() end,
                wrap = function() return {} end,
            },
            Store = { list = function() return {} end, findContainer = function() return nil end },
            Filter = { specMatches = function() return true end },
            log = function() end,
        })
        c.byRole = function(_, role, kind)
            if kind ~= 'item' then
                return {}
            end
            if role == 'input' then
                return opts.inputs or { 'in_1' }
            end
            if role == 'storage' then
                return opts.storages or { 'store_1' }
            end
            return {}
        end
        c.stacks = function(_, name) return stacksBySource[name] or {} end
        c.orderStacks = function(_, list) return list end
        c.peripheralOf = function(_, name) return name end
        c.pushItem = function(_, from, slot, amount, to, toSlot, mode, queue)
            pushes[#pushes + 1] = {
                from = from, slot = slot, amount = amount, to = to, toSlot = toSlot,
                mode = mode, queue = queue,
            }
            if opts.pending then
                return nil, 'pending'
            end
            return amount, nil
        end
        c.invalidate = function() end
        local engine = Recipe.new({
            Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
            Store = { list = function() return {} end, findContainer = function() return nil end },
            Cache = { markDirty = function() end },
            Containers = c,
            log = function() end,
        })
        return engine, pushes
    end

    --- 1) 有货：搬到存储容器，队列 inventoryIn（源槽位与数量原样传下去）
    local engine, pushes = newDrain()
    local moved = engine:drainInputContainers(os.epoch('utc'))
    check('an input container is drained into storage via the inventoryIn queue',
        moved == 64 and #pushes == 1 and pushes[1].to == 'store_1' and pushes[1].queue == 'inventoryIn' and
            pushes[1].from == 'in_1' and pushes[1].slot == 3 and pushes[1].amount == 64,
        'moved=' .. tostring(moved) .. ' pushes=' .. tostring(#pushes) ..
            ' to=' .. tostring(pushes[1] and pushes[1].to) .. ' queue=' .. tostring(pushes[1] and pushes[1].queue))

    --- 2) 没有存储容器可放：什么都不做（不提交任务）
    local engine2, pushes2 = newDrain({ storages = {} })
    check('with no storage container the input containers are left alone',
        engine2:drainInputContainers(os.epoch('utc')) == 0 and #pushes2 == 0,
        'pushes=' .. tostring(#pushes2))

    --- 3) 输入容器是空的：不提交任务
    local engine3, pushes3 = newDrain({ stacks = { in_1 = {} } })
    check('an empty input container submits nothing',
        engine3:drainInputContainers(os.epoch('utc')) == 0 and #pushes3 == 0, 'pushes=' .. tostring(#pushes3))

    --- 4) 已经交给 worker（pending）：本轮停下，不重复提交
    local engine4, pushes4 = newDrain({ pending = true })
    check('a move handed to a worker stops this round (no duplicate submission)',
        engine4:drainInputContainers(os.epoch('utc')) == 0 and #pushes4 == 1, 'pushes=' .. tostring(#pushes4))

    --- 5) onlyPeripheral：只处理"刚扫到的那个输入容器"
    local engine5, pushes5 = newDrain({
        inputs = { 'in_1', 'in_2' },
        stacks = {
            in_1 = { { slot = 1, name = 'minecraft:iron_nugget', count = 5 } },
            in_2 = { { slot = 1, name = 'minecraft:gold_nugget', count = 7 } },
        },
    })
    engine5:drainInputContainers(os.epoch('utc'), 'in_2')
    check('onlyPeripheral drains just the container that was scanned',
        #pushes5 == 1 and pushes5[1].from == 'in_2' and pushes5[1].amount == 7,
        'pushes=' .. tostring(#pushes5) .. ' from=' .. tostring(pushes5[1] and pushes5[1].from))
end


-- ===================== 抽象操作 / 抽象流程（用户第 3 项）=====================
-- 旧概念"虚操作"（元素 kind = "virtual"）已移除。现在的规则：把**物品/流体**元素的注册名写成
-- "abstract" 就是一条抽象操作；含抽象操作的流程是抽象流程 —— 可以保存、可以作为"流程设置复制"的
-- 来源，但不能执行 / 不能被选作上游 / 不能下单合成（引擎与主控都按这套判定）。
do
    local Store = StoreModule
    local Recipe = RecipeModule

    check('an item/fluid element whose id is "abstract" is an abstract operation',
        Store.elementIsAbstract({ kind = 'item', id = 'abstract' }) == true and
            Store.elementIsAbstract({ kind = 'fluid', id = 'abstract' }) == true)
    check('real resources, filters and placeholders are never abstract operations',
        Store.elementIsAbstract({ kind = 'item', id = 'minecraft:iron_ingot' }) == false and
            Store.elementIsAbstract({ kind = 'filter', id = 'abstract' }) == false and
            Store.elementIsAbstract({ kind = 'placeholder', name = 'abstract', item = 'a:b' }) == false and
            Store.elementIsAbstract(nil) == false)
    check('a process is abstract when any input/output element is an abstract operation',
        Store.processIsAbstract({ inputs = { { kind = 'item', id = 'abstract' } }, outputs = {} }) == true and
            Store.processIsAbstract({ inputs = {}, outputs = { { kind = 'fluid', id = 'abstract' } } }) == true and
            Store.processIsAbstract({ inputs = { { kind = 'item', id = 'a:b' } },
                outputs = { { kind = 'item', id = 'a:b' } } }) == false and
            Store.processIsAbstract(nil) == false)

    --- 归一化 / 校验：abstract 是合法注册名（能保存），旧的 virtual 元素类型已经不认识
    --- 注意：store.lua 里的 Util 是**点调用**（Util.num(x, default)），所以桩不能用 (self, value) 形态
    local UtilStub = {
        num = function(value, fallback)
            local number = tonumber(value)
            if number == nil then
                return fallback
            end
            return number
        end,
        int = function(value, fallback) return math.floor(tonumber(value) or fallback) end,
        clamp = function(value, low, high) return math.max(low, math.min(high, value)) end,
    }
    local store = setmetatable({ Util = UtilStub, data = {}, virtual = {} }, { __index = Store })
    local normalized = store:normalizeElement({ kind = 'item', id = 'abstract', count = 3, max = 1 }, true)
    check('an abstract operation survives normalization (it can be saved)',
        normalized ~= nil and normalized.kind == 'item' and normalized.id == 'abstract',
        tostring(normalized and normalized.id))
    check('the removed "virtual" element kind is no longer accepted',
        store:normalizeElement({ kind = 'virtual', name = 'x' }, true) == nil and
            store:validateElement({ kind = 'virtual', name = 'x' }, true, 1, 'Input') == false)
    check('an abstract input element passes validation (saving is allowed)',
        store:validateElement({ kind = 'item', id = 'abstract', count = 1 }, false, 1, 'Input') == true)

    --- 引擎：抽象流程不能当上游、不能下单、也不会被列进 producers
    local processes = {
        { name = 'abstract_flow', machineType = 't', maxMultiplier = 1,
            inputs = { { kind = 'item', id = 'abstract', count = 1 } },
            outputs = { { kind = 'item', id = 'minecraft:iron_ingot', min = 1, max = 1 } } },
        { name = 'real_flow', machineType = 't', maxMultiplier = 1, inputs = {}, outputs = {
            { kind = 'item', id = 'minecraft:iron_ingot', min = 1, max = 1 } } },
    }
    local engine = Recipe.new({
        Util = UtilStub,
        Store = {
            list = function() return processes end,
            get = function(_, name)
                for _, item in ipairs(processes) do
                    if item.name == name then
                        return item
                    end
                end
                return nil
            end,
            processIsAbstract = Store.processIsAbstract,
        },
        Cache = { markDirty = function() end, proc = function() return {} end },
        Containers = {},
        log = function() end,
    })
    check('an abstract process is never listed as a producer',
        table.concat(engine:producers('item', 'minecraft:iron_ingot'), ',') == 'real_flow',
        table.concat(engine:producers('item', 'minecraft:iron_ingot'), ','))
    check('an abstract process is never an upstream candidate',
        #engine:upstreamCandidates('other_flow', { kind = 'item', id = 'minecraft:iron_ingot' }) == 1)
    local okStart, startInfo = engine:start('abstract_flow', 1)
    check('starting an abstract process is refused with a reason',
        okStart == false and type(startInfo) == 'string' and #startInfo > 0, tostring(startInfo))
end

-- ===================== 强制删除缺失定义时摘掉机器里的引用（用户第 1/3 项）=====================
-- 现场问题：两个缺失外设的「一键删除」只删掉一个、再点一下提示 already gone、刷新网页才恢复。
-- 前端已改成"并行发请求 + 乐观移除 + 无论成败都同步一次"；服务端这一侧还要**把机器里指向它的
-- 引用摘掉** —— 否则机器卡片里那张「缺失的外设卡片」一直挂着，看起来就是"没删掉"。
do
    local Store = StoreModule
    local UtilStub = {
        trim = function(text) return tostring(text or ""):match("^%s*(.-)%s*$") end,
        kindOfDef = function(def) return def and def.kind or "item" end,
    }
    local function newStore()
        return setmetatable({
            Util = UtilStub,
            log = function() end,
            file = { markDirty = function() end },
            data = {
                containers = {
                    [Store.containerKey("item", "basin")] = { name = "basin", peripheral = "create:basin",
                        kind = "item", role = "storage" },
                },
                signals = {
                    lever_a = { name = "lever_a", peripheral = "minecraft:lever" },
                },
                machines = {
                    mixer = { name = "mixer", type = "t", itemInputs = { "basin" }, itemOutputs = {},
                        fluidInputs = {}, fluidOutputs = {}, signals = { "lever_a" } },
                },
                filters = {}, machineTypes = {}, processes = {}, schedules = {},
            },
            virtual = {},
        }, { __index = Store })
    end

    local store = newStore()
    local ok, err = store:delete("containers", "basin", "item", {})
    check('a referenced container is still refused without force', ok == false and type(err) == "string",
        tostring(err))
    check('the refused delete keeps both the definition and the machine reference',
        store.data.containers[Store.containerKey("item", "basin")] ~= nil and
            #store.data.machines.mixer.itemInputs == 1)

    local forced = newStore()
    local okForced = forced:delete("containers", "basin", "item", { force = true })
    check('force delete removes the container definition',
        okForced == true and forced.data.containers[Store.containerKey("item", "basin")] == nil)
    check('force delete also clears the machine reference (the missing card disappears for good)',
        #forced.data.machines.mixer.itemInputs == 0, tostring(#forced.data.machines.mixer.itemInputs))

    local signalStore = newStore()
    check('force delete of a signal clears it from the machine signal list',
        signalStore:delete("signals", "lever_a", nil, { force = true }) == true and
            #signalStore.data.machines.mixer.signals == 0,
        tostring(#signalStore.data.machines.mixer.signals))

    --- 只摘对得上种类的那一份：同名的流体引用不动（物品容器与流体容器允许同名）
    local kindStore = newStore()
    kindStore.data.machines.mixer.fluidOutputs = { "basin" }
    kindStore:delete("containers", "basin", "item", { force = true })
    check('only the matching container kind is purged (a same-named fluid reference stays)',
        #kindStore.data.machines.mixer.itemInputs == 0 and #kindStore.data.machines.mixer.fluidOutputs == 1,
        tostring(#kindStore.data.machines.mixer.fluidOutputs))

    --- 没有引用时（外设自己掉线）删除照旧成功，且不碰任何机器
    local cleanStore = newStore()
    cleanStore.data.machines.mixer.itemInputs = {}
    check('deleting an unreferenced definition still works and touches no machine',
        cleanStore:delete("containers", "basin", "item", {}) == true and
            #cleanStore.data.machines.mixer.itemInputs == 0)
end

-- ===================== 合成频道（用户第 4 项）=====================
-- 现场问题：材料送完后海龟从不合成、终端也没有任何"收到合成请求"的文本。两个独立 bug：
--   ① Transfer:sendCrafter 写成 self:send(message) —— chan 省略 = **worker 频道**（41000），
--      合成器（听 MACHINE/CRAFTER 频道 41001）一条都收不到，主控这边却返回 true、日志照打；
--   ② IFMCrafter.lua 的 os.pullEvent() 少接了两个返回值，param4 拿到的是 replyChannel 而不是
--      message，于是**所有**主控消息都被 type(message) ~= "table" 丢掉（已改成与 IFMWorker 一致，
--      并加了入口脚本语法检查，见 run_module_tests.js）。
do
    local sent = {}
    local fakeModem = { open = function() end, isOpen = function() return true end, close = function() end }
    local t = TransferModule.new({
        log = function() end,
        Modems = {
            find = function() return fakeModem, 'back' end,
            asModem = function() return fakeModem, 'back' end,
            transmit = function(_, chan, message)
                sent[#sent + 1] = { chan = chan, message = message }
                return true
            end,
        },
    })
    t:setContext({ version = 'test' })
    t.modem = fakeModem
    t.listenReady = true
    t.channel = TransferModule.CHANNEL
    t.crafterChannel = TransferModule.CRAFTER_CHANNEL
    t.crafters[5] = { id = 5, name = 'turtle_1', lastSeen = os.epoch('utc'), busy = false,
        version = 'test', jobs = 0 }

    check('a craft request goes out on the crafter channel, not the worker channel',
        t:sendCrafter({ proto = 'ifm_crafter', op = 'craft', target = 5 }) == true and
            #sent == 1 and sent[1].chan == TransferModule.CRAFTER_CHANNEL and
            sent[1].chan ~= t.channel,
        'chan=' .. tostring(sent[1] and sent[1].chan) .. ' worker=' .. tostring(t.channel))

    local okCraft, status = pcall(function() return t:requestCraft({ crafter = 'turtle_1', key = 'k' }) end)
    local craftFrame = sent[#sent]
    check('requestCraft reaches the turtle on the crafter channel',
        okCraft and status == 'sent' and craftFrame.chan == TransferModule.CRAFTER_CHANNEL and
            craftFrame.message.op == 'craft' and craftFrame.message.target == 5,
        'status=' .. tostring(status) .. ' chan=' .. tostring(craftFrame and craftFrame.chan))

    --- 对照：worker 作业仍然走 worker 频道（别把这次修复变成"全部走合成频道"）
    t:send({ proto = 'ifm_transfer', op = 'query' })
    check('worker messages still go out on the worker channel',
        sent[#sent].chan == t.channel and sent[#sent].message.proto == 'ifm_transfer',
        'chan=' .. tostring(sent[#sent].chan))

    --- 用户第 2/4 项：海龟上报的物品栏会写进**内容快照** —— 通过 onCrafterInventory 回调
    --- 交给主控（IFMMaster → Containers:applyScan），于是抽取/推送和海龟以外一样"按快照决策"。
    local snapshots = {}
    t.onCrafterInventory = function(name, items, at, size)
        snapshots[#snapshots + 1] = { name = name, items = items, at = at, size = size }
    end
    t:onCrafterMessage({
        proto = 'ifm_crafter', op = 'inventory', from = 5, name = 'turtle_1', at = 111,
        size = 16, items = { { slot = 6, name = 'minecraft:iron_ingot', count = 3 } },
    })
    check('a crafter inventory report is handed to the snapshot writer (name + items + size)',
        #snapshots == 1 and snapshots[1].name == 'turtle_1' and snapshots[1].size == 16 and
            snapshots[1].items[1].slot == 6 and snapshots[1].at == 111,
        'n=' .. tostring(#snapshots) .. ' name=' .. tostring(snapshots[1] and snapshots[1].name))

    --- 海龟快照靠它自报维持新鲜：超过 1.5s 就要一份新的（同一台限流 2 秒）
    t.crafters[5].inventory = { at = os.epoch('utc') - 5000, items = {} }
    t.crafters[5].inventoryAskedAt = nil
    local askedBefore = #sent
    local asked = t:refreshCrafterReports(os.epoch('utc'))
    check('a stale crafter report triggers exactly one inventory_request (rate limited)',
        asked == 1 and #sent == askedBefore + 1 and sent[#sent].message.op == 'inventory_request' and
            sent[#sent].chan == TransferModule.CRAFTER_CHANNEL and
            t:refreshCrafterReports(os.epoch('utc')) == 0,
        'asked=' .. tostring(asked) .. ' op=' .. tostring(sent[#sent] and sent[#sent].message.op))
end

-- ===================== 海龟：上报 → 内容快照 → 按快照抽取（用户第 2/3 项）=====================
-- 现场报错：Move dropped (source empty) (turtle_5 -> minecraft:chest_109): bad argument #2
-- (number expected, got nil) —— pullItems 的**源槽位是必填的**，而海龟的产物在哪个槽只有它自己知道。
-- 规则（1.9.0）：海龟上报的物品栏就是它的**内容快照**（Containers:applyScan ← IFMMaster 的
-- transfer.onCrafterInventory）；抽取按快照选槽位。**拿不到快照就什么都不做** —— 盲抽已删除。
do
    local defs = {
        { name = 'turtle_5', peripheral = 'turtle_5', kind = 'item', role = 'interaction' },
        { name = 'chest_109', peripheral = 'chest_109', kind = 'item', role = 'storage' },
        { name = 'out_3', peripheral = 'out_3', kind = 'item', role = 'output' },
    }
    local PeripheralsStub = {
        exists = function() return true end,
        --- 海龟没有 inventory 外设（用户规则）；输出容器是真 inventory，但角色是 output（不可读）
        isInventory = function(_, name) return name ~= 'turtle_5' end,
        isFluid = function() return false end,
        isTurtle = function(_, name) return name == 'turtle_5' end,
        names = function() return {} end,
        invalidate = function() end,
        wrap = function() return {} end,
    }
    local StoreStub = {
        list = function() return defs end,
        findContainer = function(_, name)
            for _, def in ipairs(defs) do
                if def.name == name then
                    return def
                end
            end
            return nil
        end,
    }
    local c = Containers.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Peripherals = PeripheralsStub,
        Store = StoreStub,
        Filter = { specMatches = function() return true end },
        log = function() end,
    })
    local submitted = {}
    c.submitMove = function(_, record) submitted[#submitted + 1] = record end
    c.invalidate = function() end

    --- ① 还没有快照（海龟没上报过）：拒绝，给出可读原因（不猜槽位、不派活）
    local moved, reason = c:pushItem('turtle_5', nil, 4, 'chest_109', nil, nil, 'inventoryOut',
        { name = 'minecraft:iron_ingot' })
    check('a turtle pull before its first report is refused with a readable reason',
        moved == 0 and #submitted == 0 and #tostring(reason) > 0, tostring(reason))

    --- ② 上报到了（写进快照）：槽位从快照来、actor = "to"（对面容器 pullItems）、源槽位标脏
    c:applyScan('turtle_5', {
        { slot = 3, name = 'minecraft:iron_nugget', count = 9 },
        { slot = 7, name = 'minecraft:iron_ingot', count = 4 },
    }, nil, os.epoch('utc'), 16)
    local moved2, reason2 = c:pushItem('turtle_5', nil, 4, 'chest_109', nil, nil, 'inventoryOut',
        { name = 'minecraft:iron_ingot' })
    local record = submitted[#submitted]
    check('the slot comes from the turtle snapshot (the product slot, not the nugget slot)',
        moved2 == nil and reason2 == 'pending' and record ~= nil and record.fromIndex == 7 and
            record.actor == 'to', 'slot=' .. tostring(record and record.fromIndex))
    check('the item being pulled is remembered (needed when a pending move is resumed)',
        record ~= nil and record.item == 'minecraft:iron_ingot', tostring(record and record.item))
    check('the source slot is marked dirty before the pull (user item 3)',
        c:isDirtySlot('turtle_5', 7, false) == true)
    c:clearDirty(c:modelOf('turtle_5'), 7, false)

    --- ③ 真 inventory、但角色是 output 且同样没有快照：一视同仁地拒绝
    local moved3, reason3 = c:pushItem('out_3', nil, 4, 'chest_109', nil, nil, 'inventoryOut',
        { name = 'minecraft:iron_ingot' })
    check('an output container without a snapshot is refused as well',
        moved3 == 0 and #submitted == 1 and #tostring(reason3) > 0, tostring(reason3))
end

-- ===================== 输出 / 交互容器的推送：槽位与快照（用户第 2/3 项）=====================
-- 规则：
--   * 推送前**必须**先定出目标槽位（"同名 + 同 NBT 的槽"或"空槽"，且没有脏标记），
--     定不出来就失败（不派活、不交给游戏自己找）；
--   * 派活前 reserveIn 标脏；结算（settleMove）按**实际成功数**更新那个槽位的快照；
--   * 失败时**不允许**改成 toSlot = nil 兜底重试（那会搬进不知道哪一格，没法记账）。
do
    local defs = {
        { name = 'store_1', peripheral = 'chest_1', kind = 'item', role = 'storage' },
        { name = 'mill_1', peripheral = 'millstone_1', kind = 'item', role = 'interaction' },
        { name = 'out_1', peripheral = 'chute_1', kind = 'item', role = 'output' },
    }
    local submitted = {}
    local c = Containers.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Peripherals = {
            exists = function() return true end,
            isInventory = function() return true end,
            isFluid = function() return false end,
            isTurtle = function() return false end,
            names = function() return {} end,
            invalidate = function() end,
            wrap = function() return {} end,
        },
        Store = {
            list = function() return defs end,
            findContainer = function(_, name)
                for _, def in ipairs(defs) do
                    if def.name == name then return def end
                end
                return nil
            end,
        },
        Filter = { specMatches = function() return true end },
        log = function() end,
    })
    c.dispatch = {
        enqueue = function(_, _, record)
            submitted[#submitted + 1] = record
            return true
        end,
    }

    --- ① 源（storage）有快照、目标（interaction）**没有快照** ⇒ 拒绝（不猜槽位、不派活）
    c:applyScan('chest_1', { { slot = 1, name = 'minecraft:coal', count = 8 } }, nil, os.epoch('utc'))
    local _, why = c:pushItem('store_1', 1, 4, 'mill_1', nil, nil, 'inventoryIn')
    check('pushing into an interaction container without a snapshot is refused',
        why ~= 'pending' and #submitted == 0, tostring(why))

    --- ② 目标有快照（9 格、全空）⇒ 自动选一个空槽位，而且**派活前**就标脏
    c:applyScan('millstone_1', nil, nil, os.epoch('utc'), 9)
    local _, why2 = c:pushItem('store_1', 1, 4, 'mill_1', nil, nil, 'inventoryIn')
    local record = submitted[#submitted]
    check('the target slot comes from the snapshot and is marked dirty before the move',
        why2 == 'pending' and record ~= nil and tonumber(record.toIndex) ~= nil and
            record.targetNeedsSlot == true and c:isDirtySlot('millstone_1', record.toIndex, false) == true,
        'slot=' .. tostring(record and record.toIndex))

    --- ③ 结算：按**实际**成功数更新目标槽位快照（这里实际只搬了 2 个）
    c:settleMove(record, 2)
    local entry = c:modelOf('millstone_1').slots[record.toIndex]
    check('the target snapshot is updated with the amount that really moved',
        entry ~= nil and entry.name == 'minecraft:coal' and entry.count == 2,
        entry and ('name=' .. tostring(entry.name) .. ' count=' .. tostring(entry.count)))
    check('the dirty mark is released after settling',
        c:isDirtySlot('millstone_1', record.toIndex, false) == false)

    --- ④ 目标装满且没有同物品的槽 ⇒ 拒绝（绝不"交给游戏自己找一格"）
    local full = {}
    for slot = 1, 9 do
        full[#full + 1] = { slot = slot, name = 'minecraft:gravel', count = 64 }
    end
    c:applyScan('millstone_1', full, nil, os.epoch('utc'), 9)
    submitted = {}
    local _, why4 = c:pushItem('store_1', 1, 8, 'mill_1', nil, nil, 'inventoryIn')
    check('a full interaction container without a matching/empty slot is refused',
        why4 ~= 'pending' and #submitted == 0, tostring(why4))

    --- ⑤ 有同物品的槽 ⇒ 合并进去（同样要标脏）
    c:applyScan('millstone_1', {
        { slot = 1, name = 'minecraft:gravel', count = 64 },
        { slot = 2, name = 'minecraft:coal', count = 3 },
    }, nil, os.epoch('utc'), 9)
    local _, why5 = c:pushItem('store_1', 1, 8, 'mill_1', nil, nil, 'inventoryIn')
    local record5 = submitted[#submitted]
    check('a slot that already holds the same item is used (and marked dirty)',
        why5 == 'pending' and record5 ~= nil and record5.toIndex == 2 and
            c:isDirtySlot('millstone_1', 2, false) == true,
        'slot=' .. tostring(record5 and record5.toIndex))

    --- ⑥ 兜底重试禁用：输出 / 交互容器失败时不会再发一条 toSlot = nil 的请求
    local requests = {}
    c.transfer = {
        request = function(_, job)
            requests[#requests + 1] = job
            return 'done', 0, 'target full'
        end,
    }
    local function tryMove(targetNeedsSlot)
        requests = {}
        c:runItemMove({
            key = 'k' .. tostring(targetNeedsSlot), kind = 'item', action = 'push_item',
            from = 'chest_1', fromIndex = 1, to = 'chute_1', toIndex = 3,
            reserved = 2, limit = 2, actor = 'from', targetNeedsSlot = targetNeedsSlot,
            item = 'minecraft:coal',
        })
        return #requests, requests[1] and requests[1].toSlot
    end
    local countStrict, firstSlot = tryMove(true)
    check('a failing output target is not retried with toSlot = nil (no unknown slot)',
        countStrict == 1 and firstSlot == 3, 'requests=' .. tostring(countStrict))
    local countSlotless = tryMove(false)
    check('storage/input targets keep the old slotless retry (control)', countSlotless == 2)
    c.transfer = nil
end

-- ===================== 失败判定：按内容快照（盲源退避机制已随盲路径删除）=====================
-- 现场：海龟（当时不可读）的产物抽不出来，旧逻辑拿"空快照"判它没货 → 丢弃 → 流程每 tick 再生成
-- 一条同样的活 → 灌满 worker 的 64 个槽位。1.9.0 起海龟也有内容快照（它自己上报），
-- 于是"按快照判有没有货"是可靠的：来源空了就丢弃；还有货（只是这一轮没搬动）就重试剩余量。
do
    local logged = { warns = {}, infos = {}, errors = {} }
    --- 注意：容器模块会把普通函数桩包装成分级日志（见 containers.lua 的 levelLogger）——
    --- 桩里必须同时有 warn 与 error，才会被原样使用（否则 warn 会被丢掉）。
    local logStub = setmetatable({
        warn = function(fmt, ...) logged.warns[#logged.warns + 1] = string.format(fmt, ...) end,
        error = function(fmt, ...) logged.errors[#logged.errors + 1] = string.format(fmt, ...) end,
    }, {
        __call = function(_, fmt, ...) logged.infos[#logged.infos + 1] = string.format(fmt, ...) end,
    })
    local c = Containers.new({
        Util = { kindOfDef = function(def) return def and def.kind or 'item' end },
        Peripherals = {
            exists = function() return true end,
            isInventory = function() return true end,
            isFluid = function() return false end,
            isTurtle = function() return false end,
            names = function() return {} end,
            invalidate = function() end,
            wrap = function() return {} end,
        },
        Store = { list = function() return {} end, findContainer = function() return nil end },
        Filter = { specMatches = function() return true end },
        log = logStub,
    })
    local record = {
        key = 'blind-1', kind = 'item', from = 'turtle_5', fromIndex = 3, to = 'chest_109',
        reserved = 4, limit = 4, blindFrom = true,
    }
    c.moveInflight[record.key] = record
    c:applyScan('turtle_5', {}, nil, os.epoch('utc'), 16)     -- 快照：物品栏是空的
    c.runMoveTask = function() return 0, 'moved nothing' end

    --- 快照说源里确实没有东西了 → 失败即丢弃（不再有"没依据地退避重试"这套特例）
    local first = c:executeMove(record)
    check('a failed move whose source snapshot is empty is dropped, with a readable warning',
        first == 'drop' and #logged.warns == 1 and
            tostring(logged.warns[1]):find('source empty', 1, true) ~= nil,
        'result=' .. tostring(first) .. ' warn=' .. tostring(logged.warns[1]))
    check('the blind retry/backoff machinery is gone (no retryAfter is set)',
        record.retryAfter == nil and record.retries == nil,
        'retryAfter=' .. tostring(record.retryAfter) .. ' retries=' .. tostring(record.retries))

    --- 反例：快照里还有东西（只是这一轮没搬动，例如目标一时满了）→ 不丢弃，剩余量回队尾重试
    c:applyScan('turtle_5', { { slot = 3, name = 'minecraft:iron_ingot', count = 4 } }, nil,
        os.epoch('utc'), 16)
    local record2 = {
        key = 'retry-1', kind = 'item', from = 'turtle_5', fromIndex = 3, to = 'chest_109',
        reserved = 4, limit = 4,
    }
    c.moveInflight[record2.key] = record2
    c.runMoveTask = function() return 1, 'target busy' end
    local second = c:executeMove(record2)
    check('a partly finished move with items still in the snapshot is retried, not dropped',
        second == true and record2.reserved == 3 and record2.state == 'queued' and record2.retryAfter == nil,
        'result=' .. tostring(second) .. ' reserved=' .. tostring(record2.reserved) ..
            ' retryAfter=' .. tostring(record2.retryAfter))
    check('only the remaining amount is retried (reserved drops from 4 to 3)',
        #logged.warns == 1, 'warns=' .. tostring(#logged.warns))
end

-- ===================== worker 结果信封（用户第 3 项）=====================
-- worker 每 tick 把本 tick 结束的任务结果打包成一条 { op = "results", results = {...} }；
-- 主控必须把它逐条结算（这里是两条：一条 done、一条 error）。
do
    local fakeModem = { open = function() end, isOpen = function() return true end, close = function() end }
    --- 日志桩：warn 单独记下来（applyQueryResult 在 worker 报错时会 warn）。主控的 log 是
    --- Util.makeLogger 的产物：**既能直接调用**，又有 .warn / .error 字段 —— 这里照着做一个，
    --- 否则那条分支在测试里会直接崩掉（Lua 里函数不能被索引，所以得用带 __call 的表）。
    local logWarnings = {}
    local logStub = setmetatable({}, {
        __call = function() end,
        __index = function(_, key)
            if key == "warn" or key == "error" then
                return function(fmt, ...)
                    logWarnings[#logWarnings + 1] = string.format(fmt, ...)
                end
            end
            return nil
        end,
    })
    local t = TransferModule.new({
        log = logStub,
        Modems = {
            find = function() return fakeModem, 'back' end,
            asModem = function() return fakeModem, 'back' end,
            transmit = function() return true end,
        },
    })
    t:setContext({ version = 'test' })
    t.modem = fakeModem
    t.listenReady = true
    t.channel = TransferModule.CHANNEL

    local first = { id = 11, key = 'k11', state = 'pending', at = os.epoch('utc') }
    local second = { id = 12, key = 'k12', state = 'pending', at = os.epoch('utc') }
    t.jobs.k11 = first
    t.jobs.k12 = second
    t.jobById[11] = first
    t.jobById[12] = second

    t:onModemMessage('back', TransferModule.CHANNEL, 0, {
        proto = 'ifm_transfer', op = 'results', from = 7, version = 'test', slots = 64,
        results = {
            { op = 'done', id = 11, moved = 3 },
            { op = 'error', id = 12, moved = 0, error = 'target full' },
        },
    }, 0)
    check('the master settles every result inside one envelope',
        first.moved == 3 and first.state == 'done' and second.state == 'failed' and
            second.error == 'target full',
        'first=' .. tostring(first.state) .. '/' .. tostring(first.moved) ..
            ' second=' .. tostring(second.state) .. '/' .. tostring(second.error))

    --- 用户第 1 项（现场 bug：transfer.lua:1130 attempt to call global 'touch'）：
    --- 结果结算被抽成 applyQueryResult / applyDetailResult 之后，这些方法里不能直接引用
    --- onModemMessage 的局部闭包 —— 这里把信封里的**每一种**结果都真跑一遍：
    --- 查询（写缓存 + 通知主控）与详情（出队）都会经过 touchWorker，漏一个就是 nil 崩溃。
    t.queries = { [21] = { id = 21, key = 'scan:chest_1', worker = 7, at = os.epoch('utc') } }
    t.queryRunning['scan:chest_1'] = 21
    t.details = { [22] = { id = 22, worker = 7, samples = {} } }
    local seenKey, seenItems = nil, nil
    t.onQueryResult = function(_, key, message)
        seenKey = key
        seenItems = #(message.items or {})
    end
    t:onModemMessage('back', TransferModule.CHANNEL, 0, {
        proto = 'ifm_transfer', op = 'results', from = 7, version = 'test', slots = 64,
        results = {
            { op = 'query_result', id = 21, ok = true, container = 'chest_1', at = os.epoch('utc'),
                items = { { slot = 1, name = 'minecraft:coal', count = 3 } } },
            { op = 'detail_result', id = 22, ok = true, details = {} },
        },
    }, 0)
    check('a results envelope with a query_result is settled (no nil-global crash)',
        t.queryCache['scan:chest_1'] ~= nil and seenKey == 'scan:chest_1' and seenItems == 1 and
            t.queries[21] == nil and t.queryRunning['scan:chest_1'] == nil,
        'cached=' .. tostring(t.queryCache['scan:chest_1'] ~= nil) .. ' key=' .. tostring(seenKey) ..
            ' items=' .. tostring(seenItems))
    check('a results envelope with a detail_result is settled too',
        t.details[22] == nil, 'details=' .. tostring(t.details[22] and 1 or 0))

    --- 同一条结果走"单条直发"的老入口也要能结算（两个入口共用同一段逻辑）
    t.queries = { [23] = { id = 23, key = 'scan:chest_2', worker = 7, at = os.epoch('utc') } }
    t.queryRunning['scan:chest_2'] = 23
    t:onModemMessage('back', TransferModule.CHANNEL, 0, {
        proto = 'ifm_transfer', op = 'query_result', from = 7, version = 'test', slots = 64,
        id = 23, ok = true, container = 'chest_2', at = os.epoch('utc'), items = {},
    }, 0)
    check('a single query_result message is settled through the same method',
        t.queryCache['scan:chest_2'] ~= nil and t.queries[23] == nil,
        'cached=' .. tostring(t.queryCache['scan:chest_2'] ~= nil))

    --- 用户第 4 项（worker 显示大量"任务超时，已丢弃"）：
    --- worker 明确回报"那台外设不响应"（ok = false）时，主控必须**立刻**知道这条扫描结束了
    --- （onQueryDropped）—— 否则那个容器的扫描任务会一直挂在 inflight，直到 QUERY_TIMEOUT(10s)
    --- 才作废：扫描队列每秒空转、日志里只有超时，真正的原因（哪台外设）还看不到。
    local droppedKey, droppedReason = nil, nil
    t.onQueryDropped = function(key, reason)
        droppedKey = key
        droppedReason = reason
    end
    t.queries = { [24] = { id = 24, key = 'scan:chest_3', worker = 7, at = os.epoch('utc') } }
    t.queryRunning['scan:chest_3'] = 24
    t:onModemMessage('back', TransferModule.CHANNEL, 0, {
        proto = 'ifm_transfer', op = 'results', from = 7, version = 'test', slots = 64,
        results = {
            { op = 'query_result', id = 24, ok = false, error = 'peripheral chest_3 is not answering' },
        },
    }, 0)
    check('a failed query_result notifies the master right away (onQueryDropped)',
        droppedKey == 'scan:chest_3' and tostring(droppedReason):find('not answering', 1, true) ~= nil and
            t.queries[24] == nil and t.queryRunning['scan:chest_3'] == nil and
            t.queryCache['scan:chest_3'] == nil,
        'key=' .. tostring(droppedKey) .. ' reason=' .. tostring(droppedReason))
    check('the failed query is logged with its container key',
        #logWarnings > 0 and tostring(logWarnings[#logWarnings]):find('scan:chest_3', 1, true) ~= nil,
        'warnings=' .. tostring(#logWarnings) .. ' last=' .. tostring(logWarnings[#logWarnings]))
    t.onQueryDropped = nil
    t.onQueryResult = nil
end

print('')
print('info: dispatch + snapshot + protocol module tests finished (passed=' .. passed ..
    ', failed=' .. failed .. ')')


end
