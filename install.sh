#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd -P)
AGENT="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
EXTENSION="$AGENT/extensions/session-panel"
APPS="${PI_SESSIONS_APP_DIR:-$HOME/Applications}"
DEST="$APPS/Pi Sessions.app"

if [[ -e "$EXTENSION" || -L "$EXTENSION" ]]; then
  [[ -L "$EXTENSION" && "$(readlink "$EXTENSION")" == "$ROOT" ]] || {
    echo "Refusing to replace unmanaged extension: $EXTENSION" >&2; exit 1;
  }
fi
if [[ -e "$DEST" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" == local.pi.sessions ]] || {
    echo "Refusing to replace another app: $DEST" >&2; exit 1;
  }
fi
bash "$ROOT/build.sh"
mkdir -p "$APPS" "$(dirname "$EXTENSION")"
STAGE=$(mktemp -d "$APPS/.pi-sessions-install.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$ROOT/.build/Pi Sessions.app" "$STAGE/Pi Sessions.app"
codesign --verify --deep --strict "$STAGE/Pi Sessions.app"
if [[ -e "$DEST" ]]; then
  osascript -e 'if application "Pi Sessions" is running then tell application "Pi Sessions" to quit'
  for ((i=0; i<50; i++)); do
    pgrep -x PiSessions >/dev/null || break
    sleep 0.1
  done
  if pgrep -x PiSessions >/dev/null; then echo 'Quit Pi Sessions before reinstalling.' >&2; exit 1; fi
  mv "$DEST" "$STAGE/previous.app"
fi
mv "$STAGE/Pi Sessions.app" "$DEST"
if [[ ! -e "$EXTENSION" ]]; then ln -s "$ROOT" "$EXTENSION"; fi
printf 'Installed: %s\n' "$DEST"
open "$DEST" --args --show
