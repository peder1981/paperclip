#!/bin/bash
# ernesto-firewall-rules.sh — reaplica regras do Proxmox → LXC 101
# Executado via cron @reboot ou if-up.d para persistir após reboot

IPTABLES=$(which iptables 2>/dev/null)
[ -z "$IPTABLES" ] && exit 0

# Regras para portas do LXC 101 (ernesto) da rede homelab 192.168.1.0/24
declare -A PORTS=(
    ["9080"]="RAG Proxy"
    ["9081"]="Mem0 Proxy"
    ["9083"]="MCP SSE Server"
)

LXC_IP="192.168.2.81"
SRC_NET="192.168.1.0/24"
CHAIN="PVEFW-HOST-IN"

for PORT in "${!PORTS[@]}"; do
    # Verificar se já existe regra para esta porta (evitar duplicatas)
    if ! $IPTABLES -C "$CHAIN" -s "$SRC_NET" -d "$LXC_IP" -p tcp --dport "$PORT" -j RETURN 2>/dev/null; then
        $IPTABLES -I "$CHAIN" 5 -s "$SRC_NET" -d "$LXC_IP" -p tcp --dport "$PORT" -j RETURN
    fi
done
