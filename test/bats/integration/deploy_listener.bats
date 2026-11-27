#!/usr/bin/env bats
# Integration spec for script/deploy-listener.sh -- the whole command driving
# lib/listener-deploy.sh, with every external it touches replaced by a scripted
# stub executable on a clean PATH.
#
# This is the level where the thing that matters is checked: a real run does
# each step, a SECOND run detects what is already in place and skips it, the
# confirmation gates the outward action, and the token never reaches an
# external command's argv. Nothing here starts a service, creates a user, or
# talks to GitHub: systemctl / journalctl / useradd / id / just and
# scaleset-admin are all stubs that record their argv.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/script/deploy-listener.sh"
  WORK=$(mktemp -d "${BATS_TEST_TMPDIR}/host.XXXXXX")
  STUB="${WORK}/stub"
  mkdir -p "${STUB}"
  # Every stubbed command appends its own name plus full argv here, one token
  # per line, so an exact argument can be grepped -- and so the token's ABSENCE
  # from every external argv can be asserted.
  CAP="${WORK}/argv.log"
  : > "${CAP}"

  PREFIX="${WORK}/opt"
  ETC="${WORK}/etc"
  CONFIG="${WORK}/runner-types.yaml"
  cat > "${CONFIG}" <<'YAML'
runner_types:
  - name: gpu
    scale_set: gpu-runners
    labels: [self-hosted, linux, gpu]
    image: ghcr.io/acme/r@sha256:abc
YAML

  # --- scripted stubs -----------------------------------------------------
  # State the stubs read so a test can say "the user already exists" or "the
  # unit is already active" and get the idempotent branch.
  export STUB_USER_EXISTS="${STUB_USER_EXISTS:-0}"
  export STUB_UNIT_ACTIVE="${STUB_UNIT_ACTIVE:-0}"
  export STUB_UNIT_ENABLED="${STUB_UNIT_ENABLED:-0}"
  # The stubbed journal is deterministic, so the verification retry loop has
  # nothing to wait for.
  export LISTENER_VERIFY_TRIES=2 LISTENER_VERIFY_INTERVAL=0

  _mkstub() {
    local name=$1 body=$2
    { printf '#!/usr/bin/env bash\n'
      printf 'printf "%%s\\n" "name=%s" "$@" >> "%s"\n' "${name}" "${CAP}"
      printf '%s\n' "${body}"
    } > "${STUB}/${name}"
    chmod +x "${STUB}/${name}"
  }

  _mkstub hostname 'printf "%s\n" "${STUB_HOSTNAME-host-a}"'
  _mkstub id 'if [ "$1" = -nG ]; then echo "ci-runner ${STUB_USER_GROUPS:-}"; exit 0; fi
if [ "${STUB_USER_EXISTS}" = 1 ]; then echo 999; exit 0; fi; exit 1'
  _mkstub useradd 'exit 0'
  # The host engine is rootful docker: a docker CLI on PATH and a docker group
  # that owns its socket. usermod / chown only record, so nothing on the test
  # host changes.
  export STUB_USER_GROUPS="${STUB_USER_GROUPS:-}"
  _mkstub docker 'exit 0'
  _mkstub getent '[ "$1 $2" = "group docker" ] && { echo "docker:x:998:"; exit 0; }; exit 2'
  _mkstub usermod 'exit 0'
  local real_install
  real_install=$(command -v install)
  _mkstub install "exec \"${real_install}\" \"\$@\""
  _mkstub chown 'exit 0'
  # A started unit becomes active, the way a real one does -- otherwise the
  # verification step could never pass and the test would be asserting against
  # a systemd that behaves like nothing else.
  _mkstub systemctl '
case "$1" in
  is-active)
    { [ "${STUB_UNIT_ACTIVE}" = 1 ] || [ -e "${STUB_STATE}/$2.started" ]; } \
      && { echo active; exit 0; }
    echo inactive; exit 3 ;;
  is-enabled)
    { [ "${STUB_UNIT_ENABLED}" = 1 ] || [ -e "${STUB_STATE}/$2.enabled" ]; } \
      && { echo enabled; exit 0; }
    echo disabled; exit 1 ;;
  enable) : > "${STUB_STATE}/$2.enabled"; exit 0 ;;
  disable) rm -f "${STUB_STATE}/$2.enabled"; exit 0 ;;
  start|restart) : > "${STUB_STATE}/$2.started"; exit 0 ;;
  stop) rm -f "${STUB_STATE}/$2.started"; exit 0 ;;
  *) exit 0 ;;
esac'
  # A journal that shows a listener which came up and is reporting capacity --
  # the success case; a test that wants the failure path overrides this.
  _mkstub journalctl '
echo "listener up: scale set \"gpu-runners\" (id=42), image=ghcr.io/acme/r@sha256:abc"
echo "level=INFO msg=\"capacity report\" event=capacity_report bound=4 in_flight=0 capacity=4"
exit 0'
  # `just` builds and installs; here it only records that it was asked to, and
  # lays down the files the verification step looks for.
  _mkstub just '
for a in "$@"; do
  case "$a" in
    install-listener)
      mkdir -p "${STUB_PREFIX}/bin"
      : > "${STUB_PREFIX}/bin/scaleset-listener"
      : > "${STUB_PREFIX}/bin/scaleset-admin"
      chmod +x "${STUB_PREFIX}/bin/scaleset-listener" "${STUB_PREFIX}/bin/scaleset-admin"
      ;;
    build-admin)
      # What the real recipe leaves behind: a scaleset-admin in the build
      # output directory. It is the same scripted stub the tests use elsewhere,
      # so a run that had to build one behaves like a run that found one.
      mkdir -p "${STUB_BIN_DIR}"
      cp "${STUB_ADMIN_SRC}" "${STUB_BIN_DIR}/scaleset-admin"
      chmod +x "${STUB_BIN_DIR}/scaleset-admin"
      ;;
  esac
done
exit 0'
  export STUB_PREFIX="${PREFIX}"
  # Where a build would land, kept out of the checkout's own bin/.
  export STUB_BIN_DIR="${WORK}/build"
  export STUB_STATE="${WORK}/state"
  mkdir -p "${STUB_STATE}"
  # Keep the unit out of the host's real systemd directory.
  export LISTENER_UNIT_DIR="${WORK}/systemd"

  # scaleset-admin: answers `show` from the fixture and records a `create`.
  export SCALESET_ADMIN_BIN="${STUB}/scaleset-admin-cmd"
  # The same file, under a name the `just` stub can copy from when a test drops
  # SCALESET_ADMIN_BIN to play a clean checkout.
  export STUB_ADMIN_SRC="${SCALESET_ADMIN_BIN}"
  cat > "${SCALESET_ADMIN_BIN}" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "name=scaleset-admin" "\$@" >> "${CAP}"
case "\${1:-}" in
  show)
    type=gpu
    while [ "\$#" -gt 0 ]; do
      case "\$1" in --type) type=\$2; shift ;; esac
      shift
    done
    printf '%s\n' "name=\${type}" "scale_set=\${type}-runners" "labels=self-hosted,linux,\${type}"
    echo 'image=ghcr.io/acme/r@sha256:abc'
    echo "runs_on=runs-on: [self-hosted, linux, \${type}]"
    ;;
  create)
    # The real command reads GITHUB_TOKEN from the environment and refuses
    # without it. Enforcing that here is what makes the ordering of the prompt
    # relative to the GitHub half observable.
    [ -n "\${GITHUB_TOKEN:-}" ] || { echo 'scaleset-admin: set GITHUB_CONFIG_URL and GITHUB_TOKEN' >&2; exit 1; }
    [ -n "\${GITHUB_CONFIG_URL:-}" ] || { echo 'scaleset-admin: set GITHUB_CONFIG_URL and GITHUB_TOKEN' >&2; exit 1; }
    if [ "\${STUB_SCALE_SET_EXISTS:-0}" = 1 ]; then
      echo 'scale set "gpu-runners" (id=42) already exists for runner type "gpu"; nothing changed'
    else
      echo 'created scale set "gpu-runners" (id=42) for runner type "gpu"'
    fi
    echo ''
    echo 'Paste into your workflow job:'
    echo ''
    echo '    runs-on: [self-hosted, linux, gpu]'
    ;;
  *) echo "stub: unexpected verb \${1:-}" >&2; exit 64 ;;
esac
STUBEOF
  chmod +x "${SCALESET_ADMIN_BIN}"

  # Clean PATH: only the stubs plus system bins, so no host systemctl / just
  # can leak into the run.
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${WORK}"; }

# Run the deploy non-interactively with --yes, feeding the token on stdin the
# way the interactive prompt reads it.
_deploy() {
  printf 'tok-abc123\n' | _deploy_host --type gpu "$@"
}

_deploy_host() {
  env -u RUNNER_TYPE -u GITHUB_TOKEN -u LISTENER_TOKEN "${SCRIPT}" --yes \
    --config "${CONFIG}" --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

_systemctl_called() {
  awk -v verb="$1" -v unit="${2-}" '
    $0 == "name=systemctl" {
      getline
      if ($0 == verb) {
        if (unit == "") found = 1
        else { getline; if ($0 == unit) found = 1 }
      }
    }
    END { exit !found }
  ' "${CAP}"
}

_seed_legacy() {
  local type=${1-gpu}
  mkdir -p "${ETC}" "${LISTENER_UNIT_DIR}" "${PREFIX}/runners/work"
  install -m 0600 /dev/null "${ETC}/scaleset-listener.env"
  printf 'RUNNER_TYPE=%s\nGITHUB_TOKEN=legacy-secret\n' "${type}" > "${ETC}/scaleset-listener.env"
  cp "${ROOT}/deploy/scaleset-listener.service" "${LISTENER_UNIT_DIR}/scaleset-listener.service"
  : > "${STUB_STATE}/scaleset-listener.service.started"
  : > "${STUB_STATE}/scaleset-listener.service.enabled"
}

# The same run on a CLEAN CHECKOUT: no SCALESET_ADMIN_BIN pointing at a
# prebuilt stub and nothing named scaleset-admin on PATH, which is the state a
# freshly cloned repository is actually in. The command has to end up with an
# admin tool by itself.
_deploy_clean_checkout() {
  printf 'tok-abc123\n' | env -u SCALESET_ADMIN_BIN -u GITHUB_TOKEN \
    LISTENER_BIN_DIR="${STUB_BIN_DIR}" "${SCRIPT}" --yes \
    --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

# The same run, but guaranteed to have no ambient GITHUB_TOKEN: the token must
# come from the prompt alone.
_deploy_env_free() {
  printf 'tok-abc123\n' | env -u GITHUB_TOKEN "${SCRIPT}" --yes \
    --config "${CONFIG}" --type gpu \
    --org-url https://github.com/acme \
    --prefix "${PREFIX}" --etc "${ETC}" "$@"
}

@test "a full run performs both halves and reports success" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"GitHub side"* ]]
  [[ "${output}" == *"Local side"* ]]
  # The GitHub half went through scaleset-admin create.
  grep -qxF 'create' "${CAP}"
  # The local half built/installed, made the user, and enabled + started.
  grep -qxF 'install-listener' "${CAP}"
  grep -qxF 'name=useradd' "${CAP}"
  grep -qxF 'enable' "${CAP}"
}

@test "a full run writes the environment file 0600 with the prompted token" {
  run _deploy
  [ "${status}" -eq 0 ]
  [ -f "${ETC}/gpu.env" ]
  [ "$(stat -c '%a' "${ETC}/gpu.env")" = "600" ]
  grep -qx 'GITHUB_TOKEN=tok-abc123' "${ETC}/gpu.env"
}

@test "the token never appears on any external command's argv" {
  # The whole point of prompting: /proc/<pid>/cmdline is world-readable, so a
  # token that reaches any exec'd command is a token any local user can read.
  run _deploy
  [ "${status}" -eq 0 ]
  ! grep -qF 'tok-abc123' "${CAP}" || false
}

@test "the token is never echoed to the terminal" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"tok-abc123"* ]]
}

@test "the run ends by printing the literal runs-on line for a test job" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"runs-on: [self-hosted, linux, gpu]"* ]]
  # And says the labels are what a workflow targets, not the scale set name.
  [[ "${output}" == *"label"* ]]
}

@test "the run verifies the listener actually came up and reports capacity" {
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"capacity"* ]]
  grep -A2 -xF 'name=journalctl' "${CAP}" | grep -qxF 'scaleset-listener@gpu.service'
}

@test "a listener that is active but never connected fails the run" {
  # Running-but-not-connected is the failure that a naive `systemctl is-active`
  # check reports as success.
  cat > "${STUB}/journalctl" <<'EOF'
#!/usr/bin/env bash
echo 'get scale set "gpu-runners": no scale set named "gpu-runners" exists'
exit 0
EOF
  chmod +x "${STUB}/journalctl"
  export STUB_UNIT_ACTIVE=1
  run _deploy
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"never reported"* ]] || [[ "${output}" == *"did not connect"* ]]
}

# --- idempotence -----------------------------------------------------------

@test "a second run skips the service user that already exists" {
  export STUB_USER_EXISTS=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already exists"* ]]
  ! grep -qxF 'name=useradd' "${CAP}"
}

@test "a second run backfills missing environment keys and preserves overrides" {
  local file="${ETC}/gpu.env"
  install -d -m 0755 "${ETC}"
  install -m 0600 /dev/null "${file}"
  printf '%s\n' 'GITHUB_TOKEN=already' 'REAP_SCRIPT=/custom/reap.sh' > "${file}"

  run _deploy
  [ "${status}" -eq 0 ]
  [ "$(stat -c '%a' "${file}")" = 600 ]
  [ "$(grep '^GITHUB_TOKEN=' "${file}")" = 'GITHUB_TOKEN=already' ]
  [ "$(grep '^REAP_SCRIPT=' "${file}")" = 'REAP_SCRIPT=/custom/reap.sh' ]
  local derived_owner
  derived_owner=$(grep '^SCALE_SET_OWNER=' "${file}")
  grep -qxF "RUNNER_HOME=${PREFIX}/runners/gpu" "${file}"
  grep -qxF "PROVISION_SCRIPT=${PREFIX}/listener/provision-job.sh" "${file}"
  grep -qxF "HOST_PROBE_CMD=${PREFIX}/listener/host-probe.sh" "${file}"

  sed -i 's/^SCALE_SET_OWNER=.*/SCALE_SET_OWNER=explicit-owner/' "${file}"
  export STUB_HOSTNAME=host-b
  run _deploy
  [ "${status}" -eq 0 ]
  [ "$(grep '^SCALE_SET_OWNER=' "${file}")" = 'SCALE_SET_OWNER=explicit-owner' ]
  [ "${derived_owner}" = 'SCALE_SET_OWNER=host-a' ]
}

@test "a second run skips enabling a unit that is already enabled" {
  export STUB_UNIT_ENABLED=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already enabled"* ]]
}

@test "a second run restarts an already-active unit rather than leaving it stale" {
  export STUB_UNIT_ACTIVE=1
  run _deploy
  [ "${status}" -eq 0 ]
  _systemctl_called restart scaleset-listener@gpu.service
}

@test "redeploy skips the current template, backfills runner home and restarts the instance" {
  run _deploy
  [ "${status}" -eq 0 ]
  sed -i '/^RUNNER_HOME=/d' "${ETC}/gpu.env"
  export STUB_USER_EXISTS=1 STUB_UNIT_ENABLED=1 STUB_UNIT_ACTIVE=1 STUB_SCALE_SET_EXISTS=1
  : > "${CAP}"
  run _deploy_host --type gpu </dev/null
  [ "${status}" -eq 0 ]
  ! grep -qxF 'name=useradd' "${CAP}"
  [[ "${output}" == *"already exists"* && "${output}" == *"already current, skipped"* ]]
  grep -qxF "RUNNER_HOME=${PREFIX}/runners/gpu" "${ETC}/gpu.env"
  grep -qxF 'GITHUB_TOKEN=tok-abc123' "${ETC}/gpu.env"
  ! grep -qxF "${LISTENER_UNIT_DIR}/scaleset-listener@.service" "${CAP}" || false
  _systemctl_called restart scaleset-listener@gpu.service
}

# --- one command means one command -----------------------------------------
# The command reads the runner-type config THROUGH scaleset-admin, so the tool
# is needed before every other step -- earlier than the local half that builds
# and installs it. On a clean checkout there is nothing built and nothing on
# PATH, and the command used to be unable to run at all.

@test "a run from a clean checkout builds the admin tool it needs, then deploys" {
  run _deploy_clean_checkout
  [ "${status}" -eq 0 ]
  # It asked for the build itself...
  grep -qxF 'build-admin' "${CAP}"
  [ -x "${STUB_BIN_DIR}/scaleset-admin" ]
  # ...and the rest of the run then happened as usual.
  grep -qxF 'create' "${CAP}"
  grep -qxF 'install-listener' "${CAP}"
  [[ "${output}" == *"Deployed."* ]]
}

@test "a dry run from a clean checkout writes only the build output: no token, no install, no GitHub" {
  # --dry-run keeps its promise even when it has to produce the tool first:
  # the build output directory is the ONE thing it may write, it never asks for
  # a token, and it reaches neither /etc nor GitHub.
  run bash -c "env -u SCALESET_ADMIN_BIN -u GITHUB_TOKEN \
    LISTENER_BIN_DIR='${STUB_BIN_DIR}' '${SCRIPT}' --dry-run \
    --config '${CONFIG}' --type gpu --org-url https://github.com/acme \
    --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 0 ]
  grep -qxF 'build-admin' "${CAP}"
  [ -x "${STUB_BIN_DIR}/scaleset-admin" ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  [ ! -d "${ETC}" ]
  [ ! -d "${PREFIX}" ]
}

# --- the GitHub half is announced and skippable ----------------------------

@test "an existing scale set is reported as a skip, not created again" {
  export STUB_SCALE_SET_EXISTS=1
  run _deploy
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"already exists"* ]]
  [[ "${output}" == *"nothing changed"* ]]
}

@test "--skip-github does the local half only and never invokes scaleset-admin create" {
  run _deploy --skip-github
  [ "${status}" -eq 0 ]
  ! grep -qxF 'create' "${CAP}"
  [[ "${output}" == *"Local side"* ]]
  # It still installs and starts the listener.
  grep -qxF 'install-listener' "${CAP}"
}

@test "the run announces what it will create on GitHub before creating it" {
  run _deploy
  [ "${status}" -eq 0 ]
  # The announcement names the scale set and the routing labels, and appears
  # before the create is reported.
  plan_line=$(printf '%s\n' "${output}" | grep -n 'gpu-runners' | head -1 | cut -d: -f1)
  made_line=$(printf '%s\n' "${output}" | grep -n 'created scale set' | head -1 | cut -d: -f1)
  [ -n "${plan_line}" ]
  [ -n "${made_line}" ]
  [ "${plan_line}" -lt "${made_line}" ]
}

# --- confirmation ----------------------------------------------------------
# The three branches of the confirmation itself (assumed-yes, refuse-unattended,
# and the interactive prompt's yes/no) are exercised against listener_confirm in
# test/bats/unit/listener_deploy.bats, where the TTY check is a seam and no pty
# is needed. What belongs here is that the whole command honours them.

@test "a non-interactive run without --yes refuses before touching anything" {
  run bash -c "'${SCRIPT}' --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 1 ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  [ ! -d "${ETC}" ]
}

@test "a dry run touches nothing at all, even with every stub available" {
  run bash -c "'${SCRIPT}' --dry-run --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 0 ]
  ! grep -qxF 'create' "${CAP}"
  ! grep -qxF 'name=useradd' "${CAP}"
  ! grep -qxF 'install-listener' "${CAP}"
  [ ! -d "${ETC}" ]
}

@test "the token is available to the GitHub half, which runs before the env file is written" {
  # The GitHub half needs the admin token, and it happens BEFORE the local half
  # writes the environment file -- so prompting for the token only at the env
  # file step would leave the create with nothing and fail every first-time
  # deploy on a host that had not already exported GITHUB_TOKEN.
  run _deploy_env_free
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"set GITHUB_CONFIG_URL and GITHUB_TOKEN"* ]]
  grep -qxF 'create' "${CAP}"
  # ...and it still never reached the child's argv.
  ! grep -qF 'tok-abc123' "${CAP}" || false
}

@test "one prompt serves both halves: the same token lands in the env file" {
  run _deploy_env_free
  [ "${status}" -eq 0 ]
  grep -qx 'GITHUB_TOKEN=tok-abc123' "${ETC}/gpu.env"
}

# --- engine access and the writable runner state ---------------------------

@test "a full run adds the service user to the docker group on a rootful docker host" {
  run _deploy
  [ "${status}" -eq 0 ]
  grep -qxF 'name=usermod' "${CAP}"
  grep -A3 -xF 'name=usermod' "${CAP}" | grep -qxF -- '-aG'
  grep -A3 -xF 'name=usermod' "${CAP}" | grep -qxF 'docker'
  grep -A3 -xF 'name=usermod' "${CAP}" | grep -qxF 'ci-runner'
}

@test "a second run skips a service user that is already in the docker group" {
  export STUB_USER_EXISTS=1 STUB_USER_GROUPS=docker
  run _deploy
  [ "${status}" -eq 0 ]
  ! grep -qxF 'name=usermod' "${CAP}" || false
  [[ "${output}" == *"already in the docker group"* ]]
}

@test "a full run creates the work root under the prefix and hands it to the service user" {
  run _deploy
  [ "${status}" -eq 0 ]
  [ -d "${PREFIX}/runners/gpu/work" ]
  local dir
  for dir in "${PREFIX}/runners" "${PREFIX}/runners/gpu" "${PREFIX}/runners/gpu/work"; do
    grep -A4 -xF 'name=chown' "${CAP}" | grep -qxF "${dir}"
  done
  grep -A4 -xF 'name=chown' "${CAP}" | grep -qxF 'ci-runner:ci-runner'
  ! grep -A4 -xF 'name=chown' "${CAP}" | grep -qxE -- '-R|--recursive' || false
}

@test "a dry run neither changes groups nor creates the work root" {
  run bash -c "'${SCRIPT}' --dry-run --config '${CONFIG}' --type gpu \
    --org-url https://github.com/acme --prefix '${PREFIX}' --etc '${ETC}'" </dev/null
  [ "${status}" -eq 0 ]
  ! grep -qxF 'name=usermod' "${CAP}" || false
  ! grep -qxF 'name=chown' "${CAP}" || false
  [ ! -d "${PREFIX}/runners" ]
}

@test "a rerun warns on stderr to rotate the token from a non-0600 environment file" {
  local file="${ETC}/gpu.env" token='existing-fixture-token'
  install -d -m 0755 "${ETC}"
  install -m 0644 /dev/null "${file}"
  printf 'GITHUB_TOKEN=%s\n' "${token}" > "${file}"

  _deploy > "${WORK}/stdout" 2> "${WORK}/stderr"
  [ "$(stat -c '%a' "${file}")" = 600 ]
  ! grep -qF "${token}" "${WORK}/stdout" "${WORK}/stderr" || false
  grep -qE 'WARNING.*0600' "${WORK}/stderr"
  grep -qiE 'token.*expos' "${WORK}/stderr"
  grep -qiF 'rotate' "${WORK}/stderr"
}

@test "gpu and cpu deploy independently on the same host using one template" {
  cat >> "${CONFIG}" <<'YAML'
  - name: cpu
    scale_set: cpu-runners
    labels: [self-hosted, linux, cpu]
    image: ghcr.io/acme/r@sha256:abc
YAML
  run _deploy --skip-github
  [ "${status}" -eq 0 ]
  cp "${ETC}/gpu.env" "${WORK}/gpu.before"
  _systemctl_called enable scaleset-listener@gpu.service
  _systemctl_called start scaleset-listener@gpu.service
  [ "$(grep -xcF "${LISTENER_UNIT_DIR}/scaleset-listener@.service" "${CAP}")" -eq 1 ]
  : > "${CAP}"

  run _deploy_host --type cpu --skip-github <<< 'cpu-fixture-token'
  [ "${status}" -eq 0 ]
  cmp "${WORK}/gpu.before" "${ETC}/gpu.env"
  local type file
  for type in gpu cpu; do
    file="${ETC}/${type}.env"
    [ "$(stat -c '%a' "${file}")" = 600 ]
    grep -qxF "RUNNER_TYPE=${type}" "${file}"
    grep -qxF "RUNNER_HOME=${PREFIX}/runners/${type}" "${file}"
    [ -d "${PREFIX}/runners/${type}/work" ]
  done
  cmp "${ROOT}/deploy/scaleset-listener@.service" "${LISTENER_UNIT_DIR}/scaleset-listener@.service"
  [ ! -e "${LISTENER_UNIT_DIR}/scaleset-listener.service" ]
  [ ! -e "${ETC}/scaleset-listener.env" ]
  ! grep -qxF "${LISTENER_UNIT_DIR}/scaleset-listener@.service" "${CAP}" || false
  ! grep -qxF 'scaleset-listener@gpu.service' "${CAP}" || false
  _systemctl_called enable scaleset-listener@cpu.service
  _systemctl_called start scaleset-listener@cpu.service
}

@test "deploy without --type uses the single type returned by scaleset-admin show" {
  run _deploy_host --skip-github <<< 'tok-abc123'
  [ "${status}" -eq 0 ]
  grep -qxF 'RUNNER_TYPE=gpu' "${ETC}/gpu.env"
  _systemctl_called start scaleset-listener@gpu.service
  [[ "${output}" == *"journalctl -u scaleset-listener@gpu.service -f"* ]]
  [[ "${output}" == *"./script/teardown-listener.sh --type gpu"* ]]
}

@test "deploy rejects an invalid type before installation or systemctl" {
  run _deploy_host --type GPU --skip-github <<< 'tok-abc123'
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL"* && "${output}" == *"GPU"* ]]
  ! grep -qxE 'install-listener|name=install|name=systemctl' "${CAP}" || false
  [ ! -e "${PREFIX}" ]
  [ ! -e "${ETC}" ]
  [ ! -e "${LISTENER_UNIT_DIR}" ]
}

@test "deploy migrates a matching legacy listener once and reuses its token" {
  _seed_legacy
  chmod 0644 "${ETC}/scaleset-listener.env"

  run _deploy_host --type gpu </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"migrated:"* && "${output}" == *"${PREFIX}/runners/work"* ]]
  [[ "${output}" != *"input hidden"* && "${output}" != *"legacy-secret"* ]]
  ! grep -qF 'legacy-secret' "${CAP}" || false
  _systemctl_called stop scaleset-listener.service
  _systemctl_called disable scaleset-listener.service
  _systemctl_called daemon-reload
  _systemctl_called start scaleset-listener@gpu.service
  [ ! -e "${LISTENER_UNIT_DIR}/scaleset-listener.service" ]
  [ ! -e "${ETC}/scaleset-listener.env" ]
  [ -d "${PREFIX}/runners/work" ]
  [ "$(stat -c '%a' "${ETC}/gpu.env")" = 600 ]
  grep -qxF 'GITHUB_TOKEN=legacy-secret' "${ETC}/gpu.env"
  grep -qxF 'RUNNER_TYPE=gpu' "${ETC}/gpu.env"
  grep -qxF "RUNNER_HOME=${PREFIX}/runners/gpu" "${ETC}/gpu.env"

  : > "${CAP}"
  run _deploy_host --type gpu </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"migrated:"* && "${output}" != *"input hidden"* ]]
  ! grep -qxF 'scaleset-listener.service' "${CAP}" || false
  ! grep -qF 'legacy-secret' "${CAP}" || false
  grep -qxF 'GITHUB_TOKEN=legacy-secret' "${ETC}/gpu.env"
}

@test "deploy keeps a legacy listener serving a different type" {
  _seed_legacy
  cp "${ETC}/scaleset-listener.env" "${WORK}/legacy.before"
  run _deploy_host --type cpu --skip-github <<< 'cpu-fixture-token'
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"NOTE"* && "${output}" == *"--type gpu"* ]]
  cmp "${WORK}/legacy.before" "${ETC}/scaleset-listener.env"
  cmp "${ROOT}/deploy/scaleset-listener.service" "${LISTENER_UNIT_DIR}/scaleset-listener.service"
  [ -e "${STUB_STATE}/scaleset-listener.service.started" ]
  [ -e "${STUB_STATE}/scaleset-listener.service.enabled" ]
  _systemctl_called start scaleset-listener@cpu.service
}

@test "deploy dry run previews legacy migration without changing the host" {
  _seed_legacy
  cp -a "${ETC}" "${WORK}/etc.before"
  cp -a "${LISTENER_UNIT_DIR}" "${WORK}/units.before"
  cp -a "${PREFIX}" "${WORK}/prefix.before"
  cp -a "${STUB_STATE}" "${WORK}/state.before"
  run _deploy_host --type gpu --dry-run </dev/null
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ [Mm]igrat ]]
  [[ "${output}" == *"${ETC}/gpu.env"* && "${output}" != *"legacy-secret"* ]]
  diff -r "${WORK}/etc.before" "${ETC}"
  diff -r "${WORK}/units.before" "${LISTENER_UNIT_DIR}"
  diff -r "${WORK}/prefix.before" "${PREFIX}"
  diff -r "${WORK}/state.before" "${STUB_STATE}"
  [ "$(stat -c '%a' "${ETC}/scaleset-listener.env")" = 600 ]
  ! grep -qxE 'create|install-listener|name=install|name=systemctl' "${CAP}" || false
}

@test "the shipped unit grants write access to exactly the runner home the deploy creates" {
  run _deploy --skip-github
  [ "${status}" -eq 0 ]
  local unit="${LISTENER_UNIT_DIR}/scaleset-listener@.service" runner_home
  grep -qxF 'ProtectSystem=strict' "${unit}"
  runner_home=$(sed -n 's/^RUNNER_HOME=//p' "${ETC}/gpu.env")
  [ -d "${runner_home}/work" ]
  [ "$(sed -n 's|^ReadWritePaths=/opt/github-runner-listener/||p' "${unit}")" = "runners/%i" ]
  [ "${runner_home#"${PREFIX}/"}" = 'runners/gpu' ]
  grep -qxF 'ExecStart=/opt/github-runner-listener/bin/scaleset-listener' "${unit}"
}

@test "deploy migrates a legacy env without RUNNER_TYPE when show resolves the only type" {
  _seed_legacy
  sed -i '/^RUNNER_TYPE=/d' "${ETC}/scaleset-listener.env"
  run _deploy_host --skip-github </dev/null
  [ "${status}" -eq 0 ]
  _systemctl_called stop scaleset-listener.service
  [ ! -e "${ETC}/scaleset-listener.env" ]
  grep -qxF 'RUNNER_TYPE=gpu' "${ETC}/gpu.env"
  grep -qxF 'GITHUB_TOKEN=legacy-secret' "${ETC}/gpu.env"
}

@test "migration keeps the existing per-type token when both env files exist" {
  _seed_legacy
  install -m 0600 /dev/null "${ETC}/gpu.env"
  printf 'GITHUB_TOKEN=instance-secret\n' > "${ETC}/gpu.env"
  run _deploy_host --type gpu </dev/null
  [ "${status}" -eq 0 ]
  _systemctl_called stop scaleset-listener.service
  _systemctl_called disable scaleset-listener.service
  [ ! -e "${ETC}/scaleset-listener.env" ]
  grep -qxF 'GITHUB_TOKEN=instance-secret' "${ETC}/gpu.env"
  ! grep -qE 'instance-secret|legacy-secret' "${CAP}" || false
  [[ "${output}" != *"instance-secret"* && "${output}" != *"legacy-secret"* ]]
}
