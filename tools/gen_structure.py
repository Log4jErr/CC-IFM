import ast
import io
import os
import re
import time

R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(R, "PROJECT_STRUCTURE.md")


def read(path):
    return io.open(path, encoding="utf-8").read()


def balanced_args(text, open_index):
    depth = 0
    index = open_index
    while index < len(text):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
        index += 1
    return text[open_index + 1:]


def sanitize(args):
    text = args.replace("{", "(").replace("}", ")").replace(";", ",").replace('"', "'")
    return re.sub(r"\s+", " ", text).strip()


def sanitize_name(name):
    cleaned = re.sub(r"[^A-Za-z0-9_]", "_", name)
    if not cleaned:
        cleaned = "unnamed"
    if cleaned[0].isdigit():
        cleaned = "_" + cleaned
    return cleaned


LUA_DECL = re.compile(r"^[ \t]*(local[ \t]+)?function[ \t]+([A-Za-z_][\w.:]*)[ \t]*\(", re.M)
LUA_ASSIGN = re.compile(
    r"^[ \t]*(local[ \t]+)?([A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*|\[[^\]]+\]))[ \t]*=[ \t]*function[ \t]*\(", re.M)
LUA_BARE = re.compile(r"^[ \t]*(local[ \t]+)?([A-Za-z_][\w]*)[ \t]*=[ \t]*function[ \t]*\(", re.M)
JS_DECL = re.compile(r"^[ \t]*function[ \t]+([A-Za-z_$][\w$]*)[ \t]*\(", re.M)
JS_ASSIGN = re.compile(r"^[ \t]*(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*function[ \t]*\(", re.M)
JS_MEMBER = re.compile(r"^[ \t]*([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+)[ \t]*=[ \t]*function[ \t]*\(", re.M)
JS_METHOD = re.compile(r"^[ \t]*([A-Za-z_$][\w$]*)[ \t]*:[ \t]*function[ \t]*\(", re.M)
PY_DECL = re.compile(r"^[ \t]*def[ \t]+([A-Za-z_]\w*)[ \t]*\(", re.M)


def lua_name(raw):
    if ":" in raw:
        return raw.split(":", 1)[1], True
    if raw.endswith("]"):
        inner = raw[raw.index("[") + 1:-1].strip()
        return inner.strip("'\""), False
    return raw.split(".")[-1], False


def extract(path):
    text = read(path)
    ext = os.path.splitext(path)[1]
    found = []
    if ext == ".lua":
        for match in LUA_DECL.finditer(text):
            name, _ = lua_name(match.group(2))
            found.append((match.start(), name, balanced_args(text, match.end() - 1), bool(match.group(1))))
        for match in LUA_ASSIGN.finditer(text):
            name, _ = lua_name(match.group(2))
            found.append((match.start(), name, balanced_args(text, match.end() - 1), bool(match.group(1))))
        for match in LUA_BARE.finditer(text):
            found.append((match.start(), match.group(2), balanced_args(text, match.end() - 1),
                          bool(match.group(1))))
    elif ext == ".js":
        for pattern in (JS_DECL, JS_ASSIGN, JS_MEMBER, JS_METHOD):
            for match in pattern.finditer(text):
                name = match.group(1).split(".")[-1]
                found.append((match.start(), name, balanced_args(text, match.end() - 1), False))
    elif ext == ".py":
        tree = ast.parse(text)
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                found.append((node.lineno, node.name, ast.unparse(node.args), node.name.startswith("_")))
    found.sort(key=lambda item: item[0])
    return text, found


def class_name(path):
    base = os.path.splitext(os.path.basename(path))[0]
    return re.sub(r"[^A-Za-z0-9_]", "_", base)


def class_diagram(path, items):
    lines = ["```mermaid", "classDiagram", "class %s {" % class_name(path)]
    for _, name, args, is_local in items:
        lines.append("  %s%s(%s)" % ("-" if is_local else "+", sanitize_name(name), sanitize(args)))
    lines.append("}")
    lines.append("```")
    return "\n".join(lines)


def collect_files():
    backend = os.path.join(R, "backend")
    files = []
    for name in sorted(os.listdir(backend)):
        if name.endswith(".lua") and name != "ifm_bundle.lua":
            files.append(os.path.join(backend, name))
    for sub in ("modules", "tools"):
        folder = os.path.join(backend, sub)
        for name in sorted(os.listdir(folder)):
            if name.endswith(".lua"):
                files.append(os.path.join(folder, name))
    web = os.path.join(R, "frontend", "web")
    for name in sorted(os.listdir(web)):
        if name.endswith(".js"):
            files.append(os.path.join(web, name))
    files.append(os.path.join(backend, "build.py"))
    files.append(os.path.join(R, "frontend", "serve.py"))
    return files


def ops_of(path):
    return sorted(set(re.findall(r'op\s*==\s*"([a-z_]+)"', read(path))))


def transfer_const(name):
    text = read(os.path.join(R, "backend", "modules", "modems.lua"))
    match = re.search(r"Modems\.%s = ([^\n]+)" % name, text)
    if not match:
        return "?"
    return match.group(1).strip().strip('"')


def load_module_edges(path):
    return sorted(set(re.findall(r'loadModule\(\s*"([a-z0-9_]+)"\s*\)', read(path))))


def frontend_order():
    html = read(os.path.join(R, "frontend", "index.html"))
    return re.findall(r'<script[^>]*src="(?:web/|dist/)([^"?]+)', html)


def build_markdown():
    files = collect_files()
    transfer_path = os.path.join(R, "backend", "modules", "transfer.lua")
    version = re.search(r'Transfer\.VERSION = "([^"]+)"', read(transfer_path)).group(1)
    parsed = []
    total = 0
    for path in files:
        text, items = extract(path)
        parsed.append((path, text.count("\n") + 1, items))
        total += len(items)

    out = []
    out.append("# CC-IFM 项目结构图")
    out.append("")
    out.append("版本 **%s** · 生成时间 %s · 源文件 %d 个 / 函数原型 %d 个"
               "（不含生成物 `backend/ifm_bundle.lua`）" % (version, time.strftime("%Y-%m-%d %H:%M:%S"),
                                                          len(files), total))
    out.append("")
    out.append("图例：`+` = 模块/全局可见（`function M.foo()`、`function Class:method()`、"
               "`foo = function()`、`function foo() {}`、`def foo()`）；`-` = 文件内私有"
               "（Lua 的 `local function`、Python 的 `_name`）。Lua 的 `Class:method(a)` 在类图中写作 "
               "`+method(a)`（`self` 隐式传入）。前端 10 个 `web/*.js` 由 `index.html` 顺序加载、"
               "共享同一个全局作用域，故每个文件画成一个 class。")
    out.append("§1 运行时架构、§2 模块依赖、§7 模块间接口调用（谁调用了谁的哪些接口）、"
               "§5 每个文件的函数原型、§8 每个文件的函数调用图、§9 外部接口明细表、§10 调用统计。")
    out.append("渲染方式：在 GitHub、VS Code（Markdown 预览 + Mermaid 插件）或 https://mermaid.live "
               "里打开本文件即可。本文件由 `tools/gen_structure.py` 从源码自动生成，"
               "重新生成：`python tools/gen_structure.py`。")
    out.append("")

    out.append("## 1. 运行时总体架构")
    out.append("")
    out.append("```mermaid")
    out.append("flowchart TB")
    out.append('  subgraph PC["浏览器（PC / 手机）"]')
    out.append('    Page["frontend/index.html<br/>web/ifm-*.js（10 个文件，共享全局作用域）"]')
    out.append("  end")
    out.append('  subgraph CC["CC:Tweaked 计算机（同一份产物解压出 ifm/）"]')
    out.append('    Master["ifm/IFMMaster.lua 主控<br/>modules/*.lua"]')
    out.append('    Worker["ifm/IFMWorker.lua 从节点"]')
    out.append('    Crafter["ifm/IFMCrafter.lua 机械臂 / 海龟"]')
    out.append("  end")
    out.append('  Bundle["backend/ifm_bundle.lua<br/>单文件解压器（解压后自删）"]')
    out.append('  Data[("磁盘数据<br/>data/config.json<br/>data/cache.json")]')
    out.append('  Bundle -->|"解压出 IFMMaster / IFMWorker / IFMCrafter / modules"| CC')
    out.append('  Page <-->|"WebSocket 中继<br/>version / snapshot / tasks"| Master')
    out.append('  Master <-->|"modem 通道 %s（%s）"| Worker'
               % (transfer_const("CHANNEL"), transfer_const("PROTOCOL")))
    out.append('  Master <-->|"modem 通道 %s（%s）"| Crafter'
               % (transfer_const("CRAFTER_CHANNEL"), transfer_const("CRAFTER_PROTOCOL")))
    out.append("  Master --- Data")
    out.append('  Master -.->|"外设调用"| Peripherals["peripherals / containers / transfer / recipe"]')
    out.append('  Netserver["tools/netserver.lua<br/>分发服务端（内容哈希变化即 +1）"] -.->|"modem 广播"| '
               'Netsync["tools/netsync.lua<br/>分发客户端"]')
    out.append("```")
    out.append("")

    out.append('## 2. 后端模块依赖（`loadModule("…")`）')
    out.append("")
    out.append("```mermaid")
    out.append("flowchart LR")
    backend_dir = os.path.join(R, "backend")
    targets = [os.path.join(backend_dir, name) for name in sorted(os.listdir(backend_dir))
               if name.endswith(".lua") and name != "ifm_bundle.lua"]
    targets += [os.path.join(backend_dir, "modules", name)
                for name in sorted(os.listdir(os.path.join(backend_dir, "modules")))
                if name.endswith(".lua")]
    for path in targets:
        deps = load_module_edges(path)
        if deps:
            out.append("  %s --> %s" % (class_name(path), " & ".join(deps)))
    out.append("```")
    out.append("")

    out.append("## 3. 前端脚本加载顺序（`index.html`）")
    out.append("")
    out.append("```mermaid")
    out.append("flowchart LR")
    order = frontend_order()
    for index, name in enumerate(order):
        if index:
            out.append("  %s --> %s" % (os.path.splitext(order[index - 1])[0],
                                        os.path.splitext(name)[0]))
    out.append("```")
    out.append("")
    out.append("注：`pinyinlite_full.min.js` 是第三方拼音词典（放在 `frontend/web/dist/`，仓库里没有该文件），"
               "缺失时前端静默降级为中英文关键词匹配。")
    out.append("")

    out.append("## 4. 协议操作（源码里的 `op == \"…\"`）")
    out.append("")
    out.append("| 文件 | 处理的操作 |")
    out.append("| --- | --- |")
    for path in targets:
        ops = ops_of(path)
        if ops:
            out.append("| `%s` | %s |" % (os.path.relpath(path, R).replace("\\", "/"),
                                          ", ".join("`%s`" % op for op in ops)))
    out.append("")

    out.append("## 5. 各文件函数原型")
    out.append("")
    for path, lines, items in parsed:
        rel = os.path.relpath(path, R).replace("\\", "/")
        out.append("### `%s`（%d 行 / %d 个函数）" % (rel, lines, len(items)))
        out.append("")
        out.append(class_diagram(path, items))
        out.append("")

    out.append("## 6. 统计")
    out.append("")
    out.append("| 文件 | 行数 | 函数原型 |")
    out.append("| --- | ---: | ---: |")
    for path, lines, items in parsed:
        out.append("| `%s` | %d | %d |" % (os.path.relpath(path, R).replace("\\", "/"), lines, len(items)))
    out.append("| **合计** | **%d** | **%d** |"
               % (sum(item[1] for item in parsed), total))
    out.append("")

    js_map = {}
    for path in files:
        if path.endswith(".js"):
            _, js_items = extract(path)
            for _, name, _, _ in js_items:
                js_map.setdefault(name, os.path.basename(path))
    js_globals = {}
    for path in files:
        if not path.endswith(".js"):
            continue
        js_text = read(path)
        for match in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)", js_text):
            js_globals.setdefault(match.group(1), os.path.basename(path))
        for match in re.finditer(r"\bwindow\.([A-Za-z_$][\w$]*)\s*=", js_text):
            js_globals.setdefault(match.group(1), os.path.basename(path))

    calls = []
    matrix = {}
    totals_calls = {"intra": 0, "module": 0, "file": 0, "platform": 0, "local": 0, "unresolved": 0}
    for path, source_lines, items in parsed:
        rel = os.path.relpath(path, R).replace("\\", "/")
        own, intra, module_calls, file_calls, counts, unknown = scan_file(path, js_map, js_globals)
        calls.append((rel, items, intra, module_calls, file_calls, counts, unknown))
        caller_module = os.path.splitext(os.path.basename(path))[0]
        for (module, method, _), count in module_calls.items():
            matrix.setdefault((caller_module, module), {})
            matrix[(caller_module, module)][method] = matrix[(caller_module, module)].get(method, 0) + count
        for (target_file, method, _), count in file_calls.items():
            target = os.path.splitext(target_file)[0]
            matrix.setdefault((caller_module, target), {})
            matrix[(caller_module, target)][method] = matrix[(caller_module, target)].get(method, 0) + count
        totals_calls["intra"] += sum(intra.values())
        totals_calls["module"] += sum(module_calls.values())
        totals_calls["file"] += sum(file_calls.values())
        totals_calls["platform"] += counts.get("platform", 0)
        totals_calls["local"] += counts.get("local", 0)
        totals_calls["unresolved"] += sum(unknown.values())

    out.append("## 7. 模块间接口调用关系")
    out.append("")
    out.append("边 = 调用方向；标签 = 被调用的接口（`方法×次数`，最多列出现最多的 6 个）。"
               "后端模块之间的调用与前端文件之间（共享全局作用域）的调用都画在这里；"
               "平台 API、本地对象方法与无法归属的调用不画入（计数见 §10）。")
    out.append("")
    out.append("```mermaid")
    out.append("flowchart LR")
    for (caller, module), methods in sorted(matrix.items()):
        if caller == module:
            continue
        top = sorted(methods.items(), key=lambda pair: (-pair[1], pair[0]))
        label = ", ".join("%s×%d" % pair for pair in top[:6])
        if len(top) > 6:
            label += ", …共 %d 个" % len(top)
        out.append('  %s -->|"%s"| %s' % (sanitize_name(caller), label, sanitize_name(module)))
    out.append("```")
    out.append("")

    out.append("## 8. 每个文件的函数调用图")
    out.append("")
    out.append("节点 = 该文件声明的函数（原型见 §5），边 = 调用（同一文件内直接连边，"
               "跨模块/跨文件调用连到 `外部:` 节点，标签列出被调接口）；"
               "边上的数字只在调用次数 >1 时显示。同名局部函数（例如同一文件里多个 `onConfirm`）"
               "各占一个节点，调用边按函数名归属。")
    for rel, items, intra, module_calls, file_calls, counts, unknown in calls:
        node_ids = {}
        for index, item in enumerate(items):
            node_ids.setdefault(item[1], "f%d" % index)
        externals = {}
        for (module, method, caller), count in module_calls.items():
            externals.setdefault(module, {}).setdefault(caller, []).append((method, count))
        for (target_file, method, caller), count in file_calls.items():
            externals.setdefault(os.path.splitext(target_file)[0], {}).setdefault(caller, []).append((method, count))
        if not intra and not externals:
            continue
        out.append("")
        out.append("### `%s`" % rel)
        out.append("")
        out.append("```mermaid")
        out.append("flowchart TD")
        for index, item in enumerate(items):
            out.append('  f%d["%s"]' % (index, sanitize_name(item[1])))
        for (caller, callee), count in sorted(intra.items()):
            if caller == callee or caller not in node_ids or callee not in node_ids:
                continue
            if count > 1:
                out.append('  %s -->|"%d"| %s' % (node_ids[caller], count, node_ids[callee]))
            else:
                out.append("  %s --> %s" % (node_ids[caller], node_ids[callee]))
        for module, by_caller in sorted(externals.items()):
            node = "ext_%s" % sanitize_name(module)
            out.append('  %s["外部: %s"]' % (node, module))
            for caller, methods in sorted(by_caller.items()):
                if caller not in node_ids:
                    continue
                names = ", ".join("%s×%d" % pair for pair in sorted(methods)[:4])
                if len(methods) > 4:
                    names += ", …"
                out.append('  %s -->|"%s"| %s' % (node_ids[caller], names, node))
        out.append("```")
    out.append("")

    out.append("## 9. 外部接口调用清单")
    out.append("")
    out.append("每一条「调用方 → 被调模块/文件」的全部接口与次数（§7 的图只画出现最多的 6 个）。")
    out.append("")
    out.append("| 调用方 | 被调模块/文件 | 接口（次数） |")
    out.append("| --- | --- | --- |")
    for (caller, module), methods in sorted(matrix.items()):
        pairs = sorted(methods.items(), key=lambda pair: (-pair[1], pair[0]))
        out.append("| `%s` | `%s` | %s |"
                   % (caller, module, ", ".join("`%s`×%d" % pair for pair in pairs)))
    out.append("")

    out.append("## 10. 调用统计")
    out.append("")
    out.append("| 文件 | 函数 | 同文件调用边 | 跨模块/跨文件接口 | 平台 API | 本地对象方法 | 未归属 |")
    out.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for rel, items, intra, module_calls, file_calls, counts, unknown in calls:
        out.append("| `%s` | %d | %d | %d | %d | %d | %d |"
                   % (rel, len(items), len(intra), len(module_calls) + len(file_calls),
                      counts.get("platform", 0), counts.get("local", 0), sum(unknown.values())))
    out.append("| **合计** | **%d** | **%d** | **%d** | **%d** | **%d** | **%d** |"
               % (sum(len(item[1]) for item in calls), totals_calls["intra"],
                  totals_calls["module"] + totals_calls["file"], totals_calls["platform"],
                  totals_calls["local"], totals_calls["unresolved"]))
    out.append("")
    out.append("归类规则：**同文件调用** = 被调函数在本文件里声明（Lua 的 `local function` / "
               "`Class:method`、JS 的全局函数、Python 的模块函数）；**跨模块/跨文件** = 通过 "
               "`loadModule(\"...\")` 绑定、`Class.new(...)` 实例、`self.<模块名>` 注入的模块方法，"
               "或前端跨文件全局函数调用；**平台 API** = Lua 标准库 + CC:T（fs / shell / peripheral / "
               "turtle / modem…）与浏览器 API（document / Math / WebSocket…）；**本地对象方法** = "
               "局部变量或参数上的方法（`list.map`、`self.log.warn` 等）；**未归属** = 无法判定的少数调用"
               "（不画入图）。内联匿名回调不单独计为函数节点。")
    out.append("")
    return out


def validate(markdown):
    problems = []
    methods = 0
    blocks = re.findall(r"```mermaid\n(.*?)```", "\n".join(markdown), re.S)
    for block in blocks:
        lines = block.split("\n")
        head = lines[0].strip()
        if head == "classDiagram":
            if not any(line.startswith("class ") for line in lines):
                problems.append("classDiagram without class line")
            for line in lines:
                stripped = line.strip()
                if not stripped or stripped.startswith(("classDiagram", "class ", "}")):
                    continue
                if stripped[0] not in "+-#~":
                    problems.append("bad visibility: %r" % stripped)
                    continue
                body = stripped[1:]
                if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*\(.*\)", body):
                    problems.append("bad method line: %r" % stripped)
                    continue
                if "{" in body or "}" in body or ";" in body or '"' in body:
                    problems.append("bad chars in method: %r" % stripped)
                methods += 1
        elif head.startswith("flowchart"):
            for line in lines[1:]:
                stripped = line.strip()
                if not stripped or stripped == "end" or stripped.startswith("subgraph "):
                    continue
                if stripped.count('"') % 2:
                    problems.append("unbalanced quotes: %r" % stripped)
                if stripped.count("[") != stripped.count("]"):
                    problems.append("unbalanced brackets: %r" % stripped)
                if not any(token in stripped for token in ("-->", "---", "-.->", "<-->")) \
                        and "[" not in stripped:
                    problems.append("bad flow line: %r" % stripped)
        else:
            problems.append("unknown mermaid head: %r" % head)
    return len(blocks), methods, problems


# ===== call graph extraction =====



LUA_KEYWORDS = set("""and break do else elseif end false for function if in local nil not or repeat
return then true until while goto self""".split())
JS_KEYWORDS = set("""break case catch class const continue debugger default delete do else export
extends finally for function if import in instanceof new of return static super switch this throw
try typeof var void while with yield async await let null true false undefined then""".split())
PLATFORM = set("""fs shell peripheral rednet colors term textutils parallel sleep print write error
pcall xpcall type tostring tonumber ipairs pairs next select assert rawget rawset rawequal
setmetatable getmetatable unpack require table string math os io debug coroutine utf8 turtle vector
gps http settings commands multishell disk window document console JSON Math Object String Number
Boolean Array Date RegExp Error TypeError RangeError Promise Map Set WeakMap Symbol Reflect
WebAssembly Intl URL URLSearchParams fetch WebSocket Event Node Element HTMLElement Image FileReader
Blob Uint8Array Int8Array Float32Array ArrayBuffer DataView isFinite isNaN parseInt parseFloat
encodeURIComponent decodeURIComponent setTimeout setInterval clearTimeout clearInterval
requestAnimationFrame localStorage sessionStorage navigator location history mermaid bootstrap
jQuery loadfile dofile setfenv getfenv collectgarbage newproxy coroutine.wrap""".split())
MODULE_CLASSES = {"Assert": "assert", "Cache": "cache", "Containers": "containers",
                  "Diagnose": "diagnose", "Dispatch": "dispatch", "Filter": "filter",
                  "JsonFile": "jsonfile", "Modems": "modems", "Peripherals": "peripherals",
                  "Protocol": "protocol", "Queue": "queue", "Recipe": "recipe",
                  "Scheduler": "scheduler", "Store": "store", "Transfer": "transfer", "Util": "util"}
CALL = re.compile(r"(?<![\w.:$])([A-Za-z_$][\w$]*(?:\s*[.:]\s*[A-Za-z_$][\w$]*)*)\s*\(")


def skip_short(segment, index):
    quote = segment[index]
    cursor = index + 1
    while cursor < len(segment):
        if segment[cursor] == "\\":
            cursor += 2
            continue
        if segment[cursor] == quote:
            return cursor + 1
        cursor += 1
    return len(segment)


def mask(segment, ext):
    out = list(segment)
    index = 0
    while index < len(segment):
        char = segment[index]
        if char in "'\"":
            end = skip_short(segment, index)
            for pos in range(index, min(end, len(segment))):
                out[pos] = " "
            index = end
            continue
        if ext == ".lua":
            match = re.match(r"\[(=*)\[", segment[index:])
            if match:
                closer = "]" + match.group(1) + "]"
                end = segment.find(closer, index)
                end = len(segment) if end < 0 else end + len(closer)
                for pos in range(index, end):
                    out[pos] = " "
                index = end
                continue
        elif char == "`":
            end = index + 1
            while end < len(segment):
                if segment[end] == "\\":
                    end += 2
                    continue
                if segment[end] == "`":
                    end += 1
                    break
                end += 1
            for pos in range(index, min(end, len(segment))):
                out[pos] = " "
            index = end
            continue
        index += 1
    return "".join(out)


def clean_chain(chain):
    return re.sub(r"\s+", "", chain).replace(":", ".")


def lua_body(text, start):
    depth = 0
    index = start
    opens = re.compile(r"\b(function|if|do|repeat)\b")
    closes = re.compile(r"\b(end|until)\b")
    while index < len(text):
        char = text[index]
        if char in "'\"":
            index = skip_short(text, index)
            continue
        match = re.match(r"\[(=*)\[", text[index:])
        if match:
            closer = "]" + match.group(1) + "]"
            end = text.find(closer, index)
            index = len(text) if end < 0 else end + len(closer)
            continue
        word = re.compile(r"[A-Za-z_]\w*").match(text, index)
        if word:
            token = word.group(0)
            if opens.fullmatch(token):
                depth += 1
            elif closes.fullmatch(token):
                depth -= 1
                if depth == 0:
                    return text[start:word.end()]
            index = word.end()
            continue
        index += 1
    return text[start:]


def js_body(text, brace):
    depth = 0
    index = brace
    while index < len(text):
        char = text[index]
        if char in "'\"":
            index = skip_short(text, index)
            continue
        if char == "`":
            index += 1
            while index < len(text):
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == "`":
                    index += 1
                    break
                index += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
        index += 1
    return text[brace:]


def body_of(text, ext, item):
    position, name, args, _ = item
    if ext == ".lua":
        return lua_body(text, position), position
    if ext == ".js":
        brace = text.find("{", position + len(name))
        if brace < 0:
            return "", position
        return js_body(text, brace), brace
    return "", position


def context_of(text, ext, items):
    locals_ = set()
    modules = {}
    if ext == ".lua":
        for match in re.finditer(r"\blocal\s+([A-Za-z_][\w,\s]*?)\s*(?:=|$)", text, re.M):
            for name in match.group(1).split(","):
                if name.strip():
                    locals_.add(name.strip())
        for match in re.finditer(r'local\s+([A-Za-z_]\w*)\s*=\s*loadModule\(\s*"([a-z0-9_]+)"', text):
            modules[match.group(1)] = match.group(2)
        for match in re.finditer(
                r"(?:local\s+|[A-Za-z_][\w.]*\s*\.\s*)?([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\.new\(", text):
            modules[match.group(1)] = MODULE_CLASSES.get(match.group(2), match.group(2).lower())
    else:
        for match in re.finditer(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)", text):
            locals_.add(match.group(1))
    for match in re.finditer(r"function\s*[A-Za-z_$]*\s*\(([^)]*)\)", text):
        for part in match.group(1).split(","):
            name = part.strip().split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_$][\w$]*", name or ""):
                locals_.add(name)
    for _, _, args, _ in items:
        for part in args.split(","):
            name = part.strip().split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_$][\w$]*", name or ""):
                locals_.add(name)
    return locals_, modules


def resolve(chain, ext, own, locals_, modules, js_map, self_file, js_globals):
    segments = clean_chain(chain).split(".")
    method = segments[-1]
    head = segments[0]
    obj = segments[-2] if len(segments) > 1 else None
    if method in (LUA_KEYWORDS if ext == ".lua" else JS_KEYWORDS):
        return None, "keyword"
    if obj is None:
        if head in PLATFORM:
            return None, "platform"
        if head in own:
            return ("intra", head), "intra"
        if ext == ".js" and head in js_map and js_map[head] != self_file:
            return ("file", js_map[head], head), "file"
        if head in locals_:
            return None, "local"
        return None, "unknown:%s" % head
    if head in js_globals and head not in locals_:
        return None, "foreign-object"
    if obj in modules:
        return ("module", modules[obj], method), "module"
    if obj in MODULE_CLASSES:
        return ("module", MODULE_CLASSES[obj], method), "module"
    if obj in ("self", "this"):
        if method in own:
            return ("intra", method), "intra"
        return None, "self-method"
    if len(segments) > 2 and head in ("self", "this"):
        return None, "self-member"
    if len(segments) > 2 and head not in ("self", "this") and head in locals_:
        return None, "local"
    if obj in locals_:
        return None, "local"
    if obj in PLATFORM:
        return None, "platform"
    if ext == ".js" and obj in js_map:
        return ("file", js_map[obj], method), "file"
    return None, "unknown:%s" % obj


def python_calls(text, own):
    tree = ast.parse(text)
    edges = []
    platform = 0
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for child in ast.walk(node):
            if not isinstance(child, ast.Call):
                continue
            target = ast.unparse(child.func)
            if target.startswith(("self.", "cls.")):
                target = target.split(".", 1)[1]
            if target in own:
                edges.append((node.name, target))
            else:
                platform += 1
    return edges, platform


def scan_file(path, js_map, js_globals):
    text, items = extract(path)
    ext = os.path.splitext(path)[1]
    own = {name for _, name, _, _ in items}
    locals_, modules = context_of(text, ext, items)
    self_file = os.path.basename(path)
    intra = {}
    module_calls = {}
    file_calls = {}
    counts = {"platform": 0, "local": 0, "keyword": 0, "self-method": 0}
    unknown = {}
    if ext == ".py":
        edges, platform = python_calls(text, own)
        for caller, callee in edges:
            intra[(caller, callee)] = intra.get((caller, callee), 0) + 1
        counts["platform"] += platform
        return own, intra, module_calls, file_calls, counts, unknown
    for item in items:
        body, body_start = body_of(text, ext, item)
        if not body:
            continue
        open_index = text.find("(", item[0])
        skip = 0
        if open_index >= 0:
            arg_end = open_index + len(balanced_args(text, open_index)) + 2
            skip = max(0, arg_end - body_start)
        masked = mask(body[skip:], ext)
        seen = {}
        for match in CALL.finditer(masked):
            chain = clean_chain(match.group(1))
            if chain.split(".")[-1] in (LUA_KEYWORDS if ext == ".lua" else JS_KEYWORDS) \
                    and "." not in chain:
                continue
            seen[chain] = seen.get(chain, 0) + 1
        for chain, count in seen.items():
            target, kind = resolve(chain, ext, own, locals_, modules, js_map, self_file, js_globals)
            if target is None:
                if kind.startswith("unknown:"):
                    unknown[kind.split(":", 1)[1]] = unknown.get(kind.split(":", 1)[1], 0) + count
                else:
                    counts[kind] = counts.get(kind, 0) + count
                continue
            if target[0] == "intra":
                intra[(item[1], target[1])] = intra.get((item[1], target[1]), 0) + count
            elif target[0] == "module":
                key = (target[1], target[2], item[1])
                module_calls[key] = module_calls.get(key, 0) + count
            else:
                key = (target[1], target[2], item[1])
                file_calls[key] = file_calls.get(key, 0) + count
    return own, intra, module_calls, file_calls, counts, unknown


if __name__ == "__main__":
    markdown = build_markdown()
    io.open(OUT, "w", encoding="utf-8", newline="\n").write("\n".join(markdown))
    blocks, methods, problems = validate(markdown)
    print("wrote %s (%d lines of markdown)" % (OUT, len(markdown)))
    print("mermaid blocks=%d  method lines=%d  problems=%d" % (blocks, methods, len(problems)))
    for item in problems[:20]:
        print("  " + item)
