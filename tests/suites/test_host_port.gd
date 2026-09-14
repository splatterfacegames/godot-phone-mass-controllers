extends RefCounted
## Port search must skip ports owned by another process on IPv4 only (dual-stack "*" bind would shadow them).

func run(t) -> void:
	t.section("ipv4-only occupant is skipped")
	var base := 20000 + randi() % 20000
	var blocker := TCPServer.new()
	if blocker.listen(base, "0.0.0.0") != OK:
		t.skip("couldn't occupy test port %d" % base)
		return
	var host := PMCHost.new()
	host.bind_address = "*"
	host.port = base
	host.port_search = 5
	host.auto_poll = false
	t.add_node(host)
	t.eq(host.start(), OK, "start")
	t.ok(host.get_port() != base, "skipped the occupied port (got %d)" % host.get_port())
	t.ok(host.get_port() > base and host.get_port() <= base + 5, "picked a port in range")
	host.stop()
	blocker.stop()

	t.section("free port is used as-is")
	var host2 := PMCHost.new()
	host2.port = base
	host2.auto_poll = false
	t.add_node(host2)
	t.eq(host2.start(), OK, "start")
	t.eq(host2.get_port(), base, "same port once free")
	host2.stop()
