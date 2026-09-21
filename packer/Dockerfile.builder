# Build host for the qemu source, containerised.
#
# Why this exists: the qemu build needs `packer` AND `qemu-system-x86_64` AND
# `qemu-img` on the same machine. hashicorp/packer has only the first, and
# installing the rest system-wide needs root on the workstation. This image is
# the whole toolchain, and `packer/build.sh` runs it with --device /dev/kvm.
#
# The AMI source needs none of this (the build happens in EC2) but works here
# too — mount ~/.aws or pass AWS_* through.
FROM hashicorp/packer:latest AS packer

FROM alpine:3.22
# --mount=type=cache keeps apk's downloads in a BuildKit cache volume that
# survives image rebuilds, so adding one package does not refetch the other
# eight. This matters more here than usual: apk against this link is slow
# enough that `apk add xorriso` alone has taken over an hour, and every
# Dockerfile edit otherwise pays that again from zero.
#
# --no-cache is dropped deliberately — it means "do not keep an index",
# which defeats the mount. The cache lives outside the image either way, so
# no layer grows.
RUN --mount=type=cache,target=/var/cache/apk \
    apk add \
      qemu-system-x86_64 \
      qemu-img \
      # cd_files builds the cloud-init `cidata` CD, and Packer shells out to an
      # ISO creation tool to do it — without one the qemu source dies in under a
      # second with "could not find a supported CD ISO creation command".
      xorriso \
      bash \
      curl \
      ca-certificates \
      openssh-client \
      # scripts/ssh-install.sh authenticates with a password when no key
      # is given, and ssh will only read one from a TTY — which a Packer
      # provisioner and a CI runner both lack.
      sshpass \
      # os-image.pkr.hcl's shell-local provisioners drive containers (apt in a
      # noble image, xorriso, chown-back). Packer runs INSIDE this image, so
      # without a docker client those steps die with "docker: command not
      # found". The client only — the daemon stays the host's, reached through
      # the socket build.sh mounts.
      docker-cli \
      python3
COPY --from=packer /bin/packer /usr/local/bin/packer
WORKDIR /w
ENTRYPOINT ["/usr/local/bin/packer"]
