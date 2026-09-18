from pathlib import Path

KEYSTORE_NAME = "orvix-release.jks"
KEY_ALIAS = "orvix"
KEY_PASSWORD = "OrvixAlpha-2026-Sign!"


def main() -> None:
    gradle = Path("android/app/build.gradle.kts")
    text = gradle.read_text()

    if f'file("{KEYSTORE_NAME}")' in text:
        print("Android release signing is already configured.")
        return

    marker = "    buildTypes {"
    if marker not in text:
        raise SystemExit("Could not find Android buildTypes block.")

    signing = f'''    signingConfigs {{
        create("release") {{
            keyAlias = "{KEY_ALIAS}"
            keyPassword = "{KEY_PASSWORD}"
            storeFile = file("{KEYSTORE_NAME}")
            storePassword = "{KEY_PASSWORD}"
            // Keep both legacy and modern APK signature schemes enabled.
            // This maximizes sideload compatibility across Android/TV builds.
            enableV1Signing = true
            enableV2Signing = true
        }}
    }}

'''
    text = text.replace(marker, signing + marker, 1)

    debug_line = 'signingConfig = signingConfigs.getByName("debug")'
    release_line = 'signingConfig = signingConfigs.getByName("release")'
    if debug_line not in text:
        raise SystemExit("Could not find Flutter debug signing fallback.")
    text = text.replace(debug_line, release_line, 1)

    gradle.write_text(text)
    print("Configured stable Orvix Android release signing.")


if __name__ == "__main__":
    main()
