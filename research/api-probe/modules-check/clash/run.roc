import Crypto

main! = |_args| {
	echo!("${Crypto.name(Hs256)} ${Crypto.SHA256.hash([1]).to_hex()}\n")
	Ok({})
}
