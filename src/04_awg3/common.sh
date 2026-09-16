### Функции подменю AmneziaWG 3:
################################
awg3env_inc="${INCLUDE_DIR}/.awg3-env"
source ${awg3env_inc}
source ${AWG3_DEFAULT_ENV}

CUSTOM_LOGS_DIR=/var/log/awg3
CUSTOM_LOG_FILE=awg3_server.log

client_dir() { printf '%s/%s' "$AWG3_CLIENTS_CONFIGS" "$1"; }
client_keys_dir() { printf '%s/%s/keys' "$AWG3_CLIENTS_CONFIGS" "$1"; }
# Путь к конфигу клиента: новая схема в приоритете, затем старая. Для несуществующего клиента возвращается путь по новой схеме — туда и создаём.
client_conf_path() {
    local name="$1"
    if [[ -f "$AWG3_CLIENTS_CONFIGS/$name/$name.conf" ]]; then
        printf '%s/%s/%s.conf' "$AWG3_CLIENTS_CONFIGS" "$name" "$name"
    elif [[ -f "$AWG3_CLIENTS_CONFIGS/$name.conf" ]]; then
        printf '%s/%s.conf' "$AWG3_CLIENTS_CONFIGS" "$name"
    else
        printf '%s/%s/%s.conf' "$AWG3_CLIENTS_CONFIGS" "$name" "$name"
    fi
}

### Энтропия:
# Значения берутся из /dev/urandom блоками, а не по одному процессу на число.
# Каждый helper присваивает переменную, а не печатает, и вызывающая сторона использует обычное присваивание вместо $( ).
# Это не стилистика: подстановка команд выполняется в подоболочке, поэтому курсор пула сдвигается у потомка и сбрасывается у родителя.
# Сделать иначе — получить одинаковые значения на последовательных выборках, то есть ровно тот отпечаток, ради устранения которого всё и затевалось.
AWG3_RAND_POOL=()
AWG3_RAND_IDX=0
awg3_rand_refill() {
    local raw v
    raw=$(od -An -N4096 -tu4 -v < /dev/urandom | tr -s ' ' '\n') || $(log_error "Не читается /dev/urandom"; return 1)
    AWG3_RAND_POOL=()
    for v in $raw; do
        AWG3_RAND_POOL+=("$v")
    done
    AWG3_RAND_IDX=0
    [[ "${#AWG3_RAND_POOL[@]}" -gt 0 ]] || $(log_error "Пустой пул энтропии!"; return 1)
}

# awg3_rand_u32 -> AWG3_REPLY: одно равномерное 32-битное значение.
awg3_rand_u32() {
    if [[ "$AWG3_RAND_IDX" -ge "${#AWG3_RAND_POOL[@]}" ]]; then
        awg3_rand_refill
    fi
    AWG3_REPLY=${AWG3_RAND_POOL[$AWG3_RAND_IDX]}
    AWG3_RAND_IDX=$((AWG3_RAND_IDX + 1))
}

# awg3_rand_int LO HI -> AWG3_REPLY: равномерное целое в [LO, HI].
# Rejection sampling, иначе остаток от деления перекашивает низ диапазона.
awg3_rand_int() {
    local lo=$1 hi=$2 span limit
    span=$((hi - lo + 1))
    [[ "$span" -gt 0 ]] || { log_error "awg3_rand_int: Пустой диапазон ${lo}..${hi}"; return 1; }
    limit=$(( (4294967296 / span) * span - 1 ))
    while :; do
        awg3_rand_u32 || return 1
        if [[ "$AWG3_REPLY" -le "$limit" ]]; then
            AWG3_REPLY=$(( lo + AWG3_REPLY % span ))
            return
        fi
    done
}

# awg3_rand_hex N -> AWG3_RAND_HEX: N случайных байт в нижнем регистре hex.
AWG3_RAND_HEX=""
awg3_rand_hex() {
    local n=$1 i byte
    AWG3_RAND_HEX=""
    for (( i = 0; i < n; i++ )); do
        awg3_rand_int 0 255 || return 1
        printf -v byte '%02x' "$AWG3_REPLY"
        AWG3_RAND_HEX="${AWG3_RAND_HEX}${byte}"
    done
}

# awg3_rand_b64_32 -> AWG3_RAND_B64: 32 случайных байта в base64 — кодировка ключей .conf.
AWG3_RAND_B64=""
awg3_rand_b64_32() {
    local i byte bin=""
    for (( i = 0; i < 32; i++ )); do
        awg3_rand_int 0 255 || return 1
        printf -v byte '\\x%02x' "$AWG3_REPLY"
        bin="${bin}${byte}"
    done
    if command -v base64 >/dev/null 2>&1; then
        AWG3_RAND_B64=$(printf '%b' "$bin" | base64 | tr -d '\n')
    elif command -v openssl >/dev/null 2>&1; then
        AWG3_RAND_B64=$(printf '%b' "$bin" | openssl base64 | tr -d '\n')
    else
        log_error "Для HeaderProtectionKey нужен base64 или openssl!"
        return 1
    fi
}

### Сигнатуры мимикрии:
# Справочник тегов (device/obf.go): <b hex> статические байты, <t> 32-битная
# метка времени, <r N> случайные байты, <rc N> случайные буквы, <rd N> случайные цифры.
AWG3_CHAIN=""
awg3_cps_chain() {
    local profile=$1 iv=$2 a b pad
    case "$profile" in
        quic)
            # QUIC long header: байт типа с установленным fixed bit, версия 1, затем connection ID.
            awg3_rand_hex 8
            awg3_rand_int 8 20; a=$AWG3_REPLY
            AWG3_CHAIN="<b 0xc00000000108${AWG3_RAND_HEX}><rc ${a}><t>"
            ;;
        tls)
            # Заголовок TLS-записи вокруг байта handshake'а ClientHello.
            awg3_rand_hex 2
            awg3_rand_int 24 48; a=$AWG3_REPLY
            AWG3_CHAIN="<b 0x160303${AWG3_RAND_HEX}01><r ${a}><t>"
            ;;
        dtls)
            # DTLS 1.2 handshake record.
            awg3_rand_hex 6
            awg3_rand_int 20 40; a=$AWG3_REPLY
            AWG3_CHAIN="<b 0x16fefd${AWG3_RAND_HEX}><r ${a}><t>"
            ;;
        sip)
            # Печатаемая преамбула: "OPTIONS sip:" в ASCII.
            awg3_rand_int 10 18; a=$AWG3_REPLY
            awg3_rand_int 4 8;   b=$AWG3_REPLY
            AWG3_CHAIN="<b 0x4f5054494f4e53207369703a><rc ${a}><rd ${b}><t>"
            ;;
        dns)
            # Заголовок DNS-запроса: transaction id, флаги обычного запроса, QDCOUNT=1 и обнулённые остальные счётчики.
            awg3_rand_hex 2
            awg3_rand_int 6 14; a=$AWG3_REPLY
            awg3_rand_int 2 4;  b=$AWG3_REPLY
            AWG3_CHAIN="<b 0x${AWG3_RAND_HEX}01000001000000000000><rc ${a}><rd ${b}>"
            ;;
        noise)
            awg3_rand_int 40 90; a=$AWG3_REPLY
            AWG3_CHAIN="<r ${a}><t>"
            ;;
        *)
            log_error "Неизвестный профиль: ${profile}!"
            ;;
    esac
    awg3_rand_int $((20 * iv)) $((60 * iv)); pad=$AWG3_REPLY
    if [[ "$pad" -gt 1000 ]]; then pad=1000; fi
    AWG3_CHAIN="${AWG3_CHAIN}<r ${pad}>"
}

# awg3_entropy_chain IV -> AWG3_CHAIN: наполнитель для I2..I5.
awg3_entropy_chain() {
    local iv=$1 a b c hexlen
    awg3_rand_int 6 16;  a=$AWG3_REPLY
    awg3_rand_int 3 10;  hexlen=$AWG3_REPLY
    awg3_rand_hex "$hexlen"
    awg3_rand_int 20 $((60 * iv)); b=$AWG3_REPLY
    awg3_rand_int 3 8;   c=$AWG3_REPLY
    AWG3_CHAIN="<rc ${a}><b 0x${AWG3_RAND_HEX}><t><r ${b}><rd ${c}>"
}

awg3_intensity_value() {
    case "$AWG3_INTENSITY" in
        low)    IV=1 ;;
        medium) IV=2 ;;
        high)   IV=3 ;;
    esac
}

### Генерация параметров:
# awg3_gen_sender_params: то, что каждое устройство вправе иметь своё. Заполняет G_Jc G_Jmin G_Jmax G_I1..G_I5 G_CPA G_RA G_RT G_RJ G_KA G_MHA.
awg3_gen_sender_params() {
    local IV jc jmin jmax
    awg3_intensity_value
    case "$AWG3_INTENSITY" in
        low)    awg3_rand_int 64 256;  jmin=$AWG3_REPLY; awg3_rand_int 256 512;  jmax=$AWG3_REPLY ;;
        medium) awg3_rand_int 128 512; jmin=$AWG3_REPLY; awg3_rand_int 512 1024; jmax=$AWG3_REPLY ;;
        high)   awg3_rand_int 256 768; jmin=$AWG3_REPLY; awg3_rand_int 768 1280; jmax=$AWG3_REPLY ;;
    esac
    # Между границами нужен реальный разброс, иначе «случайная» длина таковой не является.
    if [[ "$jmax" -le $((jmin + 64)) ]]; then
        awg3_rand_int 64 256
        jmax=$((jmin + 64 + AWG3_REPLY))
    fi
    if [[ "$AWG3_ROUTER_MODE" -eq 1 ]]; then
        awg3_rand_int 2 3; jc=$AWG3_REPLY
        if [[ "$jmin" -gt 40 ]];  then jmin=40; fi
        if [[ "$jmax" -gt 128 ]]; then jmax=128; fi
    else
        awg3_rand_int 3 7; jc=$AWG3_REPLY
    fi
    G_Jc=$jc; G_Jmin=$jmin; G_Jmax=$jmax
    awg3_cps_chain "$AWG3_PROFILE" "$IV"; G_I1="$AWG3_CHAIN"
    if [[ "$AWG3_ROUTER_MODE" -eq 1 ]]; then
        G_I2=""; G_I3=""; G_I4=""; G_I5=""
    else
        awg3_entropy_chain "$IV"; G_I2="$AWG3_CHAIN"
        awg3_entropy_chain "$IV"; G_I3="$AWG3_CHAIN"
        awg3_entropy_chain "$IV"; G_I4="$AWG3_CHAIN"
        awg3_entropy_chain "$IV"; G_I5="$AWG3_CHAIN"
    fi
    local cpa_lo cpa_hi
    if [[ "$AWG3_ROUTER_MODE" -eq 1 ]]; then
        awg3_rand_int 4 16;  cpa_lo=$AWG3_REPLY
        awg3_rand_int 8 24;  cpa_hi=$((cpa_lo + AWG3_REPLY))
    else
        awg3_rand_int 16 64;  cpa_lo=$AWG3_REPLY
        awg3_rand_int 16 120; cpa_hi=$((cpa_lo + AWG3_REPLY))
    fi
    G_CPA="${cpa_lo}-${cpa_hi}"
    local rt_lo rt_hi ka_lo ka_hi ra_lo ra_hi rj_lo rj_hi at_lo at_hi
    awg3_rand_int 4 6;     rt_lo=$AWG3_REPLY
    awg3_rand_int 1 4;     rt_hi=$((rt_lo + AWG3_REPLY))
    awg3_rand_int 8 14;    ka_lo=$AWG3_REPLY
    awg3_rand_int 2 8;     ka_hi=$((ka_lo + AWG3_REPLY))
    awg3_rand_int 100 120; ra_lo=$AWG3_REPLY
    awg3_rand_int 10 30;   ra_hi=$((ra_lo + AWG3_REPLY))
    # RejectAfterTime обязан перекрывать RekeyAfterTime вместе с окнами keepalive и rekey.
    # Ниже этого принимающая сторона перестаёт обновлять ключи, и сессия умирает по достижении дедлайна.
    rj_lo=$((ra_hi + ka_hi + rt_hi + 15))
    if [[ "$rj_lo" -lt 170 ]]; then rj_lo=170; fi
    awg3_rand_int 10 30;   rj_hi=$((rj_lo + AWG3_REPLY))
    awg3_rand_int 12 18;   at_lo=$AWG3_REPLY
    awg3_rand_int 2 10;    at_hi=$((at_lo + AWG3_REPLY))
    G_RA="${ra_lo}-${ra_hi}"
    G_RT="${rt_lo}-${rt_hi}"
    G_RJ="${rj_lo}-${rj_hi}"
    G_KA="${ka_lo}-${ka_hi}"
    G_MHA="${at_lo}-${at_hi}"
}

#-> awg3_gen_shared_params: то, что обязано совпадать на обоих концах. Заполняет G_S1..G_S4 G_H1..G_H4 G_HPK.
awg3_gen_shared_params() {
    local s1 s2 s3 s4
    local h1_lo h1_hi h2_lo h2_hi h3_lo h3_hi h4_lo h4_hi
    if [[ "$AWG3_ROUTER_MODE" -eq 1 ]]; then
        awg3_rand_int 1 20; s1=$AWG3_REPLY
        awg3_rand_int 1 20; s2=$AWG3_REPLY
    else
        awg3_rand_int 1 150; s1=$AWG3_REPLY
        awg3_rand_int 1 150; s2=$AWG3_REPLY
    fi
    awg3_rand_int 1 64; s3=$AWG3_REPLY
    awg3_rand_int 1 "$AWG3_S4_MAX"; s4=$AWG3_REPLY
    # Защита заголовка в 3.0 берёт nonce из этого padding'а, поэтому он не может быть короче nonce.
    [[ "$s1" -lt "$AWG3_NONCE_SIZE" ]] && s1=$AWG3_NONCE_SIZE
    [[ "$s2" -lt "$AWG3_NONCE_SIZE" ]] && s2=$AWG3_NONCE_SIZE
    [[ "$s3" -lt "$AWG3_NONCE_SIZE" ]] && s3=$AWG3_NONCE_SIZE
    [[ "$s4" -lt "$AWG3_NONCE_SIZE" ]] && s4=$AWG3_NONCE_SIZE
    # len(init) = 148 + S1, len(resp) = 92 + S2. Равные размеры вернули бы отпечаток обратно.
    [[ "$s2" -eq $((s1 + 56)) ]] && s2=$((s2 + 1))
    [[ "$s3" -eq $((s1 + 56)) ]] && s3=$((s3 + 1))
    [[ "$s3" -eq $((s2 + 92)) ]] && s3=$((s3 + 1))
    [[ "$s4" -gt "$AWG3_S4_MAX" ]] && s4=$AWG3_S4_MAX
    # Четыре непересекающиеся зоны, все в стороне от 1-4, которые upstream
    # WireGuard резервирует под свои типы сообщений. Каждая граница берётся
    # отдельно, чтобы диапазоны не повторяли форму друг друга.
    awg3_rand_int 100000000 900000000;   h1_lo=$AWG3_REPLY
    awg3_rand_int 1000 50000;            h1_hi=$((h1_lo + AWG3_REPLY))
    awg3_rand_int 1200000000 2000000000; h2_lo=$AWG3_REPLY
    awg3_rand_int 1000 50000;            h2_hi=$((h2_lo + AWG3_REPLY))
    awg3_rand_int 2400000000 3200000000; h3_lo=$AWG3_REPLY
    awg3_rand_int 1000 50000;            h3_hi=$((h3_lo + AWG3_REPLY))
    awg3_rand_int 3600000000 4000000000; h4_lo=$AWG3_REPLY
    awg3_rand_int 1000 50000;            h4_hi=$((h4_lo + AWG3_REPLY))
    G_S1=$s1; G_S2=$s2; G_S3=$s3; G_S4=$s4
    G_H1="${h1_lo}-${h1_hi}"; G_H2="${h2_lo}-${h2_hi}"
    G_H3="${h3_lo}-${h3_hi}"; G_H4="${h4_lo}-${h4_hi}"
    awg3_rand_b64_32; G_HPK="$AWG3_RAND_B64"
}

### Данные живого интерфейса:
#############################
# `awg show <iface> dump` отдаёт по строке на пира: pubkey \t psk \t endpoint \t allowed-ips \t handshake \t rx \t tx \t keepalive
# Первая строка описывает сам интерфейс и пропускается. Заполняет ассоциативные массивы PK_HS, PK_RX, PK_TX, PK_EP (ключ — pubkey).
declare -A PK_HS PK_RX PK_TX PK_EP
awg3_load_peer_dump() {
    local dump pk psk ep aips hs rx tx ka
    dump=$(awg show "$AWG3_SRV_IFACE" dump 2>/dev/null) || return 1
    [[ -n "$dump" ]] || return 1
    while IFS=$'\t' read -r pk psk ep aips hs rx tx ka; do
        [[ -n "$pk" ]] || continue
        PK_HS["$pk"]="$hs"; PK_RX["$pk"]="$rx"; PK_TX["$pk"]="$tx"; PK_EP["$pk"]="$ep"
    done < <(printf '%s\n' "$dump" | tail -n +2)
}

#-> Имя клиента -> публичный ключ, по маркерам #Name в серверном конфиге.
declare -A NAME_PK
awg3_load_name_to_pk() {
    local line cur=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#Name = "* ]]; then
            cur="${line#\#Name = }"; cur="${cur//[[:space:]]/}"
        elif [[ -n "$cur" && "$line" == "PublicKey = "* ]]; then
            local pk="${line#PublicKey = }"; pk="${pk//[[:space:]]/}"
            if [[ -n "$pk" ]]; then NAME_PK["$cur"]="$pk"; fi
            cur=""
        fi
    done < "$AWG3_SYSCONF"
}

# Человекочитаемый статус по времени последнего рукопожатия.
awg3_peer_status() {
    local hs="${1:-0}" now diff
    if ! [[ "$hs" =~ ^[0-9]+$ ]] || [[ "$hs" -eq 0 ]]; then
        printf 'нет связи'; return 0
    fi
    now=$(date +%s); diff=$((now - hs))
    if   [[ "$diff" -lt 180 ]];   then printf 'активен'
    elif [[ "$diff" -lt 86400 ]]; then printf 'был %dч назад' "$((diff / 3600))"
    else printf 'был %dд назад' "$((diff / 86400))"
    fi
}

awg3_format_bytes() {
    local b="${1:-0}"
    if ! [[ "$b" =~ ^[0-9]+$ ]]; then printf '0 B'; return; fi
    if   [[ "$b" -ge 1073741824 ]]; then awk "BEGIN{printf \"%.2f GiB\", $b/1073741824}"
    elif [[ "$b" -ge 1048576 ]];    then awk "BEGIN{printf \"%.2f MiB\", $b/1048576}"
    elif [[ "$b" -ge 1024 ]];       then awk "BEGIN{printf \"%.1f KiB\", $b/1024}"
    else printf '%d B' "$b"
    fi
}

#-> Команды: show, restart:
awg3_show() { awg show "$AWG3_SRV_IFACE" || log_warn "Интерфейс $AWG3_SRV_IFACE не поднят."; }

#awg3_restart() {
#    log "Перезапуск awg-quick@${AWG3_SRV_IFACE}..."
#    if systemctl restart "awg-quick@${AWG3_SRV_IFACE}"; then
#        log_ok "Сервис перезапущен."
#    else
#        log_warn "Перезапуск не удался, смотрите: systemctl status awg-quick@${AWG3_SRV_IFACE}."
#    fi
#    systemctl is-active "awg-quick@${AWG3_SRV_IFACE}"
#}

### Команда: backup:
####################
# Архив кладётся в ~/awg/backups и содержит серверный конфиг, каталоги клиентов и ключи сервера.
# Старые архивы НЕ удаляются сами: чистка — только явным --prune N, и с подтверждением.
awg3_backup() {
    local bdir="$AWG3_BACKUPS_DIR"
    mkdir -p "$bdir" || { failure_box log_error "Не создан ${bdir}!"; return 1; }
    chmod 700 "$bdir"; _fix_owner "$bdir"
    # Миллисекунды в имени: два бэкапа в одну секунду (backup сразу после remove, например) иначе молча затирают друг друга.
    local ts archive
    ts=$(date '+%Y%m%d-%H%M%S.%3N')
    archive="$bdir/awg_backup_${ts}.tar.gz"
    local staging
    staging=$(mktemp -d "${bdir}/.stage.XXXXXX") || { failure_box log_error "mktemp не сработал."; return 1; }
    mkdir -p "$staging/server" "$staging/clients"
    if [[ -f "$AWG3_SYSCONF" ]]; then cp -a "$AWG3_SYSCONF" "$staging/server/"; fi
    if [[ -f "$AWG3_DEFAULT_ENV" ]]; then cp -a "$AWG3_DEFAULT_ENV" "$staging/server/"; fi
    local f
    for f in "$AWG3_SERVER_KEYS/server_private.key" "$AWG3_SERVER_KEYS/server_public.key"; do
        if [[ -f "$f" ]]; then cp -a "$f" "$staging/server/"; fi
    done
    local name cdir count=0
    while IFS= read -r name; do
        cdir=$(client_dir "$name")
        if [[ -d "$cdir" ]]; then
            cp -a "$cdir" "$staging/clients/"
        else
            mkdir -p "$staging/clients/$name"
            cp -a "$AWG3_CLIENTS_CONFIGS/${name}.conf" "$staging/clients/$name/" 2>/dev/null || true
            cp -a "$AWG3_LEGACY_KEYS/${name}."* "$staging/clients/$name/" 2>/dev/null || true
        fi
        count=$((count + 1))
    done < <(awg3_list_client_names)
    if ! tar -czf "$archive" -C "$staging" server clients; then
        rm -rf "$staging"
        failure_box log_error "Не создан архив ${archive}."
    fi
    rm -rf "$staging"
    chmod 600 "$archive"; _fix_owner "$archive"
    log_ok "Бэкап создан: ${archive}."
    log "Клиентов в архиве: $count, размер: $(du -h "$archive" | cut -f1)."
    local total
    total=$(find "$bdir" -maxdepth 1 -name 'awg_backup_*.tar.gz' | wc -l)
    log "Всего архивов: ${total}."
    if [[ -n "$AWG3_PRUNE_KEEP" ]]; then
        local old=()
        mapfile -t old < <(find "$bdir" -maxdepth 1 -name 'awg_backup_*.tar.gz' | sort -r | tail -n +$((AWG3_PRUNE_KEEP + 1)))
        if [[ "${#old[@]}" -eq 0 ]]; then
            log "Удалять нечего, архивов не больше ${AWG3_PRUNE_KEEP}."
            return 0
        fi
        log "Будут удалены старые архивы:"
        printf '   %s\n' "${old[@]}"
        ask_confirm "Удалить?" || return 1
        rm -f "${old[@]}"
        success_box log_ok "Удалено архивов: ${#old[@]}."
    fi
}

### PostUp / PostDown:
# Правила перенесены из awg3_render_server_config апстрима (bivlked v5.23.0) без изменения семантики. %i раскрывается awg-quick в имя интерфейса.
# TCPMSS-clamping обязателен: путь до клиента уже съеден заголовками туннеля и без правки MSS TCP-сессии зависают на больших пакетах там,
# где PMTUD упирается в чёрную дыру — та самая жалоба «ping идёт, а сайт не грузится».
#-> awg3_build_postup NIC MTU ISOLATION IPV6   (ISOLATION/IPV6: on|off):
awg3_build_postup() {
    local nic="$1" mtu="$2" isolation="$3" ipv6="$4"
    local mss4=$(( mtu - 40 )) mss6=$(( mtu - 60 ))
    local r
    r="iptables -I FORWARD -i %i -j ACCEPT"
    r="${r}; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
    r="${r}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    r="${r}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    if [[ "$isolation" == "on" ]]; then
        # Цикл, а не одиночное -D: прерванный прошлый запуск мог оставить несколько одинаковых правил, снять нужно все.
        r="${r}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done"
        r="${r}; iptables -I FORWARD -i %i -o %i -j DROP"
    fi

    if [[ "$ipv6" == "on" ]]; then
        r="${r}; ip6tables -I FORWARD -i %i -j ACCEPT"
        r="${r}; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        r="${r}; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        r="${r}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        if [[ "$isolation" == "on" ]]; then
            r="${r}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done"
            r="${r}; ip6tables -I FORWARD -i %i -o %i -j DROP"
        fi
    fi

    printf '%s' "$r"
}

#-> awg3_build_postdown NIC MTU ISOLATION IPV6 — зеркало awg3_build_postup.
# DROP снимается с `|| true`: интерфейс может опускаться после того, как правило уже убрали вручную, и падать на этом PostDown не должен.
awg3_build_postdown() {
    local nic="$1" mtu="$2" isolation="$3" ipv6="$4"
    local mss4=$(( mtu - 40 )) mss6=$(( mtu - 60 ))
    local r
    r="iptables -D FORWARD -i %i -j ACCEPT"
    r="${r}; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    r="${r}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    r="${r}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    if [[ "$isolation" == "on" ]]; then
        r="${r}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi
    if [[ "$ipv6" == "on" ]]; then
        r="${r}; ip6tables -D FORWARD -i %i -j ACCEPT"
        r="${r}; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
        r="${r}; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        r="${r}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        if [[ "$isolation" == "on" ]]; then
            r="${r}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
    fi
    printf '%s' "$r"
}


### Далее — функции установки и проверки зависимостей, вызываются при установке и обновлении.
#-> missing_tools -> список отсутствующих команд через пробел.
awg3_missing_tools() {
    local tool missing=()
    for tool in "$@"; do
         command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    printf '%s' "${missing[*]:-}"
}

awg3_check_dnf_updates() {
    ask_confirm "Проверить обновления?" "y" || return 1
    dnf check-update -y > /dev/null 2>&1 || true
}

#-> Догоняет недостающие утилиты. Вызывается и при установке, и при обновлении:
# на свежем сервере `--update` раньше падал на отсутствующем make уже после скачивания Go, оставляя половину установки.
awg3_ensure_tools() {
    if [[ "$os_type" == "rhel" ]]; then
        log "Проверка утилит ${AWG3_REQUIRED_TOLLS[@]}..."
        awg3_check_deps "${AWG3_REQUIRED_TOOLS[@]}" > /dev/null 2>&1 && log_ok "Все утилиты установлены." || log_error "Ошибка установки утилит!"
    else
        local missing
        missing="$(awg3_missing_tools "${AWG3_REQUIRED_TOOLS[@]}")"
        if [[ -z "$missing" ]]; then
            return 0
        fi
        log_warn "не хватает утилит: ${missing}"
        if ! command -v apt-get >/dev/null 2>&1; then
            log_error "apt-get недоступен — поставь вручную: ${missing}!"
        fi
        awg3_install_deps
        missing="$(awg3_missing_tools "${AWG3_REQUIRED_TOOLS[@]}")"
        if [[ -n "$missing" ]]; then
            log_error "После установки пакетов всё ещё нет: ${missing}!"
        fi
        log_ok "Недостающие утилиты доставлены."
    fi
}

#-> Функция проверки зависимостей от vados-dev в стиле dnf:
awg3_check_deps() {
    local packages=("$@")
    local to_install=()
    local deps_pkg
    log "Список: ${packages[*]}"
    for deps_pkg in "${packages[@]}"; do
        if ! dnf list installed "$deps_pkg" 2>/dev/null | grep -q "Installed Packages"; then
             to_install+=("$deps_pkg")
        fi
    done
        if [ ${#to_install[@]} -eq 0 ]; then
            log_ok "Все зависимости установлены."
            return 0
        else
            log "Установка: ${to_install[*]}..."
            dnf install -y ${to_install[*]} > /dev/null 2>&1 && log_ok "Зависимости установлены." || return 1
        fi
}

awg3_install_deps() {
    if [[ "$os_type" == "rhel" ]]; then
        local deps=()
        deps=(git make curl python3 python3-pip)
        step "Проверка зависимостей: ${deps[@]}..."
        awg3_check_dnf_updates
        awg3_check_deps "${deps[@]}" > /dev/null 2>&1 && ok "Зависимости установлены" || return 1
    else
        step "Зависимости"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # --no-install-recommends: иначе python3-pip тянет build-essential, gcc, g++, binutils, python3-dev — семьдесят пакетов вместо десяти.
        # У cryptography на amd64/arm64 есть готовые wheel, компилятор ей не нужен.
        apt-get install -y -qq --no-install-recommends \
        make curl ca-certificates iproute2 iptables python3 python3-venv python3-pip golang-go
        log_ok "базовые пакеты (включая golang-go из репозитория)"
    fi
}
