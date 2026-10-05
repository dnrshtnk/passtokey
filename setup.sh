#!/usr/bin/env bash
# ==============================================================================
# Script: setup.sh (passtokey)
# Description: Disables password authentication, disables interactive login,
#              configures SSH key authentication, handles cloud-init overrides,
#              and supports Ubuntu 24.04+ (systemd socket activation & drop-in configs).
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

# --- State variables for rollback ---
BACKUP_SSHD_CONFIG=""
BACKUP_CLOUD_INIT_SSH=""
CREATED_DROPIN_CONF=""
CREATED_CLOUD_CFG=""

cleanup_tmp() {
    if [[ -n "${TMP_KEY_FILE:-}" && -f "${TMP_KEY_FILE:-}" ]]; then
        rm -f "${TMP_KEY_FILE}" "${TMP_KEY_FILE}.pub" 2>/dev/null || true
    fi
}
trap cleanup_tmp EXIT

# --- Rollback handler ---
rollback() {
    log_error "Something went wrong! Rolling back configuration changes..."

    if [[ -n "${CREATED_DROPIN_CONF}" && -f "${CREATED_DROPIN_CONF}" ]]; then
        rm -f "${CREATED_DROPIN_CONF}"
        log_info "Removed created drop-in configuration: ${CREATED_DROPIN_CONF}"
    fi

    if [[ -n "${BACKUP_CLOUD_INIT_SSH}" && -f "${BACKUP_CLOUD_INIT_SSH}" ]]; then
        cp -f "${BACKUP_CLOUD_INIT_SSH}" /etc/ssh/sshd_config.d/50-cloud-init.conf
        log_info "Restored 50-cloud-init.conf from backup"
    fi

    if [[ -n "${CREATED_CLOUD_CFG}" && -f "${CREATED_CLOUD_CFG}" ]]; then
        rm -f "${CREATED_CLOUD_CFG}"
        log_info "Removed cloud-init override: ${CREATED_CLOUD_CFG}"
    fi

    if [[ -n "${BACKUP_SSHD_CONFIG}" && -f "${BACKUP_SSHD_CONFIG}" ]]; then
        cp -f "${BACKUP_SSHD_CONFIG}" /etc/ssh/sshd_config
        log_info "Restored sshd_config from backup"
    fi

    log_warn "Rollback completed. SSH configuration reverted to previous state."
}

# --- 1. Root check ---
log_step "Step 1: Checking user privileges"
if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script must be run as root or with sudo privileges!"
    echo "Usage: sudo bash $0"
    exit 1
fi
log_success "Running with root privileges."

# --- 2. Determine target user ---
log_step "Step 2: Selecting target user for SSH key configuration"
DEFAULT_USER=""
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    DEFAULT_USER="${SUDO_USER}"
else
    # Find the first non-system user (UID >= 1000)
    FIRST_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)/ { print $1; exit }' /etc/passwd 2>/dev/null || true)
    if [[ -n "${FIRST_USER}" ]]; then
        DEFAULT_USER="${FIRST_USER}"
    else
        DEFAULT_USER="root"
    fi
fi

echo -e "Target user will receive the SSH authorized key."
read -r -p "Enter target username [default: ${DEFAULT_USER}]: " INPUT_USER
TARGET_USER="${INPUT_USER:-${DEFAULT_USER}}"

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
log_success "Target user: ${TARGET_USER} (Home: ${TARGET_HOME}, Group: ${TARGET_GROUP})"

# --- 3. Prepare ~/.ssh and authorized_keys ---
log_step "Step 3: Preparing ~/.ssh directory and permissions"
SSH_DIR="${TARGET_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

if [[ ! -d "${SSH_DIR}" ]]; then
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
    log_info "Created directory: ${SSH_DIR} (permissions: 700)"
else
    chmod 700 "${SSH_DIR}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"
fi

if [[ ! -f "${AUTH_KEYS}" ]]; then
    touch "${AUTH_KEYS}"
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
    log_info "Created file: ${AUTH_KEYS} (permissions: 600)"
else
    chmod 600 "${AUTH_KEYS}"
    chown "${TARGET_USER}:${TARGET_GROUP}" "${AUTH_KEYS}"
fi

# Function to validate an OpenSSH public key
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

# --- 4. SSH Key Selection / Generation ---
log_step "Step 4: SSH Key Configuration"
echo -e "Choose an option:"
echo -e "  ${C_BOLD}[1]${C_RESET} Paste an existing public key (${C_GREEN}Recommended${C_RESET})"
echo -e "  ${C_BOLD}[2]${C_RESET} Generate a new ED25519 key pair on this server"
echo -e "  ${C_BOLD}[3]${C_RESET} Keep existing keys in ~/.ssh/authorized_keys (if already configured)"

KEY_CHOICE=""
while [[ ! "${KEY_CHOICE}" =~ ^[1-3]$ ]]; do
    read -r -p "Enter choice [1/2/3]: " KEY_CHOICE
done

case "${KEY_CHOICE}" in
    1)
        while true; do
            echo -e "\nPlease paste your public SSH key (e.g. ssh-ed25519 AAAAC3... or ssh-rsa AAAAB3...):"
            read -r PASTED_KEY
            # Trim whitespace
            PASTED_KEY="$(echo "${PASTED_KEY}" | xargs)"

            if [[ -z "${PASTED_KEY}" ]]; then
                log_warn "Key cannot be empty. Please try again."
                continue
            fi

            if KEY_FP=$(validate_public_key "${PASTED_KEY}"); then
                log_success "Valid key detected: ${KEY_FP}"
                
                # Check if already present in authorized_keys
                if grep -Fxq "${PASTED_KEY}" "${AUTH_KEYS}" 2>/dev/null; then
                    log_info "This key is already present in ${AUTH_KEYS}."
                else
                    echo "${PASTED_KEY}" >> "${AUTH_KEYS}"
                    log_success "Key added to ${AUTH_KEYS}."
                fi
                break
            else
                log_error "Invalid SSH public key format! Expected format like: ssh-ed25519 AAAA... or ssh-rsa AAAA..."
                read -r -p "Do you want to retry? [Y/n]: " RETRY_CHOICE
                if [[ "${RETRY_CHOICE}" =~ ^[Nn]$ ]]; then
                    log_error "Aborted by user."
                    exit 1
                fi
            fi
        done
        ;;

    2)
        log_info "Generating a new ED25519 key pair..."
        TMP_KEY_FILE=$(mktemp -u)
        KEY_COMMENT="${TARGET_USER}@$(hostname)-$(date +%Y%m%d)"
        ssh-keygen -t ed25519 -a 100 -C "${KEY_COMMENT}" -f "${TMP_KEY_FILE}" -N "" >/dev/null

        PUB_KEY_CONTENT=$(cat "${TMP_KEY_FILE}.pub")
        PRIV_KEY_CONTENT=$(cat "${TMP_KEY_FILE}")

        # Add public key to authorized_keys
        echo "${PUB_KEY_CONTENT}" >> "${AUTH_KEYS}"
        log_success "Public key appended to ${AUTH_KEYS}."

        echo -e "\n${C_RED}${C_BOLD}======================================================================${C_RESET}"
        echo -e "${C_YELLOW}${C_BOLD}                   YOUR NEW PRIVATE SSH KEY                           ${C_RESET}"
        echo -e "${C_YELLOW}Copy and save the private key below onto your local machine NOW!${C_RESET}"
        echo -e "${C_YELLOW}Save it as ~/.ssh/id_ed25519 (chmod 600) on your client computer.${C_RESET}"
        echo -e "${C_RED}${C_BOLD}======================================================================${C_RESET}\n"
        echo -e "${C_CYAN}${PRIV_KEY_CONTENT}${C_RESET}\n"
        echo -e "${C_RED}${C_BOLD}======================================================================${C_RESET}"

        # Delete private key securely from server memory/file
        rm -f "${TMP_KEY_FILE}" "${TMP_KEY_FILE}.pub"

        echo -e "\n${C_BOLD}Confirmation required:${C_RESET}"
        while true; do
            read -r -p "Have you copied and saved the private key securely? (type 'yes' to proceed): " CONFIRM_KEY
            if [[ "${CONFIRM_KEY}" == "yes" ]]; then
                break
            fi
            log_warn "Please copy the private key and type 'yes' when done."
        done
        ;;

    3)
        log_info "Verifying existing keys in ${AUTH_KEYS}..."
        ;;
esac

# Ensure authorized_keys has at least one valid key before proceeding
VALID_KEY_COUNT=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    line_trimmed="$(echo "${line}" | xargs)"
    [[ -z "${line_trimmed}" || "${line_trimmed}" =~ ^# ]] && continue
    if validate_public_key "${line_trimmed}" &>/dev/null; then
        ((VALID_KEY_COUNT++))
    fi
done < "${AUTH_KEYS}"

if [[ "${VALID_KEY_COUNT}" -eq 0 ]]; then
    log_error "No valid SSH keys found in ${AUTH_KEYS}!"
    log_error "Aborting to prevent locking you out of the server."
    exit 1
fi
log_success "Found ${VALID_KEY_COUNT} valid SSH key(s) in ${AUTH_KEYS}."

# Ensure final permissions
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chown -R "${TARGET_USER}:${TARGET_GROUP}" "${SSH_DIR}"

# --- 5. Inspect Cloud-Init Overrides ---
log_step "Step 5: Inspecting cloud-init configurations (50-cloud-init.conf)"
CLOUD_INIT_SSH_CONF="/etc/ssh/sshd_config.d/50-cloud-init.conf"

if [[ -f "${CLOUD_INIT_SSH_CONF}" ]]; then
    log_warn "Found cloud-init SSH configuration file: ${CLOUD_INIT_SSH_CONF}"
    BACKUP_CLOUD_INIT_SSH="/etc/ssh/sshd_config.d/50-cloud-init.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cp "${CLOUD_INIT_SSH_CONF}" "${BACKUP_CLOUD_INIT_SSH}"
    log_info "Created backup: ${BACKUP_CLOUD_INIT_SSH}"

    # In OpenSSH, the FIRST directive encountered in sshd_config or included files takes precedence!
    # If 50-cloud-init.conf contains PasswordAuthentication yes, it could override drop-ins loaded after it.
    if grep -E -q '^[[:space:]]*(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)' "${CLOUD_INIT_SSH_CONF}"; then
        log_info "Modifying 50-cloud-init.conf to disable password and interactive authentication..."
        sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+(yes|no)/PasswordAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+(yes|no)/KbdInteractiveAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+(yes|no)/ChallengeResponseAuthentication no/g' "${CLOUD_INIT_SSH_CONF}"
        log_success "Updated directives in ${CLOUD_INIT_SSH_CONF}."
    else
        echo "PasswordAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        echo "KbdInteractiveAuthentication no" >> "${CLOUD_INIT_SSH_CONF}"
        log_info "Appended disabled password auth settings to ${CLOUD_INIT_SSH_CONF}."
    fi
else
    log_info "No 50-cloud-init.conf found. Proceeding."
fi

# Ensure cloud-init does not revert settings on next boot/reprovision
if [[ -d "/etc/cloud/cloud.cfg.d" ]]; then
    CREATED_CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-disable-passwords.cfg"
    log_info "Creating cloud-init persistence override: ${CREATED_CLOUD_CFG}"
    cat << 'EOF' > "${CREATED_CLOUD_CFG}"
# Created by passtokey script
# Prevent cloud-init from re-enabling password authentication on reboot/upgrade
ssh_pwauth: false
EOF
    log_success "Cloud-init persistence override configured (ssh_pwauth: false)."
fi

# --- 6. Configure SSH Daemon ---
log_step "Step 6: Configuring SSH daemon settings"
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_D="/etc/ssh/sshd_config.d"

if [[ ! -f "${SSHD_CONFIG}" ]]; then
    log_error "SSH configuration file ${SSHD_CONFIG} not found!"
    exit 1
fi

BACKUP_SSHD_CONFIG="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
cp "${SSHD_CONFIG}" "${BACKUP_SSHD_CONFIG}"
log_info "Created backup: ${BACKUP_SSHD_CONFIG}"

# Ensure sshd_config includes sshd_config.d/*.conf
mkdir -p "${SSHD_CONFIG_D}"
if ! grep -E -q '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"; then
    log_info "Adding 'Include /etc/ssh/sshd_config.d/*.conf' to top of ${SSHD_CONFIG}..."
    # Prepend Include line to ensure drop-ins are processed
    echo -e "Include /etc/ssh/sshd_config.d/*.conf\n$(cat "${SSHD_CONFIG}")" > "${SSHD_CONFIG}"
fi

# Check for hardcoded PasswordAuthentication yes in sshd_config before Include
# Comment them out to avoid overriding drop-in configurations
sed -i -E 's/^[[:space:]]*PasswordAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"
sed -i -E 's/^[[:space:]]*ChallengeResponseAuthentication[[:space:]]+yes/# & (disabled by passtokey)/g' "${SSHD_CONFIG}"

# In OpenSSH, first match wins. Name drop-in with 01- prefix so it is evaluated before 50-cloud-init.conf!
CREATED_DROPIN_CONF="${SSHD_CONFIG_D}/01-disable-password-auth.conf"
log_info "Writing drop-in configuration: ${CREATED_DROPIN_CONF}"

cat << 'EOF' > "${CREATED_DROPIN_CONF}"
# ==============================================================================
# Managed by passtokey
# Hardening: Disable password authentication & interactive login
# ==============================================================================

# Enable Public Key Authentication
PubkeyAuthentication yes

# Disable Password Authentication
PasswordAuthentication no

# Disable Keyboard-Interactive (interactive password / PAM prompt) Authentication
KbdInteractiveAuthentication no

# Legacy alias for KbdInteractiveAuthentication (for older OpenSSH versions compatibility)
ChallengeResponseAuthentication no

# Keep PAM enabled for environment/session initialization, but disable auth prompts
UsePAM yes
EOF

chmod 644 "${CREATED_DROPIN_CONF}"
log_success "Drop-in configuration written successfully."

# --- 7. Validate SSH Configuration ---
log_step "Step 7: Validating SSH configuration syntax (sshd -t)"
if ! sshd -t; then
    log_error "SSH configuration syntax validation failed!"
    rollback
    exit 1
fi
log_success "SSH configuration syntax verified successfully."

# --- 8. Reload / Restart SSH Service (Ubuntu 24.04+ compatible) ---
log_step "Step 8: Reloading/Restarting SSH service"

systemctl daemon-reload

SSH_RESTARTED=false

# Ubuntu 24.04 LTS uses systemd socket activation (ssh.socket) by default
if systemctl is-active --quiet ssh.socket; then
    log_info "Detected active ssh.socket (Ubuntu 24.04+ socket activation)."
    if systemctl reload-or-restart ssh.socket; then
        # Also restart existing service if running
        systemctl reload-or-restart ssh.service 2>/dev/null || true
        SSH_RESTARTED=true
        log_success "Successfully reloaded/restarted ssh.socket."
    fi
fi

if [[ "${SSH_RESTARTED}" == "false" ]]; then
    # Traditional service reload/restart
    if systemctl is-active --quiet ssh; then
        if systemctl reload-or-restart ssh; then
            SSH_RESTARTED=true
            log_success "Successfully reloaded/restarted ssh service."
        fi
    elif systemctl is-active --quiet sshd; then
        if systemctl reload-or-restart sshd; then
            SSH_RESTARTED=true
            log_success "Successfully reloaded/restarted sshd service."
        fi
    fi
fi

# Fallback restart attempt if reload didn't trigger
if [[ "${SSH_RESTARTED}" == "false" ]]; then
    log_warn "Standard reload didn't match. Attempting systemctl restart ssh || ssh.socket..."
    if systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || systemctl restart sshd 2>/dev/null; then
        SSH_RESTARTED=true
        log_success "SSH service restarted."
    else
        log_error "Failed to restart SSH service! Please check systemctl status ssh."
        rollback
        exit 1
    fi
fi

# Verification that SSH is still alive
if ! (systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket || systemctl is-active --quiet sshd); then
    log_error "SSH daemon/socket is NOT active after restart!"
    rollback
    systemctl restart ssh 2>/dev/null || systemctl restart ssh.socket 2>/dev/null || true
    exit 1
fi

# --- 9. Final Instructions and Verification ---
log_step "Step 9: Verification Summary"
echo -e "${C_GREEN}${C_BOLD}"
echo "========================================================================"
echo "                   SSH HARDENING COMPLETED SUCCESSFULLY                 "
echo "========================================================================"
echo -e "${C_RESET}"
echo -e "User configured:          ${C_BOLD}${TARGET_USER}${C_RESET}"
echo -e "Authorized keys file:     ${C_BOLD}${AUTH_KEYS}${C_RESET}"
echo -e "Drop-in configuration:    ${C_BOLD}${CREATED_DROPIN_CONF}${C_RESET}"
if [[ -n "${BACKUP_CLOUD_INIT_SSH}" ]]; then
echo -e "Cloud-init backup:        ${C_BOLD}${BACKUP_CLOUD_INIT_SSH}${C_RESET}"
fi
echo -e "Password authentication:  ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Interactive login:        ${C_RED}${C_BOLD}DISABLED${C_RESET}"
echo -e "Public key login:         ${C_GREEN}${C_BOLD}ENABLED${C_RESET}"

echo -e "\n${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}"
echo -e "${C_YELLOW}${C_BOLD}CRITICAL SAFETY NOTICE:${C_RESET}"
echo -e "${C_YELLOW}DO NOT CLOSE THIS TERMINAL SESSION YET!${C_RESET}"
echo -e "Open a ${C_BOLD}NEW${C_RESET} terminal window on your local computer and test logging in:"
echo -e "\n  ${C_CYAN}ssh -i <path_to_private_key> ${TARGET_USER}@<server-ip>${C_RESET}\n"
echo -e "Verify that:"
echo -e "  1. You can log in using your SSH key."
echo -e "  2. You are never prompted for a password."
echo -e "Only close this session once you have confirmed your key-based login works."
echo -e "${C_RED}${C_BOLD}!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!${C_RESET}\n"
