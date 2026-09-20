--[[
    listperf.lua - 并行 list() 性能测试（独立小工具）

    目的：量一下"同一台 modem 能看到的**所有 inventory 外设**"并排 list() 一次要多久。

    为什么值得量：list() 是阻塞的外设调用（有线网络上 ≈1 个服务器刻/次）。
      * 顺序读 N 台 = N 个游戏刻；
      * 全部放进协程同时发出去 = 1 个游戏刻（与 IFMWorker 的任务表同一原理）。
    这个脚本就是"一次性全部发出去、然后等它们全部回来"的那一小段逻辑。

    用法（放在有线网络里的任意计算机上跑；Ctrl+T 停止）：
      listperf.lua

    输出（英文 —— CC 终端字形没有中日韩字符）：
      modem    : back (wired)
      scan     : 27 inventory peripheral(s)
      done     : 58 ms  (27 ok, 0 failed, 412 slot(s))
      slowest  : minecraft:chest_42 (31 ms)

    注意：
      * 有线 modem + 网络线才能看到整网外设；无线 modem 只能看到本机挂着的那些；
      * 数值随区块加载 / 线缆长度 / 外设实现变化，适合做相对比较；
      * 某台外设一直不响应时脚本会一直等（Ctrl+T 停下来）。
--]]

--- 代码与字符串一律 ASCII（build.py 的 tools 检查会校验；注释不受限）。

--- 当前时刻（毫秒）
local function nowMs()
    return os.epoch("utc")
end

--- 外设类型判断：优先 peripheral.hasType（现代 CC:T），并兼容 getType 返回多个类型的情况
local function hasType(name, expected)
    if type(peripheral.hasType) == "function" then
        local ok, result = pcall(peripheral.hasType, name, expected)
        if ok then
            return result == true
        end
    end
    local ok, a, b, c = pcall(peripheral.getType, name)
    if not ok then
        return false
    end
    local kinds = { a, b, c }
    for _, kind in ipairs(kinds) do
        if kind == expected then
            return true
        end
    end
    return false
end

--- 找一台 modem：**有线优先**（有线网络里的计算机共享外设 = 能看到同一张网上的所有容器）
local function findModem()
    local wireless = nil
    for _, side in ipairs(peripheral.getNames()) do
        if hasType(side, "modem") then
            local modem = peripheral.wrap(side)
            if modem then
                local isWired = false
                if type(modem.isWireless) == "function" then
                    local ok, value = pcall(modem.isWireless)
                    isWired = ok and value == false
                end
                if isWired then
                    return modem, side, true
                end
                wireless = wireless or { modem = modem, side = side }
            end
        end
    end
    if wireless then
        return wireless.modem, wireless.side, false
    end
    return nil, nil, false
end

local modem, modemSide, wired = findModem()
if not modem then
    print("listperf: no modem found - attach a (wired) modem and run this again.")
    return
end

--- 本机能看到的所有 inventory 外设（有线网络下就是整张网上的容器）
local names = {}
for _, name in ipairs(peripheral.getNames()) do
    if hasType(name, "inventory") then
        names[#names + 1] = name
    end
end
if #names == 0 then
    print("listperf: no inventory peripheral visible from this computer.")
    return
end

--- 一台外设一个协程：**先把 list() 全部发出去**，再喂事件等它们回来
--- （阻塞只发生在协程里，所以整批调用落在同一个游戏刻 —— 这就是要测的并行度）
local startedAt = nowMs()
local tasks = {}
local failed = 0
for _, name in ipairs(names) do
    local inventory = peripheral.wrap(name)
    if inventory and type(inventory.list) == "function" then
        local task = { name = name }
        task.co = coroutine.create(function()
            local started = nowMs()
            local ok, listed = pcall(inventory.list)
            task.ok = ok
            task.cost = nowMs() - started
            task.count = 0
            if ok and type(listed) == "table" then
                for _ in pairs(listed) do
                    task.count = task.count + 1
                end
            end
        end)
        tasks[#tasks + 1] = task
    else
        failed = failed + 1                     -- 包装不出来 / 没有 list()
    end
end
for _, task in ipairs(tasks) do
    coroutine.resume(task.co)                   -- 启动 = 发起这次 list()
end

local ok, slots, slowestName, slowestCost = 0, 0, nil, 0
local pending = #tasks
while pending > 0 do
    local event, p1, p2, p3, p4, p5 = os.pullEvent()
    for i = #tasks, 1, -1 do
        local task = tasks[i]
        if coroutine.status(task.co) == "dead" then
            table.remove(tasks, i)
            pending = pending - 1
            if task.ok then
                ok = ok + 1
            else
                failed = failed + 1
            end
            slots = slots + (task.count or 0)
            if (task.cost or 0) > slowestCost then
                slowestName, slowestCost = task.name, task.cost
            end
        else
            coroutine.resume(task.co, event, p1, p2, p3, p4, p5)
        end
    end
end
local elapsed = nowMs() - startedAt

print("modem    : " .. tostring(modemSide or "?") .. (wired and " (wired)" or " (wireless)"))
print("scan     : " .. tostring(#names) .. " inventory peripheral(s)")
print("done     : " .. tostring(elapsed) .. " ms  (" .. tostring(ok) .. " ok, " ..
    tostring(failed) .. " failed, " .. tostring(slots) .. " slot(s))")
if slowestName then
    print("slowest  : " .. tostring(slowestName) .. " (" .. tostring(slowestCost) .. " ms)")
end
