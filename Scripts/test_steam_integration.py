#!/usr/bin/env python3
"""Exercise ported Steam compatibility code against fixtures without running Steam."""
import os
from pathlib import Path
import subprocess
import tempfile

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
