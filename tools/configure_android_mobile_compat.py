from pathlib import Path
import re


def main() -> None:
    manifest = Path("android/app/src/main/AndroidManifest.xml")
    text = manifest.read_text()
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


if __name__ == "__main__":
    main()
