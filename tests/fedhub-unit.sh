#!/usr/bin/env bash
# Single-quoted bash -c snippets take their arguments positionally on purpose.
# shellcheck disable=SC2016,SC2015,SC2088
# Tests for install-fedhub.sh and the Federation Hub step of the updater,
# without root, Docker, MongoDB or a real Federation Hub: every system command
# it uses (sudo, systemctl, apt-get, dpkg-*, docker, dnf, java, ss, ufw, ...)
# is a stub on PATH, and every path points into a temporary directory.
#
#   bash tests/fedhub-unit.sh            # all tests
#   bash tests/fedhub-unit.sh deb_e2e    # tests whose name matches
#
# Safe on a live server: it refuses to run unless `sudo` resolves to its own
# stub, and nothing it runs touches /opt, /etc or /var.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ME=$(id -un)
FILTER="${1:-}"
RESULTS=$(mktemp "${TMPDIR:-/tmp}/fedhub-results.XXXXXX")

# ---- fixture -----------------------------------------------------------------------
new_env() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/fedhub-test.XXXXXX")
  S=$T/shims; ST=$T/state; L=$T/log
  mkdir -p "$S" "$ST/active" "$ST/enabled" "$ST/docker/images" "$ST/docker/networks" "$ST/docker/containers" \
           "$L" "$T/home/Downloads" "$T/systemd" "$T/systemd-lib" "$T/optbin" "$T/etc"
  write_shims
  export PATH="$S:$PATH" TMPDIR=$T HOME=$T/home
  unset SUDO_USER RAVEN_UPDATER_LOCKED RAVEN_FEDHUB_ARTIFACT RAVEN_FEDHUB_DEB RAVEN_DOMAIN RAVEN_FEDHUB_SKIP RAVEN_VENV
  export ST L T
  export FEDHUB_ROOT=$T/opt/tak/federation-hub FEDHUB_TAK_USER=$ME FEDHUB_ROOT_OWNER=$ME
  export FEDHUB_DOCKER_BASE=$T/opt/fedhub-docker FEDHUB_DOCKER_DB_DIR=$T/var/lib/fedhub-docker-mongodb
  export SYSTEMD_DIR=$T/systemd SYSTEMD_LIB_DIRS=$T/systemd-lib MONGOD_CONF=$T/etc/mongod.conf
  export APT_SOURCES_DIR=$T/etc/apt KEYRING_DIR=$T/keyrings YUM_REPOS_DIR=$T/etc/yum.repos.d
  export FEDHUB_MONGOD_BIN=fake-mongod FEDHUB_WAIT_SECS=4 FEDHUB_TTY=$T/no-tty
  export RAVEN_USER=$ME RAVEN_HOME=$T/raven RAVEN_ASSUME_SYSTEMD=1 NO_COLOR=1 RETRY_ATTEMPTS=1
  export OS_RELEASE=$T/os-release
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
  # What generate-config writes: every RAVEN_FEDHUB_* key with the defaults.
  cat > "$r/data/config.yml" <<'EOF'
RAVEN_FEDHUB_API_ADDRESS: https://tak.c4raven.net:9100/api
RAVEN_FEDHUB_BROKER_ADDRESS: tak.c4raven.net:9102
RAVEN_FEDHUB_CLIENT_CERT: /opt/tak/federation-hub/certs/files/fedhub-admin.pem
RAVEN_FEDHUB_ENABLE: true
RAVEN_MEDIAMTX_TOKEN: keepme
SECRET_KEY: s3cret
SQLALCHEMY_DATABASE_URI: postgresql+psycopg://raven:pw@127.0.0.1/raven
EOF
  printf 'RAVEN_DATA_FOLDER=%s\nRAVEN_FEDHUB_ENABLE=False\nRAVEN_MEDIAMTX_ENABLE=True\n' "$r/data" > "$r/.raven-secrets.env"
  chmod 600 "$r/.raven-secrets.env"
  printf 'RAVEN_DOMAIN=\n' > "$r/.install-answers"
  touch "$T/systemd/raven.service"
}

# The tree a Federation Hub release unpacks to (federation-hub/ under DIR).
make_fh_tree() {
  local fh=$1 docker=${2:-0}
  mkdir -p "$fh/certs" "$fh/configs" "$fh/scripts/db" "$fh/jars"
  touch "$fh/jars/federation-hub-broker.jar" "$fh/jars/federation-hub-manager.jar"
  cat > "$fh/certs/makeRootCa.sh" <<'EOF'
#!/bin/bash
[ -n "$CAPASS" ] && [ -n "$STATE" ] && [ -n "$ORGANIZATIONAL_UNIT" ] || { echo "metadata not set" >&2; exit 1; }
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
    echo 'keystoreType: JKS'
    echo 'keystoreFile: /opt/tak/federation-hub/certs/files/takserver.jks'
    echo 'keystorePassword: atakatak'
    echo 'truststoreFile: /opt/tak/federation-hub/certs/files/fed-truststore.jks'
    echo 'truststorePassword: atakatak'
    echo 'caFile: /opt/tak/federation-hub/certs/files/ca.pem'
    echo 'v1Enabled: false'
    echo 'v2Enabled: true'
    echo '# a comment that must survive'
    if [ "$docker" = 1 ]; then echo 'dbUsername: martiuser'; echo 'dbPassword: '; echo 'dbHost: localhost'; fi
  } > "$fh/configs/federation-hub-broker.yml"
  cat > "$fh/configs/federation-hub-ui.yml" <<'EOF'
keystoreType: JKS
keystoreFile: /opt/tak/federation-hub/certs/files/takserver.jks
keystorePassword: atakatak
truststoreFile: /opt/tak/federation-hub/certs/files/truststore-root.jks
truststorePassword: atakatak
keyAlias: takserver
port: 9100
EOF
  cat > "$fh/scripts/federation-hub-ui.sh" <<'EOF'
#!/bin/bash
export FEDERATION_HUB=/opt/tak/federation-hub
export JDK_JAVA_OPTIONS="-Dio.netty.tmpdir=${FEDERATION_HUB}/jetty-temp -DIGNITE_UPDATE_NOTIFIER=false"
java -jar ${FEDERATION_HUB}/jars/federation-hub-ui.war "$@"
EOF
  cat > "$fh/scripts/db/configure.sh" <<'EOF'
#!/bin/sh
echo "db.createUser({user: 'martiuser', pwd: 'TOPSECRETPW', roles: []})"
grep -q '^dbUsername:' "$FEDHUB_ROOT/configs/federation-hub-broker.yml" || echo "dbUsername: martiuser" >> "$FEDHUB_ROOT/configs/federation-hub-broker.yml"
echo "dbPassword: generatedpw" >> "$FEDHUB_ROOT/configs/federation-hub-broker.yml"
printf 'security:\n  authorization: "enabled"\n' > "$MONGOD_CONF"
echo configure >> "$L/calls"
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
  cat > "$S/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$L/systemctl"
q=0; args=()
for a in "$@"; do case "$a" in --quiet|-q|--no-pager) q=1 ;; *) args+=("$a") ;; esac; done
set -- "${args[@]}"
act=$1; shift
now=0; [ "${1:-}" = --now ] && { now=1; shift; }
for u in "$@"; do
  u=${u%.service}
  case "$act" in
    is-active)  [ -e "$ST/active/$u" ] || exit 3 ;;
    is-enabled) [ -e "$ST/enabled/$u" ] || exit 1 ;;
    start|restart) [ -e "$ST/fail-$u" ] && exit 1; touch "$ST/active/$u" ;;
    stop) rm -f "$ST/active/$u" ;;
    enable) touch "$ST/enabled/$u"; [ "$now" = 1 ] && touch "$ST/active/$u" ;;
    cat) [ -e "$SYSTEMD_DIR/$u.service" ] || exit 1 ;;
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
case "$3" in Package) echo takserver-fed-hub ;; Version) v=${b#takserver-fed-hub_}; echo "${v%_all.deb}" ;; esac
EOF
  cat > "$S/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$L/apt"
for a in "$@"; do
  case "$a" in
    /*.deb) . "$T/fixture.sh"; make_fh_tree "$FEDHUB_ROOT"; b=${a##*/}; v=${b#takserver-fed-hub_}; echo "${v%_all.deb}" > "$ST/pkg-version" ;;
    mongodb-org) printf '#!/bin/sh\nexit 0\n' > "$T/shims/fake-mongod"; chmod +x "$T/shims/fake-mongod" ;;
  esac
done
exit 0
EOF
  cat > "$S/dnf" <<'EOF'
#!/bin/bash
echo "dnf $*" >> "$L/dnf"
case " $* " in *" docker-ce "*) ln -sf "$T/optbin/docker" "$T/shims/docker" ;; esac
case " $* " in *" config-manager "*) mkdir -p "$YUM_REPOS_DIR"; touch "$YUM_REPOS_DIR/docker-ce.repo" ;; esac
exit 0
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
  # mongosh: logs in unless the test made MongoDB refuse.
  printf '#!/bin/bash\necho "mongosh $*" >> "$L/mongosh"\n[ -e "$ST/mongo-refuse" ] && exit 2\nexit 0\n' > "$S/mongosh"
  cat > "$S/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$L/calls"
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { echo key > "$2"; }; shift; done
EOF
  cat > "$S/gpg" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do [ "$1" = -o ] && { echo gpg > "$2"; }; shift; done
EOF
  cat > "$S/ufw" <<'EOF'
#!/bin/bash
echo "ufw $*" >> "$L/ufw"
case "$1" in
  status) [ -e "$ST/ufw-active" ] && echo "Status: active" || echo "Status: inactive"; cat "$ST/ufw-rules" 2>/dev/null ;;
  allow) echo "$2 ALLOW Anywhere" >> "$ST/ufw-rules" ;;
esac
EOF
  printf '#!/bin/bash\necho "firewall-cmd $*" >> "$L/firewall"\nexit 252\n' > "$S/firewall-cmd"
  # docker: state in $ST/docker; exec runs the command with /opt/tak mapped
  # onto the unpacked release.
  cat > "$T/optbin/docker" <<'EOF'
#!/bin/bash
D=$ST/docker
echo "docker $*" >> "$L/docker"
map() { local n=${1#fedhub-}; printf '%s' "$FEDHUB_DOCKER_BASE/$n/tak"; }
case "$1" in
  --version) echo "Docker version 26.1.0" ;;
  info) exit 0 ;;
  network) case "$2" in inspect) [ -e "$D/networks/$3" ] ;; create) touch "$D/networks/$3" ;; esac ;;
  image) [ -e "$D/images/$3" ] ;;
  container) # container inspect [-f fmt] NAME
    n=${!#}; [ -e "$D/containers/$n" ] || exit 1
    [ "$3" = -f ] && cat "$D/containers/$n"; exit 0 ;;
  build) shift; while [ "$#" -gt 0 ]; do [ "$1" = -t ] && touch "$D/images/$2"; shift; done ;;
  run) n=""; while [ "$#" -gt 0 ]; do [ "$1" = --name ] && n=$2; shift; done; echo true > "$D/containers/$n"; echo id ;;
  start) echo true > "$D/containers/$2" ;;
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
  chmod +x "$S"/* "$T/optbin/docker"
  declare -f make_fh_tree > "$T/fixture.sh"
}

# ---- harness ---------------------------------------------------------------------------
ok_()   { echo "PASS" >> "$RESULTS"; printf '  ok   %s\n' "$1"; }
fail_() { echo "FAIL $CUR: $1" >> "$RESULTS"; printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       | /' | tail -n 30; }
check() { local d=$1; shift; if "$@"; then ok_ "$d"; else fail_ "$d"; fi; }
run_fh() { OUT=$(bash "$REPO/install-fedhub.sh" "$@" 2>&1); RC=$?; }
expect_rc() { if [ "$RC" = "$1" ]; then ok_ "$2 (exit $RC)"; else fail_ "$2: expected exit $1, got $RC" "$OUT"; fi; }
yaml_get() { python3 -I -c 'import sys, yaml; v = (yaml.safe_load(open(sys.argv[1])) or {}).get(sys.argv[2]); print("" if v is None else v)' "$1" "$2"; }
# Source the libraries into the test shell (functions only, nothing runs).
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

# ---- tests -------------------------------------------------------------------------------
test_skip() {
  local lock=$T/c4raven-updater.lock
  export RAVEN_FEDHUB_SKIP=1
  run_fh; expect_rc 2 "RAVEN_FEDHUB_SKIP=1 exits 2"
  check "says it skipped" grep -q skipped <<< "$OUT"
  check "  ... before the lock (no lock file)" test ! -e "$lock"
  run_fh --artifact /nope; expect_rc 2 "RAVEN_FEDHUB_SKIP=1 wins over --artifact"
  run_fh --check; expect_rc 3 "--check ignores RAVEN_FEDHUB_SKIP (reports not installed)"
  check "--check creates no lock file" test ! -e "$lock"
  unset RAVEN_FEDHUB_SKIP
  RAVEN_FEDHUB_ARTIFACT="" run_fh; expect_rc 2 "RAVEN_FEDHUB_ARTIFACT set but empty skips"
  RAVEN_FEDHUB_DEB="" run_fh; expect_rc 2 "RAVEN_FEDHUB_DEB set but empty skips"
  RAVEN_FEDHUB_ARTIFACT=/nope RAVEN_FEDHUB_DEB="" run_fh; expect_rc 1 "non-empty RAVEN_FEDHUB_ARTIFACT wins over an empty RAVEN_FEDHUB_DEB (used: no such file)"
  RAVEN_FEDHUB_ARTIFACT="" run_fh --artifact /nope; expect_rc 1 "an explicit --artifact overrides an empty RAVEN_FEDHUB_ARTIFACT"
  RAVEN_FEDHUB_ARTIFACT="" run_fh --check; expect_rc 3 "--check ignores an empty RAVEN_FEDHUB_ARTIFACT"
  # --check while update.sh holds the lock: no lock taken, so it still answers.
  OUT=$(flock "$lock" bash "$REPO/install-fedhub.sh" --check 2>&1); RC=$?
  expect_rc 3 "--check works while another process holds the updater lock"
}

test_discovery() {
  load_libs
  local d1 d2 z
  d1=$(make_deb "$HOME/Downloads/Federation hub docs and deb" 5.8-RELEASE9)
  d2=$(make_deb "$HOME/Downloads/Federation hub docs and deb" 5.8-RELEASE75)
  make_zip "$HOME/Downloads/sub dir/takserver-fed-hub-docker-5.8-RELEASE-75.zip" 5.8-RELEASE-75
  make_zip "$HOME/Downloads/FedHub-Docker-5.7-RELEASE-20.zip" 5.7-RELEASE-20
  touch "$HOME/Downloads/fedhub-admin.p12"
  mkdir -p "$HOME/Downloads/a/b/c/d"; make_deb "$HOME/Downloads/a/b/c/d" 9.9-RELEASE1 >/dev/null
  check "finds both forms (spaces in folders), not the .p12, not below depth 3" \
    test "$(fh_find_artifacts | wc -l)" = 4
  DISTRO_FAMILY=debian
  check "Debian: newest .deb by sort -V (RELEASE75 > RELEASE9)" test "$(fh_pick_artifact)" = "$d2"
  DISTRO_FAMILY=rhel
  check "RHEL: only the Docker zip, newest" test "$(fh_pick_artifact)" = "$HOME/Downloads/sub dir/takserver-fed-hub-docker-5.8-RELEASE-75.zip"
  rm -f "$d1" "$d2"; DISTRO_FAMILY=debian
  check "Debian without a .deb falls back to the zip" test "$(fh_pick_artifact)" = "$HOME/Downloads/sub dir/takserver-fed-hub-docker-5.8-RELEASE-75.zip"
  z="$HOME/Downloads/sub dir/takserver-fed-hub-docker-5.8-RELEASE-75.zip"
  check "zip recognised by content" test "$(fh_artifact_kind "$z")" = zip
  printf 'not a zip' > "$T/other.zip"
  check "random zip rejected" test -z "$(fh_artifact_kind "$T/other.zip")"
  check "clean: double quotes" test "$(fh_clean_path "  \"/a b/c.deb\" ")" = "/a b/c.deb"
  check "clean: single quotes" test "$(fh_clean_path "'/a b/c.deb'")" = "/a b/c.deb"
  check "clean: escaped spaces" test "$(fh_clean_path '/a\ b/c.deb')" = "/a b/c.deb"
  check "clean: ~ expands to the user's home" test "$(fh_clean_path '~/Downloads/x.deb')" = "$HOME/Downloads/x.deb"
  check "clean: ~user" test "$(fh_clean_path "~$ME/x")" = "$HOME/x"
}

test_prompt() {
  local deb out rc
  deb=$(make_deb "$T/elsewhere/with space" 5.8-RELEASE75)
  # Declined the found one (none here), then a bad path, then a quoted one.
  printf '%s\n' "/no/such/file.deb" "'$deb'" > "$T/tty"
  out=$(load_libs; FEDHUB_TTY=$T/tty; fh_choose_artifact; echo "ARTIFACT=$ARTIFACT") ; rc=$?
  check "prompt loop: bad path re-asked, quoted path with spaces accepted" grep -qxF "ARTIFACT=$deb" <<< "$out"
  printf '\n' > "$T/tty"
  out=$(load_libs; FEDHUB_TTY=$T/tty; fh_choose_artifact; echo reached) ; rc=$?
  check "blank answer skips with exit 2" test "$rc" = 2
  printf 'never\n' > "$T/tty"
  out=$(load_libs; FEDHUB_TTY=$T/tty; fh_choose_artifact) ; rc=$?
  check "'never' exits 2" test "$rc" = 2
  check "'never' is remembered, RAVEN_DOMAIN kept" grep -qx 'RAVEN_FEDHUB_DECLINED=1' "$RAVEN_HOME/.install-answers"
  check "answers file keeps RAVEN_DOMAIN" grep -qx 'RAVEN_DOMAIN=' "$RAVEN_HOME/.install-answers"
  FEDHUB_TTY=$T/tty run_fh; expect_rc 2 "declined: a later run skips without asking"
  # Found in Downloads, answered n then gave the found file explicitly.
  rm -f "$RAVEN_HOME/.install-answers"
  deb=$(make_deb "$HOME/Downloads" 5.8-RELEASE75)
  printf 'y\n' > "$T/tty"
  out=$(load_libs; FEDHUB_TTY=$T/tty; fh_choose_artifact; echo "ARTIFACT=$ARTIFACT")
  check "found file offered and accepted with y" grep -qxF "ARTIFACT=$deb" <<< "$out"
  # No terminal: never prompts.
  run_fh < /dev/null; expect_rc 2 "no tty + found file + no --yes: exit 2 without prompting"
  check "  ... and names the file" grep -qF "$deb" <<< "$OUT"
  rm -f "$deb"
  run_fh < /dev/null; expect_rc 2 "no tty + nothing found: exit 2"
}

test_mode() {
  local out rc
  out=$(load_libs; DISTRO_FAMILY=debian; ARTIFACT=x.deb; fh_mode_for deb; echo "$MODE"); check ".deb on Debian -> deb mode" test "$out" = deb
  out=$(load_libs; DISTRO_FAMILY=rhel; ARTIFACT=x.zip; fh_mode_for zip; echo "$MODE"); check ".zip on RHEL -> docker mode" test "$out" = docker
  out=$(load_libs; DISTRO_FAMILY=debian; ARTIFACT=x.zip; fh_mode_for zip; echo "$MODE"); check ".zip on Debian -> docker mode" test "$out" = docker
  out=$(load_libs; DISTRO_FAMILY=rhel; ARTIFACT=x.deb; fh_mode_for deb 2>&1); rc=$?
  check ".deb on RHEL is refused" test "$rc" = 1
  check "  ... suggesting the Docker zip" grep -q "Docker release" <<< "$out"
  set_os rocky 9 "rhel centos fedora"
  local deb; deb=$(make_deb "$T/d" 5.8-RELEASE75)
  run_fh --artifact "$deb" --host h.example; expect_rc 1 "install-fedhub.sh refuses a .deb on Rocky"
}

test_mongo_repo() {
  load_libs
  set_os ubuntu jammy;  check "jammy -> 7.0 jammy"  test "$(fh_mongo_repo)" = "$(printf '7.0\tubuntu jammy/mongodb-org/7.0 multiverse')"
  set_os ubuntu noble;  check "noble -> 8.0 noble"  test "$(fh_mongo_repo)" = "$(printf '8.0\tubuntu noble/mongodb-org/8.0 multiverse')"
  set_os ubuntu questing; check "newer Ubuntu -> 8.0 noble" test "$(fh_mongo_repo)" = "$(printf '8.0\tubuntu noble/mongodb-org/8.0 multiverse')"
  set_os debian bookworm; check "bookworm -> 7.0 debian main" test "$(fh_mongo_repo)" = "$(printf '7.0\tdebian bookworm/mongodb-org/7.0 main')"
  set_os debian trixie; check "unknown Debian -> bookworm" test "$(fh_mongo_repo)" = "$(printf '7.0\tdebian bookworm/mongodb-org/7.0 main')"
}

deb_install() {
  touch "$ST/ufw-active"
  DEB=$(make_deb "$HOME/Downloads/Federation hub docs and deb" 5.8-RELEASE75)
  run_fh --artifact "$DEB" --host fh.example.test
}

test_deb_e2e() {
  deb_install; expect_rc 0 "deb install from a path with spaces"
  local c=$RAVEN_HOME/data/config.yml f=$FEDHUB_ROOT/certs/files fhd=$RAVEN_HOME/data/fedhub
  check "MongoDB repo written for noble" grep -q 'noble/mongodb-org/8.0' "$APT_SOURCES_DIR/mongodb-org-8.0.list"
  check "apt-get installed the .deb as one absolute argument" grep -qF "$DEB" "$L/apt"
  check "configure.sh ran" grep -qx configure "$L/calls"
  check "the Mongo password from configure.sh was hidden" bash -c '! grep -q TOPSECRETPW <<< "$1"' _ "$OUT"
  check "passwords file 0600" test "$(stat -c %a "$FEDHUB_ROOT/certs/.fedhub-cert-passwords")" = 600
  check "CA named C4Raven-FedHub-CA" grep -q 'makeRootCa --ca-name C4Raven-FedHub-CA' "$L/calls"
  check "server cert for the host" test -s "$f/fh.example.test.jks"
  check "unencrypted keys for both clients, 0600" bash -c 'for k in fedhub-admin raven-federate; do [ "$(stat -c %a "$1/$k-unencrypted.key")" = 600 ] && grep -q "BEGIN PRIVATE KEY" "$1/$k-unencrypted.key" || exit 1; done' _ "$f"
  local b=$FEDHUB_ROOT/configs/federation-hub-broker.yml u=$FEDHUB_ROOT/configs/federation-hub-ui.yml
  check "broker keystore" grep -qx "keystoreFile: \"$f/fh.example.test.jks\"" "$b"
  check "broker password replaced" bash -c '! grep -q "keystorePassword: atakatak" "$1"' _ "$b"
  check "broker comment kept" grep -q 'a comment that must survive' "$b"
  check "ui keyAlias = host" grep -qx 'keyAlias: "fh.example.test"' "$u"
  check "ui truststore" grep -qx "truststoreFile: \"$f/truststore-root.jks\"" "$u"
  check "UI port fix" grep -q -- '-DIGNITE_UPDATE_NOTIFIER=false -Dserver.port=9105 -Dserver.address=127.0.0.1"' "$FEDHUB_ROOT/scripts/federation-hub-ui.sh"
  check "federation-hub.service written" grep -q "WorkingDirectory=$FEDHUB_ROOT/scripts" "$SYSTEMD_DIR/federation-hub.service"
  check "admin authorised with the manager jar" grep -q "federation-hub-manager.jar $f/fedhub-admin.pem" "$L/calls"
  check "federation-hub enabled + started" test -e "$ST/active/federation-hub"
  check "copied certs dir 0700" test "$(stat -c %a "$fhd")" = 700
  check "copied keys 0600" test "$(stat -c %a "$fhd/raven-federate-unencrypted.key")" = 600
  check "config: API address" test "$(yaml_get "$c" RAVEN_FEDHUB_API_ADDRESS)" = "https://fh.example.test:9100/api"
  check "config: broker address" test "$(yaml_get "$c" RAVEN_FEDHUB_BROKER_ADDRESS)" = "fh.example.test:9102"
  check "config: client cert copy" test "$(yaml_get "$c" RAVEN_FEDHUB_CLIENT_CERT)" = "$fhd/fedhub-admin.pem"
  check "config: federate key copy" test "$(yaml_get "$c" RAVEN_FEDHUB_FEDERATE_KEY)" = "$fhd/raven-federate-unencrypted.key"
  check "config: CA bundle = hub CA" test "$(yaml_get "$c" RAVEN_FEDHUB_CA_BUNDLE)" = "$fhd/ca.pem"
  check "config: ENABLE is a boolean true" test "$(yaml_get "$c" RAVEN_FEDHUB_ENABLE)" = True
  check "config: other keys preserved" bash -c '[ "$(python3 -c "import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print(c[\"SECRET_KEY\"], c[\"RAVEN_MEDIAMTX_TOKEN\"], c[\"SQLALCHEMY_DATABASE_URI\"])" "$1")" = "s3cret keepme postgresql+psycopg://raven:pw@127.0.0.1/raven" ]' _ "$c"
  check "config.yml backup kept" compgen -G "$c.bak-*" >/dev/null
  check "secrets: RAVEN_FEDHUB_ENABLE=True" grep -qx 'RAVEN_FEDHUB_ENABLE=True' "$RAVEN_HOME/.raven-secrets.env"
  check "secrets: still 0600" test "$(stat -c %a "$RAVEN_HOME/.raven-secrets.env")" = 600
  check "fedhub_bridge.service from the venv, PartOf raven" bash -c 'grep -q "ExecStart=$1/c4raven-server/.venv/bin/fedhub_bridge" "$2" && grep -q "PartOf=raven.service" "$2" && grep -q "EnvironmentFile=-$1/.raven-secrets.env" "$2"' _ "$RAVEN_HOME" "$SYSTEMD_DIR/fedhub_bridge.service"
  check "raven + fedhub_bridge restarted" grep -q 'systemctl restart raven fedhub_bridge' "$L/systemctl"
  check "ufw allowed 9100-9102" grep -q 'ufw allow 9100:9102/tcp' "$L/ufw"
  check "answers recorded" bash -c 'grep -qx RAVEN_FEDHUB_MODE=deb "$1" && grep -qx RAVEN_FEDHUB_HOST=fh.example.test "$1" && grep -qx RAVEN_FEDHUB_VERSION=5.8-RELEASE75 "$1"' _ "$RAVEN_HOME/.install-answers"
  check "summary names the console, p12 and Fed group" bash -c 'grep -q "https://fh.example.test:9100" <<< "$1" && grep -q fedhub-admin.p12 <<< "$1" && grep -q "Fed group" <<< "$1"' _ "$OUT"
  check "summary: Raven creates the group and Server user (nothing by hand)" bash -c 'grep -q "nothing to create by hand" <<< "$1" && ! grep -q "Admin -> Groups" <<< "$1"' _ "$OUT"
  check "summary says connected" grep -q "Raven is connected to it" <<< "$OUT"
  # Federation policy: the hub's CA is a CA group in the active policy.
  local pol=$FEDHUB_ROOT/ui_generated_policy.json uid
  uid=$(load_libs; fh_set_context deb; fh_ca_group_uid)
  check "CA group uid = RFC2253 subject + sha256 of the DER" bash -c '[[ "$1" =~ ^CN=C4Raven-FedHub-CA,OU=C4Raven-FedHub,.*-[0-9a-f]{64}$ ]]' _ "$uid"
  check "active policy has the hub's CA as an enabled FederationGroup" python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(e["type"]=="FederationGroup" and e["name"]==sys.argv[2] and e["config"]["enabled"] for e in d["policy"]["entities"]); assert d["version"]=="v3" and d["name"]=="C4Raven"' "$pol" "$uid"
  check "stored copy policies/C4Raven.json written" cmp -s "$pol" "$FEDHUB_ROOT/policies/C4Raven.json"
  check "clientTimeoutTime: 3600 (plain number)" grep -qx 'clientTimeoutTime: 3600' "$b"
  check "password-holding configs and their backups 0600" bash -c 'for f in "$1"/configs/federation-hub-broker.yml* "$1"/configs/federation-hub-ui.yml*; do [ "$(stat -c %a "$f")" = 600 ] || { echo "$f"; exit 1; }; done' _ "$FEDHUB_ROOT"
  check "admin .p12 copied, 0600" bash -c '[ "$(stat -c %a "$1/fedhub-admin.p12")" = 600 ] && cmp -s "$1/fedhub-admin.p12" "$2/fedhub-admin.p12"' _ "$fhd" "$f"
  check "p12 password file: PASS alone on one line, 0600" bash -c '[ "$(stat -c %a "$1")" = 600 ] && [ "$(wc -l < "$1")" = 1 ] && [ "$(cat "$1")" = "$(sed -n "s/^PASS=//p" "$2")" ]' _ "$fhd/fedhub-admin.p12.password" "$FEDHUB_ROOT/certs/.fedhub-cert-passwords"
  check "config: RAVEN_FEDHUB_ADMIN_P12(_PASSWORD_FILE)" bash -c '[ "$1" = "$3/fedhub-admin.p12" ] && [ "$2" = "$3/fedhub-admin.p12.password" ]' _ "$(yaml_get "$c" RAVEN_FEDHUB_ADMIN_P12)" "$(yaml_get "$c" RAVEN_FEDHUB_ADMIN_P12_PASSWORD_FILE)" "$fhd"
  check "config: FEDERATE_ENABLE true" test "$(yaml_get "$c" RAVEN_FEDHUB_FEDERATE_ENABLE)" = True
  check "no password from the passwords file in the output" bash -c '! grep -qf <(sed -n "s/^C\{0,1\}A\{0,1\}PASS=//p" "$2") <<< "$1"' _ "$OUT" "$FEDHUB_ROOT/certs/.fedhub-cert-passwords"

  # ---- idempotent re-run ----
  local sum_before sum_after
  sum_before=$(cd "$T" && find opt raven systemd etc -type f ! -path '*/logs/*' -print0 | sort -z | xargs -0 md5sum)
  : > "$L/calls"; : > "$L/apt"
  run_fh --host fh.example.test
  expect_rc 0 "re-run without --artifact (resumes from the installed package)"
  check "re-run: nothing reported as fixed" bash -c '! grep -q "fixed:" <<< "$1"' _ "$OUT"
  sum_after=$(cd "$T" && find opt raven systemd etc -type f ! -path '*/logs/*' -print0 | sort -z | xargs -0 md5sum)
  if [ "$sum_before" = "$sum_after" ]; then ok_ "re-run: no file changed"; else fail_ "re-run changed files" "$(diff <(echo "$sum_before") <(echo "$sum_after"))"; fi
  check "re-run: no cert script, apt or jar call" test ! -s "$L/calls" -a ! -s "$L/apt"

  run_fh --check; expect_rc 0 "--check after install"
  check "--check one line" test "$(printf '%s\n' "$OUT" | wc -l)" = 1
  sed -i 's/^RAVEN_FEDHUB_ENABLE: .*/RAVEN_FEDHUB_ENABLE: false/' "$c"
  run_fh --check; expect_rc 4 "--check: ENABLE off -> 4"
  run_fh --yes; expect_rc 0 "--yes repairs the wiring"
  run_fh --check; expect_rc 0 "--check after repair"
  sed -i 's/^RAVEN_FEDHUB_FEDERATE_ENABLE: .*/RAVEN_FEDHUB_FEDERATE_ENABLE: false/' "$c"
  run_fh --check; expect_rc 4 "--check: FEDERATE_ENABLE off -> 4"
  check "  ... names it" grep -q RAVEN_FEDHUB_FEDERATE_ENABLE <<< "$OUT"
  sed -i 's/^RAVEN_FEDHUB_FEDERATE_ENABLE: .*/RAVEN_FEDHUB_FEDERATE_ENABLE: true/' "$c"
  # CA bundle consistency (UI uses the hub's own certificate here).
  sed -i '/^RAVEN_FEDHUB_CA_BUNDLE:/d' "$c"
  run_fh --check; expect_rc 4 "--check: CA_BUNDLE unset while the UI uses the hub's cert -> 4"
  echo "not a cert" > "$T/other-bundle.pem"; echo "RAVEN_FEDHUB_CA_BUNDLE: $T/other-bundle.pem" >> "$c"
  run_fh --check; expect_rc 4 "--check: CA_BUNDLE without the hub CA -> 4"
  run_fh --yes; expect_rc 0 "--yes repairs the CA bundle"
  check "  ... back to the hub CA copy" test "$(yaml_get "$c" RAVEN_FEDHUB_CA_BUNDLE)" = "$fhd/ca.pem"
  # The policy loses the hub's CA group: --check 4, a re-run puts it back and restarts the hub.
  python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["policy"]["entities"]=[]; json.dump(d,open(p,"w"))' "$pol"
  run_fh --check; expect_rc 4 "--check: hub CA missing from the policy -> 4"
  check "  ... says so" grep -q "not a CA group in the active federation policy" <<< "$OUT"
  : > "$L/systemctl"
  run_fh --yes; expect_rc 0 "re-run adds the CA group back"
  check "  ... and restarts federation-hub to load it" grep -q 'systemctl restart federation-hub' "$L/systemctl"
  check "  ... a backup of the policy kept" compgen -G "$pol.bak-*" >/dev/null
  run_fh --check; expect_rc 0 "--check after the policy repair"
  rm "$pol"
  run_fh --check; expect_rc 4 "--check: no active policy -> 4"
  # Config files a package upgrade made 0644 again are restricted on the next run.
  chmod 644 "$b" "$u"
  run_fh --yes; expect_rc 0 "re-run after the modes were reset"
  check "  ... broker/UI config back to 0600" bash -c '[ "$(stat -c %a "$1")" = 600 ] && [ "$(stat -c %a "$2")" = 600 ]' _ "$b" "$u"
  rm "$SYSTEMD_DIR/fedhub_bridge.service"
  run_fh --check; expect_rc 4 "--check: no bridge unit -> 4"
}

test_unencrypted_key_refresh() {
  deb_install; expect_rc 0 "install"
  local f=$FEDHUB_ROOT/certs/files k
  k=$f/fedhub-admin-unencrypted.key
  # A key that doesn't belong to the certificate (e.g. left from an earlier one).
  openssl genrsa -out "$k" 2048 2>/dev/null; chmod 600 "$k"
  touch -d '2 hours ago' "$k"
  run_fh --yes; expect_rc 0 "re-run with a mismatched unencrypted key"
  check "  ... key rewritten to match the certificate" test "$(openssl x509 -in "$f/fedhub-admin.pem" -noout -pubkey)" = "$(openssl pkey -in "$k" -pubout)"
  check "  ... and copied to Raven" cmp -s "$k" "$RAVEN_HOME/data/fedhub/fedhub-admin-unencrypted.key"
  # A .pem newer than its unencrypted key (reissued): rewritten too.
  touch -d '1 hour ago' "$f/raven-federate-unencrypted.key"
  run_fh --yes; expect_rc 0 "re-run with a .pem newer than its unencrypted key"
  check "  ... reported" grep -q "wrote the unencrypted key for raven-federate" <<< "$OUT"
  run_fh --yes
  check "  ... then left alone" bash -c '! grep -q "wrote the unencrypted key" <<< "$1"' _ "$OUT"
}

test_host_change() {
  deb_install; expect_rc 0 "install for fh.example.test"
  local u=$FEDHUB_ROOT/configs/federation-hub-ui.yml c=$RAVEN_HOME/data/config.yml
  run_fh --host new.example.test; expect_rc 0 "--host changes the host"
  check "UI keystore moved to the new host's (the old one is this hub's, not an admin's)" grep -qx "keystoreFile: \"$FEDHUB_ROOT/certs/files/new.example.test.jks\"" "$u"
  check "UI keyAlias = new host" grep -qx 'keyAlias: "new.example.test"' "$u"
  check "Raven's API address follows" test "$(yaml_get "$c" RAVEN_FEDHUB_API_ADDRESS)" = "https://new.example.test:9100/api"
  # Remembered host beats RAVEN_DOMAIN (install.sh passes it on every run).
  RAVEN_DOMAIN=other.example.test run_fh --yes; expect_rc 0 "re-run with a different RAVEN_DOMAIN"
  check "  ... keeps the remembered host" test "$(yaml_get "$c" RAVEN_FEDHUB_BROKER_ADDRESS)" = "new.example.test:9102"
}

test_resolve_host() {
  local out rc
  printf 'RAVEN_DOMAIN=answers.example\nRAVEN_FEDHUB_HOST=remembered.example\n' > "$RAVEN_HOME/.install-answers"
  out=$(load_libs; FH_HOST_ARG=arg.example RAVEN_DOMAIN=env.example; fh_resolve_host; echo "$HOST")
  check "--host first" test "$out" = arg.example
  out=$(load_libs; FH_HOST_ARG=""; RAVEN_DOMAIN=env.example; fh_resolve_host; echo "$HOST")
  check "then the remembered host (beats RAVEN_DOMAIN)" test "$out" = remembered.example
  printf 'RAVEN_DOMAIN=answers.example\n' > "$RAVEN_HOME/.install-answers"
  out=$(load_libs; FH_HOST_ARG=""; RAVEN_DOMAIN=env.example; fh_resolve_host; echo "$HOST")
  check "then RAVEN_DOMAIN" test "$out" = env.example
  out=$(load_libs; FH_HOST_ARG=""; unset RAVEN_DOMAIN; fh_resolve_host; echo "$HOST")
  check "then the recorded RAVEN_DOMAIN" test "$out" = answers.example
  # Asked, no default IPv4, end of input: dies instead of asking forever.
  printf 'RAVEN_DOMAIN=\n' > "$RAVEN_HOME/.install-answers"
  printf '#!/bin/bash\nexit 0\n' > "$T/shims/hostname"
  : > "$T/tty"
  out=$(load_libs; FEDHUB_TTY=$T/tty; FH_HOST_ARG=""; unset RAVEN_DOMAIN; fh_resolve_host 2>&1); rc=$?
  check "EOF at the host prompt with no default: exit 1, not a loop" test "$rc" = 1
  check "  ... says why" grep -q "end of input" <<< "$out"
}

test_firewall_failure() {
  local out
  touch "$ST/ufw-active"
  printf '#!/bin/bash\ncase "$1" in status) echo "Status: active" ;; allow) exit 1 ;; esac\n' > "$T/shims/ufw"
  out=$(load_libs; set -e; fh_firewall 2>&1; echo reached)
  check "a failing ufw allow only warns (set -e caller continues)" bash -c 'grep -q reached <<< "$1" && grep -q "warn:.*ufw allow" <<< "$1"' _ "$out"
  rm -f "$T/shims/ufw"
  printf '#!/bin/bash\ncase "$1" in --state) exit 0 ;; --reload) exit 1 ;; *) case "$*" in *query-port*) exit 1 ;; esac; exit 0 ;; esac\n' > "$T/shims/firewall-cmd"
  out=$(load_libs; set -e; fh_firewall 2>&1; echo reached)
  check "a failing firewalld reload only warns" bash -c 'grep -q reached <<< "$1" && grep -q "warn:.*firewalld" <<< "$1"' _ "$out"
}

test_check_not_installed() {
  run_fh --check; expect_rc 3 "--check on a server without Federation Hub"
  check "says not installed" grep -q "not installed" <<< "$OUT"
}

test_port_timeout() {
  touch "$ST/ports-down"
  export FEDHUB_WAIT_SECS=2
  deb_install; expect_rc 1 "ports never open -> failure"
  check "prints the journal" grep -q 'journalctl -u federation-hub -n 60' "$L/journalctl"
  rm "$ST/ports-down"
  run_fh; expect_rc 0 "re-run after the failure completes it"
}

test_letsencrypt_ui() {
  deb_install; expect_rc 0 "install"
  local u=$FEDHUB_ROOT/configs/federation-hub-ui.yml c=$RAVEN_HOME/data/config.yml
  echo jks > "$FEDHUB_ROOT/certs/files/fh.example.test-letsencrypt.jks"
  sed -i "s#^keystoreFile:.*#keystoreFile: $FEDHUB_ROOT/certs/files/fh.example.test-letsencrypt.jks#; s#^keyAlias:.*#keyAlias: admin-alias#" "$u"
  # The UI certificate is for another name than the broker's; the admin set
  # Raven's API address to it. CA_BUNDLE still points at the hub CA from the
  # first run.
  python3 -c 'import yaml,sys; p=sys.argv[1]; c=yaml.safe_load(open(p)); c["RAVEN_FEDHUB_API_ADDRESS"]="https://fed.example.net:9100/api"; yaml.safe_dump(c, open(p,"w"))' "$c"
  run_fh --check; expect_rc 4 "--check: public UI but CA_BUNDLE = the hub's private CA -> 4"
  run_fh; expect_rc 0 "re-run with an admin's Let's Encrypt UI keystore"
  check "admin's UI keystore kept" grep -q "letsencrypt.jks" "$u"
  check "admin's keyAlias kept" grep -qx 'keyAlias: admin-alias' "$u"
  check "CA_BUNDLE from the earlier run removed (system trust)" test -z "$(yaml_get "$c" RAVEN_FEDHUB_CA_BUNDLE)"
  check "hand-set API address (another name) kept" test "$(yaml_get "$c" RAVEN_FEDHUB_API_ADDRESS)" = "https://fed.example.net:9100/api"
  check "broker address still the hub's host" test "$(yaml_get "$c" RAVEN_FEDHUB_BROKER_ADDRESS)" = "fh.example.test:9102"
  run_fh --check; expect_rc 0 "--check: public UI with its own API host name is connected"
  # An admin's own bundle is not removed.
  echo "RAVEN_FEDHUB_CA_BUNDLE: /etc/ssl/certs/ca-certificates.crt" >> "$c"
  run_fh; expect_rc 0 "re-run with an admin-set CA bundle"
  check "  ... kept" test "$(yaml_get "$c" RAVEN_FEDHUB_CA_BUNDLE)" = /etc/ssl/certs/ca-certificates.crt
}

test_existing_certs_no_passwords() {
  deb_install; expect_rc 0 "install"
  rm "$FEDHUB_ROOT/certs/.fedhub-cert-passwords"
  run_fh; expect_rc 1 "existing CA without its passwords file: stops instead of minting mismatched keys"
}

test_docker_rhel_e2e() {
  set_os rocky 9 "rhel centos fedora"
  local z="$HOME/Downloads/takserver-fed-hub-docker-5.8-RELEASE-75.zip" v=5.8-RELEASE-75 dir
  make_zip "$z" "$v"
  printf 'y\n\n' > "$T/tty"   # use the found zip; default host
  FEDHUB_TTY=$T/tty run_fh
  expect_rc 0 "Docker install on Rocky, found in Downloads, default host"
  dir=$FEDHUB_DOCKER_BASE/$v
  check "docker-ce from Docker's RHEL repo" bash -c 'grep -q "config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo" "$1" && grep -q -- "--allowerasing docker-ce" "$1"' _ "$L/dnf"
  check "unpacked to /opt/fedhub-docker/<ver>" test -f "$dir/tak/version.txt"
  check "network + both images" bash -c 'grep -q "network create fedhub-$1" "$2" && grep -q "build -t fedhub-db:$1" "$2" && grep -q "build -t fedhub:$1" "$2"' _ "$v" "$L/docker"
  check "DB container: persistent dir, alias hub-db, 27017 NOT published, restart policy" bash -c 'l=$(grep "run .*--name fedhub-db-" "$1"); grep -q -- "--restart unless-stopped" <<< "$l" && grep -q -- "--network-alias hub-db" <<< "$l" && grep -q "$2:/var/lib/mongodb:z" <<< "$l" && ! grep -q 27017 <<< "$l"' _ "$L/docker" "$FEDHUB_DOCKER_DB_DIR"
  check "hub container publishes 9100-9102" bash -c 'l=$(grep "run .*--name fedhub-5" "$1"); grep -q -- "-p 9100:9100 -p 9101:9101 -p 9102:9102" <<< "$l" && grep -q -- "--restart unless-stopped" <<< "$l"' _ "$L/docker"
  local b=$dir/tak/federation-hub/configs/federation-hub-broker.yml
  check "db password set before the DB's first start" bash -c 'grep -qE "^dbPassword: \"[0-9a-f]{32}\"$" "$1"' _ "$b"
  check "dbHost hub-db" grep -qx 'dbHost: "hub-db"' "$b"
  check "docker: broker config 0600" test "$(stat -c %a "$b")" = 600
  check "docker: CA group in the active policy" grep -q '"FederationGroup"' "$dir/tak/federation-hub/ui_generated_policy.json"
  check "docker: admin .p12 + password file for Raven" test -s "$RAVEN_HOME/data/fedhub/fedhub-admin.p12" -a -s "$RAVEN_HOME/data/fedhub/fedhub-admin.p12.password"
  check "container paths in the broker config" grep -qx 'keystoreFile: "/opt/tak/federation-hub/certs/files/192.0.2.10.jks"' "$b"
  check "server cert for the default IP (host-side files)" test -s "$dir/tak/federation-hub/certs/files/192.0.2.10.jks"
  check "admin authorised inside the container" grep -q "exec fedhub-$v java -jar /opt/tak/federation-hub/jars/federation-hub-manager.jar" "$L/docker"
  check "container restarted after certs" test -s "$L/docker-restarts"
  check "Raven pointed at the IP" test "$(yaml_get "$RAVEN_HOME/data/config.yml" RAVEN_FEDHUB_BROKER_ADDRESS)" = "192.0.2.10:9102"
  check "copied from the host-side cert dir" cmp -s "$dir/tak/federation-hub/certs/files/ca.pem" "$RAVEN_HOME/data/fedhub/ca.pem"
  local pw; pw=$(grep '^dbPassword' "$b")
  : > "$L/docker"; : > "$L/docker-restarts"
  run_fh; expect_rc 0 "Docker re-run"
  check "re-run: nothing fixed" bash -c '! grep -q "fixed:" <<< "$1"' _ "$OUT"
  check "re-run: no build/run/restart" bash -c '! grep -qE "docker (build|run|network create)" "$1" && [ ! -s "$2" ]' _ "$L/docker" "$L/docker-restarts"
  check "re-run: db password unchanged" test "$(grep '^dbPassword' "$b")" = "$pw"
  run_fh --check; expect_rc 0 "--check docker"
}

test_legacy_check_only() {
  # The live box: .deb installed by hand, app user = the tak user, config.yml
  # only overrides the API address; the rest are code defaults that point
  # straight at /opt/tak/... (here FEDHUB_ROOT).
  make_fh_tree "$FEDHUB_ROOT"
  mkdir -p "$FEDHUB_ROOT/certs/files"
  for x in fedhub-admin.pem fedhub-admin-unencrypted.key raven-federate.pem raven-federate-unencrypted.key; do echo x > "$FEDHUB_ROOT/certs/files/$x"; done
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/ca.key" -days 30 -out "$FEDHUB_ROOT/certs/files/ca.pem" -subj "/C=US/O=ZZ/CN=C4Raven-FedHub-CA" 2>/dev/null
  # As live: the UI serves a Let's Encrypt keystore, and the CA group was added by hand.
  echo jks > "$FEDHUB_ROOT/certs/files/tak.example.net-letsencrypt.jks"
  sed -i "s#^keystoreFile:.*#keystoreFile: $FEDHUB_ROOT/certs/files/tak.example.net-letsencrypt.jks#" "$FEDHUB_ROOT/configs/federation-hub-ui.yml"
  local uid; uid=$(load_libs; fh_set_context deb; fh_ca_group_uid)
  python3 -I -c 'import json,sys; json.dump({"name":"Tak","version":"v3","policy":{"entities":[{"id":"1","type":"FederationGroup","name":sys.argv[2],"config":{"enabled":True}}],"rules":[],"groupSets":[]}}, open(sys.argv[1],"w"))' "$FEDHUB_ROOT/ui_generated_policy.json" "$uid"
  printf 'users:\n- username: "fedhub-admin"\n' > "$FEDHUB_ROOT/authorized_users.yml"
  echo 5.8-RELEASE75 > "$ST/pkg-version"
  touch "$SYSTEMD_DIR/federation-hub.service" "$SYSTEMD_DIR/fedhub_bridge.service"
  local ots=$T/ots
  mkdir -p "$ots"; printf 'RAVEN_FEDHUB_API_ADDRESS: https://fed.example.net:9100/api\nSECRET_KEY: x\n' > "$ots/config.yml"
  rm -f "$RAVEN_HOME/.install-answers"
  local before; before=$(md5sum "$ots/config.yml" "$FEDHUB_ROOT"/configs/* "$FEDHUB_ROOT/ui_generated_policy.json")
  RAVEN_DATA_DIR=$ots RAVEN_VENV=$RAVEN_HOME/c4raven-server/.venv RAVEN_SECRETS_FILE="" run_fh --check
  expect_rc 0 "legacy layout: --check reports installed and connected"
  check "legacy: nothing changed" test "$before" = "$(md5sum "$ots/config.yml" "$FEDHUB_ROOT"/configs/* "$FEDHUB_ROOT/ui_generated_policy.json")"
  check "legacy: --check created no lock file" test ! -e "$T/c4raven-updater.lock"
  chmod 000 "$FEDHUB_ROOT/certs/files/raven-federate-unencrypted.key"
  if [ "$(id -u)" != 0 ]; then
    RAVEN_DATA_DIR=$ots RAVEN_VENV=$RAVEN_HOME/c4raven-server/.venv RAVEN_SECRETS_FILE="" run_fh --check
    expect_rc 4 "legacy: unreadable key -> 4"
  fi
  # fedhub_section never repairs the legacy layout.
  local stub=$T/stub-fedhub.sh out
  printf '#!/bin/bash\necho "stub $*" >> "%s/stub-calls"\n[ "$1" = --check ] && exit 4\nexit 0\n' "$L" > "$stub"
  out=$(load_libs; FEDHUB_SCRIPT=$stub; fedhub_section legacy 2>&1; echo "rc=$?")
  check "legacy section returns 0" grep -q 'rc=0' <<< "$out"
  check "legacy section only ran --check" test "$(cat "$L/stub-calls")" = "stub --check"
  check "legacy section prints guidance" grep -q "nothing was changed" <<< "$out"
}

test_section() {
  local stub=$T/stub-fedhub.sh out
  # not installed, terminal, install fails -> warning, still 0
  printf '#!/bin/bash\necho "stub $*" >> "%s/stub-calls"\n[ "$1" = --check ] && { echo "Federation Hub: not installed"; exit 3; }\nexit 1\n' "$L" > "$stub"
  touch "$T/tty"
  out=$(load_libs; FEDHUB_SCRIPT=$stub FEDHUB_TTY=$T/tty; set -e; fedhub_section raven 2>&1; echo "rc=$?")
  check "a failing install does not fail the section (set -e caller)" grep -q 'rc=0' <<< "$out"
  check "  ... ran the installer interactively" grep -qx 'stub ' "$L/stub-calls"
  check "  ... warns with the retry command" grep -q "Retry with: $stub --artifact" <<< "$out"
  : > "$L/stub-calls"
  out=$(load_libs; FEDHUB_SCRIPT=$stub FEDHUB_TTY=$T/no-tty; fedhub_section raven 2>&1; echo "rc=$?")
  check "no terminal: only warns with the command" bash -c 'grep -q "rc=0" <<< "$1" && [ "$(cat "$2")" = "stub --check" ] && grep -q -- "--artifact" <<< "$1"' _ "$out" "$L/stub-calls"
  : > "$L/stub-calls"
  printf 'RAVEN_FEDHUB_DECLINED=1\n' >> "$RAVEN_HOME/.install-answers"
  out=$(load_libs; FEDHUB_SCRIPT=$stub FEDHUB_TTY=$T/tty; fedhub_section raven 2>&1)
  check "declined: not offered again" test "$(cat "$L/stub-calls")" = "stub --check"
  # installed, not connected -> --yes
  : > "$L/stub-calls"
  printf '#!/bin/bash\necho "stub $*" >> "%s/stub-calls"\n[ "$1" = --check ] && exit 4\nexit 0\n' "$L" > "$stub"
  out=$(load_libs; FEDHUB_SCRIPT=$stub; fedhub_section raven 2>&1; echo "rc=$?")
  check "4 on the raven layout runs --yes" grep -qx 'stub --yes' "$L/stub-calls"
  : > "$L/stub-calls"
  out=$(load_libs; FEDHUB_SCRIPT=$stub; RAVEN_FEDHUB_SKIP=1; fedhub_section raven 2>&1)
  check "RAVEN_FEDHUB_SKIP=1: not even checked" test ! -s "$L/stub-calls"
  # The real script's --check exit 3 through the section, no terminal.
  out=$(load_libs; FEDHUB_TTY=$T/no-tty; HERE=$REPO; fedhub_section raven 2>&1; echo "rc=$?")
  check "real --check through the section: warns, returns 0" bash -c 'grep -q "rc=0" <<< "$1" && grep -q "not installed" <<< "$1"' _ "$out"
}

test_finish_install_wiring() {
  check "finish-install.sh calls fedhub_section before its summary" bash -c 'awk "/fedhub_section raven/{a=NR} /finish-install.sh done/{b=NR} END{exit !(a && b && a < b)}" "$1"' _ "$REPO/finish-install.sh"
  check "update.sh calls fedhub_section with the layout" grep -q 'fedhub_section "$LAYOUT"' "$REPO/update.sh"
  check "update.sh offline branch too" grep -q 'fedhub_section offline' "$REPO/update.sh"
}

t skip                test_skip
t discovery           test_discovery
t prompt              test_prompt
t mode                test_mode
t mongo_repo          test_mongo_repo
t deb_e2e             test_deb_e2e
t check_not_installed test_check_not_installed
t port_timeout        test_port_timeout
t letsencrypt_ui      test_letsencrypt_ui
t unencrypted_key     test_unencrypted_key_refresh
t host_change         test_host_change
t resolve_host        test_resolve_host
t firewall_failure    test_firewall_failure
t existing_certs      test_existing_certs_no_passwords
t docker_rhel_e2e     test_docker_rhel_e2e
t legacy              test_legacy_check_only
t section             test_section
t finish_install      test_finish_install_wiring

echo
pass=$(grep -c '^PASS' "$RESULTS"); fail=$(grep -c '^FAIL' "$RESULTS")
echo "$pass passed, $fail failed"
grep '^FAIL' "$RESULTS" | sed 's/^FAIL /  - /'
rm -f "$RESULTS"
[ "$fail" = 0 ]
