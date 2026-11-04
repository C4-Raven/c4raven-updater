#!/usr/bin/env bash
# C4 Raven updater -- brings an existing install fully up to date, in place:
#
#   1. backs up the database (pg_dump), the data directory (config.yml,
#      certificates, uploads), the deployed UI and /etc/nginx
#   2. fast-forwards c4raven-server to origin/main, installs its Python
#      dependencies into the venv
#   3. fast-forwards c4raven-ui to origin/main, rebuilds and redeploys it
#   4. stops the Raven services, runs the database migrations to head and
#      checks the database really is at head
#   5. leaves config.yml alone (new settings use the code's defaults; see
#      NEW_CONFIG_KEYS in lib/common.sh), fills in MediaMTX's token if missing,
#      makes the log files belong to the service user
#   6. applies the current nginx template fixes to the existing site files
#      (backup, nginx -t, roll back on failure)
#   7. starts everything again, health-checks it and prints a summary
#   8. checks Federation Hub (install-fedhub.sh --check): offers to install
#      it when missing, reconnects Raven when needed (legacy layout: report only)
#
# Safe to re-run: every step checks first and skips what is already current.
# It never drops or truncates the database, never deletes anything in the
# data directory, and never merges or rebases over local changes. A server
# whose first install stopped partway is completed with finish-install.sh
# first (automatically). See README.md for the layouts and for rollback.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

# ---- layout -----------------------------------------------------------------
#   legacy  one login user owns everything: venv ~/.raven_venv, data
#           ~/ots, source in ~/src, UI in /var/www/html/raven, raven.service
#           (the same unit and UI directory names as the raven layout, so
#           detection keys on the venv in the login user's home only)
#   raven   c4raven-server-setup's install.sh, online .deb or .rpm: a `raven`
#           system user owns /opt/raven/{c4raven-server,c4raven-ui,data},
#           UI in /var/www/html/raven, raven.service
#   offline the offline .deb/.rpm: /opt/raven/venv, no source checkout. Its
#           code is upgraded by installing a newer offline bundle; this
#           script only applies the config and nginx fixes there.
LAYOUT="${LAYOUT:-auto}"
RAVEN_HOME="${RAVEN_HOME:-/opt/raven}"
RAVEN_USER="${RAVEN_USER:-raven}"

if [[ "$LAYOUT" == auto ]]; then
    if [[ -d "$HOME/.raven_venv" ]]; then
        LAYOUT=legacy
    elif as_root test -d "$RAVEN_HOME/c4raven-server/.git"; then
        LAYOUT=raven
    elif as_root test -L "$RAVEN_HOME/venv"; then
        LAYOUT=offline
    else
        die "No C4 Raven install found (looked for ~/.raven_venv, $RAVEN_HOME/c4raven-server and $RAVEN_HOME/venv). If yours lives elsewhere, set LAYOUT=legacy or LAYOUT=raven plus the paths in README.md."
    fi
fi

case "$LAYOUT" in
    legacy)
        RAVEN_VENV="${RAVEN_VENV:-$HOME/.raven_venv}"
        RAVEN_DATA_DIR="${RAVEN_DATA_DIR:-$HOME/ots}"
        RAVEN_SERVICES="${RAVEN_SERVICES:-raven.service eud_handler.service eud_handler_ssl.service cot_parser.service}"
        SERVER_SRC_DIR="${SERVER_SRC_DIR:-$HOME/src/c4raven-server}"
        UI_SRC_DIR="${UI_SRC_DIR:-$HOME/src/c4raven-ui}"
        UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/raven}"
        HEALTH_URL="${HEALTH_URL:-https://127.0.0.1/api/health}"
        ;;
    raven|offline)
        if [[ "$LAYOUT" == raven ]]; then
            RAVEN_VENV="${RAVEN_VENV:-$RAVEN_HOME/c4raven-server/.venv}"
        else
            RAVEN_VENV="${RAVEN_VENV:-$RAVEN_HOME/venv}"
        fi
        RAVEN_DATA_DIR="${RAVEN_DATA_DIR:-$RAVEN_HOME/data}"
        RAVEN_SERVICES="${RAVEN_SERVICES:-raven.service eud_handler.service eud_handler_ssl.service cot_parser.service mediamtx.service}"
        SERVER_SRC_DIR="${SERVER_SRC_DIR:-$RAVEN_HOME/c4raven-server}"
        UI_SRC_DIR="${UI_SRC_DIR:-$RAVEN_HOME/c4raven-ui}"
        UI_DEPLOY_DIR="${UI_DEPLOY_DIR:-/var/www/html/raven}"
        # Straight to the backend: nginx on 443 may only have a certificate
        # for the domain, and 127.0.0.1:8081 is what install.sh polls.
        HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8081/api/health}"
        ;;
    *)
        die "LAYOUT must be auto, legacy, raven or offline (got '$LAYOUT')"
        ;;
esac

SERVER_REPO="${SERVER_REPO:-https://github.com/C4-Raven/c4raven-server.git}"
UI_REPO="${UI_REPO:-https://github.com/C4-Raven/c4raven-ui.git}"
SERVER_BRANCH="${SERVER_BRANCH:-main}"
UI_BRANCH="${UI_BRANCH:-main}"
SKIP_UI="${SKIP_UI:-0}"                 # 1 = backend only
SKIP_BACKEND="${SKIP_BACKEND:-0}"       # 1 = UI only
SKIP_NGINX="${SKIP_NGINX:-0}"           # 1 = leave nginx alone
SKIP_DB_BACKUP="${SKIP_DB_BACKUP:-0}"   # 1 = migrate without a pg_dump first (not recommended)
FORCE_UI_BUILD="${FORCE_UI_BUILD:-0}"   # 1 = rebuild the UI even if its commit hasn't changed
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups}"
HEALTH_TRIES="${HEALTH_TRIES:-60}"      # 2s apart

# The account that owns the install (and runs every git/pip/yarn/flask step,
# so ownership stays as the installer left it).
if [[ "$LAYOUT" == legacy ]]; then
    APP_OWNER="${APP_OWNER:-$(stat -c %U "$RAVEN_DATA_DIR" 2>/dev/null || id -un)}"
else
    APP_OWNER="$RAVEN_USER"
fi
as_app() { as_user "$APP_OWNER" "$@"; }
as_app_sh() { as_user_sh "$APP_OWNER" "$1"; }
WORKDIR="$SERVER_SRC_DIR"
[[ "$LAYOUT" == raven ]] || WORKDIR="$RAVEN_DATA_DIR"

# One run at a time (finish-install.sh, when called from here, shares it).
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

log "Updating the $LAYOUT layout (data: $RAVEN_DATA_DIR, owner: $APP_OWNER)"
systemd_notice

as_app test -d "$RAVEN_VENV" || die "RAVEN_VENV not found: $RAVEN_VENV"
as_app test -f "$RAVEN_DATA_DIR/config.yml" || {
    [[ "$LAYOUT" == raven ]] && die "$RAVEN_DATA_DIR/config.yml not found: this install stopped very early. Run ./finish-install.sh."
    die "$RAVEN_DATA_DIR/config.yml not found -- wrong RAVEN_DATA_DIR?"
}
PYTHON="$RAVEN_VENV/bin/python"
as_app test -x "$PYTHON" || die "$PYTHON not found -- wrong RAVEN_VENV?"

# The app's own CLI (flask db ..., used below) writes to logs/raven.log too,
# and dies on a log file systemd created as root -- fix that before anything
# runs it.
MAIN_LOG=raven.log
fix_log_ownership "$APP_OWNER" "$RAVEN_DATA_DIR/logs" "$MAIN_LOG" || true

# ---- an install that never finished: complete it first ----------------------
# install.sh writes the services near its very end, so a run that died
# earlier leaves no raven.service, no secrets file, maybe no database.
if [[ "$LAYOUT" == raven ]]; then
    incomplete=""
    unit_exists raven.service || incomplete="raven.service is missing"
    as_root test -f "$RAVEN_HOME/.raven-secrets.env" || incomplete="${incomplete:+$incomplete, }the secrets file is missing"
    case "$(config_get "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER" SQLALCHEMY_DATABASE_URI 2>/dev/null)" in
        postgresql*) ;;
        *) incomplete="${incomplete:+$incomplete, }config.yml has no PostgreSQL database" ;;
    esac
    if [[ -n "$incomplete" ]]; then
        warn "This server's install never finished ($incomplete). Running finish-install.sh first."
        "$HERE/finish-install.sh" || die "finish-install.sh could not complete the install (see above); fix that and re-run."
        # Its last step was the Federation Hub section; don't ask again below.
        export RAVEN_FEDHUB_SECTION_DONE=1
    fi
fi

# ---- offline package: config + nginx only ------------------------------------
if [[ "$LAYOUT" == offline ]]; then
    log "Offline package install: the code is updated by a newer offline bundle, not from GitHub"
    out=$(config_add_keys "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER" "$RAVEN_HOME/.raven-secrets.env") || warn "could not add new settings to config.yml"
    [[ -n "${out:-}" ]] && fixed "config.yml: added $(echo "$out" | tr '\n' ' ')"
    out=$(config_drop_retired "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER") || warn "could not remove retired settings from config.yml"
    [[ -n "${out:-}" ]] && fixed "config.yml: removed the retired default of $out"
    [[ "$SKIP_NGINX" == 1 ]] || nginx_harden || true
    export RAVEN_USER="$APP_OWNER" RAVEN_HOME RAVEN_DATA_DIR RAVEN_VENV
    fedhub_section offline
    echo
    print_summary
    cat <<EOF

To update the code itself, run install.sh from a newer
c4raven-server-offline bundle (or: sudo apt install ./c4raven-server_<version>_<arch>.deb).
EOF
    exit 0
fi

# ---- network preflight -------------------------------------------------------
if [[ "$SKIP_BACKEND" != 1 ]]; then
    log "Checking that GitHub is reachable"
    retry as_app git ls-remote --exit-code "$SERVER_REPO" "refs/heads/$SERVER_BRANCH" >/dev/null \
        || die "Can't reach $SERVER_REPO (after retries). Check this server's internet access / DNS / proxy and re-run; nothing has been changed."
fi

# ---- backups -----------------------------------------------------------------
PREV_COMMIT="$(as_app git -C "$SERVER_SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
PREV_UI_COMMIT="$(as_app git -C "$UI_SRC_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/update-$TS"
# Holds config.yml (DB password, secret keys) and the CA's private keys.
mkdir -p "$BACKUP_ROOT"
mkdir -m 700 "$BACKUP_DIR"
log "Backing up to $BACKUP_DIR"
echo "$PREV_COMMIT" > "$BACKUP_DIR/server-commit.txt"
echo "$PREV_UI_COMMIT" > "$BACKUP_DIR/ui-commit.txt"

DB_URI="$(config_get "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER" SQLALCHEMY_DATABASE_URI)"
DB_REV_BEFORE="$(db_revisions "$APP_OWNER" "$RAVEN_VENV" "$RAVEN_DATA_DIR" "$WORKDIR" current || true)"
echo "${DB_REV_BEFORE:-unknown}" > "$BACKUP_DIR/db-revision.txt"

if [[ "$SKIP_DB_BACKUP" == 1 ]]; then
    warn "SKIP_DB_BACKUP=1 -- no database backup taken"
elif [[ "$DB_URI" == postgresql* ]]; then
    if ! command -v pg_dump >/dev/null 2>&1; then
        warn "pg_dump not on PATH; installing the PostgreSQL client"
        if [[ "$PKG_MGR" == apt ]]; then pkg_install postgresql-client || true; else pkg_install postgresql || true; fi
    fi
    command -v pg_dump >/dev/null 2>&1 || die "pg_dump is not available, so the database can't be backed up before migrating. Install postgresql-client (Rocky: postgresql), or re-run with SKIP_DB_BACKUP=1 if you have your own backup."
    if pg_dump "$(pg_uri "$DB_URI")" > "$BACKUP_DIR/database.sql" 2> "$BACKUP_DIR/pg_dump.err"; then
        gzip "$BACKUP_DIR/database.sql"
        rm -f "$BACKUP_DIR/pg_dump.err"
        ok "database dumped to $BACKUP_DIR/database.sql.gz ($(du -h "$BACKUP_DIR/database.sql.gz" | cut -f1))"
    else
        cat "$BACKUP_DIR/pg_dump.err" >&2
        die "pg_dump failed (above), so nothing was changed. A server/client version mismatch is the usual cause: install the matching postgresql-client, or re-run with SKIP_DB_BACKUP=1 if you have your own backup."
    fi
else
    warn "config.yml's database is not PostgreSQL (${DB_URI%%:*}); copy it yourself if it lives outside the data directory"
fi

as_root tar --warning=no-file-changed --exclude='logs' -czf "$BACKUP_DIR/raven-data.tar.gz" \
    -C "$(dirname "$RAVEN_DATA_DIR")" "$(basename "$RAVEN_DATA_DIR")" || [[ $? -eq 1 ]]
as_root chown "$(id -u):$(id -g)" "$BACKUP_DIR/raven-data.tar.gz"
chmod 600 "$BACKUP_DIR/raven-data.tar.gz"
ok "data directory archived (excluding logs/)"
if as_root test -d /etc/nginx; then
    as_root tar -czf "$BACKUP_DIR/nginx.tar.gz" -C /etc nginx 2>/dev/null || true
    as_root chown "$(id -u):$(id -g)" "$BACKUP_DIR/nginx.tar.gz" 2>/dev/null || true
fi
if [[ -d "$UI_DEPLOY_DIR" ]]; then
    mkdir -p "$BACKUP_DIR/ui"
    as_root cp -a "$UI_DEPLOY_DIR/." "$BACKUP_DIR/ui/" 2>/dev/null || true
fi
ok "backup complete -- nothing has been changed yet"

# ---- git helper ----------------------------------------------------------------
# git_update DIR REPO BRANCH STAMP_FILES...  -- clone or fast-forward only.
git_update() {
    local dir=$1 repo=$2 branch=$3; shift 3
    if ! as_app test -d "$dir/.git"; then
        log "Cloning $repo"
        retry as_app git clone --branch "$branch" "$repo" "$dir"
        return
    fi
    # Build stamps the tools rewrite on every run; drift in them must not
    # block the fast-forward.
    local f
    for f in "$@"; do as_app git -C "$dir" checkout -- "$f" 2>/dev/null || true; done
    retry as_app git -C "$dir" fetch origin "$branch" \
        || die "git fetch in $dir failed after retries (network?). Nothing after the backup has changed; re-run when the network is back."
    # The packaged (.deb/.rpm) installs check out an exact commit, leaving a
    # detached HEAD: move onto the branch when that loses nothing.
    if ! as_app git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
        if as_app git -C "$dir" merge-base --is-ancestor HEAD "origin/$branch"; then
            as_app git -C "$dir" checkout -q -B "$branch" "origin/$branch"
            return
        fi
        die "$dir has a detached HEAD that isn't part of origin/$branch. Check it out onto $branch yourself, then re-run."
    fi
    if [[ "$(as_app git -C "$dir" rev-parse --abbrev-ref HEAD)" != "$branch" ]]; then
        die "$dir is on branch '$(as_app git -C "$dir" rev-parse --abbrev-ref HEAD)', not '$branch'. Switch it (git checkout $branch) or set SERVER_BRANCH/UI_BRANCH, then re-run."
    fi
    if ! as_app git -C "$dir" merge --ff-only -q "origin/$branch"; then
        as_app git -C "$dir" status --short
        die "$dir has local commits or modified files (above) that block a fast-forward to origin/$branch. Resolve them (commit/stash/push), then re-run."
    fi
}

# ---- backend -------------------------------------------------------------------
NEW_COMMIT="$PREV_COMMIT"
if [[ "$SKIP_BACKEND" != 1 ]]; then
    log "Updating c4raven-server"
    git_update "$SERVER_SRC_DIR" "$SERVER_REPO" "$SERVER_BRANCH" raven/__init__.py
    NEW_COMMIT="$(as_app git -C "$SERVER_SRC_DIR" rev-parse --short HEAD)"
    if [[ "$NEW_COMMIT" != "$PREV_COMMIT" ]]; then fixed "c4raven-server $PREV_COMMIT -> $NEW_COMMIT"; else ok "c4raven-server already at $NEW_COMMIT"; fi

    log "Installing Python dependencies"
    if [[ "$LAYOUT" == raven ]]; then
        # install.sh built this venv with Poetry; keep following poetry.lock.
        as_app_sh 'command -v poetry' >/dev/null 2>&1 \
            || die "poetry isn't on the $APP_OWNER user's PATH. Run ./finish-install.sh, which reinstalls it."
        retry as_app_sh "cd $(printf '%q' "$SERVER_SRC_DIR") && PYTHON_KEYRING_BACKEND=keyring.backends.null.Keyring poetry install --no-interaction" \
            || die "poetry install failed after retries (output above). The services are still running the previous code; fix the error (network, disk space) and re-run."
    else
        retry as_app "$RAVEN_VENV/bin/pip" install -q -e "$SERVER_SRC_DIR" \
            || die "pip install failed after retries (output above). The services are still running the previous code; re-run when fixed."
    fi
    # poetry-dynamic-versioning rewrites this on install; keep the tree clean.
    as_app git -C "$SERVER_SRC_DIR" checkout -- raven/__init__.py 2>/dev/null || true
    ok "dependencies installed"
else
    warn "SKIP_BACKEND=1 -- backend left untouched"
fi

# ---- frontend ------------------------------------------------------------------
UI_STAMP="$RAVEN_DATA_DIR/.ui-deployed-commit"
NEW_UI_COMMIT="$PREV_UI_COMMIT"
if [[ "$SKIP_UI" != 1 ]]; then
    log "Updating c4raven-ui"
    # yarn.lock: a plain `yarn install` rewrote it on some older installs and
    # that blocks every later pull; the build uses --immutable anyway.
    git_update "$UI_SRC_DIR" "$UI_REPO" "$UI_BRANCH" src/_versions.ts yarn.lock
    NEW_UI_COMMIT="$(as_app git -C "$UI_SRC_DIR" rev-parse --short HEAD)"
    DEPLOYED_UI="$(as_app cat "$UI_STAMP" 2>/dev/null || true)"
    if [[ "$FORCE_UI_BUILD" != 1 && "$DEPLOYED_UI" == "$NEW_UI_COMMIT" ]] && as_root test -f "$UI_DEPLOY_DIR/index.html"; then
        ok "UI $NEW_UI_COMMIT already built and deployed (FORCE_UI_BUILD=1 to rebuild)"
    else
        as_app_sh 'command -v corepack' >/dev/null 2>&1 \
            || die "corepack not found (needed for the yarn version c4raven-ui pins). Install Node 22 with corepack, or: sudo npm install -g corepack"
        log "Building UI $NEW_UI_COMMIT"
        retry as_app_sh "cd $(printf '%q' "$UI_SRC_DIR") && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn install --immutable" \
            || die "yarn install failed after retries (output above). The old UI is still deployed."
        if ! as_app_sh "cd $(printf '%q' "$UI_SRC_DIR") && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn build"; then
            free -h 2>/dev/null || true
            die "The UI build failed (output above); the old UI is still deployed. If it was killed, the machine is short of memory: add 2 GB of swap and re-run."
        fi
        as_app git -C "$UI_SRC_DIR" checkout -- src/_versions.ts 2>/dev/null || true
        as_root test -f "$UI_SRC_DIR/dist/index.html" || die "The UI build produced no dist/index.html; the old UI is still deployed."
        log "Deploying UI to $UI_DEPLOY_DIR"
        as_root mkdir -p "$UI_DEPLOY_DIR"
        as_root rsync -a --no-perms --no-owner --no-group --omit-dir-times --delete \
            "$UI_SRC_DIR/dist/" "$UI_DEPLOY_DIR/" || die "UI deploy to $UI_DEPLOY_DIR failed (rsync exit $?)"
        [[ "$LAYOUT" == raven ]] && as_root chown -R "$RAVEN_USER:$RAVEN_USER" "$UI_DEPLOY_DIR"
        # SELinux (EL): files rsync creates under /var/www get the wrong label
        # and nginx 403s them. No-op where restorecon doesn't exist.
        command -v restorecon >/dev/null 2>&1 && { as_root restorecon -R "$UI_DEPLOY_DIR" >/dev/null 2>&1 || true; }
        as_app_sh "printf '%s\n' $(printf '%q' "$NEW_UI_COMMIT") > $(printf '%q' "$UI_STAMP")" || true
        fixed "UI $PREV_UI_COMMIT -> $NEW_UI_COMMIT deployed"
    fi
else
    warn "SKIP_UI=1 -- frontend left untouched"
fi

# ---- settings -------------------------------------------------------------------
log "Settings"
if out=$(config_add_keys "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER" "$RAVEN_HOME/.raven-secrets.env"); then
    if [[ -n "$out" ]]; then fixed "config.yml: added $(echo "$out" | tr '\n' ' ')"; else ok "config.yml left as it is (new settings use the code's defaults)"; fi
else
    warn "could not add new settings to config.yml (above); the built-in defaults apply"
fi
if out=$(config_drop_retired "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER"); then
    [[ -n "$out" ]] && fixed "config.yml: removed the retired default of $out"
else
    warn "could not remove retired settings from config.yml (above)"
fi
# MediaMTX's webhook token: a mediamtx.yml still holding the placeholder
# makes every stream's auth callback fail.
MTX_YML="$RAVEN_DATA_DIR/mediamtx/mediamtx.yml"
if as_root test -f "$MTX_YML" && as_root grep -q MTX_TOKEN "$MTX_YML"; then
    tok="$(config_get "$PYTHON" "$RAVEN_DATA_DIR/config.yml" "$APP_OWNER" RAVEN_MEDIAMTX_TOKEN)"
    if [[ -n "$tok" ]]; then
        as_root sed -i "s~MTX_TOKEN~$tok~g" "$MTX_YML"
        fixed "filled in MediaMTX's webhook token"
    fi
fi

# ---- database --------------------------------------------------------------------
MAIN_SERVICE="${RAVEN_SERVICES%% *}"
# Units that run backend code: stop them so nothing queries a half-migrated
# schema (mediamtx and federation-hub can stay up).
APP_UNITS=""
for u in $RAVEN_SERVICES; do
    case "$u" in mediamtx*|federation-hub*) ;; *) APP_UNITS="$APP_UNITS $u" ;; esac
done
log "Migrating the database"
if [[ "$HAS_SYSTEMD" == 1 ]]; then
    # shellcheck disable=SC2086
    as_root systemctl stop $APP_UNITS 2>/dev/null || true
else
    warn "no systemd: migrating while the services keep running; restart them afterwards"
fi
MIGRATE_OK=1
db_migrate "$APP_OWNER" "$RAVEN_VENV" "$RAVEN_DATA_DIR" "$WORKDIR" || MIGRATE_OK=0
if [[ "$MIGRATE_OK" == 0 ]]; then
    warn "DATABASE MIGRATION FAILED. The services are being started anyway (they retry the migration on startup). To roll back, see README.md 'Rolling back' with $BACKUP_DIR."
fi

# ---- nginx -----------------------------------------------------------------------
if [[ "$SKIP_NGINX" != 1 ]]; then
    log "Applying nginx template fixes"
    nginx_harden || true
fi

fix_log_ownership "$APP_OWNER" "$RAVEN_DATA_DIR/logs" "$MAIN_LOG" || true

# ---- restart and verify ------------------------------------------------------------
if [[ "$LAYOUT" == raven ]] && unit_active federation-hub; then
    RAVEN_SERVICES="$RAVEN_SERVICES federation-hub.service"
fi
log "Restarting: $RAVEN_SERVICES"
# shellcheck disable=SC2086
svc restart $RAVEN_SERVICES || warn "systemctl restart reported an error"

HEALTHY=0
if [[ "$HAS_SYSTEMD" == 1 ]] || curl -s -o /dev/null --max-time 3 "$HEALTH_URL"; then
    log "Waiting for $HEALTH_URL"
    if wait_healthy "$HEALTH_URL" "$HEALTH_TRIES"; then
        HEALTHY=1; ok "healthy: $HEALTH_URL returned 200"
    else
        warn "no 200 from $HEALTH_URL after $((HEALTH_TRIES * 2))s. Check: sudo journalctl -u $MAIN_SERVICE -n 100, and $RAVEN_DATA_DIR/logs/"
    fi
fi
if [[ "$HAS_SYSTEMD" == 1 ]]; then
    for s in $RAVEN_SERVICES; do
        st="$(unit_state "$s")"
        [[ "$st" == active ]] || warn "$s is $st -- check: sudo journalctl -u $s -n 100"
    done
fi

DB_REV_AFTER="$(db_revisions "$APP_OWNER" "$RAVEN_VENV" "$RAVEN_DATA_DIR" "$WORKDIR" current || true)"
DB_HEAD="$(db_revisions "$APP_OWNER" "$RAVEN_VENV" "$RAVEN_DATA_DIR" "$WORKDIR" heads || true)"
if [[ -n "$DB_HEAD" && "$DB_REV_AFTER" == "$DB_HEAD" ]]; then
    ok "database at head ($DB_HEAD)"
else
    warn "database is at '${DB_REV_AFTER:-?}', code head is '${DB_HEAD:-?}'"
fi
# New scheduled jobs reach the job store when the app starts (raven/app.py
# add_new_jobs_to_config); confirm the ones this release added are there.
if [[ "$HEALTHY" == 1 && "$DB_URI" == postgresql* ]]; then
    sleep 3
    jobs="$(as_app "$PYTHON" -c '
import sys, sqlalchemy as sa
e = sa.create_engine(sys.argv[1])
with e.connect() as c:
    print(" ".join(r[0] for r in c.execute(sa.text("SELECT id FROM apscheduler_jobs"))))
' "$DB_URI" 2>/dev/null || true)"
    # Space-separated; extend when a release adds scheduled jobs.
    NEW_JOBS="expire_group_memberships"
    for j in $NEW_JOBS; do
        if as_app grep -q "\"$j\"" "$SERVER_SRC_DIR/raven/defaultconfig.py" 2>/dev/null; then
            case " $jobs " in
                *" $j "*) ok "scheduled job $j registered" ;;
                *) warn "scheduled job $j is not in the job store yet (it is added when $MAIN_SERVICE starts; check its log)" ;;
            esac
        fi
    done
fi

# ---- Federation Hub ---------------------------------------------------------------
# Never fails the update. Legacy layout: check only (its Federation Hub was set
# up by hand and is left exactly as it is).
if [[ "$LAYOUT" == legacy ]]; then
    export RAVEN_USER="$APP_OWNER" RAVEN_DATA_DIR RAVEN_VENV RAVEN_SECRETS_FILE="" RAVEN_MAIN_UNIT=raven
else
    export RAVEN_USER="$APP_OWNER" RAVEN_HOME RAVEN_DATA_DIR RAVEN_VENV
fi
fedhub_section "$LAYOUT"

echo
echo "Update finished ($LAYOUT layout)."
echo
cat <<EOF
Backup:          $BACKUP_DIR
Backend:         $PREV_COMMIT -> $NEW_COMMIT
UI:              $PREV_UI_COMMIT -> $NEW_UI_COMMIT
Database:        ${DB_REV_BEFORE:-?} -> ${DB_REV_AFTER:-?}
EOF
print_summary
echo
echo "If anything looks wrong, README.md 'Rolling back' explains how to restore from the backup above."
[[ "$MIGRATE_OK" == 1 ]] || exit 1
