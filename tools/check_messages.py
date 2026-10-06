#!/usr/bin/env python3
"""IFM 消息键名一致性检查。

backend/modules/message.lua 的 Message.KEYS 是面向网页文案的键名唯一来源；
frontend/web/ifm-messages.js 的 MSG.zh 必须覆盖同一批键名。运行期 Lua 源码里不允许再出现
unicode 转义（uXXXX 形式）或字面非 ASCII（注释除外，由 tools/ascii_source.py 判定）。

用法：
    python tools/check_messages.py            键名一致性检查 + 报告未迁移的转义数量
    python tools/check_messages.py --strict   迁移完成后使用：残留转义 / 非 ASCII 一律失败
"""
import io
import os
import re
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
BACKEND = os.path.join(ROOT, "backend")
sys.path.insert(0, TOOLS)

import ascii_source  # noqa: E402

MESSAGE_LUA = os.path.join(BACKEND, "modules", "message.lua")
MESSAGES_JS = os.path.join(ROOT, "frontend", "web", "ifm-messages.js")
FRONTEND = os.path.join(ROOT, "frontend")
BACKSLASH = chr(92)
NEWLINE = chr(10)
ESCAPE_MARK = BACKSLASH + "u"
HEX = "0123456789abcdefABCDEF"
KEY_PREFIX = "msg."
ALLOW_MARK = "ifm-checker: allow-non-ascii"
FRONTEND_EXTS = (".js", ".html", ".css")
FRONTEND_SKIP_FILES = ("ifm-messages.js",)
FRONTEND_SKIP_DIRS = ("dist", "bergamot", "node_modules")
PLACEHOLDER = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
SUSPECT_RANGES = (
    (0x3000, 0x303F),   # CJK 标点：。、「」
    (0x3400, 0x4DBF),   # 汉字扩展 A
    (0x4E00, 0x9FFF),   # 汉字
    (0xF900, 0xFAFF),   # 兼容汉字
    (0xFF00, 0xFFEF),   # 全角字符：：（）！？
)


def suspect(char):
    """是不是"中文 / 全角"字符（·…→×≥ 这类语言无关符号放行）。"""
    code = ord(char)
    return any(low <= code <= high for low, high in SUSPECT_RANGES)


def blank(chunk):
    return "".join(NEWLINE if char == NEWLINE else " " for char in chunk)


def mask(text, drop_strings=True, lua=False):
    """抹掉注释（drop_strings=True 时连字符串内容一起抹），长度与换行保持不变。"""
    out = []
    state = None
    line_mark = "--" if lua else "//"
    i = 0
    total = len(text)
    while i < total:
        char = text[i]
        pair = text[i:i + 2]
        if state:
            if char == BACKSLASH and not lua and i + 1 < total:
                out.append("  " if drop_strings else text[i:i + 2])
                i += 2
                continue
            if char == state or (lua and state == "\n"):
                out.append(char)
                state = None
                i += 1
                continue
            out.append(NEWLINE if char == NEWLINE else (" " if drop_strings else char))
            i += 1
            continue
        if char in "\"'":
            state = char
            out.append(char)
            i += 1
            continue
        if pair == line_mark:
            end = text.find(NEWLINE, i)
            end = total if end < 0 else end
            out.append(blank(text[i:end]))
            i = end
            continue
        if not lua and pair == "/*":
            end = text.find("*/", i + 2)
            end = total if end < 0 else end + 2
            out.append(blank(text[i:end]))
            i = end
            continue
        out.append(char)
        i += 1
    return "".join(out)


def block_range(text, marker, search_from=0, lua=False):
    """marker 之后第一个 {...} 的区间 [start, end)（含最外层大括号）。"""
    masked = mask(text, lua=lua)
    start = masked.index(marker, search_from)
    brace = masked.index("{", start)
    depth = 0
    index = brace
    while index < len(masked):
        char = masked[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return brace, index + 1
        index += 1
    raise ValueError("unbalanced block: " + marker)


def count_escapes(text):
    total = 0
    index = text.find(ESCAPE_MARK)
    while index >= 0:
        chunk = text[index + 2:index + 6]
        if len(chunk) == 4 and all(char in HEX for char in chunk):
            total += 1
        index = text.find(ESCAPE_MARK, index + 2)
    return total


def block_keys(body, lua=False):
    """块内第一层键名：在 { 或 , 之后读 'key' / "key" / key，并确认后面是 ':'。"""
    text = mask(body, drop_strings=False, lua=lua)
    keys = []
    depth = 0
    want_key = False
    i = 0
    total = len(text)
    while i < total:
        char = text[i]
        if char in "\"'":
            quote = char
            j = i + 1
            while j < total:
                if text[j] == BACKSLASH and not lua:
                    j += 2
                    continue
                if text[j] == quote:
                    break
                j += 1
            token = text[i + 1:j]
            if depth == 1 and want_key:
                k = j + 1
                while k < total and text[k] in " \t\r\n":
                    k += 1
                if token and k < total and text[k] == ":":
                    keys.append(token)
                    want_key = False
            i = j + 1
            continue
        if char == "{":
            depth += 1
            if depth == 1:
                want_key = True
            i += 1
            continue
        if char == "}":
            depth -= 1
            i += 1
            continue
        if char == "," and depth == 1:
            want_key = True
            i += 1
            continue
        if depth == 1 and want_key and char.isspace():
            i += 1
            continue
        if depth == 1 and want_key:
            if char.isalpha() or char in "_$":
                j = i
                while j < total and (text[j].isalnum() or text[j] in "_$"):
                    j += 1
                token = text[i:j]
                k = j
                while k < total and text[k] in " \t\r\n":
                    k += 1
                if k < total and text[k] == ":":
                    keys.append(token)
                    want_key = False
                i = j
                continue
            want_key = False
        i += 1
    return keys


def block_placeholders(body):
    """{key: 占位符集合}（只取单行书写的条目）。"""
    keeping = mask(body, drop_strings=False)
    out = {}
    for line in keeping.split(NEWLINE):
        match = re.match(r"\s*(?:'([^']+)'|\"([^\"]+)\"|([A-Za-z_$][\w$]*))\s*:\s*(.+)$", line)
        if not match:
            continue
        key = match.group(1) or match.group(2) or match.group(3)
        out[key] = set(PLACEHOLDER.findall(match.group(4)))
    return out


def block_strings(body, lua=False):
    """块内所有字符串字面量（数组风格的 Lua 表用它取键名）。"""
    text = mask(body, drop_strings=False, lua=lua)
    out = []
    i = 0
    total = len(text)
    while i < total:
        char = text[i]
        if char in "\"'":
            quote = char
            j = i + 1
            while j < total:
                if text[j] == BACKSLASH and not lua:
                    j += 2
                    continue
                if text[j] == quote:
                    break
                j += 1
            out.append(text[i + 1:j])
            i = j + 1
            continue
        i += 1
    return out


def backend_keys():
    text = io.open(MESSAGE_LUA, "r", encoding="utf-8").read()
    start, end = block_range(text, "Message.KEYS", lua=True)
    body = text[start:end]
    keys = set(block_keys(body, lua=True))
    if not keys:
        keys = {value for value in block_strings(body, lua=True)
                if value.startswith(KEY_PREFIX)}
    return keys


def frontend_block(table):
    text = io.open(MESSAGES_JS, "r", encoding="utf-8").read()
    start, end = block_range(text, "const " + table)
    return text[start:end]


def frontend_keys(lang="zh", table="MSG"):
    body = frontend_block(table)
    start, end = block_range(body, lang + ": {")
    return set(block_keys(body[start:end]))


def frontend_placeholders(lang="zh", table="MSG"):
    body = frontend_block(table)
    start, end = block_range(body, lang + ": {")
    return block_placeholders(body[start:end])


def frontend_issues():
    """注释之外出现非 ASCII 的位置（ifm-messages.js 是唯一文案来源，跳过）。"""
    issues = []
    for root, dirs, files in os.walk(FRONTEND):
        dirs[:] = [name for name in dirs if name not in FRONTEND_SKIP_DIRS]
        for name in sorted(files):
            if not name.endswith(FRONTEND_EXTS) or name in FRONTEND_SKIP_FILES:
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            text = io.open(path, "r", encoding="utf-8", newline="").read()
            if name.endswith(".html"):
                body = re.sub(r"<!--.*?-->", lambda m: blank(m.group(0)), text, flags=re.S)
            else:
                body = mask(text, drop_strings=False)
            raw = text.split(NEWLINE)
            for index, line in enumerate(body.split(NEWLINE)):
                if not name.endswith(".html") and (ALLOW_MARK in raw[index] or
                                                   (index > 0 and ALLOW_MARK in raw[index - 1])):
                    continue
                bad = "".join(char for char in line if suspect(char))
                if bad:
                    issues.append((rel, index + 1, bad[:40]))
    return issues


def compare(label, expected, actual, problems):
    missing = sorted(set(expected) - set(actual))
    extra = sorted(set(actual) - set(expected))
    if missing:
        problems.append("%s 缺少 %d 条：%s" % (label, len(missing), ", ".join(missing[:12])))
    if extra:
        problems.append("%s 多余 %d 条：%s" % (label, len(extra), ", ".join(extra[:12])))


def compare_placeholders(label, zh, en, problems):
    for key in sorted(set(zh) & set(en)):
        if zh[key] != en[key]:
            problems.append("%s 的 {占位符} 不一致（%s）：zh=%s en=%s"
                            % (label, key, sorted(zh[key]), sorted(en[key])))


def source_files():
    files = [os.path.join(BACKEND, "IFMMaster.lua")]
    module_dir = os.path.join(BACKEND, "modules")
    for name in sorted(os.listdir(module_dir)):
        if name.endswith(".lua"):
            files.append(os.path.join(module_dir, name))
    return files


def main():
    strict = "--strict" in sys.argv[1:]
    failed = 0
    problems = []

    keys = backend_keys()
    zh = frontend_keys("zh", "MSG")
    en = frontend_keys("en", "MSG")
    compare("MSG.zh（键名定义见 backend/modules/message.lua）", keys, zh, problems)
    compare("MSG.en（frontend/web/ifm-messages.js）", zh, en, problems)
    compare_placeholders("MSG", frontend_placeholders("zh", "MSG"),
                         frontend_placeholders("en", "MSG"), problems)

    izh = frontend_keys("zh", "I18N")
    ien = frontend_keys("en", "I18N")
    compare("I18N.en（frontend/web/ifm-messages.js）", izh, ien, problems)
    compare_placeholders("I18N", frontend_placeholders("zh", "I18N"),
                         frontend_placeholders("en", "I18N"), problems)

    print("键名：后端 %d / MSG.zh %d / MSG.en %d；I18N.zh %d / I18N.en %d"
          % (len(keys), len(zh), len(en), len(izh), len(ien)))

    issues = frontend_issues()
    if issues:
        problems.append("前端注释之外出现非 ASCII（文案应放进 ifm-messages.js，日志一律英文）:")
        for rel, number, bad in issues:
            problems.append("    %s:%d  %s" % (rel, number, bad))

    pending = []
    for path in source_files():
        text = io.open(path, "r", encoding="utf-8", newline="").read()
        count = count_escapes(text)
        if count:
            pending.append((os.path.relpath(path, ROOT).replace(os.sep, "/"), count))
        bad = ascii_source.find_violations(text)
        if bad:
            failed += 1
            print("%s: %d 处代码/字符串非 ASCII（应改写为键名）" % (path, len(bad)))
    if pending:
        print("尚未迁移的 unicode 转义：" + ", ".join("%s=%d" % item for item in pending))
        if strict:
            failed += 1
    elif strict:
        print("运行期 Lua 已无 unicode 转义")

    if problems:
        failed += 1
        print("文案检查失败：")
        for line in problems:
            print("    " + line)
    else:
        print("文案检查通过：MSG 后端/zh/en 三方一致，I18N 双语一致，前端注释之外无非 ASCII")
    print("OK" if not failed else "检查失败")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())