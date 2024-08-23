#!/bin/bash
# shellcheck disable=SC2155

#################################################################
# Settings

# Таймзона по-умолчанию, если не удалось определить таймзону компьютера
DEFAULT_TIMEZONE="Europe/Moscow"

#################################################################
# Разрешения appops для приложений
# Они будут выданы автоматически если в манифесте приложения есть соответствующие разрешения
PERMISSIONS_APPOPS=(
  "android.permission.REQUEST_INSTALL_PACKAGES"
  "android.permission.SYSTEM_ALERT_WINDOW"
)

#################################################################
# Настройки активных твиков (можно отключить через config.sh)

TWEAK_IME_APP="com.carmodapps.simplekeyboard.inputmethod/.latin.LatinIME"

DISABLED_TWEAKS=(
)

#################################################################
# System vars

ADB="adb"
AAPT="aapt"

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

OPT_VERBOSE=false
OPT_FORCE_INSTALL=false
OPT_DELETE_BEFORE_INSTALL=false

UPDATE_CHANNEL="release"
UPDATE_CHANNEL_EXTRA_HEADERS=()

#################################################################
# CAR/CPU/Screen types

CAR_TYPE_UNKNOWN="Неизвестный автомобиль"
CAR_TYPE_LIAUTO="LiAuto"
CAR_TYPE_ZEEKR="Zeekr"

CAR_TYPE_LIAUTO_TAG="LI"
CAR_TYPE_ZEEKR_TAG="ZEEKR"

ALL_CAR_TYPES_TAGS=(
  "${CAR_TYPE_LIAUTO_TAG}"
  "${CAR_TYPE_ZEEKR_TAG}"
)

CPU_TYPE_MAIN="Основной CPU"
CPU_TYPE_REAR="Задний CPU"

SCREEN_TYPE_DRIVER="Экран водителя"
SCREEN_TYPE_COPILOT="Экран пассажира"
SCREEN_TYPE_REAR="Задний экран"

SCREEN_TYPE_DRIVER_TAG="driver"
SCREEN_TYPE_COPILOT_TAG="copilot"
SCREEN_TYPE_REAR_TAG="rear"

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
# Logging

LOG_PREFIX="####CMA### "

ANSI_GREEN="\033[32m"
ANSI_YELLOW="\033[33m"
ANSI_RED="\033[31m"
ANSI_GRAY="\033[37m"
ANSI_RESET="\033[0m"

function log_info() {
  echo -e "${ANSI_GREEN}${LOG_PREFIX}[I] $1${ANSI_RESET}" >&2
}

function log_warn() {
  echo -e "${ANSI_YELLOW}${LOG_PREFIX}[W] $1${ANSI_RESET}" >&2
}

function log_error() {
  echo -e "${ANSI_RED}${LOG_PREFIX}[E] $1${ANSI_RESET}" >&2
}

function log_verbose() {
  if ${OPT_VERBOSE}; then
    echo -e "${ANSI_GRAY}${LOG_PREFIX}[V] $1${ANSI_RESET}" >&2
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
  # TODO: We got this worning, so send stderr to /dev/null
  #  AndroidManifest.xml:41: error: ERROR getting 'android:name' attribute: attribute is not an integer value
  run_cmd "${AAPT}" "$@" 2>/dev/null
}

#################################################################
# Car/CPU/Screen types helpers

function get_car_tag() {
  local car_type=$1

  case "${car_type}" in
  "${CAR_TYPE_LIAUTO}")
    echo "${CAR_TYPE_LIAUTO_TAG}"
    ;;
  "${CAR_TYPE_ZEEKR}")
    echo "${CAR_TYPE_ZEEKR_TAG}"
    ;;
  *)
    log_error "get_car_tag: неизвестный тип автомобиля: ${car_type}"
    exit 1
    ;;
  esac
}

function get_screen_type_liauto_ss2() {
  local cpu_type=$1
  local user_id=$2

  case "${cpu_type}" in
  "${CPU_TYPE_MAIN}")

    if [ "${user_id}" -eq 21473 ]; then
      echo "${SCREEN_TYPE_COPILOT}"
    elif [ "${user_id}" -eq 0 ]; then
      echo "${SCREEN_TYPE_DRIVER}"
    else
      log_error "get_screen_type_liauto_ss2: неизвестный user_id: ${user_id}"
      exit 1
    fi
    ;;

  "${CPU_TYPE_REAR}")
    echo "${SCREEN_TYPE_REAR}"
    ;;
  esac
}

function get_screen_type_liauto_ss3() {
  local cpu_type=$1
  local user_id=$2

  if [ "${cpu_type}" != "${CPU_TYPE_MAIN}" ]; then
    log_error "get_screen_type_liauto_ss3: неизвестный cpu_type: ${cpu_type}"
    exit 1
  fi

  if [ "${user_id}" -eq 21473 ]; then
    echo "${SCREEN_TYPE_COPILOT}"
  elif [ "${user_id}" -eq 6174 ]; then
    echo "${SCREEN_TYPE_REAR}"
  elif [ "${user_id}" -eq 0 ]; then
    echo "${SCREEN_TYPE_DRIVER}"
  else
    log_error "get_screen_type_liauto_ss3: неизвестный user_id: ${user_id}"
    exit 1
  fi
}

function get_screen_type_liauto() {
  local cpu_type=$1
  local user_id=$2
  local platform # ro.boot.board.platform

  platform=$(run_adb shell getprop ro.boot.board.platform) # SS2MAX/SS2PRO/SS3

  case "${platform}" in
  "SS2MAX"|"SS2PRO")
    get_screen_type_liauto_ss2 "${cpu_type}" "${user_id}"
    ;;
  "SS3")
    get_screen_type_liauto_ss3 "${cpu_type}" "${user_id}"
    ;;
  *)
    log_error "get_screen_type_liauto: неизвестная платформа: '${platform}'"
    exit 1
    ;;
  esac
}

function get_screen_type_zeekr() {
  local cpu_type=$1
  local user_id=$2

  # Zeekr: - only driver screen
  echo "${SCREEN_TYPE_DRIVER}"
}

function get_screen_type() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3

  case "${car_type}" in
  "${CAR_TYPE_LIAUTO}")
    get_screen_type_liauto "${cpu_type}" "${user_id}"
    ;;
  "${CAR_TYPE_LIAUTO_ZEEKR}")
    get_screen_type_zeekr "${cpu_type}" "${user_id}"
    ;;
  *)
    log_error "[${car_type}][$cpu_type][user:${user_id}] get_screen_type: use default ${SCREEN_TYPE_DRIVER}"
    echo "${SCREEN_TYPE_DRIVER}"
    ;;
  esac
}

function get_screen_type_tag() {
  local screen_type=$1

  case "${screen_type}" in
  "${SCREEN_TYPE_DRIVER}")
    echo "${SCREEN_TYPE_DRIVER_TAG}"
    ;;
  "${SCREEN_TYPE_COPILOT}")
    echo "${SCREEN_TYPE_COPILOT_TAG}"
    ;;
  "${SCREEN_TYPE_REAR}")
    echo "${SCREEN_TYPE_REAR_TAG}"
    ;;
  *)
    log_error "get_screen_type_tag: неизвестный тип экрана: ${screen_type}"
    exit 1
    ;;
  esac
}

#################################################################
# ADB helpers

function adb_get_cpu_type_liauto() {
  local product_type
  product_type=$(run_adb shell getprop ro.product.model)

  case "${product_type}" in
  HU_SS2MAXF)
    echo "${CPU_TYPE_MAIN}"
    ;;
  HU_SS2MAXR)
    echo "${CPU_TYPE_REAR}"
    ;;
  HU_SS2PRO)
    echo "${CPU_TYPE_MAIN}"
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
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
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

  log_info "[${car_type}][$cpu_type][user:${user_id}] Установка часового пояса (${timezone}, ${origin})..."

  if ! run_adb shell service call alarm 3 s16 "${timezone}" >/dev/null; then
    log_error "[${car_type}][$cpu_type][user:${user_id}] Установка часового пояса (${timezone}, ${origin}): ошибка"
    return 1
  fi
}

function tweak_set_night_mode() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3

  log_info "[${car_type}][$cpu_type][user:${user_id}] Установка ночного режима..."

  if ! run_adb shell cmd uimode night yes; then
    log_error "[${car_type}][$cpu_type][user:${user_id}] Установка ночного режима: ошибка"
    return 1
  fi
}

function tweak_liauto_disable_psglauncher() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3

  log_info "[${car_type}][$cpu_type][user:${user_id}] Отключение PSGLauncher"

  #run_adb shell pm disable-user --user "${user_id}" com.lixiang.psglauncher
  #run_adb shell pm clear --user "${user_id}" com.lixiang.psglauncher

  # Юзера 21473 указывать не надо...
  run_adb shell pm disable-user com.lixiang.psglauncher
  run_adb shell pm clear com.lixiang.psglauncher

  # Команда для включения PSGLauncher (без --user)
  # adb shell pm enable com.lixiang.psglauncher
}

function tweak_ime() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3

  log_info "[${car_type}][$cpu_type][user:${user_id}] Настройка IME (${TWEAK_IME_APP})..."

  run_adb shell ime disable --user "${user_id}" com.baidu.input/.ImeService &&
    run_adb shell ime disable --user "$user_id" com.android.inputmethod.latin/.LatinIME &&
    run_adb shell ime enable --user "${user_id}" "${TWEAK_IME_APP}" &&
    run_adb shell ime set --user "${user_id}" "${TWEAK_IME_APP}"

  if [ $? -ne 0 ]; then
    log_error "[${car_type}][$cpu_type][user:${user_id}] Настройка IME: ошибка"
    return 1
  fi
}

function tweak_change_locale() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local locale="en_US"

  log_info "[${car_type}][$cpu_type][user:${user_id}] Установка локали ${locale}..."

  if ! run_adb shell am start --user "${user_id}" -n "com.carmodapps.carstore/.ChangeSystemLocaleActivity" --es locale "${locale}"; then
    log_error "[${car_type}][$cpu_type][user:${user_id}] Установка локали ${locale}: ошибка"
    return 1
  fi
}

#################################################################

function get_tweaks_liauto() {
  local cpu_type=$1
  local user_id=$2
  local screen_type

  screen_type=$(get_screen_type "${CAR_TYPE_LIAUTO}" "${cpu_type}" "${user_id}")

  case "${screen_type}" in
  "${SCREEN_TYPE_DRIVER}")
    echo "tweak_change_locale"
    echo "tweak_set_timezone"
    echo "tweak_set_night_mode"
    ;;
  "${SCREEN_TYPE_COPILOT}")
    echo "tweak_liauto_disable_psglauncher"
    ;;
  "${SCREEN_TYPE_REAR}")
    echo "tweak_set_timezone"
    echo "tweak_liauto_disable_psglauncher"
    ;;
  esac

  # IME - for all users
  echo "tweak_ime"
}

function get_tweaks_zeekr() {
  local cpu_type=$1
  local user_id=$2

  # TODO: Implement
}

function get_tweaks() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3

  case "${car_type}" in
  "${CAR_TYPE_LIAUTO}")
    get_tweaks_liauto "${cpu_type}" "${user_id}"
    ;;
  "${CAR_TYPE_LIAUTO_ZEEKR}")
    get_tweaks_zeekr "${cpu_type}" "${user_id}"
    ;;
  *)
    log_warn "No tweaks for car type: ${car_type}"
    exit 1
    ;;
  esac
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

    log_verbose "[$(basename "${file_name}")] aapt_output: ${aapt_output}"

  if [ -z "${aapt_output}" ]; then
    log_error "[$(basename "${file_name}")] Ошибка получения информации о приложении"
    exit 1
  fi

  echo "${aapt_output}"
}

# Return "true"/"false"
function get_badging_user_field_value() {
  local app_id=$1
  local user_id=$2
  local field=$3

  # adb shell dumpsys package ${app_id}
  # Packages:
  #   Package [com.carmodapps.cmalauncher]
  #     User 0: ceDataInode=1357657 installed=true hidden=false suspended=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false
  #     User 21473: ceDataInode=0 installed=false hidden=false suspended=false distractionFlags=0 stopped=true notLaunched=true enabled=3 instant=false virtual=false

  local value
  value=$(run_adb shell dumpsys package "${app_id}" |
   awk -v app="$app_id" -v user="$user_id" -v field="$field" '
    $0 ~ "Package \\[" app "\\]" {package_found=1}
    package_found && $0 ~ "User " user ":" {user_found=1}
    user_found && $0 ~ field "=" {
        split($0, fields, " ")
        for (i in fields) {
            if (fields[i] ~ "^" field "=") {
                split(fields[i], kv, "=")
                print kv[2]
            }
        }
        exit
    }')

  log_verbose "dumpsys_package_get_user_field_value: [${app_id}][user:${user_id}] '${field}' = '${value}'"

  if [ -z "${value}" ]; then
    log_error "dumpsys_package_get_user_field_value: [${app_id}][user:${user_id}] Поле ${field} не найдено"
    exit 1
  fi

  echo "${value}"
}

function get_app_requested_permissions() {
  local app_id=$1

  run_adb shell dumpsys package "$app_id" |
    awk -v app_id="$app_id"  '
      $0 ~ "Package \\[" app_id "\\]" {
        package_found = 1
      }
      package_found && /requested permissions:/ {
        in_section=1
        next
      }
      in_section && /install permissions:/ {
        in_section=0
        package_found=0
      }
      in_section && /^[ ]+/ {
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          print $0
      }
    '
}

function get_app_install_permissions() {
  local app_id=$1

  run_adb shell dumpsys package "$app_id" |
    awk -v app_id="$app_id"  '
      $0 ~ "Package \\[" app_id "\\]" {
        package_found = 1
      }
      package_found && /install permissions:/ {
        in_section=1
        next
      }
      in_section && /User/ {
        in_section=0
        package_found=0
      }
      in_section && /^[ ]+/ {
          gsub(/^[ \t]+|[ \t]+$/, "", $0)
          print $0
      }
    '
}

function get_app_user_runtime_permissions() {
  local app_id=$1
  local user_id=$2

  run_adb shell dumpsys package "$app_id" |
    awk -v app_id="$app_id" -v user="$user_id" '
      $0 ~ "Package \\[" app_id "\\]" {
        package_found = 1
      }
      package_found && $0 ~ "User " user ":" {user_found=1}
      user_found && /runtime permissions:/ {in_section=1; next}
      in_section && $0 !~ /.permission./ {in_section=0; user_found=0}
      in_section {
        gsub(/^[ \t]+|[ \t]+$/, "", $0) # remove spaces

        split($0, parts, ": ")
        permission = parts[1]

        match(parts[2], /granted=[^,]+/)
        granted = substr(parts[2], RSTART+8, RLENGTH-8)


        print permission ":" granted
      }
    '
}

#
# Find app files in provided dir
# Return: list of files separated by \0
function find_app_files() {
  local dir=$1
  local app_id=$2

  find "${dir}" -name "${app_id}-*.apk" -print0
}

function get_app_files_count() {
  local dir=$1
  local app_id=$2
  local count_cma

  count_cma=$(find "${dir}" -name "${app_id}-*.apk" | wc -l | xargs)

  log_verbose "[${app_id}] Количество файлов приложения: ${count_cma} (${dir})"

  echo "${count_cma}"
}

function find_app_first_file() {
  local dir=$1
  local app_id=$2

  # Use _find_app_files and get the first file
  local app_file
  app_file=$(find_app_files "${dir}" "${app_id}" | head -n 1)

  echo "${app_file}"
}

function install_apk() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local app_filename=$4
  local screen_type=$(get_screen_type "${car_type}" "${cpu_type}" "${user_id}")
  #local log_prefix="[${car_type}][$cpu_type][user:${user_id}] ${screen_type} -"
  local log_prefix="[${car_type}][$cpu_type] ${screen_type} -"

  if [ ! -f "${app_filename}" ]; then
    log_error "install_apk Файл не найден: ${app_filename}"
    return 1
  fi

  #
  # Get local app info
  #
  local pkginfo_str=$(get_apk_package_info "${app_filename}")

  local app_id=$(echo "${pkginfo_str}" | cut -f1)
  local app_version_code=$(echo "${pkginfo_str}" | cut -f2)
  local app_version_name=$(echo "${pkginfo_str}" | cut -f3)

  log_verbose "${log_prefix} Локальная версия apk: ${app_version_name} (${app_version_code})"

  #
  # Get device app info
  #
  local package_info_output=$(get_installed_package_info "${app_id}" "${user_id}")

  # if package_info_output not empty
  if [ -n "${package_info_output}" ]; then
    local installed_version_code=$(echo "${package_info_output}" | cut -f2)
    local installed_version_name=$(echo "${package_info_output}" | cut -f3)

    log_verbose "${log_prefix} Установленная версия ${app_id}: ${installed_version_name} (${installed_version_code})"

    # if version code and version name are the same
    if [ "${app_version_code}" -eq "${installed_version_code}" ] && [ "${app_version_name}" == "${installed_version_name}" ]; then
      if ${OPT_FORCE_INSTALL}; then
        log_info "${log_prefix} Устанавливаем принудительно: ${app_id}"
      else
        log_info "${log_prefix} Уже установлено: ${app_id}"
        return 0
      fi
    fi

    # if installed version code is greater than local version code
    if [ "${installed_version_code}" -gt "${app_version_code}" ]; then
      if ${OPT_FORCE_INSTALL}; then
        log_warn "${log_prefix} Установленная версия ${app_id} (${installed_version_name} (${installed_version_code})) больше локальной ('${app_version_name}' (${app_version_code})), принудительно устанавливаем"

        log_info "${log_prefix} Удаление старой версии ${app_id} ..."
        # !!! Мы должны удалить старый со ВСЕХ мониторов, а не только с текущего, не используем --user
        if ! run_adb uninstall "${app_id}"; then
          #if ! _run_adb uninstall --user "${user_id}" "${app_id}"; then
          log_error "${log_prefix} Удаление старой версии ${app_id}: ошибка"
          return 1
        fi
      else
        log_error "${log_prefix} Установленная версия ${app_id} (${installed_version_name} (${installed_version_code})) больше локальной ('${app_version_name}' (${app_version_code})), пропускаем установку"
        return 1
      fi
    fi
  fi

  log_info "${log_prefix} Установка ${app_id} ..."

  if ! run_adb install -r -g --user "${user_id}" "${app_filename}"; then
    log_error "${log_prefix} Установка ${app_id}: ошибка"
    return 1
  fi
}

function is_appops_permission() {
  local permission=$1
  local appops_permission

  for appops_permission in "${PERMISSIONS_APPOPS[@]}"; do
    if [ "${permission}" == "${appops_permission}" ]; then
      echo "true"
      return 0
    fi
  done

  echo "false"
}

function is_android_permission() {
  local permission=$1

  if echo "${permission}" | grep -q "^android.permission."; then
    echo "true"
  else
    echo "false"
  fi
}

function fix_apk_permissions() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local app_id=$4
  local screen_type=$(get_screen_type "${car_type}" "${cpu_type}" "${user_id}")
  #local log_prefix="[${car_type}][$cpu_type][user:${user_id}] ${screen_type} -"
  local log_prefix="[${car_type}][$cpu_type] ${screen_type} -"

  local requested_permissions=$(get_app_requested_permissions "${app_id}")
  for permission in ${requested_permissions}; do

    if [ "$(is_android_permission "$permission")" == "false" ]; then
      log_verbose "${log_prefix} Разрешение ${permission} не является android.permission - пропускаем"
      continue
    fi

    local is_appops=$(is_appops_permission "${permission}")

    if [ "${is_appops}" == "true" ]; then
      # Remove "android.permission." prefix
      # shellcheck disable=SC2001
      local appops_perm=$(echo "$permission" | sed 's/^android\.permission\.//')

      # adb shell appops get --user 21473 com.carmodapps.carstore
      local appops_value=$(run_adb shell appops get --user "${user_id}" "${app_id}" "${appops_perm}" | awk '{print $2}')
      if [ "${appops_value}" == "allow" ]; then
        log_verbose "${log_prefix} Разрешение ${permission} уже выдано"
      else
        log_info "${log_prefix} Выдача разрешения ${app_id} ${appops_perm} (APPOPS)..."
        if ! run_adb shell appops set --user "${user_id}" "${app_id}" "${appops_perm}" allow; then
          log_error "${log_prefix} Выдача разрешения ${app_id} ${appops_perm} (APPOPS): ошибка"
        fi
      fi

    else
      if [ "${user_id}" -eq 0 ]; then
        # General permissions - ONLY for user ID = 0, without "--user"
        #if run_adb shell pm grant --user "${user_id}" "${app_id}" "${permission}" 2> /dev/null; then
        if run_adb shell pm grant "${app_id}" "${permission}" 2> /dev/null; then
          log_info "${log_prefix} Выдача разрешения ${app_id} ${permission}..."
        else
          log_verbose "${log_prefix} Выдача разрешения ${app_id} ${permission}: ошибка"
        fi
      fi
    fi

  done

  #
  # Packages/Package/User {id}/runtime permissions
  #
  local runtime_permissions=$(get_app_user_runtime_permissions "${app_id}" "${user_id}")
  local perm_value
  for perm_value in ${runtime_permissions}; do
    local permission=$(echo "${perm_value}" | cut -d':' -f1)
    local granted=$(echo "${perm_value}" | cut -d':' -f2) # true/false

    if [ "${granted}" == "true" ]; then
      log_verbose "${log_prefix} Разрешение ${permission} уже выдано"
      continue
    fi

    log_info "${log_prefix} Выдача разрешения ${app_id} ${permission}..."

    if ! run_adb shell pm grant --user "${user_id}" "${app_id}" "${permission}"; then
      log_error "${log_prefix} Выдача разрешения ${app_id} ${permission}: ошибка"
    fi
  done

}

function uninstall_app_id() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local app_id=$4
  local screen_type=$(get_screen_type "${car_type}" "${cpu_type}" "${user_id}")
  #local log_prefix="[${car_type}][$cpu_type][user:${user_id}] ${screen_type} -"
  local log_prefix="[${car_type}][$cpu_type] ${screen_type} -"

  local package_info_output=$(get_installed_package_info "${app_id}" "${user_id}")

  # if package_info_output not empty
  if [ -n "${package_info_output}" ]; then
    local installed_version_code=$(echo "${package_info_output}" | cut -f2)
    local installed_version_name=$(echo "${package_info_output}" | cut -f3)

    log_verbose "${log_prefix} Установленная версия ${app_id}: ${installed_version_name} (${installed_version_code})"

    log_info "${log_prefix} Удаление ${app_id} ..."

    if ! run_adb uninstall --user "${user_id}" "${app_id}"; then
      log_error "${log_prefix} Удаление ${app_id}: ошибка"
      return 1
    fi
  else
    log_verbose "${log_prefix} Удаление ${app_id} не требуется"
  fi
}


# return: "true"/"false"
function is_tweak_enabled() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local tweak=$4

  # If tweak in DISABLED_TWEAKS
  local disabled_tweak
  for disabled_tweak in "${DISABLED_TWEAKS[@]}"; do
    if [ "${tweak}" == "${disabled_tweak}" ]; then
      log_verbose "[${car_type}][$cpu_type][user:${user_id}] Твик ${tweak} отключен"
      echo "false"
      return 0
    fi
  done
  echo "true"
}


function apply_tweaks() {
  local car_type=$1
  local cpu_type=$2
  local user_id=$3
  local tweaks=$(get_tweaks "${car_type}" "${cpu_type}" "${user_id}")

  # if not empty
  if [ -n "${tweaks}" ]; then
    local tweak
    for tweak in ${tweaks}; do
      local enabled=$(is_tweak_enabled "${car_type}" "${cpu_type}" "${user_id}" "${tweak}")
      if [ "${enabled}" == "false" ]; then
        log_warn "[${car_type}][$cpu_type][user:${user_id}] Применение твика ${tweak}: отключено"
        continue
      fi

      log_info "[${car_type}][$cpu_type][user:${user_id}] Применение твика: ${tweak}"

      if ! ${tweak} "${car_type}" "${cpu_type}" "${user_id}" ; then
        log_error "[${car_type}][$cpu_type][user:${user_id}] Применение твика ${tweak}: ошибка"
      fi
    done
  else
    log_info "[${car_type}][$cpu_type][user:${user_id}] Твики не найдены"
  fi
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
  local car_type
  local cpu_type
  local users
  local user_id
  local log_prefix

  car_type=$(adb_get_car_type)
  cpu_type=$(adb_get_cpu_type)
  users=$(adb_get_users)
  log_prefix="[${car_type}][${cpu_type}]"

  local car_tag
  car_tag=$(get_car_tag "${car_type}")
  local car_packages_cma_dir="${PACKAGES_CMA_DIR}/${car_tag}"
  local car_packages_cma_index_file="${car_packages_cma_dir}/index.txt"

  ############################
  # Prepare all_apps_array
  local all_apps_array=()
  local line
  while IFS= read -r line; do
    # Push line to all_apps_array
    all_apps_array+=("${line}")
  done < <(cat "${car_packages_cma_index_file}")

  ############################
  # Install
  for line in "${all_apps_array[@]}"; do
    # Get app_id, app_filename_basename, app_screen_types
    local app_id
    local app_filename_basename
    local app_filename
    local app_screen_types
    app_id=$(echo "${line}" | cut -d'|' -f1)
    app_filename_basename=$(echo "${line}" | cut -d'|' -f2)
    app_screen_types=$(echo "${line}" | cut -d'|' -f3)

    app_filename="${car_packages_cma_dir}/${app_filename_basename}"

    ############################
    # Install/Uinstall
    for user_id in ${users}; do
      local screen_type=$(get_screen_type "${car_type}" "${cpu_type}" "${user_id}")
      local screen_type_tag=$(get_screen_type_tag "${screen_type}")
      local screen_log_prefix="[${car_type}][$cpu_type][user:${user_id}] ${screen_type} -"
      local should_be_installed=$(echo "${app_screen_types}" | grep -q "${screen_type_tag}" && echo "true" || echo "false")

      # Check if app is installed for this user
      #local is_installed=$(get_badging_user_field_value "${app_id}" "${user_id}" "installed")
      #log_verbose "${screen_log_prefix} ${app_id} - is_installed: ${is_installed} should_be_installed: ${should_be_installed}"
      #if [ "${is_installed}" == "true" ] && [ "${should_be_installed}" == "false" ]; then
      # ...
      #elif [ "${is_installed}" == "false" ] && [ "${should_be_installed}" == "true" ]; then
      # ...
      #fi

      if [ "${should_be_installed}" == "false" ]; then
        uninstall_app_id "${car_type}" "${cpu_type}" "${user_id}" "${app_id}"
      elif [ "${should_be_installed}" == "true" ]; then
        install_apk "${car_type}" "${cpu_type}" "${user_id}" "${app_filename}"
      fi

      fix_apk_permissions "${car_type}" "${cpu_type}" "${user_id}" "${app_id}"
    done

  done

  log_info "${log_prefix} Установка завершена, применение твиков..."

  ############################
  # Tweaks
  for user_id in ${users}; do
    local screen_type
    screen_type=$(get_screen_type "${car_type}" "${cpu_type}" "${user_id}")

    log_info "[${car_type}][$cpu_type][user:${user_id}] ${screen_type} - применение твиков..."

    apply_tweaks "${car_type}" "${cpu_type}" "${user_id}"
  done
}

function do_install_apk() {
  local apk_path=$1
  local car_type=$(adb_get_car_type)
  local cpu_type=$(adb_get_cpu_type)
  local users=$(adb_get_users)

  for user_id in ${users}; do
    log_info "Установка ${apk_path} для пользователя ${user_id}..."
    install_apk "${car_type}" "${cpu_type}" "${user_id}" "${apk_path}"
  done
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
        log_info "[${car_type}][$cpu_type][user:${user_id}] Удаление ${app_id} ..."

        if ! run_adb uninstall --user "${user_id}" "${app_id}"; then
          log_error "[${car_type}][$cpu_type][user:${user_id}] Удаление ${app_id}: ошибка"
        fi
      done
    fi

  done
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
  local car_packages_cma_index_file="${car_packages_cma_dir}/index.txt"
  local log_prefix="[${car_tag}]"

  mkdir -p "${car_packages_cma_dir}"

  log_info "Проверка обновлений приложений, автомобиль: $car_tag, канал: $UPDATE_CHANNEL ..."

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
  echo -n "" >"${car_packages_cma_index_file}"

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

    # app_screens is not empty ? need_download=true : need_download=false
    local need_download
    [ -n "${app_screens}" ] && need_download=true || need_download=false

    local app_log_prefix="${log_prefix}[${app_upd_channel}][${app_id}]"

    # Check if enabled for at least one screen
    if [ "${need_download}" == "true" ]; then
      if [ -f "${app_local_filename}" ]; then
        log_info "${app_log_prefix} Уже загружен. (${app_screens})"
      else
        log_info "${app_log_prefix} Загрузка... (${app_screens})"

        if ! curl -s -o "${app_local_filename}" "${app_url}"; then
          log_error "${app_log_prefix} Загрузка: ошибка"
          # Exit from script, we already cleaned index file
          exit 1
        fi
      fi

      # Save to index file
      echo "${app_id}|${app_local_filename_basename}|${app_screens}|${app_upd_channel}" >>"${car_packages_cma_index_file}"
    fi


    # Remove old app files
    local old_app_file
    while IFS= read -r -d '' old_app_file; do
      local old_app_file_basename
      old_app_file_basename=$(basename "${old_app_file}")

      if [[ "${need_download}" == "true" &&  "${old_app_file}" == "${app_local_filename}" ]]; then
        # This is current app file, skip
        continue
      fi

      log_warn "${app_log_prefix} Удаление старого файла ${old_app_file_basename} ..."
      rm -f "${old_app_file}"
    done < <(find_app_files "${car_packages_cma_dir}" "$app_id")
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
        local product_type

        ADB_CURRENT_SERIAL="${serial}"

        cpu_type=$(adb_get_cpu_type)
        car_type=$(adb_get_car_type)
        product_type=$(run_adb shell getprop ro.product.model)

        log_info "Найдено устройство: ${car_type} (${product_type}) ${cpu_type} (${serial})"
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

    if ! "${cmd}" "$@"; then
      log_error "Ошибка: ${cmd}"
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

Использование:

  $(basename "${0}") [options] [<команда>]

Установить сторонний APK-файл (и выдать разрешения):
  $(basename "${0}") [options] <APK-файл>

По-умолчанию выполняется update + install

Команды:
  vin: Отобразить VIN
  install: Запустить автоматическую установку приложений
  update: Загрузить приложения с сервера CarModApps
  delete: Удалить ВСЕ не системные приложения, включая CarModApps и пользовательские приложения

 Общие опции:
  -h, --help: Показать это сообщение
  -v, --verbose: Выводить подробную информацию
  -f, --force: Принудительно установить приложения, даже если они уже установлены

Опции при запуске без команды:
  -d, Выполнить удаление ВСЕХ не системных приложений перед установкой

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

  local apk_path
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
    vin | install | update | delete)
      cmd="$1"
      ;;
    *apk)
      cmd="apk"
      apk_path="$1"
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
  apk)
    if [ -z "${apk_path}" ]; then
      log_error "Не указан путь к APK-файлу"
      exit 1
    fi
    wait_for_devices
    exec_on_all_devices do_install_apk "${apk_path}"
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
