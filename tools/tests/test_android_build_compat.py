"""Android build compatibility: the Gradle plugin lint fix and CI debug signing.

Android Gradle Plugin 9.3.0 and 9.3.1 crash in lintVitalAnalyzeRelease on
JDK 17 (Google issue 522845800). tools/configure_android_mobile_compat.py
moves exactly those versions to 9.3.2 in the generated project and leaves
everything else alone. Lint itself must stay enabled.
"""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import configure_android_mobile_compat as compat  # noqa: E402


def settings(agp: str, kotlin: str = "2.4.20") -> str:
    """android/settings.gradle.kts as `flutter create` writes it."""
    return f"""pluginManagement {{
    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {{
        google()
        mavenCentral()
        gradlePluginPortal()
    }}
}}

plugins {{
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "{agp}" apply false
    id("org.jetbrains.kotlin.android") version "{kotlin}" apply false
}}

include(":app")
"""


class AndroidGradlePluginFixTest(unittest.TestCase):
    def test_versions_with_the_lint_crash_move_to_the_fixed_patch_release(self):
        for affected in ("9.3.0", "9.3.1"):
            with self.subTest(agp=affected):
                self.assertEqual(
                    compat.use_fixed_android_gradle_plugin(settings(affected)),
                    settings("9.3.2"),
                )

    def test_the_fix_stays_inside_the_same_minor_release(self):
        fixed = tuple(int(part) for part in compat.FIXED_AGP_VERSION.split("."))
        for affected in compat.LINT_CRASH_AGP_VERSIONS:
            parts = tuple(int(part) for part in affected.split("."))
            self.assertEqual(parts[:2], fixed[:2], "only a patch-level move is allowed")
            self.assertLess(parts, fixed)

    def test_every_other_version_is_left_as_flutter_generated_it(self):
        for version in ("8.11.1", "8.13.0", "9.0.0", "9.2.1", "9.3.2", "9.3.3", "9.4.0", "10.0.0"):
            with self.subTest(agp=version):
                text = settings(version)
                self.assertEqual(compat.use_fixed_android_gradle_plugin(text), text)

    def test_only_the_android_plugin_version_changes(self):
        # A Kotlin plugin that happens to carry the same number is not touched.
        before = settings("9.3.1", kotlin="9.3.1")
        after = compat.use_fixed_android_gradle_plugin(before)
        changed = [
            (old, new)
            for old, new in zip(before.splitlines(), after.splitlines())
            if old != new
        ]
        self.assertEqual(
            changed,
            [
                (
                    '    id("com.android.application") version "9.3.1" apply false',
                    '    id("com.android.application") version "9.3.2" apply false',
                )
            ],
        )

    def test_applying_it_twice_changes_nothing_more(self):
        once = compat.use_fixed_android_gradle_plugin(settings("9.3.1"))
        self.assertEqual(compat.use_fixed_android_gradle_plugin(once), once)

    def test_an_unrecognised_settings_file_is_left_alone(self):
        for text in ("", "plugins {\n}\n", 'id "com.android.application" version "9.3.1" apply false\n'):
            with self.subTest(text=text):
                self.assertEqual(compat.use_fixed_android_gradle_plugin(text), text)


class LintStaysEnabledTest(unittest.TestCase):
    """The crash is fixed at its source. Lint must not be switched off."""

    def test_no_build_helper_or_workflow_disables_lint(self):
        sources = sorted((ROOT / "tools").glob("*.py")) + sorted((ROOT / "tools").glob("*.sh"))
        sources += sorted((ROOT / ".github" / "workflows").glob("*.yml"))
        forbidden = (
            r"checkReleaseBuilds\s*=\s*false",
            r"abortOnError\s*=\s*false",
            r"-x\s+lint",
            r"lintVital\w*\.enabled\s*=\s*false",
            r"\bdisable\s*[+(]=?\s*[\"']",
        )
        for path in sources:
            text = path.read_text(encoding="utf-8")
            for pattern in forbidden:
                with self.subTest(file=path.name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, text))


class WorkflowCoverageTest(unittest.TestCase):
    """The fix lives in a script that every Android build runs, in CI and in
    the release workflow, for Android Mobile and Android TV."""

    def test_every_android_build_runs_the_compat_script_after_generating_the_project(self):
        for name in ("ci.yml", "prerelease.yml"):
            text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
            generated = [m.start() for m in re.finditer(r"flutter create --platforms=android", text)]
            patched = [m.start() for m in re.finditer(r"python3 tools/configure_android_mobile_compat\.py", text)]
            builds = [m.start() for m in re.finditer(r"flutter build apk", text)]
            with self.subTest(workflow=name):
                self.assertEqual(len(generated), 2, "Android Mobile and Android TV")
                self.assertEqual(len(patched), 2)
                for created, fixed in zip(generated, patched):
                    self.assertLess(created, fixed)
                    following = [build for build in builds if build > created]
                    self.assertTrue(following)
                    self.assertLess(fixed, following[0])

    def test_android_builds_still_run_on_the_jdk_the_fix_is_for(self):
        for name in ("ci.yml", "prerelease.yml"):
            text = (ROOT / ".github" / "workflows" / name).read_text(encoding="utf-8")
            with self.subTest(workflow=name):
                self.assertEqual(re.findall(r"java-version: '(\d+)'", text), ["17", "17"])


class CiDebugSigningTest(unittest.TestCase):
    """CI has no release keystore, so its Android Mobile APKs are signed with
    the Android build's debug key. The universal APK and the per-ABI APKs
    come from two commands and must share that key, or the installability
    check (rightly) fails. On a runner that sets XDG_CONFIG_HOME the two
    commands created the key in two different directories."""

    def test_both_ci_build_commands_use_one_android_user_directory(self):
        text = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
        step = text.split("- name: Build Android mobile release APKs\n", 1)[1]
        step = step.split("\n      - name:", 1)[0]
        self.assertRegex(step, r"(?m)^          ANDROID_USER_HOME: \S+")
        commands = step.split("        run: |\n", 1)[1]
        self.assertEqual(len(re.findall(r"flutter build apk --release", commands)), 2)
        self.assertLess(commands.index('mkdir -p "$ANDROID_USER_HOME"'), commands.index("flutter build apk"))

    def test_release_builds_sign_with_the_release_keystore_not_the_debug_key(self):
        signing = (ROOT / "tools" / "configure_android_signing.py").read_text(encoding="utf-8")
        self.assertIn('signingConfig = signingConfigs.getByName("release")', signing)
        text = (ROOT / ".github" / "workflows" / "prerelease.yml").read_text(encoding="utf-8")
        for build in re.finditer(r"flutter build apk --release", text):
            with self.subTest(position=build.start()):
                before = text[: build.start()]
                last_generated = before.rindex("flutter create --platforms=android")
                self.assertIn("python3 tools/configure_android_signing.py", before[last_generated:])


if __name__ == "__main__":
    unittest.main()
