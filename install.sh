#!/bin/bash

USERNAME="zabe"
USERNAME_DBPASS="7bb073796c8a93"
ADMIN_PASSWORD="zabe"
LANGUAGE_CODE="pt-BR"
TIME_ZONE="UTC"
SECRET_KEY="django-insecure-vpo7np+n_333j@2dy6$&8tibp*sll(x$*6_7a!3!uc^cibb*"
SERVER_URL="https://raw.githubusercontent.com/zabedev/script/main/"
SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"
SYSTEMD_SERVICE_DIR="/etc/systemd/system"
BASE_DIR="/opt/dac"
WEB_DIR="/var/www/html"

SUPERVISOR_SERVICES=(
    "dac-boot"
    "dac-sender"
    "dac-reader"
)
SYSTEMD_SERVICES=(
    "dac-api"
)

ZDAC_DIRS=(
    "${BASE_DIR}"
    "${BASE_DIR}/logs"
    "${BASE_DIR}/logs/supervisor"
    #"${BASE_DIR}-update"
    "${WEB_DIR}"
)

if ! command -v dialog ; then
    echo "Installing dialog for user friendly interface..."
    sudo apt update && sudo apt install dialog -y
fi


change_nopasswd() {
    if [ "$EUID" -ne 0 ]; then
        echo "Please, run command using user privilege sudoers"
        exit 1
    fi
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | EDITOR='tee -a' visudo
}

remove_nopasswd() {
    if [ "$EUID" -ne 0 ]; then
        echo "Por favor, execute como root"
        exit 1
    fi

    sudo sed -i "/^$USERNAME ALL=(ALL) NOPASSWD: ALL/d" /etc/sudoers

    if [ $? -eq 0 ]; then
        echo "A permissão NOPASSWD foi removida com sucesso."
    else
        echo "Erro ao remover a permissão NOPASSWD."
    fi
}

create_systemd_service() {
    local service_name=$1
    local command=$2
    local directory=$3
    local user=$4
    local group=$5
    sudo bash -c "cat > /etc/systemd/system/${service_name}.service << EOF
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
EOF"
}

# Funções vazias para implementar depois
update_system() {
    echo "Atualizando sistema..."
    sudo apt update && sudo apt upgrade -y
    read -p "Pressione Enter para continuar..."
}

install_auxiliary_packages() {
    echo "Instalando pacotes auxiliares..."
    sudo apt install wget zip unzip supervisor python3-dev python3-venv python3-pip nginx postgresql build-essential -y
    read -p "Pressione Enter para continuar..."
}

configure_postgres() {
    local username="${USERNAME}"
    local password="${USERNAME_DBPASS}"

    if [[ -z "$password" ]]; then
        dialog --title "Database Password Required" --inputbox \
            "Enter the password for PostgreSQL user '${username}':" 8 60 2>/tmp/dbpass
        password=$(cat /tmp/dbpass)
        rm -f /tmp/dbpass
    fi

    if ! command -v psql ; then
        dialog --title "PostgreSQL not found" --yesno \
            "PostgreSQL is not installed. Do you want to install it now?" 7 60
        if [ $? -eq 0 ]; then
            sudo apt update && sudo apt install -y postgresql postgresql-contrib
        else
            exit 1
        fi
    fi

    sudo systemctl enable --now postgresql
    sudo -u postgres psql -c "CREATE USER ${username} WITH PASSWORD '${password}';" 
    sudo -u postgres psql -c "ALTER USER ${username} WITH SUPERUSER;" 
    sudo -u postgres psql -c "CREATE DATABASE ${username} OWNER ${username};" 
}

create_supervisor_config() {
    local service_name=$1
    local command=$2
    local directory=$3
    local enviroment=$4
    local user=$5
    local group=$6

    sudo bash -c "cat > $SUPERVISOR_CONF_DIR/${service_name}.conf << EOF
[program:${service_name}]
directory=${directory}
command=${command}
environment=${environment}
autostart=true
autorestart=true
stderr_logfile=${BASE_DIR}/logs/supervisor/${service_name}_err.log
stdout_logfile=${BASE_DIR}/logs/supervisor/${service_name}_out.log
$([ -n "$user" ] && echo "user=${user}")
$([ -n "$group" ] && echo "group=${group}")
EOF"
}

create_dir() {
    local dir_name=$1
    sudo mkdir -p "${dir_name}" 
}

download_file() {
    local folder_file=$1
    local url_file=$2
    if ! wget -O "${folder_file}" "${url_file}" ; then
        exit 1
    fi
}

download_all_file() {
    download_file "/tmp/dac.zip" "${SERVER_URL}/dac.zip"
    download_file "/tmp/web.zip" "${SERVER_URL}/web.zip"
}

unzip_file() {
    local folder_zip=$1
    local folder_zip_extract=$2
    sudo unzip -o ${folder_zip} -d ${folder_zip_extract}
}

unzip_all_files() {
    unzip_file "/tmp/dac.zip" "${BASE_DIR}"
    unzip_file "/tmp/web.zip" "${WEB_DIR}"
}

supervisor_reload() {
    sudo supervisorctl reread
    sudo supervisorctl update
}

change_owner() {
    local owner=$1
    local owner_group=$2
    local objetc_=$3
    sudo chown -R ${owner}:${owner_group} ${objetc_} 
}

systemd_reload() {
    sudo systemctl daemon-reload
}

systemd_service() {
    local service_name=$1
    local command=$2
    sudo systemctl "${command}" "${service_name}"
}

supervisor_service() {
    local service_name=$1
    local command=$2
    sudo supervisorctl ${command} ${service_name}
}

stop_and_remover_systemd_service() {
    local service_name=$1
    local service_path="${SYSTEMD_SERVICE_DIR}/${service_name}.service"

    # Verificar se o serviço está ativo e pará-lo
    if systemctl is-active --quiet "${service_name}.service"; then
        sudo systemctl stop "${service_name}.service"
    fi

    # Desabilitar o serviço para que não seja iniciado automaticamente na reinicialização
    if systemctl is-enabled --quiet "${service_name}.service"; then
        sudo systemctl disable "${service_name}.service"
    fi

    # Remover o arquivo de configuração do serviço
    if [ -f "${service_path}" ]; then
        sudo rm -f "${service_path}"
    fi
}

stop_and_remove_supervisor_program() {
    local service_name=$1
    local config_path="${SUPERVISOR_CONF_DIR}/${service_name}.conf"

    if sudo supervisorctl status | grep -q "${service_name}"; then
        sudo supervisorctl stop "${service_name}"
    fi

    if [ -f "${config_path}" ]; then
        sudo rm -f "${config_path}"
    fi
}

remove_all_services() {
    for service in "${SUPERVISOR_SERVICES[@]}"; do
        stop_and_remove_supervisor_program "$service"
    done

    for service in "${SYSTEMD_SERVICES[@]}"; do
        stop_and_remover_systemd_service "$service"
    done

    supervisor_reload
    systemd_reload
}

create_services() {
    create_systemd_service "dac-api" "${BASE_DIR}/venv/bin/gunicorn --bind unix:${BASE_DIR}/gunicorn.sock backend.wsgi:application" "${BASE_DIR}" "zabe" "www-data"
    create_supervisor_config "dac-boot" "${BASE_DIR}/venv/bin/python ${BASE_DIR}/boot.py" "${BASE_DIR}" "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"
    create_supervisor_config "dac-sender" "${BASE_DIR}/venv/bin/python ${BASE_DIR}/sender.py" "${BASE_DIR}" "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"
    create_supervisor_config "dac-reader" "${BASE_DIR}/venv/bin/python ${BASE_DIR}/reader.py" "${BASE_DIR}" "PATH='${BASE_DIR}/venv/bin',VIRTUAL_ENV='${BASE_DIR}/venv'"

    supervisor_reload
    systemd_reload
}

configure_services() {
    create_services

    for service in "${SUPERVISOR_SERVICES[@]}"; do
        supervisor_service "${service}" "start"
    done

    for service in "${SYSTEMD_SERVICES[@]}"; do
        systemd_service "${service}" "start"
        systemd_service "${service}" "enable"
    done
}

create_zdac_dirs() {
    #    create_dir "/opt/zdac"
    #    create_dir "/opt/zdac/logs"
    #    create_dir "/opt/zdac/logs/supervisor"
    #    create_dir "/opt/zdac-update"
    #    create_dir "/var/www/html"
    for dir in "${ZDAC_DIRS[@]}"; do
        create_dir "$dir"
    done
}

install_zdac() {
    echo "Instalando sistema ZDAC..."
    sudo rm -rf "$temp_dir"
    sudo timedatectl set-timezone UTC
    remove_nopasswd
    change_nopasswd
    install_auxiliary_packages
    configure_postgres
    create_zdac_dirs
    download_all_file
    unzip_all_files

    change_owner "www-data" "www-data" "${WEB_DIR}"
    sudo usermod -a -G www-data ${USERNAME}
    sudo usermod -a -G ${USERNAME} www-data
    sudo usermod -a -G www-data root

    python3 -m venv ${BASE_DIR}/venv
    change_owner "${USERNAME}" "${USERNAME}" "${BASE_DIR}"

    source ${BASE_DIR}/venv/bin/activate
    pip install --upgrade pip
    pip install -r ${BASE_DIR}/requirements.txt

    sudo bash -c "cat > ${BASE_DIR}/.env <<EOF
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
EOF"

    sudo chown -R ${USERNAME}:${USERNAME} ${BASE_DIR}/.env

    python3 ${BASE_DIR}/manage.py makemigrations
    python3 ${BASE_DIR}/manage.py migrate
    python3 ${BASE_DIR}/manage.py collectstatic --noinput

    configure_services

    sudo chown "${USERNAME}":www-data "${BASE_DIR}"/gunicorn.sock
    sudo chmod 770 "${BASE_DIR}"/gunicorn.sock

    
    sudo bash -c "printf '%s\n' 'server {
    listen 80;
    server_name _;

    root ${WEB_DIR};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    location /api {
        proxy_pass http://unix:${BASE_DIR}/gunicorn.sock;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/static/ {
        root ${BASE_DIR}/statics;
        expires 30d;
        add_header Cache-Control \"public, max-age=2592000\";
    }

    location /assets/ {
        root ${WEB_DIR};
        expires 30d;
        add_header Cache-Control \"public, max-age=2592000\";
    }

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

    access_log ${BASE_DIR}/logs/nginx_access.log;
    error_log ${BASE_DIR}/logs/nginx_error.log;
}' > /etc/nginx/sites-available/zdac"

    sudo ln -s /etc/nginx/sites-available/zdac /etc/nginx/sites-enabled/zdac
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo rm -f /etc/nginx/sites-available/default

    sudo nginx -t
    sudo systemctl restart nginx

    sudo rm /tmp/dac.zip
    sudo rm /tmp/web.zip

    read -p "Pressione Enter para continuar..."
}

remove_auxiliary_packages() {
    echo "Removendo pacotes auxiliares..."
    # implementar remoção dos pacotes aqui
    sudo apt remove supervisor nginx postgresql -y
    sudo apt purge supervisor nginx postgresql supervisor* nginx* postgresql* -y
    sudo apt autoremove -y
    sudo apt clean
    read -p "Pressione Enter para continuar..."
}

run_reboot() {
    echo "Reiniciando dispositivo..."
    # implementar reboot
    read -p "Pressione Enter para confirmar reboot..."
    sudo reboot
}

uninstall_zdac() {
    echo "Removendo sistema ZDAC..."
 # Parar o Nginx, se estiver em execução
    if sudo systemctl is-active --quiet nginx; then
        sudo systemctl stop nginx 
    fi

    # Remover todos os serviços (Supervisor e Systemd)
    remove_all_services

    # Remover arquivos do diretório /var/www/html, se existir
    if [ -d "${WEB_DIR}" ]; then
        sudo rm -rf ${WEB_DIR}/* 
    fi

    # Remover arquivos do diretório ${BASE_DIR}, se existir
    if [ -d "${BASE_DIR}" ]; then
        sudo rm -rf ${BASE_DIR} 
    fi

    # Remover arquivo de configuração do site Nginx, se existir
    if [ -f "/etc/nginx/sites-available/zdac" ]; then
        sudo rm -f /etc/nginx/sites-available/zdac 
    fi

    # Remover link simbólico do site Nginx, se existir
    if [ -f "/etc/nginx/sites-enabled/zdac" ]; then
        sudo rm -f /etc/nginx/sites-enabled/zdac 
    fi

    # Verificar se o PostgreSQL está instalado e rodando
    if command -v psql ; then
        if sudo systemctl is-active --quiet postgresql; then
            sudo -u postgres psql -c "SELECT pg_terminate_backend(pg_stat_activity.pid) 
                                  FROM pg_stat_activity 
                                  WHERE datname = '${USERNAME}' AND pid <> pg_backend_pid();" 

            sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${USERNAME} WITH (FORCE);" 
            sudo -u postgres psql -c "DROP USER IF EXISTS ${USERNAME};" 
        fi
    fi

    # Remover usuário zabe do grupo www-data, se existir
    if getent group www-data | grep -q ${USERNAME}; then
        sudo deluser ${USERNAME} www-data 
    fi
    remove_auxiliary_packages
    # Remover regra NOPASSWD, se existir
    remove_nopasswd
    read -p "Pressione Enter para continuar..."
}

show_message() {
    local title="$1"
    local message="$2"
    dialog --title "$title" --msgbox "$message" 7 50
}

main_menu() {
    cmd=(dialog --clear --backtitle "Zabe Gateway" --title "Manager"
        --menu "Escolha uma opção:" 15 50 6)

    options=(
        1 "Atualizar sistema operacional"
        2 "Instalar Zabe Gateway"
        3 "Reiniciar dispositivo"
        4 "Remover Zabe Gateway"
        5 "Sair"
    )

    choice=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty)
    clear

    case $choice in
    1) update_system ;;
    2) install_zdac ;;
    3) run_reboot;;
    4) uninstall_zdac;;
    5) exit 0 ;;
    *) show_message "Erro" "Opção inválida. Tente novamente." ;;
    esac
}

# Loop para mostrar o menu até o usuário sair
while true; do
    main_menu
done
