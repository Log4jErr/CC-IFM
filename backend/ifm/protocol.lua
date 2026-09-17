-- IFM :: ifm/protocol.lua
-- WebSocket 通讯协议（参照 meweb 的实现）：
--   浏览器 -> 服务端：{ id, action, ...payload }
--   服务端 -> 浏览器：{ id, action, result }
--   服务端推送：{ action = "full_sync_start", categories = {...} }
--               { action = "incremental_update", count = n, changes = { [category] = {...} } }
--               { action = "full_sync_end", categories = {...} }   （全量发完了；网页据此一次性替换本地数据）
--   删除项带 _deleted = true；空闲时定期回 heartbeat。
-- 传输使用 itty.ws 中转：wss://itty.ws/c/<房间号>
-- 连接是**异步**的：http.websocketAsync 立刻返回，websocket_success / websocket_failure 事件
-- 在 Protocol:onEvent 里处理（同步的 http.websocket 会阻塞主循环，已弃用）。

local Protocol = {}
Protocol.__index = Protocol

local CATEGORY_ORDER = {
    "containers",
    "signals",
    "filters",
    "machineTypes",
    "machines",
    "processes",
    "peripherals",
    "missing",
    "resources",
    "runtime",
    "deliveries",
    "workers",
}

local KEY_FIELDS = {
    containers = { "name" },
    signals = { "name" },
    filters = { "name" },
    machineTypes = { "name" },
    machines = { "name" },
    processes = { "name" },
    peripherals = { "kind", "name" },
    missing = { "kind", "name" },
    resources = { "kind", "name" },
    runtime = { "name" },
    deliveries = { "id" },
    workers = { "id" },
}

local SCALAR_CATEGORIES = { status = true }

--- 推送间隔的自动放大倍数：下一次推送至少等 PUSH_COST_MULTIPLIER × 上次推送耗时，
--- 这样“扫描容器”最多占用这台计算机 ~1/3 的时间（超过就继续拉长间隔）。
local PUSH_COST_MULTIPLIER = 4

--- 异步连接的超时（毫秒）：http.websocketAsync 立刻返回，结果靠 websocket_success /
--- websocket_failure 事件送达。万一两个事件都没来（中继静默丢包），超过这个时间就
--- 允许再发一次连接请求 —— 不然“一直在连”的状态会被卡死。
local CONNECT_TIMEOUT_MS = 10000

local function keyOf(category, item)
    local fields = KEY_FIELDS[category]
    if not fields then
        return tostring(item)
    end
    local parts = {}
    for _, field in ipairs(fields) do
        parts[#parts + 1] = tostring(item[field])
    end
    return table.concat(parts, "/")
end

--- 递归比较两个值是否相同（用于增量比较，最大深度 6）
local function valuesEqual(a, b, depth)
    if a == b then
        return true
    end
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return false
    end
    depth = depth or 0
    if depth > 6 then
        return false
    end
    for k, v in pairs(a) do
        if not valuesEqual(v, b[k], depth + 1) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

--- 服务端不做任何编码转换：CC:T 不支持 unicode 字符串，非 ASCII 文本在 Lua 里没有意义，
--- 编码只会破坏原样存储。名称字段的 ASCII 转义（发送前）与还原（收到后）全部由浏览器端完成，
--- 见 index.html 的 OUTBOUND_TEXT_PATHS / CATEGORY_TEXT_PATHS / RESPONSE_TEXT_PATHS；
--- 服务端只做原样收发与存储（转义后的文本只是普通 ASCII 字符串）。

function Protocol.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Protocol)
    self.Util = opts.Util
    self.log = opts.log or function() end
    self.url = opts.url
    self.collect = opts.collect
    self.onRequest = opts.onRequest
    self.onConnect = opts.onConnect
    self.updateInterval = opts.updateInterval or 2
    --- 浏览器请求之后那次推送的最小间隔（毫秒）：一次推送要全量收集（扫描所有容器），
    --- 而浏览器会连着发心跳/请求（心跳每 5 秒一次）。设置最小间隔后，请求的响应照旧立即返回，
    --- 最新数据由随后的定时推送（updateInterval）补齐，避免“点一下按钮就重扫一遍容器”。
    self.minPushInterval = opts.minPushInterval or 400
    --- 上一次推送（收集 + 发送）花了多少毫秒：定时推送的间隔会按它自动放大（见 PUSH_COST_MULTIPLIER）。
    --- 实测：有线网络 / 远程外设上每个容器一次 list() ≈ 1 个服务器刻（50ms），
    --- 12 个容器就是 ~0.6s；固定 1 秒推送会把主循环压到 1s 以上。
    self.lastPushCost = 0
    self.reconnectInterval = opts.reconnectInterval or 5
    --- 浏览器心跳超时（毫秒）：超过这个时间没收到浏览器任何消息就重连中继。
    --- 注意别设太小：浏览器后台标签页的定时器会被节流（可能 1 分钟一次），
    --- 太小会导致服务端不停重连、把正在处理的请求响应一起丢掉（网页表现为“超时”）。
    self.clientTimeout = opts.clientTimeout or 40
    self.maxChunk = opts.maxChunk or 50
    --- 日志推送的分块大小（诊断报告可能很长，单条消息太大容易出问题）
    self.maxLogChunk = opts.maxLogChunk or 40
    self.ws = nil
    self.connected = false
    --- 是否有一次**异步**连接请求在飞（http.websocketAsync 已发出、还没等到 websocket_success/failure）
    self.connecting = false
    self.connectRequestedAt = 0
    self.clientActive = false
    self.needFullSync = true
    self.lastHeartbeat = 0
    self.lastPush = 0
    self.lastReconnect = 0
    self.selfUid = nil
    self.snapshot = {}
    self.pushCount = 0
    --- 日志推送：sentLogSeq 记录已经发给浏览器的最后一条日志序号
    self.sentLogSeq = 0
    self.logPending = false
    --- 连接不可用时只提示一次“消息被丢弃”，避免刷屏
    self.dropLogged = false
    --- 收发统计（诊断模式 perf 用）：消息数 / 字节数，按 action 汇总，
    --- 用来定位“哪个动作的包太大或太频繁”导致的运行缓慢。
    self.stats = {
        sentMessages = 0, sentBytes = 0, sentMax = 0,
        recvMessages = 0, recvBytes = 0, recvMax = 0,
        dropped = 0, failed = 0, encodeFailed = 0,
        pushes = 0, pushSkipped = 0, fullSyncs = 0, changedItems = 0,
        --- 异步连接：请求数 / 失败数 / 超时（没有结果事件）数 —— 中继不通时这几个数会持续增长
        connectRequests = 0, connectFailures = 0, connectTimeouts = 0,
        byAction = {},
        since = os.epoch("utc"),
    }
    return self
end

--- 取某个 action 的统计桶（消息数 / 总字节 / 单包最大字节）
local function statBucket(stats, prefix, action)
    local key = prefix .. ":" .. tostring(action or "?")
    local entry = stats.byAction[key]
    if not entry then
        entry = { count = 0, bytes = 0, max = 0 }
        stats.byAction[key] = entry
    end
    return entry
end

--- 收到一条新日志：标记待推送（真正的发送在 update / 客户端接入时进行）
function Protocol:onLog(text, seq)
    self.logPending = true
end

--- 把还没发过的服务端日志推给浏览器（浏览器会在控制台打印）
function Protocol:flushLogs()
    if not self.connected or not self.ws or not self.Util or not self.clientActive then
        return
    end
    local lines, lastSeq = self.Util.logSince(self.sentLogSeq or 0)
    if #lines == 0 then
        self.logPending = false
        return
    end
    -- 分块发送：诊断报告可能上百行，一条消息装不下
    local index = 1
    while index <= #lines do
        local finish = math.min(index + self.maxLogChunk - 1, #lines)
        local chunk = {}
        for i = index, finish do
            chunk[#chunk + 1] = lines[i]
        end
        if not self:send({ action = "log", lines = chunk, lastSeq = lastSeq }) then
            return
        end
        index = finish + 1
    end
    self.sentLogSeq = lastSeq
    self.logPending = false
end

--- 建立 WebSocket 连接（**异步**）
--- 以前这里用 http.websocket（同步阻塞）：中继不可达时每次重连都要等 CC:T 的 http 超时，
--- 期间主循环完全不 yield —— 性能调试里那条 `Slow protocol update: 860ms`（甚至几十秒）就是这么来的。
--- 现在改成 http.websocketAsync：立刻返回，连接结果由 websocket_success /
--- websocket_failure 事件送达（见 Protocol:onEvent / Protocol:onSocketOpened）。
function Protocol:connect()
    --- 先关掉可能还开着的旧连接（重连时会走到这里）
    self:closeSocket()
    if self.connecting then
        -- 已经有一个连接请求在飞：不重复发（结果事件回来之前不要叠加请求）
        return false
    end
    local ok, err = pcall(http.websocketAsync, self.url)
    if not ok then
        self.connected = false
        self.log("WebSocket connect request failed: %s", tostring(err))
        self.stats.connectFailures = self.stats.connectFailures + 1
        return false
    end
    self.connecting = true
    self.connectRequestedAt = os.epoch("utc")
    self.stats.connectRequests = self.stats.connectRequests + 1
    return true
end

--- websocket_success 事件：连接建立了，接管句柄
function Protocol:onSocketOpened(handle)
    self.connecting = false
    local kind = type(handle)
    if kind ~= "table" and kind ~= "userdata" then
        -- 事件里没有句柄（正常不会发生）：当作失败，下个周期重试
        self.connected = false
        self.log("WebSocket success event had no handle, will retry")
        return false
    end
    if self.ws then
        -- 已经有一个可用连接（例如连接超时后重发，随后迟到的成功事件）：把多出来的这个关掉，
        -- 保留正在用的那一个，避免句柄泄漏 / 消息重复。
        pcall(function()
            handle.close()
        end)
        return false
    end
    self.ws = handle
    self.connected = true
    self.needFullSync = true
    self.snapshot = {}
    self.dropLogged = false
    --- 新连接：日志从头补发（浏览器会看到接入前的最近日志）
    self.sentLogSeq = 0
    self.log("WebSocket connected: %s", self.url)
    if self.onConnect then
        pcall(self.onConnect)
    end
    return true
end

--- 发送 JSON
-- 不做任何编码转换：名称字段在浏览器端就已经是 ASCII 转义文本，服务端原样收发；
-- 服务端自己生成的中文提示/错误信息交给 CC:T 的 serializeJSON 处理（非 ASCII 会写成 JSON 转义）。
function Protocol:send(message)
    if not self.ws or not self.connected then
        -- 消息在这里被丢掉：连接不可用时（中继断开 / 发送异常）网页那边只会看到“超时”，
        -- 所以必须留一行日志，方便区分“服务端没执行”与“执行了但响应没发出去”。
        self.stats.dropped = self.stats.dropped + 1
        if not self.dropLogged then
            self.dropLogged = true
            self.log("Message dropped: websocket not connected (action=%s)", tostring(message and message.action))
        end
        return false
    end
    local ok, json = pcall(textutils.serializeJSON, message, { allow_repetitions = true })
    if not ok then
        self.stats.encodeFailed = self.stats.encodeFailed + 1
        self.log("JSON encode failed: %s", tostring(json))
        return false
    end
    -- 注意：1.5.0 起中继**永远**由主控自己连接（IFMWorker 不再代连），所以这里没有“转发给 worker”的分支
    local socket = self.ws
    local sent, err = pcall(function()
        -- 点号调用：send(message [, binary])，binary 必须是布尔值，不能传句柄自身
        socket.send(json)
    end)
    if not sent then
        self.stats.failed = self.stats.failed + 1
        self.log("Send failed: %s", tostring(err))
        self.connected = false
        return false
    end
    self:noteSent(message, #json)
    return true
end

--- 发送统计（本机 socket 与 worker 转发两条路径共用）
function Protocol:noteSent(message, bytes)
    self.pushCount = self.pushCount + 1
    local stats = self.stats
    bytes = tonumber(bytes) or 0
    stats.sentMessages = stats.sentMessages + 1
    stats.sentBytes = stats.sentBytes + bytes
    if bytes > stats.sentMax then
        stats.sentMax = bytes
    end
    local bucket = statBucket(stats, "send", message and message.action)
    bucket.count = bucket.count + 1
    bucket.bytes = bucket.bytes + bytes
    if bytes > bucket.max then
        bucket.max = bytes
    end
    if self.traceMessages then
        self.log("send %s: %d bytes", tostring(message and message.action), bytes)
    end
end

--- 关掉本机 socket（重连时用；connect / update 都会走到这里）
--- 注意：CC:T 的 websocket 句柄是“已绑定对象的一堆函数”（和 peripheral 一样），
--- 必须用点号调用 socket.close() / socket.send(msg)。写成 socket:close() 会把句柄自己
--- 当成第一个参数传进去，send 时就会报 “bad argument #2 (boolean expected, got string)”。
function Protocol:closeSocket()
    if not self.ws then
        return
    end
    local socket = self.ws
    self.ws = nil
    pcall(function()
        socket.close()
    end)
end

--- 计算某个类别的增量（needFullSync 时退化为全量）
function Protocol:diffCategory(category, newList)
    local fields = KEY_FIELDS[category]
    local changes = {}
    if self.needFullSync or type(self.snapshot[category]) ~= "table" then
        for _, item in ipairs(newList) do
            changes[#changes + 1] = item
        end
        self.snapshot[category] = newList
        return changes
    end
    local previousMap = {}
    for _, item in ipairs(self.snapshot[category]) do
        previousMap[keyOf(category, item)] = item
    end
    local seen = {}
    for _, item in ipairs(newList) do
        local itemKey = keyOf(category, item)
        seen[itemKey] = true
        local previous = previousMap[itemKey]
        if previous == nil or not valuesEqual(previous, item) then
            changes[#changes + 1] = item
        end
    end
    for itemKey, previous in pairs(previousMap) do
        if not seen[itemKey] then
            local tombstone = { _deleted = true }
            for _, field in ipairs(fields or {}) do
                tombstone[field] = previous[field]
            end
            changes[#changes + 1] = tombstone
        end
    end
    self.snapshot[category] = newList
    return changes
end

--- 分块发送某个类别的变更
function Protocol:sendCategoryChanges(category, changes)
    if #changes == 0 then
        return true
    end
    local start = 1
    while start <= #changes do
        local finish = math.min(start + self.maxChunk - 1, #changes)
        local chunk = {}
        for i = start, finish do
            chunk[#chunk + 1] = changes[i]
        end
        local ok = self:send({
            action = "incremental_update",
            count = #chunk,
            changes = { [category] = chunk },
        })
        if not ok then
            return false
        end
        start = finish + 1
    end
    return true
end

--- 推送全部类别（force 时即使客户端未激活也推送）
function Protocol:pushUpdates(force)
    if not self.connected then
        return false
    end
    if not self.clientActive and not force then
        self.stats.pushSkipped = self.stats.pushSkipped + 1
        return false
    end
    local ok, collected = pcall(self.collect)
    if not ok or type(collected) ~= "table" then
        self.log("Snapshot collection failed: %s", tostring(collected))
        return false
    end
    local categories = {}
    for _, category in ipairs(CATEGORY_ORDER) do
        if collected[category] ~= nil then
            categories[#categories + 1] = category
        end
    end
    for category in pairs(SCALAR_CATEGORIES) do
        if collected[category] ~= nil then
            categories[#categories + 1] = category
        end
    end
    local needFullSync = self.needFullSync
    if needFullSync then
        self.stats.fullSyncs = self.stats.fullSyncs + 1
        self:send({ action = "full_sync_start", categories = categories })
    end
    local success = true
    for _, category in ipairs(CATEGORY_ORDER) do
        local list = collected[category]
        if list ~= nil then
            local changes = self:diffCategory(category, list)
            self.stats.changedItems = self.stats.changedItems + #changes
            if not self:sendCategoryChanges(category, changes) then
                success = false
                break
            end
        end
    end
    if success and collected.status ~= nil then
        if self.needFullSync or not valuesEqual(self.snapshot.status, collected.status) then
            self.snapshot.status = collected.status
            if not self:send({ action = "incremental_update", changes = { status = collected.status } }) then
                success = false
            end
        end
    end
    if success then
        self.needFullSync = false
        self.lastPush = os.epoch("utc")
        self.stats.pushes = self.stats.pushes + 1
        --- 全量数据发完了：给网页一个明确的“结束”信号。
        --- 网页在全量期间先把数据收进缓冲、结束（或超时兜底）时才整体替换 store ——
        --- 否则每次全量都要先清空，列表会瞬间变空（整页闪一下）。
        if needFullSync then
            self:send({ action = "full_sync_end", categories = categories })
        end
    end
    return success
end

--- 周期任务：断线重连、心跳超时、定时推送
function Protocol:update(now)
    now = now or os.epoch("utc")
    if self.clientActive and now - self.lastHeartbeat > self.clientTimeout * 1000 then
        self.clientActive = false
        self.needFullSync = true
        -- 长时间收不到浏览器消息：中继可能已经静默断开（浏览器那边不会触发 onclose），
        -- 直接重连一次中继（新连接会让频道内其它客户端收到 join 事件，网页随即全量同步）
        self.log("Client timeout, reconnecting relay")
        self.lastReconnect = now
        self:connect()
        return
    end
    if not self.connected then
        --- 异步连接请求还没结果：先等（websocket_success / websocket_failure 事件会改状态）
        if self.connecting then
            if now - (self.connectRequestedAt or 0) < CONNECT_TIMEOUT_MS then
                return
            end
            -- 超时：两个事件都没来（中继静默丢包）。允许重发；迟到的成功事件由 onSocketOpened 忽略。
            self.connecting = false
            self.stats.connectTimeouts = self.stats.connectTimeouts + 1
            self.log("WebSocket connect timed out after %ds, retrying", math.floor(CONNECT_TIMEOUT_MS / 1000))
        end
        if now - self.lastReconnect >= self.reconnectInterval * 1000 then
            self.lastReconnect = now
            self:connect()
        end
        return
    end
    if self.clientActive then
        -- 定时推送：间隔随“上次推送耗时”自动放大（扫描慢的机器不会被推送占满）
        local cost = self.lastPushCost or 0
        local minGap = math.max(self.updateInterval * 1000, cost * PUSH_COST_MULTIPLIER)
        -- 一次 2.4s 的收集如果只等 6s 就重来，主循环会被推送吃掉大半（网页随之“连不上”）：
        -- 慢推送之后强制拉长到 6 倍耗时（上限 15s），把主循环让给引擎与消息收发。
        if cost > 400 then
            minGap = math.max(minGap, math.min(cost * 6, 15000))
        end
        if now - self.lastPush >= minGap then
            local startedAt = os.epoch("utc")
            local ok = self:pushUpdates(false)
            self.lastPushCost = os.epoch("utc") - startedAt
            if not ok then
                -- 推送失败（中继断开、收集出错等）：也等到下一个间隔再重试，
                -- 否则每 0.1s 就会做一次全量收集，把主循环彻底占满
                self.lastPush = os.epoch("utc")
            end
        end
    end
    if self.logPending or now - (self.lastLogPush or 0) >= 2000 then
        self.lastLogPush = now
        self:flushLogs()
    end
end

--- 处理收到的 WebSocket 文本消息
function Protocol:handleMessage(raw)
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok or type(data) ~= "table" then
        self.log("Received unparseable message")
        return
    end
    local payload = data
    if data.message ~= nil then
        if type(data.message) == "table" then
            payload = data.message
        elseif type(data.message) == "string" then
            local okInner, inner = pcall(textutils.unserializeJSON, data.message)
            if okInner and type(inner) == "table" then
                payload = inner
            end
        end
    end
    --- 统计收到的消息（按 action 汇总；字节数是中继里的原始 JSON 长度）
    local stats = self.stats
    local bytes = #raw
    stats.recvMessages = stats.recvMessages + 1
    stats.recvBytes = stats.recvBytes + bytes
    if bytes > stats.recvMax then
        stats.recvMax = bytes
    end
    local recvBucket = statBucket(stats, "recv", payload.action or payload.type or "?")
    recvBucket.count = recvBucket.count + 1
    recvBucket.bytes = recvBucket.bytes + bytes
    if bytes > recvBucket.max then
        recvBucket.max = bytes
    end
    -- 服务端不做编码转换：名称字段的 ASCII 转义/还原由浏览器端负责（见文件顶部说明）
    -- itty.socket 会在有客户端加入/离开频道时向其它客户端推送 join / leave 事件
    if payload.type == "join" then
        if payload.self then
            self.selfUid = payload.uid
            self.log("Joined channel: uid=%s total=%s", tostring(payload.uid), tostring(payload.total))
        else
            -- 浏览器连上房间：立即推送一次全量数据（不必等它发 full_request）
            self.log("Client connected: uid=%s alias=%s total=%s",
                tostring(payload.uid), tostring(payload.alias), tostring(payload.total))
            self.clientActive = true
            self.lastHeartbeat = os.epoch("utc")
            self.needFullSync = true
            self.snapshot = {}
            -- 先把最近的日志补发给它，再推全量数据
            self.sentLogSeq = 0
            self:flushLogs()
            self:pushUpdates(true)
        end
        return
    end
    if payload.type == "leave" then
        local total = tonumber(payload.total) or 0
        self.log("Client disconnected: uid=%s alias=%s total=%s",
            tostring(payload.uid), tostring(payload.alias), tostring(total))
        if total <= 1 then
            -- 频道里只剩服务端自己：暂停推送，等下一个客户端连上再全量同步
            self.clientActive = false
            self.needFullSync = true
        end
        return
    end
    if not payload.action then
        return
    end
    self.lastHeartbeat = os.epoch("utc")
    if payload.action == "heartbeat" then
        self.clientActive = true
    end
    -- 任何带 action 的请求都证明“有客户端在”，因此一律标记为活跃：
    -- 这样即使服务端错过了浏览器的 join 事件（例如服务端刚重连上中继），
    -- 处理完请求后也会立刻把最新状态推回去，网页不会停在旧数据上。
    if not self.clientActive then
        self.clientActive = true
        self.needFullSync = true
    end
    local response = { id = payload.id or payload.cid, action = payload.action }
    if payload.action == "full_request" then
        self.clientActive = true
        self.needFullSync = true
        self.snapshot = {}
        self:pushUpdates(true)
        response.result = { full_request_received = true }
        self:send(response)
        return
    end
    local startedAt = os.epoch("utc")
    local okRequest, result = pcall(self.onRequest, payload)
    local elapsed = os.epoch("utc") - startedAt
    if not okRequest then
        response.result = { error = "\\u6267\\u884C\\u9519\\u8BEF\\uFF1A" .. tostring(result) }
        self.log("Action %s failed after %dms: %s", tostring(payload.action), elapsed, tostring(result))
    else
        response.result = result
        if elapsed >= 1000 then
            self.log("Action %s took %dms (slow)", tostring(payload.action), elapsed)
        end
    end
    self:send(response)
    if self.clientActive and payload.action ~= "heartbeat" then
        -- 推送出错绝不能把异常抛到主循环（主循环结束 = 服务端退出 = 网页所有请求超时）
        --
        -- 两点优化（实测：15 个容器在有线网络上一次全量收集约 1.4s）：
        --   1) 心跳只表示“浏览器还活着”，不必为它做全量收集 + 推送（每 5 秒一次）；
        --   2) 其它请求之后的推送也做最小间隔限制（minPushInterval）：浏览器连点按钮时
        --      不会每次都重扫一遍容器，最新状态由定时推送（updateInterval）补齐。
        local now = os.epoch("utc")
        if now - (self.lastPush or 0) >= self.minPushInterval then
            local okPush, pushErr = pcall(self.pushUpdates, self, false)
            if not okPush then
                self.log("Push after action %s failed: %s", tostring(payload.action), tostring(pushErr))
            end
        end
    end
end

--- 处理 CC:T 事件（返回 true 表示该事件已被协议层消费）
--- 注意：连接是**异步**的，所以 websocket_success 必须在这里处理（否则句柄拿不到）。
function Protocol:onEvent(event, param1, param2)
    if event == "websocket_success" and param1 == self.url then
        self:onSocketOpened(param2)
        return true
    end
    if event == "websocket_message" and param1 == self.url then
        self:handleMessage(param2)
        return true
    end
    if event == "websocket_closed" and param1 == self.url then
        self.connecting = false
        self.connected = false
        self.ws = nil          -- 句柄已失效：丢掉，免得之后 send 再报一次错
        self.clientActive = false
        self.log("WebSocket closed, will reconnect")
        return true
    end
    if event == "websocket_failure" and param1 == self.url then
        self.connecting = false
        self.connected = false
        self.ws = nil
        self.stats.connectFailures = self.stats.connectFailures + 1
        self.log("WebSocket connect failed: %s", tostring(param2))
        return true
    end
    return false
end

--- 连接状态（推送给网页的 status 类别）
function Protocol:status()
    return {
        url = self.url,
        connected = self.connected,
        --- 异步连接请求在飞（网页/诊断里能看到“正在连接”）
        connecting = self.connecting or false,
        clientActive = self.clientActive,
        updateInterval = self.updateInterval,
    }
end

--- 收发统计摘要（诊断模式 perf 使用）：消息数 / 字节数 + 按字节数排序的 action 明细。
--- 用来回答“运行缓慢到底是哪个动作、哪个包太大”。
--- 注意：方法名不能叫 `stats`：实例上还有一个数据字段 `self.stats`（原始计数表），
--- 同名字段会把方法**遮蔽**掉（`obj.stats` 拿到的是表，`obj:stats()` 会报 attempt to call a table value），
--- 所以这里叫 `statsSummary`（见 ifm/diagnose.lua 的调用与 build.py 的“方法遮蔽检查”）。
function Protocol:statsSummary()
    local stats = self.stats
    local actions = {}
    for key, entry in pairs(stats.byAction) do
        actions[#actions + 1] = {
            key = key,
            count = entry.count,
            bytes = entry.bytes,
            max = entry.max,
            average = entry.count > 0 and math.floor(entry.bytes / entry.count) or 0,
        }
    end
    table.sort(actions, function(a, b)
        if a.bytes ~= b.bytes then
            return a.bytes > b.bytes
        end
        return a.key < b.key
    end)
    local since = stats.since or os.epoch("utc")
    return {
        lastPushCost = self.lastPushCost or 0,
        updateInterval = self.updateInterval,
        sentMessages = stats.sentMessages,
        sentBytes = stats.sentBytes,
        sentMax = stats.sentMax,
        recvMessages = stats.recvMessages,
        recvBytes = stats.recvBytes,
        recvMax = stats.recvMax,
        dropped = stats.dropped,
        failed = stats.failed,
        encodeFailed = stats.encodeFailed,
        --- 异步连接计数（中继不通时 connectFailures / connectTimeouts 会持续增长）
        connectRequests = stats.connectRequests,
        connectFailures = stats.connectFailures,
        connectTimeouts = stats.connectTimeouts,
        pushes = stats.pushes,
        pushSkipped = stats.pushSkipped,
        fullSyncs = stats.fullSyncs,
        changedItems = stats.changedItems,
        uptimeSeconds = math.floor((os.epoch("utc") - since) / 1000),
        actions = actions,
    }
end

return Protocol
