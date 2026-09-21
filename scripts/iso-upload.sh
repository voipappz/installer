#!/bin/sh
# The newest cut ISO to S3 — `make iso-upload`.
#
# Credentials come from ~/.aws (mounted read-only) or the environment, NEVER a
# file in the repo: scripts/check-repo-hygiene.sh scans for exactly that.
#
#   AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... make iso-upload
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DOCKER="${DOCKER:-docker}"
S3_BUCKET="${S3_BUCKET:-voipappz-assets-il}"
S3_PREFIX="${S3_PREFIX:-isos}"
S3_REGION="${S3_REGION:-il-central-1}"

if [ ! -f "$HOME/.aws/credentials" ] && [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  echo "!! no credentials — write ~/.aws/credentials or export AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY" >&2
  exit 1
fi

# `|| true`: ls is non-zero when the glob matches nothing, which is the case the
# next line reports properly.
# shellcheck disable=SC2012  # newest-first by mtime; the names are ours
iso="$(ls -t packer/build/iso/voipappz-os-*.iso 2>/dev/null | head -1 || true)"
if [ -z "$iso" ]; then
  echo "!! no ISO in packer/build/iso — run make iso first" >&2
  exit 1
fi
name="$(basename "$iso")"

echo ">> uploading $name ($(du -h "$iso" | cut -f1)) to s3://$S3_BUCKET/$S3_PREFIX/"

# The mount is read-only and the credential directory is too: this uploads, and
# can do nothing else.
awsmount=""
[ -d "$HOME/.aws" ] && awsmount="-v $HOME/.aws:/root/.aws:ro"

# shellcheck disable=SC2086  # $awsmount is deliberately two words or none
$DOCKER run --rm \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  -e AWS_DEFAULT_REGION="$S3_REGION" \
  $awsmount \
  -v "$ROOT/packer/build/iso:/data:ro" \
  amazon/aws-cli:latest \
  s3 cp "/data/$name" "s3://$S3_BUCKET/$S3_PREFIX/$name" --no-progress

echo ">> uploaded s3://$S3_BUCKET/$S3_PREFIX/$name"
