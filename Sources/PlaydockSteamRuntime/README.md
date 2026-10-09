# Steam integration

Playdock builds the Steam hooks, overlay shim, game launcher, and icon/metadata helpers from source. The GPL code was adapted from NotProton c3a49486; see NOTICE. Dobby 5dfc8546 and cJSON are vendored. Performance controls live in Playdock, with no injected settings panel in Steam.

The app and Steam helpers target Apple silicon. Wine display and overlay adapters retain x86_64 slices for Windows game processes running under Rosetta.

`BridgeComponents/Resources` holds verified Steam signatures, per-build Wine detours, and Valve package pins. `BridgeComponents/WineSteamInterop.zip` holds five pinned Wine/Steamworks ABI adapters; these are dependencies, not a Steam client or a NotProton application. The tool ID `playdock-proton` contains `proton` because Steam uses that substring to select Windows Cloud-save paths. The adapter's `NOTPROTON_OVERLAY_SHIM` environment key is its compiled ABI.

To rebuild the adapters, install CMake, mingw-w64, bison, and flex, then run the following from `InteropSources`. Its scripts fetch pinned Wine, Proton, and SDK source; they do not install into Steam without `--install`.

```sh
sh bridge/setup-wine-tree.sh
WINE_BUILD="$PWD/scratch/wine-build-arm64" HOST=aarch64-apple-darwin \
  HOST_CC='clang -arch arm64' HOST_CXX='clang++ -arch arm64' sh bridge/setup-wine-tree.sh
bash lsteamclient/build.sh
UNIX_ARCH=arm64 WINE_BUILD="$PWD/scratch/wine-build-arm64" bash lsteamclient/build.sh --unix
bash steam-shim/build.sh
```

Update the archive entries, their records in `BridgeComponents/release.json`, and `SteamIntegrationRelease.resourceManifestSHA256` together. Rebuilding detours for a new CrossOver version also requires Capstone and LLVM; pin both the clean and patched ntdll hashes before enabling that build.
