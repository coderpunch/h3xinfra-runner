#!/bin/bash
# Smoke test of the image on a computer with Docker, for example a
# GitHub-hosted runner. The container is privileged, as in the VM sandbox,
# and /var/lib/docker is a volume, as the emptyDir volume in the runner pod.
#
# Usage: tests/smoke.sh IMAGE
set -euo pipefail

image=${1:?usage: tests/smoke.sh IMAGE}
smoke_dir=$(cd "$(dirname "$0")/smoke" && pwd)

echo "== Checks inside the container (tests/smoke/inside.sh)"
docker run --rm --privileged \
    --mount type=volume,dst=/var/lib/docker \
    --mount type=volume,dst=/home/runner/_work \
    --mount "type=bind,src=$smoke_dir,dst=/smoke,readonly" \
    "$image" bash /smoke/inside.sh

echo "== Default command: the entrypoint starts dockerd, then run.sh"
# Without a runner configuration, run.sh stops with exit code 0 and a
# 'Not configured' message from the runner. The entrypoint starts run.sh
# only after dockerd answers.
if ! output=$(docker run --rm --privileged --mount type=volume,dst=/var/lib/docker "$image" 2>&1); then
    echo "$output"
    echo "FAIL the default command stopped with an error" >&2
    exit 1
fi
echo "$output"
if ! grep -qi 'not configured' <<< "$output"; then
    echo "FAIL run.sh did not start" >&2
    exit 1
fi
echo "PASS tests/smoke.sh $image"
