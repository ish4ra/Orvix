#!/usr/bin/env python3
"""Update Orvix's AltStore/SideStore source from a built unsigned IPA."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

APP_INFO_PATTERN = re.compile(r"^Payload/[^/]+\.app/Info\.plist$")
# Only the app bundle itself must be unsigned. Embedded frameworks such as
# Flutter.framework ship pre-signed; sideload tools re-sign them anyway.
APP_SIGNATURE_PATTERN = re.compile(
    r"^Payload/[^/]+\.app/(?:_CodeSignature/|embedded\.mobileprovision$)"
)
INFO_PATTERN = re.compile(
    r"^Payload/[^/]+\.app(?:/PlugIns/[^/]+\.appex)?/Info\.plist$"
)
PRIVACY_KEY_PATTERN = re.compile(r"^NS.+UsageDescription$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--release-notes", required=True, type=Path)
    parser.add_argument("--release-version", required=True)
    parser.add_argument("--release-date", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--build-version")
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def _string(mapping: dict, key: str, context: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{context} is missing {key}")
    return value.strip()


def read_source(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        source = json.load(handle)
    if not isinstance(source, dict):
        raise ValueError("AltStore source root must be an object")
    apps = source.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("AltStore source must contain at least one app")
    return source


def read_ipa(path: Path) -> tuple[dict, dict[str, str]]:
    if not path.is_file():
        raise ValueError(f"IPA does not exist: {path}")
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        infos = [name for name in names if APP_INFO_PATTERN.fullmatch(name)]
        if len(infos) != 1:
            raise ValueError(
                f"IPA must contain exactly one app Info.plist, found {len(infos)}"
            )
        if any(APP_SIGNATURE_PATTERN.match(name) for name in names):
            raise ValueError("IPA must be unsigned so AltStore/SideStore can re-sign it")

        app_info = plistlib.loads(archive.read(infos[0]))
        privacy: dict[str, str] = {}
        for name in names:
            if not INFO_PATTERN.fullmatch(name):
                continue
            info = plistlib.loads(archive.read(name))
            for key, value in info.items():
                if not PRIVACY_KEY_PATTERN.fullmatch(key) or not isinstance(value, str):
                    continue
                old = privacy.get(key)
                if old is not None and old != value:
                    raise ValueError(f"IPA contains conflicting values for {key}")
                privacy[key] = value
    return app_info, privacy


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


RELEASE_VERSION_PATTERN = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?"
    r"(?:\+[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?$"
)
BUILD_VERSION_PATTERN = re.compile(r"^[1-9]\d*$")


def ios_marketing_version(release_version: str) -> str:
    """Return Apple's three-component CFBundleShortVersionString.

    Prerelease and build suffixes never become extra components:
    ``0.7.9-beta.64`` and ``0.7.9-beta.64+4209`` both map to ``0.7.9``.
    Beta iterations are told apart by CFBundleVersion instead.
    """
    match = RELEASE_VERSION_PATTERN.fullmatch(release_version.strip())
    if match is None:
        raise ValueError(
            f"could not derive iOS marketing version from {release_version!r}; "
            "expected Major.Minor.Patch with an optional -prerelease/+build suffix"
        )
    return ".".join(match.groups())


def ios_build_version(build_number: str) -> str:
    """Validate the app build number used as CFBundleVersion."""
    value = build_number.strip()
    if BUILD_VERSION_PATTERN.fullmatch(value) is None:
        raise ValueError(
            f"iOS build version must be a positive integer, got {build_number!r}"
        )
    return value


def validate_date(value: str) -> None:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("release date must include a timezone")


def validate_url(value: str) -> None:
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or not parsed.path.endswith(".ipa"):
        raise ValueError("download URL must be an HTTPS IPA URL")


def update_versions(app: dict, entry: dict) -> None:
    versions = app.get("versions")
    if not isinstance(versions, list):
        raise ValueError("source app versions must be an array")

    # Re-running publication for the exact same version/build is idempotent.
    kept = []
    for old in versions:
        if not isinstance(old, dict):
            raise ValueError("source version entries must be objects")
        if (
            old.get("version") == entry["version"]
            and old.get("buildVersion") == entry["buildVersion"]
        ):
            continue
        kept.append(old)
    app["versions"] = [entry, *kept]


def write_source(path: Path, source: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(source, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main() -> int:
    args = parse_args()
    source = read_source(args.source)
    app_info, privacy = read_ipa(args.ipa)

    bundle_id = _string(app_info, "CFBundleIdentifier", "application Info.plist")
    version = _string(app_info, "CFBundleShortVersionString", "application Info.plist")
    build = _string(app_info, "CFBundleVersion", "application Info.plist")
    min_os = _string(app_info, "MinimumOSVersion", "application Info.plist")

    expected_ios_version = ios_marketing_version(args.release_version)
    if version != expected_ios_version:
        raise ValueError(
            f"IPA version {version} does not match expected iOS version "
            f"{expected_ios_version} for release {args.release_version}"
        )
    build = ios_build_version(build)
    if args.build_version is not None and build != ios_build_version(args.build_version):
        raise ValueError(
            f"IPA build version {build} does not match expected {args.build_version}"
        )
    validate_date(args.release_date)
    validate_url(args.download_url)

    notes = args.release_notes.read_text(encoding="utf-8").strip()
    if not notes:
        raise ValueError("release notes must not be empty")

    matches = [
        app for app in source["apps"]
        if isinstance(app, dict) and app.get("bundleIdentifier") == bundle_id
    ]
    if len(matches) != 1:
        raise ValueError(
            f"source must contain exactly one app with bundle identifier {bundle_id}"
        )
    app = matches[0]

    permissions = app.get("appPermissions")
    if not isinstance(permissions, dict):
        permissions = {}
        app["appPermissions"] = permissions
    permissions["entitlements"] = []
    permissions["privacy"] = privacy

    entry = {
        "version": version,
        "buildVersion": build,
        # Human-facing label; AltStore matches version/buildVersion to the IPA.
        "marketingVersion": args.release_version,
        "date": args.release_date,
        "localizedDescription": notes,
        "downloadURL": args.download_url,
        "size": args.ipa.stat().st_size,
        "sha256": sha256(args.ipa),
        "minOSVersion": min_os,
    }
    update_versions(app, entry)
    output = args.output or args.source
    write_source(output, source)
    print(f"Updated {output} with Orvix {version} ({build})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError, plistlib.InvalidFileException) as exc:
        print(f"error: {exc}", file=__import__("sys").stderr)
        raise SystemExit(1)
