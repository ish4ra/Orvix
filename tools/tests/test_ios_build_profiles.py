"""Modern / Legacy iOS sideload builds: naming, metadata, signing rules,
Mach-O deployment-target gate, dependency isolation and release wiring."""

from __future__ import annotations

import contextlib
import io
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import ios_ipa_checks  # noqa: E402
import ios_macho  # noqa: E402
import ios_signing  # noqa: E402
import update_altstore_source  # noqa: E402
from ios_profiles import LEGACY, MODERN, PROFILES, get_profile  # noqa: E402

RELEASE = "0.7.9-beta.65"
BUILD = "4210"

# --- synthetic Mach-O binaries ------------------------------------------------

CPU_ARM64 = 0x0100000C
CPU_X86_64 = 0x01000007
CPU_ARMV7 = 12
MH_EXECUTE = 0x2
MH_DYLIB = 0x6


def _version(value: str) -> int:
    parts = [int(part) for part in value.split(".")] + [0, 0]
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def _dylib_command(cmd: int, name: str) -> bytes:
    raw = name.encode() + b"\0"
    size = 24 + len(raw)
    size += -size % 8
    return struct.pack("<IIIIII", cmd, size, 24, 2, 0x10000, 0x10000) + raw.ljust(size - 24, b"\0")


def macho(
    *,
    cputype: int = CPU_ARM64,
    platform: int = 2,
    minos: str = "12.0",
    sdk: str = "18.5",
    filetype: int = MH_DYLIB,
    strong: tuple[str, ...] = (),
    weak: tuple[str, ...] = (),
    version_min: bool = False,
) -> bytes:
    commands = []
    if version_min:
        commands.append(struct.pack("<IIII", 0x25, 16, _version(minos), _version(sdk)))
    else:
        commands.append(struct.pack("<IIIIII", 0x32, 24, platform, _version(minos), _version(sdk), 0))
    commands += [_dylib_command(0x0C, name) for name in strong]
    commands += [_dylib_command(0x80000018, name) for name in weak]
    body = b"".join(commands)
    header = struct.pack(
        "<IiIIIIII", 0xFEEDFACF, cputype, 0, filetype, len(commands), len(body), 0, 0
    )
    return header + body


def fat(*slices: tuple[int, bytes]) -> bytes:
    header = struct.pack(">II", 0xCAFEBABE, len(slices))
    entries = b""
    payload = b""
    offset = 4096
    for cputype, data in slices:
        entries += struct.pack(">iIIII", cputype, 0, offset, len(data), 12)
        padded = data.ljust(-(-len(data) // 4096) * 4096, b"\0")
        payload += padded
        offset += len(padded)
    return (header + entries).ljust(4096, b"\0") + payload


def write_ipa(
    root: Path,
    profile,
    *,
    name: str | None = None,
    info: dict | None = None,
    binaries: dict | None = None,
    extra: dict | None = None,
) -> Path:
    ipa = root / (name or profile.ipa_filename(RELEASE))
    plist = {
        "CFBundleIdentifier": "com.orvix.orvix",
        "CFBundleDisplayName": "Orvix",
        "CFBundleShortVersionString": "0.7.9",
        "CFBundleVersion": BUILD,
        "CFBundleExecutable": "Runner",
        "MinimumOSVersion": profile.min_ios,
        "NSCameraUsageDescription": "Scan a QR code.",
    }
    plist.update(info or {})
    if binaries is None:
        binaries = {
            "Runner": macho(minos=profile.min_ios, filetype=MH_EXECUTE),
            "Frameworks/Flutter.framework/Flutter": macho(minos="12.0"),
            "Frameworks/Mpv.framework/Mpv": macho(minos="9.0"),
        }
    with zipfile.ZipFile(ipa, "w") as archive:
        archive.writestr("Payload/Orvix.app/Info.plist", plistlib.dumps(plist))
        for path, data in binaries.items():
            archive.writestr(f"Payload/Orvix.app/{path}", data)
        for path, data in (extra or {}).items():
            archive.writestr(path, data)
    return ipa


def run_checks(ipa: Path, profile, **kwargs) -> list[str]:
    return ios_ipa_checks.check_ipa(ipa, RELEASE, BUILD, profile, report=lambda _: None, **kwargs)


def job_block(workflow: str, job: str) -> str:
    """Return the text of one top-level job in a workflow file."""
    match = re.search(rf"^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", workflow, re.M | re.S)
    if match is None:
        raise AssertionError(f"workflow has no job {job!r}")
    return match.group(1)


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8").replace("\r\n", "\n")


# --- profiles and naming -----------------------------------------------------


class ProfileNamingTest(unittest.TestCase):
    def test_modern_filename(self):
        self.assertEqual(MODERN.ipa_filename(RELEASE), "Orvix-v0.7.9-beta.65-iOS-15.5-Plus.ipa")

    def test_legacy_filename(self):
        self.assertEqual(LEGACY.ipa_filename(RELEASE), "Orvix-v0.7.9-beta.65-iOS-12-Legacy.ipa")

    def test_stable_release_filenames(self):
        self.assertEqual(MODERN.ipa_filename("0.7.9"), "Orvix-v0.7.9-iOS-15.5-Plus.ipa")
        self.assertEqual(LEGACY.ipa_filename("0.7.9"), "Orvix-v0.7.9-iOS-12-Legacy.ipa")

    def test_filenames_state_their_minimum_ios_and_never_collide(self):
        modern, legacy = MODERN.ipa_filename(RELEASE), LEGACY.ipa_filename(RELEASE)
        self.assertNotEqual(modern, legacy)
        self.assertIn("15.5", modern)
        self.assertIn("iOS-12", legacy)
        for name in (modern, legacy):
            self.assertFalse(name.endswith("-iOS.ipa"), name)
            self.assertFalse(name.endswith("-iOS-Legacy.ipa"), name)

    def test_rejects_unsafe_release_versions(self):
        for version in ("", "v0.7.9", "../0.7.9"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                MODERN.ipa_filename(version)

    def test_minimum_ios_versions(self):
        self.assertEqual(MODERN.min_ios, "15.5")
        self.assertEqual(LEGACY.min_ios, "12.0")

    def test_ci_artifact_names(self):
        self.assertEqual(MODERN.ci_artifact, "ios-modern")
        self.assertEqual(LEGACY.ci_artifact, "ios-legacy")

    def test_only_legacy_pins_a_toolchain(self):
        self.assertIsNone(MODERN.flutter_version)
        self.assertIsNone(MODERN.xcode_version)
        self.assertEqual(LEGACY.flutter_version, "3.32.8")
        self.assertEqual(LEGACY.xcode_version, "16.4")

    def test_unknown_profile_is_rejected(self):
        with self.assertRaises(ValueError):
            get_profile("ios")
        self.assertEqual(set(PROFILES), {"modern", "legacy"})

    def test_profile_cli(self):
        def run(*argv):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(__import__("ios_profiles").main(list(argv)), 0)
            return out.getvalue().strip()

        self.assertEqual(run("min-ios", "legacy"), "12.0")
        self.assertEqual(run("ipa-filename", "modern", RELEASE), MODERN.ipa_filename(RELEASE))
        self.assertEqual(run("flutter-version", "legacy"), "3.32.8")

    def test_configure_script_has_no_shared_mutable_target(self):
        script = read("tools/configure_ios_build.py")
        self.assertNotIn("MIN_IOS_VERSION", script)
        self.assertIn('add_argument("--profile", required=True', script)


# --- IPA metadata and signing ------------------------------------------------


class IpaChecksTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_valid_modern_and_legacy_ipas_pass(self):
        for profile in (MODERN, LEGACY):
            with self.subTest(profile=profile.name):
                self.assertEqual(run_checks(write_ipa(self.root, profile), profile), [])

    def test_modern_requires_minimum_ios_15_5(self):
        ipa = write_ipa(self.root, MODERN, info={"MinimumOSVersion": "12.0"})
        self.assertTrue(any("MinimumOSVersion='12.0'" in p for p in run_checks(ipa, MODERN)))

    def test_legacy_requires_minimum_ios_12_0(self):
        ipa = write_ipa(self.root, LEGACY, info={"MinimumOSVersion": "15.5"})
        self.assertTrue(any("MinimumOSVersion='15.5'" in p for p in run_checks(ipa, LEGACY)))

    def test_version_metadata_for_both_profiles(self):
        for profile in (MODERN, LEGACY):
            for key, value in (
                ("CFBundleShortVersionString", "0.7.9.65"),
                ("CFBundleShortVersionString", "0.7.9-beta.65"),
                ("CFBundleVersion", "4209"),
                ("CFBundleIdentifier", "com.orvix.legacy"),
                ("CFBundleDisplayName", "Orvix Legacy"),
            ):
                with self.subTest(profile=profile.name, key=key, value=value):
                    folder = self.root / f"{profile.name}-{key}-{value}"
                    folder.mkdir()
                    ipa = write_ipa(folder, profile, info={key: value})
                    self.assertTrue(any(key in p for p in run_checks(ipa, profile)))

    def test_filename_must_match_profile(self):
        ipa = write_ipa(self.root, LEGACY, name=MODERN.ipa_filename(RELEASE))
        self.assertTrue(any("expected Orvix-v0.7.9-beta.65-iOS-12-Legacy.ipa" in p for p in run_checks(ipa, LEGACY)))

    def test_app_level_signature_is_rejected(self):
        for profile in (MODERN, LEGACY):
            with self.subTest(profile=profile.name):
                folder = self.root / profile.name
                folder.mkdir()
                ipa = write_ipa(
                    folder, profile,
                    extra={"Payload/Orvix.app/_CodeSignature/CodeResources": b"signed"},
                )
                self.assertTrue(any("code signed" in p for p in run_checks(ipa, profile)))

    def test_embedded_provisioning_profile_is_rejected(self):
        for path in (
            "Payload/Orvix.app/embedded.mobileprovision",
            "Payload/Orvix.app/PlugIns/Share.appex/embedded.mobileprovision",
        ):
            with self.subTest(path=path):
                folder = self.root / str(abs(hash(path)))
                folder.mkdir()
                ipa = write_ipa(folder, LEGACY, extra={path: b"profile"})
                self.assertTrue(any("provisioning profile" in p for p in run_checks(ipa, LEGACY)))

    def test_nested_adhoc_framework_signatures_are_allowed(self):
        nested = {
            f"Payload/Orvix.app/Frameworks/{name}.framework/_CodeSignature/CodeResources": b"adhoc"
            for name in ("Flutter", "App", "objective_c")
        }
        for profile in (MODERN, LEGACY):
            with self.subTest(profile=profile.name):
                folder = self.root / profile.name
                folder.mkdir()
                self.assertEqual(run_checks(write_ipa(folder, profile, extra=nested), profile), [])

    def test_layout_must_be_payload_orvix_app(self):
        ipa = write_ipa(self.root, LEGACY, extra={"Payload/Other.app/Info.plist": b"x"})
        self.assertTrue(any("outside Payload/Orvix.app" in p for p in run_checks(ipa, LEGACY)))

    def test_empty_or_corrupt_ipa_is_rejected(self):
        empty = self.root / LEGACY.ipa_filename(RELEASE)
        empty.write_bytes(b"")
        self.assertTrue(any("missing or empty" in p for p in run_checks(empty, LEGACY)))
        empty.write_bytes(b"not a zip")
        self.assertTrue(any("not a valid zip" in p for p in run_checks(empty, LEGACY)))


# --- Mach-O deployment-target gate -------------------------------------------


class MachOGateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def legacy_problems(self, binaries: dict) -> list[str]:
        base = {"Runner": macho(minos="12.0", filetype=MH_EXECUTE)}
        base.update(binaries)
        return run_checks(write_ipa(self.root, LEGACY, binaries=base), LEGACY)

    def test_parses_build_version_and_legacy_version_min(self):
        binary = ios_macho.parse_macho(macho(minos="12.0", sdk="18.5"), "a")
        self.assertEqual((binary.archs, binary.slices[0].platform, binary.slices[0].minos), (["arm64"], "ios", "12.0"))
        old = ios_macho.parse_macho(macho(minos="9.0", version_min=True), "b")
        self.assertEqual((old.slices[0].platform, old.slices[0].minos), ("ios", "9.0"))
        self.assertEqual(ios_macho.decode_version(_version("15.5.1")), "15.5.1")

    def test_parses_fat_binaries(self):
        binary = ios_macho.parse_macho(
            fat((CPU_ARMV7, macho(cputype=CPU_ARMV7, minos="9.0")), (CPU_ARM64, macho(minos="12.0"))),
            "fat",
        )
        self.assertEqual(binary.archs, ["armv7", "arm64"])

    def test_framework_requiring_newer_ios_fails_legacy(self):
        for minos in ("13.0", "14.0", "15.0", "12.1"):
            with self.subTest(minos=minos):
                problems = self.legacy_problems({"Frameworks/Ffmpegkit.framework/Ffmpegkit": macho(minos=minos)})
                self.assertTrue(any(f"requires iOS {minos}" in p for p in problems), problems)

    def test_main_executable_requiring_newer_ios_fails_legacy(self):
        problems = self.legacy_problems({"Runner": macho(minos="13.0", filetype=MH_EXECUTE)})
        self.assertTrue(any("Orvix.app/Runner [arm64]: requires iOS 13.0" in p for p in problems), problems)

    def test_same_framework_passes_modern(self):
        ipa = write_ipa(
            self.root, MODERN,
            binaries={
                "Runner": macho(minos="15.5", filetype=MH_EXECUTE),
                "Frameworks/Ffmpegkit.framework/Ffmpegkit": macho(minos="14.0"),
            },
        )
        self.assertEqual(run_checks(ipa, MODERN), [])

    def test_modern_rejects_binary_above_15_5(self):
        ipa = write_ipa(
            self.root, MODERN,
            binaries={
                "Runner": macho(minos="15.5", filetype=MH_EXECUTE),
                "Frameworks/New.framework/New": macho(minos="16.0"),
            },
        )
        self.assertTrue(any("requires iOS 16.0" in p for p in run_checks(ipa, MODERN)))

    def test_simulator_slices_fail(self):
        problems = self.legacy_problems({"Frameworks/Sim.framework/Sim": macho(platform=7)})
        self.assertTrue(any("ios-simulator" in p for p in problems), problems)
        problems = self.legacy_problems({
            "Frameworks/Fat.framework/Fat": fat(
                (CPU_ARM64, macho(minos="12.0")),
                (CPU_X86_64, macho(cputype=CPU_X86_64, platform=7, minos="12.0")),
            )
        })
        self.assertTrue(any("Intel simulator code" in p for p in problems), problems)

    def test_binary_without_arm64_fails(self):
        problems = self.legacy_problems({"Frameworks/Old.framework/Old": macho(cputype=CPU_ARMV7, minos="9.0")})
        self.assertTrue(any("no arm64 device slice" in p for p in problems), problems)

    def test_non_ios_platform_fails(self):
        problems = self.legacy_problems({"Frameworks/Mac.framework/Mac": macho(platform=1, minos="10.14")})
        self.assertTrue(any("built for macos" in p for p in problems), problems)

    def test_strong_link_to_newer_system_framework_fails_but_weak_link_passes(self):
        swiftui = "/System/Library/Frameworks/SwiftUI.framework/SwiftUI"
        problems = self.legacy_problems({"Frameworks/A.framework/A": macho(strong=(swiftui,))})
        self.assertTrue(any("strongly links" in p and "SwiftUI" in p for p in problems), problems)
        self.assertEqual(self.legacy_problems({"Frameworks/A.framework/A": macho(weak=(swiftui,))}), [])

    def test_swift_runtime_links(self):
        concurrency = "@rpath/libswift_Concurrency.dylib"
        problems = self.legacy_problems({"Frameworks/A.framework/A": macho(strong=(concurrency,))})
        self.assertTrue(any("libswift_Concurrency" in p for p in problems), problems)
        # Embedded back-deployment copies satisfy @rpath links.
        self.assertEqual(
            self.legacy_problems({
                "Frameworks/A.framework/A": macho(strong=("@rpath/libswiftCore.dylib",)),
                "Frameworks/libswiftCore.dylib": macho(minos="12.0"),
            }),
            [],
        )
        # System Swift libraries that exist on iOS 12.2+ are fine by path.
        self.assertEqual(
            self.legacy_problems({"Frameworks/A.framework/A": macho(strong=("/usr/lib/swift/libswiftCore.dylib",))}),
            [],
        )

    def test_inventory_lists_every_binary(self):
        app = self.root / "Orvix.app"
        (app / "Frameworks" / "Mpv.framework").mkdir(parents=True)
        (app / "Runner").write_bytes(macho(minos="12.0", filetype=MH_EXECUTE))
        (app / "Frameworks" / "Mpv.framework" / "Mpv").write_bytes(macho(minos="9.0"))
        (app / "Frameworks" / "Mpv.framework" / "Info.plist").write_bytes(b"<plist/>")
        binaries = ios_macho.scan_app(app)
        self.assertEqual([b.path for b in binaries], ["Orvix.app/Frameworks/Mpv.framework/Mpv", "Orvix.app/Runner"])
        self.assertEqual(ios_macho.highest_minos(binaries), "12.0")
        self.assertIn("Mpv", ios_macho.format_inventory(binaries))


# --- dependency and source isolation ------------------------------------------


def debrify_pins(text: str) -> dict:
    pins = {}
    for package in ("media_kit", "media_kit_video"):
        block = re.search(rf"^  {package}:\n((?:      .*\n|    git:\n)+)", text, re.M)
        assert block, package
        pins[package] = tuple(re.findall(r"^      (url|ref|path): (\S+)$", block.group(1), re.M))
    return pins


class IsolationTest(unittest.TestCase):
    overrides = read("tools/ios_legacy/pubspec_overrides.yaml")
    pubspec = read("pubspec.yaml")

    def test_legacy_overrides_keep_reviewed_debrify_pins(self):
        self.assertEqual(debrify_pins(self.overrides), debrify_pins(self.pubspec))

    def test_legacy_overrides_pin_exact_versions_or_local_paths(self):
        body = self.overrides.split("dependency_overrides:\n", 1)[1]
        for name, value in re.findall(r"^  ([a-z0-9_]+):[ ]*(.*)$", body, re.M):
            with self.subTest(package=name):
                if name in ("media_kit", "media_kit_video"):
                    continue
                if value == "":
                    self.assertRegex(body, rf"  {name}:\n    path: tools/ios_legacy/packages/{name}\n")
                    self.assertTrue((ROOT / "tools/ios_legacy/packages" / name / "pubspec.yaml").is_file())
                else:
                    self.assertRegex(value, r"^\d+\.\d+\.\d+$")

    def test_legacy_overrides_cover_ios13_plus_dependencies(self):
        for package, version in (
            ("mobile_scanner", "7.4.2"),
            ("file_picker", "11.0.3"),
            ("flutter_secure_storage", "10.3.4"),
            ("flutter_secure_storage_darwin", "0.3.2"),
            ("package_info_plus", "9.0.1"),
        ):
            with self.subTest(package=package):
                self.assertRegex(self.overrides, rf"(?m)^  {package}: {re.escape(version)}$")
        self.assertIn("ffmpeg_kit_flutter_new_https:\n    path: tools/ios_legacy/packages/ffmpeg_kit_flutter_new_https", self.overrides)

    def test_normal_builds_keep_current_dependencies(self):
        self.assertNotIn("ios_legacy", self.pubspec)
        self.assertRegex(self.pubspec, r"(?m)^  mobile_scanner: \^6\.")
        self.assertRegex(self.pubspec, r"(?m)^  file_picker: \^13\.")
        self.assertRegex(self.pubspec, r"(?m)^  ffmpeg_kit_flutter_new_https: 2\.6\.2$")
        self.assertFalse((ROOT / "pubspec_overrides.yaml").exists(), "root pubspec_overrides.yaml must never be committed")
        self.assertIn("/pubspec_overrides.yaml", read(".gitignore").splitlines())

    def test_ffmpeg_stand_in_has_no_native_code_and_covers_used_imports(self):
        package = ROOT / "tools/ios_legacy/packages/ffmpeg_kit_flutter_new_https"
        stub_pubspec = (package / "pubspec.yaml").read_text(encoding="utf-8")
        self.assertNotIn("plugin:", stub_pubspec)
        self.assertEqual(sorted(p.name for p in package.iterdir() if p.is_dir()), ["lib"])
        used = set()
        for dart in (ROOT / "lib").rglob("*.dart"):
            used |= set(re.findall(r"package:ffmpeg_kit_flutter_new_https/([\w/]+\.dart)", dart.read_text(encoding="utf-8")))
        self.assertTrue(used)
        for name in sorted(used):
            with self.subTest(file=name):
                self.assertTrue((package / "lib" / name).is_file())

    def test_ffmpeg_stays_disabled_on_ios(self):
        extractor = read("lib/services/embedded_subtitle_extractor_service.dart")
        self.assertIn("Platform.isAndroid || Platform.isWindows || Platform.isMacOS", extractor)
        self.assertIn("(Platform.isWindows || Platform.isAndroid || Platform.isMacOS)", read("lib/services/ai_audio_stt_service.dart"))

    def test_source_overlay_only_replaces_matching_adapters(self):
        overlay = ROOT / "tools/ios_legacy/overlay"
        files = sorted(p for p in overlay.rglob("*") if p.is_file())
        self.assertEqual([p.relative_to(overlay).as_posix() for p in files], ["lib/services/subtitle_file_picker.dart"])
        declaration = re.compile(r"^(?:const|final|Future<[^>]+>|[A-Z]\w*)[^\n]*?(\w+)\s*[=(]", re.M)
        for legacy in files:
            modern = ROOT / legacy.relative_to(overlay)
            with self.subTest(file=modern.name):
                self.assertTrue(modern.is_file())
                self.assertEqual(
                    sorted(declaration.findall(legacy.read_text(encoding="utf-8"))),
                    sorted(declaration.findall(modern.read_text(encoding="utf-8"))),
                )
        self.assertIn("FilePicker.pickFile(", read("lib/services/subtitle_file_picker.dart"))
        self.assertIn("pickExternalSubtitlePath()", read("lib/screens/player_screen.dart"))
        self.assertNotIn("package:file_picker", read("lib/screens/player_screen.dart"))

    def test_scanner_error_builder_fits_mobile_scanner_6_and_7(self):
        self.assertIn("MobileScannerException error, [\n    Widget? child,\n  ])", read("lib/screens/account_screen.dart"))

    def test_builders_are_bound_to_one_profile_each(self):
        modern = read("tools/build_ios_ipa.sh")
        legacy = read("tools/build_ios_legacy_ipa.sh")
        self.assertIn("\nPROFILE=modern\n", modern)
        self.assertIn("\nPROFILE=legacy\n", legacy)
        for script in (modern, legacy):
            self.assertIn('orvix_ios_build_and_package "$PROFILE"', script)
        # Modern refuses Legacy state; Legacy applies and restores it.
        self.assertIn("if [[ -e pubspec_overrides.yaml ]]", modern)
        self.assertIn("tools/ios_legacy/overlay/lib/services/subtitle_file_picker.dart", modern)
        self.assertIn('cp "$LEGACY_DIR/pubspec_overrides.yaml" pubspec_overrides.yaml', legacy)
        self.assertIn("trap restore_checkout EXIT", legacy)
        self.assertIn('rm -f "$ROOT/pubspec_overrides.yaml"', legacy)
        self.assertIn('[[ "$FLUTTER_VERSION" != "$EXPECTED_FLUTTER" ]]', legacy)
        common = read("tools/ios_ipa_common.sh")
        self.assertIn("orvix_ios_check_dependency_profile \"$profile\"", common)
        self.assertIn("grep -q 'tools/ios_legacy' \"$config\"", common)

    def test_shell_scripts_parse(self):
        bash = subprocess.run(["bash", "--version"], capture_output=True)
        if bash.returncode != 0 or sys.platform == "win32":
            self.skipTest("bash syntax check runs on CI runners")
        for script in ("ios_ipa_common.sh", "build_ios_ipa.sh", "build_ios_legacy_ipa.sh",
                       "verify_ios_ipa.sh", "verify_ios_legacy_ipa.sh"):
            with self.subTest(script=script):
                subprocess.run(["bash", "-n", str(TOOLS / script)], check=True)


# --- CI and release wiring -----------------------------------------------------


class WorkflowTest(unittest.TestCase):
    ci = read(".github/workflows/ci.yml")
    prerelease = read(".github/workflows/prerelease.yml")

    def test_ci_has_two_explicit_ios_jobs(self):
        self.assertNotRegex(self.ci, r"(?m)^  ios:\n")
        modern = job_block(self.ci, "ios-modern")
        legacy = job_block(self.ci, "ios-legacy")
        self.assertIn(f"name: {MODERN.title}\n", modern)
        self.assertIn(f"name: {LEGACY.title}\n", legacy)
        self.assertIn("name: ios-modern\n", modern)
        self.assertIn("name: ios-legacy\n", legacy)
        self.assertIn("path: Orvix-v*-iOS-15.5-Plus.ipa", modern)
        self.assertIn("path: Orvix-v*-iOS-12-Legacy.ipa", legacy)
        self.assertIn("bash tools/build_ios_ipa.sh", modern)
        self.assertIn("bash tools/build_ios_legacy_ipa.sh", legacy)
        self.assertIn("bash tools/verify_ios_legacy_ipa.sh", legacy)
        self.assertNotIn("legacy", modern.lower())

    def test_only_the_legacy_jobs_pin_flutter_and_xcode(self):
        for name, workflow in (("ci", self.ci), ("prerelease", self.prerelease)):
            with self.subTest(workflow=name):
                legacy = job_block(workflow, "ios-legacy")
                self.assertIn(f"flutter-version: {LEGACY.flutter_version}\n", legacy)
                self.assertIn(f"/Applications/Xcode_{LEGACY.xcode_version}.app/Contents/Developer", legacy)
                self.assertEqual(workflow.count("flutter-version:"), 1)
                self.assertEqual(workflow.count("xcode-select -s"), 1)

    def test_release_publishes_both_ipas_with_unambiguous_names(self):
        version = "${{ needs.metadata.outputs.version }}"
        modern = f"dist/ios-modern/Orvix-v{version}-iOS-15.5-Plus.ipa"
        legacy = f"dist/ios-legacy/Orvix-v{version}-iOS-12-Legacy.ipa"
        release = job_block(self.prerelease, "release")
        self.assertIn("ios-modern, ios-legacy", release)
        self.assertIn(f"test -s {modern}\n", release)
        self.assertIn(f"test -s {legacy}\n", release)
        publish = release[release.index("tools/publish_orvix_release.sh \\"):]
        self.assertIn(modern, publish)
        self.assertIn(legacy, publish)
        self.assertNotIn("-iOS.ipa", self.prerelease)
        for job, artifact in (("ios-modern", "ios-modern"), ("ios-legacy", "ios-legacy")):
            self.assertIn(f"name: {artifact}\n", job_block(self.prerelease, job))

    def test_release_notes_separate_the_two_downloads(self):
        release = job_block(self.prerelease, "release")
        modern_at = release.index("### iPhone / iPad - Modern (Recommended)")
        legacy_at = release.index("### iPhone / iPad - Legacy")
        self.assertLess(modern_at, legacy_at)
        modern_notes = release[modern_at:legacy_at]
        legacy_notes = release[legacy_at:release.index("### Both iPhone / iPad builds")]
        self.assertIn("Orvix-v$V-iOS-15.5-Plus.ipa", modern_notes)
        self.assertIn("Requires iOS / iPadOS 15.5 or later.", modern_notes)
        self.assertIn("Use this unless your device cannot run iOS 15.5.", modern_notes)
        self.assertIn("Orvix-v$V-iOS-12-Legacy.ipa", legacy_notes)
        for device in ("iPhone 5s", "iPhone 6", "iPhone 6 Plus"):
            self.assertIn(device, legacy_notes)
        self.assertIn("iOS 12", legacy_notes)
        self.assertIn("Legacy-only limitations", legacy_notes)

    def test_altstore_source_lists_only_the_modern_ipa(self):
        release = job_block(self.prerelease, "release")
        store = release[release.index("Prepare AltStore / SideStore source entry"):]
        self.assertIn('--ipa "dist/ios-modern/Orvix-v$V-iOS-15.5-Plus.ipa"', store)
        self.assertIn("Orvix-v$V-iOS-15.5-Plus.ipa\" \\", store)
        self.assertNotIn("Legacy.ipa", store)

    def test_altstore_updater_rejects_legacy_ipa(self):
        with tempfile.TemporaryDirectory() as temporary:
            ipa = write_ipa(Path(temporary), LEGACY)
            url = f"https://github.com/ish4ra/Orvix/releases/download/v{RELEASE}/{ipa.name}"
            with self.assertRaisesRegex(ValueError, "direct GitHub download only"):
                update_altstore_source.validate_source_build(ipa, url, "12.0")
            modern_name = Path(temporary) / MODERN.ipa_filename(RELEASE)
            with self.assertRaisesRegex(ValueError, "below the Modern build"):
                update_altstore_source.validate_source_build(modern_name, url.replace(ipa.name, modern_name.name), "12.0")
            update_altstore_source.validate_source_build(
                modern_name, url.replace(ipa.name, modern_name.name), "15.5"
            )

    def test_quality_job_checks_new_helpers(self):
        quality = job_block(self.ci, "quality")
        for helper in ("ios_ipa_checks.py", "ios_macho.py", "ios_profiles.py", "ios_signing.py"):
            self.assertIn(f"tools/{helper}", quality)
        for script in ("ios_ipa_common.sh", "build_ios_legacy_ipa.sh", "verify_ios_legacy_ipa.sh"):
            self.assertIn(f"bash -n tools/{script}", quality)


# --- code-signing policy -------------------------------------------------------

APP_PATH = "Payload/Orvix.app"
NOT_SIGNED = "/tmp/x: code object is not signed at all\n"


def codesign_output(
    identifier: str,
    *,
    authorities: tuple[str, ...] = (),
    team: str = "not set",
    adhoc: bool = False,
    fmt: str = "Mach-O thin (arm64)",
) -> str:
    flags = "0x2(adhoc)" if adhoc else "0x0(none)"
    lines = [
        "Executable=/tmp/x",
        f"Identifier={identifier}",
        f"Format={fmt}",
        f"CodeDirectory v=20400 size=1234 flags={flags} hashes=30+7 location=embedded",
        "Signature=adhoc" if adhoc else "Signature size=4797",
    ]
    lines += [f"Authority={authority}" for authority in authorities]
    lines += [f"TeamIdentifier={team}", "Sealed Resources=none", "Internal requirements count=1 size=96"]
    return "\n".join(lines) + "\n"


def adhoc(identifier: str) -> str:
    return codesign_output(identifier, adhoc=True, fmt="bundle with Mach-O thin (arm64)")


def apple_swift(
    name: str,
    *,
    identifier: str | None = None,
    team: str = "59GAB85EFG",
    authorities: tuple[str, ...] = ios_signing.APPLE_SOFTWARE_SIGNING_CHAIN,
) -> str:
    return codesign_output(identifier or f"com.apple.dt.runtime.{name}", authorities=authorities, team=team)


def developer(identifier: str, identity: str, team: str) -> str:
    return codesign_output(
        identifier,
        authorities=(
            f"{identity}: Some Developer ({team})",
            "Apple Worldwide Developer Relations Certification Authority",
            "Apple Root CA",
        ),
        team=team,
    )


SWIFT_CORE = f"{APP_PATH}/Frameworks/libswiftCore.dylib"
SWIFT_ACCELERATE = f"{APP_PATH}/Frameworks/libswiftAccelerate.dylib"
FLUTTER_ITEMS = {
    f"{APP_PATH}/Frameworks/App.framework": adhoc("io.flutter.flutter.app"),
    f"{APP_PATH}/Frameworks/Flutter.framework": adhoc("io.flutter.flutter"),
    f"{APP_PATH}/Frameworks/Mpv.framework": NOT_SIGNED,
}


class SigningPolicyTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def put(self, path: str, data: bytes) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def problems(self, items: dict, profile=LEGACY) -> list[str]:
        inventory = {APP_PATH: NOT_SIGNED, **items}
        return ios_signing.classify_inventory(inventory, profile, self.root)[1]

    # 1
    def test_unsigned_app_with_flutter_adhoc_frameworks_passes(self):
        for profile in (MODERN, LEGACY):
            with self.subTest(profile=profile.name):
                self.assertEqual(self.problems(FLUTTER_ITEMS, profile), [])

    # 2
    def test_unsigned_app_with_apple_swift_runtime_passes_legacy(self):
        for path in (SWIFT_CORE, SWIFT_ACCELERATE):
            self.put(path, macho(minos="7.0", sdk="12.2"))
        inventory = {
            APP_PATH: NOT_SIGNED,
            **FLUTTER_ITEMS,
            SWIFT_CORE: apple_swift("libswiftCore"),
            SWIFT_ACCELERATE: apple_swift("libswiftAccelerate"),
        }
        groups, problems = ios_signing.classify_inventory(inventory, LEGACY, self.root)
        self.assertEqual(problems, [])
        self.assertEqual(groups[ios_signing.APPLE_SWIFT_RUNTIME], [SWIFT_ACCELERATE, SWIFT_CORE])
        self.assertIn(APP_PATH, groups[ios_signing.UNSIGNED])

    def test_modern_does_not_accept_embedded_swift_runtime(self):
        self.put(SWIFT_CORE, macho(minos="7.0"))
        problems = self.problems({SWIFT_CORE: apple_swift("libswiftCore")}, MODERN)
        self.assertTrue(any("modern build never embeds Swift runtime" in p for p in problems), problems)

    # 3, 4
    def test_signed_app_is_rejected(self):
        app_store_chain = (
            "Apple iPhone OS Application Signing",
            "Apple iPhone Certification Authority",
            "Apple Root CA",
        )
        for name, output in (
            ("Apple Development", developer("com.orvix.orvix", "Apple Development", "ABCDE12345")),
            ("Apple Distribution", developer("com.orvix.orvix", "Apple Distribution", "ABCDE12345")),
            ("iPhone Distribution", developer("com.orvix.orvix", "iPhone Distribution", "ABCDE12345")),
            ("App Store", codesign_output("com.orvix.orvix", authorities=app_store_chain, team="ABCDE12345")),
            ("ad-hoc", adhoc("com.orvix.orvix")),
            ("Apple runtime chain", apple_swift("libswiftCore", identifier="com.orvix.orvix")),
        ):
            for profile in (MODERN, LEGACY):
                with self.subTest(identity=name, profile=profile.name):
                    category, problem = ios_signing.classify(APP_PATH, output, profile)
                    self.assertEqual(category, ios_signing.REJECTED)
                    self.assertIn("Payload/Orvix.app is code signed", problem)
        _, problem = ios_signing.classify(
            APP_PATH, developer("com.orvix.orvix", "Apple Distribution", "ABCDE12345"), LEGACY
        )
        self.assertIn("'Apple Distribution: Some Developer (ABCDE12345)'", problem)

    # 5
    def test_embedded_provisioning_profile_is_rejected(self):
        problems = ios_ipa_checks.check_layout(
            [f"{APP_PATH}/Info.plist", f"{APP_PATH}/embedded.mobileprovision"]
        )
        self.assertTrue(any("provisioning profile" in p for p in problems), problems)

    # 6
    def test_third_party_team_on_nested_framework_is_rejected(self):
        framework = f"{APP_PATH}/Frameworks/SDWebImage.framework"
        for profile in (MODERN, LEGACY):
            with self.subTest(profile=profile.name):
                problems = self.problems(
                    {framework: developer("com.sdwebimage", "Apple Development", "ZZZZZ99999")}, profile
                )
                self.assertTrue(
                    any("SDWebImage.framework is signed with a certificate" in p for p in problems), problems
                )

    # 7
    def test_developer_signed_dylib_named_like_swift_runtime_is_rejected(self):
        path = f"{APP_PATH}/Frameworks/libswiftSomething.dylib"
        self.put(path, macho(minos="7.0"))
        problems = self.problems(
            {path: developer("com.apple.dt.runtime.libswiftSomething", "Apple Development", "ABCDE12345")}
        )
        self.assertTrue(
            any("libswiftSomething.dylib" in p and "certificate chain" in p for p in problems), problems
        )

    def test_swift_runtime_rule_requires_every_apple_property(self):
        other_name = f"{APP_PATH}/Frameworks/libfoo.dylib"
        in_framework = f"{APP_PATH}/Frameworks/Plugin.framework/libswiftCore.dylib"
        in_plugins = f"{APP_PATH}/PlugIns/libswiftCore.dylib"
        for path in (SWIFT_CORE, other_name, in_framework, in_plugins):
            self.put(path, macho(minos="7.0"))
        cases = {
            "wrong team": (SWIFT_CORE, apple_swift("libswiftCore", team="ABCDE12345"), "runtime team"),
            "no team": (SWIFT_CORE, apple_swift("libswiftCore", team="not set"), "runtime team"),
            "wrong identifier": (
                SWIFT_CORE, apple_swift("libswiftCore", identifier="com.example.libswiftCore"), "runtime identifier"
            ),
            "another library's identifier": (
                SWIFT_CORE,
                apple_swift("libswiftCore", identifier="com.apple.dt.runtime.libswiftUIKit"),
                "runtime identifier",
            ),
            "partial chain": (
                SWIFT_CORE,
                apple_swift("libswiftCore", authorities=("Software Signing", "Apple Root CA")),
                "certificate chain",
            ),
            "not a Swift runtime name": (other_name, apple_swift("libfoo"), "libswift<Name>.dylib"),
            "inside a framework": (in_framework, apple_swift("libswiftCore"), "libswift<Name>.dylib"),
            "outside Frameworks": (in_plugins, apple_swift("libswiftCore"), "libswift<Name>.dylib"),
            "ad-hoc with a team": (
                SWIFT_CORE,
                codesign_output("com.apple.dt.runtime.libswiftCore", adhoc=True, team="59GAB85EFG"),
                "ad-hoc",
            ),
        }
        for name, (path, output, reason) in cases.items():
            with self.subTest(case=name):
                category, problem = ios_signing.classify(path, output, LEGACY, (self.root / path).read_bytes())
                self.assertEqual(category, ios_signing.REJECTED)
                self.assertIn(reason, problem)

    # 8
    def test_expected_apple_swift_runtime_passes(self):
        self.put(SWIFT_CORE, macho(minos="7.0", sdk="12.2"))
        result = ios_signing.classify(
            SWIFT_CORE, apple_swift("libswiftCore"), LEGACY, (self.root / SWIFT_CORE).read_bytes()
        )
        self.assertEqual(result, (ios_signing.APPLE_SWIFT_RUNTIME, None))

    def test_swift_runtime_must_still_fit_ios_12(self):
        for name, data, reason in (
            ("ios 13", macho(minos="13.0"), "requires iOS 13.0"),
            ("simulator", macho(platform=7, minos="7.0"), "ios-simulator"),
            ("no arm64", macho(cputype=CPU_ARMV7, minos="7.0"), "no arm64"),
        ):
            with self.subTest(case=name):
                category, problem = ios_signing.classify(SWIFT_CORE, apple_swift("libswiftCore"), LEGACY, data)
                self.assertEqual(category, ios_signing.REJECTED)
                self.assertIn(reason, problem)
        _, problem = ios_signing.classify(SWIFT_CORE, apple_swift("libswiftCore"), LEGACY, None)
        self.assertIn("deployment target cannot be checked", problem)

    def test_unclassifiable_signature_is_rejected(self):
        for output in ("", "codesign: unexpected output\n", "Format=Mach-O thin (arm64)\n"):
            with self.subTest(output=output):
                category, problem = ios_signing.classify(f"{APP_PATH}/Frameworks/X.framework", output, LEGACY)
                self.assertEqual(category, ios_signing.REJECTED)
                self.assertIn("cannot be classified", problem)

    def test_app_must_be_inspected(self):
        _, problems = ios_signing.classify_inventory(FLUTTER_ITEMS, LEGACY, self.root)
        self.assertIn("Payload/Orvix.app was not inspected", problems)

    # 9, 10
    def test_legacy_ipa_with_ios13_swift_dylib_fails_the_mach_o_gate(self):
        ipa = write_ipa(self.root, LEGACY, binaries={
            "Runner": macho(minos="12.0", filetype=MH_EXECUTE),
            "Frameworks/libswiftCore.dylib": macho(minos="13.0"),
        })
        problems = run_checks(ipa, LEGACY)
        self.assertTrue(any("libswiftCore.dylib [arm64]: requires iOS 13.0" in p for p in problems), problems)

    def test_signable_items_cover_app_bundles_and_dylibs(self):
        for path in (
            f"{APP_PATH}/Runner",
            f"{APP_PATH}/Frameworks/Flutter.framework/Flutter",
            f"{APP_PATH}/Frameworks/Flutter.framework/inner.dylib",
            f"{APP_PATH}/Frameworks/libswiftCore.dylib",
            f"{APP_PATH}/PlugIns/Share.appex/Share",
        ):
            self.put(path, b"x")
        self.assertEqual(
            ios_signing.signable_items(self.root),
            [
                APP_PATH,
                f"{APP_PATH}/Frameworks/Flutter.framework",
                f"{APP_PATH}/Frameworks/libswiftCore.dylib",
                f"{APP_PATH}/PlugIns/Share.appex",
            ],
        )

    def test_verifier_delegates_signing_to_the_policy(self):
        verifier = read("tools/verify_ios_ipa.sh")
        self.assertIn('python3 "$ROOT/tools/ios_signing.py" --profile "$PROFILE" "$WORK"', verifier)
        self.assertIn("embedded\\.mobileprovision", verifier)
        self.assertTrue(LEGACY.allows_embedded_swift_runtime)
        self.assertFalse(MODERN.allows_embedded_swift_runtime)


if __name__ == "__main__":
    unittest.main()
