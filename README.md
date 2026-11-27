# h3xinfra-runner

This repository builds `ghcr.io/coderpunch/h3xinfra-runner`. It is an image
for self-hosted GitHub Actions runners in Kubernetes, for example with Actions
Runner Controller (ARC). The image adds Docker Engine, Docker Compose and
Docker Buildx to the official runner image `ghcr.io/actions/actions-runner`.
Thus, a job can use these features, as on a GitHub-hosted runner:

- `docker build`, `docker run` and multi-platform builds with Buildx.
- `docker compose`.
- `services:` and `container:` in a workflow.
- `sudo`, for example `sudo apt-get install`.

> WARNING: The runner container must run in privileged mode, because
> `dockerd` runs in it. Run the image only in a VM sandbox, for example a
> Kata Containers pod. Do not run it privileged with runc on a shared node.
> In that configuration, each job gets root access to the node. The
> entrypoint stops if the CPU has no `hypervisor` flag, for example on a
> bare-metal node. But on a node that is a VM, the entrypoint cannot see runc.

## Contents

| Part | Source | Version |
| --- | --- | --- |
| Runner | The base image `ghcr.io/actions/actions-runner` | The tag and the digest in the `Dockerfile` |
| Docker Engine and CLI | `docker-ce` and `docker-ce-cli` from the Docker apt repository | The exact version in the `Dockerfile` |
| containerd and runc | `containerd.io` from the Docker apt repository | The exact version in the `Dockerfile` |
| Docker Compose | `docker-compose-plugin` from the Docker apt repository | The exact version in the `Dockerfile` |
| Docker Buildx | `docker-buildx-plugin` from the Docker apt repository | The exact version in the `Dockerfile` |
| Other tools | The Ubuntu 24.04 packages `libatomic1`, `pigz`, `xz-utils`, `zip` and `zstd`. `docker-ce` also installs `iptables` and `nftables`. | The current version in the Ubuntu archive at build time |

The base image also contains `git`, `ssh`, `curl`, `jq`, `unzip`, `python3`
and `sudo`. The base image has older static Docker binaries. The Docker
packages replace them.

The file `docker.asc` is the key of the Docker apt repository. Its
fingerprint is `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`. apt
verifies the signature of the repository with this key.

## How the container starts

The image entrypoint is `/usr/local/bin/h3x-runner-entrypoint`. It runs as
the user `runner` (uid 1001) and does these steps:

1. It looks for the `hypervisor` flag in `/proc/cpuinfo`. A VM gives this
   flag to its guest CPU. If the flag is not there, the container stops with
   exit code 1. `dockerd` and the runner do not start.
2. It starts `/usr/local/bin/h3x-dockerd` as root through passwordless
   `sudo`. This script does the same preparation as the `dind` script of the
   `docker:dind` image. Then it starts `dockerd`. The output of `dockerd`
   goes to the container log.
3. It waits until `docker info` answers, for a maximum of 60 seconds. If
   `dockerd` does not answer, the container stops with exit code 1.
4. It starts the command under `docker-init` (tini) as PID 1. tini collects
   the exit status of orphaned processes. Thus, no zombie processes stay.
   tini also forwards signals to the command. The default command is
   `/home/runner/run.sh`. Arguments replace the default command.

`dockerd` stores its data in `/var/lib/docker` and listens on
`/var/run/docker.sock`. The user `runner` is in the group `docker`. Thus, jobs
use Docker without `sudo`.

## Pod requirements

The runner pod must have these properties:

| Property | Value | Reason |
| --- | --- | --- |
| `runtimeClassName` | A RuntimeClass of a VM sandbox, for example Kata Containers | The privileged container stays inside the VM. |
| `command` of the runner container | `["/usr/local/bin/h3x-runner-entrypoint"]` | A pod `command` replaces the image entrypoint. The usual ARC template gives `/home/runner/run.sh`, which does not start `dockerd`. |
| `securityContext.privileged` | `true` | `dockerd` must configure cgroups, mounts and iptables. |
| `securityContext.runAsUser` and `runAsGroup` | `1001` | The runner user. The container runtime adds the groups `sudo` and `docker` from `/etc/group` of the image. |
| Volume at `/var/lib/docker` | An `emptyDir` volume with a `sizeLimit` | The data of `dockerd` stays out of the image layers. |

The Docker storage driver uses overlayfs. overlayfs cannot use a virtio-fs
directory as its upper directory. In the runtime-rs configuration of Kata
Containers 4, set `emptydir_mode = "block-plain"`. Then the guest gets the
`emptyDir` volume as a block device, and the volume is ext4 in the guest.

This example shows the runner part of an ARC `AutoscalingRunnerSet`:

```yaml
template:
  spec:
    runtimeClassName: kata
    restartPolicy: Never
    automountServiceAccountToken: false
    containers:
      - name: runner
        image: ghcr.io/coderpunch/h3xinfra-runner:2.338.2-1@sha256:<digest>
        command: ["/usr/local/bin/h3x-runner-entrypoint"]
        securityContext:
          privileged: true
          runAsUser: 1001
          runAsGroup: 1001
        volumeMounts:
          - name: docker
            mountPath: /var/lib/docker
    volumes:
      - name: docker
        emptyDir:
          sizeLimit: 16Gi
```

NOTE: `dockerd` uses its defaults for the networks of the job containers.
These networks have IPv4 only and an MTU of 1500. If the pod network has a
smaller MTU, the network can drop large packets from the job containers.

## Tags

A release tag has the form `<runner version>-<n>`, for example `2.338.2-1`.
The runner version is the version of `ghcr.io/actions/actions-runner` in the
`Dockerfile`. For each runner version, `n` starts at 1. Each new release
adds 1. The workflow pushes each tag one time only. Pin the tag and the
digest.

The image is for `linux/amd64` only.

Renovate uses Docker versioning for images. Docker versioning reads `-<n>`
as a compatibility suffix. Thus, it does not offer `2.338.2-2` after
`2.338.2-1`. In the Renovate configuration of a consumer repository, add a
package rule with regex versioning:

```json
{
  "matchPackageNames": ["ghcr.io/coderpunch/h3xinfra-runner"],
  "versioning": "regex:^(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-(?<build>\\d+)$"
}
```

## Provenance

The `Publish` workflow attests the build provenance of each image digest.
To verify an image, run this command:

```sh
gh attestation verify oci://ghcr.io/coderpunch/h3xinfra-runner@sha256:<digest> \
  --repo coderpunch/h3xinfra-runner \
  --signer-workflow coderpunch/h3xinfra-runner/.github/workflows/publish.yml \
  --deny-self-hosted-runners
```

CI also verifies the base image. Its digest must have an attestation from
the image workflows of `actions/runner` (`scripts/check-base-image.sh`).

## Tests

| Test | What it checks | Needs |
| --- | --- | --- |
| `python3 -m unittest discover -s tests -v` | The pins in the `Dockerfile`, the key fingerprint, the Renovate rules, the workflows and the release tag script | Python 3, bash, gpg |
| `scripts/check-base-image.sh` | The attestation of the base image | `gh` with a token, network |
| `tests/smoke.sh IMAGE` | The image in a privileged container: versions, plugins, tools, `sudo`, a build, DNS, Compose and the default command | Docker in a VM, network |

The smoke test is a check on a GitHub-hosted runner. It does not test the
VM sandbox. Test a new sandbox configuration with a test pod before you use
it for jobs.

## License

[MIT](LICENSE)
