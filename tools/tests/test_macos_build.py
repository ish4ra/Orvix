"""The macOS app: network access, the bundle checks and the native icon."""

import json
import plistlib
import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import configure_macos_build as macos_build  # noqa: E402
import verify_macos_app as verify  # noqa: E402

CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
PRERELEASE = (ROOT / ".github" / "workflows" / "prerelease.yml").read_text(
    encoding="utf-8"
)
ICONSET = ROOT / "tools" / "macos_icon" / "AppIcon.appiconset"
SANDBOX = "com.apple.security.app-sandbox"


class EntitlementsTest(unittest.TestCase):
    def test_network_access_is_added_and_the_sandbox_is_kept(self):
        updated = macos_build.with_network_access({SANDBOX: True, "other": 1})
        self.assertEqual(
            updated,
            {
                SANDBOX: True,
                "other": 1,
                "com.apple.security.network.client": True,
                "com.apple.security.network.server": True,
            },
        )

    def test_an_unexpected_project_is_refused(self):
        for entitlements in ({}, {SANDBOX: False}):
            with self.assertRaises(ValueError):
                macos_build.with_network_access(entitlements)

    def test_nothing_else_is_granted(self):
        self.assertEqual(
            macos_build.NETWORK_ENTITLEMENTS,
            ("com.apple.security.network.client", "com.apple.security.network.server"),
        )

    def test_every_macos_build_gets_network_access_before_building(self):
        for name, workflow, builds in (("ci.yml", CI, 2), ("prerelease.yml", PRERELEASE, 1)):
            with self.subTest(workflow=name):
                configured = [i for i in _positions(workflow, "tools/configure_macos_build.py\n")]
                built = _positions(workflow, "flutter build macos --release")
                self.assertEqual(len(configured), builds)
                self.assertEqual(len(built), builds)
                for before, after in zip(configured, built):
                    self.assertLess(before, after)


def _positions(text: str, needle: str) -> list[int]:
    found, start = [], 0
    while (index := text.find(needle, start)) >= 0:
        found.append(index)
        start = index + 1
    return found


class PublicBuildTest(unittest.TestCase):
    """The public macOS app keeps its identity and its release file name."""

    def test_public_builds_are_checked_as_the_public_app(self):
        for name, workflow in (("ci.yml", CI), ("prerelease.yml", PRERELEASE)):
            with self.subTest(workflow=name):
                self.assertIn("--bundle-id com.orvix.orvix --name Orvix \\\n", workflow)
                self.assertIn(
                    "--icon-set tools/macos_icon/AppIcon.appiconset",
                    workflow,
                )
        self.assertIn("Orvix-v${{ needs.metadata.outputs.version }}-macOS.zip", PRERELEASE)

    def test_public_builds_stay_universal(self):
        for workflow in (CI, PRERELEASE):
            self.assertIn("--require-arch arm64 --require-arch x86_64", workflow)
            self.assertNotIn("--no-universal", workflow)
            self.assertNotIn("ONLY_ACTIVE_ARCH", workflow)


class BundleCheckTest(unittest.TestCase):
    def test_only_system_and_bundled_dependencies_are_accepted(self):
        output = "\n".join(
            [
                "/path/App.framework/App:",
                "\t@rpath/App.framework/Versions/A/App (compatibility version 0.0.0)",
                "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1)",
                "\t/System/Library/Frameworks/AppKit.framework/AppKit (compatibility version 45.0.0)",
                "\t@executable_path/../Frameworks/libx.dylib (compatibility version 1.0.0)",
                "\t/opt/homebrew/lib/libssl.3.dylib (compatibility version 3.0.0)",
                "\t/Users/runner/work/lib/libfoo.dylib (compatibility version 1.0.0)",
            ]
        )
        self.assertEqual(
            verify.external_dependencies(output),
            ["/opt/homebrew/lib/libssl.3.dylib", "/Users/runner/work/lib/libfoo.dylib"],
        )

    def test_universal_binaries_list_themselves_once_per_architecture(self):
        output = "\n".join(
            [
                "build/Orvix.app/Contents/MacOS/Orvix (architecture x86_64):",
                "\t@rpath/FlutterMacOS.framework/Versions/A/FlutterMacOS (compatibility version 1.0.0)",
                "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1)",
                "build/Orvix.app/Contents/MacOS/Orvix (architecture arm64):",
                "\t@rpath/FlutterMacOS.framework/Versions/A/FlutterMacOS (compatibility version 1.0.0)",
                "\t/opt/homebrew/lib/libx.dylib (compatibility version 1.0.0)",
                "\t/opt/homebrew/lib/libx.dylib (compatibility version 1.0.0)",
            ]
        )
        self.assertEqual(verify.external_dependencies(output), ["/opt/homebrew/lib/libx.dylib"])

    def test_missing_architectures(self):
        self.assertEqual(verify.missing_architectures(["x86_64", "arm64"], ["arm64", "x86_64"]), [])
        self.assertEqual(verify.missing_architectures(["x86_64"], ["arm64", "x86_64"]), ["arm64"])

    def test_entitlements_are_read_from_codesign_output(self):
        blob = b"junk" + plistlib.dumps({SANDBOX: True})
        self.assertEqual(verify.parse_entitlements(blob), {SANDBOX: True})
        self.assertEqual(verify.parse_entitlements(b""), {})
        self.assertEqual(verify.parse_entitlements(b"<?xml not a plist"), {})

    def test_secret_values_are_never_printed(self):
        source = (ROOT / "tools" / "verify_macos_app.py").read_text(encoding="utf-8")
        self.assertIn('wanted.append((f"the value of {variable}", value))', source)
        self.assertIn("say(f\"  contains {label}:", source)


def png_header(path: Path) -> tuple[int, int, int, int]:
    """Width, height, bit depth and colour type of a PNG."""
    data = path.read_bytes()[:26]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError(f"{path.name} is not a PNG")
    width, height, depth, colour = struct.unpack(">IIBB", data[16:26])
    return width, height, depth, colour


class IconTest(unittest.TestCase):
    def test_the_icon_set_covers_every_macos_slot(self):
        contents = json.loads((ICONSET / "Contents.json").read_text(encoding="utf-8"))
        slots = {(image["size"], image["scale"]) for image in contents["images"]}
        self.assertEqual(
            slots,
            {(f"{points}x{points}", scale) for points in (16, 32, 128, 256, 512) for scale in ("1x", "2x")},
        )
        for image in contents["images"]:
            self.assertEqual(image["idiom"], "mac")
            points = int(image["size"].split("x")[0])
            pixels = points * int(image["scale"][0])
            width, height, depth, colour = png_header(ICONSET / image["filename"])
            # 8-bit RGBA: the area outside the icon shape is transparent.
            self.assertEqual((width, height, depth, colour), (pixels, pixels, 8, 6), image["filename"])

    def test_previews_exist_at_the_reviewed_sizes(self):
        previews = ROOT / "docs" / "branding" / "macos-icon"
        for size in (1024, 512, 256, 128, 32):
            width, height, _, colour = png_header(previews / f"orvix-macos-icon-{size}.png")
            self.assertEqual((width, height, colour), (size, size, 6))

    def test_the_macos_icon_is_macos_only(self):
        branding = (ROOT / "tools" / "generate_desktop_branding.py").read_text(encoding="utf-8")
        macos = branding[branding.index("def generate_macos") : branding.index("def main")]
        windows = branding[branding.index("def main") :]
        self.assertIn("MACOS_ICONSET", macos)
        self.assertNotIn("MACOS_ICONSET", windows)
        self.assertNotIn("image.resize", macos)
        generator = (ROOT / "tools" / "generate_macos_icon.py").read_text(encoding="utf-8")
        # The generator reads the shared artwork and writes only macOS files.
        self.assertNotIn("SOURCE.write", generator)
        for written in ("ICONSET /", "PREVIEWS /"):
            self.assertIn(written, generator)
        self.assertNotIn("windows", generator.lower().replace("windows and ios", ""))

    def test_the_corners_are_transparent_and_the_body_is_opaque(self):
        try:
            from PIL import Image
        except ImportError:
            self.skipTest("Pillow is not installed")
        icon = Image.open(ICONSET / "app_icon_1024.png").convert("RGBA")
        for corner in ((0, 0), (1023, 0), (0, 1023), (1023, 1023), (512, 40)):
            self.assertEqual(icon.getpixel(corner)[3], 0, corner)
        for inside in ((512, 110), (110, 512), (512, 512), (900, 512)):
            self.assertEqual(icon.getpixel(inside)[3], 255, inside)
        # Brand lime at the heart of the O, brand dark on the body.
        red, green, blue, _ = icon.getpixel((330, 512))
        self.assertTrue(green > 200 and green > red > blue, (red, green, blue))
        red, green, blue, _ = icon.getpixel((512, 880))
        self.assertTrue(max(red, green, blue) < 24, (red, green, blue))


if __name__ == "__main__":
    unittest.main()
