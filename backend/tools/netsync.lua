--[[
    netsync.lua - NetSync 客户端
    通过 modem 连接同名服务端, 把服务端的全部文件下载到本机(同名文件直接覆盖)

    用法:
      netsync <name>

    同步流程(严格按这个顺序):
      1. 抓取服务端文件清单
      2. **把所有文件完整下载到内存**(任何一个文件失败就整体放弃, 磁盘保持原样)
      3. 全部下载成功后才开始写盘(逐文件覆盖, 目录按需创建)
      4. 写盘成功后记录版本号到 /.netsync/<name>.version
      5. 重启整台计算机(os.reboot)

    这样设计的原因: 中途断网 / 文件缺失 / 内存不足时, 不会留下“半个版本”的混合状态 ——
    要么整台机器都是新版本, 要么保持旧版本, 等下一次广播重来。

    其它行为:
      - 监听服务端广播(每 5 秒一次), 只有服务端版本高于本地版本时才真正下载
      - 支持 modem 热插拔: 中途插上 / 拔掉 modem 都会自动重新识别, 不会卡死
      - 只新增/覆盖同名文件, 不会删除本地任何文件

    本地文件:
      /.netsync/<name>.version   本地记录的版本号
                                 (以 "." 开头的目录不会被服务端下发内容覆盖)

    协议(与 netserver.lua 成对):
      - 广播频道 42001, 直连回复使用通道 os.getComputerID() % 65500
      - 文件按 4096 字节分块传输, 每块带 offset, 可断点续传或重试
--]]

local PROTOCOL = "netsync"          -- 消息协议标识
local ANNOUNCE_CHANNEL = 42001      -- 广播发现频道
local CHUNK_SIZE = 4096             -- 单个数据块大小(字节)
local STATE_DIR = "/.netsync"       -- 客户端状态目录
local ID_CHANNEL_MOD = 65500        -- 电脑 ID 通道取模(保证通道号在 0-65535 内)
local REPLY_TIMEOUT = 5             -- 单次请求等待时间(秒)
local MAX_ATTEMPTS = 5              -- 清单 / 数据块的最大重试次数
local MAX_TOTAL_BYTES = 4 * 1024 * 1024   -- 单次同步上限(内容全部要先放进内存)

-- 运行期状态
local name = ""
local modem = nil                   -- 当前使用的 modem(热插拔时会换掉它)
local myChannel = 0
local version = 0

-- ==========================================
-- 通用工具
-- ==========================================

local function usage()
    print("NetSync 客户端")
    print("用法: netsync <name>")
    print("  <name>  服务端名称, 仅允许字母 / 数字 / 下划线 / 连字符")
    print("示例: netsync alpha")
end

-- 校验名称, 避免路径分隔符等字符混入文件名
local function validName(value)
    return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

-- 电脑 ID -> 直连通道(直接把电脑 ID 当通道号在 ID 较大时会越界)
local function idChannel(id)
    return id % ID_CHANNEL_MOD
end

-- 字节数的可读形式(日志里显示同步体积)
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

-- ==========================================
-- 输出(进度行原地刷新)
-- ==========================================

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

-- ==========================================
-- modem 热插拔
-- ==========================================

local function detachModem(reason)
    if modem then
        pcall(function()
            modem.close(ANNOUNCE_CHANNEL)
            modem.close(myChannel)
        end)
        log("已释放 modem(%s): %s", tostring(reason or "detach"), tostring(modemSide or "?"))
    end
    modem = nil
    modemSide = nil
end

-- 找到并初始化 modem: 找不到返回 false(调用方继续等 peripheral 事件)
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
    log("modem 就绪: %s  本机通道=%d", tostring(side), myChannel)
    return true
end

-- 处理热插拔事件: 返回 true 表示这次事件改变了 modem 状态, 调用方应当重新开始
local function handlePeripheralEvent(event, side)
    if event ~= "peripheral" and event ~= "peripheral_detach" then
        return false
    end
    if event == "peripheral_detach" then
        if modem and side == modemSide then
            detachModem("unplugged")
            log("检测到 modem 被拔出, 等待重新插入...")
            return true
        end
        return false
    end
    -- peripheral: 新外设插上(可能是 modem, 也可能是别的外设)
    if not modem and peripheral.isPresent(side) and peripheral.getType(side) == "modem" then
        if attachModem() then
            return true
        end
    end
    return false
end

-- 在等待期间持续处理事件: handler(event, ...) 返回非 nil 时把它当作结果返回
-- 这样 waitForAnnounce / waitForReply 都不需要自己关心热插拔
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

-- ==========================================
-- 本地版本号
-- ==========================================

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
        error("无法写入版本文件: " .. versionPath(), 0)
    end
    file.write(tostring(newVersion))
    file.close()
end

-- ==========================================
-- 事件等待
-- ==========================================

-- 等待服务端广播: 只接受同名且版本高于本地版本的服务端
-- 返回 server 表; modem 被插拔时返回 nil, "peripheral"(调用方重新开始)
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
            -- p3 = 对方在广播里附带的消息回复通道
            return { id = message.id, version = message.version, channel = p3 }
        end
        return nil
    end)
end

-- 等待匹配的直连回复, 超时返回 nil(第二项为 "peripheral" 时同样表示 modem 变了)
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

-- ==========================================
-- 与服务端交互
-- ==========================================

-- 请求文件清单, 失败返回 nil
local function requestList(server)
    for attempt = 1, MAX_ATTEMPTS do
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
        if attempt < MAX_ATTEMPTS then
            log("请求文件清单失败(第 %d 次), 重试中...", attempt)
        end
    end
    return nil
end

-- 相对路径 -> 本地绝对路径(拒绝越界路径)
local function resolveDest(rel)
    if type(rel) ~= "string" or rel == "" then
        return nil
    end
    if rel:sub(1, 1) == "/" or rel:find("%.%.") then
        return nil
    end
    return fs.combine("/", rel)
end

-- 第 2 步: 把服务端的一个文件**完整读进内存**(失败返回 nil, 不碰磁盘)
local function fetchFile(server, entry, index, total)
    local size = entry.size or 0
    if size <= 0 then
        return ""                             -- 空文件
    end
    local parts = {}
    local written = 0
    while written < size do
        local data = nil
        for attempt = 1, MAX_ATTEMPTS do
            if not modem then
                log("modem 已断开, 放弃本次同步(磁盘未改动)")
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
                break
            end
            if attempt < MAX_ATTEMPTS then
                log("下载 %s 偏移 %d 失败(第 %d 次), 重试中...", entry.path, written, attempt)
            end
        end
        if not data then
            progressDone()
            log("下载 %s 失败(已收到 %d/%d 字节)", entry.path, written, size)
            return nil
        end
        parts[#parts + 1] = data
        written = written + #data
        progress(index, total, entry.path, written / size * 100)
    end
    return table.concat(parts)
end

-- 逐个文件下载进内存; 任何一个失败就整体放弃(磁盘一个字节都不动)
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

-- 第 3 步: 全部下载成功之后才开始写盘
local function writeAll(files, blobs)
    local writtenCount, skipped = 0, 0
    for index, entry in ipairs(files) do
        local dest = resolveDest(entry.path)
        local dir = dest and fs.getDir(dest) or ""
        if not dest then
            log("跳过非法路径: %s", tostring(entry.path))
            skipped = skipped + 1
        elseif dir ~= "" and fs.exists(dir) and fs.getDrive(dir) == "rom" then
            -- /rom 只读: 跳过(服务端正常情况下不会下发这里的内容, 这里再兜一层)
            log("跳过只读路径: %s", entry.path)
            skipped = skipped + 1
        else
            local ok, err = pcall(function()
                fs.makeDir(dir)
                local handle, openErr = fs.open(dest, "w")
                if not handle then
                    error(tostring(openErr or "无法打开文件"), 0)
                end
                handle.write(blobs[index] or "")
                handle.close()
            end)
            if not ok then
                log("写入 %s 失败: %s", tostring(dest), tostring(err))
                return false
            end
            writtenCount = writtenCount + 1
        end
    end
    log("写盘完成: %d 个文件(跳过 %d 个)", writtenCount, skipped)
    return true
end

-- 完整同步一次: 清单 -> 下载到内存 -> 写盘 -> 记版本号(顺序不可颠倒)
local function syncFrom(server)
    log("准备同步: 服务端 #%s 版本 %d, 本地版本 %d",
        tostring(server.id), server.version, version)
    local files = requestList(server)
    if not files then
        log("获取文件清单失败")
        return false
    end
    local totalBytes = 0
    for _, entry in ipairs(files) do
        totalBytes = totalBytes + (entry.size or 0)
    end
    if totalBytes > MAX_TOTAL_BYTES then
        log("本次同步内容 %s 超过内存上限 %s, 已放弃(需要的话可调大脚本里的 MAX_TOTAL_BYTES)",
            humanSize(totalBytes), humanSize(MAX_TOTAL_BYTES))
        return false
    end
    log("文件清单: %d 个文件, 共 %s; 先全部下载到内存, 成功后才写盘", #files, humanSize(totalBytes))

    local blobs = fetchAll(server, files)
    if not blobs then
        log("下载未完成, 磁盘保持原样(没有写入任何文件), 版本号也未更新")
        return false
    end

    if not writeAll(files, blobs) then
        log("写盘失败(文件被占用 / 磁盘已满?), 版本号未更新")
        return false
    end

    saveLocalVersion(server.version)
    return true
end

-- ==========================================
-- Main
-- ==========================================

local args = { ... }
name = args[1]

if not validName(name) then
    usage()
    error("缺少或非法的 <name>", 0)
end

version = readLocalVersion()
log("客户端已启动: name=%s 本地版本=%d 本机通道=%d", name, version, idChannel(os.getComputerID()))

if not attachModem() then
    log("暂未找到 modem, 等待插入(支持热插拔)...")
end

while true do
    -- modem 不在就只等外设事件, 直到插上为止
    while not modem do
        local event, p1 = os.pullEvent()
        handlePeripheralEvent(event, p1)
    end

    log("等待服务端广播...")
    local server, signal = waitForAnnounce()
    if signal == "peripheral" then
        log("modem 状态发生变化, 重新开始...")
    elseif server then
        log("发现服务端 #%s, 版本 %d > 本地版本 %d", tostring(server.id), server.version, version)
        if syncFrom(server) then
            version = server.version
            log("同步完成, 版本 %d 已记录到 %s", version, versionPath())
            log("重启计算机...")
            sleep(1)
            os.reboot()
        else
            log("本次同步失败, 等待下一次广播后重试...")
            sleep(1)
        end
    end
end
