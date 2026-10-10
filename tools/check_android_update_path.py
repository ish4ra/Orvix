"""Update-path gate for Orvix Android APKs.

verify_android_apk.py proves an APK installs on a clean device. This proves
it installs *over* the release users already have: Android accepts an APK as
an update only when it has the same package name, is signed by the same
certificate and has a strictly higher versionCode. Any of those failing makes
the in-app updater hand Android an APK that is rejected.

Usage:
    python3 tools/check_android_update_path.py --build-tools <dir> \
        --previous <published.apk> <new.apk> [<new.apk>...]

Pass the most recently published APK for the same product (Android Mobile or
Android TV) as --previous, and every APK of the new release for that product.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from verify_android_apk import (
    Failures,
    check_signature,
    find_tool,
    parse_badging,
    run,
)


def identity(apk: str, aapt2: Path, apksigner: Path, failures: Failures):
    """(package, versionCode, versionName, cert) or None when unreadable."""
    if not Path(apk).is_file() or Path(apk).stat().st_size == 0:
        failures.add(apk, "file is missing or empty")
        return None
    cert = check_signature(apk, apksigner, failures)
    badging_run = run([str(aapt2), "dump", "badging", apk])
    if badging_run.returncode != 0:
        failures.add(apk, f"aapt2 dump badging failed: {badging_run.stderr.strip()}")
        return None
    badging = parse_badging(badging_run.stdout)
    if cert is None:
        return None
    return badging.package, badging.version_code, badging.version_name, cert


def check(args: argparse.Namespace) -> int:
    build_tools = Path(args.build_tools)
    apksigner = find_tool(build_tools, "apksigner")
    aapt2 = find_tool(build_tools, "aapt2")

    failures = Failures()
    previous = identity(args.previous, aapt2, apksigner, failures)
    if previous is None:
        failures.add(args.previous, "cannot read the published APK to compare against")
    else:
        prev_package, prev_code, prev_name, prev_cert = previous
        print(
            f"published {args.previous}: {prev_package} versionCode={prev_code} "
            f"versionName={prev_name} cert={prev_cert}"
        )
        for apk in args.apks:
            current = identity(apk, aapt2, apksigner, failures)
            if current is None:
                continue
            package, code, name, cert = current
            print(f"new {apk}: {package} versionCode={code} versionName={name} cert={cert}")
            if package != prev_package:
                failures.add(
                    apk, f"package {package!r} differs from published {prev_package!r}"
                )
            if cert != prev_cert:
                failures.add(
                    apk,
                    f"signing certificate {cert} differs from published {prev_cert}; "
                    "Android will refuse the update",
                )
            if code <= prev_code:
                failures.add(
                    apk,
                    f"versionCode {code} is not above published {prev_code} "
                    f"({prev_name}); raise +BUILD in pubspec.yaml",
                )

    if failures:
        print("\nAndroid update-path check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Android update-path check passed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--build-tools", required=True, help="Android SDK build-tools directory")
    parser.add_argument("--previous", required=True, help="most recently published APK")
    parser.add_argument("apks", nargs="+", metavar="APK")
    return check(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
