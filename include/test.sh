#!/usr/bin/env bash

#set -x

source ./.awg-multitools-env
source ./.awg-multitools-colors
source ./.awg-multitools-output
source ./.awg-multitools-input
source ./.awg-multitools-functions
source ./.firewalld-env

check_kernel_version() {
    # The AmneziaWG 2.0 module is built via DKMS against the host kernel. On
    # kernels older than 5.15 (Ubuntu < 22.04, e.g. 5.4 on 20.04) the build
    # usually fails at step 2 with an opaque package-failure. Warn EXPLICITLY and
    # early, before updates and reboots (issue #163). Not a die: on some older
    # kernels the module still builds (HWE and such), so WARN + confirm.
    local kver kmaj kmin
    kver=$(uname -r)
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        log_warn "Could not parse the kernel version ('$kver') - skipping the minimum-version check."
        return 0
    fi
    if (( kmaj < 5 || (kmaj == 5 && kmin < 15) )); then
        log_warn "Kernel $kver is older than 5.15 - usually too old for the AmneziaWG 2.0 module."
        log_warn "The DKMS module build on such a kernel most often fails. Reinstall the VPS on Ubuntu 24.04 LTS or Debian 12 (or newer). Matrix: Ubuntu 24.04/25.10/26.04, Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue anyway? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled: kernel $kver is too old for the AmneziaWG 2.0 module."; fi
        else
            log "Continuing on kernel $kver (--yes)."
        fi
    else
        log "Kernel $kver (OK for the AmneziaWG 2.0 module)."
    fi
}

check_kernel_version 

#FW_check_port "31031/udp" && success_box "Порт 31031/udp есть где-то в firewalld" || failure_box "Порт 31031/udp не найден ни в одной зоне"
#FW_check_port "31031/udp" && success_box "Есть в permanent" || failure_box "Нет в permanent"
#FW_check_port "31031/udp" && success_box "OK" || failure_box "FAIL"

#FW_check_service "31031/udp" || false

exit 0
#FW_Zone_check VPN-clients
#exit 0
FW_Zone --delete "test" "Its-new-Test-Zone" "New zone test description"
FW_Zone --new "test" "Its-new-Test-Zone" "New zone test description"
FW_Zone --get-zones

exit 0

declare sItems=("one" "two" "three")
declare sArr=("sel_one" "sel_two" "sel_three")
declare sDefault="2"
declare sTitle="test Select menu"
select_menu
echo $sArr

exit 0

_list=("one" "two" "three")

log "${_list[*]}"

    declare msPrompt="Выберите клиентов для удаления (пробел — отметить, Enter — подтвердить)"
    declare msDefaults=(true false true)

#    declare msSelected=()
    med_multiselect "true" result _list false "Выберите клиентов для удаления"
#    single_select "true" result _list 2 "Выберите клиентов для удаления"
# >&2

#    multi_select_menu selected 1 "${#_list[@]}" "${_list[@]}" ""  >&2
    idx=0
#        log "array: ${result}"
    ret_val=()
    for option in "${_list[@]}"; do
#        ret+="$option" #"${result[idx]}"
        [ "${result[idx]}" = true ] && ret_val+=("${option}")
#        echo -e "$option\t=> ${result[idx]}"
        ((idx++))
    done
log "${ret_val[*]}"
#        names="${ssSelected[@]}"

exit 0

print_line - 58

echo $dashes
echo $equals
echo $big_dashes
success_box "Success box here"
exit 0

#curl -sL multiselect.miu.io -o multitest.sh
#source <(curl -sL multiselect.miu.io)
source .awg-multitools-colors
source .awg-multitools-output
echo -e $zamok
exit 0
my_options=("Option 1" "Option 2" "Option 3")
preselection=("true" "true" "false")

OPTIONS_VALUES=("APPL" "MSFT" "GOOG")
OPTIONS_LABELS=("Apple" "Microsoft" "Google")

for i in "${!OPTIONS_VALUES[@]}"; do
    OPTIONS_STRING+="${OPTIONS_VALUES[$i]} (${OPTIONS_LABELS[$i]});"
done

ask_multiselect SELECTED "$OPTIONS_STRING"

for i in "${!SELECTED[@]}"; do
    if [ "${SELECTED[$i]}" == "true" ]; then
        CHECKED+=("${OPTIONS_VALUES[$i]}")
    fi
done
echo "${CHECKED[@]}"

exit 0

multiselect "true" my_options retval preselection
idx=0
for option in "${my_options[@]}"; do
     echo -e "$option\t=> ${result[idx]}"
     ((idx++))
done

printf "%*s\n" "$retval"
#printf "%*s\n" "$result"
