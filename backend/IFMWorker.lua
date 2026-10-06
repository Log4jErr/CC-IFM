local args = { ... }

local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMWorker.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path ..
            " - keep IFMWorker.lua next to the modules/ directory (the unpacker bundle writes both)", 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

local Modems = loadModule("modems")
local Peripherals = loadModule("peripherals")
local Transfer = loadModule("transfer")
local Assert = loadModule("assert")

local DEFAULT_CHANNEL = Modems.CHANNEL
local PROTOCOL = Modems.PROTOCOL
local HELLO_INTERVAL = 5
local STATE_INTERVAL = 1
local MASTER_TIMEOUT = 30
local QUERY_LIMIT = 1024
-- Every task is exactly one peripheral call, so this is also the number of calls that
-- may be in flight at once. The master derives the parallel-container limit from it.
local MAX_CALLS = 64
local STATE_TASK_LIST = 8
local SCREEN_TASK_LINES = 12
local TASK_TIMEOUT = 60

local function printUsage()
    print("IFMWorker - IFM distributed worker (moves, queries and item detail)")
    print("Usage: IFMWorker.lua [--channel <n>] [--name <label>] [--help]")
    print("  --channel  modem channel shared with the IFM master (default " .. tostring(DEFAULT_CHANNEL) .. ")")
    print("  --name     label shown in the web UI (default: computer id)")
    print("This worker only moves and queries items/fluids. Processes, storage compaction and the")
    print("web relay always stay on the master. It does need the same modules/ directory as the master")
    print("(modem discovery, peripheral scan and the channel/protocol constants) - the unpacker")
    print("bundle writes IFMMaster.lua / IFMWorker.lua and ifm/*.lua together, so keep them together.")
    print("It runs up to " .. tostring(MAX_CALLS) ..
        " peripheral calls at once (one task = one call) and only reports")
    print("busy when that task table is full; the master keeps working on its own in the meantime.")
    print("Requires a modem (wired recommended: the worker then sees the same containers as the master).")
end

local channel = DEFAULT_CHANNEL
local workerName = nil
local index = 1
while index <= #args do
    local value = tostring(args[index])
    if value == "--help" or value == "-h" then
        printUsage()
        return
    elseif value == "--channel" then
        index = index + 1
        channel = tonumber(args[index]) or channel
    elseif value == "--name" then
        index = index + 1
        workerName = tostring(args[index] or "")
    else
        print("unknown argument ignored: " .. value)
    end
    index = index + 1
end

local modem, modemSide = Modems.find()
if not modem then
    print("IFMWorker: no modem found.")
    print("Attach a (wired) modem and run this program again.")
    return
end

local okOpen, openErr = pcall(modem.open, channel)
if not okOpen then
    print("IFMWorker: cannot open channel " .. tostring(channel) .. " (" .. tostring(openErr) .. ")")
    return
end

local computerId = os.getComputerID()

local jobChannel = Modems.workerChannelOf(computerId)
do
    local okJob, jobErr = pcall(modem.open, jobChannel)
    if not okJob then
        print("[worker] warning: cannot open private job channel " .. tostring(jobChannel) ..
            " (" .. tostring(jobErr) .. ") - falling back to the shared channel")
        jobChannel = nil
    end
end
if workerName == nil or workerName == "" then
    workerName = "worker-#" .. tostring(computerId)
end

local version = Transfer.VERSION

local MAX_LOG_LINE_BYTES = 300
local logOutbox = {}

-- Slot-limit caches moved to the master: the worker now executes exactly one
-- peripheral call per task, so it has nothing to batch or cache here.

local function workerLog(text)
    local line = tostring(text)
    print("[IFMWorker] " .. line)
    if #line > MAX_LOG_LINE_BYTES then
        line = string.sub(line, 1, MAX_LOG_LINE_BYTES) .. "..."
    end
    logOutbox[#logOutbox + 1] = line
end

local lastSendError = nil
local function reply(message)
    message.proto = PROTOCOL
    message.from = computerId
    local ok, err = Modems.transmit(modem, channel, message)
    if not ok then
        local text = tostring(err)
        if text ~= lastSendError then
            lastSendError = text
            workerLog("modem send failed (" .. tostring(message.op) .. "): " .. text)
        end
    end
end

local resultOutbox = {}
local function queueResult(message)
    resultOutbox[#resultOutbox + 1] = message
end

local function flushResults()
    local results = resultOutbox
    local logs = logOutbox
    if #results == 0 and #logs == 0 then
        return 0
    end
    resultOutbox = {}
    logOutbox = {}
    local payload = { op = "results", results = results }
    if #logs > 0 then
        payload.logs = logs
    end
    reply(payload)
    return #results
end

-- Item moves must carry both slots (fromSlot/toSlot) from the master: the worker
-- only executes, and list() is reserved for query (scan) tasks.
local function runMove(job)
    local limit = tonumber(job.limit) or 1
    if limit <= 0 then
        return 0, "limit must be > 0"
    end
    if type(job.from) ~= "string" or type(job.to) ~= "string" then
        return 0, "bad job (from/to must be peripheral names)"
    end
    local actor = job.actor == "to" and "to" or "from"
    local function methodOf(handle, name)
        if type(handle) ~= "table" then
            return nil
        end
        return handle[name]
    end
    if job.action == "push_item" then
        local fromPeripheral = peripheral.wrap(job.from)
        local toPeripheral = peripheral.wrap(job.to)
        if not fromPeripheral then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        if not toPeripheral then
            return 0, "peripheral " .. tostring(job.to) .. " not found"
        end
        local fromSlot = tonumber(job.fromSlot)
        if not fromSlot or fromSlot < 1 then
            return 0, "job rejected: no explicit source slot (fromSlot) - the master must pick it"
        end
        local toSlot = tonumber(job.toSlot)
        if not toSlot or toSlot < 1 then
            return 0, "job rejected: no explicit target slot (toSlot) - the master must pick it"
        end
        if actor == "to" then
            local pull = methodOf(toPeripheral, "pullItems")
            if not pull then
                return 0, tostring(job.to) .. " has no pullItems (not an inventory peripheral)"
            end
            local ok, moved = pcall(pull, job.from, fromSlot, limit, toSlot)
            if ok and type(moved) == "number" and moved > 0 then
                return moved
            end
            return 0, ok and "moved nothing" or tostring(moved)
        end
        local push = methodOf(fromPeripheral, "pushItems")
        if not push then
            return 0, tostring(job.from) .. " has no pushItems (not an inventory peripheral)"
        end
        local ok, moved = pcall(push, job.to, fromSlot, limit, toSlot)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        return 0, ok and "moved nothing" or tostring(moved)
    end
    if job.action == "push_fluid" then
        local fromPeripheral = peripheral.wrap(job.from)
        local toPeripheral = peripheral.wrap(job.to)
        if not fromPeripheral then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        if not toPeripheral then
            return 0, "peripheral " .. tostring(job.to) .. " not found"
        end
        if actor == "to" then
            local pull = methodOf(toPeripheral, "pullFluid")
            if not pull then
                return 0, tostring(job.to) .. " has no pullFluid (not a fluid peripheral)"
            end
            local ok, moved = pcall(pull, job.from, limit, job.fluid)
            if ok and type(moved) == "number" and moved > 0 then
                return moved
            end
            return 0, ok and "moved nothing" or tostring(moved)
        end
        local push = methodOf(fromPeripheral, "pushFluid")
        if not push then
            return 0, tostring(job.from) .. " has no pushFluid (not a fluid peripheral)"
        end
        local ok, moved = pcall(push, job.to, limit, job.fluid)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        return 0, ok and "moved nothing" or tostring(moved)
    end
    return 0, "unknown action " .. tostring(job.action)
end

local function describeMove(job)
    if job.action == "push_item" then
        return string.format("move %s x%s %s#%s -> %s#%s", tostring(job.item or job.fluid or "?"),
            tostring(job.limit), tostring(job.from), tostring(job.fromSlot), tostring(job.to),
            tostring(job.toSlot))
    end
    if job.action == "push_fluid" then
        return string.format("fluid %s x%s %s -> %s", tostring(job.fluid), tostring(job.limit),
            tostring(job.from), tostring(job.to))
    end
    return tostring(job.action or "job")
end

local peripherals = Peripherals.new({ Assert = Assert, log = function() end })

local function pickContainer(spec)
    Assert.is(type(spec) == "table", "query spec must be a table, got %s", type(spec))
    local name = spec.container
    Assert.string(name, "query spec.container")
    return tostring(name)
end

-- Peripheral handles are looked up once and reused: peripheral.wrap() is a local
-- lookup, not a peripheral call, so it must not be repeated inside every task. A
-- handle is dropped again when a call on it fails (the peripheral may be gone).
local wrappedHandles = {}
local function handleOf(side)
    local cached = wrappedHandles[side]
    if cached then
        return cached
    end
    local handle = peripheral.wrap(side)
    if handle then
        wrappedHandles[side] = handle
    end
    return handle
end
local function dropHandle(side)
    wrappedHandles[side] = nil
end

-- Peripheral set changes (attach / detach, a wired modem renumbering its peripherals)
-- invalidate the classification and every cached wrap: rescanning on the event keeps the
-- worker's view in step with the master's. Throttled like the master, so a burst of
-- events only costs one scan.
local lastPeripheralScanAt = 0
local peripheralScanPending = false
local function rescanPeripheralsIfNeeded(now)
    if not peripheralScanPending or now - lastPeripheralScanAt < 1000 then
        return
    end
    peripheralScanPending = false
    lastPeripheralScanAt = now
    peripherals:scan()
    for side in pairs(wrappedHandles) do
        wrappedHandles[side] = nil
    end
end

-- ===== One task = one peripheral call ==========================================
-- Every helper below performs exactly one call on the peripheral and returns
-- (value, why). The master schedules them as separate instructions, so a slow
-- peripheral only ever delays the single call that touches it.
local function callList(side)
    -- Do NOT gate this on the cached classification (peripherals:isInventory): a wired
    -- modem renumbers its peripherals when it is reconnected, so the worker's boot-time
    -- scan can be stale - the wrapped handle and the method check below are the real
    -- test. The worker must not reject a container the master can query.
    local inventory = handleOf(side)
    if not inventory then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(inventory.list) ~= "function" then
        return nil, "wrapped, but it has no list()"
    end
    local ok, stacks = pcall(inventory.list)
    if not ok then
        dropHandle(side)
        return nil, "list() threw: " .. tostring(stacks)
    end
    if type(stacks) ~= "table" then
        return nil, "list() returned " .. type(stacks)
    end
    return stacks
end

local function callSize(side)
    local inventory = handleOf(side)
    if not inventory then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(inventory.size) ~= "function" then
        return nil, "wrapped, but it has no size()"
    end
    local ok, value = pcall(inventory.size)
    if not ok then
        dropHandle(side)
        return nil, "size() threw: " .. tostring(value)
    end
    local size = tonumber(value)
    if not size or size <= 0 then
        return nil, "size() returned " .. tostring(value)
    end
    return math.floor(size)
end

local function callItemLimit(side, slot)
    local inventory = handleOf(side)
    if not inventory then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(inventory.getItemLimit) ~= "function" then
        return nil, "wrapped, but it has no getItemLimit()"
    end
    local ok, value = pcall(inventory.getItemLimit, slot)
    if not ok then
        dropHandle(side)
        return nil, "getItemLimit(" .. tostring(slot) .. ") threw: " .. tostring(value)
    end
    local limit = tonumber(value)
    if not limit or limit <= 0 then
        return nil, "getItemLimit(" .. tostring(slot) .. ") returned " .. tostring(value)
    end
    return math.floor(limit)
end

local function callItemDetail(side, slot)
    local inventory = handleOf(side)
    if not inventory then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(inventory.getItemDetail) ~= "function" then
        return nil, "wrapped, but it has no getItemDetail()"
    end
    local ok, value = pcall(inventory.getItemDetail, slot)
    if not ok then
        dropHandle(side)
        return nil, "getItemDetail(" .. tostring(slot) .. ") threw: " .. tostring(value)
    end
    if value ~= nil and type(value) ~= "table" then
        return nil, "getItemDetail(" .. tostring(slot) .. ") returned " .. type(value)
    end
    return value
end

local function callTanks(side)
    -- Same reasoning as callList: the cached fluid classification may be stale after a
    -- wired modem renumbers its peripherals, so the wrapped handle decides.
    local storage = handleOf(side)
    if not storage then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(storage.tanks) ~= "function" then
        return nil, "wrapped, but it has no tanks()"
    end
    local ok, value = pcall(storage.tanks)
    if not ok then
        dropHandle(side)
        return nil, "tanks() threw: " .. tostring(value)
    end
    if type(value) ~= "table" then
        return nil, "tanks() returned " .. type(value)
    end
    return value
end

local function callTank(side, slot)
    local storage = handleOf(side)
    if not storage then
        return nil, "peripheral.wrap() returned nil (unloaded chunk? hardware gone?)"
    end
    if type(storage.getTank) ~= "function" then
        return nil, "wrapped, but it has no getTank()"
    end
    local ok, value = pcall(storage.getTank, slot)
    if not ok then
        dropHandle(side)
        return nil, "getTank(" .. tostring(slot) .. ") threw: " .. tostring(value)
    end
    if value ~= nil and type(value) ~= "table" then
        return nil, "getTank(" .. tostring(slot) .. ") returned " .. type(value)
    end
    return value
end


-- part = "items": the inventory snapshot (one list() call).
local function queryItems(spec, side)
    local wanted = type(spec.names) == "table" and spec.names or nil
    local cap = tonumber(spec.limit) or QUERY_LIMIT
    local items, totals, dropped = {}, {}, 0
    local stacks, why = callList(side)
    if not stacks then
        return items, totals, 0, 0, why
    end
    for slot, stack in pairs(stacks) do
        local name, count, nbt = nil, 0, nil
        if type(stack) == "table" then
            name = stack.name
            count = tonumber(stack.count) or 0
            nbt = stack.nbt
        elseif type(stack) == "string" then
            name = stack
            count = 1
        end
        if type(name) == "string" and (wanted == nil or wanted[name] == true) then
            totals[name] = (totals[name] or 0) + count
            if #items < cap then
                items[#items + 1] = {
                    container = side,
                    slot = tonumber(slot) or slot,
                    name = name,
                    count = count,
                    nbt = nbt,
                }
            else
                dropped = dropped + 1
            end
        end
    end
    return items, totals, 1, dropped, "ok"
end

-- part = "tanks": all tanks in one call (the normal case).
local function queryFluids(spec, side)
    local wanted = type(spec.names) == "table" and spec.names or nil
    local cap = tonumber(spec.limit) or QUERY_LIMIT
    local tanks, totals, dropped = {}, {}, 0
    local rows, why = callTanks(side)
    if not rows then
        -- No tanks() on this peripheral: the master asks for one tank at a time
        -- (part = "tank") instead of looping here.
        return tanks, totals, 0, 0, why
    end
    for slot, tank in pairs(rows) do
        local name = type(tank) == "table" and tank.name or nil
        local amount = type(tank) == "table" and (tonumber(tank.amount) or 0) or 0
        if type(name) == "string" and (wanted == nil or wanted[name] == true) then
            totals[name] = (totals[name] or 0) + amount
            if #tanks < cap then
                tanks[#tanks + 1] = {
                    container = side,
                    tank = tonumber(slot) or slot,
                    name = name,
                    amount = amount,
                }
            else
                dropped = dropped + 1
            end
        end
    end
    return tanks, totals, 1, dropped, "ok"
end

-- One query instruction = one peripheral call, selected by spec.part:
--   "items" (default) -> list()          "size"  -> size()
--   "limit"           -> getItemLimit(slot)
--   "tanks"           -> tanks()         "tank"  -> getTank(slot)
local function runQuery(spec)
    local startedAt = os.epoch("utc")
    local container = pickContainer(spec)
    local part = type(spec.part) == "string" and spec.part ~= "" and spec.part or "items"
    local result = {
        op = "query_result",
        id = spec.id,
        mode = part,
        part = part,
        at = startedAt,
        ok = true,
        container = container,
    }
    if part == "size" then
        local size, why = callSize(container)
        result.size = size
        if not size then
            result.ok = false
            result.error = why
        end
    elseif part == "limit" then
        local slot = tonumber(spec.slot)
        local limit, why = callItemLimit(container, slot)
        result.slot = slot
        result.limit = limit
        if not limit then
            result.ok = false
            result.error = why
        end
    elseif part == "tanks" then
        local tanks, totals, scanned, dropped, why = queryFluids(spec, container)
        result.tanks = tanks
        result.fluidTotals = totals
        result.fluidScanned = scanned
        result.fluidDropped = dropped
        result.scanned = scanned
        if scanned < 1 then
            result.ok = false
            result.error = why
        end
    elseif part == "tank" then
        local slot = tonumber(spec.tank)
        local tank, why = callTank(container, slot)
        result.tank = slot
        result.tankData = type(tank) == "table"
            and { name = tank.name, amount = tonumber(tank.amount) or 0 } or nil
        result.scanned = result.tankData and 1 or 0
        if not result.tankData then
            result.ok = false
            result.error = why or "getTank() returned nothing"
        end
    else
        local items, totals, scanned, dropped, why = queryItems(spec, container)
        result.items = items
        result.itemTotals = totals
        result.itemScanned = scanned
        result.itemDropped = dropped
        result.scanned = scanned
        if scanned < 1 then
            result.ok = false
            result.error = why
        end
    end
    local seen = peripherals:names("inventory")
    local sample = {}
    for index = 1, math.min(#seen, 8) do
        sample[index] = seen[index]
    end
    result.diag = {
        container = container,
        exists = peripherals:exists(container) and true or false,
        inventories = #seen,
        sample = sample,
    }
    result.elapsed = os.epoch("utc") - startedAt
    return result
end

-- Exactly one sample per instruction: one getItemDetail() call, no batching.
local function runDetail(spec)
    local startedAt = os.epoch("utc")
    local result = {
        op = "detail_result",
        id = spec.id,
        ok = true,
        details = {},
    }
    local samples = type(spec.samples) == "table" and spec.samples or {}
    local sample = samples[1]
    local side = type(sample) == "table" and sample.container or nil
    local slot = type(sample) == "table" and tonumber(sample.slot) or nil
    local name = type(sample) == "table" and sample.name or nil
    if type(side) == "string" and side ~= "" and slot and type(name) == "string" and name ~= "" then
        local detail, why = callItemDetail(side, slot)
        if not detail then
            result.ok = false
            result.error = why
        elseif detail.name == nil or detail.name == name then
            result.details[#result.details + 1] = {
                container = side,
                slot = slot,
                name = name,
                nbt = sample.nbt,
                detail = {
                    name = detail.name or name,
                    displayName = detail.displayName,
                    maxCount = tonumber(detail.maxCount),
                    tags = detail.tags,
                    -- Per-stack components the web resource panel draws: the
                    -- enchantment list (each entry carries a displayName), the
                    -- remaining durability as a 0..1 fraction and the used
                    -- durability points. Each may be nil when the item has none.
                    enchantments = detail.enchantments,
                    durability = tonumber(detail.durability),
                    damage = tonumber(detail.damage),
                },
            }
        end
    else
        result.ok = false
        result.error = "detail request without exactly one usable sample"
    end
    result.items = #result.details
    result.elapsed = os.epoch("utc") - startedAt
    return result
end

local masterId = nil
local lastMasterAt = 0
local masterOnline = false
local helloAt = 0
local masterVersion = nil
local versionWarning = nil
local lastVersionWarning = nil

local jobsDone = 0
local movedTotal = 0
local queriesDone = 0
local detailsDone = 0
local detailItems = 0
local lastStateAt = 0
local lastQuery = nil
local stuckTotal = 0

local STUCK_PERIPHERAL_COOLDOWN = 30
local stuckPeripherals = {}
local stuckPeripheralWarned = {}

local function peripheralNamesOf(message)
    local out = {}
    if type(message) ~= "table" then
        return out
    end
    local function add(name)
        if type(name) == "string" and name ~= "" then
            out[#out + 1] = name
        end
    end
    if message.op == "query" then
        add(pickContainer(message))
    else
        add(message.from)
        add(message.to)
    end
    return out
end

local function suspendedPeripheralOf(message)
    local now = os.epoch("utc")
    for _, name in ipairs(peripheralNamesOf(message)) do
        local untilAt = stuckPeripherals[name]
        if untilAt then
            if untilAt <= now then
                stuckPeripherals[name] = nil
            else
                return name
            end
        end
    end
    return nil
end

local tasks = {}
local taskOrder = {}
local pumpTasks
local peakLoad = 0

local function taskCount()
    return #taskOrder
end

local function notePeakLoad()
    local count = taskCount()
    if count > peakLoad then
        peakLoad = count
    end
    return count
end

local function taskList()
    local out = {}
    for _, id in ipairs(taskOrder) do
        local task = tasks[id]
        if task then
            out[#out + 1] = task.text
        end
    end
    return out
end

local function publishedTasks()
    local all = taskList()
    if #all <= STATE_TASK_LIST then
        return all
    end
    local out = {}
    for i = 1, STATE_TASK_LIST do
        out[i] = all[i]
    end
    out[#out + 1] = "+" .. tostring(#all - STATE_TASK_LIST) .. " more"
    return out
end

local function reportState()
    local running = taskCount()
    reply({
        op = "state",
        name = workerName,
        version = version,
        jobChannel = jobChannel,
        busy = running >= MAX_CALLS,
        busyKind = running > 0 and "calls" or nil,
        load = running,
        peak = peakLoad,
        slots = MAX_CALLS,
        masterVersion = masterVersion,
        versionMismatch = versionWarning ~= nil,
        jobs = jobsDone,
        moved = movedTotal,
        queries = queriesDone,
        details = detailsDone,
        detailItems = detailItems,
        tasks = publishedTasks(),
        lastQuery = lastQuery,
        stuck = stuckTotal,
    })
    lastStateAt = os.epoch("utc")
    peakLoad = running
end

local function dropStuckTasks(now)
    for index = #taskOrder, 1, -1 do
        local task = tasks[taskOrder[index]]
        if task and now - (task.startedAt or now) > TASK_TIMEOUT * 1000 then
            stuckTotal = stuckTotal + 1
            local names = task.peripherals or {}
            for _, name in ipairs(names) do
                stuckPeripherals[name] = now + STUCK_PERIPHERAL_COOLDOWN * 1000
                stuckPeripheralWarned[name] = nil
            end
            local blamed = #names > 0 and table.concat(names, ", ") or "unknown peripheral"
            workerLog("task #" .. tostring(task.id) .. " (" .. tostring(task.text) ..
                ") has been waiting for more than " .. tostring(TASK_TIMEOUT) ..
                "s - dropping it so the slot is free again; " .. tostring(blamed) ..
                " did not answer - tasks touching it fail fast for " ..
                tostring(STUCK_PERIPHERAL_COOLDOWN) .. "s")
            local why = "abandoned: " .. tostring(blamed) .. " did not answer within " ..
                tostring(TASK_TIMEOUT) .. "s"
            if task.op == "query" then
                queueResult({ op = "query_result", id = task.id, ok = false, error = why })
            elseif task.op == "detail" then
                queueResult({ op = "detail_result", id = task.id, ok = false, error = why })
            elseif task.op == "job" then
                queueResult({ op = "error", id = task.id, moved = 0, error = why })
            end
            tasks[task.id] = nil
            table.remove(taskOrder, index)
        end
    end
end

local function isWorkerHandshake(message)
    return message.role == "worker"
end

local function isMasterMessage(message, op)
    if message.target == computerId then
        return true
    end
    if message.master == true then
        return true
    end
    if op == "hello" or op == "pong" then
        return not isWorkerHandshake(message)
    end
    return false
end

local TASK_CACHE_MAX = 16
local EXECUTED_MAX = 64
local recentTasks = {}
local recentTaskOrder = {}
local executedJobs = {}
local executedOrder = {}

local function markExecuted(id)
    id = tonumber(id)
    if id == nil or executedJobs[id] then
        return
    end
    executedJobs[id] = true
    executedOrder[#executedOrder + 1] = id
    while #executedOrder > EXECUTED_MAX do
        executedJobs[table.remove(executedOrder, 1)] = nil
    end
end

local function rememberTask(id, message)
    id = tonumber(id)
    if id == nil then
        return
    end
    if not recentTasks[id] then
        recentTaskOrder[#recentTaskOrder + 1] = id
    end
    recentTasks[id] = message
    while #recentTaskOrder > TASK_CACHE_MAX do
        recentTasks[table.remove(recentTaskOrder, 1)] = nil
    end
end

local function resendTask(message)
    local cached = recentTasks[tonumber(message.id)]
    if not cached then
        return false
    end
    local copy = {}
    for key, value in pairs(cached) do
        copy[key] = value
    end
    copy.resent = true
    queueResult(copy)
    return true
end

local function rejectFull(message)
    if taskCount() < MAX_CALLS then
        return false
    end
    reply({ op = "busy", id = message.id,
        query = message.op == "query" or message.op == "detail" })
    return true
end

local function startTask(message, kind, text, body, onDone)
    local id = tonumber(message.id)
    if id == nil or tasks[id] then
        return false
    end
    local task = { id = id, kind = kind, text = text, startedAt = os.epoch("utc"), onDone = onDone,
        peripherals = peripheralNamesOf(message), op = message.op }
    task.co = coroutine.create(function()
        task.ok = true
        task.result = body()
    end)
    tasks[id] = task
    taskOrder[#taskOrder + 1] = id
    notePeakLoad()
    pumpTasks()
    return true
end

local function finishTask(task, index)
    table.remove(taskOrder, index)
    tasks[task.id] = nil
    if task.onDone then
        task.onDone(task)
    end
end

function pumpTasks(event, p1, p2, p3, p4, p5)
    for i = #taskOrder, 1, -1 do
        local task = tasks[taskOrder[i]]
        if not task then
            table.remove(taskOrder, i)
        else
            if coroutine.status(task.co) == "suspended" then
                local ok, err = coroutine.resume(task.co, event, p1, p2, p3, p4, p5)
                if not ok then
                    task.ok = false
                    task.result = "task crashed: " .. tostring(err)
                end
            end
            if coroutine.status(task.co) == "dead" then
                finishTask(task, i)
            end
        end
    end
end

local unbatchedTaskSeen = false

local function handleMessage(message, fromEnvelope)
    if type(message) ~= "table" or message.proto ~= PROTOCOL or message.from == computerId then
        return
    end
    local op = message.op
    if message.target ~= nil and message.target ~= computerId then
        return
    end
    if not isMasterMessage(message, op) then
        return
    end
    if op == "job" or op == "query" or op == "detail" then
        if not fromEnvelope then
            if not unbatchedTaskSeen then
                unbatchedTaskSeen = true
                workerLog("refused a single-task message (op=" .. tostring(op) ..
                    "): tasks must arrive as one { op = \"jobs\", jobs = {...} } envelope" ..
                    " - install the same build on master and worker")
            end
            return
        end
    end
    local senderId = message.from
    if op == "job" or op == "query" then
        senderId = tonumber(message.sender)
    end
    if senderId then
        masterId = senderId
    end
    if type(message.version) == "string" and message.version ~= "" then
        masterVersion = message.version
    end
    lastMasterAt = os.epoch("utc")
    masterOnline = true
    if op == "hello" then
        reply({ op = "pong", name = workerName, version = version, role = "worker",
            slots = MAX_TASKS, load = taskCount(), jobChannel = jobChannel })
        return
    end
    if op == "pong" then
        return
    end
    if op == "welcome" then
        if type(message.version) == "string" then
            masterVersion = message.version
            if message.version ~= version then
                versionWarning = "version mismatch: master " .. message.version .. " vs worker " .. version
                if lastVersionWarning ~= versionWarning then
                    lastVersionWarning = versionWarning
                    workerLog(versionWarning .. " - put the same build on master and worker")
                end
            else
                versionWarning = nil
            end
        end
        return
    end
    if masterVersion and masterVersion ~= version then
        local why = "version mismatch: master " .. tostring(masterVersion) .. " vs worker " .. tostring(version)
        if op == "job" then
            queueResult({ op = "error", id = message.id, moved = 0, error = why })
        elseif op == "query" then
            queueResult({ op = "query_result", id = message.id, ok = false, error = why })
        elseif op == "detail" then
            queueResult({ op = "detail_result", id = message.id, ok = false, error = why })
        end
        if lastVersionWarning ~= why then
            lastVersionWarning = why
            workerLog(why .. " - job refused; install the same build on master and worker")
        end
        return
    end
    if op == "job" then
        if resendTask(message) then
            return
        end
        if executedJobs[tonumber(message.id)] then
            queueResult({ op = "done", id = message.id, moved = 0,
                error = "already executed earlier (result expired)" })
            return
        end
        local stuckMove = suspendedPeripheralOf(message)
        if stuckMove then
            local why = "peripheral " .. tostring(stuckMove) .. " is not answering (it did not answer for " ..
                tostring(TASK_TIMEOUT) .. "s; that peripheral is skipped for " ..
                tostring(STUCK_PERIPHERAL_COOLDOWN) .. "s)"
            if not stuckPeripheralWarned[stuckMove] then
                stuckPeripheralWarned[stuckMove] = os.epoch("utc")
                workerLog("refusing moves touching " .. tostring(stuckMove) .. ": " .. why)
            end
            queueResult({ op = "error", id = message.id, moved = 0, error = why })
            return
        end
        if rejectFull(message) then
            return
        end
        startTask(message, "move", describeMove(message), function()
            local moved, err = runMove(message)
            return { moved = tonumber(moved) or 0, err = err }
        end, function(task)
            local result = task.result
            local moved, err = 0, nil
            if type(result) == "table" then
                moved = tonumber(result.moved) or 0
                err = result.err
            elseif task.ok == false then
                err = "move crashed: " .. tostring(result)
            end
            jobsDone = jobsDone + 1
            movedTotal = movedTotal + moved
            if moved == 0 and (err == nil or err == "") then
                err = "the peripheral moved nothing (target full / slot busy / wrong slot)"
            end
            local out = { op = moved > 0 and "done" or "error", id = message.id, moved = moved, error = err }
            markExecuted(message.id)
            rememberTask(message.id, out)
            queueResult(out)
        end)
        return
    end
    if op == "detail" then
        if resendTask(message) then
            return
        end
        if rejectFull(message) then
            return
        end
        local samples = type(message.samples) == "table" and message.samples or {}
        reply({ op = "detail_ack", id = message.id, samples = #samples })
        startTask(message, "detail", "detail " .. tostring(#samples) .. " item type(s)",
            function()
                return runDetail(message)
            end, function(task)
                local result = task.result
                if task.ok == false or type(result) ~= "table" then
                    local why = "detail crashed: " .. tostring(result)
                    workerLog(why)
                    local failed = { op = "detail_result", id = message.id, ok = false, error = why }
                    rememberTask(message.id, failed)
                    queueResult(failed)
                    return
                end
                detailsDone = detailsDone + 1
                detailItems = detailItems + (tonumber(result.items) or 0)
                workerLog("detail: " .. tostring(result.items) .. " of " .. tostring(#samples) ..
                    " item type(s) in " .. tostring(result.elapsed) .. "ms")
                rememberTask(message.id, result)
                queueResult(result)
            end)
        return
    end
    if op == "query" then
        if resendTask(message) then
            return
        end
        local stuckQuery = suspendedPeripheralOf(message)
        if stuckQuery then
            local why = "peripheral " .. tostring(stuckQuery) .. " is not answering (it did not answer for " ..
                tostring(TASK_TIMEOUT) .. "s; that peripheral is skipped for " ..
                tostring(STUCK_PERIPHERAL_COOLDOWN) .. "s)"
            if not stuckPeripheralWarned[stuckQuery] then
                stuckPeripheralWarned[stuckQuery] = os.epoch("utc")
                workerLog("refusing scans of " .. tostring(stuckQuery) .. ": " .. why)
            end
            queueResult({ op = "query_result", id = message.id, ok = false, error = why })
            return
        end
        if rejectFull(message) then
            return
        end
        local container = pickContainer(message)
        reply({ op = "query_ack", id = message.id, container = container })
        startTask(message, "query", "query " .. tostring(container or "?"), function()
            return runQuery(message)
        end, function(task)
            local result = task.result
            if task.ok == false or type(result) ~= "table" then
                local why = "query crashed: " .. tostring(result)
                workerLog(why)
                local failed = { op = "query_result", id = message.id, ok = false, error = why }
                rememberTask(message.id, failed)
                queueResult(failed)
                return
            end
            queriesDone = queriesDone + 1
            local stacks = #(result.items or {}) + #(result.tanks or {})
            local scanned = (result.itemScanned or 0) + (result.fluidScanned or 0) + (result.scanned or 0)
            if result.ok then
                lastQuery = {
                    mode = result.mode,
                    container = result.container,
                    at = result.at,
                    elapsed = result.elapsed,
                    stacks = stacks,
                    scanned = scanned,
                }
                workerLog("query " .. tostring(result.part or result.mode) .. " of " ..
                    tostring(result.container) .. ": " .. tostring(stacks) .. " row(s) in " ..
                    tostring(result.elapsed) .. "ms")
            else
                workerLog("query failed: " .. tostring(result.error))
            end
            rememberTask(message.id, result)
            queueResult(result)
        end)
        return
    end
end

local function dispatchMessage(message)
    if type(message) ~= "table" or message.op ~= "jobs" then
        return handleMessage(message)
    end
    local jobs = type(message.jobs) == "table" and message.jobs or {}
    for _, job in ipairs(jobs) do
        if type(job) == "table" then
            if job.op == nil then
                job.op = "job"
            end
            if job.target == nil then
                job.target = message.target
            end
            handleMessage(job, true)
        end
    end
end

local lastDrawAt = 0
local lastText = {}

local IFM_ART = {
    "     _/_/_/  _/_/_/_/  _/      _/   ",
    "      _/    _/        _/_/  _/_/    ",
    "     _/    _/_/_/    _/  _/  _/     ",
    "    _/    _/        _/      _/      ",
    " _/_/_/  _/        _/      _/        ",
}

local function redraw(force)
    local lines = {}
    for _, art in ipairs(IFM_ART) do
        lines[#lines + 1] = art
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "IFMWorker (move + query + item detail)"
    lines[#lines + 1] = "computer : #" .. tostring(computerId) .. "  name: " .. tostring(workerName)
    lines[#lines + 1] = "modem    : " .. tostring(modemSide or "?") .. "  channel: " .. tostring(channel)
    lines[#lines + 1] = "master   : " .. (masterOnline and ("#" .. tostring(masterId or "?")) or "waiting...")
    lines[#lines + 1] = "jobs     : " .. tostring(jobsDone) .. " move(s), " .. tostring(movedTotal) .. " item(s), " ..
        tostring(queriesDone) .. " query(ies), " .. tostring(detailsDone) .. " detail batch(es)"
    lines[#lines + 1] = "details  : " .. tostring(detailItems) .. " item detail(s) sent to the master"
    lines[#lines + 1] = "scope    : processes / compact / relay stay on the master"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "calls    : " .. tostring(taskCount()) .. " / " .. tostring(MAX_CALLS) ..
        " peripheral call(s) in flight" .. (taskCount() >= MAX_CALLS and "  (FULL - the master will use others)" or "")
    if stuckTotal > 0 then
        lines[#lines + 1] = "stuck    : " .. tostring(stuckTotal) ..
            " task(s) dropped after " .. tostring(TASK_TIMEOUT) .. "s - check those containers/peripherals"
    end
    lines[#lines + 1] = "current work:"
    local tasks = taskList()
    if #tasks == 0 then
        lines[#lines + 1] = "  (idle)"
    else
        for index, text in ipairs(tasks) do
            if index > SCREEN_TASK_LINES then
                lines[#lines + 1] = "  ... +" .. tostring(#tasks - SCREEN_TASK_LINES) .. " more"
                break
            end
            lines[#lines + 1] = "  - " .. text
        end
    end
    if lastQuery then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "last query: " .. tostring(lastQuery.mode) .. ", " .. tostring(lastQuery.stacks) ..
            " stack(s) in " .. tostring(lastQuery.elapsed) .. "ms"
    end
    if versionWarning then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: " .. tostring(versionWarning)
        lines[#lines + 1] = "put the same build (IFMMaster.lua / IFMWorker.lua) on both computers"
    end
    if not force and table.concat(lines, "\n") == lastText.value then
        return
    end
    lastText.value = table.concat(lines, "\n")
    term.clear()
    term.setCursorPos(1, 1)
    for _, text in ipairs(lines) do
        print(text)
    end
end

local function tick(now)
    rescanPeripheralsIfNeeded(now)
    if now - helloAt >= HELLO_INTERVAL * 1000 then
        helloAt = now
        reply({ op = "hello", name = workerName, channel = channel, version = version, role = "worker",
            slots = MAX_CALLS, load = taskCount() })
    end
    if masterOnline and now - lastMasterAt > MASTER_TIMEOUT * 1000 then
        masterOnline = false
        workerLog("master silent for " .. tostring(MASTER_TIMEOUT) .. "s - waiting for it")
    end
    if now - lastStateAt >= STATE_INTERVAL * 1000 then
        reportState()
    end
    notePeakLoad()
    dropStuckTasks(now)
    flushResults()
    if now - lastDrawAt >= 1000 then
        lastDrawAt = now
        redraw(false)
    end
end

redraw(true)
workerLog("IFMWorker started: name=" .. tostring(workerName) .. " channel=" .. tostring(channel) ..
    " (accepts every job type)")
reply({ op = "hello", name = workerName, channel = channel, version = version, role = "worker",
    slots = MAX_CALLS, load = taskCount() })

local function mainLoop()
    local timerToken = os.startTimer(0.2)
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        local now = os.epoch("utc")
        if event == "modem_message" then
            if tonumber(param2) == channel or (jobChannel and tonumber(param2) == jobChannel) then
                dispatchMessage(param4)
            end
        elseif event == "timer" and param1 == timerToken then
            timerToken = os.startTimer(0.2)
            tick(now)
        elseif event == "peripheral" or event == "peripheral_detach" then
            peripheralScanPending = true
            rescanPeripheralsIfNeeded(now)
        end
        pumpTasks(event, param1, param2, param3, param4, param5)
    end
end

tasks = {}
taskOrder = {}
mainLoop()