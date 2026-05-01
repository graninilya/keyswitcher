#!/usr/bin/env python3
"""
SVG → PDF/PNG для menu bar.
Обрезает прозрачные края чтобы лого заполнял иконку максимально.
"""
from pathlib import Path
import cairosvg
from PIL import Image
import io

ROOT = Path(__file__).parent.parent
OUT = ROOT / "App" / "Sources" / "keySwitcher" / "Resources"
OUT.mkdir(parents=True, exist_ok=True)
SOURCE = Path("/Users/ilyagranin/Downloads/GeneratedImageMay012026-5_09PM-nobg-2x-convertico-.svg")

for old in OUT.glob("StatusIcon*"):
    old.unlink()

svg_data = SOURCE.read_bytes()

# Рендерим SVG в большой PNG для обрезки
big_png_bytes = cairosvg.svg2png(bytestring=svg_data, output_width=2048, output_height=2048)
img = Image.open(io.BytesIO(big_png_bytes)).convert("RGBA")

# Обрезаем по непрозрачным пикселям + минимальный паддинг
bbox = img.getbbox()
if bbox:
    cropped = img.crop(bbox)
    pad = int(max(cropped.size) * 0.04)
    sized = Image.new("RGBA",
                      (cropped.width + pad * 2, cropped.height + pad * 2),
                      (0, 0, 0, 0))
    sized.paste(cropped, (pad, pad), cropped)
else:
    sized = img

aspect = sized.width / sized.height

# Высота 22pt, ширина по пропорциям (на retina ×2 и ×3)
def out_size(h):
    return (int(round(h * aspect)), h)

for name, h in [("StatusIcon.png", 22), ("StatusIcon@2x.png", 44), ("StatusIcon@3x.png", 66)]:
    sized.resize(out_size(h), Image.Resampling.LANCZOS).save(OUT / name)

# PDF в большом разрешении
sized.resize(out_size(512), Image.Resampling.LANCZOS).save(
    OUT / "StatusIcon.pdf", "PDF", resolution=288.0
)
print(f"Аспект: {aspect:.3f} (w/h)")

print("Готово:")
for f in sorted(OUT.glob("StatusIcon*")):
    print(f"  {f.name}: {f.stat().st_size} B")
