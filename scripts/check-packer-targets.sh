#!/bin/sh
# Every `-only=` in the Makefile must name a build+source that Packer declares.
#
#   scripts/check-packer-targets.sh          # check
#   scripts/check-packer-targets.sh --list   # show both sides
#
# WHY THIS EXISTS. `voipappz image build` used to hold a TARGETS map (the word
# an operator says -> the packer address), so renaming a source broke one
# constant a human read. With the build wrappers moved to make (2026-08-19)
# those addresses are string literals in a recipe: a renamed source surfaces
# only as Packer's "no builds matched", after the builder container has already
# started.
#
# DELIBERATELY SHELL, not a crystal spec. This repo is losing its Crystal — the
# CLI moves to va-crystal (docs/next-cli-boundary.md) — and a guard written in
# the language that is leaving is a guard scheduled for a rewrite. grep and awk
# outlive that.
#
# Pure text over the repo. No packer, no docker, no network.
#
# POSIX sh, NOT bash: the CI job that runs this uses the bare
# alpine container CI runs in, which has no bash at all — `run: bash
# ...` there dies with "bash: not found" (caught by scripts/ci-local.sh before
# it could reach a runner). No `<<<`, no `[[`, no arrays.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

# `-only='voipappz.qemu.voipappz'` -> voipappz.qemu.voipappz
makefile_targets() {
  grep -oE "\-only='[^']+'" Makefile | sed "s/-only='//; s/'$//" | sort -u
}

# build { name = "X"  sources = ["source.<type>.<name>", ...] }  ->  X.<type>.<name>
#
# awk rather than a multiline grep: the build block spans lines, and `name` is
# declared before `sources`. Tracks the current block and emits one address per
# source line until the block closes.
packer_addresses() {
  awk '
    /^build[[:space:]]*\{/            { inblock = 1; name = ""; next }
    inblock && /^\}/                  { inblock = 0; name = ""; next }
    inblock && /name[[:space:]]*=/    {
      if (match($0, /"[^"]+"/)) name = substr($0, RSTART + 1, RLENGTH - 2)
      next
    }
    inblock && /"source\./ {
      if (name != "" && match($0, /"source\.[^"]+"/)) {
        addr = substr($0, RSTART + 8, RLENGTH - 9)   # strip `"source.` and `"`
        print name "." addr
      }
    }
  ' packer/*.pkr.hcl | sort -u
}

targets="$(makefile_targets)"
declared="$(packer_addresses)"

if [ "${1:-}" = "--list" ]; then
  echo "packer declares:"; echo "$declared" | sed 's/^/  /'
  echo "Makefile references:"; echo "$targets" | sed 's/^/  /'
  exit 0
fi

# A floor: if either extractor silently stops matching, everything below passes
# vacuously and the check becomes decoration.
if [ -z "$declared" ]; then
  echo "!! parsed no build sources from packer/*.pkr.hcl — the extractor is broken" >&2
  exit 1
fi
if [ "$(echo "$targets" | grep -c .)" -lt 4 ]; then
  echo "!! parsed fewer than 4 -only targets from the Makefile — the extractor is broken" >&2
  exit 1
fi

fail=0
# A pipeline would run the loop in a subshell and lose `fail`, so collect the
# offenders and test the result instead.
unknown="$(printf '%s\n' "$targets" | while IFS= read -r t; do
  [ -n "$t" ] || continue
  echo "$declared" | grep -qxF "$t" || echo "$t"
done)"
if [ -n "$unknown" ]; then
  printf '%s\n' "$unknown" | while IFS= read -r t; do
    echo "!! Makefile builds -only='$t', which packer does not declare" >&2
  done
  fail=1
fi

# And the other direction: a source packer declares that NO make target builds is
# unreachable from the front door. `source.qemu.direct` sat that way for a while —
# it was reachable only through the removed `voipappz image build --target`, and a
# check that only looked Makefile->packer could not see it.
unreachable="$(printf '%s\n' "$declared" | while IFS= read -r d; do
  [ -n "$d" ] || continue
  echo "$targets" | grep -qxF "$d" || echo "$d"
done)"
if [ -n "$unreachable" ]; then
  printf '%s\n' "$unreachable" | while IFS= read -r d; do
    echo "!! packer declares $d, which no make target builds" >&2
  done
  fail=1
fi

if [ "$fail" = 0 ]; then
  echo "packer targets: $(echo "$targets" | grep -c .) referenced, all declared ✔"
fi
exit "$fail"
