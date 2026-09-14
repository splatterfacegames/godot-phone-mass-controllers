extends SceneTree
## Headless echo host for the Node interop and load tests.
##
## godot --headless --path . --script res://tests/lib/pmc_test_server.gd -- [--port=0] [--fps=60] [--heartbeat=15]
##     [--grace=30] [--code=] [--max-message=1048576]
## Prints "PMC_READY port=<n>" when listening. Behaviour:
## - binary frames are echoed back
## - msg frames are echoed as {"echo": d}, except commands in d.cmd:
##   "stats" -> {"stats": {...}}  (poll/frame timing percentiles since the last reset, plus host counters)
##   "reset_stats" -> {"reset": true}
##   "broadcast_hz" (d.hz, d.bytes) -> starts/stops a periodic broadcast of a d.bytes-sized JSON state
##   "quit" -> exits

var host: PMCHost
var poll_samples := PackedInt32Array()
var frame_samples := PackedInt32Array()
var last_frame_usec := 0
var broadcast_hz := 0.0
var broadcast_bytes := 100
var broadcast_accum := 0.0
var broadcast_seq := 0


func _initialize() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			args[kv[0]] = kv[1]
	Engine.max_fps = int(args.get("fps", "60"))
	host = PMCHost.new()
	host.port = int(args.get("port", "0"))
	host.controller_dir = ""
	host.auto_poll = false
	host.heartbeat_seconds = float(args.get("heartbeat", "15"))
	host.grace_seconds = float(args.get("grace", "30"))
	host.join_code = args.get("code", "")
	host.max_message_bytes = int(args.get("max-message", str(1 << 20)))
	host.max_connections = 1024
	host.io_budget_msec = float(args.get("budget", "8"))
	host.max_connections_per_address = int(args.get("per-address", "0"))
	root.add_child(host)
	host.message_received.connect(_on_message)
	var err := host.start()
	if err != OK:
		printerr("PMC_FAILED %s" % error_string(err))
		quit(1)
		return
	print("PMC_READY port=%d" % host.get_port())


func _process(delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if last_frame_usec > 0 and frame_samples.size() < 2000000:
		frame_samples.append(now - last_frame_usec)
	last_frame_usec = now
	var t0 := Time.get_ticks_usec()
	host.poll()
	if broadcast_hz > 0.0:
		broadcast_accum += delta
		var step := 1.0 / broadcast_hz
		if broadcast_accum >= step:
			broadcast_accum = fmod(broadcast_accum, step)
			broadcast_seq += 1
			host.broadcast({"state": broadcast_seq, "pad": "x".repeat(maxi(0, broadcast_bytes - 40))})
	if poll_samples.size() < 2000000:
		poll_samples.append(Time.get_ticks_usec() - t0)
	return false


func _on_message(p: PMCPlayer, d) -> void:
	if d is PackedByteArray:
		host.send(p, d)
		return
	if d is Dictionary and d.has("cmd"):
		match String(d.cmd):
			"stats":
				host.send(p, {"stats": _stats()})
			"reset_stats":
				poll_samples.clear()
				frame_samples.clear()
				host.reset_poll_stats()
				host.send(p, {"reset": true})
			"broadcast_hz":
				broadcast_hz = float(d.get("hz", 0))
				broadcast_bytes = int(d.get("bytes", 100))
				host.send(p, {"broadcast_hz": broadcast_hz})
			"quit":
				quit(0)
		return
	host.send(p, {"echo": d})


func _pct(samples: PackedInt32Array) -> Dictionary:
	if samples.is_empty():
		return {"n": 0}
	var s := samples.duplicate()
	s.sort()
	var total := 0
	for v in s:
		total += v
	var n := s.size()
	return {
		"n": n, "avg_ms": total / float(n) / 1000.0,
		"p50_ms": s[n / 2] / 1000.0, "p95_ms": s[mini(n - 1, int(n * 0.95))] / 1000.0,
		"p99_ms": s[mini(n - 1, int(n * 0.99))] / 1000.0, "max_ms": s[n - 1] / 1000.0,
	}


func _stats() -> Dictionary:
	return {"poll": _pct(poll_samples), "frame": _pct(frame_samples), "host": host.get_stats()}
