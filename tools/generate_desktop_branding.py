#!/usr/bin/env python3
"""Generate native desktop Orvix icons from the canonical v0.7.7 artwork."""

import argparse
import re
from collections import deque
from pathlib import Path

from PIL import Image

SOURCE = Path("assets/branding/orvix_logo.png")


def _clean_launcher_artwork(source: Image.Image) -> Image.Image:
    """Remove only the dark background connected to the outer image edge."""
    image = source.convert("RGBA").copy()
    width, height = image.size
    pixels = image.load()
    visited = bytearray(width * height)
    queue = deque()

    def is_outer_dark(x: int, y: int) -> bool:
        r, g, b, a = pixels[x, y]
        if a == 0:
            return True
        return r <= 46 and g <= 46 and b <= 46

    def push(x: int, y: int) -> None:
        index = y * width + x
        if visited[index] or not is_outer_dark(x, y):
            return
        visited[index] = 1
        queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)

    while queue:
        x, y = queue.popleft()
        r, g, b, _ = pixels[x, y]
        pixels[x, y] = (r, g, b, 0)
        if x > 0:
            push(x - 1, y)
        if x + 1 < width:
            push(x + 1, y)
        if y > 0:
            push(x, y - 1)
        if y + 1 < height:
            push(x, y + 1)

    bbox = image.getbbox()
    if bbox is None:
        raise SystemExit("Canonical Orvix icon became empty after background cleanup.")
    return image.crop(bbox)


def _center_artwork(source: Image.Image, size: int, fill_ratio: float) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    art = source.copy()
    target = max(1, int(size * fill_ratio))
    art.thumbnail((target, target), Image.Resampling.LANCZOS)
    canvas.alpha_composite(
        art,
        ((size - art.width) // 2, (size - art.height) // 2),
    )
    return canvas


def canonical_icon() -> Image.Image:
    image = Image.open(SOURCE).convert("RGBA")
    if image.width < 1024 or image.height < 1024:
        raise SystemExit(
            f"Canonical Orvix icon is too small: {image.size}; expected at least 1024x1024"
        )
    icon = _center_artwork(_clean_launcher_artwork(image), 1024, 0.96)
    for x, y in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
        if icon.getpixel((x, y))[3] != 0:
            raise SystemExit("Orvix desktop icon outer corners must be transparent.")
    return icon


def generate_windows(image: Image.Image) -> None:
    output = Path("windows/runner/resources/app_icon.ico")
    output.parent.mkdir(parents=True, exist_ok=True)
    sizes = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
    image.save(
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
    if args.windows:
        generate_windows(image)
    if args.macos:
        generate_macos(image)


if __name__ == "__main__":
    main()
