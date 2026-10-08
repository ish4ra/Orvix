#!/usr/bin/env python3
"""Configure the generated Flutter iOS runner for Orvix sideload builds."""

from __future__ import annotations

import json
import plistlib
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
IOS_ROOT = ROOT / "ios"
INFO_PLIST = IOS_ROOT / "Runner" / "Info.plist"
APPICON_DIR = IOS_ROOT / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
APPICON_CONTENTS = APPICON_DIR / "Contents.json"
ICON_SOURCE = ROOT / "assets" / "branding" / "orvix_logo.png"


def configure_info_plist() -> None:
    if not INFO_PLIST.is_file():
        raise SystemExit(f"Generated iOS Info.plist is missing: {INFO_PLIST}")

    with INFO_PLIST.open("rb") as handle:
        info = plistlib.load(handle)

    info["CFBundleDisplayName"] = "Orvix"
    info["NSCameraUsageDescription"] = (
        "Orvix uses the camera only when you choose to scan a QR code."
    )

    ats = info.get("NSAppTransportSecurity")
    if not isinstance(ats, dict):
        ats = {}
    # Orvix can play user/provider media over HTTP and talks to its own
    # localhost helpers on platforms that package them. Keep this narrower
    # than NSAllowsArbitraryLoads so ordinary app traffic remains protected.
    ats["NSAllowsArbitraryLoadsInMedia"] = True
    ats["NSAllowsLocalNetworking"] = True
    info["NSAppTransportSecurity"] = ats

    # media_kit/video playback may use audio while the player is foregrounded.
    # This does not request background audio entitlement or alter app behavior.
    info.setdefault("UIRequiresFullScreen", False)

    with INFO_PLIST.open("wb") as handle:
        plistlib.dump(info, handle, sort_keys=False)


def _pixel_size(entry: dict) -> int | None:
    filename = entry.get("filename")
    size = entry.get("size")
    scale = entry.get("scale")
    if not isinstance(filename, str) or not filename:
        return None
    if not isinstance(size, str) or "x" not in size:
        return None
    if not isinstance(scale, str) or not scale.endswith("x"):
        return None
    try:
        points = float(size.split("x", 1)[0])
        multiplier = float(scale[:-1])
    except ValueError:
        return None
    pixels = round(points * multiplier)
    return pixels if pixels > 0 else None


def configure_app_icons() -> None:
    if not ICON_SOURCE.is_file():
        raise SystemExit(f"Canonical Orvix icon is missing: {ICON_SOURCE}")
    if not APPICON_CONTENTS.is_file():
        raise SystemExit(f"Generated AppIcon manifest is missing: {APPICON_CONTENTS}")

    source = Image.open(ICON_SOURCE).convert("RGBA")
    if source.width < 1024 or source.height < 1024:
        raise SystemExit(
            f"Canonical Orvix icon is too small for iOS: {source.size}; "
            "expected at least 1024x1024"
        )
    if source.size != (1024, 1024):
        source = source.resize((1024, 1024), Image.Resampling.LANCZOS)

    manifest = json.loads(APPICON_CONTENTS.read_text(encoding="utf-8"))
    images = manifest.get("images")
    if not isinstance(images, list):
        raise SystemExit("Generated AppIcon Contents.json has no images array.")

    written = 0
    for entry in images:
        if not isinstance(entry, dict):
            continue
        filename = entry.get("filename")
        pixels = _pixel_size(entry)
        if not isinstance(filename, str) or pixels is None:
            continue
        target = APPICON_DIR / filename
        icon = source if pixels == 1024 else source.resize(
            (pixels, pixels), Image.Resampling.LANCZOS
        )
        # App Store icon assets may not contain alpha. Flatten only the icon
        # file itself; do not change the canonical source artwork.
        if pixels == 1024:
            background = Image.new("RGB", icon.size, (5, 8, 6))
            background.paste(icon, mask=icon.getchannel("A"))
            background.save(target, format="PNG")
        else:
            icon.save(target, format="PNG")
        written += 1

    if written < 5:
        raise SystemExit(f"Only generated {written} iOS app icon assets.")


def main() -> None:
    configure_info_plist()
    configure_app_icons()
    print("Configured generated iOS runner for Orvix.")


if __name__ == "__main__":
    main()
