# Wasm size of N5 option G1a

Question: why does G1a make the auction wasm bigger (web +8.9%, ledger +11.3% with `--opt=size`), and can we make it smaller? Research only: no file of `platform/`, `bench/`, `conformance/` or `examples/` is changed.

```sh
research/g1a-size/run.sh   # about 10 minutes, output in results.txt
```

## Result in short

| Finding | Evidence |
| --- | --- |
| The nesting `Infra([own tags])` is not the cause. The cause is the closed union `Rpc.Infra` of 29 tags, which the app uses in `RoomErr` and `SettleErr` (`Gavel.roc`) and in `error_response!` (`web.roc`) | Same app with a closed union of the 11 tags that it needs: web +0.4%, ledger +2.6% (g1a: +8.9%, +11.3%) |
| The cost is linear in the number of tags of that union: 3.5 KB (ledger) to 5.8 KB (web) for each tag | Sweep of 11, 16, 22, 29 tags |
| `Str.inspect` of the error is not the cause | The same builds with each `Str.inspect` of the app removed: growth is +9.4% and +11.8% (more, not less) |
| One payload union for each platform module (P4) does not help | web +9.6%, ledger +11.3% (g1a: +8.9%, +11.3%) |
| Shared helper functions for `Err(Infra(...))` (idea b) are not worth a prototype | All functions with an equal code hash have the same size. The rest after the fix is at most 0.4% (web) and 2.6% (ledger) |

Recommendation: keep G1a. Tell the apps to close the `err` of a method with an app alias of the tags that they use (`Infra(Gavel.Faults)`), not with `Infra(Rpc.Infra)`. See section 6.

## 1. Method

| Item | Value |
| --- | --- |
| Base | `5d4db48` (first parent of the merge `d56d075`). Worktree `.claude/worktrees/size-base` was used for the first look and is removed |
| G1a | `d56d075` |
| Build | `roc build --target=wasm32 --no-cache --opt=size` from the repo root, nightly 2026-10-19 (`bench/get-roc.sh`) |
| Variants | `work/<name>/{platform,app}`: a copy of the platform and of `examples/auction`, made by `git archive` and patched by the scripts below. `work/` and `out/` are not in git |
| Sizes | The wasm file size in bytes. web of G1a is 1,343,972 here (README of n5-rpc-errors: 1,344,258, a difference of 286 bytes, cause not found). base web, base ledger and G1a ledger are the same as there |
| Function sizes | `roc build --debug` adds a name section (14 KB) and makes the code section about 0.3% bigger (ledger g1a: 787,940 against 785,755 bytes). Function sizes are from the debug build, so they are close, not exact. `wasmfuncs.mjs` reads the code section and the name section (no wasm tool is installed). It also counts the small-string constants of the tag names and the calls to list append and to `str_escape_and_quote`, to tell a CBOR writer and a `Str.inspect` of a union |
| Limit | Roc names a function by a hash (`roc__p<hash>.fast`), not by its source name. LLVM inlines most code into a few very large functions. A name table by source function is not possible. The controlled variants below are the reliable evidence. The function tables only show where the bytes are |

| Script | Use |
| --- | --- |
| `run.sh` | Makes all variants, builds them, prints the tables |
| `build1.sh` | One build, prints the size |
| `make_a.py` | Variants `a1`, `a2` |
| `sweep_tags.py` | Variants `sweep-K`: app alias `Gavel.Faults` of K tags |
| `p4_module_unions.py` | Prototype P4 |
| `wasmfuncs.mjs`, `compare.py` | Function tables of two builds |

## 2. Sizes of all variants (`--opt=size`, bytes)

| Variant | What | web | vs base | ledger | vs base |
| --- | --- | --- | --- | --- | --- |
| base | `5d4db48` | 1,233,953 | | 723,009 | |
| g1a | `d56d075` | 1,343,972 | +8.9% | 804,719 | +11.3% |
| a1 | App: `RoomErr` and `SettleErr` list 5 tags each. `error_response!` keeps `Rpc.Infra` | 1,268,171 | +2.8% | 730,976 | +1.1% |
| a2 | As a1, and `error_response!` lists the 9 tags that web gives | 1,253,378 | +1.6% | 730,976 | +1.1% |
| sweep-11 | App alias `Gavel.Faults` of 11 tags, used in `RoomErr`, `SettleErr`, `error_response!` | 1,239,206 | +0.4% | 741,751 | +2.6% |
| sweep-16 | The same, 16 tags | 1,284,207 | +4.1% | 763,374 | +5.6% |
| sweep-22 | The same, 22 tags | 1,339,340 | +8.5% | 790,463 | +9.3% |
| sweep-29 | The same, 29 tags (equal to `Rpc.Infra`) | 1,343,972 | +8.9% | 804,719 | +11.3% |
| sweep-29-str | 11 tags + 18 extra tags with a `Str` payload (nobody makes them) | 1,305,709 | +5.8% | 795,246 | +10.0% |
| sweep-29-none | 11 tags + 18 extra tags with no payload | 1,295,032 | +4.9% | 773,460 | +7.0% |
| p4 | One payload union for each of Kv, D1, Object, R2 | 1,351,799 | +9.6% | 804,872 | +11.3% |
| base-noinsp | base, each `Str.inspect(x)` of the app is `"x"` | 1,217,880 | | 710,172 | |
| g1a-noinsp | g1a, the same | 1,332,265 | +9.4% | 793,940 | +11.8% |

Cost of one tag of the closed union (sweep, 11 to 29 tags, 18 tags):

| Tag | web | ledger |
| --- | --- | --- |
| Any tag with `Io.Thrown` (as `Rpc.Infra`) | 5.8 KB | 3.5 KB |
| Tag with no payload | 3.1 KB | 1.8 KB |
| Tag with a `Str` payload | 3.7 KB | 3.0 KB |
| The `Io.Thrown` record, on top of a tag with no payload | 2.7 KB | 1.7 KB |

## 3. Where the bytes go (step 1)

Total growth of G1a and its parts, from the variants:

| Part | web | ledger |
| --- | --- | --- |
| Growth of G1a | +110,019 | +81,710 |
| Removed when the 29-tag union is a 11-tag union (sweep-11 against g1a) | 104,766 (95%) | 62,968 (77%) |
| What stays (sweep-11 against base): the nesting, `Rpc.forward`, other code | +5,253 | +18,742 |
| Part of it from `Str.inspect` of the app (g1a-noinsp against base-noinsp, growth is bigger without it) | none | none |

Function table of `compare.py` (g1a against base, from `results.txt`). Functions with an equal hash have equal size (growth at most 159 bytes): the growth is only in functions whose code changed.

| Function (by its code) | web base | web g1a | ledger base | ledger g1a | Cause |
| --- | --- | --- | --- | --- | --- |
| CBOR writer of the union (25 tag names, list appends) | not found | 28,356 | not found | 37,712 | Derived writer of a closed union of 29 tags. One function for each union, shared by all methods (ledger: 7 call sites). About 1.0 KB to 1.3 KB for each tag |
| `Str.inspect` of the union (23 tag names, `escape_and_quote`) | not found | 20,260 | not found | 20,260 | Derived inspect of the union. About 0.7 KB for each tag. The same function in both apps |
| Largest rank-paired mega functions (unmatched hash) | 42,008 to 79,457 (+37,449); 39,632 to 67,078 (+27,446); 30,443 to 39,948 (+9,505) | | 126,217 to 152,695 (+26,478); 13,500 to 29,832 (+16,332) | | Code that has the CBOR reader and the widening of the union inlined. The function has no name by source, so it is not split further |

In base the unions have 8 and 5 tags, so LLVM inlines their codecs into the large functions, and no function of that kind exists. The pairing of unmatched functions is by size rank and is a heuristic.

The cause in one line: a closed union at the Rpc boundary gets derived code for each tag (writer, reader, inspect), and `Rpc.Infra` has 29 tags where the auction needs 11. G1a changes the app type from 8 and 5 tags to 29 tags, so it adds the code of about 21 and 24 tags.

Check that it is not the nesting itself:

| Test | Result |
| --- | --- |
| Tags of the closed union that nobody makes (sweep-29-none) still cost | 1.8 KB to 3.1 KB each, so the cost is in the type, not in the code that makes errors |
| P4: 4 modules get one payload union each (fewer distinct unions inside the platform) | No gain (+0.6% web, +0.02% ledger against g1a) |
| Same-hash functions | Equal size, so the wrappers and `map_err` closures of the platform add nothing that is seen |

## 4. Prototypes (step 2)

| Id | Change | web | ledger | Type precision | App code |
| --- | --- | --- | --- | --- | --- |
| R1 (sweep-11) | The app declares `Gavel.Faults : [11 tags]` once. `RoomErr`, `SettleErr` and `error_response!` use `Infra(Gavel.Faults)` in place of `Infra(Rpc.Infra)`. No platform change | 1,239,206 (+0.4%) | 741,751 (+2.6%) | Better: the set is closed to the tags that the app can get. A new tag from a platform call is a compile error until the app lists it | 1 alias of 11 tags, 3 words changed |
| R1b (a2) | Each type lists its own tags: 5 for `RoomErr`, 5 for `SettleErr`, 9 for `error_response!` | 1,253,378 (+1.6%) | 730,976 (+1.1%) | Best: each type has only its own tags | 3 lists, 19 tags, and the lists differ, so a hop needs a widening. Not simpler than R1 for web (+14 KB) |
| P4 | One closed payload union for each platform module (`KvInfra`, `D1Infra`, `ObjectInfra`, `R2Infra`) in place of one union for each function | 1,351,799 (+9.6%) | 804,872 (+11.3%) | Worse: `Kv.delete!` has `BadData` and `TooLarge` that it never gives | 2 annotations of the app needed the wider tags (`create_tables!`, `load_state!`) |

P4 shows that the number of distinct payload unions in the platform is not the cost. Idea (b), shared helpers for `Err(Infra(KvErr(t)))`, is not prototyped:

| Reason | Detail |
| --- | --- |
| No size left to gain | After R1, the rest against base is 0.4% (web) and 2.6% (ledger). The G0 control of `research/n5-rpc-errors/README.md` showed that code layout moves size by 7% to 8% |
| The type does not allow it | A helper must return a payload with a row (`Infra([KvErr(Io.Thrown), ..a])`). A row inside the payload does not compile (Q10 of the same README) |

## 5. Costs of R1

| Cost | Detail |
| --- | --- |
| The app lists the tags again | One alias, once. The N5 problem was the list in each Rpc method and in each match. It stays solved: methods use `Infra(Gavel.Faults)`, callers match `Infra(..)` or `Remote(Infra(..))` |
| `Rpc.Infra` is not removed | It stays the safe default (all platform tags, no compile error). It is the more costly default |
| The callee and the caller must share the alias | They do in the auction (`Gavel.roc` is in both Workers). The wire form of a tag is its name and payload, so it is the same for a tag that is in both unions. A JS peer test was not run |
| Check done | The alias was built for web and ledger only (size study). The conformance run and the behavior tests were not run on these variants, because the code is the same and only the type set changes |

## 6. Recommendation

| Step | Action |
| --- | --- |
| 1 | Keep G1a as merged. The nesting costs almost nothing (+0.4% web, +2.6% ledger after the fix). Do not do P4 or idea (b) |
| 2 | In `MODULES.md` (the N5 and Rpc sections) say: `Rpc.Infra` has 29 tags and costs 3 KB to 6 KB of wasm for each tag in each app that uses it as a closed `err` (writer, reader and inspect are derived for each tag). An app that cares about size declares `Faults : [the tags that it uses]` and writes `Infra(Faults)` |
| 3 | In the auction example (a later step, not done here) use `Gavel.Faults` in `RoomErr`, `SettleErr` and `error_response!`. Expected: web 1.24 MB (+0.4%), ledger 0.74 MB (+2.6%) |
| 4 | Open question for the human: should `Rpc.Infra` stay at 29 tags, or should the platform give smaller named sets (for example `Rpc.Infra` of storage, SQL and calls only)? The sweep shows the price of each tag. A smaller default is a design decision, not a size fix |

Limits of the study: two apps, one compiler nightly, `--opt=size` only. The size of the small residual (ledger +2.6%) is inside the layout noise of the G0 control.
