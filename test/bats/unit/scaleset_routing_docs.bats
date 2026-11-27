#!/usr/bin/env bats
# Executable spec for the ONE thing an operator of this project can most easily
# get wrong: what a workflow's `runs-on` actually targets.
#
# A workflow's runs-on is matched against the SCALE SET'S LABELS. The scale set
# NAME is only an identifier. The two coincide only when the scale set was
# created with its name as its single label -- which is the default when a
# runner type configures no labels, and is exactly why the name looks like the
# routing target when it is not. Getting this wrong costs hours: the job simply
# sits in `queued`, with no error anywhere. (The REST job status also stays
# `queued` after a job has been assigned to a scale set, so `queued` on its own
# is not evidence of a routing failure either.)
#
# Documentation that states this is therefore load-bearing, not decoration, so
# it is asserted rather than trusted. These tests check that the statement is
# present where an operator will meet it -- the deploy runbook, the listener
# README, and the config schema description -- and that the retracted claim
# (the name is the runs-on target) has not come back.

setup() {
  ROOT="${BATS_TEST_DIRNAME}/../../.."
}

@test "deploy/README.md states that workflows target the LABELS, not the name" {
  run grep -iE 'runs-on.*(match|target).*label|label.*(are|is).*routing' "${ROOT}/deploy/README.md"
  [ "${status}" -eq 0 ]
  run grep -iE 'name is only an identifier|name is an identifier' "${ROOT}/deploy/README.md"
  [ "${status}" -eq 0 ]
}

@test "listener/README.md states that workflows target the LABELS, not the name" {
  run grep -iE 'name is only an identifier|name is an identifier' "${ROOT}/listener/README.md"
  [ "${status}" -eq 0 ]
}

@test "the config schema description states which field is the routing key" {
  run grep -iE 'routing key|what runs-on matches' "${ROOT}/deploy/runner-types.sample.yaml"
  [ "${status}" -eq 0 ]
}

@test "no document still claims SCALE_SET_NAME is the runs-on target" {
  # The retracted claim, in the exact shape it was written.
  run grep -rF "the workflows' runs-on target" \
    "${ROOT}/listener" "${ROOT}/deploy" "${ROOT}/README.md"
  [ "${status}" -ne 0 ]
}

@test "the deploy runbook tells the operator how to create a scale set" {
  # The step that did not exist: the runbook said "fill in the scale set name"
  # with nothing that produced one.
  run grep -F 'scaleset-admin create' "${ROOT}/deploy/README.md"
  [ "${status}" -eq 0 ]
}

@test "the runbook documents deletion as its own explicit command" {
  run grep -F 'scaleset-admin delete' "${ROOT}/deploy/README.md"
  [ "${status}" -eq 0 ]
}

@test "the architecture overview shows the shared listener template" {
  run grep -F 'scaleset-listener@.service' "${ROOT}/doc/arch/overview.html"
  [ "${status}" -eq 0 ]
}

@test "the architecture overview shows per-type listener environment files" {
  run grep -F '&lt;type&gt;.env' "${ROOT}/doc/arch/overview.html"
  [ "${status}" -eq 0 ]
}

@test "the single-unit migration guide identifies the legacy history ledger" {
  local migration
  migration=$(sed -n '/^### Migrating a single-unit host$/,/^## /p' "${ROOT}/deploy/README.md")
  run grep -F 'runners/history' <<< "${migration}"
  [ "${status}" -eq 0 ]
}

@test "the fleet runbook exists and is linked from troubleshooting and the deploy README" {
  [ -f "${ROOT}/doc/runbook/FLEET.md" ]
  run grep -F '](FLEET.md)' "${ROOT}/doc/runbook/TROUBLESHOOTING.md"
  [ "${status}" -eq 0 ]
  run grep -F '](../doc/runbook/FLEET.md)' "${ROOT}/deploy/README.md"
  [ "${status}" -eq 0 ]
}

@test "the fleet runbook carries the restore log and the failover finding" {
  run grep -E '^## Restore log' "${ROOT}/doc/runbook/FLEET.md"
  [ "${status}" -eq 0 ]
  run grep -iF 'requeued' "${ROOT}/doc/runbook/FLEET.md"
  [ "${status}" -eq 0 ]
}
