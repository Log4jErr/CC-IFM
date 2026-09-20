-- IFM :: tools/worker_drive.lua
-- 由 tools/run_worker_drive.js 加载：把 IFMWorker.lua 当成真程序驱动的测试脚本。
-- 这里只写"驱动 + 断言"，CC:T 环境桩都在 JS 的 prelude 里。

local passed, failed = 0, 0
local function report(text)
    __report(tostring(text))
end
local function check(name, ok, detail)
    if ok then
        passed = passed + 1
        report('  ok   ' .. name)
    else
        failed = failed + 1
        report('  FAIL ' .. name .. (detail and (' -> ' .. tostring(detail)) or ''))
    end
end

-- ===== 载入 worker 之前先把 CC:T 的 fs/shell/term 补上 =====
-- 注意：fengari 不允许在 Lua 协程里调用 JS 函数（worker 就跑在协程里），所以文件内容
-- 必须在**顶层**一次读进来（__read 只能在顶层用），协程里只查这张表。
local sources = {}
for _, file in ipairs({
    'IFMWorker.lua', '/modules/modems.lua', '/modules/peripherals.lua', '/modules/transfer.lua',
}) do
    sources[file] = __read(file)
end

loadfile = function(p)
    local source = sources[p]
    if not source then
        return nil, 'not found: ' .. tostring(p)
    end
    return load(source, '@' .. tostring(p))
end
fs = {
    getDir = function(p)
        return (tostring(p):match('^(.*)/[^/]*$')) or ''
    end,
    combine = function(a, b)
        a = tostring(a)
        if a == '' or a == '/' then
            return '/' .. tostring(b)
        end
        return a .. '/' .. tostring(b)
    end,
    exists = function(p) return sources[p] ~= nil end,
}
shell = { getRunningProgram = function() return 'IFMWorker.lua' end }
term = { clear = function() end, setCursorPos = function() end }
colors = setmetatable({}, { __index = function() return 1 end })
print = function() end

-- ===== 把 worker 当成真程序跑起来 =====
-- 版本号从 modules/transfer.lua 读（唯一来源）：以前这里写死 '1.8.0'，
-- 一升版本就整片测试假装失败（版本闸门把任务全拒了，看起来像 worker 坏了）。
local __transferChunk = loadfile('/modules/transfer.lua')
__version = __transferChunk and __transferChunk().VERSION or '0.0.0'
local chunk, loadErr = loadfile('IFMWorker.lua')
check('IFMWorker.lua loads in a real Lua VM', chunk ~= nil, tostring(loadErr))

local worker = coroutine.create(function()
    return chunk()
end)

--- 喂一个事件给 worker（和 CC:T 的主机把事件交给程序完全一样）
local function feed(event, p1, p2, p3, p4, p5)
    local ok, err = coroutine.resume(worker, event, p1, p2, p3, p4, p5)
    if not ok then
        error('worker crashed while handling ' .. tostring(event) .. ': ' .. tostring(err) ..
            '\n' .. debug.traceback(worker, tostring(err)), 0)
    end
end
--- 用户第 1 项：任务**一律**以 { op = "jobs", jobs = {...} } 信封下发（即使只有 1 条任务）——
--- worker 已经拒收单条任务报文，所以驱动器必须按主控的真实形状发（否则测的就不是真协议）。
local function deliver(message)
    local op = type(message) == 'table' and message.op or nil
    if op == 'job' or op == 'query' or op == 'detail' then
        message = {
            proto = 'ifm_transfer', op = 'jobs', sender = message.sender, version = message.version,
            target = message.target, jobs = { message },
        }
    end
    feed('modem_message', 'back', 41000, 41000, message, 0)
end



--- 走一个"定时器 tick"（worker 的 tick 认 token，所以要给当前 token）
local function timerTick()
    __advance(600)
    feed('timer', __timerToken())
end

--- 最近一条 op 等于给定值的消息
local function lastMessage(op)
    for i = #__sent, 1, -1 do
        if type(__sent[i]) == 'table' and __sent[i].op == op then
            return __sent[i]
        end
    end
    return nil
end

--- 统计某个 op 的消息条数
local function countMessages(op)
    local n = 0
    for _, message in ipairs(__sent) do
        if type(message) == 'table' and message.op == op then
            n = n + 1
        end
    end
    return n
end

--- 用户第 3 项：任务结果现在打包在 { op = "results", results = {...} } 里 —— 最近一条信封的内容
local function lastResults()
    for i = #__sent, 1, -1 do
        local message = __sent[i]
        if type(message) == 'table' and message.op == 'results' then
            return message.results
        end
    end
    return nil
end

--- 最近一条（信封里的）指定 op 的结果
local function lastResult(op)
    local results = lastResults()
    if not results then
        return nil
    end
    for i = #results, 1, -1 do
        if type(results[i]) == 'table' and results[i].op == op then
            return results[i]
        end
    end
    return nil
end

--- 统计所有信封里的结果条数（op 为 nil 时数全部）
local function countResults(op)
    local n = 0
    for _, message in ipairs(__sent) do
        if type(message) == 'table' and message.op == 'results' then
            for _, entry in ipairs(message.results or {}) do
                if op == nil or entry.op == op then
                    n = n + 1
                end
            end
        end
    end
    return n
end

-- 启动：worker 起来就广播 hello（带版本与并发槽位）
feed('__boot')
local hello = lastMessage('hello')
check('the worker announces itself with hello', hello ~= nil and hello.version == __version,
    hello and tostring(hello.version))

-- 主控 hello → worker 回 pong
timerTick()
feed('modem_message', 'back', 41000, 41000, {
    proto = 'ifm_transfer', op = 'hello', from = 1, master = true,
}, 0)
local pong = lastMessage('pong')
check('the worker answers the master hello with a pong that carries version + slots',
    pong ~= nil and pong.version == __version and tonumber(pong.slots) and tonumber(pong.slots) >= 1,
    pong and ('version=' .. tostring(pong.version) .. ' slots=' .. tostring(pong.slots)))

-- ===== 并行：两条搬运任务在同一个事件循环里同时等游戏刻 =====
local function job(id, from, to, limit)
    return {
        proto = 'ifm_transfer', op = 'job', from = 1, sender = 1, version = __version,
        target = 9, id = id, action = 'push_item', from = from, to = to,
        fromSlot = 1, limit = limit,
    }
end

deliver(job(1, 'chest_1', 'chest_2', 4))
deliver(job(2, 'chest_1', 'chest_2', 8))
check('two moves are in flight at the same time (tasks really run in parallel)',
    __pushing == 2, 'pushing=' .. tostring(__pushing))
check('no result is sent before the peripheral call finishes',
    countResults('done') == 0 and countResults('error') == 0,
    'done=' .. tostring(countResults('done')))
check('both pushItems were really issued (the second did not wait for the first)',
    #__pushes == 2, 'pushes=' .. tostring(#__pushes))

-- 一个事件就可以让所有在等的外设调用继续（CC:T 的完成事件是给所有协程的）
feed('__complete')
check('the slots are released again', __pushing == 0, 'pushing=' .. tostring(__pushing))
-- 用户第 3 项：两条任务在同一 tick 结束 → 结果先入箱，tick 末**打包成一条** modem 报文发出
local envelopesBefore = countMessages('results')
timerTick()
check('both finished tasks are packed into ONE results envelope (one modem send per tick)',
    countResults('done') == 2 and countMessages('results') == envelopesBefore + 1,
    'envelopes=+' .. tostring(countMessages('results') - envelopesBefore) ..
        ' done=' .. tostring(countResults('done')))

-- 状态上报：空闲、并发上限 64
__advance(2000)
timerTick()
local state = lastMessage('state')
check('state reports the parallel slots and an idle table',
    state ~= nil and tonumber(state.slots) == 64 and tonumber(state.load) == 0 and state.busy == false,
    state and ('slots=' .. tostring(state.slots) .. ' load=' .. tostring(state.load) ..
        ' busy=' .. tostring(state.busy)))
-- 本轮第 6 项：任务很短，只报"上报这一刻"的条数永远是 0（网页就成了"永远空闲、负载 0/64"）。
-- 上面两条搬运是并行跑完的 → 这一秒的峰值必须是 2（这就是网页负载条用的数）。
check('state also reports the peak concurrency of that second (so the UI does not always show 0)',
    state ~= nil and tonumber(state.peak) == 2,
    state and ('peak=' .. tostring(state.peak)))

-- ===== 只有任务表"满"了才算忙 =====
local before = #__pushes
for i = 1, 64 do
    deliver(job(100 + i, 'chest_1', 'chest_2', 1))
end
check('64 tasks are accepted and running in parallel', __pushing == 64,
    'pushing=' .. tostring(__pushing) .. ' pushes=' .. tostring(#__pushes - before))

__advance(2000)
timerTick()
local fullState = lastMessage('state')
check('while the table is full the worker reports busy with load=64',
    fullState ~= nil and fullState.busy == true and tonumber(fullState.load) == 64,
    fullState and ('load=' .. tostring(fullState.load) .. ' busy=' .. tostring(fullState.busy)))

local pushesBefore = #__pushes
deliver(job(999, 'chest_1', 'chest_2', 1))
local busy = lastMessage('busy')
check('a 65th task is refused with busy (the master uses another worker / runs it itself)',
    busy ~= nil and tonumber(busy.id) == 999 and #__pushes == pushesBefore,
    'busy=' .. tostring(busy and busy.id) .. ' newPushes=' .. tostring(#__pushes - pushesBefore))

-- 一个事件把 64 条任务一起放行；结果先入箱，tick 末**一次**发出（用户第 3 项）
feed('__complete')
local envelopesBefore64 = countMessages('results')
timerTick()
local doneCount = countResults('done')
check('all 64 tasks finish when the tick completes and the table is empty again',
    doneCount == 66 and __pushing == 0,
    'done=' .. tostring(doneCount) .. ' pushing=' .. tostring(__pushing))
check('66 results leave as ONE envelope (not 66 separate modem sends)',
    countMessages('results') == envelopesBefore64 + 1,
    'envelopes=+' .. tostring(countMessages('results') - envelopesBefore64))

__advance(2000)
timerTick()
local idleState = lastMessage('state')
check('the worker is idle again after the batch (load=0, busy=false)',
    idleState ~= nil and tonumber(idleState.load) == 0 and idleState.busy == false,
    idleState and ('load=' .. tostring(idleState.load) .. ' busy=' .. tostring(idleState.busy)))

-- ===== 打包的作业报文（用户第 3 项：事件越少越好）=====
-- 主控一个 tick 里发给同一台 worker 的多条作业会打包成一条 { op = "jobs", jobs = {...} }。
-- 这里验证 worker 收到一条 jobs 报文后：每条各起一个协程（并行）、各自回报结果。
local batchedDoneBefore = countResults('done')
feed('modem_message', 'back', 41000, 41000, {
    op = 'jobs',
    jobs = { job(9001, 'chest_1', 'chest_2', 2), job(9002, 'chest_1', 'chest_2', 3) },
}, 0)
check('one jobs message starts every job inside it (1 event, 2 parallel tasks)',
    __pushing == 2, 'pushing=' .. tostring(__pushing))
local batchedEnvelopesBefore = countMessages('results')
feed('__complete')
timerTick()
check('both batched jobs report their own result (2 results in ONE envelope)',
    countResults('done') == batchedDoneBefore + 2 and
        countMessages('results') == batchedEnvelopesBefore + 1,
    'done=+' .. tostring(countResults('done') - batchedDoneBefore) ..
        ' envelopes=+' .. tostring(countMessages('results') - batchedEnvelopesBefore))

-- ===== 用户第 1 项：按外设类型决定"谁动手"（海龟只能由对面容器 pull）=====
-- 海龟不是 inventory 外设 —— 对它调用 pushItems/pullItems 是白费（现场那行
-- `attempt to call a nil value` 就是这么来的）。主控按类型把 job.actor 设成 "to"，
-- worker 就只调 **目标侧** 的 pullItems(turtle, …)，一次调用、不试错。
local pullsBefore = #__pulls
local pushesBeforeTurtle = #__pushes
local turtleJob = job(9100, 'turtle_9', 'chest_2', 5)
turtleJob.actor = 'to'
--- 用户第 2 项：pullItems 的源槽位是必填的 —— 主控先向海龟要过物品栏上报，这里带上具体槽位
turtleJob.fromSlot = 3
__pullReturn = 3
deliver(turtleJob)
check('actor="to" calls pullItems on the container side (never on the turtle)',
    #__pulls == pullsBefore + 1 and #__pushes == pushesBeforeTurtle,
    'pulls=+' .. tostring(#__pulls - pullsBefore) .. ' pushes=+' .. tostring(#__pushes - pushesBeforeTurtle))
local pull = __pulls[#__pulls]
check('the pull asks the right container to pull from the turtle (with the reported slot)',
    pull ~= nil and pull.to == 'chest_2' and pull.from == 'turtle_9' and tonumber(pull.limit) == 5 and
        tonumber(pull.slot) == 3,
    pull and ('to=' .. tostring(pull.to) .. ' from=' .. tostring(pull.from) ..
        ' limit=' .. tostring(pull.limit) .. ' slot=' .. tostring(pull.slot)))
feed('__complete')
timerTick()
local turtleDone = lastResult('done')
check('the pulled amount is reported back to the master (moved=3)',
    turtleDone ~= nil and tonumber(turtleDone.id) == 9100 and tonumber(turtleDone.moved) == 3,
    turtleDone and ('id=' .. tostring(turtleDone.id) .. ' moved=' .. tostring(turtleDone.moved)))

-- 反例：源是海龟、actor 却是 "from"（老主控）→ 不再"换一种方法重试"，而是明确报出原因
__pullReturn = 0
local badJob = job(9101, 'turtle_9', 'chest_2', 5)
badJob.actor = nil
deliver(badJob)
feed('__complete')
timerTick()
local badResult = lastResult('error') or lastResult('done')
check('a missing method is reported as-is (no silent fallback)',
    badResult ~= nil and tostring(badResult.reason or badResult.error or ''):find('pushItems', 1, true) ~= nil,
    badResult and tostring(badResult.reason or badResult.error))

-- 用户第 2 项：主控还没拿到海龟的物品栏上报时（fromSlot 缺失）**不派活**：
-- pullItems 的槽位参数必填，派出去只会得到 "bad argument #2 (number expected, got nil)"。
local pullsBeforeNoSlot = #__pulls
local noSlotJob = job(9102, 'turtle_9', 'chest_2', 5)
noSlotJob.actor = 'to'
noSlotJob.fromSlot = nil
deliver(noSlotJob)
feed('__complete')
timerTick()
local noSlotResult = lastResult('error') or lastResult('done')
check('a pull without a source slot is refused with a readable reason',
    #__pulls == pullsBeforeNoSlot and noSlotResult ~= nil and
        tostring(noSlotResult.reason or noSlotResult.error or ''):find('source slot', 1, true) ~= nil,
    noSlotResult and tostring(noSlotResult.reason or noSlotResult.error))

--- 用户第 1 项：任务**只**走 { op = "jobs" } 信封 —— 单条任务报文必须被拒收（不执行、不回报）
do
    local singleBefore = countResults('done') + countResults('error')
    local pushesBeforeSingle = #__pushes
    feed('modem_message', 'back', 41000, 41000, {
        proto = 'ifm_transfer', op = 'job', from = 1, sender = 1, version = __version,
        target = 9, id = 9500, action = 'push_item', from = 'chest_1', to = 'chest_2',
        fromSlot = 1, limit = 1,
    }, 0)
    feed('__complete')
    timerTick()
    check('a single-task message is refused (tasks must come as a jobs envelope)',
        #__pushes == pushesBeforeSingle and
            (countResults('done') + countResults('error')) == singleBefore,
        'pushes=+' .. tostring(#__pushes - pushesBeforeSingle) ..
            ' results=+' .. tostring(countResults('done') + countResults('error') - singleBefore))
    --- 反向确认：同一条任务装进信封就能跑（哪怕信封里只有它一条）
    deliver({
        proto = 'ifm_transfer', op = 'job', from = 1, sender = 1, version = __version,
        target = 9, id = 9501, action = 'push_item', from = 'chest_1', to = 'chest_2',
        fromSlot = 1, limit = 1,
    })
    feed('__complete')
    timerTick()
    check('the same task inside a one-task envelope runs normally',
        #__pushes == pushesBeforeSingle + 1,
        'pushes=+' .. tostring(#__pushes - pushesBeforeSingle))
end

report('')
report('info: IFMWorker parallel-task drive test finished (passed=' .. passed .. ', failed=' .. failed .. ')')
return passed, failed
