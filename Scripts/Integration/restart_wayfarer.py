#!/usr/bin/env python3
"""Restart the selected Wayfarer build; backend reset is only for managed tests."""
import os, subprocess, time, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
app = root/"build/Wayfarer.app"
if not app.exists(): app = root/"build/DerivedData/Build/Products/Debug/Wayfarer.app"
flags=sys.argv[1:]
if "--debug-build" in flags:
    app=root/"build/DerivedData/Build/Products/Debug/Wayfarer.app"
    flags.remove("--debug-build")
if "--final-debug-build" in flags:
    app=root/"build/FinalDebug/Build/Products/Debug/Wayfarer.app"
    flags.remove("--final-debug-build")
if flags == ["--quit-only"]:
    subprocess.run(["/usr/bin/osascript","-e",f'tell application "{app}" to quit'],check=True)
    print("Closed this Wayfarer build using its own session cleanup.")
    raise SystemExit(0)
if flags and flags[0]=="--reopen-only" and all(flag in {"--reopen-only","--managed-test","--connect-mac","--steam-panel=mac","--steam-panel=windows","--no-background-steam"} for flag in flags):
    subprocess.run(["/usr/bin/osascript","-e",f'tell application "{app}" to quit'],check=True)
    time.sleep(1)
    subprocess.run(["/usr/bin/open","-n",str(app),"--args","--show-library"] + flags[1:],check=True)
    print("Reopened Wayfarer using its own session cleanup.")
    raise SystemExit(0)
prefix = Path.home()/'Library/Application Support/Wayfarer/Prefixes/crossOver/Wayfarer'
engine = Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver')
env = dict(os.environ, WINEPREFIX=str(prefix), CX_BOTTLE_PATH=str(prefix.parent))
try:
    subprocess.run([str(engine/'bin/wine'),'--bottle','Wayfarer','--cx-app',r'C:\Steam\steam.exe','-shutdown'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
except subprocess.TimeoutExpired:
    pass
# Only this app-owned test prefix; no other Steam bottles or Wine servers.
subprocess.run([str(engine/'bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
time.sleep(3)
subprocess.run(['/usr/bin/osascript','-e','tell application id "app.wayfarer.mac" to quit'],check=False)
time.sleep(1)
if sys.argv[1:] in (['--baseline'],['--baseline-loader']):
    log = open(root/'build/steam-baseline.log','w')
    extra = []
    if sys.argv[1:] == ['--baseline-loader']:
        loader = Path.home()/'Library/Application Support/Wayfarer/NativeEngines/d433055d19f1c6048384eae5/lib/wine/x86_64-unix/wine'
        extra = ['--env', f"'WINELOADER={loader}' 'CX_WINELOADER={loader}'", '--enable-alt-loader','no']
    process = subprocess.Popen([str(engine/'bin/wine')] + extra + ['--bottle','Wayfarer','--cx-app',r'C:\Steam\steam.exe','-cef-disable-gpu','-cef-disable-gpu-compositing'],env=env,stdout=log,stderr=log)
    print('Started Wayfarer-only Steam control without the display adapter:',process.pid)
    raise SystemExit(0)
subprocess.run(['/usr/bin/open','-n',str(app),'--args','--open-steam'],check=True)
print('Reopened Wayfarer with its own Steam installation.')
