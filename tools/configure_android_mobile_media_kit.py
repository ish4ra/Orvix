from __future__ import annotations

import json
import re
from pathlib import Path
from urllib.parse import unquote, urlparse

FULL_LIBMPV_VERSION = "1.1.11"
FULL_JARS = {
    "arm64-v8a": "cdb54c5cf24725623ca717bbbd6d991031d625a377460bd128f19c2dffe189bd",
    "armeabi-v7a": "b658f2ff91169f8dad0e09e0240ebe200bb3df999da5712f8fab96ad11a4fbec",
    "x86": "8b3b84e54ec09bb79972095dc04bcaf651294da4e73b1e7c3251055fd8a2b901",
    "x86_64": "848936cfd7333077f21759adaca4a9e1a5647891da2e42ab211c5bdc30f4535d",
}


def _package_root(package_name: str) -> Path:
    config_path = Path(".dart_tool/package_config.json")
    if not config_path.exists():
        raise SystemExit(
            ".dart_tool/package_config.json is missing. Run flutter pub get first."
        )

    data = json.loads(config_path.read_text(encoding="utf-8"))
    for package in data.get("packages", []):
        if package.get("name") != package_name:
            continue

        raw = package.get("rootUri")
        if not raw:
            break
        parsed = urlparse(raw)
        if parsed.scheme == "file":
            return Path(unquote(parsed.path)).resolve()
        return (config_path.parent / unquote(raw)).resolve()

    raise SystemExit(f"Could not locate package {package_name!r} in package_config.json.")


def patch_media_kit_android_video() -> Path:
    root = _package_root("media_kit_libs_android_video")
    gradle = root / "android" / "build.gradle"
    if not gradle.exists():
        raise SystemExit(f"media_kit Android Gradle file was not found: {gradle}")

    text = gradle.read_text(encoding="utf-8")
    original = text

    for abi, sha256 in FULL_JARS.items():
        pattern = re.compile(
            r'\["url": "https://github\.com/media-kit/libmpv-android-video-build/'
            r'releases/download/v[^"]+/default-' + re.escape(abi) +
            r'\.jar", "md5": "[0-9a-f]+", "destination": file\("\$buildDir/'
            r'v[^"]+/default-' + re.escape(abi) + r'\.jar"\)\]'
        )
        replacement = (
            '["url": "https://github.com/media-kit/libmpv-android-video-build/'
            f'releases/download/v{FULL_LIBMPV_VERSION}/full-{abi}.jar", '
            f'"sha256": "{sha256}", '
            f'"destination": file("$buildDir/v{FULL_LIBMPV_VERSION}/full-{abi}.jar")]'
        )
        text, count = pattern.subn(replacement, text, count=1)
        if count != 1:
            raise SystemExit(
                f"Expected exactly one media_kit default {abi} JAR entry; found {count}."
            )

    text = text.replace(
        'MessageDigest.getInstance("MD5")',
        'MessageDigest.getInstance("SHA-256")',
    )
    text = text.replace("fileInfo.md5", "fileInfo.sha256")
    text = text.replace("MD5 mismatch", "SHA-256 mismatch")
    text = text.replace("MD5 verification failed", "SHA-256 verification failed")

    if text == original:
        raise SystemExit("media_kit Android Gradle file was not changed.")

    for abi in FULL_JARS:
        expected = (
            f"releases/download/v{FULL_LIBMPV_VERSION}/full-{abi}.jar"
        )
        if expected not in text:
            raise SystemExit(f"Patched Gradle is missing {expected}.")
    if "default-arm64-v8a.jar" in text:
        raise SystemExit("Default media_kit libmpv JAR is still present after patch.")
    if "MessageDigest.getInstance(\"SHA-256\")" not in text:
        raise SystemExit("Patched Gradle is not verifying the full JARs with SHA-256.")

    gradle.write_text(text, encoding="utf-8")
    print(
        "Configured Android Mobile media_kit with full libmpv "
        f"v{FULL_LIBMPV_VERSION} (PGS/HDMV decoder enabled)."
    )
    return gradle


if __name__ == "__main__":
    patch_media_kit_android_video()
