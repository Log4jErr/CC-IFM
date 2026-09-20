-- IFM :: modules/diagnose.lua
-- 只读诊断：把“为什么材料/产物/发送任务不动”逐条算出来。
-- 结果作为日志行推给浏览器控制台（同时本地 print），不写任何文件（CC:T 磁盘很小）。
--
-- 三种模式（由 IFMMaster.lua 的 diagnose action 调用）：
--   report : 全面体检（外设 / 容器定义 / 机器 / 进程 / 发送任务 / 结论）
--   tick   : 手动跑一个 tick，直接暴露引擎异常（文件新旧混用时某方法不存在等）
--   move   : 对每一对容器真搬 1 个物品/流体再搬回来，验证目标容器能否接收

local Diagnose = {}
Diagnose.__index = Diagnose

function Diagnose.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Diagnose)
    self.Util = opts.Util
    self.Store = opts.Store
    self.Cache = opts.Cache
    self.Containers = opts.Containers
    self.Peripherals = opts.Peripherals
    self.Recipe = opts.Recipe
    --- perf（各组件耗时）/ protocol（收发统计）通常由 IFMMaster.lua 在创建后回填，
    --- 这里允许构造时直接传入；两者都缺失时 perf 诊断会给出“不可用”的提示。
    -- 性能计时（IFMMaster.lua 的 timed 收集）。
    -- 注意：字段名不能叫 self.perf —— `perf` 是本模块的方法名（`Diagnose:perf()`），
    -- 赋成表会把方法覆盖掉，诊断 perf 模式就会报 “attempt to call method 'perf' (a table value)”。
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

--- 这个资源到底躺在哪个容器定义里（逐个统计，能看出角色是不是 storage）
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

--- 全面体检报告（返回行数组）
function Diagnose:report()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end

    local summary = {}
    say("===== IFM diagnose (report) =====")
    local tickAge = self.Recipe.lastTickAt and (os.epoch("utc") - self.Recipe.lastTickAt) or -1
    say("engine: tickCount=" .. tostring(self.Recipe.tickCount or 0)
        .. " lastTickAgeMs=" .. tostring(tickAge)
        .. " (\\u5F88\\u5C0F\\u7684 lastTickAgeMs = \\u5F15\\u64CE\\u5728\\u8DD1\\uFF1BtickCount \\u4E24\\u6B21\\u8BCA\\u65AD\\u4E4B\\u95F4\\u4E0D\\u589E\\u957F = \\u5F15\\u64CE\\u6CA1\\u5728\\u8DD1)")
    if self.Recipe.lastTickError then
        say("engine lastTickError: " .. tostring(self.Recipe.lastTickError))
    end
    local counters = self.Recipe.debugCounters
    if counters then
        say("engine counters: events=" .. tostring(counters.events) .. " timers=" .. tostring(counters.timers)
            .. " websockets=" .. tostring(counters.websockets) .. " runs=" .. tostring(counters.ticks)
            .. " (timers \\u957F\\u671F\\u4E3A 0 = \\u8FD9\\u53F0\\u673A\\u5668\\u6536\\u4E0D\\u5230\\u5B9A\\u65F6\\u5668\\u4E8B\\u4EF6\\uFF0C\\u5F15\\u64CE\\u53EA\\u80FD\\u9760\\u5176\\u5B83\\u4E8B\\u4EF6\\u9A71\\u52A8)")
    end
    say("peripherals detected by CC:T:")
    for _, kind in ipairs({ "inventory", "fluid", "redstone" }) do
        local names = self.Peripherals:names(kind)
        say("  " .. kind .. ": " .. tostring(#names) .. " -> " .. joinList(names))
    end

    say("container definitions:")
    for _, def in ipairs(self.Store:list("containers")) do
        local defKind = self.Util.kindOfDef(def)
        local exists = self.Peripherals:exists(def.peripheral)
        local capable = false
        if exists then
            capable = (defKind == "fluid") and self.Peripherals:isFluid(def.peripheral)
                or self.Peripherals:isInventory(def.peripheral)
        end
        say("  " .. def.name .. " [" .. defKind .. " " .. tostring(def.role) .. "] peripheral=" .. tostring(def.peripheral)
            .. " exists=" .. tostring(exists) .. " capable=" .. tostring(capable))
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
        local problem = self.Recipe:machineProblem(machine)
        if problem then
            say("      PROBLEM: " .. tostring(problem))
        end
    end

    say("processes (runtime):")
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self.Cache:proc(process.name)
        local machine = record.machine and self.Store:get("machines", record.machine) or nil
        say("  " .. tostring(process.name) .. " machineType=" .. tostring(process.machineType)
            .. " state=" .. tostring(record.state) .. " phase=" .. tostring(record.phase)
            .. " index=" .. tostring(record.index) .. " batch=" .. tostring(record.batch)
            .. " userCount=" .. tostring(record.userCount) .. " downstream=" .. tostring(record.downstreamCount))
        say("      machine=" .. tostring(record.machine)
            .. " machineUsable=" .. tostring(machine ~= nil and self.Recipe:machineUsable(machine))
            .. " wait=" .. tostring(record.wait and record.wait.kind or "nil"))
        if record.lastError then
            say("      lastError: " .. tostring(record.lastError))
        end
        local ready, element, shortBy, index = self.Recipe:batchMaterialsReady(process, record)
        say("      batchMaterialsReady=" .. tostring(ready) .. " missingElement#=" .. tostring(index)
            .. " shortBy=" .. tostring(shortBy) .. " element=" .. tostring(element and element.id or "-"))
        if record.phase == "input" then
            local current = self.Recipe:currentElement(process, record)
            if current then
                say("      current element: kind=" .. tostring(current.kind) .. " id=" .. tostring(current.id)
                    .. " done=" .. tostring(current.done) .. "/" .. tostring(current.target))
            end
        end
        for elementIndex, el in ipairs(process.inputs or {}) do
            if el.kind == "item" or el.kind == "fluid" or el.kind == "filter" then
                local key = tostring(elementIndex)
                local required = (tonumber(el.count) or 0) * (record.batch or 1)
                local doneCount = (record.progress or {})[key] or 0
                local itemTargets = machine and self.Recipe:inputContainers(machine, "item", el.containerIndex) or {}
                local fluidTargets = machine and self.Recipe:inputContainers(machine, "fluid", el.containerIndex) or {}
                local spec = { kind = el.kind, id = el.id, nbt = el.nbt, ignoreNbt = el.ignoreNbt }
                local inStorage = self.Containers:countOf(spec, "storage")
                local inTargets = self.Recipe:alreadyInTargets(spec, itemTargets, fluidTargets)
                local need = required - doneCount
                local verdict
                if not machine then
                    verdict = "NO MACHINE SELECTED (record.machine=" .. tostring(record.machine) .. ")"
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
        if record.phase == "output" then
            local outputIndex = tonumber(record.index) or 1
            local el = (process.outputs or {})[outputIndex]
            if type(el) == "table"
                and (el.kind == "item" or el.kind == "fluid" or el.kind == "filter") then
                local batch = record.batch or 1
                local maxAmount = (tonumber(el.max) or 0) * batch
                local minAmount = (tonumber(el.min) or 0) * batch
                local collected = (record.outProgress or {})[tostring(outputIndex)] or 0
                local spec = { kind = el.kind, id = el.id, nbt = el.nbt, ignoreNbt = el.ignoreNbt }
                local inMachine = machine and self.Recipe:machineRemaining(spec, machine) or 0
                local inStorage = self.Containers:countOf(spec, "storage")
                local gained = self.Recipe:storageGain(spec, record)
                local verdict
                if not machine then
                    verdict = "NO MACHINE SELECTED"
                elseif collected >= maxAmount or gained >= maxAmount then
                    verdict = "DONE"
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
    end

    say("deliveries (Sending queue):")
    local deliveries = self.Cache:deliveries()
    if #deliveries == 0 then
        say("  (empty)")
    end
    for _, delivery in ipairs(deliveries) do
        local spec = { kind = delivery.kind, id = delivery.name }
        local remaining = tonumber(delivery.remaining) or 0
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
                .. tostring(self.Containers:unusableReason(delivery.container, containerKind)) .. ")"
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

--- 现场真搬 1 个物品/流体再搬回来（验证目标容器能否接收）
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
                        --- 探针要立刻看到搬运结果，所以临时摘掉 IFMWorker 调度器（搬完装回）
                        local provider = self.Containers.transfer
                        self.Containers:setTransferProvider(nil)
                        if toKind == "item" then
                            moved, reason = self.Containers:pushItem(fromDef.name, sampleSlot, 1, toDef.name)
                        else
                            moved, reason = self.Containers:pushFluid(fromDef.name, 1, sampleName, toDef.name)
                        end
                        moved = tonumber(moved) or 0
                        say("  " .. fromDef.name .. " -> " .. toDef.name .. " (" .. tostring(sampleName)
                            .. ") moved=" .. tostring(moved) .. " reason=" .. tostring(reason))
                        if moved > 0 then
                            local backMoved, backReason
                            if toKind == "item" then
                                backMoved, backReason = self.Containers:pushItem(toDef.name, 1, moved, fromDef.name)
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

--- 手动跑一个 tick：直接暴露引擎异常（例如文件新旧混用时某个方法不存在）
function Diagnose:tickProbe()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    say("===== IFM diagnose (manual tick) =====")
    local ok, err = pcall(self.Recipe.tick, self.Recipe, os.epoch("utc"))
    say("tick: " .. (ok and "ok" or ("ERROR -> " .. tostring(err))))
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

--- 性能诊断（诊断模式 perf）：各组件耗时 + 协议层收发字节 + 事件循环计数 + 规模。
--- 服务端“运行缓慢”时先看这里：哪个组件耗时长、哪个 action 的包最大/最频繁。
function Diagnose:perf()
    local out = {}
    local function say(...)
        out[#out + 1] = line(...)
    end
    local function kb(bytes)
        return string.format("%.1fKB", (tonumber(bytes) or 0) / 1024)
    end

    say("===== IFM diagnose (perf) =====")

    --- 1) 各组件耗时（IFMMaster.lua 的 timed() 收集，按总耗时排序）
    --- 字段是 perfStats（不是 self.perf：那是本方法自己的名字，见 Diagnose.new 的说明）
    local timings = {}
    for _, stat in pairs(self.perfStats or {}) do
        timings[#timings + 1] = stat
    end
    table.sort(timings, function(a, b)
        if (a.total or 0) ~= (b.total or 0) then
            return (a.total or 0) > (b.total or 0)
        end
        return tostring(a.label) < tostring(b.label)
    end)
    say("component timings (label / calls / avg / max / total / calls>=500ms):")
    if #timings == 0 then
        say("  (no samples yet - the main loop has not run since startup)")
    end
    for _, stat in ipairs(timings) do
        local count = stat.count or 0
        say(string.format("  %-22s n=%-6d avg=%4dms max=%6dms total=%8dms slow=%d",
            tostring(stat.label),
            count,
            count > 0 and math.floor((stat.total or 0) / count) or 0,
            stat.max or 0,
            stat.total or 0,
            stat.slow or 0))
    end

    --- 2) 协议层收发统计（protocol.lua 收集）
    --- 注意：方法是 statsSummary（`stats` 是实例上的原始计数字段，会把同名方法遮蔽掉）
    local protocol = self.protocol
    if protocol and protocol.statsSummary then
        local okStats, summary = pcall(protocol.statsSummary, protocol)
        if okStats and type(summary) == "table" then
            local seconds = math.max(1, summary.uptimeSeconds or 0)
            say(string.format("protocol: sent %d msg %s (max %s) / recv %d msg %s (max %s)",
                summary.sentMessages or 0, kb(summary.sentBytes), kb(summary.sentMax),
                summary.recvMessages or 0, kb(summary.recvBytes), kb(summary.recvMax)))
            say(string.format("protocol: rate sent=%s/s recv=%s/s over %ds",
                kb((summary.sentBytes or 0) / seconds), kb((summary.recvBytes or 0) / seconds), seconds))
            say(string.format("protocol: last push cost %dms -> auto interval max(%ds, 3x cost) = %dms",
                summary.lastPushCost or 0, summary.updateInterval or 1,
                math.max((summary.updateInterval or 1) * 1000, (summary.lastPushCost or 0) * 3)))
            say(string.format("protocol: pushes=%d skipped=%d fullSyncs=%d changedItems=%d dropped=%d failed=%d encodeFailed=%d",
                summary.pushes or 0, summary.pushSkipped or 0, summary.fullSyncs or 0,
                summary.changedItems or 0, summary.dropped or 0, summary.failed or 0,
                summary.encodeFailed or 0))
            --- 连接生命周期（闪断排查）：多久断一次、是谁断的、断在连上后第几秒
            say(string.format("protocol link: connectRequests=%d failures=%d timeouts=%d reconnects=%d",
                summary.connectRequests or 0, summary.connectFailures or 0,
                summary.connectTimeouts or 0, summary.reconnects or 0))
            say(string.format("protocol link: pending=%d expected=%d abandoned=%d extras=%d",
                summary.pendingAcks or 0, summary.expectedAcks or 0,
                summary.abandoned or 0, summary.extraHandles or 0))
            say(string.format("protocol link: closes=%d (relay=%d, own=%d, stale=%d) connectedFor=%ds idle=%ds",
                summary.closes or 0,
                math.max(0, (summary.closes or 0) - (summary.ownCloses or 0) - (summary.staleCloses or 0)),
                summary.ownCloses or 0, summary.staleCloses or 0,
                summary.connectedSeconds or 0, summary.idleSeconds or 0))
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
                say(string.format("  %-26s n=%-6d total=%-10s avg=%-9s max=%s",
                    tostring(entry.key), entry.count or 0, kb(entry.bytes),
                    kb(entry.average or 0), kb(entry.max)))
            end
        else
            say("protocol: stats unavailable (" .. tostring(summary) .. ")")
        end
    else
        say("protocol: not available")
    end

    --- 2.5) 任务调度器（1.7.0）：每条队列的深度 / 服务数 / 丢弃数 + 本轮耗时。
    --- 这里是"为什么慢 / 为什么 worker 空着"的第一现场：
    ---   * mode=local   没有 worker → 主控本机执行，每次调度只推进一步；
    ---   * mode=remote  有 worker 且有空闲 → 队列轮转（派给 worker）；
    ---   * mode=paused  有 worker 但都忙 → 本次调度不推进队列（这期间 worker 会一直有活）。
    --- 看深度：某条队列深度一直是 0 而 steps 很小，说明瓶颈不在这条队列；
    --- 深度一直涨而 steps 不涨 → 队列被能力门控挡住（没有具备该能力的空闲 worker）。
    if self.dispatch and self.dispatch.status then
        local okDispatch, dispatchStatus = pcall(self.dispatch.status, self.dispatch)
        if okDispatch and type(dispatchStatus) == "table" then
            say(string.format("scheduler: mode=%s runs=%d steps=%d (local=%d remote=%d) paused=%d inflight=%d writes=%d",
                tostring(dispatchStatus.mode), dispatchStatus.runs or 0, dispatchStatus.steps or 0,
                dispatchStatus.localSteps or 0, dispatchStatus.remoteSteps or 0,
                dispatchStatus.paused or 0, dispatchStatus.inflight or 0, dispatchStatus.writes or 0))
            if self.Store and self.Store.scheduleSettings then
                local okSched, sched = pcall(self.Store.scheduleSettings, self.Store)
                if okSched and type(sched) == "table" then
                    local parts = {}
                    for _, queue in ipairs(sched.queues or {}) do
                        parts[#parts + 1] = queue .. "=" .. tostring((sched.slices or {})[queue] or 1)
                    end
                    say("scheduler slices: " .. table.concat(parts, " "))
                end
            end
            say(string.format("scheduler: per-run last=%.1fms avg=%.1fms max=%.1fms cursor=%s uptime=%ds",
                tonumber(dispatchStatus.lastMs) or 0, tonumber(dispatchStatus.avgMs) or 0,
                tonumber(dispatchStatus.maxMs) or 0, tostring(dispatchStatus.cursor),
                dispatchStatus.uptimeSeconds or 0))
            say(string.format("scheduler guards: duplicateQueues=%d missingRunner=%d idleProcessInQueue=%d",
                dispatchStatus.duplicateQueues or 0, dispatchStatus.missingRunner or 0,
                (self.engine and self.engine.guardCounters and self.engine.guardCounters.idleProcessInQueue) or 0))
            say("scheduler queues (name weight-cum-stats depth inflight served done dropped retried needs):")
            for _, queue in ipairs(dispatchStatus.queues or {}) do
                say(string.format("  %-13s slice=%-3s depth=%-5s inflight=%-3s served=%-7s done=%-7s dropped=%-5s retried=%-5s needs=%s",
                    tostring(queue.name), tostring(queue.slice), tostring(queue.depth),
                    tostring(queue.inflight), tostring(queue.served), tostring(queue.done),
                    tostring(queue.dropped), tostring(queue.retried), tostring(queue.needs)))
            end
        else
            say("scheduler: status unavailable (" .. tostring(dispatchStatus) .. ")")
        end
    else
        say("scheduler: not available")
    end

    --- 2.6) IFMWorker 搬运卸载（有 worker 时 IFM 自己不再搬东西）
    if self.transfer and self.transfer.status then
        local okTransfer, transferStats = pcall(self.transfer.status, self.transfer)
        if okTransfer and type(transferStats) == "table" then
            say(string.format("IFMWorker: workers=%d busy=%d idle=%d pending=%d channel=%s",
                transferStats.workers or 0, transferStats.busy or 0, transferStats.idle or 0,
                transferStats.pending or 0, tostring(transferStats.channel or "-")))
            say(string.format("IFMWorker: submitted=%d done=%d failed=%d timedOut=%d localMoves=%d",
                transferStats.submitted or 0, transferStats.done or 0, transferStats.failed or 0,
                transferStats.timedOut or 0, transferStats.localMoves or 0))
            --- 1.7.0：代扫机制已删除（容器扫描走 storageScan / inputScan 队列），
            --- 这里只报告 worker 侧的在飞任务数（快照统计见下面的 container snapshot 段）
            say(string.format("IFMWorker: idle=%d/%d movers=%d queriers=%d",
                transferStats.idle or 0, transferStats.workers or 0,
                transferStats.idleMovers or 0, transferStats.idleQueriers or 0))
            say(string.format("IFMWorker: usable=%d unknownVersion=%d versionMismatch=%d inFlight=%d (master=%s)",
                transferStats.usable or 0, transferStats.versionUnknown or 0,
                transferStats.versionMismatch or 0, transferStats.inFlightWorkers or 0,
                tostring((self.protocol and self.protocol.version) or "?")))
            --- 容器扫描的代扫统计（1.7.0 P1 仍是旧实现；P2 会并入 storageScan/inputScan 队列）
        else
            say("IFMWorker: status unavailable (" .. tostring(transferStats) .. ")")
        end
    else
        say("IFMWorker: not available")
    end

    --- 2.6) 容器扫描耗时（按外设名）：一次推送 / 一个 tick 要把所有容器 list() 一遍，
    --- 这里能直接看出“哪个容器最慢”——avg 几十毫秒就说明它是主循环变慢的根源。
    if self.Containers and self.Containers.scanStatsSummary then
        -- 自适应缓存：读取一次越慢，缓存放得越久（扫描最多占用主循环 ~1/multiplier）
        if self.Containers.scanSummary then
            local okSummary, scan = pcall(self.Containers.scanSummary, self.Containers)
            if okSummary and type(scan) == "table" then
                say(string.format("container snapshot: containers=%s scanned=%s readCost=%sms passCost=%sms reads=%s readMs=%sms staleMax=%s staleAvg=%s (ticks)",
                    tostring(scan.containers), tostring(scan.scanned), tostring(scan.readCost),
                    tostring(scan.passCost), tostring(scan.reads), tostring(scan.readMs),
                    tostring(scan.staleTicks or 0), tostring(scan.staleAvgTicks or 0)))
                if self.Containers.snapshotSummary then
                    local okSnap, snap = pcall(self.Containers.snapshotSummary, self.Containers)
                    if okSnap and type(snap) == "table" then
                        say(string.format("container snapshot detail: reservations=%d settled=%d swept=%d inFlight=%d results=%d",
                            snap.pending or 0, snap.settled or 0, snap.swept or 0, snap.inflight or 0,
                            snap.results or 0))
                    end
                end
            end
        end
        local okScans, scans = pcall(self.Containers.scanStatsSummary, self.Containers, 12)
        if okScans and type(scans) == "table" and #scans > 0 then
            say("container scans (peripheral / calls / avg / max / total / item vs fluid):")
            for _, entry in ipairs(scans) do
                local calls = tonumber(entry.calls) or 0
                say(string.format("  %-28s n=%-6d avg=%5dms max=%6dms total=%8dms item=%d fluid=%d",
                    tostring(entry.name), calls,
                    calls > 0 and math.floor((entry.total or 0) / calls) or 0,
                    entry.max or 0, entry.total or 0,
                    entry.item or 0, entry.fluid or 0))
            end
        else
            say("container scans: (no samples yet - nothing has been scanned since startup)")
        end
    end

    --- 2.5) IFMWorker（分布式工作节点）：只做「搬运」与「查询」
    if self.transfer and self.transfer.workersForUi then
        local okWorkers, workers = pcall(self.transfer.workersForUi, self.transfer)
        if okWorkers and type(workers) == "table" then
            if #workers == 0 then
                say("IFMWorker: none online (run IFMWorker.lua on another computer)")
            else
                say(string.format("IFMWorker: %d online (each worker only moves and queries items/fluids)", #workers))
            end
            for _, worker in ipairs(workers) do
                local caps = {}
                if worker.move then caps[#caps + 1] = "move" end
                if worker.query then caps[#caps + 1] = "query" end
                local tasks = worker.tasks or {}
                say(string.format("  #%-4s %-16s [%s] jobs=%d moved=%d queries=%d pending=%d age=%ds%s",
                    tostring(worker.id), tostring(worker.name), table.concat(caps, ","),
                    worker.jobs or 0, worker.moved or 0, worker.queries or 0, worker.pending or 0,
                    worker.stateAge or 0,
                    (worker.stateAge == nil) and " (no state yet)" or ""))
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
                        tonumber(worker.details) or 0, tonumber(worker.detailItems) or 0))
                end
            end
        else
            say("IFMWorker: status unavailable (" .. tostring(workers) .. ")")
        end
    end
    --- 物品详情代查（getItemDetail 打包给 worker）：主控本机调用次数越多 = 阻塞越多
    if self.transfer and self.transfer.detailStatus then
        local okDetail, detail = pcall(self.transfer.detailStatus, self.transfer)
        if okDetail and type(detail) == "table" then
            say(string.format("item detail offload: batches=%d done=%d items=%d pending=%d failed=%d queriers=%d",
                detail.submitted or 0, detail.done or 0, detail.items or 0, detail.pending or 0,
                detail.failed or 0, detail.queriers or 0))
            if self.Containers and self.Containers.localDetailCalls then
                say(string.format("  getItemDetail called on the master: %d time(s) (0 is ideal; " ..
                    "each one blocks ~1 game tick)", self.Containers.localDetailCalls))
            end
        end
    end

    --- 3) 事件循环计数（timers 长期为 0 = 这台机器收不到定时器事件）
    local counters = self.Recipe and self.Recipe.debugCounters
    if counters then
        say(string.format("events: events=%d timers=%d websockets=%d engineRuns=%d",
            counters.events or 0, counters.timers or 0, counters.websockets or 0, counters.ticks or 0))
    end

    --- 4) 规模（定义/资源越多，每 tick 与每次推送的开销越大）
    say(string.format("scale: containers=%d signals=%d filters=%d machineTypes=%d machines=%d processes=%d deliveries=%d",
        #(self.Store:list("containers") or {}),
        #(self.Store:list("signals") or {}),
        #(self.Store:list("filters") or {}),
        #(self.Store:list("machineTypes") or {}),
        #(self.Store:list("machines") or {}),
        #(self.Store:list("processes") or {}),
        #(self.Cache:deliveries() or {})))

    --- 5) 怎么读这份报告
    say("how to read this:")
    say("  * log line 'Slow <label>: Nms (calls=.. avg=.. max=.. slow=..)' = one call of that")
    say("    component took N ms; slow counts how many calls were >= 500 ms.")
    say("  * 'engine tick' / 'protocol event' / 'tag auto scan' each scan ALL containers; one full")
    say("    scan costs the sum of 'container scans' below. That cost is CONSTANT, so it does not")
    say("    drop when the factory is idle - it is peripheral scanning, not diffing.")
    say("  * compare events/timers with engineRuns: if events/timers are much larger than engineRuns,")
    say("    every loop iteration is blocked by the scans (engine tick + push + tag scan).")
    say("  * 'container scans' (section above) = per-peripheral list()/tanks() cost: tens of ms for")
    say("    one container means that block or the wired network is what slows everything down.")
    say("  * big send:incremental_update = one full sync when a browser connects (all categories at")
    say("    once); later pushes happen at most once per updateInterval (default 1s) and after a")
    say("    request (throttled by minPushInterval - heartbeats never trigger a push).")
    say("  * timers=0 while events grows = this computer gets no timer events (engine only moves")
    say("    when other events arrive).")
    say("===== end of perf probe =====")
    return out
end

return Diagnose
