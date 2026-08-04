#!/bin/sh
#
# Add stored archives of mid-sized files to an existing corpus.
#
# dispatch/make-corpus.sh covers the two ends: rar5-store-m0 is one 256 MB file
# (4 MB Update() calls) and rar5-many-m5 is 2000 x 4 KB files (4 KB calls, below
# the 32 KB threshold in UpdateCRC32MT, so never pooled). Neither lands in the
# band where the pool engages but the blocks are too small to pay for it, which
# is exactly where it loses.
#
# Each file becomes one Update() of its own size, because a stored file is
# CRC'd in File::CopyBufferSize() chunks (4 MB) and these are smaller than that.
# So this generates the 64 KB / 256 KB / 1 MB call sizes directly.
#
# Adds archives to the corpus rather than regenerating it, so an existing
# corpus on a benchmark box stays valid. Roughly 400 MB of extra disk.
#
# Note dispatch/make-corpus.sh starts with `rm -rf` on its output directory, so
# re-run this after any regeneration or these archives quietly disappear from
# bench.sh's table.
#
# Usage: crcmt/add-midsize-corpus.sh [-c corpusdir]

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/dispatch/corpus"
RAR=${RAR:-rar}

while [ $# -gt 0 ]; do
  case $1 in
    -c) OUT=$2; shift 2 ;;
    -c*) OUT=${1#-c}; shift ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v "$RAR" >/dev/null 2>&1 || {
  echo "$0: '$RAR' not found; the corpus needs the proprietary rar CLI." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "$0: python3 is required." >&2; exit 1; }

mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)
WORK="$OUT/.midsize"

# Incompressible input, stored: no LZ work at all, so the run is CRC and I/O
# and nothing else. Same reasoning as rar5-store-m0.
gen() { # kib count name
  kib=$1 count=$2 name=$3
  if [ -f "$OUT/$name" ]; then
    echo "  $name exists, skipping"
    return
  fi
  rm -rf "$WORK"
  mkdir -p "$WORK"
  python3 - "$WORK" "$kib" "$count" <<'PY'
import os, sys
work, kib, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
# One random blob, rotated per file: os.urandom per file is slow at this volume
# and the data only has to be incompressible, not independent.
blob = os.urandom(kib * 1024 + 4096)
for i in range(count):
    off = (i * 4093) % 4096
    with open(os.path.join(work, 'f%05d.bin' % i), 'wb') as f:
        f.write(blob[off:off + kib * 1024])
PY
  ( cd "$WORK" && "$RAR" a -inul -ep -y -ma5 -m0 "$OUT/$name" . >/dev/null )
  rm -rf "$WORK"
  printf '  %-28s %s x %s KB\n' "$name" "$count" "$kib"
}

echo "==> adding mid-size stored archives to $OUT"
gen 64   2048 rar5-mid64k-m0.rar
gen 256   512 rar5-mid256k-m0.rar
gen 1024  128 rar5-mid1m-m0.rar

echo
echo "Now run:  crcmt/bench.sh -c $OUT"
