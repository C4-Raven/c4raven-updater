<p align="center">
  <img src="https://raw.githubusercontent.com/C4-Raven/c4raven-server-setup/master/docs/logo.png" alt="C4 Raven" width="480">
</p>

# C4 Raven updater

Deploys the latest [c4raven-server](https://github.com/C4-Raven/c4raven-server)
(backend) and [c4raven-ui](https://github.com/C4-Raven/c4raven-ui)
(frontend) to an existing install, in one command, without losing your
data.

Both are our own git forks, not upstream packages — "update" means
*pull our fork's latest commits and redeploy them*, not "pull in
whatever changed upstream." See
[Pulling in upstream changes](#pulling-in-upstream-changes) below for
that separate, deliberate task.

## What this does

`./update.sh` brings an existing install fully up to date and is safe to
re-run (a second run changes nothing):

1. **Backs up** the database (`pg_dump`), the data directory (config,
   certificates, uploads, icons), the deployed UI and `/etc/nginx` to a
   timestamped folder under `~/backups/`. If the database dump fails,
   it stops before changing anything.
2. **Backend**: fast-forwards `c4raven-server` to `origin/main` and installs
   its Python dependencies (`poetry install` on the `raven` layout,
   `pip install -e` on the legacy one).
3. **Frontend**: fast-forwards `c4raven-ui`, and if that commit isn't the
   one already deployed, builds it (`corepack yarn install --immutable &&
   corepack yarn build`) and deploys it.
4. **Database**: stops the Raven services, runs `flask db upgrade` to the
   newest migration, then checks that the database revision equals the
   code's head.
5. **config.yml** is left alone. Settings added in a release
   (`RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH` in 2.3.0) take the code's default
   while `config.yml` doesn't have them. Writing them in would also override
   an environment variable of the same name, which config.yml takes
   precedence over. New scheduled jobs (`expire_group_memberships`) are added
   by the server itself when it starts, and the updater checks that they're
   registered. A `mediamtx.yml` that still has the `MTX_TOKEN` placeholder
   gets the real token. The log files in `logs/` are made to belong to the
   service user, because the 2.3.0 error-log viewer reads them.
6. **nginx**: applies the current template fixes to the site files already
   on the server, in place, for both the `raven_*` and the legacy `ots_*`
   names:
   - `proxy_set_header X-Ssl-Cert "";` in every location that proxies to the
     backend in the blocks that don't verify a client certificate
     (`raven_http`, `raven_certificate_enrollment`,
     `raven_certificate_enrollment_domain`, including certbot's 443 block in
     `raven_http`; `ots_http`, `ots_certificate_enrollment*` on the legacy
     box). Without it a client could send its own `X-Ssl-Cert` header over
     plain HTTP and be taken for any certificate holder. This uses
     c4raven-server-setup's own `lib/nginx_clear_ssl_cert.py`, fetched from
     `SETUP_REPO_RAW`, so the installer and the updater patch the same way.
     If that file can't be fetched, the fix is skipped and the run warns.
   - the WHEP follow-up location matches stream paths with slashes.

   Each changed file is copied to `/etc/nginx/raven-backups/<time>/` first.
   Then `nginx -t` runs: if it passes nginx is reloaded, and if it fails
   every file is restored.
7. **Restart and check**: restarts the services, waits for
   `/api/health`, reports any unit that isn't active, the database revision
   and a summary of what changed.

Every network step (git, poetry/pip, yarn, curl, apt/dnf) is retried up to
5 times with growing pauses (5s, 10s, 20s, 40s; `RETRY_ATTEMPTS` changes the
count), and a failure says what was and wasn't changed. Two runs can't
overlap (a lock file).

It works on every install type and picks the right one by itself:

| | Legacy | `raven` (install.sh / online `.deb` / `.rpm`) | Offline `.deb` / `.rpm` |
|---|---|---|---|
| Owner | your login user | the `raven` system user | the `raven` system user |
| Backend | `~/src/c4raven-server`, venv `~/.opentakserver_venv` | `/opt/raven/c4raven-server` (Poetry venv in `.venv`) | `/opt/raven/venv` (no source checkout) |
| Data | `~/ots` | `/opt/raven/data` | `/opt/raven/data` |
| UI served from | `/var/www/html/opentakserver` | `/var/www/html/raven` | `/var/www/html/raven` |
| Services | `opentakserver`, `eud_handler`, `eud_handler_ssl`, `cot_parser` | `raven`, `eud_handler`, `eud_handler_ssl`, `cot_parser`, `mediamtx` (+ `federation-hub` if running) | same as `raven` |

Detection order: legacy when `~/.opentakserver_venv` exists, then `raven`
when `/opt/raven/c4raven-server` is a git checkout, then offline when
`/opt/raven/venv` is a symlink. On the `raven` layout every git, Poetry,
yarn and flask step runs as the `raven` user, so file ownership stays the
way the installer left it. A packaged install that sits on a detached
commit is moved onto `main` when that loses nothing.
**Offline installs** get only the config.yml and nginx fixes, because
their code is upgraded by installing a newer offline bundle.

On the `raven` layout, if the install never finished (no `raven.service`,
no secrets file, or no PostgreSQL database in `config.yml`), `update.sh`
runs `finish-install.sh` first and then carries on with the update.

### Behaviour change in 2.3.0

The connection device profile (`/Marti/api/device/profile/connection`,
`/api/connection`) now requires a verified client certificate or Basic
credentials (`RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH: true`). If you have
devices that fetch it over plain HTTP without credentials (plain TCP
streaming connections), add `RAVEN_CONNECTION_PROFILE_REQUIRE_AUTH: false` to
`config.yml` and restart. The updater does not write this setting for you.

## What this never does

- Never drops, recreates, or truncates the database. The only database
  changes come from the app's own Alembic migrations.
- Never deletes anything in your data directory. Never touches `logs/`
  apart from making the log files readable by the service user.
- Never edits `config.yml` (finish-install.sh only fills in a missing
  database URI) and never replaces an nginx site file wholesale. It only makes
  the targeted in-place fixes listed above.
- Never merges or rebases over local work in either source checkout. If
  either has commits or changes that aren't on `origin/main`, it stops and
  says so.

## Usage

```
git clone https://github.com/C4-Raven/c4raven-updater.git
cd c4raven-updater
./update.sh
```

Run it as your own sudo-capable user (not `raven`), or as root, e.g. inside
a container. It needs network access to GitHub and the npm/PyPI registries.

`update.sh` does not update itself. If you cloned c4raven-updater before,
pull it first, or you run the old scripts and miss newer steps (such as
Federation Hub):

```
cd ~/c4raven-updater && git pull --ff-only && ./update.sh
```

### Docker

Both scripts work in a container whose PID 1 is systemd, such as
c4raven-server-setup's `tests/images` Dockerfiles run with `--privileged
--cgroupns=host --tmpfs /run --tmpfs /run/lock -v
/sys/fs/cgroup:/sys/fs/cgroup:rw`. In a container **without** systemd as
PID 1 (a plain `docker run`), they say so and keep going: every step that
doesn't need a service manager still runs (pull, dependencies, UI,
migrations, config, nginx files), service restarts are skipped, and the
summary lists what you have to restart yourself. `finish-install.sh` can't
start services there, so it only gets as far as the configuration.
`RAVEN_NO_SYSTEMD=1` forces this mode.

### Configuration

Override with environment variables. Where a default differs by layout it's
shown as legacy / `raven`:

| Variable          | Default                        | What it is                                       |
|-------------------|---------------------------------|---------------------------------------------------|
| `LAYOUT`          | `auto`                          | `legacy`, `raven` or `offline` to skip detection  |
| `RAVEN_HOME`      | `/opt/raven`                    | Root of the `raven` layout                         |
| `RAVEN_USER`      | `raven`                         | Account that owns the `raven` layout               |
| `RAVEN_VENV`      | `~/.opentakserver_venv` / `/opt/raven/c4raven-server/.venv` | Python virtualenv the backend runs from |
| `RAVEN_DATA_DIR`  | `~/ots` / `/opt/raven/data`     | Data dir (`config.yml`, certs, uploads, ...)       |
| `RAVEN_SERVICES`  | see the table above             | Space-separated systemd units to restart           |
| `SERVER_SRC_DIR`  | `~/src/c4raven-server` / `/opt/raven/c4raven-server` | Backend source checkout |
| `UI_SRC_DIR`      | `~/src/c4raven-ui` / `/opt/raven/c4raven-ui` | Where the frontend source is cloned/built |
| `UI_DEPLOY_DIR`   | `/var/www/html/opentakserver` / `/var/www/html/raven` | Where the built frontend is served from |
| `SERVER_BRANCH`, `UI_BRANCH` | `main`               | Branch to fast-forward to                          |
| `BACKUP_ROOT`     | `~/backups`                     | Where timestamped backups are written              |
| `SERVER_REPO`, `UI_REPO` | the C4-Raven GitHub repos | Cloned only if the checkout doesn't exist yet      |
| `HEALTH_URL`      | `https://127.0.0.1/api/health` / `http://127.0.0.1:8081/api/health` | Polled after the restart |
| `HEALTH_TRIES`    | `60`                            | Health checks, 2 seconds apart                     |
| `RETRY_ATTEMPTS`  | `5`                             | Tries for each network operation                   |
| `SKIP_UI` / `SKIP_BACKEND` / `SKIP_NGINX` | `0`     | `1` leaves that part alone                         |
| `FORCE_UI_BUILD`  | `0`                             | `1` rebuilds the UI even if its commit is deployed |
| `SKIP_DB_BACKUP`  | `0`                             | `1` migrates without a `pg_dump` (only if you have your own backup) |
| `SETUP_REPO_RAW`  | c4raven-server-setup `master` on GitHub | Where the X-Ssl-Cert patcher and (for finish-install.sh) the templates come from; `file:///path` for a local checkout |

Example:

```
RAVEN_DATA_DIR=/opt/ots ./update.sh
```

## Federation Hub

TAK Federation Hub connects this Raven server to other TAK servers.
`./install-fedhub.sh` installs it and connects Raven to it. `install.sh`,
`update.sh` and `finish-install.sh` all run it for you when Federation Hub
is missing. You can also run it on its own at any time.

### 1. Download Federation Hub from TAK.gov

It is licensed, so nothing here can download it for you. Get one of these
from your TAK.gov account:

| File | Use it on |
|------|-----------|
| `takserver-fed-hub_<version>_all.deb` | Ubuntu / Debian (preferred there) |
| the Federation Hub Docker release, a `.zip` with `fed`, `hub` and `docker` in its name | Ubuntu / Debian, or Rocky / Alma / RHEL 9 |

Copy it to the Raven server, into `~/Downloads` of the user you will run
the installer as (a subfolder is fine). It is then found without you
typing the path.

Not supported: the `.deb` on Debian 13 (it needs OpenJDK 17, which Debian
13 does not ship; use the Docker `.zip`), Debian on ARM (MongoDB only
publishes amd64 packages for Debian), and Docker installed as a snap.

### 2. Run the installer

As your normal sudo-capable user, **not** root and **not** `raven`:

```
cd ~/c4raven-updater && git pull --ff-only    # always get the current scripts first
./install-fedhub.sh                            # finds the file in ~/Downloads
./install-fedhub.sh --artifact /path/to/takserver-fed-hub_5.8-RELEASE92_all.deb   # or name it yourself
```

### 3. Answer its questions

At most three, and only the first time:

| Question | What to answer |
|----------|----------------|
| `Found a Federation Hub release: ... Use it? [Y/n]` | Enter, if that is the file you want. |
| `Path to the Federation Hub .deb or Docker .zip (Enter to skip, 'never' to stop asking)` | Shown only when no file was found. Give the full path. Enter skips Federation Hub for now. `never` stops `update.sh` and `finish-install.sh` offering it again. |
| `Host name or IP clients and Raven will use for Federation Hub [192.168.x.x]` | See below. |

**The host question.** The hub's server certificate is issued for exactly
one name. Raven and every partner TAK server must connect using that exact
name, or the connection fails its certificate check. It is only asked when
Raven was installed without a domain name; otherwise the domain is used.

- **Partners only on your own network, or no domain name:** press Enter to
  accept the address shown, which is this server's LAN IP. Make sure that
  IP will not change: give the server a static IP or a DHCP reservation.
- **Partners connect over the internet:** type the public DNS name that
  points at this server, e.g. `tak.example.org`. A private address such as
  `192.168.x.x` is not reachable from outside.

The answer is remembered, so later runs (and `install.sh`, `update.sh`)
keep it. To change it later, run `./install-fedhub.sh --host NEW_NAME`.
That issues a new certificate, and every server that connects has to
switch to the new name.

### 4. What it does

Every step checks first and only does what is missing:

- MongoDB (Federation Hub's database), with a password-protected user
- Federation Hub itself, from the `.deb` (a systemd service) or the Docker
  release (two containers)
- its CA and certificates: the server certificate for your host, an admin
  certificate, and the certificate Raven connects with
- the hub's own CA added to the active federation policy (without this the
  hub refuses Raven's connection)
- firewall ports 9100-9102/tcp, if ufw or firewalld is on
- Raven's side: the `RAVEN_FEDHUB_*` settings in `config.yml`, a copy of
  the certificates in the data directory, and `fedhub_bridge.service`

### 5. When it finishes

It prints a summary like this:

```
  Mode:            deb (version 5.8-RELEASE92)
  Host:            192.168.0.37  (the server certificate is issued for this name)
  Admin console:   https://192.168.0.37:9100  (log in with the fedhub-admin.p12 client certificate)
  Admin cert:      .../fedhub-admin.p12  (copy it off securely: it holds a private key)
  Passwords:       .../.fedhub-cert-passwords
```

- **Admin console:** import `fedhub-admin.p12` into your browser's
  certificates (its password is the `PASS=` line in the passwords file:
  `sudo cat` the path shown), then open `https://HOST:9100`. Raven admins
  can also download the `.p12` and its password from Raven's Federation
  Hub page, after a 2FA check.
- Raven creates the federation group (`Fed group`) and the `Server` user
  on its own. You do not need to make them.
- To federate with another TAK server, exchange CA certificates with it
  and add its CA as a group in the hub's policy (admin console, or Raven's
  CA Groups tab).

If the summary says **"Raven is NOT fully connected"**, it lists what is
wrong. Fix that, or just run `./install-fedhub.sh` again: it is safe to
re-run.

### Checking it later

```
./install-fedhub.sh --check
```

This changes nothing. Exit code 0 means installed and connected to Raven,
3 not installed, and 4 installed but Raven not connected (the output says
why). `update.sh` and `finish-install.sh` run the same check at the end:
they offer to install a missing hub when run from a terminal, and
reconnect Raven when needed. On the `legacy` layout they only report.

### If it did not install

| What you see | Why, and what to do |
|--------------|---------------------|
| Nothing about Federation Hub at all | Your `~/c4raven-updater` is older than the Federation Hub support. Run `git pull --ff-only` in it, then `./install-fedhub.sh`. |
| `Federation Hub: skipped.` | No file was found and Enter was pressed at the path question. Put the file in `~/Downloads`, or pass `--artifact PATH`. |
| `no release found in ~/Downloads and no terminal to ask` | It ran without a terminal (e.g. `ssh host ./update.sh`). Run `./install-fedhub.sh --artifact PATH` yourself. |
| `you chose 'never' earlier` | Run `./install-fedhub.sh --artifact PATH`; that clears the answer. |
| `Run this as your own sudo-capable user` | You ran it as `raven`. Log in as your normal user. |
| An error, then exit 1 | Fix what it names and run the same command again. It picks up where it stopped. |

Unattended: `RAVEN_FEDHUB_ARTIFACT=/path/to/file` (or `--artifact`) plus
`--yes` never asks. `--host NAME` answers the host question.
`RAVEN_FEDHUB_SKIP=1` skips Federation Hub everywhere.

## Finishing a half-done install

`install.sh` stops at the first command that fails. Everything after that
point is left undone, typically leaving `Unit raven.service not found` and
a web UI nobody can log in to. `./finish-install.sh` (for the `raven`
layout) checks each piece in install order and repairs only what is
missing or broken:

| Piece | What it checks / does when missing |
|---|---|
| packages | stops and tells you to re-run `install.sh` if PostgreSQL, nginx, RabbitMQ, git... aren't installed |
| backend | clones `c4raven-server`, installs Poetry, runs `poetry install` |
| `config.yml` | `flask raven generate-config` (an existing one is never regenerated) |
| PostgreSQL | starts it; creates the `raven` role and database and grants; points `config.yml` at it; if the role exists with a different password, resets the role to the password in `config.yml` |
| schema | `flask db upgrade` to head, verified |
| CA | `flask raven create-ca` / `issue-server-certificate` if the files are missing |
| MediaMTX | binary, `mediamtx.yml`, the webhook token, `mediamtx.service` |
| nginx | the `stream {}` block, `proxy_params`, the `raven_http` / `raven_https` / `raven_certificate_enrollment` sites and the `rabbitmq` / `mediamtx` streams (from c4raven-server-setup's templates), enabling them, the hardening fixes above, `nginx -t` |
| web UI | builds and deploys it when `index.html` is missing (`REBUILD_UI=1` forces it) |
| RabbitMQ | plugins enabled first, then `rabbitmq.conf`; restarted only if that changed or it's down |
| secrets file | `/opt/raven/.raven-secrets.env`, kept in step with `config.yml`'s database URI |
| services | writes `raven` / `eud_handler` / `eud_handler_ssl` / `cot_parser` units that don't exist anywhere (packaged units are left alone), enables them and starts whatever isn't running |
| admin | runs `seed_admin.py` (it only touches a brand-new database) and tests an `administrator` login |

It never drops the database, never regenerates an existing CA or
`config.yml`, and never replaces an existing nginx site. Templates come
from `SETUP_REPO_RAW` (default: c4raven-server-setup's `master` on GitHub;
`file:///path/to/c4raven-server-setup` uses a local checkout).

## Login problems

`./diagnose-login.sh` (on the `raven` layout) checks why the web UI won't
log in, without changing anything: service states, code versions, whether
the database schema is at head, the login-related settings (no secrets),
every account's active / site-access / forced-password-change / two-factor
flags, a scripted browser-style login both straight to the backend and
through nginx, the nginx sites (including whether they clear `X-Ssl-Cert`)
and certificates, and recent errors. It tests `administrator` / `password`
by default; use `LOGIN_USER=... LOGIN_PASS=... ./diagnose-login.sh` for
another account.

## Rolling back

Every `update.sh` run writes a backup directory before changing anything.
Its path is printed at the end (`~/backups/update-<time>/`), and only you
can read it, because it holds `config.yml` and the CA's private keys:

| File | What it is |
|---|---|
| `server-commit.txt`, `ui-commit.txt` | the commits that were checked out before |
| `db-revision.txt` | the database's Alembic revision before |
| `database.sql.gz` | a full `pg_dump` |
| `raven-data.tar.gz` | the data directory, minus `logs/` |
| `nginx.tar.gz` | `/etc/nginx` |
| `ui/` | the previously deployed frontend |

To roll back completely (`raven` layout, run from inside the backup
directory):

```
sudo systemctl stop raven eud_handler eud_handler_ssl cot_parser
# code
sudo -u raven -H bash -lc "cd /opt/raven/c4raven-server && git checkout $(cat server-commit.txt) && poetry install"
# database: recreate it empty, then load the dump
sudo -u postgres psql -c 'DROP DATABASE raven' -c 'CREATE DATABASE raven OWNER raven'
gunzip -c database.sql.gz | sudo -u postgres psql -d raven
# UI
sudo rsync -a --delete ui/ /var/www/html/raven/
# config / certificates, only if you need them back
sudo tar -xzf raven-data.tar.gz -C /opt/raven && sudo chown -R raven:raven /opt/raven/data
# nginx, only if you need it back
sudo tar -xzf nginx.tar.gz -C /etc && sudo nginx -t && sudo systemctl reload nginx
sudo systemctl start raven eud_handler eud_handler_ssl cot_parser
```

Restore the database **and** the code together. The old code can't run
against the migrated schema, and the new code migrates an old database
forward again as soon as it starts. Legacy layout: use
`git -C ~/src/c4raven-server checkout <commit>` with
`~/.opentakserver_venv/bin/pip install -e ~/src/c4raven-server`, the `ots`
database, `~/ots`, `/var/www/html/opentakserver` and `opentakserver` in
place of `raven`. The nginx fixes have their own per-file copies in
`/etc/nginx/raven-backups/<time>/`.

## Testing

`tests/docker-scenarios.sh /path/to/c4raven-server-setup [ubuntu-24.04|rocky-9]`
makes a real `install.sh` install in a systemd container (using the setup
repo's harness), then runs four scenarios:

- an upgrade from an older-looking install, plus a second no-op run
- repairing a half-finished install, plus a second no-op run
- an install that died before the database step
- running without systemd

CI (`.github/workflows/test.yml`) runs shellcheck on every push and runs
the scenarios on both distros for `master`.

## Pulling in upstream changes

This is a separate, occasional maintenance task — not something
`update.sh` does automatically, and not something to run directly
against production. `c4raven-server` carries a full package rename
(`opentakserver` → `raven`) on top of upstream, so a merge touches
nearly every file upstream has changed and *will* produce real
conflicts most of the time. Do this in a dev checkout, not on the live
server:

```
cd ~/src/c4raven-server        # or a separate clone, off production
git remote add upstream https://github.com/brian7704/OpenTAKServer.git   # if not already present
git fetch upstream
git merge upstream/master
# resolve conflicts -- expect them in most files upstream touched,
# since our identifiers no longer match upstream's
```

Watch in particular for:
- Any file upstream added that references `opentakserver.*` internally
  — needs the same rename treatment as the rest of the codebase.
- New `OTS_*` config keys — need a `RAVEN_*` counterpart in
  `raven/defaultconfig.py` (which is what `flask raven generate-config`
  and the app's startup defaults are built from) and, if you override
  them, in your own `config.yml`.
- New references to the server's own operational certificate, the
  plugin entry-point group, or anything else that has to match real
  external state rather than just our naming — these need to keep
  pointing at the real, already-deployed paths (`certs/raven/`, the
  `raven.plugin` entry-point group) rather than being renamed to match
  whatever upstream calls them, since renaming them for real means
  coordinating actual files already on the live server, not just a
  text substitution.

Test it (`create_app()` should import and boot cleanly, ideally against
a copy of a real `config.yml`), then push to `origin/main`. Only then
does a normal `./update.sh` run pick it up.
