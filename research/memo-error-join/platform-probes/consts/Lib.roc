## Platform constants that a user keeps at the top of a module, used from main.roc (another module).
import pf.Kv
import pf.Queue
import pf.Workflows
import pf.Rpc
import pf.Service
import pf.Object
import pf.D1
import pf.Io
import pf.Memo

Lib :: [].{
	Room := []

	db = D1.binding("DB")

	cell : Kv.Cell(Str)
	cell = Kv.json("KV").cell("k")

	q : Queue(Str)
	q = Queue.json("Q")

	wf : Workflows(Str)
	wf = Workflows.json("WF")

	ocell : Object.Cell(Str)
	ocell = Object.cell("c")

	room : Rpc.Iface(Lib.Room)
	room = Rpc.iface("Room")

	svc : Service(Lib.Room)
	svc = Service.binding("SVC", Lib.room)

	## Annotated with the callee error (the documented form).
	m_annot : Rpc(Lib.Room, {}, {}, [NotOpen])
	m_annot = Lib.room.method("m_annot")

	## The Memo of option 3: no error type in the constant.
	memo : Memo(Str)
	memo = Memo.new("m", { max_age_ms: 1_000 })

	## An Io description kept as a constant.
	cfg_io = Lib.cell.get_or("d")
}
