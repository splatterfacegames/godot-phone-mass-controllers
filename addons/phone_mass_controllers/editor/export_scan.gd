extends RefCounted
## Collects the res:// directories an export must ship as raw files for PMCHost's file serving.
##
## Godot's exporter drops files it doesn't recognize (html/js/css) and replaces imported types
## (png/ogg/...) with .ctex remaps, so FileAccess can't read the originals in an exported game.
## The editor export plugin re-adds every file under these directories verbatim with add_file().
##
## Pure logic, no editor API: unit-tested from tests/suites/test_export_scan.gd.

## PMCHost's own script; scene nodes carrying it (or a subclass) contribute their controller_dir.
const HOST_SCRIPT := "res://addons/phone_mass_controllers/host.gd"
## The JS SDK served at /pmc/. Without it every controller page 404s its client code in an export.
const WEB_DIR := "res://addons/phone_mass_controllers/web"
## PMCHost.controller_dir's default value.
const DEFAULT_CONTROLLER_DIR := "res://controller"
## Never packed: import metadata and editor cache files, not servable content.
const SKIP_EXTENSIONS := ["import", "uid", "remap", "gdc", "translation", "ctex"]
## Safety cap so a pathological scan can't blow up the pck.
const MAX_FILES := 4096


## Every file under res:// with one of [param extensions] (e.g. ["tscn"], ["gd"]).
## Hidden dirs and res://.godot are skipped.
static func project_files(extensions: Array) -> PackedStringArray:
	var out: PackedStringArray = []
	_project_files("res://", extensions, out)
	return out


static func _project_files(dir: String, extensions: Array, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension().to_lower() in extensions:
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		_project_files(dir.path_join(sub), extensions, out)


## Directories to pack, as {"dirs": {dir: why}, "warnings": [...]}. [param scenes]/[param scripts]
## come from [method project_files] so tests can pass fixture lists. Entries that can't help
## (missing dirs, res:// root, non-res:// paths) are reported in "warnings" instead.
static func collect_dirs(scenes: Array, scripts: Array) -> Dictionary:
	var dirs := {}
	var warnings: Array[String] = []
	if DirAccess.dir_exists_absolute(WEB_DIR):
		dirs[WEB_DIR] = "pmc.js SDK (served at /pmc/)"
	else:
		warnings.append("%s is missing; /pmc/pmc.js will 404 in the export" % WEB_DIR)
	var script_cache := {}
	for scene in scenes:
		_scan_scene(scene, dirs, warnings, script_cache)
	for script in scripts:
		_scan_script(script, dirs, warnings)
	if not dirs.has(DEFAULT_CONTROLLER_DIR) and DirAccess.dir_exists_absolute(DEFAULT_CONTROLLER_DIR):
		dirs[DEFAULT_CONTROLLER_DIR] = "PMCHost.controller_dir default"
	return {"dirs": dirs, "warnings": warnings}


## res:// file paths under [param dir] (recursive) that should be packed verbatim.
static func collect_files(dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	_collect_files(dir.rstrip("/"), out)
	return out


static func _collect_files(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if out.size() >= MAX_FILES:
			return
		if f.begins_with(".") or f.get_extension().to_lower() in SKIP_EXTENSIONS:
			continue
		out.append(dir.path_join(f))
	for sub in d.get_directories():
		if out.size() >= MAX_FILES:
			return
		if not sub.begins_with("."):
			_collect_files(dir.path_join(sub), out)


# Node-aware .tscn scan: a node whose script is host.gd (or extends it) contributes its
# controller_dir property. Binary .scn files yield no [node] sections and are skipped.
static func _scan_scene(path: String, dirs: Dictionary, warnings: Array, script_cache: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	if not text.begins_with("[gd_scene"):
		return

	# ext_resource id -> script path
	var ext_scripts := {}
	for m in _re("\\[ext_resource[^\\]]*\\]").search_all(text):
		var line := m.get_string()
		if not 'type="Script"' in line:
			continue
		var id := _first_group(line, 'id="([^"]+)"')
		var p := _first_group(line, 'path="([^"]+)"')
		if id != "" and p != "":
			ext_scripts[id] = p

	# Per-[node] block: its script ext-resource and controller_dir property.
	for m in _re("\\[node\\s[^\\]]*\\]").search_all(text):
		var start := m.get_end()
		var next := text.find("\n[", start)
		var block := text.substr(start, (next if next >= 0 else text.length()) - start)
		var sid := _first_group(block, 'script\\s*=\\s*ExtResource\\("([^"]+)"\\)')
		if sid == "" or not ext_scripts.has(sid):
			continue
		if not _is_host_script(ext_scripts[sid], script_cache):
			continue
		var prop := _re('controller_dir\\s*=\\s*"([^"]*)"').search(block)
		var dir := DEFAULT_CONTROLLER_DIR if prop == null else prop.get_string(1)
		if dir == "":
			continue  # controller_dir = "" disables file serving
		_add_dir(dirs, warnings, dir, "controller_dir on %s in %s" % [_node_name(m.get_string()), path.get_file()])


static func _node_name(header: String) -> String:
	var n := _first_group(header, 'name="([^"]+)"')
	return '"%s"' % n if n != "" else "a PMCHost node"


# Script scan: literal res:// strings passed to serve_directory() or assigned to controller_dir.
# Covers hosts built in code (PMCHost.new()), which scenes can't see. := declarations and
# non-string arguments are ignored on purpose.
static func _scan_script(path: String, dirs: Dictionary, warnings: Array) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var where := path.get_file()
	for m in _re('serve_directory\\s*\\(\\s*"[^"]*"\\s*,\\s*"(res://[^"]*)"').search_all(text):
		_add_dir(dirs, warnings, m.get_string(1), "serve_directory() in %s" % where)
	for m in _re('controller_dir\\s*=\\s*"(res://[^"]*)"').search_all(text):
		_add_dir(dirs, warnings, m.get_string(1), "controller_dir in %s" % where)


static func _is_host_script(path: String, cache: Dictionary) -> bool:
	if cache.has(path):
		return cache[path]
	var result := path == HOST_SCRIPT
	if not result and path.begins_with("res://") and path.get_extension() == "gd":
		var s: Script = load(path)
		while s != null:
			if s.resource_path == HOST_SCRIPT:
				result = true
				break
			s = s.get_base_script()
	cache[path] = result
	return result


static func _add_dir(dirs: Dictionary, warnings: Array, dir: String, source: String) -> void:
	var d := dir.strip_edges()
	if not d.begins_with("res://"):
		return  # user:// and absolute paths live outside the pck; nothing to pack
	d = d.rstrip("/")
	if d == "res:":
		warnings.append("%s points at res:// itself; refusing to pack the whole project (%s)" % [dir, source])
		return
	if dirs.has(d):
		return
	if not DirAccess.dir_exists_absolute(d):
		warnings.append("%s does not exist (%s)" % [d, source])
		return
	dirs[d] = source


static func _first_group(text: String, pattern: String) -> String:
	var m := _re(pattern).search(text)
	return m.get_string(1) if m != null else ""


static func _re(pattern: String) -> RegEx:
	var r := RegEx.new()
	r.compile(pattern)
	return r
