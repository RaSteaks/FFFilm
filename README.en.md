<img src="design/icon/exports/iOS-Default.png" alt="FFFilm" width="96">

# FFFilm

**English** | [简体中文](README.md)

Data rate, storage runtime and shutter planning for the camera you actually have on set, plus negative preview on iPhone / iPad and film slicing on macOS. Native SwiftUI on iPhone, iPad and Mac, with no third-party dependencies.

## Features

**Recording** — camera, format and cadence in; rate and storage out.

- Data rate as GB/h or GiB/h, with the matching Mb/s bitrate.
- Storage plan: capacity for a planned duration, the card's actual capture runtime, and a warning when the plan exceeds the card.
- Direct duration entry (0.25–24 hours) with inline validation, a native stepper and 1/4/8/12-hour presets. An incomplete draft keeps the last valid result.
- Snapshot comparisons: pin up to four setups; duplicates are rejected.
- Per-camera format memory. Media and planned duration stay per-window.
- Playback duration, active image area and the calculation basis stay in a collapsed details disclosure.

**Shutter** — three modes sharing camera FPS and a user-set maximum angle.

- **Convert** — angle ⇄ exposure time, with the primary readout following the conversion direction.
- **Flicker reference** — flicker-free angles against mains (50/60 Hz), a custom optical rate, or 2–16 display refresh rates.
- **Over / undercrank** — match an exposure by keeping the angle or the time, with playback speed and an optional light check.

Preset frame rates carry their exact rational values; typed decimals stay literal.

**Camera catalog** — 39 profiles across ARRI, Sony, RED, DJI, Kinefinity and standalone Apple ProRes, with manufacturer-grouped search, reorderable favorites and per-camera recording-mode details.

**Settings** — decimal GB/TB or binary GiB/TiB, applied to rates and totals without changing bitrate or runtime. Simplified Chinese and English follow the system language, falling back to English; camera models, codec names and FPS stay in their source form.

## Negative preview (iPhone / iPad)

Open **Film Preview** and import from the photo library or Files (TIFF / JPEG / PNG / HEIC / HEIF, including large 8/16-bit RGB or grayscale images); other apps can also hand images straight to FFFilm through the system Open-in flow — cold launches included, and a failed import keeps the current source. Sample an unexposed film edge to view the positive, compare against the original, and zoom with on-demand sharpening bounded by the source size and the memory budget.

The camera offers a lens choice (an automatic multi-lens camera with macro takeover, or explicit ultra-wide / wide / telephoto) and 720p / 1080p / 4K capture, with tap-to-focus where the hardware allows it. Exposure and white balance lock for live positive preview; frozen exports use the video frame dimensions.

Export at source dimensions as TIFF / PNG (16-bit sRGB) or JPG (8-bit sRGB) through the share sheet, or save the positive JPG straight to Photos (add-only permission). Multi-page and floating-point TIFF are not supported. This is a preview tool without grading, cropping, presets or batch processing, and does not promise calibrated scan color. Processing stays on-device and never overwrites the input.

See the [implementation notes](docs/ios-negative-film-preview.md) for simulator evidence and outstanding real-device validation of large-file limits and camera behavior.

## Film slicing (macOS only)

Open **Film** in the Mac toolbar, or press **⌘3**. Import a TIFF or experimental Flextight FFF strip, detect frame gaps or draw frames manually, then crop, rotate, reorder and export. Automatic boundaries are candidates and should be checked. Save `.fffilm` projects to resume slicing without modifying the scan.

Export current, checked or all frames as 16-bit Adobe RGB TIFF or 8-bit sRGB JPEG. Whole-strip output places rotated crops in their original slots, clipping to the slot boundaries; individual exports retain full rotated bounds. Zoom, undo/redo and batch selection remain available.

**Color management** remains for accurate input/output interpretation: embedded input profiles take precedence; untagged scans require explicit assignment or a matching RGB ICC. Floating-point previews preserve extended RGB and exports embed their output profiles. No automatic negative conversion is applied. See [color-management notes](docs/film-color-management.md).

**FFF compatibility is experimental:** ImageIO full-resolution 16-bit RGB decoding works for the tested sample, but this does not establish every proprietary variant or calibrated scanner color. Camera RAW FFF and FlexColor processing history are not supported.

## Build, run and test

Requires Xcode 26.3 or later, and iOS/iPadOS 18.6+ or macOS 15.6+. Open `FFFilm.xcodeproj`, or use:

```sh
# macOS app
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=macOS' build

# iOS Simulator
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

```sh
# Unit tests — catalog integrity, rate tables, media planning, shutter math and the negative renderer
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=macOS' -only-testing:FFFilmTests test

# UI tests — run on a simulator; the flag avoids a clone-launch flake
xcodebuild -project FFFilm.xcodeproj -scheme FFFilm \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -only-testing:FFFilmUITests test
```

UI tests select elements by accessibility identifier rather than visible label, so they run against any system language.

```sh
# macOS app lifecycle
script/build_and_run.sh            # build and launch
script/build_and_run.sh --verify   # confirm the process is running
script/build_and_run.sh --debug    # launch under lldb
script/build_and_run.sh --logs     # stream the unified log
```
