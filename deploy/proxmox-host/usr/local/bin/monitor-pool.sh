#!/bin/bash
# monitor-pool.sh — alerta thin pool pve/data
PCT=$(lvs pve/data --noheadings -o data_percent 2>/dev/null | tr -d ' ')
INT=${PCT%%.*}
LOG=/var/log/monitor-pool.log
ts() { date +'%Y-%m-%d %H:%M:%S'; }
if [ "$INT" -ge 92 ]; then
  echo "$(ts) ALERT pool=${PCT}% - fstrim auto nos CTs" >> "$LOG"
  for ct in 100 101 103 104 105 106 108 109; do
    pct exec $ct -- fstrim -av >/dev/null 2>&1
  done
  NEWP=$(lvs pve/data --noheadings -o data_percent | tr -d ' ')
  echo "$(ts) pos-fstrim pool=${NEWP}%" >> "$LOG"
  /usr/local/bin/telegram-notify "🔴 POOL CRITICO ${PCT}%→${NEWP}% fstrim auto executado" 2>/dev/null
elif [ "$INT" -ge 85 ]; then
  echo "$(ts) WARN pool=${PCT}%" >> "$LOG"
  /usr/local/bin/telegram-notify "🟡 POOL WARN ${PCT}%" 2>/dev/null
fi
