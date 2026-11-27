#!/usr/bin/env bats
# Integration spec for script/teardown-listener.sh -- the reversal of the local
# half of the deploy, driven over scripted stub executables on a clean PATH.
#
# Reversibility is a project requirement, so the removal path is exercised, not
# just its preview: the unit is stopped and disabled, the unit file, the
# environment file (which holds the admin token) and the install prefix are
# gone afterwards, a second run is a clean no-op, and the scale set on GitHub is
# never touched by any of it.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/teardown-listener.sh"
  WORK=$(mktemp -d "${BATS_TEST_TMPDIR}/host.XXXXXX")
  STUB="${WORK}/stub"
  mkdir -p "${STUB}"
  CAP="${WORK}/argv.log"
  : > "${CAP}"

  PREFIX="${WORK}/opt"
  ETC="${WORK}/etc"
  UNIT_DIR="${WORK}/systemd"
  export STUB_STATE="${WORK}/state"
  mkdir -p "${STUB_STATE}"

  # A deployed machine: prefix, env file at 0600, unit installed, unit running.
  mkdir -p "${PREFIX}/bin" "${ETC}" "${UNIT_DIR}"
  : > "${PREFIX}/bin/scaleset-listener"
  printf 'GITHUB_TOKEN=tok-abc123\n' > "${ETC}/scaleset-listener.env"
  chmod 600 "${ETC}/scaleset-listener.env"
  printf '[Service]\n' > "${UNIT_DIR}/scaleset-listener.service"
  : > "${STUB_STATE}/scaleset-listener.service.started"
  : > "${STUB_STATE}/scaleset-listener.service.enabled"

  cat > "${STUB}/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "name=systemctl" "$@" >> "${CAP_FILE}"
case "$1" in
  is-active)  [ -e "${STUB_STATE}/$2.started" ] && { echo active; exit 0; }; exit 3 ;;
  is-enabled) [ -e "${STUB_STATE}/$2.enabled" ] && { echo enabled; exit 0; }; exit 1 ;;
  stop)       rm -f "${STUB_STATE}/$2.started"; exit 0 ;;
  disable)    rm -f "${STUB_STATE}/$2.enabled"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${STUB}/systemctl"
  export CAP_FILE="${CAP}"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}"; }

_teardown_run() {
  "${SCRIPT}" --yes --prefix "${PREFIX}" --etc "${ETC}" --unit-dir "${UNIT_DIR}" "$@"
}

@test "a teardown removes the prefix, the env file and the unit" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  [ ! -d "${PREFIX}" ]
  [ ! -f "${ETC}/scaleset-listener.env" ]
  [ ! -f "${UNIT_DIR}/scaleset-listener.service" ]
}

@test "a teardown stops and disables the unit before removing it" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  grep -qxF 'stop' "${CAP}"
  grep -qxF 'disable' "${CAP}"
  grep -qxF 'daemon-reload' "${CAP}"
}

@test "the env file holding the token is actually gone, not just unreferenced" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  ! grep -rqF 'tok-abc123' "${ETC}" 2>/dev/null
}

@test "a second teardown is a clean no-op that still exits 0" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already absent"* ]]
}

@test "a teardown of a machine that was never deployed succeeds" {
  rm -rf "${PREFIX}" "${ETC}" "${UNIT_DIR}"
  rm -f "${STUB_STATE}/scaleset-listener.service.started" "${STUB_STATE}/scaleset-listener.service.enabled"
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"skipped"* ]]
}

@test "a teardown never invokes scaleset-admin, so the scale set cannot be touched" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  ! grep -qF 'scaleset-admin' "${CAP}"
  # And it says so, so the operator knows what is still out there.
  [[ "${output}" == *"scale set"* ]]
}

@test "the service user is left alone unless --remove-user names it" {
  run _teardown_run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"left in place"* ]]
}

@test "a prefix that is not a plausible install root is refused" {
  # The prefix is an rm -rf target, so it is checked lexically rather than
  # trusted because it arrived in a flag.
  run "${SCRIPT}" --yes --prefix / --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"refusing"* ]]
  run "${SCRIPT}" --yes --prefix /usr --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  run "${SCRIPT}" --yes --prefix relative/path --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"absolute"* ]]
  run "${SCRIPT}" --yes --prefix /opt/../etc --etc "${ETC}" --unit-dir "${UNIT_DIR}"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"normalized"* ]]
  # Nothing was removed by any of the refusals.
  [ -d "${PREFIX}" ]
}

_seed_instances() {
  local type
  printf '[Service]\n' > "${UNIT_DIR}/scaleset-listener@.service"
  for type in gpu cpu; do
    mkdir -p "${PREFIX}/runners/${type}/work"
    install -m 0600 /dev/null "${ETC}/${type}.env"
    printf 'RUNNER_TYPE=%s\nGITHUB_TOKEN=tok-%s\n' "${type}" "${type}" > "${ETC}/${type}.env"
    : > "${STUB_STATE}/scaleset-listener@${type}.service.started"
    : > "${STUB_STATE}/scaleset-listener@${type}.service.enabled"
  done
}

_assert_unit_stopped_and_disabled() {
  grep -A1 -xF 'stop' "${CAP}" | grep -qxF "$1"
  grep -A1 -xF 'disable' "${CAP}" | grep -qxF "$1"
}

@test "typed teardown leaves the other instance intact and removes shared files after the last type" {
  _seed_instances
  rm "${ETC}/scaleset-listener.env" "${UNIT_DIR}/scaleset-listener.service" \
    "${STUB_STATE}/scaleset-listener.service.started" "${STUB_STATE}/scaleset-listener.service.enabled"
  cp "${ETC}/gpu.env" "${WORK}/gpu.before"
  run _teardown_run --type cpu
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener@cpu.service
  [ ! -e "${ETC}/cpu.env" ]
  [ ! -e "${PREFIX}/runners/cpu" ]
  cmp "${WORK}/gpu.before" "${ETC}/gpu.env"
  [ -d "${PREFIX}/runners/gpu/work" ]
  [ -f "${PREFIX}/bin/scaleset-listener" ]
  [ -f "${UNIT_DIR}/scaleset-listener@.service" ]
  ! grep -qxF 'scaleset-listener@gpu.service' "${CAP}" || false

  : > "${CAP}"
  run _teardown_run --type gpu
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener@gpu.service
  grep -qxF 'daemon-reload' "${CAP}"
  [ ! -e "${ETC}/gpu.env" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener@.service" ]
  [ ! -e "${PREFIX}" ]
}

@test "whole-host teardown removes all instances together with legacy and shared files" {
  _seed_instances
  touch "${ETC}/runner-types-cpu.yaml" "${ETC}/runner-types-gpu.yaml"
  run _teardown_run
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener.service
  _assert_unit_stopped_and_disabled scaleset-listener@cpu.service
  _assert_unit_stopped_and_disabled scaleset-listener@gpu.service
  grep -qxF 'daemon-reload' "${CAP}"
  [ ! -e "${PREFIX}" ]
  [ ! -e "${ETC}/cpu.env" ]
  [ ! -e "${ETC}/gpu.env" ]
  [ ! -e "${ETC}/scaleset-listener.env" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener@.service" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener.service" ]
  [ ! -e "${ETC}/runner-types-cpu.yaml" ]
  [ ! -e "${ETC}/runner-types-gpu.yaml" ]
}

@test "typed teardown rejects unsafe and reserved names before touching the host" {
  _seed_instances
  local name
  for name in ../gpu work history scaleset-listener; do
    run _teardown_run --type "${name}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"FAIL"* && "${output}" == *"${name}"* ]]
    [ ! -s "${CAP}" ]
    [ -d "${PREFIX}/runners/gpu/work" ]
    [ -d "${PREFIX}/runners/cpu/work" ]
    [ -f "${ETC}/cpu.env" ]
    [ -f "${ETC}/gpu.env" ]
    [ -f "${ETC}/scaleset-listener.env" ]
    [ -f "${UNIT_DIR}/scaleset-listener@.service" ]
    [ -f "${UNIT_DIR}/scaleset-listener.service" ]
  done
}

@test "typed teardown keeps shared files for a legacy listener and removes it only for its type" {
  _seed_instances
  printf 'RUNNER_TYPE=gpu\n' >> "${ETC}/scaleset-listener.env"
  # CPU is the only template instance left, but the legacy GPU unit still runs.
  rm "${ETC}/gpu.env" "${STUB_STATE}/scaleset-listener@gpu.service.started" \
    "${STUB_STATE}/scaleset-listener@gpu.service.enabled"

  run _teardown_run --type cpu
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener@cpu.service
  [ -f "${ETC}/scaleset-listener.env" ]
  [ -f "${UNIT_DIR}/scaleset-listener.service" ]
  [ -f "${UNIT_DIR}/scaleset-listener@.service" ]
  [ -d "${PREFIX}" ]
  ! grep -qxF 'scaleset-listener.service' "${CAP}" || false

  : > "${CAP}"
  run _teardown_run --type gpu
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener.service
  [ ! -e "${ETC}/scaleset-listener.env" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener.service" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener@.service" ]
  [ ! -e "${PREFIX}" ]
}

@test "typed teardown resolves a legacy env without RUNNER_TYPE from its single-type config" {
  local config="${ETC}/runner-types.yaml"
  cat > "${config}" <<'YAML'
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, linux, gpu]
    image: ghcr.io/acme/r@sha256:abc
YAML
  printf 'RUNNER_TYPES_CONFIG=%s\n' "${config}" >> "${ETC}/scaleset-listener.env"
  cat > "${STUB}/scaleset-admin" <<'EOF'
#!/usr/bin/env bash
[[ $# -eq 3 && $1 == show && $2 == --config && $3 == "${STUB_LEGACY_CONFIG}" ]] || exit 64
printf '%s\n' 'name=gpu'
EOF
  chmod +x "${STUB}/scaleset-admin"
  export STUB_LEGACY_CONFIG="${config}" SCALESET_ADMIN_BIN="${STUB}/scaleset-admin"

  run _teardown_run --type cpu
  [ "${status}" -eq 0 ]
  [ -f "${ETC}/scaleset-listener.env" ]
  [ -f "${UNIT_DIR}/scaleset-listener.service" ]
  ! grep -qxF 'scaleset-listener.service' "${CAP}" || false

  run _teardown_run --type gpu
  [ "${status}" -eq 0 ]
  _assert_unit_stopped_and_disabled scaleset-listener.service
  [ ! -e "${ETC}/scaleset-listener.env" ]
  [ ! -e "${UNIT_DIR}/scaleset-listener.service" ]
}

@test "typed teardown removes only the selected generated runner-type config" {
  _seed_instances
  touch "${ETC}/runner-types-cpu.yaml" "${ETC}/runner-types-gpu.yaml" "${ETC}/runner-types.yaml"

  run _teardown_run --type cpu
  [ "${status}" -eq 0 ]
  [ ! -e "${ETC}/runner-types-cpu.yaml" ]
  [ -f "${ETC}/runner-types-gpu.yaml" ]
  [ -f "${ETC}/runner-types.yaml" ]
}

@test "typed teardown dry run previews removal of the selected generated config" {
  _seed_instances
  touch "${ETC}/runner-types-cpu.yaml" "${ETC}/runner-types-gpu.yaml"

  run _teardown_run --type cpu --dry-run
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"${ETC}/runner-types-cpu.yaml"* ]]
  [[ "${output}" != *"${ETC}/runner-types-gpu.yaml"* ]]
  [ -f "${ETC}/runner-types-cpu.yaml" ]
  [ -f "${ETC}/runner-types-gpu.yaml" ]
  [ ! -s "${CAP}" ]
}
