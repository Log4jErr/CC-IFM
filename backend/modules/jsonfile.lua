-- IFM :: modules/jsonfile.lua
-- 磁盘读写（config.json / cache.json 共用）：读 JSON、原子写、去抖写盘。
--
-- 为什么单独一个模块：Cache 与 Store 以前各写了一份几乎逐行相同的「读 → 解析 → 临时文件 → 删旧 → 改名」
-- 和一套一模一样的去抖逻辑，修一处（例如掉电时的原子写）要改两遍。
-- 现在两边只保留自己的**数据模型**，落盘统一走这里。
--
-- 用法（数据表始终由调用方持有，本模块只管“怎么把这坨数据安全地写下去”）：
--   local file = JsonFile.new({ path = configPath, log = log, writeDebounce = 3 })
--   local parsed, why = file:read("config.json")   -- 失败时 why 是一行原因（可直接进日志）
--   file:markDirty()                               -- 数据改了
--   if file:shouldFlush(now) then ... end          -- 主循环里问“到写盘点了吗”
--   file:flush(data)                               -- 立即原子写（不看去抖窗口）

local JsonFile = {}
JsonFile.__index = JsonFile

--- 去抖写盘的缺省间隔（秒）：写盘是慢操作，连续改动攒一会儿再写一次
JsonFile.DEFAULT_DEBOUNCE = 3

function JsonFile.new(opts)
    opts = opts or {}
    local self = setmetatable({}, JsonFile)
    self.path = opts.path or ""
    self.log = opts.log or function() end
    self.writeDebounce = tonumber(opts.writeDebounce) or JsonFile.DEFAULT_DEBOUNCE
    self.dirty = false
    self.lastWrite = 0
    return self
end

--- 读并解析 JSON。返回：表 或 nil + 原因。
--- 原因里的中文按 IFM 约定写成 \\uXXXX（浏览器端还原显示，CC:T 终端只认 ASCII）。
function JsonFile:read(label)
    label = label or tostring(self.path)
    if not fs.exists(self.path) then
        return nil, label .. " \\u4E0D\\u5B58\\u5728"
    end
    local handle = fs.open(self.path, "r")
    if not handle then
        return nil, "\\u65E0\\u6CD5\\u6253\\u5F00 " .. tostring(self.path)
    end
    local raw = handle.readAll()
    handle.close()
    local ok, parsed = pcall(textutils.unserializeJSON, raw)
    if not ok or type(parsed) ~= "table" then
        return nil, label .. " \\u89E3\\u6790\\u5931\\u8D25"
    end
    return parsed
end

--- 原子写：先写 .tmp，再删旧文件、改名。
--- 直接覆盖原文件时，一旦中途掉电/崩溃就会留下半个 JSON（下次启动读不出来 → 定义全丢）。
function JsonFile:write(data)
    local tmp = self.path .. ".tmp"
    local handle = fs.open(tmp, "w")
    if not handle then
        self.log("Failed to write %s (cannot open temp file)", tmp)
        return false
    end
    handle.write(textutils.serializeJSON(data, { allow_repetitions = true }))
    handle.close()
    if fs.exists(self.path) then
        fs.delete(self.path)
    end
    fs.move(tmp, self.path)
    return true
end

--- 数据变了
function JsonFile:markDirty()
    self.dirty = true
end

--- 到写盘点了吗：有改动、且距上次写盘已经过了去抖窗口
function JsonFile:shouldFlush(now)
    if not self.dirty then
        return false
    end
    now = now or os.epoch("utc")
    return now - self.lastWrite >= self.writeDebounce * 1000
end

--- 立即写盘（成功才清脏、才更新 lastWrite；失败时保持脏，下个 tick 会再试）
function JsonFile:flush(data)
    if not self:write(data) then
        return false
    end
    self.dirty = false
    self.lastWrite = os.epoch("utc")
    return true
end

return JsonFile
