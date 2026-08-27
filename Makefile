# Developer entry point for the VoIPAppz node installer.  `make` lists targets.
# The product is one POSIX script, install.sh; everything here exists to
# check it, run it, and test it the way GitHub Actions does.

.DEFAULT_GOAL := help
.PHONY: help check install install-archive test shellcheck iso iso-validate

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
	@printf '  $(C)%-16s$(R) %s\n' \
	  'check'           'what CI runs first: syntax, shellcheck, clean diff, no python, unit tests' \
	  'install'         'run install.sh from this checkout (asks sudo, image source, node, mothership, token)' \
	  'install-archive' 'the same, loading the newest ../va-crystal/ci/build/*.tar.gz (ARCHIVE=… to pick one)' \
	  'test'            'the integration test: real mothership booted from the node image — DISPOSABLE HOST ONLY' \
	  'iso-validate'    'packer validate the offline installer ISO template (no packer needed)' \
	  'iso'             'cut the offline installer ISO: make iso IMAGE_VERSION=… RELEASE_VERSION=… (packer + xorriso)'
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

# The "Clean install + real mothership" job, minus tests/clean-runner.sh
# (which purges Docker and refuses to run outside GitHub Actions). The
# mothership is booted from the /stack inside the node image — nothing is
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
