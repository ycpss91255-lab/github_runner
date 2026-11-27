#!/usr/bin/env bash
# Take a scale-set listener back off this machine -- the reversal of the LOCAL
# half of script/deploy-listener.sh.
#
# The project requires destructive operations to be reversible, so the command
# that stands a machine up has a counterpart that takes it down. This carries
# the same preview/confirm contract as the other destructive scripts
# (uninstall.sh, cleanup.sh, remove-runner.sh): print the plan, prompt, and
# refuse a non-interactive run that did not pass --yes.
#
# IT DOES NOT DELETE THE SCALE SET, and there is no flag that makes it.
# The scale set lives on GitHub and is shared by every machine serving that
# runner type: deleting it while decommissioning ONE host would stop serving
# all of them, which is not what "take this machine down" can be allowed to
# mean. Deleting it is a separate, explicit act:
#
#     scaleset-admin delete --config <path> --type <name> --yes
#
# Usage:
#   sudo ./script/teardown-listener.sh                 # prompt first
#   sudo ./script/teardown-listener.sh --dry-run       # print the plan
#   sudo ./script/teardown-listener.sh --yes           # unattended
#   ./script/teardown-listener.sh -h | --help
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=SCRIPTDIR/../lib/listener-deploy.sh
source "${SCRIPT_DIR}/../lib/listener-deploy.sh"

LISTENER_YES=0
DRY_RUN=0
KEEP_USER=1
TYPE_NAME=""
TYPE_GIVEN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Remove scale-set listeners from THIS machine. Stop and disable each selected
unit and remove its environment file and runner state. The last removal also
removes the shared template and install prefix. Already absent files are skipped.

It does NOT delete the scale set on GitHub. That is shared by every machine
serving the runner type, so removing one host must not stop serving the rest.
Delete it deliberately, when you actually mean to retire the runner type:

    scaleset-admin delete --config <path> --type <name> --yes

Options:
  --type <name>     remove one type (default: remove all listeners)
  --prefix <path>   install prefix to remove (default: /opt/github-runner-listener)
  --etc <path>      config dir holding the environment file
                    (default: /etc/github-runner-listener)
  --unit-dir <path> where the systemd unit lives
                    (default: /etc/systemd/system)
  --remove-user <name>
                    also remove the service user (not done by default: the
                    account may own other things on this host)
  -n, --dry-run     print the plan; remove nothing
  -y, --yes         skip the confirmation. REQUIRED for non-interactive runs.
  -h, --help        show this help

Exit code:
  0  Removed (or dry-run / nothing to remove / aborted at the prompt).
  1  Bad usage, or a non-interactive run was attempted without --yes.
EOF
}

SERVICE_USER=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --type)        TYPE_NAME=${2-}; TYPE_GIVEN=1; shift; if (( $# )); then shift; fi ;;
      --prefix)      LISTENER_PREFIX=${2:?--prefix needs a value}; shift 2 ;;
      --etc)         LISTENER_ETC=${2:?--etc needs a value}; shift 2 ;;
      --unit-dir)    LISTENER_UNIT_DIR=${2:?--unit-dir needs a value}; shift 2 ;;
      --remove-user) SERVICE_USER=${2:?--remove-user needs a value}; KEEP_USER=0; shift 2 ;;
      -n|--dry-run)  DRY_RUN=1; shift ;;
      -y|--yes)      LISTENER_YES=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
  done
}

# Refuse to rm a prefix that is not a plausible install root. The prefix is an
# rm -rf target, so it is checked lexically here -- the same defence
# lib/common.sh applies to RUNNER_HOME -- rather than trusted because it came
# from a flag.
assert_removable_prefix() {
  local dir=$1
  [[ ${dir} = /* ]] || { echo "FAIL: --prefix must be absolute: '${dir}'" >&2; exit 1; }
  case "/${dir}/" in
    */../*) echo "FAIL: --prefix must be normalized (no '..'): '${dir}'" >&2; exit 1 ;;
  esac
  # Collapse redundant slashes and dot components before checking broad roots.
  LISTENER_PREFIX=$(realpath -ms -- "${dir}")
  case "${LISTENER_PREFIX}" in
    /|/etc|/usr|/var|/home|/opt|/root|"${HOME:-}")
      echo "FAIL: refusing to remove '${dir}'" >&2; exit 1 ;;
  esac
}

main() {
  parse_args "$@"
  listener_deploy_paths
  assert_removable_prefix "${LISTENER_PREFIX}"

  local remove_legacy=1 remove_shared=1 env_file type unit reload=0
  local -a env_files=() units=()
  if (( TYPE_GIVEN )); then
    listener_type_paths "${TYPE_NAME}"
    # A symlink at either parent would send a per-type rm outside the state tree.
    if [[ -L ${LISTENER_PREFIX} || -L ${LISTENER_PREFIX}/runners ]]; then
      echo "FAIL: refusing to remove a runner tree through a symlink" >&2
      exit 1
    fi
    env_files+=("${LISTENER_ENV_FILE}")
    units+=("${LISTENER_UNIT_NAME}")
    remove_legacy=0
    if [[ -f ${LISTENER_LEGACY_ENV_FILE} ]] &&
      [[ $(listener_env_value "${LISTENER_LEGACY_ENV_FILE}" RUNNER_TYPE) == "${LISTENER_TYPE}" ]]; then
      remove_legacy=1
    elif [[ -e ${LISTENER_LEGACY_UNIT_PATH} || -L ${LISTENER_LEGACY_UNIT_PATH} ]]; then
      remove_shared=0
    fi
  fi

  # Environment files are the inventory. Even an env file with an unexpected
  # name keeps shared files in place during a typed teardown.
  for env_file in "${LISTENER_ETC}"/*.env; do
    [[ -f ${env_file} && ${env_file} != "${LISTENER_LEGACY_ENV_FILE}" ]] || continue
    if (( TYPE_GIVEN )); then
      [[ ${env_file} == "${LISTENER_ENV_FILE}" ]] || remove_shared=0
    else
      env_files+=("${env_file}")
      type=${env_file##*/}
      type=${type%.env}
      if listener_valid_type_name "${type}"; then
        units+=("scaleset-listener@${type}.service")
      fi
    fi
  done
  if (( remove_legacy )); then
    units+=("${LISTENER_LEGACY_UNIT_NAME}")
    env_files+=("${LISTENER_LEGACY_ENV_FILE}")
  fi

  echo "Plan:"
  for unit in "${units[@]}"; do
    echo "  Stop + disable:   ${unit}"
  done
  for env_file in "${env_files[@]}"; do
    echo "  Remove env file:  ${env_file}   (holds the admin token)"
  done
  if (( remove_legacy )); then
    echo "  Remove unit:      ${LISTENER_LEGACY_UNIT_PATH}"
  fi
  if (( TYPE_GIVEN )); then
    echo "  Remove state:     ${LISTENER_RUNNER_HOME}"
  fi
  if (( remove_shared )); then
    echo "  Remove template:  ${LISTENER_UNIT_PATH}"
    echo "  Remove prefix:    ${LISTENER_PREFIX}"
  else
    # A remaining instance may still need the service account.
    KEEP_USER=1
  fi
  if (( KEEP_USER )); then
    echo "  Service user:     left in place"
  else
    echo "  Remove user:      ${SERVICE_USER}"
  fi
  echo "  NOT touched:      the scale set on GitHub (shared by every machine"
  echo "                    serving this runner type). Delete it deliberately:"
  echo "                      scaleset-admin delete --config <path> --type <name> --yes"
  echo

  if (( DRY_RUN )); then
    echo "Dry run; nothing was removed."
    exit 0
  fi

  listener_confirm "Proceed? [y/N] "

  for unit in "${units[@]}"; do
    listener_stop_disable_unit "${unit}"
  done
  if (( remove_legacy )) && [[ -e ${LISTENER_LEGACY_UNIT_PATH} || -L ${LISTENER_LEGACY_UNIT_PATH} ]]; then
    rm -- "${LISTENER_LEGACY_UNIT_PATH}"
    echo "  removed unit:     ${LISTENER_LEGACY_UNIT_PATH}"
    reload=1
  fi
  for env_file in "${env_files[@]}"; do
    if [[ -e ${env_file} || -L ${env_file} ]]; then
      rm -- "${env_file}"
      echo "  removed env file: ${env_file}"
    fi
  done
  if (( TYPE_GIVEN )); then
    rm -rf -- "${LISTENER_RUNNER_HOME}"
    echo "  removed state:    ${LISTENER_RUNNER_HOME}"
  fi
  if (( remove_shared )); then
    if [[ -e ${LISTENER_UNIT_PATH} || -L ${LISTENER_UNIT_PATH} ]]; then
      rm -- "${LISTENER_UNIT_PATH}"
      echo "  removed template: ${LISTENER_UNIT_PATH}"
      reload=1
    fi
    if [[ -d ${LISTENER_PREFIX} ]]; then
      rm -rf -- "${LISTENER_PREFIX}"
      echo "  removed prefix:   ${LISTENER_PREFIX}"
    else
      echo "  prefix:           already absent, skipped"
    fi
  fi
  if (( reload )); then
    _systemctl daemon-reload
  fi

  if (( ! KEEP_USER )) && listener_service_user_exists "${SERVICE_USER}"; then
    userdel -r "${SERVICE_USER}" >/dev/null 2>&1 || true
    echo "  removed user:     ${SERVICE_USER}"
  fi

  echo
  if (( TYPE_GIVEN )); then
    echo "Removed listener for ${LISTENER_TYPE}."
  else
    echo "Removed all listeners from this machine."
  fi
  echo "The scale set on GitHub is untouched."
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
  main "$@"
fi
