#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
版本号一致性检查：
  - harmony/AppScope/app.json5 的 versionName
  - README.md 里的 release badge（release-vX.Y.Z）
  - 最新 git tag（若可用，且为 vX.Y.Z 形式）

任一不一致即失败。允许 README 未写 badge（跳过该项）。
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_JSON5 = os.path.join(ROOT, "harmony", "AppScope", "app.json5")
README = os.path.join(ROOT, "README.md")


def strip_json5(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)//.*$", "", text)
    return re.sub(r",(\s*[}\]])", r"\1", text)


def app_version():
    if not os.path.exists(APP_JSON5):
        return None
    data = json.loads(strip_json5(open(APP_JSON5, encoding="utf-8").read()))
    return (data.get("app") or {}).get("versionName")


def readme_badge():
    if not os.path.exists(README):
        return None
    m = re.search(r"badge/release-v([0-9]+\.[0-9]+\.[0-9]+)", open(README, encoding="utf-8").read())
    return m.group(1) if m else None


def latest_tag():
    try:
        out = subprocess.run(["git", "describe", "--tags", "--abbrev=0"], cwd=ROOT,
                             capture_output=True, text=True, timeout=10)
        tag = (out.stdout or "").strip()
        if tag.startswith("v") and re.match(r"^v[0-9]+\.[0-9]+\.[0-9]+$", tag):
            return tag[1:]
    except Exception:  # noqa: BLE001
        pass
    return None


def main():
    errors = []
    app = app_version()
    badge = readme_badge()
    tag = latest_tag()

    print("  app.json5 versionName: %s" % app)
    print("  README badge:          %s" % badge)
    print("  最新 git tag:          %s" % tag)

    if app is None:
        errors.append("app.json5 缺少 versionName")
    if badge is not None and app is not None and badge != app:
        errors.append("README badge (v%s) 与 app.json5 (%s) 不一致" % (badge, app))
    if tag is not None and app is not None and tag != app:
        errors.append("最新 tag (v%s) 与 app.json5 (%s) 不一致（发版前请先改版本号）" % (tag, app))

    if errors:
        print("\n失败项：")
        for e in errors:
            print("  -", e)
        return 1
    print("  版本号一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
