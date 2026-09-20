-- IFM :: modules/transfer.lua
-- IFMWorker 调度（1.5.0）：worker 只做两件事 —— 「物品/流体搬运」与「物品/流体查询」。
-- 流程（engine）、存储整理（compact）、网页中继（WebSocket）一律由主控自己执行，
-- 所以 worker 掉线既不会影响流程推进，也不会让网页失联。
--
-- 节点发现（discovery）
--   * 主控每隔 HELLO_INTERVAL(3s) 在 self.channel 广播 { op = "hello" }（Transfer:tick）；
--   * worker 收到 hello 立刻回 { op = "pong", name, caps }；另外 worker 自己每 5s 也会主动广播一次
--     hello（主控重启后不用等它广播就能发现它）；
--   * 来自某台 worker 的任何消息都会刷新 worker.lastSeen（见 touch()），超过 WORKER_TIMEOUT(12s)
--     没有任何消息 → 从 self.workers 移除，它手上的搬运任务作废（引擎下个 tick 会重试）。
--   结果表 self.workers：id -> { id, name, caps, lastSeen, busy, jobs, moved, queries, stateAt, ... }，
--   能力 caps 由 worker 上报：{ move = true, query = true }（老版本 worker 只会上报搬运）。
--
-- 任务分发（dispatch）
--   搬运：引擎每 tick 调 Transfer:request(job)（job 带 from/to/slot/limit…）——
--     0 台可用 worker            → 返回 "local"，本机自己搬（与没有分布式时完全一致）
--     挑到空闲且支持 move 的 worker → 发 { op = "job", target = <id> }，返回 "pending"
--     有 worker 但都在忙          → 也返回 "pending"（下个 tick 用同一个任务键再问一次），
--                                   绝不退回本机搬（避免同一次搬运被两处执行）
--   同一个 key 的任务只提交一次；worker 回 done/error 后才有真实结果（引擎那边仍是“等搬运完成”的语义）。
--   每台 worker 同一时间只做一个任务（它自己会用 busy 拒绝并发任务），所以多台 worker 天然并行。
--   查询：主控调 Transfer:requestQuery(spec)（spec = container/names/limit，key 用于缓存）——
--     把每个容器各派一条查询，轮流分给空闲的 worker（慢容器只影响它自己那一条）。
--     缓存命中（QUERY_TTL 内）→ "done", result
--     已有同 key 的查询在飞       → "pending"
--     挑到空闲且支持 query 的 worker → 发 { op = "query", target = <id> }，返回 "pending"
--     没有 worker 支持/可用        → "local"（调用方自己做本机扫描）
--     worker 回 query_result 后结果进 self.queryCache[key]，用 queryResult(key) 取；
--     最近一次结果同时放在 self.lastQuery（网页/诊断直接看）。

local Transfer = {}
Transfer.__index = Transfer

--- 通讯频道：所有 IFMWorker 与 IFM 都用它（worker 可用 --channel 覆盖）
Transfer.CHANNEL = 41000
Transfer.PROTOCOL = "ifm_transfer"

local HELLO_INTERVAL = 3000     -- IFM 广播 hello 的间隔（毫秒）
local WORKER_TIMEOUT = 15000    -- 多久没听到某台 worker 的消息就认为它掉线（无线链路偶尔丢包，别设太紧）
local JOB_TIMEOUT = 20000       -- 单个搬运任务多久没回报就算失败（交出 worker，任务作废）
local QUERY_TIMEOUT = 10000     -- 单个查询（含容器代扫）多久没回报就算失败
--- 查询/搬运是无线 modem 发的，偶发丢包很正常：这么久还没回音就重发同一个 id
--- （worker 侧对同一个 id 是幂等的：做过的直接重发上次结果，绝不会重复扫描/搬运）
local QUERY_RESEND_MS = 3000
local QUERY_RESEND_MAX = 2      -- 最多再发 2 次（共 3 次尝试），仍无回音就作废、交回本机读
local JOB_RESEND_MS = 4000      -- 搬运任务的重发间隔（worker 幂等，重复发不会重复搬）
local JOB_RESEND_MAX = 2
--- 查询没有超时会留下“永久 busy”的 worker：主控以为它还在扫，网页上就显示成
--- 「工作中」但看不到任何任务，而且再也不会派活给它（扫描默默退回主控本机读）。
--- ===== 物品详情卸载（worker 代查 getItemDetail，见 Transfer:detailRequest）=====
--- getItemDetail 与 list() 一样是阻塞的外设调用（有线网络上 ≈1 个服务器刻/次）：
--- 整理计划要为每种物品问一次 maxCount、标签扫描要为每种物品问一次 tags，
--- 而 19 个容器里可能有几百种物品 —— 全压在主控身上就是几百个服务器刻（主控会明显卡住）。
--- 打包交给 worker 之后，主控只等 modem 消息（结果进 Containers 的物品详情字典）。
local DETAIL_BATCH = 8          -- 一次请求最多带几个样本（worker 一口气做完，别把它占太久）
local DETAIL_TIMEOUT = 8000     -- 多久没回报就作废（样本没进字典，调用方下一轮自然会重派）
local DETAIL_RESEND_MS = 2500   -- 重发间隔（worker 对同一个 id 幂等）

function Transfer.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transfer)
    self.log = opts.log or function() end
    self.Peripherals = opts.Peripherals
    --- modem 发现 / 包装 / 发消息：与 IFMWorker.lua 共用 modules/modems.lua（不再各写一份）
    self.Modems = opts.Modems
    if not self.Modems then
        error("transfer.lua needs the modems module: pass opts.Modems (loadModule(\"modems\"))", 0)
    end
    self.channel = tonumber(opts.channel) or Transfer.CHANNEL
    self.modemSide = opts.modemSide        -- 显式指定时用；否则自动找第一个 modem
    self.modem = nil
    self.listenReady = false
    self.helloAt = 0
    self.workers = {}                       -- id -> { id, lastSeen, busy, jobs }
    self.jobs = {}                          -- key -> { id, key, worker, at, state, moved, error }
    self.jobById = {}                       -- id -> 同一个 record
    self.jobSeq = 0
    self.stats = { submitted = 0, done = 0, failed = 0, timedOut = 0, localMoves = 0, busyRejected = 0 }
    -- ===== 分布式（1.5.0）：worker 只做「搬运」与「查询」=====
    -- 主控上下文：IFMMaster.lua 建好其它模块后调用 setContext（目前只需要 version 用于版本核对）
    self.version = nil
    -- 查询（物品/流体）：见 Transfer:requestQuery / queryResult / queryStatus
    self.querySeq = 0                 -- 查询任务号（递增）
    self.queries = {}                 -- id -> { id, key, worker, at, spec }
    self.queryRunning = {}            -- key -> id（同一个 key 只允许一个在飞任务）
    self.queryCache = {}              -- key -> { at, result }（QUERY_TTL 内复用）
    self.queryTtl = 2000              -- 查询结果缓存多久（毫秒）
    self.queryStats = { submitted = 0, done = 0, failed = 0, busyRejected = 0, acked = 0 }
    self.lastQuery = nil              -- 最近一次查询结果摘要（网页/诊断直接看）
    self.scanStats = { batches = 0, requests = 0, hits = 0, pending = 0, localOnly = 0,
        containers = 0, failed = 0, subQueries = 0, paused = 0, blind = 0, queued = 0,
        throttled = 0 }
    -- ===== 物品详情卸载：worker 代查 getItemDetail（见 Transfer:detailRequest）=====
    self.detailSeq = 0
    self.details = {}                     -- id -> { id, worker, at, sendAt, attempts, samples }
    self.detailResults = {}               -- 回报进来、还没被主控吸收的详情（takeDetailResults）
    --- 1.7.0：容器扫描改成"队列发请求"模式（见 Transfer:submitScan）：
    --- 结果回来的回调由主控挂上（写进 containers 的快照 / 结束队列任务）。
    self.onQueryResult = nil
    --- 物品详情回报的回调（同样的用法：由主控挂上）
    self.onDetailResult = nil
    --- 同一个容器的扫描结果在这个时间内算"新鲜"，不重复派活（毫秒）
    self.scanFreshMs = opts.scanFreshMs or 500
    self.detailStats = { submitted = 0, done = 0, failed = 0, items = 0 }
    self.lastDetail = nil                 -- 最近一次详情回报的摘要（诊断用）
    return self
end

--- 找到 modem 外设（有线优先；具体实现见 modules/modems.lua，worker 用的是同一份）
function Transfer:ensureModem()
    if self.modem and self.listenReady then
        return self.modem
    end
    local modem, modemName = nil, nil
    if self.modemSide then
        modem, modemName = self.Modems.asModem(self.modemSide)
    else
        modem, modemName = self.Modems.find()
    end
    if modem then
        self.modemName = modemName or self.modemName
    end
    if not modem then
        self.modem = nil
        self.listenReady = false
        return nil
    end
    if self.modem ~= modem then
        self.modem = modem
        self.listenReady = false
    end
    if not self.listenReady then
        local ok, err = pcall(modem.open, self.channel)
        if not ok then
            self.log("IFMWorker link: cannot open channel %d (%s)", self.channel, tostring(err))
            self.modem = nil
            return nil
        end
        self.listenReady = true
        self.log("IFMWorker link: listening on channel %d via modem %s", self.channel,
            tostring(self.modemName or "?"))
    end
    return self.modem
end

--- 在飞状态：每台 worker 同一时间只做一条任务，所以它是一个 0/1 的标记。
--- busy 由它派生（网页仍读 busy；调度器读 inFlight 判断“有没有空闲 worker”）。
--- 用 set 而不是计数：发送成功 / 收到结果 / 超时 / worker 每秒 state 纠正 —— 都会把
--- 它设成明确的值，重复设置是幂等的（旧代码就是直接写 worker.busy 的布尔量）。
function Transfer:setWorkerBusy(worker, busy)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = busy and 1 or 0
    worker.busy = busy and true or false
end

--- 空闲（没有在飞任务）且可用的 worker 数；给了 feature 就要求具备该能力。
--- 调度器用它决定"队列能不能推进"：0 台空闲 → 本次调度不推进队列。
function Transfer:idleCount(feature)
    local count = 0
    for _, worker in pairs(self.workers) do
        if (worker.inFlight or 0) <= 0 and self:workerUsable(worker) and
            (not feature or self:workerHas(worker, feature)) then
            count = count + 1
        end
    end
    return count
end

--- worker 的显示名（日志用）：有 --name 时返回 " 名字"，否则空串（worker 可能是 nil，例如超时的任务）
function Transfer:workerLabel(worker)
    if type(worker) == "table" and type(worker.name) == "string" and worker.name ~= "" then
        return " " .. worker.name
    end
    return ""
end

--- 主控这边还欠着这台 worker 的任务吗（有在飞的搬运或查询）？
--- 用来判断“它的 busy 能不能安全清掉”：只要没有在飞的任务，worker 自己上报的 busy 就是权威的。
function Transfer:workerHasPending(worker)
    if type(worker) ~= "table" then
        return false
    end
    for _, job in pairs(self.jobs) do
        if job.worker == worker.id and job.state == "pending" then
            return true
        end
    end
    for _, query in pairs(self.queries) do
        if query.worker == worker.id then
            return true
        end
    end
    --- 在飞的物品详情代查也算（否则它的 busy 会被 worker 每秒上报的 state 清掉）
    for _, request in pairs(self.details) do
        if request.worker == worker.id then
            return true
        end
    end
    return false
end

function Transfer:workerCount()
    local count = 0
    for _ in pairs(self.workers) do
        count = count + 1
    end
    return count
end

--- 是否至少有一台可用的 worker（有它时 IFM 自己不再搬运）
--- 注意：版本和主控不一致的 worker 不算可用 —— 协议/行为必须两边一致，
--- 否则会出现“明明有 worker，主控却把活交出去、结果没人做”的局面（网页上它们会被标红提示）。
function Transfer:workerUsable(worker)
    if type(worker) ~= "table" then
        return false
    end
    --- 主控自己都不知道版本（理论上不该发生）：一律不派活 ——
    --- 以前这里返回 true，等于“版本没设好时所有 worker 都能用”，版本不匹配就拦不住了。
    if not self.version then
        if not self.versionMissingLogged then
            self.versionMissingLogged = true
            self.log("Master version is not set (setContext was never called): workers are disabled")
        end
        return false
    end
    --- 还没上报过版本（刚连上、或老版本 worker 不会报）：
    --- 编码规范（用户第 1 项）：以前这里是**静默返回 false**（"不可用"），结果就是
    --- 网页上"所有 worker 空闲、却没有任何任务被派出去"（idle=0 → 调度器 mode=paused），
    --- 而且一句日志都没有。现在：明确记日志 + 计数，并**允许使用**它 ——
    --- 能连上、能每秒上报 state 的 worker 是能用的；版本确实不一致的仍然排除（见下）。
    if type(worker.version) ~= "string" or worker.version == "" then
        worker.versionUnknown = true
        if not worker.versionUnknownLogged then
            worker.versionUnknownLogged = true
            self.stats.unknownVersion = (self.stats.unknownVersion or 0) + 1
            self.log("IFMWorker #%s did not report a version - it will still be used " ..
                "(copy the same build to that computer to silence this)", tostring(worker.id))
        end
        return true
    end
    return worker.version == self.version
end

function Transfer:available()
    for _, worker in pairs(self.workers) do
        if self:workerUsable(worker) then
            return true
        end
    end
    return false
end

function Transfer:pendingCount()
    local count = 0
    for _, job in pairs(self.jobs) do
        if job.state == "pending" then
            count = count + 1
        end
    end
    return count
end

function Transfer:status()
    local busy = 0
    for _, worker in pairs(self.workers) do
        if worker.busy then
            busy = busy + 1
        end
    end
    return {
        available = self:available(),
        workers = self:workerCount(),
        movers = #self:capableWorkers("move"),
        queriers = #self:capableWorkers("query"),
        busy = busy,
        --- 空闲（没有在飞任务）且可用的 worker 数：调度器据此决定"队列能不能推进"
        idle = self:idleCount(),
        idleMovers = self:idleCount("move"),
        idleQueriers = self:idleCount("query"),
        --- 排错用：为什么有些 worker 没算进 idle（用户现场："全部空闲但什么都不做"）
        usable = self:usableBreakdown().usable,
        versionUnknown = self:usableBreakdown().versionUnknown,
        versionMismatch = self:usableBreakdown().versionMismatch,
        inFlightWorkers = self:usableBreakdown().inFlight,
        pending = self:pendingCount(),
        queries = self.queryStats,
        queriesPending = self:queryPendingCount(),
        details = self.detailStats,
        detailsPending = self:detailPendingCount(),
        lastQuery = self.lastQuery,
        channel = self.channel,
        modem = self.modemName,
        submitted = self.stats.submitted,
        done = self.stats.done,
        failed = self.stats.failed,
        timedOut = self.stats.timedOut,
        localMoves = self.stats.localMoves,
        busyRejected = self.stats.busyRejected or 0,
    }
end

--- 统计"为什么某些 worker 不算可用/空闲"（诊断用）：
--- 主控没版本 / worker 没报版本 / 版本不一致 / 有在飞任务 —— 四种原因分别计数。
function Transfer:usableBreakdown()
    local out = { total = 0, usable = 0, noMasterVersion = 0, versionUnknown = 0, versionMismatch = 0, inFlight = 0 }
    for _, worker in pairs(self.workers) do
        out.total = out.total + 1
        if not self.version then
            out.noMasterVersion = out.noMasterVersion + 1
        elseif type(worker.version) ~= "string" or worker.version == "" then
            out.versionUnknown = out.versionUnknown + 1
        elseif worker.version ~= self.version then
            out.versionMismatch = out.versionMismatch + 1
        elseif (worker.inFlight or 0) > 0 then
            out.inFlight = out.inFlight + 1
        else
            out.usable = out.usable + 1
        end
    end
    return out
end

--- 任务键：同一逻辑搬运在所有 tick 里都必须得到同一个键（用于“同一个任务只提交一次”）
local function keyOf(job)
    return table.concat({
        tostring(job.action),
        tostring(job.from),
        tostring(job.fromSlot or -1),
        tostring(job.limit or -1),
        tostring(job.to),
        tostring(job.toSlot or -1),
        tostring(job.fluid or ""),
    }, "|")
end

--- worker 是否具备某种能力（caps 缺失 = 老版本 worker：只会上报搬运，不会查询）
function Transfer:workerHas(worker, feature)
    local caps = worker.caps
    if feature == "move" then
        return caps == nil or caps.move ~= false
    end
    if caps == nil then
        return false
    end
    return caps[feature] == true
end

--- 选一台“空闲 + 具备该能力 + 版本与主控一致”的 worker（按已完成任务数轮转，尽量平均分配）
function Transfer:pickWorkerFor(feature)
    local best = nil
    for _, worker in pairs(self.workers) do
        if not worker.busy and self:workerHas(worker, feature) and self:workerUsable(worker) then
            if not best or (worker.jobs or 0) < (best.jobs or 0) then
                best = worker
            end
        end
    end
    return best
end

--- 在频道上广播/发送一条消息
function Transfer:send(message)
    local modem = self:ensureModem()
    if not modem then
        return false
    end
    local ok, err = self.Modems.transmit(modem, self.channel, message)
    if not ok then
        self.log("IFMWorker link: transmit failed (%s)", tostring(err))
        self.modem = nil
        self.listenReady = false
        return false
    end
    return true
end

--- 把任务发给指定 worker（消息里带 target，只有它会执行）
--- 注意：job 里的 from / to 是容器外设名（worker 直接拿它们 wrap 外设），
--- 所以发信人（主控电脑号）放在 sender 字段里 —— 以前没有这个字段，worker 会把
--- “minecraft:chest_1” 当成主控的电脑号记下来（屏幕上 master 行显示成一串容器名）。
function Transfer:sendTo(worker, job)
    --- 兜一层：调用方本该先过 pickWorkerFor，这里再确认一次版本一致 ——
    --- 版本不匹配的 worker 绝不下发（用户实测“版本不匹配的 worker 还在被使用”就是这样漏出来的）
    if not self:workerUsable(worker) then
        self.log("Refusing to send job %s to worker #%s (version mismatch: worker=%s master=%s)",
            tostring(job.id), tostring(worker and worker.id),
            tostring(worker and worker.version), tostring(self.version))
        return false
    end
    return self:send({
        proto = Transfer.PROTOCOL,
        op = "job",
        target = worker.id,
        sender = os.getComputerID(),
        --- 主控版本：worker 侧也会核对，不一致就直接拒绝执行
        version = self.version,
        id = job.id,
        action = job.action,
        from = job.from,
        to = job.to,
        fromSlot = job.fromSlot,
        toSlot = job.toSlot,
        limit = job.limit,
        item = job.item,
        fluid = job.fluid,
    })
end

--- 提交/查询一个搬运任务。返回：
---   "local"                没有可用 worker：调用方自己搬（本机行为，和以前完全一样）
---   "pending"              任务已交给 worker，还没回报（也可能所有 worker 都忙）
---   "done", moved, error   任务有结果了（error 非空表示失败）
function Transfer:request(job)
    if not self:available() then
        self.stats.localMoves = self.stats.localMoves + 1
        return "local"
    end
    local key = keyOf(job)
    local existing = self.jobs[key]
    if existing then
        if existing.state == "pending" then
            return "pending"
        end
        self.jobs[key] = nil
        self.jobById[existing.id] = nil
        if existing.state == "done" then
            return "done", existing.moved or 0, existing.error
        end
        return "done", 0, existing.error or "transfer failed"
    end
    local worker = self:pickWorkerFor("move")
    if not worker then
        -- 所有 worker 都在忙（或都不支持搬运）：当作 pending（下个 tick 再试派活），绝不退回本机搬
        return "pending"
    end
    self.jobSeq = self.jobSeq + 1
    local now = os.epoch("utc")
    local record = {
        id = self.jobSeq,
        key = key,
        worker = worker.id,
        at = now,
        state = "pending",
        --- 重发要用到原始任务内容；worker 对同一个 id 是幂等的（做过的不会重复搬）
        job = job,
        sendAt = now,
        attempts = 1,
    }
    job.id = record.id
    if not self:sendTo(worker, job) then
        -- 发送失败：这条任务没交给它（不占用它的在飞位）
        return "pending"
    end
    self:setWorkerBusy(worker, true)
    self.jobs[key] = record
    self.jobById[record.id] = record
    self.stats.submitted = self.stats.submitted + 1
    return "pending"
end

--- 处理 modem 消息（由主循环的 modem_message 事件调用）
function Transfer:onModemMessage(side, channel, replyChannel, message, distance)
    if tonumber(channel) ~= self.channel or type(message) ~= "table" then
        return false
    end
    if message.proto ~= Transfer.PROTOCOL then
        return false
    end
    local now = os.epoch("utc")
    local touch = function(id, caps, name)
        local worker = self.workers[id]
        local created = false
        if not worker then
            worker = { id = id, busy = false, inFlight = 0, jobs = 0 }
            self.workers[id] = worker
            created = true
            self.log("IFMWorker #%s online", tostring(id))
        end
        worker.lastSeen = now
        if type(caps) == "table" then
            worker.caps = caps
        end
        if type(name) == "string" and name ~= "" then
            worker.name = name
        end
        return worker, created
    end
    if message.op == "hello" then
        local worker = touch(message.from, message.caps, message.name)
        -- 回 pong 告诉对方“主控在”，顺便把版本号带上（worker 会核对并在屏幕上提示版本差异）
        -- master = true：告诉 worker “这条握手来自主控”，worker 才不会把别的 worker 的 hello 当成主控
        -- （以前 worker 的屏幕 “master” 行会在 #0 与其它 worker 的电脑号之间来回跳）
        self:send({
            proto = Transfer.PROTOCOL,
            op = "pong",
            from = os.getComputerID(),
            target = message.from,
            master = true,
        })
        if not worker.welcomed then
            worker.welcomed = true
            self:send({
                proto = Transfer.PROTOCOL,
                op = "welcome",
                from = os.getComputerID(),
                target = worker.id,
                master = true,
                version = self.version,
            })
        end
        return true
    end
    if message.op == "pong" then
        touch(message.from, message.caps, message.name)
        return true
    end
    if message.op == "state" then
        -- worker 每秒上报一次：当前工作 / 能力 / 流程运行态 / 整理进度 / 中继状态
        local worker = touch(message.from, message.caps, message.name)
        self:applyWorkerState(worker, message)
        return true
    end
    if message.op == "query_ack" then
        --- worker 说“收到了，正在扫”（1.5.7 起）：记下来，超时时就能说清是哪一边的问题 ——
        --- 有 ack = 消息送到了、结果没回来（多半是回报太大被丢 / worker 屏幕上有 modem 发送错误）；
        --- 没 ack = 消息根本没到那台 worker（频道/网络/它换了电脑号）。
        local worker = touch(message.from)
        local record = self.queries[tonumber(message.id) or -1]
        if record then
            record.ack = now
        end
        worker.acked = (worker.acked or 0) + 1
        self.queryStats.acked = (self.queryStats.acked or 0) + 1
        return true
    end
    if message.op == "query_result" then
        -- worker 扫完本机外设的结果：进缓存，调用方/网页按 key 取
        local worker = touch(message.from)
        self:setWorkerBusy(worker, false)
        worker.busyKind = nil
        local id = tonumber(message.id) or -1
        local record = self.queries[id]
        if not record then
            return true
        end
        self.queries[id] = nil
        self.queryRunning[record.key] = nil
        if message.ok == false then
            self.queryStats.failed = self.queryStats.failed + 1
            self.log("IFMWorker #%s query failed: %s", tostring(worker.id), tostring(message.error))
            return true
        end
        message.key = record.key
        self.queryCache[record.key] = { at = os.epoch("utc"), result = message }
        self.queryStats.done = self.queryStats.done + 1
        -- 容器扫描卸载：把结果摊进代扫缓存（非 "scan:" 的 key 会直接忽略）
        --- 1.7.0：通知主控（写进容器快照 / 结束扫描队列任务）
        if self.onQueryResult then
            pcall(self.onQueryResult, self, record.key, message)
        end
        local stacks = #(message.items or {}) + #(message.tanks or {})
        --- 一条查询一个容器：日志里直接写容器名（旧 worker 没有 container 字段时退回 mode）
        self.log("IFMWorker #%s query %s: %d stack(s) in %sms", tostring(worker.id),
            tostring(message.container or message.mode or "?"), stacks, tostring(message.elapsed or "?"))
        return true
    end
    if message.op == "detail_result" then
        -- worker 代查回来的物品详情（getItemDetail）：先收进 detailResults，
        -- 主控每个 tick 用 takeDetailResults 取走并吸收进 Containers 的物品详情字典。
        local worker = touch(message.from)
        local id = tonumber(message.id) or -1
        local request = self.details[id]
        self.details[id] = nil
        if not self:workerHasPending(worker) then
            self:setWorkerBusy(worker, false)
            worker.busyKind = nil
        end
        if not request then
            return true                   -- 超时作废的请求：迟到的结果直接丢
        end
        --- 1.7.0：通知主控（结束 detail 队列里对应的在飞任务；字典由主控的 absorb 流程写入）
        if self.onDetailResult then
            pcall(self.onDetailResult, self, message)
        end
        if message.ok == false then
            self.detailStats.failed = self.detailStats.failed + 1
            self.log("IFMWorker #%s detail query failed: %s", tostring(worker.id), tostring(message.error))
            return true
        end
        local count = 0
        for _, entry in ipairs(type(message.details) == "table" and message.details or {}) do
            if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
                self.detailResults[#self.detailResults + 1] = entry
                count = count + 1
            end
        end
        self.detailStats.done = self.detailStats.done + 1
        self.detailStats.items = self.detailStats.items + count
        self.lastDetail = {
            worker = worker.id,
            items = count,
            elapsed = message.elapsed,
            at = os.epoch("utc"),
        }
        self.log("IFMWorker #%s item detail: %d item type(s) in %sms (cached, 0 blocking calls on the master)",
            tostring(worker.id), count, tostring(message.elapsed or "?"))
        return true
    end
    if message.op == "busy" then
        -- 我们以为它空闲、它其实正忙（刚发出去的竞态）：收回任务，下个 tick 再派。
        -- 这里不把 busy 标成 true：worker 每秒的 state 上报才是权威（否则一次误判会让它
        -- 长时间不被派活）；主控这边只是把这条任务收回来重发。
        local worker = touch(message.from)
        self:setWorkerBusy(worker, false)
        worker.busyKind = nil
        local id = tonumber(message.id) or -1
        local record = self.jobById[id]
        if record and record.state == "pending" then
            self.jobs[record.key] = nil
            self.jobById[record.id] = nil
            self.stats.busyRejected = (self.stats.busyRejected or 0) + 1
        end
        local query = self.queries[id]
        if query then
            self.queries[id] = nil
            self.queryRunning[query.key] = nil
            self.queryStats.busyRejected = self.queryStats.busyRejected + 1
            --- worker 说它正忙（我们以为它空闲——竞态）：这条查询要交回调用方本机读，
            --- 否则那个容器（或代扫分片）会一直挂在“排队”里没人管。
        end
        --- 物品详情代查同样收回（样本没进字典，调用方下一轮自然会重派）
        if self.details[id] then
            self.details[id] = nil
            self.detailStats.failed = self.detailStats.failed + 1
        end
        return true
    end
    if message.op == "done" or message.op == "error" then
        local worker = touch(message.from)
        local record = self.jobById[tonumber(message.id) or -1]
        if not record then
            return true
        end
        if record.state ~= "pending" then
            -- 已经作废（超时/掉线）的任务：忽略迟到的结果
            self.jobById[record.id] = nil
            return true
        end
        worker.jobs = (worker.jobs or 0) + 1
        self:setWorkerBusy(worker, false)
        record.moved = tonumber(message.moved) or 0
        record.error = message.error
        record.state = message.op == "done" and "done" or "failed"
        if record.state == "done" then
            self.stats.done = self.stats.done + 1
        else
            self.stats.failed = self.stats.failed + 1
        end
        return true
    end
    return false
end

--- 周期任务：广播 hello 让 worker 报到、清理掉线 worker、任务超时作废
function Transfer:tick(now)
    now = now or os.epoch("utc")
    self:ensureModem()
    if self.modem and now - (self.helloAt or 0) >= HELLO_INTERVAL then
        self.helloAt = now
        -- master = true：worker 靠它区分“主控的 hello”与“别的 worker 的 hello”（见 IFMWorker.lua 的 isWorkerHandshake）
        self:send({
            proto = Transfer.PROTOCOL,
            op = "hello",
            from = os.getComputerID(),
            channel = self.channel,
            master = true,
        })
    end
    --- worker 掉线：它手上的任务作废（引擎下个 tick 会看到失败原因并重试）
    for id, worker in pairs(self.workers) do
        if now - (worker.lastSeen or 0) > WORKER_TIMEOUT then
            self.workers[id] = nil
            self.log("IFMWorker #%s%s offline (no message for %dms) - its pending moves were dropped and will be retried",
                tostring(id), self:workerLabel(worker), WORKER_TIMEOUT)
            for _, job in pairs(self.jobs) do
                if job.worker == id and job.state == "pending" then
                    job.state = "failed"
                    job.error = "IFMWorker offline"
                    self.stats.failed = self.stats.failed + 1
                end
            end
            --- 它手上的查询（含容器代扫）同样作废：否则这些 key 会永远占着（查询没有回报就没人清）
            for queryId, query in pairs(self.queries) do
                if query.worker == id then
                    self.queries[queryId] = nil
                    self.queryRunning[query.key] = nil
                    self.queryStats.failed = self.queryStats.failed + 1
                end
            end
            --- 它手上的物品详情代查也一样（样本没进字典，调用方下一轮自然会重派）
            for detailId, request in pairs(self.details) do
                if request.worker == id then
                    self.details[detailId] = nil
                    self.detailStats.failed = self.detailStats.failed + 1
                end
            end
        end
    end
    --- 查询超时：worker 没回报（消息丢了 / 它自己重启 / 卡住了）→ 作废这个查询并释放 worker。
    --- 释放的这一步很关键：以前没有查询超时，一次丢包就会让那台 worker 永远显示「工作中」、
    --- 再也收不到任何活（容器代扫也就静默退回主控本机读）。
    --- 查询重发与超时：无线链路偶发丢包时，先把同一条查询重发几次（worker 幂等）；
    --- 仍然没有结果才作废，并把该容器交回本机读。
    for queryId, query in pairs(self.queries) do
        local worker = self.workers[query.worker]
        local age = now - (query.at or 0)
        --- 重发：距上次发送（或上次重发）超过 QUERY_RESEND_MS 且还有重发额度
        if worker and (query.attempts or 1) <= QUERY_RESEND_MAX and
            now - (query.sendAt or query.at or 0) >= QUERY_RESEND_MS then
            if self:sendQuery(worker, query.id, query.spec or {}) then
                query.attempts = (query.attempts or 1) + 1
                query.sendAt = now
                self.queryStats.resent = (self.queryStats.resent or 0) + 1
                --- 重发时也把 worker 的 busy 重新标上：这次是真的在等它回音
                if not self:workerHasPending(worker) then
                    self:setWorkerBusy(worker, true)
                    worker.busyKind = "query"
                end
            end
        end
        if age > QUERY_TIMEOUT then
            self.queries[queryId] = nil
            self.queryRunning[query.key] = nil
            self.queryStats.failed = self.queryStats.failed + 1
            if worker and not self:workerHasPending(worker) then
                self:setWorkerBusy(worker, false)
                worker.busyKind = nil
                worker.timeouts = (worker.timeouts or 0) + 1
            end
            if now - (self.lastQueryTimeoutLogAt or 0) >= 30000 then
                self.lastQueryTimeoutLogAt = now
                local isScan = string.match(tostring(query.key or ""), "^scan:") ~= nil
                local hint
                if query.ack then
                    hint = " (it acknowledged the request, so only the reply got lost - check that worker's screen " ..
                        "for 'modem send failed')"
                else
                    hint = " (no ack: the request may not have reached that worker - check its channel/network)"
                end
                self.log("IFMWorker #%s%s did not answer query #%s within %dms (%d attempt(s) incl. resends) - " ..
                    "dropped so it can be used again%s",
                    tostring(query.worker), self:workerLabel(worker), tostring(query.id or 0), QUERY_TIMEOUT,
                    query.attempts or 1, hint)
                if isScan then
                    self.log("IFMWorker scan: that container is read by the master this round and retried later " ..
                        "(one query per container now, so a slow container no longer blocks the others)")
                end
            end
        end
    end
    --- 物品详情代查的重发与超时：与查询同一套思路（worker 对同一个 id 幂等）。
    --- 超时不必交回本机读 —— 样本根本没进物品字典，调用方下一轮自然会重新请求。
    for detailId, request in pairs(self.details) do
        local worker = self.workers[request.worker]
        local age = now - (request.at or 0)
        if worker and (request.attempts or 1) <= QUERY_RESEND_MAX and
            now - (request.sendAt or request.at or 0) >= DETAIL_RESEND_MS then
            if self:sendDetail(worker, request) then
                request.attempts = (request.attempts or 1) + 1
                request.sendAt = now
                self.detailStats.resent = (self.detailStats.resent or 0) + 1
            end
        end
        if age > DETAIL_TIMEOUT then
            self.details[detailId] = nil
            self.detailStats.failed = self.detailStats.failed + 1
            if worker and not self:workerHasPending(worker) then
                self:setWorkerBusy(worker, false)
                worker.busyKind = nil
            end
            if now - (self.lastDetailTimeoutLogAt or 0) >= 30000 then
                self.lastDetailTimeoutLogAt = now
                self.log("IFMWorker #%s%s did not answer the item detail request #%s within %dms - " ..
                    "those %d item(s) are read by the master this round and retried later",
                    tostring(request.worker), self:workerLabel(worker), tostring(request.id or 0),
                    DETAIL_TIMEOUT, #(request.samples or {}))
            end
        end
    end
    for _, job in pairs(self.jobs) do
        if job.state == "pending" then
            local worker = self.workers[job.worker]
            --- 搬运也重发：worker 对同一个 id 幂等（做过的直接重发上次结果，不会重复搬）
            if worker and job.job and (job.attempts or 1) <= JOB_RESEND_MAX and
                now - (job.sendAt or job.at or 0) >= JOB_RESEND_MS then
                if self:sendTo(worker, job.job) then
                    job.attempts = (job.attempts or 1) + 1
                    job.sendAt = now
                    self.stats.resent = (self.stats.resent or 0) + 1
                end
            end
        end
    end
    for _, job in pairs(self.jobs) do
        if job.state == "pending" and now - (job.at or 0) > JOB_TIMEOUT then
            --- 超时：交出 worker，任务作废（迟到的结果会被忽略；引擎下个 tick 会用新任务号重试）
            job.state = "failed"
            job.error = "IFMWorker job timeout"
            self.stats.timedOut = self.stats.timedOut + 1
            local worker = self.workers[job.worker]
            if worker then
                self:setWorkerBusy(worker, false)
                worker.timeouts = (worker.timeouts or 0) + 1
            end
            -- 日志把“是谁、等了多久、哪次搬运”都写清楚：这样不用翻网页就知道该去哪台机器上看
            self.log("IFMWorker #%s%s did not answer job #%s within %dms (%s) - dropped, the engine will retry; " ..
                "check that worker's screen (wired modem required) and its cable",
                tostring(job.worker), self:workerLabel(worker), tostring(job.id or 0), JOB_TIMEOUT, tostring(job.key))
        elseif job.state ~= "pending" and now - (job.at or 0) > JOB_TIMEOUT then
            --- 已经出结果但没人来取（引擎那边放弃了这次搬运）：直接清掉，别让表一直涨
            self.jobs[job.key] = nil
            self.jobById[job.id] = nil
        end
    end
end

-- ===================== 分布式（1.5.0）：worker 只做「搬运」与「查询」=====================
-- 这里只保留：上下文（version 核对）、能力查询、查询派发/取回。
-- 流程分配（engine）、存储整理（compact）、中继代连（WebSocket）在 1.5.0 已彻底移除：
-- 这三件事一律由主控本机执行，worker 掉线不会影响它们。
--- 主控上下文（IFMMaster.lua 在其它模块都建好之后调用一次；现在只需要版本号）
function Transfer:setContext(ctx)
    ctx = ctx or {}
    self.version = ctx.version
end

--- 具备某种能力的在线 worker（按已完成任务数排序，尽量均衡）；
--- 版本与主控不一致的 worker 一律排除（它们不参与作业，见 workerUsable）
function Transfer:capableWorkers(feature)
    local out = {}
    for _, worker in pairs(self.workers) do
        if self:workerHas(worker, feature) and self:workerUsable(worker) then
            out[#out + 1] = worker
        end
    end
    table.sort(out, function(a, b)
        if (a.jobs or 0) ~= (b.jobs or 0) then
            return (a.jobs or 0) < (b.jobs or 0)
        end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

-- ===== 查询（物品/流体）：主控要“容器里有什么 / 某物品在哪些容器里各有多少”时用 =====
--- 把一条查询发给指定 worker
--- （query 里的 containers 是外设名清单，from 这里用作发信人：与 job 不同，注意别混）
function Transfer:sendQuery(worker, id, spec)
    --- 版本不一致的 worker 不派查询（worker 侧也会拒绝，这里是第一道闸）
    if not self:workerUsable(worker) then
        return false
    end
    return self:send({
        proto = Transfer.PROTOCOL,
        op = "query",
        target = worker.id,
        sender = os.getComputerID(),
        --- 主控版本：worker 侧核对，不一致直接拒绝执行
        version = self.version,
        id = id,
        --- 一条查询只查一个容器（worker 只认这个字段，见 IFMWorker.lua 的 runQuery）
        container = spec.container,
        names = spec.names,
        limit = spec.limit,
        from = os.getComputerID(),
    })
end

--- 提交一条查询（spec.container = 要查的容器外设名，可选 names/limit，key 用于缓存）。返回：
---   "local"          没有可用 worker（调用方自己做本机扫描）
---   "pending"        已派给 worker（或已有同 key 的查询在飞），结果用 queryResult(key) 取
---   "done", result   缓存命中（self.queryTtl 内）
function Transfer:requestQuery(spec)
    spec = spec or {}
    local now = os.epoch("utc")
    local key = spec.key or ("q:" .. tostring(spec.container or "items") .. ":" .. tostring(now))
    local cached = self.queryCache[key]
    if cached and now - cached.at <= self.queryTtl then
        return "done", cached.result
    end
    if self.queryRunning[key] then
        return "pending"
    end
    if not self:available() then
        return "local"
    end
    local worker = self:pickWorkerFor("query")
    if not worker then
        -- 有 worker 但都在忙 / 都不支持查询：当作 pending，调用方下个 tick 再问
        return "pending"
    end
    self.querySeq = self.querySeq + 1
    local id = self.querySeq
    if not self:sendQuery(worker, id, spec) then
        return "pending"
    end
    self:setWorkerBusy(worker, true)
    worker.busyKind = "query"
    self.queryRunning[key] = id
    self.queries[id] = { id = id, key = key, worker = worker.id, at = now, spec = spec }
    self.queryStats.submitted = self.queryStats.submitted + 1
    return "pending"
end

--- 提交一次"扫描某个容器"的请求（1.7.0：由 storageScan / inputScan 队列调用）。返回：
---   "done", result   最近 scanFreshMs 内已经扫过（result 是 query_result 消息）
---   "pending"        已经派给 worker（结果回来时由 Transfer.onQueryResult 通知）
---   "local"          没有可用的查询 worker：调用方本机读
function Transfer:submitScan(name, freshMs)
    if type(name) ~= "string" or name == "" then
        return "local"
    end
    local key = "scan:" .. name
    local now = os.epoch("utc")
    local cached = self.queryCache[key]
    if cached and cached.result and now - tonumber(cached.result.at or cached.at or 0) <= (tonumber(freshMs) or self.scanFreshMs or 500) then
        return "done", cached.result
    end
    if self.queryRunning[key] then
        return "pending"
    end
    if not self:available() then
        return "local"
    end
    return self:requestQuery({ container = name, key = key })
end

--- 取某个 key 的查询结果（已经回报过才有）
function Transfer:queryResult(key)
    local cached = self.queryCache[key]
    if not cached then
        return nil
    end
    return cached.result
end

--- 查询状态（网页/诊断）
function Transfer:queryStatus()
    return {
        queriers = #self:capableWorkers("query"),
        submitted = self.queryStats.submitted,
        done = self.queryStats.done,
        failed = self.queryStats.failed,
        busyRejected = self.queryStats.busyRejected,
        acked = self.queryStats.acked or 0,
        pending = self:queryPendingCount(),
        last = self.lastQuery,
    }
end

--- 还有多少个查询在飞
function Transfer:queryPendingCount()
    local count = 0
    for _ in pairs(self.queryRunning) do
        count = count + 1
    end
    return count
end

-- ===== 物品详情卸载：worker 代查 getItemDetail =====
-- 为什么必须卸载：getItemDetail 是阻塞的外设调用（有线网络上 ≈1 个服务器刻/次，
-- 与 list() 同一量级）。整理计划要为每种物品问一次 maxCount、标签扫描要为每种物品问一次
-- tags —— 几百种物品就是几百个服务器刻，全部压在主控身上会让主控明显卡顿（网页推送、
-- 引擎 tick 都被拖慢）。worker 就挂在同一批容器旁边，让它们读，主控只等 modem 消息。
--
-- 一条请求带一批样本（DETAIL_BATCH 个），worker 一次做完：
--   samples = { { container = 外设名, slot = 槽位, name = 物品名, nbt = ... }, ... }
-- 返回值（Containers:requestItemDetails 的约定）：
--   "pending"  已经派给 worker：结果回来后主控 absorbItemDetails 进物品详情字典
--   "local"    没有可用 worker（或都在忙）：调用方本机读，或者下个 tick 再试
function Transfer:sendDetail(worker, request)
    return self:send({
        proto = Transfer.PROTOCOL,
        op = "detail",
        version = self.version,
        target = worker.id,
        sender = os.getComputerID(),
        id = request.id,
        samples = request.samples,
        from = os.getComputerID(),
    })
end

function Transfer:detailRequest(samples)
    if type(samples) ~= "table" or #samples == 0 then
        return "local"
    end
    if not self:available() then
        return "local"
    end
    local batch = {}
    for _, sample in ipairs(samples) do
        if #batch >= DETAIL_BATCH then
            break
        end
        if type(sample) == "table" and type(sample.name) == "string" and sample.name ~= "" then
            batch[#batch + 1] = {
                container = sample.container,
                slot = sample.slot,
                name = sample.name,
                nbt = sample.nbt,
            }
        end
    end
    if #batch == 0 then
        return "local"
    end
    local worker = self:pickWorkerFor("query")
    if not worker then
        return "local"                    -- 都在忙：调用方本机读（少量）或下个 tick 再试
    end
    self.detailSeq = self.detailSeq + 1
    local request = { id = self.detailSeq, worker = worker.id, at = os.epoch("utc"), samples = batch }
    if not self:sendDetail(worker, request) then
        return "local"
    end
    self:setWorkerBusy(worker, true)
    worker.busyKind = "detail"
    request.sendAt = os.epoch("utc")
    self.details[request.id] = request
    self.detailStats.submitted = self.detailStats.submitted + 1
    return "pending"
end

--- 主控取走（并清空）worker 代查回来的物品详情：由 IFMMaster 每个 tick 吸收进 Containers。
--- 返回 entries = { { name, nbt, detail = {...}, container, slot }, ... }
function Transfer:takeDetailResults()
    local out = self.detailResults
    self.detailResults = {}
    return out
end

--- 还有多少条详情代查在飞
function Transfer:detailPendingCount()
    local count = 0
    for _ in pairs(self.details) do
        count = count + 1
    end
    return count
end

--- 物品详情代查的状态（诊断 / 网页）
function Transfer:detailStatus()
    return {
        queriers = #self:capableWorkers("query"),
        submitted = self.detailStats.submitted,
        done = self.detailStats.done,
        failed = self.detailStats.failed,
        items = self.detailStats.items,
        pending = self:detailPendingCount(),
        last = self.lastDetail,
    }
end

--- ===== 容器扫描卸载（worker 代读容器）=====
-- 背景：主控自己读一遍全部容器 ≈ 1 个服务器刻/个（有线网络上一次 list() ≈50ms），
-- 19 个容器就是 ~950ms —— 这部分开销以前全压在主控身上（引擎 tick / 网页推送都被拖慢），
-- 而 worker 就挂在同一批容器旁边、并行读也没人抢它的时间片。
--
-- 限流（1.6.7）：worker 是同时干搬运与查询的。以前一批代扫把 19 个容器一条接一条派出去，
-- worker 几乎永远在扫容器（用户实测），搬运请求只能干等。现在每个 tick 最多派 scanPerTick 条，
-- 并且同一台 worker 两次代扫之间要留出冷却空档（见 scanCooldown / scanIdleCooldown）。
--
-- 接口（由 modules/containers.lua 的 listPeripheral / tanksPeripheral 调用）：
--     "local"                                     没有可查询的 worker（调用方本机读，行为同以前）













--- worker 的 state 上报：更新注册表（worker 只报搬运 / 查询相关的东西）
function Transfer:applyWorkerState(worker, message)
    worker.stateAt = os.epoch("utc")
    -- 版本核对：worker 跑的代码最好和主控一致，不一致会在日志里明确写出来（便于排错）
    if type(message.version) == "string" then
        if worker.version ~= message.version then
            worker.version = message.version
            self.log("IFMWorker #%s reports version %s", tostring(worker.id), tostring(message.version))
        end
        if self.version and message.version ~= self.version then
            --- 版本不一致的 worker 不参与作业（pickWorkerFor / available 都会把它排除），
            --- 网页上也会把它的版本号标红提示 —— 请把同一份产物复制到那台电脑。
            self.log("IFMWorker #%s version mismatch: worker %s vs server %s - it will NOT be used for " ..
                "moves/queries; copy the same build to that computer", tostring(worker.id),
                tostring(message.version), tostring(self.version))
        end
    end
    if not worker.firstStateLogged then
        worker.firstStateLogged = true
        self.log("IFMWorker #%s state received: move=%s query=%s counters: jobs=%s moved=%s queries=%s",
            tostring(worker.id), tostring(self:workerHas(worker, "move")), tostring(self:workerHas(worker, "query")),
            tostring(message.jobs), tostring(message.moved), tostring(message.queries))
        if tonumber(message.jobs) == nil or tonumber(message.queries) == nil then
            self.log("IFMWorker #%s reports no counters (old build?) - the web UI would show 0; copy the same " ..
                "build to that computer", tostring(worker.id))
        end
    end
    worker.tasks = message.tasks
    --- 计数只在 worker 真的报了数字时才更新：某些情况下（旧版本 worker / 字段缺失）报文里没有
    --- jobs/queries，以前会把主控这边记着的计数清零，网页上就变成“搬 0（0 个）· 查询 0”，
    --- 看起来像 worker 没干活。
    local function counter(name)
        local value = tonumber(message[name])
        if value ~= nil then
            worker[name] = value
        elseif worker[name] == nil then
            worker[name] = 0
        end
        return worker[name]
    end
    counter("jobs")
    counter("moved")
    counter("queries")
    counter("details")
    counter("detailItems")
    worker.busyKind = message.busyKind
    worker.lastQuery = message.lastQuery
    --- busy 以 worker 自己上报的为准（主控没有在飞任务时）：
    --- 主控只是“发出去时先标记为忙”，万一回报丢了（modem 丢包 / worker 重启），
    --- 这个标记就会一直挂着 —— 网页显示「工作中」却看不到任务，而且再也不会派活给它。
    --- 这里用 worker 的 state（每秒一次）把它纠正回来；真有在飞任务时不动（等超时处理）。
    if message.busy ~= nil and not self:workerHasPending(worker) then
        local reported = message.busy == true
        if worker.busy ~= reported then
            self:setWorkerBusy(worker, reported)
            if not reported then
                worker.busyKind = nil
            end
        end
    end
    if type(message.lastQuery) == "table" then
        self.lastQuery = {
            worker = worker.id,
            mode = message.lastQuery.mode,
            --- 一条查询只查一个容器：记下是哪个容器，网页上直接显示容器名
            container = message.lastQuery.container,
            at = message.lastQuery.at,
            elapsed = message.lastQuery.elapsed,
            stacks = message.lastQuery.stacks,
            scanned = message.lastQuery.scanned,
        }
    end
end

--- 给网页的 worker 列表（每台 worker 的能力 / 当前工作 / 计数）
function Transfer:workersForUi()
    local now = os.epoch("utc")
    local out = {}
    for _, worker in pairs(self.workers) do
        local pending = 0
        for _, job in pairs(self.jobs) do
            if job.worker == worker.id and job.state == "pending" then
                pending = pending + 1
            end
        end
        local pendingQueries = 0
        for _, query in pairs(self.queries) do
            if query.worker == worker.id then
                pendingQueries = pendingQueries + 1
            end
        end
        out[#out + 1] = {
            id = worker.id,
            name = worker.name or ("worker-#" .. tostring(worker.id)),
            move = self:workerHas(worker, "move"),
            query = self:workerHas(worker, "query"),
            tasks = worker.tasks or {},
            jobs = worker.jobs or 0,
            moved = worker.moved or 0,
            queries = worker.queries or 0,
            details = worker.details or 0,
            detailItems = worker.detailItems or 0,
            busy = worker.busy and true or false,
            busyKind = worker.busyKind,
            lastQuery = worker.lastQuery,
            pending = pending,
            pendingQueries = pendingQueries,
            age = math.floor((now - (worker.lastSeen or now)) / 1000),
            --- 「多久没听到这台 worker 的任何消息」——state 上报、查询回报、搬运回报都算。
            --- 以前只看 stateAt：只要某次 state 报文丢在路上（无线链路很常见），
            --- 网页就会把它显示成「失联」，可它其实一直在正常回报查询结果（1.6.4 修）。
            stateAge = math.floor((now - math.max(worker.stateAt or 0, worker.lastSeen or 0)) / 1000),
            --- 由主控统一判定“是不是真掉线”（阈值与摘除它的 WORKER_TIMEOUT 完全一致）：
            --- 网页直接用这个字段，就不会出现“网页说失联、主控还在用它干活”的矛盾
            stale = (now - math.max(worker.stateAt or 0, worker.lastSeen or 0)) > WORKER_TIMEOUT,
            version = worker.version,
            --- 版本与主控不一致：它不参与作业，网页上版本号标红提示（见 workerUsable）
            versionMismatch = (self.version ~= nil and type(worker.version) == "string" and
                worker.version ~= "" and worker.version ~= self.version) and true or false,
            usable = self:workerUsable(worker),
        }
    end
    table.sort(out, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end


return Transfer
