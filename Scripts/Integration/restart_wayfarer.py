#!/usr/bin/env python3
"""Restart a Wayfarer build using its own graceful cleanup."""
import subprocess, time, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
app = root / "build/Wayfarer.app"
flags = sys.argv[1:]
for flag, directory in [("--debug-build", "DerivedData"), ("--final-debug-build", "FinalDebug"), ("--features-debug-build", "FeaturesDebug")]:
    if flag in flags:
        app = root / f"build/{directory}/Build/Products/Debug/Wayfarer.app"
        flags.remove(flag)
if not app.exists(): raise SystemExit("Build Wayfarer first.")
subprocess.run(["/usr/bin/osascript", "-e", f'tell application "{app}" to quit'], check=True)
if flags == ["--quit-only"]:
    print("Closed Wayfarer using its own session cleanup.")
    raise SystemExit(0)
flags = [flag for flag in flags if flag != "--reopen-only"]
time.sleep(1)
subprocess.run(["/usr/bin/open", "-n", str(app), "--args"] + flags, check=True)
print("Reopened Wayfarer.")
