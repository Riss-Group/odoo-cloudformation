#!/usr/bin/env bash
set -euo pipefail

### ─── Load variables file ──────────────────────────────────────────────── ###
VARFILE="${1:-}"
if [[ -z "$VARFILE" || ! -f "$VARFILE" ]]; then
  echo "Usage: $0 /path/to/odoo-install.env"
  exit 1
fi

set -o allexport
source "$VARFILE"
set +o allexport

### ─── Helper: Upsert environment variable in /etc/environment ─────────── ###
upsert_env_var() {
  local var="$1"
  local val="$2"
  if grep -qE "^${var}=" /etc/environment; then
    sed -i "s|^${var}=.*|${var}=\"${val}\"|" /etc/environment
  else
    echo "${var}=\"${val}\"" >> /etc/environment
  fi
}

### 1) Export environment variables ###
touch /etc/environment
upsert_env_var PGHOST                  "${RDS_ENDPOINT}"
upsert_env_var PGUSER                  "${RDS_USER}"
upsert_env_var PGPASSWORD              "${RDS_PASSWORD}"
upsert_env_var ODOO_SESSION_REDIS       1
upsert_env_var ODOO_SESSION_REDIS_URL   "${REDIS_ENDPOINT}"
upsert_env_var ODOO_SESSION_REDIS_PORT  6379
upsert_env_var PYTHONPYCACHEPREFIX      "/var/cache/pycache"
upsert_env_var ODOO_VERSION             "${ODOO_VERSION}"

### 2) System update + core tools + EFS build deps ###
apt-get update && \
  apt-get upgrade -y && \
  apt-get autoremove --purge -y && \
  apt-get install -y \
    git binutils rustc cargo pkg-config libssl-dev gettext \
    postgresql-client nginx s3fs gnupg

### 2a) Build & install amazon-efs-utils only if missing ###
if ! dpkg -s amazon-efs-utils >/dev/null 2>&1; then
  echo "amazon-efs-utils not found—building from source..."
  git clone https://github.com/aws/efs-utils /tmp/efs-utils
  cd /tmp/efs-utils
  ./build-deb.sh
  apt-get install -y ./build/amazon-efs-utils*deb
  cd /
  rm -rf /tmp/efs-utils
else
  echo "amazon-efs-utils already installed—skipping build."
fi

### 3) Pre‑create EFS dirs on the remote filesystem ###
mkdir -p /mnt/efs-temp
mount -t efs -o tls,noresvport "${EFS_ENDPOINT}:" /mnt/efs-temp
mkdir -p /mnt/efs-temp/Odoo/filestore /mnt/efs-temp/Odoo/sessions
umount /mnt/efs-temp && rmdir /mnt/efs-temp

### 4) Create RDS user with rds_superuser privileges ###
export PGPASSWORD="${RDS_PASSWORD}"
psql -h "${RDS_ENDPOINT}" -U postgres <<SQL
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${RDS_USER}') THEN
    CREATE ROLE "${RDS_USER}" WITH LOGIN PASSWORD '${RDS_PASSWORD}';
  END IF;
END
$$;
GRANT rds_superuser TO "${RDS_USER}";
SQL

### 5) Install Odoo via Debian package (force config overwrite) ###
# Import Odoo GPG key
wget -qO- https://nightly.odoo.com/odoo.key \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/odoo-archive-keyring.gpg

# Add nightly repo for specified version
REPO_LINE="deb [signed-by=/usr/share/keyrings/odoo-archive-keyring.gpg] https://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/ ./"
grep -Fxq "$REPO_LINE" /etc/apt/sources.list.d/odoo.list 2>/dev/null || \
  echo "$REPO_LINE" > /etc/apt/sources.list.d/odoo.list

apt-get update
# Install Odoo version
DEBIAN_FRONTEND=noninteractive apt-get install -y odoo

### Install wkhtmltopdf ###
WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_arm64.deb"
wget -qO /tmp/wkhtmltox.deb "$WK_URL"
apt-get install -y /tmp/wkhtmltox.deb && rm -f /tmp/wkhtmltox.deb

### Remove PostgreSQL server ###
apt-get remove --purge -y postgresql

### 6) Prepare mount points & fstab ###
mkdir -p /var/lib/odoo/.local/share/Odoo/filestore \
         /var/lib/odoo/.local/share/Odoo/sessions /mnt/efs /mnt/s3

F=/etc/fstab
for entry in \
  "${EFS_ENDPOINT}:/Odoo/filestore  /var/lib/odoo/.local/share/Odoo/filestore  efs _netdev,noresvport,tls,fsc 0 0" \
  "${EFS_ENDPOINT}:/               /mnt/efs efs _netdev,noresvport,tls 0 0" \
  "${EFS_ENDPOINT}:/Odoo/sessions  /var/lib/odoo/.local/share/Odoo/sessions  efs _netdev,noresvport,tls 0 0" \
  "s3fs#${S3_BUCKET} /mnt/s3 fuse _netdev,allow_other,umask=000 0 0"; do
  grep -Fxq "$entry" $F || echo "$entry" >> $F
done
echo "${S3FS_KEY}:${S3FS_SECRET}" > /etc/passwd-s3fs && chmod 600 /etc/passwd-s3fs

# Mount fresh
umount -l /var/lib/odoo/.local/share/Odoo/filestore \
         /var/lib/odoo/.local/share/Odoo/sessions /mnt/efs /mnt/s3 2>/dev/null || true
mount -a

### 7) Configure Nginx ###
cat <<'EOF' > /etc/nginx/sites-enabled/default
upstream odoo     { server 127.0.0.1:8069; }
upstream odoochat { server 127.0.0.1:8072; }
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
server {
  listen 80;
  client_max_body_size 256M;
  proxy_read_timeout 3600s; proxy_connect_timeout 3600s; proxy_send_timeout 3600s;
  access_log /var/log/nginx/odoo.access.log;
  error_log  /var/log/nginx/odoo.error.log;
  location /websocket {
    proxy_pass http://odoochat;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP $remote_addr;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
  }
  location / {
    # Add Headers for odoo proxy mode
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_redirect off;
    proxy_pass http://odoo;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
  }
  gzip on; gzip_types text/css text/plain application/xml application/json application/javascript;
}
EOF

# Reinstall Nginx to apply config
DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall \
  -o Dpkg::Options::="--force-confnew" \
  -o Dpkg::Options::="--force-overwrite" nginx

nginx -t && systemctl restart nginx

### 8) Clone repos ###
base_dir="/var/lib/odoo/.local/share/Odoo/addons/repos"
# Client repo
dir1="$base_dir/$(basename "${GITHUB_REPO#https://github.com/}")"
[ -d "$dir1" ] && rm -rf "$dir1"
git clone "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_REPO#https://github.com/}.git" "$dir1"
# Enterprise repo
dir2="$base_dir/enterprise"
[ -d "$dir2" ] && rm -rf "$dir2"
git clone --branch "$ODOO_VERSION" "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/odoo/enterprise.git" "$dir2"

### 9) Configure Odoo ###
conf="/etc/odoo/odoo.conf"; cp "$conf" "${conf}.bak"
cat <<EOF > "$conf"
[options]
admin_passwd      = $ADMIN_PASSWD
db_host           = $RDS_ENDPOINT
db_user           = $RDS_USER
db_password       = $RDS_PASSWORD
dbfilter          = ^%d\$
addons_path       = /usr/lib/python3/dist-packages/odoo/addons,
  $dir1,
  $dir2
proxy_mode        = True
server_wide_modules = base,web,session_redis
EOF

systemctl restart odoo && chown -R odoo:odoo /var/lib/odoo

echo "Odoo ${ODOO_VERSION} install complete."