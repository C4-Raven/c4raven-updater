#!/usr/bin/env bash
# Completes a C4 Raven install (the `raven` layout from c4raven-server-setup's
# install.sh, online .deb or .rpm) that stopped partway the first time.
#
#   ./finish-install.sh
#
# install.sh stops at the first failing command, so a failure anywhere leaves
# everything after it undone -- typically "Unit raven.service not found" and a
# web UI nobody can log in to. This script checks every piece in install
# order and repairs only what is missing or broken:
#
#   backend checkout + venv, config.yml, PostgreSQL role/database/grants and
#   the URI in config.yml, migrations to head, the
#   certificate authority and server certificate, MediaMTX (binary, config,
#   webhook token, unit), nginx sites/streams (+ current hardening), the web
#   UI, RabbitMQ plugins/config, the secrets file, the systemd units, starting
#   everything, the first administrator account, a test login, and Federation
#   Hub (install-fedhub.sh: offered when missing, reconnected when needed).
#
# Idempotent: on a complete install it changes nothing (apart from restarting
# services that are not running). It never drops or empties the database,
# never regenerates an existing CA or config.yml, and never overwrites an
# existing nginx site except for the in-place hardening fixes.
#
# Run it as your own sudo-capable user, or as root (e.g. in a container).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

APP_USER="${RAVEN_USER:-raven}"
APP_HOME="${RAVEN_HOME:-/opt/raven}"
DATA_DIR="${RAVEN_DATA_DIR:-$APP_HOME/data}"
DB_NAME="${RAVEN_DB_NAME:-raven}"
WEBROOT="${UI_DEPLOY_DIR:-/var/www/html/raven}"
SERVER_REPO="${SERVER_REPO:-https://github.com/C4-Raven/c4raven-server.git}"
UI_REPO="${UI_REPO:-https://github.com/C4-Raven/c4raven-ui.git}"
# SETUP_REPO_RAW (lib/common.sh): where the installer's templates come from.
PG_SERVICE="${PG_SERVICE:-postgresql}"
RABBIT_SERVICE="${RABBIT_SERVICE:-rabbitmq-server}"

if [[ "$(id -un)" == "$APP_USER" ]]; then
  die "Run this as your own sudo-capable user (or root), not as '$APP_USER'."
fi
if [[ -z "${RAVEN_UPDATER_LOCKED:-}" ]] && command -v flock >/dev/null 2>&1; then
  # Lock on a read-only descriptor: flock works on one, and fs.protected_regular
  # stops root opening another user's existing /tmp file for writing (O_CREAT),
  # so `exec 9>` failed under sudo whenever an earlier non-sudo run had left the
  # lock file behind ("Permission denied").
  RAVEN_LOCK="${TMPDIR:-/tmp}/c4raven-updater.lock"
  [[ -e "$RAVEN_LOCK" ]] || (umask 000; : > "$RAVEN_LOCK") 2>/dev/null || true
  { exec 9<"$RAVEN_LOCK"; } 2>/dev/null || die "Cannot open the lock file $RAVEN_LOCK (delete it and re-run)."
  flock -n 9 || die "Another update.sh / finish-install.sh is already running."
  export RAVEN_UPDATER_LOCKED=1
fi

as_app() { as_user "$APP_USER" "$@"; }
as_app_sh() { as_user_sh "$APP_USER" "$1"; }
q() { printf '%q' "$1"; }
fetch() {  # fetch RELPATH DEST  (from the setup repo, with retries)
  # Download as the invoking user, then install as root: root may not write
  # into another user's file in sticky /tmp (fs.protected_regular).
  local t rc=0
  t="$(mktemp)"
  retry curl -fsSL "$SETUP_REPO_RAW/$1" -o "$t" || rc=$?
  [[ "$rc" == 0 ]] && { as_root install -m 644 "$t" "$2" || rc=$?; }
  rm -f "$t"
  return "$rc"
}

systemd_notice

# The legacy layout (one login user, venv ~/.raven_venv) uses the same
# raven.service and /var/www/html/raven as this one, but nothing under
# $APP_HOME: it is updated by update.sh and must not be "finished" into a
# second install.
INVOKER_HOME="$HOME"
[[ -n "${SUDO_USER:-}" ]] && INVOKER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
# Also ask systemd: an existing raven.service that runs from a ~/.raven_venv
# is the legacy layout whoever runs this (root without SUDO_USER, another
# sudo user).
MAIN_EXEC=""
command -v systemctl >/dev/null 2>&1 && MAIN_EXEC=$(systemctl show -p ExecStart --value raven.service 2>/dev/null || true)
if { [[ -d "$INVOKER_HOME/.raven_venv" ]] || [[ "$MAIN_EXEC" == *"/.raven_venv/"* ]]; } \
   && ! as_root test -d "$APP_HOME/c4raven-server/.git" && ! as_root test -L "$APP_HOME/venv"; then
  die "This is the legacy layout (a ~/.raven_venv install), not an install under $APP_HOME. Use ./update.sh instead."
fi

# Which backend layout: install.sh / online package = Poetry venv in the
# checkout; offline package = plain venv behind /opt/raven/venv.
if as_root test -L "$APP_HOME/venv"; then
  BACKEND=offline
  VENV="$APP_HOME/venv"
  WORKDIR="$DATA_DIR"
else
  BACKEND=source
  VENV="$APP_HOME/c4raven-server/.venv"
  WORKDIR="$APP_HOME/c4raven-server"
fi
PY="$VENV/bin/python"
CFG="$DATA_DIR/config.yml"

# ---- 0. prerequisites ---------------------------------------------------------
log "Checking prerequisites"
missing=()
for c in psql nginx git curl rsync openssl; do
  command -v "$c" >/dev/null 2>&1 || as_root test -x "/usr/sbin/$c" || missing+=("$c")
done
command -v rabbitmq-plugins >/dev/null 2>&1 || as_root test -x /usr/sbin/rabbitmq-plugins || missing+=("rabbitmq-server")
if [[ "${#missing[@]}" -gt 0 ]]; then
  die "Missing system packages: ${missing[*]}. install.sh never got past installing packages; re-run install.sh (it is safe to re-run)."
fi
if ! id "$APP_USER" >/dev/null 2>&1; then
  as_root useradd --system --create-home --home-dir "$APP_HOME" --shell /bin/bash "$APP_USER"
  as_root chmod 750 "$APP_HOME"
  fixed "created the $APP_USER system user"
fi
as_app mkdir -p "$DATA_DIR/logs"
ok "packages and the $APP_USER account are present"

# ---- 1. backend ------------------------------------------------------------------
log "Backend"
if [[ "$BACKEND" == source ]]; then
  if ! as_root test -d "$APP_HOME/c4raven-server/.git"; then
    as_root rm -rf "$APP_HOME/c4raven-server"   # a clone that died halfway
    retry as_app git clone "$SERVER_REPO" "$APP_HOME/c4raven-server" || die "Could not clone $SERVER_REPO (network?)."
    fixed "cloned c4raven-server"
  fi
  if ! as_app test -x "$APP_HOME/.local/bin/poetry"; then
    PYBIN=python3
    [[ "$DISTRO_FAMILY" == rhel ]] && PYBIN=python3.12
    retry as_app_sh "curl -sSL https://install.python-poetry.org | $PYBIN -" || die "Could not install Poetry (network?)."
    fixed "installed Poetry for $APP_USER"
  fi
  if ! as_app test -x "$VENV/bin/raven" || ! as_app "$PY" -c 'import raven.app' >/dev/null 2>&1; then
    as_app_sh "poetry config virtualenvs.in-project true"
    [[ "$DISTRO_FAMILY" == rhel ]] && as_app_sh "cd $(q "$WORKDIR") && poetry env use \$(command -v python3.12)"
    retry as_app_sh "cd $(q "$WORKDIR") && PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring poetry install --no-interaction" || die "poetry install failed (output above)."
    as_app git -C "$WORKDIR" checkout -- raven/__init__.py 2>/dev/null || true
    fixed "backend dependencies installed"
  else
    ok "backend venv is complete"
  fi
else
  as_app test -x "$VENV/bin/raven" || die "$VENV is incomplete: finish the offline package with: sudo dpkg --configure -a (or reinstall the offline bundle)."
  ok "offline package venv present"
fi

# The app's CLI logs to logs/raven.log: a copy systemd created as root makes
# every flask command below die with PermissionError.
fix_log_ownership "$APP_USER" "$DATA_DIR/logs" raven.log || true

if ! as_app test -f "$CFG"; then
  flask_cmd "$APP_USER" "$VENV" "$DATA_DIR" "$WORKDIR" raven generate-config
  fixed "generated config.yml"
else
  ok "config.yml present"
fi

# ---- 2. PostgreSQL ------------------------------------------------------------------
log "PostgreSQL"
if [[ "$HAS_SYSTEMD" == 1 ]]; then
  if [[ "$DISTRO_FAMILY" == rhel ]] && ! as_root test -f /var/lib/pgsql/data/PG_VERSION; then
    as_root postgresql-setup --initdb && fixed "initialised the PostgreSQL cluster"
  fi
  unit_active "$PG_SERVICE" || { as_root systemctl enable --now "$PG_SERVICE" && fixed "started $PG_SERVICE"; }
fi
for i in $(seq 1 15); do as_postgres "psql -XtAc 'select 1'" >/dev/null 2>&1 && break; sleep 2; done
as_postgres "psql -XtAc 'select 1'" >/dev/null 2>&1 || die "PostgreSQL isn't accepting connections. Start it (sudo systemctl start $PG_SERVICE, or pg_ctlcluster in a container) and re-run."

URI="$(config_get "$PY" "$CFG" "$APP_USER" SQLALCHEMY_DATABASE_URI)"
role_exists="$(as_postgres "psql -XtAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_NAME'\"")"
db_password=""
case "$URI" in
  postgresql*://"$DB_NAME":*@*) db_password="${URI#*://"$DB_NAME":}"; db_password="${db_password%@*}" ;;
esac
if [[ -z "$db_password" ]]; then
  # Hex only: it goes raw into a URI (same as install.sh).
  db_password="$(openssl rand -hex 16)"
  URI="postgresql+psycopg://$DB_NAME:$db_password@127.0.0.1/$DB_NAME"
  config_set "$PY" "$CFG" "$APP_USER" SQLALCHEMY_DATABASE_URI "$URI"
  fixed "config.yml now points at the PostgreSQL database"
fi
if [[ "$role_exists" != 1 ]]; then
  as_postgres "psql -Xqc \"CREATE ROLE $DB_NAME WITH LOGIN PASSWORD '$db_password';\""
  fixed "created database role $DB_NAME"
elif ! PGPASSWORD="$db_password" psql -XtAq -h 127.0.0.1 -U "$DB_NAME" -d postgres -c 'select 1' >/dev/null 2>&1; then
  # The role exists but config.yml's password doesn't work (install died
  # between the two). Make the role match config.yml, not the other way
  # round: config.yml is what the app and the secrets file use.
  as_postgres "psql -Xqc \"ALTER ROLE $DB_NAME WITH LOGIN PASSWORD '$db_password';\""
  fixed "reset role $DB_NAME's password to the one in config.yml"
fi
if [[ "$(as_postgres "psql -XtAc \"SELECT 1 FROM pg_database WHERE datname='$DB_NAME'\"")" != 1 ]]; then
  as_postgres "psql -Xqc 'CREATE DATABASE $DB_NAME;'"
  fixed "created database $DB_NAME"
fi
as_postgres "psql -Xqc 'GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO $DB_NAME;'" >/dev/null
as_postgres "psql -Xq -d $DB_NAME -c 'GRANT ALL ON SCHEMA public TO $DB_NAME;'" >/dev/null
as_postgres "psql -Xq -d $DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis'" >/dev/null 2>&1 || true
PGPASSWORD="$db_password" psql -XtAq -h 127.0.0.1 -U "$DB_NAME" -d "$DB_NAME" -c 'select 1' >/dev/null 2>&1 \
  || die "The app's database credentials still don't work against 127.0.0.1 (check pg_hba.conf allows md5/scram for 127.0.0.1)."
ok "role, database and grants in place; config.yml's credentials work"

log "Database schema"
db_migrate "$APP_USER" "$VENV" "$DATA_DIR" "$WORKDIR" || die "Migrations failed (output above)."

log "config.yml settings"
if out=$(config_add_keys "$PY" "$CFG" "$APP_USER" "$APP_HOME/.raven-secrets.env"); then
  if [[ -n "$out" ]]; then fixed "config.yml: added $(echo "$out" | tr '\n' ' ')"; else ok "config.yml left as it is"; fi
fi
if out=$(config_drop_retired "$PY" "$CFG" "$APP_USER"); then
  [[ -n "$out" ]] && fixed "config.yml: removed the retired default of $out"
fi

# ---- 3. certificate authority ----------------------------------------------------------
log "Certificate authority"
if ! as_app test -s "$DATA_DIR/ca/ca.pem"; then
  flask_cmd "$APP_USER" "$VENV" "$DATA_DIR" "$WORKDIR" raven create-ca
  fixed "created the certificate authority"
fi
if ! as_app test -s "$DATA_DIR/ca/certs/raven/raven.pem" || ! as_app test -s "$DATA_DIR/ca/certs/raven/raven.nopass.key"; then
  flask_cmd "$APP_USER" "$VENV" "$DATA_DIR" "$WORKDIR" raven issue-server-certificate
  fixed "issued the server certificate"
fi
ok "CA and server certificate present"
if command -v restorecon >/dev/null 2>&1; then as_root restorecon -R "$DATA_DIR/ca" >/dev/null 2>&1 || true; fi

# ---- 4. MediaMTX ------------------------------------------------------------------------
log "MediaMTX"
MTX_DIR="$DATA_DIR/mediamtx"
as_app mkdir -p "$MTX_DIR/recordings"
if ! as_app test -x "$MTX_DIR/mediamtx"; then
  case "$(uname -m)" in
    x86_64) MTX_ARCH=amd64 ;; aarch64|arm64) MTX_ARCH=arm64 ;; armv7l|armv8l) MTX_ARCH=armv7 ;; *) MTX_ARCH="" ;;
  esac
  if [[ -n "$MTX_ARCH" && "$BACKEND" == source ]]; then
    if retry as_app_sh "cd $(q "$WORKDIR") && poetry run lastversion --filter '~*linux_$MTX_ARCH' --only 1.13.0 -o $(q "$MTX_DIR/mediamtx.tar.gz") --assets download bluenviron/mediamtx" \
       && as_app_sh "cd $(q "$MTX_DIR") && tar -xf mediamtx.tar.gz && rm -f mediamtx.tar.gz"; then
      fixed "downloaded mediamtx"
    else
      warn "could not download mediamtx; video streaming won't work until it's in $MTX_DIR"
    fi
  else
    warn "mediamtx binary missing in $MTX_DIR"
  fi
fi
if ! as_app test -f "$MTX_DIR/mediamtx.yml"; then
  tmp="$(mktemp)"
  if retry curl -fsSL "$SETUP_REPO_RAW/mediamtx.yml" -o "$tmp"; then
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    sed -i -e "s~OTS_FOLDER~$DATA_DIR~g" \
           -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
           -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
           -e "s~^webrtcAdditionalHosts: \[\]~webrtcAdditionalHosts: [${RAVEN_DOMAIN:-$host_ip}]~" "$tmp"
    as_root install -o "$APP_USER" -g "$APP_USER" -m 644 "$tmp" "$MTX_DIR/mediamtx.yml"
    fixed "wrote mediamtx.yml"
  else
    warn "could not fetch mediamtx.yml from $SETUP_REPO_RAW"
  fi
  rm -f "$tmp"
fi
if as_root grep -qs MTX_TOKEN "$MTX_DIR/mediamtx.yml"; then
  tok="$(config_get "$PY" "$CFG" "$APP_USER" RAVEN_MEDIAMTX_TOKEN)"
  if [[ -n "$tok" ]]; then
    as_root sed -i "s~MTX_TOKEN~$tok~g" "$MTX_DIR/mediamtx.yml"
    fixed "filled in MediaMTX's webhook token"
  else
    warn "config.yml has no RAVEN_MEDIAMTX_TOKEN; mediamtx.yml still has the placeholder"
  fi
fi
if ! as_root test -f /etc/systemd/system/mediamtx.service; then
  as_root tee /etc/systemd/system/mediamtx.service >/dev/null <<EOF
[Unit]
Wants=network.target
After=network.target
[Service]
User=$APP_USER
ExecStart=$MTX_DIR/mediamtx $MTX_DIR/mediamtx.yml
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
  fixed "wrote mediamtx.service"
fi
ok "MediaMTX checked"

# ---- 5. nginx ---------------------------------------------------------------------------
log "nginx"
as_root mkdir -p "$NGINX_SITES_DIR" "$NGINX_STREAMS_DIR"
[[ -n "$NGINX_SITES_ENABLED_DIR" ]] && as_root mkdir -p "$NGINX_SITES_ENABLED_DIR"
[[ -n "$NGINX_STREAMS_ENABLED_DIR" ]] && as_root mkdir -p "$NGINX_STREAMS_ENABLED_DIR"
NGINX_CHANGED=0
if ! as_root grep -q "stream {" "$NGINX_CONF"; then
  if [[ -n "$NGINX_STREAMS_ENABLED_DIR" ]]; then inc="$NGINX_STREAMS_ENABLED_DIR/*"; else inc="$NGINX_STREAMS_DIR/*$NGINX_CONF_SUFFIX"; fi
  printf '\nstream {\n        include %s;\n}\n' "$inc" | as_root tee -a "$NGINX_CONF" >/dev/null
  NGINX_CHANGED=1; fixed "added the stream {} block to $NGINX_CONF"
fi
if ! as_root test -f /etc/nginx/proxy_params; then
  fetch rpm/proxy_params /etc/nginx/proxy_params && { NGINX_CHANGED=1; fixed "added /etc/nginx/proxy_params"; }
fi
subst_certs() {
  as_root sed -i -e "s~SERVER_CERT_FILE~$DATA_DIR/ca/certs/raven/raven.pem~g" \
                 -e "s~SERVER_KEY_FILE~$DATA_DIR/ca/certs/raven/raven.nopass.key~g" \
                 -e "s~CA_CERT_FILE~$DATA_DIR/ca/ca.pem~g" "$1"
}
for s in raven_http raven_https raven_certificate_enrollment; do
  f="$(nginx_site_file "$s")"
  if ! as_root test -f "$f"; then
    fetch "nginx_configs/$s" "$f" && subst_certs "$f" && { NGINX_CHANGED=1; fixed "restored nginx site $s"; }
  fi
  if [[ -n "$NGINX_SITES_ENABLED_DIR" ]] && ! as_root test -e "$NGINX_SITES_ENABLED_DIR/$s"; then
    as_root ln -sf "$f" "$NGINX_SITES_ENABLED_DIR/"; NGINX_CHANGED=1; fixed "enabled nginx site $s"
  fi
done
for s in rabbitmq mediamtx; do
  f="$(nginx_stream_file "$s")"
  if ! as_root test -f "$f"; then
    fetch "nginx_configs/$s" "$f" && subst_certs "$f" && { NGINX_CHANGED=1; fixed "restored nginx stream $s"; }
  fi
  if [[ -n "$NGINX_STREAMS_ENABLED_DIR" ]] && ! as_root test -e "$NGINX_STREAMS_ENABLED_DIR/$s"; then
    as_root ln -sf "$f" "$NGINX_STREAMS_ENABLED_DIR/"; NGINX_CHANGED=1; fixed "enabled nginx stream $s"
  fi
done
# Debian's welcome page would answer port 80 instead of raven_http.
[[ -n "$NGINX_SITES_ENABLED_DIR" ]] && as_root test -e "$NGINX_SITES_ENABLED_DIR/default" \
  && { as_root rm -f "$NGINX_SITES_ENABLED_DIR/default"; NGINX_CHANGED=1; fixed "disabled the distro's default nginx site"; }
if [[ "$DISTRO_FAMILY" == rhel ]] && command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != Disabled ]]; then
  as_root setsebool -P httpd_can_network_connect 1 2>/dev/null || true
fi
nginx_harden || true
if as_root nginx -t >/dev/null 2>&1; then
  if [[ "$HAS_SYSTEMD" == 1 ]]; then
    as_root systemctl enable nginx >/dev/null 2>&1 || true
    if ! unit_active nginx; then as_root systemctl restart nginx && fixed "started nginx"
    elif [[ "$NGINX_CHANGED" == 1 ]]; then as_root systemctl reload nginx; fi
  elif [[ "$NGINX_CHANGED" == 1 ]]; then
    nginx_reload
  fi
  ok "nginx configuration valid"
else
  as_root nginx -t || true
  warn "nginx -t fails (above). The web UI won't load until that is fixed."
fi

# ---- 6. web UI ---------------------------------------------------------------------------
log "Web UI"
if ! as_root test -f "$WEBROOT/index.html" || [[ "${REBUILD_UI:-0}" == 1 ]]; then
  if [[ "$BACKEND" == offline ]]; then
    warn "$WEBROOT/index.html missing on an offline package install: reinstall the bundle (it ships the built UI)"
  else
    if ! as_root test -d "$APP_HOME/c4raven-ui/.git"; then
      as_root rm -rf "$APP_HOME/c4raven-ui"
      retry as_app git clone "$UI_REPO" "$APP_HOME/c4raven-ui" || die "Could not clone $UI_REPO (network?)."
    else
      as_app_sh "cd $APP_HOME/c4raven-ui && git checkout -- src/_versions.ts yarn.lock 2>/dev/null; true"
      retry as_app_sh "cd $APP_HOME/c4raven-ui && git pull --ff-only origin main" || warn "could not update c4raven-ui; building what is checked out"
    fi
    COREPACK="$(command -v corepack || true)"
    [[ -n "$COREPACK" ]] || die "corepack not found (Node 22 from NodeSource ships it). Re-run install.sh, or: sudo npm install -g corepack"
    retry as_app_sh "cd $APP_HOME/c4raven-ui && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $(q "$COREPACK") yarn install --immutable" || die "yarn install failed (output above)."
    if ! as_app_sh "cd $APP_HOME/c4raven-ui && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 $(q "$COREPACK") yarn build"; then
      free -h 2>/dev/null || true
      die "The UI build failed (output above). If it was killed, the machine is short of memory: add 2 GB of swap and re-run."
    fi
    as_app git -C "$APP_HOME/c4raven-ui" checkout -- src/_versions.ts 2>/dev/null || true
    as_root install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"
    as_root rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$APP_HOME/c4raven-ui/dist/" "$WEBROOT/"
    as_root chown -R "$APP_USER:$APP_USER" "$WEBROOT"
    if command -v restorecon >/dev/null 2>&1; then as_root restorecon -R "$WEBROOT" || warn "restorecon failed on $WEBROOT"; fi
    as_app_sh "git -C $APP_HOME/c4raven-ui rev-parse --short HEAD > $(q "$DATA_DIR/.ui-deployed-commit")" || true
    fixed "built and deployed the web UI to $WEBROOT"
  fi
else
  ok "web UI deployed ($WEBROOT/index.html; REBUILD_UI=1 to rebuild)"
fi

# ---- 7. RabbitMQ ---------------------------------------------------------------------------
# The plugins must be enabled BEFORE rabbitmq.conf names their settings:
# RabbitMQ refuses to start on settings it has no schema for.
log "RabbitMQ"
# Find the directory holding the broker's bundled plugins (rabbitmq_mqtt and
# rabbitmq_auth_backend_http ship with rabbitmq-server) and hand it to
# rabbitmq-plugins explicitly as RABBITMQ_PLUGINS_DIR, which wins over
# anything in rabbitmq-env.conf. Earlier installers pinned PLUGINS_DIR there
# to rabbitmq_server-<ver>/plugins with <ver> taken from rabbitmqadmin, which
# need not match the broker and is removed by the next rabbitmq-server
# upgrade either way; rabbitmq-plugins then dies with
# plugins_dir_does_not_exist. Those lines, and any plugin-dir line naming no
# directory that exists, are dropped: the package derives the right one.
rabbit_pkg_version() {
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W rabbitmq-server >/dev/null 2>&1; then
    dpkg-query -W -f='${Version}' rabbitmq-server 2>/dev/null || true
  else
    rpm -q --qf '%{VERSION}' rabbitmq-server 2>/dev/null || true
  fi
}
rabbit_plugins_dir() {
  local v d
  v=$(rabbit_pkg_version); v=${v#*:}; v=${v%%-*}; v=${v%%~*}
  for d in "/usr/lib/rabbitmq/lib/rabbitmq_server-$v/plugins" \
           $(ls -d /usr/lib/rabbitmq/lib/rabbitmq_server-*/plugins 2>/dev/null | sort -rV); do
    if compgen -G "$d/rabbitmq_mqtt-*" >/dev/null && compgen -G "$d/rabbitmq_auth_backend_http-*" >/dev/null; then
      printf '%s' "$d"; return 0
    fi
  done
  return 0
}
rabbit_diagnostics() {
  echo "--- RabbitMQ diagnostics ---" >&2
  echo "package version: $(rabbit_pkg_version)" >&2
  ls -la /usr/lib/rabbitmq/lib/ >&2 2>&1 || true
  echo "plugin-dir settings in /etc/rabbitmq/rabbitmq-env.conf:" >&2
  as_root grep -nE '^[[:space:]]*(export[[:space:]]+)?(RABBITMQ_)?PLUGINS_DIR=' /etc/rabbitmq/rabbitmq-env.conf >&2 2>&1 || echo "  (none)" >&2
  env | grep -E '^(RABBITMQ_)?PLUGINS_DIR=' >&2 || true
  echo "----------------------------" >&2
}
RABBIT_ENV=/etc/rabbitmq/rabbitmq-env.conf
if as_root test -f "$RABBIT_ENV"; then
  rabbit_env_new=$(mktemp)
  rabbit_env_dropped=0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(RABBITMQ_)?PLUGINS_DIR=(.*)$ ]]; then
      val=${BASH_REMATCH[3]}; val=${val//\"/}; val=${val//\'/}
      drop=1
      case "$val" in
        */usr/lib/rabbitmq/lib/rabbitmq_server-*) ;;
        *) IFS=: read -ra parts <<< "$val"
           for p in "${parts[@]}"; do if [ -n "$p" ] && [ -d "$p" ]; then drop=0; fi; done ;;
      esac
      if [ "$drop" = 1 ]; then
        echo "dropping from $RABBIT_ENV: $line"
        rabbit_env_dropped=1
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$rabbit_env_new"
  done < <(as_root cat "$RABBIT_ENV")
  if [ "$rabbit_env_dropped" = 1 ]; then
    as_root cp -p "$RABBIT_ENV" "$RABBIT_ENV.bak-$(date +%Y%m%d%H%M%S)"
    as_root cp "$rabbit_env_new" "$RABBIT_ENV"
    fixed "removed a stale plugin-directory setting from $RABBIT_ENV (backup kept next to it)"
  fi
  rm -f "$rabbit_env_new"
fi
unset PLUGINS_DIR RABBITMQ_PLUGINS_DIR
RABBIT_PLUGINS_DIR=$(rabbit_plugins_dir)
if [ -z "$RABBIT_PLUGINS_DIR" ]; then
  warn "RabbitMQ's plugin files are missing; reinstalling rabbitmq-server"
  if [ "$PKG_MGR" = apt ]; then
    retry as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --reinstall rabbitmq-server || true
  else
    retry as_root dnf reinstall -y -q rabbitmq-server || true
  fi
  RABBIT_PLUGINS_DIR=$(rabbit_plugins_dir)
  if [ -n "$RABBIT_PLUGINS_DIR" ]; then fixed "reinstalled rabbitmq-server (its plugin files were missing)"; fi
fi
if [ -z "$RABBIT_PLUGINS_DIR" ]; then
  rabbit_diagnostics
  die "RabbitMQ's plugin files are missing: no /usr/lib/rabbitmq/lib/rabbitmq_server-*/plugins holds rabbitmq_mqtt. Reinstall it (sudo apt-get install --reinstall rabbitmq-server, or dnf reinstall rabbitmq-server) and re-run."
fi
if ! as_root env RABBITMQ_PLUGINS_DIR="$RABBIT_PLUGINS_DIR" rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_auth_backend_http; then
  rabbit_diagnostics
  die "rabbitmq-plugins could not enable rabbitmq_mqtt / rabbitmq_auth_backend_http (output and diagnostics above)."
fi
want="$(mktemp)"
cat > "$want" <<'EOF'
mqtt.listeners.tcp.default = 1883

auth_backends.1 = internal
auth_backends.2 = http
auth_http.http_method   = post
auth_http.user_path     = http://127.0.0.1:8081/api/rabbitmq/auth
auth_http.vhost_path    = http://127.0.0.1:8081/api/rabbitmq/vhost
auth_http.resource_path = http://127.0.0.1:8081/api/rabbitmq/resource
auth_http.topic_path    = http://127.0.0.1:8081/api/rabbitmq/topic
EOF
# RabbitMQ 4.x refuses the transient non-exclusive queues the services
# declare unless re-permitted; 3.x refuses to start on that key.
if command -v dpkg-query >/dev/null 2>&1; then
  RABBIT_PKG_VERSION=$(dpkg-query -W -f='${Version}' rabbitmq-server 2>/dev/null || true)
else
  RABBIT_PKG_VERSION=$(rpm -q --qf '%{VERSION}' rabbitmq-server 2>/dev/null || true)
fi
RABBIT_MAJOR=$(printf '%s' "${RABBIT_PKG_VERSION#*:}" | cut -d. -f1)
case "$RABBIT_MAJOR" in ''|*[!0-9]*) RABBIT_MAJOR=0 ;; esac
[[ "$RABBIT_MAJOR" -ge 4 ]] && echo "deprecated_features.permit.transient_nonexcl_queues = true" >> "$want"
RABBIT_RESTART=0
# Rewrite only when a setting Raven needs is absent, so an admin's own
# additions to rabbitmq.conf survive.
need_conf=0
for k in mqtt.listeners.tcp.default auth_backends.2 auth_http.user_path auth_http.topic_path; do
  as_root grep -qs "^$k" /etc/rabbitmq/rabbitmq.conf || need_conf=1
done
[[ "$RABBIT_MAJOR" -ge 4 ]] && ! as_root grep -qs '^deprecated_features.permit.transient_nonexcl_queues' /etc/rabbitmq/rabbitmq.conf && need_conf=1
if [[ "$need_conf" == 1 ]]; then
  as_root test -f /etc/rabbitmq/rabbitmq.conf && as_root cp -a /etc/rabbitmq/rabbitmq.conf "/etc/rabbitmq/rabbitmq.conf.bak-$(date +%Y%m%d-%H%M%S)"
  as_root mkdir -p /etc/rabbitmq
  as_root install -m 644 "$want" /etc/rabbitmq/rabbitmq.conf
  RABBIT_RESTART=1; fixed "wrote /etc/rabbitmq/rabbitmq.conf"
fi
rm -f "$want"
if [[ "$HAS_SYSTEMD" == 1 ]]; then
  as_root systemctl enable "$RABBIT_SERVICE" >/dev/null 2>&1 || true
  if [[ "$RABBIT_RESTART" == 1 ]] || ! unit_active "$RABBIT_SERVICE"; then
    if ! as_root systemctl restart "$RABBIT_SERVICE"; then
      as_root journalctl -u "$RABBIT_SERVICE" -n 40 --no-pager || true
      die "RabbitMQ would not start (log above)."
    fi
    for i in $(seq 1 30); do
      as_root rabbitmq-diagnostics -q check_port_connectivity >/dev/null 2>&1 && break
      [[ "$i" -eq 30 ]] && { as_root journalctl -u "$RABBIT_SERVICE" -n 40 --no-pager || true; die "RabbitMQ started but isn't accepting connections (log above)."; }
      sleep 2
    done
    fixed "(re)started RabbitMQ"
  fi
elif [[ "$RABBIT_RESTART" == 1 ]]; then
  MANUAL_RESTARTS+=("$RABBIT_SERVICE")
fi
ok "RabbitMQ has MQTT and HTTP auth configured"

# ---- 8. secrets file -------------------------------------------------------------------------
log "Secrets file"
SECRETS="$APP_HOME/.raven-secrets.env"
if ! as_root test -f "$SECRETS"; then
  as_root tee "$SECRETS" >/dev/null <<EOF
RAVEN_DATA_FOLDER=$DATA_DIR
SQLALCHEMY_DATABASE_URI=$URI
RAVEN_RABBITMQ_USERNAME=guest
RAVEN_RABBITMQ_PASSWORD=guest
RAVEN_FEDHUB_ENABLE=False
RAVEN_MEDIAMTX_ENABLE=True
EOF
  fixed "wrote $SECRETS"
elif ! as_root grep -qxF "SQLALCHEMY_DATABASE_URI=$URI" "$SECRETS"; then
  # The env file wins over nothing (config.yml is loaded after it), but keep
  # the two from disagreeing.
  as_root sed -i "s~^SQLALCHEMY_DATABASE_URI=.*~SQLALCHEMY_DATABASE_URI=$URI~" "$SECRETS"
  as_root grep -q '^SQLALCHEMY_DATABASE_URI=' "$SECRETS" || echo "SQLALCHEMY_DATABASE_URI=$URI" | as_root tee -a "$SECRETS" >/dev/null
  fixed "brought the database URI in $SECRETS in line with config.yml"
else
  ok "present and consistent with config.yml"
fi
as_root chown "$APP_USER:$APP_USER" "$SECRETS"
as_root chmod 600 "$SECRETS"

# ---- 9. systemd units -------------------------------------------------------------------------
log "Raven services"
if [[ "$BACKEND" == source ]]; then BIN_DIR="$APP_HOME/c4raven-server/.venv/bin"; else BIN_DIR="$APP_HOME/venv/bin"; fi
UNITS_CHANGED=0
write_unit() {  # write_unit NAME  (content on stdin), only if it doesn't exist
  local tmp; tmp="$(mktemp)"; cat > "$tmp"
  # An existing unit anywhere (install.sh's in /etc, the .deb/.rpm's in
  # /lib or /usr/lib, or an admin's edit) is kept as it is: only fill in
  # what's missing, and never shadow a packaged unit with an /etc copy.
  if ! unit_exists "$1.service"; then
    as_root install -m 644 "$tmp" "/etc/systemd/system/$1.service"
    UNITS_CHANGED=1; fixed "wrote $1.service"
  fi
  rm -f "$tmp"
}
write_unit raven <<EOF
[Unit]
Wants=network.target $RABBIT_SERVICE.service $PG_SERVICE.service
After=network.target $RABBIT_SERVICE.service $PG_SERVICE.service
Requires=eud_handler.service eud_handler_ssl.service cot_parser.service
[Service]
User=$APP_USER
WorkingDirectory=$WORKDIR
EnvironmentFile=$SECRETS
ExecStart=$BIN_DIR/raven
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
for s in cot_parser eud_handler eud_handler_ssl; do
  extra=""; [[ "$s" == eud_handler_ssl ]] && extra=" --ssl"
  write_unit "$s" <<EOF
[Unit]
Wants=network.target $RABBIT_SERVICE.service
After=network.target $RABBIT_SERVICE.service
PartOf=raven.service
[Service]
User=$APP_USER
WorkingDirectory=$WORKDIR
EnvironmentFile=$SECRETS
ExecStart=$BIN_DIR/${s%_ssl}$extra
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
done
fix_log_ownership "$APP_USER" "$DATA_DIR/logs" raven.log || true
SERVICES="mediamtx raven cot_parser eud_handler eud_handler_ssl"
if [[ "$HAS_SYSTEMD" == 1 ]]; then
  as_root systemctl daemon-reload
  for s in $SERVICES; do
    systemctl is-enabled --quiet "$s" 2>/dev/null || { as_root systemctl enable "$s" >/dev/null 2>&1 && fixed "enabled $s"; }
  done
  not_running=""
  for s in $SERVICES; do unit_active "$s" || not_running="$not_running $s"; done
  if [[ "$UNITS_CHANGED" == 1 || -n "$not_running" ]]; then
    # shellcheck disable=SC2086
    as_root systemctl restart $SERVICES || true
    fixed "started:${not_running:- $SERVICES}"
  else
    ok "all Raven services enabled and running"
  fi
else
  # shellcheck disable=SC2206
  MANUAL_RESTARTS+=($SERVICES)
fi

# ---- 10. wait for the backend --------------------------------------------------------------------
BACKEND_UP=0
if [[ "$HAS_SYSTEMD" == 1 ]] || curl -s -o /dev/null --max-time 3 http://127.0.0.1:8081/api/health; then
  log "Waiting for the backend on 127.0.0.1:8081"
  if wait_healthy http://127.0.0.1:8081/api/health 90; then
    BACKEND_UP=1; ok "backend answering"
  else
    for s in $SERVICES; do printf '    %-16s %s\n' "$s" "$(unit_state "$s")"; done
    as_root tail -n 60 "$DATA_DIR/logs/raven.log" 2>/dev/null | grep -v after_fork || true
    warn "the backend didn't answer on 127.0.0.1:8081 within 3 minutes (status and log above)"
  fi
fi

# ---- 11. first administrator -------------------------------------------------------------------------
if [[ "$BACKEND_UP" == 1 ]]; then
  log "First administrator account"
  seed="$(mktemp)"
  if retry curl -fsSL "$SETUP_REPO_RAW/seed_admin.py" -o "$seed"; then
    as_root install -o "$APP_USER" -g "$APP_USER" -m 644 "$seed" "$APP_HOME/seed_admin.py"
    rc=0
    as_app_sh "cd $(q "$WORKDIR") && RAVEN_DATA_FOLDER=$(q "$DATA_DIR") $(q "$PY") $(q "$APP_HOME/seed_admin.py")" || rc=$?
    case "$rc" in
      0) fixed "administrator account ready (must set a new password at first login)" ;;
      3) ok "accounts already exist; left untouched" ;;
      *) warn "seed_admin.py exited $rc" ;;
    esac
  else
    warn "could not fetch seed_admin.py from $SETUP_REPO_RAW"
  fi
  rm -f "$seed"

  log "Testing a login as administrator"
  RESULT=$(python3 - <<'EOF'
import http.cookiejar, json, urllib.request, urllib.error
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
H = {"Accept": "application/json", "Content-Type": "application/json"}
base = "http://127.0.0.1:8081"
def call(m, p, b=None):
    try:
        r = op.open(urllib.request.Request(base + p, data=b, headers=H, method=m), timeout=15)
        return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"{}")
        except Exception: return e.code, {}
s, d = call("GET", "/api/login")
tok = d.get("response", {}).get("csrf_token", "")
s, d = call("POST", "/api/login", json.dumps({"username": "administrator", "password": "password", "csrf_token": tok}).encode())
r = d.get("response", {})
if s == 200:
    print("ok" + (" (must set a new password first)" if r.get("force_password_change") else ""))
else:
    print(f"failed ({s}): {r.get('errors') or r.get('field_errors') or d}")
EOF
) || RESULT="could not run the login test"
  case "$RESULT" in
    ok*) ok "administrator / password logs in $RESULT" ;;
    *)   echo "    administrator / password: $RESULT"
         echo "    (expected if the password was already changed; log in with the new one)" ;;
  esac
fi

# ---- 12. Federation Hub --------------------------------------------------------------------------
# Offered (or reconnected) last, once Raven itself is up; never fails this script.
export RAVEN_USER="$APP_USER" RAVEN_HOME="$APP_HOME" RAVEN_DATA_DIR="$DATA_DIR" RAVEN_VENV="$VENV"
fedhub_section raven

echo
echo "finish-install.sh done."
print_summary
cat <<EOF

Open https://<your domain or this server's IP> and log in as 'administrator'
(password 'password' unless it has been changed), then set a real password.
EOF
[[ "$BACKEND_UP" == 1 || "$HAS_SYSTEMD" == 0 ]]
