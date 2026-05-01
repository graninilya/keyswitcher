#!/usr/bin/env python3
"""
Иконка Q*Й — горизонтальная синяя «капсула» с буквами Q*Й в центре
и двумя дугообразными стрелками сверху и снизу (намёк на свап раскладки).

Дизайн взят из пользовательского референса.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import math
import subprocess
import shutil

ROOT = Path(__file__).parent.parent
OUT = ROOT / "App" / "icons"
OUT.mkdir(parents=True, exist_ok=True)


def find_font(size: int) -> ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/SFCompactRounded.ttf",
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for p in candidates:
        if Path(p).exists():
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def render_letter(text: str, font, color, padding=20) -> Image.Image:
    bbox = font.getbbox(text)
    w = bbox[2] - bbox[0] + padding * 2
    h = bbox[3] - bbox[1] + padding * 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(img).text((padding - bbox[0], padding - bbox[1]),
                              text, font=font, fill=color)
    return img


def draw_arrow_arc(draw: ImageDraw.ImageDraw, cx: int, cy: int, rx: int, ry: int,
                    start_deg: float, end_deg: float, thickness: int,
                    color, arrow_at_end: bool = True, head_size: int = 30):
    """Рисует дугу с наконечником-стрелкой на конце."""
    # Сама дуга — толстая линия по эллипсу
    bbox = (cx - rx, cy - ry, cx + rx, cy + ry)
    draw.arc(bbox, start=start_deg, end=end_deg, fill=color, width=thickness)

    # Наконечник
    tip_deg = end_deg if arrow_at_end else start_deg
    rad = math.radians(tip_deg)
    tip_x = cx + rx * math.cos(rad)
    tip_y = cy + ry * math.sin(rad)

    # Касательная к дуге в этой точке (направление движения)
    tan_deg = tip_deg + (90 if arrow_at_end else -90)
    tan_rad = math.radians(tan_deg)

    # Две точки наконечника по бокам от направления
    back_offset = head_size
    side_offset = head_size * 0.7
    back_x = tip_x - back_offset * math.cos(tan_rad)
    back_y = tip_y - back_offset * math.sin(tan_rad)
    perp_rad = tan_rad + math.pi / 2
    p1 = (back_x + side_offset * math.cos(perp_rad),
          back_y + side_offset * math.sin(perp_rad))
    p2 = (back_x - side_offset * math.cos(perp_rad),
          back_y - side_offset * math.sin(perp_rad))

    draw.polygon([(tip_x, tip_y), p1, p2], fill=color)


def draw_icon(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (245, 247, 252, 255))  # светло-серо-голубой фон
    draw = ImageDraw.Draw(img)

    # ─── Капсула (горизонтальный rounded rect) ──────────────────────────
    pill_w = int(size * 0.78)
    pill_h = int(size * 0.42)
    pill_x = (size - pill_w) // 2
    pill_y = (size - pill_h) // 2
    pill_radius = int(pill_h * 0.35)

    # Градиент внутри капсулы — от светлого голубого к насыщенному синему
    pill_layer = Image.new("RGBA", (pill_w, pill_h), (0, 0, 0, 0))
    pill_grad = Image.new("RGB", (pill_w, pill_h), (0, 0, 0))
    pg_draw = ImageDraw.Draw(pill_grad)
    top = (90, 142, 255)      # светлый голубой
    bottom = (50, 90, 230)    # насыщенный синий
    for y in range(pill_h):
        t = y / pill_h
        r = int(top[0] * (1 - t) + bottom[0] * t)
        g = int(top[1] * (1 - t) + bottom[1] * t)
        b = int(top[2] * (1 - t) + bottom[2] * t)
        pg_draw.line([(0, y), (pill_w, y)], fill=(r, g, b))

    pill_mask = Image.new("L", (pill_w, pill_h), 0)
    ImageDraw.Draw(pill_mask).rounded_rectangle(
        [(0, 0), (pill_w, pill_h)], radius=pill_radius, fill=255
    )
    pill_layer.paste(pill_grad, (0, 0), pill_mask)
    img.alpha_composite(pill_layer, (pill_x, pill_y))

    # ─── Буквы Q * Й внутри капсулы ──────────────────────────────────────
    font_size = int(pill_h * 0.62)
    font = find_font(font_size)
    star_font = find_font(int(font_size * 0.85))
    white = (255, 255, 255, 255)

    q_layer = render_letter("Q", font, white)
    yi_layer = render_letter("Й", font, white)
    star_layer = render_letter("*", star_font, white)

    qw, qh = q_layer.size
    yw, yh = yi_layer.size
    sw, sh = star_layer.size

    kern = int(size * 0.005)
    total_w = qw + kern + sw + kern + yw
    start_x = (size - total_w) // 2
    center_y = pill_y + pill_h // 2

    img.alpha_composite(q_layer,
        (start_x, center_y - qh // 2))
    img.alpha_composite(star_layer,
        (start_x + qw + kern, center_y - sh // 2 + int(size * 0.02)))
    img.alpha_composite(yi_layer,
        (start_x + qw + kern + sw + kern, center_y - yh // 2))

    # ─── Стрелки сверху и снизу ──────────────────────────────────────────
    arrow_color = (60, 110, 240, 255)  # тот же синий что и капсула
    arrow_thick = max(8, int(size * 0.030))
    head_size = int(size * 0.045)

    # Верхняя дуга — слева направо, наконечник справа
    cx = size // 2
    arc_rx = int(size * 0.34)
    arc_ry = int(size * 0.18)
    top_cy = pill_y - int(size * 0.02)
    draw_arrow_arc(draw, cx, top_cy, arc_rx, arc_ry,
                   start_deg=200, end_deg=340,
                   thickness=arrow_thick, color=arrow_color,
                   arrow_at_end=True, head_size=head_size)

    # Нижняя дуга — справа налево, наконечник слева
    bot_cy = pill_y + pill_h + int(size * 0.02)
    draw_arrow_arc(draw, cx, bot_cy, arc_rx, arc_ry,
                   start_deg=20, end_deg=160,
                   thickness=arrow_thick, color=arrow_color,
                   arrow_at_end=True, head_size=head_size)

    return img


def main():
    iconset = OUT / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

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

    base = draw_icon(1024)
    base.save(OUT / "icon_1024.png")

    for px, name in sizes:
        if px == 1024:
            base.save(iconset / name)
        else:
            resized = base.resize((px, px), Image.Resampling.LANCZOS)
            resized.save(iconset / name)

    icns_path = OUT / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", "-o", str(icns_path), str(iconset)], check=True
    )
    print(f"→ {icns_path} ({icns_path.stat().st_size / 1024:.1f} KB)")
    print(f"→ Превью: {OUT / 'icon_1024.png'}")


if __name__ == "__main__":
    main()
