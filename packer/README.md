# The node installer ISO

> Moved from `mothership/packer/` and trimmed to the node case. Every file here
> carries a header saying which mothership file it came from and what was
> removed; the *Provenance* section at the bottom is the whole inventory,
> including what was deliberately left behind.

A bootable Ubuntu Server 24.04 disc that installs, with **no network at all**, a
machine that can install one VA-Crystal VoIP node — and then the operator runs
one command.

It carries exactly four things:

| on the disc | what it is |
| --- | --- |
| `/autoinstall.yaml` + Ubuntu | the OS, installed unattended from the disc's own pool |
| `/va-crystal/debs/` | a real local apt repository: Docker Engine, `curl`, `ca-certificates`, `jq`, `openssl` |
| `/va-crystal/node-image.tar.gz` | **one** image, `docker save`d and gzipped: `nirlevi/va-crystal:<version>` |
| `/va-crystal/install.sh` | this repository's installer, unmodified |

And, at the root of the disc in plain text, `/va-crystal-node.txt` — the image
version, its digest, the installer commit and the build date. Mount the disc and
read it; you do not have to boot it to know what it is.

**Nothing of the mothership is on this disc.** No Postgres, no Kong, no admin,
no API, and nothing here can run `voipappz bootstrap`. The mothership's own ISO
stages seventeen images because it installs a platform. This one stages one,
because a VoIP node is one container.

**The disc is restricted media.** That one image is private, and it is on the
disc in the clear — anyone holding the ISO can `docker load` it. Do not put a
disc, or a link to one, anywhere public. See *Publishing* below.

## What the operator does

```console
# boot the disc — it erases the disk, installs, and powers off. Remove the disc.
# power on, log in as voipappz / voipappz (you are forced to change it)

$ va-node-install
   verifying /var/lib/va-crystal/node-image.tar.gz

VoIPAppz VoIP node installer

1/6  Docker
  present (Docker version 27.x)
2/6  Platform image
  loading /var/lib/va-crystal/node-image.tar.gz
  tagged sha256:… as nirlevi/va-crystal:latest
…
```

`va-node-install` is nine lines of wrapper. It checks the archive against the
checksum that shipped with it, exports two variables, and execs `install.sh`:

```sh
VA_IMAGE_SOURCE=archive
VA_IMAGE_ARCHIVE=/var/lib/va-crystal/node-image.tar.gz
exec sh /opt/va-crystal/install.sh
```

That path is not new. `install.sh` has loaded `docker save` archives since the
image archives went to S3 — it `docker load`s the file and retags the single
loaded image as `$VA_VOIP_IMAGE`, and it asks for no registry credential on that
path. **No installation logic exists anywhere in `packer/`.** `install.sh` is
the installer; this directory only puts it, and its image, on a disc.

To pre-answer the installer, drop an answer file beside it before running:

```sh
sudo install -m 0600 /dev/null /opt/va-crystal/.env
sudo nano /opt/va-crystal/.env        # VA_API_URL=…, VA_CUSTOMER_NAME=…
va-node-install
```

The image is offline; **registration is not**. `install.sh` still has to reach
the mothership to register the node and resolve its customer. On a machine that
genuinely cannot, install the node alone with `va-node-install --no-register` and register it
when there is a route.

## Cutting a disc

```sh
packer/scripts/fetch-base-iso.sh                        # once, ~3GB, resumable
docker login                                            # the image is private
packer/build.sh validate -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
packer/build.sh build    -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
```

Needs `packer`, `xorriso` and a Docker daemon. `validate` and `fmt` need none of
them — they fall back to the `hashicorp/packer` container.

### Two versions, and they are different numbers

| | owned by | what it is |
| --- | --- | --- |
| `image_version` | **va-crystal** | the published node image tag this disc bakes: `nirlevi/va-crystal:<image_version>` |
| `release_version` | **this repository** | the disc's own release. The ISO is named `voipappz-node-<release_version>.iso` |

A disc can be re-cut around an *unchanged* image — a fixed autoinstall, a newer
package closure — and that is a new **release** of the same **image**. Naming
both from one number is how an operator ends up holding two different discs that
claim to be the same thing. The identity stamp at the root of the disc records
both, labelled.

Both are **required and pinned**. `latest` is rejected by the template's own
validation, in `stage-payload.sh`, and again in `make-node-iso.sh`: media must
install the same thing next year as it does today.

`.github/workflows/node-iso.yml` **mints** `release_version` — today's date and
the first serial the bucket does not already carry, `<YYYY.MM.DD>-<serial>`,
which is the shape and the reasoning of va-crystal's `scripts/release.sh` with
S3 standing in for the registry. Nothing is committed and nothing is written at
mint time, so a run that fails after minting leaves the serial free for the next
one; a serial is consumed only by an object actually landing in S3. Pass
`release_version` explicitly to re-cut an existing release.

Useful variables:

| `-var` | default | |
| --- | --- | --- |
| `image_version` | *(required)* | the tag suffix; the image is `nirlevi/va-crystal:<image_version>` |
| `release_version` | *(required)* | the disc's own release; names the ISO |
| `with_image` | `true` | `false` cuts a small disc whose installer must reach a registry or S3 |
| `refresh_packages` | `true` | `false` re-cuts from an unchanged payload without touching the network |
| `network` | `autoinstall/network.default.yaml` | per-site netplan; a static address usually belongs here |
| `dest_dir` | *(empty)* | copy the finished ISO somewhere; empty leaves it in `build/iso/` |

The package list lives in `os-packages.txt` and nowhere else. The template reads
it, hands it to `stage-payload.sh` (which downloads exactly that closure) and
substitutes it into the autoinstall (which installs exactly that closure). A
second copy would drift, and the failure mode is either a package on the disc
that is never installed or an install that asks for one the disc does not carry
— the second aborts the whole installation.

## Why there is no VM in this build

The Packer source is `null` with `communicator = "none"`. Remastering an ISO has
no machine in it: the work is unpacking one ISO, adding files, and writing
another, which is one `xorriso` call. That is why the whole build runs on a
hosted GitHub runner with no KVM — see `.github/workflows/node-iso.yml`.

Two flags in that call are load-bearing:

* `-boot_image any replay` copies the source ISO's boot records forward, both
  the El Torito catalog for BIOS and the embedded EFI system partition, so the
  result stays bootable both ways and under Secure Boot. Rebuilding those by
  hand is how remastered Ubuntu ISOs end up UEFI-unbootable. Only `grub.cfg`
  changes, and `grub.cfg` is not what Secure Boot verifies.
* `autoinstall` on the kernel command line, inserted before the `---` separator,
  is what stops subiquity waiting forever on the "this will erase the disk"
  confirmation. Without it a working unattended install looks like a hang.

## Publishing — the disc is restricted media

**The ISO is not public and must never be re-hosted publicly.** It carries a
`docker save` of the private `nirlevi/va-crystal` node image, so anyone who can
download the disc can `docker load` that image straight out of the payload. The
disc is exactly as private as the image is.

`.github/workflows/node-iso.yml`, `workflow_dispatch`, required
`image_version`. It mints the release version, then uploads
`voipappz-node-<release_version>.iso` and `.sha256` to
`s3://voipappz-assets-il/iso/` — the same bucket `install.sh` already downloads
image archives from.

The `voipappz-node-` prefix is deliberate. `va-crystal-node-` already belongs to
va-crystal's image tarballs in that bucket, versioned by a different repository;
putting an ISO under the same name would make
`va-crystal-node-2026.08.27-2.iso` sit beside
`va-crystal-node-2026.08.27-2.tar.gz` and mean something else entirely.

The upload sets **no ACL**. The bucket has Block Public Access on (an anonymous
GET of the existing `images/va-crystal-node-latest.tar.gz` already returns 403)
and the objects inherit that. The role the workflow assumes cannot make an
object public: its policy is `s3:PutObject` on `iso/*` and nothing else — no
`PutObjectAcl`, no `GetObject`, no other prefix. It assumes that role through
GitHub OIDC, because this repository is public and holds no AWS keys; the trust
and permissions policies are written out at the top of the workflow.

Handing a disc to a customer is a **presigned URL**, minted by a person. The
argument is the disc's *release* version, the one that names the ISO:

```sh
packer/scripts/presign-iso.sh 2026.08.27-1          # one hour
packer/scripts/presign-iso.sh 2026.08.27-1 86400    # one day
```

A presigned URL is a bearer credential — anyone holding it can download until it
expires. Send it to one named person over a channel you would send a password
over, and tell them not to re-host what they get. SigV4 caps the lifetime at 7
days, but a URL signed with temporary credentials (an assumed role, SSO, an
instance profile) dies with that session instead: 1 hour by default, at most the
role's `MaxSessionDuration` of 12 hours. Only a long-lived IAM user key gets the
full 7 days. The script says which one you are on.

It is deliberately never run in CI: a job log on a public repository is
world-readable, and a presigned URL printed there is the disc handed to
everyone.

The ISO is also deliberately **not** a GitHub Release asset — those are capped
at 2GB, the disc is about 3GB, and a release asset would be public besides. The
checksum and the identity stamp are kept as a workflow artifact and printed in
the run summary.

## Files

```
node-iso.pkr.hcl           the template: null source, two shell-local provisioners
os-packages.txt            THE package list, read by the template and the scripts
build.sh                   packer fmt / validate / build, host or container
Dockerfile.builder         packer + xorriso + docker-cli, for a workstation with none
make-node-iso.sh           the xorriso remaster: stage, autoinstall, grub, cut
scripts/fetch-base-iso.sh  the Ubuntu ISO, resumable and checksum-verified
scripts/stage-payload.sh   the apt closure and the one saved image
scripts/presign-iso.sh     a time-limited link to one published disc — never in CI
autoinstall/user-data      the unattended install (@OS_PACKAGES@, @NETWORK@)
autoinstall/network.*.yaml the per-site `network:` key, DHCP and a static example
files/va-node-install      the wrapper the operator types
files/motd                 what the machine says at login
node-installer.html        the operator's page for a finished disc
```

## Provenance

Everything here came from `mothership/packer/`, which cuts a working ISO in
about forty seconds and had already paid for a lot of detail — the offline apt
repository, `-boot_image any replay`, `fallback: offline-install`, `shutdown:
poweroff`. Rewriting that from scratch would have thrown it away. What follows
is the full inventory and what happened to each file.

**Moved and trimmed**

| mothership/packer/… | here | trimmed away |
| --- | --- | --- |
| `os-image.pkr.hcl` | `node-iso.pkr.hcl` | 17-image payload, CLI and stack templates, `installer_env`, the SIP/triage package list, the whole `voipappz-deliver` build and its `deliver_*` variables |
| `make-installer-iso.sh` | `make-node-iso.sh` | stack tarball, 2000MB image split, firstboot/load-images units, answer sheet, profile scope tag, the builder-container xorriso indirection and its `hostpath()`, the python3 grub patch (now awk) |
| `scripts/stage-payload.sh` | same name | `stage_stack`, `compose-images.sh` and the 17-image manifest, the part split, the digest save-cache |
| `autoinstall/user-data` | same name | `/opt/voipappz` stack, CLI symlink, both systemd units, `installer.env`, every mention of `voipappz bootstrap` |
| `autoinstall/network.default.yaml` | same name | nothing; one comment renamed `voipappz setup` to `install.sh` |
| `autoinstall/network.static.example.yaml` | same name | same, plus the build commands |
| `build.sh` | same name | qemu/VirtualBox/amazon sources, `--device /dev/kvm`, the SSH/AWS/ISO mounts, `build_stack_tarball`, `stage_docker_config`, `clear_stale_output`/`collect_output` |
| `Dockerfile.builder` | same name | qemu, sshpass, openssh-client, python3 |
| `node-installer.html` | same name | `voipappz bootstrap`, the sbc sync pair, the 17-image first boot, the mothership's make targets |
| `README.md` | same name | rewritten around one image, two versions and restricted distribution |

**Left in the mothership, deliberately**

| file | why it did not come |
| --- | --- |
| `voipappz.pkr.hcl` | the older AMI/VirtualBox/qemu disk-image path. There is no disk image here — a node is installed from media, and `cli_version`, `stack_source` and `bake.sh` have nothing to bind to |
| `scripts/bake.sh` | bakes the platform onto a disk: 17 images, compose, the app plane |
| `scripts/firstboot.sh` | runs `voipappz setup` and `voipappz up` from a boot unit. `install.sh` does setup, registration and start; two installers on one disc is the thing to avoid. Its rule about never baking identity survives, in the autoinstall's comments |
| `scripts/load-images.sh` | `docker load` at first boot. `install.sh`'s archive path already loads the image — carrying this would be reimplementing installation logic. Its 4GB ISO9660 warning survives as the size guard in `make-node-iso.sh` |
| `scripts/make-seed-iso.sh`, `cloudinit/` | a cloud-init seed CD for the qemu source, which did not come |
| `scripts/remote-install.sh`, `scripts/ssh-install.sh` | install the mothership payload onto an existing host over SSH |
| `http/` | the autoinstall served over HTTP to a Packer-driven VM. This disc is read by subiquity from `/autoinstall.yaml` on the media itself, with no datasource plumbing at all |
| `autoinstall/meta-data` | empty, and only needed by the nocloud seed datasource the `/autoinstall.yaml` path does not use |
| `files/voipappz-firstboot.service`, `files/voipappz-loadimages.service` | the units for the two scripts above |
| `boot-test.sh` | **needs KVM.** It drives qemu with `--device /dev/kvm`, which a hosted GitHub runner does not have, and its hard-won flags (`-cpu host` for a RHEL9-based minio, `restrict=on`) are about the app plane's images. A node disc is worth boot-testing on a workstation that has KVM; that would be a new script, not this one |

**Should now be deleted from the mothership** — they exist only to serve node
media, which lives here now: `Makefile` targets `iso-voip` and `voip-image`
(lines 372–395), and the `VOIPAPPZ_IMAGE_PROFILES=voip` branch of
`scripts/stage-payload.sh` and `scripts/compose-images.sh` if nothing else uses
it. Not done here — that is the mothership repository's change to make.
