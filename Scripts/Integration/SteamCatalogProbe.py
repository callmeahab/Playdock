#!/usr/bin/env python3
"""Read Steam's own current license listing through the running Mac client."""
from pathlib import Path
import os, subprocess, time, re, uuid, json, sys
if sys.argv[1:] not in ([], ['--mac']): raise SystemExit('Usage: SteamCatalogProbe.py [--mac]')
root=Path.home()/'Library/Application Support/Steam'
log=root/'logs/console_log.txt'
start=log.stat().st_size if log.exists() else 0
env=dict(os.environ)
launcher=[str(root/'Steam.AppBundle/Steam/Contents/MacOS/steam_osx')]
nonce=str(uuid.uuid4()).upper()
boundary=1_000_000_000+int(uuid.UUID(nonce).hex[:8],16)%1_000_000_000
process=subprocess.Popen(launcher+['-silent','-console','-wayfarer-library-request='+nonce,'+licenses_print','+licenses_for_app',str(boundary)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
# A catalog timeout must not terminate Steam or another game's services.
text=''
for _ in range(40):
    if log.exists():
        with log.open('rb') as f: f.seek(start); text=f.read(2_000_000).decode('utf8',errors='replace')
    if f'No active license found for appID {boundary}.' in text: break
    time.sleep(.5)
clean=re.sub(r'\[\d{4}-\d{2}-\d{2}[^\]]*\]\s?', '', text)
lines=clean.splitlines()
begin=next((i for i,l in enumerate(lines) if l.startswith('ExecCommandLine:') and '-wayfarer-library-request='+nonce in l),None)
end=next((i for i,l in enumerate(lines) if l.strip()==f'No active license found for appID {boundary}.'),None)
if begin is None or end is None or end<=begin: raise SystemExit('Steam did not provide the bounded license response.')
section='\n'.join(lines[begin+1:end])
print('Fresh license packages:',len(re.findall(r'License packageID (\d+):',section)))
work=Path(__file__).resolve().parents[2]/'build/SteamCatalogReview'
work.mkdir(parents=True,exist_ok=True)
(work/'probe-mac.json').write_text(json.dumps({'nonce':nonce,'offset':start,'client':'mac'}))
print('Review nonce:',nonce)
