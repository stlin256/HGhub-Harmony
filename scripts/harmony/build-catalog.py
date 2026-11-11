#!/usr/bin/env python3
"""由交付包 catalog_index.json 生成随包精简目录（catalog_full.json）。

用法:
  python scripts/harmony/build-catalog.py       --index scripts/harmony/.local/recsys-deliverable/hghub-recsys-deliverable/data/catalog_index.json       --out harmony/entry/src/main/resources/rawfile/recommend/catalog_full.json

输出结构（数组优先，压缩体积）:
  {
    "v": "2026.11.11",
    "cates": ["ai-duanju", ...],
    "items": [
      [id, title, cover, labels[], pop, cateIdx, eps, score, hot, finished, author, lastEpAt],
      ...
    ]
  }

说明:
  - 只从公开目录索引提取，不包含任何账号/凭据；
  - 封面为索引里的去签名 URL（实测可直接下载）；
  - 打标结果（lb）来自交付包，运行时无需重新打标；
  - 作为冷启动/离线/首屏推荐基座，随包分发，避免每个用户首次启动都去抓取服务器。
"""
import argparse
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATE_ORDER = ["ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai"]
DEFAULT_INDEX = os.path.join(
    ROOT, "scripts", "harmony", ".local", "recsys-deliverable",
    "hghub-recsys-deliverable", "data", "catalog_index.json")
DEFAULT_OUT = os.path.join(
    ROOT, "harmony", "entry", "src", "main", "resources", "rawfile", "recommend", "catalog_full.json")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--index", default=DEFAULT_INDEX)
    ap.add_argument("--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    with open(args.index, encoding="utf-8") as f:
        index = json.load(f)
    items = index.get("items") or {}
    if not items:
        raise SystemExit("catalog_index.json has no items")

    rows = []
    max_hot = 1
    for k, v in items.items():
        hot = float(v.get("h") or 0)
        if hot > max_hot:
            max_hot = hot

    for k, v in items.items():
        try:
            vid = int(k)
        except ValueError:
            continue
        cover = (v.get("cv") or "").strip()
        # 只保留 https 绝对地址；缺失时置空（运行时走 API）。
        if cover and not cover.startswith("http"):
            cover = ""
        labels = v.get("lb") or []
        if not isinstance(labels, list):
            labels = []
        labels = [int(x) for x in labels if isinstance(x, (int, float))][:12]
        cate = v.get("c") or ""
        try:
            cate_idx = CATE_ORDER.index(cate)
        except ValueError:
            cate_idx = -1
        hot = float(v.get("h") or 0)
        pop = round(hot / max_hot, 4) if max_hot > 0 else 0.5
        row = [
            vid,
            (v.get("t") or "").strip(),
            cover,
            labels,
            pop,
            cate_idx,
            int(v.get("e") or 0),
            round(float(v.get("s") or 0), 2),
            int(hot),
            1 if v.get("f") else 0,
            (v.get("au") or "").strip(),
            int(v.get("la") or 0),
        ]
        rows.append(row)

    rows.sort(key=lambda r: r[0])
    out = {
        "v": index.get("version") or "",
        "cates": CATE_ORDER,
        "items": rows,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    size = os.path.getsize(args.out)
    print(f"[catalog] items={len(rows)} size={size/1024:.1f} KB -> {args.out}")
    print(f"[catalog] sample={json.dumps(rows[0], ensure_ascii=False)[:220]}")


if __name__ == "__main__":
    main()
