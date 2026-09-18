from pathlib import Path


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
        import re
        text = re.sub(
            r'android:extractNativeLibs="(?:true|false)"',
            'android:extractNativeLibs="true"',
            text,
            count=1,
        )
    manifest.write_text(text)

    gradle = Path("android/app/build.gradle.kts")
    g = gradle.read_text()

    # Use API 23 so AGP emits a legacy v1 signature as well as modern schemes.
    # Orvix itself still targets the current SDK; this only broadens install
    # verifier compatibility on custom ROMs.
    g = g.replace(
        "minSdk = flutter.minSdkVersion",
        "minSdk = 23",
        1,
    )

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
