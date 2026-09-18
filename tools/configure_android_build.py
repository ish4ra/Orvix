import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def patch_android(tv: bool) -> None:
    manifest = Path("android/app/src/main/AndroidManifest.xml")
    text = manifest.read_text()

    if "android.permission.INTERNET" not in text:
        text = text.replace(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <uses-permission android:name="android.permission.INTERNET" />\n'
            '    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />\n'
            '    <uses-permission android:name="android.permission.WAKE_LOCK" />',
        )

    text = text.replace(
        'android:label="orvix"',
        'android:label="Orvix"',
    )

    if "android:usesCleartextTraffic=" not in text:
        text = text.replace(
            "<application",
            '<application\n        android:usesCleartextTraffic="true"',
            1,
        )

    if tv and 'android:banner="@drawable/tv_banner"' not in text:
        text = text.replace(
            "<application",
            '<application\n        android:banner="@drawable/tv_banner"',
            1,
        )

    if 'android:roundIcon=' not in text:
        text = text.replace(
            "<application",
            '<application\n        android:roundIcon="@mipmap/ic_launcher_round"',
            1,
        )

    if tv:
        if 'android:screenOrientation="landscape"' not in text:
            text = text.replace(
                'android:name=".MainActivity"',
                'android:name=".MainActivity"\n'
                '            android:screenOrientation="landscape"',
                1,
            )
        if "android.software.leanback" not in text:
            text = text.replace(
                '<uses-permission android:name="android.permission.WAKE_LOCK" />',
                '<uses-permission android:name="android.permission.WAKE_LOCK" />\n'
                '    <uses-feature android:name="android.software.leanback" android:required="true" />\n'
                '    <uses-feature android:name="android.hardware.touchscreen" android:required="false" />',
            )
        if "android.intent.category.LEANBACK_LAUNCHER" not in text:
            text = text.replace(
                '<category android:name="android.intent.category.LAUNCHER"/>',
                '<category android:name="android.intent.category.LAUNCHER"/>\n'
                '                <category android:name="android.intent.category.LEANBACK_LAUNCHER"/>',
            )

    manifest.write_text(text)

    gradle = Path("android/app/build.gradle.kts")
    gradle_text = gradle.read_text()
    gradle_text = gradle_text.replace(
        "minSdk = flutter.minSdkVersion",
        "minSdk = 24",
    )
    aar_dep = 'implementation(files("libs/rustls-platform-verifier-0.1.1.aar"))'
    if aar_dep not in gradle_text:
        gradle_text += f"\n\ndependencies {{\n    {aar_dep}\n}}\n"
    gradle.write_text(gradle_text)

    src = Image.open("assets/branding/orvix_icon.png").convert("RGBA")
    sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in sizes.items():
        out = Path(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        src.resize((size, size), Image.Resampling.LANCZOS).save(out)

    fg = Image.new("RGBA", (432, 432), (0, 0, 0, 0))
    logo = src.copy()
    logo.thumbnail((380, 380), Image.Resampling.LANCZOS)
    fg.alpha_composite(
        logo,
        ((432 - logo.width) // 2, (432 - logo.height) // 2),
    )
    fg_path = Path("android/app/src/main/res/drawable-nodpi/orvix_foreground.png")
    fg_path.parent.mkdir(parents=True, exist_ok=True)
    fg.save(fg_path)

    values = Path("android/app/src/main/res/values/orvix_colors.xml")
    values.write_text(
        "<resources>\n"
        '  <color name="orvix_icon_background">#050806</color>\n'
        "</resources>\n"
    )

    anydpi = Path("android/app/src/main/res/mipmap-anydpi-v26")
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive_xml = (
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '  <background android:drawable="@color/orvix_icon_background"/>\n'
        '  <foreground android:drawable="@drawable/orvix_foreground"/>\n'
        "</adaptive-icon>\n"
    )
    (anydpi / "ic_launcher.xml").write_text(adaptive_xml)
    (anydpi / "ic_launcher_round.xml").write_text(adaptive_xml)

    for launch in (
        Path("android/app/src/main/res/drawable/launch_background.xml"),
        Path("android/app/src/main/res/drawable-v21/launch_background.xml"),
    ):
        if launch.exists():
            launch.write_text(
                launch.read_text().replace(
                    "@android:color/white",
                    "@color/orvix_icon_background",
                )
            )

    v31 = Path("android/app/src/main/res/values-v31/styles.xml")
    v31.parent.mkdir(parents=True, exist_ok=True)
    v31.write_text(
        "<resources>\n"
        '  <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">\n'
        '    <item name="android:forceDarkAllowed">false</item>\n'
        '    <item name="android:windowSplashScreenBackground">@color/orvix_icon_background</item>\n'
        '    <item name="android:windowSplashScreenAnimatedIcon">@mipmap/ic_launcher</item>\n'
        '    <item name="android:windowSplashScreenIconBackgroundColor">@color/orvix_icon_background</item>\n'
        "  </style>\n"
        '  <style name="NormalTheme" parent="@android:style/Theme.Light.NoTitleBar">\n'
        '    <item name="android:windowLightStatusBar">false</item>\n'
        '    <item name="android:windowBackground">?android:colorBackground</item>\n'
        "  </style>\n"
        "</resources>\n"
    )

    if tv:
        # Android TV expects a 320x180 xhdpi banner with the app name included.
        # Generate it from the canonical square Orvix icon instead of cropping a
        # second source artwork; this keeps launcher branding deterministic and
        # avoids the double-frame/awkward wide icon seen on physical TV launchers.
        banner_path = Path(
            "android/app/src/main/res/drawable-xhdpi/tv_banner.png"
        )
        banner_path.parent.mkdir(parents=True, exist_ok=True)

        banner = Image.new("RGB", (320, 180), (5, 8, 6))
        draw = ImageDraw.Draw(banner)

        # Subtle Orvix green glow on the right without adding a visible frame.
        for x in range(320):
            strength = max(0.0, (x - 120) / 200)
            if strength <= 0:
                continue
            green = int(8 + 20 * strength)
            draw.line((x, 0, x, 179), fill=(5, green, 6))

        icon = ImageOps.fit(
            src,
            (112, 112),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        mask = Image.new("L", (112, 112), 0)
        mask_draw = ImageDraw.Draw(mask)
        mask_draw.rounded_rectangle((0, 0, 111, 111), radius=24, fill=255)
        banner.paste(icon.convert("RGB"), (24, 34), mask)

        font = None
        for candidate in (
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
        ):
            try:
                font = ImageFont.truetype(candidate, 38)
                break
            except OSError:
                pass
        if font is None:
            font = ImageFont.load_default()

        draw.text((153, 61), "ORVIX", font=font, fill=(245, 248, 245))
        draw.rounded_rectangle(
            (154, 111, 286, 116),
            radius=3,
            fill=(185, 255, 69),
        )
        banner.save(banner_path, optimize=True)

    main_activity = Path(
        "android/app/src/main/kotlin/com/orvix/orvix/MainActivity.kt"
    )
    main_activity.parent.mkdir(parents=True, exist_ok=True)
    main_activity.write_text(
        """package com.orvix.orvix

import com.stremio.mobile.server.JniStreamingServerController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "orvix/torrent_engine"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> executor.execute {
                    try {
                        val url = JniStreamingServerController.start(applicationContext)
                        runOnUiThread { result.success(url) }
                    } catch (error: Throwable) {
                        runOnUiThread {
                            result.error(
                                "torrent_engine_start_failed",
                                "${error::class.java.simpleName}: ${error.message ?: error.toString()}",
                                null
                            )
                        }
                    }
                }
                "stop" -> executor.execute {
                    try {
                        JniStreamingServerController.stop()
                        runOnUiThread { result.success(null) }
                    } catch (error: Throwable) {
                        runOnUiThread {
                            result.error(
                                "torrent_engine_stop_failed",
                                error.message ?: error.toString(),
                                null
                            )
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
"""
    )

    controller = Path(
        "android/app/src/main/kotlin/com/stremio/mobile/server/"
        "JniStreamingServerController.kt"
    )
    controller.parent.mkdir(parents=True, exist_ok=True)
    controller.write_text(
        """package com.stremio.mobile.server

import android.content.Context
import java.io.File

class JniStreamingServerController {
    companion object {
        @Volatile
        private var nativeLoaded = false

        @Synchronized
        private fun ensureNativeLoaded() {
            if (nativeLoaded) return
            // libstream_server.so links against libc++_shared.so. Load it
            // explicitly first so Android TV/mobile do not leave the JNI
            // controller in a failed class-initializer state.
            System.loadLibrary("c++_shared")
            System.loadLibrary("stream_server")
            nativeLoaded = true
        }

        @JvmStatic
        private external fun startServerNative(
            context: Context,
            configDir: String,
            cacheDir: String,
            port: Int
        ): String?

        @JvmStatic
        private external fun stopServerNative()

        @JvmStatic
        fun start(context: Context): String? {
            ensureNativeLoaded()
            val configDir = File(context.filesDir, "stream-server")
            val cacheDir = File(context.cacheDir, "stream-server")
            configDir.mkdirs()
            cacheDir.mkdirs()
            return startServerNative(
                context.applicationContext,
                configDir.absolutePath,
                cacheDir.absolutePath,
                11470
            )
        }

        @JvmStatic
        fun stop() {
            if (!nativeLoaded) return
            stopServerNative()
        }
    }
}
"""
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tv", action="store_true")
    args = parser.parse_args()
    patch_android(args.tv)
    print(f"Configured Orvix Android build (tv={args.tv})")
