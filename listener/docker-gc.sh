#!/usr/bin/env bash
# docker-gc.sh -- the CI-owned, conservative Docker garbage collector for hosts
# whose jobs use the host Docker socket. The rules live in lib/docker-gc.sh;
# this is its command-line entrypoint, run daily by scaleset-listener-gc.timer
# (deploy/) with --apply, and by an operator with no flags for a dry run.
#
#   docker-gc.sh                 # dry run (the default): print what would go
#   docker-gc.sh --apply         # remove it
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd -P)"
# shellcheck source=SCRIPTDIR/../lib/docker-gc.sh
source "${SCRIPT_DIR}/../lib/docker-gc.sh"

usage() {
  cat <<'EOF'
Usage: docker-gc.sh [--dry-run | --apply] [options]

Remove Docker residue that CI jobs using the host Docker socket leave behind,
and nothing else. DRY RUN IS THE DEFAULT: without --apply nothing is removed.

Removed (each one logged on one line with a restore command):
  * images from ghcr.io/ycpss91255-lab/{runner-cpu,gpu-runner,runner-base} and
    ghcr.io/actions/actions-runner that were pulled by digest (no tag), whose
    digest is on no image: line of a runner-type config, and that no container
    (running or stopped) was created from. Restore: docker pull <repo>@<digest>
  * networks named <project>_default for a listed compose project, labelled
    with that project, with no container attached or referencing them, and
    older than 24h. github_runner is always listed; add more with --project,
    DOCKER_GC_PROJECTS or <etc>/docker-gc-projects (one name per line).

Never touched: volumes, buildx builders and the daemon build cache,
containers, images from any other repository, tagged images, and anything
with a gitlab label or name. Reclaiming those needs the host owner's approval.

Options:
  -n, --dry-run        print what would be removed (default)
      --apply          remove it
      --config <path>  also keep the images of this runner-type config
                       (repeatable; <etc>/runner-types*.yaml, RUNNER_TYPES_CONFIG
                       and the RUNNER_TYPES_CONFIG of every <etc>/*.env are
                       always read)
      --project <name> also collect <name>_default (repeatable)
      --etc <dir>      listener config dir (default: /etc/github-runner-listener)
  -h, --help           show this help

The daily timer installed by script/deploy-listener.sh runs this with --apply.
Turn it off with:

    sudo systemctl disable --now scaleset-listener-gc.timer

Exit code: 0 done (or dry run / no docker CLI), 1 bad usage or a removal failed.
EOF
}

main() {
  local etc=/etc/github-runner-listener
  local -a configs=() projects=()
  DOCKER_GC_APPLY=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -n|--dry-run) DOCKER_GC_APPLY=0; shift ;;
      --apply)      DOCKER_GC_APPLY=1; shift ;;
      --config)     configs+=("${2:?--config needs a value}"); shift 2 ;;
      --project)    projects+=("${2:?--project needs a value}"); shift 2 ;;
      --etc)        etc=${2:?--etc needs a value}; shift 2 ;;
      -h|--help)    usage; return 0 ;;
      *) echo "unknown option: $1" >&2; usage >&2; return 1 ;;
    esac
  done
  docker_gc_run "${etc}" configs projects
}

main "$@"
