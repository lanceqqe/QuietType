#!/bin/zsh
# Builds dist/QuietType-<version>.dmg: the app, an /Applications shortcut and install notes.
# The model (1.4 GB) is not inside; the app downloads it on first launch.
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build-app.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto dist/QuietType.app "$stage/QuietType.app"
ln -s /Applications "$stage/Applications"
cp scripts/INSTALL.txt "$stage/Как установить.txt"
dmg_path="dist/QuietType-$version.dmg"
rm -f "$dmg_path"
hdiutil create -volname "QuietType" -srcfolder "$stage" -fs HFS+ -format UDZO -quiet "$dmg_path"
print "Built: $PWD/$dmg_path"
