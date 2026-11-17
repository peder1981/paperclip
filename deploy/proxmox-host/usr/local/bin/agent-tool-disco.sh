#!/bin/bash
set -o pipefail
# Uso: agent-tool-disco.sh <LXC_ID> — somente leitura
pct exec "$1" -- df -h / 2>&1 | tail -1
