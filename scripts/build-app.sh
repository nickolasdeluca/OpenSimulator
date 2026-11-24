#!/bin/sh
# Builds build/OpenSimulator.app. Usage: scripts/build-app.sh [debug|release]
set -eu

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/OpenSimulator.app"
BUNDLE_ID="${BUNDLE_ID:-com.nickolasdeluca.OpenSimulator}"
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$ROOT"
swift build -c "$CONFIG" --product OpenSimulator
swift build -c "$CONFIG" --product opensim
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/OpenSimulator" "$APP/Contents/MacOS/OpenSimulator"
# The command line tool and MCP server agents use. It finds the app it ships in to show them.
cp "$BIN_DIR/opensim" "$APP/Contents/Helpers/opensim"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"
# The icon is an Icon Composer document, so it follows the system's light, dark, tinted and clear
# appearances. actool compiles it into Assets.car, plus an AppIcon.icns for older macOS.
ICON_TMP="$(mktemp -d)"
xcrun actool packaging/AppIcon.icon \
    --compile "$APP/Contents/Resources" \
    --app-icon AppIcon \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$ICON_TMP/icon.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
rm -rf "$ICON_TMP"

# Shipped as source and built for the simulator on first use. A prebuilt simulator binary would
# be left out of the notarization ticket, and Gatekeeper would then reject the whole app.
cp Helpers/open-sensitive-url.m Helpers/open-sensitive-url.entitlements Helpers/set-hinge-angle.m "$APP/Contents/Resources/"

# Ad hoc signature so it runs locally. Not sandboxed: it loads Xcode's simulator frameworks and
# runs simctl, neither of which a sandboxed app may do.
IDENTITY="${CODESIGN_IDENTITY:--}"
# The helper is signed on its own first: signing the app does not reach into Contents/Helpers.
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --options runtime "$APP/Contents/Helpers/opensim"
    codesign --force --sign - --options runtime "$APP"
else
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP/Contents/Helpers/opensim"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi

echo "Built $APP"
