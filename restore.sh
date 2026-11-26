#!/usr/bin/env bash
set -euo pipefail

TV_HOST="${1:-${TV_HOST:-}}"
if [ -z "$TV_HOST" ]; then
    echo "Usage: TV_HOST=<ip>:<port> $0 | $0 <ip>:<port>" >&2
    exit 1
fi

echo "Connecting to $TV_HOST ..."
adb connect "$TV_HOST"
adb -s "$TV_HOST" wait-for-device

SVC="com.local.buttonremap/.ButtonRemapService"
FULL_SVC="com.local.buttonremap/com.local.buttonremap.ButtonRemapService"
EXISTING="$(adb -s "$TV_HOST" shell settings get secure enabled_accessibility_services | tr -d '\r\n')"
REMAINING=""
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    IFS=':' read -ra PARTS <<< "$EXISTING"
    for item in "${PARTS[@]}"; do
        if [ -n "$item" ] && [ "$item" != "$SVC" ] && [ "$item" != "$FULL_SVC" ]; then
            REMAINING="${REMAINING:+$REMAINING:}$item"
        fi
    done
fi

if [ -n "$REMAINING" ]; then
    adb -s "$TV_HOST" shell "settings put secure enabled_accessibility_services '$REMAINING'"
else
    adb -s "$TV_HOST" shell settings delete secure enabled_accessibility_services
    adb -s "$TV_HOST" shell settings put secure accessibility_enabled 0
fi

echo "Uninstalling com.local.buttonremap..."
adb -s "$TV_HOST" uninstall com.local.buttonremap
echo "Restored."
