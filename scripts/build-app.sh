#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release --arch arm64 --product QuietType
product_dir="$(swift build -c release --arch arm64 --show-bin-path)"
app_path="$PWD/dist/QuietType.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$product_dir/QuietType" "$app_path/Contents/MacOS/QuietType"
# SwiftPM's Bundle.module resolves resources from Contents/Resources.
for bundle_path in "$product_dir"/*.bundle(N); do
    ditto "$bundle_path" "$app_path/Contents/Resources/${bundle_path:t}"
done
cp scripts/Info.plist "$app_path/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
mkdir -p "$app_path/Contents/Resources/Licenses"
for dependency_path in .build/checkouts/*(N/); do
    for license_path in "$dependency_path"/LICENSE*(N.); do
        license_target="$app_path/Contents/Resources/Licenses/${dependency_path:t}-${license_path:t}"
        if [[ -f "$license_target" ]]; then chmod u+w "$license_target"; fi
        cp "$license_path" "$license_target"
    done
done
if [[ -f scripts/AppIcon.icns ]]; then
    cp scripts/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
fi
signing_identity="${QUIETTYPE_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    development_identities=(${(f)"$(security find-identity -v -p codesigning | awk '/Apple Development:/ { print $2 }')"})
    if (( ${#development_identities} == 1 )) && [[ -n "$development_identities[1]" ]]; then
        signing_identity="$development_identities[1]"
    else
        signing_identity="-"
    fi
fi
codesign --force --deep --sign "$signing_identity" --identifier app.quiettype.mac "$app_path"
codesign --verify --deep --strict "$app_path"
print "Built: $app_path"
