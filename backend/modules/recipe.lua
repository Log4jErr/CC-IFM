-- IFM :: modules/recipe.lua
-- 流程引擎：非阻塞状态机，负责机器选择（轮换）、并行闸门、按序输入/输出、
-- 翻倍、递归启动上游流程、缺失判定、待交付（发送）队列，并把运行态写入 cache.json。

local Recipe = {}
Recipe.__index = Recipe

local MAX_CHAIN_DEPTH = 8

--- 抽象流程（含"注册名 = abstract"的物品/流体操作的流程）不能执行 / 合成：它只作为"流程设置复制"的来源。
--- 网页上把这类流程排在下拉框最前，就是让用户先复制它再去改真实材料。
local ABSTRACT_MESSAGE = "\\u62BD\\u8C61\\u6D41\\u7A0B\\uFF08\\u542B abstract \\u64CD\\u4F5C\\uFF09\\u4E0D\\u80FD\\u7528\\u4E8E\\u5408\\u6210\\uFF0C\\u53EA\\u80FD\\u4F5C\\u4E3A\\u6D41\\u7A0B\\u8BBE\\u7F6E\\u7684\\u590D\\u5236\\u6765\\u6E90"
local ABSTRACT_FROZEN = "\\u6D41\\u7A0B\\u662F\\u62BD\\u8C61\\u6D41\\u7A0B\\uFF08\\u542B abstract \\u64CD\\u4F5C\\uFF09\\uFF0C\\u4E0D\\u80FD\\u6267\\u884C\\uFF1A\\u53EA\\u80FD\\u7528\\u4E8E\\u590D\\u5236\\u6D41\\u7A0B\\u8BBE\\u7F6E"

--- 未指定方向时的默认方向：六面全开（网页端新建元素时默认也是六面全选）
local ALL_SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- 红石脉冲的保持时间：置位 0.05s -> 复位 0.05s
local PULSE_HOLD_MS = 50

--- 单批次的元素需求量
local function elementDemand(element, batch)
    return (tonumber(element.count) or 0) * (batch or 1)
end

--- 元素对应的资源描述（含 NBT 比较语义：ignoreNbt 为 false 时要求 NBT 相等）
local function elementSpec(element)
    return {
        kind = element.kind,
        id = element.id,
        nbt = element.nbt,
        ignoreNbt = element.ignoreNbt,
    }
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

--- 读取红石外设某方向的模拟输入
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

--- 写入红石外设某方向的模拟输出
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
    self.Store = opts.Store
    self.Cache = opts.Cache
    self.Peripherals = opts.Peripherals
    self.Containers = opts.Containers
    self.Filter = opts.Filter
    self.log = opts.log or function() end
    --- 一步的预算（1.7.0）：流程队列一次只推进"一步" —— 一次材料输入/产物抽出调用算一步，
    --- 无论它是否搬满（搬不完就让位，回队列尾）。这样机器还在合成时，进程不会一直卡在
    --- "等产物抽取"上。
    self.stepBudget = 1
    --- 存储整理（网页手动触发）：每个 tick 最多执行多少次搬运，避免一次整理卡住主循环
    self.compactOpsPerTick = opts.compactOpsPerTick or 3
    --- 自动整理的空槽位阈值（用户第 4 项）：存储容器空槽位比例 ≥ 它时**不整理**
    --- （空槽位还够多，搬来搬去没意义）；默认 0.10 = 空槽位不足 10% 才整理。
    --- 网页「设置」里可改，见 Recipe:setCompactFreeRatio / Store.SCHEDULE_COMPACT_FREE_DEFAULT。
    self.compactFreeRatio = tonumber(opts.compactFreeRatio) or 0.10
    --- 引擎存活信息（诊断用）：tick 次数、最后一次 tick 时间、最后一次 tick 异常
    self.tickCount = 0
    self.lastTickAt = 0
    self.lastTickError = nil
    --- 最近一次 tick 的细分计数（诊断/慢 tick 明细用）：推进了几个流程、真正读了几次外设、读了多少毫秒
    self.tickStats = { steps = 0, active = 0, processes = 0, reads = 0, readMs = 0 }
    return self
end

--- 记录/读取流程运行态
function Recipe:record(name)
    return self.Cache:proc(name)
end

--- 该流程是不是"抽象流程"（含注册名为 abstract 的物品/流体操作）：抽象流程不能执行、
--- 不能被选作上游、不能下单合成，只作为网页"流程设置复制"的来源。
function Recipe:isAbstract(process)
    return self.Store.processIsAbstract(process)
end

--- 该类型的全部机器定义（按名称排序）
function Recipe:machinesOfType(typeName)
    local list = {}
    for _, machine in ipairs(self.Store:list("machines")) do
        if machine.type == typeName then
            list[#list + 1] = machine
        end
    end
    return list
end

--- 机器的信号项 → 中继器外设名（1.6.9）：
---   * 旧配置写的是“信号定义名” → 查定义拿它的外设；
---   * 现在信号不需要命名，机器里直接写外设名 → 就把它当成外设名（返回它自己）。
--- 返回：中继器外设名, 用于显示/日志的名字（解析不到时返回 nil）
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

--- 机器引用的容器/信号外设是否齐全（物品列表要 inventory，流体列表要 fluid_storage）
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

--- 机器为什么不可用（可用时返回 nil）：逐项检查引用的容器与信号，返回可读原因
function Recipe:machineProblem(machine)
    local lists = {
        { list = machine.itemInputs, kind = "item", label = "\\u7269\\u54C1\\u8F93\\u5165\\u5BB9\\u5668" },
        { list = machine.fluidInputs, kind = "fluid", label = "\\u6D41\\u4F53\\u8F93\\u5165\\u5BB9\\u5668" },
        { list = machine.itemOutputs, kind = "item", label = "\\u7269\\u54C1\\u8F93\\u51FA\\u5BB9\\u5668" },
        { list = machine.fluidOutputs, kind = "fluid", label = "\\u6D41\\u4F53\\u8F93\\u51FA\\u5BB9\\u5668" },
    }
    for _, entry in ipairs(lists) do
        for _, containerName in ipairs(entry.list or {}) do
            if not self.Containers:supports(containerName, entry.kind) then
                return tostring(entry.label) .. " " .. tostring(containerName) .. " "
                    .. (self.Containers:unusableReason(containerName, entry.kind) or "\\u4E0D\\u53EF\\u7528")
            end
        end
    end
    for _, signalEntry in ipairs(machine.signals or {}) do
        local peripheral, label = self:signalPeripheralOf(signalEntry)
        if not peripheral then
            return "\\u4FE1\\u53F7\\u5B9A\\u4E49 " .. tostring(signalEntry) .. " \\u4E0D\\u5B58\\u5728"
        end
        if not self.Peripherals:exists(peripheral) then
            return "\\u4FE1\\u53F7 " .. tostring(label) .. " \\u7684\\u4E2D\\u7EE7\\u5668 " .. tostring(peripheral) .. " \\u4E0D\\u5B58\\u5728"
        end
    end
    return nil
end

--- 在同类机器间轮换选择可用机器（第 20 条：记忆轮换次序，避免集中在单台机器）
function Recipe:chooseMachine(typeName)
    local list = self:machinesOfType(typeName)
    if #list == 0 then
        return nil, "\\u673A\\u5668\\u7C7B\\u578B " .. tostring(typeName) .. " \\u8FD8\\u6CA1\\u6709\\u53EF\\u7528\\u673A\\u5668"
    end
    local total = #list
    local record = self.Cache:machineType(typeName)
    local start = (tonumber(record.rrIndex) or 0) % total
    local unusable = 0
    for offset = 0, total - 1 do
        local position = (start + offset) % total + 1
        local machine = list[position]
        if self:machineUsable(machine) then
            local usage = self.Cache:machine(machine.name)
            if (usage.running or 0) < (machine.parallel or 1) then
                record.rrIndex = position % total
                self.Cache:markDirty()
                return machine
            end
        else
            unusable = unusable + 1
        end
    end
    if unusable == total then
        return nil, "\\u540C\\u7C7B\\u673A\\u5668\\u5F15\\u7528\\u7684\\u5BB9\\u5668\\u4E0D\\u53EF\\u7528\\uFF08\\u68C0\\u67E5\\u5BB9\\u5668\\u79CD\\u7C7B\\u3001\\u5916\\u8BBE\\u4E0E\\u89D2\\u8272\\uFF09"
    end
    return nil, "\\u540C\\u7C7B\\u673A\\u5668\\u90FD\\u6CA1\\u6709\\u7A7A\\u95F2\\u7684\\u5E76\\u884C\\u4F4D"
end

--- 占用/释放并行位
function Recipe:occupyMachine(machineName, delta)
    local usage = self.Cache:machine(machineName)
    usage.running = math.max(0, (usage.running or 0) + delta)
    self.Cache:markDirty()
end

--- 机器当前并行占用（网页展示用）
function Recipe:machineUsage()
    local out = {}
    for _, machine in ipairs(self.Store:list("machines")) do
        local usage = self.Cache:machine(machine.name)
        out[#out + 1] = {
            name = machine.name,
            type = machine.type,
            parallel = machine.parallel or 1,
            running = usage.running or 0,
        }
    end
    return out
end

--- 解析元素涉及的中继器外设（只认机器定义的信号序号：机器 signals 列表的序号，从 1 开始）
function Recipe:resolveSignals(machine, element)
    local result = {}
    local sides = element.sides or {}
    if #sides == 0 then
        sides = ALL_SIDES
    end
    local machineSignalIndex = tonumber(element.machineSignalIndex) or -1
    if machineSignalIndex >= 1 and machine then
        local signalEntry = (machine.signals or {})[machineSignalIndex]
        --- 信号项可能是旧的“信号定义名”，也可能就是中继器的外设名（1.6.9 起不再需要命名）
        local peripheral, label = self:signalPeripheralOf(signalEntry)
        if peripheral then
            result[#result + 1] = { peripheral = peripheral, sides = sides, signalName = label }
        end
    end
    return result
end

--- 等待红石信号是否满足（任一中继器的任一指定方向满足比较式即视为满足）
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

--- 把一组 { peripheral, side } 目标写成指定强度（同时记录/清除红石输出，便于重启后恢复）
function Recipe:switchSignals(targets, strength)
    local emitted = false
    for _, target in ipairs(targets or {}) do
        local peripheralTable = self.Peripherals:wrap(target.peripheral)
        if peripheralTable then
            if writeAnalog(peripheralTable, target.side, strength) then
                emitted = true
                local key = target.peripheral .. "/" .. target.side
                -- 0 强度也记下来：重启后 restoreSignals 会把脉冲的“复位”状态写回去（不会卡在通电）
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

--- 元素引用的红石目标（机器红石信号序号 -> 机器定义的信号列表 -> 信号定义的中继器）
function Recipe:signalTargets(machine, element)
    local targets = {}
    for _, entry in ipairs(self:resolveSignals(machine, element)) do
        for _, side in ipairs(entry.sides) do
            targets[#targets + 1] = { peripheral = entry.peripheral, side = side }
        end
    end
    return targets
end

--- 设置红石信号：把指定方向写成固定强度（等待红石信号才需要阈值/比较，这里不需要）
function Recipe:emitSignals(machine, element)
    local strength = math.floor(tonumber(element.strength) or 15)
    local emitted = self:switchSignals(self:signalTargets(machine, element), strength)
    if not emitted then
        self.log("Emit signal failed: no usable redstone relay peripheral")
    end
    return emitted
end

--- 发出红石脉冲：先置位（强度），后续由 advancePulse 依次“等 0.05s -> 复位 -> 等 0.05s”
function Recipe:startPulse(machine, element, record, now, nextIndex)
    local targets = self:signalTargets(machine, element)
    if #targets == 0 then
        self.log("Pulse signal failed: no usable redstone relay peripheral")
        return false
    end
    local strength = math.floor(tonumber(element.strength) or 15)
    self:switchSignals(targets, strength)
    record.pulse = {
        index = math.max(1, tonumber(nextIndex) or ((record.index or 1) + 1)),
        phase = "on",
        untilMs = now + PULSE_HOLD_MS,
        targets = targets,
        strength = strength,
    }
    self.Cache:markDirty()
    return true
end

--- 推进红石脉冲：返回 true 表示该元素已处理完（可以继续下一个），false 表示本 tick 还要等
function Recipe:advancePulse(record, now)
    local pulse = record.pulse
    if not pulse then
        return true
    end
    if now < (pulse.untilMs or 0) then
        return false
    end
    if pulse.phase == "on" then
        -- 复位（写 0 并记录 0 强度）
        self:switchSignals(pulse.targets, 0)
        pulse.phase = "off"
        pulse.untilMs = now + PULSE_HOLD_MS
        self.Cache:markDirty()
        return false
    end
    record.pulse = nil
    record.index = math.max(1, tonumber(pulse.index) or ((record.index or 1) + 1))
    self.Cache:markDirty()
    return true
end

--- 恢复上次运行时的红石输出（第 25 条：重启后恢复）
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

--- 机器输入容器（containerIndex >= 1 时取指定序号；否则取全部）
function Recipe:inputContainers(machine, resourceKind, containerIndex)
    if not machine then
        -- 没有机器时按“没有可用输入容器”处理，绝不索引 nil（否则整条 tick 会崩）
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

--- 机器输出容器
function Recipe:outputContainers(machine, resourceKind)
    if not machine then
        return {}
    end
    local list
    if resourceKind == "fluid" then
        list = machine.fluidOutputs or {}
    else
        list = machine.itemOutputs or {}
    end
    local out = {}
    for _, name in ipairs(list) do
        out[#out + 1] = name
    end
    return out
end

--- ===== 在飞搬运的记忆（1.6.7：修「要 64 个却搬了 127 个」）=====
--- worker 搬运是异步的：主控发出 task 后要等它回报。回报之前调用方必须继续等同一条请求，
--- 绝不能按“这一 tick 重新扫到的槽位”再发一条 —— 那会把同一批货搬两遍。
--- 用户实测的现象：要 64 个，worker 先把某个槽位里的 63 个搬走；下一 tick 缓存刷新后，
--- 那个槽位空了，于是主控又从另一个槽位发了 64 个出去 → 一共 127 个。
--- 这里按 token（调用方给的稳定标记：流程名 + 元素 key / 发货任务 id）记住那条请求，
--- 回报回来再记账，之后才允许重新扫源找下一批。
local PENDING_MOVE_TTL = 45000      -- 超过这么久还没回报的记忆一律丢掉（worker 早就超时了）

--- 记下一条已经交给 worker 的搬运（token 由调用方给，见上面说明）
function Recipe:rememberPendingMove(token, record)
    if not token then
        return
    end
    self.pendingMoves = self.pendingMoves or {}
    record.at = os.epoch("utc")
    self.pendingMoves[token] = record
end

--- 忘掉某个 token 的在飞搬运（元素完成 / 发货任务结束 / 流程被复位时调用）
function Recipe:forgetPendingMove(token)
    if token and self.pendingMoves then
        self.pendingMoves[token] = nil
    end
end

--- 按前缀批量忘掉（流程被停止 / 复位时用）
function Recipe:forgetPendingMovesWithPrefix(prefix)
    if not self.pendingMoves or type(prefix) ~= "string" then
        return
    end
    local size = #prefix
    for token in pairs(self.pendingMoves) do
        if string.sub(token, 1, size) == prefix then
            self.pendingMoves[token] = nil
        end
    end
end

--- 清掉过期的记忆（每个 tick 调一次，表很小）
function Recipe:sweepPendingMoves(now)
    if not self.pendingMoves then
        return
    end
    local nowMs = now or os.epoch("utc")
    for token, record in pairs(self.pendingMoves) do
        if nowMs - (record.at or 0) > PENDING_MOVE_TTL then
            self.pendingMoves[token] = nil
        end
    end
end

--- 继续等 / 取回上一次交给 worker 的那条搬运（见 transferIn / transferOut 的 token 参数）
--- 返回：
---   nil, "pending"   还在 worker 手上：这一 tick 什么都别做
---   moved, reason    有结果了（记忆已清掉，调用方照常记账；moved 可能是 0 + 失败原因）
---   nil, nil         没有在飞的搬运
function Recipe:resumePendingMove(token)
    local record = token and self.pendingMoves and self.pendingMoves[token]
    if not record then
        return nil, nil
    end
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

--- 输入：从存储容器搬运匹配资源到目标容器（itemTargets / fluidTargets 分别对应物品与流体输入容器）
--- token：调用方的一致性标记（同一逻辑搬运每次都要传同一个值，见在飞搬运的记忆）
--- 返回：实际搬运量, 失败原因（未搬运到任何东西时才有；"pending" = 已交给 worker）
--- opts（可选，1.6.11）：
---   storageOrder  从存储容器抽取时的顺序（"speed" = 先拿最多的堆，机器要料求快；
---                 "fragment" = 先拿最少的那堆，发货/输出容器求少碎片）
---   insertMode    往目标容器放入时的策略（见 pushItem 的 mode 参数）
function Recipe:transferIn(spec, itemTargets, fluidTargets, toSlot, amount, token, opts)
    --- 1.7.0：这次搬运进哪条队列（默认"库存输入" = 送料进机器；发货用 opts.queue = "inventoryOut"）
    local queueName = (type(opts) == "table" and opts.queue) or "inventoryIn"
    --- 用户第 2 项：流体**从不指定槽位**（流程里的"输入流体槽位"参数已移除）——
    --- 老配置里残留的值也一律忽略，免得"看起来指定了、实际不起作用"。
    if type(spec) == "table" and spec.kind == "fluid" then
        toSlot = nil
    end
    if amount <= 0 then
        return 0, nil
    end
    opts = opts or {}
    local moved = 0
    local reason
    if token then
        --- 上一次这条搬运交给了 worker、还没回报：先取它的结果（绝不再扫源重发）
        local got, pendingReason = self:resumePendingMove(token)
        if pendingReason == "pending" then
            --- 结果是 nil（还没回报）；如果刚才取回了上一批的数量，moved 会 > 0 一起返回给调用方记账
            return moved, "pending"
        end
        if got then
            moved = got
        end
        if moved >= amount then
            return moved, nil
        end
    end
    local stacks, tanks = self.Containers:matchSpec(spec, "storage", opts.storageOrder)
    if #itemTargets > 0 and spec.kind ~= "fluid" then
        for _, stack in ipairs(stacks) do
            if moved >= amount then
                break
            end
            -- 只有“目标就是同一个容器定义”才算资源已在目标里；
            -- 两个不同定义指向同一个方块属于配置问题，交给 pushItem 报出确切原因（绝不伪造“已搬运”）
            local alreadyThere = false
            if not (toSlot and toSlot >= 1) then
                for _, target in ipairs(itemTargets) do
                    if target == stack.container then
                        alreadyThere = true
                        break
                    end
                end
            end
            if alreadyThere then
                moved = math.min(amount, moved + stack.count)
            else
                for _, target in ipairs(itemTargets) do
                    if moved >= amount then
                        break
                    end
                    local want = math.min(amount - moved, stack.count)
                    if want > 0 then
                        local got, err = self.Containers:pushItem(stack.container, stack.slot, want, target, toSlot,
                            opts.insertMode)
                        if err == "pending" then
                            --- IFMWorker 正在搬：记住这条请求（下个 tick 继续等它，绝不重新扫源）
                            self:rememberPendingMove(token, {
                                kind = "item",
                                container = stack.container,
                                slot = stack.slot,
                                want = want,
                                target = target,
                                toSlot = toSlot,
                                mode = opts.insertMode,
                            })
                            --- 返回已经取回的 moved（可能 > 0）：调用方要拿它记账，否则会重复搬
                            return moved, "pending"
                        end
                        got = tonumber(got) or 0
                        if got > 0 then
                            moved = moved + got
                            self.Containers:invalidate()
                        elseif err then
                            reason = reason or err
                        end
                    end
                end
            end
        end
    end
    if #fluidTargets > 0 and spec.kind ~= "item" then
        for _, tank in ipairs(tanks) do
            if moved >= amount then
                break
            end
            -- 只有“目标就是同一个容器定义”才算资源已在目标里（同上）
            local alreadyThere = false
            for _, target in ipairs(fluidTargets) do
                if target == tank.container then
                    alreadyThere = true
                    break
                end
            end
            if alreadyThere then
                moved = math.min(amount, moved + tank.amount)
            else
                for _, target in ipairs(fluidTargets) do
                    if moved >= amount then
                        break
                    end
                    local got, err = self.Containers:pushFluid(tank.container, amount - moved, tank.name, target)
                    if err == "pending" then
                        self:rememberPendingMove(token, {
                            kind = "fluid",
                            container = tank.container,
                            want = amount - moved,
                            fluid = tank.name,
                            target = target,
                        })
                        return moved, "pending"
                    end
                    got = tonumber(got) or 0
                    if got > 0 then
                        moved = moved + got
                        self.Containers:invalidate()
                    elseif err then
                        reason = reason or err
                    end
                end
            end
        end
    end
    return moved, reason
end

--- 机器输入容器里已经有的材料数量：
--- 这些材料本来就在机器里（例如容器同时是存储容器，或材料是手动放进输入容器的），
--- 直接算作“已输入”，不需要再搬（自己搬给自己不会真的移动，还会让输入阶段一直卡在 0/N）。
function Recipe:alreadyInTargets(spec, itemTargets, fluidTargets)
    local total = 0
    local seen = {}
    local function collect(name)
        if not name or seen[name] then
            return
        end
        seen[name] = true
        --- 用户规则：interaction / output 容器**不可读**（读它们会直接报错）——
        --- 于是"机器里已经有这些材料"这件事无从得知，这里一律记 0：
        --- 引擎只按成功推送量记账（与海龟盲容器同一语义）。
        if not self.Containers:isReadableContainer(name) then
            return
        end
        total = total + self.Containers:countIn(name, spec)
    end
    for _, target in ipairs(itemTargets or {}) do
        collect(target)
    end
    for _, target in ipairs(fluidTargets or {}) do
        collect(target)
    end
    return total
end

--- 当前元素还缺的材料是否已经全在机器输入容器里（是的话就不必等待上游，也不必搬运）
function Recipe:machineHasPending(process, record)
    local machine = record.machine and self.Store:get("machines", record.machine) or nil
    if not machine or (record.phase or "input") ~= "input" then
        return false
    end
    local index = tonumber(record.index) or 1
    local element = (process.inputs or {})[index]
    if type(element) ~= "table" then
        return false
    end
    if element.kind ~= "item" and element.kind ~= "fluid" and element.kind ~= "filter" then
        return false
    end
    local required = elementDemand(element, record.batch or 1)
    local transferred = (record.progress or {})[tostring(index)] or 0
    local short = required - transferred
    if short <= 0 then
        return true
    end
    local itemTargets = self:inputContainers(machine, "item", element.containerIndex)
    local fluidTargets = self:inputContainers(machine, "fluid", element.containerIndex)
    return self:alreadyInTargets(elementSpec(element), itemTargets, fluidTargets) >= short
end

--- 输入搬运卡住时给出可读原因（显示在网页“进行中的流程”里，同时写入会话日志）
function Recipe:transferFailureReason(machine, element, itemTargets, fluidTargets, reason)
    if not machine then
        return reason or "\\u673A\\u5668\\u4E0D\\u53EF\\u7528"
    end
    local kind = (element.kind == "fluid") and "fluid" or "item"
    local targets = (kind == "fluid") and fluidTargets or itemTargets
    local all = (kind == "fluid") and (machine.fluidInputs or {}) or (machine.itemInputs or {})
    local label = (kind == "fluid") and "\\u6D41\\u4F53\\u8F93\\u5165\\u5BB9\\u5668\\uFF08fluidInputs\\uFF09" or "\\u7269\\u54C1\\u8F93\\u5165\\u5BB9\\u5668\\uFF08itemInputs\\uFF09"
    if #targets == 0 then
        return "\\u673A\\u5668 " .. machine.name .. " \\u6CA1\\u6709\\u53EF\\u7528\\u7684" .. label
    end
    local index = tonumber(element.containerIndex) or -1
    if index >= 1 and not all[index] then
        return "\\u673A\\u5668 " .. machine.name .. " \\u6CA1\\u6709\\u7B2C " .. index .. " \\u4E2A" .. label
    end
    return reason or ("\\u65E0\\u6CD5\\u628A " .. tostring(element.id) .. " \\u9001\\u5165\\u673A\\u5668 " .. machine.name
        .. "\\uFF08\\u5BB9\\u5668\\u5DF2\\u6EE1\\u3001\\u69FD\\u4F4D\\u4E0D\\u5339\\u914D\\u6216\\u8BE5\\u7269\\u54C1\\u4E0D\\u652F\\u6301\\u81EA\\u52A8\\u63D2\\u5165\\uFF09")
end

--- 输出：从机器输出容器抽取产物到存储容器。
--- token：同 transferIn（同一逻辑抽取每次传同一个值，见在飞搬运的记忆）。
--- opts.fromSlot：流程"输出产物"元素里填的槽位序号（盲抽用；nil = 交给外设自己找第一个非空槽）。
---
--- 用户规则（见 modules/containers.lua 顶部"读取规则"）：**interaction / output 角色的容器绝不可读**
---（读一次要在搬运前多等 1 个游戏刻，输入/输出速度直接减半）。所以对这类容器改成**盲抽**：
---不读内容、不按种类筛选，直接把指定槽位（或外设自己找的槽位）里的东西推到存储容器，
---完成判定只按成功搬运量记账（record.outProgress）与"机器自己推进存储的增量"（storageGain）。
---只有可读的机器输出容器（storage/input 角色）才保持旧的精确抽取（先读、按种类筛）。
function Recipe:transferOut(spec, machine, amount, token, opts)
    if amount <= 0 then
        return 0, nil
    end
    -- 物品只送物品存储容器、流体只送流体存储容器（同名物品/流体定义也能正确区分）；
    -- 顺序按存储优先级从大到小：高优先级容器优先存入（同优先级按定义名排序，见 Containers:byRole）
    local itemTargets = self.Containers:byRole("storage", "item", "out")
    local fluidTargets = self.Containers:byRole("storage", "fluid", "out")
    if #itemTargets == 0 and #fluidTargets == 0 then
        return 0, "\\u6CA1\\u6709 storage \\u89D2\\u8272\\u7684\\u7269\\u54C1/\\u6D41\\u4F53\\u5BB9\\u5668\\uFF08\\u4EA7\\u7269\\u6CA1\\u6709\\u5730\\u65B9\\u53EF\\u653E\\uFF09"
    end
    local moved = 0
    local reason
    --- 盲抽的源槽位：流程"输出产物"里填的槽位序号（nil = 让外设自己找第一个非空槽）
    --- 用户第 2 项：抽取按**内容快照**决策；只有"物品类"产物才用"槽位序号"作为限定
    --- （流体从不指定槽位 —— 流程编辑器里流体元素已不再提供该输入框）。
    local fromSlot = (spec.kind ~= "fluid" and type(opts) == "table") and tonumber(opts.fromSlot) or nil
    if fromSlot ~= nil and fromSlot < 1 then
        fromSlot = nil
    end
    --- 单次推送 + 记账。返回 got（0/n）；返回 nil,"pending" = 已交给 worker，调用方要立刻 return moved,"pending"
    local function pushOne(source, target, slot, want)
        local got, err = self.Containers:pushItem(source, slot, want, target, nil,
            --- 机器产物进存储容器要快：优先放进能一次放下、余量最小的槽位（1.6.11）
            self.Containers.INSERT_SPEED, "inventoryOut",
            --- 用户第 2 项：把"想抽的物品"一起交给 Containers —— 盲源（海龟）要靠它去查源槽位
            { name = spec.id, nbt = spec.nbt })
        if err == "pending" then
            self:rememberPendingMove(token, {
                kind = "item", container = source, slot = slot,
                want = want, target = target, toSlot = nil,
                mode = self.Containers.INSERT_SPEED,
                --- 续传时同样要带上它：不然盲源又拿不到槽位（见 resumePendingMove）
                item = { name = spec.id, nbt = spec.nbt },
            })
            return nil, "pending"
        end
        got = tonumber(got) or 0
        if got > 0 then
            self.Containers:invalidate()
        elseif err then
            reason = reason or err
        end
        return got, nil
    end
    if token then
        --- 上一次这条抽取交给了 worker、还没回报：先取它的结果（绝不再扫输出容器重发）
        local got, pendingReason = self:resumePendingMove(token)
        if pendingReason == "pending" then
            return moved, "pending"
        end
        if got then
            moved = got
        end
        if moved >= amount then
            return moved, nil
        end
    end
    if spec.kind ~= "fluid" then
        for _, source in ipairs(self:outputContainers(machine, "item")) do
            if moved >= amount then
                break
            end
            local peripheralName = self.Containers:peripheralOf(source, "item")
            if peripheralName then
                --- 用户第 2/3 项（1.9.0）：输出容器**一律按快照抽取** —— 交互容器现在也会被扫描
                --- （海龟由它自己上报物品栏，见 Containers:applyScan + Transfer.onCrafterInventory）：
                ---   * 只抽快照里与产物匹配的槽位（同名 + 同 NBT，由 Filter:specMatches 判）；
                ---   * 跳过已被其它任务认领的脏槽位（用户第 3 项）；
                ---   * opts.fromSlot（流程"输出产物"里填的槽位序号）现在只是**限定**：填了它就只抽那一个槽位；
                ---   * 旧的"按固定槽位盲抽"分支已删除：拿不到快照 = 这一轮什么都不做（pushItem 会给出原因）。
                for _, stack in ipairs(self.Containers:stacksPeripheral(peripheralName)) do
                    if moved >= amount then
                        break
                    end
                    local resource = { kind = "item", name = stack.name, nbt = stack.nbt }
                    local slotAllowed = (fromSlot == nil) or (tonumber(stack.slot) == fromSlot)
                    if slotAllowed and self.Filter:specMatches(spec, resource)
                        and not self.Containers:isDirtySlot(peripheralName, stack.slot, false) then
                        for _, target in ipairs(itemTargets) do
                            if moved >= amount then
                                break
                            end
                            local want = math.min(amount - moved, stack.count)
                            if want > 0 then
                                local got, pending = pushOne(source, target, stack.slot, want)
                                if pending then
                                    return moved, "pending"
                                end
                                moved = moved + got
                            end
                        end
                    end
                end
            end
        end
    end
    if spec.kind ~= "item" then
        for _, source in ipairs(self:outputContainers(machine, "fluid")) do
            if moved >= amount then
                break
            end
            local peripheralName = self.Containers:peripheralOf(source, "fluid")
            if peripheralName then
                --- 用户第 2/3 项：输出容器的储罐也按快照抽取（跳过已被认领的脏储罐）；
                --- "盲抽流体"分支已随盲路径一起删除。
                for _, tank in ipairs(self.Containers:tanksPeripheral(peripheralName)) do
                    if moved >= amount then
                        break
                    end
                    local resource = { kind = "fluid", name = tank.name }
                    if self.Filter:specMatches(spec, resource)
                        and not self.Containers:isDirtySlot(peripheralName, tank.tank, true) then
                        for _, target in ipairs(fluidTargets) do
                            if moved >= amount then
                                break
                            end
                            local got, err = self.Containers:pushFluid(source, amount - moved, tank.name, target, "inventoryOut")
                            if err == "pending" then
                                self:rememberPendingMove(token, {
                                    kind = "fluid",
                                    container = source,
                                    want = amount - moved,
                                    fluid = tank.name,
                                    target = target,
                                })
                                return moved, "pending"
                            end
                            got = tonumber(got) or 0
                            if got > 0 then
                                moved = moved + got
                                self.Containers:invalidate()
                            elseif err then
                                reason = reason or err
                            end
                        end
                    end
                end
            end
        end
    end
    return moved, reason
end

--- 用户第 2 项（1.9.0）：所有角色的容器都会被扫描（interaction / output 也一样，海龟由它自己上报），
--- 所以**不存在"按设计不可读"的机器输出容器**了 —— 这里恒为 false。
--- 保留函数是为了调用点（"等机器产出"的文案判断）不必改动。
function Recipe:machineOutputsBlind(spec, machine)
    return false
end

--- 机器输出容器中剩余的可抽取数量（用户第 2/3 项：所有角色的容器都有内容快照，
--- 所以一律按快照算）。抽取完成判定仍然以记账为主：record.outProgress 与 storageGain。
function Recipe:machineRemaining(spec, machine)
    local total = 0
    if spec.kind ~= "fluid" then
        for _, source in ipairs(self:outputContainers(machine, "item")) do
            if self.Containers:isReadableContainer(source, "item") then
                local peripheralName = self.Containers:peripheralOf(source, "item")
                if peripheralName then
                    for _, stack in ipairs(self.Containers:stacksPeripheral(peripheralName)) do
                        if self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
                            total = total + stack.count
                        end
                    end
                end
            end
        end
    end
    if spec.kind ~= "item" then
        for _, source in ipairs(self:outputContainers(machine, "fluid")) do
            if self.Containers:isReadableContainer(source, "fluid") then
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
    end
    return total
end

-- 说明：elementDemand / elementSpec 的定义已上移到文件开头（前面的 machineHasPending 等要用到）

--- 存储容器中可用于该输入元素的数量
--- 判定必须与 transferIn 完全一致（含 NBT 语义），否则会出现“材料检查通过、搬运时却匹配不到”，
--- 输入阶段就会永远停在 “正在发送 xxx 0/N”。
function Recipe:availableFor(element)
    local total = self.Containers:countOf(elementSpec(element), "storage")
    return total
end

--- 当前批次剩余待输入材料是否齐备
function Recipe:batchMaterialsReady(process, record)
    local batch = record.batch or 1
    local progress = record.progress or {}
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
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
    return true
end

--- 上游产物是否满足下游输入元素
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
        return false
    end
    return false
end

--- 查找可以产出该输入元素的上游流程（按输出优先级从高到低）
--- 抽象流程（含 abstract 操作）永远不能当上游：它只是"流程设置复制"的来源，不能真的生产东西。
function Recipe:upstreamCandidates(processName, element)
    local result = {}
    local index = {}
    for _, other in ipairs(self.Store:list("processes")) do
        if other.name ~= processName and not self:isAbstract(other) then
            for _, output in ipairs(other.outputs or {}) do
                local yieldPerBatch = 0
                if output.kind == "item" or output.kind == "fluid" or output.kind == "filter" then
                    if self:outputMatchesInput(output, element) then
                        yieldPerBatch = math.max(1, tonumber(output.max) or 1)
                    end
                elseif output.kind == "placeholder" then
                    if element.kind == "item" and output.item == element.id then
                        yieldPerBatch = 1
                    elseif element.kind == "filter" and output.item and self.Filter:matches(element.id, { kind = "item", name = output.item }) then
                        yieldPerBatch = 1
                    end
                end
                if yieldPerBatch > 0 then
                    local entry = index[other.name]
                    local priority = tonumber(output.priority) or 0
                    if not entry then
                        entry = {
                            name = other.name,
                            yield = yieldPerBatch,
                            priority = priority,
                        }
                        index[other.name] = entry
                        result[#result + 1] = entry
                    else
                        entry.priority = math.max(entry.priority, priority)
                        entry.yield = math.max(entry.yield, yieldPerBatch)
                    end
                end
            end
        end
    end
    table.sort(result, function(a, b)
        if a.priority ~= b.priority then
            return a.priority > b.priority
        end
        return a.name < b.name
    end)
    return result
end

--- 清空某输入元素的上游请求（下游不再缺料 / 下游被取消时撤销请求）
--- 撤销时会把当时加到上游的“下游单位数”减回去，否则上游会继续为已取消的下游生产。
function Recipe:clearRequest(record, key)
    local ledger = record.requests and record.requests[key]
    if not ledger then
        return
    end
    record.requests[key] = nil
    if ledger.upstream and (ledger.added or 0) > 0 then
        local upstreamRecord = self:record(ledger.upstream)
        upstreamRecord.downstreamCount = math.max(0, (upstreamRecord.downstreamCount or 0) - ledger.added)
    end
    self.Cache:markDirty()
end

--- 选择要请求的上游流程：按输出产物优先级从高到低，只在高优先级上游“缺失”时才顺延到下一个
function Recipe:chooseUpstream(processName, element)
    for _, candidate in ipairs(self:upstreamCandidates(processName, element)) do
        if self:record(candidate.name).state ~= "missing" then
            return candidate
        end
    end
    return nil
end

--- 请求上游产出：
---   * 每个输入元素同一时间只向一个上游请求（台账记录已请求数量，避免重复累加）；
---   * 处于缺失状态的上游不会被取消既有请求，只是不再新增；
---   * 下游不再缺料时由 clearRequest 撤销请求记录。
-- 返回值：是否已建立/已存在请求, 是否存在候选上游
function Recipe:requestUpstream(processName, record, index, element, need, chain, depth)
    chain = chain or {}
    depth = depth or 0
    if depth > MAX_CHAIN_DEPTH or chain[processName] then
        return false, false
    end
    chain[processName] = true
    local candidates = self:upstreamCandidates(processName, element)
    if #candidates == 0 then
        return false, false
    end
    record.requests = record.requests or {}
    local key = tostring(index)
    local ledger = record.requests[key]
    if ledger and (ledger.items or 0) >= need then
        return true, true
    end
    local candidate = self:chooseUpstream(processName, element)
    if not candidate then
        return false, true
    end
    local yieldPerBatch = math.max(1, candidate.yield)
    local units = math.max(1, math.ceil(need / yieldPerBatch))
    local previous = 0
    if ledger and ledger.upstream == candidate.name then
        previous = ledger.units or 0
    elseif ledger and ledger.upstream then
        -- 换上游：先把旧上游的下游单位数减回去
        local oldRecord = self:record(ledger.upstream)
        oldRecord.downstreamCount = math.max(0, (oldRecord.downstreamCount or 0) - (ledger.added or 0))
        self.Cache:markDirty()
    end
    local added = math.max(0, units - previous)
    if added > 0 then
        local upstreamRecord = self:record(candidate.name)
        upstreamRecord.downstreamCount = (upstreamRecord.downstreamCount or 0) + added
        if upstreamRecord.state == "idle" or upstreamRecord.state == "done" then
            upstreamRecord.state = "idle"
            local upstreamProcess = self.Store:get("processes", candidate.name)
            if upstreamProcess then
                self:ensureMaterials(candidate.name, upstreamProcess, upstreamRecord, chain, depth + 1)
            end
        end
    end
    local total = math.max(units, previous)
    record.requests[key] = {
        upstream = candidate.name,
        units = total,
        added = added,
        items = total * yieldPerBatch,
        yield = yieldPerBatch,
    }
    self.Cache:markDirty()
    return true, true
end

--- 判断流程材料是否齐备；不足则按优先级请求上游，无法请求则标记缺失
function Recipe:ensureMaterials(processName, process, record, chain, depth)
    chain = chain or {}
    depth = depth or 0
    local remaining = (record.userCount or 0) + (record.downstreamCount or 0)
    if remaining <= 0 then
        return true
    end
    local maxMultiplier = math.max(1, tonumber(process.maxMultiplier) or 1)
    local batch = math.min(maxMultiplier, remaining)
    local missing = {}
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            local need = elementDemand(element, batch)
            local available = self:availableFor(element)
            if available < need then
                missing[#missing + 1] = {
                    index = index,
                    element = element,
                    need = need - available,
                }
            end
        end
    end
    if #missing == 0 then
        if record.state == "missing" then
            -- 批次进行中（batch > 0）时只把“缺失”恢复成“进行中”，不要回到 idle：
            -- 否则下一 tick 会把正在进行的批次当成新批次，已经输入的材料进度会被清空。
            record.state = (record.batch or 0) > 0 and "running" or "idle"
            record.lastError = nil
        end
        return true
    end
    local requested = false
    local hasUpstream = true
    for _, item in ipairs(missing) do
        local ok, exists = self:requestUpstream(processName, record, item.index, item.element, item.need, chain, depth)
        if ok then
            requested = true
        end
        if not exists then
            hasUpstream = false
        end
    end
    record.wait = { kind = "materials" }
    if not hasUpstream then
        record.state = "missing"
        record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\u4E14\\u6CA1\\u6709\\u53EF\\u7528\\u7684\\u4E0A\\u6E38\\u6D41\\u7A0B"
    elseif requested then
        record.state = "waiting"
        record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\uFF0C\\u5DF2\\u6309\\u4F18\\u5148\\u7EA7\\u8BF7\\u6C42\\u4E0A\\u6E38\\u6D41\\u7A0B"
    else
        record.state = "waiting"
        record.lastError = "\\u4E0A\\u6E38\\u6D41\\u7A0B\\u5747\\u5904\\u4E8E\\u7F3A\\u5931\\u72B6\\u6001\\uFF0C\\u4FDD\\u7559\\u8BF7\\u6C42\\u5E76\\u7EE7\\u7EED\\u7B49\\u5F85"
    end
    self.Cache:markDirty()
    return false
end

--- 批次执行过程中发现材料不足（按优先级请求上游，或标记缺失）
--- 1.7.0：去掉了"每秒才检查一次"的硬间隔 —— 流程队列每轮都会把进程放回队尾，
--- 轮转本身就是节流；上游请求是幂等的（requestUpstream 只加增量）。
function Recipe:handleShortage(process, record, now)
    record.checkedAt = now
    local ready, element, shortBy, index = self:batchMaterialsReady(process, record)
    if ready then
        record.requests = {}
        return true
    end
    local requested = false
    local hasUpstream = true
    if element and shortBy and index then
        local ok, exists = self:requestUpstream(process.name, record, index, element, shortBy, {}, 0)
        requested = ok
        hasUpstream = exists
    end
    record.wait = { kind = "materials" }
    if not hasUpstream then
        record.state = "missing"
        record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\u4E14\\u6CA1\\u6709\\u53EF\\u7528\\u7684\\u4E0A\\u6E38\\u6D41\\u7A0B"
    elseif requested then
        record.state = "waiting"
        record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\uFF0C\\u7B49\\u5F85\\u4E0A\\u6E38\\u6D41\\u7A0B\\u4EA7\\u51FA"
    else
        record.state = "waiting"
        record.lastError = "\\u4E0A\\u6E38\\u6D41\\u7A0B\\u5747\\u5904\\u4E8E\\u7F3A\\u5931\\u72B6\\u6001\\uFF0C\\u4FDD\\u7559\\u8BF7\\u6C42\\u5E76\\u7EE7\\u7EED\\u7B49\\u5F85"
    end
    self.Cache:markDirty()
    return false
end

--- 存储容器资源快照（用于输出进度估算）
function Recipe:storageBaseline()
    local baseline = {}
    for _, entry in ipairs(self.Containers:resources()) do
        baseline[entry.kind .. ":" .. entry.name] = entry.count
    end
    return baseline
end

--- 输入阶段：按输入列表顺序依次输入，每个元素必须完全输入后才进入下一个
function Recipe:stepInput(process, record, machine, now)
    local inputs = process.inputs or {}
    -- 一步 = 至多一次搬运调用（见 Recipe.new 的 stepBudget）
    local budget = self.stepBudget or 1
    record.progress = record.progress or {}
    -- 红石脉冲是跨 tick 的多步动作：先把它推进完，再继续后面的元素
    if record.pulse and not self:advancePulse(record, now) then
        return
    end
    local index = record.index or 1
    while index <= #inputs and budget > 0 do
        local element = inputs[index]
        local key = tostring(index)
        if element.kind == "waitTime" then
            -- 输入阶段的等待时间随翻倍一起翻倍（产物阶段的等待时间不翻倍）
            local batch = math.max(1, record.batch or 1)
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
            -- 设置红石信号：写入强度并保持
            self:emitSignals(machine, element)
            index = index + 1
            budget = budget - 1
        elseif element.kind == "emitPulse" then
            -- 发出红石脉冲：置位 -> 等 0.05s -> 复位 -> 等 0.05s（后续由 advancePulse 跨 tick 推进）
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
            local required = elementDemand(element, record.batch or 1)
            local transferred = record.progress[key] or 0
            if transferred >= required then
                self:clearRequest(record, key)
                index = index + 1
            else
                local spec = elementSpec(element)
                local itemTargets = self:inputContainers(machine, "item", element.containerIndex)
                local fluidTargets = self:inputContainers(machine, "fluid", element.containerIndex)
                local short = required - transferred
                -- 机器输入容器里已有的材料直接算作已输入（材料本来就在机器里时不再搬运）
                local already = self:alreadyInTargets(spec, itemTargets, fluidTargets)
                -- 材料齐备检查会读一遍存储容器：1.5.2 起该读取走 Containers 快照的按名合计表（O(1)，
                -- 每 600ms 才真正重算一次），所以这里可以像以前一样每个 tick 都问，不必额外节流。
                local ready = already >= short or self:batchMaterialsReady(process, record)
                if not ready then
                    if not self:handleShortage(process, record, now) then
                        record.index = index
                        return
                    end
                end
                local moved, reason = 0, nil
                if already > 0 then
                    moved = math.min(short, already)
                else
                    moved, reason = self:transferIn(
                        spec,
                        itemTargets,
                        fluidTargets,
                        --- 用户第 2 项：只有**物品**元素才用"槽位序号"；流体元素从不指定槽位
                        --- （流程编辑器里流体元素已经不再提供该输入框）。
                        (element.kind == "item") and element.slot or nil,
                        short,
                        "in:" .. tostring(process.name) .. "\1" .. tostring(key),
                        --- 给机器送料要快：从存储容器优先抽数量最多的那几堆（1.6.11）
                        { storageOrder = self.Containers.ORDER_SPEED }
                    )
                end
                if reason == "pending" then
                    -- 材料搬运已交给 IFMWorker：本 tick 不推进（下个 tick 用同一个任务继续等）。
                    -- 但已经回报的那部分要立刻记账 —— 否则下个 tick 会按“还没搬过”重新要一遍，
                    -- 把同一批材料送两遍（用户实测：要 64 个结果搬了 127 个）。
                    moved = tonumber(moved) or 0
                    if moved > 0 then
                        record.progress[key] = (record.progress[key] or 0) + moved
                        self.Cache:markDirty()
                    end
                    record.index = index
                    return
                end
                moved = tonumber(moved) or 0
                budget = budget - 1
                transferred = transferred + moved
                record.progress[key] = transferred
                if moved > 0 and record.lastError ~= nil and transferred >= required then
                    record.lastError = nil
                end
                self.Cache:markDirty()
                if transferred < required then
                    -- 未完全输入：下个 tick 继续重试同一元素
                    record.index = index
                    if moved <= 0 then
                        -- 卡片上立刻显示原因；日志每 5 秒最多推一次（避免刷屏）
                        local stallText = self:transferFailureReason(machine, element, itemTargets, fluidTargets, reason)
                        if record.lastError ~= stallText then
                            record.lastError = stallText
                            self.Cache:markDirty()
                        end
                        if now - (record.lastStallAt or 0) >= 5000 then
                            record.lastStallAt = now
                            self.log("Process %s stalled at input %s: %s", process.name, tostring(element.id), stallText)
                        end
                        return
                    end
                else
                    self:clearRequest(record, key)
                    index = index + 1
                end
            end
        end
    end
    if index > #inputs then
        --- turtle_crafter（用户第 3 项）：材料全部到位后先让海龟合成一次，再进入抽产物阶段。
        --- craft 指令是"发出去就不管"的（合成器不回报状态），所以这里只看"有没有空闲合成器"：
        --- 没有就停在本相位、下个 tick 再试 —— 免得流程以为已经合成过而直接去抽空气。
        if self.Store.isTurtleCrafter(machine) then
            --- 用户第 6 项：材料"记账上到位" ≠ 真的进了海龟物品栏（搬运是异步的）。
            --- 以前这里立刻发 craft ⇒ 海龟只拿到一两个铁粒就开始合成，必然失败。
            --- 现在先看海龟自己上报的物品栏快照；没到位就停在本相位，下个 tick 再看。
            --- 兜底：等太久（快照一直不更新 / 合成器不上报）时照样放行，免得流程永久卡住。
            local ready, missingText = self:crafterMaterialsReady(process, record, machine)
            if not ready then
                record.craftWaitSince = record.craftWaitSince or now
                local waited = now - record.craftWaitSince
                if waited < CRAFT_READY_TIMEOUT_MS then
                    record.wait = { kind = "craft", machine = machine.name }
                    record.lastError = "\\u7B49\\u5F85\\u6750\\u6599\\u771F\\u6B63\\u8FDB\\u5165\\u6D77\\u9F9F" ..
                        (missingText and ("\\uFF08\\u8FD8\\u5DEE " .. missingText .. "\\uFF09") or "")
                    if now - (record.lastCraftWaitLogAt or 0) >= 10000 then
                        record.lastCraftWaitLogAt = now
                        self.log("Process %s: waiting for the turtle to really hold %s before crafting",
                            tostring(process.name), tostring(missingText or "the materials"))
                    end
                    self.Cache:markDirty()
                    return
                end
                if not record.craftReadyTimedOut then
                    record.craftReadyTimedOut = true
                    self.log("Process %s: the turtle never reported %s - crafting anyway (check that " ..
                        "IFMCrafter.lua is still running and can reach the master)",
                        tostring(process.name), tostring(missingText or "its materials"))
                end
            else
                record.craftWaitSince = nil
                record.craftReadyTimedOut = nil
            end
            local status = self:requestMachineCraft(process, record, machine)
            if status ~= "sent" then
                record.wait = { kind = "craft", machine = machine.name }
                record.lastError = "\\u7B49\\u5F85\\u6D77\\u9F9F\\u5408\\u6210\\u5668\\u7A7A\\u95F2"
                self.Cache:markDirty()
                return
            end
        end
        record.phase = "output"
        record.index = 1
        record.outProgress = {}
        self:prepareOutputs(process, record)
        self.Cache:markDirty()
    else
        record.index = index
        self.Cache:markDirty()
    end
end

--- 海龟合成前"等材料真的进物品栏"的最长时间（用户第 6 项）：超过就照样发 craft 指令，
--- 免得合成器不上报时流程永久卡在输入相位。
local CRAFT_READY_TIMEOUT_MS = 30000

--- 材料是否**真的**已经在海龟物品栏里（用户第 6 项）。
--- 现场：一次把 9 个铁粒送进海龟，海龟只收到 1 个就开始合成 → 合成必然失败。
--- 原因：材料搬运是异步的 —— Containers:pushItem 一提交就把数量记进 record.progress
--- （记账：为了避免下个 tick 重复要料），而 record.progress 满了就直接发了 craft 指令。
--- 海龟合成的 3×3 格子就是它自己的物品栏，格子没填满 craft 一定失败。
--- 所以这里改成读**海龟自己上报的内容快照**（IFMCrafter 的 op = "inventory"，主控每 2 秒催一次：
--- 见 IFMMaster 的 refreshCrafterReports）—— 材料真的在格子里才算就绪。
--- 返回：就绪=true / 就绪=false, "还差什么"的可读描述
function Recipe:crafterMaterialsReady(process, record, machine)
    local batch = record.batch or 1
    local missing = {}
    for _, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            local required = elementDemand(element, batch)
            if required > 0 then
                local spec = elementSpec(element)
                local itemTargets = self:inputContainers(machine, "item", element.containerIndex)
                local fluidTargets = self:inputContainers(machine, "fluid", element.containerIndex)
                local have = self:alreadyInTargets(spec, itemTargets, fluidTargets)
                if have < required then
                    missing[#missing + 1] = tostring(spec.name or element.id or "?") .. " x" ..
                        tostring(required - have)
                end
            end
        end
    end
    if #missing == 0 then
        return true, nil
    end
    return false, table.concat(missing, ", ")
end

--- 请这台机器的海龟合成（turtle_crafter）：返回 "sent" = 指令已发出 / "idle" = 没有空闲合成器。
--- 合成链路由 IFMMaster 挂上（setCraftProvider）；没挂时（纯引擎测试）直接放行，不阻塞流程。
function Recipe:requestMachineCraft(process, record, machine)
    if type(self.craftProvider) ~= "function" then
        return "sent"
    end
    local ok, status = pcall(self.craftProvider, {
        machine = machine.name,
        crafter = machine.name,                 -- 虚拟机器的名字就是海龟的网络外设名
        process = process.name,
        batch = record.batch,
        key = table.concat({ tostring(process.name), tostring(record.batch or 0),
            tostring(record.startedAt or 0), tostring(machine.name) }, "|"),
    })
    if not ok then
        self.log("Process %s: craft request failed: %s", tostring(process.name), tostring(status))
        return "idle"
    end
    return status
end

--- 合成链路（IFMMaster 挂 `Transfer:requestCraft`）：function(spec) -> "sent" / "idle"
function Recipe:setCraftProvider(provider)
    self.craftProvider = provider
end

--- 进入输出阶段前记录目标产量与基线
function Recipe:prepareOutputs(process, record)
    local batch = record.batch or 1
    local targets = {}
    for _, element in ipairs(process.outputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            targets[#targets + 1] = {
                kind = element.kind,
                id = element.id,
                target = (tonumber(element.max) or 0) * batch,
            }
        end
    end
    record.target = targets
    record.baseline = self:storageBaseline()
end

--- 输出阶段：按输出列表顺序依次抽取，抽到“最多数目”或满足“最少数目”即进入下一个
function Recipe:stepOutput(process, record, machine, now)
    local outputs = process.outputs or {}
    -- 一步 = 至多一次搬运调用（见 Recipe.new 的 stepBudget）
    local budget = self.stepBudget or 1
    record.outProgress = record.outProgress or {}
    -- 红石脉冲是跨 tick 的多步动作：先把它推进完，再继续后面的元素
    if record.pulse and not self:advancePulse(record, now) then
        return
    end
    local index = record.index or 1
    while index <= #outputs and budget > 0 do
        local element = outputs[index]
        local key = tostring(index)
        if element.kind == "waitTime" then
            -- 产物阶段的等待时间不随翻倍变化（与输入阶段相反）
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
            -- 设置红石信号：写入强度并保持
            self:emitSignals(machine, element)
            index = index + 1
            budget = budget - 1
        elseif element.kind == "emitPulse" then
            -- 发出红石脉冲：置位 -> 等 0.05s -> 复位 -> 等 0.05s（后续由 advancePulse 跨 tick 推进）
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
            local batch = record.batch or 1
            local maxAmount = (tonumber(element.max) or 0) * batch
            local minAmount = (tonumber(element.min) or 0) * batch
            local collected = record.outProgress[key] or 0
            local spec = elementSpec(element)
            -- 产物可能被机器自己直接吐进存储容器（Create 搅拌盆 + 漏斗等）：存储增量也算“已到手”
            local gained = self:storageGain(spec, record)
            if collected >= maxAmount or gained >= maxAmount then
                index = index + 1
            else
                local moved, reason = self:transferOut(spec, machine, maxAmount - collected,
                    "out:" .. tostring(process.name) .. "\1" .. tostring(key),
                    --- 用户第 2/3 项：抽取按**内容快照**决策；只有物品元素才用"槽位序号"（限定），
                    --- 流体从不指定槽位（流程编辑器里流体元素不再提供该输入框）。
                    { fromSlot = (element.kind == "item") and element.slot or nil })
                if reason == "pending" then
                    -- 产物抽取已交给 IFMWorker：本 tick 不推进（下个 tick 继续等同一个任务）；
                    -- 已经回报的那部分照样记账（否则会重复抽取，见材料输入那一段的说明）。
                    local booked = tonumber(moved) or 0
                    if booked > 0 then
                        record.outProgress[key] = collected + booked
                        self.Cache:markDirty()
                    end
                    record.index = index
                    return
                end
                budget = budget - 1
                if moved > 0 then
                    record.outProgress[key] = collected + moved
                    record.lastError = nil
                    self.Cache:markDirty()
                else
                    local leftover = self:machineRemaining(spec, machine)
                    if leftover <= 0 and (collected >= minAmount or gained >= minAmount) then
                        index = index + 1
                    elseif leftover > 0 then
                        -- 产物确实在机器输出容器里（这一支必然读过它），但搬不到存储容器：
                        -- 原因只打印真实返回值，不列举"槽位不符"这类读才能知道的猜测
                        record.index = index
                        local outText = "\\u673A\\u5668 " .. tostring(machine.name) .. " \\u7684\\u8F93\\u51FA\\u5BB9\\u5668\\u91CC\\u8FD8\\u6709 "
                            .. tostring(element.id) .. "\\uFF0C\\u4F46\\u642C\\u4E0D\\u5230\\u5B58\\u50A8\\u5BB9\\u5668\\uFF1A" .. tostring(reason or "\\u672A\\u80FD\\u642C\\u8FD0\\u4EFB\\u4F55\\u7269\\u54C1")
                        if record.lastError ~= outText then
                            record.lastError = outText
                            self.Cache:markDirty()
                        end
                        if now - (record.lastStallAt or 0) >= 5000 then
                            record.lastStallAt = now
                            self.log("Process %s cannot move output %s out of machine %s: %s",
                                process.name, tostring(element.id), tostring(machine.name), tostring(reason or "-"))
                        end
                        return
                    else
                        -- 机器尚未产出足够产物：下个 tick 重试（顺便把"等机器产出"写进卡片，5 秒最多一次）。
                        -- 不可读的输出容器（interaction / output）我们**没看里面** —— 所以只说"等抽取量够了"，
                        -- 绝不写"输出容器里还没有该产物"（那是读一眼才知道的判断，写了就是撒谎）。
                        record.index = index
                        if leftover <= 0 and (record.lastError == nil or now - (record.lastStallAt or 0) >= 5000) then
                            record.lastStallAt = now
                            local prefix = "\\u7B49\\u5F85\\u673A\\u5668 " .. tostring(machine.name) .. " \\u4EA7\\u51FA "
                                .. tostring(element.id)
                            local note
                            if self:machineOutputsBlind(spec, machine) then
                                note = "\\uFF08\\u8F93\\u51FA\\u5BB9\\u5668\\u6309\\u8BBE\\u8BA1\\u4E0D\\u8BFB\\uFF0C\\u53EA\\u6309\\u62BD\\u53D6\\u91CF\\u5224\\u5B9A\\uFF09"
                            else
                                note = "\\uFF08\\u8F93\\u51FA\\u5BB9\\u5668\\u91CC\\u8FD8\\u6CA1\\u6709\\u8BE5\\u4EA7\\u7269\\uFF09"
                            end
                            record.lastError = prefix .. note
                            self.log("Process %s waiting for output %s from machine %s",
                                process.name, tostring(element.id), tostring(machine.name))
                        end
                        self.Cache:markDirty()
                        return
                    end
                end
            end
        end
    end
    if index > #outputs then
        self:finishBatch(process, record, now)
    else
        record.index = index
        self.Cache:markDirty()
    end
end

--- 一个批次完成：释放机器并行位，重置批次状态
function Recipe:finishBatch(process, record, now)
    if record.machine then
        self:occupyMachine(record.machine, -1)
    end
    record.machine = nil
    record.phase = "input"
    record.index = 1
    record.progress = {}
    record.outProgress = {}
    --- 这一批结束了：清掉它的在飞搬运记忆（token = "in:流程\1元素" / "out:流程\1元素"）
    self:forgetPendingMovesWithPrefix("in:" .. tostring(process.name) .. "\1")
    self:forgetPendingMovesWithPrefix("out:" .. tostring(process.name) .. "\1")
    for key in pairs(record.requests or {}) do
        self:clearRequest(record, key)
    end
    record.requests = {}
    record.target = {}
    record.batch = 0
    record.state = "idle"
    record.wait = nil
    record.checkedAt = now
    record.lastFinishedAt = now
    record.lastError = nil
    self.Cache:markDirty()
end

--- 重新为当前批次未完成的输入元素请求上游（返回：是否已请求, 是否存在候选上游）
function Recipe:retryUpstream(process, record)
    local requested = false
    local hasUpstream = true
    local progress = record.progress or {}
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            local required = elementDemand(element, record.batch or 1)
            local transferred = progress[tostring(index)] or 0
            if transferred < required then
                local available = self:availableFor(element)
                if available < (required - transferred) then
                    local shortBy = (required - transferred) - available
                    local ok, exists = self:requestUpstream(process.name, record, index, element, shortBy, {}, 0)
                    if ok then
                        requested = true
                    end
                    if not exists then
                        hasUpstream = false
                    end
                end
            end
        end
    end
    return requested, hasUpstream
end

--- 流程引用的容器 / 信号 / 机器类型是否齐全（不齐全时冻结流程，等外设回来自动恢复）
--- 定义被删掉、或方块（外设）不在，都会让 supports() 变假 —— 两种都算“引用缺失”。
--- 用途：换外设时可以直接删掉旧定义（网页上带 force），流程冻结而不是报错，重新建出同名定义就继续跑。
function Recipe:peripheralProblem(process, record)
    local typeName = process.machineType
    if typeName and typeName ~= "" then
        local machineType = self.Store:get("machineTypes", typeName)
        if not machineType then
            return "\\u673A\\u5668\\u7C7B\\u578B " .. tostring(typeName) .. " \\u5DF2\\u88AB\\u5220\\u9664"
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

--- 推进单个流程（每个 tick 调用一次，绝不阻塞）
function Recipe:stepProcess(process, now)
    local record = self:record(process.name)
    -- 抽象流程（含 abstract 操作）：永远不推进（也绝不允许被下单/当作上游）。
    -- 用户可能把一个正在跑的流程改成抽象流程：这里把它冻结，避免拿 abstract 当真实材料去搬运。
    if self:isAbstract(process) then
        if record.state ~= "missing" or record.lastError ~= ABSTRACT_FROZEN then
            record.state = "missing"
            record.wait = nil
            record.batch = 0
            record.lastError = ABSTRACT_FROZEN
            self.Cache:markDirty()
            self.log("Process %s is an abstract process (element id 'abstract'), not runnable", tostring(process.name))
        end
        return
    end
    if record.batch == nil then
        record.batch = 0
    end
    if record.index == nil then
        record.index = 1
    end
    if record.progress == nil then
        record.progress = {}
    end
    if record.outProgress == nil then
        record.outProgress = {}
    end

    --- 引用的外设 / 定义缺失（例如换外设时把旧定义删了）：冻结这个流程，等外设回来再继续。
    --- 冻结期间不动 batch / index / progress，所以外设一恢复就接着原来的进度跑。
    local freeze = self:peripheralProblem(process, record)
    if freeze then
        if record.state ~= "missing" or record.lastError ~= freeze then
            record.state = "missing"
            record.lastError = freeze
            record.wait = { kind = "peripheral" }
            self.Cache:markDirty()
            self.log("Process %s frozen: %s", tostring(process.name), tostring(freeze))
        end
        return
    end
    if record.wait and record.wait.kind == "peripheral" then
        -- 外设回来了：解冻（有批次在跑就继续 running，否则回到 idle 等下一次下单）
        record.wait = nil
        record.state = (record.batch or 0) > 0 and "running" or "idle"
        record.lastError = nil
        self.Cache:markDirty()
        self.log("Process %s resumed (peripherals are back)", tostring(process.name))
    end

    if record.state == "idle" or record.state == "done" then
        record.state = "idle"
        local remaining = (record.userCount or 0) + (record.downstreamCount or 0)
        if remaining <= 0 then
            record.batch = 0
            return
        end
        if not self:ensureMaterials(process.name, process, record, {}, 0) then
            return
        end
        remaining = (record.userCount or 0) + (record.downstreamCount or 0)
        if remaining <= 0 then
            return
        end
        local maxMultiplier = math.max(1, tonumber(process.maxMultiplier) or 1)
        local batch = math.min(maxMultiplier, remaining)
        local fromDownstream = math.min(record.downstreamCount or 0, batch)
        record.downstreamCount = (record.downstreamCount or 0) - fromDownstream
        record.userCount = math.max(0, (record.userCount or 0) - (batch - fromDownstream))
        record.batch = batch
        record.phase = "input"
        record.index = 1
        record.progress = {}
        record.outProgress = {}
        record.requests = {}
        record.startedAt = now
        record.wait = nil
        record.state = "running"
        record.lastError = nil
        record.baseline = self:storageBaseline()
        self.Cache:markDirty()
    end

    if (record.batch or 0) <= 0 then
        record.state = "idle"
        return
    end

    local wait = record.wait
    if wait then
        if wait.kind == "time" then
            if now < (wait.untilMs or 0) then
                return
            end
            record.wait = nil
        elseif wait.kind == "machine" then
            -- 1.7.0：去掉 500ms 硬间隔 —— 进程队列轮转本身就是节流
            record.checkedAt = now
            record.wait = nil
        elseif wait.kind == "signal" then
            local machine = record.machine and self.Store:get("machines", record.machine) or nil
            if not machine or not wait.element then
                record.wait = nil
            elseif not self:signalSatisfied(machine, wait.element) then
                return
            else
                record.wait = nil
            end
        else
            -- 1.7.0：去掉"每秒重试"的硬间隔（同一进程每轮调度都会被推进一步）
            record.checkedAt = now
            if self:batchMaterialsReady(process, record) or self:machineHasPending(process, record) then
                record.wait = nil
                record.state = "running"
                record.lastError = nil
                record.requests = {}
            else
                local requested, hasUpstream = self:retryUpstream(process, record)
                if not hasUpstream then
                    record.state = "missing"
                    record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\u4E14\\u6CA1\\u6709\\u53EF\\u7528\\u7684\\u4E0A\\u6E38\\u6D41\\u7A0B"
                elseif requested then
                    record.state = "waiting"
                    record.lastError = "\\u6750\\u6599\\u4E0D\\u8DB3\\uFF0C\\u7B49\\u5F85\\u4E0A\\u6E38\\u6D41\\u7A0B\\u4EA7\\u51FA"
                else
                    record.state = "waiting"
                    record.lastError = "\\u4E0A\\u6E38\\u6D41\\u7A0B\\u5747\\u5904\\u4E8E\\u7F3A\\u5931\\u72B6\\u6001\\uFF0C\\u4FDD\\u7559\\u8BF7\\u6C42\\u5E76\\u7EE7\\u7EED\\u7B49\\u5F85"
                end
                self.Cache:markDirty()
                return
            end
        end
    end

    local machine = record.machine and self.Store:get("machines", record.machine) or nil
    if record.machine and not machine then
        -- 机器定义被删除 / 改名：清掉记录并释放并行位，重新选机器
        self:occupyMachine(record.machine, -1)
        record.machine = nil
        self.Cache:markDirty()
    end
    if not machine or not self:machineUsable(machine) then
        if machine then
            -- 记下不可用的具体原因，方便在网页上定位（否则只能看到“等待机器”）
            local problem = self:machineProblem(machine)
            self:occupyMachine(machine.name, -1)
            record.machine = nil
            if problem then
                record.lastError = "\\u673A\\u5668 " .. machine.name .. " \\u4E0D\\u53EF\\u7528\\uFF1A" .. problem
                self.log("Process %s machine %s unusable: %s", process.name, machine.name, problem)
            end
        end
        local selected, err = self:chooseMachine(process.machineType)
        if not selected then
            record.state = "waiting"
            record.wait = { kind = "machine" }
            record.checkedAt = now
            record.lastError = err or "\\u6CA1\\u6709\\u53EF\\u7528\\u7684\\u673A\\u5668"
            self.Cache:markDirty()
            return
        end
        record.machine = selected.name
        self:occupyMachine(selected.name, 1)
        -- 关键：本地变量必须一起换成新选中的机器，否则下面 stepInput / stepOutput 拿到的还是 nil
        -- （旧版本的 bug：这里没同步，导致 “attempt to index local 'machine' (a nil value)” 崩溃）
        machine = selected
        self.Cache:markDirty()
    end

    if record.phase == "input" then
        self:stepInput(process, record, machine, now)
    else
        self:stepOutput(process, record, machine, now)
    end
end

--- 记录发送任务当前卡住的原因（网页上显示 + 推给网页控制台；原因没变就不重复写盘/刷日志）
function Recipe:markDeliveryError(delivery, text)
    if delivery.lastError == text then
        return
    end
    delivery.lastError = text
    self.Cache:markDirty()
    if text then
        self.log("Delivery %s (%s %s x%s -> %s): %s", tostring(delivery.id or 0), tostring(delivery.kind),
            tostring(delivery.name), tostring(delivery.remaining or 0), tostring(delivery.container), tostring(text))
    end
end

--- 追加发送任务：同一目标容器 + 同一资源的任务合并成一条，避免重复点“发送”时排队出多条
function Recipe:addDelivery(entry)
    for _, existing in ipairs(self.Cache:deliveries()) do
        if existing.container == entry.container and existing.kind == entry.kind and existing.name == entry.name then
            local extra = math.max(1, tonumber(entry.remaining) or 1)
            existing.remaining = (tonumber(existing.remaining) or 0) + extra
            existing.total = (tonumber(existing.total) or 0) + extra
            if entry.processName and not existing.processName then
                existing.processName = entry.processName
            end
            --- 用户第 5 项（"发送中的数量变成了两倍"）：合并本身是刻意的（同一目标容器 + 同一资源的
            --- 多次发送并成一条，避免点两次就排两条），但以前完全无声 —— 网页上只看到一条 762 的
            --- 记录，没人知道那是两次 381 并起来的。现在明确记一行（终端 + 网页控制台都能看到）。
            self.log("Delivery %s extended by %s: %s x%s -> %s (total %s)",
                tostring(existing.id or 0), tostring(extra), tostring(existing.name),
                tostring(existing.remaining), tostring(existing.container), tostring(existing.total))
            existing.lastError = nil
            self.Cache:markDirty()
            return existing
        end
    end
    return self.Cache:addDelivery(entry)
end

--- 发送中队列：每个 tick 都尝试把存储容器里的库存搬到目标 output 容器。
--- 这里不再等“流程完成一批”才搬运：只要存储里有货就先发（先发库存），
--- 不足的部分由流程继续产出，下一 tick 再搬，任务不会再永远停在“未发送”。
function Recipe:processDeliveries(now)
    local deliveries = self.Cache:deliveries()
    if #deliveries == 0 then
        return
    end
    local pending = {}
    for _, delivery in ipairs(deliveries) do
        local remaining = tonumber(delivery.remaining) or 0
        if remaining > 0 then
            local containerKind = delivery.containerKind
            if containerKind ~= "item" and containerKind ~= "fluid" then
                -- 旧任务（或 filter 资源）：按目标容器定义自己的种类判定
                containerKind = self.Util.kindOfDef(self.Store:findContainer(delivery.container, delivery.kind))
            end
            if not self.Containers:peripheralOf(delivery.container, containerKind) then
                self:markDeliveryError(delivery, self.Containers:unusableReason(delivery.container, containerKind)
                    or ("\\u76EE\\u6807\\u5BB9\\u5668 " .. tostring(delivery.container) .. " \\u5F53\\u524D\\u4E0D\\u53EF\\u7528"))
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
                local moved, reason = self:transferIn(
                    { kind = delivery.kind, id = delivery.name },
                    itemTargets,
                    fluidTargets,
                    -1,
                    remaining,
                    --- token 按发货任务 id：同一条发货在 worker 回报之前只会有一条在飞请求
                    --- （以前每次重扫源都会新发一条 → 64 个变成 63 + 64 = 127 个）
                    "delivery:" .. tostring(delivery.id or delivery.name),
                    --- 发货到输出容器要少碎片：从存储容器优先抽数量最少的那几堆（1.6.11）
                    --- 队列：发货是"库存输出"（1.7.0）
                    { storageOrder = self.Containers.ORDER_FRAGMENT, queue = "inventoryOut" }
                )
                if reason == "pending" then
                    -- 发送搬运已交给 IFMWorker：本 tick 不改状态（下个 tick 继续等同一个任务），
                    -- 也不写 lastError —— 这不是失败，只是“等 worker 干完”。delivery 会由下面的
                    -- “remaining > 0 就留在队列里”逻辑原样保留。
                    -- 但已经回报的那部分必须立刻扣减：否则下个 tick 会按原来的 remaining
                    -- 再发一遍（用户实测：要 64 个，结果搬了 63 + 64 = 127 个）。
                    local booked = tonumber(moved) or 0
                    if booked > 0 then
                        delivery.remaining = remaining - booked
                        delivery.lastError = nil
                        self.Cache:markDirty()
                    end
                else
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
                        --- 用户第 5 项（"发送中的数量是两倍、却永远发不完"）：存储里没货时要说清"还缺
                        --- 多少"；如果这个物品**根本没有流程能产出**（例如 Iron Nugget），更要明说
                        --- "不会自动到货，请补库存或删除此项" —— 以前的"等待库存/上游产出"会让人一直
                        --- 等一个永远不会发生的生产。这里只改这条发货记录的错误文案（reason 由
                        --- transferIn 给出，非 nil 时它更具体，仍然优先）。
                        if #self:producers(delivery.kind, delivery.name) == 0 then
                            reason = "\\u5B58\\u50A8\\u5BB9\\u5668\\u4E2D\\u6682\\u65F6\\u6CA1\\u6709 " ..
                                tostring(delivery.name) ..
                                "\\uFF08\\u8FD8\\u7F3A " .. tostring(remaining) ..
                                "\\uFF09\\uFF0C\\u4E14\\u6CA1\\u6709\\u6D41\\u7A0B\\u80FD\\u4EA7\\u51FA\\u5B83 \\u2192 " ..
                                "\\u4E0D\\u4F1A\\u81EA\\u52A8\\u5230\\u8D27\\uFF0C\\u8BF7\\u8865\\u5E93\\u5B58\\u6216\\u5220\\u9664\\u6B64\\u9879"
                        end
                        self:markDeliveryError(delivery, reason or ("\\u5B58\\u50A8\\u5BB9\\u5668\\u4E2D\\u6682\\u65F6\\u6CA1\\u6709 " .. tostring(delivery.name)
                            .. "\\uFF0C\\u7B49\\u5F85\\u5E93\\u5B58/\\u4E0A\\u6E38\\u4EA7\\u51FA"))
                    end
                end
            end
            if (tonumber(delivery.remaining) or 0) > 0 then
                pending[#pending + 1] = delivery
            else
                --- 这条发货做完了：清掉它的在飞搬运记忆（token 见上面的 transferIn 调用）
                self:forgetPendingMove("delivery:" .. tostring(delivery.id or delivery.name))
            end
        end
    end
    if #pending ~= #deliveries then
        self.Cache.data.deliveries = pending
        self.Cache:markDirty()
    end
end

--- ===== 存储整理（网页手动触发）=====
--- 目的：把同一种物品（同名 且 同 NBT，否则不可堆叠）散落在多个槽位、可以跨越多个容器上的堆，
--- 按「槽位内数量从小到大」的顺序合并到一起：数量最多的那堆当目标，最少的先往里装。
--- 计划是分批算的（每个 tick 最多问几次外设，见 Containers:compactPlanPass）：
--- 以前一口气算完会把主循环卡住十几秒 —— 期间引擎不推进、网页收不到推送，浏览器会
--- “15 秒没收到服务端数据”然后重连（点「整理」必然出现的那条消息就是这么来的）。
--- 现在 startCompact 立刻返回（state = "planning"），由 stepCompact 每 tick 推进一小步，
--- 算完再按 compactOpsPerTick 慢慢搬运 —— 全程不阻塞主循环。
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

--- 推进「整理计划」的计算：每次调用只跑一遍分批计算（预算内），算完就转入执行阶段
function Recipe:advanceCompactPlan(job, now)
    --- 整理计划只用当前已扫到的容器结果：计算期间打开“只读缓存模式”——
    --- 1.7.0：容器读取本来就是"快照模式"（只有扫描队列会读外设），不需要再切只读缓存模式
    --- 用 pcall 包住：算计划中途抛错（非 PLAN_YIELD）时也必须把只读缓存模式关掉，
    --- 否则引擎后面做搬运判断时也会“只看旧缓存”，那样会漏搬/错判。
    local okPlan, plan, done = pcall(self.Containers.compactPlanPass, self.Containers, job.planner)
    if not okPlan then
        error(plan, 0)
    end
    if not done then
        -- 还没算完（这一轮的外设调用预算用光）：下个 tick 接着算。
        -- 每 5 秒报一次进度，方便在网页/终端上看到“确实在算”。
        if (now or 0) - (job.lastPlanReportAt or 0) >= 5000 then
            job.lastPlanReportAt = now
            local planner = job.planner or {}
            local stage = tostring(planner.stage or "scan")
            if stage == "detail" then
                --- 正在等 worker 把物品详情（maxCount）送回来 —— 主控自己没有做阻塞的 getItemDetail
                stage = "waiting for worker item details"
            end
            self.log("Storage compact planning: %s (%d/%d containers, %d/%d kinds probed, %d call(s))",
                stage, tonumber(planner.containersDone) or 0,
                tonumber(planner.containersTotal) or 0, tonumber(planner.groupsDone) or 0,
                tonumber(planner.groupsTotal) or 0, tonumber(planner.totalCalls) or 0)
        end
        return false
    end
    plan = plan or {}
    -- 计划就绪：统计种类数与总搬运量（网页显示与日志用），然后开始执行
    local kinds, items = {}, 0
    for _, move in ipairs(plan) do
        items = items + (tonumber(move.amount) or 0)
        kinds[tostring(move.name) .. "\1" .. tostring(move.nbt or "")] = true
    end
    local kindCount = 0
    for _ in pairs(kinds) do
        kindCount = kindCount + 1
    end
    job.state = "running"
    job.plan = plan
    job.index = 1
    job.total = #plan
    job.items = items
    job.kinds = kindCount
    job.planner = nil
    job.plannedAt = now
    job.lastReportAt = now
    self.Cache:markDirty()
    self.log("Storage compact plan ready: %d move(s) (%d item(s), %d kind(s)) - executing %d per tick",
        job.total, job.items, job.kinds, self.compactOpsPerTick or 3)
    return true
end

--- 设置自动整理的空槽位阈值（用户第 4 项，网页设置里的输入框）：0 ~ 1，超出就夹到边界。
--- 阈值改了要允许"马上重算一遍"：否则下面那条"输入没变就短路"会一直挡着，用户改完看不到效果。
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

--- 存储容器的空槽位比例（0 ~ 1）：总槽位数还不知道时返回 nil（调用方按"先不整理"处理）。
--- 数据来自 Containers:capacityStats（已占用槽位 / 总槽位数，带 TTL 缓存，不额外读外设）。
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

--- ===== 自动整理（1.8.0，用户第 4/5 项）=====
--- 不再有"手动点整理"：调度器每轮检查一次，**compact 队列为空**时就算一遍搬运计划，
--- 算完把**所有**搬运任务一次性排进 compact 队列（每个任务一个 tick 一步，多台 worker/本机协程并行执行）。
--- 计划本身仍是分批算的（每 tick 一小步，见 advanceCompactPlan），不会卡住主循环。
--- 计划的输入是**当前槽位扫描快照**（容器内容）+ 物品详情字典里的"槽位堆叠上限"（由 stackScan
--- 队列补齐）；还没扫到堆叠上限的物品在规划时直接跳过（见 Containers:compactPlanPass）。
--- 没有冷却：队列一空就算（用户要求）。
function Recipe:autoCompactStep(now)
    now = now or os.epoch("utc")
    local job = self.compact
    if not job then
        --- 用户第 4 项：存储容器空槽位还够（比例 ≥ 阈值）就**不整理** —— 有地方放东西就没必要搬；
        --- 总槽位数未知（外设还没扫到 size()）时同样先不整理，等知道容量再说。
        local freeRatio = self:storageFreeRatio()
        if freeRatio == nil or freeRatio >= (self.compactFreeRatio or 0.10) then
            return 0
        end
        --- 没有冷却（队列一空就算），但"输入没变、上一轮又什么都没排出来"时不重复算：
        --- 计划的输入 = 容器快照（换代次数）+ 已知的堆叠上限数量（见 Containers:planInputRevision）。
        local revision = self.Containers.planInputRevision and self.Containers:planInputRevision() or nil
        if revision ~= nil and revision == self.compactPlanRevision and (self.compactPlanQueued or 0) == 0 then
            return 0
        end
        self.compactPlanRevision = revision
        self:startCompact("storage")
        job = self.compact
    end
    if job.state == "planning" then
        self:advanceCompactPlan(job, now)
        return 0
    end
    local plan = job.plan or {}
    local queued, skipped, rejected = 0, job.skipped or 0, 0
    for _, move in ipairs(plan) do
        --- 复核源槽位里还是不是当初计划的那一堆（同名 + 同 NBT；整理期间流程可能也在搬东西）
        local current = move.name and self.Containers:stackAt(move.fromContainer, move.fromSlot) or nil
        if current and (current.name ~= move.name or tostring(current.nbt or "") ~= tostring(move.nbt or "")) then
            skipped = skipped + 1
        else
            --- 提交成一条搬运任务（进 compact 队列）。返回 "pending" = 已经排进队列（正常路径）
            local _, reason = self.Containers:pushItem(move.fromContainer, move.fromSlot, move.amount,
                move.toContainer, move.toSlot, nil, "compact")
            if reason == "pending" then
                queued = queued + 1
            else
                rejected = rejected + 1
            end
        end
    end
    self.compact = nil
    self.compactLastFinishAt = now
    self.compactPlanQueued = queued
    self.compactPlanStats = { total = #plan, queued = queued, skipped = skipped, rejected = rejected,
        skippedUnknown = job.skippedUnknown or 0, at = now }
    self.Cache:markDirty()
    self.log("Auto compact: %d/%d move task(s) queued into the compact queue (%d skipped, %d rejected)",
        queued, #plan, skipped, rejected)
    return queued
end

--- 整理进度（网页显示用；没有整理任务时返回 nil）
function Recipe:compactStatus()
    local job = self.compact
    if not job then
        --- 计划已经生成成搬运任务（在 compact 队列里跑）：显示上一次生成了多少条
        --- （只在生成后 30 秒内显示，之后进度条自己隐藏）
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
            --- 执行侧的进度由主控用 compact 队列的统计补上（见 buildStatus）
            done = 0,
            pending = stats.queued or 0,
            moved = 0,
            items = 0,
            kinds = 0,
            failed = 0,
        }
    end
    if job.state == "planning" then
        -- 计划还在算（分批进行）：网页显示“正在计算搬运计划（扫描容器 3/19）”
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

--- 推进整理任务（每次 tick 调用）：算计划阶段每 tick 走一小步，执行阶段最多搬 compactOpsPerTick 次
--- 兼容入口（诊断 / 旧调用方）：1.8.0 起整理没有"手动启动"，搬运任务也由调度器的 compact 队列执行。
--- 这里只推进"自动整理"：计划算完 → 一次性生成所有搬运任务（见 autoCompactStep）。
function Recipe:stepCompact(now)
    return self:autoCompactStep(now)
end

--- 空闲判定：没有排队批次、没有上游请求、也没有等待中的步骤 ⇒ 这个流程完全没事可做。
--- 系统里大多数流程大多数时间都是空闲的（空闲流程不列出、也不处理），
--- 所以 tick 与 runtime() 都要先把它们筛掉，避免每 tick 白跑一遍、每帧白推一遍。
function Recipe:idleRecord(record)
    if not record then
        return true
    end
    if (tonumber(record.batch) or 0) > 0 then
        return false
    end
    if (tonumber(record.userCount) or 0) > 0 then
        return false
    end
    if (tonumber(record.downstreamCount) or 0) > 0 then
        return false
    end
    if record.wait ~= nil then
        return false
    end
    -- 只有真正的 idle（或还没有运行态）才算空闲：missing / waiting / running 都要继续推进
    local state = record.state
    if state ~= nil and state ~= "idle" then
        return false
    end
    return true
end

--- 队列外的每轮维护（1.7.0）：外设包装自愈、在飞搬运记忆清理、输入容器卸货。
--- 这些不属于"调度器推进"，worker 全忙时也照做。
function Recipe:maintain(now)
    now = now or os.epoch("utc")
    self.tickCount = (self.tickCount or 0) + 1
    self.lastTickAt = now
    -- 每 10 秒丢弃一次外设包装缓存：外设被替换 / 区块重载后旧包装对象会失效，
    -- 这样不用重启服务端也能自愈（否则 pushItems / list 可能一直静默失败）。
    if now - (self.wrapResetAt or 0) >= 10000 then
        self.wrapResetAt = now
        self.Peripherals:invalidate()
    end
    --- 在飞搬运的记忆（见在飞搬运的记忆一节）：清掉过期的（worker 早已超时的那些）
    self:sweepPendingMoves(now)
    --- 输入容器：不再每轮扫一遍 —— 1.8.0 起由 inputScan 队列扫描成功后触发入库任务生成
    --- （见 IFMMaster 的 afterScan → drainInputContainers(now, container)）。
    -- 本轮的细分计数（慢步骤明细用）：真正读了几次外设（缓存命中不算）
    self.tickStats = {
        steps = 0, active = 0, processes = #self.Store:list("processes"), reads = 0, readMs = 0,
        readsAtStart = self.Containers.readCount or 0,
        readMsAtStart = self.Containers.readMsTotal or 0,
    }
end

--- 本轮结束：把容器读取计数收尾（主控在一次调度执行完成后调用）
function Recipe:finishTick()
    local stats = self.tickStats
    if not stats then
        return
    end
    stats.reads = (self.Containers.readCount or 0) - (stats.readsAtStart or 0)
    stats.readMs = (self.Containers.readMsTotal or 0) - (stats.readMsAtStart or 0)
end

--- 流程队列的一条任务 = 一个进程推进一步。
--- 这个流程现在"有事可做"吗（批次 / 用户下单 / 下游需求任一 > 0）。
--- 空闲流程不要进流程队列 —— 生成器与流程队列的 run 都用这一个判断，
--- 免得"没事可做"的流程每轮白占一个时间片。
function Recipe:hasPendingWork(record)
    if type(record) ~= "table" then
        return false
    end
    return (tonumber(record.batch) or 0) > 0 or (tonumber(record.userCount) or 0) > 0 or
        (tonumber(record.downstreamCount) or 0) > 0
end

--- 一步的定义：一次材料输入 / 产物抽出调用算一步，无论它是否搬满了
--- 需要的数量 —— 调用完就让位（回队列尾），否则机器还在合成时这个进程会一直卡着等产物抽取。
--- 返回 true = 还没结束（调度器把它放回队尾）；false = 没事可做了（出队）。
function Recipe:stepProcessOnce(name, now)
    local process = self.Store:get("processes", name)
    if not process then
        return false                        -- 定义被删了：任务出队
    end
    local record = self:record(name)
    --- 空闲（没有批次 / 下单 / 下游需求）→ 立刻出队：不推进、也不消耗时间片。
    --- 编码规范（用户第 1 项）：这属于未定义行为（生成器只该把"有事可做"的流程排进队列），
    --- 所以必须报错并计数，而不是静默出队 —— 否则出了 bug 谁也看不见。
    if not self:hasPendingWork(record) or self:idleRecord(record) then
        self.guardCounters = self.guardCounters or {}
        self.guardCounters.idleProcessInQueue = (self.guardCounters.idleProcessInQueue or 0) + 1
        self.log("[IFM] BUG: idle process %s was in the process queue (state=%s) - the generator must not enqueue it",
            tostring(name), tostring(record and record.state))
        if record.state ~= "idle" then
            -- 上一批刚跑完：把残留的运行态清干净（网页那边也才会把这一行移除）
            record.state = "idle"
            record.phase = "input"
            record.progress = nil
            record.current = nil
            record.wait = nil
            self.Cache:markDirty()
        end
        return false
    end
    local stats = self.tickStats
    if stats then
        stats.active = stats.active + 1
        stats.steps = stats.steps + 1
    end
    local ok, err = pcall(self.stepProcess, self, process, now)
    if not ok then
        record = self:record(name)
        record.lastError = tostring(err)
        self.log("Process %s failed: %s", tostring(name), tostring(err))
        self.Cache:markDirty()
    end
    record = self:record(name)
    return not self:idleRecord(record)      -- 还有事 → 回队尾
end

--- 把所有"有事可做但还没在流程队列里"的流程补进队列（调度器的生成器每轮调用一次）。
--- 队列本身是 FIFO + 出队才回队：同一个进程不会在队列里出现两次；
--- dispatch:isQueued 只是兜底（例如用户在它排队时又点了一次合成）。
function Recipe:enqueueActiveProcesses(dispatch)
    if not dispatch then
        return 0
    end
    local added = 0
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self.Cache.data.processes and self.Cache.data.processes[process.name]
        if record then
            --- 空闲流程（没有批次 / 下单 / 下游需求）不进队列
            local pending = self:hasPendingWork(record)
            if not pending then
                -- 没有任何待办（批次 / 用户下单 / 上游需求都是 0）：清掉残留运行态
                -- （旧实现是在"每 tick 遍历所有流程"里做这件事，现在由这个生成器负责）
                if record.state ~= "idle" or record.wait ~= nil or record.progress ~= nil or
                    record.current ~= nil or record.pulse ~= nil then
                    record.state = "idle"
                    record.phase = "input"
                    record.progress = nil
                    record.current = nil
                    record.wait = nil
                    record.pulse = nil
                    record.outProgress = nil
                    self.Cache:markDirty()
                end
            elseif not dispatch:isQueued("process", process.name) then
                if dispatch:enqueue("process", { key = process.name, name = process.name }) then
                    added = added + 1
                end
            end
        end
    end
    return added
end

--- 兼容入口（诊断 / 旧调用方）：维护 + 待发送队列 + 整理。
--- 1.7.0 起流程推进走调度器的流程队列（见 stepProcessOnce / enqueueActiveProcesses）。
function Recipe:tick(now)
    now = now or os.epoch("utc")
    self:maintain(now)
    local okDeliver, errDeliver = pcall(self.processDeliveries, self, now)
    if not okDeliver then
        self.log("Delivery queue error: %s", tostring(errDeliver))
    end
    local okCompact, errCompact = pcall(self.stepCompact, self, now)
    if not okCompact then
        -- 整理出错就直接放弃这一次任务（下次网页再点一次即可），别让异常每 tick 重复抛
        self.compact = nil
        self.log("Storage compact error: %s", tostring(errCompact))
    end
    self:finishTick()
end

--- 最近一次 tick 的明细文本（主控的慢步骤日志会带上它：一眼看出慢在“推进流程”还是“扫描容器”）
function Recipe:tickStatsText()
    local stats = self.tickStats or {}
    local scan = self.Containers.scanSummary and self.Containers:scanSummary() or {}
    return string.format(
        "active=%d/%d steps=%d containerReads=%d readMs=%dms | containers=%s readCost=%sms passCost=%sms scanTtl=%sms defer=%s",
        tonumber(stats.active) or 0,
        tonumber(stats.processes) or 0,
        tonumber(stats.steps) or 0,
        tonumber(stats.reads) or 0,
        tonumber(stats.readMs) or 0,
        tostring(scan.containers or "?"),
        tostring(scan.readCost or "?"),
        tostring(scan.passCost or "?"),
        tostring(scan.ttl or "?"),
        tostring(scan.defer or 0))
end

--- 清理已被删除定义的残留运行态
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

--- 存储容器中某资源的数量（过滤器按符合的物品个数 + 流体 mB 之和）
function Recipe:storageCount(kind, name)
    if kind == "filter" then
        return self.Containers:filterCount(name)
    end
    local total = self.Containers:countOf({ kind = kind, id = name }, "storage")
    return total
end

--- 存储容器里相对“本批基线”增加的数量：
--- 很多机器（例如 Create 搅拌盆 + 漏斗）会把产物直接吐进存储容器，机器输出容器里什么都没有，
--- 所以判断“产物是否到手”必须把存储增量也算上。
function Recipe:storageGain(spec, record)
    local baseline = (record.baseline or {})[spec.kind .. ":" .. spec.id] or 0
    return math.max(0, self:storageCount(spec.kind, spec.id) - baseline)
end

--- 单个流程的产物进度（当前存储数目 / 目标数目）
function Recipe:progressOf(record)
    local batch = record.batch or 0
    if batch <= 0 or record.phase ~= "output" then
        return {}
    end
    local baseline = record.baseline or {}
    local out = {}
    for _, entry in ipairs(record.target or {}) do
        local key = entry.kind .. ":" .. entry.id
        local current = self:storageCount(entry.kind, entry.id)
        local produced = math.max(0, current - (baseline[key] or 0))
        local percent = 1
        if (entry.target or 0) > 0 then
            percent = math.min(1, produced / entry.target)
        end
        out[#out + 1] = {
            kind = entry.kind,
            id = entry.id,
            current = current,
            produced = produced,
            target = entry.target,
            percent = percent,
        }
    end
    return out
end

--- 当前正在处理/等待的元素（给网页显示“正在发送 xxx / 正在抽取 xxx / 等待…”用）
function Recipe:currentElement(process, record)
    local index = tonumber(record.index) or 1
    local isOutput = record.phase == "output"
    local list = isOutput and (process.outputs or {}) or (process.inputs or {})
    local element = list[index]
    if type(element) ~= "table" then
        return nil
    end
    local key = tostring(index)
    local batch = math.max(1, tonumber(record.batch) or 1)
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
        else
            entry.done = (record.progress or {})[key] or 0
            entry.target = (tonumber(element.count) or 0) * batch
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
        -- 只引用机器定义的信号序号（全局“红石信号序号”已移除；默认 1）
        entry.machineSignalIndex = tonumber(element.machineSignalIndex) or 1
    end
    return entry
end

--- 当前批次里“正在合成”的份数（材料已送达机器、还没出货的那些）：
---   * 每个材料输入元素有“每份需要多少个”（element.count），已送达数量 / 该比值 = 这一元素够做几份；
---     取所有输入里的最小值（任一材料不够就做不出那么多份），再按当前批次数封顶；
---   * 没有材料输入的流程（纯等待 / 红石等待）算整批都在合成；
---   * 用途：网页流程依赖图的材料节点上显示「正在合成 / 剩余目标」（用户第 11 项要求）。
function Recipe:activeUnits(process, record)
    local batch = tonumber(record and record.batch) or 0
    if batch <= 0 then
        return 0
    end
    local progress = (record and record.progress) or {}
    local units = nil
    for index, element in ipairs(process.inputs or {}) do
        if element.kind == "item" or element.kind == "fluid" or element.kind == "filter" then
            local each = tonumber(element.count) or 0
            if each > 0 then
                local transferred = tonumber(progress[tostring(index)]) or 0
                local covered = math.floor(transferred / each)
                if units == nil or covered < units then
                    units = covered
                end
            end
        end
    end
    if units == nil then
        units = batch
    end
    return math.max(0, math.min(batch, units))
end

--- ===== 输入容器（role = "input"）=====
--- 用途（用户第 13 项要求）：把外设设成“输入容器”后，IFM 会像扫描存储容器一样定期扫它，
--- 一旦里面有东西就搬进存储容器 —— 这样人工/上游丢进去的料会自动进入存储系统，
--- 参与库存统计与后续合成，不需要手动开容器工具搬。
--- 1.7.0：输入容器卸货不再有毫秒间隔与"每轮最多 N 次"的硬上限：
--- 每个调度轮次看一遍输入容器的快照（扫描由 inputScan 队列负责），有货就提交入库任务
--- （进 inventoryIn 队列；重复提交由 Containers.moveInflight 去重），pending 时下轮继续。

function Recipe:drainInputContainers(now, onlyPeripheral)
    now = now or os.epoch("utc")
    self.inputDrain = self.inputDrain or { items = 0, fluids = 0, lastAt = 0, lastLogAt = 0 }
    local state = self.inputDrain
    --- 1.7.0：不再有"每 INPUT_DRAIN_INTERVAL 毫秒扫一轮"的硬间隔 —— 输入容器的内容由
    --- inputScan 队列扫（扫描成功时才调用本函数，见 IFMMaster 的 afterScan），有货就提交入库任务
    --- （重复提交会被 moveInflight 去重），因此"投料 → 入库"的延迟只取决于队列轮转。
    state.lastAt = now
    local sources = {
        item = self.Containers:byRole("input", "item"),
        fluid = self.Containers:byRole("input", "fluid"),
    }
    --- onlyPeripheral（1.8.0）：只处理刚刚扫到的那个输入容器（扫描成功触发的入库任务）。
    --- byRole 返回的是**容器名**，所以容器名与外设名都对一下。
    if onlyPeripheral then
        local function keepOnly(list, kind)
            local out = {}
            for _, name in ipairs(list) do
                if name == onlyPeripheral or
                    self.Containers:peripheralOf(name, kind) == onlyPeripheral then
                    out[#out + 1] = name
                end
            end
            return out
        end
        sources.item = keepOnly(sources.item, "item")
        sources.fluid = keepOnly(sources.fluid, "fluid")
    end
    if #sources.item == 0 and #sources.fluid == 0 then
        return 0
    end
    local targets = {
        item = self.Containers:byRole("storage", "item", "out"),
        fluid = self.Containers:byRole("storage", "fluid", "out"),
    }
    local ops = 0
    local movedItems = 0
    local movedFluids = 0
    local pending = false
    --- 用户第 4 项：输入容器里同时有好几格东西时，一轮里**能提交的搬运全部提交**（并行）。
    --- 以前是"第一条交给 worker（err = pending）就 return"，于是每个扫描周期只搬走一格 ——
    --- 现场看就是"输入容器里的东西没有被并行搬走"。上限只用于防止一次塞爆队列；
    --- 去重与源槽位预留由 Containers:pushItem / reserveOut 负责（同一格不会被提交两次）。
    local INPUT_DRAIN_MAX_MOVES = 32
    local submitted = 0

    local function drainItems()
        if #targets.item == 0 then
            return
        end
        for _, source in ipairs(sources.item) do
            if submitted >= INPUT_DRAIN_MAX_MOVES then
                return
            end
            for _, stack in ipairs(self.Containers:orderStacks(self.Containers:stacks(source),
                self.Containers.ORDER_FRAGMENT)) do
                if submitted >= INPUT_DRAIN_MAX_MOVES then
                    return
                end
                local amount = tonumber(stack.count) or 0
                if amount > 0 then
                    for _, target in ipairs(targets.item) do
                        local got, err = self.Containers:pushItem(source, stack.slot, amount, target, nil,
                            --- 输入容器 → 存储容器：先并入同类槽位，少留碎片（1.6.11）
                            self.Containers.INSERT_LEAST, "inventoryIn")
                        if err == "pending" then
                            --- 这一格已经交给 worker / 本机池了：继续排下一格（不再中断整轮）
                            pending = true
                            submitted = submitted + 1
                            break
                        end
                        got = tonumber(got) or 0
                        if got > 0 then
                            self.Containers:invalidate()
                            state.items = (state.items or 0) + got
                            movedItems = movedItems + got
                            ops = ops + 1
                            break
                        end
                    end
                end
            end
        end
    end

    local function drainFluids()
        if #targets.fluid == 0 then
            return
        end
        for _, source in ipairs(sources.fluid) do
            if submitted >= INPUT_DRAIN_MAX_MOVES then
                return
            end
            for _, tank in ipairs(self.Containers:tanks(source)) do
                if submitted >= INPUT_DRAIN_MAX_MOVES then
                    return
                end
                local amount = tonumber(tank.amount) or 0
                if amount > 0 then
                    for _, target in ipairs(targets.fluid) do
                        local got, err = self.Containers:pushFluid(source, amount, tank.name, target, "inventoryIn")
                        if err == "pending" then
                            --- 同一个道理（用户第 4 项）：继续排下一罐，不再中断整轮
                            pending = true
                            submitted = submitted + 1
                            break
                        end
                        got = tonumber(got) or 0
                        if got > 0 then
                            self.Containers:invalidate()
                            state.fluids = (state.fluids or 0) + got
                            movedFluids = movedFluids + got
                            ops = ops + 1
                            break
                        end
                    end
                end
            end
        end
    end

    drainItems()
    drainFluids()
    local moved = movedItems + movedFluids
    if moved > 0 and now - (state.lastLogAt or 0) >= 30000 then
        state.lastLogAt = now
        self.log("Input containers drained: %d item(s) / %d mB fluid moved into storage (totals %d / %d)",
            movedItems, movedFluids, state.items or 0, state.fluids or 0)
    end
    return moved
end

--- 流程运行态（推送给网页）
--- 只下发有事可做的流程（idle 的不下发，也不创建记录）：系统里大多数流程大多数时间都是空闲的，
--- 之前每个 tick 都把它们推一遍，既浪费带宽也让浏览器白重画。
function Recipe:runtime()
    local out = {}
    for _, process in ipairs(self.Store:list("processes")) do
        local record = self.Cache.data.processes and self.Cache.data.processes[process.name]
        if record and not self:idleRecord(record) then
            out[#out + 1] = {
                name = process.name,
                state = record.state or "idle",
                phase = record.phase or "input",
                batch = record.batch or 0,
                maxMultiplier = math.max(1, tonumber(process.maxMultiplier) or 1),
                userCount = record.userCount or 0,
                downstreamCount = record.downstreamCount or 0,
                remaining = (record.userCount or 0) + (record.downstreamCount or 0),
                --- 正在合成的份数（材料已送到机器的那部分）：材料节点显示「active/remaining」
                active = self:activeUnits(process, record),
                machine = record.machine,
                lastError = record.lastError,
                waitKind = record.wait and record.wait.kind or nil,
                current = self:currentElement(process, record),
                progress = self:progressOf(record),
            }
        end
    end
    return out
end

--- 可以产出该资源的全部流程名（不含抽象模板：模板带虚操作，只能用于复制流程设置）
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

--- 只被“抽象模板”（含虚操作）产出的资源：返回那个模板的名字 —— 下单时用它给出具体原因，
--- 而不是笼统地说“没有可以产出该资源的流程”（模板本来就不能合成）。
--- 只被抽象流程"产出"的资源（含 abstract 操作的流程）：用它给出更准确的错误提示
--- （"抽象流程不能用于合成"，而不是笼统的"没有流程能产出"）
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

--- 某个流程的某个产物每批产出多少（“想要 N 个产物”换算成“要跑几批”用）
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

--- 网页 + 号：按资源启动合成（可指定流程名）
--- 说明：count 是想要的产物数量（不是批次数），这里按“每批产出”换算批次数
function Recipe:startResource(kind, name, count, processName)
    count = math.max(1, math.floor(tonumber(count) or 1))
    if not processName then
        local best = nil
        local bestScore = nil
        for _, candidate in ipairs(self:producers(kind, name)) do
            local process = self.Store:get("processes", candidate)
            if process then
                local record = self:record(candidate)
                local score = record.state == "missing" and 0 or 1000
                for _, output in ipairs(process.outputs or {}) do
                    if self:outputMatchesInput(output, { kind = kind, id = name }) then
                        local priority = tonumber(output.priority) or 0
                        if priority > score then
                            score = priority
                        end
                    end
                end
                if bestScore == nil or score > bestScore then
                    best = candidate
                    bestScore = score
                end
            end
        end
        processName = best
    end
    if not processName then
        -- 只有抽象流程（含 abstract 操作）能产出它：直接说清为什么不能合成，比"没有流程"好定位
        if self:abstractProducer(kind, name) then
            return false, ABSTRACT_MESSAGE
        end
        return false, "\\u6CA1\\u6709\\u53EF\\u4EE5\\u4EA7\\u51FA\\u8BE5\\u8D44\\u6E90\\u7684\\u6D41\\u7A0B"
    end
    local process = self.Store:get("processes", processName)
    local perBatch = self:outputPerBatch(process, kind, name)
    local batches = math.max(1, math.ceil(count / perBatch))
    local ok, info = self:start(processName, batches)
    if not ok then
        return false, info
    end
    return true, {
        process = processName,
        userCount = info.userCount,
        kind = kind,
        name = name,
        count = count,
        perBatch = perBatch,
        batches = batches,
    }
end

--- 追加用户合成次数
function Recipe:start(processName, count)
    local process = self.Store:get("processes", processName)
    if not process then
        return false, "\\u6D41\\u7A0B " .. tostring(processName) .. " \\u4E0D\\u5B58\\u5728"
    end
    if self:isAbstract(process) then
        -- 抽象流程只用于"流程设置复制"：它的 abstract 操作不对应任何真实资源
        return false, ABSTRACT_MESSAGE
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local record = self:record(processName)
    record.userCount = (record.userCount or 0) + count
    if record.state == "missing" and (record.batch or 0) <= 0 then
        record.state = "idle"
        record.wait = nil
    end
    self.Cache:markDirty()
    return true, {
        process = processName,
        userCount = record.userCount,
        downstreamCount = record.downstreamCount or 0,
    }
end

--- 直接设定用户合成次数
function Recipe:setUserCount(processName, count)
    local process = self.Store:get("processes", processName)
    if not process then
        return false, "\\u6D41\\u7A0B " .. tostring(processName) .. " \\u4E0D\\u5B58\\u5728"
    end
    if self:isAbstract(process) then
        return false, ABSTRACT_MESSAGE
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    local record = self:record(processName)
    record.userCount = count
    self.Cache:markDirty()
    return true, { process = processName, userCount = record.userCount }
end

--- 取消流程（清空计数并释放机器并行位）
function Recipe:cancel(processName)
    local process = self.Store:get("processes", processName)
    if not process then
        return false, "\\u6D41\\u7A0B " .. tostring(processName) .. " \\u4E0D\\u5B58\\u5728"
    end
    local record = self:record(processName)
    if record.machine then
        self:occupyMachine(record.machine, -1)
    end
    record.state = "idle"
    record.batch = 0
    record.userCount = 0
    record.downstreamCount = 0
    record.machine = nil
    record.wait = nil
    record.phase = "input"
    record.index = 1
    record.progress = {}
    record.outProgress = {}
    --- 取消流程：它的在飞搬运记忆一并清掉（下一次重新开始会重新扫源）
    self:forgetPendingMovesWithPrefix("in:" .. tostring(process.name) .. "\1")
    self:forgetPendingMovesWithPrefix("out:" .. tostring(process.name) .. "\1")
    -- 取消时把还没跑完的红石脉冲复位（否则中继器会一直停在通电状态）
    if record.pulse then
        self:switchSignals(record.pulse.targets, 0)
        record.pulse = nil
    end
    -- 取消时把对外请求一并撤销（含上游的下游计数），上游才能真正停下来
    for key in pairs(record.requests or {}) do
        self:clearRequest(record, key)
    end
    record.requests = {}
    record.lastError = nil
    self.Cache:markDirty()
    return true, { canceled = processName }
end

--- 排队发送：把存储容器中已有的资源送到 output 容器。
--- 资源种类可以是 item / fluid / filter；容器种类按目标容器定义自己的种类判定。
function Recipe:queueSend(kind, name, count, containerName)
    local container = self.Store:findContainer(containerName, kind)
    if not container then
        return false, "\\u5BB9\\u5668 " .. tostring(containerName) .. " \\u4E0D\\u5B58\\u5728"
    end
    if container.role ~= "output" then
        return false, "\\u53EA\\u80FD\\u53D1\\u9001\\u5230 output \\u89D2\\u8272\\u7684\\u5BB9\\u5668"
    end
    if not self.Containers:supports(containerName, kind) then
        return false, self.Containers:unusableReason(containerName, kind) or "\\u5BB9\\u5668\\u4E0D\\u53EF\\u7528"
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local entry = self:addDelivery({
        kind = kind,
        name = name,
        container = container.name,
        containerKind = self.Util.kindOfDef(container),
        remaining = count,
        total = count,
        createdAt = os.epoch("utc"),
    })
    return true, { id = entry.id, kind = kind, name = name, count = count, container = container.name }
end

--- 排队发送 + 触发合成：已有的库存先发出去，只有缺的部分才交给流程合成，
--- 合成出的产物落进存储容器后由发送队列继续搬运到 output 容器。
function Recipe:craftAndSend(kind, name, count, containerName)
    local container = self.Store:findContainer(containerName, kind)
    if not container then
        return false, "\\u5BB9\\u5668 " .. tostring(containerName) .. " \\u4E0D\\u5B58\\u5728"
    end
    if container.role ~= "output" then
        return false, "\\u53EA\\u80FD\\u53D1\\u9001\\u5230 output \\u89D2\\u8272\\u7684\\u5BB9\\u5668"
    end
    if not self.Containers:supports(containerName, kind) then
        return false, self.Containers:unusableReason(containerName, kind) or "\\u5BB9\\u5668\\u4E0D\\u53EF\\u7528"
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    -- 已有库存先发；只把不足的部分交给流程（不要按全量下单，否则库存会被卡在“未发送”）
    local available = self:storageCount(kind, name)
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

--- 待发送队列（推送给网页）
function Recipe:deliveries()
    local out = {}
    for _, delivery in ipairs(self.Cache:deliveries()) do
        out[#out + 1] = {
            id = delivery.id,
            kind = delivery.kind,
            name = delivery.name,
            remaining = delivery.remaining or 0,
            total = delivery.total or 0,
            container = delivery.container,
            processName = delivery.processName,
            lastError = delivery.lastError,
        }
    end
    return out
end

return Recipe
