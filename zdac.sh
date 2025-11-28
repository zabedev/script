#!/bin/bash

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

readonly SCRIPT_VERSION="2.0.0"
readonly USERNAME="zabe"
readonly USERNAME_DBPASS="7bb073796c8a93"
readonly ADMIN_PASSWORD="WmRhYzNAWmFiZQ=="
readonly LANGUAGE_CODE="pt-BR"
readonly TIME_ZONE="UTC"
readonly SECRET_KEY="django-insecure-vpo7np+n_333j@2dy6$&8tibp*sll(x$*6_7a!3!uc^cibb*"
readonly SERVER_URL="https://raw.githubusercontent.com/zabedev/script/main"

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
# LOGGING SYSTEM
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
    
    echo "[${timestamp}] [${level}] ${message}" | sudo tee -a "${LOG_FILE}" >/dev/null
}

log_info() {
    log_message "INFO" "$@"
    echo "ℹ️  $*"
}

log_success() {
    log_message "SUCCESS" "$@"
    echo "✅ $*"
}

log_warning() {
    log_message "WARNING" "$@"
    echo "⚠️  $*" >&2
}

log_error() {
    log_message "ERROR" "$@"
    echo "❌ $*" >&2
}

log_command() {
    local cmd="$*"
    log_info "Executing: ${cmd}"
    
    if eval "$cmd" 2>&1 | sudo tee -a "${LOG_FILE}" >/dev/null; then
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
        log_command "apt update && apt install dialog -y"
    fi
}

update_system() {
    log_info "Updating system..."
    
    if ! log_command "apt update"; then
        log_error "Failed to update package lists"
        return 1
    fi
    
    if ! log_command "apt upgrade -y"; then
        log_error "Failed to upgrade packages"
        return 1
    fi
    
    log_success "System updated successfully"
    read -p "Press Enter to continue..."
}

install_auxiliary_packages() {
    log_info "Installing auxiliary packages..."
    
    if ! log_command "apt install ${REQUIRED_PACKAGES} -y"; then
        log_error "Failed to install required packages"
        return 1
    fi
    
    log_success "Auxiliary packages installed"
    read -p "Press Enter to continue..."
}

remove_auxiliary_packages() {
    log_info "Removing auxiliary packages..."
    
    log_command "apt remove supervisor nginx postgresql -y"
    log_command "apt purge supervisor* nginx* postgresql* -y"
    log_command "apt autoremove -y"
    log_command "apt clean"
    
    log_success "Auxiliary packages removed"
    read -p "Press Enter to continue..."
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
    
    usermod -a -G www-data "${USERNAME}" 2>/dev/null || log_warning "Failed to add ${USERNAME} to www-data"
    usermod -a -G "${USERNAME}" www-data 2>/dev/null || log_warning "Failed to add www-data to ${USERNAME}"
    usermod -a -G www-data root 2>/dev/null || log_warning "Failed to add root to www-data"
    
    log_success "User groups configured"
}

remove_user_groups() {
    log_info "Removing user from groups..."
    
    if getent group www-data | grep -q "${USERNAME}"; then
        deluser "${USERNAME}" www-data 2>/dev/null || log_warning "Failed to remove ${USERNAME} from www-data"
    fi
    
    log_success "User groups cleaned"
}

# ============================================================================
# DIRECTORY MANAGEMENT
# ============================================================================

create_directory() {
    local dir_path="$1"
    local owner="${2:-}"
    local group="${3:-}"
    
    if [[ -d "${dir_path}" ]]; then
        log_warning "Directory already exists: ${dir_path}"
        return 0
    fi
    
    if ! mkdir -p "${dir_path}"; then
        log_error "Failed to create directory: ${dir_path}"
        return 1
    fi
    
    if [[ -n "${owner}" ]] && [[ -n "${group}" ]]; then
        chown -R "${owner}:${group}" "${dir_path}"
    fi
    
    log_success "Created directory: ${dir_path}"
}

create_all_directories() {
    log_info "Creating application directories..."
    
    for dir in "${ZDAC_DIRS[@]}"; do
        create_directory "${dir}"
    done
    
    log_success "All directories created"
}

# ============================================================================
# FILE OPERATIONS
# ============================================================================

download_file() {
    local destination="$1"
    local url="$2"
    
    log_info "Downloading: ${url}"
    
    if ! wget -q --show-progress -O "${destination}" "${url}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to download: ${url}"
        return 1
    fi
    
    log_success "Downloaded: $(basename "${destination}")"
}

extract_archive() {
    local archive_path="$1"
    local destination="$2"
    
    log_info "Extracting: ${archive_path} to ${destination}"
    
    if ! unzip -oq "${archive_path}" -d "${destination}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_error "Failed to extract: ${archive_path}"
        return 1
    fi
    
    log_success "Extracted: $(basename "${archive_path}")"
}

download_and_extract_files() {
    log_info "Downloading application files..."
    
    local temp_dac="/tmp/dac.zip"
    local temp_web="/tmp/web.zip"
    
    download_file "${temp_dac}" "${SERVER_URL}/dac.zip" || return 1
    download_file "${temp_web}" "${SERVER_URL}/web.zip" || return 1
    
    extract_archive "${temp_dac}" "${BASE_DIR}" || return 1
    extract_archive "${temp_web}" "${WEB_DIR}" || return 1
    
    rm -f "${temp_dac}" "${temp_web}"
    log_success "Application files downloaded and extracted"
}

change_ownership() {
    local owner="$1"
    local group="$2"
    local path="$3"
    
    log_info "Changing ownership: ${path} to ${owner}:${group}"
    
    if ! chown -R "${owner}:${group}" "${path}"; then
        log_error "Failed to change ownership: ${path}"
        return 1
    fi
    
    log_success "Ownership changed: ${path}"
}

# ============================================================================
# DATABASE OPERATIONS
# ============================================================================

configure_postgres() {
    log_info "Configuring PostgreSQL..."
    
    if ! check_command psql; then
        log_warning "PostgreSQL not installed, installing..."
        log_command "apt update && apt install -y postgresql postgresql-contrib"
    fi
    
    log_command "systemctl enable --now postgresql"
    
    log_info "Creating database user and database..."
    sudo -u postgres psql -c "DROP USER IF EXISTS ${USERNAME};" 2>&1 | tee -a "${LOG_FILE}"
    sudo -u postgres psql -c "CREATE USER ${USERNAME} WITH PASSWORD '${USERNAME_DBPASS}';" 2>&1 | tee -a "${LOG_FILE}"
    sudo -u postgres psql -c "ALTER USER ${USERNAME} WITH SUPERUSER;" 2>&1 | tee -a "${LOG_FILE}"
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${USERNAME};" 2>&1 | tee -a "${LOG_FILE}"
    sudo -u postgres psql -c "CREATE DATABASE ${USERNAME} OWNER ${USERNAME};" 2>&1 | tee -a "${LOG_FILE}"
    
    local pg_hba_file
    pg_hba_file=$(sudo -u postgres psql -t -P format=unaligned -c "SHOW hba_file;")
    
    log_info "Configuring pg_hba.conf: ${pg_hba_file}"
    sed -i 's/peer/md5/g' "${pg_hba_file}"
    
    log_command "systemctl restart postgresql"
    log_success "PostgreSQL configured"
}

cleanup_postgres() {
    log_info "Cleaning up PostgreSQL..."
    
    if ! check_command psql; then
        log_warning "PostgreSQL not installed, skipping cleanup"
        return 0
    fi
    
    if systemctl is-active --quiet postgresql; then
        sudo -u postgres psql -c "SELECT pg_terminate_backend(pg_stat_activity.pid) 
                                   FROM pg_stat_activity 
                                   WHERE datname = '${USERNAME}' AND pid <> pg_backend_pid();" 2>&1 | tee -a "${LOG_FILE}"
        
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${USERNAME} WITH (FORCE);" 2>&1 | tee -a "${LOG_FILE}"
        sudo -u postgres psql -c "DROP USER IF EXISTS ${USERNAME};" 2>&1 | tee -a "${LOG_FILE}"
    fi
    
    log_success "PostgreSQL cleaned"
}

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

create_systemd_service() {
    local service_name="$1"
    local command="$2"
    local directory="$3"
    local user="${4:-}"
    local group="${5:-}"
    
    log_info "Creating systemd service: ${service_name}"
    
    cat > "${SYSTEMD_SERVICE_DIR}/${service_name}.service" <<EOF
[Unit]
Description=${service_name} Service
After=network.target

[Service]
WorkingDirectory=${directory}
ExecStart=${command}
Restart=always
RestartSec=5
$([ -n "$user" ] && echo "User=${user}")
$([ -n "$group" ] && echo "Group=${group}")

[Install]
WantedBy=multi-user.target
EOF
    
    log_success "Systemd service created: ${service_name}"
}

create_supervisor_config() {
    local service_name="$1"
    local command="$2"
    local directory="$3"
    local environment="${4:-}"
    local user="${5:-}"
    local group="${6:-}"
    
    log_info "Creating supervisor config: ${service_name}"
    
    cat > "${SUPERVISOR_CONF_DIR}/${service_name}.conf" <<EOF
[program:${service_name}]
directory=${directory}
command=${command}
$([ -n "$environment" ] && echo "environment=${environment}")
autostart=true
autorestart=true
stderr_logfile=${LOG_DIR}/supervisor/${service_name}_err.log
stdout_logfile=${LOG_DIR}/supervisor/${service_name}_out.log
$([ -n "$user" ] && echo "user=${user}")
$([ -n "$group" ] && echo "group=${group}")
EOF
    
    log_success "Supervisor config created: ${service_name}"
}

reload_services() {
    log_info "Reloading service managers..."
    log_command "supervisorctl reread"
    log_command "supervisorctl update"
    log_command "systemctl daemon-reload"
    log_success "Service managers reloaded"
}

start_services() {
    log_info "Starting services..."
    
    for service in "${SUPERVISOR_SERVICES[@]}"; do
        log_command "supervisorctl start ${service}"
    done
    
    for service in "${SYSTEMD_SERVICES[@]}"; do
        log_command "systemctl start ${service}"
        log_command "systemctl enable ${service}"
    done
    
    log_success "All services started"
}

stop_and_remove_systemd_service() {
    local service_name="$1"
    local service_file="${SYSTEMD_SERVICE_DIR}/${service_name}.service"
    
    log_info "Removing systemd service: ${service_name}"
    
    systemctl stop "${service_name}.service" 2>/dev/null || true
    systemctl disable "${service_name}.service" 2>/dev/null || true
    
    if [[ -f "${service_file}" ]]; then
        rm -f "${service_file}"
    fi
    
    log_success "Systemd service removed: ${service_name}"
}

stop_and_remove_supervisor_program() {
    local service_name="$1"
    local config_file="${SUPERVISOR_CONF_DIR}/${service_name}.conf"
    
    log_info "Removing supervisor program: ${service_name}"
    
    supervisorctl stop "${service_name}" 2>/dev/null || true
    
    if [[ -f "${config_file}" ]]; then
        rm -f "${config_file}"
    fi
    
    log_success "Supervisor program removed: ${service_name}"
}

remove_all_services() {
    log_info "Removing all services..."
    
    for service in "${SUPERVISOR_SERVICES[@]}"; do
        stop_and_remove_supervisor_program "${service}"
    done
    
    for service in "${SYSTEMD_SERVICES[@]}"; do
        stop_and_remove_systemd_service "${service}"
    done
    
    reload_services
    log_success "All services removed"
}

create_all_services() {
    log_info "Creating all services..."
    
    create_systemd_service "dac-api" \
        "${BASE_DIR}/venv/bin/gunicorn --bind unix:${BASE_DIR}/gunicorn.sock backend.wsgi:application" \
        "${BASE_DIR}" "zabe" "www-data"
    
    create_supervisor_config "dac-boot" \
        "${BASE_DIR}/venv/bin/python ${BASE_DIR}/boot.py" \
        "${BASE_DIR}" \
        "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"
    
    create_supervisor_config "dac-sender" \
        "${BASE_DIR}/venv/bin/python ${BASE_DIR}/sender.py" \
        "${BASE_DIR}" \
        "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"
    
    create_supervisor_config "dac-reader" \
        "${BASE_DIR}/venv/bin/python ${BASE_DIR}/reader.py" \
        "${BASE_DIR}" \
        "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"
    
    reload_services
    log_success "All services created"
}

# ============================================================================
# NGINX CONFIGURATION
# ============================================================================

configure_nginx() {
    log_info "Configuring Nginx..."
    
    cat > /etc/nginx/sites-available/zdac <<'EOF'
server {
    listen 80;
    server_name _;

    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api {
        proxy_pass http://unix:/opt/dac/gunicorn.sock;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/static/ {
        alias /opt/dac/statics/;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
    }

    location /assets/ {
        root /var/www/html;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    access_log /opt/dac/logs/nginx_access.log;
    error_log /opt/dac/logs/nginx_error.log;
}
EOF
    
    ln -sf /etc/nginx/sites-available/zdac /etc/nginx/sites-enabled/zdac
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
    
    if nginx -t 2>&1 | tee -a "${LOG_FILE}"; then
        log_command "systemctl restart nginx"
        log_success "Nginx configured successfully"
    else
        log_error "Nginx configuration test failed"
        return 1
    fi
}

cleanup_nginx() {
    log_info "Cleaning up Nginx configuration..."
    
    if systemctl is-active --quiet nginx; then
        log_command "systemctl stop nginx"
    fi
    
    rm -f /etc/nginx/sites-available/zdac
    rm -f /etc/nginx/sites-enabled/zdac
    
    log_success "Nginx cleaned up"
}

# ============================================================================
# PYTHON ENVIRONMENT
# ============================================================================

setup_python_environment() {
    log_info "Setting up Python virtual environment..."
    
    if [[ -d "${BASE_DIR}/venv" ]]; then
        log_warning "Virtual environment already exists, removing..."
        rm -rf "${BASE_DIR}/venv"
    fi
    
    log_command "python3 -m venv ${BASE_DIR}/venv"
    
    source "${BASE_DIR}/venv/bin/activate"
    
    log_command "pip install --upgrade pip"
    log_command "pip install -r ${BASE_DIR}/requirements.txt"
    
    deactivate
    
    log_success "Python environment configured"
}

create_env_file() {
    log_info "Creating .env file..."
    
    cat > "${BASE_DIR}/.env" <<EOF
DEBUG=False
SECRET_KEY=${SECRET_KEY}
ALLOWED_HOSTS=127.0.0.1,zabe.local,localhost
ADMIN_PASSWORD=${ADMIN_PASSWORD}
DB_DATABASE=${USERNAME}
DB_USERNAME=${USERNAME}
DB_PASSWORD=${USERNAME_DBPASS}
DB_HOST=localhost
DB_PORT=5432
LANGUAGE_CODE=${LANGUAGE_CODE}
TIME_ZONE=${TIME_ZONE}
EOF
    
    chown "${USERNAME}:${USERNAME}" "${BASE_DIR}/.env"
    chmod 600 "${BASE_DIR}/.env"
    
    log_success "Environment file created"
}

run_django_migrations() {
    log_info "Running Django migrations..."
    
    source "${BASE_DIR}/venv/bin/activate"
    
    cd "${BASE_DIR}"
    
    python3 manage.py makemigrations 2>&1 | tee -a "${LOG_FILE}"
    python3 manage.py migrate 2>&1 | tee -a "${LOG_FILE}"
    python3 manage.py collectstatic --noinput 2>&1 | tee -a "${LOG_FILE}"
    
    deactivate
    
    log_success "Django migrations completed"
}

# ============================================================================
# MAIN OPERATIONS
# ============================================================================

install_zdac() {
    log_info "Starting Zabe Gateway installation..."
    
    timedatectl set-timezone UTC
    remove_sudo_nopasswd
    configure_sudo_nopasswd
    install_auxiliary_packages
    configure_postgres
    create_all_directories
    download_and_extract_files
    
    change_ownership "www-data" "www-data" "${WEB_DIR}"
    configure_user_groups
    
    setup_python_environment
    change_ownership "${USERNAME}" "${USERNAME}" "${BASE_DIR}"
    create_env_file
    run_django_migrations
    
    create_all_services
    start_services
    
    chown "${USERNAME}:www-data" "${BASE_DIR}/gunicorn.sock" 2>/dev/null || true
    chmod 770 "${BASE_DIR}/gunicorn.sock" 2>/dev/null || true
    
    configure_nginx
    
    log_success "Zabe Gateway installed successfully!"
    log_info "Log file: ${LOG_FILE}"
    
    read -p "Press Enter to continue..."
}

uninstall_zdac() {
    log_info "Starting Zabe Gateway uninstallation..."
    
    cleanup_nginx
    remove_all_services
    
    if [[ -d "${WEB_DIR}" ]]; then
        rm -rf "${WEB_DIR:?}"/*
        log_success "Web directory cleaned"
    fi
    
    if [[ -d "${BASE_DIR}" ]]; then
        rm -rf "${BASE_DIR:?}"
        log_success "Base directory removed"
    fi
    
    cleanup_postgres
    remove_user_groups
    remove_auxiliary_packages
    remove_sudo_nopasswd
    
    log_success "Zabe Gateway uninstalled successfully!"
    log_info "Log file preserved: ${LOG_FILE}"
    
    read -p "Press Enter to continue..."
}

run_reboot() {
    log_warning "System reboot requested"
    read -p "Press Enter to confirm reboot or Ctrl+C to cancel..."
    log_info "Rebooting system..."
    reboot
}

# ============================================================================
# UI FUNCTIONS
# ============================================================================

show_message() {
    local title="$1"
    local message="$2"
    dialog --title "${title}" --msgbox "${message}" 7 50
}

main_menu() {
    local cmd=(dialog --clear --backtitle "Zabe Gateway Manager v${SCRIPT_VERSION}" 
               --title "Main Menu" 
               --menu "Select an option:" 15 60 6)

    local options=(
        1 "Update operating system"
        2 "Install Zabe Gateway"
        3 "Reboot device"
        4 "Uninstall Zabe Gateway"
        5 "View logs"
        6 "Exit"
    )

    local choice
    choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    clear

    case $choice in
        1) update_system ;;
        2) install_zdac ;;
        3) run_reboot ;;
        4) uninstall_zdac ;;
        5) 
            if [[ -f "${LOG_FILE}" ]]; then
                less "${LOG_FILE}"
            else
                show_message "Error" "Log file not found"
            fi
            ;;
        6) 
            log_info "Exiting Zabe Gateway Manager"
            exit 0 
            ;;
        *) 
            show_message "Error" "Invalid option. Please try again."
            ;;
    esac
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

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