#!/usr/bin/env python3
"""Check release versioning and matching-source guards with disposable repositories."""
import hashlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

import package_release as release


class ReleaseTests(unittest.TestCase):
    def test_version_labels(self):
        self.assertEqual(release.release_version("v0.1.0"), "0.1.0")
        for label in ["0.1.0", "v01.0.0", "v1.0", "v1.0.0-beta.1", "v1.0.0/../../file", "v1.0.0\n"]:
            with self.subTest(label=label), self.assertRaises(ValueError):
                release.release_version(label)

    def test_source_archive_and_checkout_guards(self):
        with tempfile.TemporaryDirectory(prefix="playdock-release-test-") as temporary:
            root = Path(temporary)
            def git(*args):
                subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)
            git("init")
            paths = ["LICENSE", "NOTICE", "Scripts/build.sh", "BridgeComponents/release.json",
                     "BridgeComponents/WineSteamInterop.zip", "Sources/PlaydockSteamRuntime/README.md",
                     "Sources/PlaydockSteamRuntime/InteropSources/lsteamclient/build.sh",
                     "Sources/PlaydockSteamRuntime/InteropSources/steam-shim/build.sh"]
            for name in paths:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("committed fixture\n")
            (root / ".gitignore").write_text("build/\n")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Fixture")
            git("tag", "v0.1.0")
            commit = release.source_commit(root, "v0.1.0")
            output = root / "build"
            output.mkdir()
            archive = output / "source.tar.gz"
            release.archive_source(root, commit, "0.1.0", archive)
            with tarfile.open(archive) as source:
                names = source.getnames()
                self.assertNotIn("Playdock-0.1.0/.git", names)
                self.assertFalse(any("/build/" in name for name in names))
                self.assertEqual(source.extractfile("Playdock-0.1.0/NOTICE").read(), b"committed fixture\n")
            (root / "NOTICE").write_text("uncommitted notice")
            with self.assertRaises(ValueError):
                release.source_commit(root, "v0.1.0")
            git("checkout", "--", "NOTICE")
            stray = root / "untracked.txt"
            stray.touch()
            with self.assertRaises(ValueError):
                release.source_commit(root, "v0.1.0")
            stray.unlink()
            (root / "NOTICE").write_text("a new committed notice")
            git("add", "NOTICE")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Changed")
            with self.assertRaises(ValueError):
                release.source_commit(root, "v0.1.0")
            self.assertNotEqual(release.source_commit(root, "v0.2.0"), commit)
            release.checksums(output, [archive.name])
            expected = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual((output / "SHA256SUMS").read_text(), f"{expected}  source.tar.gz\n")
            git("rm", "LICENSE")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "Missing license")
            with self.assertRaises(ValueError):
                release.archive_source(root, release.source_commit(root, "v0.3.0"), "0.3.0", archive)


if __name__ == "__main__":
    unittest.main()
