# Third-Party Software and Access

This repository is MIT licensed. It integrates with the third-party software and services listed below.

## Media Software

- [go2rtc](https://github.com/AlexxIT/go2rtc) `1.9.14+dev.c245815.dirty` provides the local Nest WebRTC bridge. An arm64 helper built from commit `c245815` with local Nest fixes is embedded in the app and distributed under go2rtc's MIT license.
- [FFmpeg](https://ffmpeg.org/) converts H.264 camera frames to JPEG/MJPEG for the viewer and WidgetKit snapshots. FFmpeg is not copied into the app package. The installer checks for it and runs the Homebrew `ffmpeg` formula installation when necessary. FFmpeg has its own LGPL/GPL licensing terms based on the formula's enabled components.
- [Homebrew](https://brew.sh/) is used by the installer to provision FFmpeg when it is missing. Homebrew is not bundled. The installer does not bootstrap Homebrew itself; installing a package manager is a separate system-level choice that requires explicit user action.

The runtime also uses macOS system libraries and frameworks supplied by Apple. It has no Swift Package Manager, npm, Python, or separately downloaded runtime-library dependencies.

## Apple Software

- macOS 26 or newer is required to run the app.
- Xcode 26, its macOS 26 SDK, and its Swift toolchain are required only to build it locally; they are not runtime dependencies of the installer package.
- The current packaged binaries target Apple Silicon (`arm64`).
- The app uses Apple frameworks supplied with macOS/Xcode: SwiftUI, WidgetKit, AVKit, CryptoKit, Network, WebKit, Foundation, AppKit, and Security.
- Native virtual-camera output for Teams/Zoom camera menus requires Apple's Core Media I/O Camera Extension and System Extensions capabilities, plus signing entitlements from an Apple Developer account.

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

## Broadcast and Conferencing Notes

The Broadcast Bridge currently provides a clean selected-camera output window suitable for OBS/window capture workflows. For a feed to appear directly in Microsoft Teams, Zoom, OBS, and other apps as a selectable camera device, macOS requires a Core Media I/O Camera Extension packaged with a signed host app.
