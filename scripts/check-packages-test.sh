#!/usr/bin/env bash
# Test of scripts/check-packages.sh (audit 0.0.10, B1): platform/main.roc passes; a copy with a local path for cbor fails
# and names the package; a copy with no packages block fails.
set -uo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail=0
check() { # name, expected exit, file
  local out code
  out=$(scripts/check-packages.sh "$3" 2>&1); code=$?
  if [ "$code" -eq "$2" ]; then echo "ok   $1"; else echo "FAIL $1: exit $code, expected $2: $out"; fail=1; fi
  printf '%s\n' "$out" > "$work/last.out"
}
check "platform/main.roc has only https:// URLs" 0 platform/main.roc
check "bench/platform/main.roc has only https:// URLs" 0 bench/platform/main.roc
sed 's#cbor: "https://[^"]*"#cbor: "/home/user/roc-cbor/src/main.roc"#' platform/main.roc > "$work/path.roc"
check "a local path for cbor fails" 1 "$work/path.roc"
grep -q 'package cbor is not an https:// URL: /home/user/roc-cbor/src/main.roc' "$work/last.out" || { echo "FAIL the error does not name cbor and the path"; fail=1; }
sed 's#http: "https://#http: "http://#' platform/main.roc > "$work/http.roc"
check "a plain http:// URL fails" 1 "$work/http.roc"
grep -v 'packages\|cbor:\|http:' platform/main.roc > "$work/none.roc"
check "no packages block fails" 1 "$work/none.roc"
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAIL"
exit "$fail"
