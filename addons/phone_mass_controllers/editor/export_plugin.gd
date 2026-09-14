@tool
extends EditorExportPlugin
## Packs PMCHost-served res:// directories verbatim into every export.
##
## The exporter drops files it doesn't import (html/js/css) and replaces imported ones (png/ogg)
## with .ctex remaps — either way FileAccess can't serve the originals in the exported game.
## export_scan.gd decides which directories matter; this shell only feeds them to add_file().
## Registered from plugin.gd via add_export_plugin().

const Scan := preload("res://addons/phone_mass_controllers/editor/export_scan.gd")


func _get_name() -> String:
	return "Phone Mass Controllers"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var found := Scan.collect_dirs(Scan.project_files(["tscn", "scn"]), Scan.project_files(["gd"]))
	for w in found.warnings:
		push_warning("Phone Mass Controllers export: " + w)
	var dirs: Dictionary = found.dirs
	var packed := 0
	var seen := {}
	for dir in dirs:
		for res_path in Scan.collect_files(dir):
			if seen.has(res_path):
				continue
			seen[res_path] = true
			var bytes := FileAccess.get_file_as_bytes(res_path)
			if FileAccess.get_open_error() != OK:
				push_warning("Phone Mass Controllers export: couldn't read %s" % res_path)
				continue
			add_file(res_path, bytes, false)
			packed += 1
	var origin := PackedStringArray()
	for dir in dirs:
		origin.append("%s (%s)" % [dir, dirs[dir]])
	print("Phone Mass Controllers: packed %d controller file(s) from %s" % [packed, "; ".join(origin)])
