#!/bin/sh
#
# Build unrar once per ISA level from the unmodified vendored source.
#
# The vendored makefile never assigns CPPFLAGS, and its compile rule is
#   COMPILE=$(CXX) $(CPPFLAGS) $(CXXFLAGS) $(DEFINES)     (makefile:19)
# so passing CPPFLAGS on the make command line injects -march into every
# compile without editing the makefile or clobbering its own CXXFLAGS.
#
# Objects are built in-tree with fixed names and the makefile has a single
# .cpp.o suffix rule, so variants must be built sequentially with a clean
# in between.
#
# Usage:
#   dispatch/build-variants.sh [-o outdir] [-j jobs] [-a arch] [-l]
#
#   -l   force the full ladder even when the default target already covers it.
#        On arm64 this builds both armv8-a (crypto/crc compiled out, i.e. what
#        a stock Linux aarch64 build produces) and armv8-a+crc+crypto, so the
#        two can be benchmarked against each other on one machine.
#   -u   leave binaries unstripped (overrides the makefile's STRIP), so the
#        disassembly containment audit can attribute instructions to symbols.
#
# Environment:
#   CXX              compiler (default: c++)
#   EXTRA_CPPFLAGS   appended to every variant (e.g. "-O3", PGO flags)
#   EXTRA_LDFLAGS    appended to the link step (needed for -flto)

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/dispatch/build"
CXX=${CXX:-c++}
EXTRA_CPPFLAGS=${EXTRA_CPPFLAGS:-}
EXTRA_LDFLAGS=${EXTRA_LDFLAGS:-}
ARCH=$(uname -m)
JOBS=""
FORCE_LADDER=0
UNSTRIPPED=0

while [ $# -gt 0 ]; do
  case $1 in
    -o) OUT=$2; shift 2 ;;
    -o*) OUT=${1#-o}; shift ;;
    -j) JOBS=$2; shift 2 ;;
    -j*) JOBS=${1#-j}; shift ;;
    -a) ARCH=$2; shift 2 ;;
    -a*) ARCH=${1#-a}; shift ;;
    -l) FORCE_LADDER=1; shift ;;
    -u) UNSTRIPPED=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$JOBS" ]; then
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

# The vendored makefile's LDFLAGS default is -pthread; preserve it.
LDFLAGS="-pthread $EXTRA_LDFLAGS"

mkdir -p "$OUT"

# Does the compiler's *default* target already define a given feature macro?
# Used to avoid forcing -march when it would gain nothing (and, on Apple
# clang, would actively downgrade the ARMv8.5 baseline to ARMv8.0).
has_macro() {
  echo | "$CXX" -dM -E -x c++ - 2>/dev/null | grep -q "^#define $1 "
}

build_one() {
  variant=$1
  march=$2

  echo "==> $variant  (CPPFLAGS='$march $EXTRA_CPPFLAGS')"
  # STRIP=true turns the makefile's strip step into a no-op without editing it.
  [ "$UNSTRIPPED" -eq 1 ] && strip_cmd=true || strip_cmd=strip
  make -C "$ROOT" clean >/dev/null
  make -C "$ROOT" -j"$JOBS" \
       CPPFLAGS="$march $EXTRA_CPPFLAGS" \
       STRIP="$strip_cmd" \
       LDFLAGS="$LDFLAGS" >"$OUT/$variant.buildlog" 2>&1 || {
    echo "!!! build failed for $variant; see $OUT/$variant.buildlog" >&2
    tail -20 "$OUT/$variant.buildlog" >&2
    exit 1
  }
  mv "$ROOT/unrar" "$OUT/unrar.$variant"
  echo "    -> $OUT/unrar.$variant"
}

case $ARCH in
  x86_64|amd64)
    # x86-64-v2 = SSE3/SSSE3/SSE4.1/SSE4.2/POPCNT/CX16/LAHF-SAHF
    # x86-64-v3 = v2 + AVX/AVX2/BMI1/BMI2/F16C/FMA/LZCNT/MOVBE
    build_one x86-64    "-march=x86-64"
    build_one x86-64-v2 "-march=x86-64-v2"
    build_one x86-64-v3 "-march=x86-64-v3"
    ;;

  arm64|aarch64)
    # os.hpp:163 only defines USE_NEON_AES / USE_NEON_CRC32 when the compiler
    # is already targeting __ARM_FEATURE_CRYPTO / __ARM_FEATURE_CRC32. The
    # vendored makefile passes no -march (makefile:5-7), so stock Linux
    # aarch64 builds compile those paths out entirely.
    #
    # Only add the flag when the default target lacks them. On macOS arm64
    # Apple clang already defines both, and forcing -march=armv8-a there
    # would drop the ARMv8.2-8.5 baseline (LSE atomics, DOTPROD, RCPC,
    # PAUTH, BTI, SHA3/SHA512) for no gain.
    if has_macro __ARM_FEATURE_CRC32 && has_macro __ARM_FEATURE_CRYPTO &&
       [ "$FORCE_LADDER" -eq 0 ]; then
      echo "==> default target already has CRC32 + crypto; no -march needed"
      build_one native ""
    elif [ "$FORCE_LADDER" -eq 1 ] && has_macro __ARM_FEATURE_CRC32; then
      # Comparison pair: armv8-a drops crypto+crc (reproducing a stock Linux
      # aarch64 build) while native keeps whatever the default target offers.
      echo "==> forced ladder: armv8-a (no crypto/crc) vs default target"
      build_one armv8-a "-march=armv8-a"
      build_one native  ""
    else
      echo "==> default target lacks CRC32/crypto; adding +crc+crypto"
      build_one armv8-a           "-march=armv8-a"
      build_one armv8-a-crypto    "-march=armv8-a+crc+crypto"
    fi
    ;;

  *)
    echo "==> $ARCH: no ISA ladder defined; building default only"
    build_one native ""
    ;;
esac

# Leave the vendored tree pristine: the whole point of this approach is that
# `git status` shows no changes to upstream files or stray build output.
make -C "$ROOT" clean >/dev/null 2>&1 || true

echo
echo "Built variants in $OUT:"
ls -la "$OUT"/unrar.* 2>/dev/null | awk '{print "  " $NF "  " $5 " bytes"}'
