#!/bin/bash
# script regenerating tertiaries
# $1 = database name
# $2 clone name, ex: clone-1


DEBUGFILE="/tmp/mktertiary-${1}.log"
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
AWK=`which awk`
SED=`which sed`

zfsprefix="mysqldata/mysql-" 

if [ "${#1}" -eq "0" -o "${#2}" -eq "0" ]; then
	${ECHO} "Invocation requires 2 arguments: database and clone name"
	exit 1
fi


# manage the clone
dummy=`${ZFS} list | ${GREP} ${zfsprefix}${1}-${2} > /dev/null`
if [ "$?" -eq "0" ]; then
	# The clone already exists
	# First, stop MySQL
	/local/${1}/etc/mysql.server-${1}-${2} stop

	${ZFS} destroy  ${zfsprefix}${1}-${2}
        if [ "$?" -ne "0" ]; then
                #got an error umounting
                logger "Unable to umount ${zfsprefix}${1}-${2}"
		/local/${1}/etc/mysql.server-${1}-${2} start
                exit 1
	else
		/bin/rm -f /${zfsprefix}${1}-${2}/*
        fi
fi

lastsnap=`${ZFS} list -s creation -o name -t snapshot | ${GREP} AutoD | ${GREP} ${zfsprefix}${1} | tail -1`
${ZFS} clone $lastsnap  ${zfsprefix}${1}-${2}
refcompression=`${ZFS} get -H compression ${zfsprefix}${1} | ${AWK} '{ print $3}'`
refprimarycache=`${ZFS} get -H primarycache ${zfsprefix}${1} | ${AWK} '{ print $3}'`
refrecordsize=`${ZFS} get -H -s recordsize ${zfsprefix}${1} | ${AWK} '{ print $3}'`
${ZFS} set compression=${refcompression}  ${zfsprefix}${1}-${2}
${ZFS} set primarycache=${refprimarycache}  ${zfsprefix}${1}-${2}
${ZFS} set recordsize=${refrecordsize}  ${zfsprefix}${1}-${2}

# Now, setup the directory
cd /local/${1}/${2}
file=`/bin/cat snap_master_pos.out | ${AWK} '{print $1}'`
pos=`/bin/cat snap_master_pos.out | ${AWK} '{print $2}'`
/bin/mv master.info master.info.orig
/bin/cat master.info.orig | ${SED} "2s/.*/$file/" | ${SED} "3s/.*/$pos/" | ${SED} '4s/.*/127.0.0.1/' > master.info
/bin/chown mysql.mysql master.info
/bin/rm -f relay-log.info *.pid

# Finally, start MySQL
/local/${1}/etc/mysql.server-${1}-${2} start
