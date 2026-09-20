// IFM :: tools/run_module_tests.js
// 模块自测（Node + fengari：在 JS 里跑真正的 Lua 5.3 虚拟机，加载 modules/*.lua 跑断言）。
//     node tools/run_module_tests.js
//
// 为什么要有它：调度器（dispatch.lua）与容器快照（containers.lua）是 1.7.0 的核心，
// 但它们跑在 CC:T 里、只能靠游戏内实测 —— 这个脚本把这两个模块原样加载进真 Lua 虚拟机，
// 用桩（stub）替换外设/存储，断言那些一眼看不出、错了却很难查的不变量：
//   * 队列轮转公平 / 时间片 / 失败回队尾 / 失败丢弃 / 同 key 去重 / 在飞；
//   * 有 worker 且全忙 → 不推进；没有 worker → 每次调度只推进一步；能力门控；
//   * 快照：出库预留不会超发、结算按实际搬运量归还、扫描只清理"结算早于扫描"的变更、按轮次判新鲜度。
//
// 只依赖 fengari（npm install fengari --no-save）+ luaparse（语法检查用）。
'use strict';

const fs = require('fs');
const path = require('path');

let fengari;
try {
    fengari = require('fengari');
} catch (err) {
    console.error('missing dependency: fengari (run: npm install fengari --no-save)');
    process.exit(2);
}
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari;

const backendDir = path.join(__dirname, '..');
const moduleDir = path.join(backendDir, 'modules');

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);

function fail(message) {
    console.error('ERROR: ' + message);
    process.exit(1);
}

// 极小的 CC:T 环境桩：os.epoch（确定性的假时钟）/ os.startTimer / http / textutils
const prelude = `
local __now = 1700000000000
os.epoch = function() __now = __now + 50; return __now end
os.startTimer = function() return 1 end
os.cancelTimer = function() end
os.getComputerID = function() return 1 end
os.getComputerLabel = function() return nil end
__out = ''
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    __out = __out .. table.concat(parts, ' ') .. '\\n'
end
-- 协议层用到的 CC:T API 桩（只在测试里用）
__wsRequests = 0
__nowAdvance = function(ms) __now = __now + (tonumber(ms) or 0) end
http = {
    websocketAsync = function() __wsRequests = __wsRequests + 1; return true end,
}
textutils = {
    serializeJSON = function() return '{}' end,
    unserializeJSON = function() return {} end,
}
`;
if (lauxlib.luaL_loadstring(L, to_luastring(prelude)) !== lua.LUA_OK ||
    lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
    fail('prelude: ' + to_jsstring(lua.lua_tostring(L, -1)));
}

// 把模块源码包成 (function() ... end)() 并挂到全局，便于测试代码直接用
function loadModuleAs(name, file) {
    const source = fs.readFileSync(path.join(moduleDir, file), 'utf8');
    const chunk = `${name} = (function()\n${source}\nend)()`;
    if (lauxlib.luaL_loadstring(L, to_luastring(chunk)) !== lua.LUA_OK) {
        fail(file + ' load: ' + to_jsstring(lua.lua_tostring(L, -1)));
    }
    if (lua.lua_pcall(L, 0, 0, 0) !== lua.LUA_OK) {
        fail(file + ' run: ' + to_jsstring(lua.lua_tostring(L, -1)));
    }
}
loadModuleAs('DispatchModule', 'dispatch.lua');
loadModuleAs('ContainersModule', 'containers.lua');
loadModuleAs('ProtocolModule', 'protocol.lua');
loadModuleAs('QueueModule', 'queue.lua');
loadModuleAs('TransferModule', 'transfer.lua');
loadModuleAs('StoreModule', 'store.lua');
loadModuleAs('RecipeModule', 'recipe.lua');

const tests = fs.readFileSync(path.join(__dirname, 'module_tests.lua'), 'utf8');
// 用 xpcall(debug.traceback) 包一层：出错时能看到 Lua 侧的调用栈（哪个函数、哪一行）
const wrapped = 'local __ok, __err = xpcall(function()\n' + tests +
    '\nend, debug.traceback)\nif not __ok then error(__err, 0) end';
if (lauxlib.luaL_loadstring(L, to_luastring(wrapped)) !== lua.LUA_OK) {
    fail('module_tests.lua load: ' + to_jsstring(lua.lua_tostring(L, -1)));
}
const ran = lua.lua_pcall(L, 0, 0, 0);
function dumpOut() {
    lua.lua_getglobal(L, to_luastring('__out'));
    const text = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_pop(L, 1);
    if (text) process.stdout.write(text);
}
if (ran !== lua.LUA_OK) {
    dumpOut();
    const message = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_pop(L, 1);
    console.error('LUA ERROR: ' + message);
    lauxlib.luaL_traceback(L, L, to_luastring(message), 0);
    console.error(to_jsstring(lua.lua_tostring(L, -1)));
    lua.lua_pop(L, 1);
    process.exit(1);
}

lua.lua_getglobal(L, to_luastring('__out'));
const out = to_jsstring(lua.lua_tostring(L, -1));
lua.lua_pop(L, 1);
process.stdout.write(out);

// ===== 入口脚本语法检查（用户第 4 项时加上）=====
// 为什么需要它：fengari 只能加载"能安全执行"的模块 —— IFMMaster.lua / IFMWorker.lua /
// IFMCrafter.lua 一加载就会真的跑起来（连中继、开 modem），所以只能做**语法**检查。
// 现场教训：IFMCrafter.lua 里 `local event, param1, param2, param4 = os.pullEvent()` 只是少接了
// 两个返回值（param4 拿到的是 replyChannel，不是 message），不报错、不崩溃，只是"所有主控消息
// 被静默丢掉" —— 合成器永远收不到 craft。语法检查能拦住拼写/结构问题，配合人工复查才完整。
// 注意：字符串里的 `\uXXXX` 是给浏览器解码的字面转义（CC:T 的 Lua 不认它），Lua 5.x 的语法检查
// 会因此报 invalid escape sequence —— 先把 "\u" 换成 "x" 再解析。
(function checkEntryScriptSyntax() {
    let luaparse = null;
    try {
        luaparse = require('luaparse');
    } catch (err) {
        console.log('note: luaparse is missing - the entry script syntax check was skipped');
        return;
    }
    const backslash = String.fromCharCode(92);
    const entries = ['IFMMaster.lua', 'IFMWorker.lua', 'IFMCrafter.lua'];
    let bad = 0;
    entries.forEach(function (name) {
        const file = path.join(__dirname, '..', name);
        let source = '';
        try {
            source = fs.readFileSync(file, 'utf8');
        } catch (err) {
            bad += 1;
            console.error('  FAIL syntax: cannot read ' + name + ' -> ' + err.message);
            return;
        }
        try {
            luaparse.parse(source.split(backslash + 'u').join('x'), { luaVersion: '5.3' });
            console.log('  ok   syntax: ' + name);
        } catch (err) {
            bad += 1;
            console.error('  FAIL syntax: ' + name + ' -> ' + err.message);
        }
    });
    if (bad > 0) {
        console.error('entry script(s) with a syntax error: ' + bad);
        process.exit(1);
    }
}());

const failed = /FAIL/.test(out);
const passed = (out.match(/^  ok /gm) || []).length;
console.log('\n' + passed + ' passed, ' + (failed ? 'some FAILED' : '0 failed'));
process.exit(failed ? 1 : 0);
