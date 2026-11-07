## The version columns of the registry (Registry 5.1, R-IK5; slice 105). Pure: no SQL, no effect.
## The column `version` holds the key of `Semver.to_key` with the top bit flipped (`key XOR 2^63`) as a signed INTEGER.
## Its value is 2^53 or more in most rows, so it goes to D1 as decimal text and comes back through `CAST(version AS TEXT)` (R-IK2).
## So every value of this module that goes to SQL is a `Str` with the decimal form of an `I64`.
## The tests are in `worker/tests/unit/VersionTest.roc` (W0) and `sql/tests/cases/versions/` (W1).
import records.Sorted
import semver.Semver
import semver.VersionReq

Version :: [].{

	## The two columns of one release: `version` is the text to bind, `version_text` is empty for an exact key, else `Semver.to_str`.
	Column : { version : Str, version_text : Str }

	## Two column values to bind: the lower and the upper end of `version BETWEEN lo AND hi`, both inclusive.
	Bounds : { lo : Str, hi : Str }

	## `key XOR 2^63`, read as an `I64`. The key 0 gives `I64.lowest`. The key `U64.highest` gives `I64.highest`.
	## The order of the results (as `I64`) is the order of the keys.
	to_stored : U64 -> I64
	to_stored = |key| key.bitwise_xor(sign_bit).to_i64_wrap()

	## The inverse of `to_stored`.
	from_stored : I64 -> U64
	from_stored = |stored| stored.to_u64_wrap().bitwise_xor(sign_bit)

	## The columns of a version (R-IK5 table "Column"): `version` is `I64.to_str(to_stored(key))`.
	## `version_text` is "" when `Semver.to_key` says `exact`, else `Semver.to_str` (also with build metadata and pre-release).
	column : Semver -> Version.Column
	column = |v| {
		k = v.to_key()
		{ version: I64.to_str(to_stored(k.key)), version_text: if (k.exact) "" else v.to_str() }
	}

	## The version of a row. `version` is the text that `CAST(version AS TEXT)` gives.
	## `version_text` not empty: `Semver.parse` of it. Empty: `Semver.from_key`. `Err(BadColumn)` when the text is no `I64`,
	## when `version_text` is no version, or when the key is not exact and `version_text` is empty.
	## `version_text` is not checked against the key: the database owns that (the row is written by `column`).
	read : Version.Column -> Try(Semver, [BadColumn])
	read = |col| {
		if col.version_text == "" {
			stored = I64.from_str(col.version).map_err(|_| BadColumn)?
			Semver.from_key(from_stored(stored)).map_err(|_| BadColumn)
		} else {
			_ = I64.from_str(col.version).map_err(|_| BadColumn)?
			Semver.parse(col.version_text).map_err(|_| BadColumn)
		}
	}

	## The series of a version (Design 4.1, R-ID1): "M" for a major M of 1 or more, "0.m" below 1.0.
	series_of : Semver -> Str
	series_of = |v|
		if (v.major() >= 1) U64.to_str(v.major()) else "0.${U64.to_str(v.minor())}"

	## The bounds of `?series=` (R-IK5 query table), as column values. `Err(BadSeries)` for a text that is no series:
	## "M" with M of 1 or more, or "0.m". A number is decimal, with no sign, no leading zero (except 0 itself) and fits in a `U64`.
	## Series "M": keys from M x 2^48 to (M + 1) x 2^48 - 1. Series "0.m": from m x 2^32 to (m + 1) x 2^32 - 1.
	## A part of 65535 or more saturates the key (R-IK5): then the interval is the keys of that part: "M" with M >= 65535 goes from
	## 0xFFFF x 2^48 to `U64.highest`; "0.m" with m >= 65535 goes from 0xFFFF x 2^32 to 0xFFFF x 2^32 + 2^32 - 1.
	## The caller then checks `series_of` of each row.
	series_bounds : Str -> Try(Version.Bounds, [BadSeries])
	series_bounds = |series| {
		parts = series.split_on(".")
		match parts {
			[m] => {
				major = strict_number(m)?
				if major == 0 {
					Err(BadSeries)
				} else {
					lo = U64.min(major, 0xFFFF) * two_48
					hi = if (major < 0xFFFF) (major + 1) * two_48 - 1 else U64.highest
					Ok(bounds(lo, hi))
				}
			}
			["0", m] => {
				minor = strict_number(m)?
				lo = U64.min(minor, 0xFFFF) * two_32
				hi = if (minor < 0xFFFF) (minor + 1) * two_32 - 1 else lo + two_32 - 1
				Ok(bounds(lo, hi))
			}
			_ => Err(BadSeries)
		}
	}

	## The bounds of the `range` of the closure query (R-AP16): `VersionReq.key_bounds`, as column values.
	range_bounds : VersionReq -> Version.Bounds
	range_bounds = |req| {
		b = req.key_bounds()
		bounds(b.lo, b.hi)
	}

	## The filter step after the range query (R-IK5 `range`): the versions that `VersionReq.matches`, in the order of the input.
	filter_range : VersionReq, List(Semver) -> List(Semver)
	filter_range = |req, versions| versions.keep_if(|v| req.matches(v))

	## The precedence order (`Semver.order_relative_to`, R-IK5 property 3). The rows come from `ORDER BY version`, which is
	## the order of the keys: versions with one key can be out of order, and this function puts them right. Stable for `Same`.
	sort_precedence : List(Semver) -> List(Semver)
	sort_precedence = |versions| Sorted.sort_with(versions, |a, b| a.order_relative_to(b))

	sign_bit : U64
	sign_bit = 0x8000000000000000

	two_48 : U64
	two_48 = 0x1000000000000

	two_32 : U64
	two_32 = 0x100000000

	bounds : U64, U64 -> Version.Bounds
	bounds = |lo, hi| { lo: I64.to_str(to_stored(lo)), hi: I64.to_str(to_stored(hi)) }

	## A decimal number with no sign, no leading zero (except 0 itself), that fits in a `U64`.
	strict_number : Str -> Try(U64, [BadSeries])
	strict_number = |text| {
		bytes = text.to_utf8()
		digits = !bytes.is_empty() and bytes.all(|b| b >= '0' and b <= '9')
		no_zero = bytes.len() == 1 or bytes.first() != Ok('0')
		if (digits and no_zero) U64.from_str(text).map_err(|_| BadSeries) else Err(BadSeries)
	}
}
