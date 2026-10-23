#!/bin/bash
set -u
cd "$(dirname "$0")" || exit 1
bash scripts/install-mac.sh
result=$?
if [[ -t 0 ]]; then
    echo
    read -r -p 'Press Return to close this window. ' _
fi
exit "$result"
