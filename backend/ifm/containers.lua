-- IFM :: ifm/containers.lua
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
--- （ifm/transfer.lua）。派太多会把 modem 和 worker 都占满，太少则标签扫描推进很慢。
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
    self.listTtl = opts.listTtl or 1200
    --- 容器扫描卸载（worker 代读容器，见 ifm/transfer.lua 的 Transfer:scanRequest）：
    --- 主控自己读一遍全部容器要 1 个服务器刻/个（19 个 ≈950ms），这部分交给 worker 后
    --- 主控只等 modem 消息；没有 worker 时行为与以前完全一样（本机读）。
    self.scanProvider = nil
    --- 缓存过期、但代扫结果还没回来时，旧值最多还能用多久（毫秒）：先顶着别让主循环停下来等。
    --- 15 秒是配合代扫限流（每个 tick 最多一条、每台 worker 之间有冷却，见 ifm/transfer.lua）：
    --- 一轮 19 个容器在 1~2 台 worker 上要 5~10 秒，8 秒的话最后几个容器会退回主控本机读 ——
    --- 那正是“把扫描摊开、别占满 worker”要避免的开销。外来的变化晚几秒看到没关系；
    --- 引擎自己搬过的东西会显式 invalidate()，照旧立刻可见。
    self.staleTtl = opts.staleTtl or 15000
    --- 代扫结果多久没回来就放弃等待、本机读（避免 worker 卡住时主控一直用旧数据）
    self.scanWaitTtl = opts.scanWaitTtl or 1200
    --- 本机扫描时间预算（毫秒）：**一个 1 秒窗口内**，主控自己读外设的总耗时超过它时，
    --- 后面的容器先返回缓存里的旧值（没有旧值才硬读一次）。
    --- 目的：把“读一遍 16~19 个容器 ≈950ms”摊平到多个 tick，否则一个 tick 被扫描占满，
    --- 引擎、网页推送、请求响应全都跟着卡（日志里就是 containerReads=16 readMs=797ms 那一行）。
    self.localScanBudgetMs = opts.localScanBudgetMs or 250
    self.scanWindowAt = 0
    self.scanWindowMs = 0
    --- 因为“本机扫描预算”用光而先用旧值顶着的次数（诊断用：说得出有多少次扫描被摊到了下个 tick）
    self.scanDeferred = 0
    --- 扫描成本自适应倍数（见 Containers:effectiveListTtl）：
    --- 生效的缓存时长至少是“实测读一遍全部容器耗时”的这个倍数。扫描本身与缓存时长同量级时，
    --- 缓存会在最需要它的那一刻刚好过期，于是每个 tick 都重扫一遍、把主循环压死；按实测耗时放大后，
    --- 扫描最多占用主循环 ~1/scanTtlMultiplier 的时间（与 protocol 的 PUSH_COST_MULTIPLIER 同一思路）。
    self.scanTtlMultiplier = opts.scanTtlMultiplier or 4
    self.readCostMs = 0        -- 单次外设读取耗时的平滑值（毫秒）
    self.listPassMs = 0        -- 估算的“读一遍全部容器”耗时（毫秒；诊断与慢 tick 明细里可见）
    self.readCount = 0         -- 累计真正调用外设读取的次数（诊断/引擎 tick 明细用）
    self.readMsTotal = 0       -- 累计外设读取耗时（毫秒）
    self.listCache = {}
    --- 物品详情字典：键「物品名 \1 NBT」→ { detail, hit, stamp, source }（见文件里的物品详情字典一节）
    self.detailCache = {}
    --- 物品详情能放多久：物品属性（maxCount / tags）一次会话里不会变，NBT 又在键里，
    --- 所以放长一点（5 分钟）也不会错 —— 它只是「这个物品的详情」的一份记忆。
    self.detailTtl = opts.detailTtl or 300000
    --- 物品详情提供者（worker 代查 getItemDetail，见 Containers:setDetailProvider）
    self.detailProvider = nil
    self.localDetailCalls = 0        -- 主控本机调用 getItemDetail 的次数（诊断：越少越好）
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
--- 高优先级容器里的资源**优先存入**，低优先级容器里的资源**优先取出**（同为 0 时按定义名排序）
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

--- 记一次**真实**的外设读取耗时（缓存命中不算）：
--- 平滑值用于估算“读一遍全部容器要多久”，进而决定扫描缓存能放多久（见 effectiveListTtl）。
function Containers:noteReadCost(elapsed)
    elapsed = math.max(1, math.floor(tonumber(elapsed) or 1))
    self.readCount = (self.readCount or 0) + 1
    self.readMsTotal = (self.readMsTotal or 0) + elapsed
    -- 本机扫描预算（见 Containers.new）：只统计**真的读了外设**的耗时，缓存命中不算
    self.scanWindowMs = (self.scanWindowMs or 0) + elapsed
    local cost = self.readCostMs or 0
    if cost <= 0 then
        self.readCostMs = elapsed
    else
        -- 指数平滑（新值占 1/4）：一次抖动不会永久拉长缓存，持续变慢会逐步生效
        self.readCostMs = (cost * 3 + elapsed) / 4
    end
end

--- 本机扫描限流（见 Containers.new 的 localScanBudgetMs）：固定 1 秒窗口，窗口内主控自己读
--- 外设的累计耗时没到预算才允许继续本机读；返回 false 时调用方应当先用缓存里的旧值顶着
--- （下个窗口还有预算时再读）。**每次读外设之前都要调用它**：它顺便负责窗口翻页
--- （冷启动没有旧值时也必须调，否则窗口起点不更新，预算就永远用不完）。
--- 为什么需要它：读一遍 16~19 个容器 ≈800~950ms，如果全挤在一个 tick 里，
--- 这个 tick 的引擎推进 / 网页推送 / 请求响应全部被推迟（日志里的
--- `Slow engine tick detail: containerReads=16 readMs=797ms` 就是它）。
function Containers:allowLocalRead()
    local now = os.epoch("utc")
    local windowAt = self.scanWindowAt or 0
    if windowAt == 0 or now - windowAt >= 1000 then
        self.scanWindowAt = now
        self.scanWindowMs = 0
        return true
    end
    return (self.scanWindowMs or 0) < (self.localScanBudgetMs or 250)
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

--- 生效的扫描缓存时长（毫秒）：max(listTtl, 估算的一遍全量扫描耗时 × scanTtlMultiplier)。
--- 这样“读一遍容器”的耗时越长，缓存就放得越久，扫描对主循环的占用保持有界
--- （否则：15 个容器读一遍 ≈0.75s，而缓存只有 1.2s —— 缓存刚写好就该过期了，主循环全在扫描）。
function Containers:effectiveListTtl()
    local cost = self.readCostMs or 0
    if cost <= 0 then
        return self.listTtl
    end
    local pass = cost * math.max(1, self:peripheralCount())
    self.listPassMs = math.floor(pass)
    local auto = math.floor(pass * (self.scanTtlMultiplier or 4))
    if auto > self.listTtl then
        return auto
    end
    return self.listTtl
end

--- 扫描统计摘要（诊断 perf / 慢 tick 明细用）：单次读取耗时、估算的全量扫描耗时、生效缓存时长
function Containers:scanSummary()
    local ttl = self:effectiveListTtl()
    return {
        containers = self:peripheralCount(),
        readCost = math.floor(self.readCostMs or 0),
        passCost = self.listPassMs or 0,
        ttl = ttl,
        baseTtl = self.listTtl,
        multiplier = self.scanTtlMultiplier or 4,
        reads = self.readCount or 0,
        readMs = self.readMsTotal or 0,
        --- 本机扫描预算用光、先用旧值顶着的次数（defer > 0 说明扫描被摊到了多个 tick，
        --- 这正是“慢 tick 被扫描占满”的解法在生效；见 Containers:allowLocalRead）
        defer = self.scanDeferred or 0,
        budget = self.localScanBudgetMs or 250,
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

--- 需要刷新的一批外设（所有容器定义指向的、当前存在的外设）：交给代扫 provider 切片派活用。
--- 只有在 Peripherals 重新扫描过之后才重建（本函数在缓存过期时会被调用）。
function Containers:scanTargets()
    local scanAt = (self.Peripherals and self.Peripherals.lastScan) or 0
    if self.scanTargetsValue == nil or self.scanTargetsScanAt ~= scanAt then
        local names = {}
        local seen = {}
        for _, def in ipairs(self.Store:list("containers")) do
            local name = def.peripheral
            if type(name) == "string" and name ~= "" and not seen[name]
                and self.Peripherals:exists(name) then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        table.sort(names)
        self.scanTargetsValue = names
        self.scanTargetsScanAt = scanAt
    end
    return self.scanTargetsValue or {}
end

--- 问一次代扫 provider（worker 代读容器）。返回：
---   "done", value  用 value（{slots=..., tanks=...}）刷新缓存
---   "pending"      已经派活/正在扫：调用方先用旧值顶着
---   "local"        没有可查询的 worker（或没装 provider）：调用方本机读
function Containers:requestDelegateScan(peripheralName)
    if not self.scanProvider or not self.scanProvider.scanRequest then
        return "local"
    end
    --- 代扫结果要**至少和本机缓存一样新鲜**才能被复用：本机缓存时长是自适应的
    --- （见 effectiveListTtl），所以把它带过去并留 1.5 倍余量。
    --- 不带的话会这样：worker 的结果 3 秒就过期，而本机缓存有 3.8 秒 —— 每次本机该刷新时
    --- worker 的结果刚好过期，于是每次都要重新派活、主控等不到就用旧值，代扫等于白做。
    local want = math.floor(self:effectiveListTtl() * 1.5)
    local ok, state, value = pcall(self.scanProvider.scanRequest, self.scanProvider,
        peripheralName, self:scanTargets(), want)
    if not ok then
        return "local"
    end
    if state == "done" and type(value) == "table" then
        return "done", value
    end
    return state or "local"
end

--- 只读缓存模式（1.6.10）：整理计划**只用当前已经扫到的结果**，不再触发任何新的扫描 / 外设探测。
--- 用户要求：「整理容器功能直接使用当前扫描的容器结果，不触发重新扫描，探测物品种类也应当使用缓存」。
--- 打开后：
---   * listPeripheral/tanksPeripheral 只读 listCache/tankCache（连 TTL 都不看），没有缓存就返回空表
---     （这一轮就跳过这个容器；引擎每个 tick 又会跑一遍计划，缓存很快就会有）；
---   * maxCountOf 只读物品详情字典（不派 worker、不本机读），问不到的按 64 算。
--- 关闭后行为与以前完全一样（做搬运、做判断时该刷新就刷新）。
function Containers:setCacheOnly(on)
    self.cacheOnly = on and true or false
    if not self.cacheOnly then
        self.cacheOnlyMisses = 0
    end
end

--- 只读缓存模式下的 list 结果：有缓存就直接用（不看 TTL），没有就返回 nil 表示“这一轮没有数据”
function Containers:cachedList(peripheralName)
    local cached = self.listCache[peripheralName]
    if cached and type(cached.value) == "table" then
        return cached.value
    end
    return nil
end

--- 某外设的槽位表：{slot -> {name, count, nbt}}（失败返回空表）
--- 带 listTtl 短时缓存（见 Containers.new）：同一批容器在一次推送/一个 tick 里只读一次外设。
--- 缓存过期时先问 IFMWorker（它读容器对主控零成本），拿不到就用旧值顶着 / 本机读。
function Containers:listPeripheral(peripheralName)
    local cached = self.listCache[peripheralName]
    local now = os.epoch("utc")
    --- 只读缓存模式（整理计划）：绝不再触发扫描（worker 代扫 / 本机读），只用当前扫到的结果
    if self.cacheOnly then
        local only = self:cachedList(peripheralName)
        if only then
            return only
        end
        self.cacheOnlyMisses = (self.cacheOnlyMisses or 0) + 1
        return {}
    end
    if cached and now - cached.stamp < self:effectiveListTtl() then
        return cached.value
    end
    -- 容器扫描卸载：主控自己读一遍 19 个容器 ≈950ms，交给 worker 后主控只等 modem 消息
    local state, value = self:requestDelegateScan(peripheralName)
    if state == "done" then
        local slots = value.slots or {}
        self.listCache[peripheralName] = { stamp = now, value = slots }
        return slots
    end
    if state == "pending" and cached and now - cached.stamp < self.staleTtl then
        -- 已经派给 worker：先用旧值顶着（下个 tick 再问），别让主循环停下来等
        return cached.value
    end
    local inv = self:inventory(peripheralName)
    if not inv then
        return {}
    end
    -- 本机扫描预算（见 Containers.new）：这一秒里主控自己读外设已经花掉了 250ms 以上，
    -- 就先拿旧值顶着（下个 tick 还有预算时再读）——否则一次“缓存集体过期”会在一个 tick 里
    -- 读到 800ms+，把这个 tick 的引擎推进 / 网页推送 / 请求响应全部推迟。
    -- 注意：allowLocalRead 每次都要调（它顺便负责“预算窗口翻页”），冷启动没有旧值时照样读。
    local allowRead = self:allowLocalRead()
    if cached and not allowRead then
        self.scanDeferred = (self.scanDeferred or 0) + 1
        return cached.value
    end
    -- 计划计算期间：一次真实的 list() 也是一次外设调用（预算用光就中止本次计算，
    -- 有旧值就先用旧值 —— 反正下个 tick 会接着算，缓存会让它走得更远）
    if not self:chargePlanCall("list") then
        return cached and cached.value or {}
    end
    local startedAt = os.epoch("utc")
    local ok, listed = pcall(inv.list)
    noteScan(self, peripheralName, "list", startedAt)
    if not ok or type(listed) ~= "table" then
        -- 包装对象可能已失效（外设替换 / 区块重载）：清缓存，下次调用重新 wrap
        self.Peripherals:invalidate(peripheralName)
        self.listCache[peripheralName] = nil
        return {}
    end
    self.listCache[peripheralName] = { stamp = os.epoch("utc"), value = listed }
    return listed
end

--- 某外设的物品栈数组（含槽位）
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

--- 某外设的流体罐数组（同 listPeripheral：带短时缓存 + worker 代扫）
function Containers:tanksPeripheral(peripheralName)
    local cached = self.tankCache and self.tankCache[peripheralName]
    local now = os.epoch("utc")
    --- 只读缓存模式（整理计划）：只用当前扫到的结果，不再触发扫描
    if self.cacheOnly then
        if cached and type(cached.value) == "table" then
            return cached.value
        end
        self.cacheOnlyMisses = (self.cacheOnlyMisses or 0) + 1
        return {}
    end
    if cached and now - cached.stamp < self:effectiveListTtl() then
        return cached.value
    end
    self.tankCache = self.tankCache or {}
    -- 容器扫描卸载（与 listPeripheral 同一批代扫结果：worker 一次把物品与流体都读回来）
    local state, value = self:requestDelegateScan(peripheralName)
    if state == "done" then
        local out = {}
        for tank, entry in pairs(value.tanks or {}) do
            out[#out + 1] = {
                tank = tonumber(tank) or tank,
                name = entry.name,
                amount = tonumber(entry.amount) or 0,
            }
        end
        table.sort(out, function(a, b)
            return a.tank < b.tank
        end)
        self.tankCache[peripheralName] = { stamp = now, value = out }
        return out
    end
    if state == "pending" and cached and now - cached.stamp < self.staleTtl then
        return cached.value
    end
    local storage = self:fluidStorage(peripheralName)
    if not storage then
        return {}
    end
    -- 本机扫描预算：与 listPeripheral 同一套限流（流体容器也在同一个 250ms/秒 预算里）
    local allowTankRead = self:allowLocalRead()
    if cached and not allowTankRead then
        self.scanDeferred = (self.scanDeferred or 0) + 1
        return cached.value
    end
    local startedAt = os.epoch("utc")
    local ok, listed = pcall(storage.tanks)
    noteScan(self, peripheralName, "tanks", startedAt)
    if not ok or type(listed) ~= "table" then
        -- 包装对象可能已失效（同 listPeripheral）
        self.Peripherals:invalidate(peripheralName)
        self.tankCache[peripheralName] = nil
        return {}
    end
    local out = {}
    for tank, fluid in pairs(listed) do
        if type(fluid) == "table" and fluid.name then
            out[#out + 1] = {
                tank = tank,
                name = fluid.name,
                amount = tonumber(fluid.amount) or 0,
            }
        end
    end
    table.sort(out, function(a, b)
        return a.tank < b.tank
    end)
    self.tankCache[peripheralName] = { stamp = os.epoch("utc"), value = out }
    return out
end

--- 容器定义的物品栈（物品容器）
function Containers:stacks(containerName)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return {}
    end
    return self:stacksPeripheral(peripheralName)
end

--- 容器定义的流体罐（流体容器）
function Containers:tanks(containerName)
    local peripheralName = self:peripheralOf(containerName, "fluid")
    if not peripheralName then
        return {}
    end
    return self:tanksPeripheral(peripheralName)
end

--- 设置搬运提供者（IFMWorker 调度器，见 ifm/transfer.lua）：
--- 设置后 pushItem / pushFluid 会优先把搬运交给它；它返回 nil, "pending" 表示
--- “任务已发给 worker，这一 tick 先别推进”，等 worker 回报后下个 tick 才会拿到真实结果。
function Containers:setTransferProvider(provider)
    self.transfer = provider
end

--- 设置容器扫描提供者（IFMWorker 调度器，见 ifm/transfer.lua 的 Transfer:scanRequest）：
--- 设置后 listPeripheral / tanksPeripheral 缓存过期时会先请 worker 代读一遍容器，
--- 主控自己不再为每次刷新花掉 19 个服务器刻；没有 worker 时自动退回本机读。
function Containers:setScanProvider(provider)
    self.scanProvider = provider
end

--- 物品搬运：从 fromContainer 的 fromSlot 推送到 toContainer（toSlot 为 nil 或 <1 表示任意槽位）
function Containers:pushItem(fromContainer, fromSlot, limit, toContainer, toSlot)
    local fromPeripheral = self:peripheralOf(fromContainer, "item")
    local toPeripheral = self:peripheralOf(toContainer, "item")
    if not fromPeripheral then
        return 0, self:unusableReason(fromContainer, "item") or ("\\u6765\\u6E90\\u5BB9\\u5668 " .. tostring(fromContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    if not toPeripheral then
        return 0, self:unusableReason(toContainer, "item") or ("\\u76EE\\u6807\\u5BB9\\u5668 " .. tostring(toContainer) .. " \\u4E0D\\u53EF\\u7528")
    end
    local wantsSlot = (tonumber(toSlot) or -1) >= 1 and tonumber(toSlot) ~= fromSlot
    if fromPeripheral == toPeripheral and not wantsSlot then
        -- 同一个外设：只有“明确要求换到另一个槽位”时才需要搬运（容器内部挪动，CC 允许）；
        -- 否则资源本来就在目标容器里，返回理由交给调用方按“已经在目标容器里”处理。
        return 0, samePeripheralReason(fromContainer, toContainer, fromPeripheral)
    end
    local inv = self:inventory(fromPeripheral)
    if not inv then
        return 0, "\\u6765\\u6E90 " .. fromPeripheral .. " \\u4E0D\\u662F\\u7269\\u54C1\\u5BB9\\u5668"
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, "\\u6570\\u91CF\\u5FC5\\u987B\\u5927\\u4E8E 0"
    end
    --- IFMWorker 卸载：有 worker 在线时这次搬运交给它执行，本机不再自己搬
    --- （不管成功与否都记账：调用方随后 invalidate() 时只作废这两个容器，其它容器复用缓存）
    self.dirty[fromPeripheral] = true
    self.dirty[toPeripheral] = true
    if self.transfer then
        local state, moved, err = self.transfer:request({
            action = "push_item",
            from = fromPeripheral,
            fromSlot = fromSlot,
            limit = limit,
            to = toPeripheral,
            toSlot = (tonumber(toSlot) or -1) >= 1 and toSlot or nil,
        })
        if state == "pending" then
            return nil, "pending"
        elseif state == "done" then
            return moved, err
        end
    end
    local targetSlot
    if toSlot and toSlot >= 1 then
        targetSlot = toSlot
    end
    local ok, moved = pcall(inv.pushItems, toPeripheral, fromSlot, limit, targetSlot)
    if ok and type(moved) == "number" and moved > 0 then
        return moved
    end
    if not ok then
        -- 包装对象可能已失效（外设替换 / 区块重载）：清缓存，下个 tick 重新 wrap 再试
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
    if ok then
        return 0, "\\u672A\\u80FD\\u642C\\u8FD0\\u4EFB\\u4F55\\u7269\\u54C1"
    end
    return 0, tostring(moved)
end

--- 流体搬运
function Containers:pushFluid(fromContainer, limit, fluidName, toContainer)
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
    local storage = self:fluidStorage(fromPeripheral)
    if not storage then
        return 0, "\\u6765\\u6E90 " .. fromPeripheral .. " \\u4E0D\\u662F\\u6D41\\u4F53\\u5BB9\\u5668"
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, "\\u6570\\u91CF\\u5FC5\\u987B\\u5927\\u4E8E 0"
    end
    --- IFMWorker 卸载：流体搬运同样交给 worker（见 pushItem 上的说明）
    self.dirty[fromPeripheral] = true
    self.dirty[toPeripheral] = true
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
    local ok, moved = pcall(storage.pushFluid, toPeripheral, limit, fluidName)
    if ok and type(moved) == "number" and moved > 0 then
        return moved
    end
    if not ok then
        -- 包装对象可能已失效（同上）
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

-- ===================== 物品详情字典：list 的粗略物品 → getItemDetail =====================
-- getItemDetail 是**阻塞**的外设调用（有线网络上 ≈1 个服务器刻/次，见 CC:T 文档
-- docx/CC-Tweaked/item_details.txt）。它提供的两样东西是我们真正需要的：
--   * maxCount —— 整理计划算「一个槽位能放几个这种物品」必需（capacityForItem）；
--   * tags     —— 网页上的 #标签 搜索与标签展示（标签扫描）。
--
-- 字典的键是 **list() 给出的那个粗略物品**（物品名 + NBT），值是它的 itemDetail：
--   detailCache["minecraft:stone\1"] = { detail = { name, maxCount, tags, ... }, hit = true, stamp = 时间 }
-- 为什么按物品而不是按槽位：同一种物品可能散在 19 个容器的几十个槽位里 —— 按槽位缓存
-- 就要问几十次外设，按物品只有一次。这也让「整理计划」与「标签扫描」共用同一份结果：
-- 整理刚问过的物品，标签扫描就是零成本，反过来也一样。
--   * hit = false：问过但外设给不出详情（外设不支持 / 槽位已经被搬空）——TTL 内不再反复问；
--   * 物品属性（maxCount / tags）在一次会话里不会变，NBT 又在键里，所以缓存可以放很久
--     （self.detailTtl）；搬运改变的是槽位内容，与「物品 → 详情」这层无关。
local function itemDetailKey(itemName, nbt)
    return tostring(itemName) .. "\1" .. tostring(nbt or "")
end

--- 只查字典（绝不调用外设）。返回：
---   detail, true    有详情（detail 可能是 nil：负缓存，见上）
---   nil, false      字典里没有 / 已经过期 → 调用方决定去 worker 代查还是本机读
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

--- 物品详情（只读字典，不调用外设）：有详情时返回它，否则 nil
function Containers:itemDetail(itemName, nbt)
    local detail, known = self:cachedItemDetail(itemName, nbt)
    if not known then
        return nil
    end
    return detail
end

--- 写一份物品详情进字典。detail 为 nil 就是「问过、拿不到」的负缓存。
--- source 只是给诊断看的（"local" / "worker"）。
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
    --- 有答案了（本机读到的也算）：从「在飞」里摘掉
    if self.detailInFlight then
        self.detailInFlight[itemDetailKey(itemName, nbt)] = nil
    end
    return true
end

--- 吸收 worker 代查回来的物品详情（见 IFMWorker 的 detail 任务 / Transfer:takeDetailResults）。
--- entries = { { name = 物品名, nbt = ..., detail = { name, maxCount, tags, ... } }, ... }
--- 只接受「回报的物品名与请求的一致」的那些（排队期间槽位可能被搬走、换成别的东西）。
--- 返回：吸收进来的数量, 其中真的拿到详情的物品名数组（主控据此立刻写标签缓存）
function Containers:absorbItemDetails(entries)
    local taken, fresh = 0, {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local name = type(entry) == "table" and entry.name or nil
        local detail = type(entry) == "table" and entry.detail or nil
        if type(name) == "string" and name ~= "" and type(detail) == "table" and
            (detail.name == nil or detail.name == name) then
            self:setItemDetail(name, entry.nbt, detail, "worker")
            --- 这条已经回来了：从「在飞」里摘掉（同一件物品之后可以再派，例如缓存过期）
            if self.detailInFlight then
                self.detailInFlight[itemDetailKey(name, entry.nbt)] = nil
            end
            taken = taken + 1
            fresh[#fresh + 1] = name
        end
    end
    return taken, fresh
end

--- 本机读取物品详情（**阻塞**：一次调用 ≈1 个服务器刻）。
--- 有 worker 时**不要**走这里：用 setDetailProvider + requestItemDetails 交给它们
--- （getItemDetail 与 list 一样不该压在主控身上）。这是「没有 worker 可用」时的兜底。
--- opts.name / opts.nbt 是 list 结果里这个槽位的物品（给了才会写进物品字典）。
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
            --- 读不到（外设不支持 / 槽位空了）：记成负缓存，免得每个 tick 都来问一次
            self:setItemDetail(wantName, opts.nbt, nil, "local")
        end
        --- 槽位里已经是别的东西（detail.name ~= wantName）：什么都不写 ——
        --- 我们不知道那个新物品的详情，而 wantName 的详情也不该被它污染
    end
    return detail
end

--- 已经派给 worker、还没回报的物品（键 = 物品名 \1 NBT → 派出时间）：
--- 同一件物品可能同时被「整理计划」与「标签扫描」问到，这里保证它**只派一次**
--- （超时后作废：DETAIL_IN_FLIGHT_TTL 之后允许重新派，见 Containers:detailsInFlight）。
local DETAIL_IN_FLIGHT_TTL = 10000

--- 这件物品已经派给 worker 了吗（还没回报、又没过期）？
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
        --- 超时（worker 没回 / 回报丢了）：允许重新派出去
        self.detailInFlight[itemDetailKey(itemName, nbt)] = nil
        return false
    end
    return true
end

--- 请 provider（worker）代查一批物品详情（见 ifm/transfer.lua 的 Transfer:detailRequest）：
--- samples = { { container = 外设名, slot = 槽位, name = 物品名, nbt = ... }, ... }
--- 返回：
---   "pending"  已经派给 worker（结果回来后由主控 absorbItemDetails 进字典）
---   "local"    没有可用 worker（调用方本机读，或者下个 tick 再试）
--- 已经派出去、还没回报的物品会被跳掉（见 detailsInFlight）—— 不重复派同一个物品。
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
        --- 全都已经派出去了：当作 pending（等回报），调用方不要改走本机读
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

--- 设置物品详情提供者（IFMWorker 调度器，见 ifm/transfer.lua 的 Transfer:detailRequest）：
--- 设置后 requestItemDetails 会把 getItemDetail 打包交给 worker，主控自己不做阻塞调用。
function Containers:setDetailProvider(provider)
    self.detailProvider = provider
end

--- 收集指定角色容器中的全部物品栈（只统计物品容器定义）
--- 顺序 = 取出顺序（低优先级容器在前），所以流程从存储容器取料时也是**低优先级优先取出**
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

--- 收集指定角色容器中的全部流体罐（只统计流体容器定义）
--- 顺序 = 取出顺序（低优先级容器在前，同 collectStacks）
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

--- 带短时缓存的快照（避免同一 tick 内反复扫描；角色各存一份，见 self.snapshots）
--- totals：按 “种类:名称” 合计的数量（物品按个数、流体按 mB）。
--- 引擎的“材料够不够 / 已经产出多少”每 tick 都会问很多次，用它可以做到 O(1) 回答，
--- 不必每次都把所有槽位重新过一遍过滤器（旧实现里这是引擎 tick 的主要 Lua 开销）。
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

--- 清扫描缓存（1.5.0 起是“**增量**”清理）：
---   只作废 pushItem / pushFluid 记下来的那两三个外设（self.dirty）+ 让角色快照过期，
---   其它容器的 list() 结果继续复用 —— 把 15 个容器全部作废意味着下一次扫描要全部重读（≈0.75s），
---   这在 2 台 worker 同时搬运、网页推送又要全量收集时会直接把主循环拖死。
---   需要真正全清（外设插拔 / 替换、重扫外设）时用 Containers:invalidateAll()。
function Containers:invalidate()
    for name in pairs(self.dirty) do
        self.listCache[name] = nil
        if self.tankCache then
            self.tankCache[name] = nil
        end
        -- 内容被改过：这个容器的 list() 结果作废（物品详情字典按「物品」缓存，搬运不影响它）
        -- worker 那边扫到的也是旧值 → 作废它的代扫结果，下次必须重扫
        if self.scanProvider and self.scanProvider.invalidateScan then
            pcall(self.scanProvider.invalidateScan, self.scanProvider, name)
        end
    end
    self.dirty = {}
    -- 角色快照里有这两个外设的旧内容：整份作废（下次读取按 listCache 重建，只重读被改过的外设）
    self.snapshots = {}
end

--- 全部作废（结构性变化：外设插拔、重扫外设、定义大改之后）
function Containers:invalidateAll()
    self.snapshots = {}
    self.listCache = {}
    self.tankCache = {}
    self.dirty = {}
    --- list→detail 字典（物品 → 详情）也全清：外设可能被换掉，旧详情可能来自别的整合包
    self.detailCache = {}
    self.detailInFlight = {}
    -- 外设集合可能变了：容器数量缓存与代扫目标都要重算
    self.peripheralCountValue = nil
    self.peripheralCountAt = nil
    self.scanTargetsValue = nil
    self.scanTargetsScanAt = nil
    if self.scanProvider and self.scanProvider.invalidateScan then
        pcall(self.scanProvider.invalidateScan, self.scanProvider, nil)   -- 全清
    end
end

--- 匹配 spec 的物品栈与流体罐
-- spec = {kind = "item"|"fluid"|"filter", id = string}
function Containers:matchSpec(spec, role)
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
    return items, fluids
end

--- 统计 spec 在指定角色容器中的总量（物品按个数、流体按 mB；过滤器两者相加）
--- 物品/流体（且不要求严格 NBT）走快照里的按名合计表：O(1)，
--- 因为引擎每 tick 都会用“材料够不够 / 已经产出多少”反复问它。
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

--- 某个容器定义里符合 spec 的数量（物品与流体都查；用于判断“资源其实已经在目标容器里”）
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

--- 存储容器资源汇总（网页展示用）
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

--- 存储容器中符合某过滤器的资源明细
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

--- 统计某过滤器的总量（网页上显示过滤器数目用）
function Containers:filterCount(filterName)
    local total = 0
    for _, entry in ipairs(self:filterResources(filterName)) do
        total = total + entry.count
    end
    return total
end

--- 单个物品容器的槽位总数：只做**一次**外设调用（size），拿不到时按“已经看到的最大槽位号”兜底，
--- 并做上限保护（异常外设报出超大槽位数时不会把循环拖死）。
--- 结果缓存 SLOT_COUNT_TTL（一次整理要给每个容器问一次，而它几乎不变）。
function Containers:slotCount(peripheralName)
    self.slotCountCache = self.slotCountCache or {}
    local now = os.epoch("utc")
    local cached = self.slotCountCache[peripheralName]
    if cached and now - cached.stamp < SLOT_COUNT_TTL then
        return cached.value
    end
    local inv = self:inventory(peripheralName)
    local size = nil
    -- 计划计算期间要记账：一次 size() 也是一次外设调用（可能 50ms）
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

--- 计划计算记账：返回 true 表示“可以问外设”。
---   * 没在算计划（self.planCtx 为空）：永远返回 true，对其它调用方完全透明；
---   * 单次预算用光 → 抛出 PLAN_YIELD 中止本次计算（下个 tick 接着算）；
---   * 整个计划的次数超过上限 → 返回 false，调用方按保守值处理（与旧版预算语义一致）。
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

--- 新建「整理计划」的计算上下文（**不访问外设**，真正的计算由 compactPlanPass 分批做）
function Containers:compactPlanner(role, opts)
    opts = opts or {}
    return {
        role = role or "storage",
        budget = tonumber(opts.budget) or PLAN_CALLS_PER_PASS,   -- 单次（一个 tick）允许的外设调用数
        maxCalls = tonumber(opts.maxCalls) or PLAN_MAX_CALLS,    -- 整个计划的调用上限
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

--- 存储容量统计（网页资源浏览的进度条用）：
---   items / itemCapacity = 已存储物品总数 / 可存储物品总数（按 64/槽 估算）
---   slots / totalSlots    = 已占用槽位数 / 总槽位数
--- 只统计 storage 角色的**物品**容器。
--- 重要：这里**不再逐个槽位调用外设方法**（getItemLimit）：外设调用（尤其有线网络上的容器）
--- 可能很慢，跟着 2 秒一次的推送调用上百次会把整个事件循环拖住——表现出来就是网页所有请求超时。
--- 现在只用本来就要扫的 list() 与一次 size()，并用 capacityTtl（默认 15 秒）缓存结果。
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

--- 某个槽位当前的物品名（整理时复核源槽位用；空槽或不可用返回 nil）
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

--- 某个槽位当前的堆（整理时复核“源槽位还是当初那一堆”用；空槽或不可用返回 nil）
--- 比 slotName 多带 NBT：同名但 NBT 不同的物品不可堆叠，不能当成同一堆
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

--- 存储整理计划（跨容器）。完全按「槽位真实容量」计算，而不是一律假设 64：
---   * C（units）：槽位的“64 堆叠单位容量”。空槽位问 getItemLimit 直接得到它；
---     已占用槽位问 getItemLimit 得到的是“当前这种物品（一组 maxCount 个）能装多少个” L，
---     于是 C = L * 64 / maxCount（maxCount 见 CC:T 文档 docx/CC-Tweaked/item_details.txt）。
---   * vol：物品体积 = 64 / maxCount ⇒ 某物品在某槽位里最多放 n = floor(C / vol) 个。
--- 算法（与 README「存储容量与整理」一致）：
---   1) 汇总：每种物品（物品名 + NBT 都相同才算同一种，否则不可堆叠）的总数量与所在槽位，记下空槽位；
---   2) 每种物品选“最小目标槽位集合”：按槽位容量 n 从大到小、存量从多到少排序，依次取槽位直到
---      能装下这种物品的全部数量（目标槽位的剩余空间 n - 存量就是可接收量）；
---   3) 其余槽位当源，按存量从多到少把物品填进“剩余空间最大的目标槽位”（装满一个再换下一个），
---      源槽位搬空后即被释放（槽位占用数变少）；
---   4) 空槽二次优化：某个空槽位容量更大、把整种物品搬进去能让占用槽位更少（gain > 0）时，
---      把它加进这种物品的目标集合并重新生成搬运步骤。
--- 计划元素：{ name, nbt, amount, fromContainer, fromSlot, toContainer, toSlot }
--- **计算过程按 tick 分批**（见 PLAN_CALLS_PER_PASS / compactPlanPass）：
--- 一次调用最多问 planner.budget 次外设，问不完就抛 PLAN_YIELD 中止本次；
--- 引擎下个 tick 再调一次 —— 已经问过的结果都在缓存里，所以每次都会比上次走得更远，
--- 直到算出完整计划为止。这样点「整理」永远不会把主循环卡住（网页也不会“15 秒没数据”）。
local function computeCompactPlan(self, role, planner)
    role = role or "storage"
    local now = os.epoch("utc")
    -- 外设调用预算（见文件顶部常量；planner 负责“分批”这层）
    local limitBudget = MAX_SLOT_LIMIT_QUERIES
    local emptyBudget = MAX_EMPTY_SLOT_PROBES
    local detailBudget = MAX_ITEM_DETAIL_QUERIES
    self.slotUnitsCache = self.slotUnitsCache or {}
    self.itemMaxCountCache = self.itemMaxCountCache or {}
    self.emptyUnitsCache = self.emptyUnitsCache or {}
    --- 「外设 + 物品名」→ 每槽容量（同一容器里同种物品的每槽容量相同，见 unitsOf）
    self.itemUnitsCache = self.itemUnitsCache or {}

    --- 物品详情预算：worker 代查的批次数（一个 tick 里最多派几批，别把 modem 淹没）
    local detailRequestBudget = MAX_DETAIL_REQUESTS_PER_PASS

    --- 详情在 worker 手上（已经派出去、还没回报）：不能用缺省值算计划，先让出等它回来。
    --- 最多等 DETAIL_WAITS_MAX 遍（worker 一直不回就按 64 继续算完，不会永远算不完）。
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

    --- 物品的最大堆叠数（getItemDetail().maxCount）：**统一走物品详情字典**（键 = 物品名 + NBT）。
    --- 顺位：① 本会话已经知道的（itemMaxCountCache）→ ② 字典里有详情（可能是标签扫描 / 别的物品
    --- 在同一个容器里刚问出来的）→ ③ 请 worker 代查（阻塞调用不该压在主控身上）→
    --- ④ 没有 worker 时才本机读一次（受 MAX_ITEM_DETAIL_QUERIES 预算限制）。
    --- 都拿不到时按 64 算（DEFAULT_ITEM_MAX_COUNT），并且不写缓存，下次整理再试。
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
        --- 只读缓存模式（整理计划）：物品种类也只用缓存 —— 不派 worker、不本机读，问不到就按 64 算
        if self.cacheOnly then
            self.detailDeferred = (self.detailDeferred or 0) + 1
            return DEFAULT_ITEM_MAX_COUNT
        end
        --- 字典里没有：先问 worker（它就在容器旁边，主控零成本；结果下个 tick 进字典）
        if self:detailsInFlight(itemName, nbt) then
            --- 已经派出去、还没回报：别重复派，等它回来（让出，受 waitForDetail 的上限约束）
            self.detailDeferred = (self.detailDeferred or 0) + 1
            return waitForDetail()
        end
        if detailRequestBudget > 0 then
            detailRequestBudget = detailRequestBudget - 1
            local state = self:requestItemDetails({
                { container = peripheralName, slot = slot, name = itemName, nbt = nbt },
            })
            if state == "pending" then
                self.detailDeferred = (self.detailDeferred or 0) + 1
                --- 不能用猜测值（64）算出一份错的搬运计划：这一遍先让出，
                --- 等 worker 把详情送回来再算（下个 tick 字典里就有答案了，会走得更远）。
                return waitForDetail()
            end
        end
        --- 没有可用 worker：本机读（阻塞），受预算限制
        if detailBudget > 0 and self:chargePlanCall("detail") then
            detailBudget = detailBudget - 1
            local localDetail = self:detail(peripheralName, slot, { name = itemName, nbt = nbt })
            if type(localDetail) == "table" and localDetail.name == itemName then
                local value = tonumber(localDetail.maxCount) or DEFAULT_ITEM_MAX_COUNT
                if value <= 0 then
                    value = DEFAULT_ITEM_MAX_COUNT
                end
                self.itemMaxCountCache[itemName] = value
                return value
            end
        end
        return DEFAULT_ITEM_MAX_COUNT
    end

    --- 槽位的“64 堆叠单位容量”C（带缓存：槽位上限基本不变，重复整理不必反复问外设）
    ---   stack：该槽位当前的堆（空槽位传 nil）；probing = true 表示空槽位探测（单独预算）
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
        --- 同一容器里同一种物品的每槽容量是一致的：先用「外设 + 物品名」缓存兜一层。
        --- 整理计划最贵的一块就是为每个槽位各问一次 getItemLimit（19 个容器 = 几百次外设调用），
        --- 有了这层缓存，同种物品只问一次（剩下的开销是每种物品一次 getItemDetail，已在别处缓存）。
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
            -- 空槽位容量按**外设**复用：同一个容器里的空槽位容量几乎总是一样（原版箱子=64、
            -- 大容量容器=几百），而整理计划会把所有空槽位都探一遍 —— 19 个容器 × 27 个空槽位
            -- 就是几百次 getItemLimit，计划里最贵的一块。这里每个外设只问一次。
            -- 万一某个容器真的每槽容量不同，最坏情况只是“空槽二次优化”算多了剩余空间，
            -- pushItem 仍然只搬得下多少搬多少（会记为 failed 并写日志），不会搬错物品。
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
                -- 已占用槽位：getItemLimit 是“这种物品能放多少个”，按它的 maxCount 折算回 C
                local maxCount = maxCountOf(stack.name, stack.nbt, peripheralName, slot)
                units = limit * DEFAULT_ITEM_MAX_COUNT / maxCount
            else
                -- 空槽位：getItemLimit 直接就是“一组 64 个的物品能放多少个”，也就是 C
                units = limit
            end
            units = math.max(0, math.floor(units + 0.5))
            self.slotUnitsCache[key] = { units = units, stamp = now }
            if itemKey then
                self.itemUnitsCache = self.itemUnitsCache or {}
                self.itemUnitsCache[itemKey] = { units = units, stamp = now }
            end
            if probing then
                -- 记住这个外设的空槽位容量（同一外设的空槽位复用，见上面说明）
                self.emptyUnitsCache = self.emptyUnitsCache or {}
                self.emptyUnitsCache[peripheralName] = { units = units, stamp = now }
            end
            return units
        end
        -- 问不到容量（外设不支持 getItemLimit / 预算用光）：保守地按“只能装下现在这些”处理，
        -- 这样它不会被当成还有剩余空间的目标槽位（计划绝不会超量搬运）
        return stack and math.max(0, tonumber(stack.count) or 0) or 0
    end
    -- 1) 汇总：扫描全部物品容器（含空槽位），把每个堆登记到「物品名 + NBT」的组里（跨容器合并）
    local groups, order, empties = {}, {}, {}
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
                        -- 每个槽位条目都带上物品名：后面算“物品最大堆叠数 / 槽位容量”要用它
                        name = stack.name,
                    }
                    group.total = group.total + count
                else
                    empties[#empties + 1] = { container = containerName, slot = slot }
                end
            end
        end
    end
    if planner then
        planner.containersDone = #roleContainers
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

--- 跑一遍「整理计划」的计算（**分批**）：最多问 planner.budget 次外设。
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
