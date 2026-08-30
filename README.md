<p align="center">
  <img src="https://raw.githubusercontent.com/C4Raven/c4raven-server-setup/master/docs/logo.png" alt="C4 Raven" width="480">
</p>

# C4 Raven updater

Updates an existing C4 Raven install ([opentakserver](https://www.opentakserver.io/)
backend + [c4raven-ui](https://github.com/C4Raven/c4raven-ui) frontend)
in place, in one command, without losing your data.

## What this does

1. Backs up your database, your data directory (config, certificates,
   uploads, icons), and the currently-deployed UI to a timestamped folder
   under `~/backups/`.
2. Upgrades the `opentakserver` Python package via pip.
3. Re-applies C4 Raven's backend customizations on top of the upgraded
   package (see [`patches/`](patches/) below) — without this step, a
   plain `pip install --upgrade opentakserver` would silently drop the
   mandatory-2FA / forced-password-change / site-access-revocation
   security features.
4. Installs any new database migrations that ship with those
   customizations.
5. Pulls and builds the latest `c4raven-ui` frontend, and deploys it.
6. Restarts the `opentakserver` service (which runs the database
   migrations itself, as it always does on startup) and waits for the
   health check to come back up.

## What this never does

- Never drops, recreates, or truncates the database. The only database
  changes come from the app's own Alembic migrations, which are
  additive by convention.
- Never deletes anything in your data directory — `config.yml`,
  certificates, uploaded data packages, `icons.sqlite`, and your
  MediaMTX config are all left alone.
- Never touches `logs/`.

Everything that could go wrong is backed up first, before any change is
made.

## Usage

```
git clone https://github.com/C4Raven/c4raven-updater.git
cd c4raven-updater
./update.sh
```

Requires `sudo` access to restart the `opentakserver` systemd service,
and network access to PyPI, GitHub, and your npm registry.

### Configuration

The script assumes the same layout as a fresh install from
[c4raven-server-setup](https://github.com/C4Raven/c4raven-server-setup).
If your paths differ, override with environment variables:

| Variable         | Default                        | What it is                                  |
|------------------|---------------------------------|----------------------------------------------|
| `OTS_VENV`       | `~/.opentakserver_venv`         | Python virtualenv the backend runs from       |
| `OTS_DATA_DIR`   | `~/ots`                         | Data dir (`config.yml`, certs, uploads, ...)  |
| `OTS_SERVICE`    | `opentakserver.service`         | systemd unit name                             |
| `OTS_VERSION`    | *(latest)*                      | Pin to a specific opentakserver PyPI version  |
| `UI_SRC_DIR`     | `~/src/c4raven-ui`               | Where the frontend source is cloned/built     |
| `UI_DEPLOY_DIR`  | `/var/www/html/opentakserver`   | Where the built frontend is served from       |
| `BACKUP_ROOT`    | `~/backups`                     | Where timestamped backups are written         |
| `SKIP_UI`        | `0`                              | Set to `1` to update the backend only         |
| `SKIP_BACKEND`   | `0`                              | Set to `1` to update the frontend only        |

Example:

```
OTS_DATA_DIR=/opt/ots OTS_SERVICE=ots.service ./update.sh
```

## Rolling back

Every run writes a timestamped backup directory before touching
anything, printed at the end of the run (also under `~/backups/update-*`).
Inside it:

- `opentakserver-version.txt` — the version that was installed before
  the update, e.g. `pip install "opentakserver==$(cat opentakserver-version.txt)"`
- `database.sql.gz` — a full `pg_dump`, restore with
  `gunzip -c database.sql.gz | psql <connection-string>`
- `ots-data.tar.gz` — your data directory (minus logs), restore by
  extracting it back over your data dir
- `ui/` — the previously-deployed frontend, restore with
  `rsync -a --delete ui/ /var/www/html/opentakserver/`

After restoring whichever pieces you need, restart the service:
`sudo systemctl restart opentakserver.service`.

## `patches/`

[`opentakserver-customizations.patch`](patches/opentakserver-customizations.patch)
is a unified diff, generated against the matching pristine PyPI release,
capturing every C4 Raven-specific backend change:

- **Forced password change** — new/admin-reset accounts must set a real
  password before anything else works.
- **Mandatory 2FA on first login.**
- **Site access revocation** — admins can cut off an account's web UI
  login without touching its EUD/TAK client access.
- **Network throughput stats** on `/api/status`, powering the dashboard's
  network graph.
- Raven-branded fallback templates for the few Flask-Security pages that
  aren't part of the React SPA.

If a future `opentakserver` release changes one of the patched files
enough that this patch no longer applies cleanly, `update.sh` will stop
and tell you rather than silently running unpatched (and therefore
insecure) code — see the `patch`-application step's output, and any
`.orig`/`.rej` files left in the package's install directory.

## `migrations/`

New Alembic migration(s) that ship separately from the patch (since
they're new files, not diffs against existing ones). Each is written to
be safe to run against a database that already has the column from an
earlier hand-applied patch, as well as one that doesn't.
