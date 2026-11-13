from pathlib import Path
import re

# Android Gradle Plugin 9.3.0 and 9.3.1 crash in the release lint step when
# Gradle runs on JDK 17, the JDK these builds use:
#   NoSuchMethodError: 'java.lang.Object java.util.List.removeLast()'
#   (lint's bundled JavaDocParser; Google issue 522845800)
# Flutter 3.50.0 generates projects with 9.3.1. 9.3.2 is the patch release
# whose only listed change is the fix for that crash, so the affected
# versions are moved to it and lint stays on. Every other generated version
# is left exactly as Flutter wrote it.
LINT_CRASH_AGP_VERSIONS = ("9.3.0", "9.3.1")
FIXED_AGP_VERSION = "9.3.2"

_AGP_PLUGIN_LINE = re.compile(
    r'(id\("com\.android\.application"\)\s+version\s+")([^"]+)(")'
)


def use_fixed_android_gradle_plugin(settings: str) -> str:
    """Returns the text of android/settings.gradle.kts with an Android Gradle
    Plugin version that has the release lint crash replaced by the fixed
    patch release. Anything else is returned unchanged."""
    match = _AGP_PLUGIN_LINE.search(settings)
    if match is None or match.group(2) not in LINT_CRASH_AGP_VERSIONS:
        return settings
    return settings[: match.start(2)] + FIXED_AGP_VERSION + settings[match.end(2) :]


def main() -> None:
    manifest = Path("android/app/src/main/AndroidManifest.xml")
    text = manifest.read_text()

    # QR account linking uses the device camera on Android mobile. Insert the
    # permission after any generated <manifest ...> opener instead of assuming
    # Flutter emitted one exact string.
    if "android.permission.CAMERA" not in text:
        opener = re.search(r"<manifest\b[^>]*>", text)
        if opener is None:
            raise SystemExit("Could not find Android manifest opener.")
        camera_declarations = (
            '\n    <uses-permission android:name="android.permission.CAMERA" />'
            '\n    <uses-feature android:name="android.hardware.camera" android:required="false" />'
        )
        text = (
            text[: opener.end()]
            + camera_declarations
            + text[opener.end() :]
        )
    if 'android:extractNativeLibs=' not in text:
        text = text.replace(
            "<application",
            '<application\n        android:extractNativeLibs="true"',
            1,
        )
    else:
        text = re.sub(
            r'android:extractNativeLibs="(?:true|false)"',
            'android:extractNativeLibs="true"',
            text,
            count=1,
        )
    if "android.permission.CAMERA" not in text:
        raise SystemExit("Camera permission was not written to AndroidManifest.xml.")
    if "android.hardware.camera" not in text:
        raise SystemExit("Camera feature declaration was not written to AndroidManifest.xml.")
    manifest.write_text(text)

    gradle = Path("android/app/build.gradle.kts")
    g = gradle.read_text()

    # Flutter 3.47 supports Android API 24+. Keep Flutter's supported minSdk
    # instead of forcing API 23; the compatibility change here is native-lib
    # extraction/legacy packaging, which is safe for current LineageOS builds.
    if "useLegacyPackaging = true" not in g:
        marker = "    defaultConfig {"
        if marker not in g:
            raise SystemExit("Could not find Android defaultConfig block.")
        packaging = """    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

"""
        g = g.replace(marker, packaging + marker, 1)

    gradle.write_text(g)
    print("Configured Android mobile compatibility packaging.")

    settings = Path("android/settings.gradle.kts")
    if settings.is_file():
        generated = settings.read_text()
        fixed = use_fixed_android_gradle_plugin(generated)
        if fixed != generated:
            settings.write_text(fixed)
            print(
                f"Android Gradle Plugin set to {FIXED_AGP_VERSION} "
                "(release lint crash fix)."
            )


if __name__ == "__main__":
    main()
