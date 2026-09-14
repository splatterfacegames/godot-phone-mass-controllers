extends RefCounted
## PMCHost <-> PMCTunnel against the fake cloudflared fixture: tunnel_* export wiring, caller join
## codes, pmc.moved on a rolling restart, keep-alive across stop()->start(), detached adoption after
## a scene reload, and bounded auto-restart after a lost tunnel.

const TIMEOUT := 150.0
const FIXTURES := "res://tests/fixtures/tunnel"


func run(t) -> void:
	var fake := _fake_path()
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", fake])

	t.section("tunnel exports applied before the process starts")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "quic_fail")  # stalls unless --protocol http2 arrives
	var h := _new_host(t, fake)
	h.port = 18350
	h.tunnel_extra_args = PackedStringArray(["--protocol", "http2"])
	t.eq(h.start(), OK)
	h.start_tunnel()
	var tun = h.get_tunnel()
	t.ok(tun != null, "tunnel created")
	t.ok(await t.wait_until(func(): return tun.state == "ready", 20.0), "ready (extra_args forced http2)")
	t.eq(tun.verify_dns, false, "verify_dns forwarded")
	t.eq(tun.allow_download, false, "allow_download forwarded")
	t.eq(tun.ready_timeout_sec, h.tunnel_ready_timeout_sec, "ready timeout forwarded")
	t.eq(tun.extra_args, h.tunnel_extra_args, "extra_args forwarded")
	t.eq(tun.mode, "quick", "mode forwarded")
	t.ok(h.join_url().begins_with("https://random-words-here.trycloudflare.com"), "join URL uses the tunnel")
	t.eq(h.join_code.length(), 4, "join code generated")
	var first_url := h.join_url()
	t.ok(first_url.contains("code=" + h.join_code))
	h.stop_tunnel()
	t.eq(h.join_code, "", "generated code cleared on stop")
	t.ok(not h.join_url().contains("trycloudflare.com"), "join URL back to LAN")

	t.section("caller-supplied join code")
	h.start_tunnel("WXYZ")
	t.ok(await t.wait_until(func(): return h.get_tunnel() != null and String(h.get_tunnel().state) == "ready", 20.0), "ready")
	t.eq(h.join_code, "WXYZ", "param code used")
	t.ok(h.join_url().contains("code=WXYZ"))
	h.stop_tunnel()
	t.eq(h.join_code, "WXYZ", "caller code kept after stop")
	h.tunnel_join_code = "QWER"
	h.start_tunnel()
	t.ok(await t.wait_until(func(): return h.get_tunnel() != null and String(h.get_tunnel().state) == "ready", 20.0), "ready")
	t.eq(h.join_code, "QWER", "export code used")
	h.stop_tunnel()
	t.eq(h.join_code, "QWER", "export code kept after stop")
	h.tunnel_join_code = ""

	t.section("start_tunnel on a healthy tunnel is a no-op")
	h.start_tunnel()
	t.ok(await t.wait_until(func(): return h.get_tunnel() != null and String(h.get_tunnel().state) == "ready", 20.0), "ready")
	var kept = h.get_tunnel()
	var kept_pid: int = kept._pid
	h.start_tunnel()
	t.eq(h.get_tunnel(), kept, "same tunnel kept")
	t.eq(kept._pid, kept_pid, "same process kept")
	h.stop_tunnel()

	t.section("pmc.moved on a rolling restart")
	var marker := ProjectSettings.globalize_path(t.tmp_dir().path_join("rotating.marker"))
	OS.set_environment("PMC_FAKE_STATE_FILE", marker)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "rotating_url")
	var h2 := _new_host(t, fake)
	h2.port = 18352
	t.eq(h2.start(), OK)
	h2.start_tunnel()
	t.ok(await t.wait_until(func(): return h2.get_tunnel() != null and String(h2.get_tunnel().state) == "ready", 20.0), "first tunnel ready")
	t.ok(h2.join_url().contains("first-words-here"), "first URL advertised: %s" % h2.join_url())
	var ws := PMCTestWs.new(t)
	t.ok(await ws.open(h2.get_port()), "ws open")
	await ws.hello({"code": h2.join_code})
	var welcome := await ws.wait_json("pmc.welcome", 5.0)
	t.ok(not welcome.is_empty(), "player joined")
	var old_pid: int = h2.get_tunnel()._pid
	var joins: Array = []
	h2.join_url_changed.connect(func(u): joins.append(u))
	h2.restart_tunnel()
	var moved := await ws.wait_json("pmc.moved", 25.0)
	t.ok(not moved.is_empty(), "pmc.moved received before the old tunnel died")
	if not moved.is_empty():
		t.eq(str(moved.get("d", {}).get("url", "")), h2.join_url(), "moved carries the new join URL")
		t.ok(str(moved["d"]["url"]).contains("second-words-here"), "new URL inside")
	t.ok(h2.join_url().contains("second-words-here"), "join URL now points at the new tunnel: %s" % h2.join_url())
	t.ok(await t.wait_until(func(): return not OS.is_process_running(old_pid), 8.0), "old cloudflared stopped after the swap")
	t.ok(await t.wait_until(func(): return h2.get_tunnel() != null and String(h2.get_tunnel().state) == "ready", 10.0), "new tunnel ready")
	ws.close()
	h2.stop()

	t.section("tunnel survives stop -> start on the same port")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	var h3 := _new_host(t, fake)
	h3.port = 18354
	t.eq(h3.start(), OK)
	h3.start_tunnel()
	t.ok(await t.wait_until(func(): return h3.get_tunnel() != null and String(h3.get_tunnel().state) == "ready", 20.0), "ready")
	var tun3 = h3.get_tunnel()
	var pid3: int = tun3._pid
	var url3 := h3.join_url()
	h3.stop()
	t.ok(OS.is_process_running(pid3), "cloudflared still up after host.stop()")
	h3.start()
	t.eq(h3.get_tunnel(), tun3, "same tunnel reused")
	t.eq(tun3._pid, pid3, "same process")
	t.eq(h3.join_url(), url3, "join URL unchanged")

	t.section("a kept tunnel is retargeted when the port changes")
	var marker2 := ProjectSettings.globalize_path(t.tmp_dir().path_join("rotating2.marker"))
	OS.set_environment("PMC_FAKE_STATE_FILE", marker2)
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "rotating_url")
	h3.stop()
	h3.port = 18356
	t.eq(h3.start(), OK)
	t.ok(await t.wait_until(func(): return String(tun3.state) == "ready" and int(tun3._port) == 18356, 20.0), "tunnel relaunched on the new port")
	t.ok(h3.join_url().contains("first-words-here"), "new URL advertised: %s" % h3.join_url())
	h3.stop()
	h3.stop_tunnel()
	h3.port = 0

	t.section("detached tunnel adoption after a scene reload")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	var h4 := _new_host(t, fake)
	h4.port = 18358
	t.eq(h4.start(), OK)
	h4.start_tunnel()
	t.ok(await t.wait_until(func(): return h4.get_tunnel() != null and String(h4.get_tunnel().state) == "ready", 20.0), "ready")
	var tun4 = h4.get_tunnel()
	var pid4: int = tun4._pid
	var port4 := h4.get_port()
	h4.queue_free()
	await t.frame()
	await t.frame()
	t.ok(OS.is_process_running(pid4), "tunnel outlived the freed host")
	t.ok(tun4.detached, "marked detached")
	t.ok(tun4.get_parent() == t.root, "reparented to the root")
	var h5 := _new_host(t, fake)
	h5.port = port4
	h5.start_tunnel()
	t.ok(await t.wait_until(func(): return h5.get_tunnel() == tun4, 5.0), "adopted by the new host")
	t.ok(not tun4.detached, "adopted tunnel cleared")
	t.ok(h5.join_url().begins_with("https://random-words-here.trycloudflare.com"), "same URL kept")
	t.eq(tun4._pid, pid4, "same process kept")
	h5.stop_tunnel()
	h5.stop()

	t.section("auto-restart after the tunnel is lost")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "exit_after_ready")
	var h6 := _new_host(t, fake)
	h6.port = 18362
	h6.tunnel_restart_delay_sec = 0.2
	var states6: Array = []
	h6.tunnel_state_changed.connect(func(s, d): states6.append([s, d]))
	t.eq(h6.start(), OK)
	h6.start_tunnel()
	t.ok(await t.wait_until(func(): return h6.get_tunnel() != null and String(h6.get_tunnel().state) == "ready", 20.0), "ready")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")  # the replacement stays up
	t.ok(await t.wait_until(func(): return states6.any(func(s): return s[0] == "lost"), 15.0), "lost reported")
	t.ok(await t.wait_until(func(): return states6.size() > 0 and states6[states6.size() - 1][0] == "ready", 20.0), "auto-restart reached ready")
	t.eq(h6.advertise_url, "https://random-words-here.trycloudflare.com", "new tunnel advertised")
	h6.stop_tunnel()
	h6.stop()
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "")
	OS.set_environment("PMC_FAKE_STATE_FILE", "")


func _new_host(t, fake: String) -> PMCHost:
	var h := PMCHost.new()
	h.port = 0
	h.cloudflared_path = fake
	h.tunnel_allow_download = false
	h.tunnel_verify_dns = false
	h.tunnel_ready_timeout_sec = 20.0
	t.add_node(h)
	return h


func _fake_path() -> String:
	var file := "fake_cloudflared.cmd" if OS.get_name() == "Windows" else "fake_cloudflared.sh"
	return ProjectSettings.globalize_path(FIXTURES.path_join(file))
