extends RefCounted
## Issue #19: the export scanner finds every res:// dir that must ship as raw files —
## the SDK dir, res://controller, PMCHost.controller_dir from scenes, and res:// literals in
## serve_directory()/controller_dir script assignments — and nothing else.

const Scan := preload("res://addons/phone_mass_controllers/editor/export_scan.gd")
const FX := "res://tests/fixtures/export"
const SCENES := [FX + "/fixture_scene.tscn", FX + "/fixture_subclass_scene.tscn", FX + "/fixture_default_scene.tscn"]
const SCRIPTS := [FX + "/script_fixture.gd", FX + "/other_fixture.gd"]


func run(t) -> void:
	t.section("project_files")
	var scenes := Scan.project_files(["tscn", "scn"])
	t.ok(scenes.has(FX + "/fixture_scene.tscn"), "fixture scene found")
	t.ok(scenes.has("res://demo/main.tscn"), "demo scene found")
	var scripts := Scan.project_files(["gd"])
	t.ok(scripts.has(FX + "/script_fixture.gd"), "fixture script found")
	t.ok(not Array(scripts).any(func(p: String) -> bool: return p.begins_with("res://.godot")), ".godot skipped")

	t.section("collect_dirs: scenes")
	var r := Scan.collect_dirs(SCENES, [])
	var dirs: Dictionary = r.dirs
	t.eq(dirs.get(FX + "/scene_controller"), "controller_dir on \"Host\" in fixture_scene.tscn", "host node's controller_dir")
	t.eq(dirs.get(FX + "/sub_home"), "controller_dir on \"SubHost\" in fixture_subclass_scene.tscn", "PMCHost subclass in scene")
	t.ok(not dirs.has(FX + "/decoy"), "non-host controller_dir ignored")

	t.section("collect_dirs: scripts")
	r = Scan.collect_dirs([], SCRIPTS)
	dirs = r.dirs
	t.ok(dirs.has(FX + "/gd_home"), "controller_dir literal in .gd")
	t.ok(dirs.has(FX + "/gd_extra"), "serve_directory literal in .gd")
	t.ok(not dirs.has("res:") and not dirs.has("res://"), "res:// root refused")
	t.ok(not dirs.has(FX + "/decoy"), ":= declaration not matched")
	var warnings: Array = r.warnings
	t.ok(warnings.any(func(w: String) -> bool: return w.contains("gd_missing")), "missing dir warned")
	t.ok(warnings.any(func(w: String) -> bool: return w.contains("res:// itself")), "res:// root warned")

	t.section("collect_dirs: always-on dirs")
	r = Scan.collect_dirs([], [])
	dirs = r.dirs
	t.eq(dirs.get(Scan.WEB_DIR), "pmc.js SDK (served at /pmc/)", "SDK dir always packed")
	t.ok(not dirs.has(Scan.DEFAULT_CONTROLLER_DIR), "no res://controller in this repo, so not added")
	r = Scan.collect_dirs([FX + "/fixture_default_scene.tscn"], [])
	t.ok(r.warnings.any(func(w: String) -> bool: return w.contains("res://controller")), "implicit default dir warned when missing")

	t.section("collect_files")
	var files := Scan.collect_files(FX + "/controller_fixture")
	t.ok(files.has(FX + "/controller_fixture/index.html"), "html listed")
	t.ok(files.has(FX + "/controller_fixture/app.js"), "js listed")
	t.ok(files.has(FX + "/controller_fixture/logo.png"), "imported png listed raw")
	t.ok(files.has(FX + "/controller_fixture/nested/deep.txt"), "nested file listed")
	t.ok(not Array(files).any(func(p: String) -> bool: return p.get_extension() in ["import", "uid"]), "import metadata excluded")
	t.eq(Scan.collect_files(FX + "/missing_dir").size(), 0, "missing dir -> no files")

	t.section("whole project")
	r = Scan.collect_dirs(Scan.project_files(["tscn", "scn"]), Scan.project_files(["gd"]))
	dirs = r.dirs
	t.ok(dirs.has("res://demo/controller"), "demo's code-created host found via main.gd")
	t.ok(dirs.has(Scan.WEB_DIR), "SDK dir in project scan")

	t.section("plugin shells compile")
	t.ok(load("res://addons/phone_mass_controllers/editor/export_plugin.gd") != null, "export_plugin.gd")
	t.ok(load("res://addons/phone_mass_controllers/plugin.gd") != null, "plugin.gd")
