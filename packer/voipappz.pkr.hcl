# VoIPAppz node image — one template, two targets.
#
#   packer init  packer/
#   packer build -only='voipappz.amazon-ebs.voipappz'     packer/    # AMI
#   packer build -only='voipappz.virtualbox-iso.voipappz' packer/    # .vdi
#   packer build packer/                                             # both
#
# The two sources share ONE `build` block, so the provisioning is identical by
# construction rather than by discipline — the reason this is Packer and not
# EC2 Image Builder, which can only ever emit an AMI.
#
# WHAT IS BAKED, AND WHAT IS NOT
#
# Baked: docker, the voipappz binary, the stack templates, and every container
# image pulled ahead of time. Pre-pulling is the point of the exercise. 11 of
# the stack's images are `:latest`, so a release tag does NOT pin them — but a
# `docker pull` at bake time does, freezing the whole stack into the image's
# layer store. The image ID becomes the version number, Docker Hub leaves the
# boot path (no rate limits, no pull latency before a voip node can take
# calls), and an air-gapped VirtualBox node works at all.
#
# NOT baked: `voipappz setup`. It writes .env and config/va.yaml — secrets plus
# node identity. Baking those clones one set of secrets onto every instance.
# DeployManifest::HOST_GENERATED already says as much: they "exist only after
# `voipappz setup` ON THE HOST, never in a repo checkout". Setup runs at FIRST
# BOOT instead; see scripts/firstboot.sh.

packer {
  required_plugins {
    amazon     = { version = ">= 1.3.0", source = "github.com/hashicorp/amazon" }
    virtualbox = { version = ">= 1.1.1", source = "github.com/hashicorp/virtualbox" }
    qemu       = { version = ">= 1.1.0", source = "github.com/hashicorp/qemu" }
    # NOTE os-image.pkr.hcl uses source "null" and it is NOT listed here:
    # the null builder is BUILT INTO Packer core, so declaring it sends
    # `packer init` looking for hashicorp/packer-plugin-null, which does not
    # exist and fails the whole init with a bare 404.
  }
}

variable "stack_source" {
  type    = string
  default = "local"
  # "local"   — bake THIS checkout: packer/build.sh tars the working tree plus
  #             bin/voipappz and uploads it. Nothing is fetched from GitHub.
  # "release" — bake a published release via install.sh.
  #
  # Default is local, and not just for convenience: no release has ever carried
  # voipappz-stack.tar.gz (the release job was missing actions/checkout, so
  # `git archive` had no repository), and install.sh treats that download as
  # fatal. Until a fixed release ships, "release" cannot work — and even after,
  # "local" is what you want for an image built from an unreleased branch.
  description = "Where the app comes from: local checkout, or a published release."
}

variable "cli_version" {
  type        = string
  default     = "latest"
  description = "voipappz release to bake (e.g. v0.1.3). 'latest' resolves at bake time, which makes the build non-reproducible — pin it for anything you intend to ship."
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "instance_type" {
  type        = string
  default     = "t3.large"
  description = "Bake-time only. Pulling the node image wants disk throughput more than CPU."
}

# Private images need a registry credential AT BAKE TIME. It is deleted again
# before the snapshot (see bake.sh) — a leftover /root/.docker/config.json ships
# your registry password inside the image.
variable "dockerhub_username" {
  type      = string
  default   = ""
  sensitive = true
}

variable "dockerhub_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "cloud_image_url" {
  # A LOCAL path by default, not the https URL. Packer's downloader does not
  # resume, so a stalled transfer restarts from zero and the build dies with
  # "error downloading ISO: connection timed out" having done nothing. Fetch it
  # once with a resumable client instead:
  #
  #   curl -fL -C - --retry 10 -o packer/cache/ubuntu-24.04-server-cloudimg-amd64.img \
  #     https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img
  #
  # Pass the https URL explicitly if you would rather Packer fetch it.
  type        = string
  default     = "file:///w/cache/ubuntu-24.04-server-cloudimg-amd64.img"
  description = "qemu source. Canonical's pre-installed cloud image — no installer to drive, so no fragile boot_command."
}

variable "cloud_image_checksum" {
  type        = string
  default     = "sha256:6e40c07ae715f744f84af0bec76415cc1987dd115b4b8de437818561f01a3733"
  description = "Checksum of ubuntu-24.04-server-cloudimg-amd64.img, pinned literally so this source needs no network at all. From https://cloud-images.ubuntu.com/releases/24.04/release/SHA256SUMS (verified 2026-08-16)."
}

variable "local_iso" {
  type        = string
  default     = "file:///iso/ubuntu-24.04.4-live-server-amd64.iso"
  description = "qemu.installer source. An ISO already on disk, mounted at /iso by packer/build.sh (set VOIPAPPZ_ISO_DIR). Nothing is downloaded."
}

variable "local_iso_checksum" {
  type        = string
  default     = "sha256:e907d92eeec9df64163a7e454cbc8d7755e8ddc7ed42f99dbc80c40f1a138433"
  description = "Checksum of var.local_iso — 24.04.4 live-server amd64, from https://releases.ubuntu.com/24.04/SHA256SUMS. Pinned literally rather than fetched, so this source needs no network at all."
}

variable "iso_url" {
  type        = string
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"
  description = "VirtualBox only. Must match a file that actually exists on the mirror — Canonical REMOVES older point releases as new ones ship, and the failure is a confusing 'no checksum found in SHA256SUMS' rather than a 404. Verified present 2026-08-16; check https://releases.ubuntu.com/24.04/SHA256SUMS if validate complains."
}

locals {
  # Stamped into the image name and into /etc/voipappz-image so a running node
  # can say which image it came from. timestamp() is Packer's, not the shell's.
  version = "${var.cli_version}-${formatdate("YYYYMMDD-hhmm", timestamp())}"
}

# ---------------------------------------------------------------- AMI

source "amazon-ebs" "voipappz" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ubuntu"

  ami_name        = "voipappz-node-${local.version}"
  ami_description = "VoIPAppz node — docker + voipappz CLI + the pre-pulled node image"

  # 30G: the baked images are the bulk of it. The default 8G root will not hold
  # freeswitch + postgres + influx + kong + the rest.
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # IMDSv2 required — firstboot.sh reads local-ipv4/public-ipv4 from it, and a
  # token-less IMDSv1 read is a credential-exposure path not worth keeping.
  imds_support = "v2.0"
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      virtualization-type = "hvm"
      root-device-type    = "ebs"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  tags = {
    Name       = "voipappz-node-${local.version}"
    CliVersion = var.cli_version
    BuiltBy    = "packer"
  }
}

# ---------------------------------------------------------------- .vdi

source "virtualbox-iso" "voipappz" {
  iso_url = var.iso_url
  # Read the hash from Canonical's signed manifest rather than pasting one in.
  # A pasted checksum goes stale the moment iso_url moves and then fails as a
  # confusing "checksum mismatch" instead of "that ISO is gone".
  iso_checksum = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"

  guest_os_type = "Ubuntu_64"
  cpus          = 2
  memory        = 4096
  disk_size     = 30720

  # Ubuntu Server 24.04 installs unattended via cloud-init autoinstall; Packer
  # serves http/ over its own HTTP server and the kernel cmdline points at it.
  http_directory = "${path.root}/http"
  boot_wait      = "5s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<f10>",
  ]

  ssh_username = "voipappz"
  ssh_password = "voipappz" # replaced at first boot; see http/user-data
  ssh_timeout  = "45m"      # an unattended Ubuntu install is not quick

  shutdown_command = "echo 'voipappz' | sudo -S shutdown -P now"

  # Keep VirtualBox's NATIVE disk. `format = ova/ovf` would export and convert
  # the disk to VMDK on the way out, which is the one format we were not asked
  # for. Skipping the export leaves voipappz.vdi in output_directory.
  skip_export      = true
  output_directory = "build/vdi"
  vm_name          = "voipappz-node-${local.version}"

  vboxmanage = [
    ["modifyvm", "{{ .Name }}", "--memory", "4096"],
    ["modifyvm", "{{ .Name }}", "--cpus", "2"],
    # NAT'd VMs have no IMDS; firstboot.sh falls back to interface detection.
    ["modifyvm", "{{ .Name }}", "--nictype1", "virtio"],
  ]
}

# ---------------------------------------------------------- .vdi, via qemu
#
# Same artifact as the virtualbox source, different road to it — and the road
# matters, because `virtualbox-iso` needs VirtualBox on the build host and
# VirtualBox is a Windows application. On WSL2, a Linux CI runner, or any
# headless box there is no VBoxManage to call, so that source cannot run at all.
#
# This one needs only KVM. It also skips the OS install entirely: it boots
# Canonical's CLOUD image (already installed, cloud-init ready) instead of
# driving an installer through a boot_command, which removes the single most
# fragile line in the VirtualBox template — the GRUB cursor keys that change
# between Ubuntu releases.
#
# qemu emits qcow2; a shell-local post-processor converts to .vdi, which
# VirtualBox imports natively. Prefer this source unless you specifically need
# VirtualBox's own disk lineage.
source "qemu" "voipappz" {
  # The cloud image is a DISK, not an installer ISO — disk_image = true boots
  # it directly and disk_size grows it in place.
  iso_url      = var.cloud_image_url
  iso_checksum = var.cloud_image_checksum
  disk_image   = true
  disk_size    = "30G"
  format       = "qcow2"

  accelerator = "kvm"
  cpus        = 2
  memory      = 4096
  headless    = true

  # cloud-init NoCloud: a CD labelled `cidata` carrying user-data + meta-data is
  # the datasource. Packer builds the ISO itself, so there is no mkisofs step
  # and nothing to keep in sync by hand.
  # A PRE-BUILT seed ISO, attached as a plain cdrom — not Packer's `cd_files`.
  # cd_files shells out to xorriso/mkisofs/hdiutil/oscdimg and dies in under a
  # second when the build host has none; `apk add xorriso` ran over an hour on
  # this link and never finished. scripts/make-seed-iso.sh builds the same ISO
  # with pycdlib (pure Python, installs in seconds).
  # `-cdrom`, NOT `-drive ...,media=cdrom`. qemuargs REPLACES every instance of
  # a flag Packer also emits, and Packer attaches the qcow2 with `-drive` — so
  # a `-drive` entry here silently removed the boot disk. The VM then came up
  # with nothing to boot and Packer sat at "Waiting for SSH" until it timed out.
  # `-kernel`/`-initrd` are additive only because Packer never sets them.
  qemuargs = [
    ["-cdrom", "${path.root}/cache/seed.iso"],
  ]

  ssh_username = "voipappz"
  ssh_password = "voipappz"
  ssh_timeout  = "20m"

  shutdown_command = "echo 'voipappz' | sudo -S shutdown -P now"

  net_device     = "virtio-net"
  disk_interface = "virtio"

  output_directory = "build/qemu"
  vm_name          = "voipappz-node-${local.version}.qcow2"
}

# ------------------------------------------------ .vdi, from a LOCAL ISO
#
# Same output as qemu.voipappz, but it installs from an ISO already on disk
# instead of fetching Canonical's cloud image. That exists for one reason:
# downloading is the part that fails. On a link that stalls on large HTTPS
# transfers, `packer build` dies with "error downloading ISO: connection timed
# out" after several minutes, having done nothing — and Packer's downloader
# does not resume. An ISO you already have removes the failure entirely.
#
# It does mean driving the installer, so this source carries the GRUB
# boot_command that the cloud-image source was written to avoid. The trade is
# worth it when the alternative is not building at all, and unlike the
# virtualbox source this one can actually be RUN here to find out.
#
# Point var.local_iso at the file. packer/build.sh mounts VOIPAPPZ_ISO_DIR at
# /iso read-only, so the default assumes that.
source "qemu" "installer" {
  iso_url = var.local_iso
  # The manifest still names this file, so verify against it rather than
  # trusting whatever is on disk — a truncated download is otherwise a very
  # expensive way to find out.
  iso_checksum = var.local_iso_checksum

  disk_size = "30G"
  format    = "qcow2"

  accelerator = "kvm"
  cpus        = 2
  memory      = 4096
  headless    = true

  # Reuses http/user-data — the same autoinstall the virtualbox source uses.
  http_directory = "${path.root}/http"

  # 20s, not 5s. At 5s this source was FLAKY, not broken: of three runs with an
  # identical boot_command, one partitioned in three minutes and two sat at an
  # empty 197KB disk for half an hour. Keys typed before GRUB is listening go
  # nowhere, the menu then times out into the INTERACTIVE installer, and Packer
  # waits out its whole ssh_timeout for an SSH server that will never start.
  # The failure looks like a hang, which is what makes it expensive.
  #
  # It is not slow media — the ISO reads at 246 MB/s here. It is a race, and a
  # race is the reason to prefer qemu.voipappz, which drives no installer at all.
  boot_wait = "20s"

  # GRUB's command line (`c`), not its menu editor. Typing the kernel line
  # outright is far less brittle than the virtualbox source's cursor-key dance
  # through a menu entry whose layout changes between Ubuntu releases.
  # `\;` because an unescaped semicolon is GRUB's command separator, which
  # would truncate the kernel cmdline at `ds=nocloud-net`.
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz --- autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>",
  ]

  ssh_username = "voipappz"
  ssh_password = "voipappz"
  ssh_timeout  = "45m"

  shutdown_command = "echo 'voipappz' | sudo -S shutdown -P now"

  net_device     = "virtio-net"
  disk_interface = "virtio"

  output_directory = "build/qemu-iso"
  vm_name          = "voipappz-node-${local.version}.qcow2"
}

# ------------------------------------- .vdi, local ISO, NO GRUB (deterministic)
#
# Same ISO as qemu.installer, but qemu boots the kernel DIRECTLY via
# -kernel/-initrd/-append, so GRUB never runs and there is nothing to type.
#
# This exists because boot_command is a race we kept losing: four runs of
# qemu.installer, one partitioned, three sat at an empty 197KB disk — one of
# them for 32 minutes at boot_wait=20s. Keys land before GRUB is listening, the
# menu times out into the interactive installer, and Packer then waits out its
# whole ssh_timeout. There is no timing to tune here; the kernel cmdline is
# passed by qemu itself.
#
# vmlinuz and initrd are extracted from the ISO once into packer/cache/casper/
# (see packer/README.md). The ISO stays attached as a CD because casper finds
# the squashfs on it.
#
# The HTTP port is PINNED rather than templated: qemuargs interpolation of
# {{ .HTTPPort }} is not something to bet a 40-minute build on, and under qemu
# user-networking the host is always 10.0.2.2.
source "qemu" "direct" {
  iso_url      = var.local_iso
  iso_checksum = var.local_iso_checksum

  disk_size = "30G"
  format    = "qcow2"

  accelerator = "kvm"
  cpus        = 2
  memory      = 4096
  headless    = true

  http_directory = "${path.root}/http"
  http_port_min  = 8099
  http_port_max  = 8099

  qemuargs = [
    ["-kernel", "${path.root}/cache/casper/vmlinuz"],
    ["-initrd", "${path.root}/cache/casper/initrd"],
    ["-append", "autoinstall ds=nocloud-net;s=http://10.0.2.2:8099/ cloud-config-url=/dev/null ---"],
  ]

  ssh_username = "voipappz"
  ssh_password = "voipappz"
  ssh_timeout  = "45m"

  shutdown_command = "echo 'voipappz' | sudo -S shutdown -P now"

  net_device     = "virtio-net"
  disk_interface = "virtio"

  output_directory = "build/qemu-direct"
  vm_name          = "voipappz-node-${local.version}.qcow2"
}

# ---------------------------------------------------------------- provisioning

build {
  name = "voipappz"
  sources = [
    "source.amazon-ebs.voipappz",
    "source.virtualbox-iso.voipappz",
    "source.qemu.voipappz",
    "source.qemu.installer",
    "source.qemu.direct",
  ]

  # The app itself, when stack_source = "local". Produced by packer/build.sh
  # (git archive of the working tree + bin/voipappz), so an image can be built
  # from an unreleased branch and needs nothing from GitHub. Uploaded
  # unconditionally because a `file` provisioner cannot be made conditional;
  # bake.sh ignores it when stack_source = "release".
  provisioner "file" {
    source      = "${path.root}/build/stack.tar.gz"
    destination = "/tmp/stack.tar.gz"
  }

  # Registry credential for the bake's pulls. The stack's own images are
  # private, so without it the very first `docker pull` fails with "pull access
  # denied". Staged by build.sh from the host's existing docker login; bake.sh
  # deletes it from the image before the snapshot.
  provisioner "file" {
    source      = "${path.root}/build/docker-config.json"
    destination = "/tmp/docker-config.json"
  }

  provisioner "file" {
    source      = "${path.root}/scripts/firstboot.sh"
    destination = "/tmp/firstboot.sh"
  }

  provisioner "file" {
    source      = "${path.root}/files/voipappz-firstboot.service"
    destination = "/tmp/voipappz-firstboot.service"
  }

  provisioner "shell" {
    script          = "${path.root}/scripts/bake.sh"
    execute_command = "sudo -E env {{ .Vars }} sh '{{ .Path }}'"
    environment_vars = [
      "STACK_SOURCE=${var.stack_source}",
      "CLI_VERSION=${var.cli_version}",
      "IMAGE_VERSION=${local.version}",
      "DOCKERHUB_USERNAME=${var.dockerhub_username}",
      "DOCKERHUB_PASSWORD=${var.dockerhub_password}",
    ]
  }

  # qcow2 -> .vdi. `only` matters: without it this runs for the AMI and the
  # VirtualBox builds too, and fails on a file that was never produced.
  post-processor "shell-local" {
    only = ["qemu.voipappz"]
    inline = [
      "mkdir -p build",
      "qemu-img convert -f qcow2 -O vdi 'build/qemu/voipappz-node-${local.version}.qcow2' 'build/voipappz-node-${local.version}.vdi'",
      "echo 'wrote build/voipappz-node-${local.version}.vdi'",
    ]
  }

  post-processor "shell-local" {
    only = ["qemu.direct"]
    inline = [
      "mkdir -p build",
      "qemu-img convert -f qcow2 -O vdi 'build/qemu-direct/voipappz-node-${local.version}.qcow2' 'build/voipappz-node-${local.version}.vdi'",
      "echo 'wrote build/voipappz-node-${local.version}.vdi'",
    ]
  }

  post-processor "shell-local" {
    only = ["qemu.installer"]
    inline = [
      "mkdir -p build",
      "qemu-img convert -f qcow2 -O vdi 'build/qemu-iso/voipappz-node-${local.version}.qcow2' 'build/voipappz-node-${local.version}.vdi'",
      "echo 'wrote build/voipappz-node-${local.version}.vdi'",
    ]
  }

  post-processor "manifest" {
    output     = "build/manifest.json"
    strip_path = true
  }
}
