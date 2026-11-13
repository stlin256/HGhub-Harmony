#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""文档相对链接检查：docs/**/*.md 与 README.md 中的相对链接目标必须存在。"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")


def main():
    bad = []
    for dirpath, dirnames, files in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in {".git", "node_modules", "oh_modules"}]
        for f in files:
            if not f.endswith(".md"):
                continue
            path = os.path.join(dirpath, f)
            text = open(path, encoding="utf-8", errors="ignore").read()
            for m in LINK.finditer(text):
                target = m.group(1).strip()
                if target.startswith(("http://", "https://", "#", "mailto:")):
                    continue
                target = target.split("#")[0].strip()
                if not target:
                    continue
                resolved = os.path.normpath(os.path.join(dirpath, target))
                if not os.path.exists(resolved):
                    bad.append("%s -> %s" % (os.path.relpath(path, ROOT), target))
    if bad:
        print("断链 %d 处：" % len(bad))
        for b in bad[:40]:
            print("  -", b)
        return 1
    print("文档链接正常")
    return 0


if __name__ == "__main__":
    sys.exit(main())
