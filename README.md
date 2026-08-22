# Google Home Camera Widget for macOS

A native SwiftUI macOS app for testing Google Nest camera access through Google's Device Access / Smart Device Management API.

The current app is a credentialed camera tester rather than a finished Notification Center widget. It supports Google OAuth through Partner Connections Manager, stores tokens in macOS Keychain, lists authorized SDM cameras, and can request an RTSP stream for cameras that report RTSP support. Many modern Google Home cameras report WebRTC only; native WebRTC playback is called out in the UI and remains the main missing piece before those cameras can show a live feed.

## Status

- Google Partner Connections Manager OAuth: implemented
- SDM camera discovery: implemented
- RTSP stream command: implemented
- RTSP playback attempt with AVKit: implemented
- WebRTC playback: not implemented
- Packaged macOS `.app`: local build script support
- Distributed signed/notarized release: not implemented

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

Google's Device Access docs describe the required Partner Connections Manager flow and note that the SDM API uses the `sdm.service` scope. Google's camera live stream docs state that camera sessions are short-lived and that WebRTC streams require a valid SDP offer plus a native WebRTC client.

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
9. If it reports `WEB_RTC` only, the app has successfully reached the current boundary; native WebRTC playback must be added before live video can render.

## Security

- Credentials are not committed.
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
