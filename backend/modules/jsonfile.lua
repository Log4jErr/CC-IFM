local JsonFile = {}
JsonFile.__index = JsonFile

function JsonFile.new(opts)
    opts = opts or {}
    local self = setmetatable({}, JsonFile)
    self.Message = opts.Message
        or error("jsonfile.lua needs the message module: pass opts.Message", 0)
    self.path = opts.path or ""
    self.log = opts.log or function() end
    self.dirty = false
    -- Every write is measured, because the whole state travels as one json file: the
    -- serialization and the disk round trip are the two costs that can stall the master.
    -- A single write above `fatalMs` is a bug worth dying for (the flush guard in
    -- dispatch.lua is the same idea seen from the outside); `reportMs` is the level from
    -- which a write is logged even when it is not fatal, so a write that is "only" a few
    -- milliseconds several times a second still shows up in the log.
    self.fatalMs = tonumber(opts.fatalMs) or 100
    self.reportMs = tonumber(opts.reportMs) or 20
    return self
end

function JsonFile:read(label)
    label = label or tostring(self.path)
    if not fs.exists(self.path) then
        return nil, self.Message.msg(self.Message.KEYS.JSONFILE_NOT_FOUND, { label = label })
    end
    local handle = fs.open(self.path, "r")
    if not handle then
        return nil, self.Message.msg(self.Message.KEYS.JSONFILE_OPEN_FAILED, { path = tostring(self.path) })
    end
    local raw = handle.readAll()
    handle.close()
    local parsed = textutils.unserializeJSON(raw)
    if type(parsed) ~= "table" then
        return nil, self.Message.msg(self.Message.KEYS.JSONFILE_PARSE_FAILED, { label = label })
    end
    return parsed
end

function JsonFile:write(data)
    local startedAt = os.epoch("utc")
    local payload = textutils.serializeJSON(data, { allow_repetitions = true })
    local encodeMs = os.epoch("utc") - startedAt
    local bytes = #payload
    local tmp = self.path .. ".tmp"
    local handle = fs.open(tmp, "w")
    if not handle then
        -- The serialization already happened, so report it: a full disk used to hide
        -- exactly this cost, because the write it skipped was the only slow-looking part.
        self.log("Failed to write %s (cannot open temp file) encode=%dms bytes=%d",
            tmp, encodeMs, bytes)
        return false
    end
    handle.write(payload)
    handle.close()
    if fs.exists(self.path) then
        fs.delete(self.path)
    end
    fs.move(tmp, self.path)
    local fsMs = (os.epoch("utc") - startedAt) - encodeMs
    local totalMs = encodeMs + fsMs
    if totalMs >= self.reportMs then
        self.log("[perf] %s write serialize=%dms fs=%dms total=%dms bytes=%d", tostring(self.path),
            encodeMs, fsMs, totalMs, bytes)
    end
    if encodeMs >= self.fatalMs or fsMs >= self.fatalMs then
        self.log(string.format("[IFM] jsonfile write blocked: %s serialize=%dms fs=%dms total=%dms " ..
            "bytes=%d (>=%dms) - a single write may not cost this much, throttle the writer " ..
            "or split the state file", tostring(self.path), encodeMs, fsMs, totalMs, bytes,
            self.fatalMs), 0)
    end
    return true
end

function JsonFile:markDirty()
    self.dirty = true
end

-- Writes are not debounced: a dirty file is flushed on the next tick.
function JsonFile:shouldFlush(now)
    return self.dirty == true
end

function JsonFile:flush(data)
    if not self:write(data) then
        return false
    end
    self.dirty = false
    return true
end

return JsonFile
