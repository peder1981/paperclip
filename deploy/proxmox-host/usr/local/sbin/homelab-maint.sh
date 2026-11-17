#!/bin/bash
# homelab-maint.sh — manutencao e vigilancia do host Proxmox e de todas as LXCs.
#   maintain : limpeza diaria (logs, journal, tmp, caches, core dumps, docker) no host e em cada LXC
#   check    : vigilancia horaria (disco, SMART, erros de filesystem, backups, unidades com falha)
# Regras de limpeza sao conservadoras: so apaga o que e regeneravel ou ja rotacionado e antigo.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C
STATE=/var/lib/homelab-maint; mkdir -p "$STATE/alerts"
LOG=/var/log/homelab-maint.log
COOLDOWN=43200   # 12h entre repeticoes do mesmo alerta
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
alert() {   # alert <chave> <mensagem>
  local key now last; key=$(printf '%s' "$1" | md5sum | cut -c1-16); now=$(date +%s)
  last=$(cat "$STATE/alerts/$key" 2>/dev/null || echo 0)
  log "ALERTA $1: $2"
  if [ $((now - last)) -ge $COOLDOWN ]; then
    command -v telegram-notify >/dev/null && telegram-notify "[homelab] $2" >/dev/null 2>&1
    echo "$now" > "$STATE/alerts/$key"
  fi
}
running_cts() { pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}'; }

lxc_payload() { cat <<'LXC'
set -u
# journal: garante um teto (so cria se a LXC ainda nao tiver nenhum)
if ! grep -qsE '^SystemMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null; then
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=200M\n' > /etc/systemd/journald.conf.d/90-homelab-cap.conf
  systemctl restart systemd-journald 2>/dev/null
  echo "journal: teto de 200M criado"
fi
journalctl --vacuum-size=200M >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
# tmp: so o que ninguem tocou ha mais de 10 dias (acesso, conteudo e criacao)
for d in /tmp /var/tmp; do
  find "$d" -xdev -mindepth 1 -type f -atime +10 -mtime +10 -ctime +10 -delete 2>/dev/null
  find "$d" -xdev -mindepth 1 -type d -empty -ctime +10 -delete 2>/dev/null
done
# logs ja rotacionados com mais de 60 dias
find /var/log -xdev -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.log.[0-9]" -o -name "*.log.[0-9][0-9]" \) -mtime +60 -delete 2>/dev/null
# core dumps de verdade (cabecalho ELF, tipo core) com mais de 2 dias.
# NUNCA dentro do armazenamento do Docker/containerd: apagar por fora corrompe camadas de imagem.
find / -xdev \( -path /var/lib/docker -o -path /var/lib/containerd \) -prune -o -type f -name "core.[0-9]*" -size +1M -mtime +2 -print 2>/dev/null | while read -r f; do
  if [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' ')" = "7f454c46" ] && [ "$(od -An -tu2 -j16 -N2 "$f" 2>/dev/null | tr -d ' ')" = "4" ]; then
    rm -f "$f" && echo "core removido: $f"
  fi
done
# docker: log de container acima de 200M fica so com os ultimos 20M; remove imagens sem tag e cache de build antigo
if command -v docker >/dev/null 2>&1; then
  for l in /var/lib/docker/containers/*/*-json.log; do
    [ -f "$l" ] || continue
    if [ "$(stat -c %s "$l")" -gt 209715200 ]; then
      tail -c 20971520 "$l" > "$l.keep" 2>/dev/null && cat "$l.keep" > "$l" && rm -f "$l.keep" && echo "docker log reduzido: $(basename "$l")"
    fi
  done
  # core dumps dentro de containers em execucao: remove pelo proprio container, nunca pelo overlay2
  for c in $(docker ps --format '{{.Names}}'); do
    docker exec "$c" sh -c 'command -v od >/dev/null 2>&1 || exit 0; find / -xdev -type f -name "core.[0-9]*" -size +1M -mtime +2 2>/dev/null | while read -r f; do if [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d " ")" = "7f454c46" ] && [ "$(od -An -tu2 -j16 -N2 "$f" 2>/dev/null | tr -d " ")" = "4" ]; then rm -f "$f" && echo "core removido em container: $f"; fi; done' 2>/dev/null | sed "s/^/[$c] /"
  done
  docker image prune -f >/dev/null 2>&1
  docker builder prune -f --filter until=168h >/dev/null 2>&1
fi
echo "disk=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
LXC
}

maintain() {
  log "== maintain inicio"
  journalctl --vacuum-size=500M >/dev/null 2>&1
  apt-get clean >/dev/null 2>&1
  for d in /tmp /var/tmp; do
    find "$d" -xdev -mindepth 1 -type f -atime +10 -mtime +10 -ctime +10 -delete 2>/dev/null
    find "$d" -xdev -mindepth 1 -type d -empty -ctime +10 -delete 2>/dev/null
  done
  find /var/log -xdev -type f \( -name "*.gz" -o -name "*.xz" -o -name "*.log.[0-9]" -o -name "*.log.[0-9][0-9]" \) -mtime +60 -delete 2>/dev/null
  find /root/backups -maxdepth 1 -type f -name "monitor-config-*.tar.gz" -mtime +60 -delete 2>/dev/null
  for v in $(running_cts); do
    out=$(lxc_payload | timeout 900 pct exec "$v" -- sh -s 2>&1 | tr '\n' ';' | cut -c1-600)
    log "LXC $v: ${out:-sem saida}"
  done
  log "== maintain fim root=$(df --output=pcent / | tail -1 | tr -dc 0-9)% pool=$(lvs -o data_percent --noheadings pve/data | tr -d ' ')%"
}

check() {
  # 1. espaco em disco: montagens do host e raiz de cada LXC
  for m in / /mnt/ernesto-data /mnt/sdc2; do
    mountpoint -q "$m" || { [ "$m" = "/" ] || alert "mount-$m" "Ponto de montagem $m NAO esta montado."; continue; }
    u=$(df --output=pcent "$m" | tail -1 | tr -dc 0-9); [ "${u:-0}" -ge 85 ] && alert "disk-$m" "Disco $m em ${u}%."
  done
  for v in $(running_cts); do
    u=$(timeout 30 pct exec "$v" -- df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9)
    [ "${u:-0}" -ge 88 ] && alert "lxc-disk-$v" "LXC $v com disco em ${u}%."
    f=$(timeout 30 pct exec "$v" -- systemctl --failed --no-pager --plain 2>/dev/null | awk '/failed/{print $1}' | xargs)
    [ -n "$f" ] && alert "lxc-failed-$v-$f" "LXC $v com unidades em falha: $f"
  done
  f=$(systemctl --failed --no-pager --plain 2>/dev/null | awk '/failed/{print $1}' | xargs)
  [ -n "$f" ] && alert "host-failed-$f" "Host com unidades em falha: $f"
  # 2. SMART: setores realocados ou pendentes que aumentam
  for d in $(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    a=$(smartctl -A "/dev/$d" 2>/dev/null); [ -z "$a" ] && continue
    re=$(echo "$a" | awk '/Reallocated_Sector_Ct/{print $10}'); pe=$(echo "$a" | awk '/Current_Pending_Sector/{print $10}'); un=$(echo "$a" | awk '/Offline_Uncorrectable/{print $10}')
    cur="${re:-0} ${pe:-0} ${un:-0}"; prev=$(cat "$STATE/smart-$d" 2>/dev/null || echo "$cur")
    set -- $prev; pr=$1; pp=$2; pu=$3
    if [ "${re:-0}" -gt "$pr" ] || [ "${pe:-0}" -gt "$pp" ] || [ "${un:-0}" -gt "$pu" ]; then
      alert "smart-$d-$cur" "Disco /dev/$d piorou no SMART: realocados $pr->${re:-0}, pendentes $pp->${pe:-0}, incorrigiveis $pu->${un:-0}. Planejar troca."
    fi
    [ "${pe:-0}" -gt 0 ] && alert "smart-pending-$d" "Disco /dev/$d com ${pe} setores pendentes."
    echo "$cur" > "$STATE/smart-$d"
    smartctl -H "/dev/$d" 2>/dev/null | grep -q "PASSED" || alert "smart-health-$d" "Disco /dev/$d NAO passou no teste geral do SMART."
  done
  # 3. erros de sistema de arquivos ou de I/O no kernel na ultima hora
  k=$(journalctl -k --since "-65min" --no-pager 2>/dev/null | grep -E "XFS \(.*\): (Corruption|Internal error|metadata I/O error)|Shutting down filesystem|EXT4-fs error|I/O error, dev|Buffer I/O error|Medium Error" | tail -2 | cut -c1-200)
  [ -n "$k" ] && alert "kernel-fs" "Erro de disco ou sistema de arquivos no kernel: $k"
  # 4. backups: cada LXC em execucao precisa de backup com menos de 36h
  bl=$(pvesm list pbs-backup --content backup 2>/dev/null)
  if [ -z "$bl" ]; then alert "pbs-list" "Nao consegui listar os backups no PBS (storage pbs-backup)."
  else
    now=$(date +%s)
    for v in $(running_cts); do
      t=$(echo "$bl" | awk -v id="$v" 'NR>1{split($1,a,"/"); if(a[3]==id && a[4]>m) m=a[4]} END{print m}')
      if [ -z "$t" ]; then alert "bkp-none-$v" "LXC $v nao tem nenhum backup no PBS."
      else age=$(( (now - $(date -d "$t" +%s 2>/dev/null || echo 0)) / 3600 )); [ "$age" -ge 36 ] && alert "bkp-old-$v" "LXC $v sem backup ha ${age}h (ultimo: $t)."
      fi
    done
  fi
  # 5. o proprio maintain precisa ter rodado nas ultimas 30h
  last=$(grep -E "== maintain fim" "$LOG" 2>/dev/null | tail -1 | cut -c1-19)
  if [ -n "$last" ]; then h=$(( ($(date +%s) - $(date -d "$last" +%s)) / 3600 )); [ "$h" -ge 30 ] && alert "maint-stale" "A manutencao diaria nao roda ha ${h}h."; fi
  log "check ok"
}

exec 9>"$STATE/lock"; flock -n 9 || exit 0
case "${1:-}" in
  maintain) maintain ;;
  check) check ;;
  *) echo "uso: $0 maintain|check"; exit 2 ;;
esac
