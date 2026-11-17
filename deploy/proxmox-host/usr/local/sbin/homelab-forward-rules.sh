#!/bin/sh
# Regras FORWARD wt0 <-> vmbr0 (acesso remoto via NetBird à rede dos LXCs).
# Sem posição fixa: o NetBird cria as regras dele (inclusive o "-i wt0 -j DROP") alguns segundos
# depois do serviço subir, e "-I FORWARD 3/4" falhava com "Index of insertion too big" quando a
# cadeia ainda estava vazia. Aqui: espera o DROP aparecer, coloca as nossas regras logo ANTES dele
# e, se encontrar uma cópia na ordem velha (depois do DROP), remove. Idempotente.
set -u
IPT=${IPT:-/sbin/iptables}
WAIT_SECS=${WAIT_SECS:-90}
DROP='-A FORWARD -i wt0 -j DROP'

line() { $IPT -S FORWARD | grep -n -x -F -- "$1" | head -1 | cut -d: -f1; }   # nº da linha no -S (regra = linha-1)

/sbin/sysctl -w net.ipv4.ip_forward=1 >/dev/null || exit 1

t=0
while [ -z "$(line "$DROP")" ] && [ "$t" -lt "$WAIT_SECS" ]; do sleep 2; t=$((t + 2)); done

ensure() {   # $1 = regra como o `iptables -S` a imprime; demais = argumentos do iptables
    spec=$1; shift
    d=$(line "$DROP"); r=$(line "$spec")
    if [ -z "$r" ] || { [ -n "$d" ] && [ "$r" -gt "$d" ]; }; then
        if [ -n "$d" ]; then $IPT -I FORWARD $((d - 1)) "$@"; else $IPT -A FORWARD "$@"; fi
    fi
    while [ "$($IPT -S FORWARD | grep -c -x -F -- "$spec")" -gt 1 ]; do   # mantém só a primeira cópia
        last=$($IPT -S FORWARD | grep -n -x -F -- "$spec" | tail -1 | cut -d: -f1)
        $IPT -D FORWARD $((last - 1))
    done
}

ensure '-A FORWARD -i wt0 -o vmbr0 -j ACCEPT' -i wt0 -o vmbr0 -j ACCEPT
ensure '-A FORWARD -i vmbr0 -o wt0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' \
       -i vmbr0 -o wt0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
