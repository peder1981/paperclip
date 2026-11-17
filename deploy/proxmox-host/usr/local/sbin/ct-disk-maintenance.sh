#!/usr/bin/env bash
# ct-disk-maintenance — higiene de disco DENTRO dos LXC + vacuum sqlite/postgres
#
# Complementa (nao substitui):
#   - ct-thin-trim.sh        -> fstrim/trim do thin pool (noturno)
#   - host-hygiene-weekly.sh -> journal/apt/logs do HOST (semanal)
#   - pve-daily-hygiene.sh   -> cores appserver no CT109 + health PBS
#
# Este script roda a cada 3 dias e faz, POR CONTAINER:
#   - journalctl --vacuum-size
#   - remove logs rotacionados antigos e trunca logs ativos gigantes
#   - remove core dumps (/var/lib/systemd/coredump, /var/crash)
#   - apt/dnf clean, cache pip, temporarios velhos em /tmp|/var/tmp
#   - remove duckdb_temp_storage_*.tmp orfaos
#   - sqlite: wal_checkpoint(TRUNCATE) em todos; VACUUM somente quando
#     freelist > SQLITE_VACUUM_MIN_FREELIST_MB E ha espaco de sobra
#   - postgres: VACUUM ANALYZE em todos os databases dos clusters online
#     (VACUUM FULL opcional via PG_VACUUM_FULL=1 — trava tabelas)
#   - docker: system/builder prune + trunca *-json.log gigantes
#
# No HOST: journal vacuum, logs rotacionados >30d, coredumps, apt clean.
#
# Uso: ct-disk-maintenance.sh [--dry-run] [--ct <id>]
# Cron:  37 5 */3 * * root /usr/local/sbin/ct-disk-maintenance.sh
# Config: /etc/ct-disk-maintenance.conf (opcional, ver template abaixo)
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

CONF=/etc/ct-disk-maintenance.conf
[ -f "$CONF" ] && . "$CONF"

DRY_RUN=0
ONLY_CT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --ct) shift; ONLY_CT="${1:-}" ;;
    *) echo "uso: $0 [--dry-run] [--ct <id>]" >&2; exit 2 ;;
  esac
  shift
done

LOG=/var/log/ct-disk-maintenance.log
LOCK=/run/ct-disk-maintenance.lock
STATE_DIR=/var/lib/ct-disk-maintenance
GUEST_SRC=/tmp/.ct-guest-maint.sh
TIMEOUT_PER_CT="${TIMEOUT_PER_CT:-3600}"
HOST_JOURNAL_MAX="${HOST_JOURNAL_MAX:-300M}"
HOST_LOG_DAYS="${HOST_LOG_DAYS:-30}"

mkdir -p "$STATE_DIR"
log(){ echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
act(){ if [ "$DRY_RUN" = 1 ]; then log "DRY: $*"; else eval "$*"; fi; }

exec 9>"$LOCK"
flock -n 9 || { log "outra instancia em execucao — saindo"; exit 0; }

# ---------- utilitarios host ----------
root_avail_kb(){ df -Pk / | awk 'NR==2{print $4}'; }

pool_avail_kb(){
  lvs pve/data >/dev/null 2>&1 || { echo 0; return; }
  local psz pct
  read -r psz pct < <(lvs --noheadings --units k -o lv_size,data_percent pve/data 2>/dev/null)
  psz=${psz%k}
  [ -z "${psz:-}" ] && { echo 0; return; }
  awk -v s="$psz" -v p="${pct:-0}" 'BEGIN{printf "%d", s*(100-p)/100}'
}

# REAL_AVAIL_KB injetado no guest: teto de espaco real para o filesystem do CT.
#  - rootfs local-lvm (thin)      -> avail do pool pve/data
#  - rootfs local:* / dir (raw)   -> avail do / do host (o .raw vive no root)
#  - rootfs dir em /var/lib/vz    -> 0 (df dentro do CT ja e real)
ct_real_avail(){
  local ct="$1" line
  line=$(pct config "$ct" 2>/dev/null | grep '^rootfs:' | head -1)
  case "$line" in
    *local-lvm:*) echo "${POOL_AVAIL_KB:-0}" ;;
    *local:*|*/var/lib/vz/*) echo "${ROOT_AVAIL_KB:-0}" ;;
    *) echo 0 ;;
  esac
}

ct_running(){ [ "$(pct status "$1" 2>/dev/null | awk '{print $2}')" = "running" ]; }

# ---------- guest script (enviado via pct push) ----------
write_guest_script(){
cat > "$GUEST_SRC" <<'GUEST_EOF'
#!/usr/bin/env bash
# ct-guest-maintenance — executado DENTRO do LXC via pct exec.
# Fonte canonica: /usr/local/sbin/ct-disk-maintenance.sh (host Proxmox).
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

DRY_RUN="${DRY_RUN:-0}"
REAL_AVAIL_KB="${REAL_AVAIL_KB:-0}"          # 0 = df local e confiavel
JOURNAL_VACUUM_SIZE="${JOURNAL_VACUUM_SIZE:-200M}"
LOG_ROT_DAYS="${LOG_ROT_DAYS:-14}"
LOG_TRUNC_MB="${LOG_TRUNC_MB:-200}"
SQLITE_MIN_MB="${SQLITE_MIN_MB:-20}"
SQLITE_VACUUM_MIN_FREELIST_MB="${SQLITE_VACUUM_MIN_FREELIST_MB:-256}"
SQLITE_EXCLUDE_REGEX="${SQLITE_EXCLUDE_REGEX:-^/(datastore|datastore-jfs)(/|$)}"
SQLITE_SCAN_TIMEOUT="${SQLITE_SCAN_TIMEOUT:-180}"
MIN_FREE_AFTER_VACUUM_GB="${MIN_FREE_AFTER_VACUUM_GB:-6}"
PG_VACUUM_FULL="${PG_VACUUM_FULL:-0}"
DOCKER_PRUNE="${DOCKER_PRUNE:-1}"
SQLITE_TIMEOUT="${SQLITE_TIMEOUT:-600}"
PG_TIMEOUT="${PG_TIMEOUT:-900}"
TMP_MAX_DAYS="${TMP_MAX_DAYS:-7}"

log(){ echo "GUEST|$*"; }
act(){ if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: $*"; else eval "$*"; fi; }

df_avail_kb(){ df -Pk "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# espaço real disponível para um arquivo: min(df do filesystem, teto do host)
real_avail_for(){
  local f="$1" a
  a=$(df_avail_kb "$f")
  [ -z "$a" ] && { echo 0; return; }
  if [ "${REAL_AVAIL_KB:-0}" != 0 ] && [ "$REAL_AVAIL_KB" -lt "$a" ]; then a=$REAL_AVAIL_KB; fi
  echo "$a"
}

delete_list(){ # $1=descricao ; stdin=lista de paths
  local desc="$1" n=0 f
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  n=$(wc -l < "$tmp")
  [ "$n" = 0 ] && { rm -f "$tmp"; return 0; }
  if [ "$DRY_RUN" = 1 ]; then
    log "DRY-DEL[$desc]: $n arquivo(s)"
    head -20 "$tmp" | sed 's/^/  /'
    [ "$n" -gt 20 ] && log "  ... (+$((n-20)) outros)"
  else
    log "$desc: removendo $n arquivo(s)"
    tr '\n' '\0' < "$tmp" | xargs -0 -r rm -f
  fi
  rm -f "$tmp"
}

truncate_list(){ # $1=padrao de nome ; stdin=paths grandes
  local pat="$1" f sz freed=0
  if [ "$DRY_RUN" = 1 ]; then
    while read -r f; do [ -n "$f" ] && log "DRY-TRUNC[$pat]: $f ($(du -h "$f" 2>/dev/null | cut -f1))"; done
    return 0
  fi
  while read -r f; do
    [ -z "$f" ] && continue
    sz=$(stat -c%s "$f" 2>/dev/null) || continue
    truncate -s 0 "$f" 2>/dev/null && freed=$((freed+sz))
  done
  [ "$freed" -gt 0 ] && log "TRUNC[$pat]: liberado $((freed/1048576)) MB"
}

log "=== inicio manutencao guest (dry=$DRY_RUN real_avail_kb=${REAL_AVAIL_KB:-0}) ==="
log "df: $(df -h / | awk 'NR==2{print $4" livres de "$2}')"

# ---------- 1. journal ----------
before=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | tail -1)
act "journalctl --vacuum-size=$JOURNAL_VACUUM_SIZE >/dev/null 2>&1"
after=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[MG]' | tail -1)
log "journal: ${before:-?} -> ${after:-?} (max $JOURNAL_VACUUM_SIZE)"

# ---------- 2. logs rotacionados antigos ----------
find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.old' \) \
  -mtime +"$LOG_ROT_DAYS" -print 2>/dev/null | delete_list "logs-rotacionados>${LOG_ROT_DAYS}d"

# ---------- 3. logs ativos gigantes -> truncate ----------
find /var/log -xdev -type f \( -name '*.log' -o -name '*.out' -o -name '*-json.log' \) \
  -size +"${LOG_TRUNC_MB}M" -print 2>/dev/null | truncate_list "var-log"

# ---------- 4. core dumps ----------
{ find /var/lib/systemd/coredump -xdev -type f -print 2>/dev/null
  find /var/crash -xdev -type f -print 2>/dev/null
} | delete_list "core-dumps"

# ---------- 5. caches de pacote / pip ----------
act "apt-get clean >/dev/null 2>&1"
command -v dnf >/dev/null 2>&1 && act "dnf clean all >/dev/null 2>&1"
command -v yum >/dev/null 2>&1 && act "yum clean all >/dev/null 2>&1"
for d in /root/.cache/pip /home/*/.cache/pip; do
  [ -d "$d" ] && act "rm -rf $d"
done

# ---------- 6. temporarios velhos ----------
find /tmp /var/tmp -xdev -type f -mtime +"$TMP_MAX_DAYS" -print 2>/dev/null | delete_list "tmp>${TMP_MAX_DAYS}d"

# ---------- 7. temps orfaos duckdb ----------
find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /var/lib/docker \) -prune \
  -o -type f -name 'duckdb_temp_storage_*.tmp' -mtime +1 -print 2>/dev/null | delete_list "duckdb-tmp"

# ---------- 8. sqlite: checkpoint + vacuum condicional ----------
if command -v python3 >/dev/null 2>&1; then
  # um filesystem real por vez (evita duplicar mounts aninhados);
  # mounts que casam SQLITE_EXCLUDE_REGEX (ex.: datastore PBS) sao pulados;
  # timeout por mount evita ficar preso varrendo arquivos em massa
  mounts=$(findmnt -rn -o TARGET,FSTYPE 2>/dev/null \
    | awk -v re="$SQLITE_EXCLUDE_REGEX" '$2 ~ /^(ext4|xfs|btrfs|f2fs)$/ && $1 !~ re {print $1}' \
    | sort -u)
  cand_file=$(mktemp)
  : > "$cand_file"
  for mp in $mounts; do
    timeout "$SQLITE_SCAN_TIMEOUT" find "$mp" -xdev -type f \
      \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db3' \) \
      -size +"${SQLITE_MIN_MB}M" -print 2>/dev/null >> "$cand_file"
  done
  sort -u "$cand_file" -o "$cand_file"
  total=$(wc -l < "$cand_file")
  log "sqlite: $total candidato(s) >${SQLITE_MIN_MB}M"

  i=0
  while IFS= read -r db; do
    i=$((i+1))
    [ -z "$db" ] && continue
    # ---- inspect (page stats) ----
    info=$(python3 - "$db" <<'PY' 2>/dev/null
import sqlite3,sys
try:
    c=sqlite3.connect(sys.argv[1], timeout=20)
    pc=c.execute("PRAGMA page_count").fetchone()[0]
    fl=c.execute("PRAGMA freelist_count").fetchone()[0]
    ps=c.execute("PRAGMA page_size").fetchone()[0]
    c.close()
    print(pc*ps, fl*ps)
except Exception as e:
    print("ERR", e)
PY
)
    case "$info" in
      ERR*|"") log "sqlite[$i] SKIP(inspect): $db — ${info:-sem saida}"; continue ;;
    esac
    db_bytes=${info%% *}; free_bytes=${info##* }
    fsize=$(stat -c%s "$db" 2>/dev/null || echo "$db_bytes")
    free_mb=$((free_bytes/1048576)); size_mb=$((fsize/1048576))

    # ---- checkpoint WAL sempre que possivel (libera o -wal) ----
    if [ "$DRY_RUN" = 1 ]; then
      log "sqlite[$i] DRY-CHECKPOINT: $db (${size_mb}M)"
      ck="DRY"
    else
    ck=$(python3 - "$db" <<'PY' 2>/dev/null
import sqlite3,sys
try:
    c=sqlite3.connect(sys.argv[1], timeout=30, isolation_level=None)
    c.execute("PRAGMA busy_timeout=30000")
    r=c.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
    c.close()
    print("CKPT", r[0], r[1], r[2])
except Exception as e:
    print("ERR", e)
PY
)
    fi
    # ck = "CKPT busy log ckpt" — busy=1 significa reader segurando o WAL
    case "$ck" in
      CKPT\ 0*|DRY) ;;
      CKPT\ 1*) log "sqlite[$i] checkpoint OCUPADO (reader no WAL): $db ($ck)" ;;
      *) log "sqlite[$i] checkpoint falhou: $db — $ck" ;;
    esac

    # ---- decisao de VACUUM ----
    if [ "$free_mb" -lt "$SQLITE_VACUUM_MIN_FREELIST_MB" ]; then
      log "sqlite[$i] skip-vacuum (freelist ${free_mb}M < ${SQLITE_VACUUM_MIN_FREELIST_MB}M): $db (${size_mb}M)"
      continue
    fi
    avail=$(real_avail_for "$db")
    # necessidade estimada: novo arquivo ~ tamanho atual + 20% margem + 1G
    need_kb=$(( fsize/1024 + fsize/5120 + 1048576 ))
    min_after_kb=$(( MIN_FREE_AFTER_VACUUM_GB * 1024 * 1024 ))
    if [ $(( avail - need_kb )) -lt "$min_after_kb" ]; then
      log "sqlite[$i] skip-vacuum (espaco): $db ${size_mb}M freelist=${free_mb}M avail=${avail}K need=${need_kb}K"
      continue
    fi
    if [ "$DRY_RUN" = 1 ]; then
      log "DRY-VACUUM: $db ${size_mb}M freelist=${free_mb}M avail=${avail}K"
      continue
    fi
    before_sz=$fsize
    if timeout "$SQLITE_TIMEOUT" python3 - "$db" <<'PY' 2>/dev/null
import sqlite3,sys
c=sqlite3.connect(sys.argv[1], timeout=60, isolation_level=None)
c.execute("PRAGMA busy_timeout=60000")
c.execute("VACUUM")
c.close()
PY
    then
      after_sz=$(stat -c%s "$db" 2>/dev/null || echo "$before_sz")
      log "sqlite[$i] VACUUM ok: $db ${size_mb}M -> $((after_sz/1048576))M (freelist era ${free_mb}M)"
    else
      log "sqlite[$i] VACUUM falhou/timeout: $db (${size_mb}M)"
    fi
  done < "$cand_file"
  rm -f "$cand_file"
else
  log "sqlite: python3 ausente — pulando"
fi

# ---------- 9. postgres ----------
if command -v pg_lsclusters >/dev/null 2>&1; then
  pg_lsclusters 2>/dev/null | awk '$4=="online"{print $3, $1}' | while read -r port ver; do
    dbs=$(runuser -u postgres -- psql -p "$port" -d postgres -tAc \
      "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate" 2>/dev/null)
    [ -z "$dbs" ] && { log "pg${ver} port=$port: nenhum db acessivel"; continue; }
    for db in $dbs; do
      if [ "$DRY_RUN" = 1 ]; then
        log "DRY-PG: VACUUM ANALYZE ${ver}/port${port}/db=$db"
        continue
      fi
      if [ "$PG_VACUUM_FULL" = 1 ]; then
        sql="VACUUM FULL ANALYZE"
      else
        sql="VACUUM ANALYZE"
      fi
      if timeout "$PG_TIMEOUT" runuser -u postgres -- psql -p "$port" -d "$db" -c "$sql" >/dev/null 2>&1; then
        log "pg ok: ${ver} port=$port db=$db ($sql)"
      else
        log "pg FALHOU: ${ver} port=$port db=$db ($sql)"
      fi
    done
  done
fi

# ---------- 10. docker ----------
if [ "$DOCKER_PRUNE" = 1 ] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  act "docker system prune -f >/dev/null 2>&1"
  act "docker builder prune -f >/dev/null 2>&1"
  find /var/lib/docker/containers -type f -name '*-json.log' -size +"${LOG_TRUNC_MB}M" -print 2>/dev/null \
    | truncate_list "docker-json"
fi

log "=== fim manutencao guest ==="
GUEST_EOF
chmod +x "$GUEST_SRC"
}

# ---------- execucao ----------
log "=== ct-disk-maintenance inicio (dry=$DRY_RUN) ==="
ROOT_AVAIL_KB=$(root_avail_kb)
POOL_AVAIL_KB=$(pool_avail_kb)
log "host: / livre=${ROOT_AVAIL_KB}K pool-data=${POOL_AVAIL_KB}K"

# --- higiene do proprio host ---
act "journalctl --vacuum-size=$HOST_JOURNAL_MAX >/dev/null 2>&1"
find /var/log -xdev -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.[0-9].gz' -o -name '*.old' \) \
  -mtime +"$HOST_LOG_DAYS" -print 2>/dev/null | while read -r f; do
    if [ "$DRY_RUN" = 1 ]; then log "DRY-DEL host: $f"; else rm -f "$f"; fi
  done
act "rm -f /var/lib/systemd/coredump/* /var/crash/* 2>/dev/null"
act "apt-get clean >/dev/null 2>&1"

# --- CTs ---
write_guest_script

CTS=""
if [ -n "$ONLY_CT" ]; then CTS="$ONLY_CT"; else
  CTS=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}' | sort -n | tr '\n' ' ')
fi

# knobs repassados ao guest (defaults do proprio guest cobrem o resto)
GUEST_KNOBS="JOURNAL_VACUUM_SIZE LOG_ROT_DAYS LOG_TRUNC_MB TMP_MAX_DAYS \
SQLITE_MIN_MB SQLITE_VACUUM_MIN_FREELIST_MB SQLITE_EXCLUDE_REGEX SQLITE_SCAN_TIMEOUT \
MIN_FREE_AFTER_VACUUM_GB PG_VACUUM_FULL DOCKER_PRUNE SQLITE_TIMEOUT PG_TIMEOUT"

guest_env(){
  local v val out="DRY_RUN=$1 REAL_AVAIL_KB=$2"
  for v in $GUEST_KNOBS; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && out="$out $v=$val"
  done
  echo "$out"
}

for ct in $CTS; do
  ct_running "$ct" || { log "CT$ct: nao esta running — skip"; continue; }
  real=$(ct_real_avail "$ct")
  env_args=$(guest_env "$DRY_RUN" "$real")
  log "CT$ct: real_avail_kb=$real — enviando script…"
  pct push "$ct" "$GUEST_SRC" /tmp/.ct-guest-maint.sh >/dev/null 2>&1 \
    || { log "CT$ct: FALHOU pct push — skip"; continue; }
  if [ "$DRY_RUN" = 1 ]; then
    log "CT$ct: DRY — executando guest em modo dry-run"
  fi
  timeout "$TIMEOUT_PER_CT" pct exec "$ct" -- env $env_args \
    bash /tmp/.ct-guest-maint.sh 2>&1 | sed "s/^/CT$ct|/" | tee -a "$LOG"
  pct exec "$ct" -- rm -f /tmp/.ct-guest-maint.sh >/dev/null 2>&1
  log "CT$ct: concluido"
done

# --- resumo final ---
log "=== fim ct-disk-maintenance ==="
log "host df: $(df -h / | awk 'NR==2{print $4" livres, "$5" usado"}') pool-data: $(lvs --noheadings -o data_percent pve/data 2>/dev/null | tr -d ' ')%"
for ct in $CTS; do
  ct_running "$ct" && log "CT$ct df: $(pct exec "$ct" -- df -h / 2>/dev/null | awk 'NR==2{print $4" livres de "$2}')"
done
