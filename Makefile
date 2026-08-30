# Developer entry point for the VoIPAppz node installer.  `make` lists targets.
# The product is one POSIX script, install.sh; everything here exists to
# check it, run it, and test it the way GitHub Actions does.

.DEFAULT_GOAL := help
.PHONY: help check install install-archive install-no-register test shellcheck iso iso-validate \
	up down start stop logs health cli node-preflight

# Every shell script in the ISO pipeline. POSIX, like install.sh, and held to
# the same gate — one of them (va-node-install) runs on an offline node where
# nothing can be fixed afterwards.
ISO_SCRIPTS = packer/build.sh packer/make-node-iso.sh \
              packer/scripts/fetch-base-iso.sh packer/scripts/stage-payload.sh \
              packer/scripts/presign-iso.sh packer/files/va-node-install

B = \033[1m
C = \033[36m
D = \033[2m
R = \033[0m

# Sibling checkout on a workstation (only for install-archive).
VA_CRYSTAL_DIR ?= $(abspath $(CURDIR)/../va-crystal)
# The newest archive `make s3-archive` wrote in va-crystal, if any.
ARCHIVE ?= $(lastword $(sort $(wildcard $(VA_CRYSTAL_DIR)/ci/build/va-crystal-node-*.tar.gz)))

help:
	@printf '$(B)voipappz/installer$(R) — one script that installs a VA-Crystal voip node\n\n'
	@printf '  $(C)%-19s$(R) %s\n' \
	  'check'           'what CI runs first: syntax, shellcheck, clean diff, no python, unit tests' \
	  'install'         'run install.sh from this checkout (asks sudo, image source, node, mothership, token)' \
	  'install-archive' 'the same, loading the newest ../va-crystal/ci/build/*.tar.gz (ARCHIVE=… to pick one)' \
	  'install-no-register' 'sh install.sh --no-register — a node with no mothership; register it later' \
	  'test'            'the integration test: a real mothership, downloaded as its public tarball — DISPOSABLE HOST ONLY' \
	  'iso-validate'    'packer validate the offline installer ISO template (no packer needed)' \
	  'iso'             'cut the offline installer ISO: make iso IMAGE_VERSION=… RELEASE_VERSION=… (packer + xorriso)' \
	  'up'         'recreate the node with the full docker run  (alias: start)' \
	  'down'       'docker stop $(NODE)                        (alias: stop)' \
	  'health'     'docker exec $(NODE) voipappz health        — the 16-check verdict' \
	  'logs'       'docker logs -f --tail 100 $(NODE)' \
	  'cli'        'docker exec -it $(NODE) voipappz $$ARGS     — make cli ARGS="sbc egress status"'
	@printf '\n  $(D)docs: README.md (operators)  DEVELOPMENT.md (developers)  CLAUDE.md (engineering notes)$(R)\n\n'

# Exactly the "Shell" job of .github/workflows/ci.yml. shellcheck runs from
# its container when it is not installed, so this needs nothing but docker.
check:
	test -x install.sh
	sh -n install.sh
	dash -n install.sh
	bash -n tests/clean-runner.sh tests/test-install.sh tests/unit.sh
	@for f in $(ISO_SCRIPTS); do test -x "$$f" && sh -n "$$f" && dash -n "$$f" || exit 1; done
	$(MAKE) --no-print-directory shellcheck
	git diff --check
	test -z "$$(find tests -type f -name '*.py' -print -quit)"
	! grep -Eq 'python(3)?' install.sh
	bash tests/unit.sh
	@printf '$(B)check green$(R)\n'

SHELLCHECK_FILES = install.sh tests/clean-runner.sh tests/test-install.sh tests/unit.sh $(ISO_SCRIPTS)

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck $(SHELLCHECK_FILES); \
	else \
	  docker run --rm -v "$(CURDIR):/w:ro" -w /w koalaman/shellcheck:stable \
	    $(SHELLCHECK_FILES); \
	fi

install:
	sh install.sh

install-archive:
	@test -n "$(ARCHIVE)" || { printf '$(B)no archive found$(R) — in ../va-crystal run: make s3-archive   (or pass ARCHIVE=/path/file.tar.gz)\n'; exit 1; }
	VA_IMAGE_ARCHIVE="$(ARCHIVE)" sh install.sh

# Install and START the node, but do not touch a mothership: no Account
# credential, no registration, no customer. What install.sh's step 5 does, and
# only that, is skipped — the image, va.yaml, the secrets, the container and
# the full 16-check health gate all still happen.
#
# For a machine that cannot reach a mothership yet (the offline disc says the
# same: "the disc makes the IMAGE offline, not the API"), or when the Account
# credential belongs to someone else. The node runs; the platform does not know
# it exists, so phones can register and calls cannot route until it does.
install-no-register:
	sh install.sh --no-register

# The installed node, once install.sh has run. Thin on purpose: each is the
# docker command an operator would type, so nothing here can drift from what
# the node actually does. Lifecycle is Docker's (`--restart unless-stopped`),
# and every node operation is the CLI's, inside the image.
NODE ?= va-voip
# THE WHOLE COMMAND, because a wrapper that hides how a node is started is a
# wrapper you have to trust. This recreates the container rather than
# restarting it, so what you read is what ran.
#
# It DUPLICATES install.sh's docker run, which is a real cost: two copies drift,
# and the divergence between this repo's run and ../va-crystal's is exactly the
# bug that left every installed node without real-time limits. KEEP THIS IN
# STEP WITH install.sh's step 6 — the CI job "Node starts with real-time
# limits" checks the installer's copy, not this one.
#
# The three secrets are read from the installation's .env at run time. `$$VAR`
# is shell, not make, so the recipe echoes the NAMES and the values never reach
# the terminal.
INSTALL_DIR ?= /opt/voipappz

# Checked BEFORE anything destructive. `up` removes the container to recreate
# it; discovering only afterwards that the .env is unreadable leaves the host
# with no node at all. That happened once — it does not happen again.
#
# install.sh writes .env mode 0600 owned by root, on purpose (it holds the
# FreeSWITCH and licence secrets), so `make up` on a real /opt/voipappz install
# needs sudo. Say so instead of failing halfway.
node-preflight:
	@test -r $(INSTALL_DIR)/.env || { \
	  printf 'cannot read $(B)$(INSTALL_DIR)/.env$(R) — install.sh writes it 0600, owned by root.\n  run: $(B)sudo make up INSTALL_DIR=$(INSTALL_DIR)$(R)\n'; exit 1; }
	@test -r $(INSTALL_DIR)/config/va.yaml || { \
	  printf 'no $(B)$(INSTALL_DIR)/config/va.yaml$(R) — nothing is installed there. run: $(B)make install$(R)\n'; exit 1; }

up: node-preflight ## Recreate and start the node, showing the whole command (alias: start)
	-docker rm -f $(NODE)
	set -a && . $(INSTALL_DIR)/.env && set +a && docker run -d --name $(NODE) \
	  --network host --restart unless-stopped \
	  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_RESOURCE \
	  --cap-add SYS_NICE --cap-add IPC_LOCK \
	  --security-opt seccomp=unconfined \
	  --ulimit rtprio=99 --ulimit nice=-19 \
	  --ulimit memlock=-1:-1 --ulimit nofile=999999:999999 \
	  -v $(INSTALL_DIR)/config/va.yaml:/tmp/node.yaml:ro \
	  -v voipappz-kamailio:/var/lib/kamailio \
	  -e VA_PATH=/tmp/node.yaml \
	  -e FREESWITCH_PASSWORD="$$VA_FREESWITCH_PASSWORD" \
	  -e VA_FREESWITCH_PASSWORD="$$VA_FREESWITCH_PASSWORD" \
	  -e LICENSE_JWT_SECRET="$$VA_LICENSE_JWT_SECRET" \
	  -e LICENSE_ENCRYPTION_KEY="$$VA_LICENSE_ENCRYPTION_KEY" \
	  "$$VA_VOIP_IMAGE"

down: ## Stop it, keeping its identity and its kamailio volume
	docker stop $(NODE)

# Docker's own verbs, because that is what fingers type. `up`/`down` match
# ../va-crystal, so both names exist rather than one being right.
start: up
stop: down

logs: ## Follow it (kamailio + FreeSWITCH + node, interleaved)
	docker logs -f --tail 100 $(NODE)

health: ## The 16-check verdict
	docker exec $(NODE) voipappz health

cli: ## The in-image CLI: make cli ARGS="sbc egress status"
	@docker inspect -f '{{.State.Running}}' $(NODE) >/dev/null 2>&1 \
	  || { echo "$(NODE) is not running — start it with: make up"; exit 1; }
	docker exec -it $(NODE) voipappz $(ARGS)

# The "Clean install + real mothership" job, minus tests/clean-runner.sh
# (which purges Docker and refuses to run outside GitHub Actions). The
# mothership is DOWNLOADED as the public tarball of voipappz/mothership, the
# way its own installer fetches it — it used to come from a /stack inside the
# node image, which va-crystal dropped on 2026-08-26. Nothing is
# cloned; pass MOTHERSHIP_DIR=… only to test against a local checkout. It
# creates a system user and writes /opt/voipappz-ci — run it on a throwaway
# VM, never on a workstation you care about.
# The offline installer ISO — a bootable Ubuntu 24.04 disc carrying Docker,
# install.sh and ONE node image. See packer/README.md. Needs packer, xorriso and
# a docker login for the private image. The finished disc is RESTRICTED media:
# it holds that private image in the clear.
#
# TWO versions, and they are different numbers. IMAGE_VERSION is va-crystal's
# node image tag — this repository consumes it. RELEASE_VERSION is the disc's
# own release, which this repository OWNS; the GitHub workflow mints it from the
# bucket, and a local cut has to name one.
IMAGE_VERSION ?=
RELEASE_VERSION ?=
iso-validate:
	packer/build.sh validate \
	  -var image_version="$(or $(IMAGE_VERSION),0000.00.00-validate-only)" \
	  -var release_version="$(or $(RELEASE_VERSION),0000.00.00-validate-only)"

iso:
	@test -n "$(IMAGE_VERSION)" || { printf '$(B)set IMAGE_VERSION$(R) — the image is pinned: make iso IMAGE_VERSION=2026.08.27-2 RELEASE_VERSION=2026.08.27-1\n'; exit 1; }
	@test -n "$(RELEASE_VERSION)" || { printf '$(B)set RELEASE_VERSION$(R) — this disc needs its own release number (the workflow mints one from S3)\n'; exit 1; }
	packer/scripts/fetch-base-iso.sh
	packer/build.sh build \
	  -var image_version="$(IMAGE_VERSION)" \
	  -var release_version="$(RELEASE_VERSION)"

MOTHERSHIP_DIR ?=
test:
	@test -n "$${VA_REGISTRY_USER:-}" && test -n "$${VA_REGISTRY_TOKEN:-}" || { printf '$(B)export VA_REGISTRY_USER and VA_REGISTRY_TOKEN$(R) (Docker Hub, read access to nirlevi/va-crystal)\n'; exit 1; }
	tests/test-install.sh $(MOTHERSHIP_DIR)
