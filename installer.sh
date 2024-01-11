#!/bin/bash

#################################################################
# Settings

# Таймзона по-умолчанию, если не удалось определить таймзону компьютера
DEFAULT_TIMEZONE="Europe/Moscow"

APPS_ALL_SCREENS=(
  # "Системные приложения"
  "com.carmodapps.carstore"
  "com.touchtype.swiftkey"
  "mobi.infolife.uninstaller"

  # Общие приложения для всех экранов
  "com.apple.android.music"
  "ru.kinopoisk"
  "ru.yandex.music"
)

APPS_SCREEN_TYPE_DRIVER=(
  # Приложения для экрана водителя
  "ru.yandex.yandexnavi"
  "to.chargers"
  "com.maxxt.pcradio"
  # air.StrelkaHUDFREE # Вроде пока нет пермишена
)

APPS_SCREEN_TYPE_COPILOT=(
  # Приложения для экрана пассажира
  # (Они будут также установлены на водительский, т.к. пока нет возможности установить только на пассажирский)
)

APPS_SCREEN_TYPE_REAR=(
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

# shellcheck disable=SC2034
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
# CPU/Screen types

CPU_TYPE_FRONT="Передний CPU"
CPU_TYPE_REAR="Задний CPU"

SCREEN_TYPE_DRIVER="Экран водителя"
SCREEN_TYPE_COPILOT="Экран пассажира"
SCREEN_TYPE_REAR="Задний экран"

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
  echo -e "\033[32m${LOG_PREFIX} $1\033[0m" >&2
}

function log_warn() {
  echo -e "\033[33m${LOG_PREFIX}[Предупреждение] $1\033[0m" >&2
}

function log_error() {
  echo -e "\033[31m${LOG_PREFIX}[Ошибка] $1\033[0m" >&2
}

function log_verbose() {
  if ${VERBOSE}; then
    echo -e "\033[37m${LOG_PREFIX} $1\033[0m" >&2
  fi
}

#################################################################

function _unique_str_list(){
  local str="$1"
  echo "${str}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

function _run_adb(){
  log_verbose "adb \"$*\""

  if ! "$ADB" "$@"; then
    log_error "$ADB $*"
    return 1
  fi
}

#################################################################
# CPU/Screen types helpers

function get_cpu_type(){
  local product_type=$1

  case "${product_type}" in
    HU_SS2MAXF)
      echo "${CPU_TYPE_FRONT}"
      ;;
    HU_SS2MAXR)
      echo "${CPU_TYPE_REAR}"
      ;;
    *)
      log_error "Неизвестный тип CPU: ${product_type}"
      exit 1
      ;;
  esac
}

function get_screen_type(){
  local cpu_type=$1
  local user_id=$2

  if [ "${cpu_type}" == "${CPU_TYPE_FRONT}" ]; then
    if [ "${user_id}" == "${FRONT_MAIN_USER_ID}" ]; then
      echo "${SCREEN_TYPE_DRIVER}"
    elif [ "${user_id}" == "${FRONT_COPILOT_USER_ID}" ]; then
      echo "${SCREEN_TYPE_COPILOT}"
    else
      log_error "Неизвестный user_id: ${user_id}, cpu_type: ${cpu_type}"
      exit 1
    fi
  elif [ "${cpu_type}" == "${CPU_TYPE_REAR}" ]; then
    if [ "${user_id}" == "${REAR_USER_ID}" ]; then
      echo "${SCREEN_TYPE_REAR}"
    else
      log_error "Неизвестный user_id: ${user_id}, cpu_type: ${cpu_type}"
      exit 1
    fi
  else
    log_error "Неизвестный тип CPU: ${cpu_type}, cpu_type: ${cpu_type}"
    exit 1
  fi
}

#################################################################

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

function get_vin(){
  local cpu_type=$1

  local vin
  vin=$(_run_adb shell getprop persist.sys.vehicle.vin)

  if [ -z "${vin}" ]; then
    log_error "VIN не найден"
    exit 1
  fi

  echo "${vin}"
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
  local screen_type=$1
  local user_id=$2

  _run_adb shell ime disable --user "${user_id}" com.baidu.input/.ImeService && \
  _run_adb shell ime disable --user $user_id com.android.inputmethod.latin/.LatinIME && \
  _run_adb shell ime enable --user $user_id com.touchtype.swiftkey/com.touchtype.KeyboardService && \
  _run_adb shell ime set --user $user_id com.touchtype.swiftkey/com.touchtype.KeyboardService

  if [ $? -ne 0 ]; then
    log_error "[${screen_type}] Настройка SwiftKey: ошибка"
    return 1
  else
    log_info "[${screen_type}] Настройка SwiftKey: успешно"
  fi
}

function _install_app(){
  local screen_type=$1
  local app_id=$2
  local user_id=$3
  local app_filename

  # FIXME: use _find_app_files and check that only one exists
  app_filename=$(find "${DOWNLOAD_DIR}" -name "${app_id}*.apk" | head -n 1)

  if [ -z "${app_filename}" ]; then
    log_error "[${screen_type}] [$app_id] Файл не найден в каталоге загрузок: ${DOWNLOAD_DIR}"
    return 1
  fi

  if [ ! -f "${app_filename}" ]; then
    log_error "[${screen_type}] [$app_id] Файл не найден: ${app_filename}"
    return 1
  fi

  log_info "[${screen_type}] [$app_id] Установка..."

  if ! _run_adb install -r -g --user "${user_id}" "${app_filename}"; then
    log_error "[${screen_type}] [$app_id] Установка: ошибка"
    return 1
  else
    log_info "[${screen_type}] [$app_id] Установка: успешно"
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
    log_info "[${screen_type}] [$app_id] Выдача разрешения ${opt}..."

    if ! _run_adb shell appops set --user "${user_id}" "${app_id}" "${opt}" allow; then
      log_error "[${screen_type}] [$app_id] Выдача разрешения ${opt}: ошибка"
      return 1
    else
      log_info "[${screen_type}] [$app_id] Выдача разрешения ${opt}: успешно"
    fi
  done

  if [ "${app_id}" == "com.touchtype.swiftkey" ]; then
    if ! post_install_app_swiftkey "${screen_type}" "${user_id}"; then
      return 1
    fi
  fi
}

function _disable_psglauncher(){
  local screen_type=$1
  local user_id=$2

  log_info "[${screen_type}] Отключение PSGLauncher"

  _run_adb shell pm disable-user --user "${user_id}" com.lixiang.psglauncher
  _run_adb shell pm clear --user "${user_id}" com.lixiang.psglauncher
}


function install_front() {
  local users=("${FRONT_MAIN_USER_ID}" "${FRONT_COPILOT_USER_ID}")

  local user_id
  for user_id in "${users[@]}"; do
    local screen_type
    local user_apps=()
    if [ "${user_id}" == "${FRONT_MAIN_USER_ID}" ]; then
      screen_type="${SCREEN_TYPE_DRIVER}"
      user_apps=("${APPS_SCREEN_TYPE_DRIVER[@]}")
    else
      screen_type="${SCREEN_TYPE_COPILOT}"
      user_apps=("${APPS_SCREEN_TYPE_COPILOT[@]}")

      _disable_psglauncher "${screen_type}" "${user_id}"
    fi

    # Install all apps
    local apps=("${APPS_ALL_SCREENS[@]}" "${user_apps[@]}")
    local app_id
    for app_id in "${apps[@]}"; do
      _install_app "${screen_type}" "${app_id}" "${user_id}"
    done
  done
}

function install_rear() {
  local user_id="${REAR_USER_ID}"
  local apps=("${APPS_ALL_SCREENS[@]}" "${APPS_SCREEN_TYPE_REAR[@]}")

  _disable_psglauncher "${SCREEN_TYPE_REAR}" "${user_id}"

  # Install all apps
  local app_id
  for app_id in "${apps[@]}"; do
    _install_app "${SCREEN_TYPE_REAR}" "${app_id}" "${user_id}"
  done
}

function _check_all_apps_exists(){
  local all_apps
  local app_id
  local error_missing_apps=false
  local error_duplicate_apps=false
  local exit_code=0

  all_apps="${APPS_ALL_SCREENS[*]} ${APPS_SCREEN_TYPE_DRIVER[*]} ${APPS_SCREEN_TYPE_COPILOT[*]}${APPS_SCREEN_TYPE_REAR[*]}"
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

function wait_for_device(){
  local product_type
  local cpu_type
  local vin

  log_info "Ожидание подключения устройства..."

  if ! _run_adb wait-for-device; then
    log_error "Устройство не найдено"
    exit 1
  fi

  product_type=$(_run_adb shell getprop ro.build.product)
  cpu_type=$(get_cpu_type "${product_type}")
  vin=$(get_vin "${cpu_type}")

  log_info "Устройство найдено: ${cpu_type} (VIN: ${vin})"

  echo "${cpu_type}"
}

function do_display_vin(){
  local cpu_type
  local vin

  cpu_type=$(wait_for_device)
  vin=$(get_vin "${cpu_type}")

  log_info "############################################################"
  log_info "VIN: ${vin}"
  log_info "############################################################"
}

function do_install(){
  local cpu_type

  if ! _check_all_apps_exists; then
    exit 1
  fi

  cpu_type=$(wait_for_device)

  case "${cpu_type}" in
    "${CPU_TYPE_FRONT}")
      set_timezone
      set_night_mode
      install_front
      ;;
    "${CPU_TYPE_REAR}")
      set_timezone
      set_night_mode
      install_rear
      ;;
    # Default will be handled in wait_for_device()
  esac

}

function delete_for_user(){
  local screen_type=$1
  local user_id=$2
  local non_system_apps

  non_system_apps=$(_run_adb shell pm list packages --user "${user_id}" -3 | cut -d':' -f2 | tr -d '\r' | tr '\n' ' ')

  if [ -z "$non_system_apps" ]; then
    log_info "[${screen_type}] Нет приложений для удаления"
    return 0
  fi

  log_info "[${screen_type}] Удаление всех приложений, кроме системных..."

  for app_id in ${non_system_apps}; do
    log_info "[${screen_type}] Удаление ${app_id}..."

    if ! _run_adb uninstall --user "${user_id}" "${app_id}"; then
      log_error "[${screen_type}] Удаление ${app_id}: ошибка"
      return 1
    else
      log_info "[${screen_type}] Удаление ${app_id}: успешно"
    fi
  done
}

function do_delete(){
  local cpu_type

  cpu_type=$(wait_for_device)

  case "${cpu_type}" in
    "${CPU_TYPE_FRONT}")
      delete_for_user "${SCREEN_TYPE_DRIVER}" "${FRONT_MAIN_USER_ID}"
      delete_for_user "${SCREEN_TYPE_COPILOT}" "${FRONT_COPILOT_USER_ID}"
      ;;
    "${CPU_TYPE_REAR}")
      delete_for_user "${SCREEN_TYPE_REAR}" "${REAR_USER_ID}"
      ;;
    # Default will be handled in wait_for_device()
  esac
}

function do_update(){
  local api_url="https://store.carmodapps.com/api/applications/download"
  local apps_url_list

  mkdir -p "${DOWNLOAD_DIR}"

  log_info "Проверка обновлений приложений..."

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
      log_verbose "[${app_id}] Уже загружен, пропускаем..."
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

  log_info "Проверка обновлений приложений: успешно"

}

#################################################################

function usage() {
    cat <<EOF
Использование: $(basename $0) [options] [<команда>]

По-умолчанию выполняется update + install

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
  local cmd

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
    do_update
    do_install
    exit 1
  fi
}

main "$@"