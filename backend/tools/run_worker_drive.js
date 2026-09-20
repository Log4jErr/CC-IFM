// 模块自测（Node + fengari）：把 IFMWorker.lua 原样加载进真 Lua 虚拟机，
// 用一套极小的 CC:T 环境桩（事件循环 / modem / 容器外设）驱动它，验证 1.8.0 的并行任务表：
//   * 同一个事件循环里多条任务同时在跑（不是一条做完才做下一条）；
//   * worker 只在任务表**满**（MAX_TASKS）时才回 busy；
//   * 每条任务跑完都把结果回给主控，槽位正确释放；
//   * list / pushItems 这类"要等 1 个游戏刻"的外设调用在协程里并行（与 CC:T parallel 同一原理）。
// 为什么值得单独测：worker 跑在别的计算机上，这类调度错误在游戏里只表现为"worker 看起来空闲、
// 什么都不做"，很难查。
//
// 运行：node backend/tools/run_worker_drive.js（需要 fengari：npm install fengari --no-save）

const fs = require('fs');
const path = require('path');

let fengari;
try {
    fengari = require('fengari');
} catch (err) {
    console.error('missing dependency: fengari (run: npm install fengari --no-save)');
    process.exit(1);
}

const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;
const backendDir = path.join(__dirname, '..');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

const failures = [];
const notes = [];

// ---- CC:T 环境桩（Lua 侧）：事件循环、modem、容器外设 ----
const prelude = String.raw`
local __now = 1700000000000
local __timer = 0
local __peripheralWaiters = 0
__sent = {}            -- 收到的所有 modem 广播（主控那边看到的东西）
__pushes = {}          -- 每次 pushItems 调用：{ from, slot, limit, to }
__pulls = {}           -- 每次 pullItems 调用：{ to = 动手方, from = 被拉的一方, slot, limit }
__pullReturn = 0       -- 下一次 pullItems 返回多少（用户第 1 项：海龟只能由对面容器 pull）
__pushing = 0          -- 现在有多少个 pushItems 正在"等游戏刻"（并行度的直接证据）
__listCalls = 0

os.epoch = function() __now = __now + 1; return __now end
os.startTimer = function() __timer = __timer + 1; return __timer end
os.cancelTimer = function() end
os.getComputerID = function() return 9 end
os.sleep = function() coroutine.yield('sleep') end
__advance = function(ms) __now = __now + (tonumber(ms) or 0) end
__pendingPeripheral = function() return __peripheralWaiters end
__timerToken = function() return __timer end

--- CC:T 的 os.pullEvent：让出当前协程，等驱动端把事件喂回来（和真机一样的语义）
os.pullEvent = function(filter)
    while true do
        local e, p1, p2, p3, p4, p5 = coroutine.yield('pull')
        if filter == nil or e == filter then
            return e, p1, p2, p3, p4, p5
        end
    end
end

--- 外设调用桩：每次调用等一个事件（模拟"要 1 个游戏刻"）
local function waitTick()
    __peripheralWaiters = __peripheralWaiters + 1
    os.pullEvent('__complete')
    __peripheralWaiters = __peripheralWaiters - 1
end

--- 容器外设：pushItems 等 1 刻后搬走 moved 个；list 立刻返回一个栈
local function makeChest(name, moved)
    local chest = { name = name }
    function chest.list()
        __listCalls = __listCalls + 1
        waitTick()
        return { [1] = { name = 'minecraft:iron_ingot', count = 64 } }
    end
    function chest.pushItems(target, fromSlot, limit, toSlot)
        __pushing = __pushing + 1
        __pushes[#__pushes + 1] = { from = name, to = target, slot = fromSlot, limit = limit }
        waitTick()
        __pushing = __pushing - 1
        return math.min(tonumber(moved) or 0, tonumber(limit) or 0)
    end
    function chest.pullItems(source, fromSlot, limit, toSlot)
        --- 用户第 1 项：目标侧的 pullItems 是搬"非 inventory 的源"（海龟）的唯一办法
        __pulls[#__pulls + 1] = { to = name, from = source, slot = fromSlot, limit = limit }
        waitTick()
        return math.min(tonumber(__pullReturn) or 0, tonumber(limit) or 0)
    end
    return chest
end

--- 海龟（turtle）：**没有** inventory 方法 —— 对它调用 pushItems/pullItems 就是 nil
--- （这正是现场那行 "attempt to call a nil value" 的来源）。
local function makeTurtle(name)
    local turtle = { name = name }
    function turtle.getFuelLevel() return 100 end
    return turtle
end

local peripherals = {
    ['back'] = { name = 'back', kind = 'modem' },       -- 有线 modem
    ['chest_1'] = { name = 'chest_1', kind = 'inventory' },
    ['chest_2'] = { name = 'chest_2', kind = 'inventory' },
    ['turtle_9'] = { name = 'turtle_9', kind = 'turtle' },
}
__chests = { chest_1 = makeChest('chest_1', 4), chest_2 = makeChest('chest_2', 64),
    turtle_9 = makeTurtle('turtle_9') }

peripheral = {}
function peripheral.getNames()
    local names = {}
    for name in pairs(peripherals) do names[#names + 1] = name end
    table.sort(names)
    return names
end
function peripheral.getType(name)
    local entry = peripherals[name]
    return entry and entry.kind or nil
end
function peripheral.hasType(name, kind)
    local entry = peripherals[name]
    return (entry and entry.kind == kind) or false
end
function peripheral.getName(value)
    return type(value) == 'table' and value.name or nil
end
function peripheral.wrap(name)
    local entry = peripherals[name]
    if not entry then return nil end
    if entry.kind == 'modem' then
        return {
            name = name,
            isWireless = function() return false end,
            open = function() return true end,
            close = function() return true end,
            transmit = function(channel, replyChannel, message)
                __sent[#__sent + 1] = message
                return true
            end,
        }
    end
    return __chests[name]
end
function peripheral.find(kind)
    for name, entry in pairs(peripherals) do
        if entry.kind == kind then return peripheral.wrap(name), name end
    end
    return nil, nil
end
`;

const modules = {
    'modems.lua': fs.readFileSync(path.join(backendDir, 'modules', 'modems.lua'), 'utf8'),
    'peripherals.lua': fs.readFileSync(path.join(backendDir, 'modules', 'peripherals.lua'), 'utf8'),
    'transfer.lua': fs.readFileSync(path.join(backendDir, 'modules', 'transfer.lua'), 'utf8'),
};
const workerSource = fs.readFileSync(path.join(backendDir, 'IFMWorker.lua'), 'utf8');

// __report：测试脚本用它打印（worker 自己的 print 会被静音）
const reportLines = [];
lua.lua_pushjsfunction(L, function () {
    reportLines.push(to_jsstring(lua.lua_tostring(L, 1)) || '');
    return 0;
});
lua.lua_setglobal(L, to_luastring('__report'));

function toLuaPath(p) {
    return String(p).replace(/^\/+/, '').replace(/\\/g, '/');
}

// __read / __exists：worker 里的 loadfile(path) 走这里（path 形如 /modules/modems.lua）
lua.lua_pushjsfunction(L, function () {
    const requested = toLuaPath(to_jsstring(lua.lua_tostring(L, 1)) || '');
    const file = path.join(backendDir, requested);
    let source = null;
    if (requested.indexOf('modules/') === 0) {
        const name = requested.slice('modules/'.length);
        source = modules[name] !== undefined ? modules[name] : null;
    } else if (requested === 'IFMWorker.lua') {
        source = workerSource;
    }
    if (source === null) {
        lua.lua_pushnil(L);
        return 1;
    }
    lua.lua_pushstring(L, to_luastring(source));
    return 1;
});
lua.lua_setglobal(L, to_luastring('__read'));

// 先跑 CC:T 环境桩，再跑测试脚本（桩里没有 JS 函数依赖：协程里不能调 JS 函数）
const preludeResult = lauxlib.luaL_loadstring(L, to_luastring(prelude));
if (preludeResult !== lua.LUA_OK) {
    console.error('prelude failed: ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
}
if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    console.error('prelude error: ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
}

const driverSource = fs.readFileSync(path.join(__dirname, 'worker_drive.lua'), 'utf8');
if (lauxlib.luaL_loadstring(L, to_luastring(driverSource)) !== lua.LUA_OK) {
    console.error('worker_drive.lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
}
const ran = lua.lua_pcall(L, 0, 2, 0);
reportLines.forEach(function (line) { console.log(line); });
if (ran !== lua.LUA_OK) {
    console.error('ERROR: ' + to_jsstring(lua.lua_tostring(L, -1)));
    process.exit(1);
}
const passed = lua.lua_tointeger(L, -2);
const failed = lua.lua_tointeger(L, -1);
console.log('');
console.log(passed + ' passed, ' + (failed > 0 ? failed + ' failed' : '0 failed'));
process.exit(failed > 0 ? 1 : 0);
