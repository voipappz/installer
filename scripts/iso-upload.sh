#!/bin/sh
# The newest cut ISO to S3 — `make iso-upload`.
#
# Published the way va-crystal publishes the node image archive
# (scripts/s3-publish.sh there): a pinned name, a moving one, and a checksum
# beside each.
#
#   s3://<bucket>/<prefix>/voipappz-node-<VERSION>.iso          (+ .sha256)
#   s3://<bucket>/<prefix>/voipappz-node-latest.iso             (+ .sha256)
#
# `latest` is a server-side copy — the same bytes, not a second 5GB upload.
#
# NO ACL IS SET, and none must be. The disc carries a `docker save` of the
# PRIVATE node image, so anyone who can download it can load that image out of
# the payload: the disc is exactly as restricted as the image. Hand one to a
# customer with a presigned URL, minted by a person, out of band.
#
# Credentials come from ~/.aws or the environment, NEVER a file in the repo.
#
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... make iso-upload
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DOCKER="${DOCKER:-docker}"
S3_BUCKET="${S3_BUCKET:-voipappz-assets-il}"
S3_PREFIX="${S3_PREFIX:-iso}"
S3_REGION="${S3_REGION:-il-central-1}"
AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-amazon/aws-cli:latest}"

if [ ! -f "$HOME/.aws/credentials" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo "!! no credentials — write ~/.aws/credentials or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" >&2
  exit 1
fi

# `|| true`: ls is non-zero when the glob matches nothing, which is the case the
# next line reports properly.
# shellcheck disable=SC2012  # newest-first by mtime; the names are ours
iso="$(ls -t packer/build/iso/voipappz-node-*.iso 2>/dev/null | head -1 || true)"
if [ -z "$iso" ]; then
  echo "!! no ISO in packer/build/iso — run make iso first" >&2
  exit 1
fi
name="$(basename "$iso")"
dir="$(dirname "$iso")"
latest="voipappz-node-latest.iso"

# `sha256sum` format, name included, so `sha256sum -c` works on a download
# sitting beside it — the form the bucket's earlier discs already use.
echo ">> checksum of $name ($(du -h "$iso" | cut -f1))"
( cd "$dir" && sha256sum "$name" > "$name.sha256" )
sed "s/  $name\$/  $latest/" "$dir/$name.sha256" > "$dir/$latest.sha256"
echo "   $(cut -d' ' -f1 "$dir/$name.sha256")"

# The host's ~/.aws is mounted at a side path and COPIED into place inside the
# throwaway container: `aws configure set` below writes ~/.aws/config, and on a
# read-only mount that is "[Errno 30] Read-only file system" — which is how two
# va-crystal releases reached Docker Hub and never reached S3.
awsmount=""
[ -d "$HOME/.aws" ] && awsmount="-v $HOME/.aws:/host-aws:ro"

# Fewer, larger parts in flight and adaptive retries: a multi-GB multipart
# upload from a home uplink hits RequestTimeout on the CLI's defaults.
aws() {
  # shellcheck disable=SC2086  # $awsmount is deliberately two words or none
  $DOCKER run --rm --network host \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
    -e AWS_DEFAULT_REGION="$S3_REGION" \
    -e AWS_MAX_ATTEMPTS=10 -e AWS_RETRY_MODE=adaptive \
    $awsmount \
    -v "$ROOT/$dir:/data:ro" \
    --entrypoint sh "$AWS_CLI_IMAGE" -c '
      if [ -d /host-aws ]; then mkdir -p /root/.aws && cp /host-aws/* /root/.aws/ && chmod 600 /root/.aws/*; fi
      aws configure set default.s3.multipart_chunksize 32MB
      aws configure set default.s3.max_concurrent_requests 4
      exec aws --cli-read-timeout 300 --cli-connect-timeout 60 "$@"' sh "$@"
}

base="s3://$S3_BUCKET/$S3_PREFIX"

# A version that changes under someone who already downloaded it is worse than
# no disc. The unix time in the name makes a collision an accident of copying,
# not of cutting — and it is refused either way. `latest` is a moving name by
# definition and is always replaced.
if aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_PREFIX/$name" >/dev/null 2>&1; then
  echo "!! $base/$name is already published — cut a new disc, do not overwrite one" >&2
  exit 1
fi

echo ">> uploading $name to $base/"
aws s3 cp "/data/$name" "$base/$name" --no-progress
aws s3 cp "/data/$name.sha256" "$base/$name.sha256" --no-progress
aws s3 cp "$base/$name" "$base/$latest" --no-progress
aws s3 cp "/data/$latest.sha256" "$base/$latest.sha256" --no-progress

echo ">> published $base/$name"
echo "             $base/$latest"
echo "   private — share it with a presigned URL, e.g. (valid 7 days):"
echo "   aws s3 presign $base/$name --expires-in 604800 --region $S3_REGION"
