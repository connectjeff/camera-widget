# 0.2.0

## Fixed

- Added a stable, credential-free localhost Browser Source for OBS. Configure the URL once; selecting another camera in Broadcast Bridge updates the existing OBS source automatically.
- Added a direct MPEG-TS fallback, an in-app live-frame readiness check, and a credentialed smoke test that decodes 30 real camera frames.
- Added direct OBS launch and source-copy controls plus an end-to-end OBS, Microsoft Teams, and Zoom acceptance plan.
- Removed the home, room, and status overlays from camera frames. Widgets now reserve a compact footer below the uncropped image for only the camera name and capture time.
- Camera snapshots now scale to fit completely inside every widget family without cropping; black letterboxing preserves the camera's aspect ratio when needed.
- Refresh documentation now distinguishes the companion app's 60-second capture-cycle target from WidgetKit's system-managed display cadence.
- Replaced the camera `AppEntity` parameter with a primitive camera-ID string backed by a dynamic options provider. Friendly home, room, and camera names still appear in **Edit Widget**, while WidgetKit persists the selected Google camera resource ID directly.
- Removed the duplicate host-app intent and entity definitions that caused macOS to resolve configured cameras as `nil` and display the empty widget surface.
- Camera photographs continue to use full-color widget rendering so macOS 26 accented mode preserves the captured frame.

## Verification

- The end-to-end widget smoke test now verifies the primitive picker option, its friendly label, the persisted camera ID, the actual timeline entry, and the rendered real Nest frame.
- A synthetic 16:9 frame rendered into a square widget verifies that the complete frame remains visible with letterboxing instead of cropping.
- The test rejects image-less and uniform renders and writes `build/widget-e2e-smoke.png` for visual inspection.
- Release builds verify that extracted App Intents metadata contains a dynamically configured primitive string and no camera entities.

## Requirements And Limitations

- Existing widgets created with 0.1.6 store the retired entity-based configuration. After upgrading, use **Edit Widget** and select the camera once to save the new camera-ID configuration; deleting and recreating the widget should not be necessary.
- Requires macOS 26 on Apple Silicon, supported Google Nest cameras, Google Device Access, and FFmpeg.
- Keep the companion app running for authenticated snapshot capture. WidgetKit controls timeline scheduling and may throttle requested refreshes.
- This development package is ad-hoc signed and not notarized; the installer package itself is unsigned.
- Personal OAuth credentials and tokens are never included in the package.
