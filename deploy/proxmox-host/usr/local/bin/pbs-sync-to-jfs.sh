#!/bin/bash
# ============================================================
# PBS sync: datastore primary (sdd2) → secondary (JuiceFS)
# ============================================================
# Roda como root no HOST Proxmox via cron (03:30 daily).
# Após o job pbs-daily das 02:00 ter concluído.
#
# Estratégia:
#   - Chunks (content-addressed): rsync --ignore-existing
#     chunks são imutáveis e nomeados por hash — nunca mudam.
#     JuiceFS dedup + zstd comprime blocos idênticos entre backups.
#   - Índices de snapshot (ct/, vm/): rsync normal (pequenos arquivos)
#   - GC-status e metadados: copiados integralmente
#
# Resultado: se sdd2 falhar, PBS pode restaurar CTs do JuiceFS.
# ============================================================
set -euo pipefail

LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
trap 'NOTIFY "🔴 [BACKUP] pbs-sync: FALHOU em linha $LINENO"' ERR

SRC="/mnt/pbs-datastore"
DST="/mnt/jfs/pbs-secondary"
JFS_MOUNT="/mnt/jfs"
LOG_PREFIX="[$(date '+%Y-%m-%d %H:%M:%S')] [pbs-sync]"

log()  { echo "$LOG_PREFIX $*"; }
warn() { echo "$LOG_PREFIX [WARN] $*" >&2; telegram-notify "⚠️ [BACKUP] pbs-sync: $*" 2>/dev/null || true; }
die()  { echo "$LOG_PREFIX [ERR]  $*" >&2; telegram-notify "🔴 [BACKUP] pbs-sync: $*" 2>/dev/null || true; exit 1; }

log "=== Iniciando sync PBS → JuiceFS ==="

# ── verificações ──────────────────────────────────────────────────────────────
mountpoint -q "$JFS_MOUNT" \
    || die "JuiceFS não montado em $JFS_MOUNT"
mountpoint -q "$SRC" \
    || die "PBS datastore primário não montado em $SRC"
[[ -d "${SRC}/.chunks" ]] \
    || die "Chunkstore não encontrado em ${SRC}/.chunks"
[[ -d "${DST}/.chunks" ]] \
    || die "Chunkstore secundário não encontrado em ${DST}/.chunks — rode: pct exec 100 -- proxmox-backup-manager datastore create jfs-secondary /datastore-jfs"

# ── 1. Chunks — imutáveis, usar --ignore-existing ─────────────────────────────
log "Sincronizando chunks (--ignore-existing)..."
CHUNKS_BEFORE=$(find "${DST}/.chunks" -type f 2>/dev/null | wc -l)

rsync \
    --archive \
    --ignore-existing \
    --human-readable \
    --stats \
    "${SRC}/.chunks/" "${DST}/.chunks/" \
    2>&1 | grep -E 'files transferred|bytes|speedup|Number of' | while read -r line; do
        log "  chunks: $line"
    done

CHUNKS_AFTER=$(find "${DST}/.chunks" -type f 2>/dev/null | wc -l)
log "Chunks: $CHUNKS_BEFORE → $CHUNKS_AFTER (+$((CHUNKS_AFTER - CHUNKS_BEFORE)) novos)"

# ── 2. Índices de snapshot (CT) ───────────────────────────────────────────────
if [[ -d "${SRC}/ct" ]]; then
    log "Sincronizando índices CT..."
    rsync --archive --delete --human-readable "${SRC}/ct/" "${DST}/ct/" \
        2>&1 | tail -3 | while read -r l; do log "  ct: $l"; done
fi

# ── 3. Índices de snapshot (VM) ───────────────────────────────────────────────
if [[ -d "${SRC}/vm" ]]; then
    log "Sincronizando índices VM..."
    rsync --archive --delete --human-readable "${SRC}/vm/" "${DST}/vm/" \
        2>&1 | tail -3 | while read -r l; do log "  vm: $l"; done
fi

# ── 4. Metadados do datastore ─────────────────────────────────────────────────
log "Sincronizando metadados..."
for f in .gc-status .lock; do
    [[ -f "${SRC}/${f}" ]] && cp -p "${SRC}/${f}" "${DST}/${f}" || true
done

# ── 5. Estatísticas ───────────────────────────────────────────────────────────
SRC_SIZE=$(du -sh "${SRC}" 2>/dev/null | cut -f1)
DST_SIZE=$(du -sh "${DST}" 2>/dev/null | cut -f1)
JFS_USED=$(df -h "${JFS_MOUNT}" 2>/dev/null | awk 'NR==2 {print $3}')
log "Primário (sdd2 XFS):  $SRC_SIZE"
log "Secundário (JuiceFS): $DST_SIZE"
log "JuiceFS total usado:  $JFS_USED"

NOTIFY "🟢 [BACKUP] pbs-sync: concluído | primário ${SRC_SIZE:-?} → secundário ${DST_SIZE:-?}"
log "=== Sync PBS → JuiceFS concluído ==="
