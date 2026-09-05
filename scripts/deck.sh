#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source ./scripts/hardware.sh

# The desktop user owns the FIFO. Stopping needs neither sudo nor an OSK Control key.
if [[ ${1:-} == stop ]]; then
    if [[ -f /etc/systemd/system/deckusb.service && $EUID != 0 ]]; then exec systemctl stop deckusb.service; fi
    [[ -p /run/deckusb/control ]] || exit 0
    exec timeout 3 bash -c 'printf "stop\n" > /run/deckusb/control'
fi

validate_video() {
    QUALITY=${QUALITY:-20} # Older four-field settings retain the original H.264 quality.
    [[ $QUALITY == 20 || $QUALITY == 24 || $QUALITY == 28 ]] || return 2
    for number in "$WIDTH" "$HEIGHT" "$FPS"; do [[ $number =~ ^[1-9][0-9]*$ ]] || return 2; done
    [[ $WIDTH -ge 2 && $WIDTH -le 1920 && $((WIDTH % 2)) == 0 && $HEIGHT -ge 2 && $HEIGHT -le 1200 && $((HEIGHT % 2)) == 0 && $FPS -ge 1 && $FPS -le 240 ]] || return 2
    [[ $FORMAT == nv12 || $FORMAT == bgra || $FORMAT == h264 ]]
}

# The capture process runs as the desktop user. Only USB setup and uinput need
# root. The optional installer runs this same supervisor as a system service.
if [[ ${1:-} == stream ]]; then
    mode=$2
    # A settings file permits resolution tests without restarting sudo; its
    # optional fifth value selects H.264 quality (20 when absent).
    # Parse data only; never source a desktop-user file into the root shell.
    if [[ -f /run/deckusb-video.conf ]]; then read -r WIDTH HEIGHT FPS FORMAT QUALITY < /run/deckusb-video.conf
    elif [[ -f video.conf ]]; then read -r WIDTH HEIGHT FPS FORMAT QUALITY < video.conf; fi
    validate_video
    if [[ $mode != live && $FORMAT == h264 ]]; then FORMAT=nv12; fi
    args=(--width "$WIDTH" --height "$HEIGHT" --fps "$FPS" --format "$FORMAT")
    # Transport experiments change request scheduling, never video framing.
    writes=${DECKUSB_USB_WRITES:-large}
    if [[ -z ${DECKUSB_USB_WRITES:-} ]]; then
        if [[ -f /run/deckusb-usb-writes.conf ]]; then read -r writes < /run/deckusb-usb-writes.conf
        elif [[ -f usb-writes.conf ]]; then read -r writes < usb-writes.conf; fi
    fi
    [[ $writes == serial || $writes == large || $writes == async ]] || exit 2
    args+=(--usb-writes "$writes" --quality "$QUALITY")
    if [[ $mode == live ]]; then
        packet_sizes=/dev/null
        if [[ $FORMAT == h264 ]]; then
            packet_dir=$(mktemp -d /run/deckusb/packets.XXXXXX)
            packet_sizes=$packet_dir/sizes; mkfifo -m 600 "$packet_sizes"
            chmod 711 "$packet_dir"; chown "$DESKTOP_UID" "$packet_sizes"
            trap 'rm -f -- "$packet_sizes"; rmdir -- "$packet_dir"' EXIT
            args+=(--packet-sizes "$packet_sizes")
        fi
        runuser -u "$DESKTOP_USER" -- env XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID" \
            bash "$PWD/scripts/capture.sh" "$WIDTH" "$HEIGHT" "$FPS" "$FORMAT" "$packet_sizes" "$QUALITY" \
            | ./build/deck-usb "${args[@]}" --audio-fd 3 3< <(
                runuser -u "$DESKTOP_USER" -- env XDG_RUNTIME_DIR="/run/user/$DESKTOP_UID" \
                    bash "$PWD/scripts/audio.sh")
    else
        exec ./build/deck-usb "${args[@]}" "--$mode"
    fi
    exit
fi

[[ $EUID == 0 ]] || { echo 'Run: sudo bash scripts/deck.sh [--usb-network]' >&2; exit 1; }
network=false
[[ ${1:-} != --usb-network ]] || network=true
[[ $# == 0 || ( $# == 1 && $network == true ) ]] || { echo 'Usage: sudo bash scripts/deck.sh [--usb-network]' >&2; exit 2; }
export WIDTH=${WIDTH:-1280} HEIGHT=${HEIGHT:-800} FPS=${FPS:-60} FORMAT=${FORMAT:-nv12}
validate_video
export DESKTOP_USER=${SUDO_USER:?Start through sudo from the desktop user}
export DESKTOP_UID
DESKTOP_UID=$(id -u "$DESKTOP_USER")
[[ $DESKTOP_UID != 0 ]] || { echo 'Start this through sudo from the desktop user.' >&2; exit 1; }
# Log after sudo has authenticated. Tee writes as the desktop user, so a log
# symlink cannot make this root process overwrite a privileged file.
if [[ -z ${INVOCATION_ID:-} ]]; then
    exec > >(runuser -u "$DESKTOP_USER" -- tee -a "$PWD/session.log") 2>&1
fi
trap 'echo "Setup failed at line $LINENO: $BASH_COMMAND" >&2' ERR
test -x build/deck-usb

# Discover one supported AMD DRD controller; never assume a PCI address.
pci_path=$(find_drd_controller); pci=${pci_path##*/}
for bus in "$pci_path"/usb*; do
    [[ -d $bus ]] || continue
    for child in "$bus"/*-*; do
        [[ -e $child/idVendor ]] || continue
        echo "USB device attached at $child; remove it before switching the controller." >&2; exit 1
    done
done
g=/sys/kernel/config/usb_gadget/deckusb
original_driver=$(basename "$(readlink "$pci_path/driver")")
stream_pid=
switched=false
created=false

# Cleanup applies only to resources created by this session. An interrupted
# transfer removes the input device and restores normal USB host operation.
cleanup() {
    trap - EXIT INT TERM
    set +e
    if [[ -e $g/UDC && -n $(cat "$g/UDC") ]]; then printf '\n' > "$g/UDC"; fi
    if [[ -n $stream_pid ]]; then
        kill -TERM -- "-$stream_pid" 2>/dev/null
        wait "$stream_pid" 2>/dev/null
    fi
    if $created; then
        rm -f "$g/configs/c.1/ffs.direct" "$g/configs/c.1/ncm.usb0"
        umount /run/deckusb/ffs 2>/dev/null
        rmdir "$g/functions/ffs.direct" "$g/functions/ncm.usb0" 2>/dev/null
        rmdir "$g/configs/c.1/strings/0x409" "$g/configs/c.1" "$g/strings/0x409" "$g" 2>/dev/null
    fi
    # A group TERM can interrupt the stream shell before its EXIT trap. Remove
    # only packet FIFOs created inside this session's root-owned runtime folder.
    rm -f /run/deckusb/packets.*/sizes
    rmdir /run/deckusb/packets.* 2>/dev/null
    rm -f /run/deckusb/control /run/deckusb/ready
    rmdir /run/deckusb/ffs /run/deckusb 2>/dev/null
    if $switched; then
        printf '%s' "$pci" > /sys/bus/pci/drivers/dwc3-pci/unbind
        printf '%s' "$pci" > "/sys/bus/pci/drivers/$original_driver/bind"
    fi
    # Installed code and settings are root-owned. Keep validated settings across
    # reboot; manual launches keep their existing temporary /run settings.
    if [[ -n ${INVOCATION_ID:-} && -f /run/deckusb-video.conf ]]; then
        read -r WIDTH HEIGHT FPS FORMAT QUALITY < /run/deckusb-video.conf
        if validate_video; then
            printf '%s %s %s %s %s\n' "$WIDTH" "$HEIGHT" "$FPS" "$FORMAT" "$QUALITY" > video.conf.next
            mv video.conf.next video.conf
        fi
    fi
    if [[ -n ${INVOCATION_ID:-} && -f /run/deckusb-usb-writes.conf ]]; then
        read -r writes < /run/deckusb-usb-writes.conf
        if [[ $writes == serial || $writes == large || $writes == async ]]; then
            printf '%s\n' "$writes" > usb-writes.conf.next; mv usb-writes.conf.next usb-writes.conf
        fi
    fi
    echo 'DeckUSB stopped; session USB resources removed.'
}
# Serialize launchers. Older senders did not hold this lock, so also check their
# control FIFO and executable before reclaiming an interrupted session.
exec 8>/run/deckusb.lock
flock -n 8 || { echo 'DeckUSB is already running.' >&2; exit 1; }
if [[ -e /run/deckusb || -e $g ]]; then
    if pgrep -x deck-usb >/dev/null || fuser /run/deckusb/control >/dev/null 2>&1; then
        echo 'DeckUSB is already running; stop that session first.' >&2; exit 1
    fi
    if [[ -e $g ]]; then
        [[ $(cat "$g/idVendor") == 0x1209 && $(cat "$g/idProduct") == 0x0001 &&
           $(cat "$g/strings/0x409/product") == 'DeckUSB Direct' ]] || {
            echo 'Unrecognized stale USB state; leaving it untouched.' >&2; exit 1;
        }
    else
        # Interrupted cleanup can remove configfs before the FunctionFS mount.
        # Reclaim only our exact, unused mount in a root-owned runtime directory.
        [[ ! -L /run/deckusb && $(stat -c %u /run/deckusb) == 0 &&
           $(findmnt -rn -M /run/deckusb/ffs -o FSTYPE,SOURCE) == 'functionfs direct' ]] &&
           ! fuser -m /run/deckusb/ffs >/dev/null 2>&1 || {
            echo 'Unrecognized or active USB mount; leaving it untouched.' >&2; exit 1;
        }
    fi
    echo 'Removing the stopped DeckUSB session.'
    created=true; cleanup; set -e; created=false
    [[ ! -e /run/deckusb && ! -e $g ]] || { echo 'USB cleanup did not complete.' >&2; exit 1; }
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
modprobe -a dwc3-pci libcomposite usb_f_fs uinput
if [[ $original_driver == xhci_hcd ]]; then
    printf '%s' "$pci" > /sys/bus/pci/drivers/xhci_hcd/unbind
    switched=true
    printf '%s' "$pci" > /sys/bus/pci/drivers/dwc3-pci/bind
fi
udcs=(/sys/class/udc/*)
[[ ${#udcs[@]} == 1 && -e ${udcs[0]} ]] || { echo 'Expected one USB device controller.' >&2; exit 1; }
udc=$(basename "${udcs[0]}")
echo "USB controller: $udc, maximum speed: $(cat "${udcs[0]}/maximum_speed")"
mkdir -p /run/deckusb/ffs
mkfifo -m 600 /run/deckusb/control
chown "$DESKTOP_UID" /run/deckusb/control
# Keep the FIFO open so timeout reads can also watch for cable disconnects.
exec 9<> /run/deckusb/control
mkdir "$g"; created=true
printf '0x1209' > "$g/idVendor"; printf '0x0001' > "$g/idProduct"
printf '0x0300' > "$g/bcdUSB"; printf '0x0100' > "$g/bcdDevice"
mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409"
printf 'deckusb-dev-1' > "$g/strings/0x409/serialnumber"
printf 'DeckUSB' > "$g/strings/0x409/manufacturer"
printf 'DeckUSB Direct' > "$g/strings/0x409/product"
printf 'Direct video and input' > "$g/configs/c.1/strings/0x409/configuration"
# Self-powered Deck; USB charging remains negotiated by the physical hardware.
printf '0xC0' > "$g/configs/c.1/bmAttributes"; printf '0' > "$g/configs/c.1/MaxPower"
mkdir "$g/functions/ffs.direct"
mount -t functionfs direct /run/deckusb/ffs
ln -s "$g/functions/ffs.direct" "$g/configs/c.1/ffs.direct"
if $network; then
    # Optional USB-only management link. Link-local IPv6 needs no router, DHCP,
    # forwarding, or Wi-Fi. It is separate from the raw video endpoints.
    mkdir "$g/functions/ncm.usb0"
    printf '02:44:55:66:77:02' > "$g/functions/ncm.usb0/dev_addr"
    printf '02:44:55:66:77:01' > "$g/functions/ncm.usb0/host_addr"
    ln -s "$g/functions/ncm.usb0" "$g/configs/c.1/ncm.usb0"
fi
mode=test
# Resume a saved session directly. A raw startup pattern cannot describe H.264
# and previously made the viewer overwrite the saved codec with raw video.
[[ ! -f /run/deckusb-video.conf && ! -f video.conf ]] || mode=live
while [[ $mode != stop ]]; do
    case $mode in
      test|bench|live)
        active_mode=$mode
        # configfs returns ENODEV when asked to unbind an already unbound gadget.
        if [[ -n $(cat "$g/UDC") ]]; then printf '\n' > "$g/UDC"; fi
        if [[ -n $stream_pid ]]; then kill -TERM -- "-$stream_pid" 2>/dev/null || true; wait "$stream_pid" 2>/dev/null || true; fi
        # runuser may need a moment to terminate its capture child. Recreate the
        # FunctionFS mount only after its descriptors are no longer in use.
        for ((attempt=0; attempt<60; attempt++)); do
            [[ -z $stream_pid ]] && break
            kill -0 -- "-$stream_pid" 2>/dev/null || break
            sleep 0.05
        done
        rm -f /run/deckusb/packets.*/sizes
        rmdir /run/deckusb/packets.* 2>/dev/null || true
        rm "$g/configs/c.1/ffs.direct"
        umount /run/deckusb/ffs
        mount -t functionfs direct /run/deckusb/ffs
        ln -s "$g/functions/ffs.direct" "$g/configs/c.1/ffs.direct"
        rm -f /run/deckusb/ready
        setsid bash "$PWD/scripts/deck.sh" stream "$mode" &
        stream_pid=$!
        for ((attempt=0; attempt<100; attempt++)); do
            [[ ! -s /run/deckusb/ready ]] || break
            kill -0 "$stream_pid" 2>/dev/null || break
            sleep 0.05
        done
        if [[ ! -s /run/deckusb/ready ]]; then
            # VAAPI can fail before it opens the packet FIFO. Recover here too:
            # the sender cannot request raw mode until USB setup has completed.
            if [[ -f /run/deckusb-video.conf ]]; then read -r WIDTH HEIGHT FPS FORMAT QUALITY < /run/deckusb-video.conf
            elif [[ -f video.conf ]]; then read -r WIDTH HEIGHT FPS FORMAT QUALITY < video.conf; fi
            validate_video
            [[ $mode == live && $FORMAT == h264 ]] || { echo 'Sender failed before USB setup.' >&2; exit 1; }
            printf '%s %s %s nv12\n' "$WIDTH" "$HEIGHT" "$FPS" > /run/deckusb-video.recovery
            mv /run/deckusb-video.recovery /run/deckusb-video.conf
            echo 'Encoder startup failed; restoring raw video.'
            continue
        fi
        printf '%s' "$udc" > "$g/UDC"
        if $network; then
            usbif=$(cat "$g/functions/ncm.usb0/ifname")
            # An encoder failure may restart the sender during enumeration.
            # Let the loop recover instead of terminating the whole USB session.
            if ! ip link set "$usbif" up || ! ip -6 addr replace fe80::2/64 dev "$usbif"; then
                echo 'USB management interface changed during sender restart; retrying.'
            fi
        fi
        echo "Mode: $mode. Connect the Mac viewer."
        ;;
      *) echo "Unknown mode: $mode (use test, bench, live, or stop)." >&2 ;;
    esac
    while ! IFS= read -r -t 0.2 mode <&9; do
        if ! kill -0 "$stream_pid" 2>/dev/null; then
            # FunctionFS removes its interface when the sender exits. Restart it
            # to advertise the device again, even while the cable is unplugged.
            echo 'USB sender exited; waiting for the next connection.'
            mode=$active_mode
            break
        fi
    done
done
