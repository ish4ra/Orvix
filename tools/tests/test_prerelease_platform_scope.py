"""Runs the prerelease workflow's platform-scope shell steps for real.

An Android-only release must publish exactly the Android Mobile and Android TV
APKs, and every other trigger must keep publishing the full platform set.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / ".github/workflows/prerelease.yml").read_text()
VERSION = "0.7.9-beta.65"

ANDROID_ASSETS = [
    f"dist/mobile/Orvix-v{VERSION}-Android-Mobile.apk",
    f"dist/mobile/Orvix-v{VERSION}-Android-Mobile-arm64-v8a.apk",
    f"dist/mobile/Orvix-v{VERSION}-Android-Mobile-armeabi-v7a.apk",
    f"dist/mobile/Orvix-v{VERSION}-Android-Mobile-x86_64.apk",
    f"dist/tv/Orvix-v{VERSION}-Android-TV.apk",
]
ALL_ASSETS = [
    f"dist/windows/Orvix-v{VERSION}-Windows-x64.zip",
    f"dist/windows/installer-output/Orvix-Setup-v{VERSION}-Windows-x64.exe",
    *ANDROID_ASSETS,
    f"dist/macos/Orvix-v{VERSION}-macOS.zip",
    f"dist/ios-modern/Orvix-v{VERSION}-iOS-15.5-Plus.ipa",
    f"dist/ios-legacy/Orvix-v{VERSION}-iOS-12-Legacy.ipa",
]


def step_script(name: str) -> str:
    """The `run: |` body of the workflow step called `name`."""
    lines = WORKFLOW.splitlines()
    # A step's name is either its first key or follows its `- id:` line;
    # a bare `name:` elsewhere is a job name.
    start = next(
        i for i, line in enumerate(lines)
        if line.strip() == f"- name: {name}"
        or (line.strip() == f"name: {name}" and lines[i - 1].strip().startswith("- id:"))
    )
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    indent = len(lines[run + 1]) - len(lines[run + 1].lstrip())
    body = []
    for line in lines[run + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) < indent:
            break
        body.append(line[indent:])
    return "\n".join(body).replace("${{ needs.metadata.outputs.version }}", VERSION) + "\n"


def run_step(name: str, cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["bash", "-c", step_script(name)],
        cwd=cwd,
        env={"PATH": os.environ["PATH"], **env},
        capture_output=True,
        text=True,
    )


class PlatformResolutionTest(unittest.TestCase):
    def resolve(self, ref: str, requested: str = "") -> tuple[int, str]:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "output"
            result = run_step(
                "Resolve release platforms",
                Path(tmp),
                {
                    "GITHUB_REF_NAME": ref,
                    "REQUESTED_PLATFORMS": requested,
                    "GITHUB_OUTPUT": str(output),
                },
            )
            text = output.read_text() if output.exists() else ""
        return result.returncode, text

    def test_android_release_branch_is_android_only(self):
        self.assertEqual(
            self.resolve("release/android-v0.7.9-beta.65"), (0, "platforms=android\n")
        )

    def test_full_release_branch_keeps_every_platform(self):
        self.assertEqual(self.resolve("release/all-v0.7.9-beta.64"), (0, "platforms=all\n"))

    def test_manual_run_infers_from_branch_or_honours_the_choice(self):
        self.assertEqual(self.resolve("develop", "auto"), (0, "platforms=all\n"))
        self.assertEqual(
            self.resolve("release/android-v0.7.9-beta.65", "auto"), (0, "platforms=android\n")
        )
        self.assertEqual(self.resolve("develop", "all"), (0, "platforms=all\n"))
        self.assertEqual(self.resolve("develop", "android"), (0, "platforms=android\n"))

    def test_android_release_branch_never_publishes_every_platform(self):
        code, output = self.resolve("release/android-v0.7.9-beta.65", "all")
        self.assertNotEqual(code, 0)
        self.assertEqual(output, "")

    def test_unknown_platform_set_fails(self):
        code, output = self.resolve("develop", "windows")
        self.assertNotEqual(code, 0)
        self.assertEqual(output, "")


class AssetSelectionTest(unittest.TestCase):
    def select(self, platforms: str, present: list[str]) -> tuple[int, list[str], str]:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for asset in present:
                path = root / asset
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"artifact")
            selected = Path("/tmp/orvix-release-assets.txt")
            selected.unlink(missing_ok=True)
            result = run_step(
                "Select release assets", root, {"RELEASE_PLATFORMS": platforms}
            )
            listed = selected.read_text().splitlines() if selected.exists() else []
            selected.unlink(missing_ok=True)
        return result.returncode, listed, result.stdout + result.stderr

    def test_android_release_selects_exactly_the_five_android_apks(self):
        # Desktop/iOS files present in dist must still not be published.
        code, listed, output = self.select("android", ALL_ASSETS)
        self.assertEqual(code, 0, output)
        self.assertEqual(listed, ANDROID_ASSETS)

    def test_android_release_fails_when_an_android_apk_is_missing(self):
        code, listed, _ = self.select("android", ANDROID_ASSETS[:-1])
        self.assertNotEqual(code, 0)
        self.assertEqual(listed, [])

    def test_full_release_selects_every_platform(self):
        code, listed, output = self.select("all", ALL_ASSETS)
        self.assertEqual(code, 0, output)
        self.assertEqual(listed, ALL_ASSETS)

    def test_full_release_still_requires_desktop_and_ios_files(self):
        code, _, _ = self.select("all", ANDROID_ASSETS)
        self.assertNotEqual(code, 0)

    def test_unknown_platform_set_fails(self):
        code, _, _ = self.select("", ALL_ASSETS)
        self.assertNotEqual(code, 0)


class PublishUsesSelectionTest(unittest.TestCase):
    def test_publisher_receives_only_the_selected_assets(self):
        script = step_script("Publish Orvix prerelease")
        call = script[script.index("tools/publish_orvix_release.sh \\"):]
        self.assertIn('mapfile -t ASSETS < /tmp/orvix-release-assets.txt', script)
        self.assertIn('"${ASSETS[@]}"', call)
        self.assertNotIn("dist/", call)


if __name__ == "__main__":
    unittest.main()
