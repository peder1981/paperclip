#!/bin/bash
# ============================================================
# backup-ernesto-data.sh — Backup diferencial de dados Ernesto
# Cobre o que vzdump EXCLUI (bind mounts = dados em sdb1):
#   - FAISS index (advpl + dicionario)
#   - JuiceFS metadata (meta.db)
#   - Config essencial (.env, rag_proxy.py, skills/, ui/, mem0/, rag/)
# ChromaDB: coberto por backup-chromadb-jfs.sh (separado)
# Destino: /mnt/jfs/ernesto-data-backups/ (JuiceFS → sdb2 1.6T)
# Retenção: 7 dias de snapshots diferenciais
# ============================================================
set -euo pipefail

LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
trap 'NOTIFY "🔴 [BACKUP] ernesto-data: FALHOU em linha $LINENO"' ERR

BACKUP_BASE="/mnt/jfs/ernesto-data-backups"
DATE=$(date +%Y-%m-%d)
DEST="${BACKUP_BASE}/${DATE}"
LATEST="${BACKUP_BASE}/latest"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [backup-ernesto-data]"
RETENTION_DAYS=7

log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX [WARN] $*" >&2; telegram-notify "⚠️ [BACKUP] ernesto-data: $*" 2>/dev/null || true; }
die()  { echo "$LOG_PREFIX [ERR]  $*" >&2; telegram-notify "🔴 [BACKUP] ernesto-data: $*" 2>/dev/null || true; exit 1; }

log "=== Backup dados Ernesto (FAISS + config + jfs-meta) ==="

# pré-condições
mountpoint -q /mnt/jfs      || die "/mnt/jfs não montado"
mountpoint -q /mnt/ernesto-data || die "/mnt/ernesto-data não montado"

mkdir -p "${BACKUP_BASE}"

rsync_section() {
    local KEY="$1" SRC="$2"
    shift 2
    local DST="${DEST}/${KEY}"

    if [[ ! -d "$SRC" ]]; then
        warn "$KEY: fonte não encontrada ($SRC), pulando"
        return
    fi
    mkdir -p "$DST"
    log "$KEY: $SRC → $DST"

    local PREV=""
    [[ -d "${LATEST}/${KEY}" ]] && PREV="--link-dest ${LATEST}/${KEY}"

    rsync \
        --archive --delete --checksum --no-whole-file \
        --human-readable --stats \
        "$@" $PREV \
        "${SRC}/" "${DST}/" 2>&1 \
        | grep -E "^(Total|Number|sent|speedup)" || true

    SIZE=$(du -sh "$DST" 2>/dev/null | cut -f1 || echo "?")
    log "  → $KEY: $SIZE"
}

# ── 1. FAISS index ────────────────────────────────────────────────────────────
rsync_section "faiss" "/mnt/ernesto-data/ernesto-rag/faiss_index"

# ── 2. Config essencial (sem dados volumosos) ─────────────────────────────────
rsync_section "config" "/mnt/ernesto-data/ernesto-rag" \
    --exclude="faiss_index" \
    --exclude="data" \
    --exclude=".venv" \
    --exclude="venv" \
    --exclude="chroma_db" \
    --exclude="semantic_cache.db" \
    --exclude="__pycache__" \
    --exclude="*.pyc" \
    --exclude="*.pyo" \
    --exclude="*.log"

# ── 3. JuiceFS metadata (meta.db — crítico para montar /mnt/jfs) ─────────────
rsync_section "jfs-meta" "/opt/juicefs" \
    --exclude="cache"

# ── atualizar symlink ─────────────────────────────────────────────────────────
ln -sfn "$DEST" "$LATEST"
log "latest → $DATE"

# ── retenção ─────────────────────────────────────────────────────────────────
log "Retenção: $RETENTION_DAYS dias"
REMOVED=0
while IFS= read -r -d '' OLD_DIR; do
    DNAME=$(basename "$OLD_DIR")
    [[ "$DNAME" == "latest" ]] && continue
    AGE=$(python3 -c "
from datetime import date, datetime
try:
    d = datetime.strptime('${DNAME}', '%Y-%m-%d').date()
    print((date.today() - d).days)
except: print(0)" 2>/dev/null || echo 0)
    if [[ "$AGE" -gt "$RETENTION_DAYS" ]]; then
        log "Removendo: $DNAME ($AGE dias)"
        rm -rf "$OLD_DIR"
        ((REMOVED++)) || true
    fi
done < <(find "$BACKUP_BASE" -maxdepth 1 -mindepth 1 -type d -print0 | sort -z)
log "Retenção: $REMOVED removido(s)"

# ── sumário ───────────────────────────────────────────────────────────────────
log "Snapshots:"
find "$BACKUP_BASE" -maxdepth 1 -mindepth 1 -type d ! -name "latest" | sort | while read -r d; do
    SIZE=$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")
    log "  $(basename "$d")  ($SIZE)"
done
NOTIFY "🟢 [BACKUP] ernesto-data: concluído ${DATE} | ${REMOVED:-0} snapshots removidos"
log "=== Concluído ==="
