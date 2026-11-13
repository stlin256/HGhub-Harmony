#!/usr/bin/env python3
"""生成黄果短剧（HGhub Harmony）横屏宣传图。

用法:
  python scripts/harmony/gen-promo.py
  python scripts/harmony/gen-promo.py --src a.jpg --out-dir out --crop-top 128

输入默认取手机截图，裁掉顶部通知栏（默认 128px）；输出 1600x900 PNG。
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ACCENT = (96, 205, 255)
WHITE = (255, 255, 255)
W, H = 1600, 900
FONT_CN = r"C:\Windows\Fonts\msyh.ttc"
FONT_CN_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"
FONT_LATIN = r"C:\Windows\Fonts\seguisb.ttf"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# ── 多语言文案 ────────────────────────────────────────
# 用法：python scripts/harmony/gen-promo.py --lang en
# 输出文件名带 -en 后缀（promo-v1-en.png），中文版保持原文件名不变。
LANG = "zh"

COPY = {
    "zh": {
        "v1_title1": "完全鸿蒙原生",
        "v1_title2": "HGhub 短剧客户端",
        "v1_sub": "ArkTS / ArkUI 原生实现 · 无 WebView",
        "v1_pills": ["平板平行视窗", "线路智能切换", "沉浸式播放", "封面持久化缓存"],
        "v1_foot": "HarmonyOS 7 · API 26",
        "v2_title": "完全鸿蒙原生短剧客户端",
        "v2_sub": "一个 App，完整浏览、选集与沉浸播放。",
        "v2_pills": ["平行视窗", "智能线路", "沉浸播放"],
        "v2_foot": "HarmonyOS 7 · ArkTS / ArkUI",
        "v3_title": "原生 · 沉浸 · 更快",
        "v3_sub": "HGhub，为 HarmonyOS 重新设计",
        "v3_feats": [
            ("平板 / 横屏 / 平行视窗", "左列表 + 右详情，评论侧栏"),
            ("智能线路", "自动探测可用线路，无感切换"),
            ("原生播放器", "预加载 + 本地缓存，切集更快"),
        ],
        "v3_foot": "HarmonyOS 7 · API 26",
        "v4_top": "完全鸿蒙原生",
        "v4_sub": "短剧客户端 · HarmonyOS 7",
        "v4_line": "平行视窗 / 智能线路 / 沉浸播放 / 评论侧栏",
        "v4_foot": "ArkTS / ArkUI · 不套 WebView",
        "v5_accent": "完全鸿蒙原生",
        "v5_sub": "短剧浏览 · 选集 · 沉浸播放，全部原生实现。",
        "v5_line": "平板平行视窗 / 智能线路",
        "v5_foot": "HarmonyOS 7 · API 26",
        "v6_accent": "鸿蒙原生短剧客户端",
        "v6_sub": "平板适配 · 平行视窗 · 沉浸播放",
        "v6_pills": ["ArkTS", "ArkUI", "API 26"],
        "v6_foot": "HarmonyOS 7",
    },
    "en": {
        "v1_title1": "Fully Native",
        "v1_title2": "HGhub Drama Client",
        "v1_sub": "Built with ArkTS / ArkUI · No WebView",
        "v1_pills": ["Tablet Split View", "Smart Line Switch", "Immersive Play", "Cover Cache"],
        "v1_foot": "HarmonyOS 7 · API 26",
        "v2_title": "A Fully Native HarmonyOS Drama Client",
        "v2_sub": "One app for browsing, episode picking and immersive playback.",
        "v2_pills": ["Split View", "Smart Lines", "Immersive"],
        "v2_foot": "HarmonyOS 7 · ArkTS / ArkUI",
        "v3_title": "Native · Immersive · Faster",
        "v3_sub": "HGhub, redesigned for HarmonyOS",
        "v3_feats": [
            ("Tablet / Landscape / Split", "List left, details right, comments sidebar"),
            ("Smart Lines", "Auto-detects live lines and switches seamlessly"),
            ("Native Player", "Preload + local cache for faster switching"),
        ],
        "v3_foot": "HarmonyOS 7 · API 26",
        "v4_top": "Fully Native",
        "v4_sub": "Drama Client · HarmonyOS 7",
        "v4_line": "Split View / Smart Lines / Immersive Play / Comments",
        "v4_foot": "ArkTS / ArkUI · No WebView",
        "v5_accent": "Fully Native",
        "v5_sub": "Browsing, episode picking and immersive playback — all native.",
        "v5_line": "Tablet Split View / Smart Lines",
        "v5_foot": "HarmonyOS 7 · API 26",
        "v6_accent": "Native HarmonyOS Drama Client",
        "v6_sub": "Tablet-ready · Split View · Immersive Play",
        "v6_pills": ["ArkTS", "ArkUI", "API 26"],
        "v6_foot": "HarmonyOS 7",
    },
}


def T(key):
    """取当前语言的文案。"""
    return COPY[LANG][key]


def is_en():
    return LANG == "en"


def font(size: int, bold: bool = False, latin: bool = False):
    return ImageFont.truetype(FONT_LATIN if latin else (FONT_CN_BOLD if bold else FONT_CN), size)


def rgba(c, a=255):
    return (c[0], c[1], c[2], a)


def cover(img, w, h):
    s = max(w / img.width, h / img.height)
    out = img.resize((int(img.width * s + .5), int(img.height * s + .5)), Image.LANCZOS)
    x, y = (out.width - w) // 2, (out.height - h) // 2
    return out.crop((x, y, x + w, y + h))


def rounded_mask(w, h, r):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w - 1, h - 1), radius=r, fill=255)
    return m


def layer_draw(img, fn):
    """在独立透明层绘制（保证半透明颜色正确叠加），再 composite 回 img。"""
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    fn(ImageDraw.Draw(layer))
    img.alpha_composite(layer)


def radial_glow(w, h, cx, cy, radius, color=ACCENT, strength=1.0):
    yy, xx = np.mgrid[0:h, 0:w]
    dist = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    a = np.clip(1.0 - dist / radius, 0, 1) ** 2 * 255 * strength
    arr = np.zeros((h, w, 4), np.uint8)
    arr[..., 0], arr[..., 1], arr[..., 2], arr[..., 3] = color[0], color[1], color[2], a.astype(np.uint8)
    return Image.fromarray(arr, "RGBA")


def gradient(w, h, top, bottom, vertical=True):
    t = (np.linspace(0, 1, h)[:, None] if vertical else np.linspace(0, 1, w)[None, :]).astype(np.float32)
    arr = np.zeros((h, w, 4), np.float32)
    for i in range(4):
        arr[..., i] = top[i] + (bottom[i] - top[i]) * t
    return Image.fromarray(arr.astype(np.uint8), "RGBA")


def background(src, blur=48, dark=.32):
    bg = Image.eval(cover(src, W, H).filter(ImageFilter.GaussianBlur(blur)), lambda v: int(v * dark))
    img = bg.convert("RGBA")
    img.alpha_composite(radial_glow(W, H, W * .80, H * .26, W * .55, strength=.32))
    img.alpha_composite(radial_glow(W, H, W * .12, H * .88, W * .45, strength=.12))
    img.alpha_composite(gradient(W, H, (0, 0, 0, 0), (0, 0, 0, 218)))
    img.alpha_composite(gradient(W, H, (0, 0, 0, 165), (0, 0, 0, 0), vertical=False))
    return img


def phone(src, height, rotate=0.0, radius=42, border=8):
    w = int(height * src.width / src.height)
    scr = src.resize((w, height), Image.LANCZOS)
    fw, fh = w + border * 2, height + border * 2
    frame = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle((0, 0, fw - 1, fh - 1), radius=radius + border,
                                            fill=(20, 23, 28, 255), outline=(255, 255, 255, 26), width=2)
    frame.paste(scr, (border, border), rounded_mask(w, height, radius))
    ImageDraw.Draw(frame).rounded_rectangle((2, 2, fw - 3, fh - 3), radius=radius + border,
                                            outline=(255, 255, 255, 20), width=1)
    if abs(rotate) > .01:
        frame = frame.rotate(rotate, expand=True, resample=Image.BICUBIC)
    return frame


def shadow(img, ph, xy, blur=44, opacity=210, offset=(0, 24)):
    a = ph.split()[-1]
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sh = Image.new("RGBA", ph.size, (0, 0, 0, opacity))
    sh.putalpha(a)
    layer.alpha_composite(sh, (xy[0] + offset[0], xy[1] + offset[1]))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(blur)))


def brand(img, x, y, size=32, logo=None, align="left"):
    d = ImageDraw.Draw(img)
    lx = x
    ls = int(size * 1.5)
    if logo is not None:
        img.alpha_composite(logo.resize((ls, ls), Image.LANCZOS), (lx, y - int(ls * .18)))
        lx += ls + 14
    d.text((lx, y), "黄果短剧", font=font(size, bold=True), fill=WHITE)
    if align == "left":
        d.text((lx + d.textlength("黄果短剧", font=font(size, bold=True)) + 16, y + int(size * .4)),
               "HGhub Harmony", font=font(int(size * .5), latin=True), fill=(255, 255, 255, 120))


def pill(img, x, y, text, size=21):
    f = font(size)
    tw = ImageDraw.Draw(img).textlength(text, font=f)
    h, w = size + 20, int(tw + 34)
    def draw(d):
        d.rounded_rectangle((x, y, x + w, y + h), radius=h // 2, fill=(255, 255, 255, 20),
                            outline=(255, 255, 255, 40), width=1)
        d.text((x + 17, y + h // 2), text, font=f, fill=(255, 255, 255, 215), anchor="lm")
    layer_draw(img, draw)
    return w


def chip(img, x, y, text, size=19):
    f = font(size, bold=True)
    tw = ImageDraw.Draw(img).textlength(text, font=f)
    h, w = size + 18, int(tw + 30)
    def draw(d):
        d.rounded_rectangle((x, y, x + w, y + h), radius=h // 2, fill=(96, 205, 255, 36),
                            outline=(96, 205, 255, 130), width=1)
        d.text((x + 15, y + h // 2), text, font=f, fill=rgba(ACCENT), anchor="lm")
    layer_draw(img, draw)
    return w


def save(img, name, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    img.convert("RGB").save(path, "PNG", optimize=True)
    print("[promo]", path, img.size)


# ── 样式：手机在左，说明在右，只出现 HGhub 品牌 ─────────
TEXT_X = 880


def brand_hg(img, x, y, size=42, logo=None):
    """品牌行：大图标 + 垂直居中的 HGhub 字标 + 下方 HarmonyOS Native。"""
    d = ImageDraw.Draw(img)
    icon = int(size * 1.5)
    cy = y + icon / 2
    if logo is not None:
        img.alpha_composite(logo.resize((icon, icon), Image.LANCZOS), (x, y))
    tx = x + icon + 20
    d.text((tx, cy - size * 0.14), "HGhub", font=font(size, bold=True, latin=True),
           fill=WHITE, anchor="lm")
    d.text((tx + 2, cy + size * 0.62), "HarmonyOS Native",
           font=font(int(size * 0.44), latin=True), fill=(255, 255, 255, 135), anchor="lm")


def v1(src, logo):
    img = background(src)
    ph = phone(src, 850, rotate=-3.5)
    shadow(img, ph, (96, 50))
    img.alpha_composite(ph, (104, 46))
    d = ImageDraw.Draw(img)
    brand_hg(img, 840, 186, 44, logo)
    d.text((840, 292), T("v1_title1"), font=font(66, bold=True, latin=is_en()), fill=WHITE)
    d.text((840, 378), T("v1_title2"), font=font(58, bold=True, latin=is_en()), fill=rgba(ACCENT))
    d.text((840, 474), T("v1_sub"), font=font(22, latin=is_en()), fill=(255, 255, 255, 148))
    pills = T("v1_pills")
    x = 840
    for t in pills[:2]:
        x += pill(img, x, 526, t, 18) + 10
    x = 840
    for t in pills[2:]:
        x += pill(img, x, 576, t, 18) + 10
    layer_draw(img, lambda dd: dd.rounded_rectangle((840, 644, 1060, 646), radius=2,
                                                    fill=rgba(ACCENT, 205)))
    d.text((840, 662), T("v1_foot"), font=font(20, latin=True), fill=(255, 255, 255, 110))
    return img


def v2(src, logo):
    img = background(src, blur=54, dark=.28)
    ph = phone(src, 820, rotate=0)
    shadow(img, ph, (96, 64), blur=48)
    img.alpha_composite(ph, (100, 60))
    d = ImageDraw.Draw(img)
    brand_hg(img, TEXT_X, 116, 30, logo)
    d.text((TEXT_X - 6, 236), "HGhub", font=font(168, bold=True, latin=True), fill=WHITE)
    d.text((TEXT_X, 440), T("v2_title"), font=font(34, bold=True, latin=is_en()), fill=rgba(ACCENT))
    d.text((TEXT_X + 2, 500), T("v2_sub"), font=font(24, latin=is_en()), fill=(255, 255, 255, 155))
    x = TEXT_X
    for t in T("v2_pills"):
        x += pill(img, x, 566, t) + 12
    d.text((TEXT_X + 2, 760), T("v2_foot"), font=font(22, latin=True),
           fill=(255, 255, 255, 110))
    return img


def v3(src, logo):
    img = background(src, blur=56, dark=.24)
    ph = phone(src, 900, rotate=-1.5)
    shadow(img, ph, (-118, 30), blur=46, opacity=200)
    img.alpha_composite(ph, (-112, 26))
    d = ImageDraw.Draw(img)
    brand_hg(img, TEXT_X, 104, 30, logo)
    d.text((TEXT_X, 226), T("v3_title"), font=font(62, bold=True, latin=is_en()), fill=WHITE)
    d.text((TEXT_X + 2, 322), T("v3_sub"), font=font(26, latin=is_en()), fill=(255, 255, 255, 155))
    y = 412
    for title, sub in T("v3_feats"):
        chip(img, TEXT_X, y, title, 19)
        d.text((TEXT_X + 2, y + 40), sub, font=font(21, latin=is_en()), fill=(255, 255, 255, 150))
        y += 96
    d.text((TEXT_X + 2, 790), T("v3_foot"), font=font(22, latin=True), fill=(255, 255, 255, 100))
    return img


def v4(src, logo):
    img = background(src, blur=58, dark=.22)
    # 右侧加深，给文字更干净的底
    def shade(dd):
        dd.rectangle((760, 0, W, H), fill=(6, 8, 12, 120))
    layer_draw(img, shade)
    ph = phone(src, 880, rotate=0)
    shadow(img, ph, (86, 40))
    img.alpha_composite(ph, (90, 36))
    d = ImageDraw.Draw(img)
    d.text((TEXT_X, 150), T("v4_top"), font=font(58, bold=True, latin=is_en()), fill=(255, 255, 255, 225))
    brand_hg(img, TEXT_X, 240, 34, logo)
    d.text((TEXT_X - 4, 372), "HGhub", font=font(140, bold=True, latin=True), fill=WHITE)
    d.text((TEXT_X, 548), T("v4_sub"), font=font(28, latin=is_en()), fill=rgba(ACCENT))
    d.text((TEXT_X + 2, 604), T("v4_line"), font=font(22, latin=is_en()), fill=(255, 255, 255, 150))
    layer_draw(img, lambda dd: dd.rounded_rectangle((TEXT_X, 700, TEXT_X + 360, 703), radius=2,
                                                    fill=rgba(ACCENT, 200)))
    d.text((TEXT_X + 2, 726), T("v4_foot"), font=font(22, latin=True),
           fill=(255, 255, 255, 115))
    return img


def v5(src, logo):
    img = Image.new("RGBA", (W, H), (8, 10, 14, 255))
    img.alpha_composite(radial_glow(W, H, W * .30, H * .52, W * .55, strength=.26))
    img.alpha_composite(radial_glow(W, H, W * .88, H * .16, W * .40, strength=.12))
    ph = phone(src, 840, rotate=3)
    shadow(img, ph, (86, 46))
    img.alpha_composite(ph, (90, 42))
    d = ImageDraw.Draw(img)
    brand_hg(img, TEXT_X + 4, 128, 30, logo)
    d.text((TEXT_X, 292), "HGhub", font=font(150, bold=True, latin=True), fill=WHITE)
    d.text((TEXT_X, 484), T("v5_accent"), font=font(44, bold=True, latin=is_en()), fill=rgba(ACCENT))
    d.text((TEXT_X + 2, 556), T("v5_sub"), font=font(23, latin=is_en()),
           fill=(255, 255, 255, 155))
    layer_draw(img, lambda dd: dd.rounded_rectangle((TEXT_X, 634, TEXT_X + 300, 637), radius=2,
                                                    fill=rgba(ACCENT, 200)))
    d.text((TEXT_X + 2, 662), T("v5_line"), font=font(22, latin=is_en()),
           fill=(255, 255, 255, 140))
    d.text((TEXT_X + 2, 706), T("v5_foot"), font=font(21, latin=True),
           fill=(255, 255, 255, 100))
    return img


def v6(src, logo):
    img = background(src, blur=62, dark=.20)
    ph = phone(src, 940, rotate=-6)
    shadow(img, ph, (-40, 20), blur=50, opacity=210)
    img.alpha_composite(ph, (-34, 16))
    d = ImageDraw.Draw(img)
    brand_hg(img, TEXT_X + 20, 120, 32, logo)
    d.text((TEXT_X + 16, 246), "HGhub", font=font(190, bold=True, latin=True), fill=WHITE)
    d.text((TEXT_X + 20, 500), T("v6_accent"), font=font(40, bold=True, latin=is_en()), fill=rgba(ACCENT))
    d.text((TEXT_X + 20, 574), T("v6_sub"), font=font(24, latin=is_en()),
           fill=(255, 255, 255, 155))
    x = TEXT_X + 20
    for t in T("v6_pills"):
        x += pill(img, x, 646, t, 20) + 12
    d.text((TEXT_X + 20, 760), T("v6_foot"), font=font(22, latin=True), fill=(255, 255, 255, 105))
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.path.join(ROOT, "docs", "promo", "source-home.jpg"))
    ap.add_argument("--out-dir", default=os.path.join(ROOT, "docs", "promo"))
    ap.add_argument("--crop-top", type=int, default=128)
    ap.add_argument("--logo", default=os.path.join(ROOT, "public", "logo.png"))
    ap.add_argument("--only", default="",
                    help="只生成指定编号（如 v1），默认生成全部 6 张")
    ap.add_argument("--lang", default="zh", choices=["zh", "en"],
                    help="文案语言；en 输出 promo-vN-en.png")
    args = ap.parse_args()
    global LANG
    LANG = args.lang
    src = Image.open(args.src).convert("RGB")
    if args.crop_top > 0:
        src = src.crop((0, args.crop_top, src.width, src.height))
    logo = Image.open(args.logo).convert("RGBA").resize((200, 200), Image.LANCZOS)
    variants = {"v1": v1, "v2": v2, "v3": v3, "v4": v4, "v5": v5, "v6": v6}
    targets = {args.only: variants[args.only]} if args.only else variants
    suffix = "" if LANG == "zh" else f"-{LANG}"
    for key, fn in targets.items():
        save(fn(src, logo), f"promo-{key}{suffix}.png", args.out_dir)


if __name__ == "__main__":
    main()
