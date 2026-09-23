# Offline node ISO — what was built, and what it cost to learn

A record of the work behind `make iso`, written down because most of it is
knowledge that only shows up as a failure three steps from its cause.

Operator instructions are in [`INSTALL.md`](../INSTALL.md). Design and build
detail is in [`packer/README.md`](../packer/README.md). This file is the
narrative: what was made, what broke, and what the failures actually meant.

## What was built

| | |
|---|---|
| `packer/os-image.pkr.hcl` | Packer entry point — `source "null"` + shell-local |
| `packer/make-installer-iso.sh` | remasters the Ubuntu ISO with xorriso |
| `packer/scripts/stage-payload.sh` | package repo, container images, CLI bundle |
| `packer/scripts/load-images.sh` | `docker load` at first boot |
| `packer/autoinstall/user-data` | the unattended install |
| `packer/boot-test.sh` | drives qemu to boot-test a cut ISO |
| `Makefile` | `iso`, `iso-quick`, `iso-payload`, `iso-clean`, `iso-upload` |

The output installs Ubuntu 24.04.4, Docker, the SIP and triage tooling, the
`voipappz` CLI and all 18 container images onto a machine with **no route out**.

## Verified

- Installs air-gapped end to end — install, power off, boot, 18 images loaded,
  `setup --ci`, `up -p app` with postgres healthy. Tested with
  `-netdev user,restrict=on`: DHCP answers, nothing routes.
- Every image executes offline (`--network none`) — now a gate in
  `stage-payload.sh` and in CI's `health-check`.
- Split image parts reassemble byte-identical to the source archive.
- Boots BIOS and UEFI; `xorriso -boot_image any replay` carries both records.

Not verified: `scripts/test-ingress.sh` / `test-egress.sh`, and CI's
`health-check` end to end (see the ingress item below).

## What broke, and what it actually was

**`apt.fallback` defaults to `abort`.** subiquity probes the archive mirror
before installing. Offline that fails and the install stops dead at
`Mirror/apply_autoinstall_config` having partitioned nothing, naming the mirror
rather than the missing network. `fallback: offline-install` is the single flag
that makes an offline ISO possible.

**`apt-get install -d` resolves against the builder's installed set.** Every
dependency the build container already had was silently skipped, so the payload
shipped without libgssapi-krb5-2, libssh-4, libldap2 and four more, and the
target died with seven unmet dependencies. `apt-cache depends --recurse` asks
what the packages need in the abstract — the question that matters when the
target is a different machine.

**`dpkg -i *.deb` cannot satisfy pre-depends ordering**, and `apt-get -f install`
has nothing to reach for offline. The payload is a real apt repository so apt
orders the unpacking itself.

**The installer must power off, not reboot.** Rebooting into attached media
reinstalls forever — three full passes here before anyone noticed, because each
looks identical to the first.

**A single ISO9660 file cannot exceed 4GB** and the image archive is 4.6GB.
Split into 2000MB parts, `cat` into `docker load`.

**`spock_output` is not on PostgreSQL's output-plugin allowlist.** Spock's
walsender was refused its replication slot, so subscriptions formed, reported
healthy, and nothing replicated. CI showed only `probe table did not reach n2`.
Fixed with `output_plugin_libraries = 'spock_output'`. The trap: the restriction
applies to the **replication protocol only** —
`pg_create_logical_replication_slot(...,'spock_output')` succeeds as superuser,
so probing by hand says the plugin is healthy right up until a walsender uses it.

**minio needs an x86-64-v2 CPU.** Its glibc is marked `x86 ISA needed:
x86-64-v2`; without it every binary aborts, including the `curl` its healthcheck
runs. minio never goes healthy, createbuckets and db-init wait on it, and
compose reports `dependency failed to start` — three services from the cause.
qemu's default `qemu64` lacks it, so `boot-test.sh` pins `-cpu host`.

**`secrets/` is 0700.** Run `sudo voipappz setup` once and plain
`voipappz setup` after, and the non-root user cannot traverse the directory —
so `File.exists?` returns false for every secret, the CLI concludes there are
none, and tries to generate fresh ones. Three `rescue nil`s hide the cause. Use
`sudo` for every `voipappz` command on a node.

**`path.root` is relative**, and `docker run -v` treats a relative path as a
*named volume* rather than a bind mount — which surfaces much later as
"Media status : is blank" from a tool reading an empty file.

**The null builder is built into Packer core.** Declaring it in
`required_plugins` sends `packer init` after a plugin that does not exist.

**A container cannot write multi-GB files to WSL's 9p mount** — it dies with
"cp: write error: I/O error" partway through. Delivery happens host-side.

## Known open

- **`kamailio-ingress` does not stay up when the node's internal address is
  127.0.0.1** — restart-loops on `udp_init(): Address already in use`. Every
  other service reaches healthy. Affects a pure-loopback install, which is a
  supported topology.
- **acme.sh cannot issue a certificate offline** — the node stays on the
  `CN=localhost` placeholder. TLS negotiates, so it looks fine while real
  clients reject it. Inherent to DNS-01.
- The two SIP behaviour suites have not been run against a node built from an
  ISO.

## One mistake worth not repeating

A retry loop added to survive a flaky apt mirror returned **0 when exhausted** —
the `for` loop's status was that of its trailing `{ echo; sleep; }`. A layer
that never installed anything was recorded as successful, the build continued,
and the result was an image missing `postgresql-common`. That image then
replaced a working local cluster and made several hours of diagnosis point at
the wrong thing, because every subsequent test was run against it.

It is the same shape as the `rescue nil` criticised above: swallowing a failure
does not merely hide it, it manufactures a plausible artifact that sends you
chasing ghosts. Any retry wrapper must fail loudly when it gives up.
