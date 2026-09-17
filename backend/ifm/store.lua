-- IFM :: ifm/store.lua
-- 定义数据模型（config.json）：容器定义、信号定义、过滤器定义、机器类型、机器、流程。
-- 所有定义都保存在 data[kind][name] 中；set/delete 走校验，变更后自动去抖写盘。

local Store = {}
Store.__index = Store

Store.KINDS = { "containers", "signals", "filters", "machineTypes", "machines", "processes" }

local VALID_ROLES = { storage = true, interaction = true, output = true }
--- 容器定义的种类：item = 物品容器（inventory 外设），fluid = 流体容器（fluid_storage 外设）。
--- 同一个方块可能同时提供这两种外设（例如 create:basin_0），因此允许分别建立两个容器定义。
local VALID_CONTAINER_KINDS = { item = true, fluid = true }
local VALID_SIDES = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local VALID_OPS = { gt = true, ge = true, eq = true, le = true, lt = true }

Store.VALID_ROLES = VALID_ROLES
Store.VALID_CONTAINER_KINDS = VALID_CONTAINER_KINDS
Store.VALID_SIDES = VALID_SIDES
Store.VALID_OPS = VALID_OPS
Store.roleList = { "storage", "interaction", "output" }
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
--- 物品容器与流体容器**允许同名**（例如同一个工作盆：物品“工作盆” + 流体“工作盆”），
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
    }
end

function Store.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Store)
    self.Util = opts.Util
    --- 落盘统一交给 ifm/jsonfile.lua（读 / 原子写 / 去抖都在那边）
    local JsonFile = opts.JsonFile
    if not JsonFile then
        error("store.lua needs the jsonfile module: pass opts.JsonFile (loadModule(\"jsonfile\"))", 0)
    end
    self.file = JsonFile.new({
        path = opts.path or "/ifm/config.json",
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

--- 立即写盘（原子写由 ifm/jsonfile.lua 负责）
function Store:flush()
    return self.file:flush(self.data)
end

function Store:get(kind, name, containerKind)
    if kind == "containers" then
        return self:findContainer(name, containerKind)
    end
    local bucket = self.data[kind]
    if not bucket or type(name) ~= "string" then
        return nil
    end
    return bucket[name]
end

--- 查找容器定义：nameOrKey 可以是纯名称（可指定 kind）或 "item:名称"/"fluid:名称" 键。
--- 只给纯名称且没给 kind 时，优先物品容器、其次流体容器。
function Store:findContainer(nameOrKey, containerKind)
    if type(nameOrKey) ~= "string" or nameOrKey == "" then
        return nil
    end
    local direct = self.data.containers[nameOrKey]
    if direct then
        return direct
    end
    local plain = Store.containerPlainName(nameOrKey)
    if containerKind then
        return self.data.containers[Store.containerKey(containerKind, plain)]
    end
    return self.data.containers[Store.containerKey("item", plain)]
        or self.data.containers[Store.containerKey("fluid", plain)]
end

--- 按名称排序的数组
function Store:list(kind)
    local bucket = self.data[kind] or {}
    local names = {}
    for name in pairs(bucket) do
        names[#names + 1] = name
    end
    table.sort(names)
    local out = {}
    for i = 1, #names do
        out[i] = bucket[names[i]]
    end
    return out
end

function Store:names(kind)
    local bucket = self.data[kind] or {}
    local names = {}
    for name in pairs(bucket) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
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

--- 容器定义名：**只有输出容器需要用户起名字**（机器按名字引用它、点「发送」也要选它）；
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

--- 新增/修改定义。
--- opts.previous：编辑前的旧键（容器是 "种类:名称"，其它定义是名称），用于**重命名**：
--- 旧定义在校验前先摘掉 —— 否则“同一外设每种容器只能用一个名字”的检查会把“编辑自己”当成冲突，
--- 于是改名永远存不进去；校验失败时原样还原（等于没动过），通过后不再写回旧键（改名完成）。
function Store:set(kind, name, obj, opts)
    if not self.data[kind] then
        return false, "\\u672A\\u77E5\\u7684\\u914D\\u7F6E\\u7C7B\\u578B " .. tostring(kind)
    end
    obj = obj or {}
    --- 编辑（可能是改名）：**先把旧定义摘下来** —— 校验与“同外设让位”期间它不该再算占用，
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
    end
    self.data[kind][key] = nil
    self:markDirty()
    if self.onChange then
        self.onChange(kind, name)
    end
    return true
end

--- 一个机器用到的**外设名集合**（输入/输出容器定义的外设 + 信号定义的外设）。
--- 用途：校验“一个外设只隶属于一个机器” —— 两台机器共用一个外设会互相抢外设（引擎会同时向它搬运/读信号）。
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
    for _, signalName in ipairs(machine.signals or {}) do
        local def = self:get("signals", signalName)
        local peripheral = def and def.peripheral or nil
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
        -- 红石元素只引用**机器定义**里的信号序号（机器 signals 列表的序号，从 1 开始）：默认 1，不再有全局信号序号
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
    elseif kind == "virtual" then
        -- 虚操作（抽象模板元素）：不对应任何真实资源，输入/输出都能放；
        -- 含虚操作的流程**不能合成**，只作为网页“流程设置复制”的来源。
        return {
            kind = kind,
            name = el.name or "",
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
    elseif kind == "virtual" then
        -- 虚操作：输入与输出都可以放（它就是“这里以后要换成真实材料/产物”的占位步骤）。
        -- 名称必须有，网页端在复制到别的流程后要靠它认出这一行。
        if not isName(el.name) then
            return false, label .. "\\u5143\\u7D20 " .. index .. "\\u7684\\u865A\\u64CD\\u4F5C\\u540D\\u79F0\\u4E0D\\u80FD\\u4E3A\\u7A7A"
        end
        return true
    end
    return false, label .. "\\u5143\\u7D20 " .. index .. " \\u7684\\u7C7B\\u578B\\u672A\\u77E5\\uFF1A" .. tostring(kind)
end

--- 流程里是否含有“虚操作”元素（kind = "virtual"）：含虚操作的流程是**抽象模板** —— 
--- 不能执行 / 不能被选作上游 / 不能下单合成，只能被网页的“流程设置复制”拷贝到别的流程。
--- 引擎（ifm/recipe.lua）与主控（IFMMaster.lua）都用它做判断。
function Store.processHasVirtual(process)
    if type(process) ~= "table" then
        return false
    end
    local function has(list)
        for _, element in ipairs(type(list) == "table" and list or {}) do
            if type(element) == "table" and element.kind == "virtual" then
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
            return false, "\\u5BB9\\u5668\\u89D2\\u8272\\u5FC5\\u987B\\u662F storage\\u3001interaction \\u6216 output"
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
        for _, signalName in ipairs(obj.signals or {}) do
            if not self:get("signals", signalName) then
                return false, "\\u4FE1\\u53F7 " .. tostring(signalName) .. " \\u4E0D\\u5B58\\u5728"
            end
        end
        --- 一个外设只隶属于一个机器：同一个外设（容器/信号背后的方块）不能同时出现在另一台机器里 ——
        --- 两台机器共用一个外设会互相抢（引擎会同时往它搬东西 / 同时读它的红石信号）。
        local mine = self:machinePeripheralNames(obj)
        for _, other in ipairs(self:list("machines")) do
            if other.name ~= name then
                local used = self:machinePeripheralNames(other)
                for peripheral in pairs(mine) do
                    if used[peripheral] then
                        return false, "\\u5916\\u8BBE " .. tostring(peripheral) ..
                            " \\u5DF2\\u7ECF\\u5C5E\\u4E8E\\u673A\\u5668 " .. tostring(other.name) ..
                            "\\uFF08\\u4E00\\u4E2A\\u5916\\u8BBE\\u53EA\\u80FD\\u5C5E\\u4E8E\\u4E00\\u4E2A\\u673A\\u5668\\uFF09"
                    end
                end
            end
        end
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
    end
    return false, "\\u672A\\u77E5\\u7684\\u914D\\u7F6E\\u7C7B\\u578B " .. tostring(kind)
end

return Store
