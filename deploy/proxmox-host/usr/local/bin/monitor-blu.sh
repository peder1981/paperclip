#!/bin/bash
# Monitor do Blu (LXC 104) — paridade com Justatistic (LXC 103)
# Estrutura rica: Telegram + e-mail com detalhes e proximos passos

set -euo pipefail

LXC_ID=104
LXC_IP="192.168.2.104"
LXC_NAME="blu"
LOG_FILE="/var/log/proxmox-monitor.log"
TELEGRAM_CONF="/etc/telegram-notify.conf"
PROTON_CONF="/etc/proton-mail.conf"

[ -f "$TELEGRAM_CONF" ] && source "$TELEGRAM_CONF"
[ -f "$PROTON_CONF" ] && source "$PROTON_CONF"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BLU] $*" | tee -a "$LOG_FILE"; }

# ============================================
# NOTIFICACAO
# ============================================

send_telegram() {
    local title="$1"
    local message="$2"
    local severity="$3"

    local emoji="ℹ️"
    [ "$severity" = "WARN" ] && emoji="⚠️"
    [ "$severity" = "CRITICAL" ] && emoji="🚨"

    local telegram_msg="${emoji} *${title}*\n\n${message}"

    command -v telegram-notify &>/dev/null && \
        telegram-notify "$telegram_msg" 2>/dev/null || true
}

send_email() {
    local subject="$1"
    local body="$2"
    local severity="$3"

    # So envia email para WARN e CRITICAL
    if [ "$severity" != "INFO" ] && command -v notify-email.sh &>/dev/null; then
        notify-email.sh "$subject" "$body" 2>/dev/null || \
            log "ERROR: Falha ao enviar email"
    fi
}

alert() {
    local severity="$1"  # INFO, WARN, CRITICAL
    local title="$2"
    local message="$3"
    local details="${4:-}"

    log "$severity: $title - $message"

    local telegram_body="$message"
    [ -n "$details" ] && telegram_body="${telegram_body}\n\n*Detalhes:*\n${details}"

    send_telegram "$title" "$telegram_body" "$severity"

    local email_body="================================================\n"
    email_body+="  BLU MONITOR - ALERTA\n"
    email_body+="================================================\n\n"
    email_body+="📅 Data: $(date '+%d/%m/%Y às %H:%M:%S')\n"
    email_body+="🖥️  Host: $(hostname)\n"
    email_body+="🔴 Severidade: $severity\n\n"
    email_body+="------------------------------------------------\n"
    email_body+="📋 TÍTULO: $title\n"
    email_body+="------------------------------------------------\n\n"
    email_body+="$message\n\n"

    if [ -n "$details" ]; then
        email_body+="------------------------------------------------\n"
        email_body+="📝 DETALHES:\n"
        email_body+="------------------------------------------------\n"
        email_body+="$details\n\n"
    fi

    email_body+="------------------------------------------------\n"
    email_body+="💡 PRÓXIMOS PASSOS:\n"
    email_body+="------------------------------------------------\n"
    email_body+="$(_get_next_steps "$severity" "$title")\n\n"
    email_body+="================================================\n"
    email_body+="Este é um e-mail automático do sistema de\n"
    email_body+="monitoramento do Proxmox Homelab.\n"
    email_body+="Não responda a este e-mail."

    send_email "$title" "$email_body" "$severity"
}

_get_next_steps() {
    local severity="$1"
    local title="$2"

    case "$severity" in
        "CRITICAL")
            echo "1. Verifique imediatamente o LXC 104 no Proxmox"
            echo "2. Acesse: https://$(hostname):8006"
            echo "3. Execute: pct enter 104"
            echo "4. Verifique logs: tail -100 /var/log/blu*.log"
            echo "5. Se necessário: pct restart 104"
            ;;
        "WARN")
            echo "1. Verifique o status no painel 10 minutos"
            echo "2. Execute manualmente: monitor-blu.sh"
            echo "3. Confira o sync: pct exec 104 -- ps aux | grep sync_conciliadoras"
            echo "4. Confira o Streamlit: pct exec 104 -- curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8501/"
            ;;
        *)
            echo "Nenhuma ação necessária no momento."
            ;;
    esac
}

# ============================================
# VERIFICACAO
# ============================================

check_lxc_status() {
    local status
    status=$(pct status $LXC_ID 2>/dev/null | awk '{print $2}')

    if [ "$status" != "running" ]; then
        alert "CRITICAL" "LXC $LXC_ID ($LXC_NAME) está OFFLINE!" \
            "O container Blu não está rodando." \
            "Status atual: $status\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        return 1
    fi
    return 0
}

check_http() {
    local port=$1
    local description=$2
    local response

    # ponytail: probe dentro do CT via localhost (funciona com bind 127.0.0.1 ou 0.0.0.0)
    response=$(pct exec $LXC_ID -- timeout 5 curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")

    if [ "$response" = "200" ]; then
        log "INFO: $description ($port) - OK"
        return 0
    else
        alert "WARN" "Serviço $description não respondendo" \
            "O serviço $description na porta $port não está respondendo." \
            "IP: $LXC_IP\nPorta: $port\nHTTP Code: $response\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        return 1
    fi
}

check_sync_process() {
    local procs
    procs=$(pct exec $LXC_ID -- pgrep -f "sync_conciliadoras|streamlit run app.py" 2>/dev/null || echo "")

    if [ -z "$procs" ]; then
        alert "WARN" "Blu sem processos ativos" \
            "Nenhum processo streamlit/sync encontrado no LXC 104." \
            "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    else
        log "INFO: Processos Blu ativos: $(echo $procs | tr '\n' ' ')"
    fi
}

check_resources() {
    log "INFO: Verificando recursos..."

    local cpu mem disk
    cpu=$(pct exec $LXC_ID -- top -bn1 2>/dev/null | grep "^%Cpu" | awk '{print $2}' || echo "0")
    mem=$(pct exec $LXC_ID -- free 2>/dev/null | grep Mem | awk '{printf "%.0f", $3/$2*100}' || echo "0")
    disk=$(pct exec $LXC_ID -- df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "0%")

    local cpu_num=${cpu%.*}
    local mem_num=${mem%.*}
    local disk_num=${disk%\%}

    if [ "${cpu_num:-0}" -gt 80 ] 2>/dev/null; then
        alert "WARN" "CPU alta no Blu" \
            "Uso de CPU acima de 80% (${cpu}%)." \
            "CPU: ${cpu}%\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    if [ "${mem_num:-0}" -gt 85 ] 2>/dev/null; then
        alert "WARN" "Memória alta no Blu" \
            "Uso de memória acima de 85% (${mem}%)." \
            "Memória: ${mem}%\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    fi

    if [ "${disk_num:-0}" -gt 90 ] 2>/dev/null; then
        alert "CRITICAL" "Disco quase cheio no Blu" \
            "Uso de disco acima de 90% (${disk})." \
            "Disco: ${disk}\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')\n\nAções recomendadas:\n1. Limpe arquivos temporários\n2. Verifique logs grandes\n3. Considere expandir o disco"
    fi

    echo "   CPU: ${cpu:-0}% | Mem: ${mem:-0}% | Disk: ${disk:-0%}"
}

# ============================================
# MAIN
# ============================================

main() {
    log "INFO: Inicializando monitoramento Blu..."

    echo "📊 Blu Monitor - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="

    if ! check_lxc_status; then
        log "CRITICAL: LXC Blu não está rodando"
        exit 1
    fi
    echo "✅ LXC $LXC_ID ($LXC_NAME) está rodando"

    echo ""
    echo "🌐 Serviços:"
    check_http 8501 "Streamlit App" || true

    echo ""
    echo "⚙️ Processos:"
    check_sync_process

    echo ""
    echo "💻 Recursos:"
    check_resources

    echo ""
    echo "✅ Monitoramento concluído com sucesso"

    send_telegram "Blu Monitor" \
        "Monitoramento concluído em $(date '+%H:%M')\nLXC 104: OK\nSync + Streamlit: verificados" \
        "INFO"
}

main "$@"
