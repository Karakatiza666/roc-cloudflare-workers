## The API types of the registry and their JSON codecs (Registry 4, 5, 5.1; Design 6.1, R-PK7; slice 104). Pure Roc: no `Fx`, no clock. No dependency.
## It builds and passes its tests on both nightlies, `ROC_TAG` and `ROC_TAG_WORKER` (R-PK7, TESTING.md TW28, TW31).
## The CLI does not use it yet (PLAN G16, Design Q68). The records of `compat.db` are not here.
package
	[
		Account,
		Artifact,
		Audit,
		Closure,
		Code,
		Compat,
		Id,
		Index,
		Problem,
		Release,
		Short,
		Sorted,
		Toolchain,
		Work,
	]
	{}
