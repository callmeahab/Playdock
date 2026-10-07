# Wayfarer

A native macOS game library for Mac and Windows. Launch Mac games directly and Windows games through your installed CrossOver, Wine, or compatible GPTK engine.

- One Steam library with platform selection, search, favorites, and collections.
- Native install, download, storage, achievement, and session controls.
- Local save backups and per-game launch settings.
- Quick launcher (`⌘K`) and controller fullscreen (`⌘⇧F`).

Steam handles sign-in, licenses, updates, and game services. Games open in their own windows.

## Build

Runs on macOS 13+. Steam games require Steam; Windows games also require a compatibility engine supplied by you.

Build with Xcode 26+ (Swift 6.2): open `Wayfarer.xcodeproj`, select **Wayfarer / My Mac**, and run. To package a universal Intel/Apple silicon app:

```sh
bash Scripts/build.sh
open build/Wayfarer.app
```

Outputs: `build/Wayfarer.app` and `build/Wayfarer-macOS.zip`. Local builds are ad-hoc signed. See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and development notes.

## Use

Choose a Windows environment in **Engines**, or use native Mac Steam. Existing CrossOver Steam bottles are discovered automatically; **Set up Steam** creates a separate Wayfarer environment. Sign in through **Open Steam**.

Saved libraries appear while fresh scans run. Offline play depends on Steam's cached login and each game's offline support. Download scheduling requires Wayfarer to remain open. Save restoration requires the game to be closed.

## Limitations and local data

- Steam controls use private client APIs that can change. Unsupported actions remain available through **Open Steam**.
- Managed Wine display support is experimental; game compatibility depends on the engine and game.
- Mac Steam and reused CrossOver account/chat panels need Screen Recording and Accessibility permission. Ordinary browsing and background startup do not. Rebuilt ad-hoc apps may need permissions granted again.
- Settings, caches, owned prefixes, and save backups: `~/Library/Application Support/Wayfarer/`. Logs: `~/Library/Logs/Wayfarer/`; review raw logs before sharing.

## License

[GNU GPL-3.0](LICENSE). Commercial use is allowed; distributed derivatives must retain GPL licensing and provide corresponding source. See [NOTICE](NOTICE) for attribution. Steam and compatibility engines remain under their providers' licenses and are not bundled.
