# MOVED FROM mothership/packer/Dockerfile.builder and trimmed to the node case.
# Removed: qemu-system-x86_64 and qemu-img (there is no qemu source here — the
# only source is `null`, which boots nothing), openssh-client and sshpass (they
# served the delivery build's SSH communicator, which did not come across), and
# python3 (the mothership patched grub.cfg with it; make-node-iso.sh does the
# same two edits in awk, and this repository keeps Python out).
# Kept: packer, xorriso, the docker client, and the apk cache mount.
#
# Why this exists: packer/build.sh runs Packer here when the workstation has
# none, and the ISO cut needs `xorriso` on the same machine as `packer`.
# hashicorp/packer has only the first, and installing the rest system-wide needs
# root on the workstation. This image is the whole toolchain.

FROM hashicorp/packer:latest AS packer

FROM alpine:3.22
# --mount=type=cache keeps apk's downloads in a BuildKit cache volume that
# survives image rebuilds, so adding one package does not refetch the others.
# This matters more here than usual: apk against a slow link has taken over an
# hour for `apk add xorriso` alone, and every Dockerfile edit would otherwise
# pay that again from zero.
#
# --no-cache is dropped deliberately — it means "do not keep an index", which
# defeats the mount. The cache lives outside the image either way, so no layer
# grows.
RUN --mount=type=cache,target=/var/cache/apk \
    apk add \
      # THE tool. make-node-iso.sh unpacks the Ubuntu ISO, replays its boot
      # records and writes the remastered one with it.
      xorriso \
      bash \
      curl \
      ca-certificates \
      # node-iso.pkr.hcl's shell-local provisioners drive containers of their
      # own (apt in a noble image, the chown-back) and pull and save the node
      # image. Packer runs INSIDE this image, so without a docker client those
      # steps die with "docker: command not found". The client only — the
      # daemon stays the host's, reached through the socket build.sh mounts.
      docker-cli \
      # make-node-iso.sh stamps the installer commit onto the disc.
      git
COPY --from=packer /bin/packer /usr/local/bin/packer
WORKDIR /repo/packer
ENTRYPOINT ["/usr/local/bin/packer"]
