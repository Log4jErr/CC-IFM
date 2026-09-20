-- ============================================================
-- IFMCrafter.lua -- IFM 配套：装在机械臂（海龟 / turtle）上的合成执行器
--
-- 职责（用户第 1/4 项，刻意做得极简）：
--   * 只告诉主控"这里有一台合成器"（每 2 秒一次 hello，带自己在**网络上**的外设名）；
--   * 收到主控的 craft 指令就 `turtle.craft(64)` —— **不校验配方、不回报合成状态**。
--     合成失败时材料就留在海龟物品栏里，IFM 抽不出产物，流程自然卡住 —— 由用户自己修流程，
--     这正是想要的行为（少一层猜测，也就少一堆可能与实际不一致的汇报）。
--   * 一颗物品都不搬（材料由 IFMWorker 推进海龟物品栏，产物也由 IFMWorker 抽走）。
--
-- 与 IFM 的集成：
--   * 与 IFMMaster.lua / IFMWorker.lua 同一份 ifm/ 目录（模块 modem 发现、协议常量、版本号）；
--   * 走**专用频道** Transfer.CRAFTER_CHANNEL（默认 41001），与 IFMWorker 的 41000 分开；
--   * 会一起打进单文件产物（build.py），解压后就能启动。
--
-- 协议（proto = "ifm_crafter"）：
--   合成器 -> 主控  { op = "hello", name = <本机网络外设名>, label, version, busy, crafts }
--   主控 -> 合成器  { op = "pong" / "ping", master = true, version = ... }
--   主控 -> 合成器  { op = "craft", id = 任务号 }        -- 收到就 craft(64)，不回任何消息
--
-- name 为什么重要：主控在网络上看到的是 "turtle_N" 这样的**外设名**；本机用
-- modem.getNameLocal()（CC:T 文档：Returns the network name of the current computer,
-- if the modem is on.）问出自己的网络名报上去，主控两边一对就知道
-- "这个 turtle 外设正跑着合成器"（用户第 2 项），从而把它当作 turtle_crafter 机器使用。
--
-- 用法（装在机械臂上；建议放进 startup.lua 开机自启）：
--   IFMCrafter.lua                        -- 默认频道 41001
--   IFMCrafter.lua --name smelt-crafter   -- 网页上显示的名字
--   IFMCrafter.lua --help
--
-- 终端输出一律 ASCII 英文（CC:T 终端字形不含中日韩字符）。
-- ============================================================

local args = { ... }

--- 脚本目录与 modules/：定位方式与 IFMWorker.lua 完全一致（同一份 ifm/ 目录）
local scriptPath = shell and shell.getRunningProgram and shell.getRunningProgram() or "IFMCrafter.lua"
local baseDir = fs.getDir(scriptPath)
if baseDir == "" then
    baseDir = "/"
end
local moduleDir = fs.combine(baseDir, "modules")

local function loadModule(name)
    local path = fs.combine(moduleDir, name .. ".lua")
    if not fs.exists(path) then
        error("Missing module file: " .. path ..
            " - keep IFMCrafter.lua next to the modules/ directory (the IFM bundle writes both)", 0)
    end
    local chunk, err = loadfile(path)
    if not chunk then
        error("Failed to load module " .. path .. ": " .. tostring(err), 0)
    end
    return chunk()
end

--- 与主控共用的模块：modems（modem 发现/发送）、transfer（频道/协议/版本号）
local Modems = loadModule("modems")
local Transfer = loadModule("transfer")

local PROTOCOL = Transfer.CRAFTER_PROTOCOL     -- "ifm_crafter"
local CHANNEL = Transfer.CRAFTER_CHANNEL       -- 41001（与 IFMWorker 分开）
local VERSION = Transfer.VERSION

local HELLO_INTERVAL = 2           -- 秒：每 2 秒报一次到（主控据此判断合成器是否在线）
local MASTER_TIMEOUT = 30          -- 秒：多久没收到主控消息就认为它不在
local CRAFT_LIMIT = 64             -- 一次合成指令固定 craft(64)（用户第 1 项：不做校验）
--- 只有**合成海龟**（用工作台升级过的）才有 turtle.craft。
--- 现场教训（用户第 1 项）：普通海龟上 turtle.craft 是 nil，pcall 里报
--- "attempt to call a nil value"，屏幕上只剩这行 Lua 错误 —— 完全看不出"这台海龟根本不能合成"。
--- 这里开机就检查一次，检查不过就常显警告、并且拒绝合成请求（报清楚原因）。
local turtleApiReady = type(turtle) == "table"
local craftSupported = turtleApiReady and type(turtle.craft) == "function"
--- 用户第 2 项：物品栏上报。海龟没有 inventory 外设，主控抽产物时必须给出**源槽位**
--- （pullItems 的槽位参数必填，现场报错 bad argument #2 (number expected, got nil)），
--- 而 turtle.craft 不告诉我们产物落在哪个槽位 —— 只能由海龟自己把物品栏报上去。
local INVENTORY_SLOTS = 16          -- 海龟物品栏 16 格
local INVENTORY_REPORT_INTERVAL = 5 -- 秒：物品栏非空时每隔这么久重报一次（主控的上报 15 秒过期）

local workerName = nil             -- --name：显示用标签（默认用本机电脑号）
local channel = CHANNEL


local function printUsage()
    print("IFMCrafter.lua - IFM turtle crafter (executor for the turtle_crafter machine type)")
    print("Usage: IFMCrafter.lua [--channel <n>] [--name <label>] [--help]")
    print("  --channel  modem channel shared with the IFM master (default " .. tostring(CHANNEL) .. ")")
    print("             NOTE: this must NOT be the IFMWorker channel (" .. tostring(Transfer.CHANNEL) .. ")")
    print("  --name     label shown in the web UI (default: computer id)")
    print("It only announces itself and runs turtle.craft(64) on request: no recipe check, no")
    print("status report, no item movement (IFMWorker pushes the materials in and takes the")
    print("products out). Keep the same ifm/ directory next to this file.")
    print("A wired modem is required: modem.getNameLocal() is how the turtle learns its own")
    print("network name, which is how the master recognises it as a running crafter.")
end

do
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
        else
            print("unknown argument ignored: " .. value)
        end
        index = index + 1
    end
end

--- 必须跑在机械臂上（turtle API 只在机械臂上存在）
if type(turtle) ~= "table" then
    print("IFMCrafter.lua must run on a turtle (no turtle API found).")
    return
end

--- 找一个 modem（有线优先）并打开频道；实现见 modules/modems.lua（与主控/worker 同一份）
local modem, modemSide = Modems.find()
if not modem then
    print("IFMCrafter.lua: no modem found. Attach a (wired) modem and run this again.")
    return
end
local okOpen, openErr = pcall(modem.open, channel)
if not okOpen then
    print("IFMCrafter.lua: cannot open channel " .. tostring(channel) .. " (" .. tostring(openErr) .. ")")
    return
end

local computerId = os.getComputerID()
if workerName == nil or workerName == "" then
    workerName = "crafter-#" .. tostring(computerId)
end

--- 本机在**网络上**的名字（主控看到的外设名，例如 turtle_0）：只有有线 modem 问得到；
--- 无线 modem 返回空 —— 那时主控只能用电脑号认本机（用户第 2 项的识别就是靠这个名字）。
local selfName = nil
do
    local ok, value = pcall(modem.getNameLocal)
    if ok and type(value) == "string" and value ~= "" then
        selfName = value
    end
end

local function crafterLog(text)
    print("[crafter] " .. tostring(text))
end

--- 会话状态（只用于屏幕显示；主控那边不依赖它）
local masterId = nil
local lastMasterAt = 0
local masterOnline = false
local versionWarning = nil
local lastVersionWarning = nil
local helloAt = 0
local busy = false
local craftCalls = 0
local lastCraftAt = 0
local lastCraftError = nil
--- 用户第 4 项：收到过多少条合成请求（屏幕 + 日志都要看得见 —— 出问题时先确认"请求到没到"）
local requestCount = 0
local lastRequestId = nil
local lastRequestAt = 0
--- 用户第 2 项：最近一次上报的物品栏（格子数）与上报时间
local inventoryStacks = 0
local inventoryReportAt = 0
local lastText = {}

--- 向频道广播一条消息（proto/from 自动补上；发送失败只提示一次）
local lastSendError = nil
local function reply(message)
    message.proto = PROTOCOL
    message.from = computerId
    local ok, err = Modems.transmit(modem, channel, message)
    if not ok then
        local text = tostring(err)
        if text ~= lastSendError then
            lastSendError = text
            crafterLog("modem send failed (" .. tostring(message.op) .. "): " .. text)
        end
    end
end


-- ===================== 与主控的会话 =====================
--- 这条消息是不是主控发来的（主控的握手/指令都带 master = true）
local function isMasterMessage(message)
    if message.master == true then
        return true
    end
    return message.op == "hello" and message.caps == nil and message.name == nil
end

local function rememberMaster(message)
    local sender = tonumber(message.from)
    if sender and sender ~= computerId then
        masterId = sender
    end
    if type(message.version) == "string" and message.version ~= "" then
        if message.version ~= VERSION then
            versionWarning = "version mismatch: master " .. message.version .. " vs crafter " .. VERSION
            if lastVersionWarning ~= versionWarning then
                lastVersionWarning = versionWarning
                crafterLog(versionWarning .. " - put the same build on master and turtle")
            end
        else
            versionWarning = nil
        end
    end
    lastMasterAt = os.epoch("utc")
    masterOnline = true
end

--- 用户第 2 项：读一遍自己的物品栏（槽位号 + 注册名 + 数量 + NBT）
local function readInventory()
    local items = {}
    for slot = 1, INVENTORY_SLOTS do
        --- 用户第 1 项：用 turtle.getItemCount(slot) 判断"这一格有没有东西"，**直接调用、不用 pcall**
        --- （也不做交叉验证）。之前用的是 `getItemDetail(slot, true)`：detailed 参数是 CC:T 1.90 才
        --- 加上的，旧版上这个多余的参数会报错，而错误被 pcall 吞掉 —— 于是上报永远是"0 格"，
        --- 而产物其实就在 #1 槽（现场症状：inv : 0 stack(s)，但 turtle.getItemCount(1) 能看到铁锭）。
        local count = turtle.getItemCount(slot)
        if count and count > 0 then
            --- 名字 / NBT 仍然要问 getItemDetail，但**不带 detailed 参数**（旧版不认第二个参数）
            local detail = turtle.getItemDetail(slot)
            items[#items + 1] = {
                slot = slot,
                name = detail and detail.name or nil,
                count = count,
                nbt = detail and detail.nbt or nil,
            }
        end
    end
    return items
end

--- 用户第 2/4 项：把物品栏上报给主控（合成之后 / 主控索要 / 有货时每 5 秒一次）。
--- 主控把这份上报写进**内容快照**（Containers:applyScan）：海龟没有 inventory 外设，
--- 扫描队列读不到它，这份上报就是它唯一的内容来源 —— 抽取产物、挑输入槽位都按它决策。
--- size = 物品栏格数：主控问不到 size()，挑目标槽位（insertSlotFor）要靠它。
local function reportInventory()
    local items = readInventory()
    inventoryStacks = #items
    inventoryReportAt = os.epoch("utc")
    reply({
        op = "inventory",
        name = selfName or workerName,
        label = workerName,
        items = items,
        size = INVENTORY_SLOTS,
        at = inventoryReportAt,
        busy = busy,
        crafts = craftCalls,
        target = masterId,
    })
end

--- 主控要求合成：直接 craft(64)，不校验配方、不回报合成状态（用户第 1 项）。
--- 合成失败的材料就留在本机物品栏里 —— IFM 抽不出产物，流程会停在抽产物那一步，
--- 由用户自己修流程（比"猜一个理由回报给主控"更简单也更诚实）。
local function runCraft()
    if busy then
        return                              -- 上一条还没回来（craft 是服务器调用，通常 1 个刻就完）
    end
    if not craftSupported then
        --- 用户第 1 项：普通海龟没有 turtle.craft（只有合成海龟有）。以前直接 pcall 它，
        --- 结果是"attempt to call a nil value"这种看不出原因的错误。
        lastCraftError = "turtle.craft is missing - this is not a CRAFTING turtle (upgrade it with a crafting table)"
        crafterLog("craft refused: " .. tostring(lastCraftError))
        return
    end
    busy = true
    local ok, crafted = pcall(turtle.craft, CRAFT_LIMIT)
    busy = false
    craftCalls = craftCalls + 1
    lastCraftAt = os.epoch("utc")
    if ok then
        lastCraftError = nil
        crafterLog("craft(" .. tostring(CRAFT_LIMIT) .. ") -> " .. tostring(crafted))
    else
        lastCraftError = tostring(crafted)
        crafterLog("craft(" .. tostring(CRAFT_LIMIT) .. ") failed: " .. tostring(crafted))
    end
    --- 用户第 2 项：合成完立刻上报物品栏 —— 主控要靠它知道产物在哪个槽位才能抽出来
    --- （屏幕不用在这里重画：tick 每秒会刷一次，1 秒内就能看到 inventory 行）
    reportInventory()
end

local function handleMessage(message)
    if type(message) ~= "table" or message.proto ~= PROTOCOL or message.from == computerId then
        return
    end
    --- 主控可能用电脑号（它从我们的 hello 里学到）或网络外设名来点名
    if message.target ~= nil and message.target ~= computerId and message.target ~= selfName then
        return
    end
    if not isMasterMessage(message) then
        return                          -- 别把别的机械臂的回报当成主控（它们也在同一个频道上）
    end
    rememberMaster(message)
    local op = message.op
    if op == "hello" then
        reply({ op = "pong", name = selfName or workerName, label = workerName, version = VERSION,
            busy = busy, crafts = craftCalls, target = masterId })
        return
    end
    if op == "ping" then
        reply({ op = "crafter_here", name = selfName or workerName, label = workerName,
            version = VERSION, busy = busy, crafts = craftCalls, target = masterId })
        return
    end
    if op == "craft" then
        --- 用户第 4 项：收到合成请求必须在终端上看得见（以前只有"合成失败"才打印，
        --- 正常收到什么都看不到，出问题时没法判断请求到底有没有到）。
        requestCount = requestCount + 1
        lastRequestId = message.id
        lastRequestAt = os.epoch("utc")
        crafterLog("craft request #" .. tostring(message.id or "?") .. " from master #" ..
            tostring(masterId or "?") .. " -> turtle.craft(" .. tostring(CRAFT_LIMIT) .. ")")
        runCraft()
        return
    end
    --- 用户第 2 项：主控索要物品栏（它要抽产物、但手上没有新鲜的上报时会问）
    if op == "inventory_request" then
        reportInventory()
        return
    end
end

--- 每 2 秒上报一次（主控据此知道"这台 turtle 外设正在跑合成器"，用户第 2 项）
local function reportState()
    reply({ op = "hello", name = selfName or workerName, netName = selfName, label = workerName,
        version = VERSION, busy = busy, crafts = craftCalls })
end


-- ===================== 屏幕 / 主循环 =====================
local lastDrawAt = 0
local function redraw(force)
    local lines = {
        "IFM turtle crafter",
        "name     : " .. tostring(workerName) .. "  (#" .. tostring(computerId) .. ")",
        "network  : " .. tostring(selfName or "(no wired modem - master can only use my id)"),
        "modem    : " .. tostring(modemSide or "?") .. "   channel: " .. tostring(channel),
        "master   : " .. (masterOnline and ("#" .. tostring(masterId or "?")) or "waiting..."),
        "state    : " .. (busy and "CRAFTING" or "idle") .. "   craft(" .. tostring(CRAFT_LIMIT) .. ")",
        "crafts   : " .. tostring(craftCalls),
        "requests : " .. tostring(requestCount) .. (requestCount > 0
            and ("   last #" .. tostring(lastRequestId or "?") .. "   " ..
                tostring(math.max(0, math.floor((os.epoch("utc") - lastRequestAt) / 1000))) .. "s ago")
            or "   (none received yet - master has not asked)"),
        --- 用户第 2 项：主控靠这份上报选槽位抽产物，所以屏幕上要能看出"报了几格、多久前报的"
        "inv      : " .. tostring(inventoryStacks) .. " stack(s)   " .. (inventoryReportAt > 0
            and ("reported " .. tostring(math.max(0, math.floor((os.epoch("utc") - inventoryReportAt) / 1000))) .. "s ago")
            or "never reported"),
    }
    if lastCraftError then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "last craft error: " .. tostring(lastCraftError)
        lines[#lines + 1] = "materials are probably stuck in my inventory - fix the process"
    end
    if versionWarning then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: " .. tostring(versionWarning)
        lines[#lines + 1] = "put the same build (IFMMaster.lua / IFMCrafter.lua) on both computers"
    end
    --- 用户第 1 项：普通海龟没有 turtle.craft（只有合成海龟有）—— 常显警告，别让人对着
    --- "attempt to call a nil value" 猜原因。
    if not craftSupported then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "WARNING: turtle.craft is missing - this is NOT a crafting turtle"
        lines[#lines + 1] = "upgrade it with a crafting table, otherwise it cannot craft at all"
    end
    local text = table.concat(lines, "\n")
    if not force and text == lastText.value then
        return
    end
    lastText.value = text
    term.clear()
    term.setCursorPos(1, 1)
    for _, line in ipairs(lines) do
        print(line)
    end
end

--- 周期任务（0.2s 一次）：报到、屏幕刷新
local function tick(now)
    if now - helloAt >= HELLO_INTERVAL * 1000 then
        helloAt = now
        reportState()
    end
    if masterOnline and now - lastMasterAt > MASTER_TIMEOUT * 1000 then
        masterOnline = false
        crafterLog("master silent for " .. tostring(MASTER_TIMEOUT) .. "s - waiting for it")
    end
    --- 用户第 2 项：物品栏非空时定期重报（主控那边的上报 15 秒过期；抽产物前它也会自己再要一次）
    if inventoryStacks > 0 and now - inventoryReportAt >= INVENTORY_REPORT_INTERVAL * 1000 then
        reportInventory()
    end
    if now - lastDrawAt >= 1000 then
        lastDrawAt = now
        redraw(false)
    end
end

redraw(true)
crafterLog("IFM crafter started: name=" .. tostring(workerName) .. " network=" .. tostring(selfName or "?") ..
    " channel=" .. tostring(channel))
reportState()

--- 主循环：任何意外错误都不该让合成器"无声死掉"（主控会把它当成离线），所以出错后打印原因并
--- 自动重启主循环；只有 Ctrl+T（Terminated）才真正退出。
local function mainLoop()
    local timerToken = os.startTimer(0.2)
    while true do
        --- 注意：os.pullEvent() 一次返回 6 个值（event, p1..p5），必须**逐个都接住**。
        --- 以前这里只写了 4 个变量（event, param1, param2, param4）：第 4 个变量拿到的是
        --- **第 4 个返回值 = replyChannel**（一个数字），而不是 message（第 5 个返回值）——
        --- 于是 handleMessage 的 `type(message) ~= "table"` 把**每一条**主控消息都丢掉：
        --- 屏幕上永远 "master: waiting..."，craft 指令从来不执行（现场症状：
        --- "材料送完后海龟没有触发合成，终端也没有任何收到合成请求的文本"）。
        --- IFMWorker.lua 的写法是对的（param4 = message），这里保持一致。
        local event, param1, param2, param3, param4, param5 = os.pullEvent()
        if event == "modem_message" then
            -- modem_message: side(p1), channel(p2), replyChannel(p3), message(p4), distance(p5)
            if tonumber(param2) == channel then
                handleMessage(param4)
            end
        elseif event == "timer" and param1 == timerToken then
            timerToken = os.startTimer(0.2)
            tick(os.epoch("utc"))
        end
    end
end

while true do
    busy = false
    local okLoop, loopErr = pcall(mainLoop)
    if okLoop then
        break
    end
    crafterLog("main loop error: " .. tostring(loopErr))
    if tostring(loopErr) == "Terminated" then
        crafterLog("stopped by user")
        break
    end
    crafterLog("restarting the main loop in 3 seconds")
    os.sleep(3)
end
