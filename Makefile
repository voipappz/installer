# Developer entry point for the VoIPAppz node installer. `make` lists targets.
# The product is one POSIX script, install.sh; everything here exists to check
# it, run it, and test it the way GitHub Actions does.
#
# Safe defaults, applied to every recipe below:
#   bash, not /bin/sh   -- the recipes use $(...), pipes and [ ] together
#   -e                  -- a failing command fails the target instead of the
#                          recipe carrying on and reporting success
#   -o pipefail         -- ... including a failure in the middle of a pipe
#   no builtin rules    -- nothing here compiles a .c from a .o
# `-u` is deliberately NOT set: VA_REGISTRY_USER and friends are legitimately
# unset and the recipes test for that.
SHELL       := /usr/bin/env bash
.SHELLFLAGS := -e -o pipefail -c
MAKEFLAGS   += --no-print-directory --no-builtin-rules --no-builtin-variables
.SUFFIXES:
.DELETE_ON_ERROR:

.DEFAULT_GOAL := help
# Every target in one place so check-make can prove each still has a rule.
# Add a target: add it here.
PHONY_TARGETS := help check check-make shellcheck test install \
                 up down logs health cli node-preflight \
                 build cli-build cli-node-build cli-test install-cli
.PHONY: $(PHONY_TARGETS)

# ONE list, generated from the `##` comments on the rules themselves, so it can
# never drift from what the Makefile actually does. Every target appears --
# nothing hidden -- grouped by the `##@` section it lives under.
help: ## Show this help
	@printf '\n\033[1mvoipappz/installer\033[0m — one script that installs a VA-Crystal voip node\n'
	@awk 'BEGIN { FS = ":.*## "; pad = "                              " } \
	     /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z0-9_\/-]+:.*## / { \
	       desc = $$2; label = $$1; \
	       if (match(desc, /^\[[^]]*\] /)) { label = label " " substr(desc, 1, RLENGTH - 1); desc = substr(desc, RLENGTH + 1) } \
	       printf "  \033[36m%s\033[0m%s %s\n", label, substr(pad, 1, 24 - length(label)), desc \
	     }' $(firstword $(MAKEFILE_LIST))
	@printf '\n\033[2mdocs: README.md (operators)  DEVELOPMENT.md (developers)  CLAUDE.md (engineering notes)\033[0m\n\n'

##@ Check

# Exactly the "Shell" job of .github/workflows/ci.yml. shellcheck runs from its
# container when it is not installed, so this needs nothing but docker.
check: ## Everything CI runs first: syntax, shellcheck, clean diff, no python, unit tests
	test -x install.sh
	sh -n install.sh
	dash -n install.sh
	sh -n scripts/install-cli.sh && dash -n scripts/install-cli.sh
	bash -n tests/clean-runner.sh tests/test-install.sh tests/unit.sh tests/two-pbx.sh
	$(MAKE) shellcheck
	$(MAKE) check-make
	git diff --check
	test -z "$$(find tests -type f -name '*.py' -print -quit)"
	! grep -Eq 'python(3)?' install.sh
	bash tests/unit.sh
	@printf '\033[1mcheck green\033[0m\n'

SHELLCHECK_FILES = install.sh scripts/install-cli.sh tests/clean-runner.sh \
                   tests/test-install.sh tests/unit.sh tests/two-pbx.sh

shellcheck: ## ShellCheck every script (in docker when it is not installed)
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck $(SHELLCHECK_FILES); \
	else \
	  docker run --rm -v "$(CURDIR):/w:ro" -w /w koalaman/shellcheck:stable \
	    $(SHELLCHECK_FILES); \
	fi

# A .PHONY target with no rule silently does nothing, so a deleted rule looks
# like a working `make check` that skips steps.
check-make: ## Fail if any .PHONY target has no rule (CI runs this)
	@missing=""; \
	 for t in $(PHONY_TARGETS); do \
	   grep -qE "^$$t:" $(firstword $(MAKEFILE_LIST)) || missing="$$missing $$t"; \
	 done; \
	 if [ -n "$$missing" ]; then \
	   echo "Makefile: .PHONY targets with no rule:$$missing"; exit 1; \
	 fi; \
	 echo "check-make: all $(words $(PHONY_TARGETS)) targets have a rule"

# The "Clean install + real mothership" job, minus tests/clean-runner.sh (which
# purges Docker and refuses to run outside GitHub Actions). The mothership is
# DOWNLOADED as the tarball of voipappz/mothership, the way its own installer
# fetches it — the repository is private since 2026-09-04, so that download
# needs MOTHERSHIP_TOKEN (or GH_TOKEN). Nothing is cloned; pass MOTHERSHIP_DIR=…
# only to test against a local checkout. It creates a system user and writes
# /opt/voipappz-ci — run it on a throwaway VM, never on a workstation you care
# about.
test: ## [MOTHERSHIP_DIR=…] The integration test against a real mothership — DISPOSABLE HOST ONLY
	@test -n "$${VA_REGISTRY_USER:-}" && test -n "$${VA_REGISTRY_TOKEN:-}" || { \
	  printf '\033[1mexport VA_REGISTRY_USER and VA_REGISTRY_TOKEN\033[0m (Docker Hub, read access to nirlevi/va-crystal)\n'; exit 1; }
	tests/test-install.sh $(MOTHERSHIP_DIR)

##@ Install a node

# Sibling checkout on a workstation, for ARCHIVE=latest only.
VA_CRYSTAL_DIR ?= $(abspath $(CURDIR)/../va-crystal)
# The newest archive `make s3-archive` wrote in va-crystal, if any.
NEWEST_ARCHIVE  = $(lastword $(sort $(wildcard $(VA_CRYSTAL_DIR)/ci/build/va-crystal-node-*.tar.gz)))

# ONE install target, because there is one action. The image source is a flag,
# not a target of its own — install.sh already validates all three:
#
#   make install                                 S3: the newest published image archive
#   make install SOURCE=dockerhub                pull, with VA_REGISTRY_USER + VA_REGISTRY_TOKEN
#   make install ARCHIVE=/path/img.tar.gz        load a docker-save archive (path or http(s) URL)
#   make install ARCHIVE=latest                  ... the newest one in ../va-crystal/ci/build
#   make install REGISTER=0                      a node with no mothership; register it later
#
# NO WIZARD. install.sh asks which source to use only when nothing chose one;
# a SOURCE is always chosen here, so `make install` never asks — it takes the
# same S3 default the prompt offers as [2]. Naming an ARCHIVE selects it.
#
# Everything else is an environment variable (README.md's "Useful controls"):
# VA_API_URL=… VA_CONFIG=./va.yaml make install
SOURCE ?= $(if $(ARCHIVE),archive,s3)

install: ## [SOURCE=s3|dockerhub] [ARCHIVE=file|latest] [REGISTER=0] Run install.sh from this working tree
	@archive='$(ARCHIVE)'; \
	 if [ "$$archive" = latest ]; then \
	   archive='$(NEWEST_ARCHIVE)'; \
	   if [ -z "$$archive" ]; then \
	     printf 'no archive in \033[1m$(VA_CRYSTAL_DIR)/ci/build\033[0m — run `make s3-archive` there, or pass ARCHIVE=/path/file.tar.gz\n'; \
	     exit 1; \
	   fi; \
	   printf 'loading %s\n' "$$archive"; \
	 fi; \
	 VA_IMAGE_SOURCE='$(SOURCE)' VA_IMAGE_ARCHIVE="$$archive" \
	   sh install.sh $(if $(filter 0,$(REGISTER)),--no-register)

##@ The installed node

# Thin on purpose: each is the docker command an operator would type, so
# nothing here can drift from what the node actually does. Lifecycle is
# Docker's (`--restart unless-stopped`), and every node operation is the CLI's,
# inside the image.
NODE        ?= va-voip
INSTALL_DIR ?= /opt/voipappz

# Checked BEFORE anything destructive. `up` removes the container to recreate
# it; discovering only afterwards that the .env is unreadable leaves the host
# with no node at all. That happened once — it does not happen again.
#
# install.sh writes .env mode 0600 owned by root, on purpose (it holds the
# FreeSWITCH and licence secrets), so `make up` on a real /opt/voipappz install
# needs sudo. Say so instead of failing halfway.
node-preflight: ## Refuse early when INSTALL_DIR holds no readable install (up depends on it)
	@test -r $(INSTALL_DIR)/.env || { \
	  printf 'cannot read \033[1m$(INSTALL_DIR)/.env\033[0m — install.sh writes it 0600, owned by root.\n  run: \033[1msudo make up INSTALL_DIR=$(INSTALL_DIR)\033[0m\n'; exit 1; }
	@test -r $(INSTALL_DIR)/config/va.yaml || { \
	  printf 'no \033[1m$(INSTALL_DIR)/config/va.yaml\033[0m — nothing is installed there. run: \033[1mmake install\033[0m\n'; exit 1; }

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
up: node-preflight ## Recreate and start the node, showing the whole docker run
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

logs: ## Follow it (kamailio + FreeSWITCH + node, interleaved)
	docker logs -f --tail 100 $(NODE)

health: ## The 16-check verdict, from the CLI inside the image
	docker exec $(NODE) voipappz health

cli: ## [ARGS=…] The in-image CLI: make cli ARGS="sbc egress status"
	@docker inspect -f '{{.State.Running}}' $(NODE) >/dev/null 2>&1 \
	  || { echo "$(NODE) is not running — start it with: make up"; exit 1; }
	docker exec -it $(NODE) voipappz $(ARGS)

##@ The CLI binary

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

# The binary every consumer runs. cli/bin/voipappz is the compiler's output;
# bin/voipappz is the one the mothership's Makefile, its SIP suites and its ISO
# bake copy from this checkout when it sits beside theirs.
build: cli-build ## Build the host CLI binary at bin/voipappz
	@mkdir -p bin
	@cp cli/bin/voipappz bin/voipappz
	@chmod +x bin/voipappz
	@echo "cli binary: $$(./bin/voipappz --version)"

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

# File target: consumers build ONCE when the binary is absent instead of
# recompiling on every call. `make build` forces a refresh.
bin/voipappz:
	$(MAKE) build

#   make install-cli                        # this checkout, building it if needed
#   make install-cli PREFIX=~/.local/bin    # no sudo
#   make install-cli RELEASE=1              # the published binary instead
#   make install-cli RELEASE=v0.2.0         # ... a specific tag
install-cli: ## [PREFIX=dir] [RELEASE=1|v0.2.0] Put the voipappz CLI on PATH
	@PREFIX="$(if $(PREFIX),$(PREFIX),/usr/local/bin)" sh scripts/install-cli.sh \
	  $(if $(RELEASE),--release $(filter-out 1,$(RELEASE)))
