"""Generate the Android TV launcher banner.

Android TV shows an app's banner in a 16:9 tile (320x180 px at xhdpi). The
earlier banner reused a 2.5:1 promotional card with transparent rounded
corners and fitted it into that tile, which left dark bars above and below
and a card inside the card.

This script composes a full-bleed 16:9 banner from the existing Orvix
artwork instead: the logo mark from orvix_logo.png and the "orvix" wordmark
from tv_banner.png, on the Orvix canvas colour with a restrained lime accent.

    python3 tools/make_tv_banner.py

writes assets/branding/tv_launcher_banner.png (1280x720). The Android build
(tools/configure_android_build.py --tv) scales it to the 320x180 resource.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

LOGO = Path("assets/branding/orvix_logo.png")
WORDMARK_SOURCE = Path("assets/branding/tv_banner.png")
OUTPUT = Path("assets/branding/tv_launcher_banner.png")

WIDTH, HEIGHT = 1280, 720
BACKGROUND = (5, 8, 6)
CANVAS = (11, 15, 12)
LIME = (185, 255, 69)

# Measured on the source artwork (see the module docstring).
MARK_BOX = (176, 176, 1077, 1077)  # orvix_logo.png, 1254x1254
WORDMARK_BOX = (856, 272, 1512, 478)  # tv_banner.png, 1994x788


def _light_to_alpha(image: Image.Image) -> Image.Image:
    """Artwork drawn on black -> the same artwork on transparency.

    The alpha is the brightest channel; colours are un-premultiplied so the
    result composites back to the original over a dark background.
    """
    rgb = image.convert("RGB")
    r, g, b = rgb.split()
    alpha = ImageChops.lighter(ImageChops.lighter(r, g), b)
    # Treat the near-black plate as fully transparent.
    alpha = alpha.point(lambda v: 0 if v < 24 else min(255, int((v - 24) * 1.18)))
    out = Image.new("RGBA", rgb.size)
    src = rgb.load()
    a = alpha.load()
    dst = out.load()
    for y in range(rgb.height):
        for x in range(rgb.width):
            av = a[x, y]
            if av == 0:
                dst[x, y] = (0, 0, 0, 0)
                continue
            cr, cg, cb = src[x, y]
            scale = 255 / max(av, 1)
            dst[x, y] = (
                min(255, int(cr * scale)),
                min(255, int(cg * scale)),
                min(255, int(cb * scale)),
                av,
            )
    return out


def _mark() -> Image.Image:
    logo = Image.open(LOGO).convert("RGBA").crop(MARK_BOX)
    # Keep only the round mark: the plate's lime rim sits outside this circle.
    # The mark's circle spans 188..1064 in the logo; its edge is feathered by
    # a pixel so the cut is not visible.
    mask = Image.new("L", logo.size, 0)
    circle = (188 - MARK_BOX[0], 188 - MARK_BOX[1],
              1064 - MARK_BOX[0], 1064 - MARK_BOX[1])
    ImageDraw.Draw(mask).ellipse(circle, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(1))
    mark = _light_to_alpha(logo)
    mark.putalpha(ImageChops.multiply(mark.getchannel("A"), mask))
    return mark


def _wordmark() -> Image.Image:
    source = Image.open(WORDMARK_SOURCE).convert("RGBA").crop(WORDMARK_BOX)
    word = _light_to_alpha(source)
    # Drop the faint background glow around the letters.
    alpha = word.getchannel("A").point(lambda v: 0 if v < 70 else v)
    word.putalpha(alpha)
    bbox = alpha.getbbox()
    if bbox is None:
        raise SystemExit("Could not isolate the Orvix wordmark")
    return word.crop(bbox)


def _background() -> Image.Image:
    base = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    # A soft vertical lift towards the canvas colour.
    lift = Image.new("L", (1, HEIGHT))
    for y in range(HEIGHT):
        lift.putpixel((0, y), int(150 * (1 - y / HEIGHT)))
    base = Image.composite(
        Image.new("RGB", (WIDTH, HEIGHT), CANVAS),
        base,
        lift.resize((WIDTH, HEIGHT)),
    )

    # Restrained lime light: a large, very soft glow at the lower right and
    # one thin arc, so the tile reads as Orvix without competing with the logo.
    glow = Image.new("L", (WIDTH, HEIGHT), 0)
    ImageDraw.Draw(glow).ellipse((760, 330, 1640, 1210), fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(150))
    base = Image.composite(Image.new("RGB", (WIDTH, HEIGHT), LIME), base, glow)

    arc = Image.new("L", (WIDTH, HEIGHT), 0)
    ImageDraw.Draw(arc).arc(
        (700, 250, 1900, 1450), start=188, end=262, fill=150, width=5
    )
    arc = arc.filter(ImageFilter.GaussianBlur(1.6))
    halo = arc.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.9))
    base = Image.composite(Image.new("RGB", (WIDTH, HEIGHT), LIME), base, halo)
    base = Image.composite(Image.new("RGB", (WIDTH, HEIGHT), LIME), base, arc)
    return base


def build() -> Image.Image:
    banner = _background().convert("RGBA")
    mark = _mark()
    word = _wordmark()

    # Size the lockup to ~74% of the width: legible on a 320x180 tile while
    # keeping clear space around it.
    mark_height = 330
    mark = mark.resize((mark_height, mark_height), Image.Resampling.LANCZOS)
    word_height = int(mark_height * 0.47)
    word_width = round(word.width * word_height / word.height)
    word = word.resize((word_width, word_height), Image.Resampling.LANCZOS)
    gap = int(mark_height * 0.14)

    total = mark.width + gap + word.width
    left = (WIDTH - total) // 2
    top = (HEIGHT - mark_height) // 2

    # A faint shadow under the mark separates it from the accent light.
    shadow = Image.new("RGBA", banner.size, (0, 0, 0, 0))
    shadow_alpha = Image.new("L", banner.size, 0)
    shadow_alpha.paste(mark.getchannel("A"), (left, top + 10))
    shadow_alpha = shadow_alpha.filter(ImageFilter.GaussianBlur(18)).point(
        lambda v: int(v * 0.55)
    )
    shadow.putalpha(shadow_alpha)
    banner.alpha_composite(shadow)

    banner.alpha_composite(mark, (left, top))
    # The wordmark's x-height is centred on the mark.
    word_top = top + (mark_height - word.height) // 2 + int(mark_height * 0.04)
    banner.alpha_composite(word, (left + mark.width + gap, word_top))
    return banner.convert("RGB")


def main() -> None:
    banner = build()
    if banner.size != (WIDTH, HEIGHT) or not math.isclose(
        banner.width / banner.height, 16 / 9
    ):
        raise SystemExit(f"Unexpected banner size {banner.size}")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    banner.save(OUTPUT, format="PNG", optimize=True)
    print(f"Wrote {OUTPUT} {banner.size}")


if __name__ == "__main__":
    main()
