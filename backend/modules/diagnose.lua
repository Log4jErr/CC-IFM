local Diagnose = {}
Diagnose.__index = Diagnose

function Diagnose.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Diagnose)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("diagnose.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.Message = opts.Message
        or error("diagnose.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    self.Store = opts.Store
    self.Cache = opts.Cache
    self.Containers = opts.Containers
    self.Peripherals = opts.Peripherals
    self.Recipe = opts.Recipe
    self.perfStats = opts.perfStats
    self.protocol = opts.protocol
    return self
end

local function line(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    return table.concat(parts, " ")
end

local function joinList(list)
    return table.concat(list or {}, ",")
end

-- Pack a vararg (peripheral.getType returns one string per type) into a table.
local function packValues(...)
    return { n = select("#", ...), ... }
end

-- The full peripheral type list, straight from CC:T (empty/error text on failure).
-- Printed next to the classification flags so a misclassification is visible without
-- guessing: a container whose getType list has no "inventory" really is not one.
local function typeList(name)
    if type(peripheral) ~= "table" or type(peripheral.getType) ~= "function" then
        return "no getType API"
    end
    local ok, types = pcall(function()
        return packValues(peripheral.getType(name))
    end)
    if not ok or type(types) ~= "table" then
        return "getType error"
    end
    local parts = {}
    for index = 1, types.n do
        parts[#parts + 1] = tostring(types[index])
    end
    if #parts == 0 then
        return "(none)"
    end
    return table.concat(parts, ",")
end

function Diagnose:holdings(spec)
    local out = {}
    for _, def in ipairs(self.Store:list("containers")) do
        local count = self.Containers:countIn(def.name, spec)
        if count > 0 then
            out[#out + 1] = line("   holds:", def.name, "[", self.Util.kindOfDef(def), def.role, "] =", count)
        end
    end
    if #out == 0 then
        out[#out + 1] = "   holds: NOT FOUND IN ANY CONTAINER DEFINITION"
    end
    return out
end

function Diagnose:report()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    local function safeSay(fmt, ...)
        out[#out + 1] = string.format(fmt, ...)
    end

    local summary = {}
    say("===== IFM diagnose (report) =====")
    local tickAge = self.Recipe.lastTickAt and (os.epoch("utc") - self.Recipe.lastTickAt) or -1
    say("engine: tickCount=" .. tostring(self.Recipe.tickCount)
        .. " lastTickAgeMs=" .. tostring(tickAge)
        .. " (a small lastTickAgeMs means the engine is running; tickCount not growing between two diagnoses means it is not)")
    if self.Recipe.lastTickError then
        say("engine lastTickError: " .. tostring(self.Recipe.lastTickError))
    end
    local counters = self.Recipe.debugCounters
    if counters then
        safeSay("engine counters (classified): modem=%d other=%d uptime=%ds (startedAt=%s)",
            counters.modemMessages, counters.otherEvents,
            math.floor((os.epoch("utc") - counters.startedAt) / 1000),
            tostring(counters.startedAt))
        say("engine counters: events=" .. tostring(counters.events) .. " timers=" .. tostring(counters.timers)
            .. " websockets=" .. tostring(counters.websockets) .. " runs=" .. tostring(counters.ticks)
            .. " (timers stuck at 0 = this computer gets no timer events; the engine runs off other events only)")
    end
    say("peripherals detected by CC:T:")
    for _, kind in ipairs({ "inventory", "fluid", "redstone" }) do
        local names = self.Peripherals:names(kind)
        say("  " .. kind .. ": " .. tostring(#names) .. " -> " .. joinList(names))
    end

    say("container definitions:")
    for _, def in ipairs(self.Store:list("containers")) do
        local defKind = self.Util.kindOfDef(def)
        local peripheralName = tostring(def.peripheral)
        local exists = self.Peripherals:exists(peripheralName)
        local isInventory = exists and self.Peripherals:isInventory(peripheralName) or false
        local isFluid = exists and self.Peripherals:isFluid(peripheralName) or false
        local isTurtle = exists and self.Peripherals:isTurtle(peripheralName) or false
        local snapshotItem = self.Containers:snapshotComplete(peripheralName, "item")
        local snapshotFluid = self.Containers:snapshotComplete(peripheralName, "fluid")
        say("  " .. def.name .. " [" .. defKind .. " " .. tostring(def.role) .. "] peripheral="
            .. peripheralName .. " getType=" .. typeList(peripheralName))
        say("      exists=" .. tostring(exists) .. " isInventory=" .. tostring(isInventory)
            .. " isFluid=" .. tostring(isFluid) .. " isTurtle=" .. tostring(isTurtle)
            .. " snapshotItem=" .. tostring(snapshotItem)
            .. " snapshotFluid=" .. tostring(snapshotFluid)
            .. " infoMissing=" .. joinList(self.Containers:infoMissing(peripheralName)))
        local reason = self.Containers:unusableReason(def.name, defKind)
        if reason then
            say("      UNUSABLE: " .. self.Message.describe(reason))
        end
    end

    say("machines:")
    for _, machine in ipairs(self.Store:list("machines")) do
        say("  " .. tostring(machine.name) .. " type=" .. tostring(machine.type)
            .. " parallel=" .. tostring(machine.parallel or 1)
            .. " usable=" .. tostring(self.Recipe:machineUsable(machine)))
        say("      itemInputs=" .. joinList(machine.itemInputs)
            .. " fluidInputs=" .. joinList(machine.fluidInputs)
            .. " itemOutputs=" .. joinList(machine.itemOutputs)
            .. " fluidOutputs=" .. joinList(machine.fluidOutputs)
            .. " signals=" .. joinList(machine.signals))
        for _, group in ipairs({
            { list = machine.itemInputs, kind = "item" },
            { list = machine.fluidInputs, kind = "fluid" },
            { list = machine.itemOutputs, kind = "item" },
            { list = machine.fluidOutputs, kind = "fluid" },
        }) do
            for _, containerName in ipairs(group.list or {}) do
                local supported = self.Containers:supports(containerName, group.kind)
                local why = self.Containers:unusableReason(containerName, group.kind)
                say("      container " .. tostring(containerName) .. " (" .. group.kind .. ") supports="
                    .. tostring(supported) .. (why and (" reason=" .. self.Message.describe(why)) or ""))
            end
        end
        local problem = self.Recipe:machineProblem(machine)
        if problem then
            say("      PROBLEM: " .. self.Message.describe(problem))
        end
    end

    say("processes (runtime):")
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self.Cache:proc(process.name)
        local instances = self.Recipe:instancesOf(process.name)
        local probe = instances[1]
        local probeDef = probe and probe.def or process
        local craftTotal = 0
        for _, inst in ipairs(instances) do
            craftTotal = craftTotal + (tonumber(inst.multiplier) or 0)
        end
        local machine = probe and self.Store:get("machines", probe.machine) or nil
        local active = self.Cache:activeProcesses()[process.name]
        say("  " .. tostring(process.name) .. " machineType=" .. tostring(process.machineType)
            .. " state=" .. tostring(record.state)
            .. " needCount=" .. tostring(active and active.needCount or 0)
            .. " activeCount=" .. tostring(active and active.activeCount or craftTotal)
            .. " instances=" .. tostring(#instances))
        -- Why the planner picks this batch size (Recipe:planTick step 5 chooses
        -- min(materialLimit, pending, maxMultiplier)): printing the three terms makes a
        -- fragmented run explainable right here, without digging through the ledger.
        local needCount = tonumber(active and active.needCount) or 0
        local activeCount = tonumber(active and active.activeCount) or craftTotal
        local pending = math.max(0, needCount - activeCount)
        local maxMultiplier = math.max(1, math.floor(tonumber(process.maxMultiplier) or 1))
        local sizing = {}
        local limit = self.Recipe:materialLimit(process, pending, sizing)
        say("      sizing: maxMultiplier=" .. tostring(maxMultiplier) .. " parallelCap="
            .. tostring(self.Recipe:parallelCap(process)) .. " pending=" .. tostring(pending)
            .. " materialLimit=" .. tostring(limit) .. " -> next instance x"
            .. tostring(math.min(limit, pending, maxMultiplier)))
        for _, row in ipairs(sizing) do
            say("        input " .. tostring(row.key) .. " perCraft=" .. tostring(row.perCraft)
                .. " available=" .. tostring(row.available) .. " -> " .. tostring(row.limit))
        end
        for _, inst in ipairs(instances) do
            say("        live #" .. tostring(inst.id) .. " x" .. tostring(inst.multiplier)
                .. " phase=" .. tostring(inst.phase) .. " machine=" .. tostring(inst.machine))
        end
        say("      machine=" .. tostring(probe and probe.machine or "-")
            .. " machineUsable=" .. tostring(machine ~= nil and self.Recipe:machineUsable(machine))
            .. " wait=" .. tostring((record.wait and record.wait.kind)
                or (probe and probe.wait and probe.wait.kind) or "nil"))
        if record.lastError or (probe and probe.lastError) then
            say("      lastError: " .. tostring(record.lastError or (probe and probe.lastError)))
        end
        local runningBatch = craftTotal
        repeat
            if runningBatch < 1 then
                say("      idle: no running instance (state=" .. tostring(record.state)
                    .. ") - nothing to compute for this process")
                summary[#summary + 1] = "process " .. tostring(process.name) .. " is idle (no running instance)"
                break
            end
            local ready, element, shortBy, index = self.Recipe:batchMaterialsReady(probeDef, probe)
        say("      batchMaterialsReady=" .. tostring(ready) .. " missingElement#=" .. tostring(index)
            .. " shortBy=" .. tostring(shortBy) .. " element=" .. tostring(element and element.id or "-"))
        if probe.phase == "input" then
            local current = self.Recipe:currentElement(probeDef, probe)
            if current then
                say("      current element: kind=" .. tostring(current.kind) .. " id=" .. tostring(current.id)
                    .. " done=" .. tostring(current.done) .. "/" .. tostring(current.target))
            end
        end
        for elementIndex, el in ipairs(probeDef.inputs or {}) do
            if el.kind == "item" or el.kind == "fluid" or el.kind == "filter" then
                local key = tostring(elementIndex)
                local required = (tonumber(el.count) or 0) * (probe and self.Recipe:batchOf(probe) or 0)
                local doneCount = probe and (probe.progress[key] or 0) or 0
                local itemTargets = machine and self.Recipe:inputContainers(machine, "item", el.containerIndex) or {}
                local fluidTargets = machine and self.Recipe:inputContainers(machine, "fluid", el.containerIndex) or {}
                local spec = { kind = el.kind, id = el.id, nbt = el.nbt, ignoreNbt = el.ignoreNbt }
                local inStorage = self.Containers:countOf(spec, "storage")
                local inTargets = self.Recipe:alreadyInTargets(spec, itemTargets, fluidTargets)
                local need = required - doneCount
                local verdict
                if not machine then
                    verdict = "NO MACHINE SELECTED (instance machine=" .. tostring(probe and probe.machine) .. ")"
                elseif #itemTargets == 0 and #fluidTargets == 0 then
                    verdict = "MACHINE HAS NO INPUT CONTAINERS (check itemInputs / fluidInputs)"
                elseif need <= 0 then
                    verdict = "DONE"
                elseif inTargets >= need then
                    verdict = "OK: already inside the machine input containers"
                elseif inStorage + inTargets < need then
                    verdict = "NOT ENOUGH MATERIAL: need=" .. tostring(need) .. " storageRole=" .. tostring(inStorage)
                else
                    verdict = "READY: storage has enough -> pushItem should run"
                end
                say("      input#" .. tostring(elementIndex) .. " " .. tostring(el.id) .. " count=" .. tostring(el.count)
                    .. " required=" .. tostring(required) .. " done=" .. tostring(doneCount))
                say("         storageCount=" .. tostring(inStorage) .. " inMachineTargets=" .. tostring(inTargets)
                    .. " itemTargets=" .. joinList(itemTargets) .. " fluidTargets=" .. joinList(fluidTargets))
                say("         => " .. verdict)
                summary[#summary + 1] = "process " .. tostring(process.name) .. " input#" .. tostring(elementIndex)
                    .. " " .. tostring(el.id) .. " -> " .. verdict
                if machine then
                    say("         transferFailureReason: "
                        .. tostring(self.Recipe:transferFailureReason(machine, el, itemTargets, fluidTargets, nil)))
                end
                local holdings = self:holdings(spec)
                for _, entry in ipairs(holdings) do
                    say(entry)
                end
            end
        end
        if probe and probe.phase == "output" then
            local outputIndex = self.Recipe:indexOf(probe)
            local el = (probeDef.outputs or {})[outputIndex]
            if type(el) == "table"
                and (el.kind == "item" or el.kind == "fluid" or el.kind == "filter") then
                local batch = self.Recipe:batchOf(probe)
                local maxAmount = (tonumber(el.max) or 0) * batch
                local minAmount = (tonumber(el.min) or 0) * batch
                local collected = probe.outProgress[tostring(outputIndex)] or 0
                local spec = { kind = el.kind, id = el.id, nbt = el.nbt, ignoreNbt = el.ignoreNbt }
                local inMachine = machine and self.Recipe:machineRemaining(spec, machine) or nil
                local inStorage = self.Containers:countOf(spec, "storage")
                local gained = self.Recipe:storageGain(spec, probe)
                local verdict
                if not machine then
                    verdict = "NO MACHINE SELECTED"
                elseif collected >= maxAmount or gained >= maxAmount then
                    verdict = "DONE"
                elseif inMachine == nil then
                    verdict = "CANNOT READ THE MACHINE OUTPUT (peripheral gone / no output container?)"
                elseif inMachine <= 0 and gained < minAmount then
                    verdict = "WAITING FOR MACHINE (nothing in machine output and storage did not grow)"
                elseif inMachine <= 0 then
                    verdict = "OK: product went straight into storage (gained=" .. tostring(gained) .. ")"
                else
                    verdict = "PRODUCT STUCK: " .. tostring(inMachine) .. " inside machine output, storageRole="
                        .. tostring(inStorage) .. " -> transferOut/pushItem cannot move it"
                end
                say("      output#" .. tostring(outputIndex) .. " " .. tostring(el.id) .. " collected="
                    .. tostring(collected) .. "/max=" .. tostring(maxAmount) .. " min=" .. tostring(minAmount))
                say("         machineRemaining=" .. tostring(inMachine) .. " storageRole=" .. tostring(inStorage)
                    .. " storageGain=" .. tostring(gained) .. " => " .. verdict)
                summary[#summary + 1] = "process " .. tostring(process.name) .. " output#" .. tostring(outputIndex)
                    .. " " .. tostring(el.id) .. " -> " .. verdict
                if machine then
                    say("         machineOutputs=" .. joinList(machine.itemOutputs) .. " / "
                        .. joinList(machine.fluidOutputs))
                end
            end
        end
        until true
    end

    say("deliveries (Sending queue):")
    local deliveries = self.Cache:deliveries()
    if #deliveries == 0 then
        say("  (empty)")
    end
    for _, delivery in ipairs(deliveries) do
        local spec = { kind = delivery.kind, id = delivery.name }
        local remaining = delivery.remaining
        local containerKind = delivery.containerKind
        if containerKind ~= "item" and containerKind ~= "fluid" then
            local def = self.Store:findContainer(delivery.container, delivery.kind)
            containerKind = self.Util.kindOfDef(def)
        end
        local targetPeripheral = self.Containers:peripheralOf(delivery.container, containerKind)
        local stacks, tanks = self.Containers:matchSpec(spec, "storage")
        local inTarget = self.Containers:countIn(delivery.container, spec)
        local verdict
        if not targetPeripheral then
            verdict = "TARGET CONTAINER NOT USABLE ("
                .. self.Message.describe(self.Containers:unusableReason(delivery.container, containerKind)) .. ")"
        elseif #stacks + #tanks == 0 and inTarget < remaining then
            verdict = "NOTHING IN STORAGE-ROLE CONTAINERS"
        else
            verdict = "READY: transferIn / pushItem should run"
        end
        say("  #" .. tostring(delivery.id) .. " " .. tostring(delivery.kind) .. " " .. tostring(delivery.name)
            .. " remaining=" .. tostring(remaining) .. " -> " .. tostring(delivery.container)
            .. " (" .. containerKind .. ", peripheral=" .. tostring(targetPeripheral) .. ")")
        say("      storageMatches=" .. tostring(#stacks) .. "(items)/" .. tostring(#tanks)
            .. "(fluids) alreadyInTarget=" .. tostring(inTarget) .. " => " .. verdict)
        summary[#summary + 1] = "delivery #" .. tostring(delivery.id) .. " " .. tostring(delivery.name)
            .. " x" .. tostring(remaining) .. " -> " .. tostring(delivery.container) .. " -> " .. verdict
            .. (delivery.lastError and (" [lastError=" .. tostring(delivery.lastError) .. "]") or "")
        if delivery.lastError then
            say("      lastError: " .. tostring(delivery.lastError))
        end
        local holdings = self:holdings(spec)
        for _, entry in ipairs(holdings) do
            say(entry)
        end
    end

    say("===== SUMMARY (most useful part) =====")
    if #summary == 0 then
        say("  (nothing to summarize: no process / no delivery)")
    end
    for _, entry in ipairs(summary) do
        say("  " .. entry)
    end
    say("===== end of diagnose =====")
    return out
end

function Diagnose:moveProbe()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    say("===== IFM diagnose (move probe) =====")
    say("moves exactly 1 item/fluid per pair, then tries to move it back")
    for _, fromDef in ipairs(self.Store:list("containers")) do
        local fromKind = self.Util.kindOfDef(fromDef)
        local fromPeripheral = self.Containers:peripheralOf(fromDef.name, fromKind)
        if fromPeripheral then
            local sample
            if fromKind == "item" then
                sample = self.Containers:stacks(fromDef.name)[1]
            else
                sample = self.Containers:tanks(fromDef.name)[1]
            end
            if sample then
                local sampleName = sample.name
                local sampleSlot = sample.slot or sample.tank or 1
                for _, toDef in ipairs(self.Store:list("containers")) do
                    local toKind = self.Util.kindOfDef(toDef)
                    local toPeripheral = self.Containers:peripheralOf(toDef.name, toKind)
                    if toPeripheral and toPeripheral ~= fromPeripheral and toKind == fromKind then
                        local moved, reason
                        local probeSlot = nil
                        local provider = self.Containers.transfer
                        self.Containers:setTransferProvider(nil)
                        if toKind == "item" then
                            local toSlot, slotWhy = self.Containers:pickTargetSlot(toDef.name,
                                { name = sampleName, nbt = sample.nbt }, 1)
                            if not toSlot then
                                moved, reason = 0, slotWhy
                            else
                                probeSlot = toSlot
                                moved, reason = self.Containers:pushItem(fromDef.name, sampleSlot, 1,
                                    toDef.name, toSlot)
                            end
                        else
                            moved, reason = self.Containers:pushFluid(fromDef.name, 1, sampleName, toDef.name)
                        end
                        self.Assert.number(moved, "moveProbe pushItem result")
                        say("  " .. fromDef.name .. " -> " .. toDef.name .. " (" .. tostring(sampleName)
                            .. ") moved=" .. tostring(moved) .. " reason=" .. tostring(reason))
                        if moved > 0 then
                            local backMoved, backReason
                            if toKind == "item" then
                                backMoved, backReason = self.Containers:pushItem(toDef.name, probeSlot, moved,
                                    fromDef.name, sampleSlot)
                            else
                                backMoved, backReason = self.Containers:pushFluid(toDef.name, moved, sampleName, fromDef.name)
                            end
                            say("      moved back=" .. tostring(backMoved) .. " reason=" .. tostring(backReason))
                        end
                        self.Containers:setTransferProvider(provider)
                    end
                end
            end
        end
    end
    say("===== end of move probe =====")
    return out
end

function Diagnose:tickProbe()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    say("===== IFM diagnose (manual tick) =====")
    self.Recipe.tick(self.Recipe, os.epoch("utc"))
    say("tick: ok")
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self.Cache:proc(process.name)
        say("  process " .. tostring(process.name) .. " state=" .. tostring(record.state)
            .. " phase=" .. tostring(record.phase) .. " machine=" .. tostring(record.machine)
            .. " lastError=" .. tostring(record.lastError))
    end
    for _, delivery in ipairs(self.Cache:deliveries()) do
        say("  delivery #" .. tostring(delivery.id) .. " " .. tostring(delivery.name)
            .. " remaining=" .. tostring(delivery.remaining) .. " lastError=" .. tostring(delivery.lastError))
    end
    say("===== end of manual tick =====")
    return out
end

function Diagnose:perf()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    local function kb(bytes)
        return string.format("%.1fKB", bytes / 1024)
    end
    local rawFormat = string.format
    local string = {
        format = rawFormat,
    }
    local function safeSay(fmt, ...)
        out[#out + 1] = string.format(fmt, ...)
    end

    say("===== IFM diagnose (perf) =====")

    local timings = {}
    for _, stat in pairs(self.perfStats or {}) do
        timings[#timings + 1] = stat
    end
    table.sort(timings, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return tostring(a.label) < tostring(b.label)
    end)
    say("component timings (label / calls / avg / max / total / calls>=500ms):")
    if #timings == 0 then
        say("  (no samples yet - the main loop has not run since startup)")
    end
    for _, stat in ipairs(timings) do
        local count = stat.count
        say(string.format("  %-22s n=%-6d avg=%4dms max=%6dms total=%8dms slow=%d",
            tostring(stat.label),
            count,
            count > 0 and math.floor(stat.total / count) or 0,
            stat.max,
            stat.total,
            stat.slow))
    end

    local protocol = self.protocol
    if protocol and protocol.statsSummary then
        local summary = protocol.statsSummary(protocol)
        if type(summary) == "table" then
            local seconds = math.max(1, summary.uptimeSeconds)
            safeSay("protocol: sent %d msg %s (max %s) / recv %d msg %s (max %s)",
                summary.sentMessages, kb(summary.sentBytes), kb(summary.sentMax),
                summary.recvMessages, kb(summary.recvBytes), kb(summary.recvMax))
            safeSay("protocol: rate sent=%s/s recv=%s/s over %ds",
                kb(summary.sentBytes / seconds), kb(summary.recvBytes / seconds), seconds)
            safeSay("protocol: last push cost %dms -> auto interval max(%ds, 3x cost) = %dms",
                summary.lastPushCost, summary.updateInterval,
                math.max(summary.updateInterval * 1000, summary.lastPushCost * 3))
            safeSay("protocol: pushes=%d skipped=%d fullSyncs=%d changedItems=%d dropped=%d failed=%d encodeFailed=%d",
                summary.pushes, summary.pushSkipped, summary.fullSyncs,
                summary.changedItems, summary.dropped, summary.failed,
                summary.encodeFailed)
            safeSay("protocol link: connectRequests=%d failures=%d timeouts=%d reconnects=%d",
                summary.connectRequests, summary.connectFailures,
                summary.connectTimeouts, summary.reconnects)
            safeSay("protocol link: pending=%d expected=%d abandoned=%d extras=%d recvSelf=%d ownEchoSeen=%s",
                summary.pendingAcks, summary.expectedAcks,
                summary.abandoned, summary.extraHandles,
                summary.recvSelf, tostring(summary.ownEchoSeen))
            safeSay("protocol link: closes=%d (relay=%d, own=%d, stale=%d) connectedFor=%ds idle=%ds",
                summary.closes,
                math.max(0, summary.closes - summary.ownCloses - summary.staleCloses),
                summary.ownCloses, summary.staleCloses,
                summary.connectedSeconds, summary.idleSeconds)
            if summary.lastCloseReason then
                say("protocol link: last close reason: " .. tostring(summary.lastCloseReason))
            end
            say("protocol: traffic by action (bytes desc, top 12):")
            local actions = summary.actions or {}
            if #actions == 0 then
                say("  (no messages exchanged yet)")
            end
            for index = 1, math.min(#actions, 12) do
                local entry = actions[index]
                safeSay("  %-26s n=%-6d total=%-10s avg=%-9s max=%s",
                    tostring(entry.key), entry.count, kb(entry.bytes),
                    kb(entry.average), kb(entry.max))
            end
            local categories = summary.categories or {}
            if #categories == 0 then
                say("push categories: (nothing pushed yet)")
            else
                say("push categories (bytes desc, top 12) - which category eats the incremental_update traffic:")
                for index = 1, math.min(#categories, 12) do
                    local entry = categories[index]
                    safeSay("  %-26s n=%-6d items=%-7d total=%-10s avg=%-9s max=%s",
                        tostring(entry.key), entry.frames, entry.items, kb(entry.bytes),
                        kb(entry.average), kb(entry.max))
                end
            end
        else
            say("protocol: stats unavailable (" .. tostring(summary) .. ")")
        end
    else
        say("protocol: not available")
    end

    if self.dispatch and self.dispatch.status then
        local dispatchStatus = self.dispatch.status(self.dispatch)
        if type(dispatchStatus) == "table" then
            safeSay("scheduler: mode=%s runs=%d steps=%d (local=%d remote=%d) paused=%d inflight=%d writes=%d",
                tostring(dispatchStatus.mode), dispatchStatus.runs, dispatchStatus.steps,
                dispatchStatus.localSteps, dispatchStatus.remoteSteps,
                dispatchStatus.paused, dispatchStatus.inflight,
                dispatchStatus.writes)
            if self.Store and self.Store.scheduleSettings then
                local sched = self.Store.scheduleSettings(self.Store)
                if type(sched) == "table" then
                    local parts = {}
                    for _, queue in ipairs(sched.queues or {}) do
                        parts[#parts + 1] = queue .. "=" .. tostring((sched.slices or {})[queue] or 1)
                    end
                    say("scheduler slices: " .. table.concat(parts, " "))
                end
            end
            safeSay("scheduler: per-run last=%.1fms avg=%.1fms max=%.1fms cursor=%s uptime=%ds",
                dispatchStatus.lastMs, dispatchStatus.avgMs,
                dispatchStatus.maxMs, tostring(dispatchStatus.cursor),
                dispatchStatus.uptimeSeconds)
            do
                local brk = dispatchStatus.breakdown
                if type(brk) == "table" then
                    safeSay("scheduler breakdown (cumulative ms): flush=%.0f maintain=%.0f promote=%.0f gen=%.0f rotate=%.0f rounds=%d",
                        brk.flush, brk.maintain, brk.promote, brk.gen, brk.rotate,
                        brk.rounds)
                end
                local run = dispatchStatus.lastRun
                if type(run) == "table" then
                    safeSay("scheduler last run (ms): total=%.0f flush=%.0f maintain=%.0f promote=%.0f gen=%.0f rotate=%.0f steps=%s paused=%s",
                        tonumber(run.ms) or 0, tonumber(run.flush) or 0, tonumber(run.maintain) or 0,
                        tonumber(run.promote) or 0, tonumber(run.gen) or 0, tonumber(run.rotate) or 0,
                        tostring(run.steps), tostring(run.paused))
                    local qparts = {}
                    for _, q in ipairs(run.queues or {}) do
                        qparts[#qparts + 1] = string.format("%s %dx/%.0fms(max%.0f)",
                            q.name, q.calls, q.ms, q.maxMs)
                    end
                    safeSay("scheduler last run queues: %s",
                        (#qparts > 0) and table.concat(qparts, " ") or "-")
                    if self.Containers and self.Containers.stackStepText then
                        local stack = self.Containers:stackStepText()
                        if type(stack) == "string" and stack ~= "" then
                            safeSay("scheduler last run %s", stack)
                        end
                    end
                end
                local byQueue = dispatchStatus.byQueue
                if type(byQueue) == "table" then
                    local rows = {}
                    for name, entry in pairs(byQueue) do
                        rows[#rows + 1] = { name = name, ms = entry.ms,
                            calls = entry.calls, maxMs = entry.maxMs,
                            slow = entry.slow }
                    end
                    table.sort(rows, function(x, y) return x.ms > y.ms end)
                    for _, row in ipairs(rows) do
                        safeSay("  queue-task %-13s calls=%-7d total=%-9.0fms max=%-8.1fms slow(>=50ms)=%d",
                            tostring(row.name), row.calls, row.ms, row.maxMs, row.slow)
                    end
                end
            end
            local idleInQueue = 0
            if self.Recipe.guardCounters then
                idleInQueue = tonumber(self.Recipe.guardCounters.idleProcessInQueue) or 0
            end
            safeSay("scheduler guards: duplicateQueues=%d missingRunner=%d idleProcessInQueue=%d",
                dispatchStatus.duplicateQueues, dispatchStatus.missingRunner, idleInQueue)
            say("scheduler queues (name weight runs-left depth(active+waiting) inflight served done dropped retried promoted needs policy):")
            for _, queue in ipairs(dispatchStatus.queues or {}) do
                safeSay("  %-13s weight=%-5s runs=%-5s depth=%-5s active=%-5s waiting=%-5s inflight=%-3s served=%-7s done=%-7s dropped=%-5s retried=%-5s promoted=%-5s needs=%s policy=%s",
                    tostring(queue.name), tostring(queue.slice), tostring(queue.remaining),
                    tostring(queue.depth),
                    tostring(queue.active), tostring(queue.waiting),
                    tostring(queue.inflight), tostring(queue.served), tostring(queue.done),
                    tostring(queue.dropped), tostring(queue.retried), tostring(queue.promoted),
                    tostring(queue.needs), tostring(queue.policy))
            end
        else
            say("scheduler: status unavailable (" .. tostring(dispatchStatus) .. ")")
        end
    else
        say("scheduler: not available")
    end

    if self.transfer and self.transfer.status then
        local transferStats = self.transfer.status(self.transfer)
        if type(transferStats) == "table" then
            say(string.format("IFMWorker: workers=%d busy=%d idle=%d pending=%d channel=%s",
                transferStats.workers, transferStats.busy, transferStats.idle,
                transferStats.pending, tostring(transferStats.channel or "-")))
            say(string.format("IFMWorker: submitted=%d done=%d failed=%d timedOut=%d",
                transferStats.submitted, transferStats.done, transferStats.failed,
                transferStats.timedOut))
            say(string.format("IFMWorker: slots=%d freeSlots=%d inFlightTasks=%d idle=%d/%d (workers accept every job)",
                transferStats.slots, transferStats.freeSlots, transferStats.inFlightTasks,
                transferStats.idle, transferStats.workers))
            say(string.format("IFMWorker: usable=%d unknownVersion=%d versionMismatch=%d atCapacity=%d (master=%s)",
                transferStats.usable, transferStats.versionUnknown,
                transferStats.versionMismatch, transferStats.inFlightWorkers,
                tostring(transferStats.version or "?")))
        else
            say("IFMWorker: status unavailable (" .. tostring(transferStats) .. ")")
        end
    else
        say("IFMWorker: not available")
    end

    if self.Containers and self.Containers.scanStatsSummary then
        if self.Containers.scanSummary then
            local scan = self.Containers.scanSummary(self.Containers)
            if type(scan) == "table" then
                safeSay("container snapshot: containers=%s scanned=%s readCost=%sms passCost=%sms reads=%s readMs=%sms staleMax=%s staleAvg=%s (ticks)",
                    tostring(scan.containers), tostring(scan.scanned), tostring(scan.readCost),
                    tostring(scan.passCost), tostring(scan.reads), tostring(scan.readMs),
                    tostring(scan.staleTicks), tostring(scan.staleAvgTicks))
                if self.Containers.snapshotSummary then
                    local snap = self.Containers.snapshotSummary(self.Containers)
                    if type(snap) == "table" then
                        safeSay("container snapshot detail: inUseSlots=%d inUseItems=%d inUseFluids=%d inUseContainers=%d settled=%d inFlight=%d results=%d",
                            snap.inUseSlots, snap.inUseItems, snap.inUseFluids, snap.inUseContainers,
                            snap.settled, snap.inflight, snap.results)
                        local ct = self.Containers
                        if ct then
                            safeSay("move dispatch: enqueued=%d rejected=%d localDirect=%d | scans: sentToWorker=%d localRead=%d deferred=%d",
                                ct.moveEnqueued, ct.moveEnqueueRejected, ct.moveEnqueueLocal,
                                ct.scanRequested, ct.scanLocal, ct.scanDeferred)
                            local proto = self.protocol
                            if proto and proto.stats then
                                safeSay("outbox flush: flushes=%d msgs=%d frames=%d drops=%d lost=%d tooLarge=%d logThrottled=%d",
                                    proto.stats.flushes, proto.stats.flushMessages, proto.stats.flushedFrames,
                                    proto.stats.dropped, proto.stats.flushDropped, proto.stats.tooLarge,
                                    proto.stats.logThrottled)
                            end
                        end
                    end
                end
                if self.Containers.stackScanTargets and self.Containers.stackScanStatusFromSnapshot then
                    local targets = self.Containers.stackScanTargets(self.Containers)
                    if type(targets) == "table" then
                        local known, unknown = 0, 0
                        for _, target in ipairs(targets) do
                            local status = self.Containers:stackScanStatusFromSnapshot(target.container)
                            known = known + status.known
                            unknown = unknown + status.unknown
                        end
                        say(string.format("stack scan (compact planning input): %d storage container(s), %d slot(s) with a known stack limit, %d unknown, %d item(s) skipped in planning",
                            #targets, known, unknown, self.Containers.stackLimitUnknown))
                    end
                end
            end
        end
        local scans = self.Containers.scanStatsSummary(self.Containers, 12)
        if type(scans) == "table" and #scans > 0 then
            say("container scans (peripheral / calls / avg / max / total / item vs fluid):")
            for _, entry in ipairs(scans) do
                local calls = entry.calls
                say(string.format("  %-28s n=%-6d avg=%5dms max=%6dms total=%8dms item=%d fluid=%d",
                    tostring(entry.name), calls,
                    calls > 0 and math.floor(entry.total / calls) or 0,
                    entry.max, entry.total,
                    entry.item, entry.fluid))
            end
        else
            say("container scans: (no samples yet - nothing has been scanned since startup)")
        end
    end

    if self.transfer and self.transfer.workersForUi then
        local workers = self.transfer.workersForUi(self.transfer, { full = true })
        if type(workers) == "table" then
            if #workers == 0 then
                say("IFMWorker: none online (run IFMWorker.lua on another computer)")
            else
                say(string.format("IFMWorker: %d online (each worker only moves and queries items/fluids)", #workers))
            end
            for _, worker in ipairs(workers) do
                local tasks = worker.tasks or {}
                say(string.format("  #%-4s %-16s v=%s load=%d/%d peak=%d jobs=%d moved=%d queries=%d pending=%d age=%ds%s",
                    tostring(worker.id), tostring(worker.name),
                    tostring(worker.version or "?"), worker.load, worker.slots,
                    worker.peak,
                    worker.jobs, worker.moved, worker.queries, worker.pending,
                    worker.stateAge,
                    (worker.stateAge == nil) and " (no state yet)" or ""))
                if worker.stuck > 0 then
                    say(string.format("        stuck: %d task(s) dropped (a container/peripheral stopped answering)",
                        worker.stuck))
                end
                if #tasks > 0 then
                    say("        now: " .. table.concat(tasks, " | "))
                end
                if type(worker.lastQuery) == "table" then
                    say(string.format("        last query: %s, %s stack(s), %sms",
                        tostring(worker.lastQuery.mode), tostring(worker.lastQuery.stacks),
                        tostring(worker.lastQuery.elapsed)))
                end
                if worker.details ~= nil then
                    say(string.format("        item detail: %d batch(es), %d detail(s) (getItemDetail offloaded)",
                        worker.details, worker.detailItems))
                end
            end
        end
    end
    if self.transfer and self.transfer.detailStatus then
        local detail = self.transfer.detailStatus(self.transfer)
        if type(detail) == "table" then
            say(string.format("item detail offload: batches=%d done=%d items=%d pending=%d failed=%d workers=%d",
                detail.submitted, detail.done, detail.items, detail.pending,
                detail.failed, detail.workers))
            if self.Containers and self.Containers.localDetailCalls then
                say(string.format("  getItemDetail called on the master: %d time(s) (0 is ideal; " ..
                    "each one blocks ~1 game tick)", self.Containers.localDetailCalls))
            end
        end
    end

    local counters = self.Recipe and self.Recipe.debugCounters
    if counters then
        local duplicates = 0
        if type(counters.requests) == "table" then
            duplicates = tonumber(counters.requests.duplicates) or 0
        end
        safeSay("events: events=%d timers=%d websockets=%d engineRuns=%d modem=%d other=%d duplicates=%d",
            counters.events, counters.timers, counters.websockets, counters.ticks,
            counters.modemMessages, counters.otherEvents, duplicates)
        do
            local gaps = counters.tickGaps or {}
            local parts = {}
            for i = 1, #gaps do
                parts[i] = tostring(gaps[i])
            end
            say("tick gaps (raw, last " .. tostring(#gaps) .. ", ms): " .. table.concat(parts, " "))
        end
    end

    say(string.format("scale: containers=%d signals=%d filters=%d machineTypes=%d machines=%d processes=%d deliveries=%d",
        #(self.Store:list("containers") or {}),
        #(self.Store:list("signals") or {}),
        #(self.Store:list("filters") or {}),
        #(self.Store:list("machineTypes") or {}),
        #(self.Store:list("machines") or {}),
        #(self.Store:list("processes") or {}),
        #(self.Cache:deliveries() or {})))

    say("how to read this:")
    say("  * log line 'Slow <label>: Nms (calls=.. avg=.. max=.. slow=..)' = one call of that")
    say("    component took N ms; slow counts how many calls were >= 500 ms.")
    say("  * 'engine tick' / 'protocol event' / 'tag auto scan' refresh the snapshots that are wanted")
    say("    right now: storage / input containers always, interaction containers only while an active")
    say("    process instance uses that machine (or the web manual tool watches it), output containers")
    say("    only while a send (inventoryOut) is in flight; a container with unsettled dirty marks is")
    say("    re-scanned once so it can be reconciled. One full pass costs the sum of 'container scans'.")
    say("  * compare events/timers with engineRuns: if events/timers are much larger than engineRuns,")
    say("    every loop iteration is blocked by the scans (engine tick + push + tag scan).")
    say("  * 'container scans' (section above) = per-peripheral list()/tanks() cost: tens of ms for")
    say("    one container means that block or the wired network is what slows everything down.")
    say("  * big send:incremental_update = one full sync when a browser connects (all categories at")
    say("    once); later pushes are not throttled any more, and heartbeats never trigger a push.")
    say("  * timers=0 while events grows = this computer gets no timer events (engine only moves")
    say("    when other events arrive).")
    say("===== end of perf probe =====")
    return out
end

return Diagnose
