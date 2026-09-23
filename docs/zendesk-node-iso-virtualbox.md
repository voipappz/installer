# Installing a VoIPAppz node in VirtualBox from the offline ISO

**Applies to:** the `voipappz-os-*.iso` installer disc · VirtualBox 7.x on Windows, macOS or Linux

The VoIPAppz installer ISO installs a complete node — Ubuntu Server, Docker, the
SIP tooling and the node container image — on a machine with no internet
connection. This article covers running it in VirtualBox.

## Before you start

| | |
|---|---|
| RAM | 6 GB (4 GB minimum) |
| Disk | 40 GB |
| CPUs | 2 |
| Network | Bridged — a node needs an address on your LAN |
| Guest OS type | **Linux → Ubuntu (64-bit)** |

You do **not** need to download Ubuntu. The disc carries its own operating
system.

## Create the virtual machine

1. **Machine → New**. Name it (for example `va-node`) and select the ISO file.
2. **Tick "Skip Unattended Installation".** See the warning below — this one
   matters.
3. Set memory to 6144 MB and 2 CPUs.
4. Create a new virtual hard disk of 40 GB.
5. Open **Settings → Network** and set Adapter 1 to **Bridged Adapter**,
   attached to the network card your machine uses for the LAN.
6. Confirm that **Settings → Storage** shows the ISO in the optical drive.

### Warning: skip VirtualBox's unattended installation

VirtualBox 7 recognises the ISO as an Ubuntu installer and offers to install it
for you, filling in a user name, password and hostname of its own.

The VoIPAppz disc already answers every one of those questions. If VirtualBox's
unattended installation is left enabled, the two sets of answers conflict and
the installation fails — usually as an installer that stops partway with a
message about the mirror or the disk layout, which does not name the real cause.

**Always tick "Skip Unattended Installation" on the first page of the wizard.**

## Install

Start the virtual machine and leave it alone. It installs with no questions,
which takes roughly 10 to 15 minutes.

**The machine powers itself off when the installation is finished. That is the
sign of success, not a failure.**

The disc powers the machine off rather than rebooting it deliberately: a reboot
with the disc still attached would start the installation again, and each pass
looks exactly like the first.

## First boot

1. Remove the disc: **Devices → Optical Drives → Remove disk from virtual
   drive** (or detach it in Settings → Storage).
2. Start the virtual machine again.
3. The first boot loads the node container image. This takes a few minutes and
   the screen stays quiet while it happens — the machine is not stuck.
4. Log in at the console as **`voipappz`**. The password set during the build
   is expired, so you are asked to choose a new one immediately.
5. Configure the node:

   ```
   sudo voipappz bootstrap
   ```

**Use `sudo` for every `voipappz` command on a node.** The `secrets/` directory
is readable only by root, so a command run without `sudo` cannot see what a
root run wrote and reports that there are no secrets.

## Troubleshooting

**The installer stops partway, or asks questions it should not.**
VirtualBox's unattended installation was left enabled. Delete the virtual
machine and create it again with "Skip Unattended Installation" ticked.

**The machine boots the installer a second time.**
The disc is still attached. Power it off, remove the disc, and start it again.

**Nothing happens on the first boot after installing.**
The node image is being loaded into Docker. Give it a few minutes. You can
confirm progress by logging in and running `sudo systemctl status
voipappz-loadimages`.

**The node has no network address.**
The adapter is probably set to NAT. Change Adapter 1 to Bridged Adapter in
Settings → Network, and restart the machine.

**The node cannot get a TLS certificate.**
A node with no route to the internet keeps its self-signed placeholder
certificate permanently. TLS still negotiates, so the node looks correctly
configured while real clients reject it. Run `sudo voipappz cert` to see which
certificate is in use.
