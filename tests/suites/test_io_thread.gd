extends RefCounted
## io_thread_enabled: socket accept/read/write/decode runs on a worker thread; the main thread applies
## complete events. The whole protocol surface must behave identically.

func run(t) -> void:
	var host := PMCHost.new()
	host.port = 0
	host.controller_dir = ""
	host.heartbeat_seconds = 0.0
	host.io_thread_enabled = true
	t.add_node(host)

	t.section("http over the io thread")
	t.eq(host.start(), OK, "start with io thread")
	var resp := await PMCTestSocket.get_url(t, host.get_port(), "/pmc/healthz")
	t.eq(resp.get("status", 0), 200, "healthz answers")
	var s404 := await PMCTestSocket.get_url(t, host.get_port(), "/nope")
	t.eq(s404.get("status", 0), 404, "404 routed")

	t.section("ws handshake and messages")
	var joined := []
	host.player_joined.connect(func(p: PMCPlayer): joined.append(p))
	var got := []
	host.message_received.connect(func(p: PMCPlayer, d): got.append([p.id, d]))
	var ws := PMCTestWs.new(t)
	t.ok(await ws.open(host.get_port()), "upgrade")
	await ws.hello({"name": "Io"})
	var w := await ws.wait_json("pmc.welcome")
	t.ok(w.has("id") and w.has("token"), "welcome over io thread")
	t.ok(await t.wait_until(func() -> bool: return joined.size() == 1, 3.0), "player_joined emitted")
	await ws.send_json({"t": "msg", "d": {"x": 1}})
	t.ok(await t.wait_until(func() -> bool: return got.size() == 1, 3.0), "client->host msg")
	t.eq(got[0][1], {"x": 1}, "payload intact")
	host.send(host.players()[0], {"y": 2})
	var m := await ws.wait_json("msg")
	t.eq(m.get("d"), {"y": 2}, "host->client msg")
	await ws.send_frame(PMCWsFrame.OP_BINARY, PackedByteArray([9, 8, 7]))
	t.ok(await t.wait_until(func() -> bool: return got.size() == 2, 3.0), "binary msg")
	t.eq(got[1][1], PackedByteArray([9, 8, 7]), "binary payload")

	t.section("second client, per-socket ordering, ping/pong")
	var ws2 := PMCTestWs.new(t)
	t.ok(await ws2.open(host.get_port()), "second upgrade")
	await ws2.hello({"name": "Two"})
	var w2 := await ws2.wait_json("pmc.welcome")
	t.ok(w2.get("id", 0) != w.get("id", -1), "second player got a different id")
	var p1: PMCPlayer = host.players()[0]
	var p2: PMCPlayer = host.players()[1]
	for i in 5:
		host.send(p1, {"seq": i})
	for i in 5:
		var ev := await ws.wait_json("msg")
		t.eq(ev.get("d"), {"seq": i}, "per-socket order kept")
	# app-level ping -> pong with epoch s
	await ws2.send_json({"t": "pmc.ping", "c": 42})
	var pong := await ws2.wait_json("pmc.pong")
	t.eq(pong.get("c"), 42.0, "pong echoes c")
	t.ok(int(pong.get("s", 0)) > 1_700_000_000_000, "pong.s is epoch ms")

	t.section("kick and leave still work")
	host.kick(p2, "bye")
	t.ok(await ws2.wait_socket_closed(3.0), "kicked socket closes")
	await ws.send_json({"t": "pmc.leave"})
	var code := await ws.wait_close(3.0)
	t.eq(code, 1000, "leave gets close 1000")
	t.ok(await t.wait_until(func() -> bool: return host.players().is_empty(), 3.0), "players emptied")

	t.section("stop joins the thread")
	host.stop()
	t.eq(host.is_running(), false, "stopped")
	t.ok(host._io_thread == null, "worker thread joined")
