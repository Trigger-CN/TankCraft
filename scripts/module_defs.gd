extends RefCounted

## M2 模块定义访问层。
## 所有正式模块、价格、质量与全局建造参数均来自 DataRegistry。

const DataRegistry := preload("res://scripts/data_registry.gd")

var registry: DataRegistry
var global_data: Dictionary = {}

func load_all(root: String = "res://data") -> bool:
	registry = DataRegistry.new()
	if not registry.load_all(root):
		return false
	global_data = registry.globals.get("global", {}).duplicate(true)
	return true

func errors() -> PackedStringArray:
	if registry == null:
		return PackedStringArray(["模块定义尚未加载"])
	return registry.errors

func get_module(module_id: String) -> Dictionary:
	if registry == null:
		return {}
	return registry.get_module(module_id)

func get_blueprint(blueprint_id: String) -> Dictionary:
	if registry == null:
		return {}
	return registry.get_blueprint(blueprint_id)

func get_ammo(ammo_id: String) -> Dictionary:
	if registry == null:
		return {}
	return registry.get_ammo(ammo_id)

func get_arena(arena_id: String) -> Dictionary:
	if registry == null:
		return {}
	return registry.get_arena(arena_id)

func module_ids(layer: String) -> PackedStringArray:
	var ids := PackedStringArray()
	if registry == null:
		return ids
	for module_id in registry.modules.keys():
		var item: Dictionary = registry.modules[module_id]
		if String(item.get("layer", "")) == layer:
			ids.append(String(module_id))
	ids.sort()
	return ids

func modules_for_layer(layer: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for module_id in module_ids(layer):
		result.append(get_module(module_id))
	return result

func global_number(key: String, fallback: float = 0.0) -> float:
	return float(global_data.get(key, fallback))

func global_int(key: String, fallback: int = 0) -> int:
	return int(global_data.get(key, fallback))

func max_tank_size() -> Vector2i:
	var raw: Variant = global_data.get("max_tank_size", [24, 24])
	if raw is Array and raw.size() == 2:
		return Vector2i(int(raw[0]), int(raw[1]))
	return Vector2i(24, 24)

func mass_upgrade_prices() -> Array[float]:
	var result: Array[float] = []
	var raw: Variant = global_data.get("mass_cap_upgrade_prices", [])
	if raw is Array:
		for value in raw:
			result.append(float(value))
	return result

func shape_offsets(module_id: String) -> Array[Vector2i]:
	match module_id:
		"plat_1x2":
			return [Vector2i(0, 0), Vector2i(1, 0)]
		"plat_2x2":
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
		"plat_l3":
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1)]
		"plat_t4":
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1)]
		"plat_wedge":
			return [Vector2i(0, 0), Vector2i(1, 0)]
		_:
			return [Vector2i(0, 0)]

func rotation_offsets(module_id: String, footprint: int, rotation: int) -> Array[Vector2i]:
	var base := shape_offsets(module_id) if module_id.begins_with("plat_") else _line_offsets(footprint)
	var result: Array[Vector2i] = []
	for offset in base:
		result.append(_rotate_offset(offset, rotation))
	return _normalize_offsets(result)

func _line_offsets(footprint: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for index in range(footprint):
		result.append(Vector2i(index, 0))
	return result

func _rotate_offset(offset: Vector2i, rotation: int) -> Vector2i:
	match posmod(rotation, 360):
		0:
			return offset
		90:
			return Vector2i(-offset.y, offset.x)
		180:
			return Vector2i(-offset.x, -offset.y)
		270:
			return Vector2i(offset.y, -offset.x)
	return offset

func _normalize_offsets(offsets: Array[Vector2i]) -> Array[Vector2i]:
	if offsets.is_empty():
		return offsets
	var min_x := offsets[0].x
	var min_y := offsets[0].y
	for offset in offsets:
		min_x = mini(min_x, offset.x)
		min_y = mini(min_y, offset.y)
	var result: Array[Vector2i] = []
	for offset in offsets:
		result.append(offset - Vector2i(min_x, min_y))
	return result

## 读非 global 块（expedition / menu / ai / touch）。
## global_number / global_int 只看 globals["global"]，对其它块会默默返回 fallback，
## 所以非 global 块必须走这两个函数（design §11.6.8）。
func block_number(block: String, key: String, fallback: float = 0.0) -> float:
	if registry == null:
		return fallback
	var data: Dictionary = registry.globals.get(block, {})
	return float(data.get(key, fallback))

func block_int(block: String, key: String, fallback: int = 0) -> int:
	if registry == null:
		return fallback
	var data: Dictionary = registry.globals.get(block, {})
	return int(data.get(key, fallback))
