#!/usr/bin/env python3
"""Write the dart-defines for a private Watch Party test build.

The test project's address and public key are read from the environment
(ORVIX_TEST_SUPABASE_URL, ORVIX_TEST_SUPABASE_PUBLISHABLE_KEY) and written to
a JSON file for `flutter build --dart-define-from-file`, so they never appear
on a command line or in a log.

The same rules as lib/services/orvix_backend_config.dart are checked here, so
a bad configuration fails the build instead of producing an app that refuses
to start: both values present, a hosted https project address, not the
production project, not the production key, and never a secret or
service-role key.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BACKEND_CONFIG = ROOT / "lib" / "services" / "orvix_backend_config.dart"

URL_ENV = "ORVIX_TEST_SUPABASE_URL"
KEY_ENV = "ORVIX_TEST_SUPABASE_PUBLISHABLE_KEY"

_PROJECT_URL = re.compile(r"^https://([a-z0-9]{16,32})\.supabase\.co/?$")


class ConfigError(Exception):
    pass


def production_backend(source: str | None = None) -> tuple[str, str]:
    """The production address and key the app is built with by default."""
    text = BACKEND_CONFIG.read_text(encoding="utf-8") if source is None else source
    url = re.search(r"productionUrl\s*=\s*'([^']+)'", text)
    key = re.search(r"productionPublishableKey\s*=\s*'([^']+)'", text)
    if url is None or key is None:
        raise ConfigError("could not read the production backend from the app source.")
    return url.group(1), key.group(1)


def project_ref(url: str) -> str | None:
    match = _PROJECT_URL.match(url.strip())
    return match.group(1) if match else None


def _key_problem(key: str, ref: str) -> str | None:
    if key.startswith("sb_secret_"):
        return "the key is a secret key. Use the publishable key."
    if key.startswith("sb_publishable_"):
        if len(key) > len("sb_publishable_") + 8:
            return None
        return "the publishable key is incomplete."
    not_a_key = "the key is not a Supabase publishable or anon key."
    parts = key.split(".")
    if len(parts) != 3:
        return not_a_key
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, UnicodeDecodeError):
        return not_a_key
    if not isinstance(claims, dict):
        return not_a_key
    if claims.get("role") != "anon":
        return "the key is not an anon key. Never use a service-role key."
    if claims.get("ref") != ref:
        return "the key belongs to a different project than the address."
    return None


def test_build_defines(
    url: str, key: str, production: tuple[str, str]
) -> dict[str, str]:
    """The defines for a test build, or ConfigError. Messages never contain
    the values themselves."""
    url, key = url.strip(), key.strip()
    if not url or not key:
        raise ConfigError(
            f"{URL_ENV} and {KEY_ENV} must both be set "
            "(repository secrets; see docs/WATCH_PARTY_TESTING.md)."
        )
    ref = project_ref(url)
    if ref is None:
        raise ConfigError(f"{URL_ENV} must look like https://<project>.supabase.co.")
    if ref == project_ref(production[0]):
        raise ConfigError("a test build must not use the production project.")
    if key == production[1]:
        raise ConfigError("a test build must not use the production key.")
    problem = _key_problem(key, ref)
    if problem is not None:
        raise ConfigError(problem)
    return {
        "ORVIX_TEST_BUILD": "true",
        "ORVIX_WATCH_PARTY": "true",
        "ORVIX_SUPABASE_URL": f"https://{ref}.supabase.co",
        "ORVIX_SUPABASE_PUBLISHABLE_KEY": key,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="JSON file to write")
    args = parser.parse_args()
    try:
        defines = test_build_defines(
            os.environ.get(URL_ENV, ""),
            os.environ.get(KEY_ENV, ""),
            production_backend(),
        )
    except ConfigError as error:
        print(f"Test build configuration: {error}", file=sys.stderr)
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(defines), encoding="utf-8")
    print("Test build defines written (values not shown).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
