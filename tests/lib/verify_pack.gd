extends SceneTree
## Scratch verifier: load a pck produced by --export-pack and check raw files are readable
## with FileAccess (what PMCHost's static serving uses). Usage:
##   godot --headless --path . --script res://tests/lib/verify_pack.gd -- /tmp/pmc_test.pck

func _initialize() -> void:
	var pck := ""
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			pck = a
	if pck == "":
		print("usage: --script verify_pack.gd -- <pack.pck>")
		quit(1)
		return
	if not ProjectSettings.load_resource_pack(pck):
		print("FAIL could not load ", pck)
		quit(1)
		return
	var fails := 0
	for path in [
		"res://addons/phone_mass_controllers/web/pmc.js",
		"res://demo/controller/index.html",
		"res://demo/controller/controller.js",
		"res://tests/fixtures/export/gd_extra/logo.png",
		"res://tests/fixtures/export/scene_controller/logo.png",
	]:
		if not FileAccess.file_exists(path):
			print("FAIL missing in pack: ", path)
			fails += 1
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		var bytes := f.get_buffer(mini(f.get_length(), 16))
		f.close()
		print("ok ", path, "  head=", bytes.hex_encode())
	# raw png magic proves the original was packed, not just the imported .ctex
	var f := FileAccess.open("res://tests/fixtures/export/gd_extra/logo.png", FileAccess.READ)
	var magic := f.get_buffer(8)
	f.close()
	var png := PackedByteArray([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
	if magic != png:
		print("FAIL logo.png is not raw png bytes: ", magic.hex_encode())
		fails += 1
	else:
		print("ok raw png magic verified")
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)
