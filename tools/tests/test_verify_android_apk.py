import io
import os
import stat
import struct
import sys
import tempfile
import textwrap
import unittest
import zipfile
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import verify_android_apk as v  # noqa: E402

ARM64 = (64, 183)
ARM32 = (32, 40)
X86_64 = (64, 62)


def make_elf(machine=ARM64, needed=(), align=16384, api=24, elf_type=3):
    """Build a minimal little-endian shared object with dynamic and note data."""
    elf_class, e_machine = machine
    is64 = elf_class == 64
    strtab = b"\0" + b"".join(n.encode() + b"\0" for n in needed)
    offsets = []
    pos = 1
    for name in needed:
        offsets.append(pos)
        pos += len(name) + 1
    dyn_entry = "<qQ" if is64 else "<iI"
    dynamic = b"".join(struct.pack(dyn_entry, 1, o) for o in offsets)
    note = b""
    if api is not None:
        desc = struct.pack("<I", api) + b"\0" * 4
        note = struct.pack("<III", 8, len(desc), 1) + b"Android\0" + desc

    ehsize = 64 if is64 else 52
    phentsize = 56 if is64 else 32
    phnum = 3
    data_start = ehsize + phentsize * phnum
    strtab_off = data_start
    dynamic_off = strtab_off + len(strtab)
    dynamic += struct.pack(dyn_entry, 5, strtab_off)  # DT_STRTAB (vaddr == offset)
    dynamic += struct.pack(dyn_entry, 0, 0)
    note_off = dynamic_off + len(dynamic)
    total = note_off + len(note)

    ident = b"\x7fELF" + bytes([2 if is64 else 1, 1, 1]) + b"\0" * 9
    if is64:
        header = ident + struct.pack(
            "<HHIQQQIHHHHHH", elf_type, e_machine, 1, 0, ehsize, 0, 0,
            ehsize, phentsize, phnum, 0, 0, 0,
        )
        ph = lambda t, off, size, al: struct.pack(  # noqa: E731
            "<IIQQQQQQ", t, 5, off, off, off, size, size, al
        )
    else:
        header = ident + struct.pack(
            "<HHIIIIIHHHHHH", elf_type, e_machine, 1, 0, ehsize, 0, 0,
            ehsize, phentsize, phnum, 0, 0, 0,
        )
        ph = lambda t, off, size, al: struct.pack(  # noqa: E731
            "<IIIIIIII", t, off, off, off, size, size, 5, al
        )
    phdrs = ph(1, 0, total, align) + ph(2, dynamic_off, len(dynamic), 8)
    phdrs += ph(4, note_off, len(note), 4)
    return header + phdrs + strtab + dynamic + note


def required_libs(machine=ARM64, **overrides):
    libs = {name: make_elf(machine) for name in v.REQUIRED_LIBS}
    libs["libstream_server.so"] = make_elf(machine, needed=("libc++_shared.so", "libc.so"))
    libs.update(overrides)
    return libs


def make_zip(entries, arsc_compressed=False):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("AndroidManifest.xml", b"manifest", zipfile.ZIP_DEFLATED)
        zf.writestr("classes.dex", b"dex\n037\0", zipfile.ZIP_DEFLATED)
        arsc = zipfile.ZipInfo("resources.arsc")
        arsc.compress_type = zipfile.ZIP_DEFLATED if arsc_compressed else zipfile.ZIP_STORED
        # Pad with an Android alignment extra field, as zipalign does.
        data_offset = buf.tell() + 30 + len(arsc.filename) + 4
        arsc.extra = struct.pack("<HHH", 0xD935, 2, 4) + b"\0" * (-(data_offset + 2) % 4)
        arsc.extra = struct.pack("<HH", 0xD935, len(arsc.extra) - 4) + arsc.extra[4:]
        zf.writestr(arsc, b"arsc")
        for name, data in entries.items():
            zf.writestr(name, data, zipfile.ZIP_DEFLATED)
    return buf.getvalue()


def native_failures(libs_by_abi, expected, extract=True):
    entries = {
        f"lib/{abi}/{name}": data
        for abi, libs in libs_by_abi.items()
        for name, data in libs.items()
    }
    failures = v.Failures()
    with zipfile.ZipFile(io.BytesIO(make_zip(entries))) as zf:
        v.check_native_libs("app.apk", zf, expected, 24, extract, failures)
    return failures


class ElfTest(unittest.TestCase):
    def test_parses_class_machine_alignment_needed_and_api(self):
        info = v.parse_elf(make_elf(ARM64, needed=("libc++_shared.so", "liblog.so"), api=24))
        self.assertEqual((info.elf_class, info.machine, info.elf_type), (64, 183, 3))
        self.assertEqual(info.load_aligns, [16384])
        self.assertEqual(info.needed, ["libc++_shared.so", "liblog.so"])
        self.assertEqual(info.android_api, 24)

    def test_parses_32_bit_arm(self):
        info = v.parse_elf(make_elf(ARM32, needed=("libm.so",), align=4096, api=21))
        self.assertEqual((info.elf_class, info.machine), (32, 40))
        self.assertEqual(info.needed, ["libm.so"])

    def test_rejects_non_elf(self):
        with self.assertRaises(ValueError):
            v.parse_elf(b"PK\x03\x04" + b"\0" * 60)


class NativeLibsTest(unittest.TestCase):
    def test_valid_arm64_payload_passes(self):
        self.assertEqual(native_failures({"arm64-v8a": required_libs()}, ["arm64-v8a"]), [])

    def test_universal_payload_passes(self):
        failures = native_failures(
            {
                "arm64-v8a": required_libs(ARM64),
                # 32-bit libraries only need 4 KB alignment.
                "armeabi-v7a": {n: make_elf(ARM32, align=4096) for n in v.REQUIRED_LIBS},
                "x86_64": required_libs(X86_64),
            },
            ["arm64-v8a", "armeabi-v7a", "x86_64"],
        )
        self.assertEqual(failures, [])

    def test_wrong_architecture_in_arm64_dir_fails(self):
        failures = native_failures(
            {"arm64-v8a": required_libs(**{"libmpv.so": make_elf(X86_64)})}, ["arm64-v8a"]
        )
        self.assertTrue(any("libmpv.so is ELF64 machine 62" in f for f in failures), failures)

    def test_zero_byte_library_fails(self):
        failures = native_failures(
            {"arm64-v8a": required_libs(**{"libflutter.so": b""})}, ["arm64-v8a"]
        )
        self.assertTrue(any("libflutter.so is empty" in f for f in failures), failures)

    def test_missing_stream_engine_fails(self):
        libs = required_libs()
        del libs["libstream_server.so"]
        failures = native_failures({"arm64-v8a": libs}, ["arm64-v8a"])
        self.assertTrue(any("libstream_server.so is missing" in f for f in failures), failures)

    def test_missing_media_player_fails(self):
        libs = required_libs()
        del libs["libmpv.so"]
        failures = native_failures({"arm64-v8a": libs}, ["arm64-v8a"])
        self.assertTrue(any("libmpv.so is missing" in f for f in failures), failures)

    def test_unresolved_dependency_fails(self):
        libs = required_libs()
        del libs["libc++_shared.so"]
        failures = native_failures({"arm64-v8a": libs}, ["arm64-v8a"])
        self.assertTrue(
            any("needs libc++_shared.so" in f for f in failures), failures
        )

    def test_4k_aligned_64_bit_library_fails(self):
        failures = native_failures(
            {"arm64-v8a": required_libs(**{"libmpv.so": make_elf(align=4096)})}, ["arm64-v8a"]
        )
        self.assertTrue(any("LOAD alignment 4096" in f for f in failures), failures)

    def test_library_above_min_sdk_fails(self):
        failures = native_failures(
            {"arm64-v8a": required_libs(**{"libmpv.so": make_elf(api=29)})}, ["arm64-v8a"]
        )
        self.assertTrue(any("targets Android API 29" in f for f in failures), failures)

    def test_split_missing_abi_or_extra_abi_fails(self):
        failures = native_failures(
            {"arm64-v8a": required_libs(), "x86": required_libs((32, 3))}, ["arm64-v8a"]
        )
        self.assertTrue(any("do not match expected" in f for f in failures), failures)

    def test_compressed_libs_require_extract_native_libs(self):
        failures = native_failures({"arm64-v8a": required_libs()}, ["arm64-v8a"], extract=False)
        self.assertTrue(any("extractNativeLibs is false" in f for f in failures), failures)


class ZipTest(unittest.TestCase):
    def test_compressed_resources_arsc_fails(self):
        raw = make_zip({}, arsc_compressed=True)
        failures = v.Failures()
        with zipfile.ZipFile(io.BytesIO(raw)) as zf:
            v.check_zip("app.apk", zf, raw, failures)
        self.assertTrue(any("resources.arsc is compressed" in f for f in failures), failures)


MOBILE_BADGING = textwrap.dedent(
    """\
    package: name='com.orvix.orvix' versionCode='205' versionName='0.7.9-beta.60' platformBuildVersionName='16'
    sdkVersion:'24'
    targetSdkVersion:'36'
    launchable-activity: name='com.orvix.orvix.MainActivity'  label='' icon=''
    feature-group: label=''
      uses-feature-not-required: name='android.hardware.camera'
      uses-feature: name='android.hardware.faketouch'
      uses-implied-feature: name='android.hardware.faketouch' reason='default feature for all apps'
    native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'
    """
)

TV_BADGING = MOBILE_BADGING.replace(
    "feature-group",
    "leanback-launchable-activity: name='com.orvix.orvix.MainActivity'\nfeature-group",
).replace(
    "  uses-feature: name='android.hardware.faketouch'",
    "  uses-feature: name='android.software.leanback'\n"
    "  uses-feature: name='android.hardware.faketouch'",
)

MANIFEST_XMLTREE = textwrap.dedent(
    """\
    N: android=http://schemas.android.com/apk/res/android (line=2)
      E: manifest (line=2)
        A: http://schemas.android.com/apk/res/android:versionCode(0x0101021b)=205
        A: package="com.orvix.orvix" (Raw: "com.orvix.orvix")
          E: application (line=50)
            A: http://schemas.android.com/apk/res/android:label(0x01010001)="Orvix" (Raw: "Orvix")
            A: http://schemas.android.com/apk/res/android:extractNativeLibs(0x010104ea)=true
              E: activity (line=57)
                A: http://schemas.android.com/apk/res/android:name(0x01010003)="com.orvix.orvix.MainActivity" (Raw: "com.orvix.orvix.MainActivity")
                A: http://schemas.android.com/apk/res/android:exported(0x01010010)=true
                  E: intent-filter (line=72)
                      E: action (line=73)
                        A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.intent.action.MAIN" (Raw: "android.intent.action.MAIN")
                      E: category (line=74)
                        A: http://schemas.android.com/apk/res/android:name(0x01010003)="android.intent.category.LAUNCHER" (Raw: "android.intent.category.LAUNCHER")
    """
)


class ManifestTest(unittest.TestCase):
    def test_parses_mobile_badging(self):
        b = v.parse_badging(MOBILE_BADGING)
        self.assertEqual(b.package, "com.orvix.orvix")
        self.assertEqual(b.version_code, 205)
        self.assertEqual((b.min_sdk, b.target_sdk), (24, 36))
        self.assertEqual(b.native_code, ["arm64-v8a", "armeabi-v7a", "x86_64"])
        self.assertEqual(b.required_features, ["android.hardware.faketouch"])
        self.assertTrue(b.launchable)
        self.assertFalse(b.leanback_launchable)

    def test_detects_tv_only_badging(self):
        b = v.parse_badging(TV_BADGING)
        self.assertTrue(b.leanback_launchable)
        self.assertIn("android.software.leanback", b.required_features)

    def test_valid_mobile_manifest_passes(self):
        failures = v.Failures()
        extract = v.check_manifest(
            "app.apk", v.parse_xmltree(MANIFEST_XMLTREE), "mobile", 36, failures
        )
        self.assertEqual(failures, [])
        self.assertTrue(extract)

    def test_leanback_launcher_in_mobile_fails(self):
        xml = MANIFEST_XMLTREE + (
            "                  E: category (line=75)\n"
            '                    A: http://schemas.android.com/apk/res/android:name(0x01010003)='
            '"android.intent.category.LEANBACK_LAUNCHER" (Raw: "android.intent.category.LEANBACK_LAUNCHER")\n'
        )
        failures = v.Failures()
        v.check_manifest("app.apk", v.parse_xmltree(xml), "mobile", 36, failures)
        self.assertTrue(any("LEANBACK_LAUNCHER" in f for f in failures), failures)
        failures = v.Failures()
        v.check_manifest("app.apk", v.parse_xmltree(xml), "tv", 36, failures)
        self.assertEqual(failures, [])

    def test_missing_exported_on_android_12_target_fails(self):
        xml = MANIFEST_XMLTREE.replace(
            "            A: http://schemas.android.com/apk/res/android:exported(0x01010010)=true\n", ""
        )
        failures = v.Failures()
        v.check_manifest("app.apk", v.parse_xmltree(xml), "mobile", 36, failures)
        self.assertTrue(any("no android:exported" in f for f in failures), failures)

    def test_test_only_fails_and_extract_false_is_reported(self):
        xml = MANIFEST_XMLTREE.replace("extractNativeLibs(0x010104ea)=true", "extractNativeLibs(0x010104ea)=false")
        xml = xml.replace(
            '        A: http://schemas.android.com/apk/res/android:label',
            "        A: http://schemas.android.com/apk/res/android:testOnly(0x01010272)=true\n"
            '        A: http://schemas.android.com/apk/res/android:label',
        )
        failures = v.Failures()
        extract = v.check_manifest("app.apk", v.parse_xmltree(xml), "mobile", 36, failures)
        self.assertFalse(extract)
        self.assertTrue(any("testOnly" in f for f in failures), failures)


class EndToEndTest(unittest.TestCase):
    """Runs verify() with stub SDK tools that report canned results."""

    CERT = "ab" * 32

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.tools = self.dir / "build-tools"
        self.tools.mkdir()
        self._stub("zipalign", "exit 0")
        self._stub(
            "apksigner",
            "cat <<'EOF'\nVerifies\n"
            "Verified using v2 scheme (APK Signature Scheme v2): true\n"
            "Verified using v3 scheme (APK Signature Scheme v3): true\n"
            "Number of signers: 1\n"
            f"Signer #1 certificate SHA-256 digest: {self.CERT}\nEOF",
        )
        # aapt2 prints the badging/xmltree text stored next to the APK.
        self._stub(
            "aapt2",
            'apk="${@: -1}"\n'
            'if [ "$2" = badging ]; then cat "$apk.badging"; else cat "$apk.xmltree"; fi',
        )

    def tearDown(self):
        self.tmp.cleanup()

    def _stub(self, name, body):
        path = self.tools / name
        path.write_text("#!/usr/bin/env bash\n" + body + "\n")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _apk(self, name, version_code, abis):
        libs = {"arm64-v8a": required_libs(ARM64), "x86_64": required_libs(X86_64)}
        entries = {
            f"lib/{abi}/{lib}": data for abi in abis for lib, data in libs[abi].items()
        }
        apk = self.dir / name
        apk.write_bytes(make_zip(entries))
        badging = MOBILE_BADGING.replace("versionCode='205'", f"versionCode='{version_code}'")
        badging = badging.replace(
            "native-code: 'arm64-v8a' 'armeabi-v7a' 'x86_64'",
            "native-code: " + " ".join(f"'{a}'" for a in abis),
        )
        Path(f"{apk}.badging").write_text(badging)
        Path(f"{apk}.xmltree").write_text(MANIFEST_XMLTREE)
        return f"{apk}={','.join(abis)}"

    def _verify(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = v.main(["--build-tools", str(self.tools), "--flavor", "mobile", *args])
        return code, out.getvalue() + err.getvalue()

    def test_matching_variants_pass(self):
        code, output = self._verify(
            "--expected-cert-sha256", self.CERT,
            "--above-legacy-split-version-codes",
            self._apk("universal.apk", 4206, ["arm64-v8a", "x86_64"]),
            self._apk("arm64.apk", 4206, ["arm64-v8a"]),
        )
        self.assertEqual(code, 0, output)

    def test_split_versioncode_offset_fails(self):
        # The published v0.7.9-beta.60 shape: universal 205, arm64 split 2205.
        code, output = self._verify(
            self._apk("universal.apk", 205, ["arm64-v8a", "x86_64"]),
            self._apk("arm64.apk", 2205, ["arm64-v8a"]),
        )
        self.assertEqual(code, 1)
        self.assertIn("differ in package, versionCode", output)

    def test_versioncode_below_legacy_split_floor_fails(self):
        code, output = self._verify(
            "--above-legacy-split-version-codes",
            self._apk("universal.apk", 4205, ["arm64-v8a", "x86_64"]),
        )
        self.assertEqual(code, 1)
        self.assertIn("versionCode 4205 must be above 4205", output)

    def test_wrong_certificate_fails(self):
        code, output = self._verify(
            "--expected-cert-sha256", "cd" * 32,
            self._apk("universal.apk", 4206, ["arm64-v8a", "x86_64"]),
        )
        self.assertEqual(code, 1)
        self.assertIn("is not the Orvix certificate", output)

    def test_truncated_download_fails(self):
        apk = self.dir / "truncated.apk"
        full = make_zip({"lib/arm64-v8a/libapp.so": make_elf()})
        apk.write_bytes(full[: len(full) // 2])
        code, output = self._verify(f"{apk}=arm64-v8a")
        self.assertEqual(code, 1)
        self.assertIn("not a valid zip archive", output)


if __name__ == "__main__":
    unittest.main()
