#!/usr/bin/env python3
"""Upload signed Orvix internal installers to PRIVATE Supabase Storage.

Requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in CI secret context.
Never run on PRs from forks or print credentials. The internal manifest is
written only after a successful upload, and ordinary users lack table/storage
permissions. Intended for manual workflow_dispatch builds only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from urllib.parse import quote


def platform_for(name: str) -> str | None:
    if name.endswith("-Windows-x64.exe") and "Setup" in name:
        return "windows"
    if name.endswith("-Android-TV.apk"):
        return "android_tv"
    if name.endswith("-Android-Mobile.apk"):
        return "android_mobile"
    if name.endswith("-macOS.zip"):
        return "macos"
    if name.endswith("-iOS-15.5-Plus.ipa"):
        return "ios_modern"
    if name.endswith("-iOS-12-Legacy.ipa"):
        return "ios_legacy"
    return None


def curl(args: list[str], token: str) -> None:
    command = ["curl", "--fail-with-body", "--silent", "--show-error", "--retry", "3", "--retry-delay", "2"] + args
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        # Do not print response bodies, URLs with query credentials, or secrets.
        raise RuntimeError(f"Internal upload HTTP request failed (curl {result.returncode})")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--asset-list", required=True, type=Path)
    args = parser.parse_args()
    if not args.version.startswith("0.7.") or "/" in args.version:
        raise SystemExit("Invalid Orvix version")
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not base.startswith("https://") or not key:
        raise SystemExit("Internal release secrets unavailable; refusing to publish publicly")
    paths = [Path(line.strip()) for line in args.asset_list.read_text().splitlines() if line.strip()]
    selected: dict[str, Path] = {}
    for asset in paths:
        platform = platform_for(asset.name)
        if platform is None:
            continue  # Platform-specific archives and splits are not installer targets.
        if platform in selected:
            raise SystemExit(f"Duplicate internal platform: {platform}")
        if not asset.is_file() or asset.stat().st_size <= 0:
            raise SystemExit(f"Missing installer: {asset}")
        selected[platform] = asset
    if not selected or not {"windows", "android_tv", "android_mobile"}.issubset(selected):
        raise SystemExit("Internal all-platform release is missing required installers")
    for platform, asset in selected.items():
        digest = hashlib.file_digest(asset.open("rb"), "sha256").hexdigest()
        object_path = f"{args.version}/{platform}/{asset.name}"
        url = base + "/storage/v1/object/orvix-internal-updates/" + quote(object_path, safe="/")
        curl(["-X", "POST", url, "-H", "Authorization: Bearer " + key,
              "-H", "apikey: " + key, "-H", "x-upsert: true",
              "-H", "Content-Type: application/octet-stream",
              "--data-binary", "@" + str(asset)], key)
        record = [{
            "version": args.version, "platform": platform,
            "object_path": object_path, "asset_name": asset.name,
            "size_bytes": asset.stat().st_size, "sha256": digest,
        }]
        curl(["-X", "POST", base + "/rest/v1/orvix_internal_release_assets?on_conflict=version,platform",
              "-H", "Authorization: Bearer " + key, "-H", "apikey: " + key,
              "-H", "Prefer: resolution=merge-duplicates,return=minimal",
              "-H", "Content-Type: application/json",
              "--data-binary", json.dumps(record)], key)
        print(f"Private internal release registered: {platform} ({asset.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
