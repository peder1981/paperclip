#!/bin/bash
set -e
SSD_PATH=/var/lib/vz/data/ernesto-chroma
USB_BASE=/mnt/ernesto-data/backups/chroma-db
CONFIG_SRC=/opt/ernesto-rag
LOG=/var/log/backup-chromadb.log
RETENTION=7
TIMESTAMP=$(date +%Y-%m-%dT%H%M%S)
echo "[$TIMESTAMP] Iniciando..." >> "$LOG"
if ! mountpoint -q /mnt/ernesto-data; then
  echo "[$TIMESTAMP] USB /mnt/ernesto-data nao montado. Abortando." >> "$LOG"
  exit 1
fi
mkdir -p "$USB_BASE"
TARGET="$USB_BASE/$TIMESTAMP"
echo "[$TIMESTAMP] ChromaDB: $SSD_PATH -> $TARGET" >> "$LOG"
rsync -av --checksum --delete --ignore-errors "$SSD_PATH/" "$TARGET/" >> "$LOG" 2>&1
RC=$?
mkdir -p "$TARGET/config"
cp "$CONFIG_SRC/.env" "$TARGET/config/" 2>/dev/null || true
echo "[$TIMESTAMP] Config copiada" >> "$LOG"
ls -1dt "$USB_BASE"/*/ 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -rf
FILE_COUNT=$(find "$TARGET" -type f 2>/dev/null | wc -l)
if [ "$FILE_COUNT" -gt 0 ]; then
  DEST_SIZE=$(du -sh "$TARGET" 2>/dev/null | cut -f1)
  echo "[$TIMESTAMP] OK: $FILE_COUNT arquivos, $DEST_SIZE, rsync=$RC" >> "$LOG"
  exit 0
else
  echo "[$TIMESTAMP] VAZIO: $FILE_COUNT arquivos, rsync=$RC" >> "$LOG"
  rmdir "$TARGET" 2>/dev/null || true
  exit 1
fi
