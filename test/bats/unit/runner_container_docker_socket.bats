#!/usr/bin/env bats

setup() {
  export RUNNER_HOME="${BATS_TEST_TMPDIR}/runner-home"
  RUNNER_DIR="${RUNNER_HOME}/acme/_org"
  STUB="${BATS_TEST_TMPDIR}/bin"
  CAP="${BATS_TEST_TMPDIR}/cli.args"
  SOCKET="${BATS_TEST_TMPDIR}/docker.sock"
  mkdir -p "${RUNNER_DIR}" "${STUB}"
  touch "${SOCKET}"
  unset RUNNER_DOCKER_SOCKET
  source "${BATS_TEST_DIRNAME}/../../../lib/common.sh"

  make_cli() {
    cat >"${STUB}/$1" <<STUB_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "${CAP}"
STUB_EOF
    chmod +x "${STUB}/$1"
  }
  make_cli docker
  make_cli podman
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${RUNNER_HOME}" "${STUB}"; }

@test "runner_container_run omits the Docker socket and supplemental group by default" {
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- 'run' "${CAP}"
  ! grep -qF -- 'docker.sock' "${CAP}" || false
  ! grep -qxF -- '-v' "${CAP}" || false
  ! grep -qE -- '^--group-add(=|$)' "${CAP}"
}

@test "runner_container_run mounts the opted-in Docker socket and adds its host gid" {
  local gid
  gid=$(stat -c %g "${SOCKET}")
  export RUNNER_DOCKER_SOCKET="${SOCKET}"

  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -A1 -xF -- '-v' "${CAP}" | grep -qxF -- "${SOCKET}:${SOCKET}:Z"
  [ "$(grep -cE -- '^--group-add(=|$)' "${CAP}")" -eq 1 ]
  grep -A1 -xF -- '--group-add' "${CAP}" | grep -qxF -- "${gid}"
}

@test "runner_container_run adds the gid of the symlink target when the Docker socket path is a symlink" {
  export RUNNER_DOCKER_SOCKET="${BATS_TEST_TMPDIR}/linked.sock"
  ln -s "${SOCKET}" "${RUNNER_DOCKER_SOCKET}"

  # Model distinct link and target gids without requiring chgrp privileges.
  cat >"${STUB}/stat" <<'STUB_EOF'
#!/usr/bin/env bash
[[ "${!#}" == "${RUNNER_DOCKER_SOCKET}" && -L "${!#}" && -e "${!#}" ]] || exit 1
for arg in "$@"; do
  case "${arg}" in
    -L|--dereference) printf '%s\n' 4242; exit 0 ;;
  esac
done
printf '%s\n' 0
STUB_EOF
  chmod +x "${STUB}/stat"

  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -A1 -xF -- '-v' "${CAP}" | grep -qxF -- "${RUNNER_DOCKER_SOCKET}:${RUNNER_DOCKER_SOCKET}:Z"
  [ "$(grep -cE -- '^--group-add(=|$)' "${CAP}")" -eq 1 ]
  grep -A1 -xF -- '--group-add' "${CAP}" | grep -qxF -- '4242'
}

@test "runner_container_run preserves hardening with the Docker socket enabled" {
  export RUNNER_DOCKER_SOCKET="${SOCKET}"
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -eq 0 ]
  grep -qxF -- '--cap-drop=ALL' "${CAP}"
  grep -A1 -xF -- '--security-opt' "${CAP}" | grep -qxF -- 'no-new-privileges'
  grep -qxF -- '--pids-limit' "${CAP}"
  ! grep -qE -- '^--privileged(=|$)' "${CAP}" || false
  ! grep -qF -- 'seccomp=unconfined' "${CAP}" || false
  ! grep -qF -- 'label=disable' "${CAP}"
}

@test "runner_container_run rejects a missing Docker socket before invoking the CLI" {
  export RUNNER_DOCKER_SOCKET="${BATS_TEST_TMPDIR}/missing.sock"
  run runner_container_run "${RUNNER_DIR}" ENC my/image:tag
  [ "${status}" -ne 0 ]
  [[ "${output}" == FAIL:*"${RUNNER_DOCKER_SOCKET}"* ]]
  [ "${#lines[@]}" -eq 1 ]
  [ ! -s "${CAP}" ]
}
