#!/usr/bin/env python3
"""Generate native desktop Orvix icons from the canonical v0.7.7 artwork."""

import argparse
import re
from pathlib import Path

from PIL import Image

SOURCE = Path("assets/branding/orvix_logo.png")
IN_APP_LOGO = Path("assets/branding/orvix_logo.webp")


def canonical_icon() -> Image.Image:
    """Use the user-supplied launcher PNG exactly; preserve its alpha and geometry."""
    image = Image.open(SOURCE).convert("RGBA")
    if image.width < 1024 or image.height < 1024:
        raise SystemExit(
            f"Canonical Orvix icon is too small: {image.size}; expected at least 1024x1024"
        )
    if image.size != (1024, 1024):
        image = image.resize((1024, 1024), Image.Resampling.LANCZOS)
    for x, y in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
        if image.getpixel((x, y))[3] != 0:
            raise SystemExit("Orvix desktop icon outer corners must be transparent.")
    return image


def generate_in_app_mark(image: Image.Image) -> None:
    """Derive the transparent O-only in-app mark from the canonical launcher art."""
    width, height = image.size
    cx, cy = width / 2, height / 2
    radius_sq = (min(width, height) * 0.308) ** 2
    pixels = list(image.getdata())
    cleaned = []
    for index, (r, g, b, a) in enumerate(pixels):
        x = index % width
        y = index // width
        keep = (
            (x - cx) ** 2 + (y - cy) ** 2 < radius_sq
            and g > 70
            and g > b * 1.20
            and g > r * 1.02
        )
        cleaned.append((r, g, b, a if keep else 0))
    mark = Image.new("RGBA", image.size)
    mark.putdata(cleaned)
    bbox = mark.getbbox()
    if bbox is None:
        raise SystemExit("Could not isolate the Orvix O mark.")
    mark = mark.crop(bbox)
    # Small transparent breathing room, without the old full-icon canvas.
    pad = max(2, round(max(mark.size) * 0.035))
    framed = Image.new("RGBA", (mark.width + pad * 2, mark.height + pad * 2))
    framed.alpha_composite(mark, (pad, pad))
    IN_APP_LOGO.parent.mkdir(parents=True, exist_ok=True)
    framed.save(IN_APP_LOGO, format="WEBP", quality=95, method=6)
    print(f"Generated transparent in-app O mark: {IN_APP_LOGO}")


def generate_windows(image: Image.Image) -> None:
    output = Path("windows/runner/resources/app_icon.ico")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Windows Explorer sizes icons by the non-transparent artwork bounds.
    # The canonical rounded-square has intentional outer alpha padding, so
    # crop only that transparent canvas (never the designed green border),
    # then restore a tiny 2% safety margin. This makes Orvix visually match
    # normal installed-app icons such as browsers without changing the art.
    bbox = image.getbbox()
    if bbox is None:
        raise SystemExit("Canonical Orvix icon is fully transparent.")
    artwork = image.crop(bbox)
    pad = max(2, round(max(artwork.size) * 0.02))
    square_side = max(artwork.size) + pad * 2
    packed = Image.new("RGBA", (square_side, square_side))
    packed.alpha_composite(
        artwork,
        ((square_side - artwork.width) // 2, (square_side - artwork.height) // 2),
    )
    packed = packed.resize((1024, 1024), Image.Resampling.LANCZOS)

    # The resize must never turn the transparent outer corners into an opaque
    # black square. Constrain only the *outer* silhouette to the launcher's
    # rounded-square boundary; the interior black artwork remains untouched.
    rounded = Image.new("L", (1024, 1024), 0)
    mask_draw = ImageDraw.Draw(rounded)
    mask_draw.rounded_rectangle((0, 0, 1023, 1023), radius=165, fill=255)
    alpha = packed.getchannel("A")
    packed.putalpha(ImageChops.multiply(alpha, rounded))

    sizes = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    packed.save(
        output,
        format="ICO",
        sizes=[(size, size) for size in sizes],
        bitmap_format="png",
    )
    if output.stat().st_size < 10_000:
        raise SystemExit(f"Generated Windows ICO looks too small: {output.stat().st_size}")
    print(f"Generated Windows icon: {output} ({output.stat().st_size} bytes)")


def generate_macos(image: Image.Image) -> None:
    icon_dir = Path("macos/Runner/Assets.xcassets/AppIcon.appiconset")
    if not icon_dir.is_dir():
        raise SystemExit(
            "macOS AppIcon.appiconset is missing; run flutter create --platforms=macos first"
        )

    icon_sizes = {
        "app_icon_16.png": 16,
        "app_icon_32.png": 32,
        "app_icon_64.png": 64,
        "app_icon_128.png": 128,
        "app_icon_256.png": 256,
        "app_icon_512.png": 512,
        "app_icon_1024.png": 1024,
    }
    for name, size in icon_sizes.items():
        output = icon_dir / name
        resized = image.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(output, format="PNG", optimize=True)

    config = Path("macos/Runner/Configs/AppInfo.xcconfig")
    if config.exists():
        text_content = config.read_text(encoding="utf-8")
        if re.search(r"(?m)^PRODUCT_NAME\s*=.*$", text_content):
            text_content = re.sub(
                r"(?m)^PRODUCT_NAME\s*=.*$",
                "PRODUCT_NAME = Orvix",
                text_content,
                count=1,
            )
        else:
            text_content = text_content.rstrip() + "\nPRODUCT_NAME = Orvix\n"
        config.write_text(text_content, encoding="utf-8")

    print(f"Generated macOS AppIcon set in {icon_dir}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--windows", action="store_true")
    parser.add_argument("--macos", action="store_true")
    args = parser.parse_args()
    if not args.windows and not args.macos:
        parser.error("select --windows and/or --macos")

    image = canonical_icon()
    generate_in_app_mark(image)
    if args.windows:
        generate_windows(image)
    if args.macos:
        generate_macos(image)


if __name__ == "__main__":
    main()def generate_windows_icon(image: Image.Image) -> None:
    output = Path("windows/runner/resources/app_icon.ico")
    output.parent.mkdir(parents=True, exist_ok=True)

    # The supplied PNG contains near-transparent stray pixels all the way to
    # the canvas edges. PIL getbbox() therefore treated the entire 1254x1254
    # canvas as artwork, which is why Explorer kept rendering Orvix too small
    # (and some ICO sizes exposed a dark square/halo).
    #
    # Ignore only those effectively invisible alpha-noise pixels, then crop to
    # the REAL rounded-square artwork. Do not invent a new rounded mask and do
    # not touch the black interior of the designed icon.
    alpha = image.getchannel("A")
    visible = alpha.point(lambda value: 255 if value >= 5 else 0)
    bbox = visible.getbbox()
    if bbox is None:
        raise SystemExit("Canonical Orvix icon has no visible artwork.")

    artwork = image.crop(bbox)
    artwork_alpha = artwork.getchannel("A").point(
        lambda value: 0 if value < 5 else value
    )
    artwork.putalpha(artwork_alpha)

    # Keep just a tiny transparent safety margin so the rounded green border
    # nearly fills the Windows icon cell, like normal installed applications.
    pad = max(2, round(max(artwork.size) * 0.012))
    side = max(artwork.size) + pad * 2
    packed = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    packed.alpha_composite(
        artwork,
        ((side - artwork.width) // 2, (side - artwork.height) // 2),
    )
    packed = packed.resize((1024, 1024), Image.Resampling.LANCZOS)

    # Resampling can recreate tiny alpha values at transparent edges. Remove
    # only those invisible pixels again so ICO conversion cannot quantize them
    # into a black halo/square.
    packed_alpha = packed.getchannel("A").point(
        lambda value: 0 if value < 5 else value
    )
    packed.putalpha(packed_alpha)

    sizes = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    packed.save(
        output,
        format="ICO",
        sizes=[(size, size) for size in sizes],
        bitmap_format="png",
    )
    print(f"Generated {output} ({output.stat().st_size} bytes)")

