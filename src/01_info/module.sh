### Функции подменю "Инфо":
###########################


ip4info() { printf "%s\n" "$(curl --connect-timeout 1 -s ipinfo.io | jq -C '. | {ip, hostname, city, region, country, timezone, org}' | awk -F'{' '{print $1}' | awk -F'}' '{print $1}' | awk -F',' '{print $1}')"; }
ip6info() { curl --connect-timeout 1 v6.ipinfo.io; }

ip_show() {
ip_conn=$(ip -c a | awk '{print "    " $0}')
ip_routes=$(ip -c r | awk '{print "    " $0}')
printf "\n    ${bnc}Соединения:\n%s\n" "$ip_conn"
printf "\n    ${bnc}Маршруты:\n%s\n" "$ip_routes"
printf "${nc}"
}
awg_show() {
awg_all=$(awg show all | awk '{print "    " $0}')
printf "\n    AWG Соединения:\n%s\n" "$awg_all"
printf "${nc}"
}
