#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""IFM 源文件 ASCII 检查 / 转换工具。

规则：Lua **代码部分**（包括字符串字面量）只能是 ASCII；**注释**里可以放任意字符（中文说明）。
字符串里的中文写成 \\uXXXX 字面转义即可（网页端会把它还原成中文再显示）：

    return false, "\\\\u540d\\\\u79f0\\\\u4e0d\\\\u80fd\\\\u4e3a\\\\u7a7a"   -- 名称不能为空

用法：
    python tools/ascii_source.py --check             # 只检查（有违规返回 1）
    python tools/ascii_source.py --check IFMMaster.lua   # 指定文件
    python tools/ascii_source.py --list              # 列出违规位置
    python tools/ascii_source.py --write             # 把字符串里的非 ASCII 自动转成 \\uXXXX
默认目标：IFMMaster.lua 与 ifm/*.lua（相对项目根目录）。build.py 会在打包前做同样的检查。
"""
import argparse
import io
import os
import sys


def _long_bracket(text, i):
    """text[i:] 若是长括号开头 [=*[，返回 (level, 内容起点)；否则 None"""
    if i >= len(text) or text[i] != "[":
        return None
    j = i + 1
    while j < len(text) and text[j] == "=":
        j += 1
    if j < len(text) and text[j] == "[":
        return j - i - 1, j + 1
    return None


def split_segments(text):
    """把源码切成 [(kind, chunk)]，kind ∈ {code, string, string-long, comment}"""
    segs = []
    buf = []
    n = len(text)

    def flush():
        if buf:
            segs.append(("code", "".join(buf)))
            del buf[:]

    i = 0
    while i < n:
        lb = _long_bracket(text, i)
        if lb:
            level, start = lb
            closer = "]" + "=" * level + "]"
            end = text.find(closer, start)
            end = n if end < 0 else end + len(closer)
            flush()
            segs.append(("string-long", text[i:end]))
            i = end
            continue
        if text.startswith("--", i):
            lb2 = _long_bracket(text, i + 2)
            if lb2:
                level, start = lb2
                closer = "]" + "=" * level + "]"
                end = text.find(closer, start)
                end = n if end < 0 else end + len(closer)
            else:
                end = text.find("\n", i)
                end = n if end < 0 else end
            flush()
            segs.append(("comment", text[i:end]))
            i = end
            continue
        if text[i] in "\"'":
            quote = text[i]
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == quote:
                    j += 1
                    break
                if text[j] == "\n":
                    break
                j += 1
            flush()
            segs.append(("string", text[i:j]))
            i = j
            continue
        buf.append(text[i])
        i += 1
    flush()
    return segs


def find_violations(text):
    """返回 [(行号, 列号, 字符, kind)]：代码/字符串里的非 ASCII 字符（注释不算）"""
    out = []
    line = 1
    for kind, chunk in split_segments(text):
        if kind == "comment":
            line += chunk.count("\n")
            continue
        col = 1
        for ch in chunk:
            if ch == "\n":
                line += 1
                col = 1
                continue
            if ord(ch) > 127:
                out.append((line, col, ch, kind))
            col += 1
    return out


def convert(text):
    """把字符串片段里的非 ASCII 转成 \\uXXXX 字面转义（短字符串用 \\\\uXXXX，长字符串用 \\uXXXX）"""
    parts = []
    for kind, chunk in split_segments(text):
        if kind in ("string", "string-long") and any(ord(c) > 127 for c in chunk):
            double = "\\\\" if kind == "string" else "\\"
            chunk = "".join(("%su%04X" % (double, ord(c))) if ord(c) > 127 else c for c in chunk)
        parts.append(chunk)
    return "".join(parts)


def target_files(names):
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if names:
        return [os.path.abspath(name) for name in names]
    files = [os.path.join(base, "IFMMaster.lua")]
    module_dir = os.path.join(base, "ifm")
    if os.path.isdir(module_dir):
        files += [os.path.join(module_dir, n) for n in sorted(os.listdir(module_dir)) if n.endswith(".lua")]
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description="IFM 源文件 ASCII 检查/转换")
    parser.add_argument("files", nargs="*", help="要处理的 Lua 文件（默认 IFMMaster.lua 与 ifm/*.lua）")
    parser.add_argument("--check", action="store_true", help="只检查，不修改")
    parser.add_argument("--write", action="store_true", help="把字符串里的非 ASCII 转成 \\uXXXX")
    parser.add_argument("--list", action="store_true", help="列出违规位置")
    args = parser.parse_args(argv)

    total = 0
    for path in target_files(args.files):
        text = io.open(path, "r", encoding="utf-8", newline="").read()
        if args.write:
            converted = convert(text)
            if converted != text:
                io.open(path, "w", encoding="utf-8", newline="").write(converted)
                print("已转换：%s" % path)
                text = converted
        bad = find_violations(text)
        if bad:
            total += len(bad)
            print("%s: %d 处非 ASCII（代码/字符串）" % (path, len(bad)))
            if args.list or args.check:
                for line, col, ch, kind in bad[:40]:
                    print("  第 %d 行第 %d 列 [%s] %r" % (line, col, kind, ch))
        elif args.check or args.write:
            print("OK：%s" % path)
    if args.check and total:
        print("检查失败：字符串里的中文请写成 \\uXXXX 字面转义（可运行 --write 自动转换）")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
