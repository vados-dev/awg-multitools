#!/usr/bin/env bash


#curl -sL multiselect.miu.io -o multitest.sh
#source <(curl -sL multiselect.miu.io)
source .awg-multitools-colors
source .awg-multitools-output
#exit 0
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
