extends RefCounted
## HTTP server behaviour: GET/HEAD, keep-alive, pipelining, status codes, traversal, MIME, ranges, large files.

const TIMEOUT := 180

var host: PMCHost
var port := 0
var root := ""


func _write(path: String, content) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if content is String:
		f.store_string(content)
	else:
		f.store_buffer(content)
	f.close()


func run(t) -> void:
	root = t.tmp_dir()
	var www := root.path_join("www")
	_write(www.path_join("index.html"), "<!doctype html><title>hi</title>")
	_write(www.path_join("style.css"), "body{}")
	_write(www.path_join("app.js"), "export const x = 1;")
	_write(www.path_join("data.json"), "{\"a\":1}")
	_write(www.path_join("mod.wasm"), PackedByteArray([0, 97, 115, 109]))
	_write(www.path_join("pic.png"), PackedByteArray([137, 80, 78, 71]))
	_write(www.path_join("blob.xyz"), "?")
	_write(www.path_join("hello world.txt"), "spaced")
	_write(www.path_join("sub/index.html"), "sub index")
	_write(www.path_join("sub/deep.txt"), "deep")
	_write(root.path_join("secret.txt"), "TOP SECRET")
	_write(root.path_join("extra/asset.txt"), "extra asset")

	host = PMCHost.new()
	host.port = 0
	host.controller_dir = www
	host.header_timeout_seconds = 0.6
	host.max_connections_per_address = 0  # this suite opens many loopback sockets
	t.add_node(host)
	t.eq(host.start(), OK, "host starts")
	port = host.get_port()
	t.ok(port > 0, "ephemeral port assigned")

	await _basics(t)
	await _pipelining(t)
	await _errors(t)
	await _traversal(t)
	await _mime(t)
	await _routes(t)
	await _ranges(t)
	await _timeouts(t)
	await _garbage(t)
	await _large_file(t)
	host.stop()


func _fetch(t, path: String, extra := "") -> Dictionary:
	return await PMCTestSocket.get_url(t, port, path, extra)


func _basics(t) -> void:
	t.section("GET / HEAD basics")
	var r := await _fetch(t, "/")
	t.eq(r.get("status"), 200, "GET / status")
	t.eq(r.body.get_string_from_utf8(), "<!doctype html><title>hi</title>", "index.html body")
	t.eq(r.headers.get("content-type"), "text/html; charset=utf-8", "html content-type")
	t.eq(r.headers.get("cache-control"), "no-cache", "html no-cache")
	t.eq(r.headers.get("connection"), "close", "Connection: close honoured")

	var s := PMCTestSocket.new(t)
	await s.connect_to(port)
	var rs: Array = await s.http("HEAD /style.css HTTP/1.1\r\nHost: x\r\n\r\n", 1, 5.0, [true])
	t.eq(rs.size(), 1, "HEAD response")
	if rs.size() == 1:
		t.eq(rs[0].status, 200, "HEAD status")
		t.eq(rs[0].headers.get("content-length"), "6", "HEAD content-length of full body")
		t.eq(rs[0].headers.get("connection"), "keep-alive", "keep-alive default for 1.1")
	# Same connection: a GET right after must parse cleanly (HEAD sent no body).
	rs = await s.http("GET /style.css HTTP/1.1\r\nHost: x\r\n\r\n")
	t.ok(rs.size() == 1 and rs[0].body.get_string_from_utf8() == "body{}", "GET after HEAD on same socket")
	s.close()

	r = await _fetch(t, "/sub")
	t.eq(r.get("status"), 301, "directory without slash redirects")
	t.eq(r.headers.get("location"), "/sub/", "redirect location")
	r = await _fetch(t, "/sub/")
	t.eq(r.body.get_string_from_utf8(), "sub index", "directory index")
	r = await _fetch(t, "/sub/deep.txt?x=1#frag")
	t.eq(r.body.get_string_from_utf8(), "deep", "query string ignored for static")
	r = await _fetch(t, "/hello%20world.txt")
	t.eq(r.body.get_string_from_utf8(), "spaced", "percent-decoded file name")
	r = await _fetch(t, "/pmc/healthz")
	t.eq(r.get("status"), 200, "healthz")
	r = await _fetch(t, "/pmc/info.json")
	t.eq(r.get("status"), 200, "info.json")
	var info = JSON.parse_string(r.body.get_string_from_utf8())
	t.ok(info is Dictionary and info.get("sdk") == 1.0 and info.has("join_url") and info.get("code_required") == false, "info.json payload")
	r = await _fetch(t, "/pmc/pmc.js")
	if FileAccess.file_exists(PMCHost.WEB_DIR.path_join("pmc.js")):
		t.eq(r.get("status"), 200, "/pmc/pmc.js served")
		t.eq(r.headers.get("content-type"), "text/javascript; charset=utf-8", "pmc.js mime")
	else:
		t.eq(r.get("status"), 404, "/pmc/pmc.js 404 while the SDK file is absent")
	r = await _fetch(t, "/pmc/")
	t.eq(r.get("status"), 404, "/pmc/ has no index")
	r = await _fetch(t, "/pmc/qr.png")
	if t.class_available("PMCQr"):
		t.eq(r.get("status"), 200, "qr.png")
		t.eq(r.headers.get("content-type"), "image/png", "qr.png mime")
		var img := Image.new()
		t.eq(img.load_png_from_buffer(r.body), OK, "qr.png decodes as PNG")
	else:
		t.eq(r.get("status"), 501, "qr.png 501 without PMCQr")

	var r10 := PMCTestSocket.new(t)
	await r10.connect_to(port)
	rs = await r10.http("GET /style.css HTTP/1.0\r\n\r\n")
	t.ok(rs.size() == 1 and rs[0].status == 200, "HTTP/1.0 without Host works")
	t.ok(await r10.wait_closed(2.0), "HTTP/1.0 closes by default")


func _pipelining(t) -> void:
	t.section("keep-alive pipelining")
	var s := PMCTestSocket.new(t)
	await s.connect_to(port)
	var batch := ""
	var names := ["style.css", "app.js", "sub/deep.txt", "data.json", "nope.txt", "style.css"]
	for n in names:
		batch += "GET /%s HTTP/1.1\r\nHost: x\r\n\r\n" % n
	var rs: Array = await s.http(batch, names.size())
	t.eq(rs.size(), names.size(), "all pipelined responses")
	var expect := ["body{}", "export const x = 1;", "deep", "{\"a\":1}", null, "body{}"]
	for i in mini(rs.size(), expect.size()):
		if expect[i] == null:
			t.eq(rs[i].status, 404, "pipelined 404 in order")
		else:
			t.eq(rs[i].body.get_string_from_utf8(), expect[i], "pipelined response %d in order" % i)
	# Split a request across several sends.
	await s.send("GET /sub/de")
	await t.wait(0.05)
	await s.send("ep.txt HTTP/1.1\r\nHo")
	await t.wait(0.05)
	rs = await s.http("st: x\r\n\r\n")
	t.ok(rs.size() == 1 and rs[0].body.get_string_from_utf8() == "deep", "request split across packets")
	t.ok(not s.closed, "connection kept alive")
	s.close()


func _errors(t) -> void:
	t.section("status codes")
	var cases := [
		["GET /does-not-exist HTTP/1.1\r\nHost: x\r\n\r\n", 404, "unknown path"],
		["POST /style.css HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", 405, "POST static file"],
		["DELETE / HTTP/1.1\r\nHost: x\r\n\r\n", 405, "DELETE"],
		["POST /nope HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc", 405, "POST unknown path"],
		["POST /x HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n", 413, "body too large"],
		["POST /x HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n", 501, "chunked request body"],
		["HELLO\r\n\r\n", 400, "garbage request line"],
		["GET /%zz HTTP/1.1\r\nHost: x\r\n\r\n", 400, "bad percent escape"],
		["GET /%00 HTTP/1.1\r\nHost: x\r\n\r\n", 400, "encoded NUL"],
		["GET / HTTP/1.1\r\n\r\n", 400, "missing Host"],
		["GET / HTTP/2.0\r\nHost: x\r\n\r\n", 505, "HTTP/2.0"],
		["GET / FOO/1.1\r\nHost: x\r\n\r\n", 400, "bad protocol"],
		["GET relative HTTP/1.1\r\nHost: x\r\n\r\n", 400, "non-origin target"],
		["GET / HTTP/1.1\r\nHost: x\r\nBad Header: y\r\n\r\n", 400, "space in header name"],
		["GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n", 400, "negative Content-Length"],
		["GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", 400, "conflicting Content-Length"],
		["GET / HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n", 400, "obsolete folding"],
		["GET /pmc/ws HTTP/1.1\r\nHost: x\r\n\r\n", 426, "ws path without upgrade"],
		["GET /pmc/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 8\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n", 426, "ws version 8"],
		["GET /pmc/ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: short\r\n\r\n", 400, "bad ws key"],
		["POST /pmc/ws HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", 405, "POST ws"],
	]
	for c in cases:
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		var rs: Array = await s.http(c[0])
		t.eq(rs[0].status if rs.size() > 0 else -1, c[1], c[2])
		s.close()
	var big := "GET / HTTP/1.1\r\nHost: x\r\nX-Pad: %s\r\n\r\n" % "a".repeat(17000)
	var s2 := PMCTestSocket.new(t)
	await s2.connect_to(port)
	var rs2: Array = await s2.http(big)
	t.eq(rs2[0].status if rs2.size() > 0 else -1, 431, "header > 16 KiB")
	t.ok(await s2.wait_closed(2.0), "closed after 431")
	var s3 := PMCTestSocket.new(t)
	await s3.connect_to(port)
	var rs3: Array = await s3.http("GET / HTTP/1.1\r\nHost: x\r\nX-Pad: %s\r\n\r\n" % "a".repeat(15000))
	t.eq(rs3[0].status if rs3.size() > 0 else -1, 200, "15 KiB header accepted")
	s3.close()


func _traversal(t) -> void:
	t.section("path traversal")
	var attacks := [
		"/../secret.txt", "/%2e%2e/secret.txt", "/%2E%2E/secret.txt", "/..%2fsecret.txt", "/%2e%2e%2fsecret.txt",
		"/sub/../../secret.txt", "/sub/%2e%2e/%2e%2e/secret.txt", "/.%2e/secret.txt", "/%2e./secret.txt",
		"/..%5csecret.txt", "/%5c..%5csecret.txt", "/sub/..%5c..%5csecret.txt", "/..\\secret.txt",
		"/sub\\..\\..\\secret.txt", "/%2e%2e%20/secret.txt", "/...%2fsecret.txt", "/..%2e/secret.txt",
		"/%252e%252e/secret.txt", "//../secret.txt", "/./.././secret.txt", "/sub/.%2E/..%2Fsecret.txt",
		"/..;/secret.txt", "/C:/Windows/win.ini", "/c%3a/Windows/win.ini", "/%c0%ae%c0%ae/secret.txt",
		"/..%00/secret.txt", "/sub/deep.txt%00.html", "/.. /secret.txt", "/..%09/secret.txt",
	]
	for a in attacks:
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		var rs: Array = await s.http("GET %s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n" % a)
		var leaked: bool = rs.size() > 0 and rs[0].body.get_string_from_utf8().contains("TOP SECRET")
		var status: int = rs[0].status if rs.size() > 0 else -1
		t.ok(not leaked and status >= 400 and status < 500, "traversal blocked: %s (status %d)" % [a, status])
		s.close()
	# Absolute-form target is reduced to its path.
	var r := await PMCTestSocket.get_url(t, port, "http://evil.example/../secret.txt")
	t.ok(r.get("status", 0) >= 400 and not r.body.get_string_from_utf8().contains("TOP SECRET"), "absolute-form traversal blocked")
	t.eq(PMCStaticFiles.resolve("res://controller", "a/b.txt"), "res://controller/a/b.txt", "resolve joins")
	t.eq(PMCStaticFiles.resolve("user://x/", "/a//./b/"), "user://x/a/b/", "resolve normalises")
	t.eq(PMCStaticFiles.resolve("C:/games/www", "../x"), "", "resolve refuses ..")
	t.eq(PMCStaticFiles.resolve("/srv/www", "a/..."), "", "resolve refuses trailing dots")


func _mime(t) -> void:
	t.section("MIME")
	var cases := {
		"/style.css": "text/css; charset=utf-8", "/app.js": "text/javascript; charset=utf-8",
		"/data.json": "application/json; charset=utf-8", "/mod.wasm": "application/wasm",
		"/pic.png": "image/png", "/blob.xyz": "application/octet-stream", "/sub/deep.txt": "text/plain; charset=utf-8",
	}
	for path in cases:
		var r := await _fetch(t, path)
		t.eq(r.headers.get("content-type"), cases[path], "content-type of %s" % path)
	var js := await _fetch(t, "/app.js")
	t.eq(js.headers.get("cache-control"), "no-cache", "js no-cache")
	var png := await _fetch(t, "/pic.png")
	t.ok(not png.headers.has("cache-control"), "png cacheable")


func _routes(t) -> void:
	t.section("add_route / serve_directory")
	host.add_route("/api/", func(req: PMCHttpRequest):
		if req.sub_path() == "echo":
			return PMCHttpResponse.json({"method": req.method, "body": req.body_text(), "q": req.query})
		if req.sub_path() == "bad":
			return 42
		return null)
	host.add_route("/api/deeper/", func(_req: PMCHttpRequest) -> PMCHttpResponse:
		return PMCHttpResponse.text("deeper"))
	var s := PMCTestSocket.new(t)
	await s.connect_to(port)
	var rs: Array = await s.http("POST /api/echo?a=1&b=x%20y+z HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
	var d = JSON.parse_string(rs[0].body.get_string_from_utf8()) if rs.size() > 0 else null
	t.eq(d, {"method": "POST", "body": "hello", "q": {"a": "1", "b": "x y z"}}, "route gets method, body, query")
	s.close()
	var r := await _fetch(t, "/api/deeper/x")
	t.eq(r.body.get_string_from_utf8(), "deeper", "longest prefix wins")
	r = await _fetch(t, "/api/none")
	t.eq(r.get("status"), 404, "null falls through to static (404)")
	r = await _fetch(t, "/api/bad")
	t.eq(r.get("status"), 500, "invalid handler return -> 500")

	host.serve_directory("/assets", root.path_join("extra"))
	r = await _fetch(t, "/assets/asset.txt")
	t.eq(r.body.get_string_from_utf8(), "extra asset", "serve_directory user://")
	host.serve_directory("/abs/", ProjectSettings.globalize_path(root.path_join("extra")))
	r = await _fetch(t, "/abs/asset.txt")
	t.eq(r.body.get_string_from_utf8(), "extra asset", "serve_directory absolute path")
	r = await _fetch(t, "/abs/../secret.txt")
	t.ok(r.get("status", 0) >= 400, "serve_directory traversal blocked")
	r = await _fetch(t, "/assets/%2e%2e/secret.txt")
	t.ok(r.get("status", 0) >= 400 and not r.body.get_string_from_utf8().contains("SECRET"), "serve_directory encoded traversal blocked")
	host.remove_route("/api/")
	r = await _fetch(t, "/api/echo")
	t.eq(r.get("status"), 404, "remove_route")


func _ranges(t) -> void:
	t.section("Range")
	var r := await _fetch(t, "/app.js", "Range: bytes=7-11\r\n")
	t.eq(r.get("status"), 206, "206")
	t.eq(r.body.get_string_from_utf8(), "const", "range body")
	t.eq(r.headers.get("content-range"), "bytes 7-11/19", "content-range")
	r = await _fetch(t, "/app.js", "Range: bytes=-2\r\n")
	t.eq(r.body.get_string_from_utf8(), "1;", "suffix range")
	r = await _fetch(t, "/app.js", "Range: bytes=100-\r\n")
	t.eq(r.get("status"), 416, "unsatisfiable")
	r = await _fetch(t, "/app.js", "Range: bytes=0-1,3-4\r\n")
	t.eq(r.get("status"), 200, "multi-range ignored")


func _timeouts(t) -> void:
	t.section("slowloris: header timeout")
	var s := PMCTestSocket.new(t)
	await s.connect_to(port)
	await s.send("GET / HTTP/1.1\r\nHost: x\r\n")
	var rs: Array = await s.http("X-Slow: 1\r\n", 1, 3.0)
	t.eq(rs[0].status if rs.size() > 0 else -1, 408, "408 after header timeout")
	t.ok(await s.wait_closed(2.0), "slow connection closed")
	var idle := PMCTestSocket.new(t)
	await idle.connect_to(port)
	t.ok(await idle.wait_closed(3.0), "idle connection closed silently")
	t.eq(idle.buf.size(), 0, "no bytes sent to idle connection")
	# A connection trickling a byte at a time still times out.
	var trickle := PMCTestSocket.new(t)
	await trickle.connect_to(port)
	var sent := 0
	var start := Time.get_ticks_msec()
	while not trickle.closed and Time.get_ticks_msec() - start < 3000:
		await trickle.send("X")
		sent += 1
		await t.wait(0.1)
		trickle.pump()
	t.ok(trickle.closed, "trickling connection closed (sent %d bytes)" % sent)
	var r := await _fetch(t, "/style.css")
	t.eq(r.get("status"), 200, "host still serves")


func _garbage(t) -> void:
	t.section("garbage input")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	for round in 5:
		var junk := PackedByteArray()
		junk.resize(20000 + round * 5000)
		for i in junk.size():
			junk[i] = rng.randi() % 256
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		await s.send(junk)
		t.ok(await s.wait_closed(3.0), "garbage round %d closed" % round)
	var binary_nulls := PMCTestSocket.new(t)
	await binary_nulls.connect_to(port)
	await binary_nulls.send(PackedByteArray([0, 0, 0, 13, 10, 13, 10]))
	t.ok(await binary_nulls.wait_closed(3.0), "NUL request closed")
	var many: Array[PMCTestSocket] = []
	for i in 50:
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		await s.send("GET / HTTP/1.1\r\nHo")
		many.append(s)
	var r := await _fetch(t, "/style.css")
	t.eq(r.get("status"), 200, "serves while 50 partial requests are pending")
	for s in many:
		s.close()


func _large_file(t) -> void:
	t.section("large file streaming")
	var size := 5 * 1024 * 1024 + 123
	var data := PackedByteArray()
	data.resize(size)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var words := PackedInt32Array()
	words.resize(size / 4 + 1)
	for i in words.size():
		words[i] = rng.randi()
	data = words.to_byte_array().slice(0, size)
	var path := root.path_join("www/big.bin")
	_write(path, data)
	var expected_hash := _sha256(data)

	host.reset_poll_stats()
	var t0 := Time.get_ticks_msec()
	var r := await _fetch(t, "/big.bin")
	var ms := Time.get_ticks_msec() - t0
	t.eq(r.get("status"), 200, "large file status")
	t.eq(r.body.size() if r.has("body") else -1, size, "large file size")
	t.eq(_sha256(r.body) if r.has("body") else "", expected_hash, "large file sha256 intact")
	t.note("5 MiB over loopback in %d ms; max host poll %.2f ms" % [ms, host.get_stats().max_poll_usec / 1000.0])
	t.ok(host.get_stats().max_poll_usec < 50000, "no single poll blocked for 50 ms while streaming")

	# Two concurrent downloads with a range.
	var a := PMCTestSocket.new(t)
	var b := PMCTestSocket.new(t)
	await a.connect_to(port)
	await b.connect_to(port)
	await a.send("GET /big.bin HTTP/1.1\r\nHost: x\r\n\r\n")
	await b.send("GET /big.bin HTTP/1.1\r\nHost: x\r\nRange: bytes=1000000-1999999\r\n\r\n")
	var got := [{}, {}]  # lambdas capture locals by value, so use a holder
	await t.wait_until(func() -> bool:
		a.pump()
		b.pump()
		if got[0].is_empty():
			got[0] = PMCTestSocket.parse_response(a.buf)
		if got[1].is_empty():
			got[1] = PMCTestSocket.parse_response(b.buf)
		return not got[0].is_empty() and not got[1].is_empty(), 30.0)
	var ra: Dictionary = got[0]
	var rb: Dictionary = got[1]
	t.eq(_sha256(ra.get("body", PackedByteArray())), expected_hash, "concurrent full download intact")
	t.eq(_sha256(rb.get("body", PackedByteArray())), _sha256(data.slice(1000000, 2000000)), "concurrent range download intact")
	a.close()
	b.close()


func _sha256(d: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(d)
	return ctx.finish().hex_encode()
