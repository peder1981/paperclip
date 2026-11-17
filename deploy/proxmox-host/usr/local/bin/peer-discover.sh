#!/bin/bash
set -euo pipefail
LOG()  { logger -t peer-discover "$*"; }
: "${PEER_SSH:?}" ; : "${MY_NAME:?}" ; : "${PEER_NAME:?}" ; : "${UPDATE_CMD:?}"

# Troca completa no máximo a cada FULL_EXCHANGE_SECS (padrão 30 min) se o IP local não mudar.
FULL_EXCHANGE_SECS="${FULL_EXCHANGE_SECS:-1800}"
STATE_DIR="${STATE_DIR:-${XDG_STATE_HOME:-${HOME:-/root}/.local/state}/peer-discover}"
STATE_FILE="$STATE_DIR/last-exchange"

_valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
  [[ ! "$1" =~ ^(100|127|169\.254)\. ]]
}

_own_lan_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7}' | grep -Ev '^(100|127)\.' | head -1)
  [[ -z "$ip" ]] && ip=$(hostname -I | tr ' ' '\n' | grep -Ev '^(100|127|::)\.' | head -1)
  echo "$ip"
}

LOG "Iniciando: $MY_NAME -> $PEER_SSH"

for i in $(seq 1 36); do
  netbird status 2>/dev/null | grep -q "Management: Connected" && break
  [[ "$i" -eq 36 ]] && { LOG "AVISO: NetBird nao conectou; tentando mesmo assim"; break; }
  sleep 5
done

MY_IP=$(_own_lan_ip)
_valid_ip "$MY_IP" || { LOG "ERRO: IP LAN invalido: '$MY_IP'"; exit 1; }
LOG "IP local: $MY_IP"

# Pula o SSH se o IP local é o mesmo da última troca bem-sucedida e ela é recente.
LAST_IP=""; LAST_TS=0
if [[ -r "$STATE_FILE" ]]; then read -r LAST_IP LAST_TS < "$STATE_FILE" || true; fi
NOW=$(date +%s)
if [[ "$MY_IP" == "$LAST_IP" ]] && (( NOW - LAST_TS < FULL_EXCHANGE_SECS )); then
  LOG "IP local inalterado; próxima troca completa em $(( FULL_EXCHANGE_SECS - (NOW - LAST_TS) ))s"
  exit 0
fi

RAW_OUTPUT=$(ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=15 \
  -o ServerAliveInterval=5 \
  -o ServerAliveCountMax=3 \
  "$PEER_SSH" \
  "if [ \$(id -u) -eq 0 ]; then /usr/local/bin/update-hosts.sh '${MY_NAME}' '${MY_IP}'; else sudo /usr/local/bin/update-hosts.sh '${MY_NAME}' '${MY_IP}'; fi && \
   ip route get 1.1.1.1 2>/dev/null | awk '/src/{print \$7}' \
     | grep -Ev '^(100|127)\.' | head -1" \
) || { LOG "AVISO: SSH para $PEER_SSH falhou; /etc/hosts mantido"; exit 0; }

# Extrai apenas a linha que é exatamente um IP (ignora ruído do .bashrc remoto)
PEER_IP=$(printf '%s\n' "$RAW_OUTPUT" | grep -Eo '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1)

if _valid_ip "$PEER_IP"; then
  $UPDATE_CMD "$PEER_NAME" "$PEER_IP"
  mkdir -p "$STATE_DIR"
  printf '%s %s\n' "$MY_IP" "$NOW" > "$STATE_FILE"
  LOG "OK -- $MY_NAME=$MY_IP em $PEER_SSH; $PEER_NAME=$PEER_IP local"
else
  LOG "AVISO: IP invalido recebido ('$PEER_IP'); /etc/hosts local mantido"
fi
