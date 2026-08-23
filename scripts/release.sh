#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${REPO_DIR}/build.sh"
VERSION="$(grep '^VERSION=' "${BUILD_SCRIPT}" | head -1 | cut -d'"' -f2)"
PACKAGE_PATH="${REPO_DIR}/build/GoogleHomeCameraWidget-${VERSION}.pkg"
CHECKSUM_PATH="${PACKAGE_PATH}.sha256"
RELEASE_NOTES_PATH="${REPO_DIR}/RELEASE_NOTES.md"
PUBLISH=0

for arg in "$@"; do
    case "${arg}" in
        --publish)
            PUBLISH=1
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Usage: scripts/release.sh [--publish]" >&2
            exit 2
            ;;
    esac
done

cd "${REPO_DIR}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is dirty. Commit or stash changes before cutting a release." >&2
    git status --short >&2
    exit 1
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" "${BUILD_SCRIPT}" --pkg

xcrun swift \
    -module-cache-path "${REPO_DIR}/build/WidgetRenderModuleCache" \
    "${REPO_DIR}/scripts/widget_render_smoke.swift" \
    "${REPO_DIR}/Assets/AppIcon.png"

pkgutil --payload-files "${PACKAGE_PATH}" | grep -q './Applications/GoogleHomeCameraWidget.app$'
pkgutil --payload-files "${PACKAGE_PATH}" | grep -q './Applications/GoogleHomeCameraWidget.app/Contents/PlugIns/GoogleHomeCameraWidgetExtension.appex$'

PACKAGE_CHECK_DIR="$(mktemp -d)"
trap 'rm -rf "${PACKAGE_CHECK_DIR}"' EXIT
pkgutil --expand "${PACKAGE_PATH}" "${PACKAGE_CHECK_DIR}/expanded"
test -x "${PACKAGE_CHECK_DIR}/expanded/Scripts/preinstall"
test -x "${PACKAGE_CHECK_DIR}/expanded/Scripts/postinstall"
grep -q 'brew.*install ffmpeg' "${PACKAGE_CHECK_DIR}/expanded/Scripts/preinstall"
grep -q 'go2rtc-patched' "${PACKAGE_CHECK_DIR}/expanded/Scripts/postinstall"
(
    cd "$(dirname "${PACKAGE_PATH}")"
    shasum -a 256 "$(basename "${PACKAGE_PATH}")"
) > "${CHECKSUM_PATH}"

echo "Release package ready: ${PACKAGE_PATH}"
echo "Release checksum ready: ${CHECKSUM_PATH}"

if [[ "${PUBLISH}" -eq 1 ]]; then
    test -f "${RELEASE_NOTES_PATH}"
    tag="${VERSION}"
    if ! git rev-parse "${tag}" >/dev/null 2>&1; then
        git tag -a "${tag}" -m "Release ${tag}"
        git push origin "${tag}"
    fi

    gh release create "${tag}" "${PACKAGE_PATH}" "${CHECKSUM_PATH}" \
        --title "${VERSION}" \
        --notes-file "${RELEASE_NOTES_PATH}"
fi
