#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="GoogleHomeCameraWidget"

cd "${REPO_DIR}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build --disable-sandbox -c release

".build/release/${APP_NAME}" --smoke-test
CAMERA_WIDGET_BROADCAST_PORT=12985 ".build/release/${APP_NAME}" --broadcast-source-smoke-test

xcrun swift \
    -module-cache-path "${REPO_DIR}/build/WidgetRenderModuleCache" \
    "${REPO_DIR}/scripts/widget_render_smoke.swift" \
    "${REPO_DIR}/Assets/AppIcon.png"

"${REPO_DIR}/scripts/widget_e2e_smoke.sh"

echo "Headless integration smoke tests passed."
