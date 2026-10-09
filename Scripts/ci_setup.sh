#!/bin/bash
set -euo pipefail

selected_developer=''
for app in /Applications/Xcode*.app; do
    developer="$app/Contents/Developer"
    if ! version=$(DEVELOPER_DIR="$developer" xcrun swift --version); then continue; fi
    if VERSION="$version" python3 -c 'import os,re,sys; v=re.search(r"Swift version (\d+)\.(\d+)",os.environ["VERSION"]); sys.exit(0 if v and tuple(map(int,v.groups())) >= (6,2) else 1)'; then
        selected_developer="$developer"
        break
    fi
done
if [[ -z "$selected_developer" ]]; then
    echo 'No installed Xcode provides Swift 6.2 or newer.' >&2
    exit 1
fi
export DEVELOPER_DIR="$selected_developer"
for tool in cmake python3 node; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
xcodebuild -version
xcrun swift --version
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
