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

--- ===== 读取规则（用户第 2/3 项，1.9.0）：所有角色的容器都有内容快照 =====
---   * storage / input / interaction / output 全部参与扫描（见 scanQueueTargets）→ 维护快照；
---   * **海龟**这类没有 inventory 外设的交互容器扫不了：由 IFMCrafter 自己用 modem 上报物品栏，
---     写进同一个快照（Containers:applyScan ← Transfer.onCrafterInventory）；
---   * 搬运（抽取 / 推送）**一律按快照决策**：快照里没有的东西不搬、已被认领的槽位不碰；
---     拿不到快照 = 直接失败并给出可读原因（不派活、不猜槽位）—— 用户第 2 项：
---     **旧的"盲搬/盲抽"路径已整条移除**，不允许"先随便搬一格再说"这种没有依据的行为。
---   编码规范（用户第 1/3 项）：未定义的行为必须报错，不许静默失败。
function Containers.roleIsReadable(role)
    role = role or "storage"
    return true                    -- 每个角色都会被扫到（海龟由它自己上报，见上）
end

--- 某个容器定义的角色（没有定义时按 storage 处理，与旧配置语义一致）
function Containers:defRole(containerName, kind)
    local def = self.Store and self.Store:findContainer(containerName, kind)
    return (def and def.role) or "storage"
end

--- 这个容器定义能不能被读（true = storage/input；false = interaction/output 或定义不存在）
function Containers:isReadableContainer(containerName, kind)
    local def = self.Store and self.Store:findContainer(containerName, kind)
    if not def then
        return false
    end
    return Containers.roleIsReadable((def.role or "storage"))
end

--- 用户第 2 项：**读守卫已删除** —— 现在每个角色都会被扫到（没扫到的容器由 `hasSnapshot` 挡在
--- 搬运之外：拿不到快照就失败，而不是"读不到就盲搬"）。所以这里不再需要 assertReadable*。

--- 需要被扫描的容器（用户第 2 项）：**任何角色**都会扫 —— storage / input / interaction / output。
--- 返回四条队列的外设名集合（1.9.x：输出容器单独一条队列）：
---   storageScan      storage 角色的容器（仓库、机器输出到仓库的那些）
---   inputScan        input 角色的容器（扫到东西 → 生成入库任务）
---   interactionScan  interaction 角色的容器（机器交互容器：盆、粉碎机…）
---   outputScan       output 角色的容器（机器输出 / 发货目标：抽取产物也按它的快照筛）
--- 排不进队列的（扫不了）只有一种：**没有 inventory / fluid_storage 外设能力**的容器 ——
--- 海龟物品栏就是典型（它不是 inventory 外设）：它由 IFMCrafter 自己上报（见 applyScan +
--- Transfer.onCrafterInventory），不需要也不能由扫描队列去读。
--- 主控的 maintainScanQueues 直接用它来增删扫描任务 —— 规则只写在这一处，便于自测。
function Containers:scanQueueTargets()
    local out = { storageScan = {}, inputScan = {}, interactionScan = {}, outputScan = {} }
    local function bucketOf(role)
        if role == "input" then
            return "inputScan"
        end
        if role == "output" then
            return "outputScan"
        end
        if role == "interaction" then
            return "interactionScan"
        end
        return "storageScan"
    end
    for _, def in ipairs(self.Store:list("containers")) do
        local peripheralName = def.peripheral
        if type(peripheralName) == "string" and peripheralName ~= "" and def.virtual ~= true then
            --- 外设不存在时不排队：外设回来时生成器会重新排
            if self.Peripherals:exists(peripheralName) then
                local kind = (self.Util and self.Util.kindOfDef and self.Util.kindOfDef(def)) or def.kind or "item"
                local scannable
                if kind == "fluid" then
                    scannable = self.Peripherals.isFluid and self.Peripherals:isFluid(peripheralName)
                else
                    scannable = self.Peripherals.isInventory and self.Peripherals:isInventory(peripheralName)
                end
                if scannable then
                    out[bucketOf(def.role or "storage")][peripheralName] = true
                end
            end
        end
    end
    return out
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

--- 日志分级兼容（用户第 2 项）：调用点用 self.log.warn / self.log.error 表达级别，
--- 而老的调用方 / 测试桩传进来的可能只是一个普通函数 —— 这里给它补上两个子入口。
local function levelLogger(fn)
    if type(fn) == "table" and fn.warn ~= nil and fn.error ~= nil then
        return fn                                  -- 已经是分级日志（Util.makeLogger 的产物）
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

function Containers.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Containers)
    self.Util = opts.Util
    self.Peripherals = opts.Peripherals
    self.Store = opts.Store
    self.Filter = opts.Filter
    self.log = levelLogger(opts.log)
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
    self.model = {}                  -- 外设名 -> { slots, tanks, dirtySlots, dirtyTanks, dirtyCount, gen, tick, stamp, scans }
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
    if self.Peripherals:isInventory(def.peripheral) then
        return true
    end
    --- 机械臂（海龟）没有 inventory 外设（用户第 2 项），但它的物品栏能作为 pushItems/pullItems 的
    --- 目标 —— 因此**只允许当交互容器**（role = interaction）用；存储/输出容器必须是真 inventory。
    --- 这也顺带保证了引擎不会去读它的内容物：扫描/快照/堆叠扫描都只走 role = storage（用户第 3 项）。
    return (def.role or "storage") == "interaction" and self.Peripherals:isTurtle(def.peripheral)
end

--- 这个容器有没有内容快照（被扫过一次 / 海龟上报过一次）。
--- 用户第 2/3 项：搬运一律按快照决策 —— 拿不到快照就**直接失败**（不许再"盲搬一格试试"）。
function Containers:hasSnapshot(peripheralName)
    local model = type(peripheralName) == "string" and self.model[peripheralName] or nil
    return model ~= nil and (model.scans or 0) > 0
end

--- 快照里"装着想搬的那件东西"的槽位（同名 + 同 NBT），跳过已被其它任务认领的脏槽位。
--- 返回 slot, entry；找不到返回 nil, nil —— 调用方据此直接失败（绝不猜槽位）。
function Containers:slotForItem(peripheralName, item)
    local wantedName = type(item) == "table" and item.name or nil
    if type(peripheralName) ~= "string" or type(wantedName) ~= "string" or wantedName == "" then
        return nil, nil
    end
    local model = self:modelOf(peripheralName)
    if not model then
        return nil, nil
    end
    local wantedNbt = tostring((type(item) == "table" and item.nbt) or "")
    local best = nil
    for slot, entry in pairs(model.slots) do
        if type(entry) == "table" and entry.name == wantedName and (tonumber(entry.count) or 0) > 0
            and tostring(entry.nbt or "") == wantedNbt
            and not self:isDirtySlot(peripheralName, slot, false) then
            if not best or slot < best then
                best = slot
            end
        end
    end
    if best then
        return best, model.slots[best]
    end
    return nil, nil
end

--- 是否是交互容器（按角色判定；用户第 2 项：交互容器现在**也会被扫描 / 上报**，
--- 抽取与推送都按快照决策，见文件顶部"读取规则"）
function Containers:isInteractionContainer(containerName, kind)
    if type(containerName) ~= "string" or containerName == "" then
        return false
    end
    local def = self.Store and self.Store:findContainer(containerName, kind)
    return def ~= nil and (def.role or "storage") == "interaction"
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
    elseif not self.Peripherals:isInventory(def.peripheral)
        and not ((def.role or "storage") == "interaction" and self.Peripherals:isTurtle(def.peripheral)) then
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
        model = { slots = {}, tanks = {}, dirtySlots = {}, dirtyTanks = {}, dirtyCount = {},
            gen = 0, stamp = 0, scans = 0 }
        self.model[peripheralName] = model
    end
    return model
end

--- ===== 脏标记模型（用户第 7/8/9 项）=====
--- 物品数量快照（model.slots / model.tanks）**只由扫描和"入库完成"来改**：
---   * 从存储容器移出物品：**不**在动手前改快照，而是把"源槽位 + 这部分数量"标成脏（用户第 8 项）；
---   * 往容器放入物品：只把目标槽位标脏（不写数量），搬完后把成功数量加进快照（用户第 9 项）；
---   * 整理（存储容器内部挪动）：快照数量**完全不动**（用户第 7 项：物品还在存储里，只是换格子）。
--- 两条判据：
---   * 「脏槽位」= 这个槽位正被一条在飞任务引用 → 其它任务不得再引用它（出库不能从它拿、入库不能塞进去）；
---   * 「脏物品数量」= 某个物品（同名同 NBT）已经被在飞任务认领的数量 → 可用量 = 数量 - 脏数量。
local DIRTY_TIMEOUT = 30000          -- 脏标记最多活 30 秒（与搬运任务超时一致，防 worker 掉线卡死）

local function itemKeyOf(name, nbt)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name .. "\0" .. tostring(nbt or "")
end

--- 某个槽位/储罐的脏标记（不存在时现场建一个）
function Containers:dirtyMark(model, index, fluid)
    local map = fluid and model.dirtyTanks or model.dirtySlots
    local mark = map[index]
    if not mark then
        mark = { amount = 0, at = os.epoch("utc") }
        map[index] = mark
    end
    return mark
end

function Containers:isDirtySlot(peripheralName, index, fluid)
    if type(peripheralName) ~= "string" or not index then
        return false
    end
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    local map = fluid and model.dirtyTanks or model.dirtySlots
    return map[index] ~= nil
end

--- 清理超时的脏标记（worker 掉线 / 任务丢了回报时，槽位不能永远占着）
function Containers:sweepDirty(model, now)
    if not model then
        return 0
    end
    now = now or os.epoch("utc")
    local removed = 0
    local function sweep(map)
        for index, mark in pairs(map) do
            if now - (mark.at or now) > DIRTY_TIMEOUT then
                map[index] = nil
                removed = removed + 1
            end
        end
    end
    sweep(model.dirtySlots)
    sweep(model.dirtyTanks)
    if removed > 0 then
        self.dirtySwept = (self.dirtySwept or 0) + removed
    end
    return removed
end

--- 解除一个槽位/储罐的脏标记（搬运结束、或清理超时）
function Containers:clearDirty(model, index, fluid)
    if not model or not index then
        return
    end
    if fluid then
        model.dirtyTanks[index] = nil
    else
        model.dirtySlots[index] = nil
    end
end

--- 某个容器里"同名同 NBT"物品的总数量（按快照算，不含脏信息）
function Containers:countInModel(model, name, nbt)
    if not model or type(name) ~= "string" or name == "" then
        return 0
    end
    local total = 0
    local wanted = tostring(nbt or "")
    for _, entry in pairs(model.slots) do
        if entry.name == name and tostring(entry.nbt or "") == wanted then
            total = total + (tonumber(entry.count) or 0)
        end
    end
    return total
end

--- 某个槽位的数量（**快照原值**：不含任何在飞任务的推测；用户第 7/8 项要求快照不被搬运改动）
function Containers:visibleSlotCount(model, slot)
    if not model then
        return 0
    end
    local entry = model.slots[slot]
    return entry and (tonumber(entry.count) or 0) or 0
end

--- 某个储罐的容量（**快照原值**）
function Containers:visibleTankAmount(model, tank)
    if not model then
        return 0
    end
    local entry = model.tanks[tank]
    return entry and (tonumber(entry.amount) or 0) or 0
end

--- 物品槽位表：{ [slot] = { name, count, nbt } }（**快照原值**：在飞任务不改它 —— 用户第 7/8 项）
function Containers:visibleSlots(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for slot, entry in pairs(model.slots) do
        local count = tonumber(entry.count) or 0
        if count > 0 and entry.name then
            out[slot] = { name = entry.name, count = count, nbt = entry.nbt }
        end
    end
    return out
end

--- 流体罐表：{ [tank] = { name, amount } }（快照原值）
function Containers:visibleTanks(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for tank, entry in pairs(model.tanks) do
        local amount = tonumber(entry.amount) or 0
        if amount > 0 and entry.name then
            out[tank] = { name = entry.name, amount = amount }
        end
    end
    return out
end

--- 入库预留（用户第 9 项）：派任务**之前**只把目标槽位标成脏 —— **不写任何数量**。
--- 于是同一 tick 里其它入库任务不会再挑这个槽位（已被占），而数量快照保持不动；
--- 搬运结束后由 settleMove 把成功入库的数量加进快照并解除脏标记。
function Containers:reserveIn(peripheralName, index, want, kind, name, nbt)
    local model = self:modelOf(peripheralName)
    if not model or not index then
        return 0
    end
    local amount = math.max(0, tonumber(want) or 0)
    if amount <= 0 then
        return 0
    end
    local fluid = kind == "fluid"
    local existing = fluid and model.dirtyTanks[index] or model.dirtySlots[index]
    if existing and existing.kind == "out" then
        return 0                            -- 有出库任务在用它：本轮不收（避免边出边进撞在一起）
    end
    local mark = self:dirtyMark(model, index, fluid)
    mark.kind = "in"
    mark.amount = amount
    mark.at = os.epoch("utc")
    return amount
end

--- 出库预留（用户第 8 项）：动手前**不改快照**，只把"源槽位 + 这部分数量"标成脏。
--- 两条限制同时生效：
---   * 脏槽位不能再被引用（一个槽位不能有两条在飞出库任务）；
---   * 可用量 = 该物品的快照数量 - 已被认领的脏数量（跨槽位也不会超发）。
--- 返回真正预留到的数量（可能是 0）。
function Containers:reserveOut(peripheralName, index, want, kind)
    local model = self:modelOf(peripheralName)
    if not model or not index then
        return 0
    end
    local fluid = kind == "fluid"
    local existing = fluid and model.dirtyTanks[index] or model.dirtySlots[index]
    if existing and existing.kind == "in" then
        return 0                            -- 有入库任务正往这里放：本轮不从它拿
    end
    local entry = fluid and model.tanks[index] or model.slots[index]
    local base = fluid and self:visibleTankAmount(model, index) or self:visibleSlotCount(model, index)
    local claimedHere = (existing and existing.kind == "out") and (existing.amount or 0) or 0
    local slotFree = base - claimedHere
    local itemFree = math.huge
    if not fluid and entry and entry.name then
        local key = itemKeyOf(entry.name, entry.nbt)
        local claimed = (key and model.dirtyCount[key]) or 0
        itemFree = self:countInModel(model, entry.name, entry.nbt) - claimed
    end
    local amount = math.max(0, math.min(tonumber(want) or 0, slotFree, itemFree))
    if amount <= 0 then
        return 0
    end
    local mark = self:dirtyMark(model, index, fluid)
    mark.kind = "out"
    mark.amount = claimedHere + amount
    mark.at = os.epoch("utc")
    if not fluid and entry and entry.name then
        local key = itemKeyOf(entry.name, entry.nbt)
        if key then
            model.dirtyCount[key] = (model.dirtyCount[key] or 0) + amount
        end
    end
    return amount
end

--- 存储容器内部的挪动（整理）不该改数量快照：两端都是 storage 角色的物品容器（用户第 7 项）。
function Containers:countedMove(request)
    local kind = request.kind or "item"
    local from = self.Store and self.Store:findContainer(request.from, kind)
    local to = self.Store and self.Store:findContainer(request.to, kind)
    if from and to and (from.role or "storage") == "storage" and (to.role or "storage") == "storage" then
        return false
    end
    return true
end

--- 直接把数量变动写进快照（物品按槽位条目，流体按储罐；搬空了就把条目删掉，和扫描结果一致）
function Containers:applyCount(model, index, delta, fluid, name, nbt)
    if not model or not index or not delta or delta == 0 then
        return
    end
    local entry = fluid and model.tanks[index] or model.slots[index]
    if not entry then
        if delta <= 0 then
            return
        end
        if not fluid and (type(name) ~= "string" or name == "") then
            return
        end
        entry = fluid and { name = name, amount = 0 } or { name = name, count = 0, nbt = nbt }
        if fluid then
            model.tanks[index] = entry
        else
            model.slots[index] = entry
        end
    end
    if fluid then
        entry.amount = math.max(0, (tonumber(entry.amount) or 0) + delta)
    else
        entry.count = math.max(0, (tonumber(entry.count) or 0) + delta)
        if entry.count <= 0 then
            model.slots[index] = nil
        end
    end
end

--- 结算一条搬运（用户第 7/8/9 项）：
---   * 解除两侧槽位的脏标记；
---   * 出库侧扣掉这条任务认领的脏数量（没搬完的差额自动归还）；
---   * 数量快照：存储容器内部挪动（整理）**完全不动**（第 7 项）；跨角色（存储 ↔ 交互/输出）才更新 ——
---     出库侧减去实际搬走量、入库侧加上成功入库量（第 9 项）。
function Containers:settleMove(request, moved)
    if type(request) ~= "table" then
        return
    end
    local movedCount = math.max(0, tonumber(moved) or 0)
    local fluid = request.kind == "fluid"
    local counted = self:countedMove(request)
    local fromModel = self:modelOf(request.from)
    if fromModel and request.fromIndex then
        self:clearDirty(fromModel, request.fromIndex, fluid)
        if not fluid then
            local key = itemKeyOf(request.item, request.nbt)
            if key and fromModel.dirtyCount[key] then
                fromModel.dirtyCount[key] = math.max(0,
                    fromModel.dirtyCount[key] - (tonumber(request.reserved) or 0))
                if fromModel.dirtyCount[key] <= 0 then
                    fromModel.dirtyCount[key] = nil
                end
            end
        end
        if counted then
            self:applyCount(fromModel, request.fromIndex, -movedCount, fluid, request.item, request.nbt)
        end
    end
    local toModel = self:modelOf(request.to)
    if toModel and request.toIndex then
        self:clearDirty(toModel, request.toIndex, fluid)
        if counted and movedCount > 0 then
            self:applyCount(toModel, request.toIndex, movedCount, fluid, request.item, request.nbt)
        end
    end
    self.moveSettleCount = (self.moveSettleCount or 0) + 1
end

--- 记一次"worker 扫不到这个容器"的回报（用户第 4 项）：**不写快照**，只计数 + 打日志。
function Containers:noteBlindScan(peripheralName, reason)
    self.blindScans = (self.blindScans or 0) + 1
    local seen = self.blindScanSeen
    if not seen then
        seen = {}
        self.blindScanSeen = seen
    end
    if not seen[peripheralName] and (self.blindScanLogged or 0) < 8 then
        seen[peripheralName] = true
        self.blindScanLogged = (self.blindScanLogged or 0) + 1
        --- 措辞要准：以前写"worker 看不到这个容器"，害得人以为是接线问题。
        --- 实际可能只是"回报里 scanned=0"（worker 确实没读到）或字段缺失（版本不匹配，见
        --- IFMMaster.onQueryResult 的 noteScanProtocolMismatch）。
        self.log("Scan result for %s discarded (%s); keeping the previous snapshot",
            tostring(peripheralName), tostring(reason or "worker reported scanned=0"))
    end
    return self.blindScans
end

--- 从 worker 的查询回报里取"扫到了几个容器"（主控与自测共用）：
---   * 新 worker 报数值 `scanned`；
---   * 1.8.2 及以前的 worker 只报 `scannedContainers` 表（#表 = 扫到几个）；
---   * 两者都没有 = 协议不匹配 → 返回 nil（调用方必须报错式处理，绝不能静默当成"盲"）。
function Containers.scanCountOfReply(message)
    if type(message) ~= "table" then
        return nil
    end
    local scanned = tonumber(message.scanned)
    if scanned ~= nil then
        return scanned
    end
    local list = message.scannedContainers
    if type(list) == "table" then
        return #list
    end
    return nil
end

--- 扫描回报里没有可判定的字段（既没有 scanned 也没有 scannedContainers）：
--- 这是 worker 与主控的版本不匹配。**不许静默当成"盲"** —— 以前每一次成功的扫描都被
--- 当成"没扫到"丢掉，快照永远不更新、扫描队列永久空转（用户现场：staleAvg=661 ticks）。
function Containers:noteScanProtocolMismatch(peripheralName, detail)
    self.scanProtocolMismatch = (self.scanProtocolMismatch or 0) + 1
    local seen = self.scanProtocolMismatchSeen
    if not seen then
        seen = {}
        self.scanProtocolMismatchSeen = seen
    end
    if not seen[peripheralName] and (self.scanProtocolMismatchLogged or 0) < 8 then
        seen[peripheralName] = true
        self.scanProtocolMismatchLogged = (self.scanProtocolMismatchLogged or 0) + 1
        self.log("Scan result for %s has no usable 'scanned' field (%s): worker and master builds differ" ..
            " (copy the same build to every computer); result discarded",
            tostring(peripheralName), tostring(detail or "no scanned / scannedContainers"))
    end
    return self.scanProtocolMismatch
end

--- 扫描结果是权威基准：写入 slots/tanks（nil 表示这次没扫这一类，保持原样），
--- 并把"已经结算过、而且结算发生在这次扫描开始之前"的乐观变更丢掉。
--- 顺便把"扫描时看到过的物品"记进 self.scanSeen（生成器据此补物品详情任务）。
function Containers:applyScan(peripheralName, items, tanks, scanStartedAt, size)
    local model = self:modelOf(peripheralName)
    if not model then
        return false
    end
    local started = tonumber(scanStartedAt) or os.epoch("utc")
    model.scans = (model.scans or 0) + 1
    model.stamp = os.epoch("utc")
    model.gen = (model.gen or 0) + 1
    model.tick = self.tickCount or 0
    --- 用户第 4 项：海龟上报时会带上自己物品栏的**格数** —— 它不是 inventory 外设，
    --- 主控问不到 size()，而挑目标槽位（insertSlotFor / slotCount）必须知道有多少格。
    local slotTotal = tonumber(size)
    if slotTotal and slotTotal > 0 then
        model.size = math.floor(math.min(slotTotal, MAX_CONTAINER_SLOTS))
    end
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
    --- 脏标记清理（用户第 8/9 项）：超时没结算的（worker 掉线 / 回报丢了）槽位要还回来，
    --- 否则那个槽位会被永远占着。正常路径由 settleMove 解除，这里只是兜底。
    self:sweepDirty(model)
    return true
end

--- 快照统计（诊断用）：脏槽位 / 脏数量 / 已结算 / 被兜底清理 / 在飞搬运 / 待领取结果
function Containers:snapshotSummary()
    local dirtySlots, dirtyItems = 0, 0
    local containersWithDirty = 0
    for _, model in pairs(self.model) do
        local has = false
        for _ in pairs(model.dirtySlots or {}) do
            dirtySlots = dirtySlots + 1
            has = true
        end
        for _ in pairs(model.dirtyTanks or {}) do
            dirtySlots = dirtySlots + 1
            has = true
        end
        for _ in pairs(model.dirtyCount or {}) do
            dirtyItems = dirtyItems + 1
            has = true
        end
        if has then
            containersWithDirty = containersWithDirty + 1
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
        dirtySlots = dirtySlots,
        dirtyCounts = dirtyItems,
        dirtyContainers = containersWithDirty,
        --- 丢掉"扫到 0 个容器"的回报次数（worker 真的没读到那个容器）
        blindScans = self.blindScans or 0,
        --- 丢掉"回报里没有可判定字段"的次数（worker 与主控版本不一致；>0 一定要处理）
        scanProtocolMismatch = self.scanProtocolMismatch or 0,
        settled = self.moveSettleCount or 0,
        swept = self.dirtySwept or 0,
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

--- 放弃一条搬运记录（队列策略是"失败即丢弃"时用）：按"一个也没搬走"结算并归还剩余预留，
--- 记录从在飞表里摘掉（下次扫描会重新生成搬运任务）。
--- 为什么要它：不这么做的话，被丢弃的记录会一直挂在在飞表里占着预留，直到 60 秒的兜底清理 ——
--- 那段时间里这批物品既不会被重新生成任务、也从可见数量里消失（看起来像"东西丢了"）。
function Containers:abandonMove(record)
    if type(record) ~= "table" or not record.key then
        return false
    end
    if self.moveInflight[record.key] ~= record then
        return false
    end
    self:settleMove(record, 0)
    self.moveInflight[record.key] = nil
    self.dirty[record.from] = true
    self.dirty[record.to] = true
    return true
end

--- 用户第 2 项：盲源重试/退避机制（MAX_BLIND_RETRIES）**已随盲路径一起删除** ——
--- 现在每个容器都有内容快照，"按快照判有没有货"是可靠的，所以失败就是失败（sourceShortage 判定后丢弃）。
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
        self.log.warn("Move dropped (source empty) (%s -> %s): %s", tostring(record.from), tostring(record.to),
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
        self.log.warn("Move dropped (no visible source left) (%s -> %s): %s", tostring(record.from),
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














--- 这次搬运该由谁"动手"（用户第 1 项：**按外设类型直接判断，不靠失败重试**）。
---   * 海龟（turtle）不是 inventory 外设：对它调用 pushItems / pullItems 都是白费
---     （现场日志 `attempt to call a nil value` 就是这么来的）。
---     要搬它物品栏里的东西，必须由**对面那个 inventory** 来拉：`container.pullItems(turtle, …)`。
---   * 规则：源侧具备该能力（物品=inventory / 流体=fluid_storage）→ actor = "from"
---           （源 pushItems/pushFluid 到目标）；否则 → actor = "to"（目标侧 pullItems/pullFluid 从源拉）。
function Containers:moveActorOf(peripheralName, kind)
    local Peripherals = self.Peripherals
    if not (Peripherals and peripheralName) then
        return "from"
    end
    local canAct
    if kind == "fluid" then
        canAct = Peripherals.isFluid and Peripherals:isFluid(peripheralName)
    else
        canAct = Peripherals.isInventory and Peripherals:isInventory(peripheralName)
    end
    return canAct and "from" or "to"
end

--- sourceItem（用户第 2 项，可选）：这次想抽的物品 { name = ..., nbt = ... }。
--- 盲源（海龟这类没有 inventory 外设的交互容器）主控看不到内容物，抽它必须由对面
--- pullItems(海龟, **槽位**, ...)，而 pullItems 的槽位是必填的 —— 槽位靠海龟上报的物品栏查（见
--- setInventoryProvider / Transfer:crafterSlotFor）。
function Containers:pushItem(fromContainer, fromSlot, limit, toContainer, toSlot, mode, queueName, sourceItem)
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
    --- 用户第 2/3 项（1.9.0）：**一律按快照决策** —— "盲搬/盲抽"整条路径已删除。
    ---   * 源必须有内容快照（扫描 / 海龟上报），拿不到 → 直接失败（返回可读原因，不派活、不猜槽位）；
    ---   * 槽位：优先用调用方给的（它通常来自快照）；没给就用 sourceItem 在快照里找
    ---     （同名 + 同 NBT）；找不到 → 直接失败；
    ---   * 调用方同时给了槽位与"要搬的物品"时，核对快照里的那一条（不符就拒绝，不硬搬）。
    if not self:hasSnapshot(fromPeripheral) then
        return 0, "\\u6E90\\u5BB9\\u5668\\u8FD8\\u6CA1\\u6709\\u5185\\u5BB9\\u5FEB\\u7167\\uFF08\\u7B49\\u626B\\u63CF/\\u6D77\\u9F9F\\u4E0A\\u62A5\\uFF09\\uFF0C\\u4E0D\\u731C\\u69FD\\u4F4D\\u3001\\u4E0D\\u6D3E\\u6D3B"
    end
    local resolvedSlot = tonumber(fromSlot)
    local source = nil
    if resolvedSlot and resolvedSlot >= 1 then
        source = self:stackAt(fromContainer, resolvedSlot)
    else
        resolvedSlot, source = self:slotForItem(fromPeripheral, sourceItem)
    end
    if not resolvedSlot then
        return 0, "\\u5FEB\\u7167\\u91CC\\u6CA1\\u6709\\u8981\\u642C\\u7684\\u90A3\\u79CD\\u7269\\u54C1\\uFF08\\u7B49\\u4E0B\\u4E00\\u6B21\\u626B\\u63CF/\\u6D77\\u9F9F\\u4E0A\\u62A5\\uFF09"
    end
    local explicitSlot = (tonumber(toSlot) or -1) >= 1 and tonumber(toSlot) or nil
    --- 目标角色（用户第 2/3 项）：输出 / 交互容器的目标槽位**总是**由快照决定 ——
    --- 推送前必须先标脏，所以必须先知道是哪一格；定不出槽位就失败，绝不"交给游戏自己找"。
    local targetRole = self:defRole(toContainer, "item")
    local needsSlot = (targetRole == "interaction" or targetRole == "output")
    local autoSlot = nil
    if not explicitSlot and fromPeripheral ~= toPeripheral then
        local itemName = source and source.name or (type(sourceItem) == "table" and sourceItem.name) or nil
        local itemNbt = source and source.nbt or (type(sourceItem) == "table" and sourceItem.nbt) or nil
        if itemName and (needsSlot or mode) then
            --- insertSlotFor 只在这两类槽里挑（用户第 3 项）：**同名 + 同 NBT** 的槽，或**空槽**；
            --- 并且跳过所有脏槽位。mode 只决定偏好顺序（填满 / 少碎片），不决定"要不要选槽位"。
            autoSlot = self:insertSlotFor(toContainer, itemName, itemNbt, limit, mode or self.INSERT_SPEED)
        end
    end
    local chosenSlot = explicitSlot or autoSlot
    --- 输出 / 交互容器：定不出目标槽位 = 直接失败（不许派一条"搬进不知道哪一格"的活，
    --- 否则结算时无法按实际成功数更新快照 —— 见 Containers:settleMove）。
    if needsSlot and not chosenSlot then
        if not self:hasSnapshot(toPeripheral) then
            return 0, "\\u76EE\\u6807\\u5BB9\\u5668\\u8FD8\\u6CA1\\u6709\\u5185\\u5BB9\\u5FEB\\u7167\\uFF08\\u7B49\\u626B\\u63CF/\\u6D77\\u9F9F\\u4E0A\\u62A5\\uFF09\\uFF0C\\u4E0D\\u731C\\u69FD\\u4F4D\\u3001\\u4E0D\\u6D3E\\u6D3B"
        end
        return 0, "\\u76EE\\u6807\\u5BB9\\u5668\\u91CC\\u6CA1\\u6709\\u53EF\\u7528\\u7684\\u69FD\\u4F4D\\uFF08\\u540C\\u540D\\u540C NBT \\u7684\\u69FD\\u4E0E\\u7A7A\\u69FD\\u90FD\\u88AB\\u5360\\u7528\\u6216\\u5DF2\\u88AB\\u8BA4\\u9886\\uFF09"
    end
    local wantsSlot = chosenSlot ~= nil and chosenSlot ~= resolvedSlot
    if fromPeripheral == toPeripheral and not wantsSlot then
        return 0, samePeripheralReason(fromContainer, toContainer, fromPeripheral)
    end
    local key = table.concat({ "item", fromPeripheral, tostring(resolvedSlot), tostring(limit),
        toPeripheral, tostring(chosenSlot or -1) }, "|")
    --- 先看这条搬运是不是已经有结果 / 还在飞：键只用"源槽位 + 目标槽位 + 数量"，
    --- 所以**必须**在"快照里还有没有这一条"之前查 —— 上一次已经把它搬走、快照里那一格也空了的时候，
    --- 调用方（流程的 resumePendingMove）仍然要能取回那次结果，否则产物计数永远补不上、流程会卡死。
    local result = self:takeMoveResult(key)
    if result then
        return result.moved, result.err
    end
    if self.moveInflight[key] then
        return nil, "pending"
    end
    --- 到这里才是"要不要新派一条"：没有源条目 = 快照里没有那种物品（或那一格已经被搬空了）
    if not source or (tonumber(source.count) or 0) <= 0 then
        return 0, "\\u5FEB\\u7167\\u91CC\\u6CA1\\u6709\\u8981\\u642C\\u7684\\u90A3\\u79CD\\u7269\\u54C1\\uFF08\\u7B49\\u4E0B\\u4E00\\u6B21\\u626B\\u63CF/\\u6D77\\u9F9F\\u4E0A\\u62A5\\uFF09"
    end
    if type(sourceItem) == "table" and type(sourceItem.name) == "string" and sourceItem.name ~= "" then
        local wantNbt = tostring(sourceItem.nbt or "")
        if source.name ~= sourceItem.name or tostring(source.nbt or "") ~= wantNbt then
            return 0, string.format("\\u6E90\\u69FD\\u4F4D\\u91CC\\u7684\\u7269\\u54C1\\u4E0E\\u8981\\u642C\\u7684\\u4E0D\\u7B26\\uFF08\\u5FEB\\u7167=%s\\uFF0C\\u8981\\u6C42=%s\\uFF09",
                tostring(source.name), tostring(sourceItem.name))
        end
    end
    --- 出库预留（用户第 3/8 项）：只把"源槽位 + 这部分数量"标脏，不动快照数量 ——
    --- 同一槽位不会被两条在飞任务同时抽，也不会超过快照里的可用量。
    --- 注意：**不要**在这里另外判 isDirtySlot —— reserveOut 自己会处理（同向累加、异向拒绝、
    --- 数量扣减），另判一次会把"同一物品的剩余量"也一起拒掉（等于槽位被半张单占死后就再也用不了）。
    local visible = tonumber(source.count) or 0
    local reserved = self:reserveOut(fromPeripheral, resolvedSlot, math.min(limit, visible), "item")
    if reserved <= 0 then
        return 0, "\\u6E90\\u69FD\\u4F4D\\u6CA1\\u6709\\u53EF\\u642C\\u7684\\u7269\\u54C1"
    end
    local record = {
        key = key, kind = "item", action = "push_item",
        from = fromPeripheral, fromIndex = resolvedSlot, to = toPeripheral, toIndex = chosenSlot,
        reserved = reserved, limit = limit, mode = mode,
        --- 用户第 2/3 项：输出 / 交互容器的目标槽位是"先标脏、再派活"的 ——
        --- 记录里带上这个标记，runItemMove 就不会在失败时改用 toSlot = nil 重试
        --- （那会把东西搬进我们不知道的格子，结算时没法按实际成功数更新快照）。
        targetNeedsSlot = needsSlot,
        --- 谁来执行这次搬运（按外设类型定，见 moveActorOf）：海龟这类"源侧不能动手"的
        --- 情况由目标侧的 inventory 来拉（container.pullItems(turtle, …)）
        actor = self:moveActorOf(fromPeripheral, "item"),
        item = source.name, nbt = source.nbt,
    }
    --- 入库槽位预留（用户第 3 项）：定好目标槽位之后、真正派任务之前先占位 + 标脏目标槽位 ——
    --- 同一 tick 里其它入库任务不会再把东西往同一个槽位塞（推送物品同样设置脏槽位标记）。
    if chosenSlot then
        self:reserveIn(toPeripheral, chosenSlot, reserved, "item", source.name, source.nbt)
    end
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
            --- 谁来执行（按外设类型定，见 moveActorOf）
            actor = record.actor,
        })
        if state == "pending" then
            return nil, "pending"
        end
        if state == "done" and (tonumber(moved) or 0) > 0 then
            return moved, err
        end
        --- 用户第 2/3 项：输出 / 交互容器的目标槽位是"先标脏再派活"的 ——
        --- 这条兜底重试（换成 toSlot = nil = 让游戏自己找）对它们**必须禁用**：
        --- 那会把东西搬进我们不知道的格子，结算时没法按实际成功数更新快照。
        --- 这类目标失败就失败（返回原因，调用方下一轮用新快照重来）。
        if state == "done" and chosenSlot and chosenSlot ~= fromSlot and not record.targetNeedsSlot then

            local retryState, retryMoved, retryErr = self.transfer:request({
                action = "push_item", from = fromPeripheral, fromSlot = fromSlot,
                limit = limit, to = toPeripheral, toSlot = nil,
                actor = record.actor,
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
    return self:pushItemLocal(fromPeripheral, fromSlot, limit, toPeripheral, chosenSlot, record)
end

--- 本机直接把物品从 fromSlot 推到 toPeripheral（主控没有 worker 可用时走这里）。
--- 1.8.0：它被主控的协程池调用（Transfer:submitLocalJob → transfer.executeLocal），
--- 所以一次调用只做“发起 + 等 1 个游戏刻”，多个容器可以同时进行（不像以前那样串行阻塞）。
function Containers:pushItemLocal(fromPeripheral, fromSlot, limit, toPeripheral, chosenSlot, record)
    local targetSlot = (tonumber(chosenSlot) or -1) >= 1 and chosenSlot or nil
    --- 谁动手（按外设类型定）：海龟不是 inventory，只能由对面的容器 pullItems 把东西拉出来
    local actor = (record and record.actor) or self:moveActorOf(fromPeripheral, "item")
    if actor == "to" then
        local targetInv = self:inventory(toPeripheral)
        if not targetInv then
            return 0, tostring(toPeripheral) .. " \\u4E0D\\u662F\\u7269\\u54C1\\u5BB9\\u5668"
                .. "\\uFF08\\u65E0\\u6CD5\\u4ECE " .. tostring(fromPeripheral) .. " \\u62C9\\u53D6\\uFF09"
        end
        local ok, moved = pcall(targetInv.pullItems, fromPeripheral, fromSlot, limit, targetSlot)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        return 0, ok and "\\u672A\\u80FD\\u642C\\u8FD0\\u4EFB\\u4F55\\u7269\\u54C1" or tostring(moved)
    end
    local inv = self:inventory(fromPeripheral)
    if not inv then
        return 0, "\\u6765\\u6E90 " .. tostring(fromPeripheral) .. " \\u4E0D\\u662F\\u7269\\u54C1\\u5BB9\\u5668"
    end
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
    --- 兜底：选定的目标槽位放不下 / 打不开时，换成"让游戏自己找一格"再试一次。
    --- 用户第 2/3 项：输出 / 交互容器**不允许**这条兜底（那样会搬进不知道的格子，
    --- 结算时无法按实际成功数更新快照）—— 它们失败就失败，调用方用新快照重来。
    local allowSlotlessRetry = not (record and record.targetNeedsSlot)
    if allowSlotlessRetry and ok and targetSlot and targetSlot ~= fromSlot then
        local ok3, moved3 = pcall(inv.pushItems, toPeripheral, fromSlot, limit, nil)
        if ok3 and type(moved3) == "number" and moved3 > 0 then
            if record then
                record.toIndex = nil
            end
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

    local function inSlot(peripheralName, slot)
        if not peripheralName or not slot then
            return true
        end
        --- 脏槽位不能再被引用（用户第 8/9 项：出库不从它拿、入库不塞进去）
        return not self:isDirtySlot(peripheralName, slot, false)
    end
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
        if not inSlot(peripheralName, slot) then
            free = nil                       -- 脏槽位：本轮不选它（用户第 9 项：目标槽位先占住）
        elseif stack == nil then
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

    --- 用户第 2/3 项：源必须有内容快照（扫描 / 海龟上报），并且快照里确实有这种流体 ——
    --- 拿不到快照 / 快照里没有 → 直接失败（"盲抽储罐"路径已随盲路径一起删除）。
    if not self:hasSnapshot(fromPeripheral) then
        return 0, "\\u6E90\\u5BB9\\u5668\\u8FD8\\u6CA1\\u6709\\u5185\\u5BB9\\u5FEB\\u7167\\uFF08\\u7B49\\u626B\\u63CF/\\u6D77\\u9F9F\\u4E0A\\u62A5\\uFF09\\uFF0C\\u4E0D\\u731C\\u50A8\\u7F50\\u3001\\u4E0D\\u6D3E\\u6D3B"
    end
    local bestTank, reserved = nil, 0
    local visible = self:visibleTanks(fromPeripheral)
    local bestAmount = 0
    for tank, entry in pairs(visible) do
        --- 已被其它任务认领的储罐不碰（用户第 3 项：抽取前标脏、脏的不抽）
        if entry.name == fluidName and entry.amount > bestAmount
            and not self:isDirtySlot(fromPeripheral, tank, true) then
            bestTank, bestAmount = tank, entry.amount
        end
    end
    if not bestTank or bestAmount <= 0 then
        return 0, "\\u6E90\\u5BB9\\u5668\\u91CC\\u6CA1\\u6709\\u8FD9\\u79CD\\u6D41\\u4F53"
    end
    reserved = self:reserveOut(fromPeripheral, bestTank, math.min(limit, bestAmount), "fluid")
    if reserved <= 0 then
        return 0, "\\u6E90\\u5BB9\\u5668\\u91CC\\u6CA1\\u6709\\u8FD9\\u79CD\\u6D41\\u4F53"
    end
    local record = {
        key = key, kind = "fluid", action = "push_fluid",
        from = fromPeripheral, fromIndex = bestTank, to = toPeripheral, toIndex = nil,
        reserved = reserved, limit = limit, item = fluidName,
        --- 用户第 2 项：流体**从不指定槽位**（流程里的"输入/输出流体槽位"参数已移除）——
        --- 目标容器是 to（已知），但目标**储罐**由游戏自己选，我们不可能知道它落在哪个罐。
        --- 因此这里不猜罐位：结算（settleMove）只按实际成功数扣减**源罐**，同时把目标容器
        --- 标记为需要重扫（executeMove 设 self.dirty[to]）——下一次交互/输出扫描用权威内容
        --- 把目标容器的储罐快照纠正回来。
        targetTankUnknown = true,
        --- 谁来执行（按外设类型定，见 moveActorOf）：源侧没有流体储罐就由目标侧 pullFluid
        actor = self:moveActorOf(fromPeripheral, "fluid"),
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
    return self:pushFluidLocal(fromPeripheral, toPeripheral, limit, fluidName)
end

--- 本机直接把流体从 fromPeripheral 推到 toPeripheral（主控没有 worker 可用时走这里；
--- 1.8.0 起由 Transfer 的本机协程池调用，见 Containers:pushItemLocal 的说明）。
function Containers:pushFluidLocal(fromPeripheral, toPeripheral, limit, fluidName)
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

--- 主控本机执行一条搬运（给 Transfer 的本机协程池用，参数与发给 worker 的任务一致）。
--- 返回 实际搬运数量, 失败原因。
function Containers:runLocalJob(job)
    if type(job) ~= "table" then
        return 0, "bad job"
    end
    if job.action == "push_fluid" then
        return self:pushFluidLocal(job.from, job.to, tonumber(job.limit) or 1, job.fluid)
    end
    if job.action == "push_item" then
        return self:pushItemLocal(job.from, job.fromSlot, tonumber(job.limit) or 1, job.to,
            job.toSlot, nil)
    end
    return 0, "unknown action " .. tostring(job.action)
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


--- 还有哪些外设被容器定义引用着（虚拟定义也算：store:list("containers") 会带上它们）。
--- 用来判断"某个外设读到的东西还该不该留着"：没有定义引用它 = 它已经不是 IFM 的容器了。
function Containers:referencedPeripherals()
    local out = {}
    if not self.Store or type(self.Store.list) ~= "function" then
        return out
    end
    for _, def in ipairs(self.Store:list("containers")) do
        local peripheralName = def and def.peripheral
        if type(peripheralName) == "string" and peripheralName ~= "" then
            out[peripheralName] = true
        end
    end
    return out
end

--- 立即忘掉从某个外设读到的东西（用户第 3 项）：内容模型（槽位/储罐 + 脏标记）、
--- 槽位数量缓存、以及引用它的在飞搬运（源/目标都没了 → 按"一个也没搬走"结算，把预留还回去）。
--- 为什么要它：容器外设被移除后，模型里的旧内容会一直留着 —— 整理计划、槽位数量、
--- "容器管理"面板都会继续按旧内容算账（看起来就是"之前读到的物品没有清除"）。
function Containers:forgetPeripheral(peripheralName, reason)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    local forgot = false
    if self.model[peripheralName] ~= nil then
        self.model[peripheralName] = nil
        forgot = true
    end
    self.slotCountCache = self.slotCountCache or {}
    if self.slotCountCache[peripheralName] ~= nil then
        self.slotCountCache[peripheralName] = nil
        forgot = true
    end
    if self.scanStats and self.scanStats[peripheralName] then
        self.scanStats[peripheralName] = nil
    end
    if self.capacityCache then
        self.capacityCache = nil
    end
    --- 在飞搬运：源或目标已经没了，这条任务不可能再成功 —— 按"没搬走"结算并摘掉
    --- （不摘的话它会一直占着预留，直到 60 秒的兜底清理）
    for key, record in pairs(self.moveInflight or {}) do
        if record.from == peripheralName or record.to == peripheralName then
            self:settleMove(record, 0)
            self.moveInflight[key] = nil
        end
    end
    self.dirty[peripheralName] = nil
    if forgot then
        self.forgotten = (self.forgotten or 0) + 1
        self.snapshots = {}
        self.log("Forgot cached contents of %s (%s)", peripheralName, tostring(reason or "container removed"))
    end
    return forgot
end

--- 清空某个容器**读到的内容**（用户第 2 项）：连续多次"读不到"之后不能再留着旧内容 ——
--- 否则网页上会一直显示早就被拿走的物品（现场：容器里 64 个沙子一次全拿走，数量停在 64）。
--- 只清内容（槽位 / 储罐），保留模型、槽位数缓存与在飞搬运：
--- 搬运失败由 settleMove / 60 秒兜底清理处理，下一次成功扫描会把内容重新读回来。
function Containers:clearSnapshot(peripheralName, reason)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    local model = self:modelOf(peripheralName)
    if not model then
        return false
    end
    model.slots = {}
    model.tanks = {}
    model.stamp = os.epoch("utc")
    model.gen = (model.gen or 0) + 1
    model.cleared = (model.cleared or 0) + 1
    self.snapshots = {}                 -- 聚合缓存（resources / snapshot）立刻作废
    self.log("Cleared the cached contents of %s (%s) - nothing could be read from it for a while" ..
        " (check whether it is empty, or whether that peripheral is reachable)",
        tostring(peripheralName), tostring(reason or "unreadable"))
    return true
end

--- 清理"已经读不到的容器"：外设不在网络上，或者没有任何容器定义再引用它（定义被删 / 换外设）。
--- 返回清掉的外设数量（调用方据此决定要不要立刻把这些变化推给网页）。
function Containers:pruneMissingPeripherals(reason)
    local referenced = self:referencedPeripherals()
    --- 先记下名字再逐个清理：清理过程中（结算在飞搬运）会按需创建别的外设的空模型，
    --- 那不算"读到的内容"，也不该在遍历中顺手删掉。
    local names = {}
    for peripheralName in pairs(self.model or {}) do
        names[#names + 1] = peripheralName
    end
    local dropped = 0
    for _, peripheralName in ipairs(names) do
        local gone = not self.Peripherals:exists(peripheralName)
        if gone or not referenced[peripheralName] then
            if self:forgetPeripheral(peripheralName, reason) then
                dropped = dropped + 1
            end
        end
    end
    return dropped
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




--- ===== 槽位堆叠上限（"堆数"）扫描（1.8.0，用户第 5 项）=====
--- 整理计划需要知道"每个物品一组能装多少（maxCount）"才能算目标槽位还能塞多少个。
--- 以前是**规划过程中**现场问 getItemDetail：既阻塞主控，又因为要等 worker 回报把计划拖成好几轮；
--- 没扫到的还会按 64 猜（`DEFAULT_ITEM_MAX_COUNT`）→ 可能搬错数量。
--- 现在：专门的 `stackScan` 队列按容器扫"槽位堆叠上限"，结果进物品详情字典（`cachedItemDetail`），
--- 计划只读字典 —— 没扫到的物品/槽位**直接跳过**（宁可不整理，也不猜）。
--- 返回这个容器里"已经知道堆叠上限"与"还不知道"的槽位数量（诊断 / 计划用）。
function Containers:stackScanStatus(containerName)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return { known = 0, unknown = 0, slots = 0 }
    end
    local known, unknown = 0, 0
    for _, stack in pairs(self:listPeripheral(peripheralName)) do
        if type(stack) == "table" and type(stack.name) == "string" and stack.name ~= "" then
            if self:stackLimitOf(stack.name, stack.nbt) then
                known = known + 1
            else
                unknown = unknown + 1
            end
        end
    end
    return {
        known = known,
        unknown = unknown,
        slots = self:slotCount(peripheralName),
    }
end

--- 槽位堆叠上限（这个物品一组能装多少）：只查物品详情字典（不现场问外设）。
--- 返回 nil = 还没被 stackScan 队列扫到 → 调用方（整理计划）要跳过它。
function Containers:stackLimitOf(itemName, nbt)
    if type(itemName) ~= "string" or itemName == "" then
        return nil
    end
    local known = self.itemMaxCountCache and self.itemMaxCountCache[itemName]
    if known then
        return known
    end
    local detail, cached = self:cachedItemDetail(itemName, nbt)
    if not cached then
        return nil
    end
    local value = tonumber(detail and detail.maxCount)
    if not value or value <= 0 then
        return nil
    end
    self.itemMaxCountCache = self.itemMaxCountCache or {}
    if not self.itemMaxCountCache[itemName] then
        --- 记一笔"又知道了一种物品的堆叠上限"：自动整理用它判断"输入变了，可以重新规划"
        self.stackLimitKnown = (self.stackLimitKnown or 0) + 1
    end
    self.itemMaxCountCache[itemName] = value
    return value
end

--- 整理计划的"输入版本号"：容器快照换代次数 + 已知堆叠上限的物品数。
--- 自动整理没有冷却（用户要求），但"输入完全没变、上一轮又没排出任何搬运"时不该每 tick 重算一遍
--- —— 这个版本号就是那个判断依据（快照变了或又有新的堆叠上限扫到了，就重算）。
function Containers:planInputRevision()
    local revision = 0
    for _, model in pairs(self.model or {}) do
        revision = revision + (model.gen or 0)
    end
    return revision * 100000 + (self.stackLimitKnown or 0)
end

--- 一步"槽位堆叠扫描"（一个容器）：把还没扫到的物品类型的堆叠上限问出来，写进物品详情字典。
---   * 槽位数量未知的容器：顺手把"槽位数量"读出来（用户第 5 项要求）；
---   * 优先交给 worker 代查（与 detail 队列同一个机制，结果回来后 absorb 进字典）；
---   * 没有空闲查询 worker：本机读，最多 STACK_SCAN_BUDGET 次（每次约 1 个游戏刻）。
--- 返回：这一步问了多少个物品类型（0 = 这个容器已经全知道，什么都不用做）。
local STACK_SCAN_BUDGET = 4
function Containers:stackScanStep(containerName)
    --- 堆叠上限扫描只服务"整理"，而整理只针对 storage（见 scanQueueTargets / stackScanTargets）：
    --- 别的角色走到这里就是未定义行为 → 直接报错（不许静默读一遍交互/输出容器）。
    local role = self:defRole(containerName, "item")
    if role ~= "storage" then
        error(string.format("BUG: Containers:stackScanStep called for %s (role=%s): only storage containers feed the compact plan",
            tostring(containerName), tostring(role)), 0)
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return 0
    end
    --- 槽位数量未知 → 读一次 size()（有缓存，读一次能管很久）
    self:slotCount(peripheralName)
    local samples = {}
    for slot, stack in pairs(self:listPeripheral(peripheralName)) do
        if type(stack) == "table" and type(stack.name) == "string" and stack.name ~= "" and
            not self:stackLimitOf(stack.name, stack.nbt) then
            samples[#samples + 1] = {
                container = peripheralName, slot = slot, name = stack.name, nbt = stack.nbt,
            }
            if #samples >= STACK_SCAN_BUDGET then
                break
            end
        end
    end
    if #samples == 0 then
        return 0
    end
    --- 有 worker 就交给它代查（结果由 absorbItemDetails 写进字典，下一次 stackLimitOf 就能读到）
    local state = self:requestItemDetails(samples)
    if state == "pending" then
        return #samples
    end
    --- 没有空闲查询 worker：本机读（阻塞约 1 刻/次，已被 STACK_SCAN_BUDGET 限制住）
    local read = 0
    for _, sample in ipairs(samples) do
        local detail = self:detail(sample.container, sample.slot, { name = sample.name, nbt = sample.nbt })
        if type(detail) == "table" then
            self:absorbItemDetails({ { name = sample.name, nbt = sample.nbt, detail = detail } })
            read = read + 1
        end
    end
    return read
end

--- 需要做"槽位堆叠扫描"的存储容器：只含外设还在的（外设卸载的不再排任务）
function Containers:stackScanTargets()
    local list = {}
    for _, containerName in ipairs(self:byRole("storage", "item")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName and self.Peripherals:isInventory(peripheralName) then
            list[#list + 1] = { container = containerName, peripheral = peripheralName }
        end
    end
    return list
end


--- 容器槽位数量（size()；读不到就用最大槽位下标兜底，结果缓存一段时间）
function Containers:slotCount(peripheralName)
    self.slotCountCache = self.slotCountCache or {}
    local now = os.epoch("utc")
    local cached = self.slotCountCache[peripheralName]
    if cached and now - cached.stamp < SLOT_COUNT_TTL then
        return cached.value
    end
    --- 用户第 4 项：快照里记了格数（海龟上报的）就优先用它 —— 海龟不是 inventory 外设，
    --- 下面那次 inv.size() 对它永远是 nil，只靠"占用过的最高槽位"会把 16 格当成 1 格。
    local model = self.model[peripheralName]
    local known = model and tonumber(model.size) or nil
    if known and known > 0 then
        local value = math.floor(math.min(known, MAX_CONTAINER_SLOTS))
        self.slotCountCache[peripheralName] = { value = value, stamp = now }
        return value
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



















--[==[ ============================================================================
已弃用（用户第 3/6 项）：旧的「分批探测 + 链式挪动」整理规划器，已被下面的
Containers:compactPlanSimple + compactPlanPass 完全取代 —— 这里整段保留只为对照历史实现，
**不在任何代码路径上**。打包时注释会被剥离，所以它不占用 CC:T 磁盘空间；
要彻底删掉请整段删除（从这一行到文件里 end of the deprecated planner 那一句为止）。
============================================================================
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
            return nil
        end
        --- 只读字典（stackScan 队列会把"槽位堆叠上限"写进去）；没有就返回 nil 让计划跳过这个物品。
        --- 用户第 5 项：宁可这一轮不整理，也不按 64 的猜测去搬（搬错数量比不搬更糟）。
        local value = self:stackLimitOf(itemName, nbt)
        if value then
            return value
        end
        self.stackLimitUnknown = (self.stackLimitUnknown or 0) + 1
        return nil
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
    --- 因为"堆叠上限还没扫到"而跳过的物品数（用户第 5 项：不猜，直接跳过；诊断里能看到）
    local skippedUnknown = 0
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
        if not maxCount then
            --- 这个物品的堆叠上限还没扫到 → 本次跳过它（不猜、也不在现场等外设）
            return nil, nil
        end
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
        if not candidates then
            --- 堆叠上限还没扫到：跳过这个物品（下一个 tick 的 stackScan 会把它补上，下轮整理再合并）
            skippedUnknown = (skippedUnknown or 0) + 1
        else
            group.maxCount = maxCount
            local entry = {
                group = group,
                candidates = candidates,
                targets = selectTargets(candidates, group.total),
            }
            entry.moves = movesFor(group, entry.targets, candidates)
            planned[#planned + 1] = entry
        end
    end
    if planner then
        planner.groupsDone = #order
        planner.skippedUnknown = skippedUnknown or 0
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
]==] -- end of the deprecated planner

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
    --- 用户第 3/6 项：换成简单、确定的整理算法（旧的分批探测式规划器已被它取代）。
    --- 一次算完（不再分多轮 yield）：计算只用内存里的槽位快照 + 物品上限字典，不读外设。
    local plan = self:compactPlanSimple(planner.role)
    planner.stage = "done"
    planner.plannedMoves = #plan
    planner.groupsDone = #plan
    planner.groupsTotal = #plan
    planner.containersDone = planner.containersTotal
    return plan, true
end

--- 简单、确定的整理算法（用户第 3/6 项），取代旧的"分批探测 + 链式挪动"规划器。
---   1. 收集所有存储槽位（含空槽位）；物品按**数量从多到少**排序；
---   2. 同一种物品（同名同 NBT）的**散堆就地合并**（用户第 4 项）：数量最多的那几堆当目标槽位
---      （要几个槽位 = ceil(总数 / 单槽堆叠上限)），剩下的堆往目标的剩余空间里塞 ——
---      以前只把整堆搬到空槽位，于是"3 个槽位各 10 个"永远合不成"1 个槽位 30 个"；
---   3. 目标槽位不够（要的槽位数比现有的堆数多）时才去借空槽位（按 容器名 + 槽位 定序 = 确定性）；
---   4. 每条搬运互相独立（目标只会是"留下来的那一堆"或空槽位，绝不会同时是别人的源）——
---      所以可以直接并行，不会出现"A 不移走、B 就进不去"那种必须串行的依赖（旧算法效果差的根源）；
---   5. 正在被搬的槽位（脏）**不碰**：既不当目标也不当源，留给下一次整理；
---   6. 搬运提交时目标槽位会被标脏（Containers:reserveIn，用户第 9 项）→ 同一个空槽位不会被两条搬运抢；
---   7. 存储内部挪动不改数量快照（用户第 7 项）。
--- 返回 { { name, nbt, amount, fromContainer, fromSlot, toContainer, toSlot }, ... }
function Containers:compactPlanSimple(role)
    role = role or "storage"
    local now = os.epoch("utc")
    local slots, items = {}, {}
    for _, containerName in ipairs(self:byRole(role, "item", "in")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName and self.Peripherals:isInventory(peripheralName) then
            local model = self:modelOf(peripheralName)
            self:sweepDirty(model, now)
            local size = tonumber(self:slotCount(peripheralName)) or 0
            local stacks = self:stacksPeripheral(peripheralName)
            local bySlot = {}
            for _, stack in ipairs(stacks) do
                bySlot[tonumber(stack.slot)] = stack
            end
            for slot = 1, size do
                slots[#slots + 1] = {
                    container = containerName, peripheral = peripheralName, slot = slot,
                    stack = bySlot[slot],
                    dirty = self:isDirtySlot(peripheralName, slot, false) == true,
                }
            end
            for _, stack in ipairs(stacks) do
                local key = itemKeyOf(stack.name, stack.nbt)
                if key then
                    local entry = items[key]
                    if not entry then
                        entry = { name = stack.name, nbt = stack.nbt, count = 0, stacks = {} }
                        items[key] = entry
                    end
                    entry.count = entry.count + (tonumber(stack.count) or 0)
                    entry.stacks[#entry.stacks + 1] = {
                        container = containerName, peripheral = peripheralName,
                        slot = tonumber(stack.slot) or stack.slot,
                        count = tonumber(stack.count) or 0,
                    }
                end
            end
        end
    end
    --- 物品：数量从多到少（同数量按名字 / NBT 定序，保证每次都一样）
    local order = {}
    for _, entry in pairs(items) do
        order[#order + 1] = entry
    end
    table.sort(order, function(a, b)
        if a.count ~= b.count then
            return a.count > b.count
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return tostring(a.nbt or "") < tostring(b.nbt or "")
    end)
    --- 空槽位池（按 容器名 + 槽位 定序；同一个物品在所有空槽位里的堆叠上限相同）
    local free = {}
    for _, slot in ipairs(slots) do
        if not slot.stack and not slot.dirty then
            free[#free + 1] = slot
        end
    end
    table.sort(free, function(a, b)
        if a.container ~= b.container then
            return a.container < b.container
        end
        return a.slot < b.slot
    end)
    local moves = {}
    for _, entry in ipairs(order) do
        local capacity = self:itemMaxCount(entry.name, entry.nbt)
        if capacity <= 0 then
            capacity = DEFAULT_ITEM_MAX_COUNT
        end
        --- 这一种物品现存的每一堆：数量从多到少（同数量按 容器名 + 槽位 定序，保证每次都一样）——
        --- 数量最多的那几堆就是"就地合并"之后要留下来的目标槽位。
        local stacks = {}
        for _, stack in ipairs(entry.stacks) do
            stacks[#stacks + 1] = stack
        end
        table.sort(stacks, function(a, b)
            local left, right = tonumber(a.count) or 0, tonumber(b.count) or 0
            if left ~= right then
                return left > right
            end
            if a.container ~= b.container then
                return a.container < b.container
            end
            return a.slot < b.slot
        end)
        --- 需要几个槽位：ceil(总数 / 单槽上限)；至少要 1 个
        local need = math.max(1, math.ceil((tonumber(entry.count) or 0) / capacity))
        --- 目标槽位 = 留下来的那几堆（就地合并，不额外占空槽位）；装不下的堆当搬运源。
        --- 正在被搬的槽位（脏）既不选作目标也不当源：动它会把在飞任务的数量搞乱。
        local targets, sources = {}, {}
        local kept = 0
        for _, stack in ipairs(stacks) do
            if self:isDirtySlot(stack.peripheral, stack.slot, false) == true then
                --- 跳过：留给下一次整理
            elseif kept < need then
                kept = kept + 1
                targets[#targets + 1] = {
                    container = stack.container, peripheral = stack.peripheral, slot = stack.slot,
                    count = tonumber(stack.count) or 0,
                }
            else
                sources[#sources + 1] = stack
            end
        end
        --- 目标槽位不够（这一种物品的堆数比需要的槽位少）→ 从空槽位池里借（按 容器名 + 槽位 定序）
        for i = 1, #free do
            if #targets >= need then
                break
            end
            if not free[i].taken then
                free[i].taken = true             -- 本轮预留给这一种物品，别的物品不会抢
                targets[#targets + 1] = {
                    container = free[i].container, peripheral = free[i].peripheral, slot = free[i].slot,
                    count = 0,
                }
            end
        end
        if #sources > 0 then
            --- 目标槽位的剩余空间（空槽位 = 一整槽的堆叠上限）
            local rooms = {}
            for index, target in ipairs(targets) do
                rooms[index] = math.max(0, capacity - (tonumber(target.count) or 0))
            end
            --- 把小堆往剩余空间最大的目标里塞：一条搬运 = 一次 pushItem（源槽位整堆搬空）
            for _, source in ipairs(sources) do
                local remaining = tonumber(source.count) or 0
                while remaining > 0 do
                    local best, bestRoom = nil, 0
                    for index = 1, #targets do
                        local room = rooms[index] or 0
                        if room > bestRoom then
                            best, bestRoom = index, room
                        end
                    end
                    if not best then
                        break                        -- 目标都满了：剩下的堆维持原样（宁可不搬）
                    end
                    local target = targets[best]
                    local amount = math.min(remaining, bestRoom)
                    moves[#moves + 1] = {
                        name = entry.name, nbt = entry.nbt,
                        amount = amount,
                        fromContainer = source.container, fromSlot = source.slot,
                        toContainer = target.container, toSlot = target.slot,
                    }
                    rooms[best] = bestRoom - amount
                    remaining = remaining - amount
                end
            end
        end
    end
    return moves
end

--- 外设缺失的容器定义清单（网页高亮用；种类与外设能力不匹配也算缺失）。
--- 用户第 1/2 项：**自动生成**的虚拟定义（turtle_crafter 的海龟容器）不列进来 ——
--- 海龟下线时由 IFMMaster:syncTurtleCrafters 自动把它们撤掉，不是"用户定义缺失"。
--- 用户第 2/3 项（本轮）：**机器直接引用的外设**也要列进来 —— 现场：关掉有线调制解调器再打开，
--- 有线网络把外设重新编号（create:millstone_4 → create:millstone_6），机器的输入/输出列表里
--- 还指着旧名字：以前它既不在缺失面板里，机器卡片上的外设芯片也不标红，网页上完全看不出问题。
--- 只列"连容器定义都不存在"的名字（定义还在的走上面那条检查，不重复）。
function Containers:missingPeripherals()
    local out = {}
    local seen = {}
    for _, def in ipairs(self.Store:list("containers")) do
        if def.virtual ~= true then
            local defKind = self.Util.kindOfDef(def)
            local provides = false
            if self.Peripherals:exists(def.peripheral) then
                if defKind == "fluid" then
                    provides = self.Peripherals:isFluid(def.peripheral)
                else
                    --- 海龟（交互容器）没有 inventory 外设，但它确实提供了物品栏（用户第 2 项）
                    provides = self.Peripherals:isInventory(def.peripheral)
                        or ((def.role or "storage") == "interaction"
                            and self.Peripherals:isTurtle(def.peripheral))
                end
            end
            if not provides then
                --- containerKind：网页端删除这条缺失定义时要带上的容器种类（item / fluid）
                out[#out + 1] = { kind = "container", containerKind = defKind, name = def.name,
                    peripheral = def.peripheral }
                seen["container\\1" .. tostring(def.name)] = true
            end
        end
    end
    for _, def in ipairs(self.Store:list("signals")) do
        if not self.Peripherals:exists(def.peripheral) then
            out[#out + 1] = { kind = "signal", name = def.name, peripheral = def.peripheral }
            seen["signal\\1" .. tostring(def.name)] = true
        end
    end
    --- 机器（machine 定义）直接引用的外设：容器定义不存在 + 外设也不在 ⇒ 这条引用是坏的。
    if self.Store and type(self.Store.list) == "function" then
        local machines = self.Store:list("machines") or {}
        for _, machine in ipairs(machines) do
            local function note(peripheralName, kind)
                if type(peripheralName) ~= "string" or peripheralName == "" then
                    return
                end
                if self.Peripherals:exists(peripheralName) then
                    return
                end
                --- 同名容器定义还在的话，上面那条检查已经报过了（这里不重复）
                if self.Store.findContainer and self.Store:findContainer(peripheralName, kind or "item") then
                    return
                end
                local key = "machine\\1" .. peripheralName
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = { kind = "machine", containerKind = kind or "item",
                        name = peripheralName, peripheral = peripheralName,
                        machine = machine.name }
                end
            end
            for _, listKey in ipairs({ "itemInputs", "fluidInputs", "itemOutputs", "fluidOutputs" }) do
                local kind = string.find(listKey, "^fluid") and "fluid" or "item"
                for _, name in ipairs(machine[listKey] or {}) do
                    note(name, kind)
                end
            end
            for _, signal in ipairs(machine.signals or {}) do
                local peripheralName = type(signal) == "table" and signal.peripheral or signal
                note(peripheralName, "item")
            end
        end
    end
    return out
end

return Containers
