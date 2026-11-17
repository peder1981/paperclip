#!/bin/bash
# Watchdog anti-acumulo de issues recorrentes (paperclip)
# Mantem 1 instancia aberta por (origin_id, fingerprint); libera locks fantasmas.
LOG=/var/lib/paperclip/maintenance/dedupe.log
mkdir -p "$(dirname "$LOG")"
{
  echo "=== $(date -Is) dedupe run ==="
  su postgres -c "psql -d paperclip -f /var/lib/paperclip/maintenance/routine_dedupe.sql" 2>&1
} >> "$LOG" 2>&1
