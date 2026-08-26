# Developer entry point for the VoIPAppz node installer.  `make` lists targets.
# The product is one POSIX script, install.sh; everything here exists to
# check it, run it, and test it the way GitHub Actions does.

.DEFAULT_GOAL := help
.PHONY: help check install install-archive test shellcheck

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
	  'test'            'the integration test: real mothership booted from the node image — DISPOSABLE HOST ONLY'
	@printf '\n  $(D)docs: README.md (operators)  DEVELOPMENT.md (developers)  CLAUDE.md (engineering notes)$(R)\n\n'

# Exactly the "Shell" job of .github/workflows/ci.yml. shellcheck runs from
# its container when it is not installed, so this needs nothing but docker.
check:
	test -x install.sh
	sh -n install.sh
	dash -n install.sh
	bash -n tests/clean-runner.sh tests/test-install.sh tests/unit.sh
	$(MAKE) --no-print-directory shellcheck
	git diff --check
	test -z "$$(find tests -type f -name '*.py' -print -quit)"
	! grep -Eq 'python(3)?' install.sh
	bash tests/unit.sh
	@printf '$(B)check green$(R)\n'

shellcheck:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck install.sh tests/clean-runner.sh tests/test-install.sh tests/unit.sh; \
	else \
	  docker run --rm -v "$(CURDIR):/w:ro" -w /w koalaman/shellcheck:stable \
	    install.sh tests/clean-runner.sh tests/test-install.sh tests/unit.sh; \
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
MOTHERSHIP_DIR ?=
test:
	@test -n "$${VA_REGISTRY_USER:-}" && test -n "$${VA_REGISTRY_TOKEN:-}" || { printf '$(B)export VA_REGISTRY_USER and VA_REGISTRY_TOKEN$(R) (Docker Hub, read access to nirlevi/va-crystal)\n'; exit 1; }
	tests/test-install.sh $(MOTHERSHIP_DIR)
