#!/bin/sh
#
# Traffic logging tool for OpenWRT-based routers
#
# Created by Emmanuel Brucy (e.brucy AT qut.edu.au)
# Updated by Peter Bailey (peter.eldridge.bailey@gmail.com)
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

#set -x

trap "unlock; exit 1" SIGINT

chains='INPUT OUTPUT FORWARD'
DEBUG=1
tun=tun0
DB=$2

header="#mac,ip,iface,peak_in,peak_out,offpeak_in,offpeak_out,first_date,last_date"

dateFormat()
{
    date "+%d-%m-%Y_%H:%M:%S"
}

lock()
{
    while [ -f /tmp/wrtbwmon.lock ]; do
	if [ ! -d /proc/$(cat /tmp/wrtbwmon.lock) ]; then
	    echo "WARNING: Lockfile detected but process $(cat /tmp/wrtbwmon.lock) does not exist !"
	    rm -f /tmp/wrtbwmon.lock
	fi
	sleep 1
    done
    echo $$ > /tmp/wrtbwmon.lock
}

unlock()
{
    rm -f /tmp/wrtbwmon.lock
}

# chain
getTable()
{
    grep "^$1 " /tmp/tables | cut -d' ' -f2
}

# table chain tun
newRuleTUN()
{
    table=$1
    chain=$2
    tun=$3
    
    iptables -t $table -nvL RRDIPT_$chain | grep " $tun " > /dev/null
    if [ "$?" -ne 0 ]; then
	if [ "$2" = "OUTPUT" ]; then
	    iptables -t $table -A RRDIPT_$chain -o $tun -j RETURN
	elif [ "$chain" = "INPUT" ]; then
	    iptables -t $table -A RRDIPT_$chain -i $tun -j RETURN
	fi
    fi
}

# table chain IP
newRule()
{
    table=$1
    chain=$2
    IP=$3

    #Add iptable rules (if non existing).
    iptables -t $table -nL RRDIPT_$chain | grep "$IP " > /dev/null
    if [ $? -ne 0 ]; then
	if [ "$chain" = "OUTPUT" -o "$chain" = "FORWARD" ]; then
	    iptables -t $table -I RRDIPT_$chain -d $IP -j RETURN
	fi
	if [ "$chain" = "INPUT" -o "$chain" = "FORWARD" ]; then
	    iptables -t $table -I RRDIPT_$chain -s $IP -j RETURN
	fi
    fi
}


# MAC IP IFACE IN OUT DB
updatedb()
{
    MAC=$1
    IP=$2
    IFACE=$3
    IN=$4
    OUT=$5
    DB=$6
    
    [ -n "$DEBUG" ] && echo "DEBUG: New traffic for $MAC/$IP since last update: $IN:$OUT"
    
    LINE=$(grep ${MAC} $DB)
    if [ -z "$LINE" ]; then
	[ -n "$DEBUG" ] && echo "DEBUG: $MAC/$IP is a new host !"

	# add rules for new host
	for chain in $chains; do
            table=$(getTable $chain)
	    if [ "$IP" = "NA" ]; then
		if [ -n "$tun" ]; then
		    newRuleTUN $table $chain $tun
		fi
	    else
		newRule $table $chain $IP
	    fi
	done
	
	PEAKUSAGE_IN=0
	PEAKUSAGE_OUT=0
	OFFPEAKUSAGE_IN=0
	OFFPEAKUSAGE_OUT=0

	firstDate=$(dateFormat)
	
	#!@todo get hostname with: nslookup $IP | grep "$IP " | cut -d' ' -f4
    else
	echo $LINE | cut -s -d, -f4-8 > "/tmp/${MAC}_$$.tmp"
	IFS=, read PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT firstDate < "/tmp/${MAC}_$$.tmp"
    fi
    
    if [ "${3}" = "offpeak" ]; then
	echo $LINE | cut -f6,7 -s -d, > "/tmp/${MAC}_$$.tmp"
	IFS=, read OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT < "/tmp/${MAC}_$$.tmp"
	OFFPEAKUSAGE_IN=$((OFFPEAKUSAGE_IN + IN))
	OFFPEAKUSAGE_OUT=$((OFFPEAKUSAGE_OUT + OUT))
    else
	echo $LINE | cut -f4,5 -s -d, > "/tmp/${MAC}_$$.tmp"
	IFS=, read PEAKUSAGE_IN PEAKUSAGE_OUT < "/tmp/${MAC}_$$.tmp"
	PEAKUSAGE_IN=$((PEAKUSAGE_IN + IN))
	PEAKUSAGE_OUT=$((PEAKUSAGE_OUT + OUT))
    fi

    rm -f "/tmp/${MAC}_$$.tmp"
    
    #!@todo combine updates
    grep -v "^$MAC" $DB > /tmp/db_$$.tmp

    trap "" SIGINT
    mv /tmp/db_$$.tmp $DB

    echo $MAC,$IP,$IFACE,$PEAKUSAGE_IN,$PEAKUSAGE_OUT,$OFFPEAKUSAGE_IN,$OFFPEAKUSAGE_OUT,$firstDate,$(dateFormat) >> $DB
    trap "unlock; exit 1" SIGINT
}

echo 'INPUT filter
OUTPUT filter
FORWARD mangle' > /tmp/tables

#!@todo distinguish WAN<->LAN traffic from LAN<->LAN traffic.
# This can be accomplished by setting src IP != our LAN IP in the rules.

case $1 in

    "setup" )
	for chain in $chains; do
            table=$(getTable $chain)
            echo $table
	    #Create the RRDIPT_$chain chain (it doesn't matter if it already exists).
	    iptables -t $table -N RRDIPT_$chain 2> /dev/null

	    #Add the RRDIPT_$chain CHAIN to the $chain chain (if non existing).
	    iptables -t $table -L $chain --line-numbers -n | grep "RRDIPT_$chain" > /dev/null
	    if [ $? -ne 0 ]; then
		iptables -t $table -L $chain -n | grep "RRDIPT_$chain" > /dev/null
		if [ $? -eq 0 ]; then
		    [ -n "$DEBUG" ] && echo "DEBUG: iptables chain misplaced, recreating it..."
		    iptables -t $table -D $chain -j RRDIPT_$chain
		fi
		iptables -t $table -I $chain -j RRDIPT_$chain
	    fi

	    #For each host in the ARP table
            cat /proc/net/arp | tail -n +2 | \
		while read IP TYPE FLAGS MAC MASK IFACE
		do
		    newRule $table $chain $IP
		done

	    #!@todo automate this;
	    # can detect gateway IPs: route -n | grep '^[0-9]' | awk '{print $2}' | sort | uniq | grep -v 0.0.0.0
	    if [ -n "$tun" ]; then
		newRuleTUN $table $chain $tun
	    fi
	done # for all chains
	
	;;
    
    "update" )
	[ -z "$DB" ] && echo "ERROR: Missing argument 2" && exit 1	
	[ ! -f "$DB" ] && echo $header > "$DB"
	[ ! -w "$DB" ] && echo "ERROR: $DB not writable" && exit 1

	lock

	#Read and reset counters
	for chain in $chains; do
	    table=$(getTable $chain)
	    iptables -t $table -L RRDIPT_$chain -vnxZ > /tmp/traffic_${chain}_$$.tmp
	done

	# read tun data
	if [ -n "$tun" ]; then
	    IN=0
	    OUT=0
	    for chain in $chains; do
		grep " $tun " /tmp/traffic_${chain}_$$.tmp > /tmp/${tun}_${chain}_$$.tmp
		read PKTS BYTES TARGET PROT OPT IFIN IFOUT SRC DST < /tmp/${tun}_${chain}_$$.tmp
		[ "$chain" = "OUTPUT" -o "$chain" = "FORWARD" ] && [ "$IFOUT" = "$tun" ] && OUT=$((OUT + BYTES))
		[ "$chain" = "INPUT" -o "$chain" = "FORWARD" ] && [ "$IFIN" = "$tun" ] && IN=$((IN + BYTES))
		rm -f /tmp/${tun}_${chain}_$$.tmp
	    done
	    if [ "$IN" -gt 0 -o "$OUT" -gt 0 ]; then
		updatedb "($tun)" NA $tun $IN $OUT $DB
	    fi
	fi
	
        tail -n +2 /proc/net/arp  | \
	    while read IP TYPE FLAGS MAC MASK IFACE
	    do
		IN=0
		OUT=0
		#Add new data to the graph.
		for chain in $chains; do
		    grep $IP /tmp/traffic_${chain}_$$.tmp > /tmp/${IP}_${chain}_$$.tmp
		    while read PKTS BYTES TARGET PROT OPT IFIN IFOUT SRC DST
		    do
			#!@todo OUT and IN used here refer to the IP's perspective, not ours
			[ "$chain" = "OUTPUT" -o "$chain" = "FORWARD" ] && [ "$DST" = "$IP" ] && IN=$((IN + BYTES))
			[ "$chain" = "INPUT" -o "$chain" = "FORWARD" ] && [ "$SRC" = "$IP" ] && OUT=$((OUT + BYTES))
		    done < /tmp/${IP}_${chain}_$$.tmp
		    rm -f /tmp/${IP}_${chain}_$$.tmp
		done
		
		if [ "${IN}" -gt 0 -o "${OUT}" -gt 0 ]; then
		    updatedb $MAC $IP $IFACE $IN $OUT $DB
		fi
	    done

	#Free some memory
	rm -f /tmp/*_$$.tmp
	unlock
	;;
    
    "publish" )

	[ -z "$DB" ] && echo "ERROR: Missing database argument" && exit 1
	[ -z "$3" ] && echo "ERROR: Missing argument 3" && exit 1
	
	USERSFILE="/etc/dnsmasq.conf"
	[ -f "$USERSFILE" ] || USERSFILE="/tmp/dnsmasq.conf"
	[ -z "$4" ] || USERSFILE=${4}
	[ -f "$USERSFILE" ] || USERSFILE="/dev/null"

	# first do some number crunching - rewrite the database so that it is sorted
	lock
	touch /tmp/sorted_$$.tmp
	cat $DB | while IFS=, read MAC PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT LASTSEEN
		   do
		       echo ${PEAKUSAGE_IN},${PEAKUSAGE_OUT},${OFFPEAKUSAGE_IN},${OFFPEAKUSAGE_OUT},${MAC},${LASTSEEN} >> /tmp/sorted_$$.tmp
		   done
	unlock

        # create HTML page
        echo "<html><head><title>Traffic</title><script type=\"text/javascript\">" > ${3}
        echo "function getSize(size) {" >> ${3}
        echo "var prefix=new Array(\"\",\"k\",\"M\",\"G\",\"T\",\"P\",\"E\",\"Z\"); var base=1000;" >> ${3}
        echo "var pos=0; while (size>base) { size/=base; pos++; } if (pos > 2) precision=1000; else precision = 1;" >> ${3}
        echo "return (Math.round(size*precision)/precision)+' '+prefix[pos];}" >> ${3}
        echo "</script></head><body><h1>Total Usage :</h1>" >> ${3}
        echo "<table border="1"><tr bgcolor=silver><th>User</th><th>Peak download</th><th>Peak upload</th><th>Offpeak download</th><th>Offpeak upload</th><th>Last seen</th></tr>" >> ${3}
        echo "<script type=\"text/javascript\">" >> ${3}

        echo "var values = new Array(" >> ${3}
        sort -n /tmp/sorted_$$.tmp | while IFS=, read PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT MAC LASTSEEN
				     do
					 echo "new Array(" >> ${3}
					 USER=$(grep "${MAC}" "${USERSFILE}" | cut -f2 -s -d, )
					 [ -z "$USER" ] && USER=${MAC}
					 echo "\"${USER}\",${PEAKUSAGE_IN}000,${PEAKUSAGE_OUT}000,${OFFPEAKUSAGE_IN}000,${OFFPEAKUSAGE_OUT}000,\"${LASTSEEN}\")," >> ${3}
				     done
        echo "0);" >> ${3}

        echo "for (i=0; i < values.length-1; i++) {document.write(\"<tr><td>\");" >> ${3}
        echo "document.write(values[i][0]);document.write(\"</td>\");" >> ${3}
	for j in 1 2 3 4; do
            echo "document.write(\"<td>\");document.write(getSize(values[i][$j]));document.write(\"</td>\");" >> ${3}
	done
        echo "document.write(\"<td>\");document.write(values[i][5]);document.write(\"</td>\");" >> ${3}
        echo "document.write(\"</tr>\");" >> ${3}
        echo "}</script></table>" >> ${3}
        echo "<br /><small>This page was generated on `date`</small>" 2>&1 >> ${3}
        echo "</body></html>" >> ${3}

        #Free some memory
        rm -f /tmp/*_$$.tmp
        ;;

    "remove" )
	iptables-save | grep -v RRDIPT | iptables-restore
	;;
    
    *)
	echo "Usage: $0 {setup|update|publish|remove} [options...]"
	echo "Options: "
	echo "   $0 setup"
	echo "   $0 update database_file [offpeak]"
	echo "   $0 publish database_file path_of_html_report [user_file]"
	echo "Examples: "
	echo "   $0 setup"
	echo "   $0 update /tmp/usage.db offpeak"
	echo "   $0 publish /tmp/usage.db /www/user/usage.htm /jffs/users.txt"
	echo "   $0 remove"
	echo "Note: [user_file] is an optional file to match users with their MAC address"
	echo "       Its format is: 00:MA:CA:DD:RE:SS,username , with one entry per line"
	exit
	;;
esac
