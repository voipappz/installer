# MOVED FROM mothership/packer/os-image.pkr.hcl and trimmed to the node case.
# Removed: the seventeen-image payload, the CLI binary and stack templates, the
# installer_env answer sheet, the SIP/capture/triage package list (this disc
# installs a node, not a debugging workstation), the whole `voipappz-deliver`
# build with its SSH communicator and every deliver_* variable, and the
# cli_version shared with voipappz.pkr.hcl, which did not come across.
# Kept: the `null` source with communicator "none" and the reasoning for it, the
# package list as a first-class value, and the two shell-local provisioners.
# Added here: the two versions — the image this disc carries and the release
# this disc is.
#
# VA-Crystal NODE installer ISO — a bootable, offline Ubuntu Server 24.04 disc
# that carries the operating system, Docker Engine, ONE container image and
# install.sh.
#
#   packer/build.sh validate -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
#   packer/build.sh build    -var image_version=2026.08.27-2 -var release_version=2026.08.27-1
#
# SCOPE. This repository installs ONE VoIP node and never the mothership
# (CLAUDE.md, "Purpose"), and this disc carries exactly that:
#
#   * Ubuntu Server 24.04, Docker Engine, and the four tools install.sh uses
#     (curl, ca-certificates, jq, openssl) — see os-packages.txt.
#   * ONE image, nirlevi/va-crystal:node-<version>, `docker save`d and gzipped.
#     The mothership's ISO stages seventeen; there is no Postgres here, no Kong,
#     no admin, no API, and nothing on this disc can run `voipappz bootstrap`.
#   * install.sh, unmodified, from this checkout.
#
# The disc does NOT install the node. It installs a machine that can, offline:
# the archive lands on the disk and the operator runs the installer, which
# already has the offline path — VA_IMAGE_SOURCE=archive with VA_IMAGE_ARCHIVE
# pointing at a `docker save` archive, `docker load`ed and retagged as
# $VA_VOIP_IMAGE (install.sh, step 2/6). Nothing about installation is
# reimplemented here; install.sh is the installer.
#
# WHY source "null"
#
# Packer's model is source → provision → post-process: it boots or creates a
# machine, configures it, captures the result. Remastering an ISO has no
# machine — the work is unpacking one ISO, adding files, writing another. `null`
# with `communicator = "none"` is the supported way to say "this build runs
# locally", and it is what makes a hosted GitHub runner enough: no KVM, no
# nested virtualisation, no qemu. It also lets the package list, the pinned
# image and the destination live in HCL as real values with `packer validate`
# over them rather than as constants buried in a shell script.
#
# The null builder is BUILT INTO Packer core. It is deliberately not declared in
# a required_plugins block: doing so sends `packer init` looking for
# hashicorp/packer-plugin-null, which does not exist, and fails with a bare 404.

packer {
  required_version = ">= 1.9.0"
}

# ---------------------------------------------------------------- variables

# TWO VERSIONS, and they are different numbers.
#
#   image_version    what goes ON the disc — va-crystal's published node image
#                    tag. Its version space belongs to va-crystal, and this
#                    repository only consumes it.
#   release_version  what the disc IS — the media's own release, minted here.
#                    A disc can be re-cut (a fixed autoinstall, a new package
#                    closure) around an unchanged image, and it must be a new
#                    release when that happens.
#
# Conflating them is how an operator ends up holding two different discs that
# claim the same name. Both are recorded, labelled, in the identity stamp at the
# root of the disc.

variable "image_version" {
  type    = string
  default = ""

  # PINNED, always. The tag is what the disc installs in five years' time, and
  # `latest` moves — two discs cut a week apart would install different
  # software while claiming to be the same media. Rejected rather than
  # defaulted, so a build cannot forget.
  description = "The node image version to bake, e.g. 2026.08.27-2. Becomes nirlevi/va-crystal:node-<image_version>."

  validation {
    condition = (
      var.image_version != "" &&
      var.image_version != "latest" &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.image_version))
    )
    # Packer requires this to read as a sentence: uppercase first letter, final
    # period, or it rejects the template outright.
    error_message = "Set image_version to a pinned tag suffix such as 2026.08.27-2, never empty and never 'latest'."
  }
}

variable "release_version" {
  type    = string
  default = ""

  # <YYYY.MM.DD>-<serial>, the shape va-crystal releases in, minted by
  # .github/workflows/node-iso.yml from what the bucket already carries. Not
  # defaulted to a timestamp here: two discs cut in the same minute would
  # collide, and a version nobody chose is a version nobody can quote.
  description = "This disc's own release version, e.g. 2026.08.27-1. The ISO is named voipappz-node-<release_version>.iso."

  validation {
    condition = (
      var.release_version != "" &&
      var.release_version != "latest" &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", var.release_version))
    )
    error_message = "Set release_version to a minted media version such as 2026.08.27-1, never empty and never 'latest'."
  }
}

variable "image_repository" {
  type        = string
  default     = "nirlevi/va-crystal"
  description = "Private repository the node image is pulled from. The tag is always node-<image_version>."
}

variable "os_packages_file" {
  type        = string
  default     = "os-packages.txt"
  description = "The package list, relative to packer/. One name per line; blank lines and #-comments ignored."
}

variable "base_iso" {
  type    = string
  default = "cache/ubuntu-24.04.4-live-server-amd64.iso"

  # A LOCAL file, relative to packer/. Not a URL: Packer's ISO downloader does
  # not resume, so a stalled 3GB transfer restarts from zero. Fetch it once with
  # scripts/fetch-base-iso.sh, which resumes and verifies against Ubuntu's
  # published SHA256SUMS.
  description = "Ubuntu live-server ISO to remaster, relative to packer/."
}

variable "network" {
  type    = string
  default = "autoinstall/network.default.yaml"

  # The whole `network:` key, in its own file because addressing is the one
  # thing that is per-SITE — a disc with a static address baked in builds
  # exactly one machine. Copy the default, edit the ethernets block, point this
  # at it.
  description = "netplan config substituted into the autoinstall, relative to packer/."
}

variable "dest_dir" {
  type        = string
  default     = ""
  description = "Where the finished ISO is delivered. Empty = leave it in packer/build/iso/."
}

variable "with_image" {
  type        = bool
  default     = true
  description = "Bake the node image onto the disc. false cuts a much smaller disc whose installer must reach a registry or an S3 archive."
}

variable "refresh_packages" {
  type        = bool
  default     = true
  description = "Re-resolve and re-download the package closure. false re-cuts a disc from an unchanged payload without touching the network."
}

# ---------------------------------------------------------------- locals

locals {
  # One list, two consumers. `regexall` rather than a startswith(): Packer's
  # function set is go-cty's, and this is the portable way to drop comments.
  os_packages = compact([
    for line in split("\n", file("${path.root}/${var.os_packages_file}")) :
    trimspace(line)
    if trimspace(line) != "" && length(regexall("^#", trimspace(line))) == 0
  ])

  node_image = "${var.image_repository}:node-${var.image_version}"

  # `voipappz-node-`, deliberately NOT `va-crystal-node-`. That name already
  # belongs to va-crystal's image tarballs in this same bucket
  # (va-crystal-node-<version>.tar.gz), and reusing it would put two different
  # artifacts, versioned by two different repositories, in one namespace — with
  # `va-crystal-node-2026.08.27-2.iso` sitting next to
  # `va-crystal-node-2026.08.27-2.tar.gz` and meaning something else. A distinct
  # prefix keeps "which repository decides this number" answerable from the
  # filename.
  iso_name = "voipappz-node-${var.release_version}.iso"
}

# ---------------------------------------------------------------- source

source "null" "iso" {
  # No machine to talk to. Every provisioner below is shell-local.
  communicator = "none"
}

# ---------------------------------------------------------------- build

build {
  name    = "va-crystal-node"
  sources = ["source.null.iso"]

  # 1) The offline payload: the package closure as a real apt repository, and
  #    the one node image, saved and gzipped.
  #
  #    The closure is resolved with `apt-cache depends --recurse`, NOT
  #    `apt-get install -d` — the latter resolves against the BUILDER's
  #    installed set, so every dependency the builder already had is silently
  #    skipped and the target dies with unmet dependencies.
  provisioner "shell-local" {
    only_on = ["linux", "darwin"]
    env = {
      OS_PACKAGES     = join(" ", local.os_packages)
      NODE_IMAGE      = local.node_image
      IMAGE_VERSION   = var.image_version
      RELEASE_VERSION = var.release_version
    }
    # `set -eu`, not `set -euo pipefail`: shell-local runs /bin/sh, which is
    # dash on Ubuntu, and dash has no pipefail — the option itself would be the
    # error. The scripts handle their own pipelines.
    inline = [
      "set -eu",
      "cd ${path.root}",
      var.refresh_packages ? "scripts/stage-payload.sh debs" : "echo '>> reusing the existing package payload'",
      var.with_image ? "scripts/stage-payload.sh image" : "echo '>> no image staged (-var with_image=false)'",
    ]
  }

  # 2) Cut the ISO. The same package list is substituted into the autoinstall,
  #    so what the disc carries and what the installer asks for cannot disagree.
  provisioner "shell-local" {
    only_on = ["linux", "darwin"]
    env = {
      OS_PACKAGES     = join(" ", local.os_packages)
      NODE_IMAGE      = local.node_image
      IMAGE_VERSION   = var.image_version
      RELEASE_VERSION = var.release_version
      ISO_NAME        = local.iso_name
      SRC_ISO         = "${path.root}/${var.base_iso}"
    }
    inline = [
      "set -eu",
      "cd ${path.root}",
      "./make-node-iso.sh --network '${var.network}'${var.with_image ? "" : " --no-image"}${var.dest_dir != "" ? " --dest '${var.dest_dir}'" : ""}",
    ]
  }
}
