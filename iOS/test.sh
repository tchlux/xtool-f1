#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export XDG_CACHE_HOME="$ROOT/.build/cache"

usage() {
  cat <<EOF
Usage: ./test.sh quick|core|all|sim <scenario>|phone <scenario>

Scenarios: normal, editor-smoke, editor-visual, canvas-smoke, preview-project, first-project
EOF
}

swift_test() {
  local tier="$1"
  shift
  mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
  swift test --scratch-path "$ROOT/.build/swiftpm-$tier" "$@"
}

case "${1:-}" in
  quick)
    swift_test quick --filter 'RasterLogicTests|F1ProtocolTests|GeometryDiscoveryTests'
    ;;
  core)
    swift_test core
    ;;
  sim)
    shift
    "$ROOT/run-sim.sh" "$@"
    ;;
  phone)
    shift
    "$ROOT/run-phone.sh" "${1:-normal}"
    ;;
  all)
    swift_test core
    "$ROOT/run-sim.sh" editor-smoke
    "$ROOT/run-sim.sh" canvas-smoke
    "$ROOT/run-sim.sh" preview-project
    ;;
  -h|--help|"")
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
