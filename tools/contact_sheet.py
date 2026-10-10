#!/usr/bin/env python3
"""Tile `glassfilm render` output into one labeled contact sheet.
usage: python3 tools/contact_sheet.py <render-dir> <out.jpg> [original.jpg]"""
import json, pathlib, sys
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parents[1]
films = json.loads((ROOT / "profiles/film-stocks.json").read_text())["films"]
src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
tiles = [(f["displayName"] if f["id"] != "digital-neutral" else "Original", src / f"{f['id']}.jpg") for f in films]
tiles = tiles[:-1]  # drop digital-neutral; the untouched original goes first
if len(sys.argv) > 3:
    tiles = [("Original", pathlib.Path(sys.argv[3]))] + tiles
cell, label, cols = 300, 34, 6
rows = (len(tiles) + cols - 1) // cols
sheet = Image.new("RGB", (cols * cell, rows * (cell + label)), (16, 16, 16))
draw = ImageDraw.Draw(sheet)
try:
    font = ImageFont.truetype("/System/Library/Fonts/SFNSMono.ttf", 17)
except OSError:
    font = ImageFont.load_default()
for i, (name, path) in enumerate(tiles):
    x, y = (i % cols) * cell, (i // cols) * (cell + label)
    tile = Image.open(path).convert("RGB")
    side = min(tile.size)
    tile = tile.crop(((tile.width - side) // 2, (tile.height - side) // 2, (tile.width + side) // 2, (tile.height + side) // 2))
    sheet.paste(tile.resize((cell - 6, cell - 6), Image.LANCZOS), (x + 3, y + 3))
    draw.text((x + 8, y + cell + 6), name, fill=(255, 215, 0) if name == "Original" else (235, 235, 235), font=font)
sheet.save(out, quality=88, optimize=True)
print(out)
