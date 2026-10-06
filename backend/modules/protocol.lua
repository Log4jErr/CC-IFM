local Protocol = {}
Protocol.__index = Protocol

local CATEGORY_ORDER = {
    "containers",
    "signals",
    "filters",
    "machineTypes",
    "machines",
    "processes",
    "peripherals",
    "missing",
    "resources",
    "runtime",
    "materials",
    "plan",
    "deliveries",
    "workers",
}

local KEY_FIELDS = {
    containers = { "name" },
    signals = { "name" },
    filters = { "name" },
    machineTypes = { "name" },
    machines = { "name" },
    processes = { "name" },
    peripherals = { "kind", "name" },
    missing = { "kind", "name" },
    resources = { "kind", "name", "nbt" },
    runtime = { "name" },
    materials = { "key" },
    plan = { "name" },
    deliveries = { "id" },
    workers = { "id" },
}

local SCALAR_CATEGORIES = { status = true }

local WS_LIMIT_BYTES = 100000
Protocol.WS_LIMIT_BYTES = WS_LIMIT_BYTES

local PACK_PREFIX = "BDPK"
local PACK_SEP = "==+"

local function estimateBytes(value)
    local kind = type(value)
    if kind == "string" then
        local extra = 2
        for index = 1, #value do
            local byte = string.byte(value, index)
            if byte >= 128 then
                extra = extra + 2
            elseif byte < 32 then
                extra = extra + 5
            elseif byte == 34 or byte == 92 then
                extra = extra + 1
            end
        end
        return #value + extra
    elseif kind == "number" then
        return 24
    elseif kind == "boolean" then
        return 5
    elseif kind == "table" then
        local total = 4
        for key, item in pairs(value) do
            total = total + estimateBytes(key) + estimateBytes(item) + 4
        end
        return total
    end
    return 8
end

local ARRAY_ENTRY_EXTRA = estimateBytes({ "" }) - estimateBytes({})

local CONNECT_TIMEOUT_MS = 15000

local function keyOf(category, item)
    local fields = KEY_FIELDS[category]
    if not fields then
        return tostring(item)
    end
    local parts = {}
    for _, field in ipairs(fields) do
        parts[#parts + 1] = tostring(item[field])
    end
    return table.concat(parts, "/")
end

local function valuesEqual(a, b, depth)
    if a == b then
        return true
    end
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return false
    end
    depth = depth or 0
    if depth > 6 then
        return false
    end
    for k, v in pairs(a) do
        if not valuesEqual(v, b[k], depth + 1) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function levelLogger(fn)
    if type(fn) == "table" and fn.warn ~= nil and fn.error ~= nil then
        return fn
    end
    local base
    if type(fn) == "function" then
        base = fn
    elseif type(fn) == "table" then
        base = fn.info or function() end
    else
        base = function() end
    end
    return setmetatable({
        warn = function(...) return base(...) end,
        error = function(...) return base(...) end,
    }, {
        __call = function(_, ...) return base(...) end,
    })
end

function Protocol.new(opts)
    opts = opts or {}
    local self = setmetatable({}, Protocol)
    self.Util = opts.Util
    self.Assert = opts.Assert
        or error("protocol.lua needs the assert module: pass opts.Assert (loadModule(\"assert\"))", 0)
    self.log = levelLogger(opts.log)
    self.Message = opts.Message
        or error("protocol.lua needs the message module: pass opts.Message (loadModule(\"message\"))", 0)
    self.url = opts.url
    -- ws:// and wss:// speak the websocket API, http:// and https:// poll the
    -- relay's HTTP endpoint instead. Both share the same rooms and frames, so a
    -- websocket page and an HTTP master meet in the same channel.
    self.transport = (type(self.url) == "string" and self.url:match("^https?://")) and "http" or "ws"
    self.httpPollInterval = opts.httpPollInterval or 250
    self.httpOwnUid = nil
    self.httpPolling = false
    self.httpPosting = false
    self.httpPollUrl = nil
    self.httpPostUrl = nil
    self.httpOutbox = {}
    self.httpNextPoll = 0
    self.collect = opts.collect
    self.onRequest = opts.onRequest
    self.onConnect = opts.onConnect
    self.updateInterval = opts.updateInterval or 2
    self.revisionProvider = opts.revisionProvider
    self.pushedRevision = nil
    self.lastPushCost = 0
    self.reconnectInterval = opts.reconnectInterval or 5
    self.clientTimeout = opts.clientTimeout or 40
    self.maxLogChunk = opts.maxLogChunk or 40
    self.outbox = {}
    self.bundleSeq = 0
    self.ws = nil
    self.connected = false
    self.connecting = false
    self.connectRequestedAt = 0
    self.closeAcks = 0
    self.pendingAcks = 0
    self.connectedAt = 0
    self.closedAt = 0
    self.lastCloseReason = nil
    self.lastRxAt = 0
    self.idleReconnectInterval = opts.idleReconnectInterval or 300
    self.lastIdleReconnect = 0
    self.keepaliveInterval = opts.keepaliveInterval or 20
    self.lastSendAt = 0
    self.clientActive = false
    self.needFullSync = true
    self.lastHeartbeat = 0
    self.lastPush = 0
    self.lastReconnect = 0
    self.selfUid = nil
    self.snapshot = {}
    self.pushCount = 0
    self.sentLogSeq = 0
    self.logPending = false
    self.dropLogged = false
    self.stats = {
        sentMessages = 0, sentBytes = 0, sentMax = 0,
        recvMessages = 0, recvBytes = 0, recvMax = 0,
        dropped = 0, failed = 0, encodeFailed = 0,
        pushes = 0, pushSkipped = 0, fullSyncs = 0, changedItems = 0,
        connectRequests = 0, connectFailures = 0, connectTimeouts = 0,
        closes = 0, ownCloses = 0, staleCloses = 0, reconnects = 0,
        abandoned = 0, extraHandles = 0, keepalives = 0,
        flushes = 0, flushedFrames = 0, flushMessages = 0, flushDropped = 0, tooLarge = 0,
        logThrottled = 0, categorySkipped = 0, recvSelf = 0,
        byAction = {},
        lastSendBytes = 0,
        since = os.epoch("utc"),
    }
    self.categoryStats = {}
    return self
end

local function statBucket(stats, prefix, action)
    local key = prefix .. ":" .. tostring(action or "?")
    local entry = stats.byAction[key]
    if not entry then
        entry = { count = 0, bytes = 0, max = 0 }
        stats.byAction[key] = entry
    end
    return entry
end

function Protocol:onLog(text, seq)
    self.logPending = self.sendLog ~= false
end

function Protocol:setSendLog(enabled)
    local value = enabled ~= false
    if self.sendLog == value then
        return false
    end
    self.sendLog = value
    if not value then
        self.logPending = false
    end
    self.log("Web console log push %s (setting)", value and "ENABLED" or "DISABLED")
    return true
end

local LOG_TRUNCATED_MARK = " ...[truncated: single log line over the message budget]"

local function truncateLogLine(line, budget)
    local available = budget - #LOG_TRUNCATED_MARK
    local used, keep = 2, 0
    for index = 1, #line do
        local byte = string.byte(line, index)
        local cost
        if byte >= 128 then
            cost = 3
        elseif byte < 32 then
            cost = 6
        elseif byte == 34 or byte == 92 then
            cost = 2
        else
            cost = 1
        end
        if used + cost > available then
            break
        end
        used = used + cost
        keep = index
    end
    while keep > 0 and string.byte(line, keep) >= 128 and string.byte(line, keep) < 192 do
        keep = keep - 1
    end
    if keep > 0 and string.byte(line, keep) >= 192 then
        keep = keep - 1
    end
    return string.sub(line, 1, keep) .. LOG_TRUNCATED_MARK
end

function Protocol:flushLogs()
    if self.sendLog == false then
        self.logPending = false
        return
    end
    if not self.connected or not self.ws or not self.Util or not self.clientActive then
        return
    end
    local lines, lastSeq = self.Util.logSince(self.sentLogSeq or 0)
    if #lines == 0 then
        self.logPending = false
        return
    end
    local frameFixed = estimateBytes({ action = "log", lines = {}, lastSeq = lastSeq })
    local frameBudget = WS_LIMIT_BYTES - #PACK_PREFIX - frameFixed
    local lineBudget = frameBudget - ARRAY_ENTRY_EXTRA
    local index = 1
    while index <= #lines do
        local chunk, bytes = {}, 0
        local last = index - 1
        while last < #lines and #chunk < self.maxLogChunk do
            local line = tostring(lines[last + 1])
            local lineBytes = estimateBytes(line)
            if lineBytes > lineBudget then
                line = truncateLogLine(line, lineBudget)
                lineBytes = estimateBytes(line)
            end
            local lineCost = lineBytes + ARRAY_ENTRY_EXTRA
            if #chunk > 0 and bytes + lineCost > frameBudget then
                break
            end
            chunk[#chunk + 1] = line
            bytes = bytes + lineCost
            last = last + 1
        end
        if #chunk == 0 then
            self.log.error("log line still over %d bytes after packing - dropped one line", lineBudget)
            index = index + 1
        else
            if not self:send({ action = "log", lines = chunk, lastSeq = lastSeq }) then
                return
            end
            index = last + 1
        end
    end
    self.sentLogSeq = lastSeq
    self.logPending = false
end

function Protocol:connect()
    if self.transport == "http" then
        if not (http and http.request) then
            self.stats.connectFailures = self.stats.connectFailures + 1
            self.log.error("The http API is unavailable: enable it in the CC:Tweaked config" ..
                " (http.enabled) or use a ws:// / wss:// relay")
            return false
        end
        self.connecting = false
        self.connected = true
        self.connectedAt = os.epoch("utc")
        self.lastRxAt = self.connectedAt
        self.needFullSync = true
        self.snapshot = {}
        self.httpPolling = false
        self.httpPollUrl = nil
        self.httpNextPoll = 0
        self.log("HTTP relay: polling %s", tostring(self.url))
        if self.onConnect then
            self.onConnect()
        end
        return true
    end
    self:closeSocket()
    if self.connecting then
        return false
    end
    http.websocketAsync(self.url)
    self.connecting = true
    self.connectRequestedAt = os.epoch("utc")
    self.pendingAcks = (self.pendingAcks or 0) + 1
    self.stats.connectRequests = self.stats.connectRequests + 1
    return true
end

function Protocol:onSocketOpened(handle)
    self.connecting = false
    self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
    local kind = type(handle)
    if kind ~= "table" and kind ~= "userdata" then
        self.connected = false
        self.log("WebSocket success event had no handle, will retry")
        return false
    end
    if self.ws then
        self.closeAcks = (self.closeAcks or 0) + 1
        self.stats.extraHandles = self.stats.extraHandles + 1
        handle.close()
        self.log("Extra websocket handle closed (a live connection already exists)")
        return false
    end
    self.sendFailedLogged = false
    self.selfEchoLogged = false
    self.unknownEchoWarned = false
    self.ws = handle
    self.connected = true
    self.connectedAt = os.epoch("utc")
    self.lastRxAt = self.connectedAt
    self.needFullSync = true
    self.snapshot = {}
    self.dropLogged = false
    self.sentLogSeq = 0
    self.log("WebSocket connected: %s (after %dms)", self.url,
        math.max(0, self.connectedAt - (self.connectRequestedAt or self.connectedAt)))
    if self.onConnect then
        self.onConnect()
    end
    return true
end

function Protocol:send(message)
    if not self.connected or (self.transport == "ws" and not self.ws) then
        self.stats.dropped = self.stats.dropped + 1
        if not self.dropLogged then
            self.dropLogged = true
            self.log.warn("Message dropped: websocket not connected (action=%s)", tostring(message and message.action))
        end
        return false
    end
    self.outbox = self.outbox or {}
    self.outbox[#self.outbox + 1] = message
    return true
end

function Protocol:encodeFrame(frame)
    return (string.gsub(textutils.serializeJSON(frame, { allow_repetitions = true }), "=", "=+"))
end

function Protocol:flushSendBuffer()
    local box = self.outbox
    if not box or #box == 0 then
        return 0
    end
    self.outbox = {}
    self.stats.flushes = self.stats.flushes + 1

    local packed, packedSize = nil, 0
    local packedSeq = 0
    local packedFrames, packedBytes = {}, {}
    local sentTotal = 0
    local function nextHeadLength()
        return #PACK_PREFIX + #tostring((self.bundleSeq or 0) + 1) + 1
    end
    local function beginBundle(frame, text)
        self.bundleSeq = (self.bundleSeq or 0) + 1
        packedSeq = self.bundleSeq
        local head = PACK_PREFIX .. tostring(packedSeq) .. ":"
        packed = head .. text
        packedSize = #head + #text
        packedFrames[1] = frame
        packedBytes[1] = #text
    end
    local function flushPacked()
        if not packed then
            return
        end
        if self:writeNow(packed) then
            self.stats.flushMessages = self.stats.flushMessages + 1
            self.log("bundle #%d: %d bytes, %d frame(s)", packedSeq, #packed, #packedFrames)
            for index = 1, #packedFrames do
                self:noteSent(packedFrames[index], packedBytes[index])
            end
            self.stats.flushedFrames = self.stats.flushedFrames + #packedFrames
            sentTotal = sentTotal + #packedFrames
        else
            self.stats.flushDropped = self.stats.flushDropped + #packedFrames
        end
        packed, packedSize = nil, 0
        packedFrames, packedBytes = {}, {}
    end

    for index = 1, #box do
        local frame = box[index]
        local text, err = self:encodeFrame(frame)
        if not text then
            self.stats.encodeFailed = self.stats.encodeFailed + 1
            self.log.error("JSON encode failed for %s frame: %s",
                tostring(frame and frame.action), tostring(err))
        elseif nextHeadLength() + #text > WS_LIMIT_BYTES then
            self.stats.tooLarge = self.stats.tooLarge + 1
            self.log.error("Outbound %s frame is %d bytes (over the %d byte limit) - NOT sent; " ..
                "the producer must split it by entry", tostring(frame and frame.action), #text, WS_LIMIT_BYTES)
        elseif packed and packedSize + #PACK_SEP + #text > WS_LIMIT_BYTES then
            flushPacked()
            beginBundle(frame, text)
        elseif packed then
            packed = packed .. PACK_SEP .. text
            packedSize = packedSize + #PACK_SEP + #text
            packedFrames[#packedFrames + 1] = frame
            packedBytes[#packedBytes + 1] = #text
        else
            beginBundle(frame, text)
        end
    end
    flushPacked()
    return sentTotal
end

function Protocol:writeNow(text)
    if self.transport == "http" then
        return self:httpPost(text)
    end
    if not self.ws or not self.connected then
        self.stats.dropped = self.stats.dropped + 1
        if not self.dropLogged then
            self.dropLogged = true
            self.log.warn("Message dropped: websocket not connected (%d bytes)", #text)
        end
        return false
    end
    if #text > WS_LIMIT_BYTES then
        self.stats.tooLarge = self.stats.tooLarge + 1
        self.log.error("Outbound packed message is %d bytes (over the %d byte limit) - NOT sent",
            #text, WS_LIMIT_BYTES)
        return false
    end
    local socket = self.ws
    socket.send(text)
    self.lastSendBytes = #text
    return true
end

function Protocol:noteSent(message, bytes)
    self.pushCount = self.pushCount + 1
    self.lastSendAt = os.epoch("utc")
    local stats = self.stats
    bytes = tonumber(bytes) or 0
    stats.sentMessages = stats.sentMessages + 1
    stats.sentBytes = stats.sentBytes + bytes
    if bytes > stats.sentMax then
        stats.sentMax = bytes
    end
    local bucket = statBucket(stats, "send", message and message.action)
    bucket.count = bucket.count + 1
    bucket.bytes = bucket.bytes + bytes
    if bytes > bucket.max then
        bucket.max = bytes
    end
    if self.traceMessages then
        self.log("send %s: %d bytes", tostring(message and message.action), bytes)
    end
end

function Protocol:closeSocket()
    if self.transport == "http" then
        self.connected = false
        self.httpPolling = false
        self.httpPosting = false
        self.httpPollUrl = nil
        self.httpPostUrl = nil
        return
    end
    if not self.ws then
        return
    end
    local socket = self.ws
    self.ws = nil
    self.closeAcks = (self.closeAcks or 0) + 1
    socket.close()
end

-- No anti-flicker delay: a collection that suddenly loses an entry (a finished
-- process dropping out of the runtime list, a removed worker, ...) has that
-- deletion pushed in the very same diff. The delay used to smooth over one-tick
-- flaps, but it only worked when another diff happened to follow the window: a
-- quiet system could keep the deleted row on the page until a full resync. A flap
-- now costs one row blink, a missed deletion costs a stale row that never leaves.
local TOMBSTONE_DELAY_MS = 0

local IMMEDIATE_TOMBSTONES = { deliveries = true, materials = true }

function Protocol:expediteDeletions()
    self.expediteTombstones = true
end

function Protocol:diffCategory(category, newList, expedite)
    local fields = KEY_FIELDS[category]
    local changes = {}
    local now = os.epoch("utc")
    local pending = self.tombstoneAt or {}
    self.tombstoneAt = pending
    if expedite ~= true then
        expedite = IMMEDIATE_TOMBSTONES[category] == true
    end
    -- pending keys are "category\1itemKey": remembering the category inside the key
    -- keeps one flat table for every category.
    local prefix = category .. "\1"
    local function emitTombstone(previous)
        local tombstone = { _deleted = true }
        for _, field in ipairs(fields or {}) do
            tombstone[field] = previous[field]
        end
        changes[#changes + 1] = tombstone
    end
    if self.needFullSync or type(self.snapshot[category]) ~= "table" then
        for _, item in ipairs(newList) do
            changes[#changes + 1] = item
        end
        self.snapshot[category] = newList
        -- The whole list is on its way, so no deletion has to be remembered.
        for markKey in pairs(pending) do
            if string.sub(markKey, 1, #prefix) == prefix then
                pending[markKey] = nil
            end
        end
        return changes
    end
    local previousMap = {}
    for _, item in ipairs(self.snapshot[category]) do
        previousMap[keyOf(category, item)] = item
    end
    local seen = {}
    for _, item in ipairs(newList) do
        local itemKey = keyOf(category, item)
        seen[itemKey] = true
        pending[prefix .. itemKey] = nil
        local previous = previousMap[itemKey]
        if previous == nil or not valuesEqual(previous, item) then
            changes[#changes + 1] = item
        end
    end
    -- A removed entry is told to the page only after TOMBSTONE_DELAY_MS, so a
    -- collection that flaps for a tick does not make its row blink. The removed
    -- item has to be remembered in `pending` together with its payload, because
    -- the snapshot is replaced with newList right below: on the next diff the
    -- item is no longer in previousMap, so a mark holding only a timestamp would
    -- never be looked at again and the deletion would never be sent.
    for itemKey, previous in pairs(previousMap) do
        if not seen[itemKey] then
            local markKey = prefix .. itemKey
            if expedite then
                pending[markKey] = nil
                emitTombstone(previous)
            elseif pending[markKey] == nil then
                pending[markKey] = { at = now, item = previous }
            end
        end
    end
    for markKey, mark in pairs(pending) do
        if string.sub(markKey, 1, #prefix) == prefix then
            local itemKey = string.sub(markKey, #prefix + 1)
            if seen[itemKey] then
                pending[markKey] = nil
            else
                local since = now
                if type(mark) == "table" then
                    since = tonumber(mark.at) or now
                elseif type(mark) == "number" then
                    since = mark
                end
                if expedite or now - since >= TOMBSTONE_DELAY_MS then
                    pending[markKey] = nil
                    if type(mark) == "table" and type(mark.item) == "table" then
                        emitTombstone(mark.item)
                    end
                end
            end
        end
    end
    self.snapshot[category] = newList
    return changes
end

function Protocol:sendCategoryChanges(category, changes)
    if #changes == 0 then
        return true
    end
    local entry = self.categoryStats[category]
    if not entry then
        entry = { frames = 0, bytes = 0, max = 0, items = 0 }
        self.categoryStats[category] = entry
    end
    local frameFixed = estimateBytes({
        action = "incremental_update", count = #changes, changes = { [category] = {} },
    })
    local frameBudget = WS_LIMIT_BYTES - #PACK_PREFIX - frameFixed
    local itemBudget = frameBudget - ARRAY_ENTRY_EXTRA
    local start = 1
    while start <= #changes do
        local chunk, bytes = {}, 0
        local last = start - 1
        while last < #changes do
            local bytesOfItem = estimateBytes(changes[last + 1])
            if bytesOfItem > itemBudget then
                self.stats.tooLarge = self.stats.tooLarge + 1
                self.log.error("incremental_update %s entry %d is over the %d byte budget (%d bytes) - dropped; " ..
                    "the payload of that single entry is too large to send", tostring(category), last + 1,
                    itemBudget, bytesOfItem)
                last = last + 1
            elseif bytes + bytesOfItem + ARRAY_ENTRY_EXTRA > frameBudget then
                break
            else
                chunk[#chunk + 1] = changes[last + 1]
                bytes = bytes + bytesOfItem + ARRAY_ENTRY_EXTRA
                last = last + 1
            end
        end
        if #chunk == 0 then
            self.log.error("category %s change %d could not be packed - skipping it", tostring(category), start)
            start = start + 1
        else
            if not self:send({
                action = "incremental_update",
                count = #chunk,
                changes = { [category] = chunk },
            }) then
                return false
            end
            entry.frames = entry.frames + 1
            entry.items = entry.items + #chunk
            entry.bytes = entry.bytes + bytes
            if bytes > entry.max then
                entry.max = bytes
            end
            start = last + 1
        end
    end
    return true
end

function Protocol:currentRevision()
    if not self.revisionProvider then
        return 0
    end
    local value = self.revisionProvider()
    return tonumber(value) or 0
end

function Protocol:hasChanges()
    return self:currentRevision() ~= (self.pushedRevision or 0)
end

local CATEGORY_PUSH_GAP_MS = { workers = 5000 }

function Protocol:pushUpdates(force)
    if not self.connected then
        return false
    end
    if not self.clientActive and not force then
        self.stats.pushSkipped = self.stats.pushSkipped + 1
        return false
    end
    local collected = self.collect()
    if type(collected) ~= "table" then
        self.log("Snapshot collection failed: %s", tostring(collected))
        return false
    end
    local categories = {}
    for _, category in ipairs(CATEGORY_ORDER) do
        if collected[category] ~= nil then
            categories[#categories + 1] = category
        end
    end
    for category in pairs(SCALAR_CATEGORIES) do
        if collected[category] ~= nil then
            categories[#categories + 1] = category
        end
    end
    local needFullSync = self.needFullSync
    local expediteDeletions = self.expediteTombstones == true
    self.expediteTombstones = false
    if needFullSync then
        self.stats.fullSyncs = self.stats.fullSyncs + 1
        self:send({ action = "full_sync_start", categories = categories })
        self:send({ action = "state_clear", categories = categories })
    end
    local success = true
    local pushNow = os.epoch("utc")
    local categorySentAt = self.categorySentAt or {}
    self.categorySentAt = categorySentAt
    for _, category in ipairs(CATEGORY_ORDER) do
        local list = collected[category]
        if list == nil and needFullSync then
            list = {}
        end
        if list ~= nil then
            local gap = CATEGORY_PUSH_GAP_MS[category] or 0
            if gap > 0 and not needFullSync and pushNow - (categorySentAt[category] or 0) < gap then
                self.stats.categorySkipped = self.stats.categorySkipped + 1
            else
                local changes = self:diffCategory(category, list, expediteDeletions)
                categorySentAt[category] = pushNow
                self.stats.changedItems = self.stats.changedItems + #changes
                if needFullSync then
                    self.log("sync %s: %d item(s) (%d collected)", category, #changes, #list)
                end
                if not self:sendCategoryChanges(category, changes) then
                    self.log.error("Push aborted: category %s could not be sent - the remaining " ..
                        "categories are SKIPPED this round (the page will show those panels empty)", category)
                    success = false
                    break
                end
            end
        end
    end
    if success and collected.status ~= nil then
        if self.needFullSync or not valuesEqual(self.snapshot.status, collected.status) then
            self.snapshot.status = collected.status
            if not self:send({ action = "incremental_update", changes = { status = collected.status } }) then
                success = false
            end
        end
    end
    if success then
        self.needFullSync = false
        self.lastPush = os.epoch("utc")
        self.stats.pushes = self.stats.pushes + 1
        self.pushedRevision = self:currentRevision()
        if needFullSync then
            self:send({ action = "full_sync_end", categories = categories })
        end
    end
    return success
end

-- --- http transport -------------------------------------------------------
-- The relay's HTTP endpoint takes one frame per POST and hands out the frames
-- queued for us per GET: the same outbox, the same frames and the same
-- handleMessage() as the websocket path, only the carrier differs.

function Protocol:httpUid()
    return tostring(self.httpOwnUid or self.selfUid or "")
end

function Protocol:httpUrlWith(query)
    local url = tostring(self.url or "")
    return url .. (url:find("?", 1, true) and "&" or "?") .. query
end

-- Posts are serialised on purpose: the page state depends on the order of the
-- full_sync / state_clear / incremental_update frames the master sends.
function Protocol:httpPost(text)
    self.httpOutbox[#self.httpOutbox + 1] = text
    return self:httpPump()
end

function Protocol:httpPump()
    if self.httpPosting or #self.httpOutbox == 0 then
        return true
    end
    if not (http and http.request) or not self.connected then
        return false
    end
    local text = table.remove(self.httpOutbox, 1)
    local url = self:httpUrlWith("uid=" .. self:httpUid() .. "&post=1")
    self.httpPosting = true
    self.httpPostUrl = url
    local ok, err = pcall(http.request, url, text, { ["Content-Type"] = "text/plain" })
    if not ok then
        self.httpPosting = false
        self.httpPostUrl = nil
        self.stats.failed = self.stats.failed + 1
        self.log.error("HTTP post failed: %s", tostring(err))
        return false
    end
    return true
end

function Protocol:httpPoll()
    if not (http and http.request) or not self.connected then
        return false
    end
    local url = self:httpUrlWith("uid=" .. self:httpUid() .. "&wait=0")
    self.httpPolling = true
    self.httpPollUrl = url
    local ok, err = pcall(http.request, url)
    if not ok then
        self.httpPolling = false
        self.httpPollUrl = nil
        self.stats.connectFailures = self.stats.connectFailures + 1
        self.log.error("HTTP poll failed: %s", tostring(err))
        self.httpNextPoll = os.epoch("utc") + 2000
        return false
    end
    return true
end

function Protocol:httpOnPollResponse(handle)
    local text = ""
    if handle and handle.readAll then
        local ok, body = pcall(handle.readAll)
        text = ok and tostring(body or "") or ""
    end
    if handle and handle.close then
        pcall(handle.close)
    end
    self.lastRxAt = os.epoch("utc")
    local parsed = textutils.unserializeJSON(text)
    if type(parsed) ~= "table" then
        self.log.error("HTTP poll returned no usable JSON (%d bytes)", #text)
        return true
    end
    if type(parsed.uid) == "string" and parsed.uid ~= "" then
        self.httpOwnUid = parsed.uid
    end
    local frames = parsed.frames
    if type(frames) == "table" then
        for _, frame in ipairs(frames) do
            if type(frame) == "table" then
                self:handleMessage(textutils.serializeJSON(frame, { allow_repetitions = true }))
            end
        end
    end
    return true
end

function Protocol:httpUpdate(now)
    if not self.connected then
        if now - (self.lastReconnect or 0) >= (self.reconnectInterval or 5) * 1000 then
            self.lastReconnect = now
            self.stats.reconnects = self.stats.reconnects + 1
            self:connect()
        end
        return
    end
    if self.clientActive and now - self.lastHeartbeat > self.clientTimeout * 1000 then
        self.clientActive = false
        self.needFullSync = true
        self.log("Client timeout (%ds without a browser message); it will resync when it returns",
            self.clientTimeout)
    end
    if self.httpPosting then
        return
    end
    if not self.httpPolling and now >= (self.httpNextPoll or 0) then
        self.httpNextPoll = now + self.httpPollInterval
        self:httpPoll()
    end
    -- The same push logic as the websocket path: the page has to be told about
    -- every change, the carrier only decides how the frames leave the computer.
    if self.clientActive then
        local changed = self:hasChanges()
        if changed or now - self.lastPush >= self.updateInterval * 1000 then
            local startedAt = os.epoch("utc")
            local ok = self:pushUpdates(false)
            self.lastPushCost = os.epoch("utc") - startedAt
            if not ok then
                self.lastPush = os.epoch("utc")
            end
        end
    end
    if self.logPending then
        self:flushLogs()
    end
end

function Protocol:update(now)
    now = now or os.epoch("utc")
    if self.transport == "http" then
        return self:httpUpdate(now)
    end
    if self.clientActive and now - self.lastHeartbeat > self.clientTimeout * 1000 then
        self.clientActive = false
        self.needFullSync = true
        self.log("Client timeout (%ds without browser message); keeping the relay socket, will resync", self.clientTimeout)
        return
    end
    if not self.connected then
        if (self.pendingAcks or 0) > 0 then
            if now - (self.connectRequestedAt or 0) < CONNECT_TIMEOUT_MS then
                return
            end
            self.pendingAcks = math.max(0, self.pendingAcks - 1)
            self.closeAcks = (self.closeAcks or 0) + 1
            self.connecting = false
            self.stats.connectTimeouts = self.stats.connectTimeouts + 1
            self.stats.abandoned = self.stats.abandoned + 1
            self.log("WebSocket connect timed out after %ds, retrying", math.floor(CONNECT_TIMEOUT_MS / 1000))
        end
        if now - self.lastReconnect >= self.reconnectInterval * 1000 then
            self.lastReconnect = now
            self.stats.reconnects = self.stats.reconnects + 1
            self:connect()
        end
        return
    end
    local lastInbound = math.max(self.lastRxAt or 0, self.connectedAt or 0)
    if self.idleReconnectInterval and self.idleReconnectInterval > 0
        and now - lastInbound > self.idleReconnectInterval * 1000
        and now - (self.lastIdleReconnect or 0) > self.idleReconnectInterval * 1000 then
        self.lastIdleReconnect = now
        self.lastRxAt = now
        self.stats.reconnects = self.stats.reconnects + 1
        self.log("No relay traffic for %ds, refreshing the connection", self.idleReconnectInterval)
        self:connect()
        return
    end
    local lastTraffic = math.max(self.lastSendAt or 0, self.lastRxAt or 0, self.connectedAt or 0)
    if self.keepaliveInterval and self.keepaliveInterval > 0
        and now - lastTraffic >= self.keepaliveInterval * 1000 then
        self.stats.keepalives = self.stats.keepalives + 1
        self:send({ type = "keepalive", at = now })
    end
    if self.clientActive then
        local changed = self:hasChanges()
        if changed or now - self.lastPush >= self.updateInterval * 1000 then
            local startedAt = os.epoch("utc")
            local ok = self:pushUpdates(false)
            self.lastPushCost = os.epoch("utc") - startedAt
            if not ok then
                self.lastPush = os.epoch("utc")
            end
        end
    end
    if self.logPending then
        self:flushLogs()
    end
end

function Protocol.senderUidOf(frame)
    if type(frame) ~= "table" or frame.uid == nil then
        return nil
    end
    return tostring(frame.uid)
end

function Protocol:isOwnFrame(frame)
    local uid = Protocol.senderUidOf(frame)
    if uid == nil or self.selfUid == nil then
        return false
    end
    return uid == tostring(self.selfUid)
end

local SERVER_ONLY_ACTIONS = {
    full_sync_start = true,
    full_sync_end = true,
    state_clear = true,
    incremental_update = true,
    keepalive = true,
    log = true,
}

function Protocol:handleMessage(raw)
    local data = textutils.unserializeJSON(raw)
    if type(data) ~= "table" then
        self.log.error("Received unparseable message")
        return
    end
    if self:isOwnFrame(data) then
        self.stats.recvSelf = self.stats.recvSelf + 1
        if not self.selfEchoLogged then
            self.selfEchoLogged = true
            self.log.warn("Ignoring the relay's echo of our own frames (uid=%s): they are our own messages",
                tostring(self.selfUid))
        end
        return
    end
    local payload = data
    if data.message ~= nil then
        if type(data.message) == "table" then
            payload = data.message
        elseif type(data.message) == "string" then
            local inner = textutils.unserializeJSON(data.message)
            if type(inner) == "table" then
                payload = inner
            else
                self.log.warn("Received a message field that is not JSON (%d bytes) - dropped",
                    #data.message)
                return
            end
        end
    end

    if type(payload) == "table" and type(payload[1]) == "table" and payload.action == nil
        and payload.type == nil then
        for _, frame in ipairs(payload) do
            if type(frame) == "table" then
                self:handleMessage(textutils.serializeJSON(frame, { allow_repetitions = true }))
            end
        end
        return
    end
    if payload.action and SERVER_ONLY_ACTIONS[payload.action] and not self.unknownEchoWarned then
        self.unknownEchoWarned = true
        local fields = {}
        for key in pairs(data) do
            fields[#fields + 1] = tostring(key)
        end
        table.sort(fields)
        self.log.warn("Received a server-only action (%s) that we could not recognise as our own echo" ..
            " (selfUid=%s, frame fields: %s): check the relay's sender uid field",
            tostring(payload.action), tostring(self.selfUid), table.concat(fields, ","))
    end
    local stats = self.stats
    local bytes = #raw
    stats.recvMessages = stats.recvMessages + 1
    stats.recvBytes = stats.recvBytes + bytes
    if bytes > stats.recvMax then
        stats.recvMax = bytes
    end
    local recvBucket = statBucket(stats, "recv", payload.action or payload.type or "?")
    recvBucket.count = recvBucket.count + 1
    recvBucket.bytes = recvBucket.bytes + bytes
    if bytes > recvBucket.max then
        recvBucket.max = bytes
    end
    if payload.type == "join" then
        if payload.self then
            self.selfUid = payload.uid
            self.log("Joined channel: uid=%s total=%s", tostring(payload.uid), tostring(payload.total))
        else
            self.log("Client connected: uid=%s alias=%s total=%s",
                tostring(payload.uid), tostring(payload.alias), tostring(payload.total))
            self.clientActive = true
            self.lastHeartbeat = os.epoch("utc")
            self.needFullSync = true
            self.snapshot = {}
            self.sentLogSeq = 0
            self:flushLogs()
            self:pushUpdates(true)
        end
        return
    end
    if payload.type == "leave" then
        local total = tonumber(payload.total) or 0
        self.log("Client disconnected: uid=%s alias=%s total=%s",
            tostring(payload.uid), tostring(payload.alias), tostring(total))
        if total <= 1 then
            self.clientActive = false
            self.needFullSync = true
        end
        return
    end
    if not payload.action then
        return
    end
    self.lastHeartbeat = os.epoch("utc")
    if payload.action == "heartbeat" then
        self.clientActive = true
    end
    if not self.clientActive then
        self.clientActive = true
        self.needFullSync = true
    end
    local response = { id = payload.id or payload.cid, action = payload.action }
    if payload.action == "full_request" then
        self.clientActive = true
        self.needFullSync = true
        self.snapshot = {}
        self:pushUpdates(true)
        response.result = { full_request_received = true }
        self:send(response)
        return
    end
    local startedAt = os.epoch("utc")
    local result = self.onRequest(payload)
    local elapsed = os.epoch("utc") - startedAt
    response.result = result
    if elapsed >= 1000 then
        -- A whole second blocked the main loop: this is a bug, fail hard.
        self.Assert.is(false,
            "Action %s took %dms (>= 1000ms): the main loop could not serve events",
            tostring(payload.action), elapsed)
    end
    self:send(response)
    if self.clientActive and payload.action ~= "heartbeat" then
        if self:hasChanges() then
            self.pushUpdates(self, false)
        end
    end
end

function Protocol:onEvent(event, param1, param2, param3)
    if event == "websocket_success" and param1 == self.url then
        self:onSocketOpened(param2)
        return true
    end
    if event == "websocket_message" and param1 == self.url then
        self.lastRxAt = os.epoch("utc")
        self:handleMessage(param2)
        return true
    end
    if event == "websocket_closed" and param1 == self.url then
        local stats = self.stats
        stats.closes = stats.closes + 1
        self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
        local reason = tostring(param2)
        if param3 ~= nil and tostring(param3) ~= "" then
            reason = reason .. " / " .. tostring(param3)
        end
        self.lastCloseReason = reason
        self.closedAt = os.epoch("utc")
        if (self.closeAcks or 0) > 0 then
            self.closeAcks = self.closeAcks - 1
            stats.ownCloses = stats.ownCloses + 1
            self.log("Old socket closed as requested (ignored; %s; age %dms)",
                reason, self.connectedAt > 0 and (self.closedAt - self.connectedAt) or 0)
            return true
        end
        if not self.ws and not self.connected then
            stats.staleCloses = stats.staleCloses + 1
            return true
        end
        self.connecting = false
        self.connected = false
        self.ws = nil
        self.clientActive = false
        self.log("WebSocket closed by relay (%s) after %ds, will reconnect",
            reason, self.connectedAt > 0 and math.floor((self.closedAt - self.connectedAt) / 1000) or 0)
        return true
    end
    if event == "websocket_failure" and param1 == self.url then
        self.pendingAcks = math.max(0, (self.pendingAcks or 0) - 1)
        self.stats.connectFailures = self.stats.connectFailures + 1
        if (self.closeAcks or 0) > 0 then
            self.closeAcks = self.closeAcks - 1
            self.stats.staleCloses = self.stats.staleCloses + 1
            self.log("Stale connect failure ignored: %s", tostring(param2))
            return true
        end
        if self.ws and self.connected then
            self.stats.staleCloses = self.stats.staleCloses + 1
            self.log("Connect failure for an old attempt ignored (a live connection exists): %s", tostring(param2))
            return true
        end
        self.connecting = false
        self.connected = false
        self.ws = nil
        self.log("WebSocket connect failed: %s", tostring(param2))
        return true
    end
    if event == "http_success" then
        if self.httpPollUrl and param1 == self.httpPollUrl then
            self.httpPollUrl = nil
            self.httpPolling = false
            return self:httpOnPollResponse(param2)
        end
        if self.httpPostUrl and param1 == self.httpPostUrl then
            self.httpPostUrl = nil
            self.httpPosting = false
            if param2 and param2.close then
                pcall(param2.close)
            end
            self:httpPump()
            return true
        end
        return false
    end
    if event == "http_failure" then
        if self.httpPollUrl and param1 == self.httpPollUrl then
            self.httpPollUrl = nil
            self.httpPolling = false
            self.stats.connectFailures = self.stats.connectFailures + 1
            self.httpNextPoll = os.epoch("utc") + 2000
            self.log("HTTP poll failed: %s", tostring(param2))
            return true
        end
        if self.httpPostUrl and param1 == self.httpPostUrl then
            self.httpPostUrl = nil
            self.httpPosting = false
            self.stats.failed = self.stats.failed + 1
            self.log("HTTP post failed: %s", tostring(param2))
            self:httpPump()
            return true
        end
        return false
    end
    return false
end

function Protocol:status()
    return {
        url = self.url,
        transport = self.transport,
        connected = self.connected,
        connecting = self.connecting or false,
        clientActive = self.clientActive,
        updateInterval = self.updateInterval,
        connectedSeconds = (self.connected and (self.connectedAt or 0) > 0)
            and math.floor((os.epoch("utc") - self.connectedAt) / 1000) or 0,
        idleSeconds = ((self.lastRxAt or 0) > 0) and math.floor((os.epoch("utc") - self.lastRxAt) / 1000) or -1,
        closes = (self.stats and self.stats.closes) or 0,
        lastCloseReason = self.lastCloseReason,
        pendingAcks = self.pendingAcks or 0,
        expectedAcks = self.closeAcks or 0,
    }
end

function Protocol:statsSummary()
    local stats = self.stats
    local actions = {}
    for key, entry in pairs(stats.byAction) do
        actions[#actions + 1] = {
            key = key,
            count = entry.count,
            bytes = entry.bytes,
            max = entry.max,
            average = entry.count > 0 and math.floor(entry.bytes / entry.count) or 0,
        }
    end
    table.sort(actions, function(a, b)
        if a.bytes ~= b.bytes then
            return a.bytes > b.bytes
        end
        return a.key < b.key
    end)
    local since = stats.since or os.epoch("utc")
    local categories = {}
    for key, entry in pairs(self.categoryStats or {}) do
        categories[#categories + 1] = {
            key = key,
            frames = entry.frames or 0,
            items = entry.items or 0,
            bytes = entry.bytes or 0,
            max = entry.max or 0,
            average = (entry.frames or 0) > 0 and math.floor((entry.bytes or 0) / entry.frames) or 0,
        }
    end
    table.sort(categories, function(a, b)
        if a.bytes ~= b.bytes then
            return a.bytes > b.bytes
        end
        return tostring(a.key) < tostring(b.key)
    end)
    return {
        lastPushCost = self.lastPushCost or 0,
        updateInterval = self.updateInterval,
        sentMessages = stats.sentMessages,
        sentBytes = stats.sentBytes,
        sentMax = stats.sentMax,
        categories = categories,
        recvMessages = stats.recvMessages,
        recvBytes = stats.recvBytes,
        recvMax = stats.recvMax,
        dropped = stats.dropped,
        failed = stats.failed,
        encodeFailed = stats.encodeFailed,
        connectRequests = stats.connectRequests,
        connectFailures = stats.connectFailures,
        connectTimeouts = stats.connectTimeouts,
        closes = stats.closes,
        ownCloses = stats.ownCloses,
        staleCloses = stats.staleCloses,
        reconnects = stats.reconnects,
        pendingAcks = self.pendingAcks,
        expectedAcks = self.closeAcks,
        abandoned = stats.abandoned,
        extraHandles = stats.extraHandles,
        recvSelf = stats.recvSelf,
        ownEchoSeen = self.selfEchoLogged == true,
        keepalives = stats.keepalives,
        lastCloseReason = self.lastCloseReason,
        connectedSeconds = (self.connected and self.connectedAt or 0) > 0
            and math.floor((os.epoch("utc") - self.connectedAt) / 1000) or 0,
        idleSeconds = ((self.lastRxAt or 0) > 0) and math.floor((os.epoch("utc") - self.lastRxAt) / 1000) or -1,
        pushes = stats.pushes,
        pushSkipped = stats.pushSkipped,
        fullSyncs = stats.fullSyncs,
        changedItems = stats.changedItems,
        uptimeSeconds = math.floor((os.epoch("utc") - since) / 1000),
        actions = actions,
    }
end

return Protocol
