# 0.1.3

This is the first packaged development release of Google Home Camera Widget for macOS 26 on Apple Silicon.

## Included

- Nest Camera Viewer with Google OAuth and Device Access camera discovery.
- A compact, single-camera viewer with remembered camera selection and camera deep links.
- A configurable WidgetKit desktop widget. Each widget can select its own camera and displays that camera's latest captured frame.
- Per-camera snapshot scheduling with first-frame retries for cameras that need extra time to start.
- A clean broadcast window suitable for capture in OBS and other streaming software.
- A macOS installer that registers the embedded widget extension and checks the required runtime tools.

## Fixes In This Release

- Fixed camera switching so selecting a camera no longer stops its newly created renderer.
- Fixed widget camera discovery and App Intent selection.
- Fixed widget-to-viewer deep links so clicking a widget opens its selected camera.
- Added retry handling when a camera does not produce its first widget frame within the initial capture window.
- Added explicit FFmpeg discovery and installer dependency checks.
- Prevented Device Access pagination requests that the API does not support for this enterprise.

## Requirements

- macOS 26 on Apple Silicon.
- A Google account with supported Nest cameras.
- A Google Cloud project with the Smart Device Management API enabled.
- A Google Device Access project and its one-time registration fee.
- OAuth desktop-app credentials and an approved OAuth test user while the Google app remains in testing.
- FFmpeg. The installer uses an existing Homebrew installation to install FFmpeg when it is missing.

## Current Limitations

- This package is ad-hoc signed for development and is not notarized. The installer package itself is unsigned.
- Keep the companion app running for authenticated snapshot capture. WidgetKit controls timeline scheduling and may throttle requested refreshes.
- The current viewer uses bridge-generated frames rather than a native high-frame-rate player. Audio is not exposed.
- The broadcast window is intended for window capture. A native Teams, Zoom, or OBS camera device still requires a signed Core Media I/O Camera Extension.
- Personal OAuth credentials and tokens are never included in the release package.

Install the attached package manually, then open `/Applications/GoogleHomeCameraWidget.app` and complete Google sign-in. The `.sha256` attachment can be used to verify the installer before opening it.
