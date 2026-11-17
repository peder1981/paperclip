#!/bin/bash
# Avisa via Meu Gerente quando o IMAP do bridge voltar a responder login.
PASS=$(grep MAIL_IMAP_PASS /etc/paperclip-mail.env | cut -d= -f2- | tr -d "\"")
OK=$(timeout 10 python3 -c "
import imaplib,sys
try:
  c=imaplib.IMAP4(\"127.0.0.1\",1143); c.login(\"operador@example.invalid\",\"$PASS\")
  print(\"ok\"); c.logout()
except Exception as e: print(str(e)[:60])" 2>/dev/null)
[ "$OK" = "ok" ] || exit 0
# so avisa 1x: marca quando avisado
[ -f /var/run/imap-up.flag ] && exit 0
touch /var/run/imap-up.flag
/var/lib/paperclip/tools/telegram-bridge/notify.py "[paperclip] IMAP do bridge normalizado — operador@example.invalid aceitando login. Ingest pode rodar." 2>/dev/null
