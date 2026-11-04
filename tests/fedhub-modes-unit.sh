#!/usr/bin/env bash
# Single-quoted bash -c snippets take their arguments positionally on purpose.
# shellcheck disable=SC2016,SC2015
# Tests for the two install modes of install-fedhub.sh (lib/fedhub_deb.sh and
# lib/fedhub_docker.sh): upgrades and re-installs of the Docker release, the
# database password, the certificates without a running hub, snap Docker,
# --check needing running containers; and for the .deb: the Java dependency
# on Debian 13, MongoDB on arm64, the database login check, the unit written
# despite a SysV-generated one, mongod enabled, and a dead hub restarted.
#
# Same approach as tests/fedhub-unit.sh: every system command is a stub on
# PATH and every path points into a temporary directory; no root, Docker,
# MongoDB or network needed.
#
#   bash tests/fedhub-modes-unit.sh            # all tests
#   bash tests/fedhub-modes-unit.sh docker     # tests whose name matches
#
# Safe on a live server: it refuses to run unless `sudo` resolves to its own
# stub, and nothing it runs touches /opt, /etc or /var.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ME=$(id -un)
FILTER="${1:-}"
RESULTS=$(mktemp "${TMPDIR:-/tmp}/fedhub-modes-results.XXXXXX")
V1=5.7-RELEASE-20
V2=5.8-RELEASE-75

# ---- fixture -----------------------------------------------------------------------
new_env() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/fedhub-modes.XXXXXX")
  S=$T/shims; ST=$T/state; L=$T/log
  mkdir -p "$S" "$ST/active" "$ST/enabled" "$ST/docker/images" "$ST/docker/networks" "$ST/docker/containers" \
           "$L" "$T/home/Downloads" "$T/systemd" "$T/systemd-lib" "$T/optbin" "$T/etc"
  export PATH="$S:$PATH" TMPDIR=$T HOME=$T/home
  unset SUDO_USER RAVEN_UPDATER_LOCKED RAVEN_FEDHUB_ARTIFACT RAVEN_FEDHUB_DEB RAVEN_DOMAIN RAVEN_FEDHUB_SKIP RAVEN_VENV FEDHUB_DOCKER_DB_CREDS
  export ST L T S
  export FEDHUB_ROOT=$T/opt/tak/federation-hub FEDHUB_TAK_USER=$ME FEDHUB_ROOT_OWNER=$ME
  export FEDHUB_DOCKER_BASE=$T/opt/fedhub-docker FEDHUB_DOCKER_DB_DIR=$T/var/lib/fedhub-docker-mongodb
  export SYSTEMD_DIR=$T/systemd SYSTEMD_LIB_DIRS=$T/systemd-lib MONGOD_CONF=$T/etc/mongod.conf
  export APT_SOURCES_DIR=$T/etc/apt KEYRING_DIR=$T/keyrings YUM_REPOS_DIR=$T/etc/yum.repos.d
  export FEDHUB_MONGOD_BIN=fake-mongod FEDHUB_MONGOSH_BIN=fake-mongosh FEDHUB_WAIT_SECS=4 FEDHUB_MONGO_WAIT_SECS=2
  export FEDHUB_TTY=$T/no-tty FEDHUB_ARCH=amd64
  export RAVEN_USER=$ME RAVEN_HOME=$T/raven RAVEN_ASSUME_SYSTEMD=1 NO_COLOR=1 RETRY_ATTEMPTS=1
  export OS_RELEASE=$T/os-release
  write_shims
  set_os ubuntu noble
  [ "$(command -v sudo)" = "$S/sudo" ] || { echo "sudo is not the stub; refusing to run"; exit 1; }
  make_raven
  cd "$T" || exit 1
}
set_os() {  # set_os ID CODENAME [ID_LIKE]
  printf 'ID=%s\nVERSION_CODENAME=%s\nID_LIKE="%s"\n' "$1" "$2" "${3:-}" > "$OS_RELEASE"
}

make_raven() {
  local r=$RAVEN_HOME
  mkdir -p "$r/data/logs" "$r/c4raven-server/.venv/bin"
  ln -s "$(command -v python3)" "$r/c4raven-server/.venv/bin/python"
  printf '#!/bin/sh\nexit 0\n' > "$r/c4raven-server/.venv/bin/fedhub_bridge"; chmod +x "$r/c4raven-server/.venv/bin/fedhub_bridge"
  printf 'RAVEN_FEDHUB_ENABLE: true\nSECRET_KEY: s3cret\n' > "$r/data/config.yml"
  printf 'RAVEN_DATA_FOLDER=%s\nRAVEN_FEDHUB_ENABLE=False\n' "$r/data" > "$r/.raven-secrets.env"
  chmod 600 "$r/.raven-secrets.env"
  printf 'RAVEN_DOMAIN=\n' > "$r/.install-answers"
  touch "$T/systemd/raven.service"
}

# The tree a Federation Hub release unpacks to (federation-hub/ under DIR).
# configure.sh behaves like the package's: it adds a dbPassword only when the
# config has none, and createUser fails when the user already exists.
make_fh_tree() {
  local fh=$1 docker=${2:-0}
  mkdir -p "$fh/certs" "$fh/configs" "$fh/scripts/db" "$fh/jars" "$fh/policies"
  touch "$fh/jars/federation-hub-broker.jar" "$fh/jars/federation-hub-manager.jar"
  cat > "$fh/certs/makeRootCa.sh" <<'EOF'
#!/bin/bash
[ -n "$CAPASS" ] && [ -n "$STATE" ] || { echo "metadata not set" >&2; exit 1; }
mkdir -p files && cd files
[ -e ca.pem ] && { echo "ca.pem file already exists!" >&2; exit 1; }
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca-do-not-share.key -days 30 -out ca.pem \
  -subj "/C=${COUNTRY:-WW}/ST=$STATE/L=$CITY/O=$ORGANIZATION/OU=$ORGANIZATIONAL_UNIT/CN=${2:-TAK-CA}" 2>/dev/null || exit 1
echo jks > truststore-root.jks; echo jks > fed-truststore.jks
echo "makeRootCa $*" >> "$L/calls"
EOF
  cat > "$fh/certs/makeCert.sh" <<'EOF'
#!/bin/bash
[ -n "$PASS" ] && [ -n "$STATE" ] || { echo "metadata not set" >&2; exit 1; }
cd files || exit 1
[ -e ca.pem ] || exit 1
openssl genrsa -aes256 -passout env:PASS -out "$2.key" 2048 2>/dev/null || exit 1
openssl req -new -key "$2.key" -passin env:PASS -subj "/CN=$2" -out "$2.csr" 2>/dev/null || exit 1
openssl x509 -req -in "$2.csr" -CA ca.pem -CAkey ca-do-not-share.key -CAcreateserial -days 30 -out "$2.pem" 2>/dev/null || exit 1
echo jks > "$2.jks"; echo "p12 $2 $(date +%s%N)" > "$2.p12"
echo "makeCert $*" >> "$L/calls"
EOF
  chmod +x "$fh/certs/makeRootCa.sh" "$fh/certs/makeCert.sh"
  {
    echo 'keystoreFile: /opt/tak/federation-hub/certs/files/takserver.jks'
    echo 'keystorePassword: atakatak'
    echo 'truststoreFile: /opt/tak/federation-hub/certs/files/fed-truststore.jks'
    echo 'truststorePassword: atakatak'
    echo 'caFile: /opt/tak/federation-hub/certs/files/ca.pem'
    echo 'v1Enabled: false'
    echo 'v2Enabled: true'
    if [ "$docker" = 1 ]; then echo 'dbUsername: martiuser'; echo 'dbPassword: '; echo 'dbHost: localhost'; fi
  } > "$fh/configs/federation-hub-broker.yml"
  printf 'keystoreFile: /opt/tak/federation-hub/certs/files/takserver.jks\nkeystorePassword: atakatak\ntruststoreFile: /opt/tak/federation-hub/certs/files/truststore-root.jks\ntruststorePassword: atakatak\nkeyAlias: takserver\n' \
    > "$fh/configs/federation-hub-ui.yml"
  printf '#!/bin/bash\nexport JDK_JAVA_OPTIONS="-DIGNITE_UPDATE_NOTIFIER=false"\n' > "$fh/scripts/federation-hub-ui.sh"
  cat > "$fh/scripts/db/configure.sh" <<'EOF'
#!/bin/bash
y="$FEDHUB_ROOT/configs/federation-hub-broker.yml"
grep -qE '^dbPassword: *[^ ]' "$y" || echo "dbPassword: generatedpw" >> "$y"
pw=$(sed -nE 's/^dbPassword: *"?([^"]*)"?$/\1/p' "$y" | head -n 1)
echo "db.createUser({user: 'martiuser', pwd: '$pw', roles: []})"
[ -e "$ST/mongo-user" ] || printf '%s' "$pw" > "$ST/mongo-user"
printf 'security:\n  authorization: "enabled"\n' > "$MONGOD_CONF"
echo configure >> "$L/calls"
echo "Mongo Setup!"
EOF
  chmod +x "$fh/scripts/db/configure.sh" "$fh/scripts/federation-hub-ui.sh"
}

make_deb() {  # make_deb DIR VERSION -> path
  mkdir -p "$1"
  printf 'fake deb\n' > "$1/takserver-fed-hub_${2}_all.deb"
  printf '%s' "$1/takserver-fed-hub_${2}_all.deb"
}
make_zip() {  # make_zip PATH VERSION
  local src=$T/zipsrc/fedhub-docker-$2
  rm -rf "$T/zipsrc"; mkdir -p "$src/docker" "$src/tak"
  echo "$2" > "$src/tak/version.txt"
  echo "FROM scratch" > "$src/docker/Dockerfile.fedhub"; echo "FROM scratch" > "$src/docker/Dockerfile.fedhub-db"
  make_fh_tree "$src/tak/federation-hub" 1
  mkdir -p "$(dirname "$1")"
  (cd "$T/zipsrc" && python3 -I -c 'import shutil, sys; shutil.make_archive(sys.argv[1][:-4], "zip", ".", sys.argv[2])' "$1" "fedhub-docker-$2")
}

write_shims() {
  cat > "$S/sudo" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do case "$1" in -u) shift 2 ;; -H|-n|-E) shift ;; --) shift; break ;; *) break ;; esac; done
exec "$@"
EOF
  cat > "$S/runuser" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done; shift; exec "$@"
EOF
  cat > "$S/getent" <<'EOF'
#!/bin/bash
[ "$1" = passwd ] && [ "$2" = "$(id -un)" ] && { echo "$2:x:$(id -u):$(id -g)::$HOME:/bin/bash"; exit 0; }
exit 2
EOF
  # systemctl: show answers FragmentPath ($ST/fragment, else the /etc unit)
  # and SubState ($ST/substate-exited); restart clears that and, with
  # $ST/heal-on-restart, $ST/ports-down.
  cat > "$S/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$L/systemctl"
if [ "$1" = show ]; then
  case " $* " in
    *" FragmentPath "*) if [ -e "$ST/fragment" ]; then cat "$ST/fragment"; elif [ -e "$SYSTEMD_DIR/federation-hub.service" ]; then echo "$SYSTEMD_DIR/federation-hub.service"; fi ;;
    *" SubState "*) [ -e "$ST/substate-exited" ] && echo exited || echo running ;;
  esac
  exit 0
fi
args=()
for a in "$@"; do case "$a" in --quiet|-q|--no-pager) ;; *) args+=("$a") ;; esac; done
set -- "${args[@]}"
act=$1; shift
now=0; [ "${1:-}" = --now ] && { now=1; shift; }
for u in "$@"; do
  u=${u%.service}
  case "$act" in
    is-active)  [ -e "$ST/active/$u" ] || exit 3 ;;
    is-enabled) [ -e "$ST/enabled/$u" ] || exit 1 ;;
    start|restart)
      [ -e "$ST/fail-$u" ] && exit 1; touch "$ST/active/$u"
      [ "$act" = restart ] && echo "$u" >> "$L/restarts"
      [ "$u" = federation-hub ] && { rm -f "$ST/substate-exited"; [ -e "$ST/heal-on-restart" ] && rm -f "$ST/ports-down"; } ;;
    stop) rm -f "$ST/active/$u" ;;
    enable) touch "$ST/enabled/$u"; [ "$now" = 1 ] && touch "$ST/active/$u" ;;
    cat) [ -e "$SYSTEMD_DIR/$u.service" ] || [ -e "$ST/fragment" ] || exit 1 ;;
  esac
done
exit 0
EOF
  printf '#!/bin/bash\necho "journalctl $*" >> "$L/journalctl"\necho "(journal)"\n' > "$S/journalctl"
  cat > "$S/dpkg-query" <<'EOF'
#!/bin/bash
[ -f "$ST/pkg-version" ] || exit 1
printf 'install ok installed|%s' "$(cat "$ST/pkg-version")"
EOF
  cat > "$S/dpkg-deb" <<'EOF'
#!/bin/bash
f=$2; b=${f##*/}
case "$3" in
  Package) echo takserver-fed-hub ;;
  Version) v=${b#takserver-fed-hub_}; echo "${v%_all.deb}" ;;
  Depends) cat "$ST/deb-depends" 2>/dev/null ;;
esac
EOF
  # apt-cache policy PKG: no candidate when $ST/apt-none-PKG exists.
  cat > "$S/apt-cache" <<'EOF'
#!/bin/bash
echo "apt-cache $*" >> "$L/apt"
p=$2
echo "$p:"; echo "  Installed: (none)"
if [ -e "$ST/apt-none-$p" ]; then echo "  Candidate: (none)"; else echo "  Candidate: 17.0.9+9-1"; fi
EOF
  cat > "$S/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$L/apt"
for a in "$@"; do
  case "$a" in
    /*.deb) . "$T/fixture.sh"; make_fh_tree "$FEDHUB_ROOT"; b=${a##*/}; v=${b#takserver-fed-hub_}; echo "${v%_all.deb}" > "$ST/pkg-version" ;;
    mongodb-org) [ -e "$ST/mongo-install-fails" ] && exit 100
                 printf '#!/bin/sh\nexit 0\n' > "$S/fake-mongod"; chmod +x "$S/fake-mongod" ;;
    mongodb-mongosh) [ -e "$ST/no-mongosh-pkg" ] && exit 100; cp "$T/mongosh-stub" "$S/fake-mongosh" ;;
  esac
done
exit 0
EOF
  # mongosh: logs in when FH_DB_PASS is the password configure.sh created
  # the user with ($ST/mongo-user); exit 1 = no mongod ($ST/mongo-down).
  cat > "$T/mongosh-stub" <<'EOF'
#!/bin/bash
echo "mongosh $*" >> "$L/mongosh"
[ -e "$ST/mongo-down" ] && exit 1
[ -e "$ST/mongo-user" ] && [ "$(cat "$ST/mongo-user")" = "$FH_DB_PASS" ] && [ "$FH_DB_USER" = martiuser ] && exit 0
exit 2
EOF
  cp "$T/mongosh-stub" "$S/fake-mongosh"
  cat > "$S/snap" <<'EOF'
#!/bin/bash
[ "$1 $2" = "list docker" ] && [ -e "$ST/snap-docker" ] && { echo "docker 27.2.0 snap"; exit 0; }
exit 1
EOF
  cat > "$S/java" <<'EOF'
#!/bin/bash
if [ "$1" = -version ]; then echo 'openjdk version "17.0.9" 2023-10-17' >&2; exit 0; fi
echo "java $*" >> "$L/calls"
printf 'users:\n- username: "fedhub-admin"\n' > "${FH_AUTH_HOME:-$FEDHUB_ROOT}/authorized_users.yml"
EOF
  cat > "$S/ss" <<'EOF'
#!/bin/bash
echo "State Recv-Q Send-Q Local Address:Port Peer"
[ -e "$ST/ports-down" ] && exit 0
for p in $(cat "$ST/ports-up" 2>/dev/null); do echo "LISTEN 0 50 *:$p *:*"; done
[ -e "$ST/active/federation-hub" ] && for p in 9100 9102; do echo "LISTEN 0 50 *:$p *:*"; done
exit 0
EOF
  printf '#!/bin/bash\n[ "$1" = -I ] && echo "192.0.2.10 2001:db8::1"\n' > "$S/hostname"
  cat > "$S/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$L/calls"
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { echo key > "$2"; }; shift; done
EOF
  printf '#!/bin/bash\nwhile [ "$#" -gt 0 ]; do [ "$1" = -o ] && { echo gpg > "$2"; }; shift; done\n' > "$S/gpg"
  printf '#!/bin/bash\n[ "$1" = status ] && echo "Status: inactive"\nexit 0\n' > "$S/ufw"
  printf '#!/bin/bash\nexit 252\n' > "$S/firewall-cmd"
  # docker: state in $ST/docker; a container file holds true/false (running).
  # exec maps /opt/tak onto the release's tak/. With $ST/hub-exits the hub
  # container stops at once unless its CA exists.
  cat > "$S/docker" <<'EOF'
#!/bin/bash
D=$ST/docker
echo "docker $*" >> "$L/docker"
ver() { local n=${1#c4raven-}; n=${n#fedhub-certs-}; n=${n#fedhub-db-}; printf '%s' "${n#fedhub-}"; }
map() { printf '%s' "$FEDHUB_DOCKER_BASE/$(ver "$1")/tak"; }
state() {  # state NAME -> true|false
  case "$1" in
    fedhub-[0-9]*) if [ -e "$ST/hub-exits" ] && [ ! -s "$(map "$1")/federation-hub/certs/files/ca.pem" ]; then echo false; return; fi ;;
  esac
  echo true
}
case "$1" in
  --version) echo "Docker version 26.1.0" ;;
  info) exit 0 ;;
  ps) for f in "$D"/containers/*; do [ -e "$f" ] && basename "$f"; done; exit 0 ;;
  network) case "$2" in inspect) [ -e "$D/networks/$3" ] ;; create) touch "$D/networks/$3" ;; esac ;;
  image) [ -e "$D/images/$3" ] ;;
  container) n=${!#}; [ -e "$D/containers/$n" ] || exit 1
    [ "$3" = -f ] && cat "$D/containers/$n"; exit 0 ;;
  build) shift; while [ "$#" -gt 0 ]; do [ "$1" = -t ] && touch "$D/images/$2"; shift; done ;;
  run) n=""; shift; while [ "$#" -gt 0 ]; do [ "$1" = --name ] && n=$2; shift; done
       state "$n" > "$D/containers/$n"; echo id ;;
  start) state "$2" > "$D/containers/$2" ;;
  rm) shift; for a in "$@"; do [ "$a" = -f ] && continue; [ -e "$D/containers/$a" ] && echo "$a" >> "$L/docker-rm"; rm -f "$D/containers/$a"; done ;;
  restart) echo restarted >> "$L/docker-restarts" ;;
  logs) echo "(container log)" ;;
  exec)
    n=$2; shift 2; [ "$(cat "$D/containers/$n" 2>/dev/null)" = true ] || exit 1
    m=$(map "$n")
    if [ "$1" = java ]; then FH_AUTH_HOME=$m/federation-hub java "$2" "$3" "${4//\/opt\/tak/$m}"; exit; fi
    if [ "$1" = bash ] && [ "$2" = -c ]; then
      case "$3" in *dev/tcp*) [ -e "$ST/ports-down" ] && exit 1; exit 0 ;; esac
      exec bash -c "${3//\/opt\/tak/$m}"
    fi ;;
esac
EOF
  chmod +x "$S"/* "$T/mongosh-stub"
  declare -f make_fh_tree > "$T/fixture.sh"
}

# ---- harness ---------------------------------------------------------------------------
ok_()   { echo "PASS" >> "$RESULTS"; printf '  ok   %s\n' "$1"; }
fail_() { echo "FAIL $CUR: $1" >> "$RESULTS"; printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /' | tail -n 30; }
check() { local d=$1; shift; if "$@"; then ok_ "$d"; else fail_ "$d"; fi; }
run_fh() { OUT=$(bash "$REPO/install-fedhub.sh" "$@" 2>&1); RC=$?; }
expect_rc() { if [ "$RC" = "$1" ]; then ok_ "$2 (exit $RC)"; else fail_ "$2: expected exit $1, got $RC" "$OUT"; fi; }
has()   { grep -qF -- "$1" <<< "$OUT"; }
lacks() { ! grep -qF -- "$1" <<< "$OUT"; }
yget()  { sed -nE "s/^$2: *\"?([^\"]*)\"?\$/\\1/p" "$1" | head -n 1; }
load_libs() {
  # shellcheck disable=SC1091
  . "$REPO/lib/common.sh"; . "$REPO/lib/fedhub.sh"; . "$REPO/lib/fedhub_deb.sh"; . "$REPO/lib/fedhub_docker.sh"
}
t() {  # t NAME FUNCTION
  CUR=$1
  [ -n "$FILTER" ] && [[ "$1" != *"$FILTER"* ]] && return 0
  echo "== $1"
  ( new_env; "$2"; cd /; [ "${KEEP:-0}" = 1 ] && echo "   (kept $T)" || rm -rf "$T" ) ; local rc=$?
  [ "$rc" = 0 ] || echo "FAIL $1: test aborted (exit $rc)" >> "$RESULTS"
}

docker_install() {  # docker_install VERSION [args]
  local v=$1; shift
  make_zip "$T/rel/fedhub-docker-$v.zip" "$v"
  run_fh --artifact "$T/rel/fedhub-docker-$v.zip" --host fh.example.test "$@"
}
fhd() { printf '%s' "$FEDHUB_DOCKER_BASE/$1/tak/federation-hub"; }

# ---- Docker ------------------------------------------------------------------------------
test_docker_other_version_refused() {
  docker_install "$V1"; expect_rc 0 "install $V1"
  : > "$L/docker"
  docker_install "$V2"; expect_rc 1 "a second release while $V1's containers exist is refused"
  check "  ... names the containers to remove" has "docker rm -f fedhub-$V1 fedhub-db-$V1"
  check "  ... says the database folder is kept" has "$FEDHUB_DOCKER_DB_DIR"
  check "  ... before anything was created (no $V2 folder)" test ! -e "$FEDHUB_DOCKER_BASE/$V2"
  check "  ... no build, run or network for $V2" bash -c '! grep -qE "docker (build|run|network create)" "$1"' _ "$L/docker"
  check "  ... $V1's containers untouched" test "$(cat "$ST/docker/containers/fedhub-$V1")" = true
  run_fh --check; expect_rc 0 "$V1 still reported installed"
}

test_docker_upgrade_carries_state() {
  docker_install "$V1"; expect_rc 0 "install $V1"
  local o n pw1
  o=$(fhd "$V1"); n=$(fhd "$V2")
  pw1=$(yget "$o/configs/federation-hub-broker.yml" dbPassword)
  check "credentials copy saved, 0600" test "$(stat -c %a "$FEDHUB_DOCKER_BASE/.fedhub-db-credentials")" = 600
  touch "$FEDHUB_DOCKER_DB_DIR/WiredTiger"   # the database now holds data
  rm -f "$ST/docker/containers/"*            # what the refusal tells the user to do
  : > "$L/calls"
  docker_install "$V2"; expect_rc 0 "upgrade to $V2 after removing $V1's containers"
  check "same CA" cmp -s "$o/certs/files/ca.pem" "$n/certs/files/ca.pem"
  check "same certificate passwords" cmp -s "$o/certs/.fedhub-cert-passwords" "$n/certs/.fedhub-cert-passwords"
  check "admin p12 carried" cmp -s "$o/certs/files/fedhub-admin.p12" "$n/certs/files/fedhub-admin.p12"
  check "no new CA or certificates minted" bash -c '! grep -qE "makeRootCa|makeCert" "$1"' _ "$L/calls"
  check "authorised admins carried" cmp -s "$o/authorized_users.yml" "$n/authorized_users.yml"
  check "federation policy carried" cmp -s "$o/ui_generated_policy.json" "$n/ui_generated_policy.json"
  check "database password carried (the existing user's)" test "$(yget "$n/configs/federation-hub-broker.yml" dbPassword)" = "$pw1"
  check "new containers running" bash -c '[ "$(cat "$1/fedhub-$2")" = true ] && [ "$(cat "$1/fedhub-db-$2")" = true ]' _ "$ST/docker/containers" "$V2"
  check "no password in the output" lacks "$pw1"
  run_fh --check; expect_rc 0 "--check after the upgrade"
}

test_docker_reinstall_reuses_db_password() {
  docker_install "$V2"; expect_rc 0 "install"
  local b pw
  b=$(fhd "$V2")/configs/federation-hub-broker.yml
  pw=$(yget "$b" dbPassword)
  touch "$FEDHUB_DOCKER_DB_DIR/WiredTiger"
  # Containers and the release folder gone; the database folder stays.
  rm -f "$ST/docker/containers/"*; rm -rf "${FEDHUB_DOCKER_BASE:?}/$V2"
  docker_install "$V2"; expect_rc 0 "re-install with a fresh release folder"
  check "the saved password, not a new one" test "$(yget "$b" dbPassword)" = "$pw"
  check "says it restored the credentials" has "database credentials of the existing database restored"
}

test_docker_unknown_db_password() {
  mkdir -p "$FEDHUB_DOCKER_DB_DIR"; touch "$FEDHUB_DOCKER_DB_DIR/WiredTiger"
  docker_install "$V2"; expect_rc 1 "data in the database folder, no known password: stops"
  check "  ... explains" has "already holds a database"
  check "  ... the DB container was not started" bash -c '! grep -q "run .*--name fedhub-db-" "$1"' _ "$L/docker"
  check "  ... no random password written" test -z "$(yget "$(fhd "$V2")/configs/federation-hub-broker.yml" dbPassword)"
}

test_docker_fresh_random_password() {
  docker_install "$V2"; expect_rc 0 "fresh install"
  local b pw; b=$(fhd "$V2")/configs/federation-hub-broker.yml
  pw=$(yget "$b" dbPassword)
  check "random 32-hex password" grep -qE '^dbPassword: "[0-9a-f]{32}"$' "$b"
  check "saved copy matches" grep -qxF "dbPassword: \"$pw\"" "$FEDHUB_DOCKER_BASE/.fedhub-db-credentials"
  check "password not printed" lacks "$pw"
  run_fh; expect_rc 0 "re-run"
  check "re-run: nothing fixed" lacks "fixed:"
}

test_docker_port_check_first() {
  echo 9101 > "$ST/ports-up"
  docker_install "$V2"; expect_rc 1 "port 9101 taken: stops"
  check "  ... names the port" has "port 9101 is already in use"
  check "  ... before any container or network" bash -c '! grep -qE "docker (run|network create)" "$1"' _ "$L/docker"
}

test_docker_certs_when_hub_exits() {
  touch "$ST/hub-exits"
  docker_install "$V2"; expect_rc 0 "hub exits without its keystore: certificates made anyway"
  local f; f=$(fhd "$V2")/certs/files
  check "server keystore made" test -s "$f/fh.example.test.jks"
  check "in a temporary container (sleep entrypoint, same mount)" grep -q "run -d --rm --name c4raven-fedhub-certs-$V2 --entrypoint sleep -v $FEDHUB_DOCKER_BASE/$V2/tak:/opt/tak:z fedhub:$V2 infinity" "$L/docker"
  check "temporary container removed" grep -qx "c4raven-fedhub-certs-$V2" "$L/docker-rm"
  check "hub running afterwards" test "$(cat "$ST/docker/containers/fedhub-$V2")" = true
  check "warned" has "making the certificates in a temporary container"
}

test_docker_check_needs_running() {
  docker_install "$V2"; expect_rc 0 "install"
  run_fh --check; expect_rc 0 "--check while running"
  echo false > "$ST/docker/containers/fedhub-$V2"
  run_fh --check; expect_rc 3 "--check: hub container stopped -> not installed"
  echo true > "$ST/docker/containers/fedhub-$V2"; echo false > "$ST/docker/containers/fedhub-db-$V2"
  run_fh --check; expect_rc 3 "--check: DB container stopped -> not installed"
}

test_docker_snap_refused() {
  touch "$ST/snap-docker"
  docker_install "$V2"; expect_rc 1 "snap Docker refused"
  check "  ... says why and what to do" bash -c 'grep -q "snap package" <<< "$1" && grep -q "snap remove docker" <<< "$1"' _ "$OUT"
  check "  ... nothing unpacked" test ! -e "$FEDHUB_DOCKER_BASE/$V2"
  (load_libs; PATH=$T/snapbin:$PATH; mkdir -p "$T/snapbin"; rm -f "$ST/snap-docker"
   printf '#!/bin/sh\n' > "$T/snapbin/docker"; chmod +x "$T/snapbin/docker"
   fh_docker_is_snap) && fail_ "a docker outside /snap with no snap is not snap" || ok_ "a docker outside /snap with no snap is not snap"
}

# ---- .deb --------------------------------------------------------------------------------
deb_install() {
  DEB=$(make_deb "$T/rel" 5.8-RELEASE75)
  run_fh --artifact "$DEB" --host fh.example.test "$@"
}

test_deb_trixie_no_java17() {
  set_os debian trixie
  echo openjdk-17-jdk > "$ST/deb-depends"; touch "$ST/apt-none-openjdk-17-jdk"
  deb_install; expect_rc 1 "Debian 13: no openjdk-17-jdk -> stops"
  check "  ... points at the Docker zip" bash -c 'grep -q "openjdk-17-jdk" <<< "$1" && grep -q "Docker release" <<< "$1"' _ "$OUT"
  check "  ... before MongoDB or the package" bash -c '! grep -qE "install .*(mongodb-org|\.deb)" "$1" && [ ! -e "$2/mongodb-org-7.0.list" ]' _ "$L/apt" "$APT_SOURCES_DIR"
  check "  ... refreshed the lists once first" grep -q "apt-get update" "$L/apt"
  rm "$ST/apt-none-openjdk-17-jdk"
  deb_install; expect_rc 0 "with openjdk-17-jdk available it installs"
}

test_deb_debian_arm64() {
  set_os debian bookworm; export FEDHUB_ARCH=arm64
  deb_install; expect_rc 1 "arm64 Debian: stops"
  check "  ... says amd64 only, not AVX" bash -c 'grep -q "amd64 only" <<< "$1" && ! grep -q AVX <<< "$1"' _ "$OUT"
  check "  ... mentions ARMv8.2-A for Ubuntu arm64" has "ARMv8.2-A"
  check "  ... nothing installed" bash -c '[ ! -s "$1" ] || ! grep -q "install" "$1"' _ "$L/apt"
}

test_deb_ubuntu_arm64() {
  export FEDHUB_ARCH=arm64; touch "$ST/mongo-install-fails"
  deb_install; expect_rc 1 "Ubuntu arm64, mongodb-org fails"
  check "repo line for arm64" grep -q 'arch=arm64 ' "$APT_SOURCES_DIR/mongodb-org-8.0.list"
  check "error mentions ARMv8.2-A, not AVX" bash -c 'grep -q "ARMv8.2-A" <<< "$1" && ! grep -q AVX <<< "$1"' _ "$OUT"
  rm "$ST/mongo-install-fails"
  deb_install; expect_rc 0 "then installs"
}

test_deb_mongo_login() {
  deb_install; expect_rc 0 "install"
  check "configure.sh ran once" test "$(grep -c configure "$L/calls")" = 1
  check "password never on mongosh's command line" bash -c '! grep -q generatedpw "$1"' _ "$L/mongosh"
  check "nor in the output" lacks generatedpw
  : > "$L/calls"
  run_fh; expect_rc 0 "re-run"
  check "re-run: login works, configure.sh not run" bash -c '! grep -q configure "$1"' _ "$L/calls"
  # The user was never created (mongod was slow when configure.sh ran).
  rm "$ST/mongo-user"
  run_fh; expect_rc 0 "missing database user: re-run heals it"
  check "  ... by running configure.sh again" grep -q configure "$L/calls"
  check "  ... warned first" has "can't log in to MongoDB"
}

test_deb_mongo_login_fails() {
  printf 'someoneelses' > "$ST/mongo-user"   # the user exists with another password
  deb_install; expect_rc 1 "user exists with another password: stops"
  check "  ... explains" has "still can't log in"
  check "  ... no password shown" bash -c '! grep -qE "generatedpw|someoneelses" <<< "$1"' _ "$OUT"
  rm "$ST/mongo-user"; touch "$ST/mongo-down"
  deb_install; expect_rc 1 "mongod not answering: stops"
  check "  ... says so" has "not answering"
}

test_deb_mongosh_required() {
  rm "$S/fake-mongosh"
  deb_install; expect_rc 0 "mongosh missing: installed (mongodb-mongosh)"
  check "  ... via apt" grep -q "install -y -q mongodb-mongosh" "$L/apt"
  rm "$S/fake-mongosh"; touch "$ST/no-mongosh-pkg"
  run_fh; expect_rc 1 "mongosh can't be installed: stops"
  check "  ... names it" has "mongosh is not installed"
}

test_deb_generator_unit() {
  echo /run/systemd/generator.late/federation-hub.service > "$ST/fragment"
  check "lib/fedhub.sh's fh_unit_exists is fooled by the generated unit" bash -c '. "$1/lib/common.sh"; . "$1/lib/fedhub.sh"; fh_unit_exists federation-hub' _ "$REPO"
  deb_install; expect_rc 0 "install with only a SysV-generated unit"
  local u=$SYSTEMD_DIR/federation-hub.service
  check "real unit written" test -f "$u"
  check "supervised: wait -n then fail, Restart=on-failure" bash -c 'grep -q "& wait -n; exit 1\"$" "$1" && grep -qx "Restart=on-failure" "$1"' _ "$u"
  check "no RemainAfterExit" bash -c '! grep -q RemainAfterExit "$1"' _ "$u"
  run_fh --check
  check "--check counts the written unit (installed, whatever Raven's wiring)" has "Federation Hub: installed (deb"
}

test_deb_mongod_enabled() {
  printf '#!/bin/sh\nexit 0\n' > "$S/fake-mongod"; chmod +x "$S/fake-mongod"
  touch "$ST/active/mongod"   # running, started by hand, not enabled
  deb_install; expect_rc 0 "install"
  check "mongod enabled" test -e "$ST/enabled/mongod"
  check "  ... reported" has "enabled mongod"
}

test_deb_dead_hub_restarted() {
  deb_install; expect_rc 0 "install"
  : > "$L/restarts"
  touch "$ST/substate-exited"
  run_fh; expect_rc 0 "'active (exited)' hub"
  check "  ... restarted" grep -qx federation-hub "$L/restarts"
  : > "$L/restarts"
  touch "$ST/ports-down" "$ST/heal-on-restart"
  run_fh; expect_rc 0 "running but not listening"
  check "  ... restarted once" test "$(grep -c federation-hub "$L/restarts")" = 1
  check "  ... reported" has "running but not listening"
  : > "$L/restarts"; rm -f "$ST/heal-on-restart"; touch "$ST/ports-down"
  run_fh; expect_rc 1 "still not listening after the restart: fails with the journal"
  check "  ... journal shown" grep -q 'journalctl -u federation-hub' "$L/journalctl"
}

# The unit 04-finish-and-start.sh used to write: plain `wait`, RemainAfterExit,
# no Restart= -- a killed hub stays down.
write_old_unit() {
  cat > "$SYSTEMD_DIR/federation-hub.service" <<EOF
[Unit]
Description=Federation Hub Service
After=network.target mongod.service
Requires=mongod.service

[Service]
Type=simple
WorkingDirectory=$FEDHUB_ROOT/scripts
ExecStart=/bin/bash -c "./federation-hub-policy.sh & ./federation-hub-plugin-manager.sh & ./federation-hub-ui.sh & ./federation-hub-broker.sh & wait"
RemainAfterExit=yes
User=$ME

[Install]
WantedBy=multi-user.target
EOF
}

test_deb_old_unit_upgraded() {
  deb_install; expect_rc 0 "install"
  local u=$SYSTEMD_DIR/federation-hub.service
  write_old_unit
  run_fh --check
  check "--check notes the old unit" has "does not restart Federation Hub if it dies"
  check "  ... and names --repair-unit" has "--repair-unit"
  local rc_check=$RC
  : > "$L/restarts"
  RAVEN_FEDHUB_SKIP=1 run_fh --repair-unit; expect_rc 0 "--repair-unit (even with RAVEN_FEDHUB_SKIP=1)"
  check "  ... Restart=on-failure now" grep -qx "Restart=on-failure" "$u"
  check "  ... supervised wait -n" grep -q "& wait -n; exit 1\"$" "$u"
  check "  ... no RemainAfterExit" bash -c '! grep -q RemainAfterExit "$1"' _ "$u"
  check "  ... old unit backed up" bash -c 'ls "$1".bak-* >/dev/null 2>&1 && grep -q RemainAfterExit "$1".bak-*' _ "$u"
  check "  ... hub not restarted" bash -c '! grep -q federation-hub "$1"' _ "$L/restarts"
  check "  ... reported" has "upgraded federation-hub.service"
  run_fh --check
  check "--check: no note any more" lacks "does not restart Federation Hub"
  check "  ... same exit code as before" test "$RC" = "$rc_check"
  run_fh --repair-unit; expect_rc 0 "--repair-unit again"
  check "  ... nothing to do" has "nothing to do"
  check "  ... one backup only" test "$(ls "$u".bak-* | wc -l)" = 1
  write_old_unit; rm -f "$u".bak-*
  deb_install; expect_rc 0 "a full re-run"
  check "  ... also upgrades the old unit" grep -qx "Restart=on-failure" "$u"
}

test_deb_custom_unit_kept() {
  deb_install; expect_rc 0 "install"
  local u=$SYSTEMD_DIR/federation-hub.service
  write_old_unit; printf 'Restart=always\n' >> "$u"
  cp "$u" "$T/custom"
  run_fh --repair-unit; expect_rc 0 "--repair-unit on a unit that already has Restart="
  check "  ... left exactly as it was" cmp -s "$u" "$T/custom"
}

test_repair_unit_needs_deb() {
  run_fh --repair-unit; expect_rc 1 "--repair-unit with no .deb install"
  check "  ... says it is for .deb installs" has "for .deb installs"
}

t docker_other_version   test_docker_other_version_refused
t docker_upgrade         test_docker_upgrade_carries_state
t docker_reinstall       test_docker_reinstall_reuses_db_password
t docker_unknown_db_pw   test_docker_unknown_db_password
t docker_fresh_pw        test_docker_fresh_random_password
t docker_port_first      test_docker_port_check_first
t docker_certs_offline   test_docker_certs_when_hub_exits
t docker_check_running   test_docker_check_needs_running
t docker_snap            test_docker_snap_refused
t deb_trixie_java        test_deb_trixie_no_java17
t deb_debian_arm64       test_deb_debian_arm64
t deb_ubuntu_arm64       test_deb_ubuntu_arm64
t deb_mongo_login        test_deb_mongo_login
t deb_mongo_login_fails  test_deb_mongo_login_fails
t deb_mongosh_required   test_deb_mongosh_required
t deb_generator_unit     test_deb_generator_unit
t deb_mongod_enabled     test_deb_mongod_enabled
t deb_dead_hub           test_deb_dead_hub_restarted
t deb_old_unit           test_deb_old_unit_upgraded
t deb_custom_unit        test_deb_custom_unit_kept
t repair_unit_no_deb     test_repair_unit_needs_deb

echo
pass=$(grep -c '^PASS' "$RESULTS"); fail=$(grep -c '^FAIL' "$RESULTS")
echo "$pass passed, $fail failed"
grep '^FAIL' "$RESULTS" | sed 's/^FAIL /  - /'
rm -f "$RESULTS"
[ "$fail" = 0 ]
