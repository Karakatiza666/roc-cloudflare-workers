#!/bin/sh
# Run the probes of README.md. Run from the submodule root: research/typed-do-ns/run.sh
# Each line gives the probe and the first line of its result. The wasm files go to .cache/typed-do-ns/.
set -u
ROC=$(bench/get-roc.sh)
export ROC_CACHE_DIR=$PWD/.cache/roc XDG_CACHE_HOME=$PWD/.cache
D=research/typed-do-ns
OUT=.cache/typed-do-ns
mkdir -p "$OUT"
first() { grep -E "errors? and|^── |^[A-Z_]+/" | head -1; }
# The models with no platform (probes/).
for f in a_phantom a2_phantom_class a5_unannotated_trap b_record; do
	printf '%-34s %s\n' "probes/$f (run)" "$(timeout 600 "$ROC" --no-cache "$D/probes/$f.roc" 2>&1 | head -1)"
done
for f in a_phantom_fail a3_free_iface_fail a4_class_mixed_fail b2_accessor b3_record_fail; do
	printf '%-34s %s\n' "probes/$f (check)" "$(timeout 600 "$ROC" check --no-cache "$D/probes/$f.roc" 2>&1 | first)"
done
# The platform copies (not in git).
python3 "$D/make_platform_a.py" > /dev/null
python3 "$D/make_platform_b.py" > /dev/null
build() { # name, file, extra flags
	printf '%-34s %s\n' "$1" "$(timeout 600 "$ROC" build $3 --target=wasm32 --no-cache --output="$OUT/$1.wasm" "$2" 2>&1 | first)"
}
for a in web ledger; do
	build "$a-base" "examples/auction/$a.roc" ""
	for v in a b c; do build "$a-$v" "$D/auction-$v/$a.roc" ""; done
done
# The wrong uses: a copy of each app with one change (sed), in fail-*/ (not in git).
fail() { # option, file, sed expression
	rm -rf "$D/fail-$1"; cp -r "$D/auction-$1" "$D/fail-$1"
	sed -i "$3" "$D/fail-$1/$2"
	app=$2; [ "$app" = LotRoom.roc ] && app=web.roc
	build "fail-$1/$2" "$D/fail-$1/$app" ""
}
fail a web.roc 's#call!(Gavel.snapshot, {})#call!(Gavel.settle_due, {})#'
fail a LotRoom.roc 's#rpc: \[Gavel.open.on(open!),#rpc: [Gavel.settle_due.on(|_s, {}| Ok({ settled: 0 })), Gavel.open.on(open!),#'
fail a ledger.roc 's#^lot_rooms : Object.Namespace(Gavel.Room)$##; s#\tcloseout = lot_rooms.named(id).call!(Gavel.close_out, {})?#\t_x = lot_rooms.named(id).call!(Gavel.settle_due, {})?\n\tcloseout = lot_rooms.named(id).call!(Gavel.close_out, {})?#'
fail b web.roc 's#call!(|r| r.snapshot, {})#call!(|r| r.settle_due, {})#'
fail c web.roc 's#Gavel.Room.at(lot_rooms, id).snapshot!()#Gavel.Room.at(lot_rooms, id).settle_due!()#'
for v in base a b; do
	for o in size speed; do build "small-$v-$o" "$D/small/$v.roc" "--opt=$o"; done
done
ls -l "$OUT" | awk 'NR > 1 { print $5, $9 }'
