-- IFM :: modules/queue.lua
-- 环形数组队列（FIFO，动态扩容/缩容）：调度器的双队列用一个这样的队列表示"正在执行"那一半。
--
-- 为什么不用 `items[#items + 1]` + `head` 游标那种写法：`pop` 会把 `items[head]` 置 nil，
-- 而 Lua 里数组有空洞时 `#t` 是**未定义值** —— 以前 requeue 用 `#items + 1` 追加，队里只剩
-- 一条任务时会把任务写回 head 之前（等于任务"回队尾"之后凭空消失）。这里 head/tail/size
-- 三个游标全部显式维护，任何时刻都准确。
--
-- 用法（调度器）：active = 正在执行的队列（一轮里只出队）、waiting = 另一个队列
--   （重试的任务进这里，下一轮开始前再合并/交换回 active）—— 于是"一个任务一轮只执行一次"
--   不需要给每个任务打 tickId，也就没有"无意义的重试"。

local Queue = {}
Queue.__index = Queue

local MIN_CAP = 8

--- LuaJIT 有 table.new 可以预分配；标准 Lua（CC:T / 自测用的 fengari）自动退回 {}
local table_new = table and table.new or nil
local function new_data(n)
    if table_new then
        return table_new(n, 0)
    end
    return {}
end

function Queue.new(init_cap)
    init_cap = math.floor(tonumber(init_cap) or MIN_CAP)
    if init_cap < MIN_CAP then
        --- cap 必须 >= min_cap：否则 push 的扩容判断（size == cap）会先撞上 min_cap 的限制
        init_cap = MIN_CAP
    end
    return setmetatable({
        data = new_data(init_cap),
        head = 1,          -- 下一个出队位置
        tail = 0,          -- 最后一个入队位置
        size = 0,          -- 当前元素个数
        cap = init_cap,
        min_cap = init_cap,
    }, Queue)
end

function Queue:push(value)
    local size, cap = self.size, self.cap
    -- 满了就扩容为 2 倍
    if size == cap then
        self:resize(cap * 2)
        cap = self.cap
    end
    local tail = self.tail + 1
    if tail > cap then
        tail = 1
    end
    self.tail = tail
    self.data[tail] = value
    self.size = size + 1
    return value
end

function Queue:pop()
    if self.size == 0 then
        return nil
    end
    local head = self.head
    local value = self.data[head]
    self.data[head] = nil            -- 帮助 GC
    head = head + 1
    if head > self.cap then
        head = 1
    end
    self.head = head
    self.size = self.size - 1
    -- 缩容：元素很少时释放内存（1/4 阈值，避免频繁缩容）
    local cap = self.cap
    if self.size * 4 <= cap and cap > self.min_cap then
        self:resize(math.floor(cap / 2))
    end
    return value
end

function Queue:peek()
    if self.size == 0 then
        return nil
    end
    return self.data[self.head]
end

function Queue:resize(new_cap)
    new_cap = math.floor(tonumber(new_cap) or self.cap)
    if new_cap < self.min_cap then
        new_cap = self.min_cap
    end
    local old = self.data
    local old_head = self.head
    local old_cap = self.cap
    local size = self.size
    local new = new_data(new_cap)
    for i = 1, size do
        new[i] = old[old_head]
        old[old_head] = nil
        old_head = old_head + 1
        if old_head > old_cap then
            old_head = 1
        end
    end
    self.data = new
    self.head = 1
    self.tail = size
    self.cap = new_cap
end

function Queue:len()
    return self.size
end

function Queue:isEmpty()
    return self.size == 0
end

function Queue:clear()
    for i = 1, self.cap do
        self.data[i] = nil
    end
    self.head = 1
    self.tail = 0
    self.size = 0
end

--- 按顺序遍历（pred 返回 true 时停止）；用于找任务 / 统计
function Queue:any(pred)
    local head = self.head
    for i = 1, self.size do
        if pred(self.data[head]) then
            return true
        end
        head = head + 1
        if head > self.cap then
            head = 1
        end
    end
    return false
end

--- 复制成普通数组（诊断 / 测试用；顺序 = 出队顺序）
function Queue:toArray()
    local out = {}
    local head = self.head
    for i = 1, self.size do
        out[i] = self.data[head]
        head = head + 1
        if head > self.cap then
            head = 1
        end
    end
    return out
end

--- 删除所有满足 pred 的元素（返回删除条数）。调度器用它做"外设被移除 → 从队列里撤掉它的任务"。
function Queue:removeWhere(pred)
    if self.size == 0 then
        return 0
    end
    local removed = 0
    local kept = new_data(self.cap)
    local index = 0
    local head = self.head
    for i = 1, self.size do
        local value = self.data[head]
        head = head + 1
        if head > self.cap then
            head = 1
        end
        if pred(value) then
            removed = removed + 1
        else
            index = index + 1
            kept[index] = value
        end
    end
    self.data = kept
    self.head = 1
    self.tail = index
    self.size = index
    return removed
end

--- 把另一个队列的所有元素按顺序搬到本队列尾部（并清空它）。返回搬了多少条。
--- 调度器在每个 tick 开始前用它把 waiting 并回 active（用户第 4 项的双队列）。
function Queue:append(other)
    if other == nil or other.size == 0 then
        return 0
    end
    local moved = 0
    local head = other.head
    local cap = other.cap
    for i = 1, other.size do
        self:push(other.data[head])
        head = head + 1
        if head > cap then
            head = 1
        end
        moved = moved + 1
    end
    other:clear()
    return moved
end

return Queue
