-- IFM :: modules/modems.lua
-- modem 发现与包装：主控（modules/transfer.lua 调度 IFMWorker）与 worker（IFMWorker.lua）共用。
--
-- 为什么单独成模块：这两边以前各写了一份（约 60 行几乎逐行相同）。worker 跑在别的计算机上，
-- 出问题最难查，任何一处修正（有线优先、多类型外设、wrap 参数的兼容）都要保证两边一致。
--
-- 关键约定：peripheral.find 的返回值在不同 CC:T 版本 / 分支里不完全一样
-- （CC:T 是「外设名, 包装对象」，有的分支只给包装对象本身），这里统一成 (包装对象, 外设名)，
-- 避免 bad argument #1 to 'wrap' (string expected, got peripheral)。

local Modems = {}

--- 判断一个值是不是“已经包好的外设”（table / userdata）
function Modems.isPeripheral(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

--- 把 peripheral.find 的两种返回值统一成 (包装对象, 外设名)
function Modems.asModem(value)
    if type(value) == "string" then
        local ok, wrapped = pcall(peripheral.wrap, value)
        if ok and wrapped then
            return wrapped, value
        end
        return nil, nil
    end
    if Modems.isPeripheral(value) then
        local name = nil
        local ok, wrappedName = pcall(peripheral.getName, value)
        if ok and type(wrappedName) == "string" then
            name = wrappedName
        end
        return value, name
    end
    return nil, nil
end

--- 是不是有线 modem（有线网络里的计算机共享外设：worker 能看到主控那边的容器）
function Modems.isWiredModem(modem)
    if type(modem.isWireless) ~= "function" then
        return false
    end
    local ok, wireless = pcall(modem.isWireless)
    return ok and wireless == false
end

--- 找一个 modem，有线优先；一个都没有时返回 nil, nil
function Modems.find()
    local wireless, wirelessName = nil, nil
    local first, second = peripheral.find("modem")
    local modem, name = Modems.asModem(first)
    if not modem then
        modem, name = Modems.asModem(second)
    end
    if modem then
        if Modems.isWiredModem(modem) then
            return modem, name
        end
        wireless, wirelessName = modem, name
    end
    --- 兜底：自己扫一遍外设名（peripheral.find 什么都给不出时）
    for _, side in ipairs(peripheral.getNames()) do
        local ok, kind = pcall(peripheral.getType, side)
        if ok and kind == "modem" then
            local wrapped = peripheral.wrap(side)
            if wrapped and Modems.isWiredModem(wrapped) then
                return wrapped, side
            end
        end
    end
    return wireless, wirelessName
end

--- 在频道上发一条消息（收发频道相同）；返回 ok, err。
--- 用点号调用 modem.transmit：CC:T 的外设句柄是“已绑定对象的一堆函数”，
--- 写成 modem:transmit(...) 会把句柄自己当成第一个参数传进去。
function Modems.transmit(modem, channel, message)
    if not modem then
        return false, "no modem"
    end
    local ok, err = pcall(modem.transmit, channel, channel, message)
    if not ok then
        return false, err
    end
    return true
end

return Modems
