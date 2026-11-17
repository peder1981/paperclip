#!/bin/bash
# ============================================================
# check-app-backups.sh — frescor e TAMANHO dos backups app-level
# de TODOS os projetos (mede o ARTEFATO real, nao o mtime do log).
# Saida: 0 = OK, 1 = falha. Imprime "LABEL<TAB>MSG" por problema.
# Sem efeitos colaterais. Chamado por monitor-ernesto.sh.
# ============================================================
set -uo pipefail
FAIL=0
EXEC="pct exec"
now=$(date +%s)
H=3600

# ct|label|glob (mais novo por mtime)|max_idade_h|min_bytes
CHECKS=(
  "105|GesCon|/var/backups/gescon/gescon-opt-*.tar.gz|28|1000000"
  "106|GEBAN DB|/var/backups/geban/geban-*-diario.dump|28|5000"
)

newest() {  # $1=ct $2=glob -> imprime caminho do mais recente
  $EXEC "$1" -- bash -c "ls -1 -t $2 2>/dev/null | head -1" 2>/dev/null | tr -d '\r'
}

for row in "${CHECKS[@]}"; do
  IFS='|' read -r ct label glob maxh minb <<<"$row"
  f=$(newest "$ct" "$glob")
  if [[ -z "$f" ]]; then
    echo -e "$label\tSem artefato de backup (CT$ct: $glob)"; FAIL=1; continue
  fi
  read -r ts sz < <($EXEC "$ct" -- bash -c "stat -c '%Y %s' '$f'" 2>/dev/null | tr -d '\r')
  [[ -z "${ts:-}" ]] && { echo -e "$label\tstat falhou em $f"; FAIL=1; continue; }
  ageh=$(( (now - ts) / H ))
  (( ageh > maxh )) && { echo -e "$label\tBackup stale: ${ageh}h (max ${maxh}h) — $(basename "$f")"; FAIL=1; }
  (( sz < minb )) && { echo -e "$label\tBackup truncado: ${sz}B (min ${minb}B) — $(basename "$f")"; FAIL=1; }
done

# blu (104): litestream continuo -> replica S3 (MinIO) e nao esta em erro recente.
lit=$(timeout 25 $EXEC 104 -- bash -c "/usr/bin/litestream databases -config /opt/blu/litestream.yml 2>/dev/null | grep -c s3" 2>/dev/null | tr -d '\r')
# conta erros SOMENTE do processo atual (desde o start do servico), nao de
# processos mortos no journal — backoff antigo nao pode mascarar recuperacao.
lit_err=$(timeout 20 $EXEC 104 -- bash -c 'st=$(systemctl show litestream -p ActiveEnterTimestamp --value); journalctl -u litestream --since "$st" --no-pager 2>/dev/null | grep -c "sync error"' 2>/dev/null | tr -d '\r')
if [[ "${lit:-0}" -lt 1 ]]; then
  echo -e "Blu litestream\tReplicacao S3 nao encontrada (CT104)"; FAIL=1
elif [[ "${lit_err:-0}" -gt 0 ]]; then
  echo -e "Blu litestream\tErro de sync S3 (${lit_err}x em 20min) — replica MinIO caiu (CT104)"; FAIL=1
fi

# 103 jurstat: sem backup app-level por decisao (so PBS) — informativo, nao falha.
echo -e "Justatistic (CT103)\tBackup app-level inexistente por decisao (PBS cobre)"
exit $FAIL
