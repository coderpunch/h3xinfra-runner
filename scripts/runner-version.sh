#!/bin/bash
# Print the actions/runner version of the base image in the Dockerfile, for
# example 2.338.2. Each release tag of this image starts with it.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's|^FROM ghcr\.io/actions/actions-runner:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[0-9a-f]{64}$|\1|p' Dockerfile)
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "runner-version.sh: the Dockerfile needs one FROM ghcr.io/actions/actions-runner:X.Y.Z@sha256:<digest> line" >&2
    exit 1
fi
echo "$version"
