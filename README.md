# DeckUSB

A C++20 USB sender for Steam Deck and a native Objective-C++/Metal viewer for
macOS. Direct USB bulk endpoints carry video, stereo audio, keyboard input, and
pointer input. The viewer does not use network streaming.

This is a prototype. It captures X11 Desktop Mode or Gaming Mode through
PipeWire. It can enlarge the X11 desktop; it does not create a virtual display.
The launcher supports
AMD USB dual-role hardware with PCI identity `1022:163a`. It discovers the PCI
address at runtime and refuses missing or ambiguous controllers. That identity
is a compatibility guard, not a particular device's address or serial number.

## Build

Install a C++20 compiler, pnpm, and libusb. The Mac build also requires Apple
command-line developer tools. libusb is located through pkg-config or Homebrew;
set `LIBUSB_PREFIX` if neither can locate it. The build links its static library.

```sh
pnpm test
pnpm build
pnpm start
```

The Mac app is `build/DeckUSB.app`. On x86-64 Linux, install the X11 and Xext
development headers and libraries, then run `pnpm build:deck` or
`bash scripts/build.sh deck`. The resulting `build/deck-usb` sender and
`build/deck-capture` helper must match the Deck's installed runtime. The capture
helper targets the Zen 2 CPU in both Deck models. No prebuilt binary is included.
Mac and Deck must use matching protocol versions.

## Start the Deck

Enable USB dual-role device mode in the firmware and enter Desktop Mode for
setup. The Deck needs Bash, FFmpeg with x11grab, X11/Xext, XRandR, Python 3,
PulseAudio-compatible command line tools, systemd, polkit, and Linux FunctionFS,
configfs, and uinput support. Gaming Mode also needs GStreamer with PipeWire,
`pw-dump`, and `jq`. Hardware H.264 requires FFmpeg VAAPI support and an AMD
render device. Setup checks for these tools; it does not download packages.

Copy the project, including `scripts/`, `assets/`, and both Linux binaries in
`build/`, to the Deck. Keep the folder layout. As your normal Deck user, run:

```sh
bash scripts/setup.sh
```

Enter your password once to install the service. DeckUSB then starts with
Desktop or Gaming Mode. The installed start and stop icons control the service
without another password. Rerun setup after copying an update. To remove
automatic startup, run `bash scripts/setup.sh remove`.

The installer puts root-owned service files in `/var/lib/deckusb/app` and `/etc`.
Its polkit rule permits only start, stop, and restart of `deckusb.service` for
the installing user. Capture runs as that user; USB setup and input injection
need root. Logs are available with `journalctl -u deckusb.service`; setup writes
`setup.log` in the project directory.

For a manual session, run `sudo bash scripts/deck.sh` and keep the terminal open.
To stop that session from another terminal in the same directory:

```sh
bash ./scripts/deck.sh stop
```

Stopping releases input, restores the prior desktop layout and audio output,
and removes temporary USB resources. The launcher verifies stopped session
resources before cleaning them up. Manual sessions write `session.log` in the
project directory.

The installed service enables a separate link-local USB management interface;
manual sessions can enable it with `--usb-network`. The protocol address is
`fe80::2`; SSH requires the interface scope
assigned by the host, which must be discovered locally. It does not carry the
viewer's video or audio and does not enable routing or Wi-Fi fallback.

## Viewer controls

Display settings select resolution, frame rate, and Uncompressed or H.264 video.
Apply sends settings over USB and restarts capture. Runtime settings are stored
in `/run/deckusb-video.conf`; the installed service saves them when it stops.
In Desktop Mode, a larger size
enlarges the desktop framebuffer while capture runs and restores the prior
layout when it stops. A game may need a resolution change or restart to use
that size. Gaming Mode scales its existing capture and does not change the
game's render resolution.
The startup cable test can be skipped or disabled. It measures actual raw USB
throughput and recommends a setting with headroom for audio and timing variation.
USB 2 connections show a bandwidth warning; a cable label does not establish
negotiated speed or throughput.

The center of the bottom bar shows Deck CPU and GPU load and temperature,
RAM use, battery charge and charging state, and fan speed. Hover for full units
and readings. CPU load is a percentage of total CPU capacity; RAM use excludes
available memory. Sensors are read once per second on a separate thread and
sent through the existing USB heartbeat. Missing readings show a dash; samples
older than three seconds show as unavailable. Older senders still play normally
but need an update to provide these stats. The viewer does not change fan control.

- Command+, opens Display settings; Command+T tests the cable.
- Command+I shows live throughput, frame rate, control RTT, and audio buffering.
- Command+F toggles full screen; Command+Q quits.
- Shift+Command+M toggles relative pointer capture.
- Control maps to Linux Ctrl, Option to Alt, and Command to Super.
- Multiple held keys, modifiers, right-click, dragging, and key repeat are supported.
  macOS system shortcuts and viewer menu shortcuts stay local.

Losing focus releases held input. A heartbeat watchdog releases it after a
connection failure. Display settings include a Metal performance overlay and a
saved **Prevent screen tearing** option. Display sync is enabled by default;
turning it off can reduce presentation delay but can cause tearing. `--no-vsync`,
`--serial-usb`, and `--display-link` are comparison options; display-link mode
requires macOS 14 or later. `--sensitivity` scales relative pointer movement.

## Configuration

The default startup values are 1280 × 800, 60 fps, NV12. They are configuration
defaults, not a claim that a given USB link can sustain them. Select lower values
or run the cable test when necessary. Set WIDTH, HEIGHT, FPS, and FORMAT through
`sudo env`, or put four space-separated values in `video.conf`. Applied runtime
settings take precedence. Files are parsed as data, never executed as shell code.

Even dimensions up to 1920 × 1200 and rates up to 240 fps are validated. Hardware
may not sustain them. Desktop resizing depends on XRandR support; read the
capture log if the requested size cannot be applied.

Native NV12 desktop capture uses X11 shared memory and SIMD CPU conversion,
without a GPU conversion job. Unsupported layouts and other formats use FFmpeg
as a fallback. `DECKUSB_SOFTWARE_CONVERSION=1` selects the FFmpeg path for
comparison. Gaming Mode uses a bounded PipeWire capture queue.

FORMAT accepts `nv12`, `bgra`, or `h264`. H.264 uses independent IDR frames,
QP 20, no B-frames, and a bounded packet size. Each packet carries SPS/PPS so
stale frames can be dropped safely. The Mac requires hardware VideoToolbox
decoding. Codec failure restores raw capture at the same size and rate.
`VAAPI_DEVICE` can select a render node explicitly; otherwise one AMD render
node must be discoverable. Compression trades image quality and codec work for
less USB traffic. Cable tests always measure the raw transfer path.

Audio captures the temporary output's monitor, not a microphone, as stereo
48 kHz PCM. The Mac adapts buffering to clock drift and interruptions. Startup
and capture transitions can interrupt sound. No fixed latency or game-FPS cost
is guaranteed; see [performance guidance](docs/PERFORMANCE.md) for measurement guidance.

## Source and checks

```text
src/
  mac/       Native viewer, USB transport, decoding, and audio
  deck/      Linux sender, input injection, and configuration
  shared/    Wire protocol and codec framing
scripts/     Build, setup, capture, hardware discovery, and measurements
tests/       Protocol, transport, capture, input, and decoder checks
assets/      Viewer artwork, desktop entries, and service units
docs/        Performance measurement guidance
build/       Generated binaries and app bundle (not tracked)
```

Shared headers stay in `src/shared`; platform headers stay next to their
implementation. Scripts resolve paths from the project root, so pnpm commands
work as before. The root contains project metadata and this README.

`pnpm test` checks protocol limits, malformed packets, audio buffering, hardware
discovery, capture selection, desktop resizing, pixel conversion, modifiers on
macOS, and USB transfer ordering when libusb is available.
A hardware decoder check accepts an Annex B file followed by its dimensions and
packet sizes from FFmpeg framecrc: `pnpm test:decoder FILE WIDTH HEIGHT SIZE...`.
It requires actual hardware decoding and is separate from the regular checks.

USB IDs `1209:0001` are prototype test IDs, not a production allocation. The host
also checks the product string before claiming an interface.

## License

DeckUSB is licensed under the [MIT License](LICENSE).
Copyright (c) 2026 Dillon Ring.

## Disclaimer

Use DeckUSB at your own risk. It is provided "as is", without warranty.
To the fullest extent permitted by applicable law, Dillon Ring and the
contributors are not liable for any damage, data loss, or other loss arising
from installing, using, modifying, or distributing DeckUSB. This includes damage
to your Steam Deck, Mac, USB ports, cables, peripherals, or any other device or
property. See the [MIT License](LICENSE) for the full warranty and liability terms.

## AI code notice

This project includes AI-generated code and was developed with AI coding tools.
The code may contain errors. Review it before use.
