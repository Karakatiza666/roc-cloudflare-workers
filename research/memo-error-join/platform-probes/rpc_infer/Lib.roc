## An Rpc method constant with no annotation of `err`: the callee is in main.roc.
import pf.Rpc
import pf.Service

Lib :: [].{
	Room := []

	room : Rpc.Iface(Lib.Room)
	room = Rpc.iface("Room")

	svc : Service(Lib.Room)
	svc = Service.binding("SVC", Lib.room)

	m_inf = Lib.room.method("m_inf")
}
