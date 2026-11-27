#!/bin/bash
# Runs inside the h3xinfra-runner container (tests/smoke.sh mounts this
# directory at /smoke). The entrypoint started dockerd before this script.
set -euo pipefail

fail() {
    echo "FAIL $*" >&2
    exit 1
}

echo "-- runner user with passwordless sudo"
[[ $(id -u) -eq 1001 ]] || fail "uid is $(id -u), not 1001"
sudo --non-interactive true || fail "passwordless sudo"

echo "-- Docker Engine, CLI and plugins from the Docker apt packages"
want=$(dpkg-query --showformat '${Version}' --show docker-ce)
want=${want#*:}
want=${want%%-*}
got=$(docker version --format '{{.Client.Version}} {{.Server.Version}}')
[[ $got == "$want $want" ]] || fail "docker client and server are '$got', not docker-ce $want"
plugins=$(docker info --format '{{range .ClientInfo.Plugins}}{{.Name}}={{.Path}} {{end}}')
for plugin in buildx compose; do
    [[ $plugins == *"$plugin=/usr/libexec/docker/cli-plugins/docker-$plugin "* ]] \
        || fail "the $plugin plugin is not the apt package: $plugins"
done
# The base image has static Docker binaries. dpkg must own each of these
# paths, and the two base files that no package replaces must be gone.
for path in /usr/bin/containerd /usr/bin/containerd-shim-runc-v2 /usr/bin/ctr /usr/bin/runc \
    /usr/bin/docker /usr/bin/dockerd /usr/bin/docker-proxy /usr/libexec/docker/docker-init; do
    dpkg-query --search "$path" > /dev/null || fail "no package owns $path"
done
for path in /usr/bin/docker-init /usr/local/lib/docker/cli-plugins/docker-buildx; do
    [[ ! -e $path ]] || fail "$path of the base image is still there"
done
docker compose version
docker buildx version
echo "storage driver: $(docker info --format '{{.Driver}}')"

echo "-- binfmt_misc stays mounted for the QEMU handlers of multi-platform builds"
mountpoint -q /proc/sys/fs/binfmt_misc || fail "binfmt_misc is not mounted"

echo "-- runner files and extra tools"
[[ -x /home/runner/run.sh ]] || fail "/home/runner/run.sh"
ldconfig -p | grep -q 'libatomic\.so\.1 ' || fail "libatomic.so.1"
for tool in git ssh curl jq unzip zip xz zstd pigz iptables; do
    command -v "$tool" > /dev/null || fail "$tool is not installed"
done

echo "-- build and run an image"
docker buildx build --load --tag h3x-smoke /smoke
[[ $(docker run --rm h3x-smoke cat /built) == ok ]] || fail "docker run"

echo "-- DNS and NAT from a container on the default bridge"
docker run --rm h3x-smoke nslookup -type=a github.com || fail "DNS from a container"

echo "-- Compose: bind mount from the work directory, names on the project network"
www=$HOME/smoke-www
mkdir -p "$www"
token=$(date +%s%N)
echo "$token" > "$www/index.html"
WWW_DIR=$www TOKEN=$token docker compose --file /smoke/compose.yaml --project-name h3x-smoke \
    up --exit-code-from client || fail "docker compose"

echo "PASS tests/smoke/inside.sh"
