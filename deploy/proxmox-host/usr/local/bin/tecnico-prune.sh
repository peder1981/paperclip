#!/bin/bash
# Poda diaria de tecnico/: remove clones de repo (.git, worktrees) e binarios RPO
# que agentes largam como "evidencia". Mantem fontes, diffs, logs, MDs, amostras.
LOG=/var/log/tecnico-prune.log
T=/var/lib/lxc108-data/tecnico
echo "$(date +%F\ %T) === prune ===" >> $LOG
# remove dirs que sao clones de repositorio (contem .git)
find $T -mindepth 2 -maxdepth 3 -type d \( -name ".git" -o -name "repo" -o -name "my-advpl-project" \) -prune -print0 2>/dev/null | while IFS= read -r -d "" d; do
  d=$(dirname "$d"); [ -d "$d/.git" ] && { du -sh "$d" >> $LOG 2>&1; rm -rf "$d"; echo "removido clone $d" >> $LOG; }
done
# remove binarios grandes soltos (RPO, zips de repo)
find $T -type f \( -name "*.rpo" -o -name "*.RPO" -o -name "*.ptm" -o -name "*.dtc" \) -size +50M -delete -print 2>/dev/null >> $LOG
echo "$(date +%F\ %T) tecnico agora: $(du -sh $T | cut -f1)" >> $LOG
