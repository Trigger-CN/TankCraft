extends SceneTree

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all():
		printerr("BUILD_DATA_FAILED")
		quit(1)
		return
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		printerr("BUILD_SETUP_FAILED")
		quit(1)
		return
	builder.reset_demo()
	var initial := builder.to_blueprint("smoke")
	var initial_report: Dictionary = builder.validation_report()
	if not initial_report["ok"]:
		printerr("BUILD_DEMO_INVALID %s" % initial_report["errors"])
		quit(1)
		return
	var placed := builder.place_platform_cell(Vector2i(5, 6))
	if not placed.is_empty():
		printerr("BUILD_PLATFORM_FAILED %s" % placed)
		quit(1)
		return
	var isolated := GridBuilder.new()
	if not isolated.setup(definitions):
		printerr("BUILD_ISOLATED_SETUP_FAILED")
		quit(1)
		return
	isolated.reset_demo()
	var isolated_result := isolated.place_platform_cell(Vector2i(0, 0))
	if isolated_result.is_empty():
		printerr("BUILD_ISOLATED_PLATFORM_ACCEPTED")
		quit(1)
		return
	var shape_result := builder.place_platform_shape("plat_1x2", Vector2i(14, 8), 0)
	if not shape_result.is_empty() or builder.platform_occupancy().size() < 42:
		printerr("BUILD_SHAPE_FAILED %s" % shape_result)
		quit(1)
		return
	var rejected := builder.place_module("cannon_76", Vector2i(5, 6), 0, 45)
	if not rejected.is_empty():
		printerr("BUILD_MODULE_FAILED %s" % rejected)
		quit(1)
		return
	var undo_ok := builder.undo()
	var redo_ok := builder.redo()
	if not undo_ok or not redo_ok:
		printerr("BUILD_HISTORY_FAILED undo=%s redo=%s" % [undo_ok, redo_ok])
		quit(1)
		return
	var moved := builder.move_part("module", Vector2i(9, 8), Vector2i(10, 8))
	if not moved.is_empty():
		printerr("BUILD_MOVE_FAILED %s" % moved)
		quit(1)
		return
	builder.move_part("module", Vector2i(10, 8), Vector2i(9, 8))
	var rotated := builder.rotate_part("module", Vector2i(10, 7))
	if not rotated.is_empty():
		printerr("BUILD_ROTATE_FAILED %s" % rotated)
		quit(1)
		return
	builder.rotate_part("module", Vector2i(10, 7), -1)
	var blueprint := builder.to_blueprint("smoke")
	var invalid_blueprint := blueprint_with_overlap(blueprint)
	var invalid_loader := GridBuilder.new()
	if not invalid_loader.setup(definitions) or invalid_loader.load_blueprint(invalid_blueprint).is_empty():
		printerr("BUILD_INVALID_BLUEPRINT_ACCEPTED")
		quit(1)
		return
	var line_result := builder.paint_line(Vector2i(4, 6), Vector2i(4, 8))
	if not line_result.is_empty():
		printerr("BUILD_LINE_FAILED %s" % line_result)
		quit(1)
		return
	var second := GridBuilder.new()
	if not second.setup(definitions) or not second.load_blueprint(blueprint).is_empty():
		printerr("BUILD_BLUEPRINT_LOAD_FAILED")
		quit(1)
		return
	var reloaded := second.to_blueprint("smoke")
	if JSON.stringify(blueprint) != JSON.stringify(reloaded):
		printerr("BUILD_BLUEPRINT_UNSTABLE")
		quit(1)
		return
	## v3.18：居中。`reset_demo()` 把车放在 (6,6)，在 24×24 网格里偏左上；
	## `center_content()` 必须把整车搬到正中，且**不改尺寸与花费**。
	var before_volume: Vector2i = second.volume_size()
	var before_spent := second.credits_spent()
	var before_mass := second.build_mass()
	var before_bounds: Rect2i = second.content_bounds()
	if not second.center_content():
		printerr("BUILD_CENTER_NOOP bounds=%s" % str(before_bounds))
		quit(1)
		return
	var centered: Rect2i = second.content_bounds()
	if centered.size != before_volume:
		printerr("BUILD_CENTER_CHANGED_SIZE %s -> %s" % [str(before_volume), str(centered.size)])
		quit(1)
		return
	if not is_equal_approx(second.credits_spent(), before_spent) or not is_equal_approx(second.build_mass(), before_mass):
		printerr("BUILD_CENTER_CHANGED_COST spent %.1f -> %.1f mass %.1f -> %.1f" % [before_spent, second.credits_spent(), before_mass, second.build_mass()])
		quit(1)
		return
	## 居中后左右边距差、上下边距差都必须 ≤ 1 格（奇偶尺寸不可能完全相等）。
	var left_margin := centered.position.x
	var right_margin := second.grid_size.x - centered.end.x
	var top_margin := centered.position.y
	var bottom_margin := second.grid_size.y - centered.end.y
	if absi(left_margin - right_margin) > 1 or absi(top_margin - bottom_margin) > 1:
		printerr("BUILD_CENTER_NOT_CENTERED margins L%d R%d T%d B%d" % [left_margin, right_margin, top_margin, bottom_margin])
		quit(1)
		return
	## 居中只改位置：再居中一次应该是空操作（否则会每帧漂移）。
	if second.center_content():
		printerr("BUILD_CENTER_NOT_IDEMPOTENT")
		quit(1)
		return
	print("BUILD_OK cells=%d modules=%d mobility=%d spent=%d mass=%.1f" % [second.platform_occupancy().size(), second.module_parts.size(), second.mobility_parts.size(), int(second.credits_spent()), second.build_mass()])
	quit(0)

func blueprint_with_overlap(source: Dictionary) -> Dictionary:
	var result: Dictionary = source.duplicate(true)
	var modules: Array = result["modules"]
	if not modules.is_empty():
		modules.append(modules[0].duplicate(true))
	result["modules"] = modules
	return result
