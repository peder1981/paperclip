#!/bin/bash
# Email notification script using Postfix + Proton SMTP relay
# Usage: notify-email.sh "subject" "body"

set -euo pipefail

CONF="/etc/proton-mail.conf"
[ -f "$CONF" ] && source "$CONF"

RECIPIENT="${PROTON_RECIPIENT:-operador-proton@example.invalid}"
SUBJECT="${1:-Proxmox Alert}"
BODY="${2:-$(cat)}"

# Create temp file with actual date/hostname
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

# Write email with proper formatting
cat > "$TMPFILE" << EMAILHEADER
From: Proxmox Monitor <${PROTON_FROM:-operador@example.invalid}>
To: ${RECIPIENT}
Subject: ${SUBJECT}
Date: $(date '+%a, %d %b %Y %H:%M:%S %z')
Message-ID: <$(date +%s)@$(hostname)>
Content-Type: text/plain; charset=utf-8
X-Mailer: Proxmox Monitor Script

EMAILHEADER

# Append body
echo "$BODY" >> "$TMPFILE"

# Send via postfix
sendmail -t < "$TMPFILE" && \
    echo "✅ Email enviado para ${RECIPIENT}" || \
    echo "❌ Falha ao enviar email" >&2

exit 0
