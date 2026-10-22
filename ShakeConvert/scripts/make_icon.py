#!/usr/bin/env python3
"""ShakeConvert 앱 아이콘(.iconset) 생성기. 그라데이션 없는 플랫 디자인.

사용: python3 scripts/make_icon.py Resources/AppIcon.iconset
(Pillow 필요: pip install pillow) — 결과물은 저장소에 커밋되어 있으므로 일반 빌드에는 필요 없음.
"""
import os
import sys
from PIL import Image, ImageDraw

S = 2048
BG = (22, 23, 26, 255)
OFF = (236, 233, 226, 255)
GOLD = (217, 184, 108, 255)
INK = (22, 23, 26, 255)
INK_SOFT = (22, 23, 26, 70)


def sheet(color, cx, cy, angle, decorate=None, w=620, h=780, r=90):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2], radius=r, fill=color)
    if decorate:
        decorate(d, cx, cy)
    return layer.rotate(angle, resample=Image.BICUBIC, center=(cx, cy))


def text_lines(d, cx, cy):
    x0 = cx - 190
    for dy, width in ((-110, 300), (-30, 300), (50, 190)):
        d.rounded_rectangle([x0, cy + dy - 17, x0 + width, cy + dy + 17], radius=17, fill=INK_SOFT)


def arrows(d, cx, cy):
    t = 34

    def arrow(y, x_from, x_to):
        d.rounded_rectangle([min(x_from, x_to), y - t / 2, max(x_from, x_to), y + t / 2], radius=t / 2, fill=INK)
        sign = 1 if x_to > x_from else -1
        d.polygon([(x_to, y - 2.3 * t), (x_to + sign * 1.9 * t, y), (x_to, y + 2.3 * t)], fill=INK)

    arrow(cy - 75, cx - 150, cx + 80)   # →
    arrow(cy + 75, cx + 150, cx - 80)   # ←


def render():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    m = 200
    d.rounded_rectangle([m, m, S - m, S - m], radius=380, fill=BG)
    img.alpha_composite(sheet(OFF, 800, 1040, 9, text_lines))
    img.alpha_composite(sheet(GOLD, 1250, 1000, -9, arrows))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([m, m, S - m, S - m], radius=380, outline=(255, 255, 255, 20), width=4)
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.iconset"
    os.makedirs(out, exist_ok=True)
    master = render()
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
    master.resize((1024, 1024), Image.LANCZOS).save(os.path.join(out, "..", "AppIcon-preview.png"))
    print("saved to", out)


if __name__ == "__main__":
    main()
