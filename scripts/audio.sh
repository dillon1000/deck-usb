#!/usr/bin/env bash
set -euo pipefail
# Run as the desktop user. A temporary sink keeps Mac playback independent of
# speaker mute/volume. Restore routing on exit; never capture the microphone.
state="$XDG_RUNTIME_DIR/deckusb-audio.previous"
previous=$(pactl get-default-sink)
if [[ -f $state ]]; then previous=$(cat "$state"); fi
if [[ $previous == deckusb ]]; then previous=$(pactl list short sinks | awk '$2 != "deckusb" {print $2; exit}'); fi
printf '%s\n' "$previous" > "$state"
# Recover only our named sink after an interrupted setup. Duplicate sink names
# make monitor selection ambiguous, so remove stale instances before creating it.
while read -r id name args; do
    if [[ $name == module-null-sink && $args == sink_name=deckusb\ * ]]; then pactl unload-module "$id"; fi
done < <(pactl list short modules)
module=$(pactl load-module module-null-sink sink_name=deckusb rate=48000 channels=2 sink_properties=device.description=DeckUSB)
capture_pid=
cleanup() {
    trap - EXIT
    # runuser and the supervisor can both send TERM. Ignore the second signal
    # until routing is restored; the normal default action would abort cleanup.
    trap '' INT TERM HUP
    set +e
    if [[ -n $capture_pid ]]; then kill "$capture_pid" 2>/dev/null; wait "$capture_pid" 2>/dev/null; fi
    # Preserve a different output selected by the user while this session ran.
    if [[ $(pactl get-default-sink) == deckusb ]]; then pactl set-default-sink "$previous"; fi
    sink_id=$(pactl list short sinks | awk '$2 == "deckusb" {print $1}')
    while read -r id sink rest; do
        [[ $sink != "$sink_id" ]] || pactl move-sink-input "$id" "$previous" || true
    done < <(pactl list short sink-inputs)
    pactl unload-module "$module"
    rm -f "$state"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pactl set-default-sink deckusb
while read -r id rest; do pactl move-sink-input "$id" deckusb || true; done < <(pactl list short sink-inputs)
# Five milliseconds is the capture request, not a claim about hardware latency.
parec --device=deckusb.monitor --raw --format=s16le --rate=48000 --channels=2 \
    --latency-msec=5 --process-time-msec=5 --client-name=DeckUSB --stream-name='DeckUSB game audio' &
capture_pid=$!
wait "$capture_pid"
