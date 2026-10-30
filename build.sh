#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd -P)
BUILD="$ROOT/.build"
APP="$BUILD/Pi Sessions.app"
SDK=$(xcrun --show-sdk-path)
COMPILER=$(xcrun --find swiftc)
mkdir -p "$BUILD/cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
FLAGS=()

# Some upgraded CLT installs retain a second SwiftBridging module map.
# Mask only that stale map during this build; never edit the system toolchain.
INCLUDE="$(dirname "$(dirname "$COMPILER")")/include/swift"
if [[ -f "$INCLUDE/module.modulemap" && -f "$INCLUDE/bridging.modulemap" ]] &&
   grep -q 'module SwiftBridging' "$INCLUDE/module.modulemap" &&
   grep -q 'module SwiftBridging' "$INCLUDE/bridging.modulemap"; then
  printf '// Build-local mask for duplicate SwiftBridging module.\n' > "$BUILD/empty.modulemap"
  python3 - "$INCLUDE/module.modulemap" "$BUILD/empty.modulemap" "$BUILD/overlay.json" <<'PY'
import json, sys
with open(sys.argv[3], "w") as f:
    json.dump({"version": 0, "roots": [{"type": "file", "name": sys.argv[1], "external-contents": sys.argv[2]}]}, f)
PY
  FLAGS+=(-vfsoverlay "$BUILD/overlay.json")
fi

"$COMPILER" -swift-version 5 -O -sdk "$SDK" -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path "$BUILD/cache" "${FLAGS[@]}" "$ROOT"/native/*.swift \
  -o "$APP/Contents/MacOS/PiSessions"
cp "$ROOT/native/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/iterm.applescript" "$APP/Contents/Resources/iterm.applescript"
mkdir -p "$APP/Contents/Resources/icons" "$APP/Contents/Resources/icon-licenses"
cp "$ROOT/assets/icons/"*.png "$APP/Contents/Resources/icons/"
cp "$ROOT/assets/licenses/"*.txt "$APP/Contents/Resources/icon-licenses/"
codesign --force --sign - --identifier local.pi.sessions \
  --requirements '=designated => identifier "local.pi.sessions"' "$APP"
"$APP/Contents/MacOS/PiSessions" --self-test
printf '%s\n' "$APP"
