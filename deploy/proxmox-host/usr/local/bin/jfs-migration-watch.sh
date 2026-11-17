#!/bin/bash
LOG=/var/log/jfs-migration-watch.log
ARCH=$(du -sm /mnt/jfs/pbs-secondary/lxc103/archive 2>/dev/null | cut -f1)
IMG=$(du -sm /mnt/jfs/pbs-secondary/vz-images 2>/dev/null | cut -f1)
POOL=$(lvs pve/data --noheadings -o data_percent 2>/dev/null | tr -d " ")
ARCH_SRC=$(pct exec 103 -- du -sm /opt/justatistic/archive 2>/dev/null | cut -f1)
ALIVE=$(pgrep -fc "justatistic.*tar|rsync.*vz-images" || true)
TS=$(date "+%Y-%m-%d %H:%M:%S")
echo "$TS archive_src=${ARCH_SRC}M archive_dst=${ARCH}M images_dst=${IMG}M pool=${POOL}% procs=${ALIVE}" >> $LOG
# concluido quando dst==src e nao ha mais processo
if [ -n "$ARCH_SRC" ] && [ "$ARCH" = "$ARCH_SRC" ] && [ "$ALIVE" = "0" ]; then
  echo "$TS ARCHIVE COPY COMPLETE 98G -> verificar e liberar CT103" >> $LOG
fi
if ! mountpoint -q /mnt/jfs/pbs-secondary 2>/dev/null; then
  echo "$TS ALERT: JuiceFS desmontado!" >> $LOG
fi
