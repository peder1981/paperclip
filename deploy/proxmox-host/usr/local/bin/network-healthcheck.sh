#!/bin/bash
# network-healthcheck.sh v3.1
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }

NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }
LOG=/var/log/network-healthcheck.log
HAS_ERROR=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"
}

# 1. Default route via wifi?
if ! ip route show default | grep -q '192.168.1.254.*wlp2s0'; then
    log "ERRO: Rota default perdida. Readdicionando..."
    ip route del default via 192.168.2.1 2>/dev/null
    ip route add default via 192.168.1.254 dev wlp2s0 metric 50 2>/dev/null
    HAS_ERROR=1
fi

# 2. WiFi up?
if ! ip link show wlp2s0 | grep -q 'UP'; then
    log "ERRO: WiFi down. Tentando restart..."
    ip link set wlp2s0 up
    HAS_ERROR=1
fi

# 3. NetBird daemon alive?
if ! systemctl is-active netbird >/dev/null 2>&1; then
    log "ERRO: NetBird parado. Restartando..."
    systemctl restart netbird
    HAS_ERROR=1
fi

# 4. NetBird connected?
if ! netbird status 2>/dev/null | grep -q 'Management: Connected'; then
    log "ERRO: NetBird desconectado. Limpando chains + restart..."
    iptables-save 2>/dev/null | grep -v NETBIRD | iptables-restore 2>/dev/null
    systemctl restart netbird
    HAS_ERROR=1
fi

# 5. resolv.conf imutavel?
if ! lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
    log "ERRO: resolv.conf alterado. Reaplicando..."
    cat > /etc/resolv.conf << 'EOFNS'
nameserver 100.121.53.28
nameserver 8.8.8.8
nameserver 186.211.32.186
nameserver 186.211.32.187
EOFNS
    chattr +i /etc/resolv.conf
    HAS_ERROR=1
fi

# 6. Internet?
if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    log "ERRO: Sem internet. Readdicionando rota..."
    ip route del default via 192.168.2.1 2>/dev/null
    ip route add default via 192.168.1.254 dev wlp2s0 metric 50 2>/dev/null
    HAS_ERROR=1
fi

if [ "$HAS_ERROR" -eq 0 ]; then
    log "OK: Tudo saudavel"
else
    NOTIFY "🔴 [NETWORK] ${HAS_ERROR} problema(s) corrigido(s) em $(hostname)"
fi
