import io
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import check_android_update_path as u  # noqa: E402

ORVIX_CERT = "ab" * 32
OTHER_CERT = "cd" * 32


class UpdatePathTest(unittest.TestCase):
    """Runs the gate with stub SDK tools that report per-APK canned results."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.tools = self.dir / "build-tools"
        self.tools.mkdir()
        self._stub(
            "apksigner",
            'apk="${@: -1}"\n'
            "printf 'Verifies\\n'\n"
            "printf 'Verified using v2 scheme (APK Signature Scheme v2): true\\n'\n"
            "printf 'Number of signers: 1\\n'\n"
            'printf "Signer #1 certificate SHA-256 digest: %s\\n" "$(cat "$apk.cert")"',
        )
        self._stub("aapt2", 'apk="${@: -1}"\ncat "$apk.badging"')

    def tearDown(self):
        self.tmp.cleanup()

    def _stub(self, name, body):
        path = self.tools / name
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _apk(self, name, version_code, version_name, cert=ORVIX_CERT,
             package="com.orvix.orvix"):
        apk = self.dir / name
        apk.write_bytes(b"PK\x03\x04 stub apk")
        Path(f"{apk}.cert").write_text(cert)
        Path(f"{apk}.badging").write_text(
            f"package: name='{package}' versionCode='{version_code}' "
            f"versionName='{version_name}' platformBuildVersionName='16'\n"
            "sdkVersion:'24'\ntargetSdkVersion:'36'\n"
        )
        return str(apk)

    def _check(self, previous, *apks):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = u.main(["--build-tools", str(self.tools), "--previous", previous, *apks])
        return code, out.getvalue() + err.getvalue()

    def _beta64(self, name="beta64.apk"):
        # Every v0.7.9-beta.64 Android APK was published with versionCode 4209.
        return self._apk(name, 4209, "0.7.9-beta.64")

    def test_beta65_universal_and_abi_apks_update_beta64(self):
        code, output = self._check(
            self._beta64(),
            self._apk("mobile.apk", 4210, "0.7.9-beta.65"),
            self._apk("arm64.apk", 4210, "0.7.9-beta.65"),
            self._apk("armv7.apk", 4210, "0.7.9-beta.65"),
            self._apk("x86_64.apk", 4210, "0.7.9-beta.65"),
        )
        self.assertEqual(code, 0, output)
        self.assertIn("update-path check passed", output)

    def test_beta65_tv_apk_updates_beta64_tv(self):
        code, output = self._check(
            self._beta64("tv64.apk"), self._apk("tv65.apk", 4210, "0.7.9-beta.65")
        )
        self.assertEqual(code, 0, output)

    def test_same_versioncode_is_rejected(self):
        code, output = self._check(
            self._beta64(), self._apk("mobile.apk", 4209, "0.7.9-beta.65")
        )
        self.assertEqual(code, 1)
        self.assertIn("versionCode 4209 is not above published 4209", output)

    def test_stale_develop_build_number_is_rejected(self):
        # develop carried 0.7.9-beta.59+204 while beta.60-64 shipped from
        # release branches; building from it unchanged would be a downgrade.
        code, output = self._check(
            self._beta64(), self._apk("mobile.apk", 204, "0.7.9-beta.59")
        )
        self.assertEqual(code, 1)
        self.assertIn("versionCode 204 is not above published 4209", output)

    def test_one_bad_variant_fails_the_release(self):
        code, output = self._check(
            self._beta64(),
            self._apk("mobile.apk", 4210, "0.7.9-beta.65"),
            self._apk("x86_64.apk", 4209, "0.7.9-beta.65"),
        )
        self.assertEqual(code, 1)
        self.assertIn("x86_64.apk: versionCode 4209", output)
        self.assertNotIn("mobile.apk: versionCode", output)

    def test_changed_signing_certificate_is_rejected(self):
        code, output = self._check(
            self._beta64(),
            self._apk("mobile.apk", 4210, "0.7.9-beta.65", cert=OTHER_CERT),
        )
        self.assertEqual(code, 1)
        self.assertIn("Android will refuse the update", output)

    def test_changed_package_is_rejected(self):
        code, output = self._check(
            self._beta64(),
            self._apk("mobile.apk", 4210, "0.7.9-beta.65", package="com.orvix.tv"),
        )
        self.assertEqual(code, 1)
        self.assertIn("differs from published 'com.orvix.orvix'", output)

    def test_unreadable_published_apk_fails(self):
        missing = str(self.dir / "missing.apk")
        code, output = self._check(missing, self._apk("mobile.apk", 4210, "0.7.9-beta.65"))
        self.assertEqual(code, 1)
        self.assertIn("cannot read the published APK", output)


if __name__ == "__main__":
    unittest.main()
