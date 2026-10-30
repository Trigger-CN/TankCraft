extends SceneTree

## v3.25 鼠标瞄准回归（design §6.5 / §11.4.2.10）。
##
## 覆盖：
##  - `aim_at()` 后 `muzzle_dir()` 等于「炮管中心 → 目标」的世界方向（容差 1e-4）；
##  - `aim_at()` 与 `body.heading` 解耦（转动车体不改变弹道方向）；
##  - `clear_aim_override()` 后 `muzzle_dir()` 回到建造期 `heading + deg_to_rad(aim)`；
##  - `aim_all_at()` 让多门炮指向同一点，返回值与真正改变方向的炮管数一致；
##  - `aim_at()` 对非法下标返回 false **且不改状态**；
##  - 目标与炮管中心重合时保持原方向（`atan2(0,0)` 的防护）；
##  - `CombatView.to_screen()` → `main._screen_to_world()` 往返一致。
##
## 硬约束：本测试**不调任何绘制函数**（在 `_draw()` 之外调绘制会刷屏上千行
## `Drawing is only allowed inside this node's _draw()`，把断言淹掉）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const CombatView := preload("res://scripts/combat_view.gd")
const MainScript := preload("res://scripts/main.gd")

const TOL := 0.0001

var _failures := 0

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all("res://data"):
		_fail("AIM_FAIL_DATA")
		return
	var rig := _make_rig(definitions)
	if rig.is_empty():
		return
	var body: TankBody = rig["body"]
	var bank: CannonBank = rig["bank"]
	if bank.cannons.size() != 2:
		_fail("AIM_FAIL_CANNON_COUNT:%d" % bank.cannons.size())
		return

	_check_aim_at(body, bank)
	_check_decoupled_from_heading(body, bank)
	_check_clear(body, bank)
	_check_aim_all(body, bank)
	_check_bad_index(bank)
	_check_coincident_target(body, bank)
	_check_round_trip()

	if _failures == 0:
		print("AIM_OK cannons=%d" % bank.cannons.size())
		quit(0)
		return
	quit(1)

func _fail(code: String) -> void:
	_failures += 1
	printerr(code)

func _check(condition: bool, code: String) -> void:
	if not condition:
		_fail(code)

func _check_near(actual: float, expected: float, code: String) -> void:
	if absf(actual - expected) > TOL:
		_fail("%s actual=%.6f expected=%.6f" % [code, actual, expected])

## 两门 76 炮 + 驾驶舱 + 引擎 + 双履带的对称底盘（形状照 `cannon_smoke._make_rig()`）。
func _make_rig(definitions: ModuleDefs) -> Dictionary:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("AIM_FAIL_BUILDER")
		return {}
	builder.budget_enabled = false
	builder.credits_total = 100000
	for y in range(4, 11):
		for x in range(4, 10):
			builder.place_platform_cell(Vector2i(x, y))
	builder.place_mobility("track_light", Vector2i(4, 4), 0)
	builder.place_mobility("track_light", Vector2i(4, 10), 0)
	builder.place_module("cockpit_light", Vector2i(4, 7), 0, 0)
	builder.place_module("engine_medium", Vector2i(5, 7), 0, 0)
	for cannon_cell in [Vector2i(8, 4), Vector2i(8, 8)]:
		var note := builder.place_module("cannon_76", cannon_cell, 0, 0)
		if not note.is_empty():
			_fail("AIM_FAIL_CANNON:%s" % note)
			return {}
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("AIM_FAIL_BODY")
		return {}
	body.position = Vector2(1024.0, 576.0)
	var bank := CannonBank.new()
	if not bank.setup(definitions, body):
		_fail("AIM_FAIL_BANK")
		return {}
	return {"body": body, "bank": bank}

## `aim_at()` 之后弹道方向必须等于「炮管中心 → 目标」，且与车体朝向无关。
func _check_aim_at(body: TankBody, bank: CannonBank) -> void:
	body.heading = 0.0
	var target := Vector2(1600.0, 300.0)
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
		var expected := (target - centre).normalized()
		_check(bank.aim_at(index, target), "aim_at_changed_%d" % index)
		var got := bank.muzzle_dir(cannon)
		_check_near(got.x, expected.x, "aim_at_dir_x_%d" % index)
		_check_near(got.y, expected.y, "aim_at_dir_y_%d" % index)
		## 再次指向同一点：方向没变，返回 false（这是「没变」而不是失败）。
		_check(not bank.aim_at(index, target), "aim_at_same_target_%d" % index)

## 转动车体不得改变已覆盖的弹道方向——这正是「鼠标瞄准」与旧「靠车身转向」的区别。
func _check_decoupled_from_heading(body: TankBody, bank: CannonBank) -> void:
	var target := Vector2(300.0, 900.0)
	bank.aim_all_at(target)
	var cannon: Dictionary = bank.cannons[0]
	var before := bank.muzzle_dir(cannon)
	body.heading = 2.1
	var after := bank.muzzle_dir(cannon)
	_check_near(after.x, before.x, "decoupled_x")
	_check_near(after.y, before.y, "decoupled_y")
	## 对照：同样的车体转动，在**没有覆盖**时方向必须跟着转（旧语义仍然成立）。
	bank.clear_aim_override()
	var legacy := bank.muzzle_dir(cannon)
	var aim_rad := deg_to_rad(float(cannon["aim"]))
	_check_near(legacy.x, cos(2.1 + aim_rad), "legacy_x")
	_check_near(legacy.y, sin(2.1 + aim_rad), "legacy_y")

## `clear_aim_override()` 必须把方向交还给建造期 `aim`，且清掉两个字段。
func _check_clear(body: TankBody, bank: CannonBank) -> void:
	body.heading = 0.4
	bank.aim_all_at(Vector2(50.0, 50.0))
	bank.clear_aim_override()
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		_check(not bool(cannon["aim_override"]), "clear_flag_%d" % index)
		_check_near(float(cannon["aim_world"]), 0.0, "clear_world_%d" % index)
		var aim_rad := deg_to_rad(float(cannon["aim"]))
		var dir := bank.muzzle_dir(cannon)
		_check_near(dir.x, cos(0.4 + aim_rad), "clear_dir_x_%d" % index)
		_check_near(dir.y, sin(0.4 + aim_rad), "clear_dir_y_%d" % index)

## 多门炮指向同一点，返回值 = 真正改变的炮管数。
func _check_aim_all(body: TankBody, bank: CannonBank) -> void:
	body.heading = 1.0
	var target := Vector2(1200.0, 1200.0)
	var moved := bank.aim_all_at(target)
	_check(moved == bank.cannons.size(), "aim_all_moved_%d" % moved)
	_check(bank.aim_all_at(target) == 0, "aim_all_idempotent")
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
		var expected := (target - centre).normalized()
		var got := bank.muzzle_dir(cannon)
		_check_near(got.x, expected.x, "aim_all_dir_x_%d" % index)
		_check_near(got.y, expected.y, "aim_all_dir_y_%d" % index)

## 非法下标必须拒收，且**不得写脏**已有炮管的状态。
func _check_bad_index(bank: CannonBank) -> void:
	var cannon: Dictionary = bank.cannons[0]
	var flag_before := bool(cannon["aim_override"])
	var world_before := float(cannon["aim_world"])
	_check(not bank.aim_at(-1, Vector2(10.0, 10.0)), "bad_index_negative")
	_check(not bank.aim_at(bank.cannons.size(), Vector2(10.0, 10.0)), "bad_index_over")
	_check(bool(cannon["aim_override"]) == flag_before, "bad_index_flag_unchanged")
	_check_near(float(cannon["aim_world"]), world_before, "bad_index_world_unchanged")

## 目标与炮管中心重合：必须保持原方向（不能突然甩到 +X）。
func _check_coincident_target(body: TankBody, bank: CannonBank) -> void:
	var cannon: Dictionary = bank.cannons[0]
	bank.clear_aim_override()
	body.heading = 0.0
	var before := bank.muzzle_dir(cannon)
	var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
	_check(not bank.aim_at(0, centre), "coincident_rejected")
	_check(not bool(cannon["aim_override"]), "coincident_no_override")
	var after := bank.muzzle_dir(cannon)
	_check_near(after.x, before.x, "coincident_dir_x")
	_check_near(after.y, before.y, "coincident_dir_y")

## 屏幕坐标 → 世界坐标必须是 `CombatView.to_screen()` 的精确逆变换。
## v3.38：相机矩形显式传入（zoom==1 时它就是 `arena`，与旧版逐位相同）。
func _check_round_trip() -> void:
	var view := Rect2(320.0, 168.0, 1216.0, 684.0)
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	var camera := CombatView.camera_rect(arena, arena.get_center(), 1.0)
	var scale_factor := CombatView.fit_scale(view, camera)
	for world in [Vector2(0.0, 0.0), Vector2(1024.0, 576.0), Vector2(2047.0, 1151.0)]:
		var screen := CombatView.to_screen(view, camera, world, scale_factor)
		var back: Vector2 = MainScript._screen_to_world(view, camera, screen, scale_factor)
		_check_near(back.x, world.x, "round_trip_x_%.0f" % world.x)
		_check_near(back.y, world.y, "round_trip_y_%.0f" % world.y)
	## 退化比例必须回退到相机原点，而不是除零。
	var zero: Vector2 = MainScript._screen_to_world(view, camera, Vector2(0.0, 0.0), 0.0)
	_check_near(zero.x, camera.position.x, "round_trip_zero_scale_x")
	_check_near(zero.y, camera.position.y, "round_trip_zero_scale_y")
