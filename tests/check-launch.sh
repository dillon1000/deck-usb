#!/usr/bin/env bash
set -euo pipefail
# A failed sudo/setup command must leave a visible result and preserve its exit
# status. The stub never authenticates or starts USB resources.
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/scripts"
cp "$(dirname -- "$0")/../scripts/launch.sh" "$scratch/scripts/launch.sh"
printf '#!/usr/bin/env bash\nexit 17\n' > "$scratch/sudo"
printf '#!/usr/bin/env bash\nexit 1\n' > "$scratch/systemctl"
chmod +x "$scratch/sudo" "$scratch/systemctl"
result=0
PATH="$scratch:$PATH" bash "$scratch/scripts/launch.sh" > "$scratch/output" || result=$?
[[ $result == 17 && $(<"$scratch/output") == *'DeckUSB stopped (exit 17)'* ]]
[[ $(<"$scratch/launcher.log") == *'DeckUSB startup:'* ]]
printf '#!/usr/bin/env bash\n[[ $1 == cat ]] && exit 0\nexit 19\n' > "$scratch/systemctl"
result=0
PATH="$scratch:$PATH" bash "$scratch/scripts/launch.sh" >/dev/null || result=$?
[[ $result == 19 ]]
cp "$(dirname -- "$0")/../scripts/setup.sh" "$scratch/scripts/setup.sh"
printf '#!/usr/bin/env bash\n[[ $1 == -v ]] && exit 0\necho "The old DeckUSB session did not stop."\nexit 17\n' > "$scratch/sudo"
result=0
PATH="$scratch:$PATH" bash "$scratch/scripts/setup.sh" > "$scratch/output" || result=$?
[[ $result == 17 && $(<"$scratch/output") == *'Password accepted.'* ]]
[[ $(<"$scratch/setup.log") == *'The old DeckUSB session did not stop.'* && $(<"$scratch/setup.log") == *'Setup failed (exit 17)'* ]]
printf '#!/usr/bin/env bash\nexit 1\n' > "$scratch/sudo"
result=0
PATH="$scratch:$PATH" bash "$scratch/scripts/setup.sh" > "$scratch/output" || result=$?
[[ $result == 1 && $(<"$scratch/output") != *'Password accepted.'* ]]
echo 'Launcher failure visibility: PASS'
