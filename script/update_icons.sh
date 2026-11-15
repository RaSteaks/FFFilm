#!/usr/bin/env bash
set -euo pipefail

# Composer's source remains in design; Xcode's synchronized source group picks
# up the identically named AppIcon.icon copy and compiles native appearances.
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSER_TOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
SOURCE_ICON="$TASK_ROOT/design/icon/format.icon"
EXPORT_DIR="$TASK_ROOT/design/icon/exports"
APP_BUNDLE="$TASK_ROOT/build/Build/Products/Debug/FFFilm.app"
mkdir -p "$EXPORT_DIR" "$TASK_ROOT/FFFilm/AppIcon.icon/Assets"
cp "$SOURCE_ICON/icon.json" "$TASK_ROOT/FFFilm/AppIcon.icon/icon.json"
cp "$SOURCE_ICON/Assets/01-front.png" "$TASK_ROOT/FFFilm/AppIcon.icon/Assets/01-front.png"

xcodebuild -quiet -project "$TASK_ROOT/FFFilm.xcodeproj" -scheme FFFilm \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$TASK_ROOT/build" build

# These are native appearance previews, not unmasked iOS fallback artwork.
for appearance in Default Dark TintedDark; do
  "$COMPOSER_TOOL" "$SOURCE_ICON" --export-image \
    --output-file "$EXPORT_DIR/iOS-$appearance.png" --platform iOS \
    --rendition "$appearance" --width 1024 --height 1024 --scale 1
done

# The Composer CLI's macOS preview is edge-to-edge. Read Xcode's compiled
# macOS asset instead to preserve its native Dock padding at full resolution.
swift "$TASK_ROOT/script/export_compiled_icon.swift" "$APP_BUNDLE" "$EXPORT_DIR/macOS-Default.png"
swift "$TASK_ROOT/script/package_icon_assets.swift" "$TASK_ROOT"
cp "$EXPORT_DIR/iOS-Default.png" "$TASK_ROOT/design/icon/format-iOS-Default-1024x1024@1x.png"

# The support site reuses each platform's icon: browser tabs get the padded
# macOS slots, iOS home screens mask the opaque fallback themselves.
RASTER_DIR="$TASK_ROOT/FFFilm/Assets.xcassets/AppIcon.appiconset"
SITE_ICON_DIR="$TASK_ROOT/support/icons"
cp "$RASTER_DIR/AppIcon-mac-32.png" "$SITE_ICON_DIR/favicon-32.png"
cp "$RASTER_DIR/AppIcon-mac-32@2x.png" "$SITE_ICON_DIR/favicon-64.png"
sips -s format png -z 180 180 "$RASTER_DIR/AppIcon-iOS-Default.png" --out "$SITE_ICON_DIR/apple-touch-icon.png" >/dev/null
sips -s format png -z 192 192 "$EXPORT_DIR/iOS-Default.png" --out "$SITE_ICON_DIR/icon-192.png" >/dev/null
sips -s format png -z 96 96 "$EXPORT_DIR/iOS-Default.png" --out "$SITE_ICON_DIR/brand-mark.png" >/dev/null
echo 'Native icon, all 13 raster slots and the support site icons updated. Rebuild to package the refreshed fallbacks.'
