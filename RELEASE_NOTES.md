# 0.2.1

Google Home Camera Widget for macOS provides three coordinated camera surfaces: a live Nest camera viewer, independently configurable desktop snapshot widgets, and an OBS broadcast bridge for conferencing and streaming.

## Nest Camera Viewer

- Discovers authorized Google Nest cameras across multiple homes and groups them by home and room.
- Filters selection to devices that report RTSP or WebRTC live-stream support.
- Remembers the last selected camera while still waiting for an explicit selection on first use.
- Uses native AVKit for RTSP cameras and the bundled go2rtc bridge for Google Nest WebRTC cameras.
- Replaces the slow JPEG/MJPEG preview path with the same full-motion WebRTC renderer used by the OBS source.
- Detects the first decoded frame, reports measured frame rate, retries WebRTC once after a failed start, and retains JPEG as an automatic compatibility fallback.
- Keeps camera switching, refresh, and floating viewer controls available while streams load.
- Prioritizes the foreground camera when warming local sources so a selected camera can appear sooner.
- Opens the exact camera selected on a desktop widget instead of returning to the last-used app section or another camera.

## Desktop Snapshot Widgets

- Registers a native WidgetKit extension with the standard macOS widget gallery.
- Supports one independently selected Nest camera per widget instance through **Edit Widget**.
- Populates the camera picker dynamically from the authenticated app's discovered camera catalog.
- Persists the Google camera resource ID directly, fixing unresolved and empty widget configurations.
- Captures stable per-camera snapshots through a serialized background scheduler with a target 60-second capture cycle while the companion app runs.
- Requests a WidgetKit timeline reload after successful captures and after configuration changes.
- Displays real camera photographs in full color in macOS accented rendering mode.
- Scales every frame to fit without cropping, using black letterboxing when the camera and widget aspect ratios differ.
- Places only the camera name and capture time in a compact footer below the image so metadata never covers the frame.
- Fixes the blank white widget surface caused by missing App Intent metadata, duplicate entity definitions, and image rendering behavior.

## OBS And Conferencing

- Adds a dedicated Broadcast Bridge with independent camera selection.
- Hosts a stable, credential-free OBS Browser Source at `http://127.0.0.1:11985/`.
- Updates an already configured OBS Browser Source when the selected camera changes, without changing its URL.
- Provides a direct MPEG-TS fallback URL for OBS Media Source.
- Verifies a real live frame before reporting the selected broadcast source ready.
- Opens a clean 16:9 output window and keeps it synchronized with Broadcast Bridge camera changes.
- Includes controls to launch OBS and copy source URLs without exposing Google credentials.
- Supports Microsoft Teams, Zoom, and other camera clients through OBS Studio's signed OBS Virtual Camera extension.
- Leaves audio to a separately selected microphone; camera audio is not included in this release.

## Installation And Security

- Installs the app into `/Applications` and registers its embedded WidgetKit extension with LaunchServices and PlugInKit.
- Checks macOS version, Apple Silicon architecture, the bundled go2rtc helper, Homebrew availability, and FFmpeg.
- Installs FFmpeg through an existing Homebrew installation when FFmpeg is missing; it does not bootstrap a package manager without separate user consent.
- Bundles the patched arm64 go2rtc helper used for Nest WebRTC negotiation and local media transports.
- Keeps OAuth client configuration out of the installer and stores OAuth tokens in macOS Keychain.
- Supports Google Partner Connections Manager authorization and the Smart Device Management API `sdm.service` scope.

## Verification

- Adds a real-camera smoke path that discovers an authorized streamable Nest camera, requests a Google live-stream session, and requires actual decoded media.
- Adds a headless WebKit/go2rtc test that requires advancing video and reports its measured offscreen frame rate.
- Adds a broadcast smoke test that validates the stable Browser Source, receives a real JPEG, decodes 30 MPEG-TS frames, and verifies the signed OBS camera extension.
- Adds an end-to-end widget smoke test covering dynamic camera labels, persisted camera IDs, timeline creation, real snapshot loading, and nonuniform accented-mode rendering.
- Verifies with a synthetic 16:9 frame that widgets preserve the entire image instead of cropping it.
- Release builds verify that generated App Intents metadata contains the dynamic primitive camera selector and no obsolete camera entities.
- Includes a documented OBS, Microsoft Teams, and Zoom acceptance plan in `BROADCAST_TEST_PLAN.md`.

## Requirements And Limitations

- Requires macOS 26 or newer on Apple Silicon.
- Requires a Google Device Access project, a Google Cloud OAuth client, the enabled Smart Device Management API, and supported Nest cameras authorized through Partner Connections Manager.
- Requires FFmpeg. Homebrew is required only when the installer must provision FFmpeg.
- OBS Studio 30 or newer is required for OBS Virtual Camera output to Teams, Zoom, and similar clients.
- Keep the companion app running for authenticated snapshot capture. The scheduler targets a new per-camera capture cycle every 60 seconds, but WidgetKit controls display scheduling and may throttle reload requests.
- Existing widgets using the retired entity-based configuration should be edited once after upgrading to select and persist their camera again; deleting and recreating them should not be necessary.
- Hidden WebKit views may be throttled by macOS, so visible app and OBS playback are the frame-rate acceptance paths.
- This development package is ad-hoc signed and not notarized; the installer package itself is unsigned.
- Personal OAuth credentials and tokens are never included in the package.
