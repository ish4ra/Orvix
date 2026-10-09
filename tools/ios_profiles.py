#!/usr/bin/env python3
"""The two Orvix iOS sideload builds and everything that tells them apart.

Each build profile is fixed here and selected explicitly by name. There is
no shared, mutable "minimum iOS" setting, so the Modern IPA cannot pick up
Legacy dependencies (or the reverse) by accident.

- modern: the recommended build. Current Flutter and current dependencies;
  iOS / iPadOS 15.5 or later (mobile_scanner 6.x needs 15.5).
- legacy: older 64-bit devices such as iPhone 5s / 6 / 6 Plus on iOS 12.
  Pinned Flutter 3.32 toolchain (the last release that targets iOS 12) and
  the Legacy-only dependency overrides in tools/ios_legacy/.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class IosProfile:
    name: str
    min_ios: str
    asset_suffix: str
    ci_artifact: str
    title: str
    # None means "the stable Flutter the rest of CI uses".
    flutter_version: str | None = None
    xcode_version: str | None = None
    # Xcode embeds Apple-signed libswift*.dylib back-deployment copies only
    # for deployment targets below iOS 12.2, i.e. only in the Legacy build.
    allows_embedded_swift_runtime: bool = False

    def ipa_filename(self, release_version: str) -> str:
        version = release_version.strip()
        if not version or "/" in version or version.startswith("v"):
            raise ValueError(f"invalid release version for an IPA name: {release_version!r}")
        return f"Orvix-v{version}-{self.asset_suffix}.ipa"


MODERN = IosProfile(
    name="modern",
    min_ios="15.5",
    asset_suffix="iOS-15.5-Plus",
    ci_artifact="ios-modern",
    title="Build iOS Modern sideload IPA",
)

LEGACY = IosProfile(
    name="legacy",
    min_ios="12.0",
    asset_suffix="iOS-12-Legacy",
    ci_artifact="ios-legacy",
    title="Build iOS Legacy sideload IPA",
    flutter_version="3.32.8",
    xcode_version="16.4",
    allows_embedded_swift_runtime=True,
)

PROFILES = {profile.name: profile for profile in (MODERN, LEGACY)}


def get_profile(name: str) -> IosProfile:
    try:
        return PROFILES[name]
    except KeyError:
        raise ValueError(
            f"unknown iOS build profile {name!r}; expected one of {', '.join(PROFILES)}"
        ) from None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Print one iOS build profile value.")
    parser.add_argument(
        "field",
        choices=("min-ios", "ipa-filename", "ci-artifact", "flutter-version", "xcode-version"),
    )
    parser.add_argument("profile", choices=sorted(PROFILES))
    parser.add_argument("release_version", nargs="?")
    args = parser.parse_args(argv)

    profile = get_profile(args.profile)
    if args.field == "ipa-filename":
        if not args.release_version:
            parser.error("ipa-filename needs a release version")
        print(profile.ipa_filename(args.release_version))
    elif args.field == "min-ios":
        print(profile.min_ios)
    elif args.field == "ci-artifact":
        print(profile.ci_artifact)
    elif args.field == "flutter-version":
        print(profile.flutter_version or "")
    else:
        print(profile.xcode_version or "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
