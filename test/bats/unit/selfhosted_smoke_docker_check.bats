#!/usr/bin/env bats
# Invariants of the opt-in Docker check in the self-hosted smoke workflow.
#
# The check proves a docker_socket runner type can reach the host daemon and
# that same-path bind mounts of the job checkout resolve. It must stay opt-in:
# a type without socket access is still a working runner, so the default
# dispatch must skip the step. And because the step drives the host daemon,
# the workflow must stay dispatch-only -- no trigger but workflow_dispatch.

setup() {
  WF="${BATS_TEST_DIRNAME}/../../../.github/workflows/selfhosted-smoke.yaml"
}

# Print the trigger block (`on:` up to the next top-level key).
_on_block() {
  sed -n '/^on:/,/^[a-z]/p' "${WF}" | sed '1d;$d'
}

# Print the `docker:` input definition (its line through the next input or
# the end of the inputs block).
_docker_input() {
  _on_block | awk '
    /^      docker:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^      [A-Za-z_]+:/ { exit }
    inside && /^ {0,5}[^ ]/ { exit }
    inside { print }
  '
}

@test "smoke workflow_dispatch is the only trigger" {
  run bash -c "sed -n '/^on:/,/^[a-z]/p' '${WF}' | sed '1d;\$d' | grep -E '^  [A-Za-z_]+:'"
  [ "${status}" -eq 0 ]
  [ "${output}" = "  workflow_dispatch:" ]
}

@test "smoke declares a docker dispatch input" {
  run _docker_input
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
}

@test "smoke docker input defaults to 'false'" {
  run _docker_input
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ default:[[:space:]]*\'false\' ]]
}

@test "smoke docker step is guarded by the docker input" {
  run grep -cE "^[[:space:]]+if:[[:space:]]*inputs\.docker[[:space:]]*==[[:space:]]*'true'[[:space:]]*$" "${WF}"
  [ "${status}" -eq 0 ]
  [ "${output}" -eq 1 ]
}

@test "smoke docker step proves same-path workspace mount, build, buildx and compose" {
  # The guarded step is the only one that calls docker run/build/compose.
  run bash -c "awk '/inputs\\.docker == .true./ { on = 1 } on' '${WF}'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'-v "${GITHUB_WORKSPACE}:${GITHUB_WORKSPACE}"'* ]]
  [[ "${output}" == *'-v "${RUNNER_TEMP}:/t"'* ]]
  [[ "${output}" == *'docker build '* ]]
  [[ "${output}" == *'docker compose version'* ]]
  [[ "${output}" == *'docker buildx version'* ]]
  [[ "${output}" == *'docker buildx build'*'--load'* ]]
  [[ "${output}" == *'./:/src'* ]]
  [[ "${output}" == *'docker compose -f'*'run --rm'* ]]
}
