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
# -H mysql host
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
GAWK=`which gawk`
GREP=`which grep`
TAIL=`which tail`
SORT=`which sort`
XARGS=`which xargs`
DATE=`which date`
CUT=`which cut`
TR=`which tr`
MYSQL=`which mysql`
ECHO=`which echo`

# set default values
DEFAULTOPT=
LABELPREFIX="Automatic"
LABEL=`${DATE} +"%FT%H:%M"`
vflag=
pflag=
socket=/tmp/mysql.sock
mysql_hostname=127.0.0.1
mysql_user=root
password=
filesystem=
warmup=
optS="FALSE"
optH="FALSE"

# go through passed options and assign to variables
while getopts 'hd:l:vpu:S:H:P:f:w:' OPTION
do
    case $OPTION in
        d)  DEFAULTOPT="$OPTARG"
            ;;
        l)  LABELPREFIX="$OPTARG"
            ;;
        v)  vflag=1
            ;;
        p)  pflag=1
            ;;
        u)  mysql_user="$OPTARG"
            ;;
        f)  filesystem="$OPTARG"
            ;;
        S)	socket="$OPTARG"
            optS="TRUE"
            ;;
        H)  mysql_hostname="$OPTARG"
            optH="TRUE"
            ;;
        P)	password="$OPTARG"
            ;;
        w)	warmup="$OPTARG"
            ;;
        h|?)    printf "Usage: %s: [-h] [-d <default-preset>] [-v] [-p] [-u <mysql user>] [-P <mysql password>] [-S <mysql socket>] [-H <mysql_hostname>] [-f <zfs filesystem>] [-w <warmup sql script>]\n" $(basename $0) >&2
                exit 2
                ;;
    esac
done

#Check Mysql Options
if [ $optS == "TRUE" -a $optH == "TRUE" ]; then
    ${ECHO} "You cannot use -S and -H at the same time, specify only one"
    exit 1
elif [ $optS == "FALSE" -a $optH == "FALSE" ]; then
    ${ECHO} "No mysql connection specified"
    exit 1
fi

#Sanity check
if [ ! -z $filesystem ]; then
	checkfs=`${ZFS} list -o name | ${EGREP} -c "^${filesystem}$"`
	if [ "$checkfs" -eq "0" ]; then
	        ${ECHO} "Invalid filesystem"
		exit 1
	else
        mountpoint=`${ZFS} list -t filesystem | ${EGREP} -w "^${filesystem}$"| ${GAWK}  '{print $5}'`
    fi
else
	${ECHO} "Missing filesyem (-f)"
	${ECHO} "File sytem ${filesystem} not found"
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

# do the snapshot dance
if [ "$vflag" ]; then
        echo "Calling flush table and doing ${ZFS} snapshot $filesystem@$LABELPREFIX-$LABEL"
fi

#
#Check if we can connect to mysql, this should be done always
#Copied from http://linuxtitbits.blogspot.nl/2011/01/checking-mysql-connection-status.html
#
dbaccess="denied"
until [[ $dbaccess = "success" ]]; do
   
    if [ $optS == "TRUE" ]; then
        if [ "$pflag" ]; then
            echo "Checking MySQL connection to socket ${socket} "
        fi
        $MYSQL  --user="${mysql_user}" --password="${password}" -S $socket -e exit 2>/dev/null
    elif [ $optH == "TRUE" ]; then
        if [ "$pflag" ]; then
            echo "Checking MySQL connection to host ${mysql_hostname}"
        fi
        $MYSQL  --user="${mysql_user}" --password="${password}" -h $mysql_hostname -e exit 2>/dev/null
    fi   
    
    dbstatus=`echo $?`
    if [ $dbstatus -ne 0 ]; then
        if [ $optS == "TRUE" ]; then
            echo "Can't connect to MySQL server on ${socket} with user ${mysql_user}"
        elif [ $optH == "TRUE" ]; then
            echo "Can't connect to MySQL server on ${mysql_hostname} with user ${mysql_user}"
        fi
        exit 1 
    else
        dbaccess="success"
        if [ "$pflag" ]; then
            echo "Mysql connection Success!"
        fi
    fi
done


if [ "$pflag" ]; then
        echo "Flushing mysql tables"
else
    if [ $optS  == "TRUE" ]; then
        connection_arg="-S $socket "
    elif [ $optH == "TRUE" ]; then
        connection_arg="-h $mysql_hostname "
    fi
    connect_string="$MYSQL -N -n -u $mysql_user -p$password $connection_arg"
  	$connect_string > /${mountpoint}/snap_master_pos.out <<EOF
flush tables with read lock;
flush logs;
show master status;
\! sync
\! ${ZFS} snapshot $filesystem@$LABELPREFIX-$LABEL
EOF

	if [ "$vflag" ]; then
       		echo "Snapshot taken"
	fi
fi

if [ "$warmup" ]; then
	cat $warmup |  $MYSQL -N -u $mysql_user -p$password $connection_arg &
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

