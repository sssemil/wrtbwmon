#!/system/bin/sh
#
# Traffic logging tool for OpenWRT-based routers
#
# Created by Emmanuel Brucy (e.brucy AT qut.edu.au)
# Updated by Peter Bailey (peter.eldridge.bailey@gmail.com)
# Updated by Emil Suleymanov (suleymanovemil8@gmail.com) for Android OS
#
# Based on work from Fredrik Erlandsson (erlis AT linux.nu)
# Based on traff_graph script by twist - http://wiki.openwrt.org/RrdTrafficWatch
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

[ -p /cache/wrtbwmon.pipe ] || ./busybox mkfifo /cache/wrtbwmon.pipe

trap "rm -f /cache/*$$.tmp; kill $$" INT
baseDir=.
dataDir=.

chains='INPUT OUTPUT FORWARD'
DEBUG=
interfaces='wlan0'
DB=$2
mode=

header="#mac,ip,iface,in,out,total,first_date,last_date"


lock()
{
    attempts=0
    while [ $attempts -lt 10 ]; do
	mkdir /cache/wrtbwmon.lock && break
	attempts=$((attempts+1))
	if [ -d /cache/wrtbwmon.lock ]; then
	    if [ ! -d /proc/$(cat /cache/wrtbwmon.lock/pid) ]; then
		echo "WARNING: Lockfile detected but process $(cat /cache/wrtbwmon.lock/pid) does not exist !"
		rm -rf /cache/wrtbwmon.lock
	    else
		sleep 1
	    fi
	fi
    done
    #[[ -n "$DEBUG" ]] && echo $$ "got lock after $attempts attempts"
    trap '' INT
}

unlock()
{
    rm -rf /cache/wrtbwmon.lock
    #[[ -n "$DEBUG" ]] && echo $$ "released lock"
    trap "rm -f /cache/*$$.tmp; kill $$" INT
}

# chain
newChain()
{
    chain=$1

    #Create the RRDIPT_$chain chain (it doesn't matter if it already exists).
    ./iptables -t mangle -N RRDIPT_$chain 2> /dev/null
    
    #Add the RRDIPT_$chain CHAIN to the $chain chain (if non existing).
    ./iptables -t mangle -L $chain --line-numbers -n | grep "RRDIPT_$chain" > /dev/null
    if [ $? -ne 0 ]; then
	./iptables -t mangle -L $chain -n | grep "RRDIPT_$chain" > /dev/null
	if [ $? -eq 0 ]; then
	    [ -n "$DEBUG" ] && echo "DEBUG: ./iptables chain misplaced, recreating it..."
	    ./iptables -t mangle -D $chain -j RRDIPT_$chain
	fi
	./iptables -t mangle -I $chain -j RRDIPT_$chain
    fi
}

# chain tun
newRuleIF()
{
    chain=$1
    IF=$2
    
    ./iptables -t mangle -nvL RRDIPT_$chain | grep " $IF " > /dev/null
    if [ "$?" -ne 0 ]; then
	if [ "$chain" = "OUTPUT" ]; then
	    ./iptables -t mangle -A RRDIPT_$chain -o $IF -j RETURN
	elif [ "$chain" = "INPUT" ]; then
	    ./iptables -t mangle -A RRDIPT_$chain -i $IF -j RETURN
	fi
    elif [ -n "$DEBUG" ]; then
	echo "DEBUG: table mangle chain $chain rule $IF already exists?"
    fi
}

update()
{
    [ -z "$DB" ] && echo "ERROR: Missing argument 2 (database file)" && exit 1	
    [ ! -f "$DB" ] && echo $header > "$DB"
    [ ! -w "$DB" ] && echo "ERROR: $DB not writable" && exit 1

    lock

    ./iptables -nvxL -t mangle -Z > /cache/iptables_$$.tmp

    ./busybox awk -v mode="$mode" -v interfaces="$interfaces" -f readDB.awk \
	$DB \
	/proc/net/arp \
	/cache/iptables_$$.tmp
    
    unlock
}

############################################################
cd $3

case $1 in
    "update" )
	update
	rm -f /cache/*$$.tmp
	exit
	;;
    
    "setup" )
	for chain in $chains; do
	    newChain $chain
	done

	# track local data
	for chain in INPUT OUTPUT; do
	    for interface in $interfaces; do
		[ -n "$interface" ] && [ -e "/sys/class/net/$interface" ] && newRuleIF $chain $interface
	    done
	done

	# this will add rules for hosts in arp table
	update

	rm -f /cache/*$$.tmp
        cat $DB
	;;

    "remove" )
	./iptables-save | grep -v RRDIPT | ./iptables-restore
	;;
    
    *)
	echo "Usage: $0 {setup|update|publish|remove} [options...]"
	echo "Options: "
	echo "   $0 setup database_file"
	echo "   $0 update database_file"
	echo "Examples: "
	echo "   $0 setup /cache/usage.db"
	echo "   $0 update /cache/usage.db"
	echo "   $0 remove"
	echo "Note: [user_file] is an optional file to match users with their MAC address"
	echo "       Its format is: 00:MA:CA:DD:RE:SS,username , with one entry per line"
	;;
esac
