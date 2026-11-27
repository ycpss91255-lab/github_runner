#!/usr/bin/env bats
# The sample CPU image and the self-built images must agree on the runner
# release. GitHub stops dispatching jobs to stale runners with self-update
# disabled, so the operator examples and recovery guidance must stay in sync.
# These tripwires inspect the shipped files without Docker or the network.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  SAMPLE="${ROOT}/deploy/runner-types.sample.yaml"
  README="${ROOT}/deploy/README.md"
  CHANGELOG="${ROOT}/doc/changelog/CHANGELOG.md"
  CURRENT_VERSION="2.338.2"
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

@test "sample CPU image pins the current actions-runner digest" {
  image="$(cpu_image_with_previous_line | sed -n '2s/^    image: //p')"
  [ "${image}" = "ghcr.io/actions/actions-runner@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300" ]
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

@test "obsolete runner digest and version are absent from shipped files" {
  run grep -rIFn --exclude-dir=.git --exclude-dir=test --exclude-dir=coverage \
    --exclude=coverage.func --exclude='*_test.go' \
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
