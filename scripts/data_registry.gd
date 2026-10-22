extends RefCounted

## M1 数据注册表。
## 扫描 data/ 下 JSON，按稳定路径排序读取，并委托 data_validator.gd 校验。
## 该脚本不包含玩法数值；调用方只消费注册后的 Dictionary。

const Validator := preload("res://scripts/data_validator.gd")

var globals: Dictionary = {}
var modules: Dictionary = {}
var ammo: Dictionary = {}
var upgrades: Dictionary = {}
var arenas: Dictionary = {}
var blueprints: Dictionary = {}
var errors: PackedStringArray = PackedStringArray()
var loaded_files: PackedStringArray = PackedStringArray()

func load_all(root: String = "res://data") -> bool:
	globals.clear()
	modules.clear()
	ammo.clear()
	upgrades.clear()
	arenas.clear()
	blueprints.clear()
	errors.clear()
	loaded_files.clear()
	var validator := Validator.new()
	_load_globals(root.path_join("globals.json"), validator)
	_load_module_catalogs(root.path_join("modules"), validator)
	_load_catalog_dir(root.path_join("ammo"), "ammo", validator)
	_load_catalog_dir(root.path_join("upgrades"), "upgrades", validator)
	_load_arena_dir(root.path_join("arenas"), validator)
	_load_blueprint_dir(root.path_join("blueprints"), validator)
	_validate_cross_references(validator)
	return errors.is_empty()

func get_module(id: String) -> Dictionary:
	return modules.get(id, {}).duplicate(true)

func get_ammo(id: String) -> Dictionary:
	return ammo.get(id, {}).duplicate(true)

func get_upgrade(id: String) -> Dictionary:
	return upgrades.get(id, {}).duplicate(true)

func get_arena(id: String) -> Dictionary:
	return arenas.get(id, {}).duplicate(true)

func get_blueprint(id: String) -> Dictionary:
	return blueprints.get(id, {}).duplicate(true)

func _load_globals(path: String, validator: Validator) -> void:
	var data: Variant = _read_json(path)
	if data == null:
		return
	var validation := validator.validate_globals(path, data)
	_append_errors(validation)
	if validation.is_empty():
		globals = data

func _load_module_catalogs(directory: String, validator: Validator) -> void:
	var catalogs := [
		["platforms.json", "platform"],
		["mobility.json", "mobility"],
		["systems.json", "module"]
	]
	for spec in catalogs:
		var path: String = directory.path_join(spec[0])
		var data: Variant = _read_json(path)
		if data == null:
			continue
		var validation := validator.validate_module_catalog(path, data, spec[1])
		_append_errors(validation)
		if validation.is_empty():
			_index_items(data["items"], modules, path)

func _load_catalog_dir(directory: String, kind: String, validator: Validator) -> void:
	var files := _json_files(directory)
	for path in files:
		var data: Variant = _read_json(path)
		if data == null:
			continue
		var validation: PackedStringArray
		if kind == "ammo":
			validation = validator.validate_ammo_catalog(path, data)
		else:
			validation = validator.validate_upgrade_catalog(path, data)
		_append_errors(validation)
		if validation.is_empty():
			_index_items(data["items"], ammo if kind == "ammo" else upgrades, path)

func _load_arena_dir(directory: String, validator: Validator) -> void:
	for path in _json_files(directory):
		var data: Variant = _read_json(path)
		if data == null:
			continue
		var validation := validator.validate_arena(path, data)
		_append_errors(validation)
		if validation.is_empty():
			var arena_id: String = data.get("id", "")
			if arenas.has(arena_id):
				errors.append("%s $.id：重复 id '%s'" % [path, arena_id])
			else:
				arenas[arena_id] = data

func _load_blueprint_dir(directory: String, validator: Validator) -> void:
	for path in _json_files(directory):
		var data: Variant = _read_json(path)
		if data == null:
			continue
		var validation := validator.validate_blueprint(path, data, modules, ammo)
		_append_errors(validation)
		if validation.is_empty():
			var blueprint_id := path.get_file().get_basename()
			if blueprints.has(blueprint_id):
				errors.append("%s $.name：重复蓝图 id '%s'" % [path, blueprint_id])
			else:
				blueprints[blueprint_id] = data

func _validate_cross_references(validator: Validator) -> void:
	for blueprint_id in blueprints.keys():
		var blueprint: Dictionary = blueprints[blueprint_id]
		var spent := _blueprint_price(blueprint)
		var recorded: float = float(blueprint.get("economy", {}).get("credits_spent", -1))
		if recorded >= 0.0 and absf(spent - recorded) > 0.01:
			errors.append("res://data/blueprints/%s.json $.economy.credits_spent：记录值 %.2f 与重算值 %.2f 不一致" % [blueprint_id, recorded, spent])
	for module_id in modules.keys():
		var item: Dictionary = modules[module_id]
		if item.has("caliber") and not ammo.has(item["caliber"]):
			errors.append("module:%s $.caliber：引用不存在的口径 '%s'" % [module_id, item["caliber"]])

func _blueprint_price(blueprint: Dictionary) -> float:
	var total := 0.0
	## GridBuilder._recalculate_spent() 把质量上限升级花费也算进 credits_spent，
	## 重算必须用同一口径，否则 mass_cap_level > 0 的蓝图会被误判为不一致。
	var cap_level := int(blueprint.get("economy", {}).get("mass_cap_level", 0))
	var cap_prices: Array = globals.get("global", {}).get("mass_cap_upgrade_prices", [])
	for index in range(mini(cap_level, cap_prices.size())):
		total += float(cap_prices[index])
	for cell in blueprint.get("platform_cells", []):
		total += float(globals.get("global", {}).get("platform_cell_price", 4))
	for part in blueprint.get("platform_shapes", []):
		total += float(modules.get(part.get("id", ""), {}).get("price", 0))
	for part in blueprint.get("mobility", []):
		total += float(modules.get(part.get("id", ""), {}).get("price", 0))
	for part in blueprint.get("modules", []):
		total += float(modules.get(part.get("id", ""), {}).get("price", 0))
	return total

func _index_items(items: Array, target: Dictionary, path: String) -> void:
	for item in items:
		var item_id: String = item.get("id", "")
		if target.has(item_id):
			errors.append("%s $.items：跨文件重复 id '%s'" % [path, item_id])
		else:
			target[item_id] = item

func _read_json(path: String):
	if not FileAccess.file_exists(path):
		errors.append("%s $：文件不存在" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		errors.append("%s $：无法打开文件" % path)
		return null
	loaded_files.append(path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed == null:
		errors.append("%s $：JSON 解析失败" % path)
		return null
	return parsed

func _json_files(directory: String) -> Array[String]:
	var result: Array[String] = []
	var dir := DirAccess.open(directory)
	if dir == null:
		errors.append("%s：目录不存在或无法打开" % directory)
		return result
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.get_extension().to_lower() == "json":
			result.append(directory.path_join(name))
		name = dir.get_next()
	dir.list_dir_end()
	result.sort()
	return result

func _append_errors(new_errors: PackedStringArray) -> void:
	for message in new_errors:
		errors.append(message)
