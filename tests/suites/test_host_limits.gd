extends RefCounted
## Abuse limits for a publicly reachable (tunneled) host: per-address join-code blocking, CF-Connecting-IP
## handling behind the tunnel, per-address connection caps, and per-address admin PIN blocking.

const TIMEOUT := 120

var host: PMCHost
var port := 0


class FakeTunnel extends Node:
	signal state_changed(state: String, detail: String)
	var url := "https://fake.trycloudflare.com"
	func start(_p: int) -> void:
		pass
	func stop() -> void:
		pass


func _hello_reject(t, code: String, headers := "") -> Dictionary:
	var ws := PMCTestWs.new(t)
	if not await ws.open(port, "/pmc/ws", headers):
		return {"t": "open failed"}
	await ws.hello({"code": code})
	var ev := await ws.wait_event(func(e: Dictionary) -> bool:
		if e.op != "text":
			return false
		var d = JSON.parse_string(e.data)
		return d is Dictionary and (d.get("t") == "pmc.reject" or d.get("t") == "pmc.welcome"))
	ws.close()
	return JSON.parse_string(ev.data) if not ev.is_empty() else {}


func _set_fake_tunnel(on: bool) -> void:
	if on and host._tunnel == null:
		var f := FakeTunnel.new()
		host.add_child(f)
		host._tunnel = f
	elif not on and host._tunnel != null:
		host._tunnel.queue_free()
		host._tunnel = null


func run(t) -> void:
	host = PMCHost.new()
	host.port = 0
	host.controller_dir = ""
	host.heartbeat_seconds = 0.0
	host.grace_seconds = 0.0
	host.join_code = "GOOD"
	host.join_code_max_failures = 10
	host.join_code_block_seconds = 6.0  # generous: 10 handshakes must fit inside it on a loaded CI box
	t.add_node(host)
	t.eq(host.start(), OK, "start")
	port = host.get_port()

	t.section("wrong join codes block the address")
	for i in 9:
		var r := await _hello_reject(t, "BAD%d" % i)
		t.eq(r.get("code"), "bad_code", "wrong code %d rejected" % (i + 1))
	var ok := await _hello_reject(t, "GOOD")
	t.eq(ok.get("t"), "pmc.welcome", "9 failures: correct code still works")
	var tenth := await _hello_reject(t, "NOPE")
	t.eq(tenth.get("code"), "bad_code", "10th wrong code")
	var blocked := await _hello_reject(t, "GOOD")
	t.eq(blocked.get("code", blocked), "bad_code", "blocked: correct code refused")
	t.ok(String(blocked.get("reason", "")).contains("too many"), "blocked reason explains (%s)" % blocked.get("reason", ""))
	var missing := await _hello_reject(t, "")
	t.eq(missing.get("code"), "bad_code", "missing code while blocked")
	await t.wait(6.2)
	var after := await _hello_reject(t, "good")
	t.eq(after.get("t"), "pmc.welcome", "block expires")
	# Missing codes don't count as guesses.
	for i in 12:
		await _hello_reject(t, "")
	t.eq((await _hello_reject(t, "GOOD")).get("t"), "pmc.welcome", "empty codes never trigger the block")

	t.section("known tokens bypass the block")
	host.grace_seconds = 5.0
	var keeper := PMCTestWs.new(t)
	await keeper.open(port)
	await keeper.hello({"code": "GOOD"})
	var kw := await keeper.wait_json("pmc.welcome")
	keeper.close()
	for i in 10:
		await _hello_reject(t, "WRONG")
	t.eq((await _hello_reject(t, "GOOD")).get("code"), "bad_code", "address blocked again")
	var back := PMCTestWs.new(t)
	await back.open(port)
	await back.hello({"token": kw.get("token", "")})
	t.eq((await back.wait_json("pmc.welcome")).get("rejoined"), true, "rejoin with token works while blocked")
	back.close()
	host.grace_seconds = 0.0
	await t.wait(6.2)

	t.section("CF-Connecting-IP behind the tunnel")
	var plain := PMCTestWs.new(t)
	await plain.open(port, "/pmc/ws", "CF-Connecting-IP: 203.0.113.7\r\n")
	await plain.hello({"code": "GOOD"})
	var pw := await plain.wait_json("pmc.welcome")
	t.eq(host.get_player(int(pw.get("id", 0))).remote_address, "127.0.0.1", "header ignored without a tunnel")
	plain.close()
	_set_fake_tunnel(true)
	var via := PMCTestWs.new(t)
	await via.open(port, "/pmc/ws", "CF-Connecting-IP: 203.0.113.7\r\n")
	await via.hello({"code": "GOOD"})
	var vw := await via.wait_json("pmc.welcome")
	t.eq(host.get_player(int(vw.get("id", 0))).remote_address, "203.0.113.7", "remote_address from CF-Connecting-IP behind tunnel")
	via.close()
	var junk := PMCTestWs.new(t)
	await junk.open(port, "/pmc/ws", "CF-Connecting-IP: not-an-ip\r\n")
	await junk.hello({"code": "GOOD"})
	var jw := await junk.wait_json("pmc.welcome")
	t.eq(host.get_player(int(jw.get("id", 0))).remote_address, "127.0.0.1", "invalid CF-Connecting-IP falls back to the peer")
	junk.close()
	for i in 10:
		await _hello_reject(t, "WRONG", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.eq((await _hello_reject(t, "GOOD", "CF-Connecting-IP: 203.0.113.7\r\n")).get("code"), "bad_code", "tunneled address blocked")
	t.eq((await _hello_reject(t, "GOOD", "CF-Connecting-IP: 198.51.100.9\r\n")).get("t"), "pmc.welcome", "other tunneled address unaffected")
	t.eq((await _hello_reject(t, "GOOD")).get("t"), "pmc.welcome", "loopback (no header) unaffected")
	_set_fake_tunnel(false)
	t.eq((await _hello_reject(t, "GOOD", "CF-Connecting-IP: 203.0.113.7\r\n")).get("t"), "pmc.welcome", "header not trusted once the tunnel is gone")

	t.section("per-address connection cap")
	await t.wait(0.3)
	host.max_connections_per_address = 3
	var socks: Array[PMCTestSocket] = []
	for i in 3:
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		socks.append(s)
	await t.wait(0.1)
	var fourth := PMCTestSocket.new(t)
	await fourth.connect_to(port)
	t.ok(await fourth.wait_closed(2.0), "4th connection from the same address refused")
	var rs: Array = await socks[0].http("GET /pmc/healthz HTTP/1.1\r\nHost: x\r\n\r\n")
	t.ok(rs.size() == 1 and rs[0].status == 200, "existing connections keep working")
	socks[1].close()
	await t.wait(0.6)  # reap happens on the next status check / timer tick
	var again := PMCTestSocket.new(t)
	await again.connect_to(port)
	rs = await again.http("GET /pmc/healthz HTTP/1.1\r\nHost: x\r\n\r\n")
	t.ok(rs.size() == 1 and rs[0].status == 200, "slot freed after a close")
	for s in socks:
		s.close()
	again.close()
	fourth.close()
	await t.wait(0.6)

	t.section("per-address cap behind the tunnel")
	_set_fake_tunnel(true)
	var a_socks: Array[PMCTestSocket] = []
	for i in 3:
		var s := PMCTestSocket.new(t)
		await s.connect_to(port)
		var r: Array = await s.http("GET /pmc/healthz HTTP/1.1\r\nHost: x\r\nCF-Connecting-IP: 192.0.2.1\r\n\r\n")
		t.ok(r.size() == 1 and r[0].status == 200, "tunneled connection %d from 192.0.2.1" % (i + 1))
		a_socks.append(s)
	var over := PMCTestSocket.new(t)
	await over.connect_to(port)
	var ro: Array = await over.http("GET /pmc/healthz HTTP/1.1\r\nHost: x\r\nCF-Connecting-IP: 192.0.2.1\r\n\r\n")
	t.eq(ro[0].status if ro.size() > 0 else -1, 429, "4th tunneled connection from the same client -> 429")
	var other := PMCTestSocket.new(t)
	await other.connect_to(port)
	var rother: Array = await other.http("GET /pmc/healthz HTTP/1.1\r\nHost: x\r\nCF-Connecting-IP: 192.0.2.2\r\n\r\n")
	t.ok(rother.size() == 1 and rother[0].status == 200, "different client address through the same tunnel is fine")
	for s in a_socks:
		s.close()
	over.close()
	other.close()
	_set_fake_tunnel(false)
	host.max_connections_per_address = 128
	await t.wait(0.6)

	t.section("admin PIN failures per address")
	host.admin_pin = "1357"
	for conn_i in 5:
		var ws := PMCTestWs.new(t)
		await ws.open(port)
		await ws.hello({"code": "GOOD"})
		await ws.wait_json("pmc.welcome")
		for i in 5:
			await ws.send_json({"t": "pmc.auth", "pin": "0000"})
			t.eq((await ws.wait_json("pmc.auth")).get("ok"), false, "wrong pin (connection %d, try %d)" % [conn_i + 1, i + 1])
		ws.close()
	var fresh := PMCTestWs.new(t)
	await fresh.open(port)
	await fresh.hello({"code": "GOOD"})
	await fresh.wait_json("pmc.welcome")
	await fresh.send_json({"t": "pmc.auth", "pin": "1357"})
	var res := await fresh.wait_json("pmc.auth")
	t.eq(res.get("ok"), false, "after 20+ failures from one address, a new connection is still locked out")
	t.ok(float(res.get("locked_ms", 0)) > 30000, "address lockout ~60 s")
	fresh.close()

	t.section("global PIN budget disables the PIN")
	# 25 wrong PINs were tried above (> admin_pin_max_failures = 20). A new address must still be refused.
	_set_fake_tunnel(true)
	var dws := PMCTestWs.new(t)
	await dws.open(port, "/pmc/ws", "CF-Connecting-IP: 203.0.113.99\r\n")
	await dws.hello({"code": "GOOD"})
	await dws.wait_json("pmc.welcome")
	await dws.send_json({"t": "pmc.auth", "pin": "1357"})
	var dres := await dws.wait_json("pmc.auth")
	t.eq(dres.get("ok"), false, "correct PIN refused after the global budget is spent")
	t.eq(dres.get("disabled"), true, "disabled flag reported")
	dws.close()

	t.section("info.json / qr.png gated while tunneled")
	var no_code := await PMCTestSocket.get_url(t, port, "/pmc/info.json", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.eq(no_code.get("status"), 403, "info.json refuses a remote request without a code")
	var with_code := await PMCTestSocket.get_url(t, port, "/pmc/info.json?code=good", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.eq(with_code.get("status"), 200, "info.json answers with the code (case-insensitive)")
	var bad_code := await PMCTestSocket.get_url(t, port, "/pmc/info.json?code=XXXX", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.eq(bad_code.get("status"), 403, "info.json refuses a wrong code")
	var qr := await PMCTestSocket.get_url(t, port, "/pmc/qr.png", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.eq(qr.get("status"), 403, "qr.png refuses a remote request")
	var local := await PMCTestSocket.get_url(t, port, "/pmc/info.json")
	t.eq(local.get("status"), 200, "info.json stays open to loopback")
	var js := await PMCTestSocket.get_url(t, port, "/pmc/pmc.js", "CF-Connecting-IP: 203.0.113.7\r\n")
	t.ok(js.get("status") != 403, "pmc.js stays public while tunneled")
	_set_fake_tunnel(false)

	t.section("require_player / players_only mounts")
	var pws := PMCTestWs.new(t)
	await pws.open(port)
	await pws.hello({"code": "GOOD"})
	var pww := await pws.wait_json("pmc.welcome")
	var tok := String(pww.get("token", ""))
	var pid := int(pww.get("id", 0))
	host.add_route("/who", func(req: PMCHttpRequest):
		var pl := host.require_player(req)
		if pl == null:
			return PMCHttpResponse.error(403)
		return PMCHttpResponse.json({"id": pl.id}))
	var r := await PMCTestSocket.get_url(t, port, "/who")
	t.eq(r.get("status"), 403, "route 403 without a token")
	r = await PMCTestSocket.get_url(t, port, "/who?t=" + tok)
	t.eq(JSON.parse_string(r.body.get_string_from_utf8()), {"id": pid}, "?t= maps to the player")
	r = await PMCTestSocket.get_url(t, port, "/who", "Cookie: pmc_token=%s; other=x\r\n" % tok)
	t.eq(r.get("status"), 200, "pmc_token cookie maps to the player")
	r = await PMCTestSocket.get_url(t, port, "/who?t=deadbeef")
	t.eq(r.get("status"), 403, "unknown token 403")
	var priv: String = t.tmp_dir().path_join("priv")
	DirAccess.make_dir_recursive_absolute(priv)
	var f := FileAccess.open(priv.path_join("save.dat"), FileAccess.WRITE)
	f.store_string("save bytes")
	f.close()
	host.serve_directory("/priv", priv, true)
	r = await PMCTestSocket.get_url(t, port, "/priv/save.dat")
	t.eq(r.get("status"), 403, "players_only dir refuses anonymous")
	r = await PMCTestSocket.get_url(t, port, "/priv/save.dat?t=" + tok)
	t.eq(r.body.get_string_from_utf8(), "save bytes", "players_only dir serves with ?t=")
	r = await PMCTestSocket.get_url(t, port, "/priv/save.dat", "Cookie: pmc_token=%s\r\n" % tok)
	t.eq(r.get("status"), 200, "players_only dir serves with cookie")
	pws.close()
	await t.wait_until(func() -> bool: return host.get_player(pid) == null, 3.0)  # grace_seconds = 0
	r = await PMCTestSocket.get_url(t, port, "/who?t=" + tok)
	t.eq(r.get("status"), 403, "gone player's token stops working")
	host.stop()
