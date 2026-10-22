#!/bin/sh
# Reproduce the numbers of research/g1a-size/README.md. Run from the submodule root: research/g1a-size/run.sh
# Needs: the roc nightly (bench/get-roc.sh), node, python3, and platform/targets/wasm32/host.wasm (zig build, not in git).
# Time: about 30 builds, 10 to 15 minutes. Output: a table on stdout (the copy is in results.txt).
# Method: each variant is a directory work/<name>/ with platform/ and app/ (the auction). It is made from a commit with
# `git archive`, so the checkout is not touched. All builds use `--opt=size`. A `--debug` build adds a name section only
# (the code section is the same), and the function tables come from it.
set -eu
D=research/g1a-size
BASE=5d4db48   # the first parent of the G1a merge d56d075
G1A=d56d075
mkdir -p $D/out $D/work

mk() { # name commit: platform and auction of that commit
	rm -rf "$D/work/$1"; mkdir -p "$D/work/$1/app"
	git archive "$2" platform | tar x -C "$D/work/$1"
	git archive "$2" examples/auction | tar x -C "$D/work/$1/app" --strip-components=2
	sed -i 's#\.\./\.\./platform/main.roc#../platform/main.roc#' "$D/work/$1"/app/*.roc
	cp -r platform/targets "$D/work/$1/platform/"
}
size() { # variant app: the wasm size in bytes
	"$D/build1.sh" "$D/work/$1/app/$2.roc" "$D/out/$1-$2.wasm"
}
row() { # variant: web and ledger sizes
	printf '%-22s %10s %10s\n' "$1" "$(size "$1" web)" "$(size "$1" ledger)"
}
noinsp() { # variant: the same with each Str.inspect(x) of the app replaced by "x"
	rm -rf "$D/work/$1-noinsp"; cp -r "$D/work/$1" "$D/work/$1-noinsp"
	sed -i 's/Str\.inspect([a-z]*)/"x"/' "$D/work/$1-noinsp"/app/web.roc "$D/work/$1-noinsp"/app/ledger.roc "$D/work/$1-noinsp"/app/LotRoom.roc
}

mk base $BASE; mk g1a $G1A
python3 $D/make_a.py
for k in 11 16 22 29; do python3 $D/sweep_tags.py $k; done
for m in str none; do python3 $D/sweep_tags.py 29 $m; done   # the 18 extra tags with a Str payload, with no payload
# P4: one payload union for each platform module (and the two app annotations that it needs)
rm -rf $D/work/p4; cp -r $D/work/g1a $D/work/p4
python3 $D/p4_module_unions.py $D/work/p4/platform Kv D1 Object R2 > /dev/null
python3 - <<'PY'
D = "research/g1a-size/work/p4/app/"
s = open(D + "Gavel.roc").read()
s = s.replace("Try({}, [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint)])])", "Try({}, [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge])])")
open(D + "Gavel.roc", "w").write(s)
s = open(D + "LotRoom.roc").read()
s = s.replace("[NotOpen, Infra([BadData(Str), StorageErr(Io.Thrown)])]", "[NotOpen, Infra([ObjectErr(Io.Thrown), RpcErr(Io.Thrown), BadData(Str), SqlErr(Io.Thrown), Constraint(Sql.Constraint), TooLarge, StorageErr(Io.Thrown)])]")
open(D + "LotRoom.roc", "w").write(s)
PY
noinsp base; noinsp g1a

echo "== wasm size in bytes, --opt=size"
printf '%-22s %10s %10s\n' variant web ledger
for v in base g1a a1 a2 sweep-11 sweep-16 sweep-22 sweep-29 sweep-29-str sweep-29-none p4 base-noinsp g1a-noinsp; do row $v; done

echo "== function tables (roc build --debug): base against g1a"
ROC=$(bench/get-roc.sh); export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
dbg() { # variant app
	timeout 900 "$ROC" build --opt=size --debug --target=wasm32 --no-cache --output="$D/out/$1-$2.dbg.wasm" "$D/work/$1/app/$2.roc" > /dev/null 2>&1 || true
	node $D/wasmfuncs.mjs "$D/out/$1-$2.dbg.wasm" > "$D/out/$1-$2.tsv"
}
for a in web ledger; do
	for v in base g1a sweep-11; do dbg $v $a; done
	echo "--- $a: base against g1a"; python3 $D/compare.py "$D/out/base-$a.tsv" "$D/out/g1a-$a.tsv"
	echo "--- $a: sweep-11 against g1a (the same app, 11 tags against 29)"; python3 $D/compare.py "$D/out/sweep-11-$a.tsv" "$D/out/g1a-$a.tsv"
done
