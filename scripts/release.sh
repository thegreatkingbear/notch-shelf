#!/bin/zsh
# Builds Notch Shelf for distribution outside the App Store and packages it as a DMG.
#
#   scripts/release.sh               Local test: signs with your development
#                                    certificate (Config/Signing.local.xcconfig).
#                                    Not notarized; other Macs will block it.
#   TEAM_ID=ABCDE12345 NOTARY_PROFILE=notchshelf scripts/release.sh
#                                    Release: signs with Developer ID, notarizes
#                                    and staples the DMG.
#
# A release needs a paid Apple Developer Program membership, a "Developer ID
# Application" certificate in the login keychain, and notary credentials saved once:
#
#   xcrun notarytool store-credentials notchshelf \
#     --apple-id you@example.com --team-id ABCDE12345 --password <app-specific password>
#
# Output goes to dist/, which git ignores.
set -euo pipefail

cd "${0:A:h}/.."
root=$PWD
dist=$root/dist
build=$dist/build
app=$build/NotchShelf.app
team=${TEAM_ID:-}
profile=${NOTARY_PROFILE:-}

step() { print -P "%B==> $1%b"; }

if [[ -n $profile && -z $team ]]; then
  print -u2 "NOTARY_PROFILE needs TEAM_ID as well."
  exit 1
fi

signing=()
if [[ -n $team ]]; then
  signing=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application"
           DEVELOPMENT_TEAM=$team "OTHER_CODE_SIGN_FLAGS=--timestamp"
           CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO)
fi

version=$(xcodebuild -project NotchShelf.xcodeproj -scheme NotchShelf -configuration Release \
  -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
dmg=$dist/NotchShelf-$version.dmg

step "Building Notch Shelf $version"
rm -rf "$build" "$dmg"
xcodebuild -project NotchShelf.xcodeproj -scheme NotchShelf -configuration Release \
  -destination generic/platform=macOS -derivedDataPath "$dist/DerivedData" CONFIGURATION_BUILD_DIR="$build" \
  "${signing[@]}" clean build | grep -E "error:|warning:|BUILD" || true
[[ -d $app ]] || { print -u2 "Build failed."; exit 1; }

step "Checking the signature"
codesign --verify --deep --strict "$app"
details=$(codesign -dvv "$app" 2>&1)
print -r -- "$details" | grep -E "^(Authority|TeamIdentifier)=" | head -2
if ! print -r -- "$details" | grep -q "flags=.*runtime"; then
  print -u2 "Hardened Runtime is off; notarization would reject this build."
  exit 1
fi
if codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q "get-task-allow"; then
  [[ -n $team ]] && { print -u2 "The build allows debugging (get-task-allow); notarization would reject it."; exit 1; }
fi

step "Packaging $dmg:t"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/NotchShelf.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Notch Shelf" -srcfolder "$stage" -ov -format UDZO "$dmg"

if [[ -z $team ]]; then
  step "Done (local test build, not notarized)"
  print "$dmg"
  exit 0
fi

codesign --sign "Developer ID Application" --timestamp "$dmg"

if [[ -z $profile ]]; then
  step "Signed but not notarized: set NOTARY_PROFILE to notarize"
  print "$dmg"
  exit 0
fi

step "Notarizing (this usually takes a few minutes)"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"

step "Done"
print "$dmg"
shasum -a 256 "$dmg"
