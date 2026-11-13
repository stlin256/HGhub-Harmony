#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
敏感信息与危险 API 扫描：
  - 凭据模式：GitHub PAT、AWS Key、私钥块、明文 password/token
  - 禁止入库的文件：*.p12 / *.p7b / *.cer / *.keystore / *.jks / .env
  - 危险 API：eval( / new Function( / innerHTML / document.write
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKIP_DIRS = {".git", "node_modules", "oh_modules", "build", ".hvigor", "dist"}
SKIP_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".ico", ".ms", ".srs", ".zip", ".gz", ".hap"}

FORBIDDEN_EXT = {".p12", ".p7b", ".cer", ".keystore", ".jks", ".csr"}
FORBIDDEN_NAMES = {".env"}

PATTERNS = [
    ("GitHub PAT", re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}")),
    ("GitHub fine-grained PAT", re.compile(r"github_pat_[A-Za-z0-9_]{20,}")),
    ("AWS Access Key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("私钥块", re.compile(r"BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY")),
    ("明文 password", re.compile(r"(?i)\bpassword\s*[:=]\s*['\"][^'\"]{4,}['\"]")),
    ("明文 token", re.compile(r"(?i)\btoken\s*[:=]\s*['\"][A-Za-z0-9_\-]{16,}['\"]")),
]

DANGEROUS = [
    ("eval(", re.compile(r"\beval\s*\(")),
    ("new Function(", re.compile(r"new\s+Function\s*\(")),
    ("innerHTML", re.compile(r"\.innerHTML\s*=")),
    ("document.write", re.compile(r"document\.write\s*\(")),
]

errors = []


def scan_file(path):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    ext = os.path.splitext(path)[1].lower()
    name = os.path.basename(path)
    if ext in FORBIDDEN_EXT or name in FORBIDDEN_NAMES:
        errors.append("禁止入库的文件: " + rel)
        return
    if ext in SKIP_EXT:
        return
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except Exception:  # noqa: BLE001
        return
    for label, pattern in PATTERNS:
        m = pattern.search(text)
        if m:
            line = text[:m.start()].count("\n") + 1
            errors.append("%s: %s:%d" % (label, rel, line))
    if ext in (".ets", ".ts", ".js"):
        for label, pattern in DANGEROUS:
            m = pattern.search(text)
            if m:
                line = text[:m.start()].count("\n") + 1
                errors.append("危险 API %s: %s:%d" % (label, rel, line))


def main():
    count = 0
    for dirpath, dirnames, files in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for f in files:
            count += 1
            scan_file(os.path.join(dirpath, f))
    print("  扫描 %d 个文件" % count)
    if errors:
        print("\n失败项：")
        for e in errors[:40]:
            print("  -", e)
        return 1
    print("  未发现敏感信息与危险 API")
    return 0


if __name__ == "__main__":
    sys.exit(main())
