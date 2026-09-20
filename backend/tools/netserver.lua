--[[
    netserver.lua - NetSync 服务端
    通过 modem 定期广播自己, 供同名客户端发现并下载文件(同名文件覆盖)

    用法:
      netserver <name>

    参数:
      <name>    服务端名称, 仅允许字母 / 数字 / 下划线 / 连字符

    版本号(1.6.19 起全自动): 启动时先把同步范围内的所有文件内容算一遍哈希, 和上次记录的
      哈希( /netsync/<name>.hash )不一致就把版本号 +1 并写回, 一致就保持不动。
      因此不再需要 --update(传了会报错提醒); 客户端只在版本号变大时才来下载。

    同步范围(1.6.17 起): 不再固定同步某个目录, 而是读脚本同目录下的两个文件:
      syncinclude.txt   每行一个路径, 要同步的内容(目录末尾写 "/", 会递归)
      syncignore.txt    每行一个路径, 要忽略的内容(目录带不带 "/" 都行)
      绝对路径以文件系统根目录 "/" 为起点, 与脚本放在哪里无关(例: "/ifm/" 就是根目录下的
      ifm/, 不会变成"脚本目录/ifm/"); 相对路径才相对本脚本所在目录。
      "#" 开头的行是注释, 空行忽略。两个文件必须存在, 缺哪个就创建哪个(空文件)并报错。

    客户端上的落点: 服务端绝对路径去掉开头的 "/" 就是客户端上的路径 ——
      例: include 写 "ifm/" (脚本在根目录时即 /ifm/) -> 客户端写出 /ifm/IFMMaster.lua 等。
    注意: 别把客户端自己的状态目录(客户端的 /.netsync)包含进来, 否则会覆盖所有客户端的状态。

    状态文件:
      /netsync/<name>.version    版本号文件(netserver 自己管理, 与同步范围无关)

    多客户端:
      - 每个客户端的请求各自排队, 服务端轮转处理(每个 tick 服务若干次),
        所以多个 netsync 同时下载时都能稳定推进, 不会有谁被饿死
      - 同一个网络里不允许存在同名服务端: 收到别人的同名广播时会报错退出
        (两边同时广播时, 电脑 ID 较大的一方退出, 让 ID 小的继续服务)

    协议:
      - 广播频道 42001, 间隔 5 秒, 消息内 ns = "netsync" 用于过滤其他程序的消息
      - 直连回复使用通道 os.getComputerID() % 65500 (与 rednet 一致的做法)
      - 消息类型: announce / list_request / list_reply / file_request / file_reply
      - 文件按 4096 字节分块传输, 每块带 offset, 客户端断点或重试都很方便
--]]

local PROTOCOL = "netsync"          -- 消息协议标识
local ANNOUNCE_CHANNEL = 42001      -- 广播发现频道
local ANNOUNCE_INTERVAL = 5         -- 广播间隔(秒)
local CHUNK_SIZE = 4096             -- 单个数据块大小(字节)
local DATA_ROOT = "/netsync"        -- 服务端状态目录(只放 <name>.version)
local INCLUDE_FILE = "syncinclude.txt"  -- 同步范围(放在脚本同目录)
local IGNORE_FILE = "syncignore.txt"    -- 忽略范围(放在脚本同目录)
local HASH_SUFFIX = ".hash"             -- 内容哈希记录文件(/netsync/<name>.hash)
local ID_CHANNEL_MOD = 65500        -- 电脑 ID 通道取模(保证通道号在 0-65535 内)
local MAX_SERVES_PER_TICK = 6       -- 每个 tick 最多回复多少个请求(公平轮转)
local CLIENT_TIMEOUT_MS = 60000     -- 客户端队列的保活时间(超过就丢掉它的统计)

-- ==========================================
-- 通用工具
-- ==========================================

local function usage()
    print("NetSync server")
    print("usage: netserver <name>")
    print("  <name>    server name (letters / digits / underscore / hyphen only)")
    print("example: netserver alpha")
    print("  the version number is bumped automatically when the synced files change")
end

-- 校验名称, 避免路径分隔符等字符混入目录名
local function validName(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

-- 电脑 ID -> 直连通道(直接把电脑 ID 当通道号在 ID 较大时会越界)
local function idChannel(id)
    return id % ID_CHANNEL_MOD
end

local function log(fmt, ...)
    print("[NetSync] " .. string.format(fmt, ...))
end

-- ==========================================
-- 版本号
-- ==========================================

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

-- ==========================================
-- 同步根目录
-- ==========================================


-- ==========================================
-- 同步范围: syncinclude.txt / syncignore.txt
-- ==========================================

-- 脚本自己所在目录(两个配置文件都放这里)
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

-- 两个配置文件都必须在; 缺哪个就创建哪个(空文件), 然后报错让用户填好再启动
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

-- 逐行解析: 跳过空行与 "#" 注释; 目录标记(末尾 "/")与相对路径都按脚本目录解析
local function parsePaths(text, dir, kind)
    local out = {}
    for line in text:gmatch("[^\r\n]+") do
        local value = line:gsub("^%s+", ""):gsub("%s+$", "")
        if value ~= "" and value:sub(1, 1) ~= "#" then
            local isDir = value:sub(-1) == "/"
            local raw = isDir and value:sub(1, -2) or value
            if raw ~= "" then
                --- 以 "/" 开头的行是绝对路径: 从文件系统根目录开始, 与脚本位置无关
                --- (1.6.19 修正: 以前先 fs.combine 再判断, "/ifm/" 可能被解析成"脚本目录/ifm/")
                local abs
                if value:sub(1, 1) == "/" then
                    abs = fs.combine(raw)
                    if abs:sub(1, 1) ~= "/" then
                        abs = "/" .. abs
                    end
                else
                    abs = fs.combine(dir, raw)          -- 相对路径: 相对 netserver 脚本所在目录
                end
                out[#out + 1] = { kind = kind, raw = value, path = fs.combine(abs), isDir = isDir }
            end
        end
    end
    return out
end

local includeEntries = {}     -- syncinclude.txt 解析结果
local ignoreEntries = {}      -- syncignore.txt 解析结果
local index = {}              -- 客户端路径 -> 服务端绝对路径(每次扫描时刷新)

-- 这个绝对路径是否被 ignore 命中(同路径, 或在被忽略的目录里)
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

-- 按 include 列表扫描: 目录递归, 文件单个; ignore 命中的跳过。
-- 返回 (排序后的清单 { {path = 客户端路径, size = 字节数}, ... }, 不存在的 include 路径)
-- 同时刷新 index(客户端路径 -> 服务端绝对路径)
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

-- 客户端请求的路径 -> 服务端绝对路径(只允许 include 扫描出来的条目)
local function resolveFile(clientPath)
    if type(clientPath) ~= "string" or clientPath == "" then
        return nil
    end
    local abs = index[clientPath]
    if not abs then
        scanIncludes()                  -- 可能刚加了文件: 刷新一次再找
        abs = index[clientPath]
    end
    if not abs or not fs.exists(abs) or fs.isDir(abs) then
        return nil
    end
    return abs
end

-- ==========================================
-- 内容哈希（自动判断要不要把版本号 +1）
-- ==========================================

-- 简易 32 位滚动哈希：CC:T 的 Lua 没有 sha/md5，这里只用加/乘/取模，不需要位运算
local function hashText(hash, text)
    for i = 1, #text do
        hash = (hash * 31 + text:byte(i)) % 4294967296
    end
    return hash
end

-- 同步范围内所有内容(路径 + 大小 + 文件内容)的哈希；按 4KB 分块读，不把大文件整个塞进内存
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

-- 从文件的 offset 位置读取最多 count 字节
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

-- ==========================================
-- 请求处理
-- ==========================================

local configDir = "/"          -- 两个配置文件所在目录(netserver 脚本目录)
local versionPath              -- 版本号文件
local hashPath                 -- 内容哈希文件(与 version 同目录)
local version = 0              -- 当前对外版本号
local modem                    -- modem 外设
local myChannel = 0            -- 本机直连通道
local name = ""                -- 服务端名称

-- 回复文件清单(每次请求都按 include/ignore 重新扫描, 这样新增文件不用重启 netserver)
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

-- 回复一个数据块
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
    -- 文件不存在时返回空数据块, 客户端会判定失败并稍后重试
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

-- ==========================================
-- 请求队列(多客户端公平轮转)
-- ==========================================

-- channel -> { id, queue = { request }, served = n, bytes = n, lastServe = ms, lastSeen = ms }
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

-- 收到请求先入队: 这里不做任何阻塞工作, 保证某个客户端不会把别人卡住
local function enqueue(replyChannel, clientId, message)
    if message.type ~= "list_request" and message.type ~= "file_request" then
        return
    end
    local entry = clientOf(replyChannel, clientId)
    entry.queue[#entry.queue + 1] = message
end

-- 丢掉长时间没有动静的客户端队列(避免内存无限增长)
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

-- 取下一个请求: 谁的“上次服务时间”最早就服务谁(轮转, 不会饿死慢的客户端)
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

-- 一个 tick 里服务若干次请求; 返回这次实际服务的数量
local function serveQueues(limit)
    local count = 0
    while count < limit do
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

-- ==========================================
-- Main
-- ==========================================

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

--- 同步范围: 两个配置文件都放在 netserver 脚本同目录; 缺哪个就创建哪个(空文件)并报错
configDir = scriptDir()
local includeText, ignoreText = loadConfigs(configDir)
includeEntries = parsePaths(includeText, configDir, "include")
ignoreEntries = parsePaths(ignoreText, configDir, "ignore")
log("sync config: %s (%d include path(s)) / %s (%d ignore path(s))",
    fs.combine(configDir, INCLUDE_FILE), #includeEntries,
    fs.combine(configDir, IGNORE_FILE), #ignoreEntries)

--- 版本号：把当前同步范围内的所有内容算一遍哈希，和上次记录的不一样就 +1。
--- 这样改了文件直接启动就行，不用再记 --update。
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
log("broadcasting every %d second(s), waiting for clients...", ANNOUNCE_INTERVAL)

announce()
local timer = os.startTimer(ANNOUNCE_INTERVAL)
local pump = os.startTimer(0.05)          -- 请求泵: 每 0.05 秒服务一批排队的请求

while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "timer" and p1 == timer then
        announce()
        timer = os.startTimer(ANNOUNCE_INTERVAL)
        sweepClients(os.epoch("utc"))
    elseif event == "timer" and p1 == pump then
        serveQueues(MAX_SERVES_PER_TICK)
        pump = os.startTimer(0.05)
    elseif event == "modem_message" then
        -- p1 = side, p2 = channel, p3 = replyChannel, p4 = message
        local message = p4
        if type(message) == "table" and message.ns == PROTOCOL and message.name == name then
            if message.type == "announce" and message.id ~= os.getComputerID() then
                -- 同一网络里不允许有同名服务端: 报错退出。
                -- 两边同时广播时让“电脑 ID 较大”的一方退出, 这样只会死一台, 另一台继续服务。
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
                serveQueues(MAX_SERVES_PER_TICK)   -- 收到请求立刻服务一次, 延迟更低
            end
        end
    end
end
