#!/usr/bin/env bash
# Runs as the logged-in user. Probe selects the active session; capture writes
# tightly packed video to stdout and H.264 packet sizes to the supplied FIFO.
set -euo pipefail
source "$(dirname -- "$0")/hardware.sh"
session_env=$(systemctl --user show-environment)
display=$(sed -n 's/^DISPLAY=//p' <<< "$session_env")
authority=$(sed -n 's/^XAUTHORITY=//p' <<< "$session_env")
if systemctl --user is-active --quiet gamescope-session.service; then
    # Serial numbers avoid capturing a recycled PipeWire node ID. Refuse an
    # ambiguous source instead of silently capturing a nested game compositor.
    sources=$(timeout 3 pw-dump | jq -r '.[] | select(.type == "PipeWire:Interface:Node" and .info.props["node.name"] == "gamescope" and .info.props["media.class"] == "Video/Source") | .info.props["object.serial"]')
    [[ $sources =~ ^[0-9]+$ ]] || { echo 'Waiting for the Gaming Mode capture source.' >&2; exit 75; }
    session="gamescope:$sources"
else
    [[ -n $display && -f $authority ]] && timeout 2 env DISPLAY="$display" XAUTHORITY="$authority" xdpyinfo >/dev/null 2>&1 || {
        echo 'Waiting for a display session.' >&2; exit 75;
    }
    session="desktop:$display:$authority"
fi
if [[ ${1:-} == --probe ]]; then printf '%s\n' "$session"; exit; fi
[[ $# == 5 || $# == 6 ]] || { echo 'Usage: capture.sh WIDTH HEIGHT FPS FORMAT PACKET_FIFO [QUALITY]' >&2; exit 2; }
width=$1 height=$2 fps=$3 format=$4 packet_sizes=$5 quality=${6:-20}
[[ $quality == 20 || $quality == 24 || $quality == 28 ]] || exit 2
for number in "$width" "$height" "$fps"; do [[ $number =~ ^[1-9][0-9]*$ ]] || exit 2; done
[[ $width -ge 2 && $width -le 1920 && $((width % 2)) == 0 && $height -ge 2 && $height -le 1200 && $((height % 2)) == 0 && $fps -le 240 ]] || exit 2
[[ $format == nv12 || $format == bgra || $format == h264 ]] || exit 2
ffmpeg=(ffmpeg -hide_banner -loglevel warning -nostdin -fflags nobuffer)
pixel_format=$format
if [[ $format == h264 ]]; then
    pixel_format=nv12
    render_node=${VAAPI_DEVICE:-}
    if [[ -z $render_node ]]; then render_node=$(find_render_node); fi
    ffmpeg+=(-vaapi_device "$render_node")
fi
filter="scale=$width:$height:flags=fast_bilinear:out_color_matrix=bt709:out_range=tv,format=$pixel_format,setpts=N/($fps*TB)"
if [[ $format == h264 ]]; then
    # Independent IDR frames permit safe dropping. QP 20 preserves the existing
    # quality target; async_depth 1 avoids adding an encoder frame queue.
    encoder=(-map 0:v -vf "$filter,hwupload" -an -c:v h264_vaapi -qp "$quality"
        -g 1 -bf 0 -async_depth 1 -threads 1 -color_range tv -colorspace bt709
        -fps_mode passthrough -f tee "[f=framecrc:flush_packets=1]$packet_sizes|[f=h264:flush_packets=1]pipe:1")
else
    # Bypass AVIO's small staging writes; the capture pipe carries complete frames.
    encoder=(-vf "$filter" -an -c:v rawvideo -threads 1 -fps_mode passthrough -flush_packets 1 -avioflags direct -f rawvideo pipe:1)
fi
echo "Capturing $session at $width × $height, $fps fps ($format)." >&2
if [[ $session == gamescope:* ]]; then
    native="$(dirname -- "$0")/../build/deck-pipewire"
    if [[ $format == nv12 && -x $native && ${DECKUSB_GST_NATIVE:-1} == 1 ]]; then
        result=0
        "$native" "$sources" "$width" "$height" "$fps" || result=$?
        # Only startup/loader failures can fall back without mixing frame bytes.
        if [[ $result != 75 && $result != 126 && $result != 127 ]]; then exit "$result"; fi
        echo 'Native PipeWire capture is unavailable; using FFmpeg.' >&2
    fi
    # GStreamer is supplied by SteamOS. One leaky pending frame bounds capture
    # backlog. BGRx rows are always tightly packed, even for widths like 802;
    # NV12 from a generic fdsink can contain padding that raw FFmpeg cannot parse.
    gst-launch-1.0 -q pipewiresrc target-object="$sources" do-timestamp=true min-buffers=2 max-buffers=3 \
        ! video/x-raw,format=BGRx ! queue leaky=downstream max-size-buffers=1 max-size-bytes=0 max-size-time=0 \
        ! videoscale add-borders=false ! "video/x-raw,width=$width,height=$height" \
        ! videorate drop-only=true ! "video/x-raw,framerate=$fps/1" ! fdsink fd=1 sync=false \
        | "${ffmpeg[@]}" -probesize 32 -analyzeduration 0 -f rawvideo -pixel_format bgr0 \
            -video_size "${width}x${height}" -framerate "$fps" -i pipe:0 "${encoder[@]}"
else
    # The native path captures and converts in one process, without a GPU job
    # or an RGB pipe. Smaller/scaled or unsupported desktops use FFmpeg below.
    # Exit 75 is only emitted before pixels; failures after that restart framing.
    capture=(env DISPLAY="$display" XAUTHORITY="$authority" python3 "$(dirname -- "$0")/desktop-size.py" "$width" "$height")
    native="$(dirname -- "$0")/../build/deck-capture"
    if [[ $format == nv12 && -x $native && ${DECKUSB_SOFTWARE_CONVERSION:-0} != 1 ]]; then
        result=0
        "${capture[@]}" "$native" "$width" "$height" "$fps" || result=$?
        if [[ $result != 75 ]]; then exit "$result"; fi
        echo 'Native capture is unavailable for this desktop; using FFmpeg.' >&2
    fi
    capture+=("${ffmpeg[@]}" -probesize 32 -analyzeduration 0 -f x11grab -draw_mouse 0
        -framerate "$fps" -i "$display" "${encoder[@]}")
    exec "${capture[@]}"
fi
