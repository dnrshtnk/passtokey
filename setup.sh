#!/usr/bin/env bash
# ==============================================================================
# Скрипт: setup.sh (passtokey)
# Назначение: отключает вход по паролю и интерактивную аутентификацию,
#             настраивает вход по SSH-ключу и параметры cloud-init,
#             проверяет UFW и поддерживает Ubuntu 24.04+ (сокеты systemd и дополнительные конфиги).
# Репозиторий: https://github.com/USERNAME/passtokey
# Лицензия:    MIT
# ==============================================================================

set -euo pipefail

# --- Цвета вывода ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Функции сообщений ---
log_info() {
    echo -e "${C_CYAN}[INFO]${C_RESET} $*"
}

log_success() {
    echo -e "${C_GREEN}[SUCCESS]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[WARNING]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2
}

log_step() {
    echo -e "\n${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"
}

# --- Ввод данных (поддерживает запуск через curl | bash с чтением из /dev/tty) ---
prompt_read() {
    local prompt_msg="$1"
    local var_name="$2"
    if [[ -t 0 ]]; then
        read -r -p "$prompt_msg" "$var_name"
    elif [[ -e /dev/tty ]]; then
        read -r -p "$prompt_msg" "$var_name" </dev/tty
    else
        read -r -p "$prompt_msg" "$var_name"
    fi
}

# --- Переменные для восстановления настроек и очистки ---
BACKUP_SSHD_CONFIG=""
BACKUP_CLOUD_INIT_SSH=""
CREATED_DROPIN_CONF=""
CREATED_CLOUD_CFG=""
BACKUP_DROPIN_CONF=""
BACKUP_CLOUD_CFG=""
BACKUP_AUTH_KEYS=""
AUTH_KEYS_EXISTED=false
SSH_DIR_EXISTED=false
ROLLBACK_ACTIVE=false
NEWLY_CONFIGURED_PUBKEY=""
UFW_ENABLED_BY_SCRIPT=false
UFW_ADDED_PORTS=()

# --- Функция восстановления настроек ---
rollback() {
    [[ "${ROLLBACK_ACTIVE}" == "true" ]] || return 0
    log_error "Произошла ошибка. Восстанавливаю прежние настройки..."

    if [[ -n "${BACKUP_DROPIN_CONF}" && -f "${BACKUP_DROPIN_CONF}" ]]; then
        cp -a "${BACKUP_DROPIN_CONF}" "${CREATED_DROPIN_CONF}"
    elif [[ -n "${CREATED_DROPIN_CONF}" ]]; then
        rm -f "${CREATED_DROPIN_CONF}"
    fi

    if [[ -n "${BACKUP_CLOUD_INIT_SSH}" && -f "${BACKUP_CLOUD_INIT_SSH}" ]]; then
        cp -f "${BACKUP_CLOUD_INIT_SSH}" /etc/ssh/sshd_config.d/50-cloud-init.conf
        log_info "Файл 50-cloud-init.conf восстановлен из резервной копии: ${BACKUP_CLOUD_INIT_SSH}"
    fi

    if [[ -n "${BACKUP_CLOUD_CFG}" && -f "${BACKUP_CLOUD_CFG}" ]]; then
        cp -a "${BACKUP_CLOUD_CFG}" "${CREATED_CLOUD_CFG}"
    elif [[ -n "${CREATED_CLOUD_CFG}" ]]; then
        rm -f "${CREATED_CLOUD_CFG}"
    fi

    if [[ -n "${BACKUP_SSHD_CONFIG}" && -f "${BACKUP_SSHD_CONFIG}" ]]; then
        cp -f "${BACKUP_SSHD_CONFIG}" /etc/ssh/sshd_config
        log_info "Файл sshd_config восстановлен из резервной копии: ${BACKUP_SSHD_CONFIG}"
    fi

    if [[ -n "${BACKUP_AUTH_KEYS}" && -f "${BACKUP_AUTH_KEYS}" ]]; then
        cp -a "${BACKUP_AUTH_KEYS}" "${AUTH_KEYS}"
    elif [[ "${AUTH_KEYS_EXISTED}" != "true" && -n "${AUTH_KEYS:-}" ]]; then
        rm -f "${AUTH_KEYS}"
        if [[ "${SSH_DIR_EXISTED}" != "true" ]]; then
            rmdir "${SSH_DIR}" 2>/dev/null || true
        fi
    fi

    if [[ "${UFW_ENABLED_BY_SCRIPT}" == "true" ]] && command -v ufw &>/dev/null; then
        ufw --force disable >/dev/null 2>&1 || true
    fi
    if command -v ufw &>/dev/null; then
        local port
        for port in "${UFW_ADDED_PORTS[@]}"; do
            ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
        done
    fi

    log_warn "Восстановление завершено. Настройки SSH возвращены к исходному состоянию."
    ROLLBACK_ACTIVE=false
}

handle_exit() {
    local exit_status=$?
    trap - EXIT
    if [[ "${exit_status}" -ne 0 ]]; then
        rollback
    fi
    exit "${exit_status}"
}
trap handle_exit EXIT

# --- Проверка формата публичного ключа OpenSSH ---
validate_public_key() {
    local key_text="$1"
    local check_file
    check_file=$(mktemp)
    echo "${key_text}" > "${check_file}"
    if ssh-keygen -l -f "${check_file}" &>/dev/null; then
        local fp
        fp=$(ssh-keygen -l -f "${check_file}")
        rm -f "${check_file}"
        echo "${fp}"
        return 0
    else
        rm -f "${check_file}"
        return 1
    fi
}

# --- Разбор параметров командной строки ---
CLI_USER=""
CLI_KEY=""
CLI_NON_INTERACTIVE=false
CLI_KEY_VERIFIED=false

print_usage() {
    cat << EOF
Использование: sudo bash setup.sh [ПАРАМЕТРЫ]

Параметры:
  -u, --user USER         Имя пользователя на сервере (по умолчанию: SUDO_USER или первый пользователь с UID>=1000)
  -k, --key "KEY"         Строка публичного SSH-ключа для установки
      --key-verified      Подтверждает, что вход по ключу проверен в отдельном сеансе
  -g, --generate          Отключено; создайте приватный ключ на своём компьютере
  -y, --non-interactive   Запуск без запросов (требует --key-verified)
  -h, --help              Показать эту справку
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "После параметра $1 укажите имя пользователя."
                print_usage
                exit 1
            fi
            CLI_USER="$2"
            shift 2
            ;;
        -k|--key)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "После параметра $1 укажите строку публичного ключа."
                print_usage
                exit 1
            fi
            CLI_KEY="$2"
            shift 2
            ;;
        -g|--generate)
            log_error "Создание приватного ключа на сервере отключено. Создайте ключ на своём компьютере и передайте скрипту публичный ключ через --key."
            exit 1
            ;;
        --key-verified)
            CLI_KEY_VERIFIED=true
            shift
            ;;
        -y|--non-interactive)
            CLI_NON_INTERACTIVE=true
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Неизвестный параметр: $1"
            print_usage
            exit 1
            ;;
    esac
done

if [[ "${CLI_NON_INTERACTIVE}" == "true" ]]; then
    if [[ -z "${CLI_USER}" || -z "${CLI_KEY}" || "${CLI_KEY_VERIFIED}" != "true" ]]; then
        log_error "Для неинтерактивного режима укажите --user, --key и --key-verified."
        exit 1
    fi
fi

echo -e "${C_BOLD}${C_BLUE}========================================================================${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}           PassToKey: настройка SSH и входа по ключу                     ${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}========================================================================${C_RESET}"

# --- 1. Проверка прав root ---
log_step "Шаг 1: проверка прав"
if [[ "${EUID}" -ne 0 ]]; then
    log_error "Запустите скрипт от root или через sudo."
    echo "Использование: sudo bash $0"
    exit 1
fi
log_success "Скрипт запущен с правами root."

# --- 2. Поиск и проверка пользователя ---
log_step "Шаг 2: выбор пользователя"
DEFAULT_USER=""
if [[ -n "${CLI_USER}" ]]; then
    TARGET_USER="${CLI_USER}"
else
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        DEFAULT_USER="${SUDO_USER}"
    else
        FIRST_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)/ { print $1; exit }' /etc/passwd 2>/dev/null || true)
        DEFAULT_USER="${FIRST_USER:-root}"
    fi

    if [[ "${CLI_NON_INTERACTIVE}" == "true" ]]; then
        TARGET_USER="${DEFAULT_USER}"
    else
        echo -e "Укажите пользователя, для которого нужно настроить файл authorized_keys."
        prompt_read "Имя пользователя [по умолчанию: ${DEFAULT_USER}]: " INPUT_USER
        TARGET_USER="${INPUT_USER:-${DEFAULT_USER}}"
    fi
fi

if ! id "${TARGET_USER}" &>/dev/null; then
    log_error "Пользователь '${TARGET_USER}' не найден на этом сервере."
    exit 1
fi

TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
TARGET_GROUP=$(id -gn "${TARGET_USER}")

if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
    log_error "Домашний каталог пользователя '${TARGET_USER}' ('${TARGET_HOME}') не найден."
    exit 1
fi
log_success "Выбран пользователь: ${C_BOLD}${TARGET_USER}${C_RESET} (домашний каталог: ${TARGET_HOME}, группа: ${TARGET_GROUP})"

# --- 3. Каталог .ssh и права доступа ---
log_step "Шаг 3: настройка ~/.ssh и authorized_keys"
SSH_DIR="${TARGET_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [[ -d "${SSH_DIR}" ]]; then
    SSH_DIR_EXISTED=true
fi
if [[ -f "${AUTH_KEYS}" ]]; then
    AUTH_KEYS_EXISTED=true
    BACKUP_AUTH_KEYS="${AUTH_KEYS}.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp -a "${AUTH_KEYS}" "${BACKUP_AUTH_KEYS}"
    log_info "Создана резервная копия authorized_keys: ${BACKUP_AUTH_KEYS}"
fi
ROLLBACK_ACTIVE=true

if [[ ! -d "${SSH_DIR}" ]]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
    log_info "Создан каталог: ${SSH_DIR} (права 700)"
else
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
    log_info "Установлены права на каталог ${SSH_DIR}: 700"
fi

if [[ ! -f "${AUTH_KEYS}" ]]; then
    touch "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
    log_info "Создан файл: ${AUTH_KEYS} (права 600)"
else
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
    log_info "Установлены права на файл ${AUTH_KEYS}: 600"
fi

# --- 4. Выбор SSH-ключа ---
log_step "Шаг 4: настройка SSH-ключа"

if [[ -n "${CLI_KEY}" ]]; then
    # Ключ передан через командную строку
    KEY_TRIMMED="$(echo "${CLI_KEY}" | xargs)"
    if KEY_FP=$(validate_public_key "${KEY_TRIMMED}"); then
        log_success "Публичный ключ из параметров проверен: ${KEY_FP}"
        NEWLY_CONFIGURED_PUBKEY="${KEY_TRIMMED}"
        if grep -Fxq "${KEY_TRIMMED}" "${AUTH_KEYS}" 2>/dev/null; then
            log_info "Ключ уже добавлен в ${AUTH_KEYS}."
        else
            echo "${KEY_TRIMMED}" >> "${AUTH_KEYS}"
            log_success "Ключ добавлен в ${AUTH_KEYS}."
        fi
    else
        log_error "Значение --key не является корректным публичным ключом OpenSSH."
        exit 1
    fi
else
    echo -e "Выберите действие для пользователя ${C_BOLD}${TARGET_USER}${C_RESET}:"
    echo -e "  ${C_BOLD}[1]${C_RESET} Вставить публичный ключ (${C_GREEN}рекомендуется${C_RESET})"
    echo -e "  ${C_BOLD}[2]${C_RESET} Оставить текущие ключи в ~/.ssh/authorized_keys"
    echo -e "\n${C_CYAN}Для пункта [1] используйте PowerShell на СВОЁМ компьютере с Windows, а не на сервере.${C_RESET}"
    echo -e "Вставьте этот блок в PowerShell. Он запросит имя сервера и компьютера, создаст ключи и выведет публичный ключ:"
    cat <<'POWERSHELL'
$serverName = Read-Host "Имя сервера (например, web01)"
if ([string]::IsNullOrWhiteSpace($serverName)) { throw "Имя сервера не может быть пустым." }
$computerName = Read-Host "Имя компьютера [$env:COMPUTERNAME] (Enter — использовать это имя)"
if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = $env:COMPUTERNAME }
$namePart = (($serverName, $computerName) -join "_") -replace '[^A-Za-z0-9_-]', '_'
$sshDir = Join-Path $env:USERPROFILE ".ssh"
New-Item -ItemType Directory -Force $sshDir | Out-Null
$keyPath = Join-Path $sshDir "id_ed25519_$namePart"
if ((Test-Path $keyPath) -or (Test-Path "$keyPath.pub")) { throw "Файл ключа уже существует: $keyPath. Укажите другое имя сервера или выведите существующий файл .pub." }
ssh-keygen -t ed25519 -C "$env:USERNAME@$serverName" -f $keyPath
if ($LASTEXITCODE -ne 0) { throw "Не удалось выполнить ssh-keygen." }
Get-Content "$keyPath.pub"
POWERSHELL
    echo -e "Вставьте всю выведенную строку, начинающуюся с ssh-ed25519, в запрос ключа. Приватный ключ (без .pub) храните на своём компьютере."

    KEY_CHOICE=""
    while [[ ! "${KEY_CHOICE}" =~ ^[1-2]$ ]]; do
        prompt_read "Ваш выбор [1/2]: " KEY_CHOICE
    done
fi

if [[ "${KEY_CHOICE:-}" == "1" ]]; then
    while true; do
        echo -e "\nВставьте публичный SSH-ключ (например, ssh-ed25519 AAAAC3... или ssh-rsa AAAAB3...):"
        prompt_read "Ключ: " PASTED_KEY
        PASTED_KEY="$(echo "${PASTED_KEY:-}" | xargs)"

        if [[ -z "${PASTED_KEY}" ]]; then
            log_warn "Пустой ключ. Попробуйте ещё раз."
            continue
        fi

        if KEY_FP=$(validate_public_key "${PASTED_KEY}"); then
            log_success "Ключ проверен: ${KEY_FP}"
            NEWLY_CONFIGURED_PUBKEY="${PASTED_KEY}"
            if grep -Fxq "${PASTED_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
                log_info "Ключ уже добавлен в ${AUTH_KEYS}."
            else
                echo "${PASTED_KEY}" >> "${AUTH_KEYS}"
                log_success "Ключ добавлен в ${AUTH_KEYS}."
            fi
            break
        else
            log_error "Неверный формат публичного ключа OpenSSH."
            log_info "Ожидается стандартный формат, например 'ssh-ed25519 AAAA...' или 'ssh-rsa AAAA...'"
            prompt_read "Попробовать ещё раз? [Y/n]: " RETRY_CHOICE
            if [[ "${RETRY_CHOICE:-}" =~ ^[Nn]$ ]]; then
                log_error "Операция отменена."
                exit 1
            fi
        fi
    done
elif [[ "${KEY_CHOICE:-}" == "2" ]]; then
    log_info "Будут использованы ключи из ${AUTH_KEYS}."
fi

# Проверить, что authorized_keys содержит хотя бы один корректный ключ
VALID_KEY_COUNT=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_trimmed="$(echo "${line}" | xargs 2>/dev/null || echo "${line}")"
    if [[ -z "${line_trimmed}" || "${line_trimmed}" =~ ^# ]]; then
        continue
    fi
    if validate_public_key "${line_trimmed}" &>/dev/null; then
        VALID_KEY_COUNT=$((VALID_KEY_COUNT + 1))
    fi
done < "${AUTH_KEYS}"

if [[ "${VALID_KEY_COUNT}" -eq 0 ]]; then
    log_error "В ${AUTH_KEYS} не найдено ни одного корректного публичного SSH-ключа."
    log_error "Останавливаюсь, чтобы не лишить вас доступа к серверу."
    exit 1
fi
log_success "В ${AUTH_KEYS} проверено ключей: ${VALID_KEY_COUNT}."

# Установить итоговые права доступа на ~/.ssh
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}" "${AUTH_KEYS}"

if [[ "${CLI_NON_INTERACTIVE}" == "true" ]]; then
    if [[ "${CLI_KEY_VERIFIED}" != "true" ]]; then
        log_error "Отказываюсь отключать вход по паролю без подтверждения --key-verified."
        exit 1
    fi
else
    echo -e "\n${C_YELLOW}${C_BOLD}Перед продолжением проверьте вход по ключу в отдельном окне терминала.${C_RESET}"
    echo -e "Выполните команду в PowerShell на своём компьютере. Замените имя ключа, пользователя и адрес сервера на свои значения:"
    echo -e "  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -i \"\$env:USERPROFILE\\.ssh\\ИМЯ_ПРИВАТНОГО_КЛЮЧА\" ИМЯ_ПОЛЬЗОВАТЕЛЯ@АДРЕС_СЕРВЕРА"
    prompt_read "Удалось войти в новом окне? Введите 'да', чтобы отключить вход по паролю: " KEY_LOGIN_CONFIRMED
    if [[ ! "${KEY_LOGIN_CONFIRMED:-}" =~ ^(да|yes)$ ]]; then
        log_error "Вход по ключу не подтверждён. Вход по паролю останется включённым."
        exit 1
    fi
fi

# --- 5. Проверка настроек cloud-init ---
log_step "Шаг 5: проверка настроек cloud-init (50-cloud-init.conf)"
CLOUD_INIT_SSH_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"

if [[ -f "${CLOUD_INIT_SSH_CONF}" ]]; then
    log_warn "Найден файл настроек SSH cloud-init: ${CLOUD_INIT_SSH_CONF}"
    BACKUP_CLOUD_INIT_SSH="/etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp "${CLOUD_INIT_SSH_CONF}" "${BACKUP_CLOUD_INIT_SSH}"
    log_info "Создана резервная копия: ${BACKUP_CLOUD_INIT_SSH}"

    # В OpenSSH применяется первое найденное значение параметра.
    # Если 50-cloud-init.conf задаёт PasswordAuthentication yes, оно может перекрыть последующие файлы.
    if grep -E -q '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "${CLOUD_INIT_SSH_CONF}"; then
        log_info "Отключаю вход по паролю и интерактивную аутентификацию в ${CLOUD_INIT_SSH_CONF}..."
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)/PasswordAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+(yes|no)/KbdInteractiveAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+(yes|no)/ChallengeResponseAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        log_success "Параметры в ${CLOUD_INIT_SSH_CONF} обновлены."
    else
        echo "PasswordAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        echo "KbdInteractiveAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        log_info "В ${CLOUD_INIT_SSH_CONF} добавлены параметры отключения парольной аутентификации."
    fi
else
    log_info "Файл переопределения cloud-init не найден (${CLOUD_INIT_SSH_CONF})."
fi

# Не позволять cloud-init включать вход по паролю после перезагрузки
if [[ -d "/etc/cloud/cloud.cfg.d" ]]; then
    CREATED_CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-disable-passwords.cfg"
    if [[ -f "${CREATED_CLOUD_CFG}" ]]; then
        BACKUP_CLOUD_CFG="${CREATED_CLOUD_CFG}.bak.$(date +%Y%m%d_%H%M%S).$$"
        cp -a "${CREATED_CLOUD_CFG}" "${BACKUP_CLOUD_CFG}"
        log_info "Создана резервная копия настроек cloud-init: ${BACKUP_CLOUD_CFG}"
    fi
    log_info "Добавляю постоянную настройку cloud-init: ${CREATED_CLOUD_CFG}"
    cat << 'EOF' > "${CREATED_CLOUD_CFG}"
# Создано скриптом passtokey
# Не позволять cloud-init включать вход по паролю после перезагрузки или запуска cloud-init
ssh_pwauth: false
EOF
    log_success "Для cloud-init задано ssh_pwauth=false."
fi

# --- 6. Настройка SSH-сервера ---
log_step "Шаг 6: настройка защиты SSH-сервера"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"

if [[ ! -f "${SSHD_CONFIG}" ]]; then
    log_error "Не найден основной файл конфигурации SSH: ${SSHD_CONFIG}."
    exit 1
fi

BACKUP_SSHD_CONFIG="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S).$$"
cp "${SSHD_CONFIG}" "${BACKUP_SSHD_CONFIG}"
log_info "Создана резервная копия: ${BACKUP_SSHD_CONFIG}"

mkdir -p "${SSHD_CONFIG_D}"

# Убедиться, что sshd_config подключает дополнительные файлы
if ! grep -E -q '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"; then
    log_info "Добавляю 'Include /etc/ssh/sshd_config.d/*.conf' в начало файла ${SSHD_CONFIG}..."
    TEMP_SSHD_HEAD=$(mktemp)
    echo -e "Include /etc/ssh/sshd_config.d/*.conf\n$(cat "${SSHD_CONFIG}")" > "${TEMP_SSHD_HEAD}"
    cat "${TEMP_SSHD_HEAD}" > "${SSHD_CONFIG}"
    rm -f "${TEMP_SSHD_HEAD}"
fi

# Закомментировать явные значения 'yes' в sshd_config, чтобы приоритет был у дополнительных файлов
sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"

# OpenSSH применяет первое найденное значение параметра.
# Префикс 01- обеспечивает чтение файла перед 50-cloud-init.conf.
CREATED_DROPIN_CONF="${SSHD_CONFIG_D}/01-disable-password-auth.conf"
if [[ -f "${CREATED_DROPIN_CONF}" ]]; then
    BACKUP_DROPIN_CONF="${CREATED_DROPIN_CONF}.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp -a "${CREATED_DROPIN_CONF}" "${BACKUP_DROPIN_CONF}"
    log_info "Создана резервная копия дополнительного файла SSH: ${BACKUP_DROPIN_CONF}"
fi
log_info "Записываю дополнительный файл конфигурации: ${CREATED_DROPIN_CONF}"

cat << 'EOF' > "${CREATED_DROPIN_CONF}"
# ==============================================================================
# Управляется скриптом passtokey
# Оставить вход по ключу, отключить вход по паролю и интерактивную аутентификацию
# ==============================================================================

# Разрешить аутентификацию по публичному ключу
PubkeyAuthentication yes

# Запретить аутентификацию по паролю
PasswordAuthentication no

# Запретить интерактивную аутентификацию Keyboard-Interactive
KbdInteractiveAuthentication no

# Запретить устаревший параметр ChallengeResponseAuthentication
ChallengeResponseAuthentication no

# Оставить PAM включённым для настройки сеанса, MOTD и переменных окружения
UsePAM yes
EOF

chmod 644 "${CREATED_DROPIN_CONF}"
log_success "Дополнительный файл конфигурации создан."

# --- 7. Проверка конфигурации SSH ---
log_step "Шаг 7: проверка конфигурации SSH (sshd -t)"
if ! sshd -t; then
    log_error "Проверка синтаксиса конфигурации SSH не пройдена."
    rollback
    exit 1
fi
log_success "Синтаксис конфигурации SSH корректен."

# --- 8. Проверка состояния сетевого экрана UFW ---
log_step "Шаг 8: проверка сетевого экрана UFW"
UFW_DETECTED_STATUS="не установлен"

if command -v ufw &>/dev/null; then
    UFW_STATUS_RAW=$(ufw status 2>/dev/null || true)
    
    # Получить действующие SSH-порты с учётом блоков Match и подключённых файлов.
    mapfile -t SSH_PORTS < <(sshd -T | awk '$1 == "port" { print $2 }' | sort -nu)
    if [[ "${#SSH_PORTS[@]}" -eq 0 ]]; then
        SSH_PORTS=(22)
    fi
    MISSING_SSH_PORTS=()
    for port in "${SSH_PORTS[@]}"; do
        if ! grep -Eqi "^[[:space:]]*${port}(/tcp)?[[:space:]]+ALLOW([[:space:]]|$)" <<< "${UFW_STATUS_RAW}" \
            && ! { [[ "${port}" == "22" ]] && grep -Eqi "^[[:space:]]*OpenSSH[[:space:]]+ALLOW([[:space:]]|$)" <<< "${UFW_STATUS_RAW}"; }; then
            MISSING_SSH_PORTS+=("${port}")
        fi
    done

    allow_ssh_ports() {
        local port
        for port in "${SSH_PORTS[@]}"; do
            ufw allow "${port}/tcp"
        done
    }

    if echo "${UFW_STATUS_RAW}" | grep -qi "Status: active"; then
        UFW_DETECTED_STATUS="активен"
        log_info "Сетевой экран UFW ${C_GREEN}${C_BOLD}активен${C_RESET}."
        
        if [[ "${#MISSING_SSH_PORTS[@]}" -eq 0 ]]; then
            log_success "UFW разрешает все используемые SSH-порты: ${SSH_PORTS[*]}."
        else
            log_warn "UFW активен, но может блокировать SSH-порты: ${MISSING_SSH_PORTS[*]}."
            
            if [[ "${CLI_NON_INTERACTIVE}" != "true" ]]; then
                prompt_read "Разрешить SSH-порты ${MISSING_SSH_PORTS[*]} в UFW? [Д/н]: " ALLOW_UFW
                if [[ ! "${ALLOW_UFW:-}" =~ ^[Нн]$ ]]; then
                    for port in "${MISSING_SSH_PORTS[@]}"; do
                        UFW_ADDED_PORTS+=("${port}")
                        ufw allow "${port}/tcp"
                    done
                    log_success "В UFW добавлены правила для SSH-портов: ${MISSING_SSH_PORTS[*]}."
                else
                    log_warn "Правила SSH не добавлены в UFW. Убедитесь, что сетевой экран пропускает SSH-соединения."
                fi
            else
                log_info "Неинтерактивный режим: разрешаю SSH-порты, чтобы сохранить доступ к серверу."
                for port in "${MISSING_SSH_PORTS[@]}"; do
                    UFW_ADDED_PORTS+=("${port}")
                    ufw allow "${port}/tcp"
                done
                log_success "В UFW добавлены правила для SSH-портов: ${MISSING_SSH_PORTS[*]}."
            fi
        fi
    elif echo "${UFW_STATUS_RAW}" | grep -qi "Status: inactive"; then
        UFW_DETECTED_STATUS="неактивен"
        log_info "Сетевой экран UFW ${C_YELLOW}${C_BOLD}неактивен${C_RESET}."
        echo -e "  Сейчас локальный UFW не ограничивает SSH-трафик."
        echo -e "  ${C_CYAN}Подсказка:${C_RESET} перед включением UFW разрешите SSH-порты: ${SSH_PORTS[*]}."

        if [[ "${CLI_NON_INTERACTIVE}" != "true" ]]; then
            prompt_read "Разрешить SSH-порты ${SSH_PORTS[*]} и включить UFW? [д/Н]: " ENABLE_UFW
            if [[ "${ENABLE_UFW:-}" =~ ^[Дд]$ ]]; then
                allow_ssh_ports
                UFW_ENABLED_BY_SCRIPT=true
                ufw --force enable
                UFW_DETECTED_STATUS="активен"
                log_success "SSH-порты разрешены, UFW включён."
            fi
        fi
    else
        log_info "Ответ UFW о состоянии: ${UFW_STATUS_RAW}"
    fi
else
    log_info "Сетевой экран UFW (Uncomplicated Firewall) не установлен."
fi

# --- 9. Перезагрузка службы SSH (включая активацию через сокет в Ubuntu 24.04+) ---
log_step "Шаг 9: применение настроек SSH"

systemctl daemon-reload

SSH_RELOADED=false

# В Ubuntu 24.04+ SSH может запускаться через сокет systemd ssh.socket.
if systemctl is-active --quiet ssh.socket; then
    log_info "Обнаружен активный сокет systemd ssh.socket (режим Ubuntu 24.04+)."
    if systemctl reload-or-restart ssh.socket 2>/dev/null && systemctl reload-or-restart ssh.service 2>/dev/null; then
        SSH_RELOADED=true
        log_success "Сокеты ssh.socket и ssh.service перезагружены."
    fi
fi

if [[ "${SSH_RELOADED}" == "false" ]]; then
    # Обычная служба systemd
    if systemctl is-active --quiet ssh; then
        if systemctl reload-or-restart ssh 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            SSH_RELOADED=true
            log_success "Служба ssh перезагружена."
        fi
    elif systemctl is-active --quiet sshd; then
        if systemctl reload-or-restart sshd 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            SSH_RELOADED=true
            log_success "Служба sshd перезагружена."
        fi
    fi
fi

if [[ "${SSH_RELOADED}" == "false" ]]; then
    log_warn "Пробую перезапустить SSH запасным способом..."
    if systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        SSH_RELOADED=true
        log_success "Служба SSH перезапущена запасным способом."
    else
        log_error "Не удалось перезагрузить или перезапустить SSH. Возвращаю прежние настройки..."
        rollback
        exit 1
    fi
fi

# Убедиться, что SSH активен
if ! (systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket || systemctl is-active --quiet sshd); then
    log_error "После перезагрузки служба SSH или её сокет не активны."
    rollback
    systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || true
    exit 1
fi

# --- 10. Итог, публичный ключ и дальнейшие действия ---
log_step "Шаг 10: настройка завершена"
echo -e "${C_GREEN}${C_BOLD}"
echo "========================================================================"
echo "                   ИТОГ НАСТРОЙКИ SSH                                  "
echo "========================================================================"
echo -e "${C_RESET}"
echo -e "Пользователь:              ${C_BOLD}${TARGET_USER}${C_RESET}"
echo -e "Файл авторизованных ключей: ${C_BOLD}${AUTH_KEYS}${C_RESET}"
echo -e "Доп. файл конфигурации SSH: ${C_BOLD}${CREATED_DROPIN_CONF}${C_RESET}"
echo -e "Сетевой экран UFW:          ${C_BOLD}${UFW_DETECTED_STATUS}${C_RESET}"
if [[ -n "${BACKUP_CLOUD_INIT_SSH}" ]]; then
echo -e "Копия cloud-init:          ${C_BOLD}${BACKUP_CLOUD_INIT_SSH}${C_RESET}"
fi
if [[ -n "${BACKUP_SSHD_CONFIG}" ]]; then
echo -e "Копия исходного sshd:      ${C_BOLD}${BACKUP_SSHD_CONFIG}${C_RESET}"
fi
echo -e "Вход по паролю:            ${C_RED}${C_BOLD}ОТКЛЮЧЁН${C_RESET}"
echo -e "Интерактивный вход:        ${C_RED}${C_BOLD}ОТКЛЮЧЁН${C_RESET}"
echo -e "Вход по публичному ключу:  ${C_GREEN}${C_BOLD}ВКЛЮЧЁН${C_RESET}"

# Показать публичные ключи для копирования на другие серверы
echo -e "\n${C_CYAN}${C_BOLD}========================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}              УСТАНОВЛЕННЫЕ ПУБЛИЧНЫЕ КЛЮЧИ                            ${C_RESET}"
echo -e "${C_CYAN}Чтобы разрешить вход с этим ключом на другом сервере, скопируйте строку ниже${C_RESET}"
echo -e "${C_CYAN}и добавьте её в ~/.ssh/authorized_keys на том сервере:${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}------------------------------------------------------------------------${C_RESET}"

if [[ -n "${NEWLY_CONFIGURED_PUBKEY}" ]]; then
    echo -e "${C_BOLD}${NEWLY_CONFIGURED_PUBKEY}${C_RESET}"
else
    # Показать корректные ключи из authorized_keys
    while IFS= read -r kline || [[ -n "${kline}" ]]; do
        kline_trimmed="$(echo "${kline}" | xargs 2>/dev/null || echo "${kline}")"
        if [[ -z "${kline_trimmed}" || "${kline_trimmed}" =~ ^# ]]; then
            continue
        fi
        if validate_public_key "${kline_trimmed}" &>/dev/null; then
            echo -e "${C_BOLD}${kline_trimmed}${C_RESET}"
        fi
    done < "${AUTH_KEYS}"
fi

echo -e "${C_CYAN}${C_BOLD}========================================================================${C_RESET}"

echo -e "\n${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
echo -e "${C_YELLOW}${C_BOLD}ВАЖНО:${C_RESET}"
echo -e "${C_YELLOW}ПОКА НЕ ЗАКРЫВАЙТЕ ЭТО ОКНО ТЕРМИНАЛА!${C_RESET}"
echo -e "Откройте ${C_BOLD}НОВОЕ${C_RESET} окно PowerShell на своём компьютере и проверьте вход командой:"
echo -e "  ${C_CYAN}ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -i \"\$env:USERPROFILE\\.ssh\\ИМЯ_ПРИВАТНОГО_КЛЮЧА\" ИМЯ_ПОЛЬЗОВАТЕЛЯ@АДРЕС_СЕРВЕРА${C_RESET}"
echo -e "Замените имя ключа, пользователя и адрес сервера на свои значения. Проверьте, что:"
echo -e "  1. Вход по SSH-ключу проходит успешно."
echo -e "  2. Сервер не запрашивает пароль."
echo -e "Закройте текущее окно только после успешной проверки в новом окне."
echo -e "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}\n"
