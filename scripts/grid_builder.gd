extends RefCounted

## M2 三层建造编辑器逻辑。
## 不负责输入与绘制；所有模块规格来自 ModuleDefs，所有操作保持可撤销。

const ModuleDefs := preload("res://scripts/module_defs.gd")

var definitions: ModuleDefs
var grid_size := Vector2i(24, 24)
var platform_cells: Dictionary = {}
var platform_shapes: Array = []
var mobility_parts: Array = []
var module_parts: Array = []
var routes: Array = []
var credits_total := 0
var mass_cap_level := 0
## 远征模式用 scrap 支付，关闭后信用点预算检查全部失效；编辑器始终为 true。
var budget_enabled := true

var _credits_spent := 0.0
var _undo_stack: Array = []
var _redo_stack: Array = []
var _history_depth := 200

func setup(module_defs: ModuleDefs) -> bool:
	definitions = module_defs
	grid_size = definitions.max_tank_size()
	_history_depth = maxi(definitions.global_int("undo_history_depth", 200), 1)
	credits_total = definitions.global_int("default_build_credits", 2400)
	mass_cap_level = 0
	_clear_state()
	return definitions.registry != null

func reset_demo() -> void:
	_clear_state()
	var start := Vector2i(6, 6)
	for y in range(start.y, start.y + 5):
		for x in range(start.x, start.x + 8):
			platform_cells[Vector2i(x, y)] = true
	_add_part_direct(mobility_parts, "track_heavy", Vector2i(7, 9), 0)
	_add_part_direct(module_parts, "cockpit_light", Vector2i(9, 8), 0, 0)
	_add_part_direct(module_parts, "engine_small", Vector2i(10, 7), 0, 0)
	_add_part_direct(module_parts, "ammo_factory_20", Vector2i(7, 7), 0, 0)
	_add_part_direct(module_parts, "conveyor_straight", Vector2i(8, 7), 0, 0)
	## M4：炮管必须紧邻直管出口 (9,7)，否则演示构建没有供弹链。
	_add_part_direct(module_parts, "cannon_20", Vector2i(9, 7), 0, 0)
	_recalculate_spent()
	_clear_history()

func _clear_state() -> void:
	platform_cells.clear()
	platform_shapes.clear()
	mobility_parts.clear()
	module_parts.clear()
	routes.clear()
	_credits_spent = 0.0

func _clear_history() -> void:
	_undo_stack.clear()
	_redo_stack.clear()

func _add_part_direct(parts: Array, module_id: String, start: Vector2i, rotation: int, aim: int = 0) -> void:
	var part := {"id": module_id, "start": start, "rot": posmod(rotation, 360)}
	if module_id.begins_with("cannon_"):
		part["aim"] = posmod(aim, 360)
	parts.append(part)

func place_module(module_id: String, start: Vector2i, rotation: int = 0, aim: int = 0) -> String:
	var reason := _can_place("module", module_id, start, rotation, aim)
	if not reason.is_empty():
		return reason
	_push_undo()
	_add_part_direct(module_parts, module_id, start, rotation, aim)
	_recalculate_spent()
	return ""

func place_mobility(module_id: String, start: Vector2i, rotation: int = 0) -> String:
	var reason := _can_place("mobility", module_id, start, rotation, 0)
	if not reason.is_empty():
		return reason
	_push_undo()
	_add_part_direct(mobility_parts, module_id, start, rotation)
	_recalculate_spent()
	return ""

func place_platform_cell(cell: Vector2i) -> String:
	if not _inside_grid(cell):
		return "拒绝：平台格超出建造边界。"
	if platform_occupant_at(cell).size() > 0:
		return "拒绝：平台层该格已被占用。"
	var candidate := _platform_occupancy().duplicate(true)
	candidate[cell] = true
	if not _platform_edit_keeps_connected(candidate):
		return "拒绝：新增平台必须与现有平台保持 4-连通。"
	var price := _platform_cell_price()
	if budget_enabled and credits_spent() + price > float(credits_total):
		return _credit_error(price)
	_push_undo()
	platform_cells[cell] = true
	_recalculate_spent()
	return ""

func place_platform_shape(module_id: String, start: Vector2i, rotation: int = 0) -> String:
	var reason := _can_place("platform", module_id, start, rotation, 0)
	if not reason.is_empty():
		return reason
	var shape := {"id": module_id, "start": start, "rot": posmod(rotation, 360)}
	var candidate := _platform_occupancy().duplicate(true)
	for cell in part_cells(shape):
		candidate[cell] = shape
	if not _platform_edit_keeps_connected(candidate):
		return "拒绝：新增平台必须与现有平台保持 4-连通。"
	_push_undo()
	platform_shapes.append(shape)
	_recalculate_spent()
	return ""

func paint_rectangle(from_cell: Vector2i, to_cell: Vector2i, erase: bool = false) -> String:
	var min_cell := Vector2i(mini(from_cell.x, to_cell.x), mini(from_cell.y, to_cell.y))
	var max_cell := Vector2i(maxi(from_cell.x, to_cell.x), maxi(from_cell.y, to_cell.y))
	var targets: Array[Vector2i] = []
	for y in range(min_cell.y, max_cell.y + 1):
		for x in range(min_cell.x, max_cell.x + 1):
			targets.append(Vector2i(x, y))
	return _paint_cells(targets, erase)

func paint_line(from_cell: Vector2i, to_cell: Vector2i, erase: bool = false) -> String:
	var targets: Array[Vector2i] = []
	var x0 := from_cell.x
	var y0 := from_cell.y
	var x1 := to_cell.x
	var y1 := to_cell.y
	var dx := absi(x1 - x0)
	var sx := 1 if x0 < x1 else -1
	var dy := -absi(y1 - y0)
	var sy := 1 if y0 < y1 else -1
	var error := dx + dy
	while true:
		targets.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var double_error := 2 * error
		if double_error >= dy:
			error += dy
			x0 += sx
		if double_error <= dx:
			error += dx
			y0 += sy
	return _paint_cells(targets, erase)

func _paint_cells(targets: Array[Vector2i], erase: bool) -> String:
	if targets.is_empty():
		return ""
	var unique: Dictionary = {}
	for cell in targets:
		if not _inside_grid(cell):
			return "拒绝：平台工具超出建造边界。"
		unique[cell] = true
	if erase:
		for cell in unique.keys():
			var vector_cell: Vector2i = cell
			if not platform_cells.has(vector_cell):
				continue
			if _part_at(mobility_parts, vector_cell).size() > 0 or _part_at(module_parts, vector_cell).size() > 0:
				return "拒绝：不能擦除承载模块下方的平台格。"
			if platform_shape_at(vector_cell).size() > 0:
				return "拒绝：形状平台请使用拆除操作。"
		var candidate := platform_cells.duplicate(true)
		for cell in unique.keys():
			candidate.erase(cell)
		if not _platform_edit_keeps_connected(candidate):
			return "拒绝：擦除后平台会形成断开的平台岛。"
		_push_undo()
		for cell in unique.keys():
			platform_cells.erase(cell)
		_recalculate_spent()
		return ""
	var missing := 0
	for cell in unique.keys():
		if not platform_cells.has(cell):
			missing += 1
	if missing == 0:
		return ""
	var price := float(missing) * _platform_cell_price()
	if budget_enabled and credits_spent() + price > float(credits_total):
		return _credit_error(price)
	var candidate := platform_cells.duplicate(true)
	for cell in unique.keys():
		candidate[cell] = true
	if not _platform_edit_keeps_connected(candidate):
		return "拒绝：新增平台必须与现有平台保持 4-连通。"
	_push_undo()
	for cell in unique.keys():
		platform_cells[cell] = true
	_recalculate_spent()
	return ""

func remove_at(layer: String, cell: Vector2i) -> String:
	if layer == "platform":
		if platform_cells.has(cell):
			var candidate := platform_cells.duplicate(true)
			candidate.erase(cell)
			if not _platform_edit_keeps_connected(candidate):
				return "拒绝：拆除后平台会形成断开的平台岛。"
			if _part_at(mobility_parts, cell).size() > 0 or _part_at(module_parts, cell).size() > 0:
				return "拒绝：先拆除安装在此格上的部件。"
			_push_undo()
			platform_cells.erase(cell)
			_recalculate_spent()
			return ""
		var shape_index := _shape_index_at(cell)
		if shape_index >= 0:
			_push_undo()
			platform_shapes.remove_at(shape_index)
			_recalculate_spent()
			return ""
		return "这里没有平台格。"
	var part_info := _part_at(mobility_parts if layer == "mobility" else module_parts, cell)
	if part_info.is_empty():
		return "当前层此格没有部件。"
	_push_undo()
	var parts: Array = mobility_parts if layer == "mobility" else module_parts
	parts.remove_at(int(part_info["index"]))
	_recalculate_spent()
	return ""

## 战斗摧毁专用：强制移除，跳过「断开平台岛」与「上层有部件」两项建造期约束。
## 不压撤销栈 —— 战斗中的摧毁不可撤销。返回是否真的移除了东西。
func force_remove(layer: String, cell: Vector2i) -> bool:
	var removed := false
	if layer == "platform":
		if platform_cells.has(cell):
			platform_cells.erase(cell)
			removed = true
		var shape_index := _shape_index_at(cell)
		if shape_index >= 0:
			platform_shapes.remove_at(shape_index)
			removed = true
		if removed:
			_recalculate_spent()
		return removed
	var parts: Array = mobility_parts if layer == "mobility" else module_parts
	var part_info := _part_at(parts, cell)
	if part_info.is_empty():
		return false
	parts.remove_at(int(part_info["index"]))
	_recalculate_spent()
	return true

func move_part(layer: String, from_cell: Vector2i, to_cell: Vector2i) -> String:
	var parts: Array = mobility_parts if layer == "mobility" else module_parts
	var part_info := _part_at(parts, from_cell)
	if part_info.is_empty():
		return "当前层起点没有部件。"
	var part: Dictionary = part_info["part"].duplicate(true)
	var reason := _can_move(layer, part, to_cell, int(part_info["index"]))
	if not reason.is_empty():
		return reason
	_push_undo()
	parts[int(part_info["index"])]["start"] = to_cell
	_recalculate_spent()
	return ""

func rotate_part(layer: String, cell: Vector2i, step: int = 1) -> String:
	var parts: Array = mobility_parts if layer == "mobility" else module_parts
	var part_info := _part_at(parts, cell)
	if part_info.is_empty():
		return "当前层此格没有部件。"
	var part: Dictionary = part_info["part"]
	var definition := definitions.get_module(String(part["id"]))
	if not bool(definition.get("rotatable", false)):
		return "该部件不支持旋转。"
	var next_rotation := posmod(int(part["rot"]) + step * 90, 360)
	var reason := _can_move(layer, {"id": part["id"], "start": part["start"], "rot": next_rotation, "aim": part.get("aim", 0)}, part["start"], int(part_info["index"]))
	if not reason.is_empty():
		return reason
	_push_undo()
	parts[int(part_info["index"])]["rot"] = next_rotation
	return ""

func adjust_aim(cell: Vector2i, step: int = 1) -> String:
	var part_info := _part_at(module_parts, cell)
	if part_info.is_empty():
		return "当前格没有功能模块。"
	var part: Dictionary = part_info["part"]
	if not String(part["id"]).begins_with("cannon_"):
		return "只有炮管可以调整瞄准角。"
	_push_undo()
	module_parts[int(part_info["index"])]["aim"] = posmod(int(part.get("aim", 0)) + step * 45, 360)
	return ""

func buy_mass_upgrade() -> String:
	var prices := definitions.mass_upgrade_prices()
	if mass_cap_level >= definitions.global_int("mass_cap_max_level", 5):
		return "质量上限已达到最高等级。"
	var index := mass_cap_level
	if index >= prices.size():
		return "质量升级数据缺失。"
	var price := prices[index]
	if budget_enabled and credits_spent() + price > float(credits_total):
		return _credit_error(price)
	_push_undo()
	mass_cap_level += 1
	_recalculate_spent()
	return ""

func refund_mass_upgrade() -> String:
	if mass_cap_level <= 0:
		return "当前没有可退款的质量上限等级。"
	var next_cap := mass_cap()
	var prices := definitions.mass_upgrade_prices()
	if mass_cap_level - 1 < prices.size():
		next_cap = definitions.global_number("base_mass_cap", 160.0) + float(mass_cap_level - 1) * definitions.global_number("mass_cap_step", 32.0)
	if build_mass() > next_cap:
		return "拒绝退款：当前质量 %.1f u 超过退款后的上限 %.1f u。" % [build_mass(), next_cap]
	_push_undo()
	mass_cap_level -= 1
	_recalculate_spent()
	return ""

func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_redo_stack.append(_snapshot())
	_restore(_undo_stack.pop_back())
	return true

func redo() -> bool:
	if _redo_stack.is_empty():
		return false
	_undo_stack.append(_snapshot())
	_restore(_redo_stack.pop_back())
	return true

func validation_report() -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var cockpit_count := _cockpit_count()
	if cockpit_count != 1:
		errors.append("驾驶舱：需要恰好 1 个（当前 %d）" % cockpit_count)
	if mobility_parts.is_empty():
		errors.append("行进机构：至少需要 1 个。")
	if platform_cells.is_empty() and platform_shapes.is_empty():
		errors.append("平台：至少需要 1 个平台格或形状平台。")
	_validate_platform_overlaps(errors)
	_validate_layer_overlaps(mobility_parts, "行进机构", errors)
	_validate_layer_overlaps(module_parts, "功能模块", errors)
	var platform_map := _platform_occupancy()
	for part in mobility_parts:
		_validate_part(part, platform_map, "行进机构", errors)
	for part in module_parts:
		_validate_part(part, platform_map, "功能模块", errors)
	if not _platform_is_connected(platform_map):
		errors.append("连通性：存在断开的平台岛。")
	if budget_enabled and credits_spent() > float(credits_total):
		errors.append("预算：超出信用点上限。")
	if build_mass() > mass_cap():
		errors.append("质量：%.1f u 超过上限 %.1f u。" % [build_mass(), mass_cap()])
	var volume := volume_size()
	if volume.x > grid_size.x or volume.y > grid_size.y:
		errors.append("体积：包围盒 %d×%d 超出 %d×%d。" % [volume.x, volume.y, grid_size.x, grid_size.y])
	for part in module_parts:
		if String(part["id"]).begins_with("cannon_"):
			warnings.append("I9：炮管管路连通性将在 M4 弹药网络中完整计算。")
	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings}

func _validate_part(part: Dictionary, platform_map: Dictionary, label: String, errors: Array[String]) -> void:
	var module_id := String(part.get("id", ""))
	var definition := definitions.get_module(module_id)
	if definition.is_empty():
		errors.append("%s：未知模块 %s。" % [label, module_id])
		return
	var cells := part_cells(part)
	var occupied: Dictionary = {}
	for cell in cells:
		if not _inside_grid(cell):
			errors.append("%s %s：占位超出建造边界。" % [label, module_id])
		if occupied.has(cell):
			errors.append("%s %s：内部占位重叠。" % [label, module_id])
		occupied[cell] = true
		if not platform_map.has(cell):
			errors.append("平台覆盖：%s 未落在平台上。" % module_id)

func _validate_platform_overlaps(errors: Array[String]) -> void:
	var occupied: Dictionary = {}
	for cell in platform_cells.keys():
		if occupied.has(cell):
			errors.append("平台：平台格与其他平台占位重叠。")
		occupied[cell] = true
	for index in range(platform_shapes.size()):
		for cell in part_cells(platform_shapes[index]):
			if occupied.has(cell):
				errors.append("平台：形状平台 #%d 与已有平台重叠。" % index)
			occupied[cell] = true

func _validate_layer_overlaps(parts: Array, label: String, errors: Array[String]) -> void:
	var occupied: Dictionary = {}
	for index in range(parts.size()):
		for cell in part_cells(parts[index]):
			if occupied.has(cell):
				errors.append("%s：第 %d 个部件与已有部件同层重叠。" % [label, index + 1])
			occupied[cell] = true

func _can_place(layer: String, module_id: String, start: Vector2i, rotation: int, aim: int) -> String:
	var definition := definitions.get_module(module_id)
	if definition.is_empty():
		return "拒绝：找不到模块数据 %s。" % module_id
	if layer == "platform" and String(definition.get("layer", "")) != "platform":
		return "拒绝：该模块不是平台。"
	if layer == "mobility" and String(definition.get("layer", "")) != "mobility":
		return "拒绝：该模块不是行进机构。"
	if layer == "module" and String(definition.get("layer", "")) != "module":
		return "拒绝：该模块不是功能模块。"
	if not bool(definition.get("rotatable", false)) and rotation != 0:
		return "拒绝：该模块不可旋转。"
	var part := {"id": module_id, "start": start, "rot": posmod(rotation, 360), "aim": aim}
	var cells := part_cells(part)
	for cell in cells:
		if not _inside_grid(cell):
			return "拒绝：占位超出建造边界。"
	if layer == "platform":
		for cell in cells:
			if platform_occupant_at(cell).size() > 0:
				return "拒绝：平台层占位重叠。"
	else:
		var parts: Array = mobility_parts if layer == "mobility" else module_parts
		for cell in cells:
			if _part_at(parts, cell).size() > 0:
				return "拒绝：同层占位重叠。"
			if not _platform_occupancy().has(cell):
				return "拒绝：模块必须安装在平台上。"
		if layer == "module" and bool(definition.get("core", false)) and _cockpit_count() > 0:
			return "拒绝：驾驶舱只能存在一个。"
	var added_cost := _part_cost(module_id, layer)
	var added_mass := float(definition.get("mass", 0.0))
	if budget_enabled and credits_spent() + added_cost > float(credits_total):
		return _credit_error(added_cost)
	if build_mass() + added_mass > mass_cap():
		return "拒绝：质量 %.1f u 超过 Lv.%d 上限 %.1f u。" % [build_mass() + added_mass, mass_cap_level, mass_cap()]
	return ""

func _can_move(layer: String, part: Dictionary, destination: Vector2i, ignored_index: int) -> String:
	var cells := part_cells({"id": part["id"], "start": destination, "rot": part.get("rot", 0), "aim": part.get("aim", 0)})
	for cell in cells:
		if not _inside_grid(cell):
			return "拒绝：移动后占位超出建造边界。"
		var occupant := _part_at(mobility_parts if layer == "mobility" else module_parts, cell)
		if not occupant.is_empty() and int(occupant["index"]) != ignored_index:
			return "拒绝：移动后与同层部件重叠。"
		if not _platform_occupancy().has(cell):
			return "拒绝：移动后有格子缺少平台。"
	return ""

func placement_error(layer: String, module_id: String, start: Vector2i, rotation: int = 0, aim: int = 0) -> String:
	return _can_place(layer, module_id, start, rotation, aim)

func part_cells(part: Dictionary) -> Array[Vector2i]:
	var module_id := String(part.get("id", ""))
	var definition := definitions.get_module(module_id)
	if definition.is_empty():
		return []
	var start: Vector2i = part.get("start", Vector2i.ZERO)
	var rotation := int(part.get("rot", 0))
	var offsets := definitions.rotation_offsets(module_id, int(definition.get("footprint", 1)), rotation)
	var result: Array[Vector2i] = []
	for offset in offsets:
		result.append(start + offset)
	return result

func platform_occupancy() -> Dictionary:
	return _platform_occupancy()

func platform_occupant_at(cell: Vector2i) -> Dictionary:
	if platform_cells.has(cell):
		return {"kind": "cell", "cell": cell}
	return platform_shape_at(cell)

func platform_shape_at(cell: Vector2i) -> Dictionary:
	var index := _shape_index_at(cell)
	if index < 0:
		return {}
	return {"kind": "shape", "index": index, "part": platform_shapes[index].duplicate(true)}

func part_at(layer: String, cell: Vector2i) -> Dictionary:
	return _part_at(mobility_parts if layer == "mobility" else module_parts, cell)

func credits_spent() -> float:
	return _credits_spent

func credits_remaining() -> float:
	return float(credits_total) - _credits_spent

func mass_cap() -> float:
	return definitions.global_number("base_mass_cap", 160.0) + float(mass_cap_level) * definitions.global_number("mass_cap_step", 32.0)

func build_mass() -> float:
	var total := float(platform_cells.size()) * definitions.global_number("platform_cell_mass", 1.0)
	for part in platform_shapes:
		var definition := definitions.get_module(String(part["id"]))
		total += float(definition.get("mass", 0.0))
	for part in mobility_parts + module_parts:
		var definition := definitions.get_module(String(part["id"]))
		total += float(definition.get("mass", 0.0))
	return total

## 内容包围盒（含所有层）：返回最小格与尺寸。空蓝图返回 `Rect2i(Vector2i.ZERO, Vector2i.ZERO)`。
## 用途：编辑器把坦克整体居中到建造区——否则新开的车会贴在网格左上角，
## 右侧和下方留下大片空白，玩家看不清整体形状。
func content_bounds() -> Rect2i:
	var cells: Array[Vector2i] = []
	for cell in platform_cells.keys():
		cells.append(cell)
	for part in platform_shapes + mobility_parts + module_parts:
		cells.append_array(part_cells(part))
	if cells.is_empty():
		return Rect2i(Vector2i.ZERO, Vector2i.ZERO)
	var min_cell := cells[0]
	var max_cell := cells[0]
	for cell in cells:
		min_cell = Vector2i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y))
		max_cell = Vector2i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y))
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)

## 把整车（三层一起）平移到网格中心。返回是否真的移动过。
## 为什么要整块搬而不是逐个部件摆：三层必须保持相对位置，否则平台与模块会错位。
func center_content() -> bool:
	var bounds := content_bounds()
	if bounds.size == Vector2i.ZERO:
		return false
	var offset := (grid_size - bounds.size) / 2 - bounds.position
	if offset == Vector2i.ZERO:
		return false
	var moved: Dictionary = {}
	for raw_cell in platform_cells.keys():
		var cell: Vector2i = raw_cell
		moved[cell + offset] = platform_cells[cell]
	platform_cells = moved
	for part in platform_shapes + mobility_parts + module_parts:
		part["start"] = Vector2i(part["start"]) + offset
	return true

func volume_size() -> Vector2i:
	var bounds := content_bounds()
	return bounds.size


func cockpit_cells() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for part in module_parts:
		var definition := definitions.get_module(String(part["id"]))
		if bool(definition.get("core", false)):
			result.append_array(part_cells(part))
	return result

func validation_report_summary() -> String:
	var report := validation_report()
	if report["ok"]:
		return "结构合法，可以部署。"
	return String(report["errors"][0])

func to_blueprint(name: String = "未命名蓝图") -> Dictionary:
	var sorted_cells: Array = []
	var cell_list: Array[Vector2i] = []
	for cell in platform_cells.keys():
		cell_list.append(cell)
	cell_list.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y == b.y:
			return a.x < b.x
		return a.y < b.y
	)
	for cell in cell_list:
		sorted_cells.append([cell.x, cell.y])
	var shape_list: Array = []
	for part in platform_shapes:
		shape_list.append({"id": part["id"], "pos": [part["start"].x, part["start"].y], "rot": part["rot"]})
	return {
		"format": "tankcraft.blueprint",
		"version": 2,
		"name": name,
		"size": [grid_size.x, grid_size.y],
		"economy": {"credits_total": credits_total, "credits_spent": int(roundi(credits_spent())), "mass_cap_level": mass_cap_level},
		"platform_cells": sorted_cells,
		"platform_shapes": shape_list,
		"mobility": _serialize_parts(mobility_parts),
		"modules": _serialize_parts(module_parts),
		"routes": routes.duplicate(true)
	}

func load_blueprint(data: Dictionary) -> String:
	if data.get("format", "") != "tankcraft.blueprint":
		return "拒绝读取：蓝图格式错误。"
	var next_total := int(data.get("economy", {}).get("credits_total", credits_total))
	var next_level := int(data.get("economy", {}).get("mass_cap_level", 0))
	if next_level > mass_cap_level:
		return "拒绝读取：蓝图需要质量上限 Lv.%d，请先逐级购买。" % next_level
	var candidate_platforms: Dictionary = {}
	var candidate_shapes: Array = []
	var candidate_mobility: Array = []
	var candidate_modules: Array = []
	var candidate_routes: Array = data.get("routes", []).duplicate(true)
	for raw_cell in data.get("platform_cells", []):
		if not raw_cell is Array or raw_cell.size() != 2:
			return "拒绝读取：平台格坐标格式错误。"
		var cell := Vector2i(int(raw_cell[0]), int(raw_cell[1]))
		if not _inside_grid(cell):
			return "拒绝读取：平台格超出建造边界。"
		candidate_platforms[cell] = true
	for raw_shape in data.get("platform_shapes", []):
		var shape := _parse_part(raw_shape)
		if shape.is_empty() or definitions.get_module(String(shape["id"])).get("layer", "") != "platform":
			return "拒绝读取：平台形状数据错误。"
		candidate_shapes.append(shape)
	for raw_part in data.get("mobility", []):
		var part := _parse_part(raw_part)
		if part.is_empty() or definitions.get_module(String(part["id"])).get("layer", "") != "mobility":
			return "拒绝读取：行进机构数据错误。"
		candidate_mobility.append(part)
	for raw_part in data.get("modules", []):
		var part := _parse_part(raw_part)
		if part.is_empty() or definitions.get_module(String(part["id"])).get("layer", "") != "module":
			return "拒绝读取：功能模块数据错误。"
		candidate_modules.append(part)
	var before := _snapshot()
	var before_total := credits_total
	var before_level := mass_cap_level
	platform_cells = candidate_platforms
	platform_shapes = candidate_shapes
	mobility_parts = candidate_mobility
	module_parts = candidate_modules
	routes = candidate_routes
	credits_total = next_total
	mass_cap_level = next_level
	_recalculate_spent()
	var report := validation_report()
	if not report["ok"]:
		_restore(before)
		credits_total = before_total
		mass_cap_level = before_level
		return "拒绝读取：%s" % report["errors"][0]
	_push_snapshot_to_undo(before)
	_redo_stack.clear()
	return ""

func _parse_part(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var module_id := String(raw.get("id", ""))
	var pos: Variant = raw.get("pos", [0, 0])
	if not pos is Array or pos.size() != 2 or definitions.get_module(module_id).is_empty():
		return {}
	var part := {"id": module_id, "start": Vector2i(int(pos[0]), int(pos[1])), "rot": int(raw.get("rot", 0))}
	if module_id.begins_with("cannon_"):
		part["aim"] = int(raw.get("aim", 0))
	return part

func _serialize_parts(parts: Array) -> Array:
	var result: Array = []
	for part in parts:
		var item := {"id": part["id"], "pos": [part["start"].x, part["start"].y], "rot": part["rot"]}
		if String(part["id"]).begins_with("cannon_"):
			item["aim"] = part.get("aim", 0)
		result.append(item)
	return result

func _platform_occupancy() -> Dictionary:
	var result := platform_cells.duplicate(true)
	for part in platform_shapes:
		for cell in part_cells(part):
			result[cell] = part
	return result

func _part_at(parts: Array, cell: Vector2i) -> Dictionary:
	for index in range(parts.size()):
		var part: Dictionary = parts[index]
		if cell in part_cells(part):
			return {"index": index, "part": part}
	return {}

func _shape_index_at(cell: Vector2i) -> int:
	for index in range(platform_shapes.size()):
		if cell in part_cells(platform_shapes[index]):
			return index
	return -1

func _cockpit_count() -> int:
	var count := 0
	for part in module_parts:
		var definition := definitions.get_module(String(part["id"]))
		if bool(definition.get("core", false)):
			count += 1
	return count

func _platform_is_connected(platform_map: Dictionary) -> bool:
	if platform_map.is_empty():
		return true
	var cockpit := cockpit_cells()
	if cockpit.is_empty():
		var first: Vector2i = platform_map.keys()[0]
		return _reachable_count(platform_map, first) == platform_map.size()
	var start := cockpit[0]
	if not platform_map.has(start):
		return false
	return _reachable_count(platform_map, start) == platform_map.size()

func _platform_edit_keeps_connected(candidate: Dictionary) -> bool:
	if candidate.is_empty():
		return true
	return _platform_is_connected(candidate)

func _reachable_count(platform_map: Dictionary, start: Vector2i) -> int:
	if not platform_map.has(start):
		return 0
	var reached: Dictionary = {start: true}
	var pending: Array[Vector2i] = [start]
	while not pending.is_empty():
		var current: Vector2i = pending.pop_front()
		for direction in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
			var next: Vector2i = current + direction
			if platform_map.has(next) and not reached.has(next):
				reached[next] = true
				pending.append(next)
	return reached.size()

func _inside_grid(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.x < grid_size.x and cell.y < grid_size.y

func _platform_cell_price() -> float:
	return definitions.global_number("platform_cell_price", 4.0)

func _part_cost(module_id: String, layer: String) -> float:
	if layer == "platform":
		return float(definitions.get_module(module_id).get("price", 0.0))
	return float(definitions.get_module(module_id).get("price", 0.0))

func _credit_error(cost: float) -> String:
	var missing := maxi(int(ceilf(credits_spent() + cost - float(credits_total))), 0)
	return "拒绝：信用点不足（还差 %d cr）。" % missing

func _recalculate_spent() -> void:
	var total := float(mass_upgrade_spent())
	total += float(platform_cells.size()) * _platform_cell_price()
	for part in platform_shapes + mobility_parts + module_parts:
		total += float(definitions.get_module(String(part["id"])).get("price", 0.0))
	_credits_spent = total

func mass_upgrade_spent() -> float:
	var total := 0.0
	var prices := definitions.mass_upgrade_prices()
	for index in range(mini(mass_cap_level, prices.size())):
		total += prices[index]
	return total

func _snapshot() -> Dictionary:
	return {
		"platform_cells": platform_cells.duplicate(true),
		"platform_shapes": platform_shapes.duplicate(true),
		"mobility_parts": mobility_parts.duplicate(true),
		"module_parts": module_parts.duplicate(true),
		"routes": routes.duplicate(true),
		"credits_total": credits_total,
		"mass_cap_level": mass_cap_level
	}

func _restore(snapshot: Dictionary) -> void:
	platform_cells = snapshot["platform_cells"].duplicate(true)
	platform_shapes = snapshot["platform_shapes"].duplicate(true)
	mobility_parts = snapshot["mobility_parts"].duplicate(true)
	module_parts = snapshot["module_parts"].duplicate(true)
	routes = snapshot["routes"].duplicate(true)
	credits_total = int(snapshot["credits_total"])
	mass_cap_level = int(snapshot["mass_cap_level"])
	_recalculate_spent()

func _push_undo() -> void:
	_push_snapshot_to_undo(_snapshot())
	_redo_stack.clear()

func _push_snapshot_to_undo(snapshot: Dictionary) -> void:
	_undo_stack.append(snapshot)
	while _undo_stack.size() > _history_depth:
		_undo_stack.pop_front()
