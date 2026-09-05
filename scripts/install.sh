#!/usr/bin/env bash
# Explicit one-time root install. /var and /etc survive ordinary SteamOS
# updates without disabling its read-only system image. No package downloads.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source ./scripts/hardware.sh
[[ $EUID == 0 && ${SUDO_USER:-} =~ ^[a-z_][a-z0-9_-]*$ && $SUDO_USER != root ]] || { echo 'Run scripts/setup.sh as your Deck user.' >&2; exit 1; }
user=$SUDO_USER
uid=$(id -u "$user")
user_home=$(getent passwd "$user" | cut -d: -f6)
as_user=(runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid")
app=/var/lib/deckusb/app
action=${1:-install}
[[ $action == install || $action == remove ]] || exit 2
stage='Preparing setup'
trap 'echo "Setup failed: $stage (line $LINENO)." >&2' ERR
echo "$stage"
if [[ $action == remove ]]; then
    "${as_user[@]}" systemctl --user disable --now deckusb-session.service || true
    systemctl stop deckusb.service
    rm -f /etc/systemd/system/deckusb.service /etc/polkit-1/rules.d/49-deckusb.rules
    "${as_user[@]}" rm -f "$user_home/.config/systemd/user/deckusb-session.service"
    systemctl daemon-reload
    "${as_user[@]}" systemctl --user daemon-reload
    for name in DeckUSB StopDeckUSB; do
        for folder in Desktop .local/share/applications; do
            "${as_user[@]}" rm -f "$user_home/$folder/$name.desktop"
        done
    done
    echo 'Automatic startup removed. The USB port is restored; files and settings remain.'
    exit
fi
stage='Checking capture tools'; echo "$stage"
for tool in ffmpeg gst-launch-1.0 gst-inspect-1.0 pw-dump jq xdpyinfo xrandr python3 pactl parec runuser flock pkexec; do command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }; done
for plugin in pipewiresrc videoscale videorate queue fdsink; do timeout 10 gst-inspect-1.0 "$plugin" >/dev/null; done
if [[ -x build/deck-pipewire ]]; then
    for plugin in videoconvert appsink; do timeout 10 gst-inspect-1.0 "$plugin" >/dev/null; done
    capture_status=0
    build/deck-pipewire 0 0 0 0 >/dev/null 2>&1 || capture_status=$?
    [[ $capture_status == 75 ]] || { echo 'The PipeWire helper cannot run on this Deck.' >&2; exit 1; }
fi
test -x build/deck-usb
test -x build/deck-capture
# Check the native helper's loader before stopping a working installed service.
capture_status=0
build/deck-capture 0 0 60 >/dev/null 2>&1 || capture_status=$?
[[ $capture_status == 1 ]] || { echo 'The native capture helper cannot run on this Deck.' >&2; exit 1; }
for file in scripts/*.sh; do bash -n "$file"; done
find_drd_controller >/dev/null
# Stop only this app, including an earlier terminal launch, before replacing it.
stage='Stopping the previous DeckUSB session'; echo "$stage"
timeout 20 systemctl stop deckusb.service 2>/dev/null || true
if [[ -p /run/deckusb/control ]]; then timeout 3 bash -c 'printf "stop\n" > /run/deckusb/control' || true; fi
# A closed Konsole can leave its isolated stream group alive with no supervisor
# reading the FIFO. Match both the sender executable and its group leader before
# terminating that group; never kill a process merely because of its name.
for pid in $(pgrep -x deck-usb || true); do
    executable=$(readlink -f "/proc/$pid/exe" || true)
    [[ $executable == "$PWD/build/deck-usb" || $executable == "$app/build/deck-usb" ]] || continue
    group=$(ps -o pgid= -p "$pid" | tr -d ' ')
    [[ $group =~ ^[1-9][0-9]*$ ]] || continue
    mapfile -d '' -t command < "/proc/$group/cmdline" 2>/dev/null || continue
    [[ ${command[0]:-} == bash && ( ${command[1]:-} == "$PWD/scripts/deck.sh" || ${command[1]:-} == "$app/scripts/deck.sh" ) && ${command[2]:-} == stream ]] || continue
    echo "Stopping leftover DeckUSB stream group $group."
    kill -TERM -- "-$group"
done
for ((attempt=0; attempt<100; attempt++)); do
    pgrep -x deck-usb >/dev/null || break
    sleep 0.1
done
if pgrep -x deck-usb >/dev/null; then echo 'The old DeckUSB session did not stop.' >&2; exit 1; fi
stage='Installing the service files'; echo "$stage"
[[ ! -L /var/lib/deckusb && ! -L $app ]] || exit 1
install -d -o root -g root -m 755 /var/lib/deckusb "$app" "$app/build" "$app/scripts"
for file in deck.sh capture.sh audio.sh service.sh hardware.sh; do install -o root -g root -m 755 "scripts/$file" "$app/scripts/$file"; done
install -o root -g root -m 755 scripts/desktop-size.py "$app/scripts/desktop-size.py"
install -o root -g root -m 755 build/deck-usb "$app/build/deck-usb"
install -o root -g root -m 755 build/deck-capture "$app/build/deck-capture"
if [[ -x build/deck-pipewire ]]; then
    install -o root -g root -m 755 build/deck-pipewire "$app/build/deck-pipewire"
else
    rm -f "$app/build/deck-pipewire"
fi
# Keep the runtime setting when present; otherwise use raw native 60 fps.
# This matches the portable launcher default and avoids encoder startup work.
if [[ -f /run/deckusb-video.conf ]]; then
    read -r width height fps format quality < /run/deckusb-video.conf
    quality=${quality:-20}
    if [[ ( $quality == 20 || $quality == 24 || $quality == 28 ) && $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ && $fps =~ ^[0-9]+$ && $format =~ ^(h264|nv12|bgra)$ ]]; then
        printf '%s %s %s %s %s\n' "$width" "$height" "$fps" "$format" "$quality" > "$app/video.conf"
    fi
fi
[[ -f $app/video.conf ]] || printf '1280 800 60 nv12\n' > "$app/video.conf"
sed "s/@USER@/$user/g" assets/systemd/deckusb.service > /etc/systemd/system/deckusb.service
# Only start/stop/restart of this fixed unit is password-free. The account
# cannot edit the root-owned unit or installed scripts through this rule.
cat > /etc/polkit-1/rules.d/49-deckusb.rules <<EOF
polkit.addRule(function(action, subject) {
    if (subject.user == "$user" && action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "deckusb.service" &&
        ["start", "stop", "restart"].indexOf(action.lookup("verb")) >= 0)
        return polkit.Result.YES;
});
EOF
"${as_user[@]}" mkdir -p "$user_home/.config/systemd/user"
"${as_user[@]}" tee "$user_home/.config/systemd/user/deckusb-session.service" < assets/systemd/deckusb-session.service >/dev/null
stage='Starting the installed service'; echo "$stage"
timeout 15 systemctl daemon-reload
timeout 15 "${as_user[@]}" systemctl --user daemon-reload
timeout 15 "${as_user[@]}" systemctl --user enable deckusb-session.service
timeout 20 systemctl start deckusb.service
timeout 20 "${as_user[@]}" systemctl --user start deckusb-session.service
"${as_user[@]}" mkdir -p "$user_home/Desktop" "$user_home/.local/share/applications"
for name in DeckUSB StopDeckUSB; do
    verb=start; [[ $name != StopDeckUSB ]] || verb=stop
    for folder in Desktop .local/share/applications; do
        sed "s|^Exec=.*|Exec=/usr/bin/systemctl $verb deckusb.service|" "assets/desktop/$name.desktop" \
            | "${as_user[@]}" tee "$user_home/$folder/$name.desktop" >/dev/null
        "${as_user[@]}" chmod +x "$user_home/$folder/$name.desktop"
    done
done
echo 'DeckUSB is enabled for Desktop and Gaming Mode. Open the Mac viewer, then play normally.'
echo 'Use Stop DeckUSB to restore the USB port. Run scripts/setup.sh remove to remove automatic startup.'
