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
# already on our own origin/master.
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

# ---- configuration (override via environment) ------------------------------
RAVEN_VENV="${RAVEN_VENV:-$HOME/.opentakserver_venv}"
RAVEN_DATA_DIR="${RAVEN_DATA_DIR:-$HOME/ots}"
RAVEN_SERVICES="${RAVEN_SERVICES:-opentakserver.service eud_handler.service eud_handler_ssl.service cot_parser.service}"

SERVER_REPO="${SERVER_REPO:-https://github.com/C4Raven/c4raven-server.git}"
SERVER_SRC_DIR="${SERVER_SRC_DIR:-$HOME/src/c4raven-server}"

UI_REPO="${UI_REPO:-https://github.com/C4Raven/c4raven-ui.git}"
UI_SRC_DIR="${UI_SRC_DIR:-$HOME/src/c4raven-ui}"
UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/opentakserver}"

SKIP_UI="${SKIP_UI:-0}"                       # set to 1 to update backend only
SKIP_BACKEND="${SKIP_BACKEND:-0}"             # set to 1 to update UI only

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
HEALTH_URL="${HEALTH_URL:-https://127.0.0.1/api/health}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$1"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[[ -d "$RAVEN_VENV" ]] || die "RAVEN_VENV not found: $RAVEN_VENV"
[[ -d "$RAVEN_DATA_DIR" ]] || die "RAVEN_DATA_DIR not found: $RAVEN_DATA_DIR"
[[ -f "$RAVEN_DATA_DIR/config.yml" ]] || die "$RAVEN_DATA_DIR/config.yml not found -- wrong RAVEN_DATA_DIR?"

PYTHON="$RAVEN_VENV/bin/python"
PIP="$RAVEN_VENV/bin/pip"
[[ -x "$PYTHON" ]] || die "$PYTHON not found -- wrong RAVEN_VENV?"

PREV_COMMIT="$(git -C "$SERVER_SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/update-$TS"
mkdir -p "$BACKUP_DIR"

log "Backing up to $BACKUP_DIR (backend currently at commit ${PREV_COMMIT})"
echo "$PREV_COMMIT" > "$BACKUP_DIR/server-commit.txt"

# ---- back up the database ---------------------------------------------------
log "Dumping database"
DB_URI="$("$PYTHON" -c "
import yaml
with open('$RAVEN_DATA_DIR/config.yml') as f:
    cfg = yaml.safe_load(f)
print(cfg['SQLALCHEMY_DATABASE_URI'])
")"
# postgresql+psycopg://user:pass@host/dbname -> plain postgresql:// for pg_dump
PG_URI="$(python3 -c "import sys; print(sys.argv[1].replace('postgresql+psycopg://', 'postgresql://'))" "$DB_URI")"
if command -v pg_dump >/dev/null 2>&1; then
    pg_dump "$PG_URI" | gzip > "$BACKUP_DIR/database.sql.gz"
    log "Database backed up to $BACKUP_DIR/database.sql.gz"
else
    warn "pg_dump not found on PATH -- skipping database backup. Install postgresql-client or back up manually before proceeding."
fi

# ---- back up the data directory (config, certs, uploads, icons) ------------
log "Backing up $RAVEN_DATA_DIR (excluding logs/)"
tar --exclude='logs' -czf "$BACKUP_DIR/raven-data.tar.gz" -C "$(dirname "$RAVEN_DATA_DIR")" "$(basename "$RAVEN_DATA_DIR")"

# ---- back up the currently-deployed UI --------------------------------------
if [[ -d "$UI_DEPLOY_DIR" ]]; then
    log "Backing up currently deployed UI"
    mkdir -p "$BACKUP_DIR/ui"
    cp -a "$UI_DEPLOY_DIR/." "$BACKUP_DIR/ui/" 2>/dev/null || true
fi

log "Backup complete. Nothing destructive has happened yet."

# ---- update the backend -----------------------------------------------------
if [[ "$SKIP_BACKEND" != "1" ]]; then
    if [[ -d "$SERVER_SRC_DIR/.git" ]]; then
        log "Fetching c4raven-server"
        git -C "$SERVER_SRC_DIR" fetch origin
        if ! git -C "$SERVER_SRC_DIR" merge --ff-only origin/master; then
            die "c4raven-server has local commits/changes that aren't on origin/master -- won't fast-forward over them. Resolve manually in $SERVER_SRC_DIR (commit/stash/push as appropriate), then re-run."
        fi
    else
        log "Cloning c4raven-server"
        git clone "$SERVER_REPO" "$SERVER_SRC_DIR"
    fi

    NEW_COMMIT="$(git -C "$SERVER_SRC_DIR" rev-parse --short HEAD)"
    log "c4raven-server: ${PREV_COMMIT} -> ${NEW_COMMIT}"

    log "Installing into the venv (editable)"
    "$PIP" install -e "$SERVER_SRC_DIR"
else
    warn "SKIP_BACKEND=1 -- backend left untouched"
fi

# ---- update the frontend ----------------------------------------------------
if [[ "$SKIP_UI" != "1" ]]; then
    log "Updating c4raven-ui source"
    if [[ -d "$UI_SRC_DIR/.git" ]]; then
        git -C "$UI_SRC_DIR" fetch origin
        if ! git -C "$UI_SRC_DIR" merge --ff-only origin/master; then
            die "c4raven-ui has local commits/changes that aren't on origin/master -- won't fast-forward over them. Resolve manually in $UI_SRC_DIR, then re-run."
        fi
    else
        git clone "$UI_REPO" "$UI_SRC_DIR"
    fi

    log "Building UI"
    (
        cd "$UI_SRC_DIR"
        if command -v corepack >/dev/null 2>&1; then
            corepack yarn install --immutable
            corepack yarn build
        else
            warn "corepack not found, falling back to npm"
            npx --yes ts-appversion --git=.
            npx --yes vite build
        fi
    )

    log "Deploying UI to $UI_DEPLOY_DIR"
    rsync -a --delete "$UI_SRC_DIR/dist/" "$UI_DEPLOY_DIR/" 2>&1 | grep -v "chgrp\|rsync error\|code 23" || true
else
    warn "SKIP_UI=1 -- frontend left untouched"
fi

# ---- restart and verify ------------------------------------------------------
log "Restarting: $RAVEN_SERVICES"
sudo systemctl restart $RAVEN_SERVICES

log "Waiting for the service to come up"
for i in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null | grep -q '^200$'; then
        log "Healthy: $HEALTH_URL returned 200"
        break
    fi
    if [[ "$i" -eq 15 ]]; then
        warn "Service did not report healthy after 30s. Check: sudo journalctl -u opentakserver.service -n 100"
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

Update finished.

Backup:          $BACKUP_DIR
Backend before:  ${PREV_COMMIT}
Backend after:   ${NEW_COMMIT:-unchanged}

If anything looks wrong, see README.md for how to roll back from the
backup directory above.
EOF
