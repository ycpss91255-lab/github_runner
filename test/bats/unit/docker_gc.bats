#!/usr/bin/env bats
# Unit spec for listener/docker-gc.sh + lib/docker-gc.sh -- the CI-owned,
# conservative Docker garbage collector for hosts whose jobs use the host
# Docker socket.
#
# The docker CLI is a PATH stub backed by a scripted inventory under ${F}:
#
#   ${F}/img/<image-id>/{tags,digests,labels}   one entry per line
#   ${F}/ctr/<container-id>                     the image ID it was created from
#   ${F}/ctrnet/<container-id>                  networks it is attached to
#   ${F}/net/<name>/{created,labels,attached}   a network's inspect answers
#
# Every docker invocation is appended to ${F}/calls (one invocation per line),
# so a test can assert both what was removed and that nothing outside the GC's
# scope (volumes, builders, prune, container removal) was ever asked for. NO
# real container engine is touched.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SCRIPT="${ROOT}/listener/docker-gc.sh"
  F=$(mktemp -d "${BATS_TEST_TMPDIR}/gc.XXXXXX")
  STUB="${F}/stub"
  ETC="${F}/etc"
  mkdir -p "${STUB}" "${F}/img" "${F}/ctr" "${F}/ctrnet" "${F}/net" "${ETC}"
  : > "${F}/calls"

  CONFIG="${ETC}/runner-types.yaml"
  cat > "${CONFIG}" <<'YAML'
runner_types:
  - name: cpu
    scale_set: cpu-runners
    image: ghcr.io/ycpss91255-lab/runner-cpu@sha256:keep
  - name: gpu
    scale_set: gpu-runners
    image: "ghcr.io/ycpss91255-lab/gpu-runner@sha256:keepgpu"   # pinned
YAML

  # 2026-11-28T00:00:00Z, so network ages are deterministic.
  export DOCKER_GC_NOW=1795824000

  cat > "${STUB}/docker" <<EOF
#!/usr/bin/env bash
F="${F}"
printf '%s\n' "\$*" >> "\${F}/calls"
fmt=""; args=()
sub=\$1; shift
case "\${sub}" in image|container|network) obj=\${sub}; sub=\$1; shift ;; *) obj="" ;; esac
while [ \$# -gt 0 ]; do
  case "\$1" in
    --format|-f) fmt=\$2; shift 2 ;;
    --filter) filter=\$2; shift 2 ;;
    --type) obj=\$2; shift 2 ;;
    -*) shift ;;
    *) args+=("\$1"); shift ;;
  esac
done
case "\${obj}:\${sub}" in
  image:ls|:images)
    repo=\${args[0]:-}
    for d in "\${F}"/img/*; do
      [ -d "\$d" ] || continue
      if [ -z "\${repo}" ] || grep -qE "^\${repo}[@:]" "\$d/tags" "\$d/digests" 2>/dev/null; then
        basename "\$d"
      fi
    done ;;
  image:inspect)
    d="\${F}/img/\${args[0]}"
    [ -d "\$d" ] || exit 1
    case "\${fmt}" in
      *RepoTags*) cat "\$d/tags" ;;
      *RepoDigests*) cat "\$d/digests" ;;
      *Labels*) cat "\$d/labels" ;;
    esac ;;
  image:rm|:rmi)
    [ "\${STUB_RMI_FAIL:-}" = "\${args[0]}" ] && { echo "conflict" >&2; exit 1; }
    exit 0 ;;
  container:ls|:ps)
    for c in "\${F}"/ctr/*; do
      [ -f "\$c" ] || continue
      id=\$(basename "\$c")
      case "\${filter:-}" in
        network=*) grep -qxF "\${filter#network=}" "\${F}/ctrnet/\${id}" 2>/dev/null || continue ;;
      esac
      echo "\${id}"
    done ;;
  container:inspect|:inspect)
    for id in "\${args[@]}"; do cat "\${F}/ctr/\${id}"; done ;;
  network:ls)
    for d in "\${F}"/net/*; do [ -d "\$d" ] && basename "\$d"; done ;;
  network:inspect)
    d="\${F}/net/\${args[0]}"
    [ -d "\$d" ] || exit 1
    case "\${fmt}" in
      *Created*) cat "\$d/created" ;;
      *Containers*) cat "\$d/attached" ;;
      *Labels*) cat "\$d/labels" ;;
    esac ;;
  network:rm) exit 0 ;;
  *) exit 0 ;;
esac
exit 0
EOF
  chmod +x "${STUB}/docker"
  PATH="${STUB}:/bin:/usr/bin"
}

teardown() { rm -rf "${F}"; }

# img <id> <digests-csv> [tags-csv] [labels-csv]
img() {
  local d="${F}/img/$1"
  mkdir -p "${d}"
  tr ',' '\n' <<< "$2" | sed '/^$/d' > "${d}/digests"
  tr ',' '\n' <<< "${3-}" | sed '/^$/d' > "${d}/tags"
  tr ',' '\n' <<< "${4-}" | sed '/^$/d' > "${d}/labels"
}

# ctr <container-id> <image-id> [network...]
ctr() {
  local id=$1 image=$2
  shift 2
  printf '%s\n' "${image}" > "${F}/ctr/${id}"
  printf '%s\n' "$@" > "${F}/ctrnet/${id}"
}

# net <name> <created> <attached-count> [labels-csv]
net() {
  local d="${F}/net/$1"
  mkdir -p "${d}"
  printf '%s\n' "$2" > "${d}/created"
  printf '%s\n' "$3" > "${d}/attached"
  tr ',' '\n' <<< "${4-}" | sed '/^$/d' > "${d}/labels"
}

_gc() { "${SCRIPT}" --etc "${ETC}" "$@"; }

_removed() { grep -qxF "$1" "${F}/calls"; }

OLD=ghcr.io/ycpss91255-lab/runner-cpu@sha256:old
OLD_TS=2026-11-26T00:00:00Z
NEW_TS=2026-11-27T20:00:00Z
COMPOSE_LABEL=com.docker.compose.project=github_runner

@test "a run with no mode is a dry run that removes nothing" {
  img sha256:i-old "${OLD}"
  net github_runner_default "${OLD_TS}" 0 "${COMPOSE_LABEL}"
  run _gc
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"dry-run"* ]]
  [[ "${output}" == *"would remove image ${OLD}"* ]]
  [[ "${output}" == *"would remove network github_runner_default"* ]]
  ! grep -qE '^(image rm|rmi|network rm)' "${F}/calls" || false
}

@test "an image whose digest is in the runner-type config is kept" {
  img sha256:i-keep ghcr.io/ycpss91255-lab/runner-cpu@sha256:keep
  img sha256:i-gpu ghcr.io/ycpss91255-lab/gpu-runner@sha256:keepgpu
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
}

@test "an image used by a container, even a stopped one, is kept" {
  img sha256:i-old "${OLD}"
  ctr c1 sha256:i-old
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
  [[ "${output}" == *"in use"* ]]
}

@test "--apply removes an unconfigured, unused runner image and prints a restore hint" {
  img sha256:i-old "${OLD}"
  img sha256:i-base ghcr.io/ycpss91255-lab/runner-base@sha256:b1
  img sha256:i-up ghcr.io/actions/actions-runner@sha256:u1
  img sha256:i-gpu ghcr.io/ycpss91255-lab/gpu-runner@sha256:g1
  run _gc --apply
  [ "${status}" -eq 0 ]
  _removed "image rm ${OLD}"
  _removed "image rm ghcr.io/ycpss91255-lab/runner-base@sha256:b1"
  _removed "image rm ghcr.io/actions/actions-runner@sha256:u1"
  _removed "image rm ghcr.io/ycpss91255-lab/gpu-runner@sha256:g1"
  # One journald-friendly line per removal, carrying its own restore command.
  local line
  line=$(grep -F "removed image ${OLD}" <<< "${output}")
  [ "$(wc -l <<< "${line}")" -eq 1 ]
  [[ "${line}" == *"restore: docker pull ${OLD}"* ]]
}

@test "images from repositories the CI does not own are never touched" {
  img sha256:i-nuc nuc/dev@sha256:n1 nuc/dev:latest
  img sha256:i-isaac nvcr.io/nvidia/isaac-sim@sha256:s1
  img sha256:i-ros ros_dev_env@sha256:r1
  img sha256:i-other ghcr.io/ycpss91255-lab/something-else@sha256:x1
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
  [[ "${output}" != *"nuc/dev"* ]]
}

@test "an image also referenced by a non-CI repository is kept" {
  img sha256:i-shared "${OLD},bench-isaac@sha256:z9"
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
}

@test "a tagged runner image is kept; only digest-only pulls are collected" {
  img sha256:i-tag "${OLD}" ghcr.io/ycpss91255-lab/runner-cpu:latest
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
}

@test "gitlab-labelled objects are never touched, and volumes, builders and prune are never called" {
  img sha256:i-gl "${OLD}" "" com.gitlab.gitlab-runner.managed=true
  net github_runner_default "${OLD_TS}" 0 "${COMPOSE_LABEL},com.gitlab.gitlab-runner.job.id=7"
  net gitlab-runner_default "${OLD_TS}" 0 com.docker.compose.project=gitlab-runner
  run _gc --apply --project gitlab-runner
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi|network rm)' "${F}/calls" || false
  ! grep -qE '(^| )(volume|builder|buildx|prune|system)( |$)' "${F}/calls" || false
  ! grep -qE '^(container )?rm ' "${F}/calls" || false
}

@test "an empty github_runner_default older than 24h is removed on --apply" {
  net github_runner_default "${OLD_TS}" 0 "${COMPOSE_LABEL}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  _removed "network rm github_runner_default"
  [[ "${output}" == *"removed network github_runner_default"* ]]
  [[ "${output}" == *"restore:"* ]]
}

@test "a network offset in local time is aged correctly" {
  net github_runner_default "2026-11-26T08:00:00.123456789+08:00" 0 "${COMPOSE_LABEL}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  _removed "network rm github_runner_default"
}

@test "a network with an attached container is kept" {
  net github_runner_default "${OLD_TS}" 1 "${COMPOSE_LABEL}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -q '^network rm' "${F}/calls" || false
}

@test "a network a stopped container still references is kept" {
  net github_runner_default "${OLD_TS}" 0 "${COMPOSE_LABEL}"
  ctr c9 sha256:whatever github_runner_default
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -q '^network rm' "${F}/calls" || false
}

@test "a network younger than 24h is kept" {
  net github_runner_default "${NEW_TS}" 0 "${COMPOSE_LABEL}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -q '^network rm' "${F}/calls" || false
}

@test "a _default network of a project not on the list is kept" {
  net bench_default "${OLD_TS}" 0 com.docker.compose.project=bench
  net bridge "${OLD_TS}" 0
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -q '^network rm' "${F}/calls" || false
}

@test "a listed name without a matching compose project label is kept" {
  net github_runner_default "${OLD_TS}" 0 com.docker.compose.project=someone_else
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -q '^network rm' "${F}/calls" || false
}

@test "extra projects come from --project and the projects file" {
  net demo_default "${OLD_TS}" 0 com.docker.compose.project=demo
  net other_default "${OLD_TS}" 0 com.docker.compose.project=other
  printf '# recorded by jobs\nother\n' > "${ETC}/docker-gc-projects"
  run _gc --apply --project demo
  [ "${status}" -eq 0 ]
  _removed "network rm demo_default"
  _removed "network rm other_default"
}

@test "with no configured image the image pass refuses rather than removing everything" {
  rm -f "${CONFIG}"
  img sha256:i-old "${OLD}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  ! grep -qE '^(image rm|rmi)' "${F}/calls" || false
  [[ "${output}" == *"no configured runner image"* ]]
}

@test "a config named by RUNNER_TYPES_CONFIG in an env file is honoured" {
  mv "${CONFIG}" "${F}/elsewhere.yaml"
  printf 'GITHUB_TOKEN=secret\nRUNNER_TYPES_CONFIG=%s\n' "${F}/elsewhere.yaml" > "${ETC}/cpu.env"
  img sha256:i-keep ghcr.io/ycpss91255-lab/runner-cpu@sha256:keep
  img sha256:i-old "${OLD}"
  run _gc --apply
  [ "${status}" -eq 0 ]
  _removed "image rm ${OLD}"
  ! _removed "image rm ghcr.io/ycpss91255-lab/runner-cpu@sha256:keep" || false
  [[ "${output}" != *"secret"* ]]
}

@test "a failed removal is logged and the run exits non-zero" {
  img sha256:i-old "${OLD}"
  export STUB_RMI_FAIL="${OLD}"
  run _gc --apply
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"failed to remove image ${OLD}"* ]]
}

@test "no docker CLI is a clean skip" {
  run env DOCKER_GC_CLI=no-such-docker-cli "${SCRIPT}" --etc "${ETC}" --apply
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"no docker CLI"* ]]
  [ ! -s "${F}/calls" ]
}

@test "an unknown option is rejected" {
  run _gc --bogus
  [ "${status}" -eq 1 ]
}

@test "--help documents dry-run as the default and how to disable the timer" {
  run _gc --help
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"--apply"* ]]
  [[ "${output}" == *"systemctl disable --now scaleset-listener-gc.timer"* ]]
}

@test "the shipped timer runs daily and the service applies the GC" {
  local timer="${ROOT}/deploy/scaleset-listener-gc.timer"
  local svc="${ROOT}/deploy/scaleset-listener-gc.service"
  grep -qx 'OnCalendar=daily' "${timer}"
  grep -qx 'Persistent=true' "${timer}"
  grep -qx 'Type=oneshot' "${svc}"
  grep -qE '^ExecStart=/opt/github-runner-listener/listener/docker-gc.sh --apply' "${svc}"
}

@test "install-listener ships docker-gc.sh and lint covers it" {
  grep -qF 'listener/docker-gc.sh "{{DESTDIR}}{{PREFIX}}/listener/docker-gc.sh"' "${ROOT}/justfile"
  grep -E "^SCRIPTS :=" "${ROOT}/justfile" | grep -qF 'listener/docker-gc.sh'
  grep -E "^SCRIPTS :=" "${ROOT}/justfile" | grep -qF 'lib/docker-gc.sh'
}
