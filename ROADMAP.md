# Roadmap

## Track 1: Companion Floating Camera Viewer

Purpose: a launchable macOS app for focused live viewing and always-on desktop use.

Status:

- Google OAuth through Partner Connections Manager.
- Tokens stored in macOS Keychain.
- Device Access camera discovery.
- Streamable-camera selection across multiple homes with room labels.
- Focused single-camera live view that remembers the last selection.
- RTSP and WebRTC stream requests through the local go2rtc bridge.
- Full-motion go2rtc WebRTC rendering with visible connection progress, measured decoded-frame callbacks, recovery, and JPEG fallback.
- Compact floating window mode.
- Runs a serialized snapshot scheduler with stable per-camera bridge sources and a target 60-second cycle.
- System `/Applications` installer package through `build.sh --pkg`.

Remaining:

- Add stream stop/cleanup commands for RTSP sessions.
- Add throttling controls if Google API quotas are hit with many simultaneous cameras.
- Add signed/notarized release packaging if the app will be shared outside local development.

## Track 2: WidgetKit Camera Widget

Purpose: the original product goal: a real macOS widget experience for Google Nest camera viewing.

Status:

- Product goal retained.
- Feasibility constraints identified: WidgetKit renders timeline entries in a separate process and widgets are not continuously active while onscreen.
- WidgetKit snapshot extension target.
- Each widget instance can select one discovered camera.
- Widget reads the latest saved per-camera snapshot and timestamp.
- Xcode-generated App Intents metadata supports the standard macOS **Edit Widget** camera picker.
- Installer embeds and registers the sandboxed WidgetKit extension.
- Captured images scale to fit without cropping and show only the camera name and capture time below the frame.
- Clicking a configured widget opens the viewer for that camera.
- The companion scheduler targets a new snapshot every 60 seconds; WidgetKit controls when a refreshed timeline is displayed.

Remaining:

- Replace the local-build file access entitlement with a provisioned App Group for a signed distribution.

## Track 3: Broadcast / Virtual Camera Bridge

Purpose: expose a selected Google Nest camera feed to streaming and conferencing workflows.

Status:

- Broadcast Bridge mode in the main app.
- Selects a camera independently from the viewer zoom state and widget snapshot selection.
- Opens a clean 16:9 broadcast feed window for OBS window capture or conferencing screen-share workflows.
- Reuses RTSP/WebRTC stream negotiation from the viewer.
- Hosts one stable localhost Browser Source for OBS and switches its underlying camera without requiring OBS reconfiguration.
- Provides an MPEG-TS fallback and an automated credentialed transport test.
- Uses OBS Virtual Camera as the signed system-camera handoff to Teams and Zoom.

Optional future work:

- Build a first-party signed Core Media I/O Camera Extension to remove the OBS dependency.
- Add app-group shared state between the host app and camera extension.
- Add extension install/activation UI using System Extensions.
- Add frame delivery from the selected Nest feed into the Core Media I/O stream source.
