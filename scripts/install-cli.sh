#!/bin/sh
# Put the voipappz CLI on PATH.
#
#   sh scripts/install-cli.sh                 # this checkout's binary, building it if absent
#   sh scripts/install-cli.sh --release       # the latest published release instead
#   sh scripts/install-cli.sh --release v0.2.0
#   PREFIX=~/.local/bin sh scripts/install-cli.sh
#
# And from anywhere, with no clone:
#
#   curl -fsSL https://raw.githubusercontent.com/voipappz/installer/main/scripts/install-cli.sh | sh -s -- --release
#
# THE CLI ONLY. This installs a binary; it does not install the stack, write a
# .env or start anything — that is install.sh here, which is a different
# job with a different blast radius. Keeping them apart is why this one can be
# run on a laptop without a second thought.
set -eu

PREFIX="${PREFIX:-/usr/local/bin}"
REPO="${REPO:-voipappz/installer}"
MODE=local
VERSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --release) MODE=release; [ $# -gt 1 ] && case "$2" in -*) ;; *) VERSION="$2"; shift ;; esac ;;
    --prefix)  PREFIX="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "!! unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '  %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

# sudo only when the destination genuinely needs it — a --prefix into $HOME
# must not prompt for a password it does not need.
#
# The test walks up to the nearest EXISTING ancestor: an absent PREFIX is not
# an unwritable one, and testing -w on a path that does not exist yet answered
# "no" for every new directory, which sent `PREFIX=~/.local/bin` to sudo.
needs_root() {
  [ "$(id -u)" = 0 ] && return 1
  d="$PREFIX"
  while [ ! -e "$d" ] && [ "$d" != "/" ] && [ "$d" != "." ]; do d="$(dirname "$d")"; done
  [ ! -w "$d" ]
}

as_root() {
  if needs_root; then
    command -v sudo >/dev/null 2>&1 || die "$PREFIX needs root and sudo is not installed — set PREFIX=~/.local/bin"
    sudo "$@"
  else
    "$@"
  fi
}

case "$MODE" in
  local)
    # The repo root, resolved from this script rather than $PWD, so the command
    # works from anywhere inside the checkout.
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    [ -f "$ROOT/cli/shard.yml" ] || die "no cli/ here — use --release, or run this from a voipappz/installer checkout"
    if [ ! -x "$ROOT/bin/voipappz" ]; then
      say "no bin/voipappz yet — building it (docker, ~1 min)"
      make -C "$ROOT" build >/dev/null || die "make build failed"
    fi
    SRC="$ROOT/bin/voipappz"
    say "installing $($SRC --version) from this checkout"
    ;;
  release)
    # amd64 only, and not by choice: the crystallang images this is built with
    # are published for amd64 alone, and Crystal ships no aarch64 linux tarball.
    # Say so here rather than 404ing on an asset that was never cut.
    case "$(uname -s)" in
      Linux)  case "$(uname -m)" in
                x86_64|amd64) ASSET=voipappz-linux-amd64 ;;
                *) die "no linux build for $(uname -m) — only x86_64 is published" ;;
              esac ;;
      Darwin) case "$(uname -m)" in
                arm64) ASSET=voipappz-darwin-arm64 ;;
                *) die "no macOS build for $(uname -m) — only arm64 is published (Rosetta runs it on Intel)" ;;
              esac ;;
      *) die "unsupported system: $(uname -s)" ;;
    esac

    if [ -z "$VERSION" ]; then
      BASE="https://github.com/$REPO/releases/latest/download"
      say "installing $ASSET from the latest release"
    else
      BASE="https://github.com/$REPO/releases/download/$VERSION"
      say "installing $ASSET from $VERSION"
    fi

    TMP="$(mktemp -d)"
    trap 'rm -rf -- "$TMP"' EXIT INT TERM
    curl -fL --retry 5 -o "$TMP/voipappz" "$BASE/$ASSET" || die "could not download $BASE/$ASSET"

    # The sidecar is verified when it exists and skipped loudly when it does
    # not — a release cut before the checksums were added should still install,
    # but never silently as though it had been checked.
    if curl -fsSL -o "$TMP/sha" "$BASE/$ASSET.sha256" 2>/dev/null; then
      expected="$(cut -d' ' -f1 < "$TMP/sha")"
      actual="$(sha256sum "$TMP/voipappz" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$TMP/voipappz" | cut -d' ' -f1)"
      [ "$expected" = "$actual" ] || die "checksum mismatch: expected $expected, got $actual"
      say "checksum ok"
    else
      say "no .sha256 published for this release — not verified"
    fi
    chmod +x "$TMP/voipappz"
    SRC="$TMP/voipappz"
    ;;
esac

as_root mkdir -p "$PREFIX"
as_root install -m 0755 "$SRC" "$PREFIX/voipappz"

# Run the INSTALLED copy: a binary that downloaded fine and cannot exec here
# (wrong libc, wrong arch) is exactly what this check is for.
"$PREFIX/voipappz" --version >/dev/null 2>&1 || die "$PREFIX/voipappz does not run on this machine"

say "installed $PREFIX/voipappz ($("$PREFIX/voipappz" --version))"
case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) say "NOTE: $PREFIX is not on your PATH — add it, or call it by full path" ;;
esac
