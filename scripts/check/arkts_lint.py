#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ArkTS 静态检查（无需 HarmonyOS SDK）：
  1. 语法：把 .ets 复制为 .ts（struct→class），用 tsc 只报 TS1xxx 语法错误
  2. JSON5 配置可解析
  3. $r('app.xxx.name') 资源引用存在
  4. ROUTE_* 常量都在 Index.PageMap 中注册
  5. 相对导入目标存在
  6. 单文件行数上限

用法：python3 scripts/check/arkts_lint.py [--skip-syntax]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ETS_ROOT = os.path.join(ROOT, "harmony", "entry", "src", "main", "ets")
RES_ROOT = os.path.join(ROOT, "harmony", "entry", "src", "main", "resources")
APP_JSON5 = os.path.join(ROOT, "harmony", "AppScope", "app.json5")
MODULE_JSON5 = os.path.join(ROOT, "harmony", "entry", "src", "main", "module.json5")
MAX_FILE_LINES = 2000

errors = []


def fail(msg):
    errors.append(msg)


def iter_ets():
    for dirpath, _, files in os.walk(ETS_ROOT):
        for f in files:
            if f.endswith(".ets"):
                yield os.path.join(dirpath, f)


# ---------- 1. 语法 ----------
# ArkUI 的 `Column() { ... }` 构造语法不是合法 TypeScript，tsc 无法直接解析 UI 文件。
# 因此分两类：
#   - 纯逻辑文件（无 @Component/@Entry/@CustomDialog/build()）→ tsc 语法检查
#   - UI 文件 → 括号/字符串/注释平衡检查（能抓出绝大多数结构性语法错误）

UI_MARKERS = ("@Component", "@Entry", "@CustomDialog", "build()")


def is_ui_file(text):
    return any(m in text for m in UI_MARKERS)


def balance_check(path, text):
    """括号配对 + 字符串/模板字符串/注释闭合检查。"""
    stack = []
    pairs = {"}": "{", ")": "(", "]": "["}
    i, n, line = 0, len(text), 1
    while i < n:
        ch = text[i]
        if ch == "\n":
            line += 1
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            closed = False
            while i + 1 < n:
                if text[i] == "*" and text[i + 1] == "/":
                    i += 2
                    closed = True
                    break
                if text[i] == "\n":
                    line += 1
                i += 1
            if not closed:
                fail("结构: %s:%d 块注释未闭合" % (os.path.relpath(path, ROOT), line))
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            closed = False
            while i < n:
                c = text[i]
                if c == "\\":
                    i += 2
                    continue
                if c == quote:
                    closed = True
                    i += 1
                    break
                if c == "\n":
                    break
                i += 1
            if not closed:
                fail("结构: %s:%d 字符串未闭合" % (os.path.relpath(path, ROOT), line))
            continue
        if ch == "`":
            i += 1
            closed = False
            depth = 0
            while i < n:
                c = text[i]
                if c == "\\":
                    i += 2
                    continue
                if c == "`" and depth == 0:
                    closed = True
                    i += 1
                    break
                if c == "$" and i + 1 < n and text[i + 1] == "{":
                    depth += 1
                    i += 2
                    continue
                if c == "}" and depth > 0:
                    depth -= 1
                    i += 1
                    continue
                if c == "\n":
                    line += 1
                i += 1
            if not closed:
                fail("结构: %s:%d 模板字符串未闭合" % (os.path.relpath(path, ROOT), line))
            continue
        if ch in "{([":
            stack.append((ch, line))
        elif ch in "})]":
            if not stack:
                fail("结构: %s:%d 多余的 '%s'" % (os.path.relpath(path, ROOT), line, ch))
            else:
                top, tl = stack.pop()
                if top != pairs[ch]:
                    fail("结构: %s:%d '%s' 与第 %d 行 '%s' 不匹配" % (os.path.relpath(path, ROOT), line, ch, tl, top))
        i += 1
    for ch, tl in stack:
        fail("结构: %s:%d '%s' 未闭合" % (os.path.relpath(path, ROOT), tl, ch))


def check_syntax():
    ui_files = 0
    logic_files = []
    for path in iter_ets():
        text = open(path, encoding="utf-8").read()
        if is_ui_file(text):
            ui_files += 1
            balance_check(path, text)
        else:
            logic_files.append(path)
    print("  结构检查 %d 个 UI 文件" % ui_files)

    if not logic_files:
        print("  语法检查 0 个纯逻辑文件")
        return
    tmp = tempfile.mkdtemp(prefix="arkts_")
    try:
        names = []
        for path in logic_files:
            base = os.path.basename(path)[:-4]
            dst = os.path.join(tmp, base + ".ts")
            idx = 1
            while os.path.exists(dst):
                dst = os.path.join(tmp, "%s_%d.ts" % (base, idx))
                idx += 1
            # @Concurrent 是 TaskPool 的函数级装饰器，tsc 不接受函数装饰器，转译前去掉。
            text = open(path, encoding="utf-8").read()
            text = re.sub(r"^\s*@Concurrent\s*$", "", text, flags=re.M)
            with open(dst, "w", encoding="utf-8") as fh:
                fh.write(text)
            names.append(os.path.basename(dst))
        cmd = ["npx", "--yes", "-p", "typescript@5", "tsc", "--noEmit", "--noResolve",
               "--target", "es2022", "--experimentalDecorators", "--skipLibCheck"] + sorted(names)
        proc = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True)
        out = (proc.stdout or "") + (proc.stderr or "")
        syntax = [ln for ln in out.splitlines() if re.search(r"error TS1\d{3}", ln)]
        for ln in syntax[:30]:
            fail("语法: " + ln)
        print("  语法检查 %d 个纯逻辑文件，错误 %d 条" % (len(names), len(syntax)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------- 2. JSON5 ----------
def strip_json5(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)//.*$", "", text)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return text


def check_json5():
    targets = [APP_JSON5, MODULE_JSON5]
    for dirpath, _, files in os.walk(os.path.join(ROOT, "harmony")):
        for f in files:
            if f.endswith(".json5") and "-lock" not in f:
                targets.append(os.path.join(dirpath, f))
    for path in targets:
        if not os.path.exists(path):
            continue
        try:
            json.loads(strip_json5(open(path, encoding="utf-8").read()))
        except Exception as exc:  # noqa: BLE001
            fail("JSON5 解析失败 %s: %s" % (os.path.relpath(path, ROOT), exc))
    print("  JSON5 检查 %d 个文件" % len(targets))


# ---------- 3. 资源引用 ----------
def collect_resource_names():
    names = {"media": set(), "string": set(), "color": set(), "profile": set()}
    for dirpath, _, files in os.walk(RES_ROOT):
        rel = os.path.relpath(dirpath, RES_ROOT)
        if "media" in rel.split(os.sep):
            for f in files:
                names["media"].add(os.path.splitext(f)[0])
        elif "element" in rel.split(os.sep):
            for f in files:
                if not f.endswith(".json"):
                    continue
                try:
                    data = json.load(open(os.path.join(dirpath, f), encoding="utf-8"))
                except Exception:  # noqa: BLE001
                    continue
                for key in ("string", "color", "float", "boolean", "integer"):
                    for item in data.get(key, []) or []:
                        if isinstance(item, dict) and item.get("name"):
                            names.setdefault(key, set()).add(item["name"])
        elif "profile" in rel.split(os.sep):
            for f in files:
                names["profile"].add(os.path.splitext(f)[0])
    return names


def check_resources():
    names = collect_resource_names()
    pattern = re.compile(r"\$r\(\s*'app\.(media|string|color|profile)\.([A-Za-z0-9_]+)'\s*\)")
    missing = 0
    for path in iter_ets():
        text = open(path, encoding="utf-8").read()
        for m in pattern.finditer(text):
            kind, name = m.group(1), m.group(2)
            pool = names.get(kind, set())
            if pool and name not in pool:
                fail("资源缺失 %s: $r('app.%s.%s')" % (os.path.relpath(path, ROOT), kind, name))
                missing += 1
    print("  资源引用检查完成，缺失 %d 处" % missing)


# ---------- 4. 路由注册 ----------
def check_routes():
    routes_path = os.path.join(ETS_ROOT, "state", "Routes.ets")
    index_path = os.path.join(ETS_ROOT, "pages", "Index.ets")
    if not os.path.exists(routes_path) or not os.path.exists(index_path):
        return
    routes = re.findall(r"export const (ROUTE_[A-Z0-9_]+)", open(routes_path, encoding="utf-8").read())
    index_text = open(index_path, encoding="utf-8").read()
    missing = [r for r in routes if r not in index_text]
    for r in missing:
        fail("路由未注册: %s（Routes.ets 定义但 Index.ets 未引用）" % r)
    print("  路由检查 %d 个常量，未注册 %d 个" % (len(routes), len(missing)))


# ---------- 5. 相对导入 ----------
def check_imports():
    pattern = re.compile(r"from\s+'(\.{1,2}/[^']+)'")
    missing = 0
    for path in iter_ets():
        text = open(path, encoding="utf-8").read()
        base = os.path.dirname(path)
        for m in pattern.finditer(text):
            target = os.path.normpath(os.path.join(base, m.group(1)))
            candidates = [target + ".ets", target + ".ts", os.path.join(target, "index.ets"),
                          os.path.join(target, "index.ts")]
            if not any(os.path.exists(c) for c in candidates):
                fail("导入不存在 %s -> %s" % (os.path.relpath(path, ROOT), m.group(1)))
                missing += 1
    print("  相对导入检查完成，缺失 %d 处" % missing)


# ---------- 6. 单文件行数 ----------
def load_large_allowlist():
    """大文件允许清单：path<TAB>max_lines（含 headroom，防止继续膨胀）。"""
    path = os.path.join(ROOT, "scripts", "check", "large_files_allowlist.txt")
    allow = {}
    if not os.path.exists(path):
        return allow
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            allow[parts[0]] = int(parts[1])
    return allow


def check_file_size():
    allow = load_large_allowlist()
    over = 0
    for path in iter_ets():
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        n = sum(1 for _ in open(path, encoding="utf-8", errors="ignore"))
        if n <= MAX_FILE_LINES:
            continue
        limit = allow.get(rel)
        if limit is None:
            fail("单文件过大 %s: %d 行（上限 %d，未在允许清单中）" % (rel, n, MAX_FILE_LINES))
            over += 1
        elif n > limit:
            fail("单文件继续膨胀 %s: %d 行（允许上限 %d）" % (rel, n, limit))
            over += 1
        else:
            print("  允许清单内: %s %d/%d 行" % (rel, n, limit))
    print("  单文件行数检查完成，超限 %d 个" % over)


def main():
    skip_syntax = "--skip-syntax" in sys.argv
    print("[1/6] ArkTS 语法")
    if skip_syntax:
        print("  已跳过")
    else:
        check_syntax()
    print("[2/6] JSON5")
    check_json5()
    print("[3/6] 资源引用")
    check_resources()
    print("[4/6] 路由注册")
    check_routes()
    print("[5/6] 相对导入")
    check_imports()
    print("[6/6] 单文件行数")
    check_file_size()

    if errors:
        print("\n失败项：")
        for e in errors[:40]:
            print("  -", e)
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
