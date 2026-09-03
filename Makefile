# Developer entry point for the VoIPAppz node installer.  `make` lists targets.
# The product is one POSIX script, install.sh; everything here exists to
# check it, run it, and test it the way GitHub Actions does.

.DEFAULT_GOAL := help
.PHONY: help check install install-archive install-no-register test shellcheck \
	up down start stop logs health cli node-preflight \
	cli-build cli-node-build cli-test build install-cli

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
	  'up'         'recreate the node with the full docker run  (alias: start)' \
	  'down'       'docker stop $(NODE)                        (alias: stop)' \
	  'health'     'docker exec $(NODE) voipappz health        — the 16-check verdict' \
	  'logs'       'docker logs -f --tail 100 $(NODE)' \
	  'cli'        'docker exec -it $(NODE) voipappz $$ARGS     — make cli ARGS="sbc egress status"' \
	  'build'      'compile cli/ (static, in Docker) and put the host binary at bin/voipappz' \
	  'cli-node-build' 'the -Dnode_runtime binary va-crystal bakes into the node image' \
	  'cli-test'   'the CLI spec suite (in Docker)' \
	  'install-cli' 'put bin/voipappz on PATH (PREFIX=/usr/local/bin; ARGS=--release for the published one)'
	@printf '\n  $(D)docs: README.md (operators)  DEVELOPMENT.md (developers)  CLAUDE.md (engineering notes)$(R)\n\n'

# ---------------------------------------------------------------- the CLI
#
# cli/ is the voipappz CLI's SOURCE, moved here from the mothership on
# 2026-09-03 so it can be public while the mothership is not. One source, two
# binaries: the host one (bin/voipappz — `voipappz bootstrap` installs a
# mothership, `voipappz node install` launches install.sh) and the
# -Dnode_runtime one, which va-crystal fetches from this repo's releases and
# bakes into nirlevi/va-crystal:node. install.sh itself never builds, fetches
# or runs either: it only runs the copy inside the image.
#
# In Docker, never on the host: nothing here assumes a Crystal toolchain, and
# the alpine image is the same one the release workflow uses, so a workstation
# build and a released build are the same binary. Static, always: the SIP
# suites and the mothership's ISO run it FROM THE HOST, where a musl dynamic
# build cannot exec.
CRYSTAL_IMAGE ?= crystallang/crystal:1.16.3-alpine

# The REPO ROOT is mounted, not cli/, so `shards` sees the lock file next to
# the manifest and the specs can reach their fixtures under cli/spec.
CLI_RUN = docker run --rm $(shell test -t 0 && echo -t) -v "$(CURDIR):/w" -w /w/cli $(CRYSTAL_IMAGE) sh -lc

# `shards check` first: `shards install` on every build re-resolves the
# dependency graph over the network for no gain. shard.lock is committed, so
# what it installs is pinned — see cli/.gitignore for why that matters.
CLI_SHARDS = (shards check >/dev/null 2>&1 || shards install --skip-postinstall)

# chown back: the container is root, so bin/, lib/ and .shards/ land root-owned
# and the NEXT run cannot write them — `shards install` then fails as Permission
# denied on a tree the operator appears to own.
CLI_CHOWN = chown -R $(shell id -u):$(shell id -g) bin lib .shards 2>/dev/null || true

cli-build: ## Compile the host CLI from cli/ (static, in Docker)
	$(CLI_RUN) '$(CLI_SHARDS) && shards build voipappz --release --static --no-debug; s=$$?; $(CLI_CHOWN); exit $$s'

# The NODE binary. `-Dnode_runtime` drops the host-compose lifecycle surface
# (up/down/restart/status/deploy/portal…) — a genuinely different program,
# which is why it is a separate target and a separate release asset. `shards
# build` has no -o, so the output is renamed afterwards; cli/bin/voipappz is
# the node one until `make build` rebuilds the host one.
cli-node-build: ## Compile the -Dnode_runtime CLI (what the node image carries)
	$(CLI_RUN) '$(CLI_SHARDS) && shards build voipappz --release --static --no-debug -Dnode_runtime && mv bin/voipappz bin/voipappz-node; s=$$?; $(CLI_CHOWN); exit $$s'

cli-test: ## The CLI spec suite (in Docker)
	$(CLI_RUN) '$(CLI_SHARDS) && crystal spec --no-color; s=$$?; $(CLI_CHOWN); exit $$s'

# The binary every consumer runs. cli/bin/voipappz is the compiler's output;
# bin/voipappz is the one the mothership's Makefile, its SIP suites and its ISO
# bake copy from this checkout when it sits beside theirs.
build: cli-build ## Build the host CLI binary at bin/voipappz
	@mkdir -p bin
	@cp cli/bin/voipappz bin/voipappz
	@chmod +x bin/voipappz
	@echo "cli binary: $$(./bin/voipappz --version)"

# File target: consumers build ONCE when the binary is absent instead of
# recompiling on every call. `make build` forces a refresh.
bin/voipappz:
	$(MAKE) build

#   make install-cli                      # this checkout, building it if needed
#   make install-cli PREFIX=~/.local/bin  # no sudo
#   make install-cli ARGS=--release       # the published binary instead
install-cli: ## Put the voipappz CLI on PATH (PREFIX=/usr/local/bin)
	@PREFIX="$(if $(PREFIX),$(PREFIX),/usr/local/bin)" sh scripts/install-cli.sh $(ARGS)

# Exactly the "Shell" job of .github/workflows/ci.yml. shellcheck runs from
# its container when it is not installed, so this needs nothing but docker.
check:
	test -x install.sh
	sh -n install.sh
	dash -n install.sh
	sh -n scripts/install-cli.sh && dash -n scripts/install-cli.sh
	bash -n tests/clean-runner.sh tests/test-install.sh tests/unit.sh tests/two-pbx.sh
	$(MAKE) --no-print-directory shellcheck
	git diff --check
	test -z "$$(find tests -type f -name '*.py' -print -quit)"
	! grep -Eq 'python(3)?' install.sh
	bash tests/unit.sh
	@printf '$(B)check green$(R)\n'

SHELLCHECK_FILES = install.sh scripts/install-cli.sh tests/clean-runner.sh tests/test-install.sh tests/unit.sh tests/two-pbx.sh

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
test:
	@test -n "$${VA_REGISTRY_USER:-}" && test -n "$${VA_REGISTRY_TOKEN:-}" || { printf '$(B)export VA_REGISTRY_USER and VA_REGISTRY_TOKEN$(R) (Docker Hub, read access to nirlevi/va-crystal)\n'; exit 1; }
	tests/test-install.sh $(MOTHERSHIP_DIR)
