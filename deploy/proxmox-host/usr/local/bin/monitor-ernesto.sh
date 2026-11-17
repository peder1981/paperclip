#!/bin/bash
set -euo pipefail
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

LXC=101
PBS_LXC=100
PBS_IP=192.168.2.133
LOG=/var/log/monitor-ernesto.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }
if [ -f /run/maintenance.flag ]; then echo "[$(date "+%Y-%m-%d %H:%M:%S")] MANUTENCAO: flag /run/maintenance.flag ativo, sem acoes" >> /var/log/monitor-ernesto.log; exit 0; fi

STATEDIR=/tmp/monitor-state
mkdir -p "$STATEDIR"
STATE() { local f="$STATEDIR/$1"; [ -f "$f" ] && echo 1 || echo 0; }
MARK() { touch "$STATEDIR/$1"; }
CLEAR() { rm -f "$STATEDIR/$1"; }
LXC_IP=192.168.2.81

alert() {
    local subject="$1" msg="$2"
    log "ALERT: $subject -- $msg"
    telegram-notify "🛑 [ERNESTO] ${subject} — ${msg}" 2>/dev/null || true
}

notify_ok() {
    local subject="$1" msg="$2"
    log "OK: $subject -- $msg"
    telegram-notify "✅ [ERNESTO] ${subject} — ${msg}" 2>/dev/null || true
}

# ── 1. LXC 101 alive ─────────────────────────────────────────────────────────
if ! pct status "$LXC" 2>/dev/null | grep -q running; then
    alert "LXC $LXC DOWN" "Container ernesto nao esta running, tentando start"
    pct start "$LXC" 2>/dev/null && log "LXC $LXC started" || alert "LXC $LXC START FAIL" "pct start falhou"
    exit 1
fi

# ── 2. Limpar lock 'mounted' se preso (impede vzdump) ────────────────────────
LOCK=$(pct config "$LXC" 2>/dev/null | grep "^lock:" | awk '{print $2}' || true)
if [[ "$LOCK" == "mounted" ]]; then
    log "LXC $LXC com lock=mounted, desbloqueando"
    pct unlock "$LXC" 2>/dev/null && log "unlock OK" || log "unlock falhou"
fi

# ── 3. Serviços LXC ──────────────────────────────────────────────────────────
SERVICES=()  # RAG (mem0, mcp, ernesto-bot) pausado por decisao do operador: nao monitorar nem reiniciar

failed_any=false failures=""
check_svc() {
    local lxc_id="$1" name="$2" label="$3"
    local sf="$STATEDIR/svc-${lxc_id}-${name}"
    if pct exec "$lxc_id" -- systemctl is-active "$name" 2>/dev/null | grep -qx active; then
        if [ -f "$sf" ]; then
            rm -f "$sf"
            notify_ok "UP: $label" "$label recuperado"
        fi
    else
        if [ ! -f "$sf" ]; then
            touch "$sf"
            alert "DOWN: $label" "$label estava ativo mas parou"
        fi
        log "$label: nao ativo -> restart"
        pct exec "$lxc_id" -- systemctl restart "$name" 2>/dev/null || true
        sleep 4
        if pct exec "$lxc_id" -- systemctl is-active "$name" 2>/dev/null | grep -qx active; then
            notify_ok "RECOVERED: $label" "$label restartou OK"
        else
            alert "DOWN: $label" "$label inactive apos restart"
            failed_any=true
            failures="$failures $label"
        fi
    fi
}
for svc_entry in "${SERVICES[@]}"; do
    svc_name="${svc_entry%%:*}"
    svc_label="${svc_entry#*:}"
    check_svc "$LXC" "$svc_name" "$svc_label"
done

# Bot check via systemd unit ernesto-bot (SERVICES acima)

# ── 3b. LXC 106 (geban) e 107 (avatar) ─────────────────────────────────────
check_lxc_alive() {
    local id="$1" name="$2"
    if ! pct status "$id" 2>/dev/null | grep -q running; then
        alert "LXC $id DOWN" "Container $name nao esta running, tentando start"
        pct start "$id" 2>/dev/null && log "LXC $id ($name) started" \
            || alert "LXC $id START FAIL" "pct start $name falhou"
        return 1
    fi
    return 0
}

if check_lxc_alive 106 geban; then
    for svc in "geban:GEBAN ERP" "gebweb:GEBAN Web" "gebansocat:GEBAN Socat" "postgresql@15-main:PostgreSQL" "cloudflared:Cloudflare Tunnel geban"; do
        check_svc 106 "${svc%%:*}" "${svc#*:}"
    done
fi

if check_lxc_alive 107 avatar; then
    for svc in "avatar-studio:Avatar Studio" "cloudflared:Cloudflare Tunnel avatar"; do
        check_svc 107 "${svc%%:*}" "${svc#*:}"
    done
fi

if check_lxc_alive 108 paperclip; then
    for svc in "paperclip:Paperclip" "cloudflared-paperclip:Cloudflare Tunnel paperclip" "ollama-tunnel:Tunel Ollama homelab" "paperclip-telegram:Bridge Telegram Paperclip"; do
        check_svc 108 "${svc%%:*}" "${svc#*:}"
    done
fi

# ── LXC 109 (Protheus 2510): containers docker ─────────────────────────────
check_docker() {
    local lxc_id="$1" cname="$2" label="$3"
    local sf="$STATEDIR/dkr-${lxc_id}-${cname}"
    local st
    st=$(pct exec "$lxc_id" -- docker inspect -f '{{.State.Running}}' "$cname" 2>/dev/null || echo missing)
    if [ "$st" = "true" ]; then
        if [ -f "$sf" ]; then
            rm -f "$sf"
            notify_ok "UP: $label" "$label voltou a rodar"
        fi
    else
        if [ ! -f "$sf" ]; then
            touch "$sf"
            alert "DOWN: $label" "container $cname na LXC $lxc_id: estado=$st"
        fi
        log "$label: estado=$st"
    fi
}
if check_lxc_alive 109 protheus; then
    for c in protheus-2510 dbaccess-2510 postgresql-2510 license-server-2510 smartview-2510; do
        check_docker 109 "$c" "Protheus $c"
    done
fi

# ── 3c. Sondagem HTTP (correção 6) ──────────────────────────────────────────
check_http() {
    local id="$1" label="$2" url="$3"
    local sf="$STATEDIR/http-${id}-$(echo "$url" | tr -c 'a-zA-Z0-9' '_')"
    local code
    code=$(pct exec "$id" -- sh -c "curl -sk -o /dev/null -m 5 -w '%{http_code}' '$url'" 2>/dev/null) || code=000
    if [[ "$code" =~ ^[23] ]]; then
        if [ -f "$sf" ]; then
            rm -f "$sf"
            notify_ok "UP: $label" "$label respondeu HTTP $code"
        fi
    else
        if [ ! -f "$sf" ]; then
            touch "$sf"
            alert "HTTP DOWN: $label" "$label respondeu HTTP $code em $url"
        fi
        log "$label: HTTP $code"
    fi
}
check_http 100 "PBS Web" "https://127.0.0.1:8007/"
check_http 108 "Paperclip API" "http://127.0.0.1:3100/api/health"
check_http 108 "Protheus WebApp (LXC 109 via 108)" "http://192.168.2.109:4321/"
check_http 108 "Protheus WebMonitor (LXC 109 via 108)" "http://192.168.2.109:1234/webmonitor"
check_http 106 "GEBAN Web" "http://127.0.0.1:8080/"
check_http 106 "GEBAN advplc" "http://127.0.0.1:8081/"
check_http 107 "Avatar Studio Web" "http://127.0.0.1:7860/"

# ── 4. JuiceFS montado ───────────────────────────────────────────────────────
if ! mountpoint -q /mnt/jfs 2>/dev/null; then
    alert "JuiceFS DOWN" "/mnt/jfs nao montado (ernesto-jfs desabilitado; sem restart automatico)"
fi

# ── 5. PBS LXC 100: garantir IP e serviço ────────────────────────────────────
if pct status "$PBS_LXC" 2>/dev/null | grep -q running; then
    if ! ping -c 1 -W 2 "$PBS_IP" &>/dev/null; then
        log "PBS sem IP $PBS_IP, reconfigurando"
        pct exec "$PBS_LXC" -- ip addr add "${PBS_IP}/24" dev eth0 2>/dev/null || true
        pct exec "$PBS_LXC" -- ip route add default via 192.168.2.1 2>/dev/null || true
        sleep 2
        ping -c 1 -W 2 "$PBS_IP" &>/dev/null && log "PBS IP restaurado" \
            || alert "PBS OFFLINE" "PBS LXC sem IP $PBS_IP — vzdump vai falhar"
    fi
else
    log "PBS LXC $PBS_LXC não está running, tentando start"
    pct start "$PBS_LXC" 2>/dev/null || alert "PBS START FAIL" "pct start $PBS_LXC falhou"
fi

# ── 6. PBS vzdump staleness ────────────────────────────────────────────────
PBS_CT_DIR="/mnt/pbs-datastore/ct"
if [[ -d "$PBS_CT_DIR" ]]; then
    LAST_PXAR=$(find "$PBS_CT_DIR" -name "*.pxar.didx" -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
    if [[ -n "$LAST_PXAR" ]]; then
        PBS_AGE_HOURS=$(( ( $(date +%s) - ${LAST_PXAR%.*} ) / 3600 ))
        if [[ "$PBS_AGE_HOURS" -gt 26 ]]; then
            alert "PBS BACKUP STALE" "Último PBS CT backup há ${PBS_AGE_HOURS}h (esperado: diário 02:00)"
        fi
    else
        log "Nenhum .pxar encontrado em $PBS_CT_DIR (PBS pode não ter CTs ainda)"
    fi
fi

# ── 7. Idade do último backup de dados (host) ───────────────────────────────
for CHECK_BACKUP in \
    "/var/log/ernesto-data-backup.log:FAISS/config" \
    "/var/log/ernesto-backup-jfs.log:ChromaDB" \
    "/var/log/pbs-sync-jfs.log:PBS secondary" \
    "/var/log/backup-host.log:Host config"; do
    LOG_FILE="${CHECK_BACKUP%%:*}"
    LABEL="${CHECK_BACKUP#*:}"
    if [[ -f "$LOG_FILE" ]]; then
        AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y "$LOG_FILE") ) / 3600 ))
        if [[ "$AGE_HOURS" -gt 26 ]]; then
            alert "BACKUP STALE: $LABEL" "Último backup $LABEL há ${AGE_HOURS}h (esperado: diário)"
        fi
    else
        log "Sem log de backup: $LABEL ($LOG_FILE)"
    fi
done

# ── 7b. Backups app-level de TODOS os projetos (artefato real) ───────────────
# Reporta 1x na transicao (evita spam a cada 5min); notify_ok na recuperacao.
mapfile -t APP_BK < <(/usr/local/bin/check-app-backups.sh 2>/dev/null || true)
app_bk_now=""   # chaves com falha nesta rodada
for line in "${APP_BK[@]}"; do
    [[ "$line" == *$'\t'* ]] || continue
    lbl="${line%%$'\t'*}"; msg="${line#*$'\t'}"
    key="appbk-$(echo "$lbl" | tr -c 'a-zA-Z0-9' '_')"
    case "$msg" in
        # aviso informativo (backup inexistente por decisao): loga, nunca alerta
        *"inexistente por decisao"*|*"SEM backup app-level"*)
            log "APP-BACKUP AVISO: $lbl — $msg" ;;
        *)
            app_bk_now="$app_bk_now $key"
            if [ "$(STATE "$key")" = 0 ]; then
                alert "APP-BACKUP: $lbl" "$msg"; MARK "$key"
            fi ;;
    esac
done
# recuperacao: chave marcada que sumiu da lista de falhas
for sf in "$STATEDIR"/appbk-*; do
    [ -e "$sf" ] || continue
    k=$(basename "$sf")
    case " $app_bk_now " in
        *" $k "*) : ;;
        *) CLEAR "$k"; notify_ok "APP-BACKUP RECUPERADO" "$(echo "${k#appbk-}" | tr '_' ' ')" ;;
    esac
done

# ── 7. LXC 101 tem internet? ─────────────────────────────────────────────────
if [ "$(STATE lxc_down)" = 0 ] && ping -c 1 -W 1 "$LXC_IP" >/dev/null 2>&1; then
    if pct exec "$LXC" -- curl -sf --connect-timeout 5 --max-time 8 https://api.telegram.org >/dev/null 2>&1; then
        if [ "$(STATE lxc_nointernet)" = 1 ]; then
            notify_ok "INTERNET RECUPERADA" "LXC $LXC voltou a ter internet (Telegram OK)"
        fi
        CLEAR lxc_nointernet
    else
        if [ "$(STATE lxc_nointernet)" = 0 ]; then
            alert "LXC $LXC SEM INTERNET" "api.telegram.org inalcancavel — notificacoes do LXC podem estar offline"
            MARK lxc_nointernet
        fi
    fi
fi

# ── 8. Heartbeat (a cada 60 min) ─────────────────────────────────────────────
min_of_day=$(( 10#$(date +%H)*60 + 10#$(date +%M) ))
if [ "$(( min_of_day % 60 ))" -eq 0 ]; then
    down=""
    for id in 100 101 103 104 105 106 107 108 109; do
        pct status "$id" 2>/dev/null | grep -q running || down="$down LXC$id"
    done
    pend=$(ls "$STATEDIR" 2>/dev/null | grep -E '^(svc|http)-' | tr '\n' ' ' || true)
    if [ -z "$down" ] && [ -z "$pend" ]; then
        estado="LXC 100-109 running (sem 102, desativada); nenhuma falha pendente"
    else
        estado="PENDENCIAS: LXC[${down:-nenhum}] servicos[${pend:-nenhum}]"
    fi
    notify_ok "HEARTBEAT" "Proxmox $estado $(date '+%H:%M')"
    log "Heartbeat: OK (lock=$LOCK)"
fi

log "Done${failures:+ FAIL=$failures}"
exit $([ "$failed_any" = true ] && echo 1 || echo 0)
