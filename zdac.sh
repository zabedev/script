#!/bin/bash

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly LANGUAGE_CODE="pt-BR"
readonly TIME_ZONE="UTC"
readonly USERNAME="zabe"

readonly BASE_DIR="/opt/zdac"
readonly BACKEND_DIR="${BASE_DIR}/backend"
readonly FRONTEND_DIR="${BASE_DIR}/frontend"
readonly WEB_DIR="/var/www/html/zdac"
readonly NGINX_SITE="zdac"

readonly GIT_BACKEND_REPO=""
readonly GIT_BACKEND_BRANCH="main"
readonly GIT_FRONTEND_REPO=""
readonly GIT_FRONTEND_BRANCH="main"

readonly BACKEND_PORT="3333"
readonly FRONTEND_PORT="3000"

readonly SYSTEMD_SERVICE_DIR="/etc/systemd/system"
readonly SYSTEMD_SERVICES=("zdac-api")

readonly ZDAC_DIRS=(
    "${BASE_DIR}"
    "${BASE_DIR}/logs"
    "${BACKEND_DIR}"
    "${FRONTEND_DIR}"
    "${WEB_DIR}"
)

LOG_FILE="/var/log/zdac-installer.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/zdac-installer.log"
fi
readonly LOG_FILE

readonly DIALOG_HEIGHT=20
readonly DIALOG_WIDTH=70

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log "ERROR" "This operation requires root privileges"
        dialog --title "Erro" --msgbox "Esta operação requer privilégios de root.\nExecute: sudo $0" 8 50
        exit 1
    fi
}

check_user_exists() {
    if ! id "$USERNAME" &>/dev/null; then
        log "ERROR" "User $USERNAME does not exist"
        dialog --title "Erro" --msgbox "Usuário $USERNAME não existe no sistema" 7 50
        exit 1
    fi
}

ensure_dialog() {
    if ! command -v dialog &>/dev/null; then
        log "INFO" "Installing dialog package"
        apt update && apt install -y dialog || {
            log "ERROR" "Failed to install dialog"
            exit 1
        }
    fi
}

handle_error() {
    local exit_code=$?
    local line_number=$1
    log "ERROR" "Command failed with exit code $exit_code at line $line_number"
    dialog --title "Erro" --msgbox "Erro na linha $line_number\nCódigo: $exit_code\nVerifique $LOG_FILE" 9 50
    exit "$exit_code"
}

trap 'handle_error $LINENO' ERR

change_nopasswd() {
    check_root
    check_user_exists
    
    if grep -q "^$USERNAME ALL=(ALL) NOPASSWD: ALL" /etc/sudoers /etc/sudoers.d/* 2>/dev/null; then
        log "WARN" "NOPASSWD already configured for $USERNAME"
        return 0
    fi
    
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/zdac-installer
    chmod 440 /etc/sudoers.d/zdac-installer
    
    log "INFO" "NOPASSWD permission added for $USERNAME"
}

remove_nopasswd() {
    check_root
    
    if [[ -f /etc/sudoers.d/zdac-installer ]]; then
        rm -f /etc/sudoers.d/zdac-installer
        log "INFO" "NOPASSWD permission removed"
    fi
}

prompt_git_repos() {
    local backend_repo frontend_repo
    
    backend_repo=$(dialog --title "Repositório Backend" \
        --inputbox "URL do repositório Git do backend (AdonisJS):" 10 70 \
        "${GIT_BACKEND_REPO}" 2>&1 >/dev/tty)
    
    frontend_repo=$(dialog --title "Repositório Frontend" \
        --inputbox "URL do repositório Git do frontend (Vue.js):" 10 70 \
        "${GIT_FRONTEND_REPO}" 2>&1 >/dev/tty)
    
    if [[ -z "$backend_repo" ]] || [[ -z "$frontend_repo" ]]; then
        dialog --title "Erro" --msgbox "Ambos os repositórios são obrigatórios!" 7 50
        return 1
    fi
    
    echo "$backend_repo|$frontend_repo"
}

update_system() {
    log "INFO" "Starting system update"
    check_root
    
    dialog --title "Atualizando Sistema" --infobox "Atualizando lista de pacotes..." 5 50
    apt update || return 1
    
    dialog --title "Atualizando Sistema" --infobox "Atualizando pacotes instalados..." 5 50
    DEBIAN_FRONTEND=noninteractive apt upgrade -y || return 1
    
    dialog --title "Atualizando Sistema" --infobox "Removendo pacotes desnecessários..." 5 50
    apt autoremove -y && apt autoclean -y
    
    log "INFO" "System update completed"
    dialog --title "Sucesso" --msgbox "Sistema atualizado com sucesso!" 7 50
}

install_packages() {
    log "INFO" "Starting package installation"
    check_root
    
    local packages=(
        wget git zip unzip curl
        nginx redis-server
        build-essential
        postgresql postgresql-contrib
        certbot python3-certbot-nginx
    )
    
    dialog --title "Instalando Pacotes" --infobox "Instalando pacotes do sistema..." 6 60
    
    apt update
    DEBIAN_FRONTEND=noninteractive apt install -y "${packages[@]}" || return 1
    
    dialog --title "Instalando NVM" --infobox "Instalando Node Version Manager..." 5 50
    
    if [[ ! -d "/home/${USERNAME}/.nvm" ]]; then
        su - "$USERNAME" -c '
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh | bash
            export NVM_DIR="$HOME/.nvm"
            [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
            nvm install --lts
            nvm alias default node
        ' || return 1
    fi
    
    systemctl enable --now redis-server
    systemctl enable --now postgresql
    
    log "INFO" "Package installation completed"
    dialog --title "Sucesso" --msgbox "Pacotes instalados com sucesso!" 7 50
}

configure_postgres() {
    check_root
    log "INFO" "Configuring PostgreSQL"
    
    local db_name db_user db_pass
    
    db_name=$(dialog --title "PostgreSQL Config" \
        --inputbox "Nome do banco de dados:" 8 50 "zdac" 2>&1 >/dev/tty)
    
    db_user=$(dialog --title "PostgreSQL Config" \
        --inputbox "Nome do usuário:" 8 50 "$USERNAME" 2>&1 >/dev/tty)
    
    db_pass=$(dialog --title "PostgreSQL Config" \
        --insecure --passwordbox "Senha do banco:" 8 50 2>&1 >/dev/tty)
    
    if [[ -z "$db_pass" ]]; then
        dialog --title "Erro" --msgbox "Senha é obrigatória!" 7 40
        return 1
    fi
    
    dialog --title "PostgreSQL" --infobox "Criando usuário e banco de dados..." 5 50
    
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${db_name};" 2>/dev/null || true
    sudo -u postgres psql -c "DROP USER IF EXISTS ${db_user};" 2>/dev/null || true
    
    sudo -u postgres psql -c "CREATE USER ${db_user} WITH PASSWORD '${db_pass}';"
    sudo -u postgres psql -c "CREATE DATABASE ${db_name} OWNER ${db_user};"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};"
    
    echo "${db_name}|${db_user}|${db_pass}"
    
    log "INFO" "PostgreSQL configured successfully"
}

create_zdac_dirs() {
    log "INFO" "Creating ZDAC directories"
    
    for dir in "${ZDAC_DIRS[@]}"; do
        mkdir -p "$dir"
        chown -R "${USERNAME}:${USERNAME}" "$dir"
    done
    
    log "INFO" "Directories created"
}

clone_repositories() {
    local repos="$1"
    local backend_repo frontend_repo
    
    IFS='|' read -r backend_repo frontend_repo <<< "$repos"
    
    log "INFO" "Cloning repositories"
    
    dialog --title "Git Clone" --infobox "Clonando backend repository..." 5 60
    
    if [[ -d "${BACKEND_DIR}/.git" ]]; then
        su - "$USERNAME" -c "cd ${BACKEND_DIR} && git pull origin ${GIT_BACKEND_BRANCH}"
    else
        rm -rf "${BACKEND_DIR:?}"/*
        su - "$USERNAME" -c "git clone -b ${GIT_BACKEND_BRANCH} ${backend_repo} ${BACKEND_DIR}"
    fi
    
    dialog --title "Git Clone" --infobox "Clonando frontend repository..." 5 60
    
    if [[ -d "${FRONTEND_DIR}/.git" ]]; then
        su - "$USERNAME" -c "cd ${FRONTEND_DIR} && git pull origin ${GIT_FRONTEND_BRANCH}"
    else
        rm -rf "${FRONTEND_DIR:?}"/*
        su - "$USERNAME" -c "git clone -b ${GIT_FRONTEND_BRANCH} ${frontend_repo} ${FRONTEND_DIR}"
    fi
    
    chown -R "${USERNAME}:${USERNAME}" "${BASE_DIR}"
    
    log "INFO" "Repositories cloned successfully"
}

configure_backend_env() {
    local db_config="$1"
    local db_name db_user db_pass
    
    IFS='|' read -r db_name db_user db_pass <<< "$db_config"
    
    log "INFO" "Configuring backend .env"
    
    local app_key
    app_key=$(dialog --title "Backend Config" \
        --inputbox "APP_KEY do AdonisJS (deixe vazio para gerar):" 8 60 2>&1 >/dev/tty)
    
    cat > "${BACKEND_DIR}/.env" <<EOF
PORT=${BACKEND_PORT}
HOST=0.0.0.0
NODE_ENV=production
APP_KEY=${app_key:-$(openssl rand -base64 32)}
DRIVE_DISK=local
SESSION_DRIVER=cookie

DB_CONNECTION=pg
PG_HOST=localhost
PG_PORT=5432
PG_USER=${db_user}
PG_PASSWORD=${db_pass}
PG_DB_NAME=${db_name}

REDIS_CONNECTION=local
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=

CACHE_VIEWS=true
EOF
    
    chown "${USERNAME}:${USERNAME}" "${BACKEND_DIR}/.env"
    chmod 600 "${BACKEND_DIR}/.env"
    
    log "INFO" "Backend .env configured"
}

configure_frontend_env() {
    log "INFO" "Configuring frontend .env"
    
    local api_url
    api_url=$(dialog --title "Frontend Config" \
        --inputbox "URL da API (backend):" 8 60 \
        "http://localhost:${BACKEND_PORT}" 2>&1 >/dev/tty)
    
    cat > "${FRONTEND_DIR}/.env" <<EOF
VITE_API_URL=${api_url}
VITE_APP_NAME=ZDAC Gateway
EOF
    
    chown "${USERNAME}:${USERNAME}" "${FRONTEND_DIR}/.env"
    
    log "INFO" "Frontend .env configured"
}

build_backend() {
    log "INFO" "Building backend"
    
    dialog --title "Backend Build" --infobox "Instalando dependências do backend..." 6 60
    
    su - "$USERNAME" -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        cd ${BACKEND_DIR}
        npm install --production
    " || return 1
    
    dialog --title "Backend Build" --infobox "Executando migrations..." 5 50
    
    su - "$USERNAME" -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        cd ${BACKEND_DIR}
        node ace migration:run --force
    " || true
    
    log "INFO" "Backend built successfully"
}

build_frontend() {
    log "INFO" "Building frontend"
    
    dialog --title "Frontend Build" --infobox "Instalando dependências do frontend..." 6 60
    
    su - "$USERNAME" -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        cd ${FRONTEND_DIR}
        npm install
    " || return 1
    
    dialog --title "Frontend Build" --infobox "Compilando aplicação Vue..." 6 50
    
    su - "$USERNAME" -c "
        export NVM_DIR=\"\$HOME/.nvm\"
        [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
        cd ${FRONTEND_DIR}
        npm run build
    " || return 1
    
    rm -rf "${WEB_DIR:?}"/*
    cp -r "${FRONTEND_DIR}/dist/"* "${WEB_DIR}/"
    chown -R www-data:www-data "${WEB_DIR}"
    
    log "INFO" "Frontend built and deployed"
}

create_systemd_service() {
    check_root
    log "INFO" "Creating systemd service for backend"
    
    local node_path
    node_path=$(su - "$USERNAME" -c '
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        which node
    ')
    
    cat > "${SYSTEMD_SERVICE_DIR}/zdac-api.service" <<EOF
[Unit]
Description=ZDAC API Service (AdonisJS)
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=${USERNAME}
Group=${USERNAME}
WorkingDirectory=${BACKEND_DIR}
Environment="NODE_ENV=production"
Environment="PATH=${node_path%/node}:\$PATH"
ExecStart=${node_path} ace serve --watch=false
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zdac-api
    systemctl restart zdac-api
    
    log "INFO" "Systemd service created and started"
}

configure_nginx() {
    check_root
    log "INFO" "Configuring Nginx"
    
    local server_name
    server_name=$(dialog --title "Nginx Config" \
        --inputbox "Nome do servidor (domínio ou IP):" 8 60 \
        "_" 2>&1 >/dev/tty)
    
    cat > "/etc/nginx/sites-available/${NGINX_SITE}" <<EOF
upstream zdac_backend {
    server 127.0.0.1:${BACKEND_PORT};
    keepalive 64;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${server_name};

    root ${WEB_DIR};
    index index.html;

    client_max_body_size 50M;

    # Frontend
    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # Backend API
    location /api {
        proxy_pass http://zdac_backend;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }

    # Assets caching
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript 
               application/x-javascript application/xml+rss 
               application/javascript application/json;

    access_log ${BASE_DIR}/logs/nginx_access.log;
    error_log ${BASE_DIR}/logs/nginx_error.log;
}
EOF
    
    ln -sf "/etc/nginx/sites-available/${NGINX_SITE}" "/etc/nginx/sites-enabled/"
    rm -f /etc/nginx/sites-enabled/default
    
    nginx -t && systemctl restart nginx
    
    log "INFO" "Nginx configured successfully"
    
    dialog --title "SSL Certificate" \
        --yesno "Deseja configurar SSL com Let's Encrypt?" 7 50
    
    if [[ $? -eq 0 ]] && [[ "$server_name" != "_" ]]; then
        certbot --nginx -d "$server_name" --non-interactive --agree-tos \
            --register-unsafely-without-email || true
    fi
}

install_zdac() {
    log "INFO" "Starting ZDAC installation"
    check_root
    check_user_exists
    
    local repos db_config
    
    repos=$(prompt_git_repos) || return 1
    
    dialog --title "Instalação ZDAC" --infobox "Configurando timezone..." 5 50
    timedatectl set-timezone "$TIME_ZONE"
    
    change_nopasswd
    
    db_config=$(configure_postgres) || return 1
    
    create_zdac_dirs
    clone_repositories "$repos"
    
    configure_backend_env "$db_config"
    configure_frontend_env
    
    build_backend
    build_frontend
    
    create_systemd_service
    configure_nginx
    
    remove_nopasswd
    
    log "INFO" "ZDAC installation completed"
    
    dialog --title "Instalação Concluída" --msgbox "\
ZDAC instalado com sucesso!

Backend: ${BACKEND_DIR}
Frontend: ${WEB_DIR}
Logs: ${BASE_DIR}/logs

Serviço: systemctl status zdac-api
Nginx: systemctl status nginx" 14 60
}

uninstall_zdac() {
    check_root
    
    dialog --title "Remover ZDAC" \
        --yesno "ATENÇÃO: Isto removerá completamente o ZDAC.\n\nDeseja continuar?" 8 60
    
    if [[ $? -ne 0 ]]; then
        return 0
    fi
    
    log "INFO" "Starting ZDAC uninstallation"
    
    dialog --title "Removendo ZDAC" --infobox "Parando serviços..." 5 50
    
    for service in "${SYSTEMD_SERVICES[@]}"; do
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        rm -f "${SYSTEMD_SERVICE_DIR}/${service}.service"
    done
    
    systemctl daemon-reload
    
    systemctl stop nginx 2>/dev/null || true
    rm -f "/etc/nginx/sites-enabled/${NGINX_SITE}"
    rm -f "/etc/nginx/sites-available/${NGINX_SITE}"
    systemctl start nginx 2>/dev/null || true
    
    dialog --title "Removendo ZDAC" --infobox "Removendo arquivos..." 5 50
    rm -rf "${BASE_DIR}"
    rm -rf "${WEB_DIR}"
    
    dialog --title "PostgreSQL" \
        --yesno "Deseja remover o banco de dados PostgreSQL?" 7 50
    
    if [[ $? -eq 0 ]]; then
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS zdac;" 2>/dev/null || true
        sudo -u postgres psql -c "DROP USER IF EXISTS ${USERNAME};" 2>/dev/null || true
    fi
    
    remove_nopasswd
    
    log "INFO" "ZDAC uninstallation completed"
    dialog --title "Sucesso" --msgbox "ZDAC removido com sucesso!" 7 50
}

system_reboot() {
    dialog --title "Reiniciar Sistema" \
        --yesno "Deseja realmente reiniciar o sistema agora?" 7 50
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "System reboot initiated"
        shutdown -r now
    fi
}

show_logs() {
    dialog --title "Logs do Sistema" --tailbox "$LOG_FILE" 20 70
}

show_service_status() {
    local status_output
    
    status_output=$(systemctl status zdac-api 2>&1 || echo "Serviço não encontrado")
    
    dialog --title "Status do Serviço" --msgbox "$status_output" 20 70
}

show_about() {
    dialog --title "Sobre" --msgbox "\
ZDAC Gateway Installer
Versão: $SCRIPT_VERSION

Stack:
- Backend: AdonisJS (Node.js)
- Frontend: Vue.js
- Database: PostgreSQL
- Cache: Redis
- Reverse Proxy: Nginx

Diretórios:
- Base: ${BASE_DIR}
- Backend: ${BACKEND_DIR}
- Frontend: ${FRONTEND_DIR}
- Web: ${WEB_DIR}

Log: ${LOG_FILE}" 20 60
}

main_menu() {
    while true; do
        choice=$(dialog --clear \
            --backtitle "ZDAC GATEWAY v$SCRIPT_VERSION - Node.js Stack" \
            --title "Instalador do Aquisitor de Dados" \
            --menu "Escolha uma opção:" \
            $DIALOG_HEIGHT $DIALOG_WIDTH 11 \
            1 "Atualizar sistema operacional" \
            2 "Instalar pacotes necessários" \
            3 "Instalar ZDAC (Backend + Frontend)" \
            4 "Reinstalar/Atualizar ZDAC" \
            5 "Ver status do serviço" \
            6 "Ver logs do instalador" \
            7 "Reiniciar dispositivo" \
            8 "Remover ZDAC completamente" \
            9 "Sobre" \
            0 "Sair" \
            2>&1 >/dev/tty)
        
        case $choice in
            1) update_system ;;
            2) install_packages ;;
            3) install_zdac ;;
            4) install_zdac ;;
            5) show_service_status ;;
            6) show_logs ;;
            7) system_reboot ;;
            8) uninstall_zdac ;;
            9) show_about ;;
            0) 
                clear
                log "INFO" "Installer exited by user"
                exit 0
                ;;
            *)
                dialog --title "Erro" --msgbox "Opção inválida!" 7 40
                ;;
        esac
    done
}

main() {
    log "INFO" "ZDAC Installer started (version $SCRIPT_VERSION)"
    
    ensure_dialog
    check_user_exists
    
    main_menu
}

main "$@"