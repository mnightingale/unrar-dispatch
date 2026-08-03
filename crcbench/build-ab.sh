#!/bin/sh
#
# Build unrar twice - with and without the CRC32 folding path - so the
# end-to-end effect can be measured with dispatch/bench.sh.
#
# Microbenchmark throughput is not user-visible speedup: CRC is only a slice
# of unrar's runtime, so this measures the number that actually matters.
#
# Output goes to its own directory so it does not disturb any ISA-level
# variants already built in dispatch/build.
#
# Usage:
#   crcbench/build-ab.sh [-o outdir] [-j jobs]
#   dispatch/bench.sh -b crcbench/build-ab -c dispatch/corpus
#
# Variants are named so that `ls` order puts the baseline first, which makes
# bench.sh's "delta" column read as folding-vs-baseline (positive = faster).

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/crcbench/build-ab"
JOBS=""

while [ $# -gt 0 ]; do
  case $1 in
    -o) OUT=$2; shift 2 ;;
    -o*) OUT=${1#-o}; shift ;;
    -j) JOBS=$2; shift 2 ;;
    -j*) JOBS=${1#-j}; shift ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$JOBS" ]; then
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

build() {
  name=$1
  flags=$2

  echo "==> $name  (CPPFLAGS='$flags')"
  make -C "$ROOT" clean >/dev/null
  make -C "$ROOT" -j"$JOBS" CPPFLAGS="$flags" >"$OUT/$name.buildlog" 2>&1 || {
    echo "!!! build failed; see $OUT/$name.buildlog" >&2
    tail -20 "$OUT/$name.buildlog" >&2
    exit 1
  }
  mv "$ROOT/unrar" "$OUT/unrar.$name"
  echo "    -> $OUT/unrar.$name"
}

build a-nofold "-DNO_CRC_FOLD"
build b-fold   ""

# Leave the source tree clean.
make -C "$ROOT" clean >/dev/null 2>&1 || true

echo
echo "Confirming the two builds really differ:"
for v in a-nofold b-fold; do
  n=$( { objdump -d "$OUT/unrar.$v" 2>/dev/null || otool -tv "$OUT/unrar.$v" 2>/dev/null; } \
       | grep -ci pclmul || true )
  printf '  %-12s %s pclmulqdq instructions\n' "$v" "$n"
done

echo
echo "Now run:"
echo "  dispatch/bench.sh -b $OUT -c $ROOT/dispatch/corpus"
