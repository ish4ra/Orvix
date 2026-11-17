#!/usr/bin/env python3
"""Render the native macOS app icon.

The macOS icon is its own artwork, built for the Dock, Finder, Launchpad and
Spotlight. It does not replace the launcher art used on Android, Android TV,
Windows and iOS, and it does not touch the in-app logo.

It is drawn on Apple's macOS icon grid: a 1024 px canvas with an 824 px
rounded-square body in the middle, transparent outside, with the standard
soft drop shadow underneath. The body uses the Orvix dark colours and the
Orvix "O" is lifted from the canonical launcher artwork
(assets/branding/orvix_logo.png), so the mark itself is unchanged.

The two smallest sizes (16 and 32 px) are drawn with a larger mark and a
plainer body so the O stays readable.

Usage (needs Pillow):

    python3 tools/generate_macos_icon.py

Writes the icon set that builds install to
tools/macos_icon/AppIcon.appiconset/ and previews to
docs/branding/macos-icon/. The output is committed; builds copy it and never
re-render it, so a different Pillow version cannot change a release.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "orvix_logo.png"
ICONSET = ROOT / "tools" / "macos_icon" / "AppIcon.appiconset"
PREVIEWS = ROOT / "docs" / "branding" / "macos-icon"

CANVAS = 1024
BODY = 824  # Apple's macOS grid: 824 px body, 100 px margin on every side.
SUPERSAMPLE = 2

# Orvix brand colours.
LIME = (0xB9, 0xFF, 0x45)
DARK = (0x05, 0x08, 0x06)
DARK_2 = (0x07, 0x0A, 0x08)
BODY_TOP = (0x10, 0x16, 0x11)  # a lifted DARK_2 so the body reads as a surface

# (pixel size, file name). macOS asks for 16, 32, 128, 256 and 512 pt at 1x
# and 2x; these seven files cover all ten slots.
SIZES = (16, 32, 64, 128, 256, 512, 1024)
SMALL = 32  # sizes up to this use the simplified drawing
PREVIEW_SIZES = (1024, 512, 256, 128, 32)


def superellipse_mask(size: int, body: int, exponent: float = 5.0) -> Image.Image:
    """Apple-style continuous-corner rounded square, centred on the canvas."""
    half = body / 2
    centre = size / 2
    points = []
    steps = 720
    for step in range(steps):
        angle = 2 * math.pi * step / steps
        cos, sin = math.cos(angle), math.sin(angle)
        x = half * math.copysign(abs(cos) ** (2 / exponent), cos)
        y = half * math.copysign(abs(sin) ** (2 / exponent), sin)
        points.append((centre + x, centre + y))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def vertical_gradient(size: int, top: tuple, bottom: tuple, start: int, end: int) -> Image.Image:
    column = Image.new("RGB", (1, size))
    for y in range(size):
        t = min(1.0, max(0.0, (y - start) / max(1, end - start)))
        t = t * t * (3 - 2 * t)
        column.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return column.resize((size, size))


def extract_mark() -> Image.Image:
    """The lime O from the canonical launcher art, on a transparent
    background, cropped to its bounds.

    The source is the O on a near-black tile. Its brightness is used as the
    matte: the tile and the faint glow around the O become transparent, the O
    keeps its own colours and shading, and the dark opening inside the O
    stays open so the new body shows through it.
    """
    source = Image.open(SOURCE).convert("RGB")
    width, height = source.size
    # Keep only the centre: the old tile's green outline must not come along.
    radius = round(min(width, height) * 0.30)
    cx, cy = width // 2, height // 2
    box = (cx - radius, cy - radius, cx + radius, cy + radius)
    region = source.crop(box)

    low, high = 60, 118  # green level: below is tile or glow, above is the O
    background = (2, 5, 1)
    pixels = region.load()
    side = region.size[0]
    mark = Image.new("RGBA", region.size, (0, 0, 0, 0))
    out = mark.load()
    for y in range(side):
        for x in range(side):
            if (x - radius) ** 2 + (y - radius) ** 2 > radius * radius:
                continue
            r, g, b = pixels[x, y]
            if g <= low:
                continue
            t = min(1.0, (g - low) / (high - low))
            alpha = t * t * (3 - 2 * t)
            # Remove the dark tile from partly covered edge pixels.
            colour = tuple(
                max(0, min(255, round((value - (1 - alpha) * bg) / alpha)))
                for value, bg in zip((r, g, b), background)
            )
            out[x, y] = (*colour, round(alpha * 255))
    bounds = mark.getbbox()
    if bounds is None:
        raise SystemExit("Could not find the Orvix O in the launcher artwork.")
    return mark.crop(bounds)


def render(mark: Image.Image, small: bool) -> Image.Image:
    """One 1024 px master. `small` is the simplified drawing for 16-32 px."""
    scale = SUPERSAMPLE
    size = CANVAS * scale
    body = BODY * scale
    top = (size - body) // 2
    shape = superellipse_mask(size, body)

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # Drop shadow, as on Apple's template: straight down, soft, not a halo.
    shadow_alpha = ImageChops.offset(shape, 0, 12 * scale)
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(14 * scale))
    shadow_alpha = shadow_alpha.point(lambda value: round(value * 0.42))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    shadow.putalpha(shadow_alpha)
    canvas.alpha_composite(shadow)

    # Body: brand dark, slightly lifted at the top so it reads as a surface.
    fill = vertical_gradient(size, BODY_TOP, DARK, top, top + body).convert("RGBA")
    if not small:
        # A faint lime ambient behind the mark gives depth without a glow.
        ambient = Image.new("L", (size, size), 0)
        reach = round(body * 0.36)
        centre = size // 2
        ImageDraw.Draw(ambient).ellipse(
            (centre - reach, centre - reach, centre + reach, centre + reach), fill=255
        )
        ambient = ambient.filter(ImageFilter.GaussianBlur(body * 0.11))
        ambient = ambient.point(lambda value: round(value * 0.085))
        tint = Image.new("RGBA", (size, size), (*LIME, 255))
        tint.putalpha(ambient)
        fill.alpha_composite(tint)
    fill.putalpha(shape)
    canvas.alpha_composite(fill)

    # Edge lighting: a thin light rim at the top, a darker one at the bottom.
    rim_width = (3 if small else 2) * scale
    inner = superellipse_mask(size, body - 2 * rim_width)
    rim = ImageChops.subtract(shape, inner)
    fade = vertical_gradient(size, (255, 255, 255), (0, 0, 0), top, top + round(body * 0.55)).convert("L")
    highlight = Image.new("RGBA", (size, size), (255, 255, 255, 255))
    highlight.putalpha(ImageChops.multiply(rim, fade).point(lambda value: round(value * 0.20)))
    canvas.alpha_composite(highlight)
    lowlight = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    lowlight.putalpha(
        ImageChops.multiply(rim, ImageChops.invert(fade)).point(lambda value: round(value * 0.45))
    )
    canvas.alpha_composite(lowlight)

    # The O.
    diameter = round(body * (0.70 if small else 0.60))
    ratio = diameter / max(mark.size)
    glyph = mark.resize(
        (round(mark.width * ratio), round(mark.height * ratio)), Image.Resampling.LANCZOS
    )
    position = ((size - glyph.width) // 2, (size - glyph.height) // 2)
    if not small:
        # A soft contact shadow lifts the mark off the body.
        contact = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        dark = Image.new("RGBA", glyph.size, (0, 0, 0, 255))
        dark.putalpha(glyph.getchannel("A").point(lambda value: round(value * 0.55)))
        contact.alpha_composite(dark, (position[0], position[1] + 10 * scale))
        contact = contact.filter(ImageFilter.GaussianBlur(12 * scale))
        contact.putalpha(ImageChops.multiply(contact.getchannel("A"), shape))
        canvas.alpha_composite(contact)
    canvas.alpha_composite(glyph, position)

    return canvas.resize((CANVAS, CANVAS), Image.Resampling.LANCZOS)


def contents_json() -> dict:
    images = []
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            images.append(
                {
                    "size": f"{points}x{points}",
                    "idiom": "mac",
                    "filename": f"app_icon_{points * factor}.png",
                    "scale": f"{factor}x",
                }
            )
    return {"images": images, "info": {"version": 1, "author": "xcode"}}


def main() -> None:
    mark = extract_mark()
    masters = {False: render(mark, small=False), True: render(mark, small=True)}

    ICONSET.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    rendered = {}
    for size in SIZES:
        master = masters[size <= SMALL]
        image = master if size == CANVAS else master.resize((size, size), Image.Resampling.LANCZOS)
        image.save(ICONSET / f"app_icon_{size}.png", format="PNG", optimize=True)
        rendered[size] = image
    (ICONSET / "Contents.json").write_text(
        json.dumps(contents_json(), indent=2) + "\n", encoding="utf-8"
    )

    for size in PREVIEW_SIZES:
        rendered[size].save(PREVIEWS / f"orvix-macos-icon-{size}.png", format="PNG", optimize=True)

    # One sheet showing every preview size on a light and a dark desktop.
    gap = 48
    width = sum(PREVIEW_SIZES) + gap * (len(PREVIEW_SIZES) + 1)
    sheet = Image.new("RGB", (width, 2 * (CANVAS + 2 * gap)))
    for row, colour in enumerate(((0xEC, 0xEC, 0xEE), (0x1E, 0x1F, 0x22))):
        y0 = row * (CANVAS + 2 * gap)
        ImageDraw.Draw(sheet).rectangle((0, y0, width, y0 + CANVAS + 2 * gap), fill=colour)
        x = gap
        for size in PREVIEW_SIZES:
            sheet.paste(rendered[size], (x, y0 + gap + CANVAS - size), rendered[size])
            x += size + gap
    sheet.save(PREVIEWS / "orvix-macos-icon-sheet.png", format="PNG", optimize=True)
    print(f"macOS icon set written to {ICONSET.relative_to(ROOT)}")
    print(f"Previews written to {PREVIEWS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
