#!/bin/bash
# Runs in the mysql-init Job (image mysql:8.4). Idempotent, safe to run on every sync.
#  1. applies the app repository's SQL (databases, per-service users with local-dev default passwords, grants,
#     Debezium and monitoring users) from the platform-init bundle;
#  2. replaces every default password with the one from the mysql-users Secret (<USER>_PASSWORD variables, e.g.
#     ORDER_USER_PASSWORD for order_user), so no default password stays active on the cluster.
set -euo pipefail

printf '[client]\nhost=%s\nuser=root\npassword=%s\n' "${MYSQL_HOST:-mysql}" "$MYSQL_ROOT_PASSWORD" > /tmp/root.cnf
chmod 600 /tmp/root.cnf

echo "Waiting for MySQL at ${MYSQL_HOST:-mysql} ..."
until mysqladmin --defaults-extra-file=/tmp/root.cnf ping --silent >/dev/null 2>&1; do sleep 3; done

shopt -s nullglob
for file in /work/mysql/*.sql; do
  echo "Applying $(basename "$file")"
  mysql --defaults-extra-file=/tmp/root.cnf < "$file"
done

# <user>_PASSWORD variables -> ALTER USER (the user part is lower-cased: ORDER_USER_PASSWORD -> order_user).
count=0
while IFS='=' read -r name _; do
  case "$name" in
    *_PASSWORD) ;;
    *) continue ;;
  esac
  [[ "$name" == "MYSQL_ROOT_PASSWORD" ]] && continue
  user="$(echo "${name%_PASSWORD}" | tr '[:upper:]' '[:lower:]')"
  password="${!name}"
  # Escape single quotes for the SQL string literal.
  escaped="${password//\'/\'\'}"
  mysql --defaults-extra-file=/tmp/root.cnf -e "ALTER USER IF EXISTS '${user}'@'%' IDENTIFIED BY '${escaped}';"
  count=$((count + 1))
done < <(env)
mysql --defaults-extra-file=/tmp/root.cnf -e "FLUSH PRIVILEGES;"
echo "Set the passwords of ${count} users from the mysql-users secret."
rm -f /tmp/root.cnf
