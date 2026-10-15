import Handlers

main! = |_args| {
	h = Handlers.{ fetch!: |req| "fetched ${req}" }
	echo!("${Handlers.event!(h, Fetch("/v1/pkg"))} | ${Handlers.event!(h, Scheduled("* * * * *"))}\n")
	Ok({})
}
