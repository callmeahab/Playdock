#!/usr/bin/env python3
"""Test AppKit presentation with disposable processes and a temporary host window."""
import argparse, json, os, select, shutil, subprocess, tempfile, time
from pathlib import Path

root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser()
parser.add_argument('--products',type=Path,default=root/'build/DerivedData/Build/Products/Debug')
products=parser.parse_args().products
adapter=products/'libWayfarerWineDisplay.dylib'
assert adapter.is_file()
env=dict(os.environ,DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
work=Path(tempfile.mkdtemp(prefix='wayfarer-background-probe-'))
processes=[]
try:
    fixture=work/'fixture'
    subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Cocoa','-framework','ApplicationServices',str(root/'Scripts/Integration/SteamBackgroundFixture.m'),'-o',str(fixture)],env=env,check=True)
    directory=work/'state'; directory.mkdir(mode=0o700)
    def launch(name,inject=True):
        executable=work/name; shutil.copy2(fixture,executable)
        child_env=dict(env)
        if inject:child_env.update(DYLD_INSERT_LIBRARIES=str(adapter),WAYFARER_STEAM_BACKEND=str(directory))
        child=subprocess.Popen([str(executable)],env=child_env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
        processes.append(child); return child
    def read_until(child,predicate,timeout=5):
        deadline=time.monotonic()+timeout
        seen=[]
        while time.monotonic()<deadline:
            if child.poll() is not None: raise AssertionError(f'Fixture exited {child.returncode}: {child.stderr.read()[:800]}')
            if select.select([child.stdout],[],[],0.1)[0]:
                value=json.loads(child.stdout.readline())
                seen.append(value)
                if predicate(value):return value
        error=os.read(child.stderr.fileno(),2048).decode(errors='replace') if select.select([child.stderr],[],[],0)[0] else ''
        raise AssertionError(f'Fixture did not reach the expected presentation state: {seen[-3:]} {error}')
    def hidden(value):
        return (value.get('policy')==2 and value.get('alpha')==0 and
                value.get('visible')==0 and value.get('key')==0 and value.get('main')==0 and
                value.get('ignoresMouse')==1 and value.get('canKey')==0 and value.get('canMain')==0)
    steam=launch('steam_osx')
    helper=launch('Steam Helper')
    read_until(steam,hidden); read_until(helper,hidden)
    host=launch('WayfarerFixture',False)
    host_state=read_until(host,lambda v:'window' in v)
    gate=directory/'presentation.json'
    for state in [host_state, dict(host_state,external=True), {}, dict(host_state,microseconds=host_state['microseconds']+1)]:
        gate.write_text(json.dumps(state))
        time.sleep(.4)
        read_until(steam,hidden); read_until(helper,hidden)
    game=launch('NativeGameFixture')
    read_until(game,lambda v:v.get('policy')==0 and v.get('alpha')==1 and v.get('visible')==1 and v.get('canKey')==1 and v.get('ignoresMouse')==0)
    assert not (directory/f'{game.pid}.ready').exists()
    windows_game=launch('WindowsGameFixture.exe')
    read_until(windows_game,lambda v:v.get('policy')==0 and v.get('alpha')==1 and v.get('visible')==1 and v.get('canKey')==1 and v.get('ignoresMouse')==0)
    assert not (directory/f'{windows_game.pid}.ready').exists()
    print('PASS: Steam and helpers stay hidden, cannot become key/main or intercept input, and ignore presentation requests; native and Windows games remain visible.')
finally:
    for child in processes:
        if child.poll() is None:child.terminate()
        child.wait(timeout=5)
    shutil.rmtree(work)
