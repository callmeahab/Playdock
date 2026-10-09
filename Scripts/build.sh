#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_SETTINGS=(ONLY_ACTIVE_ARCH=NO)
if [[ -n "${PLAYDOCK_VERSION:-}" ]]; then
    if [[ ! "$PLAYDOCK_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo 'PLAYDOCK_VERSION must be MAJOR.MINOR.PATCH.' >&2
        exit 1
    fi
    BUILD_SETTINGS+=("MARKETING_VERSION=$PLAYDOCK_VERSION")
fi
if [[ -n "${PLAYDOCK_BUILD_NUMBER:-}" ]]; then
    if [[ ! "$PLAYDOCK_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        echo 'PLAYDOCK_BUILD_NUMBER must be a positive integer.' >&2
        exit 1
    fi
    BUILD_SETTINGS+=("CURRENT_PROJECT_VERSION=$PLAYDOCK_BUILD_NUMBER")
fi
xcodebuild -project "$ROOT/Playdock.xcodeproj" -scheme Playdock -configuration Release -derivedDataPath "$ROOT/build/DerivedData" -destination 'generic/platform=macOS' "${BUILD_SETTINGS[@]}" build -quiet
APP="$ROOT/build/Playdock.app"
STAGING_ROOT="$(mktemp -d "$ROOT/build/.package-XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
ditto "$ROOT/build/DerivedData/Build/Products/Release/Playdock.app" "$STAGING_ROOT/Playdock.app"
if [[ "$(/usr/bin/lipo -archs "$STAGING_ROOT/Playdock.app/Contents/MacOS/Playdock")" != arm64 ]]; then
    echo 'Playdock must be built for Apple silicon only.' >&2
    exit 1
fi
/usr/bin/codesign --verify --deep --strict "$STAGING_ROOT/Playdock.app"
if [[ -d "$APP" ]]; then mv "$APP" "$STAGING_ROOT/previous.app"; fi
mv "$STAGING_ROOT/Playdock.app" "$APP"
ditto -c -k --keepParent "$APP" "$STAGING_ROOT/Playdock-macOS-arm64.zip"
mv "$STAGING_ROOT/Playdock-macOS-arm64.zip" "$ROOT/build/Playdock-macOS-arm64.zip"
echo "Built $APP"
