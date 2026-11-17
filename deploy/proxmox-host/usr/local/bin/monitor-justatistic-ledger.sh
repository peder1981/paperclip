#!/bin/bash
# Monitor do Ledger Justatistic (LXC 103)
# Versão melhorada com notificações claras

set -euo pipefail

LXC_ID=103
LXC_IP="192.168.2.103"
LXC_NAME="jurstat"
LOG_FILE="/var/log/proxmox-monitor.log"
TELEGRAM_CONF="/etc/telegram-notify.conf"
PROTON_CONF="/etc/proton-mail.conf"

[ -f "$TELEGRAM_CONF" ] && source "$TELEGRAM_CONF"
[ -f "$PROTON_CONF" ] && source "$PROTON_CONF"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [JUSTATISTIC] $*" | tee -a "$LOG_FILE"; }

# ============================================
# FUNÇÕES DE NOTIFICAÇÃO MELHORADAS
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
    
    # Só envia email para WARN e CRITICAL
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
    
    # Format message for Telegram
    local telegram_body="$message"
    [ -n "$details" ] && telegram_body="${telegram_body}\n\n*Detalhes:*\n${details}"
    
    send_telegram "$title" "$telegram_body" "$severity"
    
    # Format detailed email
    local email_body="================================================\n"
    email_body+="  JUSTATISTIC MONITOR - ALERTA\n"
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
            echo "1. Verifique imediatamente o LXC 103 no Proxmox"
            echo "2. Acesse: https://$(hostname):8006"
            echo "3. Execute: pct enter 103"
            echo "4. Verifique logs: tail -100 /var/log/jurstat*.log"
            echo "5. Se necessário: pct restart 103"
            ;;
        "WARN")
            echo "1. Verifique o status no painel 10 minutos"
            echo "2. Execute manualmente: monitor-justatistic-ledger.sh"
            echo "3. Confira se há erros no build_ledger:"
            echo "   runuser -u postgres -- psql -d justatistic -c \"SELECT * FROM build_ledger WHERE status='error';\""
            ;;
        *)
            echo "Nenhuma ação necessária no momento."
            ;;
    esac
}

# ============================================
# FUNÇÕES DE VERIFICAÇÃO
# ============================================

check_lxc_status() {
    local status
    status=$(pct status $LXC_ID 2>/dev/null | awk '{print $2}')
    
    if [ "$status" != "running" ]; then
        alert "CRITICAL" "LXC $LXC_ID ($LXC_NAME) está OFFLINE!" \
            "O container Justatistic não está rodando." \
            "Status atual: $status\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        return 1
    fi
    return 0
}

check_http() {
    local port=$1
    local description=$2
    local response
    
    # ponytail: probe dentro do CT via localhost (funciona com bind 127.0.0.1 ou 0.0.0.0) — mesmo padrão do monitor-blu.sh
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

check_ledger_db() {
    log "INFO: Consultando build_ledger..."
    
    local result
    result=$(pct exec $LXC_ID -- bash -c "
        runuser -u postgres -- psql -d justatistic -t -c \"SELECT COUNT(*) FROM build_ledger WHERE status='error';\" 2>/dev/null | tr -d '[:space:]' || echo '0'" 2>/dev/null || echo "0")
    
    local error_count=${result:-0}
    
    local building_result
    building_result=$(pct exec $LXC_ID -- bash -c "
        runuser -u postgres -- psql -d justatistic -t -c \"SELECT COUNT(*) FROM build_ledger WHERE status='building';\" 2>/dev/null | tr -d '[:space:]' || echo '0'" 2>/dev/null || echo "0")
    
    local building_count=${building_result:-0}
    
    if [ "$error_count" -gt 0 ] 2>/dev/null; then
        alert "WARN" "Tribunais com ERROR no Ledger" \
            "Existem $error_count tribunal(is) com status 'error' na tabela build_ledger." \
            "Quantidade de erros: $error_count\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')\n\nPara ver detalhes:\nrunuser -u postgres -- psql -d justatistic -c \"SELECT * FROM build_ledger WHERE status='error';\""
    fi
    
    # Verificar se há builds presos há muito tempo
    local stuck_result
    stuck_result=$(pct exec $LXC_ID -- bash -c "
        runuser -u postgres -- psql -d justatistic -t -c \"SELECT COUNT(*) FROM build_ledger WHERE status='building' AND built_at < NOW() - INTERVAL '30 minutes';\" 2>/dev/null | tr -d '[:space:]' || echo '0'" 2>/dev/null || echo "0")
    
    local stuck_count=${stuck_result:-0}
    
    if [ "$stuck_count" -gt 0 ] 2>/dev/null; then
        alert "WARN" "Builds presos há >30 minutos" \
            "Existem $stuck_count tribunal(is) presos no status 'building' há mais de 30 minutos." \
            "Isso pode indicar problema no processo de build.\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    log "INFO: Ledger OK (errors: $error_count, building: $building_count)"
}

check_resources() {
    log "INFO: Verificando recursos..."
    
    # cpu/mem/disk propositalmente globais: lidos em main() apos check_resources
    cpu=$(pct exec $LXC_ID -- top -bn1 2>/dev/null | grep "^%Cpu" | awk '{print $2}' || echo "0")
    mem=$(pct exec $LXC_ID -- free 2>/dev/null | grep Mem | awk '{printf "%.0f", $3/$2*100}' || echo "0")
    disk=$(pct exec $LXC_ID -- df -h / 2>/dev/null | awk 'NR==2 {print $5}' || echo "0%")
    
    local cpu_num=${cpu%.*}
    local mem_num=${mem%.*}
    local disk_num=${disk%\%}
    
    if [ "${cpu_num:-0}" -gt 80 ] 2>/dev/null; then
        alert "WARN" "CPU alta no Justatistic" \
            "Uso de CPU acima de 80% (${cpu}%)." \
            "CPU: ${cpu}%\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    if [ "${mem_num:-0}" -gt 85 ] 2>/dev/null; then
        alert "WARN" "Memória alta no Justatistic" \
            "Uso de memória acima de 85% (${mem}%)." \
            "Memória: ${mem}%\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    if [ "${disk_num:-0}" -gt 90 ] 2>/dev/null; then
        alert "CRITICAL" "Disco quase cheio no Justatistic" \
            "Uso de disco acima de 90% (${disk})." \
            "Disco: ${disk}\nTimestamp: $(date '+%Y-%m-%d %H:%M:%S')\n\nAções recomendadas:\n1. Limpe arquivos temporários\n2. Verifique logs grandes\n3. Considere expandir o disco"
    fi
}

check_build_process() {
    local procs
    procs=$(pct exec $LXC_ID -- "pgrep -f 'build|ledger|parquet' | head -5" 2>/dev/null || echo "")
    
    if [ -z "$procs" ]; then
        log "INFO: Nenhum processo de build ativo"
    else
        log "INFO: Processos de build ativos: $procs"
    fi
}

# ============================================
# MAIN
# ============================================

main() {
    log "INFO: Inicializando monitoramento Justatistic Ledger..."
    
    echo "📊 Justatistic Ledger Monitor - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=========================================="
    
    # Check LXC status
    if ! check_lxc_status; then
        log "CRITICAL: LXC Justatistic não está rodando"
        exit 1
    fi
    echo "✅ LXC $LXC_ID ($LXC_NAME) está rodando"
    
    # Check HTTP
    echo ""
    echo "🌐 Serviços:"
    check_http 8502 "Streamlit App" || true
    # Não alertar mais para 8501 pois é interno
    
    # Check ledger
    echo ""
    echo "📚 Ledger:"
    check_ledger_db
    
    # Check resources
    echo ""
    echo "💻 Recursos:"
    check_resources
    echo "   CPU: ${cpu:-0}% | Mem: ${mem:-0}% | Disk: ${disk:-0%}"
    
    # Check build processes
    echo ""
    echo "⚙️ Builds:"
    check_build_process
    
    echo ""
    echo "✅ Monitoramento concluído com sucesso"
    
    # Info notification
    send_telegram "Justatistic Monitor" \
        "Monitoramento concluído em $(date '+%H:%M')\nLXC 103: OK\nLEDGER: Verificado" \
        "INFO"
}

main "$@"
