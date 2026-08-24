# 0.1.6

## Fixed

- The host app and WidgetKit extension now share one explicit persistent App Entity identifier, allowing WidgetKit to restore the camera selected in **Edit Widget** instead of resolving it to `nil`.
- Camera photographs use full-color widget rendering so macOS 26 accented mode no longer collapses frames into a uniform black or white field.
- Installer upgrades terminate stale widget-extension processes so macOS loads the newly installed extension binary immediately.

## Verification

- Added an end-to-end widget smoke test that reads the real camera catalog, selects a camera with an existing Nest snapshot, round-trips the App Entity identifier, builds the actual timeline entry, and renders the actual widget view.
- The test rejects image-less and uniform renders and writes `build/widget-e2e-smoke.png` for visual inspection.
- Release builds verify matching App Intents metadata in both the host app and widget extension.

## Requirements And Limitations

- Requires macOS 26 on Apple Silicon, supported Google Nest cameras, Google Device Access, and FFmpeg.
- Keep the companion app running for authenticated snapshot capture. WidgetKit controls timeline scheduling and may throttle requested refreshes.
- This development package is ad-hoc signed and not notarized; the installer package itself is unsigned.
- Personal OAuth credentials and tokens are never included in the package.
