local PROTOCOL = "netsync"
local ANNOUNCE_CHANNEL = 55561
local CHUNK_SIZE = 4096
local STATE_DIR = "/.netsync"
local SERVER_ROOT = "/netsync"
local ID_CHANNEL_MOD = 65500
local REPLY_TIMEOUT = 5
local MAX_TOTAL_BYTES = 4 * 1024 * 1024

local name = ""
local modem = nil
local myChannel = 0
local version = 0

local function usage()
    print("NetSync client")
    print("usage: netsync <name>")
    print("  <name>  server name (letters / digits / underscore / hyphen only)")
    print("example: netsync alpha")
end

local function validName(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

local function idChannel(id)
    return id % ID_CHANNEL_MOD
end

local function humanSize(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return string.format("%.2fMB", bytes / 1024 / 1024)
    end
    if bytes >= 1024 then
        return string.format("%.1fKB", bytes / 1024)
    end
    return tostring(bytes) .. "B"
end

local progressRow = nil

local function progressDone()
    if progressRow then
        term.setCursorPos(1, progressRow)
        progressRow = nil
        term.write("\n")
    end
end

local function log(fmt, ...)
    progressDone()
    print("[NetSync] " .. string.format(fmt, ...))
end

local function progress(index, total, path, percent)
    if not progressRow then
        progressRow = select(2, term.getCursorPos())
    end
    local width = term.getSize()
    local line = string.format("[%d/%d] %3d%% %s", index, total, math.floor(percent + 0.5), path)
    if #line > width - 1 then
        line = line:sub(1, math.max(width - 1, 8))
    end
    term.setCursorPos(1, progressRow)
    term.clearLine()
    term.write(line)
end

local function detachModem(reason)
    if modem then
        pcall(function()
            modem.close(ANNOUNCE_CHANNEL)
            modem.close(myChannel)
        end)
        log("released modem(%s): %s", tostring(reason or "detach"), tostring(modemSide or "?"))
    end
    modem = nil
    modemSide = nil
end

local function attachModem()
    local found, side = peripheral.find("modem")
    if not found then
        return false
    end
    if modem and modem == found then
        return true
    end
    detachModem("switch")
    modem, modemSide = found, side
    myChannel = idChannel(os.getComputerID())
    modem.open(ANNOUNCE_CHANNEL)
    modem.open(myChannel)
    log("modem ready: %s  local channel=%d", tostring(side), myChannel)
    return true
end

local function handlePeripheralEvent(event, side)
    if event ~= "peripheral" and event ~= "peripheral_detach" then
        return false
    end
    if event == "peripheral_detach" then
        if modem and side == modemSide then
            detachModem("unplugged")
            log("modem unplugged, waiting for it to be plugged back in...")
            return true
        end
        return false
    end
    if not modem and peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
        if attachModem() then
            return true
        end
    end
    return false
end

local function pumpEvents(handler)
    while true do
        local event, p1, p2, p3, p4 = os.pullEvent()
        if handlePeripheralEvent(event, p1) then
            return nil, "peripheral"
        end
        local result, signal = handler(event, p1, p2, p3, p4)
        if result ~= nil then
            return result, signal
        end
        if signal ~= nil then
            return nil, signal
        end
    end
end

local function versionPath()
    return fs.combine(STATE_DIR, name .. ".version")
end

local function readLocalVersion()
    local path = versionPath()
    if not fs.exists(path) then
        return 0
    end
    local file = fs.open(path, "r")
    if not file then
        return 0
    end
    local text = file.readAll() or ""
    file.close()
    return tonumber(text) or 0
end

local function saveLocalVersion(newVersion)
    fs.makeDir(STATE_DIR)
    local file = fs.open(versionPath(), "w")
    if not file then
        error("cannot write version file: " .. versionPath(), 0)
    end
    file.write(tostring(newVersion))
    file.close()
end

local function waitForAnnounce()
    return pumpEvents(function(event, p1, p2, p3, p4)
        if event ~= "modem_message" or type(p4) ~= "table" or not modem then
            return nil
        end
        local message = p4
        if message.ns == PROTOCOL
            and message.name == name
            and message.type == "announce"
            and type(message.version) == "number"
            and message.version > version then
            return { id = message.id, version = message.version, channel = p3 }
        end
        return nil
    end)
end

local function waitForReply(predicate, timeout)
    local timer = os.startTimer(timeout)
    return pumpEvents(function(event, p1, p2, p3, p4)
        if event == "modem_message" and type(p4) == "table" and modem then
            if p4.ns == PROTOCOL and p4.name == name and predicate(p4) then
                return p4
            end
        elseif event == "timer" and p1 == timer then
            return nil, "timeout"
        end
        return nil
    end)
end

local function requestList(server)
    local attempt = 0
    while true do
        attempt = attempt + 1
        modem.transmit(server.channel, myChannel, {
            ns = PROTOCOL,
            type = "list_request",
            name = name,
            id = os.getComputerID(),
            version = server.version,
        })
        local reply = waitForReply(function(message)
            return message.type == "list_reply" and message.version == server.version
        end, REPLY_TIMEOUT)
        if reply and type(reply.files) == "table" then
            return reply.files
        end
        log("failed to request the file list (attempt %d), retrying...", attempt)
    end
end

local function resolveDest(rel)
    if type(rel) ~= "string" or rel == "" then
        return nil
    end
    if rel:sub(1, 1) == "/" or rel:find("%.%.") then
        return nil
    end
    return fs.combine("/", rel)
end

local function fetchFile(server, entry, index, total)
    local size = entry.size or 0
    if size <= 0 then
        return ""
    end
    local parts = {}
    local written = 0
    while written < size do
        local data = nil
        while not data do
            if not modem then
                log("modem disconnected, aborting this sync (disk untouched)")
                return nil
            end
            modem.transmit(server.channel, myChannel, {
                ns = PROTOCOL,
                type = "file_request",
                name = name,
                id = os.getComputerID(),
                version = server.version,
                path = entry.path,
                offset = written,
            })
            local reply = waitForReply(function(message)
                return message.type == "file_reply"
                    and message.version == server.version
                    and message.path == entry.path
                    and message.offset == written
            end, REPLY_TIMEOUT)
            if reply and type(reply.data) == "string" and reply.data ~= "" then
                data = reply.data
            else
                log("download of %s at offset %d failed, retrying...", entry.path, written)
            end
        end
        parts[#parts + 1] = data
        written = written + #data
        progress(index, total, entry.path, written / size * 100)
    end
    return table.concat(parts)
end

local function fetchAll(server, files)
    local blobs = {}
    for index, entry in ipairs(files) do
        local blob = fetchFile(server, entry, index, #files)
        if not blob then
            return nil
        end
        blobs[index] = blob
    end
    progressDone()
    return blobs
end

local function writeAll(files, blobs)
    local writtenCount, skipped = 0, 0
    for index, entry in ipairs(files) do
        local dest = resolveDest(entry.path)
        local dir = dest and fs.getDir(dest) or ""
        if not dest then
            log("skipping unsafe path: %s", tostring(entry.path))
            skipped = skipped + 1
        elseif dir ~= "" and fs.exists(dir) and fs.getDrive(dir) == "rom" then
            log("skipping read-only path: %s", entry.path)
            skipped = skipped + 1
        else
            local ok, err = pcall(function()
                fs.makeDir(dir)
                local handle, openErr = fs.open(dest, "w")
                if not handle then
                    error(tostring(openErr or "cannot open file"), 0)
                end
                handle.write(blobs[index] or "")
                handle.close()
            end)
            if not ok then
                log("writing %s failed: %s", tostring(dest), tostring(err))
                return false
            end
            writtenCount = writtenCount + 1
        end
    end
    log("wrote %d file(s) (skipped %d)", writtenCount, skipped)
    return true
end

local function syncFrom(server)
    log("sync: server #%s version %d, local version %d",
        tostring(server.id), server.version, version)
    local files = requestList(server)
    if not files then
        log("failed to get the file list")
        return false
    end
    if #files == 0 then
        log("server returned 0 files: its sync root (%s/%s) is empty, or everything inside is excluded",
            SERVER_ROOT, name)
        log("nothing downloaded and the version was NOT recorded; put the files into the server's sync root, then run 'netserver --update %s'", name)
        return false
    end
    local totalBytes = 0
    for _, entry in ipairs(files) do
        totalBytes = totalBytes + (entry.size or 0)
    end
    if totalBytes > MAX_TOTAL_BYTES then
        log("sync payload %s exceeds the memory limit %s, aborted (raise MAX_TOTAL_BYTES in this script if needed)",
            humanSize(totalBytes), humanSize(MAX_TOTAL_BYTES))
        return false
    end
    log("file list: %d file(s), %s total; everything is downloaded into memory first and written to disk only afterwards", #files, humanSize(totalBytes))

    local blobs = fetchAll(server, files)
    if not blobs then
        log("download incomplete: disk untouched (no file written), version unchanged")
        return false
    end

    if not writeAll(files, blobs) then
        log("writing to disk failed (file in use / disk full?), version unchanged")
        return false
    end

    saveLocalVersion(server.version)
    return true
end

local args = { ... }
name = args[1]

if not validName(name) then
    usage()
    error("missing or invalid <name>", 0)
end

version = readLocalVersion()
log("client started: name=%s local version=%d local channel=%d", name, version, idChannel(os.getComputerID()))

if not attachModem() then
    log("no modem found yet, waiting for one to be plugged in (hot-plug supported)...")
end

while true do
    while not modem do
        local event, p1 = os.pullEvent()
        handlePeripheralEvent(event, p1)
    end

    log("waiting for a server broadcast...")
    local server, signal = waitForAnnounce()
    if signal == "peripheral" then
        log("modem state changed, restarting...")
    elseif server then
        log("found server #%s: version %d > local version %d", tostring(server.id), server.version, version)
        if syncFrom(server) then
            version = server.version
            log("sync complete: version %d recorded in %s", version, versionPath())
            log("rebooting...")
            os.reboot()
        else
            log("sync failed, retrying after the next broadcast...")
        end
    end
end
