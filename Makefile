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
                 build cli-test install-cli \
                 iso iso-payload iso-clean iso-deliver iso-ship iso-node-install \
                 iso-upload image-cloud image-ami image-virtualbox \
                 image-disk-direct image-disk-from-iso image-validate \
                 act-packer act-iso act-iso-base act-guard \
                 iso-release
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
          scripts/install-cli.sh scripts/node-images.sh \
          scripts/check-packer-targets.sh scripts/iso-upload.sh \
          scripts/extract-casper.sh tests/clean-runner.sh \
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
	@printf '\n\033[1m7. packer\033[0m — every -only= target names a source packer declares\n'
	sh scripts/check-packer-targets.sh
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

# WHAT `up` READS, and the default of each:
#
#   VA_CONFIG    ./config/va.yaml   the node file, mounted read-only at
#                                   /tmp/node.yaml and parsed at every boot by
#                                   the va-env oneshot -- so a change to an
#                                   address here needs a restart, not a rebuild
#   VA_ENV_FILE  ./.env             the secrets, passed as environment and never
#                                   written into va.yaml (it is world-readable)
#
# THE NODE RUNS ON THE HOST'S NETWORK AND TAKES ITS ADDRESS FROM va.yaml. That
# address must be one this machine holds and keeps: kamailio's #!substdef
# listeners, both sofia profiles, every RTP leg and the eventsocket bind it once
# at boot. If it changes underneath a running node, the node keeps the socket it
# already has and its own health checks stay green over it -- while nothing on
# the wire can reach it and no phone can register. Pin it with a DHCP
# reservation. See va.yaml.host.example.
up: ## [VA_CONFIG=f] [VA_ENV_FILE=f] Start the node from those two files
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


##@ Node media (ISO)
#
# A bootable, offline Ubuntu installer carrying docker, the SIP tooling, the
# CLI and the node container image. Operator instructions ship beside the disc
# as packer/node-installer.html; the build's own notes are packer/README.md.
#
# THIS MOVED HERE FROM THE MOTHERSHIP REPO (2026-09). It always cut NODE media
# — the mothership's Makefile said so in a comment for weeks — but it lived
# beside the mothership's docker-compose.yaml and took its image list from it.
# Here the list is scripts/node-images.sh: one image, the one scripts/up.sh
# runs. That is the whole reason the payload is a fraction of what it was.
#
#   make iso-payload      # ONCE — pull and save the node image
#   make iso              # cut the disc
#   make iso QUICK=1      # skip package re-resolution; touches the network not at all
#   make iso ISO_DEST=/mnt/d/isos
DOCKER ?= docker

# Where the finished ISO is copied to. UNSET means "leave it in
# packer/build/iso/", which is the answer for anyone who is not the person this
# used to be hardcoded for — a Windows path under one developer's home
# directory is not a default a public repository can carry.
ISO_DEST ?=
ISO_NETWORK ?= autoinstall/network.default.yaml

# Use an image already in the local layer store instead of pulling it — for
# cutting a disc around an image built by hand (`make -C ../va-crystal
# node-image`) that exists nowhere else yet, where a pull would fail or, worse,
# quietly replace it with an older published one.
VOIPAPPZ_LOCAL_IMAGES ?=
export VOIPAPPZ_LOCAL_IMAGES

# THE WHOLE CHAIN, for a disc anyone is going to boot: compile the CLI from
# source, run its specs, and only then stage a payload and cut media around it.
#
# `make iso` on its own bakes whatever binary happens to sit in bin/ — which
# may be a release someone downloaded, or a build from a branch, proved by
# nothing. A disc is the one artifact nobody can patch afterwards: it goes to a
# machine with no route out, and the next chance to fix the binary on it is a
# site visit.
#
#   make iso-release                       # pins nothing: bin/voipappz is `latest`
#   make iso-release CLI_VERSION=v0.2.0    # ... and the disc records that tag
iso-release: build cli-test iso-payload iso ## Build the CLI, run its specs, then cut a disc around it

# NO SIP ROUND TRIP HERE. The scenarios need SIPp, and driving real calls
# belongs to the node image's own build in ../va-crystal — a disc is media
# around a binary, and making it wait on a call generator puts two projects'
# test infrastructure in the path of cutting one.

# The expensive half: the node image saved into one archive. Needed ONCE —
# re-runs skip the save unless the resolved digest actually moved.
iso-payload: ## Pull and save the node image into the offline payload
	packer/scripts/stage-payload.sh images

# QUICK=1 skips the package re-resolution — for an autoinstall or script change.
# It touches the network not at all. A flag rather than a second target: same
# action, same output, one knob.
# ISO_VARS passes anything else through to Packer — `-var with_images=false`
# for a disc with no container image on it, which is what CI cuts: the payload
# images are private and gigabytes, and everything a cut can get wrong (the
# autoinstall, the package closure, the remaster, the boot records) is in the
# rest of the disc.
ISO_VARS ?=

iso: ## [QUICK=1] Cut the offline installer ISO — also ISO_DEST= ISO_NETWORK= ISO_VARS=
	VOIPAPPZ_ISO_DEST="$(ISO_DEST)" packer/build.sh build \
		$(if $(ISO_DEST),-var 'dest_dir=$(ISO_DEST)') -var 'network=$(ISO_NETWORK)' \
		$(if $(QUICK),-var 'refresh_packages=false') $(ISO_VARS) \
		-only='voipappz-os.null.iso' .

# The cut ISOs and staging tree, NOT the payload (an hour to re-fetch).
# In a container because Packer ran as root and owns the files.
iso-clean: ## Remove the cut ISOs and staging tree (keeps the payload)
	$(DOCKER) run --rm -v "$(CURDIR)/packer:/w" alpine:3.22 \
		sh -c 'rm -rf /w/build/iso /w/build/msgtest /w/build/boottest'

# --- delivering a cut ISO
#
# Packer owns the SSH (`voipappz-deliver`, a null source with a real
# communicator), so there is no ssh/scp wrapper here to keep in step with it.
#
#   make iso-deliver ISO_HOST=192.168.1.1 ISO_PASSWORD=secret
#   make iso-deliver ISO_HOST=node20 ISO_KEY=~/.ssh/id_ed25519 INSTALL=1
#   make iso-ship    ISO_HOST=node20 ISO_KEY=~/.ssh/id_ed25519   # cut, then send
#
# A key beats a password: the password lands in shell history and the process
# list, and `deliver_password` is only marked sensitive INSIDE Packer.
ISO_HOST ?=
ISO_USER ?= voipappz
ISO_KEY ?=
ISO_PASSWORD ?=
ISO_REMOTE_DIR ?= /home/$(ISO_USER)/isos

# BOTH may travel, and for a key-authenticated install both are NEEDED: the key
# authenticates SSH, the password answers sudo. Packer's "only one of
# ssh_agent_auth, ssh_password, and ssh_private_key_file" is resolved inside the
# HCL — ssh_password is nulled the moment a key is named — so suppressing one
# here is not necessary.
ISO_AUTH_VARS = $(if $(ISO_KEY),-var 'deliver_key=$(ISO_KEY)') \
	$(if $(ISO_PASSWORD),-var 'deliver_password=$(ISO_PASSWORD)')

# INSTALL=1 also installs: offline apt repo off the disc, packages, docker,
# `docker load` of the node image, CLI on PATH. Then one command short:
# `voipappz bootstrap`. It CHANGES the target where a plain deliver only copies
# to it, hence a flag you have to type and deliver_install=false by default.
# Needs root there: passwordless sudo, or ISO_PASSWORD (used for sudo too).
iso-deliver: ## [ISO_HOST=x] Send the newest ISO to a host — ISO_KEY=|ISO_PASSWORD=, INSTALL=1 also installs
	@test -n "$(ISO_HOST)" || { \
		echo "!! set ISO_HOST=<target>   e.g. make iso-deliver ISO_HOST=192.168.1.1 ISO_KEY=~/.ssh/id_ed25519" >&2; \
		exit 1; }
	@test -n "$(ISO_KEY)$(ISO_PASSWORD)" || { \
		echo "!! set ISO_KEY=<path> or ISO_PASSWORD=<pw>" >&2; exit 1; }
	packer/build.sh build -only='voipappz-deliver.null.deliver' \
		-var 'deliver_host=$(ISO_HOST)' \
		-var 'deliver_user=$(ISO_USER)' \
		-var 'deliver_dir=$(ISO_REMOTE_DIR)' \
		$(if $(INSTALL),-var 'deliver_install=true') \
		$(ISO_AUTH_VARS) \
		.

# Sequenced in the recipe, not as two prerequisites: ordering those needs
# `.NOTPARALLEL: <target>`, honoured only on GNU Make >= 4.4 — on 4.3 it
# serialises the whole file instead, and `make -j` would send a stale ISO.
iso-ship: ## [ISO_HOST=x] Cut the ISO, then send it (iso + iso-deliver)
	$(MAKE) iso
	$(MAKE) iso-deliver

# Install onto a machine that ALREADY HAS the disc — no transfer at all:
#
#   make iso-node-install ISO_HOST=192.168.137.10 ISO_PASSWORD=secret
#
# packer/scripts/ssh-install.sh uploads and runs the same
# packer/scripts/remote-install.sh the Packer build does. Re-sending 8.4GB to
# run a five-minute install is the expensive way to do nothing (~15 min on a
# slow link). The target needs no internet; ssh/sshpass/python3 stay in the
# container.
iso-node-install: ## Install onto a machine that already has the disc — ISO_HOST=
	@test -n "$(ISO_HOST)" || { \
		echo "!! set ISO_HOST=<target>   e.g. make iso-node-install ISO_HOST=192.168.137.10 ISO_PASSWORD=secret" >&2; \
		exit 1; }
	@test -n "$(ISO_KEY)$(ISO_PASSWORD)" || { \
		echo "!! set ISO_KEY=<path> or ISO_PASSWORD=<pw>" >&2; exit 1; }
	$(DOCKER) run --rm -v "$(CURDIR)/packer:/w" \
		$$([ -d "$$HOME/.ssh" ] && echo "-v $$HOME/.ssh:/root/.ssh:ro" || true) \
		--entrypoint bash voipappz-packer:local /w/scripts/ssh-install.sh \
		--host '$(ISO_HOST)' --user '$(ISO_USER)' --iso-dir '$(ISO_REMOTE_DIR)' \
		$(if $(ISO_KEY),--key '$(ISO_KEY)') \
		$(if $(ISO_PASSWORD),--password '$(ISO_PASSWORD)')

# Newest cut ISO to S3. Credentials from ~/.aws (mounted read-only) or the
# environment, never a file in the repo.
S3_BUCKET ?= voipappz-assets-il
S3_PREFIX ?= isos
S3_REGION ?= il-central-1

iso-upload: ## Upload the newest cut ISO to S3 — needs AWS credentials
	@DOCKER="$(DOCKER)" S3_BUCKET="$(S3_BUCKET)" S3_PREFIX="$(S3_PREFIX)" S3_REGION="$(S3_REGION)" \
		scripts/iso-upload.sh

##@ Disk images
#
# The five DISK sources in packer/voipappz.pkr.hcl — a disk only helps a
# hypervisor that imports one; `make iso` above cuts the media bare metal wants.
# All five share ONE `build` block, so none can drift from packer/scripts/bake.sh,
# and every declared source must be reachable from a target here —
# scripts/check-packer-targets.sh checks both directions.
#
# NOTE packer/README.md is blunt about this half: it has never been built. Treat
# every target below as unverified until one of them produces a disk.
#
#   make image-cloud CLI_VERSION=v1.2.3 STACK_SOURCE=release
STACK_SOURCE ?= local
CLI_VERSION  ?= latest
PACKER_VARS   = -var 'stack_source=$(STACK_SOURCE)' -var 'cli_version=$(CLI_VERSION)'

# Preferred: drives no installer, so the GRUB race cannot happen.
image-cloud: ## KVM disk from Canonical's cloud image — PREFER THIS. STACK_SOURCE= CLI_VERSION=
	packer/build.sh build -only='voipappz.qemu.voipappz' $(PACKER_VARS) .

# Costs money and runs IN EC2. Check credentials before Packer launches an
# instance — a build that dies on auth halfway still leaves billed resources.
image-ami: ## AWS AMI; needs credentials, and the bake runs in EC2 (costs money)
	@test -f "$$HOME/.aws/credentials" -o -n "$$AWS_ACCESS_KEY_ID" || { \
		echo "!! no AWS credentials — write ~/.aws/credentials or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" >&2; \
		exit 1; }
	packer/build.sh build -only='voipappz.amazon-ebs.voipappz' $(PACKER_VARS) .

# Needs VirtualBox ON THIS HOST — never WSL2, never CI, where it otherwise fails
# deep inside Packer talking about VBoxManage rather than the environment.
#
# `if`, not `grep ... && { ...; } || true`: under `-e` the && form fails the
# recipe on every MISS, which is the case that should proceed.
image-virtualbox: ## VirtualBox disk; VirtualBox must be on THIS host (never WSL2, never CI)
	@if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then \
		echo "!! image-virtualbox cannot run under WSL2 — VirtualBox must be on the host" >&2; \
		echo "   use 'make image-cloud' (qcow2 -> .vdi, imports natively)" >&2; \
		exit 1; \
	fi
	@command -v VBoxManage >/dev/null 2>&1 || { \
		echo "!! VBoxManage not found — VirtualBox must be installed on this host" >&2; exit 1; }
	packer/build.sh build -only='voipappz.virtualbox-iso.voipappz' $(PACKER_VARS) .

# Same ISO as image-disk-from-iso, but qemu boots the kernel directly so GRUB
# never runs and there is nothing to type — the deterministic answer to the race
# below. scripts/extract-casper.sh pulls vmlinuz+initrd out of the ISO.
CASPER = packer/cache/casper

image-disk-direct: ## KVM disk, kernel booted directly — deterministic, no GRUB. ISO_DIR=
	@DOCKER="$(DOCKER)" ISO_DIR="$(ISO_DIR)" CASPER="$(CASPER)" scripts/extract-casper.sh
	VOIPAPPZ_ISO_DIR="$(ISO_DIR)" packer/build.sh build \
		-only='voipappz.qemu.direct' $(PACKER_VARS) .

# FLAKY, not broken: keys typed before GRUB is listening go nowhere, the menu
# times out into the INTERACTIVE installer, and Packer waits out its whole
# ssh_timeout for an SSH server that never starts — so it presents as a hang.
# Prefer image-cloud, or image-disk-direct if it has to be this ISO. ISO_DIR is
# checked here rather than eight minutes in: the target mounts it at /iso.
image-disk-from-iso: ## KVM disk through the ISO installer — FLAKY, see the GRUB race. ISO_DIR=
	@test -n "$(ISO_DIR)" || { \
		echo "!! set ISO_DIR=<dir holding ubuntu-*-live-server-amd64.iso>" >&2; \
		echo "   e.g. make image-disk-from-iso ISO_DIR=packer/cache" >&2; exit 1; }
	VOIPAPPZ_ISO_DIR="$(ISO_DIR)" packer/build.sh build \
		-only='voipappz.qemu.installer' $(PACKER_VARS) .

image-validate: ## packer validate — writes nothing, builds no disk
	packer/build.sh validate .

##@ CI locally (act)
#
# The workflows on this machine, with nektos/act — .actrc holds the flags that
# are not optional (the runner images, and an EMPTY --env-file so act does not
# inject this repo's real .env into a job).
#
#   make act-packer     the templates validate — a minute, needs only Docker
#   make act-iso        cut a disc with no container image on it — ~20 minutes
#   act -j shell        the POSIX gates
#
# --bind for both (ACT_FLAGS): packer/build.sh runs its own `docker run -v`
# against the HOST daemon, so the workspace has to BE a host path. Without it
# act copies the workspace into the container, the mounts resolve to nothing on
# the host, and the build writes its ISO somewhere the job cannot see.
ACT ?= act
# --pull=false: act force-pulls the runner image on every run, and that fails
# outright when the workstation's cached Docker Hub login has expired —
# "authentication required - incorrect username or password", about an image
# that is already in the local store and needs no credential at all. GitHub
# runners pull anonymously; a stale local credential is an act-only failure.
# Append --pull=true to refresh it deliberately.
ACT_FLAGS ?= --bind --pull=false

act-guard:
	@command -v $(ACT) >/dev/null 2>&1 || { 		echo "!! act not found — https://github.com/nektos/act (curl -s https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- -b /usr/local/bin)" >&2; 		exit 1; }

act-packer: act-guard ## The media templates job locally (act): packer validate
	$(ACT) workflow_dispatch -j packer $(ACT_FLAGS) $(ARGS)

# workflow_dispatch, not push: the iso job is `if: workflow_dispatch` so that
# GitHub does not cut an 8GB disc on every commit. Under push act would skip it
# and report success having built nothing.
act-iso: act-iso-base act-guard ## The ISO job locally (act): cut an image-less disc and check it
	$(ACT) workflow_dispatch -j iso $(ACT_FLAGS) $(ARGS)

# The base ISO, once. The job caches it on GitHub (actions/cache); locally the
# cache does not exist, so a bare `act -j iso` would download 3GB on every run
# — and Packer's downloader does not resume, so an interrupted one starts over.
BASE_ISO = $(shell grep -oE 'ubuntu-[0-9.]+-live-server-amd64\.iso' packer/os-image.pkr.hcl | head -1)
act-iso-base: ## Fetch the base Ubuntu ISO into packer/cache (once, ~3GB, resumable)
	@test -n "$(BASE_ISO)" || { echo "!! could not read the base ISO name out of packer/os-image.pkr.hcl" >&2; exit 1; }
	@mkdir -p packer/cache
	@if [ -f "packer/cache/$(BASE_ISO)" ]; then 		echo "base ISO: packer/cache/$(BASE_ISO) ($$(du -h packer/cache/$(BASE_ISO) | cut -f1))"; 	else 		rel=$$(echo "$(BASE_ISO)" | sed -E 's/ubuntu-([0-9]+\.[0-9]+).*/\1/'); 		echo ">> fetching $(BASE_ISO) (~3GB, resumable)"; 		curl -fL -C - --retry 10 -o "packer/cache/$(BASE_ISO)" 			"https://releases.ubuntu.com/$$rel/$(BASE_ISO)"; 	fi
