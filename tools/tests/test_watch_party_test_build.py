"""Private Watch Party test builds must stay private and isolated.

They may only be built on request, only against a separate Supabase project,
only as workflow artifacts, and only with their own app identity. Normal CI
and release builds must not be able to pick any of that up.
"""

import base64
import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import configure_test_build_identity as identity  # noqa: E402
import write_test_build_defines as defines  # noqa: E402

CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
PRERELEASE = (ROOT / ".github" / "workflows" / "prerelease.yml").read_text(
    encoding="utf-8"
)

PRODUCTION = ("https://productionproject00.supabase.co", "sb_publishable_production_key")
TEST_REF = "abcdefghijklmnopqrst"
TEST_URL = f"https://{TEST_REF}.supabase.co"
TEST_KEY = "sb_publishable_test_key_0123456789"


def legacy_key(role: str, ref: str) -> str:
    def part(value: dict) -> str:
        raw = base64.urlsafe_b64encode(json.dumps(value).encode()).decode()
        return raw.rstrip("=")

    return f"{part({'alg': 'HS256'})}.{part({'role': role, 'ref': ref})}.signature"


class TestBuildDefinesTest(unittest.TestCase):
    def build(self, url=TEST_URL, key=TEST_KEY):
        return defines.test_build_defines(url, key, PRODUCTION)

    def test_valid_configuration_turns_on_the_test_build_and_watch_party(self):
        self.assertEqual(
            self.build(url=TEST_URL + "/"),
            {
                "ORVIX_TEST_BUILD": "true",
                "ORVIX_WATCH_PARTY": "true",
                "ORVIX_SUPABASE_URL": TEST_URL,
                "ORVIX_SUPABASE_PUBLISHABLE_KEY": TEST_KEY,
            },
        )
        self.assertEqual(
            self.build(key=legacy_key("anon", TEST_REF))["ORVIX_TEST_BUILD"], "true"
        )

    def test_unsafe_configuration_is_refused_without_echoing_values(self):
        cases = {
            "missing url": ("", TEST_KEY),
            "missing key": (TEST_URL, ""),
            "production project": (PRODUCTION[0], TEST_KEY),
            "production key": (TEST_URL, PRODUCTION[1]),
            "plain http": (TEST_URL.replace("https", "http"), TEST_KEY),
            "other host": ("https://example.com", TEST_KEY),
            "secret key": (TEST_URL, "sb_secret_abcdefghijklmnop"),
            "service role": (TEST_URL, legacy_key("service_role", TEST_REF)),
            "other project's key": (TEST_URL, legacy_key("anon", "z" * 20)),
            "not a key": (TEST_URL, "hello"),
        }
        for name, (url, key) in cases.items():
            with self.subTest(name):
                with self.assertRaises(defines.ConfigError) as caught:
                    self.build(url, key)
                message = str(caught.exception)
                for value in (url, key):
                    if value:
                        self.assertNotIn(value, message)

    def test_production_backend_is_read_from_the_app(self):
        url, key = defines.production_backend()
        self.assertIsNotNone(defines.project_ref(url))
        self.assertTrue(key)
        with self.assertRaises(defines.ConfigError):
            defines.test_build_defines(url, TEST_KEY, (url, key))

    def test_script_never_prints_the_values(self):
        source = (ROOT / "tools" / "write_test_build_defines.py").read_text(
            encoding="utf-8"
        )
        for line in source.splitlines():
            if "print(" in line:
                self.assertNotIn("defines", line.split("print(", 1)[1].split('"')[0])
        self.assertIn("values not shown", source)


class TestBuildIdentityTest(unittest.TestCase):
    def test_android_gets_its_own_application_id_and_name(self):
        gradle = 'namespace = "com.orvix.orvix"\n applicationId = "com.orvix.orvix"\n'
        changed = identity.android_gradle(gradle)
        self.assertIn('applicationId = "com.orvix.orvix.wptest"', changed)
        self.assertIn('namespace = "com.orvix.orvix"\n', changed)
        self.assertIn(
            'android:label="Orvix Test"',
            identity.android_manifest('<application android:label="Orvix">'),
        )

    def test_unexpected_files_fail_instead_of_keeping_the_public_identity(self):
        with self.assertRaises(identity.IdentityError):
            identity.android_gradle('applicationId = "com.other.app"')
        with self.assertRaises(identity.IdentityError):
            identity.android_manifest('android:label="orvix"')
        with self.assertRaises(identity.IdentityError):
            identity.windows_resources("nothing")

    def test_committed_windows_resources_can_be_given_the_test_identity(self):
        resources = (ROOT / "windows" / "runner" / "Runner.rc").read_text(
            encoding="utf-8"
        )
        changed = identity.windows_resources(resources)
        self.assertIn('VALUE "ProductName", "orvix-watch-party-test"', changed)
        self.assertNotIn('VALUE "ProductName", "orvix" ', changed)

    def test_windows_keeps_the_single_instance_guard(self):
        # The test build shares the stream cache with the installed app, so
        # the two must not run at the same time.
        self.assertNotIn("main.cpp", str(identity.TARGETS["windows"]))


def job(workflow: str, name: str) -> str:
    match = re.search(rf"^  {re.escape(name)}:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)", workflow, re.S | re.M)
    if match is None:
        raise AssertionError(f"job {name} not found")
    return match.group(1)


TEST_JOBS = ("watch-party-test-android", "watch-party-test-windows")
TEST_ONLY_WORDS = (
    "ORVIX_TEST_BUILD",
    "ORVIX_WATCH_PARTY",
    "ORVIX_SUPABASE_",
    "ORVIX_TEST_SUPABASE_",
    "write_test_build_defines.py \"",
    "configure_test_build_identity.py ",
    "dart-define-from-file",
)


class WorkflowTest(unittest.TestCase):
    def test_there_are_still_exactly_two_workflows(self):
        names = sorted(p.name for p in (ROOT / ".github" / "workflows").iterdir())
        self.assertEqual(names, ["ci.yml", "prerelease.yml"])

    def test_test_builds_are_off_unless_requested_by_hand(self):
        self.assertRegex(
            CI,
            r"workflow_dispatch:\n    inputs:\n      watch_party_test_build:\n"
            r"(?:        .*\n)+?        type: boolean\n        default: false\n",
        )
        for name in TEST_JOBS:
            body = job(CI, name)
            self.assertIn(
                "if: ${{ github.event_name == 'workflow_dispatch' && "
                "inputs.watch_party_test_build }}",
                body,
            )
            self.assertIn("needs: quality", body)

    def test_normal_ci_jobs_cannot_pick_up_test_settings(self):
        outside = CI
        for name in TEST_JOBS:
            outside = outside.replace(job(CI, name), "")
        for word in TEST_ONLY_WORDS:
            self.assertNotIn(word, outside, word)

    def test_the_release_workflow_knows_nothing_about_test_builds(self):
        for word in TEST_ONLY_WORDS + ("watch_party", "wptest"):
            self.assertNotIn(word, PRERELEASE, word)

    def test_test_builds_only_produce_workflow_artifacts(self):
        for name in TEST_JOBS:
            body = job(CI, name)
            self.assertIn("actions/upload-artifact@v4", body)
            for word in ("gh release", "publish_orvix_release", "contents: write", "softprops"):
                self.assertNotIn(word, body)
        self.assertRegex(CI, r"\npermissions:\n  contents: read\n")

    def test_backend_values_come_from_secrets_and_stay_off_command_lines(self):
        for name in TEST_JOBS:
            body = job(CI, name)
            self.assertEqual(body.count("secrets.ORVIX_TEST_SUPABASE_URL"), 1)
            self.assertEqual(
                body.count("secrets.ORVIX_TEST_SUPABASE_PUBLISHABLE_KEY"), 1
            )
            for line in body.splitlines():
                if "secrets." in line:
                    self.assertRegex(line, r"^\s+ORVIX_TEST_SUPABASE_[A-Z_]+: \$\{\{ secrets\.")
            self.assertNotIn("--dart-define=ORVIX_SUPABASE", body)
            self.assertIn('--dart-define-from-file="$RUNNER_TEMP/orvix-test-defines.json"', body)

    def test_every_test_build_gets_the_test_identity(self):
        android = job(CI, TEST_JOBS[0])
        self.assertIn("configure_test_build_identity.py android", android)
        self.assertIn("com.orvix.orvix.wptest", android)
        self.assertIn("configure_android_mobile_compat.py", android)
        self.assertIn("java-version: '17'", android)
        self.assertIn("configure_test_build_identity.py windows", job(CI, TEST_JOBS[1]))


class StagingScriptTest(unittest.TestCase):
    def test_apply_refuses_production_and_unnamed_databases(self):
        script = (ROOT / "supabase" / "staging" / "apply.sh").read_text(encoding="utf-8")
        self.assertIn("that is the production project. Refusing.", script)
        self.assertIn("names the production project. Refusing.", script)
        self.assertIn("does not name project", script)
        self.assertLess(script.index("Refusing."), script.index("run_psql <<"))
        for workflow in (CI, PRERELEASE):
            self.assertNotIn("supabase/staging", workflow)


if __name__ == "__main__":
    unittest.main()
