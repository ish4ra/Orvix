"""The macOS Free P2P engine must be built, bundled, signed and checked in
every macOS build. An app without it shows ENGINE ERROR for every source."""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import patch_macos_stream_engine as patch  # noqa: E402
import verify_macos_app as verify  # noqa: E402

CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
PRERELEASE = (ROOT / ".github" / "workflows" / "prerelease.yml").read_text(
    encoding="utf-8"
)
BUILD = (ROOT / "tools" / "build_macos_stream_engine.sh").read_text(encoding="utf-8")
BUNDLE = (ROOT / "tools" / "bundle_macos_stream_engine.sh").read_text(encoding="utf-8")
SMOKE = (ROOT / "tools" / "macos_stream_engine_smoke_test.sh").read_text(
    encoding="utf-8"
)
SERVICE = (ROOT / "lib" / "services" / "local_torrent_service.dart").read_text(
    encoding="utf-8"
)

UPSTREAM_MAIN = """mod app {
    fn run_headless_mode(use_tui: bool) -> anyhow::Result<()> {
        let rt = tokio::runtime::Runtime::new()?;
        let mut cfg = stream_server::ServerConfig::binary_default();
        cfg.use_tui = use_tui;
        let _ = rt.block_on(stream_server::run(cfg, rx, None))?;
        Ok(())
    }
}
"""


def job(workflow: str, name: str) -> str:
    match = re.search(
        rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)", workflow, re.S | re.M
    )
    if match is None:
        raise AssertionError(f"job {name} not found")
    return match.group(1)


class PatchTest(unittest.TestCase):
    def test_headless_start_becomes_a_private_loopback_helper(self):
        patched = patch.patch_main(UPSTREAM_MAIN)
        for line in (
            "cfg.setup_ffmpeg = false;",
            "cfg.enable_ssdp_discovery = false;",
            "cfg.enable_background_update_checker = false;",
            'std::env::var("ORVIX_STREAM_SERVER_PORT")',
            "SocketAddr::from(([127, 0, 0, 1], orvix_port))",
            "cfg.https_addr = None;",
            "std::os::unix::process::parent_id()",
        ):
            self.assertIn(line, patched)
        # Nothing but the configuration block changes.
        self.assertTrue(patched.startswith("mod app {\n    fn run_headless_mode"))
        self.assertTrue(patched.endswith(UPSTREAM_MAIN.split("cfg.use_tui = use_tui;\n")[1]))

    def test_unexpected_upstream_code_is_refused(self):
        for text in ("fn main() {}", UPSTREAM_MAIN.replace("binary_default", "other")):
            with self.assertRaises(patch.PatchError):
                patch.patch_main(text)
        with self.assertRaises(patch.PatchError):
            patch.patch_main(patch.patch_main(UPSTREAM_MAIN))

    def test_build_uses_the_commit_the_patch_was_written_for(self):
        self.assertIn(f"STREAM_SERVER_COMMIT={patch.UPSTREAM_COMMIT}", BUILD)
        self.assertIn('if [ "$actual" != "$STREAM_SERVER_COMMIT" ]', BUILD)
        self.assertIn("shasum -a 256 -c -", BUILD)


class BuildTest(unittest.TestCase):
    def test_engine_may_depend_on_macos_only(self):
        self.assertIn("grep -vE '^(/usr/lib/|/System/Library/)'", BUILD)
        self.assertIn("-DOPENSSL_USE_STATIC_LIBS=ON", BUILD)
        self.assertIn("LIBTORRENT_RASTERBAR_STATIC=1", BUILD)
        self.assertIn('if [ "$built" != "$arch" ]', BUILD)

    def test_engine_is_bundled_where_the_app_looks_for_it(self):
        self.assertIn("static const String bundledMacName = 'orvix-stream-server';", SERVICE)
        self.assertIn("Resources'\n              '${Platform.pathSeparator}$bundledMacName'", SERVICE)
        self.assertIn('target="$app/Contents/Resources/orvix-stream-server"', BUNDLE)
        self.assertEqual(verify.STREAM_ENGINE_NAME, "orvix-stream-server")
        self.assertIn('chmod 755 "$target"', BUNDLE)

    def test_bundling_keeps_the_sandbox_and_signs_the_engine_as_its_helper(self):
        self.assertIn('--entitlements "$here/macos_stream_engine.entitlements" "$target"', BUNDLE)
        self.assertIn('codesign --force --sign - --entitlements "$entitlements" "$app"', BUNDLE)
        self.assertNotIn("--deep --sign", BUNDLE)
        self.assertIn("refusing to guess its entitlements", BUNDLE)
        import plistlib

        helper = plistlib.loads(
            (ROOT / "tools" / "macos_stream_engine.entitlements").read_bytes()
        )
        self.assertEqual(helper, verify.STREAM_ENGINE_ENTITLEMENTS)

    def test_smoke_test_covers_start_ports_loopback_and_orphans(self):
        for expectation in (
            "wait_ready 11470",
            "ORVIX_STREAM_SERVER_PORT=11493",
            "Listening on 127.0.0.1 only",
            "the port is free again",
            "Exits with its parent",
        ):
            self.assertIn(expectation, SMOKE)


class VerifyTest(unittest.TestCase):
    GOOD = dict(verify.STREAM_ENGINE_ENTITLEMENTS)

    def problems(self, **changes):
        values = {
            "architectures": ["x86_64", "arm64"],
            "required_architectures": ["arm64", "x86_64"],
            "executable": True,
            "entitlements": self.GOOD,
            "signature_valid": True,
        }
        values.update(changes)
        return verify.stream_engine_problems(**values)

    def test_a_good_engine_has_no_problems(self):
        self.assertEqual(self.problems(), [])

    def test_each_way_the_engine_can_be_unusable_is_reported(self):
        self.assertIn("lacks arm64", self.problems(architectures=["x86_64"])[0])
        self.assertIn("lacks x86_64", self.problems(architectures=["arm64"])[0])
        self.assertIn("not executable", self.problems(executable=False)[0])
        self.assertIn("not validly signed", self.problems(signature_valid=False)[0])
        for entitlements in (
            {},
            {"com.apple.security.app-sandbox": True},
            {**self.GOOD, "com.apple.security.network.client": True},
        ):
            self.assertIn("inherit", self.problems(entitlements=entitlements)[0])


class WorkflowTest(unittest.TestCase):
    def test_both_workflows_build_the_engine_for_both_architectures(self):
        for name, workflow in (("ci.yml", CI), ("prerelease.yml", PRERELEASE)):
            with self.subTest(workflow=name):
                engine = job(workflow, "macos-engine")
                self.assertIn("runner: macos-15\n", engine)
                self.assertIn("runner: macos-15-intel\n", engine)
                steps = [
                    "tools/build_macos_stream_engine.sh",
                    "tools/macos_stream_engine_smoke_test.sh",
                    "tools/macos_sandbox_engine_test.sh",
                    "actions/upload-artifact@v4",
                ]
                positions = [engine.index(step) for step in steps]
                self.assertEqual(positions, sorted(positions))
                # A cached engine is still started before it is used.
                self.assertNotIn("cache-hit", engine.split("Start the engine")[1])

    def test_every_macos_app_gets_the_engine_and_is_refused_without_it(self):
        jobs = (
            (CI, "macos"),
            (CI, "watch-party-test-macos"),
            (PRERELEASE, "macos"),
        )
        for workflow, name in jobs:
            with self.subTest(job=name):
                body = job(workflow, name)
                self.assertIn("macos-engine", body.split("runs-on:")[0])
                steps = [
                    "flutter build macos --release",
                    "pattern: macos-stream-engine-*",
                    "tools/bundle_macos_stream_engine.sh",
                    "macos-stream-engine-arm64/orvix-stream-server",
                    "macos-stream-engine-x86_64/orvix-stream-server",
                    "tools/verify_macos_app.py",
                    "--require-stream-engine",
                ]
                positions = [body.index(step) for step in steps]
                self.assertEqual(positions, sorted(positions))

    def test_the_release_is_packed_only_after_the_engine_check(self):
        macos = job(PRERELEASE, "macos")
        self.assertLess(macos.index("--require-stream-engine"), macos.index("ditto -c -k"))

    def test_the_test_build_engine_goes_into_both_copies(self):
        macos = job(CI, "watch-party-test-macos")
        self.assertLess(
            macos.index("tools/bundle_macos_stream_engine.sh"),
            macos.index("tools/package_macos_test_build.sh"),
        )


if __name__ == "__main__":
    unittest.main()
