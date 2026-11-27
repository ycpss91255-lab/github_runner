#!/usr/bin/env bats
# The baseline host tools every runner image must carry.
#
# Self-hosted jobs used to run on classic runners straight on a full Ubuntu
# dev host, so org workflows call host tools outside any container without
# saying so: omniverse_web_viewer's tier_b_visual_e2e.sh refuses to finish
# without python3, isaac's stream_visual_e2e.sh runs python3 ports.py and
# assert_pytest_baseline.sh parses JUnit XML with python3, isaac's
# stream_smoke_lib.sh probes ports with ss, and base's install-just.sh
# fetches with curl and unpacks with tar. On an ephemeral runner image a
# missing tool turns a passed test into a failed job.
#
# The list below is pinned here, installed by one shared apt block in both
# Dockerfiles, smoke-tested with `command -v` in every image the runner-images
# workflow builds, and listed in deploy/README.md. Dropping a tool from any of
# those is a red test.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
  CPU="${ROOT}/images/runner-cpu.Dockerfile"
  GPU="${ROOT}/images/runner-gpu.Dockerfile"
  WF="${ROOT}/.github/workflows/runner-images.yaml"
  README="${ROOT}/deploy/README.md"
  # The baseline, the same for the CPU and the GPU image.
  CPU_TOOLS="bash curl docker git gzip jq python3 sha256sum ss tar unzip xz"
  GPU_TOOLS="bash curl docker git gzip jq python3 sha256sum ss tar unzip xz"
}

# The shared tools block of one Dockerfile, markers included.
tools_block() {
  awk '
    /^# BEGIN runner-tools/ { inblock = 1 }
    inblock { print }
    /^# END runner-tools/ { exit }
  ' "$1"
}

# The text of one top-level workflow job, up to the next job key.
job_block() {
  awk -v job="$1" '
    $0 ~ "^  " job ":[[:space:]]*$" { injob = 1; print; next }
    injob && /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { exit }
    injob { print }
  ' "${WF}"
}

# The workflow-level RUNNER_TOOLS value.
workflow_tools() {
  sed -n '/^env:/,/^[a-z]/p' "${WF}" \
    | sed -n 's/^  RUNNER_TOOLS:[[:space:]]*//p' \
    | tr -d "'\""
}

@test "the CPU and GPU images pin the same baseline tool list" {
  [ "${CPU_TOOLS}" = "${GPU_TOOLS}" ]
  [[ " ${GPU_TOOLS} " == *" python3 "* ]]
}

@test "both Dockerfiles carry one shared, byte-identical runner-tools block" {
  local cpu_block gpu_block
  cpu_block="$(tools_block "${CPU}")"
  gpu_block="$(tools_block "${GPU}")"
  [ -n "${cpu_block}" ]
  grep -q '^# END runner-tools' <<<"${cpu_block}"
  [ "${cpu_block}" = "${gpu_block}" ]
}

@test "the runner-tools block apt-installs the package behind each baseline tool" {
  local block pkg
  block="$(tools_block "${GPU}" | sed '/^[[:space:]]*#/d')"
  grep -Eq 'apt-get install -y --no-install-recommends' <<<"${block}"
  grep -Fq 'rm -rf /var/lib/apt/lists/*' <<<"${block}"
  # bash, gzip, tar and sha256sum ship in every Ubuntu base; docker comes
  # from each image's own docker CLI install. The rest need these packages.
  for pkg in ca-certificates curl git iproute2 jq python3 unzip xz-utils; do
    grep -Eq "(^|[[:space:]])${pkg}([[:space:]]|\\\\|$)" <<<"${block}" \
      || { echo "runner-tools block does not install ${pkg}"; return 1; }
  done
}

@test "the runner-tools block runs as root before the final USER runner" {
  local f line_block line_root line_user
  for f in "${CPU}" "${GPU}"; do
    line_block="$(grep -n '^# BEGIN runner-tools' "${f}" | cut -d: -f1)"
    line_root="$(grep -n '^USER root' "${f}" | head -n 1 | cut -d: -f1)"
    line_user="$(grep -n '^USER ' "${f}" | tail -n 1 | cut -d: -f1)"
    [ -n "${line_block}" ]
    [ "${line_root}" -lt "${line_block}" ]
    [ "${line_block}" -lt "${line_user}" ]
    [ "$(sed -n "${line_user}p" "${f}")" = "USER runner" ]
  done
}

@test "the runner-images workflow pins the same baseline tool list" {
  [ "$(workflow_tools)" = "${GPU_TOOLS}" ]
}

@test "the build job smoke-tests every baseline tool in both built images" {
  local block
  block="$(job_block build | sed '/^[[:space:]]*#/d')"
  grep -Fq 'command -v' <<<"${block}"
  grep -Eq 'for img in gpu-runner:ci runner-cpu:ci' <<<"${block}"
  grep -Fq '${RUNNER_TOOLS}' <<<"${block}"
}

@test "the publish job checks the baseline tools in both images before pushing" {
  local block
  block="$(job_block publish | sed '/^[[:space:]]*#/d')"
  # Once for the gpu ref, once for runner-cpu:build, each before its push.
  [ "$(grep -c 'command -v' <<<"${block}")" -ge 2 ]
  [ "$(grep -cF '${RUNNER_TOOLS}' <<<"${block}")" -ge 2 ]
  awk '/check_tools "\$\{ref\}"/ { seen = 1 } /docker push "\$\{ref\}"/ && seen { ok = 1 } END { exit !ok }' <<<"${block}"
  awk '/check_tools runner-cpu:build/ { seen = 1 } /docker push "\$\{ref\}"/ && seen { ok = 1 } END { exit !ok }' <<<"${block}"
}

@test "deploy/README.md lists every baseline tool" {
  local line tool
  line="$(grep -F 'Baseline host tools' "${README}")"
  [ -n "${line}" ]
  for tool in ${GPU_TOOLS}; do
    grep -Fq "\`${tool}\`" "${README}" \
      || { echo "deploy/README.md does not list ${tool}"; return 1; }
  done
}
