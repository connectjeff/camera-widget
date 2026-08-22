# Google Home Camera Widget for macOS

A native SwiftUI macOS app for testing Google Nest camera access through Google's Device Access / Smart Device Management API.

The design goal is a macOS widget that can show Google Nest camera video. This repo now has two product tracks:

- A companion floating camera viewer app for credentialed live-stream testing and always-on desktop viewing.
- A real WidgetKit widget target that remains the primary widget experience to build next.

The current SwiftUI app is the companion viewer and live-stream harness. It supports Google OAuth through Partner Connections Manager, stores tokens in macOS Keychain, lists authorized SDM cameras, requests RTSP streams for cameras that report RTSP support, and attempts WebRTC playback for cameras that report WebRTC support. It includes a compact floating mode for desktop viewing while the WidgetKit target is built out.

## Status

- Google Partner Connections Manager OAuth: implemented
- SDM camera discovery: implemented
- RTSP stream command: implemented
- RTSP playback attempt with AVKit: implemented
- WebRTC stream command and embedded playback attempt with WebKit: implemented
- Compact floating companion-viewer mode: implemented
- WidgetKit snapshot widget: implemented
- Companion app snapshot capture every 60 seconds: implemented
- Packaged macOS `.app`: local build script support
- Distributed signed/notarized release: not implemented
- Continuous in-widget live video feasibility work: pending

## Requirements

- macOS 12 or newer
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
7. In Partner Connections Manager during sign-in, grant the project access to the cameras you want to test.

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
  "deviceAccessProjectId": "YOUR_GOOGLE_DEVICE_ACCESS_PROJECT_ID"
}
```

You can also use environment variables:

```bash
export GOOGLE_CLIENT_ID="..."
export GOOGLE_CLIENT_SECRET="..."
export GOOGLE_DEVICE_ACCESS_PROJECT_ID="..."
```

## Build and Run

From the repo root:

```bash
swift build
swift run GoogleHomeCameraWidget
```

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

## First Credentialed Test Checklist

1. Confirm `Config/oauth2.local.json` exists and has your client ID and Device Access project ID.
2. Run `./build.sh --install`.
3. Open `~/Applications/GoogleHomeCameraWidget.app`.
4. Click **Sign In with Google**.
5. Complete Google's Partner Connections Manager flow and grant camera access.
6. Verify the app lists real cameras.
7. Select a camera.
8. If it reports `RTSP`, click **Start RTSP Stream**.
9. If it reports `WEB_RTC`, the embedded WebRTC view starts automatically and requests the stream from Google.
10. Toggle **Widget Mode** to keep the companion viewer as a compact floating camera window on the desktop while validating the live-stream path.
11. Add the **Nest Camera Snapshot** widget from macOS widget editing. It displays the latest snapshot written by the companion app.

## Widget Goal

The goal remains a real macOS widget experience for camera viewing. The companion app is useful on its own, but it is not a replacement for the widget.

Apple's WidgetKit renders widgets from timelines in a separate process, and widgets are not continually active while onscreen. The live video implementation therefore needs a dedicated WidgetKit design pass instead of assuming the companion app window can simply become a widget.

The implemented first widget architecture is:

- The main app handles Google OAuth, camera selection, token storage, and live stream negotiation.
- While running, the main app writes `latest-snapshot.png` and `latest-snapshot.json` to `~/Library/Application Support/GoogleHomeCameraWidget/` every 60 seconds.
- The WidgetKit extension displays the latest saved snapshot and timestamp.
- The WidgetKit extension requests a timeline refresh after 60 seconds. macOS may throttle this because WidgetKit refreshes are system-managed and budgeted.
- Continuous in-widget WebRTC/RTSP playback still needs feasibility testing against macOS WidgetKit behavior.

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
