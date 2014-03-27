#!/bin/bash


splmemused=`cat /proc/spl/kmem/slab | awk '{ SUM += $3 } END { print SUM/1024/1024/1024 }' | cut -d. -f1`

if [ "$splmemused" -gt "$1" ]; then
    for s in `ls /tmp/my*.sock`; do /local/mysql.server/bin/mysql -N -S $s -e "stop slave SQL_THREAD;"; done
    sync
    echo 2 > /proc/sys/vm/drop_caches 
    for s in `ls /tmp/my*.sock`; do /local/mysql.server/bin/mysql -N -S $s -e "start slave SQL_THREAD;"; done
fi
