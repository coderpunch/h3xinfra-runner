"""Checks of the repository files. They need Python 3, bash and gpg, but no
Docker and no network. Run: python3 -m unittest discover -s tests -v"""

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Docker Release (CE deb) <docker@docker.com>, the key of
# https://download.docker.com/linux/ubuntu (docs.docker.com/engine/install/ubuntu).
DOCKER_KEY_FINGERPRINT = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
DOCKER_REPOSITORY = "https://download.docker.com/linux/ubuntu"
DOCKER_PACKAGES = [
    "containerd.io",
    "docker-buildx-plugin",
    "docker-ce",
    "docker-ce-cli",
    "docker-compose-plugin",
]


def read(path):
    return (ROOT / path).read_text()


def run(args, stdin=""):
    return subprocess.run(
        args, cwd=ROOT, input=stdin, capture_output=True, text=True, check=True
    ).stdout.strip()


class DockerfileTest(unittest.TestCase):
    def setUp(self):
        self.text = read("Dockerfile")

    def test_base_image_is_pinned_by_tag_and_digest(self):
        froms = re.findall(r"^FROM\s+(\S+)", self.text, re.M)
        self.assertEqual(len(froms), 1, froms)
        self.assertRegex(
            froms[0],
            r"^ghcr\.io/actions/actions-runner:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$",
        )

    def test_docker_packages_have_exact_noble_versions(self):
        pins = dict(re.findall(r"^\s+(containerd\.io|docker-[a-z-]+)=(\S+)", self.text, re.M))
        self.assertEqual(sorted(pins), DOCKER_PACKAGES)
        for name, version in pins.items():
            self.assertRegex(version, r"^(\d+:)?\d+\.\d+\.\d+-\d+~ubuntu\.24\.04~noble$", name)
        self.assertEqual(pins["docker-ce"], pins["docker-ce-cli"])

    def test_docker_repository_is_noble_stable_with_the_key_file(self):
        self.assertIn(f"'URIs: {DOCKER_REPOSITORY}'", self.text)
        self.assertIn("'Suites: noble'", self.text)
        self.assertIn("'Components: stable'", self.text)
        self.assertIn("'Signed-By: /etc/apt/keyrings/docker.asc'", self.text)
        self.assertIn("COPY docker.asc /etc/apt/keyrings/docker.asc", self.text)


    def test_dockerd_gives_the_work_disk_to_the_runner(self):
        # A Kata emptyDir is a new ext4 disk that root owns.
        script = (ROOT / "bin" / "h3x-dockerd").read_text()
        self.assertIn("chown runner:runner /home/runner/_work", script)
        self.assertLess(script.index("chown runner:runner"), script.index("exec dockerd"))

    def test_dockerd_keeps_binfmt_misc_mounted(self):
        # In a Kata VM nothing else holds a binfmt_misc mount, and the kernel
        # removes the QEMU handlers when the last mount goes away.
        script = (ROOT / "bin" / "h3x-dockerd").read_text()
        self.assertIn("mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc", script)
        self.assertLess(script.index("binfmt_misc binfmt_misc"), script.index("exec dockerd"))
    def test_entrypoint(self):
        self.assertIn('ENTRYPOINT ["/usr/local/bin/h3x-runner-entrypoint"]', self.text)
        self.assertRegex(self.text, r"(?m)^USER runner$")
        entrypoint = read("bin/h3x-runner-entrypoint")
        self.assertIn("set -- /home/runner/run.sh", entrypoint)
        # Outside a VM, stop before dockerd and run.sh start.
        self.assertLess(
            entrypoint.index("if ! grep -qw hypervisor /proc/cpuinfo; then"),
            entrypoint.index("sudo --non-interactive"),
        )
        self.assertIn("sudo --non-interactive /usr/local/bin/h3x-dockerd &", entrypoint)
        self.assertIn('exec /usr/libexec/docker/docker-init -- "$@"', entrypoint)


class DockerKeyTest(unittest.TestCase):
    def test_key_file_has_one_key_with_the_docker_fingerprint(self):
        with tempfile.TemporaryDirectory() as home:
            out = subprocess.run(
                ["gpg", "--show-keys", "--with-colons", str(ROOT / "docker.asc")],
                env={**os.environ, "GNUPGHOME": home},
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        records = [line.split(":") for line in out.splitlines()]
        self.assertEqual([r[0] for r in records if r[0] == "pub"], ["pub"])
        fingerprints = [r[9] for r in records if r[0] == "fpr"]
        self.assertEqual(fingerprints[0], DOCKER_KEY_FINGERPRINT)


class RenovateTest(unittest.TestCase):
    def setUp(self):
        self.config = json.loads(read("renovate.json"))

    def test_docker_packages_are_looked_up_in_the_docker_repository(self):
        rules = [r for r in self.config["packageRules"] if r.get("matchDatasources") == ["deb"]]
        self.assertEqual(len(rules), 1)
        self.assertEqual(sorted(rules[0]["matchPackageNames"]), DOCKER_PACKAGES)
        self.assertEqual(
            rules[0]["registryUrls"],
            [f"{DOCKER_REPOSITORY}?suite=noble&components=stable&binaryArch=amd64"],
        )
        # No release dates, thus no age gate: a person merges each update.
        self.assertIs(rules[0]["automerge"], False)

    def test_tests_directory_is_not_ignored(self):
        self.assertNotIn("**/tests/**", self.config["ignorePaths"])

    def test_runner_release_manager_matches_the_from_line(self):
        (manager,) = self.config["customManagers"]
        (pattern,) = manager["matchStrings"]
        match = re.search(pattern.replace("(?<", "(?P<"), read("Dockerfile"))
        self.assertIsNotNone(match)
        self.assertEqual(match["currentValue"], run(["scripts/runner-version.sh"]))
        # Renovate applies the updates of a branch in depName order: the image
        # must rewrite the FROM line first.
        self.assertLess("ghcr.io/actions/actions-runner", manager["depNameTemplate"])


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.workflows = {
            path.name: path.read_text() for path in (ROOT / ".github/workflows").glob("*.yml")
        }

    def test_actions_are_pinned_by_commit_sha(self):
        for name, text in self.workflows.items():
            for ref, comment in re.findall(r"^\s*(?:-\s+)?uses:\s*(\S+)(.*)$", text, re.M):
                if ref.startswith("./"):
                    continue
                self.assertRegex(ref, r"^[\w.-]+/[\w./-]+@[0-9a-f]{40}$", name)
                self.assertRegex(comment, r"^ # v\d+\.\d+\.\d+$", name)

    def test_jobs_run_only_on_github_hosted_runners(self):
        # A public repository must never run a job on a self-hosted runner.
        for name, text in self.workflows.items():
            for runner in re.findall(r"^\s*runs-on:\s*(.+)$", text, re.M):
                self.assertEqual(runner.strip(), "ubuntu-latest", name)

    def test_publish_attests_the_pushed_digest(self):
        text = self.workflows["publish.yml"]
        self.assertIn("uses: actions/attest@", text)
        self.assertIn("subject-digest: ${{ steps.push.outputs.digest }}", text)
        self.assertIn("push-to-registry: true", text)

    def test_smoke_test_runs_before_the_push_without_write_permissions(self):
        self.assertIn("run: tests/smoke.sh h3xinfra-runner:ci", self.workflows["ci.yml"])
        # publish.yml: the job "build" runs the privileged smoke test and has
        # no write permission. The job "push" has the write permissions, runs
        # after "build" and starts no container.
        build, push = self.workflows["publish.yml"].split("\n  push:\n")
        self.assertIn('run: tests/smoke.sh "$IMAGE:$TAG"', build)
        self.assertNotRegex(build, r"(?m)^\s+[\w-]+: write$")
        self.assertIn("    needs: build\n", push)
        self.assertIn("      id-token: write\n", push)
        self.assertNotIn("smoke", push)
        self.assertNotIn("docker run", push)
        self.assertIn('if [[ -z $IMAGE_ID || $loaded != "$IMAGE_ID" ]]; then', push)


class ScriptTest(unittest.TestCase):
    def test_next_tag(self):
        version = run(["scripts/runner-version.sh"])
        self.assertRegex(version, r"^\d+\.\d+\.\d+$")
        self.assertEqual(run(["scripts/next-tag.sh"]), f"{version}-1")
        tags = f"{version}-2\n{version}-10\n{version}-9\n0.0.1-99\n{version}-x\nv{version}-50\n"
        self.assertEqual(run(["scripts/next-tag.sh"], tags), f"{version}-11")


if __name__ == "__main__":
    unittest.main()
