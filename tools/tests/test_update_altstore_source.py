import contextlib
import importlib.util
import io
import json
import plistlib
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "update_altstore_source",
    ROOT / "tools" / "update_altstore_source.py",
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

RELEASE = "0.7.9-beta.64"
DOWNLOAD_URL = (
    "https://github.com/ish4ra/Orvix/releases/download/"
    "v0.7.9-beta.64/Orvix-v0.7.9-beta.64-iOS.ipa"
)


class IosVersionTest(unittest.TestCase):
    def test_prerelease_maps_to_three_component_marketing_version(self):
        self.assertEqual(MODULE.ios_marketing_version("0.7.9-beta.64"), "0.7.9")
        self.assertEqual(MODULE.ios_marketing_version("0.7.9-beta.64+4209"), "0.7.9")

    def test_beta_suffix_changes_do_not_change_marketing_version(self):
        for release in (
            "0.7.9",
            "0.7.9-beta.1",
            "0.7.9-beta.63",
            "0.7.9-beta.65",
            "0.7.9-beta.100",
            "0.7.9-rc.2",
            "0.7.9-beta.65+4210",
        ):
            with self.subTest(release=release):
                version = MODULE.ios_marketing_version(release)
                self.assertEqual(version, "0.7.9")
                self.assertEqual(len(version.split(".")), 3)

    def test_rejects_versions_that_are_not_major_minor_patch(self):
        for release in ("0.7", "0.7.9.64", "v0.7.9-beta.64", "0.07.9", "", "beta"):
            with self.subTest(release=release):
                with self.assertRaises(ValueError):
                    MODULE.ios_marketing_version(release)

    def test_build_version_is_the_app_build_number(self):
        self.assertEqual(MODULE.ios_build_version("4209"), "4209")
        for build in ("", "0", "0420", "4209.1", "beta.64", "-1"):
            with self.subTest(build=build):
                with self.assertRaises(ValueError):
                    MODULE.ios_build_version(build)

    def test_ipa_builder_uses_shared_version_helpers(self):
        script = (ROOT / "tools" / "build_ios_ipa.sh").read_text(encoding="utf-8")
        self.assertIn("ios_marketing_version", script)
        self.assertIn("ios_build_version", script)
        self.assertNotIn("re.findall", script)


class UpdateAltStoreSourceTest(unittest.TestCase):
    def _write_ipa(
        self,
        root: Path,
        *,
        signed: bool = False,
        version: str = "0.7.9",
        build: str = "4209",
    ) -> Path:
        ipa = root / f"Orvix-v{RELEASE}-iOS.ipa"
        info = {
            "CFBundleIdentifier": "com.orvix.orvix",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "MinimumOSVersion": "15.5",
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

    def _run_main(self, root: Path, ipa: Path, source: Path, *extra: str) -> int:
        notes = root / "notes.md"
        notes.write_text("iOS sideload build\n", encoding="utf-8")
        argv = [
            "update_altstore_source.py",
            "--source", str(source),
            "--ipa", str(ipa),
            "--release-notes", str(notes),
            "--release-version", RELEASE,
            "--release-date", "2026-10-09T08:00:00Z",
            "--download-url", DOWNLOAD_URL,
            *extra,
        ]
        with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            return MODULE.main()

    def test_reads_unsigned_ipa_and_writes_apple_compatible_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root)
            source_path = self._write_source(root)

            app_info, privacy = MODULE.read_ipa(ipa)
            self.assertEqual(app_info["CFBundleIdentifier"], "com.orvix.orvix")
            self.assertEqual(privacy["NSCameraUsageDescription"], "Scan a QR code.")

            self.assertEqual(
                self._run_main(root, ipa, source_path, "--build-version", "4209"),
                0,
            )

            updated = json.loads(source_path.read_text(encoding="utf-8"))
            app = updated["apps"][0]
            version = app["versions"][0]
            self.assertEqual(version["version"], "0.7.9")
            self.assertEqual(version["buildVersion"], "4209")
            self.assertEqual(version["marketingVersion"], RELEASE)
            self.assertEqual(version["downloadURL"], DOWNLOAD_URL)
            self.assertEqual(version["minOSVersion"], "15.5")
            self.assertEqual(version["size"], ipa.stat().st_size)
            self.assertEqual(len(version["sha256"]), 64)
            self.assertEqual(
                app["appPermissions"]["privacy"]["NSCameraUsageDescription"],
                "Scan a QR code.",
            )

    def test_rejects_four_component_marketing_version_in_ipa(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root, version="0.7.9.64")
            source_path = self._write_source(root)
            with self.assertRaisesRegex(ValueError, "does not match expected iOS version"):
                self._run_main(root, ipa, source_path)

    def test_rejects_unexpected_build_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root, build="4208")
            source_path = self._write_source(root)
            with self.assertRaisesRegex(ValueError, "build version 4208"):
                self._run_main(root, ipa, source_path, "--build-version", "4209")

    def test_unsigned_ipa_is_accepted_and_signed_ipa_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            unsigned = self._write_ipa(root)
            info, _ = MODULE.read_ipa(unsigned)
            self.assertEqual(info["CFBundleVersion"], "4209")
            signed = self._write_ipa(root, signed=True)
            with self.assertRaisesRegex(ValueError, "must be unsigned"):
                MODULE.read_ipa(signed)

    def test_presigned_embedded_framework_does_not_count_as_signed_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ipa = self._write_ipa(root)
            with zipfile.ZipFile(ipa, "a") as archive:
                archive.writestr(
                    "Payload/Orvix.app/Frameworks/Flutter.framework/"
                    "_CodeSignature/CodeResources",
                    b"vendor-signed",
                )
            info, _ = MODULE.read_ipa(ipa)
            self.assertEqual(info["CFBundleIdentifier"], "com.orvix.orvix")

            with zipfile.ZipFile(ipa, "a") as archive:
                archive.writestr("Payload/Orvix.app/embedded.mobileprovision", b"p")
            with self.assertRaisesRegex(ValueError, "must be unsigned"):
                MODULE.read_ipa(ipa)

    def test_betas_sharing_a_marketing_version_are_distinguished_by_build(self):
        app = {"versions": []}
        beta64 = {"version": "0.7.9", "buildVersion": "4209", "marketingVersion": RELEASE}
        beta65 = {
            "version": "0.7.9",
            "buildVersion": "4210",
            "marketingVersion": "0.7.9-beta.65",
        }
        MODULE.update_versions(app, dict(beta64))
        MODULE.update_versions(app, dict(beta65))
        self.assertEqual(app["versions"], [beta65, beta64])

    def test_replacing_same_version_build_is_idempotent(self):
        app = {"versions": []}
        entry = {"version": "0.7.9", "buildVersion": "4209"}
        MODULE.update_versions(app, dict(entry))
        MODULE.update_versions(app, dict(entry))
        self.assertEqual(app["versions"], [entry])


if __name__ == "__main__":
    unittest.main()
