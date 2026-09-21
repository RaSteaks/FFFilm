# FFFilm

## Current app icon (2026-09-21)

- **Shipping integration:** user approved the grayscale time-slices PNG for Icon Composer and all project icons. `design/icon/format.icon` is the native single-raster source; `FFFilm/AppIcon.icon` is its synchronized build input. Xcode 26.3 compiles it under the existing AppIcon name. `script/update_icons.sh` refreshes the native copy, appearance previews and all 13 raster slots.
- Verification: final macOS and iOS Simulator builds pass; all 13 dimensions, opaque iOS channels, neutral tinted fallback, native macOS margins and source synchronization pass. Native Composer opening, saved material settings and small-size appearance were checked. Current app was not restarted: automatic review rejected the existing script's unconditional force-quit, so build-only verification was used.

- Visual direction: express data calculation indirectly through cinematic rhythm. Preserve the three angled slices, gaps and stagger, with dark-to-light neutral grays from left to right. Approved artwork: `design/icon/explorations/2026-09-21-time-slices-grayscale/time-slices-grayscale.png`.
- At the user's request, removed the old icon archive and four superseded exploration rounds. Retain only the approved grayscale artwork, its prompt, current native documents, normalized source and active exports. Cleanup verified that current icon asset contents were unchanged and all resource references remain valid.

## Project plan

- Repository hygiene: exclude local `.codex/` configuration, macOS metadata, Xcode user state and build products through `.gitignore`. Keep shared Xcode schemes, tests, project documentation and icon design sources/explorations versionable.

- Build a native SwiftUI format, data-rate and shutter calculator for iOS and macOS only.
- Keep camera metadata and published rate anchors in `FFFilm/Catalog.json`; decode them into immutable Swift catalog models.
- Keep selection normalization and all calculations in `CalculatorEngine` so UI and unit tests use the same implementation.
- Keep mutable workflow state in the `@Observable` `CalculatorStore`; views receive only the store or values they render.
- Preserve the compact monochrome workbench, video-only calculation boundary, Quick Start shortcuts and four-item comparison limit from the original Tauri application.
- Always expose estimated recording time from the selected media capacity and actual capture cadence; distinguish it from project playback duration.
- In RATE, expose `PROJECT FPS` only for standalone ProRes. Camera profiles expose only `SENSOR FPS`, which already drives data-rate, recording-time and daily-storage calculations. Keep the desktop timing row at three columns.
- Allow free-form positive decimal shutter inputs while keeping validation in `CalculatorEngine` so invalid values cannot produce non-finite results.
- Treat `DESIGN.md` as the durable UI contract; keep the live result above detailed controls on compact iPhone layouts and retain native 44-point interactions.
- Keep `design/icon/format.icon` as the canonical app-icon source, synchronized to `FFFilm/AppIcon.icon` by `script/update_icons.sh`. Use the compiled native macOS rendition for padded raster slots; use opaque square artwork for iOS fallbacks and neutral luminance for the tinted fallback.
- Use native Liquid Glass only on supported Apple OS versions and retain a material fallback for earlier macOS versions.

## Architecture

- `Models.swift`: catalog, settings and result value types.
- `CalculatorEngine.swift`: option compatibility, rate lookup, media planning, active-area geometry and shutter calculations.
- `CalculatorStore.swift`: user selections, dependent-state synchronization, camera favorites persistence and pinned setups.
- `ContentView.swift`: adaptive SwiftUI workbench and native controls.
- `Catalog.json`: ARRI, Sony, RED, DJI, Kinefinity and Apple ProRes source data.

## Verification

- Build the `FFFilm` scheme for macOS and an available iOS Simulator.
- Run `FFFilmTests` to verify catalog completeness and representative ARRIRAW, ProRes, DJI and shutter results.
- Run `FFFilmUITests` on an available simulator to verify launch and core controls.
- Manually test camera/mode/resolution/codec synchronization, ALEXA 35 Xtreme overdrive, Quick Start persistence, copy, reset and compare pins.

## Product boundary

All displayed rates are video-only planning estimates. Validate camera firmware, codec settings and recording media before production use.

## Kinefinity support (2026-09-21)

- Add MAVO Edge 8K, MAVO Edge 6K, MAVO mark2 LF/S35 and VISTA using official recording tables. Preserve all published ProRes rows, including oversampling and crop modes.
- Camera and resolution codec allowlists intersect with existing codec restrictions. MAVO native-gamut ProRes supports LT through 4444 XQ; VISTA supports LT/422/HQ only. Proxy and generic HEVC are excluded.
- Store published optical width/height in millimeters when available; this avoids treating an oversampled output as a sensor crop. Rows without published optical dimensions retain the existing pixel-proportional estimate.
- Include the published minimum and maximum sensor frame rates alongside standard rates without changing older camera profiles.
- Separate KineOS 8.0 RAW modes contain only explicitly documented DNG rows. Estimate packed 12-bit video payload; file headers, padding, audio and filesystem overhead are excluded. Native-gamut ProRes modes do not represent the separately limited BT.2020 modes.
- VISTA H.265 is deferred: the official page gives 400/200/80 Mbps at 4K 25fps but no complete resolution/frame-rate scaling rule. Do not substitute the generic HEVC estimate.
- Use the detailed VISTA recording table where overview/FAQ rounded frame rates disagree. Older TERRA/MAVO/KineRAW models are outside this catalog addition.
- Sources: [Edge 8K](https://kinefinity.com/zh/products/mavo-edge-8k/specs), [Edge 6K](https://kinefinity.com/zh/products/mavo-edge-6k/specs), [MAVO mark2](https://kinefinity.com/zh/products/mavo-mark2/specs), [VISTA](https://kinefinity.com/products/vista/specs), [KineOS 8.0](https://kinefinity.com/zh/support/guides/kineos-8-0-notes).
- Focused regression tests cover every added mode/codec, frame-rate limits, invalid-codec normalization, oversampled optical coverage, DNG payload rate and recording duration.
- `script/build_and_run.sh --verify` builds and launches the macOS app and checks its process.
- Verified: macOS and iOS Simulator builds; macOS app launch and manual Kinefinity selection/RAW switching; complete macOS unit-test target (including all three new Kinefinity regression tests).

## Shutter workbench (2026-09-21)

- MODE 选项使用中文描述：快门换算、频闪参考快门、升格 / 降格；沿用原有模式标识与计算逻辑。
- Three modes share camera fps and a user-set theoretical maximum angle: conversion, periodic-light candidates, and over/undercrank matching. Actual camera limits and angle increments are not cataloged.
- Use exposure seconds internally: `t = angle / (360 * cameraFps)`. Keep the reciprocal denominator explicitly named; never round inputs or computed values to displayed precision.
- Equal-exposure matching uses `t = baselineAngle / (360 * projectFps)`; constant-angle matching uses camera fps. Retimed playback speed is `projectFps / cameraFps`, duration is its reciprocal, assuming frame-by-frame interpretation without interpolation or blending.
- Periodic-light candidates use `t = n / opticalHz`, positive integer `n`. Mains 50/60 Hz assume optical 100/120 Hz; custom input is already optical Hz. Search only bounded neighbors of the target cycle count and return at most three candidates, with lower angle winning distance ties.
- Preserve theoretical angles above the user's maximum. Missing candidates do not prove flicker; model matches are not guarantees for LEDs, PWM, rolling shutters or fluctuating power. Optional matching checks never replace the exposure target.
- Validate active inputs in the engine and share field limits with the editor. Reject non-finite values, unsupported cadence, underflow/overflow and unrepresentable cycle counts rather than silently choosing defaults. Fractional presets explicitly opt into rational fps; typed decimals remain literal.
- Store draft strings in the editor, with pending and inline error states. RATE import is one-shot, preserves angles and light settings, and never changes RATE. RESET restores all shutter defaults and clears drafts. No shutter persistence or configuration-link migration is introduced.
- Verify formula round-trips, precise display, candidate ranking against a small exhaustive oracle, boundaries, impossible angles, optional checks, invalid inputs, import/reset, actual text editing and accessible mode switching.
- iPhone 17 Pro Max simulator: both existing launch/core-control and primary-action UI smoke tests passed with parallel testing disabled after a transient clone-launch Mach -308 failure.

## macOS component design (2026-09-21)

- Use the native unified window toolbar for calculator selection and Pin/Copy/Reset. Keep each window's CalculatorStore independent and route Calculator menu commands through focused scene values. ⌘1/⌘2 select workbenches; ⇧⌘P/C/R perform toolbar actions without taking standard text Copy.
- Keep desktop UI in `MacWorkbenchToolbar.swift` and shared platform-aware primitives in `WorkbenchComponents.swift`. The macOS recording form groups wide format controls separately from cadence/media controls; native bezels must not be nested inside custom capsule button backgrounds.
- Desktop fields are label/control pairs inside a single quiet panel, with 28pt compact controls and a 1120pt content maximum. Retain 44pt touch controls and the existing mobile result-first flow. Use native bordered numeric inputs on macOS and preserve the established monochrome visual identity.
- Verify native toolbar actions, keyboard routing, macOS build, iOS build/regression, full unit suite and actual desktop screenshots.

## Result selection and copying

- Enable native text selection at the RATE, SHUTTER and pinned-results container level, including numeric readouts, playback ratios, candidates and warnings. Do not limit selection to the exposure-time line. Keep standard ⌘C available for selected text; ⇧⌘C remains the separate configuration-copy action.

## Camera catalog and favorites

- `CameraLibraryView.swift` adds a searchable manufacturer-grouped catalog, a Favorites list and camera details in a native navigation sheet. The homepage's fixed CAMERAS action opens it; `QuickStartView.swift` is now selection-only.
- Preserve `fffilm.quick-start-camera-ids` and its order to migrate saved shortcuts without resetting user preferences. Keep existing default favorites and preserve intentionally empty lists. Favorites are no longer capped at five.
- Favorites support native List move/delete, context-menu and accessibility alternatives; details offer visible Move earlier/later controls and a shared favorite toggle. No membership or ordering operation changes the active calculator selection. PRORES remains fixed outside favorites.
- Native move destinations are based on original indices; validate offsets, retain moved-item order and persist only committed changes. Remove the old homepage edit state and custom drag payload implementation.
- Details only expose existing sensor and recording-mode metadata; do not invent additional camera capabilities.
- Verify catalog search and empty results, favorite toggle without navigation, detail membership/order, list drag/delete, homepage synchronization, empty favorites, migrated preferences and persistence beyond five cameras.
- Verification: macOS/iOS builds and the full 27-test unit target pass (31 executions including parameterized cases). The iPhone 17 Pro catalog/detail UI test and final iPhone 17e catalog/detail plus homepage smoke tests pass; manual simulator checks cover native list drag, removal, empty favorites, no-result search and clearing. macOS catalog/search/detail were manually verified; XCTest sheet hit-testing fails under UI automation on the available macOS 15.7.3 host, so do not claim that desktop UI test passed.

## Icon Composer assets (2026-09-21)

- `design/icon/format.icon` is the editable source. `design/icon/exports` retains native 1024px renders: iOS Default, Dark and TintedDark (tint strength 0), plus macOS Default.
- The current time-slices macOS master is loaded through AppKit from Xcode's compiled asset catalog, preserving native transparent margins and shadow. Do not add a second mask or padding. The UI export sheet was unavailable; the CLI's edge-to-edge macOS preview is not the legacy master.
- The iOS asset-catalog fallbacks use opaque, unmasked square artwork; native appearance previews are kept separately in `design/icon/exports`. `Contents.json` preserves filenames and mappings. The synchronized `FFFilm/AppIcon.icon` is now a native build resource and takes precedence in Xcode 26.3.

## Shutter exposure details

- Show exact fractional frame-rate labels only in the presets menu; do not repeat them as persistent helper text below fps fields. Preserve exact preset values and literal decimal input.
- Keep angle and reciprocal shutter speed in the main result and candidate rows. Keep all supporting information (decimal seconds/milliseconds, limit notes, playback ratios, light checks and candidates) in one native, initially collapsed DETAILS disclosure. Invalid/no-result messages remain visible. Preserve calculation precision and text selection.

## Storage planning rates

- Derive PLAYBACK from capture runtime multiplied by capture/project fps; never infer recorded-frame duration from a separate codec-rate lookup. Regression coverage includes nonlinear DJI H.264 rates in both retiming directions and standalone ProRes.
- Publish only for iOS and macOS. Application and test targets use `iphoneos iphonesimulator macosx`, device families `1,2` (iPhone/iPad), in both Debug and Release.

- RATE primary GB/h and Mb/s values and pinned comparisons use actual capture rates: SENSOR FPS for cameras, PROJECT FPS for standalone ProRes. Recording time and daily data totals use the same rate; PLAYBACK remains based on project cadence.

## Storage unit settings

- Native Settings scene and toolbar link on macOS; gear action and navigation sheet with Done on iOS. Settings copy is Chinese as requested; existing technical labels remain unchanged.
- `StorageUnit` owns decimal GB to binary GiB conversion; `SettingsView` owns the native preference picker. AppStorage persists and synchronizes the default (decimal) across windows. Reset does not erase this preference.
- RATE and pinned storage rates and daily totals follow the preference using GB/TB or GiB/TiB. Engine values and manufacturer media labels remain decimal; bitrate, recording time and utilization stay invariant.
- Explain common Apple/Windows conventions without claiming OS exclusivity; distinguish MB bytes from Mb bits.

- Storage settings keep differences, calculation impact and source links inside one initially collapsed native “详情” disclosure within the “容量换算” section, below the picker and persistence hint; the unit picker stays visible.
