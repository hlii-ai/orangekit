#!/bin/bash
# Video → a frame sequence for scroll animation.
# Usage: extract-frames.sh <VIDEO_PATH> <OUTPUT_DIR> [TARGET_FPS=12]
# The prerequisites (FFmpeg · the video exists · 3–10 seconds long) are verified here — failures are immediate and specific.
set -u

VIDEO="${1:-}"; OUT="${2:-}"; FPS="${3:-12}"

command -v ffmpeg >/dev/null 2>&1 || { echo "FAIL FFmpeg not installed — brew install ffmpeg"; exit 2; }
command -v ffprobe >/dev/null 2>&1 || { echo "FAIL ffprobe not installed (it ships with the ffmpeg package)"; exit 2; }
[ -f "$VIDEO" ] || { echo "FAIL no such video: $VIDEO"; exit 2; }
case "$FPS" in ''|*[!0-9]*) echo "FAIL TARGET_FPS must be an integer: $FPS"; exit 2;; esac

DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null | cut -d. -f1)
case "$DUR" in ''|*[!0-9]*) DUR=0;; esac
if [ "$DUR" -lt 3 ] || [ "$DUR" -gt 10 ]; then
  echo "WARN outside the recommended 3-10 second length (${DUR}s) — the frame count may not suit the scroll UX"
fi

mkdir -p "$OUT" || { echo "FAIL could not create the output directory: $OUT"; exit 2; }

# WebP sequence — about 40% smaller than JPEG, which helps page load. Width capped at 1600 (a retina compromise)
ffmpeg -y -v error -i "$VIDEO" -vf "fps=${FPS},scale='min(1600,iw)':-2" \
  -c:v libwebp -quality 82 "$OUT/frame-%04d.webp" || { echo "FAIL ffmpeg extraction failed"; exit 2; }

N=$(ls "$OUT"/frame-*.webp 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$(du -sh "$OUT" 2>/dev/null | cut -f1)
echo "OK ${N} frames (${FPS}fps · ${TOTAL} total) → $OUT"
[ "$N" -gt 0 ] || { echo "FAIL 0 frames"; exit 2; }
echo "frameCount=${N}"
