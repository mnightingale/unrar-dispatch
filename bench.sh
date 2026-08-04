#!/usr/bin/env bash
#
# Benchmark the CRC32 folding change against the pre-folding baseline.
#
# The two builds differ only by the folding commit, which touches nothing but
# crc.cpp and crcfold.cpp - same compiler, same flags - so any difference is
# attributable to the CRC implementation.
#
# Reports real, user and sys separately. That matters here: CRC is already
# threaded above 32KB (hash.cpp), so part of the pre-folding throughput was
# being bought with extra cores. Wall-clock alone hides that; user time shows
# the CPU actually saved.
#
# Usage:
#   ./bench.sh [-n runs] [-s size_gb] [-a archive] [--no-build] [--test-only]

set -euo pipefail

BASELINE_REF=5ca2407c2d65b0824814ca5f3aaded792acb5e4d   # pre-folding
FOLD_REF=main
RUNS=3
SIZE_GB=1
ARCHIVE=random.rar
DO_BUILD=1
DO_EXTRACT=1

while [ $# -gt 0 ]; do
  case $1 in
    -n) RUNS=$2; shift 2 ;;
    -n*) RUNS=${1#-n}; shift ;;
    -s) SIZE_GB=$2; shift 2 ;;
    -s*) SIZE_GB=${1#-s}; shift ;;
    -a) ARCHIVE=$2; shift 2 ;;
    -a*) ARCHIVE=${1#-a}; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --test-only) DO_EXTRACT=0; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- build ----

if [ "$DO_BUILD" -eq 1 ]; then
  # Refuse to switch commits with modified tracked files - checkout would
  # either fail or silently carry changes into the "baseline" build.
  if ! git diff --quiet HEAD -- ':!bench.sh'; then
    echo "Working tree has modified tracked files; commit or stash first," >&2
    echo "or re-run with --no-build to use the existing unrar-* binaries." >&2
    exit 1
  fi

  # Always come back to where we started, even on failure or Ctrl-C.
  ORIG_REF=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
  restore() { git checkout --quiet "$ORIG_REF" 2>/dev/null || true; }
  trap restore EXIT INT TERM

  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 8)
  BUILDLOG=$(mktemp)

  build_variant() { # ref outname label
    echo "==> building $3"
    git checkout --quiet "$1"
    make -s clean >/dev/null 2>&1 || true
    if ! make -s -j"$JOBS" >"$BUILDLOG" 2>&1; then
      echo "build failed:" >&2
      tail -20 "$BUILDLOG" >&2
      exit 1
    fi
    mv -f unrar "$2"
  }

  build_variant "$BASELINE_REF" unrar-nofold "baseline (no folding) from ${BASELINE_REF:0:8}"
  build_variant "$FOLD_REF"     unrar-fold   "folding from $FOLD_REF"
  rm -f "$BUILDLOG"

  restore
  trap - EXIT INT TERM
fi

for B in unrar-nofold unrar-fold; do
  [ -x "./$B" ] || { echo "missing ./$B - run without --no-build" >&2; exit 1; }
done

# Cheap insurance: confirm the binaries really differ in the intended way.
# A benchmark comparing two accidentally-identical, or accidentally
# differently-configured, builds is worse than no benchmark.
#
# Only meaningful on x86: crcfold.cpp is compiled out everywhere else, so both
# builds are legitimately identical on ARM and the counts are both zero.
case $(uname -m) in
  x86_64|amd64|i?86)
    if command -v objdump >/dev/null 2>&1; then
      N_BASE=$(objdump -d ./unrar-nofold 2>/dev/null | grep -ci pclmul || true)
      N_FOLD=$(objdump -d ./unrar-fold   2>/dev/null | grep -ci pclmul || true)
      echo "==> pclmulqdq instructions: nofold=$N_BASE fold=$N_FOLD"
      if [ "$N_BASE" != "0" ] || [ "$N_FOLD" = "0" ]; then
        echo "    WARNING: expected nofold=0 and fold>0 - are these the builds you think?" >&2
      fi
    fi
    ;;
  *)
    echo "==> $(uname -m): folding is x86-only, so both builds are identical here"
    ;;
esac

# --------------------------------------------------------------- corpus ----

if [ ! -f "$ARCHIVE" ]; then
  echo "==> creating ${SIZE_GB}GiB incompressible archive $ARCHIVE"
  # Stored, incompressible data: no LZ work at all, so the run is dominated
  # by CRC32 - the cleanest possible measurement of this change.
  dd if=/dev/urandom of=random.bin bs=1M count=$((SIZE_GB * 1024)) status=none
  rar a -m0 -ep -inul "$ARCHIVE" random.bin
  rm -f random.bin
fi

# Uncompressed byte count, for throughput. Taken from the archive itself so it
# stays correct if $ARCHIVE was made elsewhere or at a different size.
BYTES=$(./unrar-fold lt -p- -y "$ARCHIVE" 2>/dev/null |
        awk '/^[[:space:]]*Size:/ {s+=$2} END {print s+0}')
if [ "${BYTES:-0}" -le 0 ]; then
  echo "could not determine uncompressed size of $ARCHIVE" >&2
  exit 1
fi

# ---------------------------------------------------------------- timing ---

RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

# bash's time builtin rather than /usr/bin/time: always present, and gives the
# same three numbers.
TIMEFORMAT='%3R %3U %3S'

run_one() { # op bin -> appends "op variant real user sys"
  local op=$1 bin=$2 variant=$3 t
  [ "$op" = "e" ] && rm -f random.bin
  t=$( { time "./$bin" "$op" -p- -y "$ARCHIVE" >/dev/null 2>&1; } 2>&1 )
  echo "$op $variant $t" >>"$RESULTS"
}

echo
echo "==> $((BYTES / 1024 / 1024 / 1024))GiB of data, $RUNS runs per variant"

OPS="t"
[ "$DO_EXTRACT" -eq 1 ] && OPS="t e"

for op in $OPS; do
  case $op in
    t) echo "==> test (unrar t): decode + CRC, no disk writes" ;;
    e) echo "==> extract (unrar e): adds ${SIZE_GB}GiB of writes, so disk-bound" ;;
  esac
  for i in $(seq 1 "$RUNS"); do
    # Alternate order so any thermal drift or cache warming over the run
    # does not systematically favour whichever variant goes first.
    if [ $((i % 2)) -eq 1 ]; then
      run_one "$op" unrar-nofold nofold
      run_one "$op" unrar-fold   fold
    else
      run_one "$op" unrar-fold   fold
      run_one "$op" unrar-nofold nofold
    fi
    printf '    run %d/%d\r' "$i" "$RUNS"
  done
  printf '\r                    \r'
done

rm -f random.bin

# ----------------------------------------------------------------- table ---

print_table() {
  local op=$1 title=$2
  echo
  echo "=== $title ==="
  awk -v bytes="$BYTES" -v op="$op" '
    # Run-to-run spread as (median - min), which unlike (max - min) is not
    # destroyed by a single scheduler hiccup. Printed so a small change can
    # be recognised as noise rather than read as a result.
    function spread(v,   i,j,cnt,tmp,t,lo,med) {
      cnt=n[v]
      if (cnt<2) return 0
      for (i=1;i<=cnt;i++) tmp[i]=vals[v,i]
      for (i=2;i<=cnt;i++) { t=tmp[i]; j=i-1
        while (j>0 && tmp[j]>t) { tmp[j+1]=tmp[j]; j-- }
        tmp[j+1]=t }
      # int(cnt/2)+1 rather than the exact median index: with only two runs
      # the median IS the minimum, which would report a spread of 0% and
      # wrongly imply the measurement is perfectly stable.
      lo=tmp[1]; med=tmp[int(cnt/2)+1]
      return (lo>0 ? (med-lo)/lo*100 : 0)
    }
    $1==op {
      v=$2; r=$3+0; u=$4+0; s=$5+0
      # Report the fastest run, and the user/sys from that same run rather
      # than independent minima, so the three numbers describe one execution.
      if (!(v in br) || r < br[v]) { br[v]=r; bu[v]=u; bs[v]=s }
      n[v]++; vals[v,n[v]]=r
    }
    END {
      gb=bytes/1073741824
      printf "%-10s %10s %10s %10s %10s\n", "variant", "real", "user", "sys", "GB/s"
      for (i=1; i<=2; i++) {
        v=(i==1 ? "nofold" : "fold")
        if (!(v in br)) continue
        printf "%-10s %9.3fs %9.3fs %9.3fs %10.2f\n", v, br[v], bu[v], bs[v], gb/br[v]
      }
      if (("nofold" in br) && ("fold" in br)) {
        printf "%-10s %9s%% %9s%% %9s%% %9.2fx\n", "change", \
               sprintf("%+.1f", (br["fold"]-br["nofold"])/br["nofold"]*100), \
               sprintf("%+.1f", (bu["fold"]-bu["nofold"])/bu["nofold"]*100), \
               sprintf("%+.1f", (bs["fold"]-bs["nofold"])/bs["nofold"]*100), \
               br["nofold"]/br["fold"]

        sn=spread("nofold"); sf=spread("fold")
        worst=(sn>sf ? sn : sf)
        delta=(br["fold"]-br["nofold"])/br["nofold"]*100
        printf "\nrun-to-run spread: nofold %.1f%%, fold %.1f%%", sn, sf
        if ((delta<0 ? -delta : delta) <= worst)
          printf "  <- change is within noise, not a result\n"
        else
          printf "\n"
      }
    }
  ' "$RESULTS"
}

print_table t "test (unrar t)"
[ "$DO_EXTRACT" -eq 1 ] && print_table e "extract (unrar e)"

cat <<'EOF'

real  = wall clock; user = CPU in user mode; sys = CPU in the kernel.
change is fold vs nofold, so negative is an improvement (less time, less CPU).
GB/s is uncompressed bytes / real, with 1 GB = 2^30 bytes.
Each row is the fastest of the runs, with user and sys taken from that run.

Trust the 'test' table. 'extract' writes the whole payload to disk, so it is
dominated by storage bandwidth and its sys time swamps any CRC difference.
EOF
