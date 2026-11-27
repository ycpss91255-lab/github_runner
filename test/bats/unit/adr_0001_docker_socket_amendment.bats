#!/usr/bin/env bats

setup() {
  ADR="${BATS_TEST_DIRNAME}/../../../doc/adr/0001-ephemeral-jit-runners.md"
}

@test "ADR-0001 records amended status for the Docker socket decision" {
  grep -qxF -- '- **Status**: Amended (2026-11-27, #116)' "${ADR}"
}

@test "ADR-0001 amendment documents Docker socket opt-in, host access, and fork PR approval" {
  local amendment
  grep -qE '^## Amendment \(#116\)([[:space:]]|$)' "${ADR}"
  amendment=$(awk '
    /^## Amendment \(#116\)([[:space:]]|$)/ { in_amendment = 1; next }
    /^## / && in_amendment { exit }
    in_amendment { print }
  ' "${ADR}" | tr '\n' ' ' | tr -s ' ' | tr -d '`*')

  grep -qwF 'docker_socket' <<<"${amendment}"
  grep -qiE 'root[- ]equivalent|equivalent to (host )?root' <<<"${amendment}"
  grep -qiE 'opt[- ]in|off by default|disabled by default' <<<"${amendment}"
  grep -qiE 'per[- ](runner[- ]?)?type|each runner type' <<<"${amendment}"
  grep -qiE 'fork.*(PRs?|pull requests?)|(PRs?|pull requests?).*fork' <<<"${amendment}"
  grep -qwF 'approval_policy=all_external_contributors' <<<"${amendment}"
}

@test "ADR-0001 qualifies the DinD guidance on mounting the host Docker socket" {
  local dind
  dind=$(awk '
    /^- \*\*DinD \/ image builds\*\*:/ { in_dind = 1; print; next }
    in_dind && !/^  / { exit }
    in_dind { print }
  ' "${ADR}" | tr '\n' ' ' | tr -s ' ')

  grep -qiE 'by default|amendment|#116|docker_socket|opt[- ]in' <<<"${dind}"
}
