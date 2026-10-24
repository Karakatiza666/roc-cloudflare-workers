app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Queue
import pf.Memo
import pf.Http
import pf.Env
import pf.Ctx
import pf.Log

Job : { url : Str }

jobs : Queue(Job)
jobs = Queue.json("JOBS")

Config : { greeting : Str }

load_config! = |{}| {
	res = Http.get!("https://example.com/config.json")?
	cfg : Config
	cfg = res.json!()?
	Ok(cfg)
}

config = Memo.new("config", { max_age_ms: 60_000, load!: load_config! })

fetch! = |req| {
	cfg = config.get!()?
	token = Env.secret!("TOKEN")?
	Log.info!("req", { url: req.url })
	_ = Http.send!(Request.get("https://api.example.com").with_header("Authorization", "Bearer ${token.reveal()}"))?
	jobs.send!({ url: req.url })?
	Ctx.respond!(Response.from_text(200, cfg.greeting))?
	Ok(Response.from_status(200))
}

queue! = |batch| {
	_ = jobs.each!(batch, |_msg, job| {
		_ = Http.get!(job.url)?
		Ok({})
	})
	Ok({})
}

worker = Worker.{ fetch!, queue! }

event! = |e| worker.event!(e)
