#!/bin/bash
# End-to-end test of update.sh and finish-install.sh in a systemd container.
#
#   tests/docker-scenarios.sh /path/to/c4raven-server-setup [distro]
#
# distro: ubuntu-24.04 (default) or rocky-9. Uses c4raven-server-setup's own
# harness (tests/images, tests/methods/install-sh.sh, tests/verify.sh) to make
# a real install of the current origin code, then:
#
#   A  upgrade: make the install look older (pre-hardening nginx sites,
#      database one migration behind, server/UI checkouts one
#      commit behind) -> update.sh -> verify; update.sh again is a no-op
#   B  half-finished install: no Raven units, no secrets file, a missing nginx
#      site, an empty webroot, a wrong database password, the MediaMTX token
#      placeholder back -> finish-install.sh -> verify; again is a no-op
#   C  install that died before the database: database dropped, config.yml
#      back on the default URI -> finish-install.sh -> verify
#   D  no systemd: update.sh with RAVEN_NO_SYSTEMD=1 finishes and lists what
#      to restart; finish-install.sh in a plain (non-systemd) container exits
#      with a clear message instead of crashing
#
# Needs docker (privileged containers). Writes logs to tests/.artifacts/.
set -uo pipefail

SETUP=$(cd "${1:?usage: $0 /path/to/c4raven-server-setup [distro]}" && pwd)
DISTRO=${2:-ubuntu-24.04}
UPD=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
. "$SETUP/tests/lib/common.sh"
ENGINE=$(detect_engine)
ARCH=$(host_arch)
NAME="c4raven-updater-test-$DISTRO"
OUT="$UPD/tests/.artifacts/$DISTRO"
rm -rf "$OUT"; mkdir -p "$OUT"
FAILS=()

x()  { "$ENGINE" exec "$NAME" bash -c "$1"; }                 # as root
xs() { "$ENGINE" exec -i "$NAME" bash -s -- "$@"; }          # as root, script on stdin
xt() { "$ENGINE" exec -u tester -w /home/tester "$NAME" bash -c "$1"; }   # as the admin user
pass() { printf '%sPASS%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
fail() { printf '%sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"; FAILS+=("$1"); }
expect() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
verify() {
  if x "bash /opt/harness/repo/tests/verify.sh" > "$OUT/verify-$1.log" 2>&1; then
    pass "$1: verify.sh"
  else
    tail -40 "$OUT/verify-$1.log"; fail "$1: verify.sh (see $OUT/verify-$1.log)"
  fi
}
# shellcheck disable=SC2016  # expanded inside the container
MIG='$(/opt/raven/c4raven-server/.venv/bin/python -c "import os,raven;print(os.path.join(os.path.dirname(os.path.realpath(raven.__file__)),\"migrations\"))")'
FLASK="cd /opt/raven/c4raven-server && FLASK_APP=raven.app RAVEN_DATA_FOLDER=/opt/raven/data .venv/bin/flask"
db_at_head() {
  local cur heads
  cur=$(x "runuser -u raven -- bash -c '$FLASK db current -d $MIG' 2>/dev/null" | grep -oE '^[0-9a-f]{12}' | sort | tr '\n' ' ')
  heads=$(x "runuser -u raven -- bash -c '$FLASK db heads -d $MIG' 2>/dev/null" | grep -oE '^[0-9a-f]{12}' | sort | tr '\n' ' ')
  echo "    db current='$cur' heads='$heads'"
  [ -n "$cur" ] && [ "$cur" = "$heads" ]
}
site() { case "$DISTRO" in rocky-*) echo "/etc/nginx/conf.d/$1.conf" ;; *) echo "/etc/nginx/sites-available/$1" ;; esac; }

cleanup() { "$ENGINE" rm -f "$NAME" "$NAME-plain" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---- boot + install ---------------------------------------------------------
log "building $DISTRO image"
"$ENGINE" build -t "c4raven-test:$DISTRO-$ARCH" -f "$SETUP/tests/images/Dockerfile.$DISTRO" \
  "$SETUP/tests/images" > "$OUT/image-build.log" 2>&1 || { tail -30 "$OUT/image-build.log"; die "image build failed"; }
cleanup
mapfile -t flags < <(engine_run_flags "$ENGINE" "$ARCH")
"$ENGINE" run "${flags[@]}" --name "$NAME" "c4raven-test:$DISTRO-$ARCH" >/dev/null || die "container would not start"
for _ in $(seq 1 120); do
  st=$("$ENGINE" exec "$NAME" systemctl is-system-running 2>/dev/null | tr -d '\r')
  case "$st" in running|degraded) break ;; esac; sleep 1
done
log "systemd is $st"
x "mkdir -p /opt/harness/repo /opt/harness/updater"
tar -C "$SETUP" --exclude=./.git --exclude=./build --exclude=./tests/.artifacts -cf - . | "$ENGINE" cp - "$NAME:/opt/harness/repo"
tar -C "$UPD" --exclude=./.git --exclude=./tests/.artifacts -cf - . | "$ENGINE" cp - "$NAME:/opt/harness/updater"
x "chmod -R a+rX /opt/harness"

log "installing with install.sh (current origin code)"
"$ENGINE" exec --env "DISTRO=$DISTRO" --env "ARCH=$ARCH" --env REPO=/opt/harness/repo --env GIT_TERMINAL_PROMPT=0 \
  "$NAME" bash /opt/harness/repo/tests/methods/install-sh.sh > "$OUT/install.log" 2>&1
rc=$?
[ "$rc" = 0 ] || { tail -60 "$OUT/install.log"; die "install.sh failed ($rc); see $OUT/install.log"; }
verify install

# ---- A: upgrade an older-looking install --------------------------------------
log "A: making the install look like an older release"
xs "$(site raven_http)" "$(site raven_https)" "$(site raven_certificate_enrollment)" <<'EOF2'
http=$1 https=$2 enr=$3
sed -i -e '/Never trust a client-supplied cert header/d' -e '/proxy_set_header X-Ssl-Cert "";/d' "$http" "$enr"
python3 - "$http" "$https" <<'PY'
import sys
for p in sys.argv[1:]:
    s = open(p).read().replace("location ~ ^/.+/whep(/.*)?$ {", "location ~ ^/[^/]+/whep(/.*)?$ {")
    open(p, "w").write(s)
PY
EOF2
x "grep -c 'X-Ssl-Cert \"\"' $(site raven_http) || true" | sed 's/^/    X-Ssl-Cert lines left in raven_http: /'
x "sed -i '/^RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH:/d' /opt/raven/data/config.yml"
x "systemctl stop raven cot_parser eud_handler eud_handler_ssl"
if x "runuser -u raven -- bash -c '$FLASK db downgrade -d $MIG -- -1'" > "$OUT/A-downgrade.log" 2>&1; then
  echo "    database downgraded one revision"
else
  echo "    (downgrade -1 not possible; testing with the schema at head)"
fi
x "runuser -u raven -- git -C /opt/raven/c4raven-server reset -q --hard HEAD~1 && runuser -u raven -- git -C /opt/raven/c4raven-ui reset -q --hard HEAD~1"
# Leave the services stopped: started, the older code would migrate the
# database forward itself before update.sh gets to it. And a raven.log
# systemd created as root (which the app's CLI can't write to).
x "chown root: /opt/raven/data/logs/raven.log"

log "A: update.sh"
xt "bash /opt/harness/updater/update.sh" > "$OUT/A-update.log" 2>&1
rc=$?
tail -25 "$OUT/A-update.log"
expect "A: update.sh exits 0" [ "$rc" = 0 ]
expect "A: raven_http clears X-Ssl-Cert in every proxied location" \
  [ "$(x "grep -c 'X-Ssl-Cert \"\"' $(site raven_http)")" -ge 3 ]
expect "A: enrollment site clears X-Ssl-Cert" x "grep -q 'X-Ssl-Cert \"\"' $(site raven_certificate_enrollment)"
expect "A: WHEP location widened" x "grep -qF 'location ~ ^/.+/whep(/.*)?\$ {' $(site raven_https)"
expect "A: nginx -t passes" x "nginx -t"
expect "A: config.yml not given RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH (env var must keep working)" x "! grep -q '^RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH:' /opt/raven/data/config.yml"
expect "A: raven.log owned by raven" x "[ \"\$(stat -c %U /opt/raven/data/logs/raven.log)\" = raven ]"
expect "A: update.sh ran the migration itself" grep -q "database migrated .* (head)" "$OUT/A-update.log"
expect "A: database at head" db_at_head
expect "A: server checkout at origin/main" x "cd /opt/raven/c4raven-server && [ \"\$(runuser -u raven -- git rev-parse HEAD)\" = \"\$(runuser -u raven -- git rev-parse origin/main)\" ]"
expect "A: a pg_dump backup was written" xt "ls ~/backups/update-*/database.sql.gz"
verify A

log "A: update.sh again (must be a no-op)"
xt "bash /opt/harness/updater/update.sh" > "$OUT/A-update2.log" 2>&1
rc=$?
expect "A2: second update.sh exits 0" [ "$rc" = 0 ]
expect "A2: nginx left alone" grep -q "nginx sites already have the current fixes" "$OUT/A-update2.log"
expect "A2: schema already at head" grep -q "database schema already at head" "$OUT/A-update2.log"
expect "A2: nothing changed" grep -q "Changed: nothing" "$OUT/A-update2.log"
verify A2

# ---- B: half-finished install ---------------------------------------------------
log "B: breaking the install the way a failed install.sh leaves it"
x "systemctl disable --now raven cot_parser eud_handler eud_handler_ssl >/dev/null 2>&1; rm -f /etc/systemd/system/{raven,cot_parser,eud_handler,eud_handler_ssl}.service; systemctl daemon-reload"
x "rm -f /opt/raven/.raven-secrets.env"
case "$DISTRO" in
  rocky-*) x "rm -f /etc/nginx/conf.d/raven_https.conf" ;;
  *)       x "rm -f /etc/nginx/sites-available/raven_https /etc/nginx/sites-enabled/raven_https" ;;
esac
x "rm -rf /var/www/html/raven/* /opt/raven/data/.ui-deployed-commit"
x "runuser -u postgres -- psql -Xqc \"ALTER ROLE raven PASSWORD 'not-the-right-one'\""
xs <<'EOF2'
tok=$(sed -n 's/^RAVEN_MEDIAMTX_TOKEN: *//p' /opt/raven/data/config.yml | tr -d "'\"")
[ -n "$tok" ] && sed -i "s~$tok~MTX_TOKEN~g" /opt/raven/data/mediamtx/mediamtx.yml
grep -c MTX_TOKEN /opt/raven/data/mediamtx/mediamtx.yml | sed 's/^/    MTX_TOKEN placeholders now: /'
EOF2

log "B: finish-install.sh"
xt "SETUP_REPO_RAW=file:///opt/harness/repo bash /opt/harness/updater/finish-install.sh" > "$OUT/B-finish.log" 2>&1
rc=$?
tail -30 "$OUT/B-finish.log"
expect "B: finish-install.sh exits 0" [ "$rc" = 0 ]
expect "B: raven.service back and active" x "systemctl is-active --quiet raven"
expect "B: secrets file back" x "test -f /opt/raven/.raven-secrets.env"
expect "B: raven_https site restored" x "test -f $(site raven_https) && nginx -t"
expect "B: UI redeployed" x "test -f /var/www/html/raven/index.html"
expect "B: MediaMTX token filled in" x "! grep -q MTX_TOKEN /opt/raven/data/mediamtx/mediamtx.yml"
verify B

log "B: finish-install.sh again (must be a no-op)"
xt "SETUP_REPO_RAW=file:///opt/harness/repo bash /opt/harness/updater/finish-install.sh" > "$OUT/B-finish2.log" 2>&1
rc=$?
expect "B2: second finish-install.sh exits 0" [ "$rc" = 0 ]
expect "B2: nothing changed" grep -q "Changed: nothing" "$OUT/B-finish2.log"
grep -E 'fixed:' "$OUT/B-finish2.log" || true

# ---- C: install that died before the database step ---------------------------------
log "C: dropping the database and the URI"
x "systemctl stop raven cot_parser eud_handler eud_handler_ssl"
x "runuser -u postgres -- dropdb raven"
x "sed -i 's~^SQLALCHEMY_DATABASE_URI:.*~SQLALCHEMY_DATABASE_URI: sqlite:////opt/raven/data/raven.db~' /opt/raven/data/config.yml"
xt "SETUP_REPO_RAW=file:///opt/harness/repo bash /opt/harness/updater/finish-install.sh" > "$OUT/C-finish.log" 2>&1
rc=$?
tail -20 "$OUT/C-finish.log"
expect "C: finish-install.sh exits 0" [ "$rc" = 0 ]
expect "C: database recreated and at head" db_at_head
expect "C: administrator can log in" grep -q "administrator / password logs in" "$OUT/C-finish.log"
verify C

# ---- D: no systemd ------------------------------------------------------------------
log "D: update.sh with RAVEN_NO_SYSTEMD=1"
xt "RAVEN_NO_SYSTEMD=1 SKIP_UI=1 bash /opt/harness/updater/update.sh" > "$OUT/D-update.log" 2>&1
rc=$?
tail -12 "$OUT/D-update.log"
expect "D: update.sh exits 0 without systemd" [ "$rc" = 0 ]
expect "D: says PID 1 is not systemd" grep -q "PID 1 is not systemd" "$OUT/D-update.log"
expect "D: lists services to restart" grep -q "restart these yourself" "$OUT/D-update.log"

log "D: finish-install.sh in a plain container (no systemd, nothing installed)"
"$ENGINE" run --rm --name "$NAME-plain" -v "$UPD:/u:ro" "c4raven-test:$DISTRO-$ARCH" \
  bash /u/finish-install.sh > "$OUT/D-plain.log" 2>&1
rc=$?
cat "$OUT/D-plain.log"
expect "D: plain container: clean non-zero exit" [ "$rc" = 1 ]
expect "D: plain container: explains no systemd" grep -q "PID 1 is not systemd" "$OUT/D-plain.log"
expect "D: plain container: explains what is missing" grep -q "Missing system packages" "$OUT/D-plain.log"

"$ENGINE" exec "$NAME" journalctl -b --no-pager > "$OUT/journal.log" 2>&1 || true
"$ENGINE" exec "$NAME" cat /opt/raven/data/logs/raven.log > "$OUT/raven.log" 2>&1 || true

echo
if [ "${#FAILS[@]}" -eq 0 ]; then
  printf '%sAll scenarios passed on %s.%s\n' "$C_GRN" "$DISTRO" "$C_OFF"
else
  printf '%s%d failure(s) on %s:%s\n' "$C_RED" "${#FAILS[@]}" "$DISTRO" "$C_OFF"
  printf '  - %s\n' "${FAILS[@]}"
  exit 1
fi
