# 0.1.4

## Fixed

- Camera snapshots now opt into full-color rendering in macOS 26 accented widgets instead of appearing as solid white rectangles.
- Snapshot PNG data is eagerly decoded into stable bitmap content before WidgetKit renders the timeline entry.
- Widget snapshot loading now records useful decode and file-access diagnostics in the system log.

## Requirements And Limitations

- Requires macOS 26 on Apple Silicon, supported Google Nest cameras, Google Device Access, and FFmpeg.
- Keep the companion app running for authenticated snapshot capture. WidgetKit controls timeline scheduling and may throttle requested refreshes.
- This development package is ad-hoc signed and not notarized; the installer package itself is unsigned.
- Personal OAuth credentials and tokens are never included in the package.
