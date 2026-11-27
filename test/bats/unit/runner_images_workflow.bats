#!/usr/bin/env bats
# Static invariants of the runner-images workflow: the one workflow that
# publishes to ghcr.io. Its trigger set and its token scope are a supply-chain
# boundary, not a preference. A pull_request run that could push would let any
# PR branch overwrite the image every GPU host pulls; a packages:write token on
# a job that builds PR code hands that code the registry.
#
# Tripwires, like selfhosted_smoke_workflow.bats: each must fail the moment the
# property it guards is removed, so loosening one is a reviewed act.

setup() {
  WF="${BATS_TEST_DIRNAME}/../../../.github/workflows/runner-images.yaml"
}

# The text of one top-level job: from its `  <name>:` line up to the next job
# key at the same indent (or EOF).
job_block() {
  awk -v job="$1" '
    $0 ~ "^  " job ":[[:space:]]*$" { injob = 1; print; next }
    injob && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { exit }
    injob { print }
  ' "${WF}"
}

# The trigger block only (`on:` up to the next top-level key), so a word in a
# step's prose cannot mask or fake a trigger.
on_block() { sed -n '/^on:/,/^[a-z]/p' "${WF}"; }

@test "the runner-images workflow exists" {
  [ -f "${WF}" ]
}

@test "runner-images declares workflow_dispatch with an optional runner_version input" {
  run bash -c "$(declare -f on_block); WF='${WF}'; on_block | grep -E '^[[:space:]]+workflow_dispatch:'"
  [ "${status}" -eq 0 ]
  run bash -c "$(declare -f on_block); WF='${WF}'; on_block | grep -E '^[[:space:]]+runner_version:'"
  [ "${status}" -eq 0 ]
  # Optional: a push run has no inputs at all, so the default must suffice.
  run bash -c "$(declare -f on_block); WF='${WF}'; on_block | grep -E 'required:[[:space:]]*true'"
  [ "${status}" -ne 0 ]
}

@test "runner-images publishes on pushes to main that change images/**" {
  run bash -c "$(declare -f on_block); WF='${WF}'; on_block | sed -n '/^  push:/,/^  [a-z_]*:/p'"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"main"* ]]
  [[ "${output}" == *"images/**"* ]]
}

@test "runner-images never uses pull_request_target" {
  run bash -c "$(declare -f on_block); WF='${WF}'; on_block | grep -E '^[[:space:]]+pull_request_target:'"
  [ "${status}" -ne 0 ]
}

@test "runner-images runs only on GitHub-hosted runners" {
  run grep -E '^[[:space:]]+runs-on:' "${WF}"
  [ "${status}" -eq 0 ]
  while IFS= read -r line; do
    [[ "${line}" =~ runs-on:[[:space:]]*ubuntu-latest[[:space:]]*$ ]] || {
      echo "not GitHub-hosted: ${line}"
      return 1
    }
  done <<<"${output}"
}

@test "runner-images pins every action by commit sha, never a tag" {
  [ -f "${WF}" ]
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ @[0-9a-f]{40}([[:space:]]|$) ]] || {
      echo "unpinned action: ${line}"
      return 1
    }
  done < <(grep -E '^[[:space:]]+(-[[:space:]]+)?uses:' "${WF}" || true)
}

@test "runner-images defaults the token to read-only contents" {
  run grep -E '^permissions:' "${WF}"
  [ "${status}" -eq 0 ]
  run bash -c "sed -n '/^permissions:/,/^[a-z]/p' '${WF}' | grep -E ':[[:space:]]*write'"
  [ "${status}" -ne 0 ]
}

@test "packages: write is granted exactly once, on the publish job" {
  run grep -cE '^[[:space:]]+packages:[[:space:]]*write' "${WF}"
  [ "${output}" -eq 1 ]
  run job_block publish
  [[ "${output}" =~ packages:[[:space:]]*write ]]
}

@test "the publish job never runs for a pull_request event" {
  run job_block publish
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"github.event_name != 'pull_request'"* ]]
}

@test "the pull_request build job neither logs in nor pushes" {
  run job_block build
  [ "${status}" -eq 0 ]
  [[ -n "${output}" ]]
  [[ "${output}" != *"docker login"* ]]
  [[ "${output}" != *"docker push"* ]]
  [[ "${output}" != *": write"* ]]
}

@test "runner-images builds through the repo's own script and Dockerfile" {
  run grep -F 'images/build-runner-image.sh' "${WF}"
  [ "${status}" -eq 0 ]
  run grep -F 'images/runner-gpu.Dockerfile' "${WF}"
  [ "${status}" -eq 0 ]
}

@test "runner-images publishes the two named ghcr.io packages" {
  run grep -F 'ghcr.io/ycpss91255-lab/runner-base' "${WF}"
  [ "${status}" -eq 0 ]
  run grep -F 'ghcr.io/ycpss91255-lab/gpu-runner' "${WF}"
  [ "${status}" -eq 0 ]
}

@test "runner-images labels the images with their source repository" {
  run grep -F 'org.opencontainers.image.source' "${WF}"
  [ "${status}" -eq 0 ]
}

@test "runner-images writes the pushed digests to the job summary" {
  run job_block publish
  [[ "${output}" == *'GITHUB_STEP_SUMMARY'* ]]
  [[ "${output}" == *'sha256'* || "${output}" == *'digest'* ]]
}

@test "the dispatch input reaches a shell only through env, never inline" {
  # `${{ inputs.x }}` inside a run: script is a script-injection vector; an
  # env: mapping is not.
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]+[A-Z_]+:[[:space:]]*\$\{\{[[:space:]]*inputs\. ]] || {
      echo "input used outside env: ${line}"
      return 1
    }
  done < <(grep -E '\$\{\{[[:space:]]*inputs\.' "${WF}" || true)
}

@test "runner-images bounds every job's runtime" {
  run grep -cE '^[[:space:]]+runs-on:' "${WF}"
  local jobs="${output}"
  run grep -cE '^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+' "${WF}"
  [ "${output}" -eq "${jobs}" ]
}
