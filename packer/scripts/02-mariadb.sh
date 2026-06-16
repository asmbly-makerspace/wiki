#!/usr/bin/env bash
# packer/scripts/02-mariadb.sh
# Phase 2: Install MariaDB 10.11 LTS, create MediaWiki DB and user.
set -euxo pipefail

MW_DB_NAME="${MW_DB_NAME:-mediawiki}"
MW_DB_USER="${MW_DB_USER:-wiki}"
MW_DB_PASSWORD="${MW_DB_PASSWORD:?MW_DB_PASSWORD must be set}"

# ── Install MariaDB 10.11 from the official MariaDB repo ──────────────────────
# AL2025 ships MariaDB 10.5; for 10.11 LTS we add the official repo.
cat > /etc/yum.repos.d/mariadb.repo << 'EOF'
[mariadb]
name = MariaDB 10.11 LTS
baseurl = https://downloads.mariadb.com/MariaDB/mariadb-10.11/yum/rhel/$releasever/$basearch
gpgkey = https://downloads.mariadb.com/MariaDB/RPM-GPG-KEY-MariaDB
gpgcheck = 1
enabled = 1
EOF

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
cat > /etc/my.cnf.d/mediawiki.cnf << 'EOF'
[mysqld]
# InnoDB settings
innodb_buffer_pool_size        = 256M
innodb_log_file_size           = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method            = O_DIRECT

# Character set
character_set_server = utf8mb4
collation_server     = utf8mb4_unicode_ci

# Query cache (disabled in MariaDB 10.11 by default, but be explicit)
query_cache_type = 0
query_cache_size = 0

# Logging — enable slow query log for debugging
slow_query_log      = 1
slow_query_log_file = /var/log/mariadb/slow.log
long_query_time     = 2

# Connections
max_connections     = 100
connect_timeout     = 10
wait_timeout        = 600
interactive_timeout = 600
EOF

systemctl restart mariadb

echo "02-mariadb.sh complete — MariaDB $(mysql --version | awk '{print $5}') configured"

