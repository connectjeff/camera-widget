#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_SCRIPT="${REPO_DIR}/build.sh"
VERSION="$(grep '^VERSION=' "${BUILD_SCRIPT}" | head -1 | cut -d'"' -f2)"
PACKAGE_PATH="${REPO_DIR}/build/GoogleHomeCameraWidget-${VERSION}.pkg"
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

pkgutil --payload-files "${PACKAGE_PATH}" | grep -q './Applications/GoogleHomeCameraWidget.app$'
pkgutil --payload-files "${PACKAGE_PATH}" | grep -q './Applications/GoogleHomeCameraWidget.app/Contents/PlugIns/GoogleHomeCameraWidgetExtension.appex$'

echo "Release package ready: ${PACKAGE_PATH}"

if [[ "${PUBLISH}" -eq 1 ]]; then
    tag="v${VERSION}"
    if ! git rev-parse "${tag}" >/dev/null 2>&1; then
        git tag -a "${tag}" -m "Release ${tag}"
        git push origin "${tag}"
    fi

    gh release create "${tag}" "${PACKAGE_PATH}" \
        --title "Google Home Camera Widget ${tag}" \
        --notes "macOS installer package. Installs the app into /Applications and registers the embedded WidgetKit extension."
fi
