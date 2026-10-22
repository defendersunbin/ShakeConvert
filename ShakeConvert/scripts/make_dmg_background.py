#!/usr/bin/env python3
"""설치용 DMG 창 배경 이미지 생성 (@1x + @2x). 그라데이션 없는 단색 디자인.

문장을 쓰지 않으므로 어떤 언어 사용자에게도 같은 뜻으로 전달된다.
Finder가 창 크기를 지정한 값보다 크게 여는 경우가 있어, 이미지는 창보다 훨씬 큰 캔버스에 그린다
(디자인은 왼쪽 위 660x420 안에만 두고, 나머지는 같은 바탕색으로 채움 → 흰 여백이 생기지 않음).

사용: python3 scripts/make_dmg_background.py Resources/dmg   (Pillow 필요, 결과물은 커밋되어 있음)
아이콘 위치는 build_dmg.sh의 APP_POS / APPS_POS와 반드시 같아야 한다.
"""
import math
import os
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 660, 420            # 디자인 영역 (창 크기)
CANVAS = (1400, 1000)      # 실제 이미지 크기: 창이 더 크게 열려도 여백 없음
APP = (170, 214)           # ShakeConvert.app 아이콘 중심
APPS = (490, 214)          # Applications 바로가기 중심
LABEL_DY = 80              # 아이콘 중심 → 이름표 중심 (아이콘 크기 128 기준)

BG = (0x14, 0x14, 0x16)
RING = (0x22, 0x23, 0x28)
RING_HI = (0x7C, 0xC4, 0xFF)
TEXT = (0xF2, 0xEF, 0xE8)
DIM = (0x8B, 0x8E, 0x96)
PLATE = (0x78, 0x7A, 0x81)   # 이름표 바탕: 라이트(검은 글자)·다크(흰 글자) 모두 읽히는 중간 톤
SLOT = (0x1C, 0x1D, 0x21)


def font(size, bold=False, k=1):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc" if bold else "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    ):
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, int(size * k))
            except OSError:
                continue
    return ImageFont.load_default()


def stroke(d, pts, width, color):
    """둥근 끝·둥근 이음이 있는 선 (PIL 기본 선은 끝이 각져 있음)"""
    d.line(pts, fill=color, width=int(width), joint="curve")
    r = width / 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)


def render(k):
    img = Image.new("RGB", (CANVAS[0] * k, CANVAS[1] * k), BG)
    d = ImageDraw.Draw(img)

    def P(x, y):
        return (x * k, y * k)

    def polar(cx, cy, r, deg):
        t = math.radians(deg)
        return P(cx + r * math.cos(t), cy - r * math.sin(t))

    # 제목 + 브랜드 마크: 앱의 링 메뉴를 축소한 8조각 링(한 조각에 불)이 흔들리는 모습
    mx, my = 64, 56                       # 마크 중심 (제목 왼쪽)
    m_in, m_out, m_gap = 10, 16.5, 3.2    # 작은 링
    d.text(P(mx + 34, my), "ShakeConvert", font=font(26, True, k), fill=TEXT, anchor="lm")
    for i in range(8):
        c = i * 45
        a0, a1 = c + 22.5 - m_gap, c - 22.5 + m_gap
        poly = [polar(mx, my, m_out, a0 + (a1 - a0) * t / 16) for t in range(17)]
        poly += [polar(mx, my, m_in, a1 + (a0 - a1) * t / 16) for t in range(17)]
        d.polygon(poly, fill=RING_HI if c == 0 else (0x4A, 0x4D, 0x55))
    # 흔들림 호 (양옆, 바깥으로 갈수록 옅게)
    for side in (-1, 1):
        for j, (r, col) in enumerate(((22, DIM), (27, (0x3A, 0x3C, 0x43)))):
            center = 180 if side < 0 else 0
            span = 30 - j * 8
            pts = [polar(mx, my, r, center - span + 2 * span * t / 16) for t in range(17)]
            stroke(d, pts, 2.2 * k, col)

    # 앱 아이콘을 감싸는 링 (앱의 링 메뉴 모티프). 아래쪽은 이름표 자리라 비워 둔다.
    cx, cy = APP
    n, inner, outer, gap = 8, 82, 100, 2.2
    step = 360 / n
    for i in range(n):
        c = i * step
        if abs(((c - 270) + 180) % 360 - 180) < step / 2 + 1:
            continue
        a0, a1 = c + step / 2 - gap, c - step / 2 + gap
        poly = [polar(cx, cy, outer, a0 + (a1 - a0) * s / 30) for s in range(31)]
        poly += [polar(cx, cy, inner, a1 + (a0 - a1) * s / 30) for s in range(31)]
        d.polygon(poly, fill=RING_HI if c == 0 else RING)

    # Applications 자리: 은은한 받침
    ax, ay = APPS
    slot_left = ax - 76
    d.rounded_rectangle([P(ax - 76, ay - 76), P(ax + 76, ay + 76)], radius=28 * k, fill=SLOT)

    # 이름표 바탕 (Finder가 그 위에 이름을 씀)
    for (x, y) in (APP, APPS):
        ly = y + LABEL_DY
        d.rounded_rectangle([P(x - 66, ly - 12), P(x + 66, ly + 12)], radius=12 * k, fill=PLATE)

    # ── 화살표: 곧게 뻗은 선 + 열린 화살촉 ──
    # 받침보다 나중에 그려서 가려지지 않고, 받침 앞에서 여유를 두고 끝난다.
    x0 = cx + outer + 18
    tip = slot_left - 16
    width = 3.5 * k
    stroke(d, [P(x0, cy), P(tip - 2, cy)], width, RING_HI)
    head_len, head_angle = 12, math.radians(38)
    for sign in (-1, 1):
        bx = tip - head_len * math.cos(head_angle)
        by = cy + sign * head_len * math.sin(head_angle)
        stroke(d, [P(bx, by), P(tip, cy)], width, RING_HI)

    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources/dmg"
    os.makedirs(out, exist_ok=True)
    render(1).save(os.path.join(out, "background.png"))
    render(2).save(os.path.join(out, "background@2x.png"))
    print("saved to", out)


if __name__ == "__main__":
    main()
