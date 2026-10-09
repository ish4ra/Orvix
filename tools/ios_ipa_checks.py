#!/usr/bin/env python3
"""Platform-independent checks for an Orvix unsigned iOS sideload IPA.

Used by tools/verify_ios_ipa.sh (Modern) and tools/verify_ios_legacy_ipa.sh
(Legacy), which add the macOS-only codesign/otool/vtool checks on top.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ios_macho import check_binaries, format_inventory, highest_minos, scan_app  # noqa: E402
from ios_profiles import PROFILES, IosProfile, get_profile  # noqa: E402
from update_altstore_source import (  # noqa: E402
    ios_build_version,
    ios_marketing_version,
    read_ipa,
)

APP_DIR = "Payload/Orvix.app/"
BUNDLE_ID = "com.orvix.orvix"
DISPLAY_NAME = "Orvix"


def check_layout(names: list[str]) -> list[str]:
    problems = []
    if f"{APP_DIR}Info.plist" not in names:
        problems.append("IPA is missing Payload/Orvix.app/Info.plist")
    for name in names:
        if name in ("Payload/", APP_DIR) or name.startswith(APP_DIR):
            continue
        problems.append(f"unexpected entry outside Payload/Orvix.app: {name}")
    for name in names:
        if name.startswith(f"{APP_DIR}_CodeSignature/"):
            problems.append(
                "Payload/Orvix.app is code signed (_CodeSignature); the sideload IPA "
                "must ship the app unsigned"
            )
            break
    for name in names:
        if name.endswith("embedded.mobileprovision"):
            problems.append(f"IPA contains a provisioning profile: {name}")
    return problems


def check_metadata(info: dict, release: str, build: str, profile: IosProfile) -> list[str]:
    expected = {
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleDisplayName": DISPLAY_NAME,
        "CFBundleShortVersionString": ios_marketing_version(release),
        "CFBundleVersion": ios_build_version(build),
        "MinimumOSVersion": profile.min_ios,
    }
    problems = [
        f"IPA {key}={info.get(key)!r}, expected {value!r}"
        for key, value in expected.items()
        if info.get(key) != value
    ]
    if not info.get("NSCameraUsageDescription"):
        problems.append("IPA is missing NSCameraUsageDescription")
    if not info.get("CFBundleExecutable"):
        problems.append("IPA is missing CFBundleExecutable")
    return problems


def check_ipa(
    ipa: Path,
    release: str,
    build: str,
    profile: IosProfile,
    *,
    check_filename: bool = True,
    report=print,
) -> list[str]:
    """Return every problem found; an empty list means the IPA passed."""
    if not ipa.is_file() or ipa.stat().st_size == 0:
        return [f"IPA is missing or empty: {ipa}"]
    problems: list[str] = []
    if check_filename:
        expected_name = profile.ipa_filename(release)
        if ipa.name != expected_name:
            problems.append(f"IPA is named {ipa.name}, expected {expected_name}")

    try:
        with zipfile.ZipFile(ipa) as archive:
            broken = archive.testzip()
            if broken is not None:
                return problems + [f"IPA zip integrity check failed at {broken}"]
            names = archive.namelist()
    except zipfile.BadZipFile as exc:
        return problems + [f"IPA is not a valid zip file: {exc}"]

    layout = check_layout(names)
    problems += layout
    if layout:
        return problems

    try:
        info, _ = read_ipa(ipa)
        problems += check_metadata(info, release, build, profile)
    except (ValueError, OSError) as exc:
        return problems + [f"{type(exc).__name__}: {exc}"]

    executable = info.get("CFBundleExecutable")
    with tempfile.TemporaryDirectory(prefix="orvix-ipa-check.") as temporary:
        with zipfile.ZipFile(ipa) as archive:
            archive.extractall(temporary)
        app = Path(temporary) / "Payload" / "Orvix.app"
        binaries = scan_app(app)
        report(
            f"Mach-O deployment targets ({profile.name}, allowed up to iOS "
            f"{profile.min_ios}):\n{format_inventory(binaries)}\n"
            f"{len(binaries)} Mach-O binaries; highest iOS deployment target "
            f"{highest_minos(binaries)}"
        )
        problems += check_binaries(binaries, profile.min_ios, f"Orvix.app/{executable}")
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("ipa", type=Path)
    parser.add_argument("release_version")
    parser.add_argument("build_number")
    args = parser.parse_args(argv)

    profile = get_profile(args.profile)
    problems = check_ipa(args.ipa, args.release_version, args.build_number, profile)
    if problems:
        for problem in problems:
            if os.environ.get("GITHUB_ACTIONS"):
                print(f"::error title=iOS {profile.name} IPA verification::{problem}", flush=True)
            print(f"error: {problem}", file=sys.stderr)
        return 1
    print(
        f"IPA metadata, layout and Mach-O checks OK: {args.ipa.name} "
        f"({profile.name}, MinimumOSVersion {profile.min_ios})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
