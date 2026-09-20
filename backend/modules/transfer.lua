-- IFM :: modules/transfer.lua
-- IFMWorker 调度（1.5.0）：worker 只做两件事 —— 「物品/流体搬运」与「物品/流体查询」。
-- 流程（engine）、存储整理（compact）、网页中继（WebSocket）一律由主控自己执行，
-- 所以 worker 掉线既不会影响流程推进，也不会让网页失联。
--
-- 节点发现（discovery）
--   * 主控每隔 HELLO_INTERVAL(3s) 在 self.channel 广播 { op = "hello" }（Transfer:tick）；
--   * worker 收到 hello 立刻回 { op = "pong", name, caps }；另外 worker 自己每 5s 也会主动广播一次
--     hello（主控重启后不用等它广播就能发现它）；
--   * 来自某台 worker 的任何消息都会刷新 worker.lastSeen（见 touch()）：
--     超过 WORKER_TIMEOUT(15s) 没有任何消息 → 标成「失联」（不再派新活、网页卡片标红）；
--     超过 WORKER_EVICT_TIMEOUT(30s) → **从 self.workers 移除**（用户第 2 项：到点即移除，
--     不一直等它恢复），它手上的搬运/查询/详情代查全部作废（引擎下个 tick 重新调度）。
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
--- 机械臂合成器（crafter.lua）的**专用频道**（用户第 4 项：不要和 IFMWorker 走同一个频道）。
--- 主控会同时开这两个频道：41000 收 worker 的 hello/pong/结果，41001 收海龟合成器的 hello/回报。
Transfer.CRAFTER_CHANNEL = 41001
Transfer.PROTOCOL = "ifm_transfer"
--- 机械臂合成器的协议名 + 版本号（版本号在这里是**唯一来源**：IFMMaster / IFMWorker / crafter 都从这里取，
--- 以前三份脚本各写一份 "1.8.0"，改版本时最容易漏掉其中一个 —— 漏掉的后果是版本闸门直接拒活）。
Transfer.CRAFTER_PROTOCOL = "ifm_crafter"
Transfer.VERSION = "1.8.2"
--- 每台 worker 的**私有作业频道**（用户第 3 项：产生的事件越少越好）。
--- 以前所有作业都广播在 Transfer.CHANNEL 上：N 条任务 = N 次 modem 调用，而且**每一台** worker
--- 都会收到 N 个 modem_message 事件（即使 target 不是它，事件也得走一遍处理逻辑）。
--- 现在主控把作业发到 42000+电脑号 这个只有那台 worker 会收到的频道上：别的 worker 连事件都没有。
Transfer.PRIVATE_CHANNEL_BASE = 42000

--- 某台 worker 的私有作业频道号（id = 电脑号；取模保证落在 0..65535 内）
function Transfer.workerChannelOf(id)
    local number = math.floor(tonumber(id) or 0) % 20000
    return Transfer.PRIVATE_CHANNEL_BASE + number
end

local HELLO_INTERVAL = 3000     -- IFM 广播 hello 的间隔（毫秒）
local WORKER_TIMEOUT = 15000    -- 多久没听到某台 worker 的消息就把它标成「失联」（无线链路偶尔丢包，别设太紧）
--- 失联多久才把它从注册表里摘掉（用户第 1 项：时而在线时而不在线；用户第 2 项：到点就移除，别一直等它回来）。
--- 以前"标失联"与"摘除"是同一个 15 秒阈值：worker 只要安静 15 秒（区块没加载、
--- 无线丢包、它自己卡了一下），网页上的卡片就会消失、再出现时计数清零，
--- 看起来就是"worker 忽上忽下"。所以现在是两级：
---   * 15 秒 = 标失联（卡片还在、红字提示、不再派新活，见 workerStale）；
---   * 30 秒 = 真正从注册表摘除（它的搬运/查询/详情代查全部作废，引擎下个 tick 重新调度）。
--- 30 秒 = 给一次心跳宽限期（worker 每秒都会上报 state，15 秒已经容掉十几次丢包了），
--- 之后就不再"一直等它恢复" —— 它回来时会重新握手、当成新 worker 注册。
local WORKER_EVICT_TIMEOUT = 30000
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

--- ===== 主控本机并行执行（1.8.0）=====
--- CC:T 里 list / getItemDetail / pushItems 这类外设调用都要等 1 个服务器刻，而且会阻塞
--- 调用它的那个线程；但把它们放进协程里同时发出去，多个调用就在同一个游戏刻里并行等结果
--- （CC:T 自带的 parallel 就是这么调度的）。所以：
---   * IFMWorker 一次可以并行跑 MAX_TASKS 条任务，只在任务表满时才算“忙”；
---   * 主控自己也是一个执行者：有空闲 worker 时优先把任务派给 worker，没有空闲 worker
---     （或者根本没 worker）时主控用 LOCAL_SLOTS 个协程并行做 —— 主循环不再被一次搬运卡住。
--- 注意：协程的推进由主控主循环的 pumpLocal 负责（每个事件都会把在跑的协程 resume 一次），
--- 与 parallel.lua 的做法完全一致。
local LOCAL_SLOTS = 32          -- 主控本机同时最多几个协程在做任务
local WORKER_SLOTS_DEFAULT = 1  -- worker 没上报并发上限时按 1 算（老版本 worker 一次只做一件事）
local LOCAL_OVERRUN_MS = 10000  -- 本机一条任务超过这么久还没做完就警告（多半是某个容器卡住了）

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

function Transfer.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transfer)
    self.log = levelLogger(opts.log)
    self.Peripherals = opts.Peripherals
    --- modem 发现 / 包装 / 发消息：与 IFMWorker.lua 共用 modules/modems.lua（不再各写一份）
    self.Modems = opts.Modems
    if not self.Modems then
        error("transfer.lua needs the modems module: pass opts.Modems (loadModule(\"modems\"))", 0)
    end
    self.channel = tonumber(opts.channel) or Transfer.CHANNEL
    --- 机械臂合成器（crafter.lua）的专用频道（用户第 4 项：与 worker 的频道分开）
    self.crafterChannel = tonumber(opts.crafterChannel) or Transfer.CRAFTER_CHANNEL
    --- ===== 机械臂合成器（IFMCrafter.lua）=====
    --- 用户第 1 项：craft 指令是**发出去就不管**的 —— 合成器不校验配方、不回报状态，
    --- 主控这边也就没有"合成任务表"（不重试、不超时）：材料没到位或配方不对，产物就抽不出来，
    --- 流程停在那一步由用户自己修。busy 由合成器每 2 秒的 hello 自己刷新（见 touchCrafter）。
    self.crafters = {}                      -- id -> { id, name, label, lastSeen, busy, crafts }
    self.craftSeq = 0
    self.craftStats = { sent = 0, idle = 0 }
    self.modemSide = opts.modemSide        -- 显式指定时用；否则自动找第一个 modem
    self.modem = nil
    self.listenReady = false
    self.helloAt = 0
    self.workers = {}                       -- id -> { id, lastSeen, busy, jobs }
    self.jobs = {}                          -- key -> { id, key, worker, at, state, moved, error }
    self.jobById = {}                       -- id -> 同一个 record
    --- 发件箱（用户第 3 项）：同一个 tick 里发给同一台 worker 的多条作业会打包成一条 modem 报文
    self.outbox = {}                        -- workerId -> { 已经组装好的消息 }
    self.jobSeq = 0
    self.stats = { submitted = 0, done = 0, failed = 0, timedOut = 0, localMoves = 0, busyRejected = 0,
        --- 打包统计（事件数优化）：batches = 合并发出的报文数，batchedJobs = 被合并的作业数
        batches = 0, batchedJobs = 0 }
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
    --- 查询被丢掉时的回调（用户第 2 项）：查询超时（QUERY_TIMEOUT）或 worker 被摘除时调用。
    --- 主控靠它把扫描队列里那条容器的在飞任务结束掉 —— 否则它永远挂在 inflight，
    --- maintainScanQueues 认为"已在队列里"不再补，那个容器从此再也不扫（快照永久停在旧内容）。
    self.onQueryDropped = nil
    --- 用户第 2/4 项：海龟合成器上报物品栏时调它 —— 主控用它把上报写进**内容快照**
    --- （Containers:applyScan；海龟不是 inventory 外设，扫描队列扫不到它）。
    self.onCrafterInventory = nil
    --- 物品详情回报的回调（同样的用法：由主控挂上）
    self.onDetailResult = nil
    --- 同一个容器的扫描结果在这个时间内算"新鲜"，不重复派活（毫秒）
    self.scanFreshMs = opts.scanFreshMs or 500
    self.detailStats = { submitted = 0, done = 0, failed = 0, items = 0 }
    self.lastDetail = nil                 -- 最近一次详情回报的摘要（诊断用）
    -- ===== 主控本机并行执行（1.8.0）=====
    --- 空闲 worker 不够时，主控自己用协程池并行执行搬运（上限 LOCAL_SLOTS）。
    --- 为什么要有它：worker 是别人的电脑，掉线 / 卡住 / 没装都是常态；只要主控自己也能并行做，
    --- 「有 worker 但全忙 → 整条队列停住」（用户现场：worker 全空闲、队列却一动不动）就没了。
    self.localPool = {
        slots = math.max(1, math.floor(tonumber(opts.localSlots) or LOCAL_SLOTS)),
        inFlight = 0,
    }
    self.localEntries = {}                -- jobId -> { co, record, at, job, warned }
    self.localStats = { submitted = 0, done = 0, failed = 0, overruns = 0, rejected = 0 }
    --- 本机执行体由 IFMMaster 挂上：function(job) return moved, err end（在协程里跑，可以调外设）
    self.executeLocal = nil
    --- 主控本机协程池开关（用户第 1 项：设置里可以关掉；没有 worker 在线时忽略这个开关）
    self.localWorkEnabled = true
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
        --- 机械臂合成器走另一个频道（用户第 4 项）：worker 的搬运结果与海龟的合成回报不能混在一起
        local okCrafter, crafterErr = pcall(modem.open, self.crafterChannel)
        if not okCrafter then
            self.log("crafter link: cannot open channel %d (%s)", self.crafterChannel, tostring(crafterErr))
        end
        self.listenReady = true
        self.log("IFMWorker link: listening on channel %d (workers) and %d (turtle crafters) via modem %s",
            self.channel, self.crafterChannel, tostring(self.modemName or "?"))
    end
    return self.modem
end

--- worker 的并发上限（它自己在 state 里上报 slots；老版本 worker 不报 = 1）。
--- 版本 1.8.0 起 worker 一次能并行跑 64 条任务，所以“忙”不再是 0/1，而是「在飞数 >= 上限」。
function Transfer:workerSlots(worker)
    if type(worker) ~= "table" then
        return WORKER_SLOTS_DEFAULT
    end
    local slots = tonumber(worker.slots)
    if slots == nil or slots < 1 then
        worker.slots = WORKER_SLOTS_DEFAULT
        if not worker.slotsDefaultLogged then
            worker.slotsDefaultLogged = true
            self.log.warn("IFMWorker #%s did not report its slot capacity - assuming %d (one task at a time); " ..
                "copy the same build to that computer to get parallel tasks",
                tostring(worker.id), WORKER_SLOTS_DEFAULT)
        end
        return worker.slots
    end
    worker.slots = math.floor(slots)
    return worker.slots
end

--- 这台 worker 还有没有空位接活（在飞数 < 它的并发上限）
function Transfer:workerHasRoom(worker)
    if type(worker) ~= "table" then
        return false
    end
    return (worker.inFlight or 0) < self:workerSlots(worker)
end

--- 记一次“交给这台 worker 的任务”（在飞 +1；满了就标成忙）
function Transfer:workerBegin(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = (worker.inFlight or 0) + 1
    worker.busy = not self:workerHasRoom(worker)
end

--- 记一次“这台 worker 的任务结束了”（在飞 -1；不到上限就不忙）
function Transfer:workerEnd(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = math.max(0, (worker.inFlight or 0) - 1)
    worker.busy = not self:workerHasRoom(worker)
end

--- 显式释放：主控这边把它手上的任务全部作废（超时 / 掉线 / 结果丢了）→ 在飞清零。
--- 绝不能用它去“纠正”一条仍在飞的单个任务，否则 64 个槽位会被一次误判清空。
function Transfer:workerRelease(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = 0
    worker.busy = false
end

--- 兼容旧调用点（busy 布尔量）：true = 占满全部槽位，false = 全部释放。
--- 新代码请用 workerBegin / workerEnd / workerRelease。
function Transfer:setWorkerBusy(worker, busy)
    if busy then
        if type(worker) ~= "table" then
            return
        end
        worker.inFlight = self:workerSlots(worker)
        worker.busy = true
        return
    end
    self:workerRelease(worker)
end

--- 还有空位的 worker 数（给了 feature 就要求具备该能力）。
--- 调度器用它决定"队列能不能推进"：0 台有空的 worker 时，就要看主控本机还有没有空闲协程位。
function Transfer:idleCount(feature)
    local count = 0
    for _, worker in pairs(self.workers) do
        if self:workerHasRoom(worker) and self:workerUsable(worker) and
            (not feature or self:workerHas(worker, feature)) then
            count = count + 1
        end
    end
    return count
end

--- 主控本机还有几个空闲协程位（调度器在“worker 全忙 / 没有 worker”时用这个数决定能不能推进）
function Transfer:localFreeSlots()
    return math.max(0, (self.localPool and self.localPool.slots or 0) - (self.localPool and self.localPool.inFlight or 0))
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

--- 这台 worker 现在算「失联」吗（超过 WORKER_TIMEOUT 没听到它的任何消息）。
--- 判定口径与网页上的 stale 字段完全一致：state 上报、查询回报、搬运回报都算"消息"。
function Transfer:workerStale(worker, now)
    if type(worker) ~= "table" then
        return false
    end
    now = now or os.epoch("utc")
    return (now - math.max(worker.stateAt or 0, worker.lastSeen or 0)) > WORKER_TIMEOUT
end

--- 是否至少有一台可用的 worker（有它时 IFM 自己不再搬运）
--- 注意：版本和主控不一致的 worker 不算可用 —— 协议/行为必须两边一致，
--- 否则会出现“明明有 worker，主控却把活交出去、结果没人做”的局面（网页上它们会被标红提示）。
function Transfer:workerUsable(worker)
    if type(worker) ~= "table" then
        return false
    end
    --- 失联的 worker 不派活（用户第 1 项）：它可能只是安静了十几秒，卡片还留在网页上，
    --- 但把任务交给它只会白等 20 秒（JOB_TIMEOUT）再失败重试；等它再次上报就自动恢复。
    if self:workerStale(worker) then
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
    local breakdown = self:usableBreakdown()
    return {
        available = self:available(),
        workers = self:workerCount(),
        movers = #self:capableWorkers("move"),
        queriers = #self:capableWorkers("query"),
        busy = busy,
        --- 还有空位的 worker 数（每个 worker 能并行跑多条任务，满了才算“忙”）
        --- 主控本机协程池（1.8.0）：设置面板 / 网页上直接显示“本机并行执行”的负载
        localPool = self:localStatus(),
        idle = self:idleCount(),
        idleMovers = self:idleCount("move"),
        idleQueriers = self:idleCount("query"),
        --- 排错用：为什么有些 worker 没算进 idle（用户现场："全部空闲但什么都不做"）
        usable = breakdown.usable,
        versionUnknown = breakdown.versionUnknown,
        versionMismatch = breakdown.versionMismatch,
        inFlightWorkers = breakdown.inFlight,
        --- 并发容量：slots = 所有 worker 的槽位总和，freeSlots = 现在还能接多少条
        slots = breakdown.capacity,
        freeSlots = breakdown.capacityTasks,
        inFlightTasks = breakdown.inFlightTasks,
        --- 主控自己的协程池（1.8.0）：worker 不够时它顶上
        --- 用户第 1 项：设置里的"主控自己处理任务"开关（enabled = 设置值；allowed = 此刻是否真的接管）
        localWorkEnabled = self.localWorkEnabled and true or false,
        localWorkAllowed = self:localWorkAllowed(),
        localSlots = self.localPool and self.localPool.slots or 0,
        localInFlight = self.localPool and self.localPool.inFlight or 0,
        localIdle = self:localFreeSlots(),
        localSubmitted = self.localStats.submitted or 0,
        localDone = self.localStats.done or 0,
        localFailed = self.localStats.failed or 0,
        localOverruns = self.localStats.overruns or 0,
        version = self.version,
        pending = self:pendingCount(),
        queries = self.queryStats,
        queriesPending = self:queryPendingCount(),
        details = self.detailStats,
        detailsPending = self:detailPendingCount(),
        lastQuery = self.lastQuery,
        channel = self.channel,
        modem = self.modemName,
        --- 机械臂合成器（crafter.lua，用户第 3 项）：与 worker 分开的频道 + 分开的统计
        crafterChannel = self.crafterChannel,
        crafters = self:craftStatus(),
        crafterList = self:craftersForUi(),
        submitted = self.stats.submitted,
        done = self.stats.done,
        failed = self.stats.failed,
        timedOut = self.stats.timedOut,
        localMoves = self.stats.localMoves,
        busyRejected = self.stats.busyRejected or 0,
        --- 事件数优化（用户第 3 项）：打包报文数 / 被合并的作业数
        batches = self.stats.batches or 0,
        batchedJobs = self.stats.batchedJobs or 0,
    }
end

--- 统计"为什么某些 worker 不算可用/空闲"（诊断用）：
--- 主控没版本 / worker 没报版本 / 版本不一致 / 槽位已满 —— 分别计数。
--- 注意 usable 的语义与 idleCount() 一致 = 「还接得下任务的 worker 数」（版本没问题且没满）。
--- versionUnknown 是**提示性**计数：老版本 worker 不报版本，但仍然会被使用（见 workerUsable）。
function Transfer:usableBreakdown()
    local out = { total = 0, usable = 0, noMasterVersion = 0, versionUnknown = 0,
        versionMismatch = 0, inFlight = 0, capacity = 0, inFlightTasks = 0, capacityTasks = 0 }
    for _, worker in pairs(self.workers) do
        out.total = out.total + 1
        local slots = self:workerSlots(worker)
        local inFlight = worker.inFlight or 0
        out.capacity = out.capacity + slots
        out.inFlightTasks = out.inFlightTasks + inFlight
        out.capacityTasks = out.capacityTasks + math.max(0, slots - inFlight)
        if type(worker.version) ~= "string" or worker.version == "" then
            out.versionUnknown = out.versionUnknown + 1
        end
        if not self.version then
            out.noMasterVersion = out.noMasterVersion + 1
        elseif type(worker.version) == "string" and worker.version ~= "" and worker.version ~= self.version then
            out.versionMismatch = out.versionMismatch + 1
        elseif inFlight >= slots then
            out.atCapacity = (out.atCapacity or 0) + 1
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

--- 选一台“还有空位 + 具备该能力 + 版本与主控一致”的 worker。
--- 1.8.0：worker 有多个槽位（最多 64 条并发），所以挑选按「在飞任务数」从小到大 ——
--- 先把每台 worker 的槽位填满再考虑下一台（均衡负载），同时避免“明明还有空位却没人派活”。
function Transfer:pickWorkerFor(feature)
    local best = nil
    for _, worker in pairs(self.workers) do
        if self:workerHasRoom(worker) and self:workerHas(worker, feature) and self:workerUsable(worker) then
            if not best then
                best = worker
            else
                local a = (worker.inFlight or 0) / self:workerSlots(worker)
                local b = (best.inFlight or 0) / self:workerSlots(best)
                if a < b - 1e-9 or (math.abs(a - b) < 1e-9 and (worker.jobs or 0) < (best.jobs or 0)) then
                    best = worker
                end
            end
        end
    end
    return best
end

--- 在频道上广播/发送一条消息（chan 省略时用公共频道；私有作业频道见 workerChannelOf）
function Transfer:send(message, chan)
    local modem = self:ensureModem()
    if not modem then
        return false
    end
    local ok, err = self.Modems.transmit(modem, chan or self.channel, message)
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
    --- 先攒进发件箱：同一个 tick 里发给同一台 worker 的多条作业会在 flushOutbox 里打包成一条
    --- 报文（用户第 3 项：事件越少越好）。返回 true = 已受理，真正的 modem 调用在 tick 末。
    return self:queueTo(worker, {
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
        --- 谁来执行（用户第 1 项）：按外设类型定，"to" = 目标侧 pull（海龟物品栏只能这么搬）
        actor = job.actor,
    })
end

--- 把一条组装好的消息放进“发件箱”（按 worker 分桶）
function Transfer:queueTo(worker, message)
    local box = self.outbox[worker.id]
    if not box then
        box = {}
        self.outbox[worker.id] = box
    end
    box[#box + 1] = message
    return true
end

--- 发件箱出队：每个 tick 末把攒下的消息发出去（用户第 1 项）。
--- **一律**打包成一条 { op = "jobs", jobs = {...} } —— 即使只有 1 条任务也走信封，
--- 不再有"单条 job / 单条 query / 单条 detail"的专门单发格式：
---   * 一个 tick 里 20 条搬运只产生 1 次 modem 调用（worker 侧为每条各起一个协程并行执行，
---     结果仍然逐条回报）；
---   * 报文种类只有一种，"任务是否丢失"的排查也只需看一种形状（老版本 worker 不兼容 —— 用户第 4 项：
---     不需要老版本兼容）。
--- 发送目标：worker 报过私有频道就用私有频道（别的 worker 收不到这个事件）。
--- 返回：envelopes（发出的信封数）, batchedJobs（信封里装的任务总数）。
function Transfer:flushOutbox()
    local envelopes, batched = 0, 0
    for workerId, box in pairs(self.outbox) do
        self.outbox[workerId] = nil
        local worker = self.workers[workerId]
        if worker and #box > 0 then
            local chan = worker.jobChannel or self.channel
            local okSend = self:send({
                proto = Transfer.PROTOCOL,
                op = "jobs",
                target = workerId,
                sender = os.getComputerID(),
                version = self.version,
                jobs = box,
            }, chan)
            if okSend then
                envelopes = envelopes + 1
                batched = batched + #box
            end
        end
    end
    if envelopes > 0 then
        self.stats.batches = (self.stats.batches or 0) + envelopes
        self.stats.batchedJobs = (self.stats.batchedJobs or 0) + batched
    end
    return envelopes, batched
end

--- 提交/查询一个搬运任务。返回：
---   "pending"              任务已经在飞（派给 worker、或主控本机协程池在做），还没结果
---   "done", moved, error   任务有结果了（error 非空表示失败）
--- 1.8.0 起这里不再返回 "local"：没有空闲 worker 时由主控自己的协程池并行执行
--- （见 submitLocalJob），调用方仍然按同一个 key 轮询取结果 —— 与 worker 路径完全一致。
function Transfer:request(job)
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
    --- (1) 优先交给还有空位的 worker（每台 worker 现在能并行跑多条任务，见 workerSlots）
    local worker = self:pickWorkerFor("move")
    if worker then
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
        if self:sendTo(worker, job) then
            self:workerBegin(worker)
            self.jobs[key] = record
            self.jobById[record.id] = record
            self.stats.submitted = self.stats.submitted + 1
            return "pending"
        end
        --- 发送失败（modem 掉了 / 它刚被摘除）：这条任务没交给它，不占用它的槽位
        return "pending"
    end
    --- (2) 没有空闲 worker：主控自己用协程池并行做（最多 LOCAL_SLOTS 条同时进行）。
    --- 用户第 1 项：设置里可以关掉"主控自己干活"，但只在**确实有 worker 在线**时才尊重这个开关 ——
    --- 一台 worker 都没有时不自己干活就没人干活了（那时关掉也照旧用本机协程池）。
    if self:localWorkAllowed() and self:submitLocalJob(key, job) then
        return "pending"
    end
    --- (3) 连本机协程位也满了：下个 tick 再来问。
    --- 绝不退回“同步搬”（那样同一次搬运会被 worker 与本机两处执行 —— 以前的老坑）。
    return "pending"
end

--- ===== 主控本机协程池（1.8.0）=====
--- 本机协程池能不能接手（用户第 1 项）：设置里关掉、且至少有一台 worker 在线时不接手。
--- 没有 worker 时永远可以（否则没人干活了）。
function Transfer:localWorkAllowed()
    if self.localWorkEnabled == false and self:workerCount() > 0 then
        return false
    end
    return true
end

--- 设置里的"主控自己处理任务"开关（缺省值由 modules/store.lua 决定：默认**关**）。
--- 这里只处理显式值：nil 视为开（老调用方 / 测试桩）。忽略无效值，返回是否真的改了。
function Transfer:setLocalWorkEnabled(enabled)
    local value = enabled ~= false
    if self.localWorkEnabled == value then
        return false
    end
    self.localWorkEnabled = value
    self.log("Local executor %s (setting: %s)", value and "ENABLED" or "DISABLED",
        self:localWorkAllowed() and "active"
            or "paused while workers are online - it keeps working when no worker is online")
    return true
end

--- 把一条搬运交给本机执行：包成一个协程放进 localEntries，由主循环的 pumpLocal 推进。
--- 一次外设调用 ≈1 个游戏刻，32 个协程同时发出去就是 32 倍吞吐（这就是 parallel 的原理）。
--- 返回 true 表示已经接手（调用方拿到的是 pending 语义，用同一个 key 取结果）。
function Transfer:submitLocalJob(key, job)
    if not self.localPool or self:localFreeSlots() <= 0 then
        self.localStats.rejected = (self.localStats.rejected or 0) + 1
        if not self.localRejectLogged then
            self.localRejectLogged = true
            self.log("Local executor is full (%d slot(s) busy): new moves wait for the next round",
                self.localPool and self.localPool.slots or 0)
        end
        return false
    end
    if type(self.executeLocal) ~= "function" then
        --- 编码规范（用户第 1 项）：未定义行为要报错，不许静默失败 ——
        --- 主控没挂本机执行体时这些任务会一直 pending，这里必须说清楚。
        self.localStats.noExecutor = (self.localStats.noExecutor or 0) + 1
        if not self.noExecutorLogged then
            self.noExecutorLogged = true
            self.log("No local move executor is wired (transfer.executeLocal) - moves can only run on workers")
        end
        return false
    end
    self.jobSeq = self.jobSeq + 1
    local now = os.epoch("utc")
    local record = {
        id = self.jobSeq,
        key = key,
        worker = "local",
        at = now,
        state = "pending",
        job = job,
        sendAt = now,
    }
    job.id = record.id
    self.jobs[key] = record
    self.jobById[record.id] = record
    self.localPool.inFlight = self.localPool.inFlight + 1
    self.localStats.submitted = self.localStats.submitted + 1
    self.stats.localMoves = self.stats.localMoves + 1
    local entry = { id = record.id, key = key, record = record, job = job, at = now }
    entry.co = coroutine.create(function()
        local ok, moved, err = pcall(self.executeLocal, job)
        entry.ok = ok
        entry.moved = moved
        entry.err = err
    end)
    self.localEntries[record.id] = entry
    --- 立刻推进一次：这条任务在本 tick 里就发出第一次外设调用（不等下一个事件）
    self:pumpLocal()
    return true
end

--- 推进本机协程池（主控主循环每处理完一个事件调用一次；与 CC:T parallel.lua 的调度方式一致）：
---   * 还没跑完的协程：把当前事件交给它（协程里那次 pullEvent 会自己过滤事件）→ 它继续跑；
---   * 跑完（dead）的协程：把结果写回任务记录，调用方下次轮询就能拿到 "done"。
--- 多余的事件参数会被忽略，不需要精确匹配。
function Transfer:pumpLocal(event, p1, p2, p3, p4, p5)
    if not self.localEntries or next(self.localEntries) == nil then
        return
    end
    local now = os.epoch("utc")
    for _, entry in pairs(self.localEntries) do
        local status = coroutine.status(entry.co)
        if status == "suspended" then
            local ok, err = coroutine.resume(entry.co, event, p1, p2, p3, p4, p5)
            if not ok then
                --- resume 自身失败（协程里抛了错）：记下来，finishLocalJob 会把它当失败处理
                entry.ok = false
                entry.err = "local move crashed: " .. tostring(err)
            elseif coroutine.status(entry.co) == "suspended" and not entry.warned and
                now - (entry.at or now) > LOCAL_OVERRUN_MS then
                --- 还在跑而且超过上限：警告一次（多半是某个容器/外设不响应 ——
                --- 用户现场那条 “push_item 没回音” 就是这么来的）
                entry.warned = true
                self.localStats.overruns = (self.localStats.overruns or 0) + 1
                self.log("Local move still running after %dms (%s) - that container/peripheral may be " ..
                    "unresponsive (check the block is loaded and on the wired network)",
                    LOCAL_OVERRUN_MS, tostring(entry.key))
            end
        end
        if coroutine.status(entry.co) == "dead" then
            self:finishLocalJob(entry)
        end
    end
end

--- 本机任务结束：写回结果（moved / error）并释放协程位。
--- 结果留在 self.jobs[key] 里等调用方取（与 worker 回报走同一张表，语义完全一致）。
function Transfer:finishLocalJob(entry)
    if not entry or not entry.record then
        return
    end
    self.localEntries[entry.id] = nil
    self.localPool.inFlight = math.max(0, (self.localPool.inFlight or 0) - 1)
    local record = entry.record
    local moved = tonumber(entry.moved) or 0
    local err = entry.err
    if entry.ok == false then
        moved = 0
        err = tostring(err or "local move failed")
    end
    if moved > 0 then
        self.localStats.done = self.localStats.done + 1
    else
        self.localStats.failed = self.localStats.failed + 1
    end
    record.moved = moved
    record.error = (moved > 0) and nil or (err or "moved nothing")
    record.state = moved > 0 and "done" or "failed"
    if record.state == "done" then
        self.stats.done = self.stats.done + 1
    else
        self.stats.failed = self.stats.failed + 1
    end
    record.finishedAt = os.epoch("utc")
end

--- 本机协程池状态（诊断 / 网页）
function Transfer:localStatus()
    return {
        slots = self.localPool and self.localPool.slots or 0,
        inFlight = self.localPool and self.localPool.inFlight or 0,
        idle = self:localFreeSlots(),
        submitted = self.localStats.submitted or 0,
        done = self.localStats.done or 0,
        failed = self.localStats.failed or 0,
        rejected = self.localStats.rejected or 0,
        overruns = self.localStats.overruns or 0,
    }
end

--- 处理 modem 消息（由主循环的 modem_message 事件调用）
function Transfer:onModemMessage(side, channel, replyChannel, message, distance)
    local chan = tonumber(channel)
    if type(message) ~= "table" then
        return false
    end
    --- 机械臂合成器的频道（用户第 4 项）：另一套协议，单独处理
    if chan == self.crafterChannel then
        if message.proto ~= Transfer.CRAFTER_PROTOCOL then
            return false
        end
        return self:onCrafterMessage(message)
    end
    if chan ~= self.channel then
        return false
    end
    if message.proto ~= Transfer.PROTOCOL then
        return false
    end
    local now = os.epoch("utc")
    --- 注册 / 刷新一台 worker。version 与 slots 也在这里记下来：hello / pong / state 里都可能带。
    --- 用户现场：网页上「版本」一栏一直空着 —— 以前只有 state 报文里的版本被记下来
    --- （每秒一次，丢一包就空一栏），hello / pong 里带的那份被直接丢掉。
    local touch = function(id, caps, name, version, slots)
        local worker = self.workers[id]
        local created = false
        if not worker then
            worker = { id = id, busy = false, inFlight = 0, jobs = 0 }
            self.workers[id] = worker
            created = true
            self.log("IFMWorker #%s online", tostring(id))
        end
        worker.lastSeen = now
        --- 又听到它了：清掉"标失联"的一次性日志标记，下次再安静下来时会重新提示
        worker.staleLogged = nil
        if type(version) == "string" and version ~= "" then
            worker.version = version
        end
        if tonumber(slots) and tonumber(slots) >= 1 then
            worker.slots = math.floor(tonumber(slots))
        end
        if type(caps) == "table" then
            worker.caps = caps
        end
        if type(name) == "string" and name ~= "" then
            worker.name = name
        end
        return worker, created
    end
    if message.op == "hello" then
        local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
        --- 私有作业频道（1.8.0）：worker 在 pong/state 里报，之后它的作业只发到这个频道
        if tonumber(message.jobChannel) then
            worker.jobChannel = math.floor(tonumber(message.jobChannel))
        end
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
        touch(message.from, message.caps, message.name, message.version, message.slots)
        return true
    end
    if message.op == "state" then
        -- worker 每秒上报一次：当前工作 / 能力 / 并发槽位 / 计数
        local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
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
        return self:applyQueryResult(message)
    end
    if message.op == "detail_result" then
        return self:applyDetailResult(message)
    end
    if message.op == "busy" then
        -- worker 说它的任务表满了（1.8.0：每台最多 64 条并发，只有满时才回 busy）：
        -- 收回这条任务，下个 tick 再派（可能是竞态，也可能它的槽位确实被占满了）。
        local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
        self:workerRelease(worker)
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
    --- ===== 任务结果（用户第 3 项：worker 每 tick 把本 tick 结束的任务结果打包成一条报文）=====
    --- 信封：{ op = "results", results = { {op="done"|"error"|"query_result"|"detail_result", ...}, ... } }
    --- 不做老版本兼容（用户第 4 项）：即使只有一条结果也走这个信封 —— 所以这里只认 results。
    if message.op == "results" then
        local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
        local results = type(message.results) == "table" and message.results or {}
        for _, entry in ipairs(results) do
            local entryOp = type(entry) == "table" and entry.op or nil
            if entryOp == "query_result" then
                self:applyQueryResult(entry)
            elseif entryOp == "detail_result" then
                self:applyDetailResult(entry)
            else
                self:applyWorkerResult(worker, entry)     -- done / error（搬运）
            end
        end
        return true
    end
    return false
end

--- 结算 worker 报回来的一条任务结果（搬运 done/error）。
--- 其它结果类型（query_result / detail_result）在各自的处理分支里，不经过这里。
function Transfer:applyWorkerResult(worker, message)
    if type(message) ~= "table" then
        return false
    end
    local record = self.jobById[tonumber(message.id) or -1]
    if not record then
        --- 不认识的任务号（超时作废、或它重发的旧结果）：也要把它占的槽位放掉一个，
        --- 否则那台 worker 的槽位会被慢慢漏光（表现为“还有空位的 worker 却收不到活”）
        self:workerEnd(worker)
        return true
    end
    if record.state ~= "pending" then
        -- 已经作废（超时/掉线）的任务：忽略迟到的结果
        self.jobById[record.id] = nil
        self:workerEnd(worker)
        return true
    end
    worker.jobs = (worker.jobs or 0) + 1
    self:workerEnd(worker)
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

--- 结算 worker 报回来的一条查询结果（容器扫描 / 快照代读）。
--- 用户第 3 项：这些结果现在和搬运结果一起走 { op = "results" } 信封，所以抽成独立方法，
--- 单条直接到达（老路径）与信封里逐条派发都走同一段逻辑。
function Transfer:applyQueryResult(message)
    -- worker 扫完本机外设的结果：进缓存，调用方/网页按 key 取
    local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
    self:workerEnd(worker)
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
        self.log.warn("IFMWorker #%s query failed: %s", tostring(worker.id), tostring(message.error))
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

--- 结算 worker 报回来的一条物品详情代查结果（getItemDetail）。
function Transfer:applyDetailResult(message)
    -- worker 代查回来的物品详情：先收进 detailResults，
    -- 主控每个 tick 用 takeDetailResults 取走并吸收进 Containers 的物品详情字典。
    local worker = touch(message.from, message.caps, message.name, message.version, message.slots)
    local id = tonumber(message.id) or -1
    local request = self.details[id]
    self.details[id] = nil
    --- 这条详情代查结束了：释放它占用的一个槽位（结果迟到、我们已作废时也要释放）
    self:workerEnd(worker)
    if not self:workerHasPending(worker) then
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

--- ===== 机械臂合成器（crafter.lua，频道 self.crafterChannel）=====
--- 它与 worker 是**两套东西**：worker 搬东西/读容器，机械臂在自己身上合成。
--- 主控在网络上看到的是 turtle 外设；crafter 用 modem.getNameLocal() 报上自己的**网络外设名**，
--- 两者一对就知道"这个 turtle 正跑着 crafter"（用户第 2 项），也就能按 turtle_crafter 机器类型用它。
--- craft 指令发出去就不管（见 Transfer.new / Transfer:requestCraft 的注释）
--- 合成器物品栏上报（用户第 2 项）：海龟用 modem 把它物品栏里"哪个槽位有什么"报给主控 ——
--- 主控抽产物时必须给出源槽位（pullItems 的槽位参数必填，见 Containers:pushItem），
--- 这份上报就是唯一的槽位来源。
--- 用户第 2/4 项：海龟交互容器的**唯一**内容来源是它自己上报的物品栏（op = "inventory"）——
--- 它不是 inventory 外设，扫不到。下面两个常量管"多久算旧 / 多久要一次"。
local CRAFTER_INVENTORY_REFRESH = 1500      -- 上报超过这么久就顺手要一份新的（限流见下）
local CRAFTER_INVENTORY_ASK_GAP = 2000      -- 同一台合成器两次"要物品栏"的最小间隔（毫秒）

--- 注册 / 刷新一台合成器（任何来自它的消息都会刷新 lastSeen）
function Transfer:touchCrafter(id, message)
    id = tonumber(id)
    if id == nil then
        return nil
    end
    local now = os.epoch("utc")
    local crafter = self.crafters[id]
    local created = false
    if not crafter then
        crafter = { id = id, busy = false, jobs = 0, crafted = 0 }
        self.crafters[id] = crafter
        created = true
    end
    crafter.lastSeen = now
    if type(message.name) == "string" and message.name ~= "" then
        crafter.name = message.name
    end
    if type(message.label) == "string" and message.label ~= "" then
        crafter.label = message.label
    end
    if type(message.version) == "string" and message.version ~= "" then
        crafter.version = message.version
    end
    if message.busy ~= nil then
        crafter.busy = message.busy == true
    end
    crafter.crafted = tonumber(message.crafted) or crafter.crafted or 0
    crafter.jobs = tonumber(message.jobs) or crafter.jobs or 0
    crafter.channel = self.crafterChannel
    if created then
        self.log("crafter #%s online (%s) on channel %d", tostring(id), tostring(crafter.name or "?"),
            self.crafterChannel)
    end
    return crafter, created
end

--- 主控 → 机械臂发一条消息（同一个 modem，但走合成频道）
--- 用户第 4 项（现场：海龟从来收不到合成请求）：这里**必须**显式指定 crafterChannel ——
--- 以前写成 `self:send(message)`，而 `Transfer:send(message, chan)` 省略 chan 时用的是
--- **worker 频道**（41000）：于是 pong / ping / craft 全都发到了 worker 频道上，
--- 合成器（听 41001）一条都收不到；主控这边还看似"已经发出去了"（返回 true、日志照打）。
function Transfer:sendCrafter(message)
    return self:send(message, self.crafterChannel)
end

--- 处理机械臂的回报（协议见 crafter.lua 顶部注释）
function Transfer:onCrafterMessage(message)
    local crafter = self:touchCrafter(message.from, message)
    if not crafter then
        return false
    end
    local op = message.op
    --- 用户第 2/4 项：物品栏上报（海龟合成后 / 主控索要 / 它有货时每 5 秒一次）。
    --- 它现在**就是**那台海龟交互容器的内容快照来源：除了记在自己身上（网页用），
    --- 还会通过 onCrafterInventory 写进 Containers 的快照（与扫描结果同一个入口）——
    --- 抽取产物、挑输入槽位全都按那份快照决策（见 modules/containers.lua 的读取规则）。
    if op == "inventory" then
        local items = type(message.items) == "table" and message.items or {}
        local at = tonumber(message.at) or os.epoch("utc")
        local size = tonumber(message.size)
        local previous = crafter.inventory and #(crafter.inventory.items or {}) or -1
        crafter.inventory = { at = at, items = items, size = size }
        if message.busy ~= nil then
            crafter.busy = message.busy == true
        end
        if previous ~= #items then
            self.log("crafter #%s inventory report: %d stack(s)", tostring(crafter.id), #items)
        end
        if self.onCrafterInventory and type(crafter.name) == "string" and crafter.name ~= "" then
            local ok, err = pcall(self.onCrafterInventory, crafter.name, items, at, size)
            if not ok then
                self.log.warn("crafter #%s inventory snapshot write failed: %s", tostring(crafter.id),
                    tostring(err))
            end
        end
        return true
    end
    if op == "hello" or op == "pong" or op == "crafter_here" then
        --- 握手：把主控版本回给机械臂（它自己核对，不一致会在屏幕上常显警告）
        self:sendCrafter({
            proto = Transfer.CRAFTER_PROTOCOL,
            op = "pong",
            from = os.getComputerID(),
            target = crafter.id,
            master = true,
            version = self.version,
        })
        return true
    end
    --- 合成器不回报合成状态（用户第 1 项）：这里没有 craft_done / craft_failed 要处理 ——
    --- 结果好不好由"能不能抽出产物"体现（抽不出来 = 流程停在那一步，用户自己去修流程）。
    return false
end

--- 挑一台空闲的合成器：name 给了就只认它（turtle_crafter 机器名 = 海龟的网络外设名），
--- 否则按"已合成次数"轮转，尽量平均。
--- 版本不一致的机械臂不派活（它可能理解不了新指令）—— 用户换新版本时两边一起换。
function Transfer:pickCrafter(name)
    if name ~= nil then
        for _, crafter in pairs(self.crafters) do
            if crafter.name == name then
                local versionOk = (crafter.version == nil or crafter.version == "" or
                    crafter.version == self.version)
                if crafter.busy or not versionOk then
                    return nil
                end
                return crafter
            end
        end
        return nil
    end
    local best = nil
    for _, crafter in pairs(self.crafters) do
        local versionOk = (crafter.version == nil or crafter.version == "" or crafter.version == self.version)
        if not crafter.busy and versionOk then
            if not best or (crafter.jobs or 0) < (best.jobs or 0) then
                best = crafter
            end
        end
    end
    return best
end

--- 向合成器要一份物品栏上报（限流：同一台 2 秒最多一次）
function Transfer:requestCrafterInventory(crafter)
    if not crafter then
        return false
    end
    local now = os.epoch("utc")
    if crafter.inventoryAskedAt and now - crafter.inventoryAskedAt < CRAFTER_INVENTORY_ASK_GAP then
        return false
    end
    crafter.inventoryAskedAt = now
    return self:sendCrafter({
        proto = Transfer.CRAFTER_PROTOCOL,
        op = "inventory_request",
        from = os.getComputerID(),
        target = crafter.id,
        master = true,
        version = self.version,
    })
end

--- 用户第 2/3 项：维护海龟那份"内容快照"的新鲜度。
--- 海龟不是 inventory 外设，主控扫不到它 —— 它的快照完全靠**它自己上报**（op = "inventory"）。
--- 规则：
---   * 上报超过 CRAFTER_INVENTORY_REFRESH(1.5s) 就顺手要一份新的（限流 2 秒一台）；
---   * 超过 CRAFTER_INVENTORY_TTL(15s) 都没回来 = 快照过期，`Containers:hasSnapshot` 仍然为真，
---     但内容可能已经变了 —— 所以这里必须持续催（否则抽取会一直照旧内容决策）。
--- 返回：这一轮催了几台。
function Transfer:refreshCrafterReports(now)
    now = tonumber(now) or os.epoch("utc")
    local asked = 0
    for _, crafter in pairs(self.crafters) do
        local report = crafter.inventory
        local age = report and (now - (tonumber(report.at) or 0)) or nil
        if age == nil or age >= CRAFTER_INVENTORY_REFRESH then
            if self:requestCrafterInventory(crafter) then
                asked = asked + 1
            end
        end
    end
    return asked
end

--- 让机械臂合成一组配方。spec = { key, limit, source }
---   key    逻辑任务键（同一台机器同一批材料只提交一次；调用方按 key 轮询结果）
---   limit  合成次数上限（turtle.craft 的 limit）
---   source 可选：合成前要**并行吸入**的容器外设名（留空 = 材料已经在机械臂物品栏里）
--- 返回：
---   "pending"                     已派给它（或已有同 key 的任务在飞）
---   "done", crafted, error, job    有结果了（error 非空 = 失败原因）
---   "idle"                        没有空闲的合成器（调用方下个 tick 再试）
--- 让机械臂合成（用户第 1 项：发出去就不管）。
---   spec.key  逻辑任务键（只用于日志/排错；主控不按它等结果）
---   合成器一律 craft(64)，所以没有 limit 参数
--- 返回 "sent" = 已发出（或已有一条在飞）/"idle" = 没有空闲合成器（调用方下个 tick 再试）
function Transfer:requestCraft(spec)
    spec = spec or {}
    local crafter = self:pickCrafter(spec.crafter)
    if not crafter then
        self.craftStats.idle = self.craftStats.idle + 1
        return "idle"
    end
    self.craftSeq = self.craftSeq + 1
    local sent = self:sendCrafter({
        proto = Transfer.CRAFTER_PROTOCOL,
        op = "craft",
        from = os.getComputerID(),
        target = crafter.id,
        master = true,
        version = self.version,
        id = self.craftSeq,
        key = spec.key,
    })
    if not sent then
        return "idle"
    end
    --- 先标忙（避免同一个 tick 里又派一条给它）：合成器下一次 hello（≤2 秒）会用自己的 busy 覆盖
    crafter.busy = true
    self.craftStats.sent = self.craftStats.sent + 1
    self.log("crafter #%s craft request %s (%s)", tostring(crafter.id), tostring(self.craftSeq),
        tostring(spec.key or "?"))
    return "sent"
end

--- 合成器统计（状态栏 / 诊断用）
function Transfer:craftStatus()
    local count, busy = 0, 0
    for _, crafter in pairs(self.crafters) do
        count = count + 1
        if crafter.busy then
            busy = busy + 1
        end
    end
    local pending = 0
    return {
        crafters = count,
        busy = busy,
        idle = count - busy,
        channel = self.crafterChannel,
        --- 发出去的合成指令数 / 因为没空闲合成器而推迟的次数（用户第 1 项：不跟踪结果）
        sent = self.craftStats.sent,
        deferred = self.craftStats.idle,
    }
end

--- 给网页 / 诊断看的合成器列表（含它自报的网络外设名 = 主控看到的 turtle 外设名）
function Transfer:craftersForUi()
    local now = os.epoch("utc")
    local out = {}
    for _, crafter in pairs(self.crafters) do
        local mismatch = (type(crafter.version) == "string" and crafter.version ~= "" and
            crafter.version ~= self.version) and true or false
        out[#out + 1] = {
            id = crafter.id,
            name = crafter.name,
            label = crafter.label or ("crafter-#" .. tostring(crafter.id)),
            version = crafter.version,
            versionMismatch = mismatch,
            busy = crafter.busy and true or false,
            jobs = crafter.jobs or 0,
            crafted = crafter.crafted or 0,
            age = math.floor((now - (crafter.lastSeen or now)) / 1000),
            --- 用户第 2 项：它上报的物品栏（抽产物时按它选槽位）
            inventoryStacks = crafter.inventory and #(crafter.inventory.items or {}) or 0,
            inventoryAt = crafter.inventory and crafter.inventory.at or nil,
        }
    end
    table.sort(out, function(a, b)
        return tostring(a.name or a.id) < tostring(b.name or b.id)
    end)
    return out
end

--- 周期任务：广播 hello 让 worker 报到、清理掉线 worker、任务超时作废
function Transfer:tick(now)
    now = now or os.epoch("utc")
    self:ensureModem()
    --- 发件箱出队的位置（用户第 5 项）：**不在这里发**。
    --- 主控每个 tick 的顺序是"维护(这里) → 队列轮转(key=派活)"，如果在这里发，那么本轮
    --- 轮转里派出去的搬运/查询/详情要等到下个 tick 才出门。现在由 IFMMaster.masterTick 在
    --- 轮转**之后**统一 flush 一次：同一 tick 内同一台 worker 的所有任务合并成 1 次 modem 调用
    --- （见 flushOutbox），既最少事件、又不额外多等一个 tick。
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
    --- 机械臂合成器 + worker 的掉线判定（用户第 1 项：worker 时而在线时而不在线）：
    ---   ① 先算出"主控自己这一轮隔了多久"（一次同步写盘 / 超长外设调用能让主循环停几十秒）——
    ---      那段时间里 worker 的消息根本没被处理，它们并不是掉线，所以判定时把这截时间扣掉；
    ---   ② 超过 WORKER_TIMEOUT 只是**标失联**（网页上卡片还在、红字提示，也不再派新活），
    ---      超过 WORKER_EVICT_TIMEOUT 才真正从注册表里摘掉 —— 以前两个阈值都是 15 秒，
    ---      worker 只要安静十几秒，卡片就消失，再出现时计数清零，看起来就是"忽上忽下"。
    local stall = math.max(0, (self.lastTickAt and (now - self.lastTickAt)) or 0)
    self.lastTickAt = now
    self.lastStallMs = stall
    if stall >= WORKER_TIMEOUT and
        not (self.stallLoggedAt and now - self.stallLoggedAt < 30000) then
        self.stallLoggedAt = now
        self.log.warn("Master loop was stalled for %ds: offline checks discounted by that much " ..
            "(workers are NOT considered offline just because we stopped listening)",
            math.floor(stall / 1000))
    end
    --- 机械臂合成器掉线：从注册表里摘掉（它手上的合成指令本来就是"发出去就不管了"，无需清理）
    for id, crafter in pairs(self.crafters) do
        if now - (crafter.lastSeen or 0) - stall > WORKER_EVICT_TIMEOUT then
            self.crafters[id] = nil
            self.log("crafter #%s%s offline (no message for %dms)",
                tostring(id), crafter.name and (" (" .. tostring(crafter.name) .. ")") or "", WORKER_EVICT_TIMEOUT)
        end
    end
    --- worker 掉线：它手上的任务作废（引擎下个 tick 会看到失败原因并重试）
    for id, worker in pairs(self.workers) do
        local silent = now - (worker.lastSeen or now) - stall
        if silent > WORKER_TIMEOUT and not worker.staleLogged then
            worker.staleLogged = true
            self.log("IFMWorker #%s%s silent for %ds - marked stale (card stays, no new jobs until it reports again)",
                tostring(id), self:workerLabel(worker), math.floor(silent / 1000))
        end
        if silent > WORKER_EVICT_TIMEOUT then
            self.workers[id] = nil
            self.log("IFMWorker #%s%s offline (no message for %ds) - its pending moves were dropped and will be retried",
                tostring(id), self:workerLabel(worker), math.floor(WORKER_EVICT_TIMEOUT / 1000))
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
                    --- 用户第 2 项：worker 被摘除时也要通知主控 —— 那条容器的扫描如果正由它代扫，
                    --- 不通知就会永远卡在"在飞"，那个容器再也不更新（网页上的内容停在旧状态）。
                    if self.onQueryDropped then
                        pcall(self.onQueryDropped, query.key, "IFMWorker offline")
                    end
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
                    self:workerBegin(worker)
                    worker.busyKind = "query"
                end
            end
        end
        if age > QUERY_TIMEOUT then
            self.queries[queryId] = nil
            self.queryRunning[query.key] = nil
            self.queryStats.failed = self.queryStats.failed + 1
            --- 用户第 2 项：告诉主控"这条查询作废了" —— 容器代扫要靠它把扫描队列里那条容器的
            --- 在飞任务结束掉（否则永远挂在 inflight、那个容器再也不扫）。
            if self.onQueryDropped then
                pcall(self.onQueryDropped, query.key, "query timeout")
            end
            if worker then
                self:workerEnd(worker)
                worker.timeouts = (worker.timeouts or 0) + 1
                if not self:workerHasPending(worker) then
                    worker.busyKind = nil
                end
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
            if worker then
                self:workerEnd(worker)
                if not self:workerHasPending(worker) then
                    worker.busyKind = nil
                end
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
        --- 本机任务（worker == "local"）不参与这里的超时作废：它由主控的协程池推进，
        --- 主控还在跑就说明它没卡死；一旦在这里把它标成失败，调用方会重新发起同一个搬运，
        --- 而协程还在跑 —— 那就是“同一次搬运被搬两遍”。卡住的本机任务由 pumpLocal 的
        --- overrun 警告提示（见 LOCAL_OVERRUN_MS）。
        if job.state == "pending" and job.worker ~= "local" and now - (job.at or 0) > JOB_TIMEOUT then
            --- 超时：交出 worker，任务作废（迟到的结果会被忽略；引擎下个 tick 会用新任务号重试）
            job.state = "failed"
            job.error = "IFMWorker job timeout"
            self.stats.timedOut = self.stats.timedOut + 1
            local worker = self.workers[job.worker]
            if worker then
                self:workerEnd(worker)
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
    --- 用户第 5 项：查询也走"发件箱"打包（以前每条查询立刻 send 一次 modem）——
    --- 27 个容器 = 27 次 modem 发送/轮，CC:T 的 modem_message 事件会很快积压到 256 条的
    --- 上限然后开始丢事件（扫描结果时有时无就是这么来的）。
    --- 现在同一 tick 内发给同一台 worker 的搬运/查询/详情合并成一次 modem 调用（见 flushOutbox）。
    return self:queueTo(worker, {
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
        --- 有 worker 但槽位都满了（或都不支持查询）：交回调用方本机读（1.8.0）。
        --- 以前这里返回 "pending"：那条队列任务会一直挂着等一个永远不会来的结果
        --- （用户现场：队列深度不降、worker 却看起来空闲）。
        return "local"
    end
    self.querySeq = self.querySeq + 1
    local id = self.querySeq
    if not self:sendQuery(worker, id, spec) then
        return "pending"
    end
    self:workerBegin(worker)
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
    --- 同样走发件箱（见 sendQuery 的说明）：一个 tick 里所有代查合并成一次 modem 调用
    return self:queueTo(worker, {
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
    self:workerBegin(worker)
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
    --- 私有作业频道（1.8.0）：worker 每秒上报一次，主控据此把作业发到只有它收得到的频道上
    if tonumber(message.jobChannel) then
        local chan = math.floor(tonumber(message.jobChannel))
        if worker.jobChannel ~= chan then
            worker.jobChannel = chan
            self.log("IFMWorker #%s private job channel: %d (jobs no longer hit the shared channel)",
                tostring(worker.id), chan)
        end
    end
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
    --- 卡住被摘掉的任务数（worker 侧统计：>0 说明某个容器/外设长时间不响应）
    worker.stuck = tonumber(message.stuck) or worker.stuck or 0
    --- 并发槽位（1.8.0 = 每台最多 64 条并行）：由 worker 自己上报；它报的 load 用来校正计数。
    if tonumber(message.slots) and tonumber(message.slots) >= 1 then
        worker.slots = math.floor(tonumber(message.slots))
    end
    worker.load = tonumber(message.load) or worker.load
    --- 本轮第 6 项：worker 整秒内的峰值并发（网页的负载条用它；load 只是"上报这一刻"的值，
    --- 任务很短，直接显示 load 永远是 0）。
    worker.peak = tonumber(message.peak) or worker.peak
    --- 在飞计数以 worker 自己上报的为准（主控这边没有它的在飞任务时）：
    --- 主控只是"发出去时 +1"，万一回报丢了（modem 丢包 / worker 重启），这个计数就会一直挂着 ——
    --- 网页显示「工作中」却看不到任务，而且它的槽位再也收不到活。
    --- 这里用 worker 每秒一次的 state 把计数纠正回来；真有在飞任务时不动（等结果 / 超时处理）。
    if not self:workerHasPending(worker) then
        local slots = self:workerSlots(worker)
        local reported = tonumber(message.load)
        if reported == nil then
            --- 老版本 worker 不报 load：退回它的 busy 布尔量（true = 槽位全满）
            reported = (message.busy == true) and slots or 0
        end
        reported = math.max(0, math.min(slots, math.floor(reported)))
        worker.inFlight = reported
        local full = worker.inFlight >= slots
        worker.busy = full
        if not full then
            worker.busyKind = nil
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
        --- 并发负载：优先用 worker 自己上报的在跑条数（它包含搬运 + 查询 + 详情），
        --- 主控这边的 inFlight 只统计搬运 —— 以前只报 inFlight，于是 worker 在跑查询时网页上
        --- 一直显示 0/64（用户反馈的"从节点并发量一直是 0"就是这么来的）。
        local slots = self:workerSlots(worker)
        local load = math.max(tonumber(worker.load) or 0, tonumber(worker.inFlight) or 0)
        load = math.max(0, math.min(slots, load))
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
            --- 并发槽位（1.8.0）：worker 一次能并行跑几条任务、现在跑着几条
            slots = slots,
            load = load,
            --- 本轮第 6 项：worker 上报的"整秒峰值并发"（网页用它画负载条：
            --- 任务往往 1 个游戏刻就完，只显示 load 会一直是 0）
            peak = tonumber(worker.peak) or 0,
            free = math.max(0, slots - load),
            --- 卡住被摘掉的任务数（>0 = 某个容器/外设长时间不响应，网页会标出来）
            stuck = worker.stuck or 0,
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
