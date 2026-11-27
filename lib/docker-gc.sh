#!/usr/bin/env bash
# Docker GC -- a CONSERVATIVE, CI-owned garbage collector for hosts whose jobs
# use the host Docker socket (runner types with `docker_socket`).
#
# Such jobs leave two kinds of residue the ephemeral --rm lifecycle cannot see:
#
#   * runner images pulled BY DIGEST. Every image bump pulls a new digest and
#     the old one stays behind untagged-but-referenced (so it is never
#     "dangling" and `docker image prune` does not take it), ~2.3G each.
#   * empty Compose networks such as github_runner_default, created by a job's
#     `docker compose up` and left behind when the job's container went away.
#
# The host is SHARED: other users run their own containers, images, volumes,
# buildx builders and even a GitLab runner on it. So this collector works from
# an allowlist and never from "everything not in use":
#
#   images   only from CI_REPOS below, only digest-only (untagged) pulls, only
#            when no RepoDigest belongs to another repository, the digest is
#            not referenced by any `image:` line in a runner-type config, no
#            container (running or stopped) was created from it, and it has no
#            com.gitlab.* label. Removal is by repo@digest, never forced.
#   networks only `<project>_default` where <project> is on the project list
#            (built-in: github_runner, the checkout-derived name of this repo;
#            plus --project, DOCKER_GC_PROJECTS and <etc>/docker-gc-projects),
#            labelled com.docker.compose.project=<project>, with no attached
#            container and no stopped container referencing it, no gitlab name
#            or label, and created more than the minimum age (24h) ago.
#
# It NEVER removes volumes, builder / build cache state, containers, or any
# image or network outside the rules above, and it never calls `prune`. The
# daemon builder cache and other users' images are out of scope: reclaiming
# them needs the host owner's approval.
#
# Dry run is the DEFAULT; --apply acts. Every decision to remove is one line
# (journald-friendly) carrying its own restore command.
# shellcheck shell=bash
# The docker --format templates below are Go templates, not shell expansions.
# shellcheck disable=SC2016

# The repositories CI owns. Deliberately a constant, not a knob: widening it is a
# code change that goes through review.
DOCKER_GC_CI_REPOS=(
  ghcr.io/ycpss91255-lab/runner-cpu
  ghcr.io/ycpss91255-lab/gpu-runner
  ghcr.io/ycpss91255-lab/runner-base
  ghcr.io/actions/actions-runner
)

# Compose projects whose `<project>_default` network CI may collect. The
# checkout of this repository is `github_runner`, so a job running
# `docker compose up` in it creates `github_runner_default`.
DOCKER_GC_BUILTIN_PROJECTS=(github_runner)

_docker_gc_log() { printf 'docker-gc: %s\n' "$*"; }
_docker_gc_err() { printf 'docker-gc: %s\n' "$*" >&2; }
_docker_gc_cli() { command "${DOCKER_GC_CLI}" "$@"; }

# _docker_gc_in <needle> <haystack...>: exact membership.
_docker_gc_in() {
  local needle=$1 item
  shift
  for item in "$@"; do
    [[ ${item} == "${needle}" ]] && return 0
  done
  return 1
}

# _docker_gc_config_files <etc> [explicit...]: every runner-type config this
# host may be using. The UNION is taken on purpose -- a config counted twice
# costs nothing, a config missed would let its pinned image be removed.
_docker_gc_config_files() {
  local etc=$1 f line
  shift
  local -a out=("$@")
  [[ -n ${RUNNER_TYPES_CONFIG:-} ]] && out+=("${RUNNER_TYPES_CONFIG}")
  for f in "${etc}"/runner-types*.yaml; do
    [[ -f ${f} ]] && out+=("${f}")
  done
  # The environment files hold the token, so only the one key is read; the
  # files are never sourced and their contents never printed.
  for f in "${etc}"/*.env; do
    [[ -f ${f} ]] || continue
    while IFS= read -r line; do
      line=${line#RUNNER_TYPES_CONFIG=}
      line=${line#\"}; line=${line%\"}
      [[ -n ${line} ]] && out+=("${line}")
    done < <(grep -E '^RUNNER_TYPES_CONFIG=' "${f}" 2>/dev/null)
  done
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}" | sort -u
  return 0
}

# _docker_gc_config_refs <file...>: every image reference on an `image:` line.
# A textual scan rather than the Go loader (ADR-0003 keeps the loader the only
# PARSER of the config): this is not interpreting the config, only building a
# keep-set, and a scan can only over-keep -- the fail-safe direction.
_docker_gc_config_refs() {
  local f
  for f in "$@"; do
    [[ -r ${f} ]] || continue
    sed -n -E "s/^[[:space:]]*(-[[:space:]]*)?image:[[:space:]]*[\"']?([^\"'[:space:]#]+).*/\\2/p" "${f}"
  done
}

# _docker_gc_epoch <docker timestamp>: seconds since the epoch, for the RFC 3339
# timestamps docker prints (2026-11-26T08:00:00.123456789+08:00 or ...Z). Done
# by hand rather than `date -d <ts>` because busybox date cannot parse those.
_docker_gc_epoch() {
  local ts=$1 base rest epoch offset=0
  base=${ts:0:19}
  rest=${ts:19}
  [[ ${base} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 1
  [[ ${rest} =~ ^(\.[0-9]+)?(Z|([+-])([0-9]{2}):?([0-9]{2}))$ ]] || return 1
  if [[ ${BASH_REMATCH[2]} != Z ]]; then
    offset=$(( 10#${BASH_REMATCH[4]} * 3600 + 10#${BASH_REMATCH[5]} * 60 ))
    [[ ${BASH_REMATCH[3]} == - ]] && offset=$(( -offset ))
  fi
  epoch=$(date -u -d "${base/T/ }" +%s 2>/dev/null) || return 1
  printf '%s\n' $(( epoch - offset ))
}

# _docker_gc_remove <kind> <target> <restore hint>: act (or say what would be
# done) and log exactly one line.
_docker_gc_remove() {
  local kind=$1 target=$2 restore=$3
  if (( ! DOCKER_GC_APPLY )); then
    _docker_gc_log "dry-run: would remove ${kind} ${target}; restore: ${restore}"
    return 0
  fi
  if _docker_gc_cli "${kind}" rm "${target}" >/dev/null 2>&1; then
    _docker_gc_log "removed ${kind} ${target}; restore: ${restore}"
  else
    _docker_gc_err "failed to remove ${kind} ${target}; left in place"
    DOCKER_GC_FAILED=$(( DOCKER_GC_FAILED + 1 ))
  fi
}

# _docker_gc_images <etc> [config...]: the image pass.
_docker_gc_images() {
  local etc=$1
  shift
  local -a configs=() refs=() used=() ids=() digests=() ctrs=()
  local id repo d tags labels foreign keep

  mapfile -t configs < <(_docker_gc_config_files "${etc}" "$@")
  (( ${#configs[@]} )) && mapfile -t refs < <(_docker_gc_config_refs "${configs[@]}")
  if (( ${#refs[@]} == 0 )); then
    # Without a keep-set every runner image would look unconfigured; refusing
    # is the only safe answer.
    _docker_gc_log "no configured runner image found (looked in ${etc}); skipping the image pass"
    return 0
  fi

  # A container list that cannot be read means "in use" is unknown, so the
  # pass stops rather than guessing.
  local out
  if ! out=$(_docker_gc_cli container ls -a -q --no-trunc); then
    _docker_gc_err "could not list containers; skipping the image pass"
    return 0
  fi
  mapfile -t ctrs < <(sed '/^[[:space:]]*$/d' <<< "${out}")
  if (( ${#ctrs[@]} )); then
    if ! out=$(_docker_gc_cli container inspect --format '{{.Image}}' "${ctrs[@]}"); then
      _docker_gc_err "could not inspect containers; skipping the image pass"
      return 0
    fi
    mapfile -t used <<< "${out}"
  fi

  for repo in "${DOCKER_GC_CI_REPOS[@]}"; do
    _docker_gc_cli image ls --no-trunc --format '{{.ID}}' "${repo}" 2>/dev/null
  done | sort -u > "${DOCKER_GC_TMP}/ids"
  mapfile -t ids < "${DOCKER_GC_TMP}/ids"

  for id in "${ids[@]}"; do
    [[ -n ${id} ]] || continue
    labels=$(_docker_gc_cli image inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{println}}{{end}}' "${id}" 2>/dev/null) \
      || { _docker_gc_log "keep image ${id} (inspect failed)"; continue; }
    if grep -q '^com\.gitlab' <<< "${labels}"; then
      _docker_gc_log "keep image ${id} (gitlab-labelled)"
      continue
    fi
    tags=$(_docker_gc_cli image inspect --format '{{range .RepoTags}}{{println .}}{{end}}' "${id}" 2>/dev/null) \
      || { _docker_gc_log "keep image ${id} (inspect failed)"; continue; }
    if [[ -n ${tags//[[:space:]]/} ]]; then
      _docker_gc_log "keep image ${id} (tagged)"
      continue
    fi
    mapfile -t digests < <(_docker_gc_cli image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${id}" 2>/dev/null | sed '/^[[:space:]]*$/d')
    (( ${#digests[@]} )) || continue
    foreign=0 keep=""
    for d in "${digests[@]}"; do
      _docker_gc_in "${d%@*}" "${DOCKER_GC_CI_REPOS[@]}" || foreign=1
      _docker_gc_in "${d}" "${refs[@]}" && keep="configured: ${d}"
    done
    if (( foreign )); then
      _docker_gc_log "keep image ${id} (also referenced outside the CI repositories)"
      continue
    fi
    if [[ -n ${keep} ]]; then
      _docker_gc_log "keep image ${id} (${keep})"
      continue
    fi
    if (( ${#used[@]} )) && _docker_gc_in "${id}" "${used[@]}"; then
      _docker_gc_log "keep image ${id} (in use by a container)"
      continue
    fi
    for d in "${digests[@]}"; do
      _docker_gc_remove image "${d}" "docker pull ${d}"
    done
  done
}

# _docker_gc_networks <etc> [project...]: the network pass.
_docker_gc_networks() {
  local etc=$1 name project labels attached users created epoch line
  shift
  local -a projects=("${DOCKER_GC_BUILTIN_PROJECTS[@]}" "$@") names=()
  local p
  for p in ${DOCKER_GC_PROJECTS:-}; do projects+=("${p}"); done
  if [[ -f ${etc}/docker-gc-projects ]]; then
    while IFS= read -r line; do
      line=${line%%#*}
      line=${line//[[:space:]]/}
      [[ -n ${line} ]] && projects+=("${line}")
    done < "${etc}/docker-gc-projects"
  fi

  local max_age=$(( DOCKER_GC_NETWORK_MIN_AGE_HOURS * 3600 ))
  local now=${DOCKER_GC_NOW:-$(date +%s)}

  mapfile -t names < <(_docker_gc_cli network ls --no-trunc --format '{{.Name}}' 2>/dev/null)
  for name in "${names[@]}"; do
    [[ ${name} == ?*_default ]] || continue
    project=${name%_default}
    [[ ${project} =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || continue
    _docker_gc_in "${project}" "${projects[@]}" || continue
    if [[ ${name} == *gitlab* ]]; then
      _docker_gc_log "keep network ${name} (gitlab name)"
      continue
    fi
    labels=$(_docker_gc_cli network inspect --format '{{range $k, $v := .Labels}}{{$k}}={{$v}}{{println}}{{end}}' "${name}" 2>/dev/null) \
      || { _docker_gc_log "keep network ${name} (inspect failed)"; continue; }
    if grep -q '^com\.gitlab' <<< "${labels}"; then
      _docker_gc_log "keep network ${name} (gitlab-labelled)"
      continue
    fi
    if ! grep -qxF "com.docker.compose.project=${project}" <<< "${labels}"; then
      _docker_gc_log "keep network ${name} (not a compose network of project ${project})"
      continue
    fi
    attached=$(_docker_gc_cli network inspect --format '{{len .Containers}}' "${name}" 2>/dev/null) || attached=x
    if [[ ${attached} != 0 ]]; then
      _docker_gc_log "keep network ${name} (containers attached)"
      continue
    fi
    # A STOPPED container keeps its endpoint config but is not in .Containers.
    users=$(_docker_gc_cli container ls -a -q --no-trunc --filter "network=${name}" 2>/dev/null) || users=x
    if [[ -n ${users} ]]; then
      _docker_gc_log "keep network ${name} (referenced by a container)"
      continue
    fi
    created=$(_docker_gc_cli network inspect --format '{{.Created}}' "${name}" 2>/dev/null) || created=""
    if ! epoch=$(_docker_gc_epoch "${created}"); then
      _docker_gc_log "keep network ${name} (creation time unknown)"
      continue
    fi
    if (( now - epoch < max_age )); then
      _docker_gc_log "keep network ${name} (younger than ${DOCKER_GC_NETWORK_MIN_AGE_HOURS}h)"
      continue
    fi
    _docker_gc_remove network "${name}" \
      "docker network create --label com.docker.compose.project=${project} --label com.docker.compose.network=default ${name} (docker compose up recreates it)"
  done
}

# docker_gc_run <etc> <configs-nameref> <projects-nameref>: one whole pass.
# Returns 1 when any removal failed (so the systemd unit shows it), else 0.
docker_gc_run() {
  local etc=$1
  local -n _gc_configs=$2 _gc_projects=$3
  DOCKER_GC_CLI=${DOCKER_GC_CLI:-docker}
  DOCKER_GC_APPLY=${DOCKER_GC_APPLY:-0}
  DOCKER_GC_NETWORK_MIN_AGE_HOURS=${DOCKER_GC_NETWORK_MIN_AGE_HOURS:-24}
  DOCKER_GC_FAILED=0

  if ! command -v "${DOCKER_GC_CLI}" >/dev/null 2>&1; then
    _docker_gc_log "no docker CLI (${DOCKER_GC_CLI}) on PATH; nothing to do"
    return 0
  fi
  DOCKER_GC_TMP=$(mktemp -d)

  if (( DOCKER_GC_APPLY )); then
    _docker_gc_log "mode=apply"
  else
    _docker_gc_log "mode=dry-run (pass --apply to remove)"
  fi
  _docker_gc_images "${etc}" "${_gc_configs[@]}"
  _docker_gc_networks "${etc}" "${_gc_projects[@]}"
  rm -rf -- "${DOCKER_GC_TMP}"
  _docker_gc_log "done (${DOCKER_GC_FAILED} failed)"
  (( DOCKER_GC_FAILED == 0 ))
}
