-- IFM (Integrated Factory Manager) :: ifm/util.lua
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
--- CC:T 计算机磁盘有限，日志**不写文件**、也不刷屏终端：只保存最近若干条在内存环形缓冲里，
--- 由 ifm/protocol.lua 推送给网页（浏览器在控制台里打印）。
local LOG_LIMIT = 200
local logBuffer = {}
local logSeq = 0
local logHandler = nil

--- 设置日志接收者（例如 protocol:onLog）；传 nil 取消
function M.setLogHandler(fn)
    logHandler = fn
end

--- 追加一条日志（内部使用）
function M.pushLog(prefix, text)
    logSeq = logSeq + 1
    local line = "[" .. (prefix or "IFM") .. "] " .. tostring(text)
    logBuffer[#logBuffer + 1] = { seq = logSeq, line = line }
    while #logBuffer > LOG_LIMIT do
        table.remove(logBuffer, 1)
    end
    if logHandler then
        pcall(logHandler, line, logSeq)
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
function M.makeLogger(prefix, enabled)
    return function(fmt, ...)
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
        M.pushLog(prefix, msg)
    end
end

--- 简易唯一 id
local uidCounter = 0
function M.uid()
    uidCounter = uidCounter + 1
    return string.format("%x-%x", os.epoch("utc") % 0xFFFFFF, uidCounter % 0xFFFF)
end

return M
