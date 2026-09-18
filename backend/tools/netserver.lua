--[[
    netserver.lua - NetSync 服务端
    通过 modem 定期广播自己, 供同名客户端发现并下载文件(同名文件覆盖)

    用法:
      netserver [--update] <name>

    参数:
      --update  可选; 指定时版本号 +1, 然后对外提供服务
      <name>    服务端名称, 仅允许字母 / 数字 / 下划线 / 连字符

    目录结构:
      /netsync/<name>/           同步根目录, 该目录下所有文件(含子目录)都会下发给客户端
      /netsync/<name>.version    版本号文件(位于同步根目录之外, 不会下发)

    下发规则: 不做任何过滤 —— 同步根目录下的**所有文件与子目录**都会递归下发,
    包括以 "." 开头的隐藏项、服务端脚本自身、*.version、rom/ 与 disk/。
    注意: 别把客户端自己的状态目录(客户端的 /.netsync)放进同步根目录, 否则会被下发给所有客户端。

    多客户端:
      - 每个客户端的请求各自排队, 服务端**轮转**处理(每个 tick 服务若干次),
        所以多个 netsync 同时下载时都能稳定推进, 不会有谁被饿死
      - 同一个网络里**不允许存在同名服务端**: 收到别人的同名广播时会报错退出
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
local DATA_ROOT = "/netsync"        -- 服务端数据根目录
local ID_CHANNEL_MOD = 65500        -- 电脑 ID 通道取模(保证通道号在 0-65535 内)
local MAX_SERVES_PER_TICK = 6       -- 每个 tick 最多回复多少个请求(公平轮转)
local CLIENT_TIMEOUT_MS = 60000     -- 客户端队列的保活时间(超过就丢掉它的统计)

-- ==========================================
-- 通用工具
-- ==========================================

local function usage()
    print("NetSync server")
    print("usage: netserver [--update] <name>")
    print("  --update  bump the version number, then start serving")
    print("  <name>    server name (letters / digits / underscore / hyphen only)")
    print("example: netserver --update alpha")
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


-- 递归收集同步根目录下的所有文件(含子目录/隐藏项), 返回 { {path = "a/b.lua", size = 123}, ... }
-- 1.6.16 起不再做任何过滤: 目录里有什么就下发什么(见文件头说明)
local function collectFiles(root)
    local files = {}
    local function walk(dir, prefix)
        local entries = fs.list(dir)
        table.sort(entries)
        for _, entry in ipairs(entries) do
            local abs = fs.combine(dir, entry)
            local rel = (prefix == "") and entry or (prefix .. "/" .. entry)
            if fs.isDir(abs) then
                walk(abs, rel)
            else
                files[#files + 1] = { path = rel, size = fs.getSize(abs) or 0 }
            end
        end
    end
    if fs.exists(root) and fs.isDir(root) then
        walk(root, "")
    end
    return files
end

-- 把客户端给出的相对路径解析为同步根目录内的绝对路径(阻止 ../ 越界)
local function resolveFile(root, rel)
    if type(rel) ~= "string" or rel == "" then
        return nil
    end
    local abs = fs.combine(root, rel)
    if abs:sub(1, #root + 1) ~= root .. "/" then
        return nil
    end
    if not fs.exists(abs) or fs.isDir(abs) then
        return nil
    end
    return abs
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

local root                     -- 同步根目录
local versionPath              -- 版本号文件
local version = 0              -- 当前对外版本号
local modem                    -- modem 外设
local myChannel = 0            -- 本机直连通道
local name = ""                -- 服务端名称

-- 回复文件清单
local function sendList(targetChannel, clientId)
    -- 注意要带上自身路径：正在运行的 netserver 自己不参与同步
    local files = collectFiles(root)
    modem.transmit(targetChannel, myChannel, {
        ns = PROTOCOL,
        type = "list_reply",
        name = name,
        version = version,
        files = files,
    })
    log("client #%s requested the file list: %d file(s)", tostring(clientId), #files)
    if #files == 0 then
        log("  nothing to distribute: sync root %s is empty (or everything inside it is excluded)", root)
    end
end

-- 回复一个数据块
local function sendFile(targetChannel, clientId, rel, offset)
    local abs = resolveFile(root, rel)
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
local update = false
name = nil
for _, value in ipairs(args) do
    if value == "--update" then
        update = true
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

root = fs.combine(DATA_ROOT, name)
versionPath = fs.combine(DATA_ROOT, name .. ".version")


-- 首次运行时创建同步根目录(只创建, 不删除任何文件)
if not fs.exists(root) then
    fs.makeDir(root)
    log("created the sync root directory: %s", root)
end

version = readVersion(versionPath)
if update then
    version = version + 1
    log("version bumped to %d", version)
end
writeVersion(versionPath, version)

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

local fileCount = #collectFiles(root)
log("server started: name=%s version=%d local channel=%d", name, version, myChannel)
log("sync root: %s (%d file(s))", root, fileCount)
if fileCount == 0 then
    log("note: the sync root is empty - put the files you want to distribute into it")
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
