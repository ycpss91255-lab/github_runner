#!/usr/bin/env bats
# The sample CPU image and the self-built images must agree on the runner
# release. GitHub stops dispatching jobs to stale runners with self-update
# disabled, so the operator examples and recovery guidance must stay in sync.
# The CPU plugin image keeps that same upstream pin, and the sample CPU type
# runs the published runner-cpu image (with Docker Compose) by digest.
# These tripwires inspect the shipped files without Docker or the network.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SAMPLE="${ROOT}/deploy/runner-types.sample.yaml"
  CPU="${ROOT}/images/runner-cpu.Dockerfile"
  README="${ROOT}/deploy/README.md"
  CHANGELOG="${ROOT}/doc/changelog/CHANGELOG.md"
  CURRENT_VERSION="2.338.2"
  STOCK_CPU_IMAGE="ghcr.io/actions/actions-runner@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300"
  PUBLISHED_CPU_IMAGE="ghcr.io/ycpss91255-lab/runner-cpu@sha256:15a5cc68b51769a21e35b641328a6a329a6a9f5533ca7eb42b7b47ba37749934"
  # gpu-runner 2.338.2 as published by the runner images workflow.
  PUBLISHED_GPU_IMAGE="ghcr.io/ycpss91255-lab/gpu-runner@sha256:2846d90a90e9e9bc7b4baecd856600445786d9bd2af63297ebd167910e467cd8"
}

# Print the CPU image and its immediately preceding line.
cpu_image_with_previous_line() {
  awk '
    /^  - name: / { cpu = ($0 == "  - name: cpu") }
    cpu && /^    image: / { print previous; print; exit }
    { previous = $0 }
  ' "${SAMPLE}"
}

fallback_version() {
  sed -nE 's/^readonly RUNNER_VERSION_FALLBACK="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' \
    "${ROOT}/lib/runner-release.sh"
}

@test "sample CPU image pins the published runner-cpu digest" {
  image="$(cpu_image_with_previous_line | sed -n '2s/^    image: //p')"
  [ "${image}" = "${PUBLISHED_CPU_IMAGE}" ]
}

@test "sample CPU type keeps the commented docker_socket opt-in" {
  run awk '
    /^  - name: / { cpu = ($0 == "  - name: cpu") }
    cpu && /^    # docker_socket: \/var\/run\/docker\.sock$/ { found = 1 }
    END { exit !found }
  ' "${SAMPLE}"
  [ "${status}" -eq 0 ]
}

@test "deployment README section 3b records the published CPU digest pin as done" {
  section="$(awk '
    /^## 3b\./ { section = 1; next }
    section && /^## / { exit }
    section { print }
  ' "${README}")"
  grep -qF "${PUBLISHED_CPU_IMAGE}" <<<"${section}"
  ! grep -qF 'uses the stock digest until' <<<"${section}"
}

@test "CPU Dockerfile defaults to the current stock actions-runner digest" {
  run sed -n 's/^ARG RUNNER_IMAGE=//p' "${CPU}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${STOCK_CPU_IMAGE}" ]
}

@test "CPU Dockerfile labels its upstream pin with the fallback runner version" {
  run awk '/^ARG RUNNER_IMAGE=/ { print previous } { previous = $0 }' "${CPU}"
  [ "${status}" -eq 0 ]
  [[ "${output}" =~ ^#\ actions-runner\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
  [ "${output}" = "# actions-runner $(fallback_version)" ]
}

@test "deployment README section 3b documents the CPU digest pin and compose plugin" {
  section="$(awk '
    /^## 3b\./ { section = 1; next }
    section && /^## / { exit }
    section { print }
  ' "${README}")"
  grep -qF 'ghcr.io/ycpss91255-lab/runner-cpu@sha256' <<<"${section}"
  grep -qF 'docker compose' <<<"${section}"
}

@test "Unreleased Added changelog records the CPU image and compose plugin" {
  added="$(awk '
    /^## \[Unreleased\][[:space:]]*$/ { unreleased = 1; next }
    unreleased && /^## / { exit }
    unreleased && /^### / { added = ($0 ~ /^### Added[[:space:]]*$/); next }
    added { print }
  ' "${CHANGELOG}")"
  grep -qF 'ghcr.io/ycpss91255-lab/runner-cpu' <<<"${added}"
  grep -iqw 'compose' <<<"${added}"
}

@test "CPU image is immediately preceded by an actions-runner version matching the fallback" {
  version="$(cpu_image_with_previous_line |
    sed -nE '1s/^[[:space:]]*# actions-runner ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*)?$/\1/p')"
  [ -n "${version}" ]
  [ "${version}" = "$(fallback_version)" ]
}

@test "runner release fallback pins the current runner version" {
  [ "$(fallback_version)" = "${CURRENT_VERSION}" ]
}

# The fleet restore log (doc/runbook/FLEET.md) is history: it names the old
# version because the backup files on the hosts carry it, so it is exempt.
@test "obsolete runner digest and version are absent from shipped files" {
  run grep -rIFn --exclude-dir=.git --exclude-dir=test --exclude-dir=coverage \
    --exclude=coverage.func --exclude='*_test.go' --exclude=FLEET.md \
    -e '08c30b0a7105f64bddfc485d2487a22aa03932a791402393352fdf674bda2c29' \
    -e '2.335.1' "${ROOT}"
  [ "${status}" -eq 1 ]
}

@test "deployment README version examples match the current fallback" {
  run grep -oE '(RUNNER_VERSION=|runner_version=|runner-base:|gpu-runner:)[0-9]+\.[0-9]+\.[0-9]+' "${README}"
  [ "${status}" -eq 0 ]
  fallback="$(fallback_version)"
  for example in "${lines[@]}"; do
    version="${example##*[=:]}"
    [ "${version}" = "${fallback}" ]
    [ "${version}" = "${CURRENT_VERSION}" ]
  done
}

@test "deployment README documents the stale runner dispatch symptom and cutoff" {
  grep -Eq '^#{1,6}[[:space:]]+.*Troubleshooting' "${README}"
  grep -qF 'Listening for Jobs' "${README}"
  grep -qF '30 days' "${README}"
}

@test "Unreleased Fixed changelog records the current runner and dispatch symptom" {
  fixed="$(awk '
    /^## \[Unreleased\][[:space:]]*$/ { unreleased = 1; next }
    unreleased && /^## \[/ { exit }
    unreleased && /^### / { fixed = ($0 ~ /^### Fixed[[:space:]]*$/); next }
    fixed { print }
  ' "${CHANGELOG}")"
  grep -qF "${CURRENT_VERSION}" <<< "${fixed}"
  grep -qF 'Listening for Jobs' <<< "${fixed}"
}

# The lines of the gpu entry in the sample, up to the next type.
gpu_entry() {
  awk '
    /^  - name: / { gpu = ($0 == "  - name: gpu") }
    gpu { print }
  ' "${SAMPLE}"
}

@test "sample GPU type shows the commented docker_socket opt-in with its root-equivalence note" {
  entry="$(gpu_entry)"
  grep -qE '^    # docker_socket: /var/run/docker\.sock$' <<<"${entry}"
  grep -qiE '^    #.*root-equivalent' <<<"${entry}"
  # Commented out: socket access stays off by default.
  ! grep -qE '^    docker_socket:' <<<"${entry}"
}

@test "sample GPU type does not route builds to kaniko (GPU jobs use the host daemon)" {
  entry="$(gpu_entry)"
  ! grep -qE '^    build_tool:' <<<"${entry}"
}

@test "deployment README section 3b documents the GPU Docker CLI and the post-publish pin step" {
  section="$(awk '
    /^## 3b\./ { section = 1; next }
    section && /^## / { exit }
    section { print }
  ' "${README}")"
  grep -qF 'docker --version' <<<"${section}"
  grep -qF 'download.docker.com' <<<"${section}"
  grep -qF -- '--group-add' <<<"${section}"
  grep -qiE 'after (the|each|a) .*publish.*gpu|gpu.*after (the|each|a) .*publish' <<<"${section}"
}

@test "Unreleased changelog records the GPU image Docker CLI" {
  unreleased="$(awk '
    /^## \[Unreleased\][[:space:]]*$/ { unreleased = 1; next }
    unreleased && /^## \[/ { exit }
    unreleased { print }
  ' "${CHANGELOG}")"
  grep -qF 'ghcr.io/ycpss91255-lab/gpu-runner' <<<"${unreleased}"
  grep -qF 'docker: command not found' <<<"${unreleased}"
}

# The gpu image line and its immediately preceding line.
gpu_image_with_previous_line() {
  awk '
    /^  - name: / { gpu = ($0 == "  - name: gpu") }
    gpu && /^    image: / { print previous; print; exit }
    { previous = $0 }
  ' "${SAMPLE}"
}

@test "sample GPU image pins the published gpu-runner digest" {
  image="$(gpu_image_with_previous_line | sed -n '2s/^    image: //p')"
  [ "${image}" = "${PUBLISHED_GPU_IMAGE}" ]
}

@test "GPU image is immediately preceded by an actions-runner version matching the fallback" {
  version="$(gpu_image_with_previous_line |
    sed -nE '1s/^[[:space:]]*# actions-runner ([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*)?$/\1/p')"
  [ "${version}" = "$(fallback_version)" ]
}

@test "sample no longer ships the placeholder gpu image" {
  run grep -F 'your-org/gpu-runner' "${SAMPLE}"
  [ "${status}" -eq 1 ]
}

# The fleet pattern in production: every host serves a scale set named after
# its type, in its own runner group, with identical labels.
@test "sample types use the fleet scale set names with a commented per-host runner_group" {
  for type in gpu cpu; do
    entry="$(awk -v t="  - name: ${type}" '
      /^  - name: / { on = ($0 == t) }
      on { print }
    ' "${SAMPLE}")"
    grep -qxF "    scale_set: ${type}" <<<"${entry}"
    grep -qxF '    # runner_group: ci-<host>' <<<"${entry}"
  done
}
