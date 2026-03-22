#!/usr/bin/env bash
# =============================================================================
# Развёртывание стека для WordPress (стейдж / демо на Proxmox): Nginx + MariaDB + PHP-FPM + WP-CLI.
# Целевые ОС: Ubuntu 22.04/24.04 LTS, Debian 12+.
# Запуск: sudo ./deploy.sh   (или от root: ./deploy.sh)
#
# Конфигурация: скопируйте .env.example → .env и задайте значения (см. .env.example).
# Порядок: загрузка .env, затем значения по умолчанию для пустых переменных.
# Ключи из .env перезаписывают уже экспортированные в окружении (если заданы в .env).
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

load_env_file

# --- Конфигурация: .env + значения по умолчанию ---
DOMAIN="${DOMAIN:-localhost}"
WEB_ROOT="${WEB_ROOT:-/var/www/wordpress}"
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-${DB_NAME}}"
WP_TITLE="${WP_TITLE:-Site WordPress (staging)}"
WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@example.local}"
WP_LOCALE="${WP_LOCALE:-}"
SKIP_SSL="${SKIP_SSL:-0}"
CREDS_FILE="${CREDS_FILE:-/root/wordpress-staging-credentials.txt}"
SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-825}"

require_root
detect_os

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

# Версия PHP для путей к сокету и conf.d
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
echo ">>> Обнаружен PHP ${PHP_VERSION}"

echo ">>> Лимиты PHP для медиа и WP..."
PHP_EXTRA="/etc/php/${PHP_VERSION}/fpm/conf.d/99-wordpress-staging.ini"
cat >"${PHP_EXTRA}" <<'INI'
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
max_execution_time = 120
INI

echo ">>> WP-CLI..."
if ! command -v wp >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
fi
wp --info >/dev/null

echo ">>> Запуск MariaDB..."
systemctl enable --now mariadb

# Пароли: из .env или автогенерация
if [[ -z "${DB_PASS:-}" ]]; then
  DB_PASS="$(rand_hex 16)"
fi
if [[ -z "${WP_ADMIN_PASS:-}" ]]; then
  WP_ADMIN_PASS="$(rand_hex 12)"
fi

echo ">>> Создание БД и пользователя..."
mysql --protocol=socket -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL

echo ">>> Каталог сайта: ${WEB_ROOT}"
mkdir -p "${WEB_ROOT}"
chown -R www-data:www-data "${WEB_ROOT}"

echo ">>> Загрузка WordPress..."
if [[ -n "${WP_LOCALE}" ]]; then
  wp core download --path="${WEB_ROOT}" --locale="${WP_LOCALE}" --allow-root
else
  wp core download --path="${WEB_ROOT}" --allow-root
fi

wp config create \
  --path="${WEB_ROOT}" \
  --dbname="${DB_NAME}" \
  --dbuser="${DB_USER}" \
  --dbpass="${DB_PASS}" \
  --dbhost="localhost" \
  --dbcharset="utf8mb4" \
  --dbcollate="utf8mb4_unicode_ci" \
  --allow-root \
  --force

# Секреты и префикс таблиц по умолчанию — wp core install сам не задаёт salts; wp config shuffle-salts
wp config shuffle-salts --path="${WEB_ROOT}" --allow-root

WP_URL="http://${DOMAIN}"
if [[ "${SKIP_SSL}" != "1" ]]; then
  WP_URL="https://${DOMAIN}"
fi

wp core install \
  --path="${WEB_ROOT}" \
  --url="${WP_URL}" \
  --title="${WP_TITLE}" \
  --admin_user="${WP_ADMIN_USER}" \
  --admin_password="${WP_ADMIN_PASS}" \
  --admin_email="${WP_ADMIN_EMAIL}" \
  --allow-root

# Стейдж: не индексировать (дополнительно к firewall / Basic Auth)
wp option update blog_public 0 --path="${WEB_ROOT}" --allow-root

chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 755 {} +
find "${WEB_ROOT}" -type f -exec chmod 644 {} +

NGINX_SITE="/etc/nginx/sites-available/wordpress-staging"
NGINX_ENABLED="/etc/nginx/sites-enabled/wordpress-staging"

if [[ "${SKIP_SSL}" != "1" ]]; then
  echo ">>> Самоподписанный TLS (демо/стейдж; браузер покажет предупреждение)..."
  mkdir -p /etc/nginx/ssl
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/wordpress-staging.key \
    -out /etc/nginx/ssl/wordpress-staging.crt \
    -days "${SELF_SIGNED_DAYS}" \
    -subj "/CN=${DOMAIN}"

  cat >"${NGINX_SITE}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     /etc/nginx/ssl/wordpress-staging.crt;
    ssl_certificate_key /etc/nginx/ssl/wordpress-staging.key;

    root ${WEB_ROOT};
    index index.php;

    access_log /var/log/nginx/wordpress-staging.access.log;
    error_log  /var/log/nginx/wordpress-staging.error.log;

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
  cat >"${NGINX_SITE}" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.php;

    access_log /var/log/nginx/wordpress-staging.access.log;
    error_log  /var/log/nginx/wordpress-staging.error.log;

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

rm -f /etc/nginx/sites-enabled/default
ln -sf "${NGINX_SITE}" "${NGINX_ENABLED}"

echo ">>> Проверка конфигурации Nginx..."
nginx -t

echo ">>> Перезапуск PHP-FPM и Nginx..."
systemctl enable --now "php${PHP_VERSION}-fpm"
systemctl restart "php${PHP_VERSION}-fpm"
systemctl enable --now nginx
systemctl restart nginx

umask 077
cat >"${CREDS_FILE}" <<EOF
WordPress (staging) — сохраните в надёжном месте и удалите с сервера после переноса.

URL сайта:     ${WP_URL}
Админка:       ${WP_URL}/wp-admin/

База данных:
  DB_NAME:     ${DB_NAME}
  DB_USER:     ${DB_USER}
  DB_PASS:     ${DB_PASS}
  DB_HOST:     localhost

WordPress админ:
  Логин:       ${WP_ADMIN_USER}
  Пароль:      ${WP_ADMIN_PASS}
  Email:       ${WP_ADMIN_EMAIL}

Файлы:         ${WEB_ROOT}
Nginx site:    ${NGINX_SITE}

Примечание: включено «Попросить поисковые системы не индексировать сайт» (blog_public=0).
Для показа клиенту добавьте Basic Auth или VPN; см. обсуждение staging.
EOF
chmod 600 "${CREDS_FILE}"

echo
echo "=== Готово ==="
echo "Учётные данные: ${CREDS_FILE}"
echo "Откройте в браузере: ${WP_URL}"
if [[ "${SKIP_SSL}" != "1" ]]; then
  echo "TLS самоподписанный — примите исключение в браузере или используйте SKIP_SSL=1 для только HTTP."
fi
echo "Перед продакшеном: сменить URL в БД, снять noindex, настроить нормальный SSL (Let's Encrypt)."
