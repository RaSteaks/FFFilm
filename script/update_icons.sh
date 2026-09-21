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
echo 'Native icon and all 13 raster slots updated. Rebuild to package the refreshed fallbacks.'
