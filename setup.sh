#!/usr/bin/env bash
# ==============================================================================
# Script: setup.sh (passtokey)
# Description: Disables password authentication, disables interactive login,
#              configures SSH key authentication, handles cloud-init overrides,
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
TMP_KEY_FILE=""

cleanup_tmp() {
    if [[ -n "${TMP_KEY_FILE:-}" && -f "${TMP_KEY_FILE:-}" ]]; then
        rm -f "${TMP_KEY_FILE}" "${TMP_KEY_FILE}.pub" 2>/dev/null || true
    fi
}
trap cleanup_tmp EXIT

# --- Rollback handler ---
rollback() {
    log_error "An error occurred! Rolling back configuration changes..."

    if [[ -n "${CREATED_DROPIN_CONF}" && -f "${CREATED_DROPIN_CONF}" ]]; then
        rm -f "${CREATED_DROPIN_CONF}"
        log_info "Removed drop-in configuration: ${CREATED_DROPIN_CONF}"
    fi

    if [[ -n "${BACKUP_CLOUD_INIT_SSH}" && -f "${BACKUP_CLOUD_INIT_SSH}" ]]; then
        cp -f "${BACKUP_CLOUD_INIT_SSH}" /etc/ssh/sshd_config.d/50-cloud-init.conf
        log_info "Restored 50-cloud-init.conf from backup: ${BACKUP_CLOUD_INIT_SSH}"
    fi

    if [[ -n "${CREATED_CLOUD_CFG}" && -f "${CREATED_CLOUD_CFG}" ]]; then
        rm -f "${CREATED_CLOUD_CFG}"
        log_info "Removed cloud-init override: ${CREATED_CLOUD_CFG}"
    fi

    if [[ -n "${BACKUP_SSHD_CONFIG}" && -f "${BACKUP_SSHD_CONFIG}" ]]; then
        cp -f "${BACKUP_SSHD_CONFIG}" /etc/ssh/sshd_config
        log_info "Restored sshd_config from backup: ${BACKUP_SSHD_CONFIG}"
    fi

    log_warn "Rollback completed. SSH configuration reverted to previous state."
}

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
CLI_GENERATE=false
CLI_NON_INTERACTIVE=false

print_usage() {
    cat << EOF
Usage: sudo bash setup.sh [OPTIONS]

Options:
  -u, --user USER         Target username (default: detected SUDO_USER or first UID>=1000)
  -k, --key "KEY"         Public SSH key string to install
  -g, --generate          Automatically generate a new Ed25519 key pair
  -y, --non-interactive   Run without interactive confirmation prompts
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)
            CLI_USER="$2"
            shift 2
            ;;
        -k|--key)
            CLI_KEY="$2"
            shift 2
            ;;
        -g|--generate)
            CLI_GENERATE=true
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
elif [[ "${CLI_GENERATE}" == "true" ]]; then
    KEY_CHOICE="2"
else
    echo -e "Choose an option for user ${C_BOLD}${TARGET_USER}${C_RESET}:"
    echo -e "  ${C_BOLD}[1]${C_RESET} Paste an existing public key (${C_GREEN}Recommended${C_RESET})"
    echo -e "  ${C_BOLD}[2]${C_RESET} Generate a new ED25519 key pair on this server"
    echo -e "  ${C_BOLD}[3]${C_RESET} Keep existing keys in ~/.ssh/authorized_keys (skip adding new key)"

    KEY_CHOICE=""
    while [[ ! "${KEY_CHOICE}" =~ ^[1-3]$ ]]; do
        prompt_read "Enter choice [1/2/3]: " KEY_CHOICE
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
    log_info "Generating a secure ED25519 SSH key pair..."
    TMP_KEY_FILE=$(mktemp -u)
    KEY_COMMENT="${TARGET_USER}@$(hostname)-$(date +%Y%m%d)"
    ssh-keygen -t ed25519 -a 100 -C "${KEY_COMMENT}" -f "${TMP_KEY_FILE}" -N "" >/dev/null

    PUB_KEY_CONTENT=$(cat "${TMP_KEY_FILE}.pub")
    PRIV_KEY_CONTENT=$(cat "${TMP_KEY_FILE}")

    echo "${PUB_KEY_CONTENT}" >> "${AUTH_KEYS}"
    log_success "New public key appended to ${AUTH_KEYS}."

    echo -e "\n${C_RED}${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_YELLOW}${C_BOLD}                  YOUR NEW PRIVATE SSH KEY (ED25519)                  ${C_RESET}"
    echo -e "${C_YELLOW}Copy and save the private key block below on your local machine NOW!${C_RESET}"
    echo -e "${C_YELLOW}Save it as ~/.ssh/id_ed25519 on your client (run 'chmod 600 ~/.ssh/id_ed25519').${C_RESET}"
    echo -e "${C_RED}${C_BOLD}======================================================================${C_RESET}\n"
    echo -e "${C_CYAN}${PRIV_KEY_CONTENT}${C_RESET}\n"
    echo -e "${C_RED}${C_BOLD}======================================================================${C_RESET}"

    # Remove temporary private key from disk
    rm -f "${TMP_KEY_FILE}" "${TMP_KEY_FILE}.pub"
    TMP_KEY_FILE=""

    if [[ "${CLI_NON_INTERACTIVE}" != "true" ]]; then
        echo -e "\n${C_BOLD}Confirmation required:${C_RESET}"
        while true; do
            prompt_read "Have you saved the private key securely? (type 'yes' to proceed): " CONFIRM_KEY
            if [[ "${CONFIRM_KEY:-}" == "yes" ]]; then
                break
            fi
            log_warn "Please copy the key and type 'yes' when ready."
        done
    fi
elif [[ "${KEY_CHOICE:-}" == "3" ]]; then
    log_info "Proceeding with existing keys in ${AUTH_KEYS}."
fi

# Verify that authorized_keys contains at least ONE valid key
VALID_KEY_COUNT=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_trimmed="$(echo "${line}" | xargs)"
    [[ -z "${line_trimmed}" || "${line_trimmed}" =~ ^# ]] && continue
    if validate_public_key "${line_trimmed}" &>/dev/null; then
        ((VALID_KEY_COUNT++))
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
chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"

# --- 5. Inspect & Handle Cloud-Init Overrides ---
log_step "Step 5: Checking cloud-init configuration (50-cloud-init.conf)"
CLOUD_INIT_SSH_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"

if [[ -f "${CLOUD_INIT_SSH_CONF}" ]]; then
    log_warn "Detected cloud-init SSH configuration file: ${CLOUD_INIT_SSH_CONF}"
    BACKUP_CLOUD_INIT_SSH="/etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%Y%m%d_%H%M%S)"
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

BACKUP_SSHD_CONFIG="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
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

# --- 8. Reload / Restart SSH Service (Ubuntu 24.04+ Socket Activation Support) ---
log_step "Step 8: Applying configuration to SSH service"

systemctl daemon-reload

SSH_RELOADED=false

# Ubuntu 24.04+ uses systemd socket activation for ssh: ssh.socket
if systemctl is-active --quiet ssh.socket; then
    log_info "Detected active systemd socket: ssh.socket (Ubuntu 24.04+ mode)."
    if systemctl reload-or-restart ssh.socket 2>/dev/null; then
        systemctl reload-or-restart ssh.service 2>/dev/null || true
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

# --- 9. Summary & Final Instructions ---
log_step "Step 9: Setup Completed Successfully"
echo -e "${C_GREEN}${C_BOLD}"
echo "========================================================================"
echo "                   SSH HARDENING SUMMARY                                "
echo "========================================================================"
echo -e "${C_RESET}"
echo -e "Target user:              ${C_BOLD}${TARGET_USER}${C_RESET}"
echo -e "Authorized keys file:     ${C_BOLD}${AUTH_KEYS}${C_RESET}"
echo -e "SSHD drop-in config:      ${C_BOLD}${CREATED_DROPIN_CONF}${C_RESET}"
if [[ -n "${BACKUP_CLOUD_INIT_SSH}" ]]; then
echo -e "Cloud-init backup:        ${C_BOLD}${BACKUP_CLOUD_INIT_SSH}${C_RESET}"
fi
if [[ -n "${BACKUP_SSHD_CONFIG}" ]]; then
echo -e "Original sshd backup:     ${C_BOLD}${BACKUP_SSHD_CONFIG}${C_RESET}"
fi
echo -e "Password Authentication:  ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Interactive Login:        ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Public Key Auth:          ${C_GREEN}${C_BOLD}ENABLED${C_RESET}"

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
