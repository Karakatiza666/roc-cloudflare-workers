## The ids of the registry (Registry 5.1). Pure.
Id :: [].{

	## R-IK2: the first 8 bytes of SHA-256 (the kind byte, then `bytes`), read as a big-endian signed integer (two's complement). Kinds: 1 artifact hash (the 32 bytes), 2 group URL form, 3 lower-case GitHub name. The function does not check the kind.
	## Example: `name_id(2, "github.com/roc-lang/unicode/releases/download/{v}/".to_utf8())` is -2687166099708853831 (R-IK2, case K8).
	name_id : U8, List(U8) -> I64
	name_id = |kind, bytes| {
		digest = Crypto.SHA256.hash([kind].concat(bytes)).to_bytes()
		digest.take_first(8).fold(0.U64, |acc, b| acc * 256 + b.to_u64()).to_i64_wrap()
	}

	## R-IK4: the id of a nightly tag: `days * 2^28 + sha`. `days` counts from 1970-01-01 to the date of the tag, `sha` is the 7 hex digits of the tag as a number. Both tag forms of CLI 6.2, R-CV1 (`nightly-2026-10-09-258ab27`, `nightly-2026-October-09-258ab27`) give one id. A text that is not a nightly tag, or has a date that does not exist, is `Err(NotANightly)`.
	nightly_id : Str -> Try(I64, [NotANightly])
	nightly_id = |tag| match tag.split_on("-") {
		["nightly", year, month, day, sha] => {
			y = digits(year, 4)?
			m = month_number(month)?
			d = digits(day, 2)?
			if m < 1 or m > 12 or d < 1 or d > days_in_month(y, m) {
				Err(NotANightly)
			} else {
				Ok(days_from_civil(y.to_i64_wrap(), m.to_i64_wrap(), d.to_i64_wrap()) * 268435456 + hex7(sha)?)
			}
		}
		_ => Err(NotANightly)
	}

	# Exactly `len` ASCII digits.
	digits : Str, U64 -> Try(U64, [NotANightly])
	digits = |text, len| {
		if text.count_utf8_bytes() == len and text.to_utf8().all(|b| b >= 48 and b <= 57) {
			U64.from_str(text).map_err(|_| NotANightly)
		} else {
			Err(NotANightly)
		}
	}

	# A 2-digit month, or a month name with an upper-case first letter.
	month_number : Str -> Try(U64, [NotANightly])
	month_number = |text| {
		names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
		found = names.fold({ i: 0.U64, hit: 0.U64 }, |acc, n| { i: acc.i + 1, hit: if (n == text) acc.i + 1 else acc.hit })
		if (found.hit > 0) Ok(found.hit) else digits(text, 2)
	}

	# 7 lower-case hex digits.
	hex7 : Str -> Try(I64, [NotANightly])
	hex7 = |text| {
		bytes = text.to_utf8()
		if bytes.len() == 7 {
			bytes.fold_until(
				Ok(0.I64),
				|acc, b| {
					v = if (b >= 48 and b <= 57) Ok(b - 48) else if (b >= 97 and b <= 102) Ok(b - 87) else Err(NotANightly)
					match (acc, v) {
						(Ok(a), Ok(n)) => Continue(Ok(a * 16 + n.to_i64()))
						_ => Break(Err(NotANightly))
					}
				},
			)
		} else {
			Err(NotANightly)
		}
	}

	days_in_month : U64, U64 -> U64
	days_in_month = |y, m| {
		leap = (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
		if m == 2 {
			if (leap) 29 else 28
		} else if m == 4 or m == 6 or m == 9 or m == 11 {
			30
		} else {
			31
		}
	}

	# Days from 1970-01-01 (civil date algorithm).
	days_from_civil : I64, I64, I64 -> I64
	days_from_civil = |year, m, d| {
		y = if (m <= 2) year - 1 else year
		era = y // 400
		yoe = y - era * 400
		mp = if (m > 2) m - 3 else m + 9
		doy = (153 * mp + 2) // 5 + d - 1
		doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
		era * 146097 + doe - 719468
	}
}
