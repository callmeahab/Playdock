#!/usr/bin/env python3
"""Exercise first-launch setup using disposable settings and environment fixtures."""
import argparse
import copy
import json
import os
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--products', type=Path, default=root / 'build/SetupDebug/Build/Products/Debug')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
executable = args.products / 'Playdock.app/Contents/MacOS/Playdock'
assert executable.is_file()
work = args.output or Path(tempfile.mkdtemp(prefix='playdock-setup-ui-'))
work.mkdir(parents=True, exist_ok=True)
base = dict(steamPresent=True, steamBuild='1788652215', steamSupported=True, installed=False,
            ready=False, recoveryNeeded=False, recoveryAvailable=False, problems=[], crossOver=[
                dict(path='/Preview.app', name='CrossOver Preview', version='20261006', supported=True,
                     licensed=True, supportDetail='', licenseDetail='')])

def run(name, state, mode='unavailable', startup=False, couch=False, settings=None, snapshot=False, native_only=False, progress=False):
    fixture = work / f'{name}.fixture.json'
    fixture.write_text(json.dumps(dict(environment=state, snapshot=dict(
        mode=mode, folders=[], downloads=[], downloadsPaused=False))))
    output = work / f'{name}.json'
    if settings is None:
        settings = work / f'{name}.settings.json'
        settings.unlink(missing_ok=True)
    command = [str(executable), '--no-background-steam', f'--settings-file={settings}',
               f'--setup-environment={fixture}',
               f'--bridge-{"startup-" if startup else ""}ui-probe={output}']
    if couch: command.append('--show-couch')
    if native_only: command.append('--setup-native-only')
    if progress: command.append('--bridge-progress-preview')
    if snapshot: command.append(f'--bridge-ui-snapshot={work / (name + ".png")}')
    with (work / f'{name}.log').open('w') as log:
        child = subprocess.Popen(command, stdout=log, stderr=log, env=dict(os.environ))
        try:
            child.wait(timeout=30)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
    assert child.returncode == 0, (name, child.returncode)
    result = json.loads(output.read_text())
    assert result.get('signInIsSilent') is False, result
    assert result.get('signInHidesSteam') is False, result
    return result, settings

scenarios = []
missing = copy.deepcopy(base); missing.update(steamPresent=False, steamBuild=None, steamSupported=False, crossOver=[])
scenarios.append(('missing-steam', missing, 'unavailable', 'Get Steam'))
incomplete = copy.deepcopy(base); incomplete.update(steamBuild=None, steamSupported=False)
scenarios.append(('incomplete-steam', incomplete, 'unavailable', 'Open Steam'))
no_runtime = copy.deepcopy(base); no_runtime['crossOver'] = []
scenarios.append(('missing-runtime', no_runtime, 'unavailable', 'Get CrossOver Preview'))
activation = copy.deepcopy(base); activation['crossOver'][0]['licensed'] = False
scenarios.append(('activation', activation, 'unavailable', 'Activate CrossOver'))
scenarios.append(('enable-windows', base, 'unavailable', 'Enable Windows games'))
repair = copy.deepcopy(base); repair['installed'] = True; repair['recoveryNeeded'] = True
scenarios.append(('repair', repair, 'unavailable', 'Repair Windows support'))
ready = copy.deepcopy(base); ready.update(installed=True, ready=True)
scenarios.append(('offline', ready, 'offline', 'Open library'))
scenarios.append(('signed-out', ready, 'signedOut', 'Sign in to Steam'))
for name, state, mode, action in scenarios:
    result, _ = run(name, state, mode, snapshot=name == 'enable-windows')
    assert result['sheet'] and result['closed'] and result['setupReviewed'], result
    assert result['primaryAction'] == action, result
    print(f'PASS: {name} → {action}')

result, settings = run('first-launch', missing, startup=True)
assert result['sheet'] and result['closed'] and result['stayedClosedAfterCheck'], result
assert json.loads(settings.read_text()).get('setupReviewedAt') is not None
result, _ = run('next-launch', missing, startup=True, settings=settings)
assert not result['sheet'] and not result['setupPresented'], result
result, _ = run('controller', base, couch=True)
assert result['closePressed'] and result['closed'] and result['primaryActionVisible'], result
result, _ = run('native-only', no_runtime, couch=True, native_only=True)
assert result['nativeOnlyPressed'] and result['primaryAction'] == 'Connect Steam' and result['primaryActionVisible'], result
result, _ = run('progress', base, progress=True, snapshot=True)
assert result['sheet'] and result['closed'] and not result['connectingBeforeDismissal'], result
print(f'PASS: dismissal persists across launches; controller controls close setup. Artifacts: {work}')
