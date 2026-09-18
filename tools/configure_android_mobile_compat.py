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

    g, min_sdk_count = re.subn(
        r"(?m)^(\s*)minSdk\s*=\s*[^\n]+$",
        r"\1minSdk = 23",
        g,
        count=1,
    )
    if min_sdk_count != 1:
        raise SystemExit("Could not locate Android minSdk assignment.")

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
