-- IFMWorker.lua -- IFM 分布式工作节点：只做「物品/流体搬运」与「物品/流体查询」
--
-- 职责（1.5.0 起，只有此两项）：
--   move   搬运：主控把 pushItems / pushFluid 的参数发过来，本机执行并回报实际搬运数量；
--   query  查询：主控要“容器里有什么”“某物品在哪些容器里各有多少”时，本机扫描本机能看到的
--                外设并把结果回报主控（展示与决策都由主控做）。
--
-- 明确**不做**（一律留在主控本机，避免 worker 与主控状态不一致，也避免 worker 出问题影响生产）：
--   * 不跑流程（engine）：流程状态机、计时、下单/取消全部由主控负责；
--   * 不做存储整理（compact）：整理计划由主控计算、主控执行；
--   * 不连 WebSocket：网页中继永远由主控自己连接（worker 掉线不会让网页失联）。
--   本机需要与主控**同一份 ifm/ 目录**：modem 发现、外设枚举、频道/协议常量都从那里取，
--   不再自带一份（两份实现漂了最难查 —— worker 跑在别的计算机上）。build.py 的单文件产物
--   解压后会同时写出 IFMMaster.lua / IFMWorker.lua 与 ifm/*.lua，所以正常部署下它一定在。
--   （推荐有线网络：wired modem + 网络线 —— 有线网络里的计算机共享外设；无线 modem 只能通讯）。
--
-- 用法（拷到另一台 computer 上运行；Ctrl+T 停止）：
--   IFMWorker.lua                                   -- 默认频道 41000，搬运 + 查询都开
--   IFMWorker.lua --channel 41000 --name smelter-1   -- 指定频道与显示名
--   IFMWorker.lua --no-move                          -- 只做查询
--   IFMWorker.lua --no-query                         -- 只做搬运
--   IFMWorker.lua --help
--
-- 终端输出一律 ASCII 英文（CC:T 终端字形不含中日韩字符）。

local args = { ... }

--- 脚本目录与 ifm/ 模块目录：定位方式与 IFMMaster.lua 完全一致
local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMWorker.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "ifm")

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path ..
            " - keep IFMWorker.lua next to the ifm/ directory (the unpacker bundle writes both)", 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

--- 与主控共用的模块：
---   modems      modem 发现 / 包装 / 发消息（以前这里自带一份，与 ifm/transfer.lua 重复了 60 行）
---   peripherals 外设枚举（多类型外设也认得：getType 可能返回多个类型）
---   transfer    频道 / 协议名常量（worker 与主控必须一致，写死在两边迟早漂）
local Modems = loadModule("modems")
local Peripherals = loadModule("peripherals")
local Transfer = loadModule("transfer")

local DEFAULT_CHANNEL = Transfer.CHANNEL
local PROTOCOL = Transfer.PROTOCOL   -- 与主控一致（沿用旧协议名，老版本主控也能认出 hello）
local HELLO_INTERVAL = 5             -- 秒：没收到主控 hello 时主动广播，方便主控发现本机
local STATE_INTERVAL = 1             -- 秒：向主控上报状态（当前工作 / 计数）
local MASTER_TIMEOUT = 30            -- 秒：多久没收到主控消息就暂停干活（等主控回来）
local QUERY_LIMIT = 1024             -- 单次查询最多回报多少个槽位/储罐（避免一条消息过大）

local function printUsage()
    print("IFMWorker - IFM distributed worker (move + query only)")
    print("Usage: IFMWorker.lua [--channel <n>] [--name <label>] [--no-move] [--no-query] [--help]")
    print("  --channel  modem channel shared with the IFM master (default " .. tostring(DEFAULT_CHANNEL) .. ")")
    print("  --name     label shown in the web UI (default: computer id)")
    print("  --no-move  don't accept item/fluid move jobs")
    print("  --no-query don't accept item/fluid query jobs")
    print("This worker only moves and queries items/fluids. Processes, storage compaction and the")
    print("web relay always stay on the master. It does need the same ifm/ directory as the master")
    print("(modem discovery, peripheral scan and the channel/protocol constants) - the unpacker")
    print("bundle writes IFMMaster.lua / IFMWorker.lua and ifm/*.lua together, so keep them together.")
    print("Requires a modem (wired recommended: the worker then sees the same containers as the master).")
end

local channel = DEFAULT_CHANNEL
local workerName = nil
local caps = { move = true, query = true }
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
    elseif value == "--no-move" then
        caps.move = false
    elseif value == "--no-query" then
        caps.query = false
    else
        print("unknown argument ignored: " .. value)
    end
    index = index + 1
end

--- 找一个 modem（有线优先）并打开频道；实现见 ifm/modems.lua（与主控同一份）
local modem, modemSide = Modems.find()
if not modem then
    print("IFMWorker: no modem found.")
    print("Attach a (wired) modem and run this program again.")
    return
end

local okOpen, openErr = pcall(modem.open, channel)
if not okOpen then
    print("IFMWorker: cannot open channel " .. tostring(channel) .. " (" .. tostring(openErr) .. ")")
    return
end

local computerId = os.getComputerID()
if workerName == nil or workerName == "" then
    workerName = "worker-#" .. tostring(computerId)
end

local version = "1.6.16"

--- 本机日志（屏幕上看得到，方便直接复制给主控看）
local function workerLog(text)
    print("[IFMWorker] " .. tostring(text))
end

--- 向频道广播一条消息（proto/from 自动补上）；发送失败会在本机提示（同一个错误只提示一次）
local lastSendError = nil
local function reply(message)
    message.proto = PROTOCOL
    message.from = computerId
    local ok, err = Modems.transmit(modem, channel, message)
    if not ok then
        local text = tostring(err)
        if text ~= lastSendError then
            lastSendError = text
            workerLog("modem send failed (" .. tostring(message.op) .. "): " .. text)
        end
    end
end

-- ===================== move：物品 / 流体搬运 =====================
--- 执行一次搬运：返回 实际搬运数量, 失败原因
local function runMove(job)
    local limit = tonumber(job.limit) or 1
    if limit <= 0 then
        return 0, "limit must be > 0"
    end
    --- from / to 必须是外设名字符串：peripheral.wrap(nil) 会直接抛错。
    --- 抛错会中断主循环（更糟的是 busyJob 会一直留在“忙”状态，这台 worker 从此再也接不到活）。
    if type(job.from) ~= "string" or type(job.to) ~= "string" then
        return 0, "bad job (from/to must be peripheral names)"
    end
    if job.action == "push_item" then
        local inv = peripheral.wrap(job.from)
        if not inv then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        local ok, moved = pcall(inv.pushItems, job.to, job.fromSlot, limit, job.toSlot)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        -- 有些外设只能用对面来拉：换从目标侧 pullItems 再试一次
        local target = peripheral.wrap(job.to)
        if target then
            local ok2, moved2 = pcall(target.pullItems, job.from, job.fromSlot, limit, job.toSlot)
            if ok2 and type(moved2) == "number" and moved2 > 0 then
                return moved2
            end
        end
        if ok then
            return 0, "moved nothing"
        end
        return 0, tostring(moved)
    end
    if job.action == "push_fluid" then
        local storage = peripheral.wrap(job.from)
        if not storage then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        local ok, moved = pcall(storage.pushFluid, job.to, limit, job.fluid)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        local target = peripheral.wrap(job.to)
        if target then
            local ok2, moved2 = pcall(target.pullFluid, job.from, limit, job.fluid)
            if ok2 and type(moved2) == "number" and moved2 > 0 then
                return moved2
            end
        end
        if ok then
            return 0, "moved nothing"
        end
        return 0, tostring(moved)
    end
    return 0, "unknown action " .. tostring(job.action)
end

--- 搬运任务名（网页“当前工作”一列显示的就是这个字符串）
local function describeMove(job)
    if job.action == "push_item" then
        return string.format("move %s x%s %s#%s -> %s", tostring(job.item or job.fluid or "?"),
            tostring(job.limit), tostring(job.from), tostring(job.fromSlot), tostring(job.to))
    end
    if job.action == "push_fluid" then
        return string.format("fluid %s x%s %s -> %s", tostring(job.fluid), tostring(job.limit),
            tostring(job.from), tostring(job.to))
    end
    return tostring(job.action or "job")
end

-- ===================== query：单个容器的物品 / 流体查询 =====================
-- 主控要查询时发 { op = "query", id, container = 容器外设名,
--                    names = { 物品名/流体名 -> true }（可选，只要这些）,
--                    limit = 单次最多回报多少个槽位 }
-- **一次只查一个容器**：主控要“查询所有容器”时由它自己拆成多条查询、轮流派给各台 worker ——
-- 这样某个慢容器只会拖住它自己那一条，不会连带整整一批（也不会把 worker 的心跳卡住）。
-- 回报里的 scannedContainers 只会包含这个容器（没扫到就是空表 → 主控本机读）。
-- 本机扫描**本机能看到**的 inventory / fluid_storage，把每个槽位/储罐原样回报，并附上按名称合计的数量。

--- 外设枚举用与主控同一个模块（ifm/peripherals.lua）：多类型外设也认得
--- （CC:T 的 peripheral.getType 可能返回多个类型，自己比较第一个会漏掉）。
local peripherals = Peripherals.new({ log = function() end })

--- 一次查询只查**一个容器**（“查询所有容器”由主控拆成多条查询并行派活，见 ifm/transfer.lua）：
---   spec.container   容器外设名（主控新版本用这个字段）
---   spec.containers = { 容器外设名 }（兼容旧主控：只取第一个）
--- 注意：调用方（runQuery）必须先 peripherals:scan() 刷一次注册表。
local function pickContainer(spec)
    local name = spec.container
    if type(name) ~= "string" or name == "" then
        name = type(spec.containers) == "table" and spec.containers[1] or nil
    end
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return tostring(name)
end

--- 物品查询：只看指定容器。返回 槽位表, 按物品名合计, 是否真的扫到, 因 limit 未回报的槽位数
local function queryItems(spec, side)
    local wanted = type(spec.names) == "table" and spec.names or nil
    local limit = tonumber(spec.limit) or QUERY_LIMIT
    local items, totals, scanned, dropped = {}, {}, 0, 0
    if not peripherals:isInventory(side) then
        return items, totals, scanned, dropped
    end
    local inventory = peripheral.wrap(side)
    local listFn = inventory and inventory.list
    if type(listFn) ~= "function" then
        return items, totals, scanned, dropped
    end
    local ok, stacks = pcall(listFn)
    --- 包装失效 / 外设调用失败：算“没扫到”（主控据此对这个容器本机读）
    if not ok or type(stacks) ~= "table" then
        return items, totals, scanned, dropped
    end
    scanned = 1
    for slot, stack in pairs(stacks) do
        local name, count, nbt = nil, 0, nil
        if type(stack) == "table" then
            name = stack.name
            count = tonumber(stack.count) or 0
            nbt = stack.nbt
        elseif type(stack) == "string" then
            name = stack
            count = 1
        end
        if type(name) == "string" and (wanted == nil or wanted[name] == true) then
            totals[name] = (totals[name] or 0) + count
            if #items < limit then
                items[#items + 1] = {
                    container = side,
                    slot = tonumber(slot) or slot,
                    name = name,
                    count = count,
                    nbt = nbt,
                }
            else
                dropped = dropped + 1
            end
        end
    end
    return items, totals, scanned, dropped
end

--- 流体查询：只看指定容器。返回 储罐表, 按流体名合计, 是否真的扫到, 因 limit 未回报的储罐数
local function queryFluids(spec, side)
    local wanted = type(spec.names) == "table" and spec.names or nil
    local limit = tonumber(spec.limit) or QUERY_LIMIT
    local tanks, totals, scanned, dropped = {}, {}, 0, 0
    if not peripherals:isFluid(side) then
        return tanks, totals, scanned, dropped
    end
    local storage = peripheral.wrap(side)
    if not storage then
        return tanks, totals, scanned, dropped
    end
    local rows = {}
    if type(storage.tanks) == "function" then
        local ok, result = pcall(storage.tanks)
        if not ok or type(result) ~= "table" then
            return tanks, totals, scanned, dropped
        end
        rows = result
    elseif type(storage.getTank) == "function" then
        -- 有的外设只有 getTank(i)：从 1 开始读，读到空/报错为止（最多 64 个槽）
        local slot = 1
        while slot <= 64 do
            local ok, tank = pcall(storage.getTank, slot)
            if not ok or type(tank) ~= "table" then
                break
            end
            rows[slot] = tank
            slot = slot + 1
        end
    else
        return tanks, totals, scanned, dropped
    end
    scanned = 1
    for slot, tank in pairs(rows) do
        local name = type(tank) == "table" and tank.name or nil
        local amount = type(tank) == "table" and (tonumber(tank.amount) or 0) or 0
        if type(name) == "string" and (wanted == nil or wanted[name] == true) then
            totals[name] = (totals[name] or 0) + amount
            if #tanks < limit then
                tanks[#tanks + 1] = {
                    container = side,
                    slot = tonumber(slot) or slot,
                    name = name,
                    amount = amount,
                }
            else
                dropped = dropped + 1
            end
        end
    end
    return tanks, totals, scanned, dropped
end

--- 执行一次查询：**一个容器**（物品 + 流体都看，因为这个容器可能同时提供两种外设）
local function runQuery(spec)
    local startedAt = os.epoch("utc")
    local container = pickContainer(spec)
    local result = {
        op = "query_result",
        id = spec.id,
        mode = "all",
        at = startedAt,
        ok = true,
        container = container,
    }
    if not container then
        result.ok = false
        result.error = "no container given (one container per query)"
        result.scannedContainers = {}
        result.elapsed = os.epoch("utc") - startedAt
        return result
    end
    --- 每次查询重扫一次外设注册表（外设可能热插拔）
    peripherals:scan()
    local items, itemTotals, itemScanned, itemDropped = queryItems(spec, container)
    local tanks, fluidTotals, fluidScanned, fluidDropped = queryFluids(spec, container)
    result.items = items
    result.itemTotals = itemTotals
    result.itemScanned = itemScanned
    result.itemDropped = itemDropped
    result.tanks = tanks
    result.fluidTotals = fluidTotals
    result.fluidScanned = fluidScanned
    result.fluidDropped = fluidDropped
    --- 真的扫到了这个容器吗？主控的“容器扫描卸载”靠它判断空容器可信不可信：
    --- 扫过且为空 = 真空（可以当真）；没扫到 = 主控本机读
    result.scannedContainers = (itemScanned + fluidScanned) > 0 and { container } or {}
    result.elapsed = os.epoch("utc") - startedAt
    return result
end

-- ===================== detail：物品详情（getItemDetail）=====================
-- 主控要问「某个物品的 maxCount / tags」时发：
--   { op = "detail", id, samples = { { container = 外设名, slot = 槽位, name = 物品名, nbt = ... }, ... } }
-- getItemDetail 与 list() 一样是**阻塞**的外设调用（有线网络上 ≈1 个服务器刻/次），
-- 而主控要为几百种物品各问一次（整理计划要 maxCount、标签扫描要 tags）—— 主控自己做
-- 就是几百个服务器刻的卡顿。打包交给 worker 后，主控只等 modem 消息。
-- 只在「这个槽位现在还是那种物品」时才回报详情：排队期间它可能已经被搬走 / 换成别的东西。
-- 回报只带主控真正要的几个字段（回报越小，无线链路上越不容易丢）。
local function runDetail(spec)
    local startedAt = os.epoch("utc")
    local result = {
        op = "detail_result",
        id = spec.id,
        ok = true,
        details = {},
    }
    local samples = type(spec.samples) == "table" and spec.samples or {}
    --- 每次任务重扫一次外设注册表（外设可能热插拔；与 runQuery 一致）
    peripherals:scan()
    for _, sample in ipairs(samples) do
        local side = type(sample) == "table" and sample.container or nil
        local slot = type(sample) == "table" and tonumber(sample.slot) or nil
        local name = type(sample) == "table" and sample.name or nil
        if type(side) == "string" and side ~= "" and slot and type(name) == "string" and name ~= "" then
            local inventory = peripheral.wrap(side)
            local detail = nil
            if inventory and type(inventory.getItemDetail) == "function" then
                local ok, value = pcall(inventory.getItemDetail, slot)
                if ok and type(value) == "table" then
                    detail = value
                end
            end
            if detail and (detail.name == nil or detail.name == name) then
                result.details[#result.details + 1] = {
                    container = side,
                    slot = slot,
                    name = name,
                    nbt = sample.nbt,
                    detail = {
                        name = detail.name or name,
                        displayName = detail.displayName,
                        maxCount = tonumber(detail.maxCount),
                        tags = detail.tags,
                    },
                }
            end
        end
    end
    result.items = #result.details
    result.elapsed = os.epoch("utc") - startedAt
    return result
end

-- ===================== 与主控的会话状态 =====================
local masterId = nil
local lastMasterAt = 0
local masterOnline = false
local helloAt = 0
local masterVersion = nil      -- 主控版本（welcome 消息里带）
local versionWarning = nil     -- 版本不一致时的警告文本（会在屏幕上常显）
local lastVersionWarning = nil

local jobsDone = 0
local movedTotal = 0
local queriesDone = 0
local detailsDone = 0          -- 代查物品详情（getItemDetail）的批次数
local detailItems = 0          -- 代查到的物品详情数量（主控拿去填物品字典）
local busyJob = nil            -- { id, kind = "move" | "query", text }
local lastStateAt = 0
local lastQuery = nil          -- 最近一次查询的摘要（连同状态一起上报给主控）

--- 当前正在做的事（网页“当前工作”一列显示的就是这些字符串）
local function taskList()
    local out = {}
    if busyJob then
        out[#out + 1] = busyJob.text
    end
    return out
end

--- 每秒上报一次：主控用它更新 worker 注册表、网页用它显示“这台 worker 在干什么”
local function reportState()
    reply({
        op = "state",
        name = workerName,
        version = version,
        caps = caps,
        busy = busyJob ~= nil,
        busyKind = busyJob and busyJob.kind or nil,
        masterVersion = masterVersion,
        versionMismatch = versionWarning ~= nil,
        jobs = jobsDone,
        moved = movedTotal,
        queries = queriesDone,
        details = detailsDone,
        detailItems = detailItems,
        tasks = taskList(),
        lastQuery = lastQuery,
    })
    lastStateAt = os.epoch("utc")
end

--- 这条握手消息是不是**另一台 worker** 发来的（而不是主控）？
--- worker 的 hello / pong 一定带 caps（能力表）与 name；主控的 hello 两者都没有。
local function isWorkerHandshake(message)
    return type(message.caps) == "table" or type(message.name) == "string"
end

--- 这条消息是不是主控发来的？只有三种情况算：
---   1) 明确发给本机（target == 本机号）：job / query / welcome；
---   2) 带 master = true（1.5.3 起主控的 hello / pong / welcome 都带）；
---   3) 老版本主控的 hello / pong 握手（没有 caps / name 这两个 worker 字段）。
--- 其余一律不是 —— **别的 worker 每秒上报的 state / query_result 都没有 target**，
--- 以前它们同样会走到“记下发信人为主控”那一行，屏幕上的 master 行就在真主控与别的 worker
--- 之间来回跳，这就是那个 bug 的真正原因。
local function isMasterMessage(message, op)
    if message.target == computerId then
        return true
    end
    if message.master == true then
        return true
    end
    if op == "hello" or op == "pong" then
        return not isWorkerHandshake(message)
    end
    return false
end

-- ===================== 重发与排队（1.6.2） =====================
-- 主控与 worker 之间是无线 modem：消息偶尔会丢（距离/干扰）。主控对一条查询/搬运会**重发同一个 id**，
-- 所以这里要做两件事：
--   1) **幂等**：同一个 id 已经做过 → 把上次的结果再回一遍（绝不重复搬运、也不重复扫描）；
--   2) **排队**：手上正忙时不回 busy（主控那边会白等到超时），先把消息存起来，忙完立刻做。
local TASK_CACHE_MAX = 16
local DEFER_MAX = 8
local DEFER_MAX_AGE = 8000      -- 排队超过这么久就丢掉（主控那边早已超时作废，做了也白做）
local EXECUTED_MAX = 64         -- 记住“搬运任务已经执行过”的 id（结果被淘汰后也不会重复搬）
local recentTasks = {}          -- id -> 已回过的那条结果消息
local taskOrder = {}            -- 只用来限制缓存条数（先进先出淘汰）
local deferred = {}             -- 忙的时候收到的 job / query
local executedJobs = {}         -- 已经执行过的 job id
local executedOrder = {}

--- 记下“这条搬运已经真的执行过”：结果缓存被淘汰后仍能认出它，绝不重复搬（可能又搬一份出去）
local function markExecuted(id)
    id = tonumber(id)
    if id == nil or executedJobs[id] then
        return
    end
    executedJobs[id] = true
    executedOrder[#executedOrder + 1] = id
    while #executedOrder > EXECUTED_MAX do
        executedJobs[table.remove(executedOrder, 1)] = nil
    end
end

local function rememberTask(id, message)
    id = tonumber(id)
    if id == nil then
        return
    end
    if not recentTasks[id] then
        taskOrder[#taskOrder + 1] = id
    end
    recentTasks[id] = message
    while #taskOrder > TASK_CACHE_MAX do
        recentTasks[table.remove(taskOrder, 1)] = nil
    end
end

--- 同一个 id 已经做过 → 复制一份上次的结果重发（复制是为了不改动已缓存的那份、也不重复计数）
local function resendTask(message)
    local cached = recentTasks[tonumber(message.id)]
    if not cached then
        return false
    end
    local copy = {}
    for key, value in pairs(cached) do
        copy[key] = value
    end
    copy.resent = true
    reply(copy)
    return true
end

--- 忙的时候先把任务排队（返回 true 表示已经排进队列，调用方直接 return）
local function deferTask(message)
    if not busyJob then
        return false
    end
    if #deferred >= DEFER_MAX then
        reply({ op = "busy", id = message.id,
            query = message.op == "query" or message.op == "detail" })
        return true
    end
    message.__deferredAt = os.epoch("utc")
    deferred[#deferred + 1] = message
    return true
end

local function handleMessage(message)
    if type(message) ~= "table" or message.proto ~= PROTOCOL or message.from == computerId then
        return
    end
    local op = message.op
    if message.target ~= nil and message.target ~= computerId then
        return
    end
    if not isMasterMessage(message, op) then
        return                          -- 别的 worker 的广播（state / query_result / done …）：与本机无关
    end
    -- 能走到这里说明这条消息是主控发来的
    -- job / query 里的 from / to 是**容器外设名**，不是发信人：发信人看 sender（1.5.4 起主控会带上）
    local senderId = message.from
    if op == "job" or op == "query" then
        senderId = tonumber(message.sender)
    end
    if senderId then
        masterId = senderId
    end
    --- 主控版本：welcome / job / query / detail 都会带，记下来用于“版本不一致就拒绝执行”
    if type(message.version) == "string" and message.version ~= "" then
        masterVersion = message.version
    end
    lastMasterAt = os.epoch("utc")
    masterOnline = true
    if op == "hello" then
        -- 主控在找 worker：回 pong（主控才会把本机记进 worker 列表、之后派活过来）
        reply({ op = "pong", name = workerName, caps = caps, version = version })
        return
    end
    if op == "pong" then
        return
    end
    if op == "welcome" then
        -- 主控报到（房间号 / 版本）。worker 不需要房间号，但**必须**核对版本：
        -- 不一致时在屏幕上常显警告（只打一行日志很容易被忽略，之前的排查就吃过这个亏）。
        if type(message.version) == "string" then
            masterVersion = message.version
            if message.version ~= version then
                versionWarning = "version mismatch: master " .. message.version .. " vs worker " .. version
                if lastVersionWarning ~= versionWarning then
                    lastVersionWarning = versionWarning
                    workerLog(versionWarning .. " - put the same build on master and worker")
                end
            else
                versionWarning = nil
            end
        end
        return
    end
    --- ===== 版本闸门 =====
    --- 主控与 worker 的版本必须完全一致，否则**拒绝执行任何作业**。
    --- 只在主控版本已知时判断（hello/pong/welcome 不受影响，否则两边连互相认识都做不到）。
    if masterVersion and masterVersion ~= version then
        local why = "version mismatch: master " .. tostring(masterVersion) .. " vs worker " .. tostring(version)
        if op == "job" then
            reply({ op = "error", id = message.id, moved = 0, error = why })
        elseif op == "query" then
            reply({ op = "query_result", id = message.id, ok = false, error = why })
        elseif op == "detail" then
            reply({ op = "detail_result", id = message.id, ok = false, error = why })
        end
        if lastVersionWarning ~= why then
            lastVersionWarning = why
            workerLog(why .. " - job refused; install the same build on master and worker")
        end
        return
    end
    if op == "job" then
        if not caps.move then
            reply({ op = "error", id = message.id, moved = 0, error = "worker disabled moves (--no-move)" })
            return
        end
        --- 主控重发的同一条任务：直接把上次结果再回一遍（不重复搬东西）
        if resendTask(message) then
            return
        end
        --- 做过、但结果已经从缓存里淘汰了：绝不能再搬一次（可能又搬一份出去）
        if executedJobs[tonumber(message.id)] then
            reply({ op = "done", id = message.id, moved = 0,
                error = "already executed earlier (result expired)" })
            return
        end
        --- 正忙：排队（忙完立刻做），排队满了才回 busy
        if deferTask(message) then
            return
        end
        busyJob = { id = message.id, kind = "move", text = describeMove(message) }
        --- pcall：任何意外（外设被拆掉、名字不合法…）都不该中断主循环、更不该把 busyJob 留在“忙”
        --- （留在忙状态的 worker 会拒绝之后所有任务，网页上只剩一个永远「工作中」）
        local okMove, moved, err = pcall(runMove, message)
        busyJob = nil
        if not okMove then
            err = "move crashed: " .. tostring(moved)
            moved = 0
            workerLog("move error: " .. tostring(err))
        end
        moved = tonumber(moved) or 0
        jobsDone = jobsDone + 1
        movedTotal = movedTotal + moved
        local out = { op = moved > 0 and "done" or "error", id = message.id, moved = moved, error = err }
        markExecuted(message.id)
        rememberTask(message.id, out)
        reply(out)
        return
    end
    if op == "detail" then
        --- 物品详情代查（getItemDetail）：与 query 同一套幂等 / 排队 / 回报规则
        if not caps.query then
            reply({ op = "detail_result", id = message.id, ok = false, error = "worker disabled queries (--no-query)" })
            return
        end
        if resendTask(message) then
            return
        end
        if deferTask(message) then
            return
        end
        local samples = type(message.samples) == "table" and message.samples or {}
        reply({ op = "detail_ack", id = message.id, samples = #samples })
        busyJob = { id = message.id, kind = "detail",
            text = "detail " .. tostring(#samples) .. " item type(s)" }
        local okRun, result = pcall(runDetail, message)
        busyJob = nil
        if not okRun then
            local why = "detail crashed: " .. tostring(result)
            workerLog(why)
            local failed = { op = "detail_result", id = message.id, ok = false, error = why }
            rememberTask(message.id, failed)
            reply(failed)
            return
        end
        detailsDone = detailsDone + 1
        detailItems = detailItems + (tonumber(result.items) or 0)
        workerLog("detail: " .. tostring(result.items) .. " of " .. tostring(#samples) ..
            " item type(s) in " .. tostring(result.elapsed) .. "ms")
        rememberTask(message.id, result)
        reply(result)
        return
    end
    if op == "query" then
        if not caps.query then
            reply({ op = "query_result", id = message.id, ok = false, error = "worker disabled queries (--no-query)" })
            return
        end
        --- 主控重发的同一条查询：直接把上次结果再回一遍（不重复扫描）
        if resendTask(message) then
            return
        end
        --- 正忙：排队（忙完立刻做），排队满了才回 busy
        if deferTask(message) then
            return
        end
        --- 立刻回一条“收到了”：主控据此区分「消息没到 worker」与「结果丢了」——
        --- 只有一条 15 秒超时日志时，根本判断不出是哪一边的问题（1.5.7 起）。
        local container = pickContainer(message)
        reply({ op = "query_ack", id = message.id, container = container })
        busyJob = { id = message.id, kind = "query", text = "query " .. tostring(container or "?") }
        local okQuery, result = pcall(runQuery, message)
        busyJob = nil
        if not okQuery then
            local why = "query crashed: " .. tostring(result)
            workerLog(why)
            local failed = { op = "query_result", id = message.id, ok = false, error = why }
            rememberTask(message.id, failed)
            reply(failed)
            return
        end
        queriesDone = queriesDone + 1
        local stacks = #(result.items or {}) + #(result.tanks or {})
        if result.ok then
            lastQuery = {
                mode = result.mode,
                container = result.container,
                at = result.at,
                elapsed = result.elapsed,
                stacks = stacks,
                scanned = (result.itemScanned or 0) + (result.fluidScanned or 0),
            }
            workerLog("query " .. tostring(result.container) .. ": " .. tostring(stacks) .. " stack(s) in " ..
                tostring(result.elapsed) .. "ms")
        else
            workerLog("query failed: " .. tostring(result.error))
        end
        rememberTask(message.id, result)
        reply(result)
        return
    end
end

--- 忙完手上这条之后，把排队中的任务接着做掉（一次只做一条，别饿死心跳与屏幕刷新）
local function drainDeferred()
    if busyJob or #deferred == 0 then
        return
    end
    local message = table.remove(deferred, 1)
    if os.epoch("utc") - (message.__deferredAt or 0) > DEFER_MAX_AGE then
        workerLog("dropped a queued " .. tostring(message.op) .. " (too old: the master already timed out)")
        return
    end
    handleMessage(message)
end

-- ===================== 屏幕 / 主循环 =====================
local lastDrawAt = 0
local lastText = {}

--- 启动艺术字（纯 ASCII：CC:T 终端字形没有中日韩字符，艺术字只能用 ASCII 画）
--- 与 IFMMaster.lua 用同一份，永远显示在 worker 屏幕最上面
local IFM_ART = {
    "     _/_/_/  _/_/_/_/  _/      _/   ",
    "      _/    _/        _/_/  _/_/    ",
    "     _/    _/_/_/    _/  _/  _/     ",
    "    _/    _/        _/      _/      ",
    " _/_/_/  _/        _/      _/        ",
}

local function redraw(force)
    local lines = {}
    for _, art in ipairs(IFM_ART) do
        lines[#lines + 1] = art
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "IFMWorker (move + query + item detail)"
    lines[#lines + 1] = "computer : #" .. tostring(computerId) .. "  name: " .. tostring(workerName)
    lines[#lines + 1] = "modem    : " .. tostring(modemSide or "?") .. "  channel: " .. tostring(channel)
    lines[#lines + 1] = "master   : " .. (masterOnline and ("#" .. tostring(masterId or "?")) or "waiting...")
    lines[#lines + 1] = "caps     : " .. (caps.move and "move " or "") .. (caps.query and "query" or "")
    lines[#lines + 1] = "jobs     : " .. tostring(jobsDone) .. " move(s), " .. tostring(movedTotal) .. " item(s), " ..
        tostring(queriesDone) .. " query(ies), " .. tostring(detailsDone) .. " detail batch(es)"
    lines[#lines + 1] = "details  : " .. tostring(detailItems) .. " item detail(s) sent to the master"
    lines[#lines + 1] = "scope    : processes / compact / relay stay on the master"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "current work:"
    local tasks = taskList()
    if #tasks == 0 then
        lines[#lines + 1] = "  (idle)"
    else
        for _, text in ipairs(tasks) do
            lines[#lines + 1] = "  - " .. text
        end
    end
    if lastQuery then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "last query: " .. tostring(lastQuery.mode) .. ", " .. tostring(lastQuery.stacks) ..
            " stack(s) in " .. tostring(lastQuery.elapsed) .. "ms"
    end
    if versionWarning then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: " .. tostring(versionWarning)
        lines[#lines + 1] = "put the same build (IFMMaster.lua / IFMWorker.lua) on both computers"
    end
    -- 只在内容变化时重画（避免每秒刷屏造成闪烁）
    if not force and table.concat(lines, "\n") == lastText.value then
        return
    end
    lastText.value = table.concat(lines, "\n")
    term.clear()
    term.setCursorPos(1, 1)
    for _, text in ipairs(lines) do
        print(text)
    end
end

--- 周期任务（0.2s 一次）：给主控报到、上报状态、刷新屏幕
local function tick(now)
    if now - helloAt >= HELLO_INTERVAL * 1000 then
        helloAt = now
        reply({ op = "hello", name = workerName, caps = caps, channel = channel, version = version })
    end
    if masterOnline and now - lastMasterAt > MASTER_TIMEOUT * 1000 then
        masterOnline = false
        workerLog("master silent for " .. tostring(MASTER_TIMEOUT) .. "s - waiting for it")
    end
    if now - lastStateAt >= STATE_INTERVAL * 1000 then
        reportState()
    end
    if now - lastDrawAt >= 1000 then
        lastDrawAt = now
        redraw(false)
    end
end

redraw(true)
workerLog("IFMWorker started: name=" .. tostring(workerName) .. " channel=" .. tostring(channel) ..
    " caps=" .. (caps.move and "move," or "") .. (caps.query and "query" or ""))
reply({ op = "hello", name = workerName, caps = caps, channel = channel, version = version })

--- 主循环：任何意外错误都不该让 worker“无声死掉”（主控会把它当成失联），所以出错后打印原因并
--- 自动重启主循环；只有 Ctrl+T（Terminated）才真正退出。
local function mainLoop()
    local timerToken = os.startTimer(0.2)
    while true do
        local event, param1, param2, param3, param4 = os.pullEvent()
        local now = os.epoch("utc")
        if event == "modem_message" then
            -- modem_message: side, channel, replyChannel, message, distance
            handleMessage(param4)
            drainDeferred()
        elseif event == "timer" and param1 == timerToken then
            timerToken = os.startTimer(0.2)
            tick(now)
            drainDeferred()
        end
    end
end

while true do
    --- 主循环每一轮开始时清掉“当前工作”标记：上一轮如果是被异常打断的（上面的 pcall 捕获），
    --- busyJob 会一直留着 —— 那台 worker 之后会拒绝所有任务（网页上只剩一个永远「工作中」）。
    busyJob = nil
    deferred = {}
    local okLoop, loopErr = pcall(mainLoop)
    if okLoop then
        break
    end
    workerLog("main loop error: " .. tostring(loopErr))
    if tostring(loopErr) == "Terminated" then
        workerLog("stopped by user")
        break
    end
    workerLog("restarting the main loop in 3 seconds")
    os.sleep(3)
end