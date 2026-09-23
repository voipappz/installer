#!/usr/bin/env bash
# Boot-test a cut ISO the way a destination machine would see it.
#
#   packer/boot-test.sh install          # boot the newest ISO, install, power off
#   packer/boot-test.sh boot             # boot the installed disk
#   packer/boot-test.sh shot NAME        # screenshot the console  -> build/boottest/NAME.png
#   packer/boot-test.sh type 'text\n'    # type at the console
#   packer/boot-test.sh stop
#
# Two flags in here are the whole point, and both were learned the hard way:
#
#   -cpu host      RHEL9-based images (quay.io/minio/minio is RHEL 9.6) ship a
#                  glibc marked `x86 ISA needed: x86-64-v2`. qemu's DEFAULT cpu
#                  model, qemu64, has neither SSE4.2 nor POPCNT, so every binary
#                  in that image dies with "Fatal glibc error: CPU does not
#                  support x86-64-v2" — including the `curl` minio's healthcheck
#                  runs. va-minio then never goes healthy, createbuckets and
#                  db-init never start, and `voipappz up` fails with "dependency
#                  failed to start". That is a fault of the TEST MACHINE and not
#                  of the image, and it cost a full boot test to work out. Any
#                  real node CPU (Nehalem, 2009, onwards) has x86-64-v2.
#
#   restrict=on    The ISO's entire claim is that it installs with no network.
#                  qemu's default user-net gives the guest working internet, and
#                  every offline bug this thing has ever had passes with a route
#                  out. restrict=on answers DHCP and routes nothing, which is
#                  what a destination machine actually looks like.
#
# qemu is not installed on the workstation — it lives in the same builder image
# Packer runs from, so this drives it there, with --device /dev/kvm.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${PACKER_BUILDER_IMAGE:-voipappz-packer:local}"
WORK="$HERE/build/boottest"
CONTAINER="${BOOTTEST_CONTAINER:-va-boottest}"

DISK="$WORK/disk.qcow2"
DISK_SIZE="${BOOTTEST_DISK_SIZE:-60G}"
MEM="${BOOTTEST_MEM:-8192}"
CPUS="${BOOTTEST_CPUS:-4}"
# The install writes a partition table, unpacks a base system and dpkg-installs
# the CD's package repository. Half an hour is generous; the point of the cap is
# that a hung installer fails the test instead of running until someone notices.
TIMEOUT="${BOOTTEST_TIMEOUT:-2400}"

ISO=""

log() { echo ">> $*"; }
die() { echo "!! $*" >&2; exit 1; }

newest_iso() {
  ls -t "$HERE"/build/iso/voipappz-os-*.iso 2>/dev/null | head -1
}

# QMP, spoken from python3 inside the container — the socket is in the container's
# namespace and alpine has no socat. Prints each reply, so a failed command is
# visible rather than silently ignored.
qmp() {
  docker exec -i -e "QMP_DELAY=${QMP_DELAY:-0}" "$CONTAINER" python3 -c '
import json, os, socket, sys, time
delay = float(os.environ.get("QMP_DELAY", "0"))
s = socket.socket(socket.AF_UNIX)
s.connect("/w/build/boottest/qmp.sock")
f = s.makefile("rw")
f.readline()                                   # greeting
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
for line in sys.argv[1:]:
    f.write(line + "\n"); f.flush()
    while True:
        reply = json.loads(f.readline())
        if "event" in reply:                   # events interleave with replies
            continue
        if "error" in reply:
            sys.exit("QMP error: " + json.dumps(reply["error"]))
        print(json.dumps(reply.get("return", {})))
        break
    if delay:
        time.sleep(delay)
' "$@"
}

running() { [ -n "$(docker ps -q -f "name=^${CONTAINER}$")" ]; }

require_running() {
  running || die "no boot test running — start one with: $0 install|boot"
}

# One qemu invocation for both phases; only the boot order and the media differ.
#
# -device virtio-net-pci with restrict=on rather than -nic none: the node must
# still find AN address (firstboot derives the node's internal IP from the
# default route, and with no interface at all it exits FATAL) while reaching
# nothing. DHCP from qemu's built-in server answers; nothing routes.
start_vm() {
  local boot_order="$1"; shift
  mkdir -p "$WORK"
  rm -f "$WORK/qmp.sock"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

  local kvm=()
  if [ -e /dev/kvm ]; then
    kvm=(--device /dev/kvm)
  else
    echo "!! no /dev/kvm — this will run under emulation and take hours" >&2
    echo "   worse, -cpu host is unavailable without KVM, so the x86-64-v2" >&2
    echo "   failure this script exists to avoid comes back." >&2
  fi

  docker run -d --name "$CONTAINER" "${kvm[@]}" \
    -v "$HERE:/w" -w /w \
    --entrypoint qemu-system-x86_64 "$IMAGE" \
    -machine q35,accel=kvm -cpu host -smp "$CPUS" -m "$MEM" \
    -drive "file=/w/build/boottest/$(basename "$DISK"),format=qcow2,if=virtio" \
    "$@" \
    -boot "order=$boot_order" \
    -netdev user,id=n0,restrict=on -device virtio-net-pci,netdev=n0 \
    -display none -vga std \
    -qmp "unix:/w/build/boottest/qmp.sock,server,nowait" >/dev/null

  # The socket appears a moment after the process does; every later subcommand
  # depends on it, so wait rather than racing.
  for _ in $(seq 1 30); do
    [ -S "$WORK/qmp.sock" ] && return 0
    sleep 1
  done
  docker logs "$CONTAINER" 2>&1 | tail -20 >&2
  die "qemu did not open its QMP socket"
}

cmd_install() {
  ISO="${ISO:-$(newest_iso)}"
  [ -n "$ISO" ] || die "no ISO in build/iso — run 'make iso' first"
  [ -f "$ISO" ] || die "no such ISO: $ISO"

  mkdir -p "$WORK"
  log "fresh disk ($DISK_SIZE)"
  rm -f "$DISK"
  docker run --rm -v "$HERE:/w" --entrypoint qemu-img "$IMAGE" \
    create -f qcow2 "/w/build/boottest/$(basename "$DISK")" "$DISK_SIZE" >/dev/null
  docker run --rm -v "$HERE:/w" --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /w/build/boottest

  log "booting $(basename "$ISO") — OFFLINE, ${CPUS} cpu, ${MEM}MB"
  start_vm dc -drive "file=$(iso_in_container "$ISO"),media=cdrom,readonly=on"

  log "installing; the guest powers itself off when it is done (cap ${TIMEOUT}s)"
  local waited=0
  while running; do
    [ "$waited" -ge "$TIMEOUT" ] && {
      cmd_shot timeout || true
      die "installer still running after ${TIMEOUT}s — see build/boottest/timeout.png"
    }
    sleep 30
    waited=$((waited + 30))
    # Progress, and evidence if it later fails: subiquity's screen is the only
    # thing this test can see.
    if [ $((waited % 300)) -eq 0 ]; then
      running && cmd_shot "install-${waited}s" >/dev/null 2>&1 || true
      log "   ${waited}s"
    fi
  done

  local rc
  rc="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null || echo '?')"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ "$rc" = "0" ] || die "qemu exited $rc — the guest did not power off cleanly"
  log "installed in ${waited}s; disk is $(du -h "$DISK" | cut -f1)"
  log "now: $0 boot"
}

# The ISO lives under packer/, which is mounted at /w. Anything else has to be
# mounted separately, so refuse it rather than silently booting nothing.
iso_in_container() {
  case "$1" in
    "$HERE"/*) printf '/w/%s' "${1#"$HERE"/}" ;;
    *) die "the ISO must be under $HERE (got $1)" ;;
  esac
}

cmd_boot() {
  [ -f "$DISK" ] || die "no installed disk at $DISK — run '$0 install' first"
  log "booting the installed disk — OFFLINE"
  start_vm c
  log "up. screenshot it with: $0 shot NAME"
}

cmd_shot() {
  local name="${1:-shot}"
  require_running
  qmp "$(printf '{"execute":"screendump","arguments":{"filename":"/w/build/boottest/%s.png","format":"png"}}' "$name")" >/dev/null
  docker run --rm -v "$HERE:/w" --entrypoint chown "$IMAGE" \
    -R "$(id -u):$(id -g)" /w/build/boottest
  echo "$WORK/$name.png"
}

# Typing too fast corrupts the line, and not visibly — it looked like display
# interleaving and was not. Keys sent back to back leave `shift` held into the
# NEXT character, so `clear; echo MARKER` arrived at the shell as
# `CLEAR: ECHO MARKER` and `sudo voipappz` as `sudo voibsio@`. Both a hold-time
# and a gap between sends are needed: the first gives the guest's keyboard
# controller time to see the press and the release as separate events, the
# second stops the following key overlapping the modifier's release.
KEY_HOLD_MS="${BOOTTEST_KEY_HOLD_MS:-30}"
KEY_GAP_S="${BOOTTEST_KEY_GAP_S:-0.03}"

# Type at the console. There is no SSH key on this image and firstboot expires
# the build password, so the console is the only way in — which is also exactly
# what an operator standing at the demo machine has.
cmd_type() {
  require_running
  local text="${1:?usage: $0 type 'text'}"
  # A literal backslash-n, because the usual way to call this is from a single-
  # quoted shell argument where $'\n' is a surprise and '\n' is what gets typed.
  text="${text//\\n/$'\n'}"
  local -a cmds=()
  local i ch key
  for (( i=0; i<${#text}; i++ )); do
    ch="${text:i:1}"
    case "$ch" in
      [a-z0-9]) key="$ch" ;;
      [A-Z])    key="shift-$(printf '%s' "$ch" | tr 'A-Z' 'a-z')" ;;
      ' ')  key="spc" ;;
      '.')  key="dot" ;;
      '-')  key="minus" ;;
      '_')  key="shift-minus" ;;
      '/')  key="slash" ;;
      '\')  key="backslash" ;;
      '|')  key="shift-backslash" ;;
      ';')  key="semicolon" ;;
      ':')  key="shift-semicolon" ;;
      '=')  key="equal" ;;
      '+')  key="shift-equal" ;;
      ',')  key="comma" ;;
      '<')  key="shift-comma" ;;
      '>')  key="shift-dot" ;;
      '?')  key="shift-slash" ;;
      "'")  key="apostrophe" ;;
      '"')  key="shift-apostrophe" ;;
      '[')  key="bracket_left" ;;
      ']')  key="bracket_right" ;;
      '{')  key="shift-bracket_left" ;;
      '}')  key="shift-bracket_right" ;;
      '`')  key="grave_accent" ;;
      '~')  key="shift-grave_accent" ;;
      '!')  key="shift-1" ;;
      '@')  key="shift-2" ;;
      '#')  key="shift-3" ;;
      '$')  key="shift-4" ;;
      '%')  key="shift-5" ;;
      '^')  key="shift-6" ;;
      '&')  key="shift-7" ;;
      '*')  key="shift-8" ;;
      '(')  key="shift-9" ;;
      ')')  key="shift-0" ;;
      $'\t') key="tab" ;;
      $'\n') key="ret" ;;
      *) die "no key mapping for '$ch' — extend cmd_type" ;;
    esac
    # A modifier is its OWN qcode in the `keys` array, held for the duration of
    # the send — "shift-backslash" as a single value is rejected outright
    # ("Parameter 'data' does not accept value"). So a shifted character is two
    # entries, not one hyphenated name.
    local qcodes
    case "$key" in
      shift-*) qcodes="$(printf '{"type":"qcode","data":"shift"},{"type":"qcode","data":"%s"}' "${key#shift-}")" ;;
      *)       qcodes="$(printf '{"type":"qcode","data":"%s"}' "$key")" ;;
    esac
    cmds+=("$(printf '{"execute":"send-key","arguments":{"keys":[%s],"hold-time":%s}}' \
      "$qcodes" "$KEY_HOLD_MS")")
  done
  QMP_DELAY="$KEY_GAP_S" qmp "${cmds[@]}" >/dev/null
}

cmd_stop() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  log "stopped"
}

case "${1:-}" in
  install) shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
      esac
    done
    cmd_install ;;
  boot)  cmd_boot ;;
  shot)  shift; cmd_shot "$@" ;;
  type)  shift; cmd_type "$@" ;;
  stop)  cmd_stop ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
