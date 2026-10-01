
configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 из CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 отключен (--yes, по умолчанию)."
    else
        read -rp "Отключить IPv6 (рекомендуется)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"
}

configure_ipv6_tunnel() {
    if [[ "$CLI_ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        ALLOW_IPV6_TUNNEL=1
    elif [[ -z "${ALLOW_IPV6_TUNNEL:-}" ]]; then
        ALLOW_IPV6_TUNNEL=0
    fi
    : "${IPV6_SUBNET:=fddd:2c4:2c4:2c4::/64}"
    # Префикс стока IPv6 режима 2 (AWG_V6_SINK_PREFIX в awg_common.sh; библиотеки
    # на шаге 0 ещё нет, совпадение копий сверяет тест). Подсеть туннеля внутри него
    # сделала бы настоящие адреса клиентов неотличимыми от стока.
    local sink_prefix="fddd:2c4:2c4:ffff"
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        local _v6p="${IPV6_SUBNET%%::*}"
        _v6p="${_v6p,,}"
        if [[ "$_v6p" == "$sink_prefix" || "$_v6p" == "${sink_prefix}:"* ]]; then
            # Сервер, который УЖЕ стоит в этом префиксе и раздал клиентов, не
            # останавливаем: сменить подсеть при живых пирах нельзя (их IPv6
            # остались бы в старой), а проверки смены IPv6-подсети, как у IPv4,
            # нет. Повторный запуск тут ничего не ухудшит, поэтому предупреждение.
            # «Уже стоит» значит ровно тот же адрес сервера (префикс и длина), что
            # дала бы эта подсеть: любая другая подсеть, даже внутри стока, - это
            # новая смена, и её останавливаем, как на чистом сервере.
            # Address разбирается без конвейера: grep -m1 под pipefail мог бы
            # оборвать писателя и потерять найденный адрес.
            local _cur_v6="" _want_v6 _addr_line _el
            local -a _addr_els=()
            if [[ -f "$SERVER_CONF_FILE" ]] && grep -q '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null; then
                _addr_line=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" 2>/dev/null) || _addr_line=""
                IFS=',' read -ra _addr_els <<< "${_addr_line//$'\n'/,}"
                for _el in "${_addr_els[@]}"; do
                    _el="${_el//[[:space:]]/}"
                    if [[ "$_el" == *:* ]]; then _cur_v6="${_el,,}"; break; fi
                done
            fi
            _want_v6="${IPV6_SUBNET/::\//::1\/}"
            _want_v6="${_want_v6,,}"
            if [[ -n "$_cur_v6" && "$_cur_v6" == "$_want_v6" ]]; then
                log_warn "IPV6_SUBNET ($IPV6_SUBNET) пересекается с префиксом ${sink_prefix}::/64 режима маршрутизации 2: настоящие IPv6 клиентов похожи на сток, regen и modify могут их убрать, новые клиенты с IPv6 не создадутся. Менять подсеть при выданных клиентах нельзя; чистый путь - --uninstall и установка с другой ULA-подсетью."
            else
                die "IPV6_SUBNET ($IPV6_SUBNET) пересекается с префиксом ${sink_prefix}::/64, который установщик держит для режима маршрутизации 2. Задайте другую ULA-подсеть в $CONFIG_FILE."
            fi
        fi
    fi
    # IPv6-туннель требует включённого IPv6 на хосте. Снимаю --disallow-ipv6 И
    # активно включаю IPv6 в рантайме ДО detection/render: при upgrade с дефолтной
    # прошлой установки (IPv6 был выключен в рантайме) ядро скрывает все IPv6-адреса,
    # поэтому detect_native_ipv6 дал бы false-negative, а клиент отрендерился бы с
    # IPv6 Address при выключенном в ядре IPv6 (awg-quick restart может упасть).
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Native IPv6 определяю ПОСЛЕ runtime-включения (кэширую в init для client render Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 не обнаружен на VPS - туннель IPv6 будет работать peer-to-peer без выхода в IPv6-интернет."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
}

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
safe_load_config() {
    local config_file="${1:-$AWG3_SYSCONF}"
    if [[ ! -f "$config_file" ]]; then return 1; fi
    local line key value first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                OS_ID|OS_VERSION|OS_CODENAME|AWG_PORT|AWG_TUNNEL_SUBNET|\
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|AWG_MTU|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|NO_CPS|NO_PREBUILT|KEEP_PACKAGES|\
                AWG_APPLY_MODE|ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET|AWG_PROTOCOL|AWG_CPA|AWG_SERVER_NAME|CLIENT_DNS|CLIENT_IPV6_DIRECT)
                    export "$key=$value"
                    ;;
                *)
                    # Строка CLIENT_DNS, которую разбор не узнал, называется: иначе новые клиенты молча получали бы DNS по умолчанию.
                    if [[ "${key^^}" == CLIENT_DNS ]]; then log_warn "Строка CLIENT_DNS в $config_file не разобрана: '$line'. Нужен вид export CLIENT_DNS='10.9.9.1' без отступа и без пробелов вокруг =. Новые клиенты получат DNS по умолчанию."; fi
                    # То же для CLIENT_IPV6_DIRECT: иначе строка, которой ключ выключают, молча не читалась бы, и IPv6 клиентов шёл бы мимо туннеля дальше.
                    if [[ "${key^^}" == CLIENT_IPV6_DIRECT ]]; then log_warn "Строка CLIENT_IPV6_DIRECT в $config_file не разобрана: '$line'. Нужен вид export CLIENT_IPV6_DIRECT=1 (или =0) без отступа и без пробелов вокруг =."; fi
                    ;;
            esac
        elif [[ "${line^^}" == *CLIENT_DNS* ]]; then
            log_warn "Строка CLIENT_DNS в $config_file не разобрана: '$line'. Нужен вид export CLIENT_DNS='10.9.9.1' без отступа и без пробелов вокруг =. Новые клиенты получат DNS по умолчанию."
        elif [[ "${line^^}" == *CLIENT_IPV6_DIRECT* ]]; then
            log_warn "Строка CLIENT_IPV6_DIRECT в $config_file не разобрана: '$line'. Нужен вид export CLIENT_IPV6_DIRECT=1 (или =0) без отступа и без пробелов вокруг =."
        fi
    done < "$config_file"
}

# Чтение одного ключа из конфига (для точечных запросов)
safe_read_config_key() {
    local key="$1" config_file="${2:-$CONFIG_FILE}"
    local line first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        line="${line#export }"
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            echo "$value"
            return 0
        fi
    done < "$config_file"
    return 1
}
