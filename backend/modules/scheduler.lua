-- IFM :: modules/scheduler.lua
-- 轻量非阻塞调度器：一次性延时任务 / 周期任务 / 可取消。
-- 所有等待都以绝对时间（os.epoch("utc") 毫秒）记录，因此可以随 cache.json 一起持久化。

local Scheduler = {}
Scheduler.__index = Scheduler

--- 任务报错时的打印节流：同一秒内反复失败也不会刷屏（终端只打印、不写文件）
local PRINT_COOLDOWN_MS = 5000
local lastErrorPrint = 0

function Scheduler.new()
    local self = setmetatable({}, Scheduler)
    self.tasks = {}
    self.seq = 0
    return self
end

--- 延时执行一次（返回任务 id）
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

--- 周期执行（返回任务 id）
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

--- 取消任务
function Scheduler:cancel(id)
    if id then
        self.tasks[id] = nil
    end
end

--- 推进调度器
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
        local ok, err = pcall(task.fn)
        if not ok then
            -- 节流：任务每 tick 都失败时，最多 5 秒打一行（终端输出不写盘，但仍避免刷屏）
            if now - lastErrorPrint >= PRINT_COOLDOWN_MS then
                lastErrorPrint = now
                print("[IFM] scheduler task error: " .. tostring(err))
            end
        end
        executed = executed + 1
    end
    return executed
end

return Scheduler
