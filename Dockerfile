# ghcr.io/coderpunch/h3xinfra-runner: the GitHub Actions runner image with
# Docker Engine, Compose and Buildx in the runner container. The container
# must be privileged. Run it only inside a VM sandbox, for example a Kata
# Containers pod, never with runc on a shared node (README.md).

# Renovate updates the tag and the digest (renovate.json). The release tags
# of this image start with this runner version (scripts/runner-version.sh).
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:6d0b2d80d80f143f77dcb676e50920100bbb547e39e883454d57f45ab8c31300

LABEL org.opencontainers.image.source="https://github.com/coderpunch/h3xinfra-runner" \
      org.opencontainers.image.description="GitHub Actions runner with Docker Engine, Compose and Buildx, for VM-isolated runner pods" \
      org.opencontainers.image.licenses="MIT"

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The Docker apt repository. docker.asc is the Docker release key;
# tests/test_repo.py checks its fingerprint. The pinned packages below are
# for Ubuntu 24.04 (noble), so stop if the base image moves to another release.
COPY docker.asc /etc/apt/keyrings/docker.asc
RUN . /etc/os-release \
    && test "$VERSION_CODENAME" = noble \
    && printf '%s\n' \
        'Types: deb' \
        'URIs: https://download.docker.com/linux/ubuntu' \
        'Suites: noble' \
        'Components: stable' \
        'Signed-By: /etc/apt/keyrings/docker.asc' \
        > /etc/apt/sources.list.d/docker.sources

# Docker Engine, CLI, containerd, Compose and Buildx: exact versions, which
# Renovate updates (deb datasource, renovate.json). dpkg replaces the older
# static Docker binaries of the base image in /usr/bin. Remove the two base
# files that no package replaces: docker-init (the package puts it in
# /usr/libexec/docker) and the Buildx plugin in /usr/local/lib/docker, which
# comes first in the plugin search path. docker-ce pulls in iptables and
# nftables. The other packages: libatomic1 (Node.js 26 links it), xz-utils and
# zstd (tar.xz downloads and the zstd cache compression of actions/cache),
# zip, and pigz (faster image layer decompression in dockerd).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        containerd.io=2.4.2-4~ubuntu.24.04~noble \
        docker-buildx-plugin=0.39.1-1~ubuntu.24.04~noble \
        docker-ce=5:29.10.1-1~ubuntu.24.04~noble \
        docker-ce-cli=5:29.10.1-1~ubuntu.24.04~noble \
        docker-compose-plugin=5.8.0-1~ubuntu.24.04~noble \
        libatomic1 \
        pigz \
        xz-utils \
        zip \
        zstd \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/bin/docker-init /usr/local/lib/docker/cli-plugins/docker-buildx

COPY --chmod=0755 bin/h3x-runner-entrypoint bin/h3x-dockerd /usr/local/bin/

# The runner user of the base image: uid 1001, in the groups sudo
# (passwordless sudo) and docker (access to /var/run/docker.sock).
USER runner

# Starts dockerd, then /home/runner/run.sh. A Kubernetes pod must give this
# path as the container command (README.md).
ENTRYPOINT ["/usr/local/bin/h3x-runner-entrypoint"]
