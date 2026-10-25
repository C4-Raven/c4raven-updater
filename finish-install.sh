#!/usr/bin/env bash
# Finishes a C4 Raven install that c4raven-server-setup's install.sh left
# half done -- the symptom is "Unit raven.service not found" and a web UI
# nobody can log in to, because the backend was never started.
#
#   ./finish-install.sh
#
# install.sh stops at the first failing command, and everything after the
# UI build (RabbitMQ setup, the secrets file, the raven / eud_handler /
# cot_parser units, starting them) is skipped. This redoes exactly those
# steps, idempotently, checking each one and printing the real error if it
# fails. It never touches the database contents, config.yml, certificates,
# or nginx.
#
# Run it as your own sudo-capable user (not root, not `raven`).
set -euo pipefail

APP_USER="${RAVEN_USER:-raven}"
APP_HOME="${RAVEN_HOME:-/opt/raven}"
DATA_DIR="$APP_HOME/data"
WEBROOT="${UI_DEPLOY_DIR:-/var/www/html/raven}"

step() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
ok() { printf '\033[1;32m    ok:\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  warn:\033[0m %s\n' "$1" >&2; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }
as_app() { sudo -u "$APP_USER" -H bash -lc "cd / && $1"; }

[ "$(id -u)" != 0 ] || die "Run this as your own sudo-capable user, not root."
sudo test -d "$APP_HOME/c4raven-server/.venv" \
  || die "$APP_HOME/c4raven-server/.venv not found: install.sh didn't get as far as the backend. Re-run install.sh instead."
sudo test -f "$DATA_DIR/config.yml" || die "$DATA_DIR/config.yml not found. Re-run install.sh instead."

# ---- 1. UI ------------------------------------------------------------------
step "Building and deploying the web UI"
if ! sudo test -f "$WEBROOT/index.html" || [ "${REBUILD_UI:-0}" = 1 ]; then
  as_app "cd '$APP_HOME/c4raven-ui' && git checkout -- src/_versions.ts yarn.lock 2>/dev/null; git pull --ff-only origin main" \
    || die "Could not update $APP_HOME/c4raven-ui from GitHub."
  # COREPACK_ENABLE_DOWNLOAD_PROMPT=0: never stop to ask before fetching the
  # pinned yarn. The build (tsc + vite) needs roughly 2 GB of memory.
  if ! as_app "cd '$APP_HOME/c4raven-ui' && export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 && corepack yarn install --immutable && corepack yarn build"; then
    free -h
    die "The UI build failed (output above). If it was killed, the machine is short of memory: add swap (sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile) and re-run."
  fi
  sudo install -d -o "$APP_USER" -g "$APP_USER" -m 755 "$WEBROOT"
  sudo rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete "$APP_HOME/c4raven-ui/dist/" "$WEBROOT/"
  sudo chown -R "$APP_USER:$APP_USER" "$WEBROOT"
  # Relabel for SELinux (Rocky/RHEL, enforcing by default) -- an unlabelled
  # webroot makes nginx 403 every asset. No-op where restorecon doesn't
  # exist (Debian/Ubuntu).
  #
  # The `|| true` is load-bearing under `set -e`: a failing *last* member of
  # an && list does abort the script (only earlier members are exempt), so
  # without it a restorecon that exists but errors would kill this script
  # here -- right after the UI deploy and before RabbitMQ, the secrets file
  # and the systemd units, i.e. leaving exactly the half-finished install
  # this script exists to repair. stderr is deliberately NOT swallowed: a
  # relabel that really failed should say so.
  if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -R "$WEBROOT" || warn "restorecon failed on $WEBROOT -- if nginx 403s the UI, relabel it by hand."
  fi
  ok "UI deployed to $WEBROOT"
else
  ok "already deployed ($WEBROOT/index.html exists; REBUILD_UI=1 to rebuild)"
fi

# ---- 2. RabbitMQ ------------------------------------------------------------
# The plugins have to be enabled BEFORE rabbitmq.conf mentions their settings
# (mqtt.*, auth_http.*): RabbitMQ refuses to start on settings it has no
# schema for, and install.sh restarted it with the config first.
step "Configuring RabbitMQ"
sudo rabbitmq-plugins enable --offline rabbitmq_mqtt rabbitmq_auth_backend_http >/dev/null \
  || die "rabbitmq-plugins could not enable rabbitmq_mqtt / rabbitmq_auth_backend_http (output above)."
sudo tee /etc/rabbitmq/rabbitmq.conf >/dev/null << 'EOF'
mqtt.listeners.tcp.default = 1883

auth_backends.1 = internal
auth_backends.2 = http
auth_http.http_method   = post
auth_http.user_path     = http://127.0.0.1:8081/api/rabbitmq/auth
auth_http.vhost_path    = http://127.0.0.1:8081/api/rabbitmq/vhost
auth_http.resource_path = http://127.0.0.1:8081/api/rabbitmq/resource
auth_http.topic_path    = http://127.0.0.1:8081/api/rabbitmq/topic
EOF
if ! sudo systemctl restart rabbitmq-server; then
  sudo journalctl -u rabbitmq-server -n 40 --no-pager
  die "RabbitMQ would not start (log above)."
fi
for i in $(seq 1 30); do
  sudo rabbitmq-diagnostics -q check_port_connectivity >/dev/null 2>&1 && break
  [ "$i" -eq 30 ] && { sudo journalctl -u rabbitmq-server -n 40 --no-pager; die "RabbitMQ started but isn't accepting connections (log above)."; }
  sleep 2
done
ok "RabbitMQ running with MQTT and HTTP auth"

# ---- 3. secrets file --------------------------------------------------------
step "Writing $APP_HOME/.raven-secrets.env"
if sudo test -f "$APP_HOME/.raven-secrets.env"; then
  ok "already exists, left as is"
else
  # The venv's interpreter, not the system python3: PyYAML is a dependency of
  # the backend and is installed into that venv. On Rocky/RHEL /usr/bin/python3
  # is 3.9 and the EL stack ships python3.12-pyyaml (not python3-pyyaml), so a
  # bare `python3 -c "import yaml"` dies with ModuleNotFoundError there. The
  # guard at the top of this script has already proved the venv exists.
  DB_URI=$(as_app "'$APP_HOME/c4raven-server/.venv/bin/python' -c \"import yaml; print(yaml.safe_load(open('$DATA_DIR/config.yml'))['SQLALCHEMY_DATABASE_URI'])\"")
  case "$DB_URI" in
    postgresql*) ;;
    *) die "config.yml has no PostgreSQL SQLALCHEMY_DATABASE_URI (got '${DB_URI%%:*}...'): install.sh stopped before the database step. Re-run install.sh instead." ;;
  esac
  sudo tee "$APP_HOME/.raven-secrets.env" >/dev/null << EOF
RAVEN_DATA_FOLDER=$DATA_DIR
SQLALCHEMY_DATABASE_URI=$DB_URI
RAVEN_RABBITMQ_USERNAME=guest
RAVEN_RABBITMQ_PASSWORD=guest
RAVEN_FEDHUB_ENABLE=False
RAVEN_MEDIAMTX_ENABLE=True
EOF
  sudo chown "$APP_USER:$APP_USER" "$APP_HOME/.raven-secrets.env"
  sudo chmod 600 "$APP_HOME/.raven-secrets.env"
  ok "written"
fi

# ---- 4. systemd units (same as install.sh writes) ---------------------------
step "Installing the raven, eud_handler, eud_handler_ssl and cot_parser services"
sudo tee /etc/systemd/system/raven.service >/dev/null << EOF
[Unit]
Wants=network.target rabbitmq-server.service postgresql.service
After=network.target rabbitmq-server.service postgresql.service
Requires=eud_handler.service eud_handler_ssl.service cot_parser.service
[Service]
User=$APP_USER
WorkingDirectory=$APP_HOME/c4raven-server
EnvironmentFile=$APP_HOME/.raven-secrets.env
ExecStart=$APP_HOME/c4raven-server/.venv/bin/raven
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
for svc in cot_parser eud_handler eud_handler_ssl; do
  EXTRA_ARGS=""
  [ "$svc" = "eud_handler_ssl" ] && EXTRA_ARGS=" --ssl"
  BIN="${svc%_ssl}"
  sudo tee "/etc/systemd/system/${svc}.service" >/dev/null << EOF
[Unit]
Wants=network.target rabbitmq-server.service
After=network.target rabbitmq-server.service
PartOf=raven.service
[Service]
User=$APP_USER
WorkingDirectory=$APP_HOME/c4raven-server
EnvironmentFile=$APP_HOME/.raven-secrets.env
ExecStart=$APP_HOME/c4raven-server/.venv/bin/${BIN}${EXTRA_ARGS}
Restart=always
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
done
as_app "mkdir -p '$DATA_DIR/logs'"
sudo systemctl daemon-reload
sudo systemctl enable mediamtx raven cot_parser eud_handler eud_handler_ssl >/dev/null 2>&1
ok "installed and enabled"

# ---- 5. start and wait ------------------------------------------------------
step "Starting the services"
sudo systemctl restart mediamtx raven cot_parser eud_handler eud_handler_ssl || true
echo "    waiting for the backend (the first start creates the database tables)..."
for i in $(seq 1 90); do
  curl -fsS -o /dev/null http://127.0.0.1:8081/api/health 2>/dev/null && break
  if [ "$i" -eq 90 ]; then
    for s in raven cot_parser eud_handler eud_handler_ssl mediamtx; do printf '    %-16s %s\n' "$s" "$(systemctl is-active $s)"; done
    sudo tail -n 60 "$DATA_DIR/logs/raven.log" 2>/dev/null | grep -v after_fork
    die "The backend didn't answer on 127.0.0.1:8081 after 3 minutes (status and log above)."
  fi
  sleep 2
done
ok "backend answering on 127.0.0.1:8081"
for s in raven cot_parser eud_handler eud_handler_ssl mediamtx nginx rabbitmq-server postgresql; do
  printf '    %-16s %s\n' "$s" "$(systemctl is-active $s)"
done

# ---- 6. prove a login works --------------------------------------------------
step "Testing a login as administrator"
RESULT=$(python3 - << 'EOF'
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
)
case "$RESULT" in
  ok*) ok "administrator / password logs in $RESULT" ;;
  *)   echo "    administrator / password: $RESULT"
       echo "    (expected if the password was already changed; log in with the new one)" ;;
esac

cat << EOF

Done. Open https://<your domain or this server's IP> and log in as
'administrator' (password 'password' unless it has been changed). Set a real
password straight away under your account settings.
EOF
