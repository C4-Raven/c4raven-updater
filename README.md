<p align="center">
  <img src="https://raw.githubusercontent.com/C4Raven/c4raven-server-setup/master/docs/logo.png" alt="C4 Raven" width="480">
</p>

# C4 Raven updater

Deploys the latest [c4raven-server](https://github.com/C4Raven/c4raven-server)
(backend) and [c4raven-ui](https://github.com/C4Raven/c4raven-ui)
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
2. Fast-forwards `c4raven-server` to its `origin/master` and reinstalls
   it into the venv (editable install — no separate patch step, the
   customizations are just part of the fork's commit history).
3. Fast-forwards `c4raven-ui` to its `origin/master`, builds it, and
   deploys it.
4. Restarts `opentakserver.service`, `eud_handler.service`,
   `eud_handler_ssl.service`, and `cot_parser.service` (all four run
   from the same backend install) and waits for the health check.

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
  `origin/master`, the script stops and tells you rather than trying to
  reconcile them for you.

Everything that could go wrong is backed up first, before any change is
made.

## Usage

```
git clone https://github.com/C4Raven/c4raven-updater.git
cd c4raven-updater
./update.sh
```

Requires `sudo` access to restart the services, and network access to
GitHub and your npm registry.

### Configuration

The script assumes the same layout as a fresh install from
[c4raven-server-setup](https://github.com/C4Raven/c4raven-server-setup).
If your paths differ, override with environment variables:

| Variable          | Default                        | What it is                                       |
|-------------------|---------------------------------|---------------------------------------------------|
| `RAVEN_VENV`      | `~/.opentakserver_venv`         | Python virtualenv the backend runs from            |
| `RAVEN_DATA_DIR`  | `~/ots`                         | Data dir (`config.yml`, certs, uploads, ...)       |
| `RAVEN_SERVICES`  | see `update.sh`                 | Space-separated systemd units to restart           |
| `SERVER_SRC_DIR`  | `~/src/c4raven-server`          | Backend source checkout used for the editable install |
| `UI_SRC_DIR`      | `~/src/c4raven-ui`               | Where the frontend source is cloned/built          |
| `UI_DEPLOY_DIR`   | `/var/www/html/opentakserver`   | Where the built frontend is served from            |
| `BACKUP_ROOT`     | `~/backups`                     | Where timestamped backups are written              |
| `SKIP_UI`         | `0`                              | Set to `1` to update the backend only              |
| `SKIP_BACKEND`    | `0`                              | Set to `1` to update the frontend only             |

Example:

```
RAVEN_DATA_DIR=/opt/ots ./update.sh
```

## Rolling back

Every run writes a timestamped backup directory before touching
anything, printed at the end of the run (also under `~/backups/update-*`).
Inside it:

- `server-commit.txt` — the backend git commit that was checked out
  before the update, e.g. `git -C ~/src/c4raven-server checkout $(cat server-commit.txt)`
  then re-run `pip install -e ~/src/c4raven-server` in the venv
- `database.sql.gz` — a full `pg_dump`, restore with
  `gunzip -c database.sql.gz | psql <connection-string>`
- `raven-data.tar.gz` — your data directory (minus logs), restore by
  extracting it back over your data dir
- `ui/` — the previously-deployed frontend, restore with
  `rsync -a --delete ui/ /var/www/html/opentakserver/`

After restoring whichever pieces you need, restart the services:
`sudo systemctl restart opentakserver.service eud_handler.service eud_handler_ssl.service cot_parser.service`.

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
- New `OTS_*` config keys — need a `RAVEN_*` counterpart added to
  `config.example.yml` in
  [c4raven-server-setup](https://github.com/C4Raven/c4raven-server-setup)
  and to your own `config.yml`.
- New references to the server's own operational certificate, the
  plugin entry-point group, or anything else that has to match real
  external state rather than just our naming — see the "Revert the
  server's own cert identity and plugin group from the rename" commit
  in `c4raven-server`'s history for what that class of exception looks
  like.

Test it (`create_app()` should import and boot cleanly, ideally against
a copy of a real `config.yml`), then push to `origin/master`. Only then
does a normal `./update.sh` run pick it up.
