#!/bin/bash
# Makes build/Interspace.dmg, the download of a release: the app for Apple silicon and Intel, and a
# shortcut to the Applications folder to drag it to.
#
# The file name has no version in it, so this link always gets the newest release:
#   https://github.com/cnrad/interspace/releases/latest/download/Interspace.dmg
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY="interspace local signing"
KEYCHAIN="$HOME/Library/Keychains/interspace-signing.keychain-db"
SECRET_FILE="$HOME/.config/interspace/signing-keychain-password"
APP="build/Interspace.app"
DMG="build/Interspace.dmg"

# macOS ties the two permissions to the signature of the app. Each release must have the signature
# of the same identity, or everyone must allow the permissions again after each update.
if [ ! -f "$KEYCHAIN" ] || [ ! -f "$SECRET_FILE" ]; then
    echo "No signing identity. Run scripts/setup-signing.sh, and keep a copy of these two files:" >&2
    echo "  $KEYCHAIN" >&2
    echo "  $SECRET_FILE" >&2
    exit 1
fi

./scripts/bundle.sh --universal

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Interspace")"
case "$ARCHS" in
    *arm64*x86_64* | *x86_64*arm64*) ;;
    *) echo "The app is not universal. It has: $ARCHS" >&2; exit 1 ;;
esac
codesign --verify --strict "$APP"
# The app only installs an update that has the signature it knows. See Updater.swift.
RELEASE_HASH="$(grep -o 'certificate leaf = H"[0-9a-f]*"' Sources/Interspace/Updater.swift | grep -o '[0-9a-f]\{40\}')"
if ! codesign --verify -R "=identifier \"com.cnrad.interspace\" and certificate leaf = H\"$RELEASE_HASH\"" "$APP" 2>/dev/null; then
    echo "The signature of the app is not the one in Updater.swift ($RELEASE_HASH)." >&2
    echo "No app that is installed could update to this release." >&2
    exit 1
fi

VOLUME="Interspace"
if [ -e "/Volumes/$VOLUME" ]; then
    echo "A volume with the name $VOLUME is open. Eject it, then run this again." >&2
    exit 1
fi

WORK="$(mktemp -d)"
STAGE="$WORK/stage"
DRAFT="$WORK/draft.dmg"
trap 'hdiutil detach -quiet "/Volumes/$VOLUME" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$STAGE/.background"
# ditto keeps the signature as it is.
ditto "$APP" "$STAGE/Interspace.app"
ln -s /Applications "$STAGE/Applications"
# Made by scripts/dmg-background.swift.
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# Finder keeps the look of a window in a file on the volume. So the image is first one that can be
# written to, Finder sets the window, and then the image is made small and read-only.
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW "$DRAFT"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$DRAFT"

# The size and the positions are the numbers of `Layout` in scripts/dmg-background.swift.
# The window is 28 points higher than the picture, for its title bar.
# macOS asks one time if the terminal can control Finder.
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 112
        set text size of viewOptions to 12
        -- Finder gives no setting for the colour of the labels. It makes them white on a dark
        -- background colour, so the colour is set to that of the picture before the picture is set.
        set background color of viewOptions to {2570, 3084, 7710}
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Interspace.app" of container window to {176, 176}
        set position of item "Applications" of container window to {464, 176}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
if [ ! -f "/Volumes/$VOLUME/.DS_Store" ]; then
    echo "Finder did not keep the look of the window." >&2
    exit 1
fi
hdiutil detach -quiet "/Volumes/$VOLUME"

rm -f "$DMG"
hdiutil convert -quiet "$DRAFT" -format UDZO -imagekey zlib-level=9 -o "$DMG"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$DMG"

echo "Built $DMG (Interspace $VERSION, $ARCHS)"
