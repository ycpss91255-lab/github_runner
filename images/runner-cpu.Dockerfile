# CPU runner image (#122, ADR-0001 "Runner images").
#
# The digest-pinned upstream runner ships the Docker CLI without Compose.
# Install verified Compose and replace the bundled Buildx with a pinned release
# so CPU jobs can use both plugins through the Docker CLI.

# actions-runner 2.338.2
ARG RUNNER_IMAGE=ghcr.io/actions/actions-runner@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300
# hadolint ignore=DL3006
FROM ${RUNNER_IMAGE}

# To bump either plugin, download the new release's checksums.txt and copy
# the two Linux asset checksums below together with the new version.
ARG COMPOSE_VERSION=v5.7.1
ARG COMPOSE_SHA256_AMD64=af426722a8af5de812fcee30cc1c39f0639f5f723cbadefb25e5d4db054064cf
ARG COMPOSE_SHA256_ARM64=f2f49f903240895fa764c0dca3a14548b754ad9426f6b609ccaf55ec5a3aa2a5
ARG BUILDX_VERSION=v0.39.0
ARG BUILDX_SHA256_AMD64=5fb31a097304fbf6dd4038649a0decf32c2b9510e4047acd7d68b9d700c46194
ARG BUILDX_SHA256_ARM64=722cdcdfdd6f3fb943fa1ba75102d057feb18ba72aab93b1b0a8cf2b2b48a25f
ARG TARGETARCH

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN set -eu; \
    arch=${TARGETARCH:-$(dpkg --print-architecture)}; \
    case "${arch}" in \
      amd64) compose_arch=x86_64; compose_sha=${COMPOSE_SHA256_AMD64}; buildx_sha=${BUILDX_SHA256_AMD64} ;; \
      arm64) compose_arch=aarch64; compose_sha=${COMPOSE_SHA256_ARM64}; buildx_sha=${BUILDX_SHA256_ARM64} ;; \
      *) echo "Unsupported CPU runner architecture: ${arch}" >&2; exit 1 ;; \
    esac; \
    tmp=$(mktemp -d); \
    plugins=/usr/local/lib/docker/cli-plugins; \
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

LABEL org.opencontainers.image.title="github-runner (CPU)" \
      org.opencontainers.image.description="Upstream actions runner with pinned Docker Compose and Buildx plugins" \
      io.github.github-runner.compose-version="${COMPOSE_VERSION}" \
      io.github.github-runner.buildx-version="${BUILDX_VERSION}"

USER runner
