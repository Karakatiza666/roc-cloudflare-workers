app [main!] { lib: "../../../roc-cloudflare-workers-cli/lib/main.roc" }

## O4 of research/design-notes/test-helper.md 9: `Cfw.check` of roc-cfw 0.0.1 (the sibling checkout
## ../roc-cloudflare-workers-cli at tag 0.0.1) accepts the cfw.json of this branch, with the key `test`.
##   roc test research/test-helper/o4-cfw-check.roc
import lib.Cfw
import "../../js/cfw.json" as cfw : Str

main! = |_args| Ok({})

expect Cfw.check(cfw).is_ok()
