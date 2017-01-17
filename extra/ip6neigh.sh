#!/bin/sh

##################################################################################
#
#  Copyright (C) 2016 André Lange & Craig Miller
#
#  See the file "LICENSE" for information on usage and redistribution
#  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
#  Distributed under GPLv2 License
#
##################################################################################


#	Script to command and display information gathered by ip6neigh.
#	Script is called by luci-app-command for a web interface, or can be run directly.
#
#	by André Lange & Craig Miller	Jan 2017

readonly VERSION="1.0.2"

readonly HOSTS_FILE="/tmp/hosts/ip6neigh"
readonly CACHE_FILE="/tmp/ip6neigh.cache"
readonly SERVICE_NAME="ip6neigh-svc.sh"


#Display help text
display_help() {
	echo "ip6neigh Command Line Script v${VERSION}"
	echo -e
	echo -e "Usage: $CMD COMMAND ..."
	echo -e
	echo -e "Available commands:"
	echo -e "\t{ start | restart | stop }"
	echo -e "\t{ enable | disable }"
	echo -e "\tlist\t[ all | sta[tic] | dis[covered] ]"
	echo -e "\tname\t{ ADDRESS }"
	echo -e "\taddress\t{ NAME } [ 1 ]"
	echo -e "\tmac\t{ NAME | ADDRESS }"
	echo -e "\thost\t{ NAME | ADDRESS }"
	echo -e "\twhois\t{ ADDRESS | MAC | NAME }"
	echo -e
	echo -e "Typing shortcuts: rst lst addr hst who whos"
	exit 1
}

#Returns SUCCESS if the service is running.
is_running() {
	pgrep -f "$SERVICE_NAME" >/dev/null
	return "$?"
}

#Checks if the service is running.
check_running() {
	if ! is_running; then
		>&2 echo "The service is not running."
		exit 2
	fi
	return 0
}

#Checks if hosts and cache files exist.
check_files() {
	[ -f "$HOSTS_FILE" ] && [ -f "$CACHE_FILE" ] && return 0
	exit 2
}

#init.d shortcut commands
start_service() {
	if is_running; then
		>&2 echo "The service is already running."
		exit 2
	fi
	/etc/init.d/ip6neigh start
}
stop_service() {
	check_running && /etc/init.d/ip6neigh stop
}
restart_service() {
	/etc/init.d/ip6neigh restart
}
enable_service() {
	/etc/init.d/ip6neigh enable
}
disable_service() {
	/etc/init.d/ip6neigh disable
}

#Prints the hosts file in a user friendly format.
list_hosts() {
	check_running
	check_files
	
	#Get the line number that divides the two sections of the hosts file
	local ln=$(grep -n '^#Discovered' "$HOSTS_FILE" | cut -d ':' -f1)
	
	case "$1" in
		#All hosts without comments or blank lines
		all)
			grep '^[^#]' "$HOSTS_FILE" |
				awk '{printf "%-30s %s %s\n",$2,$1,$3}' |
				sort
		;;
		#Only static hosts
		sta*)
			awk "NR>1&&NR<(${ln}-1)"' {printf "%-30s %s %s\n",$2,$1,$3}' "$HOSTS_FILE" |
				sort
		;;
		#Only discovered hosts
		dis*)
			awk "NR>${ln}"' {printf "%-30s %s %s\n",$2,$1,$3}' "$HOSTS_FILE" |
				sort
		;;
		#All hosts with comments
		'')
			echo "#Predefined hosts"
			awk "NR>1&&NR<(${ln}-1)"' {printf "%-30s %s %s\n",$2,$1,$3}' "$HOSTS_FILE" |
				sort
			echo -e "\n#Discovered hosts"
			awk "NR>${ln}"' {printf "%-30s %s %s\n",$2,$1,$3}' "$HOSTS_FILE" |
				sort
		;;
		#Invalid parameter
		*)	display_help;;
	esac
}

#Replaces '.' with '\.' in FQDN for not confusing grep.
escape_dots() {
	eval "$1=$(echo "'$2'" | sed 's/\./\\\./g')"
}

#Loads the domain name config.
load_domain() {
	DOMAIN=$(uci get ip6neigh.config.domain 2>/dev/null)
	if [ -z "$DOMAIN" ]; then
		DOMAIN=$(uci get dhcp.@dnsmasq[0].domain 2>/dev/null)
	fi
	if [ -z "$DOMAIN" ]; then DOMAIN='lan'; fi
}

#Displays the addresses for the supplied name
show_address() {
	check_running
	check_files
	
	#Prepare name for grep
	local name
	escape_dots name "$1"
	load_domain
	
	case "$2" in
		#Any number of addresses 
		'')
			grep -i -E " ${name}$| ${name}\.${DOMAIN}$" "$HOSTS_FILE" |
				cut -d ' ' -f1
		;;
		#Limit to one address
		'1')
			grep -m 1 -i -E " ${name}$| ${name}\.${DOMAIN}$" "$HOSTS_FILE" |
				cut -d ' ' -f1
		;;
		#Invalid parameter
		*) display_help;;
	esac
}

#Displays the name for the IPv6 or MAC address
show_name() {
	check_running
	check_files
	
	#Get name from the hosts file.
	grep -m 1 -i "^$1 " "$HOSTS_FILE" | cut -d ' ' -f2
}

#Display the MAC address for a simple name, FQDN or IPv6 address.
show_mac() {
	check_running
	check_files
	
	local name
	
	#Check if it's address or name.
	echo "$1" | grep -q ':'
	if [ "$?" = 0 ]; then
		#It's an address.
		name=$(grep -m 1 -i "^$1 " "$HOSTS_FILE" |
			cut -d ' ' -f2 |
			cut -d '.' -f1
		)
	else
		#It's a simple name or FQDN.
		name=$(echo "$1" | cut -d '.' -f1)
	fi
	
	#Get the MAC address from the cache file.
	grep -m 1 -i " ${name}$" "$CACHE_FILE" |
		cut -d ' ' -f1
}

#Resolves name to address or address to name.
host_cmd() {
	check_running
	check_files
	
	#Check if it's address or name.
	echo "$1" | grep -q ':'
	if [ "$?" = 0 ]; then
		#It's an address.
		grep -m 1 -i "^$1 " "$HOSTS_FILE" |
			awk '{printf "%s is named %s\n",$1,$2}'
	else
		#It's a name.
		load_domain	
		
		#Prepare name for grep
		local name
		escape_dots name "$1"

		grep -i -E " ${name}$| ${name}\.${DOMAIN}$" "$HOSTS_FILE" |
			awk '{printf "%s has address %s\n",$2,$1}'
	fi
}

#Displays the simple name (no FQDN) for the address or all addresses for the simple name.
whois_this() {
	check_running
	check_files
	
	#Check if it's an address
	echo "$1" | grep -q ':'
	if [ "$?" = 0 ]; then
		#Check if it's a MAC address.
		echo "$1" | grep -q '..:..:..:..:..:..'
		if [ "$?" = 0 ]; then
			#MAC address. Get name from the cache file.
			grep -m 1 -i "^$1 " "$CACHE_FILE" |
				awk '{printf "%s is %s\n",$1,$3}'
		else
			#IPv6 address. Get name from the hosts file.
			grep -m 1 -i "^$1 " "$HOSTS_FILE" |
				cut -d '.' -f1 |
				awk '{printf "%s belongs to %s\n",$1,$2}'
		fi
	else
		#Name. Get the addresses from the hosts file.
		grep -i -E " $1(\.|$)" "$HOSTS_FILE" |
			awk '{printf "%-30s %s %s\n",$2,$1,$3}' |
			sort
	fi
}

#This script file
CMD="$0"

#Checks which command was called.
case "$1" in
	'start')			start_service "$0";;
	'stop')				stop_service;;
	'restart'|'rst')	restart_service;;
	'enable')			enable_service;;
	'disable')			disable_service;;
	'list'|'lst')		list_hosts "$2";;
	'address'|'addr')	show_address "$2" "$3";;
	'name')				show_name "$2";;
	'mac')				show_mac "$2";;
	'host'|'hst')		host_cmd "$2" "$3";;
	'whois'|'whos'|'who') whois_this "$2";;
	*)					display_help;;
esac