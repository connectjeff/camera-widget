#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GoogleHomeCameraWidget"
EXTENSION_NAME="GoogleHomeCameraWidgetExtension"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="com.jeffalderson.google-home-camera-widget"
EXTENSION_BUNDLE_ID="${BUNDLE_ID}.snapshot-widget"
VERSION="0.1.4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${BUNDLE_NAME}"
EXTENSION_DIR="${APP_DIR}/Contents/PlugIns/${EXTENSION_NAME}.appex"
XCODE_PROJECT="${SCRIPT_DIR}/CameraWidget.xcodeproj"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

build_installer_package() {
    local package_root="${BUILD_DIR}/pkg-root"
    local package_scripts="${BUILD_DIR}/pkg-scripts"
    local component_plist="${BUILD_DIR}/pkg-components.plist"
    local package_path="${BUILD_DIR}/${APP_NAME}-${VERSION}.pkg"

    rm -rf "${package_root}" "${package_scripts}" "${component_plist}" "${package_path}"
    mkdir -p "${package_root}/Applications" "${package_scripts}"
    COPYFILE_DISABLE=1 ditto --norsrc "${APP_DIR}" "${package_root}/Applications/${BUNDLE_NAME}"
    xattr -cr "${package_root}" >/dev/null 2>&1 || true

    cat > "${package_scripts}/preinstall" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$(/usr/bin/uname -m)" != "arm64" ]]; then
    echo "Google Home Camera Widget currently requires an Apple Silicon Mac." >&2
    exit 1
fi

os_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [[ "${os_major}" -lt 26 ]]; then
    echo "Google Home Camera Widget requires macOS 26 or newer." >&2
    exit 1
fi

for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    if [[ -x "${candidate}" ]] && "${candidate}" -version >/dev/null 2>&1; then
        exit 0
    fi
done

console_user="$(/usr/bin/stat -f '%Su' /dev/console)"
if [[ "${console_user}" == "root" || "${console_user}" == "loginwindow" ]]; then
    echo "FFmpeg is missing and no signed-in user is available for dependency installation." >&2
    exit 1
fi

brew=""
for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "${candidate}" ]]; then
        brew="${candidate}"
        break
    fi
done

if [[ -z "${brew}" ]]; then
    echo "FFmpeg is missing. Install Homebrew from https://brew.sh, then run this installer again; it will install FFmpeg automatically." >&2
    exit 1
fi

echo "Installing required FFmpeg dependency with Homebrew..."
/usr/bin/sudo -H -u "${console_user}" /usr/bin/env \
    HOMEBREW_NO_AUTO_UPDATE=1 \
    HOMEBREW_NO_ANALYTICS=1 \
    "${brew}" install ffmpeg

if ! "${brew}" --prefix ffmpeg >/dev/null 2>&1 || ! "${brew}" --prefix ffmpeg | /usr/bin/xargs -I{} test -x "{}/bin/ffmpeg"; then
    echo "Homebrew completed without providing an executable FFmpeg binary." >&2
    exit 1
fi
SCRIPT
    chmod 755 "${package_scripts}/preinstall"

    cat > "${package_scripts}/postinstall" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/${BUNDLE_NAME}"
EXTENSION_PATH="\${APP_PATH}/Contents/PlugIns/${EXTENSION_NAME}.appex"
BRIDGE_PATH="\${APP_PATH}/Contents/Resources/Tools/go2rtc-patched"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CONSOLE_USER="\$(/usr/bin/stat -f '%Su' /dev/console)"

if [[ ! -x "\${BRIDGE_PATH}" ]]; then
    echo "The packaged go2rtc bridge is missing or not executable." >&2
    exit 1
fi

FFMPEG_PATH=""
for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    if [[ -x "\${candidate}" ]] && "\${candidate}" -version >/dev/null 2>&1; then
        FFMPEG_PATH="\${candidate}"
        break
    fi
done
if [[ -z "\${FFMPEG_PATH}" ]]; then
    echo "The required FFmpeg dependency is not installed." >&2
    exit 1
fi

if [[ "\${CONSOLE_USER}" != "root" && "\${CONSOLE_USER}" != "loginwindow" ]]; then
    CONSOLE_UID="\$(/usr/bin/id -u "\${CONSOLE_USER}")"
    if [[ -x "\${LSREGISTER}" ]]; then
        /bin/launchctl asuser "\${CONSOLE_UID}" /usr/bin/sudo -u "\${CONSOLE_USER}" "\${LSREGISTER}" -f "\${APP_PATH}" >/dev/null 2>&1 || true
    fi
    if [[ -d "\${EXTENSION_PATH}" ]]; then
        /bin/launchctl asuser "\${CONSOLE_UID}" /usr/bin/sudo -u "\${CONSOLE_USER}" /usr/bin/pluginkit -a "\${EXTENSION_PATH}" >/dev/null 2>&1 || true
        /bin/launchctl asuser "\${CONSOLE_UID}" /usr/bin/sudo -u "\${CONSOLE_USER}" /usr/bin/pluginkit -e use -i "\${EXTENSION_BUNDLE_ID}" >/dev/null 2>&1 || true
    fi
    /bin/launchctl asuser "\${CONSOLE_UID}" /usr/bin/sudo -u "\${CONSOLE_USER}" /usr/bin/killall WidgetKitExtensionHost >/dev/null 2>&1 || true
fi
exit 0
SCRIPT
    chmod 755 "${package_scripts}/postinstall"

    pkgbuild --analyze --root "${package_root}" "${component_plist}"
    /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "${component_plist}"
    /usr/libexec/PlistBuddy -c "Set :0:BundleIsVersionChecked true" "${component_plist}"
    /usr/libexec/PlistBuddy -c "Set :0:BundleOverwriteAction upgrade" "${component_plist}"

    COPYFILE_DISABLE=1 pkgbuild \
        --root "${package_root}" \
        --component-plist "${component_plist}" \
        --scripts "${package_scripts}" \
        --identifier "${BUNDLE_ID}.installer" \
        --version "${VERSION}" \
        --install-location "/" \
        "${package_path}"

    echo "Built installer ${package_path}"
}

cd "${SCRIPT_DIR}"

XCODE_DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ! -x "${XCODE_DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    echo "Xcode is required to build the WidgetKit extension and App Intents metadata." >&2
    exit 1
fi

DEVELOPER_DIR="${XCODE_DEVELOPER_DIR}" "${XCODE_DEVELOPER_DIR}/usr/bin/xcodebuild" \
    -quiet \
    -project "${XCODE_PROJECT}" \
    -scheme "${APP_NAME}" \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    build

XCODE_APP="${DERIVED_DATA}/Build/Products/Release/${BUNDLE_NAME}"
rm -rf "${APP_DIR}"
COPYFILE_DISABLE=1 ditto --norsrc "${XCODE_APP}" "${APP_DIR}"

if [[ ! -f "${EXTENSION_DIR}/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]; then
    echo "Widget App Intents metadata is missing from ${EXTENSION_DIR}" >&2
    exit 1
fi

codesign --verify --deep --strict "${APP_DIR}"

if [[ "${1:-}" == "--install" ]]; then
    echo "The per-user install mode has been removed because duplicate bundle registrations break WidgetKit. Build --pkg and install the package into /Applications instead." >&2
    exit 2
elif [[ "${1:-}" == "--pkg" ]]; then
    build_installer_package
else
    echo "Built ${APP_DIR}"
fi
