#!/usr/bin/env bash
# Exercise session selection and complete capture command construction without
# a display, root, USB hardware, or installed GStreamer/FFmpeg.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "$0")/../scripts" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
export CAPTURE_CHECK_DIR=$scratch
export VAAPI_DEVICE=/dev/dri/test-render
mkdir "$scratch/scripts"
export XDG_RUNTIME_DIR=$scratch
export PATH="$scratch:$PATH"
touch "$scratch/authority"
cp "$source_dir/capture.sh" "$source_dir/hardware.sh" "$scratch/scripts/"
mkdir "$scratch/build"
cat > "$scratch/build/deck-capture" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_CHECK_DIR/capture-args"
result=${CAPTURE_CHECK_NATIVE_RESULT:-0}
if [[ $result == 0 ]]; then printf 'desktop'; fi
exit "$result"
EOF
chmod +x "$scratch/build/deck-capture"
cat > "$scratch/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *is-active* ]]; then [[ $CAPTURE_CHECK_MODE == gamescope ]]; exit; fi
printf 'DISPLAY=:8\nXAUTHORITY=%s/authority\n' "$CAPTURE_CHECK_DIR"
EOF
cat > "$scratch/xdpyinfo" <<'EOF'
#!/usr/bin/env bash
[[ $CAPTURE_CHECK_MODE == desktop ]]
EOF
cat > "$scratch/timeout" <<'EOF'
#!/usr/bin/env bash
shift; exec "$@"
EOF
cat > "$scratch/pw-dump" <<'EOF'
#!/usr/bin/env bash
printf 'stub\n'
EOF
cat > "$scratch/jq" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${CAPTURE_CHECK_SOURCES:-321}"
EOF
cat > "$scratch/gst-launch-1.0" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_CHECK_DIR/gst-args"
printf 'frame'
EOF
cat > "$scratch/ffmpeg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CAPTURE_CHECK_DIR/ffmpeg-args"
if [[ $CAPTURE_CHECK_MODE == gamescope ]]; then cat; else printf 'desktop'; fi
EOF
cat > "$scratch/python3" <<'EOF'
#!/usr/bin/env bash
# The display wrapper has its own restoration check; forward the capture here.
shift 3; exec "$@"
EOF
chmod +x "$scratch/"{systemctl,xdpyinfo,timeout,pw-dump,jq,gst-launch-1.0,ffmpeg,python3}
export CAPTURE_CHECK_MODE=desktop
[[ $(bash "$scratch/scripts/capture.sh" --probe) == "desktop::8:$scratch/authority" ]]
[[ $(bash "$scratch/scripts/capture.sh" 1280 800 90 nv12 /dev/null) == desktop ]]
[[ $(cat "$scratch/capture-args") == $'1280\n800\n90' ]]
[[ ! -e $scratch/ffmpeg-args ]]
result=0
CAPTURE_CHECK_NATIVE_RESULT=1 bash "$scratch/scripts/capture.sh" 1280 800 90 nv12 /dev/null >/dev/null 2>&1 || result=$?
[[ $result == 1 && ! -e $scratch/ffmpeg-args ]]
[[ $(CAPTURE_CHECK_NATIVE_RESULT=75 bash "$scratch/scripts/capture.sh" 1280 800 90 nv12 /dev/null) == desktop ]]
[[ $(cat "$scratch/ffmpeg-args") == *format=nv12* && $(cat "$scratch/ffmpeg-args") != *vaapi* ]]
[[ $(DECKUSB_SOFTWARE_CONVERSION=1 bash "$scratch/scripts/capture.sh" 1280 800 90 nv12 /dev/null) == desktop ]]
chmod -x "$scratch/build/deck-capture"
[[ $(bash "$scratch/scripts/capture.sh" 1280 800 90 nv12 /dev/null) == desktop ]]
[[ $(cat "$scratch/ffmpeg-args") == *format=nv12* && $(cat "$scratch/ffmpeg-args") == *direct* ]]
export CAPTURE_CHECK_MODE=gamescope
[[ $(bash "$scratch/scripts/capture.sh" --probe) == gamescope:321 ]]
[[ $(bash "$scratch/scripts/capture.sh" 802 500 90 h264 "$scratch/sizes") == frame ]]
[[ $(cat "$scratch/gst-args") == *target-object=321* && $(cat "$scratch/gst-args") == *max-size-buffers=1* ]]
[[ $(cat "$scratch/ffmpeg-args") == *bgr0* && $(cat "$scratch/ffmpeg-args") == *h264_vaapi* && $(cat "$scratch/ffmpeg-args") != *x11grab* ]]
result=0
CAPTURE_CHECK_SOURCES=$'321\n322' bash "$scratch/scripts/capture.sh" --probe >/dev/null 2>&1 || result=$?
[[ $result == 75 ]]
result=0
CAPTURE_CHECK_MODE=absent bash "$scratch/scripts/capture.sh" --probe >/dev/null 2>&1 || result=$?
[[ $result == 75 ]]
if bash "$scratch/scripts/capture.sh" 803 500 90 h264 /dev/null >/dev/null 2>&1; then exit 1; fi
echo 'Capture session selection and command paths: PASS'
