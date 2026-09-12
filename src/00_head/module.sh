#!/usr/bin/env bash
#########################
### Заголовок скрипта ###
#-> AWG Multi Tools: предстартовые проверки:
############################################
#-> Проверка bash:
##################
if [ -z "$BASH_VERSION" ]; then echo "Запустите через bash: bash $0!" >&2; exit 1; fi

#PS4 для красивой трассировки (в начале скрипта):
export PS4='+ ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:-main}() '
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
source $functions_inc
source $firewall_inc

#-> Проверка root:
##################
[[ "$EUID" -ne 0 ]] > /dev/null 2>&1 && die "Запустите от root: sudo bash $0!"

_confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

exec 200>"$PROJ_LOCK_FILE"
if ! flock -n 200; then
    log_error "Скрипт уже запущен (lock: ${PROJ_LOCK_FILE})!"
        _confirm "    Хотите удалить его и продолжить?" && rm ${PROJ_LOCK_FILE} || die "$PROJ_LOCK_FILE не удалён, выход."
    echo -e ${nc}
fi

#-> Стартовые проверки:
check_root
check_virt
validate_os_ver

### Единые правила ввода:
#-> eli:
#   • Ввод всегда идёт через /dev/tty, а не через текущие stdout/stderr.
#   • Это важно для диагностики: там вывод временно уходит в FIFO/tee.
#   • Не используем read -e с цветным prompt: readline неверно считает ширину ANSI-кодов,
#   • из-за чего Backspace и перерисовка строки дают мусор в терминале.
_tty_reset() { [[ -r /dev/tty ]] && stty sane -ixon -ixoff < /dev/tty 2>/dev/null || true; }

_read_line() {
    local __prompt="$1" __varname="$2" __default="${3:-}"
    local __input="" __ch="" __old_stty="" __esc_tail=""
    if [[ -r /dev/tty && -w /dev/tty ]]; then
        # Если основной вывод сейчас идёт через pipe/FIFO, даём tee допечатать предыдущую строку.
        [[ ! -t 1 || ! -t 2 ]] && sleep 0.05
        printf '%b' "$__prompt" > /dev/tty
        __old_stty=$(stty -g < /dev/tty 2>/dev/null || true)
        stty -echo -icanon min 1 time 0 < /dev/tty 2>/dev/null || true
        while IFS= read -r -s -n 1 __ch < /dev/tty; do
            case "$__ch" in
                ""|$'\r'|$'\n')
                    printf '\n' > /dev/tty
                    break
                    ;;
                $'\177'|$'\b')
                    if [[ -n "$__input" ]]; then
                        __input="${__input%?}"
                        printf '\b \b' > /dev/tty
                    fi
                    ;;
                $'\003')
                    [[ -n "$__old_stty" ]] && stty "$__old_stty" < /dev/tty 2>/dev/null || tty_reset
                    printf '\n' > /dev/tty
                    kill -INT $$
                    return 130
                    ;;
                $'\004')
                    printf '\n' > /dev/tty
                    break
                    ;;
                $'\025')
                    while [[ -n "$__input" ]]; do
                        __input="${__input%?}"
                        printf '\b \b' > /dev/tty
                    done
                    ;;
                $'\033')
                    # Игнор ESC/стрелок, чтобы в меню не попадали escape-последовательности.
                    read -r -s -n 2 -t 0.01 __esc_tail < /dev/tty 2>/dev/null || true
                    ;;
                *)
                    __input+="$__ch"
                    printf '%s' "$__ch" > /dev/tty
                    ;;
            esac
        done
        [[ -n "$__old_stty" ]] && stty "$__old_stty" < /dev/tty 2>/dev/null || _tty_reset
    else
        _tty_reset
        printf '%b' "$__prompt" >&2
        IFS= read -r __input || __input=""
    fi

    [[ -z "$__input" && -n "$__default" ]] && __input="$__default"
    printf -v "$__varname" "%s" "$__input"
}
#    _def_autocomp "$__input" "$__prompt"

_read_choice() {
    _read_line "\n    $(cecho sW "Выбор: ")" "$1"
}

ask() {
    local prompt="$1" default="$2" varname="$3" p
    if [[ -n "$default" ]]; then
        p=$(printf "    $(cecho sW "%s [")$(cecho sY "%s")$(cecho sW "]: ")" "$prompt" "$default")
    else
        p=$(printf "    $(cecho sW "%s: ")" "$prompt")
    fi
    _read_line "$p" "$varname" "$default"
}

ask_yn() {
    local prompt="$1" default="$2" varname="$3" value="" p
    while true; do
        if [[ "$default" == "y" ]]; then
            p=$(printf "    $(cecho sW "%s [Y/n]: ")" "$prompt")
        else
            p=$(printf "    $(cecho sW "%s [y/N]: ")" "$prompt")
        fi
        _read_line "$p" value "$default"
        case "${value,,}" in
            y|yes) printf -v "$varname" 'yes'; return ;;
            n|no)  printf -v "$varname" 'no'; return ;;
            *) print_warn "Введите y или n" ;;
        esac
    done
}

ask_confirm() {
    if [[ "ASSUME_YES" -eq 1 ]]; then return 0; fi
    [[ -t 0 ]] || log_error "Нужно подтверждение!"
    local prompt="$1" default="$2" answer p
    while true; do
        if [[ "$default" == "y" ]]; then
            p=$(printf "    $(cecho sW "%s [Y/n]: ")" "$prompt")
        else
            p=$(printf "    $(cecho sW "%s [y/N]: ")" "$prompt")
        fi
        _read_line "$p" answer "$default"
        case "${answer,,}" in
            y|Y|yes) print_confirm "Подтверждено"; return 0 ;;
            n|N|no)  print_cancel "Отменено"; return 1 ;;
            *) print_warn "Введите y или n" ;;
        esac
    done
}

# - usage: ask_raw "Текст: " varname [default] -
ask_raw() {
    local prompt="$1" varname="$2" default="${3:-}"
    _read_line "$prompt" "$varname" "$default"
}

#-> awg_multi_script:
#   Во всём скрипте ввод читается только через хелперы ниже. Общий контракт:
#   • Ctrl+D (EOF) = «отмена/назад». Никогда не роняет скрипт и не зацикливает
#     переспрос — раньше read_choice/read_yesno на EOF крутили бесконечный цикл,
#     а safe_read под set -e убивал весь скрипт.
#   • Мусорный ввод переспрашивается, а не проваливается дальше.
#   • В меню принимаются только цифры (плюс явно объявленные буквенные пункты),
#     0 = назад или выход.
#   • Опасные действия подтверждаются через read_confirm — полным словом.
#  ──────────────────────────────────────────────────────────────────────
# _flush_stdin — сбрасывает буфер stdin, чтобы случайные клавиши/повторы
# не попадали в следующий prompt. Только в интерактивном режиме (TTY):
# в неинтерактивном (heredoc/пайп) -t 0.05 съел бы реальный ввод.
# - Ввод всегда идёт через /dev/tty, а не через текущие stdout/stderr.
# - Это важно для диагностики: там вывод временно уходит в FIFO/tee.
# - Не используем read -e с цветным prompt: readline неверно считает ширину ANSI-кодов,
# - из-за чего Backspace и перерисовка строки дают мусор в терминале.

_flush_stdin() {
  if [[ -t 0 ]]; then
    while read -t 0.05 -n 100 -r _discard 2>/dev/null; do :; done
  fi
}
# safe_read — свободный ввод (имена, IP, комментарии). Валидацию делает вызывающий.
# EOF → пустое значение и rc=0: вызывающие трактуют пустую строку как отмену,
# а ненулевой код возврата под set -e снёс бы весь скрипт.
# Использование: safe_read VARNAME "Промпт: "
safe_read() {
  local _var_name="$1"
  local _prompt="${2:-}"
  _flush_stdin
  # shellcheck disable=SC2229  # читаем в переменную по имени — это намеренно
  if ! read -rp "$_prompt" "$_var_name"; then
    printf -v "$_var_name" '%s' ""
    echo "" >&2
  fi
  return 0
}

# read_choice — единая функция чтения выбора: числовой диапазон с переспросом.
# Использование: read_choice VARNAME "Промпт: " MIN MAX [DEFAULT] [EXTRA]
#   DEFAULT — что подставить на пустой Enter. Без него пустой ввод невалиден.
#   EXTRA   — дополнительные буквенные пункты через '|' (например "d" или "d|r").
#             Регистр не важен, результат отдаётся в нижнем регистре.
# MIN должен быть значением «назад/отмена» (в меню это 0): именно его получает
# вызывающий на Ctrl+D, если не задан DEFAULT.
read_choice() {
  local _var_name="$1"
  local _prompt="$2"
  local _min="$3"
  local _max="$4"
  local _default="${5:-}"
  local _extra="${6:-}"
  local _value _lc _k _matched
  local _keys=()
  [[ -n "$_extra" ]] && IFS='|' read -ra _keys <<< "$_extra"

  while true; do
    _flush_stdin
    if ! read -rp "$_prompt" _value; then
      # Ctrl+D / закрытый stdin: читать больше нечего. Раньше здесь крутился
      # бесконечный цикл переспроса. Отдаём безопасный вариант.
      echo "" >&2
      _value="${_default:-$_min}"
      break
    fi
    # Пустой ввод + есть дефолт → применяем дефолт
    if [[ -z "$_value" && -n "$_default" ]]; then
      _value="$_default"
      break
    fi
    # Число в диапазоне. 10# обязателен: без него ввод "08" ломает арифметику
    # bash (трактуется как восьмеричное) и вываливает сырую ошибку в терминал.
    if [[ "$_value" =~ ^[0-9]+$ ]] && (( 10#$_value >= _min && 10#$_value <= _max )); then
      _value="$((10#$_value))"
      break
    fi
    # Буквенные пункты меню
    _matched=0
    _lc="${_value,,}"
    for _k in ${_keys[@]+"${_keys[@]}"}; do
      if [[ "$_lc" == "${_k,,}" ]]; then
        _value="${_k,,}"; _matched=1; break
      fi
    done
    [[ $_matched -eq 1 ]] && break

    if [[ -n "$_extra" ]]; then
      echo -e "${R}  Введите число от ${_min} до ${_max} или: ${_extra//|/, }${N}" >&2
    else
      echo -e "${R}  Введите число от ${_min} до ${_max}${N}" >&2
    fi
  done
  # Присваиваем результат вызывающей переменной
  printf -v "$_var_name" '%s' "$_value"
}
