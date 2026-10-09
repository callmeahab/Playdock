# Playdock

A native macOS game library for Mac and Windows. Steam games use the Mac Steam client, with Windows games running through the CrossOver bridge. Non-Steam Windows apps can use CrossOver, Wine, or compatible GPTK.

- One Steam library with automatic native or compatibility launches, search, favorites, and collections.
- Native install, download, storage, achievement, and session controls.
- Local save backups and per-game launch settings.
- Quick launcher (`⌘K`) and controller fullscreen (`⌘⇧F`) with the same pages and game controls.

Steam handles sign-in, licenses, updates, and game services. Games open in their own windows. Windows games select Playdock CrossOver automatically; launch notices use Steam’s local API.

## Build

Runs on macOS 13+. Steam games require Steam; Steam games for Windows require the bridge described below. Non-Steam Windows apps require a compatibility engine supplied by you.

Build with Xcode 26+ (Swift 6.2) and CMake: open `Playdock.xcodeproj`, select **Playdock / My Mac**, and run. To package a universal Intel/Apple silicon app:

```sh
bash Scripts/build.sh
open build/Playdock.app
```

Outputs: `build/Playdock.app` and `build/Playdock-macOS.zip`. Local builds are ad-hoc signed. See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and development notes.

## Use

First launch detects Steam and CrossOver and shows the next setup step. Enable Windows games with one button, or continue with native Mac games and set up Windows support later in **Engines**. Setup remembers your choice; **Settings → Set up Playdock** reopens it. Windows Steam games require Apple silicon, macOS 26+, and activated CrossOver Preview 20260821 or 20261006; CrossOver 26.3 has no compatible patch table. Playdock prepares a separate CrossOver runner, downloads required Valve components, and restarts Steam safely. Steam updates remain enabled; unsupported builds require updated patches. Repair, removal, and runtime selection are under **Advanced options**.

Setup opens Steam’s own window for sign-in; return to Playdock and choose **I’ve signed in** to reconnect. Steam stays hidden during normal play while Playdock uses its local API for games, downloads, Workshop subscriptions, and settings. Workshop browsing and web chat open in your browser. **Engines → Non-Steam environment** selects a bottle or prefix for added Windows games and installers.

In fullscreen, **Navigate** (controller Menu / `M`) opens every page; `Y` / `D` opens game details and `B` / Escape goes back.

**Game details → Workshop & mods** shows subscriptions and downloaded items from Mac Steam for the game's installation. Browse in Steam or paste an item link to subscribe; manage local enable state and load order while the game is closed. Steam downloads and updates mods. Games may use their own mod manager instead of Steam's local settings.

**Game settings → Compatibility** controls the runtime, supported CrossOver graphics, MSync, and Metal HUD settings. Browse prefix files, the C: drive, user folders, and launch logs, or open Wine configuration and the registry editor after closing the game. Steam uses one managed runtime with a separate prefix per game. With the bridge, settings apply per game at launch. Bottle environment changes affect all its games and require its Windows apps to be closed. **Performance** provides background quiet mode and frame timing reports. Record a 30-second HUD run or import frame timings to compare matching scenes and shader-cache states; reports can be exported as JSON.

Saved libraries appear while fresh scans run. Offline play depends on Steam's cached login and each game's offline support. Download scheduling requires Playdock to remain open. Save restoration requires the game to be closed.

## Limitations and local data

- Steam controls use private client APIs that can change. Sign-in and unsupported confirmations require Steam outside Playdock.
- Managed Wine display support is experimental; game compatibility depends on the engine and game.
- Settings, caches, owned prefixes, and save backups: `~/Library/Application Support/Playdock/`. Logs: `~/Library/Logs/Playdock/`; review raw logs before sharing.

## License

[GNU GPL-3.0](LICENSE). Commercial use is allowed; distributed derivatives must retain GPL licensing and provide corresponding source. See [NOTICE](NOTICE) for attribution. Steam, compatibility engines, and bridge components retain their upstream licenses.
