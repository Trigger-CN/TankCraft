extends RefCounted

## M1 数据校验器。
## 只负责验证，不负责扫描文件或保存索引。
## 错误格式统一为：文件路径 + JSON 路径 + 原因。

const MODULE_CATEGORIES := ["platform", "mobility", "module"]
const MODULE_LAYERS := ["platform", "mobility", "module"]
const ROTATIONS := [0, 90, 180, 270]
const AIM_ROTATIONS := [0, 45, 90, 135, 180, 225, 270, 315]


func _is_integer_number(value: Variant) -> bool:
	return value is int or (value is float and is_equal_approx(float(value), roundf(float(value))))

func _enum_has_integer(values: Array, value: Variant) -> bool:
	if not _is_integer_number(value):
		return false
	return values.has(int(value))

func validate_globals(path: String, data: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_dictionary(path, "$", data, errors):
		return errors
	_require_string(path, data, "schema", errors)
	_require_int(path, data, "version", errors)
	var global_data: Variant = data.get("global")
	var survival_data: Variant = data.get("survival")
	var menu_data: Variant = data.get("menu")
	_require_dictionary(path, "$.global", global_data, errors)
	## M9：`expedition` 块已退役，改由 `survival` 块承接（design §14.8）。
	_require_dictionary(path, "$.survival", survival_data, errors)
	_require_dictionary(path, "$.menu", menu_data, errors)
	if global_data is Dictionary:
		_require_positive_int(path, "$.global.cell_size", global_data, "cell_size", errors)
		_require_positive_int(path, "$.global.physics_hz", global_data, "physics_hz", errors)
		_require_positive_int(path, "$.global.ammo_net_hz", global_data, "ammo_net_hz", errors)
		_require_positive_number(path, "$.global.default_build_credits", global_data, "default_build_credits", errors)
		_require_positive_number(path, "$.global.base_mass_cap", global_data, "base_mass_cap", errors)
		_require_positive_number(path, "$.global.mass_cap_step", global_data, "mass_cap_step", errors)
		_require_non_negative_int_at(path, "$.global.mass_cap_max_level", global_data, "mass_cap_max_level", errors)
		_require_vector2_int(path, "$.global.max_tank_size", global_data, "max_tank_size", errors)
		_require_positive_int(path, "$.global.undo_history_depth", global_data, "undo_history_depth", errors)
		_validate_number_array(path, "$.global.mass_cap_upgrade_prices", global_data, "mass_cap_upgrade_prices", errors)
	if survival_data is Dictionary:
		_require_positive_number(path, "$.survival.wave_time_s", survival_data, "wave_time_s", errors)
		_require_number_range(path, "$.survival.wave_growth_s", survival_data, "wave_growth_s", 0.0, 600.0, errors)
		_require_positive_int(path, "$.survival.enemy_count_base", survival_data, "enemy_count_base", errors)
		_require_positive_int(path, "$.survival.enemy_count_max", survival_data, "enemy_count_max", errors)
		_require_positive_int(path, "$.survival.boss_every", survival_data, "boss_every", errors)
		_require_positive_number(path, "$.survival.xp_base", survival_data, "xp_base", errors)
		_require_number_range(path, "$.survival.xp_step", survival_data, "xp_step", 0.0, 100000.0, errors)
		_require_positive_int(path, "$.survival.choice_count", survival_data, "choice_count", errors)
		_require_positive_number(path, "$.survival.house_hp", survival_data, "house_hp", errors)
		_require_positive_int(path, "$.survival.shop_slot_count", survival_data, "shop_slot_count", errors)
		_require_positive_number(path, "$.survival.shop_reroll_cost", survival_data, "shop_reroll_cost", errors)
		_require_number_range(path, "$.survival.shop_sell_rate", survival_data, "shop_sell_rate", 0.0, 1.0, errors)
		_require_number_range(path, "$.survival.debris_credit_share", survival_data, "debris_credit_share", 0.0, 1.0, errors)
		for key in ["debris_drop_chance", "house_drop_chance", "enemy_drop_chance"]:
			_require_number_range(path, "$.survival.%s" % key, survival_data, key, 0.0, 1.0, errors)
		_validate_number_array(path, "$.survival.shop_rarity_weight", survival_data, "shop_rarity_weight", errors)
	if menu_data is Dictionary:
		_require_number_range(path, "$.menu.ui_scale_min", menu_data, "ui_scale_min", 0.1, 4.0, errors)
		_require_number_range(path, "$.menu.ui_scale_max", menu_data, "ui_scale_max", 0.1, 4.0, errors)
	return errors

func validate_module_catalog(path: String, data: Variant, expected_category: String) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_dictionary(path, "$", data, errors):
		return errors
	_require_string(path, data, "schema", errors)
	_require_int(path, data, "version", errors)
	var category: Variant = data.get("category")
	if category != expected_category:
		errors.append(_error(path, "$.category", "必须是 '%s'" % expected_category))
	var items: Variant = data.get("items")
	if not _require_array(path, "$.items", items, errors):
		return errors
	var local_ids := {}
	for index in range(items.size()):
		var item: Variant = items[index]
		var item_path := "$.items[%d]" % index
		if not _require_dictionary(path, item_path, item, errors):
			continue
		var item_id: Variant = item.get("id")
		if not _require_string_at(path, item_path + ".id", item_id, errors):
			continue
		if local_ids.has(item_id):
			errors.append(_error(path, item_path + ".id", "目录内重复 id '%s'" % item_id))
		else:
			local_ids[item_id] = true
		_validate_module_item(path, item_path, item, expected_category, errors)
	return errors

func validate_ammo_catalog(path: String, data: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_catalog_header(path, data, "tankcraft.ammo_catalog", errors):
		return errors
	var items: Array = data["items"]
	var ids := {}
	for index in range(items.size()):
		var item: Variant = items[index]
		var item_path := "$.items[%d]" % index
		if not _require_dictionary(path, item_path, item, errors):
			continue
		var item_id: Variant = item.get("id")
		if _require_string_at(path, item_path + ".id", item_id, errors):
			if ids.has(item_id):
				errors.append(_error(path, item_path + ".id", "目录内重复 id '%s'" % item_id))
			ids[item_id] = true
		_require_positive_number_at(path, item_path + ".base_damage", item, "base_damage", errors)
		_require_positive_number_at(path, item_path + ".speed_px_s", item, "speed_px_s", errors)
		## v3.23：射程从「全局单值」改为**口径属性**——每种口径必须有自己明确的默认射程，
		## 漏写就会退化成全局值，而那正是要废除的耦合，所以这里强制必填。
		_require_positive_number_at(path, item_path + ".range_px", item, "range_px", errors)
		_require_positive_int_at(path, item_path + ".slot", item, "slot", errors)
		_require_positive_number_at(path, item_path + ".radius_px", item, "radius_px", errors)
		_require_number_range_at(path, item_path + ".processing_factor", item, "processing_factor", 0.1, 10.0, errors)
	return errors

func validate_upgrade_catalog(path: String, data: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_catalog_header(path, data, "tankcraft.upgrade_catalog", errors):
		return errors
	var items: Array = data["items"]
	var ids := {}
	for index in range(items.size()):
		var item: Variant = items[index]
		var item_path := "$.items[%d]" % index
		if not _require_dictionary(path, item_path, item, errors):
			continue
		var item_id: Variant = item.get("id")
		if _require_string_at(path, item_path + ".id", item_id, errors):
			if ids.has(item_id):
				errors.append(_error(path, item_path + ".id", "目录内重复 id '%s'" % item_id))
			ids[item_id] = true
		_require_string_at(path, item_path + ".effect", item.get("effect"), errors)
		_require_positive_int_at(path, item_path + ".stack_limit", item, "stack_limit", errors)
		_require_positive_number_at(path, item_path + ".processing_multiplier", item, "processing_multiplier", errors)
	return errors

func validate_arena(path: String, data: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_dictionary(path, "$", data, errors):
		return errors
	_require_string(path, data, "schema", errors)
	_require_string(path, data, "id", errors)
	_require_string(path, data, "name", errors)
	_require_vector2_int(path, "$.size", data, "size", errors)
	var spawns: Variant = data.get("spawns")
	if _require_array(path, "$.spawns", spawns, errors):
		for index in range(spawns.size()):
			_validate_spawn(path, "$.spawns[%d]" % index, spawns[index], errors)
	var expedition: Variant = data.get("expedition_spawns")
	if not _require_dictionary(path, "$.expedition_spawns", expedition, errors):
		return errors
	if expedition is Dictionary:
		_validate_spawn(path, "$.expedition_spawns.player", expedition.get("player"), errors)
		var waves: Variant = expedition.get("waves")
		if _require_array(path, "$.expedition_spawns.waves", waves, errors):
			for wave_index in range(waves.size()):
				var wave: Variant = waves[wave_index]
				if _require_array(path, "$.expedition_spawns.waves[%d]" % wave_index, wave, errors):
					for spawn_index in range(wave.size()):
						_validate_spawn(path, "$.expedition_spawns.waves[%d][%d]" % [wave_index, spawn_index], wave[spawn_index], errors)
	return errors

func validate_blueprint(path: String, data: Variant, known_ids: Dictionary, ammo_ids: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _require_dictionary(path, "$", data, errors):
		return errors
	_require_string_at(path, "$.format", data.get("format"), errors)
	if data.get("format") != "tankcraft.blueprint":
		errors.append(_error(path, "$.format", "必须是 tankcraft.blueprint"))
	_require_int(path, data, "version", errors)
	_require_string(path, data, "name", errors)
	_require_vector2_int(path, "$.size", data, "size", errors)
	var economy: Variant = data.get("economy")
	if _require_dictionary(path, "$.economy", economy, errors):
		_require_non_negative_number_at(path, "$.economy.credits_total", economy, "credits_total", errors)
		_require_non_negative_number_at(path, "$.economy.credits_spent", economy, "credits_spent", errors)
		_require_non_negative_int_at(path, "$.economy.mass_cap_level", economy, "mass_cap_level", errors)
	var modules: Variant = data.get("modules")
	if _require_array(path, "$.modules", modules, errors):
		var cockpit_count := 0
		for index in range(modules.size()):
			var item: Variant = modules[index]
			var item_path := "$.modules[%d]" % index
			if not _require_dictionary(path, item_path, item, errors):
				continue
			_validate_blueprint_part(path, item_path, item, known_ids, errors)
			var item_id: Variant = item.get("id")
			if item_id is String and String(item_id).begins_with("cockpit_"):
				cockpit_count += 1
		if cockpit_count != 1:
			errors.append(_error(path, "$.modules", "驾驶舱数量必须恰好为 1，当前 %d" % cockpit_count))
	var mobility: Variant = data.get("mobility")
	if _require_array(path, "$.mobility", mobility, errors):
		if mobility.is_empty():
			errors.append(_error(path, "$.mobility", "至少需要一个行进机构"))
		for index in range(mobility.size()):
			_validate_blueprint_part(path, "$.mobility[%d]" % index, mobility[index], known_ids, errors)
	var platform_cells: Variant = data.get("platform_cells")
	if _require_array(path, "$.platform_cells", platform_cells, errors):
		if platform_cells.is_empty():
			errors.append(_error(path, "$.platform_cells", "至少需要一个平台格"))
	var routes: Variant = data.get("routes")
	if not _require_array(path, "$.routes", routes, errors):
		errors.append(_error(path, "$.routes", "必须存在 routes 数组，即使为空"))
	return errors

func _validate_module_item(path: String, item_path: String, item: Dictionary, category: String, errors: PackedStringArray) -> void:
	var required := ["id", "name", "layer", "footprint", "price", "mass", "hp_max", "armor", "rotatable"]
	for field in required:
		if not item.has(field):
			errors.append(_error(path, item_path + "." + field, "缺少字段"))
	_require_string_at(path, item_path + ".layer", item.get("layer"), errors)
	if item.get("layer") not in MODULE_LAYERS:
		errors.append(_error(path, item_path + ".layer", "未知层 '%s'" % item.get("layer")))
	_require_positive_int_at(path, item_path + ".footprint", item, "footprint", errors)
	_require_non_negative_number_at(path, item_path + ".price", item, "price", errors)
	_require_non_negative_number_at(path, item_path + ".mass", item, "mass", errors)
	_require_positive_number_at(path, item_path + ".hp_max", item, "hp_max", errors)
	_require_non_negative_number_at(path, item_path + ".armor", item, "armor", errors)
	if not item.get("rotatable") is bool:
		errors.append(_error(path, item_path + ".rotatable", "必须是 boolean"))
	if category == "platform" and item.get("layer") != "platform":
		errors.append(_error(path, item_path + ".layer", "平台目录中的 layer 必须为 platform"))
	if category == "mobility" and item.get("layer") != "mobility":
		errors.append(_error(path, item_path + ".layer", "行进机构目录中的 layer 必须为 mobility"))
	if category == "module" and item.get("layer") != "module":
		errors.append(_error(path, item_path + ".layer", "功能模块目录中的 layer 必须为 module"))
	if item.has("ports") and not item["ports"] is Array:
		errors.append(_error(path, item_path + ".ports", "必须是 array"))
	if item.has("core") and not item["core"] is bool:
		errors.append(_error(path, item_path + ".core", "必须是 boolean"))
	if item.has("aim_steps") and item["aim_steps"] != 8:
		errors.append(_error(path, item_path + ".aim_steps", "炮管 aim_steps 必须为 8"))

func _validate_blueprint_part(path: String, item_path: String, item: Variant, known_ids: Dictionary, errors: PackedStringArray) -> void:
	if not _require_dictionary(path, item_path, item, errors):
		return
	var item_id: Variant = item.get("id")
	if _require_string_at(path, item_path + ".id", item_id, errors) and not known_ids.has(item_id):
		errors.append(_error(path, item_path + ".id", "引用不存在的模块 '%s'" % item_id))
	_require_vector2_int(path, item_path + ".pos", item, "pos", errors)
	var rotation: Variant = item.get("rot")
	if not _enum_has_integer(ROTATIONS, rotation):
		errors.append(_error(path, item_path + ".rot", "必须是 0/90/180/270"))
	if item_id is String and String(item_id).begins_with("cannon_"):
		var aim: Variant = item.get("aim")
		if not _enum_has_integer(AIM_ROTATIONS, aim):
			errors.append(_error(path, item_path + ".aim", "炮管 aim 必须是 0–315 的 45° 步进"))

func _validate_spawn(path: String, item_path: String, item: Variant, errors: PackedStringArray) -> void:
	if not _require_dictionary(path, item_path, item, errors):
		return
	_require_vector2_int(path, item_path + ".pos", item, "pos", errors)
	if not _enum_has_integer(ROTATIONS, item.get("rot")):
		errors.append(_error(path, item_path + ".rot", "必须是 0/90/180/270"))

func _require_catalog_header(path: String, data: Variant, expected_schema: String, errors: PackedStringArray) -> bool:
	if not _require_dictionary(path, "$", data, errors):
		return false
	_require_string(path, data, "schema", errors)
	if data.get("schema") != expected_schema:
		errors.append(_error(path, "$.schema", "必须是 '%s'" % expected_schema))
	_require_int(path, data, "version", errors)
	var items: Variant = data.get("items")
	return _require_array(path, "$.items", items, errors)

func _require_dictionary(path: String, json_path: String, value: Variant, errors: PackedStringArray) -> bool:
	if not value is Dictionary:
		errors.append(_error(path, json_path, "必须是 object"))
		return false
	return true

func _require_array(path: String, json_path: String, value: Variant, errors: PackedStringArray) -> bool:
	if not value is Array:
		errors.append(_error(path, json_path, "必须是 array"))
		return false
	return true

func _require_string(path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	_require_string_at(path, "$." + field, data.get(field), errors)

func _require_string_at(path: String, json_path: String, value: Variant, errors: PackedStringArray) -> bool:
	if not value is String or String(value).is_empty():
		errors.append(_error(path, json_path, "必须是非空 string"))
		return false
	return true

func _require_int(path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	if not data.has(field) or not _is_integer_number(data[field]):
		errors.append(_error(path, "$." + field, "必须是 int"))

func _require_positive_int(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	_require_positive_int_at(path, json_path, data, field, errors)

func _require_positive_int_at(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	if not data.has(field) or not _is_integer_number(data[field]) or int(data[field]) <= 0:
		errors.append(_error(path, json_path, "必须是正整数"))

func _require_non_negative_int_at(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	if not data.has(field) or not _is_integer_number(data[field]) or int(data[field]) < 0:
		errors.append(_error(path, json_path, "必须是非负整数"))

func _require_positive_number(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	_require_positive_number_at(path, json_path, data, field, errors)

func _require_positive_number_at(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	if not data.has(field) or not (data[field] is int or data[field] is float) or float(data[field]) <= 0.0:
		errors.append(_error(path, json_path, "必须是正数"))

func _require_non_negative_number_at(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	if not data.has(field) or not (data[field] is int or data[field] is float) or float(data[field]) < 0.0:
		errors.append(_error(path, json_path, "必须是非负数"))

func _require_number_range(path: String, json_path: String, data: Dictionary, field: String, low: float, high: float, errors: PackedStringArray) -> void:
	_require_number_range_at(path, json_path, data, field, low, high, errors)

func _require_number_range_at(path: String, json_path: String, data: Dictionary, field: String, low: float, high: float, errors: PackedStringArray) -> void:
	if not data.has(field) or not (data[field] is int or data[field] is float) or float(data[field]) < low or float(data[field]) > high:
		errors.append(_error(path, json_path, "必须在 %s..%s 范围内" % [low, high]))

func _validate_number_array(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	var value: Variant = data.get(field)
	if not value is Array or value.is_empty():
		errors.append(_error(path, json_path, "必须是非空 number array"))
		return
	for index in range(value.size()):
		if not (value[index] is int or value[index] is float) or float(value[index]) <= 0.0:
			errors.append(_error(path, "%s[%d]" % [json_path, index], "必须是正数"))
func _require_vector2_int(path: String, json_path: String, data: Dictionary, field: String, errors: PackedStringArray) -> void:
	var value: Variant = data.get(field)
	if not value is Array or value.size() != 2 or not _is_integer_number(value[0]) or not _is_integer_number(value[1]) or int(value[0]) <= 0 or int(value[1]) <= 0:
		errors.append(_error(path, json_path, "必须是两个正整数的 array"))

func _error(path: String, json_path: String, reason: String) -> String:
	return "%s %s：%s" % [path, json_path, reason]
