-- Reference counter, kept as a *list of sources* plus a dirty flag and the last
-- computed total.
--
-- The old ledgers (containers claims, per-slot move counts, machine/running,
-- craftingCount, ...) were plain integers that every call site had to add and
-- subtract by hand. A single missed release (or a release that did not match the
-- amount that was added) left the number wrong forever. This type removes that
-- class of bug:
--
--   * a source is identified by a stable id (a move key, an instance id, ...);
--   * adding the same source again accumulates, and releasing a source removes
--     it whole (no "subtract up to N" guessing);
--   * `value()` recomputes the total only when the source list actually changed.
--
-- There is intentionally no "subtract an amount from a source" API: a caller
-- that wants to shrink a reservation must re-add the source with the smaller
-- amount via add().
local RefCount = {}
RefCount.__index = RefCount

function RefCount.new(name)
    return setmetatable({
        name = name,
        bySource = {},  -- sourceId -> amount
        dirty = true,   -- has the source list changed since the last value()?
        cached = 0,     -- value computed the last time it was dirty
    }, RefCount)
end

local function idOf(source)
    return tostring(source)
end

-- Add (or accumulate) one source. amount <= 0 removes the source instead.
function RefCount:add(source, amount)
    local id = idOf(source)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return self:remove(source)
    end
    self.bySource[id] = (self.bySource[id] or 0) + amount
    self.dirty = true
    return self.bySource[id]
end

-- Set one source to an exact amount (0 removes it).
function RefCount:set(source, amount)
    local id = idOf(source)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then
        return self:remove(source)
    end
    self.bySource[id] = amount
    self.dirty = true
    return amount
end

-- Remove one source whole. Returns the amount that was held.
function RefCount:remove(source)
    local id = idOf(source)
    local held = self.bySource[id]
    if held == nil then
        return 0
    end
    self.bySource[id] = nil
    self.dirty = true
    return held
end

function RefCount:held(source)
    return self.bySource[idOf(source)] or 0
end

-- The cached reference count: recomputed only when the source list changed.
function RefCount:value()
    if not self.dirty then
        return self.cached
    end
    local total = 0
    for _, amount in pairs(self.bySource) do
        total = total + amount
    end
    self.cached = total
    self.dirty = false
    return total
end

-- Drop every source (used when a ledger is rebuilt from scratch).
function RefCount:reset()
    self.bySource = {}
    self.dirty = true
    self.cached = 0
end

-- Force the cached value to be considered stale even though nothing was added or
-- removed (used when the sources table is mutated from the outside).
function RefCount:markDirty()
    self.dirty = true
end

function RefCount:empty()
    return next(self.bySource) == nil
end

-- [{ source = <id>, amount = <n> }], biggest first - for panels / diagnostics.
function RefCount:sources()
    local out = {}
    for source, amount in pairs(self.bySource) do
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

RefCount.idOf = idOf

return RefCount
