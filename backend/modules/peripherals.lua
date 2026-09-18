-- IFM :: modules/peripherals.lua
-- 外设扫描与包装：inventory（物品容器）、fluid_storage（流体容器）、redstone_relay（红石中继器）。

local Peripherals = {}
Peripherals.__index = Peripherals

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

--- 判断某个外设是否是给定类型（兼容 hasType / getType，且三者都可能返回多类型）
local function hasType(name, expected)
    if type(peripheral.hasType) == "function" then
        local ok, result = pcall(peripheral.hasType, name, expected)
        if ok and result == true then
            return true
        end
    end
    local ok, a, b, c = pcall(peripheral.getType, name)
    if not ok then
        return false
    end
    local returns = { a, b, c }
    for _, value in ipairs(returns) do
        if value == expected then
            return true
        end
    end
    return false
end

--- 列出全部外设名称
local function listNames()
    local names = {}
    if type(peripheral.getNames) == "function" then
        local ok, list = pcall(peripheral.getNames)
        if ok and type(list) == "table" then
            for _, name in ipairs(list) do
                names[#names + 1] = name
            end
            return names
        end
    end
    for _, side in ipairs(SIDES) do
        local ok, ty = pcall(peripheral.getType, side)
        if ok and ty ~= nil then
            names[#names + 1] = side
        end
    end
    return names
end

function Peripherals.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Peripherals)
    self.Util = opts.Util
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

--- 重新扫描全部外设（外设热插拔时调用）
function Peripherals:scan()
    self.inventory = {}
    self.fluid = {}
    self.redstone = {}
    self.other = {}
    self.wrapped = {}
    for _, name in ipairs(listNames()) do
        local isInventory = hasType(name, "inventory")
        local isFluid = hasType(name, "fluid_storage")
        local isRelay = hasType(name, "redstone_relay")
        if isInventory then
            self.inventory[name] = true
        end
        if isFluid then
            self.fluid[name] = true
        end
        if isRelay then
            self.redstone[name] = true
        end
        if not isInventory and not isFluid and not isRelay then
            self.other[name] = true
        end
    end
    self.lastScan = os.epoch("utc")
end

--- 丢弃包装缓存：外设被替换 / 区块重载后，旧的包装对象会失效（调用会一直报错或返回空），
--- 清掉缓存后下次调用会重新 peripheral.wrap，不必重启服务端。
--- 传 name 只清一个外设；不传参数清空全部。
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

function Peripherals:exists(name)
    return self.inventory[name] == true or self.fluid[name] == true or self.redstone[name] == true
end

--- 包装（带缓存）
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
