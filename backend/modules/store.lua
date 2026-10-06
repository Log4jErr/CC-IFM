local Store = {}
Store.__index = Store

Store.KINDS = { "containers", "signals", "filters", "machineTypes", "machines", "processes", "settings" }

Store.SCHEDULE_NAME = "schedule"
-- Stock keeping lives in its own settings document: material key ("kind:name") ->
-- amount to keep in storage. A missing entry (or 0) means "do not maintain".
Store.KEEP_NAME = "keepStock"
Store.SCHEDULE_DEFAULTS = {
    storageScan = 1, inputScan = 1,
    interactionScan = 1, outputScan = 1,
    inventoryIn = 1, inventoryOut = 1, compact = 1,
    detail = 1, manual = 1,
    stackScan = 1, containerSize = 1, slotLimit = 1,
}
-- The fixed walk order of the scheduler and the queues a time-slice weight can be
-- set for. Every dispatch queue has to appear here (the "process" entry is gone:
-- the engine's planning is not a queue any more - processes move their material
-- through inventoryIn / inventoryOut / compact like everything else).
Store.SCHEDULE_QUEUES = { "storageScan", "inputScan", "interactionScan", "outputScan",
    "containerSize", "slotLimit",
    "inventoryIn", "inventoryOut", "compact", "stackScan", "detail", "manual" }
Store.SCHEDULE_CENTS = 100
Store.SCHEDULE_LIMITS = { min = 0.01, max = 0.91, step = 0.01 }
Store.SCHEDULE_MIN_SHARE = 0.01
Store.SCHEDULE_COMPACT_FREE_DEFAULT = 0.30

function Store.weightMax()
    local maxCents = Store.SCHEDULE_CENTS - #Store.SCHEDULE_QUEUES
    return math.max(Store.SCHEDULE_MIN_SHARE, maxCents / Store.SCHEDULE_CENTS)
end

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

function Store.containerKey(containerKind, name)
    return (containerKind == "fluid" and "fluid:" or "item:") .. tostring(name or "")
end

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
    local localPool = saved.localPool
    if localPool == nil then
        localPool = false
    end
    local sendLog = saved.sendLog
    if sendLog == nil then
        sendLog = false
    end
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

-- The stock-keeping table: material key ("item:minecraft:iron_ingot" / "fluid:..." /
-- "filter:...") -> the amount the operator wants kept in storage. Only positive
-- entries are returned; an empty table means "nothing is maintained". The engine
-- persists the raw map, this reader validates/sanitises it on every read.
function Store:keepSettings()
    local saved = self:get("settings", Store.KEEP_NAME)
    local keep = {}
    if type(saved) == "table" and type(saved.keep) == "table" then
        for key, value in pairs(saved.keep) do
            local amount = math.floor(tonumber(value) or 0)
            if type(key) == "string" and key ~= "" and amount > 0 then
                keep[key] = amount
            end
        end
    end
    return keep
end

-- Set (or clear, with amount <= 0) the stock-keeping target of one material.
function Store:setKeepStock(key, amount)
    if type(key) ~= "string" or key == "" then
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_NAME_EMPTY)
    end
    local keep = self:keepSettings()
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        keep[key] = nil
    else
        keep[key] = amount
    end
    local ok, err = self:patchSettings(Store.KEEP_NAME, { keep = keep }, { force = true })
    if not ok then
        return false, err
    end
    return true, keep
end

function Store.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Store)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("store.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.Message = opts.Message
        or error("store.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    local JsonFile = opts.JsonFile
    if not JsonFile then
        error("store.lua needs the jsonfile module: pass opts.JsonFile (loadModule(\"jsonfile\"))", 0)
    end
    self.file = JsonFile.new({
        path = opts.path or "/data/config.json",
        log = opts.log,
        Message = self.Message,
    })
    self.log = opts.log or function() end
    self.onChange = opts.onChange
    self.data = Store.emptyData()
    -- Reverse reference index (kind -> sources); rebuilt lazily after any change.
    self.refIndex = nil
    self.refDirty = true
    return self
end

local function migratedKind(Assert, obj, where)
    if obj.kind == nil then
        return "item"
    end
    Assert.is(VALID_CONTAINER_KINDS[obj.kind] == true,
        "%s: container kind '%s' is invalid (expected item or fluid)", where, tostring(obj.kind))
    return obj.kind
end

local function migratedRole(Assert, obj, where)
    if obj.role == nil then
        return "storage"
    end
    Assert.is(VALID_ROLES[obj.role] == true,
        "%s: container role '%s' is invalid (expected storage / interaction / input / output)",
        where, tostring(obj.role))
    return obj.role
end

local function migratedOp(Assert, el)
    if el.op == nil then
        return "ge"
    end
    Assert.is(VALID_OPS[el.op] == true,
        "redstone element: op '%s' is invalid (expected gt / ge / eq / le / lt)", tostring(el.op))
    return el.op
end

function Store:load()
    local parsed, why = self.file:read("config.json")
    if not parsed then
        local exists = false
        if self.file.path and type(fs) == "table" and fs.exists then
            exists = fs.exists(self.file.path) == true
        end
        self.readOnly = exists and true or false
        if self.readOnly then
            self.log("config.json exists but could not be read (%s) - the store is READ-ONLY until it is " ..
                "fixed; nothing will be written back over it", self.Message.describe(why))
        end
        self.data = Store.emptyData()
        return false, why
    end
    self.data = Store.emptyData()
    self.data.room = type(parsed.room) == "string" and parsed.room or nil
    for _, kind in ipairs(Store.KINDS) do
        local src = parsed[kind]
        if type(src) == "table" then
            for key, obj in pairs(src) do
                if type(obj) ~= "table" or type(key) ~= "string" then
                    self.log.error("config.json: %s['%s'] is not a definition table (got %s) - " ..
                        "this entry is SKIPPED, fix or remove it", tostring(kind), tostring(key), type(obj))
                elseif kind == "containers" then
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
    return true
end

function Store:getRoom()
    return self.data.room
end

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
    self.refDirty = true
    self.sampleRevision = (self.sampleRevision or 0) + 1
end

function Store:revision()
    return tonumber(self.sampleRevision) or 0
end

function Store:tick(now)
    if not self.file:shouldFlush(now) then
        return false
    end
    return self:flush()
end

function Store:flush()
    if self.readOnly then
        return false, "config.json could not be read - refusing to overwrite it"
    end
    return self.file:flush(self.data)
end

Store.TURTLE_CRAFTER_TYPE = "turtle_crafter"

-- A built-in virtual machine type: a process that only declares a bridge between a
-- material and a filter. It has no peripheral, completes as soon as its input
-- exists, and its output operation just checks the filter against that input.
Store.TYPE_CONVERSION_TYPE = "type_conversion"
-- Its maximum multiplier is effectively unbounded: the batch size is bounded by the
-- downstream demand anyway, and a high cap keeps the planner from splitting one
-- request into many tiny instances.
Store.TYPE_CONVERSION_MAX_MULTIPLIER = 1000000

-- The IO mode of a process:
--   sequential : material operations run strictly in order (one at a time).
--   two_phase  : within a block they run in parallel, all inputs before all outputs.
--   unordered  : like two_phase, but input and output may progress at the same time
--                (an output does not wait for every input to be complete).
Store.IO_MODES = { sequential = true, two_phase = true, unordered = true }

function Store.isTypeConversion(value)
    if type(value) == "table" then
        value = value.type or value.machineType
    end
    return value == Store.TYPE_CONVERSION_TYPE
end


function Store:setVirtual(kind, list)
    self.virtual = self.virtual or {}
    local bucket = {}
    for _, def in ipairs(list or {}) do
        if type(def) == "table" and type(def.name) == "string" and def.name ~= "" then
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
    return bucket, changed
end

function Store:virtualOf(kind)
    return (self.virtual and self.virtual[kind]) or {}
end

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

-- Reverse lookup by peripheral name: the container tool resolves by peripheral
-- (stable) instead of by definition name (which changes when the role changes:
-- non-output roles derive the name from the peripheral, output containers use a
-- custom name).
function Store:findContainerByPeripheral(peripheralName, containerKind)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil, 0
    end
    local best, matches = nil, 0
    for _, def in ipairs(self:list("containers")) do
        if tostring(def.peripheral or "") == peripheralName then
            local defKind = self.Util.kindOfDef(def)
            if (not containerKind) or defKind == containerKind then
                matches = matches + 1
                if not best or tostring(def.name) < tostring(best.name) then
                    best = def
                end
            end
        end
    end
    return best, matches
end

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

-- Reverse reference index: for every definition that something else points at,
-- the list of *sources* that point at it. The index is rebuilt lazily whenever the
-- store changed (refDirty), so lookups are O(references) instead of O(definitions).
local function refKey(kind, name, containerKind)
    if kind == "containers" then
        return "containers\1" .. tostring(containerKind or "item") .. "\1" .. tostring(name)
    end
    return tostring(kind) .. "\1\1" .. tostring(name)
end

function Store:addRef(index, key, refKind, refName)
    local list = index[key]
    if not list then
        list = { seen = {} }
        index[key] = list
    end
    local id = refKind .. "\1" .. tostring(refName)
    if list.seen[id] then
        return
    end
    list.seen[id] = true
    list[#list + 1] = { kind = refKind, name = refName }
end

function Store:buildRefIndex()
    local index = {}
    for _, machine in ipairs(self:list("machines")) do
        local groups = {
            { machine.itemInputs, "item" },
            { machine.fluidInputs, "fluid" },
            { machine.itemOutputs, "item" },
            { machine.fluidOutputs, "fluid" },
        }
        for _, group in ipairs(groups) do
            for _, cname in ipairs(group[1] or {}) do
                self:addRef(index, refKey("containers", Store.containerPlainName(cname), group[2]),
                    "machine", machine.name)
            end
        end
        for _, sname in ipairs(machine.signals or {}) do
            self:addRef(index, refKey("signals", sname), "machine", machine.name)
        end
        if type(machine.type) == "string" and machine.type ~= "" then
            self:addRef(index, refKey("machineTypes", machine.type), "machine", machine.name)
        end
    end
    for _, filter in ipairs(self:list("filters")) do
        for _, rule in ipairs(filter.rules or {}) do
            if (rule.type == "filter_include" or rule.type == "filter_exclude")
                and rule.id ~= filter.name then
                self:addRef(index, refKey("filters", rule.id), "filter", filter.name)
            end
        end
    end
    for _, process in ipairs(self:list("processes")) do
        if type(process.machineType) == "string" and process.machineType ~= "" then
            self:addRef(index, refKey("machineTypes", process.machineType), "process", process.name)
        end
        for _, listName in ipairs({ "inputs", "outputs" }) do
            for _, el in ipairs(process[listName] or {}) do
                if el.kind == "filter" and type(el.id) == "string" then
                    self:addRef(index, refKey("filters", el.id), "process", process.name)
                end
            end
        end
    end
    self.refIndex = index
    self.refDirty = false
    return index
end

function Store:ensureRefIndex()
    if self.refDirty or not self.refIndex then
        self:buildRefIndex()
    end
    return self.refIndex
end

function Store:references(kind, name, containerKind)
    local ck = containerKind
    if kind == "containers" then
        ck = ck or (self:findContainer(name) or {}).kind or "item"
    end
    local list = self:ensureRefIndex()[refKey(kind, name, ck)]
    local out = {}
    for _, ref in ipairs(list or {}) do
        local key = ref.kind == "filter" and self.Message.KEYS.STORE_REF_FILTER
            or (ref.kind == "process" and self.Message.KEYS.STORE_REF_PROCESS
                or self.Message.KEYS.STORE_REF_MACHINE)
        out[#out + 1] = self.Message.msg(key, { name = ref.name })
    end
    return out
end

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

function Store:signalNameFor(obj, name)
    local derived = self.Util.trim((obj or {}).peripheral or "")
    if derived ~= "" then
        return derived
    end
    return self.Util.trim(name or "")
end

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

function Store:set(kind, name, obj, opts)
    if not self.data[kind] then
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_UNKNOWN_KIND, { kind = tostring(kind) })
    end
    obj = obj or {}
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
        name = self:containerNameFor(obj, name or obj.name)
        if (obj.role or "storage") ~= "output" then
            self:dropContainerByPeripheral(self.Util.kindOfDef(obj), obj.peripheral, name)
        end
    elseif kind == "signals" then
        name = self:signalNameFor(obj, name or obj.name)
        self:dropSignalByPeripheral(obj.peripheral, name)
    else
        name = self.Util.trim(name or obj.name or "")
    end
    if not isName(name) then
        restorePrevious()
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_NAME_EMPTY)
    end
    local ok, err = self:validate(kind, name, obj)
    if not ok then
        restorePrevious()
        return false, err
    end
    local normalized = self:normalize(kind, name, obj)
    normalized.name = name
    if kind == "containers" then
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

function Store:delete(kind, name, containerKind, opts)
    local key = name
    if kind == "containers" then
        local def = self:findContainer(name, containerKind)
        if not def then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_DEF_MISSING)
        end
        key = Store.containerKey(def.kind, def.name)
        containerKind = def.kind
        name = def.name
    end
    if not self.data[kind] or not self.data[kind][key] then
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_DEF_MISSING)
    end
    local refs = self:references(kind, name, containerKind)
    if #refs > 0 then
        local head = {}
        for index = 1, math.min(#refs, 3) do
            head[index] = refs[index]
        end
        if not (opts and opts.force) then
            local key = #refs > 3 and self.Message.KEYS.STORE_ERR_IN_USE_MORE
                or self.Message.KEYS.STORE_ERR_IN_USE
            return false, self.Message.msg(key, { refs = head })
        end
        if self.log then
        self.log("Force delete %s %s (still referenced by %d definition(s))",
            tostring(kind), tostring(name), #refs)
        end
        self:purgeReferences(kind, name, containerKind)
    end
    self.data[kind][key] = nil
    self:markDirty()
    if self.onChange then
        self.onChange(kind, name)
    end
    return true
end

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
        local def = self:get("signals", signalEntry)
        local peripheral = (def and def.peripheral) or (type(signalEntry) == "string" and signalEntry or nil)
        if type(peripheral) == "string" and peripheral ~= "" then
            out[peripheral] = true
        end
    end
    return out
end

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
            expect = math.max(0, Util.num(el.expect, Util.num(el.max, 0))),
            max = math.max(0, Util.num(el.max, 0)),
            -- "Craft reference": a process that outputs this material is a
            -- candidate when that material is requested. On by default; switching it
            -- off keeps the process out of the planning engine for that output
            -- (side products, manual-only processes).
            craft = el.craft ~= false,
            -- "Mix resources": material input filters only. True (the default,
            -- and what older definitions mean) lets one batch be filled by
            -- several matching resources; false binds the filter to one
            -- concrete resource when the instance is created.
            allowMix = el.allowMix ~= false,
            -- "Catalyst": this input is not multiplied by the instance's batch
            -- (multiplier) - a fixed amount per flow instance, however many rounds
            -- that instance represents.
            catalyst = el.catalyst == true,
            -- "Skippable": the input is attempted once per instance; when it cannot be
            -- delivered it is skipped instead of holding the batch up.
            skip = el.skip == true,
        }
    elseif kind == "placeholder" and allowPlaceholder then
        return {
            kind = kind,
            name = el.name or "",
            item = el.item or "",
        }
    elseif kind == "waitSignal" or kind == "emitSignal" or kind == "emitPulse" then
        return {
            kind = kind,
            machineSignalIndex = Util.int(el.machineSignalIndex, 1),
            sides = normalizeSides(el.sides),
            threshold = Util.clamp(Util.num(el.threshold, 0), 0, 15),
            op = migratedOp(self.Assert, el),
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

function Store:normalize(kind, name, obj)
    local Util = self.Util
    if kind == "containers" then
        -- Hand-set slot capacity multipliers: a per-slot override map and an
        -- optional container-wide default. Both are optional; absent means "no user
        -- override" (the container then falls back to the mod whitelist scan or the
        -- 1x default). Keys are slot numbers stored as strings (JSON object).
        local multipliers = nil
        if type(obj.slotMultipliers) == "table" then
            multipliers = {}
            for key, value in pairs(obj.slotMultipliers) do
                local slot = tonumber(key)
                local amount = tonumber(value)
                if slot and slot >= 1 and amount and amount > 0 then
                    multipliers[tostring(math.floor(slot))] = amount
                end
            end
            if next(multipliers) == nil then
                multipliers = nil
            end
        end
        local defaultMultiplier = tonumber(obj.slotMultiplierDefault)
        if not defaultMultiplier or defaultMultiplier <= 0 then
            defaultMultiplier = nil
        end
        return {
            name = name,
            peripheral = obj.peripheral or "",
            kind = migratedKind(self.Assert, obj, name),
            role = migratedRole(self.Assert, obj, name),
            priority = Util.int(obj.priority, 0),
            slotMultiplierDefault = defaultMultiplier,
            slotMultipliers = multipliers,
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
        -- An optional item registry name ("minecraft:furnace") used as the icon
        -- of this machine type in the web UI (the machine type card and the
        -- process nodes of the flow graph). Empty means "no icon".
        local icon = Util.trim(obj.icon or "")
        return {
            name = name,
            icon = icon ~= "" and icon or nil,
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
        local machineType = obj.machineType or ""
        local maxMultiplier = math.max(1, Util.int(obj.maxMultiplier, 1))
        if Store.isTypeConversion(machineType) then
            maxMultiplier = Store.TYPE_CONVERSION_MAX_MULTIPLIER
        end
        -- IO mode enum. Old definitions carry only the boolean `unorderedIo`:
        -- false -> sequential (strict order), true -> two_phase (the old "unordered
        -- IO": parallel inside a block, all inputs then all outputs).
        local ioMode = obj.ioMode
        if not Store.IO_MODES[ioMode] then
            ioMode = obj.unorderedIo == true and "two_phase" or "sequential"
        end
        return {
            name = name,
            machineType = machineType,
            inputs = inputs,
            outputs = outputs,
            maxMultiplier = maxMultiplier,
            ioMode = ioMode,
        }
    end
    return Util.deepcopy(obj)
end

local function validateFilterRules(store, filterName, rules)
    rules = rules or {}
    for i, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_RULE_NOT_TABLE, { index = i })
        end
        if not KNOWN_RULE_TYPES[rule.type] then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_RULE_KIND_UNKNOWN,
                { index = i, kind = tostring(rule.type) })
        end
        if not isName(rule.id) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_RULE_NO_TARGET, { index = i })
        end
        if rule.type == "filter_include" or rule.type == "filter_exclude" then
            if rule.id == filterName then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_FILTER_SELF_REF)
            end
            if not store:get("filters", rule.id) then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_FILTER_MISSING, { name = tostring(rule.id) })
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
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_FILTER_CYCLE)
    end
    return true
end

function Store:validateElement(el, allowPlaceholder, index, label)
    if type(el) ~= "table" then
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_NOT_TABLE, { label = label, index = index })
    end
    local Util = self.Util
    local kind = el.kind
    if kind == "item" or kind == "fluid" or kind == "filter" then
        if not isName(el.id) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_NO_RESOURCE, { label = label, index = index })
        end
        if kind == "filter" and not self:get("filters", el.id) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_FILTER_MISSING, { label = label, index = index, filter = el.id })
        end
        if allowPlaceholder then
            local minAmount = Util.num(el.min, 0)
            local maxAmount = Util.num(el.max, 0)
            if maxAmount <= 0 then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_MAX_AMOUNT, { label = label, index = index })
            end
            if minAmount > maxAmount then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_MIN_OVER_MAX, { label = label, index = index })
            end
            local expectAmount = Util.num(el.expect, maxAmount)
            if expectAmount <= 0 or expectAmount > maxAmount then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_EXPECT, { label = label, index = index })
            end
        else
            if Util.num(el.count, 0) <= 0 then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_COUNT, { label = label, index = index })
            end
            if Util.int(el.containerIndex, -1) < -1 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_CONTAINER_INDEX, { label = label, index = index })
            end
            if Util.int(el.slot, -1) < -1 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_SLOT, { label = label, index = index })
            end
        end
        return true
    elseif kind == "placeholder" then
        if not allowPlaceholder then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_PLACEHOLDER, { label = label, index = index })
        end
        if not isName(el.name) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_PLACEHOLDER_NAME, { label = label, index = index })
        end
        if not isName(el.item) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_PLACEHOLDER_ITEM, { label = label, index = index })
        end
        return true
    elseif kind == "waitSignal" or kind == "emitSignal" or kind == "emitPulse" then
        local machineSignalIndex = Util.int(el.machineSignalIndex, 1)
        if machineSignalIndex < 1 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_SIGNAL_INDEX, { label = label, index = index })
        end
        for _, side in ipairs(el.sides or {}) do
            if not VALID_SIDES[side] then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_SIDE, { label = label, index = index, side = tostring(side) })
            end
        end
        if el.op ~= nil and not VALID_OPS[el.op] then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_OP, { label = label, index = index })
        end
        return true
    elseif kind == "waitTime" then
        if Util.num(el.seconds, -1) < 0 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_SECONDS, { label = label, index = index })
        end
        return true
    end
    return false, self.Message.msg(self.Message.KEYS.STORE_ERR_ELEMENT_KIND,
        { label = label, index = index, kind = tostring(kind) })
end

Store.ABSTRACT_ID = "abstract"

function Store.elementIsAbstract(element)
    if type(element) ~= "table" then
        return false
    end
    if element.kind ~= "item" and element.kind ~= "fluid" then
        return false
    end
    return element.id == Store.ABSTRACT_ID
end

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

function Store:validate(kind, name, obj)
    local Util = self.Util
    if not isName(name) then
        return false, self.Message.msg(self.Message.KEYS.STORE_ERR_NAME_EMPTY)
    end
    obj = obj or {}
    if kind == "containers" then
        if not isName(obj.peripheral) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_PERIPHERAL_NAME_EMPTY)
        end
        if not VALID_ROLES[obj.role] then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_CONTAINER_ROLE)
        end
        if obj.kind ~= nil and not VALID_CONTAINER_KINDS[obj.kind] then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_CONTAINER_KIND)
        end
        if obj.priority ~= nil and tonumber(obj.priority) == nil then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_CONTAINER_PRIORITY)
        end
        local containerKind = Util.kindOfDef(obj)
        for _, def in ipairs(self:list("containers")) do
            local defKind = Util.kindOfDef(def)
            if def.peripheral == obj.peripheral and defKind == containerKind and def.name ~= name then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_PERIPHERAL_ASSIGNED,
                { peripheral = tostring(obj.peripheral), name = def.name })
            end
        end
        if obj.slotMultiplierDefault ~= nil then
            local value = tonumber(obj.slotMultiplierDefault)
            if not value or value <= 0 or value > 4096 then
                return false, "slotMultiplierDefault must be a number in (0, 4096]"
            end
        end
        if obj.slotMultipliers ~= nil then
            if type(obj.slotMultipliers) ~= "table" then
                return false, "slotMultipliers must be a table of { slot = multiplier }"
            end
            for key, value in pairs(obj.slotMultipliers) do
                local slot = tonumber(key)
                local amount = tonumber(value)
                if not slot or slot < 1 or slot ~= math.floor(slot) then
                    return false, "slotMultipliers has an invalid slot key: " .. tostring(key)
                end
                if not amount or amount <= 0 or amount > 4096 then
                    return false, "slotMultipliers[" .. tostring(key) .. "] must be a number in (0, 4096]"
                end
            end
        end
        return true
    elseif kind == "signals" then
        if not isName(obj.peripheral) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_PERIPHERAL_NAME_EMPTY)
        end
        return true
    elseif kind == "filters" then
        return validateFilterRules(self, name, obj.rules)
    elseif kind == "machineTypes" then
        if obj.icon ~= nil and type(obj.icon) ~= "string" then
            return false, "machine type icon must be an item registry name (a string)"
        end
        return true
    elseif kind == "machines" then
        if not isName(obj.type) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_MACHINE_TYPE_REQUIRED)
        end
        if not self:get("machineTypes", obj.type) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_MACHINE_TYPE_MISSING, { type = tostring(obj.type) })
        end
        local groups = {
            { obj.itemInputs, self.Message.msg(self.Message.KEYS.STORE_LABEL_ITEM_INPUTS), "item" },
            { obj.fluidInputs, self.Message.msg(self.Message.KEYS.STORE_LABEL_FLUID_INPUTS), "fluid" },
            { obj.itemOutputs, self.Message.msg(self.Message.KEYS.STORE_LABEL_ITEM_OUTPUTS), "item" },
            { obj.fluidOutputs, self.Message.msg(self.Message.KEYS.STORE_LABEL_FLUID_OUTPUTS), "fluid" },
        }
        for _, group in ipairs(groups) do
            local wantedKind = group[3]
            for _, containerName in ipairs(group[1] or {}) do
                local container = self:findContainer(containerName, wantedKind)
                if not container then
                    return false, self.Message.msg(self.Message.KEYS.STORE_ERR_CONTAINER_MISSING, {
                        label = group[2],
                        name = tostring(containerName),
                        kind = self.Message.msg(wantedKind == "fluid"
                            and self.Message.KEYS.STORE_LABEL_FLUID_CONTAINER
                            or self.Message.KEYS.STORE_LABEL_ITEM_CONTAINER),
                    })
                end
                if container.role ~= "interaction" then
                    return false, self.Message.msg(self.Message.KEYS.STORE_ERR_CONTAINER_ROLE_INTERACTION,
                        { label = group[2], name = tostring(containerName) })
                end
            end
        end
        for _, signalEntry in ipairs(obj.signals or {}) do
            if not isName(signalEntry) then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_SIGNAL_NAME_EMPTY)
            end
        end
        if Util.int(obj.parallel, 1) < 1 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_PARALLEL_MIN)
        end
        return true
    elseif kind == "processes" then
        if not isName(obj.machineType) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_MACHINE_TYPE_REQUIRED)
        end
        if not self:get("machineTypes", obj.machineType) then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_MACHINE_TYPE_MISSING, { type = tostring(obj.machineType) })
        end
        if Util.int(obj.maxMultiplier, 1) < 1 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_MAX_MULTIPLIER)
        end
        local inputs = obj.inputs or {}
        local outputs = obj.outputs or {}
        if #inputs == 0 and #outputs == 0 then
            return false, self.Message.msg(self.Message.KEYS.STORE_ERR_PROCESS_EMPTY)
        end
        for i, el in ipairs(inputs) do
            local ok, err = self:validateElement(el, false, i, self.Message.msg(self.Message.KEYS.STORE_LABEL_INPUT))
            if not ok then
                return false, err
            end
        end
        for i, el in ipairs(outputs) do
            local ok, err = self:validateElement(el, true, i, self.Message.msg(self.Message.KEYS.STORE_LABEL_OUTPUT))
            if not ok then
                return false, err
            end
        end
        if Store.isTypeConversion(obj.machineType) then
            -- A type conversion process is a bridge: exactly one material input
            -- (item / fluid / filter) and exactly one filter output.
            if #inputs ~= 1 or #outputs ~= 1 then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_TYPE_CONVERSION_INPUT)
            end
            local input = inputs[1]
            if input.kind ~= "item" and input.kind ~= "fluid" and input.kind ~= "filter" then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_TYPE_CONVERSION_OPS)
            end
            if outputs[1].kind ~= "filter" then
                return false, self.Message.msg(self.Message.KEYS.STORE_ERR_TYPE_CONVERSION_OUTPUT)
            end
        end
        return true
    elseif kind == "settings" then
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
    return false, self.Message.msg(self.Message.KEYS.STORE_ERR_UNKNOWN_KIND, { kind = tostring(kind) })
end

return Store
