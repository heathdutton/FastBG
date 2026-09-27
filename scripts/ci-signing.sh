#!/bin/bash
# Sets up signing on a CI runner for scripts/release.sh, and takes it down again: a throwaway keychain holding the
# team's identities and Apple's intermediates, the app's Developer ID provisioning profile, and the App Store Connect
# API key that xcodebuild and notarytool sign in with. Secrets arrive in the environment and only ever go to files,
# since argv is readable by every process.
#   scripts/ci-signing.sh setup     with FASTBG_P12_BASE64, FASTBG_P12_PASSWORD, FASTBG_PROFILE_BASE64 and
#                                   FASTBG_ASC_KEY_P8 set
# The key lands in $RUNNER_TEMP/signing/AuthKey.p8, for FASTBG_ASC_KEY.
#   scripts/ci-signing.sh cleanup
set -euo pipefail

cd "$(dirname "$0")/.."

dir=${RUNNER_TEMP:?run this on a CI runner}/signing
keychain=$dir/fastbg.keychain-db
profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

setup() {
  : "${FASTBG_P12_BASE64:?}" "${FASTBG_P12_PASSWORD:?}" "${FASTBG_PROFILE_BASE64:?}" "${FASTBG_ASC_KEY_P8:?}"
  mkdir -p "$dir" && chmod 700 "$dir"
  # No password, since one would have to go in argv to unlock it. The keychain lasts only as long as the job.
  security create-keychain -p "" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "" "$keychain"

  # The intermediates between Apple's root and the Developer ID and Apple Development certificates, pinned.
  local ca sum
  while read -r ca sum; do
    curl -fsSL --retry 3 -o "$dir/$ca.cer" "https://www.apple.com/certificateauthority/$ca.cer"
    echo "$sum  $dir/$ca.cer" | shasum -a 256 -c --quiet -
    security import "$dir/$ca.cer" -k "$keychain" >/dev/null
  done <<'EOF'
DeveloperIDG2CA f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a
AppleWWDRCAG3 dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f
EOF

  (umask 077 && printf '%s' "$FASTBG_P12_BASE64" | base64 --decode >"$dir/signing.p12")
  FASTBG_P12=$dir/signing.p12 swift -suppress-warnings scripts/import-identity.swift "$keychain"
  rm -f "$dir/signing.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$keychain" >/dev/null

  # xcodebuild looks for identities along the search list.
  local list=("$keychain") entry
  while read -r entry; do list+=("${entry//\"/}"); done < <(security list-keychains -d user)
  security list-keychains -d user -s "${list[@]}"

  # The API key can't fetch or make the Developer ID profile Xcode made on a Mac signed in to the team, so it comes
  # along, named by its UUID as Xcode files them.
  printf '%s' "$FASTBG_PROFILE_BASE64" | base64 --decode >"$dir/direct.provisionprofile"
  local uuid
  uuid=$(security cms -D -i "$dir/direct.provisionprofile" | plutil -extract UUID raw -)
  mkdir -p "$profiles"
  mv "$dir/direct.provisionprofile" "$profiles/$uuid.provisionprofile"
  echo "$profiles/$uuid.provisionprofile" >"$dir/installed-profile"

  (umask 077 && printf '%s\n' "$FASTBG_ASC_KEY_P8" >"$dir/AuthKey.p8")
}

cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  if [[ -f $dir/installed-profile ]]; then rm -f "$(cat "$dir/installed-profile")"; fi
  rm -rf "$dir"
}

case ${1:-} in
setup) setup ;;
cleanup) cleanup ;;
*)
  echo "usage: ci-signing.sh setup|cleanup" >&2
  exit 2
  ;;
esac
