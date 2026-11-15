#!/usr/bin/env python3
"""Print the important part of the newest macOS crash report of a process.

    macos_crash_summary.py <process name> [<file to also write it to>]

macOS writes a crash report (.ips) a few seconds after a process dies. This
waits briefly for it, then prints why the process stopped and the top of the
crashed thread, which is what is needed to see the cause in a build log.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

REPORTS = Path.home() / "Library" / "Logs" / "DiagnosticReports"


def newest_report(process: str, wait_seconds: int = 25) -> Path | None:
    prefix = process.replace(" ", "")
    deadline = time.time() + wait_seconds
    while True:
        found = [
            path
            for path in REPORTS.glob("*.ips")
            if path.name.replace(" ", "").startswith(prefix)
        ]
        if found:
            return max(found, key=lambda path: path.stat().st_mtime)
        if time.time() >= deadline:
            return None
        time.sleep(1)


def summarize(text: str, frames: int = 28) -> list[str]:
    """The reason and the crashed thread's top frames from an .ips report."""
    header, _, body = text.partition("\n")
    try:
        report = json.loads(body)
    except json.JSONDecodeError:
        return text.splitlines()[:60]
    lines = []
    try:
        lines.append(f"app: {json.loads(header).get('app_name')}")
    except json.JSONDecodeError:
        pass
    exception = report.get("exception", {})
    lines.append(
        "exception: "
        + " ".join(str(exception.get(key, "")) for key in ("type", "signal", "codes")).strip()
    )
    termination = report.get("termination", {})
    if termination:
        lines.append(f"termination: {termination.get('indicator', termination)}")
    for key in ("asi", "ktriageinfo"):
        if report.get(key):
            lines.append(f"{key}: {json.dumps(report[key])[:1500]}")
    images = report.get("usedImages", [])
    for thread in report.get("threads", []):
        if not thread.get("triggered"):
            continue
        lines.append(f"crashed thread: {thread.get('name') or thread.get('queue') or '?'}")
        for frame in thread.get("frames", [])[:frames]:
            index = frame.get("imageIndex", -1)
            image = images[index].get("name", "?") if 0 <= index < len(images) else "?"
            symbol = frame.get("symbol") or hex(frame.get("imageOffset", 0))
            lines.append(f"  {image}  {symbol}")
    return lines


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    report = newest_report(sys.argv[1])
    if report is None:
        print(f"No crash report for {sys.argv[1]} in {REPORTS}.")
        return 0
    lines = [f"report: {report.name}", *summarize(report.read_text(errors="replace"))]
    print("\n".join(lines))
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
