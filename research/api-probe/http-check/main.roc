app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.29.0/GrSTLEKd6yw8orQ5ByQQVY3Htg59vZYaoHBvQELueiMB.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## Does roc-lang/http build on the pinned nightlies, and do its types fit the API (API.md AQ2)?
import pf.Stdout
import http.Request
import http.Response
import http.Method
import http.Header

main! = |_args| {
	req : Request
	req = Request.from_method(GET).with_uri("https://example.com/v1/pkg/a/b")
	res : Response
	res = Response.from_status(404).add_header("content-type", "text/plain").with_body("no".to_utf8())
	Stdout.line!("${Str.inspect(req.method())} ${res.status().to_str()} ${res.headers().len().to_str()}")?
	Ok({})
}
