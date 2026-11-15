#!/usr/bin/env python3
"""Give a private test build its own identity.

A test build must install and run next to the public app without replacing
it or sharing its saved data:

  android  application id com.orvix.orvix.wptest and the name "Orvix Test".
           The code namespace is not changed.
  windows  product name "orvix-watch-party-test", which is the folder the app
           keeps its settings and sign-in in. The single-instance guard is
           left alone on purpose: the test build and the installed app share
           the stream cache, so only one of them may run at a time.

  macos    bundle identifier com.orvix.orvix.wptest and the name
           "Orvix Watch Party Test". macOS keeps a sandboxed app's settings,
           sign-in, caches and temporary files in a folder named after the
           bundle identifier, so all of them are separate from the public
           app's.

Run after the platform's normal configuration scripts. It fails if a file
does not look as expected, so a template change cannot silently produce a
test build that carries the public identity.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PUBLIC_ANDROID_ID = "com.orvix.orvix"
TEST_ANDROID_ID = "com.orvix.orvix.wptest"
TEST_APP_LABEL = "Orvix Test"
TEST_WINDOWS_PRODUCT = "orvix-watch-party-test"
PUBLIC_MACOS_ID = "com.orvix.orvix"
TEST_MACOS_ID = "com.orvix.orvix.wptest"
TEST_MACOS_NAME = "Orvix Watch Party Test"


class IdentityError(Exception):
    pass


def _replace_once(text: str, old: str, new: str, what: str) -> str:
    if text.count(old) != 1:
        raise IdentityError(f"expected exactly one {what}, found {text.count(old)}.")
    return text.replace(old, new)


def android_gradle(text: str) -> str:
    return _replace_once(
        text,
        f'applicationId = "{PUBLIC_ANDROID_ID}"',
        f'applicationId = "{TEST_ANDROID_ID}"',
        "application id line",
    )


def android_manifest(text: str) -> str:
    return _replace_once(
        text,
        'android:label="Orvix"',
        f'android:label="{TEST_APP_LABEL}"',
        "application label",
    )


def windows_resources(text: str) -> str:
    text = _replace_once(
        text,
        'VALUE "ProductName", "orvix" "\\0"',
        f'VALUE "ProductName", "{TEST_WINDOWS_PRODUCT}" "\\0"',
        "ProductName value",
    )
    return _replace_once(
        text,
        'VALUE "FileDescription", "Orvix" "\\0"',
        f'VALUE "FileDescription", "{TEST_APP_LABEL}" "\\0"',
        "FileDescription value",
    )


def macos_app_info(text: str) -> str:
    lines = text.split("\n")
    wanted = {
        "PRODUCT_NAME = Orvix": f"PRODUCT_NAME = {TEST_MACOS_NAME}",
        f"PRODUCT_BUNDLE_IDENTIFIER = {PUBLIC_MACOS_ID}": (
            f"PRODUCT_BUNDLE_IDENTIFIER = {TEST_MACOS_ID}"
        ),
    }
    for old, new in wanted.items():
        matches = [index for index, line in enumerate(lines) if line.strip() == old]
        if len(matches) != 1:
            raise IdentityError(f"expected exactly one line '{old}', found {len(matches)}.")
        lines[matches[0]] = new
    return "\n".join(lines)


TARGETS = {
    "android": (
        ("android/app/build.gradle.kts", android_gradle),
        ("android/app/src/main/AndroidManifest.xml", android_manifest),
    ),
    "macos": (("macos/Runner/Configs/AppInfo.xcconfig", macos_app_info),),
    "windows": (("windows/runner/Runner.rc", windows_resources),),
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=sorted(TARGETS))
    args = parser.parse_args()
    try:
        for relative, change in TARGETS[args.platform]:
            path = ROOT / relative
            if not path.exists():
                raise IdentityError(f"{relative} does not exist.")
            # newline="" keeps the file's own line endings (Runner.rc).
            with path.open(encoding="utf-8", newline="") as handle:
                original = handle.read()
            with path.open("w", encoding="utf-8", newline="") as handle:
                handle.write(change(original))
    except IdentityError as error:
        print(f"Test build identity: {error}", file=sys.stderr)
        return 1
    print(f"Test build identity applied for {args.platform}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
