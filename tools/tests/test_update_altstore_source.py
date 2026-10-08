import importlib.util
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "update_altstore_source",
    ROOT / "tools" / "update_altstore_source.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class UpdateAltStoreSourceTest(unittest.TestCase):
    def _write_ipa(self, root: Path, *, signed: bool = False) -> Path:
        ipa = root / "Orvix-v0.7.9-beta.61-iOS.ipa"
        info = {
            "CFBundleIdentifier": "com.orvix.orvix",
            "CFBundleShortVersionString": "0.7.9.61",
            "CFBundleVersion": "205",
            "MinimumOSVersion": "13.0",
            "NSCameraUsageDescription": "Scan a QR code.",
        }
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr(
                "Payload/Orvix.app/Info.plist",
                plistlib.dumps(info),
            )
            archive.writestr("Payload/Orvix.app/Orvix", b"arm64-placeholder")
            if signed:
                archive.writestr(
                    "Payload/Orvix.app/_CodeSignature/CodeResources",
                    b"signed",
                )
        return ipa

    def _write_source(self, root: Path) -> Path:
        source = root / "store.json"
        source.write_text(
            json.dumps(
                {
                    "name": "Orvix",
                    "apps": [
                        {
                            "name": "Orvix",
                            "bundleIdentifier": "com.orvix.orvix",
                            "appPermissions": {
                                "entitlements": [],
                                "privacy": {},
                            },
                            "versions": [],
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        return source

    def test_reads_unsigned_ipa_metadata_and_updates_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root)
            source_path = self._write_source(root)

            source = MODULE.read_source(source_path)
            app_info, privacy = MODULE.read_ipa(ipa)
            self.assertEqual(app_info["CFBundleIdentifier"], "com.orvix.orvix")
            self.assertEqual(privacy["NSCameraUsageDescription"], "Scan a QR code.")

            app = source["apps"][0]
            entry = {
                "version": app_info["CFBundleShortVersionString"],
                "buildVersion": app_info["CFBundleVersion"],
                "date": "2026-10-08T08:00:00Z",
                "localizedDescription": "iOS sideload build",
                "downloadURL": (
                    "https://github.com/ish4ra/Orvix/releases/download/"
                    "v0.7.9-beta.61/Orvix-v0.7.9-beta.61-iOS.ipa"
                ),
                "size": ipa.stat().st_size,
                "sha256": MODULE.sha256(ipa),
                "minOSVersion": app_info["MinimumOSVersion"],
            }
            MODULE.update_versions(app, entry)
            app["appPermissions"]["privacy"] = privacy
            MODULE.write_source(source_path, source)

            updated = json.loads(source_path.read_text(encoding="utf-8"))
            version = updated["apps"][0]["versions"][0]
            self.assertEqual(version["version"], "0.7.9.61")
            self.assertEqual(
                MODULE.ios_marketing_version("0.7.9-beta.61"),
                "0.7.9.61",
            )
            self.assertEqual(version["buildVersion"], "205")
            self.assertEqual(len(version["sha256"]), 64)
            self.assertEqual(
                updated["apps"][0]["appPermissions"]["privacy"][
                    "NSCameraUsageDescription"
                ],
                "Scan a QR code.",
            )

    def test_rejects_signed_ipa(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root, signed=True)
            with self.assertRaisesRegex(ValueError, "must be unsigned"):
                MODULE.read_ipa(ipa)

    def test_replacing_same_version_build_is_idempotent(self):
        app = {"versions": []}
        entry = {
            "version": "0.7.9.61",
            "buildVersion": "205",
        }
        MODULE.update_versions(app, dict(entry))
        MODULE.update_versions(app, dict(entry))
        self.assertEqual(app["versions"], [entry])


if __name__ == "__main__":
    unittest.main()
