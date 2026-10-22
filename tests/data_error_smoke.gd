extends SceneTree

const Validator := preload("res://scripts/data_validator.gd")

func _init() -> void:
	var validator := Validator.new()
	var broken_globals := {
		"schema": "tankcraft.globals",
		"version": "bad",
		"global": {"cell_size": 0},
		"survival": {},
		"menu": {}
	}
	var errors := validator.validate_globals("res://tests/fixtures/broken_globals.json", broken_globals)
	var has_version_error := false
	var has_cell_error := false
	for message in errors:
		if "$.version" in message:
			has_version_error = true
		if "$.global.cell_size" in message:
			has_cell_error = true
	if errors.size() < 2 or not has_version_error or not has_cell_error:
		printerr("DATA_ERROR_TEST_FAILED count=%d" % errors.size())
		for message in errors:
			printerr(message)
		quit(1)
		return
	print("DATA_ERROR_OK errors=%d" % errors.size())
	quit(0)
