#!/bin/bash
set -euo pipefail

# Load configs
for conf in /etc/telegram-notify.conf /etc/proton-mail.conf; do
    [ -f "$conf" ] && source "$conf"
done

LOG_FILE="/var/log/proxmox-monitor.log"
SPARK_MODEL="/opt/models/Spark-X2.5-1.7B-GGUF/Spark-X2.5-1.7B-Q4_K_M.gguf"
LLAMA_CLI="/tmp/llama.cpp/build/bin/llama-cli"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" | tee -a "$LOG_FILE"; }

send_telegram() {
    local msg="$1"
    local severity="${2:-INFO}"
    command -v telegram-notify &>/dev/null && telegram-notify "$msg" 2>/dev/null || true
}

send_email() {
    local subject="$1"
    local body="$2"
    local severity="$3"
    if [ "$severity" = "WARN" ] || [ "$severity" = "CRITICAL" ]; then
        command -v notify-email.sh &>/dev/null && notify-email.sh "$subject" "$body" 2>/dev/null || true
    fi
}

THROTTLE_DIR="/var/lib/proxmox-monitor/throttle"
COOLDOWN="${MONITOR_COOLDOWN:-21600}"   # 6h entre envios do mesmo alerta
should_send() {
    # chave ignora numeros (92% -> 87% continua o mesmo alerta)
    local key now last
    key=$(printf "%s" "$1" | sed -E "s/[0-9.,%]+//g" | md5sum | cut -c1-16)
    mkdir -p "$THROTTLE_DIR"
    now=$(date +%s)
    last=$(cat "$THROTTLE_DIR/$key" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$COOLDOWN" ]; then echo "$now" > "$THROTTLE_DIR/$key"; return 0; fi
    return 1
}

alert() {
    local severity="$1"
    local message="$2"
    log "$severity" "$message"
    if should_send "$severity $message"; then
        send_telegram "[$severity] $message" "$severity"
        send_email "[$severity] $message" "$message" "$severity"
    fi
}

quick_status() {
    echo "📊 Proxmox Homelab Quick Status"
    echo "================================"
    echo "🕐 $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    for lxc in 100 101 103 104 105 106 107 108 109; do
        local name=$(pct config $lxc 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "LXC$lxc")
        local status=$(pct status $lxc 2>/dev/null | awk '{print $2}' || echo "DOWN")
        local icon="✅"
        [ "$status" != "running" ] && icon="🚨"
        echo "$icon LXC $lxc ($name): $status"
    done
    
    echo ""
    echo "🖥️  Host: $(hostname)"
    echo "   CPU Load: $(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)"
    echo "   Memory: $(free -h | awk '/^Mem:/ {printf "%.0f%%", $3/$2*100}')"
    echo "   Disk: $(df -h / | awk 'NR==2 {print $5}')"
}

full_monitor() {
    log "INFO" "Iniciando monitoramento completo..."
    local alerts=0
    local report="📊 Proxmox Homelab Report
🕐 $(date '+%Y-%m-%d %H:%M:%S')
🖥️  $(hostname)

--- LXC Status ---"
    
    for lxc in 100 101 103 104 105 106 107 108 109; do
        local name=$(pct config $lxc 2>/dev/null | grep '^hostname:' | awk '{print $2}' || echo "LXC$lxc")
        local status=$(pct status $lxc 2>/dev/null | awk '{print $2}' || echo "DOWN")
        report="$report
LXC $lxc ($name): $status"
        if [ "$status" != "running" ]; then alert "CRITICAL" "LXC $lxc ($name) está DOWN!"; alerts=$((alerts+1)); fi
    done
    
    local load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    local mem=$(free -h | awk '/^Mem:/ {printf "%.0f%%", $3/$2*100}')
    local disk=$(df -h / | awk 'NR==2 {print $5}')
    
    report="$report

--- Host Resources ---
CPU Load: $load
Memory: $mem
Disk: $disk"
    
    local load_num=$(echo "$load" | awk '{print $1}')
    if (( $(echo "$load_num > 8.0" | bc -l) )); then
        alert "WARN" "CPU load alta: $load"; alerts=$((alerts+1))
    fi
    
    local mem_num=${mem%\%}
    if [ "$mem_num" -gt 90 ]; then alert "WARN" "Memória alta: $mem"; alerts=$((alerts+1)); fi
    
    local disk_num=${disk%\%}
    if [ "$disk_num" -gt 85 ]; then alert "CRITICAL" "Disco quase cheio: $disk"; alerts=$((alerts+1)); fi

    # --- Thin pool pve/data (VG livre ~zero; overprovision ativo) ---
    local pool="0"
    pool=$(lvs pve/data -o data_percent --noheadings 2>/dev/null | tr -d ' %' | cut -d. -f1 || echo "0")
    [ -z "$pool" ] && pool="0"
    report="$report
Thin Pool pve/data: ${pool}%"
    if [ "$pool" -gt 90 ]; then alert "CRITICAL" "Thin pool pve/data em ${pool}% — ver CONTINGENCIA_THINPOOL_SDC2.md"; alerts=$((alerts+1));
    elif [ "$pool" -gt 80 ]; then alert "WARN" "Thin pool pve/data em ${pool}%"; alerts=$((alerts+1)); fi
    
    echo "$report"
    if [ "${FULL_REPORT:-0}" = 1 ] || { [ "$alerts" -gt 0 ] && should_send "REPORT-WITH-ALERTS"; }; then
        send_telegram "$report" "INFO"
    fi
    log "INFO" "Monitoramento completado"
}

case "${1:---quick}" in
    "--full") [ "${2:-}" = "--report" ] && FULL_REPORT=1; full_monitor ;;
    "--quick") quick_status ;;
    "--lxc") pct status "$2" 2>/dev/null || echo "LXC $2 not found" ;;
    *) echo "Usage: $0 [--full] [--quick] [--lxc ID]" ;;
esac
