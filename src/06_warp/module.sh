# --> Функции подменю "NetworkManager" <--
nmcli_show_conn() {
nm_show_conn=$(nmcli -c yes con show | awk '{print "    " $0}')
printf "\n    List connections:${nc}\n%s${nc}\n" "${nm_show_conn}";
}
nmcli_show_devices() {
nm_show_dev=$(nmcli d show | awk '{print "    " $0}')
printf "${bnc}\n    List connections:\n%s${nc}\n" "${nm_show_dev}";
}

nmcli_import_con() {
ask "Импортировать конфиг из файла:[${nc}${NMCLI_DEF_CONF}${bnc}]?" "" iconf;
[[ -z "$iconf" ]] && iconf="$NMCLI_DEF_CONF"
_imp=$(nmcli c import type amneziawg file ${iconf} | awk '{print "    " $0}')
printf "\n    Импорт конфига $iconf:${byel}\n%s\n${nc}" "${_imp}";
_conName=$(nmcli -c yes con modify ${NMCLI_DEF_IFACE} connection.interface-name ${NMCLI_DEF_IFACE} | awk '{print "    " $0}')
printf "\n    Применяю имя соединения ${NMCLI_DEF_IFACE}:${bgrn} %s\n${nc}" "${_conName}";
nmcli_add2zone
nmcli_up
}

nmcli_create_con() {
nmcli_show_conn
ask "Создать соединение:[${nc}${NMCLI_DEF_IFACE}${bnc}]?" "" cname;
[[ -z "$cname" ]] && cname="$NMCLI_DEF_IFACE"
_add=$(nmcli c add type vpn ifname '*' vpn-type amneziawg con-name ${cname} | awk '{print "    " $0}')
printf "\n    Создание соединения $cname:${bgrn}\n%s\n${nc}" "${_add}";
}

nmcli_remove_con() {
ask "Удалить соединение:[${nc}${NMCLI_DEF_IFACE}${bnc}]?" "" rmname;
[[ -z "$rmname" ]] && rmname="$NMCLI_DEF_IFACE"
_del=$(nmcli c del ${rmname} | awk '{print "    " $0}')
printf "\n    Удаление соединения $rmname:${bred}\n%s\n${nc}" "${_del}";
}

# Set interface private key
#nmcli c modify ${NAME} vpn.data "local-private-key=YAnL1JqN5iMHW2kHbNfT9xLqX5vBz1mQWc8p3Kf9R0E="

# Set peer public key
#nmcli c modify ${NAME} vpn.data "peer-1-public-key=XbK2mPw8nR4tY6vLqZ9hF1cJ3sA5gD7eB9uG2pK0M="

# Set peer endpoint
#nmcli c modify ${NAME} vpn.data "peer-1-endpoint='${ENDPOINT}:${ENDPOINT_PORT}'"

# Set peer allowed IPs
#nmcli c modify ${NAME} vpn.data "peer-1-allowed-ips='${ALLOWED_IPS}'"

# Activate the connection
nmcli_up() {
nmcli_show_conn
ask "  Поднять соединение:[${nc}${NMCLI_DEF_IFACE}|n${bnc}]?" "" upname;
[[ "$upname" == "n" ]] && return 0;
[[ -z "$upname" ]] && upname="$NMCLI_DEF_IFACE"
_up=$(nmcli -c yes con up ${upname} | awk '{print "    " $0}')
printf "\n    Поднимаю соединение $upname:${bgrn}\n%s\n${nc}" "${_up}";
local auto=""

ask_yn "  Добавить соединение ${byel}${upname}${bnc} в автозагрузку?" "y" auto
if [[ "$auto" != "yes" ]]; then
    return 0
else
    on_auto=$(nmcli connection modify ${upname} connection.autoconnect yes | awk '{print "    " $0}')
    local -i priority=-905
    priority_auto=$(nmcli connection modify ${upname} connection.autoconnect-priority ${priority} | awk '{print "    " $0}')
    local retries=15
    retries_auto=$(nmcli connection modify ${upname} connection.autoconnect-retries ${retries} | awk '{print "    " $0}')
    printf "\n    Соединение $upname:${bgrn} %s\n${nc}" "добавлено в автозагрузку $on_auto";
    printf "\n    Для соединения $upname, выставлен приоритет:${bgrn}%d %s\n${nc}" ${priority} "$priority_auto";
    printf "\n    Для соединения $upname, установлено ${bgrn}%d неудачных попыток подключения %s\n${nc}" ${retries} "$retries_auto";
fi
}

# Deactivate the connection
nmcli_down() {
nmcli_show_conn
ask "  Погасить соединение: [${nc}${NMCLI_DEF_IFACE}|n${bnc}]?" "" downname;
[[ "$downname" == "n" ]] && return 0;
[[ -z "$downname" ]] && downname="$NMCLI_DEF_IFACE"
_down=$(nmcli -c yes con down ${downname} | awk '{print "    " $0}')
printf "\n    Гашу соединение $downname:${bred}\n%s\n${nc}" "${_down}";
off_auto=$(nmcli connection modify ${downname} connection.autoconnect no | awk '{print "    " $0}')
printf "\n    Соединение $downname:${bred} %s\n${nc}" "удалено из автозагрузки $off_auto";
}

nm_restart() {
_nm_restart="$(systemctl restart NetworkManager.service | awk '{print "    " $0}')"
printf "\n    Перезапуск NetworkManager:${bgrn} %s\n${nc}" ${_nm_restart};
}

# add connection to zone
nmcli_add2zone() {
ask "    Добавить соединение ${NMCLI_DEF_IFACE} в зону: [${nc}${NMCLI_DEF_ZONE}|n${bnc}]?" "${NMCLI_DEF_ZONE}" add2zone;
[[ "$add2zone" == "n" ]] && return 0;
[[ -z "$zonename" ]] && add2zone=${NMCLI_DEF_ZONE}
_add2zone=$(nmcli -c yes con modify ${NMCLI_DEF_IFACE} connection.zone ${add2zone} | awk '{print "    " $0}')
printf "\n    Добавляю соединение ${NMCLI_DEF_IFACE}:${bgrn} %s\n${nc}" "${_add2zone}";
nm_restart
fw_restart
nmcli_up
}

# remove connection from zone
nmcli_delFromZone() {
ask_yn "  Удалить соединение ${byel}${NMCLI_DEF_IFACE}${bnc} из зоны: [${nc}${NMCLI_DEF_ZONE}?" "y" delzone
if [[ "$delzone" != "yes" ]]; then
    return 0
else
_delzone=$(nmcli -c yes con modify ${NMCLI_DEF_IFACE} connection.zone "" | awk '{print "    " $0}')
printf "\n    Удаляю соединение ${NMCLI_DEF_IFACE} из зоны ${bred} %s\n${nc}" "${_delzone}";
nm_restart
fw_restart
nmcli_up
fi
}

