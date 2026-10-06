local Modems = {}

Modems.CHANNEL = 41000
Modems.CRAFTER_CHANNEL = 41001
Modems.PRIVATE_CHANNEL_BASE = 42000
Modems.PROTOCOL = "ifm_transfer"
Modems.CRAFTER_PROTOCOL = "ifm_crafter"

function Modems.workerChannelOf(id)
    local number = math.floor(tonumber(id) or 0) % 20000
    return Modems.PRIVATE_CHANNEL_BASE + number
end

function Modems.isPeripheral(value)
    local kind = type(value)
    return kind == "table" or kind == "userdata"
end

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

function Modems.isWiredModem(modem)
    if type(modem.isWireless) ~= "function" then
        return false
    end
    local ok, wireless = pcall(modem.isWireless)
    return ok and wireless == false
end

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
