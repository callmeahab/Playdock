#!/usr/bin/env python3
"""Run an isolated CrossOver notepad through Playdock's native display adapter."""
from pathlib import Path
import os, secrets, shutil, subprocess, sys, time
ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'build/native-probe'
WORK.mkdir(parents=True, exist_ok=True)
adapter = ROOT / 'build/Playdock.app/Contents/Frameworks/libPlaydockWineDisplay.dylib'
if not adapter.is_file():
    raise SystemExit('Build Playdock with Scripts/build.sh before running the display probe.')
# Rebuild both sides together to keep the IPC handshake compatible.
toolchain = dict(os.environ, DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer'))
subprocess.run(['/usr/bin/xcrun','clang','-fobjc-arc','-fblocks','-framework','Cocoa','-framework','QuartzCore',str(ROOT/'Scripts/Integration/DisplayProbe.m'),'-o',str(WORK/'DisplayProbe')],env=toolchain,check=True)
shutil.copy2(adapter, WORK/'WineDisplay.dylib')
ENGINE = Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver')
PREFIXES = WORK / 'Prefixes'
PREFIXES.mkdir(exist_ok=True)
env = dict(os.environ, CX_BOTTLE_PATH=str(PREFIXES), PLAYDOCK_DISPLAY_SOCKET=str(WORK/'display.sock'), PLAYDOCK_DISPLAY_TOKEN=secrets.token_hex(32))
if (WORK/'display.sock').exists(): (WORK/'display.sock').unlink()
loader = WORK/'engine/lib/wine/x86_64-unix'
loader.mkdir(parents=True,exist_ok=True)
for entry in (ENGINE/'lib/wine/x86_64-unix').iterdir():
    destination = loader / entry.name
    if entry.name == 'ntdll.so' and destination.is_symlink(): destination.unlink()
    if not destination.exists():
        if entry.name in ('wine', 'ntdll.so'): shutil.copy2(entry,destination)
        else: destination.symlink_to(entry)
for entry in (ENGINE/'lib/wine').iterdir():
    destination = loader.parent / entry.name
    if not destination.exists(): destination.symlink_to(entry)
for directory in ('share', 'bin'):
    destination = WORK/'engine'/directory
    if not destination.exists(): destination.symlink_to(ENGINE/directory)
subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(loader/'wine')],check=True)
if not (PREFIXES/'PlaydockProbe/cxbottle.conf').exists():
    subprocess.run([str(ENGINE/'bin/cxbottle'),'--bottle','PlaydockProbe','--create','--template','win10_64'],env=env,check=True,stdout=(WORK/'create.log').open('w'),stderr=subprocess.STDOUT)
native = sys.argv[1:] == ['--native']
if sys.argv[1:] and not native: raise SystemExit('Usage: run_probe.py [--native]')
if native: env['PLAYDOCK_GAME_PRESENTATION'] = 'native'
host = subprocess.Popen([str(WORK/'DisplayProbe'),str(WORK/'display.sock')] + (['--native'] if native else []),stdout=(WORK/'host.log').open('w'),stderr=subprocess.STDOUT)
for _ in range(100):
    if (WORK/'display.sock').exists(): break
    time.sleep(.1)
restore = f'WINELOADER={loader/"wine"} CX_WINELOADER={loader/"wine"} DYLD_INSERT_LIBRARIES={WORK/"WineDisplay.dylib"}'
wine = subprocess.Popen([str(ENGINE/'bin/wine'),'--bottle','PlaydockProbe','--env',restore,'--enable-alt-loader','no','--wait-children','notepad.exe'],env=env,stdout=(WORK/'wine.log').open('w'),stderr=subprocess.STDOUT)
(WORK/'processes').write_text(f'{host.pid}\n{wine.pid}\n')
print(f'Native display host PID {host.pid}; isolated Wine launcher PID {wine.pid}. Logs: {WORK}')
print('Checking native game presentation.' if native else 'Waiting for the isolated display test. Close the probe window when finished.', flush=True)
try:
    for _ in range(30 if native else 900):
        if host.poll() is not None or wine.poll() is not None:
            print(f'host={host.poll()} wine={wine.poll()}', flush=True)
            break
        time.sleep(1)
finally:
    if host.poll() is None: host.terminate()
    if wine.poll() is None: wine.terminate()
    subprocess.run([str(ENGINE/'bin/wineserver'),'-k'],env=dict(os.environ,WINEPREFIX=str(PREFIXES/'PlaydockProbe')),check=False)

if native:
    if 'NATIVE_POLICY_PASSED' not in (WORK/'host.log').read_text():
        raise SystemExit('Native window presentation did not arrive. See the isolated probe logs.')
    print('Native presentation passed; the non-Steam child was not embedded.')
