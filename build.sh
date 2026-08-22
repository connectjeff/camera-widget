#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GoogleHomeCameraWidget"
EXTENSION_NAME="GoogleHomeCameraWidgetExtension"
BUNDLE_NAME="${APP_NAME}.app"
BUNDLE_ID="com.jeffalderson.google-home-camera-widget"
EXTENSION_BUNDLE_ID="${BUNDLE_ID}.snapshot-widget"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_DIR="${BUILD_DIR}/${BUNDLE_NAME}"
EXTENSION_DIR="${APP_DIR}/Contents/PlugIns/${EXTENSION_NAME}.appex"
EXECUTABLE_PATH="${SCRIPT_DIR}/.build/release/${APP_NAME}"
EXTENSION_EXECUTABLE_PATH="${SCRIPT_DIR}/.build/release/${EXTENSION_NAME}"
APP_ICON_CATALOG="${SCRIPT_DIR}/Assets/AppIcon.xcassets"

cd "${SCRIPT_DIR}"

swift build -c release

rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources" "${EXTENSION_DIR}/Contents/MacOS"
cp "${EXECUTABLE_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "${EXTENSION_EXECUTABLE_PATH}" "${EXTENSION_DIR}/Contents/MacOS/${EXTENSION_NAME}"

if command -v xcrun >/dev/null 2>&1; then
    xcrun actool "${APP_ICON_CATALOG}" \
        --compile "${APP_DIR}/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 26.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "${BUILD_DIR}/assetcatalog-info.plist" >/dev/null
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Google Home Camera Widget</string>
    <key>CFBundleDisplayName</key>
    <string>Google Home Camera Widget</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

cat > "${EXTENSION_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${EXTENSION_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${EXTENSION_BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Nest Camera Snapshot Widget</string>
    <key>CFBundleDisplayName</key>
    <string>Nest Camera Snapshot</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "${EXTENSION_DIR}" >/dev/null 2>&1 || true
    codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true
fi

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "${HOME}/Applications"
    rm -rf "${HOME}/Applications/${BUNDLE_NAME}"
    cp -R "${APP_DIR}" "${HOME}/Applications/${BUNDLE_NAME}"
    if [[ -f "${SCRIPT_DIR}/Config/oauth2.local.json" ]]; then
        mkdir -p "${HOME}/Library/Application Support/${APP_NAME}"
        cp "${SCRIPT_DIR}/Config/oauth2.local.json" "${HOME}/Library/Application Support/${APP_NAME}/oauth2.json"
        chmod 600 "${HOME}/Library/Application Support/${APP_NAME}/oauth2.json"
    fi
    echo "Installed ${HOME}/Applications/${BUNDLE_NAME}"
else
    echo "Built ${APP_DIR}"
fi
