# Release Management

This project ships local development builds and installer packages.

## Local Development Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh
```

This builds the real Xcode app and WidgetKit extension targets in `build/`. Use the installer package for desktop-widget testing: macOS App Intents services may reject extension discovery from a per-user `~/Applications` location.

## Installer Package

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build.sh --pkg
```

The package is written to:

```text
build/GoogleHomeCameraWidget-0.1.3.pkg
```

It installs `GoogleHomeCameraWidget.app` into `/Applications` and runs a postinstall script that registers the app and embedded WidgetKit extension.

The package preinstall script verifies macOS 26, Apple Silicon, and FFmpeg. When FFmpeg is absent and Homebrew is present, it installs the `ffmpeg` formula as the signed-in user. It fails with an actionable message when Homebrew is unavailable rather than silently bootstrapping a package manager.

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

The publish mode reads the current version from `build.sh`, creates and pushes its annotated tag if needed, then creates a GitHub release with the installer package attached.
