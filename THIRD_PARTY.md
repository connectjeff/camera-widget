# Third-Party Software and Access

This repository is MIT licensed and currently contains only first-party Swift source code.

## Apple Software

- macOS 26 or newer is required to run the app.
- Xcode or Apple Command Line Tools are required to build it locally.
- The app uses Apple frameworks supplied with macOS/Xcode: SwiftUI, WidgetKit, AVKit, CryptoKit, Network, WebKit, Foundation, AppKit, and Security.

## Google Access

The app does not include Google credentials. To test it with real cameras, you need:

- A consumer Google Account that manages compatible Google Nest cameras.
- Google Device Access registration.
- A Google Device Access project ID.
- A Google Cloud OAuth client associated with that Device Access project.
- The `https://www.googleapis.com/auth/sdm.service` OAuth scope.
- The redirect URI `http://127.0.0.1:53682/oauth2callback` configured for the OAuth client.
- The Smart Device Management API enabled for the Google Cloud project.

Google may charge a one-time Device Access registration fee and may impose API quotas, sandbox restrictions, verification requirements, and device compatibility limits. See Google's current Device Access and Smart Device Management documentation for authoritative terms and setup requirements.

## Camera Streaming Notes

Google Nest Device Access reports camera streaming support per device. Older devices may support RTSP, while many current Google Home managed cameras report WebRTC only. This app can request RTSP streams and attempts WebRTC playback through an embedded WebKit view that creates a receive-only SDP offer and applies Google's returned SDP answer. Live stream behavior still depends on Google's account, project, camera model, protocol support, quotas, and current API behavior.
