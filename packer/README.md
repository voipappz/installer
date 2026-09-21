# VoIPAppz node images

Two ways to build a node, for two different situations.

> Moved here from the mothership repository in 2026-09. It always built *node*
> media — the mothership's own Makefile said so — but it lived next to the
> mothership's compose file and pulled its image list out of it. Here the list
> is `scripts/node-images.sh`, which answers with the one image a node runs.

| | build | use it when |
|---|---|---|
| **Offline installer ISO** | `make iso` | bare metal, VirtualBox, or any machine with **no internet** |
| **AMI / .vdi** | `packer build` | EC2, or a disk image a hypervisor imports directly |

Everything below the first section is the older AMI/.vdi path. If you want a
bootable disc that installs a node on an isolated machine, you want the ISO.

## The offline installer ISO

`os-image.pkr.hcl` — a remastered Ubuntu Server 24.04.4 that installs an
operating system with no network at all: docker, the SIP and triage tooling,
the `voipappz` CLI, and the node container image.

```
make iso-payload    # ONCE — pulls the node image and saves it
make iso            # cut and deliver
make iso QUICK=1    # skip package re-resolution; touches the network not at all
make iso ISO_DEST=/mnt/d/isos
```

Roughly **40 seconds** once warm — images, packages and the base ISO are all
cached, and the only unavoidable cost is writing the 8GB output.

Operator instructions live in **`node-installer.html`**, which ships beside the
ISO. The short version: boot it, wait, it **powers off**, remove the disc, boot
again, then `voipappz bootstrap`.

### Boot-testing it

```
packer/boot-test.sh install      # newest ISO -> fresh disk, offline, powers off
packer/boot-test.sh boot         # boot what it installed
packer/boot-test.sh shot NAME    # console screenshot -> build/boottest/NAME.png
packer/boot-test.sh type 'voipappz\n'
packer/boot-test.sh stop
```

qemu lives in the same builder image Packer runs from, so nothing is installed
on the workstation. Two of its flags are the whole point and both were learned
by losing a boot test to them — `-cpu host` and `restrict=on`, explained in the
gotchas below.

What a full pass costs, measured on 4 vCPU / 8GB with no network at all:

| | |
|---|---|
| cut the ISO (`make iso QUICK=1`) | 2m30s |
| install, disc to power-off | **10m30s** |
| first boot: `docker load` of the node image | a few minutes |
| `voipappz bootstrap --skip-login --ci` | ~4m |

So a machine is taking calls about 25 minutes after the disc goes in, and the
middle 9 minutes are silent — `voipappz-firstboot` is ordered after
`voipappz-loadimages` and will not start the stack until every image is in.

### Copying it to another machine

```
packer/build.sh build -only='voipappz-deliver.null.deliver' \
  -var deliver_host=10.0.0.9 \
  -var deliver_user=voipappz \
  -var deliver_key=/root/.ssh/id_ed25519 \
  -var deliver_dir=/srv/isos .
```

A **second `null` source**, this one with a real SSH communicator — the null
builder's other half. The ISO-cutting source is `communicator = "none"` because
it has no machine to talk to; this one connects to a machine that already
exists, so Packer owns the auth, the wait-for-SSH loop and `ssh_timeout`, and
`packer validate` covers the settings.

It stages the newest ISO into `build/deliver/` first — as a hard link, so no
second 8.4 GB on disk — because the filename carries a build timestamp and HCL
cannot glob for it. The last provisioner runs `sha256sum` **on the target**: a
truncated ISO still lists like an ISO, and the only other symptom is an
unbootable disc at the far end.

Three defaults exist purely so `packer validate` passes, since it checks every
source in the directory including this one: `deliver_host` is `unset.invalid`
(RFC 2606 — it can never resolve, so a forgotten `-var` fails instantly instead
of reaching a real machine), and the placeholder `deliver_password` satisfies
the communicator's "one authentication method" rule without naming a key file
that would have to exist. Passing `deliver_key` unsets the password
automatically — Packer rejects both being set.

### It installs an OS. It does not configure a node.

That separation is the whole design, and it is not tidiness:

- A late-command that fails **aborts the entire install**. An earlier version did
  everything in the installer, `dpkg -i` returned 100, and subiquity discarded a
  finished partition table, bootloader and base system along with it.
- `voipappz setup` writes `.env` and `config/va.yaml` — secrets plus node
  identity, already `HOST_GENERATED` in `DeployManifest`. Baking those clones one
  set of secrets onto every machine built from the image.

So the disc stops one step short, and `voipappz-firstboot` runs setup on the
booted machine — or says so and waits, if no answer sheet was baked in.

### Why `source "null"`

Packer's model is source → provision → post-process: it boots or creates a
machine. Remastering an ISO has no machine — the work is unpacking one ISO,
adding files, writing another. `null` with `communicator = "none"` expresses
"this build runs locally", and is what lets `os_packages`, `base_iso`,
`network` and `dest_dir` be real HCL variables with `packer validate` over them
instead of constants inside a shell script.

The provisioners shell out to `scripts/*.sh` rather than inlining the work, so
the scripts stay usable on their own.

### Variables

| variable | default | controls |
|---|---|---|
| `os_packages` | 26 packages | **single source of truth** — feeds both the download and the install |
| `with_images` | `true` | bake the node image; `false` makes the node pull at `up` time |
| `network` | DHCP | netplan config substituted into the autoinstall |
| `installer_env` | empty | answer sheet — the node then configures itself with no login |
| `dest_dir` | empty | where the ISO is delivered; empty leaves it in `packer/build/iso/` |
| `refresh_packages` | `true` | `false` re-cuts from an unchanged payload |
| `deliver_host` | `unset.invalid` | SSH target for the `voipappz-deliver` build |
| `deliver_user` / `deliver_key` | `root` / empty | credentials for that target |
| `deliver_password` | placeholder | used only when `deliver_key` is empty |
| `deliver_port` / `deliver_timeout` | `22` / `10m` | SSH port and wait |
| `deliver_dir` | `/var/lib/voipappz/isos` | where the ISO lands on the target |

### Gotchas that cost real time

- **`apt.fallback` defaults to `abort`.** subiquity probes the archive mirror
  before installing; offline that probe fails and the install stops dead at
  `Mirror/apply_autoinstall_config` having partitioned nothing, naming the mirror
  rather than the missing network. `fallback: offline-install` is the flag that
  makes this ISO work at all.
- **`apt-get install -d` resolves against the BUILDER's installed set**, so every
  dependency the container already had is silently skipped — that shipped a
  payload missing libgssapi-krb5-2, libssh-4, libldap2 and four more, and the
  target died with seven unmet dependencies. `apt-cache depends --recurse` asks
  what the packages need in the abstract, which is the question that matters when
  the target is a different machine.
- **`dpkg -i *.deb` cannot satisfy pre-depends ordering** and `apt-get -f install`
  has nothing to reach for offline. The payload is a real apt repository
  (`apt-ftparchive packages`) so apt orders the unpacking itself.
- **The installer must POWER OFF, not reboot.** Rebooting into attached media
  reinstalls forever — three full passes here before anyone noticed, because each
  looks identical to the first.
- **A single ISO9660 file cannot exceed 4GB**, and the image archive has been
  over it. Split into 2000MB parts and `cat` them into `docker load`. The split
  is unconditional rather than size-tested, so a payload that grows past the
  limit cannot quietly produce a disc that will not load.
- **`-boot_image any replay` is load-bearing** — it carries the source ISO's boot
  records forward, El Torito for BIOS *and* the embedded EFI partition, so the
  result stays bootable both ways and under Secure Boot.
- **busybox `split`** (in the builder image) has neither `-d` nor the `m` suffix,
  and fails with a usage dump rather than an error.
- **`path.root` is relative**, and `docker run -v` turns a relative path into a
  *named volume* rather than a bind mount — which surfaces much later as
  "Media status : is blank" from a tool reading an empty file.
- **The null builder is built into Packer core.** Declaring it in
  `required_plugins` sends `packer init` after a plugin that does not exist and
  fails the whole init with a bare 404.
- **A container cannot write multi-GB files to WSL's 9p mount** — it dies with
  "cp: write error: I/O error" partway through. Delivery happens host-side from
  `build.sh` after the build returns.
- **Test offline or the test is worthless.** qemu's default user-net gives the VM
  internet, and the first three bugs above all pass with a route out. Use
  `-netdev user,restrict=on`.
- **The test VM needs `-cpu host`, and so does the demo machine.** qemu's
  default `qemu64` model has neither SSE4.2 nor POPCNT, so it is short of
  **x86-64-v2** — and an image whose libc is marked as needing it aborts every
  binary in the container with "Fatal glibc error: CPU does not support
  x86-64-v2", healthchecks included. A boot test without `-cpu host` fails that
  way while the ISO is perfectly good. Learned on the mothership's
  `quay.io/minio/minio` (RHEL 9.6), where the only visible symptom was
  `dependency failed to start: container va-minio is unhealthy` — three services
  from the cause — but the rule is about the CPU model, not that image. Real
  hardware has had x86-64-v2 since Nehalem (2009); what has not is a VM told to
  present a generic CPU, which a hypervisor pinned to an old compatibility level
  for live migration will do.
- **acme.sh cannot issue a certificate offline.** An air-gapped node stays on the
  `CN=localhost` placeholder permanently — TLS negotiates, so it looks fine while
  real clients reject it. `voipappz cert` reports which you have.

---

## AMI and .vdi

One Packer template, two targets: an **AMI** and a VirtualBox **.vdi**. Both
run the same provisioning script, so they cannot drift apart — that is the
reason this is Packer rather than EC2 Image Builder, which can only produce an
AMI.

```
packer init packer/
packer build -var cli_version=v0.1.3 packer/                          # both
packer build -only='voipappz.amazon-ebs.voipappz'     packer/          # AMI only
packer build -only='voipappz.virtualbox-iso.voipappz' packer/          # .vdi only
```

The .vdi lands in `build/vdi/`; the AMI id and both artifacts are recorded in
`build/manifest.json`.

## What is baked, and what is not

| baked into the image | generated at first boot |
|---|---|
| docker | `.env` |
| the `voipappz` binary | `config/va.yaml` |
| this repository's tracked files | TLS material |
| **the node container image, pre-pulled** | the node's addresses |

The split is not stylistic. `voipappz setup` writes secrets and node identity;
baking those clones one set of secrets onto every instance. `DeployManifest`
already classifies `.env` and `config/va.yaml` as `HOST_GENERATED` — "exist
only after `voipappz setup` ON THE HOST".

`install.sh` already draws the same line, so `bake.sh` does not reimplement it:
`BOOTSTRAP=0` means "install only, print the bring-up command instead".

## Why pre-pulling the images matters

`nirlevi/va-crystal:node` is a moving tag. A release pins the CLI but **not**
what `docker pull` resolves that tag to, so two nodes installed a week apart
from the same tarball run different software.

`docker pull` at bake time resolves it once and freezes it into the image's
layer store. The image ID becomes the real version number, and
`/etc/voipappz-images` records the resolved digest. It also takes Docker Hub out
of the boot path entirely — no rate limits, no pull latency before a voip node
can take calls, and an air-gapped VirtualBox node works at all.

## First boot

`voipappz-firstboot.service` runs once. It needs an answer sheet at
`/etc/voipappz/installer.env` — the same format as `installer.env.example`,
delivered by cloud-init user-data (EC2) or dropped in by hand (VirtualBox).

Without one it does nothing and says so. That is deliberate: an unconfigured
node is fine, a node with a guessed domain and admin email looks configured and
is not.

It adds the one thing only the booted machine knows — its addresses:

```
VOIPAPPZ_EXTERNAL_IP        ← IMDS public-ipv4,  else the internal address
VOIPAPPZ_INTERNAL_IP        ← IMDS local-ipv4,   else the default-route source
VOIPAPPZ_CHOOSE_INTERNAL_IP ← same value
```

Both internal keys are set because `setup` asks a different question depending
on how many interfaces it finds ("Internal IP" for one, a numbered "Choose
internal IP" menu for several), and which branch fires is a property of the
instance. The menu accepts a literal address, so one value answers either.

This is the fix for a real outage: a node whose internal address had been set
to its **public** IP bound kamailio to the wrong interface, the ingress
dispatcher never got an answer to its keepalives, and every call 404'd. Derived
from IMDS, it stops being a hand-entered value.

Set `VA_PROFILE=app` or `VA_PROFILE=voip` in the answer sheet to choose what
comes up. Default is `app`.

## Not yet verified

**This has never been built.** It was written against the repo but neither
`packer`, `VBoxManage` nor `qemu-img` exists on the machine it was authored on.
Check these first on a real build host:

- `packer init packer/ && packer validate packer/` — the HCL has not been parsed.
- `var.iso_url` points at a specific Ubuntu point release. Canonical removes
  older ones as new ones ship; if the URL 404s, bump it.
- The `boot_command` cursor keys for the 24.04 installer's GRUB entry. This is
  the single most fragile line in any VirtualBox template and it changes
  between Ubuntu releases.
- Whether 30 GB is enough once the node image is pulled.

## Known gaps

- **x86_64 only.** There is no linux-arm64 CLI build — the Crystal toolchain
  ships no aarch64 linux release — so no Graviton and no Apple-silicon .vdi.
- `cli_version=latest` (the default) makes the build non-reproducible: two
  builds a week apart bake different binaries. Pin it for anything shipped.
- The build-time `voipappz` password exists only on the VirtualBox image and is
  expired on first boot, so it forces a change rather than being a standing
  default credential. The AMI's `ubuntu` user is key-only and unaffected.
