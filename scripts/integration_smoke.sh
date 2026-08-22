#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_NAME="GoogleHomeCameraWidget"

cd "${REPO_DIR}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift build -c release

".build/release/${APP_NAME}" --smoke-test

CAMERA_WIDGET_USE_MOCK_CAMERAS=1 ".build/release/${APP_NAME}" &
pid="$!"

sleep 5

if ! kill -0 "${pid}" >/dev/null 2>&1; then
    echo "Mock app launch exited before the 5 second smoke window." >&2
    wait "${pid}" || true
    exit 1
fi

kill "${pid}" >/dev/null 2>&1 || true
wait "${pid}" >/dev/null 2>&1 || true

echo "Mock app launch smoke test passed."
