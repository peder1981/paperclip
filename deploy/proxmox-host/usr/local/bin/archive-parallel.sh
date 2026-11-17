#!/bin/bash
DIRS=$(pct exec 103 -- ls /opt/justatistic/archive | grep ^tribunal=)
i=0
for d in $DIRS; do
  echo "$d" >> /tmp/arch-batch$((i % 4)).list
  i=$((i+1))
done
for g in 0 1 2 3; do
  nohup bash -c "while read d; do pct exec 103 -- tar -C /opt/justatistic/archive -cf - \$d | tar -C /mnt/jfs/pbs-secondary/lxc103/archive -xf -; done < /tmp/arch-batch$g.list" > /var/log/arch-batch$g.log 2>&1 &
done
