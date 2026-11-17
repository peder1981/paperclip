#!/bin/bash
# Runs on homelab boot and on WiFi up (via systemd + NM dispatcher).
# Tries avahi up to 5x (30s window) to resolve laptop-operador's current IP.
HOSTS_TAG="# managed-by-nm-sync"

for i in $(seq 1 5); do
    LAPTOP_IP=$(avahi-resolve-host-name -4 laptop-operador.local 2>/dev/null | awk '{print $2}')
    [ -n "$LAPTOP_IP" ] && break
    sleep 6
done

[ -z "$LAPTOP_IP" ] && exit 0   # laptop not on same LAN, keep existing entry

sed -i "/$HOSTS_TAG/d" /etc/hosts
echo "$LAPTOP_IP laptop-operador laptop-operador.local $HOSTS_TAG" >> /etc/hosts
logger -t nm-sync "homelab-sync: laptop-operador=$LAPTOP_IP"
