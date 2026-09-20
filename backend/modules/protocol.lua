-- IFM :: modules/protocol.lua
-- WebSocket 通讯协议（参照 meweb 的实现）：
--   浏览器 -> 服务端：{ id, action, ...payload }
--   服务端 -> 浏览器：{ id, action, result }
--   服务端推送：{ action = "full_sync_start", categories = {...} }
--               { action = "incremental_update", count = n, changes = { [category] = {...} } }
--               { action = "full_sync_end", categories = {...} }   （全量发完了；网页据此一次性替换本地数据）
--   删除项带 _deleted = true；空闲时定期回 heartbeat。
-- 传输使用 itty.ws 中转：wss://itty.ws/c/<房间号>
-- 连接是异步的：http.websocketAsync 立刻返回，websocket_success / websocket_failure 事件
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

--- 推送策略（1.6.12）：
---   * 服务端不设 WebSocket 收发的速率硬限制（用户第 7 项要求）——
---     推送由“状态变更计数”（cache.revision）驱动：有变化就推，同一 tick 内多次请求只推一次；
---   * 没有变化时仍有 updateInterval 兜底刷新；推送失败时用同一个间隔退避重试。
--- 想恢复旧行为（最快 N 毫秒一次 / 按推送耗时放大间隔）时，传 minPushInterval 即可。
local DEFAULT_MIN_PUSH_GAP_MS = 0

--- 异步连接的超时（毫秒）：http.websocketAsync 立刻返回，结果靠 websocket_success /
--- websocket_failure 事件送达。万一两个事件都没来（中继静默丢包），超过这个时间就
--- 允许再发一次连接请求 —— 不然“一直在连”的状态会被卡死。
local CONNECT_TIMEOUT_MS = 35000

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

--- 日志分级兼容（用户第 2 项）：调用点用 self.log.warn / self.log.error 表达级别，
--- 而老的调用方 / 测试桩传进来的可能只是一个普通函数 —— 这里给它补上两个子入口。
local function levelLogger(fn)
    if type(fn) == "table" and fn.warn ~= nil and fn.error ~= nil then
        return fn                                  -- 已经是分级日志（Util.makeLogger 的产物）
    end
    local base
    if type(fn) == "function" then
        base = fn
    elseif type(fn) == "table" then
        base = fn.info or function() end
    else
        base = function() end
    end
    return setmetatable({
        warn = function(...) return base(...) end,
        error = function(...) return base(...) end,
    }, {
        __call = function(_, ...) return base(...) end,
    })
end

function Protocol.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Protocol)
    self.Util = opts.Util
    self.log = levelLogger(opts.log)
    self.url = opts.url
    self.collect = opts.collect
    self.onRequest = opts.onRequest
    self.onConnect = opts.onConnect
    self.updateInterval = opts.updateInterval or 2
    --- 浏览器请求之后那次推送的最小间隔（毫秒）。
    --- 1.6.12：默认 0 = 不设硬限制 —— 有数据变化就立刻推（用户第 7 项要求：
    --- 服务端不应当对 WebSocket 收发数据包做速率硬限制）。
    --- 仍然存在的两件事：① 一次推送会全量收集（读容器）——为了不把主循环压垮，
    --- 推送按“状态变更计数”驱动：只有自上次推送后有变化（cache.revision 变了）才会再推，
    --- 同一 tick 里多次请求只会合并成一次推送；② 推送失败时退避到下一个间隔再试。
    --- 需要立刻全量的场合（浏览器刚接入 / 点了刷新 / full_request）仍然用 pushUpdates(true)。
    self.minPushInterval = opts.minPushInterval or DEFAULT_MIN_PUSH_GAP_MS
    --- 两次增量推送之间的实际下限：只由 minPushInterval 决定（默认 0）
    self.pushGap = math.max(self.minPushInterval, 0)
    --- 状态变更计数提供者（一般是 cache.revision）：变了就推
    self.revisionProvider = opts.revisionProvider
    self.pushedRevision = nil
    --- 上一次推送（收集 + 发送）花了多少毫秒：只用于诊断显示，不再用它放大推送间隔
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
    --- 是否有一次异步连接请求在飞（http.websocketAsync 已发出、还没等到 websocket_success/failure）
    self.connecting = false
    self.connectRequestedAt = 0
    --- 我们自己关掉的 socket 数：CC:T 的关闭事件是异步、且只带 url（不带句柄），
    --- 所以重连时"关旧连接 → 开新连接"之后，旧连接的关闭事件会迟到到来。
    --- 如果不认识它，就会把刚建立的新连接一起判死 → 每 reconnectInterval 秒重连一次的死循环
    --- （用户报的"每隔几秒 WebSocket closed, will reconnect"）。这个计数就是用来认领它们的。
    --- 除了"自己关掉的 socket"，放弃握手的请求（超时后重发）与"多出来的句柄"
    --- 也会产生迟到的结果事件，同样记在这里。
    self.closeAcks = 0
    --- 还在等结果（websocket_success / websocket_failure / websocket_closed）的连接请求数。
    --- 关键：同一条连接不要重复发请求 —— 否则中继里会出现同一台计算机的多条连接，
    --- 网页会看到"加入 → 莫名离开"，中继也可能因为房间连接数超限而把人踢掉
    --- （日志里的 `Could not connect` 就是这么来的）。
    self.pendingAcks = 0
    --- 连接建立 / 关闭的时间与原因（诊断用：能看出"活了几秒就被关"还是"中继主动关"）
    self.connectedAt = 0
    self.closedAt = 0
    self.lastCloseReason = nil
    self.lastRxAt = 0
    --- 长时间（秒）收不到任何入站消息时的兜底重连：中继静默断开（没有关闭事件）才用得上，
    --- 所以放得很长，避免正常运行时反复重连。
    self.idleReconnectInterval = opts.idleReconnectInterval or 300
    self.lastIdleReconnect = 0
    --- 应用层保活（秒）：中继/反向代理对空闲 WebSocket 有超时（实测约 30~40 秒），
    --- 没有浏览器在房间里时主控什么都不发 → 中继会以 "Could not connect" 把连接踢掉，
    --- 表现为"没人看网页时服务端就每 35 秒重连一次，一打开网页就稳定了"。
    --- 所以这里在自己长时间（默认 20 秒）没有收发任何消息时，主动发一条极小的 keepalive。
    self.keepaliveInterval = opts.keepaliveInterval or 20
    self.lastSendAt = 0
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
        --- 连接生命周期计数（诊断用）：closes=中继关我们 / ownCloses=我们自己关（迟到事件）
        --- / staleCloses=重复或无效的关闭事件 / reconnects=主动重连次数
        closes = 0, ownCloses = 0, staleCloses = 0, reconnects = 0,
        byAction = {},
        --- 出站帧的最后一次 JSON 字节数（send 里更新；按类别记账用它，见 sendCategoryChanges）
        lastSendBytes = 0,
        since = os.epoch("utc"),
    }
    --- 用户第 3 项：按**类别**的发送记账（incremental_update 的流量成分到底是哪个类别）
    --- { [category] = { frames, bytes, max, items } }：只累积，诊断里按字节数排序展示
    self.categoryStats = {}
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
--- 用户第 1 项：`sendLog == false` 时完全不推送（日志仍留在服务端终端与内存里）。
function Protocol:onLog(text, seq)
    self.logPending = self.sendLog ~= false
end

--- 设置里的"给网页发日志"开关（默认开）。关掉时把待推送标记也清掉，避免空转。
function Protocol:setSendLog(enabled)
    local value = enabled ~= false
    if self.sendLog == value then
        return false
    end
    self.sendLog = value
    if not value then
        self.logPending = false
    end
    self.log("Web console log push %s (setting)", value and "ENABLED" or "DISABLED")
    return true
end

--- 把还没发过的服务端日志推给浏览器（浏览器会在控制台打印）
--- 用户第 1 项：设置里可以关掉"给网页发日志" —— 关掉后这里直接清掉待推送标记（不产生任何 WS 流量）。
function Protocol:flushLogs()
    if self.sendLog == false then
        self.logPending = false
        return
    end
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

--- 建立 WebSocket 连接（异步）
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
    self.pendingAcks = (self.pendingAcks or 0) + 1
    self.stats.connectRequests = self.stats.connectRequests + 1
    return true
end

--- websocket_success 事件：连接建立了，接管句柄
function Protocol:onSocketOpened(handle)
    self.connecting = false
    self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
    local kind = type(handle)
    if kind ~= "table" and kind ~= "userdata" then
        -- 事件里没有句柄（正常不会发生）：当作失败，下个周期重试
        self.connected = false
        self.log("WebSocket success event had no handle, will retry")
        return false
    end
    if self.ws then
        -- 已经有一个可用连接（例如连接超时后重发，随后迟到的成功事件）：把多出来的这个关掉，
        -- 保留正在用的那一个，避免句柄泄漏 / 消息重复。它的关闭事件会迟到 → 记进 closeAcks，
        -- 让 onEvent 认领掉，绝不能因此把在用的连接判死。
        self.closeAcks = (self.closeAcks or 0) + 1
        self.stats.extraHandles = (self.stats.extraHandles or 0) + 1
        pcall(function()
            handle.close()
        end)
        self.log("Extra websocket handle closed (a live connection already exists)")
        return false
    end
    --- 新连接建立：清掉"已经提示过发送失败"的标记（下一次失败要能再看到那条日志）
    self.sendFailedLogged = false
    --- 同样重置回声提示：新连接会拿到新的房间 uid，提示要能再出现一次（见 handleMessage）
    self.selfEchoLogged = false
    self.unknownEchoWarned = false
    self.ws = handle
    self.connected = true
    self.connectedAt = os.epoch("utc")
    self.lastRxAt = self.connectedAt
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
            self.log.warn("Message dropped: websocket not connected (action=%s)", tostring(message and message.action))
        end
        return false
    end
    local ok, json = pcall(textutils.serializeJSON, message, { allow_repetitions = true })
    if not ok then
        self.stats.encodeFailed = self.stats.encodeFailed + 1
        self.log.error("JSON encode failed: %s", tostring(json))
        return false
    end
    -- 注意：1.5.0 起中继永远由主控自己连接（IFMWorker 不再代连），所以这里没有“转发给 worker”的分支
    local socket = self.ws
    local sent, err = pcall(function()
        -- 点号调用：send(message [, binary])，binary 必须是布尔值，不能传句柄自身
        socket.send(json)
    end)
    if not sent then
        self.stats.failed = self.stats.failed + 1
        --- 同一条连接里只提示一次（连发失败会刷屏）；新连接建立时会重新允许提示
        if not self.sendFailedLogged then
            self.sendFailedLogged = true
            self.log.error("Send failed: %s", tostring(err))
        end
        --- 写失败 = 这条连接已经死了（中继关掉它、"attempt to use a closed file"）。
        --- 这里必须把句柄丢掉：否则后面每次推送都会在同一个死句柄上再失败一次
        --- （用户现场：控制台里一连串 "attempt to use a closed file"），
        --- 而且 closeAcks 会认领它迟到的关闭事件，不会把新连接一起判死。
        self.connected = false
        self.closedAt = os.epoch("utc")
        self.lastCloseReason = "send failed: " .. tostring(err)
        self:closeSocket()
        --- 立刻重连（不等 reconnectInterval）：主控不在线时网页会一直等不到数据，
        --- 15 秒后客户端开始"重连"、60 秒后整个界面收起回登录页（底部面板也跟着消失再出现）。
        self.lastReconnect = 0
        return false
    end
    self:noteSent(message, #json)
    self.lastSendBytes = #json
    return true
end

--- 发送统计（本机 socket 与 worker 转发两条路径共用）
function Protocol:noteSent(message, bytes)
    self.pushCount = self.pushCount + 1
    --- 最后一次发出消息的时间：应用层保活用它判断"我已经很久没说话了"
    self.lastSendAt = os.epoch("utc")
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
    --- 记一笔"是我们自己关的"：它的 websocket_closed 事件稍后才会到（只带 url，认不出句柄），
    --- 见 Protocol:onEvent —— 迟到的那次必须被认领，否则会把新连接一起判死。
    self.closeAcks = (self.closeAcks or 0) + 1
    pcall(function()
        socket.close()
    end)
end

--- 删除项延迟确认（用户第 2 项）：某一轮快照里"少了"不代表真的没了 ——
--- 外设重扫、worker 扫不到、容器换代都会造成一次性的空缺。以前立刻下发 _deleted，
--- 网页上就会出现"大批资源凭空消失、几秒后又回来"。现在要连续缺失这么久才发墓碑。
local TOMBSTONE_DELAY_MS = 3000

--- 这些类别的删除是**确定**的（条目是主控自己删掉的，不是扫描抖动）：不做延迟确认，立刻下发。
--- 例如发送队列（用户第 1 项）：物品真的搬完之后，网页上的「发送中」不该再挂几秒。
local IMMEDIATE_TOMBSTONES = { deliveries = true }

--- 请求"下一次推送时立刻下发删除"（跳过 TOMBSTONE_DELAY_MS 的延迟确认）。
--- 容器外设被移除 / 容器定义被删时调用它：这种"少了"同样是确定的，
--- 网页上那些"之前读到的物品"应当立即消失（用户第 3 项）。只用一次，用完自动失效。
function Protocol:expediteDeletions()
    self.expediteTombstones = true
end

--- 计算某个类别的增量（needFullSync 时退化为全量）
--- expedite = true：本轮所有"消失的条目"立刻下发墓碑（不等 TOMBSTONE_DELAY_MS）
function Protocol:diffCategory(category, newList, expedite)
    local fields = KEY_FIELDS[category]
    local changes = {}
    local now = os.epoch("utc")
    local pending = self.tombstoneAt or {}
    self.tombstoneAt = pending
    if expedite ~= true then
        expedite = IMMEDIATE_TOMBSTONES[category] == true
    end
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
        pending[category .. "\1" .. itemKey] = nil          -- 这一轮又出现了：撤销待删除标记
        local previous = previousMap[itemKey]
        if previous == nil or not valuesEqual(previous, item) then
            changes[#changes + 1] = item
        end
    end
    for itemKey, previous in pairs(previousMap) do
        if not seen[itemKey] then
            local markKey = category .. "\1" .. itemKey
            local since = pending[markKey]
            local due = expedite
            if not due then
                if not since then
                    pending[markKey] = now                  -- 第一次缺：只记时间，不发墓碑
                elseif now - since >= TOMBSTONE_DELAY_MS then
                    due = true
                end
            end
            if due then
                pending[markKey] = nil
                local tombstone = { _deleted = true }
                for _, field in ipairs(fields or {}) do
                    tombstone[field] = previous[field]
                end
                changes[#changes + 1] = tombstone
            end
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
    --- 用户第 3 项：发送流量按**类别**记账（incremental_update 里到底是哪个类别在吃流量）。
    --- 只统计每个 chunk 的实际 JSON 字节数（send 会把它记在 self.lastSendBytes 上）。
    local entry = self.categoryStats[category]
    if not entry then
        entry = { frames = 0, bytes = 0, max = 0, items = 0 }
        self.categoryStats[category] = entry
    end
    local start = 1
    while start <= #changes do
        local finish = math.min(start + self.maxChunk - 1, #changes)
        local chunk = {}
        for i = start, finish do
            chunk[#chunk + 1] = changes[i]
        end
        self.lastSendBytes = 0
        local ok = self:send({
            action = "incremental_update",
            count = #chunk,
            changes = { [category] = chunk },
        })
        if not ok then
            return false
        end
        local bytes = tonumber(self.lastSendBytes) or 0
        entry.frames = entry.frames + 1
        entry.items = entry.items + #chunk
        entry.bytes = entry.bytes + bytes
        if bytes > entry.max then
            entry.max = bytes
        end
        start = finish + 1
    end
    return true
end

--- 当前状态变更计数（cache.revision；没有提供者时返回 0）
function Protocol:currentRevision()
    if not self.revisionProvider then
        return 0
    end
    local ok, value = pcall(self.revisionProvider)
    if not ok then
        return 0
    end
    return tonumber(value) or 0
end

--- 自上次推送之后状态有没有变化（1.6.12：推送改成“有变化就推”，不做时间硬限制）
function Protocol:hasChanges()
    return self:currentRevision() ~= (self.pushedRevision or 0)
end

--- 每个类别的最小推送间隔（毫秒，用户第 2 项：incremental 流量几乎全花在 workers 上）。
--- worker 每秒上报一次 state，负载/计数/当前任务几乎每轮都不同 ⇒ 每次推送都把这几条重发一遍
--- （实测 4667 次推送 → workers 类别 6.6MB，占增量流量绝大部分）。
--- 这里只给 workers 一个下限：最多每 3 秒推一次（其它类别不受影响；全量同步照旧）。
local CATEGORY_PUSH_GAP_MS = { workers = 3000 }

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
    --- 本轮要不要"立刻下发删除"（见 expediteDeletions）：只用一次
    local expediteDeletions = self.expediteTombstones == true
    self.expediteTombstones = false
    if needFullSync then
        self.stats.fullSyncs = self.stats.fullSyncs + 1
        self:send({ action = "full_sync_start", categories = categories })
    end
    local success = true
    local pushNow = os.epoch("utc")
    local categorySentAt = self.categorySentAt or {}
    self.categorySentAt = categorySentAt
    for _, category in ipairs(CATEGORY_ORDER) do
        local list = collected[category]
        if list ~= nil then
            --- 用户第 2 项：这类别还没到最小间隔就跳过（快照不更新，改动会累积到下一次一起推，
            --- 所以不会丢变化）；全量同步时不做这个节流。
            local gap = CATEGORY_PUSH_GAP_MS[category] or 0
            if gap > 0 and not needFullSync and pushNow - (categorySentAt[category] or 0) < gap then
                self.stats.categorySkipped = (self.stats.categorySkipped or 0) + 1
            else
                local changes = self:diffCategory(category, list, expediteDeletions)
                categorySentAt[category] = pushNow
                self.stats.changedItems = self.stats.changedItems + #changes
                if not self:sendCategoryChanges(category, changes) then
                    success = false
                    break
                end
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
        --- 记下这次推送时的“状态变更计数”：下次只有计数又变了才会立刻再推（1.6.12）
        self.pushedRevision = self:currentRevision()
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
        --- 长时间收不到浏览器消息（后台标签页的定时器会被节流、网页自己也有看门狗会重建连接）。
        --- 1.7.0 起不再因此重连中继：以前那种"关掉好连接再开一条"的做法，
        --- 会让我们自己的关闭事件迟到、把新连接一起判死，形成每几秒重连一次的死循环
        --- （用户在服务端看到的就是刷屏的 WebSocket closed）。真正断线时 send 会失败，
        --- 那时走下面的正常重连分支。
        self.log("Client timeout (%ds without browser message); keeping the relay socket, will resync", self.clientTimeout)
        return
    end
    if not self.connected then
        --- 异步连接请求还没结果：先等（websocket_success / websocket_failure / websocket_closed 事件会改状态）
        if (self.pendingAcks or 0) > 0 then
            if now - (self.connectRequestedAt or 0) < CONNECT_TIMEOUT_MS then
                --- 还有一条请求在飞：绝不再发一条。否则中继里会出现同一台计算机的多条连接，
                --- 网页会看到"自己加入 → 立刻又离开"，中继也可能因为房间连接数超限而把连接踢掉
                --- （日志里的 `Could not connect` 就是这么来的）。
                return
            end
            -- 超时：结果事件一直没来（中继静默丢包）。放弃这条请求并允许重发；
            -- 它迟到的成功/失败/关闭事件由 closeAcks 认领，绝不会影响下一条连接。
            self.pendingAcks = math.max(0, self.pendingAcks - 1)
            self.closeAcks = (self.closeAcks or 0) + 1
            self.connecting = false
            self.stats.connectTimeouts = self.stats.connectTimeouts + 1
            self.stats.abandoned = (self.stats.abandoned or 0) + 1
            self.log("WebSocket connect timed out after %ds, retrying", math.floor(CONNECT_TIMEOUT_MS / 1000))
        end
        if now - self.lastReconnect >= self.reconnectInterval * 1000 then
            self.lastReconnect = now
            self.stats.reconnects = (self.stats.reconnects or 0) + 1
            self:connect()
        end
        return
    end
    --- 兜底：连接看起来还在，但很久没收到任何入站消息了（中继静默断开时不会有关闭事件）。
    --- 间隔很长（默认 300s）且只在确实连着时才生效，避免正常运行时反复重连。
    local lastInbound = math.max(self.lastRxAt or 0, self.connectedAt or 0)
    if self.idleReconnectInterval and self.idleReconnectInterval > 0
        and now - lastInbound > self.idleReconnectInterval * 1000
        and now - (self.lastIdleReconnect or 0) > self.idleReconnectInterval * 1000 then
        self.lastIdleReconnect = now
        self.lastRxAt = now
        self.stats.reconnects = (self.stats.reconnects or 0) + 1
        self.log("No relay traffic for %ds, refreshing the connection", self.idleReconnectInterval)
        self:connect()
        return
    end
    --- 应用层保活（见 keepaliveInterval 的说明）：自己长时间没收发任何消息就发一条极小的消息，
    --- 免得中继因为"空闲"把连接踢掉（没人在网页上时就是这样）。
    local lastTraffic = math.max(self.lastSendAt or 0, self.lastRxAt or 0, self.connectedAt or 0)
    if self.keepaliveInterval and self.keepaliveInterval > 0
        and now - lastTraffic >= self.keepaliveInterval * 1000 then
        self.stats.keepalives = (self.stats.keepalives or 0) + 1
        self:send({ type = "keepalive", at = now })
    end
    if self.clientActive then
        -- 推送策略（1.6.12，用户第 7 项：不做速率硬限制）：
        --   * 状态有变化（cache.revision 变了）→ 立刻推；
        --   * 没有变化 → 每 updateInterval 兜底推一次（防止漏掉没走 markDirty 的变化）；
        --   * 推送耗时不再放大推送间隔（那是以前的“自适应硬限制”）。
        local changed = self:hasChanges()
        if changed or now - self.lastPush >= self.updateInterval * 1000 then
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

--- ===== 中继回声过滤（应用层问题，不是传输问题）=====
--- itty 房间广播是"发给房间里所有人"，**包含发送者自己** —— 所以我们每发出一帧，
--- 稍后都会原样再收到一次。这些帧带着 action，如果按普通客户端请求处理，就会：
---   ① 打一行 `request: <action>` 日志（用户现场就是刷屏的 request: full_sync_start / log）；
---   ② 走完 handleRequest 后**回一条响应**进房间；
---   ③ 网页那边 `handleIncoming` 先按 action 分派（才轮到 id 配对），于是把这条响应
---      当成真的 `full_sync_start` / `full_sync_end` → 随机开始/结束一次"全量缓冲" →
---      对缓冲里的类别 `store.clear()` 再只放回有变化的条目 → worker 卡片/列表"消失又出现"。
---   ④ 浏览器自己发出的请求同样会被回声：回声与真响应 id 相同，谁先到谁被认领
---      （回声带着请求体、没有 result）→ 有些操作看着"点了没反应"。
--- 处理方式：按**发送者 uid** 丢掉自己的帧 —— 与 IFMWorker 丢掉自己的 modem 包同一个道理
--- （IFMWorker.lua：`message.from == computerId` 就 return）。不新增任何自定义协议字段：
--- uid 是中继自己给的（`join` 事件里的 uid 也被我们用来自记 selfUid）。
function Protocol.senderUidOf(frame)
    if type(frame) ~= "table" or frame.uid == nil then
        return nil
    end
    return tostring(frame.uid)
end

--- 这一帧是不是我们自己发出的（中继回声回自己）：发送者 uid == 本连接在房间里的 uid
function Protocol:isOwnFrame(frame)
    local uid = Protocol.senderUidOf(frame)
    if uid == nil or self.selfUid == nil then
        return false
    end
    return uid == tostring(self.selfUid)
end

--- 只可能由服务端（我们）发出的 action：网页端从不发这些。
--- 万一收到的这类帧**没被** isOwnFrame 认出来（uid 字段对不上 / 还没收到自己的 join），
--- 必须留一行带帧字段名的日志 —— 否则同一个 bug 会以"网页莫名清空列表"的形式悄悄回来。
local SERVER_ONLY_ACTIONS = {
    full_sync_start = true,
    full_sync_end = true,
    incremental_update = true,
    keepalive = true,
    log = true,
}

--- 处理收到的 WebSocket 文本消息
function Protocol:handleMessage(raw)
    local ok, data = pcall(textutils.unserializeJSON, raw)
    if not ok or type(data) ~= "table" then
        self.log.error("Received unparseable message")
        return
    end
    --- 自己的回声：直接丢掉（连统计都不进 recv 分桶，免得把"我们发了多少"算成"收到了多少"）。
    --- 每连接只提示一次：不能刷屏，但也绝不静默 —— 它会解释"为什么 request: 日志变少了"。
    if self:isOwnFrame(data) then
        self.stats.recvSelf = (self.stats.recvSelf or 0) + 1
        if not self.selfEchoLogged then
            self.selfEchoLogged = true
            self.log.warn("Ignoring the relay's echo of our own frames (uid=%s): they are our own messages",
                tostring(self.selfUid))
        end
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
    --- 兜底自检（见 SERVER_ONLY_ACTIONS 的说明）：一次连接最多一条
    if payload.action and SERVER_ONLY_ACTIONS[payload.action] and not self.unknownEchoWarned then
        self.unknownEchoWarned = true
        local fields = {}
        for key in pairs(data) do
            fields[#fields + 1] = tostring(key)
        end
        table.sort(fields)
        self.log.warn("Received a server-only action (%s) that we could not recognise as our own echo" ..
            " (selfUid=%s, frame fields: %s): check the relay's sender uid field",
            tostring(payload.action), tostring(self.selfUid), table.concat(fields, ","))
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
        self.log.error("Action %s failed after %dms: %s", tostring(payload.action), elapsed, tostring(result))
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
        --- 1.6.12：请求处理完之后有变化就推（用户第 7 项：不做速率硬限制）。
        ---   * 判断依据是 cache.revision：同一 tick 里连着来几个请求，也只有第一个会真的推
        ---     （推完 revision 就同步了），因此不会把主循环刷爆；
        ---   * 心跳只表示“浏览器还活着”，不为它做全量收集（保持原样）；
        ---   * minPushInterval 默认 0（可在启动参数里恢复节流）。
        local now = os.epoch("utc")
        if now - (self.lastPush or 0) >= (self.pushGap or 0) and self:hasChanges() then
            local okPush, pushErr = pcall(self.pushUpdates, self, false)
            if not okPush then
                self.log("Push after action %s failed: %s", tostring(payload.action), tostring(pushErr))
            end
        end
    end
end

--- 处理 CC:T 事件（返回 true 表示该事件已被协议层消费）
--- 注意：连接是异步的，所以 websocket_success 必须在这里处理（否则句柄拿不到）。
function Protocol:onEvent(event, param1, param2, param3)
    if event == "websocket_success" and param1 == self.url then
        self:onSocketOpened(param2)
        return true
    end
    if event == "websocket_message" and param1 == self.url then
        self.lastRxAt = os.epoch("utc")
        self:handleMessage(param2)
        return true
    end
    if event == "websocket_closed" and param1 == self.url then
        local stats = self.stats
        stats.closes = stats.closes + 1
        self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
        --- 关闭原因（CC:T 会给出原因/说明，中继主动关与本地关掉能区分开）
        local reason = tostring(param2)
        if param3 ~= nil and tostring(param3) ~= "" then
            reason = reason .. " / " .. tostring(param3)
        end
        self.lastCloseReason = reason
        self.closedAt = os.epoch("utc")
        --- ①② 属于"不重要"的关闭事件：断的不是当前在用的这条连接
        ---   ① closeAcks > 0：我们自己关掉的旧连接 / 放弃握手的请求 / 多出来的句柄 —— 认领并忽略它。
        ---      关键点：绝不能因为它的迟到而把刚建立的新连接判死（那就是"每几秒重连一次"的根因）。
        ---   ② self.ws 还活着，但我们没有任何在飞的请求：说明这条关闭事件属于更早的连接
        ---      （中继侧的老连接超时清理），当前连接不受影响。
        if (self.closeAcks or 0) > 0 then
            self.closeAcks = self.closeAcks - 1
            stats.ownCloses = stats.ownCloses + 1
            self.log("Old socket closed as requested (ignored; %s; age %dms)",
                reason, self.connectedAt > 0 and (self.closedAt - self.connectedAt) or 0)
            return true
        end
        if not self.ws and not self.connected then
            --- 已经没有活连接了（重复的关闭事件）：只记数，不改状态
            stats.staleCloses = stats.staleCloses + 1
            return true
        end
        self.connecting = false
        self.connected = false
        self.ws = nil          -- 句柄已失效：丢掉，免得之后 send 再报一次错
        self.clientActive = false
        self.log("WebSocket closed by relay (%s) after %ds, will reconnect",
            reason, self.connectedAt > 0 and math.floor((self.closedAt - self.connectedAt) / 1000) or 0)
        return true
    end
    if event == "websocket_failure" and param1 == self.url then
        self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
        self.stats.connectFailures = self.stats.connectFailures + 1
        --- 认领属于旧请求的失败事件：当前连接（self.ws）绝不能被它清掉
        if (self.closeAcks or 0) > 0 then
            self.closeAcks = self.closeAcks - 1
            self.stats.staleCloses = (self.stats.staleCloses or 0) + 1
            self.log("Stale connect failure ignored: %s", tostring(param2))
            return true
        end
        if self.ws and self.connected then
            self.stats.staleCloses = (self.stats.staleCloses or 0) + 1
            self.log("Connect failure for an old attempt ignored (a live connection exists): %s", tostring(param2))
            return true
        end
        self.connecting = false
        self.connected = false
        self.ws = nil
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
        --- 连接活了多久 / 上一次收到入站消息过了多久 / 上一次断开的原因（诊断闪断用）
        connectedSeconds = (self.connected and (self.connectedAt or 0) > 0)
            and math.floor((os.epoch("utc") - self.connectedAt) / 1000) or 0,
        idleSeconds = ((self.lastRxAt or 0) > 0) and math.floor((os.epoch("utc") - self.lastRxAt) / 1000) or -1,
        closes = (self.stats and self.stats.closes) or 0,
        lastCloseReason = self.lastCloseReason,
        --- 在飞请求数 / 等我们认领的迟到事件数（诊断"为什么一直重连"用）
        pendingAcks = self.pendingAcks or 0,
        expectedAcks = self.closeAcks or 0,
    }
end

--- 收发统计摘要（诊断模式 perf 使用）：消息数 / 字节数 + 按字节数排序的 action 明细。
--- 用来回答“运行缓慢到底是哪个动作、哪个包太大”。
--- 注意：方法名不能叫 `stats`：实例上还有一个数据字段 `self.stats`（原始计数表），
--- 同名字段会把方法遮蔽掉（`obj.stats` 拿到的是表，`obj:stats()` 会报 attempt to call a table value），
--- 所以这里叫 `statsSummary`（见 modules/diagnose.lua 的调用与 build.py 的“方法遮蔽检查”）。
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
    --- 用户第 3 项：incremental_update 的流量成分（按类别，字节数降序）——
    --- "6MB 到底是谁发的"这个问题就是靠这一段回答的。
    local categories = {}
    for key, entry in pairs(self.categoryStats or {}) do
        categories[#categories + 1] = {
            key = key,
            frames = entry.frames or 0,
            items = entry.items or 0,
            bytes = entry.bytes or 0,
            max = entry.max or 0,
            average = (entry.frames or 0) > 0 and math.floor((entry.bytes or 0) / entry.frames) or 0,
        }
    end
    table.sort(categories, function(a, b)
        if a.bytes ~= b.bytes then
            return a.bytes > b.bytes
        end
        return tostring(a.key) < tostring(b.key)
    end)
    return {
        lastPushCost = self.lastPushCost or 0,
        updateInterval = self.updateInterval,
        --- 增量推送的实际下限（毫秒）：minPushInterval 与 updateInterval 取较大者（1.6.7 起 2000）
        pushGap = self.pushGap or self.minPushInterval,
        minPushInterval = self.minPushInterval,
        sentMessages = stats.sentMessages,
        sentBytes = stats.sentBytes,
        sentMax = stats.sentMax,
        --- 按类别的发送明细（字节数降序）：incremental_update 的流量成分
        categories = categories,
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
        --- 连接生命周期：closes=中继关我们 / ownCloses=我们自己关（迟到事件被认领）
        --- / staleCloses=重复关闭事件 / reconnects=主动重连次数
        closes = stats.closes or 0,
        ownCloses = stats.ownCloses or 0,
        staleCloses = stats.staleCloses or 0,
        reconnects = stats.reconnects or 0,
        --- 连接请求纪律（1.7.0 修复）：在飞请求数 / 我们自己认领掉的迟到事件数 / 放弃的请求 / 多余句柄
        pendingAcks = self.pendingAcks or 0,
        expectedAcks = self.closeAcks or 0,
        abandoned = stats.abandoned or 0,
        extraHandles = stats.extraHandles or 0,
        --- 应用层保活次数（空闲时防止中继把连接踢掉）
        keepalives = stats.keepalives or 0,
        lastCloseReason = self.lastCloseReason,
        connectedSeconds = (self.connected and self.connectedAt or 0) > 0
            and math.floor((os.epoch("utc") - self.connectedAt) / 1000) or 0,
        idleSeconds = ((self.lastRxAt or 0) > 0) and math.floor((os.epoch("utc") - self.lastRxAt) / 1000) or -1,
        pushes = stats.pushes,
        pushSkipped = stats.pushSkipped,
        fullSyncs = stats.fullSyncs,
        changedItems = stats.changedItems,
        uptimeSeconds = math.floor((os.epoch("utc") - since) / 1000),
        actions = actions,
    }
end

return Protocol
