#!/usr/bin/env bash
# Run as the desktop user inside Konsole. Log startup and exit without logging
# password input; sudo reads the password directly from the terminal with echo off.
set -uo pipefail
cd -- "$(dirname -- "$0")/.." || exit 1
if systemctl cat deckusb.service >/dev/null 2>&1; then
    exec systemctl start deckusb.service
fi
printf '\nDeckUSB startup: %s\nEnter your Deck password if asked. Typing is hidden.\n' "$(date)" | tee -a launcher.log
sudo bash "$PWD/scripts/deck.sh" --usb-network
result=$?
printf '\nDeckUSB stopped (exit %s).\nClose this window and open DeckUSB again to retry.\n' "$result" | tee -a launcher.log
exit "$result"
