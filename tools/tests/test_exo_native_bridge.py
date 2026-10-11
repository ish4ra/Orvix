"""Contract tests between Orvix's Kotlin Media3 bridge and its Dart side.

The Android project is generated in CI, so the Kotlin bridge
(tools/android/OrvixExoPlayer.kt) is only compiled there. These checks run
everywhere and catch the mistakes a compile cannot: a Dart command the
native side ignores, an event Dart never handles, a create argument with a
different name on each side, a URL leaking into diagnostics, or a Kotlin
property used before it is initialised.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = (ROOT / "tools" / "android" / "OrvixExoPlayer.kt").read_text()
CONFIGURE = (ROOT / "tools" / "configure_android_build.py").read_text()
DART = (ROOT / "lib" / "services" / "orvix_exo_player.dart").read_text()


def _session_class(source: str) -> str:
    start = source.index("private class OrvixExoSession(")
    end = source.index("private class PatientLoadErrorPolicy")
    return source[start:end]


class ExoNativeBridgeContractTest(unittest.TestCase):
    def test_channel_name_matches(self):
        self.assertIn('MethodChannel(messenger, "orvix/exo_player")', KOTLIN)
        self.assertIn("MethodChannel('orvix/exo_player')", DART)

    def test_every_dart_command_is_handled_natively(self):
        commands = set(re.findall(r"_command\(\s*'(\w+)'", DART))
        commands |= set(re.findall(r"_backend\.command\([^,]+,\s*'(\w+)'", DART))
        self.assertTrue(commands, "no Dart commands found")
        for command in commands:
            self.assertRegex(
                KOTLIN,
                rf'"{command}"\s*->',
                f"native bridge does not handle '{command}'",
            )

    def test_every_create_argument_is_read_natively(self):
        open_block = DART[DART.index("Future<void> open() async {"):]
        open_block = open_block[: open_block.index("});")]
        keys = set(re.findall(r"'(\w+)':", open_block))
        self.assertTrue({"url", "headers", "startMs", "textDisabled"} <= keys)
        for key in keys:
            self.assertRegex(
                KOTLIN,
                rf'(argument<.+?>\("{key}"\)|number\(call, "{key}"\))',
                f"native create ignores '{key}'",
            )

    def test_every_native_event_is_handled_in_dart(self):
        events = set(re.findall(r'"event" to "(\w+)"', KOTLIN))
        events |= set(re.findall(r'payload\["event"\] = "(\w+)"', KOTLIN))
        self.assertTrue({"state", "video", "tracks", "cues", "error", "diag"} <= events)
        for event in events:
            self.assertIn(f"case '{event}':", DART, f"Dart ignores '{event}' events")

    def test_diagnostics_never_carry_urls_headers_or_hashes(self):
        session = _session_class(KOTLIN)
        # The only use of the URL is handing it to Media3.
        self.assertEqual(
            re.findall(r"\burl\b", session.split("init {", 1)[1].split("fun isPlayingNow", 1)[0]),
            ["url"],
        )
        for forbidden in (
            '"url" to',
            '"uri" to',
            '"headers" to',
            "loadEventInfo.uri",
            "dataSpec.uri",
            "error.message ?: error.errorCodeName) + url",
            "Log.",
            "println(",
        ):
            self.assertNotIn(forbidden, KOTLIN, forbidden)
        # Exceptions are reported by class name and error code, never by
        # message: Media3 messages can carry request details.
        self.assertNotIn("error.message", KOTLIN)
        self.assertIn("error::class.java.simpleName", KOTLIN)

    def test_analytics_listener_exists_before_the_player_is_built(self):
        session = _session_class(KOTLIN)
        self.assertLess(
            session.index("private val analytics = object : AnalyticsListener"),
            session.index("    init {"),
            "Kotlin initialises properties in order; the listener must be "
            "declared before init uses it",
        )
        self.assertIn("player.addAnalyticsListener(analytics)", session)
        self.assertIn("player.removeAnalyticsListener(analytics)", session)

    def test_screen_stays_awake_while_playing(self):
        self.assertIn("FLAG_KEEP_SCREEN_ON", KOTLIN)
        self.assertIn("window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)", KOTLIN)
        # MainActivity hands the activity to the bridge so it can reach the window.
        self.assertRegex(
            CONFIGURE,
            r"OrvixExoPlayerChannel\(\s*applicationContext,\s*flutterEngine\.dartExecutor\.binaryMessenger,\s*flutterEngine\.renderer,\s*this\s*\)",
        )
        self.assertIn("exoPlayer?.releaseAll()", CONFIGURE)

    def test_media3_version_is_unchanged(self):
        self.assertIn('implementation("androidx.media3:media3-exoplayer:1.9.2")', CONFIGURE)

    def test_patient_policy_and_subtitle_offset_are_kept(self):
        self.assertIn("PatientLoadErrorPolicy() else DefaultLoadErrorHandlingPolicy()", KOTLIN)
        self.assertIn("SubtitleOffsetRenderer(out[index], offset)", KOTLIN)
        self.assertIn("setEnableDecoderFallback(true)", KOTLIN)

    def test_surface_follows_flutter_lifecycle(self):
        session = _session_class(KOTLIN)
        self.assertIn("override fun onSurfaceAvailable()", session)
        self.assertIn("override fun onSurfaceCleanup()", session)
        self.assertIn("producer.release()", session)


if __name__ == "__main__":
    unittest.main()
