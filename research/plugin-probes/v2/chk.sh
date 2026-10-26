#!/bin/bash
# Type-check one or more apps with the pinned nightly. Usage: chk.sh file.roc ...
ROC=/home/george/dev/Karakatiza666/talon/cloudflare-workers/.cache/nightlies/nightly-2026-10-19-601b54c/roc
for f in "$@"; do echo "=== $f"; "$ROC" check --no-cache "$f" 2>&1 | head -${LINES_MAX:-60}; done
