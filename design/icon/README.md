# FFFilm — grayscale time slices

## Source and native delivery

- Approved artwork: `explorations/2026-09-21-time-slices-grayscale/time-slices-grayscale.png`.
- Normalized 1024px artwork: `source/time-slices-grayscale-1024.png`.
- Canonical Icon Composer 1.2 document: `format.icon`; opened, edited, saved and reopened in the native app.
- Build input: `../../FFFilm/AppIcon.icon`, synchronized from the canonical document. Xcode 26.3 automatically includes this through the existing filesystem-synchronized app source group, with the existing `AppIcon` build setting.

The artwork is one opaque raster layer named **Time Slices — Grayscale Raster**. The three faces are not independently editable. Glass, specular and translucency are disabled and group shadow is zero, preserving the selected artwork's own shading. Native platform masking and icon treatments are supplied by Apple's renderer. Default/Dark retain the dark field; Tinted follows the system tint.

## Exports and fallbacks

`exports/iOS-Default.png`, `iOS-Dark.png` and `iOS-TintedDark.png` are native, masked appearance previews. TintedDark is a sample of the renderer's tint, not a neutral asset-catalog input.

`exports/macOS-Default.png` is the 1024px native macOS rendition loaded through AppKit from Xcode's compiled `Assets.car`. It contains Apple's padding, rounded mask and shadow. The Composer export sheet could not enable its save action on this host; its CLI macOS preview lacks Dock margins, so it is not used as the legacy master. The compiled rendition was visually checked against the icon extracted from the built app's ICNS.

All 13 slots in `FFFilm/Assets.xcassets/AppIcon.appiconset` are refreshed. Ten macOS PNGs derive from the native macOS master without adding another mask or margin. The three iOS raster fallbacks use the approved square artwork without pre-masking or alpha: Default and Dark preserve its existing dark field; Tinted is neutral luminance. The native `.icon` takes precedence in the current Xcode build.

Run `script/update_icons.sh` to synchronize the native source, build it, generate previews, and package raster fallbacks. Rebuild afterward to include the refreshed raster files. Superseded icon archives and exploration rounds were deleted at the user's request; only the approved grayscale artwork and current delivery resources remain.

Apple's integration guidance: [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

## Verification (2026-09-21)

- Final macOS Debug build and generic iOS Simulator Debug build both passed with the native `.icon` and refreshed raster catalog. Build output confirms `actool` consumes `FFFilm/AppIcon.icon`.
- Checked every slot's pixel dimensions, opaque iOS channels, grayscale tinted mode, transparent macOS margins, and exact synchronization of the two `.icon` packages. Inspected Default/Dark/Tinted native exports, compiled macOS output and 32px native / 64px raster previews.
- `update_icons.sh` passes shell syntax validation; both Swift packaging helpers ran successfully. No calculation code changed, so calculation unit tests were not rerun.
- The existing build-and-launch script was rejected by automatic approval review because it first force-quits FFFilm. Verification continued through build-only commands, without terminating or relaunching the user's current app session.
