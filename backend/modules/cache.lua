local Cache = {}
Cache.__index = Cache

Cache.DATA_VERSION = 3

-- cache.json keeps the run state that cannot be rebuilt - the instances of the batches
-- that are still running, the pending deliveries, the signal outputs that were already
-- emitted and the user's own requests - and nothing else. What can be re-derived (the
-- demand counters of a material), recomputed every tick (the process state, the active
-- processes, the machine counters, the round-robin cursors) or re-scanned from the world
-- (the tag index) is deliberately left out: it only made the file bigger, and on a small
-- computer that was enough to fill the disk.
function Cache.emptyData()
    return {
        -- The demand ledger of the run: one entry per active material (something
        -- the factory is asked to make, or that a process is short of) and one per
        -- active process (how many rounds it owes / is working on).
        processes = {},
        activeMaterials = {},
        activeProcesses = {},
        instances = {},
        machines = {},
        machineTypes = {},
        deliveries = {},
        signals = {},
        tags = {},
        deliverySeq = 0,
        instanceSeq = 0,
    }
end

-- Only the *run state* of a process lives here. The demand counters that used to
-- sit next to it (userCount / downstreamCount / countDirty / craftingCount) moved
-- to Cache.data.activeMaterials: demand belongs to the material, not to the
-- process that happens to make it.
function Cache.defaultProc()
    return {
        state = "idle",
        wait = nil,
        lastError = nil,
        checkedAt = 0,
        lastFinishedAt = 0,
        pulse = nil,
    }
end

-- One row of the material ledger. `key` is `kind .. ":" .. id`
-- (item / fluid / filter / placeholder).
function Cache.defaultMaterial(key, kind, id)
    return {
        key = key,
        kind = kind,
        id = id,
        queryCount = 0,     -- user asked for this many
        automateCount = 0,  -- processes need this much and the stock does not cover it
        craftingCount = 0,  -- how much is being crafted right now (output side)
        updatedAt = 0,
    }
end

function Cache.defaultActiveProcess(name)
    return {
        name = name,
        needCount = 0,      -- rounds still owed this tick
        activeCount = 0,    -- rounds a live instance is working on
    }
end

function Cache.defaultInstance()
    return {
        id = 0,
        owner = "",
        machineType = "",
        machine = "",
        multiplier = 1,
        phase = "input",
        index = 1,
        progress = {},
        outProgress = {},
        inflight = {},
        -- Input element index (as a string) -> true once a "skippable" input got its
        -- one attempt and was skipped for this instance.
        skipDone = {},
        claims = {},
        -- What this instance booked into the material ledger when it was created
        -- (key -> amount): the craftingCount of each of its outputs. Kept on the
        -- instance so finish/kill can give back exactly what was taken, even if the
        -- process definition changes while the batch runs.
        craftCredit = {},
        wait = nil,
        baseline = {},
        target = {},
        state = "running",
        startedAt = 0,
        lastError = nil,
    }
end

-- (The old loader needed PROCESS_FIELDS / MATERIAL_FIELDS / ACTIVE_PROCESS_FIELDS to
-- merge whole sections back. The loader below only reads the sections that are still
-- written and rebuilds the counters from them, so those lists are gone.)


function Cache.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Cache)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("cache.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.log = opts.log or function() end
    self.Message = opts.Message
        or error("cache.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    local JsonFile = opts.JsonFile
    if not JsonFile then
        error("cache.lua needs the jsonfile module: pass opts.JsonFile (loadModule(\"jsonfile\"))", 0)
    end
    self.file = JsonFile.new({
        path = opts.path or "/data/cache.json",
        log = opts.log,
        Message = self.Message,
    })
    -- Asked for every restored instance: one whose process was deleted in the meantime
    -- must not come back to life and keep occupying a machine.
    self.processExists = opts.processExists
    self.data = Cache.emptyData()
    return self
end

-- One instance as it goes to disk: everything the step pipeline reads while the batch
-- runs. Two fields are deliberately left out - `baseline` (a copy of the whole storage
-- per instance, read by the diagnose probe only) and `inflight` (the input bookings of
-- moves that did not survive the restart: nothing is in flight after a boot, and a
-- restored booking would wait for a settlement that never comes).
function Cache.exportInstance(inst)
    local copy = {}
    for field, value in pairs(inst) do
        copy[field] = value
    end
    copy.baseline = nil
    copy.inflight = nil
    return copy
end

-- One identity per distinct process definition. The file stores every definition once
-- (see Cache:exportData) instead of a deep copy inside every instance; the memo maps the
-- serialized definition to its key, so a batch started from an unchanged definition
-- reuses the definition that is already written.
function Cache:noteDef(def)
    if type(def) ~= "table" then
        return nil
    end
    self.defKeys = self.defKeys or {}
    -- allow_repetitions: a frozen definition may hold the same sub-table twice, which
    -- the default serializer refuses; the option only makes it permissive.
    local text = textutils.serialize(def, { allow_repetitions = true })
    local key = self.defKeys[text]
    if not key then
        key = "d" .. tostring((self.defSeq or 0) + 1)
        self.defSeq = (self.defSeq or 0) + 1
        self.defKeys[text] = key
    end
    return key
end

-- Everything that is written to cache.json. What the operator asked for is the one
-- thing about a material that cannot be re-derived, so a row is kept for exactly those
-- requests; automateCount is re-derived from the stock every tick and craftingCount is
-- rebuilt from the restored instances by Cache:load.
function Cache:exportData()
    local out = {
        version = Cache.DATA_VERSION,
        savedAt = os.epoch("utc"),
        instanceSeq = self.data.instanceSeq,
        deliverySeq = self.data.deliverySeq,
        instances = {},
        -- Every distinct definition is stored here once: an instance keeps only its
        -- defKey. Writing the deep copied definition inside every instance was the bulk
        -- of the file - and of every serializeJSON() pass on the tick.
        defs = {},
        deliveries = self.data.deliveries,
        signals = self.data.signals,
        activeMaterials = {},
    }
    for key, inst in pairs(self.data.instances) do
        if type(inst) == "table" then
            local copy = Cache.exportInstance(inst)
            local defKey = type(inst.defKey) == "string" and inst.defKey or nil
            if defKey and type(inst.def) == "table" then
                if out.defs[defKey] == nil then
                    out.defs[defKey] = inst.def
                end
                copy.def = nil
            end
            out.instances[tostring(key)] = copy
        end
    end
    for key, material in pairs(self.data.activeMaterials) do
        local query = math.max(0, math.floor(tonumber(material.queryCount) or 0))
        if query > 0 then
            out.activeMaterials[tostring(key)] = {
                key = material.key,
                kind = material.kind,
                id = material.id,
                nbt = material.nbt,
                ignoreNbt = material.ignoreNbt,
                queryCount = query,
            }
        end
    end
    return out
end

-- Restore what cannot be rebuilt. Sections an older build used to write (processes,
-- machines, activeProcesses, machineTypes, tags) are not read at all: the engine
-- re-derives or re-scans every one of them.
function Cache:load()
    local parsed, why = self.file:read("cache.json")
    if not parsed then
        self.data = Cache.emptyData()
        return false, why
    end
    local version = tonumber(parsed.version) or 0
    if version ~= Cache.DATA_VERSION then
        self.Assert.is(false, "cache.json has data version %s, this build writes %d - " ..
            "there is no migration any more: delete data/cache.json and rebuild the definitions",
            tostring(parsed.version), Cache.DATA_VERSION)
    end
    local data = Cache.emptyData()
    -- Definitions are stored once per distinct definition (see Cache:exportData) and an
    -- instance only carries its defKey. A file written before that change keeps the
    -- definition inline on the instance.
    local defs = type(parsed.defs) == "table" and parsed.defs or {}
    local function eachRecord(section)
        local src = parsed[section]
        if src == nil then
            return function() return nil end
        end
        self.Assert.is(type(src) == "table", "cache.json: '%s' must be a table, got %s",
            tostring(section), type(src))
        local list = {}
        for key, value in pairs(src) do
            if type(value) == "table" then
                list[#list + 1] = { key = key, value = value }
            else
                self.log.error("cache.json: %s[%s] is not a table (got %s) - entry skipped",
                    tostring(section), tostring(key), type(value))
            end
        end
        local index = 0
        return function()
            index = index + 1
            local entry = list[index]
            if not entry then
                return nil
            end
            return entry.key, entry.value
        end
    end
    local function numberField(record, name, section, key)
        local value = record[name]
        if value == nil then
            return 0
        end
        self.Assert.is(type(value) == "number", "cache.json: %s[%s].%s must be a number, got %s",
            tostring(section), tostring(key), tostring(name), type(value))
        return value
    end

    local maxInstanceId = 0
    local nextInstance = eachRecord("instances")
    while true do
        local key, record = nextInstance()
        if key == nil then
            break
        end
        local inst = Cache.defaultInstance()
        for field, value in pairs(record) do
            inst[field] = value
        end
        if type(inst.def) ~= "table" and type(inst.defKey) == "string" then
            inst.def = defs[inst.defKey]
        end
        inst.id = math.max(0, math.floor(numberField(record, "id", "instances", key)))
        inst.owner = tostring(inst.owner or "")
        inst.machine = tostring(inst.machine or "")
        inst.machineType = tostring(inst.machineType or "")
        inst.multiplier = math.max(1, math.floor(numberField(record, "multiplier", "instances", key)))
        -- The instance carries the definition it was started with, so whether its
        -- process still exists can only be answered by the definitions (the file no
        -- longer lists the processes).
        local ownerKnown = self.processExists == nil or self.processExists(inst.owner) ~= false
        if type(inst.def) ~= "table" or type(inst.def.inputs) ~= "table" or type(inst.def.outputs) ~= "table" then
            self.log.warn("cache.json: instance %s has no frozen steps (def) - dropped", tostring(key))
        elseif not ownerKnown then
            self.log.warn("cache.json: instance %s belongs to process %s which no longer exists - dropped",
                tostring(key), tostring(inst.owner))
        else
            data.instances[tostring(inst.id)] = inst
            maxInstanceId = math.max(maxInstanceId, inst.id)
        end
    end
    -- `running` means "how many live instances use this machine", so it is rebuilt from
    -- the restored instances alone - that counter is not part of the file any more.
    for _, inst in pairs(data.instances) do
        local name = inst.machine
        if name ~= "" then
            local machine = data.machines[name]
            if not machine then
                machine = { running = 0 }
                data.machines[name] = machine
            end
            machine.running = machine.running + 1
        end
    end
    local seqInst = tonumber(parsed.instanceSeq)
    data.instanceSeq = math.max(0, math.floor(seqInst or maxInstanceId), maxInstanceId)

    local nextMaterial = eachRecord("activeMaterials")
    while true do
        local key, record = nextMaterial()
        if key == nil then
            break
        end
        if type(record.kind) == "string" and type(record.id) == "string" then
            local mat = Cache.defaultMaterial(tostring(key), record.kind, record.id)
            mat.nbt = record.nbt
            mat.ignoreNbt = record.ignoreNbt
            mat.queryCount = math.max(0, math.floor(numberField(record, "queryCount", "activeMaterials", key)))
            data.activeMaterials[mat.key] = mat
        else
            self.log.error("cache.json: activeMaterials[%s] has no kind/id - entry skipped", tostring(key))
        end
    end
    -- craftingCount is a live figure: rebuild it from the restored instances instead of
    -- storing a counter that says the same thing twice.
    for _, inst in pairs(data.instances) do
        for key, amount in pairs(inst.craftCredit or {}) do
            local mat = data.activeMaterials[key]
            if mat then
                mat.craftingCount = mat.craftingCount + math.max(0, math.floor(tonumber(amount) or 0))
            end
        end
    end

    local deliveries = parsed.deliveries
    if deliveries ~= nil then
        self.Assert.is(type(deliveries) == "table", "cache.json: 'deliveries' must be an array, got %s",
            type(deliveries))
        for index, entry in ipairs(deliveries) do
            self.Assert.is(type(entry) == "table", "cache.json: deliveries[%d] must be a table, got %s",
                index, type(entry))
            self.Assert.string(entry.kind, "cache.json: deliveries[" .. tostring(index) .. "].kind")
            self.Assert.is(entry.id ~= nil, "cache.json: deliveries[%d].id is missing", index)
            if entry.remaining == nil then
                entry.remaining = tonumber(entry.count)
            end
            self.Assert.count(entry.remaining,
                "cache.json: deliveries[" .. tostring(index) .. "].remaining")
            if entry.total == nil then
                entry.total = entry.remaining
            end
            self.Assert.count(entry.total, "cache.json: deliveries[" .. tostring(index) .. "].total")
            if entry.stuckCount == nil then
                entry.stuckCount = 0
            end
            self.Assert.count(entry.stuckCount,
                "cache.json: deliveries[" .. tostring(index) .. "].stuckCount")
            data.deliveries[#data.deliveries + 1] = entry
        end
    end
    local nextSignal = eachRecord("signals")
    while true do
        local key, entry = nextSignal()
        if key == nil then
            break
        end
        data.signals[key] = entry
    end
    local seq = tonumber(parsed.deliverySeq)
    if seq == nil then
        seq = 0
        for _, entry in ipairs(data.deliveries) do
            local id = tonumber(entry.id) or 0
            if id > seq then
                seq = id
            end
        end
    end
    data.deliverySeq = math.max(0, seq)
    self.data = data
    return true
end

-- Bumped on every state change: the web push uses it as its revision counter (see
-- the revisionProvider in IFMMaster) and the dispatch tick uses it to decide whether
-- the file has to be written.
function Cache:markDirty()
    self.file:markDirty()
    self.revision = (self.revision or 0) + 1
end

function Cache:tick(now)
    if not self.file:shouldFlush(now) then
        return false
    end
    return self:flush()
end

-- Writes the filtered snapshot: the state that cannot be rebuilt, nothing else.
function Cache:flush()
    return self.file:flush(self:exportData())
end

function Cache:proc(name)
    local record = self.data.processes[name]
    if not record then
        record = Cache.defaultProc()
        self.data.processes[name] = record
        self:markDirty()
    end
    return record
end

function Cache:materials()
    return self.data.activeMaterials
end

function Cache:materialByKey(key)
    return self.data.activeMaterials[key]
end

-- Creates the ledger row on demand, so callers do not have to check first.
function Cache:material(kind, id, key)
    key = key or (tostring(kind) .. ":" .. tostring(id))
    local record = self.data.activeMaterials[key]
    if not record then
        record = Cache.defaultMaterial(key, kind, id)
        self.data.activeMaterials[key] = record
        self:markDirty()
    end
    return record
end

function Cache:activeProcesses()
    return self.data.activeProcesses
end

function Cache:activeProcess(name)
    local record = self.data.activeProcesses[name]
    if not record then
        record = Cache.defaultActiveProcess(name)
        self.data.activeProcesses[name] = record
        self:markDirty()
    end
    return record
end

-- Forget everything the ledger remembers about one process definition (it was
-- deleted, or the definition no longer has a usable machine type).
function Cache:dropActiveProcess(name)
    if self.data.activeProcesses[name] == nil then
        return false
    end
    self.data.activeProcesses[name] = nil
    self:markDirty()
    return true
end

function Cache:instances()
    return self.data.instances
end

function Cache:instance(id)
    return self.data.instances[tostring(id)]
end

function Cache:addInstance(inst)
    self.data.instanceSeq = (self.data.instanceSeq or 0) + 1
    inst.id = self.data.instanceSeq
    self.data.instances[tostring(inst.id)] = inst
    self:markDirty()
    return inst.id
end

function Cache:removeInstance(id)
    local key = tostring(id)
    if self.data.instances[key] == nil then
        return false
    end
    self.data.instances[key] = nil
    self:markDirty()
    return true
end

function Cache:instanceCount()
    local n = 0
    for _ in pairs(self.data.instances) do
        n = n + 1
    end
    return n
end

function Cache:machine(name)
    local record = self.data.machines[name]
    if not record then
        record = { running = 0 }
        self.data.machines[name] = record
        self:markDirty()
    end
    return record
end

function Cache:machineType(typeName)
    local record = self.data.machineTypes[typeName]
    if not record then
        record = { rrIndex = 0 }
        self.data.machineTypes[typeName] = record
        self:markDirty()
    end
    return record
end

function Cache:addDelivery(entry)
    self.data.deliverySeq = (self.data.deliverySeq or 0) + 1
    entry.id = self.data.deliverySeq
    self.data.deliveries[#self.data.deliveries + 1] = entry
    self:markDirty()
    return entry
end

function Cache:removeDelivery(id)
    for i, entry in ipairs(self.data.deliveries) do
        if entry.id == id then
            table.remove(self.data.deliveries, i)
            self:markDirty()
            return true
        end
    end
    return false
end

function Cache:deliveries()
    return self.data.deliveries
end

function Cache:setSignalOutput(key, entry)
    self.data.signals[key] = entry
    self:markDirty()
end

function Cache:clearSignalOutput(key)
    if self.data.signals[key] ~= nil then
        self.data.signals[key] = nil
        self:markDirty()
    end
end

function Cache:signalOutputs()
    return self.data.signals
end

function Cache:tags()
    return self.data.tags
end

function Cache:tagsOf(name)
    return self.data.tags[name]
end

function Cache:hasTags(name)
    return self.data.tags[name] ~= nil
end

function Cache:setTags(name, tags)
    self.data.tags[name] = tags or {}
    self.tagRevision = (self.tagRevision or 0) + 1
    self:markDirty()
end

function Cache:pruneTags(present)
    local removed = 0
    for name in pairs(self.data.tags) do
        if not (present and present[name]) then
            self.data.tags[name] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        self.tagRevision = (self.tagRevision or 0) + 1
        self:markDirty()
    end
    return removed
end

function Cache:clearTags()
    self.data.tags = {}
    self.tagRevision = (self.tagRevision or 0) + 1
    self:markDirty()
end

return Cache
