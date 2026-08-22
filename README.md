# Google Home Camera Widget for macOS

Native macOS apps and companion capabilities for viewing and sharing Google Nest cameras through Google's Device Access / Smart Device Management API:

- **Nest Camera Viewer**: a launchable SwiftUI camera wall for live feeds across homes.
- **Nest Camera Snapshot Widget**: a configurable WidgetKit widget where each widget instance can show a different camera's latest snapshot.
- **Nest Broadcast Bridge**: a selected-camera broadcast surface for stream/conference workflows.

The viewer app handles Google OAuth through Partner Connections Manager, stores tokens in macOS Keychain, discovers authorized SDM cameras across homes, and presents a focused single-camera live viewer. It requests RTSP streams for cameras that report RTSP support and attempts WebRTC playback for cameras that report WebRTC support.

The widget app is a configurable snapshot surface. After the viewer discovers cameras, the widget exposes those cameras as choices. You can add one widget per camera. While the viewer app is running, an independent scheduler keeps per-camera snapshot files fresh on a 60-second cadence for the widgets.

The broadcast bridge lets you select any discovered camera and open a clean 16:9 output window for OBS capture today. Native appearance as a Teams/Zoom camera device requires a signed macOS Core Media I/O Camera Extension, which is tracked separately because Apple packages virtual cameras as system extensions with signing and entitlement requirements.

## Status

- Google Partner Connections Manager OAuth: implemented
- SDM camera discovery: implemented
- Single streamable-camera live viewer: implemented
- Multi-home, multi-camera feed wall: planned after live single-camera playback is stable
- Home and room grouping/filtering for camera lists: planned after live single-camera playback is stable
- Click-to-zoom single feed view: planned after live single-camera playback is stable
- RTSP stream command: implemented
- RTSP playback attempt with AVKit: implemented
- WebRTC stream command and embedded playback attempt with WebKit: implemented
- Compact floating viewer mode: implemented
- WidgetKit snapshot widget with per-widget camera configuration: implemented
- Per-camera snapshot files for widget instances: implemented
- Independent stream snapshot scheduler every 60 seconds per discovered camera: implemented
- Broadcast Bridge selected-camera output window for OBS/window capture: implemented
- Native Core Media I/O virtual camera device for Teams/Zoom camera menus: planned
- Packaged macOS `.app`: local build script support
- Distributed signed/notarized release: not implemented
- Continuous in-widget live video feasibility work: pending

## Requirements

- macOS 26 or newer
- Xcode or Apple Command Line Tools
- A consumer Google Account that manages compatible Nest cameras
- Google Device Access registration and a Device Access project
- A Google Cloud OAuth client associated with that Device Access project
- Smart Device Management API enabled in Google Cloud

See [THIRD_PARTY.md](THIRD_PARTY.md) for required Google access, scopes, redirect URI, and software dependencies.

## Google Setup

1. Register for Google Device Access and create a Device Access project.
2. Create or select the Google Cloud project used by that Device Access project.
3. Enable the Smart Device Management API.
4. Configure the OAuth consent screen and include the SDM scope:

   ```text
   https://www.googleapis.com/auth/sdm.service
   ```

5. Create an OAuth client and add this redirect URI:

   ```text
   http://127.0.0.1:53682/oauth2callback
   ```

6. Add your Google Account as a test user if the OAuth app is still in testing.
7. In Partner Connections Manager during sign-in, grant the project access to the cameras you want to view.

Google's Device Access docs describe the required Partner Connections Manager flow and note that the SDM API uses the `sdm.service` scope. Google's camera live stream docs state that camera sessions are short-lived and that WebRTC streams require a valid SDP offer, a returned SDP answer, and a client that applies that answer promptly.

## Local Configuration

Copy the example config and fill in your personal values:

```bash
cp Config/oauth2.example.json Config/oauth2.local.json
```

`Config/oauth2.local.json` is ignored by git. It should look like this:

```json
{
  "clientId": "YOUR_GOOGLE_OAUTH_CLIENT_ID.apps.googleusercontent.com",
  "clientSecret": "YOUR_GOOGLE_OAUTH_CLIENT_SECRET_IF_REQUIRED",
  "deviceAccessProjectId": "YOUR_GOOGLE_DEVICE_ACCESS_PROJECT_ID",
  "usePKCE": false
}
```

For a Google OAuth Web application client with a client secret, leave `usePKCE` as `false`. Set it to `true` only if you intentionally created a public/native OAuth client that expects PKCE.

You can also use environment variables:

```bash
export GOOGLE_CLIENT_ID="..."
export GOOGLE_CLIENT_SECRET="..."
export GOOGLE_DEVICE_ACCESS_PROJECT_ID="..."
export GOOGLE_OAUTH_USE_PKCE="false"
```

## Build and Run

From the repo root:

```bash
swift build
swift run GoogleHomeCameraWidget
```

Run automated smoke checks:

```bash
scripts/integration_smoke.sh
```

The smoke script builds the app, verifies streamable-camera selection rules using mock camera data, and launches the app briefly with `CAMERA_WIDGET_USE_MOCK_CAMERAS=1` to catch immediate startup crashes without requiring Google credentials.

To build a local `.app` bundle:

```bash
./build.sh
open build/GoogleHomeCameraWidget.app
```

To install the local bundle into your user Applications folder:

```bash
./build.sh --install
open ~/Applications/GoogleHomeCameraWidget.app
```

To build a macOS installer package that installs the app into `/Applications` and registers the embedded WidgetKit extension with LaunchServices/PlugInKit:

```bash
./build.sh --pkg
sudo installer -pkg build/GoogleHomeCameraWidget-0.1.0.pkg -target /
open /Applications/GoogleHomeCameraWidget.app
```

The installer package does not include `Config/oauth2.local.json` or OAuth tokens. Keep local credentials in `~/Library/Application Support/GoogleHomeCameraWidget/oauth2.json`, which `./build.sh --install` can populate from your ignored local config during development.

See [RELEASE.md](RELEASE.md) for package verification and GitHub release publishing.

## First Run

1. Confirm `Config/oauth2.local.json` exists and has your client ID and Device Access project ID.
2. Run `./build.sh --install` for local development, or install `build/GoogleHomeCameraWidget-0.1.0.pkg` for the system `/Applications` install that registers the desktop widget.
3. Open `~/Applications/GoogleHomeCameraWidget.app` or `/Applications/GoogleHomeCameraWidget.app`.
4. Click **Sign In with Google**.
5. Complete Google's Partner Connections Manager flow and grant camera access.
6. Verify the app lists real cameras.
7. Watch the all-feed wall grouped by home.
8. Click a feed to zoom into one camera.
9. Click **All Feeds** to return to the camera wall.
10. Toggle **Widget Mode** to keep the viewer as a compact floating camera window on the desktop.
11. Switch to **Broadcast Bridge**, select a camera, and open the clean broadcast feed window for OBS/window capture workflows.
12. Add the **Nest Camera Snapshot** widget from macOS widget editing.
13. Edit the widget and choose the camera for that widget instance. You can add one widget per camera.

## Apps

### Nest Camera Viewer

The viewer is the live monitoring app. It is intentionally independent from the widget snapshot surface.

- Shows one selected streamable camera at a time.
- Filters the picker to cameras that report RTSP or WebRTC support.
- Starts streaming immediately after selecting a camera.
- Keeps the video preview non-interactive while debugging click-related WebKit/AVKit crashes.

### Nest Camera Snapshot Widget

The widget is the configurable per-camera snapshot surface.

- Each widget instance chooses one camera.
- Widget camera choices come from the camera catalog written by the viewer app.
- Each widget displays the latest saved snapshot and timestamp for its selected camera.
- The viewer app runs an independent hidden snapshot worker for each discovered stream-capable camera.
- Each worker negotiates its own RTSP or WebRTC stream, captures a snapshot, writes that camera's snapshot file, and repeats on a 60-second cadence while the viewer app is running.
- The visible all-feed viewer is independent from the widget snapshot scheduler; changing zoom state in the viewer does not choose or limit which widget camera snapshots update.

Apple's WidgetKit renders widgets from timelines in a separate process, and widgets are not continually active while onscreen. The widget requests a timeline refresh after 60 seconds, but macOS may throttle refreshes because WidgetKit updates are system-managed and budgeted. Continuous in-widget WebRTC/RTSP playback still needs feasibility validation against macOS WidgetKit behavior.

### Nest Broadcast Bridge

The broadcast bridge is the selected-camera sharing surface.

- Selects any camera discovered by the authenticated viewer session.
- Opens a dedicated 16:9 output window titled for the selected camera.
- Uses the same live-feed negotiation as the viewer while staying independent from the viewer grid and widget snapshot workers.
- Provides an OBS-friendly capture surface immediately.
- Tracks native Teams/Zoom camera-menu support as a Core Media I/O Camera Extension, which requires a signed system extension host app and app-group communication.

## Security

- Credentials are not committed.
- `Config/oauth2.local.json` is for local use only and is ignored by git. Rotate its Google OAuth values if the file is ever copied into logs, screenshots, shared archives, or synced storage you do not fully control.
- Keep `Config/oauth2.example.json` as placeholders only.
- OAuth tokens are stored in macOS Keychain.
- Sign out deletes the stored Keychain token.
- Local OAuth callback listens on `127.0.0.1:53682` only during sign-in.

## Project Structure

```text
.
├── Config/
│   └── oauth2.example.json
├── Sources/
│   └── main.swift
├── LICENSE
├── Package.swift
├── README.md
├── THIRD_PARTY.md
└── build.sh
```

## License

MIT. See [LICENSE](LICENSE).
