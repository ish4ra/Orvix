#!/usr/bin/env python3
"""Classify the code signatures inside an Orvix unsigned sideload IPA.

tools/verify_ios_ipa.sh records `codesign -dv --verbose=4` for the app
bundle and every nested framework, app extension and dylib, then this
module decides, one item at a time, whether the signature is acceptable:

- Payload/Orvix.app itself must be unsigned. Any signature on it (Apple
  Development, Apple Distribution, App Store, ad-hoc, ...) is rejected, so a
  sideload tool can sign it with the user's own identity.
- Nested items may be unsigned, or ad-hoc signed by Flutter's toolchain
  (Signature=adhoc, no certificate, TeamIdentifier not set).
- Legacy only: Swift runtime libraries that Xcode embeds for deployment
  targets below iOS 12.2 keep Apple's own signature. They are accepted only
  at Payload/Orvix.app/Frameworks/libswift<Name>.dylib, with Apple's runtime
  identifier, Apple's software-signing certificate chain, Apple's team
  identifier, and an arm64 iOS slice that fits the Legacy target.
- Anything else, including any other certificate or team, or output that
  cannot be parsed, is rejected.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ios_macho import MachOError, parse_macho, parse_version  # noqa: E402
from ios_profiles import PROFILES, IosProfile, get_profile  # noqa: E402

APP = "Payload/Orvix.app"

# Apple signs the Swift runtime libraries that ship inside Xcode with the
# same chain and team it uses for its own software. Observed on every
# libswift*.dylib that Xcode 16.4 embedded in the Legacy IPA.
APPLE_SOFTWARE_SIGNING_CHAIN = (
    "Software Signing",
    "Apple Code Signing Certification Authority",
    "Apple Root CA",
)
APPLE_RUNTIME_TEAM_ID = "59GAB85EFG"
SWIFT_RUNTIME_PATH = re.compile(rf"^{re.escape(APP)}/Frameworks/(libswift[A-Za-z0-9_]+)\.dylib$")

# Identities that make Orvix.app a developer- or store-signed app.
DEVELOPER_IDENTITY = re.compile(
    r"^(Apple Development|Apple Distribution|iPhone Developer|iPhone Distribution|"
    r"Apple iPhone OS Application Signing|Developer ID Application)\b"
)

UNSIGNED = "unsigned"
ADHOC = "adhoc"
APPLE_SWIFT_RUNTIME = "apple-swift-runtime"
REJECTED = "rejected"


@dataclass
class Signature:
    signed: bool
    identifier: str | None = None
    format: str | None = None
    adhoc: bool = False
    authorities: list[str] = field(default_factory=list)
    team_id: str | None = None


def parse_codesign(output: str) -> Signature:
    """Parse `codesign -dv` output. Raises ValueError if it is not usable."""
    if "code object is not signed at all" in output:
        return Signature(signed=False)
    fields: dict[str, list[str]] = {}
    for line in output.splitlines():
        key, sep, value = line.partition("=")
        if sep and re.fullmatch(r"[A-Za-z]+", key):
            fields.setdefault(key, []).append(value.strip())
    identifier = fields.get("Identifier", [None])[0]
    if not identifier:
        raise ValueError("codesign output has no Identifier and no 'not signed' marker")
    team = fields.get("TeamIdentifier", [None])[0]
    return Signature(
        signed=True,
        identifier=identifier,
        format=fields.get("Format", [None])[0],
        adhoc="adhoc" in fields.get("Signature", []),
        authorities=fields.get("Authority", []),
        team_id=None if team in (None, "not set") else team,
    )


def _describe(sig: Signature) -> str:
    parts = [f"Identifier={sig.identifier}"]
    parts += [f"Authority={authority}" for authority in sig.authorities]
    parts.append(f"TeamIdentifier={sig.team_id or 'not set'}")
    if sig.adhoc:
        parts.append("Signature=adhoc")
    return " ".join(parts)


def _swift_runtime_problem(
    path: str, sig: Signature, profile: IosProfile, binary: bytes | None
) -> str | None:
    """Return None if this is a confirmed Apple Swift runtime dylib."""
    match = SWIFT_RUNTIME_PATH.fullmatch(path)
    if match is None:
        return "not at Payload/Orvix.app/Frameworks/libswift<Name>.dylib"
    if not profile.allows_embedded_swift_runtime:
        return f"the {profile.name} build never embeds Swift runtime libraries"
    if sig.adhoc:
        return "ad-hoc signed, not Apple-signed"
    if sig.identifier != f"com.apple.dt.runtime.{match.group(1)}":
        return f"identifier {sig.identifier!r} is not Apple's runtime identifier for {match.group(1)}"
    if tuple(sig.authorities) != APPLE_SOFTWARE_SIGNING_CHAIN:
        return f"certificate chain {sig.authorities} is not Apple's software-signing chain"
    if sig.team_id != APPLE_RUNTIME_TEAM_ID:
        return f"team {sig.team_id!r} is not Apple's runtime team {APPLE_RUNTIME_TEAM_ID}"
    if binary is None:
        return "binary is missing, so its deployment target cannot be checked"
    try:
        slices = parse_macho(binary, path).slices
    except MachOError as exc:
        return f"not a readable Mach-O file ({exc})"
    if "arm64" not in [item.arch for item in slices]:
        return "has no arm64 slice"
    for item in slices:
        if item.platform != "ios" or item.minos is None:
            return f"{item.arch} slice is built for {item.platform}, not iOS devices"
        if parse_version(item.minos) > parse_version(profile.min_ios):
            return f"{item.arch} slice requires iOS {item.minos}, above iOS {profile.min_ios}"
    return None


def classify(
    path: str,
    codesign_output: str,
    profile: IosProfile,
    binary: bytes | None = None,
) -> tuple[str, str | None]:
    """Return (category, problem). problem is None when the item is accepted."""
    try:
        sig = parse_codesign(codesign_output)
    except ValueError as exc:
        return REJECTED, f"{path}: signature cannot be classified ({exc})"

    if path == APP:
        if not sig.signed:
            return UNSIGNED, None
        identity = next((a for a in sig.authorities if DEVELOPER_IDENTITY.match(a)), None)
        kind = f"with '{identity}'" if identity else f"({_describe(sig)})"
        return REJECTED, f"{path} is code signed {kind}; the sideload IPA must ship it unsigned"

    if not path.startswith(f"{APP}/"):
        return REJECTED, f"{path}: outside Payload/Orvix.app"
    if not sig.signed:
        return UNSIGNED, None
    if sig.adhoc and not sig.authorities and sig.team_id is None:
        return ADHOC, None
    problem = _swift_runtime_problem(path, sig, profile, binary)
    if problem is None:
        return APPLE_SWIFT_RUNTIME, None
    return REJECTED, f"{path} is signed with a certificate or team identity ({_describe(sig)}): {problem}"


def classify_inventory(
    inventory: dict[str, str],
    profile: IosProfile,
    root: Path | None = None,
) -> tuple[dict[str, list[str]], list[str]]:
    """Classify every recorded item. Returns (paths by category, problems)."""
    groups: dict[str, list[str]] = {UNSIGNED: [], ADHOC: [], APPLE_SWIFT_RUNTIME: [], REJECTED: []}
    problems = []
    if APP not in inventory:
        problems.append(f"{APP} was not inspected")
    for path in sorted(inventory):
        binary = None
        if root is not None and path.endswith(".dylib") and (root / path).is_file():
            binary = (root / path).read_bytes()
        category, problem = classify(path, inventory[path], profile, binary)
        groups[category].append(path)
        if problem:
            problems.append(problem)
    return groups, problems


def signable_items(root: Path) -> list[str]:
    """Orvix.app plus every nested framework, app extension and dylib.

    Bundles are not descended into: codesign checks a bundle as one unit.
    """
    app = root / APP
    items = [APP]
    for current, dirs, files in os.walk(app):
        here = Path(current)
        for name in sorted(dirs):
            if name.endswith((".framework", ".appex")):
                items.append((here / name).relative_to(root).as_posix())
        dirs[:] = sorted(d for d in dirs if not d.endswith((".framework", ".appex")))
        items += [
            (here / name).relative_to(root).as_posix()
            for name in sorted(files)
            if name.endswith(".dylib")
        ]
    return sorted(set(items))


def collect_inventory(root: Path) -> dict[str, str]:
    """Run `codesign -dv --verbose=4` on every signable item (macOS only)."""
    inventory = {}
    for item in signable_items(root):
        result = subprocess.run(
            ["codesign", "-dv", "--verbose=4", str(root / item)],
            capture_output=True,
            text=True,
        )
        inventory[item] = result.stdout + result.stderr
    return inventory


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--profile", required=True, choices=sorted(PROFILES))
    parser.add_argument("root", type=Path, help="extracted IPA directory that contains Payload/")
    parser.add_argument("--save-inventory", type=Path, help="also write the raw codesign output as JSON")
    args = parser.parse_args(argv)

    profile = get_profile(args.profile)
    inventory = collect_inventory(args.root)
    if args.save_inventory:
        args.save_inventory.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
    groups, problems = classify_inventory(inventory, profile, args.root)

    print(f"Code signing inventory ({profile.name}):")
    for path in sorted(inventory):
        try:
            sig = parse_codesign(inventory[path])
            detail = _describe(sig) if sig.signed else "not signed"
        except ValueError:
            detail = "unparseable codesign output"
        print(f"  {path}: {detail}")
    summary = (
        f"{APP}: {'not signed' if APP in groups[UNSIGNED] else 'SIGNED'}\n"
        f"Unsigned nested items: {len([p for p in groups[UNSIGNED] if p != APP])}\n"
        f"Ad-hoc signed (no certificate, TeamIdentifier not set): "
        f"{', '.join(p.removeprefix(APP + '/') for p in groups[ADHOC]) or 'none'}\n"
        f"Apple-signed Swift runtime libraries (team {APPLE_RUNTIME_TEAM_ID}): "
        f"{', '.join(p.removeprefix(APP + '/Frameworks/') for p in groups[APPLE_SWIFT_RUNTIME]) or 'none'}\n"
        f"Rejected: {len(groups[REJECTED]) + (APP not in inventory)}"
    )
    print(summary)
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::notice title=IPA codesign summary ({profile.name})::" + summary.replace("\n", "%0A"))
    for problem in problems:
        if os.environ.get("GITHUB_ACTIONS"):
            print(f"::error title=iOS {profile.name} IPA signing::{problem}", flush=True)
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
