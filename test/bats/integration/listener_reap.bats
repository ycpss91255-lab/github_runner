#!/usr/bin/env bats
# Smoke tests for listener/reap.sh -- the listener's orphan-sweep entrypoint
# (ADR-0001 lifecycle, #105/#106). The Go listener shells out to this script on
# startup and on its reap interval; it bridges the Go loop to the bash reaper
# seam (lib/runner-reaper.sh), removing labelled containers (#104) no longer
# tracked and pruning leaked per-job temp dirs under the work root. The
# container CLI (docker) is shadowed by a PATH stub; NO real engine is touched.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/listener/reap.sh"

  WORK=$(mktemp -d)
  export RUNNER_HOME="${WORK}/home"
  mkdir -p "${RUNNER_HOME}"
  export RUNNER_WORK_ROOT="${WORK}/work"
  mkdir -p "${RUNNER_WORK_ROOT}"

  STUB=$(mktemp -d)
  RM_CAP="${WORK}/rm.args"
  PURGE_CAP="${WORK}/purge.args"
  unset RUNNER_PURGE_IMAGE
  PS_OUT="${WORK}/ps.out"          # scripted `docker ps` inventory: one container ID per line
  INSPECT_DIR="${WORK}/inspect"    # per-id "<key>" inspect answers
  mkdir -p "${INSPECT_DIR}"
  : >"${PS_OUT}"
  # docker stub modelling the ID-keyed reaper (#137): `ps` lists container IDs,
  # `inspect` answers the job-id / managed-by label by ID, `rm` records targets.
  cat >"${STUB}/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) cat "${PS_OUT}" ;;
  inspect)
    fmt=""; id=""; shift
    while [ \$# -gt 0 ]; do
      case "\$1" in
        --format|-f) fmt="\$2"; shift 2 ;;
        --format=*) fmt="\${1#--format=}"; shift ;;
        *) id="\$1"; shift ;;
      esac
    done
    case "\$fmt" in
      *job-id*)     key=jobid ;;
      *managed-by*) key=managedby ;;
      *)            key=other ;;
    esac
    f="${INSPECT_DIR}/\${id}.\${key}"
    if [ -f "\$f" ]; then cat "\$f"; else exit 1; fi
    ;;
  rm) shift; printf '%s\n' "\$@" >> "${RM_CAP}" ;;
  run)
    printf '%s\n' "\$@" >> "${PURGE_CAP}"
    for arg in "\$@"; do
      case "\$arg" in
        "${RUNNER_WORK_ROOT}/jit-orphan.0123abcd:/purge:Z")
          /bin/rm -- "${RUNNER_WORK_ROOT}/jit-orphan.0123abcd/locked" ;;
      esac
    done
    ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  ln -s docker "${STUB}/podman"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() {
  hash -r
  /bin/rm -rf "${WORK}" "${STUB}"
}

# Register a container in the scripted inventory: inv <id> <job-id> [managed-by].
inv() {
  local id=$1 job_id=$2 managed_by=${3:-github-runner-listener}
  printf '%s\n' "${id}" >> "${PS_OUT}"
  printf '%s' "${job_id}"     > "${INSPECT_DIR}/${id}.jobid"
  printf '%s' "${managed_by}" > "${INSPECT_DIR}/${id}.managedby"
}

@test "reap.sh exists and is executable" {
  [ -x "${SCRIPT}" ]
}

@test "reap.sh removes an orphan container and prunes its stale temp dir (#105/#106)" {
  inv orphanid orphan
  mkdir -p "${RUNNER_WORK_ROOT}/jit-orphan.XYZ"
  run "${SCRIPT}"   # no tracked ids -> everything is an orphan
  [ "${status}" -eq 0 ]
  grep -qxF -- 'orphanid' "${RM_CAP}"
  [ ! -d "${RUNNER_WORK_ROOT}/jit-orphan.XYZ" ]
}

@test "reap.sh spares a tracked job's container and temp dir (#105/#106)" {
  inv liveid live
  mkdir -p "${RUNNER_WORK_ROOT}/jit-live.XYZ"
  run "${SCRIPT}" live
  [ "${status}" -eq 0 ]
  [ ! -f "${RM_CAP}" ]
  [ -d "${RUNNER_WORK_ROOT}/jit-live.XYZ" ]
}

# --- the prune root MUST match provision-job.sh's work root (#148) ----------

@test "reap.sh prunes stranded temp dirs under RUNNER_HOME/work in the DEFAULT config (RUNNER_WORK_ROOT unset, #148)" {
  # Regression for the two-halves divergence: provision-job.sh creates per-job
  # runner dirs under ${RUNNER_HOME}/work when RUNNER_WORK_ROOT is unset (#130),
  # but reap.sh historically defaulted its prune root to ${TMPDIR:-/tmp}, so a
  # crash-stranded dir under RUNNER_HOME/work was NEVER reaped -- the prune was a
  # silent no-op and the reaper reported success having cleaned nothing. With
  # RUNNER_WORK_ROOT unset, reap.sh MUST prune ${RUNNER_HOME}/work/jit-*.
  unset RUNNER_WORK_ROOT
  mkdir -p "${RUNNER_HOME}/work/jit-orphan.XYZ"
  run "${SCRIPT}"   # no tracked ids -> everything is an orphan
  [ "${status}" -eq 0 ]
  [ ! -d "${RUNNER_HOME}/work/jit-orphan.XYZ" ]
}

@test "reap.sh spares a tracked job's dir under RUNNER_HOME/work in the DEFAULT config (#148)" {
  # The same default-config root must still spare a live job's dir, so the fix
  # prunes the RIGHT root rather than blindly widening it.
  unset RUNNER_WORK_ROOT
  mkdir -p "${RUNNER_HOME}/work/jit-live.XYZ"
  run "${SCRIPT}" live
  [ "${status}" -eq 0 ]
  [ -d "${RUNNER_HOME}/work/jit-live.XYZ" ]
}

@test "reap.sh purges a stale socket workdir with protected entries and spares a tracked workdir" {
  local orphan="${RUNNER_WORK_ROOT}/jit-orphan.0123abcd"
  local tracked="${RUNNER_WORK_ROOT}/jit-live.abcdef12"
  mkdir "${orphan}" "${tracked}"
  touch "${orphan}/locked" "${tracked}/keep"
  cat > "${STUB}/rm" <<'STUB'
#!/usr/bin/env bash
orphan="${RUNNER_WORK_ROOT}/jit-orphan.0123abcd"
for arg; do
  if [[ "${arg}" == "${orphan}" && -f "${orphan}/locked" ]]; then
    exit 1
  fi
done
exec /bin/rm "$@"
STUB
  chmod +x "${STUB}/rm"
  export RUNNER_PURGE_IMAGE=socket-runner-image

  run "${SCRIPT}" live
  [ "${status}" -eq 0 ]
  [ -f "${tracked}/keep" ]
  [ ! -e "${orphan}" ]
  grep -qxF -- "${RUNNER_PURGE_IMAGE}" "${PURGE_CAP}"
  grep -qxF -- "${orphan}:/purge:Z" "${PURGE_CAP}"
  ! grep -qF -- "${tracked}" "${PURGE_CAP}"
}

@test "reap.sh removes stale JIT credential env files and spares a tracked job's file" {
  ( umask 077
    : >"${RUNNER_WORK_ROOT}/jit-orphan.0123abcd.jitconfig.env"
    : >"${RUNNER_WORK_ROOT}/jit-live.abcdef12.jitconfig.env" )
  run "${SCRIPT}" live
  [ "${status}" -eq 0 ]
  [ ! -e "${RUNNER_WORK_ROOT}/jit-orphan.0123abcd.jitconfig.env" ]
  [ -f "${RUNNER_WORK_ROOT}/jit-live.abcdef12.jitconfig.env" ]
}

@test "reap.sh removes stale JIT credential env files under RUNNER_HOME/work in the DEFAULT config" {
  unset RUNNER_WORK_ROOT
  mkdir -p "${RUNNER_HOME}/work"
  ( umask 077; : >"${RUNNER_HOME}/work/jit-orphan.XYZ.jitconfig.env"; )
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ ! -e "${RUNNER_HOME}/work/jit-orphan.XYZ.jitconfig.env" ]
}
