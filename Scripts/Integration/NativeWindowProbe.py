#!/usr/bin/env python3
"""Check native Wine metadata, activation, and disconnect with a disposable AppKit fixture."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=ROOT / 'build/DerivedData/Build/Products/Release')
adapter = parser.parse_args().products / 'libPlaydockWineDisplay.dylib'
assert adapter.is_file(), 'Build Playdock before running this probe.'

with tempfile.TemporaryDirectory(prefix='playdock-window-test-') as temporary:
    scratch = Path(temporary)
    fixture = scratch / 'fixture'
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Cocoa',
        str(ROOT / 'Scripts/Integration/NativeWindowFixture.m'), '-o', str(fixture)], check=True)
    address = scratch / 'display.sock'
    done = scratch / 'done'
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
        server.bind(str(address)); server.listen(1); server.settimeout(8)
        env = dict(os.environ, DYLD_INSERT_LIBRARIES=str(adapter), PLAYDOCK_DISPLAY_SOCKET=str(address),
                   PLAYDOCK_DISPLAY_TOKEN='fixture-token', PLAYDOCK_PROBE_DONE=str(done))
        child = subprocess.Popen([str(fixture)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with server.accept()[0] as connection:
                connection.settimeout(8)
                with connection.makefile('rb') as stream:
                    hello = json.loads(stream.readline())
                    assert hello['type'] == 'hello' and hello['token'] == 'fixture-token' and hello['pid'] == child.pid
                    connection.sendall(b'{"type":"ready","version":1}\n')
                    deadline = time.monotonic() + 8
                    activated = False
                    while time.monotonic() < deadline:
                        value = json.loads(stream.readline())
                        if value['type'] != 'window' or not value['visible']: continue
                        assert value['id'] > 0 and value['title'] == 'Native tracking fixture', value
                        assert value['width'] == 800 and value['height'] == 600, value
                        assert 'context' not in value and 'presentation' not in value, value
                        if not activated:
                            if value['focused']: continue
                            connection.sendall(json.dumps({'kind': 'activate', 'id': value['id']}).encode() + b'\n')
                            activated = True
                        elif value['focused']: break
                    else: raise AssertionError('The tracked native window did not become key after activation.')
            # Closing the transport must leave the game's own rendering and input untouched.
            time.sleep(.3)
            done.touch()
            stdout, stderr = child.communicate(timeout=8)
            assert child.returncode == 0 and 'NATIVE_WINDOW_INTACT' in stdout, (stdout, stderr)
        finally:
            if child.poll() is None:
                child.terminate(); child.communicate(timeout=5)
    print('PASS: native metadata and activation work; disconnect preserves window rendering, visibility, and input.')
