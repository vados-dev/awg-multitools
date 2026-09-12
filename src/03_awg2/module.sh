######################
### Модуль: AmneziaWG2
#-> установка: анализ системы + DKMS + первый интерфейс + первый клиент
#-> управление: мультиинтерфейс, клиенты, DNS, перезапуск
#######################################################################

awg2env_inc="${INCLUDE_DIR}/.awg2-env"
source $awg2env_inc

#-> AWG: Выбор версии протокола:
# - AWG 1.0 (H+S1/S2) vs AWG 1.5 (+ I1-I5) vs AWG 2.0 (+ ranged H, S3/S4, I1-I5) vs WG
# - Keenetic: 1.0 работает на KeeneticOS 4.2+, 1.5/2.0 требуют 5.1+ dev-канал

_awg2_ask_version() {
    set_awg2_ver10() { printf -v AWG2_VER "%s" "1.0"; }
    set_awg2_ver15() { printf -v AWG2_VER "%s" "1.5"; }
    set_awg2_ver20() { printf -v AWG2_VER "%s" "2.0"; }
    declare mItems=("AWG 1.0 classic - H1-H4 + S1/S2 + Jc/Jmin/Jmax" "AWG 1.5 - + I1-I5 signature chain/CPS" "AWG 2.0 - 1.5 + ranged H + S3/S4")
    declare mActions=("set_awg2_ver10" "set_awg2_ver15" "set_awg2_ver20")
    declare mTitle="Версия протокола"
    declare mDescr="1.0 - (стабильная), OpenWrt, все старые клиенты. 1.5 - dev-канал. Маскировка под DNS/STUN/SIP. 2.0 - dev-канал, Amnezia 4.8.12.9+. Максимальная обфускация."
    declare mType="select"
    show_menu
}

#-> AWG: Генерация офускации
# - общие параметры Jc/Jmin/Jmax/S1/S2 с учётом MTU
# - arg1: auto (yes/no), arg2: MTU (по умолчанию 1320)
# - AWG handshake overhead: init=148 байт, response=92 байт, IP+UDP headers=28 байт
# - Jmax <= MTU - 176 (148 + 28), S1 <= MTU - 148, S2 <= MTU - 92
# - S1 != S2, S1 + 56 != S2, S2 + 56 != S1 (симметричное правило из kernel README)
_awg2_gen_obf_common() {
    local auto="$1"
    local mtu="${2:-1320}"
    # - лимиты по MTU -
    local jmax_limit=$(( mtu - 176 ))
    local s1_limit=$(( mtu - 148 ))
    local s2_limit=$(( mtu - 92 ))
    # - верхние границы для auto 15..150, но не больше *_limit если MTU мизерный -
    local s_hi=150
    [[ "$s1_limit" -lt "$s_hi" ]] && s_hi="$s1_limit"
    [[ "$s2_limit" -lt "$s_hi" ]] && s_hi="$s2_limit"

    if [[ "$auto" == "yes" ]]; then
        OBF_JC=$(rand_range 4 12)
        OBF_JMIN=$(rand_range 8 200)
        OBF_JMAX=$(rand_range 200 "$jmax_limit")
        # - Jmin должен быть строго меньше Jmax, сдвигаем если Jmin слишком близко -
        [[ "$OBF_JMIN" -ge "$OBF_JMAX" ]] && OBF_JMIN=$(( OBF_JMAX / 2 ))

        OBF_S1=$(rand_range 15 "$s_hi")
        # - детерминированный выбор S2: строим список "свободных" значений из [15, s_hi] -
        # - исключаем S1, S1+56, S1-56 (симметричная проверка из kernel README) -
        local s1_plus=$(( OBF_S1 + 56 ))
        local s1_minus=$(( OBF_S1 - 56 ))
        local -a s2_valid=()
        local v
        for (( v=15; v<=s_hi; v++ )); do
            [[ "$v" -eq "$OBF_S1" ]] && continue
            [[ "$v" -eq "$s1_plus" ]] && continue
            [[ "$v" -eq "$s1_minus" ]] && continue
            s2_valid+=("$v")
        done
        # - список не может быть пустым: размер [15..s_hi] минимум 3 значения при MTU >= 1280 -
        OBF_S2="${s2_valid[$(( RANDOM % ${#s2_valid[@]} ))]}"
    else
        print_info "Правила: Jmin < Jmax, S1 != S2, S1+56 != S2, S2+56 != S1"
        echo -e "  ${bcy}Jc - кол-во мусорных пакетов (рекомендуется 4-12, диапазон 1-128).${nc}"
        echo -e "  ${bcy}Jmin/Jmax - размер мусорных пакетов, Jmax <= ${jmax_limit} (MTU ${mtu} - 176).${nc}"
        echo -e "  ${bcy}S1 - padding init-пакета <= ${s1_limit}. S2 - padding response <= ${s2_limit}.${nc}"
        # - Jc: 1-128 -
        while true; do
            ask "Jc (1-128)" "8" OBF_JC
            [[ "$OBF_JC" =~ ^[0-9]+$ ]] && (( OBF_JC >= 1 && OBF_JC <= 128 )) && break
            print_err "Jc должен быть целым от 1 до 128"
        done
        # - Jmin < Jmax, Jmin >= 8, Jmax <= jmax_limit -
        while true; do
            ask "Jmin (8-${jmax_limit})" "64" OBF_JMIN
            ask "Jmax (>Jmin, <=${jmax_limit})" "$(( jmax_limit > 1000 ? 1000 : jmax_limit ))" OBF_JMAX
            if [[ "$OBF_JMIN" =~ ^[0-9]+$ && "$OBF_JMAX" =~ ^[0-9]+$ ]] \
               && (( OBF_JMIN >= 8 && OBF_JMIN < OBF_JMAX && OBF_JMAX <= jmax_limit )); then
                break
            fi
            print_err "Нужно 8 <= Jmin < Jmax <= ${jmax_limit}. Повторите ввод"
        done
        # - S1 в диапазоне 0..s1_limit, рекомендуется 15-150 -
        while true; do
            ask "S1 (0-${s1_limit}, рекомендуется 15-150)" "20" OBF_S1
            [[ "$OBF_S1" =~ ^[0-9]+$ ]] && (( OBF_S1 >= 0 && OBF_S1 <= s1_limit )) && break
            print_err "S1 должно быть целым от 0 до ${s1_limit}"
        done
        # - S2 с симметричной проверкой -
        while true; do
            ask "S2 (0-${s2_limit}, S1±56 != S2)" "35" OBF_S2
            if ! [[ "$OBF_S2" =~ ^[0-9]+$ ]] || (( OBF_S2 < 0 || OBF_S2 > s2_limit )); then
                print_err "S2 должно быть целым от 0 до ${s2_limit}"
                continue
            fi
            if (( OBF_S2 == OBF_S1 )); then
                print_err "S2 не должно равняться S1 (${OBF_S1})"
                continue
            fi
            if (( OBF_S2 == OBF_S1 + 56 )); then
                print_err "S2 не должно равняться S1+56 (${OBF_S1}+56=$(( OBF_S1 + 56 )))"
                continue
            fi
            if (( OBF_S2 + 56 == OBF_S1 )); then
                print_err "S2+56 не должно равняться S1 (текущее S2+56=$(( OBF_S2 + 56 )), S1=${OBF_S1})"
                continue
            fi
            break
        done
    fi
    return 0
}

# --> AWG: ПРЕСЕТЫ CPS ДЛЯ I1 (реальные hex snapshots) <--
# - I1 должен выглядеть как начало реального UDP-протокола для DPI-маскировки -
# - QUIC preset удалён: структурно некорректен (RFC 9000 требует DCID/SCID/token_length как VarInt) -
# - TLS ClientHello не делаем: TLS на UDP-порту аномален, хуже чем ничего -

# - генератор hex DNS-запроса типа A для произвольного FQDN -
# - формат: flags(0100) qd(0001) an(0000) ns(0000) ar(0000) QNAME qtype(0001) qclass(0001) -
_awg2_dns_query_hex() {
    local domain="$1"
    local hex="01000001000000000000"
    local IFS='.'
    local -a labels=($domain)
    local label len i ch
    for label in "${labels[@]}"; do
        len="${#label}"
        hex+=$(printf "%02x" "$len")
        for (( i=0; i<${#label}; i++ )); do
            ch="${label:$i:1}"
            hex+=$(printf "%02x" "'$ch")
        done
    done
    hex+="00"       # - терминатор QNAME -
    hex+="00010001" # - QTYPE=A, QCLASS=IN -
    echo "$hex"
}

# - пул популярных DNS-доменов по регионам -
# - формат: "домен|описание" либо "###Заголовок" как маркер группы -
# - маркеры не получают номера в меню, только визуальные разделители -
AWG_DNS_DOMAINS=(
    "###Глобальные"
    "www.cloudflare.com|Global CDN, правдоподобен в любой стране"
    "www.google.com|Global поиск/Gmail, самый распространённый запрос"
    "www.google-analytics.com|Global Google Analytics, на половине сайтов"
    "ssl.google-analytics.com|Global GA SSL endpoint"
    "www.googletagmanager.com|Global Google Tag Manager"
    "fonts.googleapis.com|Global Google Fonts API"
    "fonts.gstatic.com|Global Google Fonts static"
    "ajax.googleapis.com|Global Google Hosted Libraries"
    "cdnjs.cloudflare.com|Global CDN JS библиотек"
    "cdn.jsdelivr.net|Global jsDelivr CDN"
    "unpkg.com|Global npm CDN"
    "static.cloudflareinsights.com|Global Cloudflare аналитика"
    "connect.facebook.net|Global Facebook SDK/пиксель"
    "www.apple.com|Global Apple"
    "configuration.apple.com|Global Apple config"
    "gsp-ssl.ls.apple.com|Global Apple location"
    "www.microsoft.com|Global Microsoft"
    "ctldl.windowsupdate.com|Global Windows Update"
    "v10.events.data.microsoft.com|Global Windows телеметрия"
    "time.windows.com|Global Windows NTP"
    "time.apple.com|Global Apple NTP"
    "pool.ntp.org|Global NTP pool"
    "www.amazon.com|Global Amazon"
    "www.github.com|Global GitHub"
    "###Россия"
    "www.yandex.ru|Россия Яндекс"
    "mc.yandex.ru|Россия Яндекс.Метрика (на куче сайтов)"
    "www.vk.com|Россия VK"
    "www.mail.ru|Россия Mail.ru"
    "www.tinkoff.ru|Россия T-Банк"
    "www.ozon.ru|Россия Ozon"
    "www.wildberries.ru|Россия Wildberries"
    "www.avito.ru|Россия Avito"
    "###СНГ / Средняя Азия"
    "www.kaspi.kz|Казахстан Kaspi банк"
    "www.beeline.uz|Узбекистан Beeline"
    "www.onliner.by|Беларусь Onliner"
    "list.am|Армения List.am"
    "###Турция"
    "www.trt.net.tr|Турция гос. медиа"
    "www.hurriyet.com.tr|Турция Hurriyet"
    "www.trendyol.com|Турция Trendyol marketplace"
    "www.sahibinden.com|Турция Sahibinden объявления"
    "###Иран"
    "www.digikala.com|Иран Digikala marketplace"
    "www.divar.ir|Иран Divar объявления"
    "www.aparat.com|Иран Aparat видеохостинг"
    "www.snapp.ir|Иран Snapp такси"
    "###Европа"
    "www.bbc.co.uk|UK BBC"
    "www.spiegel.de|DE Spiegel"
    "www.lemonde.fr|FR Le Monde"
    "www.elpais.com|ES El Pais"
    "###США"
    "www.netflix.com|США Netflix"
    "www.nytimes.com|США NY Times"
    "www.cnn.com|США CNN"
)

# --> AWG: RAND_PORT ДЛЯ AWG-ИНТЕРФЕЙСА <--
# - диапазон 1024-9999 (рекомендация Amnezia, провайдеры режут UDP на high-ports) -
# - исключаем зарезервированные порты -
_awg2_port_blacklist() {
    local p="$1"
    case "$p" in
        20|21|22|23|25|53|67|68|69|80|88|110|111|123|135|137|138|139|143|161|162|389|443|445|465|500|514|520|546|547|554|587|631|636|853|873|989|990|993|995|1080|1194|1433|1434|1521|1701|1723|1812|1813|1900|2049|2375|2376|3128|3306|3389|3478|3479|4500|5000|5001|5060|5061|51820|5353|5355|5432|5900|5901|6379|6881|6882|6883|6884|6885|6886|6887|6888|6889|8080|8081|8443|8888|9200|9300|10000|11211|27017|27018|27019)
            return 0 ;;
    esac
    return 1
}

rand_port_awg() {
    local low=1024 high=9999 port
    local attempts=0 max_attempts=100
    local span=$(( high - low + 1 ))
    while (( attempts < max_attempts )); do
        # - _rand_bits30 на /dev/urandom, корректно работает при span > 32767 -
        port=$(( low + $(_rand_bits30 "$span") ))
        if _awg2_port_blacklist "$port"; then (( attempts++ )); continue; fi
        # - ss без -p: процесс не нужен, -p может требовать прав в некоторых окружениях -
        # - regex [:.] покрывает IPv4 (:port) и IPv6-в-mapped нотацию (.port) -
        if ! ss -H -uln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]" && \
           ! ss -H -tln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
            echo "$port"; return 0
        fi
        (( attempts++ ))
    done
    return 1
}

_awg2_cps_preset_dns() {
    # - DNS query типа A, маскирует под обычный DNS резолвинг -
    # - аргумент: FQDN. Если пустой - случайный из AWG_DNS_DOMAINS (маркеры пропускаются) -
    local domain="$1"
    if [[ -z "$domain" ]]; then
        local pool=() entry
        for entry in "${AWG_DNS_DOMAINS[@]}"; do
            [[ "$entry" == "###"* ]] && continue
            pool+=("${entry%%|*}")
        done
        domain="${pool[$(( RANDOM % ${#pool[@]} ))]}"
    fi
    local hex
    hex=$(_awg2_dns_query_hex "$domain")
    echo "<r 2><b 0x${hex}>"
}

# --> AWG: ПУЛ ШАБЛОНОВ STUN <--
# - STUN Binding Request (RFC 5389) с SOFTWARE attribute, имитирует реальные клиенты -
# - NOFP: 32 байта, без FINGERPRINT. FP: 40 байт, с рандомным FINGERPRINT -
# - FINGERPRINT в STUN это CRC32, AWG не умеет считать CRC на лету поэтому рандомный -
# - глубокий DPI с проверкой CRC отбракует, статистический DPI пропустит -
AWG_CPS_STUN_POOL_NOFP=(
    "<b 0x0001000c2112a442><r 12><b 0x802200086c69626a696e676c>"
    "<b 0x0001000c2112a442><r 12><b 0x802200086963652d6c697465>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084368726f6d69756d>"
    "<b 0x0001000c2112a442><r 12><b 0x80220008636f7475726e2d34>"
    "<b 0x0001000c2112a442><r 12><b 0x802200085374756e53657276>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084c6976654b697453>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084a616e7573534655>"
    "<b 0x0001000c2112a442><r 12><b 0x80220008417374657269736b>"
    "<b 0x000100102112a442><r 12><b 0x80220009706a70726f6a656374000000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200074a697473692d5800>"
    "<b 0x000100102112a442><r 12><b 0x802200096d65646961736f7570000000>"
    "<b 0x000100082112a442><r 12><b 0x8022000470696f6e>"
    "<b 0x0001000c2112a442><r 12><b 0x8022000661696f7274630000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200076261726573697000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200086c696e70686f6e65>"
    "<b 0x0001000c2112a442><r 12><b 0x8022000772657374756e6400>"
    "<b 0x0001000c2112a442><r 12><b 0x802200067765627274630000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200074b7572656e746f00>"
    "<b 0x0001000c2112a442><r 12><b 0x80220007696f6e2d73667500>"
    "<b 0x0001000c2112a442><r 12><b 0x802200065477696c696f0000>"
    "<b 0x0001000c2112a442><r 12><b 0x80220006566f6e6167650000>"
    "<b 0x000100102112a442><r 12><b 0x8022000a467265655357495443480000>"
    "<b 0x0001000c2112a442><r 12><b 0x802200075369707769736500>"
    "<b 0x000100102112a442><r 12><b 0x802200094753747265616d6572000000>"
    "<b 0x0001000c2112a442><r 12><b 0x80220007657475726e616c00>"
    "<b 0x0001000c2112a442><r 12><b 0x802200087374756e73657276>"
    "<b 0x0001000c2112a442><r 12><b 0x802200084d65746173776974>"
    "<b 0x0001000c2112a442><r 12><b 0x802200076564756d65657400>"
)

AWG_CPS_STUN_POOL_FP=(
    "<b 0x000100142112a442><r 12><b 0x802200086c69626a696e676c80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200086963652d6c69746580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084368726f6d69756d80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220008636f7475726e2d3480280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200085374756e5365727680280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084c6976654b69745380280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084a616e757353465580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220008417374657269736b80280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x80220009706a70726f6a65637400000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200074a697473692d580080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x802200096d65646961736f757000000080280004><r 4>"
    "<b 0x000100102112a442><r 12><b 0x8022000470696f6e80280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x8022000661696f727463000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007626172657369700080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200086c696e70686f6e6580280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x8022000772657374756e640080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220006776562727463000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200074b7572656e746f0080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007696f6e2d7366750080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200065477696c696f000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220006566f6e616765000080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x8022000a46726565535749544348000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007536970776973650080280004><r 4>"
    "<b 0x000100182112a442><r 12><b 0x802200094753747265616d657200000080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x80220007657475726e616c0080280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200087374756e7365727680280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200084d6574617377697480280004><r 4>"
    "<b 0x000100142112a442><r 12><b 0x802200076564756d6565740080280004><r 4>"
)

# --> AWG: ПУЛ ШАБЛОНОВ SIP <--
# - SIP INVITE (RFC 3261) с разными User-Agent: Asterisk, FreeSWITCH, Zoiper, Linphone, MicroSIP, 3CX, X-Lite -
# - размер 285-310 байт, влезает в MTU 1280+ с запасом -
# - переменные: user (<rc 8>), domain (<rc 12>), IP октеты (<rd 2>), branch (<rd 10>), tag (<rd 8>), Call-ID (<rc 16>) -
AWG_CPS_SIP_POOL=(
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20417374657269736b205042582031382e32302e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a202245787422203c7369703a65787440><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20467265655357495443482d6d6f645f736f6669612f312e31302e31310d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x3b72706f72740d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205a6f69706572207276322e31302e32302e340d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a20323020494e564954450d0a557365722d4167656e743a204c696e70686f6e652f352e332e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b72706f72743b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204d6963726f5349502f332e32312e330d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a2033435850686f6e652f31382e302e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a7573657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a206579654265616d2072656c656173652033303033660d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204272696120352e362e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20426c696e6b20332e342e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205477696e6b6c652f312e31302e310d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20596174652f362e342e300d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a204772616e6473747265616d20485438303220312e302e32392e380d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a205965616c696e6b205349502d543436472036362e38360d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20736e6f6d3337302f382e372e352e34340d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
    "<b 0x494e56495445207369703a><rc 8><b 0x40><rc 12><b 0x205349502f322e300d0a5669613a205349502f322e302f55445020><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x3a353036303b6272616e63683d7a39684734624b><rd 10><b 0x0d0a46726f6d3a203c7369703a63616c6c657240><rc 12><b 0x3e3b7461673d><rd 8><b 0x0d0a546f3a203c7369703a><rc 8><b 0x40><rc 12><b 0x3e0d0a43616c6c2d49443a20><rc 16><b 0x40><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x2e><rd 2><b 0x0d0a435365713a203120494e564954450d0a557365722d4167656e743a20504a5355412076322e31330d0a4d61782d466f7277617264733a2037300d0a436f6e74656e742d4c656e6774683a20300d0a0d0a>"
)

_awg2_cps_preset_stun() {
    # - STUN Binding Request (RFC 5389) с SOFTWARE - маскировка под WebRTC/VoIP -
    # - аргумент: fp=yes - использовать пул с рандомным FINGERPRINT (40 байт), иначе NOFP (32 байта) -
    local fp="${1:-no}"
    local -a pool
    if [[ "$fp" == "yes" ]]; then
        pool=("${AWG_CPS_STUN_POOL_FP[@]}")
    else
        pool=("${AWG_CPS_STUN_POOL_NOFP[@]}")
    fi
    echo "${pool[$(( RANDOM % ${#pool[@]} ))]}"
}

_awg2_cps_preset_sip() {
    # - SIP INVITE с User-Agent реального SIP-клиента - маскировка под VoIP сигналинг -
    # - случайный шаблон из AWG_CPS_SIP_POOL -
    echo "${AWG_CPS_SIP_POOL[$(( RANDOM % ${#AWG_CPS_SIP_POOL[@]} ))]}"
}

# --> AWG: ВАЛИДАЦИЯ CPS-СТРОК <--
# - проверяет корректность CPS для I1..I5, вызывается при manual-вводе -
# - разрешённые теги: <b 0xHEX>, <r N>, <rd N>, <rc N>, <t> -
# - <c> явно запрещён: не реализован в amneziawg-go (issue #120) -
# - возвращает 0 если OK, 1 если ошибка (сообщение в stderr) -
_awg2_cps_validate() {
    local s="$1"
    [[ -z "$s" ]] && return 0

    # - баланс < и > -
    local opens closes
    opens=$(tr -cd '<' <<< "$s" | wc -c)
    closes=$(tr -cd '>' <<< "$s" | wc -c)
    if [[ "$opens" -ne "$closes" ]]; then
        echo "CPS: несбалансированные скобки < > (<=${opens}, >=${closes})" >&2
        return 1
    fi

    # - проход по тегам: все подстроки вида <...> -
    local tag rest="$s"
    while [[ "$rest" =~ \<([^\<\>]*)\> ]]; do
        tag="${BASH_REMATCH[1]}"
        rest="${rest#*>}"
        case "$tag" in
            t)
                : ;;
            c)
                echo "CPS: тег <c> (packet counter) не реализован в amneziawg-go, нельзя использовать" >&2
                return 1
                ;;
            "b 0x"*)
                local hex="${tag#b 0x}"
                if ! [[ "$hex" =~ ^[0-9a-fA-F]+$ ]]; then
                    echo "CPS: <b 0x${hex}> содержит не-hex символы" >&2
                    return 1
                fi
                if (( ${#hex} % 2 != 0 )); then
                    echo "CPS: <b 0x${hex}> имеет нечётное кол-во hex-символов (${#hex})" >&2
                    return 1
                fi
                ;;
            "r "*|"rd "*|"rc "*)
                local n="${tag##* }"
                if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
                    echo "CPS: <${tag}> - N должно быть положительным целым" >&2
                    return 1
                fi
                ;;
            *)
                echo "CPS: неизвестный тег <${tag}>. Разрешены: <b 0xHEX>, <r N>, <rd N>, <rc N>, <t>" >&2
                return 1
                ;;
        esac
    done

    # - вне тегов не должно быть других < или > -
    local stripped
    stripped=$(echo "$s" | sed -E 's/<[^<>]*>//g')
    if [[ "$stripped" == *'<'* || "$stripped" == *'>'* ]]; then
        echo "CPS: лишние < или > вне тегов" >&2
        return 1
    fi
    # - CPS должен состоять только из тегов, текст вне тегов невалиден -
    if [[ -n "$stripped" ]]; then
        echo "CPS: текст вне тегов не разрешён ('${stripped}'). Используйте <b 0xHEX> для ASCII" >&2
        return 1
    fi
    return 0
}

# - описание пресетов для интерактивного выбора -
# - показывает как работает, где реалистично, какие риски -
_awg2_preset_desc() {
    case "$1" in
        dns)
            echo "    Как работает: I1 имитирует DNS query типа A к выбранному домену."
            echo "    Реалистично: DNS-трафик есть всегда, самый банальный протокол."
            echo "    Риски: DNS обычно идёт на порт 53, запрос на AWG-порту = аномалия для"
            echo "           современного DPI. Оставлен как fallback, базовые блокировки обходит,"
            echo "           глубокий DPI (Иран, Китай, РФ 2024+) детектит."
            ;;
        stun)
            echo "    Как работает: I1 имитирует STUN Binding Request с SOFTWARE attribute."
            echo "    Реалистично: WebRTC активно используется (звонки, Telegram, Zoom), STUN"
            echo "           регулярно летит на рандомные порты. Пул 10 шаблонов (libjingle, coturn,"
            echo "           Chromium, Asterisk и т.д.) - каждый клиент получает случайный."
            echo "    Риски: глубокий DPI с CRC32-валидацией FINGERPRINT отбракует (если включить FP),"
            echo "           статистический DPI пропустит. Дефолт по проекту."
            ;;
        sip)
            echo "    Как работает: I1 имитирует SIP INVITE с User-Agent реального клиента."
            echo "    Реалистично: SIP-сигналинг в VoIP трафике, ~300 байт - типичный размер"
            echo "           INVITE. Пул 7 шаблонов (Asterisk, FreeSWITCH, Zoiper, Linphone,"
            echo "           MicroSIP, 3CX, X-Lite) с рандомными user/domain/Call-ID/branch/tag."
            echo "    Риски: SIP обычно tcp/5060 или udp/5060. На высоких UDP-портах SIP редкий,"
            echo "           но не невозможный (NAT traversal). На MTU<1420 пакет близко к границе."
            ;;
    esac
}

# - случайная CPS-строка для I2-I5: разнообразные теги для энтропии -
_awg2_cps_random() {
    local idx="$1"
    case "$idx" in
        2) echo "<r 32><t>" ;;
        3) echo "<rd 16><r 24>" ;;
        4) echo "<t><rc 20>" ;;
        5) echo "<r $(rand_range 16 48)>" ;;
        *) echo "<r 24>" ;;
    esac
}

# --> AWG: ГЕНЕРАЦИЯ I1-I5 <--
# - auto: меню выбора пресета (DNS / STUN / SIP), дефолт STUN -
# - STUN: дополнительный вопрос про FINGERPRINT (рандомный CRC32) -
# - SIP: warning если MTU<1420 (но работает на любом MTU≥1280) -
# - DNS: warning что уязвимо к современному DPI -
# - I1 обязателен для 1.5/2.0, I2-I5 - случайные CPS для энтропии -
# - MTU берётся из переменной окружения TUNNEL_MTU_CURRENT (устанавливается в install flow) -
_awg2_gen_i_packets() {
    local auto="$1"
    local mtu="${TUNNEL_MTU_CURRENT:-0}"
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""

    if [[ "$auto" == "yes" ]]; then
        echo ""
        echo -e "  ${bcy}I1 - первый пакет маскировки. Выбери под что маскировать handshake.${nc}"
        echo ""
        echo -e "  ${bgrn}s)${nc} ${bnc}STUN${nc} (WebRTC Binding Request) ${byel}[дефолт]${nc}"
        echo -e "  ${bgrn}p)${nc} ${bnc}SIP${nc} (VoIP INVITE)"
        echo -e "  ${bgrn}d)${nc} ${bnc}DNS${nc} (DNS query, fallback - уязвим к современному DPI)"
        echo ""
        local _ch=""
        while true; do
            ask_raw "$(printf '  \033[1mПресет?\033[0m [s]: ')" _ch
            case "${_ch:-s}" in
                s|S) AWG_I1_PRESET="stun"; break ;;
                p|P) AWG_I1_PRESET="sip";  break ;;
                d|D) AWG_I1_PRESET="dns";  break ;;
                *) print_warn "s, p или d" ;;
            esac
        done

        case "$AWG_I1_PRESET" in
            stun)
                local _fp=""
                echo ""
                echo -e "  ${bcy}STUN FINGERPRINT attribute (опциональный CRC32):${nc}"
                echo -e "  ${bcy}  без FP: 32 байта, проще, реже палится на кривых DPI${nc}"
                echo -e "  ${bcy}  с рандомным FP: 40 байт, реалистичнее (coturn/libjingle всегда пишут FP),${nc}"
                echo -e "  ${bcy}                  но DPI с проверкой CRC32 (Китай GFW) отбракует${nc}"
                ask_yn "Включить FINGERPRINT (рекомендуется кроме Китая)" "y" _fp
                if [[ "$_fp" == "yes" ]]; then
                    OBF_I1=$(_awg2_cps_preset_stun yes); print_info "I1 пресет: stun + FP"
                else
                    OBF_I1=$(_awg2_cps_preset_stun no);  print_info "I1 пресет: stun без FP"
                fi
                ;;
            sip)
                if [[ "$mtu" -gt 0 && "$mtu" -lt 1420 ]]; then
                    print_warn "MTU ${mtu} < 1420: SIP-пакет (~300 байт) близко к границе MTU"
                    print_info "Работать будет, но при глубокой фрагментации handshake может ломаться"
                    print_info "Рекомендуется MTU 1420 для чистого Ethernet. Отменить? (n = продолжить с SIP)"
                    local _cont=""
                    ask_yn "Всё равно использовать SIP?" "y" _cont
                    [[ "$_cont" != "yes" ]] && { AWG_I1_PRESET="stun"; OBF_I1=$(_awg2_cps_preset_stun no); print_info "Откат на STUN без FP"; }
                fi
                [[ -z "$OBF_I1" ]] && { OBF_I1=$(_awg2_cps_preset_sip); print_info "I1 пресет: sip"; }
                ;;
            dns)
                print_warn "DNS preset уязвим к современному DPI (Иран, Китай, РФ 2024+)"
                print_info "Работает против базовых блокировок (Казахстан, Беларусь, старые сети)"
                _awg2_choose_dns_domain
                OBF_I1=$(_awg2_cps_preset_dns "$AWG_DNS_SELECTED")
                print_info "I1 пресет: dns (${AWG_DNS_SELECTED})"
                ;;
        esac

        OBF_I2=$(_awg2_cps_random 2)
        OBF_I3=$(_awg2_cps_random 3)
        OBF_I4=$(_awg2_cps_random 4)
        OBF_I5=$(_awg2_cps_random 5)
    else
        echo ""
        echo -e "  ${bcy}I1-I5 - signature chain (CPS). I1 обязателен (иначе AWG работает как 1.0).${nc}"
        echo -e "  ${bcy}Формат: <b 0xHEX> - статичные байты, <r N> - случайные, <rd N> - цифры, <rc N> - буквы, <t> - timestamp.${nc}"
        echo -e "  ${bcy}Оставь пустым для пропуска пакета. I1 пустой = отключение CPS целиком.${nc}"
        echo ""
        echo -e "  ${bnc}Готовые пресеты для I1:${nc}"
        echo -e "  ${bgrn}s)${nc} ${bnc}STUN${nc} (WebRTC Binding Request)"
        _awg2_preset_desc stun
        echo ""
        echo -e "  ${bgrn}p)${nc} ${bnc}SIP${nc} (VoIP INVITE)"
        _awg2_preset_desc sip
        echo ""
        echo -e "  ${bgrn}d)${nc} ${bnc}DNS${nc} (DNS query - fallback, уязвим к современному DPI)"
        _awg2_preset_desc dns
        echo ""
        echo -e "  ${bgrn}m)${nc} ${bnc}Ввести вручную${nc}"
        echo ""
        local _ch=""
        while true; do
            ask_raw "$(printf '  \033[1mВыбор для I1?\033[0m [s]: ')" _ch
            case "${_ch:-s}" in
                s|S)
                    local _fp=""
                    ask_yn "Включить FINGERPRINT в STUN (рекомендуется кроме Китая)" "y" _fp
                    if [[ "$_fp" == "yes" ]]; then
                        OBF_I1=$(_awg2_cps_preset_stun yes)
                    else
                        OBF_I1=$(_awg2_cps_preset_stun no)
                    fi
                    break ;;
                p|P)
                    if [[ "$mtu" -gt 0 && "$mtu" -lt 1420 ]]; then
                        print_warn "MTU ${mtu} < 1420: SIP-пакет ~300 байт близко к границе"
                    fi
                    OBF_I1=$(_awg2_cps_preset_sip); break ;;
                d|D)
                    print_warn "DNS preset уязвим к современному DPI"
                    _awg2_choose_dns_domain
                    OBF_I1=$(_awg2_cps_preset_dns "$AWG_DNS_SELECTED")
                    break ;;
                m|M)
                    while true; do
                        ask "I1 (CPS)" "" OBF_I1
                        if _awg2_cps_validate "$OBF_I1"; then break; fi
                        print_err "Исправьте CPS-строку и повторите"
                    done
                    break ;;
                *) print_warn "s, p, d или m" ;;
            esac
        done
        # - I2-I5: manual с валидацией, пустое = пропустить -
        local _iv=""
        for _iv in 2 3 4 5; do
            while true; do
                ask "I${_iv} (CPS, пусто = пропустить)" "$(_awg2_cps_random "$_iv")" "OBF_I${_iv}"
                local -n _cur_i="OBF_I${_iv}"
                if _awg2_cps_validate "$_cur_i"; then unset -n _cur_i; break; fi
                print_err "Исправьте I${_iv} и повторите"
                unset -n _cur_i
            done
        done
    fi
}

# - выбор домена для DNS-пресета из пула с региональной группировкой -
# - маркеры ###Заголовок выводятся как разделители без номеров -
# - сквозная нумерация только для доменов, дефолт www.cloudflare.com -
# - результат кладёт в AWG_DNS_SELECTED -
_awg2_choose_dns_domain() {
    AWG_DNS_SELECTED=""
    echo ""
    echo -e "  ${bnc}Выбор домена для DNS-пресета:${nc}"
    echo -e "  ${bcy}Выбери правдоподобный для твоего региона.${nc}"
    echo -e "  ${bcy}Домен должен быть логичен для пользователя из твоей страны.${nc}"
    echo ""

    # - idx_map: по номеру в меню даёт индекс в AWG_DNS_DOMAINS -
    local -a idx_map=()
    local default_num=0
    local i=0 n=0 entry name desc
    for entry in "${AWG_DNS_DOMAINS[@]}"; do
        if [[ "$entry" == "###"* ]]; then
            echo -e "  ${bcy}-=== ${entry#\#\#\#} ===-${nc}"
        else
            n=$(( n + 1 ))
            idx_map+=("$i")
            name="${entry%%|*}"
            desc="${entry##*|}"
            printf "  ${bgrn}%2d)${nc} %-25s  ${bcy}%s${nc}\n" "$n" "$name" "$desc"
            [[ "$name" == "www.cloudflare.com" ]] && default_num="$n"
        fi
        i=$(( i + 1 ))
    done

    local own_num=$(( n + 1 ))
    local rand_num=$(( n + 2 ))
    echo ""
    printf "  ${bgrn}%2d)${nc} %s\n" "$own_num" "Ввести свой домен"
    printf "  ${bgrn}%2d)${nc} %s\n" "$rand_num" "Случайный из пула"
    echo ""

    local sel=""
    while true; do
        ask_raw "$(printf '  \033[1mНомер (1-%s)?\033[0m [%s]: ' "$rand_num" "$default_num")" sel
        [[ -z "$sel" ]] && sel="$default_num"
        if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -gt "$rand_num" ]]; then
            print_warn "Введи число от 1 до ${rand_num}"
            continue
        fi
        break
    done

    if [[ "$sel" -le "$n" ]]; then
        entry="${AWG_DNS_DOMAINS[${idx_map[$(( sel - 1 ))]}]}"
        AWG_DNS_SELECTED="${entry%%|*}"
    elif [[ "$sel" -eq "$own_num" ]]; then
        local d=""
        while true; do
            ask "Домен (например news.example.org)" "" d
            if validate_domain "$d"; then
                AWG_DNS_SELECTED="$d"
                break
            fi
            print_warn "Неверный формат домена (RFC 1035)"
        done
    else
        # - случайный: берём из idx_map чтобы гарантированно не попасть на маркер -
        local rnd_idx="${idx_map[$(( RANDOM % ${#idx_map[@]} ))]}"
        entry="${AWG_DNS_DOMAINS[$rnd_idx]}"
        AWG_DNS_SELECTED="${entry%%|*}"
    fi
    print_info "DNS-домен: ${AWG_DNS_SELECTED}"
}

# - AWG 1.0: H1-H4 одиночные значения, без I1-I5 -
# - arg1: auto, arg2: MTU -
_awg2_gen_obf_v1() {
    local auto="$1"
    local mtu="${2:-1320}"
    _awg2_gen_obf_common "$auto" "$mtu"
    OBF_S3=""; OBF_S4=""
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
    if [[ "$auto" == "yes" ]]; then
        # - rand_h теперь гарантирует >= 5 (значения 1..4 зарезервированы vanilla WG) -
        OBF_H1=$(rand_h); OBF_H2=$(rand_h); OBF_H3=$(rand_h); OBF_H4=$(rand_h)
        while [[ "$OBF_H2" == "$OBF_H1" ]]; do OBF_H2=$(rand_h); done
        while [[ "$OBF_H3" == "$OBF_H1" || "$OBF_H3" == "$OBF_H2" ]]; do OBF_H3=$(rand_h); done
        while [[ "$OBF_H4" == "$OBF_H1" || "$OBF_H4" == "$OBF_H2" || "$OBF_H4" == "$OBF_H3" ]]; do OBF_H4=$(rand_h); done
    else
        echo -e "  ${bcy}H1-H4 - магические числа в заголовках, >= 5 (1..4 зарезервированы vanilla WG).${nc}"
        echo -e "  ${bcy}Должны быть все разными. Рекомендуемый диапазон 5..2147483647.${nc}"
        while true; do
            ask "H1" "$(rand_h)" OBF_H1
            ask "H2" "$(rand_h)" OBF_H2
            ask "H3" "$(rand_h)" OBF_H3
            ask "H4" "$(rand_h)" OBF_H4
            if ! [[ "$OBF_H1" =~ ^[0-9]+$ && "$OBF_H2" =~ ^[0-9]+$ && "$OBF_H3" =~ ^[0-9]+$ && "$OBF_H4" =~ ^[0-9]+$ ]]; then
                print_err "H1-H4 должны быть целыми числами"
                continue
            fi
            if (( OBF_H1 < 5 || OBF_H2 < 5 || OBF_H3 < 5 || OBF_H4 < 5 )); then
                print_err "H1-H4 должны быть >= 5 (значения 1..4 зарезервированы vanilla WG)"
                continue
            fi
            if [[ "$OBF_H1" == "$OBF_H2" || "$OBF_H1" == "$OBF_H3" || "$OBF_H1" == "$OBF_H4" \
               || "$OBF_H2" == "$OBF_H3" || "$OBF_H2" == "$OBF_H4" || "$OBF_H3" == "$OBF_H4" ]]; then
                print_err "H1-H4 должны быть все разными, повторите ввод"
                continue
            fi
            break
        done
    fi
}

# - AWG 1.5: H1-H4 одиночные + I1-I5 -
# - arg1: auto, arg2: MTU -
_awg2_gen_obf_v15() {
    local auto="$1"
    local mtu="${2:-1320}"
    _awg2_gen_obf_v1 "$auto" "$mtu"
    TUNNEL_MTU_CURRENT="$mtu" _awg2_gen_i_packets "$auto"
}

# - проверка пересечения диапазонов "min-max": возвращает 0 если пересекаются -
_awg2_ranges_overlap() {
    local a="$1" b="$2"
    # - guard на формат: оба аргумента должны быть "число-число", иначе арифметика упадёт -
    [[ "$a" =~ ^[0-9]+-[0-9]+$ && "$b" =~ ^[0-9]+-[0-9]+$ ]] || return 1
    local a_lo a_hi b_lo b_hi
    a_lo="${a%-*}"; a_hi="${a#*-}"
    b_lo="${b%-*}"; b_hi="${b#*-}"
    [[ -z "$a_lo" || -z "$b_lo" ]] && return 1
    # - пересекаются если a_lo <= b_hi && b_lo <= a_hi -
    if [[ "$a_lo" -le "$b_hi" && "$b_lo" -le "$a_hi" ]]; then
        return 0
    fi
    return 1
}

# - AWG 2.0: S3/S4 + ranged H1-H4 + I1-I5 -
# - arg1: auto, arg2: MTU -
# - S3 (cookie packet padding): рекомендованный и технический диапазон 0-64 -
# - S4 (transport packet padding): рекомендованный и технический диапазон 0-32 -
# - S3 != S4, S3 + 56 != S4, S4 + 56 != S3 (симметрично S1/S2, по аналогии) -
# - H1-H4 ranged: 4 равные зоны по ~500M в пространстве [5, 2^31-1] -
# - в каждой зоне под-диапазон ширины 100-1000, зоны не пересекаются 'задумано' -
_awg2_gen_obf_v2() {
    local auto="$1"
    local mtu="${2:-1320}"
    _awg2_gen_obf_common "$auto" "$mtu"
    local s3_limit=64 s4_limit=32

    # - 4 равные зоны H1-H4, по ~500M значений, by design не пересекаются -
    local _zones=("5 500000000" "500000001 1000000000" "1000000001 1500000000" "1500000001 2147483647")

    # - локальный хелпер: случайный under-диапазон ширины 100-1000 в пределах [lo, hi] -
    _awg2_h_subrange() {
        local lo="$1" hi="$2" span start
        span=$(rand_range 100 1000)
        start=$(rand_range "$lo" $(( hi - span )))
        printf '%s-%s\n' "$start" $(( start + span ))
    }

    if [[ "$auto" == "yes" ]]; then
        # - S3: 0..64, исключая 0 для маскировки (0 = отсутствие паддинга, палится) -
        OBF_S3=$(rand_range 1 "$s3_limit")
        # - S4: 0..32 с исключениями S3, S3-56, S3+56 (симметричные правила по аналогии с S1/S2) -
        local s3_plus=$(( OBF_S3 + 56 ))
        local s3_minus=$(( OBF_S3 - 56 ))
        local -a s4_valid=() v
        for (( v=1; v<=s4_limit; v++ )); do
            [[ "$v" -eq "$OBF_S3" ]] && continue
            [[ "$v" -eq "$s3_plus" ]] && continue
            [[ "$v" -eq "$s3_minus" ]] && continue
            s4_valid+=("$v")
        done
        # - диапазон [1..32] минус максимум 3 значения = минимум 29 вариантов, пустым не будет -
        OBF_S4="${s4_valid[$(( RANDOM % ${#s4_valid[@]} ))]}"

        # - случайное назначение зон к H1..H4 через shuffle (Fisher-Yates) -
        local _ord=(0 1 2 3) _i _j _tmp
        for (( _i=3; _i>0; _i-- )); do
            _j=$(( RANDOM % (_i + 1) ))
            _tmp=${_ord[$_i]}; _ord[$_i]=${_ord[$_j]}; _ord[$_j]=$_tmp
        done
        local _n=1 _lo _hi _si
        for _si in "${_ord[@]}"; do
            read -r _lo _hi <<< "${_zones[$_si]}"
            printf -v "OBF_H${_n}" '%s' "$(_awg2_h_subrange "$_lo" "$_hi")"
            _n=$(( _n + 1 ))
        done
        # - defensive: зоны by design не пересекаются, но если что-то пойдёт не так - ловим -
        local _pair _a _b
        for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
            _a="${_pair%:*}"; _b="${_pair#*:}"
            local -n _av_ref="OBF_${_a}"
            local -n _bv_ref="OBF_${_b}"
            if _awg2_ranges_overlap "$_av_ref" "$_bv_ref"; then
                print_warn "H-зоны auto: неожиданное пересечение ${_a}(${_av_ref}) и ${_b}(${_bv_ref})"
            fi
            unset -n _av_ref _bv_ref
        done
    else
        echo -e "  ${bcy}S3 (cookie padding) 0-${s3_limit}, S4 (transport padding) 0-${s4_limit}.${nc}"
        echo -e "  ${bcy}S3 != S4, S3+56 != S4, S4+56 != S3 (симметричное правило).${nc}"
        while true; do
            ask "S3 (0-${s3_limit})" "20" OBF_S3
            [[ "$OBF_S3" =~ ^[0-9]+$ ]] && (( OBF_S3 >= 0 && OBF_S3 <= s3_limit )) && break
            print_err "S3 должно быть целым от 0 до ${s3_limit}"
        done
        while true; do
            ask "S4 (0-${s4_limit})" "15" OBF_S4
            if ! [[ "$OBF_S4" =~ ^[0-9]+$ ]] || (( OBF_S4 < 0 || OBF_S4 > s4_limit )); then
                print_err "S4 должно быть целым от 0 до ${s4_limit}"
                continue
            fi
            if (( OBF_S4 == OBF_S3 )); then
                print_err "S4 не должно равняться S3 (${OBF_S3})"
                continue
            fi
            if (( OBF_S4 == OBF_S3 + 56 )); then
                print_err "S4 не должно равняться S3+56"
                continue
            fi
            if (( OBF_S4 + 56 == OBF_S3 )); then
                print_err "S4+56 не должно равняться S3"
                continue
            fi
            break
        done
        echo -e "  ${bcy}H1-H4 - диапазоны магических чисел в формате min-max, >= 5, ширина 100-1000.${nc}"
        echo -e "  ${bcy}Диапазоны не должны пересекаться между собой.${nc}"
        # - дефолты из 4 равных зон, корректные start-end -
        local _d1 _d2 _d3 _d4 _zlo _zhi
        read -r _zlo _zhi <<< "${_zones[0]}"; _d1="$(_awg2_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[1]}"; _d2="$(_awg2_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[2]}"; _d3="$(_awg2_h_subrange "$_zlo" "$_zhi")"
        read -r _zlo _zhi <<< "${_zones[3]}"; _d4="$(_awg2_h_subrange "$_zlo" "$_zhi")"
        local _att=0 _max_att=3 _pair _a _b _give_up=0
        while true; do
            ask "H1 (min-max, зона 1: 5..500M)" "$_d1" OBF_H1
            ask "H2 (min-max, зона 2: 500M..1G)" "$_d2" OBF_H2
            ask "H3 (min-max, зона 3: 1G..1.5G)" "$_d3" OBF_H3
            ask "H4 (min-max, зона 4: 1.5G..2.1G)" "$_d4" OBF_H4
            # - проверка формата: все четыре "число-число", min >= 5, min <= max -
            local _fmt_ok="yes" _h _lo _hi
            for _h in OBF_H1 OBF_H2 OBF_H3 OBF_H4; do
                local -n _hv="$_h"
                if ! [[ "$_hv" =~ ^[0-9]+-[0-9]+$ ]]; then
                    print_err "${_h} должно быть в формате min-max (например 5-1005)"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                _lo="${_hv%-*}"; _hi="${_hv#*-}"
                if (( _lo < 5 )); then
                    print_err "${_h}: min должен быть >= 5 (1..4 зарезервированы vanilla WG)"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                if (( _lo > _hi )); then
                    print_err "${_h}: min (${_lo}) должен быть <= max (${_hi})"
                    _fmt_ok="no"; unset -n _hv; break
                fi
                unset -n _hv
            done
            if [[ "$_fmt_ok" != "yes" ]]; then
                (( _att++ ))
                [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
                continue
            fi
            # - проверка на пересечение всех пар -
            local _overlap="no"
            for _pair in "H1:H2" "H1:H3" "H1:H4" "H2:H3" "H2:H4" "H3:H4"; do
                _a="${_pair%:*}"; _b="${_pair#*:}"
                local -n _av_ref="OBF_${_a}"
                local -n _bv_ref="OBF_${_b}"
                if _awg2_ranges_overlap "$_av_ref" "$_bv_ref"; then
                    print_err "Диапазоны ${_a}(${_av_ref}) и ${_b}(${_bv_ref}) пересекаются"
                    _overlap="yes"
                    unset -n _av_ref _bv_ref
                    break
                fi
                unset -n _av_ref _bv_ref
            done
            [[ "$_overlap" == "no" ]] && break
            (( _att++ ))
            [[ $_att -ge $_max_att ]] && { _give_up=1; break; }
        done
        # - после 3 неудач - автогенерация через ту же зональную механику что в auto-ветке -
        # - невалидные H1-H4 в конфиг не уходят: либо валидный ввод, либо валидный auto-фоллбек -
        if [[ $_give_up -eq 1 ]]; then
            print_warn "Слишком много невалидных вводов, генерирую H1-H4 автоматически"
            local _ord_f=(0 1 2 3) _i_f _j_f _tmp_f
            for (( _i_f=3; _i_f>0; _i_f-- )); do
                _j_f=$(( RANDOM % (_i_f + 1) ))
                _tmp_f=${_ord_f[$_i_f]}; _ord_f[$_i_f]=${_ord_f[$_j_f]}; _ord_f[$_j_f]=$_tmp_f
            done
            local _n_f=1 _lo_f _hi_f _si_f
            for _si_f in "${_ord_f[@]}"; do
                read -r _lo_f _hi_f <<< "${_zones[$_si_f]}"
                printf -v "OBF_H${_n_f}" '%s' "$(_awg2_h_subrange "$_lo_f" "$_hi_f")"
                _n_f=$(( _n_f + 1 ))
            done
            print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        fi
    fi
    # - I1-I5 для v2, пробрасываем MTU в _awg2_gen_i_packets через env -
    TUNNEL_MTU_CURRENT="$mtu" _awg2_gen_i_packets "$auto"
}

# - WireGuard vanilla: все параметры обнулены, совместимость со стандартным WG -
_awg2_gen_obf_wg() {
    OBF_JC=0; OBF_JMIN=0; OBF_JMAX=0
    OBF_S1=0; OBF_S2=0; OBF_S3=""; OBF_S4=""
    OBF_H1=1; OBF_H2=2; OBF_H3=3; OBF_H4=4
    OBF_I1=""; OBF_I2=""; OBF_I3=""; OBF_I4=""; OBF_I5=""
}

# - блок обфускации для .conf (server и client) -
_awg2_obf_conf_lines() {
    if [[ "${AWG2_VER}" == "wg" ]]; then
        return 0
    fi
    echo "Jc = ${OBF_JC}"
    echo "Jmin = ${OBF_JMIN}"
    echo "Jmax = ${OBF_JMAX}"
    echo "S1 = ${OBF_S1}"
    echo "S2 = ${OBF_S2}"
    [[ -n "$OBF_S3" ]] && echo "S3 = ${OBF_S3}"
    [[ -n "$OBF_S4" ]] && echo "S4 = ${OBF_S4}"
    echo "H1 = ${OBF_H1}"
    echo "H2 = ${OBF_H2}"
    echo "H3 = ${OBF_H3}"
    echo "H4 = ${OBF_H4}"
    [[ -n "$OBF_I1" ]] && echo "I1 = ${OBF_I1}"
    [[ -n "$OBF_I2" ]] && echo "I2 = ${OBF_I2}"
    [[ -n "$OBF_I3" ]] && echo "I3 = ${OBF_I3}"
    [[ -n "$OBF_I4" ]] && echo "I4 = ${OBF_I4}"
    [[ -n "$OBF_I5" ]] && echo "I5 = ${OBF_I5}"
    return 0
}

# - блок обфускации для env файла -
_awg2_obf_env_lines() {
    echo "AWG2_VERSION=\"${AWG2_VER}\""
    echo "JC=\"${OBF_JC}\""
    echo "JMIN=\"${OBF_JMIN}\""
    echo "JMAX=\"${OBF_JMAX}\""
    echo "S1=\"${OBF_S1}\""
    echo "S2=\"${OBF_S2}\""
    [[ -n "$OBF_S3" ]] && echo "S3=\"${OBF_S3}\""
    [[ -n "$OBF_S4" ]] && echo "S4=\"${OBF_S4}\""
    echo "H1=\"${OBF_H1}\""
    echo "H2=\"${OBF_H2}\""
    echo "H3=\"${OBF_H3}\""
    echo "H4=\"${OBF_H4}\""
    # - I1-I5 экранируем двойные кавычки внутри CPS-строк для безопасного source -
    [[ -n "$OBF_I1" ]] && echo "I1=\"${OBF_I1//\"/\\\"}\""
    [[ -n "$OBF_I2" ]] && echo "I2=\"${OBF_I2//\"/\\\"}\""
    [[ -n "$OBF_I3" ]] && echo "I3=\"${OBF_I3//\"/\\\"}\""
    [[ -n "$OBF_I4" ]] && echo "I4=\"${OBF_I4//\"/\\\"}\""
    [[ -n "$OBF_I5" ]] && echo "I5=\"${OBF_I5//\"/\\\"}\""
    return 0
}

# - заголовок-комментарий для клиентского .conf -
# - указывает версию AWG, требуемые клиенты и Keenetic NDMS -
_awg2_client_header_comment() {
    case "$AWG2_VER" in
        1.0)
            echo "# AWG 1.0"
            echo "# Совместимость: AmneziaVPN, AmneziaWG native, Keenetic NDMS 5.1 Alpha 3+"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            echo "# Keenetic: отдельный файл .keenetic.conf / .keenetic.cli (если сгенерирован)"
            ;;
        1.5)
            echo "# AWG 1.5 (Jc/Jmin/Jmax/S1/S2/H1-H4 + I1-I5 signature chain)"
            echo "# Совместимость: AmneziaVPN 4.x+, AmneziaWG 1.5+, Keenetic NDMS 5.1 Alpha 3+"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            echo "# Keenetic: отдельный файл .keenetic.conf / .keenetic.cli (если сгенерирован)"
            ;;
        2.0)
            echo "# AWG 2.0 (S3/S4 + ranged H1-H4 + I1-I5)"
            echo "# Совместимость: AmneziaVPN 4.8.12.9+, AmneziaWG 2.0.0+"
            echo "# Keenetic: NDMS 5.1 Alpha 3+ поддерживает ASC 2.0, стабильный импорт с 5.1 Alpha 5+"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            echo "# Keenetic: только .keenetic.conf (CLI не генерится для 2.0, ranged H неудобны)"
            ;;
        wg)
            echo "# WireGuard vanilla (без обфускации)"
            echo "# Совместимость: любой WireGuard клиент, любая Keenetic NDMS с поддержкой WG"
            echo "# Как подключить: импортируй этот .conf в клиент (файл или QR-код)"
            ;;
    esac
}

# --> AWG: QR-КОД КЛИЕНТСКОГО КОНФИГА <--
# - показывает QR в терминале, ставит qrencode если нет -
_awg2_show_qr() {
    local conf_file="$1"
    [[ ! -f "$conf_file" ]] && return 1
    if ! command -v qrencode &>/dev/null; then
        local do_install=""
        ask_yn "Установить qrencode для QR-кодов?" "y" do_install
        if [[ "$do_install" == "yes" ]]; then
             menu_install_utils
#            apt-get install -y -qq qrencode 2>/dev/null || { print_warn "Не удалось установить qrencode"; return 1; }
        else
            return 1
        fi
    fi
    echo ""
    qrencode -t ansiutf8 < "$conf_file"
    echo ""
}

# --> AWG: ПУТИ ПО ИМЕНИ ИНТЕРФЕЙСА <--
awg2_iface_env()     { echo "${AWG2_SETUP}/iface_${1}.env"; }
awg2_iface_keys()    { echo "${AWG2_SETUP}/server_${1}"; }
awg2_iface_clients() { echo "${AWG2_SETUP}/clients_${1}"; }
awg2_iface_conf()    { echo "${AWG_SYSCONF}/${1}.conf"; }
# --> AWG: СПИСОК ИНТЕРФЕЙСОВ <--
awg2_get_iface_list() {
    local result=()
    for f in "${AWG2_SETUP}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local name
        name=$(basename "$f" | sed 's/^iface_//' | sed 's/\.env$//')
        result+=("$name")
    done
    echo "${result[@]:-}"
}

# --> AWG: СПИСОК КЛИЕНТОВ ИНТЕРФЕЙСА <--
awg2_get_client_list() {
    local iface="$1" cdir
    cdir=$(awg2_iface_clients "$iface")
    local result=()
    if [[ -d "$cdir" ]]; then
        for d in "${cdir}"/*/; do
            [[ -d "$d" ]] || continue
            result+=("$(basename "$d")")
        done
    fi
    echo "${result[@]:-}"
}

awg2_client_exists() { [[ -d "$(awg2_iface_clients "$1")/$2" ]]; }

# --> AWG: ПОИСК СВОБОДНОГО IP В ПОДСЕТИ <--
awg2_next_free_ip() {
    local iface="$1" base="$2"
    local conf
    conf=$(awg2_iface_conf "$iface")
    local used_ips=""
    [[ -f "$conf" ]] && used_ips=$(grep "^AllowedIPs" "$conf" \
        | awk '{print $3}' | cut -d'/' -f1)
    local i=2
    while [[ $i -lt 254 ]]; do
        local candidate="${base}.${i}"
        if ! grep -qxF "$candidate" <<< "$used_ips" 2>/dev/null; then
            echo "$candidate"; return
        fi
        i=$(( i + 1 ))
    done
    echo ""
}

# --> AWG: УДАЛЕНИЕ PEER ИЗ КОНФИГА ПО ПУБЛИЧНОМУ КЛЮЧУ <--
# - awk без зависимостей: буферизуем блоки [Peer], пропускаем совпавший -
awg2_remove_peer_by_pubkey() {
    local conf="$1" pub_key="$2"
    local tmpfile
    tmpfile=$(mktemp)
    # - потоковая awk логика: буфер только для [Peer], остальное печатается сразу -
    # - pending[] копит пустые строки чтобы срезать их если следом идёт удаляемый блок -
    awk -v target="$pub_key" '
        function flush_buffer() {
            if (!buf_active) return
            has_match = 0
            for (i = 1; i <= buf_len; i++) {
                if (buf[i] ~ /^[[:space:]]*PublicKey[[:space:]]*=/) {
                    # - нельзя split по "=", base64 ключи заканчиваются на "=" или "==" -
                    # - срезаем только префикс "PublicKey = ", остальное = значение целиком -
                    key_val = buf[i]
                    sub(/^[[:space:]]*PublicKey[[:space:]]*=[[:space:]]*/, "", key_val)
                    gsub(/[[:space:]]+$/, "", key_val)
                    if (key_val == target) { has_match = 1; break }
                }
            }
            if (has_match) {
                # - срезаем накопленные пустые строки перед удаляемым блоком -
                while (pending_len > 0 && pending[pending_len] ~ /^[[:space:]]*$/) pending_len--
            } else {
                # - сначала выплюнем pending, потом сам блок -
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                for (i = 1; i <= buf_len; i++) print buf[i]
            }
            buf_active = 0; buf_len = 0
        }
        BEGIN { buf_active = 0; buf_len = 0; pending_len = 0 }
        /^\[Peer\][[:space:]]*$/ {
            flush_buffer()
            buf_active = 1
            buf[++buf_len] = $0
            next
        }
        /^\[/ {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            pending_len = 0
            print
            next
        }
        {
            if (buf_active) {
                buf[++buf_len] = $0
            } else if ($0 ~ /^[[:space:]]*$/) {
                pending[++pending_len] = $0
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                print
            }
        }
        END {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
        }
    ' "$conf" > "$tmpfile"

    if [[ -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
    else
        print_err "Ошибка при обработке конфига (awk вернул пусто)"
        rm -f "$tmpfile"
        return 1
    fi
}

# --> AWG: УДАЛЕНИЕ PEER ПО ИМЕНИ (ФОЛБЕК) <--
# - awk: ищем блок [Peer] с комментарием "# <name>" -
awg2_remove_peer_by_name() {
    local conf="$1" cname="$2"
    local tmpfile
    tmpfile=$(mktemp)
    awk -v target="$cname" '
        function flush_buffer() {
            if (!buf_active) return
            has_match = 0
            for (i = 1; i <= buf_len; i++) {
                line = buf[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line == "# " target) { has_match = 1; break }
            }
            if (has_match) {
                while (pending_len > 0 && pending[pending_len] ~ /^[[:space:]]*$/) pending_len--
                found = 1
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                for (i = 1; i <= buf_len; i++) print buf[i]
            }
            buf_active = 0; buf_len = 0
        }
        BEGIN { buf_active = 0; buf_len = 0; pending_len = 0; found = 0 }
        /^\[Peer\][[:space:]]*$/ {
            flush_buffer()
            buf_active = 1
            buf[++buf_len] = $0
            next
        }
        /^\[/ {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            pending_len = 0
            print
            next
        }
        {
            if (buf_active) {
                buf[++buf_len] = $0
            } else if ($0 ~ /^[[:space:]]*$/) {
                pending[++pending_len] = $0
            } else {
                for (i = 1; i <= pending_len; i++) print pending[i]
                pending_len = 0
                print
            }
        }
        END {
            flush_buffer()
            for (i = 1; i <= pending_len; i++) print pending[i]
            exit (found ? 0 : 1)
        }
    ' "$conf" > "$tmpfile"
    local awk_rc=$?

    if [[ $awk_rc -eq 0 && -s "$tmpfile" ]]; then
        mv "$tmpfile" "$conf"; chmod 600 "$conf"
        print_ok "Блок [Peer] удалён по имени '${cname}'"
        return 0
    else
        print_err "Не удалось найти блок '${cname}'"
        rm -f "$tmpfile"
        return 1
    fi
}

# --> AWG: ПЕРЕЗАПУСК ИНТЕРФЕЙСА <--
awg2_reload_iface() {
    local iface="$1"
    systemctl restart "awg-quick@${iface}" 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        log_ok "Интерфейс ${iface} перезапущен"
    else
        log_err "Не запустился. Логи: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
    fi
}

# --> AWG: ВЫБОР ИНТЕРФЕЙСА (ИНТЕРАКТИВНЫЙ) <--
awg2_select_iface() {
    local ifaces
    ifaces=$(awg2_get_iface_list)
    if [[ -z "$ifaces" ]]; then
        log_warn "Нет настроенных интерфейсов. Создай новый (пункт 2)."
        AWG2_ACTIVE_IFACE=""
        return 0
    fi
    local count=0 iface_array=()
    print_section "Доступные интерфейсы:"
    for iface in $ifaces; do
        count=$(( count + 1 ))
        iface_array+=("$iface")
        local status="" desc=""
        local env_file
        env_file=$(awg2_iface_env "$iface")
        [[ -f "$env_file" ]] && desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            status="${bgrn}(*) активен${nc}"
        else
            status="${bred}( ) остановлен${nc}"
        fi
        printstr "$(cecho sG "${count}") $(cecho sW "${iface}") ${desc:+(${desc})}  $(cecho sW "${status}")\n"
    done
    echo ""
    if [[ $count -eq 1 ]]; then
        AWG2_ACTIVE_IFACE="${iface_array[0]}"
        log "Автовыбор: ${AWG2_ACTIVE_IFACE}"
        local env_file
        env_file=$(awg2_iface_env "$AWG2_ACTIVE_IFACE")
        # shellcheck disable=SC1090
        [[ -f "$env_file" ]] && source "$env_file"
        return
    fi
    local choice=""
    while true; do
        ask_raw "$(printf '  \033[1mВыберите интерфейс (1-%s)?\033[0m ' "$count")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            AWG2_ACTIVE_IFACE="${iface_array[$((choice-1))]}"
            break
        fi
        log_warn "Введите число от 1 до ${count}"
    done
    local env_file
    env_file=$(awg2_iface_env "$AWG2_ACTIVE_IFACE")
    # shellcheck disable=SC1090
    [[ -f "$env_file" ]] && source "$env_file"
    log_ok "Выбран: ${AWG2_ACTIVE_IFACE}"
}

# =============================================================================
# --> AWG: ENSURE KERNEL HEADERS <--
# - гарантирует наличие headers для текущего ядра, без них DKMS не соберёт модуль -
# - трёхступенчатый fallback: exact headers -> метапакет -> установка стандартного ядра -
# - return 0 = headers есть, return 1 = headers нет и не удалось поставить, return 2 = нужен reboot -
_awg2_ensure_headers() {
    local kver arch
    kver=$(uname -r)
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    if [[ -d "/lib/modules/${kver}/build" ]]; then
        print_ok "Kernel headers: ${kver} (уже установлены)"
        return 0
    fi
    # - шаг 1: точный пакет linux-headers-$(uname -r) -
    log "Устанавливаю linux-headers-${kver}..."
    if apt-get install -y -qq "linux-headers-${kver}" 2>/dev/null; then
        print_ok "linux-headers-${kver} установлен"
        return 0
    fi
    log_warn "Пакет linux-headers-${kver} не найден в репозитории"
    log "Пробую метапакет linux-headers-${arch}..."
    if apt-get install -y -qq "linux-headers-${arch}" 2>/dev/null; then
        if [[ -d "/lib/modules/${kver}/build" ]]; then
            log_ok "linux-headers-${arch} -> headers для ${kver} появились"
            return 0
        fi
        log_warn "Метапакет установлен, но headers для ${kver} всё ещё нет"
        log "Вероятно ядро ${kver} нестандартное (провайдер или backport)"
    fi
    print_err "Kernel headers для ${kver} недоступны"
    print_info "Для DKMS (AmneziaWG) нужны headers, которых нет для этого ядра.\nРешение: установить стандартное ядро Debian + reboot.\n\n"
    local fallback_pkg=""
    apt-cache show "linux-image-${arch}" &>/dev/null && fallback_pkg="linux-image-${arch}"
    if [[ -z "$fallback_pkg" ]]; then
        print_err "Метапакет linux-image-${arch} не найден в репозитории"
        return 1
    fi
    local do_install=""
    ask_yn "Установить стандартное ядро ${fallback_pkg} + headers?" "y" do_install
    if [[ "$do_install" != "yes" ]]; then
        print_warn "Без kernel headers AWG не заработает"
        return 1
    fi
    apt-get install -y "$fallback_pkg" "linux-headers-${arch}" || {
        print_err "Не удалось установить ядро"
        return 1
    }
    # - флаг: после reboot доустановить AWG модуль через DKMS -
    mkdir -p "$AWG2_SETUP"
    echo "pending" > "${AWG2_SETUP}/pending_dkms"
    chmod 600 "${AWG2_SETUP}/pending_dkms"
    print_ok "Стандартное ядро установлено"
    print_warn "Нужен reboot. После перезагрузки запусти скрипт снова."
    echo ""
    local do_reboot=""
    ask_yn "Перезагрузить сейчас?" "y" do_reboot
    [[ "$do_reboot" == "yes" ]] && { print_info "Reboot..."; reboot; }
    return 2
}

# --> AWG: ОПРЕДЕЛЕНИЕ UBUNTU CODENAME ДЛЯ PPA <--
_awg2_ppa_codename() {
    local deb_ver=""
    if [[ -f /etc/os-release ]]; then
        deb_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
    fi
    case "$deb_ver" in
        13|13.*) echo "noble" ;;
        12|12.*) echo "focal" ;;
        11|11.*) echo "focal" ;;
        *) echo "focal" ;;
    esac
}

# --> AWG: ДОБАВИТЬ PPA И УСТАНОВИТЬ ПАКЕТ <--
_awg2_install_ppa_package() {
    local gpg_key="75c9dd72c799870e310542e24166f2c257290828"
    local gpg_ok="no"
    for ks in "keyserver.ubuntu.com" "keys.openpgp.org" "pgp.mit.edu"; do
        print_info "Пробуем keyserver: ${ks}"
        if gpg --keyserver "$ks" --keyserver-options timeout=10 \
               --recv-keys "$gpg_key" 2>/dev/null; then
            gpg_ok="yes"
            print_ok "Ключ получен с ${ks}"
            break
        fi
        print_warn "Не удалось: ${ks}"
    done
    if [[ "$gpg_ok" != "yes" ]]; then
        print_err "Не удалось получить GPG-ключ ни с одного keyserver"
        return 1
    fi
    gpg --export "$gpg_key" > /usr/share/keyrings/amnezia.gpg
    rm -f /etc/apt/sources.list.d/amnezia.list \
          /etc/apt/sources.list.d/amneziawg.list
    local ppa_codename
    ppa_codename=$(_awg2_ppa_codename)
    print_info "PPA codename: ${ppa_codename}"
    cat > /etc/apt/sources.list.d/amnezia.list << REPOEOF
deb [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main
deb-src [signed-by=/usr/share/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main
REPOEOF
    # - бэкап sources.list перед модификацией для возможности rollback -
    local src_list_bak=""
    local src_modified="no"
    if [[ -f /etc/apt/sources.list ]]; then
        if ! grep -q "^deb-src" /etc/apt/sources.list; then
            src_list_bak="/etc/apt/sources.list.bak.awg.$(date +%s)"
            cp /etc/apt/sources.list "$src_list_bak"
            local _src_lines
            _src_lines=$(grep "^deb " /etc/apt/sources.list | sed 's/^deb /deb-src /')
            if [[ -n "$_src_lines" ]]; then
                echo "$_src_lines" >> /etc/apt/sources.list
                src_modified="yes"
                print_info "sources.list: добавлены deb-src (бэкап: ${src_list_bak})"
            fi
        fi
    fi
    if ! apt-get update -qq; then
        if [[ "$src_modified" == "yes" && -f "$src_list_bak" ]]; then
            mv "$src_list_bak" /etc/apt/sources.list
            print_warn "apt update упал, sources.list восстановлен"
        fi
        rm -f /etc/apt/sources.list.d/amnezia.list \
              /etc/apt/sources.list.d/amneziawg.list
        return 1
    fi
    if ! apt-get install -y amneziawg; then
        print_err "Не удалось установить пакет amneziawg"
        if [[ "$src_modified" == "yes" && -f "$src_list_bak" ]]; then
            mv "$src_list_bak" /etc/apt/sources.list
            apt-get update -qq 2>/dev/null || true
            print_warn "sources.list восстановлен (бэкап убран)"
        fi
        return 1
    fi
    [[ -n "$src_list_bak" && -f "$src_list_bak" ]] && rm -f "$src_list_bak"
    print_ok "Пакет amneziawg установлен"
    return 0
}

# --> AWG: ENSURE DKMS MODULE LOADED <--
_awg2_ensure_module() {
    local kver
    kver=$(uname -r)
    if lsmod 2>/dev/null | grep -q "^amneziawg"; then
        print_ok "Модуль amneziawg уже загружен"
        return 0
    fi
    if modprobe amneziawg 2>/dev/null; then
        print_ok "Модуль amneziawg загружен"
        return 0
    fi
    print_info "modprobe не удался, пробую dkms autoinstall..."
    dkms autoinstall 2>/dev/null || true
    if modprobe amneziawg 2>/dev/null; then
        print_ok "Модуль amneziawg загружен (после dkms autoinstall)"
        return 0
    fi
    local awg2_dkms_ver=""
    awg2_dkms_ver=$(dkms status 2>/dev/null | grep -oP 'amneziawg/\K[^,: ]+' | head -1 || echo "")
    if [[ -n "$awg2_dkms_ver" ]]; then
        print_info "DKMS: amneziawg/${awg2_dkms_ver}, пересобираю для ${kver}..."
        dkms remove "amneziawg/${awg2_dkms_ver}" --all 2>/dev/null || true
        dkms install "amneziawg/${awg2_dkms_ver}" -k "$kver" 2>/dev/null || true
        if modprobe amneziawg 2>/dev/null; then
            print_ok "Модуль amneziawg загружен (после пересборки DKMS)"
            return 0
        fi
    fi
    local dkms_out
    dkms_out=$(dkms status amneziawg 2>/dev/null || echo "нет данных")
    print_err "Модуль amneziawg не загружается"
    print_info "dkms status: ${dkms_out}"
    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        print_err "Kernel headers отсутствуют для ${kver} - DKMS не может собрать модуль"
        print_info "Установи headers: apt install linux-headers-\$(uname -r)"
    fi
    return 1
}

#-> AWG: УСТАНОВКА
#

awg2_install() {
    # --> ПРОВЕРКА ПОВТОРНОЙ УСТАНОВКИ <--
    # - блокируем если AWG уже установлен: файлы конфига или загруженный модуль
    local _has_conf _has_mod
    _has_conf="no"
    if [[ -d "$AWG_SYSCONF" ]] && compgen -G "${AWG_SYSCONF}/*.conf" > /dev/null; then
        _has_conf="yes"
    fi
    _has_mod="no"
    lsmod 2>/dev/null | grep -q "^amneziawg" && _has_mod="yes"
    if [[ "$_already_flag" == "true" && ( "$_has_conf" == "yes" || "$_has_mod" == "yes" ) ]]; then
        print_section "AmneziaWG уже установлен"
        print_warn "Повторная установка затрёт существующие ключи и конфиги."
        print_info "Для добавления нового интерфейса или клиента: меню 'Управление AmneziaWG'"
        print_info "Для полного сноса: меню 'Управление' -> Удаление"
        return 0
    fi
    print_section "Анализ системы"
    check_root
    check_virt
    check_os
    validate_os_ver
#    if grep -qi "debian" /etc/os-release 2>/dev/null; then
#        print_err "Ok. Debian."
#    elif grep -qi "centos" /etc/os-release 2>/dev/null; then
#        print_err "Ok. Centos."
#    else
#        print_err "Скрипт рассчитан на Debian 12/13 или Centos 9/10."
#        return 1
#    fi
#    local os_ver
#    local os_id
#    os_ver=$(grep "^VERSION_ID=" /etc/os-release | cut -d'"' -f2)
#    os_id=$(grep "^OS=" /etc/os-release | cut -d'"' -f2)
#    print_ok "Debian ${os_ver}"
    print_ok "${os_id} ${os_ver}"

    local kver arch
    kver=$(uname -r)
    arch=$(uname -m)
    print_ok "Ядро: ${kver}, арх: ${arch}"

    # - определение основного интерфейса и внешнего IP -
    local main_iface
    main_iface=$(ifext)
    [[ -z "$main_iface" ]] && main_iface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -1)
    print_ok "Основной интерфейс: ${main_iface}"
    local server_ip
    server_ip=$(ipext)
    [[ -n "$server_ip" ]] && print_ok "Внешний IP: ${server_ip}" || print_warn "Не удалось определить внешний IP"
    # - сохраняем system.env -
    mkdir -p "$AWG2_SETUP"
    chmod 700 "$AWG2_SETUP"
    local existing_subnets=""
    while IFS= read -r line; do
        local cidr
        cidr=$(echo "$line" | awk '{print $4}')
        [[ -n "$cidr" ]] && existing_subnets="${existing_subnets} ${cidr}"
    done < <(ip -o addr show | grep "inet " | grep -v "host lo")
    cat > "${AWG2_SETUP}/system.env" << SYSEOF
KVER="${kver}"
ARCH="${arch}"
MAIN_IFACE="${main_iface}"
SERVER_IP="${server_ip}"
EXISTING_SUBNETS="${existing_subnets}"
SYSEOF
    chmod 600 "${AWG2_SETUP}/system.env"
    #--> Проверка модуля ядра
    print_section "Проверка модуля ядра AmneziaWG"
    # - проверяем: может модуль уже есть -
    local already_installed="no"
    if lsmod 2>/dev/null | grep -q "^amneziawg" || \
       [[ -f "/lib/modules/${kver}/extra/amneziawg.ko" ]] || \
       [[ -f "/lib/modules/${kver}/updates/dkms/amneziawg.ko" ]]; then
        already_installed="yes"
        print_ok "Модуль amneziawg обнаружен для текущего ядра. Проверяю загружен ли..."
    else
       log_error "Модуль amneziawg не обнаружен для текущего ядра!"
       local confirm="n"
       ask_yn "Перейти в меню установки? " "n" confirm
       if [[ "$confirm" == "yes" ]]; then
           menu_install_awg2_mod
       fi
    fi

   if [[ "$os_id" == "debian" ]]; then
      apt-get update -qq || true
      apt-get install -y -qq curl gnupg2 dkms wireguard-tools || true
   else
      local confirm="n"
      ask_yn "Перейти в меню установки? " "n" confirm
      if [[ "$confirm" == "yes" ]]; then
          menu_install_awg2_mod
#          dnf check-update || true
#          dnf config-manager --enable crb || true
#          dnf clean all || true
#          dnf makecache || true
#          dnf install -y curl gnupg2 dkms wireguard-tools || true
      fi
   fi
   if [[ "$os_id" == "debian" ]]; then
       if [[ "$already_installed" == "no" ]]; then
           print_section "Проверка kernel headers"
           local hdr_rc=0
           _awg2_ensure_headers || hdr_rc=$?
           if [[ $hdr_rc -eq 2 ]]; then
               # - нужен reboot (установлено новое ядро) -
               return 1
           elif [[ $hdr_rc -ne 0 ]]; then
               print_err "Не удалось обеспечить kernel headers"
               print_info "AWG требует headers для сборки DKMS модуля"
               return 1
           fi
           print_section "Установка пакета AmneziaWG"
           if ! _awg2_install_ppa_package; then
               return 1
           fi
           print_section "Проверка модуля ядра"
           if ! _awg2_ensure_module; then
               print_err "Модуль amneziawg не удалось загрузить"
               print_info "Попробуй: reboot, затем запусти скрипт снова"
               return 1
           fi
        fi
    else
           # - модуль есть, но может быть не загружен -
           if ! lsmod 2>/dev/null | grep -q "^amneziawg"; then
               modprobe amneziawg 2>/dev/null || {
                   print_err "Модуль amneziawg не загружается"
                   return 1
               }
           fi
           print_ok "Модуль amneziawg загружен"
    fi

    ! command -v awg-quick &>/dev/null && print_err "awg-quick не найден"; return 1 || log_ok "awg-quick найден: $(command -v awg-quick)"

    # -- ПАРАМЕТРЫ ПЕРВОГО ИНТЕРФЕЙСА --
    print_section "Параметры сервера AmneziaWG"
    local endpoint_ip=$(ipext)
    while true; do
        echo -e "  ${bld}IP по которому клиенты подключаются к серверу."
        echo -e "  ${bld}Если определён верно, просто нажми Enter.${nc}"
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done
    local srv_port=43034
    while true; do
        echo -e "  ${bld}UDP порт AmneziaWG. Дефолт $srv_port, можно любой свободный.${nc}"
        ask "UDP порт" "$srv_port" srv_port
        if ! validate_port "$srv_port"; then print_err "Порт 1-65535"; continue; fi
        if ss -H -uln 2>/dev/null | grep -Eq "[:.]${srv_port}[[:space:]]"; then
            print_warn "Порт ${srv_port} уже занят"; continue
        fi
        break
    done
    log_ok "Порт: ${srv_port}"
    # - интерфейс туннеля -
    local tunnel_iface="awg2vds"
    while true; do
        printstr "$(cecho sW "Интерфейс AmneziaWG. Дефолт ")$(cecho sM %s)\n" "$tunnel_iface" 
        ask "Имя интерфейса" "$tunnel_iface" tunnel_iface
        if ! validate_tunnel_iface "$tunnel_iface"; then print_err "$tunnel_iface"; continue; fi
        break
    done
    log_ok "Интерфейс: ${tunnel_iface}"

    local tunnel_subnet="10.10.10.0/24"
    while true; do
        echo ""
        log "Подсети на интерфейсах сервера: ${existing_subnets}"
        subnet_check="Убедись что подсеть не совпадает с домашней сетью клиента (роутер, гостевой WiFi). Иначе VPN работать не будет!"
        printstr "$(cecho sY %s)\n" "$subnet_check"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.8.0.0/24"; continue; fi
        local tunnel_base
        tunnel_base=$(cidr_base "$tunnel_subnet")
        # - subnets_overlap() заточен под 10.X.0.0/24, этого достаточно для схемы AWG -
        if subnets_overlap "$tunnel_base" "$existing_subnets"; then
            log_error "Конфликт с подсетью сервера!"
            log "Попробуй: 10.9.0.0/24 или 172.16.0.0/24"
            continue
        fi
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$tunnel_base" == "$_hs" ]]; then
                log_warn "Подсеть ${tunnel_subnet} очень распространена на домашних роутерах!"
                log_warn "Если у клиента дома роутер раздаёт ${tunnel_subnet},"
                log_warn "VPN работать не будет (конфликт маршрутов)!\n"
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
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"
    log_ok "Подсеть: ${tunnel_subnet}, сервер: ${srv_tunnel_ip}"

    local client_dns="8.8.4.4" #, 1.1.1.1, 9.9.9.9"
    printstr "$(cecho sW "DNS для клиентов:")"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        printstr "$(cecho sM 1)${bnc}) Unbound: %s\n" "$srv_tunnel_ip"
        printstr "2) Предустановленные: %s\n" "$client_dns"
        echo ""
        while true; do
            ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" dns_ch ${client_dns}
            case "${dns_ch:-1}" in
                1) client_dns="${srv_tunnel_ip}"; break ;;
                2) client_dns="${client_dns}"; break ;;
                *) client_dns="${srv_tunnel_ip}"; break ;;
            esac
        done
    elif systemctl is-active --quiet named 2>/dev/null; then
        printstr "$(cecho sM 1)${bnc}) Named: %s\n" "$srv_tunnel_ip"
        printstr "2) Предустановленные: %s${nc}\n\n" "$client_dns"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" dns_ch ${client_dns}
            case "${dns_ch:-2}" in
                1) client_dns="${srv_tunnel_ip}"; break ;;
                2) client_dns="${client_dns}"; break ;;
                *) client_dns="${srv_tunnel_ip}"; break ;;
#                *) print_warn "1 или 2" ;;
            esac
        done
    else
        print_info "Unbound или named не запущены, дефолт: ${client_dns}"
    fi
    log_ok "DNS: ${client_dns}"

    # - AllowedIPs -
    allowed() {
        local def_allowed="0.0.0.0/1, 128.0.0.0/1"
        manual() { ask "AllowedIPs" $def_allowed allowed; }
        set_allowed_def() { printf -v allowed "%s" "$def_allowed"; }
        set_allowed_all() { printf -v allowed "%s" "0.0.0.0/0"; }
        set_allowed_tunnel() { printf -v allowed "%s" "$tunnel_subnet"; }
        declare mItems=("$def_allowed (KillSwitch)" "0.0.0.0/0 (весь трафик через VPN)" "$tunnel_subnet (только туннель)" "Ввести вручную")
        declare mActions=("set_allowed_def" "set_allowed_all" "set_allowed_tunnel" "manual")
        declare mTitle="Маршрутизация трафика"
        declare mDescr=""
        declare mType="section"
    show_menu
    }
    log_ok "AllowedIPs: $(allowed)"

    # -- MTU ТУННЕЛЯ --
    tunnel_mtu() {
        manual() { ask "MTU" $tunnel_mtu tunnel_mtu; }
        set_mtu_1280() { printf -v tunnel_mtu "%s" "1280"; }
        set_mtu_1320() { printf -v tunnel_mtu "%s" "1320"; }
        set_mtu_1420() { printf -v tunnel_mtu "%s" "1420"; }
        declare mItems=("1280 - максимальная совместимость (мобильные сети, GTP)" "1320 - баланс (рекомендуется 'ЭТО БАЗА')" "1420 - максимальная скорость (чистый Ethernet)" "Ввести вручную")
        declare mActions=("set_mtu_1280" "set_mtu_1320" "set_mtu_1420" "manual")
        declare mTitle="MTU туннеля"
        declare mDescr=""
        declare mType="section"
    show_menu
    }
    log_ok "MTU: $(tunnel_mtu)"

#    echo -e "  ${bnc}MTU туннеля:"
#    echo -e "  ${bnc}1) 1280 - максимальная совместимость (мобильные сети, GTP)"
#    echo -e "  ${bmag}2${bnc}) 1320 - баланс (рекомендуется 'ЭТО БАЗА')"
#    echo -e "  ${bnc}3) 1420 - максимальная скорость (чистый Ethernet)"
#    echo -e "  ${bnc}4) Ввести вручную"${nc}
#    local tunnel_mtu="1320"
#    while true; do
#        ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[2]\033[1m:\033[0m ')" mtu_ch "$tunnel_mtu"
#        case "${mtu_ch:-1}" in
#            1) tunnel_mtu="1280"; break ;;
#            2) tunnel_mtu="1320"; break ;;
#            3) tunnel_mtu="1420"; break ;;
#            4) ask "MTU" $tunnel_mtu tunnel_mtu; break ;;
#            *) tunnel_mtu="1320"; break ;;
#        esac
#    done

    # -- ВЕРСИЯ ПРОТОКОЛА И ОБФУСКАЦИЯ --
    _awg2_ask_version

    if [[ "$AWG2_VER" == "wg" ]]; then
        _awg2_gen_obf_wg
        print_ok "WireGuard vanilla - обфускация отключена"
    else
        print_section "Параметры обфускации"
        local obf_auto=""
        ask_yn "Сгенерировать параметры автоматически?" "y" obf_auto
        case "$AWG2_VER" in
            2.0) _awg2_gen_obf_v2  "$obf_auto" "$tunnel_mtu" ;;
            1.5) _awg2_gen_obf_v15 "$obf_auto" "$tunnel_mtu" ;;
            *)   _awg2_gen_obf_v1  "$obf_auto" "$tunnel_mtu" ;;
        esac
        print_ok "Параметры сгенерированы (AWG ${AWG2_VER}, MTU ${tunnel_mtu})"
        print_info "Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && print_info "S3=${OBF_S3} S4=${OBF_S4}"
        print_info "H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        [[ -n "$OBF_I1" ]] && print_info "I1-I5: заданы (signature chain)"
    fi

    # -- КЛИЕНТЫ --
    print_section "Клиенты"
    echo -e "  ${bld}Клиент - это одно устройство (телефон, ноутбук, роутер)."
    echo -e "  ${bld}Для каждого будет создан отдельный конфиг-файл с QR-кодом."
    local client_count="1"
    while true; do
        ask_raw "$(printf '  \033[1mСколько клиентов создать (1-50)?\033[0m ')" client_count ${client_count}
        [[ "$client_count" =~ ^[0-9]+$ ]] && [[ "$client_count" -ge 1 ]] && [[ "$client_count" -le 50 ]] && break
        print_err "Число от 1 до 50"
    done

    local client_names=()
    for (( ci=1; ci<=client_count; ci++ )); do
        local cname=""
        while true; do
            echo -e "  ${bnc}Придумай имя для устройства (латиница, цифры, дефис, подчёркивание).${nc}"
            ask "Имя клиента #${ci}" "client${ci}" cname
            if ! validate_name "$cname"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
            local dup=false
            for ex in "${client_names[@]}"; do [[ "$ex" == "$cname" ]] && dup=true && break; done
            if $dup; then print_err "Имя '${cname}' уже используется"; continue; fi
            client_names+=("$cname"); print_ok "Клиент #${ci}: ${cname}"; break
        done
    done

    # -- ГЕНЕРАЦИЯ КЛЮЧЕЙ И КОНФИГОВ --
    print_section "Генерация ключей и конфигов"

    local iface="${tunnel_iface}"
    local keys_dir
    keys_dir=$(awg2_iface_keys "$iface")
    local clients_dir
    clients_dir=$(awg2_iface_clients "$iface")
    local conf
    conf=$(awg2_iface_conf "$iface")
    local scripts_dir
    scripts_dir="$AWG2_SCRIPTS/$iface"

    mkdir -p "$keys_dir" "$clients_dir" "$AWG_SYSCONF" "$scripts_dir"
    chmod 700 "$keys_dir" "$clients_dir" "$scripts_dir"

    # Cтрочка ниже, должна была копировать скрипты в подпапку интерфейса, НО!
    # в какой-то момент этой папки не оказалось на месте, как и переменной.
    # В результате копировался корень в папку скриптов! )))
    #cp -r ${AWG2_SCRIPTS_TEMPLATES}/ ${scripts_dir}/

    awg genkey | tee "${keys_dir}/server.key" | awg pubkey > "${keys_dir}/server.pub"
    local srv_priv srv_pub
    srv_priv=$(cat "${keys_dir}/server.key")
    srv_pub=$(cat "${keys_dir}/server.pub")
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
    print_ok "Ключи сервера сгенерированы"

    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${srv_port}
PrivateKey = ${srv_priv}
$(_awg2_obf_conf_lines)
CONFEOF
    chmod 600 "$conf"

    # - генерация клиентов -
    for cname in "${client_names[@]}"; do
        local cdir="${clients_dir}/${cname}"
        mkdir -p "$cdir"; chmod 700 "$cdir"
        awg genkey | tee "${cdir}/private.key" | awg pubkey > "${cdir}/public.key" | awg genpsk > "${cdir}/psk.key"
        chmod 600 "${cdir}/private.key" "${cdir}/public.key" "${cdir}/psk.key"
        local cli_priv cli_pub cli_psk cli_ip
        cli_priv=$(cat "${cdir}/private.key")
        cli_pub=$(cat "${cdir}/public.key")
        cli_psk=$(cat "${cdir}/psk.key")
        cli_ip=$(awg2_next_free_ip "$iface" "$tunnel_base")
        if [[ -z "$cli_ip" ]]; then
            print_err "Нет свободных IP для ${cname}"; continue
        fi

        cat >> "$conf" << PEEREOF

[Peer]
# ${cname}
PublicKey = ${cli_pub}
AllowedIPs = ${cli_ip}/32
PresharedKey = ${cli_psk}
PEEREOF

        cat > "${cdir}/client.conf" << CLIEOF
$(_awg2_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${cli_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg2_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${endpoint_ip}:${srv_port}
AllowedIPs = ${allowed}
PresharedKey = ${cli_psk}
PersistentKeepalive = 25
CLIEOF
        chmod 600 "${cdir}/client.conf"
        print_ok "Клиент ${cname}: IP ${cli_ip}"
    done

    # - iface_awg0.env -
    cat > "$(awg2_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="основной"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg2_obf_env_lines)
ENVEOF
    chmod 600 "$(awg2_iface_env "$iface")"

    # - legacy server.env для совместимости -
    cat > "${AWG2_SETUP}/server.env" << LEGEOF
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${srv_port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
MAIN_IFACE="${main_iface}"
AWG2_IFACE="${iface}"
CLIENT_DNS="${client_dns}"
CLIENT_ALLOWED_IPS="${allowed}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg2_obf_env_lines)
LEGEOF
    chmod 600 "${AWG2_SETUP}/server.env"

    # - выставляем глобально для последующего Keenetic export в текущем shell -
    SERVER_ENDPOINT_IP="$endpoint_ip"
    SERVER_PORT="$srv_port"
    TUNNEL_MTU="$tunnel_mtu"

    # - добавить конфиг в awg-qiuck -
    print_section "Прописываем конфиг $conf AmneziaWG в awg-quick"
    awg-quick up $conf
    sleep 15
    # - запуск -
    print_section "Запуск AmneziaWG"
    systemctl enable "awg-quick@${iface}"
    systemctl restart "awg-quick@${iface}"
    sleep 4
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Сервис awg-quick@${iface} запущен"
    else
        print_err "Не запустился! journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
        return 1
    fi

    local awg2_ver
    awg2_ver=$(awg --version 2>/dev/null | head -1 || echo "")

    # - итог -
    local _ver_label="AmneziaWG ${AWG2_VER}"
    [[ "$AWG2_VER" == "wg" ]] && _ver_label="WireGuard (vanilla)"
    echo ""
    echo -e "${bgrn}${bnc}====================================================${nc}"
    echo -e "  ${bgrn}${bnc}${_ver_label} установлен!${nc}"
    echo -e "${bgrn}${bnc}====================================================${nc}"
    echo ""
    echo -e "  ${bnc}Конфиги клиентов:${nc}"
    for cname in "${client_names[@]}"; do
        echo -e "    ${bcy}*${nc} ${clients_dir}/${cname}/client.conf"
    done
    echo ""
    if [[ "$AWG2_VER" != "wg" ]]; then
        echo -e "  ${bnc}Обфускация:${nc} Jc=${OBF_JC} Jmin=${OBF_JMIN} Jmax=${OBF_JMAX} S1=${OBF_S1} S2=${OBF_S2}"
        [[ -n "$OBF_S3" ]] && echo -e "  S3=${OBF_S3} S4=${OBF_S4}"
        echo -e "  H1=${OBF_H1} H2=${OBF_H2} H3=${OBF_H3} H4=${OBF_H4}"
        echo ""
    fi

    # - QR-код и Keenetic per-client: отдельный вопрос для каждого клиента -
    local show_qr=""
    ask_yn "Показать QR-коды клиентов?" "y" show_qr
    echo ""
    for cname in "${client_names[@]}"; do
        local _qcf="${clients_dir}/${cname}/client.conf"
        [[ ! -f "$_qcf" ]] && continue
        echo -e "  ${bnc}-- ${cname} --${nc}"
        if [[ "$show_qr" == "yes" ]]; then
            _awg2_show_qr "$_qcf" || true
        fi
        echo ""
    done
    return 0
}

### AWG2: Управление
####################
awg2_show_status() {
    print_section "Статус AmneziaWG"
    local ifaces
    ifaces=$(awg2_get_iface_list)
    if [[ -z "$ifaces" ]]; then print_warn "Нет настроенных интерфейсов"; return 0; fi
    for iface in $ifaces; do
        echo ""
        local env_file desc="" port="" subnet="" ver=""
        env_file=$(awg2_iface_env "$iface")
        if [[ -f "$env_file" ]]; then
            desc=$(grep "^IFACE_DESC=" "$env_file" | cut -d'"' -f2 || true)
            port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2 || true)
            subnet=$(grep "^TUNNEL_SUBNET=" "$env_file" | cut -d'"' -f2 || true)
            ver=$(grep "^AWG2_VERSION=" "$env_file" | cut -d'"' -f2 || true)
        fi
        [[ -z "$ver" ]] && ver="1.0"
        local ver_label="AWG ${ver}"
        [[ "$ver" == "wg" ]] && ver_label="WireGuard"
        if systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; then
            echo -e "  ${bgrn}(*)${nc} ${bnc}${iface}${nc}  ${desc:+(${desc})}  ${ver_label}  порт ${port}  подсеть ${subnet}"
        else
            echo -e "  ${bred}( )${nc} ${bnc}${iface}${nc}  ${desc:+(${desc})}  ${ver_label} [${byel}остановлен${nc}]"
        fi
        if command -v awg &>/dev/null; then
            local _awg2_out
            _awg2_out=$(awg show "$iface" 2>/dev/null || true)
            if [[ -n "$_awg2_out" ]]; then
                local _peer="" _hs="" _tx="" _rx=""
                while IFS= read -r line; do
                    case "$line" in
                        *peer:*)
                            if [[ -n "$_peer" ]]; then
                                echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                            fi
                            _peer=$(echo "$line" | awk '{print $2}')
                            _hs=""; _tx=""; _rx=""
                            ;;
                        *"latest handshake"*)
                            _hs=$(echo "$line" | sed 's/.*latest handshake: //')
                            ;;
                        *transfer:*)
                            _tx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $1}')
                            _rx=$(echo "$line" | sed 's/.*transfer: //' | awk -F', ' '{print $2}')
                            ;;
                    esac
                done <<< "$_awg2_out"
                # - последний пир -
                if [[ -n "$_peer" ]]; then
                    echo -e "    peer ${_peer:0:8}...  ${_hs:-never}  ^${_tx:-0}  v${_rx:-0}"
                fi
            fi
        fi
        local clients
        clients=$(awg2_get_client_list "$iface")

        if [[ -n "$clients" ]]; then
            print_info "Клиенты:"
            for name in $clients; do
                local cdir client_ip=""
                cdir="$(awg2_iface_clients "$iface")/${name}"
                [[ -f "${cdir}/client.conf" ]] && \
                    client_ip=$(grep "^Address" "${cdir}/client.conf" | awk '{print $3}' | head -1 || true)
                echo -e "      ${bcy}*${nc} ${name}  ->  ${client_ip:-?}"
            done
        fi
    done
    return 0
}

awg2_create_iface() {
    print_section "Создать новый интерфейс"
    local existing_ifaces
    existing_ifaces=$(awg2_get_iface_list)
    local n=0
    while true; do
        local candidate="awg${n}"
        if ! echo "$existing_ifaces" | grep -qw "$candidate"; then break; fi
        n=$(( n + 1 ))
    done
    local iface=""
    while true; do
        echo -e "  ${bcy}Имя интерфейса - техническое название туннеля (строчные буквы и цифры, до 15 символов).${nc}"
        ask "Имя интерфейса" "$candidate" iface
        if ! [[ "$iface" =~ ^[a-z][a-z0-9]{0,14}$ ]]; then
            print_err "Строчные буквы и цифры, до 15 символов"; continue
        fi
        if [[ -f "$(awg2_iface_env "$iface")" ]]; then
            print_err "Интерфейс '${iface}' уже существует"; continue
        fi
        if awg show 2>/dev/null | grep -q "interface: ${iface}"; then
            print_err "'awg show ${iface}' показал, что такой интерфейс есть!"; continue
        fi
        break
    done
    local desc=""
    echo -e "  ${bcy}Описание - для себя, чтобы помнить для чего этот туннель (например: офис, семья, роутер).${nc}"
    ask "Описание" "" desc
    [[ -z "$desc" ]] && desc="$iface"
    local sys_env="${AWG2_SETUP}/system.env"
    local main_iface=""
    [[ -f "$sys_env" ]] && main_iface=$(grep "^MAIN_IFACE=" "$sys_env" | cut -d'"' -f2)
    [[ -z "$main_iface" ]] && main_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5}' | head -1)
    # - вторая ступень fallback: первый non-lo интерфейс -
    # - без main_iface PostUp с iptables -o "" упадёт, интерфейс не поднимется -
    [[ -z "$main_iface" ]] && main_iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | head -1)
    if [[ -z "$main_iface" ]]; then
        print_err "Не удалось определить основной сетевой интерфейс"
        print_err "Проверь: ip route show default"
        return 1
    fi

    local endpoint_ip=""
    endpoint_ip=$(grep "^SERVER_IP=" "$sys_env" 2>/dev/null | cut -d'"' -f2 || echo "")
    [[ -z "$endpoint_ip" ]] && endpoint_ip=$(curl -4 -fsSL --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    while true; do
        ask "Внешний IP (endpoint)" "$endpoint_ip" endpoint_ip
        validate_ip "$endpoint_ip" && break
        print_err "Некорректный IP"
    done

    local port=43034
    while true; do
        echo -e "  ${bcy}UDP порт для этого туннеля (1-65535). Должен быть свободен и не совпадать с другими.${nc}"
        ask "UDP порт" "$port" port
        if ! validate_port "$port"; then print_err "Порт 1-65535"; continue; fi
        if ss -H -uln 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then print_warn "Занят"; continue; fi
        break
    done

    # - следующая свободная подсеть -
    local used_bases=""
    for f in "${AWG2_SETUP}"/iface_*.env; do
        [[ -f "$f" ]] || continue
        local b
        b=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
        used_bases="${used_bases} ${b}"
    done
    local sn=8
    while echo "$used_bases" | grep -qw "10.${sn}.0"; do sn=$(( sn + 1 )); done
    local tunnel_subnet="10.${sn}.0.0/24"
    while true; do
        echo ""
        echo -e "  ${byel}Убедись что подсеть не совпадает с домашней сетью клиента.${nc}"
        ask "Подсеть туннеля" "$tunnel_subnet" tunnel_subnet
        if ! validate_cidr "$tunnel_subnet"; then print_err "Формат: 10.9.0.0/24"; continue; fi
        local new_base
        new_base=$(cidr_base "$tunnel_subnet")
        local conflict=false
        for f in "${AWG2_SETUP}"/iface_*.env; do
            [[ -f "$f" ]] || continue
            local ex_base
            ex_base=$(grep "^TUNNEL_SUBNET=" "$f" | cut -d'"' -f2 | cut -d'/' -f1 | sed 's/\.[0-9]*$//')
            if [[ "$ex_base" == "$new_base" ]]; then
                print_err "Подсеть уже используется!"; conflict=true; break
            fi
        done
        $conflict && continue
        local _home_conflict=false
        for _hs in 192.168.0 192.168.1 192.168.100 10.0.0 10.0.1 10.10.0; do
            if [[ "$new_base" == "$_hs" ]]; then
                print_warn "Подсеть ${tunnel_subnet} распространена на домашних роутерах!"
                print_warn "Возможен конфликт маршрутов у клиента."
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
    tunnel_base=$(cidr_base "$tunnel_subnet")
    local srv_tunnel_ip="${tunnel_base}.1"

    # - DNS -
    local dns="8.8.4.4"
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo ""
        echo -e "  ${bgrn}1)${nc} Unbound: ${srv_tunnel_ip}"
        echo -e "  ${bgrn}2)${nc} Дефолт: 8.8.4.4"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in 1) dns="${srv_tunnel_ip}"; break ;; 2) break ;; *) print_warn "1 или 2" ;; esac
        done
    elif systemctl is-active --quiet named 2>/dev/null; then
        echo ""
        echo -e "  ${bgrn}1)${nc} Named: ${srv_tunnel_ip}"
        echo -e "  ${bgrn}2)${nc} Дефолт: 8.8.4.4"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in 1) dns="${srv_tunnel_ip}"; break ;; 2) break ;; *) print_warn "1 или 2" ;; esac
        done
    fi

    # - AllowedIPs -
    local allowed_ips="0.0.0.0/0"
    echo ""
    echo -e "  ${bgrn}1)${nc} 0.0.0.0/0 (весь трафик)"
    echo -e "  ${bgrn}2)${nc} ${tunnel_subnet} (только туннель)"
    echo -e "  ${bgrn}3)${nc} Вручную"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" rt_ch
        case "$rt_ch" in
            1) allowed_ips="0.0.0.0/0"; break ;; 2) allowed_ips="$tunnel_subnet"; break ;;
            3) ask "AllowedIPs" "0.0.0.0/0" allowed_ips; break ;; *) print_warn "1, 2 или 3" ;;
        esac
    done

    # - MTU туннеля -
    local tunnel_mtu="1420"
    echo ""
    echo -e "  ${bnc}MTU туннеля:"
    echo -e "  ${bnc}1) 1280 - максимальная совместимость"
    echo -e "  ${bnc}2) 1320 - баланс (рекомендуется)"
    echo -e "  ${bmag}3${bnc}) 1420 - максимальная скорость"
    while true; do
        ask_raw "$(printf '  \033[1mВыбор?\033[0m [3]: ')" mtu_ch
        case "${mtu_ch:-3}" in
            1) tunnel_mtu="1280"; break ;;
            2) tunnel_mtu="1320"; break ;;
            3) tunnel_mtu="1420"; break ;;
            *) tunnel_mtu="1420"; break ;;
        esac
    done
    _awg2_ask_version
    if [[ "$AWG2_VER" == "wg" ]]; then
        _awg2_gen_obf_wg
    else
        local gen_obf=""
        ask_yn "Сгенерировать параметры обфускации автоматически?" "y" gen_obf
        case "$AWG2_VER" in
            2.0) _awg2_gen_obf_v2  "$gen_obf" "$tunnel_mtu" ;;
            1.5) _awg2_gen_obf_v15 "$gen_obf" "$tunnel_mtu" ;;
              1) _awg2_gen_obf_v1  "$gen_obf" "$tunnel_mtu" ;;
              *) _awg2_gen_obf_v2  "$gen_obf" "$tunnel_mtu" ;;
        esac
    fi
    local keys_dir
    keys_dir=$(awg2_iface_keys "$iface")
    mkdir -p "$keys_dir"; chmod 700 "$keys_dir"
    awg genkey | tee "${keys_dir}/server.key" | awg pubkey > "${keys_dir}/server.pub"
    chmod 600 "${keys_dir}/server.key" "${keys_dir}/server.pub"
    local srv_priv
    srv_priv=$(cat "${keys_dir}/server.key")

    local scripts_dir
    scripts_dir="$AWG2_SCRIPTS/$iface"
    mkdir -p "$scripts_dir"

    # Cтрочка ниже, должна была копировать скрипты в подпапку интерфейса, НО!
    # в какой-то момент этой папки не оказалось на месте, как и переменной.
    # В результате копировался корень в папку скриптов! )))
    #cp -r ${AWG2_SCRIPTS_TEMPLATES}/ ${scripts_dir}/

    local conf
    conf=$(awg2_iface_conf "$iface")
    mkdir -p "$AWG_SYSCONF"
    #PostUp = ${scripts_dir}/PostUp.sh ${port} ${srv_tunnel_ip}
    #PostDown = ${scripts_dir}/PostDown.sh ${port} ${srv_tunnel_ip}
    cat > "$conf" << CONFEOF
[Interface]
Address = ${srv_tunnel_ip}/24
MTU = ${tunnel_mtu}
ListenPort = ${port}
PrivateKey = ${srv_priv}
$(_awg2_obf_conf_lines)
CONFEOF
    chmod 600 "$conf"
    mkdir -p "$(awg2_iface_clients "$iface")"; chmod 700 "$(awg2_iface_clients "$iface")"

    # - env файл интерфейса -
    cat > "$(awg2_iface_env "$iface")" << ENVEOF
IFACE_NAME="${iface}"
IFACE_DESC="${desc}"
SERVER_ENDPOINT_IP="${endpoint_ip}"
SERVER_PORT="${port}"
SERVER_TUNNEL_IP="${srv_tunnel_ip}"
TUNNEL_SUBNET="${tunnel_subnet}"
TUNNEL_BASE="${tunnel_base}"
CLIENT_DNS="${dns}"
CLIENT_ALLOWED_IPS="${allowed_ips}"
TUNNEL_MTU="${tunnel_mtu}"
$(_awg2_obf_env_lines)
ENVEOF
    chmod 600 "$(awg2_iface_env "$iface")"

    # - выставляем глобально на случай если в текущем shell дальше потребуется -
    SERVER_ENDPOINT_IP="$endpoint_ip"
    SERVER_PORT="$port"
    TUNNEL_MTU="$tunnel_mtu"

    systemctl enable --now "awg-quick@${iface}" 2>/dev/null || true
    systemctl start "awg-quick@${iface}"
    sleep 3
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_ok "Интерфейс ${iface} (${desc}) запущен!"
    else
        print_err "Не запустился: journalctl -xeu awg-quick@${iface} --no-pager | tail -20"
    fi
}

awg2_toggle_iface() {
    print_section "Включить / выключить интерфейс"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"
    if systemctl is-active --quiet "awg-quick@${iface}"; then
        print_warn "Интерфейс ${iface} сейчас активен"
        local confirm=""
        ask_yn "Остановить?" "y" confirm
        [[ "$confirm" == "yes" ]] && systemctl stop "awg-quick@${iface}" && print_ok "Остановлен"
    else
        print_warn "Интерфейс ${iface} остановлен"
        local confirm=""
        ask_yn "Запустить?" "y" confirm
        if [[ "$confirm" == "yes" ]]; then
            systemctl start "awg-quick@${iface}"; sleep 1
            if systemctl is-active --quiet "awg-quick@${iface}"; then
                print_ok "Запущен"
            else
                print_err "Не запустился"
            fi
        fi
    fi
    return 0
}

awg2_restart_iface() {
    print_section "Перезапустить интерфейс"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    awg2_reload_iface "$AWG2_ACTIVE_IFACE"
    return 0
}

awg2_change_dns() {
    print_section "Изменить DNS интерфейса"
    local ifaces
    ifaces=$(awg2_get_iface_list)
    [[ -z "$ifaces" ]] && { print_warn "Нет интерфейсов"; return 0; }

    echo ""
    local i=1 iface_arr=()
    for iface in $ifaces; do
        local env_f cur_dns=""
        env_f=$(awg2_iface_env "$iface")
        [[ -f "$env_f" ]] && cur_dns=$(grep "^CLIENT_DNS=" "$env_f" | cut -d'"' -f2 || true)
        echo -e "  ${bgrn}${i})${nc} ${iface}  ${bcy}(DNS: ${cur_dns:-?})${nc}"
        iface_arr+=("$iface"); i=$(( i + 1 ))
    done
    echo ""
    ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 ]] || [[ "$sel" -gt ${#iface_arr[@]} ]]; then
        print_warn "Неверный выбор"; return 0
    fi
    local sel_iface="${iface_arr[$(( sel - 1 ))]}"

    local env_file
    env_file=$(awg2_iface_env "$sel_iface")
    [[ ! -f "$env_file" ]] && { print_err "Env не найден"; return 0; }
    # shellcheck disable=SC1090
    source "$env_file"

    local new_dns=""
    echo ""
    if systemctl is-active --quiet unbound 2>/dev/null; then
        echo -e "  ${bgrn}1)${nc} Unbound: ${SERVER_TUNNEL_IP}"
        echo -e "  ${bgrn}2)${nc} Дефолт: 8.8.8.8, 1.1.1.1, 9.9.9.9"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор?\033[0m ')" dns_ch
            case "$dns_ch" in
                1) new_dns="${SERVER_TUNNEL_IP}"; break ;;
                2) new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"; break ;;
                *) print_warn "1 или 2" ;;
            esac
        done
    else
        new_dns="8.8.8.8, 1.1.1.1, 9.9.9.9"
    fi

    sed -i "s|^CLIENT_DNS=.*|CLIENT_DNS=\"${new_dns}\"|" "$env_file"
    print_ok "DNS ${sel_iface}: ${new_dns}"

    local clients_dir updated=0
    clients_dir=$(awg2_iface_clients "$sel_iface")
    if [[ -d "$clients_dir" ]]; then
        for ccf in "${clients_dir}"/*/client.conf; do
            [[ -f "$ccf" ]] || continue
            sed -i "s|^DNS = .*|DNS = ${new_dns}|" "$ccf"
            updated=$(( updated + 1 ))
        done
        [[ $updated -gt 0 ]] && print_ok "Обновлено конфигов: ${updated}"
    fi
    print_info "Клиентам нужно переимпортировать конфиг"
    return 0
}

awg2_delete_iface() {
    print_section "Удалить интерфейс"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"
    # - проверка что интерфейс реально существует -
    local conf
    conf=$(awg2_iface_conf "$iface")
    local env_file
    env_file=$(awg2_iface_env "$iface")
    if [[ ! -f "$conf" ]] && [[ ! -f "$env_file" ]]; then
        print_warn "Интерфейс '${iface}' не найден (конфиг и env отсутствуют)"
        return 0
    fi

    echo ""
    print_warn "Интерфейс '${iface}' будет полностью удалён!"
    local confirm=""
    ask_yn "Подтвердить удаление?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }
    # - запоминаем порт до удаления env -
    local port=""
    [[ -f "$env_file" ]] && port=$(grep "^SERVER_PORT=" "$env_file" | cut -d'"' -f2)
    systemctl stop "awg-quick@${iface}" 2>/dev/null || true
#    awg-quick down ${iface} 2>/dev/null || true
    sleep 2
    systemctl disable --now "awg-quick@${iface}" 2>/dev/null || true
    rm -f "$(awg2_iface_conf "$iface")"
    rm -rf "$(awg2_iface_keys "$iface")"
    rm -rf "$(awg2_iface_clients "$iface")"
    rm -f "$env_file"

    local remaining
    remaining=$(awg2_get_iface_list)
    print_ok "Интерфейс ${iface} удалён"
    return 0
}

awg2_add_client() {
    print_section "Добавить клиента"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"
    local env_file
    env_file=$(awg2_iface_env "$iface")
    # shellcheck disable=SC1090
    source "$env_file"
    # - загружаем обфускацию из env в OBF_* для хелперов -
    AWG2_VER="${AWG2_VERSION:-1.0}"
    OBF_JC="$JC"; OBF_JMIN="$JMIN"; OBF_JMAX="$JMAX"
    OBF_S1="$S1"; OBF_S2="$S2"; OBF_S3="${S3:-}"; OBF_S4="${S4:-}"
    OBF_H1="$H1"; OBF_H2="$H2"; OBF_H3="$H3"; OBF_H4="$H4"
    OBF_I1="${I1:-}"; OBF_I2="${I2:-}"; OBF_I3="${I3:-}"
    OBF_I4="${I4:-}"; OBF_I5="${I5:-}"
    local tunnel_mtu="${TUNNEL_MTU:-1320}"
    local srv_pub
    srv_pub=$(cat "$(awg2_iface_keys "$iface")/server.pub")

    local name=""
    while true; do
        echo -e "  ${bcy}Имя устройства - латиница, цифры, дефис, подчёркивание (например: iphone-vasya, laptop-work).${nc}"
        ask "Имя нового клиента" "" name
        if ! validate_name "$name"; then print_err "Буквы, цифры, дефис, подчёркивание"; continue; fi
        if awg2_client_exists "$iface" "$name"; then print_err "'${name}' уже существует"; continue; fi
        break
    done

    local client_ip
    client_ip=$(awg2_next_free_ip "$iface" "$TUNNEL_BASE")
    [[ -z "$client_ip" ]] && { print_err "Нет свободных IP в ${TUNNEL_SUBNET}"; return 0; }
    print_ok "IP: ${client_ip}"

    local client_dns="$CLIENT_DNS"
    local client_allowed="$CLIENT_ALLOWED_IPS"
    local change_allowed=""
    ask_yn "Изменить AllowedIPs для этого клиента?" "n" change_allowed
    if [[ "$change_allowed" == "yes" ]]; then
        echo -e "  ${bmag}1${bnc}) 0.0.0.0/0"
        echo -e "  ${bld}2) ${TUNNEL_SUBNET}"
        echo -e "  ${bld}3) Вручную ${nc}"
        while true; do
            ask_raw "$(printf '  \033[1mВыбор? \033[1;35m[1]\033[1m:\033[0m ')" rc
            case "$(rc:-1)" in
                1) client_allowed="0.0.0.0/0"; break ;;
                2) client_allowed="$TUNNEL_SUBNET"; break ;;
                3) ask "AllowedIPs" "$client_allowed" client_allowed; break ;;
                *) client_allowed="0.0.0.0/0"; break ;;
            esac
        done
    fi

    local cdir
    cdir="$(awg2_iface_clients "$iface")/${name}"
    mkdir -p "$cdir"; chmod 700 "$cdir"
    awg genkey | tee "${cdir}/private.key" | awg pubkey > "${cdir}/public.key" | awg genpsk > "${cdir}/psk.key"
    chmod 600 "${cdir}/private.key" "${cdir}/public.key" "${cdir}/psk.key"
    local cli_priv cli_pub cli_psk
    cli_priv=$(cat "${cdir}/private.key")
    cli_pub=$(cat "${cdir}/public.key")
    cli_psk=$(cat "${cdir}/psk.key")

    local conf
    conf=$(awg2_iface_conf "$iface")
    cat >> "$conf" << PEEREOF

[Peer]
# ${name}
PublicKey = ${cli_pub}
AllowedIPs = ${client_ip}/32
PresharedKey = ${cli_psk}
PEEREOF

    cat > "${cdir}/client.conf" << CLIEOF
$(_awg2_client_header_comment)
[Interface]
PrivateKey = ${cli_priv}
Address = ${client_ip}/24
DNS = ${client_dns}
MTU = ${tunnel_mtu}
$(_awg2_obf_conf_lines)

[Peer]
PublicKey = ${srv_pub}
Endpoint = ${SERVER_ENDPOINT_IP}:${SERVER_PORT}
AllowedIPs = ${client_allowed}
PersistentKeepalive = 25
CLIEOF
    chmod 600 "${cdir}/client.conf"
    print_ok "Клиент ${name} добавлен: IP ${client_ip}"
    print_info "Конфиг: ${cdir}/client.conf"

    # - QR-код для мобильного клиента -
    local show_qr=""
    ask_yn "Показать QR-код?" "y" show_qr
    [[ "$show_qr" == "yes" ]] && _awg2_show_qr "${cdir}/client.conf"
    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg2_reload_iface "$iface"
    return 0
}

awg2_show_client() {
    print_section "Показать конфиг клиента"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"
    local clients
    clients=$(awg2_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${bcy}*${nc} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента" "" name
    local cfg
    cfg="$(awg2_iface_clients "$iface")/${name}/client.conf"
    [[ ! -f "$cfg" ]] && { print_err "Конфиг не найден: ${cfg}"; return 0; }
    echo ""
    echo -e "${bnc}-- ${iface}/${name}/client.conf --${nc}"
    cat "$cfg"
    echo -e "${bnc}--------------------------------------${nc}"
    echo ""
    print_info "Файл: ${cfg}"

    # - QR-код -
    local show_qr=""
    ask_yn "Показать QR-код?" "n" show_qr
    [[ "$show_qr" == "yes" ]] && _awg2_show_qr "$cfg"

    return 0
}

awg2_delete_client() {
    print_section "Удалить клиента"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"
    local clients
    clients=$(awg2_get_client_list "$iface")
    [[ -z "$clients" ]] && { print_warn "Нет клиентов на ${iface}"; return 0; }
    echo ""
    for n in $clients; do echo -e "  ${bcy}*${nc} ${n}"; done
    echo ""
    local name=""
    ask "Имя клиента для удаления" "" name
    [[ -z "$name" ]] && { print_warn "Имя не введено"; return 0; }
    if ! awg2_client_exists "$iface" "$name"; then
        print_err "Клиент '${name}' не найден"; return 0
    fi
    echo ""
    print_warn "Клиент '${name}' будет удалён!"
    local confirm=""
    ask_yn "Подтвердить?" "n" confirm
    [[ "$confirm" != "yes" ]] && { print_info "Отмена"; return 0; }

    local cdir conf
    cdir="$(awg2_iface_clients "$iface")/${name}"
    conf=$(awg2_iface_conf "$iface")
    if [[ -f "${cdir}/public.key" ]]; then
        local pub
        pub=$(cat "${cdir}/public.key")
        awg2_remove_peer_by_pubkey "$conf" "$pub"
        print_ok "Peer удалён из конфига"
    else
        awg2_remove_peer_by_name "$conf" "$name"
    fi
    rm -rf "${cdir:?}"
    print_ok "Файлы клиента '${name}' удалены"
    echo ""
    local do_restart=""
    ask_yn "Перезапустить ${iface}?" "y" do_restart
    [[ "$do_restart" == "yes" ]] && awg2_reload_iface "$iface"
    return 0
}

# --> AWG: ТЕСТ ОБФУСКАЦИИ <--
# - снимает tcpdump, анализирует handshake пакеты, определяет применились ли -
# - S1/S2 padding, Jc junk, H1-H4 mangle, I1 signature chain. Pcap удаляется -
awg2_test_obf() {
    print_section "Тест обфускации AmneziaWG"
    awg2_select_iface
    [[ -z "$AWG2_ACTIVE_IFACE" ]] && return 0
    local iface="$AWG2_ACTIVE_IFACE"

    # --> ЗАГРУЗКА ПАРАМЕТРОВ ИЗ ENV <--
    local env_file
    env_file=$(awg2_iface_env "$iface")
    [[ ! -f "$env_file" ]] && { print_err "env не найден: ${env_file}"; return 1; }
    # shellcheck disable=SC1090
    source "$env_file"

    local srv_port="${SERVER_PORT:-}"
    local awg2_ver="${AWG2_VERSION:-1.0}"
    [[ -z "$srv_port" ]] && { print_err "SERVER_PORT не задан в ${env_file}"; return 1; }

    # --> ПРОВЕРКА TCPDUMP <--
    if ! command -v tcpdump &>/dev/null; then
        print_warn "tcpdump не установлен"
        local do_inst=""
        ask_yn "Установить tcpdump?" "y" do_inst
        [[ "$do_inst" != "yes" ]] && { print_info "Отмена"; return 0; }
        apt-get install -y -qq tcpdump 2>/dev/null || { print_err "Не удалось установить tcpdump"; return 1; }
    fi

    # --> ВНЕШНИЙ ИНТЕРФЕЙС <--
    local ext_iface
    ext_iface=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    [[ -z "$ext_iface" ]] && ext_iface="any"

    # --> ОЖИДАЕМЫЕ РАЗМЕРЫ <--
    # - стандартный WG: init=148, resp=92 (UDP payload) -
    # - AWG: +S1 к init, +S2 к resp -
    local exp_init=148 exp_resp=92
    local s1_val="${S1:-0}" s2_val="${S2:-0}"
    local exp_init_pad=$(( exp_init + s1_val ))
    local exp_resp_pad=$(( exp_resp + s2_val ))

    # --> ВЫВОД КОНФИГА <--
    echo ""
    echo -e "  ${bnc}Интерфейс:${nc}      ${bcy}${iface}${nc}"
    echo -e "  ${bnc}Порт:${nc}           ${bcy}${srv_port}/udp${nc}"
    echo -e "  ${bnc}Версия AWG:${nc}     ${bcy}${awg2_ver}${nc}"
    echo -e "  ${bnc}Внешний iface:${nc}  ${bcy}${ext_iface}${nc}"
    echo ""
    echo -e "  ${bnc}Ожидаемые параметры обфускации:${nc}"
    echo -e "    Jc=${JC:-?}  Jmin=${JMIN:-?}  Jmax=${JMAX:-?}"
    echo -e "    S1=${S1:-?}  S2=${S2:-?}"
    [[ -n "${S3:-}" ]] && echo -e "    S3=${S3}  S4=${S4:-?}"
    echo -e "    H1=${H1:-?}  H2=${H2:-?}  H3=${H3:-?}  H4=${H4:-?}"
    [[ -n "${I1:-}" ]] && echo -e "    I1=${I1:0:60}..."
    echo ""
    echo -e "  ${bnc}Ожидаемые размеры пакетов (UDP payload):${nc}"
    echo -e "    Vanilla WG:          init=${exp_init}, resp=${exp_resp}"
    echo -e "    AWG S1/S2 padding:   init=${exp_init_pad}, resp=${exp_resp_pad}"
    [[ "${JC:-0}" != "0" ]] && echo -e "    Junk (Jc=${JC}):     ${JMIN:-?}..${JMAX:-?} байт ДО handshake"
    echo ""

    # --> ВЫБОР ДЛИТЕЛЬНОСТИ <--
    local duration=60
    echo -e "  ${bnc}Длительность захвата:${nc}"
    echo -e "    ${bgrn}1)${nc} 30 секунд"
    echo -e "    ${bgrn}2)${nc} 60 секунд (по умолчанию)"
    echo -e "    ${bgrn}3)${nc} 120 секунд"
    echo ""
    local dsel=""
    ask "Выбор [1/2/3]" "2" dsel
    case "$dsel" in
        1) duration=30 ;;
        3) duration=120 ;;
        *) duration=60 ;;
    esac

    # --> ИНСТРУКЦИЯ ПОЛЬЗОВАТЕЛЮ <--
    echo ""
    print_info "Инструкция:"
    echo -e "    1) На клиенте (Keenetic/Amnezia/etc) ${bnc}ОТКЛЮЧИ${nc} VPN"
    echo -e "    2) Подожди 3-5 секунд"
    echo -e "    3) ${bnc}ВКЛЮЧИ${nc} VPN обратно -> клиент пошлёт handshake"
    echo -e "    4) Жди пока tcpdump завершится (${duration} сек)"
    echo ""
    local go=""
    ask_yn "Начать захват?" "y" go
    [[ "$go" != "yes" ]] && { print_info "Отмена"; return 0; }

    # --> КАПТУРА <--
    local pcap
    pcap=$(mktemp -t "awg2_test_${iface}.XXXXXX.pcap")
    # - гарантированное удаление дампа на выходе из функции -
    # shellcheck disable=SC2064
    trap "rm -f '${pcap}'" RETURN

    echo ""
    print_info "Путь дампа: ${pcap}"
    print_info "(удаляется автоматически после анализа)"
    print_info "Захват ${duration} сек на ${ext_iface}:${srv_port}/udp..."
    timeout "$duration" tcpdump -i "$ext_iface" -nn -U -s 0 \
        "udp port ${srv_port}" -w "$pcap" >/dev/null 2>&1 &
    local tpid=$!

    # - прогресс -
    local i
    for (( i=1; i<=duration; i++ )); do
        printf "\r  Прошло: %ds / %ds" "$i" "$duration"
        sleep 1
    done
    echo ""
    wait "$tpid" 2>/dev/null || true

    # --> АНАЛИЗ <--
    echo ""
    print_section "Анализ дампа"

    if [[ ! -s "$pcap" ]]; then
        print_err "Дамп пустой. Возможные причины:"
        echo -e "    - клиент не пытался подключиться"
        echo -e "    - UFW блокирует ${srv_port}/udp"
        echo -e "    - пакеты идут через другой интерфейс (не ${ext_iface})"
        return 1
    fi

    local pkt_count
    pkt_count=$(tcpdump -nn -r "$pcap" 2>/dev/null | wc -l)
    print_ok "Захвачено пакетов всего: ${pkt_count}"
    [[ "$pkt_count" -eq 0 ]] && { print_err "Пакетов нет, клиент не подключался"; return 1; }

    # - лимит для анализа: handshake + Jc junk + несколько data пакетов -
    # - всё что дальше - это уже трафик пользователя, не влияет на диагностику обфускации -
    local analyze_limit=100
    if [[ "$pkt_count" -gt "$analyze_limit" ]]; then
        print_info "Анализируем первые ${analyze_limit} пакетов (handshake и начало трафика)"
    fi

    # --> РАЗБОР РАЗМЕРОВ <--
    # - собираем длины UDP payload первых N пакетов -
    local -a sizes=()
    mapfile -t sizes < <(tcpdump -nn -r "$pcap" -c "$analyze_limit" 2>/dev/null | grep -oP 'length \K[0-9]+')

    # - раздельная статистика: все размеры + подсчёт -
    declare -A size_count=()
    local sz
    for sz in "${sizes[@]}"; do
        size_count[$sz]=$(( ${size_count[$sz]:-0} + 1 ))
    done

    echo ""
    echo -e "  ${bnc}Распределение размеров пакетов:${nc}"
    # - сортировка по размеру для читаемости -
    local -a sorted_sizes=()
    mapfile -t sorted_sizes < <(printf '%s\n' "${!size_count[@]}" | sort -n)

    local init_found=0 init_padded=0 resp_found=0 resp_padded=0 junk_found=0
    local jmin_v="${JMIN:-0}" jmax_v="${JMAX:-0}" jc_v="${JC:-0}"
    for sz in "${sorted_sizes[@]}"; do
        local cnt="${size_count[$sz]}"
        local marker=""
        if [[ "$sz" == "$exp_init" ]]; then
            marker="  ${byel}<- vanilla WG init (S1 НЕ применилось)${nc}"
            init_found=1
        elif [[ "$sz" == "$exp_resp" ]]; then
            marker="  ${byel}<- vanilla WG response (S2 НЕ применилось)${nc}"
            resp_found=1
        elif [[ "$sz" == "$exp_init_pad" && "$s1_val" -gt 0 ]]; then
            marker="  ${bgrn}<- AWG init с S1=${s1_val} padding (S1 работает)${nc}"
            init_padded=1
        elif [[ "$sz" == "$exp_resp_pad" && "$s2_val" -gt 0 ]]; then
            marker="  ${bgrn}<- AWG response с S2=${s2_val} padding (S2 работает)${nc}"
            resp_padded=1
        elif [[ "$jc_v" != "0" && "$sz" -ge "$jmin_v" && "$sz" -le "$jmax_v" \
             && "$sz" != "$exp_init" && "$sz" != "$exp_resp" \
             && "$sz" != "$exp_init_pad" && "$sz" != "$exp_resp_pad" ]]; then
            marker="  ${bcy}<- вероятно junk (Jc в диапазоне ${jmin_v}..${jmax_v})${nc}"
            junk_found=1
        elif [[ "$sz" -gt "$jmax_v" ]]; then
            marker="  ${nc}<- data-трафик (после handshake)${nc}"
        fi
        printf "    %5d байт  x%-3d%b\n" "$sz" "$cnt" "$marker"
    done

    # --> ПЕРВЫЙ БАЙТ PAYLOAD (H-MANGLE) <--
    # - tcpdump -x выводит hex начиная с IP хедера -
    # - IP хедер 20 байт + UDP хедер 8 байт = 28 байт = offset 0x001c -
    # - в выводе каждая строка: "\t0x0000:  4500 0098 ..." по 16 байт -
    # - offset 28 байт -> во второй строке (0x0010) позиция +12 от начала -
    # - берём payload-hex первых 5 пакетов и смотрим первый байт -
    echo ""
    echo -e "  ${bnc}Первый байт UDP payload (WG type field):${nc}"

    # - dump в виде "packet #N: <все hex без пробелов>" -
    # - ограничиваем 10 пакетами на уровне tcpdump - иначе awk молотит весь pcap -
    local -a pkt_hex=()
    mapfile -t pkt_hex < <(
        tcpdump -nn -r "$pcap" -c 10 -x 2>/dev/null | awk '
            /^[0-9]{2}:[0-9]{2}:[0-9]{2}/ {
                if (buf != "") print buf
                buf = ""
                next
            }
            /^[[:space:]]*0x/ {
                gsub(/^[[:space:]]*0x[0-9a-f]+:[[:space:]]*/, "")
                gsub(/[[:space:]]+/, "")
                buf = buf $0
            }
            END { if (buf != "") print buf }
        '
    )

    local h_mangled=0 h_vanilla=0
    local p idx=0
    for p in "${pkt_hex[@]}"; do
        idx=$(( idx + 1 ))
        [[ $idx -gt 5 ]] && break
        # - payload начинается с offset 56 (28 байт × 2 hex символа) -
        # - первый байт payload = символы 56-57 -
        local fb="${p:56:2}"
        [[ -z "$fb" ]] && continue
        local fb_dec=$(( 16#${fb} ))
        local desc=""
        case "$fb_dec" in
            1) desc="0x01 -> vanilla WG init (H1 mangle НЕ применилось)"; h_vanilla=1 ;;
            2) desc="0x02 -> vanilla WG response (H2 mangle НЕ применилось)"; h_vanilla=1 ;;
            3) desc="0x03 -> vanilla WG cookie (H3 mangle НЕ применилось)"; h_vanilla=1 ;;
            4) desc="0x04 -> vanilla WG data (H4 mangle НЕ применилось)"; h_vanilla=1 ;;
            *) desc="0x${fb} (${fb_dec}) -> обфусцирован (не равен 1-4)"; h_mangled=1 ;;
        esac
        printf "    пакет #%d: %s\n" "$idx" "$desc"
    done

    # --> ПРОВЕРКА I1 СИГНАТУРЫ <--
    local i1_status="none"
    if [[ -n "${I1:-}" ]]; then
        echo ""
        echo -e "  ${bnc}Проверка I1 signature chain:${nc}"
        # - ищем статичные hex-блоки в I1: "<b 0xDEADBEEF>" -
        local -a i1_static=()
        mapfile -t i1_static < <(grep -oP '<b 0x\K[0-9a-fA-F]+' <<< "$I1" 2>/dev/null)

        if [[ ${#i1_static[@]} -eq 0 ]]; then
            echo -e "    ${byel}I1 без статичных байт (<b 0x...>), только random/timestamp${nc}"
            echo -e "    Визуально проверить невозможно. Если handshake прошёл - I1 скорее всего применяется."
            i1_status="dynamic"
        else
            local target="${i1_static[0],,}"
            local probe="${target:0:16}"
            # - поиск probe в первых 5 пакетах через grep (быстрее bash substring на длинных hex) -
            local found=0 pnum=0 p payload_hex
            for p in "${pkt_hex[@]}"; do
                pnum=$(( pnum + 1 ))
                [[ $pnum -gt 5 ]] && break
                payload_hex="${p:56}"
                [[ -z "$payload_hex" ]] && continue
                if grep -qi "$probe" <<< "$payload_hex"; then
                    # - вычисляем offset через awk (без растягивания переменной) -
                    local pos_bytes
                    pos_bytes=$(awk -v h="${payload_hex,,}" -v n="$probe" \
                        'BEGIN { i = index(h, n); if (i > 0) print int((i-1)/2); else print -1 }')
                    print_ok "    I1 найден в пакете #${pnum} на offset ${pos_bytes} байт"
                    echo -e "    Искомый фрагмент: ${target:0:32}..."
                    found=1
                    i1_status="applied"
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                print_warn "    I1 статичный фрагмент НЕ найден в первых 5 пакетах"
                echo -e "    Искомый фрагмент: ${target:0:32}..."
                echo -e "    Возможные причины: клиент не поддерживает I1-I5 или применил их иначе"
                i1_status="missing"
            fi
        fi
    fi

    # --> ИТОГОВЫЙ ВЕРДИКТ <--
    echo ""
    echo -e "  ${bnc}Итог:${nc}"
    # - S1 -
    if [[ "$s1_val" -gt 0 ]]; then
        if [[ $init_padded -eq 1 ]]; then
            print_ok "S1 padding работает (пакет ${exp_init_pad} байт)"
        elif [[ $init_found -eq 1 ]]; then
            print_err "S1 padding НЕ применяется (пакет ${exp_init} байт - vanilla)"
        else
            print_warn "S1: init пакет не видно (клиент не подключился?)"
        fi
    else
        print_info "S1=0 (padding отключён)"
    fi
    # - S2 -
    if [[ "$s2_val" -gt 0 ]]; then
        if [[ $resp_padded -eq 1 ]]; then
            print_ok "S2 padding работает (пакет ${exp_resp_pad} байт)"
        elif [[ $resp_found -eq 1 ]]; then
            print_err "S2 padding НЕ применяется (пакет ${exp_resp} байт - vanilla)"
        else
            print_warn "S2: response пакет не видно"
        fi
    else
        print_info "S2=0 (padding отключён)"
    fi
    # - Jc -
    if [[ "$jc_v" != "0" ]]; then
        if [[ $junk_found -eq 1 ]]; then
            print_ok "Jc junk пакеты присутствуют"
        else
            print_warn "Jc junk пакеты не обнаружены (ожидалось ${jc_v} в диапазоне ${jmin_v}..${jmax_v})"
        fi
    else
        print_info "Jc=0 (junk отключён)"
    fi
    # - H -
    if [[ "$awg2_ver" == "wg" ]]; then
        print_info "H: vanilla WG, mangle не применяется по определению"
    elif [[ $h_mangled -eq 1 && $h_vanilla -eq 0 ]]; then
        print_ok "H1-H4 mangle работает (первые байты не равны 1-4)"
    elif [[ $h_vanilla -eq 1 && $h_mangled -eq 0 ]]; then
        print_err "H1-H4 mangle НЕ применяется (видны vanilla type байты 1-4)"
    elif [[ $h_mangled -eq 1 && $h_vanilla -eq 1 ]]; then
        print_warn "H: смешанная картина (часть пакетов обфусцирована, часть нет)"
    else
        print_warn "H: недостаточно пакетов для анализа"
    fi
    # - I1 -
    case "$i1_status" in
        applied) print_ok "I1 signature chain применён (найден статичный фрагмент)" ;;
        missing) print_err "I1 signature chain НЕ применён" ;;
        dynamic) print_info "I1: только динамические теги, визуальная проверка невозможна" ;;
        none)    [[ "$awg2_ver" != "wg" && "$awg2_ver" != "1.0" ]] && print_warn "I1 не задан, хотя версия ${awg2_ver}" ;;
    esac

    echo ""
    print_info "Дамп был сохранён как ${pcap} и сейчас удаляется"
    return 0
}
