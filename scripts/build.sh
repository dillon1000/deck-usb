#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
# Resolve source headers from the project root, independent of the caller directory.
includes=(-Isrc/shared -Isrc/mac -Isrc/deck)
mkdir -p build
# Resolve libusb from its package metadata or an explicit installation prefix.
usb_prefix=${LIBUSB_PREFIX:-}
if [[ -z $usb_prefix ]] && command -v pkg-config >/dev/null; then
    usb_prefix=$(pkg-config --variable=prefix libusb-1.0 2>/dev/null || true)
fi
if [[ -z $usb_prefix ]] && command -v brew >/dev/null; then
    usb_prefix=$(brew --prefix libusb 2>/dev/null || true)
fi
case "${1:-mac}" in
  test)
    bash tests/check-hardware.sh
    bash tests/check-launch.sh
    bash tests/check-capture.sh
    python3 tests/check-desktop-size.py
    "${CXX:-c++}" "${includes[@]}" -std=c++20 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined tests/check.cpp -o build/check
    build/check
    "${CXX:-c++}" "${includes[@]}" -std=c++20 -O3 -g -Wall -Wextra -Werror -fsanitize=address,undefined tests/check-convert.cpp -o build/check-convert
    build/check-convert
    "${CXX:-c++}" "${includes[@]}" -std=c++20 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined tests/check-telemetry.cpp -o build/check-telemetry
    build/check-telemetry
    if [[ $(uname) == Darwin ]]; then
      clang++ "${includes[@]}" -std=c++20 -O1 -g -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
        tests/check-mac.mm -framework Cocoa -o build/check-mac
      build/check-mac
    fi
    # The transfer check supplies fake libusb functions; no USB hardware is used.
    if [[ -f "$usb_prefix/include/libusb-1.0/libusb.h" ]]; then
      "${CXX:-c++}" "${includes[@]}" -std=c++20 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
        -I"$usb_prefix/include/libusb-1.0" tests/check-usb.cpp -o build/check-usb
      build/check-usb
    fi
    ;;
  test-decoder)
    clang++ "${includes[@]}" -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
      tests/check-decoder.mm -framework Cocoa -framework Metal -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o build/check-decoder
    build/check-decoder "${@:2}"
    ;;
  deck)
    "${CXX:-g++}" "${includes[@]}" -std=c++20 -O3 -pthread -Wall -Wextra -Werror src/deck/deck.cpp -o build/deck-usb
    # Both Deck models use Zen 2; optimize the per-pixel CPU conversion for it.
    "${CXX:-g++}" "${includes[@]}" -std=c++20 -O3 -march=znver2 -Wall -Wextra -Werror \
      src/deck/capture-x11.cpp -lX11 -lXext -o build/deck-capture
    ;;
  mac)
    # Link an existing libusb installation; do not install dependencies here.
    test -f "$usb_prefix/include/libusb-1.0/libusb.h" || { echo 'Set LIBUSB_PREFIX to the installed libusb prefix.' >&2; exit 1; }
    app=build/DeckUSB.app/Contents
    mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
    cp assets/deck.svg "$app/Resources/deck.svg"
    clang++ "${includes[@]}" -std=c++20 -O3 -fobjc-arc -pthread -Wall -Wextra -Werror \
      -I"$usb_prefix/include/libusb-1.0" src/mac/mac.mm src/mac/mac-app.mm src/mac/mac-ui.mm src/mac/mac-view.mm src/mac/mac-audio.mm \
      "$usb_prefix/lib/libusb-1.0.a" \
      -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
      -framework VideoToolbox -framework CoreMedia -framework CoreVideo \
      -framework AudioToolbox -framework IOKit -framework Security -o "$app/MacOS/deck-usb"
    cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>deck-usb</string>
<key>CFBundleIdentifier</key><string>local.deckusb.viewer</string>
<key>CFBundleName</key><string>DeckUSB</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
    codesign --force --sign - "build/DeckUSB.app"
    ;;
  *) echo 'Usage: bash scripts/build.sh mac|deck|test|test-decoder' >&2; exit 2 ;;
esac
