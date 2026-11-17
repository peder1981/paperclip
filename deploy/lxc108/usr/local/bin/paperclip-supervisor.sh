#!/bin/bash
# Supervisor v3: IMAP down->restart bridge+alerta, crash-loop->isola gluon, auto-unblock issues, anomalias.
NOTIFY=/usr/local/bin/paperclip-notify
PASS=$(grep MAIL_IMAP_PASS /etc/paperclip-mail.env | cut -d= -f2- | tr -d '"')
FLAG=/var/run/supervisor-alert.flag
STATE=/var/lib/paperclip/supervisor-unblock.state
IMAPFLAG=/var/run/supervisor-imap-down.flag

imap_check() {
timeout 15 python3 - "$PASS" <<'PY'
import imaplib, ssl, sys
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
try:
    c = imaplib.IMAP4("127.0.0.1", 1143)
    c.starttls(ssl_context=ctx)
    c.login("operador@example.invalid", sys.argv[1])
    print("ok"); c.logout()
except Exception:
    print("fail")
PY
}

OK=$(imap_check 2>/dev/null)

# 1) IMAP DOWN -> acao + alerta (antes so alertava na RECUPERACAO - gap)
if [ "$OK" != "ok" ]; then
  if [ ! -f "$IMAPFLAG" ]; then
    $NOTIFY "[supervisor] IMAP DOWN (porta 1143/login falhou) - tentando restart do bridge." 2>/dev/null
    touch "$IMAPFLAG"
  fi
  LISTEN=$(ss -ltn 2>/dev/null | grep -c ":1143 ")
  if [ "$LISTEN" = "0" ]; then
    # crash loop? isola o db gluon mais recente e reinicia
    RC=$(systemctl show protonmail-bridge -p NRestarts --value 2>/dev/null)
    if [ "${RC:-0}" -ge 3 ]; then
      DB=$(ls -t /root/.local/share/protonmail/bridge-v3/gluon/backend/db/*.db 2>/dev/null | head -1)
      [ -n "$DB" ] && mkdir -p /root/gluon-bak && cp -a "$DB"* /root/gluon-bak/ 2>/dev/null \
        && rm -f "$DB" "$DB-shm" "$DB-wal" \
        && $NOTIFY "[supervisor] bridge em crash-loop (SIGBUS?) - db gluon isolado: $(basename $DB)" 2>/dev/null
    fi
    systemctl restart protonmail-bridge 2>/dev/null
    sleep 20
    OK=$(imap_check 2>/dev/null)
  fi
  if [ "$OK" != "ok" ]; then
    $NOTIFY "[supervisor] IMAP AINDA DOWN apos restart - intervencao manual necessaria (senha/2FA no bridge?)" 2>/dev/null
    exit 0
  fi
fi
if [ "$OK" = "ok" ] && [ -f "$IMAPFLAG" ]; then
  rm -f "$IMAPFLAG"
  $NOTIFY "[supervisor] IMAP normalizado." 2>/dev/null
fi

# 2) IMAP ok e cron pausado -> despausa
if [ "$OK" = "ok" ] && crontab -l 2>/dev/null | grep -q "PAUSADO JMP-119"; then
  crontab -l | sed "s/^# *\([0-9*].*jmp30_fetch.*\) *# *PAUSADO JMP-119.*/\1/" | crontab -
  $NOTIFY "[supervisor] IMAP normalizado - cron jmp30_fetch reativado." 2>/dev/null
fi

# 3) AUTO-UNBLOCK: issues paradas >2h -> comentario via API acorda o responsavel (1x/2h por issue)
TOKEN=$(python3 -c "
import json,ast
d=json.load(open('/root/.paperclip/auth.json'))
c=d['credentials']
c=ast.literal_eval(c) if isinstance(c,str) else c
print(list(c.values())[0]['token'])" 2>/dev/null)
UNBLOCK=$(su postgres -c "psql -d paperclip -tAf /var/lib/paperclip/supervisor-stalled.sql" 2>/dev/null)
NOW=$(date +%s)
echo "$UNBLOCK" | while IFS='|' read -r iid ident aid hours; do
  [ -z "$iid" ] && continue
  KEY="unblock-$iid"
  LAST=$(python3 -c "
import json,os
s=json.load(open('$STATE')) if os.path.exists('$STATE') else {}
print(s.get('$KEY',0))" 2>/dev/null || echo 0)
  [ $((NOW-LAST)) -lt 7200 ] && continue
  RES=$(curl -s -m10 -X POST "localhost:3100/api/issues/$iid/comments" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"body\":\"[supervisor] EMENDA 1.5 — EXECUTE o proximo passo AGORA, nao reconfirme estado: (a) tema ja existe em outra issue? feche como duplicata apontando a original; (b) decisao pendente? aplique o default seguro e continue; (c) dependencia externa? agende monitor com timeout; (d) revisao pendente? solicite ao responsavel. Reconfirmar sem agir = falha de execucao.\"}" 2>/dev/null | head -c 40)
  case "$RES" in
    *'"id"'*)
      python3 -c "
import json,os
s=json.load(open('$STATE')) if os.path.exists('$STATE') else {}
s['$KEY']=$NOW
json.dump(s,open('$STATE','w'))" 2>/dev/null
      $NOTIFY "[supervisor] $ident parada ${hours}h - retomada automatica postada." 2>/dev/null
      ;;
  esac
done


# 5) INGEST vivo? (timer do mail-ingest executou nos ultimos 40min?)
LAST=$(systemctl show mail-ingest-projetos.timer -p LastTriggerUSec --value 2>/dev/null | cut -d' ' -f1-2)
if [ -n "$LAST" ]; then
  AGE=$(( $(date +%s) - $(date -d "$LAST" +%s 2>/dev/null || echo 0) ))
  if [ $AGE -gt 2400 ]; then
    systemctl start mail-ingest-projetos.service 2>/dev/null
    $NOTIFY "[supervisor] timer do mail-ingest parado ha $((AGE/60))min - ingest disparado manualmente." 2>/dev/null
  fi
fi


# 6) AUTO-RESOLVE de recovery actions ativas (o que era manual: resolve + atribui revisor + acorda)
RECS=$(su postgres -c "psql -d paperclip -tAf <<'SQL'
SELECT r.id, i.id, i.identifier, coalesce(a.id,'') FROM issue_recovery_actions r
JOIN issues i ON i.id=r.source_issue_id
LEFT JOIN agents a ON a.id=i.assignee_agent_id
WHERE r.status NOT IN ('resolved','cancelled') LIMIT 10;
SQL" 2>/dev/null)
echo "$RECS" | while IFS='|' read -r rid iid ident aid; do
  [ -z "$rid" ] && continue
  R=$(curl -s -m10 -X POST "localhost:3100/api/issues/$iid/recovery-actions/resolve" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"actionId\":\"$rid\",\"outcome\":\"restored\",\"sourceIssueStatus\":\"in_review\",\"resolutionNote\":\"[supervisor] Recuperacao resolvida automaticamente — agente reavalia com EMENDAS (default seguro, decide e executa).\"}" 2>/dev/null | head -c 40)
  case "$R" in
    *'"id"'*)
      # atribui o responsavel atual como revisor (cria caminho mantido) e acorda
      [ -n "$aid" ] && curl -s -m10 -X PATCH "localhost:3100/api/issues/$iid" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"assigneeAgentId\":\"$aid\"}" >/dev/null 2>&1
      curl -s -m10 -X POST "localhost:3100/api/issues/$iid/comments" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"body\":\"[supervisor] Recovery resolvida automaticamente. Reavalie com as EMENDAS: pesquise o board (duplicata?), aplique o default seguro, decida e execute — nunca termine em espera sem caminho.\"}" >/dev/null 2>&1
      $NOTIFY "[supervisor] $ident: recovery resolvida automaticamente (agente reavaliando)." 2>/dev/null
      ;;
  esac
done

# 4) Anomalias graves -> Telegram
REPORT=$(su postgres -c "psql -d paperclip -tAf /var/lib/paperclip/supervisor.sql" 2>/dev/null)
if [ -n "$REPORT" ]; then
  [ -f $FLAG ] && exit 0
  MSG=$(echo "$REPORT" | head -8)
  $NOTIFY "[supervisor] anomalias:
$MSG" 2>/dev/null
  touch $FLAG
else
  rm -f $FLAG
fi
