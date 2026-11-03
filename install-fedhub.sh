#!/usr/bin/env bash
# Installs TAK Federation Hub next to C4 Raven and connects Raven to it.
#
#   ./install-fedhub.sh [--artifact PATH] [--deb PATH] [--host NAME] [--yes] [--check]
#
# Federation Hub is licensed: download it from tak.gov first, as either
#   takserver-fed-hub_<ver>_all.deb          (Debian / Ubuntu)
#   takserver-fed-hub-docker-<ver>.zip       (Docker; Debian / Ubuntu / RHEL / Rocky 9)
# Without --artifact it is looked for in ~/Downloads (three levels deep).
#
#   --artifact PATH  the .deb or Docker .zip (--deb is the same)
#   --host NAME      the name (or IPv4) the hub's server certificate is issued
#                    for; Raven and other servers must connect with exactly it
#   --yes            never ask: use what was found / remembered
#   --check          change nothing; print one status line and exit
#                    0 installed and Raven connected, 3 not installed,
#                    4 installed but Raven not connected (or the hub's CA is
#                    not a CA group in the active federation policy).
#                    It takes no lock (safe while update.sh runs) and ignores
#                    the skip variables below.
#
# Host: --host NAME (changes the host), else the host used last time, else
# RAVEN_DOMAIN, else the domain install.sh recorded, else asked.
#
# Environment: RAVEN_FEDHUB_ARTIFACT (or RAVEN_FEDHUB_DEB), RAVEN_DOMAIN (host),
# RAVEN_USER (raven), RAVEN_HOME (/opt/raven), RAVEN_DATA_DIR ($RAVEN_HOME/data),
# RAVEN_VENV. Skip (do nothing, exit 2): RAVEN_FEDHUB_SKIP=1, or
# RAVEN_FEDHUB_ARTIFACT / RAVEN_FEDHUB_DEB set to an empty value.
#
# Exit: 0 installed and connected (or already was), 2 skipped (declined,
# nothing found and nobody to ask, the skip variables), 1 failed.
#
# Every step checks first and only does what is missing, so after a failure
# just run it again. Answers are remembered in $RAVEN_HOME/.install-answers
# (RAVEN_FEDHUB_MODE, _HOST, _VERSION, _DECLINED).
set -euo pipefail

# Before anything else (CI runs install.sh with these set). Same precedence as
# lib/common.sh's fedhub_skip_requested: RAVEN_FEDHUB_SKIP=1; else
# RAVEN_FEDHUB_ARTIFACT set but empty (non-empty = install that file); else,
# RAVEN_FEDHUB_ARTIFACT unset, RAVEN_FEDHUB_DEB set but empty. An explicit
# --artifact/--deb argument overrides the empty variables (not SKIP=1).
# --check only reports, so it is never skipped.
fh_early_skip() {
  local a has_check=0 has_artifact=0 why=""
  for a in "$@"; do
    case "$a" in
      --check) has_check=1 ;;
      --artifact|--artifact=*|--deb|--deb=*) has_artifact=1 ;;
    esac
  done
  [ "$has_check" = 1 ] && return 0
  if [ "${RAVEN_FEDHUB_SKIP:-0}" = 1 ]; then
    why="RAVEN_FEDHUB_SKIP=1"
  elif [ "$has_artifact" = 0 ]; then
    if [ -n "${RAVEN_FEDHUB_ARTIFACT+x}" ]; then
      [ -n "$RAVEN_FEDHUB_ARTIFACT" ] || why="RAVEN_FEDHUB_ARTIFACT is empty"
    elif [ -n "${RAVEN_FEDHUB_DEB+x}" ] && [ -z "$RAVEN_FEDHUB_DEB" ]; then
      why="RAVEN_FEDHUB_DEB is empty"
    fi
  fi
  if [ -n "$why" ]; then
    echo "Federation Hub: skipped ($why)."
    exit 2
  fi
  return 0
}
fh_early_skip "$@"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FH_SELF="$HERE/install-fedhub.sh"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/fedhub.sh
. "$HERE/lib/fedhub.sh"
# shellcheck source=lib/fedhub_deb.sh
. "$HERE/lib/fedhub_deb.sh"
# shellcheck source=lib/fedhub_docker.sh
. "$HERE/lib/fedhub_docker.sh"

fh_usage() {
  sed -n '2,/^set -euo/p' "$FH_SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

fh_parse_args() {
  FH_ARTIFACT_ARG="${RAVEN_FEDHUB_ARTIFACT:-${RAVEN_FEDHUB_DEB:-}}"
  FH_HOST_ARG=""
  FH_YES=0
  FH_CHECK=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --artifact|--deb) [ "$#" -ge 2 ] || die "$1 needs a path"; FH_ARTIFACT_ARG=$2; shift 2 ;;
      --artifact=*|--deb=*) FH_ARTIFACT_ARG=${1#*=}; shift ;;
      --host) [ "$#" -ge 2 ] || die "--host needs a name"; FH_HOST_ARG=$2; shift 2 ;;
      --host=*) FH_HOST_ARG=${1#*=}; shift ;;
      --yes|-y) FH_YES=1; shift ;;
      --check) FH_CHECK=1; shift ;;
      -h|--help) fh_usage; exit 0 ;;
      *) die "unknown argument: $1 (see --help)" ;;
    esac
  done
}

fh_lock() {
  # Same lock as update.sh / finish-install.sh (read-only descriptor; see there).
  if [ -z "${RAVEN_UPDATER_LOCKED:-}" ] && command -v flock >/dev/null 2>&1; then
    RAVEN_LOCK="${TMPDIR:-/tmp}/c4raven-updater.lock"
    [ -e "$RAVEN_LOCK" ] || (umask 000; : > "$RAVEN_LOCK") 2>/dev/null || true
    { exec 9<"$RAVEN_LOCK"; } 2>/dev/null || die "Cannot open the lock file $RAVEN_LOCK (delete it and re-run)."
    flock -n 9 || die "Another update.sh / finish-install.sh / install-fedhub.sh is already running."
    export RAVEN_UPDATER_LOCKED=1
  fi
}

# fh_detect -- what is on this machine already. Sets FH_MODE (deb, docker or
# empty), FH_INSTALLED (1 = complete) and FH_RESUMABLE (1 = can be finished
# without the release file).
fh_detect() {
  FH_MODE=$(answers_get RAVEN_FEDHUB_MODE)
  FH_INSTALLED=0
  FH_RESUMABLE=0
  if [ -z "$FH_MODE" ]; then
    if [ -n "$(fh_deb_installed_version)" ] || as_root test -f "$FEDHUB_ROOT/jars/federation-hub-broker.jar"; then
      FH_MODE=deb
    elif [ -n "$(fh_docker_unpacked_version)" ]; then
      FH_MODE=docker
    fi
  fi
  case "$FH_MODE" in
    deb)
      [ -n "$(fh_deb_installed_version)" ] && FH_RESUMABLE=1
      fh_deb_installed && FH_INSTALLED=1
      FH_VERSION=$(fh_deb_installed_version) ;;
    docker)
      FH_VERSION=$(answers_get RAVEN_FEDHUB_VERSION)
      [ -n "$FH_VERSION" ] || FH_VERSION=$(fh_docker_unpacked_version)
      [ -n "$FH_VERSION" ] && as_root test -f "$FEDHUB_DOCKER_BASE/$FH_VERSION/docker/Dockerfile.fedhub" && FH_RESUMABLE=1
      fh_docker_installed && FH_INSTALLED=1 ;;
  esac
  return 0
}

fh_check() {
  local problems
  fh_detect
  if [ "$FH_INSTALLED" != 1 ]; then
    if [ -n "$FH_MODE" ]; then
      echo "Federation Hub: not installed (a $FH_MODE install is incomplete; run $FH_SELF to finish it)"
    else
      echo "Federation Hub: not installed"
    fi
    return 3
  fi
  if problems=$(fh_wiring_problems); then
    echo "Federation Hub: installed ($FH_MODE ${FH_VERSION:-?}), Raven connected"
    return 0
  fi
  echo "Federation Hub: installed ($FH_MODE ${FH_VERSION:-?}), Raven not connected: $problems"
  return 4
}

fh_summary() {
  local group user problems
  group=$(fh_raven_setting RAVEN_FEDHUB_FEDERATE_GROUP); group=${group:-Fed group}
  user=$(fh_raven_setting RAVEN_FEDHUB_FEDERATE_USERNAME); user=${user:-Server}
  FH_PROBLEMS=""
  problems=$(fh_wiring_problems) || FH_PROBLEMS=${problems:-not connected}
  echo
  if [ -z "$FH_PROBLEMS" ]; then
    echo "Federation Hub is installed and Raven is connected to it."
  else
    echo "Federation Hub is installed, but Raven is NOT fully connected: $FH_PROBLEMS"
  fi
  cat <<EOF

  Mode:            $MODE (version ${FH_VERSION:-?})
  Host:            $HOST  (the server certificate is issued for this name)
  Admin console:   https://$HOST:9100  (log in with the fedhub-admin.p12 client certificate)
  Admin cert:      $FH_FILES/fedhub-admin.p12  (copy it off securely: it holds a private key);
                   Raven's admins can also download it, with its password, from Raven
  Passwords:       $FH_PWFILE
                   the .p12 import password is PASS in that file: sudo cat $(fh_q "$FH_PWFILE")
  Raven:           $CFG (RAVEN_FEDHUB_*), certificates in $DATA_DIR/fedhub,
                   fedhub_bridge.service
  Policy:          the hub's CA ($FEDHUB_CA_NAME) is a CA group in the active
                   federation policy ($(fh_policy_file));
                   add partner CAs and rules in the admin console

Raven creates the "$group" group (RAVEN_FEDHUB_FEDERATE_GROUP) and the "$user"
system user in it when it starts (RAVEN_FEDHUB_FEDERATE_ENABLE is on), so there
is nothing to create by hand.
EOF
  [ -z "$FH_PROBLEMS" ] || warn "Raven is not fully connected to Federation Hub: $FH_PROBLEMS (re-run $FH_SELF after fixing it; $FH_SELF --check shows the state)"
  echo
  print_summary
}

fh_main() {
  local kind
  fh_parse_args "$@"
  fh_detect_backend
  # --check is read-only: no lock (it must work while update.sh holds it,
  # and must not create the lock file).
  if [ "$FH_CHECK" = 1 ]; then
    local rc=0
    fh_check || rc=$?
    exit "$rc"
  fi
  fh_lock
  [ "$(id -un)" != "$APP_USER" ] || [ "$IS_ROOT" = 1 ] || [ "$APP_USER" = "$FEDHUB_TAK_USER" ] \
    || die "Run this as your own sudo-capable user (or root), not as '$APP_USER'."
  systemd_notice
  fh_detect

  ARTIFACT=""
  if [ -n "$FH_ARTIFACT_ARG" ]; then
    ARTIFACT=$(fh_clean_path "$FH_ARTIFACT_ARG")
    [ -f "$ARTIFACT" ] || die "no such file: $ARTIFACT"
    ARTIFACT=$(readlink -f "$ARTIFACT")
  elif [ "$FH_RESUMABLE" != 1 ]; then
    fh_choose_artifact          # exits 2 when skipped
  fi

  if [ -n "$ARTIFACT" ]; then
    kind=$(fh_artifact_kind "$ARTIFACT")
    [ -n "$kind" ] || die "$ARTIFACT is not a Federation Hub .deb or Docker release zip."
    fh_mode_for "$kind"
    if [ -n "$FH_MODE" ] && [ "$FH_MODE" != "$MODE" ] && [ "$FH_RESUMABLE" = 1 ]; then
      die "Federation Hub is already installed here as the $FH_MODE release; refusing to add the $MODE one as well (both use ports 9100-9102). Remove the old one first."
    fi
    answers_set RAVEN_FEDHUB_DECLINED 0
  else
    MODE=$FH_MODE
    echo "Finishing the existing $MODE install of Federation Hub."
  fi

  fh_resolve_host
  answers_set RAVEN_FEDHUB_MODE "$MODE"
  answers_set RAVEN_FEDHUB_HOST "$HOST"
  log "Federation Hub: $MODE release, host $HOST"

  FH_CHANGED=0
  if [ "$MODE" = deb ]; then
    fh_deb_install "$ARTIFACT"
  else
    fh_docker_install "$ARTIFACT"
  fi
  answers_set RAVEN_FEDHUB_VERSION "$FH_VERSION"
  log "Federation Hub files holding passwords"
  fh_protect_configs

  fh_wire_raven
  log "Firewall"
  fh_firewall
  fh_summary
  [ -z "$FH_PROBLEMS" ] || exit 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fh_main "$@"
fi
