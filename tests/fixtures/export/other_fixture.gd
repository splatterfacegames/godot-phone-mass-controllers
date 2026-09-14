extends Node
## Scanner fixture: a node that happens to export a controller_dir property but is NOT a PMCHost.
## Scene scanning must not pick up its value (issue #19).

@export var controller_dir := "res://tests/fixtures/export/decoy"
