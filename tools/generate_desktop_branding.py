#!/usr/bin/env python3
"""Generate native desktop Orvix icons from the canonical v0.7.7 artwork."""

import argparse
import re
from pathlib import Path

from PIL import Image, ImageOps

SOURCE = Path("assets/branding/orvix_icon.webp")


def canonical_icon() -> Image.Image:
    image = Image.open(SOURCE).convert("RGBA")
    if image.width < 1024 or image.height < 1024:
        raise SystemExit(
            f"Canonical Orvix icon is too small: {image.size}; expected at least 1024x1024"
        )
    return ImageOps.fit(
        image,
        (1024, 1024),
        method=Image.Resampling.LANCZOS,
        centering=(0.5, 0.5),
    )


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
        text = config.read_text(encoding="utf-8")
        if re.search(r"(?m)^PRODUCT_NAME\s*=.*$", text):
            text = re.sub(
                r"(?m)^PRODUCT_NAME\s*=.*$",
                "PRODUCT_NAME = Orvix",
                text,
                count=1,
            )
        else:
            text = text.rstrip() + "\nPRODUCT_NAME = Orvix\n"
        config.write_text(text, encoding="utf-8")

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
