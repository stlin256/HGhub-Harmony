#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
变体检查：禁止 test 变体被提交/发布。

BuildVariant.ets 中 IS_TEST_VARIANT 必须为 false（release）。
若为 true，说明当前是测试变体，CI 失败。

本地构建测试包时可临时设置环境变量 ALLOW_TEST_VARIANT=1 跳过本检查。

用法：python3 scripts/check/variant_check.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD_VARIANT = os.path.join(ROOT, "harmony", "entry", "src", "main", "ets", "utils", "BuildVariant.ets")

IS_TEST_RE = re.compile(r"^export const IS_TEST_VARIANT\s*:\s*boolean\s*=\s*(true|false)\s*;", re.M)
VARIANT_NAME_RE = re.compile(r"^export const VARIANT_NAME\s*:\s*string\s*=\s*'([^']+)'", re.M)


def main():
    if os.environ.get("ALLOW_TEST_VARIANT") == "1":
        print("  已设置 ALLOW_TEST_VARIANT=1，跳过变体检查（仅限本地构建测试包）")
        return 0

    rel = os.path.relpath(BUILD_VARIANT, ROOT)
    if not os.path.exists(BUILD_VARIANT):
        print("  找不到 %s" % rel)
        return 1

    text = open(BUILD_VARIANT, encoding="utf-8").read()
    m = IS_TEST_RE.search(text)
    if not m:
        print("  %s 中未找到 IS_TEST_VARIANT 常量" % rel)
        return 1

    is_test = m.group(1) == "true"
    name_match = VARIANT_NAME_RE.search(text)
    variant_name = name_match.group(1) if name_match else None
    print("  当前变体：%s（IS_TEST_VARIANT = %s）" % (variant_name or "?", m.group(1)))

    errors = []
    if is_test:
        errors.append("当前是 test 变体，禁止提交/发布")
    if variant_name is None:
        errors.append("未找到 VARIANT_NAME 常量")
    elif variant_name != ("test" if is_test else "release"):
        errors.append("IS_TEST_VARIANT 与 VARIANT_NAME 不一致（%s / %s）" % (m.group(1), variant_name))

    if errors:
        print("\n失败项：")
        for e in errors:
            print("  -", e)
        print("\n请先切回 release 变体：node scripts/harmony/set-variant.mjs release")
        print("（本地构建测试包可临时设置 ALLOW_TEST_VARIANT=1 跳过本检查）")
        return 1

    print("  变体检查通过（release）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
