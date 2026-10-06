local Dispatch = {}
Dispatch.__index = Dispatch

Dispatch.DEFAULT_SLICE = 0.1

-- Runs handed to a queue per refill cycle: over one cycle every queue executes
-- `weight * CONTINUOUS_RUNS` times, so the schedule weight really is its share.
Dispatch.CONTINUOUS_RUNS = 16

local function levelLogger(fn)
    if type(fn) == "table" and fn.warn ~= nil and fn.error ~= nil then
        return fn
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
    self.Assert = opts.Assert
        or error("dispatch.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.store = opts.store
    self.cache = opts.cache
    self.transfer = opts.transfer
    self.Queue = opts.Queue
    if not self.Queue then
        error("dispatch.lua needs the queue module: pass opts.Queue (loadModule(\"queue\"))", 0)
    end
    self.queues = {}
    self.order = {}
    self.generators = {}
    self.maintain = nil
    self.cursor = 1
    self.round = 0
    self.stats = {
        runs = 0, steps = 0, localSteps = 0, remoteSteps = 0, paused = 0, inflight = 0,
        promoted = 0,
        ms = 0, maxMs = 0, lastMs = 0, writes = 0, startedAt = os.epoch("utc"),
    }
    return self
end

function Dispatch:addQueue(name, opts)
    opts = opts or {}
    local queue = self.queues[name]
    if not queue then
        queue = {
            name = name,
            needs = opts.needs or "none",
            run = opts.run or function() return false end,
            policy = opts.policy or "retry",
            slice = math.max(0.01, math.min(0.99, tonumber(opts.slice) or Dispatch.DEFAULT_SLICE)),
            -- "Runs left": the scheduler spends one run per walk while it is >= 1 and
            -- refills it with weight * CONTINUOUS_RUNS once every counter has dropped
            -- to <= 1. Persists across ticks, so a low-weight queue only waits, it is
            -- never skipped forever.
            remaining = 0,
            singleQueue = opts.singleQueue == true,
            active = self.Queue.new(),
            waiting = opts.singleQueue == true and nil or self.Queue.new(),
            keys = {},
            inflight = {},
            served = 0, done = 0, dropped = 0, retried = 0, queued = 0, promoted = 0,
        }
        self.queues[name] = queue
        self.order[#self.order + 1] = name
        if not opts.run then
            queue.noRunner = true
            self.stats.missingRunner = (self.stats.missingRunner or 0) + 1
            self.log.error("[IFM] dispatch: queue %s registered without a runner - it will never do anything (bug)", tostring(name))
        end
        return queue
    end
    if opts.needs then queue.needs = opts.needs end
    if opts.run then queue.run = opts.run end
    if opts.policy then queue.policy = opts.policy end
    if opts.singleQueue == true and queue.waiting then
        if queue.waiting:len() > 0 then
            queue.active:append(queue.waiting)
        end
        queue.waiting = nil
        queue.singleQueue = true
    end
    if opts.slice then
        queue.slice = math.max(0.01, math.min(0.99, tonumber(opts.slice) or queue.slice))
    end
    self.stats.duplicateQueues = (self.stats.duplicateQueues or 0) + 1
    self.log.warn("[IFM] dispatch: queue %s registered twice - fields merged (run %s)",
        tostring(name), opts.run and "updated" or "kept")
    return queue
end

function Dispatch:setSlice(name, value)
    local queue = self.queues[name]
    local number = tonumber(value)
    if not queue or number == nil then
        return false
    end
    -- The upper bound follows the *weighted* queue set (Store.SCHEDULE_QUEUES), not the
    -- number of registered dispatch queues: a schedule may legitimately give one queue
    -- `1 - 0.01 * (n - 1)`, and a queue without its own weight (compactPlan) is driven by
    -- another one. Bounding it by the queue count silently dropped valid shares.
    local maxShare = 0.99
    local Store = self.store
    if Store and Store.SCHEDULE_QUEUES and Store.weightMax then
        local count = #Store.SCHEDULE_QUEUES
        maxShare = 1 - (Store.SCHEDULE_MIN_SHARE or 0.01) * math.max(0, count - 1)
    end
    if number < 0.01 or number > maxShare then
        return false
    end
    queue.slice = number
    return true
end

function Dispatch:applySlices(slices)
    if type(slices) ~= "table" then
        return
    end
    for name, value in pairs(slices) do
        self:setSlice(name, value)
    end
end

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

function Dispatch:depth(name)
    local queue = self.queues[name]
    if not queue then
        return 0
    end
    return queue.active:len() + (queue.waiting and queue.waiting:len() or 0)
end

function Dispatch:activeDepth(name)
    local queue = self.queues[name]
    return queue and queue.active:len() or 0
end

function Dispatch:waitingDepth(name)
    local queue = self.queues[name]
    return (queue and queue.waiting and queue.waiting:len()) or 0
end

function Dispatch:roundBlocked(queue)
    return queue ~= nil and queue.blockedRound == self.round
end

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

function Dispatch:enqueue(name, task, opts)
    local queue = self.queues[name]
    if not queue or type(task) ~= "table" then
        return false
    end
    local key = task.key
    local ignoreInflight = type(opts) == "table" and opts.ignoreInflight == true
    if key ~= nil then
        if queue.keys[key] then
            return false
        end
        if not ignoreInflight and queue.inflight[key] then
            return false
        end
    end
    queue.active:push(task)
    if key ~= nil then
        queue.keys[key] = true
    end
    queue.queued = queue.queued + 1
    return true
end

function Dispatch:pop(queue)
    local task = queue.active:pop()
    if task and task.key ~= nil then
        queue.keys[task.key] = nil
    end
    return task
end

function Dispatch:pushBack(queue, task)
    if not queue.waiting then
        self:requeue(queue, task)
        return
    end
    queue.waiting:push(task)
    if task.key ~= nil then
        queue.keys[task.key] = true
    end
end

function Dispatch:requeue(queue, task)
    if type(task) == "table" then
        task.__round = self.round
    end
    queue.active:push(task)
    if type(task) == "table" and task.key ~= nil then
        queue.keys[task.key] = true
    end
    queue.retried = (queue.retried or 0) + 1
end

function Dispatch:promote(name)
    local queue = type(name) == "table" and name or self.queues[name]
    if not queue or not queue.waiting or queue.waiting:len() == 0 then
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

function Dispatch:removeKey(name, key)
    local queue = self.queues[name]
    if not queue or key == nil then
        return 0
    end
    local function match(task)
        return type(task) == "table" and task.key == key
    end
    local removed = queue.active:removeWhere(match)
    if queue.waiting then
        removed = removed + queue.waiting:removeWhere(match)
    end
    if removed > 0 then
        queue.keys[key] = nil
    end
    return removed
end

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
    return queue.active:removeWhere(match)
        + (queue.waiting and queue.waiting:removeWhere(match) or 0)
end

function Dispatch:markInflight(queue, task)
    if task.key ~= nil then
        queue.inflight[task.key] = task
    end
    task.state = "inflight"
    self.stats.inflight = self.stats.inflight + 1
end

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

function Dispatch:inflightTasks(name)
    local queue = self.queues[name]
    return queue and queue.inflight or {}
end

function Dispatch:mode()
    local transfer = self.transfer
    if not transfer or not transfer.workerCount then
        return "paused"
    end
    -- The master has no executor of its own any more: work is either running on
    -- remote workers ("remote") or waiting because none is online ("paused").
    return transfer:workerCount() > 0 and "remote" or "paused"
end

function Dispatch:runnable(queue, mode)
    -- Remote workers and the master's own executor share one pool, so a queue is
    -- runnable as soon as any executor has a free slot. `needs` stays for the status
    -- panel and the manual-container pre-check only.
    return not self:executorsFull()
end

function Dispatch:runTask(queue, task, now, mode)
    if queue.noRunner then
        queue.missingRunner = (queue.missingRunner or 0) + 1
        self.stats.missingRunner = (self.stats.missingRunner or 0) + 1
        if queue.missingRunner == 1 then
            self.log.error("[IFM] dispatch: queue %s has NO runner - tasks are being dropped (bug)", tostring(queue.name))
        end
        queue.dropped = queue.dropped + 1
        return false
    end
    if queue.singleQueue and type(task) == "table" and task.__round == self.round then
        queue.blockedRound = self.round
        queue.active:push(task)
        if task.key ~= nil then
            queue.keys[task.key] = true
        end
        return false
    end
    local runStart = os.epoch("utc")
    -- Business failures are returned by the queue runners, not raised, so nothing
    -- here catches exceptions: a raised error is a bug and takes the master down.
    local result = queue.run(task, now)
    do
        local byQueue = self.stats.byQueue
        if not byQueue then
            byQueue = {}
            self.stats.byQueue = byQueue
        end
        local entry = byQueue[queue.name]
        if not entry then
            entry = { calls = 0, ms = 0, maxMs = 0, slow = 0 }
            byQueue[queue.name] = entry
        end
        local cost = os.epoch("utc") - runStart
        entry.calls = entry.calls + 1
        entry.ms = entry.ms + cost
        if cost > entry.maxMs then
            entry.maxMs = cost
        end
        if cost >= 50 then
            entry.slow = entry.slow + 1
        end
        -- Per-run max for this queue (reset every Dispatch:tick), so the fatal message
        -- can tell "one heavy task" (max ~ runMs) apart from "many cheap tasks".
        local runMax = self.runQueueMax
        if runMax then
            local cur = runMax[queue.name]
            if not cur or cost > cur then
                runMax[queue.name] = cost
            end
        end
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

-- ---------------------------------------------------------------- scheduler walk
--
-- Weighted round robin over the queues in a fixed order. Every queue carries a
-- "runs left" counter (`remaining`):
--
--   * a queue with remaining >= 1 spends one run: the counter drops by one and, if
--     the queue still holds work, one element is taken and executed;
--   * a run only happens while some executor (a remote worker or the master's own
--     executor) still has a free slot; the moment every executor is full the walk
--     stops and the leftover counters survive into the next tick;
--   * once every counter has dropped to <= 1 the counters are refilled with
--     `weight * CONTINUOUS_RUNS`; over a full refill cycle each queue therefore
--     executes in proportion to its schedule weight;
--   * the walk also stops as soon as no queue has runnable work left. A queue that
--     answered "pending" is parked in its waiting queue and only promoted again at
--     the start of the next tick, so nothing that is parked can spin this loop.
--
-- No step budget is needed: a slot is never freed inside a tick and every executed
-- element spends exactly one.
function Dispatch:syncOrder()
    if self.orderSynced then
        return
    end
    self.orderSynced = true
    local names = self.store and self.store.SCHEDULE_QUEUES
    if type(names) ~= "table" or #names == 0 then
        return
    end
    local rank = {}
    for index, name in ipairs(names) do
        rank[name] = index
    end
    local order = {}
    for _, name in ipairs(self.order) do
        order[#order + 1] = name
    end
    table.sort(order, function(a, b)
        local ra, rb = rank[a], rank[b]
        if ra and rb then
            return ra < rb
        end
        if ra then
            return true
        end
        return false
    end)
    self.order = order
end

-- Executors that still have a free slot. Every instruction runs on a remote worker
-- now, so this is exactly the workers' free slot count: "all workers are full" and
-- "no worker online" both pause the scheduler.
function Dispatch:executorsFull()
    local transfer = self.transfer
    if not transfer then
        return false
    end
    if transfer.freeExecutorSlots then
        return transfer:freeExecutorSlots() <= 0
    end
    return not (transfer.idleCount and transfer:idleCount() > 0)
end

function Dispatch:anyReadyWork(mode)
    for _, name in ipairs(self.order) do
        local queue = self.queues[name]
        if queue and queue.active:len() > 0 and self:runnable(queue, mode)
            and not self:roundBlocked(queue) then
            return true
        end
    end
    return false
end

function Dispatch:allRemainingAtMostOne()
    for _, name in ipairs(self.order) do
        local queue = self.queues[name]
        if queue and (tonumber(queue.remaining) or 0) > 1 then
            return false
        end
    end
    return true
end

function Dispatch:refill()
    for _, name in ipairs(self.order) do
        local queue = self.queues[name]
        if queue then
            local weight = math.max(0, tonumber(queue.slice) or 0)
            queue.remaining = (tonumber(queue.remaining) or 0) + weight * Dispatch.CONTINUOUS_RUNS
        end
    end
end

function Dispatch:advanceAll(now, mode)
    self:syncOrder()
    local steps = 0
    -- The walk only stops when every executor is full or nothing is ready (see
    -- the header comment above). A pass that spends nothing while ready work
    -- remains therefore is NOT an exit: it means the weight credits ran out
    -- (or a runner parked everything), so the credits are topped up and the
    -- walk takes another pass. This keeps the scheduler's invariant "queued
    -- work implies a full executor pool". stallPasses is a safety net for a
    -- runner that keeps re-queueing without ever spending a slot.
    local stallPasses = 0
    local MAX_STALL_PASSES = 64
    while true do
        if self:executorsFull() then
            break
        end
        if not self:anyReadyWork(mode) then
            break
        end
        local passSteps = 0
        for index, name in ipairs(self.order) do
            local queue = self.queues[name]
            if queue and (tonumber(queue.remaining) or 0) >= 1 then
                queue.remaining = queue.remaining - 1
                if queue.active:len() > 0 and self:runnable(queue, mode)
                    and not self:roundBlocked(queue) then
                    local task = self:pop(queue)
                    if task then
                        self.cursor = index
                        self:runTask(queue, task, now, mode)
                        steps = steps + 1
                        passSteps = passSteps + 1
                        if self:executorsFull() then
                            break
                        end
                    end
                end
            end
        end
        if self:executorsFull() then
            break
        end
        if not self:anyReadyWork(mode) then
            break
        end
        if self:allRemainingAtMostOne() then
            self:refill()
        end
        if passSteps == 0 then
            -- Nothing could spend a credit this pass although ready work is
            -- left: top the credits up and take another pass instead of
            -- stopping with a free executor (see the comment at the top).
            self:refill()
            stallPasses = stallPasses + 1
            if stallPasses > MAX_STALL_PASSES then
                break
            end
        else
            stallPasses = 0
        end
    end
    return steps
end

-- Per-queue accounting for one dispatch run: calls/ms since the snapshot, plus the
-- single slowest task of the run (self.runQueueMax). Sorted by total ms, top N kept.
local function runQueueSummary(self, snapshot, topN)
    local list = {}
    local runMax = self.runQueueMax or {}
    for name, entry in pairs(self.stats.byQueue or {}) do
        local before = snapshot[name]
        local calls = (tonumber(entry.calls) or 0) - (before and tonumber(before.calls) or 0)
        if calls > 0 then
            list[#list + 1] = {
                name = name,
                calls = calls,
                ms = (tonumber(entry.ms) or 0) - (before and tonumber(before.ms) or 0),
                maxMs = tonumber(runMax[name]) or 0,
            }
        end
    end
    table.sort(list, function(a, b)
        if a.ms ~= b.ms then
            return a.ms > b.ms
        end
        return a.calls > b.calls
    end)
    while #list > (tonumber(topN) or 3) do
        table.remove(list)
    end
    return list
end

-- Writing a state file is the one step of the tick that can block the whole master for
-- a long time: the snapshot is serialized in full and pushed to disk. One write above
-- this is treated as a bug - the message names the file, and jsonfile.lua adds how much
-- of the time was serialization and how much the disk.
local FLUSH_FATAL_MS = 100

function Dispatch:timedFileFlush(label, owner)
    local startedAt = os.epoch("utc")
    local ok = owner:flush()
    local cost = os.epoch("utc") - startedAt
    if cost >= FLUSH_FATAL_MS then
        self.log("[IFM] %s flush blocked: %dms (>=%dms) - throttle the state " ..
            "writer or split the file (jsonfile.lua reports the serialize/disk split)",
            tostring(label), cost, FLUSH_FATAL_MS)
    end
    return ok
end

function Dispatch:tick(now)
    now = now or os.epoch("utc")
    local started = os.epoch("utc")
    local brk = self.stats.breakdown
    if not brk then
        brk = { flush = 0, maintain = 0, promote = 0, gen = 0, rotate = 0, rounds = 0 }
        self.stats.breakdown = brk
    end
    local markAt = started
    brk.rounds = brk.rounds + 1
    self.stats.runs = self.stats.runs + 1
    self.round = (self.round or 0) + 1
    -- Per-run phase timings (ms). The cumulative breakdown above cannot say which
    -- phase a single slow tick was spent in, so the last run is kept separately and
    -- is what the fatal "LONG BLOCK dispatch" message reports.
    local run = { rounds = self.round }
    -- Per-run queue delta: which runner actually burned the time in this tick.
    self.runQueueMax = {}
    local byQueueStart = {}
    for name, entry in pairs(self.stats.byQueue or {}) do
        byQueueStart[name] = { calls = entry.calls or 0, ms = entry.ms or 0 }
    end

    if self.store and self.store.file and self.store.file.dirty then
        if self:timedFileFlush("store", self.store) then
            self.stats.writes = self.stats.writes + 1
        end
    end
    if self.cache and self.cache.file and self.cache.file.dirty then
        if self:timedFileFlush("cache", self.cache) then
            self.stats.writes = self.stats.writes + 1
        end
    end
    run.flush = os.epoch("utc") - markAt
    brk.flush = brk.flush + run.flush
    markAt = os.epoch("utc")

    if self.maintain then
        self.maintain(now)
    end
    run.maintain = os.epoch("utc") - markAt
    brk.maintain = brk.maintain + run.maintain
    markAt = os.epoch("utc")

    for _, name in ipairs(self.order) do
        self:promote(name)
    end
    run.promote = os.epoch("utc") - markAt
    brk.promote = brk.promote + run.promote
    markAt = os.epoch("utc")

    local mode = self:mode()
    if self:executorsFull() then
        self.stats.paused = self.stats.paused + 1
        self.stats.lastMs = os.epoch("utc") - started
        run.ms = self.stats.lastMs
        run.steps = 0
        run.paused = true
        run.queues = {}
        self.lastRun = run
        return 0
    end

    if self.transfer and self.transfer.beginDispatchRound then
        self.transfer:beginDispatchRound()
    end
    for _, generator in ipairs(self.generators) do
        generator(now)
    end
    run.gen = os.epoch("utc") - markAt
    brk.gen = brk.gen + run.gen
    markAt = os.epoch("utc")

    local steps = self:advanceAll(now, mode)
    run.rotate = os.epoch("utc") - markAt
    brk.rotate = brk.rotate + run.rotate

    if self.transfer and self.transfer.endDispatchRound then
        self.transfer:endDispatchRound()
    end
    local spent = os.epoch("utc") - started
    self.stats.ms = self.stats.ms + spent
    self.stats.lastMs = spent
    if spent > (self.stats.maxMs or 0) then
        self.stats.maxMs = spent
    end
    run.ms = spent
    run.steps = steps
    run.paused = false
    run.queues = runQueueSummary(self, byQueueStart, 3)
    self.lastRun = run
    return steps
end

-- Compact one/two-line summary of the last run, for the fatal "LONG BLOCK" message
-- (the full status dump does not fit a CC:T terminal). Only the phases and the few
-- queues that actually ran are shown.
function Dispatch:runText()
    local run = self.lastRun
    if type(run) ~= "table" then
        return ""
    end
    local parts = {}
    for _, q in ipairs(run.queues or {}) do
        parts[#parts + 1] = string.format("%s %dx/%.0fms(max%.0f)", q.name, q.calls, q.ms, q.maxMs)
    end
    return string.format(
        "run steps=%d ms=%.0f flush=%.0f maintain=%.0f promote=%.0f gen=%.0f rotate=%.0f | queues: %s",
        tonumber(run.steps) or 0, tonumber(run.ms) or 0,
        tonumber(run.flush) or 0, tonumber(run.maintain) or 0, tonumber(run.promote) or 0,
        tonumber(run.gen) or 0, tonumber(run.rotate) or 0,
        (#parts > 0) and table.concat(parts, " ") or "-")
end

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
            remaining = queue.remaining or 0,
            depth = queue.active:len() + (queue.waiting and queue.waiting:len() or 0),
            active = queue.active:len(),
            waiting = queue.waiting and queue.waiting:len() or 0,
            singleQueue = queue.singleQueue == true,
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
        promoted = self.stats.promoted or 0,
        lastMs = self.stats.lastMs,
        maxMs = self.stats.maxMs,
        avgMs = self.stats.runs > 0 and (self.stats.ms / self.stats.runs) or 0,
        writes = self.stats.writes,
        uptimeSeconds = math.floor((os.epoch("utc") - (self.stats.startedAt or os.epoch("utc"))) / 1000),
        duplicateQueues = self.stats.duplicateQueues or 0,
        missingRunner = self.stats.missingRunner or 0,
        queues = queues,
        breakdown = self.stats.breakdown,
        byQueue = self.stats.byQueue,
        lastRun = self.lastRun,
    }
end

return Dispatch
