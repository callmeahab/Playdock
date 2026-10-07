# Contributing

Use Xcode 26+ with Swift 6.2. There are no external package dependencies.

## Checks

```sh
swift test
xcodebuild -project Wayfarer.xcodeproj -scheme Wayfarer \
  -destination 'platform=macOS' test
bash Scripts/build.sh
```

Run core tests for logic changes and Xcode tests/builds for app or native adapter changes. Regenerate the project after adding source files:

```sh
python3 Scripts/generate_project.py
```

## Code

- Keep AppKit and published UI state on `MainActor`; use dedicated actors for background workflows and immutable snapshots for views.
- Coalesce refreshes, retain tasks through cleanup, and reject late results after cancellation or scope changes.
- Keep blocking socket I/O on dedicated queues. Explain any unsafe or `@unchecked Sendable` boundary.
- Preserve account/environment isolation and verify process identity before signaling a process.
- Comment on non-obvious constraints and reasons; avoid narrating the code.

## Local probes

Debug builds accept `--ui-responsiveness-probe=/absolute/path.json`, `--probe-delay-library=10`, and `--ignore-installed-cache`. Home and fullscreen checks use `--home-controls-probe=/absolute/path.json` and `--show-couch --couch-ui-probe=/absolute/path.json`. Fullscreen page/dialog parity uses `--show-couch --couch-parity-probe=/absolute/path.json`.

`Scripts/Integration/` contains local Steam/Wine probes. Read a script before running it: some start applications or change a managed test environment. Test success does not establish compatibility with every game.

Keep contributions under the project's [GPL-3.0 license](LICENSE) and preserve existing notices. Include the relevant validation with your change. Publish binary releases with their matching source; the app bundles `LICENSE` and `NOTICE`.
