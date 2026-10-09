# Contributing

Use Xcode 26+ (Swift 6.2), CMake, Python 3, and Node.js. Builds use vendored native dependencies and fetch no packages.

## Checks

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
python3 Scripts/test_steam_integration.py
python3 Scripts/test_release.py
xcodebuild -project Playdock.xcodeproj -scheme Playdock \
  -destination 'platform=macOS' test
bash Scripts/build.sh
```

CI runs these checks on Apple silicon, packages an arm64 app, and checks native window tracking and Dock icons. Local probes live in `Scripts/Integration/`; read them before running, since some start apps or modify test environments. Regenerate the project after adding source files:

```sh
python3 Scripts/generate_project.py
```

## Code

- Keep AppKit and published UI state on `MainActor`; use dedicated actors for background workflows and immutable snapshots for views.
- Feature models in `PlaydockPresentation` own UI state and worker actors; views subscribe through `ObservedFeatures`.
- Coalesce refreshes, retain tasks through cleanup, and reject late results after cancellation or scope changes.
- Keep blocking I/O off the main actor. Explain unsafe or `@unchecked Sendable` boundaries.
- Preserve account/environment isolation and verify process identity before signaling a process.
- Comment on non-obvious constraints and reasons; avoid narrating the code.

Xcode builds Steam helpers through `Scripts/prepare_steam_bridge.py`. Adapter source, dependency pins, and rebuild instructions are in [Sources/PlaydockSteamRuntime](Sources/PlaydockSteamRuntime/README.md); the component inventory is `BridgeComponents/release.json`.

## Releases

From a clean committed checkout, run `python3 Scripts/package_release.py v0.1.0` (replace the version). It builds and verifies the app, includes matching source and notices, and writes checksums and build details to `build/release/`.

Pushing a `vMAJOR.MINOR.PATCH` tag runs the full CI checks and creates a **draft** GitHub release with those assets. Review the draft before publishing. Reruns can update a draft but refuse to overwrite a published release. CI artifacts are ad-hoc signed and not notarized; Apple Developer ID signing and notarization remain necessary for a notarized public download.

Include validation with contributions, keep them under [GPL-3.0](LICENSE), and preserve component notices. Distribute binaries with their matching source archive.
