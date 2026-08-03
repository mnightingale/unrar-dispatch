#!/bin/sh
#
# Generate a benchmark corpus that separates the decompression paths, since
# they have different bottlenecks and a win in one is easily hidden by a wash
# in another. Requires the proprietary `rar` CLI (unrar cannot create).
#
# Usage: dispatch/make-corpus.sh [-o corpusdir] [-s size_mb] [-f filecount]
#
#   -s  size in MB of each source file (default 256). Larger inputs raise the
#       signal-to-noise ratio: at 64MB a 2% ISA effect is buried in run-to-run
#       variance, at 256-512MB it is resolvable.
#   -f  number of small files for the per-file-overhead archives (default 2000)
#
# Disk use is roughly 4x SIZE_MB (three source files, plus archives, plus the
# extraction tree that verify-parity.sh creates).

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="$ROOT/dispatch/corpus"
SIZE_MB=256
NFILES=2000
RAR=${RAR:-rar}

while [ $# -gt 0 ]; do
  case $1 in
    -o) OUT=$2; shift 2 ;;
    -o*) OUT=${1#-o}; shift ;;
    -s) SIZE_MB=$2; shift 2 ;;
    -s*) SIZE_MB=${1#-s}; shift ;;
    -f) NFILES=$2; shift 2 ;;
    -f*) NFILES=${1#-f}; shift ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v "$RAR" >/dev/null 2>&1 || {
  echo "$0: '$RAR' not found. The corpus needs the proprietary rar CLI to build archives." >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || {
  echo "$0: python3 is required to generate large source files at a usable speed." >&2
  exit 1
}

# Archives are built after cd'ing into the source directory, so a relative
# output path would resolve against the wrong directory and rar would fail
# with RARX_CREATE (9). Canonicalise before doing anything else.
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd)

SRC="$OUT/src"
rm -rf "$OUT"
mkdir -p "$SRC"

echo "==> generating source data (${SIZE_MB}MB each)"

# Generation is done in python3 rather than awk/shell loops: at 256-512MB the
# per-line awk loop and the per-file `wc -c` in the old exe loop dominated
# total runtime. Everything is seeded so corpora are reproducible.
python3 - "$SRC" "$SIZE_MB" "$NFILES" <<'PY'
import os, random, sys

src, size_mb, nfiles = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
total = size_mb * 1024 * 1024
CHUNK = 8 << 20

# 1. Text-like: compressible with plenty of medium-length repeated matches,
#    exercising CopyString's 8-byte fast path (unpackinline.cpp:78-92).
#    Built from a bounded vocabulary so matches are frequent but the stream
#    is not so self-similar that it degenerates into one long match.
rng = random.Random(1)
words = ("the quick brown fox jumps over lazy dog while parsing archive "
         "headers and decoding huffman tables").split()
with open(os.path.join(src, 'text.txt'), 'wb') as f:
    written = 0
    while written < total:
        buf = []
        n = 0
        while n < CHUNK:
            line = ' '.join(rng.choice(words) for _ in range(9)) + '\n'
            buf.append(line)
            n += len(line)
        b = ''.join(buf).encode()[:total - written]
        f.write(b)
        written += len(b)

# 2. Executable-like: real machine code, exercising the RAR5 E8/E9 x86
#    call-target filter (unpack50.cpp:436). Distinct binaries are used first;
#    once exhausted the pool repeats, which inflates compressibility but keeps
#    the input identical across variants, so relative comparison stays valid.
pool, seen = [], 0
for d in ('/bin', '/usr/bin', '/usr/lib', '/usr/libexec',
          '/lib/x86_64-linux-gnu', '/usr/lib/x86_64-linux-gnu'):
    if seen >= total:
        break
    try:
        entries = sorted(os.listdir(d))
    except OSError:
        continue
    for name in entries:
        p = os.path.join(d, name)
        try:
            if not os.path.isfile(p) or os.path.islink(p):
                continue
            with open(p, 'rb') as fh:
                data = fh.read()
        except OSError:
            continue
        if data:
            pool.append(data)
            seen += len(data)
            if seen >= total:
                break

if not pool:
    pool = [os.urandom(1 << 20)]

with open(os.path.join(src, 'exe.bin'), 'wb') as f:
    written = 0
    i = 0
    while written < total:
        b = pool[i % len(pool)][:total - written]
        f.write(b)
        written += len(b)
        i += 1
print("    exe.bin: %d distinct MB of binaries, %s"
      % (seen >> 20, "no repetition" if seen >= total
         else "pool repeated %.1fx" % (total / seen)))

# 3. Incompressible: forces store mode, isolating CRC32 throughput
#    (crc.cpp:111 slicing-by-16 vs the NEON crc32x path at crc.cpp:83).
with open(os.path.join(src, 'random.bin'), 'wb') as f:
    written = 0
    while written < total:
        n = min(CHUNK, total - written)
        f.write(os.urandom(n))
        written += n

# 4. Many small files: per-file overhead rather than decode throughput.
many = os.path.join(src, 'many')
os.makedirs(many, exist_ok=True)
for i in range(nfiles):
    with open(os.path.join(many, 'f%d.dat' % i), 'wb') as f:
        f.write(os.urandom(4096))
PY

echo "==> building archives"
cd "$SRC"

# rar syntax is: rar a [switches] <archive> <files...>
# The archive name must precede the file list, hence the explicit split.
mk() {
  name=$1; files=$2; shift 2
  rm -f "$OUT/$name"
  # -inul quiet, -ep1 strip base dir, -y assume yes
  "$RAR" a -inul -ep1 -y "$@" "$OUT/$name" $files >/dev/null
  printf '  %-28s %s\n' "$name" "$(ls -lh "$OUT/$name" | awk '{print $5}')"
}

# RAR5 (-ma5) is the default for modern rar; -ma4 selects the RAR3 format.
mk rar5-text-m5.rar   text.txt   -ma5 -m5
mk rar5-exe-m5.rar    exe.bin    -ma5 -m5
mk rar5-store-m0.rar  random.bin -ma5 -m0
mk rar5-many-m5.rar   many       -ma5 -m5 -r
mk rar5-solid-m5.rar  many       -ma5 -m5 -r -s
# RAR3 -m5 on text selects PPMd automatically, exercising model.cpp /
# suballoc.cpp and the divide-bound range coder at coder.cpp:32.
#
# RAR 7.x removed the ability to *create* RAR4-format archives (it still
# extracts them), so -ma4 is only available on older rar builds. Probe rather
# than assume, and carry on without the RAR3 arm if it is unavailable.
if "$RAR" a -inul -y -ma4 "$OUT/.ma4probe.rar" "$SRC/many/f0.dat" >/dev/null 2>&1; then
  rm -f "$OUT/.ma4probe.rar"
  mk rar3-text-m5.rar   text.txt   -ma4 -m5
  mk rar3-exe-m5.rar    exe.bin    -ma4 -m5
else
  rm -f "$OUT/.ma4probe.rar"
  echo "  (skipping RAR3 archives: this rar cannot create -ma4 format)"
  echo "  (drop pre-made RAR3 archives into $OUT to benchmark the PPMd path)"
fi

# Encrypted: AES + blake2sp on every block. Password is fixed and public;
# this is throwaway benchmark data, not a secret.
# Encrypted, compressed: AES + blake2sp + full LZ decode.
mk rar5-encrypted.rar    text.txt   -ma5 -m5 -hpbenchpw

# Encrypted, stored, incompressible input: AES + CRC32 with *no* LZ decoding
# at all. Paired with rar5-store-m0 (same data, no encryption) this isolates
# the crypto cost from everything else - the cleanest measure of the
# rijndael.cpp path there is.
mk rar5-encrypted-m0.rar random.bin -ma5 -m0 -hpbenchpw

# Multi-volume, for the correctness parity check rather than timing.
#
# Volume size is derived from the already-built compressed size, not fixed:
# a hardcoded size larger than the compressed output silently produces a
# single volume, quietly dropping multi-volume from the parity check.
rm -f "$OUT/rar5-vol".part*.rar
comp=$(wc -c < "$OUT/rar5-exe-m5.rar" | tr -d ' ')
vol=$((comp / 4))
[ "$vol" -lt 102400 ] && vol=102400
"$RAR" a -inul -ep1 -y -ma5 -m5 -v${vol}b "$OUT/rar5-vol.rar" exe.bin >/dev/null
nvol=$(ls "$OUT"/rar5-vol.part*.rar 2>/dev/null | wc -l | tr -d ' ')
printf '  %-28s %s volumes\n' "rar5-vol.part*.rar" "$nvol"
[ "$nvol" -lt 2 ] && echo "  WARNING: multi-volume set did not split; parity check will not cover volumes" >&2

echo
echo "==> corpus ready in $OUT"
echo "    source data kept in $SRC for extraction diffing ($(du -sh "$SRC" | cut -f1))"
