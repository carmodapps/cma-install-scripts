#!/bin/bash

#################################################################
# Settings

# Таймзона по-умолчанию, если не удалось определить таймзону компьютера
DEFAULT_TIMEZONE="Europe/Moscow"

#################################################################
# Разрешения appops для приложений
# Они будут выданы автоматически если в манифесте приложения есть соответствующие разрешения
PERMISSIONS_APPOPS=(
  "REQUEST_INSTALL_PACKAGES"
)

#################################################################
# Настройки активных твиков (можно отключить через config.sh)

TWEAK_SET_TIMEZONE=true
TWEAK_SET_NIGHT_MODE=true
TWEAK_DISABLE_PSGLAUNCHER=true
#TWEAK_IME="com.touchtype.swiftkey/com.touchtype.KeyboardService" #
TWEAK_IME="com.carmodapps.simplekeyboard.inputmethod/.latin.LatinIME"
TWEAK_CHANGE_LOCALE=true

#################################################################
# System vars

ADB="adb"
AAPT="aapt"
FRONT_MAIN_USER_ID=0
FRONT_COPILOT_USER_ID=21473
REAR_USER_ID=0

SCRIPT_REALPATH="$(readlink -f "$0")"
SCRIPT_BASENAME=$(basename "${SCRIPT_REALPATH}")
SCRIPT_DIR=$(dirname "${SCRIPT_REALPATH}")

# read VERSION file
VERSION_FILE="${SCRIPT_DIR}/VERSION"
if [ -f "${VERSION_FILE}" ]; then
  VERSION=$(cat "${VERSION_FILE}")
else
  VERSION="unknown"
fi

PACKAGES_DIR="${SCRIPT_DIR}/packages"
PACKAGES_CMA_DIR="${PACKAGES_DIR}/carmodapps"
PACKAGES_CMA_INDEX_FILE="${PACKAGES_CMA_DIR}/index.txt"
PACKAGES_CUSTOM_SCREEN_TYPE_DRIVER_DIR="${PACKAGES_DIR}/custom/driver"
PACKAGES_CUSTOM_SCREEN_TYPE_COPILOT_DIR="${PACKAGES_DIR}/custom/copilot"
PACKAGES_CUSTOM_SCREEN_TYPE_REAR_DIR="${PACKAGES_DIR}/custom/rear"

OPT_VERBOSE=false
OPT_FORCE_INSTALL=false
OPT_DELETE_BEFORE_INSTALL=false

UPDATE_CHANNEL="release"
UPDATE_CHANNEL_EXTRA_HEADERS=()

#################################################################
# CAR/CPU/Screen types

CAR_TYPE_UNKNOWN="Неизвестный автомобиль"
CAR_TYPE_LIAUTO="LiAuto"

CAR_TYPE_LIAUTO_TAG="LI"
CAR_TYPE_LIAUTO_ZEEKR_TAG="ZEEKR"

ALL_CAR_TYPES_TAGS=(
  "${CAR_TYPE_LIAUTO_TAG}"
  "${CAR_TYPE_LIAUTO_ZEEKR_TAG}"
)

CPU_TYPE_MAIN="Основной CPU"
CPU_TYPE_FRONT="Передний CPU"
CPU_TYPE_REAR="Задний CPU"

SCREEN_TYPE_DRIVER="Экран водителя"
SCREEN_TYPE_COPILOT="Экран пассажира"
SCREEN_TYPE_REAR="Задний экран"

#################################################################
# Setup Platform-specific vars

HOST_TIMEZONE=""

# Determine the platform and set the binary path
case "$(uname -s)" in
Darwin)
  # Mac OS X platform
  HOST_TIMEZONE=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  ADB="${SCRIPT_DIR}/3rd_party/bin/mac/$(uname -m)/adb"
  AAPT="${SCRIPT_DIR}/3rd_party/bin/mac/$(uname -m)/aapt"

  # Remove xattr from adb and aapt
  for bin in "${ADB}" "${AAPT}"; do
    if xattr "${bin}" | grep -q 'com.apple.quarantine'; then
      echo "Удаление xattr: ${bin}"
      xattr -d com.apple.quarantine "${bin}"
    fi
  done
  ;;
Linux)
  # Linux platform
  HOST_TIMEZONE=$(cat /etc/timezone)
  ADB="${SCRIPT_DIR}/3rd_party/bin/linux/adb"
  AAPT="${SCRIPT_DIR}/3rd_party/bin/linux/aapt"
  ;;
*)
  echo "Неизвестная платформа: $(uname -s)"
  exit 1
  ;;
esac

if [ ! -f "${ADB}" ]; then
  echo "ADB не найден: ${ADB}"
  exit 1
fi

if [ ! -f "${AAPT}" ]; then
  echo "AAPT не найден: ${AAPT}"
  exit 1
fi

#################################################################
# Handle Config

CONFIG_FILE="${SCRIPT_DIR}/config.sh"
if [ -f "${CONFIG_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

#################################################################
# Variables which SHOULD NOT be overriden by user

PACKAGES_CMA_DIR="${PACKAGES_DIR}/carmodapps"
PACKAGES_CMA_INDEX_FILE="${PACKAGES_CMA_DIR}/index.txt"

#################################################################
# Logging

LOG_PREFIX="####LiAuto### "

ANSI_GREEN="\033[32m"
ANSI_YELLOW="\033[33m"
ANSI_RED="\033[31m"
ANSI_GRAY="\033[37m"
ANSI_RESET="\033[0m"

function log_info() {
  echo -e "${ANSI_GREEN}${LOG_PREFIX}$1${ANSI_RESET}" >&2
}

function log_warn() {
  echo -e "${ANSI_YELLOW}${LOG_PREFIX}[Предупреждение] $1${ANSI_RESET}" >&2
}

function log_error() {
  echo -e "${ANSI_RED}${LOG_PREFIX}[Ошибка] $1${ANSI_RESET}" >&2
}

function log_verbose() {
  if ${OPT_VERBOSE}; then
    echo -e "${ANSI_GRAY}${LOG_PREFIX}$1${ANSI_RESET}" >&2
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

function log_cmd_with_args() {
  local cmd=$1
  shift
  local args=("$@")
  local cmd_str="$cmd"
  local arg
  for arg in "${args[@]}"; do
    cmd_str+=" '$arg'"
  done
  echo "$cmd_str"
}

function run_cmd() {
  local cmd=$1
  shift

  local cmd_basename
  cmd_basename=$(basename "${cmd}")

  local cmd_with_args
  cmd_with_args=$(log_cmd_with_args "$cmd" "$@")
  log_verbose "${cmd_with_args}"

  local exit_code
  "$cmd" "$@"
  exit_code=$?

  if [ $exit_code -ne 0 ]; then
    log_error "${cmd_with_args} (exit code: ${exit_code})"
    return $exit_code
  fi
}

ADB_CURRENT_SERIAL=""
function run_adb() {
  if [ -z "${ADB_CURRENT_SERIAL}" ]; then
    run_cmd "${ADB}" "$@"
  else
    run_cmd "${ADB}" -s "${ADB_CURRENT_SERIAL}" "$@"
  fi
}

function run_aapt() {
  run_cmd "${AAPT}" "$@"
}

#################################################################
# CPU/Screen types helpers


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

# Get only carmodapps apps for screen type
function get_carmodapps_apps() {
  local screen_type=$1
  local filter

  case "${screen_type}" in
  "${SCREEN_TYPE_DRIVER}")
    filter="driver"
    ;;
  "${SCREEN_TYPE_COPILOT}")
    filter="copilot"
    ;;
  "${SCREEN_TYPE_REAR}")
    filter="rear"
    ;;
  *)
    log_error "[get_carmodapps_apps] Неизвестный тип экрана: ${screen_type}"
    exit 1
    ;;
  esac

  log_verbose "[${screen_type}][get_carmodapps_apps] Получение списка приложений CarModApps..."

  local line
  while IFS= read -r line; do
    local app_id
    local app_filename_basename
    local app_filename
    local app_screen_types
    app_id=$(echo "${line}" | cut -d'|' -f1)
    app_filename_basename=$(echo "${line}" | cut -d'|' -f2)
    app_screen_types=$(echo "${line}" | cut -d'|' -f3)

    app_filename="${PACKAGES_CMA_DIR}/${app_filename_basename}"

    # app_screen_types format: driver,copilot,rear (coma-separated list of screen types)
    if echo "${app_screen_types}" | grep -q "${filter}"; then
      log_verbose "[${screen_type}][get_carmodapps_apps][${app_id} (${app_screen_types}) - OK]"
      echo "${app_filename}"
    else
      log_verbose "[${screen_type}][get_carmodapps_apps][${app_id} (${app_screen_types}) - SKIP]"
    fi

  done < <(cat "${PACKAGES_CMA_INDEX_FILE}")
}

# Get custom apps ids for screen type
function get_custom_screen_apps() {
  local screen_type=$1
  local custom_packages_dir

  custom_packages_dir=$(get_custom_packages_dir "${screen_type}")

  log_verbose "[${screen_type}][get_custom_screen_apps] Проверка папки пользовательских приложений: ${custom_packages_dir}"

  # Collect all custom apps
  local custom_apps_count=0
  local app_filename
  while IFS= read -r -d '' app_filename; do
    echo "${app_filename}"
    log_verbose "[${screen_type}][get_custom_screen_apps] Найдено пользовательское приложение: ${app_filename}"
    custom_apps_count=$((custom_apps_count + 1))
  done < <(find "${custom_packages_dir}" -name "*.apk" -print0)

  log_verbose "[${screen_type}][get_custom_screen_apps] Найдено пользовательских приложений: ${custom_apps_count}"
}

function get_all_screen_apps() {
  local screen_type=$1

  get_carmodapps_apps "${screen_type}"
  get_custom_screen_apps "${screen_type}"
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
# ADB helpers
function adb_get_product_type() {
  local product_type
  product_type=$(run_adb shell getprop ro.build.product)

  if [ -z "${product_type}" ]; then
    log_error "Не удалось считать ro.build.product"
    return 1
  fi

  log_verbose "ro.build.product: ${product_type}"

  echo "${product_type}"
}

function adb_get_cpu_type_liauto() {
  local product_type
  product_type=$(adb_get_product_type)

  case "${product_type}" in
  HU_SS2MAXF)
    echo "${CPU_TYPE_FRONT}"
    ;;
  HU_SS2MAXR)
    echo "${CPU_TYPE_REAR}"
    ;;
  HU_SS2PRO)
    echo "${CPU_TYPE_FRONT}"
    ;;
  HU_SS3)
    echo "${CPU_TYPE_MAIN}"
    ;;
  *)
    log_error "Неизвестный тип CPU: ${product_type}"
    return 1
    ;;
  esac
}

function adb_get_cpu_type() {
  local car_type
  car_type=$(adb_get_car_type)

  case "${car_type}" in
  "${CAR_TYPE_LIAUTO}")
    adb_get_cpu_type_liauto
    ;;
  *)
    log_error "Неизвестный тип автомобиля: ${car_type}"
    echo "${CPU_TYPE_MAIN}"
    ;;
  esac
}

function adb_get_car_type() {
  local ro_product_manufacturer
  ro_product_manufacturer=$(run_adb shell getprop ro.product.manufacturer)

  case "${ro_product_manufacturer}" in
  "LI_AUTO")
    echo "${CAR_TYPE_LIAUTO}"
    ;;
  *)
    echo "${CAR_TYPE_UNKNOWN}"
    ;;
  esac
}

function adb_get_vin() {
  local vin
  vin=$(run_adb shell getprop persist.sys.vehicle.vin)

  if [ -z "${vin}" ]; then
    log_error "VIN не найден"
    exit 1
  fi

  echo "${vin}"
}

# Get connected devices serials
function adb_get_connected_devices() {
  local devices_serials
  devices_serials=$(run_adb devices -l | awk 'NR>1 && $2=="device" {print $1}')

  # if empty
  if [ -z "${devices_serials}" ]; then
    log_verbose "Устройств не обнаружено"
  else
    local serial
    for serial in ${devices_serials}; do
      log_verbose "Найдено устройство: serial: ${serial}"

      echo "$serial"
    done

  fi
}

#Get all available users IDs
function adb_get_users(){
  # SS2-front
  # Users:
  #	  UserInfo{0:Driver:c13} running
  #	  UserInfo{21473:Copilot:1030} running
  #
  # SS2-rear
  # Users:
  #  UserInfo{0:Driver:c13} running
  #
  # SS3
  # Users:
  # 	UserInfo{0:Driver:c13} running
  #	  UserInfo{6174:Rear:1030} running
  #	  UserInfo{21473:Copilot:1030} running
  #
  # Zeekr: TODO
  local users_output
  users_output=$(run_adb shell pm list users)

  # parse lines like "UserInfo{0:Driver:c13} running"
  echo "${users_output}" | awk -F'[{}:]' '/UserInfo/ {print $2}'
}

#################################################################
# Tweaks

function tweak_set_timezone() {
  local timezone
  local origin

  if ! ${TWEAK_SET_TIMEZONE}; then
    log_verbose "Установка часового пояса отключена"
    return 0
  fi

  # if HOST_TIMEZONE is set, use it
  if [ -n "${HOST_TIMEZONE}" ]; then
    timezone="${HOST_TIMEZONE}"
    origin="из компьютера"
  else
    timezone="${DEFAULT_TIMEZONE}"
    origin="по-умолчанию"
  fi

  log_info "Установка часового пояса (${timezone}, ${origin})..."

  if ! run_adb shell service call alarm 3 s16 "${timezone}" >/dev/null; then
    log_error "Установка часового пояса (${timezone}, ${origin}): ошибка"
    return 1
  fi
}

function tweak_set_night_mode() {
  log_info "Установка ночного режима..."

  if ! ${TWEAK_SET_NIGHT_MODE}; then
    log_verbose "Установка ночного режима отключена"
    return 0
  fi

  if ! run_adb shell cmd uimode night yes; then
    log_error "Установка ночного режима: ошибка"
    return 1
  fi
}

function tweak_disable_psglauncher() {
  local screen_type=$1
  local user_id=$2

  if ! ${TWEAK_DISABLE_PSGLAUNCHER}; then
    log_verbose "[${screen_type}] Отключение PSGLauncher отключено"
    return 0
  fi

  log_info "[${screen_type}] Отключение PSGLauncher"

  #run_adb shell pm disable-user --user "${user_id}" com.lixiang.psglauncher
  #run_adb shell pm clear --user "${user_id}" com.lixiang.psglauncher

  # Юзера 21473 указывать не надо...
  run_adb shell pm disable-user com.lixiang.psglauncher
  run_adb shell pm clear com.lixiang.psglauncher

  # Команда для включения PSGLauncher (без --user)
  # adb shell pm enable com.lixiang.psglauncher
}

function tweak_ime() {
  local screen_type=$1
  local user_id=$2

  # if TWEAK_IME is empty
  if [ -z "${TWEAK_IME}" ]; then
    log_verbose "[${screen_type}] Настройка IME отключена"
    return 0
  fi

  log_info "[${screen_type}] Настройка IME (${TWEAK_IME})..."

  run_adb shell ime disable --user "${user_id}" com.baidu.input/.ImeService &&
    run_adb shell ime disable --user "$user_id" com.android.inputmethod.latin/.LatinIME &&
    run_adb shell ime enable --user "${user_id}" "${TWEAK_IME}" &&
    run_adb shell ime set --user "${user_id}" "${TWEAK_IME}"

  if [ $? -ne 0 ]; then
    log_error "[${screen_type}] Настройка IME: ошибка"
    return 1
  fi
}

function tweak_change_locale() {
  local screen_type=$1
  local user_id=$2
  local locale="en_US"

  if ! ${TWEAK_CHANGE_LOCALE}; then
    log_verbose "[${screen_type}] Установка локали отключена"
    return 0
  fi

  log_info "[${screen_type}] Установка локали ${locale}..."

  if ! run_adb shell am start --user "${user_id}" -n "com.carmodapps.carstore/.ChangeSystemLocaleActivity" --es locale "${locale}"; then
    log_error "[${screen_type}] Установка локали ${locale}: ошибка"
    return 1
  fi
}

#################################################################

# Return: app_id"\t"version_code"\t"version_name
function get_installed_package_info() {
  local app_id=$1
  local user_id=$2

  #  log_verbose "[${app_id}][user:${user_id}] Получение информации об установленном приложении..."

  local adb_output
  adb_output=$(
    run_adb shell dumpsys package "$app_id" |
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

# Return: app_id"\t"version_code"\t"version_name
function get_apk_package_info() {
  local file_name=$1
  local aapt_output

  aapt_output=$(
    run_aapt dump badging "${file_name}" | awk -F"'" '
    $1 ~ /package: name=/ { app_id = $2 }
    $3 ~ / versionCode=/ { version_code = $4 }
    $5 ~ / versionName=/ { version_name = $6 }
    END { print app_id "\t" version_code "\t" version_name }
  '
  )

  #  log_verbose "[$(basename "${file_name}")] aapt_output: ${aapt_output}"

  if [ -z "${aapt_output}" ]; then
    log_error "[$(basename "${file_name}")] Ошибка получения информации о приложении"
    exit 1
  fi

  echo "${aapt_output}"
}

# Return permissions, separated by \n
function get_apk_permissions() {
  local file_name=$1
  local aapt_output

  aapt_output=$(
    run_aapt dump badging "${file_name}" | awk -F"'" '/uses-permission: name=/ { print $2 }'
  )

  log_verbose "[$(basename "${file_name}")] aapt_output:\n${aapt_output}"

  if [ -z "${aapt_output}" ]; then
    log_verbose "[$(basename "${file_name}")] Приложение не имеет разрешений"
    return 0
  fi

  echo "${aapt_output}"
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
  local pkginfo_str
  pkginfo_str=$(get_apk_package_info "${app_filename}")

  local app_id
  local app_version_code
  local app_version_name
  app_id=$(echo "${pkginfo_str}" | cut -f1)
  app_version_code=$(echo "${pkginfo_str}" | cut -f2)
  app_version_name=$(echo "${pkginfo_str}" | cut -f3)

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
    installed_version_code=$(echo "${package_info_output}" | cut -f2)
    installed_version_name=$(echo "${package_info_output}" | cut -f3)

    log_verbose "[${screen_type}] [${app_id}] Установленная версия apk: ${installed_version_name} (${installed_version_code})"

    # if version code and version name are the same
    if [ "${app_version_code}" -eq "${installed_version_code}" ] && [ "${app_version_name}" == "${installed_version_name}" ]; then
      if ${OPT_FORCE_INSTALL}; then
        log_info "[${screen_type}] [${app_id}] Установленная версия apk совпадает с локальной, но установка принудительно включена, устанавливаем: ${app_version_name} (${app_version_code})"
      else
        log_info "[${screen_type}] [${app_id}] Установленная версия apk совпадает с локальной, пропускаем установку: ${app_version_name} (${app_version_code})"
        return 0
      fi
    fi

    # if installed version code is greater than local version code
    if [ "${installed_version_code}" -gt "${app_version_code}" ]; then
      if ${OPT_FORCE_INSTALL}; then
        log_warn "[${screen_type}] [${app_id}] Установленная версия apk (${installed_version_name} (${installed_version_code})) больше локальной (${app_version_name} (${app_version_code})), принудительно устанавливаем"

        log_info "[${screen_type}] [${app_id}] Удаление старой версии apk..."
        # !!! Мы должны удалить старый со ВСЕХ мониторов, а не только с текущего, не используем --user
        if ! run_adb uninstall "${app_id}"; then
          #if ! _run_adb uninstall --user "${user_id}" "${app_id}"; then
          log_error "[${screen_type}] [${app_id}] Удаление старой версии apk: ошибка"
          return 1
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
  fi

  # Check APPOPS_xxx
  local appops=() # Required appops for this app
  local opt
  for opt in "${PERMISSIONS_APPOPS[@]}"; do
    if get_apk_permissions "${app_filename}" | grep -q "${opt}"; then
      appops+=("${opt}")
    fi
  done

  for opt in "${appops[@]}"; do
    log_info "[${screen_type}] [$app_id] Выдача разрешения ${opt}..."

    if ! run_adb shell appops set --user "${user_id}" "${app_id}" "${opt}" allow; then
      log_error "[${screen_type}] [$app_id] Выдача разрешения ${opt}: ошибка"
      return 1
    fi
  done
}

function install_custom_packages() {
  local screen_type=$1
  local user_id=$2

  custom_packages_dir=$(get_custom_packages_dir "${screen_type}")

  log_info "[${screen_type}] Проверка папки пользовательских приложений: ${custom_packages_dir}"

  # Collect all custom apps
  local custom_apps_count=0
  local custom_apps=()
  local app_filename
  while IFS= read -r app_filename; do
    custom_apps+=("${app_filename}")
    custom_apps_count=$((custom_apps_count + 1))
  done < <(get_custom_screen_apps "${screen_type}")

  log_verbose "[${screen_type}] Найдено пользовательских приложений: ${custom_apps_count}"

  for app_filename in "${custom_apps[@]}"; do
    install_apk "${screen_type}" "${user_id}" "${app_filename}"
  done

  if [ ${custom_apps_count} -eq 0 ]; then
    log_info "[${screen_type}] Нет пользовательских приложений"
  else
    log_info "[${screen_type}] Обработано пользовательских приложений: ${custom_apps_count}"
  fi
}

function install_front() {
  local users=("${FRONT_MAIN_USER_ID}" "${FRONT_COPILOT_USER_ID}")

  local user_id
  for user_id in "${users[@]}"; do
    local screen_type

    if [ "${user_id}" == "${FRONT_MAIN_USER_ID}" ]; then
      screen_type="${SCREEN_TYPE_DRIVER}"
    else
      screen_type="${SCREEN_TYPE_COPILOT}"
    fi

    # Install all apps
    local apps=()
    while IFS= read -r line; do
      apps+=("$line")
    done < <(get_carmodapps_apps "${screen_type}")

    local app_filename
    for app_filename in "${apps[@]}"; do
      install_apk "${screen_type}" "${user_id}" "${app_filename}"
    done

    # Install custom packages
    install_custom_packages "${screen_type}" "${user_id}"

    # Run at the end, because swiftkey is installed, but may be not available
    tweak_ime "${screen_type}" "${user_id}"

    tweak_change_locale "${screen_type}" "${user_id}"
  done

  # Disable PSG Launcher
  tweak_disable_psglauncher "${screen_type}" "${FRONT_COPILOT_USER_ID}"
}

function install_rear() {
  local screen_type="${SCREEN_TYPE_REAR}"
  local user_id="${REAR_USER_ID}"

  tweak_disable_psglauncher "${screen_type}" "${user_id}"

  # Install all apps
  local apps=()
  while IFS= read -r line; do
    apps+=("$line")
  done < <(get_carmodapps_apps "${screen_type}")

  local app_filename
  for app_filename in "${apps[@]}"; do
    install_apk "${screen_type}" "${user_id}" "${app_filename}"
  done

  # Install custom packages
  install_custom_packages "${screen_type}" "${user_id}"

  # Run at the end, because swiftkey is installed, but may be not available
  tweak_ime "${screen_type}" "${user_id}"

  tweak_change_locale "${screen_type}" "${user_id}"
}

function do_display_vin() {
  local cpu_type
  local vin

  cpu_type=$(adb_get_cpu_type)
  vin=$(adb_get_vin)

  log_info "============================================================"
  log_info "VIN: ${vin} (${cpu_type})"
  log_info "============================================================"
}

function do_install() {
  local cpu_type

  cpu_type=$(adb_get_cpu_type)

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
  default)
    log_error "Неизвестный тип CPU: ${cpu_type}"
    exit 1
    ;;
  esac

}

function do_delete() {
  local car_type
  local cpu_type
  local users
  car_type=$(adb_get_car_type)
  cpu_type=$(adb_get_cpu_type)
  users=$(adb_get_users)

  log_info "Удаление всех приложений, кроме системных..."

  for user_id in ${users}; do
    log_info "[${car_type}][$cpu_type][user:${user_id}] Удаление всех приложений, кроме системных..."

    local non_system_apps

    non_system_apps=$(run_adb shell pm list packages --user "${user_id}" -3 | cut -d':' -f2)

    if [ -z "$non_system_apps" ]; then
      log_info "[${car_type}][$cpu_type][user:${user_id}] Нет приложений для удаления"
    else

      log_info "[${car_type}][$cpu_type][user:${user_id}] Удаление всех приложений, кроме системных..."

      for app_id in ${non_system_apps}; do
        log_info "[${car_type}][$cpu_type][user:${user_id}] Удаление ${app_id}..."

        if ! run_adb uninstall --user "${user_id}" "${app_id}"; then
          log_error "[${car_type}][$cpu_type][user:${user_id}] Удаление ${app_id}: ошибка"
        fi
      done
    fi

  done
}

function clear_for_screen() {
  local screen_type=$1
  local user_id=$2
  local non_system_apps
  local keep_app_ids=()
  local app_id

  non_system_apps=$(run_adb shell pm list packages --user "${user_id}" -3 | cut -d':' -f2)

  while IFS= read -r app_filename; do
    log_verbose "[${screen_type}][clear_for_screen] All app: ${app_filename}"

    local pkginfo_str
    pkginfo_str=$(get_apk_package_info "${app_filename}")

    local app_id
    app_id=$(echo "${pkginfo_str}" | cut -f1)

    keep_app_ids+=("${app_id}")

  done < <(get_all_screen_apps "${screen_type}")

  for app_id in ${non_system_apps}; do
    if ! echo "${keep_app_ids[@]}" | grep -q "${app_id}"; then
      log_warn "[${screen_type}][$app_id] Удаление..."

      if ! run_adb uninstall --user "${user_id}" "${app_id}"; then
        log_error "[${screen_type}][$app_id] Удаление: ошибка"
        return 1
      fi
    else
      log_info "[${screen_type}][$app_id] Удаление не требуется"
    fi
  done
}

function do_clear() {
  local cpu_type

  cpu_type=$(adb_get_cpu_type)

  log_info "[${cpu_type}] Удаление сторонних приложений кроме CarModApps и пользовательских..."

  case "${cpu_type}" in
  "${CPU_TYPE_FRONT}")
    clear_for_screen "${SCREEN_TYPE_DRIVER}" "${FRONT_MAIN_USER_ID}"
    clear_for_screen "${SCREEN_TYPE_COPILOT}" "${FRONT_COPILOT_USER_ID}"
    ;;
  "${CPU_TYPE_REAR}")
    clear_for_screen "${SCREEN_TYPE_REAR}" "${REAR_USER_ID}"
    ;;
  default)
    log_error "[do_clear] Неизвестный тип CPU: ${cpu_type}"
    exit 1
    ;;
  esac
}

# Check if network connection is available
function has_network_connection() {
  local ping_host="yandex.ru"
  local ping_count=1
  local ping_timeout=1

  if ping -c "${ping_count}" -W "${ping_timeout}" "${ping_host}" >/dev/null 2>&1; then
    log_verbose "Сетевое соединение доступно"
    return 0
  else
    log_verbose "Сетевое соединение недоступно"
    return 1
  fi
}

function do_check_self_updates() {
  local server_version_url="https://raw.githubusercontent.com/carmodapps/liauto-install-scripts/master/VERSION"

  log_verbose "Проверка обновлений скрипта..."

  local server_version
  server_version=$(run_cmd curl -s "${server_version_url}")

  if [ -z "${server_version}" ]; then
    log_error "Не удалось получить версию скрипта с сервера"
    return 0
  fi

  if [ "${server_version}" == "${VERSION}" ]; then
    log_info "Скрипт обновлен до последней версии (${VERSION})"
  else
    echo -e -n "${ANSI_YELLOW}"
    echo "============================================================"
    echo " Доступно обновление скрипта!"
    echo ""
    echo " Установленная версия: ${VERSION}"
    echo " Новая версия: ${server_version}"
    echo ""
    echo " Скачайте новую версию скрипта по ссылке https://github.com/carmodapps/liauto-install-scripts/archive/master.zip"
    echo " Или выполните команду \"git pull\" в папке со скриптом, если вы используете git"
    echo "============================================================"
    echo -e -n "${ANSI_RESET}"
  fi

  # FIXME: Сделать проверку, сравнение версий,
  #  а также добавить update.sh (может качать с github и запускать?)
}

function do_update_for_car_tag() {
  local car_tag=$1
  local api_url="https://store.carmodapps.com/api/applications/download?carModel=${car_tag}"

  local headers=(
    "Accept: text/plain"
  )
  local car_packages_cma_dir="${PACKAGES_CMA_DIR}/${car_tag}"
  local log_prefix="[${car_tag}][$UPDATE_CHANNEL]"

  mkdir -p "${car_packages_cma_dir}"

  log_info "Проверка обновлений приложений, автомобиль: $car_tag, канал: $UPDATE_CHANNEL..."

  # if UPDATE_CHANNEL!=release
  if [ "${UPDATE_CHANNEL}" != "release" ]; then
    api_url="${api_url}&updateChannel=${UPDATE_CHANNEL}"
  fi

  # Array to store curl command parameters
  local curl_params
  curl_params=(-s -G)

  # Add headers, add all from UPDATE_CHANNEL_EXTRA_HEADERS
  for line in "${headers[@]}" "${UPDATE_CHANNEL_EXTRA_HEADERS[@]}"; do
    curl_params+=(-H "${line}")
  done

  local tmp_index_file
  tmp_index_file=$(mktemp)
  log_verbose "${log_prefix} tmp_index_file: ${tmp_index_file}"

  curl_params+=(
    -o "${tmp_index_file}"
    -w "%{http_code}"
    "${api_url}"
  )

  # Execute the curl command with expanded array parameters
  local http_status_code
  http_status_code=$(run_cmd curl "${curl_params[@]}")

  if [ "${http_status_code}" != "200" ]; then
    log_error "${log_prefix} Ошибка получения списка приложений: (HTTP ${http_status_code}): $(cat "${tmp_index_file}")"
    return 1
  fi

  local apps_url_list
  apps_url_list=$(cat "${tmp_index_file}")

  # Clean index file
  echo -n "" >"${PACKAGES_CMA_INDEX_FILE}"

  local app_line
  for app_line in ${apps_url_list}; do
    local app_id
    local app_filename
    local app_url
    local app_local_filename
    local app_local_filename_basename
    local app_screens
    local app_upd_channel

    if [ -z "${app_line}" ]; then
      continue
    fi

    # app_line format: "app_id|app_filename|app_url"
    app_id=$(echo "$app_line" | cut -d'|' -f1)
    app_filename=$(echo "$app_line" | cut -d'|' -f2)
    app_url=$(echo "$app_line" | cut -d'|' -f3)
    app_screens=$(echo "$app_line" | cut -d'|' -f4)
    app_upd_channel=$(echo "$app_line" | cut -d'|' -f5)

    app_local_filename="${car_packages_cma_dir}/${app_filename}"
    app_local_filename_basename=$(basename "${app_local_filename}")

    if [ -f "${app_local_filename}" ]; then
      log_info "${log_prefix}[${app_id}]  ($app_upd_channel) Уже загружен, пропускаем..."
    else
      log_info "${log_prefix}[${app_id}]  ($app_upd_channel) Загрузка..."

      if ! curl -s -o "${app_local_filename}" "${app_url}"; then
        log_error "${log_prefix}[${app_id}]  ($app_upd_channel) Загрузка: ошибка"
        # Exit from script, we already cleaned index file
        exit 1
      fi
    fi

    # Save to index file
    echo "${app_id}|${app_local_filename_basename}|${app_screens}" >>"${PACKAGES_CMA_INDEX_FILE}"

    # Remove old app files
    local old_app_file
    while IFS= read -r -d '' old_app_file; do
      local old_app_file_basename
      old_app_file_basename=$(basename "${old_app_file}")
      if [ "${old_app_file}" == "${app_local_filename}" ]; then
        # This is current app file, skip
        continue
      fi
      log_warn "${log_prefix}[${app_id}] Удаление старого файла ${old_app_file_basename}..."
      rm -f "${old_app_file}"
    done < <(find_app_files "$app_id")
  done

}
function do_update() {
  # foreach ALL_CAR_TYPES_TAGS
  local car_tag
  for car_tag in "${ALL_CAR_TYPES_TAGS[@]}"; do
    do_update_for_car_tag "${car_tag}"
  done
}


# Wait for device and return line for each device:
# <serial>\t<cpu_type>
function wait_for_devices() {

  log_info "Ожидание подключения устройств..."

  echo -e -n "${ANSI_YELLOW}"
  echo "============================================================"
  echo "!!!   Подтвердите подключение на мониторах автомобиля   !!!!"
  echo "============================================================"
  echo -e -n "${ANSI_RESET}"

  while true; do
    local devices_serials
    devices_serials=$(adb_get_connected_devices)

    # if empty
    if [ -z "${devices_serials}" ]; then
      log_verbose "Устройств не обнаружено, повтор через 1 секунду..."
      sleep 1
    else
      log_info "============================================================"
      local serial
      for serial in ${devices_serials}; do
        local cpu_type
        local car_type

        ADB_CURRENT_SERIAL="${serial}"

        cpu_type=$(adb_get_cpu_type)
        car_type=$(adb_get_car_type)
        log_info "Найдено устройство: ${car_type} ${cpu_type} (${serial})"
      done
      log_info "============================================================"

      ADB_CURRENT_SERIAL=""

      break
    fi
  done

}

function exec_on_all_devices() {
  local cmd=$1
  shift
  local devices_serials

  devices_serials=$(adb_get_connected_devices)
  if [ -z "${devices_serials}" ]; then
    log_error "Устройств не обнаружено"
    exit 1
  fi

  local serial
  for serial in ${devices_serials}; do
    ADB_CURRENT_SERIAL="${serial}"

    local cpu_type
    cpu_type=$(adb_get_cpu_type)

    log_verbose "${cmd} ${serial} ${cpu_type}"

    if ! "${cmd}" "${cpu_type}" "$@"; then
      log_error "${cmd} ${serial} ${cpu_type}"
      return 1
    fi
  done
  ADB_CURRENT_SERIAL=""
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
  delete: Удалить ВСЕ не системные приложения, включая CarModApps и пользовательские приложения
  clear: Удалить все сторонние приложения, кроме CarModApps и пользовательских приложений (ТОЛБКО для экспертов!)

 Общие опции:
  -h, --help: Показать это сообщение
  -v, --verbose: Выводить подробную информацию
  -f, --force: Принудительно установить приложения, даже если они уже установлены

Опции при запуске без команды:
  -d, Выполнить удаление ВСЕХ не системных приложений перед установкой

Для добавления своих приложений положите apk в папки:

   packages/custom/driver   Для экрана водителя
   packages/custom/copilot  Для экрана пассажира
   packages/custom/rear     Для заднего экрана

Кастомизация настроек (для продвинутых пользователей):

  1. Создайте файл config.sh
  2. Добавьте в него переопределение переменных

  Пример файла можно посмотреть в config.sh.example

EOF
}

#################################################################

function main() {
  local cmd

  if [ "${UPDATE_CHANNEL}" != "release" ]; then
    log_warn "============================================================"
    log_warn "Вы используете канал обновлений: ${UPDATE_CHANNEL}"
    log_warn "============================================================"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -v | --verbose)
      OPT_VERBOSE=true
      ;;
    -f | --force)
      OPT_FORCE_INSTALL=true
      ;;
    -d)
      OPT_DELETE_BEFORE_INSTALL=true
      ;;
    vin | install | update | delete | clear)
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

  case "${cmd}" in
  vin)
    wait_for_devices
    exec_on_all_devices do_display_vin
    ;;
  install)
    wait_for_devices
    if ${OPT_DELETE_BEFORE_INSTALL}; then
      exec_on_all_devices do_delete
    fi
    exec_on_all_devices do_install
    exec_on_all_devices do_display_vin
    ;;
  update)
    do_check_self_updates
    do_update
    ;;
  delete)
    wait_for_devices
    exec_on_all_devices do_delete
    ;;
  clear)
    wait_for_devices
    exec_on_all_devices do_clear
    ;;
  *)
    if has_network_connection; then
      do_check_self_updates
      do_update
    else
      log_warn "Сетевое соединение недоступно, пропускаем обновление скрипта и приложений"
    fi

    wait_for_devices

    if ${OPT_DELETE_BEFORE_INSTALL}; then
      exec_on_all_devices do_delete
    fi

    exec_on_all_devices do_install
    exec_on_all_devices do_display_vin
    ;;
  esac

}

main "$@"
