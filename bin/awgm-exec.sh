#!/usr/bin/env bash

#set -Eeuo pipefail

#-> запускалка по умолчанию:
default_run=run_exec
#-> Альяс этого скрипта если уже установлен и сделан source ~/.bash_profile
#me_alias=$(alias | grep awgm-exec.sh | awk '{print $2}' | cut -d'=' -f1)
me_alias="awgm"

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BIN_DIR=${SELF%/*}
PARENT_DIR="$(dirname "$BIN_DIR")"
#-> название проекта (берём название корневой папки)
PROJ_NAME=${PARENT_DIR##*/}
BUILD_SCRIPT="${PARENT_DIR}/build.sh"
INCLUDE_DIR="${PARENT_DIR}/include"
env_inc="${INCLUDE_DIR}/.${PROJ_NAME}-env"
#-> Имя этого скрипта с расширением:
me_ext=$(basename "$0")
#-> Имя этого скрипта без расширения:
me="${me_ext%.*}"

### Подключаем инклюды:
#######################
source $env_inc
source $colors_inc
source $output_inc

EXEC_SCRIPT="${SELF}"
SRC_ROOT="${PARENT_DIR}"

#--- > Флаг дефолтного запуска сразу после билда.
#FlagRUN=true

##################
### Запускалки ###
##################
show_test() {
echo $OUT_FILE
echo $SRC_DIR
echo $BUILD_SCRIPT
exit 0
}

#parse_cmd(){
#    local _cmd="$1" run_cmd="$2" arg1="$3" arg2="$4"
#    if ! echo "$_cmd" | cut -d'-' -f1 > /dev/null 2>&1; then
#        run_cmd="$_cmd"
#    else
#        run_cmd=$(echo "$_cmd" | cut -d'-' -f1)
#        arg1=$(echo "$_cmd" | cut -d'-' -f2)
#        f3=$(echo "$_cmd" | cut -d'-' -f3)
#        [ -n "$f3" ] 2>/dev/null && arg2="$f3" || true
#    fi
#}

#parse_cmd "exec-build-main" run_cmd arg1 arg2
#echo "$run_cmd $arg1 $arg2"

#exit 0

run_build() { bash ${BUILD_SCRIPT}; }
run_exec() {
#   local run_obj="$1"
   run_build
   bash ${MAIN_SCRIPT}
exit 0
}

_check(){
    if ! flock -n 9; then
        printstr "Скрипт уже запущен (lock: %s)\n" "${PROJ_LOCK_FILE}"
        return 0
    else
        return 1
    fi
}


show_help() {
    echo -e "${bld} Управление запуском скрипта${byel} ${me_alias}${bnc}."
    echo -e "┌─────────────────────────────────────────────────────────────────┐"
    echo -e "│         Использование: sudo bash ${bgrn}${me_alias}${bnc} [${byell}ОПЦИИ${bnc}]                   │"
    echo -e "├─────────────────────────────────────────────────────────────────┤"
    echo -e "│                                                                 │"
    echo -e "│ $(cecho uWs "Опции:")                                                          ${bnc}│"
    echo -e "│  $(cecho sY "build | -b")            $bnc - Собрать скрипт                        │"
    echo -e "│  $(cecho sY "run   | -r")            $bnc - Запустить скрипт                      │"
    echo -e "│  $(cecho sY "test$ | -t")            $bnc - Запустить тестовую функцию и выйти    │"
    echo -e "│  $(cecho sY "help  | -h")            $bnc - Показать эту справку и выйти          │"
    echo -e "│  $(cecho sR "Запуск без аргументов") $bnc - Запустить default_run                 │"
    echo -e "│                                                                 │"
    echo -e "└─────────────────────────────────────────────────────────────────┘${nc}\n"
    exit "${EXIT_RC:-0}"
}

### Основная логика:
####################
echo -e ${nc}
if [ "$#" -lt 1 ]; then
        $default_run
#else
#        if [ "$2" = "-y" ] || [ "$2" = "-Y" ]; then
#                commandConfirmed="true"
#        fi
#
#        if [ "$1" = "build" ]||[ "$1" = "-b" ]; then
#                _build
#            ![[ -z "$FlagRUN" ]] > /dev/null 2>&1 || _exec
#        elif [ "$1" = "start" ]||[ "$1" = "run" ]||[ "$1" = "-s" ]; then
#                    _exec
#        elif [ "$1" = "help" ]||[ "$1" = "-h" ]; then
#                show_help
#        elif [ "$1" = "test" ]||[ "$1" = "-t" ]; then
#                show_test
#        else
#            show_help
#        fi
fi
printf "%s\n" "$dashes"

exit 0

#ALLOWED_ARGS="-b build -r run -br brun -h help -t test"
#ALLOWED_CMDS="run-build run-main run-build-main show_help"

#validate_command() {
#    local cmd_name="$1"
#    shift
#    case " $ALLOWED_CMDS " in
#        *" $cmd_name "*) ;;
#        *) echo "Команды не разрешена"; return 1 ;;
#    esac
#    case "$cmd_name" in
#        run)   validate_find   "$@" ;;
#        grep)   validate_grep   "$@" ;;
#        sed)    validate_sed    "$@" ;;
#        od)     validate_od     "$@" ;;
#        tr)     validate_tr     "$@" ;;
#        mkdir)  validate_mkdir  "$@" ;;
#        rm)     validate_rm     "$@" ;;
#        *)      validate_simple_text "$@" ;;
#    esac
#}

# ----- main -----
#if [ "$#" -eq 0 ]; then
