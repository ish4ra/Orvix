import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


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

    # v0.7.7 uses a tightly cropped 1024px canonical icon.  Keep the complete
    # designed rounded-square edge for raster launcher icons; do not reintroduce
    # the black source-image margin that surrounded the original concept art.
    source = Image.open("assets/branding/orvix_logo.png").convert("RGBA")
    if source.size != (1024, 1024):
        source = source.resize((1024, 1024), Image.Resampling.LANCZOS)
    for x, y in ((0, 0), (1023, 0), (0, 1023), (1023, 1023)):
        if source.getpixel((x, y))[3] != 0:
            raise SystemExit("Orvix launcher icon outer corners must be transparent.")

    # Keep in-app branding distinct from the launcher: only the lime O mark,
    # with the surrounding rounded-square/background fully transparent.
    width, height = source.size
    cx, cy = width / 2, height / 2
    radius_sq = (min(width, height) * 0.36) ** 2
    cleaned = []
    for index, (r, g, b, a) in enumerate(source.getdata()):
        x = index % width
        y = index // width
        keep = (
            (x - cx) ** 2 + (y - cy) ** 2 < radius_sq
            and g > 45
            and g > b * 1.15
            and g > r * 0.90
        )
        cleaned.append((r, g, b, a if keep else 0))
    mark = Image.new("RGBA", source.size)
    mark.putdata(cleaned)
    mark.save(
        "assets/branding/orvix_logo.webp",
        format="WEBP",
        quality=95,
        method=6,
    )

    sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for density, size in sizes.items():
        out = Path(f"android/app/src/main/res/mipmap-{density}/ic_launcher.png")
        out.parent.mkdir(parents=True, exist_ok=True)
        launcher = ImageOps.fit(
            source,
            (size, size),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        )
        launcher.save(out, format="PNG", optimize=True)

    # Adaptive icons get breathing room inside the OS mask while still using
    # the exact same high-resolution artwork.
    # Preserve the exact supplied icon for adaptive foreground too.
    fg = source.resize((432, 432), Image.Resampling.LANCZOS)
    fg_path = Path("android/app/src/main/res/drawable-nodpi/orvix_foreground.png")
    fg_path.parent.mkdir(parents=True, exist_ok=True)
    fg.save(fg_path)

    values = Path("android/app/src/main/res/values/orvix_colors.xml")
    values.write_text(
        "<resources>\n"
        '  <color name="orvix_icon_background">#050806</color>\n'
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
        # Use the supplied wide TV artwork directly. Preserve its aspect ratio
        # and fit it inside Android TV's 320x180 banner without stretching.
        banner_path = Path(
            "android/app/src/main/res/drawable-xhdpi/tv_banner.png"
        )
        banner_path.parent.mkdir(parents=True, exist_ok=True)
        supplied_banner = Image.open("assets/branding/tv_banner.png").convert("RGBA")
        banner = Image.new("RGBA", (320, 180), (5, 8, 6, 255))
        fitted = supplied_banner.copy()
        fitted.thumbnail((320, 180), Image.Resampling.LANCZOS)
        banner.alpha_composite(
            fitted,
            ((320 - fitted.width) // 2, (180 - fitted.height) // 2),
        )
        banner.convert("RGB").save(banner_path, format="PNG", optimize=True)

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
        @Volatile
        private var serverRunning = false

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
            val url = startServerNative(
                context.applicationContext,
                configDir.absolutePath,
                cacheDir.absolutePath,
                11470
            )
            serverRunning = true
            return url
        }

        @JvmStatic
        @Synchronized
        fun stop() {
            if (!nativeLoaded || !serverRunning) return
            serverRunning = false
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
