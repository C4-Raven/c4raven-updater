# Federation Hub from TAK.gov's takserver-fed-hub_<ver>_all.deb (Debian and
# Ubuntu): MongoDB, Java, the package, Mongo auth, the systemd unit, and the
# UI port fix. The generalised form of ~/federation-hub-setup/0[1-4]-*.sh.
# Sourced by install-fedhub.sh after lib/common.sh and lib/fedhub.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2015  # FH_* state is shared with fedhub.sh; A && B || die is intended

# Installed version of the package, empty when it isn't installed.
fh_deb_installed_version() {
  command -v dpkg-query >/dev/null 2>&1 || return 0
  local s
  s=$(dpkg-query -W -f='${Status}|${Version}' "$FEDHUB_PKG" 2>/dev/null || true)
  case "$s" in "install ok installed|"*) printf '%s' "${s#*|}" ;; esac
}

# fh_mongo_repo -> "VERSION<TAB>apt source suite and components" for this
# release. MongoDB publishes 7.0 for jammy and bookworm, and only 8.0 for
# noble; newer or unknown Ubuntu releases get noble's packages, unknown
# Debian releases bookworm's.
# shellcheck disable=SC1090  # OS_RELEASE is a path chosen at run time
fh_mongo_repo() {
  local id codename like ubuntu_cn
  id=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${ID:-}")
  like=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${ID_LIKE:-}")
  codename=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
  ubuntu_cn=$(. "$OS_RELEASE" 2>/dev/null; printf '%s' "${UBUNTU_CODENAME:-}")
  if [ "$id" = ubuntu ] || { [ "$id" != debian ] && [ -n "$ubuntu_cn" ]; } || case " $like " in *" ubuntu "*) true ;; *) false ;; esac; then
    [ "$id" = ubuntu ] || codename=${ubuntu_cn:-$codename}
    case "$codename" in
      jammy) printf '7.0\tubuntu jammy/mongodb-org/7.0 multiverse' ;;
      focal) printf '7.0\tubuntu focal/mongodb-org/7.0 multiverse' ;;
      *)     printf '8.0\tubuntu noble/mongodb-org/8.0 multiverse' ;;
    esac
  else
    printf '7.0\tdebian bookworm/mongodb-org/7.0 main'
  fi
}

fh_java_major() {
  local v
  v=$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\)\(\.[0-9]*\)*.*".*/\1/p' | head -n 1)
  [ "$v" = 1 ] && v=8   # "1.8.0_x"
  printf '%s' "${v:-0}"
}

FEDHUB_MONGOSH_BIN="${FEDHUB_MONGOSH_BIN:-mongosh}"
FEDHUB_MONGO_WAIT_SECS="${FEDHUB_MONGO_WAIT_SECS:-60}"

# dpkg's architecture name (amd64, arm64, ...); FEDHUB_ARCH overrides it.
fh_deb_arch() {
  local a=${FEDHUB_ARCH:-}
  [ -n "$a" ] || a=$(dpkg --print-architecture 2>/dev/null || true)
  [ -n "$a" ] || a=$(uname -m)
  case "$a" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; esac
  printf '%s' "$a"
}

# What MongoDB's CPU requirement is on this architecture, for error messages.
fh_mongo_cpu_note() {
  case "$(fh_deb_arch)" in
    arm64) printf 'On ARM, MongoDB 5+ needs an ARMv8.2-A CPU or newer (Raspberry Pi 5, AWS Graviton2+, Ampere Altra; not a Raspberry Pi 4).' ;;
    *)     printf 'On x86, MongoDB 5+ needs a CPU with AVX (in a VM: a CPU type that passes AVX through, e.g. Proxmox "host").' ;;
  esac
}

# Can MongoDB's apt repository serve this machine? Its Debian packages are
# amd64-only; its Ubuntu ones are amd64 and arm64.
fh_deb_mongo_arch_ok() {
  local repo suite arch
  repo=$(fh_mongo_repo); suite=${repo#*$'\t'}; arch=$(fh_deb_arch)
  case "$suite:$arch" in
    debian*:amd64|ubuntu*:amd64|ubuntu*:arm64) return 0 ;;
    debian*:*)
      die "MongoDB publishes its Debian packages for amd64 only, and this is $arch Debian, so the .deb install has no database to use here. Use an amd64 machine, or Ubuntu 22.04/24.04 on arm64 (MongoDB's Ubuntu packages include arm64; $(FEDHUB_ARCH=arm64 fh_mongo_cpu_note))." ;;
    *)
      die "MongoDB publishes packages for amd64 and arm64 only; this machine is $arch, so the .deb install has no database to use here." ;;
  esac
}

# fh_apt_has PKG -- apt can install PKG (it has a candidate version).
fh_apt_has() {
  local c
  c=$(apt-cache policy "$1" 2>/dev/null | sed -n 's/^ *Candidate: *//p' | head -n 1)
  [ -n "$c" ] && [ "$c" != "(none)" ]
}

# fh_deb_java_dep_ok DEB -- the package Depends on a specific JDK
# (openjdk-17-jdk for 5.x). Debian 13 has no Java 17, so apt would fail on it
# only after MongoDB had been set up; check first. Only the openjdk-*
# alternatives are checked (virtual packages have no candidate of their own).
fh_deb_java_dep_ok() {
  local abs=$1 deps group alt name found need updated=0
  deps=$(dpkg-deb -f "$abs" Depends 2>/dev/null || true)
  [ -n "$deps" ] || return 0
  local IFS=','
  for group in $deps; do
    case "$group" in *openjdk-*) ;; *) continue ;; esac
    found=0; need=""
    IFS='|'
    for alt in $group; do
      name=$(sed -E 's/\(.*\)//; s/:[a-z0-9]+//; s/[[:space:]]//g' <<< "$alt")
      [ -n "$name" ] || continue
      need="${need:+$need or }$name"
      fh_apt_has "$name" && { found=1; break; }
    done
    if [ "$found" = 0 ] && [ "$updated" = 0 ]; then
      # Lists may just be stale (a fresh machine): refresh once and look again.
      updated=1
      retry as_root env DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
      for alt in $group; do
        name=$(sed -E 's/\(.*\)//; s/:[a-z0-9]+//; s/[[:space:]]//g' <<< "$alt")
        [ -n "$name" ] && fh_apt_has "$name" && { found=1; break; }
      done
    fi
    IFS=','
    [ "$found" = 1 ] && continue
    die "$abs depends on $need, which this system's apt sources don't offer (Debian 13 \"trixie\" has no Java 17, only 21 and newer), so the package can't be installed here. Use the Federation Hub Docker release instead: download takserver-fed-hub-docker-<version>.zip from tak.gov and run: $FH_SELF --artifact /path/to/that.zip"
  done
  return 0
}

# fh_deb_preflight [DEB] -- what would make the install fail halfway, before
# anything is installed.
fh_deb_preflight() {
  local deb=${1:-} abs
  command -v "$FEDHUB_MONGOD_BIN" >/dev/null 2>&1 || fh_deb_mongo_arch_ok
  [ -n "$deb" ] || return 0
  abs=$(readlink -f "$deb")
  [ "$(dpkg-deb -f "$abs" Version 2>/dev/null || true)" = "$(fh_deb_installed_version)" ] && return 0
  fh_deb_java_dep_ok "$abs"
}

fh_deb_prereqs() {
  local repo ver suite key list tmp
  log "MongoDB and Java"
  if command -v "$FEDHUB_MONGOD_BIN" >/dev/null 2>&1; then
    ok "mongod present"
  else
    repo=$(fh_mongo_repo); ver=${repo%%$'\t'*}; suite=${repo#*$'\t'}
    key="$KEYRING_DIR/mongodb-server-$ver.gpg"
    list="$APT_SOURCES_DIR/mongodb-org-$ver.list"
    pkg_install curl gnupg ca-certificates || die "could not install curl/gnupg"
    if ! as_root test -s "$key"; then
      tmp=$(mktemp)
      retry curl -fsSL "https://pgp.mongodb.com/server-$ver.asc" -o "$tmp" || { rm -f "$tmp"; die "could not download MongoDB's signing key (network?)"; }
      as_root mkdir -p "$KEYRING_DIR"
      as_root gpg --dearmor --yes -o "$key" "$tmp" || { rm -f "$tmp"; die "gpg --dearmor of MongoDB's key failed"; }
      as_root chmod 644 "$key"
      rm -f "$tmp"
    fi
    fh_deb_mongo_arch_ok
    printf 'deb [ arch=%s signed-by=%s ] https://repo.mongodb.org/apt/%s\n' "$(fh_deb_arch)" "$key" "$suite" \
      | fh_install_file 644 "$FH_ROOT_OWNER" "$list" && fixed "added the MongoDB $ver apt repository ($suite)"
    pkg_install mongodb-org || die "installing mongodb-org failed (output above). $(fh_mongo_cpu_note)"
    fixed "installed MongoDB $ver"
  fi
  if [ "$HAS_SYSTEMD" = 1 ]; then
    if unit_active mongod; then
      # Running but not enabled (started by hand): it, and so the hub, which
      # Requires it, would not come back after a reboot.
      systemctl is-enabled --quiet mongod 2>/dev/null \
        || { as_root systemctl enable mongod >/dev/null 2>&1 && fixed "enabled mongod (start at boot)"; } \
        || warn "could not enable mongod; it won't start at boot (sudo systemctl enable mongod)"
    else
      { as_root systemctl enable --now mongod && fixed "started mongod"; } \
        || die "mongod would not start: sudo journalctl -u mongod -n 50. $(fh_mongo_cpu_note)"
    fi
  else
    warn "no systemd: start mongod yourself (mongod --config $MONGOD_CONF)"
  fi
  if [ "$(fh_java_major)" -ge 17 ] 2>/dev/null; then
    ok "Java $(fh_java_major) present"
  else
    # Debian 13 has no 17; 21 runs Federation Hub too.
    pkg_install openjdk-17-jre-headless || pkg_install openjdk-21-jre-headless || die "could not install Java 17+ (openjdk-17-jre-headless)"
    fixed "installed Java $(fh_java_major)"
  fi
}

# fh_deb_package [DEB] -- install DEB unless that version is installed.
fh_deb_package() {
  local deb=${1:-} want have pkg abs
  log "Federation Hub package"
  have=$(fh_deb_installed_version)
  if [ -z "$deb" ]; then
    [ -n "$have" ] || die "the $FEDHUB_PKG package is not installed and no .deb was given (--artifact)."
    ok "$FEDHUB_PKG $have installed"
  else
    abs=$(readlink -f "$deb")
    pkg=$(dpkg-deb -f "$abs" Package 2>/dev/null || true)
    [ "$pkg" = "$FEDHUB_PKG" ] || die "$abs is not the $FEDHUB_PKG package (Package: ${pkg:-unreadable})."
    want=$(dpkg-deb -f "$abs" Version)
    if [ "$have" = "$want" ]; then
      ok "$FEDHUB_PKG $have already installed"
    else
      # One argv word, absolute: apt treats it as a file, spaces and all.
      retry as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$abs" \
        || die "apt-get install of $abs failed (output above)."
      fixed "installed $FEDHUB_PKG $want${have:+ (was $have)}"
      FH_CHANGED=1
    fi
  fi
  FH_VERSION=$(fh_deb_installed_version)
  as_root test -d "$FEDHUB_ROOT/certs" || die "$FEDHUB_ROOT/certs is missing after installing $FEDHUB_PKG."
  id "$FEDHUB_TAK_USER" >/dev/null 2>&1 || die "the package did not create the '$FEDHUB_TAK_USER' user."
}

# MongoDB authentication: the package's own configure.sh creates the database
# user from (or writes) dbUsername/dbPassword in the broker config and turns
# authorization on. It has no `set -e` and ends in an echo, so its exit
# status means nothing: success is that user actually logging in.

# mongosh: configure.sh creates the user with it, and the check below uses it.
fh_deb_mongosh() {
  command -v "$FEDHUB_MONGOSH_BIN" >/dev/null 2>&1 && return 0
  pkg_install mongodb-mongosh || true
  command -v "$FEDHUB_MONGOSH_BIN" >/dev/null 2>&1 \
    || die "mongosh is not installed, and configure.sh needs it to create the database user (it comes with MongoDB's apt repository as mongodb-mongosh): sudo apt-get install mongodb-mongosh, then re-run."
  fixed "installed mongosh"
}

# fh_deb_mongo_login -- log in to mongod (127.0.0.1, net.port from
# MONGOD_CONF) as dbUsername/dbPassword from the broker config. The
# credentials are read inside the root process and reach mongosh through its
# environment, never a command line. 0 = logged in, 2 = refused, 4 = no
# credentials in the config, other = mongod not answering.
fh_deb_mongo_login() {
  as_root python3 -I - "$FH_BROKER_YML" "$MONGOD_CONF" "$(command -v "$FEDHUB_MONGOSH_BIN")" <<'PY'
import os, re, subprocess, sys
yml, conf, mongosh = sys.argv[1:4]

def get(path, rx):
    try:
        for line in open(path):
            m = re.match(rx, line.rstrip("\r\n"))
            if m:
                v = m.group(1).split(" #")[0].strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                return v
    except OSError:
        pass
    return ""

user = get(yml, r"^dbUsername:(.*)$") or "martiuser"   # setup-db.sh's default
pw = get(yml, r"^dbPassword:(.*)$")
if not pw:
    sys.exit(4)
port = get(conf, r"^\s+port:(.*)$") or "27017"
js = ("try { db.getSiblingDB('admin').auth(process.env.FH_DB_USER, process.env.FH_DB_PASS); quit(0) } "
      "catch (e) { quit(e.code === 18 || e.codeName === 'AuthenticationFailed' ? 2 : 3) }")
env = dict(os.environ, FH_DB_USER=user, FH_DB_PASS=pw)
try:
    r = subprocess.run([mongosh, "--quiet", "--norc", f"mongodb://127.0.0.1:{port}/admin?serverSelectionTimeoutMS=5000",
                        "--eval", js], env=env, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
except (OSError, subprocess.TimeoutExpired):
    sys.exit(3)
sys.exit(r.returncode if r.returncode in (0, 2) else 3)
PY
}

# fh_deb_mongo_wait_login -- fh_deb_mongo_login, waiting up to
# FEDHUB_MONGO_WAIT_SECS for a mongod that is (re)starting to answer.
fh_deb_mongo_wait_login() {
  local i rc
  for ((i = 0; ; i += 2)); do
    rc=0; fh_deb_mongo_login || rc=$?
    case "$rc" in 0|2|4) return "$rc" ;; esac
    [ "$i" -lt "$FEDHUB_MONGO_WAIT_SECS" ] || return "$rc"
    sleep 2
  done
}

fh_deb_mongo_auth() {
  local has_pw=0 has_auth=0 rc
  log "MongoDB authentication"
  fh_deb_mongosh
  as_root grep -qE '^dbPassword:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]' "$FH_BROKER_YML" 2>/dev/null && has_pw=1
  as_root grep -qE '^[[:space:]]*authorization:[[:space:]]*["'"'"']?enabled' "$MONGOD_CONF" 2>/dev/null && has_auth=1
  if [ "$has_pw" = 1 ] && [ "$has_auth" = 1 ]; then
    rc=0; fh_deb_mongo_wait_login || rc=$?
    case "$rc" in
      0) ok "database user logs in; authorization enabled"; return 0 ;;
      2|4) warn "the database user in $FH_BROKER_YML can't log in to MongoDB; running configure.sh again to create it" ;;
      *) die "mongod is not answering on 127.0.0.1 (sudo systemctl status mongod; sudo journalctl -u mongod -n 50)." ;;
    esac
  fi
  [ "$HAS_SYSTEMD" = 1 ] || die "configure.sh needs systemd to restart mongod; this host has none."
  # configure.sh prints the generated create_user.js, password and all: hide it.
  as_root "$FEDHUB_ROOT/scripts/db/configure.sh" 2>&1 | sed -E "s/(pwd: *')[^']*/\1<hidden>/" \
    || die "$FEDHUB_ROOT/scripts/db/configure.sh failed (output above)."
  as_root grep -qE '^dbPassword:[[:space:]]*["'"'"']?[^"'"'"'[:space:]]' "$FH_BROKER_YML" \
    && as_root grep -qE '^[[:space:]]*authorization:[[:space:]]*["'"'"']?enabled' "$MONGOD_CONF" \
    || die "configure.sh ran but the database password / authorization are still not set."
  rc=0; fh_deb_mongo_wait_login || rc=$?
  case "$rc" in
    0) ;;
    2|4) die "configure.sh ran, but the database user in $FH_BROKER_YML still can't log in to MongoDB (output above). If that user already existed with another password, configure.sh can't change it: set dbPassword in $FH_BROKER_YML to that user's password, or drop the user in MongoDB, then re-run." ;;
    *) die "mongod is not answering on 127.0.0.1 after configure.sh restarted it (sudo journalctl -u mongod -n 50)." ;;
  esac
  FH_CHANGED=1
  fixed "MongoDB: database user created and logs in, authorization enabled"
}

# Federation Hub's UI also starts Spring's default web server on 8080 (taken
# by other things, and not needed): move it to 127.0.0.1:9105.
fh_deb_ui_port_fix() {
  local f="$FEDHUB_ROOT/scripts/federation-hub-ui.sh"
  if ! as_root test -f "$f"; then warn "$f not found; the UI port fix was not applied"; return 0; fi
  if as_root grep -q '^export JDK_JAVA_OPTIONS=.*-Dserver\.port=' "$f"; then
    ok "federation-hub-ui.sh already moves the UI's web server to 127.0.0.1:9105"
  elif as_root grep -q '^export JDK_JAVA_OPTIONS=.*-DIGNITE_UPDATE_NOTIFIER=false' "$f"; then
    as_root sed -i '/^export JDK_JAVA_OPTIONS=/s/-DIGNITE_UPDATE_NOTIFIER=false/-DIGNITE_UPDATE_NOTIFIER=false -Dserver.port=9105 -Dserver.address=127.0.0.1/' "$f"
    FH_CHANGED=1; fixed "federation-hub-ui.sh: UI web server moved off 8080 to 127.0.0.1:9105"
  else
    warn "$f has no JDK_JAVA_OPTIONS line with -DIGNITE_UPDATE_NOTIFIER=false (a newer package?); add -Dserver.port=9105 -Dserver.address=127.0.0.1 to it yourself if the UI fails on port 8080"
  fi
}

# A real federation-hub.service: a file in a unit directory, or whatever
# systemd loaded it from -- unless that is systemd-sysv-generator's wrapper
# (/run/systemd/generator*) for the package's /etc/init.d/federation-hub*
# scripts, which makes `systemctl cat` succeed although no unit was written.
fh_deb_real_unit() {
  local d frag
  for d in "$SYSTEMD_DIR" $SYSTEMD_LIB_DIRS; do
    as_root test -f "$d/federation-hub.service" && return 0
  done
  [ "$HAS_SYSTEMD" = 1 ] || return 1
  frag=$(systemctl show -p FragmentPath --value federation-hub.service 2>/dev/null || true)
  case "$frag" in ""|/run/systemd/generator*) return 1 ;; esac
  as_root test -f "$frag"
}

# The .deb's postinst only registers the service on RHEL; write the unit from
# 04-finish-and-start.sh when there is none. Unlike that one, it is
# supervised: bash waits for the FIRST of the four parts to exit (wait -n)
# and then fails, so systemd stops the other three and restarts all four
# (Restart=on-failure); with a plain `wait` plus RemainAfterExit=yes a dead
# hub stayed "active" and a killed one stayed down until started by hand.
# That older unit (the one 04-finish-and-start.sh used to write) is upgraded
# in place, the old file kept beside it; any other existing unit is left alone.

# fh_deb_unit_outdated -- 0 if $SYSTEMD_DIR/federation-hub.service is the old
# unsupervised unit: it runs the four hub scripts but has no Restart= line.
fh_deb_unit_outdated() {
  local u="$SYSTEMD_DIR/federation-hub.service"
  as_root test -f "$u" || return 1
  as_root grep -q 'federation-hub-broker\.sh' "$u" || return 1
  ! as_root grep -q '^Restart=' "$u"
}

fh_deb_unit() {
  local u="$SYSTEMD_DIR/federation-hub.service" bak=""
  if fh_deb_unit_outdated; then
    bak="$u.bak-$(date +%Y%m%d-%H%M%S)"
    as_root cp -p "$u" "$bak" || die "could not back up $u"
  elif fh_deb_real_unit; then
    ok "federation-hub.service present"
    return 0
  fi
  fh_install_file 644 "$FH_ROOT_OWNER" "$u" <<EOF || true
[Unit]
Description=Federation Hub Service
After=network.target mongod.service
Requires=mongod.service

[Service]
Type=simple
WorkingDirectory=$FEDHUB_ROOT/scripts
ExecStart=/bin/bash -c "./federation-hub-policy.sh & ./federation-hub-plugin-manager.sh & ./federation-hub-ui.sh & ./federation-hub-broker.sh & wait -n; exit 1"
Restart=on-failure
RestartSec=10s
User=$FEDHUB_TAK_USER
Group=$(id -gn "$FEDHUB_TAK_USER")
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  [ "$HAS_SYSTEMD" = 1 ] && as_root systemctl daemon-reload
  if [ -n "$bak" ]; then
    # No restart just for this: the running hub carries on, and the new unit
    # applies from its next start (systemd itself restarts it from then on).
    fixed "upgraded federation-hub.service so systemd restarts the hub if it dies (takes effect at its next restart; old unit kept as $bak)"
    return 0
  fi
  FH_CHANGED=1; fixed "wrote federation-hub.service"
}

fh_deb_authorize() {
  if fh_admin_authorized; then ok "fedhub-admin is an authorised admin"; return 0; fi
  as_user "$FEDHUB_TAK_USER" java -jar "$FEDHUB_ROOT/jars/federation-hub-manager.jar" "$FH_FILES/$FEDHUB_ADMIN_CN.pem" \
    || die "authorising $FEDHUB_ADMIN_CN.pem with federation-hub-manager.jar failed (output above)."
  fh_mark_authorized
  FH_CHANGED=1; fixed "authorised fedhub-admin for the admin UI"
}

fh_deb_ports_up() {
  local p ports
  ports=$(ss -tln 2>/dev/null | awk 'NR > 1 {print $4}')
  for p in "$@"; do
    grep -qE "[:.]$p\$" <<< "$ports" || return 1
  done
}

# fh_deb_wait_ports PORT... -- up to FEDHUB_WAIT_SECS for all of them.
fh_deb_wait_ports() {
  local i
  for ((i = 0; i < FEDHUB_WAIT_SECS; i += 2)); do
    fh_deb_ports_up "$@" && return 0
    sleep 2
  done
  return 1
}

fh_deb_start() {
  local ports kicked=0
  log "Starting Federation Hub"
  if [ "$HAS_SYSTEMD" != 1 ]; then
    MANUAL_RESTARTS+=(federation-hub)
    warn "no systemd: start Federation Hub yourself (cd $FEDHUB_ROOT/scripts and run the four federation-hub-*.sh)"
    return 0
  fi
  systemctl is-enabled --quiet federation-hub 2>/dev/null || { as_root systemctl enable federation-hub >/dev/null 2>&1 && fixed "enabled federation-hub"; }
  if ! unit_active federation-hub; then
    as_root systemctl start federation-hub && fixed "started federation-hub"; kicked=1
  elif [ "${FH_CHANGED:-0}" = 1 ]; then
    as_root systemctl restart federation-hub && fixed "restarted federation-hub to load the changes"; kicked=1
  elif [ "$(systemctl show -p SubState --value federation-hub 2>/dev/null || true)" = exited ]; then
    # RemainAfterExit=yes (04-finish-and-start.sh's unit): "active", but
    # every process of it has gone.
    as_root systemctl restart federation-hub && fixed "restarted federation-hub (it was 'active (exited)': its processes had stopped)"; kicked=1
  fi
  ports=$(fh_expected_ports)
  # shellcheck disable=SC2086
  if fh_deb_wait_ports $ports; then ok "listening on ${ports// /, }"; return 0; fi
  if [ "$kicked" = 0 ]; then
    # Running, but (part of) the hub is dead or hung: one restart.
    as_root systemctl restart federation-hub && fixed "restarted federation-hub (it was running but not listening on ${ports// /, })"
    # shellcheck disable=SC2086
    if fh_deb_wait_ports $ports; then ok "listening on ${ports// /, }"; return 0; fi
  fi
  as_root journalctl -u federation-hub -n 60 --no-pager || true
  die "Federation Hub did not open ports ${ports// /, } within ${FEDHUB_WAIT_SECS}s (log above)."
}

# fh_deb_install [DEB]
fh_deb_install() {
  fh_set_context deb
  fh_deb_preflight "${1:-}"
  fh_deb_prereqs
  fh_deb_package "${1:-}"
  fh_deb_mongo_auth
  fh_certs
  log "Federation Hub configuration"
  fh_configure_ymls
  as_root chown "$FEDHUB_TAK_USER:" "$FH_BROKER_YML" "$FH_UI_YML"
  fh_deb_ui_port_fix
  fh_deb_unit
  fh_deb_authorize
  fh_deb_start
}

# fh_deb_installed -- package present, unit written, certificates made and
# the admin authorised: what --check calls "installed".
fh_deb_installed() {
  fh_set_context deb
  [ -n "$(fh_deb_installed_version)" ] || as_root test -f "$FEDHUB_ROOT/jars/federation-hub-broker.jar" || return 1
  fh_deb_real_unit || return 1
  as_root test -s "$FH_FILES/ca.pem" && as_root test -s "$FH_FILES/$FEDHUB_ADMIN_CN.pem" && fh_admin_authorized
}
