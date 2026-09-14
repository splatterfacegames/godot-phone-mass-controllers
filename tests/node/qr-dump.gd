extends SceneTree
## Dumps QR matrices for a verification corpus so tests/node/qr-verify.mjs can decode them
## with independent implementations (jsQR, and module-by-module against the `qrcode` npm package).
##
## Usage: godot --headless --path <repo> --script tests/node/qr-dump.gd -- <out_dir>

const LEVELS := ["L", "M", "Q", "H"]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var out_dir: String = args[0] if args.size() > 0 else ProjectSettings.globalize_path("res://tests/node/out/qr")
	DirAccess.make_dir_recursive_absolute(out_dir)

	var entries: Array = []
	var fixed := [
		"http://192.168.1.87:8086/?code=ABCD",
		"https://random-words-here.trycloudflare.com/?code=WXYZ",
		"http://10.0.0.2:8080/",
		"https://example.com",
		"https://example.com/a/very/long/path/that/keeps/going/and/going?with=query&params=true&and=more#fragment-too",
		"A",
		"",
		"HELLO WORLD",
		"HTTP://192.168.1.87:8086/",
		"0123456789",
		"31415926535897932384626433832795028841971693993751058209749445923",
		"Grüße aus Köln — ünïcödé ✓",
		"日本語のテキストとQRコード",
		"emoji 🎮🕹️📱 party",
		"line1\nline2\ttab",
	]
	var t0 := Time.get_ticks_usec()
	for text in fixed:
		for ecc in 4:
			_add(entries, "fixed", text, PMCQr.encode(text, ecc))
	# Every version 1..40 at every level, filled close to capacity with byte / alphanumeric / numeric data.
	for v in range(1, 41):
		for ecc in 4:
			var byte_text := _fill_bytes(v, ecc)
			_add(entries, "v%d-%s-byte" % [v, LEVELS[ecc]], byte_text, PMCQr.encode_advanced(byte_text, ecc, v, v))
			if v <= 20 or v % 5 == 0:
				var alnum := _fill_mode(v, ecc, "alphanumeric", "HTTP://PMC.EXAMPLE/$%*+-./: 0123456789")
				_add(entries, "v%d-%s-alnum" % [v, LEVELS[ecc]], alnum, PMCQr.encode_advanced(alnum, ecc, v, v, -1, "alphanumeric"))
				var num := _fill_mode(v, ecc, "numeric", "8675309")
				_add(entries, "v%d-%s-num" % [v, LEVELS[ecc]], num, PMCQr.encode_advanced(num, ecc, v, v, -1, "numeric"))
	# Every forced mask.
	for msk in 8:
		var url := "http://192.168.1.87:8086/?code=ABCD"
		_add(entries, "mask%d" % msk, url, PMCQr.encode_advanced(url, 1, 1, 40, msk))
	var encode_ms := (Time.get_ticks_usec() - t0) / 1000.0

	# Timing for a typical URL.
	var iters := 50
	var t1 := Time.get_ticks_usec()
	for i in iters:
		PMCQr.encode("http://192.168.1.87:8086/?code=ABCD", 1)
	var typical_ms := (Time.get_ticks_usec() - t1) / 1000.0 / iters
	var t2 := Time.get_ticks_usec()
	for i in iters:
		PMCQr.encode("https://random-words-here.trycloudflare.com/?code=WXYZ", 1)
	var tunnel_ms := (Time.get_ticks_usec() - t2) / 1000.0 / iters

	# PNG renders for a handful of entries (checks to_image end to end).
	var pngs := 0
	for i in entries.size():
		var e: Dictionary = entries[i]
		if e.name == "fixed" or e.name.begins_with("v10-") or e.name.begins_with("v20-") or e.name.begins_with("v40-M"):
			var m := PMCQr.encode_advanced(e.text, e.ecc, e.version, e.version, e.mask, e.mode)
			var img := PMCQr.to_image(m, 4, 4)
			var file := "%s/%04d.png" % [out_dir, i]
			img.save_png(file)
			e["png"] = "%04d.png" % i
			e["png_module_px"] = 4
			pngs += 1

	var f := FileAccess.open(out_dir + "/corpus.json", FileAccess.WRITE)
	f.store_string(JSON.stringify({
		"entries": entries,
		"encode_total_ms": encode_ms,
		"typical_url_ms": typical_ms,
		"tunnel_url_ms": tunnel_ms,
	}))
	f.close()
	print("qr-dump: %d entries (%d png) -> %s; typical URL encode %.2f ms, tunnel URL %.2f ms" % [entries.size(), pngs, out_dir, typical_ms, tunnel_ms])
	quit(0)


func _add(entries: Array, name: String, text: String, m: PMCQrMatrix) -> void:
	if m == null:
		push_error("qr-dump: failed to encode %s" % name)
		quit(1)
		return
	entries.append({
		"name": name, "text": text, "ecc": m.ecc, "level": LEVELS[m.ecc], "version": m.version,
		"mask": m.mask, "mode": m.mode, "size": m.size, "rows": m.to_rows(),
	})


# Deterministic mixed ASCII/UTF-8 text sized to the byte capacity of version v (but too big for v-1 where possible).
func _fill_bytes(v: int, ecc: int) -> String:
	var cap := _byte_capacity(v, ecc)
	var rng := RandomNumberGenerator.new()
	rng.seed = v * 7 + ecc
	var s := ""
	var pieces := ["https://", "example", ".com/", "?q=", "é", "ü", "漢", "-", "_", "0", "Z", "~", "%20"]
	while s.to_utf8_buffer().size() < cap:
		var p: String = pieces[rng.randi() % pieces.size()]
		if (s + p).to_utf8_buffer().size() > cap:
			s += "x"
		else:
			s += p
	return s


func _fill_mode(v: int, ecc: int, mode: String, alphabet: String) -> String:
	var n := _max_count(v, ecc, mode)
	var s := ""
	for i in n:
		s += alphabet[i % alphabet.length()]
	return s


func _byte_capacity(v: int, ecc: int) -> int:
	return _max_count(v, ecc, "byte")


# Largest character count of the given mode that fits in version v (uses encoder internals).
func _max_count(v: int, ecc: int, mode: String) -> int:
	var cap_bits := PMCQr._num_data_codewords(v, ecc) * 8
	var n := 0
	while 4 + PMCQr._char_count_bits(mode, v) + PMCQr._payload_bits(mode, n + 1) <= cap_bits:
		n += 1
	return n
