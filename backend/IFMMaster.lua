-- IFM (Integrated Factory Manager) :: IFMMaster.lua
-- CC:Tweaked 服务端入口。
-- 用法：IFMMaster.lua [--room <房间号>] [--relay <中转地址前缀>] [--random-room]
--   IFMMaster.lua                       -- 用 config.json 里保存的房间号；没有则随机生成 12 位并写入配置
--   IFMMaster.lua --random-room         -- 强制随机生成一个新房间号并写入配置
--   IFMMaster.lua --room myfactory123   -- 用指定房间号，并写入配置
--   IFMMaster.lua --room myfactory123 --relay ws://localhost:8765/c/
--   IFMMaster.lua --help
-- 房间号保存在 <脚本目录>/data/config.json 的 room 字段里；整个运行期间固定不变
-- （断线重连始终复用同一个 wsUrl），进程重启后也沿用配置里的房间号。
-- 浏览器端：打开 index.html，填入同样的房间号与中转地址即可连接。
-- 注意：终端输出一律使用 ASCII 英文（CC:T 终端字形不含中日韩字符）。

local args = { ... }

--- 版本号：前端 web/ifm-core.js 里的 IFM_CLIENT_VERSION 必须与此保持一致。
--- 网页连上后会比对两边的版本号，不一致时弹出警告并主动停止连接，
--- 避免“新前端 + 旧后端”（或反过来）产生难以定位的怪问题。
local IFM_VERSION = "1.6.16"

local DEFAULT_RELAY = "wss://itty.ws/c/"

--- 生成 12 位随机房间号（同时包含大写字母、小写字母与数字）
local function randomRoom()
    local pools = {
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz",
        "0123456789",
    }
    math.randomseed(os.epoch("utc") + (os.getComputerID() or 0) * 7919)
    local chars = {}
    for _, pool in ipairs(pools) do
        chars[#chars + 1] = pool
    end
    local out = {}
    for index, pool in ipairs(pools) do
        local picked = math.random(1, #pool)
        out[index] = pool:sub(picked, picked)
    end
    local all = table.concat(chars)
    for index = #out + 1, 12 do
        local picked = math.random(1, #all)
        out[index] = all:sub(picked, picked)
    end
    for index = #out, 2, -1 do
        local other = math.random(1, index)
        out[index], out[other] = out[other], out[index]
    end
    return table.concat(out)
end

local function printUsage()
    print("IFM (Integrated Factory Manager) - server")
    print("Usage: IFMMaster.lua [--room <room>] [--relay <ws-base-url>] [--random-room]")
    print("  --room         room name shared with the browser (saved into data/config.json)")
    print("                 (default: the room stored in config.json, else a new random 12-char room)")
    print("  --random-room  ignore the stored room, generate a new random one (saved into config.json)")
    print("  --relay        websocket relay base url (default: " .. DEFAULT_RELAY .. ")")
    print("Examples:")
    print("  IFMMaster.lua")
    print("  IFMMaster.lua --random-room")
    print("  IFMMaster.lua --room myfactory123")
    print("  IFMMaster.lua --room myfactory123 --relay ws://localhost:8765/c/")
    print("Note: the room never changes while this program runs (reconnects reuse it),")
    print("      and it is kept in data/config.json so restarts reuse the same room.")
    print("      --room wins over --random-room.")
end

local room = nil
local relayBase = nil
local forceRandomRoom = false
local unknown = {}
local index = 1
while index <= #args do
    local value = tostring(args[index] or "")
    if value == "--help" or value == "-h" then
        printUsage()
        return
    elseif value == "--room" then
        room = args[index + 1]
        index = index + 2
    elseif value:sub(1, 7) == "--room=" then
        room = value:sub(8)
        index = index + 1
    elseif value == "--relay" then
        relayBase = args[index + 1]
        index = index + 2
    elseif value:sub(1, 8) == "--relay=" then
        relayBase = value:sub(9)
        index = index + 1
    elseif value == "--random-room" then
        forceRandomRoom = true
        index = index + 1
    elseif value == "--relay-via-worker" then
        -- 1.5.0：中继永远由主控自己连接（IFMWorker 不再承担 WebSocket），这个开关已无作用
        print("note: --relay-via-worker was removed in 1.5.0 - the server always connects the relay itself")
        index = index + 1
    else
        unknown[#unknown + 1] = value
        index = index + 1
    end
end

-- 兼容旧的 `ifm <room>` 写法
if (not room or room == "") and #unknown == 1 and unknown[1]:sub(1, 1) ~= "-" then
    room = unknown[1]
    unknown = {}
    print("[IFM] note: positional room argument is deprecated, use --room <room>")
end

--- 定位脚本目录：**代码**在 <脚本目录>/ifm/，**数据**在 <脚本目录>/data/（1.6.16 起）
--- 以前 config.json / cache.json 和代码混在 ifm/ 里，升级时会自动把老数据搬到 data/（只搬一次）
local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMMaster.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "ifm")
local legacyDataDir = moduleDir
local dataDir = fs.combine(baseDir, "data")

for _, value in ipairs(unknown) do
    print("[IFM] warning: unknown argument ignored: " .. tostring(value))
end

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path, 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

local Util = loadModule("util")
local log = Util.makeLogger("IFM", true)
--- 磁盘读写（config.json / cache.json）：读 / 原子写 / 去抖都在 ifm/jsonfile.lua
local JsonFile = loadModule("jsonfile")
--- modem 发现与包装：与 IFMWorker.lua 共用（worker 不再自带一份）
local Modems = loadModule("modems")

local Scheduler = loadModule("scheduler")
local Filter = loadModule("filter")
local Store = loadModule("store")
local Cache = loadModule("cache")
local Peripherals = loadModule("peripherals")
local Containers = loadModule("containers")
local Recipe = loadModule("recipe")
local Diagnose = loadModule("diagnose")
local Protocol = loadModule("protocol")
local Transfer = loadModule("transfer")

if not fs.exists(dataDir) then
    fs.makeDir(dataDir)
end

--- 一次性迁移：老版本的 config.json / cache.json 放在 ifm/ 里，
--- 这里在 data/ 还没有对应文件时把它复制过来（复制成功后再删掉老文件；删不掉也无妨）。
local function migrateLegacyData(fileName)
    local target = fs.combine(dataDir, fileName)
    local legacy = fs.combine(legacyDataDir, fileName)
    if fs.exists(target) or not fs.exists(legacy) then
        return false
    end
    local handle = fs.open(legacy, "r")
    if not handle then
        return false
    end
    local text = handle.readAll() or ""
    handle.close()
    local out = fs.open(target, "w")
    if not out then
        return false
    end
    out.write(text)
    out.close()
    pcall(fs.delete, legacy)
    log("Migrated data file %s -> %s", legacy, target)
    return true
end
migrateLegacyData("config.json")
migrateLegacyData("cache.json")
local configPath = fs.combine(dataDir, "config.json")
local cachePath = fs.combine(dataDir, "cache.json")

--- 组装模块
local scheduler = Scheduler.new()
local store = Store.new({
    Util = Util,
    JsonFile = JsonFile,
    path = configPath,
    log = log,
    writeDebounce = 3,
})
local cache = Cache.new({
    Util = Util,
    JsonFile = JsonFile,
    path = cachePath,
    log = log,
    writeDebounce = 3,
})
local filter = Filter.new({
    Util = Util,
    Store = store,
    -- 标签只在用户按需触发扫描后才会出现在缓存里，热路径不调用 getItemDetail
    tagProvider = function(name)
        return cache:tagsOf(name)
    end,
})
local peripherals = Peripherals.new({
    Util = Util,
    log = log,
})
local containers = Containers.new({
    Util = Util,
    Store = store,
    Peripherals = peripherals,
    Filter = filter,
    log = log,
})
local engine = Recipe.new({
    Util = Util,
    Store = store,
    Cache = cache,
    Peripherals = peripherals,
    Containers = containers,
    Filter = filter,
    log = log,
})
--- 诊断模块（网页点「诊断」或控制台调用时使用；只读，不写文件）
local diagnose = Diagnose.new({
    Util = Util,
    Store = store,
    Cache = cache,
    Containers = containers,
    Peripherals = peripherals,
    Recipe = engine,
})

--- 读取持久化数据
local configLoaded, configErr = store:load()
if configLoaded then
    log("Loaded config: %s", configPath)
else
    log("No existing config (%s), starting with empty definitions", tostring(configErr))
end
local cacheLoaded, cacheErr = cache:load()
if cacheLoaded then
    log("Restored runtime state: %s", cachePath)
else
    log("No existing runtime state (%s), starting fresh", tostring(cacheErr))
end

--- 容器扫描间隔设置（1.6.11）：存储容器（list 缓存时长）与输入容器（排空扫描节奏）。
--- 网页「设置」面板改完会立刻生效，重启后从 config.json 里的 settings.scan 恢复。
local function applyScanSettings()
    local settings = store:scanSettings()
    containers:applyScanSettings(settings.storageScanMs)
    engine:applyScanSettings(settings.inputScanMs)
    return settings
end
--- 1.6.15：缺省 存储 8000ms（同一容器两次扫描的最小间隔）/ 输入 1000ms
local scanSettings = applyScanSettings()
log("Container scan settings: storage=%dms (min interval between two scans of the same " ..
    "container) input=%dms (input container drain interval) (config.json -> settings.scan)",
    scanSettings.storageScanMs, scanSettings.inputScanMs)

--- 房间号：保存在 config.json 顶层的 room 字段里（不再使用 room.txt）
-- 规则：--room 指定 -> 用它；--random-room -> 随机一个；都没有 -> 用配置里的；配置里没有 -> 随机并写入配置
local function normalizeRoom(value)
    if type(value) ~= "string" then
        return nil
    end
    local trimmed = value:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" or #trimmed > 64 or trimmed:find("%s") then
        return nil
    end
    return trimmed
end

local requestedRoom = normalizeRoom(room)
if room and room ~= "" and requestedRoom == nil then
    print("[IFM] warning: --room value is empty or not usable, ignoring it")
end
local storedRoom = normalizeRoom(store:getRoom())
local roomSource
if requestedRoom then
    room = requestedRoom
    roomSource = "argument"
elseif forceRandomRoom then
    room = randomRoom()
    roomSource = "random"
elseif storedRoom then
    room = storedRoom
    roomSource = "config"
else
    room = randomRoom()
    roomSource = "random"
end

-- 写回配置：进程重启后仍是同一房间号
if store:setRoom(room) then
    log("Room saved to %s", configPath)
end

local roomNote
if roomSource == "config" then
    roomNote = "from " .. configPath
elseif roomSource == "random" then
    roomNote = "random, saved to " .. configPath
else
    roomNote = "from --room argument"
end

relayBase = relayBase or DEFAULT_RELAY
if relayBase:sub(-1) ~= "/" then
    relayBase = relayBase .. "/"
end
--- 本次运行固定使用的连接地址：protocol 断线重连始终复用它，房间号绝不会变化
local wsUrl = relayBase .. room

--- 可合成索引（key = "kind:name"）
local function buildProducerIndex()
    local index = {}
    local function mark(key, processName)
        if not key then
            return
        end
        local bucket = index[key]
        if not bucket then
            bucket = {}
            index[key] = bucket
        end
        bucket[processName] = true
    end
    for _, process in ipairs(store:list("processes")) do
        -- 抽象模板（含虚操作）不参与“可合成”判定：它只是给别人复制设置用的
        if not store.processHasVirtual(process) then
            for _, output in ipairs(process.outputs or {}) do
                if output.kind == "item" then
                    mark("item:" .. output.id, process.name)
                elseif output.kind == "fluid" then
                    mark("fluid:" .. output.id, process.name)
                elseif output.kind == "placeholder" then
                    mark("item:" .. output.item, process.name)
                elseif output.kind == "filter" then
                    mark("filter:" .. output.id, process.name)
                end
            end
        end
    end
    return index
end

--- 物品标签（网页悬停信息与 #标签 搜索用）：只读服务端缓存，缓存里没有就返回 nil。
--- 标签由 processTagQueue 按需补进缓存：先把缺的物品排进队列，再交给 worker 打包代查
--- getItemDetail（没有可用 worker 时才本机读，且每 tick 最多一个）—— 每个物品名只查一次。
local function itemTags(name)
    local cached = cache:tagsOf(name)
    if type(cached) ~= "table" then
        return nil
    end
    local out = {}
    for tag, value in pairs(cached) do
        if value and type(tag) == "string" then
            out[#out + 1] = tag
        end
    end
    if #out == 0 then
        return nil
    end
    table.sort(out)
    return out
end

--- 资源网格：物品 / 流体 / 过滤器 / 占位符
local function collectResources()
    local list = {}
    for _, entry in ipairs(containers:resources()) do
        list[#list + 1] = {
            kind = entry.kind,
            name = entry.name,
            count = entry.count,
            craftable = false,
            samples = {},
            -- 标签只对物品有意义（流体没有 tag），且只在缓存已有时才带上
            tags = entry.kind == "item" and itemTags(entry.name) or nil,
        }
    end
    for _, def in ipairs(store:list("filters")) do
        local samples = {}
        local seen = {}
        local count = 0
        for _, entry in ipairs(containers:filterResources(def.name)) do
            count = count + entry.count
            local key = entry.kind .. ":" .. entry.name
            if not seen[key] then
                seen[key] = true
                samples[#samples + 1] = { kind = entry.kind, name = entry.name }
            end
        end
        list[#list + 1] = {
            kind = "filter",
            name = def.name,
            count = count,
            craftable = false,
            samples = samples,
        }
    end
    local placeholders = {}
    for _, process in ipairs(store:list("processes")) do
        for _, element in ipairs(process.outputs or {}) do
            if element.kind == "placeholder" and element.name and not placeholders[element.name] then
                placeholders[element.name] = {
                    kind = "placeholder",
                    name = element.name,
                    item = element.item,
                    craftable = false,
                    samples = { { kind = "item", name = element.item } },
                }
            end
        end
    end
    for _, entry in pairs(placeholders) do
        list[#list + 1] = entry
    end
    local index = buildProducerIndex()
    for _, entry in ipairs(list) do
        if index[entry.kind .. ":" .. entry.name] then
            entry.craftable = true
        end
    end
    for _, process in ipairs(store:list("processes")) do
        -- 抽象模板（含虚操作）不参与“可合成”判定（与 buildProducerIndex 一致）
        if not store.processHasVirtual(process) then
            for _, output in ipairs(process.outputs or {}) do
                if output.kind == "filter" then
                    for _, entry in ipairs(list) do
                        if entry.kind == "item" or entry.kind == "fluid" then
                            if filter:matches(output.id, { kind = entry.kind, name = entry.name }) then
                                entry.craftable = true
                            end
                        end
                    end
                end
            end
        end
    end
    return list
end

--- 机器清单（附带当前并行占用与可用性）
local function collectMachines()
    local usage = {}
    for _, entry in ipairs(engine:machineUsage()) do
        usage[entry.name] = entry
    end
    local out = {}
    for _, machine in ipairs(store:list("machines")) do
        local entry = Util.deepcopy(machine)
        local use = usage[machine.name]
        entry.running = use and use.running or 0
        entry.usable = engine:machineUsable(machine)
        out[#out + 1] = entry
    end
    return out
end

--- 外设清单（inventory / fluid_storage / redstone_relay 及其定义）
local function collectPeripherals()
    local out = {}
    local function add(kind, name)
        local containerDefs = {}
        for _, def in ipairs(store:list("containers")) do
            if def.peripheral == name then
                containerDefs[#containerDefs + 1] = {
                    name = def.name,
                    role = def.role,
                    kind = Util.kindOfDef(def),
                }
            end
        end
        local signalDefs = {}
        for _, def in ipairs(store:list("signals")) do
            if def.peripheral == name then
                signalDefs[#signalDefs + 1] = { name = def.name }
            end
        end
        out[#out + 1] = {
            kind = kind,
            name = name,
            containers = containerDefs,
            signals = signalDefs,
        }
    end
    for _, name in ipairs(peripherals:names("inventory")) do
        add("inventory", name)
    end
    for _, name in ipairs(peripherals:names("fluid")) do
        add("fluid_storage", name)
    end
    for _, name in ipairs(peripherals:names("redstone")) do
        add("redstone_relay", name)
    end
    return out
end

local protocol
--- 搬运卸载调度器（IFMWorker 调度，实现见 ifm/transfer.lua）：在下面 Protocol 建好之后创建并接到 containers 上
local transfer

--- 汇总推送给网页的全部类别
local function collectSnapshot()
    return {
        containers = store:list("containers"),
        signals = store:list("signals"),
        filters = store:list("filters"),
        machineTypes = store:list("machineTypes"),
        machines = collectMachines(),
        processes = store:list("processes"),
        peripherals = collectPeripherals(),
        missing = containers:missingPeripherals(),
        resources = collectResources(),
        runtime = engine:runtime(),
        deliveries = engine:deliveries(),
        workers = transfer and transfer.workersForUi and transfer:workersForUi() or nil,
        status = buildStatus(),
    }
end

--- 标签扫描：只在需要时才问 getItemDetail（每个物品名只问一次，结果持久化到 cache.json）。
--- **getItemDetail 是阻塞的外设调用**（有线网络上 ≈1 个服务器刻/次），而且主控要问的是
--- 「几百种物品」—— 所以这里一律先走物品详情字典（Containers 的 detailCache），
--- 字典里没有的交给 worker 打包代查（见 Transfer:detailRequest），主控自己**不做**阻塞调用；
--- 只有在没有可用 worker 时才本机读，并且每个 tick 最多读 MAX_TAG_SCANS_PER_TICK 个。
local tagScan = { queued = 0, scanned = 0, fromWorkers = 0, deferred = 0 }
local tagQueue = {}
local tagIndex = 1
--- 兜底路径（没有可用 worker）每个 tick 最多本机读几个：一次 getItemDetail ≈1 个服务器刻，
--- 一次读 8 个会把主循环拖住 ~0.4s，所以这里只做 1 个（标签是展示用的低优先级数据）。
local MAX_TAG_SCANS_PER_TICK = 1
--- 一次请 worker 代查多少个物品（一批 = 一个 modem 请求，worker 一口气做完）。
--- 一批 8 个 ≈ 8 个服务器刻（≈0.4s）—— 够快，又不会把 worker 占太久（它还要搬东西）。
local TAG_DETAIL_BATCH = 8
--- 一个 tick 最多派几批给 worker（4 × 8 = 32 个物品）：派太多会连 modem 和 worker 一起占满。
local MAX_TAG_DETAIL_REQUESTS = 4
--- 客户端连着时自动补扫的间隔：标签缓存里缺哪个物品就补哪个（每个物品只会补一次）。
--- 补扫要先扫一遍所有容器（`queueTagScan`），所以间隔别太短（默认 60 秒）。
local TAG_AUTO_INTERVAL = 60000
local lastTagAutoScan = 0

--- 收集「标签缓存里还没有」的每种物品的一个样本，排队扫描其标签。
--- 已经在缓存里的物品**绝不会**再问 getItemDetail（同一物品一个会话只查一次）。
--- 顺手做两件事（都是这次扫描本来就要读的数据）：
---   * 记录「当前存储里出现的物品名」→ 用来清理标签缓存（只保留现有物品，见下面的 pruneTags）；
---   * 只对现有物品排队扫描。
local function queueTagScan()
    tagQueue = {}
    tagIndex = 1
    local seen = {}
    local present = {}
    for _, stack in ipairs(containers:collectStacks(nil)) do
        local name = stack.name
        if type(name) == "string" and name ~= "" then
            present[name] = true
            if not seen[name] then
                seen[name] = true
                if not cache:hasTags(name) then
                    tagQueue[#tagQueue + 1] = {
                        peripheral = stack.peripheral,
                        slot = stack.slot,
                        name = name,
                        --- NBT 也是物品身份的一部分（物品详情字典的键 = 物品名 + NBT）
                        nbt = stack.nbt,
                    }
                end
            end
        end
    end
    --- 标签缓存只保留「当前存储里还有的」物品：NBT 变体无限多，临时物品的标签会把 cache.json 写满
    local dropped = cache:pruneTags(present)
    if dropped > 0 then
        log("Tag cache pruned: %d item type(s) no longer in storage (%d kept, %d present)",
            dropped, Util.count(cache:tags()), Util.count(present))
    end
    tagScan = { queued = #tagQueue, scanned = 0, fromWorkers = 0, deferred = 0 }
    return #tagQueue
end

--- 客户端连着时自动把缺失的标签排进队列（用户不点「扫描标签」也能在网页上看到标签与 #标签 搜索）
local function autoQueueTagScan()
    if tagScan.queued > 0 or not protocol or not protocol.clientActive then
        return 0
    end
    local now = os.epoch("utc")
    if now - (lastTagAutoScan or 0) < TAG_AUTO_INTERVAL then
        return 0
    end
    -- 上一次推送很慢 = 主循环正被容器扫描拖着走：这一刻先不补扫标签（标签只是展示用的低优先级数据）
    if protocol.lastPushCost and protocol.lastPushCost > 400 then
        return 0
    end
    lastTagAutoScan = now
    return queueTagScan()
end

--- 把一份 itemDetail 的 tags 写进标签缓存（只有确认物品名一致时调用）
local function storeTags(itemName, detail)
    local tags = {}
    if type(detail) == "table" and type(detail.tags) == "table" then
        for key, value in pairs(detail.tags) do
            if type(key) == "string" then
                tags[key] = true
            end
            if type(value) == "string" then
                tags[value] = true
            end
        end
    end
    cache:setTags(itemName, tags)
end

--- 把「物品详情字典里已经有答案」的排队物品写进标签缓存（worker 代查回来的都走这条）。
--- 返回这次消费掉几个条目。**只有**遇到字典里还没有的物品才停（保持队列顺序）。
local function flushTagQueue()
    local written = 0
    while tagIndex <= #tagQueue do
        local entry = tagQueue[tagIndex]
        local detail, known = containers:cachedItemDetail(entry.name, entry.nbt)
        if not known then
            break
        end
        tagIndex = tagIndex + 1
        written = written + 1
        --- detail 为 nil = 问过但外设给不出（负缓存）：跳过，但不再重复排队
        if detail then
            storeTags(entry.name, detail)
        end
        tagScan.scanned = (tagScan.scanned or 0) + 1
    end
    return written
end

--- 吸收 worker 代查回来的物品详情（每个 tick 一次）：填进物品详情字典，然后立刻写标签缓存。
--- 这一步**零阻塞**：主控只读 modem 消息，getItemDetail 是 worker 在旁边做的。
local function absorbWorkerDetails()
    if not transfer or not transfer.takeDetailResults then
        return 0
    end
    local entries = transfer:takeDetailResults()
    if type(entries) ~= "table" or #entries == 0 then
        return 0
    end
    local taken = containers:absorbItemDetails(entries)
    if taken > 0 then
        tagScan.fromWorkers = (tagScan.fromWorkers or 0) + taken
    end
    flushTagQueue()
    return taken
end

--- 每个 tick 处理一小段队列，绝不阻塞主循环：
---   ① 先吸收 worker 代查回来的详情（零阻塞）；
---   ② 字典里已经有答案的条目立刻写标签缓存；
---   ③ 剩下的请 worker 打包代查（一批 TAG_DETAIL_BATCH 个）；
---   ④ 没有可用 worker 时才本机读（每 tick 最多 MAX_TAG_SCANS_PER_TICK 个，阻塞但极少）。
local function processTagQueue()
    absorbWorkerDetails()
    local processed = flushTagQueue()
    local requests = 0
    while tagIndex <= #tagQueue and requests < MAX_TAG_DETAIL_REQUESTS and processed < MAX_TAG_SCANS_PER_TICK do
        local batch, index = {}, tagIndex
        while index <= #tagQueue and #batch < TAG_DETAIL_BATCH do
            local entry = tagQueue[index]
            local _, known = containers:cachedItemDetail(entry.name, entry.nbt)
            if known then
                break                        -- 这条已经有答案（含“问过拿不到”的负缓存）：交给 flush 处理
            end
            batch[#batch + 1] = {
                container = entry.peripheral,
                slot = entry.slot,
                name = entry.name,
                nbt = entry.nbt,
            }
            index = index + 1
        end
        if #batch == 0 then
            break
        end
        requests = requests + 1
        local state = containers:requestItemDetails(batch)
        if state == "pending" then
            --- 已经派给 worker：结果回来后由 absorbWorkerDetails 填字典并写标签（下个 tick）
            tagScan.deferred = (tagScan.deferred or 0) + #batch
            return processed
        end
        --- 没有可用 worker（或都在忙）：本机读一个，读到的详情进字典，再由 flush 统一写标签
        local entry = tagQueue[tagIndex]
        containers:detail(entry.peripheral, entry.slot, { name = entry.name, nbt = entry.nbt })
        local written = flushTagQueue()
        if written == 0 then
            --- 槽位里已经不是那个物品了（被搬走 / 换掉）也不该卡住队列：跳过这一条
            tagIndex = tagIndex + 1
            tagScan.scanned = (tagScan.scanned or 0) + 1
            written = 1
        end
        processed = processed + written
        break
    end
    if tagScan.queued > 0 and tagIndex > #tagQueue then
        log("Tag scan finished: %d item type(s) cached in cache.json (%d of them read by workers)",
            tagScan.scanned, tagScan.fromWorkers or 0)
        tagScan = { queued = 0, scanned = 0, fromWorkers = 0, deferred = 0 }
        tagQueue = {}
        tagIndex = 1
    end
    return processed
end

--- 连接状态 + 标签扫描进度
function buildStatus()
    local current = protocol and protocol:status() or {}
    --- 服务端版本号：网页端用它做版本比对（不一致会提示并断开）
    current.version = IFM_VERSION
    current.tags = 0
    for _ in pairs(cache:tags()) do
        current.tags = current.tags + 1
    end
    if tagScan.queued > 0 then
        current.tagScan = {
            queued = tagScan.queued,
            scanned = tagScan.scanned,
            pending = math.max(0, tagScan.queued - tagScan.scanned),
            --- 有多少个是 worker 代查回来的（网页上能看出“主控没在做阻塞调用”）
            fromWorkers = tagScan.fromWorkers or 0,
            deferred = tagScan.deferred or 0,
        }
    end
    --- 存储容量（网页资源浏览的进度条）：已存物品/可存物品、已占用槽位/总槽位
    --- 只读统计，即使某个外设出问题也不能影响整包推送
    local okCapacity, capacity = pcall(containers.capacityStats, containers)
    if okCapacity and type(capacity) == "table" then
        current.capacity = capacity
    end
    --- 存储整理进度（1.5.0：整理永远由主控自己执行，worker 不再参与）
    local compact = engine:compactStatus()
    if compact then
        current.compact = compact
    end
    --- IFMWorker 搬运卸载状态：worker 数量 / 在飞任务 / 累计完成数（网页顶部会显示）
    if transfer then
        current.transfer = transfer:status()
    end
    --- 容器扫描间隔设置（网页「设置」面板显示 + 编辑）
    current.scanSettings = store:scanSettings()
    return current
end

--- 定义增删的 action 映射
local SET_KINDS = {
    set_container = "containers",
    set_signal = "signals",
    set_filter = "filters",
    set_machine_type = "machineTypes",
    set_machine = "machines",
    set_process = "processes",
}

local DELETE_KINDS = {
    delete_container = "containers",
    delete_signal = "signals",
    delete_filter = "filters",
    delete_machine_type = "machineTypes",
    delete_machine = "machines",
    delete_process = "processes",
}

--- 发送按钮：发送已有资源 / 触发合成后再发送
local function handleSendItems(payload)
    local containerName = payload.container
    local container = store:get("containers", containerName)
    if not container then
        return { error = "\\u5BB9\\u5668 " .. tostring(containerName) .. " \\u4E0D\\u5B58\\u5728" }
    end
    if container.role ~= "output" then
        return { error = "\\u53EA\\u80FD\\u53D1\\u9001\\u5230 output \\u89D2\\u8272\\u7684\\u5BB9\\u5668" }
    end
    local items = payload.items or {}
    if #items == 0 then
        return { error = "\\u5F85\\u53D1\\u9001\\u5217\\u8868\\u4E3A\\u7A7A" }
    end
    local results = {}
    for _, item in ipairs(items) do
        local kind = item.kind
        local name = item.name
        local count = math.max(1, math.floor(tonumber(item.count) or 1))
        if not kind or not name then
            results[#results + 1] = { name = tostring(name), error = "\\u7F3A\\u5C11\\u8D44\\u6E90\\u4FE1\\u606F" }
        else
            -- 物品只能发到物品容器、流体只能发到流体容器（同名不同种类的定义也能区分）
            local target = store:findContainer(containerName, kind)
            -- filter 是资源种类（可能匹配物品或流体），只要求容器定义存在；
            -- item / fluid 必须与容器定义的种类一致
            if not target or (kind ~= "filter" and target.kind ~= Util.kindOfDef(kind)) then
                results[#results + 1] = {
                    kind = kind,
                    name = name,
                    error = "\\u5BB9\\u5668 " .. tostring(containerName) .. " \\u4E0D\\u662F"
                        .. (kind == "fluid" and "\\u6D41\\u4F53" or "\\u7269\\u54C1") .. "\\u5BB9\\u5668",
                }
            else
                local available = engine:storageCount(kind, name)
                local producers = engine:producers(kind, name)
                local ok, info
                if available < count and #producers > 0 then
                    -- 库存不足但可以合成：先发库存，并按缺少的数量触发合成
                    ok, info = engine:craftAndSend(kind, name, count, containerName)
                else
                    ok, info = engine:queueSend(kind, name, count, containerName)
                end
                if ok then
                    results[#results + 1] = {
                        kind = kind,
                        name = name,
                        count = count,
                        queued = true,
                        craft = info and info.process or nil,
                    }
                else
                    results[#results + 1] = { kind = kind, name = name, error = tostring(info) }
                end
            end
        end
    end
    return { results = results }
end

--- 网页发来的容器管理请求 → 找到容器定义。
--- 先按“名称 + 种类”找；找不到再**只按名称**在物品/流体两种容器里找一遍 ——
--- 网页那侧的种类可能来自历史数据或它自己的猜测，不该因此报“容器定义不存在”。
--- 返回 def, 实际种类（找不到返回 nil）。
local function findContainerByPayload(payload)
    local asked = Util.kindOfDef(payload)
    local def = store:findContainer(payload.name, asked) or store:findContainer(payload.name)
    if not def then
        return nil, asked
    end
    return def, Util.kindOfDef(def)
end

--- 交互容器管理：查看某个容器定义当前的内容物（网页「容器管理」小工具用）
local function containerView(payload)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = "\\u5BB9\\u5668\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728" }
    end
    local usable = containers:supports(def.name, kind)
    local out = {
        name = def.name,
        kind = kind,
        role = def.role,
        peripheral = def.peripheral,
        usable = usable,
        problem = usable and nil or containers:unusableReason(def.name, kind),
        items = {},
        fluids = {},
        slots = 0,
    }
    if kind == "item" then
        for _, stack in ipairs(containers:stacks(def.name)) do
            out.items[#out.items + 1] = {
                slot = stack.slot,
                name = stack.name,
                count = tonumber(stack.count) or 0,
            }
        end
        out.slots = containers:slotCount(def.peripheral) or 0
    else
        for _, tank in ipairs(containers:tanks(def.name)) do
            out.fluids[#out.fluids + 1] = {
                tank = tank.tank,
                name = tank.name,
                amount = tonumber(tank.amount) or 0,
            }
        end
    end
    return out
end

--- 交互容器管理：手动搬运。
---   dir = "out"：把这个容器里的资源搬到**存储容器**（role = storage）
---   dir = "in" ：把**存储容器**里的资源搬进这个容器
--- 注意：这里临时摘掉 IFMWorker 调度器，由本机直接搬 —— 手动操作要立刻看到结果，
--- 不适合“发任务给 worker、下个 tick 再确认”的异步路径（搬完立刻把调度器装回去）。
local function containerMove(payload, dir)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = "\\u5BB9\\u5668\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728" }
    end
    if not containers:supports(def.name, kind) then
        return { error = containers:unusableReason(def.name, kind) or "\\u5BB9\\u5668\\u4E0D\\u53EF\\u7528" }
    end
    local resource = tostring(payload.resource or "")
    if resource == "" then
        return { error = "\\u8BF7\\u5148\\u9009\\u62E9\\u7269\\u54C1/\\u6D41\\u4F53" }
    end
    local count = math.max(1, tonumber(payload.count) or 1)
    --- 某容器里符合该资源的条目（物品给槽位、流体给罐号）
    local listEntries = function(containerName)
        local out = {}
        if kind == "item" then
            for _, stack in ipairs(containers:stacks(containerName)) do
                if stack.name == resource then
                    out[#out + 1] = { ref = stack.slot, amount = tonumber(stack.count) or 0 }
                end
            end
        else
            for _, tank in ipairs(containers:tanks(containerName)) do
                if tank.name == resource then
                    out[#out + 1] = { ref = tank.tank, amount = tonumber(tank.amount) or 0 }
                end
            end
        end
        return out
    end
    local move = function(fromContainer, ref, want, toContainer)
        if kind == "item" then
            return containers:pushItem(fromContainer, ref, want, toContainer)
        end
        return containers:pushFluid(fromContainer, want, resource, toContainer)
    end
    --- 搬运顺序按存储优先级：out（搬进存储）高优先级在前；in（从存储搬出）低优先级在前
    local targets = containers:byRole("storage", kind, dir == "out" and "out" or "in")
    if #targets == 0 then
        return { error = "\\u6CA1\\u6709 storage \\u89D2\\u8272\\u7684\\u5B58\\u50A8\\u5BB9\\u5668" }
    end
    local provider = containers.transfer
    containers:setTransferProvider(nil)
    local moved, reason = 0, nil
    local ok, err = pcall(function()
        if dir == "out" then
            for _, entry in ipairs(listEntries(def.name)) do
                if moved >= count then
                    break
                end
                for _, target in ipairs(targets) do
                    if moved >= count then
                        break
                    end
                    local got, sub = move(def.name, entry.ref, count - moved, target)
                    got = tonumber(got) or 0
                    if got > 0 then
                        moved = moved + got
                        containers:invalidate()
                    elseif sub then
                        reason = reason or sub
                    end
                end
            end
        else
            for _, source in ipairs(targets) do
                if moved >= count then
                    break
                end
                for _, entry in ipairs(listEntries(source)) do
                    if moved >= count then
                        break
                    end
                    local got, sub = move(source, entry.ref, count - moved, def.name)
                    got = tonumber(got) or 0
                    if got > 0 then
                        moved = moved + got
                        containers:invalidate()
                    elseif sub then
                        reason = reason or sub
                    end
                end
            end
        end
    end)
    containers:setTransferProvider(provider)
    if not ok then
        return { error = tostring(err) }
    end
    log("Manual container %s %s %s: %s x%s -> %s", tostring(def.name), tostring(dir),
        tostring(kind), tostring(resource), tostring(count), tostring(moved))
    return { success = true, moved = moved, reason = reason }
end

--- WebSocket 请求路由
--- 网页端会在每条请求里带上自己的版本号（前端 IFM_CLIENT_VERSION）：
--- 与后端不一致时这里留一行日志；网页端自己会更严格地弹窗警告并停止连接。
local lastClientVersion = nil

local function handleRequest(payload)
    local action = payload.action
    if type(payload.version) == "string" and payload.version ~= "" and payload.version ~= lastClientVersion then
        lastClientVersion = payload.version
        if payload.version ~= IFM_VERSION then
            log("Client version mismatch: client=%s server=%s (the browser will show a warning)",
                payload.version, IFM_VERSION)
        end
    end
    if action == "ping" or action == "heartbeat" then
        return { status = "alive" }
    end
    -- 每次网页请求都在终端与网页控制台留一行：用来确认请求确实到达了服务端（排查"点了没反应"）
    log("request: %s", tostring(action))
    if action == "rescan_peripherals" then
        peripherals:scan()
        containers:invalidate()
        return { success = true }
    elseif action == "save" then
        local okStore = store:flush()
        local okCache = cache:flush()
        return { success = okStore and okCache or false }
    elseif action == "get_definitions" then
        return collectSnapshot()
    elseif action == "scan_tags" then
        local queued = queueTagScan()
        return { success = true, queued = queued }
    elseif action == "clear_tags" then
        cache:clearTags()
        cache:flush()
        return { success = true }
    elseif action == "compact_storage" then
        -- 存储整理：把同一种物品（同名同 NBT）散落在多个槽位/多个容器上的堆按数量升序合并。
        -- 计划本身也**分批算**（每个 tick 最多问几次外设），所以这里立刻返回：
        -- 网页显示“正在计算搬运计划…”，算完后引擎再按每 tick 少量搬运执行（进度在网页上看得到）。
        local state = engine:startCompact(payload.role)
        log("Storage compact requested (%s): the plan is computed in small slices so the master stays responsive",
            tostring(state))
        return { success = true, planning = true, state = state }
    elseif action == "set_scan_settings" then
        --- 容器扫描间隔（毫秒）：存储容器 / 输入容器各一个。校验走 Store:set，
        --- 保存后立刻应用并回传生效值（网页直接显示回传值，避免“看着存了其实没生效”）。
        local data = {
            storageScanMs = payload.storageScanMs,
            inputScanMs = payload.inputScanMs,
        }
        local ok, err = store:set("settings", Store.SETTINGS_NAME, data, { force = true })
        if not ok then
            log("Save settings failed: %s", tostring(err))
            return { error = err }
        end
        local applied = applyScanSettings()
        store:flush()
        log("Container scan settings updated: storage=%dms input=%dms",
            applied.storageScanMs, applied.inputScanMs)
        return { success = true, scanSettings = applied }
    elseif action == "container_view" then
        -- 交互容器管理：查看该容器当前的内容物
        return containerView(payload)
    elseif action == "container_take" then
        -- 交互容器管理：把该容器里的物品/流体搬回存储容器
        return containerMove(payload, "out")
    elseif action == "container_put" then
        -- 交互容器管理：把存储容器里的物品/流体搬进该容器
        return containerMove(payload, "in")
    elseif action == "diagnose" then
        -- 诊断结果作为日志行发给浏览器控制台（同时本地 print），不写任何文件
        local mode = tostring(payload.mode or "report")
        local lines
        if mode == "move" then
            lines = diagnose:moveProbe()
        elseif mode == "tick" then
            lines = diagnose:tickProbe()
        elseif mode == "perf" then
            --- 性能诊断：各组件耗时 + 协议层收发字节（排查“运行缓慢”用）
            lines = diagnose:perf()
        else
            lines = diagnose:report()
        end
        -- 报告行通过日志通道（每 40 行一条消息）发给浏览器；网页按 begin/end 标记收集后显示在诊断窗口
        log("===== IFM diagnose begin (%s) =====", mode)
        for _, entry in ipairs(lines) do
            log("%s", entry)
        end
        log("===== IFM diagnose end =====")
        return { success = true, mode = mode, lines = lines, count = #lines }
    end
    local setKind = SET_KINDS[action]
    if setKind then
        local name = payload.name
        local data = payload.data or payload
        if setKind == "containers" then
            -- 容器种类必须是 item / fluid，且引用到的外设要真的提供这种外设
            if data.kind ~= nil and data.kind ~= "item" and data.kind ~= "fluid" then
                return { error = "\\u5BB9\\u5668\\u79CD\\u7C7B\\u53EA\\u80FD\\u662F item\\uFF08\\u7269\\u54C1\\uFF09\\u6216 fluid\\uFF08\\u6D41\\u4F53\\uFF09" }
            end
            local wantKind = Util.kindOfDef(data)
            local peripheralName = data.peripheral
            if peripheralName and peripheralName ~= "" and peripherals:exists(peripheralName) then
                local provides
                if wantKind == "fluid" then
                    provides = peripherals:isFluid(peripheralName)
                else
                    provides = peripherals:isInventory(peripheralName)
                end
                if not provides then
                    return { error = "\\u5916\\u8BBE " .. peripheralName .. " \\u4E0D\\u63D0\\u4F9B"
                        .. (wantKind == "fluid" and "\\u6D41\\u4F53\\uFF08fluid_storage\\uFF09" or "\\u7269\\u54C1\\uFF08inventory\\uFF09") .. "\\u5916\\u8BBE" }
                end
            end
        end
        local ok, err = store:set(setKind, name, data, { previous = payload.previous })
        if not ok then
            log("Save %s failed: %s", tostring(setKind), tostring(err))
            return { error = err }
        end
        log("Saved %s: %s", tostring(setKind), tostring(name))
        -- 保存后的收尾工作：出错也不能让这次请求没有响应（否则网页只会看到“超时”）
        local okAfter, afterErr = pcall(function()
            engine:reconcile()
            store:flush()
        end)
        if not okAfter then
            log("Post-save cleanup failed for %s: %s", tostring(setKind), tostring(afterErr))
        end
        return { success = true, kind = setKind, name = name }
    end
    local deleteKind = DELETE_KINDS[action]
    if deleteKind then
        -- force = true：允许删除仍被引用的定义（换外设时用；引用它的流程会被冻结，等同名定义回来再恢复）
        local ok, err = store:delete(deleteKind, payload.name, payload.kind, { force = payload.force == true })
        if not ok then
            return { error = err }
        end
        if deleteKind == "processes" then
            cache.data.processes[payload.name] = nil
        elseif deleteKind == "machines" then
            cache.data.machines[payload.name] = nil
        elseif deleteKind == "machineTypes" then
            cache.data.machineTypes[payload.name] = nil
        end
        engine:reconcile()
        store:flush()
        cache:flush()
        return { success = true }
    end
    --- 1.5.0：流程一律由主控本机执行（IFMWorker 只做搬运/查询），网页动作不再转发给 worker
    if action == "start_process" then
        local ok, info = engine:start(payload.name, payload.count)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "set_process_count" then
        local ok, info = engine:setUserCount(payload.name, payload.count)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "cancel_process" then
        local ok, info = engine:cancel(payload.name)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "craft_resource" then
        local ok, info = engine:startResource(payload.kind, payload.name, payload.count, payload.process)
        if not ok then
            return { error = info }
        end
        return { success = true, info = info }
    elseif action == "send_items" then
        local result = handleSendItems(payload)
        cache:flush()
        store:flush()
        -- 把每条发送结果打到终端/网页控制台，便于确认请求确实被处理
        local queued, failed = 0, 0
        for _, entry in ipairs(result.results or {}) do
            if entry.error then
                failed = failed + 1
                log("send_items: %s %s FAILED: %s", tostring(entry.kind), tostring(entry.name), tostring(entry.error))
            else
                queued = queued + 1
                log("send_items: %s %s x%s queued (craft=%s)", tostring(entry.kind), tostring(entry.name),
                    tostring(entry.count), tostring(entry.craft))
            end
        end
        log("send_items -> container=%s queued=%d failed=%d", tostring(payload.container), queued, failed)
        return result
    elseif action == "worker_query" then
        -- 让 IFMWorker 代扫**一个容器**（一条查询只查一个容器，见 ifm/transfer.lua 的 startScanBatch）
        -- payload: { container = 容器外设名, names = {物品名...}, key = "自定义缓存键" }
        if not (transfer and transfer.requestQuery) then
            return { error = "transfer module unavailable" }
        end
        local container = payload.container
        if type(container) ~= "string" or container == "" then
            return { error = "container is required (one container per query)" }
        end
        local names = nil
        if type(payload.names) == "table" then
            names = {}
            for _, value in ipairs(payload.names) do
                if type(value) == "string" and value ~= "" then
                    names[value] = true
                end
            end
        end
        local key = payload.key
        if type(key) ~= "string" or key == "" then
            key = "web:" .. container
        end
        local state, result = transfer:requestQuery({
            container = container,
            names = names,
            key = key,
        })
        if state == "done" then
            log("worker_query: served %s from the query cache", tostring(key))
            return { success = true, state = state, key = key, result = result }
        end
        if state == "local" then
            -- 没有可用 worker：调用方自己做本机扫描（这里不带本机扫描结果，避免和引擎的缓存混淆）
            return { success = false, state = state, key = key, info = "no IFMWorker online for queries" }
        end
        return { success = true, state = state, key = key, info = "query sent to IFMWorker; see status.transfer.lastQuery" }
    elseif action == "delete_delivery" then
        --- 发货 id 用 deliveryId 字段传：请求里顶层的 id 是**请求关联号**（响应要靠它配对），
        --- 早先前端把发货 id 也写成 id，把关联号覆盖掉 → 响应回来了网页却等不到（1.6.7 修）。
        --- 这里仍然接受旧的 id 字段（老前端/缓存的页面），保证兼容。
        local deliveryId = tonumber(payload.deliveryId or payload.id)
        local removed = cache:removeDelivery(deliveryId)
        cache:flush()
        return { success = true, removed = removed and true or false, id = deliveryId }
    end
    return { error = "\\u672A\\u77E5\\u7684 action\\uFF1A" .. tostring(action) }
end

--- 建立 WebSocket 协议层
protocol = Protocol.new({
    Util = Util,
    url = wsUrl,
    log = log,
    collect = collectSnapshot,
    onRequest = handleRequest,
    -- 定时推送间隔（秒）：**没有变化时**的兜底刷新频率（有变化会立刻推，见下）。
    -- 注意：一次推送要全量收集（每个容器一次外设调用，有线网络上 ≈1 个服务器刻/次），
    -- 12 个容器就 ~0.6s，所以兜底频率别设太小。
    updateInterval = 2,
    -- 增量推送的硬下限（毫秒）：1.6.12 起**默认 0 = 不设硬限制**（用户要求：服务端不应当
    -- 对 WebSocket 收发数据包做速率硬限制）。推送改由“状态变更计数”驱动：
    -- cache.revision 变了就立刻推，同一 tick 内多个请求合并成一次。
    -- 想恢复旧的“最快 N 毫秒一次”节流时，把这里设成毫秒数即可（例如 2000）。
    minPushInterval = 0,
    -- 状态变更计数：cache.revision（任何 Cache:markDirty() 都会 +1）
    revisionProvider = function()
        return cache.revision or 0
    end,
    reconnectInterval = 5,
    -- 浏览器心跳超时（秒）：别设太小，浏览器后台标签页的定时器会被节流，
    -- 太小会导致服务端不停重连中继，把正在处理的请求响应一起丢掉（网页表现为“超时”）
    clientTimeout = 40,
    maxChunk = 50,
})

--- IFMWorker 调度（transfer）：把物品/流体搬运接到调度器上。
--- 有 worker 在线时，搬运全部由它们执行，本机只发送参数、等回报；查询（requestQuery）同理。
transfer = Transfer.new({ log = log, Peripherals = peripherals, Modems = Modems })
containers:setTransferProvider(transfer)
--- 容器扫描卸载：worker 代读主控的容器（主控自己读一遍 19 个容器 ≈950ms，是“主控缓慢”的最大来源）
containers:setScanProvider(transfer)
--- 物品详情卸载：getItemDetail 同样是阻塞调用（≈1 个服务器刻/次），整理要 maxCount、
--- 标签扫描要 tags，几百种物品全压在主控身上会明显卡顿 —— 打包交给 worker 代查。
containers:setDetailProvider(transfer)
--- 分布式（1.5.0）：只把版本号交给调度器 —— worker 只做搬运/查询，流程/整理/中继都在主控本机
transfer:setContext({
    version = IFM_VERSION,
})

--- 日志同时打印到本地终端并推给网页（浏览器控制台打印）：
--- 这样即使没打开浏览器控制台，也能在 CC 终端看到引擎/流程/发送任务的具体原因。
Util.setLogHandler(function (text)
    print(text)
    if protocol then
        protocol:onLog(text)
    end
end)

--- 启动
--- 先打 IFM 艺术字（纯 ASCII：CC:T 终端字形没有中日韩字符，艺术字只能用 ASCII 画）
local IFM_ART = {
    "     _/_/_/  _/_/_/_/  _/      _/   ",
    "      _/    _/        _/_/  _/_/    ",
    "     _/    _/_/_/    _/  _/  _/     ",
    "    _/    _/        _/      _/      ",
    " _/_/_/  _/        _/      _/        ",
}
for _, line in ipairs(IFM_ART) do
    print(line)
end
print("")
print("=========================================")
print(" IFM - Integrated Factory Manager (server)")
print("=========================================")
print(" room   : " .. room .. "  (" .. roomNote .. ")")
print(" version: " .. IFM_VERSION)
print(" relay  : " .. wsUrl .. "  (fixed for this run)")
print(" module : " .. moduleDir)
print(" transfer: channel " .. tostring(transfer.channel) ..
    " (run IFMWorker.lua on other computers: move + query; unpack the same bundle there)")
print(" data   : " .. dataDir)
print(" browser: open IFM/index.html and use the same room name")
print(" Ctrl+T stops safely (config + runtime state are saved)")
print("=========================================")

engine:reconcile()
engine:restoreSignals()
if protocol:connect() then
    log("Relay connection requested (async); websocket_success / websocket_failure will report the result")
else
    log("Initial relay connection request failed, retrying every %d seconds", protocol.reconnectInterval)
end

local TICK = 0.1
local tickToken = os.startTimer(TICK)
local lastStatusPrint = os.epoch("utc")
local startedAt = os.epoch("utc")

--- 每 30 秒的状态摘要（**同时**打印到终端与浏览器控制台）：
--- 连接状态、每条发送任务的进度与原因、每个进程的状态/阶段/机器/原因
local function statusLine()
    local connection = protocol.connected and "relay:up" or "relay:down"
    local client = protocol.clientActive and "browser:on" or "browser:off"
    log("%s / %s / room %s / defs: containers=%d signals=%d filters=%d machines=%d processes=%d / uptime %ds",
        connection,
        client,
        room,
        #store:list("containers"),
        #store:list("signals"),
        #store:list("filters"),
        #store:list("machines"),
        #store:list("processes"),
        math.floor((os.epoch("utc") - startedAt) / 1000))
    for _, delivery in ipairs(cache:deliveries()) do
        log("delivery #%s %s x%s -> %s%s",
            tostring(delivery.id or 0),
            tostring(delivery.name),
            tostring(delivery.remaining or 0),
            tostring(delivery.container),
            delivery.lastError and (" | " .. tostring(delivery.lastError)) or "")
    end
    for _, process in ipairs(store:list("processes")) do
        local record = cache:proc(process.name)
        log("process %s state=%s phase=%s batch=%s machine=%s err=%s",
            tostring(process.name),
            tostring(record.state),
            tostring(record.phase),
            tostring(record.batch),
            tostring(record.machine),
            tostring(record.lastError))
    end
end

--- 备用驱动：某些情况下主 tick 定时器会丢失（收不到 timer 事件），
--- 这时只要还有任何事件（网页心跳等）或备用定时器，引擎依然会被推进
local backupToken = os.startTimer(TICK + 0.05)

--- 事件计数（诊断报告里能看到：timers=0 说明这台机器收不到定时器事件）
local debugCounters = { events = 0, timers = 0, websockets = 0, ticks = 0 }
engine.debugCounters = debugCounters

--- 计时包装：单个模块出错或卡住都不该让主循环直接结束（那会让网页所有请求变成超时），
--- 同时把“慢步骤”写进日志（浏览器控制台可见），便于定位卡住的环节。
--- 每个 label 的调用次数 / 总耗时 / 最大耗时都会累计进 perfStats（诊断模式 perf 可查看）。
local SLOW_STEP_MS = 500
local perfStats = {}
local function perfStatOf(label)
    local stat = perfStats[label]
    if not stat then
        stat = { label = label, count = 0, total = 0, max = 0, last = 0, slow = 0 }
        perfStats[label] = stat
    end
    return stat
end

--- 慢步骤的补充说明：label -> 返回一行明细的函数（只有该步骤慢到要打日志时才会调用）。
--- 目的是“一眼看出慢在哪”：引擎 tick 是慢在推进流程，还是慢在读容器（明细见 Recipe:tickStatsText）。
local slowDetails = {}

local function timed(label, fn, ...)
    local startedAt = os.epoch("utc")
    local ok, err = pcall(fn, ...)
    local elapsed = os.epoch("utc") - startedAt
    local stat = perfStatOf(label)
    stat.count = stat.count + 1
    stat.total = stat.total + elapsed
    stat.last = elapsed
    if elapsed > stat.max then
        stat.max = elapsed
    end
    if elapsed >= SLOW_STEP_MS then
        stat.slow = stat.slow + 1
        log("Slow %s: %dms (calls=%d avg=%dms max=%dms slow=%d)",
            label, elapsed, stat.count, math.floor(stat.total / stat.count), stat.max, stat.slow)
        local detail = slowDetails[label]
        if detail then
            local okDetail, text = pcall(detail)
            if okDetail and type(text) == "string" and text ~= "" then
                log("Slow %s detail: %s", label, text)
            end
        end
    end
    if not ok then
        log("%s error: %s", label, tostring(err))
    end
    return ok, err
end

--- 慢 tick 明细：引擎 tick 里推进了几个流程 / 真正读了几次容器（缓存命中不算）与容器扫描的实测成本
slowDetails["engine tick"] = function()
    return engine:tickStatsText()
end

--- 慢推送明细：一次推送要全量收集（含资源统计与容量），这里给出容器扫描的自适应缓存时长
slowDetails["protocol update"] = function()
    local scan = containers:scanSummary()
    return string.format("containers=%s readCost=%sms passCost=%sms scanTtl=%sms (base=%sms x%s) defer=%s",
        tostring(scan.containers), tostring(scan.readCost), tostring(scan.passCost),
        tostring(scan.ttl), tostring(scan.baseTtl), tostring(scan.multiplier),
        tostring(scan.defer or 0))
end

--- 诊断（perf 模式）需要的三类运行时计数：
---   perfStats     —— 各组件耗时（上面的 timed 收集）
---   debugCounters —— 事件循环计数（timers=0 说明收不到定时器事件）
---   protocol      —— 协议层收发消息数 / 字节数（按 action 汇总）
---   transfer      —— IFMWorker 调度器（worker 数 / 任务计数）
--- 注意：这几个字段名都不能和 Diagnose 的方法名重名（曾把耗时表写成 `diagnose.perf`，
--- 直接覆盖了 `Diagnose:perf()` 方法，于是“诊断 → perf”报 attempt to call method 'perf' (a table value)）。
diagnose.perfStats = perfStats
diagnose.debugCounters = debugCounters
diagnose.protocol = protocol
diagnose.transfer = transfer

--- 外设热插拔：可能成片触发（有线网络抖动 / 成片区块加载时事件会刷屏）。
--- 因此这里只标记“待扫描”，真正的重扫放到 runDue 里按“最多每秒一次”执行：
--- 否则事件循环会被扫描占满，网页发来的请求长时间得不到处理，表现为所有请求超时。
local lastPeripheralScanAt = 0
local peripheralScanPending = false

local function refreshPeripheralsIfNeeded(now)
    if not peripheralScanPending or now - lastPeripheralScanAt < 1000 then
        return
    end
    peripheralScanPending = false
    lastPeripheralScanAt = now
    log("Peripherals changed, rescanning")
    timed("peripheral scan", peripherals.scan, peripherals)
    containers:invalidate()
end

--- 推进引擎与各模块：不论由哪种事件触发，只要距上次推进 >= TICK 就跑一次
local lastEngineRun = 0
local function runDue(now)
    if now - lastEngineRun < TICK * 1000 then
        return
    end
    lastEngineRun = now
    debugCounters.ticks = debugCounters.ticks + 1
    refreshPeripheralsIfNeeded(now)
    -- 引擎 tick 也要计时：以前这里是裸 pcall，perf 报告里**看不到**它的耗时，
    -- 而排查“主循环为什么变慢（engineRuns 远小于 timers）”时这一段往往正是最大的一块。
    --- 1.5.0：流程与中继都由主控本机执行（IFMWorker 只做搬运/查询），
    --- 所以这里不再有“让出流程”与“切换中继传输层”的动作。
    local okEngine, engineErr = timed("engine tick", engine.tick, engine, now)
    if not okEngine then
        -- 记进引擎（诊断报告里能看到）；错误行由 timed() 统一打印/推送
        engine.lastTickError = tostring(engineErr)
    else
        engine.lastTickError = nil
    end
    timed("scheduler", scheduler.tick, scheduler, now)
    timed("tag queue", processTagQueue)
    timed("tag auto scan", autoQueueTagScan)
    timed("store tick", store.tick, store, now)
    timed("cache tick", cache.tick, cache, now)
    timed("protocol update", protocol.update, protocol, now)
    --- IFMWorker 调度：定时广播 hello、清理掉线的 worker 与超时任务
    timed("transfer tick", transfer.tick, transfer, now)
    if now - lastStatusPrint > 30000 then
        lastStatusPrint = now
        timed("status line", statusLine)
    end
end

local function mainLoop()
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        debugCounters.events = debugCounters.events + 1
        if event == "timer" and (param1 == tickToken or param1 == backupToken) then
            if param1 == tickToken then
                tickToken = os.startTimer(TICK)
            else
                backupToken = os.startTimer(TICK + 0.05)
            end
            debugCounters.timers = debugCounters.timers + 1
            runDue(Util.now())
        elseif event == "peripheral" or event == "peripheral_detach" then
            -- 不在这里立刻重扫：成片的外设事件会把事件循环占满（见 refreshPeripheralsIfNeeded）
            peripheralScanPending = true
            runDue(Util.now())
        elseif event == "websocket_success" or event == "websocket_message" or event == "websocket_closed"
            or event == "websocket_failure" then
            debugCounters.websockets = debugCounters.websockets + 1
            -- 协议层（含收到请求后的推送）出错绝不能让主循环结束：
            -- 主循环一旦结束，服务端就退出，网页上所有请求都会变成“超时”。
            timed("protocol event", protocol.onEvent, protocol, event, param1, param2)
            runDue(Util.now())
        elseif event == "modem_message" then
            -- IFMWorker 调度：worker 的 hello / pong / 任务结果都从这里进来
            timed("transfer message", transfer.onModemMessage, transfer, param1, param2, param3, param4, param5)
            runDue(Util.now())
        else
            runDue(Util.now())
        end
    end
end

--- 主循环：任何未预料的异常都不该让服务端“无声死掉”（网页会表现为所有请求超时），
--- 所以出错后保存状态并自动重启主循环；用户按 Ctrl+T（Terminated）时仍然正常退出。
while true do
    local okLoop, loopErr = pcall(mainLoop)
    store:flush()
    cache:flush()
    if okLoop then
        break
    end
    log("Main loop error: %s", tostring(loopErr))
    if tostring(loopErr) == "Terminated" then
        log("Terminated by user; config and runtime state saved")
        break
    end
    log("Restarting the main loop in 3 seconds (definitions and runtime state are kept)")
    os.sleep(3)
end