#!/bin/bash
# homelab-recovery.sh - Garante que tudo suba após boot
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
LOG=/var/log/homelab-recovery.log

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$LOG"
}

NOTIFY "🟡 [RECOVERY] Iniciado em $(hostname)"
log "=== HOMELAB RECOVERY INICIADO ==="

# 1. Garantir vmbr0 bridge existe
if ! ip link show vmbr0 >/dev/null 2>&1; then
    log "vmbr0 nao existe. Criando..."
    ip link add name vmbr0 type bridge 2>/dev/null
    ip link set nic0 master vmbr0 2>/dev/null
    ip link set nic0 up
    ip addr add 192.168.2.194/24 dev vmbr0
    ip link set vmbr0 up
    log "vmbr0 criado manualmente"
else
    BRIDGE_INFO=$(ip -br a s vmbr0 2>/dev/null | awk '{print $3}')
    log "vmbr0 existe (${BRIDGE_INFO:-sem IP})"
fi

# 2. Iniciar containers parados
for ct in 100 101; do
    CT_STATUS=$(pct status "$ct" 2>/dev/null)
    if echo "$CT_STATUS" | grep -q 'stopped'; then
        log "Container $ct parado. Iniciando..."
        pct start "$ct" 2>&1 | tee -a "$LOG"
    else
        log "Container $ct rodando"
    fi
done

# 3. Garantir rota default via wifi
if ! ip route show default | grep -q '192.168.1.254.*wlp2s0'; then
    log "Rota default incorreta. Corrigindo..."
    ip route del default via 192.168.2.1 2>/dev/null
    ip route add default via 192.168.1.254 dev wlp2s0 metric 50
fi

# 4. Garantir NetBird rodando e conectado
if ! systemctl is-active netbird >/dev/null 2>&1; then
    log "NetBird parado. Restartando..."
    systemctl restart netbird
elif ! netbird status 2>/dev/null | grep -q 'Management: Connected'; then
    log "NetBird desconectado. Limpando chains + restart..."
    iptables-save 2>/dev/null | grep -v NETBIRD | iptables-restore 2>/dev/null
    systemctl restart netbird
fi

# 5. Garantir resolv.conf imutavel
if ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    log "resolv.conf alterado. Reaplicando + imutavel..."
    cat > /etc/resolv.conf << 'EOFNS'
nameserver 100.121.53.28
nameserver 8.8.8.8
nameserver 186.211.32.186
nameserver 186.211.32.187
EOFNS
    chattr +i /etc/resolv.conf
fi

NOTIFY "🟢 [RECOVERY] Concluído em $(hostname)"
log "=== HOMELAB RECOVERY CONCLUIDO ==="
