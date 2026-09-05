# Measuring latency and resource use

Performance depends on the USB link, capture size and rate, desktop workload,
codec, and Mac display. Measure on the target hardware; no device-specific
benchmark results are included in this repository.

## What the counters mean

- USB payload-read time measures receipt of a frame payload on the host.
- Deck queue time starts after FFmpeg supplies a complete frame. It excludes
  capture, conversion, and encoding.
- Mac receive-to-submit time includes decoding and GPU submission.
- Mac receive-to-display time includes decoding and presentation. Hidden windows
  may not produce valid presentation samples.
- Decode time includes hardware decoding and the copy into the NV12 renderer.
- Control RTT is a message round trip, not input-to-photon latency.
- Audio buffering excludes the output device's own delay.

These counters overlap. Do not add decode time to receive-to-display, or subtract
Deck timestamps from Mac timestamps. A full input-to-photon measurement needs an
external observation of input and the resulting screen change.

## Compare one change at a time

Keep the game scene, resolution, frame rate, window state, display refresh rate,
and power settings fixed when comparing implementations. Exclude startup and
codec initialization. Record throughput, drops, audio gaps, presentation timing,
and CPU time over the same interval. Distinguish one-core CPU percentages from
aggregate machine capacity; neither directly predicts game-FPS loss.

Compare capture enabled and disabled in the same scene to estimate its impact.
GPU and power sensors are shared with other work and cannot alone identify the
sender's incremental cost. Record memory as well as CPU: a codec can reduce USB
traffic while increasing memory and hardware-engine use.

A higher capture rate reduces time between capture opportunities but uses more
resources. Raw NV12 requires width × height × 1.5 × fps bytes per second, plus
audio and framing. H.264 traffic depends on the scene and quality setting.
Use the cable test instead of assuming advertised USB speed is achievable.

Keep display sync enabled if tearing is unacceptable. Test serial USB reads or
display-linked rendering only as controlled comparisons, and keep a change only
when the relevant measurements improve without unacceptable regressions.
