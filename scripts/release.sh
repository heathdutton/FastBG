#!/bin/bash
# Builds dist/fastbg-<version>.zip: archived, re-signed with Developer ID at export, notarized and stapled.
#
# Needs full Xcode, xcodegen, the team ID in Signing.xcconfig, and Apple Development and Developer ID Application
# certificates for that team. Then either of two ways to sign in to Apple:
#
# - On a Mac: Xcode signed in to the team's Apple ID, and FASTBG_NOTARY_PROFILE naming a notarytool keychain profile
#   saved once with `xcrun notarytool store-credentials fastbg --apple-id <apple id> --team-id <team id>`.
# - In CI: an App Store Connect API key, its .p8 file in FASTBG_ASC_KEY, with FASTBG_ASC_KEY_ID and FASTBG_ASC_ISSUER.
#   scripts/ci-signing.sh sets that up.
#
# The version is the plain semver tag on HEAD (1.2.3, no v), else MARKETING_VERSION from project.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

ext_id=com.heathdutton.fastbg.camera
build=build/release
dist=dist

die() {
  echo "release: $*" >&2
  exit 1
}

grep -Eq '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10} *$' Signing.xcconfig || die "put the team ID in Signing.xcconfig"
command -v xcodegen >/dev/null || die "xcodegen missing: brew install xcodegen"

# The key's ID and issuer name it without granting anything, so argv is fine for them. The .p8 stays a file.
auth=()
if [[ -n ${FASTBG_ASC_KEY:-} ]]; then
  [[ -f $FASTBG_ASC_KEY ]] || die "no API key at $FASTBG_ASC_KEY"
  : "${FASTBG_ASC_KEY_ID:?set FASTBG_ASC_KEY_ID}" "${FASTBG_ASC_ISSUER:?set FASTBG_ASC_ISSUER}"
  auth=(-authenticationKeyPath "$FASTBG_ASC_KEY" -authenticationKeyID "$FASTBG_ASC_KEY_ID"
    -authenticationKeyIssuerID "$FASTBG_ASC_ISSUER")
  notary=(--key "$FASTBG_ASC_KEY" --key-id "$FASTBG_ASC_KEY_ID" --issuer "$FASTBG_ASC_ISSUER")
else
  : "${FASTBG_NOTARY_PROFILE:?set FASTBG_NOTARY_PROFILE to a notarytool keychain profile name}"
  notary=(--keychain-profile "$FASTBG_NOTARY_PROFILE")
fi

# sysextd only offers to replace an activated extension whose version differs, so each commit gets its own build
# number, and outside git every release would ship the same one.
git rev-parse --verify -q HEAD >/dev/null 2>&1 || die "not in a git repo with commits, so there's no build number"
overrides=("CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)")
tag=$(git describe --tags --exact-match HEAD 2>/dev/null || true)
if [[ -n $tag ]]; then
  [[ $tag =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag $tag on HEAD isn't plain semver like 1.2.3"
  [[ -z $(git status --porcelain) ]] || die "uncommitted changes, so the build wouldn't match tag $tag"
  overrides+=("MARKETING_VERSION=$tag")
fi

rm -rf "${build:?}"
mkdir -p "$build" "$dist"

xcodegen generate --quiet

xcodebuild archive \
  -project fastbg.xcodeproj \
  -scheme fastbg \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$build/fastbg.xcarchive" \
  -derivedDataPath "$build/DerivedData" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  -quiet \
  "${overrides[@]}"

xcodebuild -exportArchive \
  -archivePath "$build/fastbg.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$build/export" \
  -allowProvisioningUpdates \
  ${auth[@]+"${auth[@]}"} \
  -quiet

app=$build/export/FastBG.app
ext=$app/Contents/Library/SystemExtensions/$ext_id.systemextension
[[ -d $ext ]] || die "camera extension missing from $app"
codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -dvv "$app" 2>&1)
[[ $signature == *"Authority=Developer ID Application"* ]] || die "$app isn't signed with Developer ID"

# The camera only registers when its mach service name starts with one of its app groups.
mach=$(plutil -extract CMIOExtension.CMIOExtensionMachServiceName raw -o - "$ext/Contents/Info.plist")
codesign -d --entitlements "$build/camera.entitlements" --xml "$ext" 2>/dev/null
group=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$build/camera.entitlements")
[[ $mach == "$group"* ]] || die "mach service $mach doesn't start with app group $group"

version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CFBundleShortVersionString $version isn't plain semver"

ditto -c -k --keepParent "$app" "$build/notarize.zip"
xcrun notarytool submit "$build/notarize.zip" "${notary[@]}" --wait --timeout 1h \
  --output-format json >"$build/notary.json" || true
status=$(plutil -extract status raw -o - "$build/notary.json" 2>/dev/null || echo unknown)
if [[ $status != Accepted ]]; then
  cat "$build/notary.json" >&2
  id=$(plutil -extract id raw -o - "$build/notary.json" 2>/dev/null || true)
  if [[ -n $id ]]; then
    xcrun notarytool log "$id" "${notary[@]}" >&2 || true
  fi
  die "notarization came back $status"
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

zip=$dist/fastbg-$version.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
(cd "$dist" && shasum -a 256 "${zip##*/}" | tee "${zip##*/}.sha256")
echo "gh release create $version $zip $zip.sha256"
