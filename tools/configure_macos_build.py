#!/usr/bin/env python3
"""Give the generated macOS app the network access Orvix needs.

`flutter create` produces a sandboxed macOS app whose release entitlements
allow nothing but the sandbox itself. Such an app cannot open any network
connection: no catalog, no sign-in, no streams. Orvix needs to make outgoing
connections and to serve its own local playback bridge on 127.0.0.1.

The sandbox stays on. Only these two entitlements are added:

  com.apple.security.network.client   outgoing connections
  com.apple.security.network.server   listening sockets (local bridge)

Run after `flutter create --platforms=macos` and before `flutter build`.
"""

from __future__ import annotations

import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

ENTITLEMENT_FILES = (
    "macos/Runner/Release.entitlements",
    "macos/Runner/DebugProfile.entitlements",
)
SANDBOX = "com.apple.security.app-sandbox"
NETWORK_ENTITLEMENTS = (
    "com.apple.security.network.client",
    "com.apple.security.network.server",
)


def with_network_access(entitlements: dict) -> dict:
    """The entitlements with network access added. The sandbox must already
    be on; this never turns it on or off."""
    if entitlements.get(SANDBOX) is not True:
        raise ValueError(f"{SANDBOX} is expected to be on in the generated project.")
    updated = dict(entitlements)
    for key in NETWORK_ENTITLEMENTS:
        updated[key] = True
    return updated


def main() -> int:
    for relative in ENTITLEMENT_FILES:
        path = ROOT / relative
        if not path.exists():
            print(f"macOS build: {relative} does not exist.", file=sys.stderr)
            return 1
        try:
            updated = with_network_access(plistlib.loads(path.read_bytes()))
        except (ValueError, plistlib.InvalidFileException) as error:
            print(f"macOS build: {relative}: {error}", file=sys.stderr)
            return 1
        path.write_bytes(plistlib.dumps(updated, fmt=plistlib.FMT_XML, sort_keys=True))
    print("macOS entitlements: sandbox kept, network client and server allowed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
