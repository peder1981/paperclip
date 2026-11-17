#!/usr/bin/env bash
# ct-thin-trim — reclaim rotativo do thin pool pve/data para LXC
#
# - CTs privileged: fstrim vivo a cada execucao (sem downtime)
# - CTs unprivileged: UM por execucao, em rotacao (arquivo de estado):
#   shutdown -> mount LV -> fstrim -> umount -> start
# - Garante mountoptions=discard nos rootfs unprivileged (trim continuo
#   no futuro — discard do kernel nao depende do ioctl FITRIM)
#
# Uso: ct-thin-trim.sh [--dry-run] [--ct <id>] [--all-unpriv]
# Cron sugerido: 15 4 * * * root /usr/local/sbin/ct-thin-trim.sh
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

POOL_LV_PREFIX="/dev/pve/vm-"
STATE_DIR="/var/lib/ct-thin-trim"
STATE_FILE="$STATE_DIR/last-ctid"
LOCK_FILE="/run/ct-thin-trim.lock"
LOG_FILE="/var/log/ct-thin-trim.log"
MNT_BASE="/mnt/ct-trim"
SHUTDOWN_TIMEOUT=90

DRY_RUN=0
FORCE_CT=""
ALL_UNPRIV=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --all-unpriv) ALL_UNPRIV=1 ;;
    --ct) : ;;
    *) if [ "${FORCE_CT:-}" = "" ] && [ "${prev:-}" = "--ct" ]; then FORCE_CT="$arg"; fi ;;
  esac
  prev="$arg"
done

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG_FILE"; }
run() { if [ "$DRY_RUN" = 1 ]; then log "DRY: $*"; else eval "$@"; fi; }

exec 9>"$LOCK_FILE"
flock -n 9 || { log "outra instancia em execucao — saindo"; exit 0; }
mkdir -p "$STATE_DIR" "$MNT_BASE"

ct_list() { pct list 2>/dev/null | awk 'NR>1 {print $1}'; }
ct_running() { [ "$(pct status "$1" 2>/dev/null | awk '{print $2}')" = "running" ]; }
ct_unpriv() { pct config "$1" 2>/dev/null | grep -q '^unprivileged: 1'; }

# volumes lvm-thin de um CT -> device paths
ct_thin_devs() {
  pct config "$1" 2>/dev/null | grep -oE 'local-lvm:vm-[0-9]+-disk-[0-9]+' \
    | sed 's|local-lvm:|/dev/pve/|' | sort -u
}

ensure_discard() {
  local ct="$1" line vol opts newopts
  line=$(pct config "$ct" 2>/dev/null | grep '^rootfs:') || return 0
  case "$line" in *local-lvm:*) ;; *) return 0 ;; esac
  case "$line" in *discard*) return 0 ;; esac
  vol=$(echo "$line" | grep -oE 'local-lvm:[^,]+')
  opts=$(echo "$line" | grep -oE ',.*' | tr -d ' ')
  case "$opts" in
    *mountoptions=*) newopts=$(echo "$opts" | sed 's/mountoptions=\([^,;]*\)/mountoptions=\1;discard/') ;;
    *) newopts="$opts,mountoptions=discard" ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then log "DRY: pct set $ct -rootfs $vol$newopts"; return 0; fi
  pct set "$ct" -rootfs "$vol$newopts" >/dev/null 2>&1 \
    && log "CT$ct: mountoptions=discard ativado (vale no proximo start)" \
    || log "CT$ct: FALHOU set mountoptions (segue assim mesmo)"
}

live_trim() {
  local ct="$1" out
  ct_running "$ct" || { log "CT$ct: parado, pulando live-trim"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then log "DRY: pct exec $ct -- fstrim -av"; return 0; fi
  out=$(pct exec "$ct" -- fstrim -av 2>&1 | grep -oE 'trimmed on .*|[0-9.]+ [A-Z]iB .*trimmed' | head -3)
  log "CT$ct live-trim: ${out:-nada}"
}

trim_one_stopped() {
  local ct="$1" dev mnt rc=0 trimmed=""
  for dev in $(ct_thin_devs "$ct"); do
    mnt="${MNT_BASE}/${ct}-$(basename "$dev")"
    mkdir -p "$mnt"
    if [ "$DRY_RUN" = 1 ]; then log "DRY: mount $dev $mnt; fstrim -v $mnt; umount $mnt"; continue; fi
    lvchange -ay "$dev" >/dev/null 2>&1
    if ! mount "$dev" "$mnt" 2>>"$LOG_FILE"; then
      log "CT$ct: FALHOU mount $dev — pulando"; rc=1; continue
    fi
    trimmed="$trimmed $(fstrim -v "$mnt" 2>&1 | grep -oE '[0-9.]+ [A-Z]iB')"
    umount "$mnt" || rc=1
    rmdir "$mnt" 2>/dev/null
  done
  log "CT$ct stop-trim:${trimmed:- (sem volumes thin)}"
  return $rc
}

reclaim_ct() {
  local ct="$1" was=0
  ensure_discard "$ct"
  ct_running "$ct" && was=1
  if [ "$was" = 1 ]; then
    log "CT$ct: desligando (timeout ${SHUTDOWN_TIMEOUT}s)…"
    run "pct shutdown $ct --timeout $SHUTDOWN_TIMEOUT >/dev/null 2>&1"
    ct_running "$ct" && run "pct stop $ct >/dev/null 2>&1"
  fi
  if ct_running "$ct" && [ "$DRY_RUN" = 0 ]; then
    log "CT$ct: NAO parou — reclaim abortado por seguranca (nunca montar fs viva)"
    return 1
  fi
  trim_one_stopped "$ct"
  if [ "$was" = 1 ]; then
    run "pct start $ct >/dev/null 2>&1"
    sleep 3
    ct_running "$ct" && log "CT$ct: de volta running" || log "CT$ct: ATENCAO nao subiu"
  fi
}

next_in_rotation() {
  local last="" cts sorted
  [ -f "$STATE_FILE" ] && last=$(cat "$STATE_FILE")
  sorted=$(for c in $@; do echo "$c"; done | sort -n | tr '\n' ' ')
  for c in $sorted; do if [ -n "$last" ] && [ "$c" -gt "$last" ]; then echo "$c"; return; fi; done
  echo "$sorted" | awk '{print $1}'
}

log "=== ct-thin-trim iniciado $(date '+%F %T') ==="

UNPRIV="" PRIV=""
for ct in $(ct_list); do
  if ct_unpriv "$ct"; then UNPRIV="$UNPRIV $ct"; else PRIV="$PRIV $ct"; fi
done

# privileged: trim vivo toda execucao
for ct in $PRIV; do
  if ct_thin_devs "$ct" | grep -q .; then live_trim "$ct"; fi
done

# unprivileged: rotacao (ou forcado via --ct / --all-unpriv)
if [ -n "$FORCE_CT" ]; then
  reclaim_ct "$FORCE_CT"
elif [ "$ALL_UNPRIV" = 1 ]; then
  for ct in $UNPRIV; do reclaim_ct "$ct"; done
else
  target=$(next_in_rotation $UNPRIV)
  [ -n "$target" ] && reclaim_ct "$target" && echo "$target" > "$STATE_FILE"
fi

log "=== fim: pool $(lvs --noheadings -o data_percent pve/data 2>/dev/null | tr -d ' ')% data ==="
