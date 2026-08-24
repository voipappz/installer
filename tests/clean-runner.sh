#!/usr/bin/env bash
# Remove the Docker packages preinstalled on a GitHub-hosted runner so the
# public installer has to install Docker exactly as it would on a clean host.
set -Eeuo pipefail

[[ ${GITHUB_ACTIONS:-} == true ]] || {
  echo 'clean-runner.sh is intentionally restricted to GitHub Actions' >&2
  exit 1
}

sudo systemctl stop docker.service docker.socket containerd.service 2>/dev/null || true

packages=()
for package in \
  docker-ce docker-ce-cli docker-ce-rootless-extras \
  docker-buildx-plugin docker-compose-plugin containerd.io \
  docker.io docker-compose docker-compose-v2 containerd runc podman-docker
do
  dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii ' \
    && packages+=("$package")
done

((${#packages[@]} > 0)) || {
  echo 'No installed Docker packages were found on the runner' >&2
  exit 1
}

sudo apt-get purge -y "${packages[@]}" >/dev/null
hash -r

if command -v docker >/dev/null 2>&1; then
  echo "Docker is still on PATH after package removal: $(command -v docker)" >&2
  exit 1
fi

echo 'GitHub runner has no Docker CLI; installer Docker setup will be exercised'
