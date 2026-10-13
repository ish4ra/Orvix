import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class CameraPermissionBridgeTest(unittest.TestCase):
    """The phone's QR scanner and the Android activity agree on the channel."""

    def setUp(self):
        self.kotlin = (ROOT / "tools/android/OrvixCameraPermission.kt").read_text()
        self.dart = (ROOT / "lib/services/camera_permission_service.dart").read_text()
        self.configure = (ROOT / "tools/configure_android_build.py").read_text()

    def test_channel_and_methods_match(self):
        channel = '"orvix/camera_permission"'
        self.assertIn(channel, self.kotlin)
        self.assertIn("'orvix/camera_permission'", self.dart)
        for method in ("status", "request", "openSettings"):
            self.assertIn(f'"{method}" ->', self.kotlin)
            self.assertIn(f"'{method}'", self.dart)

    def test_every_reported_state_is_understood(self):
        reported = set(re.findall(r'-> "([a-zA-Z]+)"', self.kotlin))
        self.assertEqual(
            reported,
            {"noCamera", "granted", "notRequested", "denied", "permanentlyDenied"},
        )
        for state in reported:
            self.assertIn(f"'{state}' => CameraAccess.", self.dart)

    def test_activity_registers_the_channel_and_forwards_results(self):
        self.assertIn("OrvixCameraPermission.kt", self.configure)
        self.assertIn("cameraPermission = OrvixCameraPermissionChannel(", self.configure)
        self.assertIn(
            "super.onRequestPermissionsResult(requestCode, permissions, grantResults)",
            self.configure,
        )
        self.assertIn("cameraPermission?.onRequestPermissionsResult(requestCode)", self.configure)
        # mobile_scanner uses 0x0786; ours must differ and fit in 16 bits.
        code = int(re.search(r"REQUEST_CODE = (0x[0-9A-Fa-f]+)", self.kotlin).group(1), 16)
        self.assertNotEqual(code, 0x0786)
        self.assertLess(code, 1 << 16)

    def test_no_new_permission_is_declared(self):
        # The camera permission is declared once, by the existing mobile
        # compatibility step; this bridge only reads and requests it.
        self.assertNotIn("uses-permission", self.kotlin)


if __name__ == "__main__":
    unittest.main()
