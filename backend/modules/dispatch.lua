-- IFM :: modules/dispatch.lua
-- 任务调度器（1.8.0 双队列版）：每个来源一条队列，队列之间轮转（round-robin），
-- 队列内部 FIFO；每条队列有自己的权重（正整数，网页「设置」可改）。
--
-- 为什么要有它：以前"什么时候推进哪个流程 / 读哪个容器"散落在主循环各处，并且用
-- 一堆硬间隔（扫描间隔、每 tick 条数上限、冷却）来限流 —— 结果是"任务积压着、
-- 大量 IFMWorker 却空闲"。现在：
--   * 调度只由 timer 事件驱动（主循环每 1 个游戏刻 = 50ms 跑一次）；
--   * 有空闲 worker 就派给 worker；worker 不够时主控自己用协程池并行做（1.8.0）；
--   * 任务失败/未完成时按队列策略处理（回"等待队列"或直接丢弃）。
--
-- ===== 双队列（用户第 4 项）=====
-- 每条队列其实是**两个**环形队列（modules/queue.lua）：
--   active  "正在执行"：一轮调度里只从这里出队执行；
--   waiting "另一个队列"：重试/未完成的任务进这里，**下一轮开始前**才合并（或交换）回 active。
-- 于是"同一个任务一轮只执行一次"是结构上保证的 —— 不需要给每个任务打 tickId，
-- 也就没有"回队尾后同一轮又被取出来执行"的无意义重试：
--   * 每个 tick 开始时：active 为空 → 交换两个队列；否则把 waiting 整体并到 active 尾部
--     （保证 active 一直在进新任务时，waiting 里的任务也不会饿死）；
--   * 上层可以按需在队列为空/有变化时主动推进（见 Dispatch:promote）。
--
-- 任务表（task）约定：
--   task.key        去重键（可选）：同一个 key 在队列里/在飞时只允许有一条
--   task.<其它字段> 由队列自己的 run 解释（例如流程队列只放 name）
-- run(task, now) 的返回值：
--   false/nil   这一步做完了 → 出队（不再回来）
--   true        未完成 / 需要重试 → 按队列策略：双队列进 waiting；policy="drop" 直接丢弃
--   "pending"   在等外部结果（例如已交给 IFMWorker，等它回报）→ 进 waiting（任何队列都一样，
--               因为"等结果"不是失败，丢了它那笔搬运就没人结算了）
--   "drop"      这一步失败/没得做 → 直接丢弃（由生成器下次重建）
--   "inflight"  已经交给 IFMWorker，正在飞：任务出队（不计完成、也不重试），
--               结果由回报路径调用 Dispatch:finishInflight 处理

local Dispatch = {}
Dispatch.__index = Dispatch

--- 队列的默认权重（1.8.0：0 ~ 1 的小数，所有队列加起来应为 1；0 = 不参与轮转）。
--- 1.7.0 起权重决定"这条队列在轮转里占多大比例"，不是"一次连跑多少步"（见 advanceRound）。
Dispatch.DEFAULT_SLICE = 0.1

--- 建调度器（队列随后用 addQueue 加）
--- opts.Queue = modules/queue.lua（环形队列实现；必传 —— 调度器不再自己维护数组游标）
--- 日志分级兼容（用户第 2 项）：调用点用 self.log(...) / self.log.warn(...) / self.log.error(...)，
--- 而老的调用方 / 测试桩传进来的可能只是一个普通函数 —— 这里统一包成"可调用的表"。
--- （Lua 里函数不能挂字段也不能设元表，所以必须包一层。）
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

function Dispatch.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Dispatch)
    self.log = levelLogger(opts.log)
    self.store = opts.store           -- 每轮调度顺手写盘（只脏才写）
    self.cache = opts.cache
    self.transfer = opts.transfer     -- 判断 worker 是否空闲（可为 nil）
    self.Queue = opts.Queue
    if not self.Queue then
        error("dispatch.lua needs the queue module: pass opts.Queue (loadModule(\"queue\"))", 0)
    end
    self.queues = {}                  -- name -> queue
    self.order = {}                   -- 固定轮转顺序（name 列表）
    self.generators = {}              -- 每轮调度前的生成器（纯内存）
    self.maintain = nil               -- 维护回调（心跳/超时/重发/掉线）
    self.cursor = 1                   -- 轮转游标（跨 tick 持久：下个 tick 从这里继续）
    self.stats = {
        runs = 0, steps = 0, localSteps = 0, remoteSteps = 0, paused = 0, inflight = 0,
        promoted = 0,                 -- 从"等待队列"并回"正在执行"队列的任务数
        ms = 0, maxMs = 0, lastMs = 0, writes = 0, startedAt = os.epoch("utc"),
    }
    return self
end

--- 建一个队列。
--- opts = { needs = "none"|"query"|"move", run = function(task, now),
---          policy = "retry"|"drop", slice = n }
--- policy 的语义（1.8.0 双队列）：
---   "retry"  run 返回 true（未完成 / 失败）→ 进 waiting，下一轮再执行（流程 / 扫描 / 出库）
---   "drop"   run 返回 true → 直接丢弃（入库 / 整理 / 详情 / 手动：一步做完就结束，失败不重试）
--- 两种策略下 run 返回 "pending"（在等外部结果，例如等 worker 回报）都会进 waiting ——
--- 那是"还没做完"，不是失败；丢了它那笔搬运就再也没人结算了。
--- 重复注册同名队列是"更新"而不是"覆盖"：只改显式传进来的字段，其余保持不变。
--- （踩过的坑：某次补丁把两条 addQueue 合并成一行，第二次调用没带 run，
---   于是整条队列的 run 被换成默认空跑 —— 表现为 worker 永远空闲、什么都没有发生。）
function Dispatch:addQueue(name, opts)
    opts = opts or {}
    local queue = self.queues[name]
    if not queue then
        queue = {
            name = name,
            needs = opts.needs or "none",
            run = opts.run or function() return false end,
            policy = opts.policy or "retry",
            --- 权重：0.01 ~ 1-0.01n 的小数（网页「设置」里所有队列加起来 = 1；不允许 0）
            slice = math.max(0.01, math.min(0.99, tonumber(opts.slice) or Dispatch.DEFAULT_SLICE)),
            credit = 0,                 -- 平滑加权轮转的额度（见 advanceRound）
            active = self.Queue.new(),  -- "正在执行"队列（一轮里只从这里出队）
            waiting = self.Queue.new(), -- "另一个队列"（重试 / 等结果；下一轮开始前并回 active）
            keys = {},                  -- 去重表：key -> true（在 active 或 waiting 里）
            inflight = {},              -- key -> task（已经交给 worker、还没回报）
            served = 0, done = 0, dropped = 0, retried = 0, queued = 0, promoted = 0,
        }
        self.queues[name] = queue
        self.order[#self.order + 1] = name
        if not opts.run then
            --- 编码规范（用户第 1 项）：注册时没给 run = 未定义行为，明确报错（别等运行时才发现队列什么都不做）
            queue.noRunner = true
            self.stats.missingRunner = (self.stats.missingRunner or 0) + 1
            self.log.error("[IFM] dispatch: queue %s registered without a runner - it will never do anything (bug)", tostring(name))
        end
        return queue
    end
    if opts.needs then queue.needs = opts.needs end
    if opts.run then queue.run = opts.run end
    if opts.policy then queue.policy = opts.policy end
    if opts.slice then
        queue.slice = math.max(0.01, math.min(0.99, tonumber(opts.slice) or queue.slice))
    end
    --- 编码规范（用户第 1 项）：未定义的行为要报错，不许静默失败。
    --- 重复注册同名队列以前会悄悄把 run 换成默认空跑（worker 永远空闲、什么都不发生），
    --- 现在一律留下日志与计数，诊断里能看到。
    self.stats.duplicateQueues = (self.stats.duplicateQueues or 0) + 1
    self.log.warn("[IFM] dispatch: queue %s registered twice - fields merged (run %s)",
        tostring(name), opts.run and "updated" or "kept")
    return queue
end

--- 设置某条队列的权重：0.01 ~ 1-0.01n（n = 队列条数；不允许 0 —— 全是 0 就没法归一化了）
function Dispatch:setSlice(name, value)
    local queue = self.queues[name]
    local number = tonumber(value)
    if not queue or number == nil then
        return false
    end
    local count = math.max(1, #self.order)
    local maxShare = 1 - 0.01 * count
    if number < 0.01 or number > maxShare then
        return false
    end
    queue.slice = number
    return true
end

--- 批量应用时间片（网页「设置」保存后调用）：slices = { queueName = n, ... }
function Dispatch:applySlices(slices)
    if type(slices) ~= "table" then
        return
    end
    for name, value in pairs(slices) do
        self:setSlice(name, value)
    end
end

--- 当前时间片（网页 / 诊断显示）
function Dispatch:slices()
    local out = {}
    for _, name in ipairs(self.order) do
        out[name] = self.queues[name].slice
    end
    return out
end

function Dispatch:addGenerator(fn)
    if type(fn) == "function" then
        self.generators[#self.generators + 1] = fn
    end
end

function Dispatch:setMaintain(fn)
    if type(fn) == "function" then
        self.maintain = fn
    end
end

--- 队列里还有多少条（active + waiting，不含在飞）
function Dispatch:depth(name)
    local queue = self.queues[name]
    if not queue then
        return 0
    end
    return queue.active:len() + queue.waiting:len()
end

--- "正在执行"队列里有多少条（这一轮轮得到几条）
function Dispatch:activeDepth(name)
    local queue = self.queues[name]
    return queue and queue.active:len() or 0
end

--- "另一个队列"里有多少条（重试 / 等结果，下一轮开始前并回 active）
function Dispatch:waitingDepth(name)
    local queue = self.queues[name]
    return queue and queue.waiting:len() or 0
end

--- 这个 key 是否已经排队 / 在飞（生成器用它去重；任务出队时自动清掉）
function Dispatch:isQueued(name, key)
    local queue = self.queues[name]
    if not queue then
        return false
    end
    if key == nil then
        return self:depth(name) > 0
    end
    return queue.keys[key] == true or queue.inflight[key] ~= nil
end

--- 入队：新产生的任务进"正在执行"队列（用户第 4 项：新任务本轮就能做，不用等下一轮）
function Dispatch:enqueue(name, task)
    local queue = self.queues[name]
    if not queue or type(task) ~= "table" then
        return false
    end
    local key = task.key
    if key ~= nil and (queue.keys[key] or queue.inflight[key]) then
        return false
    end
    queue.active:push(task)
    if key ~= nil then
        queue.keys[key] = true
    end
    queue.queued = queue.queued + 1
    return true
end

--- 取出"正在执行"队列的队首（内部用；同时清掉去重键）
function Dispatch:pop(queue)
    local task = queue.active:pop()
    if task and task.key ~= nil then
        queue.keys[task.key] = nil
    end
    return task
end

--- 重试 / 等结果：进"另一个队列"（下一轮开始前才并回 active）。
--- 这就是双队列的全部秘密：重试的任务**不在**正在执行的队列里，所以同一轮不可能被再取出来执行。
function Dispatch:pushBack(queue, task)
    queue.waiting:push(task)
    if task.key ~= nil then
        queue.keys[task.key] = true
    end
end

--- 把"另一个队列"并回"正在执行"队列（调度器每个 tick 开始前调用一次）：
---   active 空 → 直接交换（用户第 4 项："如果当前执行的队列已空，交换两个队列"）；
---   否则整体附加到 active 尾部（保证 active 一直有新任务进来时，等待中的任务也不会饿死）。
--- 支持传队列名或队列本身；返回并回的任务数。
function Dispatch:promote(name)
    local queue = type(name) == "table" and name or self.queues[name]
    if not queue or queue.waiting:len() == 0 then
        return 0
    end
    local moved
    if queue.active:len() == 0 then
        queue.active, queue.waiting = queue.waiting, queue.active
        moved = queue.active:len()
    else
        moved = queue.active:append(queue.waiting)
    end
    if moved > 0 then
        queue.promoted = (queue.promoted or 0) + moved
        self.stats.promoted = (self.stats.promoted or 0) + moved
    end
    return moved
end

--- 按 key 撤掉任务（两个队列都撤，也清掉去重键）。
--- 用途：容器外设被移除 / 用户删掉存储容器角色 → 它的扫描任务要从队列里撤掉，
--- 否则这些任务会一直重试一个已经不存在的外设（每次都失败、白占额度）。
function Dispatch:removeKey(name, key)
    local queue = self.queues[name]
    if not queue or key == nil then
        return 0
    end
    local function match(task)
        return type(task) == "table" and task.key == key
    end
    local removed = queue.active:removeWhere(match)
    removed = removed + queue.waiting:removeWhere(match)
    if removed > 0 then
        queue.keys[key] = nil
    end
    return removed
end

--- 按条件撤掉任务（两个队列都撤，命中的任务会清掉自己的去重键）。
--- 返回撤掉的条数。在飞的任务不在这里（它们由回报路径 / 超时处理）。
function Dispatch:removeWhere(name, pred)
    local queue = self.queues[name]
    if not queue or type(pred) ~= "function" then
        return 0
    end
    local function match(task)
        if not pred(task) then
            return false
        end
        if type(task) == "table" and task.key ~= nil then
            queue.keys[task.key] = nil
        end
        return true
    end
    return queue.active:removeWhere(match) + queue.waiting:removeWhere(match)
end

--- 任务已经交给 worker：出队并记为在飞（结果回来时由生产者调用 finishInflight）
function Dispatch:markInflight(queue, task)
    if task.key ~= nil then
        queue.inflight[task.key] = task
    end
    task.state = "inflight"
    self.stats.inflight = self.stats.inflight + 1
end

--- 在飞任务有结果了（成功 / 失败 / 超时都算）：返回该任务，由调用方决定是否重新入队
function Dispatch:finishInflight(name, key)
    local queue = self.queues[name]
    if not queue or key == nil then
        return nil
    end
    local task = queue.inflight[key]
    if not task then
        return nil
    end
    queue.inflight[key] = nil
    self.stats.inflight = math.max(0, self.stats.inflight - 1)
    return task
end

--- 在飞任务表（诊断 / 掉线清理）
function Dispatch:inflightTasks(name)
    local queue = self.queues[name]
    return queue and queue.inflight or {}
end

--- 当前工作模式：
---   "local"   没有可用 worker（或本机也没位子）→ 主控本机执行（本机协程池，最多 32 条并行）
---   "remote"  有 worker 且有空闲槽位 → 队列推进（派给 worker）
---   "mixed"   有 worker 但槽位都满了 → 主控自己也并行做（本机协程还有空位时）
---   "paused"  谁都没有空位 → 本次调度不推进队列（写盘 / 维护照做）
function Dispatch:mode()
    local transfer = self.transfer
    if not transfer then
        return "local"
    end
    local hasLocalSlots = transfer.localFreeSlots and transfer:localFreeSlots() > 0
    if not transfer.workerCount or transfer:workerCount() == 0 then
        return "local"
    end
    local idle = transfer.idleCount and transfer:idleCount() or 0
    if idle > 0 then
        return "remote"
    end
    --- worker 全忙：主控自己上（这正是用户第 3 项要的效果 —— 队列不再整条停住）
    return hasLocalSlots and "mixed" or "paused"
end

--- 这个队列现在可以推进吗：
---   none 队列：总是可以（本机执行）；
---   需要 worker 的队列：有空闲 worker 可以；没有的话看主控本机还有没有空闲协程位
---   （1.8.0：本机协程池让主控也能并行执行，所以“worker 全忙”不再等于“队列停住”）。
function Dispatch:runnable(queue, mode)
    if queue.needs == "none" then
        return true
    end
    local transfer = self.transfer
    if not transfer then
        return mode == "local"
    end
    if transfer.idleCount and transfer:idleCount(queue.needs) > 0 then
        return true
    end
    if mode == "local" or mode == "mixed" then
        if transfer.localFreeSlots then
            return transfer:localFreeSlots() > 0
        end
        return mode == "local"
    end
    return false
end

--- 执行一条任务：出队 → 跑 → 按返回值决定它去哪
---   false/nil → 完成（出队）
---   true      → 未完成/失败：policy="retry" 进 waiting；policy="drop" 直接丢弃
---   "pending" → 在等外部结果：进 waiting（与 policy 无关，丢了它那笔活就没人结算）
---   "drop"    → 直接丢弃
---   "inflight"→ 交给 worker 在飞：出队，结果由 finishInflight 处理
--- 注意：重试的任务进的是 waiting（"另一个队列"），不在"正在执行"队列里 ——
--- 所以同一轮不可能再被取出来执行（这就是双队列替代 tickId 的原因）。
function Dispatch:runTask(queue, task, now, mode)
    --- 编码规范（用户第 1 项）：没配 run 的队列是"未定义行为"，必须报错而不是悄悄啥也不做
    if queue.noRunner then
        queue.missingRunner = (queue.missingRunner or 0) + 1
        self.stats.missingRunner = (self.stats.missingRunner or 0) + 1
        if queue.missingRunner == 1 then
            self.log.error("[IFM] dispatch: queue %s has NO runner - tasks are being dropped (bug)", tostring(queue.name))
        end
        queue.dropped = queue.dropped + 1
        return false
    end
    local ok, result = pcall(queue.run, task, now)
    if not ok then
        self.log.error("[IFM] dispatch task failed (%s/%s): %s", queue.name, tostring(task.key), tostring(result))
        result = queue.policy ~= "drop"
    end
    queue.served = queue.served + 1
    self.stats.steps = self.stats.steps + 1
    if mode == "local" then
        self.stats.localSteps = self.stats.localSteps + 1
    else
        self.stats.remoteSteps = self.stats.remoteSteps + 1
    end
    if result == "inflight" then
        self:markInflight(queue, task)
        return true
    end
    if result == "drop" then
        -- 任务自己判断"这一步失败/没得做"：直接丢弃（由生成器下次重建）
        queue.dropped = queue.dropped + 1
        return false
    end
    if result == "pending" or result == true then
        if result == "pending" or queue.policy ~= "drop" then
            queue.retried = queue.retried + 1
            self:pushBack(queue, task)
        else
            queue.dropped = queue.dropped + 1
        end
        return true
    end
    queue.done = queue.done + 1
    return false
end

--- 没有 worker（或本机协程池模式）：每次调度只推进一步（从游标开始找第一个可推进且非空的队列）
function Dispatch:advanceOne(now)
    local count = #self.order
    for _ = 1, count do
        local queue = self.queues[self.order[self.cursor]]
        self.cursor = (self.cursor % count) + 1
        if queue and self:depth(queue.name) > 0 and self:runnable(queue, "local") then
            local task = self:pop(queue)
            if task then
                self:runTask(queue, task, now, "local")
                return 1
            end
        end
    end
    return 0
end

--- 有 worker：平滑加权轮转，**一直派到派不动为止**（用户第 5 项）。
--- slice 的语义 = 权重，它只决定"下一件先派谁"，**不限制一轮能派多少**：
---   * 每次选择前给"还有活可派"的队列各加一份自己的权重，挑额度最高的一条执行一步，
---     然后按"总权重"扣回去 —— nginx 的 smooth weighted round robin。
---     于是 process=50 / storageScan=20 时顺序是 流程、扫描、流程、流程、扫描…，
---     但两者都会一直派到自己没活、或者没容量为止（不再按权重分一个 32 步的预算）。
---   * 停止条件（用户第 5 项原文）：所有队列都已空，或者所有 worker 的负载已满
---     （启用"主控分担任务"时，再加上主控本机协程池的负载）。
---   * 本机执行的队列（needs = "none"，每步可能是一次阻塞外设调用）**保留**每 tick
---     MASTER_STEPS_PER_TICK 步的旧上限；需要 worker 的队列不受它限制。
local MASTER_STEPS_PER_TICK = 32

--- 防御性上限：正常不可能碰到（任务跑完就离开 active 队列，一轮里 active 只会变少），
--- 只在真的活锁时兜底并留下日志。
local MAX_STEPS_PER_ROUND = 100000

function Dispatch:advanceRound(now, mode)
    local transfer = self.transfer
    --- 每轮开始时算一次容量（用户第 5 项）：
    ---   * 需要 worker 的队列：容量 = "有空位的 worker"，循环里每一步都重算（worker 会被喂满）；
    ---     没有空闲 worker 时回落到主控本机协程池，这一轮最多用掉开始时的那几个空闲位。
    ---   * 本机执行的队列（needs = "none"）：保留旧的 32 步预算（按权重折算，见 MASTER_STEPS_PER_TICK）。
    local localFallback = 0
    if transfer and transfer.localFreeSlots then
        localFallback = math.max(0, tonumber(transfer:localFreeSlots()) or 0)
    end
    local budgets = {}
    for _, name in ipairs(self.order) do
        local queue = self.queues[name]
        if queue and queue.needs == "none" then
            local weight = math.max(0, tonumber(queue.slice) or 0)
            budgets[name] = math.max(1, math.ceil(weight * MASTER_STEPS_PER_TICK))
        end
    end
    local steps = 0
    local guard = 0
    while true do
        guard = guard + 1
        if guard > MAX_STEPS_PER_ROUND then
            self.log.warn("[IFM] dispatch: one round ran %d steps - stopping this round (possible livelock)",
                steps)
            break
        end
        --- 每一轮重新收集：容量与深度都随着派发在变（worker 会被喂满、本机池也会被占满）。
        local eligible = {}
        local totalWeight = 0
        local viaLocal = {}
        local count = #self.order
        for _ = 1, count do
            local name = self.order[self.cursor]
            local queue = self.queues[name]
            self.cursor = (self.cursor % count) + 1
            --- 只看 active：waiting（重试 / 等结果）本来就要等下一轮才并回来，
            --- 否则同一轮里会把同一条任务反复取出来执行。
            if queue and self:activeDepth(name) > 0 and self:runnable(queue, mode) then
                local weight = math.max(0, tonumber(queue.slice) or 0)
                local ok = false
                if weight > 0 then
                    if queue.needs == "none" then
                        ok = (budgets[name] or 0) > 0
                    elseif transfer and transfer.idleCount and transfer:idleCount(queue.needs) > 0 then
                        ok = true                          -- worker 还有容量：一直派
                    else
                        ok = localFallback > 0             -- 没 worker 了：用主控本机池的空闲位
                        viaLocal[name] = ok
                    end
                end
                if ok then
                    totalWeight = totalWeight + weight
                    eligible[#eligible + 1] = queue
                end
            end
        end
        if totalWeight <= 0 then
            break                                          -- 队列都空了，或者都没容量了
        end
        local best = nil
        for _, queue in ipairs(eligible) do
            queue.credit = (queue.credit or 0) + (queue.slice or 0)
            if not best or queue.credit > best.credit then
                best = queue
            end
        end
        local task = self:pop(best)
        if not task then
            break
        end
        self:runTask(best, task, now, mode)
        best.credit = (best.credit or 0) - totalWeight
        if best.needs == "none" then
            budgets[best.name] = (budgets[best.name] or 0) - 1
        elseif viaLocal[best.name] then
            localFallback = localFallback - 1
        end
        steps = steps + 1
    end
    return steps
end

--- 一次调度执行（主控主循环每个 timer 事件调用一次，见 IFMMaster.lua）
function Dispatch:tick(now)
    now = now or os.epoch("utc")
    local started = os.clock()
    self.stats.runs = self.stats.runs + 1

    -- (1) 写盘：只脏才写（写盘很便宜，也不做无谓的写）
    if self.store and self.store.file and self.store.file.dirty then
        if self.store:flush() then
            self.stats.writes = self.stats.writes + 1
        end
    end
    if self.cache and self.cache.file and self.cache.file.dirty then
        if self.cache:flush() then
            self.stats.writes = self.stats.writes + 1
        end
    end

    -- (2) 维护：心跳 / worker 超时 / 任务重发 —— 不属于调度器，worker 再忙也照做
    if self.maintain then
        local ok, err = pcall(self.maintain, now)
        if not ok then
            self.log.error("[IFM] dispatch maintain failed: %s", tostring(err))
        end
    end

    -- (3) 双队列轮换（用户第 4 项）：把"另一个队列"（重试 / 等结果）并回"正在执行"队列。
    --     active 空 → 直接交换；否则附加到尾部。每个 tick 只做一次 —— 这就是
    --     "同一个任务一轮只执行一次"的结构保证（不需要 tickId）。
    for _, name in ipairs(self.order) do
        self:promote(name)
    end

    -- (3) worker 门控：有 worker 但都忙 → 只停“队列推进”
    local mode = self:mode()
    if mode == "paused" then
        self.stats.paused = self.stats.paused + 1
        self.stats.lastMs = (os.clock() - started) * 1000
        return 0
    end

    -- (4) 生成器：把新任务补进队列（纯内存操作）
    for _, generator in ipairs(self.generators) do
        local ok, err = pcall(generator, now)
        if not ok then
            self.log.error("[IFM] dispatch generator failed: %s", tostring(err))
        end
    end

    -- (5) 推进队列。
    --- 没有 worker 时：主控本机执行。1.8.0 起本机也是并行的（最多 32 条协程在飞），
    --- 所以这里同样用轮转推进、每轮上限 = 本机空闲协程位；没有本机协程池的实现
    --- （老的测试桩 / 老调用方）仍然保持“一次调度只推进一步”的老行为。
    local parallelLocal = self.transfer and self.transfer.localFreeSlots ~= nil
    local steps
    if mode == "local" and not parallelLocal then
        steps = self:advanceOne(now)
    else
        steps = self:advanceRound(now, mode)
    end

    local spent = (os.clock() - started) * 1000
    self.stats.ms = self.stats.ms + spent
    self.stats.lastMs = spent
    if spent > (self.stats.maxMs or 0) then
        self.stats.maxMs = spent
    end
    return steps
end

--- 调度状态（网页 / 诊断）
function Dispatch:status()
    local queues = {}
    for _, name in ipairs(self.order) do
        local queue = self.queues[name]
        local inflight = 0
        for _ in pairs(queue.inflight) do
            inflight = inflight + 1
        end
        queues[#queues + 1] = {
            name = name,
            needs = queue.needs,
            policy = queue.policy,
            missingRunner = queue.missingRunner or 0,
            slice = queue.slice,
            --- depth = active + waiting（网页上的"排队/在飞"总数）
            depth = queue.active:len() + queue.waiting:len(),
            --- active = "正在执行"队列（这一轮轮得到几条）；waiting = "另一个队列"（重试/等结果）
            active = queue.active:len(),
            waiting = queue.waiting:len(),
            inflight = inflight,
            served = queue.served,
            done = queue.done,
            dropped = queue.dropped,
            retried = queue.retried,
            promoted = queue.promoted or 0,
            queued = queue.queued,
        }
    end
    return {
        mode = self:mode(),
        cursor = self.cursor,
        runs = self.stats.runs,
        steps = self.stats.steps,
        localSteps = self.stats.localSteps,
        remoteSteps = self.stats.remoteSteps,
        paused = self.stats.paused,
        inflight = self.stats.inflight,
        --- 双队列（用户第 4 项）：从"等待队列"并回"正在执行"队列的任务数（累计）
        promoted = self.stats.promoted or 0,
        lastMs = self.stats.lastMs,
        maxMs = self.stats.maxMs,
        avgMs = self.stats.runs > 0 and (self.stats.ms / self.stats.runs) or 0,
        writes = self.stats.writes,
        uptimeSeconds = math.floor((os.epoch("utc") - (self.stats.startedAt or os.epoch("utc"))) / 1000),
        --- 编码规范相关的守卫计数（用户第 1 项）：非 0 就说明代码里有未定义行为，诊断里能直接看到
        duplicateQueues = self.stats.duplicateQueues or 0,
        missingRunner = self.stats.missingRunner or 0,
        queues = queues,
    }
end

return Dispatch
