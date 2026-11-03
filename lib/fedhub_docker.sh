# Federation Hub from TAK.gov's Docker release zip (Debian/Ubuntu and
# RHEL/Rocky 9), following its docs/README_fedhub_docker.md: unpack it to
# /opt/fedhub-docker/<ver>, a network, two images, a MongoDB container and the
# hub container, certificates made inside the container.
# Sourced by install-fedhub.sh after lib/common.sh and lib/fedhub.sh.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2015  # FH_* state is shared with fedhub.sh; A && B || die is intended

FH_DOCKER_RHEL_REPO="${FH_DOCKER_RHEL_REPO:-https://download.docker.com/linux/rhel/docker-ce.repo}"

# Newest release already unpacked under FEDHUB_DOCKER_BASE, empty if none.
fh_docker_unpacked_version() {
  local d
  for d in "$FEDHUB_DOCKER_BASE"/*/tak/version.txt; do
    [ -f "$d" ] || continue
    d=${d%/tak/version.txt}; printf '%s\n' "${d##*/}"
  done | sort -V | tail -n 1
}

fh_docker_is_podman() { grep -qi podman <<< "$(docker --version 2>/dev/null || true)"; }

# Docker from the snap store: /snap/bin/docker, or the snap installed at all
# (its daemon would own /var/run/docker.sock even beside docker.io).
fh_docker_is_snap() {
  local p
  p=$(command -v docker 2>/dev/null || true)
  case "$p" in /snap/*) return 0 ;; esac
  command -v snap >/dev/null 2>&1 && snap list docker >/dev/null 2>&1
}

# Docker engine. On RHEL/Rocky 9 this is docker-ce from Docker's own repo
# rather than podman-docker: the release's README relies on a daemon
# (`--restart unless-stopped` surviving a reboot needs one; podman only
# restarts `always` containers, and only with podman-restart.service), and
# docker-ce behaves the same as Debian's docker.io for build, network
# aliases, exec and restart, so one code path covers both. --allowerasing
# lets it replace RHEL's runc/containerd-compatible podman bits if present.
fh_docker_engine() {
  log "Docker"
  if fh_docker_is_snap; then
    die "Docker here is the snap package (snap list docker). Snap's Docker is confined to folders under /home, so it can't mount $FEDHUB_DOCKER_BASE or $FEDHUB_DOCKER_DB_DIR as this install needs. Remove it (sudo snap remove docker -- this deletes the snap's own containers and images) and re-run; the installer then installs the distribution's docker.io."
  fi
  if command -v docker >/dev/null 2>&1; then
    if fh_docker_is_podman; then
      die "'docker' here is podman's emulation (podman-docker). This installer needs the Docker engine: remove podman-docker (sudo dnf remove podman-docker) and re-run, which installs docker-ce."
    fi
    ok "docker present ($(docker --version 2>/dev/null | head -n 1))"
  elif [ "$DISTRO_FAMILY" = rhel ]; then
    retry as_root dnf install -y -q dnf-plugins-core || die "could not install dnf-plugins-core"
    if ! as_root test -f "$YUM_REPOS_DIR/docker-ce.repo"; then
      retry as_root dnf config-manager --add-repo "$FH_DOCKER_RHEL_REPO" || die "could not add Docker's repository ($FH_DOCKER_RHEL_REPO)"
    fi
    retry as_root dnf install -y -q --allowerasing docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
      || die "installing docker-ce failed (output above)."
    fixed "installed docker-ce"
  else
    pkg_install docker.io || die "installing docker.io failed (output above)."
    # BuildKit's builder, where the distro has it; the legacy builder works too.
    pkg_install docker-buildx >/dev/null 2>&1 || true
    fixed "installed docker.io"
  fi
  if [ "$HAS_SYSTEMD" = 1 ]; then
    unit_active docker || { as_root systemctl enable --now docker && fixed "started docker"; } || die "docker would not start: sudo journalctl -u docker -n 50"
  fi
  as_root docker info >/dev/null 2>&1 || die "the Docker daemon is not answering (sudo docker info)."
}

# fh_docker_zip_version ZIP -- the release version in ZIP's tak/version.txt.
fh_docker_zip_version() {
  local zip=$1 ver
  command -v unzip >/dev/null 2>&1 || { pkg_install unzip >&2 || die "could not install unzip"; }
  ver=$(unzip -p "$zip" '*tak/version.txt' 2>/dev/null | head -n 1 | tr -d '[:space:]')
  [ -n "$ver" ] || die "$zip has no tak/version.txt; is it the Federation Hub Docker release?"
  [[ "$ver" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unexpected version '$ver' in $zip's tak/version.txt"
  printf '%s' "$ver"
}

# Versions other than $1 that have containers here (fedhub-<v>, fedhub-db-<v>,
# running or not), one per line.
fh_docker_container_versions() {
  local names
  names=$(as_root docker ps -a --format '{{.Names}}' 2>/dev/null || true)
  sed -nE 's/^fedhub(-db)?-([0-9][A-Za-z0-9._-]*)$/\2/p' <<< "$names" | sort -u | grep -vxF -- "$1" || true
}

# Versions other than $1 unpacked here and set up (a CA in certs/files).
fh_docker_setup_versions() {
  local d v
  for d in "$FEDHUB_DOCKER_BASE"/*/tak/version.txt; do
    [ -f "$d" ] || continue
    d=${d%/tak/version.txt}; v=${d##*/}
    [ "$v" = "$1" ] && continue
    as_root test -s "$d/tak/federation-hub/certs/files/ca.pem" && printf '%s\n' "$v"
  done | sort -V
}

# fh_docker_preflight VER -- before anything is created: another release's
# containers would share the database folder (two mongods on one data dir)
# and ports 9100-9102 with this one, so refuse and say how to upgrade.
fh_docker_preflight() {
  local ver=$1 others v rm=""
  others=$(fh_docker_container_versions "$ver")
  [ -z "$others" ] && return 0
  for v in $others; do rm="$rm fedhub-$v fedhub-db-$v"; done
  die "Federation Hub ${others//$'\n'/, } already has containers here, and this is release $ver. Running both would start a second MongoDB on the same database folder ($FEDHUB_DOCKER_DB_DIR) and clash on ports 9100-9102, so nothing was changed. To upgrade: remove the old containers with  sudo docker rm -f$rm  (the database in $FEDHUB_DOCKER_DB_DIR and the release folders under $FEDHUB_DOCKER_BASE are kept), then re-run this; it carries the old release's CA, certificates, passwords, authorised admins, policies and database credentials over to $ver. To keep the old release instead, run $FH_SELF without --artifact."
}

# fh_docker_carry_over -- a release being set up for the first time (no CA
# yet) next to an older one that was set up (its containers already removed,
# see fh_docker_preflight): copy the hub's state across, so existing
# federates, the admin's .p12 and the policies keep working. Sets
# FH_CARRY_FROM (that release's federation-hub directory).
FH_CARRY_FROM=""
fh_docker_carry_over() {
  local old src f
  FH_CARRY_FROM=""
  as_root test -s "$FH_FILES/ca.pem" && return 0
  old=$(fh_docker_setup_versions "$FH_VERSION" | tail -n 1)
  [ -n "$old" ] || return 0
  src="$FEDHUB_DOCKER_BASE/$old/tak/federation-hub"
  FH_CARRY_FROM=$src
  log "Carrying Federation Hub $old's certificates and state over to $FH_VERSION"
  as_root mkdir -p "$FH_CERTS"
  as_root cp -a "$src/certs/files" "$FH_CERTS/" || die "copying $src/certs/files to $FH_CERTS failed"
  for f in certs/.fedhub-cert-passwords authorized_users.yml .c4raven-admin-authorized ui_generated_policy.json policies backup-policies; do
    as_root test -e "$src/$f" || continue
    as_root cp -a "$src/$f" "$(dirname "$FH_HOME/$f")/" || die "copying $src/$f failed"
  done
  fixed "copied the CA, certificates, passwords, authorised admins and policies from $old"
  warn "other changes you made to $src/configs/*.yml were not copied to $FH_HOME/configs; compare them if you customised the hub"
}

# fh_docker_db_creds sync|save -- the database user (dbUsername/dbPassword in
# the broker config) that the DB container's entrypoint creates on its first
# start. A copy is kept, root-only, in FEDHUB_DOCKER_DB_CREDS beside the
# releases, because the database folder outlives any one release.
#   save: copy the config's credentials there (silent).
#   sync: before the DB container exists. A real password in the config is
#         kept; else the saved copy, else the carried-over release's; else a
#         new random one -- but only when the database folder is empty: one
#         that holds data already has its user, whose password can't change.
# Prints kept | restored:<from> | random | sample; exits 3 when the folder
# holds data and no password is known. Passwords never leave the root process.
fh_docker_db_creds() {
  local mode=$1 nonempty=0
  if as_root test -d "$FEDHUB_DOCKER_DB_DIR" \
     && [ -n "$(as_root find "$FEDHUB_DOCKER_DB_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    nonempty=1
  fi
  as_root python3 -I - "$mode" "$FH_BROKER_YML" "${FEDHUB_DOCKER_DB_CREDS:-$FEDHUB_DOCKER_BASE/.fedhub-db-credentials}" \
      "$nonempty" "${FH_CARRY_FROM:+$FH_CARRY_FROM/configs/federation-hub-broker.yml}" <<'PY'
import os, re, secrets, shutil, sys, tempfile, time
mode, yml, credf, nonempty = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
extra = [p for p in sys.argv[5:] if p]
SAMPLE = {"", "pass4marti", "changeme", "null", "~"}
KEY = re.compile(r"^(dbUsername|dbPassword):(.*)$")

def read(path):
    d = {}
    try:
        lines = open(path).read().splitlines()
    except OSError:
        return d
    for line in lines:
        m = KEY.match(line)
        if m and m.group(1) not in d:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            d[m.group(1)] = v
    return d

def save(user, pw):
    want = f'dbUsername: "{user}"\ndbPassword: "{pw}"\n'
    try:
        if open(credf).read() == want:
            return
    except OSError:
        pass
    os.makedirs(os.path.dirname(credf), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(credf))
    with os.fdopen(fd, "w") as f:   # mkstemp: mode 0600
        f.write(want)
    os.replace(tmp, credf)

cur = read(yml)
user, pw = cur.get("dbUsername", ""), cur.get("dbPassword", "")
if mode == "save":
    if user and pw not in SAMPLE:
        save(user, pw)
    sys.exit(0)

action = "kept"
if pw in SAMPLE:
    for src in [credf] + extra:
        c = read(src)
        if c.get("dbPassword", "") not in SAMPLE:
            user, pw = c.get("dbUsername") or user or "martiuser", c["dbPassword"]
            action = "restored:" + src
            break
    else:
        if not nonempty:
            user, pw, action = user or "martiuser", secrets.token_hex(16), "random"
        elif pw:
            action = "sample"
        else:
            sys.exit(3)
user = user or "martiuser"

with open(yml) as f:
    lines = f.read().splitlines(True)
new = list(lines)
for key, value in (("dbUsername", user), ("dbPassword", pw)):
    for i, line in enumerate(new):
        m = KEY.match(line.rstrip("\r\n"))
        if m and m.group(1) == key:
            if m.group(2).strip().strip("\"'") != value:
                new[i] = f'{key}: "{value}"\n'
            break
    else:
        if new and not new[-1].endswith("\n"):
            new[-1] += "\n"
        new.append(f'{key}: "{value}"\n')
if new != lines:
    shutil.copy2(yml, f"{yml}.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    with open(yml, "w") as f:   # in place: owner and mode stay
        f.writelines(new)
save(user, pw)
print(action)
PY
}

# fh_docker_unpack ZIP -- to FEDHUB_DOCKER_BASE/<ver>/ unless it is there.
# Sets FH_VERSION.
fh_docker_unpack() {
  local zip=$1 ver tmpd top
  log "Unpacking the Docker release"
  ver=$(fh_docker_zip_version "$zip") || exit 1
  FH_VERSION=$ver
  if as_root test -f "$FEDHUB_DOCKER_BASE/$ver/tak/version.txt" && as_root test -f "$FEDHUB_DOCKER_BASE/$ver/docker/Dockerfile.fedhub"; then
    ok "release $ver already unpacked in $FEDHUB_DOCKER_BASE/$ver"
    return 0
  fi
  as_root mkdir -p "$FEDHUB_DOCKER_BASE"
  tmpd="$FEDHUB_DOCKER_BASE/.unpack-$$"
  as_root rm -rf "$tmpd"
  as_root mkdir -p "$tmpd"
  as_root unzip -q "$zip" -d "$tmpd" || { as_root rm -rf "$tmpd"; die "unzip $zip failed"; }
  # The folder holding tak/version.txt: fedhub-docker-<ver>/ normally, the
  # zip's root if it has no top folder.
  top=$(as_root find "$tmpd" -maxdepth 3 -path '*/tak/version.txt' -print | head -n 1)
  top=${top%/tak/version.txt}
  if [ -z "$top" ] || ! as_root test -f "$top/docker/Dockerfile.fedhub" || ! as_root test -f "$top/docker/Dockerfile.fedhub-db"; then
    as_root rm -rf "$tmpd"
    die "$zip does not have the expected layout (tak/version.txt, docker/Dockerfile.fedhub, docker/Dockerfile.fedhub-db)."
  fi
  as_root rm -rf "$FEDHUB_DOCKER_BASE/$ver"
  as_root mv "$top" "$FEDHUB_DOCKER_BASE/$ver"
  as_root rm -rf "$tmpd"
  fixed "unpacked Federation Hub $ver to $FEDHUB_DOCKER_BASE/$ver"
}

fh_docker_exists()  { as_root docker "$1" inspect "$2" >/dev/null 2>&1; }
fh_docker_running() { [ "$(as_root docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# Before the database container's first start: its entrypoint creates the
# MongoDB user from dbUsername/dbPassword in the broker config, once. So the
# password is only chosen while that container doesn't exist, and is never
# a new one for a database folder that already holds data.
fh_docker_configs() {
  local out rc creds=${FEDHUB_DOCKER_DB_CREDS:-$FEDHUB_DOCKER_BASE/.fedhub-db-credentials}
  log "Federation Hub configuration"
  fh_cert_passwords
  if ! fh_docker_exists container "$FH_DB_CONTAINER"; then
    rc=0; out=$(fh_docker_db_creds sync) || rc=$?
    case "$rc/$out" in
      0/kept) ;;
      0/random) fixed "federation-hub-broker.yml: set dbUsername dbPassword (database credentials)" ;;
      0/restored:*) fixed "federation-hub-broker.yml: database credentials of the existing database restored from ${out#restored:}" ;;
      0/sample) warn "$FEDHUB_DOCKER_DB_DIR already holds a database and no saved password was found, so dbPassword in $FH_BROKER_YML was left as the release ships it. If the hub then can't log in to MongoDB, set dbUsername/dbPassword there to the ones that database was created with and re-run." ;;
      3/*) die "$FEDHUB_DOCKER_DB_DIR already holds a database, but $FH_BROKER_YML has no dbPassword and none was saved ($creds), so the hub could not log in to it. Set dbUsername/dbPassword in $FH_BROKER_YML to the ones that database was created with -- or move $FEDHUB_DOCKER_DB_DIR aside to start with an empty database -- then re-run." ;;
      *) die "could not set the database credentials in $FH_BROKER_YML" ;;
    esac
  else
    fh_docker_db_creds save >/dev/null || warn "could not save a copy of the database credentials to $creds"
  fi
  out=$(fh_yml_set "$FH_BROKER_YML" "dbHost=hub-db") || die "could not edit $FH_BROKER_YML"
  [ -n "$out" ] && { FH_CHANGED=1; fixed "federation-hub-broker.yml: dbHost hub-db"; }
  fh_configure_ymls
}

# The certificates without the hub running (it may exit straight away when
# the keystore its config names doesn't exist yet): a throwaway container of
# the same image with the same tak/ mount, kept alive by sleep, so fh_certs'
# `docker exec` works unchanged. Not named fedhub-*, so it is never taken for
# a release's container.
fh_docker_certs_offline() {
  local helper="c4raven-fedhub-certs-$FH_VERSION" rc=0
  as_root docker rm -f "$helper" >/dev/null 2>&1 || true
  as_root docker run -d --rm --name "$helper" --entrypoint sleep \
    -v "$FH_DIR/tak:/opt/tak:z" "fedhub:$FH_VERSION" infinity >/dev/null \
    || die "starting a temporary container to make the certificates failed (output above)."
  ( FH_CONTAINER=$helper; fh_certs ) || rc=$?
  as_root docker rm -f "$helper" >/dev/null 2>&1 || true
  [ "$rc" = 0 ] || exit "$rc"
  FH_CHANGED=1
}

fh_docker_ports_free() {
  local p listening
  listening=$(ss -tln 2>/dev/null | awk 'NR > 1 {print $4}' || true)
  for p in 9100 9101 9102; do
    if grep -qE "[:.]$p\$" <<< "$listening"; then
      die "port $p is already in use on this host (another Federation Hub? sudo ss -tlnp | grep $p). Stop it, then re-run."
    fi
  done
}

fh_docker_containers() {
  local ver=$FH_VERSION net="fedhub-$FH_VERSION"
  log "Containers"
  # Before anything is created: the hub publishes 9100-9102.
  fh_docker_exists container "$FH_CONTAINER" || fh_docker_ports_free

  if fh_docker_exists network "$net"; then ok "network $net exists"
  else as_root docker network create "$net" >/dev/null && fixed "created network $net"; fi

  if fh_docker_exists image "fedhub-db:$ver"; then ok "image fedhub-db:$ver exists"
  else
    retry as_root docker build -t "fedhub-db:$ver" -f "$FH_DIR/docker/Dockerfile.fedhub-db" "$FH_DIR" || die "building fedhub-db:$ver failed (output above)."
    fixed "built image fedhub-db:$ver"
  fi
  if fh_docker_exists image "fedhub:$ver"; then ok "image fedhub:$ver exists"
  else
    retry as_root docker build -t "fedhub:$ver" -f "$FH_DIR/docker/Dockerfile.fedhub" "$FH_DIR" || die "building fedhub:$ver failed (output above)."
    fixed "built image fedhub:$ver"
  fi

  # The database: data on the host (outside the release folder, so an
  # upgrade keeps it). 27017 is deliberately NOT published: a host mongod may
  # already have it, and the hub reaches it by the network alias hub-db.
  if fh_docker_exists container "$FH_DB_CONTAINER"; then
    if fh_docker_running "$FH_DB_CONTAINER"; then ok "container $FH_DB_CONTAINER running"
    else as_root docker start "$FH_DB_CONTAINER" >/dev/null && fixed "started $FH_DB_CONTAINER"; fi
  else
    as_root mkdir -p "$FEDHUB_DOCKER_DB_DIR"
    as_root docker run -d -it --restart unless-stopped \
      -v "$FEDHUB_DOCKER_DB_DIR:/var/lib/mongodb:z" \
      -v "$FH_HOME/configs:$FH_CONTAINER_HOME/configs:z" \
      --network "$net" --network-alias hub-db \
      --name "$FH_DB_CONTAINER" "fedhub-db:$ver" >/dev/null || die "starting $FH_DB_CONTAINER failed (output above)."
    fixed "started $FH_DB_CONTAINER (data in $FEDHUB_DOCKER_DB_DIR)"
  fi

  if fh_docker_exists container "$FH_CONTAINER"; then
    if fh_docker_running "$FH_CONTAINER"; then ok "container $FH_CONTAINER running"
    else as_root docker start "$FH_CONTAINER" >/dev/null && fixed "started $FH_CONTAINER"; fi
  else
    as_root docker run -d -it --restart unless-stopped \
      -v "$FH_DIR/tak:/opt/tak:z" \
      -p 9100:9100 -p 9101:9101 -p 9102:9102 \
      --network "$net" \
      --name "$FH_CONTAINER" "fedhub:$ver" >/dev/null || die "starting $FH_CONTAINER failed (output above)."
    fixed "started $FH_CONTAINER (ports 9100-9102)"
  fi
  # Not running, and the keystore its config names was never made: make the
  # certificates without it, then try again.
  if ! fh_docker_running "$FH_CONTAINER" && ! as_root test -s "$FH_FILES/$HOST.jks"; then
    warn "$FH_CONTAINER is not running; making the certificates in a temporary container, then starting it again"
    fh_docker_certs_offline
    as_root docker start "$FH_CONTAINER" >/dev/null || true
  fi
  fh_docker_running "$FH_CONTAINER" || { as_root docker logs --tail 60 "$FH_CONTAINER" || true; die "$FH_CONTAINER is not running (log above)."; }
}

fh_docker_authorize() {
  if fh_admin_authorized; then ok "fedhub-admin is an authorised admin"; return 0; fi
  as_root docker exec "$FH_CONTAINER" java -jar "$FH_CONTAINER_HOME/jars/federation-hub-manager.jar" "$FH_CONTAINER_HOME/certs/files/$FEDHUB_ADMIN_CN.pem" </dev/null \
    || die "authorising $FEDHUB_ADMIN_CN.pem inside $FH_CONTAINER failed (output above)."
  fh_mark_authorized
  FH_CHANGED=1; fixed "authorised fedhub-admin for the admin UI"
}

# docker-proxy listens on the published ports straight away, so probe from
# inside the container instead.
fh_docker_ports_up() {
  # shellcheck disable=SC2016  # expanded by the shell inside the container
  as_root docker exec "$FH_CONTAINER" bash -c 'for p in "$@"; do (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || exit 1; done' _ "$@" </dev/null >/dev/null 2>&1
}

fh_docker_start() {
  local ports i
  log "Starting Federation Hub"
  if [ "${FH_CHANGED:-0}" = 1 ]; then
    as_root docker restart "$FH_CONTAINER" >/dev/null && fixed "restarted $FH_CONTAINER to load the certificates and configuration"
  fi
  ports=$(fh_expected_ports)
  for ((i = 0; i < FEDHUB_WAIT_SECS; i += 2)); do
    # shellcheck disable=SC2086
    fh_docker_ports_up $ports && { ok "listening on ${ports// /, }"; return 0; }
    sleep 2
  done
  as_root docker logs --tail 60 "$FH_CONTAINER" || true
  die "Federation Hub did not open ports ${ports// /, } within ${FEDHUB_WAIT_SECS}s (log above)."
}

# fh_docker_install [ZIP]
fh_docker_install() {
  local zip=${1:-} ver
  fh_docker_engine
  if [ -n "$zip" ]; then
    ver=$(fh_docker_zip_version "$zip") || exit 1
    fh_docker_preflight "$ver"
    fh_docker_unpack "$zip"; ver=$FH_VERSION
  else
    ver=$(answers_get RAVEN_FEDHUB_VERSION)
    [ -n "$ver" ] || ver=$(fh_docker_unpacked_version)
    [ -n "$ver" ] && as_root test -f "$FEDHUB_DOCKER_BASE/$ver/docker/Dockerfile.fedhub" \
      || die "no unpacked Docker release under $FEDHUB_DOCKER_BASE and no zip given (--artifact)."
    fh_docker_preflight "$ver"
    ok "using the unpacked release $FEDHUB_DOCKER_BASE/$ver"
  fi
  fh_set_context docker "$ver"
  fh_docker_carry_over
  fh_docker_configs
  fh_docker_containers
  fh_certs
  fh_docker_authorize
  fh_docker_start
}

# Installed = both containers running (not merely created: a stopped or
# crash-looping hub is not an install --check should call complete), the
# certificates made and the admin authorised.
fh_docker_installed() {
  local ver
  ver=$(answers_get RAVEN_FEDHUB_VERSION)
  [ -n "$ver" ] || ver=$(fh_docker_unpacked_version)
  [ -n "$ver" ] || return 1
  fh_set_context docker "$ver"
  command -v docker >/dev/null 2>&1 || return 1
  fh_docker_running "$FH_CONTAINER" && fh_docker_running "$FH_DB_CONTAINER" || return 1
  as_root test -s "$FH_FILES/ca.pem" && as_root test -s "$FH_FILES/$FEDHUB_ADMIN_CN.pem" && fh_admin_authorized
}
