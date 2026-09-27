#!/bin/bash
# Downloads the free-licensed people photos that the Vision and green screen checks run on, and derives
# 1920x1080 frames from them. Fixtures stay out of git, and SOURCES.md next to them records each license.
# Safe to re-run: originals are kept and checked by sha1, and nothing is re-downloaded that already matches.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dir="$here/Fixtures"
src="$dir/src"
mkdir -p "$src"
commons="https://upload.wikimedia.org/wikipedia/commons"
# Wikimedia answers 403 to a missing or generic library User-Agent, so the script names itself.
ua="fastbg-fixtures/1.0 (fetch-fixtures.sh)"

fetch() { # name url sha1
  local out="$src/$1"
  if [[ -f "$out" ]] && [[ "$(shasum -a 1 "$out" | cut -d' ' -f1)" == "$3" ]]; then return; fi
  curl -fsSL --retry 3 -A "$ua" -o "$out.part" "$2"
  local got; got="$(shasum -a 1 "$out.part" | cut -d' ' -f1)"
  if [[ "$got" != "$3" ]]; then echo "sha1 mismatch for $1: $got" >&2; rm -f "$out.part"; exit 1; fi
  mv "$out.part" "$out"
}

# Frames are converted to sRGB (one original is Adobe RGB) so their pixel values look like a webcam's.
frame() { # name out cropH cropW offY offX: crop a 16:9 window from the original, then scale to 1920x1080
  local tmp="$dir/.crop-$2"
  sips -s format jpeg -c "$3" "$4" --cropOffset "$5" "$6" "$src/$1" --out "$tmp" >/dev/null
  sips -s format jpeg -s formatOptions 95 -z 1080 1920 -m "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
    "$tmp" --out "$dir/$2" >/dev/null
  rm -f "$tmp"
}

fetch home.jpg \
  "$commons/d/d5/Woman_engaged_in_a_phone_conversation_while_working_on_her_laptop_at_home.jpg" \
  e054229a9a21bad3c5309f0b3ab3b6d30c1fa509
fetch brick.jpg \
  "$commons/8/84/Woman_smiling_in_front_of_a_laptop_while_holding_glasses_in_one_hand_and_a_card_in_the_other_one.jpg" \
  73f98fd58cf85a7e95257a0686eb36f8f03020d0
fetch studio.jpg "$commons/5/52/Pow_Salud_Studio.jpg" 53877297005438b9a4ebe0ea1d808d3dd1cac4f0

fetch office.jpg \
  "$commons/7/72/%E3%82%AA%E3%82%AA%E3%82%B5%E3%82%AB%E3%83%B3%E3%82%B9%E3%83%9A%E3%83%BC%E3%82%B9%E3%81%AE%E9%9B%86%E4%B8%AD%E3%82%A8%E3%83%AA%E3%82%A2_%286837921264%29.jpg" \
  367c76da4a392cd4cfb4a83a8cedf2be28591f83
fetch desk.jpg "$commons/9/99/Desktop_after_work_%28Unsplash%29.jpg" f9d2ac6de4804391556b193c3efb27467d86a0d3

frame home.jpg portrait-home.jpg 2721 4838 150 416
frame brick.jpg portrait-brick.jpg 4140 7360 100 0
cp "$src/studio.jpg" "$dir/studio.jpg"
frame office.jpg room-office.jpg 2369 4212 439 0
frame desk.jpg room-desk.jpg 3052 5426 300 0

echo "fixtures in $dir"
