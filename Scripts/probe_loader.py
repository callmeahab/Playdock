#!/usr/bin/env python3
"""Check local Wine loader compatibility without touching any Windows prefix."""
from pathlib import Path
import os
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
work = root / 'build/loader-probe'
work.mkdir(parents=True, exist_ok=True)
(work / 'probe.c').write_text('#include <stdio.h>\n#include <unistd.h>\n__attribute__((constructor)) static void probe(void) { fprintf(stderr, "WAYFARER_NATIVE_LOADED pid=%d\\n", getpid()); }\n')
subprocess.run(['/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang', '-arch', 'x86_64', '-dynamiclib', str(work / 'probe.c'), '-o', str(work / 'probe.dylib')], check=True)
loader = work / 'wine'
original = Path('/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine')
shutil.copy2(original, loader)
(work / 'ntdll.so').symlink_to(original.parent / 'ntdll.so') if not (work / 'ntdll.so').exists() else None
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(loader)], check=True)
env = os.environ.copy()
env['WINEDLLPATH'] = str(original.parent.parent)
env['DYLD_INSERT_LIBRARIES'] = str(work / 'probe.dylib')
for binary in [original, loader]:
    result = subprocess.run([str(binary), '--version'], env=env, text=True, capture_output=True, timeout=20)
    print(f'{binary.name} ({"provider" if binary == original else "app-owned loader"}): exit={result.returncode}')
    print(result.stdout.strip())
    print(result.stderr.strip())
