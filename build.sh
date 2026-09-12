#!/usr/bin/env bash

#########
### BUILD
### собирает модули из src/ в один файл ${dir_name}/module.sh
### порядок папок важен: header первый, entry последний
########################################################

set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
BUILD_DIR=${SELF%/*}
source "${BUILD_DIR}/include/.${BUILD_DIR##*/}-env"
source $colors_inc

str_replace(){
    local rep_file=$(<$1)
    local rep_str=$2
    local new_str=$3
    rep_file="${rep_file//$rep_str/$new_str}"
    printf "%s\n" "$rep_file"
}



#-> Сборка меню:
add_menu_files() {
    local dir="$1"
    local pattern="$2"
    get_arr() {
        local arr_file=$1
        local arr_var="${1##*/}"
        local arr_val=()
        while IFS= read -r line; do
            item=$(echo \"$line\" | awk '{printf "%s ", $0}')
            arr_val+="$item"
        done < "${arr_file}"
        printf -v ${arr_var} "%s" "${arr_val% }"
    }
    get_file() {
        local menu_file=$1
        local menu_var="${1##*/}"
        local menu_val
        menu_val=$(<${menu_file})
        printf -v ${menu_var} "%s" "${menu_val}"
    }
    for file in `find $dir -type f -name "$pattern" | sort`; do
        if [[ "${file##*/}" == "Items" ]]; then
            get_arr "${file}"
        elif [[ "${file##*/}" == "Actions" ]]; then
            get_arr "${file}"
        else
            get_file "${file}"
        fi
    done
}

build_menu() {
    local dir="$1"
    local indent="$2"
    local menu_folder=""
    for item in "$dir"/*; do
        if [ -d "$item" ]; then
            if [[ "${item##*/}" == "menu" ]]; then
                build_menu "$item" "$indent"
            else
                menu_name="menu_${item##*/}"
                menu_folder=$indent$item
                add_menu_files "${menu_folder}" "*"
                printf "#-> %s:\n" "$Title"
                printf "%s() {\n" "$menu_name"
                printf "    declare mItems=(%s)\n" "${Items}"
                printf "    declare mActions=(%s)\n" "${Actions}"
                printf "    declare mTitle=\"%s\"\n" "${Title}"
                printf "    declare mDescr=\"%s\"\n" "${Descr}"
                printf "    declare mType=\"%s\"\n" "${Type}"
                printf "    show_menu\n}\n\n"
            fi
        fi
    done
}

#build_menu "." "" >> "$MAIN_SCRIPT"
#set -x

build_modules() {
    local dir="$1"
    local indent="$2"
    local read_item=""
    for item in "$dir"/*; do
        if [ -d "$item" ]; then
            if [[ "${item##*/}" != "menu" ]]; then
                build_modules "$item" "$indent"
            #else
            #    build_menu "$item" ""
            fi
        elif [ -f "$item" ]; then
            if [[ "${item##*/}" == "common.sh" || "${item##*/}" == "module.sh" ]]; then
                while IFS= read -r line; do
                    #-> Пропускаем shebang из модулей, он уже есть в начале:
                    if [[ "$line" != "#!/"* ]]; then
                        #-> Заменяем #<::PROJ_WORK_DIR::> на реальную переменную:
                        if [[ "$line" == "#<::PROJ_WORK_DIR::>" ]]; then
                            printf "PROJ_WORK_DIR=\"%s\"\n" "$PROJ_WORK_DIR"
                        else
                            printf "%s\n" "$line"
                        fi
                    fi
                done < "$item"
            fi
        fi
    done
}


# - порядок сборки: header -> модули -> меню -> entry -
DIRS=(
    "00_head"
    "01_info"
    "02_install"
    "03_awg2"
    "04_awg3"
    "08_nmcli"
    "15_utils"
    "90_main"
    "99_entry"
)

cecho sW "Сборка "; cecho sM "${app_name} "; cecho sY "${app_version}"; cecho sW "...\n"

#-> Начинаем с shebang:
printf '#!/usr/bin/env bash\n\n' > "$MAIN_SCRIPT"
printf '##########################################################\n' >> "$MAIN_SCRIPT"
printf "### ${pr_descr}\n" >> "$MAIN_SCRIPT"
printf "#-> ${app_name} ${app_version}\n" >> "$MAIN_SCRIPT"
printf "#-> Git-Hub: ${github_url}${pr_owner}/${repo_name}/\n" >> "$MAIN_SCRIPT"
printf "#-> Собран: $(date -u +'%Y-%m-%d %H:%M:%S %Z')\n" >> "$MAIN_SCRIPT"
printf '##########################################################\n\n' >> "$MAIN_SCRIPT"

TOTAL_LINES=0
MISSING=0

cd ${SRC_DIR}
for d in "${DIRS[@]}"; do
    src="${d}"
#    echo "src=$src"
#    ls
    if [[ ! -d "$src" ]]; then
        printf "$(cecho sR %s)\n" "Перечисленная папка пропущена: $d (не найдена)!"
        MISSING=$((MISSING + 1))
        continue
    fi
build_modules "${d}" "" >> "$MAIN_SCRIPT"
build_menu "${d}" "" >> "$MAIN_SCRIPT"
done

exit 0

for f in "${FILES[@]}"; do
    src="${SRC_DIR}/${f}"
    if [[ ! -f "$src" ]]; then
        printf "  Пропущен: ${f} (файл не найден)"
        MISSING=$((MISSING + 1))
        continue
    fi

    lines=$(wc -l < "$src")
    TOTAL_LINES=$((TOTAL_LINES + lines))

    echo "" >> "$MAIN_SCRIPT"
    echo "# === ${f} ===" >> "$MAIN_SCRIPT"

    # - пропускаем shebang из модулей, он уже есть в начале -
    if head -1 "$src" | grep -q '^#!/'; then
        tail -n +2 "$src" >> "$MAIN_SCRIPT"
    else
        cat "$src" >> "$MAIN_SCRIPT"
    fi

    echo "  [OK] ${f} (${lines} строк)"
done

chmod +x "$MAIN_SCRIPT"

echo ""
echo "Готово: ${MAIN_SCRIPT}"
echo "Строк: ${TOTAL_LINES}"
echo "Модулей: ${#FILES[@]} (пропущено: ${MISSING})"
echo "Размер: $(du -h "$MAIN_SCRIPT" | awk '{print $1}')"

exit 0


#                if head -1 "$item" | grep -q '^#!/'; then
#                    $read_item="$(tail -n +2 "$item")"
#                else
#                    $read_item="$item"
#                fi
                #echo "$indent$item/" '^#!/' ""
#for file in `find ./menu/main/ -type f -name "*.*"`; do
#    if [[ "${file##*/}" == "Items.arr" ]]; then
#        Items=()
#        while IFS= read -r line; do
#            item=$(echo \"$line\" | awk '{printf "%s ", $0}')
#            Items+="$item"
#        done < "${file}"
#        printf "    declare mItems=(%s)\n" "${Items% }"
#    elif [[ "${file##*/}" == "Actions.arr" ]]; then
#        Actions=()
#        while IFS= read -r line; do
#            action=$(echo \"$line\" | awk '{printf "%s ", $0}')
#            Actions+="$action"
#        done < "${file}"
#        printf "    declare mActions=(%s)\n" "${Actions% }"
#    elif [[ "${file##*/}" == "Title.txt" ]]; then
#        Title=$(<${file})
#        printf "    declare mTitle=\"%s\"\n" "${Title}"
#    elif [[ "${file##*/}" == "Descr.txt" ]]; then
#        Descr=$(<${file})
#        printf "    declare mDescr=\"%s\"\n" "${Descr}"
#    elif [[ "${file##*/}" == "Type.txt" ]]; then
#        Type=$(<${file})
#        printf "    declare mType=\"%s\"\n" "${Type}"
#    fi
#done >> "$MAIN_SCRIPT"
#exit 0
#for dir in */; do
#    echo "Сборка из папки dir: $dir"
#    if [[ "$dir" == "menu/" ]]; then
#        for menu in */menu; do
#            echo "Сборка из папки menu: $menu"
#            if [[ "$menu" != "" ]]; then
#                names=$(ls ${menu%/*})
#                echo "Сборка из папки names: $names"
#
#                for menu_name in */menu/*; do
#                    menu_name=$(dir ${menu}/*)
#                    echo $menu_name
#                done
#            fi
#        done
#    fi
# > "$dir/build.txt"
#done
#exit 0
#find ./ -type f | xargs bash -c '
#    echo "Обрабатываю: $0";
#    cat "$0"'; {} \;
#clear
#find_read() {
#    local dir="$1"
#    local pattern="$2"
#    find "$dir" -type f \( -name "$pattern" -o -path "*.git*" \) -print0 | while IFS= read -r -d '' file; do
#        echo "Чтение файла: $file"
#        cat "$file"
#    done
#}
#find_read "./menu/main" "*"
#find ./menu/main -type f -name "*" | while read -r file; do
#    cat "$file" > ./out.txt
#done
