#!/usr/bin/env python3
"""Make work/sweep-K from work/g1a: the app has its own alias Gavel.Faults, a closed union of K Infra tags. RoomErr,
SettleErr and error_response! use it in place of Rpc.Infra (29 tags). K = 11 is the least that the auction needs."""
import sys, shutil, re
# argv[2] (optional): the payload of the tags above the 11 that the app needs: "thrown" (default, as Rpc.Infra), "str" or "none".
# The extra tags are never made, so they test the cost of a tag in the codecs alone.
k = int(sys.argv[1]); mode = sys.argv[2] if len(sys.argv) > 2 else "thrown"; D = "research/g1a-size/work"
dst = f"{D}/sweep-{k}" + ("" if mode == "thrown" else "-" + mode)
shutil.rmtree(dst, ignore_errors=True); shutil.copytree(f"{D}/g1a", dst)
first = ["StorageErr(Io.Thrown)", "SqlErr(Io.Thrown)", "Constraint(Sql.Constraint)", "BadData(Str)", "TooLarge", "D1Err(Io.Thrown)",
         "KvErr(Io.Thrown)", "R2Err(Io.Thrown)", "ObjectErr(Io.Thrown)", "RpcErr(Io.Thrown)", "MissingEnv(Str)"]
rest = [f"{n}(Io.Thrown)" for n in "CacheErr QueueErr ServiceErr HttpErr Network SocketErr BodyErr CryptoErr AiErr VectorizeErr WorkflowsErr EmailErr AnalyticsErr AssetsErr SecretsStoreErr LimitErr".split()] + ["InvalidJson(Str)", "TimedOut"]
if mode != "thrown":
    rest = [f"Extra{i}" + ("(Str)" if mode == "str" else "") for i in range(1, 19)]
tags = (first + rest)[:k]
assert len(tags) == k, k
p = f"{dst}/app/Gavel.roc"; s = open(p).read()
s = s.replace("\t## What a lot room can answer.", "\t## The infrastructure errors of this app (a part of Rpc.Infra).\n\tFaults : [" + ", ".join(tags) + "]\n\n\t## What a lot room can answer.", 1)
s = s.replace("Infra(Rpc.Infra)", "Infra(Gavel.Faults)")
open(p, "w").write(s)
p = f"{dst}/app/web.roc"; s = open(p).read()
s = s.replace("Infra(Rpc.Infra)", "Infra(Gavel.Faults)")
open(p, "w").write(s)
