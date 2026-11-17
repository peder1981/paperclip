#!/bin/bash
# Send email via Postfix + Proton SMTP relay (credenciais via env/host)
# Usage: send-proton-email.sh [to] [subject] [body]
# ENV usadas: PROTON_FROM, PROTON_RECIPIENT, PROTON_ACCOUNT, PROTON_MAIL, PROTON_PORT

CONF="/etc/proton-mail.conf"
[ -f "$CONF" ] && source "$CONF"

FROM="${PROTON_FROM:-operador@example.invalid}"
RECIPIENT="${1:-${PROTON_RECIPIENT:-operador-proton@example.invalid}}"
SUBJECT="${2:-Teste}"
BODY="${3:-Corpo do email}"

echo "From: $FROM | To: $RECIPIENT | Via: ${PROTON_MAIL:-smtp.protonmail.ch}:${PROTON_PORT:-587} (conta ${PROTON_ACCOUNT:-proton})"

# Via preferencial: notify-email.sh (postfix relay com SASL)
if command -v notify-email.sh &>/dev/null; then
    notify-email.sh "$SUBJECT" "$BODY" && exit 0
fi

# Fallback direto via sendmail com From correto
{
echo "From: Proxmox Monitor <${FROM}>"
echo "To: ${RECIPIENT}"
echo "Subject: ${SUBJECT}"
echo "Content-Type: text/plain; charset=utf-8"
echo ""
echo "$BODY"
} | sendmail -t && echo "OK via sendmail" || echo "FALHA ao enviar email" >&2
