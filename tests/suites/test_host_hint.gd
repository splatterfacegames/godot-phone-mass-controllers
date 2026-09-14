extends RefCounted
## no_joins_hint: fires once when the join URL sits unjoined; silenced by a join; re-arms on URL change.

func run(t) -> void:
	t.section("hint fires with zero joins")
	var host := PMCHost.new()
	host.port = 0
	host.controller_dir = ""
	host.heartbeat_seconds = 0.0
	host.no_joins_hint_seconds = 0.3
	t.add_node(host)
	var hints := [0]
	host.no_joins_hint.connect(func(): hints[0] += 1)
	t.eq(host.start(), OK, "start")
	t.ok(await t.wait_until(func() -> bool: return hints[0] == 1, 3.0), "hint fired after the deadline")
	await t.wait(0.4)
	t.eq(hints[0], 1, "hint fires only once")
	host.stop()

	t.section("a join silences the hint; URL change re-arms")
	var h2 := PMCHost.new()
	h2.port = 0
	h2.controller_dir = ""
	h2.heartbeat_seconds = 0.0
	h2.no_joins_hint_seconds = 0.4
	t.add_node(h2)
	var hints2 := [0]
	h2.no_joins_hint.connect(func(): hints2[0] += 1)
	t.eq(h2.start(), OK, "start")
	var ws := PMCTestWs.new(t)
	await ws.open(h2.get_port())
	await ws.hello()
	await ws.wait_json("pmc.welcome")
	await t.wait(0.8)
	t.eq(hints2[0], 0, "no hint when a phone joined")
	h2.advertise_url = "http://192.0.2.1:9000/"
	t.ok(await t.wait_until(func() -> bool: return hints2[0] == 1, 3.0), "re-armed hint fires when no new joins follow")
	h2.stop()

	t.section("off by default")
	var h3 := PMCHost.new()
	h3.port = 0
	h3.controller_dir = ""
	h3.heartbeat_seconds = 0.0
	t.add_node(h3)
	var hints3 := [0]
	h3.no_joins_hint.connect(func(): hints3[0] += 1)
	t.eq(h3.start(), OK, "start")
	await t.wait(0.5)
	t.eq(hints3[0], 0, "no hint with the default 0")
	h3.stop()
