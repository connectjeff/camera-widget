#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build/WidgetE2ESmoke"

mkdir -p "${BUILD_DIR}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun swiftc \
    -D WIDGET_E2E_TEST \
    -module-cache-path "${BUILD_DIR}/ModuleCache" \
    "${REPO_DIR}/Sources/GoogleHomeCameraWidgetExtension/WidgetExtension.swift" \
    "${REPO_DIR}/scripts/widget_e2e_smoke.swift" \
    -o "${BUILD_DIR}/widget-e2e-smoke"

cd "${REPO_DIR}"
"${BUILD_DIR}/widget-e2e-smoke"
