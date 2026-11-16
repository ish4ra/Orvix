#!/usr/bin/env python3
"""Prepare the upstream stream server to run as Orvix's private macOS helper.

    patch_macos_stream_engine.py <stream-server checkout>

The macOS Free P2P engine is the upstream stream server (see
licenses/stream-server), started by the app with `--no-tray`. This changes
only that headless start-up, so the binary behaves as a helper of one app:

  * no FFmpeg requirement at start-up: Orvix streams the file directly and
    does not use the server's transcoding;
  * listens on 127.0.0.1 only, on the port given in
    ORVIX_STREAM_SERVER_PORT (default 11470), with no HTTPS listener. Nothing
    on the network can reach it, and two Orvix apps on one Mac can each run
    their own engine;
  * no device discovery, update checks or local add-on scan;
  * exits when the app that started it goes away, so a crashed or
    force-quit app cannot leave an engine holding the port.

The patch fails if the upstream code does not look as expected.
"""

from __future__ import annotations

import sys
from pathlib import Path

# The upstream commit this patch is written for (tag v0.1.8).
UPSTREAM_COMMIT = "4f29c489ee38820f80166267ebc71538bf50e63d"

ANCHOR = "    fn run_headless_mode(use_tui: bool)"
OLD = (
    "        let mut cfg = stream_server::ServerConfig::binary_default();\n"
    "        cfg.use_tui = use_tui;\n"
)
NEW = """        let mut cfg = stream_server::ServerConfig::binary_default();
        // Orvix: this binary only runs as a private helper of the Orvix app.
        cfg.setup_ffmpeg = false;
        cfg.enable_ssdp_discovery = false;
        cfg.enable_background_update_checker = false;
        cfg.enable_update_exit = false;
        cfg.enable_local_addon_scan = false;
        let orvix_port = std::env::var("ORVIX_STREAM_SERVER_PORT")
            .ok()
            .and_then(|value| value.trim().parse::<u16>().ok())
            .filter(|port| *port >= 1024)
            .unwrap_or(stream_server::DEFAULT_HTTP_PORT);
        cfg.http_addr = std::net::SocketAddr::from(([127, 0, 0, 1], orvix_port));
        cfg.https_addr = None;
        cfg.public_base_url = Some(format!("http://127.0.0.1:{orvix_port}"));
        // Never outlive the app that started this helper.
        let orvix_parent = std::os::unix::process::parent_id();
        std::thread::spawn(move || loop {
            std::thread::sleep(std::time::Duration::from_secs(2));
            if std::os::unix::process::parent_id() != orvix_parent {
                std::process::exit(0);
            }
        });
        cfg.use_tui = use_tui;
"""


class PatchError(Exception):
    pass


def patch_main(text: str) -> str:
    start = text.find(ANCHOR)
    if start < 0:
        raise PatchError("run_headless_mode was not found in server/src/main.rs.")
    head, tail = text[:start], text[start:]
    if tail.count(OLD) != 1:
        raise PatchError("the headless ServerConfig block is not where it is expected.")
    return head + tail.replace(OLD, NEW, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = Path(sys.argv[1]) / "server" / "src" / "main.rs"
    try:
        path.write_text(patch_main(path.read_text(encoding="utf-8")), encoding="utf-8")
    except (OSError, PatchError) as error:
        print(f"stream engine patch: {error}", file=sys.stderr)
        return 1
    print("Stream engine prepared as an Orvix helper.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
