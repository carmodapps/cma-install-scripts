#!/bin/bash

#################################################################
# Settings

# Таймзона по-умолчанию, если не удалось определить таймзону компьютера
DEFAULT_TIMEZONE="Europe/Moscow"

# Если существует файл user_settings.sh, то он будет загружен
# В нём можно переопределить переменные
USER_DEFINED_SETTINGS_OVERRIDE_FILE="user_settings.sh"

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
  "air.StrelkaHUDFREE"
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
APKANALYZER="apkanalyzer"
FRONT_MAIN_USER_ID=0
FRONT_COPILOT_USER_ID=21473
REAR_USER_ID=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
SCRIPT_BASENAME="$(basename "${BASH_SOURCE[0]}")"

# read VERSION file
VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [ -f "${VERSION_FILE}" ]; then
  VERSION=$(cat "${VERSION_FILE}")
else
  VERSION="unknown"
fi

PACKAGES_DIR="${SCRIPT_DIR}/packages"
PACKAGES_CMA_DIR="${PACKAGES_DIR}/carmodapps"
PACKAGES_CUSTOM_SCREEN_TYPE_DRIVER_DIR="${PACKAGES_DIR}/custom/driver"
PACKAGES_CUSTOM_SCREEN_TYPE_COPILOT_DIR="${PACKAGES_DIR}/custom/copilot"
PACKAGES_CUSTOM_SCREEN_TYPE_REAR_DIR="${PACKAGES_DIR}/custom/rear"

VERBOSE=false

FORCE_INSTALL=false

#################################################################
# CPU/Screen types

CPU_TYPE_FRONT="Передний CPU"
CPU_TYPE_REAR="Задний CPU"

SCREEN_TYPE_DRIVER="Экран водителя"
SCREEN_TYPE_COPILOT="Экран пассажира"
SCREEN_TYPE_REAR="Задний экран"

#################################################################
# Setup Platform-specific vars

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

# FIXME: Добавить APKANALYZER

if [ ! -f "${ADB}" ]; then
  echo "ADB не найден: ${ADB}"
  exit 1
fi

#################################################################
# Handle USER_DEFINED_SETTINGS_OVERRIDE_FILE

if [ -f "${USER_DEFINED_SETTINGS_OVERRIDE_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${USER_DEFINED_SETTINGS_OVERRIDE_FILE}"
fi

#################################################################
# Logging

LOG_PREFIX="####LiAuto### "

function log_info() {
  echo -e "\033[32m${LOG_PREFIX}$1\033[0m" >&2
}

function log_warn() {
  echo -e "\033[33m${LOG_PREFIX}[Предупреждение] $1\033[0m" >&2
}

function log_error() {
  echo -e "\033[31m${LOG_PREFIX}[Ошибка] $1\033[0m" >&2
}

function log_verbose() {
  if ${VERBOSE}; then
    echo -e "\033[37m${LOG_PREFIX}$1\033[0m" >&2
  fi
}

#################################################################
# Util functions

function fn_unique_str_list() {
  local str="$1"
  echo "${str}" | tr ' ' '\n' | sort -u | tr '\n' ' '
}

#################################################################
# Run commands

function run_adb() {
  log_verbose "adb $*"

  if ! "$ADB" "$@"; then
    log_error "$ADB $*"
    return 1
  fi
}

function run_apkanalyzer() {
  log_verbose "apkanalyzer $*"

  if ! "${APKANALYZER}" "$@"; then
    log_error "${APKANALYZER} $*"
    return 1
  fi
}

#################################################################
# CPU/Screen types helpers

function get_cpu_type() {
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

function get_screen_type() {
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

function get_vin() {
  local cpu_type=$1

  local vin
  vin=$(run_adb shell getprop persist.sys.vehicle.vin)

  if [ -z "${vin}" ]; then
    log_error "VIN не найден"
    exit 1
  fi

  echo "${vin}"
}

function get_custom_packages_dir() {
  local screen_type=$1
  local dir

  case "${screen_type}" in
  "${SCREEN_TYPE_DRIVER}")
    dir="${PACKAGES_CUSTOM_SCREEN_TYPE_DRIVER_DIR}"
    ;;
  "${SCREEN_TYPE_COPILOT}")
    dir="${PACKAGES_CUSTOM_SCREEN_TYPE_COPILOT_DIR}"
    ;;
  "${SCREEN_TYPE_REAR}")
    dir="${PACKAGES_CUSTOM_SCREEN_TYPE_REAR_DIR}"
    ;;
  *)
    log_error "Неизвестный тип экрана: ${screen_type}"
    exit 1
    ;;
  esac

  echo "${dir}"
}

#################################################################
# Tweaks

function tweak_set_timezone() {
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

  if ! run_adb shell service call alarm 3 s16 "${timezone}" >/dev/null; then
    log_error "Установка часового пояса (${timezone}, ${origin}): ошибка"
    return 1
  else
    log_info "Установка часового пояса (${timezone}, ${origin}): успешно"
  fi
}

function tweak_set_night_mode() {
  log_info "Установка ночного режима..."

  if ! run_adb shell cmd uimode night yes; then
    log_error "Установка ночного режима: ошибка"
    return 1
  else
    log_info "Установка ночного режима: успешно"
  fi
}

function tweak_disable_psglauncher() {
  local screen_type=$1
  local user_id=$2

  log_info "[${screen_type}] Отключение PSGLauncher"

  run_adb shell pm disable-user --user "${user_id}" com.lixiang.psglauncher
  run_adb shell pm clear --user "${user_id}" com.lixiang.psglauncher
}

#################################################################

# Return: app_id\tapp_version_code\tapp_version_name
function get_installed_package_info() {
  local app_id=$1
  local user_id=$2

  #  log_verbose "[${app_id}][user:${user_id}] Получение информации об установленном приложении..."

  local adb_output
  adb_output=$(
    run_adb shell dumpsys package |
      awk -v app_id="$app_id" -v user_id="$user_id" '
      $0 ~ "Package \\[" app_id "\\]" {
        package_found = 1
      }
      package_found && $0 ~ /versionCode=/ {
        split($0, version_code_array, " ")
        for (i in version_code_array) {
          if (version_code_array[i] ~ /^versionCode=/) {
            split(version_code_array[i], vc, "=")
            version_code = vc[2]
            break
          }
        }
      }
      package_found && $0 ~ /versionName=/ {
        version_name = substr($0, index($0, "versionName=") + 12)
      }
      package_found && $0 ~ "User " user_id ":" {
        user_line = $0
        if (user_line ~ /installed=true/) {
          print app_id "\t" version_code "\t" version_name
        }
        package_found = 0
      }
    '
  )

  if [ $? -ne 0 ]; then
    log_error "[${app_id}][user:${user_id}] Ошибка получения информации о приложении"
    exit 1
  fi

  log_verbose "[${app_id}][user:${user_id}] adb_output: ${adb_output}"

  # No output
  if [ -z "${adb_output}" ]; then
    log_verbose "[${app_id}][user:${user_id}] Приложение не установлено"
    return 1
  fi

  echo "${adb_output}"
}

#
# Find app files in PACKAGES_CMA_DIR
# Return: list of files separated by \0
function find_app_files() {
  local app_id=$1

  find "${PACKAGES_CMA_DIR}" -name "${app_id}*.apk" -print0
}

function get_app_files_count() {
  local app_id=$1
  local count_cma

  count_cma=$(find "${PACKAGES_CMA_DIR}" -name "${app_id}*.apk" | wc -l | xargs)

  log_verbose "[${app_id}] Количество файлов приложения: ${count_cma}"

  echo "${count_cma}"
}

function find_app_first_file() {
  local app_id=$1

  # Use _find_app_files and get the first file
  local app_file
  app_file=$(find_app_files "${app_id}" | head -n 1)

  echo "${app_file}"
}

function post_install_app_swiftkey() {
  local screen_type=$1
  local user_id=$2

  run_adb shell ime disable --user "${user_id}" com.baidu.input/.ImeService &&
    run_adb shell ime disable --user "$user_id" com.android.inputmethod.latin/.LatinIME &&
    run_adb shell ime enable --user "${user_id}" com.touchtype.swiftkey/com.touchtype.KeyboardService &&
    run_adb shell ime set --user "${user_id}" com.touchtype.swiftkey/com.touchtype.KeyboardService

  if [ $? -ne 0 ]; then
    log_error "[${screen_type}] Настройка SwiftKey: ошибка"
    return 1
  else
    log_info "[${screen_type}] Настройка SwiftKey: успешно"
  fi
}

function install_apk() {
  local screen_type=$1
  local user_id=$2
  local app_filename=$3

  if [ ! -f "${app_filename}" ]; then
    log_error "[${screen_type}] Файл не найден: ${app_filename}"
    return 1
  fi

  #
  # Get local app info
  #
  local apkanalyzer_str
  apkanalyzer_str=$(run_apkanalyzer apk summary "${app_filename}")

  local app_id
  local app_version_code
  local app_version_name
  app_id=$(echo "${apkanalyzer_str}" | head -n 1 | cut -f1)
  app_version_code=$(echo "${apkanalyzer_str}" | head -n 1 | cut -f2)
  app_version_name=$(echo "${apkanalyzer_str}" | head -n 1 | cut -f3)

  log_verbose "[${screen_type}] [${app_id}] Локальная версия apk: ${app_version_name} (${app_version_code})"

  #
  # Get device app info
  #
  local package_info_output
  package_info_output=$(get_installed_package_info "${app_id}" "${user_id}")

  # if package_info_output not empty
  if [ -n "${package_info_output}" ]; then
    local installed_version_code
    local installed_version_name
    installed_version_code=$(echo "${package_info_output}" | head -n 1 | cut -f2)
    installed_version_name=$(echo "${package_info_output}" | head -n 1 | cut -f3)

    log_verbose "[${screen_type}] [${app_id}] Установленная версия apk: ${installed_version_name} (${installed_version_code})"

    # if version code and version name are the same
    if [ "${app_version_code}" -eq "${installed_version_code}" ] && [ "${app_version_name}" == "${installed_version_name}" ]; then
      if ${FORCE_INSTALL}; then
        log_info "[${screen_type}] [${app_id}] Установленная версия apk совпадает с локальной, но установка принудительно включена, устанавливаем: ${app_version_name} (${app_version_code})"
      else
        log_info "[${screen_type}] [${app_id}] Установленная версия apk совпадает с локальной, пропускаем установку: ${app_version_name} (${app_version_code})"
        return 0
      fi
    fi

    # if installed version code is greater than local version code
    if [ "${installed_version_code}" -gt "${app_version_code}" ]; then
      if ${FORCE_INSTALL}; then
        log_warn "[${screen_type}] [${app_id}] Установленная версия apk (${installed_version_name} (${installed_version_code})) больше локальной (${app_version_name} (${app_version_code})), принудительно устанавливаем"

        # !!! Мы должны удалить старый со ВСЕХ мониторов, а не только с текущего, не используем --user
        if ! run_adb uninstall "${app_id}"; then
          #if ! _run_adb uninstall --user "${user_id}" "${app_id}"; then
          log_error "[${screen_type}] [${app_id}] Удаление старой версии apk: ошибка"
          return 1
        else
          log_info "[${screen_type}] [${app_id}] Удаление старой версии apk: успешно"
        fi
      else
        log_error "[${screen_type}] [${app_id}] Установленная версия apk (${installed_version_name} (${installed_version_code})) больше локальной (${app_version_name} (${app_version_code})), пропускаем установку"
        return 1
      fi
    fi
  fi

  log_info "[${screen_type}] [$app_id] Установка..."

  if ! run_adb install -r -g --user "${user_id}" "${app_filename}"; then
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

    if ! run_adb shell appops set --user "${user_id}" "${app_id}" "${opt}" allow; then
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

function install_carmodapps_app() {
  local screen_type=$1
  local app_id=$2
  local user_id=$3
  local app_filename

  app_filename=$(find_app_first_file "${app_id}")

  if [ -z "${app_filename}" ]; then
    log_error "[${screen_type}] [$app_id] Нет файла для установки"
    return 1
  fi

  install_apk "${screen_type}" "${user_id}" "${app_filename}"
}

function install_custom_packages() {
  local screen_type=$1
  local user_id=$2
  local user_packages_dir
  local app_filename

  user_packages_dir=$(get_custom_packages_dir "${screen_type}")

  log_verbose "[${screen_type}] Проверка папки пользовательских приложений: ${user_packages_dir}"

  # Read all apk files in user_packages_dir
  for app_filename in "${user_packages_dir}"/*.apk; do
    local app_id
    app_id=$(basename "${app_filename}" .apk)

    install_apk "${screen_type}" "${user_id}" "${app_filename}"
  done
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

      tweak_disable_psglauncher "${screen_type}" "${FRONT_MAIN_USER_ID}"
    fi

    # Install all apps
    local apps=("${APPS_ALL_SCREENS[@]}" "${user_apps[@]}")
    local app_id
    for app_id in "${apps[@]}"; do
      install_carmodapps_app "${screen_type}" "${app_id}" "${user_id}"
    done

    # Install custom packages
    install_custom_packages "${screen_type}" "${user_id}"
  done
}

function install_rear() {
  local user_id="${REAR_USER_ID}"
  local apps=("${APPS_ALL_SCREENS[@]}" "${APPS_SCREEN_TYPE_REAR[@]}")

  tweak_disable_psglauncher "${SCREEN_TYPE_REAR}" "${user_id}"

  # Install all apps
  local app_id
  for app_id in "${apps[@]}"; do
    install_carmodapps_app "${SCREEN_TYPE_REAR}" "${app_id}" "${user_id}"
  done

  # Install custom packages
  install_custom_packages "${SCREEN_TYPE_REAR}" "${user_id}"
}

function check_all_apps_exists() {
  local all_apps
  local app_id
  local error_missing_apps=false
  local error_duplicate_apps=false
  local exit_code=0

  all_apps="${APPS_ALL_SCREENS[*]} ${APPS_SCREEN_TYPE_DRIVER[*]} ${APPS_SCREEN_TYPE_COPILOT[*]}${APPS_SCREEN_TYPE_REAR[*]}"
  all_apps=$(fn_unique_str_list "${all_apps}")

  for app_id in ${all_apps}; do
    local count
    count=$(get_app_files_count "${app_id}")

    if [ "${count}" -eq 0 ]; then
      log_error "[${app_id}] Приложение не найдено в папках packages/carmodapps или packages/user"
      error_missing_apps=true
      exit_code=1

    elif [ "${count}" -gt 1 ]; then
      log_error "[${app_id}] Найдено несколько файлов приложения:"

      local app_file
      while IFS= read -r -d '' app_file; do
        log_error "[${app_id}]     ${app_file}"
      done < <(find_app_files "$app_id")

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
    log_error "Для ручного добавления сторонних приложений смотрите инструкцию: $(basename "$0") -h"
  fi

  if ${error_duplicate_apps}; then
    log_error "Удалите дубликаты приложений и повторите попытку"
  fi

  return ${exit_code}
}

function wait_for_device() {
  local product_type
  local cpu_type
  local vin

  log_info "Ожидание подключения устройства..."
  log_warn "!!! Подтвердите подключение на мониторе автомобиля !!!!"

  if ! run_adb wait-for-device; then
    log_error "Устройство не найдено"
    exit 1
  fi

  product_type=$(run_adb shell getprop ro.build.product)
  cpu_type=$(get_cpu_type "${product_type}")
  vin=$(get_vin "${cpu_type}")

  log_info "Устройство найдено: ${cpu_type} (VIN: ${vin})"

  echo "${cpu_type}"
}

function do_display_vin() {
  local cpu_type
  local vin

  cpu_type=$(wait_for_device)
  vin=$(get_vin "${cpu_type}")

  log_info "############################################################"
  log_info "VIN: ${vin}"
  log_info "############################################################"
}

function do_install() {
  local cpu_type

  if ! check_all_apps_exists; then
    exit 1
  fi

  cpu_type=$(wait_for_device)

  case "${cpu_type}" in
  "${CPU_TYPE_FRONT}")
    tweak_set_timezone
    tweak_set_night_mode
    install_front
    ;;
  "${CPU_TYPE_REAR}")
    tweak_set_timezone
    tweak_set_night_mode
    install_rear
    ;;
    # Default will be handled in wait_for_device()
  esac

}

function delete_for_user() {
  local screen_type=$1
  local user_id=$2
  local non_system_apps

  non_system_apps=$(run_adb shell pm list packages --user "${user_id}" -3 | cut -d':' -f2 | tr -d '\r' | tr '\n' ' ')

  if [ -z "$non_system_apps" ]; then
    log_info "[${screen_type}] Нет приложений для удаления"
    return 0
  fi

  log_info "[${screen_type}] Удаление всех приложений, кроме системных..."

  for app_id in ${non_system_apps}; do
    log_info "[${screen_type}] Удаление ${app_id}..."

    if ! run_adb uninstall --user "${user_id}" "${app_id}"; then
      log_error "[${screen_type}] Удаление ${app_id}: ошибка"
      return 1
    else
      log_info "[${screen_type}] Удаление ${app_id}: успешно"
    fi
  done
}

function do_delete() {
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

function do_check_self_updates() {
  log_verbose "Проверка обновлений скрипта..."

  # FIXME: Сделать проверку, сравнение версий,
  #  а также добавить update.sh (может качать с github и запускать?)
}

function do_update() {
  local api_url="https://store.carmodapps.com/api/applications/download"
  local apps_url_list

  mkdir -p "${PACKAGES_CMA_DIR}"

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
    app_id=$(echo "$app_line" | cut -d'|' -f1)
    app_filename=$(echo "$app_line" | cut -d'|' -f2)
    app_url=$(echo "$app_line" | cut -d'|' -f3)

    app_local_filename="${PACKAGES_CMA_DIR}/${app_filename}"
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
    done < <(find_app_files "$app_id")
  done

  log_info "Проверка обновлений приложений: успешно"

}

#################################################################

function usage() {
  cat <<EOF
----------------------------------------------------------------------------
Скрипт для установки приложений CarModApps для автомобилей Li Auto (Lixiang)
Версия: ${VERSION}
Сайт: https://carmodapps.com, Telegram: https://t.me/carmodapps
----------------------------------------------------------------------------

Использование: $(basename "${0}") [options] [<команда>]

По-умолчанию выполняется update + install

Команды:
  vin: Отобразить VIN
  install: Запустить автоматическую установку приложений
  update: Загрузить приложения с сервера CarModApps
  delete: Удалить все не системные приложения

Опции:
  -h, --help: Показать это сообщение
  -v, --verbose: Выводить подробную информацию
  -f, --force: Принудительно установить приложения, даже если они уже установлены

Для добавления своих приложений положите apk в папки:

   packages/custom/driver   Для экрана водителя
   packages/custom/copilot  Для экрана пассажира
   packages/custom/rear     Для заднего экрана

Кастомизация настроек (для продвинутых пользователей):

  1. Создайте файл user_settings.sh
  2. Добавьте в него переопределение переменных
     Пример добавления установки Angry birds из CarModApps на все экраны:
        APPS_ALL_SCREENS+=("com.rovio.angrybirds")
EOF
}

#################################################################

function main() {
  local cmd

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -v | --verbose)
      VERBOSE=true
      ;;
    -f | --force)
      FORCE_INSTALL=true
      ;;
    vin | install | update | delete)
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
    do_check_self_updates
    do_update
  elif [ "${cmd}" == "delete" ]; then
    do_delete
  else
    do_check_self_updates
    do_update
    do_install
    exit 1
  fi
}

main "$@"
