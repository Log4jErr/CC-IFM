-- IFM :: modules/containers.lua
-- 容器读写：统计、槽位查找、物品/流体搬运。
-- 对外一律使用“容器定义名称”，内部解析为外设名称后调用 pushItems / pullItems / pushFluid / pullFluid。

local Containers = {}
Containers.__index = Containers

--- 来源与目标是同一个外设时的说明（推给自己不会真的移动物品/流体）
local function samePeripheralReason(fromContainer, toContainer, peripheralName)
    return "\\u6765\\u6E90\\u5BB9\\u5668 " .. tostring(fromContainer) .. " \\u4E0E\\u76EE\\u6807\\u5BB9\\u5668 " .. tostring(toContainer)
        .. " \\u6307\\u5411\\u540C\\u4E00\\u4E2A\\u5916\\u8BBE\\uFF08" .. tostring(peripheralName) .. "\\uFF09\\uFF0C\\u65E0\\u6CD5\\u642C\\u8FD0"
end

--- 单个槽位的“可存物品数”缺省值：外设不提供 getItemLimit 时按原版一组的最大数量（64）估算
local DEFAULT_SLOT_CAPACITY = 64
--- 物品“一组”的缺省最大数量（CC:T 文档 item_details.txt 里的 maxCount）：查不到时按 64 算
--- 在飞搬运记录的存活上限（毫秒）：超过就按"没搬走"结算并丢弃（快照由扫描纠正）
local MOVE_RECORD_TTL = 60000

local DEFAULT_ITEM_MAX_COUNT = 64
--- 单个容器最多统计多少个槽位（异常外设报出超大槽位数时的保护）
local MAX_CONTAINER_SLOTS = 4096
--- 一次“整理”计划里允许的外设调用次数（有线网络上的 getItemLimit / getItemDetail 可能很慢，
--- 超出预算的槽位按“只能装下现在这些”处理，绝不会被当成还有剩余空间的目标槽位）：
---   MAX_SLOT_LIMIT_QUERIES  槽位容量查询（getItemLimit）
---   MAX_EMPTY_SLOT_PROBES   空槽位容量探测（只用于“空槽二次优化”）
---   MAX_ITEM_DETAIL_QUERIES 物品最大堆叠数查询（getItemDetail，每种物品一次）
local MAX_SLOT_LIMIT_QUERIES = 240
local MAX_EMPTY_SLOT_PROBES = 60
local MAX_ITEM_DETAIL_QUERIES = 40
--- 一个 tick 里最多请 worker 代查几批物品详情（见 Containers:requestItemDetails）：
--- 每批 = 一个 modem 请求，worker 那边每批最多查 DETAIL_BATCH_PER_REQUEST 个物品
--- （modules/transfer.lua）。派太多会把 modem 和 worker 都占满，太少则标签扫描推进很慢。
local MAX_DETAIL_REQUESTS_PER_PASS = 4
--- 整理计划等待「worker 代查物品详情」的最多遍数：详情是异步回来的，
--- 等不到就别再让出（否则 worker 一直不回 = 计划永远算不完），按缺省值 64 继续算完。
local DETAIL_WAITS_MAX = 8
--- 槽位容量缓存时长（毫秒）：槽位上限基本不变，重复点「整理」不必反复问外设
local SLOT_UNITS_TTL = 60000
--- 容器槽位总数（size）的缓存时长：一次整理要问每个容器一次，而它几乎不变
local SLOT_COUNT_TTL = 60000
--- ===== 整理计划的分批计算（绝不阻塞主循环）=====
--- 一次「整理」计划可能要问几百次 getItemLimit / getItemDetail，每次在有线网络上 ≈1 个服务器刻。
--- 一口气算完会把主循环卡住十几秒 —— 期间引擎不推进、网页收不到任何推送，浏览器会
--- “15 秒没收到服务端数据”然后重连（用户看到的就是“点了整理 → 15s 未收到服务器响应 → 已重新连接 →
--- 开始整理：263 步搬运”）。
--- 现在计划按 tick 分批算：每次（一个 tick）最多问 PLAN_CALLS_PER_PASS 次外设，
--- 算不完就中止本次、下个 tick 接着算（已经问过的结果都在缓存里，重跑会走得更远），
--- 直到算完为止 —— 全程不阻塞，网页能正常看到“正在计算搬运计划”。
local PLAN_CALLS_PER_PASS = 3
--- 整个计划允许问外设的次数上限：超出后按“保守值”处理（与旧版预算语义一致，避免病态底座算不完）
local PLAN_MAX_CALLS = 400
--- 单次计算被预算中止的标记（只在 containers.lua 内部传播）
local PLAN_YIELD = { ifmPlanYield = true }

--- 槽位容量的缓存键（外设名 + 槽位号）
local function slotUnitsKey(peripheralName, slot)
    return tostring(peripheralName) .. "\1" .. tostring(slot)
end

--- 槽位的“64 堆叠单位容量”C 换算成某物品能放多少个：
---   vol = 64 / maxCount（物品的“体积”）⇒ n = floor(C / vol) = floor(C * maxCount / 64)
--- 例：空槽位 getItemLimit = 512（即 C = 512）时，一组 16 个的物品能放 128 个。
local function capacityForItem(units, maxCount)
    maxCount = tonumber(maxCount) or DEFAULT_ITEM_MAX_COUNT
    if maxCount <= 0 then
        maxCount = DEFAULT_ITEM_MAX_COUNT
    end
    if not units or units <= 0 then
        return 0
    end
    return math.floor(units * maxCount / DEFAULT_ITEM_MAX_COUNT)
end

function Containers.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Containers)
    self.Util = opts.Util
    self.Peripherals = opts.Peripherals
    self.Store = opts.Store
    self.Filter = opts.Filter
    self.log = opts.log or function() end
    self.cacheTtl = opts.cacheTtl or 600
    --- 角色快照缓存：角色（storage / interaction / output）各存一份。
    --- 1.5.2 之前只有一个槽位，引擎在一个 tick 里交替读 storage 与 interaction 时会互相挤掉，
    --- 每次切换都要重建快照（重建会连带触发整批容器扫描），是“引擎 tick 常年几百毫秒”的主因之一。
    self.snapshots = {}
    -- 单个外设的 list() / tanks() 结果短时缓存（毫秒）：
    --   有线网络 / 复杂方块（抽屉、缓存、工作盆…）上这些调用可能几十毫秒，而一次推送、一个 tick 里
    --   会反复读同一批容器（资源统计、引擎取料/落库、标签扫描、诊断）。
    --   1.5.0：默认值 200ms 提到 1200ms —— 15 个容器逐个重读 ≈0.75s，而引擎 tick / 网页推送 /
    --   标签扫描之间通常隔了不止 200ms，等于每次都重扫一遍，主循环被扫描拖死（网页就“连不上”了）。
    --   安全前提：pushItem / pushFluid 会把动过的两个外设记进 self.dirty，invalidate() 只作废它们，
    --   所以“刚搬过的容器”下一次读取一定是新的，引擎不会基于过期槽位做决定。
    --- 1.6.15：缺省 8000 —— 语义就是“同一个容器从上次被扫描到下次被扫描的最小间隔”，
    --- 1.7.0：扫描不再有毫秒间隔 —— 由 storageScan / inputScan 队列按轮次驱动。
    --- 1.7.0：毫秒级的"扫描间隔 / 本机读预算 / 代扫限流"全部删除 ——
    --- 扫描由 storageScan / inputScan 队列按轮次推进（见 containers 顶部与 dispatch.lua）。
    self.readCostMs = 0        -- 单次外设读取耗时的平滑值（毫秒）
    self.listPassMs = 0        -- 估算的“读一遍全部容器”耗时（毫秒；诊断与慢 tick 明细里可见）
    self.readCount = 0         -- 累计真正调用外设读取的次数（诊断/引擎 tick 明细用）
    self.readMsTotal = 0       -- 累计外设读取耗时（毫秒）
    --- 物品详情字典：键「物品名 \1 NBT」→ { detail, hit, stamp, source }（见文件里的物品详情字典一节）
    self.detailCache = {}
    --- 物品详情能放多久：物品属性（maxCount / tags）一次会话里不会变，NBT 又在键里，
    --- 所以放长一点（5 分钟）也不会错 —— 它只是「这个物品的详情」的一份记忆。
    self.detailTtl = opts.detailTtl or 300000
    --- 物品详情提供者（worker 代查 getItemDetail，见 Containers:setDetailProvider）
    self.detailProvider = nil
    self.localDetailCalls = 0        -- 主控本机调用 getItemDetail 的次数（诊断：越少越好）
    --- ===== 容器内容模型（1.7.0 快照）=====
    --- 每个容器外设一份：slots/tanks 是最近一次扫描得到的真实内容（基准），pend 是还没被扫描覆盖的
    --- 乐观变更（出库先扣、入库后加），对外可见值 = 基准 + 乐观变更合计。
    ---   * 搬运任务自己不做扫描：源槽位/数量全部来自这里的可见值；
    ---   * 出库：派任务之前立刻 pend -= n（两个出库任务不会争抢同一堆）；
    ---   * 结算：按实际 moved 修正（见 settleMove）；扫描是权威基准，会丢掉"结算早于扫描"的变更。
    self.model = {}                  -- 外设名 -> { slots, tanks, pendSlots, pendTanks, gen, tick, stamp, scans }
    self.moveRequests = {}           -- 预留（旧接口兼容；现在用 moveInflight）
    self.moveInflight = {}           -- key -> 在飞/待领取的搬运记录（同一个逻辑搬运只预留一次）
    self.moveResults = {}            -- key -> { moved, err, at }（结算结果等调用方取走）
    self.scanSeen = {}               -- 扫描时看到过的物品（detail 队列的生成器取走即清空）
    self.tickCount = 0               -- 调度轮次计数（模型新鲜度按轮次判断，不是毫秒间隔）
    -- 搬运（可能）改动过的外设：invalidate() 只清它们，其它容器的扫描结果继续复用
    self.dirty = {}
    -- 每个外设的 list()/tanks() 调用耗时统计（诊断 perf 报告里能看到“哪个容器最慢”）
    self.scanStats = {}
    -- 容量统计缓存时长：容量几乎不变，而外设调用（尤其有线网络上的容器）可能很慢，
    -- 没必要跟着 2 秒一次的推送反复问外设。
    self.capacityTtl = opts.capacityTtl or 15000
    self.capacityCache = nil
    -- 「整理」用的容量缓存：槽位的 64 堆叠单位容量（getItemLimit）与物品的最大堆叠数（getItemDetail）
    self.slotUnitsCache = {}
    self.itemMaxCountCache = {}
    return self
end

--- 容器定义 -> 外设名称（外设缺失时返回 nil）。
--- kind 指定容器种类（item / fluid）：物品容器与流体容器可以同名，靠它区分；不传时优先物品容器。
function Containers:peripheralOf(containerName, kind)
    local def = self.Store:findContainer(containerName, kind)
    if not def then
        return nil
    end
    local peripheralName = def.peripheral
    if not self.Peripherals:exists(peripheralName) then
        return nil
    end
    return peripheralName
end

--- 容器是否可用、且具备该种类所需的能力（item -> inventory，fluid -> fluid_storage）
function Containers:supports(containerName, kind)
    local def = self.Store:findContainer(containerName, kind)
    if not def then
        return false
    end
    local defKind = self.Util.kindOfDef(def)
    -- 资源种类 filter 可能匹配物品或流体：按容器定义自己的种类判断能力；
    -- item / fluid 则必须与容器定义的种类一致。
    if kind and kind ~= "filter" and defKind ~= kind then
        return false
    end
    if not self.Peripherals:exists(def.peripheral) then
        return false
    end
    if defKind == "fluid" then
        return self.Peripherals:isFluid(def.peripheral)
    end
    return self.Peripherals:isInventory(def.peripheral)
end

--- 给诊断信息用：说明某个容器定义为什么不能按 kind 使用（可用时返回 nil）
function Containers:unusableReason(containerName, kind)
    if containerName == nil or containerName == "" then
        return "\\u672A\\u6307\\u5B9A\\u5BB9\\u5668"
    end
    local def = self.Store:findContainer(containerName, kind)
    if not def then
        return "\\u5BB9\\u5668\\u5B9A\\u4E49 " .. tostring(containerName) .. " \\u4E0D\\u5B58\\u5728"
    end
    local defKind = self.Util.kindOfDef(def)
    if kind and kind ~= "filter" and defKind ~= kind then
        return "\\u5BB9\\u5668\\u5B9A\\u4E49 " .. def.name .. " \\u662F" .. (defKind == "fluid" and "\\u6D41\\u4F53" or "\\u7269\\u54C1") .. "\\u5BB9\\u5668"
    end
    if not self.Peripherals:exists(def.peripheral) then
        return "\\u5BB9\\u5668\\u5B9A\\u4E49 " .. def.name .. " \\u7684\\u5916\\u8BBE " .. def.peripheral .. " \\u4E0D\\u5B58\\u5728"
    end
    if defKind == "fluid" then
        if not self.Peripherals:isFluid(def.peripheral) then
            return "\\u5916\\u8BBE " .. def.peripheral .. " \\u4E0D\\u63D0\\u4F9B\\u6D41\\u4F53\\u5BB9\\u5668\\uFF08fluid_storage\\uFF09"
        end
    elseif not self.Peripherals:isInventory(def.peripheral) then
        return "\\u5916\\u8BBE " .. def.peripheral .. " \\u4E0D\\u63D0\\u4F9B\\u7269\\u54C1\\u5BB9\\u5668\\uFF08inventory\\uFF09"
    end
    return nil
end

--- 容器定义的存储优先级（可选参数，缺省 0）：
--- 高优先级容器里的资源优先存入，低优先级容器里的资源优先取出（同为 0 时按定义名排序）
function Containers.priorityOf(def)
    return tonumber(def and def.priority) or 0
end

--- 按角色列出容器定义名称（可按容器种类过滤：item / fluid）。
--- order：
---   "out"（存入）→ 优先级从大到小（高优先级容器优先存入）
---   "in" （取出）→ 优先级从小到大（低优先级容器优先取出）
---   nil           → 按定义名排序（展示用的稳定顺序，与旧行为一致）
function Containers:byRole(role, kind, order)
    local defs = {}
    for _, def in ipairs(self.Store:list("containers")) do
        local defKind = self.Util.kindOfDef(def)
        if ((not role) or def.role == role) and ((not kind) or defKind == kind) then
            defs[#defs + 1] = def
        end
    end
    if order == "in" or order == "out" then
        local descending = order == "out"
        table.sort(defs, function(a, b)
            local priorityA, priorityB = Containers.priorityOf(a), Containers.priorityOf(b)
            if priorityA ~= priorityB then
                if descending then
                    return priorityA > priorityB
                end
                return priorityA < priorityB
            end
            return tostring(a.name) < tostring(b.name)
        end)
    end
    local out = {}
    for _, def in ipairs(defs) do
        out[#out + 1] = def.name
    end
    return out
end

function Containers:inventory(peripheralName)
    if not self.Peripherals:isInventory(peripheralName) then
        return nil
    end
    return self.Peripherals:wrap(peripheralName)
end

function Containers:fluidStorage(peripheralName)
    if not self.Peripherals:isFluid(peripheralName) then
        return nil
    end
    return self.Peripherals:wrap(peripheralName)
end

--- 记录一次外设调用耗时（诊断用；只在真正调用外设时统计）
local function noteScan(self, peripheralName, method, startedAt)
    local bucket = self.scanStats[peripheralName]
    if not bucket then
        bucket = { name = peripheralName, calls = 0, total = 0, max = 0, item = 0, fluid = 0 }
        self.scanStats[peripheralName] = bucket
    end
    local elapsed = (os.epoch("utc") - startedAt)
    bucket.calls = bucket.calls + 1
    bucket.total = bucket.total + elapsed
    if elapsed > bucket.max then
        bucket.max = elapsed
    end
    if method == "tanks" then
        bucket.fluid = bucket.fluid + 1
    else
        bucket.item = bucket.item + 1
    end
    self:noteReadCost(elapsed)
end

--- 记一次真实的外设读取耗时（缓存命中不算）：
--- 平滑值用于估算“读一遍全部容器要多久”，进而决定扫描缓存能放多久（见 effectiveListTtl）。
function Containers:noteReadCost(elapsed)
    elapsed = math.max(1, math.floor(tonumber(elapsed) or 1))
    self.readCount = (self.readCount or 0) + 1
    self.readMsTotal = (self.readMsTotal or 0) + elapsed
    -- 本机扫描预算（见 Containers.new）：只统计真的读了外设的耗时，缓存命中不算
    local cost = self.readCostMs or 0
    if cost <= 0 then
        self.readCostMs = elapsed
    else
        -- 指数平滑（新值占 1/4）：一次抖动不会永久拉长缓存，持续变慢会逐步生效
        self.readCostMs = (cost * 3 + elapsed) / 4
    end
end



--- 当前有线网络上的容器外设数量：读一遍全部容器 ≈ 单次读取耗时 × 这个数。
--- Peripherals 每次重扫后才会改变，所以只在它重扫之后重算（本函数会被高频调用）。
function Containers:peripheralCount()
    local scanAt = (self.Peripherals and self.Peripherals.lastScan) or 0
    if self.peripheralCountValue == nil or self.peripheralCountAt ~= scanAt then
        local items = self.Peripherals and self.Peripherals:names("inventory") or {}
        local fluids = self.Peripherals and self.Peripherals:names("fluid") or {}
        self.peripheralCountValue = #items + #fluids
        self.peripheralCountAt = scanAt
    end
    return self.peripheralCountValue or 0
end



function Containers:scanSummary()
    --- 1.7.0：扫描由队列驱动，这里报告"模型新鲜度"（按轮次，不是毫秒间隔）
    local staleMax, staleSum, counted = 0, 0, 0
    for _, model in pairs(self.model) do
        local ageTicks = math.max(0, (self.tickCount or 0) - (model.tick or 0))
        staleSum = staleSum + ageTicks
        counted = counted + 1
        if ageTicks > staleMax then
            staleMax = ageTicks
        end
    end
    local cost = math.floor(self.readCostMs or 0)
    local pass = cost * math.max(1, self:peripheralCount())
    self.listPassMs = math.floor(pass)
    return {
        containers = self:peripheralCount(),
        scanned = counted,
        readCost = cost,
        passCost = self.listPassMs,
        --- 兼容旧字段：1.7.0 起没有"毫秒级扫描缓存时长"了
        ttl = 0,
        baseTtl = 0,
        multiplier = 0,
        reads = self.readCount or 0,
        readMs = self.readMsTotal or 0,
        defer = self.moveSettleCount or 0,
        budget = 0,
        --- 新字段：模型多久没被扫描过（轮次）
        staleTicks = staleMax,
        staleAvgTicks = counted > 0 and math.floor(staleSum / counted) or 0,
    }
end

--- 扫描耗时摘要（按总耗时降序）：诊断 perf 报告用，用来定位“哪个容器最慢”
function Containers:scanStatsSummary(limit)
    local out = {}
    for _, bucket in pairs(self.scanStats) do
        out[#out + 1] = bucket
    end
    table.sort(out, function(a, b)
        if a.total ~= b.total then
            return a.total > b.total
        end
        return tostring(a.name) < tostring(b.name)
    end)
    limit = tonumber(limit) or 12
    local trimmed = {}
    for index = 1, math.min(#out, limit) do
        trimmed[#trimmed + 1] = out[index]
    end
    return trimmed
end



--- ===== 快照 API（1.7.0）=====
--- 推进"调度轮次"计数（主控每个调度轮次调一次）。模型新鲜度按轮次衡量，
function Containers:advanceTick()
    self.tickCount = (self.tickCount or 0) + 1
    --- 在飞记录兜底清理：超过 MOVE_RECORD_TTL 还没结算的（worker 结果丢了 / 调用方不再来问）
    --- → 按"一个也没搬走"结算（预留归还），真实内容由下一次扫描做权威纠正。
    local now = os.epoch("utc")
    for key, record in pairs(self.moveInflight) do
        if now - (record.at or now) > MOVE_RECORD_TTL then
            self:settleMove(record, 0)
            self.moveInflight[key] = nil
            self.moveSwept = (self.moveSwept or 0) + 1
        end
    end
end

--- 这个容器需要重扫吗：没扫过、或距上次扫描已经超过 maxAgeTicks 轮
function Containers:needsScan(peripheralName, maxAgeTicks)
    local model = self.model[peripheralName]
    if not model or (model.scans or 0) == 0 then
        return true
    end
    return ((self.tickCount or 0) - (model.tick or 0)) >= (tonumber(maxAgeTicks) or 20)
end

--- 取某个外设的内容模型（没有就建一个空模型：还没扫过 → 可见值为空）
function Containers:modelOf(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil
    end
    local model = self.model[peripheralName]
    if not model then
        model = { slots = {}, tanks = {}, pendSlots = {}, pendTanks = {}, gen = 0, stamp = 0, scans = 0 }
        self.model[peripheralName] = model
    end
    return model
end

--- 某个槽位/储罐的乐观变更合计（出库是负数、入库是正数）
local function pendingDelta(map, index)
    local list = map[index]
    if not list then
        return 0
    end
    local total = 0
    for i = 1, #list do
        total = total + (tonumber(list[i].delta) or 0)
    end
    return total
end

--- 记一条乐观变更。settleAt = nil 表示"还在飞"；有 settleAt 表示已经结算过
--- （下一次在它之后发生的扫描会把它丢掉：那次扫描已经反映了它的效果）
local function addPending(map, index, delta, settleAt, name, nbt)
    local list = map[index]
    if not list then
        list = {}
        map[index] = list
    end
    list[#list + 1] = { delta = delta, settleAt = settleAt, name = name, nbt = nbt }
end

--- 某个槽位的可见数量（基准 + 乐观变更；不小于 0）
function Containers:visibleSlotCount(model, slot)
    if not model then
        return 0
    end
    local entry = model.slots[slot]
    local base = entry and (tonumber(entry.count) or 0) or 0
    local value = base + pendingDelta(model.pendSlots, slot)
    if value < 0 then
        value = 0
    end
    return value
end

--- 某个储罐的可见容量（基准 + 乐观变更；不小于 0）
function Containers:visibleTankAmount(model, tank)
    if not model then
        return 0
    end
    local entry = model.tanks[tank]
    local base = entry and (tonumber(entry.amount) or 0) or 0
    local value = base + pendingDelta(model.pendTanks, tank)
    if value < 0 then
        value = 0
    end
    return value
end

--- 可见的物品槽位表：{ [slot] = { name, count, nbt } }（只列可见值 > 0 的槽位）
function Containers:visibleSlots(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for slot, entry in pairs(model.slots) do
        local count = self:visibleSlotCount(model, slot)
        if count > 0 and entry and entry.name then
            out[slot] = { name = entry.name, count = count, nbt = entry.nbt }
        end
    end
    -- 基准里没有、但有正向乐观变更的槽位（刚入库、还没扫描到）：也要能被看见
    for slot, list in pairs(model.pendSlots) do
        if not out[slot] and self:visibleSlotCount(model, slot) > 0 then
            for i = #list, 1, -1 do
                if list[i].name then
                    out[slot] = { name = list[i].name, count = self:visibleSlotCount(model, slot),
                        nbt = list[i].nbt }
                    break
                end
            end
        end
    end
    return out
end

--- 可见的流体罐表：{ [tank] = { name, amount } }
function Containers:visibleTanks(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for tank, entry in pairs(model.tanks) do
        local amount = self:visibleTankAmount(model, tank)
        if amount > 0 and entry and entry.name then
            out[tank] = { name = entry.name, amount = amount }
        end
    end
    for tank, list in pairs(model.pendTanks) do
        if not out[tank] and self:visibleTankAmount(model, tank) > 0 then
            for i = #list, 1, -1 do
                if list[i].name then
                    out[tank] = { name = list[i].name, amount = self:visibleTankAmount(model, tank) }
                    break
                end
            end
        end
    end
    return out
end

--- 出库预留：派任务之前按可见值扣掉（返回真正预留的数量，可能是 0）。
--- 不做"目标是否可用"的前置检查（存储内容基本只受 IFM 控制，回滚极少见）。
function Containers:reserveOut(peripheralName, index, want, kind)
    local model = self:modelOf(peripheralName)
    if not model then
        return 0
    end
    local fluid = kind == "fluid"
    local visible = fluid and self:visibleTankAmount(model, index) or self:visibleSlotCount(model, index)
    local amount = math.max(0, math.min(tonumber(want) or 0, visible))
    if amount <= 0 then
        return 0
    end
    local entry = fluid and model.tanks[index] or model.slots[index]
    addPending(fluid and model.pendTanks or model.pendSlots, index, -amount, nil,
        entry and entry.name or nil, entry and entry.nbt or nil)
    return amount
end

--- 结算一条搬运：出库侧的乐观变更从 -reserved 改成 -moved（差额归还），入库侧 +moved。
--- settleAt = 结算时间：之后发生的扫描会把这条变更丢掉（扫描已经反映了它的效果）。
function Containers:settleMove(request, moved)
    if type(request) ~= "table" then
        return
    end
    local now = os.epoch("utc")
    local movedCount = math.max(0, tonumber(moved) or 0)
    local fluid = request.kind == "fluid"
    local fromModel = self:modelOf(request.from)
    if fromModel and request.fromIndex then
        local map = fluid and fromModel.pendTanks or fromModel.pendSlots
        --- 结算"就地改写那条在飞预留"：reserveOut 记的是 -reserved，
        --- 改成 -moved 之后可见值立刻是 base - moved；再把 settleAt 打上时间戳，
        --- 这样之后开始的那次扫描会把它整条丢掉（扫描已经反映了真实结果）。
        local target = nil
        local list = map[request.fromIndex]
        local want = -(tonumber(request.reserved) or 0)
        for i = 1, #(list or {}) do
            local entry = list[i]
            if entry.settleAt == nil and (tonumber(entry.delta) or 0) == want then
                target = entry
                break
            end
        end
        if target then
            target.delta = -movedCount
            target.settleAt = now
        else
            --- 找不到对应的在飞预留（调用方没先预留 / 预留被兜底清理过）：补一条净额
            addPending(map, request.fromIndex, (tonumber(request.reserved) or 0) - movedCount, now)
        end
    end
    local toModel = self:modelOf(request.to)
    if toModel and request.toIndex and movedCount > 0 then
        addPending(fluid and toModel.pendTanks or toModel.pendSlots, request.toIndex,
            movedCount, now, request.item, request.nbt)
    end
    self.moveSettleCount = (self.moveSettleCount or 0) + 1
end

--- 扫描结果是权威基准：写入 slots/tanks（nil 表示这次没扫这一类，保持原样），
--- 并把"已经结算过、而且结算发生在这次扫描开始之前"的乐观变更丢掉。
--- 顺便把"扫描时看到过的物品"记进 self.scanSeen（生成器据此补物品详情任务）。
function Containers:applyScan(peripheralName, items, tanks, scanStartedAt)
    local model = self:modelOf(peripheralName)
    if not model then
        return false
    end
    local started = tonumber(scanStartedAt) or os.epoch("utc")
    model.scans = (model.scans or 0) + 1
    model.stamp = os.epoch("utc")
    model.gen = (model.gen or 0) + 1
    model.tick = self.tickCount or 0
    if items ~= nil then
        local slots = {}
        for _, entry in ipairs(items) do
            local slot = tonumber(entry and entry.slot)
            if slot and type(entry.name) == "string" and entry.name ~= "" then
                slots[slot] = { name = entry.name, count = tonumber(entry.count) or 0, nbt = entry.nbt }
                if #self.scanSeen < 512 then
                    --- 带上容器与槽位：detail 队列拿它去 getItemDetail（一步一次、失败丢弃）
                    self.scanSeen[#self.scanSeen + 1] = { name = entry.name, nbt = entry.nbt,
                        container = peripheralName, slot = slot }
                end
            end
        end
        model.slots = slots
    end
    if tanks ~= nil then
        local tanksOut = {}
        for _, entry in ipairs(tanks) do
            local tank = tonumber(entry and entry.tank) or tonumber(entry and entry.slot)
            if tank and type(entry.name) == "string" and entry.name ~= "" then
                tanksOut[tank] = { name = entry.name, amount = tonumber(entry.amount) or 0 }
            end
        end
        model.tanks = tanksOut
    end
    local function prune(map)
        for index, list in pairs(map) do
            local keep = {}
            for i = 1, #list do
                local entry = list[i]
                if not entry.settleAt or entry.settleAt >= started then
                    keep[#keep + 1] = entry
                end
            end
            if #keep == 0 then
                map[index] = nil
            else
                map[index] = keep
            end
        end
    end
    prune(model.pendSlots)
    prune(model.pendTanks)
    return true
end

--- 快照统计（诊断用）：未结算的乐观变更 / 已结算 / 被兜底清理 / 在飞搬运 / 待领取结果
function Containers:snapshotSummary()
    local pending = 0
    local containersWithPending = 0
    for _, model in pairs(self.model) do
        local has = false
        for _ in pairs(model.pendSlots) do
            pending = pending + 1
            has = true
        end
        for _ in pairs(model.pendTanks) do
            pending = pending + 1
            has = true
        end
        if has then
            containersWithPending = containersWithPending + 1
        end
    end
    local function count(map)
        local total = 0
        for _ in pairs(map or {}) do
            total = total + 1
        end
        return total
    end
    return {
        pending = pending,
        pendingContainers = containersWithPending,
        settled = self.moveSettleCount or 0,
        swept = self.moveSwept or 0,
        inflight = count(self.moveInflight),
        results = count(self.moveResults),
        models = count(self.model),
        detailDeferred = self.detailDeferred or 0,
    }
end

--- 取走"扫描时看到过的物品"（生成器用：给还没有详情的物品补 detail 任务）--- 取走"扫描时看到过的物品"（生成器用：给还没有详情的物品补 detail 任务）
function Containers:takeScanSeen()
    local seen = self.scanSeen
    self.scanSeen = {}
    return seen
end

--- 本机真读一次容器内容（list + tanks）→ 写进快照。返回是否有任何一次读取成功。
--- worker 代读由 Transfer:submitScan 派活，结果经 Transfer:onScanResult 回到 applyScan。
function Containers:scanNow(peripheralName)
    local startedAt = os.epoch("utc")
    local readAny = false
    if self.Peripherals and self.Peripherals:isInventory(peripheralName) then
        local inv = self:inventory(peripheralName)
        if inv and type(inv.list) == "function" then
            local ok, listed = pcall(inv.list)
            noteScan(self, peripheralName, "list", startedAt)
            if ok and type(listed) == "table" then
                local items = {}
                for slot, stack in pairs(listed) do
                    if type(stack) == "table" and stack.name then
                        items[#items + 1] = { slot = tonumber(slot) or slot, name = stack.name,
                            count = tonumber(stack.count) or 0, nbt = stack.nbt }
                    end
                end
                self:applyScan(peripheralName, items, nil, startedAt)
                readAny = true
            else
                self.Peripherals:invalidate(peripheralName)
            end
        end
    end
    if self.Peripherals and self.Peripherals:isFluid(peripheralName) then
        local storage = self:fluidStorage(peripheralName)
        if storage and type(storage.tanks) == "function" then
            local ok, listed = pcall(storage.tanks)
            noteScan(self, peripheralName, "tanks", startedAt)
            if ok and type(listed) == "table" then
                local tanks = {}
                for index, tank in pairs(listed) do
                    if type(tank) == "table" and tank.name then
                        tanks[#tanks + 1] = { tank = tonumber(index) or index, name = tank.name,
                            amount = tonumber(tank.amount) or 0 }
                    end
                end
                self:applyScan(peripheralName, nil, tanks, startedAt)
                readAny = true
            else
                self.Peripherals:invalidate(peripheralName)
            end
        end
    end
    return readAny
end









function Containers:listPeripheral(peripheralName)


    return self:visibleSlots(peripheralName)
end


function Containers:stacksPeripheral(peripheralName)
    local listed = self:listPeripheral(peripheralName)
    local out = {}
    for slot, stack in pairs(listed) do
        if type(stack) == "table" and stack.name then
            out[#out + 1] = {
                slot = slot,
                name = stack.name,
                count = tonumber(stack.count) or 0,
                nbt = stack.nbt,
            }
        end
    end
    table.sort(out, function(a, b)
        return a.slot < b.slot
    end)
    return out
end

function Containers:tanksPeripheral(peripheralName)

    local out = {}
    local visible = self:visibleTanks(peripheralName)
    for tank, entry in pairs(visible) do
        out[#out + 1] = { tank = tonumber(tank) or tank, name = entry.name, amount = entry.amount }
    end
    table.sort(out, function(a, b)
        return a.tank < b.tank
    end)
    return out
end


function Containers:stacks(containerName)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return {}
    end
    return self:stacksPeripheral(peripheralName)
end


function Containers:tanks(containerName)
    local peripheralName = self:peripheralOf(containerName, "fluid")
    if not peripheralName then
        return {}
    end
    return self:tanksPeripheral(peripheralName)
end






function Containers:setDispatcher(dispatch)
    self.dispatch = dispatch
end


function Containers:setTransferProvider(provider)
    self.transfer = provider
end




function Containers:submitMove(record, queueName)
    if not record or not record.key then
        return
    end
    self.moveInflight[record.key] = record
    record.state = "queued"
    record.at = os.epoch("utc")
    if self.dispatch and self.dispatch.enqueue then
        if self.dispatch:enqueue(queueName or "inventoryOut", record) then
            return
        end

        return
    end
    self:executeMove(record)
end





--- 源侧是不是"确实没材料了"（可见数量已经是 0）。
--- 用户第 3 项要求：出库任务失败时只有这种情况才丢弃；其它失败（目标容器限速 / 暂时满了 /
--- 外设报错）都要把剩余未完成的数量放回队尾重试。
function Containers:sourceShortage(record)
    local model = self:modelOf(record.from)
    if not model then
        return true                            -- 源外设都没了：当作没得搬
    end
    if record.kind == "fluid" then
        return self:visibleTankAmount(model, record.fromIndex) <= 0
    end
    return self:visibleSlotCount(model, record.fromIndex) <= 0
end

function Containers:executeMove(record)
    if type(record) ~= "table" or not record.key then
        return "drop"
    end
    if self.moveInflight[record.key] ~= record then
        return false
    end
    local moved, err = self:runMoveTask(record)
    if err == "pending" then
        record.state = "inflight"
        return true
    end
    local value = tonumber(moved) or 0
    self:settleMove(record, value)
    self.moveInflight[record.key] = nil
    self.dirty[record.from] = true
    self.dirty[record.to] = true
    self.moveResults = self.moveResults or {}
    self.moveResults[record.key] = { moved = value, err = (value > 0) and nil or err, at = os.epoch("utc") }
    local wanted = tonumber(record.reserved) or 0
    if value >= wanted then
        return false                           -- 搬完了
    end
    --- 没搬完（或者一个都没搬动）：区分"源侧没材料"与"其它失败"（用户第 3 项要求）
    if value <= 0 and self:sourceShortage(record) then
        self.log("Move dropped (source empty) (%s -> %s): %s", tostring(record.from), tostring(record.to),
            tostring(err or "nothing moved"))
        return "drop"
    end
    --- 其它失败（输出容器有限速 / 暂时满了 / 外设忙 / 报错）：把剩余部分放回队尾重试。
    --- 重新预留剩余量：预留不到（可见量已经变成 0）才认定为材料不足、丢弃。
    local remaining = math.max(0, wanted - value)
    if remaining <= 0 then
        return false
    end
    local again = self:reserveOut(record.from, record.fromIndex, remaining,
        record.kind == "fluid" and "fluid" or "item")
    if again <= 0 then
        self.log("Move dropped (no visible source left) (%s -> %s): %s", tostring(record.from),
            tostring(record.to), tostring(err or "nothing moved"))
        return "drop"
    end
    record.reserved = again
    record.retries = (record.retries or 0) + 1
    record.state = "queued"
    self.moveInflight[record.key] = record        -- 继续算"在飞"：下次执行还走这条记录
    self.log("Move retry %d/%d (%s -> %s, moved=%d): %s", again, remaining,
        tostring(record.from), tostring(record.to), value, tostring(err or "target busy"))
    return true                                   -- 调度器把任务放回队尾（policy=retry）
end


function Containers:runMoveTask(record)
    if record.kind == "fluid" then
        return self:runFluidMove(record)
    end
    return self:runItemMove(record)
end


function Containers:takeMoveResult(key)
    if not key or not self.moveResults then
        return nil
    end
    local result = self.moveResults[key]
    if result then
        self.moveResults[key] = nil
    end
    return result
end














function Containers:pushItem(fromContainer, fromSlot, limit, toContainer, toSlot, mode, queueName)
    local fromPeripheral = self:peripheralOf(fromContainer, "item")
    local toPeripheral = self:peripheralOf(toContainer, "item")
    if not fromPeripheral then
        return 0, self:unusableReason(fromContainer, "item") or ("\\u6765\\u6E90\\u5BB9\\u5668 " .. tostring(fromContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    if not toPeripheral then
        return 0, self:unusableReason(toContainer, "item") or ("\\u76EE\\u6807\\u5BB9\\u5668 " .. tostring(toContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, "\\u6570\\u91CF\\u5FC5\\u987B\\u5927\\u4E8E 0"
    end
    local explicitSlot = (tonumber(toSlot) or -1) >= 1 and tonumber(toSlot) or nil
    local autoSlot = nil
    if not explicitSlot and mode and fromPeripheral ~= toPeripheral then
        local source = self:stackAt(fromContainer, fromSlot)
        if source and source.name then
            autoSlot = self:insertSlotFor(toContainer, source.name, source.nbt, limit, mode)
        end
    end
    local chosenSlot = explicitSlot or autoSlot
    local wantsSlot = chosenSlot ~= nil and chosenSlot ~= fromSlot
    if fromPeripheral == toPeripheral and not wantsSlot then
        return 0, samePeripheralReason(fromContainer, toContainer, fromPeripheral)
    end
    local key = table.concat({ "item", fromPeripheral, tostring(fromSlot), tostring(limit),
        toPeripheral, tostring(chosenSlot or -1) }, "|")
    local result = self:takeMoveResult(key)
    if result then
        return result.moved, result.err
    end
    if self.moveInflight[key] then
        return nil, "pending"
    end
    local source = self:stackAt(fromContainer, fromSlot)
    local visible = source and (tonumber(source.count) or 0) or 0
    local reserved = self:reserveOut(fromPeripheral, fromSlot, math.min(limit, visible), "item")
    if reserved <= 0 then
        return 0, "\\u6E90\\u69FD\\u4F4D\\u6CA1\\u6709\\u53EF\\u642C\\u7684\\u7269\\u54C1"
    end
    local record = {
        key = key, kind = "item", action = "push_item",
        from = fromPeripheral, fromIndex = fromSlot, to = toPeripheral, toIndex = chosenSlot,
        reserved = reserved, limit = limit, mode = mode,
        item = source and source.name or nil, nbt = source and source.nbt or nil,
    }
    self:submitMove(record, queueName)
    return nil, "pending"
end



function Containers:runItemMove(record)
    local fromPeripheral = record.from
    local toPeripheral = record.to
    local fromSlot = record.fromIndex
    local limit = record.reserved
    local chosenSlot = record.toIndex
    if self.transfer then
        local state, moved, err = self.transfer:request({
            action = "push_item",
            from = fromPeripheral,
            fromSlot = fromSlot,
            limit = limit,
            to = toPeripheral,
            toSlot = (tonumber(chosenSlot) or -1) >= 1 and chosenSlot or nil,
        })
        if state == "pending" then
            return nil, "pending"
        end
        if state == "done" and (tonumber(moved) or 0) > 0 then
            return moved, err
        end
        if state == "done" and chosenSlot and chosenSlot ~= fromSlot then

            local retryState, retryMoved, retryErr = self.transfer:request({
                action = "push_item", from = fromPeripheral, fromSlot = fromSlot,
                limit = limit, to = toPeripheral, toSlot = nil,
            })
            if retryState == "pending" then
                return nil, "pending"
            end
            if (tonumber(retryMoved) or 0) > 0 then
                record.toIndex = nil
                return retryMoved, nil
            end
            return moved, retryErr or err
        end
        return moved, err
    end
    local inv = self:inventory(fromPeripheral)
    if not inv then
        return 0, "\\u6765\\u6E90 " .. tostring(fromPeripheral) .. " \\u4E0D\\u662F\\u7269\\u54C1\\u5BB9\\u5668"
    end
    local targetSlot = (tonumber(chosenSlot) or -1) >= 1 and chosenSlot or nil
    local ok, moved = pcall(inv.pushItems, toPeripheral, fromSlot, limit, targetSlot)
    if ok and type(moved) == "number" and moved > 0 then
        return moved
    end
    if not ok then
        self.Peripherals:invalidate(fromPeripheral)
        self.Peripherals:invalidate(toPeripheral)
    end
    local targetInv = self:inventory(toPeripheral)
    if targetInv then
        local ok2, moved2 = pcall(targetInv.pullItems, fromPeripheral, fromSlot, limit, targetSlot)
        if ok2 and type(moved2) == "number" and moved2 > 0 then
            return moved2
        end
    end
    if ok and targetSlot and targetSlot ~= fromSlot then
        local ok3, moved3 = pcall(inv.pushItems, toPeripheral, fromSlot, limit, nil)
        if ok3 and type(moved3) == "number" and moved3 > 0 then
            record.toIndex = nil
            return moved3
        end
    end
    if ok then
        return 0, "\\u672A\\u80FD\\u642C\\u8FD0\\u4EFB\\u4F55\\u7269\\u54C1"
    end
    return 0, tostring(moved)
end








Containers.ORDER_SPEED = "speed"
Containers.ORDER_FRAGMENT = "fragment"
Containers.INSERT_SPEED = "speed"
Containers.INSERT_LEAST = "leastWaste"


function Containers:orderStacks(list, order)
    local out = {}
    for index, entry in ipairs(list or {}) do
        out[index] = entry
    end
    if order ~= Containers.ORDER_SPEED and order ~= Containers.ORDER_FRAGMENT then
        return out
    end
    table.sort(out, function(a, b)
        local ca = tonumber(a and (a.count or a.amount)) or 0
        local cb = tonumber(b and (b.count or b.amount)) or 0
        if ca ~= cb then
            if order == Containers.ORDER_SPEED then
                return ca > cb
            end
            return ca < cb
        end

        if tostring(a and a.container) ~= tostring(b and b.container) then
            return tostring(a and a.container) < tostring(b and b.container)
        end
        return (tonumber(a and (a.slot or a.tank)) or 0) < (tonumber(b and (b.slot or b.tank)) or 0)
    end)
    return out
end



function Containers:itemMaxCount(itemName, nbt)
    if type(itemName) ~= "string" or itemName == "" then
        return DEFAULT_ITEM_MAX_COUNT
    end
    local known = self.itemMaxCountCache and self.itemMaxCountCache[itemName]
    if known then
        return known
    end
    local detail, cached = self:cachedItemDetail(itemName, nbt)
    if cached then
        local value = tonumber(detail and detail.maxCount) or DEFAULT_ITEM_MAX_COUNT
        if value <= 0 then
            value = DEFAULT_ITEM_MAX_COUNT
        end
        self.itemMaxCountCache = self.itemMaxCountCache or {}
        self.itemMaxCountCache[itemName] = value
        return value
    end
    return DEFAULT_ITEM_MAX_COUNT
end



function Containers:insertSlotFor(containerName, itemName, nbt, amount, mode)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil
    end
    local size = self:slotCount(peripheralName)
    if not size or size <= 0 then
        return nil
    end
    local slots = self:stacksPeripheral(peripheralName)

    local bySlot = {}
    for _, entry in ipairs(slots or {}) do
        local index = tonumber(entry and entry.slot)
        if index then
            bySlot[index] = entry
        end
    end
    local capacity = self:itemMaxCount(itemName, nbt)
    amount = math.max(1, tonumber(amount) or 1)
    local sameSlot, sameFree
    local fitsSlot, fitsFree
    local roomSlot, roomFree
    for slot = 1, size do
        local stack = bySlot[slot]
        local free = nil
        local same = false
        if stack == nil then
            free = capacity
        elseif tostring(stack.name) == tostring(itemName) and tostring(stack.nbt or "") == tostring(nbt or "") then
            free = math.max(0, capacity - (tonumber(stack.count) or 0))
            same = true
        end
        if free and free > 0 then
            if same and (sameFree == nil or free < sameFree) then
                sameSlot, sameFree = slot, free
            end
            if free >= amount and (fitsFree == nil or free < fitsFree) then
                fitsSlot, fitsFree = slot, free
            end
            if roomFree == nil or free > roomFree then
                roomSlot, roomFree = slot, free
            end
        end
    end
    if mode == Containers.INSERT_LEAST then

        if sameSlot then
            return sameSlot
        end
        if fitsSlot then
            return fitsSlot
        end
        return roomSlot
    end

    if fitsSlot then
        return fitsSlot
    end
    return roomSlot
end




function Containers:pushFluid(fromContainer, limit, fluidName, toContainer, queueName)
    local fromPeripheral = self:peripheralOf(fromContainer, "fluid")
    local toPeripheral = self:peripheralOf(toContainer, "fluid")
    if not fromPeripheral then
        return 0, self:unusableReason(fromContainer, "fluid") or ("\\u6765\\u6E90\\u5BB9\\u5668 " .. tostring(fromContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    if not toPeripheral then
        return 0, self:unusableReason(toContainer, "fluid") or ("\\u76EE\\u6807\\u5BB9\\u5668 " .. tostring(toContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    if fromPeripheral == toPeripheral then
        return 0, samePeripheralReason(fromContainer, toContainer, fromPeripheral)
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, "\\u6570\\u91CF\\u5FC5\\u987B\\u5927\\u4E8E 0"
    end
    local key = table.concat({ "fluid", fromPeripheral, toPeripheral, tostring(fluidName or "") }, "|")
    local result = self:takeMoveResult(key)
    if result then
        return result.moved, result.err
    end
    if self.moveInflight[key] then
        return nil, "pending"
    end

    local visible = self:visibleTanks(fromPeripheral)
    local bestTank, bestAmount = nil, 0
    for tank, entry in pairs(visible) do
        if entry.name == fluidName and entry.amount > bestAmount then
            bestTank, bestAmount = tank, entry.amount
        end
    end
    if not bestTank or bestAmount <= 0 then
        return 0, "\\u6E90\\u5BB9\\u5668\\u91CC\\u6CA1\\u6709\\u8FD9\\u79CD\\u6D41\\u4F53"
    end
    local reserved = self:reserveOut(fromPeripheral, bestTank, math.min(limit, bestAmount), "fluid")
    if reserved <= 0 then
        return 0, "\\u6E90\\u5BB9\\u5668\\u91CC\\u6CA1\\u6709\\u8FD9\\u79CD\\u6D41\\u4F53"
    end
    local record = {
        key = key, kind = "fluid", action = "push_fluid",
        from = fromPeripheral, fromIndex = bestTank, to = toPeripheral, toIndex = nil,
        reserved = reserved, limit = limit, item = fluidName,
    }
    self:submitMove(record, queueName)
    return nil, "pending"
end


function Containers:runFluidMove(record)
    local fromPeripheral = record.from
    local toPeripheral = record.to
    local fluidName = record.item
    local limit = record.reserved
    if self.transfer then
        local state, moved, err = self.transfer:request({
            action = "push_fluid",
            from = fromPeripheral,
            limit = limit,
            fluid = fluidName,
            to = toPeripheral,
        })
        if state == "pending" then
            return nil, "pending"
        elseif state == "done" then
            return moved, err
        end
    end
    local storage = self:fluidStorage(fromPeripheral)
    if not storage then
        return 0, "\\u6765\\u6E90 " .. tostring(fromPeripheral) .. " \\u4E0D\\u662F\\u6D41\\u4F53\\u5BB9\\u5668"
    end
    local ok, moved = pcall(storage.pushFluid, toPeripheral, limit, fluidName)
    if ok and type(moved) == "number" and moved > 0 then
        return moved
    end
    if not ok then
        self.Peripherals:invalidate(fromPeripheral)
        self.Peripherals:invalidate(toPeripheral)
    end
    local targetStorage = self:fluidStorage(toPeripheral)
    if targetStorage then
        local ok2, moved2 = pcall(targetStorage.pullFluid, fromPeripheral, limit, fluidName)
        if ok2 and type(moved2) == "number" and moved2 > 0 then
            return moved2
        end
    end
    if ok then
        return 0, "\\u672A\\u80FD\\u642C\\u8FD0\\u4EFB\\u4F55\\u6D41\\u4F53"
    end
    return 0, tostring(moved)
end















local function itemDetailKey(itemName, nbt)
    return tostring(itemName) .. "\1" .. tostring(nbt or "")
end




function Containers:cachedItemDetail(itemName, nbt)
    if type(itemName) ~= "string" or itemName == "" then
        return nil, false
    end
    local entry = self.detailCache[itemDetailKey(itemName, nbt)]
    if not entry then
        return nil, false
    end
    if os.epoch("utc") - (entry.stamp or 0) >= self.detailTtl then
        return nil, false
    end
    return entry.detail, true
end


function Containers:itemDetail(itemName, nbt)
    local detail, known = self:cachedItemDetail(itemName, nbt)
    if not known then
        return nil
    end
    return detail
end



function Containers:setItemDetail(itemName, nbt, detail, source)
    if type(itemName) ~= "string" or itemName == "" then
        return false
    end
    if type(detail) ~= "table" then
        detail = nil
    end
    self.detailCache[itemDetailKey(itemName, nbt)] = {
        detail = detail,
        hit = detail ~= nil,
        stamp = os.epoch("utc"),
        source = source,
    }

    if self.detailInFlight then
        self.detailInFlight[itemDetailKey(itemName, nbt)] = nil
    end
    return true
end





function Containers:absorbItemDetails(entries)
    local taken, fresh = 0, {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local name = type(entry) == "table" and entry.name or nil
        local detail = type(entry) == "table" and entry.detail or nil
        if type(name) == "string" and name ~= "" and type(detail) == "table" and
            (detail.name == nil or detail.name == name) then
            self:setItemDetail(name, entry.nbt, detail, "worker")

            if self.detailInFlight then
                self.detailInFlight[itemDetailKey(name, entry.nbt)] = nil
            end
            taken = taken + 1
            fresh[#fresh + 1] = name
        end
    end
    return taken, fresh
end





function Containers:detail(peripheralName, slot, opts)
    opts = opts or {}
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil
    end
    slot = tonumber(slot) or slot
    if slot == nil then
        return nil
    end
    local inv = self:inventory(peripheralName)
    local detail = nil
    if inv and type(inv.getItemDetail) == "function" then
        local ok, value = pcall(inv.getItemDetail, slot)
        if ok and type(value) == "table" then
            detail = value
        end
    end
    self.localDetailCalls = (self.localDetailCalls or 0) + 1
    local wantName = type(opts.name) == "string" and opts.name ~= "" and opts.name or nil
    if wantName then
        if detail and detail.name == wantName then
            self:setItemDetail(wantName, opts.nbt, detail, "local")
        elseif detail == nil then

            self:setItemDetail(wantName, opts.nbt, nil, "local")
        end


    end
    return detail
end




local DETAIL_IN_FLIGHT_TTL = 10000


function Containers:detailsInFlight(itemName, nbt)
    if type(itemName) ~= "string" or itemName == "" then
        return false
    end
    self.detailInFlight = self.detailInFlight or {}
    local at = self.detailInFlight[itemDetailKey(itemName, nbt)]
    if not at then
        return false
    end
    if os.epoch("utc") - at >= DETAIL_IN_FLIGHT_TTL then

        self.detailInFlight[itemDetailKey(itemName, nbt)] = nil
        return false
    end
    return true
end







function Containers:requestItemDetails(samples)
    if type(samples) ~= "table" or #samples == 0 then
        return "local"
    end
    if not self.detailProvider or type(self.detailProvider.detailRequest) ~= "function" then
        return "local"
    end
    local fresh = {}
    for _, sample in ipairs(samples) do
        if type(sample) == "table" and type(sample.name) == "string" and sample.name ~= "" and
            not self:detailsInFlight(sample.name, sample.nbt) then
            fresh[#fresh + 1] = sample
        end
    end
    if #fresh == 0 then

        return "pending"
    end
    local ok, state = pcall(self.detailProvider.detailRequest, self.detailProvider, fresh)
    if not ok then
        return "local"
    end
    state = state or "local"
    if state == "pending" then
        self.detailInFlight = self.detailInFlight or {}
        local now = os.epoch("utc")
        for _, sample in ipairs(fresh) do
            self.detailInFlight[itemDetailKey(sample.name, sample.nbt)] = now
        end
    end
    return state
end



function Containers:setDetailProvider(provider)
    self.detailProvider = provider
end



function Containers:collectStacks(role)
    local out = {}
    for _, containerName in ipairs(self:byRole(role, "item", "in")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName then
            for _, stack in ipairs(self:stacksPeripheral(peripheralName)) do
                out[#out + 1] = {
                    container = containerName,
                    peripheral = peripheralName,
                    slot = stack.slot,
                    name = stack.name,
                    count = stack.count,
                    nbt = stack.nbt,
                }
            end
        end
    end
    return out
end



function Containers:collectTanks(role)
    local out = {}
    for _, containerName in ipairs(self:byRole(role, "fluid", "in")) do
        local peripheralName = self:peripheralOf(containerName, "fluid")
        if peripheralName then
            for _, tank in ipairs(self:tanksPeripheral(peripheralName)) do
                out[#out + 1] = {
                    container = containerName,
                    peripheral = peripheralName,
                    tank = tank.tank,
                    name = tank.name,
                    amount = tank.amount,
                }
            end
        end
    end
    return out
end





function Containers:snapshot(role)
    role = role or "storage"
    local now = os.epoch("utc")
    local cached = self.snapshots[role]
    if cached and cached.value and now - cached.stamp < self.cacheTtl then
        return cached.value
    end
    local stacks = self:collectStacks(role)
    local tanks = self:collectTanks(role)
    local totals = {}
    for _, stack in ipairs(stacks) do
        local key = "item:" .. stack.name
        totals[key] = (totals[key] or 0) + stack.count
    end
    for _, tank in ipairs(tanks) do
        local key = "fluid:" .. tank.name
        totals[key] = (totals[key] or 0) + tank.amount
    end
    local value = {
        stacks = stacks,
        tanks = tanks,
        totals = totals,
    }
    self.snapshots[role] = { stamp = now, value = value }
    return value
end






function Containers:invalidate()
    for name in pairs(self.dirty) do
        local model = self.model[name]
        if model then

            model.tick = -1
        end
    end
    self.dirty = {}

    self.snapshots = {}
end


function Containers:invalidateAll()
    self.snapshots = {}
    self.model = {}
    self.moveRequests = {}

    self.moveInflight = {}
    self.scanSeen = {}

    self.detailCache = {}
    self.detailInFlight = {}
    self.peripheralCountValue = nil
    self.peripheralCountAt = nil
end




function Containers:matchSpec(spec, role, order)
    role = role or "storage"
    local snapshot = self:snapshot(role)
    local items, fluids = {}, {}
    if spec.kind ~= "fluid" then
        for _, stack in ipairs(snapshot.stacks) do
            local resource = { kind = "item", name = stack.name, nbt = stack.nbt }
            if self.Filter:specMatches(spec, resource) then
                items[#items + 1] = stack
            end
        end
    end
    if spec.kind ~= "item" then
        for _, tank in ipairs(snapshot.tanks) do
            local resource = { kind = "fluid", name = tank.name }
            if self.Filter:specMatches(spec, resource) then
                fluids[#fluids + 1] = tank
            end
        end
    end
    return self:orderStacks(items, order), self:orderStacks(fluids, order)
end




function Containers:countOf(spec, role)
    role = role or "storage"
    if type(spec) == "table" and (spec.kind == "item" or spec.kind == "fluid")
        and spec.id and spec.ignoreNbt ~= false then
        local snapshot = self:snapshot(role)
        local totals = snapshot.totals
        if totals then
            return totals[spec.kind .. ":" .. spec.id] or 0
        end
    end
    local items, fluids = self:matchSpec(spec, role)
    local total = 0
    for _, stack in ipairs(items) do
        total = total + stack.count
    end
    for _, tank in ipairs(fluids) do
        total = total + tank.amount
    end
    return total, items, fluids
end


function Containers:countIn(containerName, spec)
    local total = 0
    for _, stack in ipairs(self:stacks(containerName)) do
        if self.Filter:specMatches(spec, { kind = "item", name = stack.name, nbt = stack.nbt }) then
            total = total + stack.count
        end
    end
    for _, tank in ipairs(self:tanks(containerName)) do
        if self.Filter:specMatches(spec, { kind = "fluid", name = tank.name }) then
            total = total + tank.amount
        end
    end
    return total
end


function Containers:resources()
    local snapshot = self:snapshot("storage")
    local grouped = {}
    for _, stack in ipairs(snapshot.stacks) do
        local key = "item:" .. stack.name
        local entry = grouped[key]
        if not entry then
            entry = { kind = "item", name = stack.name, count = 0 }
            grouped[key] = entry
        end
        entry.count = entry.count + stack.count
    end
    for _, tank in ipairs(snapshot.tanks) do
        local key = "fluid:" .. tank.name
        local entry = grouped[key]
        if not entry then
            entry = { kind = "fluid", name = tank.name, count = 0 }
            grouped[key] = entry
        end
        entry.count = entry.count + tank.amount
    end
    local out = {}
    for _, entry in pairs(grouped) do
        out[#out + 1] = entry
    end
    return out
end


function Containers:filterResources(filterName)
    local snapshot = self:snapshot("storage")
    local out = {}
    for _, stack in ipairs(snapshot.stacks) do
        local resource = { kind = "item", name = stack.name, nbt = stack.nbt }
        if self.Filter:matches(filterName, resource) then
            out[#out + 1] = {
                kind = "item",
                name = stack.name,
                nbt = stack.nbt,
                count = stack.count,
                container = stack.container,
                slot = stack.slot,
            }
        end
    end
    for _, tank in ipairs(snapshot.tanks) do
        local resource = { kind = "fluid", name = tank.name }
        if self.Filter:matches(filterName, resource) then
            out[#out + 1] = {
                kind = "fluid",
                name = tank.name,
                count = tank.amount,
                container = tank.container,
                tank = tank.tank,
            }
        end
    end
    return out
end


function Containers:filterCount(filterName)
    local total = 0
    for _, entry in ipairs(self:filterResources(filterName)) do
        total = total + entry.count
    end
    return total
end




function Containers:slotCount(peripheralName)
    self.slotCountCache = self.slotCountCache or {}
    local now = os.epoch("utc")
    local cached = self.slotCountCache[peripheralName]
    if cached and now - cached.stamp < SLOT_COUNT_TTL then
        return cached.value
    end
    local inv = self:inventory(peripheralName)
    local size = nil

    if inv and type(inv.size) == "function" and self:chargePlanCall("size") then
        local ok, value = pcall(inv.size)
        if ok then
            size = tonumber(value)
        end
    end
    if not size or size <= 0 then
        for slot in pairs(self:listPeripheral(peripheralName)) do
            if type(slot) == "number" and slot > (size or 0) then
                size = slot
            end
        end
    end
    size = math.max(0, tonumber(size) or 0)
    if size > MAX_CONTAINER_SLOTS then
        size = MAX_CONTAINER_SLOTS
    end
    size = math.floor(size)
    if size > 0 then
        self.slotCountCache[peripheralName] = { value = size, stamp = now }
    end
    return size
end





function Containers:chargePlanCall(what)
    local planner = self.planCtx
    if not planner then
        return true
    end
    if (planner.totalCalls or 0) >= (planner.maxCalls or PLAN_MAX_CALLS) then
        return false
    end
    planner.totalCalls = (planner.totalCalls or 0) + 1
    planner.calls = (planner.calls or 0) + 1
    if planner.calls > (planner.budget or PLAN_CALLS_PER_PASS) then
        planner.yielded = what or "peripheral"
        error(PLAN_YIELD, 0)
    end
    return true
end


function Containers:compactPlanner(role, opts)
    opts = opts or {}
    return {
        role = role or "storage",
        budget = tonumber(opts.budget) or PLAN_CALLS_PER_PASS,
        maxCalls = tonumber(opts.maxCalls) or PLAN_MAX_CALLS,
        calls = 0,
        totalCalls = 0,
        passes = 0,
        stage = "scan",
        containersDone = 0,
        containersTotal = 0,
        groupsDone = 0,
        groupsTotal = 0,
    }
end








function Containers:capacityStats()
    local now = os.epoch("utc")
    local cached = self.capacityCache
    if cached and now - cached.stamp < self.capacityTtl then
        return cached.value
    end
    local stats = { items = 0, itemCapacity = 0, slots = 0, totalSlots = 0 }
    for _, containerName in ipairs(self:byRole("storage", "item")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName then
            local listed = self:listPeripheral(peripheralName)
            local items, used = 0, 0
            for _, stack in pairs(listed) do
                if type(stack) == "table" and stack.name then
                    used = used + 1
                    items = items + (tonumber(stack.count) or 0)
                end
            end
            local size = self:slotCount(peripheralName)
            stats.items = stats.items + items
            stats.slots = stats.slots + used
            stats.totalSlots = stats.totalSlots + size
            stats.itemCapacity = stats.itemCapacity + size * DEFAULT_SLOT_CAPACITY
        end
    end
    self.capacityCache = { stamp = now, value = stats }
    return stats
end


function Containers:slotName(containerName, slot)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil
    end
    local listed = self:listPeripheral(peripheralName)
    local stack = listed[slot]
    if type(stack) == "table" then
        return stack.name
    end
    return nil
end



function Containers:stackAt(containerName, slot)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil
    end
    local listed = self:listPeripheral(peripheralName)
    local stack = listed[slot]
    if type(stack) == "table" and stack.name then
        return { name = stack.name, count = tonumber(stack.count) or 0, nbt = stack.nbt }
    end
    return nil
end



















local function computeCompactPlan(self, role, planner)
    role = role or "storage"
    local now = os.epoch("utc")

    local limitBudget = MAX_SLOT_LIMIT_QUERIES
    local emptyBudget = MAX_EMPTY_SLOT_PROBES
    local detailBudget = MAX_ITEM_DETAIL_QUERIES
    self.slotUnitsCache = self.slotUnitsCache or {}
    self.itemMaxCountCache = self.itemMaxCountCache or {}
    self.emptyUnitsCache = self.emptyUnitsCache or {}

    self.itemUnitsCache = self.itemUnitsCache or {}


    local detailRequestBudget = MAX_DETAIL_REQUESTS_PER_PASS



    local function waitForDetail()
        if planner then
            planner.detailWaits = (planner.detailWaits or 0) + 1
            if planner.detailWaits <= DETAIL_WAITS_MAX then
                planner.stage = "detail"
                planner.yielded = "item detail"
                error(PLAN_YIELD, 0)
            end
        end
        return DEFAULT_ITEM_MAX_COUNT
    end






    local function maxCountOf(itemName, nbt, peripheralName, slot)
        if type(itemName) ~= "string" or itemName == "" then
            return DEFAULT_ITEM_MAX_COUNT
        end
        local known = self.itemMaxCountCache[itemName]
        if known then
            return known
        end
        local detail, cached = self:cachedItemDetail(itemName, nbt)
        if cached then
            local value = tonumber(detail and detail.maxCount) or DEFAULT_ITEM_MAX_COUNT
            if value <= 0 then
                value = DEFAULT_ITEM_MAX_COUNT
            end
            self.itemMaxCountCache[itemName] = value
            return value
        end


        self.detailDeferred = (self.detailDeferred or 0) + 1
        return DEFAULT_ITEM_MAX_COUNT
    end



    local function unitsOf(containerName, slot, stack, probing)
        local peripheralName = self:peripheralOf(containerName, "item")
        if not peripheralName then
            return 0
        end
        local key = slotUnitsKey(peripheralName, slot)
        local cached = self.slotUnitsCache[key]
        if cached and now - cached.stamp < SLOT_UNITS_TTL then
            return cached.units
        end



        local itemKey = nil
        if stack and type(stack.name) == "string" and stack.name ~= "" then
            itemKey = peripheralName .. "\1" .. stack.name
            local per = self.itemUnitsCache and self.itemUnitsCache[itemKey]
            if per and now - (per.stamp or 0) < SLOT_UNITS_TTL then
                self.slotUnitsCache[key] = { units = per.units, stamp = now }
                return per.units
            end
        end
        if probing then





            local per = self.emptyUnitsCache and self.emptyUnitsCache[peripheralName]
            if per and now - (per.stamp or 0) < SLOT_UNITS_TTL then
                self.slotUnitsCache[key] = { units = per.units, stamp = now }
                return per.units
            end
        end
        local inv = self:inventory(peripheralName)
        local limit = nil
        local budget = probing and emptyBudget or limitBudget
        local charged = self:chargePlanCall(probing and "empty-limit" or "limit")
        if inv and type(inv.getItemLimit) == "function" and budget > 0 and charged then
            if probing then
                emptyBudget = emptyBudget - 1
            else
                limitBudget = limitBudget - 1
            end
            local ok, value = pcall(inv.getItemLimit, slot)
            if ok then
                limit = tonumber(value)
                if limit and limit <= 0 then
                    limit = nil
                end
            end
        end
        if limit then
            local units
            if stack then

                local maxCount = maxCountOf(stack.name, stack.nbt, peripheralName, slot)
                units = limit * DEFAULT_ITEM_MAX_COUNT / maxCount
            else

                units = limit
            end
            units = math.max(0, math.floor(units + 0.5))
            self.slotUnitsCache[key] = { units = units, stamp = now }
            if itemKey then
                self.itemUnitsCache = self.itemUnitsCache or {}
                self.itemUnitsCache[itemKey] = { units = units, stamp = now }
            end
            if probing then

                self.emptyUnitsCache = self.emptyUnitsCache or {}
                self.emptyUnitsCache[peripheralName] = { units = units, stamp = now }
            end
            return units
        end


        return stack and math.max(0, tonumber(stack.count) or 0) or 0
    end

    local groups, order, empties = {}, {}, {}
    --- 因为"物品详情还没拿到"而被跳过的物品数（整理先跳过它们，等 detail 队列补齐）
    local planSkipped = 0
    local roleContainers = self:byRole(role, "item")
    if planner then
        planner.stage = "scan"
        planner.containersTotal = #roleContainers
        planner.containersDone = 0
    end
    for index, containerName in ipairs(roleContainers) do
        if planner then
            planner.containersDone = index - 1
        end
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName then
            local size = self:slotCount(peripheralName)
            local listed = self:listPeripheral(peripheralName)
            for slot = 1, size do
                local stack = listed[slot]
                if type(stack) == "table" and stack.name then
                    --- 详情还没有拿到的物品先不整理
                    --- 槽位容量 / 最大堆叠数都依赖 getItemDetail；拿不到就会按默认 64 算出偏大的目标，搬到一半失败。
                    --- 它们的详情由 detail 队列补齐，下一次整理就会带上它们。
                    local _, detailKnown = self:cachedItemDetail(stack.name, stack.nbt)
                    if not detailKnown then
                        self.detailDeferred = (self.detailDeferred or 0) + 1
                        planSkipped = planSkipped + 1
                    else
                    local key = tostring(stack.name) .. "\1" .. tostring(stack.nbt or "")
                    local group = groups[key]
                    if not group then
                        group = { name = stack.name, nbt = stack.nbt, total = 0, slots = {} }
                        groups[key] = group
                        order[#order + 1] = key
                    end
                    local count = tonumber(stack.count) or 0
                    group.slots[#group.slots + 1] = {
                        container = containerName,
                        slot = slot,
                        count = count,

                        name = stack.name,
                    }
                    group.total = group.total + count
                    end
                else
                    empties[#empties + 1] = { container = containerName, slot = slot }
                end
            end
        end
    end
    if planner then
        planner.containersDone = #roleContainers
        --- 因详情未到被跳过的物品数（网页/诊断能看到"整理为什么没动这些东西"）
        planner.skipped = planSkipped
    end

    --- 该物品在每个槽位里的容量 n = floor(C / vol)，容量/存量一起返回（供目标选择与搬运使用）
    local function candidatesOf(group)
        local sample = group.slots[1]
        -- 只占一个槽位的物品永远不会有搬运步骤（它自己就是目标），
        -- 所以连它的“槽位容量 / 最大堆叠数”都不必问外设 —— 省掉大量 getItemLimit / getItemDetail
        if #group.slots <= 1 then
            return {
                {
                    container = sample.container,
                    slot = sample.slot,
                    count = sample.count,
                    units = 0,
                    room = 0,
                },
            }, DEFAULT_ITEM_MAX_COUNT
        end
        local maxCount = maxCountOf(group.name, group.nbt, self:peripheralOf(sample.container, "item"), sample.slot)
        local list = {}
        for _, stack in ipairs(group.slots) do
            local units = unitsOf(stack.container, stack.slot, stack, false)
            list[#list + 1] = {
                container = stack.container,
                slot = stack.slot,
                count = stack.count,
                units = units,
                room = capacityForItem(units, maxCount),
            }
        end
        return list, maxCount
    end

    --- 选出“能装下 need 个该物品”的最小槽位集合（容量大的优先；容量相同时存量多的优先）
    local function selectTargets(candidates, need)
        local sorted = {}
        for _, entry in ipairs(candidates) do
            sorted[#sorted + 1] = entry
        end
        table.sort(sorted, function(a, b)
            if a.room ~= b.room then
                return a.room > b.room
            end
            if a.count ~= b.count then
                return a.count > b.count
            end
            if a.container ~= b.container then
                return a.container < b.container
            end
            return a.slot < b.slot
        end)
        local chosen, remaining = {}, math.max(0, tonumber(need) or 0)
        for _, entry in ipairs(sorted) do
            if remaining <= 0 then
                break
            end
            chosen[#chosen + 1] = entry
            remaining = remaining - entry.room
        end
        return chosen
    end

    --- 生成搬运步骤：源 = 不在目标集合里的槽位（存量多的先搬），目标 = 剩余空间最大的槽位
    local function movesFor(group, targets, candidates)
        local inTarget, rooms = {}, {}
        for index, target in ipairs(targets) do
            inTarget[slotUnitsKey(target.container, target.slot)] = true
            rooms[index] = math.max(0, (target.room or 0) - (target.count or 0))
        end
        local sources = {}
        for _, entry in ipairs(candidates) do
            if not inTarget[slotUnitsKey(entry.container, entry.slot)] then
                sources[#sources + 1] = entry
            end
        end
        table.sort(sources, function(a, b)
            if a.count ~= b.count then
                return a.count > b.count
            end
            if a.container ~= b.container then
                return a.container < b.container
            end
            return a.slot < b.slot
        end)
        local out = {}
        for _, source in ipairs(sources) do
            local remaining = source.count
            while remaining > 0 do
                -- argmax(rem)：剩余空间最大的目标槽位
                local best, bestRoom = nil, 0
                for index = 1, #targets do
                    local room = rooms[index] or 0
                    if room > bestRoom then
                        best, bestRoom = index, room
                    end
                end
                if not best then
                    break
                end
                local target = targets[best]
                local amount = math.min(remaining, bestRoom)
                out[#out + 1] = {
                    name = group.name,
                    nbt = group.nbt,
                    amount = amount,
                    fromContainer = source.container,
                    fromSlot = source.slot,
                    toContainer = target.container,
                    toSlot = target.slot,
                }
                rooms[best] = bestRoom - amount
                remaining = remaining - amount
            end
        end
        return out
    end
    -- 2) 每种物品各自算一次：先选出目标槽位集合，再据此生成搬运步骤
    local planned = {}
    for groupIndex, key in ipairs(order) do
        local group = groups[key]
        if planner then
            planner.stage = "probe"
            planner.groupsTotal = #order
            planner.groupsDone = groupIndex - 1
        end
        local candidates, maxCount = candidatesOf(group)
        group.maxCount = maxCount
        local entry = {
            group = group,
            candidates = candidates,
            targets = selectTargets(candidates, group.total),
        }
        entry.moves = movesFor(group, entry.targets, candidates)
        planned[#planned + 1] = entry
    end
    if planner then
        planner.groupsDone = #order
        planner.stage = "empty"
    end

    -- 3) 空槽二次优化：容量更大的空槽位能让某种物品占用更少的槽位时，把它加进目标集合重算
    if #empties > 0 and emptyBudget > 0 then
        local probed = {}
        for _, empty in ipairs(empties) do
            if emptyBudget <= 0 then
                break
            end
            local units = unitsOf(empty.container, empty.slot, nil, true)
            if units > 0 then
                probed[#probed + 1] = { container = empty.container, slot = empty.slot, units = units }
            end
        end
        table.sort(probed, function(a, b)
            if a.units ~= b.units then
                return a.units > b.units
            end
            if a.container ~= b.container then
                return a.container < b.container
            end
            return a.slot < b.slot
        end)
        local used = {}
        for _, empty in ipairs(probed) do
            local emptyKey = slotUnitsKey(empty.container, empty.slot)
            if not used[emptyKey] then
                local best, bestGain = nil, 0
                for _, entry in ipairs(planned) do
                    local group = entry.group
                    -- 已经在用 1 个槽位时不影响占用数，跳过（gain 一定为 0）
                    if #entry.targets > 1 then
                        local room = capacityForItem(empty.units, group.maxCount)
                        if room > 0 then
                            local candidates = {}
                            for _, target in ipairs(entry.candidates) do
                                candidates[#candidates + 1] = target
                            end
                            candidates[#candidates + 1] = {
                                container = empty.container,
                                slot = empty.slot,
                                count = 0,
                                units = empty.units,
                                room = room,
                            }
                            local reduced = selectTargets(candidates, group.total)
                            local gain = #entry.targets - #reduced
                            if gain > bestGain then
                                bestGain = gain
                                best = { entry = entry, candidates = candidates, targets = reduced }
                            end
                        end
                    end
                end
                if best then
                    -- 这个空槽位被这种物品占用了；被换出的旧目标槽位（还存着这种物品）
                    -- 会在重新生成步骤时自动变成源槽位，物品照样搬得出来
                    used[emptyKey] = true
                    best.entry.candidates = best.candidates
                    best.entry.targets = best.targets
                    best.entry.moves = movesFor(best.entry.group, best.targets, best.candidates)
                end
            end
        end
    end

    -- 4) 展平成计划（顺序稳定：按容器扫描顺序 + 物品登记顺序），交给引擎分 tick 执行
    local plan = {}
    for _, entry in ipairs(planned) do
        for _, move in ipairs(entry.moves) do
            plan[#plan + 1] = move
        end
    end
    return plan
end

--- 跑一遍「整理计划」的计算（分批）：最多问 planner.budget 次外设。
--- 返回：
---   plan, true   算完了（plan 可能为空表 = 不需要搬任何东西）
---   nil,  false  本次预算用光（被 PLAN_YIELD 中止）：引擎下个 tick 接着算
---   （其它异常原样抛出，由 Recipe 的 pcall 记日志）
function Containers:compactPlanPass(planner)
    planner = planner or self:compactPlanner("storage")
    planner.calls = 0
    planner.passes = (planner.passes or 0) + 1
    planner.yielded = nil
    self.planCtx = planner
    local ok, result = pcall(computeCompactPlan, self, planner.role, planner)
    self.planCtx = nil
    if ok then
        planner.stage = "done"
        return result, true
    end
    if result == PLAN_YIELD then
        return nil, false
    end
    error(result, 0)
end

--- 外设缺失的容器定义清单（网页高亮用；种类与外设能力不匹配也算缺失）
function Containers:missingPeripherals()
    local out = {}
    for _, def in ipairs(self.Store:list("containers")) do
        local defKind = self.Util.kindOfDef(def)
        local provides = false
        if self.Peripherals:exists(def.peripheral) then
            if defKind == "fluid" then
                provides = self.Peripherals:isFluid(def.peripheral)
            else
                provides = self.Peripherals:isInventory(def.peripheral)
            end
        end
        if not provides then
            --- containerKind：网页端删除这条缺失定义时要带上的容器种类（item / fluid）
            out[#out + 1] = { kind = "container", containerKind = defKind, name = def.name, peripheral = def.peripheral }
        end
    end
    for _, def in ipairs(self.Store:list("signals")) do
        if not self.Peripherals:exists(def.peripheral) then
            out[#out + 1] = { kind = "signal", name = def.name, peripheral = def.peripheral }
        end
    end
    return out
end

return Containers
