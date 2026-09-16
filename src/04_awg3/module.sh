### Функции подменю "AmneziaWG3"
#####################################

#-> Чтение серверного конфига:
# Значение ключа из секции [Interface] (до первого [Peer]).
awg3_iface_value() {
    local key="$1"
    awk -v k="$key" '
        /^[[:space:]]*\[Peer\]/ { exit }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, "#") == 1) next
            split(line, kv, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
            if (kv[1] == k) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$AWG3_SYSCONF"
}

#-> Заполняет S_S1..S_S4 S_H1..S_H4 S_HPK S_MTU S_PORT S_ADDR S_ADDR6.
awg3_load_server_params() {
    if ! [[ -r "$AWG3_SYSCONF" ]]; then
        log_warn "Серверный конфиг недоступен: $AWG3_SYSCONF, Инициализация сервера делалась?";
        ask_confirm "Инициализировать сервер?" "n" || return 1
        awg3_server_init
    fi
    S_S1=$(awg3_iface_value S1); S_S2=$(awg3_iface_value S2)
    S_S3=$(awg3_iface_value S3); S_S4=$(awg3_iface_value S4)
    S_H1=$(awg3_iface_value H1); S_H2=$(awg3_iface_value H2)
    S_H3=$(awg3_iface_value H3); S_H4=$(awg3_iface_value H4)
    S_HPK=$(awg3_iface_value HeaderProtectionKey)
    S_MTU=$(awg3_iface_value MTU)
    S_PORT=$(awg3_iface_value ListenPort)
    local addr_line
    addr_line=$(awg3_iface_value Address)
    S_ADDR=""; S_ADDR6=""
    local part
    IFS=',' read -ra _addr_parts <<< "$addr_line"
    for part in "${_addr_parts[@]}"; do
        part="${part//[[:space:]]/}"
        [[ -z "$part" ]] && continue
        if [[ "$part" == *:* ]]; then
            if [[ -z "$S_ADDR6" ]]; then S_ADDR6="$part"; fi
        else
            if [[ -z "$S_ADDR" ]]; then S_ADDR="$part"; fi
        fi
    done
    [[ -n "$S_ADDR" ]] || { log_error "В $AWG3_SYSCONF не найден IPv4 Address сервера!"; return 1; }
    [[ -n "$S_PORT" ]] || { log_error "В $AWG3_SYSCONF не найден ListenPort!"; return 1; }
}

server_is_awg3() { [[ -n "${S_HPK:-}" ]]; }

#-> Фактическое состояние сервера читается из PostUp, а не из отдельного файла настроек: конфиг — единственный источник истины, и расходиться с ним нечему.
server_isolation_state() {
    if grep -qE 'FORWARD -i %i -o %i -j DROP' "$AWG3_SYSCONF" 2>/dev/null; then
        printf 'on'
    else
        printf 'off'
    fi
}

server_ipv6_state() {
    if grep -q 'ip6tables' "$AWG3_SYSCONF" 2>/dev/null; then
        printf 'on'
    else
        printf 'off'
    fi
}

require_server_awg3() {
    if server_is_awg3; then return 0; fi
    log_error "Сервер ещё не переведён на AWG $AWG3_PROTOCOL: в $AWG3_SYSCONF нет HeaderProtectionKey!"
    log_error "Сначала выполните: \"Обновить сервер\"!"
}

### Endpoint:
# Порядок: --endpoint > '#Endpoint' из awg0.conf > Endpoint уже существующего клиента > внешний IP.
# Отдельного файла настроек нет — источник истины только awg0.conf, поэтому имя хоста хранится там же комментарием.
awg3_server_endpoint_name() {
    [[ -r "$AWG3_SYSCONF" ]] || return 0
    awk '
        /^[[:space:]]*\[Peer\]/ { exit }
        /^[[:space:]]*#Endpoint[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            print
            exit
        }
    ' "$AWG3_SYSCONF"
}

awg3_resolve_endpoint() {
    if [[ -n "$AWG3_ENDPOINT_OVERRIDE" ]]; then
        echo "${AWG3_ENDPOINT_OVERRIDE%%:*}"
        return 0
    fi
    local saved
    saved=$(awg3_server_endpoint_name)
    if [[ -n "$saved" ]]; then
        echo "$saved"
        return 0
    fi
    local f ep url name
    while IFS= read -r name; do
        f=$(client_conf_path "$name")
        [[ -f "$f" ]] || continue
        ep=$(grep -oP '^Endpoint\s*=\s*\K[^:]+' "$f" 2>/dev/null | head -1 || true)
        if [[ -n "$ep" ]]; then echo "$ep"; return 0; fi
    done < <(awg3_list_client_names)
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ep=$(curl -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ep" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ep"; return 0; fi
    done
    failure_box "Не удалось определить endpoint, укажите его явно: --endpoint HOST!"
    return 1
}

awg3_backup_file() {
    local f="$1"
    local bf=$(basename "$1")
    [[ -f "$f" ]] || return 0
    # Объявление отдельно от присваивания: иначе local маскирует код возврата подстановки, и сбой date остался бы незамеченным.
    local bak
    mkdir -p ${AWG3_SYSCONF_BAK}
    bak="${AWG3_SYSCONF_BAK}/${bf}.bak-$(date '+%Y%m%d%H%M%S')"
    cp -p "$f" "$bak" || log_error "Не создан бэкап ${bak}!"; return 1;
    BACKUP_LAST="$bak"
    log_ok "бэкап: $bak"
}

### Управление сервисом:
########################
awg3_restart() {
    local rc=0
    systemctl restart "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && success_box "Cервис перезапущен." || failure_box "Ошибка перезапуска сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    return $rc
}
awg3_start() {
    local rc=0
    systemctl start "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && success_box "Cервис запущен." || failure_box "Ошибка запуска сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    return $rc
}
awg3_stop() {
    local rc=0
    systemctl stop "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && success_box "Cервис остановлен." || failure_box "Ошибка остановки сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    return $rc
}
awg3_enable() {
    local rc=0
    systemctl enable --now "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && success_box "Cервис включён и запущен." || failure_box "Ошибка включения сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    return $rc
}
awg3_disable() {
    local rc=0
    systemctl disable --now "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
    [[ $rc -eq 0 ]] && success_box "Cервис выключен и остановлен." || failure_box "Ошибка выключения сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    return $rc
}

### Применение конфигурации:
############################
# syncconf переносит только список пиров: параметры самого интерфейса
# (S/H/HeaderProtectionKey) им не меняются, поэтому смена общих параметров требует полного перезапуска.
apply_peers() {
    [[ "$AWG3_DO_APPLY" -eq 1 ]] || { log_warn "Применение пропущено."; return 0; }
    local fd
    exec {fd}>"$AWG3_LOCK_DIR/.awg_apply.lock"
    if ! flock -x -w 120 "$fd"; then
        exec {fd}>&-
        log_warn "Не получен apply-lock, изменения записаны, но не применены."
        return 1
    fi
    local strip_out rc=0
    if strip_out=$(timeout 10 awg-quick strip "$AWG3_SRV_IFACE" 2>/dev/null) \
       && printf '%s\n' "$strip_out" | timeout 10 awg syncconf "$AWG3_SRV_IFACE" /dev/stdin 2>/dev/null; then
        log_ok "Конфигурация применена (syncconf)."
    else
        log_warn "syncconf не сработал, перезапускаю сервис."
        systemctl restart "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || rc=$?
        [[ $rc -eq 0 ]] && log_ok "Cервис перезапущен." || log_warn "Ошибка перезапуска сервиса, подробности: \"systemctl status awg-quick@${AWG3_SRV_IFACE}\"!"
    fi
    exec {fd}>&-
    return $rc
}

awg3_apply_restart() { [[ "$AWG3_DO_APPLY" -eq 1 ]] && awg3_restart || return 0; }

### Рендер серверного конфига:
##############################
generate_server_keys() {
    local priv pub
    priv=$(awg genkey) || log_error "не сгенерирован приватный ключ сервера"
    pub=$(printf '%s' "$priv" | awg pubkey) || log_error "не выведен публичный ключ сервера"
    ( umask 077; printf '%s\n' "$priv" > "$AWG3_SERVER_KEYS/server_private.key" ) || log_error "не записан server_private.key"
    ( umask 077; printf '%s\n' "$pub" > "$AWG3_SERVER_KEYS/server_public.key" ) || log_error "не записан server_public.key"
    chmod 600 "$AWG3_SERVER_KEYS/server_private.key" "$AWG3_SERVER_KEYS/server_public.key"
    _fix_owner "$AWG3_SERVER_KEYS/server_private.key"
    _fix_owner "$AWG3_SERVER_KEYS/server_public.key"
    log_ok "Ключи сервера созданы."
}

# Адрес сервера в IPv6-подсети — первый адрес, ::1.
derive_ipv6_server_addr() {
    local subnet="$1" prefix len
    prefix="${subnet%%/*}"; len="${subnet##*/}"
    prefix="${prefix%::}"
    printf '%s::1/%s' "$prefix" "$len"
}

# Все блоки [Peer] из файла: от первого до конца либо до следующего
# [Interface], который в норме встречается только в начале.
extract_peers() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '
        /^[[:space:]]*\[Peer\]/      { in_peer = 1 }
        /^[[:space:]]*\[Interface\]/ { in_peer = 0 }
        in_peer { print }
    ' "$f"
}

# awg3_render_server_conf OUT PRIVKEY ADDRESS PORT MTU POSTUP POSTDOWN [PEERS_SRC]
# Общие параметры берутся из G_S*/G_H*/G_HPK, отправительские — из G_Jc,
# G_Jmin, G_Jmax, G_I1..G_I5, G_CPA, поэтому вызывающая сторона обязана
# заранее вызвать awg3_gen_shared_params и awg3_gen_sender_params.
# Пиры дописываются во ВРЕМЕННЫЙ файл до mv: иначе сбой между записью конфига
# и добавлением пиров оставил бы живой сервер без единого клиента.
awg3_render_server_conf() {
    local out="$1" privkey="$2" address="$3" port="$4" mtu="$5"
    local postup="$6" postdown="$7" peers_src="${8:-}"
    local dir tmp
    dir=$(dirname "$out")
    mkdir -p "$dir" || log_error "не создан каталог $dir"
    chmod 700 "$dir" 2>/dev/null || true
    tmp=$(mktemp "${out}.tmp.XXXXXX") || log_error "mktemp не сработал"
    chmod 600 "$tmp"
    {
        printf '[Interface]\n'
        # Имя хоста для клиентских Endpoint. Хранится комментарием в самом конфиге, как и #Name у пиров:
        # отдельного файла настроек нет, а выводить DNS-имя из адреса интерфейса неоткуда.
        if [[ -n "${AWG3_ENDPOINT_OVERRIDE:-}" ]]; then
            printf '#Endpoint = %s\n' "${AWG3_ENDPOINT_OVERRIDE%%:*}"
        fi
        printf 'PrivateKey = %s\n' "$privkey"
        printf 'Address = %s\n' "$address"
        printf 'ListenPort = %s\n' "$port"
        printf 'MTU = %s\n' "$mtu"
#        printf 'PostUp = %s\n' "$postup"
#        printf 'PostDown = %s\n' "$postdown"
#        printf '\n'
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$G_S1" "$G_S2" "$G_S3" "$G_S4"
        printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$G_H1" "$G_H2" "$G_H3" "$G_H4"
        printf 'HeaderProtectionKey = %s\n' "$G_HPK"
        printf 'ContentPaddingAddition = %s\n' "$G_CPA"
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$G_Jc" "$G_Jmin" "$G_Jmax"
        local n var
        for n in 1 2 3 4 5; do
            var="G_I${n}"
            if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
        done
    } > "$tmp"
    if [[ -n "$peers_src" && -f "$peers_src" ]]; then
        local peers
        peers=$(extract_peers "$peers_src")
        if [[ -n "$peers" ]]; then
            printf '\n%s\n' "$peers" >> "$tmp"
        fi
    fi
    mv -f "$tmp" "$out" || { rm -f "$tmp"; log_error "Не записан ${out}!"; return 1; }
    chmod 600 "$out"
    _fix_owner "$out"
}

# Публичный ключ сервера: из сохранённого файла, иначе выводится из приватного.
server_public_key() {
    if [[ -r "$AWG3_SERVER_KEYS/server_public.key" ]]; then
        tr -d '[:space:]' < "$AWG3_SERVER_KEYS/server_public.key"
        return 0
    fi
    local priv
    priv=$(awg3_iface_value PrivateKey)
    [[ -n "$priv" ]] || log_error "в $AWG3_SERVER_KEYS нет PrivateKey"
    printf '%s' "$priv" | awg pubkey
}

### Команда: server-init:
# Создание сервера AWG 3.0 с нуля: ключи, параметры обфускации, NAT, конфиг, форвардинг.
# Промежуточной стадии 2.0 не существует, server-upgrade здесь не
# участвует — он остаётся только для уже существующих 2.0-серверов.
awg3_guard_existing_server() {
    if [[ -f "$AWG3_SYSCONF" ]] && [[ "$AWG3_SRV_FORCE" -ne 1 ]]; then
        log_error "Сервер уже существует: ${AWG3_SYSCONF}!"
        log_error "Пересоздать с переносом пиров (переменная \$AWG3_SRV_FORCE=1, или пункт меню: \"Принудительно инициализировать сервер\")!"
        return 1
    fi
    return 0
}

awg3_force_server_init() { AWG3_SRV_FORCE=1; awg3_server_init; }

awg3_server_init() {
#    [ "$1" -lt 1 ] && awg3_guard_existing_server || log "Получена задача принудительно инициализировать сервер. Выполняю."
    awg3_guard_existing_server || return 1
# return 1 || log "Получена задача принудительно инициализировать сервер. Выполняю."
    [[ -n "$AWG3_SRV_PORT" ]] || { awg3_rand_int 1024 65000; AWG3_SRV_PORT=$AWG3_REPLY; }
    validate_port "$AWG3_SRV_PORT" || true
    validate_subnet   "$AWG3_SRV_SUBNET" || true
    validate_mtu      "$AWG3_SRV_MTU"    || true
    port_is_free "$AWG3_SRV_PORT" || log_error "UDP-порт $AWG3_SRV_PORT уже занят"
    local nic=${ifext}
    [[ -n "$nic" ]] || { log_error "Не определён внешний интерфейс — проверьте маршрут по умолчанию!"; return 1; }
    log_ok "Внешний интерфейс: ${nic}."
    local peers_src=""
    if [[ -f "$AWG3_SYSCONF" ]]; then
        # Имя хоста переживает пересоздание сервера: клиенты продолжат подключаться по тому же адресу, если его не задали заново.
        if [[ -z "${AWG3_ENDPOINT_OVERRIDE:-}" ]]; then
            AWG3_ENDPOINT_OVERRIDE=$(awg3_server_endpoint_name)
            [[ -z "$AWG3_ENDPOINT_OVERRIDE" ]] || log "Имя хоста сохранено: ${AWG3_ENDPOINT_OVERRIDE}."
        fi
        awg3_backup_file "$AWG3_SYSCONF"
        peers_src="$BACKUP_LAST"
    fi
    ROLLBACK_SERVER_BAK="$peers_src"
    ROLLBACK_ACTIVE=1
    trap '_rollback_server_init' EXIT
    mkdir -p "$AWG3_SERVER_KEYS"; chmod 700 "$AWG3_SERVER_KEYS"; _fix_owner "$AWG3_SERVER_KEYS"
    generate_server_keys
    local address="$AWG3_SRV_SUBNET"
    if [[ "$AWG3_SRV_IPV6" == "on" ]]; then
        address="${address}, $(derive_ipv6_server_addr "$AWG3_SRV_IPV6_SUBNET")"
    fi
    awg3_gen_shared_params
    awg3_gen_sender_params
    #local postup postdown    #postup= $(awg3_build_postup     "$nic" "$AWG3_SRV_MTU" "$AWG3_SRV_ISOLATION" "$AWG3_SRV_IPV6")    #postdown= $(awg3_build_postdown "$nic" "$AWG3_SRV_MTU" "$AWG3_SRV_ISOLATION" "$AWG3_SRV_IPV6")
    local privkey
    privkey=$(tr -d '[:space:]' < "$AWG3_SERVER_KEYS/server_private.key")
    awg3_render_server_conf "$AWG3_SYSCONF" "$privkey" "$address" "$AWG3_SRV_PORT" "$AWG3_SRV_MTU" "$postup" "$postdown" "$peers_src"
    #enable_forwarding "$AWG3_SRV_IPV6" /etc/sysctl.d/99-awg3.conf || log_warn "Форвардинг не настроен"
    ROLLBACK_ACTIVE=0
    trap - EXIT
    if [[ "$AWG3_DO_APPLY" -eq 1 ]]; then
        systemctl enable --now "awg-quick@${AWG3_SRV_IFACE}" 2>/dev/null || log_warn "Сервис не запустился, смотрите: systemctl status \"awg-quick@${AWG3_SRV_IFACE}.service\"."
    fi
    log_ok "Сервер AWG ${AWG3_PROTOCOL} создан: ${AWG3_SYSCONF}."
    log_ok "Порт: ${AWG3_SRV_PORT}/udp, подсеть: ${AWG3_SRV_SUBNET}, MTU: ${AWG3_SRV_MTU}."
    log_ok "Изоляция клиентов: ${AWG3_SRV_ISOLATION}, IPv6: ${AWG3_SRV_IPV6}."
    log "Далее: добавить клиента в меню \"Управление клиентами\"."
    success_box "Сервер инициализирован."
}

#-> Ловушка висит на EXIT, а не на ERR: die() выходит через exit, и ERR на нём не срабатывает.
_rollback_server_init() {
    local rc=$?
    if [[ "${ROLLBACK_ACTIVE:-0}" -ne 1 ]]; then return 0; fi
    ROLLBACK_ACTIVE=0
    log_error "Сбой при создании сервера — откатываю!"
    rm -f "$AWG3_SERVER_KEYS/server_private.key" "$AWG3_SERVER_KEYS/server_public.key" 2>/dev/null || true
    if [[ -n "${ROLLBACK_SERVER_BAK:-}" && -f "$ROLLBACK_SERVER_BAK" ]]; then
        if cp -p "$ROLLBACK_SERVER_BAK" "$AWG3_SYSCONF"; then
            log_ok "Прежний конфиг восстановлен."
        fi
    else
        rm -f "$AWG3_SYSCONF" 2>/dev/null || true
    fi
    if [[ "$rc" -eq 0 ]]; then rc=1; fi
    exit "$rc"
}

### Команда: awg3_set_endpoint:
# Меняет имя хоста для клиентских Endpoint, не трогая ничего больше.
# Отдельная команда нужна потому, что единственная альтернатива: "Принудительно инициализировать сервер" перегенерирует общие параметры и обесценит все выданные конфиги.
awg3_set_endpoint() {
    local name
    ask "IP или имя endpoint:" "$ipext" name
    [[ -n "$name" ]] || log_error "Укажите адрес или имя хоста: 111.222.333.444 | vpn.example.com!"; return 0;
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]] || log_error "недопустимое имя хоста: '$name'"; return 0;
    [[ -f "$AWG3_SYSCONF" ]] || log_error "серверный конфиг не найден: $AWG3_SYSCONF"; return 0;
    local previous
    previous=$(awg3_server_endpoint_name)
    awg3_backup_file "$AWG3_SYSCONF"
    local tmp
    tmp=$(mktemp "${AWG3_SYSCONF}.tmp.XXXXXX") || log_error "mktemp не сработал"; return 0;
    chmod 600 "$tmp"
    # Строка живёт в [Interface] сразу после заголовка. Прежняя убирается, а не дублируется: иначе awg3_server_endpoint_name читал бы первую попавшуюся.
    awk -v host="$name" '
        BEGIN { done = 0; in_peer = 0 }
        /^[[:space:]]*\[Peer\]/ { in_peer = 1 }
        # Прежняя строка удаляется независимо от флага: она идёт ПОСЛЕ
        # [Interface], то есть встречается уже со взведённым done, и проверка
        # на него оставила бы в файле обе строки разом.
        !in_peer && /^[[:space:]]*#Endpoint[[:space:]]*=/ { next }
        /^[[:space:]]*\[Interface\]/ && !done {
            print
            printf "#Endpoint = %s\n", host
            done = 1
            next
        }
        { print }
    ' "$AWG3_SYSCONF" > "$tmp" || { rm -f "$tmp"; log_error "не перестроен $AWG3_SYSCONF"; return 0; }
    grep -qxF "#Endpoint = ${name}" "$tmp" || { rm -f "$tmp"; log_error "строка не добавилась — в конфиге нет секции [Interface]?"; return 0; }
    mv -f "$tmp" "$AWG3_SYSCONF" || { rm -f "$tmp"; log_error "не записан $AWG3_SYSCONF"; return 0; }
    chmod 600 "$AWG3_SYSCONF"
    if [[ -n "$previous" ]]; then
        log_ok "имя хоста изменено: ${previous} → ${name}"
    else
        log_ok "имя хоста задано: ${name}"
    fi
    log "Уже выданные конфиги продолжат работать по прежнему адресу."
    log "Новое имя попадёт в конфиги, созданные дальше: [Меню \"Управление клиентами AWG3\" - Создать клиента]."
}

awg3_gen() {
    awg3_gen_shared_params
    awg3_gen_sender_params
    cat <<EOF
# AmneziaWG ${AWG3_PROTOCOL} — сгенерировано awg3_generator.sh config version $(date '+%Y%m%d%H%M%S').
# S1-S4, H1-H4 и HeaderProtectionKey должны совпадать на ОБОИХ концах.
# Jc, Jmin, Jmax, I1-I5, ContentPaddingAddition и таймеры — sender-side:
# у каждого устройства могут быть свои, и разные значения лучше.

[Interface]
S1 = ${G_S1}
S2 = ${G_S2}
S3 = ${G_S3}
S4 = ${G_S4}
H1 = ${G_H1}
H2 = ${G_H2}
H3 = ${G_H3}
H4 = ${G_H4}
HeaderProtectionKey = ${G_HPK}
ContentPaddingAddition = ${G_CPA}
Jc = ${G_Jc}
Jmin = ${G_Jmin}
Jmax = ${G_Jmax}
EOF
    local n var
    for n in 1 2 3 4 5; do
        var="G_I${n}"
        if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
    done
    cat <<EOF
RekeyAfterTime = ${G_RA}
RekeyTimeout = ${G_RT}
RejectAfterTime = ${G_RJ}
KeepaliveTimeout = ${G_KA}
MaxHandshakeAttempts = ${G_MHA}
# Требуется amneziawg-go >= 3.0.1 и amneziawg-tools с поддержкой 3.0.
# S1-S4 подняты минимум до ${AWG3_NONCE_SIZE}: nonce шифра берётся из этого padding'а.
EOF
}

awg3_server_upgrade() {
    awg3_load_server_params
    if server_is_awg3; then
        log_warn "Сервер уже на AWG ${AWG3_PROTOCOL} (HeaderProtectionKey присутствует)."
        log_warn "Повторный запуск сгенерирует НОВЫЕ общие параметры и разорвёт все текущие подключения."
        ask_confirm "Всё равно перегенерировать?" "n" || return 1
    fi
    log "После смены общих параметров все клиентские конфиги станут недействительны."
    log "Каждого клиента придётся создать заново: Удалить клиентов, затем Добавить клиента."
    ask_confirm "Всё равно продолжить?" "n" || return 1
    awg3_gen_shared_params
    awg3_backup_file "$AWG3_SYSCONF"
    local tmp
    tmp=$(mktemp "${AWG3_SYSCONF}.tmp.XXXXXX") || { log_error "mktemp не сработал"; return 1; }
    chmod 600 "$tmp"

    # Старые S/H/HPK/CPA вырезаются из [Interface], новые вставляются единым блоком перед первым [Peer].
    # Всё остальное — PostUp, MTU, ListenPort, список пиров — переносится дословно.
    awk -v s1="$G_S1" -v s2="$G_S2" -v s3="$G_S3" -v s4="$G_S4" \
        -v h1="$G_H1" -v h2="$G_H2" -v h3="$G_H3" -v h4="$G_H4" \
        -v hpk="$G_HPK" -v cpa="$G_CPA" '
        function emit_block() {
            printf "\nS1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n", s1, s2, s3, s4
            printf "H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n", h1, h2, h3, h4
            printf "HeaderProtectionKey = %s\n", hpk
            printf "ContentPaddingAddition = %s\n", cpa
        }
        BEGIN { in_iface = 0; done = 0 }
        /^[[:space:]]*\[Interface\]/ { in_iface = 1; print; next }
        /^[[:space:]]*\[Peer\]/ {
            if (in_iface && !done) { emit_block(); done = 1 }
            in_iface = 0; print; next
        }
        {
            if (in_iface) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                split(line, kv, "=")
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
                if (kv[1] ~ /^(S[1-4]|H[1-4]|HeaderProtectionKey|ContentPaddingAddition|Jc|Jmin|Jmax|I[1-5])$/) next
                if (line == "") next
            }
            print
        }
        END { if (in_iface && !done) emit_block() }
    ' "$AWG3_SYSCONF" > "$tmp" || { rm -f "$tmp"; log_error "Не удалось перестроить ${AWG3_SYSCONF}!"; }

    mv -f "$tmp" "$AWG3_SYSCONF" || { rm -f "$tmp"; log_error "Не записан ${AWG3_SYSCONF}!"; }
    chmod 600 "$AWG3_SYSCONF"
    log_ok "Cервер переведён на AWG ${AWG3_PROTOCOL}."
    # syncconf не меняет параметры интерфейса — только полный перезапуск.
    awg3_apply_restart || true
    log_warn "Старые конфиги больше не подключатся — пересоздайте клиентов заново."
}

### safe_rm_tree PATH — удаление каталога с проверками:
# Пути берутся из переменных окружения (AWG3_HOME, AWG3_CONFIGS), и пустое или короткое значение превратило бы rm -rf в катастрофу.
# Отвергаем всё, что не является абсолютным путём глубиной >= 2 внутри разрешённых префиксов.
awg3_safe_rm_tree() {
    local target="${1:-}"
    [[ -z "$target" ]] && { log_error "awg3_safe_rm_tree: пустой путь"; return 0; }
    [[ "$target" != /* ]] && { log_error "awg3_safe_rm_tree: путь не абсолютный: '${target}'"; return 0; }
    [[ "$target" == *..* ]] && { log_error "awg3_safe_rm_tree: путь содержит '..': '${target}'"; return 0; }
    local clean="${target%/}"
    local depth; depth="$(awk -F/ '{print NF - 1}' <<<"$clean")"
    if ((depth < 2)); then
        log_error "awg3_safe_rm_tree: путь слишком короткий, нужно >= 2 сегментов: '${target}'"
        return 0;
    fi
    case "$clean" in
        ${AWG3_HELPERS} | ${AWG3_HELPERS}/* | ${AWG3_CONFIGS} | ${AWG3_CONFIGS}/*) : ;;
        *)
            log_error "awg3_safe_rm_tree: путь вне разрешённых префиксов: '${target}'"
            return 0
            ;;
    esac
    rm -rf -- "$clean"
}

#-> Читает конфиг AWG 2.0 и резервирует непересекающиеся порт и подсеть.
awg3_preflight() {
    step "Preflight: сосуществование с AWG 2.0"
    # Повторный запуск не должен менять порт: клиенты уже раздали конфиги с прежним значением, и смена порта тихо оборвала бы их всех.
    if [[ -r "$AWG3_RESERVED_ENV" ]]; then
            local prev_port prev_subnet
            prev_port="$(awk -F= '/^AWG3_SRV_PORT=/{print $2}' "$AWG3_RESERVED_ENV")"
            prev_subnet="$(awk -F= '/^AWG3_SRV_SUBNET=/{print $2}' "$AWG3_RESERVED_ENV")"
            log "Переустановка: сохраняю прежний резерв."
            log "Порт ${prev_port}, подсеть ${prev_subnet}."
            log "Сбросить резерв: rm ${AWG3_RESERVED_ENV}."
            return 0
    fi
    local awg2_port="" awg2_addr="" awg2_net=""
    if [[ -r "$AWG2_CONF" ]]; then
        awg2_port="$(awg2_field "$AWG2_CONF" ListenPort)"
        awg2_addr="$(awg2_field "$AWG2_CONF" Address)"
        awg2_net="$(cidr_network "$awg2_addr")"
        log_ok "AWG 2.0 найден: ${AWG2_CONF}"
        [[ -n "$awg2_port" ]] && log "Его порт   : ${awg2_port} (не займём)."
        [[ -n "$awg2_net"  ]] && log "Его подсеть: ${awg2_net}/24 (обойдём)."
    else
        log "AWG 2.0 не найден — ставимся на чистый сервер."
    fi
    if [[ -d /sys/module/amneziawg ]]; then
        log_warn "Загружен kernel-модуль amneziawg — это штатно, мы его не трогаем."
        log "Именно поэтому AWG3 не пользуется awg-quick: при модуле он поднял бы."
        log "Kernel-интерфейс вместо нашего userspace-демона."
    fi
    if [[ "$AWG3_SRV_PORT" == "" ]]; then
        AWG3_SRV_PORT="$(pick_port "$awg2_port")"
        validate_port "$AWG3_SRV_PORT" || exit 1
    fi
    if [[ "$AWG3_SRV_SUBNET" == "" ]]; then
        AWG3_SRV_SUBNET="$(pick_subnet "$awg2_net")"
    fi
    mkdir -p "$AWG3_CONFIGS"; chmod 700 "$AWG3_CONFIGS"
    cat >"$AWG3_RESERVED_ENV" <<EOF
# Зарезервировано установщиком AWG3 $(date -Is).
# Проверено на непересечение с AWG 2.0 на момент установки.
AWG3_SRV_PORT=${AWG3_SRV_PORT}
AWG3_SRV_IFACE=${AWG3_SRV_IFACE}
AWG3_ROUTE_TABLE=${AWG3_ROUTE_TABLE}
AWG2_PORT_SEEN=${awg2_port:-none}
AWG2_SUBNET_SEEN=${awg2_net:-none}
EOF
    chmod 600 "$AWG3_RESERVED_ENV"
    log_ok "Зарезервировано: порт ${our_port}, подсеть ${our_net}/24, таблица ${AWG3_ROUTE_TABLE}."
    log "Записано в ${AWG3_RESERVED_ENV}."
}

awg3_edit_default_env() {
    print_section "Параметры сервера AmneziaWG 3"
    if [[ -r "$AWG3_DEFAULT_ENV" ]]; then
        ask_force "Переделываем ${AWG3_DEFAULT_ENV}?" || return 1
        log "Сначала бэкап..."
        awg3_backup || { failure_box log_error "Бэкап не сделан, отмена!"; return 1; }
        print_delete "Переустановка: удаляю прежний ${AWG3_DEFAULT_ENV}."
        rm -f "$AWG3_DEFAULT_ENV" || true
        log "Пишем новый $AWG3_DEFAULT_ENV."
#    else
#        log "Файл резерва переменных окружения $AWG3_RESERVED_ENV не найден. Просто создаём новый."
#        awg3_add_reserv
    fi
    local existing_subnets=""
    while IFS= read -r line; do
        local cidr
        cidr=$(echo "$line" | awk '{print $4}')
        [[ -n "$cidr" ]] && existing_subnets="${existing_subnets} ${cidr}"
    done < <(ip -o addr show | grep "inet " | grep -v "host lo")

    local def_endpoint_ip=${ipext}
    while true; do
        printstr "IP по которому клиенты подключаются к серверу."
        printstr "Если определён верно, просто нажмите Enter."
        ask "Внешний IP (ENDPOINT)" "$def_endpoint_ip" AWG3_NEW_ENDPOINT
        validate_ip "$AWG3_NEW_ENDPOINT" && break
        log_warn "Некорректный IP!"
    done
    log_ok "Внешний IP: ${AWG3_NEW_ENDPOINT}"

    local def_port="${AWG3_DEFAULT_PORT}"
    while true; do
        printstr "UDP порт AmneziaWG. По умолчанию: [$def_port], можно любой свободный."
        ask "UDP порт" "$def_port" AWG3_NEW_PORT
        validate_port "$AWG3_NEW_PORT" > /dev/null 2>&1 || { log_warn "Порт 1-65535"; continue; }
        ! ss -H -uln 2>/dev/null | grep -Eq "[:.]${AWG3_NEW_PORT}[[:space:]]" > /dev/null 2>&1 || { log_warn "Порт ${AWG3_NEW_PORT} уже занят."; continue; }
        break
    done
    log_ok "Порт: ${AWG3_NEW_PORT}"

    #-> Интерфейс туннеля:
    local def_iface="${AWG3_DEFAULT_IFACE}"
    while true; do
        printstr "Интерфейс AmneziaWG. По умолчанию: ${def_iface}."
        ask "Имя интерфейса" "$def_iface" AWG3_NEW_IFACE
        ! validate_tunnel_iface "${AWG3_NEW_IFACE}" > /dev/null 2>&1 || { log_warn "${AWG3_NEW_IFACE}"; continue; }
        break
    done
    log_ok "Интерфейс: ${AWG3_NEW_IFACE}"

    #-> Подсеть туннеля:
    local def_subnet="${AWG3_DEFAULT_SUBNET}"
    while true; do
        printstr "Подсети на интерфейсах сервера: ${existing_subnets}."
        log_warn "Убедитесь что подсеть не совпадает с домашней сетью клиента (роутер, гостевой WiFi). Иначе VPN работать не будет."
        ask "Подсеть туннеля" "$def_subnet" AWG3_NEW_SUBNET
        validate_cidr "${AWG3_NEW_SUBNET}" > /dev/null 2>&1 || { log_error "Формат: 10.10.10.0/24"; continue; }
        local tunnel_base=$(cidr_base "$AWG3_NEW_SUBNET")
        # - subnets_overlap() заточен под 10.X.0.0/24, этого достаточно для схемы AWG -
        if subnets_overlap "$tunnel_base" "$existing_subnets"; then
            log_error "Конфликт с подсетью сервера!"
            log "Попробуйте: 10.3.3.0/24 или 10.33.33.0/24"
            continue
        fi
        #-> Предупреждение о типичных домашних подсетях:
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$tunnel_base" == "$_hs" ]]; then
                printstr "Подсеть ${AWG3_NEW_SUBNET} очень распространена на домашних роутерах!"
                printstr "Если у клиента дома роутер раздаёт ${AWG3_NEW_SUBNET},"
                printstr "VPN работать не будет (конфликт маршрутов)!"
                local _hc=""
                ask_yn "Всё равно использовать?" "n" _hc
                [[ "$_hc" != "yes" ]] && { _home_conflict=true; break; }
                break
            fi
        done
        $_home_conflict && continue
        break
    done
    local tunnel_base
    tunnel_base=$(cidr_base "$AWG3_NEW_SUBNET")
    AWG3_NEW_ADDRESS="${tunnel_base}.1"
    log_ok "Подсеть: ${AWG3_NEW_SUBNET}, IP сервера: ${AWG3_NEW_ADDRESS}"

    #-> DNS:
    local def_dns="${AWG3_DEFAULT_DNS}"
    printstr "DNS для клиентов:"
    select_dns() {
        local _resolver="$1"
        echo -e "  $(cecho Ws "1) $_resolver (IP туннеля): ${AWG3_NEW_ADDRESS}")"
        echo -e "  $(cecho Ms '2')$(cecho Ws ") Предустановленные: ${def_dns}")"
        echo -e "  $(cecho Ws "3) Все: ${AWG3_NEW_ADDRESS}, ${def_dns}")"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[2]\033[1m:\033[0m ')" AWG3_NEW_DNS "$def_dns" -
            case "${AWG3_NEW_DNS:-2}" in
                1) AWG3_NEW_DNS="${AWG3_NEW_ADDRESS}"; break ;;
                2) AWG3_NEW_DNS="${def_dns}"; break ;;
                3) AWG3_NEW_DNS="${AWG3_NEW_ADDRESS}, ${def_dns}"; break ;;
                *) AWG3_NEW_DNS="${def_dns}"; break ;;
            esac
        done
    }
    if systemctl is-active --quiet unbound 2>/dev/null; then
        select_dns "Unbound"
    elif systemctl is-active --quiet named 2>/dev/null; then
        select_dns "Named"
    else
        log "Unbound или named не запущены, по умолчанию: ${AWG3_DEFAULT_DNS}"
        AWG3_NEW_DNS="${def_dns}"
    fi
    print_ok "DNS: ${AWG3_NEW_DNS}"

    #-> AllowedIPs:
    local def_allowed="${AWG3_DEFAULT_ALLOWED_IPS}"
    local kill_switch="0.0.0.0/1, 128.0.0.0/1"
    printstr "Маршрутизация трафика:"
    echo -e "  $(cecho Ms '1')$(cecho Ws ") ${def_allowed} (весь трафик через VPN)")"
    echo -e "  $(cecho Ws "2) ${kill_switch} (kill switch)")"
    echo -e "  $(cecho Ws "3) ${AWG3_NEW_SUBNET} (только туннель)")"
    echo -e "  $(cecho Ws "4) Ввести вручную")"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" AWG3_NEW_ALLOWED_IPS "$def_allowed" -
        case "${AWG3_NEW_ALLOWED_IPS:-1}" in
            1) AWG3_NEW_ALLOWED_IPS="$def_allowed"; break ;;
            2) AWG3_NEW_ALLOWED_IPS="$kill_switch"; break ;;
            3) AWG3_NEW_ALLOWED_IPS="$AWG3_NEW_SUBNET"; break ;;
            4) ask "AllowedIPs" "$def_allowed" AWG3_NEW_ALLOWED_IPS; break ;;
            *) AWG3_NEW_ALLOWED_IPS="$def_allowed"; break ;;
        esac
    done
    log_ok "AllowedIPs: ${AWG3_NEW_ALLOWED_IPS}"

    #-> MTU туннеля:
    local def_mtu="${AWG3_DEFAULT_MTU}"
    printstr "MTU туннеля:"
    echo -e "  $(cecho Ws "1) 1280 - максимальная совместимость (мобильные сети, GTP)")"
    echo -e "  $(cecho Ws "2) 1300 - баланс и совместимость")"
    echo -e "  $(cecho Ms '3')$(cecho Ws ") 1320 - баланс (рекомендуется 'ЭТО БАЗА')")"
    echo -e "  $(cecho Ws "4) 1360 - баланс и скорость")"
    echo -e "  $(cecho Ws "5) 1420 - максимальная скорость (чистый Ethernet)")"
    echo -e "  $(cecho Ws "6) Ввести вручную")"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[3]\033[1m:\033[0m ')" AWG3_NEW_MTU "$def_mtu" -
        case "${AWG3_NEW_MTU:-3}" in
            1) AWG3_NEW_MTU="1280"; break ;;
            2) AWG3_NEW_MTU="1300"; break ;;
            3) AWG3_NEW_MTU="1320"; break ;;
            4) AWG3_NEW_MTU="1360"; break ;;
            5) AWG3_NEW_MTU="1420"; break ;;
            6) ask "MTU" "$def_mtu" AWG3_NEW_MTU; break ;;
            *) AWG3_NEW_MTU="$def_mtu"; break ;;
        esac
    done
    log_ok "MTU: ${AWG3_NEW_MTU}"

    #-> Firewalld Policy:
    local def_fw_policy=${AWG3_DEFAULT_FW_POLICY}
    printstr "Имя firewalld policy:"
    echo -e "  $(cecho Ms '1')$(cecho Ws ") ${def_fw_policy} (туннель в Интернет)")"
    echo -e "  $(cecho Ws "2) Ввести вручную")"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" AWG3_NEW_FW_POLICY "$def_fw_policy" -
        case "${AWG3_NEW_FW_POLICY:-1}" in
            1) AWG3_NEW_FW_POLICY="$def_fw_policy"; break ;;
            2) ask "Имя firewalld policy" "$def_fw_policy" AWG3_NEW_FW_POLICY; break ;;
            *) AWG3_NEW_FW_POLICY="$def_fw_policy"; break ;;
        esac
    done
    log_ok "Имя firewalld policy: ${AWG3_NEW_FW_POLICY}"

    #-> Firewalld Service:
    local def_fw_service=${AWG3_DEFAULT_FW_SERVICE}
    printstr "Имя firewalld service:"
    echo -e "  $(cecho Ws '1')$(cecho Ws ") ${def_fw_service}")"
    echo -e "  $(cecho Ws "2) Ввести вручную")"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" AWG3_NEW_FW_SERVICE "$def_fw_service" -
        case "${AWG3_NEW_FW_SERVICE:-1}" in
            1) AWG3_NEW_FW_SERVICE="$def_fw_service"; break ;;
            2) ask "Имя firewalld service" "$def_fw_service" AWG3_NEW_FW_SERVICE; break ;;
            *) AWG3_NEW_FW_SERVICE="$def_fw_service"; break ;;
        esac
    done
    log_ok "Имя firewalld service: ${AWG3_NEW_FW_SERVICE}"

    #-> Firewalld Zone:
    local def_fw_zone=${AWG3_DEFAULT_FW_ZONE}
    printstr "Имя firewalld zone:"
    echo -e "  $(cecho Ms '1')$(cecho Ws ") ${def_fw_zone}")"
    echo -e "  $(cecho Ws "2) Ввести вручную")"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" AWG3_NEW_FW_ZONE "$def_fw_zone" -
        case "${AWG3_NEW_FW_ZONE:-1}" in
            1) AWG3_NEW_FW_ZONE="$def_fw_zone"; break ;;
            2) ask "Имя firewalld zone" "$def_fw_zone" AWG3_NEW_FW_ZONE; break ;;
            *) AWG3_NEW_FW_ZONE="$def_fw_zone"; break ;;
        esac
    done
    log_ok "Имя firewalld zone: ${AWG3_NEW_FW_ZONE}"

    cat >"${AWG3_DEFAULT_ENV}" <<EOF
### Параметры генерации:
########################
#-> Возможные значения:
# quick, tls, dtls, sip, dns, noise
AWG3_PROFILE="dns"
AWG3_INTENSITY="medium"
AWG3_ROUTER_MODE=0

### Параметры клиентов:
#######################
AWG3_ENDPOINT="${AWG3_NEW_ENDPOINT}"
AWG3_ENDPOINT_OVERRIDE=""
AWG3_CLIENT_DNS="${AWG3_NEW_DNS}"
AWG3_CLIENT_ALLOWED_IPS="${AWG3_NEW_ALLOWED_IPS}"
#-> Задан ли список явно флагом: если да, он уважается как есть, даже когда IPv6-маршруты клиенту не нужны.
AWG3_CLIENT_ALLOWED_IPS_EXPLICIT=0
AWG3_MTU_OVERRIDE=""
AWG3_MAKE_QR=1
AWG3_MAKE_LINK=1
AWG3_DO_APPLY=1
AWG3_PRUNE_KEEP="5"

### Параметры файрвола:
#######################
AWG3_SRV_FW_POLICY="${AWG3_NEW_FW_POLICY}"
AWG3_SRV_FW_SERVICE="${AWG3_NEW_FW_SERVICE}"
AWG3_SRV_FW_ZONE="${AWG3_NEW_FW_ZONE}"

### Параметры awg3_server_init:
###############################
#-> Значение 1 будет заставлять игнорировать имеющийся конфиг сервера
AWG3_SRV_FORCE=0
AWG3_SRV_IFACE="${AWG3_NEW_IFACE}"
#-> Пустой AWG3_SRV_PORT означает «выбрать случайный»: предсказуемый порт сам по себе является признаком.
AWG3_SRV_PORT="${AWG3_NEW_PORT}"
AWG3_SRV_SUBNET="${AWG3_NEW_SUBNET}"
AWG3_SRV_ADDRESS="${AWG3_NEW_ADDRESS}/24"
AWG3_SRV_MTU="${AWG3_NEW_MTU}"
AWG3_SRV_ISOLATION="off"
AWG3_SRV_IPV6="off"
AWG3_SRV_IPV6_SUBNET="fddd:2c4:2c4:2c4::/64"
EOF
    chmod 600 "$AWG3_DEFAULT_ENV"
    success_box "Записано в ${AWG3_DEFAULT_ENV}."
}

remove_awg3_fw_policy() {
    local del_policy=0
    del_policy=$(${fwperm} --delete-policy=${AWG3_FW_POLICY})
    ${fwreload}
    log "${del_policy}."
}

remove_awg3_fw_service() {
    local del_service=0
    del_service=$(${fwperm} --delete-service=${AWG3_FW_SERVICE})
    ${fwreload}
    log "${del_service}."
}

remove_awg3_fw_zone() {
    local rem_zone=0
    del_zone=$(${fwperm} --delete-zone=${AWG3_FW_ZONE})
    ${fwreload}
    log "${del_zone}."
}


#############################
### Управление AWG3 клиентами
#############################
# Наименьший свободный адрес в подсети сервера.
awg3_get_next_client_ip() {
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$S_ADDR") || log_error "не разобрана подсеть сервера '$S_ADDR'"
    declare -A used
    used["$(_int_to_ipv4 $((net_int + 1)))"]=1
    local ip
    while IFS= read -r ip; do
        used["$ip"]=1
    done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$AWG3_SYSCONF" 2>/dev/null || true)
    local i candidate
    for (( i = net_int + 2; i <= bcast_int - 1; i++ )); do
        candidate=$(_int_to_ipv4 "$i")
        if [[ -z "${used[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    log_error "в подсети ${S_ADDR} нет свободных адресов"
}

#-> IPv6 клиента выводится из его IPv4 по смещению в подсети — уникальному при любой маске. 
# Для /24 смещение равно последнему октету, иначе кодируется hex:
awg3_get_client_ipv6() {
    local ipv4="$1"
    [[ -n "${S_ADDR6:-}" ]] || return 0
    local net_int bcast_int offset suffix prefix tprefix
    read -r net_int bcast_int < <(_cidr_bounds "$S_ADDR") || return 0
    offset=$(( $(_ipv4_to_int "$ipv4") - net_int ))
    tprefix="${S_ADDR##*/}"
    if [[ "$tprefix" == "24" ]]; then suffix="$offset"; else suffix=$(printf '%x' "$offset"); fi
    prefix="${S_ADDR6%%::*}"
    [[ "$prefix" == *:* ]] || return 0
    echo "${prefix}::${suffix}"
}

### Рендер клиентского конфига:
# render_client_conf <файл> <privkey> <address> <server_pubkey> <endpoint> <port> [psk]
# Общие параметры берутся из S_*, sender-side — из G_*, поэтому вызывающая сторона обязана предварительно вызвать awg3_load_server_params и awg3_gen_sender_params.
render_client_conf() {
    local out="$1" privkey="$2" address="$3" srv_pub="$4" endpoint="$5" port="$6" psk="$7"
    local mtu="${AWG3_MTU_OVERRIDE:-${S_MTU:-1280}}"
    local tmp
    tmp=$(mktemp "${out}.tmp.XXXXXX") || log_error "mktemp не сработал"
    chmod 600 "$tmp"
    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$privkey"
        printf 'Address = %s\n' "$address"
        printf 'DNS = %s\n' "$AWG3_CLIENT_DNS"
        printf 'MTU = %s\n' "$mtu"
#        printf '\n'
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$S_S1" "$S_S2" "$S_S3" "$S_S4"
        printf 'H1 = %s\nH2 = %s\nH3 = %s\nH4 = %s\n' "$S_H1" "$S_H2" "$S_H3" "$S_H4"
        printf 'HeaderProtectionKey = %s\n' "$S_HPK"
        printf 'ContentPaddingAddition = %s\n' "$G_CPA"
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$G_Jc" "$G_Jmin" "$G_Jmax"
        local n
        for n in 1 2 3 4 5; do
            local var="G_I${n}"
            if [[ -n "${!var}" ]]; then printf 'I%s = %s\n' "$n" "${!var}"; fi
        done
        printf 'RekeyAfterTime = %s\n' "$G_RA"
        printf 'RekeyTimeout = %s\n' "$G_RT"
        printf 'RejectAfterTime = %s\n' "$G_RJ"
        printf 'KeepaliveTimeout = %s\n' "$G_KA"
        printf 'MaxHandshakeAttempts = %s\n' "$G_MHA"
        printf '\n'
        printf '[Peer]\n'
        printf 'PublicKey = %s\n' "$srv_pub"
        if [[ -n "$psk" ]]; then printf 'PresharedKey = %s\n' "$psk"; fi
        printf 'Endpoint = %s:%s\n' "$endpoint" "$port"
        printf 'AllowedIPs = %s\n' "$AWG3_CLIENT_ALLOWED_IPS"
        printf 'PersistentKeepalive = %s\n' "$AWG3_KEEPALIVE"
    } > "$tmp"
    mv -f "$tmp" "$out" || { rm -f "$tmp"; log_error "не записан ${out}!"; }
    chmod 600 "$out"
    _fix_owner "$out"
}

### Команда: generate_qr <имя> <путь к conf> — PNG кладётся рядом с конфигом:
generate_qr() {
    local name="$1" conf="$2"
    [[ "$AWG3_MAKE_QR" -eq 1 ]] || return 0
    if ! command -v qrencode >/dev/null 2>&1; then
        log_warn "qrencode не установлен, QR-код для '$name' не создан"
        return 0
    fi
    local png="${conf%.conf}.png" tmp
    tmp=$(mktemp "${png}.tmp.XXXXXX") || return 0
    if qrencode -t png -o "$tmp" < "$conf"; then
        chmod 600 "$tmp"
        mv -f "$tmp" "$png"
        _fix_owner "$png"
        log_ok "QR-код: $png"
    else
        rm -f "$tmp"
        log_warn "не удалось создать QR-код для '$name'"
    fi
}

### Ссылка vpn:// для приложения Amnezia:
# Формат ровно тот, который приложение AmneziaVPN принимает при импорте ссылки: vpn:// + base64url( BE32(длина JSON) || zlib(JSON) )
# Четыре байта длины впереди — это формат QByteArray::qCompress из Qt, на котором построен клиент; без них qUncompress не разожмёт поток.
# Внутри JSON лежит ВТОРОЙ JSON строкой в поле last_config, а тот несёт целиком текст клиентского конфига в поле config.
# Двойная вложенность не наша выдумка — так устроен формат. Параметры, которых в структурированных полях формата нет (HeaderProtectionKey, ContentPaddingAddition, таймеры 3.0),
# кладутся туда же по именам ключей конфига: приложение, которое их не знает, лишние поля проигнорирует, а полный текст конфига в любом случае едет в config.
# Обрезка пробелов по краям — значения из конфига приходят с ними постоянно.
_trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

#-> Экранирование строки для JSON. Пяти символов достаточно: другого управляющего в конфиге взяться неоткуда:
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

#-> adler32 по stdin — хвост zlib-потока. Печатается восемью hex-цифрами:
_adler32() {
    od -An -v -tu1 | awk '
        BEGIN { a = 1; b = 0 }
        {
            for (i = 1; i <= NF; i++) {
                a = (a + $i) % 65521
                b = (b + a) % 65521
            }
        }
        # Двумя половинами: %x от 32-битного значения в mawk переполняется.
        END { printf "%04x%04x", b, a }
    '
}

#-> Четыре байта числа, старший вперёд:
_be32() {
    local n="$1"
    printf '%b' "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
        "$(( (n >> 8) & 255 ))"  "$(( n & 255 ))")"
}

### zlib-поток из файла в stdout:
# Отдельного упаковщика zlib в системе может не быть, зато gzip есть всегда, а deflate внутри у них один и тот же — различаются только обёртки.
# С флагом -n gzip не пишет в заголовок имя файла и время, поэтому заголовок ровно 10 байт, а хвост (CRC32 + размер) — 8; остаётся заменить их на пару 0x78 0x9c впереди и adler32 в конце.
_zlib_compress() {
    local src="$1" gz size head4 adler
    gz="${src}.gz"
    # Внутри сжатого — приватный ключ клиента, поэтому файл создаётся сразу
    # закрытым: umask ставится в подоболочке вместе с самим перенаправлением.
    ( umask 077; gzip -c -n -9 < "$src" > "$gz" ) || { rm -f "$gz"; return 0; }
    size=$(wc -c < "$gz"); size=$(_trim_ws "$size")
    head4=$(head -c 4 "$gz" | od -An -v -tx1 | tr -d ' \n')
    # Заголовок обязан быть каноническим: 1f8b (магия), 08 (deflate), 00 (флагов нет). Иначе смещения ниже уедут и получится мусор.
    if [[ "$head4" != "1f8b0800" ]]; then
        rm -f "$gz"
        log_warn "неожиданный заголовок gzip ($head4)"
        return 0
    fi
    adler=$(_adler32 < "$src")
    printf '\x78\x9c'
    tail -c +11 "$gz" | head -c "$(( size - 18 ))"
    printf '%b' "\\x${adler:0:2}\\x${adler:2:2}\\x${adler:4:2}\\x${adler:6:2}"
    rm -f "$gz"
}

### Команда: build_vpn_uri <конфиг> [описание] — печатает ссылку vpn:// в stdout:
# Имя сервера в списке приложения; по умолчанию берётся хост из Endpoint.
build_vpn_uri() {
    local conf="$1" desc="${2:-}"
    [[ -f "$conf" ]] || { log_warn "конфиг не найден: $conf"; return 0; }
    local dep
    for dep in gzip base64 od head tail; do
        command -v "$dep" >/dev/null 2>&1 || { log_warn "нет команды $dep — ссылка vpn:// не создана"; return 0; }
    done
    local priv pub psk addr dns mtu endpoint_raw aips keepalive
    priv=$(awg3_conf_value "$conf" PrivateKey interface)
    addr=$(awg3_conf_value "$conf" Address interface)
    dns=$(awg3_conf_value "$conf" DNS interface)
    mtu=$(awg3_conf_value "$conf" MTU interface)
    pub=$(awg3_conf_value "$conf" PublicKey peer)
    psk=$(awg3_conf_value "$conf" PresharedKey peer)
    endpoint_raw=$(awg3_conf_value "$conf" Endpoint peer)
    aips=$(awg3_conf_value "$conf" AllowedIPs peer)
    keepalive=$(awg3_conf_value "$conf" PersistentKeepalive peer)
    [[ -n "$priv" ]] || { log_error "в $conf нет PrivateKey"; return 0; }
    [[ -n "$pub" ]]  || { log_error "в $conf нет PublicKey сервера"; return 0; }
    [[ -n "$endpoint_raw" ]] || { log_error "в $conf нет Endpoint"; return 0; }
    # Хост и порт. IPv6 приходит в скобках — [::1]:443, поэтому обрезать по последнему двоеточию нельзя.
    local host port
    if [[ "$endpoint_raw" == \[*\]:* ]]; then
        host="${endpoint_raw%%]:*}"; host="${host#\[}"
        port="${endpoint_raw##*]:}"
    else
        host="${endpoint_raw%:*}"
        port="${endpoint_raw##*:}"
    fi
    # port уезжает в JSON единственным числом без кавычек: пустое или
    # нечисловое значение сделало бы JSON синтаксически битым, и приложение молча откажется импортировать ссылку.
    [[ "$port" =~ ^[0-9]+$ ]] || { log_error "непонятный Endpoint '$endpoint_raw'"; return 0; }
    local ip4="" ip6="" part
    while IFS= read -r part; do
        part=$(_trim_ws "$part")
        [[ -n "$part" ]] || continue
        part="${part%%/*}"
        if [[ "$part" == *:* ]]; then ip6="${ip6:-$part}"; else ip4="${ip4:-$part}"; fi
    done < <(printf '%s\n' "${addr//,/$'\n'}")
    local dns1 dns2
    dns1=$(_trim_ws "${dns%%,*}")
    if [[ "$dns" == *,* ]]; then dns2=$(_trim_ws "${dns#*,}"); dns2="${dns2%%,*}"; else dns2="$dns1"; fi
    dns1="${dns1:-1.1.1.1}"; dns2="${dns2:-$dns1}"
    mtu="${mtu:-1280}"
    keepalive="${keepalive:-33}"
    desc="${desc:-$host}"
    # AllowedIPs в формате уезжает массивом, а не строкой.
    local aips_json="" first=1
    while IFS= read -r part; do
        part=$(_trim_ws "$part")
        [[ -n "$part" ]] || continue
        if [[ "$first" -eq 1 ]]; then first=0; else aips_json+=","; fi
        aips_json+="\"$(_json_escape "$part")\""
    done < <(printf '%s\n' "${aips//,/$'\n'}")
    [[ -n "$aips_json" ]] || aips_json='"0.0.0.0/0"'
    local inner="{" key val
    for key in H1 H2 H3 H4 Jc Jmin Jmax S1 S2 S3 S4; do
        val=$(awg3_conf_value "$conf" "$key" interface)
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    # I1-I5 в режиме роутера пустуют, а пустые поля приложение принимает за заданные — поэтому только непустые.
    for key in I1 I2 I3 I4 I5; do
        val=$(awg3_conf_value "$conf" "$key" interface)
        [[ -n "$val" ]] || continue
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    for key in HeaderProtectionKey ContentPaddingAddition RekeyAfterTime \
               RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts; do
        val=$(awg3_conf_value "$conf" "$key" interface)
        [[ -n "$val" ]] || continue
        inner+="\"${key}\":\"$(_json_escape "$val")\","
    done
    inner+="\"allowed_ips\":[${aips_json}],"
    inner+="\"client_ip\":\"$(_json_escape "$ip4")\","
    inner+="\"client_ipv6\":\"$(_json_escape "$ip6")\","
    inner+="\"client_priv_key\":\"$(_json_escape "$priv")\","
    # Без psk_key импорт теряет PresharedKey, и рукопожатие не проходит — текста конфига в поле config для этого недостаточно.
    if [[ -n "$psk" ]]; then inner+="\"psk_key\":\"$(_json_escape "$psk")\","; fi
    inner+="\"config\":\"$(_json_escape $(<"$conf"))\","
    inner+="\"hostName\":\"$(_json_escape "$host")\",\"mtu\":\"$(_json_escape "$mtu")\","
    inner+="\"persistent_keep_alive\":\"$(_json_escape "$keepalive")\",\"port\":${port},"
    inner+="\"server_pub_key\":\"$(_json_escape "$pub")\"}"
    local outer="{"
    outer+='"containers":[{"awg":{"isThirdPartyConfig":true,'
    outer+="\"last_config\":\"$(_json_escape "$inner")\","
    outer+="\"port\":\"${port}\",\"protocol_version\":\"2\",\"transport_proto\":\"udp\"},"
    outer+='"container":"amnezia-awg"}],'
    outer+='"defaultContainer":"amnezia-awg",'
    outer+="\"description\":\"$(_json_escape "$desc")\","
    outer+="\"dns1\":\"$(_json_escape "$dns1")\",\"dns2\":\"$(_json_escape "$dns2")\","
    outer+="\"hostName\":\"$(_json_escape "$host")\"}"
    # Приватный ключ клиента идёт через файл рядом с конфигом (каталог 700), а не через /tmp, который читаем всем.
    local tmp size b64
    tmp=$(mktemp "${conf}.uri.XXXXXX") || { log_error "mktemp не сработал"; return 0; }
    chmod 600 "$tmp"
    printf '%s' "$outer" > "$tmp" || { rm -f "$tmp" "${tmp}.gz"; return 1; }
    size=$(wc -c < "$tmp"); size=$(_trim_ws "$size")
    if ! b64=$({ _be32 "$size"; _zlib_compress "$tmp"; } | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='); then
        rm -f "$tmp" "${tmp}.gz"
        log_error "не удалось собрать ссылку vpn://"
        return 0
    fi
    rm -f "$tmp" "${tmp}.gz"
    [[ -n "$b64" ]] || { log_error "пустая ссылка vpn://"; return 0; }
    printf 'vpn://%s\n' "$b64"
}

### Команда: awg3_generate_link <имя> <путь к conf> — файл со ссылкой рядом с конфигом. Готовая ссылка остаётся в LINK_LAST, чтобы её можно было ещё и напечатать.
awg3_generate_link() {
    local name="$1" conf="$2"
    LINK_LAST=""
    [[ "$AWG3_MAKE_LINK" -eq 1 ]] || return 0
    local uri file="${conf%.conf}.vpnuri" tmp
    if ! uri=$(build_vpn_uri "$conf"); then
        log_error "ссылка vpn:// для '$name' не создана"
        return 0
    fi
    tmp=$(mktemp "${file}.tmp.XXXXXX") || { log_error "mktemp не сработал"; return 0; }
    chmod 600 "$tmp"
    printf '%s\n' "$uri" > "$tmp" || { rm -f "$tmp"; return -0; }
    if ! mv -f "$tmp" "$file"; then
        rm -f "$tmp"
        log_error "не записана ссылка $file"
        return 0
    fi
    _fix_owner "$file"
    LINK_LAST="$uri"
    log_ok "ссылка: $file"
}

### Команда: awg3_gen_link:
# Пересобирает файл со ссылкой по уже существующему конфигу.
# Нужна тем, у кого клиенты созданы прежними версиями скрипта, и после правки конфига руками.
# Ключи и пир при этом не трогаются: ссылка — производная от конфига.
awg3_gen_link() {
    local names=()
    if [[ $# -gt 0 ]]; then
        names=("$@")
    else
        mapfile -t names < <(awg3_list_client_names)
        [[ "${#names[@]}" -gt 0 ]] || log_warn "клиентов нет"
    fi
    # Команду вызвали явно, значит ссылка нужна вопреки --no-qr-подобным умолчаниям.
    MAKE_LINK=1
    local name conf ok=0 failed=0
    for name in "${names[@]}"; do
        validate_client_name "$name"
        conf=$(client_conf_path "$name")
        if [[ ! -f "$conf" ]]; then
            log_error "'$name': конфиг не найден"
            failed=$((failed + 1))
            continue
        fi
        if awg3_generate_link "$name" "$conf"; then
            ok=$((ok + 1))
            # Одно имя — почти всегда «покажи мне ссылку»; списком же печатать ссылки бессмысленно, они по несколько килобайт.
            if [[ "${#names[@]}" -eq 1 ]]; then printf '%s\n' "$LINK_LAST"; fi
        else
            failed=$((failed + 1))
        fi
    done
    if [[ "${#names[@]}" -gt 1 ]]; then log "Готово: ссылок $ok, с ошибками $failed"; fi
    [[ "$failed" -eq 0 ]]
}

### Чтение клиентского конфига:
awg3_conf_value() {
    local file="$1" key="$2" section="${3:-any}"
    awk -v k="$key" -v want="$section" '
        /^[[:space:]]*\[Interface\]/ { sec = "interface"; next }
        /^[[:space:]]*\[Peer\]/      { sec = "peer"; next }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (index(line, "#") == 1) next
            if (want != "any" && sec != want) next
            split(line, kv, "=")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", kv[1])
            if (kv[1] == k) {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)
                print line
                exit
            }
        }
    ' "$file"
}

### Имена клиентов из обеих раскладок, без повторов и в алфавитном порядке:
awg3_list_client_names() {
    local d f base
    {
        for d in "${AWG3_CLIENTS_CONFIGS}"/*/; do
            [[ -d "$d" ]] || continue
            base=$(basename "$d")
            if [[ -f "${d}/${base}.conf" ]]; then printf '%s\n' "${base}"; fi
        done
        for f in ${AWG3_CLIENTS_CONFIGS}/*.conf; do
            [[ -f "$f" ]] || continue
            # Серверный конфиг, если он оказался в том же каталоге, клиентом не является: у него есть ListenPort, которого у клиента не бывает.
            if [[ "$f" -ef "$AWG3_SYSCONF" ]]; then continue; fi
            if grep -qE '^[[:space:]]*ListenPort[[:space:]]*=' "$f" 2>/dev/null; then continue; fi
            printf '%s\n' "$(basename "$f" .conf)"
        done
    } | sort -u
}

### Команда: awg3_list:
# Выравнивание ячейки по ШИРИНЕ В СИМВОЛАХ. printf считает байты, поэтому колонка с кириллицей съезжает ровно на число многобайтовых символов.
awg3_list() {
    awg3_load_server_params
    awg3_load_name_to_pk
    awg3_load_peer_dump
    printstr "$(_cols_pad "КЛИЕНТ" 20; _cols_pad "АДРЕС" 14; _cols_pad "ВЕРСИЯ" 8; _cols_pad "СВЯЗЬ" 14; _cols_pad "РАСКЛАДКА" 9; _cols_pad "СОВМЕСТИМ" 28;)"
    printstr "$(printf '%s\n' "$dashes")"
    local name conf addr hpk ver match c_s1 c_h1 layout
    while IFS= read -r name; do
        conf=$(client_conf_path "$name")
        if [[ "$conf" == "$AWG3_CLIENTS_CONFIGS/$name/$name.conf" ]]; then
            layout="папка"
        else
            layout="старая"
        fi
        addr=$(awg3_conf_value "$conf" Address interface)
        hpk=$(awg3_conf_value "$conf" HeaderProtectionKey interface)
        c_s1=$(awg3_conf_value "$conf" S1 interface)
        c_h1=$(awg3_conf_value "$conf" H1 interface)
        if [[ -n "$hpk" ]]; then ver="${AWG3_PROTOCOL}"; else ver="2.0"; fi
        if [[ "$c_s1" == "${S_S1}" && "$c_h1" == "${S_H1}" && "$hpk" == "${S_HPK}" ]]; then
            match="$(cecho sG "да")"
        else
            match="$(cecho sR "нет (клиент не подключится)")"
        fi
        local pk="${NAME_PK[$name]:-}" link
        if [[ -n "$pk" ]]; then link=$(awg3_peer_status "${PK_HS[$pk]:-0}"); else link="нет пира"; fi
        printstr "$(_cols_pad "${name}" 20; _cols_pad "${addr%%,*}" 14; _cols_pad "$ver" 8; _cols_pad "$link" 14; _cols_pad "$layout" 9; _cols_pad "$match" 28;)"
        printf '\n'
    done < <(awg3_list_client_names)
    printf '\n'
    if server_is_awg3; then
        printstr "$(printf 'Сервер: AWG %s (S1=%s H1=%s)\n' "${AWG3_PROTOCOL}" "$S_S1" "$S_H1")"
    else
        printstr "$(printf 'Сервер: AWG 2.0 — HeaderProtectionKey отсутствует\n')"
    fi
    printstr "$(printf '  порт: %s/udp, подсеть: %s, MTU: %s\n' "${S_PORT:-?}" "${S_ADDR:-?}" "${S_MTU:-?}")"
    printstr "$(printf '  изоляция клиентов: %s, IPv6: %s\n' "$(server_isolation_state)" "$(server_ipv6_state)")"
    local ep
    ep=$(awg3_server_endpoint_name)
    if [[ -n "$ep" ]]; then
        printstr "$(printf '  имя хоста для клиентов: %s\n' "$ep")"
    else
        printstr "$(printf '  имя хоста для клиентов: не задано (берётся внешний IP)\n')"
    fi
}

#### Команда: stats:
awg3_stats() {
    awg3_load_server_params
    awg3_load_name_to_pk
    awg3_load_peer_dump
    printstr "$(_cols_pad "КЛИЕНТ" 20; _cols_pad "ПРИНЯТО" 12; _cols_pad "ОТДАНО" 12; _cols_pad "СОСТОЯНИЕ" 16; _cols_pad "ОТКУДА" 10;)"
    printstr "$(printf '%s\n' "$dashes")"
    local name pk total_rx=0 total_tx=0 ep
    while IFS= read -r name; do
        pk="${NAME_PK[$name]:-}"
        if [[ -z "$pk" ]]; then
            printstr "$(_cols_pad "$name" 20; _cols_pad "нет пира в конфиге" 20;)"
            continue
        fi
        local rx="${PK_RX[$pk]:-0}" tx="${PK_TX[$pk]:-0}"
        [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
        [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
        total_rx=$((total_rx + rx)); total_tx=$((total_tx + tx))
        ep="${PK_EP[$pk]:-}"
        if [[ -z "$ep" || "$ep" == "(none)" ]]; then ep="-"; fi
        printstr "$(_cols_pad "$name" 20; _cols_pad "$(awg3_format_bytes "$rx")" 12; _cols_pad "$(awg3_format_bytes "$tx")" 12; _cols_pad "$(awg3_peer_status "${PK_HS[$pk]:-0}")" 16; _cols_pad "${ep}" 10;)"
    done < <(awg3_list_client_names)
    printf '\n'
    printstr "$(printf 'Всего: принято %s, отдано %s\n' "$(awg3_format_bytes "$total_rx")" "$(awg3_format_bytes "$total_tx")")"
}

### Команда: awg3_gen_add:
awg3_add_peer() {
    local name
    ask "Имя нового клиента" "" name
    validate_client_name "$name"
    awg3_load_server_params
    require_server_awg3
    local cdir conf
    cdir=$(client_dir "$name")
    conf="$cdir/${name}.conf"
    [[ ! -f "$conf" ]] || log_error "Клиент \"${name}\" уже существует: ${conf}!"
    [[ ! -f "$AWG3_CLIENTS_CONFIGS/${name}.conf" ]] || log_error "Клиент \"${name}\" уже существует в старой раскладке: ${AWG3_CLIENTS_CONFIGS}/${name}.conf!"
    if grep -qxF "#Name = ${name}" "$AWG3_SYSCONF" 2>/dev/null; then
        log_error "Пир \"${name}\" уже есть в ${AWG3_SYSCONF}."
        return 1
    fi
    local endpoint
    endpoint=$(awg3_resolve_endpoint)
    # Блокировка на время правки серверного конфига — тот же файл, что использует manage_amneziawg.sh, поэтому параллельный запуск безопасен.
    local lock_fd
    exec {lock_fd}>"$AWG3_LOCK_DIR/.awg_config.lock"
    flock -x -w 10 "$lock_fd" || log_error "Не получен config-lock!"
    local client_ip client_ip6 privkey psk pubkey address
    client_ip=$(awg3_get_next_client_ip)
    client_ip6=$(awg3_get_client_ipv6 "$client_ip")
    privkey=$(awg genkey)
    psk=$(awg genpsk)
    pubkey=$(printf '%s' "$privkey" | awg pubkey)
    if [[ -n "$client_ip6" ]]; then
        address="${client_ip}/32, ${client_ip6}/128"
    else
        address="${client_ip}/32"
        # У клиента нет IPv6-адреса, значит ::/0 в AllowedIPs — маршрут в никуда.
        # Хуже того, awg-quick на машине с отключённым IPv6 падает на нём с «IPv6 is disabled on nexthop device» и не поднимает туннель вообще.
        # Убираем, если пользователь не потребовал явно.
        if [[ "$AWG3_CLIENT_ALLOWED_IPS_EXPLICIT" -eq 0 ]]; then
            AWG3_CLIENT_ALLOWED_IPS=$(strip_ipv6_routes "$AWG3_CLIENT_ALLOWED_IPS")
        fi
    fi
    # Дальше идут изменения на диске: при сбое откатываем всё, что успели.
    # Ловушка висит на EXIT, а не только на ERR: die() выходит через exit, и на нём ERR не срабатывает.
    ROLLBACK_NAME="$name"
    ROLLBACK_SERVER_BAK=""
    ROLLBACK_ACTIVE=1
    trap '_rollback_add' EXIT
    mkdir -p "$cdir"; chmod 700 "$cdir"; _fix_owner "$cdir"
    printf '%s\n' "$privkey" > "$cdir/${name}.private"
    printf '%s\n' "$psk" > "$cdir/${name}.psk"
    printf '%s\n' "$pubkey"  > "$cdir/${name}.public"
    chmod 600 "$cdir/${name}.private" "$cdir/${name}.psk" "$cdir/${name}.public"
    _fix_owner "$cdir/${name}.private"; _fix_owner "$cdir/${name}.psk"; _fix_owner "$cdir/${name}.public"
    awg3_backup_file "$AWG3_SYSCONF"
    ROLLBACK_SERVER_BAK="$BACKUP_LAST"
    {
        printf '\n[Peer]\n'
        printf '#Name = %s\n' "$name"
        printf 'PublicKey = %s\n' "$pubkey"
        if [[ -n "$psk" ]]; then
            printf 'PresharedKey = %s\n' "$psk"
        fi
        if [[ -n "$client_ip6" ]]; then
            printf 'AllowedIPs = %s/32, %s/128\n' "$client_ip" "$client_ip6"
        else
            printf 'AllowedIPs = %s/32\n' "$client_ip"
        fi
    } >> "$AWG3_SYSCONF"
    chmod 600 "$AWG3_SYSCONF"
    awg3_gen_sender_params
    render_client_conf "$conf" "$privkey" "$address" "$(server_public_key)" "$endpoint" "$S_PORT" "$psk"
    ROLLBACK_ACTIVE=0
    trap - EXIT
    exec {lock_fd}>&-
    generate_qr "$name" "$conf"
    # Ссылка — приятное дополнение, а не условие успеха: клиент уже создан, применён и работоспособен с конфигом и QR даже без неё.
    awg3_generate_link "$name" "$conf" || true
    apply_peers || true
    success_box "Клиент \"${name}\" создан: ${client_ip}${client_ip6:+, $client_ip6}."
    log_ok "  Каталог: ${cdir}."
    log_ok "  Конфиг: ${conf}."
    if [[ -f "${conf%.conf}.vpnuri" ]]; then log_ok "  Ссылка: [${conf%.conf}.vpnuri]."; fi
    log_ok "  Профиль обфускации: AWG ${AWG3_PROTOCOL} / ${AWG3_PROFILE} / ${AWG3_INTENSITY}."
}

_rollback_add() {
    local rc=$?
    if [[ "${ROLLBACK_ACTIVE:-0}" -ne 1 ]]; then return 0; fi
    ROLLBACK_ACTIVE=0
    log_error "Сбой при создании клиента — откатываю изменения!"
    # Каталог создаётся этим же вызовом, поэтому удаляется целиком; чужого в нём быть не может — существование клиента проверено до начала работы.
    rm -rf "${AWG3_CLIENTS_CONFIGS:?}/${ROLLBACK_NAME:?}" 2>/dev/null || true
    if [[ -n "${ROLLBACK_SERVER_BAK:-}" && -f "$ROLLBACK_SERVER_BAK" ]]; then
        if cp -p "$ROLLBACK_SERVER_BAK" "$AWG3_SYSCONF"; then
            log_ok "Серверный конфиг восстановлен."
        fi
    fi
    if [[ "$rc" -eq 0 ]]; then rc=1; fi
    exit "$rc"
}

### Команда: migrate:
#####################
# Переносит клиентов из плоской раскладки в /etc/VPN/configs/awg3/ИМЯ/. 
# Файлы перемещаются, а не копируются: две копии приватного ключа на диске никому не нужны.
# Повторный запуск безопасен — уже перенесённые пропускаются.
awg3_migrate_one() {
    local name="$1" cdir moved=0
    cdir=$(client_dir "$name")
    if [[ -f "$cdir/${name}.conf" ]]; then
        log "\"${name}\": уже в своём каталоге, пропускаю."
        return 0
    fi
    [[ -f "$AWG3_CLIENTS_CONFIGS/${name}.conf" ]] || { log_error "\"${name}\": конфиг не найден!"; return 1; }
    mkdir -p "$cdir" || { log_error "\"${name}\": не создан каталог $cdir"; return 1; }
    chmod 700 "$cdir"; _fix_owner "$cdir"
    local src dst
    for src in "$AWG3_CLIENTS_CONFIGS/${name}.conf" "$AWG3_CLIENTS_CONFIGS/${name}.png" \
               "$AWG3_CLIENTS_CONFIGS/${name}.vpnuri" "$AWG3_CLIENTS_CONFIGS/${name}.vpnuri.png" \
               "$AWG3_LEGACY_KEYS/${name}.private" "$AWG3_LEGACY_KEYS/${name}.psk" "$AWG3_LEGACY_KEYS/${name}.public"; do
        [[ -f "$src" ]] || continue
        dst="$cdir/$(basename "$src")"
        if mv -f "$src" "$dst"; then
            _fix_owner "$dst"
            moved=$((moved + 1))
        else
            log_error "\"${name}\": не перенесён ${src}!"
            return 1
        fi
    done
    # Бэкапы конфигов, накопленные прежними запусками, едут следом: иначе они осиротеют в корне каталога.
    local bak
    for bak in "${AWG3_CLIENTS_CONFIGS}/${name}.conf".bak-*; do
        [[ -f "$bak" ]] || continue
        if mv -f "$bak" "$cdir/"; then moved=$((moved + 1)); fi
    done
    log_ok "\"${name}\": перенесено файлов — $moved → $cdir"
    return 0
}

awg3_migrate() {
    local names_list=() names=() name flat=()
#    mapfile -t names < <(awg3_list_client_names)
    mapfile -t names_list < <(awg3_list_client_names)
    [[ "${#names_list[@]}" -gt 0 ]] || { log_warn "Клиентов не найдено."; return 1; }
    med_multiselect "true" result names_list false "Выберите клиентов для переноса" || return 1
    idx=0
    for option in "${names_list[@]}"; do
        [ "${result[idx]}" = true ] && names+=("${option}")
        ((idx++))
    done

#    [[ "${#names[@]}" -gt 0 ]] || log_warn "Клиентов не найдено."
    for name in "${names[@]}"; do
        if [[ ! -f "$AWG3_CLIENTS_CONFIGS/$name/$name.conf" && -f "$AWG3_CLIENTS_CONFIGS/${name}.conf" ]]; then
            flat+=("$name")
        fi
    done
    if [[ "${#flat[@]}" -eq 0 ]]; then
        log_ok "Переносить нечего: все клиенты уже разложены по каталогам."
        return 0
    fi
    log "Будут перенесены в собственные каталоги: ${flat[*]}."
    log "Файлы перемещаются (conf, png, ключи, бэкапы), сервер не затрагивается."
    ask_confirm "Продолжить?" "n" || return 1
    local ok=0 fail=0
    for name in "${flat[@]}"; do
        if awg3_migrate_one "$name"; then ok=$((ok + 1)); else fail=$((fail + 1)); fi
    done
    # Каталог keys/ остаётся на месте, даже если опустел: удаление файлов — отдельное решение, скрипт его за пользователя не принимает.
    if [[ -d "$AWG3_LEGACY_KEYS" ]]; then
        local left
        left=$(find "$AWG3_LEGACY_KEYS" -type f 2>/dev/null | wc -l)
        if [[ "$left" -eq 0 ]]; then
            log "Каталог $AWG3_LEGACY_KEYS опустел — можно удалить вручную."
        else
            log_warn "В $AWG3_LEGACY_KEYS осталось файлов: $left (ключи без клиента?)."
        fi
    fi
    success_box "Готово: перенесено ${ok}, с ошибками ${fail}."
    [[ "$fail" -eq 0 ]]
}

### Отображение клиентских конфигов:
####################################
#-> показывает QR в терминале.
awg3_show_qr() {
    local conf_file="$1" conf_size
    conf_size=$(wc -c < "$conf_file")
    [[ ! -f "$conf_file" ]] && return 1
    if ! command -v qrencode &>/dev/null; then
        local do_install=""
        ask_yn "Установить qrencode для QR-кодов?" "y" do_install
        if [[ "$do_install" == "yes" ]]; then
            [[ "$os_type" = "deb" ]] && apt-get install -y -qq qrencode 2>/dev/null || { print_warn "Не удалось установить qrencode"; return 1; }
            [[ "$os_type" = "rhel" ]] && dnf install -y qrencode 2>/dev/null || { print_warn "Не удалось установить qrencode"; return 1; }
        else
            return 1
        fi
    fi
    if [[ "$conf_size" -le 2800 ]] && command -v qrencode &>/dev/null; then
#        printf '\n%s\n' "$(qrencode -t ansiutf8 -s 1 -m 1 < "$conf_file" | sed 's/^/  /')"
        printf '\n%s\n' "$(qrencode -t utf8i -m 1 -l L -s 1 < "$conf_file" | sed 's/^/  /')"
        printstr "QR-код конфига %s" "([${conf_size}] байт)" "$arr_up"
      return 0
    fi
}

awg3_show_client() {
    local names_list=()
    mapfile -t names_list < <(awg3_list_client_names)
    [[ "${#names_list[@]}" -gt 0 ]] || { log_warn "Клиентов не найдено."; return 1; }
    single_select "true" result names_list 0 "Выберите клиента" || return 1
    local name="$result"
    local cfg="$AWG3_CLIENTS_CONFIGS/${name}/${name}.conf"
    [[ ! -f "$cfg" ]] && { log_error "Конфиг не найден: ${cfg}!"; return 1; }
    success_box "$cfg"
    printf '\n%s\n' "$(cat "$cfg")"
    #-> QR-код
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && awg3_show_qr "$cfg"
    return 0
}

### Команда: awg3_remove_peer:
##############################
#-> Вырезает из серверного конфига секцию [Peer] с указанным #Name.
awg3_drop_peer_section() {
    local name="$1" tmp
    tmp=$(mktemp "${AWG3_SYSCONF}.tmp.XXXXXX") || return 0
    chmod 600 "$tmp"
    # Секция копится в буфере до её конца, и только тогда решается судьба: печатать или выбросить. Маркер #Name стоит внутри секции, а не перед ней.
    awk -v target="$name" '
        function flush_buf() {
            if (nbuf > 0 && !drop) { for (i = 1; i <= nbuf; i++) print buf[i] }
            nbuf = 0; drop = 0
        }
        /^[[:space:]]*\[Peer\]/ { flush_buf(); in_peer = 1; buf[++nbuf] = $0; next }
        /^[[:space:]]*\[Interface\]/ { flush_buf(); in_peer = 0; print; next }
        {
            if (in_peer) {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                if (line == "#Name = " target) drop = 1
                buf[++nbuf] = $0
            } else print
        }
        END { flush_buf() }
    ' "$AWG3_SYSCONF" | sed '/^$/d' > "$tmp" || { rm -f "$tmp"; return 0; }
    if ! grep -qxF "#Name = ${name}" "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$AWG3_SYSCONF" || { rm -f "$tmp"; return 0; }
        chmod 600 "$AWG3_SYSCONF"
        return 0
    fi
    rm -f "$tmp"
    return 0
}

awg3_remove_peer() {
    awg3_load_server_params
    local names_list=() valid=() names=()
    mapfile -t names_list < <(awg3_list_client_names)
    [[ "${#names_list[@]}" -gt 0 ]] || { log_warn "Клиентов не найдено."; return 1; }
    med_multiselect "true" result names_list false "Выберите клиентов для удаления" || return 1
    idx=0
    for option in "${names_list[@]}"; do
        [ "${result[idx]}" = true ] && names+=("${option}")
        ((idx++))
    done

    for name in "${names[@]}"; do
        validate_client_name "$name"
        if grep -qxF "#Name = ${name}" "$AWG3_SYSCONF" 2>/dev/null; then
            valid+=("$name")
        else
            log_warn "'$name': пира нет в $AWG3_SYSCONF"
            # Файлы могли остаться от прошлой неудачной попытки — заберём и их.
            if [[ -d "$(client_dir "$name")" || -f "$AWG3_CLIENTS_CONFIGS/${name}/${name}.conf" ]]; then
                valid+=("$name")
            fi
        fi
    done
    [[ "${#valid[@]}" -gt 0 ]] > /dev/null 2>&1 || { log_warn "Нечего удалять."; return 1; }
    log_warn "Будет удалено безвозвратно:"
    for name in "${valid[@]}"; do
        local cdir=$(client_dir "$name")
        printstr "[Peer]: ${name}"
        if [[ -d "$cdir" ]]; then
            find "$cdir" -type f -printf "$(printstr %p)\n" 2>/dev/null || true;
        fi
        [[ -f "$AWG3_CLIENTS_CONFIGS/${name}.conf" ]] && printstr "$AWG3_CLIENTS_CONFIGS/${name}.conf"
        if grep -qxF "#Name = ${name}" "$AWG3_SYSCONF" 2>/dev/null; then
            printstr "[Peer] в $AWG3_SYSCONF"
        fi
    done
    ask_confirm "Точно удалить?" "n" || return 1
    local lock_fd
    exec {lock_fd}>"$AWG3_LOCK_DIR/.awg_config.lock"
    flock -x -w 10 "$lock_fd" || print_warn "Не получен config-lock."
    awg3_backup_file "$AWG3_SYSCONF"
    local removed=0 failed=0
    for name in "${valid[@]}"; do
        if grep -qxF "#Name = ${name}" "$AWG3_SYSCONF" 2>/dev/null; then
            if ! awg3_drop_peer_section "$name"; then
                log_error "'$name': не удалён из серверного конфига!"
                failed=$((failed + 1))
                continue
            fi
        fi
        # Приватный ключ затирается, а не просто отвязывается от имени файла.
        local cdir; cdir=$(client_dir "$name")
        if [[ -d "$cdir" ]]; then
            find "$cdir" -type f -name '*.private' -exec shred -u {} \; 2>/dev/null || return 0
            rm -rf "${AWG3_CLIENTS_CONFIGS:?}/${name:?}"
        fi
        rm -f "$AWG3_CLIENTS_CONFIGS/${name}.conf" "$AWG3_CLIENTS_CONFIGS/${name}.png" \
              "$AWG3_CLIENTS_CONFIGS/${name}.vpnuri" "$AWG3_CLIENTS_CONFIGS/${name}.vpnuri.png" \
              "$AWG3_CLIENTS_CONFIGS/${name}.conf".bak-* 2>/dev/null || true
        if [[ -f "$AWG3_LEGACY_KEYS/${name}.private" ]]; then
            shred -u "$AWG3_LEGACY_KEYS/${name}.private" 2>/dev/null || true
        fi
        rm -f "$AWG3_LEGACY_KEYS/${name}.psk" 2>/dev/null || true
        rm -f "$AWG3_LEGACY_KEYS/${name}.public" 2>/dev/null || true
        log_ok "\"${name}\" удалён"
        removed=$((removed + 1))
    done
    exec {lock_fd}>&-
    if [[ "$removed" -gt 0 ]]; then apply_peers || true; fi
    success_box "Готово: удалено $removed, с ошибками ${failed}."
    [[ "$failed" -eq 0 ]]
}
