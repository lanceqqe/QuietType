#!/bin/zsh
# Publishes the version in scripts/Info.plist as a GitHub release with the DMG attached.
# Installed copies pick it up on their next update check (at launch and once a day).
set -euo pipefail
cd "${0:A:h:h}"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)"
[[ -z "$(git status --porcelain)" ]] || { print "Commit your changes first."; exit 1 }
swift test
./scripts/make-dmg.sh
git push origin HEAD
gh release create "v$version" "dist/QuietType-$version.dmg" --title "QuietType $version" --generate-notes
