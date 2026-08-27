#!/bin/sh
# Mint a time-limited download link for one node ISO.
#
#   packer/scripts/presign-iso.sh 2026.08.27-1
#   packer/scripts/presign-iso.sh 2026.08.27-1 86400        # one day
#
# The argument is the disc's RELEASE version — what names the ISO — not the
# version of the node image it carries. Those are two different numbers; the
# identity stamp inside the disc records both.
#
# WHY THIS EXISTS AT ALL
#
# The disc is RESTRICTED media. It carries a `docker save` of the private
# nirlevi/va-crystal node image, so anyone who can download the ISO can
# `docker load` that image straight out of the payload — the disc is exactly as
# private as the image is. The bucket has Block Public Access on, the publishing
# workflow sets no ACL, and the role it assumes cannot set one. There is no
# public URL for this object and there must not be one.
#
# So a customer gets a presigned URL: a signed, expiring link to one object.
#
# A PRESIGNED URL IS A BEARER CREDENTIAL. Anyone who holds it can download the
# disc until it expires — no AWS account, no login, no audit trail beyond the
# S3 access log. Treat it like a password:
#
#   * Send it over a channel you would send a password over, to one named
#     person. Not a public issue, not a shared channel, not a support ticket
#     that a wider team can read later.
#   * Never paste one into CI. This script is deliberately NOT run by
#     .github/workflows/node-iso.yml: a job log on a public repository is
#     world-readable, and a URL printed there is the disc handed to everyone.
#   * Give it the shortest life that works. The default here is one hour.
#   * Tell the recipient not to re-host what they download.
#
# HOW LONG A URL CAN LIVE
#
# SigV4 caps a presigned URL at 7 days (604800 seconds) — the AWS CLI refuses a
# longer --expires-in. But the URL also dies with the credentials that signed
# it, and that is usually the real limit:
#
#   * TEMPORARY credentials (anything from STS: an assumed role, SSO, an
#     instance profile, `aws sts get-session-token`) — the URL stops working
#     when the session token expires, however long --expires-in claimed. A role
#     session is 1 hour by default and at most the role's MaxSessionDuration,
#     which is at most 12 hours. Signing a 7-day URL with a 1-hour session
#     produces a link that quietly 403s after an hour.
#   * A long-lived IAM USER access key — the full 7 days is available, because
#     nothing else expires first.
#
# Ask for a lifetime and this script says which of those you are on and what you
# actually got.
set -eu

BUCKET="${ISO_S3_BUCKET:-voipappz-assets-il}"
PREFIX="${ISO_S3_PREFIX:-iso/}"
REGION="${ISO_S3_REGION:-il-central-1}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }

VERSION="${1:-}"
EXPIRES="${2:-3600}"
[ -n "$VERSION" ] || die "usage: $0 <iso-release-version> [seconds] — e.g. $0 2026.08.27-1 86400"
case "$VERSION" in
  latest) die "media is pinned; there is no 'latest' disc" ;;
  *[!A-Za-z0-9._-]*) die "version may only hold A-Z a-z 0-9 . _ -" ;;
esac
case "$EXPIRES" in
  ''|*[!0-9]*) die "seconds must be a number" ;;
esac
[ "$EXPIRES" -le 604800 ] || die "SigV4 caps a presigned URL at 604800 seconds (7 days)"

command -v aws >/dev/null 2>&1 || die "the AWS CLI is not installed"

# voipappz-node-, not va-crystal-node-: that prefix belongs to va-crystal's
# image tarballs in this same bucket.
KEY="${PREFIX%/}/voipappz-node-$VERSION.iso"
case "$KEY" in /*) KEY="${KEY#/}" ;; esac
URI="s3://$BUCKET/$KEY"

# Prove the object is there before minting a link to it: a presigned URL for a
# missing key is a valid signature over nothing, and the customer discovers that
# instead of you.
aws s3api head-object --bucket "$BUCKET" --key "$KEY" --region "$REGION" >/dev/null 2>&1 \
  || die "$URI does not exist (or these credentials cannot read it)"

# Which kind of credential is signing. `aws sts get-caller-identity` names an
# assumed-role session as arn:aws:sts::…:assumed-role/…; a plain IAM user is
# arn:aws:iam::…:user/….
CALLER="$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || printf 'unknown')"
case "$CALLER" in
  *:assumed-role/*|*:federated-user/*)
    printf '   signing with TEMPORARY credentials (%s).\n' "$CALLER" >&2
    printf '   The link dies when that session does — at most the role'"'"'s\n' >&2
    printf '   MaxSessionDuration (12 hours), whatever %s says. For a longer\n' "$EXPIRES" >&2
    printf '   link, sign with a long-lived IAM user key.\n' >&2 ;;
  *) printf '   signing as %s\n' "$CALLER" >&2 ;;
esac

printf '   %s, valid for %s seconds. This URL is a bearer credential:\n' "$URI" "$EXPIRES" >&2
printf '   send it to one named person over a channel you would send a password over.\n' >&2
printf '   The disc holds a private image and must not be re-hosted.\n\n' >&2

# stdout, alone, so it can be piped somewhere sensible and so every warning
# above stays on stderr and out of whatever captured it.
aws s3 presign "$URI" --expires-in "$EXPIRES" --region "$REGION"
