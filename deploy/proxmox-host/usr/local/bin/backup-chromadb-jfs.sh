#!/bin/bash
# ============================================================
# Backup ChromaDB → JuiceFS (substitui o backup tar antigo)
# ============================================================
# Roda como root no HOST Proxmox via cron (04:30 daily).
# JuiceFS garante atomicidade de bloco: USB disconnect no meio
# da operação não corrompe o backup existente.
#
# Estratégia:
#   - rsync delta: só os blocos que mudaram são escritos no USB
#   - Retenção: 7 snapshots de diretório (hardlinks JuiceFS)
#   - Deduplicação implícita: blocos idênticos compartilhados
#   - Compressão zstd aplicada automaticamente pelo JuiceFS
#
# Log: /var/log/ernesto-backup-jfs.log
# ============================================================
set -euo pipefail

LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
trap 'NOTIFY "🔴 [BACKUP] chromadb-jfs: FALHOU em linha $LINENO"' ERR

# ── config ────────────────────────────────────────────────────────────────────
CHROMA_SRC="/mnt/ernesto-data/ernesto-rag/chroma_db"  # ChromaDB mem0 via bind mp0 (LXC101 /opt/ernesto-rag)
JFS_BACKUP_DIR="/mnt/ernesto-data/chroma-backups"              # destino JuiceFS
OLD_BACKUP_DIR="/mnt/ernesto-data/backups/chroma-db"  # backups antigos (tar/rsync simples)
RETENTION_DAYS=7                                       # quantos dias manter
META_DB="sqlite3:///opt/juicefs/meta.db"
MOUNT_POINT="/mnt/ernesto-data"

DATE=$(date +%Y-%m-%d)
DEST="${JFS_BACKUP_DIR}/${DATE}"
LATEST="${JFS_BACKUP_DIR}/latest"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [backup-jfs]"

log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX [WARN] $*" >&2; telegram-notify "⚠️ [BACKUP] chromadb-jfs: $*" 2>/dev/null || true; }
die()  { echo "$LOG_PREFIX [ERR]  $*" >&2; telegram-notify "🔴 [BACKUP] chromadb-jfs: $*" 2>/dev/null || true; exit 1; }

log "=== Iniciando backup ChromaDB → JuiceFS ==="

# ── verificações ──────────────────────────────────────────────────────────────
mountpoint -q "$MOUNT_POINT" \
    || die "JuiceFS não montado em $MOUNT_POINT. Verifique: systemctl status ernesto-jfs"

[[ -d "$CHROMA_SRC" ]] \
    || die "ChromaDB não encontrado em $CHROMA_SRC"

mkdir -p "$JFS_BACKUP_DIR"

# ── rsync delta ───────────────────────────────────────────────────────────────
log "Fonte:  $CHROMA_SRC"
log "Destino: $DEST"

# Se existe backup de hoje, fazer delta sobre ele
# Se existe 'latest', usar como referência para hard-link (dedup)
RSYNC_OPTS=(
    --archive
    --delete
    --delete-excluded
    --human-readable
    --stats
    --no-whole-file      # força checksum, ignora mtime (ChromaDB atualiza mtime sem mudar conteúdo)
    --checksum
)

if [[ -d "$LATEST" ]]; then
    RSYNC_OPTS+=(--link-dest "$LATEST")
    log "Link-dest: $LATEST (economiza espaço com dedup)"
fi

rsync "${RSYNC_OPTS[@]}" "${CHROMA_SRC}/" "${DEST}/"

# Atualizar symlink 'latest'
ln -sfn "$DEST" "$LATEST"
log "Symlink atualizado: $LATEST → $DATE"

# ── tamanho do backup ─────────────────────────────────────────────────────────
BACKUP_SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1 || echo "?")
log "Tamanho do snapshot de hoje: $BACKUP_SIZE"

# ── retenção ──────────────────────────────────────────────────────────────────
log "Aplicando retenção: $RETENTION_DAYS dias"
REMOVED=0
while IFS= read -r -d '' OLD_DIR; do
    OLD_DATE=$(basename "$OLD_DIR")
    # Pular 'latest' (symlink)
    [[ "$OLD_DATE" == "latest" ]] && continue
    # Calcular idade em dias
    if command -v python3 &>/dev/null; then
        AGE=$(python3 -c "
from datetime import date, datetime
try:
    d = datetime.strptime('${OLD_DATE}', '%Y-%m-%d').date()
    print((date.today() - d).days)
except: print(0)
" 2>/dev/null || echo 0)
    else
        AGE=0  # fallback: não deletar se python não disponível
    fi
    if [[ "$AGE" -gt "$RETENTION_DAYS" ]]; then
        log "Removendo backup antigo: $OLD_DATE ($AGE dias)"
        rm -rf "$OLD_DIR"
        ((REMOVED++)) || true
    fi
done < <(find "$JFS_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)
log "Retenção: $REMOVED backup(s) removido(s)"

# ── estatísticas JuiceFS ──────────────────────────────────────────────────────
log "--- JuiceFS I/O stats (último ciclo) ---"
/usr/local/bin/juicefs stats --interval 0 "$MOUNT_POINT" 2>/dev/null \
    | tail -5 || true

# ── garbage collection (semanal — apenas às segundas) ────────────────────────
if [[ $(date +%u) -eq 1 ]]; then
    log "Segunda-feira: rodando GC para limpar blocos órfãos..."
    /usr/local/bin/juicefs gc --delete "$META_DB" 2>&1 | tail -10 || true
    log "GC concluído"
fi

# ── listar snapshots existentes ───────────────────────────────────────────────
log "Snapshots disponíveis:"
find "$JFS_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort | while read -r d; do
    SIZE=$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")
    log "  $(basename "$d")  ($SIZE)"
done

NOTIFY "🟢 [BACKUP] chromadb-jfs: concluído em ${DATE} | ${BACKUP_SIZE:-?} | ${REMOVED:-0} snapshots removidos"
log "=== Backup concluído com sucesso ==="
