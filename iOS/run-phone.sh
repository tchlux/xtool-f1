#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED="${DERIVED_DATA:-$ROOT/.DerivedData-phone}"
PROJECT="$ROOT/xToolF1App.xcodeproj"
SCHEME="xToolF1App"
BUNDLE_ID="com.thomaslux.xToolF1App"
APP="$DERIVED/Build/Products/Debug-iphoneos/xToolF1App.app"
SCENARIO=normal
UNINSTALL=0
TARGET_ID=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [DEVICE_ID] [SCENARIO] [--uninstall]

Build, install, and open xTool F1 on a connected iPhone.
Normal launches pass --phone-deploy so the app shows a deployment banner.

Scenarios:
  normal
  editor-smoke
  editor-visual
  canvas-smoke
  preview-project
  first-project

Options:
  -u, --uninstall  Uninstall the app before installing
  --editor-smoke   Alias for scenario editor-smoke
  --editor-visual  Alias for scenario editor-visual
  -h, --help       Show this help

Environment:
  DEVICE_ID        Device id override
  DERIVED_DATA     Build output path (default: $DERIVED)
  DEVELOPER_DIR    Xcode developer dir (default: $DEVELOPER_DIR)
EOF
}

while (($#)); do
  case "$1" in
    -u|--uninstall) UNINSTALL=1 ;;
    --editor-smoke) SCENARIO=editor-smoke ;;
    --editor-visual) SCENARIO=editor-visual ;;
    normal|editor-smoke|editor-visual|canvas-smoke|preview-project|first-project) SCENARIO="$1" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) [[ -z "$TARGET_ID" ]] || { usage >&2; exit 1; }; TARGET_ID="$1" ;;
  esac
  shift
done

find_device() {
  env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun devicectl list devices |
    awk '/available \(paired\)/ && /iPhone/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/) {
          print $i
          exit
        }
      }
    }'
}

DEVICE_ID="${TARGET_ID:-${DEVICE_ID:-$(find_device)}}"
[[ -n "$DEVICE_ID" ]] || { echo "No available paired iPhone found." >&2; exit 1; }

typeset -a LAUNCH_ARGS LAUNCH_OPTIONS
LAUNCH_OPTIONS=(--terminate-existing)
case "$SCENARIO" in
  normal) LAUNCH_ARGS=(--phone-deploy) ;;
  editor-smoke) LAUNCH_ARGS=(--scenario editor-smoke); LAUNCH_OPTIONS+=(--console) ;;
  editor-visual) LAUNCH_ARGS=(--scenario editor-visual); LAUNCH_OPTIONS+=(--console) ;;
  canvas-smoke) LAUNCH_ARGS=(--scenario canvas-smoke); LAUNCH_OPTIONS+=(--console) ;;
  preview-project) LAUNCH_ARGS=(--scenario preview-project) ;;
  first-project) LAUNCH_ARGS=(--scenario first-project) ;;
esac

mkdir -p "$DERIVED"
(( UNINSTALL )) && env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun devicectl device uninstall app --device "$DEVICE_ID" "$BUNDLE_ID" >/dev/null 2>&1 || true

env DEVELOPER_DIR="$DEVELOPER_DIR" "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build

env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
env DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun devicectl device process launch --device "$DEVICE_ID" "${LAUNCH_OPTIONS[@]}" "$BUNDLE_ID" "${LAUNCH_ARGS[@]}"
