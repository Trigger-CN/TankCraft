extends SceneTree

const DataRegistry := preload("res://scripts/data_registry.gd")

func _init() -> void:
	var registry := DataRegistry.new()
	var valid := registry.load_all()
	if not valid:
		for message in registry.errors:
			printerr(message)
		quit(1)
		return
	print("DATA_OK files=%d modules=%d ammo=%d upgrades=%d arenas=%d blueprints=%d" % [
		registry.loaded_files.size(),
		registry.modules.size(),
		registry.ammo.size(),
		registry.upgrades.size(),
		registry.arenas.size(),
		registry.blueprints.size()
	])
	quit(0)
