#!/usr/bin/env bash
# C4 Raven updater -- deploys the latest c4raven-server (backend) and
# c4raven-ui (frontend) in place, without touching the database contents,
# uploaded files, certificates, or config.yml.
#
# Both are our own git forks now (not a pip package + patch file), so
# "update" means: pull our fork's latest commits and redeploy. It does
# NOT pull in new upstream OpenTAKServer changes -- that's a separate,
# deliberate maintenance step (see "Pulling in upstream changes" in
# README.md) done by a maintainer in a dev checkout, tested, and pushed
# to our fork first. This script only ever fast-forwards to what's
# already on our own origin/main.
#
# It updates either server layout (detected automatically, see below):
# the legacy single-user one, and the `raven`-user one that
# c4raven-server-setup's install.sh creates.
#
# What this does NOT do, ever:
#   - drop, recreate, or truncate the database (only additive Alembic
#     migrations run, via the app's own normal startup path)
#   - delete anything under $RAVEN_DATA_DIR (certs, config.yml, uploads,
#     icons.sqlite, mediamtx config)
#   - touch $RAVEN_DATA_DIR/logs
#   - merge or rebase over local changes in either source checkout
#
# It DOES back up the database and $RAVEN_DATA_DIR before making any
# change, so a bad update can be rolled back. See README.md for rollback
# steps.

set -euo pipefail

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$1"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

# ---- layout ---------------------------------------------------------------------
#   legacy  one login user owns everything: backend venv ~/.opentakserver_venv,
#           data ~/ots, source in ~/src, UI in /var/www/html/opentakserver,
#           opentakserver.service
#   raven   c4raven-server-setup's install.sh (or its online .deb): a `raven`
#           system user owns /opt/raven/{c4raven-server,c4raven-ui,data}
#           (mode 750), UI in /var/www/html/raven, raven.service
#
# LAYOUT=auto picks legacy when ~/.opentakserver_venv exists, otherwise raven
# when /opt/raven/c4raven-server is a git checkout. An install from the
# OFFLINE .deb has no source checkout to pull (just /opt/raven/venv); it is
# updated by running install.sh from a newer offline bundle, so it's refused.
LAYOUT="${LAYOUT:-auto}"
RAVEN_HOME="${RAVEN_HOME:-/opt/raven}"
RAVEN_USER="${RAVEN_USER:-raven}"

if [[ "$LAYOUT" == auto ]]; then
    if [[ -d "$HOME/.opentakserver_venv" ]]; then
        LAYOUT=legacy
    elif sudo test -d "$RAVEN_HOME/c4raven-server/.git"; then
        LAYOUT=raven
    elif sudo test -L "$RAVEN_HOME/venv"; then
        die "This server was installed from the offline package ($RAVEN_HOME/venv, no source checkout). Update it by running install.sh from a newer c4raven-server-offline bundle."
    else
        die "No C4 Raven install found (looked for ~/.opentakserver_venv and $RAVEN_HOME/c4raven-server). If yours lives elsewhere, set LAYOUT=legacy or LAYOUT=raven plus the paths in README.md."
    fi
fi

# ---- configuration (override via environment) ------------------------------
case "$LAYOUT" in
    legacy)
        RAVEN_VENV="${RAVEN_VENV:-$HOME/.opentakserver_venv}"
        RAVEN_DATA_DIR="${RAVEN_DATA_DIR:-$HOME/ots}"
        RAVEN_SERVICES="${RAVEN_SERVICES:-opentakserver.service eud_handler.service eud_handler_ssl.service cot_parser.service}"
        SERVER_SRC_DIR="${SERVER_SRC_DIR:-$HOME/src/c4raven-server}"
        UI_SRC_DIR="${UI_SRC_DIR:-$HOME/src/c4raven-ui}"
        UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/opentakserver}"
        HEALTH_URL="${HEALTH_URL:-https://127.0.0.1/api/health}"
        ;;
    raven)
        RAVEN_VENV="${RAVEN_VENV:-$RAVEN_HOME/c4raven-server/.venv}"
        RAVEN_DATA_DIR="${RAVEN_DATA_DIR:-$RAVEN_HOME/data}"
        RAVEN_SERVICES="${RAVEN_SERVICES:-raven.service eud_handler.service eud_handler_ssl.service cot_parser.service mediamtx.service}"
        SERVER_SRC_DIR="${SERVER_SRC_DIR:-$RAVEN_HOME/c4raven-server}"
        UI_SRC_DIR="${UI_SRC_DIR:-$RAVEN_HOME/c4raven-ui}"
        UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/raven}"
        # Straight to the backend: nginx on 443 may be serving a certificate
        # for the domain only, and 127.0.0.1:8081 is what install.sh polls.
        HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8081/api/health}"
        ;;
    *)
        die "LAYOUT must be auto, legacy or raven (got '$LAYOUT')"
        ;;
esac

SERVER_REPO="${SERVER_REPO:-https://github.com/C4-Raven/c4raven-server.git}"
UI_REPO="${UI_REPO:-https://github.com/C4-Raven/c4raven-ui.git}"

SKIP_UI="${SKIP_UI:-0}"                       # set to 1 to update backend only
SKIP_BACKEND="${SKIP_BACKEND:-0}"             # set to 1 to update UI only

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
HEALTH_TRIES="${HEALTH_TRIES:-30}"            # 2s apart

# Run a command as whoever owns the install: you (legacy), or the raven
# system user (raven layout -- its directories aren't readable by anyone
# else). A login shell, so the raven user's ~/.local/bin (poetry) is on PATH.
as_app() {
    if [[ "$LAYOUT" == raven ]]; then
        # cd /: the raven user can't read the directory you launched from.
        sudo -u "$RAVEN_USER" -H bash -lc "cd / && $(printf '%q ' "$@")"
    else
        "$@"
    fi
}

# Root for the raven layout (files there belong to another user), plain
# otherwise.
as_owner_root() {
    if [[ "$LAYOUT" == raven ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

log "Updating the $LAYOUT layout (data: $RAVEN_DATA_DIR)"

as_app test -d "$RAVEN_VENV" || die "RAVEN_VENV not found: $RAVEN_VENV"
as_app test -d "$RAVEN_DATA_DIR" || die "RAVEN_DATA_DIR not found: $RAVEN_DATA_DIR"
as_app test -f "$RAVEN_DATA_DIR/config.yml" || die "$RAVEN_DATA_DIR/config.yml not found -- wrong RAVEN_DATA_DIR?"

PYTHON="$RAVEN_VENV/bin/python"
PIP="$RAVEN_VENV/bin/pip"
as_app test -x "$PYTHON" || die "$PYTHON not found -- wrong RAVEN_VENV?"

PREV_COMMIT="$(as_app git -C "$SERVER_SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/update-$TS"
# The backup holds config.yml (database password, secret keys) and the CA's
# private keys: keep it readable by you only.
mkdir -p "$BACKUP_ROOT"
mkdir -m 700 "$BACKUP_DIR"

log "Backing up to $BACKUP_DIR (backend currently at commit ${PREV_COMMIT})"
echo "$PREV_COMMIT" > "$BACKUP_DIR/server-commit.txt"

# ---- back up the database ---------------------------------------------------
log "Dumping database"
DB_URI="$(as_app "$PYTHON" -c '
import sys, yaml
with open(sys.argv[1]) as f:
    print(yaml.safe_load(f)["SQLALCHEMY_DATABASE_URI"])
' "$RAVEN_DATA_DIR/config.yml")"
# pg_dump doesn't understand the SQLAlchemy "+psycopg" driver suffix.
PG_URI="$(python3 -c "import sys; print(sys.argv[1].replace('postgresql+psycopg://', 'postgresql://'))" "$DB_URI")"
if command -v pg_dump >/dev/null 2>&1; then
    pg_dump "$PG_URI" | gzip > "$BACKUP_DIR/database.sql.gz"
    log "Database backed up to $BACKUP_DIR/database.sql.gz"
else
    warn "pg_dump not found on PATH -- skipping database backup. Install postgresql-client or back up manually before proceeding."
fi

# ---- back up the data directory (config, certs, uploads, icons) ------------
log "Backing up $RAVEN_DATA_DIR (excluding logs/)"
# The data dir is live (icons.sqlite, uploads); tar exits 1 for "file changed
# as we read it", which is a warning here, not a failed backup. Anything
# else (exit 2) is a real error and still aborts.
as_owner_root tar --warning=no-file-changed --exclude='logs' -czf "$BACKUP_DIR/raven-data.tar.gz" \
    -C "$(dirname "$RAVEN_DATA_DIR")" "$(basename "$RAVEN_DATA_DIR")" || [[ $? -eq 1 ]]
as_owner_root chown "$(id -u):$(id -g)" "$BACKUP_DIR/raven-data.tar.gz"
chmod 600 "$BACKUP_DIR/raven-data.tar.gz"

# ---- back up the currently-deployed UI --------------------------------------
if [[ -d "$UI_DEPLOY_DIR" ]]; then
    log "Backing up currently deployed UI"
    mkdir -p "$BACKUP_DIR/ui"
    cp -a "$UI_DEPLOY_DIR/." "$BACKUP_DIR/ui/" 2>/dev/null || true
fi

log "Backup complete. Nothing destructive has happened yet."

# ---- update the backend -----------------------------------------------------
if [[ "$SKIP_BACKEND" != "1" ]]; then
    if as_app test -d "$SERVER_SRC_DIR/.git"; then
        log "Fetching c4raven-server"
        # raven/__init__.py is a version stamp that poetry-dynamic-versioning
        # rewrites on every install; discard that drift so it can't block
        # the fast-forward (git refuses to overwrite a modified file).
        as_app git -C "$SERVER_SRC_DIR" checkout -- raven/__init__.py 2>/dev/null || true
        as_app git -C "$SERVER_SRC_DIR" fetch origin
        if ! as_app git -C "$SERVER_SRC_DIR" merge --ff-only origin/main; then
            as_app git -C "$SERVER_SRC_DIR" status --short
            die "c4raven-server has local commits or modified files (listed above) that block a fast-forward to origin/main. Resolve them in $SERVER_SRC_DIR (commit/stash/push as appropriate), then re-run."
        fi
    else
        log "Cloning c4raven-server"
        as_app git clone "$SERVER_REPO" "$SERVER_SRC_DIR"
    fi

    NEW_COMMIT="$(as_app git -C "$SERVER_SRC_DIR" rev-parse --short HEAD)"
    log "c4raven-server: ${PREV_COMMIT} -> ${NEW_COMMIT}"

    if [[ "$LAYOUT" == raven ]]; then
        # install.sh built this venv with Poetry (in-project .venv); keep
        # using it so the install follows poetry.lock exactly.
        log "Installing into the venv (poetry install)"
        as_app bash -c 'cd "$1" && poetry install' _ "$SERVER_SRC_DIR"
    else
        log "Installing into the venv (editable)"
        "$PIP" install -e "$SERVER_SRC_DIR"
    fi
else
    warn "SKIP_BACKEND=1 -- backend left untouched"
fi

# ---- update the frontend ----------------------------------------------------
if [[ "$SKIP_UI" != "1" ]]; then
    log "Updating c4raven-ui source"
    if as_app test -d "$UI_SRC_DIR/.git"; then
        # src/_versions.ts is a build stamp that `yarn build` rewrites every
        # run; discard it so it can't block the fast-forward.
        as_app git -C "$UI_SRC_DIR" checkout -- src/_versions.ts 2>/dev/null || true
        as_app git -C "$UI_SRC_DIR" fetch origin
        if ! as_app git -C "$UI_SRC_DIR" merge --ff-only origin/main; then
            as_app git -C "$UI_SRC_DIR" status --short
            die "c4raven-ui has local commits or modified files (listed above) that block a fast-forward to origin/main. Resolve them in $UI_SRC_DIR, then re-run."
        fi
    else
        as_app git clone "$UI_REPO" "$UI_SRC_DIR"
    fi

    log "Building UI"
    # c4raven-ui pins yarn 4 via package.json's packageManager field;
    # `corepack yarn` runs that exact version. There is no npm fallback:
    # npm doesn't understand the yarn 4 lockfile and would corrupt it.
    as_app bash -c 'command -v corepack' >/dev/null 2>&1 \
        || die "corepack not found (needed to run the pinned yarn 4). Install Node with corepack, or: sudo npm install -g corepack"
    as_app bash -c 'cd "$1" && corepack yarn install --immutable && corepack yarn build' _ "$UI_SRC_DIR"

    log "Deploying UI to $UI_DEPLOY_DIR"
    # --no-perms/--no-owner/--no-group/--omit-dir-times: don't try to set
    # metadata on the webroot itself (we may not own it), which is the only
    # thing that used to make rsync exit 23 here. Everything else is a real
    # failure and must not be swallowed -- a half-deployed UI plus a service
    # restart is worse than stopping.
    as_owner_root rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete \
        "$UI_SRC_DIR/dist/" "$UI_DEPLOY_DIR/" || die "UI deploy to $UI_DEPLOY_DIR failed (rsync exit $?)"
    if [[ "$LAYOUT" == raven ]]; then
        sudo chown -R "$RAVEN_USER:$RAVEN_USER" "$UI_DEPLOY_DIR"
    fi
else
    warn "SKIP_UI=1 -- frontend left untouched"
fi

# ---- restart and verify ------------------------------------------------------
# Federation Hub (optional, raven layout) talks to the backend's API; restart
# it with the rest when it's running, as c4raven-server-setup's update.sh does.
if [[ "$LAYOUT" == raven ]] && systemctl is-active --quiet federation-hub 2>/dev/null; then
    RAVEN_SERVICES="$RAVEN_SERVICES federation-hub.service"
fi
log "Restarting: $RAVEN_SERVICES"
# shellcheck disable=SC2086
sudo systemctl restart $RAVEN_SERVICES

log "Waiting for the service to come up (migrations run on startup)"
MAIN_SERVICE="${RAVEN_SERVICES%% *}"
for i in $(seq 1 "$HEALTH_TRIES"); do
    if curl -sk -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null | grep -q '^200$'; then
        log "Healthy: $HEALTH_URL returned 200"
        break
    fi
    if [[ "$i" -eq "$HEALTH_TRIES" ]]; then
        warn "Service did not report healthy after $((HEALTH_TRIES * 2))s. Check: sudo journalctl -u $MAIN_SERVICE -n 100"
    fi
    sleep 2
done

for svc in $RAVEN_SERVICES; do
    state="$(systemctl is-active "$svc" 2>/dev/null || echo unknown)"
    if [[ "$state" != "active" ]]; then
        warn "$svc is $state -- check: sudo journalctl -u $svc -n 100"
    fi
done

cat <<EOF

Update finished ($LAYOUT layout).

Backup:          $BACKUP_DIR
Backend before:  ${PREV_COMMIT}
Backend after:   ${NEW_COMMIT:-unchanged}

If anything looks wrong, see README.md for how to roll back from the
backup directory above.
EOF
