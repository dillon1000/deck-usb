# DeckUSB

A C++20 USB sender for Steam Deck and a native Objective-C++/Metal viewer for
macOS. Direct USB bulk endpoints carry video, stereo audio, keyboard input, and
pointer input. The viewer does not use network streaming.

This is a prototype. Live capture requires an X11 desktop session. It mirrors
the existing desktop; it does not create a virtual display. The launcher supports
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

The Mac app is `build/DeckUSB.app`. Build the sender on Linux with
`pnpm build:deck`, or `bash build.sh deck`. The resulting `build/deck-usb` must
match the Deck's CPU architecture and installed runtime. No prebuilt binary is
included. Mac and Deck must use matching protocol versions.

## Start the Deck

Enable USB dual-role device mode in the firmware and enter an X11 Desktop Mode
session. The Deck needs Bash, FFmpeg with x11grab, PulseAudio-compatible command
line tools, and Linux FunctionFS, configfs, and uinput support. Hardware H.264
also requires FFmpeg VAAPI support and an AMD render device.

Copy `deck.sh`, `hardware.sh`, `audio.sh`, and the Linux `build/deck-usb` into the
same directory layout on the Deck. From that directory, run:

```sh
sudo bash ./deck.sh
```

The script gets the desktop user from sudo and reads display credentials from
the user's session. Capture runs as that user; USB setup and input injection need
root. Keep the terminal open. To stop from another terminal in the same directory:

```sh
bash ./deck.sh stop
```

Stopping releases input, restores the prior audio output, and removes temporary
USB resources. The launcher verifies stopped session resources before cleaning
them up. Logs are written to `session.log` in the project directory.

An optional `--usb-network` flag creates a separate link-local management
interface. Its protocol address is `fe80::2`; SSH requires the interface scope
assigned by the host, which must be discovered locally. It does not carry the
viewer's video or audio and does not enable routing or Wi-Fi fallback.

## Viewer controls

Display settings select resolution, frame rate, and Uncompressed or H.264 video.
Apply sends settings over USB and restarts capture. Settings are temporary in
`/run/deckusb-video.conf`; they do not change the desktop framebuffer.
The startup cable test can be skipped or disabled. It measures actual raw USB
throughput and recommends a setting with headroom for audio and timing variation.
USB 2 connections show a bandwidth warning; a cable label does not establish
negotiated speed or throughput.

- Command+, opens Display settings; Command+T tests the cable.
- Command+I shows live throughput, frame rate, control RTT, and audio buffering.
- Command+F toggles full screen; Command+Q quits.
- Shift+Command+M toggles relative pointer capture.
- Control maps to Linux Ctrl, Option to Alt, and Command to Super.
- Multiple held keys, modifiers, right-click, dragging, and key repeat are supported.
  macOS system shortcuts and viewer menu shortcuts stay local.

Losing focus releases held input. A heartbeat watchdog releases it after a
connection failure. Display sync is enabled to prevent tearing. `--no-vsync`,
`--serial-usb`, and `--display-link` are comparison options; display-link mode
requires macOS 14 or later. `--sensitivity` scales relative pointer movement.

## Configuration

The default startup values are 1280 × 800, 60 fps, NV12. They are configuration
defaults, not a claim that a given USB link can sustain them. Select lower values
or run the cable test when necessary. Set WIDTH, HEIGHT, FPS, and FORMAT through
`sudo env`, or put four space-separated values in `video.conf`. Applied runtime
settings take precedence. Files are parsed as data, never executed as shell code.

Even dimensions up to 1920 × 1200 and rates up to 240 fps are validated. Hardware
may not sustain them. Dimensions above the desktop resolution only upscale the
image; a larger native desktop requires separate display configuration.

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
is guaranteed; see PERFORMANCE.md for measurement guidance.

## Source and checks

`protocol.hpp` defines framing and limits. `deck.cpp` owns the sender, with
input, I/O, and configuration helpers in headers. `usb.hpp` and `usb-video.hpp`
implement host transport. The native viewer shares declarations in `mac.hpp`;
window controls, rendering, decoding, and audio are separate implementation files.

`pnpm test` checks protocol limits, malformed packets, audio buffering, hardware
discovery, modifiers on macOS, and USB transfer ordering when libusb is available.
A hardware decoder check accepts an Annex B file followed by its dimensions and
packet sizes from FFmpeg framecrc: `pnpm test:decoder FILE WIDTH HEIGHT SIZE...`.
It requires actual hardware decoding and is separate from the regular checks.

USB IDs `1209:0001` are prototype test IDs, not a production allocation. The host
also checks the product string before claiming an interface.
