#!/bin/sh
# Registra temperaturas do host em CSV (CPU, GPU integrada, discos SMART)
LOG=/var/log/temp-monitor.csv
[ -f "$LOG" ] || echo "timestamp,cpu_tctl,gpu_edge,sda_c,sdb_c" > "$LOG"
S=$(sensors -u 2>/dev/null)
CPU=$(echo "$S" | awk "/^k10temp/{b=\"cpu\"} /^amdgpu/{b=\"gpu\"} /^\$/{b=\"\"} b==\"cpu\" && /temp1_input/{printf \"%.1f\", \$2; exit}")
GPU=$(echo "$S" | awk "/^amdgpu/{g=1} /^\$/{g=0} g && /temp1_input/{printf \"%.1f\", \$2; exit}")
SDA=$(smartctl -A /dev/sda 2>/dev/null | awk "\$1==194{print \$10}")
SDB=$(smartctl -A /dev/sdb 2>/dev/null | awk "\$1==194{print \$10}")
echo "$(date +%FT%T),${CPU:-},${GPU:-},${SDA:-},${SDB:-}" >> "$LOG"
