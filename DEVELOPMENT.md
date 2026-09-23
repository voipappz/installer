# Developing the installer

This repository is one product: `install.sh`, a POSIX shell script that
installs a single VA-Crystal VoIP node and registers it with a mothership.
There is no build step and no runtime of its own — the node's software is the
private `nirlevi/va-crystal:latest` image, and the CLI inside that image does the
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
cloned**: the integration test downloads the public tarball of
voipappz/mothership, the same way the mothership's own installer does.

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
make get                             # the image: S3 archive, verified, no questions
make get dockerhub                   # ... pulled instead, with VA_REGISTRY_USER + VA_REGISTRY_TOKEN
make get ARCHIVE=latest              # ... docker load the newest ../va-crystal/ci/build/*.tar.gz
make get ARCHIVE=/path/img.tar.gz    # ... a path or an http(s) URL (which must publish .sha256)
make install                         # install THAT image; never fetches, never asks
make install REGISTER=0              # a node with no mothership; register it later
sh install.sh --start-only           # start the node INSTALLED in $INSTALL_DIR
```

## The node on your machine

`make up` and friends are the other thing: they drive the node you are working
on, HERE, out of two files beside the Makefile — `./.env` (the image tag and
the secrets the image cannot derive) and `./config/va.yaml` (the node itself).

```sh
make setup                          # the wizard: writes ./.env and ./config/va.yaml
make verify                         # check those two files before starting anything
make up                             # start the node from those two files
make down                           # stop it, keeping its kamailio volume
make logs                           # follow it (TAIL=all from the beginning)
make health                         # its own verdict, from the CLI in the image
make cli ARGS="sbc egress status"   # any other CLI command, in the image
```

ONE COMMAND, ONE SCRIPT: each is a file in `scripts/`, and the recipe only
names it, so nothing about how a node starts lives in the Makefile. What make
adds is visibility — it puts the values from `./.env` on the command line it
echoes, and a variable you set wins over the file, exactly as the scripts read
them:

```
$ make up
VA_VOIP_IMAGE=nirlevi/va-crystal:node sh scripts/up.sh

$ make up VA_VOIP_IMAGE=nirlevi/va-crystal:latest
VA_VOIP_IMAGE=nirlevi/va-crystal:latest sh scripts/up.sh
```

No secret is ever expanded onto that line: only the image tag, the two file
paths, the container name and `TAIL`. The scripts read the credentials from
`./.env` themselves and mask them even in the `docker run` they print.

STRICT, AND NOTHING IS GUESSED. There are no defaults: a value that is not in
`./.env` or your environment is named and the run stops, pointing at `make
setup`. Nothing pulls, loads or retags an image — `make get` does that.

`make verify` is the one to run before `make up`, and it is the only one that
changes nothing at all. The image fails loudly or not at all: a bad `va.yaml`
or a missing secret halts the container before any service starts, so its
report — which names every problem at once — ends up in the `docker logs` of
something that is already dead. `verify` asks the same questions out here: the
five values only `./.env` can carry (set or missing; never printed, and
`VA_SECRET_KEY` compared against a local API container's when there is one),
the image on this host, the contract's fields in `va.yaml` (a uuid, an
`ip_address_internal` an interface here actually holds, 5060 for kamailio and
5070/5090 for sofia, HTTPS to the mothership unless it is loopback, a broker
URL), no secret leaked into the world-readable YAML, and the ports free. A `✗`
fails the run; a `!` is a warning. It reads an installed node just as well:

```sh
VA_ENV_FILE=/opt/voipappz/.env VA_CONFIG=/opt/voipappz/config/va.yaml make verify
```

`make up` also validates the node it started rather than trusting a port.
`--network host` means every `127.0.0.1` probe can be answered by a DIFFERENT
node container, so it refuses to start beside a second host-network node
(offering to stop it), then proves kamailio through *this* container's own
control socket before waiting for the API on `:4000`. A start that fails prints
the tail of the node's log instead of a bare exit code, and every check happens
before the running container is removed — a `make up` that cannot start the
node must not be the thing that stopped it.

Its `docker run` is `install.sh`'s, flag for flag (the unit tests compare the
two, and va-crystal's `scripts/run-node.sh` is the third copy that must agree):
the real-time ulimits, the capabilities, the YAML at `/tmp/node.yaml` and the
named kamailio volume.

The script takes no arguments; everything is an environment variable (the
full list is the "Useful controls" table in README.md). The ones you will
reach for while developing:

```sh
INSTALL_DIR=/tmp/node-a sh install.sh --no-register --no-start  # no registration, nothing started
VA_API_URL=https://mothership.local VA_CONFIG=./va.yaml make install
VA_IMAGE_SOURCE=archive VA_IMAGE_ARCHIVE=/path/img.tar.gz sh install.sh
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
   the real private image, downloads the mothership tarball, boots
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

   On a workstation, run it in a throwaway VM; otherwise push a branch, open a
   pull request, and let Actions run it on Ubuntu 22.04 and 24.04.

Adding a test: append to `tests/test-install.sh` using `run_installer
<success|failure> <label> VAR=… VAR=…`, then assert with `grep` on `$LAST_LOG`
or `api GET …` against the mothership. Every run's log is checked for
secrets automatically.

## CI

`.github/workflows/ci.yml`, nine jobs:

- **Shell / Ubuntu 22.04, 24.04** — `make check` and the `make -n` target
  expansions, on every push and pull request.
- **cli · specs + static link + SIPp round-trip** — `make cli-test`, `make
  build`, the command-surface check, and a real SIPp round trip through
  `voipappz test scenario`, on every push and pull request. The binary is kept
  as an artifact for a week, and a push to `main` also replaces the rolling
  `latest` release.
- **Node starts with real-time limits / Ubuntu 22.04, 24.04** — installs a node
  against a stub mothership, checks the container's capabilities and ulimits
  reached the process, then drives `make up`, `make down` and `make health`
  against that installation.
- **Clean install + real mothership / Ubuntu 22.04, 24.04** — the integration
  test, `tests/test-install.sh`, against a downloaded mothership.
- **Media / templates validate** — `make image-validate`: `packer validate`
  over both `.pkr.hcl` files, in the builder container, so the runner needs
  Docker and nothing else. Every push. Locally: `make act-packer` (~45s).
- **Media / cut an image-less ISO** — cuts a disc end to end with
  `with_images=false`, then proves it is one: El Torito for BIOS *and* UEFI,
  and the `/voipappz` payload present. Manual only (it writes gigabytes).
  Locally: `make act-iso-base` once for Canonical's ISO, then `make act-iso`.

  `with_images=false` is what makes a cut runnable in CI: the payload's image
  is private and gigabytes, while everything a cut can get wrong — the
  autoinstall, the package closure, the remaster, the boot records — is in the
  rest of the disc. A disc WITH the image is `make iso` on a machine that has
  the registry credential.

The last two need the registry secrets (`DOCKERHUB_USERNAME`,
`DOCKERHUB_TOKEN`) and `MOTHERSHIP_TOKEN`. They run on pushes, manual dispatch,
and pull requests opened from this repository. Pull requests from forks and
Dependabot receive no secrets, so those two jobs skip themselves there.

Watch a run: `gh pr checks <number>`, or `gh run list --limit 1` then
`gh run watch <id>`. A change is "done" when every job is green.

## Landing a change

`main` is protected by the `protect-main` repository ruleset:

- no direct pushes: every change arrives as a pull request;
- all seven CI jobs above must pass, on a branch that is up to date with `main`;
- review threads must be resolved; merge or squash, no rebase merges;
- no force pushes, and `main` cannot be deleted.

So the loop is: branch, `make check`, push, open a pull request, wait for the
seven checks, merge, then confirm the run on `main` is green too.

The integration test downloads the mothership's `main`, so a mothership change
can turn this repository's CI red with no change here. When it does, fix the
test to follow the mothership in a pull request like any other.

`.github/workflows/release.yml` runs on a `v*` tag and publishes the CLI
binaries and checksums. Nothing in `install.sh` consumes them; va-crystal and
`scripts/install-cli.sh --release` do — as does `make build RELEASE=1`, which
downloads that binary into `bin/` instead of compiling one.

## Where things live

| Path | Purpose |
|---|---|
| `install.sh` | the product; steps 1–6 are the top-level `step "N/6 …"` blocks |
| `tests/test-install.sh` | integration test (Bash) |
| `tests/clean-runner.sh` | GitHub-runner-only Docker purge |
| `cli/` | the `voipappz` CLI: source, specs, SIPp scenarios (moved from the mothership 2026-09-03) |
| `scripts/install-cli.sh` | puts a built or published CLI binary on PATH |
| `Makefile` | this developer tool, and the CLI build and test targets |
| `README.md` | operator documentation |
| `CLAUDE.md` | engineering notes and contracts (registration, customers, credentials) — read before changing behaviour |

## Conventions

- POSIX `sh` only in `install.sh`: no arrays, no `[[ ]]`, no bashisms;
  `dash -n` is the referee.
- One file. `install.sh` is fetched alone and piped into `sh`; it may not
  source anything, and it never builds, fetches or runs the host CLI — the
  CLI it uses is the one inside the node image.
- Prefer a direct shell fix over a framework or a dependency.
- Behaviour that an operator can observe must be reflected in README.md and
  covered by an assertion in `tests/test-install.sh`.
- Commit messages say what changed and why, in prose.
