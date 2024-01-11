#!/bin/bash

#################################################################
# Settings

DEFAULT_TIMEZONE="Europe/Moscow"

ALL_SCREEN_APPS=(
  # "Системные приложения"
  "com.carmodapps.carstore"
  "com.touchtype.swiftkey"
  "mobi.infolife.uninstaller"

  # Общие приложения для всех экранов
  "com.apple.android.music"
  "ru.kinopoisk"
  "ru.yandex.music"
)

DRIVER_SCREEN_APPS=(
  # Приложения для экрана водителя
  "ru.yandex.yandexnavi"
  "to.chargers"
  "com.maxxt.pcradio"
  # air.StrelkaHUDFREE # Вроде пока нет пермишена
)

PASSENGER_SCREEN_APPS=(
  # Приложения для экрана пассажира
  # (Они будут также установлены на водительский, т.к. пока нет возможности установить только на пассажирский)
)

REAR_SCREEN_APPS=(
  # Приложения для экрана задних пассажиров
  "com.rovio.angrybirds"
  "com.netflix.NGP.TerraNil"
)

#################################################################
# Разрешения appops для приложений
#
# Для добавления нового разрешения необходимо:
#   1. Добавить его в APPOPS_TYPES
#   2. Добавить в массив APPOPS_xxx нужные приложения

# Все возможные типы разрешений
APPOPS_TYPES=(
  "REQUEST_INSTALL_PACKAGES"
)

APPOPS_REQUEST_INSTALL_PACKAGES=(
  "com.carmodapps.carstore"
)

#################################################################
# System vars

ADB="adb"
FRONT_MAIN_USER_ID=0
FRONT_COPILOT_USER_ID=21473
REAR_USER_ID=0

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
SCRIPT_BASENAME="$(basename "${BASH_SOURCE[0]}")"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"

VERBOSE=false

#################################################################
# Setup 3rd party deps depending on OS

PLATFORM_BINARY_PATH=""
HOST_TIMEZONE=""

# Determine the platform and set the binary path
case "$(uname -s)" in
    Darwin)
        # Mac OS X platform
        PLATFORM_BINARY_PATH="mac/$(uname -m)"
        HOST_TIMEZONE=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
        ;;
    Linux)
        # Linux platform
        PLATFORM_BINARY_PATH="linux/$(uname -m)"
        HOST_TIMEZONE=$(cat /etc/timezone)
        ;;
    *)
        echo "Неизвестная платформа: $(uname -s)"
        exit 1
        ;;
esac

ADB="${SCRIPT_DIR}/3rd_party/bin/${PLATFORM_BINARY_PATH}/adb"

if [ ! -f "${ADB}" ]; then
  echo "ADB не найден: ${ADB}"
  exit 1
fi

#################################################################
# Logging

LOG_PREFIX="####LiAuto### "

function log_info() {
  echo -e "\033[32m${LOG_PREFIX} $1\033[0m"
}

function log_warn() {
  echo -e "\033[33m${LOG_PREFIX}[Предупреждение] $1\033[0m"
}

function log_error() {
  echo -e "\033[31m${LOG_PREFIX}[Ошибка] $1\033[0m"
}
#################################################################

function _unique_str_list(){
  local str="$1"
  echo "${str}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

function _run_adb(){
  if [ "${VERBOSE}" == "true" ]; then
    echo "adb \"$*\"" >&2
  fi

  if ! "$ADB" "$@"; then
    log_error "$ADB $*"
    return 1
  fi
}

function set_timezone(){
  local timezone
  local origin

  # if HOST_TIMEZONE is set, use it
  if [ -n "${HOST_TIMEZONE}" ]; then
    timezone="${HOST_TIMEZONE}"
    origin="из компьютера"
  else
    timezone="${DEFAULT_TIMEZONE}"
    origin="по-умолчанию"
  fi

  if ! _run_adb shell service call alarm 3 s16 "${timezone}" > /dev/null; then
    log_error "Установка часового пояса (${timezone}, ${origin}): ошибка"
    return 1
  else
    log_info "Установка часового пояса (${timezone}, ${origin}): успешно"
  fi
}

function set_night_mode(){
  log_info "Установка ночного режима..."

  if ! _run_adb shell cmd uimode night yes; then
    log_error "Установка ночного режима: ошибка"
    return 1
  else
    log_info "Установка ночного режима: успешно"
  fi
}

#
# Find app files in DOWNLOAD_DIR
# Return: list of files separated by \0
function _find_app_files(){
  local app_id=$1

  find "${DOWNLOAD_DIR}" -name "${app_id}*.apk" -print0
}

function _get_app_files_count(){
  local app_id=$1

  find "${DOWNLOAD_DIR}" -name "${app_id}*.apk" | wc -l
}

function post_install_app_swiftkey(){
  local screen_name=$1
  local user_id=$2

  _run_adb shell ime disable --user "${user_id}" com.baidu.input/.ImeService && \
  _run_adb shell ime disable --user $user_id com.android.inputmethod.latin/.LatinIME && \
  _run_adb shell ime enable --user $user_id com.touchtype.swiftkey/com.touchtype.KeyboardService && \
  _run_adb shell ime set --user $user_id com.touchtype.swiftkey/com.touchtype.KeyboardService

  if [ $? -ne 0 ]; then
    log_error "[${screen_name}] Настройка SwiftKey: ошибка"
    return 1
  else
    log_info "[${screen_name}] Настройка SwiftKey: успешно"
  fi
}

function _install_app(){
  local screen_name=$1
  local app_id=$2
  local user_id=$3
  local app_filename

  # FIXME: use _find_app_files and check that only one exists
  app_filename=$(find "${DOWNLOAD_DIR}" -name "${app_id}*.apk" | head -n 1)

  if [ -z "${app_filename}" ]; then
    log_error "[${screen_name}] [$app_id] Файл не найден в каталоге загрузок: ${DOWNLOAD_DIR}"
    return 1
  fi

  if [ ! -f "${app_filename}" ]; then
    log_error "[${screen_name}] [$app_id] Файл не найден: ${app_filename}"
    return 1
  fi

  log_info "[${screen_name}] [$app_id] Установка..."

  if ! _run_adb install -r -g --user "${user_id}" "${app_filename}"; then
    log_error "[${screen_name}] [$app_id] Установка: ошибка"
    return 1
  else
    log_info "[${screen_name}] [$app_id] Установка: успешно"
  fi

  # Check APPOPS_xxx
  local appops=() # Required appops for this app
  local opt
  for opt in "${APPOPS_TYPES[@]}"; do
    local var_name="APPOPS_${opt}"
    local appops_list=("${!var_name}")
    local appops_app_id

    for appops_app_id in "${appops_list[@]}"; do
      if [ "${appops_app_id}" == "${app_id}" ]; then
        appops+=("${opt}")
      fi
    done

  done


  for opt in "${appops[@]}"; do
    log_info "[${screen_name}] [$app_id] Выдача разрешения ${opt}..."

    if ! _run_adb shell appops set --user "${user_id}" "${app_id}" "${opt}" allow; then
      log_error "[${screen_name}] [$app_id] Выдача разрешения ${opt}: ошибка"
      return 1
    else
      log_info "[${screen_name}] [$app_id] Выдача разрешения ${opt}: успешно"
    fi
  done

  if [ "${app_id}" == "com.touchtype.swiftkey" ]; then
    if ! post_install_app_swiftkey "${screen_name}" "${user_id}"; then
      return 1
    fi
  fi
}

function _disable_psglauncher(){
  local screen_name=$1
  local user_id=$2

  log_info "[${screen_name}] Отключение PSGLauncher"

  _run_adb shell pm disable-user --user "${user_id}" com.lixiang.psglauncher
  _run_adb shell pm clear --user "${user_id}" com.lixiang.psglauncher
}


function install_max_front() {
  local users=("${FRONT_MAIN_USER_ID}" "${FRONT_COPILOT_USER_ID}")

  local user_id
  for user_id in "${users[@]}"; do
    local screen_name
    local user_apps=()
    if [ "${user_id}" == "${FRONT_MAIN_USER_ID}" ]; then
      screen_name="Экран водителя"
      user_apps=("${DRIVER_SCREEN_APPS[@]}")
    else
      screen_name="Экран пассажира"
      user_apps=("${PASSENGER_SCREEN_APPS[@]}")

      _disable_psglauncher "${screen_name}" "${user_id}"
    fi

    # Install all apps
    local apps=("${ALL_SCREEN_APPS[@]}" "${user_apps[@]}")
    local app_id
    for app_id in "${apps[@]}"; do
      _install_app "${screen_name}" "${app_id}" "${user_id}"
    done
  done
}

function install_max_rear() {
  local screen_name="Экран задних пассажиров"
  local user_id="${REAR_USER_ID}"
  local apps=("${ALL_SCREEN_APPS[@]}" "${REAR_SCREEN_APPS[@]}")

  _disable_psglauncher "${screen_name}" "${user_id}"

  # Install all apps
  local app_id
  for app_id in "${apps[@]}"; do
    _install_app "${screen_name}" "${app_id}" "${user_id}"
  done
}

function _check_all_apps_exists(){
  local all_apps
  local app_id
  local error_missing_apps=false
  local error_duplicate_apps=false
  local exit_code=0

  all_apps="${ALL_SCREEN_APPS[*]} ${DRIVER_SCREEN_APPS[*]} ${PASSENGER_SCREEN_APPS[*]}${REAR_SCREEN_APPS[*]}"
  all_apps=$(_unique_str_list "${all_apps}")

  for app_id in ${all_apps}; do
    local count
    count=$(_get_app_files_count "${app_id}")

    if [ "${count}" -eq 0 ]; then
      log_error "[${app_id}] Приложение не найдено в каталоге загрузок"
      error_missing_apps=true
      exit_code=1

    elif [ "${count}" -gt 1 ]; then
      log_error "[${app_id}] Найдено несколько файлов приложения:"

      local app_file
      while IFS= read -r -d '' app_file; do
        log_error "[${app_id}]     ${app_file}"
      done < <(eval "_find_app_files ${app_id}")


      error_duplicate_apps=true
      exit_code=1
    fi
  done

  if [ ${exit_code} -ne 0 ]; then
    log_error "############################################################"
    log_error " Ошибка при проверке приложений"
    log_error "############################################################"
  fi

  if ${error_missing_apps}; then
    log_error "Для автоматического скачивания приложений CarModApps необходимо выполнить команду \"${SCRIPT_BASENAME} update\""
    log_error "Для ручного добавления сторонних приложений необходимо поместить их в каталог загрузок: ${DOWNLOAD_DIR}"
  fi

  if ${error_duplicate_apps}; then
    log_error "Удалите дубликаты приложений из каталога загрузок: ${DOWNLOAD_DIR}"
  fi

  return ${exit_code}
}

function _wait_for_device(){
  log_info "Ожидание подключения устройства..."

  if ! _run_adb wait-for-device; then
    log_error "Устройство не найдено"
    exit 1
  fi

  log_info "Устройство найдено"
}

function do_display_vin(){
  _wait_for_device

  local vin
  vin=$(_run_adb shell getprop persist.sys.vehicle.vin)

  if [ -z "${vin}" ]; then
    log_error "VIN не найден"
    exit 1
  fi

  log_info "############################################################"
  log_info "VIN: ${vin}"
  log_info "############################################################"
}

function do_install(){
  local product_type

  if ! _check_all_apps_exists; then
    exit 1
  fi

  _wait_for_device

  product_type=$(_run_adb shell getprop ro.build.product)

  if [ "${product_type}" == "HU_SS2MAXF" ]; then
    log_info "############################################################"
    log_info "# Обнаружен передний CPU: ${product_type}"
    log_info "############################################################"

    set_timezone
    set_night_mode
    install_max_front

  elif [ "${product_type}" == "HU_SS2MAXR" ]; then
    log_info "############################################################"
    log_info "# Обнаружен задний CPU: ${product_type}"
    log_info "############################################################"

    set_timezone
    set_night_mode
    install_max_rear
  else
    log_error "Неизвестный тип CPU: ${product_type}"
  fi
}

function do_delete(){
  local non_system_apps

  _wait_for_device

  non_system_apps=$(_run_adb shell pm list packages -3 | cut -d':' -f2 | tr -d '\r' | tr '\n' ' ')

  if [ -z "$non_system_apps" ]; then
    log_info "Нет приложений для удаления"
    return 0
  fi

  log_info "Удаление всех приложений, кроме системных..."

  for app_id in ${non_system_apps}; do
    log_info "Удаление ${app_id}..."

    if ! _run_adb uninstall "${app_id}"; then
      log_error "Удаление ${app_id}: ошибка"
      return 1
    else
      log_info "Удаление ${app_id}: успешно"
    fi
  done
}

function do_update(){
  local api_url="https://store.carmodapps.com/api/applications/download"
  local apps_url_list

  log_info "Загрузка приложений с сервера CarModApps..."

  apps_url_list=$(curl -s -G -H "Accept: text/plain" "${api_url}")

  local app_line
  for app_line in ${apps_url_list}; do
    local app_id
    local app_filename
    local app_url
    local app_local_filename

    if [ -z "${app_line}" ]; then
      continue
    fi

    # app_line format: "app_id|app_filename|app_url"
    app_id=$(echo "${app_line}" | cut -d'|' -f1)
    app_filename=$(echo "${app_line}" | cut -d'|' -f2)
    app_url=$(echo "${app_line}" | cut -d'|' -f3)

    app_local_filename="${DOWNLOAD_DIR}/${app_filename}"
    if [ -f "${app_local_filename}" ]; then
      log_info "[${app_id}] Уже загружен, пропускаем..."
    else
      log_info "[${app_id}] Загрузка..."

      if ! curl -s -o "${app_local_filename}" "${app_url}"; then
        log_error "[${app_id}] Загрузка: ошибка"
        return 1
      else
        log_info "[${app_id}] Загрузка: успешно"
      fi
    fi

    # Remove old app files
    local old_app_file
    while IFS= read -r -d '' old_app_file; do
      if [ "${old_app_file}" == "${app_local_filename}" ]; then
        # This is current app file, skip
        continue
      fi
      log_warn "[${app_id}] Удаление старого файла ${old_app_file}..."
      rm -f "${old_app_file}"
    done < <(eval "_find_app_files ${app_id}")
  done

}

#################################################################

function usage() {
    cat <<EOF
Использование: $(basename $0) [options] [<команда>]

По-умолчанию выполняется установка приложений (install)

Команды:
  vin: Отобразить VIN
  install: Запустить автоматическую установку приложений
  update: Загрузить приложения с сервера CarModApps
  delete: Удалить все не системные приложения

Опции:
  -h, --help: Показать это сообщение
  -v, --verbose: Выводить подробную информацию
EOF
}

#################################################################

function main() {
  local cmd="install"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -v|--verbose)
        VERBOSE=true
        ;;
      vin|install|update|delete)
        cmd="$1"
        ;;
      *)
        log_error "Неизвестная опция: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done

  if [ "${cmd}" == "vin" ]; then
    do_display_vin
  elif [ "${cmd}" == "install" ]; then
    do_install
    do_display_vin
  elif [ "${cmd}" == "update" ]; then
    do_update
  elif [ "${cmd}" == "delete" ]; then
    do_delete
  else
    log_error "Неизвестная команда: ${cmd}"
    usage
    exit 1
  fi
}

main "$@"