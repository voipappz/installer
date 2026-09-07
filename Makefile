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
PHONY_TARGETS := help check check-make test get install \
                 setup verify up down logs health cli \
                 build cli-test install-cli
.PHONY: $(PHONY_TARGETS)

# ONE list, generated from the `##` comments on the rules themselves, so it can
# never drift from what the Makefile actually does. Every target appears --
# nothing hidden -- grouped by the `##@` section it lives under.
help: ## Show this help
	@printf '\n\033[1mvoipappz/installer\033[0m — one script that installs a VA-Crystal voip node\n'
	@awk 'BEGIN { FS = ":.*## "; W = 24; pad = sprintf("%" W "s", "") } \
	     /^##@ / { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	     /^[a-zA-Z0-9_\/-]+:.*## / { \
	       desc = $$2; label = $$1; \
	       if (match(desc, /^\[[^]]*\] /)) { label = label " " substr(desc, 1, RLENGTH - 1); desc = substr(desc, RLENGTH + 1) } \
	       if (length(label) < W) \
	         printf "  \033[36m%s\033[0m%s%s\n", label, substr(pad, 1, W - length(label)), desc; \
	       else \
	         printf "  \033[36m%s\033[0m\n  %s%s\n", label, pad, desc \
	     }' $(firstword $(MAKEFILE_LIST))
	@printf '\n\033[2mdocs: README.md (operators)  DEVELOPMENT.md (developers)  CLAUDE.md (engineering notes)\033[0m\n\n'

##@ Check

# Exactly the "Shell" job of .github/workflows/ci.yml. shellcheck runs from its
# container when it is not installed, so this needs nothing but docker.
SCRIPTS = install.sh scripts/common.sh scripts/setup.sh scripts/verify.sh scripts/up.sh \
          scripts/down.sh scripts/logs.sh scripts/health.sh scripts/cli.sh \
          scripts/install-cli.sh tests/clean-runner.sh \
          tests/test-install.sh tests/unit.sh tests/two-pbx.sh

check: ## Everything CI runs first: syntax, shellcheck, clean diff, no python, unit tests
	@printf '\n\033[1m1. syntax\033[0m — every script parses under the shell that runs it\n'
	test -x install.sh
	sh -n install.sh
	dash -n install.sh
	for s in scripts/*.sh; do sh -n "$$s" && dash -n "$$s"; done
	bash -n tests/clean-runner.sh tests/test-install.sh tests/unit.sh tests/two-pbx.sh
	@printf '\n\033[1m2. shellcheck\033[0m — the lint CI runs, on all $(words $(SCRIPTS)) scripts\n'
	@if command -v shellcheck >/dev/null 2>&1; then \
	  echo "shellcheck $(SCRIPTS)"; shellcheck $(SCRIPTS); \
	else \
	  echo "no shellcheck on this host — running it from Docker (the first run pulls ~4MB)"; \
	  echo "  to skip the pull: sudo apt-get install -y shellcheck"; \
	  docker run --rm -v "$(CURDIR):/w:ro" -w /w koalaman/shellcheck:stable $(SCRIPTS); \
	fi
	@echo "shellcheck: $(words $(SCRIPTS)) scripts clean"
	@printf '\n\033[1m3. this Makefile\033[0m — no .PHONY target lost its rule\n'
	$(MAKE) check-make
	@printf '\n\033[1m4. the diff\033[0m — no trailing whitespace or conflict markers\n'
	git diff --check
	@printf '\n\033[1m5. no python\033[0m — the installer and its tests are shell, deliberately\n'
	test -z "$$(find tests -type f -name '*.py' -print -quit)"
	! grep -Eq 'python(3)?' install.sh
	@printf '\n\033[1m6. unit tests\033[0m — install.sh'"'"'s own functions, and the scripts/ contract\n'
	bash tests/unit.sh
	@printf '\n\033[1mcheck green\033[0m — this is the "Shell" CI job; the integration job is `make test`\n\n'

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
test: ## [MOTHERSHIP_DIR=dir] The integration test against a real mothership — DISPOSABLE HOST ONLY
	@test -n "$${VA_REGISTRY_USER:-}" && test -n "$${VA_REGISTRY_TOKEN:-}" || { \
	  printf '\033[1mexport VA_REGISTRY_USER and VA_REGISTRY_TOKEN\033[0m (Docker Hub, read access to nirlevi/va-crystal)\n'; exit 1; }
	tests/test-install.sh $(MOTHERSHIP_DIR)

##@ Get the image, then install it

# Sibling checkout on a workstation, for ARCHIVE=latest only.
VA_CRYSTAL_DIR ?= $(abspath $(CURDIR)/../va-crystal)
# The newest archive `make s3-archive` wrote in va-crystal, if any.
NEWEST_ARCHIVE  = $(lastword $(sort $(wildcard $(VA_CRYSTAL_DIR)/ci/build/va-crystal-node-*.tar.gz)))

# GET THE IMAGE, THEN INSTALL IT. Two steps because they fail for different
# reasons and at different times: getting it needs the network and a gigabyte,
# installing it needs a mothership and an Account. `get` ends by RUNNING the
# image's CLI, so a machine is only "prepared" once the image is proved to
# work; `install` then never touches the network for it, so a re-install
# cannot re-download what the host already has.
#
#   make get                          S3: the newest published image archive
#   make get dockerhub                pull, with VA_REGISTRY_USER + VA_REGISTRY_TOKEN
#   make get ARCHIVE=/path.tar.gz     docker load a docker-save archive: a path or an http(s) URL
#   make get ARCHIVE=latest           ... the newest one in ../va-crystal/ci/build
#
# NO WIZARD, either way. install.sh asks which source to use only when nothing
# chose one: `get` always names a source (the S3 default is the same one its
# prompt offers as [2]) and `install` names `local`, which never fetches and
# says plainly when the image is missing.
#
# The source is a bare word, not SOURCE=word, so each name below is also a
# harmless phony goal — `make get dockerhub` runs `get` then the no-op
# `dockerhub`. SOURCE=word (used by CI's `make -n` smoke tests) still works.
IMAGE_SOURCES := s3 dockerhub archive local
.PHONY: $(IMAGE_SOURCES)
$(IMAGE_SOURCES): ; @:
SOURCE ?= $(or $(filter $(IMAGE_SOURCES),$(MAKECMDGOALS)),$(if $(ARCHIVE),archive,s3))

get: ## [s3|dockerhub] [ARCHIVE=file|url|latest] Get the node image and prove it runs
	@archive='$(ARCHIVE)'; \
	 if [ "$$archive" = latest ]; then \
	   archive='$(NEWEST_ARCHIVE)'; \
	   if [ -z "$$archive" ]; then \
	     printf 'no archive in \033[1m$(VA_CRYSTAL_DIR)/ci/build\033[0m — run `make s3-archive` there, or pass ARCHIVE=/path/file.tar.gz\n'; \
	     exit 1; \
	   fi; \
	   printf 'loading %s\n' "$$archive"; \
	 fi; \
	 VA_IMAGE_SOURCE='$(SOURCE)' VA_IMAGE_ARCHIVE="$$archive" sh install.sh --image-only

# Everything else is an environment variable (README.md's "Useful controls"):
# VA_API_URL=… VA_CONFIG=./va.yaml make install
install: ## [REGISTER=0] Install the node from the image on this host (make get first)
	VA_IMAGE_SOURCE=local sh install.sh $(if $(filter 0,$(REGISTER)),--no-register)

##@ The node on this machine

# ONE COMMAND, ONE SCRIPT. Every target below is a file in scripts/ — the
# recipe only names it. Nothing about how a node is set up, started, stopped or
# asked a question lives in this Makefile, so `make up` and the command an
# operator types by hand cannot drift apart, and each script says in its own
# header what it does and refuses to do.
#
# These drive the node you are working on, HERE: scripts/setup.sh writes ./.env
# and ./config/va.yaml, and the rest read them. install.sh is the other thing —
# it installs and registers a node into $INSTALL_DIR on a real host.
#
#   make setup    the wizard: ./.env + ./config/va.yaml
#   make up       start the node from those two files
#   make down     stop it, keeping its volume
#   make logs     follow it
#   make health   its own verdict, from the CLI in the image
#   make cli      any other CLI command, in the image

# SHOW THE WHOLE COMMAND, ./.env INCLUDED. `make up` prints the line it runs
# with every value that decided it spelled out:
#
#   $ make up
#   VA_VOIP_IMAGE=nirlevi/va-crystal:node sh scripts/up.sh
#
# — so the tag comes from ./.env, and you can still see it, copy the line and
# run it yourself. A value you set on the command line or export in your shell
# wins over the file (the same rule the scripts follow) and is shown the same
# way; a value nothing names is not invented here.
#
# NEVER A SECRET. Only the four names below are ever expanded onto a command
# line, and none of them is a credential: the FreeSWITCH, licence and API
# secrets stay in ./.env, are read by the script itself, and are masked even in
# the docker run it prints.
NODE_VARS = VA_VOIP_IMAGE VA_ENV_FILE VA_CONFIG NODE TAIL
env_file  = $(if $(VA_ENV_FILE),$(VA_ENV_FILE),.env)
env_value = $(strip $(shell test -f $(env_file) && sed -n 's/^$(1)=//p' $(env_file) | tail -1 | tr -d '\042\047'))
node_arg  = $(if $(filter command\ line environment,$(origin $(1))),$(1)=$($(1)),\
              $(if $(call env_value,$(1)),$(1)=$(call env_value,$(1))))
NODE_ARGS = $(strip $(foreach v,$(NODE_VARS),$(call node_arg,$(v))))

setup: ## The wizard: write ./.env and ./config/va.yaml
	$(NODE_ARGS) sh scripts/setup.sh

# BEFORE the start button. The image halts on a bad va.yaml or a missing
# secret, so its report lands in the log of a container that is already gone;
# this asks the same questions here, names every problem at once, and starts
# nothing. Verifying an INSTALLED node is the same command with its two files:
#   VA_ENV_FILE=/opt/voipappz/.env VA_CONFIG=/opt/voipappz/config/va.yaml make verify
verify: ## Check ./.env and ./config/va.yaml against what the image requires
	$(NODE_ARGS) sh scripts/verify.sh

up: ## Start the node here from ./.env and ./config/va.yaml
	$(NODE_ARGS) sh scripts/up.sh

down: ## Stop it, keeping its identity and its kamailio volume
	$(NODE_ARGS) sh scripts/down.sh

logs: ## [TAIL=n] Follow it (kamailio + FreeSWITCH + node, interleaved)
	$(NODE_ARGS) sh scripts/logs.sh

health: ## The node's own health verdict, from the CLI inside the image
	$(NODE_ARGS) sh scripts/health.sh

cli: ## [ARGS=cmd] The in-image CLI: make cli ARGS="sbc egress status"
	@$(NODE_ARGS) sh scripts/cli.sh $(ARGS)

##@ The CLI binary

# cli/ is the voipappz CLI's SOURCE, moved here from the mothership on
# 2026-09-03 so it can be public while the mothership is not.
#
# ONE SOURCE, ONE BINARY, since 2026-09-07. It used to be two: a host build and
# a `-Dnode_runtime` build with the compose lifecycle commands compiled out.
# The CLI already decides at RUNTIME where it is — Services.available? for a
# catalog, Docker.local_exec? for the inside of the node image — so the flag
# was a second mechanism answering a question already answered, and a second
# artifact to build, release, pin and prove. va-crystal bakes this same binary
# into nirlevi/va-crystal:node. install.sh never builds or fetches it: it only
# runs the copy inside the image.
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
# bake copy from this checkout when it sits beside theirs — and the one
# va-crystal's image build downloads from this repo's releases.

# NO CRYSTAL, NO DOCKER, NO WAIT: `make build RELEASE=…` DOWNLOADS the binary
# instead of compiling one, through the same scripts/install-cli.sh that puts
# it on PATH — it just installs into ./bin here. Same artifact: release.yml
# links it from this source, in the image named above.
#
#   make build                 compile it here (docker, ~1 min)
#   make build RELEASE=1       the newest tagged release
#   make build RELEASE=latest  the rolling `latest` prerelease — every push to main
#   make build RELEASE=v0.2.0  a specific tag
#
# Use it when you only need to RUN the CLI (the SIP suites, the ISO bake, a
# laptop); compile when you are CHANGING it, because a download cannot contain
# your edit.
build: ## [RELEASE=1|latest|v0.2.0] Build the CLI binary at bin/voipappz (static, in Docker; RELEASE downloads it)
ifdef RELEASE
	@PREFIX='$(CURDIR)/bin' sh scripts/install-cli.sh --release $(filter-out 1,$(RELEASE))
else
	$(CLI_RUN) '$(CLI_SHARDS) && shards build voipappz --release --static --no-debug; s=$$?; $(CLI_CHOWN); exit $$s'
	@mkdir -p bin
	@cp cli/bin/voipappz bin/voipappz
	@chmod +x bin/voipappz
	@echo "cli binary: $$(./bin/voipappz --version)"
endif

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
