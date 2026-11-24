#!/usr/bin/env bash
# Builds build/HearMe.app. Pass --install to copy it to ~/Applications and relaunch it.
#
# Signing with a real certificate (not ad-hoc) keeps the Microphone and
# Accessibility grants across rebuilds. Override with HEARME_SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

# Default: an Apple Development certificate whose name contains your macOS user name.
IDENTITY="${HEARME_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' -v user="$USER" 'index(tolower($2), tolower(user)) && /Apple Development/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/HearMe"

APP=build/HearMe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HearMe"
cp Vendor/lib/*.dylib "$APP/Contents/Frameworks/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --timestamp=none --sign "$IDENTITY" "$APP"/Contents/Frameworks/*.dylib
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x HearMe 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/HearMe.app"
    cp -R "$APP" "$HOME/Applications/"
    open "$HOME/Applications/HearMe.app"
    echo "Installed and launched ~/Applications/HearMe.app"
fi
