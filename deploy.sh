#!/usr/bin/env bash
# =============================================================================
# WordPress на одной ВМ: Nginx + MariaDB + PHP-FPM + WP-CLI.
# Целевые ОС: Ubuntu 22.04/24.04 LTS, Debian 12+.
#
# Режимы (через аргумент или DEPLOY_ACTION в .env):
#   bootstrap — один раз на сервер: пакеты, PHP, WP-CLI, сервисы (без сайта).
#   site      — новый инстанс WP: своя БД, каталог, vhost Nginx (повторять на домен).
#   full      — как раньше: bootstrap + один сайт за один прогон (обратная совместимость).
#
# Конфигурация: .env (см. .env.example). Значения с пробелами/скобками — в кавычках.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DEPLOY_ENV_FILE:-${SCRIPT_DIR}/.env}"

load_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    return 0
  fi
  echo ">>> Загрузка конфигурации: ${ENV_FILE}"
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Запустите скрипт от root или через: sudo $0" >&2
    exit 1
  fi
}

rand_hex() {
  openssl rand -hex "${1:-16}"
}

detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Не удалось определить ОС (/etc/os-release отсутствует)." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *)
      echo "Внимание: протестировано на Debian/Ubuntu. Текущий ID: ${ID:-unknown}" >&2
      ;;
  esac
}

# Имя файла для Nginx/SSL: example.com → example-com
slug_from_domain() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g'
}

# Имя БД: только буквы/цифры/подчёркивание, префикс wp_
db_name_from_domain() {
  local s
  s="$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr '.-' '__' | tr -c 'a-z0-9_' '_' | sed 's/__*/_/g' | sed 's/^_\|_$//g')"
  echo "wp_${s}" | cut -c1-63
}

install_stack_packages() {
  export DEBIAN_FRONTEND=noninteractive
  echo ">>> Обновление индекса пакетов..."
  apt-get update -qq

  echo ">>> Установка Nginx, MariaDB, PHP и расширений для WordPress..."
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    nginx \
    mariadb-server \
    mariadb-client \
    php-fpm \
    php-mysql \
    php-xml \
    php-mbstring \
    php-curl \
    php-zip \
    php-gd \
    php-intl \
    php-opcache \
    php-imagick \
    unzip
}

configure_php_wordpress_ini() {
  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  echo ">>> Обнаружен PHP ${PHP_VERSION}"

  echo ">>> Лимиты PHP для медиа и WP..."
  local PHP_EXTRA="/etc/php/${PHP_VERSION}/fpm/conf.d/99-wordpress-staging.ini"
  cat >"${PHP_EXTRA}" <<'INI'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 120
INI
}

ensure_wp_cli() {
  echo ">>> WP-CLI..."
  if ! command -v wp >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x /usr/local/bin/wp
  fi
  wp --info >/dev/null
}

enable_base_services() {
  echo ">>> Запуск MariaDB, PHP-FPM, Nginx..."
  systemctl enable --now mariadb
  systemctl enable --now "php${PHP_VERSION}-fpm"
  systemctl restart "php${PHP_VERSION}-fpm"
  systemctl enable --now nginx
}

write_nginx_vhost() {
  local domain="$1"
  local web_root="$2"
  local slug="$3"
  local skip_ssl="$4"
  local nginx_site="/etc/nginx/sites-available/wp-${slug}.conf"
  local nginx_enabled="/etc/nginx/sites-enabled/wp-${slug}.conf"

  if [[ "${skip_ssl}" != "1" ]]; then
    echo ">>> TLS (самоподписанный) для ${domain} → wp-${slug}..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "/etc/nginx/ssl/wp-${slug}.key" \
      -out "/etc/nginx/ssl/wp-${slug}.crt" \
      -days "${SELF_SIGNED_DAYS}" \
      -subj "/CN=${domain}"

    cat >"${nginx_site}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    ssl_certificate     /etc/nginx/ssl/wp-${slug}.crt;
    ssl_certificate_key /etc/nginx/ssl/wp-${slug}.key;

    root ${web_root};
    index index.php;

    access_log /var/log/nginx/wp-${slug}.access.log;
    error_log  /var/log/nginx/wp-${slug}.error.log;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~* /(?:uploads|files)/.*\\.php\$ {
        deny all;
    }

    location ~* \\.(?:engine|inc|info|install|make|module|profile|po|sh|.*sql|theme|tpl|xtpl|yaml|yml)\$ {
        deny all;
    }
}
NGINX
  else
    cat >"${nginx_site}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    root ${web_root};
    index index.php;

    access_log /var/log/nginx/wp-${slug}.access.log;
    error_log  /var/log/nginx/wp-${slug}.error.log;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \\.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~* /(?:uploads|files)/.*\\.php\$ {
        deny all;
    }

    location ~* \\.(?:engine|inc|info|install|make|module|profile|po|sh|.*sql|theme|tpl|xtpl|yaml|yml)\$ {
        deny all;
    }
}
NGINX
  fi

  ln -sf "${nginx_site}" "${nginx_enabled}"
  echo "${nginx_site}"
}

install_one_wordpress_site() {
  local domain="$1"
  local web_root="$2"
  local slug="$3"
  local db_name="$4"
  local db_user="$5"
  local db_pass="$6"
  local remove_default="$7"

  if [[ -f "${web_root}/wp-config.php" ]] && [[ "${FORCE_SITE_REINSTALL:-0}" != "1" ]]; then
    echo "Ошибка: ${web_root} уже содержит wp-config.php. Удалите каталог или задайте FORCE_SITE_REINSTALL=1 (опасно)." >&2
    exit 1
  fi

  echo ">>> Создание БД и пользователя (${db_name})..."
  mysql --protocol=socket -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

  echo ">>> Каталог сайта: ${web_root}"
  mkdir -p "${web_root}"
  chown -R www-data:www-data "${web_root}"

  echo ">>> Загрузка WordPress..."
  if [[ -n "${WP_LOCALE:-}" ]]; then
    wp core download --path="${web_root}" --locale="${WP_LOCALE}" --allow-root
  else
    wp core download --path="${web_root}" --allow-root
  fi

  wp config create \
    --path="${web_root}" \
    --dbname="${db_name}" \
    --dbuser="${db_user}" \
    --dbpass="${db_pass}" \
    --dbhost="localhost" \
    --dbcharset="utf8mb4" \
    --dbcollate="utf8mb4_unicode_ci" \
    --allow-root \
    --force

  wp config shuffle-salts --path="${web_root}" --allow-root

  local wp_url="http://${domain}"
  if [[ "${SKIP_SSL:-0}" != "1" ]]; then
    wp_url="https://${domain}"
  fi

  wp core install \
    --path="${web_root}" \
    --url="${wp_url}" \
    --title="${WP_TITLE}" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASS}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --allow-root

  wp option update blog_public 0 --path="${web_root}" --allow-root

  chown -R www-data:www-data "${web_root}"
  find "${web_root}" -type d -exec chmod 755 {} +
  find "${web_root}" -type f -exec chmod 644 {} +

  local nginx_conf_path
  nginx_conf_path="$(write_nginx_vhost "${domain}" "${web_root}" "${slug}" "${SKIP_SSL:-0}")"

  if [[ "${remove_default}" == "1" ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  echo ">>> Проверка конфигурации Nginx..."
  nginx -t
  systemctl restart nginx

  umask 077
  cat >"${CREDS_FILE}" <<EOF
WordPress (staging) — сохраните в надёжном месте и удалите с сервера после переноса.

Домен:         ${domain}
URL сайта:     ${wp_url}
Админка:       ${wp_url}/wp-admin/

База данных:
  DB_NAME:     ${db_name}
  DB_USER:     ${db_user}
  DB_PASS:     ${db_pass}
  DB_HOST:     localhost

WordPress админ:
  Логин:       ${WP_ADMIN_USER}
  Пароль:      ${WP_ADMIN_PASS}
  Email:       ${WP_ADMIN_EMAIL}

Файлы:         ${web_root}
Nginx site:    ${nginx_conf_path}

Примечание: blog_public=0 (не индексировать). Для стейджа — VPN / Basic Auth / firewall.
EOF
  chmod 600 "${CREDS_FILE}"

  echo
  echo "=== Сайт готов: ${domain} ==="
  echo "Учётные данные: ${CREDS_FILE}"
  echo "Откройте: ${wp_url}"
}

# --- Загрузка .env ---
load_env_file

DEPLOY_ACTION="${DEPLOY_ACTION:-${1:-full}}"

require_root
detect_os

case "${DEPLOY_ACTION}" in
  bootstrap)
    install_stack_packages
    configure_php_wordpress_ini
    ensure_wp_cli
    enable_base_services
    echo
    echo "=== Bootstrap завершён ==="
    echo "Дальше для каждого домена: скопируйте .env под сайт или задайте переменные и выполните:"
    echo "  sudo DEPLOY_ACTION=site DOMAIN=site2.example.com ./deploy.sh site"
    echo "или: sudo ./deploy.sh site   (с DOMAIN в .env)"
    ;;
  site)
    DOMAIN="${DOMAIN:?Задайте DOMAIN (FQDN этого сайта)}"
    SITE_SLUG="${SITE_SLUG:-$(slug_from_domain "${DOMAIN}")}"
    WEB_ROOT="${WEB_ROOT:-/var/www/sites/${DOMAIN}}"
    DB_NAME="${DB_NAME:-$(db_name_from_domain "${DOMAIN}")}"
    DB_USER="${DB_USER:-${DB_NAME}}"
    WP_TITLE="${WP_TITLE:-"WordPress ${DOMAIN}"}"
    WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
    WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.local}"
    WP_LOCALE="${WP_LOCALE:-}"
    SKIP_SSL="${SKIP_SSL:-0}"
    SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-825}"
    CREDS_FILE="${CREDS_FILE:-/root/wp-credentials-${SITE_SLUG}.txt}"
    REMOVE_NGINX_DEFAULT="${REMOVE_NGINX_DEFAULT:-0}"

    if ! command -v wp >/dev/null 2>&1 || ! systemctl is-active --quiet mariadb 2>/dev/null; then
      echo "Сначала выполните на этой ВМ: sudo ./deploy.sh bootstrap" >&2
      exit 1
    fi
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"

    if [[ -z "${DB_PASS:-}" ]]; then
      DB_PASS="$(rand_hex 16)"
    fi
    if [[ -z "${WP_ADMIN_PASS:-}" ]]; then
      WP_ADMIN_PASS="$(rand_hex 12)"
    fi

    install_one_wordpress_site \
      "${DOMAIN}" \
      "${WEB_ROOT}" \
      "${SITE_SLUG}" \
      "${DB_NAME}" \
      "${DB_USER}" \
      "${DB_PASS}" \
      "${REMOVE_NGINX_DEFAULT}"
    if [[ "${SKIP_SSL:-0}" != "1" ]]; then
      echo "TLS самоподписанный — примите исключение в браузере или SKIP_SSL=1."
    fi
    ;;
  full)
    DOMAIN="${DOMAIN:-localhost}"
    WEB_ROOT="${WEB_ROOT:-/var/www/wordpress}"
    DB_NAME="${DB_NAME:-wordpress}"
    DB_USER="${DB_USER:-${DB_NAME}}"
    WP_TITLE="${WP_TITLE:-"Site WordPress (staging)"}"
    WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
    WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.local}"
    WP_LOCALE="${WP_LOCALE:-}"
    SKIP_SSL="${SKIP_SSL:-0}"
    CREDS_FILE="${CREDS_FILE:-/root/wordpress-staging-credentials.txt}"
    SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-825}"
    SITE_SLUG="${SITE_SLUG:-wordpress-staging}"

    install_stack_packages
    configure_php_wordpress_ini
    ensure_wp_cli
    enable_base_services

    if [[ -z "${DB_PASS:-}" ]]; then
      DB_PASS="$(rand_hex 16)"
    fi
    if [[ -z "${WP_ADMIN_PASS:-}" ]]; then
      WP_ADMIN_PASS="$(rand_hex 12)"
    fi

    install_one_wordpress_site \
      "${DOMAIN}" \
      "${WEB_ROOT}" \
      "${SITE_SLUG}" \
      "${DB_NAME}" \
      "${DB_USER}" \
      "${DB_PASS}" \
      "1"
    echo "Перед продакшеном: сменить URL, снять noindex, нормальный SSL (Let's Encrypt)."
    if [[ "${SKIP_SSL:-0}" != "1" ]]; then
      echo "TLS самоподписанный — примите исключение в браузере или SKIP_SSL=1."
    fi
    ;;
  *)
    echo "Неизвестный режим: ${DEPLOY_ACTION}. Используйте: bootstrap | site | full" >&2
    exit 1
    ;;
esac
