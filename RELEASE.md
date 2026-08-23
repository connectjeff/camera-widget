# Release Management

This project ships local development builds and installer packages.

## Local Development Install

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh --install
open ~/Applications/GoogleHomeCameraWidget.app
```

This builds the real Xcode app and WidgetKit extension targets, installs into `~/Applications`, copies ignored local OAuth config into the user's Application Support directory, and verifies LaunchServices/PlugInKit registration for the widget extension.

## Installer Package

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh --pkg
```

The package is written to:

```text
build/GoogleHomeCameraWidget-0.1.0.pkg
```

It installs `GoogleHomeCameraWidget.app` into `/Applications` and runs a postinstall script that registers the app and embedded WidgetKit extension.

The package contains Xcode-generated App Intents metadata required for the standard **Edit Widget** camera picker. The current local package is ad-hoc signed and is intended for this Mac. A public release should use a Developer ID signature, notarization, and a provisioned App Group.

The package intentionally does not include `Config/oauth2.local.json`, Keychain tokens, or other personal credentials.

## Release Script

After committing changes:

```bash
scripts/release.sh
```

The script builds the installer package and verifies that the payload contains both:

- `/Applications/GoogleHomeCameraWidget.app`
- `/Applications/GoogleHomeCameraWidget.app/Contents/PlugIns/GoogleHomeCameraWidgetExtension.appex`

To publish a GitHub release with the `.pkg` attached:

```bash
scripts/release.sh --publish
```

The publish mode creates and pushes an annotated `v0.1.0` tag if it does not already exist, then creates a GitHub release with the installer package attached.
