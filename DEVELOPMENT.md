# Developing the installer

This repository is one product: `install.sh`, a POSIX shell script that
installs a single VA-Crystal VoIP node and registers it with a mothership.
There is no build step and no runtime of its own — the node's software is the
private `nirlevi/va-crystal:node` image, and the CLI inside that image does the
real work. This guide is for people changing the script or its tests.

If you only want to *install a node*, use [README.md](README.md).

## What you need

| Tool | Why |
|---|---|
| Docker Engine + Compose v2 | the installer's only runtime; `shellcheck` also runs from a container when not installed |
| `sh`, `dash`, `bash` | `install.sh` must parse under `sh` and `dash` (Ubuntu's `/bin/sh`); the tests are Bash |
| `git`, `make` | this repo |
| `gh` (optional) | watching GitHub Actions from the terminal |

Optional sibling checkout, expected next to this directory:

```
voipappz/
├── installer/     this repo
└── va-crystal/    builds the node image; `make s3-archive` writes a tar.gz the installer can load
```

It is not required to edit and check the script. The mothership is **never
cloned**: the integration test boots it from the `/stack` directory inside the
node image, which is the stack repository as shipped.

## First run

```sh
git clone https://github.com/voipappz/installer.git
cd installer
make            # lists the targets
make check      # the same checks the "Shell" CI job runs — seconds, no network
```

`make check` is the gate for every change: syntax under `sh`, `dash` and
`bash`, ShellCheck, a clean `git diff --check`, and the guard that no Python
sneaks into the installer or its tests (the project deliberately has none).

## Running the installer from your checkout

```sh
make install                         # identical to `curl … | sh`, from the working tree
make install-archive                 # same, loading ../va-crystal/ci/build/va-crystal-node-<VERSION>.tar.gz
make install-archive ARCHIVE=/path/to/va-crystal-node-latest.tar.gz
```

The script takes no arguments; everything is an environment variable (the
full list is the "Useful controls" table in README.md). The ones you will
reach for while developing:

```sh
INSTALL_DIR=/tmp/node-a START=0 VA_REGISTER=0 make install     # no registration, nothing started
VA_API_URL=https://mothership.local VA_CONFIG=./va.yaml make install
VA_IMAGE_SOURCE=archive VA_IMAGE_ARCHIVE=/path/img.tar.gz make install
```

Points worth knowing when reading the script:

- **Nothing touches `INSTALL_DIR` until registration succeeds.** All work
  happens in a private `/tmp/voipappz-install.*` directory and is copied over
  in one step (`commit_install_dir`). A failed run leaves the target as it was.
- **Root is taken only when needed.** `root_cmd`/`sudo` for the install
  directory (`FS_AS_ROOT`) and for Docker (`DOCKER_AS_ROOT`) are decided
  separately; `sudo` resets the environment, which is why the Account
  authorization crosses that boundary on stdin (`docker_with_authorization`).
- **The image CLI has two setup wizards.** With `VA_PATH` set it runs the
  node-only one; the installer must never call the other (organization,
  domain, TLS — those belong to the mothership).
- **Secrets never land on disk or in logs.** Registry token, Account
  token/password and the Basic value live only in process memory and a
  temporary Docker config. `tests/test-install.sh` greps every log for them.

## Testing

Two layers, mirroring `.github/workflows/ci.yml`:

1. **`make check`** — static. Run before every commit.
2. **`make test`** — the integration test, `tests/test-install.sh`. It pulls
   the real private image, takes the stack repository from its `/stack`, boots
   the complete mothership (`app + storage`) from that copy (nothing is
   cloned; `MOTHERSHIP_DIR=…` overrides it with a local checkout), installs the node several times (Docker Hub, local
   archive, archive over HTTP, as a user outside the `docker` group, into a
   root-owned directory, over an untrusted TLS chain …), registers it, drives
   customer creation and `Customer::Init`, starts the VoIP profile and proves
   Kamailio answers a real SIP OPTIONS.

   It needs `VA_REGISTRY_USER` / `VA_REGISTRY_TOKEN` (Docker Hub, read access
   to `nirlevi/va-crystal`) and **a disposable host**: it creates a system
   user, writes `/opt/voipappz-ci`, and uses `sudo` freely. CI additionally
   runs `tests/clean-runner.sh`, which purges Docker from the runner; that
   script refuses to run outside GitHub Actions on purpose.

   On a workstation, run it in a throwaway VM; otherwise push a branch and let
   Actions run it on Ubuntu 22.04 and 24.04.

Adding a test: append to `tests/test-install.sh` using `run_installer
<success|failure> <label> VAR=… VAR=…`, then assert with `grep` on `$LAST_LOG`
or `api GET …` against the mothership. Every run's log is checked for
secrets automatically.

## CI

`.github/workflows/ci.yml`:

- **Shell / Ubuntu 22.04, 24.04** — `make check`, on every push and PR.
- **Clean install + real mothership / Ubuntu 22.04, 24.04** — the
  integration test, on pushes and manual dispatch only (fork PRs cannot
  receive the registry secrets `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`).
  It checks out only this repository.

Watch a run: `gh run list --limit 1` then `gh run watch <id>`. A change is
"done" when all four jobs are green.

## Where things live

| Path | Purpose |
|---|---|
| `install.sh` | the product; steps 1–6 are the top-level `step "N/6 …"` blocks |
| `tests/test-install.sh` | integration test (Bash) |
| `tests/clean-runner.sh` | GitHub-runner-only Docker purge |
| `Makefile` | this developer tool |
| `README.md` | operator documentation |
| `CLAUDE.md` | engineering notes and contracts (registration, customers, credentials) — read before changing behaviour |

## Conventions

- POSIX `sh` only in `install.sh`: no arrays, no `[[ ]]`, no bashisms;
  `dash -n` is the referee.
- One file. `install.sh` is fetched alone and piped into `sh`; it may not
  source anything.
- Prefer a direct shell fix over a framework or a dependency.
- Behaviour that an operator can observe must be reflected in README.md and
  covered by an assertion in `tests/test-install.sh`.
- Commit messages say what changed and why, in prose.
