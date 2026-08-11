#!/bin/bash
set -Eeuo pipefail

log() { printf '[fast] %s\n' "$*"; }
fatal() { printf '[fast] ERROR: %s\n' "$*" >&2; exit 1; }
require_var() { local name="$1"; [[ -n "${!name:-}" ]] || fatal "Required variable ${name} is not set."; }

INTERNAL_DB=false
if [[ -z "${DB_HOST:-}" ]]; then
  INTERNAL_DB=true
fi
require_var DB_ROOT_PASSWORD
require_var DB_USER
require_var DB_PASSWORD
require_var DB_NAME
require_var DB_CDR_NAME

mkdir -p /run/mysqld /var/log/mysql /var/run/asterisk /var/log/asterisk /var/log/pbx
chown -R mysql:mysql /run/mysqld /var/log/mysql
chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk 2>/dev/null || true

if [[ "$INTERNAL_DB" == true ]]; then
  if [[ ! -d /var/lib/mysql/mysql ]]; then
    log 'Initializing internal MariaDB.'
    mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
  fi
  if ! mariadb-admin --protocol=socket ping >/dev/null 2>&1; then
    log 'Starting internal MariaDB.'
    mariadbd --user=mysql --datadir=/var/lib/mysql --bind-address=127.0.0.1 --skip-name-resolve \
      --socket=/run/mysqld/mysqld.sock --pid-file=/run/mysqld/mysqld.pid >/var/log/mysql/mariadb.log 2>&1 &
  fi
  for _ in {1..60}; do mariadb-admin --protocol=socket ping >/dev/null 2>&1 && break; sleep 1; done
  mariadb-admin --protocol=socket ping >/dev/null 2>&1 || fatal 'Internal MariaDB did not become ready.'
  DB_HOST=127.0.0.1
  export DB_HOST
else
  log "Waiting for external MariaDB at ${DB_HOST}:${DB_PORT}."
  for _ in {1..90}; do
    mariadb-admin --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" --password="$DB_PASSWORD" ping >/dev/null 2>&1 && break
    sleep 2
  done
  mariadb-admin --host="$DB_HOST" --port="$DB_PORT" --user="$DB_USER" --password="$DB_PASSWORD" ping >/dev/null 2>&1 || fatal 'External MariaDB is not reachable with the configured credentials.'
fi

log 'Ensuring FreePBX databases and user exist.'
MYSQL_ROOT=(mariadb --host="$DB_HOST" --port="$DB_PORT" --user=root --password="$DB_ROOT_PASSWORD")
"${MYSQL_ROOT[@]}" -e "CREATE DATABASE IF NOT EXISTS \\`$DB_NAME\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE DATABASE IF NOT EXISTS \\`$DB_CDR_NAME\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; ALTER USER '$DB_USER'@'%' IDENTIFIED BY '$DB_PASSWORD'; GRANT ALL PRIVILEGES ON \\`$DB_NAME\\`.* TO '$DB_USER'@'%'; GRANT ALL PRIVILEGES ON \\`$DB_CDR_NAME\\`.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES;" || fatal 'Could not provision FreePBX databases. Verify DB_ROOT_PASSWORD and external MariaDB privileges.'

cat > /etc/odbcinst.ini <<'EOF'
[MariaDB]
Description=MariaDB ODBC driver
Driver=/usr/lib/x86_64-linux-gnu/odbc/libmaodbc.so
FileUsage=1
EOF
cat > /etc/odbc.ini <<EOF
[MySQL-asteriskcdrdb]
Description=FreePBX CDR database
Driver=MariaDB
Server=${DB_HOST}
Database=${DB_CDR_NAME}
Port=${DB_PORT}
Option=3
EOF

if [[ -f /etc/asterisk/rtp.conf ]]; then
  sed -i -E "s/^rtpstart=.*/rtpstart=${RTP_START}/; s/^rtpend=.*/rtpend=${RTP_END}/" /etc/asterisk/rtp.conf
  grep -q '^rtpstart=' /etc/asterisk/rtp.conf || printf '\nrtpstart=%s\n' "$RTP_START" >> /etc/asterisk/rtp.conf
  grep -q '^rtpend=' /etc/asterisk/rtp.conf || printf 'rtpend=%s\n' "$RTP_END" >> /etc/asterisk/rtp.conf
fi

if ! pgrep -x asterisk >/dev/null 2>&1; then
  log 'Starting Asterisk.'
  /usr/sbin/asterisk -U asterisk -G asterisk -vvvgc >/var/log/asterisk/asterisk-console.log 2>&1 &
  for _ in {1..30}; do asterisk -rx 'core show version' >/dev/null 2>&1 && break; sleep 1; done
fi
asterisk -rx 'core show version' >/dev/null 2>&1 || fatal 'Asterisk failed to start.'

if [[ ! -f /etc/freepbx.conf ]]; then
  log 'First startup detected; installing FreePBX framework into the configured database.'
  cd /var/www/html
  [[ -x ./install ]] || fatal 'FreePBX installer is missing from /var/www/html.'
  ./install -n --dbuser "$DB_USER" --dbpass "$DB_PASSWORD" --dbhost "$DB_HOST" --dbport "$DB_PORT" \
    --dbname "$DB_NAME" --cdrdbname "$DB_CDR_NAME" --user asterisk --group asterisk \
    --webroot /var/www/html || fatal 'FreePBX installation failed. Inspect /var/log/pbx and container logs.'
  fwconsole ma installall || fatal 'FreePBX module installation failed.'
  fwconsole chown || true
  fwconsole reload || true
fi

fwconsole chown >/dev/null 2>&1 || true
fwconsole reload >/dev/null 2>&1 || true
apachectl -k start
log 'FreePBX/Asterisk is ready.'

trap 'log "Stopping Asterisk/Apache/MariaDB."; asterisk -rx "core stop gracefully" >/dev/null 2>&1 || true; apachectl -k stop >/dev/null 2>&1 || true; if [[ "$INTERNAL_DB" == true ]]; then mariadb-admin --protocol=socket --user=root --password="$DB_ROOT_PASSWORD" shutdown >/dev/null 2>&1 || true; fi; exit 0' TERM INT

while pgrep -x asterisk >/dev/null 2>&1; do sleep 5; done
fatal 'Asterisk exited unexpectedly. Check /var/log/asterisk/asterisk-console.log.'
