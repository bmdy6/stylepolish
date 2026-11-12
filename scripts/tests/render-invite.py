#!/usr/bin/env python3
"""Render production invite views against an owned loopback fake; no app bundle or UI."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parents[2]
output = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / "docs/acceptance/invite"
server = subprocess.Popen(
    [sys.executable, "-u", str(root / "scripts/tests/invite-fake-server.py")],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
)
try:
    port = int(server.stdout.readline().strip())
    subprocess.run(
        [str(root / ".build/debug/StylePolish"), "--render-invite", str(output), f"http://127.0.0.1:{port}"],
        cwd=root, timeout=45, check=True,
    )
finally:
    # Terminate only the exact child this script started.
    server.terminate()
    server.wait(timeout=5)
