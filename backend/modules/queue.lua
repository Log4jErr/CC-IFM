local Queue = {}
Queue.__index = Queue

local MIN_CAP = 8

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
        init_cap = MIN_CAP
    end
    return setmetatable({
        data = new_data(init_cap),
        head = 1,
        tail = 0,
        size = 0,
        cap = init_cap,
        min_cap = init_cap,
    }, Queue)
end

function Queue:push(value)
    local size, cap = self.size, self.cap
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
    self.data[head] = nil
    head = head + 1
    if head > self.cap then
        head = 1
    end
    self.head = head
    self.size = self.size - 1
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
