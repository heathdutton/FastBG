<img src=".github/icon.png" width="96" align="right" alt="FastBG">

# FastBG

[![CI](https://github.com/heathdutton/fastbg/actions/workflows/ci.yml/badge.svg)](https://github.com/heathdutton/fastbg/actions/workflows/ci.yml)
![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-000?logo=apple)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-arm64-000)

Video and live web backgrounds in any app.

FastBG takes macOS's own background effect past photos, to looping video and live web pages. Same matte, so your hair
and the mic in your hand stay put. Green screen optional.

It runs from the menu bar on minimal CPU and battery. With no app on the camera, it does nothing.

## Install

1. Download the `.dmg` from [Releases](https://github.com/heathdutton/FastBG/releases/latest), open it, and drag
   FastBG to Applications. Then open it from there.
2. Approve the camera extension once in System Settings > General > Login Items & Extensions.
3. Allow camera access when asked.
4. Pick "FastBG" as the camera in your video app, and turn off that app's own background effects.

Drop images, videos, `.html` files or URLs on the menu bar icon to add backgrounds. Click a thumbnail to switch.

It ships with five public-domain backgrounds from NASA, the Park Service and Fish and Wildlife.
[Stock/SOURCES.md](Stock/SOURCES.md) credits each.

Uninstall by dragging the app to the Trash, then delete `~/Library/Application Support/fastbg`.

## Build

Needs Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and a paid Apple Developer team, since the camera is a
system extension.

1. Put the team ID in `Signing.xcconfig`.
2. `xcodegen generate`, then build the `fastbg` scheme.
3. Copy the app to `/Applications` and run that copy. A system extension only activates from there.

macOS only replaces an installed extension whose version changed, so bump `CURRENT_PROJECT_VERSION` on every build
that touches `Extension/`.

`scripts/release.sh` archives, notarizes and zips a release.

### Without Xcode

`scripts/dev-build.sh` builds with the Command Line Tools alone: an ad-hoc app (its extension can't activate unsigned)
and `fastbg-check`, a harness that runs the real pipeline on test photos.

```
Checks/fetch-fixtures.sh
scripts/dev-build.sh check
build/dev/fastbg-check all
build/dev/fastbg-check preview ~/Pictures/beach.jpg   # your camera through the pipeline, in a window
```
