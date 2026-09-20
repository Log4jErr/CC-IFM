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
local IFM_VERSION = "1.7.0"

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
--- 任务调度器（1.7.0）：每个来源一个队列，队列间轮转，每个队列有自己的时间片
local Dispatch = loadModule("dispatch")

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
--- 搬运卸载调度器（IFMWorker 调度，实现见 modules/transfer.lua）：在下面 Protocol 建好之后创建并接到 containers 上
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
        for _, stack in ipairs(containers:stacks(def.name)) do
            if type(stack.name) == "string" and stack.name ~= "" then
                present[stack.name] = true
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
    --- 存储整理进度（1.5.0：整理永远由主控自己执行，worker 不再参与）
    local compact = engine:compactStatus()
    if compact then
        current.compact = compact
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
                return true                     -- 已交给 worker：回队尾等它回报（不重复发）
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
                return true                     -- 还差一些：回队尾继续（下一轮重新看源容器）
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
        -- 计划本身也分批算（每个 tick 最多问几次外设），所以这里立刻返回：
        -- 网页显示“正在计算搬运计划…”，算完后引擎再按每 tick 少量搬运执行（进度在网页上看得到）。
        local state = engine:startCompact(payload.role)
        log("Storage compact requested (%s): the plan is computed in small slices so the master stays responsive",
            tostring(state))
        return { success = true, planning = true, state = state }
    elseif action == "set_schedule_settings" then
        --- 调度时间片（1.7.0）：每条队列每次轮到时最多执行几步（正整数，1 ~ 50）。
        --- 校验走 Store:set；保存后立刻应用并回传生效值（网页直接显示回传值）。
        local slices = type(payload.slices) == "table" and payload.slices or nil
        if not slices then
            return { error = "slices must be a table of { queue = positive integer }" }
        end
        local data = { slices = slices }
        local ok, err = store:set("settings", Store.SCHEDULE_NAME, data, { force = true })
        if not ok then
            log("Save schedule settings failed: %s", tostring(err))
            return { error = err }
        end
        local applied = store:scheduleSettings()
        if dispatch then
            dispatch:applySlices(applied.slices)
        end
        store:flush()
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
transfer = Transfer.new({ log = log, Peripherals = peripherals, Modems = Modems })
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

--- ===== 任务调度器（1.7.0）=====
--- 每个来源一个队列，队列之间轮转（round-robin），每个队列各有时间片（网页「设置」可改）。
--- 队列的推进规则：
---   * 有 worker 且都忙 → 本次调度不推进队列（写盘 / 心跳 / 超时 / 推送照做）；
---   * 没有 worker → 主控本机执行，且每次调度只推进一步；
---   * 任务失败/未完成：流程队列回队尾（retry），其它队列直接丢弃（drop，由生成器下次重建）。
--- 目前（P1）只有流程队列接了执行体；容器扫描 / 入库 / 出库 / 整理 / 物品详情 / 交互容器
--- 这几条队列在 P2 接入（现在先把队列与生成器骨架搭好，行为与以前一致）。
dispatch = Dispatch.new({ log = log, store = store, cache = cache, transfer = transfer })
--- 搬运任务的执行者：containers 把任务入队，队列轮到它时调用 executeMove（见 modules/containers.lua）
containers:setDispatcher(dispatch)
local scheduleSettings = store:scheduleSettings()
dispatch:applySlices(scheduleSettings.slices)

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
-- 容器扫描队列（storageScan / inputScan）：一步 = 扫一个容器。
--   * 有 worker：交给 worker 代读（Transfer:submitScan），结果由 transfer.onQueryResult 写进快照；
--   * 没有 worker：本机 scanNow（阻塞约 1 刻/容器；无 worker 时每次调度只推进一步，不会挤爆）；
--   * 扫描失败 / 外设没了：丢弃（"drop"），下次由生成器重新排。
local function scanTaskRunner(task, now)
    local name = task.name
    if not peripherals:exists(name) then
        return "drop"
    end
    if transfer:workerCount() == 0 then
        containers:scanNow(name)
        return false
    end
    local state, value = transfer:submitScan(name)
    if state == "done" and type(value) == "table" then
        -- 新鲜结果已经在缓存里：写一次快照（用结果自己的时间戳，避免把"已结算的乐观变更"误丢）
        containers:applyScan(name, value.items, value.tanks, tonumber(value.at) or now)
        return false
    end
    if state == "pending" then
        return "inflight"                       -- worker 在扫：结果由 onQueryResult 收
    end
    return true                                 -- 没有空闲的查询 worker：回队尾，下次再试
end
dispatch:addQueue("storageScan", { needs = "query", policy = "retry", run = scanTaskRunner })
dispatch:addQueue("inputScan", { needs = "query", policy = "retry", run = scanTaskRunner })
-- 搬运队列（inventoryIn / inventoryOut / compact）：一步 = 执行一条搬运任务。
--   * 有 worker：交给 worker（Containers:runItemMove 里的 Transfer 请求，对任务键幂等）；
--   * 没有 worker：主控本机执行（pushItems / pullItems）；
--   * 搬不动 / 失败：丢弃（入库、出库、整理的搬运失败即丢弃，由生成器下次重建）；
--   * 已经交给 worker 还在飞：返回 "inflight"（等回报，回报后由 executeMove 再走一次结算）。
local function moveTaskRunner(task)
    return containers:executeMove(task)
end
dispatch:addQueue("inventoryIn", { needs = "move", policy = "retry", run = moveTaskRunner })
dispatch:addQueue("inventoryOut", { needs = "move", policy = "retry", run = moveTaskRunner })
dispatch:addQueue("compact", { needs = "move", policy = "retry", run = moveTaskRunner })
-- 物品详情队列：一步 = 一次 getItemDetail（一次调用约 1 个游戏刻）。
--   * 有 worker：交给它代查（结果由 transfer.onDetailResult 结束任务，字典由 absorb 流程写入）；
--   * 没有 worker：主控本机读一次（阻塞约 1 刻）；
--   * 拿不到 / 失败：丢弃（物品可能已经不在了；下一次扫描会重新生成）；
--   * 字典里已经有答案（含"问过拿不到"的负缓存）：丢弃。
dispatch:addQueue("detail", {
    needs = "query", policy = "retry",
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
            return true                         -- 没有空闲的查询 worker：回队尾
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
dispatch:addQueue("manual", {
    needs = "move", policy = "retry",
    run = function(task, now)
        return runManualTask(task, now)
    end,
})

-- 维护：心跳 / worker 超时 / 任务重发（不属于"调度器推进"，worker 全忙也照做）
dispatch:setMaintain(function(now)
    transfer:tick(now)
end)

--- worker 代扫回来了：写进容器快照，并结束对应的扫描队列任务（在飞 → 出队）
transfer.onQueryResult = function(_, key, message)
    local name = tostring(key or ""):match("^scan:(.+)$")
    if not name then
        return
    end
    containers:applyScan(name, message.items, message.tanks, tonumber(message.at) or os.epoch("utc"))
    dispatch:finishInflight("storageScan", name)
    dispatch:finishInflight("inputScan", name)
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
    --- 容器扫描：按轮次判断新鲜度（不是毫秒间隔）——没扫过、或超过 maxAgeTicks 轮没扫过就排进队列
    containers:advanceTick()
    local maxAgeTicks = 20                      -- 20 轮 ≈ 1 秒（50ms/轮）
    for _, def in ipairs(store:list("containers")) do
        local peripheralName = def.peripheral
        if type(peripheralName) == "string" and peripheralName ~= "" and
            peripherals:exists(peripheralName) and containers:needsScan(peripheralName, maxAgeTicks) then
            local queueName = (def.role == "input") and "inputScan" or "storageScan"
            dispatch:enqueue(queueName, { key = peripheralName, name = peripheralName })
        end
    end
    engine:enqueueActiveProcesses(dispatch)
    engine:processDeliveries(now)
    engine:stepCompact(now)
    engine:finishTick()
    --- 物品详情（detail 队列）：吸收 worker 代查回来的结果 → 排"扫描时看到但还没详情"的物品 →
    --- 低频清理标签缓存（按轮次，不是毫秒间隔）
    absorbWorkerDetails()
    queueMissingDetails()
    pruneTagCache()
end)

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