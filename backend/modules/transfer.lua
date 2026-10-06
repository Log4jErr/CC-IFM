local Transfer = {}
Transfer.__index = Transfer

Transfer.VERSION = "487"

local HELLO_INTERVAL = 3000
local WORKER_TIMEOUT = 15000
local WORKER_EVICT_TIMEOUT = 30000
local MAX_WORKER_LOG_LINES = 32
local INSTRUCTION_TIMEOUT_MS = 3000
-- One instruction = one peripheral call, so a detail instruction carries one sample.
local DETAIL_BATCH = 1

local WORKER_SLOTS_DEFAULT = 1

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

function Transfer.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Transfer)
    self.log = levelLogger(opts.log)
    self.Assert = opts.Assert
        or error("transfer.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.Peripherals = opts.Peripherals
    self.Modems = opts.Modems
    if not self.Modems then
        error("transfer.lua needs the modems module: pass opts.Modems (loadModule(\"modems\"))", 0)
    end
    self.channel = tonumber(opts.channel) or self.Modems.CHANNEL
    self.crafterChannel = tonumber(opts.crafterChannel) or self.Modems.CRAFTER_CHANNEL
    self.crafters = {}
    self.craftSeq = 0
    self.craftStats = { sent = 0, idle = 0 }
    self.modemSide = opts.modemSide
    self.modem = nil
    self.listenReady = false
    self.helloAt = 0
    self.workers = {}
    self.jobs = {}
    self.jobById = {}
    self.outbox = {}
    self.jobSeq = 0
    self.stats = { submitted = 0, done = 0, failed = 0, timedOut = 0, busyRejected = 0,
        batches = 0, batchedJobs = 0 }
    self.version = nil
    self.querySeq = 0
    self.queries = {}
    self.queryRunning = {}
    self.queryCache = {}
    self.queryTtl = 2000
    self.queryStats = { submitted = 0, done = 0, failed = 0, busyRejected = 0, acked = 0 }
    self.lastQuery = nil
    self.scanStats = { batches = 0, requests = 0, hits = 0, pending = 0, localOnly = 0,
        containers = 0, failed = 0, subQueries = 0, paused = 0, blind = 0, queued = 0,
        throttled = 0 }
    self.detailSeq = 0
    self.details = {}
    self.detailResults = {}
    self.onQueryResult = nil
    self.onQueryDropped = nil
    self.onCrafterInventory = nil
    self.onDetailResult = nil
    self.onDetailSettled = nil
    self.scanFreshMs = opts.scanFreshMs or 500
    self.detailStats = { submitted = 0, done = 0, failed = 0, items = 0 }
    self.lastDetail = nil
    self.crafterDetailSeq = 0
    self.crafterDetails = {}
    self.crafterDetailStats = { submitted = 0, done = 0, failed = 0, items = 0 }
    self.onCrafterDetails = nil
    return self
end

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
            self.log.error("IFMWorker link: cannot open channel %d (%s)", self.channel, tostring(err))
            self.modem = nil
            return nil
        end
        local okCrafter, crafterErr = pcall(modem.open, self.crafterChannel)
        if not okCrafter then
            self.log.error("crafter link: cannot open channel %d (%s)", self.crafterChannel, tostring(crafterErr))
        end
        self.listenReady = true
        self.log("IFMWorker link: listening on channel %d (workers) and %d (turtle crafters) via modem %s",
            self.channel, self.crafterChannel, tostring(self.modemName or "?"))
    end
    return self.modem
end

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

function Transfer:workerHasRoom(worker)
    if type(worker) ~= "table" then
        return false
    end
    return (worker.inFlight or 0) < self:workerSlots(worker)
end

function Transfer:workerBegin(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = (worker.inFlight or 0) + 1
    worker.busy = not self:workerHasRoom(worker)
    worker.dispatchRound = (worker.dispatchRound or 0) + 1
end

function Transfer:beginDispatchRound()
    for _, worker in pairs(self.workers) do
        worker.dispatchRound = 0
    end
end

function Transfer:endDispatchRound()
    for _, worker in pairs(self.workers) do
        local load = tonumber(worker.dispatchRound) or 0
        worker.dispatchLoad = load
        worker.dispatchSamples = (worker.dispatchSamples or 0) + 1
        worker.dispatchTotal = (worker.dispatchTotal or 0) + load
        local peak = tonumber(worker.dispatchPeak) or 0
        if load > peak then
            peak = load
        end
        if worker.dispatchSamples >= 100 then
            worker.dispatchSamples = 0
            worker.dispatchTotal = 0
            peak = load
        end
        worker.dispatchPeak = peak
        worker.dispatchAvg = worker.dispatchSamples > 0 and (worker.dispatchTotal / worker.dispatchSamples) or load
    end
end

function Transfer:workerEnd(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = math.max(0, (worker.inFlight or 0) - 1)
    worker.busy = not self:workerHasRoom(worker)
end

function Transfer:workerRelease(worker)
    if type(worker) ~= "table" then
        return
    end
    worker.inFlight = 0
    worker.busy = false
end

function Transfer:idleCount()
    local count = 0
    for _, worker in pairs(self.workers) do
        if self:workerHasRoom(worker) and self:workerUsable(worker) then
            count = count + 1
        end
    end
    return count
end

-- Free instruction slots of every usable remote worker.
function Transfer:freeWorkerSlots()
    local free = 0
    for _, worker in pairs(self.workers) do
        if self:workerUsable(worker) then
            free = free + math.max(0, self:workerSlots(worker) - (worker.inFlight or 0))
        end
    end
    return free
end

-- Free slots of the whole executor pool. Every instruction runs on a remote worker
-- now (the master has no executor of its own), so this is exactly the workers' free
-- slot count; with no worker online it is 0 and the scheduler pauses instead of
-- falling back to doing the work itself.
function Transfer:freeExecutorSlots()
    return self:freeWorkerSlots()
end

function Transfer:workerLabel(worker)
    if type(worker) == "table" and type(worker.name) == "string" and worker.name ~= "" then
        return " " .. worker.name
    end
    return ""
end

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

function Transfer:workerStale(worker, now)
    if type(worker) ~= "table" then
        return false
    end
    now = now or os.epoch("utc")
    return (now - math.max(worker.stateAt or 0, worker.lastSeen or 0)) > WORKER_TIMEOUT
end

function Transfer:workerUsable(worker)
    if type(worker) ~= "table" then
        return false
    end
    if self:workerStale(worker) then
        return false
    end
    if not self.version then
        if not self.versionMissingLogged then
            self.versionMissingLogged = true
            self.log("Master version is not set (setContext was never called): workers are disabled")
        end
        return false
    end
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
    if worker.version ~= self.version then
        if worker.versionMismatchFor ~= worker.version then
            worker.versionMismatchFor = worker.version
            self.stats.versionMismatch = (self.stats.versionMismatch or 0) + 1
            self.log("IFMWorker #%s runs version %s but the master is %s - it will NOT be used until both " ..
                "computers run the same build (copy the same ifm_bundle.lua to that computer and run it again)",
                tostring(worker.id), tostring(worker.version), tostring(self.version))
        end
        return false
    end
    worker.versionMismatchFor = nil
    return true
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
        busy = busy,
        idle = self:idleCount(),
        usable = breakdown.usable,
        versionUnknown = breakdown.versionUnknown,
        versionMismatch = breakdown.versionMismatch,
        inFlightWorkers = breakdown.inFlight,
        slots = breakdown.capacity,
        freeSlots = breakdown.capacityTasks,
        inFlightTasks = breakdown.inFlightTasks,
        version = self.version,
        pending = self:pendingCount(),
        queries = self.queryStats,
        queriesPending = self:queryPendingCount(),
        details = self.detailStats,
        detailsPending = self:detailPendingCount(),
        lastQuery = self.lastQuery,
        channel = self.channel,
        modem = self.modemName,
        crafterChannel = self.crafterChannel,
        crafters = self:craftStatus(),
        crafterList = self:craftersForUi(),
        submitted = self.stats.submitted,
        done = self.stats.done,
        failed = self.stats.failed,
        timedOut = self.stats.timedOut,
        busyRejected = self.stats.busyRejected or 0,
        batches = self.stats.batches or 0,
        batchedJobs = self.stats.batchedJobs or 0,
    }
end

function Transfer:usableBreakdown()
    local out = { total = 0, usable = 0, noMasterVersion = 0, versionUnknown = 0,
        versionMismatch = 0, inFlight = 0, capacity = 0, inFlightTasks = 0, capacityTasks = 0,
        atCapacity = 0 }
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
            out.atCapacity = out.atCapacity + 1
            out.inFlight = out.inFlight + 1
        else
            out.usable = out.usable + 1
        end
    end
    return out
end

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

function Transfer:pickWorkerFor()
    local best = nil
    for _, worker in pairs(self.workers) do
        if self:workerHasRoom(worker) and self:workerUsable(worker) then
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

function Transfer:send(message, chan)
    local modem = self:ensureModem()
    if not modem then
        return false
    end
    local ok, err = self.Modems.transmit(modem, chan or self.channel, message)
    if not ok then
        self.log.error("IFMWorker link: transmit failed (%s)", tostring(err))
        self.modem = nil
        self.listenReady = false
        return false
    end
    return true
end

function Transfer:sendTo(worker, job)
    if not self:workerUsable(worker) then
        self.log("Refusing to send job %s to worker #%s (version mismatch: worker=%s master=%s)",
            tostring(job.id), tostring(worker and worker.id),
            tostring(worker and worker.version), tostring(self.version))
        return false
    end
    return self:queueTo(worker, {
        proto = self.Modems.PROTOCOL,
        op = "job",
        target = worker.id,
        sender = os.getComputerID(),
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
        nbt = job.nbt,
        actor = job.actor,
    })
end

function Transfer:queueTo(worker, message)
    local box = self.outbox[worker.id]
    if not box then
        box = {}
        self.outbox[worker.id] = box
    end
    box[#box + 1] = message
    return true
end

function Transfer:flushOutbox()
    local envelopes, batched = 0, 0
    for workerId, box in pairs(self.outbox) do
        self.outbox[workerId] = nil
        local worker = self.workers[workerId]
        if worker and #box > 0 then
            local chan = worker.jobChannel or self.channel
            local okSend = self:send({
                proto = self.Modems.PROTOCOL,
                op = "jobs",
                target = workerId,
                sender = os.getComputerID(),
                version = self.version,
                jobs = box,
            }, chan)
            if okSend then
                local at = os.epoch("utc")
                for _, message in ipairs(box) do
                    self:stampSent(message, at)
                end
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

function Transfer:stampSent(message, at)
    local id = message and message.id
    if id == nil then
        return
    end
    local record
    if message.op == "job" then
        record = self.jobById[id]
    elseif message.op == "query" then
        record = self.queries[id]
    elseif message.op == "detail" then
        record = self.details[id]
    end
    if record then
        record.sendAt = at
    end
end

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
    local worker = self:pickWorkerFor()
    if worker then
        self.jobSeq = self.jobSeq + 1
        local now = os.epoch("utc")
        local record = {
            id = self.jobSeq,
            key = key,
            worker = worker.id,
            at = now,
            state = "pending",
            job = job,
            sendAt = now,
        }
        job.id = record.id
        if self:sendTo(worker, job) then
            self:workerBegin(worker)
            self.jobs[key] = record
            self.jobById[record.id] = record
            self.stats.submitted = self.stats.submitted + 1
            return "pending"
        end
        self.stats.sendRejected = (self.stats.sendRejected or 0) + 1
        self.log.error("Refusing job %s to IFMWorker #%s (version mismatch or worker gone) - the move " ..
            "FAILED; sync the builds on every computer", tostring(job.id), tostring(worker.id))
        return "done", 0, "worker refused the job (build mismatch or worker gone)"
    end
    -- No worker could take the instruction (none online, or every slot busy / build
    -- mismatched): report it instead of a silent "pending" - the caller would just
    -- wait for a reply that never comes. The master no longer executes moves itself,
    -- so there is no local fallback.
    self.stats.busyRejected = (self.stats.busyRejected or 0) + 1
    return "busy"
end

function Transfer:touchWorker(id, name, version, slots)
    if id == nil then
        self.log.warn("Worker message without a sender id - ignored")
        return nil
    end
    local worker = self.workers[id]
    local created = false
    if not worker then
        worker = { id = id, busy = false, inFlight = 0, jobs = 0 }
        self.workers[id] = worker
        created = true
        self.log("IFMWorker #%s online", tostring(id))
    end
    worker.lastSeen = os.epoch("utc")
    worker.staleLogged = nil
    if type(version) == "string" and version ~= "" then
        worker.version = version
    end
    if tonumber(slots) and tonumber(slots) >= 1 then
        worker.slots = math.floor(tonumber(slots))
    end
    if type(name) == "string" and name ~= "" then
        worker.name = name
    end
    return worker, created
end

function Transfer:onModemMessage(side, channel, replyChannel, message, distance)
    local chan = tonumber(channel)
    if type(message) ~= "table" then
        return false
    end
    if chan == self.crafterChannel then
        if message.proto ~= self.Modems.CRAFTER_PROTOCOL then
            return false
        end
        return self:onCrafterMessage(message)
    end
    if chan ~= self.channel then
        return false
    end
    if message.proto ~= self.Modems.PROTOCOL then
        return false
    end
    local now = os.epoch("utc")
    if message.op == "hello" then
        local worker = self:touchWorker(message.from, message.name, message.version, message.slots)
        if tonumber(message.jobChannel) then
            worker.jobChannel = math.floor(tonumber(message.jobChannel))
        end
        self:send({
            proto = self.Modems.PROTOCOL,
            op = "pong",
            from = os.getComputerID(),
            target = message.from,
            master = true,
        })
        if not worker.welcomed then
            worker.welcomed = true
            self:send({
                proto = self.Modems.PROTOCOL,
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
        self:touchWorker(message.from, message.name, message.version, message.slots)
        return true
    end
    if message.op == "state" then
        local worker = self:touchWorker(message.from, message.name, message.version, message.slots)
        self:applyWorkerState(worker, message)
        return true
    end
    if message.op == "query_ack" then
        local worker = self:touchWorker(message.from)
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
        local worker = self:touchWorker(message.from, message.name, message.version, message.slots)
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
        end
        if self.details[id] then
            self.details[id] = nil
            self.detailStats.failed = self.detailStats.failed + 1
        end
        return true
    end
    if message.op == "results" then
        local worker = self:touchWorker(message.from, message.name, message.version, message.slots)
        local results = self.Assert.field(message, "results", "table")
        self:applyWorkerLogs(worker, message)
        for _, entry in ipairs(results) do
            local entryOp = self.Assert.field(entry, "op", "string")
            if entryOp == "query_result" then
                self:applyQueryResult(entry, worker)
            elseif entryOp == "detail_result" then
                self:applyDetailResult(entry, worker)
            else
                self.Assert.is(entryOp == "done" or entryOp == "error",
                    "worker sent an unknown result op '%s' - build mismatch?", tostring(entryOp))
                self:applyWorkerResult(worker, entry)
            end
        end
        return true
    end
    return false
end

function Transfer:applyWorkerResult(worker, message)
    self.Assert.is(type(message) == "table", "worker result must be a table, got %s", type(message))
    local id = self.Assert.integer(tonumber(message.id), "worker result id")
    local record = self.jobById[id]
    if not record then
        self:workerEnd(worker)
        return true
    end
    if record.state ~= "pending" then
        self.jobById[record.id] = nil
        self:workerEnd(worker)
        return true
    end
    worker.jobs = (worker.jobs or 0) + 1
    self:workerEnd(worker)
    record.moved = self.Assert.count(tonumber(message.moved), "worker result moved")
    record.error = message.error
    record.state = message.op == "done" and "done" or "failed"
    if record.state == "done" then
        self.stats.done = self.stats.done + 1
    else
        self.stats.failed = self.stats.failed + 1
    end
    return true
end

function Transfer:applyQueryResult(message, worker)
    worker = worker or self:touchWorker(message.from, message.name, message.version, message.slots)
    if not worker then
        self.log.warn("Query result without a sender id - dropped (id=%s)", tostring(message.id))
        return false
    end
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
        self.log.error("IFMWorker #%s query failed (%s): %s", tostring(worker.id),
            tostring(record.key), tostring(message.error))
        if self.onQueryDropped then
            self.onQueryDropped(record.key, "worker reported: " .. tostring(message.error))
        end
        return true
    end
    message.key = record.key
    if record.spec and record.spec.ts ~= nil then
        message.ts = record.spec.ts
    end
    self.queryCache[record.key] = { at = os.epoch("utc"), result = message }
    self.queryStats.done = self.queryStats.done + 1
    if self.onQueryResult then
        self.onQueryResult(self, record.key, message)
    end
    local stacks = #(message.items or {}) + #(message.tanks or {})
    self.log("IFMWorker #%s query %s %s: %d row(s) in %sms", tostring(worker.id),
        tostring(message.part or "items"), tostring(message.container or message.mode or "?"),
        stacks, tostring(message.elapsed or "?"))
    return true
end

function Transfer:applyDetailResult(message, worker)
    worker = worker or self:touchWorker(message.from, message.name, message.version, message.slots)
    if not worker then
        self.log.warn("Item detail result without a sender id - dropped (id=%s)", tostring(message.id))
        return false
    end
    local id = tonumber(message.id) or -1
    local request = self.details[id]
    self.details[id] = nil
    self:workerEnd(worker)
    if not self:workerHasPending(worker) then
        worker.busyKind = nil
    end
    if not request then
        return true
    end
    -- Same settlement path as the timeout sweep: whoever tracks the in-flight
    -- detail request (containers.detailInFlight) is told it is over - and told *why* when
    -- the worker could not read the detail, so the container side can log it once.
    local reason = nil
    if message.ok == false then
        self.detailStats.failed = self.detailStats.failed + 1
        self.log.error("IFMWorker #%s detail query failed: %s", tostring(worker.id), tostring(message.error))
        reason = "worker reported: " .. tostring(message.error)
    end
    if self.onDetailSettled then
        self.onDetailSettled(request, reason)
    end
    if self.onDetailResult then
        self.onDetailResult(self, message)
    end
    if message.ok == false then
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

local CRAFTER_INVENTORY_REFRESH = 1500
local CRAFTER_INVENTORY_ASK_GAP = 2000

function Transfer:touchCrafter(id, message)
    id = tonumber(id)
    if id == nil then
        return nil
    end
    local now = os.epoch("utc")
    local crafter = self.crafters[id]
    local created = false
    if not crafter then
        crafter = { id = id, busy = false, crafted = 0 }
        self.crafters[id] = crafter
        created = true
    end
    crafter.lastSeen = now
    crafter.name = self.Assert.string(message.name, "crafter report name")
    crafter.label = self.Assert.string(message.label, "crafter report label")
    crafter.busy = self.Assert.boolean(message.busy, "crafter report busy")
    crafter.crafted = self.Assert.count(tonumber(message.crafts), "crafter crafts counter (field 'crafts')")
    if message.op ~= "inventory" then
        crafter.version = self.Assert.string(message.version, "crafter report version")
    end
    crafter.channel = self.crafterChannel
    if created then
        self.log("crafter #%s online (%s) on channel %d", tostring(id), tostring(crafter.name or "?"),
            self.crafterChannel)
    end
    return crafter, created
end

function Transfer:sendCrafter(message)
    return self:send(message, self.crafterChannel)
end

function Transfer:onCrafterMessage(message)
    local crafter = self:touchCrafter(message.from, message)
    if not crafter then
        return false
    end
    local op = message.op
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
            self.onCrafterInventory(crafter.name, items, at, size)
        end
        return true
    end
    if op == "detail_result" then
        local request = self.crafterDetails[tonumber(message.id) or message.id]
        if request then
            self.crafterDetails[request.id] = nil
        end
        local entries = {}
        for _, entry in ipairs(type(message.details) == "table" and message.details or {}) do
            if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" and
                type(entry.detail) == "table" then
                entries[#entries + 1] = {
                    name = entry.name,
                    nbt = entry.nbt,
                    detail = entry.detail,
                    slot = entry.slot,
                    container = crafter.name,
                }
            end
        end
        self.crafterDetailStats.done = self.crafterDetailStats.done + 1
        self.crafterDetailStats.items = self.crafterDetailStats.items + #entries
        if request == nil then
            self.crafterDetailStats.failed = self.crafterDetailStats.failed + 1
        end
        if #entries > 0 and self.onCrafterDetails and type(crafter.name) == "string" and crafter.name ~= "" then
            self.onCrafterDetails(crafter.name, entries)
        end
        return true
    end
    if op == "hello" or op == "pong" or op == "crafter_here" then
        self:sendCrafter({
            proto = self.Modems.CRAFTER_PROTOCOL,
            op = "pong",
            from = os.getComputerID(),
            target = crafter.id,
            master = true,
            version = self.version,
        })
        return true
    end
    return false
end

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
            if not best or (crafter.crafted or 0) < (best.crafted or 0) then
                best = crafter
            end
        end
    end
    return best
end

-- A turtle crafter is addressed by its container name in the master (the wired
-- peripheral name of the turtle), while the turtle introduces itself with its
-- local modem name. Accept an exact match first, then fall back to the part
-- after the colon ("computercraft:turtle_normal_5" vs "turtle_5").
function Transfer:findCrafterByName(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local tail = string.match(name, ":([^:]+)$") or name
    local loose = nil
    for _, crafter in pairs(self.crafters) do
        if crafter.name == name then
            return crafter
        end
        local crafterName = type(crafter.name) == "string" and crafter.name or nil
        local crafterTail = crafterName and (string.match(crafterName, ":([^:]+)$") or crafterName) or nil
        if crafterName and (crafterTail == name or crafterTail == tail or crafterName == tail) then
            if loose == nil or (crafter.crafted or 0) < (loose.crafted or 0) then
                loose = crafter
            end
        end
    end
    return loose
end

-- Ask a turtle crafter for the item details of its own inventory slots. This is
-- the only way to learn the stack limit of an item that exists nowhere but in a
-- turtle: reading it through peripheral.wrap() does not return maxCount.
-- Busy turtles answer too (reading the inventory does not interfere with craft).
function Transfer:requestCrafterDetails(containerName, samples)
    if type(samples) ~= "table" or #samples == 0 then
        return "local"
    end
    local crafter = self:findCrafterByName(containerName)
    if not crafter then
        return "local"
    end
    if type(crafter.version) == "string" and crafter.version ~= "" and crafter.version ~= self.version then
        return "local"
    end
    local batch = {}
    for _, sample in ipairs(samples) do
        if #batch >= DETAIL_BATCH then
            break
        end
        if type(sample) == "table" and type(sample.name) == "string" and sample.name ~= "" then
            batch[#batch + 1] = {
                slot = tonumber(sample.slot),
                name = sample.name,
                nbt = sample.nbt,
            }
        end
    end
    if #batch == 0 then
        return "local"
    end
    self.crafterDetailSeq = self.crafterDetailSeq + 1
    local request = {
        id = self.crafterDetailSeq,
        crafter = crafter.id,
        container = containerName,
        samples = batch,
        at = os.epoch("utc"),
    }
    local sent = self:sendCrafter({
        proto = self.Modems.CRAFTER_PROTOCOL,
        op = "detail_request",
        from = os.getComputerID(),
        target = crafter.id,
        master = true,
        version = self.version,
        id = request.id,
        samples = batch,
    })
    if not sent then
        return "local"
    end
    request.sendAt = os.epoch("utc")
    self.crafterDetails[request.id] = request
    self.crafterDetailStats.submitted = self.crafterDetailStats.submitted + 1
    return "pending"
end

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
        proto = self.Modems.CRAFTER_PROTOCOL,
        op = "inventory_request",
        from = os.getComputerID(),
        target = crafter.id,
        master = true,
        version = self.version,
    })
end

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

function Transfer:requestCraft(spec)
    spec = spec or {}
    local crafter = self:pickCrafter(spec.crafter)
    if not crafter then
        self.craftStats.idle = self.craftStats.idle + 1
        return "idle"
    end
    self.craftSeq = self.craftSeq + 1
    local sent = self:sendCrafter({
        proto = self.Modems.CRAFTER_PROTOCOL,
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
    crafter.busy = true
    self.craftStats.sent = self.craftStats.sent + 1
    self.log("crafter #%s craft request %s (%s)", tostring(crafter.id), tostring(self.craftSeq),
        tostring(spec.key or "?"))
    return "sent"
end

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
        sent = self.craftStats.sent,
        deferred = self.craftStats.idle,
    }
end

function Transfer:craftersForUi()
    local now = os.epoch("utc")
    local out = {}
    for _, crafter in pairs(self.crafters) do
        local mismatch = (type(crafter.version) == "string" and crafter.version ~= "" and
            crafter.version ~= self.version) and true or false
        out[#out + 1] = {
            id = crafter.id,
            name = crafter.name,
            label = crafter.label,
            version = crafter.version,
            versionMismatch = mismatch,
            busy = crafter.busy,
            crafted = crafter.crafted,
            age = math.floor((now - (crafter.lastSeen or now)) / 1000),
            inventoryStacks = crafter.inventory and #(crafter.inventory.items or {}) or 0,
            inventoryAt = crafter.inventory and crafter.inventory.at or nil,
        }
    end
    table.sort(out, function(a, b)
        return tostring(a.name or a.id) < tostring(b.name or b.id)
    end)
    return out
end

function Transfer:releaseInstructionWorker(worker)
    if not worker then
        return
    end
    self:workerEnd(worker)
    worker.timeouts = (worker.timeouts or 0) + 1
    if not self:workerHasPending(worker) then
        worker.busyKind = nil
    end
end

function Transfer:tick(now)
    now = now or os.epoch("utc")
    self:ensureModem()
    if self.modem and now - (self.helloAt or 0) >= HELLO_INTERVAL then
        self.helloAt = now
        self:send({
            proto = self.Modems.PROTOCOL,
            op = "hello",
            from = os.getComputerID(),
            channel = self.channel,
            master = true,
        })
    end
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
    for id, crafter in pairs(self.crafters) do
        if now - (crafter.lastSeen or 0) - stall > WORKER_EVICT_TIMEOUT then
            self.crafters[id] = nil
            self.log("crafter #%s%s offline (no message for %dms)",
                tostring(id), crafter.name and (" (" .. tostring(crafter.name) .. ")") or "", WORKER_EVICT_TIMEOUT)
        end
    end
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
            local droppedMoves = {}
            for _, job in pairs(self.jobs) do
                if job.worker == id and job.state == "pending" then
                    job.state = "failed"
                    job.error = "IFMWorker offline"
                    self.stats.failed = self.stats.failed + 1
                    if job.moveKey then
                        droppedMoves[#droppedMoves + 1] = job.moveKey
                    end
                end
            end
            if #droppedMoves > 0 and self.onMovesDropped then
                self.onMovesDropped(droppedMoves, "worker #" .. tostring(id) .. " offline")
            end
            for queryId, query in pairs(self.queries) do
                if query.worker == id then
                    self.queries[queryId] = nil
                    self.queryRunning[query.key] = nil
                    self.queryStats.failed = self.queryStats.failed + 1
                    if self.onQueryDropped then
                        self.onQueryDropped(query.key, "IFMWorker offline")
                    end
                end
            end
            for detailId, request in pairs(self.details) do
                if request.worker == id then
                    self.details[detailId] = nil
                    self.detailStats.failed = self.detailStats.failed + 1
                end
            end
        end
    end
    -- One sweep, one deadline for every in-flight instruction: queries, item
    -- details, crafter details and move jobs all expire here, with the same worker
    -- release and the same "instruction FAILED (not retried)" wording. No request
    -- kind gets a private timeout.
    local timeout = INSTRUCTION_TIMEOUT_MS
    local reason = "no reply within " .. tostring(timeout) .. "ms"
    for queryId, query in pairs(self.queries) do
        if now - (query.sendAt or query.at or 0) > timeout then
            self.queries[queryId] = nil
            self.queryRunning[query.key] = nil
            self.queryStats.failed = self.queryStats.failed + 1
            self:releaseInstructionWorker(self.workers[query.worker])
            if self.onQueryDropped then
                self.onQueryDropped(query.key, reason)
            end
            local isScan = string.match(tostring(query.key or ""), "^scan:") ~= nil
            self.log.error("IFMWorker #%s%s did not answer query #%s for %s within %dms - instruction " ..
                "FAILED (not retried); the worker slot is free again%s",
                tostring(query.worker), self:workerLabel(self.workers[query.worker]), tostring(query.id or 0),
                tostring(query.key), timeout, query.ack and " (it did ack the request, so only the reply is missing)" or
                " (no ack at all: the request may never have reached that worker)")
            if isScan then
                self.log.error("IFMWorker scan of %s gave up - that container's scan task is released and " ..
                    "will be queued again next round (its snapshot stays as it is)", tostring(query.key))
            end
        end
    end
    for detailId, request in pairs(self.details) do
        if now - (request.sendAt or request.at or 0) > timeout then
            self.details[detailId] = nil
            self.detailStats.failed = self.detailStats.failed + 1
            self:releaseInstructionWorker(self.workers[request.worker])
            if self.onDetailSettled then
                self.onDetailSettled(request, reason)
            end
            self.log.error("IFMWorker #%s%s did not answer the item detail request #%s within %dms " ..
                "(%d sample(s)) - instruction FAILED (not retried), those items are re-requested later",
                tostring(request.worker), self:workerLabel(self.workers[request.worker]),
                tostring(request.id or 0), timeout, #(request.samples or {}))
        end
    end
    for requestId, request in pairs(self.crafterDetails) do
        if now - (request.sendAt or request.at or 0) > timeout then
            self.crafterDetails[requestId] = nil
            self.crafterDetailStats.failed = self.crafterDetailStats.failed + 1
            if self.onDetailSettled then
                self.onDetailSettled(request, reason)
            end
            self.log.error("IFMCrafter #%s did not answer item detail request #%s for %s within %dms " ..
                "(%d sample(s)) - turtle offline, or its build does not know the request",
                tostring(request.crafter), tostring(request.id or 0), tostring(request.container),
                timeout, #(request.samples or {}))
        end
    end
    local droppedMoves = {}
    for _, job in pairs(self.jobs) do
        if job.state == "pending" and job.worker ~= "local" then
            if now - (job.sendAt or job.at or 0) > timeout then
                job.state = "failed"
                job.error = reason
                self.stats.timedOut = self.stats.timedOut + 1
                self:releaseInstructionWorker(self.workers[job.worker])
                droppedMoves[#droppedMoves + 1] = job.key
                local move = job.job or {}
                self.log.error("IFMWorker #%s%s did not answer job #%s (%s#%s -> %s#%s) within %dms - " ..
                    "instruction FAILED (not retried), its reservation is released and the engine retries " ..
                    "with a new job; check that worker's screen",
                    tostring(job.worker), self:workerLabel(self.workers[job.worker]), tostring(job.id or 0),
                    tostring(move.from), tostring(move.fromSlot), tostring(move.to), tostring(move.toSlot),
                    timeout)
            end
        elseif job.state ~= "pending" and now - (job.at or 0) > timeout then
            self.jobs[job.key] = nil
            self.jobById[job.id] = nil
        end
    end
    if #droppedMoves > 0 and self.onMovesDropped then
        self.onMovesDropped(droppedMoves, "instruction timeout (" .. tostring(timeout) .. "ms)")
    end
end

function Transfer:setContext(ctx)
    ctx = ctx or {}
    self.version = ctx.version
end

function Transfer:capableWorkers()
    local out = {}
    for _, worker in pairs(self.workers) do
        if self:workerUsable(worker) then
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

function Transfer:sendQuery(worker, id, spec)
    if not self:workerUsable(worker) then
        return false
    end
    return self:queueTo(worker, {
        proto = self.Modems.PROTOCOL,
        op = "query",
        target = worker.id,
        sender = os.getComputerID(),
        version = self.version,
        id = id,
        container = spec.container,
        part = spec.part,
        slot = spec.slot,
        tank = spec.tank,
        names = spec.names,
        limit = spec.limit,
        from = os.getComputerID(),
    })
end

function Transfer:requestQuery(spec)
    spec = spec or {}
    local now = os.epoch("utc")
    local key = spec.key or ("q:" .. tostring(spec.container or "items") .. ":" .. tostring(now))
    if not spec.allowConcurrent then
        if not spec.noCache then
            local cached = self.queryCache[key]
            if cached and now - cached.at <= self.queryTtl then
                return "done", cached.result
            end
        end
        if self.queryRunning[key] then
            return "pending"
        end
    end
    local worker = self:pickWorkerFor()
    if not worker then
        -- No worker with a free slot: every instruction has to run on a remote worker
        -- now, so this is simply "busy" (the caller defers and retries next round).
        return "busy"
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

-- One instruction = one peripheral call: `part` picks the call the worker makes.
--   item : "items" (list) | "size" (size) | "limit" (getItemLimit(slot))
--   fluid: "tanks" (tanks) | "tank" (getTank(slot))
-- Returns "pending" (in flight), "done" (answered from the cache) or "busy"
-- (no worker is available right now - the instruction is retried next round).
function Transfer:submitPart(name, kind, part, slot, ts)
    if type(name) ~= "string" or name == "" then
        return "busy"
    end
    if kind == "fluid" then
        if part == "tank" then
            return self:requestQuery({ container = name,
                key = "tank:" .. name .. ":" .. tostring(slot),
                part = "tank", tank = slot, noCache = true })
        end
        return self:requestQuery({ container = name, key = "tanks:" .. name, part = "tanks",
            ts = tonumber(ts), allowConcurrent = true })
    end
    if part == "size" then
        return self:requestQuery({ container = name, key = "size:" .. name, part = "size",
            ts = tonumber(ts), noCache = true })
    end
    if part == "limit" then
        return self:requestQuery({ container = name,
            key = "limit:" .. name .. ":" .. tostring(slot),
            part = "limit", slot = slot, noCache = true })
    end
    return self:submitScan(name, 0, ts, "items")
end

function Transfer:submitScan(name, freshMs, ts, part)
    if type(name) ~= "string" or name == "" then
        return "busy"
    end
    local key = "scan:" .. name
    local now = os.epoch("utc")
    local fresh = tonumber(freshMs) or 0
    if fresh > 0 then
        local cached = self.queryCache[key]
        if cached and cached.result and
            now - tonumber(cached.result.at or cached.at or 0) <= fresh then
            return "done", cached.result
        end
    end
    if not self:available() then
        return "busy"
    end
    return self:requestQuery({ container = name, key = key, part = part or "items",
        ts = tonumber(ts), allowConcurrent = true })
end

function Transfer:queryResult(key)
    local cached = self.queryCache[key]
    if not cached then
        return nil
    end
    return cached.result
end

function Transfer:queryStatus()
    return {
        workers = #self:capableWorkers(),
        submitted = self.queryStats.submitted,
        done = self.queryStats.done,
        failed = self.queryStats.failed,
        busyRejected = self.queryStats.busyRejected,
        acked = self.queryStats.acked or 0,
        pending = self:queryPendingCount(),
        last = self.lastQuery,
    }
end

function Transfer:queryPendingCount()
    local count = 0
    for _ in pairs(self.queryRunning) do
        count = count + 1
    end
    return count
end

function Transfer:sendDetail(worker, request)
    return self:queueTo(worker, {
        proto = self.Modems.PROTOCOL,
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
        return "busy"
    end
    if not self:available() then
        return "busy"
    end
    -- One instruction = one getItemDetail() call: only the first sample is sent.
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
        return "busy"
    end
    local worker = self:pickWorkerFor()
    if not worker then
        return "busy"
    end
    self.detailSeq = self.detailSeq + 1
    local request = { id = self.detailSeq, worker = worker.id, at = os.epoch("utc"), samples = batch }
    if not self:sendDetail(worker, request) then
        return "busy"
    end
    self:workerBegin(worker)
    worker.busyKind = "detail"
    request.sendAt = os.epoch("utc")
    self.details[request.id] = request
    self.detailStats.submitted = self.detailStats.submitted + 1
    return "pending"
end

function Transfer:takeDetailResults()
    local out = self.detailResults
    self.detailResults = {}
    return out
end

function Transfer:detailPendingCount()
    local count = 0
    for _ in pairs(self.details) do
        count = count + 1
    end
    return count
end

function Transfer:detailStatus()
    return {
        workers = #self:capableWorkers(),
        submitted = self.detailStats.submitted,
        done = self.detailStats.done,
        failed = self.detailStats.failed,
        items = self.detailStats.items,
        pending = self:detailPendingCount(),
        crafterDetail = self.crafterDetailStats,
        last = self.lastDetail,
    }
end

function Transfer:applyWorkerLogs(worker, message)
    if message.logs == nil then
        return false
    end
    local lines = self.Assert.field(message, "logs", "table")
    local label = self:workerLabel(worker) or ""
    local id = tostring(worker and worker.id or message.from)
    local count = #lines
    local limit = math.min(count, MAX_WORKER_LOG_LINES)
    for index = 1, limit do
        self.log("[worker#%s%s] %s", id, label, tostring(lines[index]))
    end
    if count > limit then
        self.log.warn("[worker#%s%s] sent %d log lines in one message (limit %d) - the rest was dropped; " ..
            "version mismatch or a bug on that worker", id, label, count, MAX_WORKER_LOG_LINES)
    end
    return true
end

function Transfer:applyWorkerState(worker, message)
    worker.stateAt = os.epoch("utc")
    if tonumber(message.jobChannel) then
        local chan = math.floor(tonumber(message.jobChannel))
        if worker.jobChannel ~= chan then
            worker.jobChannel = chan
            self.log("IFMWorker #%s private job channel: %d (jobs no longer hit the shared channel)",
                tostring(worker.id), chan)
        end
    end
    if type(message.version) == "string" then
        if worker.version ~= message.version then
            worker.version = message.version
            self.log("IFMWorker #%s reports version %s", tostring(worker.id), tostring(message.version))
        end
        if self.version and message.version ~= self.version then
            self.log("IFMWorker #%s version mismatch: worker %s vs server %s - it will NOT be used for " ..
                "moves/queries; copy the same build to that computer", tostring(worker.id),
                tostring(message.version), tostring(self.version))
        end
    end
    if not worker.firstStateLogged then
        worker.firstStateLogged = true
        self.log("IFMWorker #%s state received: counters: jobs=%s moved=%s queries=%s",
            tostring(worker.id), tostring(message.jobs), tostring(message.moved), tostring(message.queries))
        if tonumber(message.jobs) == nil or tonumber(message.queries) == nil then
            self.log("IFMWorker #%s reports no counters (old build?) - the web UI would show 0; copy the same " ..
                "build to that computer", tostring(worker.id))
        end
    end
    worker.tasks = message.tasks
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
    worker.stuck = tonumber(message.stuck) or worker.stuck or 0
    if tonumber(message.slots) and tonumber(message.slots) >= 1 then
        worker.slots = math.floor(tonumber(message.slots))
    end
    worker.load = tonumber(message.load) or worker.load
    worker.peak = tonumber(message.peak) or worker.peak
    if not self:workerHasPending(worker) then
        local slots = self:workerSlots(worker)
        local reported = tonumber(message.load)
        if reported == nil then
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
            container = message.lastQuery.container,
            at = message.lastQuery.at,
            elapsed = message.lastQuery.elapsed,
            stacks = message.lastQuery.stacks,
            scanned = message.lastQuery.scanned,
        }
    end
end

-- Two shapes of the same list:
--   * default: the summary the web panel receives on every push (load, slots,
--     counters, stale/waiting flags) - no task texts and no per-second-changing
--     fields, so an idle master does not re-send seven ~1.2 KB records every few
--     seconds just because a counter or an age ticked.
--   * opts.full: everything the terminal diagnose screen prints (task list, last
--     query, age/free/usable) - asked for on demand instead of riding along on
--     the websocket.
function Transfer:workersForUi(opts)
    local full = type(opts) == "table" and opts.full == true
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
        local slots = self:workerSlots(worker)
        local load = math.max(0, math.min(slots, tonumber(worker.dispatchLoad) or 0))
        local stateAt = worker.stateAt or 0
        local lastSeen = worker.lastSeen or now
        local quietFor = math.floor((now - math.max(stateAt, lastSeen)) / 1000)
        local stale = (now - math.max(stateAt, lastSeen)) > WORKER_TIMEOUT
        local record = {
            id = worker.id,
            name = worker.name or ("worker-#" .. tostring(worker.id)),
            jobs = worker.jobs or 0,
            moved = worker.moved or 0,
            queries = worker.queries or 0,
            details = worker.details or 0,
            detailItems = worker.detailItems or 0,
            busy = worker.busy and true or false,
            slots = slots,
            load = load,
            peak = math.min(slots, tonumber(worker.dispatchPeak) or load),
            -- one decimal is all the panel shows; the raw average was a long
            -- float that changed on every push without telling anything more
            avg = math.floor((tonumber(worker.dispatchAvg) or load) * 10 + 0.5) / 10,
            stuck = worker.stuck or 0,
            pending = pending,
            pendingQueries = pendingQueries,
            -- "registered but no state report yet" is a stable flag. age/stateAge
            -- used to change every single second even while the worker sat idle,
            -- which made the websocket re-send the whole record forever.
            waiting = stateAt == 0,
            stale = stale,
            version = worker.version,
            versionMismatch = (self.version ~= nil and type(worker.version) == "string" and
                worker.version ~= "" and worker.version ~= self.version) and true or false,
        }
        if stale then
            record.silentFor = quietFor
        end
        if full then
            record.tasks = worker.tasks or {}
            record.lastQuery = worker.lastQuery
            record.age = math.floor((now - lastSeen) / 1000)
            record.stateAge = quietFor
            record.free = math.max(0, slots - load)
            record.busyKind = worker.busyKind
            record.usable = self:workerUsable(worker)
        end
        out[#out + 1] = record
    end
    table.sort(out, function(a, b)
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

return Transfer
