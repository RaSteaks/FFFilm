#!/usr/bin/env bash
set -euo pipefail
# One macOS build/launch entry point keeps the verified app and Run action aligned.
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in run|--debug|--logs|--telemetry|--verify) ;; *) exit 2 ;; esac
pkill -x FFFilm >/dev/null 2>&1 || true
xcodebuild -quiet -project "$TASK_ROOT/FFFilm.xcodeproj" -scheme FFFilm -configuration Debug -destination 'platform=macOS' -derivedDataPath "$TASK_ROOT/build" build
APP="$TASK_ROOT/build/Build/Products/Debug/FFFilm.app"
if [[ "$MODE" == --debug ]]; then
    exec lldb -- "$APP/Contents/MacOS/FFFilm"
fi
open -n "$APP"
case "$MODE" in
    --verify) sleep 1; pgrep -x FFFilm >/dev/null ;;
    --logs|--telemetry) exec /usr/bin/log stream --info --style compact --predicate 'process == "FFFilm"' ;;
esac
