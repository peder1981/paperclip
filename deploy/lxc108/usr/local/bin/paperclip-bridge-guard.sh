#!/bin/bash
# Guardiao v2: restart apos 2 falhas; se falhar DEPOIS do restart, rebuild do cache gluon.
STATE=/var/lib/paperclip/maintenance/bridge_guard.state
LOG=/var/lib/paperclip/maintenance/bridge_guard.log
PASS=$(grep -oP '(?<=MAIL_IMAP_PASS=).*' /etc/paperclip-mail.env)
USER=$(grep -oP '(?<=MAIL_IMAP_USER=).*' /etc/paperclip-mail.env)
R=$(timeout 20 python3 -c "
import imaplib
try:
    m=imaplib.IMAP4('127.0.0.1',1143); m.login('$USER','$PASS'); m.logout(); print('ok')
except Exception as e: print('fail')
" 2>/dev/null)
N=$(cat $STATE 2>/dev/null || echo 0)
if [ "$R" = "ok" ]; then
  echo 0 > $STATE
  exit 0
fi
N=$((N+1)); echo $N > $STATE
echo "$(date '+%F %T') falha #$N" >> $LOG
if [ $N -ge 2 ]; then
  if [ $N -ge 4 ]; then
    echo "$(date '+%F %T') REBUILD cache gluon (restart nao resolveu)" >> $LOG
    systemctl stop protonmail-bridge
    sleep 3
    BK=/root/gluon-db-backup-$(date +%Y%m%d%H%M)
    mkdir -p $BK
    cp -a /root/.local/share/protonmail/bridge-v3/gluon/backend/db/*.db $BK/ 2>/dev/null
    cp -a /root/.config/protonmail/bridge-v3/imap-sync $BK/imap-sync 2>/dev/null
    rm -f /root/.local/share/protonmail/bridge-v3/gluon/backend/db/*.db /root/.local/share/protonmail/bridge-v3/gluon/backend/db/*.db-shm /root/.local/share/protonmail/bridge-v3/gluon/backend/db/*.db-wal
    rm -rf /root/.config/protonmail/bridge-v3/imap-sync/*
    systemctl start protonmail-bridge
  else
    echo "$(date '+%F %T') REINICIANDO bridge" >> $LOG
    systemctl restart protonmail-bridge
  fi
  echo 0 > $STATE
fi
