#!/bin/bash
# Backup incremental do host Proxmox para /mnt/host-backup
set -euo pipefail
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
trap 'NOTIFY "🔴 [BACKUP] host: FALHOU em $BACKUP_DIR (linha $LINENO)"' ERR

DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/mnt/host-backup/host/backup-$DATE"
LATEST_LINK="/mnt/host-backup/host/latest"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [backup-host]"

log()   { echo "$LOG_PREFIX $*"; }

log "=== Iniciando backup do host ==="

mkdir -p "$BACKUP_DIR/etc" "$BACKUP_DIR/boot-efi" "$BACKUP_DIR/lvm"

# rsync incremental (hardlink-dest para economizar espaco)
rsync -aHAXx --delete \
  --link-dest="$LATEST_LINK" \
  /etc/ \
  "$BACKUP_DIR/etc/"

rsync -aHAXx --delete \
  /boot/efi/ \
  "$BACKUP_DIR/boot-efi/"

# Config do cluster Proxmox
tar czf "$BACKUP_DIR/pve-cluster.tar.gz" -C /var/lib pve-cluster

# LVM metadata
vgcfgbackup -f "$BACKUP_DIR/lvm/vg.cfg" pve 2>/dev/null || true

# Atualizar link "latest"
rm -f "$LATEST_LINK"
ln -s "backup-$DATE" "$LATEST_LINK"

# Limpeza: manter 10 backups
ls -dt /mnt/host-backup/host/backup-* 2>/dev/null | tail -n +11 | xargs -r rm -rf || true

SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "?")
NOTIFY "🟢 [BACKUP] host: concluído ${SIZE:-?} — ${BACKUP_DIR}"
