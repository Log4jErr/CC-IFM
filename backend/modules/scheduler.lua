local Scheduler = {}
Scheduler.__index = Scheduler

function Scheduler.new()
    local self = setmetatable({}, Scheduler)
    self.tasks = {}
    self.seq = 0
    return self
end

function Scheduler:after(seconds, fn)
    self.seq = self.seq + 1
    local id = self.seq
    self.tasks[id] = {
        id = id,
        at = os.epoch("utc") + math.floor((tonumber(seconds) or 0) * 1000),
        fn = fn,
    }
    return id
end

function Scheduler:every(seconds, fn)
    self.seq = self.seq + 1
    local id = self.seq
    local interval = math.max(50, math.floor((tonumber(seconds) or 1) * 1000))
    self.tasks[id] = {
        id = id,
        at = os.epoch("utc") + interval,
        everyMs = interval,
        fn = fn,
    }
    return id
end

function Scheduler:cancel(id)
    if id then
        self.tasks[id] = nil
    end
end

function Scheduler:tick(now)
    now = now or os.epoch("utc")
    local due = {}
    for _, task in pairs(self.tasks) do
        if task.at <= now then
            due[#due + 1] = task
        end
    end
    if #due == 0 then
        return 0
    end
    table.sort(due, function(a, b)
        return a.at < b.at
    end)
    local executed = 0
    for _, task in ipairs(due) do
        if task.everyMs then
            task.at = now + task.everyMs
        else
            self.tasks[task.id] = nil
        end
        task.fn()
        executed = executed + 1
    end
    return executed
end

return Scheduler
