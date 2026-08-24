#!/usr/bin/env bash
set -euo pipefail

BRIDGE_URL="http://127.0.0.1:11984"
SOURCE_URL="http://127.0.0.1:11985"
OBS_EXTENSION="/Applications/OBS.app/Contents/Library/SystemExtensions/com.obsproject.obs-studio.mac-camera-extension.systemextension"

for candidate in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg /usr/bin/ffmpeg; do
    if [[ -x "${candidate}" ]]; then
        FFMPEG="${candidate}"
        break
    fi
done

if [[ -z "${FFMPEG:-}" ]]; then
    echo "FFmpeg is required for the broadcast smoke test." >&2
    exit 1
fi

source_json="$(curl --fail --silent --show-error --max-time 5 "${SOURCE_URL}/source")"
source_id="$(printf '%s' "${source_json}" | plutil -extract sourceId raw -o - -- -)"
if [[ ! "${source_id}" =~ ^camera_[0-9a-f]{16}$ ]]; then
    echo "Broadcast Bridge has no selected camera source. Select a camera in the app first." >&2
    exit 1
fi

curl --fail --silent --show-error --max-time 5 "${SOURCE_URL}/" | grep -q '/source'
curl --fail --silent --show-error --max-time 5 "${SOURCE_URL}/health" | grep -q '^ok$'

frame_file="$(mktemp -t camera-widget-broadcast).jpg"
trap 'rm -f "${frame_file}"' EXIT
curl --fail --silent --show-error --max-time 30 \
    "${BRIDGE_URL}/api/frame.jpeg?src=${source_id}&w=1280" \
    -o "${frame_file}"
sips -g pixelWidth -g pixelHeight "${frame_file}"

progress_file="$(mktemp -t camera-widget-ffmpeg-progress)"
trap 'rm -f "${frame_file}" "${progress_file}"' EXIT
"${FFMPEG}" -hide_banner -loglevel error -rw_timeout 30000000 \
    -i "${BRIDGE_URL}/api/stream.ts?src=${source_id}" \
    -map 0:v:0 -frames:v 30 -f null - \
    -progress "${progress_file}" -nostats

decoded_frames="$(awk -F= '/^frame=/{value=$2} END{print value+0}' "${progress_file}")"
if [[ "${decoded_frames}" -lt 30 ]]; then
    echo "FFmpeg decoded only ${decoded_frames} of 30 required camera frames." >&2
    exit 1
fi

test -d "${OBS_EXTENSION}"
codesign --verify --deep --strict "${OBS_EXTENSION}"

echo "Broadcast smoke test passed: local page, live JPEG, 30 decoded MPEG-TS frames, and signed OBS camera extension."
