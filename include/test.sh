#!/usr/bin/env bash


source ./.awg-multitools-env
source ./.awg-multitools-colors
source ./.awg-multitools-output
source ./.awg-multitools-input
source ./.awg-multitools-functions


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
