local args = { ... }

local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMCrafter.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path ..
            " - keep IFMCrafter.lua next to the modules/ directory (the IFM bundle writes both)", 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

local Modems = loadModule("modems")
local Transfer = loadModule("transfer")

local PROTOCOL = Modems.CRAFTER_PROTOCOL
local CHANNEL = Modems.CRAFTER_CHANNEL
local VERSION = Transfer.VERSION

local HELLO_INTERVAL = 2
local MASTER_TIMEOUT = 30
local CRAFT_LIMIT = 64
local turtleApiReady = type(turtle) == "table"
local craftSupported = turtleApiReady and type(turtle.craft) == "function"
local INVENTORY_SLOTS = 16
local INVENTORY_REPORT_INTERVAL = 5

local workerName = nil
local channel = CHANNEL

local function printUsage()
    print("IFMCrafter.lua - IFM turtle crafter (executor for the turtle_crafter machine type)")
    print("Usage: IFMCrafter.lua [--channel <n>] [--name <label>] [--help]")
    print("  --channel  modem channel shared with the IFM master (default " .. tostring(CHANNEL) .. ")")
    print("             NOTE: this must NOT be the IFMWorker channel (" .. tostring(Modems.CHANNEL) .. ")")
    print("  --name     label shown in the web UI (default: computer id)")
    print("It only announces itself, runs turtle.craft(64) on request and answers the master's")
    print("inventory / item detail requests (only when the master asks - the details are what")
    print("teaches the master the stack limit of an item that exists only inside the turtle).")
    print("No recipe check, no item movement (IFMWorker pushes the materials in and takes the")
    print("products out). Keep the same ifm/ directory next to this file.")
    print("A wired modem is required: modem.getNameLocal() is how the turtle learns its own")
    print("network name, which is how the master recognises it as a running crafter.")
end

do
    local index = 1
    while index <= #args do
        local value = tostring(args[index])
        if value == "--help" or value == "-h" then
            printUsage()
            return
        elseif value == "--channel" then
            index = index + 1
            channel = tonumber(args[index]) or channel
        elseif value == "--name" then
            index = index + 1
            workerName = tostring(args[index] or "")
        else
            print("unknown argument ignored: " .. value)
        end
        index = index + 1
    end
end

if type(turtle) ~= "table" then
    print("IFMCrafter.lua must run on a turtle (no turtle API found).")
    return
end

local modem, modemSide = Modems.find()
if not modem then
    print("IFMCrafter.lua: no modem found. Attach a (wired) modem and run this again.")
    return
end
local okOpen, openErr = pcall(modem.open, channel)
if not okOpen then
    print("IFMCrafter.lua: cannot open channel " .. tostring(channel) .. " (" .. tostring(openErr) .. ")")
    return
end

local computerId = os.getComputerID()
if workerName == nil or workerName == "" then
    workerName = "crafter-#" .. tostring(computerId)
end

local selfName = nil
do
    local ok, value = pcall(modem.getNameLocal)
    if ok and type(value) == "string" and value ~= "" then
        selfName = value
    end
end

local function crafterLog(text)
    print("[crafter] " .. tostring(text))
end

local masterId = nil
local lastMasterAt = 0
local masterOnline = false
local versionWarning = nil
local lastVersionWarning = nil
local helloAt = 0
local busy = false
local craftCalls = 0
local lastCraftAt = 0
local lastCraftError = nil
local requestCount = 0
local lastRequestId = nil
local lastRequestAt = 0
local inventoryStacks = 0
local inventoryReportAt = 0
local lastText = {}

local lastSendError = nil
local function reply(message)
    message.proto = PROTOCOL
    message.from = computerId
    local ok, err = Modems.transmit(modem, channel, message)
    if not ok then
        local text = tostring(err)
        if text ~= lastSendError then
            lastSendError = text
            crafterLog("modem send failed (" .. tostring(message.op) .. "): " .. text)
        end
    end
end

local function isMasterMessage(message)
    if message.master == true then
        return true
    end
    return message.op == "hello" and message.role ~= "worker"
end

local function rememberMaster(message)
    local sender = tonumber(message.from)
    if sender and sender ~= computerId then
        masterId = sender
    end
    if type(message.version) == "string" and message.version ~= "" then
        if message.version ~= VERSION then
            versionWarning = "version mismatch: master " .. message.version .. " vs crafter " .. VERSION
            if lastVersionWarning ~= versionWarning then
                lastVersionWarning = versionWarning
                crafterLog(versionWarning .. " - put the same build on master and turtle")
            end
        else
            versionWarning = nil
        end
    end
    lastMasterAt = os.epoch("utc")
    masterOnline = true
end

local function readInventory()
    local items = {}
    for slot = 1, INVENTORY_SLOTS do
        local count = turtle.getItemCount(slot)
        if count and count > 0 then
            local detail = turtle.getItemDetail(slot)
            items[#items + 1] = {
                slot = slot,
                name = detail and detail.name or nil,
                count = count,
                nbt = detail and detail.nbt or nil,
            }
        end
    end
    return items
end

-- Item details are read on demand only: the master asks for specific slots and we
-- answer with what the turtle itself knows (its own getItemDetail is the only
-- place that can tell the stack limit of an item that is not in storage yet).
-- The periodic inventory report stays as cheap as it is (slot/name/count/nbt).
local function readItemDetails(samples)
    local details = {}
    for _, sample in ipairs(type(samples) == "table" and samples or {}) do
        local slot = tonumber(type(sample) == "table" and sample.slot or nil)
        local wantName = type(sample) == "table" and sample.name or nil
        if slot and slot >= 1 and slot <= INVENTORY_SLOTS then
            local ok, detail = pcall(turtle.getItemDetail, slot, true)
            if not ok or type(detail) ~= "table" then
                ok, detail = pcall(turtle.getItemDetail, slot)
            end
            if ok and type(detail) == "table" and type(detail.name) == "string" and detail.name ~= "" and
                (type(wantName) ~= "string" or wantName == "" or wantName == detail.name) then
                details[#details + 1] = {
                    slot = slot,
                    name = detail.name,
                    nbt = type(sample) == "table" and sample.nbt or nil,
                    detail = {
                        name = detail.name,
                        displayName = detail.displayName,
                        maxCount = tonumber(detail.maxCount),
                        tags = detail.tags,
                    },
                }
            end
        end
    end
    return details
end

local function reportInventory()
    local items = readInventory()
    inventoryStacks = #items
    inventoryReportAt = os.epoch("utc")
    reply({
        op = "inventory",
        name = selfName or workerName,
        label = workerName,
        items = items,
        size = INVENTORY_SLOTS,
        at = inventoryReportAt,
        busy = busy,
        crafts = craftCalls,
        target = masterId,
    })
end

local function runCraft()
    if busy then
        return
    end
    if not craftSupported then
        lastCraftError = "turtle.craft is missing - this is not a CRAFTING turtle (upgrade it with a crafting table)"
        crafterLog("craft refused: " .. tostring(lastCraftError))
        return
    end
    busy = true
    local ok, crafted = pcall(turtle.craft, CRAFT_LIMIT)
    busy = false
    craftCalls = craftCalls + 1
    lastCraftAt = os.epoch("utc")
    if ok then
        lastCraftError = nil
        crafterLog("craft(" .. tostring(CRAFT_LIMIT) .. ") -> " .. tostring(crafted))
    else
        lastCraftError = tostring(crafted)
        crafterLog("craft(" .. tostring(CRAFT_LIMIT) .. ") failed: " .. tostring(crafted))
    end
    reportInventory()
end

local function handleMessage(message)
    if type(message) ~= "table" or message.proto ~= PROTOCOL or message.from == computerId then
        return
    end
    if message.target ~= nil and message.target ~= computerId and message.target ~= selfName then
        return
    end
    if not isMasterMessage(message) then
        return
    end
    rememberMaster(message)
    local op = message.op
    if op == "hello" then
        reply({ op = "pong", name = selfName or workerName, label = workerName, version = VERSION,
            busy = busy, crafts = craftCalls, target = masterId })
        return
    end
    if op == "ping" then
        reply({ op = "crafter_here", name = selfName or workerName, label = workerName,
            version = VERSION, busy = busy, crafts = craftCalls, target = masterId })
        return
    end
    if op == "craft" then
        requestCount = requestCount + 1
        lastRequestId = message.id
        lastRequestAt = os.epoch("utc")
        crafterLog("craft request #" .. tostring(message.id or "?") .. " from master #" ..
            tostring(masterId or "?") .. " -> turtle.craft(" .. tostring(CRAFT_LIMIT) .. ")")
        runCraft()
        return
    end
    if op == "inventory_request" then
        reportInventory()
        return
    end
    if op == "detail_request" then
        requestCount = requestCount + 1
        lastRequestId = message.id
        lastRequestAt = os.epoch("utc")
        local details = readItemDetails(message.samples)
        reply({
            op = "detail_result",
            id = message.id,
            name = selfName or workerName,
            label = workerName,
            version = VERSION,
            busy = busy,
            crafts = craftCalls,
            target = masterId,
            details = details,
            at = os.epoch("utc"),
        })
        return
    end
end

local function reportState()
    reply({ op = "hello", name = selfName or workerName, netName = selfName, label = workerName,
        version = VERSION, busy = busy, crafts = craftCalls })
end

local lastDrawAt = 0
local function redraw(force)
    local lines = {
        "IFM turtle crafter",
        "name     : " .. tostring(workerName) .. "  (#" .. tostring(computerId) .. ")",
        "network  : " .. tostring(selfName or "(no wired modem - master can only use my id)"),
        "modem    : " .. tostring(modemSide or "?") .. "   channel: " .. tostring(channel),
        "master   : " .. (masterOnline and ("#" .. tostring(masterId or "?")) or "waiting..."),
        "state    : " .. (busy and "CRAFTING" or "idle") .. "   craft(" .. tostring(CRAFT_LIMIT) .. ")",
        "crafts   : " .. tostring(craftCalls),
        "requests : " .. tostring(requestCount) .. (requestCount > 0
            and ("   last #" .. tostring(lastRequestId or "?") .. "   " ..
                tostring(math.max(0, math.floor((os.epoch("utc") - lastRequestAt) / 1000))) .. "s ago")
            or "   (none received yet - master has not asked)"),
        "inv      : " .. tostring(inventoryStacks) .. " stack(s)   " .. (inventoryReportAt > 0
            and ("reported " .. tostring(math.max(0, math.floor((os.epoch("utc") - inventoryReportAt) / 1000))) .. "s ago")
            or "never reported"),
    }
    if lastCraftError then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "last craft error: " .. tostring(lastCraftError)
        lines[#lines + 1] = "materials are probably stuck in my inventory - fix the process"
    end
    if versionWarning then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: " .. tostring(versionWarning)
        lines[#lines + 1] = "put the same build (IFMMaster.lua / IFMCrafter.lua) on both computers"
    end
    if not craftSupported then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: turtle.craft is missing - this is NOT a crafting turtle"
        lines[#lines + 1] = "upgrade it with a crafting table, otherwise it cannot craft at all"
    end
    local text = table.concat(lines, "\n")
    if not force and text == lastText.value then
        return
    end
    lastText.value = text
    term.clear()
    term.setCursorPos(1, 1)
    for _, line in ipairs(lines) do
        print(line)
    end
end

local function tick(now)
    if now - helloAt >= HELLO_INTERVAL * 1000 then
        helloAt = now
        reportState()
    end
    if masterOnline and now - lastMasterAt > MASTER_TIMEOUT * 1000 then
        masterOnline = false
        crafterLog("master silent for " .. tostring(MASTER_TIMEOUT) .. "s - waiting for it")
    end
    if inventoryStacks > 0 and now - inventoryReportAt >= INVENTORY_REPORT_INTERVAL * 1000 then
        reportInventory()
    end
    if now - lastDrawAt >= 1000 then
        lastDrawAt = now
        redraw(false)
    end
end

redraw(true)
crafterLog("IFM crafter started: name=" .. tostring(workerName) .. " network=" .. tostring(selfName or "?") ..
    " channel=" .. tostring(channel))
reportState()

local function mainLoop()
    local timerToken = os.startTimer(0.2)
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        if event == "modem_message" then
            if tonumber(param2) == channel then
                handleMessage(param4)
            end
        elseif event == "timer" and param1 == timerToken then
            timerToken = os.startTimer(0.2)
            tick(os.epoch("utc"))
        end
    end
end

busy = false
mainLoop()
