extends RefCounted
## Real end-to-end Cloudflare Quick Tunnel test. Opt-in: set PMC_TUNNEL_E2E=1.
##
## Downloads cloudflared if needed, starts a PMCHost (or the tiny PMCTunnelTestResponder when the host class
## isn't available), opens a quick tunnel, fetches https://<random>.trycloudflare.com/pmc/healthz with curl
## from outside the engine, then joins over wss:// through the tunnel and measures ping round trips.
## Uses the public internet and a throwaway account-less tunnel.

const TIMEOUT := 300.0


func run(t) -> void:
	if OS.get_environment("PMC_TUNNEL_E2E") != "1":
		t.skip("set PMC_TUNNEL_E2E=1 to run the real Cloudflare quick tunnel test")
		return

	t.section("cloudflared binary")
	var bin := PMCTunnel.resolve_binary(OS.get_environment("PMC_CLOUDFLARED"))
	if bin == "":
		var dl := PMCTunnel.new()
		t.add_node(dl)
		var result := [null]
		dl.download_finished.connect(func(ok: bool, info: String) -> void: result[0] = [ok, info])
		var d0 := Time.get_ticks_msec()
		dl.download()
		await t.wait_until(func(): return result[0] != null, 240.0)
		t.ok(result[0] != null and result[0][0], "download finished: %s" % [result[0]])
		t.note("downloaded cloudflared in %.1f s -> %s" % [(Time.get_ticks_msec() - d0) / 1000.0, result[0][1] if result[0] != null else "?"])
		t.ok(" ".join(dl.log_lines).contains("SHA-256 verified"), "download checked against the release digest (%s)" % [dl.log_lines])
		bin = PMCTunnel.resolve_binary()
	t.ok(bin != "", "cloudflared resolved")
	if bin == "":
		return
	var ver := []
	OS.execute(bin, ["--version"], ver, true)
	t.note("using %s (%s)" % [bin, "".join(ver).strip_edges()])

	t.section("tunnel")
	var use_host: bool = t.class_available("PMCHost")
	var host: Node = null
	var responder: PMCTunnelTestResponder = null
	var tunnel: PMCTunnel = null
	var port := 0
	var states: Array = []
	var t0 := Time.get_ticks_msec()
	if use_host:
		host = t.add_node(_new_global("PMCHost"))
		host.port = 18480
		host.cloudflared_path = bin
		host.tunnel_state_changed.connect(func(s: String, d: String) -> void:
			states.append([s, d, Time.get_ticks_msec() - t0]))
		host.start_tunnel()
		port = host.get_port()
	else:
		responder = t.add_node(PMCTunnelTestResponder.new())
		port = responder.listen(18480)
		tunnel = t.add_node(PMCTunnel.new())
		tunnel.cloudflared_path = bin
		tunnel.state_changed.connect(func(s: String, d: String) -> void:
			states.append([s, d, Time.get_ticks_msec() - t0]))
		tunnel.start(port)
	t.note("local server: %s on port %d" % ["PMCHost" if use_host else "PMCTunnelTestResponder", port])
	var ready: bool = await t.wait_until(func(): return states.any(func(s): return s[0] == "ready" or s[0] == "failed"), 90.0)
	t.ok(ready, "tunnel reached ready/failed")
	var last: Array = states[states.size() - 1] if states.size() > 0 else ["none", "", 0]
	t.eq(last[0], "ready", "tunnel ready (states: %s)" % [states])
	if last[0] != "ready":
		return
	var url: String = last[1]
	var ready_ms: int = last[2]
	t.note("tunnel ready in %.2f s: %s" % [ready_ms / 1000.0, url])
	var active: PMCTunnel = host.get_tunnel() if use_host else tunnel
	if active != null:
		for line in active.log_lines:
			if line.begins_with("PMCTunnel:") or line.contains("Registered tunnel connection"):
				t.note("  " + line)
	t.ok(RegEx.create_from_string("^https://[a-z0-9-]+\\.trycloudflare\\.com$").search(url) != null, "URL shape")
	if use_host:
		t.ok(host.join_url().begins_with(url), "join URL uses the tunnel: %s" % host.join_url())
		t.eq(str(host.join_code).length(), 4, "join code auto-generated")

	t.section("curl from outside")
	var fetched := false
	var f0 := Time.get_ticks_msec()
	var attempts := 0
	var last_out := ""
	while not fetched and Time.get_ticks_msec() - f0 < 90000:
		attempts += 1
		var res: Dictionary = await _curl(t, url + "/pmc/healthz")
		last_out = res.out
		if res.code == 0 and res.out.contains("\n200 ") and res.out.begins_with("ok"):
			fetched = true
			t.note("healthz via tunnel OK after %.1f s (%d attempts): %s" % [(Time.get_ticks_msec() - f0) / 1000.0, attempts, res.out.replace("\n", " | ")])
		else:
			await t.wait(2.0)
	t.ok(fetched, "GET /pmc/healthz through the tunnel (last: %s)" % last_out)
	if fetched:
		var times: Array[String] = []
		for i in 5:
			var r: Dictionary = await _curl(t, url + "/pmc/healthz")
			var lines: PackedStringArray = str(r.out).split("\n", false)
			times.append(lines[lines.size() - 1].get_slice(" ", 1) if lines.size() > 0 else "?")
		t.note("curl total times (s) for 5 sequential requests: %s" % ", ".join(times))

	if use_host:
		t.section("websocket through the tunnel")
		var ws := WebSocketPeer.new()
		ws.outbound_buffer_size = 1 << 20
		ws.inbound_buffer_size = 1 << 20
		var wss := url.replace("https://", "wss://") + "/pmc/ws"
		var err := ws.connect_to_url(wss)
		t.eq(err, OK, "connect_to_url")
		var opened: bool = await t.wait_until(func():
			ws.poll()
			return ws.get_ready_state() != WebSocketPeer.STATE_CONNECTING, 30.0)
		t.ok(opened and ws.get_ready_state() == WebSocketPeer.STATE_OPEN, "wss open")
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var got: Array = []
			ws.send_text(JSON.stringify({"t": "pmc.hello", "sdk": 1, "name": "e2e", "code": host.join_code}))
			var welcome: bool = await t.wait_until(func(): return _read_json(ws, got, "pmc.welcome") != null, 20.0)
			t.ok(welcome, "pmc.welcome received (got %s)" % [got])
			var rtts: Array[String] = []
			for i in 5:
				var c := Time.get_ticks_msec()
				ws.send_text(JSON.stringify({"t": "pmc.ping", "c": c}))
				if await t.wait_until(func(): return _read_json(ws, got, "pmc.pong") != null, 10.0):
					rtts.append(str(Time.get_ticks_msec() - c))
			t.eq(rtts.size(), 5, "5 pongs")
			t.note("ws ping RTT through tunnel (ms): %s" % ", ".join(rtts))
			var received := [null]
			host.message_received.connect(func(_p, d) -> void: received[0] = d)
			ws.send_text(JSON.stringify({"t": "msg", "d": {"hello": "through the tunnel"}}))
			t.ok(await t.wait_until(func():
				ws.poll()
				return received[0] != null, 10.0), "game message reached the host")
			var blob := PackedByteArray()
			blob.resize(200000)
			for i in blob.size():
				blob[i] = i % 251
			received[0] = null
			ws.send(blob)
			t.ok(await t.wait_until(func():
				ws.poll()
				return received[0] != null, 20.0), "200 KB binary message reached the host")
			if received[0] is PackedByteArray:
				t.ok(received[0] == blob, "binary payload intact")
			ws.close(1000)
			await t.wait(0.3)

	t.section("stop")
	var pid := -1
	var tun: PMCTunnel = host.get_tunnel() if use_host else tunnel
	if tun != null:
		pid = tun._pid
	if use_host:
		host.stop_tunnel()
		host.stop()
	else:
		tunnel.stop()
		responder.close()
	if pid > 0:
		t.ok(await t.wait_until(func(): return not OS.is_process_running(pid), 10.0), "cloudflared killed")


func _new_global(cls: String) -> Object:
	for c in ProjectSettings.get_global_class_list():
		if c["class"] == cls:
			return load(c["path"]).new()
	return null


func _read_json(ws: WebSocketPeer, inbox: Array, type: String):
	ws.poll()
	while ws.get_available_packet_count() > 0:
		var pkt := ws.get_packet()
		if ws.was_string_packet():
			var d = JSON.parse_string(pkt.get_string_from_utf8())
			inbox.append(d)
	for i in inbox.size():
		if inbox[i] is Dictionary and inbox[i].get("t", "") == type:
			var d = inbox[i]
			inbox.remove_at(i)
			return d
	return null


# Runs curl without blocking the main loop (the host must keep serving). Returns {code, out}.
func _curl(t, target: String) -> Dictionary:
	var exe := "curl.exe" if OS.get_name() == "Windows" else "curl"
	var info := OS.execute_with_pipe(exe, ["-sS", "-m", "20", "-w", "\n%{http_code} %{time_total}", target], false)
	if info.is_empty():
		return {"code": -1, "out": "could not run curl"}
	var pid: int = info.pid
	var out := ""
	var so: FileAccess = info.stdio
	var se: FileAccess = info.stderr
	while OS.is_process_running(pid):
		out += so.get_buffer(65536).get_string_from_utf8()
		await t.frame()
	out += so.get_buffer(65536).get_string_from_utf8()
	var errs := se.get_buffer(65536).get_string_from_utf8()
	var code: int = OS.get_process_exit_code(pid)
	return {"code": code, "out": out.strip_edges() + ("" if errs == "" else " [stderr: %s]" % errs.strip_edges())}
