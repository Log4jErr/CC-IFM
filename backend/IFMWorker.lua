-- IFMWorker.lua -- IFM 分布式工作节点：只做「物品/流体搬运」与「物品/流体查询」
--
-- 职责（1.5.0 起，只有此两项）：
--   move   搬运：主控把 pushItems / pushFluid 的参数发过来，本机执行并回报实际搬运数量；
--   query  查询：主控要“容器里有什么”“某物品在哪些容器里各有多少”时，本机扫描本机能看到的
--                外设并把结果回报主控（展示与决策都由主控做）。
--
-- 并行（1.8.0）：本机一次最多同时跑 MAX_TASKS(64) 条任务 —— 每条任务在自己的协程里执行，
-- 所以多条 list / getItemDetail / pushItems 会在同一个游戏刻里并行等结果（这就是 parallel 的
-- 原理，但调度器是自己写的：只有任务表**满了**才回 busy，主控据此把活派给别的 worker 或自己
-- 本机并行做）。为什么不用 CC:T 自带的 parallel：它的调度靠 os.pullEventRaw 收事件，任务极多
-- 时累计事件数会逼近 Cobalt 的 256 上限；这里的调度器只有一个事件循环，与任务数无关。
--
-- 明确不做（一律留在主控本机，避免 worker 与主控状态不一致，也避免 worker 出问题影响生产）：
--   * 不跑流程（engine）：流程状态机、计时、下单/取消全部由主控负责；
--   * 不做存储整理（compact）：整理计划由主控计算、主控执行；
--   * 不连 WebSocket：网页中继永远由主控自己连接（worker 掉线不会让网页失联）。
--   本机需要与主控同一份 ifm/ 目录：modem 发现、外设枚举、频道/协议常量都从那里取，
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

--- 脚本目录与 modules/ 模块目录：定位方式与 IFMMaster.lua 完全一致
local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMWorker.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path ..
            " - keep IFMWorker.lua next to the modules/ directory (the unpacker bundle writes both)", 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

--- 与主控共用的模块：
---   modems      modem 发现 / 包装 / 发消息（以前这里自带一份，与 modules/transfer.lua 重复了 60 行）
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
--- ===== 并行任务表（用户第 3 项）=====
--- CC:T 里 list / getItemDetail / pushItems 都要等 1 个服务器刻，而且会阻塞调用它的那个线程；
--- 但把多条任务放进协程里同时发出去，它们就在同一个游戏刻里并行等结果（这才是 worker 的意义）。
--- 上限 MAX_TASKS：只有任务表**满了**才算“忙”，主控会据此把活派给别的 worker 或自己本机做。
--- 为什么不用 CC:T 的 parallel：parallel 的调度靠 os.pullEventRaw 收事件，同时跑的任务极多时
--- 累计事件数会逼近 Cobalt 的 256 上限；下面这个调度器只有一个事件循环，与任务数无关。
local MAX_TASKS = 64
local STATE_TASK_LIST = 8            -- 每秒上报时最多带几条“当前工作”（64 条全带上消息太大）
local SCREEN_TASK_LINES = 12         -- 屏幕上最多列几条“当前工作”（再多屏幕就滚没了）
--- 一条任务超过这么久还没跑完就把它从任务表里摘掉（让位子给别的任务）。
--- 为什么要有它：外设要是长时间不响应（方块所在区块没加载、网络断了），协程就会一直挂在
--- 等待里；Lua 没法从外面杀掉协程，但它占的槽位必须还回来 —— 否则任务表会被慢慢占满、
--- 整台 worker 最后被主控判成“忙”（用户现场：worker 用了一会儿就整台没动静）。
local TASK_TIMEOUT = 60

local function printUsage()
    print("IFMWorker - IFM distributed worker (move + query only)")
    print("Usage: IFMWorker.lua [--channel <n>] [--name <label>] [--no-move] [--no-query] [--help]")
    print("  --channel  modem channel shared with the IFM master (default " .. tostring(DEFAULT_CHANNEL) .. ")")
    print("  --name     label shown in the web UI (default: computer id)")
    print("  --no-move  don't accept item/fluid move jobs")
    print("  --no-query don't accept item/fluid query jobs")
    print("This worker only moves and queries items/fluids. Processes, storage compaction and the")
    print("web relay always stay on the master. It does need the same modules/ directory as the master")
    print("(modem discovery, peripheral scan and the channel/protocol constants) - the unpacker")
    print("bundle writes IFMMaster.lua / IFMWorker.lua and ifm/*.lua together, so keep them together.")
    print("It runs up to " .. tostring(MAX_TASKS) .. " tasks in parallel (coroutines) and only reports")
    print("busy when that task table is full; the master keeps working on its own in the meantime.")
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

--- 找一个 modem（有线优先）并打开频道；实现见 modules/modems.lua（与主控同一份）
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

--- 私有作业频道（用户第 3 项：事件越少越好）：主控会把本机的作业只发到这个频道上，
--- 别的 worker 连那个 modem_message 事件都不会产生。老主控不认识它（照旧广播在公共频道上），
--- 所以主控与 worker 可以先后升级；开不出频道就退回公共频道。
local jobChannel = Transfer.workerChannelOf(computerId)
do
    local okJob, jobErr = pcall(modem.open, jobChannel)
    if not okJob then
        print("[worker] warning: cannot open private job channel " .. tostring(jobChannel) ..
            " (" .. tostring(jobErr) .. ") - falling back to the shared channel")
        jobChannel = nil
    end
end
if workerName == nil or workerName == "" then
    workerName = "worker-#" .. tostring(computerId)
end

local version = Transfer.VERSION

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

--- ===== 任务结果的发件箱（用户第 3 项）=====
--- 每条任务结束原来都各发一次 modem：同一 tick 里 64 条任务同时结束 = 64 次 modem 调用，
--- 主控那边就是 64 个 modem_message 事件（CC:T 的事件队列超过 256 条会开始丢事件）。
--- 现在把本 tick 结束的任务结果攒起来，tick 末发**一条** { op = "results", results = {...} }。
--- 按用户第 4 项：不做老版本兼容 —— 即使只有一条结果也走同一个信封。
local resultOutbox = {}
local function queueResult(message)
    resultOutbox[#resultOutbox + 1] = message
end

--- 把本 tick 攒下的结果一次发出去（返回发出去几条）
local function flushResults()
    if #resultOutbox == 0 then
        return 0
    end
    local batch = resultOutbox
    resultOutbox = {}
    reply({ op = "results", results = batch })
    return #batch
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
    --- 用户第 1 项：谁来执行这次搬运由**主控按外设类型**决定（job.actor，见 containers.lua 的
    --- moveActorOf）—— 这里**只执行一种方法，不再"失败了换另一种再试"**：
    ---   actor = "from"：源侧动手（from.pushItems / from.pushFluid）
    ---   actor = "to"  ：目标侧动手（to.pullItems / to.pullFluid）
    --- 海龟（没有 inventory）永远是 "to"：搬它物品栏里的东西只能由对面的容器来拉 ——
    --- 对它调用 pushItems/pullItems 是白费（现场那行 `attempt to call a nil value` 就是这么来的）。
    local actor = job.actor == "to" and "to" or "from"
    local function methodOf(handle, name)
        if type(handle) ~= "table" then
            return nil
        end
        return handle[name]
    end
    if job.action == "push_item" then
        local fromPeripheral = peripheral.wrap(job.from)
        local toPeripheral = peripheral.wrap(job.to)
        if not fromPeripheral then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        if not toPeripheral then
            return 0, "peripheral " .. tostring(job.to) .. " not found"
        end
        if actor == "to" then
            local pull = methodOf(toPeripheral, "pullItems")
            if not pull then
                return 0, tostring(job.to) .. " has no pullItems (not an inventory peripheral)"
            end
            --- 用户第 2 项：pullItems 的**源槽位是必填的**（现场报错：bad argument #2 (number expected, got nil)）。
            --- 主控拿不到槽位时不该派这条活（containers.lua 会先向海龟要物品栏上报）；这里兜一层，
            --- 报一句能看懂的原因，而不是把 Lua 的参数错误丢给用户。
            if type(job.fromSlot) ~= "number" then
                return 0, "pullItems needs a source slot (the master has none yet - " ..
                    "waiting for the crafter inventory report)"
            end
            local ok, moved = pcall(pull, job.from, job.fromSlot, limit, job.toSlot)
            if ok and type(moved) == "number" and moved > 0 then
                return moved
            end
            return 0, ok and "moved nothing" or tostring(moved)
        end
        local push = methodOf(fromPeripheral, "pushItems")
        if not push then
            return 0, tostring(job.from) .. " has no pushItems (not an inventory peripheral)"
        end
        local ok, moved = pcall(push, job.to, job.fromSlot, limit, job.toSlot)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        return 0, ok and "moved nothing" or tostring(moved)
    end
    if job.action == "push_fluid" then
        local fromPeripheral = peripheral.wrap(job.from)
        local toPeripheral = peripheral.wrap(job.to)
        if not fromPeripheral then
            return 0, "peripheral " .. tostring(job.from) .. " not found"
        end
        if not toPeripheral then
            return 0, "peripheral " .. tostring(job.to) .. " not found"
        end
        if actor == "to" then
            local pull = methodOf(toPeripheral, "pullFluid")
            if not pull then
                return 0, tostring(job.to) .. " has no pullFluid (not a fluid peripheral)"
            end
            local ok, moved = pcall(pull, job.from, limit, job.fluid)
            if ok and type(moved) == "number" and moved > 0 then
                return moved
            end
            return 0, ok and "moved nothing" or tostring(moved)
        end
        local push = methodOf(fromPeripheral, "pushFluid")
        if not push then
            return 0, tostring(job.from) .. " has no pushFluid (not a fluid peripheral)"
        end
        local ok, moved = pcall(push, job.to, limit, job.fluid)
        if ok and type(moved) == "number" and moved > 0 then
            return moved
        end
        return 0, ok and "moved nothing" or tostring(moved)
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
-- 一次只查一个容器：主控要“查询所有容器”时由它自己拆成多条查询、轮流派给各台 worker ——
-- 这样某个慢容器只会拖住它自己那一条，不会连带整整一批（也不会把 worker 的心跳卡住）。
-- 回报里的 scannedContainers 只会包含这个容器（没扫到就是空表 → 主控本机读）。
-- 本机扫描本机能看到的 inventory / fluid_storage，把每个槽位/储罐原样回报，并附上按名称合计的数量。

--- 外设枚举用与主控同一个模块（modules/peripherals.lua）：多类型外设也认得
--- （CC:T 的 peripheral.getType 可能返回多个类型，自己比较第一个会漏掉）。
local peripherals = Peripherals.new({ log = function() end })

--- 一次查询只查一个容器（“查询所有容器”由主控拆成多条查询并行派活，见 modules/transfer.lua）：
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

--- 执行一次查询：一个容器（物品 + 流体都看，因为这个容器可能同时提供两种外设）
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
    --- 数值版"扫到了几个容器"：主控 onQueryResult 读的就是这一个字段。
    --- 注意（修 bug）：以前只发 scannedContainers，主控读 message.scanned = nil，
    --- 于是**每一次成功的扫描都被当成"没扫到"丢掉**（快照永远不更新、扫描队列空转）。
    --- 现在两个字段都发：老主控读 scannedContainers，新主控读 scanned。
    result.scanned = itemScanned + fluidScanned
    result.elapsed = os.epoch("utc") - startedAt
    return result
end

-- ===================== detail：物品详情（getItemDetail）=====================
-- 主控要问「某个物品的 maxCount / tags」时发：
--   { op = "detail", id, samples = { { container = 外设名, slot = 槽位, name = 物品名, nbt = ... }, ... } }
-- getItemDetail 与 list() 一样是阻塞的外设调用（有线网络上 ≈1 个服务器刻/次），
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
local lastStateAt = 0
local lastQuery = nil          -- 最近一次查询的摘要（连同状态一起上报给主控）
local stuckTotal = 0           -- 因为超时被摘掉的卡住任务数（>0 说明有容器/外设长时间不响应）

--- ===== 并行任务表 =====
--- tasks[id] = { id, kind, text, co, startedAt, onDone }
--- taskOrder = 按启动顺序排的任务号（保证屏幕上显示的顺序稳定）
local tasks = {}
local taskOrder = {}
local pumpTasks                       -- 前向声明（startTask 里要用）
--- 本轮第 6 项：这一秒里出现过的**最大并发任务数**。
--- 为什么需要它：任务都很短（一次扫描/搬运常常 1 个游戏刻就完），而状态每秒只上报一次 ——
--- 直接上报"上报这一刻的条数"几乎永远是 0，网页上就成了"永远空闲、负载 0/64"，
--- 看起来像没在干活（用户现场：挂了 27 个存储容器却全显示 0）。
--- 所以把整秒的峰值一起报上去（见 reportState / notePeakLoad）。
local peakLoad = 0

local function taskCount()
    return #taskOrder
end

--- 记下这一刻的并发数（取整秒内的峰值）。任务开始/结束时都要调一次：
--- 一条"开始即结束"的短任务，光靠每秒采样是抓不到的。
local function notePeakLoad()
    local count = taskCount()
    if count > peakLoad then
        peakLoad = count
    end
    return count
end

--- 当前正在做的事（网页“当前工作”一列显示的就是这些字符串）
local function taskList()
    local out = {}
    for _, id in ipairs(taskOrder) do
        local task = tasks[id]
        if task then
            out[#out + 1] = task.text
        end
    end
    return out
end

--- 上报用的“当前工作”列表（最多 STATE_TASK_LIST 条；其余用一行计数代替）
local function publishedTasks()
    local all = taskList()
    if #all <= STATE_TASK_LIST then
        return all
    end
    local out = {}
    for i = 1, STATE_TASK_LIST do
        out[i] = all[i]
    end
    out[#out + 1] = "+" .. tostring(#all - STATE_TASK_LIST) .. " more"
    return out
end

--- 每秒上报一次：主控用它更新 worker 注册表、网页用它显示“这台 worker 在干什么”
local function reportState()
    local running = taskCount()
    reply({
        op = "state",
        name = workerName,
        version = version,
        caps = caps,
        --- 私有作业频道（用户第 3 项）：主控据此把作业发到只有本机收得到的频道上
        jobChannel = jobChannel,
        --- 忙 = 任务表满（MAX_TASKS 条在跑）：主控据此把活派给别人或自己本机做
        busy = running >= MAX_TASKS,
        busyKind = running > 0 and "tasks" or nil,
        --- 1.8.0：并发槽位与当前负载（load 让主控校正它那边的在飞计数）
        load = running,
        --- 本轮第 6 项：这一秒里的峰值并发（网页的负载条用它才看得见"确实在跑"）。
        --- 报完重置成当前条数：下一个窗口只统计这一秒之后的活动。
        peak = peakLoad,
        slots = MAX_TASKS,
        masterVersion = masterVersion,
        versionMismatch = versionWarning ~= nil,
        jobs = jobsDone,
        moved = movedTotal,
        queries = queriesDone,
        details = detailsDone,
        detailItems = detailItems,
        tasks = publishedTasks(),
        lastQuery = lastQuery,
        --- 卡住被摘掉的任务数（>0 说明某个容器/外设长时间不响应，屏幕上也会打印它是什么）
        stuck = stuckTotal,
    })
    lastStateAt = os.epoch("utc")
    peakLoad = running
end

--- 把长时间没跑完的任务从任务表里摘掉（见 TASK_TIMEOUT）：槽位必须还回来，
--- 否则任务表会被“挂在等待里的任务”慢慢占满，整台 worker 最后被判成忙。
local function dropStuckTasks(now)
    for index = #taskOrder, 1, -1 do
        local task = tasks[taskOrder[index]]
        if task and now - (task.startedAt or now) > TASK_TIMEOUT * 1000 then
            stuckTotal = stuckTotal + 1
            workerLog("task #" .. tostring(task.id) .. " (" .. tostring(task.text) ..
                ") has been waiting for more than " .. tostring(TASK_TIMEOUT) ..
                "s - dropping it so the slot is free again (that container/peripheral is not answering)")
            tasks[task.id] = nil
            table.remove(taskOrder, index)
        end
    end
end

--- 这条握手消息是不是另一台 worker 发来的（而不是主控）？
--- worker 的 hello / pong 一定带 caps（能力表）与 name；主控的 hello 两者都没有。
local function isWorkerHandshake(message)
    return type(message.caps) == "table" or type(message.name) == "string"
end

--- 这条消息是不是主控发来的？只有三种情况算：
---   1) 明确发给本机（target == 本机号）：job / query / welcome；
---   2) 带 master = true（1.5.3 起主控的 hello / pong / welcome 都带）；
---   3) 老版本主控的 hello / pong 握手（没有 caps / name 这两个 worker 字段）。
--- 其余一律不是 —— 别的 worker 每秒上报的 state / query_result 都没有 target，
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
-- 主控与 worker 之间是无线 modem：消息偶尔会丢（距离/干扰）。主控对一条查询/搬运会重发同一个 id，
-- 所以这里要做两件事：
--   1) 幂等：同一个 id 已经做过 → 把上次的结果再回一遍（绝不重复搬运、也不重复扫描）；
--   2) 排队：手上正忙时不回 busy（主控那边会白等到超时），先把消息存起来，忙完立刻做。
local TASK_CACHE_MAX = 16
local EXECUTED_MAX = 64         -- 记住“搬运任务已经执行过”的 id（结果被淘汰后也不会重复搬）
local recentTasks = {}          -- id -> 已回过的那条结果消息
local recentTaskOrder = {}      -- 只用来限制缓存条数（先进先出淘汰；与任务表的 taskOrder 无关）
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
        recentTaskOrder[#recentTaskOrder + 1] = id
    end
    recentTasks[id] = message
    while #recentTaskOrder > TASK_CACHE_MAX do
        recentTasks[table.remove(recentTaskOrder, 1)] = nil
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
    queueResult(copy)
    return true
end

--- 任务表满了（MAX_TASKS 条在跑）：回 busy 让主控把这条活交给别人 / 自己本机做。
--- 1.8.0 之前这里是“排队等它忙完”，但那样主控要等 20 秒才超时；现在 worker 一次能并行 64 条，
--- 满了就说明它确实接不下，直接告诉主控是最快的选择。
local function rejectFull(message)
    if taskCount() < MAX_TASKS then
        return false
    end
    reply({ op = "busy", id = message.id,
        query = message.op == "query" or message.op == "detail" })
    return true
end

--- 起一条任务：body 在协程里跑（可以调外设，会等 1 个游戏刻），task.onDone 在结束时回结果。
--- 同一个 id 已经在跑时不再起第二条（主控会重发同一个 id，靠这个幂等）。
local function startTask(message, kind, text, body, onDone)
    local id = tonumber(message.id)
    if id == nil or tasks[id] then
        return false
    end
    local task = { id = id, kind = kind, text = text, startedAt = os.epoch("utc"), onDone = onDone }
    task.co = coroutine.create(function()
        local ok, result = pcall(body)
        task.ok = ok
        task.result = result
    end)
    tasks[id] = task
    taskOrder[#taskOrder + 1] = id
    notePeakLoad()                      -- 本轮第 6 项：任务表刚变大 → 这一秒的峰值可能更新
    --- 立刻推进一次：这条任务在本 tick 里就发出第一次外设调用（不等下一个事件）
    pumpTasks()
    return true
end

--- 任务结束：交给它的 onDone（计数 / 记结果 / 回消息），然后从任务表里摘掉
local function finishTask(task, index)
    table.remove(taskOrder, index)
    tasks[task.id] = nil
    if task.onDone then
        local ok, err = pcall(task.onDone, task)
        if not ok then
            workerLog("task callback failed: " .. tostring(err))
        end
    end
end

--- 推进所有任务（主循环每处理完一个事件调用一次；与 CC:T parallel 的调度方式一致）：
---   * 还没跑完的协程：把当前事件交给它（它内部那次 pullEvent 会自己过滤）→ 它继续跑；
---   * 跑完（dead）的协程：回结果、计数、从任务表里摘掉。
--- 倒序遍历：finishTask 会就地删掉当前这一项。
function pumpTasks(event, p1, p2, p3, p4, p5)
    for i = #taskOrder, 1, -1 do
        local task = tasks[taskOrder[i]]
        if not task then
            table.remove(taskOrder, i)
        else
            if coroutine.status(task.co) == "suspended" then
                local ok, err = coroutine.resume(task.co, event, p1, p2, p3, p4, p5)
                if not ok then
                    task.ok = false
                    task.result = "task crashed: " .. tostring(err)
                end
            end
            if coroutine.status(task.co) == "dead" then
                finishTask(task, i)
            end
        end
    end
end

--- 收到过"单条任务报文"（用户第 1 项：任务必须打包下发，单条格式已废弃）—— 只提示一次
local unbatchedTaskSeen = false


local function handleMessage(message, fromEnvelope)
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
    --- 用户第 1 项：任务**只**以 { op = "jobs", jobs = {...} } 信封下发（即使只有 1 条任务）。
    --- 单条任务报文（op = job / query / detail）已经废弃：收到就拒绝、不执行 ——
    --- 两种格式混着来会让"任务到底发了没有"极难排查（用户第 4 项：不做老版本兼容）。
    if op == "job" or op == "query" or op == "detail" then
        if not fromEnvelope then
            if not unbatchedTaskSeen then
                unbatchedTaskSeen = true
                workerLog("refused a single-task message (op=" .. tostring(op) ..
                    "): tasks must arrive as one { op = \"jobs\", jobs = {...} } envelope" ..
                    " - install the same build on master and worker")
            end
            return
        end
    end
    -- 能走到这里说明这条消息是主控发来的
    -- job / query 里的 from / to 是容器外设名，不是发信人：发信人看 sender（1.5.4 起主控会带上）
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
        -- 顺带把版本与并发槽位带上：主控立刻就知道这台 worker 一次能并行几条任务
        reply({ op = "pong", name = workerName, caps = caps, version = version,
            slots = MAX_TASKS, load = taskCount(), jobChannel = jobChannel })
        return
    end
    if op == "pong" then
        return
    end
    if op == "welcome" then
        -- 主控报到（房间号 / 版本）。worker 不需要房间号，但必须核对版本：
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
    --- 主控与 worker 的版本必须完全一致，否则拒绝执行任何作业。
    --- 只在主控版本已知时判断（hello/pong/welcome 不受影响，否则两边连互相认识都做不到）。
    if masterVersion and masterVersion ~= version then
        local why = "version mismatch: master " .. tostring(masterVersion) .. " vs worker " .. tostring(version)
        if op == "job" then
            queueResult({ op = "error", id = message.id, moved = 0, error = why })
        elseif op == "query" then
            queueResult({ op = "query_result", id = message.id, ok = false, error = why })
        elseif op == "detail" then
            queueResult({ op = "detail_result", id = message.id, ok = false, error = why })
        end
        if lastVersionWarning ~= why then
            lastVersionWarning = why
            workerLog(why .. " - job refused; install the same build on master and worker")
        end
        return
    end
    if op == "job" then
        if not caps.move then
            queueResult({ op = "error", id = message.id, moved = 0, error = "worker disabled moves (--no-move)" })
            return
        end
        --- 主控重发的同一条任务：直接把上次结果再回一遍（不重复搬东西）
        if resendTask(message) then
            return
        end
        --- 做过、但结果已经从缓存里淘汰了：绝不能再搬一次（可能又搬一份出去）
        if executedJobs[tonumber(message.id)] then
            queueResult({ op = "done", id = message.id, moved = 0,
                error = "already executed earlier (result expired)" })
            return
        end
        --- 任务表满了（64 条在跑）才回 busy：主控会把这条活交给别的 worker 或自己本机做
        if rejectFull(message) then
            return
        end
        startTask(message, "move", describeMove(message), function()
            --- pcall：任何意外（外设被拆掉、名字不合法…）都不该中断主循环
            local okMove, moved, err = pcall(runMove, message)
            if not okMove then
                workerLog("move error: " .. tostring(moved))
                return { moved = 0, err = "move crashed: " .. tostring(moved) }
            end
            return { moved = tonumber(moved) or 0, err = err }
        end, function(task)
            local result = task.result
            local moved, err = 0, nil
            if type(result) == "table" then
                moved = tonumber(result.moved) or 0
                err = result.err
            elseif task.ok == false then
                err = "move crashed: " .. tostring(result)
            end
            jobsDone = jobsDone + 1
            movedTotal = movedTotal + moved
            local out = { op = moved > 0 and "done" or "error", id = message.id, moved = moved, error = err }
            markExecuted(message.id)
            rememberTask(message.id, out)
            queueResult(out)
        end)
        return
    end
    if op == "detail" then
        --- 物品详情代查（getItemDetail）：与 query 同一套幂等 / 排队 / 回报规则
        if not caps.query then
            queueResult({ op = "detail_result", id = message.id, ok = false, error = "worker disabled queries (--no-query)" })
            return
        end
        if resendTask(message) then
            return
        end
        if rejectFull(message) then
            return
        end
        local samples = type(message.samples) == "table" and message.samples or {}
        reply({ op = "detail_ack", id = message.id, samples = #samples })
        startTask(message, "detail", "detail " .. tostring(#samples) .. " item type(s)",
            function()
                return runDetail(message)
            end, function(task)
                local result = task.result
                if task.ok == false or type(result) ~= "table" then
                    local why = "detail crashed: " .. tostring(result)
                    workerLog(why)
                    local failed = { op = "detail_result", id = message.id, ok = false, error = why }
                    rememberTask(message.id, failed)
                    queueResult(failed)
                    return
                end
                detailsDone = detailsDone + 1
                detailItems = detailItems + (tonumber(result.items) or 0)
                workerLog("detail: " .. tostring(result.items) .. " of " .. tostring(#samples) ..
                    " item type(s) in " .. tostring(result.elapsed) .. "ms")
                rememberTask(message.id, result)
                queueResult(result)
            end)
        return
    end
    if op == "query" then
        if not caps.query then
            queueResult({ op = "query_result", id = message.id, ok = false, error = "worker disabled queries (--no-query)" })
            return
        end
        --- 主控重发的同一条查询：直接把上次结果再回一遍（不重复扫描）
        if resendTask(message) then
            return
        end
        --- 任务表满了才回 busy（1.8.0：worker 一次能并行 64 条）
        if rejectFull(message) then
            return
        end
        --- 立刻回一条“收到了”：主控据此区分「消息没到 worker」与「结果丢了」——
        --- 只有一条 15 秒超时日志时，根本判断不出是哪一边的问题（1.5.7 起）。
        local container = pickContainer(message)
        reply({ op = "query_ack", id = message.id, container = container })
        startTask(message, "query", "query " .. tostring(container or "?"), function()
            return runQuery(message)
        end, function(task)
            local result = task.result
            if task.ok == false or type(result) ~= "table" then
                local why = "query crashed: " .. tostring(result)
                workerLog(why)
                local failed = { op = "query_result", id = message.id, ok = false, error = why }
                rememberTask(message.id, failed)
                queueResult(failed)
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
            queueResult(result)
        end)
        return
    end
end

--- ===================== 屏幕 / 主循环 =====================
--- 打包的作业报文（用户第 1 项）：主控的 flushOutbox 把同一个 tick 里发给本机的所有任务
--- （搬运 / 查询 / 详情）合成**一条** { op = "jobs", jobs = {...} }，**即使只有 1 条任务**也走信封。
--- 这里把它拆成单条，再走同一个处理函数 —— 每条都会各起一个协程。
--- 于是：单条 job / query / detail 的"专门单发格式"已经不存在（用户第 4 项：不做老版本兼容）。
local function dispatchMessage(message)
    if type(message) ~= "table" or message.op ~= "jobs" then
        return handleMessage(message)
    end
    local jobs = type(message.jobs) == "table" and message.jobs or {}
    for _, job in ipairs(jobs) do
        if type(job) == "table" then
            if job.op == nil then
                job.op = "job"
            end
            if job.target == nil then
                job.target = message.target
            end
            handleMessage(job, true)
        end
    end
end

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
    lines[#lines + 1] = "tasks    : " .. tostring(taskCount()) .. " / " .. tostring(MAX_TASKS) ..
        " slot(s) in use" .. (taskCount() >= MAX_TASKS and "  (FULL - the master will use others)" or "")
    if stuckTotal > 0 then
        lines[#lines + 1] = "stuck    : " .. tostring(stuckTotal) ..
            " task(s) dropped after " .. tostring(TASK_TIMEOUT) .. "s - check those containers/peripherals"
    end
    lines[#lines + 1] = "current work:"
    local tasks = taskList()
    if #tasks == 0 then
        lines[#lines + 1] = "  (idle)"
    else
        --- 最多显示 SCREEN_TASK_LINES 条：64 条全打出来屏幕会滚掉，反而看不到重点
        for index, text in ipairs(tasks) do
            if index > SCREEN_TASK_LINES then
                lines[#lines + 1] = "  ... +" .. tostring(#tasks - SCREEN_TASK_LINES) .. " more"
                break
            end
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
        reply({ op = "hello", name = workerName, caps = caps, channel = channel, version = version,
            slots = MAX_TASKS, load = taskCount() })
    end
    if masterOnline and now - lastMasterAt > MASTER_TIMEOUT * 1000 then
        masterOnline = false
        workerLog("master silent for " .. tostring(MASTER_TIMEOUT) .. "s - waiting for it")
    end
    if now - lastStateAt >= STATE_INTERVAL * 1000 then
        reportState()
    end
    notePeakLoad()                      -- 本轮第 6 项：每 0.2s 采一次，峰值才抓得住短任务
    dropStuckTasks(now)
    --- 用户第 3 项：本 tick 结束的任务结果一次性发出（上面各处只入箱、不单独发 modem）
    flushResults()
    if now - lastDrawAt >= 1000 then
        lastDrawAt = now
        redraw(false)
    end
end

redraw(true)
workerLog("IFMWorker started: name=" .. tostring(workerName) .. " channel=" .. tostring(channel) ..
    " caps=" .. (caps.move and "move," or "") .. (caps.query and "query" or ""))
reply({ op = "hello", name = workerName, caps = caps, channel = channel, version = version,
    slots = MAX_TASKS, load = taskCount() })

--- 主循环：任何意外错误都不该让 worker“无声死掉”（主控会把它当成失联），所以出错后打印原因并
--- 自动重启主循环；只有 Ctrl+T（Terminated）才真正退出。
local function mainLoop()
    local timerToken = os.startTimer(0.2)
    while true do
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        local now = os.epoch("utc")
        if event == "modem_message" then
            -- modem_message: side, channel, replyChannel, message, distance
            -- 注意：message 是第 4 个参数（param4），第 5 个是 distance
            if tonumber(param2) == channel or (jobChannel and tonumber(param2) == jobChannel) then
                dispatchMessage(param4)
            end
        elseif event == "timer" and param1 == timerToken then
            timerToken = os.startTimer(0.2)
            tick(now)
        end
        --- 推进并行任务表（与 CC:T parallel 的调度方式一致）：把刚拿到的事件交给每条协程，
        --- 它们内部的 pullEvent 会自己过滤；跑完的任务在这里回结果。
        pumpTasks(event, param1, param2, param3, param4, param5)
    end
end

while true do
    --- 主循环每一轮开始时清空任务表：上一轮如果是被异常打断的（下面的 pcall 捕获），
    --- 任务协程会留在表里 —— 那台 worker 之后会一直显示“忙”。清空后由主控重发。
    tasks = {}
    taskOrder = {}
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