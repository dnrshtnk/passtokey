#!/usr/bin/env bash
# ==============================================================================
# Script: setup.sh (passtokey)
# Description: Disables password authentication, disables interactive login,
#              configures SSH key authentication, handles cloud-init overrides,
#              checks UFW firewall status, displays public key for other servers,
#              and supports Ubuntu 24.04+ (systemd socket activation & drop-in configs).
# Repository:  https://github.com/USERNAME/passtokey
# License:     MIT
# ==============================================================================

set -euo pipefail

# --- Color definitions ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'

# --- Logging functions ---
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

# --- Helper for interactive input (supports curl | bash via /dev/tty) ---
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

# --- State variables for rollback & cleanup ---
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

# --- Rollback handler ---
rollback() {
    [[ "${ROLLBACK_ACTIVE}" == "true" ]] || return 0
    log_error "An error occurred! Rolling back configuration changes..."

    if [[ -n "${BACKUP_DROPIN_CONF}" && -f "${BACKUP_DROPIN_CONF}" ]]; then
        cp -a "${BACKUP_DROPIN_CONF}" "${CREATED_DROPIN_CONF}"
    elif [[ -n "${CREATED_DROPIN_CONF}" ]]; then
        rm -f "${CREATED_DROPIN_CONF}"
    fi

    if [[ -n "${BACKUP_CLOUD_INIT_SSH}" && -f "${BACKUP_CLOUD_INIT_SSH}" ]]; then
        cp -f "${BACKUP_CLOUD_INIT_SSH}" /etc/ssh/sshd_config.d/50-cloud-init.conf
        log_info "Restored 50-cloud-init.conf from backup: ${BACKUP_CLOUD_INIT_SSH}"
    fi

    if [[ -n "${BACKUP_CLOUD_CFG}" && -f "${BACKUP_CLOUD_CFG}" ]]; then
        cp -a "${BACKUP_CLOUD_CFG}" "${CREATED_CLOUD_CFG}"
    elif [[ -n "${CREATED_CLOUD_CFG}" ]]; then
        rm -f "${CREATED_CLOUD_CFG}"
    fi

    if [[ -n "${BACKUP_SSHD_CONFIG}" && -f "${BACKUP_SSHD_CONFIG}" ]]; then
        cp -f "${BACKUP_SSHD_CONFIG}" /etc/ssh/sshd_config
        log_info "Restored sshd_config from backup: ${BACKUP_SSHD_CONFIG}"
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

    log_warn "Rollback completed. SSH configuration reverted to previous state."
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

# --- Validate OpenSSH Public Key Format ---
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

# --- CLI Options parsing ---
CLI_USER=""
CLI_KEY=""
CLI_NON_INTERACTIVE=false
CLI_KEY_VERIFIED=false

print_usage() {
    cat << EOF
Usage: sudo bash setup.sh [OPTIONS]

Options:
  -u, --user USER         Target username (default: detected SUDO_USER or first UID>=1000)
  -k, --key "KEY"         Public SSH key string to install
      --key-verified      Confirm key login was tested in a separate session
  -g, --generate          Removed; generate the private key on your client
  -y, --non-interactive   Run without prompts (requires --key-verified)
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "Option $1 requires a username."
                print_usage
                exit 1
            fi
            CLI_USER="$2"
            shift 2
            ;;
        -k|--key)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "Option $1 requires a public key string."
                print_usage
                exit 1
            fi
            CLI_KEY="$2"
            shift 2
            ;;
        -g|--generate)
            log_error "Server-side private-key generation is disabled. Generate the key on your client and pass its public key with --key."
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
            log_error "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
done

if [[ "${CLI_NON_INTERACTIVE}" == "true" ]]; then
    if [[ -z "${CLI_USER}" || -z "${CLI_KEY}" || "${CLI_KEY_VERIFIED}" != "true" ]]; then
        log_error "Non-interactive mode requires --user, --key, and --key-verified."
        exit 1
    fi
fi

echo -e "${C_BOLD}${C_BLUE}========================================================================${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}         PassToKey: SSH Hardening & Key Authentication Setup            ${C_RESET}"
echo -e "${C_BOLD}${C_BLUE}========================================================================${C_RESET}"

# --- 1. Root privileges check ---
log_step "Step 1: Checking user privileges"
if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be executed as root (or with sudo)!"
    echo "Usage: sudo bash $0"
    exit 1
fi
log_success "Running with root privileges."

# --- 2. Target user detection & verification ---
log_step "Step 2: Detecting target user"
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
        echo -e "Enter the username whose authorized_keys should be configured."
        prompt_read "Target username [default: ${DEFAULT_USER}]: " INPUT_USER
        TARGET_USER="${INPUT_USER:-${DEFAULT_USER}}"
    fi
fi

if ! id "${TARGET_USER}" &>/dev/null; then
    log_error "User '${TARGET_USER}' does not exist on this system!"
    exit 1
fi

TARGET_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
TARGET_GROUP=$(id -gn "${TARGET_USER}")

if [[ -z "${TARGET_HOME}" || ! -d "${TARGET_HOME}" ]]; then
    log_error "Home directory for user '${TARGET_USER}' ('${TARGET_HOME}') does not exist!"
    exit 1
fi
log_success "Selected user: ${C_BOLD}${TARGET_USER}${C_RESET} (Home: ${TARGET_HOME}, Group: ${TARGET_GROUP})"

# --- 3. Directory structure & permissions ---
log_step "Step 3: Setting up ~/.ssh and authorized_keys"
SSH_DIR="${TARGET_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [[ -d "${SSH_DIR}" ]]; then
    SSH_DIR_EXISTED=true
fi
if [[ -f "${AUTH_KEYS}" ]]; then
    AUTH_KEYS_EXISTED=true
    BACKUP_AUTH_KEYS="${AUTH_KEYS}.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp -a "${AUTH_KEYS}" "${BACKUP_AUTH_KEYS}"
    log_info "authorized_keys backup created: ${BACKUP_AUTH_KEYS}"
fi
ROLLBACK_ACTIVE=true

if [[ ! -d "${SSH_DIR}" ]]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
    log_info "Created directory: ${SSH_DIR} (mode 700)"
else
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
    log_info "Ensured permissions: ${SSH_DIR} (mode 700)"
fi

if [[ ! -f "${AUTH_KEYS}" ]]; then
    touch "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
    log_info "Created file: ${AUTH_KEYS} (mode 600)"
else
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
    log_info "Ensured permissions: ${AUTH_KEYS} (mode 600)"
fi

# --- 4. SSH Key Selection / Generation ---
log_step "Step 4: SSH Key Configuration"

if [[ -n "${CLI_KEY}" ]]; then
    # Provided via command-line
    KEY_TRIMMED="$(echo "${CLI_KEY}" | xargs)"
    if KEY_FP=$(validate_public_key "${KEY_TRIMMED}"); then
        log_success "Valid public key passed via arguments: ${KEY_FP}"
        NEWLY_CONFIGURED_PUBKEY="${KEY_TRIMMED}"
        if grep -Fxq "${KEY_TRIMMED}" "${AUTH_KEYS}" 2>/dev/null; then
            log_info "Key is already present in ${AUTH_KEYS}."
        else
            echo "${KEY_TRIMMED}" >> "${AUTH_KEYS}"
            log_success "Key appended to ${AUTH_KEYS}."
        fi
    else
        log_error "The key provided with --key is not a valid OpenSSH public key!"
        exit 1
    fi
else
    echo -e "Choose an option for user ${C_BOLD}${TARGET_USER}${C_RESET}:"
    echo -e "  ${C_BOLD}[1]${C_RESET} Paste an existing public key (${C_GREEN}Recommended${C_RESET})"
    echo -e "  ${C_BOLD}[2]${C_RESET} Keep existing keys in ~/.ssh/authorized_keys (skip adding new key)"
    SERVER_KEY_HOST="$(hostname -s 2>/dev/null | tr -cd '[:alnum:]_-')"
    SERVER_KEY_HOST="${SERVER_KEY_HOST:-ubuntu-server}"
    SERVER_INSTANCE_ID="$(sha256sum /etc/machine-id 2>/dev/null | cut -c1-8 || true)"
    SERVER_KEY_SUFFIX="${SERVER_KEY_HOST}${SERVER_INSTANCE_ID:+-${SERVER_INSTANCE_ID}}"
    SERVER_KEY_NAME="id_ed25519_${SERVER_KEY_SUFFIX}"
    echo -e "\n${C_CYAN}For option [1], use PowerShell on your LOCAL Windows computer (not on this server).${C_RESET}"
    echo -e "This key is named for this server so you can keep a separate key for each server: ${C_BOLD}${SERVER_KEY_NAME}${C_RESET}"
    echo -e "If this key does not exist yet, create it with:"
    printf '    New-Item -ItemType Directory -Force "$env:USERPROFILE\\.ssh" | Out-Null\n'
    printf '    ssh-keygen -t ed25519 -C "%s@%s" -f "$env:USERPROFILE\\.ssh\\%s"\n' "${TARGET_USER}" "${SERVER_KEY_SUFFIX}" "${SERVER_KEY_NAME}"
    echo -e "Then print the public key (or run this alone if the key already exists):"
    printf '    Get-Content "$env:USERPROFILE\\.ssh\\%s.pub"\n' "${SERVER_KEY_NAME}"
    echo -e "Paste the entire output line at the Key prompt. Only share the .pub file; keep the private key without .pub on your computer."

    KEY_CHOICE=""
    while [[ ! "${KEY_CHOICE}" =~ ^[1-2]$ ]]; do
        prompt_read "Enter choice [1/2]: " KEY_CHOICE
    done
fi

if [[ "${KEY_CHOICE:-}" == "1" ]]; then
    while true; do
        echo -e "\nPlease paste your public SSH key (e.g., ssh-ed25519 AAAAC3... or ssh-rsa AAAAB3...):"
        prompt_read "Key: " PASTED_KEY
        PASTED_KEY="$(echo "${PASTED_KEY:-}" | xargs)"

        if [[ -z "${PASTED_KEY}" ]]; then
            log_warn "Key cannot be empty. Please try again."
            continue
        fi

        if KEY_FP=$(validate_public_key "${PASTED_KEY}"); then
            log_success "Valid key confirmed: ${KEY_FP}"
            NEWLY_CONFIGURED_PUBKEY="${PASTED_KEY}"
            if grep -Fxq "${PASTED_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
                log_info "Key is already present in ${AUTH_KEYS}."
            else
                echo "${PASTED_KEY}" >> "${AUTH_KEYS}"
                log_success "Key successfully added to ${AUTH_KEYS}."
            fi
            break
        else
            log_error "Invalid OpenSSH public key format!"
            log_info "Expected standard format, e.g. 'ssh-ed25519 AAAA...' or 'ssh-rsa AAAA...'"
            prompt_read "Try again? [Y/n]: " RETRY_CHOICE
            if [[ "${RETRY_CHOICE:-}" =~ ^[Nn]$ ]]; then
                log_error "Operation canceled by user."
                exit 1
            fi
        fi
    done
elif [[ "${KEY_CHOICE:-}" == "2" ]]; then
    log_info "Proceeding with existing keys in ${AUTH_KEYS}."
fi

# Verify that authorized_keys contains at least ONE valid key
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
    log_error "No valid SSH public keys detected in ${AUTH_KEYS}!"
    log_error "Aborting immediately to prevent locking you out of the server."
    exit 1
fi
log_success "Verified ${VALID_KEY_COUNT} valid SSH key(s) in ${AUTH_KEYS}."

# Enforce final permissions on ~/.ssh
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}" "${AUTH_KEYS}"

if [[ "${CLI_NON_INTERACTIVE}" == "true" ]]; then
    if [[ "${CLI_KEY_VERIFIED}" != "true" ]]; then
        log_error "Refusing to disable password authentication without --key-verified."
        exit 1
    fi
else
    echo -e "\n${C_YELLOW}${C_BOLD}Before continuing, test key login in a separate terminal session.${C_RESET}"
    echo -e "Use your private key and connect as '${TARGET_USER}'. For a key-only test, use:"
    echo -e "  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -i <private-key> ${TARGET_USER}@<server-ip>"
    prompt_read "Did that new session log in successfully? Type 'yes' to disable password authentication: " KEY_LOGIN_CONFIRMED
    if [[ "${KEY_LOGIN_CONFIRMED:-}" != "yes" ]]; then
        log_error "Key login was not confirmed. Password authentication will remain unchanged."
        exit 1
    fi
fi

# --- 5. Inspect & Handle Cloud-Init Overrides ---
log_step "Step 5: Checking cloud-init configuration (50-cloud-init.conf)"
CLOUD_INIT_SSH_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"

if [[ -f "${CLOUD_INIT_SSH_CONF}" ]]; then
    log_warn "Detected cloud-init SSH configuration file: ${CLOUD_INIT_SSH_CONF}"
    BACKUP_CLOUD_INIT_SSH="/etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp "${CLOUD_INIT_SSH_CONF}" "${BACKUP_CLOUD_INIT_SSH}"
    log_info "Backup created: ${BACKUP_CLOUD_INIT_SSH}"

    # In OpenSSH, the FIRST match in configuration files wins.
    # If 50-cloud-init.conf defines PasswordAuthentication yes, it could override later drop-ins.
    if grep -E -q '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "${CLOUD_INIT_SSH_CONF}"; then
        log_info "Patching ${CLOUD_INIT_SSH_CONF} to disable password and interactive authentication..."
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)/PasswordAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+(yes|no)/KbdInteractiveAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+(yes|no)/ChallengeResponseAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        log_success "Updated directives in ${CLOUD_INIT_SSH_CONF}."
    else
        echo "PasswordAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        echo "KbdInteractiveAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        log_info "Appended disabled auth directives to ${CLOUD_INIT_SSH_CONF}."
    fi
else
    log_info "No cloud-init SSH override found (${CLOUD_INIT_SSH_CONF} not present)."
fi

# Prevent cloud-init from regenerating PasswordAuthentication yes on reboot
if [[ -d "/etc/cloud/cloud.cfg.d" ]]; then
    CREATED_CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-disable-passwords.cfg"
    if [[ -f "${CREATED_CLOUD_CFG}" ]]; then
        BACKUP_CLOUD_CFG="${CREATED_CLOUD_CFG}.bak.$(date +%Y%m%d_%H%M%S).$$"
        cp -a "${CREATED_CLOUD_CFG}" "${BACKUP_CLOUD_CFG}"
        log_info "Existing cloud-init override backed up: ${BACKUP_CLOUD_CFG}"
    fi
    log_info "Adding cloud-init persistence override: ${CREATED_CLOUD_CFG}"
    cat << 'EOF' > "${CREATED_CLOUD_CFG}"
# Created by passtokey
# Prevents cloud-init from re-enabling SSH password authentication on reboot or cloud-init run
ssh_pwauth: false
EOF
    log_success "Cloud-init override applied: ssh_pwauth=false"
fi

# --- 6. Configure SSH Daemon ---
log_step "Step 6: Hardening SSH Daemon configuration"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"

if [[ ! -f "${SSHD_CONFIG}" ]]; then
    log_error "Main SSH daemon configuration ${SSHD_CONFIG} not found!"
    exit 1
fi

BACKUP_SSHD_CONFIG="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S).$$"
cp "${SSHD_CONFIG}" "${BACKUP_SSHD_CONFIG}"
log_info "Backup created: ${BACKUP_SSHD_CONFIG}"

mkdir -p "${SSHD_CONFIG_D}"

# Ensure sshd_config includes drop-ins
if ! grep -E -q '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"; then
    log_info "Adding 'Include /etc/ssh/sshd_config.d/*.conf' to the beginning of ${SSHD_CONFIG}..."
    TEMP_SSHD_HEAD=$(mktemp)
    echo -e "Include /etc/ssh/sshd_config.d/*.conf\n$(cat "${SSHD_CONFIG}")" > "${TEMP_SSHD_HEAD}"
    cat "${TEMP_SSHD_HEAD}" > "${SSHD_CONFIG}"
    rm -f "${TEMP_SSHD_HEAD}"
fi

# Comment out any explicit 'yes' values in the main sshd_config so drop-ins take precedence
sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"

# OpenSSH uses the first matching configuration line.
# Name our drop-in with 01- prefix so it is parsed before 50-cloud-init.conf!
CREATED_DROPIN_CONF="${SSHD_CONFIG_D}/01-disable-password-auth.conf"
if [[ -f "${CREATED_DROPIN_CONF}" ]]; then
    BACKUP_DROPIN_CONF="${CREATED_DROPIN_CONF}.bak.$(date +%Y%m%d_%H%M%S).$$"
    cp -a "${CREATED_DROPIN_CONF}" "${BACKUP_DROPIN_CONF}"
    log_info "Existing SSH drop-in backed up: ${BACKUP_DROPIN_CONF}"
fi
log_info "Writing drop-in file: ${CREATED_DROPIN_CONF}"

cat << 'EOF' > "${CREATED_DROPIN_CONF}"
# ==============================================================================
# Managed by passtokey (https://github.com/USERNAME/passtokey)
# Hardening: Key-only authentication, disable password & interactive logins
# ==============================================================================

# Enable Public Key Authentication
PubkeyAuthentication yes

# Disable Password Authentication
PasswordAuthentication no

# Disable Keyboard-Interactive (PAM challenge/response interactive login)
KbdInteractiveAuthentication no

# Disable legacy ChallengeResponseAuthentication (alias for older OpenSSH)
ChallengeResponseAuthentication no

# Keep PAM enabled for session setup, motd, and env (without allowing auth prompts)
UsePAM yes
EOF

chmod 644 "${CREATED_DROPIN_CONF}"
log_success "Drop-in configuration created."

# --- 7. Validate SSH Configuration ---
log_step "Step 7: Validating SSH configuration (sshd -t)"
if ! sshd -t; then
    log_error "SSH configuration syntax validation failed!"
    rollback
    exit 1
fi
log_success "SSH configuration syntax is valid."

# --- 8. Check UFW Firewall Status ---
log_step "Step 8: Checking UFW Firewall Status"
UFW_DETECTED_STATUS="not_installed"

if command -v ufw &>/dev/null; then
    UFW_STATUS_RAW=$(ufw status 2>/dev/null || true)
    
    # Read effective SSH ports so Match blocks and included configuration are respected.
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
        UFW_DETECTED_STATUS="active"
        log_info "UFW Firewall is ${C_GREEN}${C_BOLD}ACTIVE${C_RESET}."
        
        if [[ "${#MISSING_SSH_PORTS[@]}" -eq 0 ]]; then
            log_success "UFW allows all effective SSH port(s): ${SSH_PORTS[*]}."
        else
            log_warn "UFW is active but may block SSH port(s): ${MISSING_SSH_PORTS[*]}."
            
            if [[ "${CLI_NON_INTERACTIVE}" != "true" ]]; then
                prompt_read "Allow the effective SSH port(s) ${MISSING_SSH_PORTS[*]} in UFW now? [Y/n]: " ALLOW_UFW
                if [[ ! "${ALLOW_UFW:-}" =~ ^[Nn]$ ]]; then
                    for port in "${MISSING_SSH_PORTS[@]}"; do
                        UFW_ADDED_PORTS+=("${port}")
                        ufw allow "${port}/tcp"
                    done
                    log_success "UFW rules added for SSH port(s): ${MISSING_SSH_PORTS[*]}."
                else
                    log_warn "SSH rule was NOT added to UFW. Please ensure your firewall permits SSH connections."
                fi
            else
                log_info "Non-interactive mode: allowing the effective SSH port(s) to avoid lockout."
                for port in "${MISSING_SSH_PORTS[@]}"; do
                    UFW_ADDED_PORTS+=("${port}")
                    ufw allow "${port}/tcp"
                done
                log_success "UFW rules added for SSH port(s): ${MISSING_SSH_PORTS[*]}."
            fi
        fi
    elif echo "${UFW_STATUS_RAW}" | grep -qi "Status: inactive"; then
        UFW_DETECTED_STATUS="inactive"
        log_info "UFW Firewall is ${C_YELLOW}${C_BOLD}INACTIVE${C_RESET} (disabled)."
        echo -e "  Traffic to SSH is not restricted by local UFW."
        echo -e "  ${C_CYAN}Tip:${C_RESET} If you enable UFW in the future, allow the effective SSH port(s): ${SSH_PORTS[*]}."

        if [[ "${CLI_NON_INTERACTIVE}" != "true" ]]; then
            prompt_read "Allow SSH port(s) ${SSH_PORTS[*]} and enable UFW now? [y/N]: " ENABLE_UFW
            if [[ "${ENABLE_UFW:-}" =~ ^[Yy]$ ]]; then
                allow_ssh_ports
                UFW_ENABLED_BY_SCRIPT=true
                ufw --force enable
                UFW_DETECTED_STATUS="active"
                log_success "SSH port(s) allowed and UFW enabled."
            fi
        fi
    else
        log_info "UFW status output: ${UFW_STATUS_RAW}"
    fi
else
    log_info "UFW (Uncomplicated Firewall) is not installed on this system."
fi

# --- 9. Reload / Restart SSH Service (Ubuntu 24.04+ Socket Activation Support) ---
log_step "Step 9: Applying configuration to SSH service"

systemctl daemon-reload

SSH_RELOADED=false

# Ubuntu 24.04+ uses systemd socket activation for ssh: ssh.socket
if systemctl is-active --quiet ssh.socket; then
    log_info "Detected active systemd socket: ssh.socket (Ubuntu 24.04+ mode)."
    if systemctl reload-or-restart ssh.socket 2>/dev/null && systemctl reload-or-restart ssh.service 2>/dev/null; then
        SSH_RELOADED=true
        log_success "Successfully reloaded/restarted ssh.socket & ssh.service."
    fi
fi

if [[ "${SSH_RELOADED}" == "false" ]]; then
    # Traditional systemd service
    if systemctl is-active --quiet ssh; then
        if systemctl reload-or-restart ssh 2>/dev/null || systemctl restart ssh 2>/dev/null; then
            SSH_RELOADED=true
            log_success "Successfully reloaded/restarted ssh service."
        fi
    elif systemctl is-active --quiet sshd; then
        if systemctl reload-or-restart sshd 2>/dev/null || systemctl restart sshd 2>/dev/null; then
            SSH_RELOADED=true
            log_success "Successfully reloaded/restarted sshd service."
        fi
    fi
fi

if [[ "${SSH_RELOADED}" == "false" ]]; then
    log_warn "Attempting fallback restart: systemctl restart ssh || ssh.socket || sshd..."
    if systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        SSH_RELOADED=true
        log_success "SSH service restarted via fallback."
    else
        log_error "Failed to reload/restart SSH service! Performing rollback..."
        rollback
        exit 1
    fi
fi

# Ensure SSH is currently active
if ! (systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket || systemctl is-active --quiet sshd); then
    log_error "SSH service or socket is not active after reload!"
    rollback
    systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || true
    exit 1
fi

# --- 10. Summary, Public Key Display & Final Instructions ---
log_step "Step 10: Setup Completed Successfully"
echo -e "${C_GREEN}${C_BOLD}"
echo "========================================================================"
echo "                   SSH HARDENING SUMMARY                                "
echo "========================================================================"
echo -e "${C_RESET}"
echo -e "Target user:              ${C_BOLD}${TARGET_USER}${C_RESET}"
echo -e "Authorized keys file:     ${C_BOLD}${AUTH_KEYS}${C_RESET}"
echo -e "SSHD drop-in config:      ${C_BOLD}${CREATED_DROPIN_CONF}${C_RESET}"
echo -e "UFW Firewall:             ${C_BOLD}${UFW_DETECTED_STATUS^^}${C_RESET}"
if [[ -n "${BACKUP_CLOUD_INIT_SSH}" ]]; then
echo -e "Cloud-init backup:        ${C_BOLD}${BACKUP_CLOUD_INIT_SSH}${C_RESET}"
fi
if [[ -n "${BACKUP_SSHD_CONFIG}" ]]; then
echo -e "Original sshd backup:     ${C_BOLD}${BACKUP_SSHD_CONFIG}${C_RESET}"
fi
echo -e "Password Authentication:  ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Interactive Login:        ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Public Key Auth:          ${C_GREEN}${C_BOLD}ENABLED${C_RESET}"

# Display public key(s) for copying to other servers
echo -e "\n${C_CYAN}${C_BOLD}========================================================================${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}         PUBLIC KEY(S) INSTALLED (FOR USE ON OTHER SERVERS)             ${C_RESET}"
echo -e "${C_CYAN}To allow login with this key on other servers, copy the line(s) below${C_RESET}"
echo -e "${C_CYAN}and add them to ~/.ssh/authorized_keys on the remote server:${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}------------------------------------------------------------------------${C_RESET}"

if [[ -n "${NEWLY_CONFIGURED_PUBKEY}" ]]; then
    echo -e "${C_BOLD}${NEWLY_CONFIGURED_PUBKEY}${C_RESET}"
else
    # Show valid keys from authorized_keys
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
echo -e "${C_YELLOW}${C_BOLD}CRITICAL SAFETY NOTICE:${C_RESET}"
echo -e "${C_YELLOW}DO NOT CLOSE THIS TERMINAL SESSION YET!${C_RESET}"
echo -e "Open a ${C_BOLD}NEW${C_RESET} terminal window on your local machine and verify login:"
echo -e "\n  ${C_CYAN}ssh ${TARGET_USER}@$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')${C_RESET}"
echo -e "  (or: ${C_CYAN}ssh -i <path_to_private_key> ${TARGET_USER}@<server-ip>${C_RESET})\n"
echo -e "Confirm that:"
echo -e "  1. You can log in using your SSH key."
echo -e "  2. You are NEVER asked for a password."
echo -e "Only close this current terminal after testing in a separate window!"
echo -e "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}\n"
