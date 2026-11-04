#!/usr/bin/env bash
# Read-only login diagnostics for a C4 Raven server installed by
# c4raven-server-setup (the `raven` layout under /opt/raven).
#
#   ./diagnose-login.sh                      # tests administrator / password
#   LOGIN_USER=bob LOGIN_PASS='...' ./diagnose-login.sh
#
# Changes nothing. Prints no passwords, keys or tokens from the config; the
# login tests report only status codes and the server's error messages.
# Skim the output before sharing it anyway (it includes recent log lines).
set -uo pipefail

RAVEN_HOME="${RAVEN_HOME:-/opt/raven}"
DATA="$RAVEN_HOME/data"
LOGIN_USER="${LOGIN_USER:-administrator}"
LOGIN_PASS="${LOGIN_PASS:-password}"

h() { printf '\n===== %s\n' "$1"; }
# Root in a container often has no sudo binary; stand in for the two forms
# used below (`sudo CMD` and `sudo -u USER [-H] CMD`).
if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then
  sudo() {
    if [ "$1" = -u ]; then
      local u=$2; shift 2; [ "$1" = -H ] && shift
      runuser -u "$u" -- "$@"
    else
      "$@"
    fi
  }
fi
as_raven() { sudo -u raven -H bash -lc "cd / && $1"; }

# Reading config.yml needs PyYAML, which is a dependency of the backend and
# so lives in the backend's venv -- not necessarily in the system python3.
# On Rocky/RHEL that matters: /usr/bin/python3 is 3.9 (too old for the server
# anyway) and the EL stack installs python3.12-pyyaml, not python3-pyyaml, so
# a bare `python3 -c "import yaml"` raises ModuleNotFoundError on exactly the
# boxes this script exists to diagnose. Prefer the venv interpreter (source
# install, then the offline package's), then whichever system python can
# actually import yaml.
RAVEN_PY=""
for _p in "$RAVEN_HOME/c4raven-server/.venv/bin/python" "$RAVEN_HOME/venv/bin/python"; do
  if sudo test -x "$_p"; then RAVEN_PY="$_p"; break; fi
done
if [ -z "$RAVEN_PY" ]; then
  for _p in python3.12 python3; do
    if command -v "$_p" >/dev/null 2>&1 && "$_p" -c 'import yaml' >/dev/null 2>&1; then
      RAVEN_PY="$_p"; break
    fi
  done
fi
RAVEN_PY="${RAVEN_PY:-python3}"

# PG_SERVICE is `postgresql` on both families as installed, but EL users who
# took rpm/c4raven-el9-repos.sh's PGDG advice have a versioned unit name
# (postgresql-16). Only a status line, but let them say so.
PG_SERVICE="${PG_SERVICE:-postgresql}"

h "System"
. /etc/os-release; echo "$PRETTY_NAME, $(uname -m)"
echo "python3: $(python3 --version 2>&1)"
# Through as_raven, the same way the config reads below run it: $RAVEN_PY may
# be inside /opt/raven, which the invoking user need not be able to execute.
echo "config reader: $RAVEN_PY ($(as_raven "$RAVEN_PY --version" 2>&1))"
# Rocky/RHEL enable SELinux and firewalld by default, and either can break a
# login that looks fine from the backend's own side: SELinux blocks nginx's
# proxy_pass to 127.0.0.1:8081 unless httpd_can_network_connect is on (every
# request 502s), and firewalld drops 443/8089 unless they've been opened.
if command -v getenforce >/dev/null 2>&1; then
  echo "selinux: $(getenforce 2>&1) | httpd_can_network_connect: $(getsebool httpd_can_network_connect 2>/dev/null | awk '{print $3}' || echo '?')"
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  echo "firewalld: $(firewall-cmd --state 2>&1) | open: $(sudo firewall-cmd --list-ports 2>/dev/null) $(sudo firewall-cmd --list-services 2>/dev/null)"
fi

h "Services"
for s in raven eud_handler eud_handler_ssl cot_parser mediamtx fedhub_bridge nginx "$PG_SERVICE" rabbitmq-server; do
  printf '%-18s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done

h "Code versions"
echo "server: $(as_raven "git -C $RAVEN_HOME/c4raven-server log -1 --format='%h %cd %s' --date=short" 2>&1)"
echo "ui:     $(as_raven "git -C $RAVEN_HOME/c4raven-ui log -1 --format='%h %cd %s' --date=short" 2>&1)"
echo "ui files deployed: $(find /var/www/html/raven -mindepth 1 -maxdepth 1 2>/dev/null | wc -l) (index.html: $(test -f /var/www/html/raven/index.html && echo yes || echo NO))"

h "Settings that affect login (no secrets)"
as_raven "$RAVEN_PY - '$DATA/config.yml'" <<'EOF'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
for k in ["RAVEN_TURNSTILE_ENABLE", "RAVEN_ENABLE_EMAIL", "RAVEN_ENABLE_LDAP",
          "SECURITY_TWO_FACTOR_REQUIRED", "SECURITY_TWO_FACTOR", "RAVEN_FEDHUB_ENABLE",
          "RAVEN_FEDHUB_FEDERATE_ENABLE", "SESSION_COOKIE_SECURE", "SESSION_COOKIE_SAMESITE",
          "SESSION_COOKIE_DOMAIN", "SERVER_NAME", "SECURITY_CSRF_IGNORE_UNAUTH_ENDPOINTS",
          "WTF_CSRF_CHECK_DEFAULT", "RAVEN_LISTENER_ADDRESS", "RAVEN_LISTENER_PORT"]:
    print(f"{k}: {c.get(k, '(not set)')!r}")
print("SECRET_KEY set:", bool(c.get("SECRET_KEY")), "| SECURITY_PASSWORD_SALT set:", bool(c.get("SECURITY_PASSWORD_SALT")))
print("database:", c.get("SQLALCHEMY_DATABASE_URI", "").split("@")[-1])
EOF
echo "connection profile requires client cert/Basic auth: $(as_raven "$RAVEN_PY -c \"import yaml; print(yaml.safe_load(open('$DATA/config.yml')).get('RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH', '(not set: default True)'))\"" 2>&1)"
echo "secrets env keys: $(sudo cut -d= -f1 "$RAVEN_HOME/.raven-secrets.env" 2>/dev/null | tr '\n' ' ')"

h "Database schema"
RAVEN_VENV_DIR=$(dirname "$(dirname "$RAVEN_PY")")
MIG=$(as_raven "$RAVEN_PY -c 'import os, raven; print(os.path.join(os.path.dirname(os.path.realpath(raven.__file__)), \"migrations\"))'" 2>/dev/null | tail -1)
if [ -n "$MIG" ] && sudo test -x "$RAVEN_VENV_DIR/bin/flask"; then
  cur=$(as_raven "cd $DATA && FLASK_APP=raven.app RAVEN_DATA_FOLDER=$DATA $RAVEN_VENV_DIR/bin/flask db current -d $MIG" 2>/dev/null | grep -oE '^[0-9a-f]{12}' | tr '\n' ' ')
  head=$(as_raven "cd $DATA && FLASK_APP=raven.app RAVEN_DATA_FOLDER=$DATA $RAVEN_VENV_DIR/bin/flask db heads -d $MIG" 2>/dev/null | grep -oE '^[0-9a-f]{12}' | tr '\n' ' ')
  echo "database at: ${cur:-?} | code head: ${head:-?} $([ -n "$cur" ] && [ "$cur" = "$head" ] && echo '(up to date)' || echo '(NOT at head: run ./update.sh)')"
else
  echo "(could not locate the backend's flask/migrations)"
fi

h "Accounts"
DBNAME=$(as_raven "$RAVEN_PY -c \"import yaml; print(yaml.safe_load(open('$DATA/config.yml'))['SQLALCHEMY_DATABASE_URI'].rsplit('/',1)[-1])\"" 2>/dev/null)
sudo -u postgres psql -d "${DBNAME:-raven}" -XAt -F ' | ' -c "
  select u.username, 'active='||u.active, 'site_access='||u.site_access,
         'force_password_change='||u.force_password_change,
         'has_email='||(u.email is not null), 'tf='||coalesce(u.tf_primary_method,'none'),
         'roles='||coalesce(string_agg(r.name, ','),'none'),
         'logins='||coalesce(u.login_count,0)
  from \"user\" u
  left join roles_users ru on ru.user_id = u.id
  left join role r on r.id = ru.role_id
  group by u.id order by u.id;" 2>&1

# Browser-like login: GET /api/login for the CSRF token, POST the
# credentials as JSON, then GET /api/me with the session cookie.
login_test() {
  python3 - "$1" "$2" "$LOGIN_USER" "$LOGIN_PASS" <<'EOF'
import http.cookiejar, json, ssl, sys, urllib.request, urllib.error
base, host, user, pw = sys.argv[1:5]
ctx = ssl._create_unverified_context()
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),
                                 urllib.request.HTTPSHandler(context=ctx))
H = {"Accept": "application/json", "Content-Type": "application/json"}
if host:
    H["Host"] = host
    H["Referer"] = f"https://{host}/login"
    H["Origin"] = f"https://{host}"
def call(method, path, body=None):
    req = urllib.request.Request(base + path, data=body, headers=H, method=method)
    try:
        r = op.open(req, timeout=15); return r.status, r.read().decode("utf-8", "replace"), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), e.headers
    except Exception as e:
        return None, f"{type(e).__name__}: {e}", {}
def errors(text):
    try:
        d = json.loads(text); r = d.get("response", d)
        return {k: r[k] for k in ("errors", "field_errors", "tf_required", "tf_method", "force_password_change") if k in r} or "(ok)"
    except Exception:
        return text[:300].replace("\n", " ")
s, t, _ = call("GET", "/api/login")
print("GET  /api/login  ->", s, errors(t) if s != 200 else "")
tok = ""
try: tok = json.loads(t)["response"].get("csrf_token", "")
except Exception: pass
body = json.dumps({"username": user, "password": pw, "submit": "Login", "csrf_token": tok, "turnstile_token": ""}).encode()
s, t, hd = call("POST", "/api/login?include_auth_token", body)
print("POST /api/login  ->", s, errors(t))
cookies = [c.name for c in jar]
print("cookies set:", cookies or "none", "| Set-Cookie flags:", "; ".join(v.split(";", 1)[1].strip() for k, v in hd.items() if k.lower() == "set-cookie")[:200] if hd else "")
s, t, _ = call("GET", "/api/me")
print("GET  /api/me     ->", s, errors(t) if s != 200 else "(logged in)")
EOF
}

h "Login test: straight to the backend (127.0.0.1:8081)"
login_test "http://127.0.0.1:8081" ""

# Where the enabled site lives depends on the distro: sites-enabled on
# Debian/Ubuntu, conf.d on Rocky/RHEL (which has no sites-enabled at all).
NGINX_DIRS=()
for d in /etc/nginx/sites-enabled /etc/nginx/conf.d; do
  [[ -d "$d" ]] && NGINX_DIRS+=("$d")
done

# -R, not -r: every entry in Debian's sites-enabled is a symlink into
# sites-available, and `grep -r` *skips* symlinks it meets while recursing
# (only ones named directly on the command line are followed). With -r this
# finds nothing at all on Debian/Ubuntu, which is where almost every install
# is. -R dereferences them. Same below.
DOMAIN=""
if [[ ${#NGINX_DIRS[@]} -gt 0 ]]; then
  DOMAIN=$(sudo grep -RhoE 'server_name\s+[^;]+' "${NGINX_DIRS[@]}" 2>/dev/null | awk '{for(i=2;i<=NF;i++) print $i}' | grep -vE '^(_|raven_[0-9]+|localhost)$' | grep '\.' | head -1)
fi
h "Login test: through nginx on 443 (as ${DOMAIN:-the server IP})"
login_test "https://127.0.0.1" "${DOMAIN:-}"

h "nginx"
if [[ ${#NGINX_DIRS[@]} -eq 0 ]]; then
  echo "(no /etc/nginx/sites-enabled or /etc/nginx/conf.d -- is nginx installed?)"
else
  ls -l "${NGINX_DIRS[@]}" 2>&1
  sudo grep -RnE 'server_name|listen|ssl_certificate |return 301|managed by Certbot' "${NGINX_DIRS[@]}" 2>&1
fi
sudo nginx -t 2>&1 | tail -2
# Non-mTLS blocks must blank X-Ssl-Cert (update.sh applies this).
for f in /etc/nginx/sites-available/raven_http /etc/nginx/sites-available/raven_certificate_enrollment /etc/nginx/conf.d/raven_http.conf /etc/nginx/conf.d/raven_certificate_enrollment.conf; do
  sudo test -f "$f" || continue
  if sudo grep -q 'X-Ssl-Cert ""' "$f"; then echo "$f: clears client X-Ssl-Cert (ok)"; else echo "$f: does NOT clear X-Ssl-Cert -- run ./update.sh"; fi
done

h "Certificates"
sudo certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' || echo "(certbot has no certificates)"
echo | timeout 5 openssl s_client -connect 127.0.0.1:443 ${DOMAIN:+-servername "$DOMAIN"} 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null

h "Recent backend errors (raven.log, last 400 lines)"
sudo tail -n 400 "$DATA/logs/raven.log" 2>/dev/null | grep -iE 'error|exception|traceback|csrf|login|refused|denied' | grep -v after_fork | tail -40

h "Recent nginx errors"
sudo tail -n 30 /var/log/nginx/error.log 2>/dev/null
