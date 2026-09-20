-- IFM (Integrated Factory Manager) :: modules/util.lua
-- 通用工具模块。除 CC:Tweaked 自带 API 外无外部依赖。
-- 加载方式：local Util = loadModule("util")

local M = {}

--- 深拷贝（支持循环引用与表键）
function M.deepcopy(value, seen)
    if type(value) ~= "table" then
        return value
    end
    seen = seen or {}
    if seen[value] then
        return seen[value]
    end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do
        copy[M.deepcopy(k, seen)] = M.deepcopy(v, seen)
    end
    return copy
end

--- 当前 UTC 毫秒时间戳（重启后仍可用来比较绝对时间）
function M.now()
    return os.epoch("utc")
end

--- 限制数值范围
function M.clamp(v, lo, hi)
    v = tonumber(v) or 0
    if v < lo then
        return lo
    end
    if v > hi then
        return hi
    end
    return v
end

--- 转数值（带默认值）
function M.num(v, default)
    v = tonumber(v)
    if v == nil then
        return default
    end
    return v
end

--- 转整数（带默认值）
function M.int(v, default)
    v = tonumber(v)
    if v == nil then
        return default
    end
    return math.floor(v)
end

--- 去除首尾空白
function M.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- 容器 / 资源定义的种类归一：只认 item 与 fluid。
--- 参数可以是“带 kind 字段的表”（容器定义、网页请求 payload…），也可以直接是 "item"/"fluid" 字符串；
--- 其它情况（nil、未知值）一律按 item 处理 —— 这正是旧配置（没有 kind 字段）的语义。
--- 这段判断以前散落在 5 个文件、重复了 17 次，现在这里是唯一实现。
function M.kindOfDef(def)
    local kind = type(def) == "table" and def.kind or def
    return kind == "fluid" and "fluid" or "item"
end

--- 表元素个数（数组或字典）
function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

--- ===== 日志 =====
--- CC:T 计算机磁盘有限，日志不写文件、也不刷屏终端：只保存最近若干条在内存环形缓冲里，
--- 由 modules/protocol.lua 推送给网页（浏览器在控制台里打印）。
local LOG_LIMIT = 200
local logBuffer = {}
local logSeq = 0
local logHandler = nil

--- 设置日志接收者（例如 protocol:onLog）；传 nil 取消
function M.setLogHandler(fn)
    logHandler = fn
end

--- ===== 日志分级（用户第 2 项）=====
--- 三个级别：info（默认）/ warn / error，**由调用点显式指定**（`log.warn(...)` / `log.error(...)`）。
--- 行首带标记（`[IFM] [warn] ...`）：终端与网页都能一眼看出等级，网页端按标记上色；
--- 后端终端另外用 CC:T 的颜色区分（见 IFMMaster.lua 的日志接收者）。
--- 注意：这里**不做关键字猜测**（用户第 2 项：不按关键字分级，级别要由调用点慢慢改）——
--- 没写级别的就是 info。
M.LOG_TAGS = { info = nil, warn = "[warn] ", error = "[error] " }

--- 终端颜色（CC:T 没有 colors 时返回 nil：fengari 测试环境就没有）
function M.logColour(level)
    if type(colors) ~= "table" then
        return nil
    end
    if level == "error" then
        return colors.red
    end
    if level == "warn" then
        return colors.yellow
    end
    return nil
end

--- 追加一条日志（内部使用）：level = "info" | "warn" | "error"（缺省 info，不做内容猜测）
function M.pushLog(prefix, text, level)
    level = M.LOG_TAGS[level] and level or "info"
    logSeq = logSeq + 1
    local tag = M.LOG_TAGS[level]
    local body = tag and (tag .. tostring(text)) or tostring(text)
    local line = "[" .. (prefix or "IFM") .. "] " .. body
    logBuffer[#logBuffer + 1] = { seq = logSeq, line = line }
    while #logBuffer > LOG_LIMIT do
        table.remove(logBuffer, 1)
    end
    if logHandler then
        pcall(logHandler, line, logSeq, level)
    end
end

--- 取 seq 之后的日志；同时返回当前最后一条的 seq（网页刚接入时用来补发历史）
function M.logSince(seq)
    local from = tonumber(seq) or 0
    local out = {}
    for _, entry in ipairs(logBuffer) do
        if entry.seq > from then
            out[#out + 1] = entry.line
        end
    end
    return out, logSeq
end

--- 构造日志函数（只进内存缓冲，由网页端在控制台输出）
--- 级别接口（用户第 2 项）：logger(fmt, ...) = 信息；logger.warn(...) = 警告；logger.error(...) = 错误
--- 为什么返回的是"可调用的表"而不是函数：Lua 里**函数既不能挂字段、也不能设元表**
--- （`fn.warn = ...` / `setmetatable(fn, ...)` 都会报 attempt to index a function value），
--- 所以用 setmetatable({...}, { __call = ... }) —— 照旧 `log("...")`，同时能 `log.warn("...")`。
function M.makeLogger(prefix, enabled)
    local function emit(level, fmt, ...)
        if enabled == false then
            return
        end
        local msg
        if select("#", ...) > 0 then
            local ok, formatted = pcall(string.format, fmt, ...)
            if ok then
                msg = formatted
            else
                msg = tostring(fmt)
            end
        else
            msg = tostring(fmt)
        end
        M.pushLog(prefix, msg, level)
    end
    return setmetatable({
        warn = function(fmt, ...)
            return emit("warn", fmt, ...)
        end,
        error = function(fmt, ...)
            return emit("error", fmt, ...)
        end,
        --- 显式分级（如果调用方自己知道级别）
        log = function(level, fmt, ...)
            return emit(level or "info", fmt, ...)
        end,
    }, {
        __call = function(_, fmt, ...)
            return emit("info", fmt, ...)
        end,
    })
end

--- 简易唯一 id
local uidCounter = 0
function M.uid()
    uidCounter = uidCounter + 1
    return string.format("%x-%x", os.epoch("utc") % 0xFFFFFF, uidCounter % 0xFFFF)
end

return M
