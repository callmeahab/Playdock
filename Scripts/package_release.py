#!/usr/bin/env python3
"""Build an Apple silicon app and package its matching committed source for release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
import tempfile

from prepare_steam_bridge import matches

ROOT = Path(__file__).resolve().parents[1]


def run(*arguments, cwd=ROOT, **kwargs):
    return subprocess.run([str(arg) for arg in arguments], cwd=cwd, check=True, **kwargs)


def git(root, *arguments):
    return run("git", *arguments, cwd=root, capture_output=True, text=True).stdout.strip()


def release_version(tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Release tags must be vMAJOR.MINOR.PATCH, without leading zeroes.")
    return tag[1:]


def source_commit(root, tag):
    if git(root, "status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Commit or remove working-tree changes before packaging a release.")
    commit = git(root, "rev-parse", "HEAD")
    reference = subprocess.run(["git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
                               cwd=root, capture_output=True, text=True)
    if reference.returncode == 0 and reference.stdout.strip() != commit:
        raise ValueError("The release tag does not point to the checked-out commit.")
    return commit


def verify_app(root, app, version, build_number):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != build_number:
        raise ValueError("The app version/build number does not match this release.")
    for name in ["LICENSE", "NOTICE"]:
        if (contents / "Resources" / name).read_bytes() != (root / name).read_bytes():
            raise ValueError(f"Missing or outdated bundled {name}.")
    bridge = contents / "Resources/SteamBridge"
    manifest = json.loads((root / "BridgeComponents/release.json").read_text())
    if (bridge / "release.json").read_bytes() != (root / "BridgeComponents/release.json").read_bytes():
        raise ValueError("The bundled bridge inventory is outdated.")
    compiled = json.loads((bridge / "build.json").read_text())["files"]
    if set(compiled) != set(manifest["compiled"]):
        raise ValueError("The compiled bridge inventory is incomplete.")
    for name, entry in {**manifest["files"], **compiled}.items():
        if not matches(bridge / name, entry):
            raise ValueError(f"The bundled component failed integrity verification: {name}")
    for name in ["MacOS/Playdock", "MacOS/PlaydockSteamIntegration"]:
        arches = run("/usr/bin/lipo", "-archs", contents / name, capture_output=True, text=True).stdout.split()
        if arches != ["arm64"]:
            raise ValueError(f"The app must support Apple silicon only: {name}")
    # Wine game processes can need the Intel adapter even on Apple silicon.
    for arch in ["arm64", "x86_64"]:
        run("/usr/bin/lipo", contents / "Frameworks/libPlaydockWineDisplay.dylib", "-verify_arch", arch)
    for name in manifest["compiled"]:
        if name != "payload/run":
            for arch in (["arm64", "x86_64"] if name == "payload/overlay-shim.dylib" else ["arm64"]):
                run("/usr/bin/lipo", bridge / name, "-verify_arch", arch)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def archive_source(root, commit, version, destination):
    prefix = f"Playdock-{version}/"
    run("git", "archive", "--format=tar.gz", f"--prefix={prefix}",
        f"--output={destination}", commit, cwd=root)
    required = ["LICENSE", "NOTICE", "Scripts/build.sh", "BridgeComponents/release.json",
                "BridgeComponents/WineSteamInterop.zip", "Sources/PlaydockSteamRuntime/README.md",
                "Sources/PlaydockSteamRuntime/InteropSources/lsteamclient/build.sh",
                "Sources/PlaydockSteamRuntime/InteropSources/steam-shim/build.sh"]
    with tarfile.open(destination) as archive:
        names = set(archive.getnames())
        if any(prefix + name not in names for name in required):
            raise ValueError("The source archive is missing licenses, components, or rebuild scripts.")


def checksums(directory, names):
    lines = []
    for name in names:
        checksum = hashlib.sha256()
        with (directory / name).open("rb") as source:
            for chunk in iter(lambda: source.read(1_048_576), b""):
                checksum.update(chunk)
        lines.append(f"{checksum.hexdigest()}  {name}\n")
    (directory / "SHA256SUMS").write_text("".join(lines))


def package(tag):
    version = release_version(tag)
    build_number = os.environ.get("GITHUB_RUN_NUMBER", "1")
    if not re.fullmatch(r"[1-9][0-9]*", build_number):
        raise ValueError("The build number must be a positive integer.")
    commit = source_commit(ROOT, tag)
    env = dict(os.environ, PLAYDOCK_VERSION=version, PLAYDOCK_BUILD_NUMBER=build_number)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    run("bash", ROOT / "Scripts/build.sh", env=env)
    if source_commit(ROOT, tag) != commit:
        raise ValueError("Source changed during the build; refusing to package mismatched source.")
    verify_app(ROOT, ROOT / "build/Playdock.app", version, build_number)
    destination = ROOT / "build/release"
    with tempfile.TemporaryDirectory(dir=ROOT / "build", prefix=".release-") as temporary:
        staging = Path(temporary)
        binary = f"Playdock-{version}-macOS-arm64.zip"
        source = f"Playdock-{version}-source.tar.gz"
        shutil.copy2(ROOT / "build/Playdock-macOS-arm64.zip", staging / binary)
        archive_source(ROOT, commit, version, staging / source)
        details = {"tag": tag, "commit": commit, "version": version, "buildNumber": build_number,
                   "architectures": ["arm64"], "signing": "ad-hoc", "notarized": False,
                   "xcode": run("xcodebuild", "-version", env=env, capture_output=True, text=True).stdout.strip(),
                   "swift": run("xcrun", "swift", "--version", env=env, capture_output=True, text=True).stdout.strip()}
        (staging / "BUILD_INFO.json").write_text(json.dumps(details, indent=2) + "\n")
        checksums(staging, [binary, source, "BUILD_INFO.json"])
        (staging / "RELEASE_NOTES.md").write_text(
            f"Apple silicon macOS app, built from `{commit}`.\n\n"
            "Requires macOS 13+. Windows Steam support additionally requires Apple silicon, "
            "macOS 26+, and a compatible activated CrossOver Preview.\n\n"
            "This build is ad-hoc signed and not notarized. The source archive includes "
            "component notices and rebuild instructions. Verify downloads with `shasum -a 256 -c SHA256SUMS`.\n")
        if destination.is_symlink():
            raise ValueError("The release output must not be a symlink.")
        if destination.exists():
            destination.rename(staging / "previous")
        destination.mkdir()
        for path in staging.iterdir():
            if path.is_file():
                path.rename(destination / path.name)
    print(f"Release assets: {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Version label, such as v0.1.0; does not create or push a tag")
    args = parser.parse_args()
    try:
        package(args.tag)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")
