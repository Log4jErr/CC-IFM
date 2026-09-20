-- IFM :: modules/store.lua
-- 定义数据模型（config.json）：容器定义、信号定义、过滤器定义、机器类型、机器、流程。
-- 所有定义都保存在 data[kind][name] 中；set/delete 走校验，变更后自动去抖写盘。

local Store = {}
Store.__index = Store

Store.KINDS = { "containers", "signals", "filters", "machineTypes", "machines", "processes", "settings" }

--- 全局设置（1.7.0）：
---   "schedule" —— 各任务队列的调度时间片（正整数，见 Store.SCHEDULE_*）。
--- 1.7.0 起不再有"毫秒级扫描间隔"（settings.scan 已删除：扫描由 storageScan / inputScan 队列驱动）。

--- 调度权重（1.8.0）：**0.01 ~ 1-0.01n 的小数（n = 队列条数），所有队列加起来等于 1**。
--- 为什么不允许 0：一旦允许，用户可能把所有滑条都拖到 0 → 没法归一化（除零），而且"整条队列停摆"
--- 这种状态对工厂是没有意义的。所以每条队列永远至少占 0.01（1 分），单条最多 1-0.01n。
--- 网页「设置」里滑动一条滑条会按比例影响其它滑条（归一化）。
--- 之所以能这么改：轮转算法本来就是"平滑加权轮转"（权重只需要是正数），并不要求整数时间片。
Store.SCHEDULE_NAME = "schedule"
Store.SCHEDULE_DEFAULTS = {
    process = 1, storageScan = 1, inputScan = 1,
    --- interactionScan / outputScan（1.9.x）：交互容器与输出容器**各自一条**扫描队列
    --- （它们现在都会被扫描；输出容器单独一条是用户第 1 项的要求）
    interactionScan = 1, outputScan = 1,
    inventoryIn = 1, inventoryOut = 1, compact = 1, detail = 1, manual = 1,
    --- stackScan（1.8.0）：槽位堆叠上限扫描队列（自动整理计划的输入）
    stackScan = 1,
}
Store.SCHEDULE_QUEUES = { "process", "storageScan", "inputScan", "interactionScan", "outputScan",
    "inventoryIn", "inventoryOut", "compact", "stackScan", "detail", "manual" }
--- 1 分 = 0.01；权重一律按"整数分"（1 ~ 100）计算，这样"合计正好 1"不会有四舍五入误差
Store.SCHEDULE_CENTS = 100
--- 注意：max 只是"当前 11 条队列时"的展示值，真正的上限由 Store.weightMax() 按队列条数算（1-0.01n）
Store.SCHEDULE_LIMITS = { min = 0.01, max = 0.91, step = 0.01 }
Store.SCHEDULE_MIN_SHARE = 0.01
--- 自动整理的空槽位阈值（用户第 4 项）：存储容器的**空槽位比例**低于它才自动整理
---（空槽位还够多时搬来搬去没意义）。1 = 总是整理，0 = 从不整理；网页「设置」里可改。
--- 自动整理的空槽位阈值缺省值（用户第 3 项）：0 ~ 1；
--- 存储容器的空槽位低于这个比例才触发自动整理（0 = 关掉自动整理）。缺省 0.30（空槽不足 30% 就整理）。
Store.SCHEDULE_COMPACT_FREE_DEFAULT = 0.30

--- 单条队列的最大权重：其它队列每条至少留 1 分 ⇒ (100 - n) 分
function Store.weightMax()
    local maxCents = Store.SCHEDULE_CENTS - #Store.SCHEDULE_QUEUES
    return math.max(Store.SCHEDULE_MIN_SHARE, maxCents / Store.SCHEDULE_CENTS)
end

--- 归一化权重（**浮点**，不再截断到小数点后 2 位 —— 用户第 2 项：前端拖出的 0.1174 保存后不该
--- 变成 0.12）。规则与前端 rebalanceWeights 一致：
---   * 按比例缩放到合计正好 1；每条至少 SCHEDULE_MIN_SHARE（低于下限的先钉下限，其余按比例分剩下的）；
---   * 保留 6 位小数（只去掉浮点噪声，不做业务意义上的取整）。
--- 返回：权重表, 是否原本全 0（调用方据此提示"回退到平均分"）。
local function round6(value)
    return math.floor((tonumber(value) or 0) * 1000000 + 0.5) / 1000000
end

function Store.normalizeSlices(slices)
    local names = Store.SCHEDULE_QUEUES
    local count = #names
    local min = Store.SCHEDULE_MIN_SHARE
    local raw, total = {}, 0
    for _, name in ipairs(names) do
        local value = tonumber(slices and slices[name]) or 0
        if value < 0 then
            value = 0
        end
        raw[name] = value
        total = total + value
    end
    local out = {}
    if total <= 0 then
        local each = 1 / count
        for _, name in ipairs(names) do
            out[name] = round6(each)
        end
        return out, true
    end
    --- 低于下限的先钉在下限，剩下的按原比例在其余队列之间分配
    local frozen, frozenCount, freeSum = {}, 0, 0
    for _, name in ipairs(names) do
        if raw[name] / total < min then
            frozen[name] = true
            frozenCount = frozenCount + 1
        else
            freeSum = freeSum + raw[name]
        end
    end
    local budget = 1 - min * frozenCount
    local freeCount = count - frozenCount
    for _, name in ipairs(names) do
        if frozen[name] then
            out[name] = min
        elseif freeSum > 0 then
            out[name] = round6(budget * (raw[name] / freeSum))
        else
            out[name] = round6(budget / math.max(1, freeCount))
        end
    end
    return out, false
end

local VALID_ROLES = { storage = true, interaction = true, output = true, input = true }
--- 容器定义的种类：item = 物品容器（inventory 外设），fluid = 流体容器（fluid_storage 外设）。
--- 同一个方块可能同时提供这两种外设（例如 create:basin_0），因此允许分别建立两个容器定义。
local VALID_CONTAINER_KINDS = { item = true, fluid = true }
local VALID_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local VALID_OPS = { gt = true, ge = true, eq = true, le = true, lt = true }

Store.VALID_ROLES = VALID_ROLES
Store.VALID_CONTAINER_KINDS = VALID_CONTAINER_KINDS
Store.VALID_SIDES = VALID_SIDES
Store.VALID_OPS = VALID_OPS
Store.roleList = { "storage", "input", "interaction", "output" }
Store.containerKindList = { "item", "fluid" }
Store.sideList = { "top", "bottom", "left", "right", "front", "back" }
Store.opList = { "gt", "ge", "eq", "le", "lt" }

local KNOWN_RULE_TYPES = {
    item_include = true,
    item_exclude = true,
    fluid_include = true,
    fluid_exclude = true,
    itemTag_include = true,
    itemTag_exclude = true,
    fluidTag_include = true,
    fluidTag_exclude = true,
    filter_include = true,
    filter_exclude = true,
}

local function isName(s)
    return type(s) == "string" and s:match("%S") ~= nil
end

local function normalizeSides(list)
    local out = {}
    for _, side in ipairs(list or {}) do
        if VALID_SIDES[side] then
            out[#out + 1] = side
        end
    end
    -- 未指定任何方向时默认六面全开（设置红石信号 / 发出红石脉冲 / 等待红石信号 都一样）
    if #out == 0 then
        return { "top", "bottom", "left", "right", "front", "back" }
    end
    return out
end

local function normalizeStringList(list)
    local out = {}
    for _, v in ipairs(list or {}) do
        if type(v) == "string" and v ~= "" then
            out[#out + 1] = v
        end
    end
    return out
end

--- 容器定义在数据表里的键：kind:name。
--- 物品容器与流体容器允许同名（例如同一个工作盆：物品“工作盆” + 流体“工作盆”），
--- 所以容器定义以“种类:名称”为键，其它定义仍然以名称为键。
function Store.containerKey(containerKind, name)
    return (containerKind == "fluid" and "fluid:" or "item:") .. tostring(name or "")
end

--- 去掉 "item:" / "fluid:" 前缀，取出纯名称
function Store.containerPlainName(value)
    local text = tostring(value or "")
    local prefix, rest = text:match("^(%a+):(.*)$")
    if prefix == "item" or prefix == "fluid" then
        return rest
    end
    return text
end

function Store.emptyData()
    return {
        version = 1,
        containers = {},
        signals = {},
        filters = {},
        machineTypes = {},
        machines = {},
        processes = {},
        settings = {},
    }
end


--- 调度权重设置：缺省 + 归一化（总和 = 1 的小数），保证任何时候都拿得到可用值
function Store:scheduleSettings()
    local saved = self:get("settings", Store.SCHEDULE_NAME) or {}
    local savedSlices = type(saved.slices) == "table" and saved.slices or {}
    local slices = {}
    for _, name in ipairs(Store.SCHEDULE_QUEUES) do
        local value = tonumber(savedSlices[name])
        if not value or value < 0 then
            value = Store.SCHEDULE_DEFAULTS[name] or 0
        end
        slices[name] = value
    end
    local normalized, allZero = Store.normalizeSlices(slices)
    if allZero then
        self.log("Schedule weights were all zero - falling back to an equal split (%d queues)", #Store.SCHEDULE_QUEUES)
    end
    --- 主控本机协程池开关（用户第 1 项）：关掉后主控不再自己处理任务 —— 只在有 worker 在线时才生效。
    --- 用户第 3 项：**缺省关**（分布式部署下主控只管调度/网页，搬运交给 worker；
    --- 没有 worker 在线时后端仍会本机干活，所以网络里一台 worker 都没有也不会卡住）。
    local localPool = saved.localPool
    if localPool == nil then
        localPool = false
    end
    --- 给网页推日志的开关（用户第 1 项）：日志在 WS 上是最大的一块流量，可以按需关掉。
    --- 用户第 3 项：**缺省关**（要在线看日志请在网页「设置」里打开）。
    local sendLog = saved.sendLog
    if sendLog == nil then
        sendLog = false
    end
    --- 自动整理的空槽位阈值（用户第 4 项）：0 ~ 1，缺省 0.10（空槽位不足 10% 才整理）
    local compactFreeRatio = tonumber(saved.compactFreeRatio)
    if not compactFreeRatio or compactFreeRatio < 0 then
        compactFreeRatio = Store.SCHEDULE_COMPACT_FREE_DEFAULT
    elseif compactFreeRatio > 1 then
        compactFreeRatio = 1
    end
    return {
        slices = normalized,
        limits = Store.SCHEDULE_LIMITS,
        minShare = Store.SCHEDULE_MIN_SHARE,
        queues = Store.SCHEDULE_QUEUES,
        localPool = localPool ~= false,
        sendLog = sendLog ~= false,
        compactFreeRatio = compactFreeRatio,
    }
end

function Store.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Store)
    self.Util = opts.Util
    --- 落盘统一交给 modules/jsonfile.lua（读 / 原子写 / 去抖都在那边）
    local JsonFile = opts.JsonFile
    if not JsonFile then
        error("store.lua needs the jsonfile module: pass opts.JsonFile (loadModule(\"jsonfile\"))", 0)
    end
    self.file = JsonFile.new({
        path = opts.path or "/data/config.json",
        log = opts.log,
        writeDebounce = opts.writeDebounce,
    })
    self.log = opts.log or function() end
    self.onChange = opts.onChange
    self.data = Store.emptyData()
    return self
end

--- 读取 config.json（缺失 / 打不开 / 解析失败都只返回原因，调用方照常从空配置起步）
function Store:load()
    local parsed, why = self.file:read("config.json")
    if not parsed then
        --- 文件**存在**却读不出来（写盘被打断 / 手工编辑坏了）→ 进只读保护：
        --- 绝不把内存里的空配置写回去覆盖用户的定义（那等于静默清空整座工厂）。
        --- 文件不存在（全新安装）不算：这时写一份空配置没有任何损失。
        local exists = false
        if self.file.path and type(fs) == "table" and fs.exists then
            local ok, value = pcall(fs.exists, self.file.path)
            exists = ok and value == true
        end
        self.readOnly = exists and true or false
        if self.readOnly then
            self.log("config.json exists but could not be read (%s) - the store is READ-ONLY until it is " ..
                "fixed; nothing will be written back over it", tostring(why))
        end
        self.data = Store.emptyData()
        return false, why
    end
    self.data = Store.emptyData()
    --- 房间号保存在配置顶层：重启后沿用同一个房间号
    self.data.room = type(parsed.room) == "string" and parsed.room or nil
    for _, kind in ipairs(Store.KINDS) do
        local src = parsed[kind]
        if type(src) == "table" then
            for key, obj in pairs(src) do
                if type(obj) == "table" and type(key) == "string" then
                    if kind == "containers" then
                        -- 容器定义以 "种类:名称" 为键（物品容器与流体容器允许同名）；
                        -- 名字取自定义自己的 name 字段（只在不完整时才退回键）
                        local containerKind = self.Util.kindOfDef(obj)
                        local plain = self.Util.trim(obj.name or "")
                        if plain == "" then
                            plain = Store.containerPlainName(key)
                        end
                        obj.name = plain
                        self.data.containers[Store.containerKey(containerKind, plain)] =
                            self:normalize("containers", plain, obj)
                    else
                        obj.name = obj.name or key
                        self.data[kind][key] = self:normalize(kind, key, obj)
                    end
                end
            end
        end
    end
    return true
end

--- 房间号（保存在 config.json 顶层）
function Store:getRoom()
    return self.data.room
end

--- 写入房间号并立即落盘（启动时定一次，之后不会再变）
function Store:setRoom(roomName)
    if self.data.room == roomName then
        return false
    end
    self.data.room = roomName
    self:markDirty()
    self:flush()
    return true
end

function Store:markDirty()
    self.file:markDirty()
end

--- 去抖写盘（由主循环按 tick 调用）
function Store:tick(now)
    if not self.file:shouldFlush(now) then
        return false
    end
    return self:flush()
end

--- 立即写盘（原子写由 modules/jsonfile.lua 负责）
--- 只读保护（见 Store:load）：配置读不出来时一个字节都不写，避免用空配置覆盖用户数据。
function Store:flush()
    if self.readOnly then
        return false, "config.json could not be read - refusing to overwrite it"
    end
    return self.file:flush(self.data)
end

--- 预设机器类型名（用户第 3 项）：运行 IFMCrafter.lua 的机械臂（海龟）**自动**成为这个类型的机器，
--- 用户不必再走"添加机器类型 → 添加机器 → 添加外设"三步。
Store.TURTLE_CRAFTER_TYPE = "turtle_crafter"

--- 虚拟定义（不落盘）：{ [kind] = { 键 -> 定义 } }。
--- 用途：turtle_crafter —— 主控看到的海龟外设 × 合成器上报的网络名 → 自动生成
--- "容器（role = interaction，输入输出都是海龟自己）+ 机器（parallel 恒 1）"。
--- 它们**不写进 config.json**（self.data 里没有它们），只在本机内存里生效，
--- 但 get / findContainer / list / names 都会看到它们 —— 引擎与网页因此当作真实定义。
function Store:setVirtual(kind, list)
    self.virtual = self.virtual or {}
    local bucket = {}
    for _, def in ipairs(list or {}) do
        if type(def) == "table" and type(def.name) == "string" and def.name ~= "" then
            --- 容器定义按"种类:名称"做键（与 findContainer 一致），其它定义用名称
            local key = def.name
            if kind == "containers" then
                key = Store.containerKey(def.kind or "item", def.name)
            end
            bucket[key] = def
        end
    end
    local changed = false
    local previous = self.virtual[kind] or {}
    for key, def in pairs(bucket) do
        if previous[key] ~= def then
            changed = true
            break
        end
    end
    if not changed then
        for key in pairs(previous) do
            if bucket[key] == nil then
                changed = true
                break
            end
        end
    end
    self.virtual[kind] = bucket
    --- **不标脏**：虚拟定义不落盘（config.json 里没有它们），标脏只会让主控白白写盘 ——
    --- 而且万一 config.json 读不出来（Store:load 的只读保护）就会把空配置写回去。
    --- 网页照旧能看到它们：快照推送本来就有 1 秒一次的定时推送。
    return bucket, changed
end

--- 某个 kind 的虚拟定义表（没有就是空表）
function Store:virtualOf(kind)
    return (self.virtual and self.virtual[kind]) or {}
end

--- 这台机器是不是"机械臂合成器"（turtle_crafter 预设类型）：
--- 引擎在"材料输入完成"之后要额外给海龟发一条 craft 指令（用户第 3 项）。
function Store.isTurtleCrafter(machine)
    return type(machine) == "table" and machine.type == Store.TURTLE_CRAFTER_TYPE
end

function Store:get(kind, name, containerKind)
    if kind == "containers" then
        return self:findContainer(name, containerKind)
    end
    local bucket = self.data[kind]
    if not bucket or type(name) ~= "string" then
        return nil
    end
    return bucket[name] or self:virtualOf(kind)[name]
end

--- 查找容器定义：nameOrKey 可以是纯名称（可指定 kind）或 "item:名称"/"fluid:名称" 键。
--- 只给纯名称且没给 kind 时，优先物品容器、其次流体容器。
function Store:findContainer(nameOrKey, containerKind)
    if type(nameOrKey) ~= "string" or nameOrKey == "" then
        return nil
    end
    local virtual = self:virtualOf("containers")
    local direct = self.data.containers[nameOrKey] or virtual[nameOrKey]
    if direct then
        return direct
    end
    local plain = Store.containerPlainName(nameOrKey)
    if containerKind then
        return self.data.containers[Store.containerKey(containerKind, plain)]
            or virtual[Store.containerKey(containerKind, plain)]
    end
    return self.data.containers[Store.containerKey("item", plain)]
        or self.data.containers[Store.containerKey("fluid", plain)]
        or virtual[Store.containerKey("item", plain)]
        or virtual[Store.containerKey("fluid", plain)]
end

--- 按名称排序的数组（含虚拟定义：turtle_crafter 的机器/容器，见 setVirtual）
function Store:list(kind)
    local bucket = self.data[kind] or {}
    local virtual = self:virtualOf(kind)
    local names = {}
    for name in pairs(bucket) do
        names[#names + 1] = name
    end
    for _, def in pairs(virtual) do
        local name = def.name
        if type(name) == "string" and not bucket[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    local out = {}
    for i = 1, #names do
        local name = names[i]
        out[i] = bucket[name] or virtual[name]
            or virtual[Store.containerKey("item", name)] or virtual[Store.containerKey("fluid", name)]
    end
    return out
end

function Store:names(kind)
    local out = {}
    for _, def in ipairs(self:list(kind)) do
        if type(def) == "table" and type(def.name) == "string" then
            out[#out + 1] = def.name
        end
    end
    return out
end

--- 是否被引用（用于删除保护）
function Store:references(kind, name, containerKind)
    local refs = {}
    if kind == "containers" then
        local wanted = containerKind or (self:findContainer(name) or {}).kind or "item"
        local wantedItem = wanted ~= "fluid"
        for _, machine in ipairs(self:list("machines")) do
            local lists = {
                { list = machine.itemInputs, isItem = true },
                { list = machine.fluidInputs, isItem = false },
                { list = machine.itemOutputs, isItem = true },
                { list = machine.fluidOutputs, isItem = false },
            }
            local hit = false
            for _, entry in ipairs(lists) do
                if entry.isItem == wantedItem then
                    for _, cname in ipairs(entry.list or {}) do
                        if Store.containerPlainName(cname) == name then
                            hit = true
                        end
                    end
                end
            end
            if hit then
                refs[#refs + 1] = "\\u673A\\u5668 " .. machine.name
            end
        end
    elseif kind == "signals" then
        for _, machine in ipairs(self:list("machines")) do
            for _, sname in ipairs(machine.signals or {}) do
                if sname == name then
                    refs[#refs + 1] = "\\u673A\\u5668 " .. machine.name
                    break
                end
            end
        end
    elseif kind == "filters" then
        for _, filter in ipairs(self:list("filters")) do
            if filter.name ~= name then
                for _, rule in ipairs(filter.rules or {}) do
                    if rule.id == name and (rule.type == "filter_include" or rule.type == "filter_exclude") then
                        refs[#refs + 1] = "\\u8FC7\\u6EE4\\u5668 " .. filter.name
                        break
                    end
                end
            end
        end
        for _, process in ipairs(self:list("processes")) do
            local used = false
            for _, el in ipairs(process.inputs or {}) do
                if el.kind == "filter" and el.id == name then
                    used = true
                end
            end
            for _, el in ipairs(process.outputs or {}) do
                if el.kind == "filter" and el.id == name then
                    used = true
                end
            end
            if used then
                refs[#refs + 1] = "\\u6D41\\u7A0B " .. process.name
            end
        end
    elseif kind == "machineTypes" then
        for _, machine in ipairs(self:list("machines")) do
            if machine.type == name then
                refs[#refs + 1] = "\\u673A\\u5668 " .. machine.name
            end
        end
        for _, process in ipairs(self:list("processes")) do
            if process.machineType == name then
                refs[#refs + 1] = "\\u6D41\\u7A0B " .. process.name
            end
        end
    end
    return refs
end

--- 强制删除时"顺手摘掉引用"（用户第 3 项）：把机器定义里指向这条容器/信号定义的名字去掉。
--- 为什么需要它：一键删除缺失外设之后，网页上机器卡片里那张「缺失的外设卡片」还挂在机器的
--- 输入/输出列表里 —— 用户看到的还是"没删掉"。摘掉引用后机器卡片就干净了。
--- 注意：机器的输入/输出是**按顺序**引用的（流程里的容器序号指向列表下标），从中间摘掉一条会
--- 让它后面的序号前移 —— 被删的这台外设本来就已经不在，机器本来也跑不动，这里以"卡片能清干净"为准。
--- 返回被改动的机器数量。
function Store:purgeReferences(kind, name, containerKind)
    local touched = 0
    local function purgeList(machine, listKey, match)
        local list = machine[listKey]
        if type(list) ~= "table" then
            return false
        end
        local kept = {}
        local changed = false
        for _, entry in ipairs(list) do
            if match(entry) then
                changed = true
            else
                kept[#kept + 1] = entry
            end
        end
        if changed then
            machine[listKey] = kept
        end
        return changed
    end
    if kind == "containers" then
        --- 物品容器与流体容器可以同名：只摘对得上种类的那几个列表
        local wanted = containerKind or (self:findContainer(name) or {}).kind or "item"
        local isItem = wanted ~= "fluid"
        local match = function(entry) return Store.containerPlainName(entry) == name end
        for _, machine in ipairs(self:list("machines")) do
            local changed = false
            if isItem then
                changed = purgeList(machine, "itemInputs", match) or changed
                changed = purgeList(machine, "itemOutputs", match) or changed
            else
                changed = purgeList(machine, "fluidInputs", match) or changed
                changed = purgeList(machine, "fluidOutputs", match) or changed
            end
            if changed then
                touched = touched + 1
            end
        end
    elseif kind == "signals" then
        local match = function(entry) return entry == name end
        for _, machine in ipairs(self:list("machines")) do
            if purgeList(machine, "signals", match) then
                touched = touched + 1
            end
        end
    end
    if touched > 0 then
        self:markDirty()
        if self.log then
            self.log("Cleared references to the deleted %s %s in %d machine(s)", tostring(kind),
                tostring(name), touched)
        end
    end
    return touched
end
--- 存储容器与交互容器都用外设名作定义名 —— 一个外设 + 一种容器只对应一个定义，用户不必（也不该）起名。
function Store:containerNameFor(obj, name)
    local plain = Store.containerPlainName(self.Util.trim(name or ""))
    if (obj.role or "storage") == "output" then
        return plain
    end
    local derived = Store.containerPlainName(self.Util.trim(obj.peripheral or ""))
    if derived ~= "" then
        return derived
    end
    return plain
end

--- 信号定义名：红石信号不再需要命名 —— 定义名恒等于中继器的外设名（一个中继器一个定义）。
--- 兼容旧配置：机器里写的旧“信号定义名”仍然能解析（见 Recipe:signalPeripheralOf）。
function Store:signalNameFor(obj, name)
    local derived = self.Util.trim((obj or {}).peripheral or "")
    if derived ~= "" then
        return derived
    end
    return self.Util.trim(name or "")
end

--- 丢掉同一个中继器的旧信号定义（名字不同）：信号改用外设名之后，旧的自定义名字要让位，
--- 否则会留下两个指向同一个外设的定义（界面上看起来像两台不同的信号）。
function Store:dropSignalByPeripheral(peripheral, keepName)
    if type(peripheral) ~= "string" or peripheral == "" then
        return false
    end
    local dropped = false
    for _, def in ipairs(self:list("signals")) do
        if def.peripheral == peripheral and def.name ~= keepName then
            self.data.signals[def.name] = nil
            dropped = true
        end
    end
    return dropped
end

--- 丢掉同一个外设 + 同一种类的旧定义（名字不同）。
--- 非输出容器改用外设名作定义名后，旧配置里自定义的名字要让位；否则校验会报
--- “外设已经分配给容器定义 xxx”而存不进去。
function Store:dropContainerByPeripheral(containerKind, peripheral, keepName)
    if type(peripheral) ~= "string" or peripheral == "" then
        return false
    end
    local dropped = false
    for _, def in ipairs(self:list("containers")) do
        local defKind = self.Util.kindOfDef(def)
        if defKind == containerKind and def.peripheral == peripheral and def.name ~= keepName then
            self.data.containers[Store.containerKey(defKind, def.name)] = nil
            dropped = true
        end
    end
    return dropped
end

--- 局部更新一条 settings（1.8.0）：读出现有内容 → 覆盖 patch 里的键 → 整条写回。
--- 为什么需要它：Store:set 是**整条替换** —— 直接提交 { slices = ..., sendLog = false } 会把
--- localPool 这个键一起丢掉，读回来又回落成默认 true，表现就是"关掉一个开关，另一个自己打开，
--- 两个永远无法同时关闭"（用户第 5 项）。网页提交调度设置走这里，只覆盖它带的字段。
function Store:patchSettings(name, patch, opts)
    local current = self:get("settings", name)
    local merged = {}
    if type(current) == "table" then
        for key, value in pairs(current) do
            merged[key] = value
        end
    end
    if type(patch) == "table" then
        for key, value in pairs(patch) do
            merged[key] = value
        end
    end
    return self:set("settings", name, merged, opts)
end

--- 新增/修改定义。
--- opts.previous：编辑前的旧键（容器是 "种类:名称"，其它定义是名称），用于重命名：
--- 旧定义在校验前先摘掉 —— 否则“同一外设每种容器只能用一个名字”的检查会把“编辑自己”当成冲突，
--- 于是改名永远存不进去；校验失败时原样还原（等于没动过），通过后不再写回旧键（改名完成）。
function Store:set(kind, name, obj, opts)
    if not self.data[kind] then
        return false, "\\u672A\\u77E5\\u7684\\u914D\\u7F6E\\u7C7B\\u578B " .. tostring(kind)
    end
    obj = obj or {}
    --- 编辑（可能是改名）：先把旧定义摘下来 —— 校验与“同外设让位”期间它不该再算占用，
    --- 失败时再原样放回（等于没动过）。注意必须早于 dropContainerByPeripheral：
    --- 否则那一步会先把旧定义删掉，这里就再也拿不回备份、失败后也还原不出来。
    local previousKey = type(opts) == "table" and opts.previous or nil
    local previousDef = nil
    if type(previousKey) == "string" and previousKey ~= "" then
        previousDef = self.data[kind][previousKey]
        if previousDef then
            self.data[kind][previousKey] = nil
        end
    end
    local function restorePrevious()
        if previousDef then
            self.data[kind][previousKey] = previousDef
        end
    end
    if kind == "containers" then
        -- 容器定义可能带 "item:"/"fluid:" 前缀（网页用“种类:名称”作键）：这里只保留纯名称；
        -- 非输出容器（存储 / 交互）用外设名作定义名（用户不需要也不允许给它们起名字）
        name = self:containerNameFor(obj, name or obj.name)
        if (obj.role or "storage") ~= "output" then
            self:dropContainerByPeripheral(self.Util.kindOfDef(obj), obj.peripheral, name)
        end
    elseif kind == "signals" then
        --- 红石信号不再需要命名：定义名就是中继器的外设名（拖外设到机器的信号卡片即可）。
        --- 旧配置里的自定义信号名会被同名外设的新定义顶掉，机器若还写着旧名字，
        --- 由 Recipe:signalPeripheralOf 兜底按外设名解析（兼容旧配置）。
        name = self:signalNameFor(obj, name or obj.name)
        self:dropSignalByPeripheral(obj.peripheral, name)
    else
        name = self.Util.trim(name or obj.name or "")
    end
    if not isName(name) then
        restorePrevious()
        return false, "\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
    end
    local ok, err = self:validate(kind, name, obj)
    if not ok then
        restorePrevious()
        return false, err
    end
    local normalized = self:normalize(kind, name, obj)
    normalized.name = name
    if kind == "containers" then
        -- 物品容器与流体容器允许同名：内部以“种类:名称”为键
        self.data.containers[Store.containerKey(normalized.kind, name)] = normalized
    else
        self.data[kind][name] = normalized
    end
    self:markDirty()
    if self.onChange then
        self.onChange(kind, name)
    end
    return true
end

--- 删除定义。
--- 默认在“被别的定义引用”时拒绝，避免误删；带 opts.force（网页上删除缺失外设的定义时会带）则允许强制删除：
--- 引用它的机器/流程会被冻结（`state = missing`），重新建出同名定义后自动恢复 —— 这正是“换外设”的流程。
function Store:delete(kind, name, containerKind, opts)
    local key = name
    if kind == "containers" then
        local def = self:findContainer(name, containerKind)
        if not def then
            return false, "\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728"
        end
        key = Store.containerKey(def.kind, def.name)
        containerKind = def.kind
        name = def.name
    end
    if not self.data[kind] or not self.data[kind][key] then
        return false, "\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728"
    end
    local refs = self:references(kind, name, containerKind)
    if #refs > 0 then
        local head = table.concat(refs, "\\u3001", 1, math.min(#refs, 3))
        if #refs > 3 then
            head = head .. " \\u7B49"
        end
        if not (opts and opts.force) then
            return false, "\\u8BE5\\u5B9A\\u4E49\\u6B63\\u88AB\\u5F15\\u7528\\uFF1A" .. head
        end
        --- 强制删除：把“还被谁引用”写进日志；引用方会被冻结，等同名定义回来再自动恢复
        if self.log then
            self.log("Force delete %s %s (still referenced by: %s)", tostring(kind), tostring(name), head)
        end
        --- 用户第 3 项：顺手把机器里的引用摘掉 —— 一键删除缺失外设之后，机器卡片上那张
        --- 「缺失的外设卡片」也要跟着消失（以前只删定义、机器里留着名字，看起来"没删掉"）。
        self:purgeReferences(kind, name, containerKind)
    end
    self.data[kind][key] = nil
    self:markDirty()
    if self.onChange then
        self.onChange(kind, name)
    end
    return true
end

--- 一个机器用到的外设名集合（输入/输出容器定义的外设 + 信号解析出的中继器）。
--- 现在只用于诊断/展示：1.6.9 起同一个外设允许被多台机器引用（用户明确要求），
--- 所以不再用它做“一个外设只属于一个机器”的校验。
function Store:machinePeripheralNames(machine)
    local out = {}
    if type(machine) ~= "table" then
        return out
    end
    local groups = {
        { machine.itemInputs, "item" },
        { machine.fluidInputs, "fluid" },
        { machine.itemOutputs, "item" },
        { machine.fluidOutputs, "fluid" },
    }
    for _, group in ipairs(groups) do
        for _, containerName in ipairs(group[1] or {}) do
            local def = self:findContainer(containerName, group[2])
            local peripheral = def and def.peripheral or nil
            if type(peripheral) == "string" and peripheral ~= "" then
                out[peripheral] = true
            end
        end
    end
    for _, signalEntry in ipairs(machine.signals or {}) do
        --- 信号项可能是旧定义名，也可能直接是外设名（1.6.9 起信号不再需要命名）
        local def = self:get("signals", signalEntry)
        local peripheral = (def and def.peripheral) or (type(signalEntry) == "string" and signalEntry or nil)
        if type(peripheral) == "string" and peripheral ~= "" then
            out[peripheral] = true
        end
    end
    return out
end

--- 归一化流程元素
function Store:normalizeElement(el, allowPlaceholder)
    if type(el) ~= "table" then
        return nil
    end
    local Util = self.Util
    local kind = el.kind
    if kind == "item" or kind == "fluid" or kind == "filter" then
        return {
            kind = kind,
            id = el.id or "",
            nbt = el.nbt or "",
            ignoreNbt = el.ignoreNbt ~= false,
            count = math.max(0, Util.num(el.count, 0)),
            containerIndex = Util.int(el.containerIndex, -1),
            slot = Util.int(el.slot, -1),
            min = math.max(0, Util.num(el.min, 0)),
            max = math.max(0, Util.num(el.max, 0)),
            priority = Util.num(el.priority, 0),
        }
    elseif kind == "placeholder" and allowPlaceholder then
        return {
            kind = kind,
            name = el.name or "",
            item = el.item or "",
        }
    elseif kind == "waitSignal" or kind == "emitSignal" or kind == "emitPulse" then
        -- 红石元素只引用机器定义里的信号序号（机器 signals 列表的序号，从 1 开始）：默认 1，不再有全局信号序号
        return {
            kind = kind,
            machineSignalIndex = Util.int(el.machineSignalIndex, 1),
            sides = normalizeSides(el.sides),
            threshold = Util.clamp(Util.num(el.threshold, 0), 0, 15),
            op = VALID_OPS[el.op] and el.op or "ge",
            strength = Util.clamp(Util.num(el.strength, 15), 0, 15),
        }
    elseif kind == "waitTime" then
        return {
            kind = kind,
            seconds = math.max(0, Util.num(el.seconds, 1)),
        }
    end
    return nil
end

--- 归一化定义（宽松，用于读取或写入前的整理）
function Store:normalize(kind, name, obj)
    local Util = self.Util
    if kind == "containers" then
        return {
            name = name,
            peripheral = obj.peripheral or "",
            kind = VALID_CONTAINER_KINDS[obj.kind] and obj.kind or "item",
            role = VALID_ROLES[obj.role] and obj.role or "storage",
            -- 存储优先级（可选参数，缺省 0）：越大越先存入、越小越先取出，见 README「容器优先级」
            priority = Util.int(obj.priority, 0),
        }
    elseif kind == "signals" then
        return {
            name = name,
            peripheral = obj.peripheral or "",
        }
    elseif kind == "filters" then
        local rules = {}
        for _, rule in ipairs(obj.rules or {}) do
            if type(rule) == "table" then
                rules[#rules + 1] = {
                    type = rule.type,
                    id = rule.id or "",
                    nbt = rule.nbt or "",
                    ignoreNbt = rule.ignoreNbt == true,
                }
            end
        end
        return {
            name = name,
            rules = rules,
        }
    elseif kind == "machineTypes" then
        return {
            name = name,
        }
    elseif kind == "machines" then
        return {
            name = name,
            type = obj.type or "",
            itemInputs = normalizeStringList(obj.itemInputs),
            fluidInputs = normalizeStringList(obj.fluidInputs),
            signals = normalizeStringList(obj.signals),
            itemOutputs = normalizeStringList(obj.itemOutputs),
            fluidOutputs = normalizeStringList(obj.fluidOutputs),
            parallel = math.max(1, Util.int(obj.parallel, 1)),
        }
    elseif kind == "processes" then
        local inputs = {}
        for _, el in ipairs(obj.inputs or {}) do
            local norm = self:normalizeElement(el, false)
            if norm then
                inputs[#inputs + 1] = norm
            end
        end
        local outputs = {}
        for _, el in ipairs(obj.outputs or {}) do
            local norm = self:normalizeElement(el, true)
            if norm then
                outputs[#outputs + 1] = norm
            end
        end
        return {
            name = name,
            machineType = obj.machineType or "",
            inputs = inputs,
            outputs = outputs,
            maxMultiplier = math.max(1, Util.int(obj.maxMultiplier, 1)),
        }
    end
    return Util.deepcopy(obj)
end

--- 过滤器规则校验（自引用与循环引用）
local function validateFilterRules(store, filterName, rules)
    rules = rules or {}
    for i, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            return false, "\\u89C4\\u5219 " .. i .. " \\u4E0D\\u662F\\u8868"
        end
        if not KNOWN_RULE_TYPES[rule.type] then
            return false, "\\u89C4\\u5219 " .. i .. " \\u7684\\u7C7B\\u578B\\u672A\\u77E5\\uFF1A" .. tostring(rule.type)
        end
        if not isName(rule.id) then
            return false, "\\u89C4\\u5219 " .. i .. " \\u7F3A\\u5C11\\u76EE\\u6807"
        end
        if rule.type == "filter_include" or rule.type == "filter_exclude" then
            if rule.id == filterName then
                return false, "\\u8FC7\\u6EE4\\u5668\\u4E0D\\u80FD\\u5F15\\u7528\\u81EA\\u8EAB"
            end
            if not store:get("filters", rule.id) then
                return false, "\\u8FC7\\u6EE4\\u5668 " .. tostring(rule.id) .. " \\u4E0D\\u5B58\\u5728"
            end
        end
    end
    local function walks(name, path)
        local filter = store:get("filters", name)
        if not filter then
            return false
        end
        if path[name] then
            return true
        end
        path[name] = true
        for _, rule in ipairs(filter.rules or {}) do
            if rule.type == "filter_include" or rule.type == "filter_exclude" then
                if walks(rule.id, path) then
                    path[name] = nil
                    return true
                end
            end
        end
        path[name] = nil
        return false
    end
    if walks(filterName, {}) then
        return false, "\\u8FC7\\u6EE4\\u5668\\u5B58\\u5728\\u5FAA\\u73AF\\u5F15\\u7528"
    end
    return true
end

--- 流程元素校验
function Store:validateElement(el, allowPlaceholder, index, label)
    if type(el) ~= "table" then
        return false, label .. "\\u5143\\u7D20 " .. index .. " \\u4E0D\\u662F\\u8868"
    end
    local Util = self.Util
    local kind = el.kind
    if kind == "item" or kind == "fluid" or kind == "filter" then
        if not isName(el.id) then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7F3A\\u5C11\\u8D44\\u6E90\\u540D\\u79F0"
        end
        if kind == "filter" and not self:get("filters", el.id) then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u8FC7\\u6EE4\\u5668 " .. el.id .. " \\u4E0D\\u5B58\\u5728"
        end
        if allowPlaceholder then
            local minAmount = Util.num(el.min, 0)
            local maxAmount = Util.num(el.max, 0)
            if maxAmount <= 0 then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u201C\\u6700\\u591A\\u6570\\u76EE\\u201D\\u5FC5\\u987B\\u5927\\u4E8E 0"
            end
            if minAmount > maxAmount then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u201C\\u6700\\u5C11\\u6570\\u76EE\\u201D\\u4E0D\\u80FD\\u5927\\u4E8E\\u201C\\u6700\\u591A\\u6570\\u76EE\\u201D"
            end
        else
            if Util.num(el.count, 0) <= 0 then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u6570\\u76EE\\u5FC5\\u987B\\u5927\\u4E8E 0"
            end
            if Util.int(el.containerIndex, -1) < -1 then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u5BB9\\u5668\\u5E8F\\u53F7\\u4E0D\\u80FD\\u5C0F\\u4E8E -1"
            end
            if Util.int(el.slot, -1) < -1 then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u69FD\\u4F4D\\u4E0D\\u80FD\\u5C0F\\u4E8E -1"
            end
        end
        return true
    elseif kind == "placeholder" then
        if not allowPlaceholder then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u4E0D\\u80FD\\u662F\\u5360\\u4F4D\\u7B26"
        end
        if not isName(el.name) then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u5360\\u4F4D\\u7B26\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
        end
        if not isName(el.item) then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u5360\\u4F4D\\u7B26\\u5173\\u8054\\u7269\\u54C1\\u4E0D\\u80FD\\u4E3A\\u7A7A"
        end
        return true
    elseif kind == "waitSignal" or kind == "emitSignal" or kind == "emitPulse" then
        local machineSignalIndex = Util.int(el.machineSignalIndex, 1)
        -- 等待红石信号 / 设置红石信号 / 发出红石脉冲都只引用机器定义里的信号序号（从 1 开始），
        -- 全局“红石信号序号”已移除：必须指定机器信号序号
        if machineSignalIndex < 1 then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u5FC5\\u987B\\u6307\\u5B9A\\u673A\\u5668\\u7EA2\\u77F3\\u4FE1\\u53F7\\u5E8F\\u53F7\\uFF08\\u673A\\u5668\\u5B9A\\u4E49 signals \\u5217\\u8868\\u7684\\u5E8F\\u53F7\\uFF0C\\u4ECE 1 \\u5F00\\u59CB\\uFF09"
        end
        for _, side in ipairs(el.sides or {}) do
            if not VALID_SIDES[side] then
                return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u65B9\\u5411 " .. tostring(side) .. " \\u65E0\\u6548"
            end
        end
        if el.op ~= nil and not VALID_OPS[el.op] then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u6BD4\\u8F83\\u7B26\\u53F7\\u65E0\\u6548"
        end
        return true
    elseif kind == "waitTime" then
        if Util.num(el.seconds, -1) < 0 then
            return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u65F6\\u957F\\u4E0D\\u80FD\\u4E3A\\u8D1F"
        end
        return true
    end
    return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u7C7B\\u578B\\u672A\\u77E5\\uFF1A" .. tostring(kind)
end

--- 抽象操作（用户第 3 项，取代原来的"虚操作"元素）：把物品/流体元素的**注册名写成 abstract**
--- 就表示"这里以后要换成真实材料/产物"，它不对应任何真实资源。
Store.ABSTRACT_ID = "abstract"

--- 单个元素是不是抽象操作。只有物品/流体能是抽象操作 —— 过滤器指向的是真实的过滤器定义。
function Store.elementIsAbstract(element)
    if type(element) ~= "table" then
        return false
    end
    if element.kind ~= "item" and element.kind ~= "fluid" then
        return false
    end
    return element.id == Store.ABSTRACT_ID
end

--- 流程里是否含抽象操作（物品/流体注册名 = abstract）：含它的流程是**抽象流程** ——
--- 不能执行 / 不能被选作上游 / 不能下单合成，但可以保存，也可以作为网页"流程设置复制"的来源。
--- 引擎（modules/recipe.lua）与主控（IFMMaster.lua）都用它做判断。
function Store.processIsAbstract(process)
    if type(process) ~= "table" then
        return false
    end
    local function has(list)
        for _, element in ipairs(type(list) == "table" and list or {}) do
            if Store.elementIsAbstract(element) then
                return true
            end
        end
        return false
    end
    return has(process.inputs) or has(process.outputs)
end

--- 定义校验
function Store:validate(kind, name, obj)
    local Util = self.Util
    if not isName(name) then
        return false, "\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
    end
    obj = obj or {}
    if kind == "containers" then
        if not isName(obj.peripheral) then
            return false, "\\u5916\\u8BBE\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
        end
        if not VALID_ROLES[obj.role] then
            return false, "\\u5BB9\\u5668\\u89D2\\u8272\\u5FC5\\u987B\\u662F storage\\u3001input\\u3001interaction \\u6216 output"
        end
        if obj.kind ~= nil and not VALID_CONTAINER_KINDS[obj.kind] then
            return false, "\\u5BB9\\u5668\\u79CD\\u7C7B\\u5FC5\\u987B\\u662F item\\uFF08\\u7269\\u54C1\\uFF09\\u6216 fluid\\uFF08\\u6D41\\u4F53\\uFF09"
        end
        if obj.priority ~= nil and tonumber(obj.priority) == nil then
            return false, "\\u5BB9\\u5668\\u4F18\\u5148\\u7EA7\\u5FC5\\u987B\\u662F\\u6570\\u5B57"
        end
        -- 每个 inventory / fluid_storage 外设（按种类）只允许分配到一个容器定义名字
        local containerKind = Util.kindOfDef(obj)
        for _, def in ipairs(self:list("containers")) do
            local defKind = Util.kindOfDef(def)
            if def.peripheral == obj.peripheral and defKind == containerKind and def.name ~= name then
                return false, "\\u5916\\u8BBE " .. tostring(obj.peripheral) .. " \\u5DF2\\u7ECF\\u5206\\u914D\\u7ED9\\u5BB9\\u5668\\u5B9A\\u4E49 " .. def.name
                    .. "\\uFF08\\u540C\\u4E00\\u5916\\u8BBE\\u6BCF\\u79CD\\u5BB9\\u5668\\u53EA\\u80FD\\u7528\\u4E00\\u4E2A\\u540D\\u5B57\\uFF09"
            end
        end
        return true
    elseif kind == "signals" then
        if not isName(obj.peripheral) then
            return false, "\\u5916\\u8BBE\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
        end
        return true
    elseif kind == "filters" then
        return validateFilterRules(self, name, obj.rules)
    elseif kind == "machineTypes" then
        return true
    elseif kind == "machines" then
        if not isName(obj.type) then
            return false, "\\u5FC5\\u987B\\u6307\\u5B9A\\u673A\\u5668\\u7C7B\\u578B"
        end
        if not self:get("machineTypes", obj.type) then
            return false, "\\u673A\\u5668\\u7C7B\\u578B " .. tostring(obj.type) .. " \\u4E0D\\u5B58\\u5728"
        end
        local groups = {
            { obj.itemInputs, "\\u7269\\u54C1\\u8F93\\u5165\\u5BB9\\u5668", "item" },
            { obj.fluidInputs, "\\u6D41\\u4F53\\u8F93\\u5165\\u5BB9\\u5668", "fluid" },
            { obj.itemOutputs, "\\u7269\\u54C1\\u8F93\\u51FA\\u5BB9\\u5668", "item" },
            { obj.fluidOutputs, "\\u6D41\\u4F53\\u8F93\\u51FA\\u5BB9\\u5668", "fluid" },
        }
        for _, group in ipairs(groups) do
            local wantedKind = group[3]
            for _, containerName in ipairs(group[1] or {}) do
                local container = self:findContainer(containerName, wantedKind)
                if not container then
                    return false, group[2] .. " " .. tostring(containerName) .. " \\u4E0D\\u5B58\\u5728\\u6216\\u4E0D\\u662F"
                        .. (wantedKind == "fluid" and "\\u6D41\\u4F53\\u5BB9\\u5668" or "\\u7269\\u54C1\\u5BB9\\u5668")
                end
                if container.role ~= "interaction" then
                    return false, group[2] .. " " .. tostring(containerName) .. " \\u7684\\u89D2\\u8272\\u5FC5\\u987B\\u662F interaction"
                end
            end
        end
        for _, signalEntry in ipairs(obj.signals or {}) do
            --- 红石信号不再需要命名：这一项既可以是旧的“信号定义名”，也可以直接是
            --- 红石中继器的外设名（把外设拖到机器的信号卡片上产生的就是后者）。
            --- 外设是否存在由引擎检查（Recipe:machineProblem 会给出可读原因）。
            if not isName(signalEntry) then
                return false, "\\u4FE1\\u53F7\\u540D\\u4E0D\\u80FD\\u4E3A\\u7A7A"
            end
        end
        --- 1.6.9：允许同一个外设（交互容器 / 红石中继器）被多台机器引用 ——
        --- 用户明确要求“交互容器可以属于多个机器”“一个红石中继器可以给多台机器用”。
        --- 注意（使用提示）：两台机器共用同一个输入/输出容器时会同时往里搬 / 同时读它的信号，
        --- 这是配置者自己的选择；IFM 不再替它拦下来。
        if Util.int(obj.parallel, 1) < 1 then
            return false, "\\u5E76\\u884C\\u4FE1\\u53F7\\u91CF\\u5FC5\\u987B\\u5927\\u4E8E\\u7B49\\u4E8E 1"
        end
        return true
    elseif kind == "processes" then
        if not isName(obj.machineType) then
            return false, "\\u5FC5\\u987B\\u6307\\u5B9A\\u673A\\u5668\\u7C7B\\u578B"
        end
        if not self:get("machineTypes", obj.machineType) then
            return false, "\\u673A\\u5668\\u7C7B\\u578B " .. tostring(obj.machineType) .. " \\u4E0D\\u5B58\\u5728"
        end
        if Util.int(obj.maxMultiplier, 1) < 1 then
            return false, "\\u6700\\u5927\\u7FFB\\u500D\\u6570\\u5FC5\\u987B\\u5927\\u4E8E\\u7B49\\u4E8E 1"
        end
        local inputs = obj.inputs or {}
        local outputs = obj.outputs or {}
        if #inputs == 0 and #outputs == 0 then
            return false, "\\u6D41\\u7A0B\\u81F3\\u5C11\\u8981\\u6709\\u4E00\\u4E2A\\u8F93\\u5165\\u6216\\u8F93\\u51FA\\u5143\\u7D20"
        end
        for i, el in ipairs(inputs) do
            local ok, err = self:validateElement(el, false, i, "\\u8F93\\u5165")
            if not ok then
                return false, err
            end
        end
        for i, el in ipairs(outputs) do
            local ok, err = self:validateElement(el, true, i, "\\u8F93\\u51FA")
            if not ok then
                return false, err
            end
        end
        return true
    elseif kind == "settings" then
        -- 全局设置：
        -- "schedule" —— 各队列的调度时间片（正整数，1 ~ 50）
        --   "scan"     —— 旧的容器扫描间隔（毫秒，250 ~ 600000；1.7.0 起被调度时间片取代，仅作兼容保留）
        --   "schedule" —— 各队列的调度时间片（正整数，1 ~ 50）
        local limits = Store.SCAN_LIMITS
        for _, field in ipairs({ "storageScanMs", "inputScanMs" }) do
            if obj[field] ~= nil then
                local value = tonumber(obj[field])
                if not value then
                    return false, field .. " must be a number (milliseconds)"
                end
                if value < limits.min or value > limits.max then
                    return false, field .. " out of range (" .. limits.min .. " ~ " .. limits.max .. " ms)"
                end
            end
        end
        if obj.slices ~= nil then
            if type(obj.slices) ~= "table" then
                return false, "slices must be a table"
            end
            local limits = Store.SCHEDULE_LIMITS
            local maxShare = Store.weightMax()
            for name, value in pairs(obj.slices) do
                if Store.SCHEDULE_DEFAULTS[name] == nil then
                    return false, "unknown queue " .. tostring(name)
                end
                local number = tonumber(value)
                if not number then
                    return false, "weight for " .. tostring(name) .. " must be a number"
                end
                if number < limits.min or number > maxShare then
                    return false, "weight for " .. tostring(name) .. " out of range (" ..
                        limits.min .. " ~ " .. maxShare .. ")"
                end
            end
        end
        return true
    end
    return false, "\\u672A\\u77E5\\u7684\\u914D\\u7F6E\\u7C7B\\u578B " .. tostring(kind)
end

return Store
