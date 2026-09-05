# Measuring latency and resource use

Performance depends on the USB link, capture size and rate, desktop workload,
codec, and Mac display. Measure on the target hardware. The
[September 2026 OLED check](PERFORMANCE-2026-09-05.md) records one hardware
comparison and its limits.

## What the counters mean

- USB payload-read time measures receipt of a frame payload on the host.
- Deck queue time starts after the capture process supplies a complete frame. It excludes
  capture, conversion, and encoding.
- Mac receive-to-submit time includes decoding and GPU submission.
- Mac receive-to-display time includes decoding and presentation. Hidden windows
  may not produce valid presentation samples.
- Decode time includes hardware decoding and mapping its pixel buffer into
  Metal textures. Decoded NV12 planes are not copied into another frame buffer.
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

For per-frame Mac presentation timing, run the viewer with `--trace-present`
and save its stderr to a file. Keep the window visible while measuring, then
run `python3 scripts/measure-presentation.py LOG` for percentiles and frame
intervals. Trace output adds logging work, so use it only for measurements.

Keep **Prevent screen tearing** enabled in Display settings if tearing is
unacceptable. Its saved setting applies immediately. Test serial USB reads or
display-linked rendering only as controlled comparisons, and keep a change only
when the relevant measurements improve without unacceptable regressions.

## Compare Deck USB writes

Quit the Mac viewer before using the command line; only one process can claim
the video interface. With an updated Deck sender, select a mode over USB:

```sh
build/DeckUSB.app/Contents/MacOS/deck-usb --deck-writes async
build/DeckUSB.app/Contents/MacOS/deck-usb --bench 12
```

Wait for the device to reconnect between commands. A closed reader restarts
the sender to discard incomplete frames. If a command reaches the old session
during shutdown, wait for reconnection and retry it.

`serial` uses the original blocking 256 KiB writes. `large`, the default, uses
blocking 1 MiB writes. `async` keeps up to three 256 KiB requests in flight,
including the separate frame header. It waits for all requests before starting
another frame. None of these modes changes the host's framing or queues whole
frames for later transmission.

The selection is stored in `/run/deckusb-usb-writes.conf`; the installed service
saves it to `usb-writes.conf` when it stops. `DECKUSB_USB_WRITES` overrides these
files for manual tests. Keep `large` as a general fallback and compare `async`
on the actual USB controller and kernel before using it.
