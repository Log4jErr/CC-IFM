local Peripherals = {}
Peripherals.__index = Peripherals

-- Peripheral names are used verbatim: exactly the strings peripheral.getNames()
-- returns, i.e. "modname:name_index" (e.g. minecraft:chest_42) on a wired network.
-- Plain side names are filtered out: they address different peripherals on
-- different computers and get renumbered by rewiring, so IFM never hands them to
-- any other layer. This module never addresses or enumerates a peripheral by side
-- (there is no side fallback: a peripheral that only has a side name is ignored).
local SIDE_NAMES = {
    top = true,
    bottom = true,
    left = true,
    right = true,
    front = true,
    back = true,
}

local function isSideName(name)
    return type(name) == "string" and SIDE_NAMES[name] == true
end

-- Pack a vararg into a table (table.pack is not available on every CC:T runtime,
-- so the count is stored explicitly and the values go to 1..n).
local function packTypes(...)
    return { n = select("#", ...), ... }
end

-- Peripheral types come from peripheral.getType(name), which returns one string per
-- type as a vararg (never peripheral.hasType: that API does not exist on every
-- CC:T version and its result must not be trusted blindly). Every returned type is
-- checked, so a peripheral with more than a handful of types is still classified
-- correctly (the old code only looked at the first three returns).
local function hasType(name, expected)
    local ok, types = pcall(function()
        return packTypes(peripheral.getType(name))
    end)
    if not ok or type(types) ~= "table" then
        return false
    end
    for index = 1, types.n do
        if types[index] == expected then
            return true
        end
    end
    return false
end

local function listNames()
    local names, sideSkipped = {}, 0
    if type(peripheral.getNames) == "function" then
        local ok, list = pcall(peripheral.getNames)
        if ok and type(list) == "table" then
            for _, name in ipairs(list) do
                if isSideName(name) then
                    sideSkipped = sideSkipped + 1
                else
                    names[#names + 1] = name
                end
            end
        end
    end
    return names, sideSkipped
end

function Peripherals.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Peripherals)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("peripherals.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.log = opts.log or function() end
    self.inventory = {}
    self.fluid = {}
    self.redstone = {}
    self.other = {}
    self.wrapped = {}
    self.lastScan = 0
    self:scan()
    return self
end

function Peripherals:scan()
    self.inventory = {}
    self.fluid = {}
    self.redstone = {}
    self.turtle = {}
    self.other = {}
    self.wrapped = {}
    local names, sideSkipped = listNames()
    for _, name in ipairs(names) do
        local isInventory = hasType(name, "inventory")
        local isFluid = hasType(name, "fluid_storage")
        local isRelay = hasType(name, "redstone_relay")
        local isTurtle = hasType(name, "turtle")
        if isInventory then
            self.inventory[name] = true
        end
        if isTurtle then
            self.turtle[name] = true
        end
        if isFluid then
            self.fluid[name] = true
        end
        if isRelay then
            self.redstone[name] = true
        end
        if not isInventory and not isTurtle and not isFluid and not isRelay then
            self.other[name] = true
        end
    end
    self.lastScan = os.epoch("utc")
    self.sideSkipped = sideSkipped
    if sideSkipped > 0 and self.sideSkippedNoted ~= sideSkipped then
        self.sideSkippedNoted = sideSkipped
        self.log("%d peripheral(s) only have a side name (top/left/...): they are ignored - " ..
            "connect them through a wired modem so they get a stable name like minecraft:chest_42",
            sideSkipped)
    end
end

function Peripherals:invalidate(name)
    if name == nil then
        self.wrapped = {}
        return
    end
    self.wrapped[name] = nil
end

function Peripherals:isInventory(name)
    return self.inventory[name] == true
end

function Peripherals:isFluid(name)
    return self.fluid[name] == true
end

function Peripherals:isTurtle(name)
    return self.turtle[name] == true
end

function Peripherals:turtleNames()
    return self:names("turtle")
end

function Peripherals:exists(name)
    return self.inventory[name] == true or self.fluid[name] == true or self.redstone[name] == true
        or self.turtle[name] == true
end

function Peripherals:wrap(name)
    if type(name) ~= "string" or not self:exists(name) then
        return nil
    end
    local wrapped = self.wrapped[name]
    if wrapped == nil then
        local ok, result = pcall(peripheral.wrap, name)
        if not ok or result == nil then
            return nil
        end
        wrapped = result
        self.wrapped[name] = wrapped
    end
    return wrapped
end

function Peripherals:names(kind)
    local source = self[kind] or {}
    local names = {}
    for name in pairs(source) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

return Peripherals
