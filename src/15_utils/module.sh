### Функции подменю "Оптимизация":
##################################
#-> Настройка sysctl (расширенная):
awg_optimize_sysctl_buffers() {
    log "Настройка Адаптивных буферов sysctl..."
    ![ -d ${AWG_OPTIMIZE_SYSCTL_DIR} ] 2>/dev/null || mkdir -p ${AWG_OPTIMIZE_SYSCTL_DIR}
    local f="${AWG_OPTIMIZE_SYSCTL_DIR}/80-amneziawg-buffers.conf"
    # Адаптивные буферы по объёму RAM
    local rmem_max wmem_max netdev_backlog
    if [[ ${TOTAL_RAM_MB:-1024} -ge 2048 ]]; then
        rmem_max=16777216    # 16MB
        wmem_max=16777216
        netdev_backlog=5000
    else
        rmem_max=4194304     # 4MB
        wmem_max=4194304
        netdev_backlog=2500
    fi
    cat > "$f" << EOF
#-> Network Buffers (adaptive):
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${netdev_backlog}
EOF
    if [[ "$AWG_OPTIMIZE_SYSCTL_DIR" == "/etc/sysctl.d" ]]; then
        log "Применение sysctl..."
        if ! sysctl -p "$f" >/dev/null 2>&1; then
            log_warn "Некоторые параметры sysctl не применились."
            sysctl -p "$f" 2>/dev/null || true
        fi
    else
        log "Параметры были записаны в файл $f."
        log "Его можно скопировать в /etc/sysctl.d и применить командой sysctl -p /etc/sysctl.d/80-amneziawg-buffers.conf."
    fi
}

awg_optimize_sysctl_ip_tcpip() {
    log "Настройка sysctl IP Forwarding и TCP/IP Hardening..."
    ![ -d ${AWG_OPTIMIZE_SYSCTL_DIR} ] 2>/dev/null || mkdir -p ${AWG_OPTIMIZE_SYSCTL_DIR}
    local f="${AWG_OPTIMIZE_SYSCTL_DIR}/85-amneziawg-IP-tcpIP.conf"
    cat > "$f" << EOF
#-> IP Forwarding:
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 не отключен"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)
#-> TCP/IP Hardening:
# rp_filter = 2 (loose mode): 
# проверяет source IP по ANY маршруту в таблице, а не по обратному маршруту через тот же интерфейс.
# Strict mode (=1) ломает routing на облачных хостерах (Hetzner и подобных) где шлюз в другой подсети,
# чем IP самой VPS — ответные пакеты не проходят strict reverse path check.
# Loose mode безопасен: подделанные source IP всё равно отсеиваются если для них нет маршрута вообще. Discussion #41 (z036).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_rfc1337 = 1

#-> Redirects:
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [[ "${DISABLE_IPV6:-1}" -ne 1 ]]; then
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
fi)
EOF
    if [[ "$AWG_OPTIMIZE_SYSCTL_DIR" == "/etc/sysctl.d" ]]; then
        log "Применение sysctl..."
        if ! sysctl -p "$f" >/dev/null 2>&1; then
            log_warn "Некоторые параметры sysctl не применились."
            sysctl -p "$f" 2>/dev/null || true
        fi
    else
        log "Параметры были записаны в файл $f."
        log "Его можно скопировать в /etc/sysctl.d и применить командой sysctl -p /etc/sysctl.d/85-amneziawg-IP-tcpIP.conf."
    fi
}

awg_optimize_sysctl_ip_tcp() {
    log "Настройка sysctl BBR, Conntrack и Security..."
    ![ -d ${AWG_OPTIMIZE_SYSCTL_DIR} ] 2>/dev/null || mkdir -p ${AWG_OPTIMIZE_SYSCTL_DIR}
    local f="${AWG_OPTIMIZE_SYSCTL_DIR}/88-amneziawg-security.conf"
    cat > "$f" << EOF
#-> BBR Congestion Control:
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

#-> Conntrack:
net.netfilter.nf_conntrack_max = 65536

#-> Security:
vm.swappiness = 10
kernel.sysrq = 0
EOF
    if [[ "$AWG_OPTIMIZE_SYSCTL_DIR" == "/etc/sysctl.d" ]]; then
        log "Применение sysctl..."
        if ! sysctl -p "$f" >/dev/null 2>&1; then
            log_warn "Некоторые параметры sysctl не применились (nf_conntrack будет доступен позже)."
            sysctl -p "$f" 2>/dev/null || true
        fi
    else
        log "Параметры были записаны в файл $f."
        log "Его можно скопировать в /etc/sysctl.d и применить командой sysctl -p /etc/sysctl.d/88-amneziawg-security.conf."
    fi
}

awg_optimize_sysctl_kernel_printk() {
    log "Настройка sysctl - Подавление kernel warning/notice messages в VNC-консоли хостера..."
    ![ -d ${AWG_OPTIMIZE_SYSCTL_DIR} ] 2>/dev/null || mkdir -p ${AWG_OPTIMIZE_SYSCTL_DIR}
    local f="${AWG_OPTIMIZE_SYSCTL_DIR}/91-amneziawg-kernel_printk.conf"
    cat > "$f" << EOF
#-> Подавление kernel warning/notice messages в VNC-консоли хостера:
# Без этого fail2ban блокировки спамят VNC окно строками типа "[BLOCK]" и делают консоль непригодной для работы.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Значение 3 = KERN_ERR — на консоль идут только ошибки и критические (Discussion #41 (z036)).
kernel.printk = 3 4 1 3
EOF
    if [[ "$AWG_OPTIMIZE_SYSCTL_DIR" == "/etc/sysctl.d" ]]; then
        log "Применение sysctl..."
        if ! sysctl -p "$f" >/dev/null 2>&1; then
            log_warn "Некоторые параметры sysctl не применились."
            sysctl -p "$f" 2>/dev/null || true
        fi
    else
        log "Параметры были записаны в файл $f."
        log "Его можно скопировать в /etc/sysctl.d и применить командой sysctl -p /etc/sysctl.d/91-amneziawg-kernel_printk.conf."
    fi
}


optimize_swap() {
    log "Optimizing swap..."
    local target_swap_mb
    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi
    # Check current swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')
    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap is already sufficient: ${current_swap_mb}MB (target: ${target_swap_mb}MB)"
    else
        log "Creating swap file: ${target_swap_mb}MB"
        # Disable existing swap file if present
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Error creating swap file"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap error"; return 1; }
        swapon /swapfile || { log_warn "swapon error"; return 1; }
        # Add to fstab if missing. Precise field match: ignore commented
        # lines and partial matches (e.g. `/swapfile.bak` or an old entry
        # left in a comment).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap file created: ${target_swap_mb}MB"
    fi
    # Setting swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

awg_optimize_nic() {
    log "Оптимизация сетевого интерфейса"
    if [[ -z "$ifext" ]]; then
        log_error "Основной NIC не определён, пропуск оптимизации."
        return 1
    fi
    if ! command -v ethtool &>/dev/null; then
        log_warn "ethtool не найден, пропуск NIC оптимизации."
        return 0
    fi
    log "Оптимизация NIC: $ifext"
    log "Отключение GRO/GSO/TSO — могут мешать VPN-трафику"
    ethtool -K $ifext gro off 2>/dev/null || log_warn "GRO: не поддерживается/уже выкл."
    ethtool -K $ifext gso off 2>/dev/null || log_warn "GSO: не поддерживается/уже выкл."
    ethtool -K $ifext tso off 2>/dev/null || log_warn "TSO: не поддерживается/уже выкл."
    log "NIC оптимизация завершена."
}

### Настройка sysctl (минимальная, для --no-tweaks):
####################################################
awg_optimize_sysctl_minimal() {
    log "Настройка минимального sysctl (--no-tweaks)..."
    ![ -d ${AWG_OPTIMIZE_SYSCTL_DIR} ] 2>/dev/null || mkdir -p ${AWG_OPTIMIZE_SYSCTL_DIR}
    local f="${AWG_OPTIMIZE_SYSCTL_DIR}/51-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
#-> AmneziaWG — минимальные настройки (--no-tweaks):
net.ipv4.ip_forward = 1
SYSEOF
    if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
    else
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.forwarding = 1
SYSEOF
    fi

    if [[ "$AWG_OPTIMIZE_SYSCTL_DIR" == "/etc/sysctl.d" ]]; then
        log "Применение sysctl..."
        if ! sysctl -p "$f" >/dev/null 2>&1; then
            log_warn "Ошибка sysctl -p"
            sysctl -p "$f" 2>/dev/null || true
        fi
    else
        log "Минимальный sysctl настроен."
        log "Параметры были записаны в файл $f."
        log "Его можно скопировать в /etc/sysctl.d и применить командой sysctl -p /etc/sysctl.d/51-amneziawg-forwarding.conf."
    fi
}
