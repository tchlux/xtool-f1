#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEVICE="${DEVICE:-3A9ECE81-38CB-48BA-9D24-74F63F402E63}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED_DATA:-$ROOT/.DerivedData-sim}"
PROJECT="$ROOT/xToolF1App.xcodeproj"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/xToolF1App.app"
BUNDLE_ID=com.thomaslux.xToolF1App
SCENARIO=normal
LAUNCH_STATE=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [DEVICE_ID] [SCENARIO] [--state launch-state.json]

Build, install, and open xTool F1 in the iOS Simulator.

Scenarios:
  normal
  editor-smoke
  editor-visual
  canvas-smoke
  preview-project
  first-project

Environment:
  DEVICE        Simulator device id override
  DERIVED_DATA  Build output path (default: $DERIVED)
  DEVELOPER_DIR Xcode developer dir (default: $DEVELOPER_DIR)
EOF
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --state)
      shift
      if (($# == 0)); then echo "--state requires a JSON file" >&2; exit 1; fi
      LAUNCH_STATE="$1"
      ;;
    --editor-smoke) SCENARIO=editor-smoke ;;
    --editor-visual) SCENARIO=editor-visual ;;
    normal|editor-smoke|editor-visual|canvas-smoke|preview-project|first-project) SCENARIO="$1" ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) DEVICE="$1" ;;
  esac
  shift
done

typeset -a LAUNCH_ARGS LAUNCH_OPTIONS
LAUNCH_OPTIONS=(--terminate-running-process)
case "$SCENARIO" in
  normal) LAUNCH_ARGS=() ;;
  editor-smoke) LAUNCH_ARGS=(--scenario editor-smoke); LAUNCH_OPTIONS+=(--console) ;;
  editor-visual) LAUNCH_ARGS=(--scenario editor-visual); LAUNCH_OPTIONS+=(--console) ;;
  canvas-smoke) LAUNCH_ARGS=(--scenario canvas-smoke); LAUNCH_OPTIONS+=(--console) ;;
  preview-project) LAUNCH_ARGS=(--scenario preview-project) ;;
  first-project) LAUNCH_ARGS=(--scenario first-project) ;;
esac

if [[ -n "$LAUNCH_STATE" ]]; then
  [[ -f "$LAUNCH_STATE" ]] || { echo "Launch state not found: $LAUNCH_STATE" >&2; exit 1; }
  LAUNCH_ARGS+=(--launch-state-json "$(base64 -i "$LAUNCH_STATE" | tr -d '\n')")
fi

env DEVELOPER_DIR="$DEVELOPER_DIR" "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$PROJECT" \
  -scheme xToolF1App \
  -destination "platform=iOS Simulator,id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  build

env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun simctl boot "$DEVICE" || true
open -a Simulator
env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun simctl install "$DEVICE" "$APP"
env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun simctl launch "${LAUNCH_OPTIONS[@]}" "$DEVICE" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"
