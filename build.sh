#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GoogleHomeCameraWidget"
EXTENSION_NAME="GoogleHomeCameraWidgetExtension"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="com.jeffalderson.google-home-camera-widget"
EXTENSION_BUNDLE_ID="${BUNDLE_ID}.snapshot-widget"
VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${BUNDLE_NAME}"
EXTENSION_DIR="${APP_DIR}/Contents/PlugIns/${EXTENSION_NAME}.appex"
XCODE_PROJECT="${SCRIPT_DIR}/CameraWidget.xcodeproj"
DERIVED_DATA="${BUILD_DIR}/DerivedData"

register_app() {
    local installed_app="$1"
    local installed_extension="${installed_app}/Contents/PlugIns/${EXTENSION_NAME}.appex"
    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    if [[ -x "${lsregister}" ]]; then
        "${lsregister}" -f "${installed_app}" >/dev/null 2>&1 || true
    fi

    if command -v pluginkit >/dev/null 2>&1 && [[ -d "${installed_extension}" ]]; then
        pluginkit -a "${installed_extension}" >/dev/null 2>&1 || true
        pluginkit -e use -i "${EXTENSION_BUNDLE_ID}" >/dev/null 2>&1 || true
    fi

    killall WidgetKitExtensionHost >/dev/null 2>&1 || true

    local registration
    registration="$(pluginkit -m -A -D -v -i "${EXTENSION_BUNDLE_ID}" 2>&1 || true)"
    if [[ "${registration}" != *"${EXTENSION_BUNDLE_ID}"* ]]; then
        echo "Widget extension registration failed for ${installed_extension}" >&2
        echo "${registration}" >&2
        return 1
    fi
}

install_local_config() {
    if [[ -f "${SCRIPT_DIR}/Config/oauth2.local.json" ]]; then
        mkdir -p "${HOME}/Library/Application Support/${APP_NAME}"
        cp "${SCRIPT_DIR}/Config/oauth2.local.json" "${HOME}/Library/Application Support/${APP_NAME}/oauth2.json"
        chmod 600 "${HOME}/Library/Application Support/${APP_NAME}/oauth2.json"
    fi
}

build_installer_package() {
    local package_root="${BUILD_DIR}/pkg-root"
    local package_scripts="${BUILD_DIR}/pkg-scripts"
    local package_path="${BUILD_DIR}/${APP_NAME}-${VERSION}.pkg"

    rm -rf "${package_root}" "${package_scripts}" "${package_path}"
    mkdir -p "${package_root}/Applications" "${package_scripts}"
    COPYFILE_DISABLE=1 ditto --norsrc "${APP_DIR}" "${package_root}/Applications/${BUNDLE_NAME}"
    xattr -cr "${package_root}" >/dev/null 2>&1 || true

    cat > "${package_scripts}/postinstall" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Applications/${BUNDLE_NAME}"
EXTENSION_PATH="\${APP_PATH}/Contents/PlugIns/${EXTENSION_NAME}.appex"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
CONSOLE_USER="\$(/usr/bin/stat -f '%Su' /dev/console)"

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

    COPYFILE_DISABLE=1 pkgbuild \
        --root "${package_root}" \
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
    mkdir -p "${HOME}/Applications"
    rm -rf "${HOME}/Applications/${BUNDLE_NAME}"
    cp -R "${APP_DIR}" "${HOME}/Applications/${BUNDLE_NAME}"
    install_local_config
    register_app "${HOME}/Applications/${BUNDLE_NAME}"
    echo "Installed ${HOME}/Applications/${BUNDLE_NAME}"
elif [[ "${1:-}" == "--pkg" ]]; then
    build_installer_package
else
    echo "Built ${APP_DIR}"
fi
