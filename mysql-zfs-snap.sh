#!/bin/bash
#
# mysql_zfs_snap.sh version v 0.1 2013-06-24
# Yves Trudeau, Percona
# Inspired by zfs_snap of Nils Bausch
#
# take ZFS snapshots with a time stamp
# -h help page
# -d choose default options: hourly, daily, weekly, monthly, yearly
# -f filesystem to snapshot 
# -v verbose output
# -p pretend - don't take snapshots
# -S mysql socket
# -u user mysql user
# -P mysql password 
# -w warmup script

DEBUGFILE="/tmp/mysql-zfs-snap.log"
if [ "${DEBUGFILE}" -a -w "${DEBUGFILE}" -a ! -L "${DEBUGFILE}" ]; then
        exec 9>>"$DEBUGFILE"
	exec 2>&9
	date >&9
	echo "$*" >&9
	set -x
else
	echo 9>/dev/null
fi
export PATH=$PATH:/sbin:/usr/sbin
# Path to binaries used
ZPOOL=`which zpool`
ZFS=`which zfs`
EGREP=`which egrep`
GREP=`which grep`
TAIL=`which tail`
SORT=`which sort`
XARGS=`which xargs`
DATE=`which date`
CUT=`which cut`
TR=`which tr`
MYSQL=`which mysql`
ECHO=`which echo`
REV=`which rev`
FLOCK=`which flock`

# set default values
DEFAULTOPT=
LABELPREFIX="Automatic"
LABEL=`${DATE} +"%FT%H:%M"`
vflag=
pflag=
socket=/tmp/mysql.sock
mysql_user=root
password=
filesystem=
warmup=

# go through passed options and assign to variables
while getopts 'hd:l:vpu:S:P:f:w:' OPTION
do
        case $OPTION in
        d)      DEFAULTOPT="$OPTARG"
                ;;
        l)      LABELPREFIX="$OPTARG"
                ;;
        v)      vflag=1
                ;;
        p)      pflag=1
                ;;
        u)      mysql_user="$OPTARG"
                ;;
        f)      filesystem="$OPTARG"
                ;;
	S)	socket="$OPTARG"
		;;
	P)	password="$OPTARG"
		;;
	w)	warmup="$OPTARG"
		;;
        h|?)      printf "Usage: %s: [-h] [-d <default-preset>] [-v] [-p] [-u <mysql user>] [-P <mysql password>] [-S <mysql socket>] [-f <zfs filesystem>] [-w <warmup sql script>]\n" $(basename $0) >&2
                exit 2
                ;;
        esac
done

lockfile=`$ECHO $socket | $REV | $CUT -d"/" -f1 | $REV`
lockfile="/var/lock/${lockfile}.lck"

#Sanity check
if [ ! -z $filesystem ]; then
	checkfs=`${ZFS} list -t snapshot -o name | ${GREP} -c $filesystem`
	if [ "$checkfs" -eq "0" ]; then
	        ${ECHO} "Invalid filesystem"
		exit 1
	fi
else
	${ECHO} "Missing filesyem (-f)"
	exit 1
fi

# go through possible presets if available
if [ -n "$DEFAULTOPT" ]; then
        case $DEFAULTOPT in
        hourly) LABELPREFIX="AutoH"
                LABEL=`${DATE} +"%FT%H:%M"`
                retention=24
                ;;
        daily)  LABELPREFIX="AutoD"
                LABEL=`${DATE} +"%F"`
                retention=7
                ;;
        weekly) LABELPREFIX="AutoW"
                LABEL=`${DATE} +"%Y-%U"`
                retention=4
                ;;
        monthly)LABELPREFIX="AutoM"
                LABEL=`${DATE} +"%Y-%m"`
                retention=12
                ;;
        yearly) LABELPREFIX="AutoY"
                LABEL=`${DATE} +"%Y"`
                retention=10
                ;;
        *)      printf 'Default option not specified\n'
                exit 2
                ;;
        esac
fi

(

#Let aquire the lock for monitoring
$FLOCK -x 200

# do the snapshot dance
if [ "$vflag" ]; then
        echo "Calling flush table and doing ${ZFS} snapshot $filesystem@$LABELPREFIX-$LABEL"
fi

if [ "$pflag" ]; then
        echo "Flushing mysql tables"
else

	ddllock=`$MYSQL -N -u $mysql_user -p$password -S $socket  -e "show processlist;"| grep -ci "killing slave"`
	if [ "$ddllock" -eq "0" ]; then
	#no ddl lock

                $MYSQL -N -u $mysql_user -p$password -S $socket <<EOF
stop slave SQL_THREAD;
EOF

                sleep 60  # Hopefully SQL thread will be done.  This is needed because of 
			  # bug 45940, sql may hang waiting for event in a trx involving innodb _and_ myisam

  		$MYSQL -N -u $mysql_user -p$password -S $socket > /${filesystem}/snap_master_pos.out <<EOF
stop slave;
flush logs;
show master status;
EOF

  		sync

  		$MYSQL -N -u $mysql_user -p$password -S $socket  <<EOF
flush tables with read lock;
\! ${ZFS} snapshot $filesystem@$LABELPREFIX-$LABEL
start slave;
EOF

		if [ "$vflag" ]; then
        		echo "Snapshot taken"
		fi
	else
		if [ "$vflag" ]; then
                        echo "Snapshot blocked by running DDL"
                fi
	fi
fi

if [ "$warmup" ]; then
	cat $warmup |  $MYSQL -N -u $mysql_user -p$password -S $socket &
fi

#DELETE SNAPSHOTS
# adjust retention to work with tail i.e. increase by one
let retention+=1
if [ "$vflag" ]; then
        echo "${ZFS} list -t snapshot -o name | ${GREP} $pool@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention}"
fi

list=`${ZFS} list -t snapshot -o name | ${GREP} $filesystem@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention}`

if [ ! -z "$pflag" ]; then
        if [ "${#list}" -gt 0 ]; then
                echo "Delete recursively:"
                echo "$list"
        else
                echo "No snapshots to delete for pool ${pool}"
        fi
else
	if [ "${#list}" -gt 0 ]; then
                $(${ZFS} list -t snapshot -o name | ${GREP} $filesystem@${LABELPREFIX} | ${SORT} -r | ${TAIL} -n +${retention} | ${XARGS} -n 1 ${ZFS} destroy -r)
        fi
fi

) 200>$lockfile 
