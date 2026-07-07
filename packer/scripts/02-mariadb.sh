#!/usr/bin/env bash
# packer/scripts/02-mariadb.sh
# Phase 2: Install MariaDB 10.11 LTS, create MediaWiki DB and user.
set -euxo pipefail

: "${MW_DB_NAME:?MW_DB_NAME must be set}"
: "${MW_DB_USER:?MW_DB_USER must be set}"
: "${MW_DB_PASSWORD:?MW_DB_PASSWORD must be set}"

# ── Install MariaDB 10.11 from the official MariaDB repo ──────────────────────
cp /tmp/config/mariadb/mariadb.repo /etc/yum.repos.d/mariadb.repo

dnf install -y MariaDB-server MariaDB-client

# ── Start MariaDB for setup ───────────────────────────────────────────────────
systemctl enable mariadb
systemctl start mariadb

# Wait until socket is available
for i in $(seq 1 15); do
  mysqladmin ping --silent && break
  sleep 2
done
mysqladmin ping || { echo "MariaDB did not start in time"; exit 1; }

# ── Secure installation (non-interactive) ────────────────────────────────────
ROOT_PASS=$(openssl rand -hex 24)
mysql --user=root << SQL
  -- Remove anonymous users
  DELETE FROM mysql.user WHERE User='';
  -- Remove remote root login
  DELETE FROM mysql.user WHERE User='root' AND Host != 'localhost';
  -- Remove test database
  DROP DATABASE IF EXISTS test;
  DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
  -- Set root password
  ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PASS}';
  FLUSH PRIVILEGES;
SQL

# Write root credentials so later scripts can bootstrap
cat > /root/.my.cnf << EOF
[client]
user=root
password=${ROOT_PASS}
EOF
chmod 600 /root/.my.cnf

# ── Create MediaWiki database & user ─────────────────────────────────────────
mysql << SQL
  CREATE DATABASE IF NOT EXISTS \`${MW_DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

  CREATE USER IF NOT EXISTS '${MW_DB_USER}'@'localhost'
    IDENTIFIED BY '${MW_DB_PASSWORD}';

  GRANT ALL PRIVILEGES ON \`${MW_DB_NAME}\`.* TO '${MW_DB_USER}'@'localhost';

  FLUSH PRIVILEGES;
SQL

# ── MariaDB performance tuning for a single-server wiki ──────────────────────
cp /tmp/config/mariadb/mediawiki.cnf /etc/my.cnf.d/mediawiki.cnf

systemctl restart mariadb

echo "02-mariadb.sh complete — MariaDB $(mysql --version | awk '{print $5}') configured"

