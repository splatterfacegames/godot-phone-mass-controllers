extends RefCounted
## PMCTunnel against fake cloudflared scripts (tests/fixtures/tunnel) that replay real-looking logs:
## success, slow URL, no URL ever (timeout), error exit, exit after ready, missing binary, kill on free.

const TIMEOUT := 90.0
const FIXTURES := "res://tests/fixtures/tunnel"


func run(t) -> void:
	t.section("parsing and resolution")
	t.eq(PMCTunnel.parse_url("2026-09-14T09:00:01Z INF |  https://random-words-here.trycloudflare.com                   |"),
		"https://random-words-here.trycloudflare.com")
	t.eq(PMCTunnel.parse_url("ERR Failed to request quick Tunnel: Post \"https://api.trycloudflare.com/tunnel\": i/o timeout"), "",
		"the API hostname is not a tunnel URL")
	t.eq(PMCTunnel.parse_url("INF Requesting new quick Tunnel on trycloudflare.com..."), "")
	t.ok(PMCTunnel.asset_name() != "", "release asset known for %s/%s" % [OS.get_name(), Engine.get_architecture_name()])
	t.ok(PMCTunnel.install_path().ends_with(PMCTunnel.executable_name()))
	t.eq(PMCTunnel.resolve_binary("C:/definitely/not/here/cloudflared.exe"), "")
	t.eq(PMCTunnel.unsupported_reason(), "", "desktop platform supports subprocesses")
	var tmp: String = t.tmp_dir().path_join("abc.txt")
	var fa := FileAccess.open(tmp, FileAccess.WRITE)
	fa.store_string("abc")
	fa.close()
	t.eq(PMCTunnel.file_sha256(tmp), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of a file")
	t.eq(PMCTunnel.file_sha256(tmp + ".missing"), "")
	var fake := _fake_path()
	t.eq(PMCTunnel.resolve_binary(fake), fake, "explicit path resolves")
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", fake])

	t.section("missing binary without download")
	var missing := _make(t, "C:/definitely/not/here/cloudflared.exe")
	missing.node.allow_download = false
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	missing.node.start(8080)
	t.eq(missing.states, ["failed"], "fails immediately")
	t.ok(str(missing.details[0]).contains("not found"), "reason mentions not found: %s" % missing.details[0])

	t.section("ok")
	var ok := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	ok.node.start(8080)
	t.eq(ok.states, ["starting"], "starting right away")
	t.ok(ok.node.is_running(), "process running")
	var became_ready: bool = await t.wait_until(func(): return ok.node.state == "ready", 15.0)
	t.ok(became_ready, "ready (log: %s)" % [ok.node.log_lines])
	t.eq(ok.node.url, "https://random-words-here.trycloudflare.com")
	t.eq(ok.details[ok.details.size() - 1], "https://random-words-here.trycloudflare.com", "ready detail is the URL")
	var pid: int = ok.node._pid
	ok.node.stop()
	t.eq(ok.states, ["starting", "ready", "stopped"])
	t.eq(ok.node.url, "")
	t.ok(await t.wait_until(func(): return not OS.is_process_running(pid), 5.0), "process killed on stop")

	t.section("slow URL")
	var slow := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "slow")
	var t0 := Time.get_ticks_msec()
	slow.node.start(8081)
	await t.wait(1.5)
	t.eq(slow.node.state, "starting", "still starting after 1.5 s")
	t.ok(await t.wait_until(func(): return slow.node.state == "ready", 20.0), "eventually ready")
	t.ok(Time.get_ticks_msec() - t0 >= 2500, "ready only after the delayed URL (%d ms)" % (Time.get_ticks_msec() - t0))
	slow.node.stop()

	t.section("no URL -> timeout")
	var nourl := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "no_url")
	nourl.node.ready_timeout_sec = 3.0
	nourl.node.start(8082)
	await t.wait(0.5)
	var nourl_pid: int = nourl.node._pid
	t.ok(await t.wait_until(func(): return nourl.node.state == "failed", 15.0), "fails on timeout")
	var reason := str(nourl.details[nourl.details.size() - 1])
	t.ok(reason.contains("timed out"), "reason: %s" % reason)
	t.ok(reason.contains("api.trycloudflare.com"), "reason includes the last ERR line")
	t.eq(nourl.node.url, "")
	t.ok(await t.wait_until(func(): return not OS.is_process_running(nourl_pid), 5.0), "process killed after timeout")

	t.section("error exit")
	var errx := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "error_exit")
	errx.node.start(8083)
	t.ok(await t.wait_until(func(): return errx.node.state == "failed", 15.0), "fails when the process exits")
	var why := str(errx.details[errx.details.size() - 1])
	t.ok(why.contains("exited"), "reason: %s" % why)
	t.ok(why.contains("code 1"), "exit code reported")
	t.ok(why.contains("429"), "last error line reported")
	t.eq(errx.states, ["starting", "failed"])

	t.section("exit after ready")
	var late := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "exit_after_ready")
	late.node.start(8084)
	t.ok(await t.wait_until(func(): return late.node.state == "failed", 20.0), "fails when the process dies after ready")
	t.eq(late.states, ["starting", "ready", "failed"])
	t.eq(late.node.url, "", "url cleared")

	t.section("restart after failure")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	late.node.start(8085)
	t.ok(await t.wait_until(func(): return late.node.state == "ready", 15.0), "same node can start again")
	late.node.stop()

	t.section("DNS check falls back to ready after its timeout")
	var dns := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	dns.node.verify_dns = true
	dns.node.dns_timeout_sec = 2.0
	dns.node.dns_over_https_url = "http://127.0.0.1:9/dns-query"
	dns.node.start(8087)
	await t.wait_until(func(): return dns.node.log_lines.size() > 0 and dns.node.log_lines[dns.node.log_lines.size() - 1].contains("waiting for"), 15.0)
	await t.wait(1.0)
	t.eq(dns.node.state, "starting", "not ready while DNS is unconfirmed")
	t.ok(await t.wait_until(func(): return dns.node.state == "ready", 10.0), "ready after the DNS timeout")
	t.ok(" | ".join(dns.node.log_lines).contains("DNS check timed out"), "timeout logged")
	dns.node.stop()

	t.section("killed when freed")
	var freed := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	freed.node.start(8086)
	t.ok(await t.wait_until(func(): return freed.node.state == "ready", 15.0), "ready before free")
	var freed_pid: int = freed.node._pid
	freed.node.queue_free()
	await t.frame()
	await t.frame()
	t.ok(await t.wait_until(func(): return not OS.is_process_running(freed_pid), 5.0), "process killed on free")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "")


func _fake_path() -> String:
	var file := "fake_cloudflared.cmd" if OS.get_name() == "Windows" else "fake_cloudflared.sh"
	return ProjectSettings.globalize_path(FIXTURES.path_join(file))


# Returns {node, states, details}; records every state_changed emission.
func _make(t, path: String) -> Dictionary:
	var n := PMCTunnel.new()
	n.cloudflared_path = path
	n.allow_download = false
	n.verify_dns = false
	t.add_node(n)
	var rec := {"node": n, "states": [], "details": []}
	n.state_changed.connect(func(s: String, d: String) -> void:
		rec.states.append(s)
		rec.details.append(d))
	return rec
