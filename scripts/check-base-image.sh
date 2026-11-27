#!/bin/bash
# Verify that the base image of the Dockerfile (ghcr.io/actions/actions-runner)
# comes from actions/runner itself. Its digest must carry a GitHub artifact
# attestation (SLSA provenance) from actions/runner, signed on a GitHub-hosted
# runner by one of its two image workflows:
#   - .github/workflows/release.yml on a releases/mNNN branch (each release);
#   - .github/workflows/docker-publish.yml on main (a manual re-publish of a
#     release, as for 2.338.2 on 2026-11-11).
# The subject of the attestation is the multi-arch index digest, which the
# Dockerfile pins.
#
# Renovate merges base image updates itself (renovate.json). Its release-age
# check does not cover digest-only updates (a re-pushed tag), so this check
# is their only gate.
#
# Needs gh with any token (GH_TOKEN in CI, `gh auth login` on your computer).
# Network: api.github.com, ghcr.io and the Sigstore TUF repositories.
set -euo pipefail
cd "$(dirname "$0")/.."

digest=$(sed -nE 's|^FROM ghcr\.io/actions/actions-runner:[0-9.]+@(sha256:[0-9a-f]{64})$|\1|p' Dockerfile)
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "FAIL the Dockerfile does not pin ghcr.io/actions/actions-runner by tag and digest" >&2
    exit 1
fi

if ! gh attestation verify "oci://ghcr.io/actions/actions-runner@$digest" \
        --repo actions/runner \
        --cert-identity-regex '^https://github\.com/actions/runner/\.github/workflows/(release\.yml@refs/heads/releases/m[0-9]+|docker-publish\.yml@refs/heads/main)$' \
        --deny-self-hosted-runners; then
    echo "FAIL ghcr.io/actions/actions-runner@$digest: no attestation from the image workflows of actions/runner" >&2
    exit 1
fi
echo "ok   ghcr.io/actions/actions-runner@$digest: attestation from actions/runner"
