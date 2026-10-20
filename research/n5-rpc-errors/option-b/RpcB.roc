## N5 option B, as an app module: one alias with a row variable. The platform `Rpc` does not change.
import pf.Io
import pf.Sql

RpcB :: [].{

	## The infrastructure tags next to the domain tags `e`, in one flat union.
	InfraOr(e) : [StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), D1Err(Io.Thrown), KvErr(Io.Thrown), R2Err(Io.Thrown), CacheErr(Io.Thrown), QueueErr(Io.Thrown), ObjectErr(Io.Thrown), ServiceErr(Io.Thrown), RpcErr(Io.Thrown), HttpErr(Io.Thrown), Network(Io.Thrown), SocketErr(Io.Thrown), BodyErr(Io.Thrown), CryptoErr(Io.Thrown), AiErr(Io.Thrown), VectorizeErr(Io.Thrown), WorkflowsErr(Io.Thrown), EmailErr(Io.Thrown), AnalyticsErr(Io.Thrown), AssetsErr(Io.Thrown), SecretsStoreErr(Io.Thrown), LimitErr(Io.Thrown), BadData(Str), InvalidJson(Str), MissingEnv(Str), TooLarge, TimedOut, ..e]

	## The infrastructure tags alone. A second list: `RpcB.InfraOr([])` has no derived codec (README Q5).
	Infra : [
		StorageErr(Io.Thrown),
		SqlErr(Io.Thrown),
		Constraint(Sql.Constraint),
		D1Err(Io.Thrown),
		KvErr(Io.Thrown),
		R2Err(Io.Thrown),
		CacheErr(Io.Thrown),
		QueueErr(Io.Thrown),
		ObjectErr(Io.Thrown),
		ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown),
		HttpErr(Io.Thrown),
		Network(Io.Thrown),
		SocketErr(Io.Thrown),
		BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown),
		AiErr(Io.Thrown),
		VectorizeErr(Io.Thrown),
		WorkflowsErr(Io.Thrown),
		EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown),
		AssetsErr(Io.Thrown),
		SecretsStoreErr(Io.Thrown),
		LimitErr(Io.Thrown),
		BadData(Str),
		InvalidJson(Str),
		MissingEnv(Str),
		TooLarge,
		TimedOut,
	]
}
