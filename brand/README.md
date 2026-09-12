# Sauron — brand kit

Mark concept: **the eye that listens.** An almond iris ring in the product's violet gradient, pierced by a
full-height ember slit, framed by two concentric "signal" lids. Original geometric construction — deliberately
not a likeness of any film artwork.

Tagline: *The meeting assistant that never blinks.*

## Regenerating

Everything in this directory is generated. Edit the scripts, never the outputs.

```bash
python build_brand.py    # SVG sources, PNG exports, AppIcon.appiconset
python build_sheets.py   # presentation sheets (needs build_brand.py output)
```

Requires `cairosvg`, `Pillow`, and Inter installed to a font path cairo can see
(`fonts/inter/extras/ttf/*.ttf` copied to `~/.fonts`, then `fc-cache -f`).

## Geometry (1024 canvas)

| Element | Spec |
| --- | --- |
| Almond ring | `M 148 512 C 300 258, 724 258, 876 512 C 724 766, 300 766, 148 512 Z`, stroke 50, round joins/caps |
| Ember slit | `M 512 322 C 550 412, 550 612, 512 702 C 474 612, 474 412, 512 322 Z`, filled |
| Signal lid (top) | `M 214 388 C 352 206, 672 206, 810 388`, stroke 24, opacity 0.50 |
| Signal lid (bottom) | `M 214 636 C 352 818, 672 818, 810 636`, stroke 24, opacity 0.50 |
| Core glint | circle `cx 512, cy 496, r 19`, `#FFF3DC` |
| Simplified mark | same ring at stroke 62, no lids — used at ≤ 32 px |

Gradients: iris `#5B6CFF → #A96BFF` (diagonal), ember `#FFC46B → #FF7A18` (vertical).
The icon foreground is the mark scaled 0.80 about the canvas centre.

## Palette

| Token | Hex | Use |
| --- | --- | --- |
| Ink | `#0A0B0D` | app canvas, icon base |
| Surface | `#12141A` | panels |
| Iris A / Iris B | `#5B6CFF` / `#A96BFF` | mark ring, primary accent |
| Ember A / Ember B | `#FFC46B` / `#FF7A18` | slit, live/recording state only |
| Core | `#FFF3DC` | specular glint |
| Text | `#F2F3F5` / `#9AA0AC` / `#6B7280` | primary / secondary / tertiary |

Wordmark: Inter SemiBold, uppercase, +0.14 em tracking. Subtitle in Inter Regular/Medium at 40–45% of the
wordmark's cap height.

## macOS 26 icon (Icon Composer)

Import these **1024 × 1024 square** layers — do not bake corners, shadows, gloss, or bevels; the system's
Liquid Glass material supplies masking and specular highlights.

| Layer | File |
| --- | --- |
| Background (dark) | `icon/icon-background.svg` · `exports/icon-background-1024.png` |
| Background (light) | `icon/icon-background-light.svg` |
| Foreground | `icon/icon-foreground.svg` · `exports/icon-foreground-1024.png` |
| Mono annotation | `icon/icon-mono.svg` — drives the clear and tinted appearances |

Composited previews (squircle applied by the build script, for review only, not for shipping):
`exports/icon-macos-{16,32,64,128,256,512,1024}.png`, `icon-macos-light-1024.png`, `icon-mono-tile-1024.png`.

### Legacy / non-Icon-Composer targets

`AppIcon.appiconset/` is a ready `.appiconset` (16/32/128/256/512 at @1x and @2x plus `Contents.json`) for
older toolchains, DMG art, and web favicons. Sizes ≤ 64 px use the simplified mark.

To produce an `.icns` on a Mac:

```bash
cp -R AppIcon.appiconset Sauron.iconset
# rename members to icon_16x16.png, icon_16x16@2x.png, … as iconutil expects
iconutil -c icns Sauron.iconset
```

## Logo files

| File | Use |
| --- | --- |
| `svg/sauron-mark.svg` | primary mark, transparent |
| `svg/sauron-mark-simple.svg` | small sizes, favicons |
| `svg/sauron-mark-mono-light.svg` / `-mono-dark.svg` | single-colour on dark / on light |
| `svg/sauron-lockup-horizontal-{dark,light}.svg` | primary lockup, marketing headers |
| `svg/sauron-lockup-stacked-{dark,light}.svg` | square placements, splash, about panel |
| `exports/preview-lockup-*.png` | lockups flattened onto ink/paper for slides |
| `sheets/*.png` | reviewable spec sheets |

## Rules

- Clear space on every side equals the height of the ember slit.
- Minimum sizes: mark 20 px; horizontal lockup 120 px wide; stacked lockup 96 px wide.
- Never recolor, outline, rotate, or add a glow to the mark. On photography, use a dark scrim.
- The ember slit is the only warm element in the product UI — reserve `#FF7A18` for live capture states so
  the icon and the recording indicator read as the same idea.

## In-app usage

- Menu bar: `sauron-mark-mono-light.svg` as a template image, 18 px, iris tint only when actively recording.
- Recording HUD / Live Assist: the ember slit doubles as the capture indicator — pulse the core glint, never
  the whole mark.
- Empty states: the mark at 15% opacity behind copy, never larger than 240 px.
