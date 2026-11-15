#!/usr/bin/env python3
"""Check a built macOS app bundle and describe what is in it.

Runs on macOS (it uses lipo, otool, codesign, spctl and iconutil). It prints
a report of the bundle's identity, architectures, native libraries, signing
and icon, and fails when an expectation given on the command line is not
met. Everything is printed before it fails, so one run shows the whole
picture.

It never claims more than it sees: an ad-hoc signature is reported as
ad-hoc, and the Gatekeeper assessment is printed as macOS gives it.
"""

from __future__ import annotations

import argparse
import os
import plistlib
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

# Mach-O and universal ("fat") file signatures.
MACHO_MAGICS = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xfe\xed\xfa\xce",
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
}

# A dependency is fine when it is part of macOS or is looked up inside the
# app bundle. Anything else (Homebrew, a build machine path) would be missing
# on a user's Mac.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
BUNDLE_PREFIXES = ("@rpath/", "@executable_path/", "@loader_path/")


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            magic = handle.read(4)
    except OSError:
        return False
    if magic not in MACHO_MAGICS:
        return False
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        # Java class files share this signature; a universal binary has a
        # small architecture count right after it.
        with path.open("rb") as handle:
            handle.seek(4)
            count = struct.unpack(">I", handle.read(4))[0]
        return 0 < count < 20
    return True


def macho_files(app: Path) -> list[Path]:
    return sorted(
        path
        for path in app.rglob("*")
        if path.is_file() and not path.is_symlink() and is_macho(path)
    )


def external_dependencies(otool_output: str) -> list[str]:
    """Dependencies from `otool -L` output that are neither part of macOS nor
    looked up inside the bundle."""
    found = []
    for line in otool_output.splitlines()[1:]:
        dependency = line.strip().split(" (compatibility", 1)[0].strip()
        if not dependency:
            continue
        if dependency.startswith(SYSTEM_PREFIXES + BUNDLE_PREFIXES):
            continue
        found.append(dependency)
    return found


def missing_architectures(present: list[str], required: list[str]) -> list[str]:
    return [arch for arch in required if arch not in present]


def run(*command: str) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, check=False)


def parse_entitlements(raw: bytes) -> dict:
    start = raw.find(b"<?xml")
    if start < 0:
        return {}
    try:
        value = plistlib.loads(raw[start:])
    except Exception:  # noqa: BLE001 - any unreadable blob means "none readable"
        return {}
    return value if isinstance(value, dict) else {}


def icon_difference(icns: Path, master: Path) -> float:
    """Mean per-channel difference (0-255) between the largest image in the
    built icon and the committed 1024 px master."""
    from PIL import Image, ImageChops, ImageStat

    with tempfile.TemporaryDirectory() as temp:
        iconset = Path(temp) / "AppIcon.iconset"
        result = run("iconutil", "--convert", "iconset", str(icns), "--output", str(iconset))
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or "iconutil failed")
        largest = iconset / "icon_512x512@2x.png"
        if not largest.exists():
            raise RuntimeError("the built icon has no 1024 px image")

        def flattened(path: Path) -> Image.Image:
            image = Image.open(path).convert("RGBA")
            backdrop = Image.new("RGBA", image.size, (128, 128, 128, 255))
            backdrop.alpha_composite(image)
            return backdrop.convert("RGB")

        built, wanted = flattened(largest), flattened(master)
        if built.size != wanted.size:
            raise RuntimeError(f"the built icon is {built.size}, expected {wanted.size}")
        return sum(ImageStat.Stat(ImageChops.difference(built, wanted)).mean) / 3


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--name", required=True, help="expected CFBundleName")
    parser.add_argument("--require-arch", action="append", default=[])
    parser.add_argument("--require-entitlement", action="append", default=[])
    parser.add_argument(
        "--expect-text",
        action="append",
        default=[],
        help="text that must be compiled into the Dart code",
    )
    parser.add_argument(
        "--expect-text-env",
        action="append",
        default=[],
        help="environment variable whose value must be compiled into the "
        "Dart code; the value is never printed",
    )
    parser.add_argument("--icon-master", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    lines: list[str] = []
    failures: list[str] = []

    def say(text: str = "") -> None:
        lines.append(text)
        print(text)

    def fail(text: str) -> None:
        failures.append(text)

    app = args.app
    if not app.is_dir():
        print(f"macOS app: {app} is not an app bundle.", file=sys.stderr)
        return 1

    # Identity.
    info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    say(f"App bundle: {app.name}")
    for key in (
        "CFBundleIdentifier",
        "CFBundleName",
        "CFBundleExecutable",
        "CFBundleShortVersionString",
        "CFBundleVersion",
        "LSMinimumSystemVersion",
        "CFBundleIconFile",
        "CFBundleIconName",
    ):
        say(f"  {key}: {info.get(key)}")
    if info.get("CFBundleIdentifier") != args.bundle_id:
        fail(f"bundle identifier is {info.get('CFBundleIdentifier')!r}, expected {args.bundle_id!r}")
    if info.get("CFBundleName") != args.name:
        fail(f"bundle name is {info.get('CFBundleName')!r}, expected {args.name!r}")

    # Architectures.
    executable = app / "Contents" / "MacOS" / str(info.get("CFBundleExecutable"))
    say()
    say("Architectures")
    primary = [executable]
    for framework in ("App", "FlutterMacOS"):
        binary = app / "Contents" / "Frameworks" / f"{framework}.framework" / framework
        primary.append(binary.resolve() if binary.exists() else binary)
    primary_resolved = {path.resolve() for path in primary if path.exists()}
    intel_missing = []
    for path in macho_files(app):
        present = run("lipo", "-archs", str(path)).stdout.split()
        relative = path.relative_to(app)
        is_primary = path.resolve() in primary_resolved
        if is_primary:
            say(f"  {relative}: {' '.join(present) or 'unknown'}")
        missing = missing_architectures(present, args.require_arch)
        if "arm64" in missing or (is_primary and missing):
            fail(f"{relative} lacks {', '.join(missing)}")
        elif missing:
            intel_missing.append(f"{relative} ({' '.join(present)})")
    for path in primary:
        if not path.exists():
            fail(f"{path.relative_to(app)} is missing")
    all_macho = macho_files(app)
    say(f"  {len(all_macho)} native binaries in the bundle")
    if intel_missing:
        say("  Without every requested architecture:")
        for entry in intel_missing:
            say(f"    {entry}")

    # Native libraries.
    say()
    say("Bundled native libraries")
    frameworks = app / "Contents" / "Frameworks"
    for entry in sorted(frameworks.iterdir()) if frameworks.is_dir() else []:
        say(f"  {entry.name}")
    external: dict[str, list[str]] = {}
    for path in all_macho:
        found = external_dependencies(run("otool", "-L", str(path)).stdout)
        if found:
            external[str(path.relative_to(app))] = found
    if external:
        say("  Dependencies outside macOS and the bundle:")
        for owner, dependencies in external.items():
            for dependency in dependencies:
                say(f"    {owner} -> {dependency}")
        fail("the app depends on libraries that are not in the bundle or in macOS")
    else:
        say("  No dependency outside macOS and the bundle.")

    # Signing.
    say()
    say("Code signing")
    details = run("codesign", "--display", "--verbose=2", str(app)).stderr
    for line in details.splitlines():
        if line.startswith(("Signature", "TeamIdentifier", "Authority", "CodeDirectory", "Identifier")):
            say(f"  {line}")
    verify = run("codesign", "--verify", "--deep", "--strict", str(app))
    say(f"  Signature valid: {'yes' if verify.returncode == 0 else 'no'}")
    if verify.returncode != 0:
        say(f"  {verify.stderr.strip()}")
        fail("the code signature does not verify")
    raw = subprocess.run(
        ["codesign", "--display", "--entitlements", "-", "--xml", str(app)],
        capture_output=True,
        check=False,
    ).stdout
    entitlements = parse_entitlements(raw)
    say("  Entitlements:")
    for key in sorted(entitlements):
        say(f"    {key} = {entitlements[key]}")
    if not entitlements:
        say("    (none)")
    for key in args.require_entitlement:
        if entitlements.get(key) is not True:
            fail(f"entitlement {key} is not set")
    assessment = run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
    say("  Gatekeeper assessment (not notarized builds are expected to be rejected):")
    for line in (assessment.stdout + assessment.stderr).strip().splitlines():
        say(f"    {line}")

    # Compiled Dart code.
    dart = app / "Contents" / "Frameworks" / "App.framework" / "App"
    if args.expect_text or args.expect_text_env:
        say()
        say("Compiled Dart code")
        blob = dart.resolve().read_bytes() if dart.exists() else b""
        wanted = [(text, text) for text in args.expect_text]
        for variable in args.expect_text_env:
            value = os.environ.get(variable, "").strip().rstrip("/")
            if not value:
                fail(f"{variable} is not set")
                continue
            wanted.append((f"the value of {variable}", value))
        for label, value in wanted:
            present = value.encode() in blob or value.encode("utf-16-le") in blob
            say(f"  contains {label}: {'yes' if present else 'no'}")
            if not present:
                fail(f"the compiled Dart code does not contain {label}")

    # Icon.
    say()
    say("Icon")
    icns = app / "Contents" / "Resources" / "AppIcon.icns"
    if not icns.exists():
        fail("Contents/Resources/AppIcon.icns is missing")
    else:
        say(f"  AppIcon.icns: {icns.stat().st_size} bytes")
        if args.icon_master is not None:
            try:
                difference = icon_difference(icns, args.icon_master)
            except Exception as error:  # noqa: BLE001 - report any reason
                fail(f"could not compare the built icon: {error}")
            else:
                say(f"  Difference from {args.icon_master}: {difference:.2f} of 255")
                if difference > 3.0:
                    fail("the built icon is not the committed macOS icon")

    say()
    if failures:
        say("FAILED")
        for failure in failures:
            say(f"  - {failure}")
    else:
        say("All checks passed.")
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
