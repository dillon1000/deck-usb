#!/usr/bin/env bash
# One visible password prompt installs or removes the fixed service. The
# installed service runs from root-owned storage, not the user's source folder.
set -uo pipefail
cd -- "$(dirname -- "$0")/.." || exit 1
printf 'DeckUSB setup: %s\nEnter your Deck password once. Typing is hidden.\n' "$(date)" | tee -a setup.log
sudo -v
result=$?
if [[ $result == 0 ]]; then
    printf '\nPassword accepted. Installing DeckUSB…\n' | tee -a setup.log
    sudo -n bash "$PWD/scripts/install.sh" "${1:-install}" 2>&1 | tee -a setup.log
    result=${PIPESTATUS[0]}
fi
if [[ $result == 0 ]]; then
    printf '\nSetup complete. Close this window.\n' | tee -a setup.log
else
    printf '\nSetup failed (exit %s). Keep this window open for the error above.\n' "$result" | tee -a setup.log
fi
exit "$result"
