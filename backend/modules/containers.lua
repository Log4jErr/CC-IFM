local Containers = {}
Containers.__index = Containers
local Assert = nil
local RefCount = nil

local function samePeripheralReason(Message, fromContainer, toContainer, peripheralName)
    return Message.msg(Message.KEYS.CONT_ERR_SAME_PERIPHERAL, {
        from = tostring(fromContainer),
        to = tostring(toContainer),
        peripheral = tostring(peripheralName),
    })
end

function Containers:defRole(containerName, kind)
    local def = self.Store and self.Store:findContainer(containerName, kind)
    return (def and def.role) or "storage"
end

-- Scan policy (2.0): a container is scanned only while somebody needs its
-- snapshot.
--   storage / input : always (inventory accounting, compact plan, resource list).
--   interaction     : only while an active process instance references the
--                     container's machine (opts.interaction), or while the web
--                     manual container tool keeps it open (opts.watched), or
--                     while unsettled dirty marks still need reconciling
--                     (opts.reconcile).
--   output          : only while a move is being sent (opts.sendActive, i.e.
--                     the inventoryOut queue is not empty), plus watch /
--                     reconcile as above.
function Containers:scanQueueTargets(opts)
    opts = opts or {}
    local interaction = opts.interaction or {}
    local watched = opts.watched or {}
    local viewed = opts.viewed or {}
    local reconcile = opts.reconcile or {}
    local sendActive = opts.sendActive == true
    local sending = opts.sending or {}
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
    -- `viewed` is the container tool looking at this container right now. A container
    -- that nobody uses yet (a freshly added barrel, say) has no snapshot and no slot
    -- count, so the tool's own view has to count as a demand for its scan.
    local function wanted(role, peripheralName)
        if role == "interaction" then
            return interaction[peripheralName] == true or watched[peripheralName] == true
                or viewed[peripheralName] == true or reconcile[peripheralName] == true
        end
        if role == "output" then
            return sendActive or sending[peripheralName] == true
                or watched[peripheralName] == true or viewed[peripheralName] == true
                or reconcile[peripheralName] == true
        end
        return true
    end
    for _, def in ipairs(self.Store:list("containers")) do
        local peripheralName = def.peripheral
        if type(peripheralName) == "string" and peripheralName ~= "" and def.virtual ~= true then

            if self.Peripherals:exists(peripheralName) then
                local role = def.role or "storage"
                local kind = (self.Util and self.Util.kindOfDef and self.Util.kindOfDef(def)) or def.kind or "item"
                local scannable
                if kind == "fluid" then
                    scannable = self.Peripherals.isFluid and self.Peripherals:isFluid(peripheralName)
                else
                    scannable = self.Peripherals.isInventory and self.Peripherals:isInventory(peripheralName)
                end
                if scannable and wanted(role, peripheralName) then
                    -- Keyed by kind: one peripheral can be both an inventory and a fluid
                    -- storage, and then it needs BOTH scans (item list + size, and tanks).
                    out[bucketOf(role)][kind .. ":" .. peripheralName] =
                        { name = peripheralName, kind = kind }
                end
            end
        end
    end
    return out
end

-- Slot capacity model.
--
-- A slot holds a number of *stacks*; that multiplier is what every capacity figure
-- is derived from. It comes from the peripheral's own slot limit:
--
--   empty slot    : getItemLimit(slot) / 64
--                   (the peripheral reports an empty slot as a 64-stack slot)
--   occupied slot : getItemLimit(slot) / maxCount(item actually in that slot)
--                   (it reports an occupied slot in units of that item)
--
-- Both spellings describe the same slot property. How many items with stack size Y
-- fit into a slot with multiplier X is X * Y.
--
-- The multiplier is computed exactly ONCE per slot - from the limit and the stack size
-- of the item that is in the slot at that moment - and then cached on the slot's limit
-- entry (see slotStacksOf). It is a property of the physical slot, so it never changes
-- when the slot's content changes later. While it is still unknown the slot takes part
-- in no item I/O at all (see slotMultiplierReady), so its content cannot move underneath
-- the computation.
Containers.STACK_UNIT = 64

local MAX_CONTAINER_SLOTS = 4096

-- A turtle has a fixed geometry: 16 slots, each worth exactly one stack (1x). Its slot
-- count and its slot multiplier are constants, so it never takes part in the
-- slot-capacity scan - it can never hold storage compaction back.
local TURTLE_SLOTS = 16
local TURTLE_SLOT_MULTIPLIER = 1

local SLOT_COUNT_TTL = 60000

-- getItemLimit() is one peripheral call per slot and a call can cost a game tick on a
-- wired network, so a single scan only warms up this many *new* slot limits; the rest
-- are read on later scans (or reused from the previous scan when nothing changed).
local SLOT_LIMIT_WARMUP = 8

-- Stable merge sort (table.sort is *not* stable): equal elements keep their original
-- order, which is what the compact plan relies on. Returns a new list, `list` itself
-- is left untouched. `less(a, b) == true` means "a comes before b".
local function mergeSort(list, less)
    local n = #list
    local src = {}
    for index = 1, n do
        src[index] = list[index]
    end
    local dst = {}
    local width = 1
    while width < n do
        local start = 1
        while start <= n do
            local mid = math.min(start + width - 1, n)
            local finish = math.min(start + 2 * width - 1, n)
            local left, right, out = start, mid + 1, start
            while left <= mid and right <= finish do
                -- Only a strictly smaller element is taken from the right half, so
                -- equal elements stay in their original (left) order.
                if less(src[right], src[left]) then
                    dst[out] = src[right]
                    right = right + 1
                else
                    dst[out] = src[left]
                    left = left + 1
                end
                out = out + 1
            end
            while left <= mid do
                dst[out] = src[left]
                left = left + 1
                out = out + 1
            end
            while right <= finish do
                dst[out] = src[right]
                right = right + 1
                out = out + 1
            end
            start = start + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    local result = {}
    for index = 1, n do
        result[index] = src[index]
    end
    return result
end

-- Rule 1: the slot's stack multiplier.
function Containers.slotStackMultiplier(slotLimit, itemMaxCount)
    local limit = tonumber(slotLimit)
    local stack = tonumber(itemMaxCount)
    if not stack or stack <= 0 then
        stack = Containers.STACK_UNIT
    end
    if not limit or limit <= 0 then
        limit = Containers.STACK_UNIT
    end
    return limit / stack
end

-- Rule 2: multiplier * item stack size = how many of that item fit in the slot.
function Containers.stacksToItems(stacks, itemMaxCount)
    local stack = tonumber(itemMaxCount)
    if not stack or stack <= 0 then
        stack = Containers.STACK_UNIT
    end
    return math.floor((tonumber(stacks) or 0) * stack)
end

-- Rules 1+2 composed: capacity of a slot (limit) for an item with stack size Y.
function Containers.slotItemCapacity(slotLimit, itemMaxCount)
    return Containers.stacksToItems(Containers.slotStackMultiplier(slotLimit, itemMaxCount), itemMaxCount)
end


local function levelLogger(fn)
    if type(fn) == "table" and fn.warn ~= nil and fn.error ~= nil then
        return fn
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
    self.Assert = opts.Assert
    or error("containers.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    Assert = self.Assert
    self.RefCount = opts.RefCount
    or error("containers.lua needs the refcount module: pass opts.RefCount (loadModule(\"refcount\"))", 0)
    RefCount = self.RefCount
    self.Message = opts.Message
    or error("containers.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    self.Peripherals = opts.Peripherals
    self.Store = opts.Store
    self.Filter = opts.Filter
    self.log = levelLogger(opts.log)
    self.cacheTtl = opts.cacheTtl or 600

    self.snapshots = {}
    self.readCostMs = 0
    self.listPassMs = 0
    self.readCount = 0
    self.readMsTotal = 0
    self.tickCount = 0
    self.moveSettleCount = 0
    self.moveResultCount = 0
    self.moveReleased = 0
    self.moveEnqueued = 0
    self.moveEnqueueRejected = 0
    self.moveEnqueueLocal = 0
    self.scanRequested = 0
    self.scanDeferred = 0
    self.scanLocal = 0
    self.scanUnknown = 0
    self.scanStale = 0
    self.scanProtocolMismatch = 0
    self.scanProtocolMismatchLogged = 0
    self.stackLimitKnown = 0
    self.stackLimitUnknown = 0
    self.detailDeferred = 0
    self.forgotten = 0

    self.detailCache = {}

    self.detailTtl = opts.detailTtl or 300000

    self.detailProvider = nil
    self.localDetailCalls = 0
    self.model = {}
    self.moveRequests = {}
    self.moveInflight = {}
    self.moveResults = {}
    self.scanSeen = {}
    self.tickCount = 0

    -- Snapshot ledgers (all private to this module; callers only use the methods
    -- below):
    --   model        : peripheral -> { slots = {[slot]={name,nbt,count}},
    --                                  tanks = {[tank]={name,amount}}, ... }  (raw scan)
    --   inUse        : peripheral -> { slots = {[slot]={name,nbt,sources,total}},
    --                                  fluids = {[name]={sources,total}} }     (reserved)
    --   index        : resource -> locations (reverse lookup for a free slot)
    --   sourceIndex  : source id -> { [locKey] = location } (fast release of a source)
    --   claimResidual: resource -> { sources = {[owner]=amount}, total }
    --                  (the part of a process claim that could not be pinned to a
    --                   concrete slot, e.g. right after a restart before the first scan)
    self.inUse = {}
    self.index = { items = {}, fluids = {} }
    self.sourceIndex = {}
    self.claimResidual = {}

    self.dirty = {}

    self.scanStats = {}

    self.capacityTtl = opts.capacityTtl or 15000
    self.capacityCache = nil

    -- Containers whose slot capacities are not fully known yet (see
    -- markCapacityPending). O(1) to query, never a full slot walk.
    self.capacityPending = {}

    self.itemMaxCountCache = {}
    return self
end

-- The raw getItemLimit(slot) reported by the *limit* instruction for that slot (nil
-- while it has not been read yet). It is stored per slot together with the item it was
-- read for and, once computable, the slot's stack multiplier (`stacks`, see the slot
-- capacity model at the top and slotStacksOf). The multiplier is a property of the
-- physical slot: it is computed once and then read from here, independent of whatever
-- the slot holds later (the recorded item is kept for diagnostics only).
function Containers:slotLimitEntry(peripheralName, slot)
    local model = self.model[peripheralName]
    local entry = model and model.slotLimits and model.slotLimits[slot]
    if type(entry) == "table" then
        return entry
    end
    return nil
end

function Containers:slotLimitOf(peripheralName, slot)
    local entry = self:slotLimitEntry(peripheralName, slot)
    return entry and tonumber(entry.limit) or nil
end

-- A slot whose limit has not been read yet is *unknown*, not "one stack": the master
-- asks for the limit (one dedicated instruction) and refuses to size the slot until the
-- answer is in. Guessing 64 would silently overflow drawers.
function Containers:requestSlotLimit(peripheralName, slot)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return
    end
    slot = tonumber(slot)
    if not slot or slot < 1 then
        return
    end
    if self:isFixedSlotCapacity(peripheralName) then
        -- A turtle's slots are a constant (1x): there is nothing to ask for.
        return
    end
    if self:slotLimitOf(peripheralName, slot) then
        return
    end
    local model = self.model[peripheralName]
    if model and model.limitFailed and model.limitFailed[slot] then
        -- The peripheral already answered that it cannot report this slot's limit:
        -- asking again every tick would only spam the log.
        return
    end
    self.slotLimitPending = self.slotLimitPending or {}
    self.slotLimitPending[peripheralName] = self.slotLimitPending[peripheralName] or {}
    self.slotLimitPending[peripheralName][slot] = true
end

-- The peripheral (or the worker) reported that this slot has no readable limit: stop
-- asking for it. Slots stay unsized, so nothing is moved into them.
function Containers:markLimitUnavailable(peripheralName, slot, reason)
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    if self:isFixedSlotCapacity(peripheralName) then
        -- A turtle's slot capacity is known without asking: a "cannot report" answer can
        -- only be a stale reply from before the fix, so it is ignored.
        return false
    end
    slot = tonumber(slot)
    local wasFailed = model.limitFailed ~= nil and model.limitFailed[slot] == true
    model.limitFailed = model.limitFailed or {}
    model.limitFailed[slot] = true
    self:clearPendingLimit(peripheralName, slot)
    -- The peripheral answered that it cannot report this slot: the capacity stays
    -- unknown, so the container must not leave the pending list.
    self:markCapacityPending(peripheralName)
    -- Report it once per slot: this is the one failure that keeps the whole storage
    -- compaction waiting, so it must be visible in the log.
    if not wasFailed then
        self.log.error("%s slot %s: the peripheral cannot report its slot capacity (%s) -" ..
            " this keeps the container unsized and storage compaction waiting for it",
            tostring(peripheralName), tostring(slot), tostring(reason or "no reason given"))
    end
    return true
end

-- The (peripheral, slot) pairs the master still has to read, oldest request first.
function Containers:takePendingLimits(limit)
    local out = {}
    local pending = self.slotLimitPending or {}
    limit = tonumber(limit) or 0
    for peripheralName, slots in pairs(pending) do
        for slot in pairs(slots) do
            if limit > 0 and #out >= limit then
                return out
            end
            out[#out + 1] = { peripheral = peripheralName, slot = slot,
                container = peripheralName }
        end
    end
    return out
end

function Containers:clearPendingLimit(peripheralName, slot)
    local pending = self.slotLimitPending
    local slots = pending and pending[peripheralName]
    if not slots then
        return
    end
    slots[tonumber(slot)] = nil
end

-- Rule 1 for one slot: the slot's stack multiplier. It is a property of the physical
-- slot, not of what is stored in it: it is computed exactly once - from the slot's limit
-- and the stack size of the item that is in the slot at that moment (an empty slot is a
-- 64-stack slot) - and then cached on the limit entry. Every later read returns that
-- cached value, no matter what the slot holds by then, so a slot that changed content
-- keeps its multiplier. nil while the limit, or that item's stack size, is still unknown.
-- The stack size comes from the item detail cache whenever it is already known (list()
-- reported the name+nbt and an earlier getItemDetail covered it) - it is never re-read
-- here; a missing detail is only *requested* (one queued instruction).
local function slotStacksOf(self, peripheralName, slot, entry)
    -- A user-set multiplier is authoritative and independent of what the slot holds.
    local override = self:slotOverrideOf(peripheralName, slot)
    if override then
        entry.stacks = override
        return override
    end
    -- A container that is not slot-capacity scanned is one stack per slot.
    if not self:needsSlotScan(peripheralName) then
        entry.stacks = 1
        return 1
    end
    if entry.stacks then
        -- Already computed (or a fixed geometry, e.g. a turtle: 1x).
        return entry.stacks
    end
    local model = self.model[peripheralName]
    if not (model and model.info and model.info.items) then
        -- The slot's content has not been scanned yet: an empty-looking slot cannot be
        -- told apart from a not-yet-read one, so the multiplier stays undecided (and
        -- uncached) until the item list is in.
        return nil
    end
    local inSlot = model.slots and model.slots[slot]
    local inMax = nil
    if type(inSlot) == "table" and type(inSlot.name) == "string" then
        inMax = self:itemMaxCount(inSlot.name, inSlot.nbt)
        if not inMax then
            -- The stack size of the item in the slot is not known yet: the multiplier
            -- cannot be computed. Ask for its detail and stay undecided until it is in.
            self:requestItemDetails({ { container = peripheralName, slot = slot,
                name = inSlot.name, nbt = inSlot.nbt } })
            return nil
        end
    end
    entry.stacks = Containers.slotStackMultiplier(entry.limit, inMax)
    return entry.stacks
end

-- Whether this slot's capacity multiplier has already been read and cached. While it is
-- false the slot takes part in NO item I/O: neither as a move source nor as a target.
function Containers:slotMultiplierReady(peripheralName, slot)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    slot = tonumber(slot)
    if not slot or slot < 1 then
        return false
    end
    if self:slotOverrideOf(peripheralName, slot) then
        return true
    end
    if not self:needsSlotScan(peripheralName) then
        return true
    end
    local entry = self:slotLimitEntry(peripheralName, slot)
    if not entry then
        return false
    end
    return slotStacksOf(self, peripheralName, slot, entry) ~= nil
end

-- Rule 1 applied to one slot of a container: the slot's stack multiplier. A user-set
-- multiplier (or the 1x default of an unscanned container) answers without a scan.
function Containers:slotStackCount(peripheralName, slot)
    return self:slotMultiplierOf(peripheralName, slot)
end

-- Rules 1+2 for one slot: how many items with stack size `itemMaxCount` fit in it.
-- `itemMaxCount` nil means "whatever is in the slot now" (an empty slot: 64).
-- nil while the slot's limit (or the item's maxCount) is still unknown.
function Containers:slotCapacityFor(peripheralName, slot, itemName, nbt)
    local targetMax = nil
    if type(itemName) == "string" and itemName ~= "" then
        targetMax = self:itemMaxCount(itemName, nbt)
        if not targetMax then
            -- The item's stack size is unknown, so the slot cannot be sized (X*Y) and
            -- nothing may be moved into it: ask for its detail and stay unusable until
            -- the answer is in.
            self:requestItemDetails({ { container = peripheralName, slot = slot,
                name = itemName, nbt = nbt } })
            return nil
        end
    end
    local stacks = self:slotMultiplierOf(peripheralName, slot)
    if not stacks then
        return nil
    end
    return Containers.stacksToItems(stacks, targetMax)
end

-- The capacity multiplier of one slot: how many stacks it is worth.
--   * a user-set multiplier (per slot or the container default) always wins;
--   * a container that is not slot-capacity scanned is 1x;
--   * otherwise it is read from getItemLimit() (whitelisted mods).
-- nil while a scanned slot's limit - or the stack size of the item in it at read time -
-- is still unknown.
function Containers:slotMultiplierOf(peripheralName, slot)
    local override = self:slotOverrideOf(peripheralName, slot)
    if override then
        return override
    end
    if not self:needsSlotScan(peripheralName) then
        return 1
    end
    local entry = self:slotLimitEntry(peripheralName, slot)
    if not entry then
        self:requestSlotLimit(peripheralName, slot)
        return nil
    end
    return slotStacksOf(self, peripheralName, slot, entry)
end

-- Read-only snapshot of one slot's capacity bookkeeping, for the container tool: the
-- effective multiplier, the raw getItemLimit value, the item key the limit was read for
-- and the user override (if any). Never computes the multiplier and never queues a
-- request - the tool shows exactly what the master currently believes.
function Containers:slotCapacityInfo(peripheralName, slot)
    local entry = self:slotLimitEntry(peripheralName, slot)
    local limit = entry and tonumber(entry.limit) or nil
    local item = entry and entry.item or nil
    local override = self:slotOverrideOf(peripheralName, slot)
    if override then
        return { multiplier = override, limit = limit, item = item, override = override }
    end
    if not self:needsSlotScan(peripheralName) then
        return { multiplier = 1, limit = limit, item = item }
    end
    if not entry then
        return nil
    end
    return { multiplier = tonumber(entry.stacks), limit = limit, item = item }
end

-- The per-peripheral flags both helpers below answer with. They are pure functions of
-- the peripheral name (its type only changes when the peripheral list is rescanned) and
-- they are called for every slot of every capacity walk, so they are remembered per
-- peripheral, keyed by the same scan generation peripheralCount() uses.
function Containers:peripheralFlags(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil
    end
    local scanAt = (self.Peripherals and self.Peripherals.lastScan) or 0
    if self.peripheralFlagGen ~= scanAt then
        self.peripheralFlagGen = scanAt
        self.peripheralFlagCache = {}
    end
    self.peripheralFlagCache = self.peripheralFlagCache or {}
    local flags = self.peripheralFlagCache[peripheralName]
    if flags == nil then
        local mod = peripheralName:match("^([^:]+):")
        flags = {
            -- A turtle has a fixed geometry (16 slots x 1 stack) and never needs a
            -- slot-capacity scan.
            fixed = self.Peripherals ~= nil and self.Peripherals.isTurtle ~= nil
                and self.Peripherals:isTurtle(peripheralName) == true,
            -- Only containers of a whitelisted mod are slot-capacity scanned.
            mod = mod ~= nil and Containers.SCANNED_MODS[mod] == true,
        }
        self.peripheralFlagCache[peripheralName] = flags
    end
    return flags
end

-- A peripheral with a fixed, known geometry (a turtle: 16 slots x 1 stack) never needs a
-- slot-capacity scan. Returns true for those peripherals only.
function Containers:isFixedSlotCapacity(peripheralName)
    local flags = self:peripheralFlags(peripheralName)
    return flags ~= nil and flags.fixed == true
end

-- Only containers of these mods are slot-capacity scanned (their getItemLimit() is a
-- real value). Everything else is assumed to be one stack per slot and is NOT scanned:
-- e.g. a vanilla chest reports a buggy constant 99 on NeoForge, so scanning it would
-- over-estimate every slot. A user-set multiplier always wins over this.
Containers.SCANNED_MODS = {
    sophisticatedstorage = true,
    sophisticatedbackpacks = true,
}

function Containers:isScannedMod(peripheralName)
    local flags = self:peripheralFlags(peripheralName)
    return flags ~= nil and flags.mod == true
end

-- The container definition of one peripheral. The reverse lookup walks every
-- definition and Store:list() copies and sorts them, while the slot accessors call this
-- once per slot - so the whole peripheral -> definition table is built in ONE pass per
-- store revision instead of one walk per lookup (that walk, repeated per slot, burned a
-- whole tick and ended in "Too long without yielding").
function Containers:defOfPeripheral(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" or not self.Store then
        return nil
    end
    local rev = self.Store.revision and self.Store:revision() or 0
    local memo = self.slotDefMemo
    if not memo or memo.rev ~= rev then
        memo = { rev = rev, map = {} }
        -- list() is sorted by definition name, so the first definition of a peripheral
        -- is the same one findContainerByPeripheral() would have picked.
        for _, def in ipairs(self.Store:list("containers")) do
            local peripheral = type(def) == "table" and def.peripheral or nil
            if type(peripheral) == "string" and peripheral ~= "" and memo.map[peripheral] == nil then
                memo.map[peripheral] = def
            end
        end
        self.slotDefMemo = memo
    end
    return memo.map[peripheralName] or nil
end

-- The container-wide hand-set default multiplier (nil when none).
function Containers:slotMultiplierDefaultOf(peripheralName)
    local def = self:defOfPeripheral(peripheralName)
    local value = def and tonumber(def.slotMultiplierDefault)
    if value and value > 0 then
        return value
    end
    return nil
end

-- The user-set multiplier of one slot: the per-slot override first, then the
-- container-wide default. nil when the user set nothing for it.
function Containers:slotOverrideOf(peripheralName, slot)
    local def = self:defOfPeripheral(peripheralName)
    if not def then
        return nil
    end
    local map = def.slotMultipliers
    if type(map) == "table" then
        local value = tonumber(map[tostring(slot)])
        if value and value > 0 then
            return value
        end
    end
    return self:slotMultiplierDefaultOf(peripheralName)
end

-- Whether this container's slot multipliers have to be read from the device: only
-- whitelisted mods, and only while no user-set default covers all of its slots.
function Containers:needsSlotScan(peripheralName)
    if self:isFixedSlotCapacity(peripheralName) then
        return false
    end
    if not self:isScannedMod(peripheralName) then
        return false
    end
    return self:slotMultiplierDefaultOf(peripheralName) == nil
end

-- Fill in the known geometry of a fixed-capacity peripheral. Every slot carries a
-- precomputed `stacks` value, which slotStackCount() / slotCapacityFor() /
-- slotMultiplierOf() prefer over a getItemLimit()-derived limit - so the peripheral is
-- fully sized without a single capacity instruction, and can never hold compaction back.
function Containers:applyFixedSlotCapacity(peripheralName)
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    local size = tonumber(model.size)
    if not size or size < 1 or size > TURTLE_SLOTS then
        size = TURTLE_SLOTS
    end
    size = math.floor(size)
    model.size = size
    model.info = model.info or {}
    model.info.size = true
    model.slotLimits = model.slotLimits or {}
    for slot = 1, size do
        local entry = model.slotLimits[slot]
        if type(entry) ~= "table" then
            entry = {}
            model.slotLimits[slot] = entry
        end
        entry.stacks = TURTLE_SLOT_MULTIPLIER
    end
    model.limitKnown = size
    self:clearCapacityPending(peripheralName)
    if self.slotLimitPending then
        -- Drop requests queued before the geometry was known: there is nothing to read.
        self.slotLimitPending[peripheralName] = nil
    end
    return true
end

-- Containers whose slot capacities are not fully known yet. A container joins when
-- its slot count becomes known (and every slot limit is requested in bulk); it
-- leaves the list once every slot reported a readable limit. A slot the peripheral
-- cannot report keeps the container on the list: its capacity stays unknown, so no
-- compaction may touch that container.
function Containers:markCapacityPending(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    if self:isFixedSlotCapacity(peripheralName) then
        -- Fixed geometry: nothing to read, so it must never block compaction.
        return false
    end
    self.capacityPending = self.capacityPending or {}
    self.capacityPending[peripheralName] = true
    return true
end

function Containers:clearCapacityPending(peripheralName)
    if self.capacityPending then
        self.capacityPending[peripheralName] = nil
    end
end

-- O(1): does any container still have an unknown slot capacity?
function Containers:hasUnknownSlotCapacity()
    return self.capacityPending ~= nil and next(self.capacityPending) ~= nil
end

function Containers:pendingCapacityCount()
    local count = 0
    for _ in pairs(self.capacityPending or {}) do
        count = count + 1
    end
    return count
end

function Containers:pendingCapacityList(limit)
    local out = {}
    for peripheralName in pairs(self.capacityPending or {}) do
        out[#out + 1] = peripheralName
        if limit and #out >= limit then
            break
        end
    end
    table.sort(out)
    return out
end

-- Storage containers whose peripheral is attached but whose slot count has not been
-- read yet. A compact plan would silently skip them (slotCount() cannot size them), so
-- compaction waits instead of planning around a half-known storage. A container whose
-- peripheral is gone is NOT counted: it takes no part in compaction anyway.
function Containers:unknownSlotCountList(limit)
    local out = {}
    for _, containerName in ipairs(self:byRole("storage", "item")) do
        local def = self.Store:findContainer(containerName, "item")
        local peripheralName = def and def.peripheral or nil
        if peripheralName and self.Peripherals:exists(peripheralName)
            and self.Peripherals:isInventory(peripheralName)
            and not self:isFixedSlotCapacity(peripheralName) then
            local model = self.model[peripheralName]
            local size = model and tonumber(model.size) or nil
            if not size or size <= 0 then
                out[#out + 1] = peripheralName
                if limit and #out >= limit then
                    break
                end
            end
        end
    end
    table.sort(out)
    return out
end

function Containers:hasUnknownSlotCount()
    return #self:unknownSlotCountList() > 0
end

-- Every peripheral whose slot information is not fully read yet: the slot count is
-- unknown, or a slot capacity has not come back. This is exactly the set that holds
-- storage compaction back, so the web panel outlines these cards (see renderPeripherals).
function Containers:slotScanPendingPeripherals()
    local seen, out = {}, {}
    local function add(name)
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            out[#out + 1] = name
        end
    end
    for peripheralName in pairs(self.capacityPending or {}) do
        add(peripheralName)
    end
    for _, peripheralName in ipairs(self:unknownSlotCountList()) do
        add(peripheralName)
    end
    table.sort(out)
    return out
end

-- Every attached container whose definition currently cannot be used, with the real
-- reason (capability mismatch, ...) so the web panel can mark that card instead of
-- only the machine explaining it. A container that is merely waiting for its snapshot
-- is listed only for roles that are always scanned (storage / input); for interaction
-- and output roles "no snapshot" is a normal idle state, not a problem. The
-- slot-capacity pending set is appended too (reason nil).
function Containers:containerIssues(limit, pendingSlotScan)
    local out, seen = {}, {}
    local function add(peripheralName, containerName, kind, reason)
        if type(peripheralName) ~= "string" or peripheralName == "" or seen[peripheralName] then
            return
        end
        seen[peripheralName] = true
        out[#out + 1] = {
            peripheral = peripheralName,
            container = containerName,
            kind = kind,
            reason = reason,
        }
    end
    for _, def in ipairs(self.Store:list("containers")) do
        local peripheralName = def.peripheral
        if def.virtual ~= true and type(peripheralName) == "string" and peripheralName ~= ""
            and self.Peripherals:exists(peripheralName) then
            local defKind = self.Util.kindOfDef(def)
            local reason = self:unusableReason(def.name, defKind)
            if reason then
                local role = def.role or "storage"
                local scanning = reason.key == self.Message.KEYS.CONT_ERR_SCANNING
                if (not scanning) or role == "storage" or role == "input" then
                    add(peripheralName, def.name, defKind, reason)
                end
            end
        end
    end
    for _, peripheralName in ipairs(pendingSlotScan or self:slotScanPendingPeripherals()) do
        add(peripheralName, nil, nil, nil)
    end
    table.sort(out, function(a, b)
        return a.peripheral < b.peripheral
    end)
    limit = tonumber(limit)
    if limit and limit > 0 and #out > limit then
        local trimmed = {}
        for index = 1, limit do
            trimmed[index] = out[index]
        end
        return trimmed
    end
    return out
end

-- Every slot limit of one container, requested in bulk: getItemLimit() is one call
-- per slot, so the requests are parked in slotLimitPending and drained by the
-- slotLimit queue (see IFMMaster.queueSlotLimits).
local function requestAllSlotLimits(self, peripheralName)
    local model = self.model[peripheralName]
    local size = model and tonumber(model.size) or nil
    if not size or size <= 0 then
        return 0
    end
    local asked = 0
    for slot = 1, math.min(size, MAX_CONTAINER_SLOTS) do
        if not self:slotLimitOf(peripheralName, slot) then
            self:requestSlotLimit(peripheralName, slot)
            asked = asked + 1
        end
    end
    return asked
end

-- A container's slot multipliers are "fully read" only once EVERY slot can be sized: its
-- getItemLimit() value is in, and - for a slot that was occupied when that value was read
-- - the stack size of the item in it is known too. Until then the multiplier cannot be
-- computed, so the container stays on the pending list (see noteSlotLimitKnown) and
-- storage compaction keeps waiting for it, exactly like a slot whose limit is missing.
-- The check warms the cache: every slot it walks gets its multiplier stored
-- (slotStacksOf), so once it returns true the whole container is ready.
local function slotCapacityComplete(self, peripheralName)
    -- A container that is not slot-capacity scanned (a user default covers it, or its
    -- mod is not whitelisted) is complete as soon as its size is known.
    if not self:needsSlotScan(peripheralName) then
        return true
    end
    local model = self.model[peripheralName]
    local size = model and tonumber(model.size) or nil
    if not size or size <= 0 then
        return false
    end
    -- This check runs for every reply that lands (every slot limit and every item
    -- detail), and it used to walk the whole container again each time: with thousands of
    -- slots times a reply batch that ate a whole tick. `capacityCheckedTo` is the slot up
    -- to which every multiplier is verified, so a repeat only looks at what is new. The
    -- walk restarts at slot 1 whenever the basis changes (a new list scan, or a dropped
    -- multiplier cache - see refreshSlotMultipliers).
    if model.capacityCheckedGen ~= model.gen then
        model.capacityCheckedGen = model.gen
        model.capacityCheckedTo = 0
    end
    for slot = (tonumber(model.capacityCheckedTo) or 0) + 1, size do
        local entry = model.slotLimits and model.slotLimits[slot]
        if not entry then
            return false
        end
        if not entry.stacks and slotStacksOf(self, peripheralName, slot, entry) == nil then
            return false
        end
        model.capacityCheckedTo = slot
    end
    return true
end

-- One slot limit arrived: the container leaves the pending list once every slot's
-- multiplier can actually be computed - its getItemLimit() value AND, for a slot that
-- was occupied when it was read, the stack size of the item it holds.
local function noteSlotLimitKnown(self, peripheralName)
    if slotCapacityComplete(self, peripheralName) then
        self:clearCapacityPending(peripheralName)
    end
end

-- Re-derive every slot multiplier after the container definition changed (the user set
-- or cleared a multiplier). Cached values are dropped so the override takes effect at
-- once; a container that stopped needing a scan leaves the pending set immediately.
function Containers:refreshSlotMultipliers(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    local model = self.model[peripheralName]
    if model then
        for _, entry in pairs(model.slotLimits or {}) do
            if type(entry) == "table" then
                entry.stacks = nil
            end
        end
        -- Every cleared multiplier has to be computed again: the verification of
        -- slotCapacityComplete starts over at slot 1.
        model.capacityCheckedTo = 0
        model.capacityCheckedGen = model.gen
    end
    if self:needsSlotScan(peripheralName) then
        self:markCapacityPending(peripheralName)
        requestAllSlotLimits(self, peripheralName)
        noteSlotLimitKnown(self, peripheralName)
    else
        self:clearCapacityPending(peripheralName)
    end
    return true
end

-- An item's stack size just became known: a container that was waiting for exactly that
-- unit (a slot whose getItemLimit was read for this item) may now be fully sized. The
-- pending set only holds containers that are not sized yet, so this stays cheap, and
-- clearing the current key during the iteration is allowed.
local function noteSlotDetailsKnown(self)
    for peripheralName in pairs(self.capacityPending or {}) do
        noteSlotLimitKnown(self, peripheralName)
    end
end

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

function Containers:supports(containerName, kind)
    local def = self.Store:findContainer(containerName, kind)
    if not def then
        return false
    end
    local defKind = self.Util.kindOfDef(def)

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

    return (def.role or "storage") == "interaction" and self.Peripherals:isTurtle(def.peripheral)
end

-- A container is only *usable* once every instruction that defines its snapshot has
-- come back: the item/tank list (part "items"/"tanks") and, for inventories, the size
-- (part "size"). Until then it reports nothing, asks for what it is missing and is
-- treated as "still scanning" instead of "empty".
function Containers:infoMissing(peripheralName, kind)
    local model = type(peripheralName) == "string" and self.model[peripheralName] or nil
    if not model then
        return { "snapshot" }
    end
    local missing = {}
    local info = model.info or {}
    local wantItem = kind == nil or kind == "item"
    local wantFluid = kind == nil or kind == "fluid"
    if wantItem then
        if not info.items then
            missing[#missing + 1] = "items"
        end
        if self:needsSize(peripheralName) and not info.size then
            missing[#missing + 1] = "size"
        end
    end
    if wantFluid and not info.tanks then
        missing[#missing + 1] = "tanks"
    end
    if (model.scans or 0) == 0 then
        missing[#missing + 1] = "snapshot"
    end
    return missing
end

-- Inventories report a size(); fluid storages do not (they have tanks() only).
function Containers:needsSize(peripheralName)
    if not self.Peripherals then
        return false
    end
    if self.Peripherals:isFluid(peripheralName) and not self.Peripherals:isInventory(peripheralName) then
        return false
    end
    return self.Peripherals:isInventory(peripheralName)
end

-- Whether the snapshot of one *kind* of this peripheral is complete. A peripheral that
-- is both an inventory and a fluid storage keeps two independent snapshots (slots vs
-- tanks): reading its tanks must not make the item side look ready, and the item side
-- needs its own size() instruction (see needsSize).
function Containers:snapshotComplete(peripheralName, kind)
    local model = type(peripheralName) == "string" and self.model[peripheralName] or nil
    if not model or (model.scans or 0) == 0 then
        return false
    end
    local info = model.info
    if type(info) ~= "table" then
        return false
    end
    if kind == "fluid" then
        return info.tanks == true
    end
    if not info.items then
        return false
    end
    if self:needsSize(peripheralName) and not info.size then
        return false
    end
    return true
end

-- Kept for the item-oriented callers: the item side of the snapshot.
function Containers:hasSnapshot(peripheralName)
    return self:snapshotComplete(peripheralName, "item")
end

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
            and self:itemMoveUse(peripheralName, slot) == 0 then
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

function Containers:isInteractionContainer(containerName, kind)
    if type(containerName) ~= "string" or containerName == "" then
        return false
    end
    local def = self.Store and self.Store:findContainer(containerName, kind)
    return def ~= nil and (def.role or "storage") == "interaction"
end

local WATCH_TTL_MS = 15000

-- The web manual container tool keeps a container "watched" while it is open.
-- The browser renews the lease by calling container_view; when it stops (tab
-- closed, editor closed) the lease expires and the container stops being scanned
-- (unless an active process instance references it).
function Containers:watchContainer(containerName, kind, ttlMs)
    local peripheralName = self:peripheralOf(containerName, kind or "item")
    if not peripheralName then
        return false
    end
    self.watched = self.watched or {}
    local ttl = math.max(1000, tonumber(ttlMs) or WATCH_TTL_MS)
    self.watched[peripheralName] = os.epoch("utc") + ttl
    return true
end

function Containers:watchedPeripherals(now)
    now = tonumber(now) or os.epoch("utc")
    self.watched = self.watched or {}
    local out = {}
    for peripheralName, untilAt in pairs(self.watched) do
        if (tonumber(untilAt) or 0) > now then
            out[peripheralName] = true
        else
            self.watched[peripheralName] = nil
        end
    end
    return out
end

-- The container the manual tool is looking at right now, renewed by its poll. Kept
-- apart from the watch lease because the scan pass treats a viewed container as
-- needed no matter what role it has: the tool has to show the slots of a container
-- that no process instance uses yet.
function Containers:noteView(peripheralName, ttlMs)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    self.viewed = self.viewed or {}
    local ttl = math.max(1000, tonumber(ttlMs) or WATCH_TTL_MS)
    self.viewed[peripheralName] = os.epoch("utc") + ttl
    return true
end

function Containers:viewedPeripherals(now)
    now = tonumber(now) or os.epoch("utc")
    self.viewed = self.viewed or {}
    local out = {}
    for peripheralName, untilAt in pairs(self.viewed) do
        if (tonumber(untilAt) or 0) > now then
            out[peripheralName] = true
        else
            self.viewed[peripheralName] = nil
        end
    end
    return out
end

function Containers:watchCount(now)
    local count = 0
    for _ in pairs(self:watchedPeripherals(now)) do
        count = count + 1
    end
    return count
end

-- A container with unsettled in-use reservations (a move whose result never came
-- back, or a process claim pinned onto it) has to keep being scanned while it
-- settles, even when nobody watches it and no active instance references its
-- machine. The snapshot itself never times a source out; this only keeps the raw
-- store fresh, the release is driven by the source's own lifecycle.
function Containers:needsReconcile(peripheralName)
    if type(peripheralName) ~= "string" then
        return false
    end
    local use = self.inUse[peripheralName]
    if not use then
        return false
    end
    return next(use.slots) ~= nil or next(use.fluids) ~= nil
end

function Containers:reconcilePeripherals()
    local out = {}
    for _, def in ipairs(self.Store:list("containers")) do
        local peripheralName = def.peripheral
        if type(peripheralName) == "string" and peripheralName ~= "" and def.virtual ~= true
            and self:needsReconcile(peripheralName) then
            out[peripheralName] = true
        end
    end
    return out
end

-- unusableReason is polled every tick (deliveries compare it by identity to decide
-- whether to mark the cache dirty), so a container must keep getting the *same*
-- table back while its reason does not change.
function Containers:reasonNode(key, params, cacheKey)
    self.reasonCache = self.reasonCache or {}
    local node = cacheKey and self.reasonCache[cacheKey] or nil
    if node and node.key == key then
        return node
    end
    node = self.Message.msg(key, params)
    if cacheKey then
        self.reasonCache[cacheKey] = node
    end
    return node
end

function Containers:unusableReason(containerName, kind)
    local cacheKey = "cont|" .. tostring(containerName) .. "|" .. tostring(kind)
    if containerName == nil or containerName == "" then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_UNSPECIFIED, nil, cacheKey)
    end
    local def = self.Store:findContainer(containerName, kind)
    if not def then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_DEF_MISSING, { name = tostring(containerName) }, cacheKey)
    end
    local defKind = self.Util.kindOfDef(def)
    if kind and kind ~= "filter" and defKind ~= kind then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_DEF_KIND, { name = def.name, kind = self.Message.msg(defKind == "fluid" and self.Message.KEYS.COMMON_FLUID or self.Message.KEYS.COMMON_ITEM) }, cacheKey)
    end
    if not self.Peripherals:exists(def.peripheral) then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_PERIPHERAL_MISSING, { name = def.name, peripheral = def.peripheral }, cacheKey)
    end
    -- Capability is checked before the snapshot: a peripheral that is simply the
    -- wrong kind of container (a fluid storage configured as an item container, say)
    -- never gets a snapshot, so asking hasSnapshot() first reported it as "still
    -- scanning" forever and hid the real reason.
    if defKind == "fluid" then
        if not self.Peripherals:isFluid(def.peripheral) then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_NO_FLUID_CAPABILITY, { peripheral = def.peripheral }, cacheKey)
        end
    elseif not self.Peripherals:isInventory(def.peripheral)
        and not ((def.role or "storage") == "interaction" and self.Peripherals:isTurtle(def.peripheral)) then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_NO_ITEM_CAPABILITY, { peripheral = def.peripheral }, cacheKey)
    end
    -- The kind decides which snapshot is required: a dual peripheral (inventory +
    -- fluid_storage) has an item snapshot and a fluid snapshot, and the fluid one does
    -- not need the item side's size() to be read.
    if not self:snapshotComplete(def.peripheral, defKind) then
    return self:reasonNode(self.Message.KEYS.CONT_ERR_SCANNING, { name = def.name, peripheral = def.peripheral }, cacheKey)
    end
    return nil
end

function Containers.priorityOf(def)
    return tonumber(def and def.priority) or 0
end

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
-- (Containers:inventory / Containers:fluidStorage were removed: they were the last
-- place the master wrapped an inventory/fluid peripheral itself. The snapshot models
-- and the worker instructions replace them - the master never touches a container
-- peripheral directly any more.)

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

function Containers:noteReadCost(elapsed)
    elapsed = math.max(1, math.floor(tonumber(elapsed) or 1))
    self.readCount = self.readCount + 1
    self.readMsTotal = (self.readMsTotal or 0) + elapsed

    local cost = self.readCostMs or 0
    if cost <= 0 then
        self.readCostMs = elapsed
    else

        self.readCostMs = (cost * 3 + elapsed) / 4
    end
end

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

    local staleMax, staleSum, counted, incomplete, unsized = 0, 0, 0, 0, 0
    for _, model in pairs(self.model) do
        local ageTicks = math.max(0, (self.tickCount or 0) - (model.tick or 0))
        staleSum = staleSum + ageTicks
        counted = counted + 1
        if ageTicks > staleMax then
            staleMax = ageTicks
        end
    end
    -- Containers whose snapshot is not complete yet (still waiting for the item list or
    -- the size instruction): they are not usable, so they are reported separately
    -- instead of looking like "empty".
    for peripheralName in pairs(self.model) do
        -- Either kind being complete makes the peripheral usable for that kind; only a
        -- peripheral incomplete for BOTH kinds is truly unusable.
        if not (self:snapshotComplete(peripheralName, "item")
            or self:snapshotComplete(peripheralName, "fluid")) then
            incomplete = incomplete + 1
        end
    end
    for _, containerName in ipairs(self:byRole("storage", "item")) do
        if unsized >= 4096 then
            break
        end
        local peripheralName = self:peripheralOf(containerName, "item")
        local model = peripheralName and self.model[peripheralName] or nil
        local size = model and tonumber(model.size) or 0
        local limits = model and model.slotLimits or nil
        for slot = 1, size do
            if unsized >= 4096 then
                break
            end
            local entry = limits and limits[slot]
            -- A slot counts as unsized while its multiplier cannot be computed yet: no
            -- limit read, or (for a slot that was occupied when it was read) the stack
            -- size of the item it holds still unknown.
            if not entry or (not entry.stacks
                and self:slotMultiplierOf(peripheralName, slot) == nil) then
                unsized = unsized + 1
            end
        end
    end
    local cost = math.floor(self.readCostMs or 0)
    local pass = cost * math.max(1, self:peripheralCount())
    self.listPassMs = math.floor(pass)
    local watched = self:watchCount()
    local reconcile = 0
    for _ in pairs(self:reconcilePeripherals()) do
        reconcile = reconcile + 1
    end
    return {
        containers = self:peripheralCount(),
        scanned = counted,
        readCost = cost,
        passCost = self.listPassMs,

        ttl = 0,
        baseTtl = 0,
        multiplier = 0,
        reads = self.readCount or 0,
        readMs = self.readMsTotal or 0,
        defer = self.moveSettleCount or 0,
        budget = 0,

        staleTicks = staleMax,
        staleAvgTicks = counted > 0 and math.floor(staleSum / counted) or 0,
        watched = watched,
        reconcile = reconcile,
        incomplete = incomplete,
        unsized = unsized,
    }
end

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

function Containers:advanceTick()
    self.tickCount = self.tickCount + 1
        end

function Containers:needsScan(peripheralName, maxAgeTicks)
    local model = self.model[peripheralName]
    if not model or (model.scans or 0) == 0 then
        return true
    end
    return ((self.tickCount or 0) - (model.tick or 0)) >= (tonumber(maxAgeTicks) or 20)
end

function Containers:modelOf(peripheralName)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil
    end
    local model = self.model[peripheralName]
    if not model then
        model = { slots = {}, tanks = {},
            gen = 0, stamp = 0, scans = 0, info = { list = false, size = false } }
        self.model[peripheralName] = model
    end
    return model
end
local function itemKeyOf(name, nbt)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name .. "\0" .. tostring(nbt or "")
end

-- =====================================================================
-- Snapshot ledgers (encapsulated): raw store, in-use, reverse index.
-- Callers must go through the methods below; they never touch self.index,
-- self.inUse or self.sourceIndex directly.
-- =====================================================================

local function locKeyOf(kind, peripheralName, index)
    return tostring(kind) .. "\1" .. tostring(peripheralName) .. "\1" .. tostring(index or 0)
end

-- A process instance owns a claim source ("process:<owner>#<id>"); everything else
-- (a move key) is an in-flight move source.
local function isClaimSource(source)
    return type(source) == "string" and string.sub(source, 1, 8) == "process:"
end

function Containers:inUseOf(peripheralName, create)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil
    end
    local entry = self.inUse[peripheralName]
    if not entry and create then
        entry = { slots = {}, fluids = {} }
        self.inUse[peripheralName] = entry
    end
    return entry
end

local function itemUseSlot(self, peripheralName, slot, create)
    local use = self:inUseOf(peripheralName, create)
    if not use then
        return nil
    end
    slot = tonumber(slot)
    if not slot or slot < 1 then
        return nil
    end
    local entry = use.slots[slot]
    if not entry and create then
        entry = { sources = {}, total = 0 }
        use.slots[slot] = entry
    end
    return entry
end

local function fluidUseSlot(self, peripheralName, name, create)
    local use = self:inUseOf(peripheralName, create)
    if not use then
        return nil
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local entry = use.fluids[name]
    if not entry and create then
        entry = { sources = {}, total = 0 }
        use.fluids[name] = entry
    end
    return entry
end

-- Adjust one (peripheral, position) in-use entry by `delta` for `source`.
local function addUse(self, kind, peripheralName, index, source, delta)
    local entry
    if kind == "fluid" then
        entry = fluidUseSlot(self, peripheralName, index, true)
    else
        entry = itemUseSlot(self, peripheralName, index, true)
    end
    if not entry then
        return
    end
    local held = (entry.sources[source] or 0) + delta
    if held <= 0 then
        entry.sources[source] = nil
    else
        entry.sources[source] = held
    end
    entry.total = math.max(0, (tonumber(entry.total) or 0) + delta)
    if entry.total <= 0 and next(entry.sources) == nil then
        local use = self.inUse[peripheralName]
        if use then
            if kind == "fluid" then
                use.fluids[index] = nil
            else
                use.slots[tonumber(index)] = nil
            end
            if next(use.slots) == nil and next(use.fluids) == nil then
                self.inUse[peripheralName] = nil
            end
        end
    end
end

-- ------------------------------------------------------------- reverse index
function Containers:indexAddItem(peripheralName, slot, name, nbt)
    local key = itemKeyOf(name, nbt)
    if not key then
        return
    end
    slot = tonumber(slot)
    if not slot or slot < 1 then
        return
    end
    local bucket = self.index.items[key]
    if not bucket then
        bucket = {}
        self.index.items[key] = bucket
    end
    local byPeripheral = bucket[peripheralName]
    if not byPeripheral then
        byPeripheral = {}
        bucket[peripheralName] = byPeripheral
    end
    byPeripheral[slot] = true
end

function Containers:indexRemoveItem(peripheralName, slot, name, nbt)
    local key = itemKeyOf(name, nbt)
    if not key then
        return
    end
    slot = tonumber(slot)
    local bucket = self.index.items[key]
    if not bucket then
        return
    end
    local byPeripheral = bucket[peripheralName]
    if not byPeripheral then
        return
    end
    byPeripheral[slot] = nil
    if next(byPeripheral) == nil then
        bucket[peripheralName] = nil
    end
    if next(bucket) == nil then
        self.index.items[key] = nil
    end
end

function Containers:indexAddFluid(peripheralName, name)
    if type(name) ~= "string" or name == "" then
        return
    end
    local bucket = self.index.fluids[name]
    if not bucket then
        bucket = {}
        self.index.fluids[name] = bucket
    end
    bucket[peripheralName] = true
end

function Containers:indexRemoveFluid(peripheralName, name)
    if type(name) ~= "string" or name == "" then
        return
    end
    local bucket = self.index.fluids[name]
    if not bucket then
        return
    end
    bucket[peripheralName] = nil
    if next(bucket) == nil then
        self.index.fluids[name] = nil
    end
end

-- Drop the index entries of whatever a model currently holds (before it is
-- overwritten by a new scan, cleared or forgotten).
function Containers:indexClearSlots(peripheralName)
    local model = self.model[peripheralName]
    if not model then
        return
    end
    for slot, entry in pairs(model.slots or {}) do
        if type(entry) == "table" and entry.name then
            self:indexRemoveItem(peripheralName, slot, entry.name, entry.nbt)
        end
    end
end

function Containers:indexClearTanks(peripheralName)
    local model = self.model[peripheralName]
    if not model then
        return
    end
    for _, entry in pairs(model.tanks or {}) do
        if type(entry) == "table" and entry.name then
            self:indexRemoveFluid(peripheralName, entry.name)
        end
    end
end

function Containers:indexClearModel(peripheralName)
    self:indexClearSlots(peripheralName)
    self:indexClearTanks(peripheralName)
end

-- ------------------------------------------------------------- reserve / release
-- Reserve `amount` of a resource at one concrete position for `source`. The
-- position is a slot for items and the tank's fluid name for fluids.
function Containers:reserve(source, kind, peripheralName, index, resource, nbt, amount, dir)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or type(source) ~= "string" or source == "" then
        return 0
    end
    dir = (dir == "in") and "in" or "out"
    if kind == "fluid" then
        if type(resource) ~= "string" or resource == "" then
            return 0
        end
        addUse(self, "fluid", peripheralName, resource, source, amount)
    else
        index = tonumber(index)
        if not index or index < 1 then
            return 0
        end
        addUse(self, "item", peripheralName, index, source, amount)
    end
    local key = locKeyOf(kind, peripheralName, kind == "fluid" and resource or index)
    local map = self.sourceIndex[source]
    if not map then
        map = {}
        self.sourceIndex[source] = map
    end
    local loc = map[key]
    if not loc then
        loc = { kind = kind == "fluid" and "fluid" or "item", peripheral = peripheralName,
            index = index, resource = resource, nbt = nbt, amount = 0, dir = dir }
        map[key] = loc
    end
    loc.amount = loc.amount + amount
    return amount
end

-- Release (or shrink to `keep`) one source whole, everywhere it is pinned.
function Containers:releaseReserve(source, keep)
    local map = self.sourceIndex[source]
    if not map then
        return 0
    end
    local released = 0
    for key, loc in pairs(map) do
        local target
        if keep == nil then
            target = 0
        else
            target = math.max(0, math.min(loc.amount, math.floor(tonumber(keep) or 0)))
        end
        local drop = loc.amount - target
        if drop > 0 then
            addUse(self, loc.kind, loc.peripheral, loc.kind == "fluid" and loc.resource or loc.index,
                source, -drop)
            loc.amount = target
            released = released + drop
        end
        if loc.amount <= 0 then
            map[key] = nil
        end
    end
    if next(map) == nil then
        self.sourceIndex[source] = nil
    end
    return released
end

-- How much of `source` is pinned at one position right now.
function Containers:useHeldBy(peripheralName, kind, index, source)
    local use = self.inUse[peripheralName]
    if not use then
        return 0
    end
    local entry
    if kind == "fluid" then
        entry = use.fluids[index]
    else
        entry = use.slots[tonumber(index)]
    end
    return (entry and entry.sources[source]) or 0
end

function Containers:itemUseTotal(peripheralName, slot)
    local use = self.inUse[peripheralName]
    local entry = use and use.slots[tonumber(slot)]
    return entry and (tonumber(entry.total) or 0) or 0
end

function Containers:fluidUseTotal(peripheralName, fluidName)
    local use = self.inUse[peripheralName]
    local entry = use and use.fluids[fluidName]
    return entry and (tonumber(entry.total) or 0) or 0
end

-- Sum only the move sources (or only the claim sources) of one in-use entry. The
-- feasibility checks of a move look at *move* usage only: a process instance has to
-- be able to fetch the material it reserved itself, so its own claim must not block
-- the move that consumes it. Planning availability, on the other hand, counts both.
local function sumUse(entry, mode)
    if not entry then
        return 0
    end
    local total = 0
    for source, amount in pairs(entry.sources) do
        local claim = isClaimSource(source)
        if (mode == "claim" and claim) or (mode == "move" and not claim) or mode == "all" then
            total = total + amount
        end
    end
    return total
end

function Containers:itemMoveUse(peripheralName, slot)
    local use = self.inUse[peripheralName]
    return sumUse(use and use.slots[tonumber(slot)], "move")
end

function Containers:fluidMoveUse(peripheralName, fluidName)
    local use = self.inUse[peripheralName]
    return sumUse(use and use.fluids[fluidName], "move")
end

-- A slot is busy while any source (an in-flight move or a process claim) holds
-- something in it; the automatic routines skip busy slots.
function Containers:slotBusy(peripheralName, slot)
    return self:itemUseTotal(peripheralName, slot) > 0
end

-- All sources currently pinned at one position, biggest first (diagnostics / panels).
function Containers:sourcesAt(peripheralName, kind, index)
    local use = self.inUse[peripheralName]
    if not use then
        return {}
    end
    local entry
    if kind == "fluid" then
        entry = use.fluids[index]
    else
        entry = use.slots[tonumber(index)]
    end
    if not entry then
        return {}
    end
    local out = {}
    for source, amount in pairs(entry.sources) do
        out[#out + 1] = { source = source, amount = amount }
    end
    table.sort(out, function(a, b)
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return a.source < b.source
    end)
    return out
end

-- Drop the in-use ledger of one peripheral. Pinned process claims are turned into
-- residual claims (they survive at the resource level), so removing a storage
-- container does not silently forget what a batch reserved.
function Containers:releaseInUseOf(peripheralName)
    for source, map in pairs(self.sourceIndex) do
        local dropKeys = {}
        for key, loc in pairs(map) do
            if loc.peripheral == peripheralName then
                if isClaimSource(source) then
                    self:residualAdd(source,
                        tostring(loc.kind) .. ":" .. tostring(loc.resource or ""), loc.amount)
                end
                dropKeys[#dropKeys + 1] = key
            end
        end
        for _, key in ipairs(dropKeys) do
            map[key] = nil
        end
        if next(map) == nil then
            self.sourceIndex[source] = nil
        end
    end
    self.inUse[peripheralName] = nil
end

-- ------------------------------------------------------------ process claims
local function claimKeyOfSpec(spec)
    local kind = (type(spec) == "table" and spec.kind) or "item"
    local id = (type(spec) == "table" and (spec.id or spec.name)) or ""
    return tostring(kind) .. ":" .. tostring(id)
end

function Containers:residualEntry(key, create)
    local entry = self.claimResidual[key]
    if not entry and create then
        entry = { sources = {}, total = 0 }
        self.claimResidual[key] = entry
    end
    return entry
end

function Containers:residualAdd(source, key, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or type(key) ~= "string" or key == "" then
        return 0
    end
    local entry = self:residualEntry(key, true)
    entry.sources[source] = (entry.sources[source] or 0) + amount
    entry.total = (entry.total or 0) + amount
    return amount
end

function Containers:residualTake(source, key, amount)
    local entry = self.claimResidual[key]
    if not entry then
        return 0
    end
    local held = entry.sources[source] or 0
    local take = math.min(held, math.max(0, math.floor(tonumber(amount) or 0)))
    if take <= 0 then
        return 0
    end
    entry.sources[source] = held - take
    if entry.sources[source] <= 0 then
        entry.sources[source] = nil
    end
    entry.total = math.max(0, (entry.total or 0) - take)
    if entry.total <= 0 and next(entry.sources) == nil then
        self.claimResidual[key] = nil
    end
    return take
end

-- Does one concrete resource match a spec (item / fluid / filter)?
function Containers:resourceMatchesSpec(spec, kind, name, nbt)
    if type(spec) ~= "table" then
        return false
    end
    if spec.kind == "filter" then
        if kind ~= "fluid" and kind ~= "item" then
            return false
        end
        return (self.Filter and self.Filter:specMatches(spec, { kind = kind, name = name, nbt = nbt }))
            or false
    end
    if (spec.kind == "fluid") ~= (kind == "fluid") then
        return false
    end
    if type(spec.id) == "string" and spec.id ~= "" and spec.id ~= name then
        return false
    end
    if spec.ignoreNbt == false and tostring(spec.nbt or "") ~= tostring(nbt or "") then
        return false
    end
    return true
end

local function locMatchesSpec(self, loc, spec)
    return self:resourceMatchesSpec(spec, loc.kind, loc.resource, loc.nbt)
end

function Containers:isStoragePeripheral(peripheralName, kind)
    if not self.Store then
        return false
    end
    kind = kind or "item"
    local def
    if self.Store.findContainerByPeripheral then
        def = self.Store:findContainerByPeripheral(peripheralName, kind)
    end
    if not def and self.Store.findContainer then
        def = self.Store:findContainer(peripheralName, kind)
    end
    return def ~= nil and (def.role or "storage") == "storage"
end

-- Every storage position holding something that matches `spec`, with how much of
-- it is still free. Used to pin a process claim onto concrete slots.
function Containers:allocatableLocations(spec)
    local out = {}
    if type(spec) ~= "table" then
        return out
    end
    if spec.kind ~= "fluid" then
        for key, bucket in pairs(self.index.items) do
            local name, nbt = key:match("^(.-)\0(.*)$")
            if name and self:resourceMatchesSpec(spec, "item", name, nbt) then
                for peripheralName, byPeripheral in pairs(bucket) do
                    if self:isStoragePeripheral(peripheralName, "item") then
                        local model = self.model[peripheralName]
                        for slot in pairs(byPeripheral) do
                            local stored = model and model.slots and model.slots[slot]
                            if stored then
                                local free = (tonumber(stored.count) or 0)
                                    - self:itemUseTotal(peripheralName, slot)
                                if free > 0 then
                                    out[#out + 1] = { kind = "item", peripheral = peripheralName,
                                        resource = name, nbt = stored.nbt, index = slot, available = free }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if spec.kind ~= "item" then
        for name, bucket in pairs(self.index.fluids) do
            if self:resourceMatchesSpec(spec, "fluid", name, nil) then
                for peripheralName in pairs(bucket) do
                    if self:isStoragePeripheral(peripheralName, "fluid") then
                        local model = self.model[peripheralName]
                        local stored = 0
                        for _, tank in pairs(model and model.tanks or {}) do
                            if tank.name == name then
                                stored = stored + (tonumber(tank.amount) or 0)
                            end
                        end
                        local free = stored - self:fluidUseTotal(peripheralName, name)
                        if free > 0 then
                            out[#out + 1] = { kind = "fluid", peripheral = peripheralName,
                                resource = name, nbt = nil, index = name, available = free }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.available ~= b.available then
            return a.available > b.available
        end
        if a.peripheral ~= b.peripheral then
            return a.peripheral < b.peripheral
        end
        return tostring(a.index) < tostring(b.index)
    end)
    return out
end

-- A process instance reserves its whole batch when it is created: claim() pins as
-- much as it can to concrete storage positions (so a free slot can never be handed
-- out twice) and keeps the rest as a residual counter for that resource, which is
-- what survives a restart before the first scan comes in. Input releases the claim
-- again, a slice per successful input, through releaseClaimAmount().
function Containers:claim(spec, amount, owner)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return 0
    end
    owner = owner or "?"
    local remaining = amount
    for _, loc in ipairs(self:allocatableLocations(spec)) do
        if remaining <= 0 then
            break
        end
        local take = math.min(loc.available, remaining)
        if take > 0 then
            self:reserve(owner, loc.kind, loc.peripheral, loc.index, loc.resource, loc.nbt, take)
            remaining = remaining - take
        end
    end
    if remaining > 0 then
        self:residualAdd(owner, claimKeyOfSpec(spec), remaining)
    end
    return amount
end

-- Release `amount` of one resource for a claim source (pinned positions first,
-- then the residual counter). Returns what was actually released.
function Containers:releaseClaimAmount(spec, amount, owner)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 or not owner then
        return 0
    end
    local released = 0
    local map = self.sourceIndex[owner]
    if map then
        for key, loc in pairs(map) do
            if released >= amount then
                break
            end
            if locMatchesSpec(self, loc, spec) then
                local take = math.min(loc.amount, amount - released)
                if take > 0 then
                    addUse(self, loc.kind, loc.peripheral,
                        loc.kind == "fluid" and loc.resource or loc.index, owner, -take)
                    loc.amount = loc.amount - take
                    released = released + take
                    if loc.amount <= 0 then
                        map[key] = nil
                    end
                end
            end
        end
        if next(map) == nil then
            self.sourceIndex[owner] = nil
        end
    end
    if released < amount then
        released = released + self:residualTake(owner, claimKeyOfSpec(spec), amount - released)
    end
    return released
end

function Containers:releaseClaim(spec, amount, owner)
    return self:releaseClaimAmount(spec, amount, owner)
end

-- Drop every reservation of one claim source (instance finish / abort).
function Containers:releaseClaimSource(owner)
    if not owner then
        return 0
    end
    local released = self:releaseReserve(owner)
    for key, entry in pairs(self.claimResidual) do
        local held = entry.sources[owner]
        if held and held > 0 then
            entry.sources[owner] = nil
            entry.total = math.max(0, (entry.total or 0) - held)
            released = released + held
            if entry.total <= 0 and next(entry.sources) == nil then
                self.claimResidual[key] = nil
            end
        end
    end
    return released
end

function Containers:claimedAmount(spec)
    if type(spec) ~= "table" or spec.id == nil then
        return 0
    end
    local total = 0
    for source, map in pairs(self.sourceIndex or {}) do
        if isClaimSource(source) then
            for _, loc in pairs(map) do
                if loc.dir ~= "in" and locMatchesSpec(self, loc, spec) then
                    total = total + loc.amount
                end
            end
        end
    end
    local residual = self.claimResidual[claimKeyOfSpec(spec)]
    if residual then
        total = total + (residual.total or 0)
    end
    return total
end

-- Amount that is in flight out of the snapshot for this resource (move sources
-- only; claims are reported by claimedAmount()).
function Containers:dirtyAmount(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        return 0
    end
    local total = 0
    for source, map in pairs(self.sourceIndex or {}) do
        if not isClaimSource(source) then
            for _, loc in pairs(map) do
                -- Only the source side of a move counts: a move reserves its source
                -- ("out") and its target ("in"), and counting both would report the
                -- same in-flight amount twice.
                if loc.dir ~= "in" and locMatchesSpec(self, loc, spec) then
                    total = total + loc.amount
                end
            end
        end
    end
    return total
end

function Containers:claimsSummary()
    local out = {}
    for key, entry in pairs(self.claimResidual or {}) do
        out[#out + 1] = { key = key, total = entry.total, owners = self:sourcesOfMap(entry.sources) }
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

function Containers:sourcesOfMap(map)
    local out = {}
    for source, amount in pairs(map or {}) do
        out[#out + 1] = { source = source, amount = amount }
    end
    table.sort(out, function(a, b)
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return a.source < b.source
    end)
    return out
end

-- (Containers:isDirtySlot is gone: the item/fluid dirty-mark system was removed.
-- "Is this slot busy?" is Containers:slotBusy().)

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

function Containers:visibleSlotCount(model, slot)
    if not model then
        return 0
    end
    local entry = model.slots[slot]
    return entry and (tonumber(entry.count) or 0) or 0
end

function Containers:visibleTankAmount(model, tank)
    if not model then
        return 0
    end
    local entry = model.tanks[tank]
    return entry and (tonumber(entry.amount) or 0) or 0
end

function Containers:visibleSlots(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for slot, entry in pairs(model.slots) do
        local count = Assert.count(entry.count, "snapshot count of " .. tostring(peripheralName))
        if count > 0 and entry.name then
            out[slot] = { name = entry.name, count = count, nbt = entry.nbt }
        end
    end
    return out
end

function Containers:visibleTanks(peripheralName)
    local model = self:modelOf(peripheralName)
    local out = {}
    if not model then
        return out
    end
    for tank, entry in pairs(model.tanks) do
        local amount = Assert.count(entry.amount, "snapshot tank amount of " .. tostring(peripheralName))
        if amount > 0 and entry.name then
            out[tank] = { name = entry.name, amount = amount }
        end
    end
    return out
end

-- Rebuild the claim ledger from the restored instances. `inst.claims` is persisted
-- in cache.json, so without this the in-memory ledger would start empty after a
-- restart while the instances still believe they hold material. At boot the store
-- has not been scanned yet, so a restored claim lands in the residual counter of
-- its resource - it still makes that resource unavailable, and the regular claim
-- path pins it to concrete slots as soon as the first scan is in.
function Containers:rebuildClaims(instances)
    self.claimResidual = {}
    local stale = {}
    for source in pairs(self.sourceIndex or {}) do
        if isClaimSource(source) then
            stale[#stale + 1] = source
        end
    end
    for _, source in ipairs(stale) do
        self:releaseReserve(source)
    end
    local restored = 0
    for id, inst in pairs(instances or {}) do
        local source = "process:" .. tostring(inst.owner or "") .. "#" .. tostring(inst.id or id)
        for key, amount in pairs(inst.claims or {}) do
            local kind, rid = key:match("^(%a+):(.*)$")
            if kind and rid then
                self:claim({ kind = kind, id = rid }, amount, source)
                restored = restored + 1
            end
        end
    end
    return restored
end

-- Per-slot claim (dirty) marks of one container, for the web container tool: an
-- operator can then see which slots an in-flight move has already claimed, and
-- why the automatic drain skips them.
-- Reservation view of one container, for the web container tool. Kept in the same
-- shape as before (slots / items / fluids / summary) so the UI does not change; the
-- numbers now come from the in-use ledger (in-flight moves and process claims).
function Containers:claimView(containerName, kind)
    kind = (kind == "fluid") and "fluid" or "item"
    local out = {
        kind = kind,
        slots = {},
        items = {},
        fluids = {},
        summary = { slots = 0, items = 0, fluids = 0, inFlight = 0, oldestMs = 0 },
    }
    local peripheralName = self:peripheralOf(containerName, kind)
    if not peripheralName then
        return out
    end
    local use = self:inUseOf(peripheralName, false)
    if use then
        if kind == "item" then
            local model = self.model[peripheralName]
            for slot, entry in pairs(use.slots or {}) do
                local total = tonumber(entry.total) or 0
                if total > 0 then
                    local stored = model and model.slots and model.slots[slot]
                    local outMap, intoMap = {}, {}
                    for _, source in ipairs(self:sourcesAt(peripheralName, "item", slot)) do
                        if isClaimSource(source.source) then
                            intoMap[source.source] = source.amount
                        else
                            outMap[source.source] = source.amount
                        end
                    end
                    out.slots[#out.slots + 1] = {
                        index = tonumber(slot) or 0,
                        dir = (#self:sourcesAt(peripheralName, "item", slot) > 0) and "out" or "in",
                        amount = total,
                        item = stored and stored.name or nil,
                        nbt = stored and stored.nbt or nil,
                        ageMs = 0,
                    }
                    out.items[#out.items + 1] = {
                        slot = tonumber(slot) or 0,
                        name = stored and stored.name or nil,
                        nbt = stored and stored.nbt or nil,
                        out = total,
                        inCount = 0,
                        sources = { out = self:sourcesOfMap(outMap), into = self:sourcesOfMap(intoMap) },
                    }
                end
            end
            table.sort(out.slots, function(a, b) return a.index < b.index end)
            table.sort(out.items, function(a, b) return a.slot < b.slot end)
        else
            for fluidName, entry in pairs(use.fluids or {}) do
                local total = tonumber(entry.total) or 0
                if total > 0 then
                    out.fluids[#out.fluids + 1] = {
                        name = tostring(fluidName),
                        out = total,
                        inCount = 0,
                        sources = { out = self:sourcesAt(peripheralName, "fluid", fluidName), into = {} },
                    }
                end
            end
            table.sort(out.fluids, function(a, b) return tostring(a.name) < tostring(b.name) end)
        end
    end
    out.summary.slots = #out.slots
    out.summary.items = #out.items
    out.summary.fluids = #out.fluids
    for _, record in pairs(self.moveInflight or {}) do
        if record.from == peripheralName or record.to == peripheralName then
            out.summary.inFlight = out.summary.inFlight + 1
        end
    end
    return out
end

-- How much of a spec can really be used right now: every matching storage position
-- minus what is already in use there (in-flight moves and pinned claims), with the
-- resource-level residual claims subtracted on top.
function Containers:availableForCraft(spec)
    local visible = self:countOf(spec, "storage")
    local available = 0
    for _, loc in ipairs(self:allocatableLocations(spec)) do
        available = available + loc.available
    end
    local residual = self.claimResidual[claimKeyOfSpec(spec)]
    if residual then
        available = math.max(0, available - (residual.total or 0))
    end
    available = math.max(0, math.floor(available))
    return available, visible, self:dirtyAmount(spec), self:claimedAmount(spec)
end

function Containers:availableForFilterSpec(spec)
    if type(spec) ~= "table" or spec.kind ~= "filter" then
        return 0
    end
    local total = 0
    for _, loc in ipairs(self:allocatableLocations(spec)) do
        total = total + loc.available
    end
    local residual = self.claimResidual[claimKeyOfSpec(spec)]
    if residual then
        total = math.max(0, total - (residual.total or 0))
    end
    return math.max(0, math.floor(total))
end


-- (Containers:applyCount is gone: it mutated the raw model behind the index and had
-- no callers left. Snapshot writes go through applyItems/applyTanks, reservations
-- through reserve()/releaseReserve().)

function Containers:noteMoveResult(record, moved, err)
    self.moveResults = self.moveResults or {}
    self.moveResults[record.key] = { moved = moved, err = (moved > 0) and nil or err, at = os.epoch("utc") }
    self.moveResultCount = self.moveResultCount + 1
    local now = os.epoch("utc")
    if self.moveResultCount <= 5 or now - (self.moveResultLogAt or 0) > 500 then
        self.moveResultLogAt = now
        self.log("[debug] move-result key=%s moved=%d %s -> %s (%s)", tostring(record.key), moved,
            tostring(record.from), tostring(record.to), tostring(record.moveAction or record.action))
    end
end

-- Amount still movable from this record's source (visible snapshot minus the
-- "leaving" claims of the six move functions).
function Containers:sourceFreeFor(record)
    if type(record) ~= "table" then
        return 0
    end
    local model = self:modelOf(record.from)
    if not model then
        return 0
    end
    if record.kind == "fluid" then
        local stored = 0
        for _, entry in pairs(model.tanks) do
            if entry.name == record.item then
                stored = stored + (tonumber(entry.amount) or 0)
            end
        end
        -- Exclude this move's own reservation: it is not "other traffic" that
        -- blocks the retry.
        local use = self:fluidUseTotal(record.from, record.item)
            - self:useHeldBy(record.from, "fluid", record.item, record.key)
        return math.max(0, stored - use)
    end
    local stored = self:visibleSlotCount(model, record.fromIndex)
    local use = self:itemUseTotal(record.from, record.fromIndex)
        - self:useHeldBy(record.from, "item", record.fromIndex, record.key)
    return math.max(0, stored - use)
end

-- final ~= false: the instruction ended (done / dropped / released) - release this
-- move's whole reservation. final == false: still running (retry) - shrink it to
-- what is still reserved.
function Containers:settleMove(request, moved, final)
    if type(request) ~= "table" then
        return
    end
    if request.claimed == false then
        self.moveSettleCount = self.moveSettleCount + 1
        return
    end
    if final ~= false then
        self:releaseReserve(request.key)
    else
        local movedCount = math.max(0, tonumber(moved) or 0)
        local claimed = tonumber(request.reserved) or 0
        self:releaseReserve(request.key, math.max(0, claimed - movedCount))
    end
    self.moveSettleCount = self.moveSettleCount + 1
end
function Containers:releaseMoveKey(key, reason)
    local record = self.moveInflight and self.moveInflight[key]
    if not record then
        return false
    end
    self:settleMove(record, 0)
    self.moveInflight[key] = nil
    self.moveResults = self.moveResults or {}
    self.moveResults[key] = {
        moved = 0,
        err = tostring(reason or "move released"),
        at = os.epoch("utc"),
    }
    self.moveReleased = self.moveReleased + 1
    self.log.warn("move released (%s): %s#%s -> %s#%s", tostring(reason or "?"),
        tostring(record.from), tostring(record.fromIndex), tostring(record.to), tostring(record.toIndex))
    return true
end
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

function Containers:noteScanProtocolMismatch(peripheralName, detail)
    self.scanProtocolMismatch = self.scanProtocolMismatch + 1
    local seen = self.scanProtocolMismatchSeen
    if not seen then
        seen = {}
        self.scanProtocolMismatchSeen = seen
    end
    if not seen[peripheralName] and (self.scanProtocolMismatchLogged or 0) < 8 then
        seen[peripheralName] = true
        self.scanProtocolMismatchLogged = self.scanProtocolMismatchLogged + 1
        self.log("Scan result for %s has no usable 'scanned' field (%s): worker and master builds differ" ..
            " (copy the same build to every computer); result discarded",
            tostring(peripheralName), tostring(detail or "no scanned / scannedContainers"))
    end
    return self.scanProtocolMismatch
end
-- Snapshot updates are split by instruction: the master now issues one peripheral call
-- per task (items / size / one slot limit / tanks), so every reply is applied on its
-- own. applyScan() still composes them for the local (no-worker) path.
function Containers:beginScan(peripheralName, scanStartedAt, ts)
    local model = self:modelOf(peripheralName)
    if not model then
        self.scanUnknown = self.scanUnknown + 1
        return nil
    end
    if (model.scans or 0) == 0 then
        self.log("scan: %s had no snapshot yet; created one from this scan", tostring(peripheralName))
    end
    ts = tonumber(ts)
    if ts ~= nil then
        local prev = tonumber(model.scanTs)
        if prev ~= nil and ts < prev then
            self.scanStale = self.scanStale + 1
            return nil
        end
        model.scanTs = ts
    end
    local started = Assert.number(tonumber(scanStartedAt), "scan startedAt")
    model.scans = (model.scans or 0) + 1
    model.stamp = os.epoch("utc")
    model.gen = (model.gen or 0) + 1
    model.tick = self.tickCount or 0
    model.scanStartedAt = started
    if self:isFixedSlotCapacity(peripheralName) then
        -- A turtle's geometry is a constant: size it right away so no size() /
        -- getItemLimit() instruction is ever issued for it.
        self:applyFixedSlotCapacity(peripheralName)
    end
    return model
end

-- Scan results also arrive from workers (and turtle crafters), i.e. from another
-- computer and possibly another build. Invalid data must never raise here: the snapshot
-- is simply left incomplete (so the container stays unusable) and a clear log line says
-- why, instead of taking the master down.
function Containers:scanDataError(peripheralName, what)
    self.scanDataErrors = (self.scanDataErrors or 0) + 1
    self.log.error("scan result for %s is not usable: %s - snapshot left incomplete," ..
        " the container will be scanned again", tostring(peripheralName), tostring(what))
    return false
end

local function validCount(value)
    local number = tonumber(value)
    return number ~= nil and number >= 0 and number == math.floor(number) and number
end

function Containers:applyItems(peripheralName, items)
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    local slots = {}
    for _, entry in ipairs(items) do
        if type(entry) ~= "table" then
            return self:scanDataError(peripheralName, "item entry is a " .. type(entry))
        end
        local slot = tonumber(entry.slot)
        local itemName = entry.name
        local count = validCount(entry.count)
        if not slot or slot < 1 or slot ~= math.floor(slot) then
            return self:scanDataError(peripheralName, "item slot " .. tostring(entry.slot))
        end
        if type(itemName) ~= "string" or itemName == "" then
            return self:scanDataError(peripheralName, "item name " .. tostring(itemName))
        end
        if count == nil then
            return self:scanDataError(peripheralName, "count " .. tostring(entry.count) ..
                " of " .. itemName)
        end
        if entry.nbt ~= nil and type(entry.nbt) ~= "string" then
            return self:scanDataError(peripheralName, "nbt of " .. itemName)
        end
        slots[slot] = { name = itemName, count = count, nbt = entry.nbt }
        if #self.scanSeen < 512 then
            self.scanSeen[#self.scanSeen + 1] = { name = itemName, nbt = entry.nbt,
                container = peripheralName, slot = slot }
        end
    end
    -- Snapshot update (rule 5): remove the *previous* content of this container
    -- from the reverse index, write the new raw store, then add the new content
    -- back. The in-use ledger is never touched here.
    self:indexClearSlots(peripheralName)
    model.slots = slots
    for slot, entry in pairs(slots) do
        self:indexAddItem(peripheralName, slot, entry.name, entry.nbt)
    end
    model.info = model.info or {}
    -- `items` is the item-side completion flag (the fluid side has `tanks`); `list` is
    -- kept for older readers.
    model.info.items = true
    model.info.list = true
    model.info.at = os.epoch("utc")
    -- The item list is now known (a slot can finally be told empty from not-yet-read):
    -- a container that was only waiting for it may now be fully sized.
    noteSlotLimitKnown(self, peripheralName)
    return true
end

function Containers:applySize(peripheralName, size)
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    local slotTotal = tonumber(size)
    if not slotTotal or slotTotal <= 0 then
        -- The peripheral answered without a usable slot count: the container can never
        -- be sized, so its slot-capacity scan stays incomplete and storage compaction
        -- keeps waiting for it. Never fatal, but the operator must see why.
        self.log.error("%s: the peripheral did not report a usable slot count (size() -> %s) -" ..
            " the container stays unsized and its slot-capacity scan cannot complete",
            tostring(peripheralName), tostring(size))
        return false
    end
    if slotTotal > MAX_CONTAINER_SLOTS then
        -- Logged as an error (never fatal): a huge (but real) container must not take
        -- the master down, but its slot-capacity scan can never complete either.
        self.log.error("%s reported %d slots (above the %d soft limit) - trusting it anyway",
            tostring(peripheralName), slotTotal, MAX_CONTAINER_SLOTS)
    end
    model.size = math.floor(slotTotal)
    model.info = model.info or {}
    model.info.size = true
    if self:isFixedSlotCapacity(peripheralName) then
        -- A turtle needs no slot-capacity scan: its slots are a fixed 1x geometry.
        self:applyFixedSlotCapacity(peripheralName)
        return true
    end
    if not self:needsSlotScan(peripheralName) then
        -- No slot scan for this container (not a whitelisted mod, or a user-set
        -- default covers every slot): its multiplier is the override or 1x, so it is
        -- fully sized right away and never holds compaction/instances back.
        self:clearCapacityPending(peripheralName)
        return true
    end
    -- A newly known size means every slot's capacity has to be read: the container
    -- joins the pending list (and the limits are requested in bulk) until they all
    -- came back.
    self:markCapacityPending(peripheralName)
    requestAllSlotLimits(self, peripheralName)
    noteSlotLimitKnown(self, peripheralName)
    return true
end

function Containers:applySlotLimit(peripheralName, slot, limit, item)
    local model = self.model[peripheralName]
    if not model then
        return false
    end
    local slotNumber = tonumber(slot)
    if not slotNumber or slotNumber < 1 or slotNumber ~= math.floor(slotNumber) then
        return self:scanDataError(peripheralName, "slot limit for slot " .. tostring(slot))
    end
    local value = tonumber(limit)
    if not value or value <= 0 then
        return self:scanDataError(peripheralName, "slot limit " .. tostring(limit) ..
            " of slot " .. tostring(slotNumber))
    end
    slot = slotNumber
    -- Remember which item the value was read for (diagnostics only): the slot multiplier
    -- is computed once from the limit and that item's stack size and then cached on the
    -- entry (slotStacksOf), so a later content change does not change it.
    local itemKey = nil
    local inSlot = model.slots and model.slots[slot]
    if type(item) == "table" and type(item.name) == "string" then
        itemKey = tostring(item.name) .. "\0" .. tostring(item.nbt or "")
    elseif type(inSlot) == "table" and type(inSlot.name) == "string" then
        itemKey = tostring(inSlot.name) .. "\0" .. tostring(inSlot.nbt or "")
    end
    local wasKnown = model.slotLimits and model.slotLimits[slot] ~= nil
    model.slotLimits = model.slotLimits or {}
    model.slotLimits[slot] = { limit = math.floor(value), item = itemKey }
    if not wasKnown then
        model.limitKnown = (tonumber(model.limitKnown) or 0) + 1
    end
    if model.limitFailed then
        model.limitFailed[slot] = nil
    end
    self:clearPendingLimit(peripheralName, slot)
    noteSlotLimitKnown(self, peripheralName)
    return true
end

function Containers:applyTanks(peripheralName, tanks)
    -- The fluid reply may be the very first thing the master ever hears about this
    -- peripheral (a fluid storage added while the master runs): create the model here
    -- instead of silently dropping the tanks (the item path builds it in beginScan,
    -- which the fluid reply path did not go through).
    local model = self:modelOf(peripheralName)
    if not model then
        return false
    end
    local tanksOut = {}
    for _, entry in ipairs(tanks) do
        if type(entry) ~= "table" then
            return self:scanDataError(peripheralName, "tank entry is a " .. type(entry))
        end
        local tank = tonumber(entry.tank)
        local fluidName = entry.name
        local amount = validCount(entry.amount)
        if not tank or tank < 1 or tank ~= math.floor(tank) then
            return self:scanDataError(peripheralName, "tank index " .. tostring(entry.tank))
        end
        if type(fluidName) ~= "string" or fluidName == "" then
            return self:scanDataError(peripheralName, "fluid name " .. tostring(fluidName))
        end
        if amount == nil then
            return self:scanDataError(peripheralName, "amount " .. tostring(entry.amount) ..
                " of " .. fluidName)
        end
        tanksOut[tank] = { name = fluidName, amount = amount }
    end
    self:indexClearTanks(peripheralName)
    model.tanks = tanksOut
    for _, entry in pairs(tanksOut) do
        self:indexAddFluid(peripheralName, entry.name)
    end
    model.info = model.info or {}
    -- `tanks` is the fluid-side completion flag. `list` is NOT set here: that flag
    -- belongs to the item side, and a dual peripheral would otherwise look item-ready
    -- after a fluid scan.
    model.info.tanks = true
    model.info.at = os.epoch("utc")
    return true
end

function Containers:applyScan(peripheralName, items, tanks, scanStartedAt, size, ts, slotLimits)
    local model = self:beginScan(peripheralName, scanStartedAt, ts)
    if not model then
        return false
    end
    if items ~= nil then
        self:applyItems(peripheralName, items)
    end
    if size ~= nil then
        self:applySize(peripheralName, size)
    end
    if slotLimits ~= nil then
        for slot, limit in pairs(slotLimits) do
            self:applySlotLimit(peripheralName, slot, limit)
        end
    end
    if tanks ~= nil then
        self:applyTanks(peripheralName, tanks)
    end
    return true
end

function Containers:snapshotSummary()
    local inUseSlots, inUseFluids = 0, 0
    local containersInUse = 0
    for _, use in pairs(self.inUse) do
        local has = false
        for _ in pairs(use.slots or {}) do
            inUseSlots = inUseSlots + 1
            has = true
        end
        for _ in pairs(use.fluids or {}) do
            inUseFluids = inUseFluids + 1
            has = true
        end
        if has then
            containersInUse = containersInUse + 1
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
        inUseSlots = inUseSlots,
        inUseItems = inUseSlots,
        inUseFluids = inUseFluids,
        inUseContainers = containersInUse,

        scanProtocolMismatch = self.scanProtocolMismatch,
        scanDuplicate = self.scanDuplicate or 0,
        claims = self:claimsSummary(),
        settles = self.moveSettleCount,
        settled = self.moveSettleCount,
        inflight = count(self.moveInflight),
        results = count(self.moveResults),
        models = count(self.model),
        detailDeferred = self.detailDeferred,
    }
end

function Containers:takeScanSeen()
    local seen = self.scanSeen
    self.scanSeen = {}
    return seen
end
-- (The master used to read a peripheral itself here via Containers:scanNow; that
-- local instruction path was removed - every scan now runs on a remote worker.)
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
                count = stack.count,
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
        out[#out + 1] = { tank = Assert.positive(tank, "snapshot tank index"), name = entry.name,
        amount = entry.amount }
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
    local target = queueName or "inventoryOut"
    if target == "manual" then
        -- The manual queue's own element issues this instruction itself: it is not
        -- handed to inventoryIn/inventoryOut, so one element = one instruction = one
        -- load (the manual element would otherwise spend no load at all).
        self.moveEnqueued = self.moveEnqueued + 1
        self:executeMove(record)
        return
    end
    if self.dispatch and self.dispatch.enqueue then
        if self.dispatch:enqueue(target, record) then
            self.moveEnqueued = self.moveEnqueued + 1
            return
        end
        self.moveEnqueueRejected = self.moveEnqueueRejected + 1
        -- A rejected move must not linger: release its reservation, forget it and
        -- publish an immediate failure so the caller can move on.
        self:settleMove(record, 0)
        self.moveInflight[record.key] = nil
        self.moveResults = self.moveResults or {}
        self.moveResults[record.key] = {
            moved = 0,
            err = "move rejected by queue " .. tostring(target),
            at = os.epoch("utc"),
        }
        self.log.error("move-enqueue REJECTED by queue %s (key=%s): released and dropped",
        tostring(target), tostring(record.key))
        return
    end
    self.moveEnqueueLocal = self.moveEnqueueLocal + 1
    self:executeMove(record)
end

function Containers:sourceShortage(record)
    local model = self:modelOf(record.from)
    if not model then
        return true
    end
    if record.kind == "fluid" then
        return self:visibleTankAmount(model, record.fromIndex) <= 0
    end
    return self:visibleSlotCount(model, record.fromIndex) <= 0
end

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
    -- Terminal mark: a queue runner must be able to tell a settled move from one that
    -- is still out at an executor (see the move runners in IFMMaster).
    record.state = "settled"
    return true
end

function Containers:executeMove(record)
    if type(record) ~= "table" or not record.key then
        return "drop"
    end
    if self.moveInflight[record.key] ~= record then
        -- Not the registered move any more: it was settled by settleMove()/abandonMove()/
        -- releaseMoveKey(). Report it as finished and clear the stale "inflight" mark, so
        -- a queue runner never mistakes a settled move for one still out at an executor.
        record.state = "settled"
        return false
    end
    local moved, err = self:runMoveTask(record)
    if err == "pending" then
        record.state = "inflight"
        return true
    end
    local value = tonumber(moved) or 0
    local wanted = tonumber(record.reserved) or 0
    if value >= wanted then
        self:settleMove(record, value, true)
        self.moveInflight[record.key] = nil
        self.dirty[record.from] = true
        self.dirty[record.to] = true
        self:noteMoveResult(record, value, err)
        record.state = "settled"
        return false
    end

    -- Not finished: keep the slot marks, only shrink the claims by what moved.
    self:settleMove(record, value, false)
    record.reserved = math.max(0, wanted - value)
    self.dirty[record.from] = true
    self.dirty[record.to] = true
    self:noteMoveResult(record, value, err)

    -- What is still reserved for this move, per the transfer result alone.
    local remaining = tonumber(record.reserved) or 0

    -- The snapshot is consulted for ONE thing only: noticing that somebody outside
    -- changed the container while this move was running. Two signs, both fail this move:
    --   * the source slot no longer holds the kind this move reserved (a swap), or
    --   * with every other actor's claim discounted, less than `remaining` is left.
    -- The plan was built on that reservation, so it is stale - which is why
    -- compactMoveRunner rebuilds the compact queue from a fresh snapshot.
    local sourceModel = self.model[record.from]
    local sourceEntry = sourceModel and sourceModel.slots and sourceModel.slots[record.fromIndex]
    local swapped = record.kind ~= "fluid" and type(sourceEntry) == "table"
        and sourceEntry.name ~= nil
        and (sourceEntry.name ~= record.item
            or tostring(sourceEntry.nbt or "") ~= tostring(record.nbt or ""))
    local available = self:sourceFreeFor(record)
    if remaining > 0 and (swapped or available < remaining) then
        self:settleMove(record, 0, true)
        self.moveInflight[record.key] = nil
        record.failReason = "source changed outside"
        self.log.warn("Move failed (source changed outside: %d of %d reserved left, slot holds %s)" ..
            " (%s -> %s)", available, remaining,
            swapped and tostring(sourceEntry.name) or tostring(record.item),
            tostring(record.from), tostring(record.to))
        record.state = "settled"
        return "drop"
    end

    if value <= 0 then
        -- Not a single item moved (target full, or the peripheral rate-limits and did
        -- not answer): the action failed. Anything above zero is progress and retried.
        self:settleMove(record, 0, true)
        self.moveInflight[record.key] = nil
        record.failReason = "nothing moved"
        self.log.warn("Move failed (nothing moved) (%s -> %s): %s", tostring(record.from),
            tostring(record.to), self.Message.describe(err or "target busy"))
        record.state = "settled"
        return "drop"
    end

    if remaining <= 0 then
        self.moveInflight[record.key] = nil
        record.state = "settled"
        return false
    end

    -- Partial progress and the source still holds the rest: retry the remainder. The
    -- retry amount is the transfer's own remainder - never trimmed by an observation.
    record.retries = (record.retries or 0) + 1
    record.state = "queued"
    self.moveInflight[record.key] = record
    self.log("Move retry %d/%d (%s -> %s, moved=%d): %s", remaining, wanted,
        tostring(record.from), tostring(record.to), value, self.Message.describe(err or "target busy"))
    return true
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
function Containers:pushItemImpl(fromContainer, fromSlot, limit, toContainer, toSlot, mode, queueName, sourceItem)
    local fromPeripheral = self:peripheralOf(fromContainer, "item")
    local toPeripheral = self:peripheralOf(toContainer, "item")
    if not fromPeripheral then
        return 0, self:unusableReason(fromContainer, "item")
            or self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_UNUSABLE, { name = tostring(fromContainer) })
    end
    if not toPeripheral then
        return 0, self:unusableReason(toContainer, "item")
            or self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_UNUSABLE, { name = tostring(toContainer) })
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_COUNT)
    end

    local snapshot = self:hasSnapshot(fromPeripheral)
    if not snapshot then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_NO_SNAPSHOT)
    end
    local resolvedSlot = tonumber(fromSlot)
    local source = nil
    if resolvedSlot and resolvedSlot >= 1 then
        source = self:stackAt(fromContainer, resolvedSlot)
    else
        resolvedSlot, source = self:slotForItem(fromPeripheral, sourceItem)
    end
    if not resolvedSlot then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SNAPSHOT_NO_ITEM)
    end
    local explicitSlot = (tonumber(toSlot) or -1) >= 1 and tonumber(toSlot) or nil
    if not explicitSlot and fromPeripheral == toPeripheral then
        return 0, "source and target are the same peripheral: an explicit target slot (toSlot) is required"
    end

    local autoSlot = nil
    if not explicitSlot and fromPeripheral ~= toPeripheral then
        local itemName = source and source.name or (type(sourceItem) == "table" and sourceItem.name) or nil
        local itemNbt = source and source.nbt or (type(sourceItem) == "table" and sourceItem.nbt) or nil
        if itemName then
            autoSlot = self:insertSlotFor(toContainer, itemName, itemNbt, limit, mode or self.INSERT_SPEED)
        end
    end
    local chosenSlot = explicitSlot or autoSlot

    if not chosenSlot then
        if not self:hasSnapshot(toPeripheral) then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_NO_SNAPSHOT)
        end
        local why = self.lastInsertFailure
        if why and why.container == toContainer and why.snapshot then
            if (why.dirty or 0) == 0 and (why.full or 0) == 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_FULL)
            end
            if (why.dirty or 0) > 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_SLOTS_CLAIMED)
            end
        end
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_NO_SLOT)
    end
    local wantsSlot = chosenSlot ~= resolvedSlot
    if fromPeripheral == toPeripheral and not wantsSlot then
        return 0, samePeripheralReason(self.Message, fromContainer, toContainer, fromPeripheral)
    end
    local key = table.concat({ "item", fromPeripheral, tostring(resolvedSlot), tostring(limit),
        toPeripheral, tostring(chosenSlot) }, "|")

    local result = self:takeMoveResult(key)
    if result then
        return result.moved, result.err
    end
    if self.moveInflight[key] then
        return nil, "pending"
    end

    if not source or (tonumber(source.count) or 0) <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SNAPSHOT_NO_ITEM)
    end
    if type(sourceItem) == "table" and type(sourceItem.name) == "string" and sourceItem.name ~= "" then
        local wantNbt = tostring(sourceItem.nbt or "")
        if source.name ~= sourceItem.name or tostring(source.nbt or "") ~= wantNbt then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_ITEM_MISMATCH, {
            snapshot = tostring(source.name),
            wanted = tostring(sourceItem.name),
        })
        end
    end

    local visible = tonumber(source.count) or 0
    -- pushItem never claims: only takeItem / sendItem / manageItem write the dirty marks.
    local reserved = math.min(limit, visible)
    if reserved <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_EMPTY_SLOT)
    end
    local record = {
        key = key, kind = "item", action = "push_item",
        from = fromPeripheral, fromIndex = resolvedSlot, to = toPeripheral, toIndex = chosenSlot,
        reserved = reserved, limit = limit, mode = mode, claimed = false,

        actor = self:moveActorOf(fromPeripheral, "item"),
        item = source.name, nbt = source.nbt,
    }
    self:submitMove(record, queueName)
    return nil, "pending"
end
-- Debug logging is never throttled: every call goes out as-is.
local function debugLog(self, fmt, ...)
    if not self.debug then
        return
    end
    self.log("[debug] " .. string.format(fmt, ...))
end
function Containers:setTickSeq(seq)
    self.tickSeq = tonumber(seq) or 0
end
function Containers:tickOf()
    return tonumber(self.tickSeq) or 0
end
local MOVE_ROLE_SOURCE = {
send = { storage = true },
take = { input = true, interaction = true },
manage = { storage = true },
}
local MOVE_ROLE_TARGET = {
send = { output = true, interaction = true },
take = { storage = true },
manage = { storage = true },
}
local function roleOfDef(self, containerName, kind)
    local role = self:defRole(containerName, kind)
    return role or "storage"
end
-- Business failures are *returned* (nil, <Message>), never raised: the scheduler no
-- longer catches exceptions, so a raised error would kill the master. Only real bugs
-- (Assert violations, nil indexing) keep raising.
local function requireModel(self, peripheralName, what)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_PERIPHERAL_NAME_INVALID, { what = what })
    end
    local model = self.model[peripheralName]
    if not model then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_SNAPSHOT, { what = what })
    end
    return model
end
local function assertItemSource(self, peripheralName, slot, item, count)
    local model, why = requireModel(self, peripheralName,
        self.Message.msg(self.Message.KEYS.CONT_LABEL_SOURCE))
    if not model then
        return nil, why
    end
    if not slot or slot < 1 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SLOT_INVALID)
    end
    if not self:slotMultiplierReady(peripheralName, slot) then
        -- The slot's capacity multiplier is still being read: no item I/O on it yet.
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCANNING,
            { name = tostring(peripheralName), peripheral = tostring(peripheralName) })
    end
    -- A slot is not exclusive: several consumers may move out of it at the same time
    -- (instances of processes sharing one machine, an extraction next to a compact
    -- move, ...). Only the amount is reserved - `inUse` below sums the amounts that are
    -- already on their way out and `count` has to fit what is left of the snapshot, so
    -- the same piece of a stack can never be handed out twice.
    local entry = model.slots[slot]
    if not entry or not entry.name then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SLOT_EMPTY,
            { peripheral = peripheralName, slot = slot })
    end
    if entry.name ~= item.name or tostring(entry.nbt or "") ~= tostring(item.nbt or "") then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SLOT_ITEM_MISMATCH, {
            peripheral = peripheralName,
            slot = slot,
            found = tostring(entry.name),
            foundNbt = tostring(entry.nbt),
            wanted = tostring(item.name),
            wantedNbt = tostring(item.nbt),
        })
    end
    local inUse = self:itemMoveUse(peripheralName, slot)
    local snapshot = tonumber(entry.count) or 0
    if inUse > snapshot then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_DIRTY_EXCEEDS, {
            peripheral = peripheralName,
            slot = slot,
            dirty = inUse,
            snapshot = snapshot,
        })
    end
    local available = snapshot - inUse
    if count > available then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_NOT_ENOUGH_SAFE, {
            count = count,
            peripheral = peripheralName,
            slot = slot,
            available = available,
            snapshot = snapshot,
            dirty = inUse,
        })
    end
    return model
end
local function assertFluidSource(self, peripheralName, fluidName, count)
    local model, why = requireModel(self, peripheralName,
        self.Message.msg(self.Message.KEYS.CONT_LABEL_SOURCE))
    if not model then
        return nil, why
    end
    if type(fluidName) ~= "string" or fluidName == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_FLUID_NAME_INVALID)
    end
    local available = 0
    for _, entry in pairs(model.tanks) do
        if entry.name == fluidName then
            available = available + (tonumber(entry.amount) or 0)
        end
    end
    available = math.max(0, available - self:fluidMoveUse(peripheralName, fluidName))
    if count > available then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_FLUID_NOT_ENOUGH, {
            count = count,
            peripheral = peripheralName,
            fluid = fluidName,
            available = available,
        })
    end
    return model
end
local function queueNameForAction(action)
    if action == "send" then
        return "inventoryOut"
    end
    if action == "take" then
        return "inventoryIn"
    end
    return "compact"
end
function Containers:queueItemMove(action, fromContainer, fromSlot, toContainer, toSlot, item, count,
    queueName)
    if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ITEM_SPEC)
    end
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_COUNT)
    end
    local fromPeripheral = self:peripheralOf(fromContainer, "item")
    local toPeripheral = self:peripheralOf(toContainer, "item")
    if not fromPeripheral then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_CONTAINER_UNAVAILABLE,
            { name = tostring(fromContainer) })
    end
    if not toPeripheral then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_CONTAINER_UNAVAILABLE,
            { name = tostring(toContainer) })
    end
    local fromRole = roleOfDef(self, fromContainer, "item")
    local toRole = roleOfDef(self, toContainer, "item")
    if not (MOVE_ROLE_SOURCE[action] or {})[fromRole] then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ROLE_SOURCE,
            { name = tostring(fromContainer), role = fromRole, action = action })
    end
    if not (MOVE_ROLE_TARGET[action] or {})[toRole] then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ROLE_TARGET,
            { name = tostring(toContainer), role = toRole, action = action })
    end
    local fromModel, why = assertItemSource(self, fromPeripheral, fromSlot, item, count)
    if not fromModel then
        return nil, why
    end
    local toModel = nil
    if toSlot then
        toSlot = math.floor(tonumber(toSlot) or 0)
        if toSlot < 1 then
            return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_SLOT_INVALID)
        end
        toModel, why = requireModel(self, toPeripheral, self.Message.msg(self.Message.KEYS.CONT_LABEL_TARGET))
        if not toModel then
            return nil, why
        end
        if not self:slotMultiplierReady(toPeripheral, toSlot) then
            -- The target slot's capacity multiplier is still being read: no item I/O yet.
            return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCANNING,
                { name = tostring(toPeripheral), peripheral = tostring(toPeripheral) })
        end
        if self:itemUseTotal(toPeripheral, toSlot) > 0 then
            return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_SLOT_CLAIMED,
                { peripheral = toPeripheral, slot = toSlot })
        end
    else
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_SLOT_REQUIRED)
    end
    local ts = self:tickOf()
    -- The sequence number keeps the key unique: a slot may carry several moves now (see
    -- assertItemSource), so two of them can agree in every other field - same tick, same
    -- endpoints, same amount - and a collision would drop the older move from moveInflight
    -- while its reservation is still open.
    self.moveSeq = (tonumber(self.moveSeq) or 0) + 1
    local key = table.concat({ "move", action, fromPeripheral, tostring(fromSlot), toPeripheral,
    tostring(toSlot or -1), tostring(count), tostring(ts), tostring(self.moveSeq) }, "|")
    -- One source: the move key. It is pinned on the source position (material is
    -- leaving) and on the target position (the slot is taken, nothing else may be
    -- placed there) and released whole by settleMove()/releaseMoveKey().
    self:reserve(key, "item", fromPeripheral, fromSlot, item.name, item.nbt, count, "out")
    self:reserve(key, "item", toPeripheral, toSlot, item.name, item.nbt, count, "in")
    local record = {
    key = key,
    kind = "item",
    action = "move_item",
    moveAction = action,
    from = fromPeripheral,
    fromIndex = fromSlot,
    to = toPeripheral,
    toIndex = toSlot,
    reserved = count,
    item = item.name,
    nbt = item.nbt,
    actor = self:moveActorOf(fromPeripheral, "item"),
    ts = ts,
}
    self.moveInflight = self.moveInflight or {}
    self.moveInflight[key] = record
    self:submitMove(record, queueName or queueNameForAction(action))
    debugLog(self,
    "move %s %s#%s(x%s) -> %s#%s(x%s) %s(nbt=%s) x%d ts=%d", action, fromPeripheral, tostring(fromSlot),
    tostring(self:slotMultiplierOf(fromPeripheral, fromSlot)), toPeripheral, tostring(toSlot),
    tostring(self:slotMultiplierOf(toPeripheral, toSlot)), tostring(item.name), tostring(item.nbt), count, ts)
    return key
end
function Containers:sendItem(storageContainer, storageSlot, targetContainer, targetSlot, item, count,
    queueName)
    return self:queueItemMove("send", storageContainer, storageSlot, targetContainer, targetSlot, item, count,
        queueName)
end
function Containers:takeItem(sourceContainer, sourceSlot, storageContainer, storageSlot, item, count,
    queueName)
    return self:queueItemMove("take", sourceContainer, sourceSlot, storageContainer, storageSlot, item, count,
        queueName)
end
function Containers:manageItem(fromContainer, fromSlot, toContainer, toSlot, item, count, queueName)
    return self:queueItemMove("manage", fromContainer, fromSlot, toContainer, toSlot, item, count, queueName)
end
function Containers:queueFluidMove(action, fromContainer, toContainer, fluidName, count, queueName)
    count = math.floor(tonumber(count) or 0)
    if count <= 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_COUNT)
    end
    if type(fluidName) ~= "string" or fluidName == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_FLUID_NAME_INVALID)
    end
    local fromPeripheral = self:peripheralOf(fromContainer, "fluid")
    local toPeripheral = self:peripheralOf(toContainer, "fluid")
    if not fromPeripheral then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_CONTAINER_UNAVAILABLE,
            { name = tostring(fromContainer) })
    end
    if not toPeripheral then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_CONTAINER_UNAVAILABLE,
            { name = tostring(toContainer) })
    end
    local fromRole = roleOfDef(self, fromContainer, "fluid")
    local toRole = roleOfDef(self, toContainer, "fluid")
    if not (MOVE_ROLE_SOURCE[action] or {})[fromRole] then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ROLE_SOURCE,
            { name = tostring(fromContainer), role = fromRole, action = action })
    end
    if not (MOVE_ROLE_TARGET[action] or {})[toRole] then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ROLE_TARGET,
            { name = tostring(toContainer), role = toRole, action = action })
    end
    local fromModel, why = assertFluidSource(self, fromPeripheral, fluidName, count)
    if not fromModel then
        return nil, why
    end
    local ts = self:tickOf()
    local key = table.concat({ "movefluid", action, fromPeripheral, toPeripheral, fluidName,
    tostring(count), tostring(ts) }, "|")
    -- Fluids are tracked per container (not per tank): the source container is
    -- leaving, the target container is receiving.
    self:reserve(key, "fluid", fromPeripheral, nil, fluidName, nil, count, "out")
    self:reserve(key, "fluid", toPeripheral, nil, fluidName, nil, count, "in")
    local record = {
    key = key,
    kind = "fluid",
    action = "move_fluid",
    moveAction = action,
    from = fromPeripheral,
    fromIndex = nil,
    to = toPeripheral,
    toIndex = nil,
    reserved = count,
    item = fluidName,
    actor = self:moveActorOf(fromPeripheral, "fluid"),
    targetTankUnknown = true,
    claimed = true,
    ts = ts,
}
    self.moveInflight = self.moveInflight or {}
    self.moveInflight[key] = record
    self:submitMove(record, queueName or queueNameForAction(action))
    debugLog(self,
    "move %s %s -> %s %s x%d mB ts=%d", action, fromPeripheral, toPeripheral, fluidName, count, ts)
    return key
end
function Containers:sendFluid(storageContainer, targetContainer, fluidName, count, queueName)
    return self:queueFluidMove("send", storageContainer, targetContainer, fluidName, count, queueName)
end
function Containers:takeFluid(sourceContainer, storageContainer, fluidName, count, queueName)
    return self:queueFluidMove("take", sourceContainer, storageContainer, fluidName, count, queueName)
end
function Containers:manageFluid(fromContainer, toContainer, fluidName, count, queueName)
    return self:queueFluidMove("manage", fromContainer, toContainer, fluidName, count, queueName)
end
-- Every slot of this container that holds `item` and can give some of it away, best
-- first (the order Containers:pickSourceSlot picks from). The unordered-IO extraction
-- uses the whole list to submit one move per slot instead of one move per tick.
function Containers:pickSourceSlots(containerName, item, prefer)
    if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ITEM_SPEC_SHORT)
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_UNAVAILABLE, { name = tostring(containerName) })
    end
    local model = self.model[peripheralName]
    if not model then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_NO_SNAPSHOT)
    end
    local out = {}
    for slot, entry in pairs(model.slots) do
        if entry.name == item.name and tostring(entry.nbt or "") == tostring(item.nbt or "")
            and self:slotMultiplierReady(peripheralName, slot) then
            local inUse = self:itemMoveUse(peripheralName, slot)
            local available = math.max(0, (tonumber(entry.count) or 0) - inUse)
            if available > 0 then
                out[#out + 1] = { slot = slot, available = available }
            end
        end
    end
    if #out == 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_ITEM_AVAILABLE, {
            container = tostring(containerName),
            item = tostring(item.name),
        })
    end
    local fragment = prefer == Containers.ORDER_FRAGMENT
    table.sort(out, function(a, b)
        if a.available ~= b.available then
            if fragment then
                return a.available < b.available
            end
            return a.available > b.available
        end
        return a.slot < b.slot
    end)
    return out
end

function Containers:pickSourceSlot(containerName, item, prefer)
    local slots, why = self:pickSourceSlots(containerName, item, prefer)
    if not slots then
        return nil, why
    end
    return slots[1].slot, nil, slots[1].available
end
-- How much of `item` can be moved out of this slot right now: the snapshot count
-- minus everything already on its way out. Read-only helper for callers that have
-- to size a move before submitting it; queueItemMove/assertItemSource keeps its
-- own check, so this only avoids requests that would be rejected anyway.
function Containers:safeTakeAmount(containerName, slot, item)
    if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
        return 0
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return 0
    end
    local model = self.model[peripheralName]
    if not model then
        return 0
    end
    slot = math.floor(tonumber(slot) or 0)
    if slot < 1 then
        return 0
    end
    local entry = model.slots[slot]
    if not entry or not entry.name then
        return 0
    end
    if entry.name ~= item.name or tostring(entry.nbt or "") ~= tostring(item.nbt or "") then
        return 0
    end
    if not self:slotMultiplierReady(peripheralName, slot) then
        return 0
    end
    local inUse = self:itemMoveUse(peripheralName, slot)
    return math.max(0, (tonumber(entry.count) or 0) - inUse)
end
function Containers:fluidAvailable(containerName, fluidName)
    local peripheralName = self:peripheralOf(containerName, "fluid")
    if not peripheralName then
        return 0
    end
    local model = self.model[peripheralName]
    if not model then
        return 0
    end
    local total = 0
    for _, entry in pairs(model.tanks) do
        if entry.name == fluidName then
            total = total + (tonumber(entry.amount) or 0)
        end
    end
    return math.max(0, total - self:fluidMoveUse(peripheralName, fluidName))
end
function Containers:pickTargetSlot(containerName, item, count, prefer)
    if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ITEM_SPEC_SHORT)
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_UNAVAILABLE, { name = tostring(containerName) })
    end
    local model = self.model[peripheralName]
    if not model then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_NO_SNAPSHOT)
    end
    local size = self:slotCount(peripheralName)
    if not size or size <= 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCANNING,
            { name = tostring(containerName), peripheral = tostring(peripheralName) })
    end
    count = math.max(1, math.floor(tonumber(count) or 1))
    local capacity = self:itemMaxCount(item.name, item.nbt)
    if not capacity then
        return nil, string.format("stack size of %s is not scanned yet (no getItemDetail result)",
        tostring(item.name))
    end
    local slot = self:insertSlotFor(containerName, item.name, item.nbt, count, Containers.INSERT_LEAST)
    if slot then
        return slot, nil, self:itemMaxCount(item.name, item.nbt)
    end
    local dirty, occupied = 0, 0
    for slot = 1, size do
        if self:itemUseTotal(peripheralName, slot) > 0 then
            dirty = dirty + 1
        elseif model.slots[slot] then
            occupied = occupied + 1
        end
    end
    if dirty > 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ALL_SLOTS_CLAIMED, {
            container = tostring(containerName),
            dirty = dirty,
            size = size,
        })
    end
    -- Not "full": the slots are simply not sized yet (the slot limit or the item's stack
    -- size is still being read), so the master reports "scanning" instead of a lie.
    local last = self.lastInsertFailure
    if last and last.container == containerName and (last.unknown or 0) > 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCANNING,
            { name = tostring(containerName), peripheral = tostring(peripheralName) })
    end
    return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_FULL, {
        container = tostring(containerName),
        occupied = occupied,
        item = tostring(item.name),
    })
end
-- Every slot of one container that can still take some of `item` right now: empty
-- slots sized by their slot multiplier, plus same-item slots with free room. Busy
-- slots (an in-flight move or a claim already holds them) are skipped, so a caller
-- can send several parallel moves to distinct slots at once. Biggest room first.
function Containers:pickTargetSlots(containerName, item)
    if type(item) ~= "table" or type(item.name) ~= "string" or item.name == "" then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_ITEM_SPEC_SHORT)
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_UNAVAILABLE, { name = tostring(containerName) })
    end
    if not self:hasSnapshot(peripheralName) then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_CONTAINER_NO_SNAPSHOT)
    end
    local size = self:slotCount(peripheralName)
    if not size or size <= 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCANNING,
            { name = tostring(containerName), peripheral = tostring(peripheralName) })
    end
    local itemMax = self:itemMaxCount(item.name, item.nbt)
    if not itemMax then
        return nil, string.format("stack size of %s is not scanned yet (no getItemDetail result)",
        tostring(item.name))
    end
    local slots = self:stacksPeripheral(peripheralName)
    local bySlot = {}
    for _, entry in ipairs(slots or {}) do
        local index = tonumber(entry and entry.slot)
        if index then
            bySlot[index] = entry
        end
    end
    local out = {}
    for slot = 1, size do
        if not self:slotBusy(peripheralName, slot) then
            local stack = bySlot[slot]
            local free
            if stack == nil then
                free = self:slotCapacityFor(peripheralName, slot, item.name, item.nbt)
            elseif tostring(stack.name) == tostring(item.name)
                and tostring(stack.nbt or "") == tostring(item.nbt or "") then
                local capacity = self:slotCapacityFor(peripheralName, slot, item.name, item.nbt)
                free = capacity and math.max(0, capacity - (tonumber(stack.count) or 0)) or nil
            end
            if free and free > 0 then
                out[#out + 1] = { slot = slot, free = free }
            end
        end
    end
    if #out == 0 then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_FULL, {
            container = tostring(containerName),
            occupied = size,
            item = tostring(item.name),
        })
    end
    table.sort(out, function(a, b)
        if a.free ~= b.free then
            return a.free > b.free
        end
        return a.slot < b.slot
    end)
    return out
end

function Containers:beginScanTick()
    self.scannedThisTick = {}
end
function Containers:scanItem(containerName, ts, part, slot)
    return self:scanContainer(containerName, "item", ts, part, slot)
end
function Containers:scanFluid(containerName, ts, part, slot)
    return self:scanContainer(containerName, "fluid", ts, part, slot)
end
function Containers:scanSlotLimit(containerName, slot, ts)
    return self:scanContainer(containerName, "item", ts, "limit", slot)
end
local function callerOf(level)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        return "?"
    end
    local info = debug.getinfo((level or 1) + 1, "Sl")
    if type(info) ~= "table" then
        return "?"
    end
    return tostring(info.short_src or "?") .. ":" .. tostring(info.currentline or 0)
end

function Containers:scanContainer(containerName, kind, ts, part, slot)
    local peripheralName = tostring(containerName or "")
    if peripheralName == "" or not self.Peripherals:exists(peripheralName) then
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCAN_UNAVAILABLE,
            { container = tostring(containerName), kind = tostring(kind) })
    end
    part = type(part) == "string" and part ~= "" and part or "items"
    slot = tonumber(slot)
    local seen = self.scannedThisTick
    if not seen then
        seen = {}
        self.scannedThisTick = seen
    end
    local key = tostring(kind) .. "|" .. peripheralName .. "|" .. part ..
        (slot and (":" .. tostring(slot)) or "")
    if seen[key] then
        self.scanDuplicate = (self.scanDuplicate or 0) + 1
        self.log.error("duplicate %s/%s scan of %s inside one tick (#%d) - caller: %s",
            tostring(kind), part, peripheralName, self.scanDuplicate, callerOf(2))
        return nil, self.Message.msg(self.Message.KEYS.CONT_ERR_SCAN_TWICE, {
            container = peripheralName,
            kind = tostring(kind),
        })
    end
    seen[key] = true
    ts = tonumber(ts) or self:tickOf()
    local transfer = self.transfer
    if transfer and transfer.submitPart then
        local status = transfer:submitPart(peripheralName, kind, part, slot, ts, key)
        if status == "pending" then
            self.scanRequested = self.scanRequested + 1
            return "sent"
        end
        if status == "done" then
            -- Answered from the cache: nothing to wait for, the callback already ran.
            return true
        end
    end
    -- No worker took the instruction: defer it and retry next round. The master no
    -- longer reads a peripheral itself, so there is no local fallback.
    self.scanDeferred = self.scanDeferred + 1
    return "deferred"
end
function Containers:pushItem(fromContainer, fromSlot, limit, toContainer, toSlot, mode, queueName, sourceItem)
    local moved, reason = self:pushItemImpl(fromContainer, fromSlot, limit, toContainer, toSlot, mode, queueName,
    sourceItem)
    if reason and reason ~= "pending" then
        debugLog(self,
        "pushItem %s#%s -> %s#%s limit=%s item=%s nbt=%s : %s",
        tostring(fromContainer), tostring(fromSlot), tostring(toContainer), tostring(toSlot),
        tostring(limit), tostring(type(sourceItem) == "table" and sourceItem.name or nil),
        tostring(type(sourceItem) == "table" and sourceItem.nbt or nil), tostring(reason))
    end
    return moved, reason
end
function Containers:runItemMove(record)
    local fromPeripheral = record.from
    local toPeripheral = record.to
    local fromSlot = tonumber(record.fromIndex)
    local limit = record.reserved
    local chosenSlot = tonumber(record.toIndex)
    if not fromSlot or fromSlot < 1 then
        return 0, "item move rejected: no explicit source slot (fromSlot); the master must pick it"
    end
    if not chosenSlot or chosenSlot < 1 then
        return 0, "item move rejected: no explicit target slot (toSlot); the master must pick it"
    end
    if self.transfer then
        local state, moved, err = self.transfer:request({
            action = "push_item",
            from = fromPeripheral,
            fromSlot = fromSlot,
            limit = limit,
            to = toPeripheral,
            toSlot = chosenSlot,
            actor = record.actor,
            moveKey = record.key,
            item = record.item,
            nbt = record.nbt,
        })
        if state == "pending" then
            return nil, "pending"
        end
        return moved, err
    end
    return 0, "item move failed: the transfer module is unavailable (no IFMWorker executor)"
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
        return nil
    end
    local known = self.itemMaxCountCache and self.itemMaxCountCache[itemName]
    if known then
        return known
    end
    local detail, cached = self:cachedItemDetail(itemName, nbt)
    if not cached or detail == nil then
        return nil
    end
    local value = tonumber(detail.maxCount)
    if not value or value <= 0 then
        return nil
        end
        self.itemMaxCountCache = self.itemMaxCountCache or {}
        if not self.itemMaxCountCache[itemName] then
            self.stackLimitKnown = self.stackLimitKnown + 1
        end
        self.itemMaxCountCache[itemName] = value
        return value
    end
function Containers:insertSlotFor(containerName, itemName, nbt, amount, mode)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return nil
    end
    if not self:hasSnapshot(peripheralName) then
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

        return not self:slotBusy(peripheralName, slot)
    end
    local bySlot = {}
    for _, entry in ipairs(slots or {}) do
        local index = tonumber(entry and entry.slot)
        if index then
            bySlot[index] = entry
        end
    end
    local itemMax = self:itemMaxCount(itemName, nbt)
    if not itemMax then
        return nil
    end
    amount = math.max(1, tonumber(amount) or 1)
    local sameSlot, sameFree
    local fitsSlot, fitsFree
    local roomSlot, roomFree
    local dirtyCount, fullCount, otherCount = 0, 0, 0
    local unknownCount = 0
    for slot = 1, size do
        local stack = bySlot[slot]
        local free = nil
        local same = false
        if not inSlot(peripheralName, slot) then
            free = nil
            dirtyCount = dirtyCount + 1
        elseif stack == nil then
            -- Empty slot: how much of THIS item fits there (slot multiplier * its
            -- stack size), not just one stack.
            free = self:slotCapacityFor(peripheralName, slot, itemName, nbt)
        elseif tostring(stack.name) == tostring(itemName) and tostring(stack.nbt or "") == tostring(nbt or "") then
            -- The capacity can be unknown for a while (the slot limit or that item's
            -- stack size is still being read): no room is assumed then, the slot is
            -- simply not used until the answer arrives. Never do arithmetic on nil.
            local capacity = self:slotCapacityFor(peripheralName, slot, itemName, nbt)
            free = capacity and math.max(0, capacity - (tonumber(stack.count) or 0)) or nil
            same = true
            if free == 0 then
                fullCount = fullCount + 1
            elseif free == nil then
                unknownCount = unknownCount + 1
            end
        else
            otherCount = otherCount + 1
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
    local function noteFailure()
        self.lastInsertFailure = {
        container = containerName,
        item = itemName,
        nbt = nbt,
        slots = size,
        dirty = dirtyCount,
        full = fullCount,
        other = otherCount,
        unknown = unknownCount,
        snapshot = self:hasSnapshot(peripheralName) and true or false,
        at = os.epoch("utc"),
    }
        debugLog(self,
        "insertSlotFor %s item=%s nbt=%s amount=%s capacity=%s slots=%s snapshot=%s" ..
        " -> no usable slot (dirty=%d full=%d other=%d unknown=%d)",
        tostring(containerName), tostring(itemName), tostring(nbt), tostring(amount),
        tostring(itemMax), tostring(size),
        (self:hasSnapshot(peripheralName) and "yes" or "no"),
        dirtyCount, fullCount, otherCount, unknownCount)
        return nil
    end
    if mode == Containers.INSERT_LEAST then
        if sameSlot then
            return sameSlot
        end
        if fitsSlot then
            return fitsSlot
        end
        if not roomSlot then
            noteFailure()
        end
        return roomSlot
    end
    if fitsSlot then
        return fitsSlot
    end
    if not roomSlot then
        noteFailure()
    end
    return roomSlot
end
function Containers:pushFluid(fromContainer, limit, fluidName, toContainer, queueName)
    local fromPeripheral = self:peripheralOf(fromContainer, "fluid")
    local toPeripheral = self:peripheralOf(toContainer, "fluid")
    if not fromPeripheral then
        return 0, self:unusableReason(fromContainer, "fluid")
            or self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_UNUSABLE, { name = tostring(fromContainer) })
    end
    if not toPeripheral then
        return 0, self:unusableReason(toContainer, "fluid")
            or self.Message.msg(self.Message.KEYS.CONT_ERR_TARGET_UNUSABLE, { name = tostring(toContainer) })
    end
    if fromPeripheral == toPeripheral then
        return 0, samePeripheralReason(self.Message, fromContainer, toContainer, fromPeripheral)
    end
    limit = tonumber(limit) or 1
    if limit <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_COUNT)
    end
    local key = table.concat({ "fluid", fromPeripheral, toPeripheral, tostring(fluidName or "") }, "|")
    local result = self:takeMoveResult(key)
    if result then
        return result.moved, result.err
    end
    if self.moveInflight[key] then
        return nil, "pending"
    end

    if not self:snapshotComplete(fromPeripheral, "fluid") then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_SOURCE_NO_SNAPSHOT_FLUID)
    end
    local bestTank, bestAmount = nil, 0
    local visible = self:visibleTanks(fromPeripheral)
    for tank, entry in pairs(visible) do

        if entry.name == fluidName and entry.amount > bestAmount then
            bestTank, bestAmount = tank, entry.amount
        end
    end
    if not bestTank or bestAmount <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_FLUID)
    end
    -- pushFluid never claims: only takeFluid / sendFluid / manageFluid write the dirty marks.
    local reserved = math.min(limit, bestAmount)
    if reserved <= 0 then
        return 0, self.Message.msg(self.Message.KEYS.CONT_ERR_NO_FLUID)
    end
    local record = {
        key = key, kind = "fluid", action = "push_fluid",
        from = fromPeripheral, fromIndex = bestTank, to = toPeripheral, toIndex = nil,
        reserved = reserved, limit = limit, item = fluidName, claimed = false,

        targetTankUnknown = true,

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
            moveKey = record.key,
        })
        if state == "pending" then
            return nil, "pending"
        elseif state == "done" then
            return moved, err
        end
    end
    return 0, "fluid move failed: the transfer module is unavailable (no IFMWorker executor)"
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
    -- A pending container may have been waiting for exactly this stack size: re-check
    -- whether every slot can now be sized (see noteSlotDetailsKnown).
    noteSlotDetailsKnown(self)
    return true
end

-- An item's getItemDetail() could not be read (the peripheral refused/failed, or a
-- worker/turtle answered without a usable detail). Its stack size stays unknown, so every
-- slot holding it stays unsized - which keeps those slots out of item I/O and the
-- container on the pending list (see slotCapacityComplete). Logged once per item, because
-- otherwise this wait would be invisible. Symmetric to markLimitUnavailable().
function Containers:markDetailUnavailable(itemName, nbt, reason)
    if type(itemName) ~= "string" or itemName == "" then
        return false
    end
    self.detailFailed = self.detailFailed or {}
    local key = itemDetailKey(itemName, nbt)
    if self.detailFailed[key] then
        return false
    end
    self.detailFailed[key] = true
    self.log.error("item %s: its getItemDetail() could not be read (%s) - its stack size stays" ..
        " unknown, so its slots stay unsized and take part in no item I/O; storage compaction" ..
        " keeps waiting for them", tostring(itemName), tostring(reason or "no reason given"))
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
-- Detail requests are a plain in-flight set: cleared by the transfer timeout path
-- (the same instruction timeout every other request uses), never by a private TTL.
function Containers:detailsInFlight(itemName, nbt)
    if type(itemName) ~= "string" or itemName == "" then
        return false
    end
    return (self.detailInFlight or {})[itemDetailKey(itemName, nbt)] == true
end

-- Called by the transfer layer when a detail instruction is settled (reply or
-- timeout), so the in-flight marks go away through the shared flow.
function Containers:noteDetailSettled(request)
    local map = self.detailInFlight
    if not map then
        return 0
    end
    local cleared = 0
    for _, sample in ipairs((request or {}).samples or {}) do
        local key = itemDetailKey(sample.name, sample.nbt)
        if map[key] then
            map[key] = nil
            cleared = cleared + 1
        end
    end
    return cleared
end
function Containers:requestItemDetails(samples)
    if type(samples) ~= "table" or #samples == 0 then
        return "busy"
    end
    if not self.detailProvider or type(self.detailProvider.detailRequest) ~= "function" then
        return "busy"
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
    local state = self.detailProvider.detailRequest(self.detailProvider, fresh)
    state = state or "busy"
    if state == "pending" then
        self.detailInFlight = self.detailInFlight or {}
        for _, sample in ipairs(fresh) do
            self.detailInFlight[itemDetailKey(sample.name, sample.nbt)] = true
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

function Containers:forgetPeripheral(peripheralName, reason)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    local forgot = false
    if self.model[peripheralName] ~= nil then
        -- Drop the reverse-index entries while the model still holds the old
        -- content, then forget the model.
        self:indexClearModel(peripheralName)
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

    for key, record in pairs(self.moveInflight or {}) do
        if record.from == peripheralName or record.to == peripheralName then
            self:settleMove(record, 0)
            self.moveInflight[key] = nil
        end
    end
    self:releaseInUseOf(peripheralName)
    self.dirty[peripheralName] = nil
    self:clearCapacityPending(peripheralName)
    if self.slotLimitPending then
        self.slotLimitPending[peripheralName] = nil
    end
    if forgot then
        self.forgotten = self.forgotten + 1
        self.snapshots = {}
        self.log("Forgot cached contents of %s (%s)", peripheralName, tostring(reason or "container removed"))
    end
    return forgot
end

function Containers:clearSnapshot(peripheralName, reason)
    if type(peripheralName) ~= "string" or peripheralName == "" then
        return false
    end
    local model = self:modelOf(peripheralName)
    if not model then
        return false
    end
    self:indexClearModel(peripheralName)
    model.slots = {}
    model.tanks = {}
    model.info = model.info or {}
    model.info.list = false
    model.info.items = false
    model.info.tanks = false
    model.info.size = false
    model.limitKnown = 0
    -- The snapshot is gone, so the slot capacities (and their cached multipliers) have to
    -- be read again: dropping slotLimits makes requestAllSlotLimits() ask for them anew.
    model.slotLimits = nil
    self:markCapacityPending(peripheralName)
    model.stamp = os.epoch("utc")
    model.gen = (model.gen or 0) + 1
    model.cleared = (model.cleared or 0) + 1
    self.snapshots = {}
    self.log("Cleared the cached contents of %s (%s) - nothing could be read from it for a while" ..
        " (check whether it is empty, or whether that peripheral is reachable)",
        tostring(peripheralName), tostring(reason or "unreadable"))
    return true
end

function Containers:pruneMissingPeripherals(reason)
    local referenced = self:referencedPeripherals()

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
    self.inUse = {}
    self.index = { items = {}, fluids = {} }
    self.sourceIndex = {}
    self.claimResidual = {}
    self.capacityPending = {}
    self.slotLimitPending = {}
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
        local key = itemKeyOf(stack.name, stack.nbt)
        local entry = grouped[key]
        if not entry then
            entry = { kind = "item", name = stack.name, nbt = stack.nbt, count = 0 }
            grouped[key] = entry
        end
        entry.count = entry.count + stack.count
    end
    for _, tank in ipairs(snapshot.tanks) do
        local key = "fluid:" .. tostring(tank.name)
        local entry = grouped[key]
        if not entry then
            entry = { kind = "fluid", name = tank.name, nbt = tank.nbt, count = 0 }
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

function Containers:stackScanStatusFromSnapshot(containerName)
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return { known = 0, unknown = 0 }
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
    return { known = known, unknown = unknown }
end

function Containers:stackScanStatus(containerName)
    local status = self:stackScanStatusFromSnapshot(containerName)
    local peripheralName = self:peripheralOf(containerName, "item")
    status.slots = peripheralName and self:slotCount(peripheralName) or 0
    return status
end

function Containers:stackLimitOf(itemName, nbt)
    return self:itemMaxCount(itemName, nbt)
    end

function Containers:planInputRevision()
    local revision = 0
    for _, model in pairs(self.model or {}) do
        revision = revision + (model.gen or 0)
    end
    return revision * 100000 + (self.stackLimitKnown or 0)
end

-- Per-tick profiling of stackScanStep, so a "LONG BLOCK dispatch" can show where the
-- time inside one stack scan goes (list building vs limit checks vs the detail ask).
function Containers:resetStackStepStats()
    self.stackStepStats = { calls = 0, listMs = 0, loopMs = 0, askMs = 0, totalMs = 0,
        maxMs = 0, occupied = 0, missing = 0, lastContainer = nil,
        -- Added: the un-timed prefix (defRole/peripheralOf) and the slotCount() call,
        -- plus how often slotCount had to do a DIRECT peripheral read (inv.size()).
        prefixMs = 0, slotMs = 0, slotHit = 0, slotMiss = 0, slotDirect = 0 }
    self.slotCountStats = { hit = 0, miss = 0, direct = 0 }
end

function Containers:stackStepText()
    local s = self.stackStepStats
    if not s or (s.calls or 0) == 0 then
        return ""
    end
    local sc = self.slotCountStats or {}
    return string.format(
        "stackStep calls=%d occ=%d miss=%d prefix=%.0fms slot=%.0fms(hit=%d miss=%d direct=%d) " ..
        "list=%.0fms loop=%.0fms ask=%.0fms total=%.0fms max=%.0fms last=%s",
        s.calls, s.occupied, s.missing, s.prefixMs or 0, s.slotMs or 0,
        sc.hit or 0, sc.miss or 0, sc.direct or 0,
        s.listMs, s.loopMs, s.askMs, s.totalMs, s.maxMs,
        tostring(s.lastContainer or "?"))
end

function Containers:stackScanStep(containerName)
    -- Timed with os.epoch (real ms). slotCount() here is snapshot-only now (it never
    -- touches the peripheral), so the scan body is the only cost left.
    local stepStart = os.epoch("utc")

    local role = self:defRole(containerName, "item")
    if role ~= "storage" then
        error(string.format("BUG: Containers:stackScanStep called for %s (role=%s): only storage containers feed the compact plan",
            tostring(containerName), tostring(role)), 0)
    end
    local peripheralName = self:peripheralOf(containerName, "item")
    if not peripheralName then
        return 0
    end
    local prefixAt = os.epoch("utc")

    self:slotCount(peripheralName)
    local slotAt = os.epoch("utc")

    local listed = self:listPeripheral(peripheralName)
    local listAt = os.epoch("utc")
    local samples = {}
    local occupied = 0
    for slot, stack in pairs(listed) do
        occupied = occupied + 1
        if type(stack) == "table" and type(stack.name) == "string" and stack.name ~= "" and
            not self:stackLimitOf(stack.name, stack.nbt) then
            samples[#samples + 1] = {
                container = peripheralName, slot = slot, name = stack.name, nbt = stack.nbt,
            }
        end
    end
    local loopAt = os.epoch("utc")
    local state = nil
    if #samples > 0 then
        state = self:requestItemDetails({ samples[1] })
    end
    local askAt = os.epoch("utc")

    local stats = self.stackStepStats
    if stats then
        local total = askAt - stepStart
        stats.calls = stats.calls + 1
        stats.prefixMs = stats.prefixMs + (prefixAt - stepStart)
        stats.slotMs = stats.slotMs + (slotAt - prefixAt)
        stats.listMs = stats.listMs + (listAt - slotAt)
        stats.loopMs = stats.loopMs + (loopAt - listAt)
        stats.askMs = stats.askMs + (askAt - loopAt)
        stats.totalMs = stats.totalMs + total
        if total > stats.maxMs then
            stats.maxMs = total
        end
        stats.occupied = stats.occupied + occupied
        stats.missing = stats.missing + #samples
        stats.lastContainer = peripheralName
    end

    if #samples == 0 then
        return 0
    end

    -- One element = one detail instruction = one load: exactly one sample is asked
    -- for on a remote worker; the next element picks up the next stack that still
    -- lacks its limit. With no worker available the step reports 0 and is retried.
    if state == "pending" then
        return #samples
    end
    return 0
end

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

function Containers:slotCount(peripheralName)
    self.slotCountCache = self.slotCountCache or {}
    local stats = self.slotCountStats
    local now = os.epoch("utc")
    local cached = self.slotCountCache[peripheralName]
    if cached and now - cached.stamp < SLOT_COUNT_TTL then
        if stats then stats.hit = stats.hit + 1 end
        return cached.value
    end

    local model = self.model[peripheralName]
    local known = model and tonumber(model.size) or nil
    if known and known > 0 then
        if known > MAX_CONTAINER_SLOTS then
            -- Logged as an error (never fatal): a huge (but real) container must not
            -- take the master down, but its slot-capacity scan can never complete.
            self.log.error("%s reported %d slots (above the %d soft limit) - trusting it anyway",
                tostring(peripheralName), known, MAX_CONTAINER_SLOTS)
        end
        local value = known
        self.slotCountCache[peripheralName] = { value = value, stamp = now }
        if stats then stats.hit = stats.hit + 1 end
        return value
    end
    if stats then stats.miss = stats.miss + 1 end
    -- Slot count unknown: the master must NOT read the peripheral itself. Doing so
    -- (Peripheral:wrap + inventory.size()) blocked the main loop for ~50ms per
    -- container and could freeze a whole tick with many containers. The size is
    -- learned from the snapshot instead: the containerSize scan fills model.size via
    -- applySize, and every caller treats nil as "still scanning".
    return nil
end
function Containers:compactPlanner(role, opts)
    opts = opts or {}
    return {
        role = role or "storage",
        calls = 0,
        totalCalls = 0,
        passes = 0,
        stage = "scan",
        containersDone = 0,
        containersTotal = 0,
        groupsDone = 0,
        groupsTotal = 0,
        -- Streaming move generation (see compactPlanSimple): the layout snapshot of the
        -- current pass, the slot cursor, the counters, and `stale` when a failed move
        -- forces steps 1-4 to run again.
        slotList = nil,
        slotTotal = 0,
        cursor = 1,
        targetItemAt = nil,
        targetMultiplier = nil,
        queued = 0,
        skipped = 0,
        rejected = 0,
        restarts = 0,
        stale = nil,
    }
end
function Containers:capacityStats()
    local now = os.epoch("utc")
    local cached = self.capacityCache
    if cached and now - cached.stamp < self.capacityTtl then
        return cached.value
    end
    local stats = { items = 0, itemCapacity = 0, slots = 0, totalSlots = 0, skipped = 0, unsized = 0 }
    for _, containerName in ipairs(self:byRole("storage", "item")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        -- The size comes from the snapshot, not from slotCount(): asking the
        -- peripheral here would raise for a container that is gone, and an aggregate
        -- statistic must not be able to abort the whole snapshot.
        local model = peripheralName and self.model[peripheralName] or nil
        local size = model and tonumber(model.size) or nil
        if peripheralName and size and size > 0 and size <= MAX_CONTAINER_SLOTS then
            local listed = self:listPeripheral(peripheralName)
            local items, used = 0, 0
            for slot, stack in pairs(listed) do
                if type(stack) == "table" and stack.name then
                    used = used + 1
                    items = items + (tonumber(stack.count) or 0)
                    -- Occupied slot: getItemLimit() already is its capacity, expressed
                    -- in units of the item that is stored in it (nil while unknown).
                    local occupiedCapacity = self:slotCapacityFor(peripheralName, slot, stack.name, stack.nbt)
                    if occupiedCapacity then
                        stats.itemCapacity = stats.itemCapacity + occupiedCapacity
                    else
                        -- Slot limit / item stack size still unknown: not counted.
                        stats.unsized = stats.unsized + 1
                    end
                end
            end
            -- Empty slots: capacity for a 64-stack item (multiplier * 64).
            for slot = 1, size do
                local stack = listed[slot]
                if not (type(stack) == "table" and stack.name) then
                    local emptyCapacity = self:slotCapacityFor(peripheralName, slot)
                    if emptyCapacity then
                        stats.itemCapacity = stats.itemCapacity + emptyCapacity
                    else
                        stats.unsized = stats.unsized + 1
                    end
                end
            end
            stats.items = stats.items + items
            stats.slots = stats.slots + used
            stats.totalSlots = stats.totalSlots + size
        elseif peripheralName then
            stats.skipped = stats.skipped + 1
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

function Containers:compactPlanPass(planner)
    planner = planner or self:compactPlanner("storage")
    planner.calls = 0
    planner.passes = (planner.passes or 0) + 1
    planner.yielded = nil

    local queued, skipped, finished = self:compactPlanSimple(planner.role, planner)
    planner.skipped = skipped or 0
    planner.plannedMoves = queued or 0
    planner.containersDone = planner.containersTotal
    if finished ~= true then
        -- One slot per call: the stage stays open and the next call carries on with the
        -- slot after this one.
        planner.stage = "moves"
        planner.groupsDone = math.max(0, (tonumber(planner.cursor) or 1) - 1)
        planner.groupsTotal = tonumber(planner.slotTotal) or 0
        return queued or 0, skipped or 0, false
    end
    planner.stage = "done"
    planner.groupsDone = queued or 0
    planner.groupsTotal = queued or 0
    return queued or 0, skipped or 0, true
end

-- Storage compaction, target-layout algorithm:
--   1. items are sorted by their total count (in-use items excluded), merge sort: the
--      kind with the most items is laid out first;
--   2. each kind takes the capacity class (slot multiplier) that needs the fewest
--      slots for its whole count, and on a tie the smallest multiplier - a bulk item
--      lands in the big slots, a single small stack lands in a small slot;
--   3. a class that runs out of free slots hands the rest of the kind on to the next
--      class, again by "fewest slots, then smallest multiplier";
--   4. every slot whose current item differs from its target item is looked at once, in
--      the order of the snapshot: the stack goes to a slot of the target multiplier that
--      either is empty or already holds the same kind in its own target slot with enough
--      room left, and that has no move on the way (see below). No such slot: the item is
--      skipped.
--      A stack that already sits in a slot of its own target multiplier is only moved to
--      MERGE with the same kind in another slot of that class (both counts then fit into
--      one slot, which frees a slot). Shifting it to another slot of the same multiplier
--      changes no class total, and a peripheral that ignores `toSlot` would otherwise keep
--      regenerating that very same move pass after pass.
-- The move generation streams - one slot per call - and hands every move it finds to the
-- compact queue immediately. The reservation model of the queue pins both ends of a move,
-- so a slot that is already committed (or busy) is neither a source nor a destination: a
-- swap therefore advances one stage per pass, and the next pass - started once the current
-- one is through - carries on. A refused move means the snapshot no longer matches the
-- storage, so the pass rebuilds it (steps 1-4) instead of planning from stale positions.
-- Steps 1-4 of a compaction pass: collect every movable slot of the role, sum the items
-- up, sort both, group the slots into capacity classes and lay the target layout out.
-- This snapshot is what the streaming move generation works on; it is rebuilt whenever a
-- pass starts over (see compactPlanSimple).
local function compactLayoutSnapshot(self, role)
    role = role or "storage"
    local slots, items, itemOrder = {}, {}, {}
    for _, containerName in ipairs(self:byRole(role, "item", "in")) do
        local peripheralName = self:peripheralOf(containerName, "item")
        if peripheralName and self.Peripherals:isInventory(peripheralName) then
            local size = self:slotCount(peripheralName)
            local stacks = size and size > 0 and self:stacksPeripheral(peripheralName) or nil
            if stacks then
                local bySlot = {}
                for _, stack in ipairs(stacks) do
                    bySlot[tonumber(stack.slot)] = stack
                end
                for slot = 1, size do
                    -- In-use slots are not part of the layout at all: neither their
                    -- item nor their capacity is read or moved.
                    if not self:slotBusy(peripheralName, slot) then
                        local stack = bySlot[slot]
                        local multiplier = self:slotMultiplierOf(peripheralName, slot)
                        if multiplier == nil then
                            -- The container gate (hasUnknownSlotCapacity) must have kept
                            -- compaction from running while any slot was unsized: reaching
                            -- this means the gate leaked, so fail loudly instead of planning
                            -- around a half-read container.
                            error(string.format("BUG: Containers:compactPlanSimple reached %s slot %d" ..
                                " whose capacity multiplier is not ready - compaction must not run" ..
                                " on a container whose slot capacities are still being read",
                                tostring(peripheralName), slot), 0)
                        end
                        slots[#slots + 1] = {
                            container = containerName, peripheral = peripheralName, slot = slot,
                            multiplier = multiplier,
                            current = stack and {
                                name = stack.name, nbt = stack.nbt,
                                count = tonumber(stack.count) or 0,
                            } or nil,
                        }
                        if stack and multiplier then
                            local key = itemKeyOf(stack.name, stack.nbt)
                            if key then
                                local entry = items[key]
                                if not entry then
                                    entry = { name = stack.name, nbt = stack.nbt, count = 0 }
                                    items[key] = entry
                                    -- First-seen order: the merge sort below is stable and
                                    -- must not depend on an unordered table walk.
                                    itemOrder[#itemOrder + 1] = entry
                                end
                                entry.count = entry.count + (tonumber(stack.count) or 0)
                            end
                        end
                    end
                end
            end
        end
    end

    local itemList = mergeSort(itemOrder, function(a, b)
        return a.count > b.count
    end)
    slots = mergeSort(slots, function(a, b)
        return (a.multiplier or 0) > (b.multiplier or 0)
    end)

    -- Target layout. The kinds are laid out in total-count order (priority 1); each
    -- one takes the class that needs the fewest slots (priority 2) and, on a tie, the
    -- smallest multiplier (priority 3). A class that runs out of free slots passes the
    -- rest of the kind on to the next class under the same two rules.
    local classList, classOf = {}, {}
    for index = 1, #slots do
        local multiplier = tonumber(slots[index].multiplier)
        if multiplier and multiplier > 0 then
            local bucket = classOf[multiplier]
            if not bucket then
                bucket = { multiplier = multiplier, indices = {}, cursor = 0 }
                classOf[multiplier] = bucket
                classList[#classList + 1] = bucket
            end
            local indices = bucket.indices
            indices[#indices + 1] = index
        end
    end
    -- Ascending order, so the first class that needs the fewest slots is also the
    -- smallest one (priority 3).
    mergeSort(classList, function(a, b)
        return a.multiplier < b.multiplier
    end)

    local targetItemAt, targetMultiplier = {}, {}
    for _, entry in ipairs(itemList) do
        local itemMax = self:itemMaxCount(entry.name, entry.nbt)
        local key = itemKeyOf(entry.name, entry.nbt)
        if itemMax and key then
            local remaining = entry.count
            while remaining > 0 do
                local best, bestNeed, bestPer = nil, nil, nil
                for _, bucket in ipairs(classList) do
                    local available = #bucket.indices - bucket.cursor
                    if available > 0 then
                        local per = math.max(1, math.floor(bucket.multiplier * itemMax))
                        local need = math.floor((remaining - 1) / per) + 1
                        if bestNeed == nil or need < bestNeed then
                            best, bestNeed, bestPer = bucket, need, per
                        end
                    end
                end
                if not best then
                    -- Every class is full: the rest of this kind gets no target slot.
                    break
                end
                local take = math.min(bestNeed, #best.indices - best.cursor)
                for _ = 1, take do
                    best.cursor = best.cursor + 1
                    targetItemAt[best.indices[best.cursor]] = key
                end
                if targetMultiplier[key] == nil then
                    targetMultiplier[key] = best.multiplier
                end
                remaining = remaining - take * bestPer
            end
        end
    end

    return slots, targetItemAt, targetMultiplier
end

-- The move generation of a compaction pass, one slot per call: the layout snapshot is
-- built once (steps 1-4) and then every call takes the next slot, finds a destination in
-- that snapshot and hands the move straight to the compact queue - there is no plan array
-- that would be executed later. A move the queue refuses, or a slot whose content no
-- longer matches the snapshot, invalidates the snapshot: the next call rebuilds it (steps
-- 1-4), and slots that already have a move on the way are busy and therefore not part of a
-- rebuilt snapshot at all. Returns queued, skipped, finished.
function Containers:compactPlanSimple(role, planner)
    role = role or "storage"
    planner = planner or self:compactPlanner(role)
    if planner.slotList == nil or planner.stale then
        planner.stale = nil
        planner.restarts = (planner.restarts or 0) + 1
        local slots, targetItemAt, targetMultiplier = compactLayoutSnapshot(self, role)
        planner.slotList = slots
        planner.slotTotal = #slots
        planner.cursor = 1
        planner.targetItemAt = targetItemAt
        planner.targetMultiplier = targetMultiplier
    end
    local slots = planner.slotList
    local targetItemAt = planner.targetItemAt or {}
    local targetMultiplier = planner.targetMultiplier or {}
    local slotTotal = tonumber(planner.slotTotal) or 0
    local index = tonumber(planner.cursor) or 1
    if index > slotTotal then
        return planner.queued or 0, planner.skipped or 0, true
    end
    planner.cursor = index + 1
    local slot = slots[index]
    local current = slot and slot.current or nil
    -- A slot that got a move on the way since the snapshot was built (as a destination of
    -- an earlier slot) must not act as a source now: the queue would refuse that move.
    if current and not self:slotBusy(slot.peripheral, slot.slot) then
        -- The snapshot is older than the storage: every move handed to the queue since
        -- it was built changed a container. So the source is verified before planning
        -- from it - a mismatch means steps 1-4 have to run again.
        local live = self:stackAt(slot.container, slot.slot)
        if not live or tostring(live.name) ~= tostring(current.name)
            or tostring(live.nbt or "") ~= tostring(current.nbt or "") then
            planner.rejected = (planner.rejected or 0) + 1
            planner.stale = true
            return planner.queued or 0, planner.skipped or 0, false
        end
        local currentKey = itemKeyOf(current.name, current.nbt)
        if not currentKey or currentKey ~= targetItemAt[index] then
            -- The stack belongs somewhere else: look for a slot of the class its kind is
            -- laid out in that can take the whole stack right now.
            local wantMultiplier = currentKey and targetMultiplier[currentKey] or nil
            local amount = tonumber(current.count) or 0
            local destIndex = nil
            -- A stack that already sits in a slot of its OWN capacity class is placed
            -- correctly: shifting it to another slot of the SAME multiplier frees no
            -- capacity and changes no class total. The only meaningful same-class move is
            -- a merge, where both counts fit into one slot and a slot is freed. Skipping
            -- the rest also stops peripherals that ignore the target slot from
            -- regenerating the very same move pass after pass.
            local inOwnClass = wantMultiplier ~= nil and slot.multiplier ~= nil
                and math.abs(slot.multiplier - wantMultiplier) < 1e-9
            if wantMultiplier and amount > 0 then
                for candidate = 1, #slots do
                    local other = slots[candidate]
                    -- A slot with a move on the way is busy: neither source nor
                    -- destination for this pass - this replaces the plan-local bookkeeping
                    -- of the old batch planner, and it holds across passes too.
                    if not self:slotBusy(other.peripheral, other.slot) and other.multiplier ~= nil
                        and math.abs(other.multiplier - wantMultiplier) < 1e-9 then
                        -- Room is checked for the empty case too, because slot limits may
                        -- be small (a machine slot of 16 must not pretend to hold a stack
                        -- of 64).
                        local room = self:slotCapacityFor(other.peripheral, other.slot,
                            current.name, current.nbt)
                        if room and room >= amount then
                            if other.current == nil then
                                -- Empty slot of the target class: move there, but only to
                                -- CHANGE class - a lateral move inside the own class
                                -- achieves nothing.
                                if not inOwnClass then
                                    destIndex = candidate
                                end
                            elseif itemKeyOf(other.current.name, other.current.nbt) == currentKey
                                and targetItemAt[candidate] == currentKey
                                and (room - (tonumber(other.current.count) or 0)) >= amount then
                                -- Same kind, this slot is its own target slot, and both
                                -- counts fit into it: merge (this slot is freed).
                                destIndex = candidate
                            end
                        end
                        if destIndex then
                            break
                        end
                    end
                end
            end
            if destIndex then
                local dest = slots[destIndex]
                local key, why = self:manageItem(slot.container, slot.slot, dest.container, dest.slot,
                    { name = current.name, nbt = current.nbt }, amount)
                if key then
                    planner.queued = (planner.queued or 0) + 1
                else
                    planner.rejected = (planner.rejected or 0) + 1
                    if (planner.rejected or 0) <= 3 then
                        self.log.warn("compact move rejected: %s", self.Message.describe(why))
                    end
                    planner.stale = true
                    return planner.queued or 0, planner.skipped or 0, false
                end
            else
                planner.skipped = (planner.skipped or 0) + 1
            end
        end
    end
    if planner.stale then
        return planner.queued or 0, planner.skipped or 0, false
    end
    return planner.queued or 0, planner.skipped or 0, (tonumber(planner.cursor) or 1) > slotTotal
end

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

                    provides = self.Peripherals:isInventory(def.peripheral)
                        or ((def.role or "storage") == "interaction"
                            and self.Peripherals:isTurtle(def.peripheral))
                end
            end
            if not provides then

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
