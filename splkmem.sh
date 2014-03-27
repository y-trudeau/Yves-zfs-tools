echo "splkmem `cat /proc/spl/kmem/slab | awk '{ SUM += $3 } END { print SUM/1024/1024/1024 }'` GB"

