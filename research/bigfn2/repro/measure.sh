#!/usr/bin/env bash
# Text size of the native binary of each repro (nightly-2026-10-31-f7bef6b, x86-64 Linux, --opt=speed).
ROC=${ROC:-/home/george/dev/Karakatiza666/talon/cloudflare-workers/.cache/nightlies/nightly-2026-10-31-f7bef6b/roc}
cd "$(dirname "$0")"
for f in nosort u64 pair main sortby; do
  src=$f.roc; $ROC build --opt=speed --output=$f.bin $src >/dev/null 2>&1
  printf '%s\t%s bytes of text\n' "$f" "$(size $f.bin | tail -1 | awk '{print $1}')"
done
