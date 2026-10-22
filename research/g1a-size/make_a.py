#!/usr/bin/env python3
"""Make work/a1 and work/a2 from work/g1a (app code only, no platform change).
a1: RoomErr and SettleErr list the 5 tags that their handlers give, in place of Infra(Rpc.Infra) (29 tags).
a2: as a1, and error_response! of web.roc lists the 9 tags that web.roc gives."""
import shutil
D = "research/g1a-size/work"
for v in ("a1", "a2"):
    shutil.rmtree(f"{D}/{v}", ignore_errors=True); shutil.copytree(f"{D}/g1a", f"{D}/{v}")
    p = f"{D}/{v}/app/Gavel.roc"; s = open(p).read()
    a = "RoomErr : [NotOpen, AlreadyOpen, StillOpen, Infra(Rpc.Infra)]"
    b = "SettleErr : [Infra(Rpc.Infra)]"
    assert a in s and b in s
    s = s.replace(a, "RoomErr : [NotOpen, AlreadyOpen, StillOpen, Infra([StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge])]")
    s = s.replace(b, "SettleErr : [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint), KvErr(Io.Thrown), BadData(Str), TooLarge])]")
    open(p, "w").write(s)
    if v == "a2":
        p = f"{D}/a2/app/web.roc"; s = open(p).read()
        a = "Infra(Rpc.Infra), Remote(Gavel.RoomErr)"
        assert a in s
        s = s.replace(a, "Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint), KvErr(Io.Thrown), R2Err(Io.Thrown), ObjectErr(Io.Thrown), RpcErr(Io.Thrown), MissingEnv(Str), BadData(Str), TooLarge]), Remote(Gavel.RoomErr)")
        s = s.replace("import pf.Rpc\n", "import pf.Rpc\nimport pf.Io\n", 1)
        open(p, "w").write(s)
