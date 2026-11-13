#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
配置覆盖率检查（SPEC §9 / P8）：找出「代码里写死、但没接入远程下发」的数值常量。

规则：
  1. 扫描 `harmony/entry/src/main/ets/**/*.ets` 里的数值常量声明：
       const NAME: number = <数值表达式>;
       const NAME = <数值表达式>;
     数值表达式支持四则运算（如 `10 * 60 * 1000`），只做受限求值，不执行任意代码。
  2. 以下情况跳过：
     - 文件名以 `.test.ets` 结尾
     - 声明行或上一行带 `// @config-exempt` 注释（说明为何保持硬编码）
     - 常量名命中内置白名单（MAX_*_BYTES / MAX_*_LEN / *_TIMEOUT_MS）
     - 常量名命中 `scripts/check/config_coverage_allowlist.txt` 里的 glob
     - 常量值已出现在 `services/ConfigRegistry.ets` 的 DEFS 默认值里
  3. 其余常量视为「未注册」：**只告警，不阻断**（exit 0），最多列前 20 条。
  4. `--strict` 模式：存在未注册常量时 exit 1（供后续收紧 CI 用）。

用法：
  python3 scripts/check/config_coverage.py            # 告警模式（CI 默认）
  python3 scripts/check/config_coverage.py --strict   # 严格模式（有未注册常量即失败）
"""
import fnmatch
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ETS_ROOT = os.path.join(ROOT, "harmony", "entry", "src", "main", "ets")
REGISTRY_PATH = os.path.join(ETS_ROOT, "services", "ConfigRegistry.ets")
ALLOWLIST_PATH = os.path.join(ROOT, "scripts", "check", "config_coverage_allowlist.txt")

# 数值常量声明：const NAME(: number)? = <数值表达式>;
DECL_RE = re.compile(
    r"^\s*const\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*(?::\s*number\s*)?=\s*"
    r"(-?[0-9][0-9_]*(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"
    r"(?:\s*[+\-*/]\s*[0-9][0-9_]*(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)*)\s*;"
)
# 只把全大写常量当作「配置候选」；小写多是函数内临时变量（如 const week = 7 * 86400 * 1000）。
NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
# 受限表达式：只允许数字、空格、四则运算与括号。
SAFE_EXPR_RE = re.compile(r"^[0-9_+\-*/().\s]+$")
# ConfigRegistry DEFS 里的数值默认值：threshold(ConfigKey.X, <数值>, ...) / userNumber(...)
DEF_DEFAULT_RE = re.compile(
    r"(?:threshold|userNumber)\(\s*ConfigKey\.[A-Z0-9_]+\s*,\s*(-?[0-9]+(?:\.[0-9]+)?)"
)

# 内置白名单：协议/安全上限，本来就不应该远程放宽。
BUILTIN_ALLOW = ["MAX_*_BYTES", "MAX_*_LEN", "*_TIMEOUT_MS"]

# 输出最多列出的未注册常量条数。
MAX_REPORT = 20


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def iter_ets():
    for dirpath, _, files in os.walk(ETS_ROOT):
        for f in files:
            if f.endswith(".ets"):
                yield os.path.join(dirpath, f)


def load_allowlist():
    """读取白名单文件（常量名 glob，一行一个，# 开头为注释）。"""
    patterns = []
    if not os.path.exists(ALLOWLIST_PATH):
        return patterns
    for line in open(ALLOWLIST_PATH, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line)
    return patterns


def collect_registry_defaults():
    """提取 ConfigRegistry DEFS 里注册过的数值默认值集合。"""
    if not os.path.exists(REGISTRY_PATH):
        return None
    text = open(REGISTRY_PATH, encoding="utf-8").read()
    values = set()
    for m in DEF_DEFAULT_RE.finditer(text):
        try:
            values.add(float(m.group(1)))
        except ValueError:
            continue
    return values


def eval_expr(expr):
    """受限求值：只允许数字与四则运算，失败返回 None（跳过该常量）。"""
    if not SAFE_EXPR_RE.match(expr):
        return None
    try:
        value = eval(expr, {"__builtins__": {}}, {})  # noqa: S307 —— 已用白名单正则限制字符集
    except Exception:  # noqa: BLE001
        return None
    if not isinstance(value, (int, float)):
        return None
    return float(value)


def is_exempt(lines, index):
    """声明行或上一行带 @config-exempt 注释即视为已说明。"""
    line = lines[index]
    prev = lines[index - 1] if index > 0 else ""
    return "@config-exempt" in line or "@config-exempt" in prev


def main(argv):
    strict = "--strict" in argv[1:]

    defaults = collect_registry_defaults()
    if defaults is None:
        print("  找不到 %s，无法判断配置注册情况" % rel(REGISTRY_PATH))
        return 1

    allowlist = BUILTIN_ALLOW + load_allowlist()
    files = 0
    total = 0
    exempt = 0
    allowlisted = 0
    registered = 0
    warnings = []

    for path in iter_ets():
        if path.endswith(".test.ets"):
            continue
        files += 1
        try:
            lines = open(path, encoding="utf-8").read().split("\n")
        except Exception:  # noqa: BLE001
            continue
        for i, line in enumerate(lines):
            m = DECL_RE.match(line)
            if not m:
                continue
            name = m.group(1)
            if not NAME_RE.match(name):
                continue
            total += 1
            if is_exempt(lines, i):
                exempt += 1
                continue
            if any(fnmatch.fnmatchcase(name, pat) for pat in allowlist):
                allowlisted += 1
                continue
            value = eval_expr(m.group(2))
            if value is None:
                continue
            if value in defaults:
                registered += 1
                continue
            warnings.append((rel(path), i + 1, name, value))

    print("  扫描 %d 个 .ets 文件，数值常量 %d 个" % (files, total))
    print("  已排除：@config-exempt %d / 白名单 %d / 已注册值 %d"
          % (exempt, allowlisted, registered))

    if not warnings:
        print("  配置覆盖率检查通过：没有发现未注册的数值常量")
        return 0

    print("  未注册且未标注 @config-exempt：%d 个（仅告警，不阻断）" % len(warnings))
    for path, line, name, value in warnings[:MAX_REPORT]:
        shown = int(value) if value == int(value) else value
        print("    - %s:%d %s = %s" % (path, line, name, shown))
    if len(warnings) > MAX_REPORT:
        print("    … 其余 %d 条省略" % (len(warnings) - MAX_REPORT))
    print("  提示：业务阈值应注册进 ConfigRegistry DEFS；协议/安全/UI 常量请加")
    print("        `// @config-exempt: 原因` 或加入 scripts/check/config_coverage_allowlist.txt")

    if strict:
        print("\n失败项：")
        print("  - --strict 模式下存在 %d 个未注册数值常量" % len(warnings))
        return 1
    print("  配置覆盖率检查完成（告警 %d 个，不阻断）" % len(warnings))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
