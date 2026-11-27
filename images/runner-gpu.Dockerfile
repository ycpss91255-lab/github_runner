# GPU / device runner image (#121, ADR-0001 "Runner images").
#
# Stock actions-runner images cannot run GPU jobs, so device runners need a
# self-built image carrying the CUDA/device stack. This image LAYERS that stack
# on the SEC-5 base (images/runner-base.Dockerfile) -- so the runner binary it
# runs is still the SEC-5-verified one (its tarball passed verify_runner_tarball
# before being baked into the base). The device stack is added on top.
#
# The CUDA runtime libraries are COPYed from a DIGEST-pinned nvidia/cuda image
# rather than apt-installed from the NVIDIA network repo, which keeps the build
# hermetic and reproducible (two pinned digests, no network) and lets CI build
# it AFK. Host GPU access is via precise --device passthrough + the nvidia
# runtime at run time (lib/runner-container.sh / provisioner), NOT --privileged
# (ADR-0001 "Hardware-runner residual").
#
# Docker CLI: GPU workflows build and run containers against the HOST daemon
# through the runner type's opt-in docker_socket mount. The image therefore
# ships the static docker CLI (client only -- no dockerd, no containerd) from
# download.docker.com, plus the same pinned Compose and Buildx plugins as the
# CPU image (the shared docker-cli-plugins block below). No docker group is
# baked in: the provisioner adds the socket's host GID with --group-add, so the
# runner user can use the mounted socket whatever GID the host gave it.
#
# Pinned by digest:
#   * RUNNER_BASE_IMAGE -- the SEC-5 base (build it first; pin its digest).
#   * CUDA_IMAGE        -- the nvidia/cuda runtime the device libs come from.
#
# AFK vs HITL: this image BUILDS and is wired into the gpu runner-type config
# AFK. A GPU job ACTUALLY EXECUTING needs a real NVIDIA host (driver + nvidia
# container runtime) -- an operator (HITL) step, not reproducible in CI.

# The SEC-5 base, built by images/build-runner-image.sh and pinned by digest.
# Bump by rebuilding the base and copying its new image id / digest.
ARG RUNNER_BASE_IMAGE=gh-runner-base:latest

# DIGEST-pinned CUDA image the device libraries are copied from. Matches the
# CUDA version init.sh probes (12.2.0-base-ubuntu22.04). Bump via:
#   docker buildx imagetools inspect nvidia/cuda:12.2.0-base-ubuntu22.04
ARG CUDA_IMAGE=nvidia/cuda@sha256:ecdf8549dd5f12609e365217a64dedde26ecda26da8f3ff3f82def6749f53051

# hadolint ignore=DL3006
FROM ${CUDA_IMAGE} AS cuda

# hadolint ignore=DL3006
FROM ${RUNNER_BASE_IMAGE}

ARG RUNNER_VERSION=unknown

# Device stack: the CUDA runtime libraries + the toolkit metadata, copied from
# the pinned nvidia/cuda image (hermetic; no NVIDIA apt repo at build time). The
# kernel driver is NOT in the image -- it is provided by the host and exposed at
# run time via --device + the nvidia container runtime.
USER root
COPY --from=cuda /usr/local/cuda /usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64

# Let the nvidia container runtime know what to expose (consumed by the runtime
# at run time on a real GPU host; inert otherwise).
ENV NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# BEGIN runner-tools -- shared by images/runner-cpu.Dockerfile and
# images/runner-gpu.Dockerfile; keep both copies byte-identical
# (test/bats/unit/runner_image_tools.bats checks it). Needs USER root.
#
# Baseline host tools. Jobs used to run on a full Ubuntu host, so workflows
# call these on the runner itself, outside any container (python3 for
# attestation and port helpers, ss for port probes, xz and unzip for
# archives). The list is pinned in runner_image_tools.bats and checked with
# command -v in every image the runner-images workflow builds. Packages are
# not version-pinned; the digest-pinned base is the reproducibility anchor.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git iproute2 jq python3 unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*
# END runner-tools

# Static docker CLI release. download.docker.com publishes no checksum file for
# the static tarballs, so the SHA-256s below were computed from the official
# download when the version was pinned. To bump: download
#   https://download.docker.com/linux/static/stable/{x86_64,aarch64}/docker-<ver>.tgz
# run sha256sum on both, and update all three ARGs together.
ARG DOCKER_VERSION=29.10.1
ARG DOCKER_SHA256_AMD64=061642059fa7f2ed9b2f04a327a951cff4249585cf04b2661c2a6539197c9962
ARG DOCKER_SHA256_ARM64=a38c8a9ef6d17bce07499bfd3a3688542274769dc3b4f75c06ea2705fe65053e
ARG TARGETARCH
RUN set -eu; \
    arch=${TARGETARCH:-$(dpkg --print-architecture)}; \
    case "${arch}" in \
      amd64) docker_arch=x86_64; docker_sha=${DOCKER_SHA256_AMD64} ;; \
      arm64) docker_arch=aarch64; docker_sha=${DOCKER_SHA256_ARM64} ;; \
      *) echo "Unsupported Docker CLI architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp}/docker.tgz" \
      "https://download.docker.com/linux/static/stable/${docker_arch}/docker-${DOCKER_VERSION}.tgz"; \
    echo "${docker_sha}  ${tmp}/docker.tgz" | sha256sum -c -; \
    tar -xzf "${tmp}/docker.tgz" -C "${tmp}" docker/docker; \
    install -m 0755 -o root -g root "${tmp}/docker/docker" /usr/local/bin/docker; \
    rm -rf "${tmp}"; \
    docker_version=$(docker --version); \
    [[ "${docker_version}" == "Docker version ${DOCKER_VERSION},"* ]] || { echo "Unexpected Docker CLI version: ${docker_version}" >&2; exit 1; }

# BEGIN docker-cli-plugins -- shared by images/runner-cpu.Dockerfile and
# images/runner-gpu.Dockerfile; keep both copies byte-identical
# (test/bats/unit/runner_image_dockerfiles.bats checks it). Needs the docker
# CLI on PATH, USER root and SHELL bash -o pipefail.
#
# To bump either plugin, download the new release's checksums.txt and copy
# the two Linux asset checksums below together with the new version.
ARG COMPOSE_VERSION=v5.7.1
ARG COMPOSE_SHA256_AMD64=af426722a8af5de812fcee30cc1c39f0639f5f723cbadefb25e5d4db054064cf
ARG COMPOSE_SHA256_ARM64=f2f49f903240895fa764c0dca3a14548b754ad9426f6b609ccaf55ec5a3aa2a5
ARG BUILDX_VERSION=v0.39.0
ARG BUILDX_SHA256_AMD64=5fb31a097304fbf6dd4038649a0decf32c2b9510e4047acd7d68b9d700c46194
ARG BUILDX_SHA256_ARM64=722cdcdfdd6f3fb943fa1ba75102d057feb18ba72aab93b1b0a8cf2b2b48a25f
ARG TARGETARCH
RUN set -eu; \
    arch=${TARGETARCH:-$(dpkg --print-architecture)}; \
    case "${arch}" in \
      amd64) compose_arch=x86_64; compose_sha=${COMPOSE_SHA256_AMD64}; buildx_sha=${BUILDX_SHA256_AMD64} ;; \
      arm64) compose_arch=aarch64; compose_sha=${COMPOSE_SHA256_ARM64}; buildx_sha=${BUILDX_SHA256_ARM64} ;; \
      *) echo "Unsupported Docker CLI plugin architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    plugins=/usr/local/lib/docker/cli-plugins; \
    install -d -m 0755 "${plugins}"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp}/docker-compose" \
      "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${compose_arch}"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp}/docker-buildx" \
      "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-${arch}"; \
    echo "${compose_sha}  ${tmp}/docker-compose" | sha256sum -c -; \
    echo "${buildx_sha}  ${tmp}/docker-buildx" | sha256sum -c -; \
    install -m 0755 -o root -g root "${tmp}/docker-compose" "${plugins}/docker-compose"; \
    install -m 0755 -o root -g root "${tmp}/docker-buildx" "${plugins}/docker-buildx"; \
    rm -rf "${tmp}"; \
    compose_version=$(docker compose version --short); \
    buildx_version=$(docker buildx version); \
    [[ "${compose_version}" == "${COMPOSE_VERSION#v}" ]] || { echo "Unexpected Compose version: ${compose_version}" >&2; exit 1; }; \
    [[ "${buildx_version}" == *"${BUILDX_VERSION}"* ]] || { echo "Unexpected Buildx version: ${buildx_version}" >&2; exit 1; }
# END docker-cli-plugins

USER runner

LABEL org.opencontainers.image.title="github-runner (GPU/device)" \
      org.opencontainers.image.description="SEC-5 base + CUDA device stack + Docker CLI with pinned Compose and Buildx for GPU jobs" \
      io.github.github-runner.runner-version="${RUNNER_VERSION}" \
      io.github.github-runner.docker-version="${DOCKER_VERSION}" \
      io.github.github-runner.compose-version="${COMPOSE_VERSION}" \
      io.github.github-runner.buildx-version="${BUILDX_VERSION}"
