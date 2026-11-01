# Shared helpers for update.sh and finish-install.sh. Sourced, not run.
#
# Everything here is safe to call more than once: each repair checks the
# current state first and only changes what is missing or out of date.
# shellcheck shell=bash

# ---- output -----------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BLU=$'\033[1;34m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_BLU=''; C_GRN=''; C_YEL=''; C_RED=''; C_OFF=''
fi
log()  { printf '\n%s==>%s %s\n' "$C_BLU" "$C_OFF" "$1"; }
ok()   { printf '%s    ok:%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
fixed(){ printf '%s fixed:%s %s\n' "$C_GRN" "$C_OFF" "$1"; SUMMARY_FIXED+=("$1"); }
warn() { printf '%s  warn:%s %s\n' "$C_YEL" "$C_OFF" "$1" >&2; SUMMARY_WARN+=("$1"); }
die()  { printf '\n%sERROR: %s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit 1; }
SUMMARY_FIXED=()
SUMMARY_WARN=()

# ---- privilege --------------------------------------------------------------
# Normally run as an ordinary sudo-capable user. Root works too (a Docker
# container usually has no other account, and often no sudo binary).
IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1
if [ "$IS_ROOT" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  die "sudo is not installed and you are not root. Run this as root or install sudo."
fi

as_root() {
  if [ "$IS_ROOT" = 1 ]; then "$@"; else sudo "$@"; fi
}

# as_user USER CMD...  -- run CMD (argv, not a string) as USER through a login
# shell, so that user's ~/.local/bin (poetry) is on PATH. `cd /` first: USER
# may not be able to read the directory this script was started from.
as_user() {
  local u=$1; shift
  if [ "$(id -un)" = "$u" ]; then
    (cd / && "$@")
  elif [ "$IS_ROOT" = 1 ]; then
    runuser -u "$u" -- bash -lc "cd / && $(printf '%q ' "$@")"
  else
    sudo -u "$u" -H bash -lc "cd / && $(printf '%q ' "$@")"
  fi
}

# as_user_sh USER 'shell string' -- same, for a pipeline or a cd.
as_user_sh() {
  local u=$1 s=$2
  if [ "$(id -un)" = "$u" ]; then
    (cd / && bash -c "$s")
  elif [ "$IS_ROOT" = 1 ]; then
    runuser -u "$u" -- bash -lc "cd / && $s"
  else
    sudo -u "$u" -H bash -lc "cd / && $s"
  fi
}

as_postgres() {
  as_user_sh postgres "$1"
}

# ---- retries ------------------------------------------------------------------
# retry CMD...  -- up to RETRY_ATTEMPTS tries (default 5), waiting 5s, 10s,
# 20s, 40s between them. For network operations only (git, pip/poetry, yarn,
# curl, apt/dnf): a flaky link or a mirror hiccup should not leave an update
# half done. A deterministic failure still fails, just a minute later.
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-5}"
retry() {
  local n=1 delay=5 rc
  while true; do
    "$@" && return 0
    rc=$?
    if [ "$n" -ge "$RETRY_ATTEMPTS" ]; then
      printf '%s  warn:%s gave up after %d attempts (exit %d): %s\n' "$C_YEL" "$C_OFF" "$n" "$rc" "$*" >&2
      return "$rc"
    fi
    printf '%s  warn:%s attempt %d/%d failed (exit %d), retrying in %ds: %s\n' \
      "$C_YEL" "$C_OFF" "$n" "$RETRY_ATTEMPTS" "$rc" "$delay" "$*" >&2
    sleep "$delay"
    n=$((n + 1)); delay=$((delay * 2))
  done
}

# ---- distro facts -------------------------------------------------------------
# The same facts c4raven-server-setup's lib/distro.sh derives, kept minimal.
DISTRO_FAMILY=debian
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*) DISTRO_FAMILY=rhel ;;
  esac
fi
# shellcheck disable=SC2034  # used by finish-install.sh
if [ "$DISTRO_FAMILY" = rhel ]; then
  NGINX_SITES_DIR=/etc/nginx/conf.d;      NGINX_SITES_ENABLED_DIR=""
  NGINX_STREAMS_DIR=/etc/nginx/stream.d;  NGINX_STREAMS_ENABLED_DIR=""
  NGINX_CONF_SUFFIX=".conf"
  PKG_MGR=dnf
else
  NGINX_SITES_DIR=/etc/nginx/sites-available
  NGINX_SITES_ENABLED_DIR=/etc/nginx/sites-enabled
  NGINX_STREAMS_DIR=/etc/nginx/streams-available
  NGINX_STREAMS_ENABLED_DIR=/etc/nginx/streams-enabled
  NGINX_CONF_SUFFIX=""
  PKG_MGR=apt
fi
# shellcheck disable=SC2034
NGINX_CONF=/etc/nginx/nginx.conf
nginx_site_file()   { printf '%s/%s%s' "$NGINX_SITES_DIR" "$1" "$NGINX_CONF_SUFFIX"; }
nginx_stream_file() { printf '%s/%s%s' "$NGINX_STREAMS_DIR" "$1" "$NGINX_CONF_SUFFIX"; }

# pkg_install PKG...  -- with retries; apt never prompts.
pkg_install() {
  if [ "$PKG_MGR" = apt ]; then
    retry as_root env DEBIAN_FRONTEND=noninteractive apt-get update -q || true
    retry as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
  else
    retry as_root dnf install -y -q "$@"
  fi
}

# ---- systemd or not -------------------------------------------------------------
# Inside a container whose PID 1 is not systemd (plain `docker run`), there is
# no service manager to restart anything with. Don't crash on that: do every
# step that doesn't need it, and list what the user has to (re)start by hand.
# RAVEN_NO_SYSTEMD=1 forces this mode (tests use it).
HAS_SYSTEMD=0
if [ "${RAVEN_NO_SYSTEMD:-0}" != 1 ] && [ -d /run/systemd/system ] \
   && [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ] && command -v systemctl >/dev/null 2>&1; then
  HAS_SYSTEMD=1
fi
MANUAL_RESTARTS=()

systemd_notice() {
  [ "$HAS_SYSTEMD" = 1 ] && return 0
  warn "PID 1 is not systemd ($(cat /proc/1/comm 2>/dev/null || echo unknown)) -- this looks like a container started without systemd. Service restarts are skipped; you will get a list of what to restart yourself at the end. For a fully managed container, run it with systemd as PID 1 (see c4raven-server-setup's tests/images Dockerfiles)."
}

unit_exists() {
  [ "$HAS_SYSTEMD" = 1 ] || { [ -f "/etc/systemd/system/$1.service" ] || [ -f "/etc/systemd/system/$1" ] || [ -f "/lib/systemd/system/$1.service" ] || [ -f "/usr/lib/systemd/system/$1.service" ]; return; }
  systemctl cat "$1" >/dev/null 2>&1
}
unit_active() {
  [ "$HAS_SYSTEMD" = 1 ] || return 1
  systemctl is-active --quiet "$1" 2>/dev/null
}
unit_state() {
  if [ "$HAS_SYSTEMD" = 1 ]; then systemctl is-active "$1" 2>/dev/null || true; else echo "unmanaged"; fi
}
svc() {
  # svc ACTION UNIT...   (restart|start|stop|enable|reload|daemon-reload)
  local action=$1; shift
  if [ "$HAS_SYSTEMD" = 1 ]; then
    if [ "$action" = daemon-reload ]; then as_root systemctl daemon-reload; else as_root systemctl "$action" "$@"; fi
  else
    case "$action" in
      restart|start|reload) local u; for u in "$@"; do MANUAL_RESTARTS+=("$u"); done ;;
    esac
    return 0
  fi
}

# ---- config.yml -----------------------------------------------------------------
# Settings to add to an existing config.yml when it lacks them, one per line:
# KEY<TAB>YAML value. Empty on purpose for 2.3.0: config.yml is loaded after
# the service's environment, so a key written here would silently override an
# admin's env setting, and the app already falls back to raven/defaultconfig.py
# for every key config.yml lacks (RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH
# defaults to True that way). Only list a key here if the code's default is
# NOT what existing installs should get.
NEW_CONFIG_KEYS=""

# config_add_keys PYTHON CONFIG_FILE OWNER [ENV_FILE]
# Appends only the missing keys, as text, so admins' formatting and comments
# survive; then re-parses the file and leaves it untouched if that fails.
# A key the service's environment file already sets is skipped too: config.yml
# is loaded after the environment, so writing it there would override the
# admin's choice. Prints one line per key added.
config_add_keys() {
  local py=$1 cfg=$2 owner=$3 envf=${4:-}
  [ -n "$NEW_CONFIG_KEYS" ] || return 0
  as_user "$owner" "$py" - "$cfg" "$NEW_CONFIG_KEYS" "$envf" <<'PY'
import os, shutil, sys, time, yaml
path, spec, envf = sys.argv[1], sys.argv[2], sys.argv[3]
env_keys = set()
if envf and os.path.isfile(envf):
    env_keys = {l.split("=", 1)[0].strip() for l in open(envf) if "=" in l and not l.lstrip().startswith("#")}
with open(path) as f:
    text = f.read()
conf = yaml.safe_load(text) or {}
if not isinstance(conf, dict):
    sys.exit(f"{path} is not a YAML mapping; not touching it")
missing = []
for line in spec.splitlines():
    key, value = line.split("\t", 1)
    if key not in conf and key not in env_keys:
        missing.append((key, yaml.safe_load(value)))
if not missing:
    sys.exit(0)
backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(path, backup)
add = "" if text.endswith("\n") or not text else "\n"
for key, value in missing:
    add += yaml.safe_dump({key: value}, default_flow_style=False)
tmp = f"{path}.tmp-{os.getpid()}"
with open(tmp, "w") as f:
    f.write(text + add)
shutil.copymode(path, tmp)
check = yaml.safe_load(open(tmp))
if not all(check.get(k) == v for k, v in missing):
    os.unlink(tmp)
    sys.exit("re-parsing config.yml after the edit failed; left unchanged")
os.replace(tmp, path)
for key, value in missing:
    print(f"{key}: {value!r}")
PY
}

# config_get PYTHON CONFIG_FILE OWNER KEY
config_get() {
  as_user "$3" "$1" -c 'import sys, yaml; v = (yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2]); print("" if v is None else v)' "$2" "$4"
}

# config_set PYTHON CONFIG_FILE OWNER KEY VALUE  (string value; safe_dump rewrite,
# which is how install.sh writes config.yml in the first place)
config_set() {
  as_user "$3" "$1" - "$2" "$4" "$5" <<'PY'
import shutil, sys, time, yaml
path, key, value = sys.argv[1:4]
conf = yaml.safe_load(open(path)) or {}
shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
conf[key] = value
with open(path, "w") as f:
    yaml.safe_dump(conf, f)
PY
}

# fix_log_ownership OWNER DIR [MAIN_LOG] -- systemd (as root) creates a missing
# StandardOutput=append: file as root; the app's error-log viewer reads them
# as OWNER. Make sure the directory and raven.log exist owned by OWNER, and
# chown any log there that isn't.
fix_log_ownership() {
  local owner=$1 dir=$2 main=${3:-} n
  as_root install -d -o "$owner" -g "$(id -gn "$owner")" "$dir"
  if [ -n "$main" ] && ! as_root test -e "$dir/$main"; then
    as_root install -o "$owner" -g "$(id -gn "$owner")" -m 644 /dev/null "$dir/$main"
  fi
  [ "$(as_root stat -c %U "$dir")" = "$owner" ] || { as_root chown "$owner:" "$dir"; fixed "$dir now owned by $owner"; }
  n=$(as_root find "$dir" -maxdepth 1 -name '*.log*' ! -user "$owner" 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || return 0
  as_root find "$dir" -maxdepth 1 -name '*.log*' ! -user "$owner" -exec chown "$owner:" {} + \
    && fixed "made $n log file(s) in $dir owned by $owner"
}

# ---- nginx ----------------------------------------------------------------------
# Site files whose blocks do NOT verify a client certificate, under every name
# they have had: raven_* (install.sh / packages) and ots_* (the legacy box).
# Their proxied locations must blank X-Ssl-Cert, or a client could send its own
# header and be taken for the holder of any certificate it likes.
NGINX_NO_MTLS_SITES="raven_http raven_certificate_enrollment raven_certificate_enrollment_domain ots_http ots_certificate_enrollment ots_certificate_enrollment_domain"
# Sites that carry the WHEP follow-up location (any of them, both layouts).
NGINX_WHEP_SITES="raven_http raven_https ots_http ots_https"

# Real files (symlinks resolved, de-duplicated) for the given site names.
nginx_real_files() {
  local name dir f seen=" "
  for name in "$@"; do
    for dir in /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d; do
      for f in "$dir/$name" "$dir/$name.conf"; do
        as_root test -e "$f" || continue
        f=$(as_root readlink -f "$f")
        case "$seen" in *" $f "*) continue ;; esac
        seen="$seen$f "
        printf '%s\n' "$f"
      done
    done
  done
}

# Where the installer's files come from (nginx templates, mediamtx.yml,
# seed_admin.py, and the shared X-Ssl-Cert patcher). A local checkout works
# too: SETUP_REPO_RAW=file:///path/to/c4raven-server-setup
SETUP_REPO_RAW="${SETUP_REPO_RAW:-https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master}"

# nginx_whep_patch FILE -- widen the WHEP follow-up location (setup 4f27bd8)
# so stream paths with slashes (TAK ICU's live/VIDEO_1) reach MediaMTX.
# Prints what it changed, nothing if there was nothing to do.
nginx_whep_patch() {
  as_root python3 - "$1" <<'PY'
import os, sys
path = sys.argv[1]
old, new = "location ~ ^/[^/]+/whep(/.*)?$ {", "location ~ ^/.+/whep(/.*)?$ {"
s = open(path).read()
n = s.count(old)
if n:
    st = os.stat(path)
    tmp = path + ".c4raven-tmp"
    with open(tmp, "w") as f:
        f.write(s.replace(old, new))
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, path)
    print(f"widened the WHEP follow-up location ({n})")
PY
}

# nginx_harden -- bring existing site files in line with the current
# templates, in place (they may have been edited by certbot or the admin, so
# they are never replaced wholesale):
#   - non-mTLS sites: blank client-supplied X-Ssl-Cert, using the setup repo's
#     own lib/nginx_clear_ssl_cert.py so installer and updater patch alike
#   - the WHEP follow-up location regex
# Each changed file is first copied to /etc/nginx/raven-backups/<time>/
# (outside nginx's include globs). Then nginx -t: reload on success, restore
# every file on failure. Idempotent.
nginx_harden() {
  command -v nginx >/dev/null 2>&1 || as_root test -x /usr/sbin/nginx || { warn "nginx not installed; skipping the nginx fixes"; return 0; }
  local ts bdir f out n changed=() backups=() nomtls whep patcher bk
  ts=$(date +%Y%m%d-%H%M%S)
  bdir=/etc/nginx/raven-backups/$ts
  # shellcheck disable=SC2086  # space-separated name lists
  nomtls=$(nginx_real_files $NGINX_NO_MTLS_SITES)
  # shellcheck disable=SC2086
  whep=$(nginx_real_files $NGINX_WHEP_SITES)
  if [ -z "$nomtls$whep" ]; then
    warn "no Raven nginx site files found (looked for raven_* and ots_* in sites-available, sites-enabled, conf.d)"
    return 0
  fi
  backup_once() {
    bk="$bdir/$(echo "$1" | tr / _)"
    as_root test -e "$bk" && return 0
    as_root mkdir -p "$bdir" && as_root cp -a "$1" "$bk" || return 1
    changed+=("$1"); backups+=("$bk")
  }
  if [ -n "$nomtls" ]; then
    patcher=$(mktemp)
    if retry curl -fsSL "$SETUP_REPO_RAW/lib/nginx_clear_ssl_cert.py" -o "$patcher" && grep -q 'def patch' "$patcher"; then
      chmod 644 "$patcher"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Dry run on a copy first, so only files that change get a backup.
        n=$(as_root python3 -c 'import sys, runpy; m = runpy.run_path(sys.argv[1]); print(m["patch"](open(sys.argv[2]).read())[1])' "$patcher" "$f") || { warn "could not read $f"; continue; }
        [ "$n" -gt 0 ] 2>/dev/null || continue
        backup_once "$f" || { warn "could not back up $f; left it unpatched"; continue; }
        out=$(as_root python3 "$patcher" "$f") || { warn "patching $f failed: $out"; continue; }
        echo "    $out"
      done <<< "$nomtls"
    else
      warn "could not fetch lib/nginx_clear_ssl_cert.py from $SETUP_REPO_RAW, so the X-Ssl-Cert fix was NOT applied. Re-run when GitHub is reachable (or set SETUP_REPO_RAW to a local c4raven-server-setup checkout)."
    fi
    rm -f "$patcher"
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    as_root grep -qF 'location ~ ^/[^/]+/whep(/.*)?$ {' "$f" || continue
    backup_once "$f" || { warn "could not back up $f; left it unpatched"; continue; }
    out=$(nginx_whep_patch "$f") && [ -n "$out" ] && echo "    $f: $out"
  done <<< "$whep"
  if [ "${#changed[@]}" -eq 0 ]; then
    ok "nginx sites already have the current fixes"
    return 0
  fi
  if as_root nginx -t >/dev/null 2>&1; then
    nginx_reload
    fixed "nginx: patched ${#changed[@]} site file(s) (originals in $bdir)"
  else
    as_root nginx -t || true
    local i
    for i in "${!changed[@]}"; do as_root cp -a "${backups[$i]}" "${changed[$i]}"; done
    warn "nginx -t rejected the patched files, so every change was rolled back (nginx config is as it was). Copies: $bdir"
    return 1
  fi
}

nginx_reload() {
  if [ "$HAS_SYSTEMD" = 1 ]; then
    if unit_active nginx; then as_root systemctl reload nginx; else as_root systemctl restart nginx || warn "nginx would not start: sudo journalctl -u nginx -n 50"; fi
  elif as_root test -s /run/nginx.pid; then
    as_root nginx -s reload
  else
    MANUAL_RESTARTS+=("nginx")
  fi
}

# ---- database -------------------------------------------------------------------
# flask_cmd OWNER VENV DATA_DIR WORKDIR ARGS...  -- the app's own CLI (create_app
# in CLI mode reads config.yml for the database URI).
flask_cmd() {
  local owner=$1 venv=$2 data=$3 wd=$4; shift 4
  as_user_sh "$owner" "cd $(printf '%q' "$wd") && FLASK_APP=raven.app RAVEN_DATA_FOLDER=$(printf '%q' "$data") $(printf '%q' "$venv/bin/flask") $(printf '%q ' "$@")"
}

migrations_dir() {
  as_user "$1" "$2/bin/python" -c 'import os, raven; print(os.path.join(os.path.dirname(os.path.realpath(raven.__file__)), "migrations"))' 2>/dev/null | tail -1
}

# db_revisions OWNER VENV DATA WORKDIR current|heads -> sorted revision ids
db_revisions() {
  local mig
  mig=$(migrations_dir "$1" "$2")
  flask_cmd "$1" "$2" "$3" "$4" db "$5" -d "$mig" 2>/dev/null | grep -oE '^[0-9a-f]{12}\b' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# db_migrate OWNER VENV DATA WORKDIR  -- upgrade to head, then prove it.
db_migrate() {
  local owner=$1 venv=$2 data=$3 wd=$4 mig before after heads
  mig=$(migrations_dir "$owner" "$venv")
  [ -n "$mig" ] || { warn "could not locate the migrations directory in $venv"; return 1; }
  before=$(db_revisions "$owner" "$venv" "$data" "$wd" current)
  heads=$(db_revisions "$owner" "$venv" "$data" "$wd" heads)
  echo "    database at: ${before:-<empty>}; code head: ${heads:-?}"
  if [ -n "$before" ] && [ "$before" = "$heads" ]; then
    ok "database schema already at head ($heads)"
    return 0
  fi
  if ! flask_cmd "$owner" "$venv" "$data" "$wd" db upgrade -d "$mig"; then
    warn "flask db upgrade failed (output above)"
    return 1
  fi
  after=$(db_revisions "$owner" "$venv" "$data" "$wd" current)
  if [ -n "$after" ] && [ "$after" = "$heads" ]; then
    fixed "database migrated ${before:-<empty>} -> $after (head)"
  else
    warn "after upgrading, the database is at '${after:-?}' but the code's head is '${heads:-?}'"
    return 1
  fi
}

# pg_uri: SQLAlchemy URI -> libpq URI
pg_uri() { printf '%s' "${1/postgresql+psycopg:\/\//postgresql://}"; }

# Health check: 200 from URL within TRIES*2 seconds.
wait_healthy() {
  local url=$1 tries=${2:-45} i code
  for i in $(seq 1 "$tries"); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)
    [ "$code" = 200 ] && return 0
    sleep 2
  done
  return 1
}

print_summary() {
  local x
  if [ "${#SUMMARY_FIXED[@]}" -gt 0 ]; then
    echo "Changed:"
    for x in "${SUMMARY_FIXED[@]}"; do echo "  - $x"; done
  else
    echo "Changed: nothing (everything was already up to date)"
  fi
  if [ "${#SUMMARY_WARN[@]}" -gt 0 ]; then
    echo "Warnings:"
    for x in "${SUMMARY_WARN[@]}"; do echo "  - $x"; done
  fi
  if [ "${#MANUAL_RESTARTS[@]}" -gt 0 ]; then
    echo "No systemd here, so restart these yourself (or restart the container):"
    printf '  %s\n' "$(printf '%s\n' "${MANUAL_RESTARTS[@]}" | sort -u | tr '\n' ' ')"
  fi
}
