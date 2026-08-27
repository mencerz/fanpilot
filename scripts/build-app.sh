#!/bin/zsh
set -euo pipefail

FANPILOT_ROOT="${0:A:h:h}"
FANPILOT_OUTPUT="$FANPILOT_ROOT/dist"
FANPILOT_APP="$FANPILOT_OUTPUT/FanPilot.app"
FANPILOT_CACHE="$FANPILOT_ROOT/.build/local-cache"
FANPILOT_APP_ID="com.oleksii.baliuk.fanpilot.app"
FANPILOT_HELPER_ID="com.oleksii.baliuk.fanpilot.helper"

/bin/mkdir -p "$FANPILOT_CACHE/clang" "$FANPILOT_CACHE/swiftpm"
export XDG_CACHE_HOME="$FANPILOT_CACHE"
export CLANG_MODULE_CACHE_PATH="$FANPILOT_CACHE/clang"
export SWIFTPM_CONFIG_DIR="$FANPILOT_CACHE/swiftpm"

cd "$FANPILOT_ROOT"
swift build -c release --disable-sandbox --product FanPilot
swift build -c release --disable-sandbox --product FanPilotHelper
FANPILOT_BIN="$(swift build -c release --disable-sandbox --show-bin-path)"

/bin/rm -rf "$FANPILOT_APP"
/bin/mkdir -p "$FANPILOT_APP/Contents/MacOS"
/bin/mkdir -p "$FANPILOT_APP/Contents/Resources"
/bin/mkdir -p "$FANPILOT_APP/Contents/Library/LaunchDaemons"

/bin/cp "$FANPILOT_ROOT/Resources/Info.plist" "$FANPILOT_APP/Contents/Info.plist"
/bin/cp "$FANPILOT_ROOT/Resources/AppIcon.icns" "$FANPILOT_APP/Contents/Resources/AppIcon.icns"
/bin/cp "$FANPILOT_ROOT/Resources/$FANPILOT_HELPER_ID.plist" "$FANPILOT_APP/Contents/Library/LaunchDaemons/$FANPILOT_HELPER_ID.plist"
# Shipped only so the app can unregister the daemon installed by older builds.
/bin/cp "$FANPILOT_ROOT/Resources/com.fanpilot.helper.plist" "$FANPILOT_APP/Contents/Library/LaunchDaemons/com.fanpilot.helper.plist"
/bin/cp "$FANPILOT_BIN/FanPilot" "$FANPILOT_APP/Contents/MacOS/FanPilot"
/bin/cp "$FANPILOT_BIN/FanPilotHelper" "$FANPILOT_APP/Contents/MacOS/FanPilotHelper"

/usr/bin/codesign --force --sign - --identifier "$FANPILOT_HELPER_ID" "$FANPILOT_APP/Contents/MacOS/FanPilotHelper"
/usr/bin/codesign --force --sign - --identifier "$FANPILOT_APP_ID" "$FANPILOT_APP/Contents/MacOS/FanPilot"
/usr/bin/codesign --force --sign - --identifier "$FANPILOT_APP_ID" "$FANPILOT_APP"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$FANPILOT_APP"
/usr/bin/plutil -lint "$FANPILOT_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$FANPILOT_APP/Contents/Library/LaunchDaemons/$FANPILOT_HELPER_ID.plist"

echo "$FANPILOT_APP"
