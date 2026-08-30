#!/usr/bin/env bash
# C4 Raven updater -- upgrades an existing install (opentakserver backend +
# c4raven-ui frontend) in place, without touching the database contents,
# uploaded files, certificates, or config.yml.
#
# What this does NOT do, ever:
#   - drop, recreate, or truncate the database (only additive Alembic
#     migrations run, via the app's own normal startup path)
#   - delete anything under $OTS_DATA_DIR (certs, config.yml, uploads,
#     icons.sqlite, mediamtx config)
#   - touch $OTS_DATA_DIR/logs
#
# It DOES back up the database and $OTS_DATA_DIR before making any change,
# so a bad update can be rolled back. See README.md for rollback steps.

set -euo pipefail

# ---- configuration (override via environment) ------------------------------
OTS_VENV="${OTS_VENV:-$HOME/.opentakserver_venv}"
OTS_DATA_DIR="${OTS_DATA_DIR:-$HOME/ots}"
OTS_SERVICE="${OTS_SERVICE:-opentakserver.service}"
OTS_VERSION="${OTS_VERSION:-}"                # empty = latest on PyPI

UI_REPO="${UI_REPO:-https://github.com/C4Raven/c4raven-ui.git}"
UI_SRC_DIR="${UI_SRC_DIR:-$HOME/src/c4raven-ui}"
UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/opentakserver}"
SKIP_UI="${SKIP_UI:-0}"                       # set to 1 to update backend only
SKIP_BACKEND="${SKIP_BACKEND:-0}"             # set to 1 to update UI only

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
HEALTH_URL="${HEALTH_URL:-https://127.0.0.1/api/health}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m! %s\033[0m\n' "$1"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

[[ -d "$OTS_VENV" ]] || die "OTS_VENV not found: $OTS_VENV"
[[ -d "$OTS_DATA_DIR" ]] || die "OTS_DATA_DIR not found: $OTS_DATA_DIR"
[[ -f "$OTS_DATA_DIR/config.yml" ]] || die "$OTS_DATA_DIR/config.yml not found -- wrong OTS_DATA_DIR?"

PYTHON="$OTS_VENV/bin/python"
PIP="$OTS_VENV/bin/pip"
[[ -x "$PYTHON" ]] || die "$PYTHON not found -- wrong OTS_VENV?"

SITE_PACKAGES="$("$PYTHON" -c 'import opentakserver, os; print(os.path.dirname(os.path.dirname(opentakserver.__file__)))')"
PREV_VERSION="$("$PIP" show opentakserver 2>/dev/null | awk '/^Version:/{print $2}')"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/update-$TS"
mkdir -p "$BACKUP_DIR"

log "Backing up to $BACKUP_DIR (previous opentakserver version: ${PREV_VERSION:-unknown})"
echo "$PREV_VERSION" > "$BACKUP_DIR/opentakserver-version.txt"

# ---- back up the database ---------------------------------------------------
log "Dumping database"
DB_URI="$("$PYTHON" -c "
import yaml
with open('$OTS_DATA_DIR/config.yml') as f:
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
log "Backing up $OTS_DATA_DIR (excluding logs/)"
tar --exclude='logs' -czf "$BACKUP_DIR/ots-data.tar.gz" -C "$(dirname "$OTS_DATA_DIR")" "$(basename "$OTS_DATA_DIR")"

# ---- back up the currently-deployed UI --------------------------------------
if [[ -d "$UI_DEPLOY_DIR" ]]; then
    log "Backing up currently deployed UI"
    mkdir -p "$BACKUP_DIR/ui"
    cp -a "$UI_DEPLOY_DIR/." "$BACKUP_DIR/ui/" 2>/dev/null || true
fi

log "Backup complete. Nothing destructive has happened yet."

# ---- update the backend -----------------------------------------------------
if [[ "$SKIP_BACKEND" != "1" ]]; then
    log "Upgrading opentakserver (pip)"
    if [[ -n "$OTS_VERSION" ]]; then
        "$PIP" install --upgrade "opentakserver==$OTS_VERSION"
    else
        "$PIP" install --upgrade opentakserver
    fi

    NEW_VERSION="$("$PIP" show opentakserver 2>/dev/null | awk '/^Version:/{print $2}')"
    log "opentakserver: $PREV_VERSION -> $NEW_VERSION"

    log "Re-applying C4 Raven backend customizations"
    if patch -p1 --forward -d "$SITE_PACKAGES" < "$SCRIPT_DIR/patches/opentakserver-customizations.patch"; then
        log "Patch applied cleanly"
    else
        status=$?
        if [[ $status -eq 1 ]]; then
            warn "Patch already applied or partially applied (forward-check skipped some hunks) -- this is normal on a re-run."
        else
            die "Patch failed to apply against opentakserver $NEW_VERSION. The upstream package likely changed the patched files enough that this needs a manual merge. Your install has NOT been left running the new version's code without patches -- check $SITE_PACKAGES for *.orig/*.rej files, resolve, then re-run."
        fi
    fi

    log "Installing new migrations"
    cp "$SCRIPT_DIR"/migrations/*.py "$SITE_PACKAGES/opentakserver/migrations/versions/"
else
    warn "SKIP_BACKEND=1 -- backend left untouched"
fi

# ---- update the frontend ----------------------------------------------------
if [[ "$SKIP_UI" != "1" ]]; then
    log "Updating c4raven-ui source"
    if [[ -d "$UI_SRC_DIR/.git" ]]; then
        git -C "$UI_SRC_DIR" fetch origin
        git -C "$UI_SRC_DIR" merge --ff-only origin/master
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
log "Restarting $OTS_SERVICE"
sudo systemctl restart "$OTS_SERVICE"

log "Waiting for the service to come up"
for i in $(seq 1 15); do
    if curl -sk -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null | grep -q '^200$'; then
        log "Healthy: $HEALTH_URL returned 200"
        break
    fi
    if [[ "$i" -eq 15 ]]; then
        warn "Service did not report healthy after 30s. Check: sudo journalctl -u $OTS_SERVICE -n 100"
    fi
    sleep 2
done

cat <<EOF

Update finished.

Backup:        $BACKUP_DIR
Previous ver:  ${PREV_VERSION:-unknown}
New ver:       ${NEW_VERSION:-unchanged}

If anything looks wrong, see README.md for how to roll back from the
backup directory above.
EOF
