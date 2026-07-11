#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/WizCinema"
APP_PATH="$ROOT/dist/WizCinema.app"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/WizCinema"
cp "$ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign - --identifier com.local.WizCinema "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
print "Built $APP_PATH"
