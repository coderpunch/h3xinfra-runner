#!/bin/bash
# Print the next release tag, <runner version>-<n>, for example 2.338.2-3.
# n is 1 more than the highest n of the current runner version.
#
# Usage: gh release list --limit 1000 --json tagName --jq '.[].tagName' | scripts/next-tag.sh
set -euo pipefail

runner_version=$("$(dirname "$0")/runner-version.sh")
last=0
while read -r tag; do
    n=${tag#"$runner_version"-}
    if [[ $tag == "$runner_version"-* && $n =~ ^[0-9]+$ ]] && ((10#$n > last)); then
        last=$((10#$n))
    fi
done
echo "$runner_version-$((last + 1))"
