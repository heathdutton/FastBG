#!/bin/bash
# Builds the stock backgrounds FastBG ships with, Stock/*.mp4, from public domain footage on Wikimedia Commons and
# the US Fish and Wildlife Service's video library. Stock/SOURCES.md credits each one. Needs ffmpeg with libx265
# and libvmaf (Homebrew's has both).
#   scripts/make-stock.sh            every clip
#   scripts/make-stock.sh aurora     just the ones named
#
# Each clip becomes a loop with no visible join, then HEVC Main 10 at 1920x1080, 30 fps or less, no audio: the
# format the importer stores video in, so these go into the library as they are. The quality is picked per clip:
# the highest CRF whose VMAF against the lossless loop is at least $VMAF_TARGET. 92 is past what shows behind a
# person once a call app has compressed the picture again.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Stock"
work="$root/build/stock"
src="$work/src"
mkdir -p "$out" "$src"
target="${VMAF_TARGET:-92}"
commons="https://upload.wikimedia.org/wikipedia/commons"
fws="https://fws.rev.vbrick.com/downloads/videos"
# Wikimedia's policy asks for a User-Agent that says who's asking.
ua="FastBG/1.0 (https://github.com/heathdutton/fastbg; make-stock.sh)"

# A byte range takes only the start of a long master, when its index comes first and the clip sits early on.
fetch() { # file url sha1 [byte range]
  local path="$src/$1"
  if [[ -f "$path" ]] && [[ "$(shasum -a 1 "$path" | cut -d' ' -f1)" == "$3" ]]; then return; fi
  curl -fsSL --retry 3 --retry-delay 20 -A "$ua" ${4:+-r "$4"} -o "$path.part" "$2"
  local got; got="$(shasum -a 1 "$path.part" | cut -d' ' -f1)"
  if [[ "$got" != "$3" ]]; then echo "sha1 mismatch for $1: $got" >&2; rm -f "$path.part"; exit 1; fi
  mv "$path.part" "$path"
}

# The last `fade` seconds cross-fade into the first, so the end runs straight into the start. Soft, slow scenes
# only: anything sharp would show twice for the length of the fade.
crossfade() { # start length fade [filters before the loop, whose timeline start and length are on]
  local s=$1 l=$2 f=$3 pre=${4:-null}
  echo "[0:v]$pre,trim=start=$s:duration=$(echo "$l + $f" | bc),setpts=PTS-STARTPTS,split[a][b];
[a]trim=start=$f:duration=$l,setpts=PTS-STARTPTS[main];
[b]trim=duration=$f,setpts=PTS-STARTPTS[head];
[main][head]xfade=transition=fade:duration=$f:offset=$(echo "$l - $f" | bc)"
}

build() { # name file graph
  local name=$1 master="$work/$1-master.mkv" graph=$3
  echo "== $name"
  nice ffmpeg -nostdin -loglevel error -y -i "$src/$2" -filter_complex "$graph,format=yuv420p10le[out]" -map "[out]" \
    -an -c:v ffv1 -level 3 "$master"
  local chosen="" crf score
  for crf in 34 32 30 28 26 24 22 20; do
    local try="$work/$name-crf$crf.mp4"
    nice ffmpeg -nostdin -loglevel error -y -i "$master" -an -c:v libx265 -preset slow -crf "$crf" \
      -pix_fmt yuv420p10le -profile:v main10 -tag:v hvc1 \
      -x265-params "aq-mode=3:keyint=240:min-keyint=24:log-level=error" \
      -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart "$try"
    # Paired by frame number: the master's timestamps are rounded to the millisecond and the mp4's aren't, so at 30
    # fps pairing by time matched most frames with a neighbour and scored moving clips in the 60s.
    score=$(nice ffmpeg -nostdin -i "$try" -i "$master" \
      -lavfi "[0:v]setpts=N/(30*TB)[d];[1:v]setpts=N/(30*TB)[r];[d][r]libvmaf=n_threads=4" -f null - 2>&1 \
      | sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p')
    printf "   crf %s: %s KB, VMAF %s\n" "$crf" "$(( $(stat -f %z "$try") / 1024 ))" "$score"
    chosen=$try
    if awk -v s="$score" -v t="$target" 'BEGIN { exit !(s >= t) }'; then break; fi
  done
  # A noisy source can level off under the target, and then the finest one tried is as good as it gets.
  cp "$chosen" "$out/$name.mp4"
}

want() { [[ ${#only[@]} -eq 0 ]] || [[ " ${only[*]} " == *" $1 "* ]]; }
only=("$@")

fetch aurora.webm "$commons/9/93/Aurora_Australis_as_seen_from_ISS_%28SVS31281_-_1080p25%29.webm" \
  9f5f9b9b406005002ea22036ed0544f0a4193796
fetch canyon.webm "$commons/e/ed/B-roll_Video_-_Time-lapse_of_Clouds_over_the_Canyon_-_November_20%2C_2025_%2855087231001%29.webm" \
  3d2f5e815e0e229e3dabec69c9a4e65b7038bff5
fetch lava.webm "$commons/2/27/HAVO_20230607_timeplapse_LAVA_LAKE_VIDEO_J_Wei_%2852958939258%29.webm" \
  5ab6b51c309234656bd69cda862a286c17508a25
# The whole master is 2.4 GB. Its first 780 MB run to 204 s, past the shot that's used.
fetch salmon.mov "$fws/515b2b3d-0f70-4acc-bbbc-265ead755caa/instances/5f3a213e-b3ff-45da-8e5b-cd686008f649" \
  6dea4a2d8f156bc8fba4f58e35d9f10e05917877 0-779999999
fetch earth.webm "$commons/5/5d/Spinning_Earth_with_clouds%2C_atmosphere%2C_and_night_lights_%28SVS5570%29.webm" \
  6d08ccd6db0ee0a904c02c6e87084e59b88acb71

# The brightest stretch of aurora. A timestamp sits in the top-left corner, down to row 62, so the top 72 rows go and
# an exact 16:9 of the rest is scaled back up. Anything off 16:9 comes out with non-square pixels.
want aurora && build aurora aurora.webm \
  "$(crossfade 9 14 1.5 "crop=1792:1008:64:72,scale=1920:1080:flags=lanczos,setsar=1")"
want canyon && build canyon canyon.webm "$(crossfade 4 14 2)"
# Dusk sensor noise, which nobody wants shimmering behind them, is smoothed out first, mostly over time.
want lava && build lava lava.webm "$(crossfade 6 14 2 "hqdn3d=1.5:1.5:6:6")"
# The school under sunbeams, one shot from 183 s to 197.5 s, filmed from the riverbed so only fish cross-fade.
# Drifting specks are smoothed out first, mostly over time. The housing darkens the corners and edge columns, so an
# exact 16:9 inside them is scaled back up once the loop is cut, which scales only its frames.
want salmon && build salmon salmon.mov \
  "$(crossfade 183.6 12 1.5 "hqdn3d=4:3:14:14"),crop=1872:1053:8:13,scale=1920:1080:flags=lanczos,setsar=1"
# One turn is the whole 100 s clip, sped up 4x. The globe moves to the right third, where a person in the middle of
# the frame leaves it showing, and the seam only cross-fades the clouds.
want earth && build earth earth.webm "$(crossfade 0 23.5 1.5 \
  "setpts=PTS/4,fps=30,scale=1920:1080:flags=lanczos,pad=2400:1080:480:0:black,crop=1920:1080:0:0")"
ls -la "$out"/*.mp4
