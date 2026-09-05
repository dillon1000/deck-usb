# OLED performance check — September 5, 2026

At 1920 × 1200 and 60 fps, asynchronous Deck USB writes reduced mean payload
receipt time by about 37% against the original writer. The isolated CPU color
conversion test improved by about 11%. These are measurements of two stages;
they do not establish the full input-to-photon improvement.

## USB comparison

Hardware: Steam Deck OLED, kernel
`6.11.11-valve29-1-neptune-611-g2dcfaf4df7ac`, and an Apple silicon Mac.
The link reported USB 3 at 10 Gbit/s or faster. All runs used live Desktop Mode
NV12 at 1920 × 1200, 60 fps, and the same new Mac receiver with pipelined reads.
The command-line receiver drained video and audio without displaying them.

Each successful run lasted 12 seconds. The order was serial, large, async,
async, large, serial. No LAN connection carried the measurements.

| Deck writer | Mean payload time, run 1 / run 2 | Control RTT p50, run 1 / run 2 | Control RTT p95, run 1 / run 2 |
| --- | --- | --- | --- |
| Serial, 256 KiB | 6.00 / 5.86 ms | 0.24 / 0.23 ms | 0.32 / 0.34 ms |
| Large, 1 MiB | 5.63 / 5.56 ms | 0.23 / 0.25 ms | 0.38 / 0.36 ms |
| Async, three requests | 3.71 / 3.76 ms | 0.26 / 0.22 ms | 0.38 / 0.37 ms |

The two-run mean fell from 5.93 to 3.735 ms: 2.195 ms, or 37.0%. Against the
large writer, the reduction was 1.86 ms, or 33.2%. Control RTT p95 increased
by at most 0.06 ms in these short runs. This favors async on this Deck, while
leaving the simpler large writer as the general fallback.

Successful runs reported 57.6–60.0 fps and 199.2–207.5 MB/s because their clocks
included initial capture startup. The subsequent visible raw session reached
60 fps and about 207.4 MB/s, with a mean payload time of about 3.75 ms. Its
capture-drop count stayed at 23 after startup. The first serial run included
109 frames discarded before receipt began; this is not a steady-state drop rate.

Some immediate reconnect attempts met a sender that was still shutting down.
These failed with connection, timeout, or overflow errors and were retried after
USB enumeration. They are excluded from the successful-run table. No transfer
failure occurred within a successful 12-second run. A concurrent GUI viewer
also blocked an early attempt by holding the same interface.

## CPU conversion and resource use

The conversion comparison ran on the Deck, compiled with GCC 14 at `-O3
-march=znver2`. Four source buffers kept the working set larger than L3 cache.
Each of six alternating old/new rounds ran 180 conversions. The outputs were
checked for byte equality before timing; vectorized loops remained in the build.

| Conversion size | Original median | Row-pair median | Reduction |
| --- | --- | --- | --- |
| 1280 × 800 | 1.367 ms | 1.207 ms | 11.7% |
| 1920 × 1200 | 2.961 ms | 2.634 ms | 11.1% |

Separate 20-second process samples at 1920 × 1200 measured:

| Process | Before | Updated, async |
| --- | --- | --- |
| Capture | 34.18% | 35.31% |
| USB sender | 20.04% | 20.26% |
| Audio capture | 1.08% | 1.23% |
| Combined share of eight logical CPUs | 6.91% | 7.10% |

The first three rows use 100% for one logical CPU. The updated processes used
about 35.2 MiB of combined resident memory. These samples support similar sender
CPU cost, not a measured reduction in total capture CPU use. Desktop activity,
clock rates, and shared GPU readings varied. No game-FPS or incremental GPU-cost
claim follows from this comparison. The raw desktop converter still runs on the
CPU and adds no GPU conversion job.

## Checks and limits

Mac and Linux checks passed, including malformed packets, USB completion
ordering and failures, input, adaptive audio, telemetry, pixel conversion,
capture selection, and shutdown. The hardware decoder check covered concurrent
receipt, stale decoded frames, recovery, and decoded-surface lifetime.

The native Gaming Mode helper passed actual Deck startup and synthetic frame
checks at 802 × 500. Tests covered padded rows and BT.709 limited-range output.
Live Gaming Mode capture was not benchmarked in this Desktop Mode session.

The viewer's H.264 quality controls were applied over USB to the live hardware
encoder. Independent IDR frames remain in use so stale frames can be discarded
without corrupting later frames. The 12, 15, and 20 ms audio floors passed drift
and waveform checks. A live 12 ms session recorded an interruption and increased
its target to 17 ms as designed; 20 ms remains the default.

A separate audio comparison used the same 10-second, 48 kHz stereo tone in
fresh visible sessions, with a 12 ms selected floor. Each received 2,001 signal
packets. The large writer added one underrun and six overflow trims; async
added one underrun and no trims. Async had already increased its target to
17 ms after a startup underrun before the tone, while large started at 12 ms.
That difference prevents a claim that async improved audio. The checks also
do not establish a glitch-free 12 ms floor. Both sessions used automatic
recovery; the Mac output callback was 512 frames, or 10.67 ms at 48 kHz.

The final viewer runs raw 1920 × 1200 at 60 fps with async writes and per-frame
trace logging off. Its saved audio and display-sync choices are preserved.
The service remained active with zero systemd restarts; deliberate stream
restarts for settings and viewer reconnects are separate from this counter.

Mac presentation timing varied with window and HUD activity, so it is not used
to claim an end-to-end improvement here.

## Review items retained or deferred

The update overlaps USB chunks and H.264 decoding, processes conversion rows
in pairs, removes the Gaming Mode RGB pipe through FFmpeg, reuses compressed
conversion storage, removes redundant render dispatch and idle command polling,
sets Mac worker QoS, and adds quality and audio-floor controls.

Capture double buffering, shared-memory desktop transport, raw Metal buffer
views, and a full libusb event-thread rewrite remain deferred. Their complexity
needs a measured bottleneck. Linux real-time scheduling remains off because it
can take CPU time from the game. Intra-refresh cannot make arbitrary dependent
H.264 frame drops safe. Vector resize also does not imply allocation when its
existing capacity is sufficient.
