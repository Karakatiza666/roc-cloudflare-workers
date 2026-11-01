#!/usr/bin/env bash
# Fetch the third-party decoders of the probe into .cache/src (not committed). Pinned commits.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)/.cache/src; mkdir -p "$D"
get() { [ -d "$D/$1" ] || git clone -q "$2" "$D/$1"; git -C "$D/$1" checkout -q "$3"; }
get zstd https://github.com/facebook/zstd f8745da6ff1ad1e7bab384bd1f9d742439278e99          # v1.5.7
get zstd.zig https://github.com/muhammad-fiaz/zstd.zig aeec26c273fa59bede70421408a98716ddcdb90e # 0.0.5
get zaxified_zig-libs https://github.com/zaxified/zig-libs ccde0637ddd031b962d91c7cff6dd4a0f531e348 # the decoder of hostlib/zstd
