#!/usr/bin/env python3
"""Inspect the Mach-O binaries inside an Orvix iOS app bundle or IPA.

Info.plist MinimumOSVersion only states what the app claims. iOS refuses to
load a binary whose own load commands demand a newer OS, so the Legacy iOS
gate reads every executable, framework and dylib that ships in the IPA and
checks what each one actually encodes:

- architectures (fat and thin slices);
- the iOS deployment target (LC_BUILD_VERSION / LC_VERSION_MIN_IPHONEOS);
- simulator-only slices (platform iOS Simulator, or x86/x86_64 code);
- strong links to system frameworks or Swift runtime libraries that do not
  exist on the claimed iOS version.

The parser is pure Python so the same checks run in unit tests on Linux and
in CI on macOS, where tools/verify_ios_legacy_ipa.sh also cross-checks the
result with Apple's otool/vtool/lipo.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import struct
import sys
import tempfile
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM = 0xCEFAEDFE
MH_CIGAM_64 = 0xCFFAEDFE

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_CODE_SIGNATURE = 0x1D
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_VERSION_MIN_TVOS = 0x2F
LC_VERSION_MIN_WATCHOS = 0x30
LC_BUILD_VERSION = 0x32

STRONG_DYLIB_COMMANDS = {LC_LOAD_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB}

MH_EXECUTE = 0x2
MH_DYLIB = 0x6
MH_BUNDLE = 0x8

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_X86 = 7
CPU_TYPE_ARM = 12
CPU_TYPE_X86_64 = CPU_TYPE_X86 | CPU_ARCH_ABI64
CPU_TYPE_ARM64 = CPU_TYPE_ARM | CPU_ARCH_ABI64
CPU_SUBTYPE_MASK = 0xFF000000
CPU_SUBTYPE_ARM64E = 2

PLATFORM_MACOS = 1
PLATFORM_IOS = 2
PLATFORM_TVOS = 3
PLATFORM_WATCHOS = 4
PLATFORM_MACCATALYST = 6
PLATFORM_IOSSIMULATOR = 7
PLATFORM_TVOSSIMULATOR = 8
PLATFORM_WATCHOSSIMULATOR = 9
PLATFORM_NAMES = {
    PLATFORM_MACOS: "macos",
    PLATFORM_IOS: "ios",
    PLATFORM_TVOS: "tvos",
    PLATFORM_WATCHOS: "watchos",
    PLATFORM_MACCATALYST: "maccatalyst",
    PLATFORM_IOSSIMULATOR: "ios-simulator",
    PLATFORM_TVOSSIMULATOR: "tvos-simulator",
    PLATFORM_WATCHOSSIMULATOR: "watchos-simulator",
    10: "driverkit",
    11: "visionos",
    12: "visionos-simulator",
}
VERSION_MIN_PLATFORMS = {
    LC_VERSION_MIN_MACOSX: PLATFORM_MACOS,
    LC_VERSION_MIN_IPHONEOS: PLATFORM_IOS,
    LC_VERSION_MIN_TVOS: PLATFORM_TVOS,
    LC_VERSION_MIN_WATCHOS: PLATFORM_WATCHOS,
}

# System libraries that first shipped in the listed iOS release. A strong
# (non-weak) link to one of these makes dyld abort at launch on older iOS,
# whatever the binary's own deployment target says. Weak links are fine.
SYSTEM_LIBRARY_MIN_IOS: dict[str, tuple[int, ...]] = {
    # Frameworks introduced in iOS 13.
    "/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks": (13, 0),
    "/System/Library/Frameworks/Combine.framework/Combine": (13, 0),
    "/System/Library/Frameworks/CoreHaptics.framework/CoreHaptics": (13, 0),
    "/System/Library/Frameworks/CryptoKit.framework/CryptoKit": (13, 0),
    "/System/Library/Frameworks/LinkPresentation.framework/LinkPresentation": (13, 0),
    "/System/Library/Frameworks/MetricKit.framework/MetricKit": (13, 0),
    "/System/Library/Frameworks/PencilKit.framework/PencilKit": (13, 0),
    "/System/Library/Frameworks/QuickLookThumbnailing.framework/QuickLookThumbnailing": (13, 0),
    "/System/Library/Frameworks/RealityKit.framework/RealityKit": (13, 0),
    "/System/Library/Frameworks/SoundAnalysis.framework/SoundAnalysis": (13, 0),
    "/System/Library/Frameworks/SwiftUI.framework/SwiftUI": (13, 0),
    "/System/Library/Frameworks/VisionKit.framework/VisionKit": (13, 0),
    # Frameworks introduced in iOS 14.
    "/System/Library/Frameworks/AppClip.framework/AppClip": (14, 0),
    "/System/Library/Frameworks/AppTrackingTransparency.framework/AppTrackingTransparency": (14, 0),
    "/System/Library/Frameworks/MLCompute.framework/MLCompute": (14, 0),
    "/System/Library/Frameworks/NearbyInteraction.framework/NearbyInteraction": (14, 0),
    "/System/Library/Frameworks/ScreenTime.framework/ScreenTime": (14, 0),
    "/System/Library/Frameworks/UniformTypeIdentifiers.framework/UniformTypeIdentifiers": (14, 0),
    "/System/Library/Frameworks/WidgetKit.framework/WidgetKit": (14, 0),
    # Frameworks introduced in iOS 15+.
    "/System/Library/Frameworks/GroupActivities.framework/GroupActivities": (15, 0),
    "/System/Library/Frameworks/SharedWithYou.framework/SharedWithYou": (16, 0),
    # Swift runtime libraries that only ship with newer iOS releases.
    "/usr/lib/swift/libswift_Concurrency.dylib": (15, 0),
    "/usr/lib/swift/libswift_StringProcessing.dylib": (16, 0),
    "/usr/lib/swift/libswift_RegexParser.dylib": (16, 0),
    "/usr/lib/swift/libswiftObservation.dylib": (17, 0),
    "/usr/lib/swift/libswiftSynchronization.dylib": (18, 0),
}
# The Swift standard library itself is part of iOS from 12.2. iOS 12.0/12.1
# need it embedded in the app, so @rpath links resolve to Frameworks/.
SWIFT_RUNTIME_IN_OS_SINCE = (12, 2)


class MachOError(ValueError):
    """Raised when a file that should be Mach-O cannot be parsed."""


@dataclass
class Slice:
    arch: str
    filetype: int
    platform: str | None = None
    minos: str | None = None
    sdk: str | None = None
    signed: bool = False
    strong_dylibs: list[str] = field(default_factory=list)
    weak_dylibs: list[str] = field(default_factory=list)


@dataclass
class Binary:
    path: str
    slices: list[Slice]

    @property
    def archs(self) -> list[str]:
        return [item.arch for item in self.slices]


def decode_version(value: int) -> str:
    """Decode Mach-O's xxxx.yy.zz nibble-packed version as X.Y[.Z]."""
    major, minor, patch = value >> 16, (value >> 8) & 0xFF, value & 0xFF
    return f"{major}.{minor}.{patch}" if patch else f"{major}.{minor}"


def parse_version(value: str) -> tuple[int, ...]:
    parts = value.strip().split(".")
    if not parts or not all(part.isdigit() for part in parts):
        raise ValueError(f"invalid version: {value!r}")
    numbers = [int(part) for part in parts]
    while len(numbers) > 1 and numbers[-1] == 0:
        numbers.pop()
    return tuple(numbers)


def arch_name(cputype: int, cpusubtype: int) -> str:
    if cputype == CPU_TYPE_ARM64:
        return "arm64e" if cpusubtype & ~CPU_SUBTYPE_MASK == CPU_SUBTYPE_ARM64E else "arm64"
    if cputype == CPU_TYPE_ARM:
        return "armv7"
    if cputype == CPU_TYPE_X86_64:
        return "x86_64"
    if cputype == CPU_TYPE_X86:
        return "i386"
    return f"cpu{cputype:#x}"


def is_macho(data: bytes) -> bool:
    if len(data) < 4:
        return False
    big = struct.unpack(">I", data[:4])[0]
    little = struct.unpack("<I", data[:4])[0]
    if big in (FAT_MAGIC, FAT_MAGIC_64):
        # Java class files share 0xCAFEBABE; a real fat header has few archs.
        return len(data) >= 8 and 0 < struct.unpack(">I", data[4:8])[0] < 32
    return little in (MH_MAGIC, MH_MAGIC_64) or big in (MH_MAGIC, MH_MAGIC_64)


def _parse_thin(data: bytes, offset: int) -> Slice:
    if len(data) < offset + 28:
        raise MachOError("truncated Mach-O header")
    magic_le = struct.unpack_from("<I", data, offset)[0]
    if magic_le in (MH_MAGIC, MH_MAGIC_64):
        endian = "<"
        magic = magic_le
    else:
        magic = struct.unpack_from(">I", data, offset)[0]
        if magic not in (MH_MAGIC, MH_MAGIC_64):
            raise MachOError(f"bad Mach-O magic {magic_le:#x}")
        endian = ">"
    cputype, cpusubtype, filetype, ncmds, sizeofcmds = struct.unpack_from(
        endian + "iIIII", data, offset + 4
    )
    header = 32 if magic == MH_MAGIC_64 else 28
    item = Slice(arch=arch_name(cputype & 0xFFFFFFFF, cpusubtype), filetype=filetype)
    cursor = offset + header
    end = cursor + sizeofcmds
    if end > len(data):
        raise MachOError("load commands exceed file size")
    for _ in range(ncmds):
        if cursor + 8 > end:
            raise MachOError("truncated load command")
        cmd, cmdsize = struct.unpack_from(endian + "II", data, cursor)
        if cmdsize < 8 or cursor + cmdsize > end:
            raise MachOError(f"invalid load command size {cmdsize}")
        if cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from(endian + "III", data, cursor + 8)
            item.platform = PLATFORM_NAMES.get(platform, f"platform{platform}")
            item.minos = decode_version(minos)
            item.sdk = decode_version(sdk)
        elif cmd in VERSION_MIN_PLATFORMS:
            version, sdk = struct.unpack_from(endian + "II", data, cursor + 8)
            platform = VERSION_MIN_PLATFORMS[cmd]
            # Before LC_BUILD_VERSION, simulator slices used the device
            # command and were told apart only by their Intel CPU type.
            if platform == PLATFORM_IOS and item.arch in ("x86_64", "i386"):
                platform = PLATFORM_IOSSIMULATOR
            item.platform = PLATFORM_NAMES[platform]
            item.minos = decode_version(version)
            item.sdk = decode_version(sdk)
        elif cmd == LC_CODE_SIGNATURE:
            item.signed = True
        elif cmd in STRONG_DYLIB_COMMANDS or cmd in (LC_LOAD_WEAK_DYLIB, LC_LAZY_LOAD_DYLIB):
            name_offset = struct.unpack_from(endian + "I", data, cursor + 8)[0]
            raw = data[cursor + name_offset:cursor + cmdsize]
            name = raw.split(b"\0", 1)[0].decode("utf-8", "replace")
            if cmd in STRONG_DYLIB_COMMANDS:
                item.strong_dylibs.append(name)
            else:
                item.weak_dylibs.append(name)
        cursor += cmdsize
    return item


def parse_macho(data: bytes, path: str = "<memory>") -> Binary:
    if len(data) < 8:
        raise MachOError(f"{path}: too small to be Mach-O")
    magic = struct.unpack(">I", data[:4])[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack(">I", data[4:8])[0]
        entry = 32 if magic == FAT_MAGIC_64 else 20
        slices = []
        for index in range(count):
            base = 8 + index * entry
            if magic == FAT_MAGIC_64:
                _, _, offset, size = struct.unpack_from(">iIQQ", data, base)
            else:
                _, _, offset, size = struct.unpack_from(">iIII", data, base)
            if offset + size > len(data):
                raise MachOError(f"{path}: fat slice {index} exceeds file size")
            slices.append(_parse_thin(data, offset))
        return Binary(path=path, slices=slices)
    try:
        return Binary(path=path, slices=[_parse_thin(data, 0)])
    except MachOError as exc:
        raise MachOError(f"{path}: {exc}") from None


def scan_app(app: Path) -> list[Binary]:
    """Return every Mach-O file inside an .app bundle, sorted by path."""
    binaries = []
    for root, _, files in os.walk(app):
        for name in sorted(files):
            full = Path(root) / name
            if full.is_symlink() or not full.is_file():
                continue
            with full.open("rb") as handle:
                head = handle.read(8)
            if not is_macho(head):
                continue
            data = full.read_bytes()
            binaries.append(parse_macho(data, full.relative_to(app.parent).as_posix()))
    return sorted(binaries, key=lambda item: item.path)


def _embedded_dylibs(binaries: list[Binary]) -> set[str]:
    return {Path(item.path).name for item in binaries}


def check_binaries(
    binaries: list[Binary],
    max_min_ios: str,
    main_executable: str,
) -> list[str]:
    """Return human-readable problems; an empty list means compatible."""
    limit = parse_version(max_min_ios)
    problems: list[str] = []
    embedded = _embedded_dylibs(binaries)
    paths = {item.path for item in binaries}
    if main_executable not in paths:
        problems.append(f"main executable {main_executable} is missing or not Mach-O")

    for binary in binaries:
        if not binary.slices:
            problems.append(f"{binary.path}: no architecture slices")
            continue
        if "arm64" not in binary.archs:
            problems.append(
                f"{binary.path}: no arm64 device slice (archs: {' '.join(binary.archs)})"
            )
        for item in binary.slices:
            label = f"{binary.path} [{item.arch}]"
            if item.arch in ("x86_64", "i386"):
                problems.append(f"{label}: Intel simulator code must not ship in a device IPA")
            if item.platform is None or item.minos is None:
                problems.append(f"{label}: no deployment target load command")
                continue
            if item.platform != "ios":
                problems.append(f"{label}: built for {item.platform}, not iOS devices")
                continue
            if parse_version(item.minos) > limit:
                problems.append(
                    f"{label}: requires iOS {item.minos}, above the supported iOS {max_min_ios}"
                )
            for dylib in item.strong_dylibs:
                needs = _strong_link_minimum(dylib, embedded)
                if needs is not None and needs > limit:
                    problems.append(
                        f"{label}: strongly links {dylib}, which needs iOS "
                        f"{'.'.join(map(str, needs))}"
                    )
    return problems


def _strong_link_minimum(dylib: str, embedded: set[str]) -> tuple[int, ...] | None:
    if dylib in SYSTEM_LIBRARY_MIN_IOS:
        return SYSTEM_LIBRARY_MIN_IOS[dylib]
    if dylib.startswith("@rpath/libswift") and dylib.endswith(".dylib"):
        name = dylib.split("/", 1)[1]
        if name in embedded:
            return None
        system = f"/usr/lib/swift/{name}"
        return SYSTEM_LIBRARY_MIN_IOS.get(system, SWIFT_RUNTIME_IN_OS_SINCE)
    return None


def inventory(binaries: list[Binary]) -> list[dict]:
    rows = []
    for binary in binaries:
        for item in binary.slices:
            rows.append(
                {
                    "path": binary.path,
                    "arch": item.arch,
                    "platform": item.platform,
                    "minos": item.minos,
                    "sdk": item.sdk,
                    "signed": item.signed,
                }
            )
    return rows


def format_inventory(binaries: list[Binary]) -> str:
    rows = inventory(binaries)
    width = max((len(row["path"]) for row in rows), default=4)
    lines = [f"{'binary'.ljust(width)}  arch    platform        minOS   sdk"]
    for row in rows:
        lines.append(
            f"{row['path'].ljust(width)}  {row['arch']:<7} {str(row['platform']):<15} "
            f"{str(row['minos']):<7} {row['sdk']}"
        )
    return "\n".join(lines)


def highest_minos(binaries: list[Binary]) -> str | None:
    values = [
        item.minos
        for binary in binaries
        for item in binary.slices
        if item.platform == "ios" and item.minos
    ]
    return max(values, key=parse_version) if values else None


def _app_from_ipa(ipa: Path, work: Path) -> Path:
    with zipfile.ZipFile(ipa) as archive:
        archive.extractall(work)
    apps = sorted((work / "Payload").glob("*.app"))
    if len(apps) != 1:
        raise MachOError(f"{ipa}: expected exactly one Payload/*.app, found {len(apps)}")
    return apps[0]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("bundle", type=Path, help=".ipa file or .app directory")
    parser.add_argument(
        "--max-min-ios",
        required=True,
        help="highest iOS deployment target any shipped binary may require",
    )
    parser.add_argument("--json", type=Path, help="write the inventory as JSON")
    args = parser.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="orvix-macho.") as temporary:
        if args.bundle.is_dir():
            app = args.bundle
        else:
            app = _app_from_ipa(args.bundle, Path(temporary))
        info_path = app / "Info.plist"
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable:
            print("error: Info.plist has no CFBundleExecutable", file=sys.stderr)
            return 1
        binaries = scan_app(app)
        main_path = f"{app.name}/{executable}"
        print(format_inventory(binaries))
        print(
            f"\n{len(binaries)} Mach-O binaries; highest iOS deployment target "
            f"{highest_minos(binaries)}; allowed {args.max_min_ios}"
        )
        if args.json:
            args.json.write_text(json.dumps(inventory(binaries), indent=2) + "\n", encoding="utf-8")
        problems = check_binaries(binaries, args.max_min_ios, main_path)

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
