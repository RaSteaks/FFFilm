---
version: 1
name: "FFFilm Workbench"
description: "A compact monochrome field calculator that keeps live production estimates within immediate reach."
colors:
  primary: "#F2F2F2"
  background: "#111111"
  surface: "#191919"
  surfaceRaised: "#222222"
  text: "#F2F2F2"
  muted: "#A6A6A6"
  mutedDeep: "#767676"
  line: "rgba(255,255,255,0.14)"
typography:
  interface:
    fontFamily: "SF Pro"
  data:
    fontFamily: "SF Mono"
rounded:
  field: "10px"
  panel: "18px"
  capsule: "999px"
spacing:
  unit: "4pt"
  phone-gutter: "12pt"
  regular-gutter: "16pt"
  section-gap: "12pt"
  page-max: "920pt iPhone / 1180pt iPad"
components:
  button:
    minHeight: "44pt touch / 28pt macOS"
    emphasis: "native bordered or quiet capsule"
  field:
    surface: "group-owned opaque surface"
    label: "system font; values use SF Mono"
  resultPanel:
    primaryMetric: "Required storage or available recording time, selected by task"
    disclosure: "recording has no technical disclosure; shutter details stay collapsed by default"
  presetChip:
    touchHeight: "44pt"
    desktopHeight: "28pt"
---

# FFFilm Workbench Design System

## Overview

### Creative North Star

The interface should feel like a calibrated camera-side instrument: dark anodized surfaces, restrained white markings, compact controls and a live meter that responds immediately to capture-setting changes.

### Product context and register

- **Audience and primary job:** cinematographers, DITs and camera assistants estimating recording rates, media runtime and shutter relationships.
- **Target market and evidence:** global film-production users; the migrated catalog and English technical nomenclature are the current product evidence.
- **Locale and language policy:** Settings offers exactly 简体中文 and English, shown in their native names. The initial selection follows supported system preferences with English fallback; an explicit choice takes effect immediately across scenes and persists across launches. AppLanguagePreference owns language, AppText owns eager string lookup, and FFFilmApp injects the SwiftUI locale without resetting view identity. Camera models, codec names, FPS and other production terms remain source text; numeric formatting follows the active system locale.
- **Usage scene:** frequent, time-sensitive use on iPhone beside a camera, with iPad and macOS as wider workbench surfaces.
- **Register:** professional production tool.
- **Memorable signature:** the selected calculation result appears before detailed controls on compact phones, behaving like the readout of a field meter.
- **Restraint:** native pickers, toggles and steppers remain familiar; decorative color, shadows and non-functional motion are avoided.
- **Anti-references:** consumer finance dashboards, colorful camera-control panels and oversized card stacks that hide the live result below the fold.
- **Token ownership/runtime mapping:** this file documents the durable intent; `Palette`, shared field surfaces and button styles in `FFFilm/ContentView.swift` are the canonical runtime mapping.

## Colors

The product is intentionally monochrome. `background` provides the chassis, `surface` and `surfaceRaised` establish depth, `text` carries primary values, and the two muted tokens establish metadata hierarchy. Selection must use contrast and shape as well as color. The app currently ships dark-only; new themes must define equivalent semantic tokens before adoption.

## Typography

SF Pro is used for native controls and action labels. SF Mono is reserved for measurements, camera settings, compact labels and result readouts. Numeric output uses monospaced figures to avoid jitter. Primary controls use Dynamic Type-aware body sizing on compact iOS layouts; metadata remains subordinate but legible.

## Layout

Spacing follows a 4pt rhythm. Compact iPhone layouts use 12pt gutters, put the live result above the settings list and render each setting as a horizontal row with a minimum 44pt control region. At 900pt of usable content width, the page changes to a 55:45 parameter/result split; below that threshold the result-first single-column flow remains. Capture format and storage plan groups stay expanded, with capture format first and storage plan second. Recording results contain no Technical details disclosure. Content respects safe areas and the page remains a single vertical scroller.

On iPad, use the available window width rather than size class alone: the workbench spans up to 1180pt and changes to the same 55:45 parameter/result split at 900pt, where the form panel has room for native pickers. RATE and SHUTTER use one page scroller with both columns moving together; narrower iPad windows put the result first. Field columns follow their actual panel width, and resizing must preserve draft input. The camera library uses a collapsible list/detail split on iPad, while settings text stays within a 680pt reading width. The camera-library sheet is presented by the content root outside the bottom-tab size-class override, preserving the system's wide iPad split presentation. iPhone and macOS retain their existing layout rules.

## Elevation & Depth

Hierarchy comes from tonal surfaces, one-pixel translucent strokes and native material/glass where already supported. Drop shadows are avoided. Glass is limited to major panels; dense form rows use stable opaque surfaces for readability.

## Shapes

Major result/header panels use 16–18pt continuous corners. Form fields use 10pt continuous corners. Presets and compact actions use capsules or circles. Borders remain thin and quiet.

## Components

### Foundational visual states

Enabled controls provide an immediate opacity/scale pressed state without moving layout. Selected chips invert foreground and surface. Disabled actions retain native disabled semantics and visibly reduce emphasis. Success feedback combines a symbol change with restrained haptics; color is never the sole signal.

### Buttons and actions

Phone header actions are 44pt icon buttons with accessible names. Wider layouts include text labels. The comparison action exposes an `n/4` count, COPY changes to a checkmark briefly, and RESET lives in MORE with a one-step undo banner. Repeated feedback must remain interruptible.

### Navigation and data display

iOS uses three persistent native bottom tabs in this order: Calculate (计算), Shutter (快门), and Settings (设置). `ContentView` owns tab selection and the shared calculator store; each calculator tab has a fixed page identity to retain scroll position and drafts. Settings owns an independent `NavigationStack` and title bar. The header contains page actions only. Native `TabView` supplies system Liquid Glass on supported releases and the standard tab bar on earlier releases; no custom glass overlay or extra bottom inset is added. On iPad, only the tab shell receives compact size class to keep navigation at the bottom; each page restores its actual size class for wide layouts and camera-library navigation. macOS keeps its existing toolbar navigation. Quick Start is a horizontally scrolling preset strip with clear selected and pressed states. Live results use the strongest type hierarchy and numeric content transitions.

### Forms and overlays

Native menu pickers are intentional because platform-owned selection behavior is appropriate for catalog choices. Shutter variables use typed numeric fields because frame rates and angles must accept production-specific decimal values outside the catalog presets. Compact fields use visible left labels and right-aligned controls. No nested vertical scrolling, custom select popovers or modal confirmation is required for routine reversible changes.

### macOS desktop components

The macOS window uses a unified native toolbar: a label-free Recording/Shutter segmented control, comparison, readable Copy and MORE actions. Reset and copy-link live in MORE. Do not add capsule fills or strokes inside native toolbar buttons. The Calculator menu routes ⌘1/⌘2 to the focused window; ⇧⌘P/C/R remain available, leaving ⌘C to native text editing. Tooltips explain actions and shortcuts. Copy feedback changes the icon and accessible label.

Desktop content uses a 1120pt maximum width, 24pt gutters and 18pt section spacing. The default window is 1040×760pt, minimum 760×560pt; smaller heights scroll naturally. The top content heading names the active calculator. Recording controls live in one 12pt-radius panel: two wide columns for camera/mode/resolution/codec, then a divided equal-width row for cadence/media/time (three columns in both camera and standalone ProRes modes). Fields have 6pt label spacing and native controls instead of independent outlined cards. Shutter controls reuse this grouped-panel treatment and bordered numeric fields.

Desktop presets use a 28pt height and 7pt corner radius. Native controls keep platform focus rings, keyboard navigation and disabled states. Panel fills use the established surface token, with a quieter 60%-strength line token; the native toolbar owns material effects. These are explicit desktop variants, not changes to iPhone/iPad touch density or the existing monochrome palette. Runtime ownership is `WorkbenchComponents.swift` (Layout, Palette, FieldCard and surface modifiers) and `MacWorkbenchToolbar.swift` (toolbar and scene-focused commands).

### Shutter workbench behavior

SHUTTER owns three native menu destinations: Convert, Flicker candidates and Over / undercrank. Conversion direction and matching goal are explicit secondary pickers. Keep exposure time is the default matching goal; a fixed 180° angle is a shortcut, never a safety claim.

The result emphasis follows the operation: angle → time makes shutter time primary, time → angle makes angle primary, and flicker/matching make the recommended angle primary while keeping time visible. One collapsed-by-default DETAILS disclosure contains decimal seconds, milliseconds, limit/support notes, playback ratios, light checks and all candidate information. Invalid/no-result messages remain visible. Preserve up to six decimal places without trailing zeros and never round stored calculation inputs. Fractional fps presets name their exact rational value; typed decimals remain literal.

Exact fractional frame-rate labels appear only in the presets menu, without persistent helper text below fps fields.
The Camera FPS menu includes `33.333 (100/3)` for 50 Hz lighting/overcrank planning; selection stores `100.0 / 3` without decimal truncation. This capture-only preset does not appear in the Project FPS menu; both fields continue to accept literal decimal input.

The shared FieldCard owns field presentation, native TextField/Menu/Picker/Toggle own platform interaction, CalculatorStore owns settings and one-shot RATE import, and CalculatorEngine owns validation and results. Shutter fields keep editing drafts, show pending results for unfinished input and show a specific inline error after submit or blur. Invalid drafts must not leave a seemingly current computed result onscreen. RESET clears all shutter settings and draft state.

Camera fps and maximum angle are shared across the three modes; other input values survive mode changes. USE RATE FPS copies both frame rates without linking the two pages or replacing angle/light choices. The default maximum is a user-set 360° theoretical limit, not a verified camera capability. Over-limit theoretical results remain visible with a symbol and explanatory text; they are never silently clamped.

Place the one-shot recording-rate import inside the Camera FPS field alongside its preset menu. Use the existing arrow.down.doc symbol and WorkbenchPressStyle, a 44pt touch target (platform control height on macOS), full localized accessibility label/hint and desktop tooltip. Keep its confirmation directly beneath the field; state both imported frame rates because project FPS is also copied. Do not allocate a separate full-width action row.

### Release copy

Use concise, sentence-case action and field labels in English and Simplified Chinese. Avoid duplicate field explanations, repeated settings headings and persistence instructions. Recording-task guidance remains in accessibility hints; storage-unit explanations stay in the details disclosure. Show the short video-estimate footer only on Recording; Shutter owns its camera-limit and flicker-model caveats in details, with compromise qualifications always visible. Preserve units, validation, permissions, unsupported-format recovery and meaningful compatibility limits. Scanner errors recommend a supported 16-bit RGB TIFF workflow rather than requesting samples for future development. Keep catalog/source dates in maintained reference documentation rather than unrelated screen footers.

Flicker candidates show at most three nearest complete optical-cycle exposures. A 50/60 Hz mains choice explicitly assumes 100/120 Hz light pulses. Optional light checking in matching is off by default and only adds reference candidates; it never changes the target. Empty candidates, non-integer target cycles and unverified real-world lighting have distinct text. Never label a result as guaranteed flicker-free.

Maintain one page scroller, compact result-first layout, native 44pt controls, keyboard focus and Dynamic Type. Center the focused input after keyboard insets settle and reserve the result panel’s height during editing so temporary invalid drafts cannot collapse the scroller or dismiss the keyboard. Use explicit accessibility containers so parent test identifiers do not replace descendant control identifiers. Error and result states combine text with symbols and do not rely on color. No new visual tokens are introduced.

### Iconography

Use SF Symbols with a consistent outline hierarchy. Filled variants indicate committed state, not decoration. Icon-only controls always keep accessible labels and 44pt targets.

### Motion

Motion communicates selection, numeric changes and action completion. Press feedback is under 150ms; content transitions use short native springs. Reduced Motion removes transform animation while retaining state changes and haptics where the system permits them.

### Content and data visualization

All result panels and pinned comparison rows support native text selection and copying, including numeric values, units, candidates and explanatory messages. On macOS, select text and use ⌘C or the native context menu; this is distinct from the configuration-copy toolbar action (⇧⌘C).

Labels are short production terms in uppercase. Results preserve units beside values, show estimated recording time against the selected media capacity, keep the recording result focused on the selected question, and retain the estimate disclaimer in copied summaries. Avoid marketing copy and decorative metrics.

RATE exposes PROJECT FPS only for standalone ProRes. Camera profiles expose SENSOR FPS only, including when the selected camera codec is ProRes; the condition follows the source profile, not the codec.

## Do's and Don'ts

- **Do:** keep the current calculation visible while users tune settings on a phone.
- **Do:** preserve native controls, accessible labels and 44pt touch targets.
- **Don't:** stack oversized cards that push the result beneath the first screenful.
- **Don't:** introduce semantic hue or decorative animation into the monochrome field-tool language.

### Camera catalog and favorites

RATE keeps a horizontal favorites strip with PRORES fixed first. A permanently visible CAMERAS button opens a native navigation sheet, separate from calculator inputs. No editing, remove icons or drag handles appear on the homepage. Empty favorites offer a short invitation to add them in CAMERAS.

The Cameras page uses a searchable, manufacturer-grouped native List. Each camera row links to its details and has a separate, explicitly labeled star button; toggling the star never navigates or changes the calculation. Native search supplies clearing and no-results feedback. Favorites are available from the top of the catalog, including while searching. The same native star action owns membership in both catalog and details.

The Favorites page lists complete camera rows in saved order. iOS Edit exposes native row deletion and drag reordering, keeping each control tied to a clearly bounded row. Context menus, VoiceOver actions and visible Move earlier/later buttons in camera details provide non-drag alternatives. Boundary moves are disabled. Details also show favorite position and allow removal or re-adding. Removal only changes membership; the camera remains in the catalog and the current RATE selection is preserved. Changes persist immediately; closing the sheet does not discard them.

Keep the existing stored shortcut order as favorites, including an intentionally empty list. Remove the former five-camera cap; the homepage scrolls as needed. PRORES is a calculation source, not a camera to favorite. Detail sensor dimensions and supported recording modes come directly from Catalog.json, with a firmware/codec qualification. Never imply that catalog metadata is an exhaustive camera specification.

Runtime ownership: CameraLibraryView.swift owns the native catalog/favorites/detail flow, QuickStartView.swift owns homepage navigation and selection, and CalculatorStore owns membership, ordering and persistence. Reuse Layout.controlHeight (44pt touch / 28pt desktop), Palette and native Dynamic Type typography; retain the monochrome identity. No new visual tokens or network requests.

## Storage unit settings

- Native Settings scene and toolbar link on macOS; a dedicated bottom tab with its own navigation bar on iOS. Tab labels and settings follow the established Simplified Chinese/English app-language preference. Switching tabs dismisses keyboard focus, retains editor drafts and resets transient copy feedback.
- `StorageUnit` owns decimal GB to binary GiB conversion; `SettingsView` owns the native preference picker. AppStorage persists and synchronizes the default (decimal) across windows. Reset does not erase this preference.
- RATE and pinned storage rates and daily totals follow the preference using GB/TB or GiB/TiB. Engine values and manufacturer media labels remain decimal; bitrate, recording time and utilization stay invariant.
- Explain common Apple/Windows conventions without claiming OS exclusivity; distinguish MB bytes from Mb bits.

- Storage settings keep differences, calculation impact and source links inside one initially collapsed native “详情” disclosure within the “容量换算” section, below the picker and persistence hint; the unit picker stays visible.

## Recording plan, memory and comparison

Recording uses a native segmented task picker: Storage needed / Recording time. Storage needed shows only the duration editor and makes required storage primary; Recording time shows only the media picker and makes available capture time primary. Both share camera format and retain independent inputs when switching. Task inputs precede format controls. GB/h or GiB/h and bitrate remain secondary. The compact scrolling summary and clipboard follow the selected task; full comparison snapshots retain both estimates. CalculatorStore owns the window-local task; ContentView reuses native Picker, FieldCard, ParameterGroup and existing Palette/Layout tokens without new colors or fonts. Playback duration, active image area and the calculation boundary remain in a collapsed Technical details disclosure. A direct duration editor accepts 0.25–24 hours, retains the last valid result while a draft is incomplete, shows inline validation and offers 1/4/8/12-hour presets alongside the native stepper.

Camera format choices are remembered per camera ID in a versioned UserDefaults payload. Media and planned duration are window-local. Invalid, corrupt, future-version or catalog-missing records are ignored; each window keeps its own active state while the latest valid camera edit wins for the next switch. Compatibility normalization owns its own non-blocking adjustment banner.

The result action stores independent comparison snapshots, deduplicates identical settings and caps the list at four. The comparison sheet shows complete format, cadence, rate, plan and card runtime values, and supports removal. Human-readable copy is separate from the unchanged configuration-link format.

### Multiple display shutter input

The existing LIGHT SOURCE picker owns 多显示设备. A shared FieldCard and native text field accept a comma-separated Hz list with explicit decimal-point instructions. Reuse light-field keyboard focus, scroll centering and result-height retention. Preserve raw list edits across modes/import; reset restores 60, 120. Invalid lists clear the result. When no exact common exposure fits, show a compromise angle/time with an always-visible qualification. DETAILS reports worst and per-device cycle deviation, the optimization rule and an approximation note when the bounded search applies. Matching mode preserves its primary target and puts the compromise in DETAILS only. Clipboard output carries the same qualification and reference angle. Keep fixed-refresh/PWM/VRR limitations; no measured flicker percentages or guarantees. No new visual tokens.

## macOS film slicing

The Film toolbar action and ⌘3 open a separate macOS slicing window, preserving RATE/SHUTTER as the calculator's only segmented modes. Keep the existing monochrome Palette and native controls, central preview, 300–380pt scrolling inspector and bottom frame strip.

The inspector exposes source dimensions/profile, physical film format, frame splitting/cropping/rotation/reordering and export. Show crop controls directly. Retain TIFF/FFF import, automatic gap candidates, manual frame drawing, numeric crop fields, aspect ratios, rotation, batch selection, zoom, undo/redo and project save/open. Remove color-negative/positive classification, original/processed comparison, tone, mask correction, curves, histograms, presets, editing-space selection and adjustment synchronization.

The whole Film page accepts one TIFF/FFF file from Finder, including while a scan is loaded. Use a quiet monochrome dashed outline and release label during a file drag, with no layout movement. Keep the Import button as the keyboard alternative; reuse FilmStore's busy/presentation gates, unsaved-project prompt and input-profile choice. Reject unsupported files, folders and multiple files with localized guidance.

The native Film format picker shows Automatic (135 / 120 / Large format / Unknown) and allows a persisted override. Recognition uses explicitly tagged scan DPI and paired periodic sprockets; a cropped image's aspect ratio alone is not enough to distinguish formats. Format affects geometry only. Add frame assigns a sized first slice in place of the full-scan placeholder, then appends directly at the last frame's lower boundary (right boundary for horizontal strips). Reliable gaps supply a suggested length; otherwise use 135's 3:2, 120's square first frame and large format's 5:4 fallback. Subsequent 120 frames keep the preceding frame's height. Reject a full frame that will not fit, preserving selection and undo. Draw frame and numeric crop controls remain precise alternatives for unusual formats and detection corrections.

Show the active scan's filename and Home-relative path above the preview. Keep long paths selectable and accessible at the minimum window width; source identity follows the successfully loaded scan, including restored projects.

In the strip preview's Select tool, dragging a frame's edge adjusts that side while the opposite edge stays fixed; dragging its interior moves the frame. Selected edges show inset grips so full-image crops remain operable at the canvas boundary; hover and active edges use a yellow line and directional resize cursor. Hide these grips in Draw frame mode. The four numeric crop fields remain the precise keyboard-accessible alternative. A drag remains one undoable edit.

Canvas zoom is relative to Fit (100%). Buttons and ⌘+/⌘− use 100/150/200/300/400/600/800% stops; ⌘0 returns to Fit. Trackpad pinch and ⌘-scroll zoom continuously around the pointer; double-click toggles Fit/200%. Button/menu zoom keeps the viewport center fixed. Strip and Frame retain independent zoom and normalized viewed regions across frame/tab switches; importing a source resets both to centered Fit. FilmStore owns this state, FilmZoomScrollView owns native scrolling/input, and SwiftUI retains the crop tools with screen-sized grips.

Keep the 1800px import/thumbnail/analysis cache. Settled canvas demand includes local display scale and requests a sharper, extended-linear RGBAh image from the full source, cropping/rotating before downsampling. Retain one high-resolution display cache, bounded to 8192px per side and 16,777,216 pixels; preserve the sharper tier on zoom-out and reject cancelled/stale renders. Source geometry determines layout so replacing a bitmap never moves the view or crop coordinates. Export resolution/profile remains independent of zoom.

Rendering changes geometry only. Existing projects may contain removed grading keys; ignore these during decoding and omit them when resaving. Do not read or delete the old user-preset library. Source ICC interpretation, floating-point preview and output profile conversion remain necessary for faithful file handling, not image grading. Untagged inputs require explicit profile assignment.

Export current/checked/all frames or the whole strip as 16-bit Adobe RGB TIFF or 8-bit sRGB JPEG. Individual frame output includes the full rotated bounds; whole-strip rotation is clipped to each original slot. Preserve asynchronous progress, cancellation, collision avoidance, error reporting, and unsaved-project protection. No source scans are rewritten.

Frame-strip thumbnails show the saved rotation and keep their 96 × 60 slot while loading. JPEG exports flatten transparent rotated corners onto white before encoding; TIFF retains transparency. Treat a newly imported scan as an unsaved project so close/quit can offer to save its source link and default frame. Only one file panel or unsaved-work sheet may be active per film window; confirmed discards close without a second prompt.

## iOS negative preview

See `docs/ios-negative-film-preview.md` for the workflow, states and acceptance criteria. Target both iPhone and iPad/iPadOS for release, with no macOS addition. The Film Preview (胶片预览) tab sits between Shutter and Settings, using the existing monochrome tokens and native controls. Preserve the current image and sampled base across iPad split-view/window resizing and phone/tablet orientation changes. The image is the primary surface; the sampled film-base swatch retains its real color. Provide explicit original/positive comparison, sampling confirmation/cancellation, capture-lock status and accessible alternatives to dragging. The scope is preview only: no grading panel or extra editing tools. Accept large TIFF files through the system file picker as well as ordinary photos, and offer TIFF/PNG/JPG file sharing and direct JPG saving to Photos for positive export. Compact and wide layouts prioritize the image. NegativePreviewView owns this native page; NegativeStore owns workflow state and NegativeImagePanel/NegativeZoomView own frame rendering and pinch/pan coordinates. Buttons and menus use native semantics, and format selection is the only export setting. Device-only acceptance is recorded separately in the implementation notes.

Film-base sampling uses a white crosshair and center dot around the source-sized region, with a dark shadow for contrast. The camera continuously autofocuses by default; a tap moves the continuous-focus region rather than switching to one-shot focus. Camera taps only adjust focus; the explicit Sample film base action starts capture locking at image center, then reveals the full source for positioning. Do not require a separate focus/sample mode switch. Sampling retains tap and directional controls and adds a labeled Return to center action. Confirmation stores only the base RGB values in the current camera session and resumes positive preview; cancellation preserves the committed base. Restarting capture clears calibration. NegativeStore owns this state and NegativeZoomView owns the zoom-aware marker; no new visual tokens or persistent calibration storage.
The sampling target uses a compact 1.5pt center dot, 3pt crosshair arms and 1pt stroke at screen scale, preserving visibility without covering film detail; the sample-region box still represents the source sampling area.

Camera settings live in a native scrollable sheet opened from the viewfinder header. Default to Auto (Macro) only when a virtual rear camera contains an autofocus-capable ultra-wide lens; retain explicit physical lens choices and discovered video presets. Do not expose manual exposure compensation: continuous auto-exposure plus film-base sampling normalizes brightness on a light table. Show the reported minimum focusing distance with a fixed-focus explanation when needed; do not expose an autofocus recovery button. Automatic macro status is a caption below the camera hint. Switching constituent lenses invalidates calibration and leaves a persistent re-sampling hint until confirmation. Disable settings during sampling, loading, export or frozen capture. Changing lens or resolution invalidates calibration; show this before the edit. Reuse existing colors, native menus and 44pt actions.
Camera capture opens an immersive viewport with navigation/title/tab bars hidden and an explicit Close camera action that suspends capture. The monochrome header overlays Close, Original/Positive and Settings; the bottom action panel contains focus/lock status, macro status, Sample/Resample, Freeze/Continue and Export. Settings use a scrollable native sheet and do not resize the viewport. Source dimensions live in settings. Native buttons, menus and pickers remain the canonical interaction owners; NegativeStore retains workflow/lifecycle ownership.

Camera display always fits the complete source outside the header/action panel: film edges are never cropped and there is no fill-screen toggle. Display scaling never changes source pixels, capture format, sampling coordinates or exported bounds, and preserves precise UIKit zoom/tap mapping. Wide windows place the scrollable action panel at the right; portrait places it below. Controls remain inside safe areas with 44pt targets. File review retains its full-image workbench. Palette and SF Pro/SF Mono remain the runtime visual owners; camera overlays use the existing background token at 94% opacity for readable controls over arbitrary footage.

### File preview display feedback (2026-09-28)

Keep document import/render/export progress, cancellation and errors in a bottom safe-area inset above the tab bar so they remain visible while scrolling. Import starts with an 1800-pixel long-side preview; settled pinch zoom requests a sharper bitmap based on screen pixels, bounded by source dimensions and the device memory budget. Preserve zoom and the viewed region when replacing a display tier, and sharpen either comparison variant when switching back to it. Camera frames retain capture resolution. Sampling and exports continue to use source pixels; display zoom never crops or reduces exported dimensions.

Only replace a zoom preview when the actual rendered bitmap is sharper than its cached comparison variant; a memory-limited request must not reduce visible quality. A newly imported source always starts centered at fit, even when its bitmap dimensions match the previous file. Preserve zoom/pan only for tiers and comparison within the same source.

### Save positive to Photos (2026-09-29)

The shared export menu includes Save positive to Photos (JPG) in file review and immersive camera. Save the committed positive at source dimensions, independent of the selected comparison or display zoom. Keep TIFF/PNG/JPG file sharing. Ask only for add-only Photos authorization when saving; show native success/error feedback and a Settings action after denied access. NegativeStore owns pending/duplicate prevention and temporary-file lifetime; NegativePhotoLibrary owns PhotoKit. Once the system photo transaction is submitted, show saving progress without a Cancel action until completion. Reuse existing Palette, typography, native Menu/Button/alert, and English/Chinese localization.

### Open images from other apps (2026-09-29)

Register supported image document types as alternate Viewer handlers on iOS. System file-open delivery selects Film Preview and imports a private copy, including on cold launch. ContentView owns NegativeStore and tab routing; NegativePreviewView retains presentation state and closes its transient pickers/settings for external opens. Provider reads are coordinated and security-scoped. Keep the last valid image on decoding failure. If a Photos save has already been submitted, finish it before importing the latest pending external image. This is a single-image workflow; discovery and naming of the Open in FFFilm activity remain system/source-app controlled.
