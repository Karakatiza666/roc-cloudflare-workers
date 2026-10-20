#!/bin/sh
# Make research/n5-rpc-errors/platform-g/: a copy of platform/ with option G1a (gen_g.py) in the modules that the
# auction example uses. Run from the submodule root. The copy is not in git (.gitignore).
# Also make platform-g0/: the control with the same wrappers and the flat errors (NEST_IDENTITY=1).
set -eu
D=research/n5-rpc-errors
rm -rf "$D/platform-g" "$D/platform-g0"
cp -r platform "$D/platform-g"
cp -r platform "$D/platform-g0"
python3 "$D/gen_g.py" "$D/platform-g" Object Kv D1 R2 Service
NEST_IDENTITY=1 python3 "$D/gen_g.py" "$D/platform-g0" Object Kv D1 R2 Service
# Rpc.Infra: the closed union of the infrastructure tags.
python3 - "$D/platform-g/Rpc.roc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "\t## The `err` of a method with no errors."
infra = """\t## Option G: the infrastructure errors of the platform, one closed union. Each function gives its own tags in
\t## `Infra(...)`; a handler error closes them as `Infra(Rpc.Infra)`.
\tInfra : [StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), D1Err(Io.Thrown), KvErr(Io.Thrown), R2Err(Io.Thrown), CacheErr(Io.Thrown), QueueErr(Io.Thrown), ObjectErr(Io.Thrown), ServiceErr(Io.Thrown), RpcErr(Io.Thrown), HttpErr(Io.Thrown), Network(Io.Thrown), SocketErr(Io.Thrown), BodyErr(Io.Thrown), CryptoErr(Io.Thrown), AiErr(Io.Thrown), VectorizeErr(Io.Thrown), WorkflowsErr(Io.Thrown), EmailErr(Io.Thrown), AnalyticsErr(Io.Thrown), AssetsErr(Io.Thrown), SecretsStoreErr(Io.Thrown), LimitErr(Io.Thrown), BadData(Str), InvalidJson(Str), MissingEnv(Str), TooLarge, TimedOut]

"""
assert anchor in s
s = s.replace(anchor, infra + anchor)
if "import Io\n" not in s: s = s.replace("import Request\n", "import Request\nimport Io\nimport Sql\n")
open(p, "w").write(s)
PY
