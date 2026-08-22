# Roadmap

## Track 1: Companion Floating Camera Viewer

Purpose: a launchable macOS app for credentialed live-stream testing and always-on desktop viewing.

Status:

- Google OAuth through Partner Connections Manager.
- Tokens stored in macOS Keychain.
- Device Access camera discovery.
- RTSP stream request and AVKit playback attempt.
- WebRTC stream request and embedded WebKit playback attempt.
- Compact floating window mode.
- Writes per-camera live-view snapshots and metadata every 60 seconds for the camera currently open in the viewer.
- Local `.app` installer through `build.sh --install`.

Remaining:

- Validate RTSP and WebRTC behavior against real Google Nest cameras.
- Add clearer per-camera diagnostics after the first live-device test.
- Add stream stop/cleanup commands for RTSP sessions.
- Add signed/notarized release packaging if the app will be shared outside local development.

## Track 2: WidgetKit Camera Widget

Purpose: the original product goal: a real macOS widget experience for Google Nest camera viewing.

Status:

- Product goal retained.
- Feasibility constraints identified: WidgetKit renders timeline entries in a separate process and widgets are not continuously active while onscreen.

Remaining:

- WidgetKit snapshot extension target.
- Each widget instance can select one discovered camera.
- Widget reads the latest saved per-camera snapshot and timestamp.
- Determine whether macOS WidgetKit can host continuous WebRTC/RTSP playback in practice.
- Add an app group for sharing state if signing/sandboxing requires it.
- If continuous playback is blocked by WidgetKit, implement the best viable widget behavior: selected-camera tile, latest safe preview state, status, and a direct handoff into the companion viewer for live video.
