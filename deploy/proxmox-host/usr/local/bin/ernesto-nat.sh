#!/bin/bash
# Regras NAT custom do Ernesto — idempotente
# Roda após netbird para garantir que as DNAT rules persistam
LOCKFILE="/tmp/${0##*/}.lock"
exec 9>"$LOCKFILE"
flock -n 9 || { echo "[LOCK] ${0##*/} ja em execucao"; exit 0; }
NOTIFY() { telegram-notify "$1" 2>/dev/null || true; }

add_rule() {
    local table=$1; shift
    iptables -w -t "$table" -C "$@" 2>/dev/null || iptables -w -w -t "$table" -A "$@"
}

# DNAT: NetBird (wt0) → LXC 101
add_rule nat PREROUTING -i wt0 -p tcp --dport 9080 -j DNAT --to-destination 192.168.2.81:9080
add_rule nat PREROUTING -i wt0 -p tcp --dport 9081 -j DNAT --to-destination 192.168.2.81:9081
add_rule nat PREROUTING -i wt0 -p tcp --dport 9083 -j DNAT --to-destination 192.168.2.81:9083
add_rule nat PREROUTING -i wt0 -p tcp --dport 11434 -j DNAT --to-destination 192.168.2.81:11434

# DNAT: WiFi local (wlp2s0) → LXC 101
add_rule nat PREROUTING -i wlp2s0 -p tcp --dport 9080 -j DNAT --to-destination 192.168.2.81:9080
add_rule nat PREROUTING -i wlp2s0 -p tcp --dport 9081 -j DNAT --to-destination 192.168.2.81:9081
add_rule nat PREROUTING -i wlp2s0 -p tcp --dport 9083 -j DNAT --to-destination 192.168.2.81:9083

# POSTROUTING: masquerade para tráfego ao LXC
add_rule nat POSTROUTING -d 192.168.2.0/24 -o vmbr0 -j MASQUERADE
add_rule nat POSTROUTING -s 192.168.2.0/24 -o wlp2s0 -j MASQUERADE

# FORWARD: permitir tráfego local ↔ LXC (inserir antes do DROP se necessário)
for rule in \
    "-i wlp2s0 -o vmbr0 -j ACCEPT" \
    "-i vmbr0 -o wlp2s0 -j ACCEPT" \
    "-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"; do
    iptables -C FORWARD $rule 2>/dev/null || iptables -w -I FORWARD 4 $rule
done

NOTIFY "🟢 [NAT] Regras aplicadas em $(hostname)"
echo "ernesto-nat: regras aplicadas"
