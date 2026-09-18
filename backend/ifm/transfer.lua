-- IFM :: ifm/transfer.lua
-- IFMWorker 调度（1.5.0）：worker 只做两件事 —— 「物品/流体搬运」与「物品/流体查询」。
-- 流程（engine）、存储整理（compact）、网页中继（WebSocket）**一律由主控自己执行**，
-- 所以 worker 掉线既不会影响流程推进，也不会让网页失联。
--
-- 节点发现（discovery）
--   * 主控每隔 HELLO_INTERVAL(3s) 在 self.channel 广播 { op = "hello" }（Transfer:tick）；
--   * worker 收到 hello 立刻回 { op = "pong", name, caps }；另外 worker 自己每 5s 也会主动广播一次
--     hello（主控重启后不用等它广播就能发现它）；
--   * 来自某台 worker 的**任何**消息都会刷新 worker.lastSeen（见 touch()），超过 WORKER_TIMEOUT(12s)
--     没有任何消息 → 从 self.workers 移除，它手上的搬运任务作废（引擎下个 tick 会重试）。
--   结果表 self.workers：id -> { id, name, caps, lastSeen, busy, jobs, moved, queries, stateAt, ... }，
--   能力 caps 由 worker 上报：{ move = true, query = true }（老版本 worker 只会上报搬运）。
--
-- 任务分发（dispatch）
--   搬运：引擎每 tick 调 Transfer:request(job)（job 带 from/to/slot/limit…）——
--     0 台可用 worker            → 返回 "local"，本机自己搬（与没有分布式时完全一致）
--     挑到空闲且支持 move 的 worker → 发 { op = "job", target = <id> }，返回 "pending"
--     有 worker 但都在忙          → 也返回 "pending"（下个 tick 用**同一个任务键**再问一次），
--                                   绝不退回本机搬（避免同一次搬运被两处执行）
--   同一个 key 的任务只提交一次；worker 回 done/error 后才有真实结果（引擎那边仍是“等搬运完成”的语义）。
--   每台 worker 同一时间只做一个任务（它自己会用 busy 拒绝并发任务），所以多台 worker 天然并行。
--   查询：主控调 Transfer:requestQuery(spec)（spec = container/names/limit，key 用于缓存）——
--     **一条查询只查一个容器**（container = 容器外设名）；要刷新一批容器时由 startScanBatch
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
--- 查询/搬运是无线 modem 发的，偶发丢包很正常：这么久还没回音就**重发同一个 id**
--- （worker 侧对同一个 id 是幂等的：做过的直接重发上次结果，绝不会重复扫描/搬运）
local QUERY_RESEND_MS = 3000
local QUERY_RESEND_MAX = 2      -- 最多再发 2 次（共 3 次尝试），仍无回音就作废、交回本机读
local JOB_RESEND_MS = 4000      -- 搬运任务的重发间隔（worker 幂等，重复发不会重复搬）
local JOB_RESEND_MAX = 2
--- 查询没有超时会留下“永久 busy”的 worker：主控以为它还在扫，网页上就显示成
--- 「工作中」但看不到任何任务，而且再也不会派活给它（扫描默默退回主控本机读）。
local SCAN_TTL = 3000           -- worker 代扫到的容器内容多久内算“新鲜”（毫秒；调用方可以要求更久，见 scanTtlMax）
local SCAN_TTL_MAX = 20000      -- 代扫结果最长算新鲜多久（上限，避免数据旧得离谱）
--- 一批代扫任务“没有任何进展”多久后作废（避免 scanBatches 一直涨）。
--- 每完成 / 失败一片都会顺延（见 absorbScanResult / failScanSlice）：一整批 60 个容器在多台 worker
--- 上可能要跑十几秒，用固定的“批次创建时间 + TTL”会把还在正常推进的批次提前丢掉。
local SCAN_BATCH_TTL = 15000
local SCAN_FAIL_LIMIT = 3       -- 连续失败几次就暂停派活一段时间（免得每次都要干等超时、主控一直在本机兜底）
local SCAN_PAUSE_MS = 60000     -- 连续失败后暂停派活多久（之后自动再试）
--- ===== 物品详情卸载（worker 代查 getItemDetail，见 Transfer:detailRequest）=====
--- getItemDetail 与 list() 一样是**阻塞**的外设调用（有线网络上 ≈1 个服务器刻/次）：
--- 整理计划要为每种物品问一次 maxCount、标签扫描要为每种物品问一次 tags，
--- 而 19 个容器里可能有几百种物品 —— 全压在主控身上就是几百个服务器刻（主控会明显卡住）。
--- 打包交给 worker 之后，主控只等 modem 消息（结果进 Containers 的物品详情字典）。
local DETAIL_BATCH = 8          -- 一次请求最多带几个样本（worker 一口气做完，别把它占太久）
local DETAIL_TIMEOUT = 8000     -- 多久没回报就作废（样本没进字典，调用方下一轮自然会重派）
local DETAIL_RESEND_MS = 2500   -- 重发间隔（worker 对同一个 id 幂等）
--- ===== 代扫限流（1.6.7）=====
--- 以前一批代扫会把 19 个容器**一条接一条**全派出去，worker 几乎永远在处理扫描任务：
--- 引擎的搬运请求只能等它空出来（用户实测：worker 几乎总是被扫描任务占据，搬运被拖慢）。
--- 现在两条限制：
---   * 每个 tick 最多派 SCAN_PER_TICK 条代扫；
---   * 同一台 worker 两次代扫之间至少隔 scanCooldownMs（默认 500ms；工厂里还有搬运在排队时
---     用这个值，没别的活时才用 scanIdleCooldownMs）—— 空档就是留给搬运与别的查询的。
local SCAN_PER_TICK = 1
local SCAN_COOLDOWN = 500
local SCAN_IDLE_COOLDOWN = 120

function Transfer.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transfer)
    self.log = opts.log or function() end
    self.Peripherals = opts.Peripherals
    --- modem 发现 / 包装 / 发消息：与 IFMWorker.lua 共用 ifm/modems.lua（不再各写一份）
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
    -- ===== 容器扫描卸载：worker 代读主控的容器 =====
    -- 主控读一遍全部容器要 1 个服务器刻/个（19 个 ≈950ms），这是“主控运行缓慢”的最大来源；
    -- worker 就在同一批容器旁边，读一遍对主控零成本（只等 modem 消息）。详见 Transfer:scanRequest。
    self.scanTtl = opts.scanTtl or SCAN_TTL       -- 代扫结果多久内算新鲜（调用方可以要求更久）
    self.scanTtlMax = opts.scanTtlMax or SCAN_TTL_MAX  -- 但最多算这么久（上限）
    self.scanCache = {}                           -- 外设名 -> { at, slots = {槽位表}, tanks = {储罐表} }
    self.scanOwner = {}                           -- 外设名 -> 覆盖它的批次号（在飞时用）
    self.scanBatches = {}                         -- 批次号 -> { at, pending, slices = { {key, names, state} } }
    self.scanSeq = 0
    self.scanLogAt = 0
    --- 连续失败（超时 / 报错 / worker 看不到容器）到 SCAN_FAIL_LIMIT 次就暂停派活 SCAN_PAUSE_MS，
    --- 期间 scanRequest 直接返回 "local"（主控本机读），不再每次干等 15 秒超时。
    self.scanFailStreak = 0
    self.scanPausedUntil = 0
    --- 没派出去的分片（有 worker 但当时都在忙）：批次号 -> true，Transfer:tick 里补派
    self.scanQueue = {}
    self.scanWarnAt = 0                           -- 诊断日志节流（“worker 一个容器都没看到”）
    self.scanStats = { batches = 0, requests = 0, hits = 0, pending = 0, localOnly = 0,
        containers = 0, failed = 0, subQueries = 0, paused = 0, blind = 0, queued = 0,
        throttled = 0 }
    --- 代扫限流（见文件顶部 SCAN_* 常量）：一个 tick 派出去的条数 + 每台 worker 上次代扫的时间
    self.scanPerTick = opts.scanPerTick or SCAN_PER_TICK
    self.scanCooldown = opts.scanCooldown or SCAN_COOLDOWN
    self.scanIdleCooldown = opts.scanIdleCooldown or SCAN_IDLE_COOLDOWN
    self.scanDispatchAt = 0
    self.scanDispatchCount = 0
    -- ===== 物品详情卸载：worker 代查 getItemDetail（见 Transfer:detailRequest）=====
    self.detailSeq = 0
    self.details = {}                     -- id -> { id, worker, at, sendAt, attempts, samples }
    self.detailResults = {}               -- 回报进来、还没被主控吸收的详情（takeDetailResults）
    self.detailStats = { submitted = 0, done = 0, failed = 0, items = 0 }
    self.lastDetail = nil                 -- 最近一次详情回报的摘要（诊断用）
    return self
end

--- 找到 modem 外设（有线优先；具体实现见 ifm/modems.lua，worker 用的是同一份）
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
--- 注意：**版本和主控不一致的 worker 不算可用** —— 协议/行为必须两边一致，
--- 否则会出现“明明有 worker，主控却把活交出去、结果没人做”的局面（网页上它们会被标红提示）。
function Transfer:workerUsable(worker)
    if type(worker) ~= "table" then
        return false
    end
    --- 主控自己都不知道版本（理论上不该发生）：**一律不派活** ——
    --- 以前这里返回 true，等于“版本没设好时所有 worker 都能用”，版本不匹配就拦不住了。
    if not self.version then
        if not self.versionMissingLogged then
            self.versionMissingLogged = true
            self.log("Master version is not set (setContext was never called): workers are disabled")
        end
        return false
    end
    --- 还没上报过版本（刚连上、或老版本 worker 不会报）→ 先不用它，等它的 state 到了再说
    if type(worker.version) ~= "string" or worker.version == "" then
        return false
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
        pending = self:pendingCount(),
        queries = self.queryStats,
        queriesPending = self:queryPendingCount(),
        details = self.detailStats,
        detailsPending = self:detailPendingCount(),
        lastQuery = self.lastQuery,
        scan = self:scanStatus(),
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
--- 注意：job 里的 from / to 是**容器外设名**（worker 直接拿它们 wrap 外设），
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
        worker.busy = false
        return "pending"
    end
    worker.busy = true
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
            worker = { id = id, busy = false, jobs = 0 }
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
        worker.busy = false
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
            self:failScanSlice(record.key)     -- 代扫分片失败：交回调用方本机读
            self.log("IFMWorker #%s query failed: %s", tostring(worker.id), tostring(message.error))
            return true
        end
        message.key = record.key
        self.queryCache[record.key] = { at = os.epoch("utc"), result = message }
        self.queryStats.done = self.queryStats.done + 1
        -- 容器扫描卸载：把结果摊进代扫缓存（非 "scan:" 的 key 会直接忽略）
        self:absorbScanResult(record.key, message)
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
            worker.busy = false
            worker.busyKind = nil
        end
        if not request then
            return true                   -- 超时作废的请求：迟到的结果直接丢
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
        -- 我们以为它空闲、它其实正忙（刚发出去的竞态）：收回任务，下个 tick 再派
        local worker = touch(message.from)
        worker.busy = false
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
            self:failScanSlice(query.key)
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
        worker.busy = false
        worker.jobs = (worker.jobs or 0) + 1
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
                    self:failScanSlice(query.key)
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
                    worker.busy = true
                    worker.busyKind = "query"
                end
            end
        end
        if age > QUERY_TIMEOUT then
            self.queries[queryId] = nil
            self.queryRunning[query.key] = nil
            self.queryStats.failed = self.queryStats.failed + 1
            if worker and not self:workerHasPending(worker) then
                worker.busy = false
                worker.busyKind = nil
                worker.timeouts = (worker.timeouts or 0) + 1
            end
            self:failScanSlice(query.key)
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
                worker.busy = false
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
                worker.busy = false
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
    --- 分布式维护：流程分配、中继代连、定义补发（见 maintainWorkers）
    self:maintainWorkers(now)
    --- 容器扫描卸载：清掉过期的代扫批次 + 补派“当时 worker 都在忙、没能发出去”的分片
    self:pruneScanBatches(now)
    self:dispatchScanQueue(now)
end

-- ===================== 分布式（1.5.0）：worker 只做「搬运」与「查询」=====================
-- 这里只保留：上下文（version 核对）、能力查询、查询派发/取回。
-- 流程分配（engine）、存储整理（compact）、中继代连（WebSocket）在 1.5.0 已**彻底移除**：
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
    worker.busy = true
    worker.busyKind = "query"
    self.queryRunning[key] = id
    self.queries[id] = { id = id, key = key, worker = worker.id, at = now, spec = spec }
    self.queryStats.submitted = self.queryStats.submitted + 1
    return "pending"
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
-- 为什么必须卸载：getItemDetail 是**阻塞**的外设调用（有线网络上 ≈1 个服务器刻/次，
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
    worker.busy = true
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
-- 限流（1.6.7）：worker 是**同时**干搬运与查询的。以前一批代扫把 19 个容器一条接一条派出去，
-- worker 几乎永远在扫容器（用户实测），搬运请求只能干等。现在每个 tick 最多派 scanPerTick 条，
-- 并且同一台 worker 两次代扫之间要留出冷却空档（见 scanCooldown / scanIdleCooldown）。
--
-- 接口（由 ifm/containers.lua 的 listPeripheral / tanksPeripheral 调用）：
--   Transfer:scanRequest(name, names)
--     "done", { slots = 槽位表, tanks = 储罐表 }  worker 刚扫过（scanTtl 内）
--     "pending"                                   已经派活/正在扫（调用方先用旧值顶着）
--     "local"                                     没有可查询的 worker（调用方本机读，行为同以前）
--   Transfer:invalidateScan(name)  某个容器内容被改（搬运）：作废它的代扫结果，强制重扫
function Transfer:hasQueryWorker()
    return #self:capableWorkers("query") > 0
end

--- 现在可以再派一条代扫吗？（见文件顶部 SCAN_* 说明）
---   * 本 tick 已经派够 scanPerTick 条 → 不派（下个 tick 再派）；
---   * 所有能查询的 worker 都在冷却期内 → 不派（空档留给搬运/别的查询）。
--- 工厂里还有搬运在排队时用较长的冷却（scanCooldown），闲时用短的（scanIdleCooldown）。
function Transfer:scanDispatchAllowed(now)
    now = now or os.epoch("utc")
    if self.scanDispatchAt ~= now then
        self.scanDispatchAt = now
        self.scanDispatchCount = 0
    end
    if (self.scanDispatchCount or 0) >= (self.scanPerTick or SCAN_PER_TICK) then
        return false
    end
    local busy = self:pendingCount() > 0
    local cooldown = busy and (self.scanCooldown or SCAN_COOLDOWN) or (self.scanIdleCooldown or SCAN_IDLE_COOLDOWN)
    for _, worker in ipairs(self:capableWorkers("query")) do
        if now - (worker.lastScanAt or 0) >= cooldown then
            return true
        end
    end
    return false
end

--- 派出一条代扫分片（记限流记账 + 记住是哪台 worker 扫的）。
--- 返回 requestQuery 的返回值（"pending" / "local" / "done"）。
function Transfer:dispatchScanSlice(slice, now)
    now = now or os.epoch("utc")
    local state = self:requestQuery({ container = slice.names[1], key = slice.key })
    if self.queryRunning[slice.key] then
        self.scanDispatchCount = (self.scanDispatchCount or 0) + 1
        for _, worker in ipairs(self:capableWorkers("query")) do
            local record = self.queries[self.queryRunning[slice.key]]
            if record and record.worker == worker.id then
                worker.lastScanAt = now          -- 这台刚扫过：一段冷却期里不再派给它
                break
            end
        end
    end
    return state
end

--- 某个容器被搬动过：作废它的代扫结果（否则引擎会拿搬之前的槽位内容做判断）
function Transfer:invalidateScan(name)
    if name == nil then
        self.scanCache = {}
        self.scanBatches = {}
        self.scanOwner = {}
        return
    end
    self.scanCache[name] = nil
    local batchId = self.scanOwner[name]
    self.scanOwner[name] = nil
    local batch = batchId and self.scanBatches[batchId]
    if not batch then
        return
    end
    -- 只把它从所在的那一片里摘掉：同一片的其它容器仍然有效（下一次请求会为它重新派活）
    for _, slice in ipairs(batch.slices or {}) do
        for index = #slice.names, 1, -1 do
            if slice.names[index] == name then
                table.remove(slice.names, index)
            end
        end
    end
end

--- 清理过期的批次（避免 scanBatches 一直涨）
function Transfer:pruneScanBatches(now)
    now = now or os.epoch("utc")
    for id, batch in pairs(self.scanBatches) do
        if now - (batch.at or 0) > SCAN_BATCH_TTL then
            for _, slice in ipairs(batch.slices or {}) do
                for _, name in ipairs(slice.names or {}) do
                    if self.scanOwner[name] == id then
                        self.scanOwner[name] = nil
                    end
                end
            end
            self.scanBatches[id] = nil
        end
    end
end

--- 一批代扫任务：**每个容器一条查询**，轮流派给“空闲且可查询”的 worker，派不出去的分片排队补派。
--- 为什么一片只放一个容器：慢容器（远程计算机 / 某些 Mod 机器）会拖住整条查询，而查询是 worker
--- 主循环里同步执行的；一条查询一个容器时，慢的只影响它自己，其它容器的结果照常回来。
function Transfer:startScanBatch(names)
    local now = os.epoch("utc")
    self.scanSeq = self.scanSeq + 1
    local batchId = self.scanSeq
    local batch = { id = batchId, at = now, pending = 0, slices = {} }
    self.scanBatches[batchId] = batch
    for index, name in ipairs(names) do
        local slice = { names = { name }, state = "pending", key = "scan:" .. batchId .. ":" .. index }
        batch.slices[index] = slice
        self.scanOwner[name] = batchId
    end
    for _, slice in ipairs(batch.slices) do
        batch.pending = batch.pending + 1
        if not self:scanDispatchAllowed(now) then
            --- 限流：这个 tick 已经派够了（或所有 worker 都在冷却期）→ 排队，下个 tick 再派。
            --- 这就是「两个容器之间允许插进搬运/别的查询」的实现。
            slice.state = "queued"
            self.scanQueue[batch.id] = true
            self.scanStats.queued = (self.scanStats.queued or 0) + 1
            self.scanStats.throttled = (self.scanStats.throttled or 0) + 1
        else
            local state = self:dispatchScanSlice(slice, now)
            if state == "local" then
                slice.state = "local"          -- 没有 worker 了：这一片交回调用方本机读
                batch.pending = batch.pending - 1
                for _, name in ipairs(slice.names) do
                    if self.scanOwner[name] == batch.id then
                        self.scanOwner[name] = nil
                    end
                end
            elseif self.queryRunning[slice.key] then
                slice.state = "pending"        -- 真的发出去了
                self.scanStats.subQueries = self.scanStats.subQueries + 1
            else
                --- 有 worker 但都在忙（requestQuery 直接返回 pending，**这条查询根本没发出去**）。
                --- 以前这里也当作“已派活”，于是这一片再也没人管：主控以为一直在扫，实际没人扫，
                --- 只能一直用旧值 / 本机读。现在记进补派队列，Transfer:tick 里等 worker 空出来补发。
                slice.state = "queued"
                self.scanQueue[batch.id] = true
                self.scanStats.queued = (self.scanStats.queued or 0) + 1
            end
        end
    end
    self.scanStats.batches = self.scanStats.batches + 1
    return batch
end

--- 补派「当时没发出去」的代扫分片（worker 都在忙）：每个 tick 试一次，直到发出去或批次作废。
function Transfer:dispatchScanQueue(now)
    if not next(self.scanQueue) then
        return
    end
    now = now or os.epoch("utc")
    if now < (self.scanPausedUntil or 0) then
        return
    end
    for batchId in pairs(self.scanQueue) do
        local batch = self.scanBatches[batchId]
        if not batch then
            self.scanQueue[batchId] = nil
        else
            local waiting = false
            for _, slice in ipairs(batch.slices or {}) do
                if slice.state == "queued" and #slice.names == 0 then
                    --- 分片里的容器都被搬动过（invalidateScan 摘掉了）：不用再派了
                    slice.state = "empty"
                    batch.pending = math.max(0, (batch.pending or 1) - 1)
                elseif slice.state == "queued" then
                    if not self:scanDispatchAllowed(now) then
                        waiting = true               -- 限流中：下个 tick 再派（空档留给搬运）
                        batch.at = now               -- 这是**有意等待**，别让批次被 TTL 提前丢掉
                    else
                        local state = self:dispatchScanSlice(slice, now)
                        if self.queryRunning[slice.key] then
                            slice.state = "pending"
                            self.scanStats.subQueries = self.scanStats.subQueries + 1
                        elseif state == "local" then
                            slice.state = "local"
                            batch.pending = math.max(0, (batch.pending or 1) - 1)
                            for _, name in ipairs(slice.names) do
                                if self.scanOwner[name] == batch.id then
                                    self.scanOwner[name] = nil
                                end
                            end
                        else
                            waiting = true           -- 还在忙：留着下个 tick 再试
                        end
                    end
                end
            end
            if not waiting then
                self.scanQueue[batchId] = nil
            end
        end
    end
end

--- 把一条 query_result 摊进代扫缓存（只有 "scan:<批次>:<片>" 这种 key 才处理）
--- 返回是否处理了这条结果
function Transfer:absorbScanResult(key, result)
    local batchId, sliceIndex = string.match(tostring(key or ""), "^scan:(%d+):(%d+)$")
    if not batchId or type(result) ~= "table" then
        return false
    end
    local batch = self.scanBatches[tonumber(batchId)]
    local slice = batch and batch.slices and batch.slices[tonumber(sliceIndex)] or nil
    if not batch or not slice then
        return true                       -- 批次已作废：迟到的结果直接丢
    end
    local now = os.epoch("utc")
    -- 按外设名摊开：worker 只回报非空槽位，所以“扫过且没内容” = 空容器
    local slots, tanks = {}, {}
    local function bucketInto(map, name)
        local value = map[name]
        if not value then
            value = {}
            map[name] = value
        end
        return value
    end
    for _, entry in ipairs(type(result.items) == "table" and result.items or {}) do
        local peripheral = entry.container
        local slot = tonumber(entry.slot)
        if type(peripheral) == "string" and slot and type(entry.name) == "string" then
            bucketInto(slots, peripheral)[slot] = {
                name = entry.name,
                count = tonumber(entry.count) or 0,
                nbt = entry.nbt,
            }
        end
    end
    for _, entry in ipairs(type(result.tanks) == "table" and result.tanks or {}) do
        local peripheral = entry.container
        local slot = tonumber(entry.slot)
        if type(peripheral) == "string" and slot and type(entry.name) == "string" then
            bucketInto(tanks, peripheral)[slot] = {
                name = entry.name,
                amount = tonumber(entry.amount) or 0,
            }
        end
    end
    -- worker 有没有回报“真的扫到了哪些容器”？报了才能证明“这个容器是空的”
    local announced = type(result.scannedContainers) == "table" and result.scannedContainers or nil
    local announcedSet = {}
    for _, entry in ipairs(announced or {}) do
        announcedSet[tostring(entry)] = true
    end
    local absorbed = 0
    for _, name in ipairs(slice.names) do
        local hasItems = slots[name] ~= nil
        local hasTanks = tanks[name] ~= nil
        local trustworthy
        if hasItems or hasTanks then
            trustworthy = true                      -- 有内容：worker 确实扫到了它
        elseif announced == nil then
            -- 老版本 worker（不报清单）：空容器不敢当真，交给调用方本机读 —— 安全降级
            trustworthy = false
        else
            trustworthy = announcedSet[name] == true
        end
        if trustworthy then
            self.scanCache[name] = {
                at = now,
                slots = slots[name] or {},
                tanks = tanks[name] or {},
            }
            absorbed = absorbed + 1
        end
        -- 这一批已经给出结果：解除占用，下一次缓存过期时才能开新的一批（否则会一直“在扫”）
        if self.scanOwner[name] == batch.id then
            self.scanOwner[name] = nil
        end
    end
    slice.state = "done"
    slice.doneAt = now
    batch.pending = math.max(0, (batch.pending or 1) - 1)
    --- 每完成一片就顺延批次寿命：一整批 60 个容器在多台 worker 上要跑十几秒，
    --- 用“创建时间 + TTL”会把还在正常推进的批次提前丢掉（迟到的分片结果全部白扫）
    batch.at = now
    self.scanStats.containers = self.scanStats.containers + absorbed
    --- 结果回来了，但请求的容器**一个都没摊上**：worker 回答了却看不到这些容器
    --- （不在同一有线网络上 / 名字不一样）——这种代扫永远是白跑。计入失败：
    --- 连续几次之后就暂停派活，主控安心本机读，同时在日志里把原因说清楚。
    if absorbed > 0 then
        self:noteScanSuccess()
    elseif announced ~= nil and #slice.names > 0 then
        self.scanStats.blind = (self.scanStats.blind or 0) + 1
        if now - (self.scanWarnAt or 0) >= 60000 then
            self.scanWarnAt = now
            self.log("IFMWorker scan: worker answered but saw 0 of the %d requested container(s) (e.g. %s) - " ..
                "it cannot see them, so delegated scanning cannot work (workers must share the master's wired " ..
                "network, see README 6.2); the master reads containers itself",
                #slice.names, tostring(slice.names[1] or "?"))
        end
        self:noteScanFailure("no requested container visible")
    end
    return true
end

--- 代扫成功一次：连续失败计数清零（一片就是一个容器，不再有“每片几个容器”的自适应）
function Transfer:noteScanSuccess()
    self.scanFailStreak = 0
end

--- 代扫失败一次（超时 / worker 报错 / worker 看不到容器）：
--- 连续失败到 SCAN_FAIL_LIMIT 次 → 暂停派活 SCAN_PAUSE_MS，期间调用方直接本机读。
--- （以前没有这一步：每次失败都要干等 15 秒超时，主控一直在“等 worker + 本机兜底”之间打转。）
function Transfer:noteScanFailure(reason)
    self.scanFailStreak = (self.scanFailStreak or 0) + 1
    if self.scanFailStreak >= SCAN_FAIL_LIMIT then
        local now = os.epoch("utc")
        self.scanFailStreak = 0
        self.scanPausedUntil = now + SCAN_PAUSE_MS
        self.log("IFMWorker scan: %d consecutive failures (last: %s) - pausing delegated container scans for %ds " ..
            "and reading containers on the master meanwhile; fix the workers, or ignore this (scanning works without them)",
            SCAN_FAIL_LIMIT, tostring(reason or "?"), math.floor(SCAN_PAUSE_MS / 1000))
    end
end

--- 某一片代扫失败（worker 报错 / 掉线）：不缓存任何东西，让调用方本机读
function Transfer:failScanSlice(key)
    local batchId, sliceIndex = string.match(tostring(key or ""), "^scan:(%d+):(%d+)$")
    if not batchId then
        return false
    end
    local batch = self.scanBatches[tonumber(batchId)]
    local slice = batch and batch.slices and batch.slices[tonumber(sliceIndex)] or nil
    if batch and slice then
        slice.state = "failed"
        batch.pending = math.max(0, (batch.pending or 1) - 1)
        --- 失败也是一次“进展”：顺延批次寿命，让还在飞的分片跑完
        --- （固定 TTL 会在多容器批次上把正在正常推进的批次提前丢掉）
        batch.at = os.epoch("utc")
    end
    -- 失败也要解除占用：下一次请求可以重新派活或本机读
    for _, name in ipairs(slice and slice.names or {}) do
        if self.scanOwner[name] == batchId then
            self.scanOwner[name] = nil
        end
    end
    self.scanStats.failed = (self.scanStats.failed or 0) + 1
    self:noteScanFailure("slice failed")
    return true
end

--- 主控要读某个容器时调用（见上面说明）。names = 这一次可能一起刷新的一批外设名（用于切片派活）。
--- ttl = 调用方希望的“结果至少多新”（毫秒）：本机缓存时长是自适应的（见 Containers:effectiveListTtl），
--- 不带的话 worker 的结果总在主控该刷新时刚好过期，代扫等于白做。
function Transfer:scanRequest(name, names, ttl)
    if type(name) ~= "string" or name == "" then
        return "local"
    end
    local now = os.epoch("utc")
    ttl = tonumber(ttl) or self.scanTtl
    if ttl < self.scanTtl then
        ttl = self.scanTtl
    end
    if ttl > (self.scanTtlMax or SCAN_TTL_MAX) then
        ttl = self.scanTtlMax or SCAN_TTL_MAX
    end
    local cached = self.scanCache[name]
    if cached and now - (cached.at or 0) <= ttl then
        self.scanStats.hits = self.scanStats.hits + 1
        return "done", cached
    end
    --- 连续失败中：暂时不派活（调用方直接本机读），别再让每一次都干等一批回不来的结果
    if now < (self.scanPausedUntil or 0) then
        self.scanStats.paused = (self.scanStats.paused or 0) + 1
        return "local"
    end
    if not self:hasQueryWorker() then
        self.scanStats.localOnly = self.scanStats.localOnly + 1
        return "local"
    end
    self.scanStats.requests = self.scanStats.requests + 1
    if self.scanOwner[name] then
        self.scanStats.pending = self.scanStats.pending + 1
        return "pending"                    -- 已经在扫了：调用方先用旧值顶着
    end
    -- 开一批新的：把“要刷新的容器”切片并行派给多台 worker
    local seen = {}
    local list = {}
    local function add(value)
        if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            list[#list + 1] = value
        end
    end
    add(name)
    for _, entry in ipairs(type(names) == "table" and names or {}) do
        add(entry)
    end
    self:startScanBatch(list)
    self:pruneScanBatches(now)
    if now - (self.scanLogAt or 0) >= 30000 then
        self.scanLogAt = now
        self.log("IFMWorker scan: %d container(s) delegated (one query per container) to %d worker(s)",
            #list, #self:capableWorkers("query"))
    end
    self.scanStats.pending = self.scanStats.pending + 1
    return "pending"
end

--- 代扫状态（网页/诊断）
function Transfer:scanStatus()
    local cached = 0
    for _ in pairs(self.scanCache) do
        cached = cached + 1
    end
    local now = os.epoch("utc")
    return {
        ttl = self.scanTtl,
        ttlMax = self.scanTtlMax or SCAN_TTL_MAX,
        cached = cached,
        batchCount = self.scanStats.batches,
        subQueries = self.scanStats.subQueries,
        requests = self.scanStats.requests,
        hits = self.scanStats.hits,
        pending = self.scanStats.pending,
        localOnly = self.scanStats.localOnly,
        containers = self.scanStats.containers,
        failed = self.scanStats.failed or 0,
        --- 以下三个字段用来判断“代扫到底有没有用”：
        ---   paused   —— 连续失败暂停期间，调用方要求代扫、被直接判为“本机读”的次数
        ---   blind    —— worker 回答了却看不到请求的容器（不在同一有线网络）的次数
        ---   queued   —— 当时所有 worker 都忙、没能发出去（排队等补派）的分片数
        paused = self.scanStats.paused or 0,
        pauseLeft = math.max(0, math.floor(((self.scanPausedUntil or 0) - now) / 1000)),
        blind = self.scanStats.blind or 0,
        --- 限流：因为“这个 tick 派够了 / worker 还在冷却”而推迟的分片数（1.6.7）
        throttled = self.scanStats.throttled or 0,
        perTick = self.scanPerTick or SCAN_PER_TICK,
        cooldown = self.scanCooldown or SCAN_COOLDOWN,
        idleCooldown = self.scanIdleCooldown or SCAN_IDLE_COOLDOWN,
        queued = self.scanStats.queued or 0,
        --- 一条查询只查一个容器（见 startScanBatch）
        perQuery = 1,
    }
end

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
            --- 版本不一致的 worker **不参与作业**（pickWorkerFor / available 都会把它排除），
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
    --- jobs/queries，以前会把主控这边记着的计数**清零**，网页上就变成“搬 0（0 个）· 查询 0”，
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
    --- busy 以 worker **自己**上报的为准（主控没有在飞任务时）：
    --- 主控只是“发出去时先标记为忙”，万一回报丢了（modem 丢包 / worker 重启），
    --- 这个标记就会一直挂着 —— 网页显示「工作中」却看不到任务，而且再也不会派活给它。
    --- 这里用 worker 的 state（每秒一次）把它纠正回来；真有在飞任务时不动（等超时处理）。
    if message.busy ~= nil and not self:workerHasPending(worker) then
        local reported = message.busy == true
        if worker.busy ~= reported then
            worker.busy = reported
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

--- 周期维护：清掉超时 / 已失效的查询（搬运任务的超时由 tick 里的逻辑处理）
function Transfer:maintainWorkers(now)
    for key, id in pairs(self.queryRunning) do
        local record = self.queries[id]
        if not record or now - (record.at or 0) > JOB_TIMEOUT then
            self.queryRunning[key] = nil
            self.queries[id] = nil
        end
    end
end

return Transfer
