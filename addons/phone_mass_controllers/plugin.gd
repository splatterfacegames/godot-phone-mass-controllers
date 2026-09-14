@tool
extends EditorPlugin
## Editor integration for Phone Mass Controllers: the "Phone Controllers" bottom panel (running-game
## status, cloudflared download, test tunnel, docs links), an export plugin that ships served
## controller dirs as raw files, and a debugger plugin that feeds the dock live game status.
## PMCHost is registered by its class_name — an add_custom_type on top would list it twice in
## Create Node. Its icon comes from the @icon annotation on host.gd.
## Editor-only: nothing here is referenced by the runtime classes, so it never runs in exported games.

const ICON := "res://addons/phone_mass_controllers/editor/icon_host.svg"
const DockScript := preload("res://addons/phone_mass_controllers/editor/dock.gd")
const ExportPluginScript := preload("res://addons/phone_mass_controllers/editor/export_plugin.gd")
const DebuggerPluginScript := preload("res://addons/phone_mass_controllers/editor/debugger_plugin.gd")

var _dock: Control
var _dock_container: Control # EditorDock (4.6+) or null when using the bottom panel API.
var _export_plugin: EditorExportPlugin
var _debugger_plugin: EditorDebuggerPlugin


func _enter_tree() -> void:
	_export_plugin = ExportPluginScript.new()
	add_export_plugin(_export_plugin)
	_debugger_plugin = DebuggerPluginScript.new()
	add_debugger_plugin(_debugger_plugin)

	_dock = DockScript.new()
	_dock.name = "PhoneControllers"
	if ClassDB.class_exists("EditorDock") and has_method("add_dock"):
		_dock_container = ClassDB.instantiate("EditorDock")
		_dock_container.set("title", "Phone Controllers")
		_dock_container.set("default_slot", 8) # EditorDock.DOCK_SLOT_BOTTOM
		_dock_container.set("layout_key", "phone_mass_controllers")
		if ResourceLoader.exists(ICON):
			_dock_container.set("dock_icon", load(ICON))
		_dock_container.add_child(_dock)
		call("add_dock", _dock_container)
	else:
		add_control_to_bottom_panel(_dock, "Phone Controllers")


func _exit_tree() -> void:
	if _debugger_plugin != null:
		remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
	if _dock_container != null:
		call("remove_dock", _dock_container)
		_dock_container.queue_free()
		_dock_container = null
		_dock = null
	elif _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
