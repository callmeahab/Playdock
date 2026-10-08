#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$ROOT/Playdock.xcodeproj" -scheme Playdock -configuration Release -derivedDataPath "$ROOT/build/DerivedData" -destination 'generic/platform=macOS' 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build -quiet
APP="$ROOT/build/Playdock.app"
STAGING_ROOT="$(mktemp -d "$ROOT/build/.package-XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
ditto "$ROOT/build/DerivedData/Build/Products/Release/Playdock.app" "$STAGING_ROOT/Playdock.app"
if [[ -d "$APP" ]]; then mv "$APP" "$STAGING_ROOT/previous.app"; fi
mv "$STAGING_ROOT/Playdock.app" "$APP"
ditto -c -k --keepParent "$APP" "$ROOT/build/Playdock-macOS.zip"
echo "Built $APP"
