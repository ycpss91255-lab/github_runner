#!/usr/bin/env bats

setup() {
  export RUNNER_HOME="${BATS_TEST_TMPDIR}/home"
  export JOB_DIR="${RUNNER_HOME}/work/jit-job-abc.0123abcd"
  export CLI_ARGS="${BATS_TEST_TMPDIR}/cli.args"
  STUB="${BATS_TEST_TMPDIR}/bin"
  SOCKET="${BATS_TEST_TMPDIR}/docker.sock"
  mkdir -p "${JOB_DIR}" "${STUB}"
  touch "${SOCKET}"
  unset RUNNER_DOCKER_SOCKET RUNNER_PURGE_IMAGE
  export RUNNER_CONTAINER_HOME=/home/test-runner
  source "${BATS_TEST_DIRNAME}/../../../lib/common.sh"
  source "${BATS_TEST_DIRNAME}/../../../lib/runner-reaper.sh"

  cat > "${STUB}/podman" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${CLI_ARGS}"
if [[ "$*" == *'/purge:Z'* && -f "${JOB_DIR}/locked" ]]; then
  /bin/rm -- "${JOB_DIR}/locked"
fi
STUB
  chmod +x "${STUB}/podman"
  PATH="${STUB}:/bin:/usr/bin"
}

# Simulate an entry the host user cannot delete, even on root CI runners.
block_host_rm() {
  touch "${JOB_DIR}/locked"
  cat > "${STUB}/rm" <<'STUB'
#!/usr/bin/env bash
for arg; do
  if [[ "${arg}" == "${JOB_DIR}" && -f "${JOB_DIR}/locked" ]]; then
    exit 1
  fi
done
exec /bin/rm "$@"
STUB
  chmod +x "${STUB}/rm"
}

assert_job_run_layout() {
  local -a args
  local i mounts=0 workdir='' envfile=''
  mapfile -t args < "${CLI_ARGS}"
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
      -v)
        case "${args[i+1]}" in
          "${JOB_DIR}:${JOB_DIR}:Z") mounts=$((mounts + 1)) ;;
          "${SOCKET}:${SOCKET}:Z") [[ -n "${RUNNER_DOCKER_SOCKET}" ]] || return 1 ;;
          *) echo "unexpected mount: ${args[i+1]}"; return 1 ;;
        esac
        ;;
      -w) workdir="${args[i+1]}" ;;
      --env-file) envfile="${args[i+1]}" ;;
    esac
  done
  [ "${workdir}" = "${RUNNER_CONTAINER_HOME}" ]
  [ "${envfile}" = "${JOB_DIR}.jitconfig.env" ]
  [ "${mounts}" -eq "$1" ]
}

assert_purge_argv() {
  local -a expected=(
    run --rm --network none --user 0:0 --cap-drop=ALL
    --cap-add=DAC_OVERRIDE --cap-add=FOWNER --security-opt no-new-privileges
    -v "${JOB_DIR}:/purge:Z" --entrypoint
  )
  local -a actual
  local i
  mapfile -t actual < "${CLI_ARGS}"
  for ((i=0; i<${#expected[@]}; i++)); do
    [ "${actual[i]}" = "${expected[i]}" ] || return 1
  done
  # Both entrypoints are allowed. Match the complete remaining argv.
  local tail
  tail=$(printf '%s\n' "${actual[@]:i}")
  [[ "${tail}" == "$(printf '%s\n' rm "$1" -rf -- /purge/locked)" ||
     "${tail}" == "$(printf '%s\n' find "$1" /purge -mindepth 1 -delete)" ]]
}

@test "runner_container_run mounts the socket job workdir once at the same path" {
  export RUNNER_DOCKER_SOCKET="${SOCKET}"
  run runner_container_run "${JOB_DIR}" ENC job-image
  [ "${status}" -eq 0 ]
  assert_job_run_layout 1
}

@test "runner_container_run keeps the workdir and /tmp private with the socket off" {
  export RUNNER_DOCKER_SOCKET=''
  run runner_container_run "${JOB_DIR}" ENC job-image
  [ "${status}" -eq 0 ]
  assert_job_run_layout 0
}

@test "runner_workdir_purge removes the workdir with host rm alone" {
  touch "${JOB_DIR}/ordinary"
  declare -F runner_workdir_purge >/dev/null
  run runner_workdir_purge "${JOB_DIR}" job-image
  [ "${status}" -eq 0 ]
  [ ! -e "${JOB_DIR}" ]
  [ ! -e "${CLI_ARGS}" ]
}

@test "runner_workdir_purge retries host rm after an argv-only container purge" {
  block_host_rm
  declare -F runner_workdir_purge >/dev/null
  run runner_workdir_purge "${JOB_DIR}" job-image
  [ "${status}" -eq 0 ]
  assert_purge_argv job-image
  [ ! -e "${JOB_DIR}" ]
}

@test "runner_workdir_purge remains best effort with an empty image and skips the CLI" {
  block_host_rm
  declare -F runner_workdir_purge >/dev/null
  run runner_workdir_purge "${JOB_DIR}" ''
  [ "${status}" -eq 0 ]
  [ -f "${JOB_DIR}/locked" ]
  [ ! -e "${CLI_ARGS}" ]
}

@test "runner_prune_temp_dirs purges stale workdirs with RUNNER_PURGE_IMAGE and spares tracked jobs" {
  local tracked="${RUNNER_HOME}/work/jit-live.abcdef12"
  mkdir "${tracked}"
  touch "${tracked}/keep"
  block_host_rm
  export RUNNER_PURGE_IMAGE=prune-image

  run runner_prune_temp_dirs "${RUNNER_HOME}/work" live
  [ "${status}" -eq 0 ]
  [ -f "${tracked}/keep" ]
  [ -s "${CLI_ARGS}" ]
  assert_purge_argv prune-image
  [ ! -e "${JOB_DIR}" ]
}
