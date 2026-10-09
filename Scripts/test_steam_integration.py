#!/usr/bin/env python3
"""Exercise ported Steam compatibility code against fixtures without running Steam."""
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "Sources/PlaydockSteamRuntime"


def run(*arguments):
    result = subprocess.run([str(a) for a in arguments], check=True, text=True, capture_output=True)
    return result.stdout


with tempfile.TemporaryDirectory(prefix="playdock-steam-tests-") as temporary:
    scratch = Path(temporary)
    generated = scratch / "generated"
    generated.mkdir()
    run("/usr/bin/python3", NATIVE / "dylib/embed_script.py", NATIVE / "dylib/feats/compat_run.sh", generated / "compat_run.h", "RUN_SCRIPT")
    run("/bin/sh", "-n", NATIVE / "dylib/feats/compat_run.sh")
    for test in ["compatcheck", "compatsvc-check", "spawn-env", "peicon-check", "gatecheck"]:
        binary = scratch / test
        extra = [NATIVE / "dylib/util/peicon.c"] if test == "peicon-check" else []
        run("/usr/bin/xcrun", "clang", "-std=c17", "-O1", "-g", "-Wall", "-Wextra", "-Wno-unused-parameter",
            "-I" + str(NATIVE / "dylib"), "-I" + str(generated), "-o", binary, NATIVE / f"dylib/tests/{test}.c", *extra)
        arguments = []
        if test == "compatcheck":
            home = scratch / "home"
            (home / "Library/Application Support/Steam/compatibilitytools.d").mkdir(parents=True)
            arguments = [home]
        elif test == "peicon-check":
            icons = scratch / "icons"
            icons.mkdir()
            arguments = [icons]
        print(run(binary, *arguments).strip())
    tool = scratch / "home/Library/Application Support/Steam/compatibilitytools.d/playdock-proton"
    declaration = (tool / "compatibilitytool.vdf").read_text()
    assert '"playdock-proton"' in declaration and '"Playdock CrossOver"' in declaration
    launcher = (tool / "run").read_text()
    assert "Library/Application Support/Playdock/SteamIntegration/runners/current" in launcher
    assert "Library/Application Support/notproton" not in launcher
    assert os.access(tool / "run", os.X_OK)
    print("PASS: Playdock tool registration, launcher paths, and executable permission")
    repair = launcher.split("repair_loader_cache() {", 1)[1].split('\n\nstage_step=', 1)[0]
    repair = 'repair_loader_cache() {' + repair
    cache_test = scratch / 'repair-cache.sh'
    cache_test.write_text('#!/bin/sh\nset -e\nlog=/dev/null\n' + repair + '\nrepair_loader_cache "$@"\n')
    wine = scratch / 'wine'
    wine.write_text('loader fixture')
    key = run('stat', '-f', '%i-%z-%m', wine).strip()
    runtime = scratch / 'runtime'
    runtime.mkdir()
    (runtime / 'ntdll.so').write_text('library fixture')
    cache_root = scratch / 'cache'
    cache_root.mkdir()
    broken = cache_root / f'winetemp-{key}-0'
    broken.mkdir()
    os.link(wine, broken / 'cmd.exe')
    (broken / 'ntdll.so').symlink_to(scratch / 'removed-runtime/ntdll.so')
    live = cache_root / f'winetemp-{key}-1'
    live.mkdir()
    os.link(wine, live / 'cmd.exe')
    other_library = scratch / 'other-ntdll.so'
    other_library.write_text('another runtime')
    (live / 'ntdll.so').symlink_to(other_library)
    unrelated = cache_root / f'winetemp-{key}-2'
    unrelated.mkdir()
    (unrelated / 'cmd.exe').write_text('unrelated loader')
    (unrelated / 'ntdll.so').symlink_to(scratch / 'unrelated-missing.so')
    linked = cache_root / f'winetemp-{key}-3'
    linked.symlink_to(unrelated, target_is_directory=True)
    for _ in range(2):
        run('/bin/sh', cache_test, wine, runtime, cache_root)
        assert (broken / 'ntdll.so').resolve() == (runtime / 'ntdll.so').resolve()
        assert (live / 'ntdll.so').resolve() == other_library.resolve()
        assert os.readlink(unrelated / 'ntdll.so') == str(scratch / 'unrelated-missing.so')
        assert linked.is_symlink()
    home = scratch / 'startup-home'
    loader = home / 'Library/Application Support/Playdock/SteamIntegration/runners/current/lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine'
    loader.parent.mkdir(parents=True)
    loader.write_text('#!/bin/sh\nexit 27\n')
    loader.chmod(0o755)
    server = loader.parents[6] / 'bin/wineserver-arm64'
    server.parent.mkdir()
    server.write_text('#!/bin/sh\nexit 0\n')
    server.chmod(0o755)
    native_dll = loader.parents[4] / 'aarch64-windows/ntdll.dll'
    native_dll.parent.mkdir()
    native_dll.write_text('runtime generation one')
    compat = scratch / 'compatdata'
    compat.mkdir()
    result = subprocess.run(['/bin/sh', str(tool / 'run'), 'run', 'cmd.exe'],
        env=dict(os.environ, HOME=str(home), TMPDIR=str(cache_root), STEAM_COMPAT_DATA_PATH=str(compat), STEAM_COMPAT_APP_ID='100'),
        capture_output=True, text=True)
    assert result.returncode == 27, (result.returncode, result.stderr)
    assert (compat / 'playdock-launch-result').read_text() == '1\n27\nwineboot\n'
    print('PASS: moved runtime cache repairs idempotently, unrelated caches stay intact, and Wine startup failure stops the launch with its actual exit code')
    calls = scratch / 'wine-calls'
    server_calls = scratch / 'server-calls'
    server.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FIXTURE_SERVER_CALLS"\nexit 0\n')
    loader.write_text('''#!/bin/sh
printf '%s\\n' "$*" >> "$FIXTURE_CALLS"
if [ "$1" = wineboot ]; then
  mkdir -p "$WINEPREFIX/drive_c/windows/system32"
  touch "$WINEPREFIX/system.reg" "$WINEPREFIX/drive_c/windows/system32/kernel32.dll"
fi
exit 0
''')
    def prepare(sync='0', retina='0'):
        return subprocess.run(['/bin/sh', str(tool / 'run'), 'run', 'cmd.exe'],
            env=dict(os.environ, HOME=str(home), TMPDIR=str(cache_root), STEAM_COMPAT_DATA_PATH=str(compat),
                     STEAM_COMPAT_APP_ID='100', FIXTURE_CALLS=str(calls), FIXTURE_SERVER_CALLS=str(server_calls),
                     WINEMSYNC=sync, PLAYDOCK_STEAM_RETINA=retina),
            capture_output=True, text=True, check=True)
    prepare()
    first = calls.read_text().splitlines()
    assert first.count('wineboot --init') == 1
    assert server_calls.read_text().splitlines() == ['-k', '-w']
    os.link(loader, scratch / 'bundle-wine')
    prepare()
    second = calls.read_text().splitlines()
    assert second[len(first):] == ['cmd.exe'], second
    assert server_calls.read_text().splitlines() == ['-k', '-w']
    prepare(sync='1')
    assert calls.read_text().splitlines().count('wineboot --init') == 2
    prepare(sync='1', retina='1')
    assert calls.read_text().splitlines().count('wineboot --init') == 3
    replacement = native_dll.with_suffix('.new')
    replacement.write_text('runtime generation two')
    replacement.replace(native_dll)
    prepare(sync='1', retina='1')
    assert calls.read_text().splitlines().count('wineboot --init') == 4
    (compat / 'pfx/drive_c/windows/system32/kernel32.dll').unlink()
    prepare(sync='1', retina='1')
    assert calls.read_text().splitlines().count('wineboot --init') == 5
    assert server_calls.read_text().splitlines() == ['-k', '-w'] * 5
    print('PASS: repeat launches skip prefix setup; runtime, sync, Retina and incomplete-prefix changes invalidate the cache')
    direct = 'direct_executable() {' + launcher.split('direct_executable() {', 1)[1].split('\ndirect_target=', 1)[0]
    path_test = scratch / 'direct-path.sh'
    path_test.write_text('#!/bin/sh\n' + direct + '\ndirect_executable "$1"\n')
    drives = compat / 'pfx/dosdevices'
    drives.mkdir()
    (drives / 'z:').symlink_to('/')
    target = scratch / 'Game with spaces & $literal.EXE'
    target.write_text('PE fixture')
    env = dict(os.environ, WINEPREFIX=str(compat / 'pfx'))
    def direct_path(value):
        return subprocess.run(['/bin/sh', str(path_test), str(value)], env=env, capture_output=True, text=True, check=True).stdout.strip()
    assert direct_path(target) == 'Z:' + str(target).replace('/', '\\')
    for value in [scratch / 'missing.exe', 'relative.exe', 'steam://launch/100']:
        assert direct_path(value) == str(value)
    (drives / 'z:').unlink()
    (drives / 'z:').symlink_to(scratch)
    assert direct_path(target) == str(target)
    print('PASS: executable paths bypass shell inspection while preserving arguments and custom root-drive mappings')
    bundle_script = scratch / 'bundle-prepare.sh'
    bundle_body = launcher.split('# Fixes CrossOver window focus issues', 1)[1].split("\nwine_helpers=", 1)[0]
    bundle_script.write_text('''#!/bin/sh
set -e
log="$FIXTURE_BUNDLE_LOG"
log_stage() { echo "$1" >> "$log"; }
target="$FIXTURE_GAME"
''' + bundle_body + '\nprintf "%s\\n" "$bundle_changed"\n')
    bin_dir = scratch / 'fake-bin'
    bin_dir.mkdir()
    gate = scratch / 'icon-release'
    curl = bin_dir / 'curl'
    curl.write_text('''#!/bin/sh
while [ ! -f "$FIXTURE_ICON_RELEASE" ]; do sleep 0.05; done
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then shift; output=$1; fi
  shift
done
printf '\\000\\000\\001\\000fixture' > "$output"
printf 200
''')
    curl.chmod(0o755)
    support = home / 'Library/Application Support/Playdock/SteamIntegration'
    appinfo = support / 'appinfo'
    appinfo.write_text('#!/bin/sh\nprintf "name=Fixture Game\\nclienticon=fixturehash\\n"\n')
    appinfo.chmod(0o755)
    iconmaker = support / 'iconmaker'
    iconmaker.write_text('#!/bin/sh\ncp "$1" "$2"\n')
    iconmaker.chmod(0o755)
    client = scratch / 'steam-client'
    (client / 'appcache').mkdir(parents=True)
    (client / 'appcache/appinfo.vdf').write_text('fixture metadata')
    bundle_log = scratch / 'bundle.log'
    bundle_env = dict(os.environ, HOME=str(home), PATH=str(bin_dir) + ':' + os.environ['PATH'],
        WINELOADER=str(loader), wine_unix=str(loader.parents[3]), WINEPREFIX=str(compat / 'pfx'),
        STEAM_COMPAT_DATA_PATH=str(compat), STEAM_COMPAT_INSTALL_PATH=str(scratch),
        STEAM_COMPAT_CLIENT_INSTALL_PATH=str(client), app_id='100', launch_result=str(compat / 'playdock-launch-result'),
        FIXTURE_ICON_RELEASE=str(gate), FIXTURE_BUNDLE_LOG=str(bundle_log), FIXTURE_GAME=str(target))
    def bundle_prepare():
        return subprocess.run(['/bin/sh', str(bundle_script)], env=bundle_env, capture_output=True,
                              text=True, check=True, timeout=3).stdout.strip()
    try:
        assert bundle_prepare() == '1'
        bundle = support / 'launchers/100/Fixture Game.app'
        plist = bundle / 'Contents/Info.plist'
        first_plist = plist.stat()
        assert bundle_prepare() == '0'
        assert plist.stat().st_ino == first_plist.st_ino
        assert plist.stat().st_mtime_ns == first_plist.st_mtime_ns
    finally:
        gate.touch()
    fetched_icon = support / 'launchers/100/clienticon-fixturehash.ico'
    for _ in range(100):
        if fetched_icon.exists(): break
        time.sleep(0.02)
    assert fetched_icon.exists()
    assert bundle_prepare() == '1', 'New artwork must refresh the bundle'
    assert bundle_prepare() == '0'
    new_loader = loader.with_suffix('.new')
    new_loader.write_bytes(loader.read_bytes())
    new_loader.chmod(0o755)
    new_loader.replace(loader)
    assert bundle_prepare() == '1', 'A replaced runtime must refresh the bundle'
    assert os.path.samefile(loader, bundle / 'Contents/MacOS/wine')
    print('PASS: blocked icon download never delays launch, bundles reuse unchanged files, and artwork/runtime changes refresh them')
    process_script = scratch / 'process-cache.sh'
    process_body = launcher.split('game_pids=""', 1)[1].split('\nwait_prefix_idle()', 1)[0]
    lsof_calls = scratch / 'lsof-calls'
    token_file = scratch / 'process-start'
    member_file = scratch / 'prefix-member'
    token_file.write_text('1000 Mon Oct  9 10:00:00 2026')
    member_file.touch()
    lsof = bin_dir / 'lsof'
    lsof.write_text('#!/bin/sh\necho scan >> "$FIXTURE_LSOF_CALLS"\n[ ! -f "$FIXTURE_MEMBER" ] || echo 1000\n')
    lsof.chmod(0o755)
    ps = bin_dir / 'ps'
    ps.write_text('''#!/bin/sh
case "$*" in
  *lstart*) cat "$FIXTURE_PROCESS_START" ;;
  *) printf '1000 C:\\\\game.exe\\n' ;;
esac
''')
    ps.chmod(0o755)
    process_script.write_text('''#!/bin/sh
set -e
wine_helpers='services|steam.exe'
prefix_server_dir() { printf '%s\\n' "$FIXTURE_SERVER_DIR"; }
game_pids=""''' + process_body + '''
prefix_game_running
prefix_game_running
[ "$(wc -l < "$FIXTURE_LSOF_CALLS" | tr -d ' ')" = 1 ]
printf '1000 Tue Oct 10 10:00:00 2026' > "$FIXTURE_PROCESS_START"
rm "$FIXTURE_MEMBER"
if prefix_game_running; then exit 1; fi
[ "$(wc -l < "$FIXTURE_LSOF_CALLS" | tr -d ' ')" = 2 ]
''')
    subprocess.run(['/bin/sh', str(process_script)], check=True,
        env=dict(bundle_env, FIXTURE_LSOF_CALLS=str(lsof_calls), FIXTURE_PROCESS_START=str(token_file),
                 FIXTURE_MEMBER=str(member_file), FIXTURE_SERVER_DIR=str(scratch)))
    print('PASS: process start-time checks reuse verified PIDs; PID replacement requires a fresh prefix-membership scan')
    for fixture in sorted((NATIVE / "dylib/tests/webpatch-fixtures").glob("gates.*.js")):
        binary = scratch / "gatecheck"
        output = run(binary, fixture)
        assert "APPLIED" in output, output
        for name, content in [("doubled", fixture.read_bytes() * 2), ("truncated", fixture.read_bytes()[:fixture.stat().st_size // 2])]:
            broken = scratch / f"{fixture.stem}.{name}.js"
            broken.write_bytes(content)
            output = run(binary, broken)
            assert "REJECTED" in output, output
    webpatch = (NATIVE / "dylib/feats/webpatch.c").read_text()
    assert "MSCXOpts" not in webpatch and "MSCXPanel" not in webpatch
    print("PASS: three Steam UI fixtures patch once, reject duplicate/truncated anchors, and contain no injected performance panel")
