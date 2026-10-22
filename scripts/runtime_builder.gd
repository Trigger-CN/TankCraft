extends RefCounted

## M2 运行期原地建造（BUILD_MODE）。
## 仅在 EXPEDITION 可用：scrap 支付 + 按格施工计时 + 受击中断 + 拆解返还。
## 结构规则（I1–I10）完全委托 GridBuilder 副本校验，本脚本只负责运行期结算。

const GridBuilder := preload("res://scripts/grid_builder.gd")
const ModuleDefs := preload("res://scripts/module_defs.gd")

const MODE_EXPEDITION := "EXPEDITION"

const LAYER_PLATFORM := "platform"
const LAYER_MOBILITY := "mobility"
const LAYER_MODULE := "module"

const PLATFORM_CELL_ID := "platform_cell"

var definitions: ModuleDefs
## 运行期坦克状态。运行期不用信用点预算，全部支出走 scrap。
var builder: GridBuilder
## 当前对局模式标签：只有 EXPEDITION 允许进入 BUILD_MODE。
var mode := MODE_EXPEDITION
var scrap := 0.0
var in_build_mode := false
## 同时只允许一个施工任务：设计未规定并发，这里采用最简模型。
var pending: Dictionary = {}

var _build_rate := 1.0
var _refund_rate := 0.5
var _seconds_per_cell := 0.6

func setup(module_defs: ModuleDefs) -> bool:
	if module_defs == null or module_defs.registry == null:
		return false
	definitions = module_defs
	builder = GridBuilder.new()
	if not builder.setup(definitions):
		builder = null
		return false
	# 运行期付 scrap，信用点预算检查必须关闭；编辑器使用独立实例，不受影响。
	builder.budget_enabled = false
	var expedition: Dictionary = {}
	var raw: Variant = definitions.registry.globals.get("expedition", {})
	if raw is Dictionary:
		expedition = raw
	_build_rate = float(expedition.get("scrap_build_rate", 1.0))
	_refund_rate = float(expedition.get("scrap_refund", 0.5))
	_seconds_per_cell = float(expedition.get("build_time_per_cell_s", 0.6))
	return true

func seed_from_blueprint(data: Dictionary) -> String:
	if builder == null:
		return "拒绝：运行期建造尚未初始化。"
	pending = {}
	return builder.load_blueprint(data)

func reset_demo() -> void:
	if builder != null:
		builder.reset_demo()

func set_mode(next_mode: String) -> void:
	if mode == next_mode:
		return
	mode = next_mode
	if mode != MODE_EXPEDITION:
		exit_build_mode()

func set_scrap(value: float) -> void:
	scrap = maxf(value, 0.0)

func add_scrap(amount: float) -> void:
	scrap = maxf(scrap + amount, 0.0)

func movement_locked() -> bool:
	return in_build_mode

func is_building() -> bool:
	return not pending.is_empty()

func enter_build_mode() -> String:
	if mode != MODE_EXPEDITION:
		return "拒绝：原地建造仅在 EXPEDITION 可用。"
	if builder == null:
		return "拒绝：运行期建造尚未初始化。"
	in_build_mode = true
	return ""

func exit_build_mode() -> String:
	var note := ""
	if not pending.is_empty():
		var cost := float(pending.get("cost", 0.0))
		pending = {}
		note = "退出建造模式，施工中断：已投入的 %.1f scrap 不返还。" % cost
	in_build_mode = false
	return note

func price_of(layer: String, module_id: String) -> float:
	if definitions != null:
		var definition: Dictionary = definitions.get_module(module_id)
		if not definition.is_empty():
			return float(definition.get("price", 0.0))
		if layer == LAYER_PLATFORM:
			return definitions.global_number("platform_cell_price", 4.0)
	return 0.0

func build_cost(layer: String, module_id: String) -> float:
	return price_of(layer, module_id) * _build_rate

func can_afford(layer: String, module_id: String) -> bool:
	return scrap + 0.0001 >= build_cost(layer, module_id)

func request_build(layer: String, module_id: String, start: Vector2i, rotation: int = 0, aim: int = 0) -> String:
	if mode != MODE_EXPEDITION:
		return "拒绝：原地建造仅在 EXPEDITION 可用。"
	if not in_build_mode:
		return "拒绝：需先进入建造模式。"
	if not pending.is_empty():
		return "拒绝：已有施工正在进行。"
	var scratch := _scratch_copy()
	if scratch == null:
		return "拒绝：建造规则引擎不可用。"
	var reason := _apply_to(scratch, layer, module_id, start, rotation, aim)
	if not reason.is_empty():
		return reason
	var report: Dictionary = scratch.validation_report()
	if not bool(report.get("ok", false)):
		return "拒绝：%s" % String(report["errors"][0])
	var probe := {"id": module_id, "start": start, "rot": posmod(rotation, 360), "aim": aim}
	var cells: Array[Vector2i] = scratch.part_cells(probe)
	if cells.is_empty():
		return "拒绝：找不到 %s 的占位数据。" % module_id
	var cost := build_cost(layer, module_id)
	if scrap + 0.0001 < cost:
		return "拒绝：scrap 不足（需要 %.1f，当前 %.1f）。" % [cost, scrap]
	scrap -= cost
	pending = {
		"layer": layer,
		"module_id": module_id,
		"start": start,
		"rot": posmod(rotation, 360),
		"aim": aim,
		"cells": cells,
		"cost": cost,
		"elapsed": 0.0,
		"duration": maxf(float(cells.size()) * _seconds_per_cell, 0.001),
	}
	return ""

func tick(delta: float) -> String:
	if pending.is_empty() or delta <= 0.0:
		return ""
	pending["elapsed"] = float(pending["elapsed"]) + delta
	if float(pending["elapsed"]) + 0.000001 < float(pending["duration"]):
		return ""
	var layer := String(pending["layer"])
	var module_id := String(pending["module_id"])
	var start: Vector2i = pending["start"]
	var rotation := int(pending["rot"])
	var aim := int(pending["aim"])
	var cost := float(pending["cost"])
	pending = {}
	var reason := _apply_to(builder, layer, module_id, start, rotation, aim)
	if not reason.is_empty():
		return "施工失败：%s（已投入的 %.1f scrap 不返还）" % [reason, cost]
	return "施工完成：%s（%.1f scrap）" % [module_id, cost]

func notify_hit(cell: Vector2i) -> String:
	if pending.is_empty():
		return ""
	var cells: Array = pending["cells"]
	if cells.find(cell) < 0:
		return ""
	var module_id := String(pending["module_id"])
	var cost := float(pending["cost"])
	pending = {}
	return "施工被击中中断：%s（已投入的 %.1f scrap 不返还）" % [module_id, cost]

func request_dismantle(layer: String, cell: Vector2i) -> String:
	if mode != MODE_EXPEDITION:
		return "拒绝：原地拆解仅在 EXPEDITION 可用。"
	if not in_build_mode:
		return "拒绝：需先进入建造模式。"
	if not pending.is_empty():
		return "拒绝：施工进行中不能拆解。"
	var module_id := _module_at(layer, cell)
	if module_id.is_empty():
		return "当前层此格没有部件。"
	var definition: Dictionary = definitions.get_module(module_id)
	if bool(definition.get("core", false)):
		return "拒绝：驾驶舱不能被拆解。"
	var scratch := _scratch_copy()
	if scratch == null:
		return "拒绝：建造规则引擎不可用。"
	var reason := scratch.remove_at(layer, cell)
	if not reason.is_empty():
		return reason
	var report: Dictionary = scratch.validation_report()
	if not bool(report.get("ok", false)):
		return "拒绝：%s" % String(report["errors"][0])
	reason = builder.remove_at(layer, cell)
	if not reason.is_empty():
		return reason
	scrap += price_of(layer, module_id) * _refund_rate
	return ""

func purchase_mass_upgrade() -> String:
	if mode != MODE_EXPEDITION:
		return "拒绝：运行期质量升级仅在 EXPEDITION 可用。"
	if not in_build_mode:
		return "拒绝：需先进入建造模式。"
	if builder == null:
		return "拒绝：运行期建造尚未初始化。"
	var prices := definitions.mass_upgrade_prices()
	var level := builder.mass_cap_level
	if level >= prices.size():
		return builder.buy_mass_upgrade()
	var price := prices[level] * _build_rate
	if scrap + 0.0001 < price:
		return "拒绝：scrap 不足（需要 %.1f，当前 %.1f）。" % [price, scrap]
	var reason := builder.buy_mass_upgrade()
	if not reason.is_empty():
		return reason
	scrap -= price
	return ""

func part_at_module(cell: Vector2i) -> Dictionary:
	if builder == null:
		return {}
	return builder.part_at(LAYER_MODULE, cell)

func part_at_mobility(cell: Vector2i) -> Dictionary:
	if builder == null:
		return {}
	return builder.part_at(LAYER_MOBILITY, cell)

func pending_info() -> Dictionary:
	if pending.is_empty():
		return {}
	var duration := maxf(float(pending["duration"]), 0.001)
	return {
		"layer": pending["layer"],
		"module_id": pending["module_id"],
		"start": pending["start"],
		"cells": pending["cells"].duplicate(),
		"cost": pending["cost"],
		"elapsed": pending["elapsed"],
		"duration": pending["duration"],
		"progress": clampf(float(pending["elapsed"]) / duration, 0.0, 1.0),
	}

func _apply_to(target: GridBuilder, layer: String, module_id: String, start: Vector2i, rotation: int, aim: int) -> String:
	if layer == LAYER_PLATFORM:
		if module_id == PLATFORM_CELL_ID:
			if posmod(rotation, 360) != 0:
				return "拒绝：手绘平台格不支持旋转。"
			return target.place_platform_cell(start)
		return target.place_platform_shape(module_id, start, rotation)
	if layer == LAYER_MOBILITY:
		return target.place_mobility(module_id, start, rotation)
	if layer == LAYER_MODULE:
		return target.place_module(module_id, start, rotation, aim)
	return "拒绝：未知建造层 %s。" % layer

func _scratch_copy() -> GridBuilder:
	if builder == null:
		return null
	var scratch := GridBuilder.new()
	if not scratch.setup(definitions):
		return null
	scratch.platform_cells = builder.platform_cells.duplicate(true)
	scratch.platform_shapes = builder.platform_shapes.duplicate(true)
	scratch.mobility_parts = builder.mobility_parts.duplicate(true)
	scratch.module_parts = builder.module_parts.duplicate(true)
	scratch.routes = builder.routes.duplicate(true)
	scratch.mass_cap_level = builder.mass_cap_level
	scratch.credits_total = builder.credits_total
	scratch.budget_enabled = false
	return scratch

func _module_at(layer: String, cell: Vector2i) -> String:
	if builder == null:
		return ""
	if layer == LAYER_PLATFORM:
		var occupant: Dictionary = builder.platform_occupant_at(cell)
		if occupant.is_empty():
			return ""
		if String(occupant.get("kind", "")) == "cell":
			return PLATFORM_CELL_ID
		var shape: Dictionary = occupant.get("part", {})
		return String(shape.get("id", ""))
	var part_info: Dictionary = builder.part_at(layer, cell)
	if part_info.is_empty():
		return ""
	var part: Dictionary = part_info["part"]
	return String(part.get("id", ""))
