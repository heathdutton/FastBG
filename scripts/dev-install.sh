#!/bin/bash
# Builds a team-signed fastbg with Xcode, copies it to /Applications and opens that copy, since a system extension
# only activates from there. Release, because a Debug build's unoptimized Swift costs several times the CPU per
# frame, which makes every measurement of the live pipeline wrong.
#
# The build number is a hash of the extension's sources and project.yml, which writes its Info.plist and
# entitlements. macOS only replaces an activated extension whose version changed, so a new relay needs a new number.
# But every replacement can make launchd drop the camera until it's toggled off and on in System Settings, so changes
# anywhere else keep the number and never replace it.
set -euo pipefail

cd "$(dirname "$0")/.."

grep -Eq '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10} *$' Signing.xcconfig || {
  echo "put the team ID in Signing.xcconfig" >&2
  exit 1
}
command -v xcodegen >/dev/null || {
  echo "xcodegen missing: brew install xcodegen" >&2
  exit 1
}

version=$(cat Extension/*.swift Shared/*.swift project.yml | cksum | cut -d' ' -f1)

xcodegen generate --quiet
xcodebuild -project fastbg.xcodeproj -scheme fastbg -configuration Release -derivedDataPath build/xcode \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet CURRENT_PROJECT_VERSION="$version" build

pkill -x FastBG || pkill -x fastbg || true
# LaunchServices refuses to open an app whose previous instance is still on its way out.
while pgrep -x FastBG >/dev/null || pgrep -x fastbg >/dev/null; do sleep 0.2; done
# ditto merges into an existing bundle, and a file left over from an older build breaks its signature.
# APFS ignores case, so this also clears the fastbg.app from before the rename.
rm -rf /Applications/FastBG.app
ditto build/xcode/Build/Products/Release/FastBG.app /Applications/FastBG.app
open /Applications/FastBG.app
