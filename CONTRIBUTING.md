# Contributing

Use Xcode 26+ with Swift 6.2 and CMake. Native hook dependencies are vendored; there are no external Swift packages.

## Checks

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
python3 Scripts/test_steam_integration.py
xcodebuild -project Playdock.xcodeproj -scheme Playdock \
  -destination 'platform=macOS' test
bash Scripts/build.sh
```

Run core tests for logic changes and Xcode tests/builds for app or native adapter changes. Regenerate the project after adding source files:

```sh
python3 Scripts/generate_project.py
```

## Code

- Keep AppKit and published UI state on `MainActor`; use dedicated actors for background workflows and immutable snapshots for views.
- Feature models in `PlaydockPresentation` own UI state and worker actors. Views subscribe through `ObservedFeatures`; keep feature updates off the app navigation model.
- Coalesce refreshes, retain tasks through cleanup, and reject late results after cancellation or scope changes.
- Keep blocking socket I/O on dedicated queues. Explain any unsafe or `@unchecked Sendable` boundary.
- Preserve account/environment isolation and verify process identity before signaling a process.
- Comment on non-obvious constraints and reasons; avoid narrating the code.

## Local probes

Debug builds accept `--settings-file=/absolute/path.json` for isolated settings, `--ui-responsiveness-probe=/absolute/path.json`, `--probe-delay-library=10`, and `--ignore-installed-cache`. Home and fullscreen checks use `--home-controls-probe=/absolute/path.json` and `--show-couch --couch-ui-probe=/absolute/path.json`. Fullscreen page/dialog parity uses `--show-couch --couch-parity-probe=/absolute/path.json`.

`Scripts/Integration/` contains local Steam/Wine probes. Read a script before running it: some start applications or change a managed test environment. Test success does not establish compatibility with every game.

After a release build, `python3 Scripts/Integration/GameDockProbe.py` checks Dock icons and `python3 Scripts/Integration/NativeWindowProbe.py` checks window tracking, activation, and disconnect using disposable AppKit processes.

Xcode builds the Steam hooks and launcher helpers through `Scripts/prepare_steam_bridge.py`, with no build-time downloads. Five pinned Wine/Steamworks adapters are vendored in `BridgeComponents/WineSteamInterop.zip`; their authored source, dependency pins, and rebuild scripts are in [Sources/PlaydockSteamRuntime](Sources/PlaydockSteamRuntime). The inventory is in `BridgeComponents/release.json`. Check native compatibility gates with `python3 Scripts/test_steam_integration.py`.

Keep contributions under the project's [GPL-3.0 license](LICENSE) and preserve existing notices. Include the relevant validation with your change. Publish binary releases with their matching source; the app bundles `LICENSE` and `NOTICE`.
