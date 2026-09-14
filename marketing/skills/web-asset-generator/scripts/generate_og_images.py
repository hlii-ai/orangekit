#!/usr/bin/env python3
"""Pillow-based OG/social image generation (offline mode).

Usage: generate_og_images.py --title "title" --out <dir>
     [--subtitle "subtitle"] [--logo <path>] [--bg "#0F172A"] [--fg "#FFFFFF"]
Output: og-image.png (1200x630, Facebook/LinkedIn) · twitter-card.png (1200x600)
"""
import argparse, sys
from pathlib import Path

SIZES = {"og-image.png": (1200, 630), "twitter-card.png": (1200, 600)}

def load_font(size: int):
    from PIL import ImageFont
    for p in ("/System/Library/Fonts/AppleSDGothicNeo.ttc",
              "/System/Library/Fonts/Helvetica.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default()

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--subtitle", default="")
    ap.add_argument("--logo", default=None)
    ap.add_argument("--bg", default="#0F172A")
    ap.add_argument("--fg", default="#FFFFFF")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    from PIL import Image, ImageDraw
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

    for name, (w, h) in SIZES.items():
        img = Image.new("RGB", (w, h), a.bg)
        d = ImageDraw.Draw(img)
        x = 96
        if a.logo and Path(a.logo).is_file():
            logo = Image.open(a.logo).convert("RGBA")
            logo.thumbnail((160, 160), Image.LANCZOS)
            img.paste(logo, (x, 88), logo)
        title_font, sub_font = load_font(72), load_font(36)
        # Wrap the title (roughly 22 characters per line)
        words, lines, cur = a.title.split(), [], ""
        for wd in words:
            if len(cur + " " + wd) > 22 and cur:
                lines.append(cur); cur = wd
            else:
                cur = (cur + " " + wd).strip()
        lines.append(cur)
        y = h // 2 - len(lines) * 44
        for ln in lines[:3]:
            d.text((x, y), ln, fill=a.fg, font=title_font); y += 88
        if a.subtitle:
            d.text((x, y + 12), a.subtitle[:60], fill=a.fg, font=sub_font)
        img.save(out / name, "PNG")
        print(f"OK {out / name} ({(out / name).stat().st_size:,}B)")
    return 0

if __name__ == "__main__":
    sys.exit(main())
