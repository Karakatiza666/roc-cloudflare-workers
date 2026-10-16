#!/usr/bin/env bash
# Make the test data of research/native with the zstd CLI, b3sum-free (see README). Run from anywhere.
# Small files (committed): pkg.tar, the .zst variants of it, the zeros archives.
# Big files (data/big-*, not committed): the speed test archives, from the Zig lib dir (ZIGLIB).
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$D/../.." && pwd)
ZIGLIB=${ZIGLIB:-/home/george/.local/zig/zig-x86_64-linux-0.17.0/lib}
mkdir -p "$D/data"
cd "$D/data"
if [ "${SMALL:-1}" = 1 ]; then
  # A package: the platform files of this repo, as a deterministic tar.
  (cd "$R" && tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$D/data/pkg.tar" \
      LICENSE README.md MODULES.md platform/main.roc platform/Js.roc platform/Wait.roc research/api-probe/*.roc)
  zstd -q -f -19 pkg.tar -o pkg.tar.zst                    # file input: content size in the header, checksum
  zstd -q -f -19 < pkg.tar > pkg-pipe.tar.zst              # pipe: no content size, window from the level
  zstd -q -f -19 --no-check < pkg.tar > pkg-nocheck.tar.zst
  zstd -q -f -19 --zstd=wlog=24 < pkg.tar > pkg-w24.tar.zst # declares a 16 MB window
  # 4 MB of zeros: a few hundred bytes packed.
  head -c 4194304 /dev/zero > zeros.bin
  zstd -q -f -19 zeros.bin -o zeros.zst                    # content size declared
  zstd -q -f -19 < zeros.bin > zeros-pipe.zst              # no content size
  rm zeros.bin
  # Two frames with a skippable frame between them.
  { cat pkg.tar.zst; printf '\x50\x2a\x4d\x18\x04\x00\x00\x00abcd'; cat pkg-pipe.tar.zst; } > multi.zst
  cat pkg.tar pkg.tar > multi.tar
  # What the CLI says for each (the reference).
  for f in pkg.tar.zst pkg-pipe.tar.zst pkg-nocheck.tar.zst pkg-w24.tar.zst; do zstd -d -c -q "$f" | cmp - pkg.tar; done
  zstd -d -c -q multi.zst | cmp - multi.tar
  zstd -d -c -q zeros.zst | sha256sum | cut -d' ' -f1 > zeros.sha256
  # A real package made by `roc bundle` (roc-parser): window 2 MiB, no content size, no checksum. It is copied
  # (data/roc-parser.tar.zst, committed), not made here. Its reference output is the CLI's.
  [ -f roc-parser.tar.zst ] && zstd -d -c -q roc-parser.tar.zst | sha256sum | cut -d' ' -f1 > roc-parser.sha256
  # Hash inputs: whole tars, an odd size, and the empty file. Reference digests: sha256sum, and the
  # official Python package `blake3` (PyPI, 1.0.11: B3PY=<python with blake3>). b3sum is not installed.
  head -c 200001 multi.tar > odd.bin
  : > empty.bin
  B3PY=${B3PY:-python3}
  : > hashes.txt
  for f in pkg.tar multi.tar odd.bin empty.bin; do
    b3=$("$B3PY" -I -c 'import sys,blake3;print(blake3.blake3(open(sys.argv[1],"rb").read()).hexdigest())' "$f")
    echo "$f $b3 $(sha256sum "$f" | cut -d' ' -f1)" >> hashes.txt
  done
fi
if [ "${BIG:-1}" = 1 ]; then
  # Speed: a 1 MB and a 10 MB .tar.zst (level 19). Input: the start of a binary (a platform archive has binaries:
  # basic-cli is 21 MB packed, 70 MB unpacked, ratio about 3 to 4). BIGSRC: any big binary file.
  BIGSRC=${BIGSRC:-$(command -v node)}
  T=$(mktemp -d)
  for spec in "1m 3700000" "10m 33500000"; do
    set -- $spec
    head -c "$2" "$BIGSRC" > "$T/payload.bin"
    tar --mtime=@0 --owner=0 --group=0 --numeric-owner -cf "$T/big.tar" -C "$T" payload.bin
    zstd -q -f -19 -T0 "$T/big.tar" -o "big-$1.tar.zst"
    zstd -q -f -19 < "$T/big.tar" > "big-$1-pipe.tar.zst"   # no content size in the header: the decode cannot size the buffer
    zstd -d -c -q "big-$1.tar.zst" | sha256sum | cut -d' ' -f1 > "big-$1.sha256"
    ls -l "big-$1.tar.zst"
  done
  rm -rf "$T"
fi
