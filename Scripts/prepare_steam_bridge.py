#!/usr/bin/env python3
"""Build Wayfarer's Steam hooks and stage its offline compatibility resources."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / "Sources/WayfarerSteamRuntime"
COMPONENTS = ROOT / "BridgeComponents"
MANIFEST = COMPONENTS / "release.json"
SOURCES = [
    "core/loader.c", "core/macho.c", "resolver/anchor.c", "resolver/aob.c",
    "resolver/resolver.c", "resolver/sigdb.c", "util/log.c", "util/file.c",
    "util/peicon.c", "hooks/hooks.c", "hooks/hook_compat.c", "hooks/hook_shortcut.c",
    "hooks/hook_icon.c", "hooks/hook_webui.c", "hooks/hook_webpatch.c", "hooks/hook_spawn.c",
    "feats/compat.c", "feats/webui.c", "feats/compatsvc.c", "feats/webpatch.c",
]


def digest(path):
    with path.open("rb") as source:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: source.read(1_048_576), b""):
            checksum.update(chunk)
        return checksum.hexdigest()


def record(path):
    return {"bytes": path.stat().st_size, "sha256": digest(path), "mode": path.stat().st_mode & 0o777}


def matches(path, expected):
    return path.is_file() and not path.is_symlink() and path.stat().st_size == expected["bytes"] and digest(path) == expected["sha256"]


def run(*arguments):
    subprocess.run([str(arg) for arg in arguments], check=True)


def build(output):
    cmake = shutil.which("cmake") or next((str(p) for p in [Path("/opt/homebrew/bin/cmake"), Path("/usr/local/bin/cmake")] if p.is_file()), None)
    if not cmake:
        raise ValueError("Building the Steam hook library requires CMake")
    output.mkdir(parents=True, exist_ok=True)
    dobby = output / "dobby"
    run(cmake, "-S", NATIVE / "vendor/dobby", "-B", dobby, "-G", "Unix Makefiles",
        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DDOBBY_DEBUG=OFF", "-DDOBBY_GENERATE_SHARED=OFF")
    run(cmake, "--build", dobby, "--parallel", str(min(os.cpu_count() or 2, 8)))
    generated = output / "generated"
    generated.mkdir(exist_ok=True)
    run("/usr/bin/python3", NATIVE / "dylib/embed_script.py", NATIVE / "dylib/feats/compat_run.sh", generated / "compat_run.h", "RUN_SCRIPT")
    libraries = [dobby / name for name in [
        "libdobby.a", "builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a",
        "builtin-plugin/SymbolResolver/libmacho_ctx_kit.a", "builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a",
        "external/osbase/libosbase.a", "external/logging/liblogging.a",
    ]]
    common = ["-mmacosx-version-min=15.0", "-O2", "-Wall", "-Wextra", "-Wno-unused-parameter"]
    arm = output / "steam.arm64.dylib"
    run("/usr/bin/xcrun", "clang", "-arch", "arm64", *common, "-std=c17", "-fPIC",
        "-I" + str(NATIVE / "dylib"), "-I" + str(NATIVE / "vendor"), "-I" + str(NATIVE / "vendor/dobby/include"), "-I" + str(generated),
        "-dynamiclib", "-install_name", "@rpath/libWayfarerSteam.dylib", "-o", arm,
        *[NATIVE / "dylib" / name for name in SOURCES], NATIVE / "vendor/cJSON.c", *libraries, "-framework", "CoreFoundation", "-lc++")
    stub = output / "steam.x86_64.dylib"
    run("/usr/bin/xcrun", "clang", "-arch", "x86_64", *common, "-dynamiclib", "-install_name", "@rpath/libWayfarerSteam.dylib",
        "-o", stub, NATIVE / "dylib/stub_x86_64.c")
    payload = output / "payload"
    payload.mkdir(exist_ok=True)
    run("/usr/bin/lipo", "-create", arm, stub, "-output", payload / "libWayfarerSteam.dylib")
    overlay = []
    for arch in ["arm64", "x86_64"]:
        dylib = output / f"overlay.{arch}.dylib"
        run("/usr/bin/xcrun", "clang", "-arch", arch, *common, "-dynamiclib", "-install_name", "@rpath/overlay-shim.dylib", "-o", dylib,
            NATIVE / "overlay-shim/overlay_shim.m", "-framework", "Metal", "-framework", "QuartzCore", "-framework", "CoreGraphics", "-framework", "CoreFoundation")
        overlay.append(dylib)
    run("/usr/bin/lipo", "-create", *overlay, "-output", payload / "overlay-shim.dylib")
    for helper in ["appinfo", "iconmaker"]:
        slices = []
        for arch in ["arm64", "x86_64"]:
            binary = output / f"{helper}.{arch}"
            flags = []
            if helper == "iconmaker":
                obj = output / f"peicon.{arch}.o"
                run("/usr/bin/xcrun", "clang", "-c", "-arch", arch, *common, "-o", obj, NATIVE / "dylib/util/peicon.c")
                flags = ["-framework", "AppKit", "-import-objc-header", NATIVE / "dylib/util/peicon.h", obj]
            run("/usr/bin/xcrun", "swiftc", "-O", "-target", f"{arch}-apple-macos15.0", *flags, "-o", binary, NATIVE / f"helpers/{helper}.swift")
            slices.append(binary)
        run("/usr/bin/lipo", "-create", *slices, "-output", payload / helper)
    for file in payload.iterdir():
        run("/usr/bin/codesign", "-f", "-s", "-", file)


def prepare(output):
    manifest = json.loads(MANIFEST.read_text())
    archive = COMPONENTS / manifest["interop"]["archive"]
    if not matches(archive, manifest["interop"]):
        raise ValueError("The vendored Wine/Steamworks adapter archive failed SHA-256 verification")
    if output.is_symlink():
        raise ValueError("The integration output directory must not be a symlink")
    fingerprint = hashlib.sha256()
    fingerprint.update(MANIFEST.read_bytes())
    fingerprint.update(Path(__file__).read_bytes())
    fingerprint.update(subprocess.check_output(["/usr/bin/xcrun", "clang", "--version"]))
    fingerprint.update(subprocess.check_output(["/usr/bin/xcrun", "swiftc", "--version"]))
    inputs = [NATIVE / name for name in ["dylib", "overlay-shim", "helpers", "vendor"]]
    for path in sorted(p for directory in inputs for p in directory.rglob("*") if p.is_file()):
        fingerprint.update(str(path.relative_to(ROOT)).encode())
        fingerprint.update(bytes.fromhex(digest(path)))
    revision = fingerprint.hexdigest()
    try:
        built = json.loads((output / "build.json").read_text())
        if built["sourceSHA256"] == revision and set(built["files"]) == set(manifest["compiled"]) and (output / "release.json").read_bytes() == MANIFEST.read_bytes() and all(matches(output / name, entry) for name, entry in {**manifest["files"], **built["files"]}.items()):
            return
    except (OSError, ValueError, KeyError):
        pass
    cache = ROOT / "build/SteamRuntime" / revision
    build(cache)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".SteamIntegration-") as directory:
        staging = Path(directory) / "SteamBridge"
        staging.mkdir()
        with zipfile.ZipFile(archive) as package:
            for name, entry in manifest["files"].items():
                destination = staging / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                if name.startswith("payload/bridge/"):
                    member = package.getinfo(name)
                    if member.file_size != entry["bytes"]:
                        raise ValueError(f"Wrong adapter size: {name}")
                    with package.open(member) as source, destination.open("wb") as target:
                        shutil.copyfileobj(source, target)
                else:
                    source = COMPONENTS / name if name.startswith("Licenses/") else COMPONENTS / "Resources" / name
                    shutil.copyfile(source, destination)
                destination.chmod(entry["mode"])
                if not matches(destination, entry):
                    raise ValueError(f"Integration component failed SHA-256 verification: {name}")
        compiled = {}
        for name in manifest["compiled"]:
            destination = staging / name
            shutil.copy2(cache / name, destination)
            compiled[name] = record(destination)
        (staging / "build.json").write_text(json.dumps({"sourceSHA256": revision, "files": compiled}, indent=2, sort_keys=True) + "\n")
        shutil.copyfile(MANIFEST, staging / "release.json")
        if output.exists():
            shutil.rmtree(output)
        staging.replace(output)
    print("Built Wayfarer Steam hooks, launcher helpers and verified offline adapters", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.output)
