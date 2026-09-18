-- ============================================================
-- crafter.lua -- IFM 配套脚本：装在机械臂（海龟，turtle）上的自动合成脚本
--
-- 运行方式：把本文件拖到机械臂上（或粘贴进去），运行 crafter.lua
--
-- 事件：等待 redstone 事件；任一监听面的信号达到阈值（上升沿）时执行一轮合成。
--
-- 一轮合成的流程：
--   1. 读取顶部容器内的全部物品（按容器槽位号排序）；
--   2. 把容器内的物品全部吸入机械臂自身物品栏（从槽位 1 开始接收）；
--   3. 按容器槽位顺序把物品摆放到机械臂的 3x3 合成栏（容器槽位 1..9 分别对应
--      物品栏槽位 1/2/3、5/6/7、9/10/11，与 little_projects/craft.lua 的映射一致）；
--      容器槽位为空则对应合成栏槽位留空；
--   4. 触发一次合成（turtle.craft(1)）；
--   5. 把物品栏里剩下的东西（合成产物 + 多余材料）丢弃到下方。
--
-- 关键点（CC:Tweaked 的 craft 实现）：
--   * 3x3 合成栏之外的槽位必须为空，否则会报 "No matching recipes"；
--   * 合成产物需要有空槽位存放，否则会被丢到下方。
--   因此本脚本在合成前会清空合成栏之外的槽位，多余的物品从 EXTRA_SIDE 处理
--   （默认丢到下方）。
--
-- 终端输出不得为中文（CC:T 的终端字形不含中文字形），所以 print 一律用 ASCII 英文。
--
-- 本文件是独立部署到机械臂上的脚本，不参与 build.py 的分发文件打包
-- （build.py 只打包 IFMMaster.lua / IFMWorker.lua 与 ifm/*.lua，crafter.lua 不会被打包）。
-- ============================================================


-- ============================================================
-- 常量
-- ============================================================
-- 逻辑 3x3 位置（1..9）-> 机械臂 3x3 合成栏槽位
--   [1] [2] [3]      [1] [2] [3]
--   [4] [5] [6]  ==> [5] [6] [7]
--   [7] [8] [9]      [9] [10] [11]
local SRC_TO_DST = {
    [1] = 1, [2] = 2, [3] = 3,
    [4] = 5, [5] = 6, [6] = 7,
    [7] = 9, [8] = 10, [9] = 11,
}

-- 3x3 合成栏槽位（按逻辑位置顺序）
local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

-- 合成栏之外的槽位：作腾挪暂存用，合成产物也会存放在这里
local FREE_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }

-- ===== 可调参数 =====
-- 物品容器放在顶部（机械臂顶面）
local INPUT_SIDE = "top"
-- 产物与剩余的丢弃方向（下方）
local DROP_SIDE = "down"
-- 不与本次合成的多余物品的去向："down" 丢到下方容器 / "up" 送回上方容器
local EXTRA_SIDE = "down"

-- 布局模式（把容器内物品对应到 3x3 合成栏的方式）：
--   "slot"（默认）：容器槽位 1..9 分别对应逻辑位置 1..9，
--                   即容器槽位 1/2/3/4/5/6/7/8/9 -> 物品栏槽位 1/2/3/5/6/7/9/10/11，
--                   容器槽位为空时，对应合成栏槽位保持为空，不跳过容器内的摆放顺序；
--   "order"：忽略容器槽位号，按容器内物品出现的先后顺序依次填入逻辑位置 1..9
local LAYOUT_MODE = "slot"

-- 每次触发的合成次数（turtle.craft 的 limit 参数，1 = 只合成一次）
local CRAFT_LIMIT = 1

-- 监听的信号面，可只听一个面，例如 { "back" }
local SIGNAL_SIDES = { "front", "back", "left", "right", "top", "bottom" }

-- 触发阈值，模拟信号强度 0..15，默认 1，即只要有信号就触发
local SIGNAL_THRESHOLD = 1

-- 逻辑位置数（3x3）
local MAX_POSITIONS = 9

-- 防御性上限：吸入轮数 / 摆放步数 / 丢弃重试次数上限
local MAX_SUCK_ROUNDS = 32
local MAX_ARRANGE_STEPS = 64
local DROP_ATTEMPTS = 5
local DROP_RETRY_DELAY = 0.5


-- ============================================================
-- 基础工具
-- ============================================================
--- 物品栏是否有物品
local function hasItems()
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            return true
        end
    end
    return false
end

--- 读取机械臂物品栏（names[slot] = 物品名，空槽为 nil；counts[slot] = 数量）
local function readInventory()
    local names, counts = {}, {}
    for slot = 1, 16 do
        local detail = turtle.getItemDetail(slot)
        names[slot] = detail and detail.name or nil
        counts[slot] = detail and detail.count or 0
    end
    return names, counts
end

--- 读 INPUT_SIDE 面的物品容器
--- 返回：按槽位号排序的槽位表（list() 的结果，键为槽位号）、物品表、错误信息（失败时给出）
local function readContainer()
    local wrapped, container = pcall(peripheral.wrap, INPUT_SIDE)
    if not wrapped or not container then
        return nil, nil, "no peripheral on the " .. INPUT_SIDE .. " side"
    end
    if type(container.list) ~= "function" then
        return nil, nil, "the peripheral on the " .. INPUT_SIDE .. " side is not an inventory"
    end
    local listed, items = pcall(container.list)
    if not listed then
        return nil, nil, "list() failed: " .. tostring(items)
    end
    if type(items) ~= "table" then
        return nil, nil, "list() returned " .. type(items)
    end
    local order = {}
    for slot in pairs(items) do
        if type(slot) == "number" then
            order[#order + 1] = slot
        end
    end
    table.sort(order)
    return order, items, nil
end

--- 依据容器内容计算目标布局
--- 返回：target[合成栏槽位] = 物品名（nil 表示该槽位应当为空）；positions[逻辑位置] = 物品名
local function buildTarget(order, items)
    local positions = {}
    for position = 1, MAX_POSITIONS do
        if LAYOUT_MODE == "slot" then
            -- 容器槽位即逻辑栏位：槽位 1..9 直接对应逻辑位置 1..9
            local detail = items[position]
            positions[position] = detail and detail.name or nil
        else
            -- 容器内第 i 个物品（按槽位号排序）对应逻辑位置 i
            local slot = order[position]
            positions[position] = slot and items[slot].name or nil
        end
    end
    local target = {}
    for position = 1, MAX_POSITIONS do
        target[SRC_TO_DST[position]] = positions[position]
    end
    return target, positions
end

--- 按逻辑位置列表打印成一行便于终端查看，空位置显示为 -
local function planText(positions)
    local parts = {}
    for position = 1, MAX_POSITIONS do
        parts[position] = positions[position] or "-"
    end
    return table.concat(parts, ", ")
end

--- 把某个槽位里的东西全部丢到指定方向（"up" / "down"）
--- dropUp/dropDown 一次最多丢 64 个（容器满时丢不下去），所以要循环；
--- 连续失败 DROP_ATTEMPTS 次后放弃，返回 false，避免容器满时卡死循环。
local function dropStack(slot, side)
    local failed = 0
    while turtle.getItemCount(slot) > 0 do
        turtle.select(slot)
        local ok
        if side == "up" then
            ok = turtle.dropUp()
        else
            ok = turtle.dropDown()
        end
        if ok then
            failed = 0
        else
            failed = failed + 1
            if failed >= DROP_ATTEMPTS then
                return false
            end
            sleep(DROP_RETRY_DELAY)
        end
    end
    return true
end

--- 把 INPUT_SIDE 容器内的物品全部吸入物品栏
--- 吸入前先选中槽位 1：容器 -> 机械臂的搬运会以该槽位为起点，物品依次堆在 1、2、3 ……
--- 返回：吸入的轮数（turtle.suckUp 失败即停止：容器已空或物品栏已满）
local function suckAll()
    local stacks = 0
    turtle.select(1)
    for _ = 1, MAX_SUCK_ROUNDS do
        local ok = turtle.suckUp()
        if not ok then
            break
        end
        stacks = stacks + 1
    end
    return stacks
end

-- ============================================================
-- 摆放：把物品栏里的物品按目标布局排进 3x3 合成栏
-- ============================================================
--- 按目标布局摆放物品栏
--- 返回 true；失败返回 false, 原因
--- 算法与 little_projects/craft.lua 的贪心摆放一致，并做了两点折衷：
---   * 合成栏槽位以外的物品不参与轮换判定（合成前会统一清空）；
---   * 同一物品被吸入时可能并成一叠，可以从已装好的槽位里再分出 1 个补到仍为空的槽位。
local function arrange(target)
    local current = readInventory()
    local needed, inGrid = {}, {}
    for _, slot in ipairs(GRID_SLOTS) do
        inGrid[slot] = true
        if target[slot] ~= nil then
            needed[target[slot]] = true
        end
    end

    --- 合成栏是否已经完全就位（合成栏之外的槽位不参与判定）
    local function gridReady()
        for _, slot in ipairs(GRID_SLOTS) do
            if current[slot] ~= target[slot] then
                return false
            end
        end
        return true
    end

    --- 找一个可腾挪的槽位作为摆放缓冲（优先合成栏之外的空槽位；
    --- 没有空槽位时，退回已经在合成栏内、且位置不对的那一叠）
    local function findParkCandidate(preferSpare)
        for slot = 1, 16 do
            local name = current[slot]
            if name ~= nil and name ~= target[slot] and (needed[name] or inGrid[slot]) then
                local isSpare = inGrid[slot] == nil
                if isSpare == preferSpare then
                    return slot, name
                end
            end
        end
        return nil, nil
    end

    for _ = 1, MAX_ARRANGE_STEPS do
        if gridReady() then
            return true
        end
        local moved = false

        -- A) 用已有的整叠补上空的目标槽位
        for _, dst in ipairs(GRID_SLOTS) do
            local need = target[dst]
            if need ~= nil and current[dst] == nil then
                for src = 1, 16 do
                    if src ~= dst and current[src] == need and target[src] ~= need then
                        turtle.select(src)
                        if turtle.transferTo(dst) then
                            current[dst] = need
                            current[src] = nil
                            moved = true
                            break
                        end
                    end
                end
            end
            if moved then break end
        end

        -- B) 同一物品需要多个位置时，从已装好的槽位里分出 1 个补到仍为空的槽位
        if not moved then
            for _, dst in ipairs(GRID_SLOTS) do
                local need = target[dst]
                if need ~= nil and current[dst] == nil then
                    for src = 1, 16 do
                        if src ~= dst and current[src] == need and target[src] == need
                            and turtle.getItemCount(src) > 1 then
                            turtle.select(src)
                            if turtle.transferTo(dst, 1) then
                                current[dst] = need
                                moved = true
                                break
                            end
                        end
                    end
                end
                if moved then break end
            end
        end

        -- C) 还摆不下去：把可腾挪的那一叠先挪到空闲的合成栏外槽位，打破循环 / 腾出合成栏
        if not moved then
            for _, preferSpare in ipairs({ false, true }) do
                local slot, name = findParkCandidate(preferSpare)
                if slot ~= nil then
                    for _, spare in ipairs(FREE_SLOTS) do
                        if current[spare] == nil then
                            turtle.select(slot)
                            if turtle.transferTo(spare) then
                                current[spare] = name
                                current[slot] = nil
                                moved = true
                                break
                            end
                        end
                    end
                    -- 合成栏内不该留、又实在没有空闲槽位时，直接丢走
                    if not moved and inGrid[slot] and not needed[name] then
                        if dropStack(slot, EXTRA_SIDE) then
                            current[slot] = nil
                            moved = true
                        end
                    end
                end
                if moved then break end
            end
        end

        if not moved then
            return false, "cannot resolve the layout (no movable stack / no free spare slot)"
        end
    end
    return false, "layout still incomplete after " .. MAX_ARRANGE_STEPS .. " steps"
end

--- 清空合成栏之外的槽位：CC:T 的 craft 要求它们为空，合成产物也需要空槽位存放；
--- 这些物品不参与本次合成，按 EXTRA_SIDE 处理（默认丢到下方）
local function clearOutsideGrid()
    local failed = 0
    for _, slot in ipairs(FREE_SLOTS) do
        while turtle.getItemCount(slot) > 0 do
            if dropStack(slot, EXTRA_SIDE) then
                failed = 0
            else
                failed = failed + 1
                if failed >= DROP_ATTEMPTS then
                    return false, "cannot drop the extra items in slot " .. slot
                end
                sleep(DROP_RETRY_DELAY)
            end
        end
    end
    return true, nil
end


-- ============================================================
-- 合成与丢弃
-- ============================================================
--- 合成一次（先 craft(0) 探测配方是否存在，再 craft(CRAFT_LIMIT)，默认只合 1 次）
--- 注意：不带参数的 turtle.craft() 会连续合成最多 64 次，这里固定只合 CRAFT_LIMIT 次
local function craftOnce()
    local probe, reason = turtle.craft(0)
    if not probe then
        return false, "no matching recipe (" .. tostring(reason) .. ")"
    end
    -- 合成产物会从当前选中的槽位开始寻找存放位置：先选一个空的合成栏外槽位，
    -- 避免产物直接被丢到下方
    for _, slot in ipairs(FREE_SLOTS) do
        if turtle.getItemCount(slot) == 0 then
            turtle.select(slot)
            break
        end
    end
    local ok, err = turtle.craft(CRAFT_LIMIT)
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

--- 把物品栏里所有东西（合成产物 + 剩余材料）全部丢到 DROP_SIDE（默认下方）
--- 返回是否全部丢完；丢不完时会留在物品栏里，下一轮开始时会被再试一次
local function dropEverything()
    local failed = 0
    for slot = 1, 16 do
        while turtle.getItemCount(slot) > 0 do
            if dropStack(slot, DROP_SIDE) then
                failed = 0
            else
                failed = failed + 1
                print("[CRAFTER] warning: cannot drop slot " .. slot .. " to the " .. DROP_SIDE)
                if failed >= DROP_ATTEMPTS then
                    return false
                end
                sleep(DROP_RETRY_DELAY)
            end
        end
    end
    return true
end

-- ============================================================
-- 一轮合成
-- ============================================================
local function runCycle()
    -- 0) 上一轮如果没丢干净，先清空物品栏，保证本轮从干净状态开始
    if hasItems() then
        print("[CRAFTER] warning: the inventory is not empty, dropping the leftovers first")
        dropEverything()
    end

    -- 1) 读取顶部物品容器内的所有物品（按槽位号排序）
    local order, items, reason = readContainer()
    if not order then
        print("[CRAFTER] cannot read the " .. INPUT_SIDE .. " container: " .. tostring(reason))
        return
    end
    if #order == 0 then
        print("[CRAFTER] the " .. INPUT_SIDE .. " container is empty, nothing to craft")
        return
    end

    -- 2) 计算目标布局（容器内物品顺序 -> 逻辑 3x3 -> 合成栏槽位）
    local target, positions = buildTarget(order, items)
    print("[CRAFTER] input: " .. #order .. " stack(s) on the " .. INPUT_SIDE)
    print("[CRAFTER] plan : " .. planText(positions))

    -- 3) 把容器内的物品全部吸入物品栏
    local rounds = suckAll()
    local _, counts = readInventory()
    local held = 0
    for slot = 1, 16 do
        if counts[slot] > 0 then
            held = held + 1
        end
    end
    print("[CRAFTER] suck rounds: " .. rounds .. ", stacks in inventory: " .. held)
    local remaining = readContainer()
    if remaining and #remaining > 0 then
        print("[CRAFTER] warning: " .. #remaining .. " stack(s) left in the container (inventory full?)")
    end

    -- 4) 摆放到合成栏
    local placed, arrangeReason = arrange(target)
    if not placed then
        print("[CRAFTER] layout failed: " .. tostring(arrangeReason))
        print("[CRAFTER] giving up this cycle, dropping everything to the " .. DROP_SIDE)
        dropEverything()
        return
    end
    print("[CRAFTER] layout: OK")

    -- 5) 清空合成栏之外的槽位（合成前检查）
    local cleared, clearReason = clearOutsideGrid()
    if not cleared then
        print("[CRAFTER] cannot clear the slots outside the grid: " .. tostring(clearReason))
        dropEverything()
        return
    end

    -- 6) 合成一次
    local crafted, craftReason = craftOnce()
    if crafted then
        print("[CRAFTER] craft: SUCCESS")
    else
        print("[CRAFTER] craft: FAILED - " .. tostring(craftReason))
    end

    -- 7) 产物与剩余材料全部丢到下方
    if not dropEverything() then
        print("[CRAFTER] warning: some items are still in the inventory")
    end
    print("[CRAFTER] cycle done")
end


-- ============================================================
-- 红石信号
-- ============================================================
--- 监听面的最大模拟信号强度（0..15）
local function readSignal()
    local level = 0
    for _, side in ipairs(SIGNAL_SIDES) do
        local value = redstone.getAnalogInput(side)
        if value and value > level then
            level = value
        end
    end
    return level
end

--- 等待触发（上升沿）：信号达到阈值即返回
local function waitForSignal()
    while true do
        os.pullEvent("redstone")
        if readSignal() >= SIGNAL_THRESHOLD then
            return readSignal()
        end
    end
end

--- 等信号落下，避免一次持续的高电平被重复触发
local function waitForRelease()
    while readSignal() >= SIGNAL_THRESHOLD do
        os.pullEvent("redstone")
    end
end


-- ============================================================
-- 主循环
-- ============================================================
print("IFM crafter (turtle) started")
print("  input container : " .. INPUT_SIDE .. " side")
print("  layout mode     : " .. LAYOUT_MODE)
print("  drop / extras   : " .. DROP_SIDE .. " / " .. EXTRA_SIDE)
print("  craft steps     : " .. CRAFT_LIMIT)
print("  waiting for a redstone signal (threshold " .. SIGNAL_THRESHOLD .. ") ...")

while true do
    -- 等待红石信号（上升沿）后执行一轮合成
    local level = waitForSignal()
    print("[CRAFTER] redstone signal detected (level " .. level .. "), starting a cycle")
    local ok, err = pcall(runCycle)
    if not ok then
        print("[CRAFTER] cycle aborted: " .. tostring(err))
    end
    -- 等信号落下后再继续监听
    print("[CRAFTER] waiting for the signal to go low ...")
    waitForRelease()
end
