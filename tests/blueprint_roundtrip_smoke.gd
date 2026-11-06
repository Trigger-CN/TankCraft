extends SceneTree

## v3.45 永久回归：**蓝图必须保存改进槽配置**（审核报告唯一 P0）。
##
## 缺陷原貌：`grid_builder._parse_part()` / `_serialize_parts()` 都不处理 `upgrades`，
## 于是玩家在改装页用 `Q/E` + `T` 配好的改进槽，`Ctrl+S` 会提示「蓝图已保存」、
## `Ctrl+O` 会提示读回成功，**但槽位是空的，静默丢失且无任何警告**。
##
## 本测试的期望值**不来自实现**，全部来自「玩家可见的事实」：
##   1. 同一个 builder 上 serialize → parse → serialize 必须逐字节稳定（round-trip）；
##   2. 反序列化后的 `modifier_upgrades_at(cell)` 必须**逐项等于**写入值（不是「非空」）；
##   3. `intrinsic` 不得出现在存档里（模块类型属性，不是实例状态）；
##   4. 旧存档（没有 `upgrades` 字段）必须照样能读，且读出来是空配置；
##   5. 未知升级 id 与超槽数的条目**丢弃而不整条失败**（旧存档 / 手改坏的单条不该让整车打不开）；
##   6. 数据层读取真实蓝图目录时必须全部通过校验（`upgrades` 字段的类型与 id 都要被查）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all():
		printerr("BPROUND_DATA_FAILED")
		quit(1)
		return
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		printerr("BPROUND_SETUP_FAILED")
		quit(1)
		return
	builder.reset_demo()

	# 给演示车接一件改进装置：`modifier_power` 是 1 格、1 槽、固有 up_damage（不占槽）。
	# 放在 (10, 8) —— 演示车平台覆盖 x∈[6,13]、y∈[6,10]，该格空着。
	var place := builder.place_module("modifier_power", Vector2i(10, 8), 0, 0)
	_check(place.is_empty(), "place_modifier_accepted", place)

	# 槽位配置：写入两件（`modifier_power` 只有 1 槽，所以只收第一件，第二件被拒）。
	var slot_cell := Vector2i(10, 8)
	var configured := builder.set_modifier_upgrades(slot_cell, ["up_damage"])
	_check(configured.is_empty(), "configure_upgrades_accepted", configured)
	var written: Array = builder.modifier_upgrades_at(slot_cell)
	_check(written == ["up_damage"], "written_upgrades_exact", str(written))

	# ---- 第 1、3 条：存档内容与 round-trip
	var blueprint: Dictionary = builder.to_blueprint("roundtrip")
	var saved_part := _part_at_cell(blueprint, "modules", slot_cell)
	_check(not saved_part.is_empty(), "blueprint_has_modifier_part", str(saved_part))
	_check(saved_part.get("upgrades", null) is Array, "blueprint_writes_upgrades_field",
		"types=%s" % str(typeof(saved_part.get("upgrades", null))))
	if saved_part.get("upgrades", null) is Array:
		_check((saved_part["upgrades"] as Array) == ["up_damage"], "blueprint_upgrades_value_exact",
			str(saved_part["upgrades"]))
	_check(not saved_part.has("intrinsic"), "blueprint_does_not_write_intrinsic",
		"keys=%s" % str(saved_part.keys()))

	# **空数组也写**：没配槽的改进装置同样要有 `upgrades: []`，
	# 这样「本来没配」与「配了但字段丢了」在存档里可区分。
	# `(11, 9)` 是演示车平台上的空格（探针实测 `(9, 8)` 被驾驶舱占了）。
	var empty_cell := Vector2i(11, 9)
	var empty_place := builder.place_module("modifier_flame", empty_cell, 0, 0)
	_check(empty_place.is_empty(), "place_second_modifier_accepted", empty_place)
	var fresh: Dictionary = builder.to_blueprint("roundtrip")
	var saved_empty := _part_at_cell(fresh, "modules", empty_cell)
	_check(not saved_empty.is_empty(), "blueprint_has_second_modifier", str(saved_empty))
	_check(saved_empty.get("upgrades", null) is Array and (saved_empty["upgrades"] as Array).is_empty(),
		"blueprint_writes_empty_upgrades_array", str(saved_empty.get("upgrades", "MISSING")))

	# ---- 第 2 条：反序列化后必须逐项相等
	var reloaded := GridBuilder.new()
	if not reloaded.setup(definitions):
		printerr("BPROUND_RELOAD_SETUP_FAILED")
		quit(1)
		return
	var load_error := reloaded.load_blueprint(blueprint)
	_check(load_error.is_empty(), "reload_accepted", load_error)
	var restored: Array = reloaded.modifier_upgrades_at(slot_cell)
	_check(restored == ["up_damage"], "reloaded_upgrades_exact", str(restored))

	# round-trip 逐字节稳定（旧缺陷下这里也是稳的，所以它单独不能证明修好 —— 见上面两条）。
	var resaved: Dictionary = reloaded.to_blueprint("roundtrip")
	_check(JSON.stringify(blueprint) == JSON.stringify(resaved), "roundtrip_byte_stable",
		JSON.stringify(resaved))

	# ---- 第 4 条：旧存档（完全没有 upgrades 字段）必须照样能读
	var legacy: Dictionary = blueprint.duplicate(true)
	for raw in (legacy["modules"] as Array):
		(raw as Dictionary).erase("upgrades")
	var legacy_loader := GridBuilder.new()
	if not legacy_loader.setup(definitions):
		printerr("BPROUND_LEGACY_SETUP_FAILED")
		quit(1)
		return
	var legacy_error := legacy_loader.load_blueprint(legacy)
	_check(legacy_error.is_empty(), "legacy_blueprint_still_loads", legacy_error)
	_check(legacy_loader.modifier_upgrades_at(slot_cell).is_empty(), "legacy_reads_as_empty",
		str(legacy_loader.modifier_upgrades_at(slot_cell)))

	# ---- 第 5 条：非法条目丢弃而不整条失败
	var dirty: Dictionary = blueprint.duplicate(true)
	var dirty_part := _part_at_cell(dirty, "modules", slot_cell)
	if not dirty_part.is_empty():
		dirty_part["upgrades"] = ["up_does_not_exist", "up_damage", "up_damage", "up_damage"]
	var dirty_loader := GridBuilder.new()
	if not dirty_loader.setup(definitions):
		printerr("BPROUND_DIRTY_SETUP_FAILED")
		quit(1)
		return
	var dirty_error := dirty_loader.load_blueprint(dirty)
	_check(dirty_error.is_empty(), "dirty_blueprint_not_rejected", dirty_error)
	var dirty_result: Array = dirty_loader.modifier_upgrades_at(slot_cell)
	# 未知 id 丢弃；`up_damage` 的 stack_limit 是 4、槽数 1，所以只剩一件。
	_check(dirty_result == ["up_damage"], "dirty_unknown_dropped", str(dirty_result))

	# 槽数上限：塞 5 件合法-but-重复的条目，必须被截到槽数以内。
	var overflow: Dictionary = blueprint.duplicate(true)
	var overflow_part := _part_at_cell(overflow, "modules", slot_cell)
	if not overflow_part.is_empty():
		overflow_part["upgrades"] = ["up_damage", "up_burn", "up_slow", "up_pierce", "up_burn"]
	var overflow_loader := GridBuilder.new()
	if not overflow_loader.setup(definitions):
		printerr("BPROUND_OVERFLOW_SETUP_FAILED")
		quit(1)
		return
	var overflow_error := overflow_loader.load_blueprint(overflow)
	_check(overflow_error.is_empty(), "overflow_blueprint_not_rejected", overflow_error)
	var overflow_result: Array = overflow_loader.modifier_upgrades_at(slot_cell)
	_check(overflow_result.size() == 1, "overflow_truncated_to_slots", str(overflow_result))

	# ---- 第 6 条：真实蓝图目录必须全部通过数据层校验（含 upgrades 字段校验）
	var registry := definitions.registry
	_check(registry != null and registry.errors.is_empty(), "data_layer_errors_empty",
		"" if registry == null else str(registry.errors))
	var with_upgrades := 0
	for blueprint_id in registry.blueprints.keys():
		for raw in (registry.blueprints[blueprint_id].get("modules", []) as Array):
			if (raw as Dictionary).has("upgrades"):
				with_upgrades += 1
	print("BPROUND_SHIPPED_BLUEPRINTS_WITH_UPGRADES %d" % with_upgrades)

	print("BPROUND_DONE checks=%d failures=%d" % [_checks, _failures])
	if _failures == 0:
		print("BPROUND_OK")
		quit(0)
	else:
		printerr("BPROUND_FAIL count=%d" % _failures)
		quit(1)


func _check(condition: bool, tag: String, detail: String = "") -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	if detail.is_empty():
		printerr("BPROUND_CHECK_FAILED %s" % tag)
	else:
		printerr("BPROUND_CHECK_FAILED %s :: %s" % [tag, detail])


## 按格坐标从一份蓝图字典里找那一件（与世界坐标无关：蓝图存的是 `pos` 起始格）。
func _part_at_cell(blueprint: Dictionary, key: String, cell: Vector2i) -> Dictionary:
	for raw in (blueprint.get(key, []) as Array):
		if not raw is Dictionary:
			continue
		var pos: Variant = (raw as Dictionary).get("pos", [])
		if pos is Array and pos.size() == 2 and int(pos[0]) == cell.x and int(pos[1]) == cell.y:
			return raw
	return {}
