extends RefCounted
## Scanner fixture: literal res:// strings the export scan should pick up (issue #19).
## Never called; the values just need to exist as source text.


func configure(host: PMCHost, dynamic_dir: String) -> void:
	host.controller_dir = "res://tests/fixtures/export/gd_home"
	host.serve_directory("/extra/", "res://tests/fixtures/export/gd_extra")
	host.serve_directory("/missing/", "res://tests/fixtures/export/gd_missing")
	host.serve_directory("/everything/", "res://")
	host.serve_directory("/abs/", "user://not_in_pck")
	host.serve_directory("/dyn/", dynamic_dir)
