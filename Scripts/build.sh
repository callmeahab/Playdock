#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$ROOT/Wayfarer.xcodeproj" -scheme Wayfarer -configuration Release -derivedDataPath "$ROOT/build/DerivedData" -destination 'generic/platform=macOS' 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build -quiet
APP="$ROOT/build/Wayfarer.app"
ditto "$ROOT/build/DerivedData/Build/Products/Release/Wayfarer.app" "$APP"
ditto -c -k --keepParent "$APP" "$ROOT/build/Wayfarer-macOS.zip"
echo "Built $APP"
