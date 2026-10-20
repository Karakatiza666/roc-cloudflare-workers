## N5 option E, as an app module: the platform `Rpc` as it is, plus the closed `Infra` union.
import pf.Io
import pf.Sql

RpcE :: [].{

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
