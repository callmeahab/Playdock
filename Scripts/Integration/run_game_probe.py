#!/usr/bin/env python3
"""Launch an installed Steam game and check its native window; leave it running."""
from pathlib import Path
import argparse, os, subprocess, time
parser = argparse.ArgumentParser()
parser.add_argument('--app-id', required=True, help='Steam app ID to launch.')
parser.add_argument('--game', required=True, type=Path, help='Installed Windows game executable.')
parser.add_argument('--verify-only', action='store_true', help='Check an existing game without sending another launch request.')
options = parser.parse_args()
ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'build/GamePresentationReview'
WORK.mkdir(parents=True, exist_ok=True)
STEAM = Path.home() / 'Library/Application Support/Steam'
GAME = options.game.expanduser().resolve()
if not options.app_id.isdecimal() or not 0 < int(options.app_id) <= 0xffffffff:
    raise SystemExit('Use a valid Steam app ID.')
if not GAME.is_file() :
    raise SystemExit('The installed test game in the Mac Steam library was not found.')
def processes():
    return [(int(line.split(None,2)[0]), line.split(None,2)[2]) for line in subprocess.check_output(['ps','-eo','pid,ppid,comm'],text=True).splitlines()[1:] if len(line.split(None,2)) == 3]
game_name = GAME.name.lower()
existing = [pid for pid, name in processes() if name.lower().endswith(game_name)]
if existing and not options.verify_only:
    raise SystemExit('The game is already running; use --verify-only to check its current session.')
if not any(Path(name).name == 'steam_osx' for _, name in processes()):
    raise SystemExit('Connect Mac Steam in Playdock first.')
if not options.verify_only:
    env = dict(os.environ)
    subprocess.run([str(STEAM/'Steam.AppBundle/Steam/Contents/MacOS/steam_osx'),'-silent','-applaunch',options.app_id],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15,check=True)
for _ in range(180):
    matches = [pid for pid, name in processes() if name.lower().endswith(game_name)]
    if matches: break
    time.sleep(.5)
if not matches: raise SystemExit('The game process did not start; check the latest Playdock log.')
pid = matches[0]
toolchain = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['/usr/bin/xcrun','clang','-fobjc-arc','-framework','Cocoa',str(ROOT/'Scripts/Integration/WindowProbe.m'),'-o',str(WORK/'WindowProbe')],env=toolchain,check=True)
for _ in range(60):
    result = subprocess.check_output([str(WORK/'WindowProbe'),str(pid)],text=True)
    if 'ALPHA=1.00 ONSCREEN=1' in result: break
    time.sleep(.5)
(WORK/'game-window.txt').write_text(f'GAME_PID={pid}\n'+result)
print(f'GAME_PID={pid}\n'+result)
if 'ALPHA=1.00 ONSCREEN=1' not in result: raise SystemExit('The game’s native window did not become visible.')
print('The game has a visible native window. It is left running for picture and input validation.')
