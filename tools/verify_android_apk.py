"""Static installability gate for Orvix Android APKs.

Gradle succeeding only proves that an APK was produced. This checks the final
APK files the way Android's Package Manager will see them, so a release that
phones would reject ("App not installed as package appears to be invalid")
fails in CI instead of on a user's device.

Usage:
    python3 tools/verify_android_apk.py --build-tools <dir> --flavor mobile \
        [--expected-cert-sha256 <hex>] [--above-legacy-split-version-codes] \
        <apk>=<abi>[,<abi>...] [<apk>=<abi>...]

Every APK passed in one call must be a variant of the same release: they are
required to share package name, versionCode, versionName and signer, so any
of them can replace any other on a device.
"""

from __future__ import annotations

import argparse
import collections
import re
import struct
import subprocess
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

PACKAGE_NAME = "com.orvix.orvix"
SUPPORTED_MIN_SDK = 24

# Flutter's --split-per-abi used to publish each ABI APK with versionCode
# ABI*1000+BUILD (armeabi-v7a 1xxx, arm64-v8a 2xxx, x86_64 4xxx) while the
# universal APK used BUILD. Installing the universal APK over a split one was
# then a versionCode downgrade, which Android reports as "package appears to
# be invalid". The highest versionCode ever published that way was 4205
# (v0.7.9-beta.60 x86_64). Release builds must stay above it so every
# existing installation can still update.
HIGHEST_LEGACY_SPLIT_VERSION_CODE = 4205

ABI_ELF = {
    # abi: (ELF class, e_machine)
    "arm64-v8a": (64, 183),
    "armeabi-v7a": (32, 40),
    "x86_64": (64, 62),
    "x86": (32, 3),
}
# Android 15+ devices may use 16 KB pages; 64-bit libraries must load there.
MIN_LOAD_ALIGN_64 = 16384

REQUIRED_LIBS = (
    "libflutter.so",  # Flutter engine
    "libapp.so",  # Dart AOT snapshot
    "libmpv.so",  # media_kit player
    "libmediakitandroidhelper.so",
    "libstream_server.so",  # Orvix P2P stream engine
    "libc++_shared.so",  # required by libstream_server.so
)

# NDK stable system libraries an app library may link against.
SYSTEM_LIBS = frozenset(
    {
        "libaaudio.so",
        "libamidi.so",
        "libandroid.so",
        "libbinder_ndk.so",
        "libc.so",
        "libcamera2ndk.so",
        "libdl.so",
        "libEGL.so",
        "libGLESv1_CM.so",
        "libGLESv2.so",
        "libGLESv3.so",
        "libjnigraphics.so",
        "liblog.so",
        "libm.so",
        "libmediandk.so",
        "libnativewindow.so",
        "libneuralnetworks.so",
        "libOpenMAXAL.so",
        "libOpenSLES.so",
        "libstdc++.so",
        "libsync.so",
        "libvulkan.so",
        "libz.so",
    }
)

# Features a phone-or-tablet APK may mark as required.
MOBILE_ALLOWED_REQUIRED_FEATURES = frozenset(
    {"android.hardware.faketouch", "android.hardware.touchscreen"}
)

ANDROID_NS = "http://schemas.android.com/apk/res/android"


class Failures(list):
    def add(self, apk: str, message: str) -> None:
        self.append(f"{apk}: {message}")


# --------------------------------------------------------------------------
# ELF


@dataclass
class ElfInfo:
    elf_class: int
    machine: int
    elf_type: int
    load_aligns: list[int] = field(default_factory=list)
    needed: list[str] = field(default_factory=list)
    android_api: int | None = None


def parse_elf(data: bytes) -> ElfInfo:
    if len(data) < 52 or data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    ei_class, ei_data = data[4], data[5]
    if ei_class not in (1, 2):
        raise ValueError(f"unknown ELF class {ei_class}")
    if ei_data != 1:
        raise ValueError("not a little-endian ELF file")
    is64 = ei_class == 2
    if is64:
        (e_type, e_machine, _v, _entry, e_phoff, _shoff, _flags, _ehsize,
         e_phentsize, e_phnum) = struct.unpack_from("<HHIQQQIHHH", data, 16)
        ph_fmt = "<IIQQQQQQ"
    else:
        (e_type, e_machine, _v, _entry, e_phoff, _shoff, _flags, _ehsize,
         e_phentsize, e_phnum) = struct.unpack_from("<HHIIIIIHHH", data, 16)
        ph_fmt = "<IIIIIIII"

    phdrs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + struct.calcsize(ph_fmt) > len(data):
            raise ValueError("truncated program header table")
        raw = struct.unpack_from(ph_fmt, data, off)
        if is64:
            p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz, _memsz, p_align = raw
        else:
            p_type, p_offset, p_vaddr, _paddr, p_filesz, _memsz, _flags, p_align = raw
        phdrs.append((p_type, p_offset, p_vaddr, p_filesz, p_align))

    info = ElfInfo(64 if is64 else 32, e_machine, e_type)
    loads = [p for p in phdrs if p[0] == 1]  # PT_LOAD
    info.load_aligns = [p[4] for p in loads]

    def vaddr_to_offset(vaddr: int) -> int | None:
        for _t, p_offset, p_vaddr, p_filesz, _a in loads:
            if p_vaddr <= vaddr < p_vaddr + p_filesz:
                return p_offset + (vaddr - p_vaddr)
        return None

    for p_type, p_offset, _vaddr, p_filesz, _align in phdrs:
        if p_type == 2:  # PT_DYNAMIC
            entry = "<qQ" if is64 else "<iI"
            size = struct.calcsize(entry)
            strtab = None
            needed_offsets = []
            for pos in range(p_offset, p_offset + p_filesz, size):
                tag, val = struct.unpack_from(entry, data, pos)
                if tag == 0:
                    break
                if tag == 1:  # DT_NEEDED
                    needed_offsets.append(val)
                elif tag == 5:  # DT_STRTAB
                    strtab = vaddr_to_offset(val)
            if needed_offsets and strtab is None:
                raise ValueError("DT_NEEDED present without a readable DT_STRTAB")
            for off in needed_offsets:
                start = strtab + off
                end = data.index(b"\0", start)
                info.needed.append(data[start:end].decode())
        elif p_type == 4:  # PT_NOTE
            pos, end = p_offset, p_offset + p_filesz
            while pos + 12 <= end:
                namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
                name_start = pos + 12
                desc_start = name_start + ((namesz + 3) & ~3)
                name = data[name_start:name_start + namesz].rstrip(b"\0")
                if name == b"Android" and ntype == 1 and descsz >= 4:
                    info.android_api = struct.unpack_from("<I", data, desc_start)[0]
                pos = desc_start + ((descsz + 3) & ~3)
    return info


def check_native_libs(
    apk: str,
    zf: zipfile.ZipFile,
    expected_abis: list[str],
    min_sdk: int,
    extract_native_libs: bool,
    failures: Failures,
) -> None:
    by_abi: dict[str, dict[str, zipfile.ZipInfo]] = collections.defaultdict(dict)
    for info in zf.infolist():
        parts = info.filename.split("/")
        if parts[0] != "lib" or info.filename.endswith("/"):
            continue
        if len(parts) != 3:
            failures.add(apk, f"unexpected native library path {info.filename}")
            continue
        by_abi[parts[1]][parts[2]] = info

    if sorted(by_abi) != sorted(expected_abis):
        failures.add(
            apk,
            f"native ABIs {sorted(by_abi)} do not match expected {sorted(expected_abis)}",
        )

    for abi in expected_abis:
        libs = by_abi.get(abi, {})
        for required in REQUIRED_LIBS:
            if required not in libs:
                failures.add(apk, f"lib/{abi}/{required} is missing")
        want_class, want_machine = ABI_ELF[abi]
        for name, info in sorted(libs.items()):
            path = f"lib/{abi}/{name}"
            if not name.endswith(".so"):
                failures.add(apk, f"{path} is not a shared library")
                continue
            if info.file_size == 0:
                failures.add(apk, f"{path} is empty")
                continue
            if not extract_native_libs and info.compress_type != zipfile.ZIP_STORED:
                failures.add(
                    apk,
                    f"{path} is compressed but extractNativeLibs is false",
                )
            try:
                elf = parse_elf(zf.read(info))
            except (ValueError, struct.error) as error:
                failures.add(apk, f"{path} is not a valid ELF library: {error}")
                continue
            if (elf.elf_class, elf.machine) != (want_class, want_machine):
                failures.add(
                    apk,
                    f"{path} is ELF{elf.elf_class} machine {elf.machine}, "
                    f"expected ELF{want_class} machine {want_machine} for {abi}",
                )
            if elf.elf_type != 3:  # ET_DYN
                failures.add(apk, f"{path} is not a shared object (e_type {elf.elf_type})")
            if not elf.load_aligns:
                failures.add(apk, f"{path} has no loadable segments")
            elif want_class == 64 and min(elf.load_aligns) < MIN_LOAD_ALIGN_64:
                failures.add(
                    apk,
                    f"{path} LOAD alignment {min(elf.load_aligns)} is below "
                    f"{MIN_LOAD_ALIGN_64} (16 KB page devices)",
                )
            if elf.android_api is not None and elf.android_api > min_sdk:
                failures.add(
                    apk,
                    f"{path} targets Android API {elf.android_api}, above minSdk {min_sdk}",
                )
            for dep in elf.needed:
                if dep not in libs and dep not in SYSTEM_LIBS:
                    failures.add(apk, f"{path} needs {dep}, which is not in lib/{abi}/")


# --------------------------------------------------------------------------
# Zip container


def check_zip(apk: str, zf: zipfile.ZipFile, raw: bytes, failures: Failures) -> None:
    names = [i.filename for i in zf.infolist()]
    dupes = sorted(n for n, c in collections.Counter(names).items() if c > 1)
    if dupes:
        failures.add(apk, f"duplicate zip entries: {dupes[:5]}")
    for required in ("AndroidManifest.xml", "classes.dex", "resources.arsc"):
        if required not in names:
            failures.add(apk, f"{required} is missing")
    bad = zf.testzip()
    if bad is not None:
        failures.add(apk, f"corrupt zip entry {bad}")

    # Android 11+ refuses APKs targeting API 30+ whose resources.arsc is
    # compressed or not 4-byte aligned.
    if "resources.arsc" in names:
        info = zf.getinfo("resources.arsc")
        if info.compress_type != zipfile.ZIP_STORED:
            failures.add(apk, "resources.arsc is compressed")
        else:
            off = info.header_offset
            name_len, extra_len = struct.unpack_from("<HH", raw, off + 26)
            if (off + 30 + name_len + extra_len) % 4:
                failures.add(apk, "resources.arsc is not 4-byte aligned")


# --------------------------------------------------------------------------
# Manifest (aapt2 output)


@dataclass
class Badging:
    package: str = ""
    version_code: int = -1
    version_name: str = ""
    min_sdk: int = -1
    target_sdk: int = -1
    native_code: list[str] = field(default_factory=list)
    alt_native_code: list[str] = field(default_factory=list)
    required_features: list[str] = field(default_factory=list)
    launchable: bool = False
    leanback_launchable: bool = False
    debuggable: bool = False


def parse_badging(text: str) -> Badging:
    b = Badging()
    for line in text.splitlines():
        stripped = line.strip()
        if line.startswith("package:"):
            b.package = re.search(r"name='([^']*)'", line).group(1)
            b.version_code = int(re.search(r"versionCode='(\d+)'", line).group(1))
            b.version_name = re.search(r"versionName='([^']*)'", line).group(1)
        elif line.startswith("sdkVersion:"):
            b.min_sdk = int(re.search(r"'(\d+)'", line).group(1))
        elif line.startswith("targetSdkVersion:"):
            b.target_sdk = int(re.search(r"'(\d+)'", line).group(1))
        elif line.startswith("native-code:"):
            b.native_code = re.findall(r"'([^']+)'", line)
        elif line.startswith("alt-native-code:"):
            b.alt_native_code = re.findall(r"'([^']+)'", line)
        elif stripped.startswith("uses-feature:"):
            b.required_features.append(re.search(r"name='([^']+)'", stripped).group(1))
        elif line.startswith("launchable-activity:"):
            b.launchable = True
        elif line.startswith("leanback-launchable-activity:"):
            b.leanback_launchable = True
        elif line.startswith("application-debuggable"):
            b.debuggable = True
    return b


@dataclass
class XmlElement:
    name: str
    attrs: dict[str, str] = field(default_factory=dict)
    children: list["XmlElement"] = field(default_factory=list)

    def iter(self):
        yield self
        for child in self.children:
            yield from child.iter()


def parse_xmltree(text: str) -> XmlElement:
    """Parse `aapt2 dump xmltree` output into a small element tree."""
    root = XmlElement("#document")
    stack: list[tuple[int, XmlElement]] = [(-1, root)]
    for line in text.splitlines():
        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()
        if body.startswith("E: "):
            name = body[3:].split(" ", 1)[0]
            while stack[-1][0] >= indent:
                stack.pop()
            element = XmlElement(name)
            stack[-1][1].children.append(element)
            stack.append((indent, element))
        elif body.startswith("A: "):
            match = re.match(r"A: (?:(\S+?):)?([\w-]+)(?:\(0x[0-9a-fA-F]+\))?=(.*)$", body)
            if not match:
                continue
            ns, attr, value = match.groups()
            key = f"android:{attr}" if ns in (ANDROID_NS, "android") else attr
            value = re.sub(r" \(Raw: .*\)$", "", value).strip()
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            stack[-1][1].attrs[key] = value
    return root


def _is_true(value: str | None) -> bool:
    return value is not None and value.lower() in ("true", "0xffffffff", "(type 0x12)0xffffffff")


def check_manifest(
    apk: str, tree: XmlElement, flavor: str, target_sdk: int, failures: Failures
) -> bool:
    """Returns the effective android:extractNativeLibs value."""
    application = next((e for e in tree.iter() if e.name == "application"), None)
    if application is None:
        failures.add(apk, "manifest has no <application>")
        return True
    if _is_true(application.attrs.get("android:testOnly")):
        failures.add(apk, "android:testOnly is true (Package Manager rejects it)")
    extract = application.attrs.get("android:extractNativeLibs")
    # Absent means true for minSdk < 23 builds; Orvix always writes it.
    extract_native_libs = extract is None or _is_true(extract)

    if target_sdk >= 31:
        for component in application.children:
            if component.name not in ("activity", "activity-alias", "service", "receiver"):
                continue
            has_filter = any(c.name == "intent-filter" for c in component.children)
            if has_filter and "android:exported" not in component.attrs:
                failures.add(
                    apk,
                    f"{component.name} {component.attrs.get('android:name')} has an "
                    "intent-filter but no android:exported (rejected on Android 12+)",
                )

    if flavor == "mobile":
        for element in tree.iter():
            if element.name == "category" and element.attrs.get("android:name") == (
                "android.intent.category.LEANBACK_LAUNCHER"
            ):
                failures.add(apk, "Android Mobile manifest contains LEANBACK_LAUNCHER")
    return extract_native_libs


# --------------------------------------------------------------------------
# SDK tools


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def check_signature(
    apk: str, apksigner: Path, failures: Failures
) -> str | None:
    result = run([str(apksigner), "verify", "--verbose", "--print-certs", apk])
    out = result.stdout + result.stderr
    if result.returncode != 0 or not re.search(r"^Verifies$", out, re.M):
        failures.add(apk, f"apksigner verification failed:\n{out.strip()}")
        return None
    schemes = {
        s: re.search(rf"Verified using {s} scheme[^:]*: true", out) is not None
        for s in ("v2", "v3")
    }
    if not any(schemes.values()):
        failures.add(apk, "APK is not signed with APK Signature Scheme v2 or v3")
    signers = re.search(r"Number of signers: (\d+)", out)
    if not signers or signers.group(1) != "1":
        failures.add(apk, "APK must have exactly one signer")
    certs = set(re.findall(r"certificate SHA-256 digest: ([0-9a-f]{64})", out))
    if len(certs) != 1:
        failures.add(apk, f"expected one signing certificate, found {len(certs)}")
        return None
    return certs.pop()


def check_zipalign(apk: str, zipalign: Path, failures: Failures) -> None:
    result = run([str(zipalign), "-c", "-p", "4", apk])
    if result.returncode != 0:
        failures.add(apk, "zipalign -c -p 4 failed:\n" + (result.stdout + result.stderr)[-2000:])


# --------------------------------------------------------------------------


def find_tool(build_tools: Path, name: str) -> Path:
    path = build_tools / name
    if not path.exists():
        raise SystemExit(f"{name} not found in {build_tools}")
    return path


def verify(args: argparse.Namespace) -> int:
    build_tools = Path(args.build_tools)
    apksigner = find_tool(build_tools, "apksigner")
    aapt2 = find_tool(build_tools, "aapt2")
    zipalign = find_tool(build_tools, "zipalign")

    failures = Failures()
    identities = {}
    for spec in args.apks:
        apk, sep, abis = spec.partition("=")
        if not sep or not abis:
            raise SystemExit(f"expected <apk>=<abi>[,<abi>...], got {spec!r}")
        expected_abis = abis.split(",")
        unknown = [a for a in expected_abis if a not in ABI_ELF]
        if unknown:
            raise SystemExit(f"unknown ABI(s) {unknown}")
        if not Path(apk).is_file() or Path(apk).stat().st_size == 0:
            failures.add(apk, "file is missing or empty")
            continue

        raw = Path(apk).read_bytes()
        try:
            zf = zipfile.ZipFile(apk)
        except zipfile.BadZipFile as error:
            failures.add(apk, f"not a valid zip archive: {error}")
            continue
        with zf:
            check_zip(apk, zf, raw, failures)
            check_zipalign(apk, zipalign, failures)
            cert = check_signature(apk, apksigner, failures)

            badging_run = run([str(aapt2), "dump", "badging", apk])
            if badging_run.returncode != 0:
                failures.add(apk, f"aapt2 dump badging failed: {badging_run.stderr.strip()}")
                continue
            badging = parse_badging(badging_run.stdout)
            xml_run = run(
                [str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", apk]
            )
            if xml_run.returncode != 0:
                failures.add(apk, f"aapt2 dump xmltree failed: {xml_run.stderr.strip()}")
                continue
            tree = parse_xmltree(xml_run.stdout)

            if badging.package != args.package:
                failures.add(apk, f"package is {badging.package!r}, expected {args.package!r}")
            if not 0 < badging.min_sdk <= SUPPORTED_MIN_SDK:
                failures.add(apk, f"minSdk {badging.min_sdk} is above supported {SUPPORTED_MIN_SDK}")
            if badging.target_sdk < badging.min_sdk:
                failures.add(apk, f"targetSdk {badging.target_sdk} is below minSdk")
            if sorted(badging.native_code) != sorted(expected_abis) or badging.alt_native_code:
                failures.add(
                    apk,
                    f"native-code {badging.native_code} (alt {badging.alt_native_code}) "
                    f"does not match expected {expected_abis}",
                )
            if badging.debuggable:
                failures.add(apk, "release APK is debuggable")
            if not badging.launchable:
                failures.add(apk, "no launchable activity")
            if (
                args.above_legacy_split_version_codes
                and badging.version_code <= HIGHEST_LEGACY_SPLIT_VERSION_CODE
            ):
                failures.add(
                    apk,
                    f"versionCode {badging.version_code} must be above "
                    f"{HIGHEST_LEGACY_SPLIT_VERSION_CODE} so installs of older ABI-specific "
                    "APKs can update; raise +BUILD in pubspec.yaml",
                )
            if args.flavor == "mobile":
                if badging.leanback_launchable:
                    failures.add(apk, "Android Mobile APK has a leanback launcher activity")
                forbidden = sorted(
                    set(badging.required_features) - MOBILE_ALLOWED_REQUIRED_FEATURES
                )
                if forbidden:
                    failures.add(apk, f"phones would be filtered by required features {forbidden}")

            extract_native_libs = check_manifest(
                apk, tree, args.flavor, badging.target_sdk, failures
            )
            check_native_libs(
                apk, zf, expected_abis, badging.min_sdk, extract_native_libs, failures
            )

        identities[apk] = (badging.package, badging.version_code, badging.version_name, cert)
        print(
            f"{apk}: {badging.package} versionCode={badging.version_code} "
            f"versionName={badging.version_name} minSdk={badging.min_sdk} "
            f"targetSdk={badging.target_sdk} abis={','.join(badging.native_code)} "
            f"cert={cert}"
        )

    # Every variant of one release must be able to replace every other one.
    if len(set(identities.values())) > 1:
        detail = "\n".join(f"  {apk}: {ident}" for apk, ident in identities.items())
        failures.append(
            "APK variants differ in package, versionCode, versionName or signer:\n" + detail
        )
    if args.expected_cert_sha256:
        expected = args.expected_cert_sha256.lower()
        for apk, (_p, _vc, _vn, cert) in identities.items():
            if cert is not None and cert != expected:
                failures.add(apk, f"signing certificate {cert} is not the Orvix certificate {expected}")

    if failures:
        print("\nAndroid APK installability check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1
    print("Android APK installability check passed.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--build-tools", required=True, help="Android SDK build-tools directory")
    parser.add_argument("--flavor", choices=("mobile", "tv"), required=True)
    parser.add_argument("--package", default=PACKAGE_NAME)
    parser.add_argument("--expected-cert-sha256")
    parser.add_argument(
        "--above-legacy-split-version-codes",
        action="store_true",
        help="require versionCode above every versionCode published by old ABI APKs",
    )
    parser.add_argument("apks", nargs="+", metavar="APK=ABI[,ABI...]")
    return verify(parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
