#!/usr/bin/env bats
# Static invariants of the runner-images workflow: the one workflow that
# publishes to ghcr.io. Its trigger set and its token scope are a supply-chain
# boundary, not a preference. A pull_request run that could push would let any
# PR branch overwrite the image every GPU host pulls; a packages:write token on
# a job that builds PR code hands that code the registry.
#
# Tripwires, like selfhosted_smoke_workflow.bats: each must fail the moment the
# property it guards is removed, so loosening one is a reviewed act.
# The CPU image needs its own smoke checks and provenance because it layers
# Docker plugins onto a runner whose version comes from its pinned base.

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

# Print a step only if all three patterns occur before the next step.
matching_step() {
  local job="$1"
  shift
  job_block "${job}" | awk -v first="$1" -v second="$2" -v third="$3" '
    function emit() {
      if (step ~ first && step ~ second && step ~ third) print step
    }
    /^      - / { emit(); step = "" }
    /^[[:space:]]*#/ { next }
    /^      - / || step != "" { step = step $0 "\n" }
    END { emit() }
  '
}

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

@test "runner-images builds through the repo's own script and Dockerfiles" {
  run grep -F 'images/build-runner-image.sh' "${WF}"
  [ "${status}" -eq 0 ]
  run grep -F 'images/runner-gpu.Dockerfile' "${WF}"
  [ "${status}" -eq 0 ]
  run grep -F 'images/runner-cpu.Dockerfile' "${WF}"
  [ "${status}" -eq 0 ]
}

@test "runner-images publishes the three named ghcr.io packages" {
  run grep -F 'ghcr.io/ycpss91255-lab/runner-base' "${WF}"
  [ "${status}" -eq 0 ]
  run grep -F 'ghcr.io/ycpss91255-lab/gpu-runner' "${WF}"
  [ "${status}" -eq 0 ]
  grep -Eq '^  CPU_IMAGE_NAME:[[:blank:]]+ghcr\.io/ycpss91255-lab/runner-cpu[[:blank:]]*$' "${WF}"
}

@test "the pull_request job builds the CPU image and runs both Docker plugin version commands in it" {
  run job_block build
  [ "${status}" -eq 0 ]
  grep -Fq 'images/runner-cpu.Dockerfile' <<<"${output}"
  grep -Eq 'docker run[[:blank:]].*(runner-cpu|CPU_IMAGE)[^;]*docker compose version([[:blank:]]|$)' <<<"${output}"
  grep -Eq 'docker run[[:blank:]].*(runner-cpu|CPU_IMAGE)[^;]*docker buildx version([[:blank:]]|$)' <<<"${output}"
}

@test "runner-cpu version commands in build and publish suppress runner logs on stdout" {
  # WHY: The upstream image enables stdout tracing, which adds log lines to
  # Runner.Listener --version output and breaks the publish version check.
  local command_pattern='/^[[:space:]]*#/ { next } /runner-cpu/ && /Runner[.]Listener --version/'
  local job
  for job in build publish; do
    if ! job_block "${job}" | awk "${command_pattern}" | grep -q .; then
      echo "${job} has no runner-cpu version command"
      return 1
    fi
  done

  awk "${command_pattern}" "${WF}" | awk '
    !/env -u ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT([[:space:]]|$)/ &&
    !/-e ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=([[:space:]]|$)/ {
      print "runner-cpu version command leaves stdout tracing enabled: " $0
      failed = 1
    }
    END { exit failed }
  '
}

@test "the build job checks that runner-cpu reports a three-part numeric version" {
  run job_block build
  [ "${status}" -eq 0 ]
  grep -Fq 'runner-cpu' <<<"${output}"
  grep -Fq '=~ ^[0-9]+\.[0-9]+\.[0-9]+$' <<<"${output}"
}

@test "the publish job builds the CPU image and reads its runner version in the same step" {
  run matching_step publish 'images/runner-cpu[.]Dockerfile' 'Runner[.]Listener --version' ''
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
}

@test "the publish job pushes the CPU image and records its digest" {
  run matching_step publish 'CPU_IMAGE_NAME' 'docker push[[:blank:]]' 'digest=.*|[.]outputs[.]digest'
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
}

@test "the publish job attests the CPU image digest" {
  run matching_step publish 'uses: actions/attest@' 'subject-name: .*env[.]CPU_IMAGE_NAME' 'subject-digest:'
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
}

@test "the publish job summary includes the CPU image and its digest" {
  run matching_step publish 'GITHUB_STEP_SUMMARY' 'CPU_IMAGE_NAME' 'CPU[A-Z_]*DIGEST|steps[.]cpu[.]outputs[.]digest'
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
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

@test "the pull_request job runs the Docker CLI and both plugin version commands in the GPU image" {
  run job_block build
  [ "${status}" -eq 0 ]
  grep -Eq 'docker run[[:blank:]].*gpu-runner[^;]*docker --version([[:blank:]]|$)' <<<"${output}"
  grep -Eq 'docker run[[:blank:]].*gpu-runner[^;]*docker compose version([[:blank:]]|$)' <<<"${output}"
  grep -Eq 'docker run[[:blank:]].*gpu-runner[^;]*docker buildx version([[:blank:]]|$)' <<<"${output}"
}

@test "the publish job smoke-tests the Docker CLI in the GPU image before pushing it" {
  run matching_step publish 'images/runner-gpu[.]Dockerfile' 'docker run[^\n]*docker --version' 'docker push[[:blank:]]'
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
  grep -Fq 'docker compose version' <<<"${output}"
  grep -Fq 'docker buildx version' <<<"${output}"
}

@test "the publish job summary includes the GPU image and its digest" {
  run matching_step publish 'GITHUB_STEP_SUMMARY' 'GPU_IMAGE_NAME' 'GPU_DIGEST|steps[.]gpu[.]outputs[.]digest'
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
}
