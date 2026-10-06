local Recipe = {}
Recipe.__index = Recipe

local Assert = nil
local RefCount = nil

-- The planning engine follows the demand chain one level per tick (50 ms), so no
-- depth constant is needed any more; it stops when nothing is short.



local ALL_SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- The claim / occupancy / crafting ledgers key every reservation by its *instance*,
-- not by the process name: two live instances of one process must be separate
-- sources, otherwise releasing one would drop the other's reservation.
local function instanceSource(inst)
    return "process:" .. tostring(inst and inst.owner or "") .. "#" .. tostring(inst and inst.id or 0)
end

local PULSE_HOLD_MS = 50

-- A large send is spread over the free slots of the target containers, but only so
-- many moves are submitted per attempt: the rest follows on the next tick, once the
-- first ones reported. Keeps one request from flooding the transfer layer.
local SEND_SPREAD_MAX = 8

-- The IO mode of a process. `sequential` runs one material operation at a time;
-- `two_phase` parallelises the operations inside a block and keeps the input phase
-- before the output phase; `unordered` additionally lets the output phase progress
-- while the inputs are still being delivered. Old definitions only carry the
-- boolean `unorderedIo`: true == the old "unordered IO" (today's two-phase), false
-- == the old sequential behaviour.
local function processIoMode(process)
    if process and process.ioMode ~= nil then
        return process.ioMode
    end
    if process and process.unorderedIo == true then
        return "two_phase"
    end
    return "sequential"
end

local function processBlockParallel(process)
    return processIoMode(process) ~= "sequential"
end

local function elementDemand(element, batch)
    local count = tonumber(element.count) or 0
    local rounds = Assert.count(batch, "elementDemand batch")
    if element.catalyst then
        -- A catalyst is a fixed amount per flow instance: it is never multiplied by
        -- the batch, so one instance consumes `count` no matter how many rounds it is.
        return count
    end
    return count * rounds
end

-- Material operations (the ones that move items/fluids); everything else in a
-- process (waitTime, waitSignal, emitSignal, emitPulse) is a barrier between
-- "unordered IO" blocks.
local function isMaterialElement(element)
    return type(element) == "table" and (element.kind == "item" or element.kind == "fluid"
        or element.kind == "filter")
end

local function elementSpec(element)
    return {
        kind = element.kind,
        id = element.id,
        nbt = element.nbt,
        ignoreNbt = element.ignoreNbt,
    }
end

-- Output elements may pin the machine output container / the slot inside it
-- (element.containerIndex / element.slot, -1 = any). The scope is used to pick
-- the source container and to decide what "the machine still holds" means.
local function outputScopeOf(opts)
    opts = opts or {}
    local index = tonumber(opts.containerIndex)
    if not index or index < 1 then
        index = nil
    end
    local slot = tonumber(opts.slot)
    if not slot or slot < 1 then
        slot = nil
    end
    return index, slot
end

local OP_FUNCS = {
    gt = function(a, b)
        return a > b
    end,
    ge = function(a, b)
        return a >= b
    end,
    eq = function(a, b)
        return a == b
    end,
    le = function(a, b)
        return a <= b
    end,
    lt = function(a, b)
        return a < b
    end,
}

local function readAnalog(peripheralTable, side)
    if type(peripheralTable.getAnalogInput) == "function" then
        local ok, value = pcall(peripheralTable.getAnalogInput, side)
        if ok and type(value) == "number" then
            return value
        end
    end
    if type(peripheralTable.getAnalogueInput) == "function" then
        local ok, value = pcall(peripheralTable.getAnalogueInput, side)
        if ok and type(value) == "number" then
            return value
        end
    end
    if type(peripheralTable.getInput) == "function" then
        local ok, value = pcall(peripheralTable.getInput, side)
        if ok then
            if value then
                return 15
            end
            return 0
        end
    end
    return 0
end

local function writeAnalog(peripheralTable, side, strength)
    if type(peripheralTable.setAnalogOutput) == "function" then
        local ok = pcall(peripheralTable.setAnalogOutput, side, strength)
        if ok then
            return true
        end
    end
    if type(peripheralTable.setAnalogueOutput) == "function" then
        local ok = pcall(peripheralTable.setAnalogueOutput, side, strength)
        if ok then
            return true
        end
    end
    if type(peripheralTable.setOutput) == "function" then
        local ok = pcall(peripheralTable.setOutput, side, strength > 0)
        if ok then
            return true
        end
    end
    return false
end

function Recipe.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Recipe)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("recipe.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.Message = opts.Message
        or error("recipe.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    Assert = self.Assert
    self.RefCount = opts.RefCount
        or error("recipe.lua needs the refcount module: pass opts.RefCount (loadModule(\"refcount\"))", 0)
    RefCount = self.RefCount
    self.Store = opts.Store
    self.Cache = opts.Cache
    self.Peripherals = opts.Peripherals
    self.Containers = opts.Containers
    self.Filter = opts.Filter
    self.log = opts.log or function() end
    self.stepBudget = 1
    -- The scheduler handle: heavy work (the storage compact *planning* pass) is
    -- handed to a dispatch queue instead of running inline.
    self.dispatch = nil
    self.compactOpsPerTick = opts.compactOpsPerTick or 3
    self.compactFreeRatio = tonumber(opts.compactFreeRatio) or 0.10
    self.tickCount = 0
    self.lastTickAt = 0
    self.lastTickError = nil
    self.tickStats = { steps = 0, active = 0, processes = 0, reads = 0, readMs = 0 }
    self.debug = opts.debug ~= false
    -- material key -> { { process = <name>, yield = <per batch> }, ... }: every
    -- process that can craft that material and has its "craft reference" switch
    -- on. Rebuilt when the store revision changes, never written to disk.
    self.craftIndexCache = nil
    self.craftIndexRev = nil
    -- Per-tick counters of the planning engine (status line / diagnose).
    self.planStats = { need = 0, created = 0, materials = 0, machines = 0 }
    return self
end

function Recipe:debugInfo(fmt, ...)
    if not self.debug then
        return
    end
    self.log("[debug] " .. string.format(fmt, ...))
end

function Recipe:stallLog(fmt, ...)
    self.log("[debug] " .. string.format(fmt, ...))
end

local function callerOf(level)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return "?"
    end
    local info = debug.getinfo((level or 1) + 1, "Sl")
    if type(info) ~= "table" then
        return "?"
    end
    return tostring(info.short_src or "?") .. ":" .. tostring(info.currentline or 0)
end

function Recipe:batchOf(record)
    local batch = record and (record.multiplier or record.batch)
    self.Assert.is(type(batch) == "number" and batch >= 1 and batch == math.floor(batch),
        "record.multiplier must be a positive integer inside a running instance (got %s, phase=%s)" ..
        " - it is written by recipe.createInstance", tostring(batch), tostring(record and record.phase))
    return batch
end

function Recipe:indexOf(record)
    local index = record and record.index
    self.Assert.is(type(index) == "number" and index >= 1 and index == math.floor(index),
        "record.index must be an integer >= 1 (got %s) - see Cache.defaultProc / record.index writes",
        tostring(index))
    return index
end

function Recipe:moveKeyCount()
    local n = 0
    for _ in pairs(self.moveKeys or {}) do n = n + 1 end
    return n
end

-- One token may own several moves at once (a large send is split over the free
-- slots of the target containers), so a token maps to a record that collects every
-- key's result. The record survives partial answers: the moves that already
-- reported keep their counted amount until the whole token settles.
function Recipe:trackMoveKey(token, key)
    if not token or not key then
        return
    end
    self.moveKeys = self.moveKeys or {}
    local entry = self.moveKeys[token]
    if not entry then
        entry = { keys = {}, answered = {}, moved = 0, err = nil, remaining = 0 }
        self.moveKeys[token] = entry
    end
    entry.keys[#entry.keys + 1] = key
    entry.remaining = entry.remaining + 1
    self.moveKeyAt = self.moveKeyAt or {}
    self.moveKeyAt[token] = os.epoch("utc")
end

function Recipe:settleInFlightMove(token)
    local entry = token and self.moveKeys and self.moveKeys[token]
    if not entry then
        return nil, nil
    end
    for i = 1, #entry.keys do
        if not entry.answered[i] then
            local result = self.Containers:takeMoveResult(entry.keys[i])
            if result then
                entry.answered[i] = true
                entry.moved = entry.moved + (tonumber(result.moved) or 0)
                if result.err then
                    entry.err = result.err
                end
                entry.remaining = entry.remaining - 1
            end
        end
    end
    if entry.remaining <= 0 then
        self.moveKeys[token] = nil
        if self.moveKeyAt then
            self.moveKeyAt[token] = nil
        end
        if self.inflightWant then
            self.inflightWant[token] = nil
        end
        return entry.moved, entry.err
    end
    local at = tonumber(self.moveKeyAt and self.moveKeyAt[token]) or 0
    local now = os.epoch("utc")
    self:stallLog("move-result-miss token=%s keys=%d waited=%dms", tostring(token), #entry.keys,
        at > 0 and (now - at) or -1)
    return nil, "pending"
end

-- Bookkeeping for the multi-move extraction (see Recipe:takeFromMachineMulti): one
-- element may have several moves on the way at once, each under its own token. This
-- remembers what each of them was asked to move, so a later attempt does not request
-- the same amount again while it is still travelling.
function Recipe:noteInflightWant(token, want)
    if not token then
        return
    end
    self.inflightWant = self.inflightWant or {}
    self.inflightWant[token] = math.floor(tonumber(want) or 0)
end

-- How much is on the way for every token starting with `prefix`.
function Recipe:inflightWantOf(prefix)
    local total = 0
    if not self.inflightWant then
        return total
    end
    local size = #prefix
    for token, want in pairs(self.inflightWant) do
        if string.sub(token, 1, size) == prefix then
            total = total + (tonumber(want) or 0)
        end
    end
    return total
end

-- Settle every in-flight move whose token starts with `prefix`, adding the results
-- up. Returns (total, pending): `pending` is true while at least one of them is
-- still unanswered.
function Recipe:settleInFlightMoves(prefix)
    local total, pending = 0, false
    if not self.moveKeys then
        return total, pending
    end
    local size = #prefix
    local tokens = {}
    for token in pairs(self.moveKeys) do
        if string.sub(token, 1, size) == prefix then
            tokens[#tokens + 1] = token
        end
    end
    for _, token in ipairs(tokens) do
        local moved, reason = self:settleInFlightMove(token)
        if moved ~= nil then
            total = total + moved
        elseif reason == "pending" then
            pending = true
        end
    end
    return total, pending
end

-- Message nodes that go into lastError are compared with ~= in a few places to keep
-- the cache from being marked dirty on every tick, so the same message (same key and
-- same parameters) has to come back as the *same* table.
local function paramsKey(params)
    if type(params) ~= "table" then
        return tostring(params)
    end
    local parts = {}
    for name, value in pairs(params) do
        local text = (type(value) == "table" and value.key) or tostring(value)
        parts[#parts + 1] = tostring(name) .. "=" .. tostring(text)
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

function Recipe:messageOf(key, params, cacheKey)
    self.messageCache = self.messageCache or {}
    local digest = cacheKey or (key .. "|" .. paramsKey(params))
    local node = self.messageCache[digest]
    if node and node.key == key then
        return node
    end
    node = self.Message.msg(key, params)
    self.messageCache[digest] = node
    return node
end

function Recipe:record(name)
    return self.Cache:proc(name)
end

function Recipe:isAbstract(process)
    return self.Store.processIsAbstract(process)
end

function Recipe:machinesOfType(typeName)
    if self.Store.isTypeConversion(typeName) then
        -- The type conversion type is virtual: it has no peripheral and no stored
        -- machine, so the engine hands out one synthetic instance of it.
        return { {
            name = self.Store.TYPE_CONVERSION_TYPE,
            type = self.Store.TYPE_CONVERSION_TYPE,
            virtual = true,
            parallel = 1,
            itemInputs = {}, fluidInputs = {}, itemOutputs = {}, fluidOutputs = {}, signals = {},
        } }
    end
    local list = {}
    for _, machine in ipairs(self.Store:list("machines")) do
        if machine.type == typeName then
            list[#list + 1] = machine
        end
    end
    return list
end

function Recipe:signalPeripheralOf(entry)
    if type(entry) ~= "string" or entry == "" then
        return nil
    end
    local signal = self.Store:get("signals", entry)
    if signal and type(signal.peripheral) == "string" and signal.peripheral ~= "" then
        return signal.peripheral, signal.name or entry
    end
    return entry, entry
end

function Recipe:machineUsable(machine)
    local lists = {
        { list = machine.itemInputs, kind = "item" },
        { list = machine.fluidInputs, kind = "fluid" },
        { list = machine.itemOutputs, kind = "item" },
        { list = machine.fluidOutputs, kind = "fluid" },
    }
    for _, entry in ipairs(lists) do
        for _, containerName in ipairs(entry.list or {}) do
            if not self.Containers:supports(containerName, entry.kind) then
                return false
            end
        end
    end
    for _, signalEntry in ipairs(machine.signals or {}) do
        local peripheral = self:signalPeripheralOf(signalEntry)
        if not peripheral or not self.Peripherals:exists(peripheral) then
            return false
        end
    end
    return true
end

function Recipe:machineProblem(machine)
    local lists = {
        { list = machine.itemInputs, kind = "item", label = self.Message.msg(self.Message.KEYS.RECIPE_LABEL_ITEM_INPUTS) },
        { list = machine.fluidInputs, kind = "fluid", label = self.Message.msg(self.Message.KEYS.RECIPE_LABEL_FLUID_INPUTS) },
        { list = machine.itemOutputs, kind = "item", label = self.Message.msg(self.Message.KEYS.RECIPE_LABEL_ITEM_OUTPUTS) },
        { list = machine.fluidOutputs, kind = "fluid", label = self.Message.msg(self.Message.KEYS.RECIPE_LABEL_FLUID_OUTPUTS) },
    }
    for _, entry in ipairs(lists) do
        for _, containerName in ipairs(entry.list or {}) do
            if not self.Containers:supports(containerName, entry.kind) then
                return self.Message.msg(self.Message.KEYS.RECIPE_ERR_CONTAINER_PROBLEM, {
                    label = entry.label,
                    container = tostring(containerName),
                    reason = self.Containers:unusableReason(containerName, entry.kind)
                        or self.Message.msg(self.Message.KEYS.COMMON_UNAVAILABLE),
                })
            end
        end
    end
    for _, signalEntry in ipairs(machine.signals or {}) do
        local peripheral, label = self:signalPeripheralOf(signalEntry)
        if not peripheral then
            return self.Message.msg(self.Message.KEYS.RECIPE_ERR_SIGNAL_DEF_MISSING, { signal = tostring(signalEntry) })
        end
        if not self.Peripherals:exists(peripheral) then
            return self.Message.msg(self.Message.KEYS.RECIPE_ERR_SIGNAL_RELAY_MISSING, { signal = tostring(label), peripheral = tostring(peripheral) })
        end
    end
    return nil
end

function Recipe:chooseMachine(typeName)
    local list = self:machinesOfType(typeName)
    if #list == 0 then
    return nil, self:messageOf(self.Message.KEYS.RECIPE_ERR_NO_MACHINE, { type = tostring(typeName) })
    end
    local total = #list
    local record = self.Cache:machineType(typeName)
    local start = (tonumber(record.rrIndex) or 0) % total
    local unusable = 0
    for offset = 0, total - 1 do
        local position = (start + offset) % total + 1
        local machine = list[position]
        if self:machineUsable(machine) then
            if self:machineRunning(machine.name) < (machine.parallel or 1) then
                record.rrIndex = position % total
                self.Cache:markDirty()
                return machine
            end
        else
            unusable = unusable + 1
        end
    end
    if unusable == total then
            return nil, self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINES_UNUSABLE)
    end
    return nil, self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINES_BUSY)
end

-- Machine occupancy is a RefCount keyed by instance id; `usage.running` in the
-- cache is only a mirrored snapshot, so cache.json keeps its old shape.
function Recipe:machineRef(machineName)
    self.machineLedger = self.machineLedger or {}
    local ref = self.machineLedger[machineName]
    if not ref then
        ref = RefCount.new("machine:" .. tostring(machineName))
        self.machineLedger[machineName] = ref
    end
    return ref
end

function Recipe:machineRunning(machineName)
    local ref = self.machineLedger and self.machineLedger[machineName]
    return ref and ref:value() or 0
end

function Recipe:occupyMachine(machineName, delta, source)
    if type(machineName) ~= "string" or machineName == "" then
        return 0
    end
    local ref = self:machineRef(machineName)
    source = tostring(source or "?")
    if (tonumber(delta) or 0) >= 0 then
        ref:add(source, delta)
    else
        ref:remove(source)
    end
    local running = ref:value()
    -- Mirror the ledger into the persisted record (display / panel only).
    self.Cache:machine(machineName).running = running
    self.Cache:markDirty()
    return running
end

function Recipe:machineUsage()
    local out = {}
    for _, machine in ipairs(self.Store:list("machines")) do
        out[#out + 1] = {
            name = machine.name,
            type = machine.type,
            parallel = machine.parallel or 1,
            running = self:machineRunning(machine.name),
        }
    end
    return out
end

-- Startup safety net: mark every machine as fully occupied for a moment, then
-- rebuild the counters from the restored instances - the only thing that can
-- really hold a machine. A panel that happens to look in between sees "busy"
-- instead of a stale number, and afterwards the counters depend on the cache's
-- instances only, never on what the previous run happened to save.
function Recipe:resetMachineUsage()
    local machines = self.Store:list("machines")
    local before = {}
    for _, machine in ipairs(machines) do
        before[machine.name] = self:machineRunning(machine.name)
        -- Lock first: between here and the rebuild below a parallel slot must
        -- never look free.
        local ref = self:machineRef(machine.name)
        ref:reset()
        ref:add("startup", math.max(1, math.floor(tonumber(machine.parallel) or 1)))
    end
    local instances = 0
    for id, inst in pairs(self.Cache:instances()) do
        instances = instances + 1
        local name = type(inst.machine) == "string" and inst.machine or ""
        if name ~= "" then
            -- One source per instance: the same key the runtime release uses.
            local ref = self:machineRef(name)
            ref:remove("startup")
            ref:add(instanceSource(inst) or ("instance:" .. tostring(id)), 1)
        end
    end
    local corrected = 0
    for name, ref in pairs(self.machineLedger or {}) do
        -- The startup lock is dropped for *every* machine here, not just for the
        -- ones that got an instance back: a machine with no instance must end up
        -- at 0, not at "fully occupied".
        ref:remove("startup")
        local running = ref:value()
        -- An instance whose machine definition is gone (deleted, renamed, turtle
        -- offline) still gets a record: releasing it looks the record up.
        self.Cache:machine(name).running = running
        if (before[name] or 0) ~= running then
            corrected = corrected + 1
        end
    end
    self.Cache:markDirty()
    self.log("Machine parallel counters reset at startup: %d machine(s) locked then rebuilt for %d restored " ..
        "instance(s) (%d had a counter that did not match)", #machines, instances, corrected)
end

function Recipe:resolveSignals(machine, element)
    local result = {}
    local sides = element.sides or {}
    if #sides == 0 then
        sides = ALL_SIDES
    end
    local machineSignalIndex = tonumber(element.machineSignalIndex) or -1
    if machineSignalIndex >= 1 and machine then
        local signalEntry = (machine.signals or {})[machineSignalIndex]
        local peripheral, label = self:signalPeripheralOf(signalEntry)
        if peripheral then
            result[#result + 1] = { peripheral = peripheral, sides = sides, signalName = label }
        end
    end
    return result
end

function Recipe:signalSatisfied(machine, element)
    local op = OP_FUNCS[element.op or "ge"] or OP_FUNCS.ge
    local threshold = tonumber(element.threshold) or 0
    local values = {}
    for _, entry in ipairs(self:resolveSignals(machine, element)) do
        local peripheralTable = self.Peripherals:wrap(entry.peripheral)
        if peripheralTable then
            for _, side in ipairs(entry.sides) do
                local value = readAnalog(peripheralTable, side)
                values[#values + 1] = value
                if op(value, threshold) then
                    return true, values
                end
            end
        end
    end
    return false, values
end

function Recipe:switchSignals(targets, strength)
    local emitted = false
    for _, target in ipairs(targets or {}) do
        local peripheralTable = self.Peripherals:wrap(target.peripheral)
        if peripheralTable then
            if writeAnalog(peripheralTable, target.side, strength) then
                emitted = true
                local key = target.peripheral .. "/" .. target.side
                self.Cache:setSignalOutput(key, {
                    peripheral = target.peripheral,
                    side = target.side,
                    strength = strength,
                })
            end
        end
    end
    return emitted
end

function Recipe:signalTargets(machine, element)
    local targets = {}
    for _, entry in ipairs(self:resolveSignals(machine, element)) do
        for _, side in ipairs(entry.sides) do
            targets[#targets + 1] = { peripheral = entry.peripheral, side = side }
        end
    end
    return targets
end

function Recipe:emitSignals(machine, element)
    local strength = math.floor(tonumber(element.strength) or 15)
    local emitted = self:switchSignals(self:signalTargets(machine, element), strength)
    if not emitted then
        self.log("Emit signal failed: no usable redstone relay peripheral")
    end
    return emitted
end

function Recipe:startPulse(machine, element, record, now, nextIndex)
    local targets = self:signalTargets(machine, element)
    if #targets == 0 then
        self.log("Pulse signal failed: no usable redstone relay peripheral")
        return false
    end
    local strength = math.floor(tonumber(element.strength) or 15)
    self:switchSignals(targets, strength)
    record.pulse = {
        index = math.max(1, tonumber(nextIndex) or (self:indexOf(record) + 1)),
        phase = "on",
        untilMs = now + PULSE_HOLD_MS,
        targets = targets,
        strength = strength,
    }
    self.Cache:markDirty()
    return true
end

function Recipe:advancePulse(record, now)
    local pulse = record.pulse
    if not pulse then
        return true
    end
    if now < (pulse.untilMs or 0) then
        return false
    end
    if pulse.phase == "on" then
        self:switchSignals(pulse.targets, 0)
        pulse.phase = "off"
        pulse.untilMs = now + PULSE_HOLD_MS
        self.Cache:markDirty()
        return false
    end
    record.pulse = nil
    record.index = math.max(1, tonumber(pulse.index) or (self:indexOf(record) + 1))
    self.Cache:markDirty()
    return true
end

function Recipe:restoreSignals()
    local restored = 0
    for key, entry in pairs(self.Cache:signalOutputs()) do
        local peripheralTable = self.Peripherals:wrap(entry.peripheral)
        if peripheralTable then
            if writeAnalog(peripheralTable, entry.side, math.floor(tonumber(entry.strength) or 0)) then
                restored = restored + 1
            else
                self.Cache:clearSignalOutput(key)
            end
        else
            self.Cache:clearSignalOutput(key)
        end
    end
    if restored > 0 then
        self.log("Restored %d redstone output(s)", restored)
    end
    return restored
end

function Recipe:inputContainers(machine, resourceKind, containerIndex)
    if not machine then
        return {}
    end
    local list
    if resourceKind == "fluid" then
        list = machine.fluidInputs or {}
    else
        list = machine.itemInputs or {}
    end
    local index = tonumber(containerIndex) or -1
    if index >= 1 then
        if list[index] then
            return { list[index] }
        end
        return {}
    end
    local out = {}
    for _, name in ipairs(list) do
        out[#out + 1] = name
    end
    return out
end

function Recipe:outputContainers(machine, resourceKind, containerIndex)
    if not machine then
        return {}
    end
    local list
    if resourceKind == "fluid" then
        list = machine.fluidOutputs or {}
    else
        list = machine.itemOutputs or {}
    end
    local index = tonumber(containerIndex) or -1
    if index >= 1 then
        if list[index] then
            return { list[index] }
        end
        return {}
    end
    local out = {}
    for _, name in ipairs(list) do
        out[#out + 1] = name
    end
    return out
end

function Recipe:rememberPendingMove(token, record)
    if not token then
        return
    end
    self.pendingMoves = self.pendingMoves or {}
    record.at = os.epoch("utc")
    self.pendingMoves[token] = record
end

function Recipe:forgetPendingMove(token)
    if not token then
        return
    end
    if self.pendingMoves then
        self.pendingMoves[token] = nil
    end
    local entry = self.moveKeys and self.moveKeys[token]
    if entry then
        self.moveKeys[token] = nil
        if self.Containers and self.Containers.releaseMoveKey then
            for _, key in ipairs(entry.keys or {}) do
                self.Containers:releaseMoveKey(key, "move forgotten")
            end
        end
    end
    if self.inflightWant then
        self.inflightWant[token] = nil
    end
end

function Recipe:forgetPendingMovesWithPrefix(prefix)
    if type(prefix) ~= "string" then
        return
    end
    local size = #prefix
    if self.pendingMoves then
        for token in pairs(self.pendingMoves) do
            if string.sub(token, 1, size) == prefix then
                self.pendingMoves[token] = nil
            end
        end
    end
    if self.moveKeys then
        for token in pairs(self.moveKeys) do
            if string.sub(token, 1, size) == prefix then
                local entry = self.moveKeys[token]
                self.moveKeys[token] = nil
                if entry and self.Containers and self.Containers.releaseMoveKey then
                    for _, key in ipairs(entry.keys or {}) do
                        self.Containers:releaseMoveKey(key, "prefix reset")
                    end
                end
            end
        end
    end
    if self.inflightWant then
        for token in pairs(self.inflightWant) do
            if string.sub(token, 1, size) == prefix then
                self.inflightWant[token] = nil
            end
        end
    end
end

function Recipe:resumePendingMove(token)
    local record = token and self.pendingMoves and self.pendingMoves[token]
    if not record then
        return nil, nil
    end
    local queueName = record.queueName or "inventoryIn"
    local moved, err
    if record.kind == "fluid" then
        moved, err = self.Containers:pushFluid(record.container, record.want, record.fluid, record.target, queueName)
    else
        moved, err = self.Containers:pushItem(record.container, record.slot, record.want, record.target,
            record.toSlot, record.mode, queueName, record.item)
    end
    if err == "pending" then
        return nil, "pending"
    end
    self.pendingMoves[token] = nil
    return tonumber(moved) or 0, err
end

-- A filter input has to be turned into one concrete resource before it can be
-- moved into the machine: the filter is matched against what storage really
-- holds and the resource with the most to give wins (items are only preferred
-- over fluids when they hold more). Mirrors resolveFilterOutput.
function Recipe:resolveFilterSource(spec)
    local best
    for _, storageName in ipairs(self.Containers:byRole("storage", "item", "out")) do
        for _, stack in ipairs(self.Containers:stacks(storageName)) do
            if self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
                local available = self.Containers:safeTakeAmount(storageName, stack.slot,
                    { name = stack.name, nbt = stack.nbt })
                if available > 0 and (not best or available > best.available) then
                    best = { kind = "item", id = stack.name, nbt = stack.nbt, available = available }
                end
            end
        end
    end
    for _, storageName in ipairs(self.Containers:byRole("storage", "fluid", "out")) do
        for _, tank in ipairs(self.Containers:tanks(storageName)) do
            if self.Filter:specMatches(spec, { kind = "fluid", name = tank.name }) then
                local available = self.Containers:fluidAvailable(storageName, tank.name)
                if available > 0 and (not best or available > best.available) then
                    best = { kind = "fluid", id = tank.name, available = available }
                end
            end
        end
    end
    return best
end

-- How a request of `want` of `item` is spread over the free slots of `containerNames`
-- (the storage containers or a machine's input containers). Empty slots count by their
-- slot multiplier, busy slots are skipped, and at most SEND_SPREAD_MAX moves are
-- planned per attempt; the remainder is retried once the first moves reported.
function Recipe:planTargetSlots(item, want, containerNames)
    local plan, why, remaining = {}, nil, math.max(0, math.floor(tonumber(want) or 0))
    for _, name in ipairs(containerNames or {}) do
        if remaining <= 0 or #plan >= SEND_SPREAD_MAX then
            break
        end
        local slots, slotWhy = self.Containers:pickTargetSlots(name, item)
        if slots then
            for _, entry in ipairs(slots) do
                if remaining <= 0 or #plan >= SEND_SPREAD_MAX then
                    break
                end
                local chunk = math.min(remaining, entry.free)
                if chunk > 0 then
                    plan[#plan + 1] = { target = name, slot = entry.slot, count = chunk }
                    remaining = remaining - chunk
                end
            end
        else
            why = why or slotWhy
        end
    end
    return plan, why
end

function Recipe:sendToMachine(spec, itemTargets, fluidTargets, toSlot, amount, token, opts)
    opts = opts or {}
    if amount <= 0 then
        return 0, nil
    end
    local settled, settleReason = self:settleInFlightMove(token)
    if settled ~= nil then
        return settled, settleReason
    end
    if settleReason == "pending" then
        return nil, "pending"
    end
    if type(spec) ~= "table" then
        return 0, nil
    end
    if spec.kind == "filter" then
        -- A filter input names a filter, not an item: pick the concrete storage
        -- resource with the most to give (mirrors the output side) so that the
        -- move below names a real item instead of the filter itself.
        local concrete = self:resolveFilterSource(spec)
        if not concrete then
            return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_STORAGE_MISSING,
                { item = tostring(spec.id) })
        end
        spec = { kind = concrete.kind, id = concrete.id, nbt = concrete.nbt, ignoreNbt = false }
    end
    local kind = (spec.kind == "fluid") and "fluid" or "item"
    local item = { name = spec.id, nbt = spec.nbt }
    local inputTargets = (kind == "fluid") and (fluidTargets or {}) or (itemTargets or {})
    if #inputTargets == 0 then
        return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_INPUT_CONTAINER)
    end
    local fromContainer, fromSlot, available, reason
    if kind == "fluid" then
        for _, storageName in ipairs(self.Containers:byRole("storage", "fluid", "out")) do
            local have = self.Containers:fluidAvailable(storageName, spec.id)
            if have > 0 then
                fromContainer, available = storageName, have
                break
            end
        end
        if not fromContainer then
        return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_STORAGE_MISSING, { item = tostring(spec.id) })
        end
    else
        for _, storageName in ipairs(self.Containers:byRole("storage", "item", "out")) do
            local slot, why, avail = self.Containers:pickSourceSlot(storageName, item, opts.storageOrder)
            if slot then
                fromContainer, fromSlot, available = storageName, slot, avail
                break
            end
            reason = reason or why
        end
        if not fromContainer then
        return 0, reason or self.Message.msg(self.Message.KEYS.RECIPE_ERR_STORAGE_MISSING, { item = tostring(spec.id) })
        end
    end
    local want = math.min(math.floor(amount), math.floor(available or amount))
    if want <= 0 then
            return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_STORAGE_MISSING, { item = tostring(spec.id) })
    end
    -- Target selection: an element that pins a slot keeps that single (target, slot)
    -- pair; otherwise the request is spread over the free slots of the input
    -- containers and sent as several parallel moves, so a large batch no longer has
    -- to be pushed through one slot (and one move) at a time.
    if kind == "fluid" then
        local target = inputTargets[1]
        local key, keyErr = self.Containers:sendFluid(fromContainer, target, spec.id, want)
        if not key then
            return 0, keyErr
        end
        self:trackMoveKey(token, key)
        return nil, "pending"
    end
    local explicitSlot = tonumber(toSlot)
    local plan, why
    if explicitSlot and explicitSlot >= 1 then
        plan = { { target = inputTargets[1], slot = explicitSlot, count = want } }
    else
        plan, why = self:planTargetSlots(item, want, inputTargets)
        if #plan == 0 then
            return 0, why or self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_INPUT_CONTAINER)
        end
    end
    local submitted, lastErr = 0, nil
    for _, move in ipairs(plan) do
        local key, keyErr = self.Containers:sendItem(fromContainer, fromSlot, move.target, move.slot,
            item, move.count)
        if key then
            self:trackMoveKey(token, key)
            submitted = submitted + move.count
        else
            lastErr = lastErr or keyErr
        end
    end
    if submitted <= 0 then
        return 0, lastErr or self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_INPUT_CONTAINER)
    end
    return nil, "pending"
end


-- How much of `spec` one machine target holds right now. Read-only: the panel and the
-- diagnose tool show this, the engine itself never credits it as input progress (input
-- progress comes from the move results only, see Recipe:stepInput).
local function availableInTarget(self, name, kind, spec, slot)
    if not name then
        return 0
    end
    -- A slot only exists inside item containers: a fluid target keeps counting the
    -- whole container (fluids ignore the slot field).
    if slot then
        local stack = self.Containers:stackAt(name, slot)
        if stack and self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
            return tonumber(stack.count) or 0
        end
        return 0
    end
    return self.Containers:countIn(name, spec)
end

function Recipe:alreadyInTargets(spec, itemTargets, fluidTargets, element)
    local total = 0
    local seen = {}
    local slot = (type(element) == "table"
        and (element.kind == "item" or element.kind == "filter")) and tonumber(element.slot) or nil
    if slot and slot < 1 then
        slot = nil
    end
    local function collect(name, kind)
        if not name or seen[name] then
            return
        end
        seen[name] = true
        total = total + availableInTarget(self, name, kind, spec, (kind == "item") and slot or nil)
    end
    for _, target in ipairs(itemTargets or {}) do
        collect(target, "item")
    end
    for _, target in ipairs(fluidTargets or {}) do
        collect(target, "fluid")
    end
    return total
end

-- (claimInTargets is gone: the input phase no longer books what already sits in the
-- machine input container as progress - that double counted the items this very batch
-- had delivered and let slots look full while they were short. Input progress comes
-- from the move results only, see Recipe:stepInput.)

-- (machineHasPending is gone: it answered "the machine already holds the input" from the
-- container content, the same non-move source the input phase no longer uses.)

function Recipe:transferFailureReason(machine, element, itemTargets, fluidTargets, reason)
    if not machine then
        return reason or self.Message.msg(self.Message.KEYS.RECIPE_ERR_MACHINE_NOT_USABLE)
    end
    local kind = (element.kind == "fluid") and "fluid" or "item"
    local targets = (kind == "fluid") and fluidTargets or itemTargets
    local all = (kind == "fluid") and (machine.fluidInputs or {}) or (machine.itemInputs or {})
    local label = (kind == "fluid") and self.Message.msg(self.Message.KEYS.RECIPE_LABEL_FLUID_INPUTS_FULL)
        or self.Message.msg(self.Message.KEYS.RECIPE_LABEL_ITEM_INPUTS_FULL)
    if #targets == 0 then
        return self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINE_NO_INPUTS, { machine = machine.name, label = label })
    end
    local index = tonumber(element.containerIndex) or -1
    if index >= 1 and not all[index] then
        return self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINE_NO_INPUT_INDEX, { machine = machine.name, index = index, label = label })
    end
        return reason or self.Message.msg(self.Message.KEYS.RECIPE_ERR_CANNOT_SEND, {
            item = tostring(element.id),
            machine = machine.name,
        })
end

-- A filter output element is not one resource, but the mover needs a concrete
-- item/fluid per move: look at what the machine's output containers hold right
-- now and take the matching resource with the most to give. All the counting
-- (machineRemaining, storageGain, the batch targets) stays filter based.
-- opts.containerIndex / opts.slot narrow the search to one output container /
-- one slot, so an element can pin exactly where it extracts from.
function Recipe:resolveFilterOutput(spec, machine, opts)
    local scopeIndex, scopeSlot = outputScopeOf(opts)
    local best
    for _, source in ipairs(self:outputContainers(machine, "item", scopeIndex)) do
        local peripheralName = self.Containers:peripheralOf(source, "item")
        if peripheralName then
            for _, stack in ipairs(self.Containers:stacksPeripheral(peripheralName)) do
                local name = stack.name
                if (not scopeSlot or tonumber(stack.slot) == scopeSlot)
                    and type(name) == "string" and name ~= ""
                    and self.Filter:specMatches(spec, { kind = "item", name = name, nbt = stack.nbt }) then
                    local available = self.Containers:safeTakeAmount(source, stack.slot,
                        { name = name, nbt = stack.nbt })
                    if available > 0 and (not best or available > best.available) then
                        best = { kind = "item", id = name, nbt = stack.nbt, slot = stack.slot,
                            available = available }
                    end
                end
            end
        end
    end
    for _, source in ipairs(self:outputContainers(machine, "fluid", scopeIndex)) do
        local peripheralName = self.Containers:peripheralOf(source, "fluid")
        if peripheralName then
            for _, tank in ipairs(self.Containers:tanksPeripheral(peripheralName)) do
                local name = tank.name
                if type(name) == "string" and name ~= ""
                    and self.Filter:specMatches(spec, { kind = "fluid", name = name }) then
                    local available = self.Containers:fluidAvailable(source, name)
                    if available > 0 and (not best or available > best.available) then
                        best = { kind = "fluid", id = name, available = available }
                    end
                end
            end
        end
    end
    return best
end

function Recipe:takeFromMachine(spec, machine, amount, token, opts)
    opts = opts or {}
    if amount <= 0 then
        return 0, nil
    end
    local settled, settleReason = self:settleInFlightMove(token)
    if settled ~= nil then
        return settled, settleReason
    end
    if settleReason == "pending" then
        return nil, "pending"
    end
    if type(spec) ~= "table" then
        return 0, nil
    end
    -- The element may pin the output container / the slot inside it; an empty
    -- scope (-1) keeps the old "any output container" behaviour.
    local scopeIndex, scopeSlot = outputScopeOf(opts)
    local scoped = scopeIndex ~= nil or scopeSlot ~= nil
    if spec.kind == "filter" then
        local concrete = self:resolveFilterOutput(spec, machine, opts)
        if not concrete then
            if scoped then
                -- The pinned container/slot holds nothing matching the filter:
                -- that is "nothing to take yet", not an error.
                return 0, nil
            end
            return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE,
                { container = tostring(machine and machine.name), item = tostring(spec.id) })
        end
        spec = { kind = concrete.kind, id = concrete.id, nbt = concrete.nbt }
        if scopeSlot == nil then
            -- The filter resolved to one concrete stack: keep extracting from
            -- that slot so a single filter move never spreads over slots.
            scopeSlot = tonumber(concrete.slot)
            if scopeSlot and scopeSlot < 1 then
                scopeSlot = nil
            end
        end
    end
    local kind = (spec.kind == "fluid") and "fluid" or "item"
    local item = { name = spec.id, nbt = spec.nbt }
    -- Without a pinned container/slot any output container that really holds the
    -- wanted resource is used, so the item does not have to sit in the first one.
    -- A pinned scope still limits the search to that container/slot.
    local sources = self:outputContainers(machine, kind, scopeIndex) or {}
    if #sources == 0 then
        return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_OUTPUT_CONTAINER,
            { machine = tostring(machine and machine.name) })
    end
    -- Size the move to what the machine really offers right now: queueItemMove
    -- rejects a move whose source slot holds less than the requested amount
    -- (assertItemSource), so asking for the whole batch while the machine has
    -- only a few pieces would be retried every tick and never move anything.
    local source, fromSlot, available, sourceWhy
    for _, name in ipairs(sources) do
        if kind == "fluid" then
            local have = self.Containers:fluidAvailable(name, spec.id)
            if have > 0 then
                source, available = name, have
                break
            end
            sourceWhy = sourceWhy or self.Message.msg(self.Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE,
                { container = tostring(name), item = tostring(spec.id) })
        else
            -- opts.fromSlot is the legacy name (a resolver already picked the slot);
            -- the element's own slot arrives through the scope above.
            local slot = tonumber(opts.fromSlot) or scopeSlot
            if slot and slot >= 1 then
                local safe = self.Containers:safeTakeAmount(name, slot, item)
                if safe > 0 then
                    source, fromSlot, available = name, slot, safe
                    break
                end
            else
                local picked, pickedWhy, safe = self.Containers:pickSourceSlot(name, item,
                    self.Containers.ORDER_SPEED)
                if picked then
                    source, fromSlot, available = name, picked, safe
                    break
                end
                sourceWhy = sourceWhy or pickedWhy
            end
        end
    end
    if not source then
        if scoped then
            -- A pinned container/slot holds nothing matching: "nothing to take
            -- yet", not an error.
            return 0, nil
        end
        return 0, sourceWhy or self.Message.msg(self.Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE,
            { container = tostring(machine and machine.name), item = tostring(spec.id) })
    end
    local want = math.max(1, math.floor(amount))
    if available and available < want then
        want = math.floor(available)
    end
    if want <= 0 then
        if scoped then
            -- A pinned container/slot that simply does not hold the wanted item:
            -- treat it as "nothing taken this tick" instead of an error.
            return 0, nil
        end
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE,
            { container = tostring(source), item = tostring(spec.id) })
    end
    local target, targetSlot, why
    if kind == "fluid" then
        target = (self.Containers:byRole("storage", "fluid", "in") or {})[1]
        if not target then
        return 0, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_FLUID_STORAGE)
        end
    else
        for _, storageName in ipairs(self.Containers:byRole("storage", "item", "in")) do
            local slot, reason = self.Containers:pickTargetSlot(storageName, item, want)
            if slot then
                target, targetSlot = storageName, slot
                break
            end
            why = why or reason
        end
        if not target then
        return 0, why or self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_TARGET_SLOT)
        end
    end
    self:stallLog("out-take %s %s slot=%s requested=%d available=%s -> taking %d",
        tostring(machine and machine.name), tostring(spec.id), tostring(fromSlot), math.floor(amount),
        available and tostring(math.floor(available)) or "n/a", want)
    local key, keyErr
    if kind == "fluid" then
        key, keyErr = self.Containers:takeFluid(source, target, spec.id, want)
    else
        key, keyErr = self.Containers:takeItem(source, fromSlot, target, targetSlot, item, want)
    end
    if not key then
        return 0, keyErr
    end
    self:trackMoveKey(token, key)
    return nil, "pending"
end

-- Unordered IO: a machine output can sit in several slots of one or more output
-- containers. Instead of one move per tick, this submits one move per source slot at
-- once - each under its own token ("<token>\1<container>:<slot>") - so the extraction
-- of one element runs in parallel. Recipe:settleInFlightMoves adds the results back
-- up; Recipe:inflightWantOf reports what is still on the way so a later attempt does
-- not request it again.
-- Returns (nil, "pending") while moves are in flight, (0, reason) when nothing could
-- be submitted, and (nil, "fallback") when the caller has to use the single-move path
-- instead (fluid or filter outputs, a pinned container/slot).
function Recipe:takeFromMachineMulti(spec, machine, amount, token, opts)
    opts = opts or {}
    if type(spec) ~= "table" or spec.kind ~= "item" then
        return nil, "fallback"
    end
    local scopeIndex, scopeSlot = outputScopeOf(opts)
    if scopeIndex ~= nil or scopeSlot ~= nil then
        return nil, "fallback"
    end
    local prefix = tostring(token) .. "\1"
    local want = math.max(0, math.floor(tonumber(amount) or 0))
    local onTheWay = self:inflightWantOf(prefix)
    if want <= 0 or onTheWay >= want then
        return nil, "pending"
    end
    local item = { name = spec.id, nbt = spec.nbt }
    local remaining, submitted, reason = want - onTheWay, 0, nil
    for _, source in ipairs(self:outputContainers(machine, "item") or {}) do
        if remaining <= 0 then
            break
        end
        local slots, slotsWhy = self.Containers:pickSourceSlots(source, item, self.Containers.ORDER_SPEED)
        if not slots then
            reason = reason or slotsWhy
        else
            for _, entry in ipairs(slots) do
                if remaining <= 0 then
                    break
                end
                local take = math.min(remaining, math.floor(tonumber(entry.available) or 0))
                if take > 0 then
                    local moveToken = prefix .. tostring(source) .. ":" .. tostring(entry.slot)
                    local plan, targetWhy = self:planTargetSlots(item, take,
                        self.Containers:byRole("storage", "item", "in"))
                    if #plan == 0 then
                        reason = reason or targetWhy
                            or self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_TARGET_SLOT)
                    else
                        local movedHere = 0
                        for _, move in ipairs(plan) do
                            local key, keyErr = self.Containers:takeItem(source, entry.slot, move.target,
                                move.slot, item, move.count)
                            if key then
                                self:trackMoveKey(moveToken, key)
                                movedHere = movedHere + move.count
                            else
                                reason = reason or keyErr
                            end
                        end
                        if movedHere > 0 then
                            self:noteInflightWant(moveToken, movedHere)
                            submitted = submitted + movedHere
                            remaining = remaining - movedHere
                            self:stallLog("out-take-multi %s %s %s#%d -> %d slot(s) x%d",
                                tostring(machine and machine.name), tostring(spec.id), tostring(source),
                                entry.slot, #plan, movedHere)
                        end
                    end
                end
            end
        end
    end
    if submitted > 0 then
        return nil, "pending"
    end
    return 0, reason
end

-- Every container with the "input" role is drained into storage: for each stack /
-- tank of its snapshot that is not dirty, one take move is created. The "not dirty"
-- check doubles as de-duplication, because creating a move marks the source slot
-- dirty and claims the target slot, so the same stack is not submitted again until
-- that move settles. Moves go through the existing inventoryIn ("stock in") queue.
function Recipe:drainInputContainers(now)
    local stats = self.inputDrainStats
    if not stats then
        stats = { containers = 0, moves = 0, skipped = 0, noTarget = 0 }
        self.inputDrainStats = stats
    end
    local Containers = self.Containers
    if not Containers then
        return 0
    end
    for _, containerName in ipairs(Containers:byRole("input", "item")) do
        local def = self.Store:findContainer(containerName, "item")
        local peripheralName = def and def.peripheral or nil
        if peripheralName and Containers:hasSnapshot(peripheralName) then
            stats.containers = stats.containers + 1
            for _, stack in ipairs(Containers:stacks(containerName)) do
                if Containers:slotBusy(peripheralName, stack.slot) then
                    stats.skipped = stats.skipped + 1
                else
                    local amount = math.max(1, math.floor(tonumber(stack.count) or 0))
                    local item = { name = stack.name, nbt = stack.nbt }
                    local done = false
                    for _, storageName in ipairs(Containers:byRole("storage", "item", "in")) do
                        local slot = Containers:pickTargetSlot(storageName, item, amount)
                        if slot then
                            local key = Containers:takeItem(containerName, stack.slot,
                                storageName, slot, item, amount)
                            if key then
                                done = true
                                break
                            end
                        end
                    end
                    if done then
                        stats.moves = stats.moves + 1
                    else
                        stats.noTarget = stats.noTarget + 1
                        break
                    end
                end
            end
        end
    end
    for _, containerName in ipairs(Containers:byRole("input", "fluid")) do
        local def = self.Store:findContainer(containerName, "fluid")
        local peripheralName = def and def.peripheral or nil
        if peripheralName and Containers:snapshotComplete(peripheralName, "fluid") then
            stats.containers = stats.containers + 1
            for _, tank in ipairs(Containers:tanks(containerName)) do
                if Containers:fluidAvailable(containerName, tank.name) <= 0 then
                    stats.skipped = stats.skipped + 1
                else
                    local amount = math.max(1, math.floor(tonumber(tank.amount) or 0))
                    local done = false
                    for _, storageName in ipairs(Containers:byRole("storage", "fluid", "in")) do
                        local key = Containers:takeFluid(containerName, storageName, tank.name, amount)
                        if key then
                            done = true
                            break
                        end
                    end
                    if done then
                        stats.moves = stats.moves + 1
                    else
                        stats.noTarget = stats.noTarget + 1
                        break
                    end
                end
            end
        end
    end
    return stats.moves
end


-- How much of `spec` the machine still holds *inside the element's scope*: an
-- element that pins a container/slot must not be kept waiting by matching
-- resources sitting somewhere else, or the output phase could never complete.
function Recipe:machineRemaining(spec, machine, opts)
    local scopeIndex, scopeSlot = outputScopeOf(opts)
    local total = 0
    if spec.kind ~= "fluid" then
        for _, source in ipairs(self:outputContainers(machine, "item", scopeIndex)) do
            local peripheralName = self.Containers:peripheralOf(source, "item")
            if peripheralName then
                for _, stack in ipairs(self.Containers:stacksPeripheral(peripheralName)) do
                    if (not scopeSlot or tonumber(stack.slot) == scopeSlot)
                        and self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
                        total = total + stack.count
                    end
                end
            end
        end
    end
    if spec.kind ~= "item" then
        for _, source in ipairs(self:outputContainers(machine, "fluid", scopeIndex)) do
            local peripheralName = self.Containers:peripheralOf(source, "fluid")
            if peripheralName then
                for _, tank in ipairs(self.Containers:tanksPeripheral(peripheralName)) do
                    if self.Filter:specMatches(spec, { kind = "fluid", name = tank.name }) then
                        total = total + tank.amount
                    end
                end
            end
        end
    end
    return total
end

function Recipe:availableFor(element)
    local total = self.Containers:countOf(elementSpec(element), "storage")
    return total
end

function Recipe:batchMaterialsReady(process, record)
    local batch = self.Assert.count(record.multiplier or record.batch, "record.multiplier")
    local progress = record.progress or {}
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            -- A skippable input never blocks readiness: it gets its one attempt in
            -- Recipe:stepInput, which marks it skipped when it cannot be delivered.
            if not element.skip then
                local required = elementDemand(element, batch)
                local done_ = progress[tostring(index)] or 0
                if done_ < required then
                    local available = self:availableFor(element)
                    if available < (required - done_) then
                        return false, element, (required - done_) - available, index
                    end
                end
            end
        end
    end
    return true
end

function Recipe:outputMatchesInput(output, element)
    if element.kind == "item" then
        if output.kind == "item" then
            return output.id == element.id
        end
        if output.kind == "filter" then
            return self.Filter:matches(output.id, { kind = "item", name = element.id })
        end
        return false
    elseif element.kind == "fluid" then
        if output.kind == "fluid" then
            return output.id == element.id
        end
        if output.kind == "filter" then
            return self.Filter:matches(output.id, { kind = "fluid", name = element.id })
        end
        return false
    elseif element.kind == "filter" then
        if output.kind == "item" then
            return self.Filter:matches(element.id, { kind = "item", name = output.id })
        end
        if output.kind == "fluid" then
            return self.Filter:matches(element.id, { kind = "fluid", name = output.id })
        end
        if output.kind == "filter" then
            -- A process that outputs that very filter is a direct producer for it.
            -- (Automatic containment is display-only: it is drawn in the dependency
            -- graph, but it does not make the process a producer for the filter.)
            return output.id == element.id
        end
        if output.kind == "placeholder" then
            -- Same rule as upstreamCandidates: the placeholder stands for one item.
            return type(output.item) == "string" and output.item ~= "" and
                self.Filter:matches(element.id, { kind = "item", name = output.item })
        end
        return false
    end
    return false
end

-- (upstreamCandidates / clearRequest / releaseInstanceRequests are gone: the
-- material ledger owns every demand now, so instances no longer carry request
-- ledgers and no code writes into another process' counters.)

-- (chooseUpstream / requestUpstream are gone with the instance request ledger.)

-- An input phase ran out of material. The shortage itself is *not* booked here:
-- the planning engine reads the same shortage off the material ledger (that is
-- what automateCount counts) and picks a producer for it. This only records the
-- state the panel shows, and it answers whether the batch can go on now.
-- Are all the material inputs of this instance fully delivered? The unordered IO
-- mode keeps the instance alive until this is true, even when every output is
-- already out.
function Recipe:inputsSatisfied(process, record)
    local batch = self:batchOf(record)
    local progress = record.progress or {}
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            local required = elementDemand(element, batch)
            if (tonumber(progress[tostring(index)]) or 0) < required then
                return false
            end
        end
    end
    return true
end

function Recipe:noteMaterialShortage(process, record, now)
    record.checkedAt = now
    local ready, element = self:batchMaterialsReady(process, record)
    if ready then
        return true
    end
    record.wait = { kind = "materials" }
    local hasProducer = true
    if element then
        local key = self:materialKeyOf(self:specOfElement(element))
        local producers = self:craftIndex()[key]
        hasProducer = producers ~= nil and #producers > 0
    end
    if hasProducer then
        record.state = "waiting"
        record.lastError = self.Message.msg(self.Message.KEYS.RECIPE_WAIT_UPSTREAM)
    else
        -- Nothing can make that material: park the batch in "missing" so the panel
        -- shows why it will never move.
        record.state = "missing"
        record.lastError = self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_UPSTREAM)
    end
    self.Cache:markDirty()
    return false
end

function Recipe:storageBaseline()
    local baseline = {}
    for _, entry in ipairs(self.Containers:resources()) do
        baseline[entry.kind .. ":" .. entry.name] = entry.count
    end
    return baseline
end

function Recipe:stepInput(process, record, machine, now)
    local inputs = process.inputs or {}
    local budget = self.stepBudget
    record.progress = record.progress or {}
    if record.pulse and not self:advancePulse(record, now) then
        return
    end
    -- "unordered IO": the material operations inside one block (a block ends at a
    -- wait/signal op) are moved in parallel instead of one after the other. The
    -- barriers keep their order and the phase only switches once every block is
    -- satisfied, so a timer between two groups still splits them apart.
    local unordered = processBlockParallel(process)
    local firstShort = nil
    local shortageChecked = false
    -- One attempt for a single material input. Returns "done" (satisfied),
    -- "retry" (moved something but still short) or "park" (nothing to do now).
    local attempt = function(element, index, key)
        local required = elementDemand(element, self:batchOf(record))
        if element.skip and record.skipDone and record.skipDone[key] then
            -- Already attempted once for this instance: it is off the table, do not retry.
            return "done"
        end
        local ownerKey = "process:" .. tostring(process.name) .. "#" .. tostring(record.id or 0)
        -- The instance reserved its whole batch on creation (Containers:claim). Every
        -- successful input gives that exact slice back, so the claim shrinks with the
        -- material actually consumed instead of staying at the batch size.
        local function releaseInputClaim(element, amount)
            amount = math.floor(tonumber(amount) or 0)
            if amount <= 0 then
                return
            end
            local elementSpec = self:specOfElement(element)
            if elementSpec then
                self.Containers:releaseClaimAmount(elementSpec, amount, ownerKey)
            end
        end
        -- "Skippable": the input got its one attempt; whatever could not be delivered is
        -- skipped (recorded so it is not attempted again) and the batch moves on.
        local function markSkipped(transferred)
            record.skipDone = record.skipDone or {}
            record.skipDone[key] = true
            record.progress[key] = required
            if record.inflight then
                record.inflight[key] = nil
            end
            self.Cache:markDirty()
            self.debugInfo("input %s#%d %s skipped (skippable, delivered %d/%d)",
                tostring(process.name), index, tostring(element.id), tonumber(transferred) or 0, required)
        end
        local inflightToken = "in:" .. tostring(process.name) .. "#" .. tostring(record.id or 0) .. "\1"
            .. tostring(key)
        local settledMove, settledReason = self:settleInFlightMove(inflightToken)
        if settledMove == nil and settledReason == "pending" then
            self:stallLog("input-wait %s#%d %s progress=%d required=%d inflight=%d (waiting for settle)",
                tostring(process.name), index, tostring(element.id), record.progress[key] or 0, required,
                tonumber((record.inflight or {})[key]) or 0)
            return "park"
        end
        if settledMove ~= nil then
            settledMove = tonumber(settledMove) or 0
            record.inflight = record.inflight or {}
            record.inflight[key] = nil
            if settledMove > 0 then
                record.progress[key] = (record.progress[key] or 0) + settledMove
                releaseInputClaim(element, settledMove)
                self.Cache:markDirty()
            end
        end
        local transferred = record.progress[key] or 0
        if transferred >= required then
            return "done"
        end
        local spec = elementSpec(element)
        local itemTargets = self:inputContainers(machine, "item", element.containerIndex)
        local fluidTargets = self:inputContainers(machine, "fluid", element.containerIndex)
        local inflight = tonumber((record.inflight or {})[key]) or 0
        local short = required - transferred - inflight
        if short <= 0 then
            self:stallLog("input-wait %s#%d %s progress=%d required=%d inflight=%d (waiting for settle)",
                tostring(process.name), index, tostring(element.id), transferred, required, inflight)
            return "park"
        end
        -- Input is credited only by move results: the returns of settleInFlightMove
        -- above and of sendToMachine below. What already sits in the machine input
        -- container is deliberately NOT counted - it cannot be told apart from what
        -- this very batch just delivered, which credited the same item twice and let
        -- a slot look full while it was still short.
        local ready = self:batchMaterialsReady(process, record)
        if not ready then
            -- One shortage scan per tick is enough: it always inspects the first
            -- short element, so asking again for a later element in the same tick
            -- would request the very same upstream demand twice.
            if shortageChecked or not self:noteMaterialShortage(process, record, now) then
                return "park"
            end
            shortageChecked = true
        end
        local moved, reason = self:sendToMachine(
            spec,
            itemTargets,
            fluidTargets,
            ((element.kind == "item" or element.kind == "filter") and element.slot or nil),
            short,
            inflightToken,
            { storageOrder = self.Containers.ORDER_SPEED }
        )
        if reason == "pending" then
            record.inflight = record.inflight or {}
            record.inflight[key] = short
            moved = tonumber(moved) or 0
            if moved > 0 then
                record.progress[key] = (record.progress[key] or 0) + moved
                releaseInputClaim(element, moved)
                self.Cache:markDirty()
            end
            return "park"
        end
        moved = tonumber(moved) or 0
        budget = budget - 1
        if record.inflight then
            record.inflight[key] = nil
        end
        transferred = transferred + moved
        record.progress[key] = transferred
        if moved > 0 then
            releaseInputClaim(element, moved)
        end
        self:debugInfo("input %s#%d %s slot=%s moved=%d progress=%d/%d reason=%s",
            tostring(process.name), index, tostring(element.id), tostring(element.slot),
            moved, transferred, required, self.Message.describe(reason))
        if moved > 0 and record.lastError ~= nil and transferred >= required then
            record.lastError = nil
        end
        self.Cache:markDirty()
        if transferred < required then
            if element.skip then
                -- One attempt is all a skippable input gets.
                markSkipped(transferred)
                return "done"
            end
            if moved <= 0 then
                local stallText = self:transferFailureReason(machine, element, itemTargets, fluidTargets, reason)
                if record.lastError ~= stallText then
                    record.lastError = stallText
                    self.Cache:markDirty()
                end
                if now - (record.lastStallAt or 0) >= 5000 then
                    record.lastStallAt = now
                    self.log("Process %s stalled at input %s: %s", process.name, tostring(element.id), stallText)
                end
                return "park"
            end
            return "retry"
        end
        return "done"
    end
    local index = self:indexOf(record)
    while index <= #inputs and budget > 0 do
        local element = inputs[index]
        local key = tostring(index)
        if firstShort ~= nil and not isMaterialElement(element) then
            -- a wait/signal op stands in front of an unfinished block: the block
            -- has to finish first (that is what keeps the blocks apart)
            record.index = firstShort
            self.Cache:markDirty()
            return
        end
        if element.kind == "waitTime" then
            local batch = self:batchOf(record)
            record.wait = {
                kind = "time",
                untilMs = now + math.floor((tonumber(element.seconds) or 0) * 1000 * batch),
            }
            record.index = index + 1
            self.Cache:markDirty()
            return
        elseif element.kind == "waitSignal" then
            if not self:signalSatisfied(machine, element) then
                record.wait = { kind = "signal", element = element }
                record.index = index
                self.Cache:markDirty()
                return
            end
            index = index + 1
        elseif element.kind == "emitSignal" then
            self:emitSignals(machine, element)
            index = index + 1
            budget = budget - 1
        elseif element.kind == "emitPulse" then
            index = index + 1
            budget = budget - 1
            self:startPulse(machine, element, record, now, index)
            record.index = index
            self.Cache:markDirty()
            if record.pulse then
                return
            end
        elseif element.kind == "placeholder" then
            index = index + 1
        else
            local status = attempt(element, index, key)
            if status == "done" then
                index = index + 1
            elseif unordered then
                -- park the earliest unfinished element and let the rest of this
                -- block keep moving; it is revisited on the next tick
                if firstShort == nil or index < firstShort then
                    firstShort = index
                end
                index = index + 1
            elseif status == "retry" then
                record.index = index
            else
                record.index = index
                return
            end
        end
    end
    if firstShort ~= nil then
        -- unordered IO: the scan walked past unfinished material elements, so the
        -- record parks on the earliest one and the input phase continues
        record.index = firstShort
        self.Cache:markDirty()
        return
    end
    if index > #inputs then
        if self.Store.isTurtleCrafter(machine) then
            local inflightKey = self:firstInflightInput(record, inputs)
            if inflightKey then
                record.wait = { kind = "craft", machine = machine.name }
                record.lastError = self.Message.msg(self.Message.KEYS.RECIPE_WAIT_MOVE_SETTLE)
                if now - (record.lastCraftWaitLogAt or 0) >= 10000 then
                    record.lastCraftWaitLogAt = now
                    self.log("Process %s: input %s still has an in-flight move - not crafting yet",
                        tostring(process.name), tostring(inflightKey))
                end
                self.Cache:markDirty()
                return
            end
            local batch = self:batchOf(record)
            local detail = {}
            for elementIndex, element in ipairs(inputs) do
                if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
                    detail[#detail + 1] = tostring(element.id or element.kind) .. "=" ..
                        tostring(record.progress[tostring(elementIndex)] or 0) .. "/" ..
                        tostring(elementDemand(element, batch))
                end
            end
            self.log("Process %s: all inputs settled (batch=%s, %s) - asking %s to craft",
                tostring(process.name), tostring(batch), table.concat(detail, " "),
                tostring(machine.name))
            local status = self:requestMachineCraft(process, record, machine)
            if status ~= "sent" then
                record.wait = { kind = "craft", machine = machine.name }
                record.lastError = self.Message.msg(self.Message.KEYS.RECIPE_WAIT_TURTLE)
                self.Cache:markDirty()
                return
            end
        end
        do
            local batch = self:batchOf(record)
            local parts = {}
            for elementIndex, element in ipairs(inputs) do
                if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
                    parts[#parts + 1] = tostring(element.id) .. "=" ..
                        tostring((record.progress or {})[tostring(elementIndex)] or 0) .. "/" ..
                        tostring(elementDemand(element, batch))
                end
            end
            self:stallLog("in-done %s batch=%d machine=%s inputs=%s", tostring(process.name),
                batch, tostring(machine and machine.name), table.concat(parts, " "))
        end
        record.phase = "output"
        record.inputDone = true
        if processIoMode(process) ~= "unordered" then
            record.index = 1
            record.outProgress = {}
            self:prepareOutputs(process, record)
        end
        self.Cache:markDirty()
    else
        record.index = index
        self.Cache:markDirty()
    end
end

function Recipe:firstInflightInput(record, inputs)
    local inflight = record.inflight or {}
    for elementIndex in ipairs(inputs or {}) do
        if (tonumber(inflight[tostring(elementIndex)]) or 0) > 0 then
            return tostring(elementIndex)
        end
    end
    return nil
end

function Recipe:requestMachineCraft(process, record, machine)
    if type(self.craftProvider) ~= "function" then
        return "sent"
    end
    return self.craftProvider({
        machine = machine.name,
        crafter = machine.name,
        process = process.name,
        batch = record.batch,
        key = table.concat({ tostring(process.name), tostring(record.batch or 0),
            tostring(record.startedAt or 0), tostring(machine.name) }, "|"),
    })
end

function Recipe:setCraftProvider(provider)
    self.craftProvider = provider
end

-- The scheduler handle used for the heavy storage-compact planning pass. Without
-- it, Recipe:autoCompactStep cannot queue that pass and will fail loudly.
function Recipe:setDispatch(dispatch)
    self.dispatch = dispatch
end

function Recipe:prepareOutputs(process, record)
    local batch = self:batchOf(record)
    local baseline = self:storageBaseline()
    local targets = {}
    for _, element in ipairs(process.outputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            targets[#targets + 1] = {
                kind = element.kind,
                id = element.id,
                -- The batch's own numbers: the progress bar is scaled to `target`
                -- (max x batch, the extraction cap) and draws a tick at `min` and at
                -- `expect`, so a finished batch reads correctly even when the machine
                -- still holds more than the expected yield.
                min = (tonumber(element.min) or 0) * batch,
                target = (tonumber(element.max) or 0) * batch,
                expect = (tonumber(element.expect) or tonumber(element.max) or 0) * batch,
                -- storage content before this batch (filter aware); frozen here
                -- so the panel does not have to re-match the filter every push
                baseline = self:baselineCountIn(baseline, element.kind, element.id),
            }
        end
    end
    record.target = targets
    record.baseline = baseline
end

function Recipe:stepOutput(process, record, machine, now)
    self:stallLog("out-enter %s idx=%d/%d batch=%d wait=%s moves=%d",
        tostring(process.name), self:indexOf(record), #(process.outputs or {}),
        self:batchOf(record), tostring(record.wait and record.wait.kind), self:moveKeyCount())
    local outputs = process.outputs or {}
    local budget = self.stepBudget
    record.outProgress = record.outProgress or {}
    if record.pulse and not self:advancePulse(record, now) then
        return
    end
    -- Same "unordered IO" handling as the input phase: the material outputs of one
    -- block (a block ends at a wait/signal op) are extracted in parallel.
    local unordered = processBlockParallel(process)
    local firstShort = nil
    -- One attempt for a single material output element. Returns "done"
    -- (satisfied), "retry" (moved something but still short) or "park".
    local attempt = function(element, index, key)
        local batch = self:batchOf(record)
        local maxAmount = (tonumber(element.max) or 0) * batch
        local minAmount = (tonumber(element.min) or 0) * batch
        local collected = record.outProgress[key] or 0
        local spec = elementSpec(element)
        local token = "out:" .. tostring(process.name) .. "#" .. tostring(record.id or 0) .. "\1" .. tostring(key)
        -- Unordered IO without a pinned container/slot extracts from *every* source
        -- slot of this element at once: each move gets its own token under `token`,
        -- and settling them together (below) keeps the bookkeeping in one place.
        local multi = unordered and element.kind == "item"
        if multi then
            local scopeIndex, scopeSlot = outputScopeOf({ containerIndex = element.containerIndex,
                slot = element.slot })
            multi = (scopeIndex == nil and scopeSlot == nil)
        end
        -- The extraction of this element runs asynchronously: takeFromMachine only
        -- queues a move and reports "pending" until the transfer subsystem answers.
        -- That answer is the only thing that counts as "this batch produced it", so it
        -- is collected here - before anything below can mark the element as finished
        -- (once finished nobody asks for that move again, and the instance cleanup
        -- would release its result as 0).
        local settled, settledErr
        if multi then
            settled = self:settleInFlightMoves(token .. "\1")
        else
            settled, settledErr = self:settleInFlightMove(token)
        end
        if settled ~= nil then
            if settled > 0 then
                collected = collected + settled
                record.outProgress[key] = collected
                self.Cache:markDirty()
            end
            self:debugInfo("out-settle %s idx=%d moved=%d -> %d/%d err=%s", tostring(process.name), index,
                settled, collected, maxAmount, self.Message.describe(settledErr))
        end
        self:stallLog("out-trace %s idx=%d/%d collected=%d max=%d min=%d moved_last=%s",
            tostring(process.name), index, #outputs, collected, maxAmount, minAmount,
            tostring(record.outLastMoved))
        if collected >= maxAmount then
            self:stallLog("out-advance %s idx=%d -> %d (collected=%d/%d)", tostring(process.name), index,
                index + 1, collected, maxAmount)
            return "done"
        end
        local moved, reason
        if multi then
            moved, reason = self:takeFromMachineMulti(spec, machine, maxAmount - collected, token,
                { containerIndex = element.containerIndex, slot = element.slot })
            if reason == "fallback" then
                multi = false
            end
        end
        if not multi then
            moved, reason = self:takeFromMachine(spec, machine, maxAmount - collected, token,
                { containerIndex = element.containerIndex, slot = element.slot })
        end
        if reason == "pending" then
            local booked = tonumber(moved) or 0
            if booked > 0 then
                record.outProgress[key] = collected + booked
                self.Cache:markDirty()
            end
            return "park"
        end
        budget = budget - 1
        record.outLastMoved = moved
        if moved > 0 then
            record.outProgress[key] = collected + moved
            record.lastError = nil
            if collected + moved >= maxAmount then
                self:stallLog("out-advance %s idx=%d -> %d (moved=%d -> %d/%d)",
                    tostring(process.name), index, index + 1, moved, collected + moved, maxAmount)
                self.Cache:markDirty()
                return "done"
            end
            self.Cache:markDirty()
            return "retry"
        end
        local leftover = self:machineRemaining(spec, machine,
            { containerIndex = element.containerIndex, slot = element.slot })
        self:stallLog("out-blocked %s leftover=%d reason=%s collected=%d min=%d max=%d " ..
            "batch=%d idx=%d state=%s wait=%s",
            tostring(process.name), leftover, self.Message.describe(reason), collected, minAmount, maxAmount,
            tonumber(record.batch) or 0, index, tostring(record.state),
            tostring(record.wait and record.wait.kind))
        if leftover <= 0 and collected >= minAmount then
            return "done"
        end
        if leftover > 0 then
            local outText = self:messageOf(self.Message.KEYS.RECIPE_ERR_OUTPUT_STUCK, {
                machine = tostring(machine.name),
                item = tostring(element.id),
                reason = reason and self.Message.reason(reason)
                    or self.Message.msg(self.Message.KEYS.RECIPE_ERR_MOVE_FAILED),
            })
            if record.lastError ~= outText then
                record.lastError = outText
                self.Cache:markDirty()
            end
            if now - (record.lastStallAt or 0) >= 5000 then
                record.lastStallAt = now
                self.log("Process %s cannot move output %s out of machine %s: %s",
                    process.name, tostring(element.id), tostring(machine.name), self.Message.describe(reason or "-"))
            end
            return "park"
        end
        if record.lastError == nil or now - (record.lastStallAt or 0) >= 5000 then
            record.lastStallAt = now
            record.lastError = self:messageOf(self.Message.KEYS.RECIPE_WAIT_MACHINE_OUTPUT, {
                machine = tostring(machine.name),
                item = tostring(element.id),
            })
            self.log("Process %s waiting for output %s from machine %s",
                process.name, tostring(element.id), tostring(machine.name))
        end
        self.Cache:markDirty()
        return "park"
    end
    local index = self:indexOf(record)
    while index <= #outputs and budget > 0 do
        local element = outputs[index]
        local key = tostring(index)
        if firstShort ~= nil and not isMaterialElement(element) then
            -- a wait/signal op stands in front of an unfinished block: the block
            -- has to finish first (that is what keeps the blocks apart)
            record.index = firstShort
            self.Cache:markDirty()
            return
        end
        if element.kind == "waitTime" then
            record.wait = {
                kind = "time",
                untilMs = now + math.floor((tonumber(element.seconds) or 0) * 1000),
            }
            record.index = index + 1
            self.Cache:markDirty()
            return
        elseif element.kind == "waitSignal" then
            if not self:signalSatisfied(machine, element) then
                record.wait = { kind = "signal", element = element }
                record.index = index
                self.Cache:markDirty()
                return
            end
            index = index + 1
        elseif element.kind == "emitSignal" then
            self:emitSignals(machine, element)
            index = index + 1
            budget = budget - 1
        elseif element.kind == "emitPulse" then
            index = index + 1
            budget = budget - 1
            self:startPulse(machine, element, record, now, index)
            record.index = index
            self.Cache:markDirty()
            if record.pulse then
                return
            end
        elseif element.kind == "placeholder" then
            index = index + 1
        else
            local status = attempt(element, index, key)
            if status == "done" then
                index = index + 1
            elseif unordered then
                -- park the earliest unfinished element and let the rest of this
                -- block keep moving; it is revisited on the next tick
                if firstShort == nil or index < firstShort then
                    firstShort = index
                end
                index = index + 1
            elseif status == "retry" then
                record.index = index
            else
                record.index = index
                return
            end
        end
    end
    if firstShort ~= nil then
        -- unordered IO: the scan walked past unfinished material elements, so the
        -- record parks on the earliest one and the output phase continues
        record.index = firstShort
        self.Cache:markDirty()
        return
    end
    if index > #outputs then
        if processIoMode(process) == "unordered" and not self:inputsSatisfied(process, record) then
            -- unordered IO: every output is already out, but the inputs are still
            -- being delivered - keep the instance alive until they are complete.
            record.outDone = true
            self.Cache:markDirty()
            return
        end
        self:finishInstance(process, record, now)
    else
        record.index = index
        self:stallLog("out-stall %s idx=%d/%d collected=%d max=%d outLastMoved=%s",
            tostring(process.name), index, #outputs,
            tonumber((record.outProgress or {})[tostring(index)]) or 0,
            (tonumber(outputs[index] and outputs[index].max) or 0) * self:batchOf(record),
            tostring(record.outLastMoved))
        self.Cache:markDirty()
    end
end


-- (retryUpstream is gone: the input phase no longer asks upstream processes for
-- anything, the planning engine does that from the material ledger.)

function Recipe:peripheralProblem(process, record)
    local typeName = process.machineType
    if typeName and typeName ~= "" then
        local machineType = self.Store:get("machineTypes", typeName)
        if not machineType then
        return self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINE_TYPE_DELETED, { type = tostring(typeName) })
        end
        local reason = self:machineProblem(machineType)
        if reason then
            return reason
        end
    end
    local machineName = record and record.machine
    if machineName then
        local machine = self.Store:get("machines", machineName)
        if machine then
            local reason = self:machineProblem(machine)
            if reason then
                return reason
            end
        end
    end
    return nil
end


function Recipe:markDeliveryError(delivery, text)
    if delivery.lastError == text then
        return
    end
    delivery.lastError = text
    self.Cache:markDirty()
    if text then
        self.log("Delivery %s (%s %s x%s -> %s): %s", tostring(delivery.id or 0), tostring(delivery.kind),
            tostring(delivery.name), tostring(delivery.remaining or 0), tostring(delivery.container), self.Message.describe(text))
    end
end

function Recipe:addDelivery(entry)
    for _, existing in ipairs(self.Cache:deliveries()) do
        if existing.container == entry.container and existing.kind == entry.kind
            and existing.name == entry.name
            and (existing.nbt or "") == (entry.nbt or "") then
            local stuck = (tonumber(existing.stuckCount) or 0) >= 3
            if stuck then
                self.log("Delivery %s is stuck (%s remaining=%s): queueing the new request separately",
                    tostring(existing.id or 0), tostring(existing.name), tostring(existing.remaining or 0))
            else
                local extra = self.Assert.positive(entry.remaining, "delivery.remaining")
                existing.remaining = self.Assert.count(existing.remaining, "delivery.remaining") + extra
                existing.total = self.Assert.count(existing.total, "delivery.total") + extra
                if entry.processName and not existing.processName then
                    existing.processName = entry.processName
                end
                self.log("Delivery %s extended by %s: %s x%s -> %s (total %s)",
                    tostring(existing.id or 0), tostring(extra), tostring(existing.name),
                    tostring(existing.remaining), tostring(existing.container), tostring(existing.total))
                existing.lastError = nil
                self.Cache:markDirty()
                return existing
            end
        end
    end
    return self.Cache:addDelivery(entry)
end

function Recipe:processDeliveries(now)
    local deliveries = self.Cache:deliveries()
    if #deliveries == 0 then
        return
    end
    local pending = {}
    for _, delivery in ipairs(deliveries) do
        local remaining = tonumber(delivery.remaining) or 0
        if remaining > 0 and delivery.nextAttemptAt and now < delivery.nextAttemptAt then
            pending[#pending + 1] = delivery
        elseif remaining > 0 then
            local containerKind = delivery.containerKind
            if containerKind ~= "item" and containerKind ~= "fluid" then
                containerKind = self.Util.kindOfDef(self.Store:findContainer(delivery.container, delivery.kind))
            end
            if not self.Containers:peripheralOf(delivery.container, containerKind) then
                self:markDeliveryError(delivery, self.Containers:unusableReason(delivery.container, containerKind)
                    or self.Message.msg(self.Message.KEYS.RECIPE_ERR_DELIVERY_TARGET_UNAVAILABLE, { container = tostring(delivery.container) }))
            else
                local targets = { delivery.container }
                local itemTargets = {}
                local fluidTargets = {}
                if delivery.kind ~= "fluid" then
                    itemTargets = targets
                end
                if delivery.kind ~= "item" then
                    fluidTargets = targets
                end
                local inflightQty = tonumber(delivery.inflight) or 0
                local wantQty = remaining
                local moveToken = "delivery:" .. tostring(delivery.id or delivery.name)
                local spec = { kind = delivery.kind, id = delivery.name }
                if delivery.nbt ~= nil and delivery.nbt ~= "" then
                    spec.nbt = delivery.nbt
                    spec.ignoreNbt = false
                end
                local moved, reason = self:sendToMachine(
                    spec,
                    itemTargets,
                    fluidTargets,
                    -1,
                    wantQty,
                    moveToken,
                    { storageOrder = self.Containers.ORDER_FRAGMENT, queue = "inventoryOut" }
                )
                self:debugInfo("delivery#%s %s remaining=%d inflight=%d want=%d moved=%s reason=%s",
                    tostring(delivery.id or delivery.name), tostring(delivery.name), remaining, inflightQty,
                    wantQty, tostring(moved), self.Message.describe(reason))
                if reason == "pending" then
                    local booked = tonumber(moved) or 0
                    if booked > 0 then
                        delivery.remaining = remaining - booked
                        delivery.lastError = nil
                        self.Cache:markDirty()
                    end
                elseif moved > 0 then
                    delivery.inflight = nil
                    moved = tonumber(moved) or 0
                    delivery.remaining = remaining - moved
                    delivery.lastError = nil
                    delivery.nextAttemptAt = nil
                    delivery.stuckCount = 0
                    delivery.lastProgressAt = now
                    self.Cache:markDirty()
                    if (tonumber(delivery.remaining) or 0) <= 0 then
                        self.log("Delivery %s done: %s x%s -> %s", tostring(delivery.id or 0),
                            tostring(delivery.name), tostring(remaining), tostring(delivery.container))
                    end
                elseif wantQty > 0 then
                    delivery.inflight = nil
                    moved = tonumber(moved) or 0
                    if moved > 0 then
                        delivery.remaining = remaining - moved
                        delivery.lastError = nil
                        self.Cache:markDirty()
                        if (tonumber(delivery.remaining) or 0) <= 0 then
                            self.log("Delivery %s done: %s x%s -> %s", tostring(delivery.id or 0),
                                tostring(delivery.name), tostring(remaining), tostring(delivery.container))
                        end
                    else
                        if #self:producers(delivery.kind, delivery.name) == 0 then
                            reason = self:messageOf(self.Message.KEYS.RECIPE_ERR_NO_PRODUCER, {
                                item = tostring(delivery.name),
                                remaining = tostring(remaining),
                            })
                        end
                        self:markDeliveryError(delivery, reason
                            or self.Message.msg(self.Message.KEYS.RECIPE_WAIT_STOCK, { item = tostring(delivery.name) }))
                        local stuck = (tonumber(delivery.stuckCount) or 0) + 1
                        delivery.stuckCount = stuck
                        delivery.nextAttemptAt = now + math.min(30000, 1000 * (2 ^ math.min(stuck, 5)))
                        self.Cache:markDirty()
                    end
                end
            end
            if (tonumber(delivery.remaining) or 0) > 0 then
                pending[#pending + 1] = delivery
            else
                self:forgetPendingMove("delivery:" .. tostring(delivery.id or delivery.name))
            end
        end
    end
    if #pending ~= #deliveries then
        self.Cache.data.deliveries = pending
        self.Cache:markDirty()
    end
end

function Recipe:startCompact(role)
    local now = os.epoch("utc")
    self.compact = {
        state = "planning",
        role = role or "storage",
        planner = self.Containers:compactPlanner(role or "storage"),
        plan = nil,
        index = 1,
        total = 0,
        items = 0,
        kinds = 0,
        moved = 0,
        failed = 0,
        skipped = 0,
        loggedFailures = 0,
        startedAt = now,
        lastReportAt = now,
    }
    self.Cache:markDirty()
    return "planning"
end

-- A compaction pass streams (see Containers:compactPlanSimple): every slot it looks at
-- either hands one move to the compact queue right away or is skipped, and a refused move
-- makes the pass rebuild its layout. There is no plan array to hand over, so the job only
-- stays "planning" until the pass is through and the counters below are the result.
function Recipe:advanceCompactPlan(job, now)
    local queued, skipped, finished = self.Containers.compactPlanPass(self.Containers, job.planner)
    if finished ~= true then
        return false
    end
    local rejected = (job.planner and job.planner.rejected) or 0
    local restarts = (job.planner and job.planner.restarts) or 0
    job.state = "done"
    job.plan = nil
    job.index = 1
    job.total = 0
    job.items = 0
    job.kinds = 0
    job.moved = 0
    job.failed = 0
    job.skipped = skipped or 0
    job.queued = queued or 0
    job.rejected = rejected
    job.planner = nil
    job.plannedAt = now
    job.lastReportAt = now
    self.compact = nil
    self.compactPlanQueued = queued or 0
    self.compactLastFinishAt = now
    self.compactPlanStats = { total = queued or 0, queued = queued or 0, skipped = skipped or 0,
        rejected = rejected, at = now }
    self.Cache:markDirty()
    self.log("Auto compact: %d move task(s) queued into the compact queue " ..
        "(%d skipped, %d rejected, %d restart(s))", queued or 0, skipped or 0, rejected, restarts)
    return true
end

function Recipe:setCompactFreeRatio(value)
    local ratio = tonumber(value)
    if not ratio or ratio < 0 then
        ratio = 0
    elseif ratio > 1 then
        ratio = 1
    end
    if self.compactFreeRatio ~= ratio then
        self.compactFreeRatio = ratio
        self.compactPlanRevision = nil
        self.log("Auto compact free-slot threshold: %.2f (compaction runs below it)", ratio)
    end
    return ratio
end

function Recipe:storageFreeRatio()
    local stats = self.Containers and self.Containers.capacityStats
        and self.Containers:capacityStats() or nil
    if not stats then
        return nil
    end
    local total = tonumber(stats.totalSlots) or 0
    if total <= 0 then
        return nil
    end
    local used = tonumber(stats.slots) or 0
    if used > total then
        used = total
    elseif used < 0 then
        used = 0
    end
    return (total - used) / total
end

-- The compact *plan* is generated here, inline, before the scheduler runs: it never
-- enters a dispatch queue and never spends an executor slot. Nothing is planned while
-- the compact queue still holds move tasks, while a container's slot capacity is
-- still unknown, or while the free-slot ratio is above the threshold.
function Recipe:compactPlanTick(now)
    now = now or os.epoch("utc")
    local job = self.compact
    if job and job.state == "planning" then
        self:advanceCompactPlan(job, now)
        return 0
    end
    if job then
        return 0
    end
    if self.dispatch and self.dispatch.depth and self.dispatch:depth("compact") > 0 then
        return 0
    end
    -- A storage container whose slot count has not been read cannot be planned around
    -- (its slots would be skipped), so compaction waits for the read instead of
    -- generating a plan from a half-known storage.
    if self.Containers.hasUnknownSlotCount and self.Containers:hasUnknownSlotCount() then
        self.compactWaitReason = "slotCount"
        return 0
    end
    local freeRatio = self:storageFreeRatio()
    if freeRatio == nil or freeRatio >= (self.compactFreeRatio or 0.10) then
        self.compactWaitReason = nil
        return 0
    end
    if self.Containers.hasUnknownSlotCapacity and self.Containers:hasUnknownSlotCapacity() then
        self.compactWaitReason = "capacity"
        return 0
    end
    local revision = self.Containers.planInputRevision and self.Containers:planInputRevision() or nil
    if revision ~= nil and revision == self.compactPlanRevision and (self.compactPlanQueued or 0) == 0 then
        return 0
    end
    self.compactPlanRevision = revision
    self.compactWaitReason = nil
    self:startCompact("storage")
    job = self.compact
    if job and job.state == "planning" then
        self:advanceCompactPlan(job, now)
    end
    return 0
end

-- Drop the current plan (a move failed): the next plan is generated from a fresh
-- snapshot once the compact queue is empty again.
function Recipe:abortCompact(reason)
    local job = self.compact
    self.compact = nil
    self.compactPlanQueued = 0
    self.compactPlanStats = nil
    self.compactAbortReason = reason
    self.compactAbortedAt = os.epoch("utc")
    self.Cache:markDirty()
    if job then
        self.log("Storage compact aborted (%s) after %d move(s)",
            tostring(reason or "move failed"), tonumber(job.total) or 0)
    end
    return job ~= nil
end

-- Push the moves of the finished plan into the compact queue (one concrete move task
-- per element). Only the execution runs here; the plan itself is already complete.
function Recipe:autoCompactStep(now)
    now = now or os.epoch("utc")
    local job = self.compact
    if not job or job.state ~= "running" then
        return 0
    end
    local plan = job.plan or {}
    local queued, skipped, rejected = 0, job.skipped or 0, 0
    for _, move in ipairs(plan) do
        local current = move.name and self.Containers:stackAt(move.fromContainer, move.fromSlot) or nil
        local fromPeripheral = self.Containers:peripheralOf(move.fromContainer, "item")
        local toPeripheral = self.Containers:peripheralOf(move.toContainer, "item")
        if current and (current.name ~= move.name or tostring(current.nbt or "") ~= tostring(move.nbt or "")) then
            skipped = skipped + 1
        elseif (fromPeripheral and self.Containers:slotBusy(fromPeripheral, move.fromSlot))
            or (toPeripheral and self.Containers:slotBusy(toPeripheral, move.toSlot)) then
            skipped = skipped + 1
        else
            local key, why = self.Containers:manageItem(move.fromContainer, move.fromSlot, move.toContainer,
                move.toSlot, { name = move.name, nbt = move.nbt }, move.amount)
            if key then
                queued = queued + 1
            else
                rejected = rejected + 1
                if rejected <= 3 then
                    self.log.warn("compact move rejected: %s", self.Message.describe(why))
                end
            end
        end
    end
    self.compact = nil
    self.compactLastFinishAt = now
    self.compactPlanQueued = queued
    self.compactPlanStats = { total = #plan, queued = queued, skipped = skipped, rejected = rejected,
        at = now }
    self.Cache:markDirty()
    self.log("Auto compact: %d/%d move task(s) queued into the compact queue (%d skipped, %d rejected)",
        queued, #plan, skipped, rejected)
    return queued
end

function Recipe:compactStatus()
    local job = self.compact
    if not job then
        if self.compactWaitReason == "slotCount" and self.Containers.unknownSlotCountList
            and #self.Containers:unknownSlotCountList() > 0 then
            -- Compaction is waiting for the slot-count read of some storage container.
            return {
                planning = false,
                waiting = "slotCount",
                pendingSlotCount = #self.Containers:unknownSlotCountList(),
                containers = self.Containers:unknownSlotCountList(4),
                done = 0, pending = 0, moved = 0, items = 0, kinds = 0, failed = 0, queued = 0,
            }
        end
        if self.compactWaitReason == "capacity" and self.Containers.pendingCapacityCount
            and self.Containers:pendingCapacityCount() > 0 then
            -- Compaction is waiting for the slot-capacity scan of some container.
            return {
                planning = false,
                waiting = "capacity",
                pendingCapacity = self.Containers:pendingCapacityCount(),
                containers = self.Containers.pendingCapacityList
                    and self.Containers:pendingCapacityList(4) or {},
                done = 0, pending = 0, moved = 0, items = 0, kinds = 0, failed = 0, queued = 0,
            }
        end
        local stats = self.compactPlanStats
        if not stats or (os.epoch("utc") - (stats.at or 0)) > 30000 then
            return nil
        end
        return {
            planning = false,
            generated = true,
            total = stats.total or 0,
            queued = stats.queued or 0,
            skipped = stats.skipped or 0,
            rejected = stats.rejected or 0,
            at = stats.at,
            done = 0,
            pending = stats.queued or 0,
            moved = 0,
            items = 0,
            kinds = 0,
            failed = 0,
        }
    end
    if job.state == "planning" then
        local planner = job.planner or {}
        return {
            planning = true,
            stage = planner.stage or "scan",
            containersDone = tonumber(planner.containersDone) or 0,
            containersTotal = tonumber(planner.containersTotal) or 0,
            groupsDone = tonumber(planner.groupsDone) or 0,
            groupsTotal = tonumber(planner.groupsTotal) or 0,
            calls = tonumber(planner.totalCalls) or 0,
            total = 0,
            done = 0,
            pending = 0,
            moved = 0,
            items = 0,
            kinds = 0,
            failed = 0,
            skipped = 0,
        }
    end
    return {
        total = job.total or 0,
        done = math.min(job.index - 1, job.total or 0),
        pending = math.max(0, (job.total or 0) - (job.index - 1)),
        moved = job.moved or 0,
        items = job.items or 0,
        kinds = job.kinds or 0,
        failed = job.failed or 0,
        skipped = job.skipped or 0,
    }
end

function Recipe:stepCompact(now)
    return self:autoCompactStep(now)
end


function Recipe:elementKeyOf(spec)
    local kind = (type(spec) == "table" and spec.kind == "fluid") and "fluid" or "item"
    local id = (type(spec) == "table" and spec.id) or tostring(spec or "")
    return kind .. ":" .. tostring(id)
end

function Recipe:specOfElement(element)
    if type(element) ~= "table" then
        return { kind = "item", id = "" }
    end
    if element.kind == "filter" then
        return { kind = "filter", id = element.id, nbt = element.nbt, ignoreNbt = element.ignoreNbt ~= false }
    end
    return {
        kind = element.kind == "fluid" and "fluid" or "item",
        id = element.id,
        nbt = element.nbt,
        ignoreNbt = element.ignoreNbt ~= false,
    }
end

function Recipe:availableForCraft(element)
    local spec = self:specOfElement(element)
    if element.kind == "filter" then
        -- Exact figure: matching stacks minus dirty marks and instance claims (both are
        -- booked per concrete resource, which is why plain countOf() over-counted).
        return self.Containers:availableForFilterSpec(spec), 0, 0
    end
    local available, visible, dirty, claimed = self.Containers:availableForCraft(spec)
    return available, visible, dirty, claimed
end

-- With "mix resources" off, a material filter has to be bound to exactly one
-- concrete resource, and the batch size has to fit what that single resource can
-- supply (the request is then covered by several instances instead of one mixed
-- batch). Returns that concrete spec plus its really available amount (claims
-- already deducted), or nil when nothing matching sits in storage.
function Recipe:bestSingleInput(element)
    if type(element) ~= "table" or element.kind ~= "filter" then
        return nil
    end
    local spec = self:specOfElement(element)
    if not spec then
        return nil
    end
    local bestSpec, bestAvailable
    -- One candidate is one concrete (name, nbt) pair. countOf()'s fast path sums
    -- every nbt variant of an id, so the visible amount is summed here instead
    -- and only the dirty/claimed amounts are taken from the container side (both
    -- of those honour the nbt of the spec).
    local function consider(kind, name, nbt, visible)
        local concrete = { kind = kind, id = name, nbt = nbt or "", ignoreNbt = false }
        local available = (tonumber(visible) or 0)
            - (tonumber(self.Containers:dirtyAmount(concrete)) or 0)
            - (tonumber(self.Containers:claimedAmount(concrete)) or 0)
        available = math.max(0, math.floor(available))
        if available > 0 and (not bestAvailable or available > bestAvailable) then
            bestSpec, bestAvailable = concrete, available
        end
    end
    local totals, order = {}, {}
    for _, storageName in ipairs(self.Containers:byRole("storage", "item", "out")) do
        for _, stack in ipairs(self.Containers:stacks(storageName)) do
            if self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
                local key = tostring(stack.name) .. "\1" .. tostring(stack.nbt or "")
                local bucket = totals[key]
                if not bucket then
                    bucket = { name = stack.name, nbt = stack.nbt, count = 0 }
                    totals[key] = bucket
                    order[#order + 1] = bucket
                end
                bucket.count = bucket.count + (tonumber(stack.count) or 0)
            end
        end
    end
    for _, bucket in ipairs(order) do
        consider("item", bucket.name, bucket.nbt, bucket.count)
    end
    for _, storageName in ipairs(self.Containers:byRole("storage", "fluid", "out")) do
        for _, tank in ipairs(self.Containers:tanks(storageName)) do
            if self.Filter:specMatches(spec, { kind = "fluid", name = tank.name }) then
                consider("fluid", tank.name, nil, tank.amount)
            end
        end
    end
    if not bestSpec then
        return nil
    end
    return bestSpec, bestAvailable
end

-- Identity of a material in the ledger. Items, fluids, filters and placeholders
-- keep their own row, so a filter request never merges with a request for one
-- concrete item it happens to match.
function Recipe:materialKeyOf(spec)
    local kind = (type(spec) == "table" and spec.kind) and tostring(spec.kind) or "item"
    local id = ""
    if type(spec) == "table" then
        id = tostring(spec.id or spec.name or "")
    end
    return kind .. ":" .. id
end

-- Same identity, straight from a process element.
function Recipe:materialKeyOfElement(element)
    if type(element) ~= "table" then
        return nil
    end
    if element.kind == "placeholder" then
        return "placeholder:" .. tostring(element.name or "")
    end
    if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
        return element.kind .. ":" .. tostring(element.id or "")
    end
    return nil
end

-- material key -> { { process = <name>, yield = <per round> }, ... } for every
-- process that can craft that material and has its "craft reference" switch on.
-- Rebuilt when the store revision changes (a definition was added, edited or
-- deleted); never written to disk.
function Recipe:craftIndex()
    local revision = self.Store.revision and self.Store:revision() or 0
    if self.craftIndexRev == revision and self.craftIndexCache then
        return self.craftIndexCache
    end
    local index = {}
    local function add(key, processName, yieldPerBatch)
        local bucket = index[key]
        if not bucket then
            bucket = {}
            index[key] = bucket
        end
        bucket[#bucket + 1] = { process = processName, yield = yieldPerBatch }
    end
    for _, process in ipairs(self.Store:list("processes")) do
        if not self:isAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                if output.craft ~= false then
                    local yieldPerBatch = math.max(1, math.floor(tonumber(self:expectedYield(process, output)) or 0))
                    if output.kind == "placeholder" then
                        -- A placeholder stands for one item; it is reachable both as
                        -- "that placeholder" and as the concrete item it names, which
                        -- is what a downstream input usually asks for.
                        if output.name and output.name ~= "" then
                            add("placeholder:" .. output.name, process.name, yieldPerBatch)
                        end
                        if output.item and output.item ~= "" then
                            add("item:" .. output.item, process.name, yieldPerBatch)
                        end
                    elseif output.kind == "item" or output.kind == "fluid" or output.kind == "filter" then
                        add(output.kind .. ":" .. tostring(output.id), process.name, yieldPerBatch)
                    end
                end
            end
        end
    end
    self.craftIndexRev = revision
    self.craftIndexCache = index
    return index
end

function Recipe:expectedYield(process, element)
    local total = 0
    for _, output in ipairs(process.outputs or {}) do
        if output.kind == element.kind or (element.kind == "filter" and
                (output.kind == "item" or output.kind == "fluid")) then
            if self:outputMatchesInput(output, element) then
                local expect = tonumber(output.expect)
                if expect == nil then
                    expect = tonumber(output.max) or 0
                end
                total = total + math.max(0, expect)
            end
        end
    end
    return total
end

-- (downstreamNeed / downstreamCap / countKeys are gone: the demand of a process
-- is derived from the material ledger every tick by Recipe:planTick.)

-- (markCountDirty is gone: nothing has to be marked, the material ledger is the
-- only place a demand lives and Recipe:planTick re-derives it every tick.)

-- (consumeDemand is gone: a finished batch is settled against its *material* rows
-- by Recipe:settleProduced - automateCount first, then queryCount.)

-- (upstreamOf is gone: the reverse lookup lives in Recipe:craftIndex, keyed by
-- material instead of by process.)

-- (recomputeDirty is gone: Recipe:planTick derives the whole demand from the
-- material ledger on every tick, so nothing has to be marked dirty any more.)

-- (enabledOwners / noteOwnerEnabled are gone: the set of processes that have
-- work to do is derived from the material ledger by Recipe:planTick every tick.)

-- The batch limit of one planning round: maxMultiplier, capped by how many rounds the
-- material that is available *right now* covers (one figure per material input, the
-- tightest one wins) and by the rounds that are still owed (`gap`). `report` is an
-- optional out table: diagnostics pass one and get one row per material input, which is
-- what makes a small batch explainable (see Diagnose:report).
function Recipe:materialLimit(process, gap, report)
    local limit = math.max(1, math.floor(tonumber(process.maxMultiplier) or 1))
    -- Several input elements may draw from the same storage stock (nine slot-pinned
    -- coal inputs are nine consumers of one pile). Availability therefore has to be
    -- divided by the *sum* of their per-round demand: measuring the whole pile once per
    -- element made the batch bigger than the stock - it fed a part of it and then
    -- stalled while holding a machine slot.
    local stocks, order = {}, {}
    for _, element in ipairs(process.inputs or {}) do
        -- A skippable input must not cap the batch either: it is optional, so its
        -- missing stock cannot reduce the multiplier to 0.
        if (element.kind == "item" or element.kind == "fluid" or element.kind == "filter")
            and not element.skip then
            local perCraft = elementDemand(element, 1)
            if perCraft > 0 then
                local key, available
                if element.kind == "filter" and element.allowMix == false then
                    -- A non-mixing filter is bound to one concrete resource, so its
                    -- stock is that resource - not the filter.
                    local concrete, single = self:bestSingleInput(element)
                    if concrete then
                        key = "item:" .. tostring(concrete.id)
                        available = single
                    end
                elseif element.kind == "filter" then
                    key = "filter:" .. tostring(element.id)
                    available = self:availableForCraft(element)
                else
                    local spec = self:specOfElement(element)
                    key = self:elementKeyOf(spec)
                    available = self:availableForCraft(element)
                end
                if key then
                    local stock = stocks[key]
                    if not stock then
                        stock = { key = key,
                            available = math.max(0, math.floor(tonumber(available) or 0)), perCraft = 0 }
                        stocks[key] = stock
                        order[#order + 1] = stock
                    end
                    stock.perCraft = stock.perCraft + perCraft
                end
            end
        end
    end
    for _, stock in ipairs(order) do
        if stock.perCraft > 0 then
            local share = math.floor(stock.available / stock.perCraft)
            limit = math.min(limit, share)
            if report then
                report[#report + 1] = { key = stock.key, perCraft = stock.perCraft,
                    available = stock.available, limit = share }
            end
        end
    end
    return math.max(0, math.min(limit, math.floor(tonumber(gap) or 0)))
end

-- "Mix resources" off: replace every such material input filter of the instance
-- definition with the concrete item/fluid this instance will consume. The
-- definition is a per-instance copy (inst.def), so other instances of the same
-- process may well bind a different resource - what never happens is one batch
-- mixing two of them. Returns how many elements were bound.
function Recipe:bindSingleInputs(inst)
    local def = inst and inst.def
    if type(def) ~= "table" then
        return 0
    end
    local bound = 0
    for index, element in ipairs(def.inputs or {}) do
        if element.kind == "filter" and element.allowMix == false then
            local concrete, available = self:bestSingleInput(element)
            if concrete then
                def.inputs[index] = {
                    kind = concrete.kind,
                    id = concrete.id,
                    nbt = concrete.nbt or "",
                    ignoreNbt = false,
                    count = element.count,
                    containerIndex = element.containerIndex,
                    slot = element.slot,
                    min = element.min,
                    expect = element.expect,
                    max = element.max,
                    craft = element.craft,
                    allowMix = true,
                    catalyst = element.catalyst,
                    skip = element.skip,
                }
                inst.bindings = inst.bindings or {}
                inst.bindings[tostring(index)] = {
                    filter = tostring(element.id),
                    kind = concrete.kind,
                    id = concrete.id,
                    available = math.floor(tonumber(available) or 0),
                }
                bound = bound + 1
                self.log("Process %s: input #%d filter %s bound to %s (%d available, batch x%d)",
                    tostring(inst.owner), index, tostring(element.id), tostring(concrete.id),
                    math.floor(tonumber(available) or 0), tonumber(inst.multiplier) or 0)
            end
        end
    end
    return bound
end

function Recipe:createInstance(process, machine, multiplier, now)
    local inst = self.Cache.defaultInstance()
    inst.owner = process.name
    inst.machineType = process.machineType
    inst.machine = machine.name
    inst.multiplier = math.max(1, math.floor(tonumber(multiplier) or 1))
    inst.def = self.Util.deepcopy(process)
    -- Identity of that frozen definition: the file stores each definition once and an
    -- instance only carries this key (see Cache:exportData).
    inst.defKey = self.Cache:noteDef(inst.def)
    inst.startedAt = now
    inst.phase = "input"
    inst.index = 1
    inst.state = "running"
    local conversion = self.Store.isTypeConversion(process.machineType)
    -- The output side is prepared up front for an unordered process (and every type
    -- conversion): the outputs then have their own index and may progress while the
    -- inputs are still being delivered.
    if conversion or processIoMode(process) == "unordered" then
        inst.outProgress = {}
        inst.outIndex = 1
        self:prepareOutputs(inst.def, inst)
    end
    if not conversion then
        -- Bind the non-mixing material filters to one concrete resource before
        -- anything is claimed, so the claims below (and the whole batch) work on the
        -- exact item/fluid this instance is going to consume.
        self:bindSingleInputs(inst)
    end
    -- Register the instance first so its id is final: the id is the claim source.
    self.Cache:addInstance(inst)
    local ownerKey = instanceSource(inst)
    local claims = {}
    if not conversion then
        -- Claim against the *bound* definition (inst.def): a non-mixing material filter
        -- was replaced by the concrete item this instance is going to consume, so the
        -- reservation follows the real resource (that is what makes the next instance
        -- see it through Recipe:availableForCraft / bestSingleInput).
        for _, element in ipairs((inst.def or process).inputs or {}) do
            -- A skippable input is not reserved: it may not be consumed at all.
            if (element.kind == "item" or element.kind == "fluid") and not element.skip then
                local amount = elementDemand(element, inst.multiplier)
                if amount > 0 then
                    local spec = self:specOfElement(element)
                    self.Containers:claim(spec, amount, ownerKey)
                    local key = self:elementKeyOf(spec)
                    claims[key] = (claims[key] or 0) + amount
                end
            end
        end
    end
    inst.claims = claims
    self:occupyMachine(machine.name, 1, instanceSource(inst))
    -- Book what this batch is going to produce: the ledger counts it as "being
    -- crafted" until the instance ends, so the very same rounds are not queued
    -- again while it runs.
    self:noteCrafting(process, inst, 1)
    local record = self:record(process.name)
    record.state = "running"
    record.wait = nil
    record.lastError = nil
    record.checkedAt = now
    self.instanceScanBurst = true
    self.Cache:markDirty()
    self.log("Process %s: instance #%d started on %s x%d", tostring(process.name), inst.id,
        tostring(machine.name), inst.multiplier)
    return inst
end

function Recipe:finishInstance(process, inst, now)
    if type(inst) ~= "table" then
        return false
    end
    local ownerName = tostring(inst.owner or (process and process.name) or "")
    local ownerKey = instanceSource(inst)
    for key, amount in pairs(inst.claims or {}) do
        local kind, id = key:match("^(%a+):(.*)$")
        if kind and id then
            self.Containers:releaseClaim({ kind = kind, id = id }, amount, ownerKey)
        end
    end
    inst.claims = {}
    -- Drop whatever is left of this instance's reservations (the successful input
    -- already gave back the slices that were consumed).
    self.Containers:releaseClaimSource(ownerKey)
    if type(inst.machine) == "string" and inst.machine ~= "" then
        self:occupyMachine(inst.machine, -1, instanceSource(inst))
    end
    self:forgetPendingMovesWithPrefix("in:" .. ownerName .. "#" .. tostring(inst.id or 0))
    self:forgetPendingMovesWithPrefix("out:" .. ownerName .. "#" .. tostring(inst.id or 0))
    if inst.id ~= nil then
        self.Cache:removeInstance(inst.id)
    end
    -- The batch is out: give the craftingCount back and settle what really came
    -- out of the machine (automateCount first, then the user request).
    self:releaseCrafting(inst)
    if process then
        self:settleProduced(process, inst)
    end
    local record = self.Cache.data.processes and self.Cache.data.processes[ownerName]
    if record then
        record.lastFinishedAt = now or os.epoch("utc")
        record.wait = nil
        record.lastError = nil
        record.state = "idle"
    end
    self.Cache:markDirty()
    self.log("Process %s: instance #%s finished (x%s)", ownerName, tostring(inst.id),
        tostring(inst.multiplier))
    return true
end

-- Kill one instance without touching the material ledger: the demand stays where
-- it is, so the planning engine queues those rounds again on the next tick. That
-- is the intended behaviour of "abort instance"; Recipe:cancel builds on it for
-- "abort process" (it zeroes the user request of the products right after killing
-- every instance).
function Recipe:killInstance(inst, reason)
    if type(inst) ~= "table" then
        return false
    end
    local ownerName = tostring(inst.owner or "")
    local ownerKey = instanceSource(inst)
    for key, amount in pairs(inst.claims or {}) do
        local kind, id = key:match("^(%a+):(.*)$")
        if kind and id then
            self.Containers:releaseClaim({ kind = kind, id = id }, amount, ownerKey)
        end
    end
    inst.claims = {}
    self.Containers:releaseClaimSource(ownerKey)
    if type(inst.machine) == "string" and inst.machine ~= "" then
        self:occupyMachine(inst.machine, -1, instanceSource(inst))
    end
    self:forgetPendingMovesWithPrefix("in:" .. ownerName .. "#" .. tostring(inst.id or 0))
    self:forgetPendingMovesWithPrefix("out:" .. ownerName .. "#" .. tostring(inst.id or 0))
    if inst.id ~= nil then
        self.Cache:removeInstance(inst.id)
    end
    self:releaseCrafting(inst)
    local record = self.Cache.data.processes and self.Cache.data.processes[ownerName]
    if record then
        record.wait = nil
        record.lastError = nil
    end
    self.Cache:markDirty()
    self.log("Process %s: instance #%s killed (%s, x%d)", ownerName, tostring(inst.id),
        tostring(reason or "killed"), tonumber(inst.multiplier) or 1)
    return true
end


function Recipe:abortInstance(processName, id)
    processName = tostring(processName or "")
    local wanted = tonumber(id)
    if processName == "" or wanted == nil then
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_INSTANCE_ARGS)
    end
    local inst = self.Cache:instance(wanted)
    if not inst or tostring(inst.owner or "") ~= processName then
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_INSTANCE_MISSING, { id = tostring(wanted) })
    end
    self:killInstance(inst, "aborted")
    return true, { process = processName, instance = wanted }
end


function Recipe:stepInstance(inst, now)
    local def = inst and inst.def
    if type(def) ~= "table" then
        return false
    end
    if self.Store.isTypeConversion(def.machineType) then
        self:stepConversionInstance(inst, def, now)
        return true
    end
    local machine = self.Store:get("machines", inst.machine)
    if not machine or not self:machineUsable(machine) then
        local problem = machine and self:machineProblem(machine) or nil
        inst.state = "missing"
        inst.wait = { kind = "peripheral" }
        if problem then
            inst.lastError = self.Message.msg(self.Message.KEYS.RECIPE_ERR_MACHINE_UNAVAILABLE_WHY,
                { machine = tostring(inst.machine), problem = problem })
        else
            inst.lastError = self.Message.msg(self.Message.KEYS.RECIPE_ERR_MACHINE_UNAVAILABLE,
                { machine = tostring(inst.machine) })
        end
        self.Cache:markDirty()
        return true
    end
    if inst.wait and inst.wait.kind == "peripheral" then
        inst.wait = nil
        inst.state = "running"
        inst.lastError = nil
        self.Cache:markDirty()
    end
    if processIoMode(def) == "unordered" then
        -- Input and output progress in the same tick. The two phases must not share
        -- record.index, so the output phase runs on record.outIndex (swapped in
        -- around the call); stepInput keeps the input index in record.index.
        if not inst.outProgress then
            inst.outProgress = {}
            inst.outIndex = 1
            self:prepareOutputs(def, inst)
        end
        if inst.phase ~= "output" then
            self:stepInput(def, inst, machine, now)
        end
        local inputIndex = inst.index
        inst.index = tonumber(inst.outIndex) or 1
        self:stepOutput(def, inst, machine, now)
        inst.outIndex = inst.index
        inst.index = inputIndex
        return true
    end
    if inst.phase == "input" then
        self:stepInput(def, inst, machine, now)
    else
        self:stepOutput(def, inst, machine, now)
    end
    return true
end

-- A type conversion instance is a bridge: it consumes nothing and touches no
-- peripheral. Its input operation only checks that the material exists; its output
-- operation checks that the configured filter really matches that material and then
-- records the filter as produced. A mismatch parks the instance so the user sees
-- that the filter does not actually accept the input.
function Recipe:conversionInputMatchesFilter(input, output)
    if input.kind == "item" or input.kind == "fluid" then
        if self.Filter:matches(output.id, { kind = input.kind, name = input.id, nbt = input.nbt }) then
            return true, false
        end
        -- The item's tags may simply not be scanned yet: wait instead of crying
        -- "mismatch" (that is the whole reason the bridge exists).
        if input.kind == "item" and self.Cache and self.Cache.hasTags
            and not self.Cache:hasTags(input.id) then
            return false, true
        end
        return false, false
    end
    if input.kind == "filter" then
        -- A filter input: the output filter has to accept everything it accepts.
        return self.Filter:isSubsetOf(input.id, output.id), false
    end
    return false, false
end

function Recipe:stepConversionInstance(inst, def, now)
    local input = (def.inputs or {})[1]
    local output = (def.outputs or {})[1]
    inst.progress = inst.progress or {}
    inst.outProgress = inst.outProgress or {}
    if not input or not output then
        inst.state = "missing"
        inst.wait = { kind = "conversion" }
        inst.lastError = self.Message.msg(self.Message.KEYS.RECIPE_ERR_CONVERSION_SHAPE)
        self.Cache:markDirty()
        return
    end
    local batch = self:batchOf(inst)
    local required = elementDemand(input, batch)
    local available = math.max(0, math.floor(tonumber(self:availableFor(input)) or 0))
    local done = math.min(available, required)
    inst.progress["1"] = done
    local matched, pending = self:conversionInputMatchesFilter(input, output)
    local outTarget = math.max(0,
        math.floor((tonumber(output.expect) or tonumber(output.max) or 1) * batch))
    -- Unordered IO streams the output with the input as it arrives; the other modes
    -- wait for the whole batch of input before producing anything.
    local target = 0
    if required > 0 and done >= required then
        target = outTarget
    elseif processIoMode(def) == "unordered" and required > 0 then
        target = math.floor(outTarget * done / required)
    end
    local produced = tonumber(inst.outProgress["1"]) or 0
    if matched and target > produced then
        inst.outProgress["1"] = target
        produced = target
    end
    if not matched then
        inst.state = "waiting"
        inst.wait = { kind = "conversion" }
        inst.lastError = pending
            and self.Message.msg(self.Message.KEYS.RECIPE_ERR_CONVERSION_SCANNING,
                { item = tostring(input.id) })
            or self.Message.msg(self.Message.KEYS.RECIPE_ERR_CONVERSION_MISMATCH,
                { filter = tostring(output.id), item = tostring(input.id) })
        self.Cache:markDirty()
        return
    end
    if produced >= outTarget and done >= required then
        self:finishInstance(def, inst, now)
        return
    end
    -- Still short of the full batch: park and let the planner top the input up.
    inst.state = "waiting"
    inst.wait = { kind = "materials" }
    inst.lastError = nil
    self:noteMaterialShortage(def, inst, now)
end

function Recipe:stepInstances(now)
    local list = {}
    for _, inst in pairs(self.Cache:instances()) do
        list[#list + 1] = inst
    end
    if #list == 0 then
        return 0
    end
    table.sort(list, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
    local stepped = 0
    for _, inst in ipairs(list) do
        self.stepInstance(self, inst, now)
        stepped = stepped + 1
    end
    local stats = self.tickStats
    if stats then
        stats.active = stepped
    end
    return stepped
end

-- Interaction containers are only scanned while an active instance references
-- them (plus the web manual tool's watch lease and the reconciliation escape).
function Recipe:activeInstanceContainers()
    local out = {}
    local instances = self.Cache:instances()
    if not instances then
        return out
    end
    for _, inst in pairs(instances) do
        local machineName = type(inst.machine) == "string" and inst.machine or nil
        local machine = machineName and self.Store:get("machines", machineName) or nil
        if machine then
            for _, listKey in ipairs({ "itemInputs", "fluidInputs", "itemOutputs", "fluidOutputs" }) do
                local kind = string.find(listKey, "^fluid") and "fluid" or "item"
                for _, containerName in ipairs(machine[listKey] or {}) do
                    local peripheralName = self.Containers:peripheralOf(containerName, kind)
                    if peripheralName then
                        out[peripheralName] = true
                    end
                end
            end
        end
    end
    return out
end

function Recipe:takeInstanceScanBurst()
    local burst = self.instanceScanBurst == true
    self.instanceScanBurst = nil
    return burst
end

-- (tryCreateInstances is gone: Recipe:planTick decides and sends the instances,
-- from the material ledger instead of from per-process counters.)

function Recipe:maintain(now)
    now = now or os.epoch("utc")
    self.tickCount = (self.tickCount or 0) + 1
    self.lastTickAt = now
    if now - (self.wrapResetAt or 0) >= 10000 then
        self.wrapResetAt = now
        self.Peripherals:invalidate()
    end
    self.tickStats = {
        steps = 0, active = 0, processes = #self.Store:list("processes"), reads = 0, readMs = 0,
        readsAtStart = self.Containers.readCount or 0,
        readMsAtStart = self.Containers.readMsTotal or 0,
    }
end

-- Stock keeping: the operator pins a target amount for a craftable material and the
-- engine tops the storage up whenever it drops below that. The demand is injected
-- through the same material ledger a manual "craft_resource" uses, so the planner
-- treats it like any other request. keepPending remembers how much of the target is
-- already on its way; without it every tick would ask for the full shortfall again
-- while a slow producer is still catching up.
function Recipe:maintainKeepStock(now)
    now = now or os.epoch("utc")
    local keep = {}
    if self.Store and self.Store.keepSettings then
        keep = self.Store:keepSettings()
    end
    self.keepPending = self.keepPending or {}
    local stats = self.keepStats
    if not stats then
        stats = { targets = 0, requested = 0, satisfied = 0, pending = 0 }
        self.keepStats = stats
    end
    stats.targets = 0
    stats.requested = 0
    stats.satisfied = 0
    stats.pending = 0
    if next(keep) == nil then
        return 0
    end
    local index = self:craftIndex()
    for key, amount in pairs(keep) do
        if amount > 0 then
            stats.targets = stats.targets + 1
            local kind, name = tostring(key):match("^(%a+):(.*)$")
            if not name or name == "" then
                self.keepPending[key] = nil
            elseif kind == "placeholder" then
                -- A placeholder has no stock (always 0): its keep target is a rolling
                -- demand on the material ledger, so the process that outputs it keeps
                -- running while its output is consumed downstream. The ledger itself is
                -- the "pending" amount here, so keepPending is not used.
                local material = self:materialOfKey(key)
                local outstanding = material
                    and ((tonumber(material.queryCount) or 0) + (tonumber(material.craftingCount) or 0)) or 0
                if outstanding < amount then
                    local producers = index[key]
                    if producers and #producers > 0 then
                        local needed = amount - outstanding
                        local ok = self:startResource(kind, name, needed)
                        if ok then
                            stats.requested = stats.requested + needed
                        end
                    end
                else
                    stats.satisfied = stats.satisfied + 1
                end
                self.keepPending[key] = nil
            else
                local stock = self:visibleStock({ kind = kind, id = name })
                if stock >= amount then
                    self.keepPending[key] = nil
                    stats.satisfied = stats.satisfied + 1
                else
                    local need = amount - stock
                    local pending = tonumber(self.keepPending[key]) or 0
                    if pending > need then
                        pending = need
                    end
                    local deficit = need - pending
                    if deficit > 0 then
                        local producers = index[kind .. ":" .. name]
                        if producers and #producers > 0 then
                            local ok = self:startResource(kind, name, deficit)
                            if ok then
                                pending = pending + deficit
                                stats.requested = stats.requested + deficit
                            end
                        end
                    end
                    self.keepPending[key] = pending
                    stats.pending = stats.pending + pending
                end
            end
        else
            self.keepPending[key] = nil
        end
    end
    return stats.requested
end

function Recipe:finishTick()
    local stats = self.tickStats
    if not stats then
        return
    end
    stats.reads = (self.Containers.readCount or 0) - (stats.readsAtStart or 0)
    stats.readMs = (self.Containers.readMsTotal or 0) - (stats.readMsAtStart or 0)
end




-- The instance pipeline of the tick: step what is running and deliver. The
-- *planning* part (who owes how many rounds, what is short) runs as
-- Recipe:planTick before the task scheduler - see IFMMaster.masterTick.
function Recipe:tick(now)
    now = now or os.epoch("utc")
    self:maintain(now)
    self.stepInstances(self, now)
    self.processDeliveries(self, now)
    self:finishTick()
end

function Recipe:tickStatsText()
    local stats = self.tickStats or {}
    local scan = self.Containers.scanSummary and self.Containers:scanSummary() or {}
    local plan = self.planStats or {}
    return string.format(
        "active=%d/%d steps=%d containerReads=%d readMs=%dms | materials=%d planNeed=%d created=%d | " ..
        "containers=%s readCost=%sms passCost=%sms scanTtl=%sms defer=%s",
        tonumber(stats.active) or 0,
        tonumber(stats.processes) or 0,
        tonumber(stats.steps) or 0,
        tonumber(stats.reads) or 0,
        tonumber(stats.readMs) or 0,
        tonumber(plan.materials) or 0,
        tonumber(plan.need) or 0,
        tonumber(plan.created) or 0,
        tostring(scan.containers or "?"),
        tostring(scan.readCost or "?"),
        tostring(scan.passCost or "?"),
        tostring(scan.ttl or "?"),
        tostring(scan.defer or 0))
end

function Recipe:reconcile()
    local processNames = {}
    for _, process in ipairs(self.Store:list("processes")) do
        processNames[process.name] = true
    end
    for name in pairs(self.Cache.data.processes) do
        if not processNames[name] then
            self.Cache.data.processes[name] = nil
            self.Cache:markDirty()
        end
    end
    local machineNames = {}
    for _, machine in ipairs(self.Store:list("machines")) do
        machineNames[machine.name] = true
    end
    for name in pairs(self.Cache.data.machines) do
        if not machineNames[name] then
            self.Cache.data.machines[name] = nil
            self.Cache:markDirty()
        end
    end
end

function Recipe:storageCount(kind, name, nbt)
    if kind == "filter" then
        return self.Containers:filterCount(name)
    end
    local spec = { kind = kind, id = name }
    if nbt ~= nil and nbt ~= "" then
        spec.nbt = nbt
        spec.ignoreNbt = false
    end
    return self.Containers:countOf(spec, "storage")
end

-- Pre-batch storage content of one output element. Concrete items/fluids are
-- stored per resource name, but a filter matches many of them, so its baseline
-- has to be summed over every matching entry - otherwise the whole pre-existing
-- matching stock would look like output of this batch. It is computed once per
-- element when the batch starts (prepareOutputs) and frozen onto the element,
-- because the filter matcher is far too heavy to re-run on every panel push.
function Recipe:baselineCountIn(baseline, kind, id)
    if kind ~= "filter" then
        return tonumber((baseline or {})[kind .. ":" .. tostring(id)]) or 0
    end
    local spec = { kind = "filter", id = id }
    local total = 0
    for key, count in pairs(baseline or {}) do
        local entryKind, name = key:match("^([^:]+):(.*)$")
        if name and (entryKind == "item" or entryKind == "fluid") then
            if self.Filter:specMatches(spec, { kind = entryKind, name = name }) then
                total = total + (tonumber(count) or 0)
            end
        end
    end
    return total
end

function Recipe:storageBaselineCount(record, kind, id)
    return self:baselineCountIn((record or {}).baseline, kind, id)
end

function Recipe:storageGain(spec, record)
    local baseline = (record.baseline or {})[spec.kind .. ":" .. spec.id] or 0
    return math.max(0, self:storageCount(spec.kind, spec.id) - baseline)
end

function Recipe:progressOf(record)
    local batch = record.multiplier or record.batch or 0
    if batch <= 0 or record.phase ~= "output" then
        return {}
    end
    local out = {}
    for index, entry in ipairs(record.target or {}) do
        -- Same source as the ledger: only what the extraction moves reported. The
        -- storage content is deliberately not consulted here either.
        local produced = math.max(0, math.floor(tonumber((record.outProgress or {})[tostring(index)]) or 0))
        -- The bar shows this batch's own output against the expected yield
        -- (expect x batch), not against how much the element may extract at
        -- most - max is the extraction cap, so a full bar there would mean
        -- "nothing left to take", not "expected amount reached".
        local expected = tonumber(entry.expect) or tonumber(entry.target) or 0
        local percent = 1
        if expected > 0 then
            percent = math.min(1, produced / expected)
        end
        out[#out + 1] = {
            kind = entry.kind,
            id = entry.id,
            -- Legacy alias: the progress bar reads "current" as a fallback only.
            current = produced,
            produced = produced,
            -- target = max x batch (bar scale), min/expected are the two tick marks.
            target = entry.target,
            min = tonumber(entry.min) or 0,
            expected = expected,
            percent = percent,
        }
    end
    return out
end

function Recipe:currentElement(process, record)
    local batch = self.Assert.count(record.multiplier or record.batch, "record.multiplier")
    if batch < 1 then
        return nil
    end
    local index = self:indexOf(record)
    local isOutput = record.phase == "output"
    local list = isOutput and (process.outputs or {}) or (process.inputs or {})
    local element = list[index]
    if type(element) ~= "table" then
        return nil
    end
    local key = tostring(index)
    local entry = {
        phase = isOutput and "output" or "input",
        kind = element.kind,
        id = element.id,
        name = element.name,
        item = element.item,
    }
    if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
        if isOutput then
            entry.done = (record.outProgress or {})[key] or 0
            entry.min = (tonumber(element.min) or 0) * batch
            entry.target = (tonumber(element.max) or 0) * batch
            entry.expect = (tonumber(element.expect) or tonumber(element.max) or 0) * batch
        else
            entry.done = (record.progress or {})[key] or 0
            -- elementDemand honours the "catalyst" flag: a catalyst input keeps its
            -- fixed count instead of being scaled by the batch.
            entry.target = elementDemand(element, batch)
            entry.catalyst = element.catalyst == true
            entry.skip = element.skip == true
        end
    elseif element.kind == "placeholder" then
        entry.id = element.item
    elseif element.kind == "waitTime" then
        entry.seconds = tonumber(element.seconds) or 0
    elseif element.kind == "waitSignal" or element.kind == "emitSignal" or element.kind == "emitPulse" then
        entry.sides = element.sides or {}
        entry.threshold = tonumber(element.threshold) or 0
        entry.op = element.op or "ge"
        entry.strength = tonumber(element.strength) or 0
        entry.machineSignalIndex = tonumber(element.machineSignalIndex) or 1
    end
    return entry
end

-- (activeUnits is gone: the rounds a process is working on are the sum of the
-- multipliers of its live instances, which is what planTick keeps in activeCount.)
function Recipe:instancesOf(owner)
    local out = {}
    for key, inst in pairs(self.Cache:instances()) do
        if inst.owner == owner then
            out[#out + 1] = inst
        end
    end
    table.sort(out, function(a, b) return (tonumber(a.id) or 0) < (tonumber(b.id) or 0) end)
    return out
end

-- (hasAccounting is gone: the panel decides from the material ledger rows and the
-- live instances whether a process row is worth showing.)

-- One row per process that has something to show: a live instance, owed rounds or
-- a ledger row of one of its products. `userCount` / `downstreamCount` /
-- `craftingCount` are the ledger of that process' products summed up; they stay
-- next to the new `needCount` / `activeCount` / `materials` fields so a web panel
-- written before this refactor still renders (P3 switches the UI over).
function Recipe:runtime()
    local out = {}
    local materials = self.Cache:materials()
    local actives = self.Cache:activeProcesses()
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self:record(process.name)
        local instances = record and self:instancesOf(process.name) or {}
        local entry = actives[process.name]
        local needCount = entry and (tonumber(entry.needCount) or 0) or 0
        local activeCount = entry and (tonumber(entry.activeCount) or 0) or 0
        local rows, queryCount, automateCount, craftingCount = {}, 0, 0, 0
        for _, output in ipairs(process.outputs or {}) do
            for _, key in ipairs(self:materialKeysOfOutput(output)) do
                local material = materials[key]
                if material then
                    local query = tonumber(material.queryCount) or 0
                    local automate = tonumber(material.automateCount) or 0
                    local crafting = tonumber(material.craftingCount) or 0
                    queryCount = queryCount + query
                    automateCount = automateCount + automate
                    craftingCount = craftingCount + crafting
                    rows[#rows + 1] = {
                        key = material.key,
                        kind = material.kind,
                        id = material.id,
                        queryCount = query,
                        automateCount = automate,
                        craftingCount = crafting,
                    }
                end
            end
        end
        if record and (#instances > 0 or needCount > 0 or #rows > 0) then
            local first = instances[1]
            -- One row per live instance: the web panel lists them under the
            -- process row (each with its own abort button), so the detailed
            -- fields have to travel with the snapshot instead of only the first
            -- instance being described.
            local instanceList = {}
            for _, inst in ipairs(instances) do
                instanceList[#instanceList + 1] = {
                    id = inst.id,
                    machine = inst.machine,
                    multiplier = tonumber(inst.multiplier) or 0,
                    phase = inst.phase or "input",
                    state = inst.state or "running",
                    waitKind = inst.wait and inst.wait.kind or nil,
                    lastError = inst.lastError,
                    startedAt = inst.startedAt,
                    current = self:currentElement(inst.def, inst),
                    progress = self:progressOf(inst),
                }
            end
            -- The process row is the summary of its instances: its progress bars are the
            -- sums of the instance bars (one bar per product, so the products of several
            -- instances end up in the same bar) and its batch figure is how many rounds
            -- all live instances together are working on. Only an instance that reached
            -- its output phase has progress at all (progressOf reports nothing before),
            -- so the bars appear as soon as the first batch produces.
            local batchTotal = 0
            for _, inst in ipairs(instances) do
                batchTotal = batchTotal + math.max(1, math.floor(tonumber(inst.multiplier) or 1))
            end
            local progress, progressAt = {}, {}
            for _, entry in ipairs(instanceList) do
                for _, bar in ipairs(entry.progress or {}) do
                    local key = tostring(bar.kind) .. "\1" .. tostring(bar.id)
                    local row = progressAt[key]
                    if not row then
                        row = { kind = bar.kind, id = bar.id, target = bar.target,
                            produced = 0, expected = 0, min = 0, percent = 1 }
                        progressAt[key] = row
                        progress[#progress + 1] = row
                    end
                    row.produced = row.produced + (tonumber(bar.produced) or 0)
                    row.expected = row.expected + (tonumber(bar.expected) or 0)
                    row.min = row.min + (tonumber(bar.min) or 0)
                end
            end
            for _, row in ipairs(progress) do
                -- Legacy alias: the progress bar reads "current" as a fallback only.
                row.current = row.produced
                row.percent = row.expected > 0 and math.min(1, row.produced / row.expected) or 1
            end
            out[#out + 1] = {
                name = process.name,
                state = record.state or "idle",
                phase = first and first.phase or "input",
                batch = batchTotal,
                maxMultiplier = math.max(1, tonumber(process.maxMultiplier) or 1),
                needCount = needCount,
                activeCount = activeCount,
                remaining = math.max(0, needCount - activeCount),
                materials = rows,
                -- Compatibility names for a panel from before the refactor.
                userCount = queryCount,
                downstreamCount = automateCount,
                craftingCount = craftingCount,
                active = activeCount,
                instances = #instances,
                -- A single instance: describe that one (its machine, its current step).
                -- Several: the row stays a summary - those details belong to the instance
                -- rows, which the panel lists under the process row.
                machine = #instances == 1 and first.machine or nil,
                machines = #instances,
                lastError = record.lastError,
                waitKind = record.wait and record.wait.kind or nil,
                current = #instances == 1 and self:currentElement(first.def, first) or nil,
                progress = progress,
                instanceList = instanceList,
            }
        end
    end
    return out
end

function Recipe:producers(kind, name)
    local out = {}
    for _, process in ipairs(self.Store:list("processes")) do
        if not self:isAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                if self:outputMatchesInput(output, { kind = kind, id = name }) then
                    out[#out + 1] = process.name
                    break
                end
            end
        end
    end
    return out
end

function Recipe:abstractProducer(kind, name)
    for _, process in ipairs(self.Store:list("processes")) do
        if self:isAbstract(process) then
            for _, output in ipairs(process.outputs or {}) do
                if self:outputMatchesInput(output, { kind = kind, id = name }) then
                    return process.name
                end
            end
        end
    end
    return nil
end

function Recipe:outputPerBatch(process, kind, name)
    if not process then
        return 1
    end
    for _, output in ipairs(process.outputs or {}) do
        if (output.kind == "item" or output.kind == "fluid" or output.kind == "filter")
            and self:outputMatchesInput(output, { kind = kind, id = name }) then
            local amount = math.floor(tonumber(output.max) or 0)
            if amount < 1 then
                amount = 1
            end
            return amount
        end
    end
    return 1
end

-- A user request: "make `count` of that material". It goes straight to the
-- material ledger - which process makes it, and how many rounds that is, is the
-- planning engine's business. `processName` is accepted and ignored: the old
-- panel let the operator pin a producer, the ledger does not.
function Recipe:startResource(kind, name, count, processName)
    count = math.max(1, math.floor(tonumber(count) or 1))
    kind = tostring(kind or "item")
    name = tostring(name or "")
    -- A placeholder is a valid request target: its producer key exists in the craft
    -- index ("placeholder:<name>"), and stock keeping uses it to keep the producing
    -- process running (see Recipe:maintainKeepStock).
    if name == "" then
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_PRODUCER_PROCESS)
    end
    local key = kind .. ":" .. name
    local producers = self:craftIndex()[key]
    if producers == nil or #producers == 0 then
        if self:abstractProducer(kind, name) then
            return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_ABSTRACT_PROCESS)
        end
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_PRODUCER_PROCESS)
    end
    local material = self:materialOfKey(key)
    if not material then
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_NO_PRODUCER_PROCESS)
    end
    material.queryCount = (tonumber(material.queryCount) or 0) + count
    material.updatedAt = os.epoch("utc")
    self.Cache:markDirty()
    self.log("[debug] request %s +%d -> queryCount=%d producers=%d caller=%s", key, count,
        material.queryCount, #producers, callerOf(2))
    return true, {
        kind = kind,
        name = name,
        count = count,
        queryCount = material.queryCount,
        producers = #producers,
    }
end

-- (start / setUserCount are gone together with the "make N batches of that
-- process" actions: a request is always made for a *material*, see
-- Recipe:startResource.)

-- "Abort process": stop every instance of it and drop the user request of its
-- products. The automatic demand is left alone - what the processes below need is
-- their business, and the engine keeps feeding them.
function Recipe:cancel(processName)
    local process = self.Store:get("processes", processName)
    if not process then
        return false, self.Message.msg(self.Message.KEYS.RECIPE_ERR_PROCESS_MISSING, { name = tostring(processName) })
    end
    local record = self:record(processName)
    local killed = 0
    local ids = {}
    for key in pairs(self.Cache:instances()) do
        ids[#ids + 1] = key
    end
    table.sort(ids)
    for _, key in ipairs(ids) do
        local inst = self.Cache:instances()[key]
        if inst and inst.owner == processName then
            killed = killed + 1
            self:killInstance(inst, "cancelled")
        end
    end
    record.state = "idle"
    record.wait = nil
    record.lastError = nil
    record.pulse = nil
    self:forgetPendingMovesWithPrefix("in:" .. tostring(process.name) .. "\1")
    self:forgetPendingMovesWithPrefix("out:" .. tostring(process.name) .. "\1")
    if record.pulse then
        self:switchSignals(record.pulse.targets, 0)
        record.pulse = nil
    end
    -- Every product of this process loses its user request. The ledger row itself
    -- is dropped by the engine once nothing is left in it.
    local cleared = 0
    for _, output in ipairs(process.outputs or {}) do
        for _, key in ipairs(self:materialKeysOfOutput(output)) do
            local material = self.Cache:materialByKey(key)
            if material and (tonumber(material.queryCount) or 0) > 0 then
                material.queryCount = 0
                material.updatedAt = os.epoch("utc")
                cleared = cleared + 1
            end
        end
    end
    self.Cache:dropActiveProcess(processName)
    self.Cache:markDirty()
    self.log("Process %s: cancelled (%d instance(s) killed, %d request row(s) cleared)",
        tostring(processName), killed, cleared)
    return true, { canceled = processName, instances = killed, cleared = cleared }
end

function Recipe:queueSend(kind, name, count, containerName, nbt)
    local container = self.Store:findContainer(containerName, kind)
    if not container then
        return false, self.Message.msg(self.Message.KEYS.MASTER_ERR_CONTAINER_NOT_FOUND, { name = tostring(containerName) })
    end
    if container.role ~= "output" then
        return false, self.Message.msg(self.Message.KEYS.MASTER_ERR_OUTPUT_ONLY)
    end
    if not self.Containers:supports(containerName, kind) then
        return false, self.Containers:unusableReason(containerName, kind)
            or self.Message.msg(self.Message.KEYS.MASTER_ERR_CONTAINER_UNUSABLE)
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local entry = self:addDelivery({
        kind = kind,
        name = name,
        nbt = nbt,
        container = container.name,
        containerKind = self.Util.kindOfDef(container),
        remaining = count,
        total = count,
        createdAt = os.epoch("utc"),
    })
    return true, { id = entry.id, kind = kind, name = name, count = count, container = container.name }
end

function Recipe:craftAndSend(kind, name, count, containerName, nbt)
    local container = self.Store:findContainer(containerName, kind)
    if not container then
        return false, self.Message.msg(self.Message.KEYS.MASTER_ERR_CONTAINER_NOT_FOUND, { name = tostring(containerName) })
    end
    if container.role ~= "output" then
        return false, self.Message.msg(self.Message.KEYS.MASTER_ERR_OUTPUT_ONLY)
    end
    if not self.Containers:supports(containerName, kind) then
        return false, self.Containers:unusableReason(containerName, kind)
            or self.Message.msg(self.Message.KEYS.MASTER_ERR_CONTAINER_UNUSABLE)
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local available = self:storageCount(kind, name, nbt)
    local shortBy = math.max(0, count - available)
    local processName = nil
    if shortBy > 0 then
        local ok, info = self:startResource(kind, name, shortBy)
        if not ok then
            self.log("Craft request for %s failed: %s", tostring(name), tostring(info))
        else
            processName = info.process
        end
    end
    local entry = self:addDelivery({
        kind = kind,
        name = name,
        nbt = nbt,
        container = container.name,
        containerKind = self.Util.kindOfDef(container),
        remaining = count,
        total = count,
        processName = processName,
        createdAt = os.epoch("utc"),
    })
    return true, {
        id = entry.id,
        process = processName,
        kind = kind,
        name = name,
        count = count,
        container = container.name,
    }
end

function Recipe:deliveries()
    local out = {}
    for _, delivery in ipairs(self.Cache:deliveries()) do
        out[#out + 1] = {
            id = delivery.id,
            kind = delivery.kind,
            name = delivery.name,
            nbt = delivery.nbt,
            remaining = delivery.remaining or 0,
            total = delivery.total or 0,
            container = delivery.container,
            processName = delivery.processName,
            lastError = delivery.lastError,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The planning engine.
--
-- Every main loop tick walks the material ledger, which is the only place a
-- demand lives now: user requests (queryCount), what the processes below still
-- need once the stock is counted (automateCount) and what is being crafted right
-- now (craftingCount). From that it derives how many rounds each producer owes
-- (activeProcesses), sends the instances for them, pushes the demand it could not
-- cover one level up, and drops whatever is empty. Instances are never cancelled
-- because a demand moved: they run to their end, and finish / kill settle the
-- ledger.
-- ---------------------------------------------------------------------------

-- A material ledger row, created on first use. `element` may be a process input
-- element, an output element or a bare { kind = ..., id = ... } spec.
function Recipe:ensureMaterial(element)
    local key = self:materialKeyOfElement(element) or self:materialKeyOf(element)
    local material = self.Cache:materialByKey(key)
    if material then
        return material
    end
    local kind, id = "item", ""
    if type(element) == "table" then
        kind = tostring(element.kind or "item")
        id = tostring(element.kind == "placeholder" and element.name or element.id or "")
    else
        id = tostring(element or "")
    end
    material = self.Cache:material(kind, id, key)
    material.updatedAt = os.epoch("utc")
    return material
end

function Recipe:materialOfKey(key)
    local material = self.Cache:materialByKey(key)
    if material then
        return material
    end
    local kind, id = tostring(key or ""):match("^(%a+):(.*)$")
    if not kind then
        return nil
    end
    return self.Cache:material(kind, id, key)
end

-- Every ledger key one output element stands for. A placeholder is both "that
-- placeholder" and the concrete item it names, so a downstream process that asks
-- for the item sees the batch that is being crafted for it.
function Recipe:materialKeysOfOutput(output)
    local keys = {}
    if type(output) ~= "table" then
        return keys
    end
    if output.kind == "placeholder" then
        if output.name and output.name ~= "" then
            keys[#keys + 1] = "placeholder:" .. output.name
        end
        if output.item and output.item ~= "" then
            keys[#keys + 1] = "item:" .. output.item
        end
    elseif output.kind == "item" or output.kind == "fluid" or output.kind == "filter" then
        keys[#keys + 1] = output.kind .. ":" .. tostring(output.id)
    end
    return keys
end

-- How much storage really holds of a material: deliberately the *visible* amount.
-- A stack a live instance already claimed is still physically there, and that
-- instance's demand is already gone from the ledger (it is running).
function Recipe:visibleStock(material)
    if material.kind == "item" or material.kind == "fluid" or material.kind == "filter" then
        local spec = { kind = material.kind, id = material.id, ignoreNbt = true }
        -- countOf returns (total, items, fluids). A call sitting in the last
        -- argument slot expands to *all* of them, so the total has to be captured
        -- first: tonumber(total, items, ...) would read the item list as its base
        -- argument and crash with "bad argument (number expected, got table)".
        -- Item/fluid specs take countOf's fast path and return one value, which is
        -- why only filter materials used to break here.
        local total = self.Containers:countOf(spec, "storage")
        if type(total) ~= "number" then
            total = 0
        end
        return math.max(0, math.floor(total))
    end
    -- A placeholder is not a resource of its own: it is covered by the item it
    -- stands for, which has its own ledger row.
    return 0
end

-- How many units one round of a process takes of an input element.
function Recipe:perCraftUnits(element)
    if type(element) ~= "table" then
        return 0
    end
    if element.kind == "placeholder" then
        return 1
    end
    return math.max(0, math.floor(tonumber(element.count) or 0))
end

-- How many rounds the machines of a process type can hold at once: the parallel
-- slots of every machine of that type, times what one round may scale to.
function Recipe:parallelCap(process)
    local parallel = 0
    for _, machine in ipairs(self:machinesOfType(process.machineType)) do
        parallel = parallel + math.max(1, math.floor(tonumber(machine.parallel) or 1))
    end
    if parallel <= 0 then
        return 0
    end
    return parallel * math.max(1, math.floor(tonumber(process.maxMultiplier) or 1))
end

-- Expected amount of one output of one batch. A placeholder stands for one item.
function Recipe:outputUnits(process, output, multiplier)
    local perRound = math.max(0, math.floor(tonumber(self:expectedYield(process, output)) or 0))
    if perRound <= 0 and type(output) == "table" and output.kind == "placeholder" then
        perRound = 1
    end
    return perRound * math.max(1, math.floor(tonumber(multiplier) or 1))
end

-- craftingCount ledger: one RefCount per material key, sources are instances.
-- `material.craftingCount` stays a plain number in cache.json (mirror of value()).
function Recipe:craftingRef(key)
    self.craftingLedger = self.craftingLedger or {}
    local ref = self.craftingLedger[key]
    if not ref then
        ref = RefCount.new("crafting:" .. tostring(key))
        self.craftingLedger[key] = ref
    end
    return ref
end

local function syncCrafting(self, key)
    local ref = self.craftingLedger and self.craftingLedger[key]
    local material = self.Cache:materialByKey(key)
    if material then
        material.craftingCount = ref and ref:value() or 0
        material.updatedAt = os.epoch("utc")
    end
end

-- Book the craftingCount of every output of a batch that just started (+1) or
-- ended (-1). The instance is the source, so finish / kill give back exactly what
-- was taken even if the definition changes while the batch runs.
function Recipe:noteCrafting(process, inst, sign)
    local credit = {}
    local source = instanceSource(inst)
    for _, output in ipairs(process.outputs or {}) do
        local perBatch = self:outputUnits(process, output, inst.multiplier)
        if perBatch > 0 then
            for _, key in ipairs(self:materialKeysOfOutput(output)) do
                local ref = self:craftingRef(key)
                if sign > 0 then
                    ref:add(source, perBatch)
                else
                    ref:remove(source)
                end
                syncCrafting(self, key)
                credit[key] = (credit[key] or 0) + perBatch
            end
        end
    end
    if sign > 0 then
        inst.craftCredit = credit
    else
        inst.craftCredit = {}
    end
    return credit
end

-- Give back the craftingCount an instance had booked (both on finish and on kill).
function Recipe:releaseCrafting(inst)
    local source = instanceSource(inst)
    for key in pairs(inst.craftCredit or {}) do
        local ref = self.craftingLedger and self.craftingLedger[key]
        if ref then
            ref:remove(source)
            syncCrafting(self, key)
        end
    end
    inst.craftCredit = {}
end

-- Startup: rebuild the crafting ledger from the restored instances (their
-- craftCredit is persisted), so the mirrored numbers match the live sources.
function Recipe:rebuildCrafting()
    self.craftingLedger = {}
    local restored = 0
    for _, inst in pairs(self.Cache:instances()) do
        local source = instanceSource(inst)
        for key, amount in pairs(inst.craftCredit or {}) do
            self:craftingRef(key):add(source, amount)
            restored = restored + 1
        end
    end
    for key in pairs(self.craftingLedger) do
        syncCrafting(self, key)
    end
    return restored
end

-- A batch came out: settle its *real* output against every material row it
-- produced - automateCount first (that is what the factory below is waiting for),
-- then the user request. Nothing is written off that was not really produced: the
-- amounts come from the instance's outProgress, and an output without a recorded
-- amount settles nothing at all (no fallback to the expected yield).
function Recipe:settleProduced(process, inst)
    local outProgress = inst.outProgress or {}
    for index, output in ipairs(process.outputs or {}) do
        local produced = math.max(0, math.floor(tonumber(outProgress[tostring(index)]) or 0))
        if produced <= 0 then
            self.debugInfo("settle %s #%s out#%d: no recorded output, nothing settled",
                tostring(inst.owner), tostring(inst.id), index)
        else
            for _, key in ipairs(self:materialKeysOfOutput(output)) do
                local material = self.Cache:materialByKey(key)
                if material then
                    local automated = math.min(math.max(0, tonumber(material.automateCount) or 0), produced)
                    material.automateCount = math.max(0, (tonumber(material.automateCount) or 0) - automated)
                    local left = produced - automated
                    if left > 0 then
                        material.queryCount = math.max(0, (tonumber(material.queryCount) or 0) - left)
                    end
                    material.updatedAt = os.epoch("utc")
                    self.debugInfo("settle %s #%s %s produced=%d automate-=%d query-=%d (query=%d)",
                        tostring(inst.owner), tostring(inst.id), key, produced, automated, left,
                        tonumber(material.queryCount) or 0)
                end
            end
        end
    end
end

function Recipe:countMap(map)
    local n = 0
    for _ in pairs(map or {}) do
        n = n + 1
    end
    return n
end

-- One planning pass. Runs once per main loop tick, before the task scheduler: the
-- demand is walked top-down (materials -> rounds), the instances are sent, and
-- whatever material is still short is booked for the level above. A single pass
-- per tick is intended - the chain is followed one level per tick.
function Recipe:planTick(now)
    local materials = self.Cache:materials()
    local actives = self.Cache:activeProcesses()
    local index = self:craftIndex()
    self.planStats = { need = 0, created = 0, materials = 0, machines = 0 }

    -- (0) The owed rounds are a per-tick figure: they are re-derived from the
    -- ledger below. (automateCount is reset later, in step 4 - step 1 *reads* it,
    -- because it carries the demand the previous tick could not cover.)
    for _, entry in pairs(actives) do
        entry.needCount = 0
    end

    -- (1) material -> rounds. What a material row still lacks becomes rounds of
    -- every process that can craft it (in definition order). Several producers of
    -- the same material each get their own rounds: that is what makes a request
    -- with two producers over-produce on purpose.
    for _, material in pairs(materials) do
        local need = (tonumber(material.queryCount) or 0) + (tonumber(material.automateCount) or 0)
            - (tonumber(material.craftingCount) or 0)
        if need > 0 then
            for _, producer in ipairs(index[material.key] or {}) do
                local entry = self.Cache:activeProcess(producer.process)
                local rounds = math.ceil(need / math.max(1, producer.yield))
                if rounds > entry.needCount then
                    entry.needCount = rounds
                    self.planStats.need = self.planStats.need + 1
                    self.debugInfo("plan %s: need=%d -> %s rounds=%d", tostring(material.key), need,
                        tostring(producer.process), rounds)
                end
            end
        end
    end

    -- (2) Cap the rounds at what the machines of that type can hold, then reset
    -- the in-flight counter: it is rebuilt from the instances in the next step.
    -- A process that owes rounds but has parallelCap 0 (no machine of its type at all,
    -- or an empty machine type) is reported right here: step (5) only runs for
    -- pending > 0, so without this the process would sit at "idle / remaining 0" with no
    -- reason at all - the exact "requested, but nothing happens and nothing says why".
    for _, entry in pairs(actives) do
        local process = self.Store:get("processes", entry.name)
        local raw = tonumber(entry.needCount) or 0
        entry.rawNeedCount = raw
        entry.needCount = process and math.min(self:parallelCap(process), raw) or 0
        entry.activeCount = 0
        if process and raw > 0 and entry.needCount <= 0 then
            local reason
            if #self:machinesOfType(process.machineType) == 0 then
                reason = self:messageOf(self.Message.KEYS.RECIPE_ERR_NO_MACHINE,
                    { type = tostring(process.machineType or "") })
            else
                reason = self:messageOf(self.Message.KEYS.RECIPE_ERR_MACHINES_UNUSABLE)
            end
            local record = self:record(entry.name)
            record.wait = { kind = "machine" }
            record.state = "waiting"
            if record.lastError ~= reason then
                record.lastError = reason
                self.Cache:markDirty()
            end
        end
    end

    -- (3) Live instances say what is really running.
    for _, inst in pairs(self.Cache:instances()) do
        local entry = actives[inst.owner]
        if entry then
            entry.activeCount = entry.activeCount
                + math.max(1, math.floor(tonumber(inst.multiplier) or 1))
        end
    end

    -- (4) Book the demand a round could not cover: the uncovered demand is a
    -- per-tick figure too, so it is reset here and rebuilt from the rounds that are
    -- still owed. One stock pool per material: the first consumer of a material
    -- takes what is there, the next one only sees the remainder, so a material
    -- several processes ask for is never counted twice.
    for _, material in pairs(materials) do
        material.automateCount = 0
    end
    local stockLeft = {}
    for _, entry in pairs(actives) do
        local pending = entry.needCount - entry.activeCount
        local process = pending > 0 and self.Store:get("processes", entry.name) or nil
        if process then
            for _, input in ipairs(process.inputs or {}) do
                -- A skippable input is optional, so it never books demand upstream.
                if isMaterialElement(input) and not input.skip then
                    local material = self:ensureMaterial(input)
                    local want = elementDemand(input, pending)
                    local left = stockLeft[material.key]
                    if left == nil then
                        left = self:visibleStock(material)
                        stockLeft[material.key] = left
                    end
                    local taken = math.min(left, want)
                    stockLeft[material.key] = left - taken
                    if want > taken then
                        material.automateCount = (tonumber(material.automateCount) or 0) + (want - taken)
                        material.updatedAt = os.epoch("utc")
                        self.debugInfo("plan %s: %s want=%d stock=%d -> automate=%d",
                            tostring(entry.name), tostring(material.key), want, taken, want - taken)
                    end
                end
            end
        end
    end

    -- (5) Send the rounds that are still missing. The multiplier is capped by what
    -- the storage can really send, by the missing rounds and by the definition.
    for _, entry in pairs(actives) do
        local pending = entry.needCount - entry.activeCount
        if pending > 0 then
            local process = self.Store:get("processes", entry.name)
            -- self:record() also creates the run-state record on first use, which is
            -- what the instance pipeline writes its wait/state into.
            local record = process and self:record(entry.name) or nil
            if process and record then
                local machine, err = self:chooseMachine(process.machineType)
                if machine then
                    local limit = self:materialLimit(process, pending)
                    local maxMultiplier = math.max(1, math.floor(tonumber(process.maxMultiplier) or 1))
                    local multiplier = math.min(limit, pending, maxMultiplier)
                    if multiplier > 0 then
                        -- One line per instance: these are the terms a small batch has to
                        -- be explained with - a big request that comes out as many small
                        -- instances was limited by one of them, not by a bug per se.
                        self.log("Plan %s: instance x%d (needCount=%d activeCount=%d pending=%d " ..
                            "parallelCap=%d materialLimit=%d maxMultiplier=%d)",
                            tostring(process.name), multiplier, entry.needCount, entry.activeCount,
                            pending, self:parallelCap(process), limit, maxMultiplier)
                        self:createInstance(process, machine, multiplier, now)
                        entry.activeCount = entry.activeCount + multiplier
                        self.planStats.created = self.planStats.created + 1
                    else
                        -- Rounds are owed but the storage cannot send that material
                        -- yet: the demand was booked one level up above, so the panel
                        -- only has to explain the wait.
                        record.wait = { kind = "materials" }
                        record.state = "waiting"
                        local text = self:messageOf(self.Message.KEYS.RECIPE_ERR_NOT_ENOUGH_MATERIALS)
                        if record.lastError ~= text then
                            record.lastError = text
                            self.Cache:markDirty()
                        end
                    end
                else
                    record.wait = { kind = "machine" }
                    record.state = "waiting"
                    if err and record.lastError ~= err then
                        record.lastError = err
                        self.Cache:markDirty()
                    end
                end
            end
        end
    end

    -- (6) Drop what owes nothing. A material that is still being crafted keeps its
    -- row: its craftingCount has to be given back when that instance ends. A process
    -- that owes no round is dropped and comes back as soon as a demand asks for it.
    for name, entry in pairs(actives) do
        if entry.needCount <= 0 then
            actives[name] = nil
            self.Cache:markDirty()
        end
    end
    for key, material in pairs(materials) do
        if (tonumber(material.queryCount) or 0) <= 0 and (tonumber(material.automateCount) or 0) <= 0
            and (tonumber(material.craftingCount) or 0) <= 0 then
            materials[key] = nil
            self.Cache:markDirty()
        end
    end
    self.planStats.materials = self:countMap(materials)
    return self.planStats
end

-- Ledger rows for the web panel: one entry per active material.
function Recipe:materials()
    local out = {}
    for _, material in pairs(self.Cache:materials()) do
        out[#out + 1] = {
            key = material.key,
            kind = material.kind,
            id = material.id,
            queryCount = tonumber(material.queryCount) or 0,
            automateCount = tonumber(material.automateCount) or 0,
            craftingCount = tonumber(material.craftingCount) or 0,
        }
    end
    return out
end

-- Ledger rows for the web panel: one entry per active process.
function Recipe:plan()
    local out = {}
    for _, entry in pairs(self.Cache:activeProcesses()) do
        out[#out + 1] = {
            name = entry.name,
            needCount = tonumber(entry.needCount) or 0,
            activeCount = tonumber(entry.activeCount) or 0,
        }
    end
    return out
end

return Recipe
