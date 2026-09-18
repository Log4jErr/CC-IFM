-- IFM :: ifm/cache.lua
-- 运行态数据（cache.json）：流程运行状态、机器占用、机器类型轮换位置、
-- 待交付（待发送）队列、红石输出状态。全部持久化，用于服务器重启后完整恢复。

local Cache = {}
Cache.__index = Cache

function Cache.emptyData()
    return {
        version = 1,
        processes = {},
        machines = {},
        machineTypes = {},
        deliveries = {},
        signals = {},
        tags = {},
        deliverySeq = 0,
        savedAt = 0,
    }
end

function Cache.defaultProc()
    return {
        state = "idle",
        phase = "input",
        index = 1,
        batch = 0,
        userCount = 0,
        downstreamCount = 0,
        progress = {},
        outProgress = {},
        requests = {},
        machine = nil,
        wait = nil,
        lastError = nil,
        startedAt = 0,
        checkedAt = 0,
        lastFinishedAt = 0,
        baseline = {},
        target = {},
    }
end

function Cache.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Cache)
    self.Util = opts.Util
    --- 落盘统一交给 ifm/jsonfile.lua（读 / 原子写 / 去抖都在那边）
    local JsonFile = opts.JsonFile
    if not JsonFile then
        error("cache.lua needs the jsonfile module: pass opts.JsonFile (loadModule(\"jsonfile\"))", 0)
    end
    self.file = JsonFile.new({
        path = opts.path or "/ifm/cache.json",
        log = opts.log,
        writeDebounce = opts.writeDebounce,
    })
    self.data = Cache.emptyData()
    return self
end

function Cache:load()
    local parsed, why = self.file:read("cache.json")
    if not parsed then
        self.data = Cache.emptyData()
        return false, why
    end
    local data = Cache.emptyData()
    for name, record in pairs(type(parsed.processes) == "table" and parsed.processes or {}) do
        if type(record) == "table" then
            local merged = Cache.defaultProc()
            for k, v in pairs(record) do
                merged[k] = v
            end
            data.processes[name] = merged
        end
    end
    for name, record in pairs(type(parsed.machines) == "table" and parsed.machines or {}) do
        if type(record) == "table" then
            data.machines[name] = { running = math.max(0, tonumber(record.running) or 0) }
        end
    end
    for name, record in pairs(type(parsed.machineTypes) == "table" and parsed.machineTypes or {}) do
        if type(record) == "table" then
            data.machineTypes[name] = { rrIndex = math.max(0, tonumber(record.rrIndex) or 0) }
        end
    end
    for _, entry in ipairs(type(parsed.deliveries) == "table" and parsed.deliveries or {}) do
        if type(entry) == "table" and entry.kind and entry.id then
            data.deliveries[#data.deliveries + 1] = entry
        end
    end
    for key, entry in pairs(type(parsed.signals) == "table" and parsed.signals or {}) do
        if type(entry) == "table" then
            data.signals[key] = entry
        end
    end
    for key, entry in pairs(type(parsed.tags) == "table" and parsed.tags or {}) do
        if type(entry) == "table" then
            data.tags[key] = entry
        end
    end
    data.deliverySeq = math.max(0, tonumber(parsed.deliverySeq) or #data.deliveries)
    data.savedAt = tonumber(parsed.savedAt) or 0
    self.data = data
    return true
end

function Cache:markDirty()
    self.file:markDirty()
    --- 状态变更计数（1.6.12）：网页推送用它判断“有没有新东西要推”
    --- —— 有变化就立刻推，不做时间上的硬速率限制（用户第 7 项要求）
    self.revision = (self.revision or 0) + 1
end

--- 去抖写盘（由主循环按 tick 调用）
function Cache:tick(now)
    if not self.file:shouldFlush(now) then
        return false
    end
    return self:flush()
end

--- 立即写盘（顺便记下“最后一次保存时间”，网页的运行时状态里会显示）
function Cache:flush()
    self.data.savedAt = os.epoch("utc")
    return self.file:flush(self.data)
end

--- 取（或创建）流程运行记录
--- 注意：脏标记一律走 self:markDirty()（它转发到 ifm/jsonfile.lua）；直接写 self.dirty 是**无效**的。
function Cache:proc(name)
    local record = self.data.processes[name]
    if not record then
        record = Cache.defaultProc()
        self.data.processes[name] = record
        self:markDirty()
    end
    return record
end

function Cache:machine(name)
    local record = self.data.machines[name]
    if not record then
        record = { running = 0 }
        self.data.machines[name] = record
        self:markDirty()
    end
    return record
end

function Cache:machineType(typeName)
    local record = self.data.machineTypes[typeName]
    if not record then
        record = { rrIndex = 0 }
        self.data.machineTypes[typeName] = record
        self:markDirty()
    end
    return record
end

function Cache:addDelivery(entry)
    self.data.deliverySeq = (self.data.deliverySeq or 0) + 1
    entry.id = self.data.deliverySeq
    self.data.deliveries[#self.data.deliveries + 1] = entry
    self:markDirty()
    return entry
end

function Cache:removeDelivery(id)
    for i, entry in ipairs(self.data.deliveries) do
        if entry.id == id then
            table.remove(self.data.deliveries, i)
            self:markDirty()
            return true
        end
    end
    return false
end

function Cache:deliveries()
    return self.data.deliveries
end

--- 记录红石输出（供重启后恢复）
function Cache:setSignalOutput(key, entry)
    self.data.signals[key] = entry
    self:markDirty()
end

function Cache:clearSignalOutput(key)
    if self.data.signals[key] ~= nil then
        self.data.signals[key] = nil
        self:markDirty()
    end
end

function Cache:signalOutputs()
    return self.data.signals
end

--- 标签缓存：只在用户按需触发扫描时才调用 getItemDetail，结果持久化，热路径不查详情
function Cache:tags()
    return self.data.tags
end

function Cache:tagsOf(name)
    return self.data.tags[name]
end

--- 标签缓存里是否已经有这个物品（有就绝不再调用 getItemDetail）
function Cache:hasTags(name)
    return self.data.tags[name] ~= nil
end

function Cache:setTags(name, tags)
    self.data.tags[name] = tags or {}
    self:markDirty()
end

--- 只保留「当前存储里还有的」物品标签：NBT 变体无限多（工具耐久 / 附魔 / 自定义数据各不相同），
--- 临时流转的物品如果把标签留在缓存里，cache.json 会被越写越大（CC:T 磁盘很小），
--- 而且这些标签对界面与过滤规则毫无用处（它们只对**当前存在**的资源求值）。
--- present = { [物品名] = true }，由调用方在扫描容器时顺手收集；不在里面的条目一律删掉。
--- 返回被删掉的条数（调用方据此决定要不要打日志）。
function Cache:pruneTags(present)
    local removed = 0
    for name in pairs(self.data.tags) do
        if not (present and present[name]) then
            self.data.tags[name] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then
        -- 注意：脏标记在 ifm/jsonfile.lua 那边（Cache 自己不再持有 dirty 字段）
        self.file:markDirty()
    end
    return removed
end

function Cache:clearTags()
    self.data.tags = {}
    self:markDirty()
end

return Cache
