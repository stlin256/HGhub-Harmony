#!/usr/bin/env python3
"""生成 HGhub 应用图标（HG 标识加大版）。

用法: python scripts/harmony/gen-icons.py
产物写入 AppScope 与 entry 两套 resources（两处都要有，保持一致）。
"""
from PIL import Image, ImageDraw, ImageFont
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIRS = [
    os.path.join(ROOT, "harmony", "AppScope", "resources", "base", "media"),
    os.path.join(ROOT, "harmony", "entry", "src", "main", "resources", "base", "media"),
]

SIZE = 1024
BG = (96, 205, 255, 255)      # #60CDFF
INK = (0, 48, 66, 255)        # #003042
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\seguisb.ttf",
    r"C:\Windows\Fonts\arialbd.ttf",
    r"C:\Windows\Fonts\seguibl.ttf",
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\Deng.ttf",
]


def load_font(px: int) -> ImageFont.FreeTypeFont:
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, px)
            except Exception:
                continue
    raise SystemExit("no usable bold font found")


def glyph_mask(px_height: int) -> Image.Image:
    """把 HG 画到临时透明画布上，返回裁切到字形边界的 mask。"""
    tmp = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(tmp)
    font = load_font(px_height)
    text = "HG"
    bbox = draw.textbbox((0, 0), text, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    # 以字面高度为目标：先按比例反推字号再画一次
    font2 = load_font(max(10, int(px_height * px_height / max(1, h))))
    bbox2 = draw.textbbox((0, 0), text, font=font2)
    w2 = bbox2[2] - bbox2[0]
    h2 = bbox2[3] - bbox2[1]
    canvas = Image.new("RGBA", (w2 + 8, h2 + 8), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    d.text((4 - bbox2[0], 4 - bbox2[1]), text, font=font2, fill=INK)
    return canvas.crop(canvas.getbbox())


def compose_glyph(canvas: Image.Image, target_w_ratio: float) -> None:
    """按画布宽度比例放置 HG 字形（等比），水平垂直居中，光学上略上移。"""
    target_w = int(SIZE * target_w_ratio)
    base = glyph_mask(SIZE // 2)
    scale = target_w / base.width
    glyph = base.resize((max(1, int(base.width * scale)), max(1, int(base.height * scale))),
                        Image.LANCZOS)
    x = (SIZE - glyph.width) // 2
    y = (SIZE - glyph.height) // 2 - int(SIZE * 0.005)
    canvas.alpha_composite(glyph, (x, y))


def build_flat() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    r = int(SIZE * 0.225)
    shape = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(shape).rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=r, fill=255)
    bg = Image.new("RGBA", (SIZE, SIZE), BG)
    img.paste(bg, (0, 0), shape)
    compose_glyph(img, 0.60)
    return img


def build_background() -> Image.Image:
    return Image.new("RGBA", (SIZE, SIZE), BG)


def build_foreground() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    compose_glyph(img, 0.54)
    return img


def main() -> None:
    flat = build_flat()
    background = build_background()
    foreground = build_foreground()
    for directory in DIRS:
        os.makedirs(directory, exist_ok=True)
        flat.save(os.path.join(directory, "app_icon.png"))
        background.save(os.path.join(directory, "app_icon_background.png"))
        foreground.save(os.path.join(directory, "app_icon_foreground.png"))
        print("[icons]", directory)


if __name__ == "__main__":
    main()
