#!/usr/bin/env python3
"""Verify game icons and helper Dock policies with disposable AppKit processes."""
import argparse
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'build/DerivedData/Build/Products/Release')
products = parser.parse_args().products
iconmaker = products / 'Playdock.app/Contents/Resources/SteamBridge/payload/iconmaker'
adapter = products / 'libPlaydockWineDisplay.dylib'
overlay = iconmaker.parent / 'overlay-shim.dylib'

with tempfile.TemporaryDirectory(prefix='playdock-dock-test-') as temporary:
    scratch = Path(temporary)
    fixture = scratch / 'fixture'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Cocoa', str(ROOT / 'Scripts/Integration/GameDockFixture.m'), '-o', str(fixture)], check=True)
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    png = scratch / 'source.png'
    png.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 6, 0, 0, 0))
        + chunk(b'IDAT', zlib.compress((b'\0' + b'\0\xff\0\xff' * 64) * 64)) + chunk(b'IEND', b''))
    prepared = scratch / 'game.icns'
    subprocess.run([str(iconmaker), str(png), str(prepared)], check=True)
    def run(name, libraries, prepared_icon=True, baseline=False):
        executable = scratch / name
        shutil.copy2(fixture, executable)
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=libraries, PLAYDOCK_GAME_PRESENTATION='native')
        if prepared_icon: env['PLAYDOCK_STEAM_DOCK_ICON'] = str(prepared)
        if baseline: env['PLAYDOCK_TEST_PREPARED_BASELINE'] = '1'
        result = subprocess.run([str(executable)], env=env, capture_output=True, text=True, timeout=8, check=True)
        return json.loads(result.stdout.strip().splitlines()[-1])
    for libraries in [str(adapter), str(overlay), f'{adapter}:{overlay}']:
        baseline = run('NativeBaseline', libraries, baseline=True)
        game = run('Game.exe', libraries)
        assert game['policy'] == 0 and game['cornerAlpha'] == 0, game
        assert all(abs(game[channel] - baseline[channel]) < .01 for channel in ['red', 'green', 'blue']), (game, baseline)
        helper = run('steam.exe', libraries)
        assert helper['policy'] == 1 and helper['blue'] > .9, helper
        fallback = run('AddedGame.exe', libraries, False)
        assert fallback['policy'] == 0 and fallback['blue'] > .9 and fallback['cornerAlpha'] == 0, fallback
        control = run('NativeControl', libraries)
        assert control['policy'] == 0 and control['blue'] > .9 and control['cornerAlpha'] == 1, control
    launcher = (ROOT / 'Sources/PlaydockSteamRuntime/dylib/feats/compat_run.sh').read_text()
    assert '<key>LSUIElement</key><true/>' in launcher
    assert 'export PLAYDOCK_STEAM_DOCK_ICON=' in launcher
    assert 'PLAYDOCK_STEAM_HIDE_LAUNCHER_TILE' not in launcher
    print('PASS: prepared game icons survive Wine updates and subclass overrides; helpers have no Dock tile; added games use rounded icons; native apps remain unchanged.')
