# Broadcast Bridge Acceptance Test

This plan verifies the complete supported conference path:

```text
Google Nest camera -> Google SDM -> local go2rtc bridge -> OBS Browser Source
-> OBS Virtual Camera -> Microsoft Teams or Zoom
```

The app and OBS must remain open while Teams or Zoom uses the feed. OBS Virtual Camera carries video; select a normal microphone separately in the conference app.

## Prerequisites

- Install the current Google Home Camera Widget package in `/Applications`.
- Sign in and confirm the Camera Viewer can display frames from the intended camera.
- Install OBS Studio 30 or newer in `/Applications`.
- Install Microsoft Teams and Zoom for their respective checks.

## 1. Prepare And Validate The Nest Output

1. Open **Google Home Camera Widget**.
2. Open **Broadcast Bridge**.
3. Select one streamable Nest camera.
4. Wait for the status to read **Ready: received ... from ...**.
5. Run this command from the repository:

   ```bash
   scripts/broadcast_smoke.sh
   ```

Expected result: the test validates the local OBS page, receives a live JPEG, decodes 30 frames from the MPEG-TS transport, validates the signed OBS camera extension, and exits successfully.

## 2. Configure OBS Once

1. In Broadcast Bridge, click **Copy OBS Source**, then **Open OBS**.
2. In OBS, create or select a scene named **Nest Camera**.
3. In **Sources**, click **+**, choose **Browser**, and name it **Google Nest Camera**.
4. Leave **Local file** off and paste the copied URL.
5. Set **Width** to `1920`, **Height** to `1080`, and **FPS** to `30`.
6. Leave **Shutdown source when not visible** off.
7. Confirm the selected Nest camera appears in the OBS canvas without app controls or window chrome.
8. Select a different camera in Broadcast Bridge. Confirm the existing OBS source changes cameras without editing its URL.
9. Record 30 seconds in OBS and play the recording. Confirm motion continues throughout and the frame is correctly proportioned.

If the Browser Source cannot negotiate WebRTC, click **Copy MPEG-TS** in the app and use that URL as a non-local **Media Source** in OBS.

## 3. Activate OBS Virtual Camera

1. In the OBS **Controls** dock, click **Start Virtual Camera**.
2. If macOS blocks the camera extension, open **System Settings > General > Login Items & Extensions > Camera Extensions**, enable the OBS extension, authenticate, and restart OBS.
3. Start Virtual Camera again and leave it running.

Expected result: **OBS Virtual Camera** becomes available as a system camera.

## 4. Verify Microsoft Teams

1. Quit Zoom so it cannot hold the virtual camera during this check.
2. Open Teams **Settings > Devices**.
3. Select **OBS Virtual Camera** under **Camera**.
4. Confirm the Nest feed appears in the Teams preview.
5. Start a private test meeting and enable the camera.
6. Change the selected camera in Broadcast Bridge and confirm Teams follows the OBS output.

## 5. Verify Zoom

1. Leave OBS and OBS Virtual Camera running, then quit Teams.
2. Open Zoom **Settings > Video & effects > Camera**.
3. Select **OBS Virtual Camera**.
4. Confirm the Nest feed appears in the Zoom preview.
5. Start a private test meeting and enable the camera.
6. Change the selected camera in Broadcast Bridge and confirm Zoom follows the OBS output.

## Pass Criteria

- The automated broadcast smoke test passes against a real Nest stream.
- OBS shows continuous video from the selected camera.
- Camera changes propagate through the stable Browser Source URL.
- A 30-second OBS recording contains continuous, correctly proportioned video.
- OBS Virtual Camera is selectable and displays the Nest feed in both Teams and Zoom when tested separately.
- No Google credentials or tokens appear in the copied OBS URL.
