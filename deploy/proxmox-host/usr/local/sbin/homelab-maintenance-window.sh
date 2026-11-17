#!/usr/bin/env bash
# homelab-maintenance-window — JANELA DE MANUTENCAO A CADA 5 DIAS
#
# Orquestra, em sequencia:
#   FASE 1  limpeza interna online em todos os CTs (ct-disk-maintenance.sh)
#   FASE 2  blu.db-wal: restart litestream + wal_checkpoint(TRUNCATE)
#   FASE 3  RECLAIM de espaco:
#             - privileged c/ thin   -> fstrim vivo so no / (nao toca binds)
#             - unprivileged         -> shutdown -> trim LV/raw no host -> start
#             - raw em dir (104/106) -> loop mount + fstrim (punch hole)
#             - dir rootfs (101)     -> nada (delecoes ja liberam o host)
#   FASE 4  verificacao: todos running + df final
#
# Uso: homelab-maintenance-window.sh [--dry-run]
# Cron: 30 3 */5 * * root /usr/local/sbin/homelab-maintenance-window.sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

LOG=/var/log/homelab-maintenance-window.log
LOCK=/run/homelab-maintenance-window.lock
MNT_BASE=/mnt/ct-trim
SHUTDOWN_TIMEOUT=120
mkdir -p "$MNT_BASE"

log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
act(){ if [ "$DRY_RUN" = 1 ]; then log "DRY: $*"; else eval "$*"; fi; }

exec 9>"$LOCK"
flock -n 9 || { log "outra janela em execucao — saindo"; exit 0; }

ct_running(){ [ "$(pct status "$1" 2>/dev/null | awk '{print $2}')" = "running" ]; }
ct_unpriv(){ pct config "$1" 2>/dev/null | grep -q '^unprivileged: 1'; }

thin_devs(){ # volumes local-lvm do CT -> /dev/pve/...
  pct config "$1" 2>/dev/null | grep -oE 'local-lvm:vm-[0-9]+-disk-[0-9]+' \
    | sed 's|local-lvm:|/dev/pve/|' | sort -u
}

raw_path(){ # rootfs .raw em dir storage -> path real no host (via pvesm path)
  local vol
  vol=$(pct config "$1" 2>/dev/null | grep '^rootfs:' | head -1 \
        | sed 's/^rootfs: *//' | cut -d, -f1)
  case "$vol" in
    *.raw) pvesm path "$vol" 2>/dev/null ;;
    *) echo "" ;;
  esac
}

# ---------- FASE 1: limpeza interna online ----------
log "=== JANELA inicio (dry=$DRY_RUN) ==="
log "fase 1/4: limpeza interna nos CTs (ct-disk-maintenance)"
if [ "$DRY_RUN" = 1 ]; then
  log "DRY: /usr/local/sbin/ct-disk-maintenance.sh --dry-run"
else
  /usr/local/sbin/ct-disk-maintenance.sh >>"$LOG" 2>&1 \
    && log "fase 1 ok" || log "fase 1 com erros (ver log)"
fi

# ---------- FASE 2: blu.db-wal ----------
log "fase 2/4: blu.db-wal (CT104)"
wal_size=$(pct exec 104 -- stat -c%s /opt/blu/blu.db-wal 2>/dev/null || echo 0)
if [ "${wal_size:-0}" -gt 1073741824 ]; then
  log "wal=${wal_size}B (>1G) — restart litestream + checkpoint"
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY: pct exec 104 systemctl restart litestream; wal_checkpoint(TRUNCATE)"
  else
    pct exec 104 -- systemctl restart litestream >/dev/null 2>&1
    sleep 5
    res=$(pct exec 104 -- python3 -c "
import sqlite3
c=sqlite3.connect('/opt/blu/blu.db', timeout=180, isolation_level=None)
c.execute('PRAGMA busy_timeout=180000')
print(c.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone())
c.close()" 2>/dev/null | tail -1)
    log "checkpoint resultado: ${res:-falhou}"
    sleep 3
    pct exec 104 -- ls -lh /opt/blu/blu.db-wal 2>/dev/null | sed 's/^/wal agora: /' | tee -a "$LOG"
  fi
else
  log "wal=${wal_size}B — nada a fazer"
fi

# ---------- FASE 3: reclaim ----------
log "fase 3/4: reclaim de espaco (stop-trim unpriv + live-trim priv + raw)"

trim_thin_stopped(){ # $1=ct — CT ja desligado; monta cada LV thin e fstrima
  local ct="$1" dev mnt out=""
  for dev in $(thin_devs "$ct"); do
    mnt="${MNT_BASE}/${ct}-$(basename "$dev")"
    mkdir -p "$mnt"
    if [ "$DRY_RUN" = 1 ]; then log "DRY: mount $dev $mnt; fstrim; umount"; continue; fi
    lvchange -ay "$dev" >/dev/null 2>&1
    if mount "$dev" "$mnt" 2>>"$LOG"; then
      out="$out $(fstrim -v "$mnt" 2>&1 | grep -oE '[0-9.]+ [A-Z]iB' | head -1)"
      umount "$mnt" && rmdir "$mnt" 2>/dev/null
    else
      log "CT$ct: FALHOU mount $dev"
    fi
  done
  [ "$DRY_RUN" = 1 ] || log "CT$ct thin-trim:${out:- (sem volumes thin)}"
}

trim_raw_stopped(){ # $1=ct — raw file em dir storage; loop mount + fstrim
  local ct="$1" raw mnt="${MNT_BASE}/raw-$1" out
  raw=$(raw_path "$ct")
  [ -z "$raw" ] && return 0
  [ -f "$raw" ] || { log "CT$ct: raw $raw nao existe no host"; return 0; }
  mkdir -p "$mnt"
  if [ "$DRY_RUN" = 1 ]; then log "DRY: loop mount $raw $mnt; fstrim; umount"; return 0; fi
  if mount -o loop,discard,rw "$raw" "$mnt" 2>>"$LOG"; then
    out=$(fstrim -v "$mnt" 2>&1 | grep -oE '[0-9.]+ [A-Z]iB' | head -1)
    umount "$mnt" && rmdir "$mnt" 2>/dev/null
    log "CT$ct raw-trim:${out:- (nada)}"
  else
    log "CT$ct: FALHOU loop+discard mount $raw — tentando sem discard"
    if mount -o loop,rw "$raw" "$mnt" 2>>"$LOG"; then
      out=$(fstrim -v "$mnt" 2>&1 | grep -oE '[0-9.]+ [A-Z]iB' | head -1)
      umount "$mnt" && rmdir "$mnt" 2>/dev/null
      log "CT$ct raw-trim(nodiscard):${out:- (nada)}"
    else
      log "CT$ct: FALHOU mount raw $raw"
    fi
  fi
}

live_trim_root(){ # $1=ct privileged — fstrim so em / (evita binds gigantes)
  local ct="$1" out
  ct_running "$ct" || return 0
  if [ "$DRY_RUN" = 1 ]; then log "DRY: pct exec $ct -- fstrim -v /"; return 0; fi
  out=$(timeout 300 pct exec "$ct" -- fstrim -v / 2>&1 | grep -oE '[0-9.]+ [A-Z]iB' | head -1)
  log "CT$ct live-trim: ${out:-nada}"
}

# unprivileged: shutdown -> trim -> start (sequencial)
for ct in $(pct list 2>/dev/null | awk 'NR>1{print $1}' | sort -n); do
  ct_unpriv "$ct" || continue
  thin_devs "$ct" | grep -q . || [ -n "$(raw_path "$ct")" ] || continue
  ct_running "$ct" || { log "CT$ct unpriv parado — skip"; continue; }
  log "CT$ct: shutdown para trim (timeout ${SHUTDOWN_TIMEOUT}s)…"
  act "pct shutdown $ct --timeout $SHUTDOWN_TIMEOUT >/dev/null 2>&1"
  if [ "$DRY_RUN" = 0 ]; then
    sleep 2
    pct status "$ct" 2>/dev/null | grep -q running && act "pct stop $ct >/dev/null 2>&1"
    sleep 2
    ct_running "$ct" && { log "CT$ct NAO parou — abortando trim (nunca montar fs viva)"; continue; }
  fi
  trim_thin_stopped "$ct"
  trim_raw_stopped "$ct"
  act "pct start $ct >/dev/null 2>&1"
  [ "$DRY_RUN" = 0 ] && { sleep 5; ct_running "$ct" && log "CT$ct de volta running" || log "CT$ct ATENCAO: nao subiu"; }
done

# privileged com volume thin: live-trim so no /
for ct in $(pct list 2>/dev/null | awk 'NR>1{print $1}' | sort -n); do
  ct_unpriv "$ct" && continue
  thin_devs "$ct" | grep -q . || continue
  live_trim_root "$ct"
done

# ---------- FASE 4: verificacao ----------
log "fase 4/4: verificacao"
for ct in $(pct list 2>/dev/null | awk 'NR>1{print $1}' | sort -n); do
  if [ "$DRY_RUN" = 0 ]; then
    st=$(pct status "$ct" 2>/dev/null | awk '{print $2}')
    log "CT$ct: $st"
  fi
done
log "host df: $(df -h / | awk 'NR==2{print $4" livres, "$5" usado"}') pool-data: $(lvs --noheadings -o data_percent pve/data 2>/dev/null | tr -d ' ')%"
log "=== JANELA fim ==="
