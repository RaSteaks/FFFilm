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
  page-max: "920pt"
components:
  button:
    minHeight: "44pt touch / 28pt macOS"
    emphasis: "native bordered or quiet capsule"
  field:
    surface: "group-owned opaque surface"
    label: "system font; values use SF Mono"
  resultPanel:
    primaryMetric: "GB or GiB per hour"
    disclosure: "technical details collapsed by default"
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
- **Locale and language policy:** Simplified Chinese or English follows the system language; all other languages fall back to English. Camera models, codec names, FPS and other production terms remain source text; numeric formatting follows the active system locale.
- **Usage scene:** frequent, time-sensitive use on iPhone beside a camera, with iPad and macOS as wider workbench surfaces.
- **Register:** professional production tool.
- **Memorable signature:** the live rate result appears before detailed controls on compact phones, behaving like the readout of a field meter.
- **Restraint:** native pickers, toggles and steppers remain familiar; decorative color, shadows and non-functional motion are avoided.
- **Anti-references:** consumer finance dashboards, colorful camera-control panels and oversized card stacks that hide the live result below the fold.
- **Token ownership/runtime mapping:** this file documents the durable intent; `Palette`, shared field surfaces and button styles in `FFFilm/ContentView.swift` are the canonical runtime mapping.

## Colors

The product is intentionally monochrome. `background` provides the chassis, `surface` and `surfaceRaised` establish depth, `text` carries primary values, and the two muted tokens establish metadata hierarchy. Selection must use contrast and shape as well as color. The app currently ships dark-only; new themes must define equivalent semantic tokens before adoption.

## Typography

SF Pro is used for native controls and action labels. SF Mono is reserved for measurements, camera settings, compact labels and result readouts. Numeric output uses monospaced figures to avoid jitter. Primary controls use Dynamic Type-aware body sizing on compact iOS layouts; metadata remains subordinate but legible.

## Layout

Spacing follows a 4pt rhythm. Compact iPhone layouts use 12pt gutters, put the live result above the settings list and render each setting as a horizontal row with a minimum 44pt control region. At 900pt of usable content width, the page changes to a 55:45 parameter/result split; below that threshold the result-first single-column flow remains. Capture format and storage plan groups stay expanded. Content respects safe areas and the page remains a single vertical scroller.

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

RATE and SHUTTER remain the only top-level segmented modes. Quick Start is a horizontally scrolling preset strip with clear selected and pressed states. Live results use the strongest type hierarchy and numeric content transitions.

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

The shared FieldCard owns field presentation, native TextField/Menu/Picker/Toggle own platform interaction, CalculatorStore owns settings and one-shot RATE import, and CalculatorEngine owns validation and results. Shutter fields keep editing drafts, show pending results for unfinished input and show a specific inline error after submit or blur. Invalid drafts must not leave a seemingly current computed result onscreen. RESET clears all shutter settings and draft state.

Camera fps and maximum angle are shared across the three modes; other input values survive mode changes. USE RATE FPS copies both frame rates without linking the two pages or replacing angle/light choices. The default maximum is a user-set 360° theoretical limit, not a verified camera capability. Over-limit theoretical results remain visible with a symbol and explanatory text; they are never silently clamped.

Flicker candidates show at most three nearest complete optical-cycle exposures. A 50/60 Hz mains choice explicitly assumes 100/120 Hz light pulses. Optional light checking in matching is off by default and only adds reference candidates; it never changes the target. Empty candidates, non-integer target cycles and unverified real-world lighting have distinct text. Never label a result as guaranteed flicker-free.

Maintain one page scroller, compact result-first layout, native 44pt controls, keyboard focus and Dynamic Type. Center the focused input after keyboard insets settle and reserve the result panel’s height during editing so temporary invalid drafts cannot collapse the scroller or dismiss the keyboard. Use explicit accessibility containers so parent test identifiers do not replace descendant control identifiers. Error and result states combine text with symbols and do not rely on color. No new visual tokens are introduced.

### Iconography

Use SF Symbols with a consistent outline hierarchy. Filled variants indicate committed state, not decoration. Icon-only controls always keep accessible labels and 44pt targets.

### Motion

Motion communicates selection, numeric changes and action completion. Press feedback is under 150ms; content transitions use short native springs. Reduced Motion removes transform animation while retaining state changes and haptics where the system permits them.

### Content and data visualization

All result panels and pinned comparison rows support native text selection and copying, including numeric values, units, candidates and explanatory messages. On macOS, select text and use ⌘C or the native context menu; this is distinct from the configuration-copy toolbar action (⇧⌘C).

Labels are short production terms in uppercase. Results preserve units beside values, show estimated recording time against the selected media capacity, distinguish capture time from playback duration, and retain the estimate disclaimer. Avoid marketing copy and decorative metrics.

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

- Native Settings scene and toolbar link on macOS; gear action and navigation sheet with Done on iOS. Settings copy is Chinese as requested; existing technical labels remain unchanged.
- `StorageUnit` owns decimal GB to binary GiB conversion; `SettingsView` owns the native preference picker. AppStorage persists and synchronizes the default (decimal) across windows. Reset does not erase this preference.
- RATE and pinned storage rates and daily totals follow the preference using GB/TB or GiB/TiB. Engine values and manufacturer media labels remain decimal; bitrate, recording time and utilization stay invariant.
- Explain common Apple/Windows conventions without claiming OS exclusivity; distinguish MB bytes from Mb bits.

- Storage settings keep differences, calculation impact and source links inside one initially collapsed native “详情” disclosure within the “容量换算” section, below the picker and persistence hint; the unit picker stays visible.

## Recording plan, memory and comparison

Recording results lead with GB/h or GiB/h, then bitrate, plan total capacity, actual planned recording time and the selected card's available capture time. Playback duration, active image area and the calculation boundary remain in a collapsed Technical details disclosure. A direct duration editor accepts 0.25–24 hours, retains the last valid result while a draft is incomplete, shows inline validation and offers 1/4/8/12-hour presets alongside the native stepper.

Camera format choices are remembered per camera ID in a versioned UserDefaults payload. Media and planned duration are window-local. Invalid, corrupt, future-version or catalog-missing records are ignored; each window keeps its own active state while the latest valid camera edit wins for the next switch. Compatibility normalization owns its own non-blocking adjustment banner.

The result action stores independent comparison snapshots, deduplicates identical settings and caps the list at four. The comparison sheet shows complete format, cadence, rate, plan and card runtime values, and supports removal. Human-readable copy is separate from the unchanged configuration-link format.

### Multiple display shutter input

The existing LIGHT SOURCE picker owns 多显示设备. A shared FieldCard and native text field accept a comma-separated Hz list with explicit decimal-point instructions. Reuse light-field keyboard focus, scroll centering and result-height retention. Preserve raw list edits across modes/import; reset restores 60, 120. Show invalid-list and no-common-exposure messages in the main result; keep per-device cycle counts and fixed-refresh/PWM/VRR qualifications in DETAILS. No new visual tokens.
