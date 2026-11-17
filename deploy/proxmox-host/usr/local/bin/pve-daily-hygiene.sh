#!/bin/bash
# Limpeza diaria: cores appsrvlinux em todos containers docker do 109 + health check PBS
LOG=/var/log/pve-hygiene.log
echo "$(date +%F\ %T) === hygiene ===" >> $LOG
# cores em qualquer appserver dentro de containers do 109
for c in $(pct exec 109 -- docker ps --format "{{.Names}}" 2>/dev/null); do
  pct exec 109 -- docker exec $c rm -f /protheus12/bin/appserver/core.* 2>/dev/null && echo "$c cores limpos" >> $LOG
done
# PBS: garante servicos ativos (se morto, reinicia)
pct exec 100 -- bash -c "systemctl is-active proxmox-backup | grep -q active || systemctl restart proxmox-backup; systemctl is-active proxmox-backup-proxy | grep -q active || systemctl restart proxmox-backup-proxy" 2>/dev/null
pct exec 100 -- systemctl is-active proxmox-backup >> $LOG 2>&1
echo "$(date +%F\ %T) done" >> $LOG
