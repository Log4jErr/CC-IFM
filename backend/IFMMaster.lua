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
--- 注意：transfer.lua 等模块在这之后才加载，所以这里只能写字面量；
--- 加载完模块后会核对一次 Transfer.VERSION（见下方 doVersionCheck）。
local IFM_VERSION = "1.8.2"

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

--- 定位脚本目录：代码在 <脚本目录>/modules/，数据在 <脚本目录>/data/（1.6.17 起）
--- 以前数据文件和代码混在一起（ifm/ 里），升级时会自动把老数据搬到 data/（只搬一次）
local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMMaster.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")   -- 代码模块（1.6.17 起目录名是 modules/）
--- 老版本的数据文件位置：1.6.16 及以前模块目录叫 ifm/，config.json / cache.json 就放在里面，
--- 也就是现在的 baseDir（<脚本目录>）下；更老的自定义安装里也可能在 modules/ 里，两个都查一遍。
local legacyDataDirs = { baseDir, moduleDir }
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
--- 磁盘读写（config.json / cache.json）：读 / 原子写 / 去抖都在 modules/jsonfile.lua
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
--- 任务调度器（1.8.0）：每个来源一个队列，队列间轮转，每条队列有自己的权重；
--- 队列内部是"双队列"（modules/queue.lua 的环形队列：active 正在执行 / waiting 另一个队列）
local Dispatch = loadModule("dispatch")
local Queue = loadModule("queue")
--- 版本号唯一来源核对：transfer.lua 里的 Transfer.VERSION 是 master/worker/crafter 三边共用的版本，
--- 这里（以及 IFMWorker）如果写错，版本闸门会直接拒活 —— 所以启动时就明确报出来。
if Transfer.VERSION ~= IFM_VERSION then
    error(string.format("version mismatch: IFMMaster.lua says %s but transfer.lua says %s" ..
        " (keep them in sync; web/ifm-core.js must match too)", IFM_VERSION, tostring(Transfer.VERSION)), 0)
end

--- 槽位堆叠上限扫描的累计统计（诊断 / 网页 status.stackScan 用）。
--- 注意：这个声明必须在**它被使用之前**（快照函数在 700 行左右就用到它）——
--- 以前它写在 1400 多行的队列注册处，导致快照里读到的是一个不存在的全局（nil），
--- 整个快照推送失败，网页上机器定义与外设信息全部消失（build.py 现在有专门检查拦这类错）。
local stackScanStats = { rounds = 0, asked = 0, lastContainers = 0 }

if not fs.exists(dataDir) then
    fs.makeDir(dataDir)
end

--- 一次性迁移：老版本的 config.json / cache.json 放在 ifm/ 里，
--- 这里在 data/ 还没有对应文件时把它复制过来（复制成功后再删掉老文件；删不掉也无妨）。
local function migrateLegacyData(fileName)
    local target = fs.combine(dataDir, fileName)
    if fs.exists(target) then
        return false
    end
    for _, dir in ipairs(legacyDataDirs) do
        local legacy = fs.combine(dir, fileName)
        if fs.exists(legacy) and legacy ~= target then
            local handle = fs.open(legacy, "r")
            if handle then
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
        end
    end
    return false
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
        -- 抽象流程（含 abstract 操作）不参与"可合成"判定：它只是给别人复制设置用的
        if not store.processIsAbstract(process) then
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
--- 标签由 detail 队列按需补进缓存：扫描时看到"还没有详情"的物品就排一条任务（一步一次 getItemDetail）
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
        -- 抽象流程（含 abstract 操作）不参与"可合成"判定（与 buildProducerIndex 一致）
        if not store.processIsAbstract(process) then
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

--- 用户第 4 项：正在跑 IFMCrafter 的海龟（网络外设名 → true）。由 syncTurtleCrafters 维护；
--- 没跑 crafter 的海龟对 IFM 没用（物品栏读不到、也没有自动生成的机器/容器），网页上不列出它们。
--- 注意：这里必须是**文件级局部变量**，不能在 collectPeripherals 里直接引用 `transfer`（那个局部
--- 变量声明在后面 —— 构建脚本的"定义顺序检查"会直接中止构建）。
local runningCrafters = {}

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
    --- 机械臂（海龟，用户第 4 项）：**只有正在跑 IFMCrafter 的海龟才列出来**。
    --- 没跑 crafter 的海龟对 IFM 没有任何用途（物品栏读不到、也没有自动生成的机器/交互容器），
    --- 列出来只会让人在网页上白点它 —— 所以这里直接忽略（外设不列出）。
    for _, name in ipairs(peripherals:turtleNames()) do
        if runningCrafters[name] then
            add("turtle", name)
        end
    end
    return out
end

local protocol
--- 搬运卸载调度器（IFMWorker 调度，实现见 modules/transfer.lua）：在下面 Protocol 建好之后创建并接到 containers 上
local transfer

--- 主控启动时刻（进程内）：给下面"开机头 20 秒不下发空 worker 列表"用
local bootAt = os.epoch("utc")

--- 开机头 20 秒（还没有任何 worker 注册）**不下发空的 worker 列表**。
--- 用户现场：worker 卡片整个消失又出现。主控重启那一刻（或重连时的全量同步）workersForUi 是空表，
--- 推一条空列表会把网页上已经画好的卡片清掉，几秒后 worker 报到才画回来 = 卡片闪一下。
--- 网页端对"这一轮没出现的类别保持原样"（frontend/web/ifm-net.js finishFullSync），所以这里返回 nil
--- 就等于"这次别动它"。第一台 worker 注册之后（或超过 20 秒）照旧如实下发 —— 包括"真的一个都没有"。
local WORKER_WARMUP_MS = 20000
local workerWarmupLogged = false
local function collectWorkers()
    local list = transfer and transfer.workersForUi and transfer:workersForUi() or nil
    if list == nil then
        return nil
    end
    if next(list) == nil and (os.epoch("utc") - bootAt) < WORKER_WARMUP_MS then
        if not workerWarmupLogged then
            workerWarmupLogged = true
            log("[startup] no worker has registered yet: keeping the page's worker list instead of clearing it" ..
                " (warmup %ds)", math.floor(WORKER_WARMUP_MS / 1000))
        end
        return nil
    end
    return list
end

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
        workers = collectWorkers(),
        status = buildStatus(),
    }
end

--- 标签扫描：只在需要时才问 getItemDetail（每个物品名只问一次，结果持久化到 cache.json）。
--- getItemDetail 是阻塞的外设调用（有线网络上 ≈1 个服务器刻/次），而且主控要问的是
--- 「几百种物品」—— 所以这里一律先走物品详情字典（Containers 的 detailCache），
--- 字典里没有的交给 worker 打包代查（见 Transfer:detailRequest），主控自己不做阻塞调用；
--- 只有在没有可用 worker 时才本机读，并且每个 tick 最多读 MAX_TAG_SCANS_PER_TICK 个。
--- ===== 物品详情（maxCount / tags）：由调度器的 detail 队列 补齐（1.7.0）=====
--- 生成：storageScan / inputScan 扫到"还没有详情"的物品时排一条任务；
--- 执行：队列一步只做一次 getItemDetail（一次调用约 1 个游戏刻）；
--- 失败：直接丢弃（物品可能已经不在了；下一次扫描会重新生成）；
--- 结果：进物品详情字典（maxCount 供整理/放入策略用）+ 写标签缓存（供 #标签 搜索）。
local detailScan = { queued = 0, scanned = 0, fromWorkers = 0 }

--- detail 队列任务的键：物品名 + NBT（与物品详情字典同键）
local function detailQueueKey(name, nbt)
    return tostring(name) .. "\1" .. tostring(nbt or "")
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

--- 吸收 worker 代查回来的物品详情（每个调度轮次一次）：填字典 + 立刻写标签缓存。
--- 零阻塞：getItemDetail 是 worker 在旁边做的，主控只读 modem 消息。
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
        detailScan.fromWorkers = (detailScan.fromWorkers or 0) + taken
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "table" and type(entry.detail) == "table" and entry.name then
            storeTags(entry.name, entry.detail)
            detailScan.scanned = (detailScan.scanned or 0) + 1
        end
    end
    return taken
end

--- 把"扫描时看到过、但还没有详情"的物品排进 detail 队列（生成器每个轮次调用）
local function queueMissingDetails()
    local seen = containers:takeScanSeen()
    local queued = 0
    for _, entry in ipairs(seen or {}) do
        local _, known = containers:cachedItemDetail(entry.name, entry.nbt)
        if not known and entry.container then
            if dispatch and dispatch:enqueue("detail", {
                key = detailQueueKey(entry.name, entry.nbt),
                sample = { container = entry.container, slot = entry.slot,
                    name = entry.name, nbt = entry.nbt },
            }) then
                queued = queued + 1
            end
        end
    end
    detailScan.queued = queued
    return queued
end

--- 标签缓存清理（低频，按轮次而不是毫秒间隔）：只保留"当前还存在"的物品的标签。
--- NBT 变体无限多，临时流转的物品标签会把 cache.json 写满。
local TAG_PRUNE_EVERY_TICKS = 200
local tagPruneTick = 0
local function pruneTagCache()
    tagPruneTick = (tagPruneTick or 0) + 1
    if tagPruneTick < TAG_PRUNE_EVERY_TICKS then
        return 0
    end
    tagPruneTick = 0
    local present = {}
    for _, def in ipairs(store:list("containers")) do
        --- 只有 storage/input 的容器可读（interaction/output 按设计不读，读它们会直接报错）
        if containers:isReadableContainer(def.name, Util.kindOfDef(def)) then
            for _, stack in ipairs(containers:stacks(def.name)) do
                if type(stack.name) == "string" and stack.name ~= "" then
                    present[stack.name] = true
                end
            end
        end
    end
    local dropped = cache:pruneTags(present)
    if dropped > 0 then
        log("Tag cache pruned: %d item type(s) no longer in storage", dropped)
    end
    return dropped
end

--- 网页「扫描标签」按钮：把"存储里可见、但还没有详情"的物品全部排进 detail 队列
local function queueTagScan()
    local queued = 0
    for _, def in ipairs(store:list("containers")) do
        --- 只有 storage/input 的容器可读（interaction/output 按设计不读，读它们会直接报错）
        if containers:isReadableContainer(def.name, Util.kindOfDef(def)) then
            for _, stack in ipairs(containers:stacks(def.name)) do
                if type(stack.name) == "string" and stack.name ~= "" then
                    local _, known = containers:cachedItemDetail(stack.name, stack.nbt)
                    if not known and dispatch then
                        if dispatch:enqueue("detail", {
                            key = detailQueueKey(stack.name, stack.nbt),
                            sample = { container = def.peripheral, slot = stack.slot,
                                name = stack.name, nbt = stack.nbt },
                        }) then
                            queued = queued + 1
                        end
                    end
                end
            end
        end
    end
    detailScan.queued = queued
    return queued
end

--- 每个 tick 处理一小段队列，绝不阻塞主循环：
---   ① 先吸收 worker 代查回来的详情（零阻塞）；
---   ② 字典里已经有答案的条目立刻写标签缓存；
---   ③ 剩下的请 worker 打包代查（一批 TAG_DETAIL_BATCH 个）；
---   ④ 没有可用 worker 时才本机读（每 tick 最多 MAX_TAG_SCANS_PER_TICK 个，阻塞但极少）。

--- 连接状态 + 标签扫描进度
function buildStatus()
    local current = protocol and protocol:status() or {}
    --- 服务端版本号：网页端用它做版本比对（不一致会提示并断开）
    current.version = IFM_VERSION
    current.tags = 0
    for _ in pairs(cache:tags()) do
        current.tags = current.tags + 1
    end
    if dispatch then
        current.detail = {
            depth = dispatch:depth("detail"),
            scanned = detailScan.scanned or 0,
            fromWorkers = detailScan.fromWorkers or 0,
        }
    end
    --- 存储容量（网页资源浏览的进度条）：已存物品/可存物品、已占用槽位/总槽位
    --- 只读统计，即使某个外设出问题也不能影响整包推送
    local okCapacity, capacity = pcall(containers.capacityStats, containers)
    if okCapacity and type(capacity) == "table" then
        current.capacity = capacity
    end
    --- 存储整理（1.8.0：自动进行，没有"手动启动"了）
    --- 计划算完会一次性把搬运任务排进 compact 队列，所以这里把队列的执行统计也带上，网页能看到进度。
    local compact = engine:compactStatus()
    if compact then
        if dispatch and dispatch.queues and dispatch.queues["compact"] then
            compact.pendingMoves = dispatch:depth("compact")
            compact.activeMoves = dispatch:activeDepth("compact")
            compact.waitingMoves = dispatch:waitingDepth("compact")
            compact.movesDone = dispatch.queues["compact"].done or 0
            compact.movesDropped = dispatch.queues["compact"].dropped or 0
        end
        current.compact = compact
    end
    --- 槽位堆叠上限扫描（用户第 5 项）：整理计划的输入之一，诊断/网页能看到还差多少没扫到
    if containers and containers.stackScanStatus then
        local stack = { rounds = stackScanStats.rounds or 0, asked = stackScanStats.asked or 0,
            containers = stackScanStats.lastContainers or 0, known = 0, unknown = 0, skippedUnknown = 0 }
        if engine and engine.Containers then
            stack.skippedUnknown = engine.Containers.stackLimitUnknown or 0
        end
        --- 扫描每个容器的槽位状态要遍历一遍快照：2 秒算一次就够（网页只是看个大概）
        local now = Util.now()
        if not current.stackScanCache or now - (current.stackScanCache.at or 0) > 2000 then
            for _, target in ipairs(containers:stackScanTargets()) do
                local status = containers:stackScanStatus(target.container)
                stack.known = stack.known + (status.known or 0)
                stack.unknown = stack.unknown + (status.unknown or 0)
            end
            current.stackScanCache = { at = now, known = stack.known, unknown = stack.unknown }
        else
            stack.known = current.stackScanCache.known or 0
            stack.unknown = current.stackScanCache.unknown or 0
        end
        current.stackScan = stack
    end
    --- IFMWorker 搬运卸载状态：worker 数量 / 在飞任务 / 累计完成数（网页顶部会显示）
    if transfer then
        current.transfer = transfer:status()
    end
--- （1.7.0：settings.scan 已删除 —— 扫描由 storageScan / inputScan 队列驱动）
    --- 调度时间片设置（网页「设置」面板）：每条队列每次轮到自己时最多几步
    current.schedule = store:scheduleSettings()
    --- 调度器运行状态（各队列深度 / 服务数 / 模式 / 每轮耗时）
    if dispatch then
        current.dispatch = dispatch:status()
    end
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
--- 先按“名称 + 种类”找；找不到再只按名称在物品/流体两种容器里找一遍 ——
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
--- 用户规则：interaction / output 角色的容器**按设计不可读** —— 这里明确说明，
--- 绝不返回"看起来是空的"（那是静默失败：网页会显示空容器，其实是我们没读）。
local function containerView(payload)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = "\\u5BB9\\u5668\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728" }
    end
    if not containers:isReadableContainer(def.name, kind) then
        return {
            error = "\\u4EA4\\u4E92/\\u8F93\\u51FA\\u89D2\\u8272\\u7684\\u5BB9\\u5668\\u4E0D\\u53C2\\u4E0E\\u8BFB\\u53D6"
                .. "\\uFF08\\u8BBE\\u8BA1\\u89C4\\u5219\\uFF1A\\u53EA\\u6309\\u6210\\u529F\\u642C\\u8FD0\\u91CF\\u8BB0\\u8D26\\uFF09",
            name = def.name,
            kind = kind,
            role = def.role,
            peripheral = def.peripheral,
            usable = false,
            notReadable = true,
        }
    end
    local usable = containers:supports(def.name, kind)
    local problem = nil
    if not usable then
        --- 注意别写成 `usable and nil or unusableReason(...)`：usable 为真时那个 or 也会执行一遍
        --- （Lua 的经典陷阱），白问一次外设/定义。
        problem = containers:unusableReason(def.name, kind)
    end
    local out = {
        name = def.name,
        kind = kind,
        role = def.role,
        peripheral = def.peripheral,
        usable = usable,
        problem = problem,
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

--- 交互容器管理：手动搬运（1.7.0 起进入「手动操作队列」）。
---   dir = "out"：把这个容器里的资源搬到存储容器（role = storage）
---   dir = "in" ：把存储容器里的资源搬进这个容器
--- 队列规则（与其它队列一致）：
---   * 有 worker 就交给 worker（不再"临时摘掉调度器由本机搬"）；
---   * 每次调度只做一步（一次 pushItem/pushFluid 调用）；
---   * 这一步搬不动 / 失败 → 丢弃任务（失败时丢弃）；
---   * 这一步搬到了但还没搬够 → 回队尾，下一轮接着搬。
local manualSeq = 0
local function runManualTask(task, now)
    local def = store:findContainer(task.container, task.kind)
    if not def then
        log("Manual move dropped: container %s is gone", tostring(task.container))
        return false
    end
    local kind = task.kind
    local resource = task.resource
    --- 用户第 2 项（1.9.0）：所有角色的容器都会被扫描（海龟由它自己上报物品栏），
    --- 所以「取出」对任何角色都成立 —— 内容从**快照**读（`containers:stacks/tanks`），
    --- 以前那条"interaction / output 不可读 → 只能放入"的拒绝分支已经没有意义，已删除。
    local entries = task.entries
    if not entries or now - (task.listedAt or 0) >= 1000 then
        -- 源容器当前内容（缓存/快照；不额外触发扫描）
        entries = {}
        if task.dir == "out" then
            if kind == "item" then
                for _, stack in ipairs(containers:stacks(def.name)) do
                    if stack.name == resource then
                        entries[#entries + 1] = { ref = stack.slot, amount = tonumber(stack.count) or 0 }
                    end
                end
            else
                for _, tank in ipairs(containers:tanks(def.name)) do
                    if tank.name == resource then
                        entries[#entries + 1] = { ref = tank.tank, amount = tonumber(tank.amount) or 0 }
                    end
                end
            end
            task.targets = task.targets or containers:byRole("storage", kind, "out")
        else
            task.targets = task.targets or containers:byRole("storage", kind, "in")
            for _, source in ipairs(task.targets) do
                if kind == "item" then
                    for _, stack in ipairs(containers:stacks(source)) do
                        if stack.name == resource then
                            entries[#entries + 1] = { ref = stack.slot, amount = tonumber(stack.count) or 0,
                                source = source }
                        end
                    end
                else
                    for _, tank in ipairs(containers:tanks(source)) do
                        if tank.name == resource then
                            entries[#entries + 1] = { ref = tank.tank, amount = tonumber(tank.amount) or 0,
                                source = source }
                        end
                    end
                end
            end
        end
        task.entries = entries
        task.listedAt = now
        task.index = 1
    end
    local remaining = math.max(0, tonumber(task.remaining) or 0)
    if remaining <= 0 then
        log("Manual container %s %s %s: %s x%s done", tostring(def.name), tostring(task.dir),
            tostring(kind), tostring(resource), tostring(task.moved or 0))
        return false
    end
    local targets = task.targets or {}
    if #targets == 0 then
        log("Manual container %s %s: no storage container available, task dropped", tostring(def.name),
            tostring(task.dir))
        return false
    end
    -- 一次调用 = 一步：挑当前源条目 -> 依次试目标
    local index = task.index or 1
    while index <= #entries do
        local entry = entries[index]
        if not entry then
            break
        end
        local from = entry.source or def.name
        for _, target in ipairs(targets) do
            local to = (task.dir == "out") and target or def.name
            local got, reason
            if kind == "item" then
                got, reason = containers:pushItem(from, entry.ref, math.min(remaining, entry.amount), to)
            else
                got, reason = containers:pushFluid(from, math.min(remaining, entry.amount), resource, to)
            end
            if reason == "pending" then
                task.index = index
                --- 已交给 worker：进"另一个队列"，下一个 tick 再来看结果（不是失败，别丢）
                return "pending"
            end
            got = tonumber(got) or 0
            if got > 0 then
                task.moved = (task.moved or 0) + got
                task.remaining = remaining - got
                task.index = index
                if task.remaining <= 0 then
                    log("Manual container %s %s %s: %s x%s done", tostring(def.name), tostring(task.dir),
                        tostring(kind), tostring(resource), tostring(task.moved))
                    return false
                end
                --- 还差一些：这一步先做完一次搬运，剩下的下一个 tick 继续（“pending”= 还没做完）
                return "pending"
            end
            if reason then
                task.reason = reason
            end
        end
        index = index + 1
    end
    log("Manual container %s %s %s: %s - task dropped (%s)", tostring(def.name), tostring(task.dir),
        tostring(kind), tostring(resource), tostring(task.reason or "nothing left to move"))
    return false
end

local function containerMove(payload, dir)
    local def, kind = findContainerByPayload(payload)
    if not def then
        return { error = "\\u5BB9\\u5668\\u5B9A\\u4E49\\u4E0D\\u5B58\\u5728" }
    end
    if not containers:supports(def.name, kind) then
        return { error = containers:unusableReason(def.name, kind) or "\\u5BB9\\u5668\\u4E0D\\u53EF\\u7528" }
    end
    --- 用户规则：取出（dir = "out"）必须读源容器（"里面有哪些、各多少"），而 interaction / output
    --- 按设计不可读 → 当场拒绝并把原因回给网页（不许"已排队"然后默默什么都不做）。
    if dir == "out" and not containers:isReadableContainer(def.name, kind) then
        return {
            error = "\\u4EA4\\u4E92/\\u8F93\\u51FA\\u89D2\\u8272\\u7684\\u5BB9\\u5668\\u4E0D\\u53C2\\u4E0E\\u8BFB\\u53D6"
                .. "\\uFF08\\u8BBE\\u8BA1\\u89C4\\u5219\\uFF09\\uFF0C\\u4E0D\\u80FD\\u4ECE\\u91CC\\u9762\\u53D6\\u51FA"
                .. "\\uFF1B\\u8BF7\\u6539\\u7528\\u201C\\u653E\\u5165\\u201D\\u6216\\u628A\\u5B83\\u5F53\\u673A\\u5668\\u8F93\\u51FA",
            notReadable = true,
        }
    end
    local resource = tostring(payload.resource or "")
    if resource == "" then
        return { error = "\\u8BF7\\u5148\\u9009\\u62E9\\u7269\\u54C1/\\u6D41\\u4F53" }
    end
    local count = math.max(1, tonumber(payload.count) or 1)
    --- 搬运顺序按存储优先级：out（搬进存储）高优先级在前；in（从存储搬出）低优先级在前
    local targets = containers:byRole("storage", kind, dir == "out" and "out" or "in")
    if #targets == 0 then
        return { error = "\\u6CA1\\u6709 storage \\u89D2\\u8272\\u7684\\u5B58\\u50A8\\u5BB9\\u5668" }
    end
    manualSeq = manualSeq + 1
    local task = {
        key = "manual:" .. tostring(manualSeq),
        dir = dir,
        container = def.name,
        kind = kind,
        resource = resource,
        remaining = count,
        moved = 0,
        targets = targets,
    }
    if not dispatch or not dispatch:enqueue("manual", task) then
        return { error = "\\u8C03\\u5EA6\\u5668\\u4E0D\\u53EF\\u7528" }
    end
    log("Manual container %s %s %s x%s queued (manual queue)", tostring(def.name), tostring(dir),
        tostring(resource), tostring(count))
    return { success = true, queued = true, moved = 0 }
end

--- 用户第 3 项：容器被移除之后（外设拔了 / 定义删了 / 定义换到别的外设），**立刻**清掉从它那里读到的内容，
--- 并让网页马上收到删除（不等 3 秒的墓碑延迟）—— 否则网页上会一直留着"已经读不到的物品"。
--- 返回被清掉内容的外设数量。
local function forgetRemovedContainers(reason)
    local dropped = containers:pruneMissingPeripherals(reason)
    if dropped > 0 then
        --- 真的有东西被清掉：下一次推送立刻下发删除（cache.revision 变了 → 推送马上发生）
        protocol:expediteDeletions()
        cache:markDirty()
    end
    return dropped
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
            log.warn("Client version mismatch: client=%s server=%s (the browser will show a warning)",
                payload.version, IFM_VERSION)
        end
    end
    if action == "ping" or action == "heartbeat" then
        return { status = "alive" }
    end
    -- 每次网页请求都在终端与网页控制台留一行：用来确认请求确实到达了服务端（排查"点了没反应"）
    log("request: %s", tostring(action))
    if action == "save" then
        --- 用户第 2 项（请求超时）：**绝不在请求里同步写盘** ——
        --- 一次真实的文件写（cache.json 里可能存着成百上千条物品标签）能卡几十秒，
        --- 期间主循环完全不转：网页所有请求超时（客户端 30 秒超时还会顺手做一次全量同步，
        --- 界面就会"整块消失再出现"）、worker 因为收不到主控消息被判掉线（时而在线时而不在线）、
        --- 中继也可能因为长时间没响应直接关掉连接（"attempt to use a closed file"）。
        --- 现在只标脏，交给去抖写盘（cache:tick / store:tick，默认 3 秒一次）。
        store:markDirty()
        cache:markDirty()
        return { success = true, queued = true }
    elseif action == "get_definitions" then
        return collectSnapshot()
    elseif action == "scan_tags" then
        local queued = queueTagScan()
        return { success = true, queued = queued }
    elseif action == "clear_tags" then
        cache:clearTags()
        --- 只标脏：清标签也会改 cache.json，同步写盘同样会把请求拖成"30 秒超时"
        cache:markDirty()
        return { success = true }
    elseif action == "compact_storage" then
        --- 1.8.0（用户第 4 项）：手动启动整理的功能已移除 —— 整理是自动的：
        --- compact 队列为空时，调度器的生成器会算一遍搬运计划并生成所有搬运任务。
        --- 这里保留一个明确的回复（老网页点到它时不会"什么都没发生"）。
        log("compact_storage is gone (1.8.0): storage compaction runs automatically when the compact queue is empty")
        return { success = false, error = "storage compaction is automatic now (see the compact queue in the scheduler panel)" }
    elseif action == "set_schedule_settings" then
        --- 调度权重（1.8.0）：每条队列 0.01 ~ 1-0.01n 的小数（不允许 0），**归一化后总和 = 1**。
        --- 校验走 Store:set；保存前先归一化（手改过的值也能用），保存后立刻应用并回传生效值。
        local slices = type(payload.slices) == "table" and payload.slices or nil
        if not slices then
            return { error = "slices must be a table of { queue = weight 0.01..1-0.01n }" }
        end
        local normalized = Store.normalizeSlices(slices)
        --- 用户第 5 项：走 Store:patchSettings（**局部覆盖**）—— Store:set 是整条替换，
        --- 直接提交 { slices, sendLog = false } 会把 localPool 这个键一起丢掉、读回来又回落成
        --- 默认 true，表现就是"关掉一个开关，另一个自己打开，两个永远不能同时关闭"。
        local data = { slices = normalized }
        --- 用户第 1 项：主控本机协程池开关（缺省开；只在有 worker 在线时才生效，见 Transfer:localWorkAllowed）
        if payload.localPool ~= nil then
            data.localPool = payload.localPool == true
        end
        --- 用户第 1 项：给网页发日志的开关（日志是 WS 上最大的一块流量）
        if payload.sendLog ~= nil then
            data.sendLog = payload.sendLog == true
        end
        --- 用户第 4 项：自动整理的空槽位阈值（0 ~ 1；空槽位比例低于它才整理）
        if payload.compactFreeRatio ~= nil then
            local ratio = tonumber(payload.compactFreeRatio)
            if not ratio then
                return { error = "compactFreeRatio must be a number between 0 and 1" }
            end
            if ratio < 0 then
                ratio = 0
            elseif ratio > 1 then
                ratio = 1
            end
            data.compactFreeRatio = ratio
        end
        local ok, err = store:patchSettings(Store.SCHEDULE_NAME, data, { force = true })
        if not ok then
            log("Save schedule settings failed: %s", tostring(err))
            return { error = err }
        end
        local applied = store:scheduleSettings()
        if dispatch then
            dispatch:applySlices(applied.slices)
        end
        --- 用户第 1 项：把"主控自己处理任务"开关应用到本机协程池（没有 worker 时它照旧干活）
        if transfer then
            transfer:setLocalWorkEnabled(applied.localPool)
        end
        --- 用户第 1 项：把"给网页发日志"开关应用到 WS 推送
        if protocol then
            protocol:setSendLog(applied.sendLog)
        end
        --- 用户第 4 项：把"自动整理的空槽位阈值"应用到整理器（0 = 从不整理，1 = 总是整理）
        if engine and engine.setCompactFreeRatio then
            engine:setCompactFreeRatio(applied.compactFreeRatio)
        end
        --- 用户第 2/4 项：这里**不要**同步写盘（写盘慢 → 请求 30 秒无响应 → 网页上开关看着"自己弹回去"）；
        --- 只标脏，由去抖写盘（store:tick，默认 3 秒）落盘。
        store:markDirty()
        local parts = {}
        for _, queue in ipairs(applied.queues) do
            parts[#parts + 1] = queue .. "=" .. tostring(applied.slices[queue])
        end
        log("Schedule slices updated: %s", table.concat(parts, " "))
        return { success = true, schedule = applied }
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
        --- 用户第 5 项：自动生成的虚拟定义（turtle_crafter 的海龟机器 / 交互容器）不允许改写或覆盖 ——
        --- 它们由 IFMMaster:syncTurtleCrafters 维护，手改只会被下一次同步冲掉，这里直接拒绝更清楚。
        if store:virtualOf(setKind)[name] then
            return { error = "\\u81EA\\u52A8\\u751F\\u6210\\u7684\\u5B9A\\u4E49\\u4E0D\\u80FD\\u4FEE\\u6539" }
        end
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
            log.error("Save %s failed: %s", tostring(setKind), tostring(err))
            return { error = err }
        end
        log("Saved %s: %s", tostring(setKind), tostring(name))
        --- 容器定义改过之后：旧外设读到过的内容立刻作废（换外设 / 换角色 / 换种类都可能，用户第 3 项）
        if setKind == "containers" then
            forgetRemovedContainers("container definition saved")
        end
        -- 保存后的收尾工作：出错也不能让这次请求没有响应（否则网页只会看到“超时”）
        local okAfter, afterErr = pcall(function()
            engine:reconcile()
            --- 用户第 4 项（请求超时）：**不要**在这里同步写盘。store:flush() 是一次真实的文件写，
            --- 盘慢/盘满时能卡几十秒 —— 网页的 set_schedule_settings 就变成"30 秒无响应"，
            --- 开关/权重看着像"自己弹回去了"。这里只标脏，落盘交给去抖写盘（store:tick，默认 3 秒）。
            store:markDirty()
        end)
        if not okAfter then
            log("Post-save cleanup failed for %s: %s", tostring(setKind), tostring(afterErr))
        end
        return { success = true, kind = setKind, name = name }
    end
    local deleteKind = DELETE_KINDS[action]
    if deleteKind then
        --- 用户第 5 项：自动生成的虚拟定义不能删（海龟一下线它自己就没了；手工删没有意义）
        if store:virtualOf(deleteKind)[payload.name] then
            return { error = "\\u81EA\\u52A8\\u751F\\u6210\\u7684\\u5B9A\\u4E49\\u4E0D\\u80FD\\u5220\\u9664" }
        end
        --- 幂等删除（用户第 2 项）：定义本来就不在 = 用户要的结果已经达成 → 直接算成功。
        --- 为什么会有这种请求：网页上的"外设缺失"列表可能比服务端旧（推送丢过、或页面缓存），
        --- 以前这里返回"定义不存在"，用户点「一键删除」就变成一屏报错
        --- （现场：删除了 0 条，8 条失败）。成功返回后网页会把这条失效条目收掉。
        if not store:get(deleteKind, payload.name, payload.kind) then
            log("Delete %s %s: already gone (nothing to do)", tostring(deleteKind), tostring(payload.name))
            return { success = true, gone = true, kind = deleteKind, name = payload.name }
        end
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
        elseif deleteKind == "containers" then
            --- 用户第 3 项：容器定义被删 → 从这个外设读到的内容立刻清除，并让网页马上收到删除
            forgetRemovedContainers("container definition deleted")
        end
        engine:reconcile()
        --- 用户第 4 项：不在这里同步写盘（写盘慢会把请求拖成"30 秒超时"）—— 只标脏
        store:markDirty()
        --- 同样不能同步写盘：删除是网页上最常点的操作之一，卡一次就是 30 秒超时
        --- （超时后客户端会重新全量同步，界面还会"整块消失再出现"）
        cache:markDirty()
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
        --- 不阻塞写盘（发送请求本来就可能点很多次）：只标脏，落盘交给去抖写盘
        cache:markDirty()
        store:markDirty()
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
        -- 让 IFMWorker 代扫一个容器（一条查询只查一个容器，见 modules/transfer.lua 的 startScanBatch）
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
        --- 发货 id 用 deliveryId 字段传：请求里顶层的 id 是请求关联号（响应要靠它配对），
        --- 早先前端把发货 id 也写成 id，把关联号覆盖掉 → 响应回来了网页却等不到（1.6.7 修）。
        --- 这里仍然接受旧的 id 字段（老前端/缓存的页面），保证兼容。
        local deliveryId = tonumber(payload.deliveryId or payload.id)
        local removed = cache:removeDelivery(deliveryId)
        --- 不在这里同步写盘：一次真实的文件写可能卡几十秒 → 网页超时（还会触发全量同步，
        --- 底部面板"整块消失再出现"）、worker 被判掉线。去抖写盘几个 tick 内就会落盘。
        cache:markDirty()
        return { success = true, removed = removed and true or false, id = deliveryId }
    elseif action == "delete_deliveries" then
        --- 用户第 6 项：「发送中」区域也要有一个"全部删除"（以前只有「待发送」有清空按钮）。
        --- 逐条走 removeDelivery（与单条删除同一套语义），并清掉每条的在飞搬运记忆
        --- （token 见 Recipe:processDeliveries 的 "delivery:<id>"）—— 否则删掉后残留的 token
        --- 会让同名的新发货被当成"还在飞"。
        local removed = 0
        for _, delivery in ipairs(cache:deliveries()) do
            if cache:removeDelivery(delivery.id) then
                removed = removed + 1
            end
        end
        --- 一条都不剩了：把"在飞搬运"的记忆按前缀一次清掉（token 见 Recipe:processDeliveries 的
        --- "delivery:<id>"）—— 否则残留的 token 会让同名的新发货被当成"还在飞"。
        if engine.forgetPendingMovesWithPrefix then
            engine:forgetPendingMovesWithPrefix("delivery:")
        end
        --- 与单条删除一样：不在这里同步写盘（去抖写盘几个 tick 内会落盘）
        cache:markDirty()
        return { success = true, removed = removed }
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
    -- 定时推送间隔（秒）：没有变化时的兜底刷新频率（有变化会立刻推，见下）。
    -- 注意：一次推送要全量收集（每个容器一次外设调用，有线网络上 ≈1 个服务器刻/次），
    -- 12 个容器就 ~0.6s，所以兜底频率别设太小。
    updateInterval = 2,
    -- 增量推送的硬下限（毫秒）：1.6.12 起默认 0 = 不设硬限制（服务端不应当对 WebSocket 收发数据包做速率硬限制）。推送改由“状态变更计数”驱动：
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
transfer = Transfer.new({ log = log, Peripherals = peripherals, Modems = Modems, scanFreshMs = 1000 })
containers:setTransferProvider(transfer)
--- 容器扫描：1.7.0 起由 storageScan / inputScan 队列驱动（Transfer:submitScan → worker 代读，
--- 没有 worker 时本机 scanNow）；容器模块自己不再持有任何"扫描间隔 / 预算"。
--- 物品详情卸载：getItemDetail 同样是阻塞调用（≈1 个服务器刻/次），整理要 maxCount、
--- 标签扫描要 tags，几百种物品全压在主控身上会明显卡顿 —— 打包交给 worker 代查。
containers:setDetailProvider(transfer)
--- 分布式（1.5.0）：只把版本号交给调度器 —— worker 只做搬运/查询，流程/整理/中继都在主控本机
transfer:setContext({
    version = IFM_VERSION,
})
--- 1.8.0：主控自己也是一个执行者 —— 没有空闲 worker（或根本没 worker）时，
--- 搬运交给本机的协程池并行执行（最多 32 条同时进行，见 Transfer:submitLocalJob）。
--- 一次外设调用 ≈1 个游戏刻，32 个协程同时发出去就是 32 倍吞吐；主循环不再被一次搬运卡住。
transfer.executeLocal = function(job)
    return containers:runLocalJob(job)
end

--- ===== 任务调度器（1.7.0）=====
--- 每个来源一个队列，队列之间轮转（round-robin），每个队列各有时间片（网页「设置」可改）。
--- 队列的推进规则：
---   * 有 worker 且都忙 → 本次调度不推进队列（写盘 / 心跳 / 超时 / 推送照做）；
---   * 没有 worker → 主控本机执行，且每次调度只推进一步；
---   * 任务失败/未完成：流程队列回队尾（retry），其它队列直接丢弃（drop，由生成器下次重建）。
--- 目前（P1）只有流程队列接了执行体；容器扫描 / 入库 / 出库 / 整理 / 物品详情 / 交互容器
--- 这几条队列在 P2 接入（现在先把队列与生成器骨架搭好，行为与以前一致）。
dispatch = Dispatch.new({ log = log, store = store, cache = cache, transfer = transfer, Queue = Queue })
--- 搬运任务的执行者：containers 把任务入队，队列轮到它时调用 executeMove（见 modules/containers.lua）
containers:setDispatcher(dispatch)
local scheduleSettings = store:scheduleSettings()
dispatch:applySlices(scheduleSettings.slices)
--- 用户第 1 项：开机应用"主控自己处理任务"开关（没有 worker 在线时本机池照旧干活）
transfer:setLocalWorkEnabled(scheduleSettings.localPool)
--- 用户第 1 项：开机应用"给网页发日志"开关
protocol:setSendLog(scheduleSettings.sendLog)
--- 用户第 4 项：开机应用"自动整理的空槽位阈值"（存储容器空槽位不足这个比例才整理）
if engine and engine.setCompactFreeRatio then
    engine:setCompactFreeRatio(scheduleSettings.compactFreeRatio)
end

-- 队列定义：needs = 任务需要什么能力（none / query / move）。
-- 各队列的 run 自己决定"这一步是继续（true，回队尾）/ 结束（false）/ 丢弃（"drop"）"：
--   * 流程队列：没结束就 true（均匀推进所有进程）；
--   * 手动操作：搬够了 false，还没搬够 true，搬不动 / 失败 "drop"（失败即丢弃）。
dispatch:addQueue("process", {
    needs = "none", policy = "retry",
    run = function(task, now)
        return engine:stepProcessOnce(task.name, now)
    end,
})
-- 容器扫描队列（storageScan / inputScan）：一步 = 扫一个容器。双队列策略（用户第 4 项）：
--   * 扫成功 / 扫失败**都回到"另一个队列"**（下一个 tick 先问新鲜度缓存，只有真的过时才再扫一次）——
--     于是"一个容器一个 tick 只扫一次"是结构保证的，不可能出现"同一刻连扫好几遍"；
--   * 容器外设卸载 / 容器角色被删 → maintainScanQueues 把它的任务从两个队列里撤掉；
--     外设回来 / 新增存储容器角色 → 立刻补一条扫描任务进"正在执行"队列；
--   * 扫到未缓存的物品 → 生成细节扫描任务；输入容器扫到东西 → 生成入库任务（见 afterScan）。
local function isInputContainer(peripheralName)
    for _, def in ipairs(store:list("containers")) do
        if def.peripheral == peripheralName then
            return def.role == "input"
        end
    end
    return false
end

--- 扫描完成之后的后续任务（用户第 4 项）：
---   存储容器 → 扫到还没详情的物品就排细节扫描任务（字典与队列都会去重）；
---   输入容器 → 扫到东西就生成入库任务（重复提交由 Containers.moveInflight 去重）。
local function afterScan(name, now)
    if isInputContainer(name) then
        local ok, err = pcall(engine.drainInputContainers, engine, now, name)
        if not ok then
            log("input container drain failed (%s): %s", tostring(name), tostring(err))
        end
        return
    end
    queueMissingDetails()
end

local function scanTaskRunner(task, now)
    local name = task.name
    if not peripherals:exists(name) then
        return "drop"                      -- 外设没了：撤掉任务（它回来时生成器会重新排一条）
    end
    local state, value = transfer:submitScan(name)
    if state == "done" and type(value) == "table" then
        --- 新鲜度缓存命中：多半已经写进快照了 —— 只有确实比快照新才再写一次（省掉重复整理）
        local model = containers:modelOf(name)
        local at = tonumber(value.at) or now
        if not model or at > (model.stamp or 0) then
            containers:applyScan(name, value.items, value.tanks, at)
            afterScan(name, now)           -- 真的拿到新内容了才生成后续任务
        end
        return true                        -- 回"另一个队列"（下一个 tick 再看新鲜度）
    end
    if state == "pending" then
        return "inflight"                  -- worker 在扫：结果由 onQueryResult 收（它会写快照）
    end
    --- "local"（没有空闲的查询 worker / 槽位满了）：主控本机读一次（阻塞约 1 刻），然后照旧回另一个队列
    containers:scanNow(name)
    afterScan(name, now)
    return true
end
dispatch:addQueue("storageScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("inputScan", { needs = "query", policy = "retry", run = scanTaskRunner })
--- 交互容器扫描队列（用户第 2 项，1.9.0）：interaction 角色的容器**也要扫**——
--- 抽取产物、挑选输入槽位都按内容快照决策（见 modules/containers.lua 的读取规则）。
--- 海龟不在其中：它不是 inventory 外设，扫不到，由 IFMCrafter 自己上报（transfer.onCrafterInventory）。
dispatch:addQueue("interactionScan", { needs = "query", policy = "retry", run = scanTaskRunner })
--- 输出容器扫描队列（用户第 1 项，1.9.x）：output 角色**单独一条队列**（与交互容器分开）——
--- 机器输出 / 发货目标的内容也要有快照，抽取产物才有的依据。
dispatch:addQueue("outputScan", { needs = "query", policy = "retry", run = scanTaskRunner })

--- 扫描队列的容器维护（用户第 4 项）：
---   容器外设上线（或用户给它加了存储/输入角色）→ 加一条扫描任务到"正在执行"队列；
---   容器外设卸载 / 角色被删 → 从两个队列里撤掉它的扫描任务（否则它会一直重试一个不存在的外设）。
local function maintainScanQueues()
    --- 用户第 2 项（1.9.0）：**任何角色**的容器都参与扫描（storage / input / interaction / output），
    --- 其中输出容器单独一条队列（用户第 1 项）。
    --- 这条规则写在 Containers:scanQueueTargets() 里（可自测），这里只负责按它的结果增删任务；
    --- 扫不了的外设（海龟：没有 inventory）不会出现在它的结果里 —— 海龟的内容由它自己上报。
    local want = containers:scanQueueTargets()
    for _, queueName in ipairs({ "storageScan", "inputScan", "interactionScan", "outputScan" }) do
        local keep = want[queueName] or {}
        for peripheralName in pairs(keep) do
            if not dispatch:isQueued(queueName, peripheralName) then
                dispatch:enqueue(queueName, { key = peripheralName, name = peripheralName })
            end
        end
        --- 不在 keep 里的（容器外设卸载 / 角色改成 interaction / 定义被删）→ 从队列撤掉，
        --- 否则它会一直重试一个不该被扫描的容器。
        dispatch:removeWhere(queueName, function(task)
            return type(task) == "table" and task.name ~= nil and keep[task.name] ~= true
        end)
    end
end

-- 搬运队列（inventoryIn / inventoryOut / compact）：一步 = 执行一条搬运任务。
--   * 有 worker：交给 worker（Containers:runItemMove 里的 Transfer 请求，对任务键幂等）；
--   * 没有空闲 worker：主控本机协程池并行执行（1.8.0，不再有"退回同步搬"的模式）；
--   * 未完成 / 在等 worker 回报：返回 "pending" → 进"另一个队列"，下一个 tick 再来看结果
--     （这样一次搬运一个 tick 只推进一次，而结果照样会被结算）；
--   * 搬不动 / 失败：由队列策略决定（入库 = 丢弃；出库 = 回"另一个队列"重试剩余量；
--     整理 = 丢弃，下次计划重新生成）。
--- 搬运队列的执行体。三种搬运队列的策略不同，所以按策略包一层（见下面的 addQueue）：
---   "retry"（出库）：没搬完 → 返回 true → 进 waiting，下一轮继续搬剩余量
---   "drop"（入库 / 整理）：没搬完 → 返回 true → 直接丢弃；丢弃时立刻结算记录（归还预留），
---                          否则那批物品会被预留占着直到 60 秒兜底清理（看起来像丢了）
local function makeMoveRunner(queuePolicy)
    return function(task)
        local result = containers:executeMove(task)
        if result == "drop" or result == false or result == nil then
            return result
        end
        if type(task) == "table" and task.state == "inflight" then
            return "pending"               -- 在等 worker 回报：还没做完，别丢
        end
        if result == true and queuePolicy == "drop" then
            containers:abandonMove(task)
        end
        return result                      -- true：没搬完 / 失败 → 按队列策略
    end
end
--- 入库任务（用户第 4 项）：不设双队列，成功或失败都移除（失败即丢弃，等下一次扫描重新生成）
dispatch:addQueue("inventoryIn", { needs = "move", policy = "drop", run = makeMoveRunner("drop") })
--- 出库任务（用户第 4 项）：不完全 / 失败 → 进"另一个队列"；每个 tick 开始前并回"正在执行"队列
dispatch:addQueue("inventoryOut", { needs = "move", policy = "retry", run = makeMoveRunner("retry") })
--- 整理搬运（用户第 4 项）：不设双队列，执行后无条件移除；计划由生成器在队列为空时生成
dispatch:addQueue("compact", { needs = "move", policy = "drop", run = makeMoveRunner("drop") })
--- 槽位堆叠上限（"堆数"）扫描队列（用户第 5 项）：不设双队列，一步扫一个存储容器，执行后无条件移除。
---   * 一步 = 把这台容器里"还没扫到堆叠上限（maxCount）"的若干物品类型问一遍（有 worker 就交给 worker
---     代查），顺手把"槽位数量"读出来；结果进物品详情字典，整理计划只读字典（不临场问外设、也不猜 64）。
---   * 队列为空时由生成器把当前所有存储容器一次性排进来（扫完就出队；下次空了再排一轮）。
---   （累计统计 stackScanStats 的声明在文件上方 —— 快照函数要先用到它）
local function stackScanRunner(task)
    local name = task.container
    if not name then
        return "drop"
    end
    local peripheralName = containers:peripheralOf(name, "item")
    if not peripheralName or not peripherals:exists(peripheralName) then
        return "drop"                       -- 外设没了：丢弃（它回来时生成器会重新排一条）
    end
    --- 角色被改成 interaction / output / input 之后这条老任务就是多余的（扫描只服务 storage 整理）
    if containers:defRole(name, "item") ~= "storage" then
        return "drop"
    end
    local asked = containers:stackScanStep(name)
    stackScanStats.asked = (stackScanStats.asked or 0) + (tonumber(asked) or 0)
    return false                            -- 无条件移除（用户第 5 项）
end
dispatch:addQueue("stackScan", { needs = "query", policy = "drop", run = stackScanRunner })

-- 物品详情队列（用户第 4 项）：不设双队列，一步做完就无条件移除。
--   * 有 worker：交给它代查（结果由 transfer.onDetailResult 结束任务，字典由 absorb 流程写入）；
--   * 没有 worker：主控本机读一次（阻塞约 1 刻）；
--   * 拿不到 / 失败：丢弃（物品可能已经不在了；下一次扫描会重新生成）；
--   * 字典里已经有答案（含"问过拿不到"的负缓存）：丢弃。
dispatch:addQueue("detail", {
    needs = "query", policy = "drop",
    run = function(task)
        local sample = task.sample
        if not sample or not sample.container or not sample.name then
            return "drop"
        end
        local _, known = containers:cachedItemDetail(sample.name, sample.nbt)
        if known then
            return false
        end
        if not peripherals:exists(sample.container) then
            return "drop"
        end
        if transfer:workerCount() > 0 then
            local state = containers:requestItemDetails({ sample })
            if state == "pending" then
                return "inflight"
            end
            --- "local"：查询 worker 的槽位满了 —— 落下去，由下面这段本机读一次
        end
        local detail = containers:detail(sample.container, sample.slot,
            { name = sample.name, nbt = sample.nbt })
        if type(detail) == "table" then
            storeTags(sample.name, detail)
            detailScan.scanned = (detailScan.scanned or 0) + 1
        end
        return false
    end,
})
--- 手动搬运（用户第 4 项）：不设双队列，执行后无条件移除。
--- 唯一例外：这一手已经交给 IFMWorker 还在飞时，runManualTask 返回 "pending" —— 那是"还没做完"，
--- 进"另一个队列"下一个 tick 再看（否则用户点的那一次搬运会只搬一半就没人接着做了）。
dispatch:addQueue("manual", {
    needs = "move", policy = "drop",
    run = function(task, now)
        return runManualTask(task, now)
    end,
})

--- ===== turtle_crafter（用户第 3 项）：运行 IFMCrafter.lua 的海龟**自动**成为机器 =====
--- 主控看到的海龟外设（peripheral 类型 = turtle）× 合成器 hello 里自报的网络外设名，
--- 两边一致 = "这台海龟正在跑合成器" → 配一个虚拟容器（role = interaction，输入与输出都是它自己：
--- 海龟没有 inventory 外设、读不到内容物，所以引擎只按"成功推送/抽取量"记账）+ 一台虚拟机器
--- （parallel 恒 1，一次只做一批）。虚拟定义不落盘（modules/store.lua 的 setVirtual），只在内存里生效。
local turtleSignature = nil
local function syncTurtleCrafters()
    local crafters = transfer and transfer.craftersForUi and transfer:craftersForUi() or {}
    local running = {}
    local parts = {}
    for _, crafter in ipairs(crafters) do
        if type(crafter.name) == "string" and crafter.name ~= "" then
            running[crafter.name] = crafter
            parts[#parts + 1] = crafter.name .. ":" .. tostring(crafter.version or "?")
        end
    end
    local turtles = peripherals:turtleNames()
    for _, name in ipairs(turtles) do
        parts[#parts + 1] = "turtle:" .. name
    end
    table.sort(parts)
    local signature = table.concat(parts, ",")
    if signature == turtleSignature then
        return                              -- 没变化：不重写虚拟定义（也避免每 tick 标脏/推网页）
    end
    turtleSignature = signature
    --- 用户第 4 项：把"正在跑 crafter 的海龟"名单交给 collectPeripherals（网页只列这些海龟）
    for name in pairs(runningCrafters) do
        runningCrafters[name] = nil
    end
    for name in pairs(running) do
        runningCrafters[name] = true
    end
    --- 预设机器类型恒定存在（否则流程定义里选不到它）
    store:setVirtual("machineTypes", { { name = Store.TURTLE_CRAFTER_TYPE } })
    local containerDefs, machineDefs = {}, {}
    for _, name in ipairs(turtles) do
        if running[name] then
            containerDefs[#containerDefs + 1] = {
                name = name, peripheral = name, kind = "item", role = "interaction",
                priority = 0, virtual = true,
            }
            machineDefs[#machineDefs + 1] = {
                name = name, type = Store.TURTLE_CRAFTER_TYPE, virtual = true, parallel = 1,
                label = running[name].label or name,
                itemInputs = { name }, itemOutputs = { name },
            }
        end
    end
    store:setVirtual("containers", containerDefs)
    store:setVirtual("machines", machineDefs)
    log("turtle_crafter: %d turtle(s) visible, %d running IFMCrafter (auto machines), %d ignored (no crafter on them)",
        #turtles, #machineDefs, math.max(0, #turtles - #machineDefs))
end

-- 维护：心跳 / worker 超时 / 任务重发（不属于"调度器推进"，worker 全忙也照做）
dispatch:setMaintain(function(now)
    transfer:tick(now)
    --- 海龟合成器上下线（syncturtles 内部有签名比对，没变化时不做任何事）
    syncTurtleCrafters()
    --- 用户第 2/3 项：海龟那份内容快照靠它自己上报 —— 定期催一份新的（超过 1.5s 就催，
    --- 同一台限流 2 秒），这样"抽产物 / 挑输入槽位"依据的快照不会过期。
    transfer:refreshCrafterReports(now)
end)

--- 合成链路（用户第 3 项）：引擎在 turtle_crafter 机器"材料输入完成"时会调它一次 ——
--- 交给 Transfer 走合成频道发给那台海龟（发出去就不管，见 Transfer:requestCraft）。
engine:setCraftProvider(function(spec)
    return transfer:requestCraft(spec)
end)

--- 海龟交互容器的内容快照（用户第 2/4 项）：它不是 inventory 外设，扫描队列扫不到它 ——
--- 它自己用 modem 上报物品栏（op = "inventory"：合成后 / 被索要 / 有货时每 5 秒一次）。
--- 这里把上报写进**同一个**内容快照入口（Containers:applyScan），于是抽取产物、挑选输入槽位
--- 都像普通容器一样"按快照决策"；旧的盲搬/盲抽路径（按槽位猜、按成功量记账）已整条删除。
--- size = 海龟物品栏的格数（16）：主控问不到它不是 inventory 的 size()，挑目标槽位要靠它。
transfer.onCrafterInventory = function(name, items, at, size)
    containers:applyScan(name, items, nil, at, size)
end

--- 扫描回报收尾：把**四条**扫描队列里这条容器的在飞任务都结束掉
--- （storageScan / inputScan / interactionScan / outputScan —— 用户第 1 项：输出容器单独一条队列）。
--- 为什么抽成一个函数：队列从三条变四条时，散落各处的 finishInflight 最容易漏掉一条，
--- 而漏掉的那条会一直重试同一个容器（"扫完不结算"）。
local function finishScanInflight(name)
    dispatch:finishInflight("storageScan", name)
    dispatch:finishInflight("inputScan", name)
    dispatch:finishInflight("interactionScan", name)
    dispatch:finishInflight("outputScan", name)
end

--- 用户第 2 项：代扫查询被丢掉（查询超时 / worker 被摘除）时，主控必须把队列里那条容器的
--- 在飞任务结束掉 —— 否则它永远挂在 inflight，`maintainScanQueues` 认为"已在队列里"不再补，
--- 那个容器**从此再也不扫**：表现就是"玩家把存储容器里的东西拿走了，网页上还一直显示着"。
--- 结束之后扫描队列下一轮就会重新排它（要么 worker 代扫、要么主控本机读）。
transfer.onQueryDropped = function(key, reason)
    local name = tostring(key or ""):match("^scan:(.+)$")
    if not name then
        return
    end
    finishScanInflight(name)
    log("Container scan for %s was dropped (%s) - it will be scanned again next round",
        tostring(name), tostring(reason or "unknown"))
end

--- worker 代扫回来了：写进容器快照，并结束对应的扫描队列任务（在飞 → 出队）
transfer.onQueryResult = function(_, key, message)
    local name = tostring(key or ""):match("^scan:(.+)$")
    if not name then
        return
    end
    --- 用户第 4 项（资源大面积消失）：worker 可能**看不到**这个容器（不在同一有线网络 / 区块没加载 /
    --- 外设刚被拆）—— 那种情况下它回报的是"扫到 0 个容器 + 空表"。以前主控照单全收，于是这个容器的
    --- 快照被清空（网页上大批资源凭空消失，往往只剩别的容器里还有的那几种）。
    --- 现在只接受"确实扫到了"的回报：扫不到就丢掉这次结果，保留旧快照等下一次扫描/本机读。
    ---
    --- 字段兼容（修 bug）：新 worker 报数值 `scanned`，1.8.2 及以前的 worker 只报 `scannedContainers` 表。
    --- 以前主控**只读** message.scanned，而 worker 从来不发这个字段 → 每一次成功的扫描都被当成
    --- "没扫到"丢掉（现场症状：container snapshot 的 staleAvg = 整个 uptime、扫描队列每秒空转）。
    local scanned = Containers.scanCountOfReply(message)
    if scanned == nil then
        --- 两个字段都没有 = 协议不匹配（worker 与主控版本不同）：
        --- 编码规范：不许静默失败 —— 记日志 + 计数，并丢弃这次结果（而不是假装"盲"）。
        containers:noteScanProtocolMismatch(name, "reply has neither scanned nor scannedContainers")
        finishScanInflight(name)
        return
    end
    if scanned < 1 then
        containers:noteBlindScan(name, "worker reported scanned=0")
        finishScanInflight(name)
        --- 用户第 2 项：worker 看不到这个容器（不在同一有线网络 / 区块没加载 / 外设刚被拆）——
        --- 以前只是"丢弃这次结果、保留旧快照" ⇒ 那个容器的内容会永久停在旧值
        --- （玩家把东西拿走、网页上还一直显示着）。现在补一次**主控本机读**。
        if peripherals:exists(name) then
            containers:scanNow(name)
            afterScan(name, os.epoch("utc"))
        end
        return
    end
    containers:applyScan(name, message.items, message.tanks, tonumber(message.at) or os.epoch("utc"))
    finishScanInflight(name)
    --- 用户第 7 项（输入容器里的东西始终没被取走）：扫描之后的后续任务生成（输入容器 → 入库 /
    --- 存储容器 → 补齐物品详情）以前只在"主控本机扫描"那条路径上调用（scanTaskRunner 的 "local"
    --- 分支），worker 代扫回报时漏掉了 —— 现场有 worker 时扫描基本都交给 worker，于是输入容器
    --- 只更新了快照、永远不成库。现在两条路径都走同一个 afterScan（它自己区分 input / storage）。
    afterScan(name, os.epoch("utc"))
end

--- worker 代查的物品详情回来了：结束 detail 队列里对应的在飞任务
--- （字典与标签由 absorbWorkerDetails 在生成器里统一写入）
transfer.onDetailResult = function(_, message)
    for _, entry in ipairs(type(message.details) == "table" and message.details or {}) do
        if type(entry) == "table" and entry.name then
            dispatch:finishInflight("detail", detailQueueKey(entry.name, entry.nbt))
        end
    end
end

-- 生成器：把新任务补进队列（纯内存）
dispatch:addGenerator(function(now)
    engine:maintain(now)
    containers:advanceTick()
    --- 容器扫描（用户第 4 项）：扫描任务是常驻的 —— 生成器只负责"容器上线/下线"的增删：
    ---   新容器外设（或用户新加的存储/输入角色）→ 补一条扫描任务到"正在执行"队列；
    ---   容器外设卸载 / 角色被删 → 从两个队列里撤掉它的扫描任务。
    maintainScanQueues()
    --- 槽位堆叠上限扫描（用户第 5 项）：队列为空 → 给当前所有存储容器各排一条扫描任务
    --- （扫完就出队；下次空了再排一轮 —— 已经扫到的物品类型不会再问，所以这个常驻扫描很便宜）
    if dispatch:depth("stackScan") == 0 then
        local targets = containers:stackScanTargets()
        for _, target in ipairs(targets) do
            dispatch:enqueue("stackScan", { key = "stack:" .. target.peripheral, container = target.container })
        end
        if #targets > 0 then
            stackScanStats.rounds = (stackScanStats.rounds or 0) + 1
            stackScanStats.lastContainers = #targets
        end
    end
    engine:enqueueActiveProcesses(dispatch)
    engine:processDeliveries(now)
    --- 整理搬运（用户第 4 项）：队列为空时计算搬运计划并生成所有搬运任务
    --- （计划本身是分批算的，见 Recipe:autoCompactStep —— 算完一次性把搬运任务全排进 compact 队列）
    if dispatch:depth("compact") == 0 then
        local okCompact, errCompact = pcall(engine.autoCompactStep, engine, now, dispatch)
        if not okCompact then
            log("Storage compact planning failed: %s", tostring(errCompact))
        end
    end
    engine:finishTick()
    --- 物品详情（detail 队列）：吸收 worker 代查回来的结果 → 排"扫描时看到但还没详情"的物品 →
    --- 低频清理标签缓存（按轮次，不是毫秒间隔）
    absorbWorkerDetails()
    queueMissingDetails()
    pruneTagCache()
end)

--- 日志同时打印到本地终端并推给网页（浏览器控制台打印）：
--- 这样即使没打开浏览器控制台，也能在 CC 终端看到引擎/流程/发送任务的具体原因。
Util.setLogHandler(function (text, seq, level)
    --- 用户第 2 项：终端按级别上色（信息=默认 / 警告=黄 / 错误=红）；
    --- 网页端按行首的 [warn] / [error] 标记上色（见 web/ifm-net.js 的 serverLog）
    local colour = Util.logColour and Util.logColour(level) or nil
    if colour and term and term.setTextColour and colours then
        pcall(term.setTextColour, colour)
        print(text)
        pcall(term.setTextColour, colours.white)
    else
        print(text)
    end
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

--- 调度节拍（1.7.0）：50ms = 1 个游戏刻（CC:T 能准确计时的最小时间片）。
--- 上一轮调度完成后才开始下一轮计时：一轮偶尔超过 50ms（例如没有 worker、本机读容器
--- 每次约 1 刻）时不会积压 timer 事件，也就不会出现"timer 事件永远消化不完"的情况。
local TICK = 0.05
local tickToken = nil
local armedAt = 0
local function armTick()
    tickToken = os.startTimer(TICK)
    armedAt = os.epoch("utc")
end
armTick()
local lastStatusPrint = os.epoch("utc")
local startedAt = os.epoch("utc")

--- 每 30 秒的状态摘要（同时打印到终端与浏览器控制台）：
--- 连接状态、每条发送任务的进度与原因、每个进程的状态/阶段/机器/原因
local function statusLine()
    local protocolStatus = protocol.status and select(2, pcall(protocol.status, protocol)) or nil
    local link = ""
    if type(protocolStatus) == "table" then
        --- 中继连接的健康度：活了多久 / 多久没收到任何入站消息 / 累计断开次数与最后一次的原因
        --- （闪断排查用；closes 持续增长而 connectedFor 很小 = 连接一直被关掉）
        link = string.format(" / link: up=%ds idle=%ds closes=%d%s",
            protocolStatus.connectedSeconds or 0,
            protocolStatus.idleSeconds or 0,
            protocolStatus.closes or 0,
            protocolStatus.lastCloseReason and (" (" .. tostring(protocolStatus.lastCloseReason) .. ")") or "")
    end
    local connection = protocol.connected and "relay:up" or "relay:down"
    local client = protocol.clientActive and "browser:on" or "browser:off"
    log("%s / %s / room %s / defs: containers=%d signals=%d filters=%d machines=%d processes=%d / uptime %ds%s",
        connection,
        client,
        room,
        #store:list("containers"),
        #store:list("signals"),
        #store:list("filters"),
        #store:list("machines"),
        #store:list("processes"),
        math.floor((os.epoch("utc") - startedAt) / 1000),
        link)
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

--- 慢调度明细：这一轮推了哪些队列（每条队列的深度/服务数）以及容器扫描的实测成本
slowDetails["dispatch"] = function()
    local dispatchStatus = dispatch:status()
    local parts = {}
    for _, queue in ipairs(dispatchStatus.queues) do
        parts[#parts + 1] = string.format("%s=%d", queue.name, queue.depth)
    end
    return string.format("%s | mode=%s steps=%d lastMs=%.1f maxMs=%.1f | %s",
        engine:tickStatsText(), tostring(dispatchStatus.mode), tonumber(dispatchStatus.steps) or 0,
        tonumber(dispatchStatus.lastMs) or 0, tonumber(dispatchStatus.maxMs) or 0,
        table.concat(parts, " "))
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
--- 调度器（1.7.0）：诊断报告里的队列深度 / 服务数 / 每轮耗时都从这里取
diagnose.dispatch = dispatch
--- 引擎（recipe）：诊断里的守卫计数（用户第 1 项：未定义行为必须报错并计数）从这里取
diagnose.engine = engine

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
    --- 用户第 3 项：外设被拔掉 / 被换掉之后，之前从这里读到的内容必须**立刻**清掉
    --- （否则网页上会一直留着那些已经读不到的物品），并马上把删除推给网页。
    forgetRemovedContainers("peripheral removed")
end

--- 一次主控调度执行（只在 timer 事件里跑；见下面的 mainLoop）。
--- 主角是调度器（队列轮转 + 时间片）：有 worker 且都忙时它只停"队列推进"，
--- 写盘 / 心跳 / 超时 / 重发 / 推送这些不属于调度器的部分照做。
local function masterTick(now)
    debugCounters.ticks = debugCounters.ticks + 1
    refreshPeripheralsIfNeeded(now)
    --- 延时任务（modules/scheduler.lua）：与任务队列无关的小定时器
    timed("scheduler", scheduler.tick, scheduler, now)
    --- 网页推送：状态有变化才真的推（revision 驱动）
    timed("protocol update", protocol.update, protocol, now)
    --- 任务调度器：写盘 → 维护 → 生成器 → 队列轮转（见 modules/dispatch.lua）
    timed("dispatch", dispatch.tick, dispatch, now)
    --- 发件箱出队（用户第 5 项）：轮转刚派出去的搬运/查询/详情在这里一次性发给 worker ——
    --- 同一台 worker 本 tick 的所有任务合并成 1 次 modem 调用（见 Transfer:flushOutbox），
    --- 避免每条任务一次 modem send 把 modem_message 事件堆到 256 条上限后开始丢事件。
    timed("transfer flush", transfer.flushOutbox, transfer)
    if now - lastStatusPrint > 30000 then
        lastStatusPrint = now
        timed("status line", statusLine)
    end
end

local function mainLoop()
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        debugCounters.events = debugCounters.events + 1
        if event == "timer" and param1 == tickToken then
            tickToken = nil
            debugCounters.timers = debugCounters.timers + 1
            masterTick(Util.now())
            -- 需求：一轮调度完成后才开始下一轮计时 —— timer 事件永远不会积压
            armTick()
        elseif event == "peripheral" or event == "peripheral_detach" then
            -- 不在这里立刻重扫：成片的外设事件会把事件循环占满（见 refreshPeripheralsIfNeeded）
            peripheralScanPending = true
        elseif event == "websocket_success" or event == "websocket_message" or event == "websocket_closed"
            or event == "websocket_failure" then
            debugCounters.websockets = debugCounters.websockets + 1
            -- 协议层（含收到请求后的推送）出错绝不能让主循环结束：
            -- 主循环一旦结束，服务端就退出，网页上所有请求都会变成“超时”。
            -- 网页请求在两次调度之间就会被处理完（调度器只认 timer 事件）。
            -- param3 是 CC:T 在 websocket_closed 里附带的关闭说明（诊断用）。
            timed("protocol event", protocol.onEvent, protocol, event, param1, param2, param3)
        elseif event == "modem_message" then
            -- IFMWorker 调度：worker 的 hello / pong / 任务结果都从这里进来
            timed("transfer message", transfer.onModemMessage, transfer, param1, param2, param3, param4, param5)
        end
        --- 推进主控本机的搬运协程池（1.8.0）：每个事件都把在跑的协程 resume 一次，
        --- 与 CC:T parallel 的调度方式一致。放在事件处理之后：本 tick 刚派出去的本机任务
        --- 立刻继续跑，而不是等下一个事件。
        timed("local pool", transfer.pumpLocal, transfer, event, param1, param2, param3, param4, param5)
        -- 丢 timer 的恢复（事件驱动、不引入第二个 timer）：已经排队的 timer 早该触发却一直没来
        -- → 重开一个（旧 token 的事件会被忽略，因为 tickToken 已经换了）
        local now = Util.now()
        if tickToken and now - armedAt > 2 * TICK * 1000 then
            tickToken = nil
            armTick()
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