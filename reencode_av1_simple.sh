#!/usr/bin/env bash
set -euo pipefail

# Disable SVT-AV1 library info logs
export SVT_LOG=1

# Simple batch AV1 encoder (CPU only).
# Usage: ./simple_av1.sh video1 [video2 ...]
# Environment overrides:
#   MAX_DIM     – max size of the shorter side (default 720)
#   FPS_LIMIT   – max fps (default 45)
#   SVT_CRF     – SVT-AV1 CRF (default 32)
#   SVT_PRESET  – SVT-AV1 preset (default 6)
#   AUDIO_BR    – audio bitrate for AAC (default 128k)

MAX_DIM="${MAX_DIM:-720}"
FPS_LIMIT="${FPS_LIMIT:-45}"
SVT_CRF="${SVT_CRF:-32}"
SVT_PRESET="${SVT_PRESET:-6}"
AUDIO_BR="${AUDIO_BR:-128k}"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 video1 [video2 ...]"
    exit 1
fi

echo "Encoding with:"
echo "  libsvtav1  CRF=${SVT_CRF}, preset=${SVT_PRESET}"
echo "  Max short side = ${MAX_DIM}px, FPS limit = ${FPS_LIMIT}"
echo "  Audio: AAC ${AUDIO_BR}, pix_fmt yuv420p10le"
echo

for f in "$@"; do
    if [ ! -f "$f" ]; then
        echo "Skipping '$f' (not a regular file)"
        continue
    fi

    start=$SECONDS

    base="${f%.*}"
    out="${base}_av1_${MAX_DIM}px_${FPS_LIMIT}fps_p${SVT_PRESET}_crf${SVT_CRF}.mp4"

    # If width > height: height=MAX_DIM, width auto (-2); else width=MAX_DIM, height auto (-2).
    # This keeps aspect ratio and ensures even dimensions for 4:2:0.
    vf="scale='if(gt(iw,ih),-2,${MAX_DIM})':'if(gt(iw,ih),${MAX_DIM},-2)',fps=${FPS_LIMIT}"

    echo ">>> '$f'"
    ffmpeg -hide_banner -loglevel error -y \
        -i "$f" \
        -vf "$vf" \
        -c:v libsvtav1 -preset "$SVT_PRESET" -crf "$SVT_CRF" \
        -pix_fmt yuv420p10le \
        -c:a aac -b:a "$AUDIO_BR" \
        -movflags +faststart \
        "$out"

    elapsed=$((SECONDS - start))
    echo "New file '$out' processed in ${elapsed} seconds."
    echo
done
