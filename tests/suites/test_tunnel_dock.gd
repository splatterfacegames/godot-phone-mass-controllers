extends RefCounted
## The editor dock's "Test tunnel" flow, driven outside the editor with the fake cloudflared fixture.

const TIMEOUT := 60.0
const DockScript := preload("res://addons/phone_mass_controllers/editor/dock.gd")


func run(t) -> void:
	t.section("builds")
	var dock: Control = DockScript.new()
	t.add_node(dock)
	await t.frame()
	t.eq(dock.download_button.text, "Download cloudflared")
	t.eq(dock.test_button.text, "Test tunnel")
	t.ok(dock.binary_label.text != "", "binary status shown")

	t.section("test tunnel with fake cloudflared")
	var fake := "fake_cloudflared.cmd" if OS.get_name() == "Windows" else "fake_cloudflared.sh"
	var fake_path := ProjectSettings.globalize_path("res://tests/fixtures/tunnel/" + fake)
	if OS.get_name() != "Windows":
		OS.execute("chmod", ["+x", fake_path])
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "ok")
	dock.tunnel.cloudflared_path = fake_path
	dock.tunnel.verify_dns = false
	dock.test_button.pressed.emit()
	t.ok(dock.responder.get_port() > 0, "local responder listening")
	t.ok(await t.wait_until(func(): return dock.url_edit.text != "", 15.0), "URL shown")
	t.eq(dock.url_edit.text, "https://random-words-here.trycloudflare.com")
	t.ok(dock.qr_rect.texture != null, "QR shown")
	t.eq(dock.test_button.text, "Stop")
	t.ok(not dock.copy_button.disabled, "copy enabled")

	t.section("local responder")
	var http := HTTPRequest.new()
	t.add_node(http)
	var res := [null]
	http.request_completed.connect(func(r, code, _h, body: PackedByteArray) -> void: res[0] = [r, code, body.get_string_from_utf8()])
	http.request("http://127.0.0.1:%d/pmc/healthz" % dock.responder.get_port())
	t.ok(await t.wait_until(func(): return res[0] != null, 5.0), "healthz answered")
	if res[0] != null:
		t.eq(res[0][1], 200)
		t.eq(res[0][2], "ok")

	t.section("stop")
	dock.test_button.pressed.emit()
	t.eq(dock.test_button.text, "Test tunnel")
	t.eq(dock.url_edit.text, "")
	t.ok(dock.qr_rect.texture == null, "QR cleared")
	t.eq(dock.responder.get_port(), 0, "responder closed")
	OS.set_environment("PMC_FAKE_CLOUDFLARED_MODE", "")
