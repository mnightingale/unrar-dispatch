#!/bin/sh
#
# Correctness parity across ISA variants.
#
# This is the gate that matters: a variant that decodes fastest but wrong is
# far worse than one that is merely slow. Every variant must produce
# byte-identical extractions and identical exit codes.
#
# Checks:
#   1. `unrar t` succeeds on every corpus archive, for every variant
#   2. extractions are byte-identical between variants, and match the
#      original source data
#   3. error exit codes agree (CRC failure, bad password, missing file)
#
# Usage: dispatch/verify-parity.sh [-b builddir] [-c corpusdir]

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/dispatch/build"
CORPUS="$ROOT/dispatch/corpus"

while [ $# -gt 0 ]; do
  case $1 in
    -b) BUILD=$2; shift 2 ;;
    -b*) BUILD=${1#-b}; shift ;;
    -c) CORPUS=$2; shift 2 ;;
    -c*) CORPUS=${1#-c}; shift ;;
    *) echo "$0: unknown option: $1" >&2; exit 2 ;;
  esac
done

VARIANTS=$(ls "$BUILD"/unrar.* 2>/dev/null | grep -v '\.buildlog$' || true)
[ -n "$VARIANTS" ] || { echo "no variants in $BUILD" >&2; exit 1; }
[ -d "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || {
  echo "$0: python3 is required (used to corrupt an archive for the CRC exit-code check)." >&2
  exit 1
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
note_fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

# Any *encrypted* archive shares the fixed benchmark password.
pw_for() {
  case $(basename "$1") in
    *encrypted*) echo "-pbenchpw" ;;
    *) echo "-p-" ;;
  esac
}

archives() {
  for a in "$CORPUS"/*.rar; do
    case $(basename "$a") in
      *.part01.rar|*.part1.rar) echo "$a" ;;
      *.part*.rar) ;;                       # continuation volumes
      *) echo "$a" ;;
    esac
  done
}

echo "=== 1. test-mode integrity ==="
for v in $VARIANTS; do
  name=$(basename "$v" | sed 's/^unrar\.//')
  for a in $(archives); do
    if "$v" t "$(pw_for "$a")" -y "$a" >/dev/null 2>&1; then :; else
      note_fail "$name: 'unrar t' failed on $(basename "$a") (exit $?)"
    fi
  done
  echo "  $name: all archives pass"
done

echo
echo "=== 2. extraction parity ==="
reference=""
for v in $VARIANTS; do
  name=$(basename "$v" | sed 's/^unrar\.//')
  dest="$WORK/$name"
  mkdir -p "$dest"
  for a in $(archives); do
    "$v" x -o+ "$(pw_for "$a")" -y "$a" "$dest/" >/dev/null 2>&1 \
      || note_fail "$name: extraction failed on $(basename "$a")"
  done

  if [ -z "$reference" ]; then
    reference=$dest
    refname=$name
    echo "  $name: reference extraction ($(find "$dest" -type f | wc -l | tr -d ' ') files)"
  elif diff -r "$reference" "$dest" >/dev/null 2>&1; then
    echo "  $name: byte-identical to $refname"
  else
    note_fail "$name: extraction differs from $refname"
    diff -r "$reference" "$dest" 2>&1 | head -5
  fi
done

echo
echo "=== 3. extraction matches original source data ==="
for f in text.txt exe.bin random.bin; do
  if [ -f "$CORPUS/src/$f" ] && [ -f "$reference/$f" ]; then
    if cmp -s "$CORPUS/src/$f" "$reference/$f"; then
      echo "  $f: matches original"
    else
      note_fail "$f: extracted content differs from original source"
    fi
  fi
done

echo
echo "=== 4. error exit codes ==="
# RAR_EXIT from errhnd.hpp: 3=RARX_CRC, 11=RARX_BADPWD, 10=RARX_NOFILES
corrupt="$WORK/corrupt.rar"
cp "$CORPUS/rar5-text-m5.rar" "$corrupt"
# Flip bytes well past the header, inside the compressed stream.
python3 - "$corrupt" <<'PY'
import sys
p = sys.argv[1]
with open(p, 'r+b') as f:
    f.seek(4096)
    b = f.read(256)
    f.seek(4096)
    f.write(bytes(x ^ 0xFF for x in b))
PY

for v in $VARIANTS; do
  name=$(basename "$v" | sed 's/^unrar\.//')

  "$v" t -p- -y "$corrupt" >/dev/null 2>&1 && rc=0 || rc=$?
  corrupt_rc=$rc

  "$v" t -pWRONGPASSWORD -y "$CORPUS/rar5-encrypted.rar" >/dev/null 2>&1 && rc=0 || rc=$?
  badpw_rc=$rc

  "$v" t -p- -y "$WORK/does-not-exist.rar" >/dev/null 2>&1 && rc=0 || rc=$?
  missing_rc=$rc

  echo "  $name: corrupt=$corrupt_rc badpassword=$badpw_rc missing=$missing_rc"

  if [ -z "${ref_codes:-}" ]; then
    ref_codes="$corrupt_rc $badpw_rc $missing_rc"
    ref_codes_name=$name
  elif [ "$ref_codes" != "$corrupt_rc $badpw_rc $missing_rc" ]; then
    note_fail "$name: exit codes differ from $ref_codes_name ($ref_codes)"
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "PASS: all variants agree."
else
  echo "FAIL: $FAILURES problem(s) found."
  exit 1
fi
