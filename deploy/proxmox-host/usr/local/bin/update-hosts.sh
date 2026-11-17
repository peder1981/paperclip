#!/bin/bash
set -euo pipefail
NAME="$1" IP="$2"
TMP=$(mktemp /tmp/hosts_peer.XXXXXX)
grep -Ev "[[:space:]]${NAME}([[:space:]]|\$)" /etc/hosts > "$TMP" || true
echo "$IP  $NAME ${NAME}.local" >> "$TMP"
chmod 644 "$TMP"
mv "$TMP" /etc/hosts
