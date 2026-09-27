#!/bin/bash
# Builds what can be built without Xcode or a team, into build/dev:
#   FastBG.app     ad-hoc signed. Runs from anywhere, but its camera extension can't activate unsigned.
#   fastbg-camera  the extension's binary, compiled to prove it builds
#   fastbg-check   the dev harness in Checks/Harness, linked against the app's sources
# Pass the names to build a subset: scripts/dev-build.sh check
set -euo pipefail

cd "$(dirname "$0")/.."

# The Command Line Tools can ship an SDK newer than their compiler understands, so take the first SDK, newest first,
# that the compiler can actually import Swift from.
pick_sdk() {
  local probe candidate
  probe=$(mktemp -d)
  : >"$probe/probe.swift"
  for candidate in "$(xcrun --sdk macosx --show-sdk-path)" \
    $(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -name 'MacOSX[0-9]*.sdk' 2>/dev/null | sort -rV); do
    if swiftc -sdk "$candidate" -typecheck "$probe/probe.swift" 2>/dev/null; then
      rm -rf "$probe"
      echo "$candidate"
      return
    fi
  done
  rm -rf "$probe"
  echo "no SDK this swiftc can build against" >&2
  return 1
}
sdk=${SDK:-$(pick_sdk)}
flags=(-swift-version 6 -sdk "$sdk" -target arm64-apple-macos14.4 -O)
out=build/dev
mkdir -p "$out"
targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(app camera check)

app_sources=()
for f in App/*.swift; do
  [[ $f == App/main.swift ]] || app_sources+=("$f")
done

# The one Objective-C file: @try around calls into private frameworks, whose exceptions Swift can't catch.
objc=(-import-objc-header App/fastbg-Bridging-Header.h "$out/Catching.o")
nice clang -fobjc-arc -O2 -isysroot "$sdk" -target arm64-apple-macos14.4 -c App/Catching.m -o "$out/Catching.o"

for target in "${targets[@]}"; do
  case $target in
  app)
    app=$out/FastBG.app
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    nice swiftc "${flags[@]}" "${objc[@]}" Shared/*.swift App/*.swift -o "$app/Contents/MacOS/FastBG"
    [[ -f App/Info.plist ]] || xcodegen generate --quiet
    mkdir -p "$app/Contents/Resources"
    cp App/AppIcon.icns "$app/Contents/Resources/"
    cp -R Stock "$app/Contents/Resources/"
    # The $(...) are Xcode build settings, matched literally.
    # shellcheck disable=SC2016
    sed -e 's/$(DEVELOPMENT_LANGUAGE)/en/' -e 's/$(EXECUTABLE_NAME)/FastBG/' \
      -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/com.heathdutton.fastbg/' -e 's/$(PRODUCT_NAME)/FastBG/' \
      -e 's/$(MARKETING_VERSION)/0.0.0/' -e 's/$(CURRENT_PROJECT_VERSION)/1/' \
      -e 's/$(MACOSX_DEPLOYMENT_TARGET)/14.4/' App/Info.plist >"$app/Contents/Info.plist"
    # Only the camera entitlement: the extension-install and app-group ones need a team's provisioning profile.
    cat >"$out/dev.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.camera</key>
	<true/>
</dict>
</plist>
EOF
    codesign --force --sign - --options runtime --entitlements "$out/dev.entitlements" "$app"
    echo "built $app"
    ;;
  camera)
    nice swiftc "${flags[@]}" Shared/*.swift Extension/*.swift -o "$out/fastbg-camera"
    echo "built $out/fastbg-camera"
    ;;
  check)
    nice swiftc "${flags[@]}" "${objc[@]}" -parse-as-library Shared/*.swift "${app_sources[@]}" \
      Checks/Harness/*.swift -o "$out/fastbg-check"
    codesign --force --sign - "$out/fastbg-check"
    echo "built $out/fastbg-check"
    ;;
  *)
    echo "unknown target $target (app, camera, check)" >&2
    exit 1
    ;;
  esac
done
