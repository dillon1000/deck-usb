#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
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
    bash check-hardware.sh
    "${CXX:-c++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined check.cpp -o build/check
    build/check
    if [[ $(uname) == Darwin ]]; then
      clang++ -std=c++20 -O1 -g -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
        check-mac.mm -framework Cocoa -o build/check-mac
      build/check-mac
    fi
    # The transfer check supplies fake libusb functions; no USB hardware is used.
    if [[ -f "$usb_prefix/include/libusb-1.0/libusb.h" ]]; then
      "${CXX:-c++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
        -I"$usb_prefix/include/libusb-1.0" check-usb.cpp -o build/check-usb
      build/check-usb
    fi
    ;;
  test-decoder)
    clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror -fsanitize=address,undefined \
      check-decoder.mm -framework Cocoa -framework VideoToolbox -framework CoreMedia -framework CoreVideo -o build/check-decoder
    build/check-decoder "${@:2}"
    ;;
  deck)
    "${CXX:-g++}" -std=c++20 -O3 -pthread -Wall -Wextra -Werror deck.cpp -o build/deck-usb
    ;;
  mac)
    # Link an existing libusb installation; do not install dependencies here.
    test -f "$usb_prefix/include/libusb-1.0/libusb.h" || { echo 'Set LIBUSB_PREFIX to the installed libusb prefix.' >&2; exit 1; }
    app=build/DeckUSB.app/Contents
    mkdir -p "$app/MacOS" "$app/Frameworks" "$app/Resources"
    cp assets/deck.svg "$app/Resources/deck.svg"
    clang++ -std=c++20 -O3 -fobjc-arc -pthread -Wall -Wextra -Werror \
      -I"$usb_prefix/include/libusb-1.0" mac.mm mac-app.mm mac-ui.mm mac-view.mm mac-audio.mm \
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
  *) echo 'Usage: bash build.sh mac|deck|test' >&2; exit 2 ;;
esac
