#!/usr/bin/env python3
"""Restart a Playdock build using its own graceful cleanup."""
import argparse
import subprocess
import time
from pathlib import Path
root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--app', type=Path, default=root / 'build/Playdock.app', help='Built Playdock app to open.')
parser.add_argument('--quit-only', action='store_true')
options, flags = parser.parse_known_args()
app = options.app.expanduser().resolve()
if not app.exists(): raise SystemExit("Build Playdock first.")
running = 'application id "app.playdock.mac" is running'
subprocess.run(["/usr/bin/osascript", "-e", f'if {running} then tell application id "app.playdock.mac" to quit'], check=True)
for _ in range(50):
    if subprocess.check_output(["/usr/bin/osascript", "-e", running], text=True).strip() == 'false': break
    time.sleep(.2)
else: raise SystemExit('Playdock has not finished closing.')
if options.quit_only:
    print("Closed Playdock using its own session cleanup.")
    raise SystemExit(0)
subprocess.run(["/usr/bin/open", "-n", str(app), "--args"] + flags, check=True)
print("Reopened Playdock.")
