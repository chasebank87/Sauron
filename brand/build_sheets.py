#!/usr/bin/env python3
"""Presentation sheets for the Sauron brand kit."""
import os
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.abspath(__file__))
EXP = os.path.join(ROOT, "exports"); SHEET = os.path.join(ROOT, "sheets")
FDIR = os.path.join(ROOT, "fonts/inter/extras/ttf")
os.makedirs(SHEET, exist_ok=True)

INK = (10, 11, 13); PAPER = (246, 247, 249)
T1 = (242, 243, 245); T2 = (154, 160, 172); T3 = (118, 125, 140)
IRIS = (107, 114, 255); EMBER = (255, 122, 24)

def F(w, s):
    return ImageFont.truetype(os.path.join(FDIR, f"Inter-{w}.ttf"), s)

def load(name, size=None):
    im = Image.open(os.path.join(EXP, name)).convert("RGBA")
    if size:
        im = im.resize((size, max(1, int(size * im.height / im.width))), Image.LANCZOS)
    return im

def text(d, xy, s, font, fill=T1, tracking=0):
    if not tracking:
        d.text(xy, s, font=font, fill=fill)
        return d.textlength(s, font=font)
    x, y = xy
    for ch in s:
        d.text((x, y), ch, font=font, fill=fill)
        x += d.textlength(ch, font=font) + tracking
    return x - xy[0]

def header(d, sub):
    w = text(d, (80, 66), "Sauron", F("SemiBold", 54), T1)
    text(d, (80 + w + 26, 84), sub, F("Medium", 30), T2)
    d.line((80, 150, 2320, 150), fill=(255, 255, 255, 22), width=1)

def overline(d, xy, s):
    text(d, xy, s.upper(), F("SemiBold", 19), T3, tracking=2.2)

def bullets(d, x, y, items, dot=IRIS, gap=44):
    for it in items:
        d.ellipse((x + 2, y + 12, x + 10, y + 20), fill=dot)
        text(d, (x + 30, y), it, F("Regular", 26), T2)
        y += gap
    return y

# ================================================================ sheet 1 · app icon
W, H = 2400, 1330
c = Image.new("RGB", (W, H), INK); d = ImageDraw.Draw(c)
header(d, "macOS app icon")

hero = load("icon-macos-1024.png", 600)
c.paste(hero, (80, 210), hero)
overline(d, (80, 850), "Default · dark appearance")
text(d, (80, 886), "1024 px layered source: background + foreground,", F("Regular", 26), T2)
text(d, (80, 922), "no baked corners, gloss, or shadow — Icon Composer", F("Regular", 26), T2)
text(d, (80, 958), "applies the Liquid Glass material.", F("Regular", 26), T2)

TILE, PITCH, X0, Y0 = 280, 348, 780, 210
variants = [("icon-macos-light-1024.png", "Light"),
            ("icon-mono-tile-1024.png", "Mono"),
            ("icon-foreground-1024.png", "Foreground"),
            ("icon-background-1024.png", "Background")]
for i, (fn, label) in enumerate(variants):
    x = X0 + i * PITCH
    im = load(fn, TILE)
    if label == "Foreground":
        plate = Image.new("RGBA", im.size, (28, 30, 38, 255))
        im = Image.alpha_composite(plate, im)
    c.paste(im, (x, Y0), im)
    overline(d, (x, Y0 + TILE + 22), label)

overline(d, (X0, 600), "Size ladder · rendered at each size, never downscaled")
x, base = X0, 660 + 256
for s in (256, 128, 64, 32, 16):
    im = load(f"icon-macos-{s}.png", s)
    c.paste(im, (x, base - s), im)
    text(d, (x, base + 18), f"{s} px", F("Medium", 22), T3)
    x += s + 56
text(d, (X0, base + 76), "16 and 32 px swap to the simplified mark: heavier ring, no signal arcs.",
     F("Regular", 26), T2)

overline(d, (X0, base + 160), "Construction")
bullets(d, X0, base + 200, [
    "Almond ring — two mirrored cubic arcs, 50 px stroke, round joins.",
    "Ember slit — full-height vertical lens piercing the lid, with one specular core dot.",
    "Signal arcs — concentric lids at 50% opacity: the eye that listens.",
    "Four solid overlapping shapes, no subtracted paths, so glass refraction stays clean.",
])
c.save(f"{SHEET}/sauron-app-icon.png")

# ================================================================ sheet 2 · logo system
W, H = 2400, 1390
c = Image.new("RGB", (W, H), INK); d = ImageDraw.Draw(c)
header(d, "logo system")

lock = load("sauron-lockup-horizontal-dark-2400.png", 1150)
c.paste(lock, (50, 200), lock)
overline(d, (80, 500), "Primary lockup · horizontal")

stack = load("sauron-lockup-stacked-dark-1200.png", 380)
c.paste(stack, (1560, 180), stack)
overline(d, (1560, 620), "Stacked lockup")

MT, MP, MX, MY = 290, 350, 80, 700
marks = [("sauron-mark-1024.png", "Mark", None),
         ("sauron-mark-simple-1024.png", "Simplified · ≤ 32 px", None),
         ("sauron-mark-mono-light-1024.png", "Mono knockout", None),
         ("sauron-mark-mono-dark-1024.png", "Mono on light", PAPER)]
for i, (fn, label, plate_col) in enumerate(marks):
    x = MX + i * MP
    if plate_col:
        d.rounded_rectangle((x, MY, x + MT, MY + MT), 18, fill=plate_col)
    im = load(fn, MT)
    c.paste(im, (x, MY), im)
    overline(d, (x, MY + MT + 22), label)

overline(d, (MX, 1090), "Rules")
bullets(d, MX, 1130, [
    "Clear space on every side equals the height of the ember slit. Nothing enters it.",
    "Minimum sizes: mark 20 px, horizontal lockup 120 px wide, stacked lockup 96 px wide.",
    "Wordmark is Inter SemiBold, uppercase, +0.14 em tracking. Never re-typeset it.",
    "Never recolor, outline, rotate, or add a glow to the mark; on photos use a dark scrim.",
    "The ember slit is always vertical and always warm — the only warm element in the system.",
], dot=EMBER)

overline(d, (1560, 700), "Palette")
sw = [("Ink", "#0A0B0D", (10, 11, 13)), ("Surface", "#12141A", (18, 20, 26)),
      ("Iris A", "#5B6CFF", (91, 108, 255)), ("Iris B", "#A96BFF", (169, 107, 255)),
      ("Ember A", "#FFC46B", (255, 196, 107)), ("Ember B", "#FF7A18", (255, 122, 24)),
      ("Core", "#FFF3DC", (255, 243, 220))]
for i, (n, hexv, rgb) in enumerate(sw):
    px = 1560 + (i % 3) * 250
    py = 748 + (i // 3) * 168
    d.rounded_rectangle((px, py, px + 210, py + 92), 14, fill=rgb,
                        outline=(255, 255, 255, 46), width=1)
    text(d, (px, py + 102), n, F("Medium", 24), T1)
    text(d, (px, py + 132), hexv, F("Regular", 22), T3)
c.save(f"{SHEET}/sauron-logo-system.png")
print("sheets written")
