# Federation Hub helpers shared by both release forms (the .deb and the Docker
# zip): settings, the remembered answers, finding the release in ~/Downloads,
# the certificates, the Federation Hub YAML files, and connecting Raven to it.
# Sourced by install-fedhub.sh after lib/common.sh. Not run.
#
# Every path is overridable from the environment so tests can point it at a
# temporary directory; the defaults are the real locations.
# shellcheck shell=bash
# Settings and state here are read by fedhub_deb.sh / fedhub_docker.sh and
# install-fedhub.sh; `A && B || die` is the intended idiom throughout.
# shellcheck disable=SC2034,SC2015

# ---- settings -------------------------------------------------------------------
FEDHUB_ROOT="${FEDHUB_ROOT:-/opt/tak/federation-hub}"            # the .deb's home
FEDHUB_TAK_USER="${FEDHUB_TAK_USER:-tak}"                         # the .deb's service user
FEDHUB_DOCKER_BASE="${FEDHUB_DOCKER_BASE:-/opt/fedhub-docker}"   # <ver>/ per Docker release
FEDHUB_DOCKER_DB_DIR="${FEDHUB_DOCKER_DB_DIR:-/var/lib/fedhub-docker-mongodb}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SYSTEMD_LIB_DIRS="${SYSTEMD_LIB_DIRS:-/lib/systemd/system /usr/lib/systemd/system}"
FH_ROOT_OWNER="${FEDHUB_ROOT_OWNER:-root}"                     # tests: the current user
FEDHUB_MONGOD_BIN="${FEDHUB_MONGOD_BIN:-mongod}"
MONGOD_CONF="${MONGOD_CONF:-/etc/mongod.conf}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
KEYRING_DIR="${KEYRING_DIR:-/usr/share/keyrings}"
YUM_REPOS_DIR="${YUM_REPOS_DIR:-/etc/yum.repos.d}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
FEDHUB_TTY="${FEDHUB_TTY:-/dev/tty}"
FEDHUB_WAIT_SECS="${FEDHUB_WAIT_SECS:-120}"
FEDHUB_CA_NAME="${FEDHUB_CA_NAME:-C4Raven-FedHub-CA}"
FEDHUB_ADMIN_CN=fedhub-admin
FEDHUB_FEDERATE_CN=raven-federate
FEDHUB_PKG=takserver-fed-hub
FH_SELF="${FH_SELF:-$0}"
# Inside the Docker image the release's tak/ is mounted at /opt/tak.
FH_CONTAINER_HOME=/opt/tak/federation-hub
# Subject fields for the hub's own CA and certificates (03-generate-certs.sh).
# cert-metadata.sh refuses to run without STATE, CITY and ORGANIZATIONAL_UNIT.
FEDHUB_CERT_COUNTRY="${FEDHUB_CERT_COUNTRY:-WW}"
FEDHUB_CERT_STATE="${FEDHUB_CERT_STATE:-XX}"
FEDHUB_CERT_CITY="${FEDHUB_CERT_CITY:-YY}"
FEDHUB_CERT_ORG="${FEDHUB_CERT_ORG:-ZZ}"
FEDHUB_CERT_OU="${FEDHUB_CERT_OU:-C4Raven-FedHub}"

APP_USER="${RAVEN_USER:-raven}"
APP_HOME="${RAVEN_HOME:-/opt/raven}"
DATA_DIR="${RAVEN_DATA_DIR:-$APP_HOME/data}"
ANSWERS_FILE="${RAVEN_ANSWERS_FILE:-$APP_HOME/.install-answers}"
SECRETS_FILE="${RAVEN_SECRETS_FILE-$APP_HOME/.raven-secrets.env}"
RAVEN_MAIN_UNIT="${RAVEN_MAIN_UNIT:-raven}"
RABBIT_SERVICE="${RABBIT_SERVICE:-rabbitmq-server}"
CFG="$DATA_DIR/config.yml"

# Same backend detection as finish-install.sh: install.sh / online package =
# Poetry venv in the checkout; offline package = plain venv behind
# $APP_HOME/venv. RAVEN_VENV wins (update.sh passes the legacy layout's).
fh_detect_backend() {
  if as_root test -L "$APP_HOME/venv"; then
    VENV="${RAVEN_VENV:-$APP_HOME/venv}"
    WORKDIR="$DATA_DIR"
  else
    VENV="${RAVEN_VENV:-$APP_HOME/c4raven-server/.venv}"
    WORKDIR="$APP_HOME/c4raven-server"
  fi
  BIN_DIR="$VENV/bin"
  PY="$VENV/bin/python"
}

fh_q() { printf '%q' "$1"; }

# ---- small file helpers --------------------------------------------------------------
# fh_install_file MODE OWNER DEST  (content on stdin) -- returns 0 if it wrote
# DEST, 1 if DEST already had exactly that content (owner/mode untouched then).
fh_install_file() {
  local mode=$1 owner=$2 dest=$3 tmp rc=0
  tmp=$(mktemp)
  cat > "$tmp"
  if as_root test -f "$dest" && as_root cmp -s "$tmp" "$dest"; then
    rc=1
  else
    as_root mkdir -p "$(dirname "$dest")"
    as_root install -m "$mode" -o "$owner" -g "$(id -gn "$owner")" "$tmp" "$dest" || { rm -f "$tmp"; die "could not write $dest"; }
  fi
  rm -f "$tmp"
  return "$rc"
}

# A unit anywhere systemd looks (admin's /etc copy, a package's /lib one).
fh_unit_exists() {
  local u=$1 d
  for d in "$SYSTEMD_DIR" $SYSTEMD_LIB_DIRS; do
    as_root test -f "$d/$u.service" && return 0
  done
  [ "$HAS_SYSTEMD" = 1 ] && systemctl cat "$u.service" >/dev/null 2>&1
}

# ---- remembered answers ($APP_HOME/.install-answers, KEY=value) -------------------------
answers_get() {
  as_root test -f "$ANSWERS_FILE" || return 0
  as_root sed -n "s/^$1=//p" "$ANSWERS_FILE" | tail -n 1
}
answers_set() {
  local k=$1 v=$2 tmp
  as_root grep -qxF "$k=$v" "$ANSWERS_FILE" 2>/dev/null && return 0
  if ! as_root test -d "$(dirname "$ANSWERS_FILE")"; then
    warn "$(dirname "$ANSWERS_FILE") does not exist, so $k was not remembered"
    return 0
  fi
  tmp=$(mktemp)
  { as_root cat "$ANSWERS_FILE" 2>/dev/null | grep -v "^$k=" || true; printf '%s=%s\n' "$k" "$v"; } > "$tmp"
  as_root install -m 600 "$tmp" "$ANSWERS_FILE"
  rm -f "$tmp"
}

# ---- interaction -------------------------------------------------------------------------
# Prompts go to stderr; answers come from the terminal (FEDHUB_TTY, opened
# once), never from stdin, which may be a pipe.
FH_TTY_FD=""
fh_open_tty() {
  [ -n "$FH_TTY_FD" ] && return 0
  { exec {FH_TTY_FD}<"$FEDHUB_TTY"; } 2>/dev/null || { FH_TTY_FD=""; return 1; }
}
fh_interactive() {
  [ "${FH_YES:-0}" = 1 ] && return 1
  fh_open_tty
}
fh_ask() {  # fh_ask PROMPT VAR -- reads one line from the terminal into VAR
  local __line=""
  printf '%s' "$1" >&2
  IFS= read -r -u "$FH_TTY_FD" __line || { echo >&2; printf -v "$2" '%s' ""; return 1; }
  printf -v "$2" '%s' "$__line"
}

# The invoking user's home: the sudo user's when run through sudo.
fh_user_home() {
  local h=""
  [ -n "${SUDO_USER:-}" ] && h=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  printf '%s' "${h:-$HOME}"
}

# fh_clean_path TEXT -- what a user pastes or drags in: trims blanks, one
# pair of surrounding quotes, backslash-escaped spaces, and expands ~ / ~user.
fh_clean_path() {
  local p=$1 u rest h
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  if [ "${#p}" -ge 2 ] && { { [ "${p:0:1}" = "'" ] && [ "${p: -1}" = "'" ]; } || { [ "${p:0:1}" = '"' ] && [ "${p: -1}" = '"' ]; }; }; then
    p="${p:1:${#p}-2}"
  else
    p="${p//\\ / }"
  fi
  # shellcheck disable=SC2088  # matching a literal ~ the user typed
  case "$p" in
    "~")   p="$(fh_user_home)" ;;
    "~/"*) p="$(fh_user_home)/${p#\~/}" ;;
    "~"*)  u="${p#\~}"; u="${u%%/*}"; rest="${p#\~"$u"}"
           h=$(getent passwd "$u" | cut -d: -f6)
           [ -n "$h" ] && p="$h$rest" ;;
  esac
  printf '%s' "$p"
}

# ---- the release artifact ------------------------------------------------------------------
# fh_artifact_kind PATH -> deb | zip | "" (not a Federation Hub release)
fh_artifact_kind() {
  local f=$1 base
  [ -f "$f" ] || return 0
  base=$(basename "$f" | tr '[:upper:]' '[:lower:]')
  case "$base" in
    *fed*hub*.deb) echo deb ;;
    *.zip)
      # Any zip that holds a fedhub-docker release (tak/version.txt plus the
      # Dockerfiles), whatever it was renamed to.
      if python3 -I - "$f" >/dev/null 2>&1 <<'PY'
import sys, zipfile
names = zipfile.ZipFile(sys.argv[1]).namelist()
ok = any(n.endswith("tak/version.txt") for n in names) and any(n.endswith("docker/Dockerfile.fedhub") for n in names)
sys.exit(0 if ok else 1)
PY
      then echo zip; fi ;;
  esac
}

# Home directories to search: the sudo user's, $HOME, and whoever owns the
# current directory.
fh_search_homes() {
  local h owner seen=" "
  for h in "$(fh_user_home)" "$HOME" \
           "$(owner=$(stat -c %U . 2>/dev/null) && getent passwd "$owner" | cut -d: -f6)"; do
    [ -n "$h" ] && [ -d "$h/Downloads" ] || continue
    case "$seen" in *" $h "*) continue ;; esac
    seen="$seen$h "
    printf '%s\n' "$h"
  done
}

# fh_find_artifacts -- every candidate in ~/Downloads (maxdepth 3), one per line.
fh_find_artifacts() {
  local h
  while IFS= read -r h; do
    find "$h/Downloads" -maxdepth 3 -type f \( -iname '*fed*hub*.deb' -o -iname '*fed*hub*docker*.zip' \) -print 2>/dev/null || true
  done < <(fh_search_homes)
}

# fh_pick_artifact -- the best candidate for this distro: on RHEL only the
# Docker zip can work; on Debian/Ubuntu the .deb is preferred (native
# packages, no container engine needed). Newest by `sort -V` on the file name.
fh_pick_artifact() {
  local all debs zips pick
  all=$(fh_find_artifacts | sort -u)
  [ -n "$all" ] || return 0
  debs=$(printf '%s\n' "$all" | grep -iE '\.deb$' || true)
  zips=$(printf '%s\n' "$all" | grep -iE '\.zip$' || true)
  if [ "$DISTRO_FAMILY" = rhel ]; then pick=$zips
  elif [ -n "$debs" ]; then pick=$debs
  else pick=$zips; fi
  [ -n "$pick" ] || return 0
  printf '%s\n' "$pick" | while IFS= read -r p; do printf '%s\t%s\n' "${p##*/}" "$p"; done \
    | sort -t "$(printf '\t')" -k1,1V | tail -n 1 | cut -f2-
}

# fh_choose_artifact -- sets ARTIFACT, or exits 2 (skipped / declined /
# nothing found when nobody can be asked).
fh_choose_artifact() {
  local found ans p kind
  if [ "$(answers_get RAVEN_FEDHUB_DECLINED)" = 1 ]; then
    echo "Federation Hub: skipped (you chose 'never' earlier; run $FH_SELF --artifact PATH to install it anyway)."
    exit 2
  fi
  found=$(fh_pick_artifact)
  if [ -n "$found" ] && [ -z "$(fh_artifact_kind "$found")" ]; then found=""; fi
  if ! fh_interactive; then
    if [ -n "$found" ] && [ "${FH_YES:-0}" = 1 ]; then
      echo "Using the Federation Hub release found in Downloads: $found"
      ARTIFACT=$found
      return 0
    fi
    if [ -n "$found" ]; then
      echo "Federation Hub: found $found but nobody to confirm it (no terminal). Install it with: $FH_SELF --artifact $(fh_q "$found")"
    else
      echo "Federation Hub: no release found in ~/Downloads and no terminal to ask. Download it from tak.gov, then run: $FH_SELF --artifact /path/to/the/file"
    fi
    exit 2
  fi
  if [ -n "$found" ]; then
    echo "Found a Federation Hub release:" >&2
    echo "    $found" >&2
    fh_ask "Use it? [Y/n] " ans || ans=n
    case "$ans" in ''|[Yy]*) ARTIFACT=$found; return 0 ;; esac
  else
    echo "No Federation Hub release (takserver-fed-hub_*.deb or *fedhub-docker*.zip) found in ~/Downloads." >&2
  fi
  while true; do
    fh_ask "Path to the Federation Hub .deb or Docker .zip (Enter to skip, 'never' to stop asking): " ans || ans=""
    p=$(fh_clean_path "$ans")
    case "$p" in
      "") echo "Federation Hub: skipped."; exit 2 ;;
      never|NEVER|Never)
        answers_set RAVEN_FEDHUB_DECLINED 1
        echo "Federation Hub: skipped, and won't be offered again (run $FH_SELF --artifact PATH to install it later)."
        exit 2 ;;
    esac
    if [ ! -f "$p" ]; then echo "    no such file: $p" >&2; continue; fi
    kind=$(fh_artifact_kind "$p")
    if [ -z "$kind" ]; then echo "    not a Federation Hub .deb or Docker release zip: $p" >&2; continue; fi
    ARTIFACT=$(readlink -f "$p")
    return 0
  done
}

# fh_mode_for KIND -> sets MODE, or dies (a .deb on RHEL).
fh_mode_for() {
  case "$1" in
    deb)
      if [ "$DISTRO_FAMILY" = rhel ]; then
        die "$ARTIFACT is the Debian/Ubuntu package; it can't be installed on this $DISTRO_FAMILY system. Download the Federation Hub Docker release (a takserver-fed-hub-docker-<version>.zip) from tak.gov and run: $FH_SELF --artifact /path/to/that.zip"
      fi
      MODE=deb ;;
    zip) MODE=docker ;;
    *) die "$ARTIFACT is not a Federation Hub .deb or Docker release zip." ;;
  esac
}

# ---- host -----------------------------------------------------------------------------------
fh_default_ip() {
  hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$' || true
}
fh_valid_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

# fh_resolve_host -- sets HOST: --host (an explicit host change), else the
# host this script used last time (so an existing hub keeps its certificate
# name even when install.sh passes RAVEN_DOMAIN), else RAVEN_DOMAIN, else the
# domain install.sh recorded, else ask (default: this server's first IPv4).
fh_resolve_host() {
  local def ans
  HOST="${FH_HOST_ARG:-}"
  [ -n "$HOST" ] || HOST=$(answers_get RAVEN_FEDHUB_HOST)
  [ -n "$HOST" ] || HOST="${RAVEN_DOMAIN:-}"
  [ -n "$HOST" ] || HOST=$(answers_get RAVEN_DOMAIN)
  if [ -z "$HOST" ]; then
    def=$(fh_default_ip)
    if fh_interactive; then
      echo "Federation Hub's server certificate is issued for one name, and Raven must connect with exactly that name." >&2
      while true; do
        # EOF (Ctrl-D, or the terminal went away): stop rather than re-ask forever.
        fh_ask "Host name or IP clients and Raven will use for Federation Hub [${def:-none}]: " ans \
          || die "No host name given for Federation Hub (end of input): re-run with --host NAME."
        HOST=${ans:-$def}
        fh_valid_host "$HOST" && break
        echo "    '$HOST' is not a host name or IPv4 address" >&2
      done
    else
      HOST=$def
      [ -n "$HOST" ] && echo "    no host given; using this server's address $HOST (pass --host NAME to choose)"
    fi
  fi
  [ -n "$HOST" ] || die "No host name for Federation Hub: pass --host NAME."
  fh_valid_host "$HOST" || die "'$HOST' is not a valid host name or IPv4 address."
}

# ---- mode context -------------------------------------------------------------------------
# fh_set_context deb | docker VERSION -- where this release keeps its files.
#   FH_HOME   the federation-hub directory on the host
#   FH_FILES  its certs/files on the host
#   FH_REF    the same certs/files as written into the hub's YAML (container
#             path for Docker)
fh_set_context() {
  MODE=$1
  if [ "$MODE" = deb ]; then
    FH_HOME=$FEDHUB_ROOT
    FH_REF_HOME=$FEDHUB_ROOT
    FH_CERT_OWNER=$FEDHUB_TAK_USER
  else
    FH_VERSION=$2
    FH_DIR="$FEDHUB_DOCKER_BASE/$FH_VERSION"
    FH_HOME="$FH_DIR/tak/federation-hub"
    FH_REF_HOME=$FH_CONTAINER_HOME
    FH_CERT_OWNER=$FH_ROOT_OWNER
    FH_CONTAINER="fedhub-$FH_VERSION"
    FH_DB_CONTAINER="fedhub-db-$FH_VERSION"
  fi
  FH_CERTS="$FH_HOME/certs"
  FH_FILES="$FH_CERTS/files"
  FH_REF="$FH_REF_HOME/certs/files"
  FH_PWFILE="$FH_CERTS/.fedhub-cert-passwords"
  FH_BROKER_YML="$FH_HOME/configs/federation-hub-broker.yml"
  FH_UI_YML="$FH_HOME/configs/federation-hub-ui.yml"
  FH_AUTH_MARKER="$FH_HOME/.c4raven-admin-authorized"
}
# A path as the hub sees it -> the same file on the host.
fh_host_path() {
  case "$1" in
    "$FH_REF_HOME"/*) printf '%s%s' "$FH_HOME" "${1#"$FH_REF_HOME"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# fh_cert_sh 'shell' -- run in the certs directory as whoever owns the
# certificates: the tak user (.deb) or root inside the container (Docker).
# The passwords are sourced from the passwords file inside that shell, so
# they never appear on a command line (sudo logs those, ps shows them).
fh_cert_sh() {
  local pre
  pre="set -e; set -a; . ./.fedhub-cert-passwords; COUNTRY=$(fh_q "$FEDHUB_CERT_COUNTRY") STATE=$(fh_q "$FEDHUB_CERT_STATE") CITY=$(fh_q "$FEDHUB_CERT_CITY") ORGANIZATION=$(fh_q "$FEDHUB_CERT_ORG") ORGANIZATIONAL_UNIT=$(fh_q "$FEDHUB_CERT_OU"); set +a"
  if [ "$MODE" = deb ]; then
    as_user_sh "$FEDHUB_TAK_USER" "cd $(fh_q "$FH_CERTS") && $pre && $1" </dev/null
  else
    as_root docker exec "$FH_CONTAINER" bash -c "cd $FH_CONTAINER_HOME/certs && $pre && $1" </dev/null
  fi
}

# ---- certificates (both modes) ------------------------------------------------------------
# A dedicated CA for the hub, a server certificate for HOST, and two client
# certificates: fedhub-admin (admin API on 9100, and the browser login) and
# raven-federate (Raven's FIG connection to the broker on 9102), each with an
# unencrypted copy of its key for Raven. Each piece only if it's missing.
# fh_cert_passwords -- CAPASS and PASS, generated once into FH_PWFILE (0600,
# owned by the certificates' owner) and reused on every later run.
fh_cert_passwords() {
  local tmp
  as_root test -s "$FH_PWFILE" && return 0
  if as_root test -s "$FH_FILES/ca.pem"; then
    die "$FH_FILES/ca.pem exists but $FH_PWFILE doesn't, so the passwords of the existing keys are unknown. Create $FH_PWFILE (owner $FH_CERT_OWNER, mode 600) with two lines CAPASS=<CA key password> and PASS=<certificate password>, then re-run."
  fi
  as_root mkdir -p "$(dirname "$FH_PWFILE")"
  tmp=$(mktemp)
  printf 'CAPASS=%s\nPASS=%s\n' "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > "$tmp"
  as_root install -m 600 -o "$FH_CERT_OWNER" -g "$(id -gn "$FH_CERT_OWNER")" "$tmp" "$FH_PWFILE"
  rm -f "$tmp"
  fixed "generated the certificate passwords ($FH_PWFILE)"
}

fh_certs() {
  local cn rc
  log "Federation Hub certificates ($FH_FILES)"
  fh_cert_passwords
  if ! as_root test -s "$FH_FILES/ca.pem"; then
    fh_cert_sh "./makeRootCa.sh --ca-name $(fh_q "$FEDHUB_CA_NAME")" || die "makeRootCa.sh failed (output above)."
    FH_CHANGED=1; fixed "created the Federation Hub CA ($FEDHUB_CA_NAME)"
  fi
  if ! as_root test -s "$FH_FILES/$HOST.jks"; then
    fh_cert_sh "./makeCert.sh server $(fh_q "$HOST")" || die "makeCert.sh server $HOST failed (output above)."
    FH_CHANGED=1; fixed "issued the Federation Hub server certificate for $HOST"
  fi
  for cn in "$FEDHUB_ADMIN_CN" "$FEDHUB_FEDERATE_CN"; do
    if ! as_root test -s "$FH_FILES/$cn.pem" || ! as_root test -s "$FH_FILES/$cn.key"; then
      fh_cert_sh "./makeCert.sh client $cn" || die "makeCert.sh client $cn failed (output above)."
      FH_CHANGED=1; fixed "issued the client certificate $cn"
    fi
    # The unencrypted copy must belong to the current certificate: (re)write
    # it when it is missing, older than the .pem (the certificate was
    # reissued), or its public key differs from the certificate's.
    # Exit 3 = already matches.
    rc=0
    fh_cert_sh "k=files/$cn-unencrypted.key; p=files/$cn.pem
      if [ -s \"\$k\" ] && [ ! \"\$p\" -nt \"\$k\" ] \\
         && [ \"\$(openssl x509 -in \"\$p\" -noout -pubkey 2>/dev/null)\" = \"\$(openssl pkey -in \"\$k\" -pubout 2>/dev/null)\" ]; then exit 3; fi
      umask 077; rm -f \"\$k\"
      openssl rsa -in files/$cn.key -passin env:PASS -out \"\$k\" && chmod 600 \"\$k\"" || rc=$?
    case "$rc" in
      3) ;;
      0) fixed "wrote the unencrypted key for $cn (matching $cn.pem)" ;;
      *) die "could not write files/$cn-unencrypted.key (output above)." ;;
    esac
  done
  ok "CA, server certificate ($HOST) and client certificates present"
  fh_policy_ca
}

# ---- the federation policy -----------------------------------------------------------------
# The broker runs with useCaGroups: true, so a federate is only accepted when
# the CA that issued its certificate is a FederationGroup in the active
# policy; otherwise it refuses with "Federate/CA Group not found in the policy
# graph" -- which is what Raven's own bridge (raven-federate, issued by this
# hub's CA) hits on a fresh install. The policy manager reads the active
# policy from ui_generated_policy.json when it starts (and the UI saves it
# there and in policies/<name>.json), so the hub's CA is added to that file
# here, before the hub is (re)started, instead of through the admin API
# (which would need the hub up, then a save and an activation).
#
# A CA group's name is "<subject DN, RFC 2253>-<sha256 of the DER
# certificate>", exactly as Federation Hub's getKnownCaGroups reports it.
FH_POLICY_NAME="${FH_POLICY_NAME:-C4Raven}"
fh_policy_file() { printf '%s/ui_generated_policy.json' "$FH_HOME"; }
fh_ca_group_uid() {
  local ca=${1:-$FH_FILES/ca.pem} subj sum
  subj=$(as_root openssl x509 -in "$ca" -noout -subject -nameopt RFC2253 2>/dev/null) || return 1
  subj=${subj#subject=}; subj=${subj# }
  sum=$(as_root openssl x509 -in "$ca" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) || return 1
  [ -n "$subj" ] && [ "${#sum}" = 64 ] || return 1
  printf '%s-%s' "$subj" "$sum"
}

# fh_policy_ca_state UID -> "ok", "disabled", "missing" or "no-policy".
fh_policy_ca_state() {
  as_root python3 -I - "$(fh_policy_file)" "$1" <<'PY' 2>/dev/null || echo unreadable
import json, os, sys
path, uid = sys.argv[1], sys.argv[2]
if not os.path.isfile(path):
    print("no-policy"); sys.exit()
d = json.load(open(path))
for e in ((d.get("policy") or {}).get("entities") or []):
    if e.get("type") == "FederationGroup" and e.get("name") == uid:
        print("disabled" if (e.get("config") or {}).get("enabled") is False else "ok")
        break
else:
    print("missing")
PY
}

# fh_policy_ca -- make the hub's CA an enabled CA group in the active policy
# (creating a policy named FH_POLICY_NAME when there is none). Sets
# FH_CHANGED so the hub is restarted and loads it.
fh_policy_ca() {
  local uid out
  log "Federation policy"
  uid=$(fh_ca_group_uid) || die "could not read $FH_FILES/ca.pem to name the hub's CA group."
  if [ "$(fh_policy_ca_state "$uid")" = ok ]; then
    ok "the hub's CA ($FEDHUB_CA_NAME) is a CA group in the active policy"
    return 0
  fi
  out=$(as_root python3 -I - "$(fh_policy_file)" "$FH_HOME/policies" "$uid" "$FEDHUB_CA_NAME (this hub)" \
        "$FH_POLICY_NAME" "$(id -u "$FH_CERT_OWNER")" "$(id -g "$FH_CERT_OWNER")" <<'PY'
import datetime, json, os, shutil, sys, time, uuid
active, pdir, uid, display, default_name, owner, group = sys.argv[1:8]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")

def write(path, data):
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.chown(tmp, int(owner), int(group))
    os.replace(tmp, path)

def ensure(d):
    pol = d.get("policy")
    if not isinstance(pol, dict):
        d["policy"] = pol = {}
    ents = pol.setdefault("entities", [])
    pol.setdefault("rules", [])
    pol.setdefault("groupSets", [])
    for e in ents:
        if e.get("type") == "FederationGroup" and e.get("name") == uid:
            cfg = e.setdefault("config", {})
            if cfg.get("enabled") is False:
                cfg["enabled"] = True
                return "enabled"
            return ""
    eid = str(uuid.uuid4())
    ents.append({"id": eid, "type": "FederationGroup", "displayName": display, "name": uid,
                 "description": None,
                 "config": {"interconnected": False, "tokenAuthDuration": -1,
                            "allowTokenAuth": False, "enabled": True}})
    graph = d.setdefault("views", {}).setdefault("graph", {})
    graph.setdefault("nodes", []).append({"id": eid, "x": 200, "y": 100})
    graph.setdefault("settings", {"zoom": 1, "canvas_x": 0, "canvas_y": 0})
    return "added"

if os.path.isfile(active):
    d = json.load(open(active))
    created = False
else:
    d = {"name": default_name, "version": "v3", "creationDate": now, "modifiedDate": now,
         "policy": {"entities": [], "rules": [], "groupSets": []}, "plugins": [],
         "views": {"graph": {"nodes": [], "settings": {"zoom": 1, "canvas_x": 0, "canvas_y": 0}}}}
    created = True
what = ensure(d)
if not what and not created:
    sys.exit()
d["modifiedDate"] = now
if not created:
    shutil.copy2(active, f"{active}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
write(active, d)
# The stored copy the UI lists (policies/<name>.json) gets the same change.
name = d.get("name") or default_name
os.makedirs(pdir, exist_ok=True)
stored = os.path.join(pdir, f"{name}.json")
if os.path.isfile(stored):
    s = json.load(open(stored))
    if ensure(s):
        s["modifiedDate"] = now
        write(stored, s)
else:
    write(stored, d)
print(("created the policy " + name + " with " if created else what + " ") + "the hub's CA group")
PY
) || die "could not add the hub's CA group to $(fh_policy_file) (output above)."
  [ "$(fh_policy_ca_state "$uid")" = ok ] || die "the hub's CA group is still not in $(fh_policy_file)."
  FH_CHANGED=1
  fixed "federation policy: ${out:-updated}; Federation Hub will be restarted to load it"
}

# ---- the hub's YAML files ------------------------------------------------------------------
# fh_yml_set FILE KEY=VALUE...  -- as root, line by line so comments and the
# rest of the file survive; a missing key is appended. In VALUE, @PASS@ and
# @CAPASS@ become the passwords from FH_PWFILE (read inside the root process,
# never on a command line). KEY?=VALUE only sets KEY when it is missing,
# empty or the package's sample value, and @RANDOM@ is a fresh random
# password. Prints the names of the keys it changed; a backup of the file is
# kept next to it (it holds passwords, so it keeps the file's mode).
fh_yml_set() {
  local file=$1; shift
  as_root python3 -I - "$file" "$FH_PWFILE" "$@" <<'PY'
import os, re, secrets, shutil, sys, time
path, pwf, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
pw = {}
if os.path.isfile(pwf):
    for line in open(pwf):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            pw[k] = v
SAMPLE = {"", "pass4marti", "changeme", "null", "~"}
def quote(v, secret):
    # Numbers and booleans stay plain YAML scalars (clientTimeoutTime: 3600);
    # everything else, and every password, is a quoted string.
    return v if not secret and re.fullmatch(r"[0-9]+|true|false", v) else f'"{v}"'
with open(path) as f:
    lines = f.read().splitlines(True)
changed = []
for pair in pairs:
    key, value = pair.split("=", 1)
    only_default = key.endswith("?")
    key = key.rstrip("?")
    secret = "@" in value
    for name in ("PASS", "CAPASS"):
        token = "@" + name + "@"
        if token in value:
            if name not in pw:
                sys.exit(f"{pwf} has no {name}")
            value = value.replace(token, pw[name])
    if value == "@RANDOM@":
        value = secrets.token_hex(16)
    rx = re.compile(r"^" + re.escape(key) + r":(.*)$")
    for i, line in enumerate(lines):
        m = rx.match(line.rstrip("\r\n"))
        if not m:
            continue
        cur = m.group(1).strip()
        if len(cur) >= 2 and cur[0] == cur[-1] and cur[0] in "\"'":
            cur = cur[1:-1]
        if only_default and cur not in SAMPLE:
            break
        if cur != value:
            lines[i] = f'{key}: {quote(value, secret)}\n'
            changed.append(key)
        break
    else:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f'{key}: {quote(value, secret)}\n')
        changed.append(key)
if changed:
    shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    with open(path, "w") as f:   # in place: owner and mode stay
        f.writelines(lines)
    print(" ".join(changed))
PY
}

# fh_yml_get FILE KEY -- for settings that are not secrets.
fh_yml_get() {
  as_root python3 -I - "$1" "$2" <<'PY'
import re, sys
rx = re.compile(r"^" + re.escape(sys.argv[2]) + r":(.*)$")
for line in open(sys.argv[1]):
    m = rx.match(line.rstrip("\r\n"))
    if m:
        v = m.group(1).strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        print(v)
        break
PY
}

# fh_own_keystore PATH -- PATH (as the hub sees it) is a keystore this hub's
# makeCert.sh made: <name>.jks in its certs/files with a <name>.pem next to it
# issued by this hub's CA. A server certificate for an earlier host name is
# one of these; an admin's Let's Encrypt keystore is not.
fh_own_keystore() {
  local p=$1 base pem
  case "$p" in "$FH_REF"/*.jks) ;; *) return 1 ;; esac
  base=$(basename "$p" .jks)
  [ "$base" = takserver ] && return 0
  pem="$FH_FILES/$base.pem"
  as_root test -s "$pem" && as_root test -s "$FH_FILES/ca.pem" || return 1
  as_root openssl verify -no_check_time -CAfile "$FH_FILES/ca.pem" "$pem" >/dev/null 2>&1
}

# fh_ui_public -- the UI on 9100 serves a keystore the admin set up (the live
# box serves a Let's Encrypt one), not one of this hub's own. Read-only.
fh_ui_public() {
  local cur
  cur=$(fh_yml_get "$FH_UI_YML" keystoreFile 2>/dev/null || true)
  [ -n "$cur" ] && ! fh_own_keystore "$cur" && as_root test -s "$(fh_host_path "$cur")"
}

# fh_configure_ymls -- point the broker and the UI at this hub's certificates.
# The UI keystore is the exception: an admin who pointed it at another
# existing keystore (the live box serves a Let's Encrypt one on 9100) keeps
# it, with its password and alias. Sets FH_UI_PUBLIC=1 in that case.
fh_configure_ymls() {
  local out cur
  out=$(fh_yml_set "$FH_BROKER_YML" \
      "keystoreFile=$FH_REF/$HOST.jks" "keystorePassword=@PASS@" \
      "truststoreFile=$FH_REF/fed-truststore.jks" "truststorePassword=@CAPASS@" \
      "caFile=$FH_REF/ca.pem") || die "could not edit $FH_BROKER_YML"
  if [ -n "$out" ]; then FH_CHANGED=1; fixed "federation-hub-broker.yml: set $out"; fi
  # The package's clientTimeoutTime of 15 (seconds) drops every federate's
  # stream every 15s; an hour, as on the live hub. A value an admin chose stays.
  cur=$(fh_yml_get "$FH_BROKER_YML" clientTimeoutTime)
  if [ -z "$cur" ] || [ "$cur" = 15 ]; then
    out=$(fh_yml_set "$FH_BROKER_YML" "clientTimeoutTime=3600") || die "could not edit $FH_BROKER_YML"
    if [ -n "$out" ]; then FH_CHANGED=1; fixed "federation-hub-broker.yml: clientTimeoutTime 3600 (was ${cur:-unset})"; fi
  fi

  FH_UI_PUBLIC=0
  cur=$(fh_yml_get "$FH_UI_YML" keystoreFile)
  if fh_ui_public; then
    FH_UI_PUBLIC=1
    ok "UI keystore left as the admin set it: $cur"
    out=$(fh_yml_set "$FH_UI_YML" \
        "truststoreFile=$FH_REF/truststore-root.jks" "truststorePassword=@CAPASS@") || die "could not edit $FH_UI_YML"
  else
    out=$(fh_yml_set "$FH_UI_YML" \
        "keystoreFile=$FH_REF/$HOST.jks" "keystorePassword=@PASS@" "keyAlias=$HOST" \
        "truststoreFile=$FH_REF/truststore-root.jks" "truststorePassword=@CAPASS@") || die "could not edit $FH_UI_YML"
  fi
  if [ -n "$out" ]; then FH_CHANGED=1; fixed "federation-hub-ui.yml: set $out"; fi
  ok "broker and UI configuration point at the hub's certificates"
}

# The broker ports this configuration actually opens (the live box runs with
# v1Enabled: false, so nothing listens on 9101 there), plus the UI's 9100.
fh_expected_ports() {
  local v1 v2 ports=9100
  v1=$(fh_yml_get "$FH_BROKER_YML" v1Enabled 2>/dev/null || true)
  v2=$(fh_yml_get "$FH_BROKER_YML" v2Enabled 2>/dev/null || true)
  [ "$v1" = false ] || ports="$ports 9101"
  [ "$v2" = false ] || ports="$ports 9102"
  printf '%s' "$ports"
}

# fh_authorize_admin CMD... -- run the manager jar once for fedhub-admin.pem.
fh_admin_authorized() {
  as_root test -f "$FH_AUTH_MARKER" && return 0
  as_root grep -qE "username: *\"?$FEDHUB_ADMIN_CN\"?\$" "$FH_HOME/authorized_users.yml" 2>/dev/null
}
fh_mark_authorized() {
  printf '%s\n' "fedhub-admin.pem authorised $(date -u +%FT%TZ) by install-fedhub.sh" | fh_install_file 644 "$FH_CERT_OWNER" "$FH_AUTH_MARKER" || true
}

# ---- Raven ---------------------------------------------------------------------------------
# Values Raven's defaultconfig.py uses for a key nothing sets.
fh_raven_defaults_json() {
  local f="$FEDHUB_ROOT/certs/files"
  printf '{"RAVEN_FEDHUB_ENABLE": "True", "RAVEN_FEDHUB_FEDERATE_ENABLE": "True", "RAVEN_FEDHUB_CLIENT_CERT": "%s/fedhub-admin.pem", "RAVEN_FEDHUB_CLIENT_KEY": "%s/fedhub-admin-unencrypted.key", "RAVEN_FEDHUB_FEDERATE_CERT": "%s/raven-federate.pem", "RAVEN_FEDHUB_FEDERATE_KEY": "%s/raven-federate-unencrypted.key", "RAVEN_FEDHUB_FEDERATE_CA": "%s/ca.pem", "RAVEN_FEDHUB_FEDERATE_GROUP": "Fed group"}' "$f" "$f" "$f" "$f" "$f"
}

# fh_raven_setting KEY -- the value Raven ends up with: config.yml (loaded
# last), else the secrets file, else the code's default.
fh_raven_setting() {
  as_user "$APP_USER" "$PY" - "$CFG" "${SECRETS_FILE:-}" "$(fh_raven_defaults_json)" "$1" <<'PY' 2>/dev/null || true
import json, os, sys, yaml
cfg, envf, defaults, key = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
conf = (yaml.safe_load(open(cfg)) or {}) if os.path.isfile(cfg) else {}
env = {}
try:
    for l in open(envf):
        if "=" in l and not l.lstrip().startswith("#"):
            k, v = l.rstrip("\n").split("=", 1)
            env[k.strip()] = v
except (OSError, TypeError):
    pass
v = conf.get(key, env.get(key, defaults.get(key)))
print("" if v is None else v)
PY
}

# fh_wiring_problems -- empty output and status 0 when Raven is connected:
# Federation Hub and Raven's federate enabled, every certificate and key it is
# configured with readable by the app user, RAVEN_FEDHUB_CA_BUNDLE matching
# the certificate the UI on 9100 serves, (when this script recorded the host)
# the addresses using that host, the fedhub_bridge unit, and the hub's CA a
# CA group in the active federation policy. Read-only; never changes anything.
# Needs the mode context (fh_set_context, done by fh_detect).
fh_wiring_problems() {
  local host problems ui_public=0 hubca uid
  host=$(answers_get RAVEN_FEDHUB_HOST)
  if ! as_root test -f "$CFG"; then echo "no Raven config at $CFG"; return 1; fi
  fh_ui_public && ui_public=1
  hubca=$(as_root cat "$FH_FILES/ca.pem" 2>/dev/null || true)
  problems=$(fh_wiring_py "$host" "$ui_public" "$hubca" 2>&1) || true
  fh_unit_exists fedhub_bridge || problems="${problems:+$problems; }no fedhub_bridge.service"
  if uid=$(fh_ca_group_uid); then
    case "$(fh_policy_ca_state "$uid")" in
      ok) ;;
      no-policy) problems="${problems:+$problems; }no active federation policy ($(fh_policy_file)), so the broker refuses Raven's federate: run $FH_SELF to create one with the hub's CA group" ;;
      missing) problems="${problems:+$problems; }the hub's CA ($FEDHUB_CA_NAME) is not a CA group in the active federation policy, so the broker refuses Raven's federate: run $FH_SELF, or add it in the hub's admin console and activate the policy" ;;
      disabled) problems="${problems:+$problems; }the hub's CA group is disabled in the active federation policy: run $FH_SELF, or enable it in the hub's admin console" ;;
      *) problems="${problems:+$problems; }could not read the active federation policy $(fh_policy_file)" ;;
    esac
  else
    problems="${problems:+$problems; }could not read the hub's CA ($FH_FILES/ca.pem)"
  fi
  printf '%s' "$problems"
  [ -z "$problems" ]
}
# fh_wiring_py HOST UI_PUBLIC HUB_CA_PEM
fh_wiring_py() {
  as_user "$APP_USER" "$PY" - "$CFG" "${SECRETS_FILE:-}" "$(fh_raven_defaults_json)" "$1" "$2" "$3" <<'PY'
import json, os, sys, urllib.parse, yaml
cfg, envf, defaults, host, ui_public, hubca = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4], sys.argv[5] == "1", sys.argv[6].strip()
conf = yaml.safe_load(open(cfg)) or {}
env = {}
try:
    for l in open(envf):
        if "=" in l and not l.lstrip().startswith("#"):
            k, v = l.rstrip("\n").split("=", 1)
            env[k.strip()] = v
except (OSError, TypeError):
    pass
def get(k):
    return conf.get(k, env.get(k, defaults.get(k)))
def on(k):
    v = get(k)
    return v is True or str(v).lower() in ("true", "1", "yes")
problems = []
if not on("RAVEN_FEDHUB_ENABLE"):
    problems.append("RAVEN_FEDHUB_ENABLE is off")
if not on("RAVEN_FEDHUB_FEDERATE_ENABLE"):
    problems.append("RAVEN_FEDHUB_FEDERATE_ENABLE is off (no fedhub_bridge federation)")
for k in ("RAVEN_FEDHUB_CLIENT_CERT", "RAVEN_FEDHUB_CLIENT_KEY", "RAVEN_FEDHUB_FEDERATE_CERT",
          "RAVEN_FEDHUB_FEDERATE_KEY", "RAVEN_FEDHUB_FEDERATE_CA"):
    p = get(k)
    try:
        open(p, "rb").close()
    except (OSError, TypeError):
        problems.append(f"{k} ({p}) is not readable")
# RAVEN_FEDHUB_CA_BUNDLE: what Raven verifies the UI's certificate (9100) with.
bundle = get("RAVEN_FEDHUB_CA_BUNDLE")
bundle = None if bundle in (None, "", True, "True", "true") else str(bundle)
content = None
if bundle:
    try:
        content = open(bundle).read()
    except OSError:
        problems.append(f"RAVEN_FEDHUB_CA_BUNDLE ({bundle}) is not readable")
if ui_public:
    if content is not None and hubca and hubca in content and content.count("BEGIN CERTIFICATE") == 1:
        problems.append("RAVEN_FEDHUB_CA_BUNDLE is the hub's private CA, but the UI on 9100 serves the admin's own (public) certificate")
else:
    if not bundle:
        problems.append("RAVEN_FEDHUB_CA_BUNDLE is not set, but the UI on 9100 uses the hub's own certificate")
    elif content is not None and hubca and hubca not in content:
        problems.append(f"RAVEN_FEDHUB_CA_BUNDLE ({bundle}) does not contain the hub's CA")
if host:
    api = urllib.parse.urlsplit(str(get("RAVEN_FEDHUB_API_ADDRESS") or "")).hostname or ""
    broker = str(get("RAVEN_FEDHUB_BROKER_ADDRESS") or "").rsplit(":", 1)[0]
    # With a public UI certificate the API address uses that certificate's
    # name, which may differ from the broker's (e.g. fed.example vs tak.example).
    if not ui_public and api != host:
        problems.append(f"RAVEN_FEDHUB_API_ADDRESS does not use {host}")
    if ui_public and not api:
        problems.append("RAVEN_FEDHUB_API_ADDRESS is not set")
    if broker != host:
        problems.append(f"RAVEN_FEDHUB_BROKER_ADDRESS does not use {host}")
print("; ".join(problems))
PY
}

# fh_raven_config KEY=VALUE... -- set those keys in config.yml (safe_dump
# rewrite, as install.sh writes it), as the app user, only if a value
# differs; a timestamped backup is kept. *_ENABLE values become booleans.
# KEY?=VALUE only sets KEY when it is missing or empty; -KEY=VALUE removes
# KEY when (and only when) its value is VALUE. Prints the keys it changed.
fh_raven_config() {
  as_user "$APP_USER" "$PY" - "$CFG" "$@" <<'PY'
import os, shutil, sys, time, yaml
path, pairs = sys.argv[1], sys.argv[2:]
conf = yaml.safe_load(open(path)) or {}
if not isinstance(conf, dict):
    sys.exit(f"{path} is not a YAML mapping; not touching it")
changed = []
for pair in pairs:
    k, v = pair.split("=", 1)
    if k.startswith("-"):
        k = k[1:]
        if k in conf and conf[k] == v:
            del conf[k]
            changed.append(k)
        continue
    only_missing = k.endswith("?")
    k = k.rstrip("?")
    if only_missing and conf.get(k) not in (None, ""):
        continue
    if k.endswith("_ENABLE"):
        v = v.lower() in ("true", "1", "yes")
    if conf.get(k) != v:
        conf[k] = v
        changed.append(k)
if changed:
    shutil.copy2(path, f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w") as f:
        yaml.safe_dump(conf, f)
    shutil.copymode(path, tmp)
    os.replace(tmp, path)
    print(" ".join(changed))
PY
}

# fh_admin_p12_password DEST -- the .p12 import password (PASS in FH_PWFILE),
# alone on one line, into DEST (0600, the app user's). Read and written by a
# root process, so the password is never on a command line. Returns 0 if it
# wrote DEST, 1 if DEST already held it.
fh_admin_p12_password() {
  local out
  out=$(as_root python3 -I - "$FH_PWFILE" "$1" "$(id -u "$APP_USER")" "$(id -g "$APP_USER")" <<'PY'
import os, sys
pwf, dest, uid, gid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
pw = None
for line in open(pwf):
    if line.startswith("PASS="):
        pw = line.rstrip("\r\n").split("=", 1)[1]
if not pw:
    sys.exit(f"{pwf} has no PASS line")
want = pw + "\n"
try:
    cur = open(dest).read()
except OSError:
    cur = None
if cur == want:
    os.chown(dest, uid, gid)
    os.chmod(dest, 0o600)
    sys.exit()
tmp = f"{dest}.tmp-{os.getpid()}"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    f.write(want)
os.chown(tmp, uid, gid)
os.chmod(tmp, 0o600)
os.replace(tmp, dest)
print("written")
PY
) || die "could not write $1 (above)"
  [ "$out" = written ]
}

# fh_wire_raven -- copy the hub's client certificates (and the admin console's
# .p12 with its password) where the app user can read them, point config.yml
# and the secrets file at them, make sure the fedhub_bridge service exists,
# and restart Raven if anything changed.
fh_wire_raven() {
  local dest="$DATA_DIR/fedhub" grp f mode changed=0 out pairs unit_changed=0 envline=""
  log "Connecting Raven to Federation Hub"
  as_root test -f "$CFG" || die "Raven's config.yml is not at $CFG, so Raven can't be connected. Federation Hub itself is set up; finish the Raven install (finish-install.sh), then re-run $FH_SELF."
  as_root test -x "$PY" || die "$PY not found (Raven's venv); set RAVEN_VENV, or finish the Raven install first."
  id "$APP_USER" >/dev/null 2>&1 || die "user $APP_USER does not exist (set RAVEN_USER)."
  grp=$(id -gn "$APP_USER")
  as_root install -d -o "$APP_USER" -g "$grp" -m 700 "$dest"
  for f in fedhub-admin.pem fedhub-admin-unencrypted.key fedhub-admin.p12 raven-federate.pem raven-federate-unencrypted.key ca.pem; do
    as_root test -s "$FH_FILES/$f" || die "$FH_FILES/$f is missing"
    case "$f" in *.key|*.p12) mode=600 ;; *) mode=644 ;; esac
    if as_root cmp -s "$FH_FILES/$f" "$dest/$f"; then
      as_root chown "$APP_USER:$grp" "$dest/$f"; as_root chmod "$mode" "$dest/$f"
    else
      as_root install -o "$APP_USER" -g "$grp" -m "$mode" "$FH_FILES/$f" "$dest/$f"
      changed=1
    fi
  done
  if fh_admin_p12_password "$dest/fedhub-admin.p12.password"; then changed=1; fi
  [ "$changed" = 1 ] && fixed "copied the Federation Hub client certificates and the admin .p12 (with its password file) to $dest"

  pairs=(
    "RAVEN_FEDHUB_ENABLE=true"
    "RAVEN_FEDHUB_FEDERATE_ENABLE=true"
    "RAVEN_FEDHUB_CLIENT_CERT=$dest/fedhub-admin.pem"
    "RAVEN_FEDHUB_CLIENT_KEY=$dest/fedhub-admin-unencrypted.key"
    "RAVEN_FEDHUB_ADMIN_P12=$dest/fedhub-admin.p12"
    "RAVEN_FEDHUB_ADMIN_P12_PASSWORD_FILE=$dest/fedhub-admin.p12.password"
    "RAVEN_FEDHUB_BROKER_ADDRESS=$HOST:9102"
    "RAVEN_FEDHUB_FEDERATE_CERT=$dest/raven-federate.pem"
    "RAVEN_FEDHUB_FEDERATE_KEY=$dest/raven-federate-unencrypted.key"
    "RAVEN_FEDHUB_FEDERATE_CA=$dest/ca.pem"
  )
  # The UI on 9100 presents a public certificate when an admin set one up
  # (FH_UI_PUBLIC): Raven must then trust the system bundle, not this hub's
  # CA, and reach the UI by that certificate's name, which an admin sets in
  # RAVEN_FEDHUB_API_ADDRESS (kept; only filled in when empty).
  if [ "${FH_UI_PUBLIC:-0}" = 1 ]; then
    pairs+=("RAVEN_FEDHUB_API_ADDRESS?=https://$HOST:9100/api" "-RAVEN_FEDHUB_CA_BUNDLE=$dest/ca.pem")
    ok "RAVEN_FEDHUB_API_ADDRESS and the system CA bundle kept for the UI (it uses the admin's own certificate on 9100)"
  else
    pairs+=("RAVEN_FEDHUB_API_ADDRESS=https://$HOST:9100/api" "RAVEN_FEDHUB_CA_BUNDLE=$dest/ca.pem")
  fi
  out=$(fh_raven_config "${pairs[@]}") || die "could not update $CFG (above)"
  if [ -n "$out" ]; then changed=1; fixed "config.yml: set $out (backup next to it)"; else ok "config.yml already points at Federation Hub"; fi

  if [ -n "${SECRETS_FILE:-}" ] && as_root test -f "$SECRETS_FILE"; then
    if ! as_root grep -qx 'RAVEN_FEDHUB_ENABLE=True' "$SECRETS_FILE"; then
      if as_root grep -q '^RAVEN_FEDHUB_ENABLE=' "$SECRETS_FILE"; then
        as_root sed -i 's/^RAVEN_FEDHUB_ENABLE=.*/RAVEN_FEDHUB_ENABLE=True/' "$SECRETS_FILE"
      else
        echo 'RAVEN_FEDHUB_ENABLE=True' | as_root tee -a "$SECRETS_FILE" >/dev/null
      fi
      changed=1; fixed "RAVEN_FEDHUB_ENABLE=True in $SECRETS_FILE"
    fi
    as_root chown "$APP_USER:$grp" "$SECRETS_FILE"
    as_root chmod 600 "$SECRETS_FILE"
  else
    warn "no secrets file at ${SECRETS_FILE:-<unset>}; the Raven units expect one (finish-install.sh writes it)"
  fi

  # Raven's federation bridge (console script fedhub_bridge) runs as its own
  # unit, which install.sh never writes. Same shape as finish-install.sh's.
  # "-": a missing secrets file is not fatal to the unit (config.yml has the
  # settings; the warning above says what is missing).
  [ -n "${SECRETS_FILE:-}" ] && envline="EnvironmentFile=-$SECRETS_FILE"
  if ! fh_unit_exists fedhub_bridge; then
    as_root test -x "$BIN_DIR/fedhub_bridge" || warn "$BIN_DIR/fedhub_bridge does not exist yet (an older backend?); update Raven, then the bridge will start"
    fh_install_file 644 "$FH_ROOT_OWNER" "$SYSTEMD_DIR/fedhub_bridge.service" <<EOF || true
[Unit]
Description=C4 Raven Federation Hub bridge
Wants=network.target $RABBIT_SERVICE.service
After=network.target $RABBIT_SERVICE.service
PartOf=$RAVEN_MAIN_UNIT.service
[Service]
User=$APP_USER
WorkingDirectory=$WORKDIR
$envline
ExecStart=$BIN_DIR/fedhub_bridge
Restart=on-failure
RestartSec=5s
StandardOutput=append:$DATA_DIR/logs/raven.log
StandardError=append:$DATA_DIR/logs/raven.log
[Install]
WantedBy=multi-user.target
EOF
    unit_changed=1; changed=1; fixed "wrote fedhub_bridge.service"
  fi
  if [ "$HAS_SYSTEMD" = 1 ]; then
    [ "$unit_changed" = 1 ] && as_root systemctl daemon-reload
    if ! systemctl is-enabled --quiet fedhub_bridge 2>/dev/null; then
      if as_root systemctl enable fedhub_bridge >/dev/null 2>&1; then fixed "enabled fedhub_bridge"
      else warn "could not enable fedhub_bridge: sudo systemctl enable fedhub_bridge"; fi
    fi
    if [ "$changed" = 1 ] || ! unit_active fedhub_bridge; then
      if as_root systemctl restart "$RAVEN_MAIN_UNIT" fedhub_bridge; then
        fixed "restarted $RAVEN_MAIN_UNIT and fedhub_bridge"
      else
        warn "restarting $RAVEN_MAIN_UNIT / fedhub_bridge failed: sudo journalctl -u fedhub_bridge -n 50"
      fi
    else
      ok "fedhub_bridge enabled and running"
    fi
  elif [ "$changed" = 1 ]; then
    MANUAL_RESTARTS+=("$RAVEN_MAIN_UNIT" fedhub_bridge)
  fi
}

# fh_protect_configs -- the hub's files that hold passwords (the broker and UI
# configuration, the backups fh_yml_set keeps of them, and the database
# setup's create_user.js) readable only by the hub's owner (the tak user for
# the .deb, root for Docker, whose containers run as root). Every run: a
# package upgrade puts them back to 0644.
fh_protect_configs() {
  local f g n=0 st want
  g=$(id -gn "$FH_CERT_OWNER")
  want="600 $FH_CERT_OWNER"
  while IFS= read -r -d '' f; do
    st=$(as_root stat -c '%a %U' "$f" 2>/dev/null) || continue
    [ "$st" = "$want" ] && continue
    as_root chown "$FH_CERT_OWNER:$g" "$f" && as_root chmod 600 "$f" || { warn "could not restrict $f to $FH_CERT_OWNER (mode 600)"; continue; }
    n=$((n + 1))
  done < <(as_root find "$FH_HOME/configs" "$FH_HOME/scripts/db" -maxdepth 1 -type f \
             \( -name 'federation-hub-broker*.yml*' -o -name 'federation-hub-ui.yml*' -o -name create_user.js \) -print0 2>/dev/null)
  if [ "$n" -gt 0 ]; then fixed "restricted $n Federation Hub file(s) holding passwords to $FH_CERT_OWNER (mode 600)"
  else ok "Federation Hub files holding passwords are mode 600"; fi
}

# fh_firewall -- open 9100-9102/tcp in a firewall that is already on. Never
# turns one on, and a failure only warns.
fh_firewall() {
  local st=""
  # Captured first: `ufw status | grep -q` can fail under pipefail (SIGPIPE).
  command -v ufw >/dev/null 2>&1 && st=$(as_root ufw status 2>/dev/null || true)
  if grep -q '^Status: active' <<< "$st"; then
    if grep -qE '^9100:9102/tcp +ALLOW' <<< "$st"; then
      ok "ufw already allows 9100-9102/tcp"
    elif as_root ufw allow 9100:9102/tcp >/dev/null; then
      fixed "ufw: allowed 9100-9102/tcp"
    else
      warn "ufw allow 9100:9102/tcp failed; open 9100-9102/tcp yourself: sudo ufw allow 9100:9102/tcp"
    fi
  elif command -v firewall-cmd >/dev/null 2>&1 && as_root firewall-cmd --state >/dev/null 2>&1; then
    if as_root firewall-cmd --permanent --query-port=9100-9102/tcp >/dev/null 2>&1; then
      ok "firewalld already allows 9100-9102/tcp"
    elif as_root firewall-cmd --permanent --add-port=9100-9102/tcp >/dev/null && as_root firewall-cmd --reload >/dev/null; then
      fixed "firewalld: opened 9100-9102/tcp"
    else
      warn "firewalld: opening 9100-9102/tcp failed; sudo firewall-cmd --permanent --add-port=9100-9102/tcp && sudo firewall-cmd --reload"
    fi
  else
    ok "no active ufw/firewalld; make sure 9100-9102/tcp are reachable if there is another firewall"
  fi
  return 0
}
