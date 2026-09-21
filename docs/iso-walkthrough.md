> **Moved from the mothership repo in 2026-09, unedited.** Written when the
> ISO carried the whole mothership stack (17 images). Media cut here now carries
> the node image only; the steps and gotchas still apply, the counts do not.

# Installing the mothership

Two ways in. Online, one command (see README.md, "Run it"):

```sh
curl -fsSL https://raw.githubusercontent.com/voipappz/mothership/main/installer/install.sh | sh
```

Or offline, from the ISO this document describes. A VoIP **node** is a
different machine and a different installer: github.com/voipappz/installer.

## The ISO

One disc. One machine. No internet.

Boot `voipappz-os-*.iso` and it installs Ubuntu 24.04.4, Docker, the SIP and
triage tooling, the `voipappz` CLI, and all 17 container images — on a machine
with no route out. Then one command brings the platform up.

The same guide with formatting: `packer/node-installer.html`.

## What you get

| | |
|---|---|
| OS | Ubuntu Server 24.04.4, installed unattended |
| Docker | 29.7 with compose and buildx |
| Tools | sngrep, tcpdump, ngrep, chrony, openssl + 18 more |
| CLI | `voipappz` on PATH, at `/opt/voipappz` |
| Images | all 18 containers, pre-loaded — nothing downloads |
| Login | `voipappz` / `voipappz`, changed on first use |

The disc does **not** configure the node — no domain, no secrets. That is step 5,
on the machine, because `voipappz setup` writes `.env` and `config/va.yaml`:
secrets plus node identity, which must never be identical on two machines.

## Install

### 1. Make a VM

80 GB disk, 8 GB RAM, 4 CPU. Network optional.

> **Tick "Skip Unattended Installation" in the VirtualBox wizard.** VirtualBox
> sees an Ubuntu ISO and offers to run its *own* unattended install, asking for
> a username and password. That fights the one on the disc — leave it on and you
> get VirtualBox's machine, not the node.

The disk is the setting that bites later: the images unpack to ~18 GB, and a
too-small disk shows up as `docker load` dying part-way through on first boot,
long after the choice was made.

### 2. Wait (10–25 min)

Scrolling text, no questions. It goes quiet for a while copying images off the
disc — that is normal. Then **the VM powers off by itself**.

### 3. Remove the disc, then start again

The VM is already off — don't restart it yet. Take the disc out first:
**Settings → Storage → optical drive → Remove Disk from Virtual Drive**.

> Start it with the disc still attached and it boots the installer again, wiping
> what it just built. That is why it powers off instead of rebooting — so you can
> pull the media first. It reinstalled three times in a row during testing before
> anyone noticed, because each pass looks identical to the first.

### 4. First boot (5–15 min)

It loads the 17 images, then stops at a login prompt saying:

```
no /etc/voipappz/installer.env — leaving this node unconfigured
run: voipappz setup
```

That is expected. Log in with `voipappz` / `voipappz` — you will be asked to
change the password straight away.

### 5. Bring it up

```bash
cd /opt/voipappz
sudo voipappz bootstrap
```

Runs the setup wizard, starts the app profile, health-checks it. Nothing
downloads — the images are already there.

Use `sudo` for **every** `voipappz` command on a node. `secrets/` is `0700`, so a
non-root run cannot read what a root run wrote, concludes there are no secrets,
and tries to generate new ones.

### 6. Seed both Kamailios

```bash
sudo voipappz sbc ingress sync
sudo voipappz sbc egress sync
```

> Both. They use separate storage, so syncing one does not seed the other.
> Skipping the ingress leaves its dispatcher empty and every call 404s.

## Check it worked

```
$ which docker voipappz sngrep tcpdump
/usr/bin/docker
/usr/local/bin/voipappz
/usr/bin/sngrep
/usr/bin/tcpdump

$ docker --version
Docker version 29.7.2

$ docker images | wc -l
19          # 18 + header
```

Also useful: `/etc/voipappz-images` (the 18 by digest), `/etc/voipappz-image`
(which ISO this node came from), and
`systemctl status voipappz-loadimages voipappz-firstboot`.

The CLI is present from the **install**; the images arrive on **first boot** —
`docker load` needs a running daemon and there is none inside the installer.

## Normal things that look wrong

| You see | It means |
|---|---|
| long silence | copying 4.6 GB off the disc |
| VM powers off | install finished — remove the disc |
| asks a question | VirtualBox's own installer is on; remake the VM |
| no wizard | no answer sheet; run `voipappz setup` |
| "unconfigured" | deliberate — it will not guess your domain |
| password rejected | expired on purpose; set a new one |
| TLS warnings | offline cannot get a real cert; `voipappz cert` confirms |

## Known limitations

- **An offline node cannot get a real certificate.** acme.sh needs Let's Encrypt
  and Cloudflare, so the node stays on the `CN=localhost` placeholder. TLS still
  negotiates, so it *looks* fine while real clients reject it.
- **`kamailio-ingress` does not stay up when the node's internal address is
  127.0.0.1** — it restart-loops on `udp_init(): Address already in use`. Every
  other service reaches healthy. Affects a pure-loopback install.
- **x86-64-v2 CPU required.** `minio` aborts with "Fatal glibc error" without it,
  and the only visible symptom is `dependency failed to start`. Real hardware has
  had it since 2009; a hypervisor presenting a generic CPU is the case that bites.

## Building a new ISO

```bash
make iso-payload    # once — pulls 17 images and saves them (~4.6 GB)
make iso            # ~90 seconds after that
```

| option | |
|---|---|
| `ISO_DEST=` | where it lands |
| `ISO_NETWORK=` | static IP instead of DHCP |
| `-var installer_env=` | answer sheet — node configures itself, no login |

If you use an answer sheet, set the domain, admin email, organisation and
profile — but **not** the IP addresses. Those are read off the machine. A
hand-entered internal IP once bound Kamailio to the wrong interface and 404'd
every call.

See `packer/README.md` for how the ISO is built and why.
