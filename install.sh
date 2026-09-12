#!/usr/bin/env bash

###########
### INSTALL
### Устанавливает систему в окружение
#####################################

#set -o pipefail

### Где находимся:
### имена папок, имя проекта и пр.
##################################
SELF="$(readlink -f "${BASH_SOURCE[0]}")" #export PATH="${SELF%/*}:$PATH"
cur_dir=${SELF%/*}
dir_name=${cur_dir##*/}
# название проекта (берём название папки)
proj_name=${dir_name}
SRC_SECURE_DIR="${cur_dir:-.}/secure"
SRC_DIR="${cur_dir:-.}/src"

### Куда копируем:
##################
HOME_DIR=${HOME:-~}
PROFILE_FILE_NAME=".bash_profile"
BASH_PROFILE_FILE="${HOME_DIR}/${PROFILE_FILE_NAME}"
DST_ROOT="${HOME_DIR:-/root}/.${proj_name}"
DST_SECURE_DIR="${DST_ROOT}/.secure"

### Если папки нет, создаём:
############################
[ -d "$DST_ROOT" ] || [ -L "$DST_ROOT" ] && echo "Папка или симлинк $DST_ROOT уже существует." || echo "Папка $DST_ROOT не существует, создаю..."; mkdir -p $DST_ROOT
[ -d "$DST_SECURE_DIR" ] || [ -L "$DST_SECURE_DIR" ] && echo "Папка или симлинк $DST_SECURE_DIR уже существует." || echo "Папка $DST_SECURE_DIR не существует, создаю..."; mkdir -p $DST_SECURE_DIR
echo "Копирую ${SRC_SECURE_DIR} в $DST_SECURE_DIR..."
cp -r ${SRC_SECURE_DIR}/* ${DST_SECURE_DIR}/ 2>/dev/null || true
find ${SRC_SECURE_DIR} -depth -name '.*' -exec cp -r {} ${DST_SECURE_DIR} \;

echo '' >> $BASH_PROFILE_FILE
echo "# start $proj_name" >> $BASH_PROFILE_FILE
echo "export AWGM_HOME=\"$cur_dir\"" >> $BASH_PROFILE_FILE
echo 'case ":$PATH:" in' >> $BASH_PROFILE_FILE
echo '  *":$AWGM_HOME/bin:"*) ;;' >> $BASH_PROFILE_FILE
echo '  *) export PATH="$AWGM_HOME:$AWGM_HOME/bin:$PATH" ;;' >> $BASH_PROFILE_FILE
echo 'esac' >> $BASH_PROFILE_FILE
echo '' >> $BASH_PROFILE_FILE
echo "export AWGM_ROOT=\"$DST_ROOT\"" >> $BASH_PROFILE_FILE
echo 'case ":$PATH:" in' >> $BASH_PROFILE_FILE
echo '  *":$AWGM_ROOT/bin:"*) ;;' >> $BASH_PROFILE_FILE
echo '  *) export PATH="$AWGM_ROOT:$PATH" ;;' >> $BASH_PROFILE_FILE
echo 'esac' >> $BASH_PROFILE_FILE
echo 'alias awgm="awgm-exec.sh"' >> $BASH_PROFILE_FILE
echo "# end $proj_name" >> $BASH_PROFILE_FILE

exit 0


_ROOT=${HOME_DIR:-"~/.eli"}/.eli
ELI_BIN="${ELI_ROOT}/bin"
cur_dir=$(cd $(dirname "$0") 2>/dev/null && pwd) || SCRIPT_DIR=".";
ENV_FILE=${cur_dir}/.env/.eli/.eli-env

#######################################
### Подключаем переменные окружения ###
#######################################
. $ENV_FILE

##################
### Запускалки ###
##################

show_test() {
echo $SCRIPT_DIR
echo $OUT_FILE
echo $SRC_DIR
echo $BUILD_SCRIPT
#exit 0
}

#ls -la ${cur_dir}/.env/.eli/bin
#cat $ENV_FILE
# || true

eli_install() {
    mkdir -p ${ELI_BIN} || echo "Error $0\n"; exit 1;
    cp -rf ${ENV_FILE} ${ELI_ROOT}/
    cp -rf ${cur_dir}/.env/.eli/bin ${ELI_ROOT}/
    cat ${cur_dir}/.env/.bashrc >> ${HOME_DIR}/.bashrc
     source $HOME/.bashrc
    printf "Поздравляю, набор The-VPS-of-ELi установлен!\nНаберите в терминале \"eli\" для получения помощи с командами.\n"
}

show_help() {
    echo -e "${bld} Управление запуском скрипта${byel} ./install.sh ${bnc}."
    echo -e "┌──────────────────────────────────────────────────────────────────┐"
    echo -e "│          Использование: sudo bash ${bgrn}eli${bnc} [${byel}ОПЦИИ${bnc}]                    │"
    echo -e "├──────────────────────────────────────────────────────────────────┤"
    echo -e "│ ${byel}Опции${bnc}:                                                           │"
    echo -e "│   ${byel}install${bnc}                 - Установить набор                     │"
    echo -e "│   ${byel}test${bnc}                    - Запустить тестовую функцию и выйти   │"
    echo -e "│   ${byel}help${bnc}                    - Показать эту справку и выйти         │"
    echo -e "│   ${byel}без аргументов${bnc}          - Установить набор                     │"
    echo -e "│                                                                  │"
    echo -e "└──────────────────────────────────────────────────────────────────┘${nc}"
    exit "${EXIT_RC:-0}"
}
#######################
### Основная логика ###
#######################
echo -e ${nc}
if [ "$#" -lt 1 ]; then
        eli_install
else
#        if [ "$2" = "-y" ] || [ "$2" = "-Y" ]; then
#                commandConfirmed="true"
#        fi

        if [ "$1" = "install" ]; then
                eli_install
        elif [ "$1" = "help" ]; then
                show_help
        elif [ "$1" = "test" ]; then
                show_test
        fi
fi
printf "%s\n" "$dashes"

echo -e ${nc}
