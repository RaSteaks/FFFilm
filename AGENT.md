# FFFilm

## iPad live-camera memory investigation (2026-09-27)

- Report: iPad14,3 running the negative live camera was terminated for memory pressure during an approximately 20-minute Xcode debug session. The user confirmed the camera remained in original mode without film-base sampling or positive conversion.
- Read-only profiling of the running iPad app: a 45-second Activity Monitor trace measured 60.61–60.66 MiB physical footprint. A subsequent 180-second trace, after attaching Allocations, measured 92.99–93.06 MiB with no sustained growth. Different profiler attachment states are not a before/after code comparison.
- The 30-second Allocations trace recorded 578 Core Image VM allocations, of which 576 were transient and two remained (14.06 MiB). Its roughly 3.97 GiB cumulative allocation total is churn, not resident memory or evidence of a leak.
- Xcode showed its debug session had ended during this investigation. The device's available Jetsam report did not include FFFilm or match the reported termination time. These captures do not reproduce or resolve the original kill; do not claim a fix or long-duration acceptance. Next reproduce original-mode live preview under the original Xcode diagnostics and capture memory growth before changing the rendering path. View debugging was enabled in the supplied failure metadata, but no evidence yet establishes it as the cause.
- Local trace artifacts: `/tmp/FFFilm-live-footprint.trace`, `/tmp/FFFilm-live-allocations.trace`, `/tmp/FFFilm-live-long.trace`. No production code was changed for this investigation.

## Current app icon (2026-09-21)

- **Shipping integration:** user approved the grayscale time-slices PNG for Icon Composer and all project icons. `design/icon/format.icon` is the native single-raster source; `FFFilm/AppIcon.icon` is its synchronized build input. Xcode 26.3 compiles it under the existing AppIcon name. `script/update_icons.sh` refreshes the native copy, appearance previews and all 13 raster slots.
- Verification: final macOS and iOS Simulator builds pass; all 13 dimensions, opaque iOS channels, neutral tinted fallback, native macOS margins and source synchronization pass. Native Composer opening, saved material settings and small-size appearance were checked. Current app was not restarted: automatic review rejected the existing script's unconditional force-quit, so build-only verification was used.

- Visual direction: express data calculation indirectly through cinematic rhythm. Preserve the three angled slices, gaps and stagger, with dark-to-light neutral grays from left to right. Approved artwork: `design/icon/explorations/2026-09-21-time-slices-grayscale/time-slices-grayscale.png`.
- At the user's request, removed the old icon archive and four superseded exploration rounds. Retain only the approved grayscale artwork, its prompt, current native documents, normalized source and active exports. Cleanup verified that current icon asset contents were unchanged and all resource references remain valid.

## Project plan

- Settings display the selectable support address `zhuyutian041119@foxmail.com`, matching the support site, with Simplified Chinese and English instructions for copying it into a mail app. Issue feedback remains paused: its form, submission service, endpoint configuration and dedicated outgoing-network entitlement are removed; no GitHub issue is created from settings.
- Support-site copyright attribution names 朱煜天 as the rights holder; FFFilm remains the product name in all three page footers.
- App Info.plists use `NSHumanReadableCopyright = © 2026 朱煜天`: the macOS source plist declares it, and both Xcode build configurations inject the field into built apps on each platform.
- Publish the static `support/` directory as the GitHub Pages artifact through `.github/workflows/pages.yml`; its `index.html`, `support.html`, and `privacy.html` become the site root and the two App Store Connect URLs. Trigger deployment on support-site or workflow changes, with a manual dispatch option.
- Export compliance: declare `ITSAppUsesNonExemptEncryption = NO` for the iOS generated Info.plist and macOS source plist while the app and linked dependencies use no non-exempt encryption. Reassess if encryption-related capabilities or dependencies are added.
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

## Multiple display shutter calculation (2026-09-22)

- LIGHT SOURCE → 多显示设备 accepts 2–16 comma-separated fixed refresh rates, 0.001–1000000 Hz with up to three decimal places; decimal points are explicit, Chinese commas are accepted. Show commas in localized input examples so the sample matches the field separator. Preserve raw text across mode changes/import and reset with shutter defaults.
- Parse exact integer milli-Hz, then compute the GCD: the shortest common exposure is `1000 / gcd(milliHz)`. Reuse bounded candidate ranking and maximum-angle enforcement; never round nearby rates together or silently substitute a partial match.
- Support both flicker candidates and the optional matching check. DETAILS reports per-device refresh cycles; invalid lists clear results. When no exact common exposure fits, provide the qualified compromise described below.
- Fixed refresh is a theoretical model, not a guarantee for PWM, VRR, scanout or rolling shutters; environmental lighting is excluded from the display-only selection. Periodic-exposure background: https://www.red.com/learn/red-101/flicker-free-video-tutorial .

### Multi-display compromise optimization (2026-09-23)

- Exact common-cycle candidates retain priority and existing preferred-angle ordering. Only if no exact candidate fits, minimize `max_i |Hz_i * t - max(1, round(Hz_i * t))|` over positive exposures within the user angle limit. Positive integer targets prevent the zero-exposure degeneracy. All devices have equal priority; duplicate Hz values are equivalent. Ties (1e-12 cycles numerical tolerance) favor the preferred angle, then the lower angle.
- Split the exposure domain at half-cycle boundaries (starting at 1.5 cycles). In each interval the nearest positive integers are fixed; minimize the convex upper envelope by bisecting the increasing/decreasing envelope crossing, including endpoints. Up to 4096 boundaries are exhausted; beyond that, optimize cells from a bounded 4096-point sampling plus the preferred exposure and label the search approximate, never globally optimal.
- `ShutterCompromise` stays separate from exact candidates. Flicker mode displays its angle/time with a visible qualification; matching keeps the target, status and playback ratios, showing the compromise only as a reference in details. Details and clipboard expose per-Hz cycles, nearest positive integers and deviations. These are cycle errors, not measured brightness or flicker percentages.
- English and Simplified Chinese strings live in `Localizable.xcstrings`; `AppText` owns dynamic detail and clipboard formatting. Reuse the native result/details layout without introducing new UI tokens.
- Regression coverage includes analytical 50/60 Hz minimax, independent dense-search oracles, exact-solution priority, duplicates/order, decimal rates, short exposures, numerical underflow, bounded extreme-rate search, matching-target preservation and clipboard reference values.
- Verified: macOS complete unit target (49 passing test entries), subsequent focused ShutterTests including preferred-angle ties, and iPhone 17 Pro multiple-display UI regression (exact → compromise → invalid → exact, per-device details, reset). macOS and iOS Simulator builds and string-catalog JSON validation pass. The first Pro Max UI attempt failed before feature interaction because an old simulator app could not terminate; the final Pro run passed, with screenshots inspected.

## UI and interaction optimization (2026-09-22)

### iPad layout (2026-09-24)

- iPad RATE and SHUTTER use available content width: up to 1180pt, with a 55:45 parameter/result split from 900pt so native form controls do not overflow. Both columns scroll with the page. Narrow windows show results first, and the shared layout retains field drafts through rotation and window resizing. iPhone keeps its 900pt split threshold and 920pt cap; macOS remains unchanged.
- The iPad camera sheet uses a collapsible native list/detail split; selection, search and favorite actions remain in the same library state. Settings limits reading width to 680pt in wide iPad sheets. Keep the monochrome tokens, native controls and 44pt touch regions.

- Keep `CalculatorEngine` as the only compatibility/number-validation authority, `CalculatorStore` as the per-window workflow owner, and `WorkbenchComponents`/shared SwiftUI views as the presentation layer. `Localization.swift` owns non-view clipboard and feedback strings; `Localizable.xcstrings` contains English and Simplified Chinese, with other locales falling back to English.
- Recording uses the compact order workbench switch → favorites → result → parameters. At 900pt usable width the result and parameter groups use a 55:45 split; otherwise the page remains one vertical scroller. Results lead with GB/h or GiB/h and keep plan capacity, actual planned recording time and selected-card runtime visible; technical details stay collapsed.
- Duration editing keeps the last valid calculation while a 0.25–24 hour draft is empty, incomplete or invalid. Valid direct edits, the native stepper and 1/4/8/12-hour presets share one Store path. Camera format memory is versioned by camera ID in UserDefaults; media and planned duration remain window-local.
- Comparisons are immutable snapshots with four-item deduplication and a native sheet. The readable recording/shutter summary is separate from the legacy configuration-link string. Reset is scoped to the active calculator and supports one-step undo; the feedback banner is cleared by the next configuration edit or page switch.
- Code comments explain state ownership, compatibility persistence, draft preservation and UI behavior at the non-obvious boundaries. Do not add third-party dependencies or alter the existing catalog formula/link semantics.

### Verification status

- macOS destination: full `FFFilmTests` target passes — 41/41 tests, including the pre-existing ARRIRAW/ProRes/DJI/Kinefinity/shutter/QuickStart regression suites and the new `CalculatorStoreTests` (versioned camera-format memory, window-local media/hours, reset-undo scope, language-invariant readable summaries).
- iPhone 17 Pro simulator (iOS 26.2): every `FFFilmUITests` method passes — launch/core controls, primary actions, duration direct-input commit-on-submit with inline error, comparison sheet add/remove, MORE-menu reset with one-step undo, shutter decimal conversion, invalid-input recovery and reset, flicker/overcrank matching, multiple displays (no-common-period, invalid list, reset-to-defaults, DETAILS cycles), one-shot RATE import, camera catalog, and launch performance. One full-suite run hit a runner-level automation-session hang on the import test before any step executed (the known simulator infrastructure flake, Mach-308 precedent); that test passes standalone and all other cases passed in the same run.
- Fixes made during verification: `Localization.resolve` now uses the `String(localized:defaultValue:)` initializer so catalog format strings substitute `%@` arguments in zh-Hans; `Detail` dropped its unlabeled `String` initializer, because an unlabeled overload won resolution for string literals and rendered raw catalog keys on screen (the label on the initializer was the fix, never a verbatim code path); the recording-duration draft validates while typing and commits only through DONE/submit/focus loss; shutter conversion angle→time asserts the `shutter-time-primary` readout.
- iOS UI automation on this host: the simulator attaches the host hardware keyboard, so the software keyboard and long-press edit menu never appear and delete-key events are dropped for default-keyboard fields (verified against screen recordings). Field replacement therefore leads with a two-finger whole-paragraph selection plus typed replacement, with verified per-key deletes and the edit menu as fallbacks; `enterText` dismisses keyboard focus before revealing the next field, and reveal uses short center drags to avoid swipe momentum oscillation. The shutter DONE toolbar button now carries the stable `shutter-done` identifier; `twoFingerTap` is guarded with `#if os(iOS)` so the UI-test target still compiles for macOS.
- `python3 -m json.tool FFFilm/Localizable.xcstrings`: passed. macOS and iOS Simulator app/test targets compile from the same source. No release or deployment action is part of this change.

## Code review follow-up (2026-09-23)

- Restore the storage-unit symbol on the primary recording rate: the headline readout must read `GB/h` or `GiB/h`, never a unitless "per hour", so binary and decimal plans stay distinguishable. The compact summary, snapshot and pinned rows already used `\(unit.symbol)/h`; the headline now matches them.
- Keep the plan-versus-card comparison in the card-duration row, including utilization percentage. Per the later UI request, do not show a separate over-capacity warning.
- The header's MORE menu no longer registers ⇧⌘R; the macOS toolbar owns that shortcut, and one window must not hold two identical key equivalents. Its reset also carries `reset-action-header` on macOS so window-wide element queries stay unambiguous (`reset-action` remains the toolbar's and iOS's). The menu's duplicated reset branch collapsed to a single button.
- `Detail` keeps exactly one `LocalizedStringKey` initializer. The unlabeled `String` overload it once carried was removed rather than labelled: an unlabeled overload wins resolution for string literals and renders raw catalog keys, and nothing needed a verbatim path.
- `RateResults` binds `store.calculation` once per body and passes it to the technical-details disclosure, matching `CompactSummaryView`. Every `result.` read in the body previously re-ran the engine, which the added planning rows and accessibility label had roughly doubled.
- Each shutter frame-rate preset menu names its field in the accessibility label, because matching mode can show the camera and project menus at once, and a stable `shutter-presets-<field>` identifier replaces label-based test selection.
- Catalog: removed 8 stale entries whose English duplicated a live key (`feedback.*`, `copy.invalidShutterSummary`, `shutter.overLimit`), giving 196 keys; added a zh-Hans value for `%@ hours`, which had none. The later UI request removed the unused `result.overCapacity` key. Keys still used at runtime with no localization (`%@ fps`, `%@°`, `%lld/4`, `%@ Mb/s`, `180°`) are intentional: their text is language-neutral.
- Verification: macOS `FFFilmTests` 41/41 pass; the full iPhone 17 Pro UI suite passes every method in a single run. macOS UI automation remains unverified on this host (sheet hit-testing limitation above), so the macOS-only header/toolbar action duplication — pre-existing, not introduced here — still needs a manual look before deciding whether the header should render those actions at all.

## Code review fixes (2026-09-23)

- Route shutter field and picker edits through `CalculatorStore` so editing after reset clears the stale undo snapshot and feedback before new values can be overwritten.
- Reload camera-format memory on camera switches and merge each camera edit with the latest UserDefaults payload. Reset undo restores only the default camera record it changed, preserving later edits to other cameras in other windows.
- Label standalone ProRes comparison cadence as `PROJECT FPS`; include each camera name in the separate favorite button's VoiceOver label.
- Verification: the complete macOS `FFFilmTests` target passed with the new cross-window and shutter-undo regressions. Focused iPhone 17 Pro simulator UI tests passed for camera favorites and standalone ProRes comparison. `audit_project.py --mode strict` reported zero findings; `git diff --check` passed. Xcode used a temporary DerivedData path and disabled signing for local checks.

## Film workbench as a main-window tab (2026-09-23)

- The film editor no longer opens as an independent window. `CalculatorView` gains a macOS-only `film` case (`#if os(macOS)`), so the segmented workbench picker in the header and the macOS titlebar show FILM directly beside SHUTTER; iOS keeps exactly two segments and no film UI. `nav.film`/`mac.filmWorkbench` were added to `Localizable.xcstrings`.
- `ContentView` owns the `FilmStore` on macOS, so the film document, renderer and undo stacks survive workbench-tab switches; the editor fills the entire window content below the unified titlebar with no in-content header — the titlebar segmented control is the single navigation (an initial in-content header duplicated the titlebar picker and was removed), and the editor's own toolbar items (import/project/undo/redo) appear in the titlebar while the FILM tab is showing. `FilmWindowGuard` is attached at the ContentView root, keeping unsaved-film close/quit protection active even on other tabs. `resetActiveView` is a no-op on the FILM tab.
- The standalone `WindowGroup(id: "film-workbench")` was removed. ⌘3 now switches the focused main window to the FILM tab (Calculator menu); the Film menu keeps import/save/undo/redo acting through the focused scene's film store.
- Verification: macOS and iOS Simulator builds pass; the complete macOS `FFFilmTests` target passes (63 cases); catalog and string-catalog JSON validation pass. The previously running app instance was not restarted; live tab switching and the film editor inside the main window still need a manual look after rebuild, and window widths below the split view's ~810pt pane minimum clip the inspector edge on the FILM tab.

## macOS film workbench (2026-09-23)

- Film processing is isolated behind `#if os(macOS)` in FilmModels, FilmRenderer, FilmStore and FilmWorkbenchView. The existing calculator retains its state/navigation; toolbar Film and ⌘3 open an independent editor window. iOS has no film UI or image-processing implementation. File read/write and app-scoped bookmark entitlements are macOS-only.
- Input is TIFF and experimental Flextight 3F/FFF via ImageIO. Choose the largest exposed image and reject FFF decode below 16-bit RGB. This does not prove complete proprietary 3F support: actual FFF samples and reference pixel/profile checks are still required. Never claim a decoded preview establishes compatibility. Camera FFF RAW and FlexColor edit history are excluded.
- FilmRenderer owns a reusable background Core Image context, original source, reduced preview, base sampling, gap candidates, high-precision edits and original-resolution export. Crops are normalized top-left coordinates of the EXIF-oriented source. Preview results are revision-gated and superseded tasks cancelled.
- Base sampling and manual linear RGB values edit the same parameters; strip defaults permit frame overrides. Positive mode bypasses inversion and defaults to no base correction. Negative conversion is base normalization followed by inversion; B&W conversion removes saturation. This first implementation is not a calibrated scanner/film-stock color model.
- Per-frame tone and four-channel curves are independent of crop geometry. Curve presets store curves only, copy values into projects, support named local persistence and JSON exchange, and use a shared atomic library across windows. User preset changes cannot retroactively change project images.
- Versioned `.fffilm` JSON stores source security bookmark/path, frames, corrections, curves and export options; raw scans are not rewritten. Missing sources can be relinked. Project state has bounded snapshot undo/redo and grouped drag edits. File operations and save/discard prompts use non-blocking sheets. A forwarding window delegate and macOS-only application delegate protect close and quit.
- Export current/checked/all frames as 16-bit Adobe RGB TIFF or 8-bit sRGB JPEG. Whole-strip preview/export composites graded frames in their source crop slots, clipping rotated edges to those slots; individual frame export preserves the full rotated bounds. Export serially to temporary files and rename completed results, avoid name collisions, allow cancellation, report failures.
- Verification: synthetic 16-bit TIFF decoder/sample/crop/export integration, curve interpolation/validation, project/preset JSON, gap detection and undo tests; full macOS unit suite passed 53 tests (57 executions including parameterized cases), macOS and iOS Simulator builds passed, and strict UI audit/diff checks passed. Live checks passed for TIFF import, three-frame detection, manual RGB editing, curve-point editing and named preset save, `.fffilm` save/reopen with a source bookmark, and TIFF export. The exported file was confirmed as 1800×600, 16-bit Adobe RGB. Real FFF and large scanner-file performance remain unverified pending samples.

## Film review fixes (2026-09-23)

- Both build configurations bind the film entitlements and project-type Info.plist only for macOS, with user-selected file read/write access. iOS retains its existing build settings.
- Saving without a decoded source must return failure when the document is dirty, so a failed import cannot authorize close/quit without saving. A regression exercises failed loading and verifies that the existing project file and unsaved state remain intact.
- Failed-import cleanup keeps the editor busy until renderer cleanup and error reporting finish. Verification: complete macOS unit-test target passed including the new failed-import regression; macOS ad-hoc signed and iOS Simulator builds passed. The built macOS bundle contains the `.fffilm` type declaration and sandbox, user-selected read/write and app-scoped bookmark entitlements. Plist validation and `git diff --check` passed. Interactive save/export panels were not retested.

## Real FFF sample validation (2026-09-23)

- User-provided `007.fff` successfully decodes at 5167 × 16443, 16-bit RGB through the production renderer; the small thumbnail is not used. Preview, gap detection, base sampling, full-size TIFF/JPEG export and rotated crop export passed. The detailed private-sample report remains local and is excluded from version control.
- No standard embedded ICC profile was found; testing assumed Linear sRGB. Base-sampled output still needs tone adjustment and reference color validation. Do not generalize this one sample to all FFF variants or claim parity with FlexColor. No production code changed in this validation task.

## Local artifact hygiene (2026-09-23)

- Exclude generated `premium-audit.json`, the one-off private FFF validation report, Python caches and Xcode archives. Keep local reports on disk; untrack the previously committed audit output. Preserve versioned source, tests, configuration, shared project settings and intentional icon design assets.

## Film rotation button directions (2026-09-23)

- Counterclockwise adds 90 degrees and clockwise subtracts 90 degrees, matching Core Image's bottom-left coordinate system. Preserve renderer and saved-project angle semantics; only correct the button actions.

## Manual film-base correction (2026-09-23)

- Film-base correction is manual only: retain RGB sliders/numeric fields, enable/disable, strip defaults, per-frame overrides, neutral reset and undo/redo. Remove both canvas sampling entries and the store/renderer sampling APIs; automatic frame-gap detection remains independent.
- Preserve version-1 project values and rendering semantics so previously saved base corrections remain editable. Update the renderer integration test to supply explicit manual RGB and verify the known base normalizes to black. Remove obsolete sampling localization entries and update README/DESIGN.
- Verification: full macOS unit-test target (including manual-RGB renderer integration) and iOS Simulator build passed; strict UI audit, string-catalog JSON validation and `git diff --check` passed. Interactive desktop controls were not retested in this change.

## Film classification without image changes (2026-09-23)

- Film type is metadata only. Remove implicit inversion/desaturation and the picker's base-correction toggle; preview and export use only explicit manual adjustments. Neutral processing returns the decoded scan directly. Previously saved type values remain readable but no longer trigger automatic conversion.
- Renderer regression verifies all three types preserve original preview pixels and expected export RGB. Manual base normalization now correctly expects white rather than an automatically inverted black result.
- Skip neutral frame compositing in strip view to avoid fractional-preview resampling. Full macOS tests pass, including a large-strip pixel equality regression. Real `007.fff` revalidation confirms 5167 × 16443, 16-bit source and identical original/preview pixels for all three types. iOS Simulator build, strict UI audit and diff checks passed; no app restart or live file-panel test was performed.

## Curve-based cast correction (2026-09-23)

- Replace RGB division-based mask correction with the existing manual four-channel curve editor and presets. No separate mask controls or sampling remain. Corrections belong to the current frame; sync and preset application support checked frames.
- Keep legacy version-1 mask fields decodable/round-trippable but inert, including per-frame overrides. Classification stays metadata-only and neutral curves preserve original scan appearance. Renderer tests verify independent curves map a synthetic cast to neutral RGB despite non-neutral legacy mask values.
- Verification: full macOS unit tests passed, including curve-neutralization, neutral-import, project round-trip and preset/undo tests. iOS Simulator build, strict UI audit, localization JSON validation and diff checks passed. Desktop interactive curve dragging was not rerun; the app was not restarted.

## Encoded RGB curve inversion (2026-09-23)

- Curves operate on encoded sRGB channel levels: convert linear working RGB to sRGB before the curve LUT, then convert back to linear for compositing/export. Identity curves bypass the LUT. Film classification remains metadata only.
- Regression checks RGB/master inversion, three individual inverted channels, and blue-only inversion on gray and colored inputs, in both preview and Adobe RGB TIFF exported back to sRGB. This aligns the inversion math with an sRGB Photoshop document, not every Photoshop profile or spline implementation.
- Verification: full macOS unit-test target and iOS Simulator build pass; real 5167 × 16443 16-bit `007.fff` produces an inspected inverted crop preview without the previous washed-out linear inversion. Strict UI audit and diff checks pass. No Photoshop reference export was supplied, so full Photoshop parity is not claimed; original scan profiling and remaining color-cast grading are separate from this inversion fix.

## ICC-managed film workflow (2026-09-23)

- Follow `docs/film-color-management.md`: distinguish assigned/embedded input profiles, explicit document curve space and output encoding. Preserve embedded RGB ICCs; untagged imports require selecting the actual scan output space or loading RGB ICC bytes retained in the project. Never infer sRGB primaries from linear encoding or film type.
- Keep extended-linear sRGB as an internal 32-bit-float connection/processing space, not a fixed curve gamut. Match to/from the selected sRGB/Adobe RGB/Display P3 curve space using Core Image color matching. Skip identity curves. Preview as tagged extended-linear RGBAh; export converts once to the chosen output ICC.
- The native Color management disclosure reports source profile provenance and editing-space selection. User presets carry their curve domain; mismatches fail explicitly without changing the project, while generic built-in shapes use the active space. Old optional-field-free projects/presets retain sRGB curve semantics.
- Preserve manual curve grading and film-type-as-metadata behavior. ICC colorimetry is not a calibrated negative inversion or scanner/film-stock reconstruction; real 007.fff has no verified input profile, so no automatic accuracy claim or guessed film-stock model is introduced.
- Verification: full macOS unit tests and iOS Simulator build passed; regressions cover per-space inversion, embedded ICC precedence, persisted custom assignment, invalid ICC rejection, old project migration, preset domain mismatch and P3-green preview preservation. Strict UI audit, localization JSON validation and diff checks passed. The native profile-selection panel/display UI was not interactively retested; the application was not restarted. The shared rationale lives in `docs/` because `research/` is intentionally ignored for local reports.

## Curve histogram and movable endpoints (2026-09-23)

- Display a 256-bin pre-curve histogram behind the active frame's curve in its selected editing space, after crop/rotation/tone. RGB combines the channel counts. Use bounded preview sampling, ignore transparent corners, cache independent of curve points, and revision-gate store publication. Include a visibility toggle and identify the sampling/domain in the UI.
- Every control point, including both endpoints, moves in X and Y; retain strictly increasing X and clamp Y to 0–1. Outside the first/last X, hold endpoint output rather than extrapolate. The graph includes these flat extensions. Expand handle hit targets with edge padding; numeric entry remains available; at least two points must remain.
- Verification: full macOS unit tests and iOS Simulator build passed; regressions cover endpoint movement/order/constant extension/JSON and histogram bin counts, pre-curve stability, crop/tone/space changes. Strict UI audit, JSON and diff checks passed. The actual editor was rendered offscreen at 350pt using real FFF histogram data; histogram, inset endpoints and flat extensions were visually inspected. Live pointer dragging and the running application were not exercised/restarted.

## Curve alignment guides and histogram contrast (2026-09-23)

- The selected point projects yellow dashed horizontal and vertical guides across the entire plot, updated from its actual coordinates during drag and numeric editing. Guides ignore hit testing and accessibility traversal.
- Increase histogram fill from 22% to 46% white and add a 32% contour to separate the distribution from the grid while retaining the white curve and yellow selection hierarchy. Document these visual choices in DESIGN.md.
- Verification: macOS build, strict UI audit and diff checks passed. An offscreen snapshot using the actual editor code with a seeded selected-point state and real FFF histogram data was visually inspected. No renderer/model logic changed; no new tests were added. The running app was not restarted.

## Slicing/export-only scope (2026-09-23, supersedes grading plans above)

- Film workbench now exposes only import/project workflow, automatic/manual slicing, crop/rotation/reorder, preview/zoom, batch selection and export. Remove film type, original comparison, tone, cast correction, curves/histograms/guides, editing-space controls, presets and adjustment sync.
- Delete grading/filter/statistics/preset execution paths and their models. Version-1 project decoding ignores retired fields; saving emits only geometry, source/input ICC and export data. No old curve library is read or deleted. Preserve source ICC assignment and display/output conversion for faithful color handling.
- Replace obsolete grading tests with legacy-project geometry-only pixel/export regression, crop/rotation and grouped undo/batch-removal tests. Retain ICC, wide-gamut, gap detection, save/error and failed-import protections.
- Verification: full macOS unit-test target, iOS Simulator build, strict UI audit, localization JSON validation and diff checks passed. Real 007.fff decoded at 5167 × 16443 / 16-bit, produced three gap candidates and exported a 5167 × 6614 / 16-bit Adobe RGB TIFF. An offscreen snapshot of the actual simplified workbench was visually inspected. The existing app was not restarted; live file panels were not retested.

## Film first-preview performance (2026-09-23)

- Probe the largest image IFD's metadata before asking for an untagged scan's input ICC, then load the scan only once. The preview uses ImageIO subsampling of that same full-size IFD when it preserves RGB bit depth and expected dimensions; it never uses a separate embedded FFF thumbnail. Keep the original full-resolution image for export.
- Materialize one extended-linear, half-float preview and reuse it for the canvas, frame thumbnails, gap detection and later geometry edits. Initial project state is published only after preview rendering succeeds. `close()` releases the source and preview and clears CI caches.
- Read-only renderer benchmark comparisons with local graphics access: real 5167 × 16443 / 16-bit `007.fff` improved from 18.14 s / 2.26 GB maximum resident memory to 0.30 s / 0.56 GB; a 5167 × 16443 / 16-bit TIFF improved from 20.45 s / 2.24 GB to 0.30 s / 0.56 GB. These times cover renderer load and first preview, not file-panel interaction or user ICC selection. Real FFF preview was visually compared with the prior output and a 518 × 1645 / 16-bit full-source TIFF crop exported successfully. The full macOS unit target passed (59 test cases), including profile probing, cache reuse, restored rotation, color, export and close behavior. Other TIFF compression and FFF variants may fall back to full decode.

## Direct crop-border dragging (2026-09-23)

- In the strip canvas Select tool, start a drag within eight display points of any frame's left, right, top or bottom border to resize that side. Prefer the selected frame's border when frames overlap; dragging inside a frame still moves it, and Draw frame still creates a new crop.
- Keep the opposite border fixed, clamp to the source bounds and a valid minimum size, and group each drag into one undo entry. Preserve valid narrow crops from older projects.
- Cover four-side geometry, bounds, narrow crops and border hit testing in `FilmTests`.
- Verification: the focused `FilmTests` and the complete macOS `FFFilmTests` target passed (59 reported cases); the strict UI audit found zero issues, and whitespace/diff checks passed. Pointer dragging in a running window was not exercised.

## Full-width crop border and interaction feedback (2026-09-23)

- For a border touching the canvas boundary, extend its pointer hit band 24 display points inward; keep the eight-point band for other borders. This lets a full-width or full-height crop's edge be grabbed without relying on the clipped exterior half of the band.
- Show inset grips on the selected crop in Select mode. Highlight the hovered or actively dragged edge in yellow and use the matching macOS resize cursor. Hide grips in Draw frame mode; retain numeric crop fields for keyboard use.
- Full-extent hit and resize regressions passed in focused `FilmTests`; the complete macOS `FFFilmTests` target passed. Strict UI audit reported zero findings, and diff/Swift whitespace checks passed. Live pointer dragging was not exercised.

## Source scan identity (2026-09-23)

- In the macOS film workbench, show the loaded scan's filename and a path relative to the current user's Home directory above the preview. Derive both from the loaded project's `sourcePath`, including when reopening a project or relocating its source; keep long paths selectable with full accessibility text.

## Film review corrections (2026-09-23)

- Flatten rotated single-frame JPEG output onto white before encoding, while leaving TIFF alpha intact. Generate rotated frame-strip thumbnails from the cached preview at thumbnail size and refresh them after source or frame changes.
- Serialize file panels and unsaved-work sheets per film window. Disable document commands during presentation/export, and let an accepted Don't Save decision close once without repeating the prompt. Localize the missing-source export error.
- A fresh import is intentionally dirty because the source link, bookmark and default frame have not been saved as a project. Preserve the current aspect-ratio fallback: when the width-derived height exceeds available space, the height-derived width is smaller than the original width and valid. Preserve `CGColorSpace.name`'s nil fallback for unnamed custom ICC profiles.
- Verification: focused `FilmTests` and full macOS `FFFilmTests` passed, including new JPEG corner/rotation and sheet-gating regressions; `git diff --check` passed. Live sheet reentry and pointer interactions were not exercised.

## Merge repair (2026-09-24)

- Restore the film workbench source, tests, documentation, localization and macOS file configuration from the merged film-processing PR. The previous `main` merge commit recorded the local parent's tree and omitted those PR changes.
- Keep the later version, signing and Info.plist settings from `main`; resolve the Xcode project conflict with one macOS-specific file-access, entitlement and project-type setting per build configuration.
- Verification: project and configuration plists are valid; the complete macOS `FFFilmTests` target and iOS Simulator build pass, as do string-catalog JSON and staged diff checks. The macOS UI test runner exited before bootstrapping in both the full-scheme run and a focused retry with parallel testing disabled, so UI-test success is not claimed.

## Single macOS workbench navigation (2026-09-24)

- Keep the macOS recording and shutter workbenches below the native titlebar without the duplicate in-content header. The titlebar owns workbench selection, settings, pin, copy and reset; its copy action also handles shutter summaries and keeps the shutter invalid-result disabled state. iOS retains its content header.
- Verification: macOS and iOS Simulator builds passed, and the rebuilt macOS recording window showed exactly one workbench selector in the titlebar with no in-content header. The focused macOS UI test compiled but did not execute because the XCTest runner exited before bootstrapping on this host.

## iPad workbench review fixes (2026-09-24)

- Keep iPad RATE and SHUTTER side by side at 900pt of usable width, while preserving SHUTTER's earlier controls-first stack on regular-width iPhones and result-first stack on compact iPhones. Centralize the 900pt threshold, 920pt iPhone width cap and 16pt column gap in `Layout`; stacked panels use the 12pt section spacing token.
- In the iPad camera split view, clear an invalid camera selection and show the existing empty detail state. Filter and sort the catalog once per list update before grouping it by manufacturer; keep one accessibility identifier on either navigation-link variant.
- Verification: iOS Simulator app and test targets and the macOS app build passed. Focused UI tests passed on iPhone 17 Pro Max (landscape SHUTTER), iPad Pro 13-inch (workbench and split catalog), and iPhone 17 Pro (catalog search, favorites and details). `git diff --check` passed.

## iOS bottom navigation (2026-09-26)

- Replace the iOS header workbench picker and settings sheet with native `TabView` destinations: 计算 / 快门 / 设置 (Calculate / Shutter / Settings). Settings owns an independent `NavigationStack`; macOS retains its toolbar and Settings scene. This supersedes the earlier iOS two-segment/gear-sheet plan.
- Keep one `CalculatorStore` at the app content root. Each calculator tab renders a fixed workbench page and owns its scroll/keyboard state, so input drafts and calculation parameters survive tab switches. Dismiss field focus and clear temporary copy feedback when leaving a page.
- Use system tab-bar rendering, including Liquid Glass on supported systems. iPad receives compact size class only at the tab shell to keep it at the bottom; each tab restores the actual size class for its content. No new visual tokens or dependencies.
- Apple WWDC26 confirms iPhone retains bottom tab navigation in iOS 27 (https://developer.apple.com/videos/play/wwdc2026/278/). Local tooling is Xcode 26.3 with iOS 26.2 SDK / iOS 26.3 simulator runtime, so iOS 27 runtime appearance remains unverified.
- Present the camera-library sheet at the content root, outside the compact tab environment; `QuickStartView` receives its presentation binding. This preserves the native wide iPad list/detail sheet without custom widths. Compact header comparison actions use the symbol plus count, retaining a full accessible label.
- Verification: iOS Simulator and macOS builds pass; all 59 unit tests pass. Focused iPhone 17 Pro / 17e navigation, settings-unit synchronization, valid/invalid draft preservation, core actions and camera tests pass. iPhone 17 Pro Max landscape and iPad Pro 13-inch bottom navigation plus portrait/landscape workbench and camera split checks pass. Three page screenshots from iPhone 17e were visually inspected. Strict UI audit, localization JSON validation and `git diff --check` pass. DESIGN.md lint reports zero errors and 13 pre-existing token warnings. iOS 27 runtime appearance, VoiceOver and largest Dynamic Type were not exercised.

## iOS negative preview implementation (2026-09-27; not released)

- Design contract: `docs/ios-negative-film-preview.md`; suggested branch `codex/ios-negative-film-preview`. Release scope is iPhone and iPad/iPadOS in the existing iOS app, with both device families required for acceptance; no macOS feature addition or deployment-target increase.
- Add an independent iOS negative-preview workflow: camera or selected photo/file including large 8/16-bit TIFF, explicit film-base region sampling, locked capture configuration, managed-color inversion, comparison and TIFF/PNG/JPG export. No manual grading, presets, batch processing or additional editing tools.
- Preserve current macOS import/slicing/export behavior; historical grading/sampling entries above describe removed implementations, not available reusable features.
- Bind samples to source/capture configuration, reject invalid samples, require resampling after capture changes, and share the exact frozen frame through the same processing pipeline. First release is a viewing aid, not calibrated film reconstruction or full-resolution camera scanning.
- File export retains oriented source dimensions; camera export uses the frozen frame dimensions. Specify 16-bit sRGB TIFF/PNG and 8-bit sRGB JPG. Large-TIFF acceptance includes approximately 85MP 16-bit RGB input through all three exports on the lowest supported real device; no silent downsampling or unverified unlimited-size claim.
- Implemented `NegativePreviewView`, `NegativeStore`, `NegativeCamera`, and platform-neutral `NegativeRenderer`/`NegativeRaster`. Import via PhotosPicker file transfer or Files; preserve managed color and EXIF; sample the source region; invert encoded sRGB after linear base normalization. No additional editing tools.
- Large-file rendering crops before GPU upload, renders bounded stripes into preallocated disk backing, and serializes file jobs. One shared full-resolution CPU pixel buffer prevents repeated LZW/PackBits decoding; real devices check their remaining process memory budget before decoding/export; do not claim fixed memory or unlimited scan size. Sharing retains temporary output until the system finishes reading it.
- Camera work belongs to a serial queue with one pending main-actor frame delivery, lock completion gating, cancellation generations, background interruption handling and thermal fallback. The iOS-only permission string catalog is excluded on macOS. No microphone access or full photo-library permission.
- Verification is recorded in `docs/ios-negative-film-preview.md`. The user requested simulator verification first; real camera timing, real-film appearance and lowest-device memory/thermal limits remain release gates. No app-store submission or production publication was performed.

- Verified: iPhone Simulator full unit target plus negative UI and tab-state regression; iPad Simulator negative unit/state/UI checks; both simulators completed uncompressed and LZW 85MP 16-bit TIFF through all three full-size exports. Full macOS unit target and unsigned iOS device build pass. Strict UI audit/diff checks pass; DESIGN.md lint retains 13 pre-existing warnings. Real-device camera, thermal and memory acceptance remains outstanding at the user's request to prioritize simulator validation.

## Negative preview review follow-up

- Use typed workflow phases for camera-frame gating; localized busy keys are display values only. Ignore user cancellation when reporting import errors.
- PhotosPicker transfers ownership of its temporary copy directly to the renderer; failed/cancelled loads delete it and successful assets retain cleanup responsibility.
- Mirror image-centering insets on both axes and keep the Chinese README fully localized.
- White-balance locking uses the completion-handler API returning Void; no Boolean-return check applies.

## Negative camera failure recovery (2026-09-27)

- Track requested capture independently of `AVCaptureSession.isRunning`, so startup failures and system-stopped interruptions reach the workflow; explicit stop/configuration failure clears that state.
- Camera errors use the suspension path to freeze the last displayed source, cancel pending work, invalidate late callbacks and discard the old film base. Static resampling and export operate on that same frozen source.
- Inject the camera capture interface for hardware-independent workflow regression tests. Targeted iPhone Simulator negative tests passed, including startup failure and interrupted-frame sampling/PNG export. Real-device notification timing remains unverified; the optional large-TIFF test was not enabled for this fix.
- Verification: iOS Simulator build and 24 focused negative unit-test executions passed; the opt-in large TIFF stress test remained skipped. Cancel-import UI regression passed on an isolated iPhone 17 Pro simulator after shared-simulator interference. Zoom/rotation visual behavior and physical-camera behavior were not interactively verified in this follow-up.

## Film preview navigation naming (2026-09-28)

- Rename the shared iPhone/iPad tab, page title and empty-state heading to 胶片预览 / Film Preview through `negative.title`. Keep the existing localization key, workspace identity and behavior; update navigation test labels and user-facing documentation.
- Verified both locale values and shared title consumers; string-catalog JSON and `git diff --check` pass.

## Film-base target and session calibration (2026-09-28)

- Add a visible center dot/crosshair and an accessible Return to center button to film-base selection. Before calibration, tapping live camera pixels starts the existing exposure/white-balance lock workflow at the tapped source position; the sample button defaults to center.
- Preserve the selected point through locked-frame delivery, block sampling edits while rendering, and reuse the existing confirmed RGB base for subsequent positive frames. Calibration remains session-local; no frame history or persisted camera calibration is added.
- Keep bilingual hints and existing cancel/re-sample behavior. The original-mode memory termination investigation remains unresolved; this interaction change is not a memory fix.
- Verified: iPad Simulator focused negative unit/state suite passed (25 executions; opt-in large TIFF stress test skipped), iPad and iPhone sampling/comparison/three-format-export UI tests passed, center-target screenshots inspected, unsigned iOS device build passed, strict UI audit and diff checks passed. Physical-camera interaction and the earlier long-duration memory failure remain unverified for this change.
- Follow-up: reduced the sampling marker's center-dot diameter from 3pt to 1.5pt, crosshair arms from 8pt to 3pt and stroke from 2pt to 1pt. Source sampling bounds and touch controls are unchanged.

## Camera controls and focus (2026-09-28)

- Discover physical rear wide/ultra-wide/telephoto devices, default to wide, and expose only selected-input supported 720p/1080p/4K video presets. Keep default 720p and full preset-sized buffers; do not silently use preview proxies. Limit 4K processing to 15fps and ordinary delivery to 30fps (10fps when seriously hot).
- Default taps to focus, with an explicit Focus / Sample film base selector. Restore continuous autofocus at capture start and via an accessible action, support rotated source-coordinate taps, show a transient request marker and the device-reported minimum focus distance. Do not claim the marker proves focus convergence. Wait for focus as well as exposure/white balance before freezing a sample.
- Add capability-bounded exposure compensation (up to ±3EV), commit on slider release, and provide reset. Lens, format and exposure changes restart capture, clear the session calibration and require re-sampling. Pause/export/sampling disable controls. Reject previous-generation frame acknowledgements and buffers preceding the new capture start.
- NegativeCameraSettings owns immutable configuration/capability values and focus-coordinate mapping; NegativeCameraControls owns native controls. A simulator-only DEBUG capture fixture supports UI verification; it is excluded from device/release builds. This is not a verified fix for the earlier memory termination.
- Verified: focused negative rendering/state suite passed (27 executions, opt-in large TIFF stress test skipped); final camera-state suite rerun passed after guarding startup against stale configuration callbacks. Camera fixture UI flow passed on iPad and iPhone, including tap intent, calibration invalidation, lens/resolution switching, EV adjustment and autofocus recovery. iPhone file sampling/comparison/all-format export regression passed. Screenshots inspected; expanded settings reserve preview space so exposure/autofocus sit above the tab bar. Final unsigned iOS device build, bilingual string checks, strict UI audit and diff checks passed. Physical lens/AF/EV behavior and prior long-duration memory termination were not validated on hardware in this change.

## Sony α mirrorless support (2026-09-28)

- Add α1 II, α9 III, α7S III, α7 IV, α7R V and α7 V with internal XAVC capture only: XAVC S-I 4K, XAVC S 4K (8-bit 4:2:0 and 10-bit 4:2:2), XAVC HS 4K (4:2:0/4:2:2 10-bit), XAVC HS 8K (α1 II 4:2:2, α7R V 4:2:0), XAVC S-I HD and XAVC S HD. Camera-level codec allowlists exclude generic HEVC and Apple ProRes from α bodies; `supportedManufacturers: [SONY]` plus the published-table row requirement keep the new codecs off cinema cameras.
- Rate rows store MB/s (Mbps ÷ 8) at the published cadences only. Where Sony lists multiple quality settings inside one format, rows use the highest published setting per frame rate; lower options are not separately cataloged. HD long-GOP rows use the published XAVC S HD rates. 8K is XAVC HS only; α1 II publishes 520 Mb/s at 23.98/25/29.97p and α7R V 400 Mb/s at 24/25p.
- Resolution and camera maxima use exact published cadences (119.88/59.94/29.97/25), not marketing labels (120/60/30p); α7 IV and α7R V cap UHD at 59.94p. Stable full-frame mode IDs per body: mandatory format/cadence crops affect optical area but not published data rates. XAVC HS 4K rows exist only at Sony's published cadences (23.98/50/59.94/100/119.88p) where those models omit 25/29.97p HS.
- Media picker gains 128 GB and 256 GB SD-card options ahead of the existing capacities; existing media IDs and defaults are unchanged.
- Sources: official Sony product specification pages (sony.co.id regional official site, matching sony.com) for [α1 II](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-1-series/ilce-1m2/specifications), [α9 III](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-9-series/ilce-9m3/specifications), [α7S III](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-7-series/ilce-7sm3/specifications), [α7 IV](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-7-series/ilce-7m4/specifications), [α7R V](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-7-series/ilce-7rm5/specifications), [α7 V](https://www.sony.co.id/en/electronics/support/e-mount-body-ilce-7-series/ilce-7m5/specifications).
- `SonyMirrorlessTests` covers per-resolution codec counts and XAVC-only allowlists, exact published rate anchors (600/520/400/280/222/100 Mb/s and 270 GB/h on a 256 GB card), published frame-rate availability per body, and stale-codec normalization across resolution switches. `catalogMigration` pinned counts updated to 39 cameras / 23 codecs / 87 rate rows.
- Verified: complete macOS `FFFilmTests` target passes and the iOS Simulator build succeeds (separate DerivedData, signing disabled). macOS UI-test failures in the full-scheme run remain the pre-existing host automation limitation; not attributable to this change.


## Sony optical-area correction (2026-09-28)

- Keep existing camera/mode/resolution IDs and published rate rows. All six α bodies declare a base optical width equal to sensor width and a 16:9 height; encoded UHD/HD downsampling no longer implies sensor cropping.
- Optional `Resolution.sensorCrop` metadata applies at normalized SENSOR FPS, never PROJECT FPS. Mandatory crops: α7 IV UHD ≥50fps ≈1.5x; α7 V UHD ≥100fps ≈1.5x; α1 II UHD ≥100fps ≈1.1x; α7S III UHD ≥100fps uses the published 10% image crop; α7R V UHD ≥50fps and all 8K ≈1.2x. α9 III retains full width at the cataloged cadences. Existing profiles without metadata preserve their geometry.
- Dimensions derived from sensor width and manufacturer approximate crop factors are planning estimates, not measured optical dimensions. Profiles assume full-frame-compatible lenses and exclude optional APS-C selection, digital stabilization, breathing compensation, RAW output and S&Q. Mode labels/notes state the automatic-crop scope.
- Sources: Sony angle-of-view guides for [α1 II](https://helpguide.sony.net/ilc/2440/v1/en/contents/0404M_angle_of_view.html), [α9 III](https://helpguide.sony.net/ilc/2380/v1/en/contents/0404M_angle_of_view.html), [α7 IV](https://helpguide.sony.net/ilc/2110/v1/en/contents/TP1000655359.html), [α7R V](https://helpguide.sony.net/ilc/2230/v1/en/contents/TP0002925752.html), [α7 V](https://helpguide.sony.net/ilc/2540/v1/en/contents/0414_apsc_shooting.html), and [α7S III](https://helpguide.sony.net/ilc/2410/v1/en/contents/0404M_angle_of_view.html) with Sony's [10% crop specification](https://www.sony.co.uk/electronics/exwarranty).
- Regression coverage checks full-width UHD/HD, mandatory crop boundaries in PAL/NTSC, 8K differences, image-circle/S35 factors, playback independence and normalization of unsupported capture rates. Existing bitrate/media tests remain unchanged.
- Verification: complete macOS `FFFilmTests` target passed, including `SonyMirrorlessTests.opticalAreas`; opt-in large-TIFF stress test skipped. Final iOS Simulator build, catalog geometry validation and `git diff --check` passed. No physical-camera or UI interaction tests were needed for this calculation/data correction.


## Continuous autofocus and automatic macro (2026-09-28)

- User testing requests continuous focus and automatic close-focus macro. This supersedes the earlier physical-only default and autofocus-recovery action. Start and tap-to-focus both prefer continuous AF; tap changes the region only. Remove the separate action from protocol, store, UI and fixtures.
- Discover a dual-wide virtual camera (triple fallback) only with an autofocus-capable ultra-wide constituent. Default to that automatic option, set its wide-lens switch-over zoom, and enable automatic constituent switching. Preserve explicit physical lens choices and fallback to physical wide on unsupported devices. No invented distance estimator or claimed macro support on fixed-focus ultra-wide devices.
- Pin constituent switching only while locking/sampling. Resume automatic switching with live frames; continue autofocus throughout. Detect actual primary-constituent changes on the serial capture queue, discard transition buffers, reset AE/AWB and invalidate the sampled base. Generation guards restart a pending lock if its lens changes. A calibration generation repeated on every frame survives rejected deliveries and clears the store calibration and shows persistent re-sampling guidance; successful confirmation clears that guidance.
- Native caption reports automatic macro readiness/active ultra-wide, and existing menus select automatic/manual lenses. Reuse the current monochrome tokens and bilingual string catalog; update DESIGN.md and the negative-preview workflow.
- API basis: AVFoundation AVCaptureDevice.h documents automatic fallback selection based on focus/exposure limits and virtual-device switch-over zoom factors. [Apple switching behavior documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum). Physical near/far transitions and focus convergence require hardware acceptance; simulator fixtures only verify workflow and UI.
- Verification: final unsigned iOS device build and all 9 NegativeStoreTests passed, including a lens-change delivery rejected during locking. NegativeTests rendering suite passed (opt-in large TIFF skipped). Camera fixture UI flow passed on iPhone 17 Pro and iPad Pro 11-inch; iPhone settings screenshot inspected. Bilingual camera-string validation, strict UI audit and diff checks passed. No physical-device macro/AF run or long-duration memory acceptance is claimed.
