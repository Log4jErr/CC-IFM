local M = {}

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

function M.now()
    return os.epoch("utc")
end

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

function M.num(v, default)
    v = tonumber(v)
    if v == nil then
        return default
    end
    return v
end

function M.int(v, default)
    v = tonumber(v)
    if v == nil then
        return default
    end
    return math.floor(v)
end

function M.trim(s)
    if type(s) ~= "string" then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.kindOfDef(def)
    local kind = type(def) == "table" and def.kind or def
    return kind == "fluid" and "fluid" or "item"
end

function M.count(t)
    local n = 0
    for _ in pairs(t or {}) do
        n = n + 1
    end
    return n
end

local LOG_LIMIT = 200
local logBuffer = {}
local logSeq = 0
local logHandler = nil

function M.setLogHandler(fn)
    logHandler = fn
end

M.LOG_TAGS = { info = nil, warn = "[warn] ", error = "[error] " }

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
        logHandler(line, logSeq, level)
    end
end

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

function M.makeLogger(prefix, enabled)
    local function emit(level, fmt, ...)
        if enabled == false then
            return
        end
        local msg
        if select("#", ...) > 0 then
            msg = string.format(fmt, ...)
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
        log = function(level, fmt, ...)
            return emit(level or "info", fmt, ...)
        end,
    }, {
        __call = function(_, fmt, ...)
            return emit("info", fmt, ...)
        end,
    })
end

local uidCounter = 0
function M.uid()
    uidCounter = uidCounter + 1
    return string.format("%x-%x", os.epoch("utc") % 0xFFFFFF, uidCounter % 0xFFFF)
end

return M
