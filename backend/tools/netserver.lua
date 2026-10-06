local PROTOCOL = "netsync"
local ANNOUNCE_CHANNEL = 55561
local CHUNK_SIZE = 4096
local DATA_ROOT = "/netsync"
local INCLUDE_FILE = "syncinclude.txt"
local IGNORE_FILE = "syncignore.txt"
local HASH_SUFFIX = ".hash"
local ID_CHANNEL_MOD = 65500
local CLIENT_TIMEOUT_MS = 60000

local function usage()
    print("NetSync server")
    print("usage: netserver <name>")
    print("  <name>    server name (letters / digits / underscore / hyphen only)")
    print("example: netserver alpha")
    print("  the version number is bumped automatically when the synced files change")
end

local function validName(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

local function idChannel(id)
    return id % ID_CHANNEL_MOD
end

local function log(fmt, ...)
    print("[NetSync] " .. string.format(fmt, ...))
end

local function readVersion(path)
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

local function writeVersion(path, version)
    fs.makeDir(fs.getDir(path))
    local file = fs.open(path, "w")
    if not file then
        error("cannot write version file: " .. path, 0)
    end
    file.write(tostring(version))
    file.close()
end

local function scriptDir()
    local program = (shell and shell.getRunningProgram and shell.getRunningProgram()) or "netserver.lua"
    if fs.exists(program) then
        local dir = fs.getDir(program)
        return (dir == "") and "/" or dir
    end
    if shell and shell.dir then
        local dir = shell.dir()
        return (dir == "") and "/" or dir
    end
    return "/"
end

local function loadConfigs(dir)
    local texts, missing = {}, {}
    for _, fileName in ipairs({ INCLUDE_FILE, IGNORE_FILE }) do
        local path = fs.combine(dir, fileName)
        if fs.exists(path) then
            local handle = fs.open(path, "r")
            if not handle then
                error("cannot read " .. path, 0)
            end
            texts[fileName] = handle.readAll() or ""
            handle.close()
        else
            local handle = fs.open(path, "w")
            if handle then
                handle.close()
            end
            log("created empty config file: %s", path)
            missing[#missing + 1] = path
        end
    end
    if #missing > 0 then
        error(string.format(
            "config file(s) missing, empty ones were just created: %s; put one path per line into them (in %s) and start netserver again",
            table.concat(missing, ", "), dir), 0)
    end
    return texts[INCLUDE_FILE], texts[IGNORE_FILE]
end

local function parsePaths(text, dir, kind)
    local out = {}
    for line in text:gmatch("[^\r\n]+") do
        local value = line:gsub("^%s+", ""):gsub("%s+$", "")
        if value ~= "" and value:sub(1, 1) ~= "#" then
            local isDir = value:sub(-1) == "/"
            local raw = isDir and value:sub(1, -2) or value
            if raw ~= "" then
                local abs
                if value:sub(1, 1) == "/" then
                    abs = fs.combine(raw)
                    if abs:sub(1, 1) ~= "/" then
                        abs = "/" .. abs
                    end
                else
                    abs = fs.combine(dir, raw)
                end
                out[#out + 1] = { kind = kind, raw = value, path = fs.combine(abs), isDir = isDir }
            end
        end
    end
    return out
end

local includeEntries = {}
local ignoreEntries = {}
local index = {}

local function isIgnored(path)
    for _, item in ipairs(ignoreEntries) do
        if item.path == path then
            return true
        end
        if item.isDir and path:sub(1, #item.path + 1) == item.path .. "/" then
            return true
        end
    end
    return false
end

local function scanIncludes()
    index = {}
    local out = {}
    local missing = {}
    local function add(abs)
        if isIgnored(abs) then
            return
        end
        local clientPath = abs:sub(1, 1) == "/" and abs:sub(2) or abs
        if clientPath == "" or index[clientPath] ~= nil then
            return
        end
        index[clientPath] = abs
        out[#out + 1] = { path = clientPath, size = fs.getSize(abs) or 0 }
    end
    local function walk(dir)
        local entries = fs.list(dir)
        table.sort(entries)
        for _, entry in ipairs(entries) do
            local abs = fs.combine(dir, entry)
            if fs.isDir(abs) then
                if not isIgnored(abs) then
                    walk(abs)
                end
            else
                add(abs)
            end
        end
    end
    for _, item in ipairs(includeEntries) do
        if not fs.exists(item.path) then
            missing[#missing + 1] = item.raw
        elseif fs.isDir(item.path) then
            walk(item.path)
        else
            add(item.path)
        end
    end
    table.sort(out, function(a, b) return a.path < b.path end)
    return out, missing
end

local function resolveFile(clientPath)
    if type(clientPath) ~= "string" or clientPath == "" then
        return nil
    end
    local abs = index[clientPath]
    if not abs then
        scanIncludes()
        abs = index[clientPath]
    end
    if not abs or not fs.exists(abs) or fs.isDir(abs) then
        return nil
    end
    return abs
end

local function hashText(hash, text)
    for i = 1, #text do
        hash = (hash * 31 + text:byte(i)) % 4294967296
    end
    return hash
end

local function computeContentHash(files, index)
    local hash = 2166136261
    hash = hashText(hash, tostring(#files))
    for _, entry in ipairs(files) do
        hash = hashText(hash, entry.path .. "|" .. tostring(entry.size or 0))
        local abs = index[entry.path]
        if abs then
            local handle = fs.open(abs, "r")
            if handle then
                while true do
                    local chunk = handle.read(4096)
                    if chunk == nil or chunk == "" then
                        break
                    end
                    hash = hashText(hash, chunk)
                end
                handle.close()
            end
        end
    end
    return tostring(math.floor(hash))
end

local function readHash(path)
    if not fs.exists(path) then
        return nil
    end
    local handle = fs.open(path, "r")
    if not handle then
        return nil
    end
    local text = (handle.readAll() or ""):gsub("%s+", "")
    handle.close()
    if text == "" then
        return nil
    end
    return text
end

local function writeHash(path, value)
    fs.makeDir(fs.getDir(path))
    local handle = fs.open(path, "w")
    if handle then
        handle.write(tostring(value))
        handle.close()
    end
end

local function readChunk(path, offset, count)
    local file = fs.open(path, "r")
    if not file then
        return nil
    end
    if offset > 0 then
        file.seek("set", offset)
    end
    local data = file.read(count) or ""
    file.close()
    return data
end

local configDir = "/"
local versionPath
local hashPath
local version = 0
local modem
local myChannel = 0
local name = ""

local function sendList(targetChannel, clientId)
    local files, missing = scanIncludes()
    modem.transmit(targetChannel, myChannel, {
        ns = PROTOCOL,
        type = "list_reply",
        name = name,
        version = version,
        files = files,
    })
    log("client #%s requested the file list: %d file(s)", tostring(clientId), #files)
    if #files == 0 then
        log("  nothing to distribute: check %s and %s in %s",
            INCLUDE_FILE, IGNORE_FILE, configDir)
    end
    for _, raw in ipairs(missing) do
        log("  include path not found (skipped): %s", raw)
    end
    if #missing > 0 then
        missing = nil
    end
end

local function sendFile(targetChannel, clientId, rel, offset)
    local abs = resolveFile(rel)
    local data = abs and (readChunk(abs, offset, CHUNK_SIZE) or "") or ""
    if offset == 0 then
        if abs then
            log("client #%s started downloading %s", tostring(clientId), rel)
        else
            log("client #%s asked for a missing file: %s", tostring(clientId), tostring(rel))
        end
    end
    modem.transmit(targetChannel, myChannel, {
        ns = PROTOCOL,
        type = "file_reply",
        name = name,
        version = version,
        path = rel,
        offset = offset,
        data = data,
    })
end

local clients = {}

local function clientOf(channel, clientId)
    local entry = clients[channel]
    if not entry then
        entry = { id = clientId, queue = {}, served = 0, bytes = 0, lastServe = 0 }
        clients[channel] = entry
        log("new client #%s joined (reply channel %d)", tostring(clientId), channel)
    end
    entry.id = clientId or entry.id
    entry.lastSeen = os.epoch("utc")
    return entry
end

local function enqueue(replyChannel, clientId, message)
    if message.type ~= "list_request" and message.type ~= "file_request" then
        return
    end
    local entry = clientOf(replyChannel, clientId)
    entry.queue[#entry.queue + 1] = message
end

local function sweepClients(now)
    for channel, entry in pairs(clients) do
        if entry.queue[1] == nil and now - (entry.lastSeen or now) > CLIENT_TIMEOUT_MS then
            if entry.served > 0 then
                log("client #%s finished: served %d request(s)", tostring(entry.id), entry.served)
            end
            clients[channel] = nil
        end
    end
end

local function nextRequest()
    local chosenChannel, chosenRequest, oldest = nil, nil, nil
    for channel, entry in pairs(clients) do
        if entry.queue[1] ~= nil then
            local lastServe = entry.lastServe or 0
            if oldest == nil or lastServe < oldest then
                oldest, chosenChannel, chosenRequest = lastServe, channel, entry.queue[1]
            end
        end
    end
    if not chosenChannel then
        return nil, nil, nil
    end
    local entry = clients[chosenChannel]
    table.remove(entry.queue, 1)
    entry.lastServe = os.epoch("utc")
    entry.served = entry.served + 1
    return chosenChannel, chosenRequest, entry
end

local function serveQueues()
    local count = 0
    while true do
        local channel, request, entry = nextRequest()
        if not request then
            break
        end
        if request.type == "list_request" then
            sendList(channel, entry.id)
        else
            sendFile(channel, entry.id, request.path, tonumber(request.offset) or 0)
        end
        count = count + 1
    end
    return count
end

local args = { ... }
name = nil
for _, value in ipairs(args) do
    if value:sub(1, 1) == "-" then
        usage()
        error("unknown option: " .. tostring(value) ..
            " (--update is no longer needed: the version is bumped automatically when the synced files change)", 0)
    elseif name == nil then
        name = value
    else
        usage()
        error("too many arguments: " .. tostring(value), 0)
    end
end

if not validName(name) then
    usage()
    error("missing or invalid <name>", 0)
end

versionPath = fs.combine(DATA_ROOT, name .. ".version")
hashPath = fs.combine(DATA_ROOT, name .. HASH_SUFFIX)

configDir = scriptDir()
local includeText, ignoreText = loadConfigs(configDir)
includeEntries = parsePaths(includeText, configDir, "include")
ignoreEntries = parsePaths(ignoreText, configDir, "ignore")
log("sync config: %s (%d include path(s)) / %s (%d ignore path(s))",
    fs.combine(configDir, INCLUDE_FILE), #includeEntries,
    fs.combine(configDir, IGNORE_FILE), #ignoreEntries)

local startupFiles = scanIncludes()
local contentHash = computeContentHash(startupFiles, index)
version = readVersion(versionPath)
local storedHash = readHash(hashPath)
if storedHash ~= contentHash then
    version = version + 1
    writeVersion(versionPath, version)
    writeHash(hashPath, contentHash)
    log("content hash changed (%s -> %s): version bumped to %d",
        tostring(storedHash), tostring(contentHash), version)
else
    writeVersion(versionPath, version)
    log("content hash unchanged (%s): version stays %d", tostring(contentHash), version)
end

modem = peripheral.find("modem")
if not modem then
    error("no modem found: install and connect a wireless/wired modem first", 0)
end

myChannel = idChannel(os.getComputerID())
modem.open(ANNOUNCE_CHANNEL)
modem.open(myChannel)

local function announce()
    modem.transmit(ANNOUNCE_CHANNEL, myChannel, {
        ns = PROTOCOL,
        type = "announce",
        name = name,
        id = os.getComputerID(),
        version = version,
    })
end

local totalBytes = 0
for _, entry in ipairs(startupFiles) do
    totalBytes = totalBytes + (entry.size or 0)
end
log("server started: name=%s version=%d local channel=%d", name, version, myChannel)
log("sync rules matched %d file(s), %d byte(s) in total (see %s / %s in %s)",
    #startupFiles, totalBytes, INCLUDE_FILE, IGNORE_FILE, configDir)
if #startupFiles == 0 then
    log("note: nothing to distribute - put the paths you want to send into %s in %s",
        INCLUDE_FILE, configDir)
end
for _, item in ipairs(includeEntries) do
    log("  include: %s -> %s%s", item.raw, item.path, (not fs.exists(item.path)) and " (NOT FOUND)" or "")
end
for _, item in ipairs(ignoreEntries) do
    log("  ignore : %s -> %s", item.raw, item.path)
end
log("broadcasting continuously (there is no announce interval any more), waiting for clients...")

announce()
local pump = os.startTimer(0.05)

while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "timer" and p1 == pump then
        announce()
        sweepClients(os.epoch("utc"))
        serveQueues()
        pump = os.startTimer(0.05)
    elseif event == "modem_message" then
        local message = p4
        if type(message) == "table" and message.ns == PROTOCOL and message.name == name then
            if message.type == "announce" and message.id ~= os.getComputerID() then
                if tostring(message.id) > tostring(os.getComputerID()) then
                    error(string.format(
                        "another server with the same name already exists: name=%s (computer #%s), this one is #%d; use another name or stop the other computer",
                        name, tostring(message.id), os.getComputerID()), 0)
                else
                    log("same-name server #%s detected (version %s): this computer has the lower ID and keeps serving; the other side should exit",
                        tostring(message.id), tostring(message.version))
                end
            else
                enqueue(p3, message.id, message)
                serveQueues()
            end
        end
    end
end
