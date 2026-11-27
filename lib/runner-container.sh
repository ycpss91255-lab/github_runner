#!/usr/bin/env bash
# Runner Container -- the per-job container provisioner (ADR-0001 Phase 3,
# advances #82). This is the isolation CORE the ADR calls out: the scale-set
# client decides when / how many runners, but the per-job container -- where the
# residue/secret guarantees actually land -- is ours. Each ephemeral job runs in
# a FRESH, single-use, rootless container that is torn down on exit, so no state
# (a poisoned _work tree, leaked secrets in env/cache/disk) survives the job.
# The container is the unit of isolation -- one ephemeral `run.sh --jitconfig`
# run, walled off from the host and from every other job.
#
# Sourced by lib/common.sh. This is the SINGLE place the one-job
# `run.sh --jitconfig <encoded>` invocation lives, executed INSIDE the throwaway
# container rather than directly on the host. The encoded JIT config is minted
# by the Go scale-set client (ADR-0001/ADR-0003), not by any bash seam, and is
# delivered into the container OFF the host argv via a mode-0600 --env-file
# (#136), so the single-use credential never lands in the HOST process table --
# the ADR-0003 invariant holds on the bash side, not just the Go side.
# shellcheck shell=bash

# The label value that marks every container THIS tool provisions, so the
# orphan reaper (#105) can find and remove our containers (and only ours)
# without touching anything else on the host. Overridable for tests / multiple
# fleets on one host.
: "${RUNNER_MANAGED_BY:=github-runner-listener}"

# Per-job max wall-clock lifetime in seconds (#107): the watchdog stops+removes
# a container that outlives this, so a hung job cannot hold host resources
# forever. Default 6h; override for shorter/longer ceilings. 0 disables it.
: "${RUNNER_JOB_MAX_LIFETIME:=21600}"

# Baseline container-hardening knobs (#114, ADR-0001 "defense-in-depth on every
# job container"). Every per-job container drops ALL Linux capabilities, runs
# with no-new-privileges (a job can never gain privileges via setuid), and is
# bounded by a pids-limit (a fork bomb cannot exhaust host PIDs). The default
# seccomp profile is KEPT (we never pass seccomp=unconfined) and MAC stays
# enforced (#115). Add-back is empty by default -- the runner needs no
# capabilities to execute actions -- but RUNNER_CAP_ADD lets a runner type grant
# a minimal, explicit set when a job genuinely needs one (space-separated cap
# names, e.g. "NET_BIND_SERVICE").
: "${RUNNER_PIDS_LIMIT:=4096}"
: "${RUNNER_CAP_ADD:=}"

# Docker-socket opt-in (#116). By DEFAULT a job container NEVER receives the host
# docker socket -- so job code cannot reach the host daemon (root-equivalence) --
# and image builds go through the daemonless build seam (#118) instead. A runner
# type that genuinely needs the daemon opts in EXPLICITLY by setting this to the
# host socket path; the listener only sets it for a type that asked for it. Empty
# = no socket mount (the secure default).
: "${RUNNER_DOCKER_SOCKET:=}"

# Precise device passthrough (#117). The host device nodes a runner type declares
# (RunnerType.Devices in the config, e.g. /dev/nvidia0), passed as the listener's
# shell-out parameter. Each becomes one `--device <node>` -- least-privilege, and
# NEVER --privileged. Whitespace-separated (newline or space) so the listener can
# pass the type's device list verbatim. Empty (a plain CPU type) = no --device.
: "${RUNNER_DEVICES:=}"

# Container runtime / hardware shim (the runner type's `runtime:` knob, passed
# as the listener's shell-out parameter). Names an engine runtime such as
# "nvidia" (the GPU shim that injects the driver/CUDA stack), or a stronger
# sandbox like "gvisor"/"kata" later. A non-empty value becomes exactly one
# `--runtime <value>` on the container run; EMPTY adds no flag, leaving the
# engine default in force. The value is free text on purpose -- it names a shim
# registered with the local engine, which we cannot enumerate from here -- so a
# wrong value makes the engine refuse the run LOUDLY rather than silently
# dropping a runtime the operator asked for.
: "${RUNNER_RUNTIME:=}"

# The runner's home INSIDE the image: where the bundled actions/runner (run.sh,
# config.sh, bin/) lives and where the job runs from. Both the self-built images
# (images/runner-base.Dockerfile: WORKDIR /home/runner, USER runner) and the
# official ghcr.io/actions/actions-runner image use this layout. The container
# works from here so run.sh remains visible. _diag lives in the container's
# writable layer. The default _work does too. Socket-enabled jobs instead use
# an absolute work folder mounted at the same path as the per-job host dir.
# Overridable for an image that installs the runner elsewhere.
: "${RUNNER_CONTAINER_HOME:=/home/runner}"

# runner_work_root -- the per-job work root shared by provision-job.sh and
# reap.sh. Keep it in sync with socketJobWorkDir in the listener. Both scripts must
# agree on this path or the reaper sweeps the WRONG directory: provision-job.sh
# would strand residue under RUNNER_HOME/work while reap.sh globbed a different
# root and reported success having cleaned nothing (#148). Sourced by BOTH
# provision-job.sh (directly) and reap.sh (via common.sh), so the resolution can
# never re-diverge.
#
# Defaults to ${RUNNER_HOME}/work -- the SEC-3 rm chokepoint the history store
# also lives under (#130) -- with RUNNER_WORK_ROOT overriding for tests/alternate
# layouts. RUNNER_HOME, when unset, defaults to <repo_root>/runners EXACTLY as
# common.sh resolves it: this file lives in lib/ beside common.sh, so the same
# lib-relative `../runners` fallback yields the identical path whether reached via
# common.sh (which sets RUNNER_HOME readonly) or via provision-job.sh's direct
# source (which sets its own SCRIPT_DIR/../runners default -- the same dir).
runner_work_root() {
  local home="${RUNNER_HOME:-}"
  if [[ -z "${home}" ]]; then
    home="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/runners"
  fi
  printf '%s\n' "${RUNNER_WORK_ROOT:-${home%/}/work}"
}

# Emit the baseline hardening argv (#114) one token per array element, for the
# caller to splice into `<cli> run`. cap-drop=ALL + optional minimal add-back,
# no-new-privileges, and a pids-limit. Deliberately does NOT touch seccomp (the
# engine default profile stays on) or MAC (kept enforced, #115).
#   runner_container_hardening_args  -> prints flags, newline-separated
runner_container_hardening_args() {
  local -a args=(
    --cap-drop=ALL
    --security-opt no-new-privileges
    --pids-limit "${RUNNER_PIDS_LIMIT}"
  )
  local cap
  for cap in ${RUNNER_CAP_ADD}; do
    args+=(--cap-add="${cap}")
  done
  printf '%s\n' "${args[@]}"
}

# Deterministic container name for a job id (#104): the same job id always maps
# to the same name, so a container can be correlated and reaped by name. Sanitise
# the job id to the [a-zA-Z0-9_.-] set Docker/Podman allow in names (anything
# else becomes '-'), prefixed so our containers are recognisable at a glance.
#   runner_container_name <job_id>
runner_container_name() {
  local job_id=$1 safe
  safe=$(printf '%s' "${job_id}" | tr -c 'a-zA-Z0-9_.-' '-')
  printf 'gha-jit-%s' "${safe}"
}

# Sanitise the attacker-influenced job id for use as a LABEL value (#137). The
# scale-set JobID flows into our job-id label unsanitized; a NEWLINE (or other
# control char) in that label is what let the reaper's old "<name> <label>"
# listing be split into a forged phantom row naming an arbitrary victim. Strip
# every control character (incl. CR/LF/TAB) so the label can never carry a line
# break. Kept less aggressive than the name sanitiser (the label is
# informational, not a shell/engine identifier); the control-char strip is the
# security-load-bearing part, and the reaper additionally reaps by container ID
# so it never parses this value as a removal target.
#   runner_job_id_label <job_id>
runner_job_id_label() {
  local job_id=$1
  printf '%s' "${job_id}" | tr -d '[:cntrl:]'
}

# Pick the rootless container CLI: podman preferred over docker (rootless is
# podman's default mode -- no daemon, no root -- which is the #82 goal; docker
# is the fallback for hosts that only ship it). Prints the CLI name, or returns
# non-zero (printing nothing) when neither is on PATH, so the caller can fail
# with one clear line instead of an obscure command-not-found mid-run.
runner_container_cli() {
  if command -v podman >/dev/null 2>&1; then
    printf 'podman'
  elif command -v docker >/dev/null 2>&1; then
    printf 'docker'
  else
    return 1
  fi
}

# Run exactly one ephemeral job inside a throwaway, rootless container, then let
# it be torn down -- the per-job isolation boundary.
#   runner_container_run <dir> <encoded_jit_config> <image> [job_id]
# Detects the CLI (runner_container_cli), then `<cli> run --rm ...` the image so
# the container is single-use and removed on exit (--rm: no state survives),
# executing the Phase 2 ephemeral run (run.sh --jitconfig <encoded>) inside it.
# The encoded credential is passed to the container via a mode-0600 --env-file
# (#136), never on the host `<cli> run` argv, so it stays off the host process
# table; run.sh reads it from $JITCONFIG inside the container's own namespace.
# Rootless-appropriate: --init reaps the runner's child PIDs (no host init); the
# baseline hardening flags (#114) and MAC kept enforced (#115: no label=disable,
# any opt-in bind mount relabelled :Z) keep it an unprivileged, self-contained
# unit. When a job id is given,
# the container gets a DETERMINISTIC
# --name and managed-by + job-id --labels (#104) so the reaper (#105) can
# correlate and remove orphans. PROPAGATES the in-container job's exit status (it
# is the whole job lifecycle). The image's bundled run.sh runs from
# RUNNER_CONTAINER_HOME inside the container. <dir> is the per-job HOST dir; it
# is mounted at the same path for socket-enabled jobs only. The credential
# env-file remains a sibling of the dir in either mode.
runner_container_run() {
  local dir=$1 encoded=$2 image=$3 job_id=${4:-} cli line
  cli=$(runner_container_cli) || {
    echo "FAIL: no rootless container CLI found (need podman or docker)" >&2
    return 1
  }
  # Build the identity args (name + labels) only when a job id is supplied, so
  # the deterministic name and managed-by/job-id labels keyed by the job id let
  # the orphan reaper find exactly our containers.
  local -a id_args=()
  if [[ -n "${job_id}" ]]; then
    id_args=(
      --name "$(runner_container_name "${job_id}")"
      --label "managed-by=${RUNNER_MANAGED_BY}"
      --label "job-id=$(runner_job_id_label "${job_id}")"
    )
  fi
  # Baseline hardening flags (#114): read one-per-line into an array so each
  # token survives as its own argv word.
  local -a hardening_args=()
  while IFS= read -r line; do hardening_args+=("${line}"); done < <(runner_container_hardening_args)
  # The listener sets RUNNER_DOCKER_SOCKET from the per-type docker_socket
  # opt-in (#116). Empty leaves the mount off. Access is root-equivalent on
  # the host. The mount keeps :Z relabelling, and --group-add lets the runner
  # user open the socket even if its image-local docker group has a different GID.
  # Resolve the target's GID because the bind mount follows symlinks.
  local -a socket_args=()
  local socket_gid
  if [[ -n "${RUNNER_DOCKER_SOCKET}" ]]; then
    if ! socket_gid=$(stat -L -c %g "${RUNNER_DOCKER_SOCKET}" 2>/dev/null) || [[ ! ${socket_gid} =~ ^[0-9]+$ ]]; then
      printf 'FAIL: cannot resolve group ID for Docker socket %s\n' "${RUNNER_DOCKER_SOCKET}" >&2
      return 1
    fi
    socket_args=(
      -v "${RUNNER_DOCKER_SOCKET}:${RUNNER_DOCKER_SOCKET}:Z"
      -v "${dir}:${dir}:Z"
      --group-add "${socket_gid}"
    )
  fi
  # Precise --device passthrough (#117): one --device per declared host node, no
  # --privileged. Word-splitting RUNNER_DEVICES on whitespace is intentional so a
  # newline- or space-separated device list maps to exactly those nodes.
  local -a device_args=() dev
  for dev in ${RUNNER_DEVICES}; do
    device_args+=(--device "${dev}")
  done
  # Container runtime shim: the runner type's `runtime:` knob becomes exactly one
  # `--runtime <value>` pair. Quoted (not word-split) so the value crosses as a
  # single argv token, and only added when non-empty so a type that declares no
  # runtime keeps the engine default rather than being handed an empty flag.
  local -a runtime_args=()
  if [[ -n "${RUNNER_RUNTIME}" ]]; then
    runtime_args=(--runtime "${RUNNER_RUNTIME}")
  fi
  # Deliver the single-use JIT credential to the container OFF the host argv
  # (#136, restores the ADR-0003 invariant). Splicing `--jitconfig "${encoded}"`
  # directly onto the host `<cli> run ...` argv put the credential in the HOST
  # process table (/proc/<pid>/cmdline, world-readable) for the container's whole
  # life -- the exact exposure the Go->bash file handoff exists to prevent. The
  # Go side keeps it off ITS argv (a 0600 file, ADR-0003); bash must not undo
  # that here. Instead write the credential to a mode-0600 --env-file inside the
  # (throwaway, per-job) runner dir as KEY=VALUE; the engine reads the VALUE from
  # the file, so only the env-file PATH -- never the secret -- is on the host
  # argv. The env-file is named in the dir torn down with the job (--rm + the
  # caller's rm -rf), so the credential file does not survive teardown.
  #
  # The container then receives the credential through its environment ONLY, set
  # from this --env-file as the runner's native ACTIONS_RUNNER_INPUT_JITCONFIG
  # input. It is NEVER spliced onto any process argv -- not the host CLI argv and
  # not the in-container run.sh argv (#155). The earlier form
  # `./run.sh --jitconfig "${JITCONFIG}"` looked safe because the host string is
  # kept literal, but the CONTAINER's `sh -c` expands $JITCONFIG onto run.sh's
  # argv, and for rootless/rootful engines run.sh is an ordinary HOST process:
  # its /proc/<pid>/cmdline is mode 0444 (world-readable, no ptrace/owner check,
  # unlike /proc/<pid>/environ), so ANY local host user could read the base64 JIT
  # config off run.sh's cmdline for the whole job -- the exact off-argv invariant
  # #136/ADR-0003 exists to hold. A PID namespace only renumbers PIDs as seen
  # from inside the container; it does not remove run.sh's task from the host
  # procfs. Delivering via the env (ACTIONS_RUNNER_INPUT_JITCONFIG, which the
  # official runner reads natively) keeps the secret on /proc/<pid>/environ
  # (ptrace-protected) and off the world-readable cmdline end to end.
  # The env-file MUST live OUTSIDE `${dir}` (#140). `${dir}` used to be mounted
  # READ-WRITE as the job's working directory, so a file written under it
  # (`${dir}/.jitconfig.env`) was visible to -- and copyable by -- the hostile
  # job, which could plant the single-use credential into _diag. `${dir}` is no
  # longer mounted at all, but the sibling placement is kept so that no future
  # mount of the per-job dir can ever expose the credential file. The engine
  # still reads its VALUE from the file (never the host argv, #136).
  # The sibling sits beside `${dir}` under the same throwaway work root, so the
  # caller's `rm -rf "${runner_dir}"` does not remove it -- we delete it here on
  # return (success or failure) via a RETURN trap so the credential file does not
  # outlive this function.
  local env_file="${dir%/}.jitconfig.env"
  # Restrict before writing so the secret never exists world-readable, even
  # briefly. printf (not echo) so a value with leading '-' is written verbatim;
  # the single KEY=VALUE line is the --env-file format the engines expect.
  ( umask 077; : >"${env_file}"; )
  # Set the env var the official runner reads natively (ACTIONS_RUNNER_INPUT_
  # JITCONFIG), so run.sh consumes the credential from its ENVIRONMENT and we
  # never have to put it on run.sh's argv (#155).
  printf 'ACTIONS_RUNNER_INPUT_JITCONFIG=%s\n' "${encoded}" >"${env_file}"
  # Shred the sibling env-file when this function returns, by ANY path, so the
  # single-use credential never lingers on disk past the container's run.
  #
  # The trap action MUST embed the path as code, because `env_file` is a function
  # LOCAL and bash runs a RETURN trap in the CALLER's scope (the bounded wrapper),
  # where the local is already gone -- a deferred `"${env_file}"` would hit
  # `set -u` "unbound variable" and abort the job. So the path is expanded now;
  # the danger is that `dir` (hence env_file) embeds the only-control-char-
  # stripped scale-set JobID verbatim (mktemp -d jit-<job_id>.XXXXXX). A path
  # spliced inside single quotes in a double-quoted trap let a `'` in a hostile
  # JobID close the quoting so a trailing `; <cmd> #` ran on the HOST when the
  # trap fired (#142). printf %q renders the path in a re-parse-safe form
  # (quotes, ;, space, $(...) all escaped), so the trap is exactly one `rm`
  # argument and no attacker data is ever parsed as a command.
  local env_file_q
  printf -v env_file_q '%q' "${env_file}"
  # shellcheck disable=SC2064  # expand NOW (local not in scope on RETURN); %q-safe
  trap "rm -f -- ${env_file_q}" RETURN

  # The in-container command. run.sh reads the credential from its ENVIRONMENT
  # (ACTIONS_RUNNER_INPUT_JITCONFIG, set from --env-file), so we pass NO
  # credential on its argv -- not the value and not a $JITCONFIG expansion. This
  # keeps the secret off run.sh's world-readable host /proc/<pid>/cmdline (#155);
  # do NOT add `--jitconfig "${JITCONFIG}"` back here -- that re-exposes it.
  local run_in_container='./run.sh'

  # Work from the image's runner home, where run.sh lives. Socket-enabled
  # jobs have two :Z bind mounts: the socket and the absolute work folder.
  # MAC (SELinux/AppArmor) stays enforced (#115).
  "${cli}" run --rm --init \
    "${hardening_args[@]}" \
    "${socket_args[@]}" \
    "${device_args[@]}" \
    "${runtime_args[@]}" \
    "${id_args[@]}" \
    --env-file "${env_file}" \
    -w "${RUNNER_CONTAINER_HOME}" \
    "${image}" \
    sh -c "${run_in_container}"
}

# runner_workdir_purge <dir> [image]
# Try host removal first. Use the runner image to delete protected entries
# when available. The unprivileged host user then removes the directory itself.
runner_workdir_purge() {
  local dir=$1 image=${2:-} cli
  rm -rf -- "${dir}" || :
  # Only mount a real directory with a safe volume source. Legacy temp paths
  # can contain characters that Docker interprets as volume spec separators.
  if [[ -d "${dir}" && ! -L "${dir}" && "${dir}" != *:* && -n "${image}" ]] &&
      cli=$(runner_container_cli); then
    "${cli}" run --rm --network none --user 0:0 --cap-drop=ALL \
      --cap-add=DAC_OVERRIDE --cap-add=FOWNER --security-opt no-new-privileges \
      -v "${dir}:/purge:Z" --entrypoint find "${image}" /purge -mindepth 1 -delete || :
    rm -rf -- "${dir}" || :
  fi
  if [[ -e "${dir}" || -L "${dir}" ]]; then
    printf 'purge: unable to remove work directory %q\n' "${dir}" >&2
  fi
  return 0
}

# runner_container_kill <name>
# Force-stop then remove a named container and log it -- the action a watchdog
# (#107) or operator takes against a hung job. `stop` first (graceful, then the
# engine SIGKILLs after its own grace), `rm -f` to be sure nothing lingers even
# if --rm did not fire. Best-effort: a failure of either step is logged, not
# fatal. Returns 0.
runner_container_kill() {
  local name=$1 cli
  cli=$(runner_container_cli) || {
    echo "watchdog: no container CLI to kill ${name}" >&2; return 0; }
  echo "watchdog: max lifetime exceeded, stopping+removing container ${name}" >&2
  "${cli}" stop "${name}" >/dev/null 2>&1 || true
  "${cli}" rm "${name}"   >/dev/null 2>&1 || true
  return 0
}

# runner_container_exists <name> -- true (0) if a container with this name is
# still present (running or not), via `ps -q --filter name=`. Used by the
# watchdog to decide whether the deadline actually caught a live job.
runner_container_exists() {
  local name=$1 cli out
  cli=$(runner_container_cli) || return 1
  out=$("${cli}" ps --all --quiet --filter "name=^${name}$" 2>/dev/null)
  [[ -n "${out}" ]]
}

# runner_container_watchdog <name> <timeout_secs>
# Bound a single container's wall-clock lifetime (#107): wait the timeout, then
# if the container is STILL present, stop+remove+log it (a hung job). If the job
# finished within the deadline (container gone) it is a no-op. timeout <= 0
# disables the watchdog (returns immediately). Meant to run in the background
# beside runner_container_run; the caller cancels it (a TERM) on normal
# completion so it never fires for a job that finished in time.
#
# The wait is a BACKGROUND sleep plus a TERM trap that kills it, so a single
# `kill` on this function's (subshell) pid cancels the timer cleanly -- no
# orphaned sleep left holding resources or an inherited fd. This avoids relying
# on `ps --ppid` / pkill, which BusyBox `ps` does not support.
runner_container_watchdog() {
  local name=$1 timeout=$2 sleep_pid=
  [[ "${timeout}" -gt 0 ]] 2>/dev/null || return 0
  # On cancellation, kill the pending sleep and exit without firing.
  trap '[[ -n "${sleep_pid}" ]] && kill "${sleep_pid}" 2>/dev/null; exit 0' TERM
  sleep "${timeout}" &
  sleep_pid=$!
  wait "${sleep_pid}" 2>/dev/null
  trap - TERM
  if runner_container_exists "${name}"; then
    runner_container_kill "${name}"
  fi
  return 0
}

# runner_container_run_bounded <dir> <encoded> <image> <job_id> [timeout]
# runner_container_run with a background watchdog (#107) keyed off the job's
# deterministic name. The watchdog enforces the per-job max lifetime (default
# RUNNER_JOB_MAX_LIFETIME); on normal completion it is killed so it never fires
# for an in-time job. PROPAGATES the in-container job's exit status. Requires a
# job id (the name the watchdog targets).
runner_container_run_bounded() {
  local dir=$1 encoded=$2 image=$3 job_id=$4 timeout=${5:-${RUNNER_JOB_MAX_LIFETIME}}
  [[ -n "${job_id}" ]] || { echo "FAIL: bounded run needs a job id" >&2; return 2; }

  local name wd_pid=
  name=$(runner_container_name "${job_id}")
  if [[ "${timeout}" -gt 0 ]] 2>/dev/null; then
    # Background the watchdog with its own stdin/stdout closed off the caller's
    # captured pipe, so cancelling it (below) does not leave `run`/the listener
    # blocked waiting on an inherited fd held open by its sleep child.
    runner_container_watchdog "${name}" "${timeout}" </dev/null >/dev/null 2>&1 &
    wd_pid=$!
  fi

  local rc=0
  runner_container_run "${dir}" "${encoded}" "${image}" "${job_id}" || rc=$?

  # Job finished (in time or by error): cancel the watchdog with a TERM, which
  # its trap turns into "kill the pending sleep and exit" -- no orphaned sleep
  # left holding resources or the inherited fd.
  if [[ -n "${wd_pid}" ]]; then
    kill -TERM "${wd_pid}" >/dev/null 2>&1 || true
    wait "${wd_pid}" 2>/dev/null || true
  fi
  return "${rc}"
}
