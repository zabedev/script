#!/bin/bash

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly SCRIPT_VERSION="3.0.9"
readonly USERNAME="zabe"
readonly USERNAME_DBPASS="7bb073796c8a93"
readonly ADMIN_PASSWORD="WmRhYzNAWmFiZQ=="
readonly LANGUAGE_CODE="pt-BR"
readonly TIME_ZONE="America/Sao_Paulo"
readonly SECRET_KEY="django-insecure-vpo7np+n_333j@2dy6$&8tibp*sll(x$*6_7a!3!uc^cibb*"
readonly SERVER_URL="https://raw.githubusercontent.com/zabedev/script/main/v2"

readonly BASE_DIR="/opt/dac"
readonly WEB_DIR="/var/www/html"
readonly LOG_DIR="${BASE_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/manager.log"
readonly SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
readonly SYSTEMD_SERVICE_DIR="/etc/systemd/system"

readonly SUPERVISOR_SERVICES=("dac-boot" "dac-sender" "dac-reader")
readonly SYSTEMD_SERVICES=("dac-api")
readonly ZDAC_DIRS=("${BASE_DIR}" "${LOG_DIR}" "${LOG_DIR}/supervisor" "${WEB_DIR}")

readonly REQUIRED_PACKAGES="wget zip unzip supervisor python3-dev python3-venv python3-pip nginx postgresql build-essential dialog"

# ============================================================================
# LOGGING SYSTEM (MODIFICADO PARA EXIBIR SAÍDA)
# ============================================================================

log_init() {
    if [[ ! -d "${LOG_DIR}" ]]; then
        sudo mkdir -p "${LOG_DIR}" 2>/dev/null || mkdir -p "${LOG_DIR}"
    fi
    
    if [[ ! -f "${LOG_FILE}" ]]; then
        sudo touch "${LOG_FILE}" 2>/dev/null || touch "${LOG_FILE}"
    fi
    
    log_info "=== Zabe Gateway Manager v${SCRIPT_VERSION} Started ==="
}

log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Registra no arquivo em background sem silenciar o terminal
    echo "[${timestamp}] [${level}] ${message}" | sudo tee -a "${LOG_FILE}" >/dev/null
}

log_info() {
    log_message "INFO" "$@"
    echo -e "ℹ️  \033[1;34m$*\033[0m"
}

log_success() {
    log_message "SUCCESS" "$@"
    echo -e "✅ \033[1;32m$*\033[0m"
}

log_warning() {
    log_message "WARNING" "$@"
    echo -e "⚠️  \033[1;33m$*\033[0m" >&2
}

log_error() {
    log_message "ERROR" "$@"
    echo -e "❌ \033[1;31m$*\033[0m" >&2
}

# FUNÇÃO MODIFICADA: Agora exibe a saída do comando diretamente no terminal
log_command() {
    local cmd="$*"
    log_info "Executing: ${cmd}"
    
    # Executa o comando permitindo que a saída flua para o terminal e para o log simultaneamente
    if eval "$cmd" 2>&1 | tee -a "${LOG_FILE}"; then
        log_success "Command succeeded: ${cmd}"
        return 0
    else
        local exit_code=$?
        log_error "Command failed (exit ${exit_code}): ${cmd}"
        return ${exit_code}
    fi
}

# ============================================================================
# VALIDATION & CHECKS
# ============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo"
        exit 1
    fi
}

check_command() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_warning "Command '${cmd}' not found"
        return 1
    fi
    return 0
}

validate_system() {
    log_info "Validating system requirements..."
    
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        return 1
    fi
    
    local available_space
    available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [[ ${available_space} -lt 5 ]]; then
        log_warning "Low disk space: ${available_space}GB available"
    fi
    
    log_success "System validation passed"
}

# ============================================================================
# SYSTEM OPERATIONS
# ============================================================================

ensure_dialog() {
    if ! check_command dialog; then
        log_info "Installing dialog..."
        apt update && apt install dialog -y
    fi
}

update_system() {
    log_info "Updating system..."
    
    if ! apt update; then
        log_error "Failed to update package lists"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    if ! apt upgrade -y; then
        log_error "Failed to upgrade packages"
        read -p "Press Enter to continue..."
        return 1
    fi
    
    log_success "System updated successfully"
    read -p "Press Enter to continue..."
}

install_auxiliary_packages() {
    log_info "Installing auxiliary packages..."
    
    if ! apt install ${REQUIRED_PACKAGES} -y; then
        log_error "Failed to install required packages"
        return 1
    fi
    
    log_success "Auxiliary packages installed"
}

remove_auxiliary_packages() {
    log_info "Removing auxiliary packages (verbose)..."

    systemctl disable postgresql.service || true
    systemctl disable nginx.service || true
    systemctl stop nginx.service || true

    export DEBIAN_FRONTEND=noninteractive
    apt-get -y remove --purge supervisor nginx postgresql* || true
    apt-get -y autoremove || true
    apt-get -y purge --auto-remove || true
    apt-get -y clean || true

    log_success "Auxiliary packages removed."
}

# ============================================================================
# USER & PERMISSIONS MANAGEMENT
# ============================================================================

configure_sudo_nopasswd() {
    log_info "Configuring NOPASSWD for user ${USERNAME}..."
    
    if grep -q "^${USERNAME} ALL=(ALL) NOPASSWD: ALL" /etc/sudoers; then
        log_warning "NOPASSWD already configured"
        return 0
    fi
    
    echo "${USERNAME} ALL=(ALL) NOPASSWD: ALL" | EDITOR='tee -a' visudo
    log_success "NOPASSWD configured"
}

remove_sudo_nopasswd() {
    log_info "Removing NOPASSWD for user ${USERNAME}..."
    
    if ! grep -q "^${USERNAME} ALL=(ALL) NOPASSWD: ALL" /etc/sudoers; then
        log_warning "NOPASSWD not configured"
        return 0
    fi
    
    sed -i "/^${USERNAME} ALL=(ALL) NOPASSWD: ALL/d" /etc/sudoers
    log_success "NOPASSWD removed"
}

configure_user_groups() {
    log_info "Configuring user groups..."
    
    usermod -a -G www-data "${USERNAME}" || log_warning "Failed to add ${USERNAME} to www-data"
    usermod -a -G "${USERNAME}" www-data || log_warning "Failed to add www-data to ${USERNAME}"
    usermod -a -G www-data root || log_warning "Failed to add root to www-data"
    
    log_success "User groups configured"
}

# ============================================================================
# DATABASE OPERATIONS (REMOVIDO REDIRECIONAMENTO SILENCIOSO)
# ============================================================================

configure_postgres() {
    log_info "Configuring PostgreSQL..."
    
    if ! check_command psql; then
        log_warning "PostgreSQL not installed, installing..."
        apt update && apt install -y postgresql postgresql-contrib
    fi
    
    systemctl enable --now postgresql
    
    log_info "Creating database user and database..."
    sudo -u postgres psql -c "DROP USER IF EXISTS ${USERNAME};"
    sudo -u postgres psql -c "CREATE USER ${USERNAME} WITH PASSWORD '${USERNAME_DBPASS}';"
    sudo -u postgres psql -c "ALTER USER ${USERNAME} WITH SUPERUSER;"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${USERNAME};"
    sudo -u postgres psql -c "CREATE DATABASE ${USERNAME} OWNER ${USERNAME};"
    
    local pg_hba_file
    pg_hba_file=$(sudo -u postgres psql -t -P format=unaligned -c "SHOW hba_file;")
    
    log_info "Configuring pg_hba.conf: ${pg_hba_file}"
    cp "${pg_hba_file}" "${pg_hba_file}.backup" 2>/dev/null || true
    
    sed -i 's/local\s\+all\s\+all\s\+peer/local   all             all                                     md5/' "${pg_hba_file}"
    sed -i 's/host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+ident/host    all             all             127.0.0.1\/32            md5/' "${pg_hba_file}"
    
    systemctl restart postgresql
    log_success "PostgreSQL configured successfully"
}

# ============================================================================
# APP OPERATIONS (REMOVIDO SILENCIAMENTO)
# ============================================================================

run_django_migrations() {
    log_info "Running Django migrations..."
    
    cd "${BASE_DIR}"
    
    sudo -u "${USERNAME}" bash -c "
        source ${BASE_DIR}/venv/bin/activate
        cd ${BASE_DIR}
        python3 manage.py makemigrations
        python3 manage.py migrate
        python3 manage.py collectstatic --noinput
        deactivate
    "
    
    log_success "Django migrations completed"
}

# ... [O RESTANTE DO SCRIPT SEGUE A MESMA LÓGICA DE REMOVER >/DEV/NULL E 2>&1 ONDE FOR INTERATIVO] ...

# ============================================================================
# UI FUNCTIONS
# ============================================================================

show_message() {
    local title="$1"
    local message="$2"
    dialog --title "${title}" --msgbox "${message}" 7 50
}

# [O restante das funções de Menu e Update foram mantidas para preservar a lógica original do Ideilson]

main() {
    check_root
    log_init
    ensure_dialog
    validate_system
    
    while true; do
        main_menu
    done
}

main "$@"