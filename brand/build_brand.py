#!/usr/bin/env python3
"""Sauron brand build: mark, wordmark lockups, macOS icon layers, appiconset, spec sheets."""
import json, os, math, shutil
import cairosvg
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.abspath(__file__))
SVG = os.path.join(ROOT, "svg"); ICON = os.path.join(ROOT, "icon")
EXP = os.path.join(ROOT, "exports"); SHEET = os.path.join(ROOT, "sheets")
SET = os.path.join(ROOT, "AppIcon.appiconset")
for d in (SVG, ICON, EXP, SHEET, SET):
    os.makedirs(d, exist_ok=True)

# ---------------------------------------------------------------- tokens
IRIS_A, IRIS_B = "#5B6CFF", "#A96BFF"
EMBER_A, EMBER_B = "#FFC46B", "#FF7A18"
CORE = "#FFF3DC"
INK = "#0A0B0D"
PAPER = "#F6F7F9"

# ---------------------------------------------------------------- geometry (1024 canvas)
ALMOND = "M 148 512 C 300 258, 724 258, 876 512 C 724 766, 300 766, 148 512 Z"
PUPIL  = "M 512 322 C 550 412, 550 612, 512 702 C 474 612, 474 412, 512 322 Z"
LID_T  = "M 214 388 C 352 206, 672 206, 810 388"
LID_B  = "M 214 636 C 352 818, 672 818, 810 636"

DEFS = f"""
  <linearGradient id="iris" x1="152" y1="296" x2="872" y2="728" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{IRIS_A}"/><stop offset="1" stop-color="{IRIS_B}"/>
  </linearGradient>
  <linearGradient id="ember" x1="470" y1="372" x2="556" y2="652" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="{EMBER_A}"/><stop offset="1" stop-color="{EMBER_B}"/>
  </linearGradient>
"""

def eye(full=True, ring="url(#iris)", pupil_fill="url(#ember)", core=CORE,
        lid=None, sw=50, lid_sw=24, lid_op=0.5):
    """Eye group. full=False drops the sound-wave lids and thickens the ring (small sizes)."""
    lid = lid or ring
    if not full:
        sw = 62
    parts = []
    if full:
        for d in (LID_T, LID_B):
            parts.append(f'<path d="{d}" fill="none" stroke="{lid}" stroke-width="{lid_sw}" '
                         f'stroke-linecap="round" opacity="{lid_op}"/>')
    parts.append(f'<path d="{ALMOND}" fill="none" stroke="{ring}" stroke-width="{sw}" '
                 f'stroke-linejoin="round" stroke-linecap="round"/>')
    parts.append(f'<path d="{PUPIL}" fill="{pupil_fill}"/>')
    if core:
        parts.append(f'<circle cx="512" cy="496" r="19" fill="{core}"/>')
    return "\n".join(parts)

def svg_doc(body, w=1024, h=1024, defs=DEFS, bg=None):
    bgr = f'<rect width="{w}" height="{h}" fill="{bg}"/>' if bg else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" '
            f'viewBox="0 0 {w} {h}" fill="none">\n<defs>{defs}</defs>\n{bgr}\n{body}\n</svg>\n')

def write(path, text):
    with open(path, "w") as f:
        f.write(text)
    return path

# ---------------------------------------------------------------- 1. marks
write(f"{SVG}/sauron-mark.svg", svg_doc(eye()))
write(f"{SVG}/sauron-mark-simple.svg", svg_doc(eye(full=False)))
write(f"{SVG}/sauron-mark-mono-light.svg",
      svg_doc(eye(ring="#FFFFFF", pupil_fill="#FFFFFF", core=None, lid_op=0.5), defs=""))
write(f"{SVG}/sauron-mark-mono-dark.svg",
      svg_doc(eye(ring=INK, pupil_fill=INK, core=None, lid_op=0.5), defs=""))

# ---------------------------------------------------------------- 2. lockups
def lockup_h(dark=True, tagline=True):
    fg = "#F2F3F5" if dark else "#14161C"
    sub = "#9AA0AC" if dark else "#6B7280"
    W, H = 1600, 420
    mark = f'<g transform="translate(40,26) scale(0.36)">{eye()}</g>'
    tag = (f'<text x="452" y="268" font-family="Inter" font-size="42" font-weight="500" '
           f'letter-spacing="1.5" fill="{sub}">The meeting assistant that never blinks</text>'
           if tagline else "")
    body = f"""{mark}
  <text x="452" y="212" font-family="Inter" font-size="124" font-weight="600"
        letter-spacing="17" fill="{fg}">SAURON</text>
  {tag}"""
    return svg_doc(body, W, H, bg=None)

def lockup_v(dark=True):
    fg = "#F2F3F5" if dark else "#14161C"
    sub = "#9AA0AC" if dark else "#6B7280"
    W, H = 900, 1000
    mark = f'<g transform="translate(162,40) scale(0.56)">{eye()}</g>'
    body = f"""{mark}
  <text x="450" y="780" text-anchor="middle" font-family="Inter" font-size="118"
        font-weight="600" letter-spacing="16" fill="{fg}">SAURON</text>
  <text x="450" y="848" text-anchor="middle" font-family="Inter" font-size="36"
        font-weight="500" letter-spacing="6" fill="{sub}">MEETING INTELLIGENCE</text>"""
    return svg_doc(body, W, H)

write(f"{SVG}/sauron-lockup-horizontal-dark.svg", lockup_h(True))
write(f"{SVG}/sauron-lockup-horizontal-light.svg", lockup_h(False))
write(f"{SVG}/sauron-lockup-stacked-dark.svg", lockup_v(True))
write(f"{SVG}/sauron-lockup-stacked-light.svg", lockup_v(False))

# ---------------------------------------------------------------- 3. icon layers (unmasked squares)
BG_DEFS = """
  <linearGradient id="bgbase" x1="0" y1="0" x2="1024" y2="1024" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#191C25"/><stop offset="0.55" stop-color="#0F1116"/>
    <stop offset="1" stop-color="#07080B"/>
  </linearGradient>
  <radialGradient id="bgiris" cx="300" cy="240" r="640" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#6B72FF" stop-opacity="0.30"/>
    <stop offset="1" stop-color="#6B72FF" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="bgember" cx="560" cy="880" r="520" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#FF7A18" stop-opacity="0.16"/>
    <stop offset="1" stop-color="#FF7A18" stop-opacity="0"/>
  </radialGradient>
"""
BG_BODY = ('<rect width="1024" height="1024" fill="url(#bgbase)"/>'
           '<rect width="1024" height="1024" fill="url(#bgiris)"/>'
           '<rect width="1024" height="1024" fill="url(#bgember)"/>')
write(f"{ICON}/icon-background.svg", svg_doc(BG_BODY, defs=BG_DEFS))

BG_LIGHT_DEFS = BG_DEFS.replace("#191C25", "#FFFFFF").replace("#0F1116", "#EEF0F6").replace("#07080B", "#DDE1EC")
write(f"{ICON}/icon-background-light.svg", svg_doc(BG_BODY, defs=BG_LIGHT_DEFS))

# foreground: eye scaled to ~66% of canvas, centered (macOS 26 layer, no baked corners)
def fg_group(full=True, ring="url(#iris)", pupil_fill="url(#ember)", core=CORE):
    inner = eye(full=full, ring=ring, pupil_fill=pupil_fill, core=core)
    return f'<g transform="translate(512,512) scale(0.80) translate(-512,-512)">{inner}</g>'

write(f"{ICON}/icon-foreground.svg", svg_doc(fg_group()))
write(f"{ICON}/icon-foreground-simple.svg", svg_doc(fg_group(full=False)))
write(f"{ICON}/icon-mono.svg", svg_doc(
    '<rect width="1024" height="1024" fill="#000000"/>' +
    fg_group(ring="#FFFFFF", pupil_fill="#B9BCC4", core="#FFFFFF"), defs=""))

# ---------------------------------------------------------------- 4. rasterize
def png(svg_path, out, w, h=None):
    cairosvg.svg2png(url=svg_path, write_to=out, output_width=w, output_height=h or w)
    return out

png(f"{SVG}/sauron-mark.svg", f"{EXP}/sauron-mark-1024.png", 1024)
png(f"{SVG}/sauron-mark-simple.svg", f"{EXP}/sauron-mark-simple-1024.png", 1024)
png(f"{SVG}/sauron-mark-mono-light.svg", f"{EXP}/sauron-mark-mono-light-1024.png", 1024)
png(f"{SVG}/sauron-mark-mono-dark.svg", f"{EXP}/sauron-mark-mono-dark-1024.png", 1024)
for n in ("horizontal-dark", "horizontal-light"):
    png(f"{SVG}/sauron-lockup-{n}.svg", f"{EXP}/sauron-lockup-{n}-2400.png", 2400, 630)
for n in ("stacked-dark", "stacked-light"):
    png(f"{SVG}/sauron-lockup-{n}.svg", f"{EXP}/sauron-lockup-{n}-1200.png", 1200, 1333)
png(f"{ICON}/icon-background.svg", f"{EXP}/icon-background-1024.png", 1024)
png(f"{ICON}/icon-background-light.svg", f"{EXP}/icon-background-light-1024.png", 1024)
png(f"{ICON}/icon-foreground.svg", f"{EXP}/icon-foreground-1024.png", 1024)
png(f"{ICON}/icon-foreground-simple.svg", f"{EXP}/icon-foreground-simple-1024.png", 1024)
png(f"{ICON}/icon-mono.svg", f"{EXP}/icon-mono-1024.png", 1024)

# ---------------------------------------------------------------- 5. squircle composite for legacy icns
def squircle_mask(size, n=5.0, inset_ratio=0.0):
    """Apple-like continuous-corner superellipse mask at supersampled resolution."""
    ss = 8 if size <= 128 else 4
    S = size * ss
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    a = S / 2 * (1 - inset_ratio)
    cx = cy = S / 2
    pts = []
    steps = 2048
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(ct) ** (2.0 / n), ct)
        y = cy + a * math.copysign(abs(st) ** (2.0 / n), st)
        pts.append((x, y))
    d.polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)

def render_layer(svg_path, size):
    tmp = f"/tmp/_l{size}.png"
    cairosvg.svg2png(url=svg_path, write_to=tmp, output_width=size, output_height=size)
    return Image.open(tmp).convert("RGBA")

def composite_icon(size, dark=True, simple=False, pad_ratio=0.09):
    """Full-bleed squircle tile + centered eye, matching macOS 26 proportions."""
    inner = int(round(size * (1 - pad_ratio * 2)))
    bg_svg = f"{ICON}/icon-background.svg" if dark else f"{ICON}/icon-background-light.svg"
    bg = render_layer(bg_svg, inner)
    mask = squircle_mask(inner)
    tile = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    tile.paste(bg, (0, 0), mask)
    fg_svg = f"{ICON}/icon-foreground-simple.svg" if simple else f"{ICON}/icon-foreground.svg"
    fg = render_layer(fg_svg, inner)
    tile = Image.alpha_composite(tile, fg)
    # crop foreground to tile shape so nothing spills past the squircle
    clipped = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    clipped.paste(tile, (0, 0), mask)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    off = (size - inner) // 2
    canvas.paste(clipped, (off, off), clipped)
    return canvas

SIZES = [16, 32, 64, 128, 256, 512, 1024]
for s in SIZES:
    composite_icon(s, simple=(s <= 64)).save(f"{EXP}/icon-macos-{s}.png")
composite_icon(1024, dark=False).save(f"{EXP}/icon-macos-light-1024.png")

# mono / tinted preview
mono = render_layer(f"{ICON}/icon-mono.svg", 1024)
mmask = squircle_mask(1024)
mono_tile = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
mono_tile.paste(mono, (0, 0), mmask)
mono_tile.save(f"{EXP}/icon-mono-tile-1024.png")

# ---------------------------------------------------------------- 6. legacy AppIcon.appiconset
entries = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
images = []
for pt, sc in entries:
    px = pt * sc
    fn = f"icon_{pt}x{pt}{'@2x' if sc == 2 else ''}.png"
    composite_icon(px, simple=(px <= 64)).save(os.path.join(SET, fn))
    images.append({"size": f"{pt}x{pt}", "idiom": "mac", "filename": fn, "scale": f"{sc}x"})
write(os.path.join(SET, "Contents.json"),
      json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))

print("marks, lockups, icon layers, appiconset written")

# ---------------------------------------------------------------- 7. previews on backgrounds
def on_bg(src, out, bg):
    im = Image.open(src).convert("RGBA")
    plate = Image.new("RGBA", im.size, bg)
    Image.alpha_composite(plate, im).convert("RGB").save(out)

on_bg(f"{EXP}/sauron-lockup-horizontal-dark-2400.png", f"{EXP}/preview-lockup-dark.png", (10, 11, 13, 255))
on_bg(f"{EXP}/sauron-lockup-horizontal-light-2400.png", f"{EXP}/preview-lockup-light.png", (246, 247, 249, 255))
on_bg(f"{EXP}/sauron-lockup-stacked-dark-1200.png", f"{EXP}/preview-lockup-stacked-dark.png", (10, 11, 13, 255))
print("previews done")
