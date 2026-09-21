import argparse
from collections import deque
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def _clean_launcher_artwork(source: Image.Image) -> Image.Image:
    """Remove only the dark background connected to the outer image edge."""
    image = source.convert("RGBA").copy()
    width, height = image.size
    pixels = image.load()
    visited = bytearray(width * height)
    queue = deque()

    def is_outer_dark(x: int, y: int) -> bool:
        r, g, b, a = pixels[x, y]
        if a == 0:
            return True
        return r <= 46 and g <= 46 and b <= 46

    def push(x: int, y: int) -> None:
        index = y * width + x
        if visited[index] or not is_outer_dark(x, y):
            return
        visited[index] = 1
        queue.append((x, y))

    for x in range(width):
        push(x, 0)
        push(x, height - 1)
    for y in range(height):
        push(0, y)
        push(width - 1, y)

    while queue:
        x, y = queue.popleft()
        r, g, b, _ = pixels[x, y]
        pixels[x, y] = (r, g, b, 0)
        if x > 0:
            push(x - 1, y)
        if x + 1 < width:
            push(x + 1, y)
        if y > 0:
            push(x, y - 1)
        if y + 1 < height:
            push(x, y + 1)

    bbox = image.getbbox()
    return image.crop(bbox) if bbox else image


def _center_artwork(source: Image.Image, size: int, fill_ratio: float) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    art = source.copy()
    target = max(1, int(size * fill_ratio))
    art.thumbnail((target, target), Image.Resampling.LANCZOS)
    canvas.alpha_composite(
        art,
        ((size - art.width) // 2, (size - art.height) // 2),
    )
    return canvas


def patch_android(tv: bool) -> None:
    manifest = Path("android/app/src/main/AndroidManifest.xml")
    text = manifest.read_text()

    if "android.permission.INTERNET" not in text:
        text = text.replace(
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">',
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <uses-permission android:name="android.permission.INTERNET" />\n'
            '    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />\n'
            '    <uses-permission android:name="android.permission.WAKE_LOCK" />\n'
            '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />',
        )

    if "android.permission.REQUEST_INSTALL_PACKAGES" not in text:
        text = text.replace(
            "<application",
            '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />\n<application',
            1,
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

    if "androidx.core.content.FileProvider" not in text:
        text = text.replace(
            "</application>",
            '        <provider\n'
            '            android:name="androidx.core.content.FileProvider"\n'
            '            android:authorities="${applicationId}.fileprovider"\n'
            '            android:exported="false"\n'
            '            android:grantUriPermissions="true">\n'
            '            <meta-data\n'
            '                android:name="android.support.FILE_PROVIDER_PATHS"\n'
            '                android:resource="@xml/orvix_file_paths" />\n'
            '        </provider>\n'
            '    </application>',
            1,
        )

    file_paths = Path("android/app/src/main/res/xml/orvix_file_paths.xml")
    file_paths.parent.mkdir(parents=True, exist_ok=True)
    file_paths.write_text(
        '<paths xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <cache-path name="orvix_updates" path="." />\n'
        '</paths>\n'
    )

    manifest.write_text(text)

    gradle = Path("android/app/build.gradle.kts")
    gradle_text = gradle.read_text()
    gradle_text = gradle_text.replace(
        "minSdk = flutter.minSdkVersion",
        "minSdk = 24",
    )
    aar_dep = 'implementation(files("libs/rustls-platform-verifier-0.1.1.aar"))'
    deps = [aar_dep]
    missing = [dep for dep in deps if dep not in gradle_text]
    if missing:
        gradle_text += "\n\ndependencies {\n" + "".join(
            f"    {dep}\n" for dep in missing
        ) + "}\n"
    gradle.write_text(gradle_text)

    raw_src = Image.open("assets/branding/orvix_icon.png").convert("RGBA")
    src = _clean_launcher_artwork(raw_src)

    sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in sizes.items():
        out = Path(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        _center_artwork(src, size, .84).save(out)

    fg = _center_artwork(src, 432, .68)
    fg_path = Path("android/app/src/main/res/drawable-nodpi/orvix_foreground.png")
    fg_path.parent.mkdir(parents=True, exist_ok=True)
    fg.save(fg_path)

    values = Path("android/app/src/main/res/values/orvix_colors.xml")
    values.write_text(
        "<resources>\n"
        '  <color name="orvix_icon_background">#00000000</color>\n'
        '  <color name="orvix_splash_background">#050806</color>\n'
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
                    "@color/orvix_splash_background",
                )
            )

    v31 = Path("android/app/src/main/res/values-v31/styles.xml")
    v31.parent.mkdir(parents=True, exist_ok=True)
    v31.write_text(
        "<resources>\n"
        '  <style name="LaunchTheme" parent="@android:style/Theme.Light.NoTitleBar">\n'
        '    <item name="android:forceDarkAllowed">false</item>\n'
        '    <item name="android:windowSplashScreenBackground">@color/orvix_splash_background</item>\n'
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

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.stremio.mobile.server.JniStreamingServerController
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
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
                        val url =
                            JniStreamingServerController.start(applicationContext)
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "orvix/app_update"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("missing_apk", "APK path is missing", null)
                        return@setMethodCallHandler
                    }

                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()
                    ) {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                            Uri.parse("package:$packageName")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(intent)
                        result.success("permission_required")
                        return@setMethodCallHandler
                    }

                    try {
                        val apk = File(path)
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            apk
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(
                                uri,
                                "application/vnd.android.package-archive"
                            )
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success("installer_opened")
                    } catch (error: Throwable) {
                        result.error(
                            "apk_install_failed",
                            error.message ?: error.toString(),
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (isFinishing) {
            try {
                JniStreamingServerController.stop()
            } catch (_: Throwable) {
            }
        }
        super.onDestroy()
    }
}
"""
    ) )

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
