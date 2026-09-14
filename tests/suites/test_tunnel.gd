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
	errx.node.max_retries = 0
	errx.node.start(8083)
	t.ok(await t.wait_until(func(): return errx.node.state == "failed", 15.0), "fails when the process exits")
	var why := str(errx.details[errx.details.size() - 1])
	t.ok(why.contains("exited"), "reason: %s" % why)
	t.ok(why.contains("code 1"), "exit code reported")
	t.ok(why.contains("429"), "last error line reported")
	t.eq(errx.states, ["starting", "failed"], "details: %s" % [errx.details])

	t.section("exit after ready")
	var late := _make(t, fake)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "exit_after_ready")
	late.node.start(8084)
	t.ok(await t.wait_until(func(): return late.node.state == "lost", 20.0), "lost when the process dies after ready")
	t.eq(late.states, ["starting", "ready", "lost"])
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

	t.section("429 rate limit: retry then ready")
	var marker := ProjectSettings.globalize_path(t.tmp_dir().path_join("fake_once.marker"))
	OS.set_environment("PMC_FAKE_STATE_FILE", marker)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "error_429_once")
	var r := _make(t, fake)
	r.node.retry_backoff_sec = 0.3
	r.node.start(8090)
	t.ok(await t.wait_until(func(): return r.node.state == "ready", 20.0), "ready after one retry")
	t.ok(r.states.count("starting") >= 2, "relaunched (states: %s)" % [r.states])
	t.ok(r.details.any(func(d): return String(d).contains("retry 1/")), "retry announced")
	r.node.stop()

	t.section("retries exhausted")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "error_exit")
	var r2 := _make(t, fake)
	r2.node.max_retries = 1
	r2.node.retry_backoff_sec = 0.2
	r2.node.start(8091)
	t.ok(await t.wait_until(func(): return r2.node.state == "failed", 20.0), "failed once retries ran out")
	t.ok(str(r2.details[r2.details.size() - 1]).contains("1015"), "last 429 reason kept")

	t.section("QUIC blocked -> HTTP/2 fallback")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "quic_fail")
	var fb := _make(t, fake)
	fb.node.protocol_fallback_sec = 2.0
	fb.node.start(8092)
	t.ok(await t.wait_until(func(): return fb.node.state == "ready", 20.0), "ready after the http2 fallback")
	t.ok(" | ".join(fb.node.log_lines).contains("HTTP/2"), "fallback logged")
	t.eq(fb.node.url, "https://random-words-here.trycloudflare.com", "second launch's URL")
	fb.node.stop()

	t.section("extra_args protocol skips fallback")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "quic_fail")
	var forced := _make(t, fake)
	forced.node.extra_args = PackedStringArray(["--protocol", "http2"])
	forced.node.start(8093)
	t.ok(await t.wait_until(func(): return forced.node.state == "ready", 15.0), "ready with forced http2, no fallback needed")
	forced.node.stop()

	t.section("edge connections unregistered -> lost")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "unregister")
	var un := _make(t, fake)
	un.node.lost_grace_sec = 0.5
	un.node.start(8094)
	t.ok(await t.wait_until(func(): return un.node.state == "ready", 15.0), "ready")
	t.ok(await t.wait_until(func(): return un.node.state == "lost", 15.0), "lost after the grace period")
	t.ok(un.node.is_running(), "process still alive while lost")
	t.eq(un.node.url, "https://random-words-here.trycloudflare.com", "url kept while alive")
	un.node.stop()

	t.section("re-registration returns to ready")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "unregister_recover")
	var rec := _make(t, fake)
	rec.node.lost_grace_sec = 0.5
	rec.node.start(8095)
	t.ok(await t.wait_until(func(): return rec.node.state == "ready", 15.0), "ready")
	t.ok(await t.wait_until(func(): return rec.node.state == "lost", 15.0), "lost")
	t.ok(await t.wait_until(func(): return rec.node.state == "ready" and rec.states.count("ready") >= 2, 20.0), "recovered to ready")
	rec.node.stop()

	t.section("named tunnel (token)")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "named_ok")
	var named := _make(t, fake)
	named.node.mode = "named"
	named.node.named_token = "TESTTOKEN"
	named.node.named_hostname = "party.example.com"
	named.node.start(8096)
	t.ok(await t.wait_until(func(): return named.node.state == "ready", 15.0), "named ready")
	t.eq(named.node.url, "https://party.example.com", "stable hostname is the URL")
	named.node.stop()

	t.section("named tunnel (name + credentials file)")
	var cred: String = t.tmp_dir().path_join("creds.json")
	var cf := FileAccess.open(cred, FileAccess.WRITE)
	cf.store_string('{"AccountTag":"a","TunnelSecret":"b","TunnelID":"c"}')
	cf.close()
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "named_local")
	var nl := _make(t, fake)
	nl.node.mode = "named"
	nl.node.named_tunnel = "mytunnel"
	nl.node.named_credentials_file = cred
	nl.node.named_hostname = "party.example.com"
	nl.node.start(8097)
	t.ok(await t.wait_until(func(): return nl.node.state == "ready", 15.0), "named ready")
	var ncfg := FileAccess.get_file_as_string(ProjectSettings.globalize_path(PMCTunnel.NAMED_CONFIG))
	t.ok(ncfg.contains("tunnel: mytunnel"), "generated config names the tunnel")
	t.ok(ncfg.contains("hostname: party.example.com"), "generated config routes the hostname")
	t.ok(ncfg.contains("service: http://127.0.0.1:8097"), "generated config targets the port")
	nl.node.stop()

	t.section("named mode validation")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	var bad := _make(t, fake)
	bad.node.mode = "named"
	bad.node.start(8098)
	t.eq(bad.states, ["failed"], "missing named settings -> failed fast")
	t.ok(str(bad.details[0]).contains("named_hostname"), "reason names the missing field")

	t.section("default config.yml isolation")
	var cdir := ProjectSettings.globalize_path(t.tmp_dir().path_join("fakehome"))
	DirAccess.make_dir_recursive_absolute(cdir)
	var cfile := FileAccess.open(cdir.path_join("config.yml"), FileAccess.WRITE)
	cfile.store_string("tunnel: bogus\n")
	cfile.close()
	t.eq(PMCTunnel.find_default_config(PackedStringArray([cdir])), cdir.path_join("config.yml"), "config detected")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "needs_config")
	var iso := _make(t, fake)
	iso.node.config_dirs = PackedStringArray([cdir])
	iso.node.start(8099)
	t.ok(await t.wait_until(func(): return iso.node.state == "ready", 15.0), "ready with an isolated --config")
	t.ok(" | ".join(iso.node.log_lines).contains("default cloudflared config exists"), "warning logged")
	iso.node.stop()

	t.section("binary version + verification")
	t.eq(PMCTunnel.binary_version(fake), "2025.8.1", "fake --version parses")
	t.ok(PMCTunnel.version_at_least("2025.8.1", "2022.6.2"))
	t.ok(not PMCTunnel.version_at_least("2022.6.2", "2025.8.1"))
	t.ok(PMCTunnel.version_at_least("2025.8", "2025.8.0"), "missing patch counts as 0")
	t.eq(PMCTunnel.verify_binary(fake, "2022.6.2"), "", "fake passes the minimum")
	t.ok(PMCTunnel.verify_binary(fake, "2999.1.1") != "", "too-old binary rejected")
	t.ok(PMCTunnel.verify_binary(fake + ".missing") != "", "unrunnable binary rejected")

	t.section("pid file")
	var pid_file := ProjectSettings.globalize_path(PMCTunnel.PID_FILE)
	DirAccess.remove_absolute(pid_file)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	var pf := _make(t, fake)
	pf.node.start(8100)
	t.ok(await t.wait_until(func(): return pf.node.state == "ready", 15.0), "ready")
	t.ok(FileAccess.file_exists(pid_file), "pid file written")
	var prec = JSON.parse_string(FileAccess.get_file_as_string(pid_file))
	t.eq(int(prec.get("pid", -1)) if prec is Dictionary else -1, pf.node._pid, "records the child pid")
	pf.node.stop()
	t.ok(not FileAccess.file_exists(pid_file), "pid file removed on stop")

	t.section("stale pid reaping")
	var spawned := OS.execute_with_pipe(fake, ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:9"], false)
	var old_pid := int(spawned.get("pid", -1))
	t.ok(old_pid > 0, "leftover fake spawned")
	DirAccess.make_dir_recursive_absolute(pid_file.get_base_dir())
	var f := FileAccess.open(pid_file, FileAccess.WRITE)
	f.store_string(JSON.stringify({"pid": old_pid, "exe": fake, "port": 9}))
	f.close()
	var reaper := _make(t, fake)
	reaper.node.start(8101)
	t.ok(await t.wait_until(func(): return reaper.node.state == "ready", 15.0), "new tunnel ready")
	t.ok(await t.wait_until(func(): return not OS.is_process_running(old_pid), 8.0), "leftover cloudflared killed")
	t.ok(" | ".join(reaper.node.log_lines).contains("leftover cloudflared"), "kill logged")
	var f2 := FileAccess.open(pid_file, FileAccess.WRITE)
	f2.store_string(JSON.stringify({"pid": OS.get_process_id(), "exe": fake}))
	f2.close()
	var reaper2 := _make(t, fake)
	reaper2.node.start(8102)
	t.ok(await t.wait_until(func(): return reaper2.node.state == "ready", 15.0), "ready")
	# OS.is_process_running only accepts child pids on Unix; our own pid needs kill -0 there.
	var self_alive: bool = OS.is_process_running(OS.get_process_id()) if OS.get_name() == "Windows" \
		else OS.execute("sh", ["-c", "kill -0 %d" % OS.get_process_id()], [], true) == 0
	t.ok(self_alive, "own process untouched")
	t.ok(" | ".join(reaper2.node.log_lines).contains("left alone"), "recycled-pid guard logged")
	reaper.node.stop()
	reaper2.node.stop()
	OS.set_environment("PMC_FAKE_STATE_FILE", "")

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
