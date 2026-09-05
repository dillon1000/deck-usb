#!/usr/bin/env bash
# systemd keeps USB setup outside the desktop session. Wait for its capture
# source before touching the USB controller; stop requests interrupt this wait.
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
uid=$(id -u "${SUDO_USER:?Missing Deck user}")
echo 'Waiting for Desktop or Gaming Mode.'
until runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" bash "$PWD/scripts/capture.sh" --probe; do sleep 2; done
exec bash "$PWD/scripts/deck.sh" --usb-network
