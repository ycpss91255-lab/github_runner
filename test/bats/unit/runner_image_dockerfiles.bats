#!/usr/bin/env bats
# Static invariants of the self-built runner-image Dockerfiles (#120 base, #121
# GPU). These guard the supply-chain + reproducibility promises WITHOUT building
# a real image (the actual `docker build` is exercised by the just/CI gate):
#   * the base bakes in the SEC-5-verified tarball from the build context and
#     NEVER downloads a runner tarball itself,
#   * every FROM is pinned by digest (no floating :latest baked in),
#   * the GPU image LAYERS on the SEC-5 base (so it inherits the verified
#     runner) and is NOT --privileged,
#   * the CPU image keeps the upstream runner pinned and installs only
#     versioned, checksum-verified Docker CLI plugins from their release repos.

setup() {
  IMAGES="${BATS_TEST_DIRNAME}/../../../images"
  BASE="${IMAGES}/runner-base.Dockerfile"
  GPU="${IMAGES}/runner-gpu.Dockerfile"
  CPU="${IMAGES}/runner-cpu.Dockerfile"
}

# Ignore Dockerfile comments when checking executable lines.
cpu_instructions() {
  [ -f "${CPU}" ] || return 1
  sed '/^[[:space:]]*#/d' "${CPU}"
}

@test "CPU Dockerfile builds from a digest-pinned upstream runner" {
  [ -f "${CPU}" ]
  grep -Eq '^ARG RUNNER_IMAGE=ghcr\.io/actions/actions-runner@sha256:[0-9a-f]{64}[[:space:]]*$' "${CPU}"
  grep -Eq '^FROM \$\{RUNNER_IMAGE\}[[:space:]]*$' "${CPU}"
}

@test "CPU Dockerfile pins compose and buildx to exact release versions" {
  local plugin
  for plugin in COMPOSE BUILDX; do
    run grep -E "^ARG ${plugin}_VERSION=" "${CPU}"
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^ARG\ ${plugin}_VERSION=v[0-9]+\.[0-9]+\.[0-9]+[[:blank:]]*$ ]]
  done
}

@test "CPU Dockerfile declares and checks per-architecture plugin checksums" {
  local arg
  for arg in COMPOSE_SHA256_AMD64 COMPOSE_SHA256_ARM64 BUILDX_SHA256_AMD64 BUILDX_SHA256_ARM64; do
    run grep -E "^ARG ${arg}=" "${CPU}"
    [ "${status}" -eq 0 ]
    [[ "${output}" =~ ^ARG\ ${arg}=[0-9a-f]{64}[[:blank:]]*$ ]]
  done
  run cpu_instructions
  [ "${status}" -eq 0 ]
  grep -Eq '(^|[[:space:]|&;])sha256sum[[:space:]]+-c([[:space:]]|$)' <<<"${output}"
}

@test "CPU Dockerfile uses only official plugin release URLs and never pipes into a shell" {
  local url
  run cpu_instructions
  [ "${status}" -eq 0 ]
  local instructions="${output}"
  run grep -E '\|[[:space:]]*([^[:space:]|;]+/)?(sh|bash)([[:space:];&|]|$)' <<<"${instructions}"
  [ "${status}" -eq 1 ]
  # Match an approved prefix or the scheme alone, so even two URLs in one
  # shell argument are independently checked.
  run grep -ioE 'https://github\.com/docker/(compose|buildx)/releases/download/|https?://' <<<"${instructions}"
  [ "${status}" -eq 0 ]
  for url in "${lines[@]}"; do
    case "${url}" in
      https://github.com/docker/compose/releases/download/*|https://github.com/docker/buildx/releases/download/*) ;;
      *) echo "unexpected CPU plugin URL: ${url}"; return 1 ;;
    esac
  done
  [[ "${output}" == *"https://github.com/docker/compose/releases/download/"* ]]
  [[ "${output}" == *"https://github.com/docker/buildx/releases/download/"* ]]
}

@test "CPU Dockerfile installs both Docker CLI plugins" {
  run cpu_instructions
  [ "${status}" -eq 0 ]
  local instructions="${output}"
  grep -qF '/usr/local/lib/docker/cli-plugins' <<<"${instructions}"
  grep -Eq '(install|cp|mv)[[:blank:]].*/docker-compose([^[:alnum:]_-]|$)' <<<"${instructions}"
  grep -Eq '(install|cp|mv)[[:blank:]].*/docker-buildx([^[:alnum:]_-]|$)' <<<"${instructions}"
}

@test "CPU Dockerfile ends as runner and never bakes in --privileged" {
  run cpu_instructions
  [ "${status}" -eq 0 ]
  local instructions="${output}"
  run grep -F -- '--privileged' <<<"${instructions}"
  [ "${status}" -eq 1 ]
  run bash -c 'grep -iE "^[[:blank:]]*USER[[:blank:]]" | tail -n 1' <<<"${instructions}"
  [[ "${output}" =~ ^[[:blank:]]*USER[[:blank:]]+runner[[:blank:]]*$ ]]
}

@test "base Dockerfile pins its base image by sha256 digest (#120)" {
  [ -f "${BASE}" ]
  run grep -E 'BASE_IMAGE=.*@sha256:[0-9a-f]{64}' "${BASE}"
  [ "${status}" -eq 0 ]
}

@test "base Dockerfile COPYs the verified tarball and never downloads one (#120)" {
  run grep -E 'COPY .*actions-runner\.tar\.gz' "${BASE}"
  [ "${status}" -eq 0 ]
  # The image build must NEVER fetch the runner tarball itself (that would
  # bypass the SEC-5 gate, which is the wrapper's job on the host). curl is a
  # legitimate runtime dep, so assert specifically that no runner release is
  # downloaded in the build.
  ! grep -Eiq 'github\.com/actions/runner|actions-runner-linux.*\.tar\.gz.*http' "${BASE}"
  ! grep -Eiq '(curl|wget)[^#]*actions-runner' "${BASE}"
}

@test "base Dockerfile runs the runner as a non-root user (#120)" {
  run grep -E '^USER runner' "${BASE}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile layers on the SEC-5 base image (#121)" {
  [ -f "${GPU}" ]
  run grep -E 'FROM \$\{RUNNER_BASE_IMAGE\}' "${GPU}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile pins the CUDA source image by sha256 digest (#121)" {
  run grep -E 'CUDA_IMAGE=.*@sha256:[0-9a-f]{64}' "${GPU}"
  [ "${status}" -eq 0 ]
}

@test "GPU Dockerfile never bakes in --privileged (#121, ADR-0001)" {
  # Ignore comment lines (the rationale text mentions the word); assert no
  # actual instruction bakes in --privileged.
  ! grep -vE '^[[:space:]]*#' "${GPU}" | grep -qF -- '--privileged'
}
