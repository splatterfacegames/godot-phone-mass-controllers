@tool
extends EditorPlugin
## Editor integration for Phone Mass Controllers: registers the PMCHost node type and adds the
## "Phone Controllers" bottom panel (download cloudflared, test a quick tunnel, docs links).
## Editor-only: nothing here is referenced by the runtime classes, so it never runs in exported games.

const HOST_SCRIPT := "res://addons/phone_mass_controllers/host.gd"
const ICON := "res://addons/phone_mass_controllers/editor/icon_host.svg"
const DockScript := preload("res://addons/phone_mass_controllers/editor/dock.gd")

var _dock: Control
var _dock_container: Control # EditorDock (4.6+) or null when using the bottom panel API.
var _custom_type_added := false


func _enter_tree() -> void:
	if ResourceLoader.exists(HOST_SCRIPT):
		var icon: Texture2D = load(ICON) if ResourceLoader.exists(ICON) else null
		add_custom_type("PMCHost", "Node", load(HOST_SCRIPT), icon)
		_custom_type_added = true

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
	if _custom_type_added:
		remove_custom_type("PMCHost")
		_custom_type_added = false
	if _dock_container != null:
		call("remove_dock", _dock_container)
		_dock_container.queue_free()
		_dock_container = null
		_dock = null
	elif _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
