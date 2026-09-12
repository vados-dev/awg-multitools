#-> Функции подменю "Установка":
################################
check_updates() {
    log "Checking for system updates..."
    dnf check-update -y || true
    log "Installing system updates..."
    dnf update -y || true
}

install_deps() {
#    dnf update -y || true
    dnf check-update || true
    dnf config-manager --enable crb || true
    dnf install -y epel-release || true
    dnf clean all || true
    dnf makecache || true
    dnf install -y dkms || die "DKMS не установлен!"
}
remove_deps() {
    echo "dkms"
    dnf remove -y dkms
}

amf="/etc/modules-load.d/amneziawg.conf"
wmf="/etc/modules-load.d/wireguard.conf"

load_awg_module() {
    if ! lsmod | grep amneziawg > /dev/null 2>&1; then
        log "Модуль amneziawg не загружен, пробую загрузить..."
        modprobe amneziawg 2>/dev/null
        ! lsmod | grep amneziawg > /dev/null 2>&1 && log_error "Не удалось загрузить модуль amneziawg!" || log "Модуль amneziawg загружен."
    else
        log "Модуль amneziawg загружен."
    fi
}

add_awg_to_modules() {
    mkdir -p "$(dirname "$amf")"
    if ! grep -qxF 'amneziawg' "$amf" 2>/dev/null; then
        if echo "amneziawg" > "$amf" 2>/dev/null; then log "Модуль amneziawg добавлен в автозагрузку."; load_awg_module; else log_warn "Ошибка записи $amf!"; return 1; fi
    else
        log "Модуль amneziawg уже есть в автозагрузке."
        load_awg_module
    fi
}

unload_awg_module() {
    modprobe -r amneziawg 2>/dev/null
    lsmod | grep amneziawg > /dev/null 2>&1 || return 0
}

del_awg_from_modules() {
    if ! unload_awg_module > /dev/null 2>&1; then
        log_error "Не удалось выгрузить модуль amneziawg!"
        return 0
    else
        log "Модуль amneziawg выгружен."
        if rm -f $amf 2>/dev/null; then log "Модуль amneziawg удалён из автозагрузки."; else log_error "Ошибка удаления $amf из автозагрузки!"; fi
    fi
}

load_wg_module() {
    if ! lsmod | grep wireguard > /dev/null 2>&1; then
        log "Модуль wireguard не загружен, пробую загрузить..."
        modprobe wireguard 2>/dev/null
        ! lsmod | grep wireguard > /dev/null 2>&1 && log_error "Не удалось загрузить модуль wireguard!" || log "Модуль wireguard загружен."
    else
        log "Модуль wireguard загружен."
    fi
}

add_wg_to_modules() {
    mkdir -p "$(dirname "$wmf")"
    if ! grep -qxF 'wireguard' "$wmf" 2>/dev/null; then
        if echo "wireguard" > "$wmf" 2>/dev/null; then log "Модуль wireguard добавлен в автозагрузку."; load_wg_module; else log_warn "Ошибка записи $wmf!"; return 1; fi
    else
        log "Модуль wireguard уже есть в автозагрузке."
        load_wg_module
    fi
}

unload_wg_module() {
    modprobe -r wireguard 2>/dev/null
    lsmod | grep wireguard > /dev/null 2>&1 || return 0
}

del_wg_from_modules() {
    if ! unload_wg_module > /dev/null 2>&1; then
        log_error "Не удалось выгрузить модуль wireguard!"
        return 0
    else
        log "Модуль wireguard выгружен."
        if rm -f $wmf 2>/dev/null; then log "Модуль wireguard удалён из автозагрузки."; else log_error "Ошибка удаления $wmf из автозагрузки!"; fi
    fi
}

mod_awg_install() {
    if ! dnf list installed "dkms" 2>/dev/null | grep -q "Installed Packages"; then
        install_deps
    fi
    TMP_DIR=$(mktemp -d -t install_nm_awg-XXXXXX)
    chmod 0700 "$TMP_DIR"
    git clone -b ${AWG_MODULE_GIT_BRANCH} "${AWG_MODULE_GIT_URL}" "${TMP_DIR}" 2>/dev/null; cd "${TMP_DIR}/src" 2>/dev/null && log "Репозиотрий клонирован." || log_error "Ошибка клона репозитория!"
# local gitUrl="$1" #    rm -rf ./setup #    git clone ${gitUrl} ${AWG_MODULE_SETUP_DIR} # cd ${AWG_MODULE_SETUP_DIR}/src && \
    make dkms-install > /dev/null 2>&1 && log "\"sudo make dkms-install\" выполнено успешно." || log_error "Ошибка выполнения \"sudo make dkms-install\"!"
    dkms install "amneziawg/$(make print-version)" > /dev/null 2>&1 && log "Установка модуля ядра amneziawg успешно завершена." || log_error "Ошибка установки модуля ядра amneziawg!"
#    sudo dkms add -m amneziawg -v ${AWG_MODULE_VERSION} #    sudo dkms build -m amneziawg -v ${AWG_MODULE_VERSION} #    sudo dkms install -m amneziawg -v ${AWG_MODULE_VERSION}
    add_awg_to_modules
    rm -rf "$TMP_DIR" > /dev/null 2>&1 && log "Папка ${TMP_DIR} удалена." || log_error "Ошибка удаления ${TMP_DIR}!"
}

mod_awg_remove() {
    dkms remove "amneziawg/$(dkms status | grep amneziawg | awk -F'[/, ]+' '{print $2}' | head -1)" --all
    del_awg_from_modules
    del_wg_from_modules
}

mod_awg_reinstall() {
    if ! dnf list installed "dkms" 2>/dev/null | grep -q "Installed Packages"; then
        install_deps
    fi
    dkms install "amneziawg/$(dkms status | grep amneziawg | awk -F'[/, ]+' '{print $2}' | head -1)" -k $(uname -r)
#    mod_awg_remove
#    mod_awg_install
}

# --> МЕНЮ: Установка модуля ядра amneziawg <--
install_awg_mod() {
    declare mItems=("Установка модуля amneziawg" "Переустановка/обновление модуля amneziawg" "Удаление модуля amneziawg" "Добавить в автозагрузку модуль amneziawg" "Удалить из автозагрузки модуль amneziawg" "Добавить в автозагрузку модуль wireguard" "Удалить из автозагрузки модуль wireguard")
    declare mActions=("mod_awg_install" "mod_awg_reinstall" "mod_awg_remove" "add_awg_to_modules" "del_awg_from_modules" "add_wg_to_modules" "del_wg_from_modules")
    declare mTitle="Установка модуля ядра amneziawg"
    declare mDescr=""
    declare mType="section"
    show_menu
}
