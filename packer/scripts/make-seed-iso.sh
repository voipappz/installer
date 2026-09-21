#!/usr/bin/env bash
# Build the cloud-init NoCloud seed ISO (packer/cache/seed.iso).
#
# Packer's `cd_files` would do this, but it shells out to xorriso/mkisofs and
# the builder image could not get one — `apk add xorriso` ran for over an hour
# on this link. pycdlib is pure Python, installs in seconds, and writes a
# perfectly good ISO9660 with the volume label cloud-init requires.
#
# The label MUST be CIDATA (uppercase). NoCloud finds its datasource by
# filesystem label, so a wrong label means the image boots with no user, no
# SSH, and Packer sits at "Waiting for SSH" until it times out.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/cache/seed.iso"
mkdir -p "$HERE/cache"

docker run --rm \
  -v "$HERE/cloudinit:/in:ro" \
  -v "$HERE/cache:/out" \
  python:3.12-alpine sh -c '
    pip install -q pycdlib 2>/dev/null
    python - <<PY
import pycdlib
iso = pycdlib.PyCdlib()
# joliet + rock_ridge so the names survive; interchange_level 4 allows the long
# lowercase names cloud-init looks for.
iso.new(interchange_level=4, joliet=3, rock_ridge="1.09", vol_ident="CIDATA")
for name in ("user-data", "meta-data"):
    data = open("/in/" + name, "rb").read()
    iso.add_fp(__import__("io").BytesIO(data), len(data),
               "/" + name.upper().replace("-", "_") + ".;1",
               rr_name=name, joliet_path="/" + name)
    print("added", name, len(data), "bytes")
iso.write("/out/seed.iso")
iso.close()
print("wrote seed.iso")
PY
'

ls -lh "$OUT"
