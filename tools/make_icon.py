#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Sniff App 图标生成器 —— "简与白"极简风格
构图：白底 + 深灰细线放大镜（镜片内三道信号弧），寓意"嗅探/探测隐藏资源"
产出：
  Sniff/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png  各尺寸
  Design/icon.svg            矢量源文件（可交给设计师改）
  Design/icon_preview.png     圆角桌面预览效果图
"""
import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Sniff", "Resources", "Assets.xcassets", "AppIcon.appiconset")
DESIGN_DIR = os.path.join(ROOT, "Design")
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(DESIGN_DIR, exist_ok=True)

INK = (29, 29, 31, 255)      # #1D1D1F 深灰（简与白同款墨色）
BG = (255, 255, 255, 255)    # 纯白

# ---- 设计参数（以 1024 画布为基准，按比例缩放） ----
CENTER = (0.4395, 0.4492)    # 放大镜镜片圆心
RING_RADIUS = 0.244          # 镜片圆环半径
RING_WIDTH = 0.0449          # 圆环线宽
HANDLE_LEN = 0.176           # 手柄长度
HANDLE_WIDTH = 0.0566        # 手柄粗细
WAVE_RADII = (0.078, 0.129, 0.180)  # 镜片内三道信号弧半径
WAVE_ANGLE = (-55, 25)       # 信号弧张角（度，0°指向 3 点钟，逆时针为正）


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), BG)
    d = ImageDraw.Draw(img)
    cx, cy = CENTER[0] * size, CENTER[1] * size

    def pt(radius, deg):
        rad = math.radians(deg)
        return (cx + radius * math.cos(rad), cy + radius * math.sin(rad))

    # 1. 镜片圆环
    ring = RING_RADIUS * size
    w = max(1, round(RING_WIDTH * size))
    d.ellipse([cx - ring, cy - ring, cx + ring, cy + ring],
              outline=INK, width=w)

    # 2. 手柄（45° 方向，圆头）
    hw = HANDLE_WIDTH * size
    start = pt(ring * 0.92, 45)
    end = pt(ring * 0.92 + HANDLE_LEN * size, 45)
    d.line([start, end], fill=INK, width=round(hw))
    d.ellipse([end[0] - hw / 2, end[1] - hw / 2, end[0] + hw / 2, end[1] + hw / 2], fill=INK)

    # 3. 镜片内三道信号弧（向右上探测）
    for r in WAVE_RADII:
        rr = r * size
        a0, a1 = WAVE_ANGLE
        d.arc([cx - rr, cy - rr, cx + rr, cy + rr],
              start=a0, end=a1, fill=INK, width=w)

    return img


def svg_source() -> str:
    cx, cy = CENTER[0] * 1024, CENTER[1] * 1024
    ring = RING_RADIUS * 1024
    ink = "#1D1D1F"
    parts = [
        f'<rect width="1024" height="1024" fill="#FFFFFF"/>',
        f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{ring:.1f}" fill="none" stroke="{ink}" stroke-width="{RING_WIDTH*1024:.1f}"/>',
    ]
    # 手柄
    a = math.radians(45)
    sx, sy = cx + ring * 0.92 * math.cos(a), cy + ring * 0.92 * math.sin(a)
    ex, ey = cx + (ring * 0.92 + HANDLE_LEN * 1024) * math.cos(a), cy + (ring * 0.92 + HANDLE_LEN * 1024) * math.sin(a)
    parts.append(f'<line x1="{sx:.1f}" y1="{sy:.1f}" x2="{ex:.1f}" y2="{ey:.1f}" stroke="{ink}" stroke-width="{HANDLE_WIDTH*1024:.1f}" stroke-linecap="round"/>')
    # 信号弧（SVG 角度：0° 指向 3 点钟，顺时针为正，与 PIL 相反 → 取负）
    for r in WAVE_RADII:
        rr = r * 1024
        a0, a1 = WAVE_ANGLE
        p0 = (cx + rr * math.cos(math.radians(a0)), cy - rr * math.sin(math.radians(a0)))
        p1 = (cx + rr * math.cos(math.radians(a1)), cy - rr * math.sin(math.radians(a1)))
        parts.append(
            f'<path d="M {p0[0]:.1f} {p0[1]:.1f} A {rr:.1f} {rr:.1f} 0 0 1 {p1[0]:.1f} {p1[1]:.1f}" '
            f'fill="none" stroke="{ink}" stroke-width="{RING_WIDTH*1024:.1f}" stroke-linecap="round"/>'
        )
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  '
            + "\n  ".join(parts) + "\n</svg>\n")


def rounded(img: Image.Image, radius_ratio: float = 0.2237) -> Image.Image:
    """iOS 主屏幕圆角近似，仅用于预览"""
    size = img.size[0]
    r = int(size * radius_ratio)
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size, size], radius=r, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main():
    sizes = {
        "icon_20@1x.png": 20, "icon_20@2x.png": 40, "icon_20@3x.png": 60,
        "icon_29@1x.png": 29, "icon_29@2x.png": 58, "icon_29@3x.png": 87,
        "icon_40@1x.png": 40, "icon_40@2x.png": 80, "icon_40@3x.png": 120,
        "icon_76@1x.png": 76, "icon_76@2x.png": 152,
        "icon_83.5@2x.png": 167,
        "icon_60@2x.png": 120, "icon_60@3x.png": 180,
        "icon_1024.png": 1024,
    }
    for name, px in sizes.items():
        draw_icon(px).save(os.path.join(OUT_DIR, name))
        print(f"  ✓ {name} ({px}px)")

    with open(os.path.join(DESIGN_DIR, "icon.svg"), "w", encoding="utf-8") as f:
        f.write(svg_source())
    print("  ✓ Design/icon.svg")

    # 预览图：灰色桌面 + 圆角图标
    big = draw_icon(1024)
    preview = Image.new("RGBA", (1200, 1400), (242, 242, 247, 255))
    preview.paste(rounded(big, 0.2237), (88, 120), rounded(big, 0.2237))
    preview.save(os.path.join(DESIGN_DIR, "icon_preview.png"))
    print("  ✓ Design/icon_preview.png")
    print("完成：图标全部生成")


if __name__ == "__main__":
    main()
