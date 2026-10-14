import struct
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

BANNER = ROOT / "assets/branding/tv_launcher_banner.png"


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:24]
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise AssertionError(f"{path} is not a PNG")
    return struct.unpack(">II", data[16:24])


class TvLauncherBannerTest(unittest.TestCase):
    def test_banner_artwork_is_full_bleed_16_by_9(self):
        width, height = png_size(BANNER)
        self.assertEqual(width * 9, height * 16)
        # At least 4x the 320x180 xhdpi banner, so scaling only sharpens it.
        self.assertGreaterEqual(width, 1280)

    def test_tv_build_scales_the_banner_without_letterboxing(self):
        script = (ROOT / "tools/configure_android_build.py").read_text()
        self.assertIn("assets/branding/tv_launcher_banner.png", script)
        self.assertIn('android:banner="@drawable/tv_banner"', script)
        self.assertIn("resize((320, 180)", script)
        # The old path pasted a 2.5:1 card onto a dark 16:9 canvas.
        self.assertNotIn("thumbnail((320, 180)", script)
        self.assertNotIn('Image.open("assets/branding/tv_banner.png")', script)

    def test_generator_reproduces_the_committed_banner(self):
        try:
            from PIL import Image, ImageChops
        except ImportError:
            self.skipTest("Pillow is not installed")
        import make_tv_banner

        import os

        cwd = os.getcwd()
        os.chdir(ROOT)
        try:
            built = make_tv_banner.build()
        finally:
            os.chdir(cwd)
        committed = Image.open(BANNER).convert("RGB")
        self.assertEqual(built.size, committed.size)
        diff = ImageChops.difference(built, committed).getbbox()
        self.assertIsNone(diff, "Run python3 tools/make_tv_banner.py")


if __name__ == "__main__":
    unittest.main()
