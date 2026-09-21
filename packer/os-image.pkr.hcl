# VoIPAppz OS image — a bootable, OFFLINE Ubuntu installer ISO.
#
#   packer/build.sh init
#   packer/build.sh build -only='voipappz-os.null.iso' .
#
# SCOPE: this builds an OPERATING SYSTEM. Ubuntu 24.04.4, docker, the SIP and
# network tooling a node is debugged with, and the voipappz CLI binary. It does
# NOT install the VoIPAppz platform — `voipappz bootstrap` does that afterwards,
# against a machine that already has everything it needs to run it.
#
# The split is why a docker packaging failure can no longer throw away a
# completed OS install. It did exactly that once: a late-command returning 100
# discarded a finished partition table, bootloader and base system because one
# package would not unpack.
#
# WHY source "null"
#
# Packer's model is source → provision → post-process: it boots or creates a
# machine, configures it, and captures the result. Remastering an ISO has no
# machine — the work is unpacking one ISO, adding files, and writing another.
# `null` with `communicator = "none"` is the supported way to express "this
# build runs locally", and it is what lets the package list, the base image and
# the destination live in HCL as real variables with `packer validate` over
# them, rather than as constants buried in a shell script.
#
# The provisioners shell out to packer/scripts/*.sh rather than inlining the
# work, for the same reason the make targets shell out to build.sh: one
# implementation, and the scripts stay usable on their own.

# ---------------------------------------------------------------- variables
#
# NOTE every .pkr.hcl in this directory merges into ONE configuration, so these
# share a namespace with voipappz.pkr.hcl. `cli_version` and the
# `required_plugins` block are declared THERE and deliberately not repeated
# here — a second declaration is a hard "Duplicate variable" error, not a
# shadow.

variable "os_packages" {
  type = list(string)

  # THE list. Defined here and nowhere else: stage-payload.sh downloads exactly
  # this closure, and make-installer-iso.sh substitutes exactly this list into
  # the autoinstall. A second copy would drift, and the failure mode is a
  # package that is on the CD but never installed — or the reverse, an install
  # that asks for a package the CD does not carry, which aborts the whole thing.
  #
  # On an offline box you cannot apt-get anything later, so what is not in this
  # list is not on the machine, ever.
  default = [
    # Docker. From download.docker.com, not Ubuntu's older docker.io.
    "docker-ce", "docker-ce-cli", "containerd.io",
    "docker-buildx-plugin", "docker-compose-plugin",

    # SIP and packet capture. A voip node without sngrep is a node you cannot
    # debug a call on, and it is not installable after the fact when air-gapped.
    "sngrep", "tcpdump", "ngrep",

    # chrony: RTP and SIP timers care about the clock, and drift also breaks
    # certificate validity windows.
    # openssl: `voipappz setup` generates the placeholder certs with it, and
    # neither Kong nor kamailio will start without a certificate on disk.
    "chrony", "openssl", "ca-certificates",

    # Ordinary triage: what is listening, what is slow, what is resolving, what
    # a process is actually doing.
    "htop", "iotop", "lsof", "strace",
    "jq", "vim", "git", "curl", "wget", "unzip",
    "net-tools", "ethtool", "traceroute", "mtr-tiny", "bind9-dnsutils",
  ]
  description = "Every package baked into the OS image. Single source of truth for both the download and the install."
}

variable "base_iso" {
  type    = string
  default = "cache/ubuntu-24.04.4-live-server-amd64.iso"

  # A LOCAL file, relative to packer/. Not a URL: Packer's ISO downloader does
  # not resume, so a stalled transfer restarts from zero and the build dies with
  # "connection timed out" having done nothing. Fetch it once by hand:
  #   curl -fL -C - --retry 10 -o packer/cache/... https://releases.ubuntu.com/...
  description = "Ubuntu live-server ISO to remaster, relative to packer/."
}

variable "dest_dir" {
  type    = string
  default = ""
  # The Windows side, because that is where the ISO gets attached to a VM or
  # written to a USB stick from — a WSL-only path is reachable by neither.
  description = "Where the finished ISO is delivered."
}

variable "installer_env" {
  type    = string
  default = ""

  # An answer sheet for `voipappz setup`, baked to /etc/voipappz/installer.env.
  # Empty is the normal case: the node then installs and waits, unconfigured,
  # rather than guessing a domain and looking configured when it is not.
  #
  # Filled in, it makes the node self-configuring — and makes the ISO a SECRET,
  # because the file carries the Cloudflare token and SMTP password. Cut one per
  # tenant.
  description = "Path to a voipappz setup answer sheet to bake in. Empty = node waits for `voipappz setup`."
}

variable "network" {
  type    = string
  default = "autoinstall/network.default.yaml"

  # The whole `network:` key, kept in its own file because addressing is the one
  # thing that is per-SITE — an ISO with a static address baked in builds exactly
  # one machine. Copy the default, edit the ethernets block, point this at it.
  description = "netplan config substituted into the autoinstall, relative to packer/."
}

variable "with_images" {
  type        = bool
  default     = true
  description = "Bake the node container image onto the ISO so the node needs no registry. false = the node pulls at `up` time."
}

variable "refresh_packages" {
  type        = bool
  default     = true
  description = "Re-resolve and re-download the package closure. Set false to re-cut an ISO from an unchanged payload without touching the network."
}

# ---------------------------------------------------------------- delivery
#
# Copying the finished ISO to another machine over SSH. Empty host = do not
# deliver, which is the default: an ISO left in build/iso/ is a finished build,
# not a failed one.
#
# This is the remote counterpart to `dest_dir`. That one is a PATH on this
# machine (usually the Windows side, over 9p); these reach a box that is not
# this one — a build host, a jump box in the customer's DC, or the hypervisor
# that will attach the disc.

variable "deliver_host" {
  type    = string
  default = "unset.invalid"

  # `.invalid` is reserved by RFC 2606 and can never resolve, so forgetting
  # -var deliver_host fails instantly and unmistakably instead of reaching some
  # real machine. It cannot be empty: `packer validate` checks EVERY source in
  # the directory, including this one, and an SSH communicator with no host is a
  # hard error — which would break validation of the ISO build next to it.
  description = "SSH host to copy the finished ISO to. Required for the voipappz-deliver build."
}

variable "deliver_user" {
  type        = string
  default     = "root"
  description = "SSH user for delivery. Matches `voipappz deploy`'s default."
}

variable "deliver_key" {
  type    = string
  default = ""

  # Empty, deliberately. A default path would be checked by `packer validate`,
  # which stats the file — so naming ~/.ssh/id_rsa fails validation outright on
  # any machine whose key is an ed25519, which is most of them now. The
  # placeholder password below is what satisfies the communicator's "one
  # authentication method" rule at validate time instead; it needs no file to
  # exist. A real delivery passes -var deliver_key=<path>, and the key wins over
  # the password when both are set.
  description = "SSH private key for delivery. Empty = use deliver_password."
}

variable "deliver_port" {
  type        = string
  default     = "22"
  description = "SSH port for delivery."
}

variable "deliver_password" {
  type      = string
  default   = "unset-pass-deliver_key-or-deliver_password"
  sensitive = true

  # A placeholder, not a credential: it exists so the SSH communicator has an
  # auth method at validate time (see deliver_key). It can never reach anything,
  # because the default host is unresolvable by construction.
  description = "SSH password for delivery, if the target has no key. Prefer a key."
}

variable "deliver_timeout" {
  type        = string
  default     = "10m"
  description = "How long to wait for SSH on the delivery target."
}

variable "deliver_install" {
  type    = bool
  default = false

  # Off by default: delivery puts a disc on a machine, installation CHANGES that
  # machine. Those are different levels of consent and the flag is where the
  # difference lives.
  description = "After copying the ISO, mount it and install the OS payload (packages, docker, the node image, the CLI) onto the target."
}

variable "deliver_dir" {
  type        = string
  default     = "/var/lib/voipappz/isos"
  description = "Directory on the remote host to copy the ISO into. Created if missing."
}

# ---------------------------------------------------------------- source

source "null" "iso" {
  # No machine to talk to. Every provisioner below is shell-local.
  communicator = "none"
}

# ---------------------------------------------------------------- build

build {
  name    = "voipappz-os"
  sources = ["source.null.iso"]

  # 1) The offline payload: the package closure as a real apt repository, plus
  #    the CLI binary and stack templates.
  #
  #    The closure is resolved with `apt-cache depends --recurse`, NOT
  #    `apt-get install -d`. The latter resolves against the BUILDER's installed
  #    set, so every dependency the container already had is silently skipped —
  #    that shipped a payload missing libgssapi-krb5-2, libssh-4, libldap2 and
  #    four more, and the target died with seven unmet dependencies.
  provisioner "shell-local" {
    only_on = ["linux", "darwin"]
    env = {
      OS_PACKAGES = join(" ", var.os_packages)
    }
    inline = [
      "set -euo pipefail",
      "cd ${path.root}",
      var.refresh_packages ? "scripts/stage-payload.sh debs" : "echo '>> reusing the existing package payload'",
      "scripts/stage-payload.sh stack",
    ]
  }

  # 2) Cut the ISO. The same package list is substituted into the autoinstall,
  #    so what the CD carries and what the installer asks for cannot disagree.
  provisioner "shell-local" {
    only_on = ["linux", "darwin"]
    env = {
      OS_PACKAGES = join(" ", var.os_packages)
      SRC_ISO     = "${path.root}/${var.base_iso}"
    }
    inline = [
      "set -euo pipefail",
      "cd ${path.root}",
      "./make-installer-iso.sh --dest '${var.dest_dir}' --cli-version '${var.cli_version}' --network '${var.network}'${var.with_images ? "" : " --no-images"}${var.installer_env != "" ? " --installer-env '${var.installer_env}'" : ""}",
    ]
  }
}


# ---------------------------------------------------------------- delivery
#
# A SECOND null source, this one with a real SSH communicator: Packer connects
# to a machine that already exists and provisions it. That is exactly what the
# null builder is for — the ISO-cutting source above is the other half of it,
# `communicator = "none"`, because that half has nothing to talk to.
#
# Packer owns the connection here rather than a script shelling out to ssh: auth,
# the retry-until-reachable loop, and `ssh_timeout` are the builder's job, and
# `packer validate` covers the settings.

source "null" "deliver" {
  communicator         = "ssh"
  ssh_host             = var.deliver_host
  ssh_username         = var.deliver_user
  # EXACTLY one auth method — Packer rejects "only one of ssh_agent_auth,
  # ssh_password, and ssh_private_key_file must be specified" when both are set,
  # so the password is unset the moment a key is named rather than sitting there
  # as a placeholder.
  ssh_private_key_file = var.deliver_key != "" ? var.deliver_key : null
  ssh_password         = var.deliver_key == "" ? var.deliver_password : null
  ssh_port             = var.deliver_port
  ssh_timeout          = var.deliver_timeout
}

build {
  name    = "voipappz-deliver"
  sources = ["source.null.deliver"]

  # The ISO's name carries a build timestamp and HCL cannot glob, so the file
  # provisioner has no way to name it. Stage the newest one into a directory of
  # its own and upload THAT — the upload keeps the real filename, and the
  # staging dir holds nothing else.
  #
  # A hard link, not a copy: same filesystem, instant, and no second 8.4GB on
  # disk. build/iso/ also holds `add/` (the CD staging tree) and grub.cfg, which
  # is why this cannot just upload build/iso/ wholesale.
  provisioner "shell-local" {
    only_on = ["linux", "darwin"]
    inline = [
      "set -euo pipefail",
      "cd ${path.root}",
      "test '${var.deliver_host}' != 'unset.invalid' || { echo '!! set -var deliver_host=<target>' >&2; exit 1; }",
      "iso=$(ls -t build/iso/voipappz-os-*.iso 2>/dev/null | head -1)",
      "test -n \"$iso\" || { echo '!! no ISO in build/iso — run make iso first' >&2; exit 1; }",
      "rm -rf build/deliver && mkdir -p build/deliver",
      "ln -f \"$iso\" \"build/deliver/$(basename \"$iso\")\" 2>/dev/null || cp \"$iso\" build/deliver/",
      "echo \">> staged $(basename \"$iso\") ($(du -h \"$iso\" | cut -f1)) for delivery\"",
    ]
  }

  # Runs ON THE TARGET, through the communicator above.
  provisioner "shell" {
    inline = ["mkdir -p '${var.deliver_dir}'"]
  }

  provisioner "file" {
    source      = "build/deliver/"
    destination = "${var.deliver_dir}/"
  }

  # Prove it landed whole. A truncated ISO still lists like an ISO, and the only
  # symptom is an unbootable disc at the far end.
  provisioner "shell" {
    inline = [
      "ls -l '${var.deliver_dir}'",
      "sha256sum '${var.deliver_dir}'/voipappz-os-*.iso",
    ]
  }

  # Install the disc's payload ONTO this machine, instead of leaving it to be
  # booted. Same steps the autoinstall's late-commands run, in the same order,
  # against a machine that is already running: mount, wire the offline apt
  # repository, install, load the images, drop the CLI on PATH.
  #
  # `execute_command` with sudo -S: the target user is a normal account, and
  # every step here needs root.
  provisioner "shell" {
    # There is no conditional provisioner in Packer — `only`/`except` filter by
    # BUILD name, not by a variable. So the flag travels as an env var and the
    # script returns early when it is false, the same way `refresh_packages`
    # picks between two inline strings above.
    execute_command = "echo '${var.deliver_password}' | {{.Vars}} sudo -S -E bash '{{.Path}}'"
    environment_vars = [
      "VA_INSTALL=${var.deliver_install}",
      "OS_PACKAGES=${join(" ", var.os_packages)}",
      "ISO_DIR=${var.deliver_dir}",
    ]
    script = "scripts/remote-install.sh"
  }
}
