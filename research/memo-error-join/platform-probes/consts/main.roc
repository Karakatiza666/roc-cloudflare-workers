app [event!] { pf: platform "../../../../platform/main.roc" }
import pf.Worker
import pf.Request
import pf.Response
import pf.Sql
import pf.Io
import pf.Object
import pf.Memo
import Lib

Faults : [D1Err(Io.Thrown), KvErr(Io.Thrown), QueueErr(Io.Thrown), WorkflowsErr(Io.Thrown), StorageErr(Io.Thrown), RpcErr(Io.Thrown), BadData(Str), TooLarge, MissingEnv(Str)]

Wide : [NotFound, AlreadyExists, Constraint(Sql.Constraint), Remote([NotOpen]), Infra(Faults)]

d1! : () => Try(Str, [Constraint(Sql.Constraint), Infra([D1Err(Io.Thrown), BadData(Str), TooLarge])])
d1! = || {
	n : List({ n : I64 })
	n = Lib.db.all!("SELECT 1 AS n", Sql.none)?
	Ok(n.len().to_str())
}

# Each pair: one caller with an inferred error, one with the wide annotated error. Each joins with d1!.
kv_web! = || {
	v = Lib.cell.get_or!("x")?
	_ = Lib.cell.get!()?
	Ok("${v}${d1!()?}")
}
kv_ledger! : () => Try(Str, Wide)
kv_ledger! = || {
	v = Lib.cell.get_or!("x")?
	Ok("${v}${d1!()?}")
}

q_web! = || {
	Lib.q.send!("x")?
	d1!()
}
q_ledger! : () => Try(Str, Wide)
q_ledger! = || {
	Lib.q.send!("x")?
	Ok(d1!()?)
}

wf_web! = || {
	_ = Lib.wf.create!("x")?
	d1!()
}
wf_ledger! : () => Try(Str, Wide)
wf_ledger! = || {
	_ = Lib.wf.create!("x")?
	Ok(d1!()?)
}

oc_web! = |self| {
	v = Lib.ocell.get_or!(self, "x")?
	Ok("${v}${d1!()?}")
}
oc_ledger! : Object.Self => Try(Str, Wide)
oc_ledger! = |self| {
	v = Lib.ocell.get_or!(self, "x")?
	Ok("${v}${d1!()?}")
}

rpc_web! = || {
	Lib.svc.call!(Lib.m_annot, {})?
	d1!()
}
rpc_ledger! : () => Try(Str, Wide)
rpc_ledger! = || {
	Lib.svc.call!(Lib.m_annot, {})?
	Ok(d1!()?)
}

io_web! = || {
	v = Io.run!(Lib.cfg_io)?
	Ok("${v}${d1!()?}")
}
io_ledger! : () => Try(Str, Wide)
io_ledger! = || {
	v = Io.run!(Lib.cfg_io)?
	Ok("${v}${d1!()?}")
}

memo_web! = || {
	v = Lib.memo.get!(|| Lib.cell.get_or!("x"))?
	Ok("${v}${d1!()?}")
}
memo_ledger! : () => Try(Str, Wide)
memo_ledger! = || {
	v = Lib.memo.get!(|| Lib.cell.get_or!("x"))?
	_ = Lib.memo.get!(|| d1!())?
	Ok("${v}${d1!()?}")
}

# A Memo constant of this module with two uses of other error types.
local : Memo(Str)
local = Memo.new("l", { max_age_ms: 1_000 })

local_a! = || {
	v = local.get!(|| Lib.cell.get_or!("x"))?
	Ok("${v}${d1!()?}")
}
local_b! : () => Try(Str, Wide)
local_b! = || {
	v = local.get!(|| d1!())?
	Lib.q.send!(v)?
	Ok(v)
}

show = |r| match r {
	Ok(s) => s
	Err(e) => Str.inspect(e)
}

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	t = [show(kv_web!()), show(kv_ledger!()), show(q_web!()), show(q_ledger!()), show(wf_web!()), show(wf_ledger!()), show(rpc_web!()), show(rpc_ledger!()), show(io_web!()), show(io_ledger!()), show(memo_web!()), show(memo_ledger!()), show(local_a!()), show(local_b!())]
	Ok(Response.from_text(200, Str.join_with(t, ",")))
}

_oc! = |self| [show(oc_web!(self)), show(oc_ledger!(self))]

worker = Worker.new({ fetch!: fetch!, bindings: [Lib.db.declare(), Lib.cell.declare()] })
event! = |e| worker.event!(e)
