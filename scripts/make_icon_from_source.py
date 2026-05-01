#!/usr/bin/env python3
"""
Берёт пользовательский референс и делает из него .icns без перерисовки.
Просто паддит до квадрата 1024×1024 и нарезает во все нужные размеры.
"""
from pathlib import Path
from PIL import Image
import subprocess
import shutil

ROOT = Path(__file__).parent.parent
ICONS = ROOT / "App" / "icons"
SOURCE = Path("/tmp/qj_source.png")  # копия пользовательского файла

iconset = ICONS / "AppIcon.iconset"
if iconset.exists():
    shutil.rmtree(iconset)
iconset.mkdir(parents=True)

# Загружаем оригинал
src = Image.open(SOURCE).convert("RGBA")
sw, sh = src.size

# Делаем квадратным (padding до max(width, height) с фоном из левого-верхнего пикселя)
side = max(sw, sh)
bg_color = src.getpixel((0, 0))  # цвет фона из угла (обычно белый)
square = Image.new("RGBA", (side, side), bg_color)
square.paste(src, ((side - sw) // 2, (side - sh) // 2), src)

# Скейлим до 1024 (стандартный размер для иконок macOS)
base = square.resize((1024, 1024), Image.Resampling.LANCZOS)
base.save(ICONS / "icon_1024.png")

sizes = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for px, name in sizes:
    if px == 1024:
        base.save(iconset / name)
    else:
        base.resize((px, px), Image.Resampling.LANCZOS).save(iconset / name)

icns = ICONS / "AppIcon.icns"
subprocess.run(["iconutil", "-c", "icns", "-o", str(icns), str(iconset)], check=True)
print(f"→ {icns} ({icns.stat().st_size / 1024:.1f} KB)")
