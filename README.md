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

1. Backs up your database, your data directory (config, certificates,
   uploads, icons), and the currently-deployed UI to a timestamped folder
   under `~/backups/`.
2. Fast-forwards `c4raven-server` to its `origin/main` and reinstalls
   it into the venv (no separate patch step, the customizations are just
   part of the fork's commit history).
3. Fast-forwards `c4raven-ui` to its `origin/main`, builds it, and
   deploys it.
4. Restarts the backend services (they all run from the same backend
   install) and waits for the health check.

It works on both server layouts and picks the right one by itself:

| | Legacy | `raven` (fresh install from GitHub) |
|---|---|---|
| Set up by | the original single-user install | [c4raven-server-setup](https://github.com/C4-Raven/c4raven-server-setup)'s `install.sh` or online `.deb` |
| Owner | your login user | the `raven` system user |
| Backend | `~/src/c4raven-server`, venv `~/.opentakserver_venv` | `/opt/raven/c4raven-server` (Poetry venv in `.venv`) |
| Data | `~/ots` | `/opt/raven/data` |
| UI served from | `/var/www/html/opentakserver` | `/var/www/html/raven` |
| Services | `opentakserver`, `eud_handler`, `eud_handler_ssl`, `cot_parser` | `raven`, `eud_handler`, `eud_handler_ssl`, `cot_parser`, `mediamtx` (+ `federation-hub` if running) |

Legacy is used when `~/.opentakserver_venv` exists, otherwise `raven`
when `/opt/raven/c4raven-server` is a git checkout. On the `raven` layout
every git, Poetry and yarn step runs as the `raven` user (via `sudo -u
raven`), so file ownership stays the way `install.sh` left it. A server
installed from the **offline** `.deb` has no source checkout to pull; the
script refuses it and points you at a newer offline bundle instead.

Database migrations run themselves, the same way they always have — the
app runs them on startup, no separate step needed.

## What this never does

- Never drops, recreates, or truncates the database. The only database
  changes come from the app's own Alembic migrations, which are
  additive by convention.
- Never deletes anything in your data directory — `config.yml`,
  certificates, uploaded data packages, `icons.sqlite`, and your
  MediaMTX config are all left alone. Never touches `logs/`.
- Never merges or rebases over local, uncommitted work in either source
  checkout. If either has commits or changes that aren't on its
  `origin/main`, the script stops and tells you rather than trying to
  reconcile them for you.

Everything that could go wrong is backed up first, before any change is
made.

## Usage

```
git clone https://github.com/C4-Raven/c4raven-updater.git
cd c4raven-updater
./update.sh
```

Run it as your own sudo-capable user (not root, not `raven`). It needs
`sudo` to restart the services (and, on the `raven` layout, to act as
the `raven` user), plus network access to GitHub and your npm registry.

### Configuration

If your paths differ from the defaults, override with environment
variables. Where a default differs by layout it's shown as
legacy / `raven`:

| Variable          | Default                        | What it is                                       |
|-------------------|---------------------------------|---------------------------------------------------|
| `LAYOUT`          | `auto`                          | `legacy` or `raven` to skip detection              |
| `RAVEN_HOME`      | `/opt/raven`                    | Root of the `raven` layout                         |
| `RAVEN_USER`      | `raven`                         | Account that owns the `raven` layout               |
| `RAVEN_VENV`      | `~/.opentakserver_venv` / `/opt/raven/c4raven-server/.venv` | Python virtualenv the backend runs from |
| `RAVEN_DATA_DIR`  | `~/ots` / `/opt/raven/data`     | Data dir (`config.yml`, certs, uploads, ...)       |
| `RAVEN_SERVICES`  | see the table above             | Space-separated systemd units to restart           |
| `SERVER_SRC_DIR`  | `~/src/c4raven-server` / `/opt/raven/c4raven-server` | Backend source checkout |
| `UI_SRC_DIR`      | `~/src/c4raven-ui` / `/opt/raven/c4raven-ui` | Where the frontend source is cloned/built |
| `UI_DEPLOY_DIR`   | `/var/www/html/opentakserver` / `/var/www/html/raven` | Where the built frontend is served from |
| `BACKUP_ROOT`     | `~/backups`                     | Where timestamped backups are written              |
| `SERVER_REPO`     | `https://github.com/C4-Raven/c4raven-server.git` | Cloned only if `SERVER_SRC_DIR` doesn't exist yet |
| `UI_REPO`         | `https://github.com/C4-Raven/c4raven-ui.git` | Cloned only if `UI_SRC_DIR` doesn't exist yet |
| `HEALTH_URL`      | `https://127.0.0.1/api/health` / `http://127.0.0.1:8081/api/health` | Polled after the restart until it returns 200 |
| `HEALTH_TRIES`    | `30`                             | Health checks, 2 seconds apart                     |
| `SKIP_UI`         | `0`                              | Set to `1` to update the backend only              |
| `SKIP_BACKEND`    | `0`                              | Set to `1` to update the frontend only             |

Example:

```
RAVEN_DATA_DIR=/opt/ots ./update.sh
```

## Finishing a half-done install

If `./update.sh` reports `Unit raven.service not found`, the server's
`install.sh` stopped partway (it exits at the first failed command) and
the backend was never set up to run, so nobody can log in.
`./finish-install.sh` redoes everything after the UI build (RabbitMQ with
its plugins enabled first, the secrets file, the raven / eud_handler /
cot_parser units), starts the services, waits for the backend and tests
an `administrator` login. Each step prints the real error if it fails. It
leaves the database contents, `config.yml`, certificates and nginx alone.

## Login problems

`./diagnose-login.sh` (on the `raven` layout) checks why the web UI won't
log in, without changing anything: service states, code versions, the
login-related settings (no secrets), every account's active / site-access
/ forced-password-change / two-factor flags, a scripted browser-style
login both straight to the backend and through nginx, the nginx sites and
certificates, and recent errors. It tests `administrator` / `password` by
default; use `LOGIN_USER=... LOGIN_PASS=... ./diagnose-login.sh` for
another account.

## Rolling back

Every run writes a timestamped backup directory before touching
anything, printed at the end of the run (also under `~/backups/update-*`).
Inside it:

- `server-commit.txt` — the backend git commit that was checked out
  before the update. Legacy: `git -C ~/src/c4raven-server checkout $(cat server-commit.txt)`
  then re-run `pip install -e ~/src/c4raven-server` in the venv. `raven`
  layout: `sudo -u raven -H bash -lc "cd /opt/raven/c4raven-server && git checkout $(cat server-commit.txt) && poetry install"`
- `database.sql.gz` — a full `pg_dump`, restore with
  `gunzip -c database.sql.gz | psql <connection-string>`
- `raven-data.tar.gz` — your data directory (minus logs), restore by
  extracting it back over your data dir (with `sudo` on the `raven`
  layout, then `sudo chown -R raven:raven /opt/raven/data`)
- `ui/` — the previously-deployed frontend, restore with
  `rsync -a --delete ui/ <UI served from>/`

The backup directory is readable by you only: it holds `config.yml` and
the certificate authority's private keys.

After restoring whichever pieces you need, restart the services listed
in the table above, e.g. on the `raven` layout:
`sudo systemctl restart raven eud_handler eud_handler_ssl cot_parser mediamtx`.

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
