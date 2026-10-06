local args = { ... }

local IFM_VERSION = "487"

local DEFAULT_RELAY = "wss://itty.ws/c/"

local function randomRoom()
    local pools = {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz",
        "0123456789",
    }
    math.randomseed(os.epoch("utc") + (os.getComputerID() or 0) * 7919)
    local chars = {}
    for _, pool in ipairs(pools) do
        chars[#chars + 1] = pool
    end
    local out = {}
    for index, pool in ipairs(pools) do
        local picked = math.random(1, #pool)
        out[index] = pool:sub(picked, picked)
    end
    local all = table.concat(chars)
    for index = #out + 1, 12 do
        local picked = math.random(1, #all)
        out[index] = all:sub(picked, picked)
    end
    for index = #out, 2, -1 do
        local other = math.random(1, index)
        out[index], out[other] = out[other], out[index]
    end
    return table.concat(out)
end

local function printUsage()
    print("IFM (Integrated Factory Manager) - server")
    print("Usage: IFMMaster.lua [--room <room>] [--relay <relay-url>] [--random-room]")
    print("  --room         room name shared with the browser (saved into data/config.json)")
    print("                 (default: the room stored in config.json, else a new random 12-char room)")
    print("  --random-room  ignore the stored room, generate a new random one (saved into config.json)")
    print("  --relay        relay base url - the scheme picks the transport:")
    print("                   ws:// wss://    websocket (the relay upgrades the connection)")
    print("                   http:// https:// HTTP polling (for networks that block websockets)")
    print("                 default: " .. DEFAULT_RELAY)
    print("Examples:")
    print("  IFMMaster.lua")
    print("  IFMMaster.lua --random-room")
    print("  IFMMaster.lua --room myfactory123")
    print("  IFMMaster.lua --room myfactory123 --relay ws://localhost:8765/c/")
    print("  IFMMaster.lua --room myfactory123 --relay http://localhost:8765/c/")
    print("  IFMMaster.lua --room myfactory123 --relay wss://relay.example.com/c/")
    print("Note: the room never changes while this program runs (reconnects reuse it),")
    print("      and it is kept in data/config.json so restarts reuse the same room.")
    print("      --room wins over --random-room.")
end

local room = nil
local relayBase = nil
local forceRandomRoom = false
local unknown = {}
local index = 1
while index <= #args do
    local value = tostring(args[index] or "")
    if value == "--help" or value == "-h" then
        printUsage()
        return
    elseif value == "--room" then
        room = args[index + 1]
        index = index + 2
    elseif value:sub(1, 7) == "--room=" then
        room = value:sub(8)
        index = index + 1
    elseif value == "--relay" then
        relayBase = args[index + 1]
        index = index + 2
    elseif value:sub(1, 8) == "--relay=" then
        relayBase = value:sub(9)
        index = index + 1
    elseif value == "--random-room" then
        forceRandomRoom = true
        index = index + 1
    elseif value == "--relay-via-worker" then
        print("note: --relay-via-worker was removed in 1.5.0 - the server always connects the relay itself")
        index = index + 1
    else
        unknown[#unknown + 1] = value
        index = index + 1
    end
end

if (not room or room == "") and #unknown == 1 and unknown[1]:sub(1, 1) ~= "-" then
    room = unknown[1]
    unknown = {}
    print("[IFM] note: positional room argument is deprecated, use --room <room>")
end

local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMMaster.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")
local dataDir = fs.combine(baseDir, "data")

for _, value in ipairs(unknown) do
    print("[IFM] warning: unknown argument ignored: " .. tostring(value))
end

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path, 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

local Util = loadModule("util")
local Assert = loadModule("assert")
local log = Util.makeLogger("IFM", true)
local JsonFile = loadModule("jsonfile")
local Modems = loadModule("modems")

local Scheduler = loadModule("scheduler")
local Filter = loadModule("filter")
local Store = loadModule("store")
local Cache = loadModule("cache")
local Peripherals = loadModule("peripherals")
local Containers = loadModule("containers")
local Recipe = loadModule("recipe")
local RefCount = loadModule("refcount")
local Diagnose = loadModule("diagnose")
local Protocol = loadModule("protocol")
local Transfer = loadModule("transfer")
local Dispatch = loadModule("dispatch")
local Queue = loadModule("queue")
local Message = loadModule("message")
if Transfer.VERSION ~= IFM_VERSION then
    error(string.format("version mismatch: IFMMaster.lua says %s but transfer.lua says %s" ..
        " (keep them in sync; web/ifm-core.js must match too)", IFM_VERSION, tostring(Transfer.VERSION)), 0)
end

local stackScanStats = { rounds = 0, asked = 0, lastContainers = 0 }

if not fs.exists(dataDir) then
    fs.makeDir(dataDir)
end

local configPath = fs.combine(dataDir, "config.json")
local cachePath = fs.combine(dataDir, "cache.json")

local scheduler = Scheduler.new()
local store = Store.new({
    Util = Util,
    Assert = Assert,
    JsonFile = JsonFile,
    Message = Message,
    path = configPath,
    log = log,
})
local cache = Cache.new({
    Util = Util,
    Assert = Assert,
    JsonFile = JsonFile,
    Message = Message,
    path = cachePath,
    log = log,
    -- A restored instance carries its own frozen definition, so whether the process it
    -- belongs to still exists can only be answered by the definitions.
    processExists = function(name)
        return store:get("processes", name) ~= nil
    end,
})
local filter = Filter.new({
    Util = Util,
    Store = store,
    tagProvider = function(name)
        return cache:tagsOf(name)
    end,
    -- Filter containment is memoised; the key folds in the definition revision and
    -- the tag revision, so editing a filter (or finishing a tag scan) drops it.
    revisionProvider = function()
        return tostring(store:revision()) .. "|" .. tostring(cache.tagRevision or 0)
    end,
})
local peripherals = Peripherals.new({
    Util = Util,
    Assert = Assert,
    log = log,
})
local containers = Containers.new({
    Util = Util,
    Assert = Assert,
    RefCount = RefCount,
    Message = Message,
    Store = store,
    Peripherals = peripherals,
    Filter = filter,
    log = log,
})
local engine = Recipe.new({
    Util = Util,
    Assert = Assert,
    RefCount = RefCount,
    Message = Message,
    Store = store,
    Cache = cache,
    Peripherals = peripherals,
    Containers = containers,
    Filter = filter,
    log = log,
})
containers.debug = true
local diagnose = Diagnose.new({
    Util = Util,
    Assert = Assert,
    Message = Message,
    Store = store,
    Cache = cache,
    Containers = containers,
    Peripherals = peripherals,
    Recipe = engine,
})

local configLoaded, configErr = store:load()
if configLoaded then
    log("Loaded config: %s", configPath)
else
    log("No existing config (%s), starting with empty definitions", Message.describe(configErr))
end
local cacheLoaded, cacheErr = cache:load()
if cacheLoaded then
    log("Restored runtime state: %s", cachePath)
else
    log("No existing runtime state (%s), starting fresh", Message.describe(cacheErr))
end

local function normalizeRoom(value)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" or #trimmed > 64 or trimmed:find("%s") then
        return nil
    end
    return trimmed
end

local requestedRoom = normalizeRoom(room)
if room and room ~= "" and requestedRoom == nil then
    print("[IFM] warning: --room value is empty or not usable, ignoring it")
end
local storedRoom = normalizeRoom(store:getRoom())
local roomSource
if requestedRoom then
    room = requestedRoom
    roomSource = "argument"
elseif forceRandomRoom then
    room = randomRoom()
    roomSource = "random"
elseif storedRoom then
    room = storedRoom
    roomSource = "config"
else
    room = randomRoom()
    roomSource = "random"
end

if store:setRoom(room) then
    log("Room saved to %s", configPath)
end

local roomNote
if roomSource == "config" then
    roomNote = "from " .. configPath
elseif roomSource == "random" then
    roomNote = "random, saved to " .. configPath
else
    roomNote = "from --room argument"
end

relayBase = relayBase or DEFAULT_RELAY
if type(relayBase) ~= "string"
    or not (relayBase:match("^wss?://") or relayBase:match("^https?://")) then
    error(string.format("--relay must be a ws:// / wss:// / http:// / https:// url (got %s)",
        tostring(relayBase)), 0)
end
if relayBase:match("^https?://") and not (http and http.request) then
    print("[IFM] warning: this computer runs with the http API disabled (http.enabled = false)," ..
        " so an http(s) relay cannot be used - use ws:// / wss:// or enable it")
end
if relayBase:sub(-1) ~= "/" then
    relayBase = relayBase .. "/"
end
local wsUrl = relayBase .. room

local function buildProducerIndex()
    local index = {}
    local function mark(key, processName)
        if not key then
            return
        end
        local bucket = index[key]
        if not bucket then
            bucket = {}
            index[key] = bucket
        end
        bucket[processName] = true
    end
    for _, process in ipairs(store:list("processes")) do
        if not store.processIsAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                -- "Craft reference" off: that output does not make the process a
                -- candidate for the material.
                if output.craft ~= false then
                    if output.kind == "item" then
                        mark("item:" .. output.id, process.name)
                    elseif output.kind == "fluid" then
                        mark("fluid:" .. output.id, process.name)
                    elseif output.kind == "placeholder" then
                        -- A placeholder output is reachable under two keys: as "that
                        -- placeholder" (what the panel's placeholder card and the graph
                        -- node ask for) and as the concrete item it names (what a
                        -- downstream input usually asks for). Recipe:craftIndex
                        -- registers both, so the panel has to see both as craftable.
                        if output.name and output.name ~= "" then
                            mark("placeholder:" .. output.name, process.name)
                        end
                        mark("item:" .. output.item, process.name)
                    elseif output.kind == "filter" then
                        mark("filter:" .. output.id, process.name)
                    end
                end
            end
        end
    end
    return index
end

-- A filter counts as craftable only when some process outputs that very filter
-- (identity). Automatic containment - an item/fluid output the filter happens to
-- match - is display-only (a dashed graph hint), so it must not mark the filter as
-- craftable. The answer is memoised per (configuration revision, tag revision).
local filterProducerMemo = { key = nil, value = {} }
local function filterHasProducer(filterName)
    if type(filterName) ~= "string" or filterName == "" then
        return false
    end
    local key = tostring(store:revision()) .. "|" .. tostring(cache.tagRevision or 0)
    if filterProducerMemo.key ~= key then
        filterProducerMemo.key = key
        filterProducerMemo.value = {}
    end
    local memo = filterProducerMemo.value
    local cached = memo[filterName]
    if cached ~= nil then
        return cached
    end
    local found = false
    for _, process in ipairs(store:list("processes")) do
        if not store.processIsAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                if output.craft ~= false and output.kind == "filter" and output.id == filterName then
                    found = true
                    break
                end
            end
        end
        if found then
            break
        end
    end
    memo[filterName] = found
    return found
end

local function itemTags(name)
    local cached = cache:tagsOf(name)
    if type(cached) ~= "table" then
        return nil
    end
    local out = {}
    for tag, value in pairs(cached) do
        if value and type(tag) == "string" then
            out[#out + 1] = tag
        end
    end
    if #out == 0 then
        return nil
    end
    table.sort(out)
    return out
end

-- The per-stack item detail the resource panel draws (enchantments / durability /
-- damage). The full getItemDetail table is cached per (name, nbt); only the three
-- fields the web UI renders are shipped, so the resource frame stays small. nil
-- when the item has none of them (or its detail was never read).
local function itemDetailUi(kind, name, nbt)
    if kind ~= "item" then
        return nil
    end
    local detail = containers:itemDetail(name, nbt)
    if type(detail) ~= "table" then
        return nil
    end
    local enchantments = detail.enchantments
    if type(enchantments) ~= "table" or #enchantments == 0 then
        enchantments = nil
    end
    local durability = tonumber(detail.durability)
    local damage = tonumber(detail.damage)
    if enchantments == nil and durability == nil and damage == nil then
        return nil
    end
    return {
        enchantments = enchantments,
        durability = durability,
        damage = damage,
    }
end

local function collectResources()
    local list = {}
    for _, entry in ipairs(containers:resources()) do
        list[#list + 1] = {
            kind = entry.kind,
            name = entry.name,
            nbt = entry.nbt,
            count = entry.count,
            craftable = false,
            samples = {},
            tags = entry.kind == "item" and itemTags(entry.name) or nil,
            detail = itemDetailUi(entry.kind, entry.name, entry.nbt),
        }
    end
    for _, def in ipairs(store:list("filters")) do
        local samples = {}
        local seen = {}
        local count = 0
        for _, entry in ipairs(containers:filterResources(def.name)) do
            count = count + entry.count
            local key = entry.kind .. ":" .. tostring(entry.name) .. "\1" .. tostring(entry.nbt or "")
            if not seen[key] then
                seen[key] = true
                samples[#samples + 1] = { kind = entry.kind, name = entry.name, nbt = entry.nbt }
            end
        end
        list[#list + 1] = {
            kind = "filter",
            name = def.name,
            count = count,
            craftable = false,
            samples = samples,
        }
    end
    local placeholders = {}
    for _, process in ipairs(store:list("processes")) do
        for _, element in ipairs(process.outputs or {}) do
            if element.kind == "placeholder" and element.name and not placeholders[element.name] then
                placeholders[element.name] = {
                    kind = "placeholder",
                    name = element.name,
                    item = element.item,
                    craftable = false,
                    samples = { { kind = "item", name = element.item } },
                }
            end
        end
    end
    for _, entry in pairs(placeholders) do
        list[#list + 1] = entry
    end
    local index = buildProducerIndex()
    for _, entry in ipairs(list) do
        if index[entry.kind .. ":" .. entry.name] then
            entry.craftable = true
        end
        -- A filter may have no process that outputs the filter itself, yet still be
        -- feedable by processes that output items/fluids the filter matches.
        if not entry.craftable and entry.kind == "filter" then
            entry.craftable = filterHasProducer(entry.name)
        end
    end
    for _, process in ipairs(store:list("processes")) do
        if not store.processIsAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                if output.craft ~= false and output.kind == "filter" then
                    for _, entry in ipairs(list) do
                        if entry.kind == "item" or entry.kind == "fluid" then
                            if filter:matches(output.id, { kind = entry.kind, name = entry.name }) then
                                entry.craftable = true
                            end
                        end
                    end
                end
            end
        end
    end
    return list
end

local runningCrafters = {}

local function collectMachines()
    local usage = {}
    for _, entry in ipairs(engine:machineUsage()) do
        usage[entry.name] = entry
    end
    local out = {}
    for _, machine in ipairs(store:list("machines")) do
        local entry = Util.deepcopy(machine)
        local use = usage[machine.name]
        entry.running = use and use.running or 0
        entry.usable = engine:machineUsable(machine)
        out[#out + 1] = entry
    end
    return out
end

local function collectPeripherals()
    local out = {}
    local function add(kind, name)
        local containerDefs = {}
        for _, def in ipairs(store:list("containers")) do
            if def.peripheral == name then
                containerDefs[#containerDefs + 1] = {
                    name = def.name,
                    role = def.role,
                    kind = Util.kindOfDef(def),
                }
            end
        end
        local signalDefs = {}
        for _, def in ipairs(store:list("signals")) do
            if def.peripheral == name then
                signalDefs[#signalDefs + 1] = { name = def.name }
            end
        end
        out[#out + 1] = {
            kind = kind,
            name = name,
            containers = containerDefs,
            signals = signalDefs,
        }
    end
    for _, name in ipairs(peripherals:names("inventory")) do
        add("inventory", name)
    end
    for _, name in ipairs(peripherals:names("fluid")) do
        add("fluid_storage", name)
    end
    for _, name in ipairs(peripherals:names("redstone")) do
        add("redstone_relay", name)
    end
    for _, name in ipairs(peripherals:turtleNames()) do
        if runningCrafters[name] then
            add("turtle", name)
        end
    end
    return out
end

local protocol
local transfer
local dispatch

local bootAt = os.epoch("utc")

-- Boot grace: for the first second after boot the task scheduler is not advanced, so a
-- worker that boots alongside the master can register first. Everything else (relay,
-- scans, worker handshake) keeps running.
local BOOT_GRACE_MS = 1000
local bootGraceUntil = bootAt + BOOT_GRACE_MS
local bootGraceStartLogged = false
local bootGraceDoneLogged = false
local function inBootGrace(now)
    return (tonumber(now) or os.epoch("utc")) < bootGraceUntil
end

local WORKER_WARMUP_MS = 20000
local workerWarmupLogged = false
local function collectWorkers()
    local list = transfer and transfer.workersForUi and transfer:workersForUi() or nil
    if list == nil then
        return nil
    end
    if next(list) == nil and (os.epoch("utc") - bootAt) < WORKER_WARMUP_MS then
        if not workerWarmupLogged then
            workerWarmupLogged = true
            log("[startup] no worker has registered yet: keeping the page's worker list instead of clearing it" ..
                " (warmup %ds)", math.floor(WORKER_WARMUP_MS / 1000))
        end
        return nil
    end
    return list
end

local function collectSnapshot()
    return {
        containers = store:list("containers"),
        signals = store:list("signals"),
        filters = store:list("filters"),
        machineTypes = store:list("machineTypes"),
        machines = collectMachines(),
        processes = store:list("processes"),
        peripherals = collectPeripherals(),
        missing = containers:missingPeripherals(),
        resources = collectResources(),
        runtime = engine:runtime(),
        materials = engine:materials(),
        plan = engine:plan(),
        deliveries = engine:deliveries(),
        workers = collectWorkers(),
        status = buildStatus(),
    }
end

local detailScan = { queued = 0, scanned = 0, fromWorkers = 0 }

-- Set while the instance gate is closed (see the dispatch generator).
local containerScanGateLogged = false

local function detailQueueKey(name, nbt)
    return tostring(name) .. "\1" .. tostring(nbt or "")
end

local function storeTags(itemName, detail)
    local tags = {}
    if type(detail) == "table" and type(detail.tags) == "table" then
        for key, value in pairs(detail.tags) do
            if type(key) == "string" then
                tags[key] = true
            end
            if type(value) == "string" then
                tags[value] = true
            end
        end
    end
    cache:setTags(itemName, tags)
end

local function absorbWorkerDetails()
    if not transfer or not transfer.takeDetailResults then
        return 0
    end
    local entries = transfer:takeDetailResults()
    if type(entries) ~= "table" or #entries == 0 then
        return 0
    end
    local taken = containers:absorbItemDetails(entries)
    if taken > 0 then
        detailScan.fromWorkers = (detailScan.fromWorkers or 0) + taken
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.detail) == "table" and entry.name then
            storeTags(entry.name, entry.detail)
            detailScan.scanned = (detailScan.scanned or 0) + 1
        end
    end
    return taken
end

-- Defined further down (it needs the crafter helpers): routes one "item detail not
-- known yet" sample either straight to a turtle crafter (fire and forget) or into
-- the detail queue.
local enqueueDetail

local function queueMissingDetails()
    local seen = containers:takeScanSeen()
    local queued = 0
    for _, entry in ipairs(seen or {}) do
        local _, known = containers:cachedItemDetail(entry.name, entry.nbt)
        if not known and entry.container then
            if enqueueDetail(entry.container, entry.slot, entry.name, entry.nbt) then
                queued = queued + 1
            end
        end
    end
    detailScan.queued = queued
    return queued
end

local TAG_PRUNE_EVERY_TICKS = 200
local tagPruneTick = 0
local function pruneTagCache()
    tagPruneTick = (tagPruneTick or 0) + 1
    if tagPruneTick < TAG_PRUNE_EVERY_TICKS then
        return 0
    end
    tagPruneTick = 0
    local present = {}
    for _, def in ipairs(store:list("containers")) do
        for _, stack in ipairs(containers:stacks(def.name)) do
            if type(stack.name) == "string" and stack.name ~= "" then
                present[stack.name] = true
            end
        end
    end
    local dropped = cache:pruneTags(present)
    if dropped > 0 then
        log("Tag cache pruned: %d item type(s) no longer in storage", dropped)
    end
    return dropped
end

local function queueTagScan()
    local queued = 0
    for _, def in ipairs(store:list("containers")) do
        for _, stack in ipairs(containers:stacks(def.name)) do
            if type(stack.name) == "string" and stack.name ~= "" then
                local _, known = containers:cachedItemDetail(stack.name, stack.nbt)
                if not known and enqueueDetail(def.peripheral, stack.slot, stack.name, stack.nbt) then
                    queued = queued + 1
                end
            end
        end
    end
    detailScan.queued = queued
    return queued
end

function buildStatus()
    local current = protocol and protocol:status() or {}
    current.version = IFM_VERSION
    current.bootGrace = inBootGrace(os.epoch("utc"))
    current.tags = 0
    for _ in pairs(cache:tags()) do
        current.tags = current.tags + 1
    end
    if dispatch then
        current.detail = {
            depth = dispatch:depth("detail"),
            scanned = detailScan.scanned or 0,
            fromWorkers = detailScan.fromWorkers or 0,
        }
    end
    local capacity = containers.capacityStats(containers)
    if type(capacity) == "table" then
        current.capacity = capacity
    end
    -- Computed once and shared: the slot-scan pending set feeds both the dedicated
    -- capacityPending status and the reason-aware containerIssues list below.
    local pendingSlotScan = nil
    if containers and containers.slotScanPendingPeripherals then
        -- Peripherals whose slot information is still being read (slot count or slot
        -- capacity): the web panel outlines their card (see renderPeripherals).
        pendingSlotScan = containers:slotScanPendingPeripherals()
        current.capacityPending = pendingSlotScan
    end
    if containers and containers.containerIssues then
        -- Attached containers that cannot be used right now, with the real reason
        -- (capability mismatch, plain "still scanning" on an always-scanned role, ...):
        -- the web panel outlines those cards and shows the reason as the tooltip.
        current.containerIssues = containers:containerIssues(64, pendingSlotScan)
    end
    local compact = engine:compactStatus()
    if compact then
        if dispatch and dispatch.queues and dispatch.queues["compact"] then
            compact.pendingMoves = dispatch:depth("compact")
            compact.activeMoves = dispatch:activeDepth("compact")
            compact.waitingMoves = dispatch:waitingDepth("compact")
            compact.movesDone = dispatch.queues["compact"].done or 0
            compact.movesDropped = dispatch.queues["compact"].dropped or 0
        end
        current.compact = compact
    end
    if engine.inputDrainStats then
        current.inputDrain = engine.inputDrainStats
    end
    if containers and containers.stackScanStatusFromSnapshot then
        local stack = { rounds = stackScanStats.rounds or 0, asked = stackScanStats.asked or 0,
            containers = stackScanStats.lastContainers or 0, known = 0, unknown = 0, skippedUnknown = 0 }
        if engine and engine.Containers then
            stack.skippedUnknown = engine.Containers.stackLimitUnknown or 0
        end
        local now = Util.now()
        if not current.stackScanCache or now - (current.stackScanCache.at or 0) > 2000 then
            for _, target in ipairs(containers:stackScanTargets()) do
                local status = containers:stackScanStatusFromSnapshot(target.container)
                stack.known = stack.known + (status.known or 0)
                stack.unknown = stack.unknown + (status.unknown or 0)
            end
            current.stackScanCache = { at = now, known = stack.known, unknown = stack.unknown }
        else
            stack.known = current.stackScanCache.known or 0
            stack.unknown = current.stackScanCache.unknown or 0
        end
        current.stackScan = stack
    end
    if transfer then
        current.transfer = transfer:status()
    end
    current.schedule = store:scheduleSettings()
    -- Stock keeping targets ("kind:name" -> amount), read by the resource panel to
    -- draw the maintenance number next to each craftable material.
    current.keepStock = store:keepSettings()
    if dispatch then
        current.dispatch = dispatch:status()
    end
    return current
end

local SET_KINDS = {
    set_container = "containers",
    set_signal = "signals",
    set_filter = "filters",
    set_machine_type = "machineTypes",
    set_machine = "machines",
    set_process = "processes",
}

local DELETE_KINDS = {
    delete_container = "containers",
    delete_signal = "signals",
    delete_filter = "filters",
    delete_machine_type = "machineTypes",
    delete_machine = "machines",
    delete_process = "processes",
}

local function handleSendItems(payload)
    local containerName = payload.container
    local container = store:get("containers", containerName)
    if not container then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_NOT_FOUND,
            { name = tostring(containerName) }) }
    end
    if container.role ~= "output" then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_OUTPUT_ONLY) }
    end
    local items = payload.items or {}
    if #items == 0 then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_SEND_LIST_EMPTY) }
    end
    local results = {}
    for _, item in ipairs(items) do
        local kind = item.kind
        local name = item.name
        local nbt = item.nbt
        if type(nbt) == "string" and nbt == "" then
            nbt = nil
        end
        local count = math.max(1, math.floor(tonumber(item.count) or 1))
        if not kind or not name then
            results[#results + 1] = { name = tostring(name),
                error = Message.msg(Message.KEYS.MASTER_ERR_RESOURCE_INFO_MISSING) }
        else
            local target = store:findContainer(containerName, kind)
            if not target or (kind ~= "filter" and target.kind ~= Util.kindOfDef(kind)) then
                results[#results + 1] = {
                    kind = kind,
                    name = name,
                    error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_KIND, {
                        name = tostring(containerName),
                        kind = Message.msg(kind == "fluid"
                            and Message.KEYS.COMMON_FLUID or Message.KEYS.COMMON_ITEM),
                    }),
                }
            else
                local available = engine:storageCount(kind, name, nbt)
                local producers = engine:producers(kind, name)
                local ok, info
                if available < count and #producers > 0 then
                    ok, info = engine:craftAndSend(kind, name, count, containerName, nbt)
                else
                    ok, info = engine:queueSend(kind, name, count, containerName, nbt)
                end
                if ok then
                    results[#results + 1] = {
                        kind = kind,
                        name = name,
                        nbt = nbt,
                        count = count,
                        queued = true,
                        craft = info and info.process or nil,
                    }
                else
                    results[#results + 1] = { kind = kind, name = name, nbt = nbt, error = tostring(info) }
                end
            end
        end
    end
    return { results = results }
end

-- The container tool resolves definitions by peripheral name first: the peripheral
-- is stable, while a definition's name changes with its role (non-output roles
-- derive the name from the peripheral, output containers use a custom name) and
-- existing machine/process references are not rewritten when that happens.
local function containerCandidates(needle)
    local wanted = Util.trim(tostring(needle or ""))
    if wanted == "" then
        return ""
    end
    local parts = {}
    for _, def in ipairs(store:list("containers")) do
        local name = tostring(def.name or "")
        local peripheral = tostring(def.peripheral or "")
        local hit = name == wanted or peripheral == wanted
            or string.find(name, wanted, 1, true) ~= nil
            or string.find(peripheral, wanted, 1, true) ~= nil
            or string.find(wanted, name, 1, true) ~= nil
            or string.find(wanted, peripheral, 1, true) ~= nil
        if hit then
            parts[#parts + 1] = string.format("%s:%s(peripheral=%s)", Util.kindOfDef(def), name, peripheral)
            if #parts >= 8 then
                break
            end
        end
    end
    return table.concat(parts, ", ")
end

local function findContainerByPayload(payload)
    local asked = Util.kindOfDef(payload)
    local peripheral = type(payload.peripheral) == "string" and payload.peripheral or nil
    local def = nil
    if peripheral and peripheral ~= "" then
        def = store:findContainer(peripheral, asked) or store:findContainer(peripheral)
            or store:findContainerByPeripheral(peripheral, asked)
            or store:findContainerByPeripheral(peripheral)
    end
    if not def then
        def = store:findContainer(payload.name, asked) or store:findContainer(payload.name)
    end
    if not def then
        log("container lookup FAILED: name=%s kind=%s key=%s peripheral=%s | candidates: %s",
            tostring(payload.name), tostring(payload.kind), tostring(payload.key), tostring(payload.peripheral),
            containerCandidates(peripheral or payload.name))
        return nil, asked
    end
    return def, Util.kindOfDef(def)
end

-- Result of the last finished manual move (the container tool shows it). A
-- manual move runs exactly once: no retry on failure, so this is the only
-- feedback the operator gets besides the log.
local manualLast = nil

local function containerView(payload)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_DEF_MISSING) }
    end
    local usable = containers:supports(def.name, kind)
    local problem = nil
    if not usable then
        problem = containers:unusableReason(def.name, kind)
    elseif def.peripheral and not containers:snapshotComplete(def.peripheral, kind) then
        -- The hardware can do it, but its snapshot is not complete yet: nothing can be
        -- moved until the scan instructions (list / size) have all come back.
        problem = Message.msg(Message.KEYS.CONT_ERR_SCANNING,
            { name = def.name, peripheral = def.peripheral })
    end
    containers:watchContainer(def.name, kind)
    -- The tool is looking at this container: it has to be scanned even while no process
    -- instance uses its machine yet, otherwise a freshly added container has no slot
    -- count and the tool cannot draw its slot grid.
    containers:noteView(def.peripheral)
    local out = {
        name = def.name,
        kind = kind,
        role = def.role,
        peripheral = def.peripheral,
        usable = usable,
        problem = problem,
        items = {},
        fluids = {},
        claims = containers:claimView(def.name, kind),
        manual = manualLast and manualLast.container == def.name and manualLast or nil,
    }
    if kind == "item" then
        for _, stack in ipairs(containers:stacks(def.name)) do
            out.items[#out.items + 1] = {
                slot = stack.slot,
                name = stack.name,
                count = stack.count,
                nbt = stack.nbt,
            }
        end
        if usable then
            out.slots = containers:slotCount(def.peripheral)
        end
        -- Per-slot capacity multiplier for the container tool: what the master
        -- currently believes about every slot (including empty ones), plus the user
        -- override so the tool can show/edit it.
        local total = math.floor(tonumber(out.slots) or 0)
        out.slotMultiplierDefault = containers:slotMultiplierDefaultOf(def.peripheral)
        out.slotScanned = containers:isScannedMod(def.peripheral)
            and containers:slotMultiplierDefaultOf(def.peripheral) == nil
        if total > 0 then
            local slotInfo = {}
            for slot = 1, total do
                local info = containers:slotCapacityInfo(def.peripheral, slot)
                slotInfo[#slotInfo + 1] = {
                    slot = slot,
                    multiplier = info and info.multiplier or nil,
                    limit = info and info.limit or nil,
                    item = info and info.item or nil,
                    override = info and info.override or nil,
                }
            end
            out.slotInfo = slotInfo
        end
    else
        for _, tank in ipairs(containers:tanks(def.name)) do
            out.fluids[#out.fluids + 1] = {
                tank = tank.tank,
                name = tank.name,
                amount = tank.amount,
            }
        end
    end
    return out
end

local manualSeq = 0

-- A manual put with an explicit slot may only land on an empty slot or on a
-- stack of the very same item that still has room left; anything else is
-- rejected with a message naming the slot.
local function manualSlotAccepts(containerName, slot, item, amount)
    local stack = containers:stackAt(containerName, slot)
    if not stack or not stack.name then
        return true
    end
    local sameItem = stack.name == item.name
        and (item.nbt == nil or item.nbt == "" or stack.nbt == item.nbt)
    if not sameItem then
        return false, Message.msg(Message.KEYS.CONT_ERR_TARGET_SLOT_BUSY, {
            peripheral = tostring(containerName),
            slot = slot,
            item = tostring(stack.name),
        })
    end
    local cap = tonumber(containers:itemMaxCount(item.name, stack.nbt)) or 64
    if (tonumber(stack.count) or 0) + math.max(1, math.floor(tonumber(amount) or 1)) > cap then
        return false, Message.msg(Message.KEYS.CONT_ERR_FULL, {
            container = tostring(containerName),
            occupied = tonumber(stack.count) or 0,
            item = tostring(item.name),
        })
    end
    return true
end

-- A manual move is submitted exactly once. The task then only waits for that one
-- move to settle: success, failure and timeout all finish the task - nothing is
-- retried, so a bad request can neither pile up behind a stuck task nor keep a
-- slot marked dirty forever.
local MANUAL_MOVE_TIMEOUT_MS = 10000

-- A candidate stack for a manual move: right item, right hash (an empty hash
-- means "any variant") and something actually in it.
local function manualStackMatches(stack, resource, nbt)
    if not stack or not stack.name or stack.name ~= resource then
        return false
    end
    if nbt and nbt ~= "" and (stack.nbt or "") ~= nbt then
        return false
    end
    return (tonumber(stack.count) or 0) > 0
end

local function manualFinish(task, ok, reason, moved)
    task.ok = ok
    task.moved = math.max(0, math.floor(tonumber(moved) or 0))
    task.reason = reason
    task.finishedAt = os.epoch("utc")
    manualLast = {
        key = task.key,
        container = task.container,
        dir = task.dir,
        kind = task.kind,
        resource = task.resource,
        slot = task.slot,
        nbt = task.nbt,
        moved = task.moved,
        ok = ok,
        reason = reason and Message.describe(reason) or nil,
        at = task.finishedAt,
    }
    if ok then
        log("Manual container %s %s %s x%s done (moved %s)", tostring(task.container),
            tostring(task.dir), tostring(task.resource), tostring(task.remaining),
            tostring(task.moved))
    else
        log("Manual container %s %s %s x%s failed: %s", tostring(task.container),
            tostring(task.dir), tostring(task.resource), tostring(task.remaining),
            Message.describe(reason or "nothing moved"))
    end
    return false
end

local function runManualTask(task, now)
    local def = store:findContainer(task.container, task.kind)
    if not def then
        log("Manual move dropped: container %s is gone", tostring(task.container))
        return false
    end
    if task.pendingKey then
        -- The move was already submitted (exactly once): only wait for it.
        local result = containers:takeMoveResult(task.pendingKey)
        if result then
            local moved = math.floor(tonumber(result.moved) or 0)
            if result.err then
                return manualFinish(task, moved > 0, result.err, moved)
            end
            if moved <= 0 then
                return manualFinish(task, false, Message.msg(Message.KEYS.MASTER_ERR_MOVE_NOTHING), 0)
            end
            return manualFinish(task, true, nil, moved)
        end
        if now - (task.pendingAt or now) < MANUAL_MOVE_TIMEOUT_MS then
            return "pending"
        end
        -- Timed out: release the slot marks so the container stays usable.
        local record = containers.moveInflight and containers.moveInflight[task.pendingKey]
        if record then
            containers:abandonMove(record)
        end
        return manualFinish(task, false, Message.msg(Message.KEYS.MASTER_ERR_MANUAL_TIMEOUT,
            { seconds = math.floor(MANUAL_MOVE_TIMEOUT_MS / 1000) }), 0)
    end
    local kind = task.kind
    local resource = task.resource
    local entries = task.entries
    -- The candidate list is built once: a manual move never rescans and retries.
    if not task.entries then
        entries = {}
        if task.dir == "out" then
            if kind == "item" and task.slot then
                -- The take button named the slot: pull from exactly that one.
                local stack = containers:stackAt(def.name, task.slot)
                if manualStackMatches(stack, resource, task.nbt) then
                    entries[#entries + 1] = { ref = task.slot, amount = tonumber(stack.count) or 0,
                        nbt = stack.nbt }
                end
            elseif kind == "item" then
                for _, stack in ipairs(containers:stacks(def.name)) do
                    if manualStackMatches(stack, resource, task.nbt) then
                        entries[#entries + 1] = { ref = stack.slot, amount = tonumber(stack.count) or 0,
                            nbt = stack.nbt }
                    end
                end
            else
                for _, tank in ipairs(containers:tanks(def.name)) do
                    if tank.name == resource then
                        entries[#entries + 1] = { ref = tank.tank, amount = tonumber(tank.amount) or 0 }
                    end
                end
            end
            task.targets = task.targets or containers:byRole("storage", kind, "out")
        else
            task.targets = task.targets or containers:byRole("storage", kind, "in")
            for _, source in ipairs(task.targets) do
                if kind == "item" then
                    for _, stack in ipairs(containers:stacks(source)) do
                        if manualStackMatches(stack, resource, task.nbt) then
                            entries[#entries + 1] = { ref = stack.slot, amount = tonumber(stack.count) or 0,
                                source = source, nbt = stack.nbt }
                        end
                    end
                else
                    for _, tank in ipairs(containers:tanks(source)) do
                        if tank.name == resource then
                            entries[#entries + 1] = { ref = tank.tank, amount = tonumber(tank.amount) or 0,
                                source = source }
                        end
                    end
                end
            end
        end
        task.entries = entries
        task.listedAt = now
        task.index = 1
    end
    local remaining = math.max(0, tonumber(task.remaining) or 0)
    if remaining <= 0 then
        return manualFinish(task, true, nil, 0)
    end
    local targets = task.targets or {}
    if #targets == 0 then
        return manualFinish(task, false, Message.msg(Message.KEYS.MASTER_ERR_NO_STORAGE), 0)
    end
    local entry = entries[task.index or 1]
    if not entry then
        return manualFinish(task, false, Message.msg(Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE, {
            container = tostring(def.name),
            item = tostring(resource),
        }), 0)
    end
    local from = entry.source or def.name
    local amount = math.min(remaining, entry.amount)
    local moveRes
    if kind == "item" then
        local item = { name = resource, nbt = entry.nbt or task.nbt }
        local to, toSlot, why
        if task.dir == "in" and task.slot then
            -- The put button named the target slot: it has to be empty or hold
            -- the same item with room left, otherwise this task fails right here.
            to = def.name
            toSlot = task.slot
            local accepts, acceptWhy = manualSlotAccepts(def.name, toSlot, item, amount)
            if not accepts then
                return manualFinish(task, false, acceptWhy, 0)
            end
        elseif task.dir == "in" then
            to = def.name
            toSlot, why = containers:pickTargetSlot(to, item, amount)
            if not toSlot then
                return manualFinish(task, false,
                    why or Message.msg(Message.KEYS.RECIPE_ERR_NO_TARGET_SLOT), 0)
            end
        else
            for _, target in ipairs(targets) do
                local slot, slotWhy = containers:pickTargetSlot(target, item, amount)
                if slot then
                    to, toSlot = target, slot
                    break
                end
                why = why or slotWhy
            end
            if not to then
                return manualFinish(task, false,
                    why or Message.msg(Message.KEYS.RECIPE_ERR_NO_TARGET_SLOT), 0)
            end
        end
        local moveKey, moveErr
        if task.dir == "out" then
            moveKey, moveErr = containers:takeItem(from, entry.ref, to, toSlot, item, amount, "manual")
        else
            moveKey, moveErr = containers:sendItem(from, entry.ref, to, toSlot, item, amount, "manual")
        end
        if not moveKey then
            return manualFinish(task, false, moveErr, 0)
        end
        moveRes = moveKey
    else
        local to = (task.dir == "out") and targets[1] or def.name
        local moveKey, moveErr
        if task.dir == "out" then
            moveKey, moveErr = containers:takeFluid(from, to, resource, amount, "manual")
        else
            moveKey, moveErr = containers:sendFluid(from, to, resource, amount, "manual")
        end
        if not moveKey then
            return manualFinish(task, false, moveErr, 0)
        end
        moveRes = moveKey
    end
    -- One submission, then only the wait.
    task.pendingKey = moveRes
    task.pendingAt = now
    log("Manual container %s %s %s x%s submitted once (key=%s)", tostring(def.name),
        tostring(task.dir), tostring(resource), tostring(amount), tostring(moveRes))
    return "pending"
end

local function containerMove(payload, dir)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_DEF_MISSING) }
    end
    if not containers:supports(def.name, kind) then
        return { error = containers:unusableReason(def.name, kind)
            or Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_UNUSABLE) }
    end
    local resource = tostring(payload.resource or "")
    if resource == "" then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_PICK_RESOURCE) }
    end
    -- Manual moves are part of the web container tool: keep the container
    -- watched while the operator works with it.
    containers:watchContainer(def.name, kind)
    local count = math.max(1, tonumber(payload.count) or 1)
    -- The web tool sends the slot of the button that was clicked: for a "put" it
    -- is the slot inside this container, for a "take" the slot the item is taken
    -- from. Fluids ignore it (their buttons never send one).
    local slot = math.floor(tonumber(payload.slot) or 0)
    if slot < 1 then
        slot = nil
    end
    -- Optional NBT hash: empty means "any variant of that item".
    local nbt = tostring(payload.nbt or "")
    if nbt == "" then
        nbt = nil
    end
    local targets = containers:byRole("storage", kind, dir == "out" and "out" or "in")
    if #targets == 0 then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_NO_STORAGE) }
    end
    manualSeq = manualSeq + 1
    local task = {
        key = "manual:" .. tostring(manualSeq),
        dir = dir,
        container = def.name,
        kind = kind,
        resource = resource,
        slot = slot,
        nbt = nbt,
        remaining = count,
        moved = 0,
        targets = targets,
    }
    -- The manual queue only runs when a mover is available. Enqueuing into a
    -- queue that cannot run would leave the task pending forever with no
    -- feedback, so that case is reported right away instead.
    local queue = dispatch and dispatch.queues and dispatch.queues["manual"]
    if queue and not dispatch:runnable(queue, dispatch:mode()) then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_MANUAL_NO_WORKER) }
    end
    if not dispatch or not dispatch:enqueue("manual", task) then
        return { error = Message.msg(Message.KEYS.MASTER_ERR_DISPATCH_UNAVAILABLE) }
    end
    log("Manual container %s %s %s x%s queued (manual queue)", tostring(def.name), tostring(dir),
        tostring(resource), tostring(count))
    return { success = true, queued = true, moved = 0 }
end

local function forgetRemovedContainers(reason)
    local dropped = containers:pruneMissingPeripherals(reason)
    if dropped > 0 then
        protocol:expediteDeletions()
        cache:markDirty()
    end
    return dropped
end

local lastClientVersion = nil

local recentRequests = {}
local REQUEST_DEDUPE_MS = 10000
local requestStats = { duplicates = 0 }

-- Data files: the browser may download and overwrite the json files in the data
-- directory. cache.json is excluded on purpose (the runtime state is rebuilt by
-- the master itself, and half-written cache would only poison the next start).
local DATA_FILE_EXCLUDED = { ["cache.json"] = true }
local DATA_FILE_CHUNK_BYTES = 8192
local DATA_FILE_CHUNK_CHARS = DATA_FILE_CHUNK_BYTES * 2

local function dataFileNames()
    local names = {}
    if not fs.exists(dataDir) then
        return names
    end
    for _, name in ipairs(fs.list(dataDir)) do
        if type(name) == "string" and name:sub(-5) == ".json" and not DATA_FILE_EXCLUDED[name]
            and not name:find("[\\/]") and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

-- Only the files this directory really offers are reachable: no path escapes.
local function dataFilePath(name)
    local wanted = tostring(name or "")
    for _, known in ipairs(dataFileNames()) do
        if known == wanted then
            return fs.combine(dataDir, known)
        end
    end
    return nil
end

-- The body travels as hex: a protocol frame is size capped and its text fields
-- are escape-decoded, and a config.json may well contain literal \uXXXX
-- sequences - plain ASCII hex survives both untouched.
local function toHex(text)
    return (string.gsub(text, ".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function fromHex(text)
    return (string.gsub(tostring(text or ""), "%x%x", function(pair)
        return string.char(tonumber(pair, 16))
    end))
end

local function handleRequestInner(payload)
    local action = payload.action
    if type(payload.version) == "string" and payload.version ~= "" and payload.version ~= lastClientVersion then
        lastClientVersion = payload.version
        if payload.version ~= IFM_VERSION then
            log.warn("Client version mismatch: client=%s server=%s (the browser will show a warning)",
                payload.version, IFM_VERSION)
        end
    end
    if action == "ping" or action == "heartbeat" then
        return { status = "alive" }
    end
    log("request: %s id=%s", tostring(action), tostring(payload.id))
    if action == "save" then
        store:markDirty()
        cache:markDirty()
        return { success = true, queued = true }
    elseif action == "get_definitions" then
        return collectSnapshot()
    elseif action == "scan_tags" then
        local queued = queueTagScan()
        return { success = true, queued = queued }
    elseif action == "clear_tags" then
        cache:clearTags()
        cache:markDirty()
        return { success = true }
    elseif action == "compact_storage" then
        log("compact_storage is gone (1.8.0): storage compaction runs automatically when the compact queue is empty")
        return { success = false, error = "storage compaction is automatic now (see the compact queue in the scheduler panel)" }
    elseif action == "set_schedule_settings" then
        local slices = type(payload.slices) == "table" and payload.slices or nil
        if not slices then
            return { error = "slices must be a table of { queue = weight 0.01..1-0.01n }" }
        end
        local normalized = Store.normalizeSlices(slices)
        local data = { slices = normalized }
        if payload.sendLog ~= nil then
            data.sendLog = payload.sendLog == true
        end
        if payload.compactFreeRatio ~= nil then
            local ratio = tonumber(payload.compactFreeRatio)
            if not ratio then
                return { error = "compactFreeRatio must be a number between 0 and 1" }
            end
            if ratio < 0 then
                ratio = 0
            elseif ratio > 1 then
                ratio = 1
            end
            data.compactFreeRatio = ratio
        end
        local ok, err = store:patchSettings(Store.SCHEDULE_NAME, data, { force = true })
        if not ok then
            log("Save schedule settings failed: %s", tostring(err))
            return { error = err }
        end
        local applied = store:scheduleSettings()
        if dispatch then
            dispatch:applySlices(applied.slices)
        end
        if protocol then
            protocol:setSendLog(applied.sendLog)
        end
        if engine and engine.setCompactFreeRatio then
            engine:setCompactFreeRatio(applied.compactFreeRatio)
        end
        store:markDirty()
        local parts = {}
        for _, queue in ipairs(applied.queues) do
            parts[#parts + 1] = queue .. "=" .. tostring(applied.slices[queue])
        end
        log("Schedule slices updated: %s", table.concat(parts, " "))
        return { success = true, schedule = applied }
    elseif action == "set_slot_multiplier" then
        -- User-set slot capacity multiplier: one slot (slot = n) or every slot of the
        -- container (all = true, through the container-wide default). An empty/0 amount
        -- clears that setting; the container then falls back to the mod whitelist scan
        -- or the 1x default. A user-set value always wins over the scan.
        local name = tostring(payload.name or "")
        local kind = tostring(payload.kind or "")
        local def = name ~= "" and store:findContainer(name, kind ~= "" and kind or nil) or nil
        if not def then
            return { error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_DEF_MISSING) }
        end
        local data = {}
        for key, value in pairs(def) do
            data[key] = value
        end
        local amount = tonumber(payload.amount)
        if amount ~= nil and amount <= 0 then
            amount = nil
        end
        if amount ~= nil and amount > 4096 then
            return { error = "multiplier must be <= 4096" }
        end
        if payload.all == true then
            data.slotMultiplierDefault = amount
            if payload.clearPerSlot ~= false then
                data.slotMultipliers = nil
            end
        else
            local slot = math.floor(tonumber(payload.slot) or 0)
            if slot < 1 then
                return { error = "slot must be >= 1, or pass all=true" }
            end
            local map = {}
            if type(data.slotMultipliers) == "table" then
                for key, value in pairs(data.slotMultipliers) do
                    map[key] = value
                end
            end
            map[tostring(slot)] = amount
            if next(map) == nil then
                map = nil
            end
            data.slotMultipliers = map
        end
        local ok, err = store:set("containers", def.name, data)
        if not ok then
            return { error = err }
        end
        store:markDirty()
        if def.peripheral and def.peripheral ~= "" then
            containers:refreshSlotMultipliers(def.peripheral)
        end
        if payload.all == true then
            log("Slot multipliers of %s: all -> %s", tostring(def.name), tostring(amount))
        else
            log("Slot multiplier of %s: slot %s -> %s", tostring(def.name),
                tostring(payload.slot), tostring(amount))
        end
        return { success = true }
    elseif action == "set_keep_stock" then
        -- Stock keeping: the resource panel sets (or clears, amount 0) the target
        -- amount of one craftable material. Placeholder is allowed too: it has no real
        -- stock, so the target is kept as a rolling demand on the material ledger
        -- (see Recipe:maintainKeepStock) which keeps the producing process running.
        local kind = tostring(payload.kind or "")
        local name = tostring(payload.name or "")
        if kind ~= "item" and kind ~= "fluid" and kind ~= "filter" and kind ~= "placeholder" then
            return { error = "kind must be item, fluid, filter or placeholder" }
        end
        if name == "" then
            return { error = "name is required" }
        end
        local amount = math.floor(tonumber(payload.amount) or 0)
        local ok, keep = store:setKeepStock(kind .. ":" .. name, amount)
        if not ok then
            return { error = keep }
        end
        local targets = 0
        for _ in pairs(keep) do
            targets = targets + 1
        end
        log("Keep stock %s:%s -> %d (%d target(s))", kind, name, amount, targets)
        return { success = true, keep = keep }
    elseif action == "remove_machine_peripheral" then
        local peripheral = tostring(payload.peripheral or payload.name or "")
        local removed = 0
        if peripheral ~= "" then
            for _, machine in ipairs(store:list("machines")) do
                if machine.virtual ~= true then
                    local data = {}
                    for key, value in pairs(machine) do
                        data[key] = value
                    end
                    local changed = false
                    for _, listKey in ipairs({ "itemInputs", "fluidInputs", "itemOutputs", "fluidOutputs" }) do
                        local kept = {}
                        for _, name in ipairs(machine[listKey] or {}) do
                            if tostring(name) == peripheral then
                                changed = true
                            else
                                kept[#kept + 1] = name
                            end
                        end
                        data[listKey] = kept
                    end
                    local keptSignals = {}
                    for _, signal in ipairs(machine.signals or {}) do
                        local signalName = type(signal) == "table" and tostring(signal.peripheral or "")
                            or tostring(signal)
                        if signalName == peripheral then
                            changed = true
                        else
                            keptSignals[#keptSignals + 1] = signal
                        end
                    end
                    data.signals = keptSignals
                    if changed then
                        local ok, err = store:set("machines", machine.name, data)
                        if ok then
                            removed = removed + 1
                        else
                            log.error("remove_machine_peripheral: %s failed: %s", tostring(machine.name),
                                tostring(err))
                        end
                    end
                end
            end
        end
        if removed > 0 then
            store:markDirty()
            cache:markDirty()
            log("remove_machine_peripheral: %s removed from %d machine(s)", tostring(peripheral), removed)
        end
        return { success = true, removed = removed, peripheral = peripheral }
    elseif action == "container_view" then
        return containerView(payload)
    elseif action == "container_take" then
        return containerMove(payload, "out")
    elseif action == "container_put" then
        return containerMove(payload, "in")
    elseif action == "diagnose" then
        local mode = tostring(payload.mode or "report")
        local lines
        if mode == "move" then
            lines = diagnose:moveProbe()
        elseif mode == "tick" then
            lines = diagnose:tickProbe()
        elseif mode == "perf" then
            lines = diagnose:perf()
        else
            lines = diagnose:report()
        end
        log("===== IFM diagnose begin (%s) =====", mode)
        for _, entry in ipairs(lines) do
            log("%s", entry)
        end
        log("===== IFM diagnose end =====")
        local DIAGNOSE_RESPONSE_LIMIT = Protocol.WS_LIMIT_BYTES - 2000
        local size, kept = 0, {}
        for _, entry in ipairs(lines) do
            local line = tostring(entry)
            if size + #line + 4 > DIAGNOSE_RESPONSE_LIMIT then
                break
            end
            size = size + #line + 4
            kept[#kept + 1] = entry
        end
        local response = { success = true, mode = mode, count = #lines }
        if #kept == #lines then
            response.lines = lines
        else
            kept[#kept + 1] = string.format(
                "!! response truncated: only the first %d of %d line(s) are in this response " ..
                "(the full report went out over the log channel; enable 'send logs to the web' " ..
                "if you cannot see it)", #kept, #lines)
            response.lines = kept
            response.truncated = true
        end
        return response
    end
    local setKind = SET_KINDS[action]
    if setKind then
        local name = payload.name
        local data = payload.data or payload
        if store:virtualOf(setKind)[name] then
            return { error = Message.msg(Message.KEYS.MASTER_ERR_VIRTUAL_READONLY) }
        end
        if setKind == "containers" then
            if data.kind ~= nil and data.kind ~= "item" and data.kind ~= "fluid" then
                return { error = Message.msg(Message.KEYS.MASTER_ERR_CONTAINER_KIND_BAD) }
            end
            local wantKind = Util.kindOfDef(data)
            local peripheralName = data.peripheral
            if peripheralName and peripheralName ~= "" and peripherals:exists(peripheralName) then
                local provides
                if wantKind == "fluid" then
                    provides = peripherals:isFluid(peripheralName)
                else
                    provides = peripherals:isInventory(peripheralName)
                end
                if not provides then
                    return { error = Message.msg(Message.KEYS.MASTER_ERR_PERIPHERAL_CAPABILITY, {
                        name = peripheralName,
                        kind = Message.msg(wantKind == "fluid"
                            and Message.KEYS.COMMON_FLUID_STORAGE or Message.KEYS.COMMON_ITEM_INVENTORY),
                    }) }
                end
            end
            -- The editor's payload does not carry the slot multipliers: keep whatever
            -- the container already has, so an editor save never wipes them.
            local existingDef = store:findContainer(name, data.kind)
            if existingDef then
                if data.slotMultiplierDefault == nil then
                    data.slotMultiplierDefault = existingDef.slotMultiplierDefault
                end
                if data.slotMultipliers == nil then
                    data.slotMultipliers = existingDef.slotMultipliers
                end
            end
        end
        local ok, err = store:set(setKind, name, data, { previous = payload.previous })
        if not ok then
            log.error("Save %s failed: %s", tostring(setKind), Message.describe(err))
            return { error = err }
        end
        log("Saved %s: %s", tostring(setKind), tostring(name))
        if setKind == "containers" then
            forgetRemovedContainers("container definition saved")
            -- The new/changed container must show up in the resource list right away:
            -- drop the cached storage snapshot so the next collection is rebuilt from
            -- the (re)scanned models instead of a stale one.
            containers:invalidate()
        end
        engine:reconcile()
        store:markDirty()
        return { success = true, kind = setKind, name = name }
    end
    local deleteKind = DELETE_KINDS[action]
    if deleteKind then
        if store:virtualOf(deleteKind)[payload.name] then
            return { error = Message.msg(Message.KEYS.MASTER_ERR_VIRTUAL_NO_DELETE) }
        end
        if not store:get(deleteKind, payload.name, payload.kind) then
            log("Delete %s %s: already gone (nothing to do)", tostring(deleteKind), tostring(payload.name))
            return { success = true, gone = true, kind = deleteKind, name = payload.name }
        end
        local ok, err = store:delete(deleteKind, payload.name, payload.kind, { force = payload.force == true })
        if not ok then
            return { error = err }
        end
        if deleteKind == "processes" then
            cache.data.processes[payload.name] = nil
            cache:dropActiveProcess(payload.name)
        elseif deleteKind == "machines" then
            cache.data.machines[payload.name] = nil
        elseif deleteKind == "machineTypes" then
            cache.data.machineTypes[payload.name] = nil
        elseif deleteKind == "containers" then
            forgetRemovedContainers("container definition deleted")
        end
        engine:reconcile()
        store:markDirty()
        cache:markDirty()
        return { success = true }
    end
    if action == "cancel_process" then
        local ok, info = engine:cancel(payload.name)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "cancel_instance" then
        local ok, info = engine:abortInstance(payload.name, payload.id)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "craft_resource" then
        local ok, info = engine:startResource(payload.kind, payload.name, payload.count, payload.process)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "send_items" then
        local result = handleSendItems(payload)
        cache:markDirty()
        store:markDirty()
        local queued, failed = 0, 0
        for _, entry in ipairs(result.results or {}) do
            if entry.error then
                failed = failed + 1
                log("send_items: %s %s FAILED: %s", tostring(entry.kind), tostring(entry.name), tostring(entry.error))
            else
                queued = queued + 1
                log("send_items: %s %s x%s queued (craft=%s)", tostring(entry.kind), tostring(entry.name),
                    tostring(entry.count), tostring(entry.craft))
            end
        end
        log("send_items -> container=%s queued=%d failed=%d", tostring(payload.container), queued, failed)
        return result
    elseif action == "worker_query" then
        if not (transfer and transfer.requestQuery) then
            return { error = "transfer module unavailable" }
        end
        local container = payload.container
        if type(container) ~= "string" or container == "" then
            return { error = "container is required (one container per query)" }
        end
        local names = nil
        if type(payload.names) == "table" then
            names = {}
            for _, value in ipairs(payload.names) do
                if type(value) == "string" and value ~= "" then
                    names[value] = true
                end
            end
        end
        local key = payload.key
        if type(key) ~= "string" or key == "" then
            key = "web:" .. container
        end
        local state, result = transfer:requestQuery({
            container = container,
            names = names,
            key = key,
        })
        if state == "done" then
            log("worker_query: served %s from the query cache", tostring(key))
            return { success = true, state = state, key = key, result = result }
        end
        if state == "local" then
            return { success = false, state = state, key = key, info = "no IFMWorker online for queries" }
        end
        return { success = true, state = state, key = key, info = "query sent to IFMWorker; see status.transfer.lastQuery" }
    elseif action == "delete_delivery" then
        local deliveryId = tonumber(payload.deliveryId or payload.id)
        local removed = cache:removeDelivery(deliveryId)
        cache:markDirty()
        return { success = true, removed = removed and true or false, id = deliveryId }
    elseif action == "delete_deliveries" then
        local removed = 0
        for _, delivery in ipairs(cache:deliveries()) do
            if cache:removeDelivery(delivery.id) then
                removed = removed + 1
            end
        end
        if engine.forgetPendingMovesWithPrefix then
            engine:forgetPendingMovesWithPrefix("delivery:")
        end
        cache:markDirty()
        return { success = true, removed = removed }
    elseif action == "list_data_files" then
        local files = {}
        for _, name in ipairs(dataFileNames()) do
            files[#files + 1] = { name = name, size = fs.getSize(fs.combine(dataDir, name)) or 0 }
        end
        return { success = true, files = files }
    elseif action == "data_file_read" then
        local name = tostring(payload.file or "")
        local path = dataFilePath(name)
        if not path then
            return { error = "unknown data file: " .. name }
        end
        local size = fs.getSize(path) or 0
        local offset = math.max(0, math.floor(tonumber(payload.offset) or 0))
        if offset > size then
            offset = size
        end
        local handle = fs.open(path, "r")
        if not handle then
            return { error = "cannot open " .. name }
        end
        handle.seek("set", offset)
        local chunk = handle.read(DATA_FILE_CHUNK_BYTES) or ""
        handle.close()
        local result = { success = true, file = name, size = size, offset = offset, hex = toHex(chunk) }
        if offset + #chunk < size then
            result.next = offset + #chunk
        end
        return result
    elseif action == "data_file_upload" then
        local name = tostring(payload.file or "")
        local path = dataFilePath(name)
        if not path then
            return { error = "unknown data file: " .. name }
        end
        local hex = tostring(payload.hex or "")
        if #hex > DATA_FILE_CHUNK_CHARS then
            return { error = "chunk too large (max " .. tostring(DATA_FILE_CHUNK_BYTES) .. " bytes)" }
        end
        local offset = math.max(0, math.floor(tonumber(payload.offset) or 0))
        local temp = path .. ".upload"
        if offset == 0 and fs.exists(temp) then
            fs.delete(temp)
        end
        local written = 0
        if fs.exists(temp) then
            written = fs.getSize(temp) or 0
        end
        if offset ~= written then
            return { error = "chunk out of order: expected offset " .. tostring(written) }
        end
        local bytes = fromHex(hex)
        local handle = fs.open(temp, "a")
        if not handle then
            return { error = "cannot open " .. name .. ".upload" }
        end
        handle.write(bytes)
        handle.close()
        if payload.done ~= true then
            return { success = true, file = name, offset = written + #bytes }
        end
        -- The whole file arrived. It has to parse before it replaces the live one,
        -- so a broken upload can never destroy the definitions on disk.
        local uploaded = fs.getSize(temp) or 0
        local readHandle = fs.open(temp, "r")
        local body = nil
        if readHandle then
            body = readHandle.readAll()
            readHandle.close()
        end
        if type(body) ~= "string" or type(textutils.unserializeJSON(body)) ~= "table" then
            fs.delete(temp)
            log.error("data_file_upload: %s rejected (not a JSON object)", name)
            return { error = name .. " is not a valid JSON object - the file was NOT replaced" }
        end
        if fs.exists(path) then
            fs.delete(path)
        end
        fs.move(temp, path)
        if name == "config.json" then
            local ok, why = store:load()
            if not ok then
                log.error("data_file_upload: config.json replaced (%d bytes) but reload failed: %s",
                    uploaded, Message.describe(why))
                return { success = true, file = name, size = uploaded, reloaded = false }
            end
            local applied = store:scheduleSettings()
            if dispatch then
                dispatch:applySlices(applied.slices)
            end
            if protocol then
                protocol:setSendLog(applied.sendLog)
                protocol:expediteDeletions()
            end
            if engine and engine.setCompactFreeRatio then
                engine:setCompactFreeRatio(applied.compactFreeRatio)
            end
            log("data_file_upload: config.json replaced (%d bytes) and reloaded", uploaded)
        else
            log("data_file_upload: %s replaced (%d bytes)", name, uploaded)
        end
        return { success = true, file = name, size = uploaded, reloaded = true }
    end
    return { error = Message.msg(Message.KEYS.MASTER_ERR_UNKNOWN_ACTION, { action = tostring(action) }) }
end

local function handleRequest(payload)
    local action = payload and payload.action
    local id = payload and payload.id
    if id == nil then
        return handleRequestInner(payload)
    end
    local now = Util.now()
    local key = tostring(action) .. "\1" .. tostring(payload.session or "-") .. "\1" .. tostring(id)
    local previous = recentRequests[key]
    if previous and now - (previous.at or 0) <= REQUEST_DEDUPE_MS then
        requestStats.duplicates = requestStats.duplicates + 1
        log.warn("Duplicate request ignored: %s id=%s - the same frame was delivered twice; " ..
            "replaying the previous response instead of running it again", tostring(action), tostring(id))
        return previous.response
    end
    local response = handleRequestInner(payload)
    recentRequests[key] = { at = now, response = response }
    for otherKey, entry in pairs(recentRequests) do
        if now - (entry.at or 0) > REQUEST_DEDUPE_MS then
            recentRequests[otherKey] = nil
        end
    end
    return response
end

protocol = Protocol.new({
    Util = Util,
    Assert = Assert,
    Message = Message,
    url = wsUrl,
    log = log,
    collect = collectSnapshot,
    onRequest = handleRequest,
    updateInterval = 2,
    revisionProvider = function()
        return cache.revision or 0
    end,
    reconnectInterval = 5,
    clientTimeout = 40,
})

transfer = Transfer.new({ log = log, Assert = Assert, Peripherals = peripherals, Modems = Modems,
    scanFreshMs = 1000 })
containers:setTransferProvider(transfer)
containers:setDetailProvider(transfer)
transfer:setContext({
    version = IFM_VERSION,
})

dispatch = Dispatch.new({ Assert = Assert, log = log, store = store, cache = cache, transfer = transfer, Queue = Queue })
containers:setDispatcher(dispatch)
engine:setDispatch(dispatch)
local scheduleSettings = store:scheduleSettings()
dispatch:applySlices(scheduleSettings.slices)
protocol:setSendLog(scheduleSettings.sendLog)
if engine and engine.setCompactFreeRatio then
    engine:setCompactFreeRatio(scheduleSettings.compactFreeRatio)
end

local function isInputContainer(peripheralName)
    for _, def in ipairs(store:list("containers")) do
        if def.peripheral == peripheralName then
            return def.role == "input"
        end
    end
    return false
end

local function scanKindOf(name)
    local fluidDef = store:findContainer(name, "fluid")
    if fluidDef and (fluidDef.kind or "item") == "fluid" then
        return "fluid"
    end
    return "item"
end

-- After the "items" snapshot is in, a container still needs two more instructions:
-- its size (once, until it answers) and the limit of every slot the master wants to
-- size. Both are single-call tasks of their own, so they never share a load slot with
-- the list() read.
local function queueSlotLimits()
    -- No per-call limit: every slot whose limit is still missing is asked for at once.
    -- How many of those instructions run is the slotLimit queue's business, not this
    -- function's.
    local pending = containers:takePendingLimits()
    for _, item in ipairs(pending) do
        dispatch:enqueue("slotLimit", {
            key = "limit:" .. tostring(item.peripheral) .. ":" .. tostring(item.slot),
            name = item.peripheral,
            slot = item.slot,
            kind = "item",
            part = "limit",
        })
    end
    return #pending
end

local function afterScan(name, now)
    -- Any inventory peripheral needs its size() read, whether or not it also is a fluid
    -- storage: scanKindOf() must not decide this - a dual peripheral is scanned as both
    -- kinds now, and its item side still needs the size instruction.
    if peripherals:isInventory(name) then
        local model = containers:modelOf(name)
        if model and not tonumber(model.size) then
            dispatch:enqueue("containerSize", { key = "size:" .. tostring(name), name = name,
                kind = "item", part = "size" })
        end
    end
    -- Every container role is detail-scanned now. Input containers used to be
    -- excluded, which left the items sitting in them unsized: their slot capacity
    -- multiplier never resolved, so the input drain could not take them out
    -- (takeItem refused with "scanning") and the slots stayed claimed in the
    -- container tool. A stack is still asked for only once (the detail cache and
    -- the in-flight marks dedupe the requests).
    queueMissingDetails()
    queueSlotLimits()
end

local scanFailStreak = {}
-- A peripheral that is not attached at all is reported once instead of every tick.
local scanSkipLogged = {}

local function noteScanFailure(name, reason)
    if type(name) ~= "string" or name == "" then
        return
    end
    local now = os.epoch("utc")
    local streak = scanFailStreak[name]
    if not streak or now - (streak.firstAt or 0) > 60000 then
        streak = { count = 0, firstAt = now }
        scanFailStreak[name] = streak
    end
    streak.count = streak.count + 1
    streak.lastReason = reason
    log("Container scan for %s failed (%s) - it will be retried next round", tostring(name),
        tostring(reason or "unknown"))
end

local function noteScanSuccess(name)
    if type(name) ~= "string" or name == "" then
        return
    end
    scanFailStreak[name] = nil
end

-- One single-call task: "size" reads inventory.size(), "limit" one getItemLimit(slot),
-- "tank" one getTank(slot). The reply is applied by transfer.onQueryResult.
local function partTaskRunner(task, now)
    local name = task.name
    if not peripherals:exists(name) then
        if type(name) == "string" and not scanSkipLogged[name] then
            scanSkipLogged[name] = true
            log.error("scan task %s of %s skipped: the peripheral is not attached" ..
                " (check the container's peripheral name)", tostring(task.part or "?"), tostring(name))
        end
        return "drop"
    end
    if type(name) == "string" then
        scanSkipLogged[name] = nil
    end
    local kind = task.kind or scanKindOf(name)
    local ts = containers:tickOf()
    local state, why
    if task.part == "size" then
        state, why = containers:scanContainer(name, kind, ts, "size")
    elseif task.part == "tank" then
        state, why = containers:scanFluid(name, ts, "tank", task.slot)
    else
        state, why = containers:scanSlotLimit(name, task.slot, ts)
    end
    if state == nil and why then
        log.error("scan task %s of %s rejected: %s", tostring(task.part), tostring(name),
            Message.describe(why))
        return "drop"
    end
    if state == "sent" or state == "pending" then
        return "inflight"
    end
    if state == "deferred" then
        -- No worker slot and no local slot right now: retry on the next tick instead
        -- of pretending the instruction was done.
        return "pending"
    end
    return true
end

local function scanTaskRunner(task, now)
    local name = task.name
    if not peripherals:exists(name) then
        if type(name) == "string" and not scanSkipLogged[name] then
            scanSkipLogged[name] = true
            log.error("scan of %s skipped: the peripheral is not attached" ..
                " (check the container's peripheral name)", tostring(name))
        end
        return "drop"
    end
    if type(name) == "string" then
        scanSkipLogged[name] = nil
    end
    local kind = task.kind or scanKindOf(name)
    local ts = containers:tickOf()
    local state, why
    if kind == "fluid" then
        state, why = containers:scanFluid(name, ts)
    else
        state, why = containers:scanItem(name, ts)
    end
    if not state then
        log.error("scan of %s rejected: %s", tostring(name), Message.describe(why))
        return "drop"
    end
    if state == "sent" or state == "pending" then
        -- The reply applies the snapshot and calls afterScan() itself.
        return "inflight"
    end
    if state == "deferred" then
        return "pending"
    end
    afterScan(name, now)
    return true
end
dispatch:addQueue("storageScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("inputScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("interactionScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("outputScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("containerSize", { needs = "query", policy = "drop", run = partTaskRunner })
dispatch:addQueue("slotLimit", { needs = "query", policy = "drop", run = partTaskRunner })

-- A delivery that still has items to send counts as "sending in progress" even
-- before its first move could be created: a target without a snapshot cannot
-- receive a move, so the inventoryOut queue alone is never a usable trigger.
local function sendTargetsOfDeliveries()
    local out = {}
    for _, delivery in ipairs(cache:deliveries()) do
        local containerName = delivery.container
        if type(containerName) == "string" and containerName ~= "" then
            local peripheralName = containers:peripheralOf(containerName, delivery.containerKind or delivery.kind)
            if peripheralName then
                out[peripheralName] = true
            end
        end
    end
    return out
end

local function maintainScanQueues()
    -- Containers referenced by a live instance: input/storage roles are scanned anyway,
    -- but an *output* container is normally only scanned while a delivery is on the way
    -- - and a move cannot be created before its snapshot exists. Feeding the same set
    -- into `sending` breaks that circle for a machine that is already running (its
    -- output container is scanned even before the first extraction move).
    local active = engine:activeInstanceContainers()
    local sending = sendTargetsOfDeliveries()
    for peripheralName in pairs(active) do
        sending[peripheralName] = true
    end
    local want = containers:scanQueueTargets({
        interaction = active,
        watched = containers:watchedPeripherals(),
        viewed = containers:viewedPeripherals(),
        reconcile = containers:reconcilePeripherals(),
        sendActive = dispatch:depth("inventoryOut") > 0,
        sending = sending,
    })
    for _, queueName in ipairs({ "storageScan", "inputScan", "interactionScan", "outputScan" }) do
        local keep = want[queueName] or {}
        for key, entry in pairs(keep) do
            dispatch:enqueue(queueName, { key = key, name = entry.name, kind = entry.kind },
                { ignoreInflight = true })
        end
        dispatch:removeWhere(queueName, function(task)
            return type(task) == "table" and task.key ~= nil and keep[task.key] == nil
        end)
    end
end

local function makeMoveRunner(queuePolicy)
    return function(task)
        local result = containers:executeMove(task)
        if result == "drop" or result == false or result == nil then
            return result
        end
        if type(task) == "table" and task.state == "inflight" then
            return "pending"
        end
        if result == true and queuePolicy == "drop" then
            containers:abandonMove(task)
        end
        return result
    end
end
dispatch:addQueue("inventoryIn", { needs = "move", policy = "drop", singleQueue = true, run = makeMoveRunner("drop") })
dispatch:addQueue("inventoryOut", { needs = "move", policy = "retry", run = makeMoveRunner("retry") })

-- A compact move is one concrete instruction of the current compact plan. If such an
-- instruction fails, the plan was built from a snapshot that no longer holds: the
-- whole compact queue is flushed (reservations released) and the plan is dropped so
-- the next plan is generated from a fresh snapshot.
local function clearCompactQueue(reason)
    local released = 0
    local removed = dispatch:removeWhere("compact", function(task)
        if type(task) == "table" and containers:abandonMove(task) then
            released = released + 1
        end
        return true
    end)
    engine:abortCompact(reason)
    if removed > 0 or released > 0 then
        log.warn("compact: cleared %d queued move(s) (%d reservation(s) released) - %s",
            removed, released, tostring(reason or "move failed"))
    end
    return removed
end

local function compactMoveRunner(task)
    local result = containers:executeMove(task)
    -- Terminal results are honoured FIRST, exactly like makeMoveRunner does for the
    -- inventory queues: false/nil = the move finished (or was settled elsewhere).
    -- Looking at task.state first would trap the element forever, because a settled
    -- move keeps its "inflight" mark, so it would be re-queued on every round without
    -- ever running again - and the queue (plus its reservations) would never be freed.
    if result == false or result == nil then
        return result
    end
    if result == true then
        -- Either the move is out at an executor waiting for its reply, or it made partial
        -- progress and the rest is being retried (some containers rate-limit a single
        -- move). Both come back for another round; the remainder shrinks every time, so
        -- this always terminates.
        return "pending"
    end
    if result == "drop" then
        -- A failure: either nothing moved at all, or the source changed outside while the
        -- move was running. Either way the plan was built from a snapshot that no longer
        -- holds, so it is dropped and rebuilt from a fresh one.
        containers:abandonMove(task)
        clearCompactQueue((type(task) == "table" and task.failReason)
            or "compact move failed (nothing could move)")
        return false
    end
    return result
end
dispatch:addQueue("compact", { needs = "move", policy = "drop", singleQueue = true, run = compactMoveRunner })
local function stackScanRunner(task)
    local name = task.container
    if not name then
        return "drop"
    end
    local peripheralName = containers:peripheralOf(name, "item")
    if not peripheralName or not peripherals:exists(peripheralName) then
        return "drop"
    end
    if containers:defRole(name, "item") ~= "storage" then
        return "drop"
    end
    local asked = containers:stackScanStep(name)
    stackScanStats.asked = (stackScanStats.asked or 0) + (tonumber(asked) or 0)
    return false
end
dispatch:addQueue("stackScan", { needs = "query", policy = "drop", singleQueue = true, run = stackScanRunner })

-- Item details of a virtual container (a turtle crafter that reports its own
-- inventory) cannot be read from here: the turtle is the only computer that can
-- tell the stack limit of an item that is not in storage yet. Ask it directly.
-- "Known but without maxCount" counts as missing too, otherwise a stale cache
-- entry (written by an earlier empty reply) would block the turtle path forever.
local virtualDetailWarned = false

-- Crafter item details are not scheduled as queue tasks: the instruction goes
-- straight out to the turtle crafter over the modem (fire and forget). This set only
-- remembers what is still unanswered, so the same sample is not asked for twice.
local crafterDetailPending = {}
local CRAFTER_DETAIL_PENDING_TTL = 10000

local function crafterDetailKeyOf(sample)
    return tostring(sample and sample.name or "") .. "\1" .. tostring(sample and sample.nbt or "")
end

local function crafterDetailInFlight(sample, now)
    local key = crafterDetailKeyOf(sample)
    local at = crafterDetailPending[key]
    if at == nil then
        return false
    end
    if now - at > CRAFTER_DETAIL_PENDING_TTL then
        crafterDetailPending[key] = nil
        return false
    end
    return true
end

local function isVirtualDetailContainer(containerName)
    local def = store and store.findContainer and store:findContainer(containerName, "item") or nil
    return type(def) == "table" and def.virtual == true
end

local function needsCrafterDetail(sample)
    if not isVirtualDetailContainer(sample.container) then
        return false
    end
    return containers:itemMaxCount(sample.name, sample.nbt) == nil
end

-- Ask the turtle crafter for one item detail right now. Deliberately NOT a queue
-- task: only the turtle can answer, so the instruction goes out immediately and the
-- reply arrives through transfer.onCrafterDetails.
local function requestCrafterDetail(sample)
    local now = os.epoch("utc")
    if crafterDetailInFlight(sample, now) then
        return "pending"
    end
    local state = transfer:requestCrafterDetails(sample.container, { sample })
    if state == "pending" then
        crafterDetailPending[crafterDetailKeyOf(sample)] = now
        return "pending"
    end
    if not virtualDetailWarned then
        virtualDetailWarned = true
        log("Crafter item details: %s has no answering turtle crafter (%s) - check that " ..
            "IFMCrafter.lua runs on that turtle and that both builds match",
            tostring(sample.container), tostring(state))
    end
    return state
end

-- One "detail not known yet" sample: a virtual container (turtle inventory) is asked
-- directly over the modem, everything else becomes a normal detail queue element.
enqueueDetail = function(container, slot, name, nbt)
    local sample = { container = container, slot = slot, name = name, nbt = nbt }
    if needsCrafterDetail(sample) then
        requestCrafterDetail(sample)
        return false
    end
    if not dispatch then
        return false
    end
    return dispatch:enqueue("detail", {
        key = detailQueueKey(name, nbt),
        sample = sample,
    })
end

-- One element = one instruction = one load: worker first, the master's own executor
-- otherwise (both go through transfer).
dispatch:addQueue("detail", {
    needs = "query", policy = "drop", singleQueue = true,
    run = function(task)
        local sample = task.sample
        if not sample or not sample.container or not sample.name then
            return "drop"
        end
        local _, known = containers:cachedItemDetail(sample.name, sample.nbt)
        if known then
            return false
        end
        if not peripherals:exists(sample.container) then
            return "drop"
        end
        if containers:requestItemDetails({ sample }) == "pending" then
            return "inflight"
        end
        -- No worker took the detail instruction: retry next round. The master no
        -- longer reads peripherals itself, so there is no local fallback here.
        return "pending"
    end,
})
dispatch:addQueue("manual", {
    needs = "move", policy = "drop", singleQueue = true,
    run = function(task, now)
        return runManualTask(task, now)
    end,
})

-- The storage-compact *plan* is NOT a dispatch queue any more: Recipe:compactPlanTick
-- generates it inline, before the scheduler runs (see masterTick). Only the resulting
-- concrete move tasks are executed, by the compact queue above.

-- The saved schedule was applied before the queues above existed (setSlice on a queue
-- that does not exist yet is skipped), so it is applied once more now that every queue
-- is registered. Without this the scan / size / limit queues would keep the default
-- weight until the user saved the schedule again.
dispatch:applySlices(scheduleSettings.slices)

local turtleSignature = nil
local function syncTurtleCrafters()
    local crafters = transfer and transfer.craftersForUi and transfer:craftersForUi() or {}
    local running = {}
    local parts = {}
    for _, crafter in ipairs(crafters) do
        if type(crafter.name) == "string" and crafter.name ~= "" then
            running[crafter.name] = crafter
            parts[#parts + 1] = crafter.name .. ":" .. tostring(crafter.version or "?")
        end
    end
    local turtles = peripherals:turtleNames()
    for _, name in ipairs(turtles) do
        parts[#parts + 1] = "turtle:" .. name
    end
    table.sort(parts)
    local signature = table.concat(parts, ",")
    if signature == turtleSignature then
        return
    end
    turtleSignature = signature
    for name in pairs(runningCrafters) do
        runningCrafters[name] = nil
    end
    for name in pairs(running) do
        runningCrafters[name] = true
    end
    -- Built-in virtual machine types (no peripheral): the turtle crafter and the
    -- explicit "type conversion" bridge, both (re)registered together because
    -- setVirtual replaces the whole bucket.
    store:setVirtual("machineTypes", {
        { name = Store.TURTLE_CRAFTER_TYPE },
        { name = Store.TYPE_CONVERSION_TYPE },
    })
    local containerDefs, machineDefs = {}, {}
    for _, name in ipairs(turtles) do
        if running[name] then
            containerDefs[#containerDefs + 1] = {
                name = name, peripheral = name, kind = "item", role = "interaction",
                priority = 0, virtual = true,
            }
            machineDefs[#machineDefs + 1] = {
                name = name, type = Store.TURTLE_CRAFTER_TYPE, virtual = true, parallel = 1,
                label = running[name].label or name,
                itemInputs = { name }, itemOutputs = { name },
            }
        end
    end
    store:setVirtual("containers", containerDefs)
    store:setVirtual("machines", machineDefs)
    log("turtle_crafter: %d turtle(s) visible, %d running IFMCrafter (auto machines), %d ignored (no crafter on them)",
        #turtles, #machineDefs, math.max(0, #turtles - #machineDefs))
end

dispatch:setMaintain(function(now)
    transfer:tick(now)
    syncTurtleCrafters()
    transfer:refreshCrafterReports(now)
    -- Slot limits asked for by the capacity readers are issued here as well, so they
    -- arrive even while no scan is running.
    queueSlotLimits()
end)

engine:setCraftProvider(function(spec)
    return transfer:requestCraft(spec)
end)

transfer.onCrafterInventory = function(name, items, at, size)
    containers:applyScan(name, items, nil, at, size, containers:tickOf())
end

-- Item details that only a turtle crafter could provide (its own inventory):
-- absorb them like worker details so the stack limit (maxCount) becomes known and
-- the product can finally be moved out of the turtle. The tags are only written
-- when the turtle actually reported them (never overwrite known tags with empty).
transfer.onCrafterDetails = function(name, entries)
    local batch = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" and
            type(entry.detail) == "table" then
            batch[#batch + 1] = { name = entry.name, nbt = entry.nbt, detail = entry.detail }
            if type(entry.detail.tags) == "table" then
                storeTags(entry.name, entry.detail)
            end
            detailScan.fromWorkers = (detailScan.fromWorkers or 0) + 1
            detailScan.scanned = (detailScan.scanned or 0) + 1
            crafterDetailPending[crafterDetailKeyOf(entry)] = nil
        end
    end
    if #batch == 0 then
        return 0
    end
    local taken = containers:absorbItemDetails(batch)
    if taken > 0 then
        log("Crafter item details: %d item type(s) from %s (stack limits learned)", taken,
            tostring(name))
    end
    return taken
end

local function finishScanInflight(name)
    -- Scan task keys are kind-qualified now ("item:<name>" / "fluid:<name>"), because a
    -- peripheral can be both an inventory and a fluid storage. Clear both candidates:
    -- the caller only knows the peripheral name.
    for _, kind in ipairs({ "item", "fluid" }) do
        local key = kind .. ":" .. tostring(name)
        dispatch:finishInflight("storageScan", key)
        dispatch:finishInflight("inputScan", key)
        dispatch:finishInflight("interactionScan", key)
        dispatch:finishInflight("outputScan", key)
    end
end

transfer.onQueryDropped = function(key, reason)
    containers:releaseMoveKey(key, reason)
    key = tostring(key or "")
    if key:match("^size:") then
        dispatch:finishInflight("containerSize", key)
        -- No reply at all (timeout, worker gone, peripheral missing): the container's
        -- slot count stays unknown, so its slot-capacity scan can never complete.
        log.error("Container %s: reading its slot count (size()) failed (%s) -" ..
            " the container stays unsized and storage compaction will keep waiting for it",
            tostring(key:match("^size:(.+)$")), tostring(reason or "no reason given"))
        return
    end
    if key:match("^limit:") then
        dispatch:finishInflight("slotLimit", key)
        local limitName, limitSlot = key:match("^limit:(.+):(%d+)$")
        if limitName and tostring(reason or ""):match("^worker reported") then
            -- A *reported* failure (the peripheral cannot answer) is final: remember the
            -- slot so it is not requested again (markLimitUnavailable logs it).
            containers:markLimitUnavailable(limitName, tonumber(limitSlot), reason)
        else
            -- A timeout / worker loss is not final, so the slot stays in the pending
            -- queue and is retried - but the reason must be visible in the log too.
            log.error("Container %s slot %s: reading its slot capacity (getItemLimit) failed (%s) -" ..
                " the slot stays unsized and storage compaction will keep waiting for it",
                tostring(limitName), tostring(limitSlot), tostring(reason or "no reason given"))
        end
        return
    end
    if key:match("^tanks:") or key:match("^tank:") then
        return
    end
    local name = key:match("^scan:(.+)$")
    if not name then
        return
    end
    finishScanInflight(name)
    noteScanFailure(name, reason)
end

transfer.onMovesDropped = function(keys, reason)
    local released = 0
    for _, key in ipairs(keys or {}) do
        if containers:releaseMoveKey(key, reason) then
            released = released + 1
        end
    end
    if released > 0 then
        log("Released %d dirty move(s): %s", released, tostring(reason))
    end
    return released
end

transfer.onQueryResult = function(_, key, message)
    key = tostring(key or "")
    local sizeName = key:match("^size:(.+)$")
    if sizeName then
        containers:applySize(sizeName, message.size)
        dispatch:finishInflight("containerSize", key)
        return
    end
    local limitName, limitSlot = key:match("^limit:(.+):(%d+)$")
    if limitName then
        local applied = containers:applySlotLimit(limitName, tonumber(limitSlot), message.limit)
        if not applied then
            -- Unusable answer (the peripheral reported no limit): stop asking for it.
            containers:clearPendingLimit(limitName, tonumber(limitSlot))
        end
        dispatch:finishInflight("slotLimit", key)
        return
    end
    local tanksName = key:match("^tanks:(.+)$")
    if tanksName then
        -- Go through beginScan like the item reply path does: it creates/updates the
        -- model (scans/ts bookkeeping), so a fluid storage reports a real snapshot
        -- instead of staying "still scanning" forever.
        containers:beginScan(tanksName, tonumber(message.at) or os.epoch("utc"), tonumber(message.ts))
        containers:applyTanks(tanksName, message.tanks)
        finishScanInflight(tanksName)
        afterScan(tanksName, os.epoch("utc"))
        return
    end
    local tankName, tankSlot = key:match("^tank:(.+):(%d+)$")
    if tankName then
        local data = message.tankData
        if type(data) == "table" then
            -- Rebuild the whole tank list from the last good scan plus this one tank,
            -- through the encapsulated accessor (never the raw model).
            local tanks = containers:tanksPeripheral(tankName)
            tanks[#tanks + 1] = { tank = tonumber(tankSlot), name = data.name, amount = data.amount }
            containers:beginScan(tankName, tonumber(message.at) or os.epoch("utc"), tonumber(message.ts))
            containers:applyTanks(tankName, tanks)
        end
        finishScanInflight(tankName)
        return
    end
    local name = key:match("^scan:(.+)$")
    if not name then
        return
    end
    noteScanSuccess(name)
    local scanned = Containers.scanCountOfReply(message)
    if scanned == nil then
        containers:noteScanProtocolMismatch(name, "reply has neither scanned nor scannedContainers")
        finishScanInflight(name)
        return
    end
    if scanned < 1 then
        -- No fallback: a container that reports nothing really holds nothing.
        log("Scan of %s reported no containers - its snapshot is cleared (no stale stock kept)",
            tostring(name))
        containers:applyScan(name, {}, {}, tonumber(message.at) or os.epoch("utc"), nil,
            tonumber(message.ts))
        finishScanInflight(name)
        afterScan(name, os.epoch("utc"))
        return
    end
    containers:applyScan(name, message.items, message.tanks, tonumber(message.at) or os.epoch("utc"), nil,
        tonumber(message.ts))
    finishScanInflight(name)
    afterScan(name, os.epoch("utc"))
end

transfer.onDetailResult = function(_, message)
    for _, entry in ipairs(type(message.details) == "table" and message.details or {}) do
        if type(entry) == "table" and entry.name then
            dispatch:finishInflight("detail", detailQueueKey(entry.name, entry.nbt))
        end
    end
end

-- Detail requests settle through the same instruction flow as every other
-- request: on reply and on timeout alike, the in-flight marks are cleared here.
transfer.onDetailSettled = function(request, reason)
    containers:noteDetailSettled(request)
    -- Crafter detail requests settle here too (reply or timeout): drop their
    -- in-flight mark so the turtle can be asked again for that item.
    for _, sample in ipairs((request or {}).samples or {}) do
        crafterDetailPending[crafterDetailKeyOf(sample)] = nil
    end
    if reason then
        for _, sample in ipairs((request or {}).samples or {}) do
            -- The detail could not be read (worker failure or timeout): its stack size
            -- stays unknown, so the slots holding it stay unsized and out of item I/O.
            -- Logged once per item, so the wait is traceable.
            containers:markDetailUnavailable(sample.name, sample.nbt, reason)
            dispatch:finishInflight("detail", detailQueueKey(sample.name, sample.nbt))
        end
    end
end

dispatch:addGenerator(function(now)
    containers:advanceTick()
    -- Reset the stack-scan profile before the queues run, so a fatal "LONG BLOCK" this
    -- tick reports this tick's numbers (0 calls when stackScan did not run).
    containers:resetStackStepStats()
    maintainScanQueues()
    if dispatch:depth("stackScan") == 0 then
        local targets = containers:stackScanTargets()
        for _, target in ipairs(targets) do
            dispatch:enqueue("stackScan", { key = "stack:" .. target.peripheral, container = target.container })
        end
        if #targets > 0 then
            stackScanStats.rounds = (stackScanStats.rounds or 0) + 1
            stackScanStats.lastContainers = #targets
        end
    end
    -- Container scans own the workers until every container is sized: processing
    -- process instances meanwhile keeps those scans from ever finishing (their moves
    -- and detail requests starve the scan queues), so instances are paused while any
    -- container is still pending. Deliberately no timeout: a container that cannot
    -- report its size/limit has to be fixed or removed, not masked.
    local scanPending = containers:slotScanPendingPeripherals()
    if #scanPending > 0 then
        if not containerScanGateLogged then
            containerScanGateLogged = true
            log("Container scans still in progress (%d pending) - process instances are paused: %s",
                #scanPending, table.concat(scanPending, ", "))
        end
    else
        if containerScanGateLogged then
            containerScanGateLogged = false
            log("Container scans complete - process instances resume")
        end
        engine:drainInputContainers(now)
        -- Stock keeping runs before the plan tick, so the demand it injects is planned
        -- in the same round.
        if engine.maintainKeepStock then
            engine:maintainKeepStock(now)
        end
        engine:tick(now)
        if engine:takeInstanceScanBurst() then
            -- A new process instance started: scan the machine containers it needs
            -- right away instead of waiting for the next maintenance pass.
            maintainScanQueues()
        end
    end
    if dispatch:depth("compact") == 0 then
        engine.autoCompactStep(engine, now, dispatch)
    end
    absorbWorkerDetails()
    queueMissingDetails()
    pruneTagCache()
end)

Util.setLogHandler(function (text, seq, level)
    if string.find(text, "[debug]", 1, false) then
        if protocol then
            protocol:onLog(text)
        end
        return
    end
    local colour = Util.logColour and Util.logColour(level) or nil
    if colour and term and term.setTextColour and colours then
        term.setTextColour(colour)
        print(text)
        term.setTextColour(colours.white)
    else
        print(text)
    end
    if protocol then
        protocol:onLog(text)
    end
end)

local IFM_ART = {
    "     _/_/_/  _/_/_/_/  _/      _/ ",
    "      _/    _/        _/_/  _/_/  ",
    "     _/    _/_/_/    _/  _/  _/   ",
    "    _/    _/        _/      _/    ",
    " _/_/_/  _/        _/      _/     ",
}
print("=========================================")
print(" IFM - Integrated Factory Manager (server)")
print("=========================================")
for _, line in ipairs(IFM_ART) do
    print(line)
end
print(" room   : " .. room .. "  (" .. roomNote .. ")")
print(" version: " .. IFM_VERSION)
print(" relay  : " .. wsUrl)
print(" transfer: channel " .. tostring(transfer.channel) ..
    " (run IFMWorker.lua on other computers)")
print(" data   : " .. dataDir)
print(" browser: open IFM/index.html and use the same room name")
print(" Ctrl+T stops safely (config + runtime state are saved)")
print("=========================================")

local startupAt = os.epoch("utc")
if protocol:connect() then
    log("Relay connection requested (async); websocket_success / websocket_failure will report the result")
else
    log("Initial relay connection request failed, retrying every %d seconds", protocol.reconnectInterval)
end
local requestAt = os.epoch("utc")
engine:reconcile()
-- Startup safety net: every machine is marked fully occupied for a moment and the
-- counters are then rebuilt from the restored instances (recipe.resetMachineUsage),
-- so a stale/missing counter can never hand out a parallel slot that is not free.
engine:resetMachineUsage()
-- The claim / crafting ledgers live in memory; rebuild them from the restored
-- instances, otherwise a restart makes material look unclaimed (the instances
-- still hold their claims, the availability calculation would not see them).
local claimsRestored = containers:rebuildClaims(cache:instances())
local craftingRestored = engine:rebuildCrafting()
if claimsRestored > 0 or craftingRestored > 0 then
    log("Ledgers rebuilt from restored instances: %d claim(s), %d crafting entr(ies)",
        claimsRestored, craftingRestored)
end
local reconcileAt = os.epoch("utc")
engine:restoreSignals()
log("Startup timings: connect request +%dms, reconcile +%dms, restoreSignals +%dms",
    requestAt - startupAt, reconcileAt - requestAt, os.epoch("utc") - reconcileAt)

local TICK = 0.05
local tickToken = nil
local armedAt = 0
local function armTick()
    tickToken = os.startTimer(TICK)
    armedAt = os.epoch("utc")
end
armTick()
local lastStatusPrint = os.epoch("utc")
local startedAt = os.epoch("utc")

local function statusLine()
    local protocolStatus = protocol.status and protocol.status(protocol) or nil
    local link = ""
    if type(protocolStatus) == "table" then
        link = string.format(" / link: up=%ds idle=%ds closes=%d%s",
            protocolStatus.connectedSeconds or 0,
            protocolStatus.idleSeconds or 0,
            protocolStatus.closes or 0,
            protocolStatus.lastCloseReason and (" (" .. tostring(protocolStatus.lastCloseReason) .. ")") or "")
    end
    local connection = protocol.connected and "relay:up" or "relay:down"
    local client = protocol.clientActive and "browser:on" or "browser:off"
    log("%s / %s / room %s / defs: containers=%d signals=%d filters=%d machines=%d processes=%d / uptime %ds%s",
        connection,
        client,
        room,
        #store:list("containers"),
        #store:list("signals"),
        #store:list("filters"),
        #store:list("machines"),
        #store:list("processes"),
        math.floor((os.epoch("utc") - startedAt) / 1000),
        link)
    for _, delivery in ipairs(cache:deliveries()) do
        log("delivery #%s %s x%s -> %s%s",
            tostring(delivery.id or 0),
            tostring(delivery.name),
            tostring(delivery.remaining or 0),
            tostring(delivery.container),
            delivery.lastError and (" | " .. tostring(delivery.lastError)) or "")
    end
    for _, process in ipairs(store:list("processes")) do
        local record = cache:proc(process.name)
        log("process %s state=%s phase=%s batch=%s machine=%s err=%s",
            tostring(process.name),
            tostring(record.state),
            tostring(record.phase),
            tostring(record.batch),
            tostring(record.machine),
            tostring(record.lastError))
    end
end

local TICK_GAP_KEEP = 200
local debugCounters = { events = 0, timers = 0, websockets = 0, ticks = 0,
    modemMessages = 0, otherEvents = 0, startedAt = os.epoch("utc"),
    requests = requestStats,
    tickGaps = {} }
local lastTickAt = 0
engine.debugCounters = debugCounters

local SLOW_STEP_MS = 500
-- A step that runs this long without returning to os.pullEvent() froze the whole
-- master (no modem/websocket events are served meanwhile), so every slow step is
-- reported as a warning - and a step that takes >=1s is a hard failure: it means the
-- main loop could not serve events for a whole second, so the master aborts loudly
-- instead of limping on.
local BLOCK_FAIL_MS = 1000
local perfStats = {}
local function perfStatOf(label)
    local stat = perfStats[label]
    if not stat then
        stat = { label = label, count = 0, total = 0, max = 0, last = 0, slow = 0 }
        perfStats[label] = stat
    end
    return stat
end

local slowDetails = {}
-- Compact detail providers used by the FATAL (>=1s) message: it has to fit a CC:T
-- terminal, so these return one short line (the slowDetails above are for the web log).
local fatalDetails = {}

local function timed(label, fn, ...)
    local startedAt = os.epoch("utc")
    fn(...)
    local elapsed = os.epoch("utc") - startedAt
    local stat = perfStatOf(label)
    stat.count = stat.count + 1
    stat.total = stat.total + elapsed
    stat.last = elapsed
    if elapsed > stat.max then
        stat.max = elapsed
    end
    if elapsed >= BLOCK_FAIL_MS then
        -- A second without yielding froze the main loop: fail hard. The message must
        -- stay short enough for a CC:T terminal, so only a compact breakout of the
        -- step is appended (the verbose slowDetails goes to the web log only).
        local why = ""
        local detail = fatalDetails[label]
        if detail then
            local ok, text = pcall(detail)
            if ok and type(text) == "string" and text ~= "" then
                why = "\n  " .. text
            end
        end
        Assert.is(false, "[IFM] LONG BLOCK %s: %dms (>=%dms)%s",
            label, elapsed, BLOCK_FAIL_MS, why)
    end
    if elapsed >= SLOW_STEP_MS then
        stat.slow = stat.slow + 1
        log.warn("Slow %s: %dms (calls=%d avg=%dms max=%dms slow=%d)",
            label, elapsed, stat.count, math.floor(stat.total / stat.count), stat.max, stat.slow)
        local detail = slowDetails[label]
        if detail then
            local text = detail()
            if type(text) == "string" and text ~= "" then
                log.warn("Slow %s detail: %s", label, text)
            end
        end
    end
end

slowDetails["dispatch"] = function()
    local dispatchStatus = dispatch:status()
    local parts = {}
    for _, queue in ipairs(dispatchStatus.queues) do
        parts[#parts + 1] = string.format("%s=%d", queue.name, queue.depth)
    end
    -- Which phase of the last dispatch run the time went into (flush / maintain /
    -- promote / gen / rotate), plus the sizes that make a phase expensive.
    local run = dispatchStatus.lastRun or {}
    local phase = string.format("phases flush=%.0f maintain=%.0f promote=%.0f gen=%.0f rotate=%.0f ms",
        tonumber(run.flush) or 0, tonumber(run.maintain) or 0, tonumber(run.promote) or 0,
        tonumber(run.gen) or 0, tonumber(run.rotate) or 0)
    local instances = 0
    for _ in pairs(cache:instances() or {}) do
        instances = instances + 1
    end
    local deliveries = #(cache:deliveries() or {})
    local capacity = containers.capacityStats and containers:capacityStats() or nil
    local usedSlots = capacity and tonumber(capacity.slots) or 0
    local totalSlots = capacity and tonumber(capacity.totalSlots) or 0
    local compact = engine.compact
    local text = string.format(
        "%s | %s | mode=%s runSteps=%d runMs=%.0f maxMs=%.0f paused=%s | " ..
        "instances=%d deliveries=%d slots=%d/%d compactPlan=%d | %s",
        engine:tickStatsText(), phase, tostring(dispatchStatus.mode),
        tonumber(run.steps) or 0, tonumber(dispatchStatus.lastMs) or 0,
        tonumber(dispatchStatus.maxMs) or 0, tostring(run.paused),
        instances, deliveries, usedSlots, totalSlots,
        compact and (tonumber(compact.total) or 0) or 0,
        table.concat(parts, " "))
    local stack = containers:stackStepText()
    if type(stack) == "string" and stack ~= "" then
        text = text .. " | " .. stack
    end
    return text
end

-- Fatal (>=1s) detail: keep it to one short line for the CC:T terminal.
fatalDetails["dispatch"] = function()
    local text = dispatch:runText()
    local stack = containers:stackStepText()
    if type(stack) == "string" and stack ~= "" then
        text = text .. "\n  " .. stack
    end
    return text
end

slowDetails["protocol update"] = function()
    local scan = containers:scanSummary()
    return string.format("containers=%s readCost=%sms passCost=%sms scanTtl=%sms (base=%sms x%s) defer=%s watched=%s reconcile=%s",
        tostring(scan.containers), tostring(scan.readCost), tostring(scan.passCost),
        tostring(scan.ttl), tostring(scan.baseTtl), tostring(scan.multiplier),
        tostring(scan.defer or 0), tostring(scan.watched or 0), tostring(scan.reconcile or 0))
end

diagnose.perfStats = perfStats
diagnose.debugCounters = debugCounters
diagnose.protocol = protocol
diagnose.transfer = transfer
diagnose.dispatch = dispatch
diagnose.engine = engine

local lastPeripheralScanAt = 0
local peripheralScanPending = false

local function peripheralSignature()
    local parts = {}
    for _, kind in ipairs({ "inventory", "fluid", "redstone", "turtle" }) do
        for _, name in ipairs(peripherals:names(kind)) do
            parts[#parts + 1] = kind .. ":" .. name
        end
    end
    table.sort(parts)
    return parts
end

local function refreshPeripheralsIfNeeded(now)
    if not peripheralScanPending or now - lastPeripheralScanAt < 1000 then
        return
    end
    peripheralScanPending = false
    lastPeripheralScanAt = now
    log("Peripherals changed, rescanning")
    local before = peripheralSignature()
    timed("peripheral scan", peripherals.scan, peripherals)
    containers:invalidate()
    forgetRemovedContainers("peripheral removed")
    local after = peripheralSignature()
    if table.concat(before, "\1") ~= table.concat(after, "\1") then
        cache:markDirty()
        log("Peripheral set changed: %d -> %d peripheral(s)", #before, #after)
        if #before == #after then
            log("Peripheral names changed (a wired modem renumbers its peripherals when it is reconnected):" ..
                " container definitions pointing at the old names stay 'missing' - re-add them" ..
                " or use the missing list to delete them")
        end
    end
end

local function masterTick(now)
    debugCounters.ticks = debugCounters.ticks + 1
    do
        local nowMs = tonumber(now) or os.epoch("utc")
        if lastTickAt > 0 then
            local gaps = debugCounters.tickGaps
            gaps[#gaps + 1] = math.floor(nowMs - lastTickAt)
            if #gaps > TICK_GAP_KEEP then
                table.remove(gaps, 1)
            end
        end
        lastTickAt = nowMs
    end
    containers:setTickSeq(debugCounters.ticks)
    timed("peripheral refresh", refreshPeripheralsIfNeeded, now)
    -- The planning engine walks the material ledger before anything else runs: it
    -- derives the rounds, sends the instances and books the demand one level up.
    timed("process plan", engine.planTick, engine, now)
    -- The storage compaction *plan* is generated here, before the scheduler runs: it
    -- never enters a dispatch queue and never spends an executor slot. Only the
    -- resulting move tasks are executed by the compact queue.
    timed("compact plan", engine.compactPlanTick, engine, now)
    timed("scheduler", scheduler.tick, scheduler, now)
    timed("protocol update", protocol.update, protocol, now)
    -- Boot grace: leave the task scheduler parked for a moment so IFMWorkers that boot
    -- alongside the master can register before any move runs (see inBootGrace). The
    -- planning steps above still run; their tasks simply wait in the queues.
    if inBootGrace(now) then
        if not bootGraceStartLogged then
            bootGraceStartLogged = true
            log("[startup] boot grace %dms: holding the task scheduler while workers register",
                BOOT_GRACE_MS)
        end
    else
        if not bootGraceDoneLogged then
            bootGraceDoneLogged = true
            log("[startup] boot grace over (%dms): advancing the task scheduler", BOOT_GRACE_MS)
        end
        timed("dispatch", dispatch.tick, dispatch, now)
    end
    timed("transfer flush", transfer.flushOutbox, transfer)
    timed("scan tick", containers.beginScanTick, containers)
    if protocol and protocol.flushSendBuffer then
        timed("protocol flush", protocol.flushSendBuffer, protocol)
    end
    if now - lastStatusPrint > 30000 then
        lastStatusPrint = now
        timed("status line", statusLine)
    end
end

local function mainLoop()
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        debugCounters.events = debugCounters.events + 1
        if event == "modem_message" then
            debugCounters.modemMessages = debugCounters.modemMessages + 1
        elseif event ~= "timer" and event ~= "websocket_success" and event ~= "websocket_message"
            and event ~= "websocket_closed" and event ~= "websocket_failure" then
            debugCounters.otherEvents = debugCounters.otherEvents + 1
        end
        if event == "timer" and param1 == tickToken then
            tickToken = nil
            debugCounters.timers = debugCounters.timers + 1
            masterTick(Util.now())
            armTick()
        elseif event == "peripheral" or event == "peripheral_detach" then
            peripheralScanPending = true
        elseif event == "websocket_success" or event == "websocket_message" or event == "websocket_closed"
            or event == "websocket_failure" or event == "http_success" or event == "http_failure" then
            debugCounters.websockets = debugCounters.websockets + 1
            timed("protocol event", protocol.onEvent, protocol, event, param1, param2, param3)
        elseif event == "modem_message" then
            timed("transfer message", transfer.onModemMessage, transfer, param1, param2, param3, param4, param5)
        end
        local now = Util.now()
        if tickToken and now - armedAt > 2 * TICK * 1000 then
            tickToken = nil
            armTick()
        end
    end
end

mainLoop()
store:flush()
cache:flush()