#!/usr/bin/env bash
#########################
### Заголовок скрипта ###
#-> AWG Multi Tools: предстартовые проверки:
############################################
#-> Проверка bash:
##################
if [ -z "$BASH_VERSION" ]; then echo "Запустите через bash: bash $0!" >&2; exit 1; fi

#PS4 для красивой трассировки (в начале скрипта):
#export PS4='+ ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:-main}() '
#Теперь set -x покажет файл, номер строки и имя функции — почти как нормальный отладчик.
#set -x

# -E нужен, чтобы ERR-ловушка отката работала и внутри функций.
#set -Eeuo pipefail
#set -euo pipefail
set -o pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PROJ_ROOT_DIR=${SELF%/*}
#<::PROJ_WORK_DIR::>
PROJ_NAME=${PROJ_WORK_DIR##*/}
INCLUDE_DIR="${PROJ_WORK_DIR}/include"
env_inc="${INCLUDE_DIR}/.${PROJ_NAME}-env"
me_ext=$(basename "$0")
me="${me_ext%.*}"

#-> Подключаем инклюды:
#######################
source $env_inc
source $colors_inc
source $output_inc
source $input_inc
source $functions_inc
source $firewall_inc

#-> Проверка root:
##################
[[ "$EUID" -ne 0 ]] > /dev/null 2>&1 && die "Запустите от root: sudo bash $0!"

_confirm() {
    local answer
    read -r -p "$(cecho sW "    $1 [y/N]: ")" answer
    [[ "$answer" =~ ^[Yy]$ ]] || return 1
}

exec 200>"$PROJ_LOCK_FILE"
if ! flock -n 200; then
    log_error "Скрипт уже запущен (lock: ${PROJ_LOCK_FILE})!"
    _confirm "Хотите удалить его и продолжить?" && rm ${PROJ_LOCK_FILE} || die "${PROJ_LOCK_FILE} не удалён, выход."
fi

#-> Стартовые проверки:
check_root
check_virt
validate_os_ver
