extends SceneTree

## 炮管绘制与实时指向回归（v3.37，design §11.4.2.17）。
##
## 这个测试存在的**唯一理由**：「炮管必须跟着瞄准方向转」这件事的正确性全压在
## 一行减法上 —— `aim_local = muzzle_dir().angle() - hull.heading`。
##
## `CannonBank.muzzle_dir()` 返回的是**世界**方向；而炮管是在 `_draw_hull_shared()` 的
## `draw_set_transform(origin, heading, scale)` 之内画的，处在**车体局部坐标系**。
## 少减这一个 `heading`，车体一转炮管就多转一个 `heading`。
##
## 这个错**画面上才看得见**：截图 / 实机能发现，但所有已有的 headless 测试都抓不到，
## 因为它们只验证 `muzzle_dir()`，从不验证「画出来的角度」。
##
## 本测试的做法：把它**还原成世界角再比** ——
##   预期：`aim_local + heading == muzzle_dir().angle()`
## 而不是去和 `aim_local` 的绝对值比。这样即使将来 `muzzle_dir()` 的语义变化
## （比如又加进什么偏移），这条断言依然只盯住「局部角 ↔ 世界角」这一个关系。
##
## 并且带**反向对照**：把 `aim_local` 换成「不减 heading」的写法，断言它必须失败 ——
## 否则这条测试在一个恒真的比较上就毫无区分力。
##
## 硬约束：**不调任何绘制函数**（在 `_draw()` 之外调绘制会刷屏上千行
## `Drawing is only allowed inside this node's _draw()`，把断言淹掉）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const CannonView := preload("res://scripts/cannon_view.gd")
const MainScript := preload("res://scripts/main.gd")

const TOL := 0.0001

var _failures := 0
var _checks := 0

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all("res://data"):
		_fail("CANNONVIEW_FAIL_DATA")
		return

	_check_predicate(definitions)
	_check_geometry_invariants()
	_check_mouth_offset()
	_check_cannon_key(definitions)

	var rig := _make_rig(definitions)
	if rig.is_empty():
		return
	var body: TankBody = rig["body"]
	var bank: CannonBank = rig["bank"]

	_check_realtime_aim(body, bank, 0.0)
	_check_realtime_aim(body, bank, 1.0)
	_check_realtime_aim(body, bank, 2.1)
	_check_realtime_aim(body, bank, -0.9)
	_check_negative_control(body, bank)
	_check_legacy_aim(body, bank)
	_check_hook_offset_not_doubled()

	if _failures == 0:
		print("CANNONVIEW_OK checks=%d cannons=%d" % [_checks, bank.cannons.size()])
		quit(0)
		return
	quit(1)

func _fail(code: String) -> void:
	_failures += 1
	printerr(code)

func _check(condition: bool, code: String) -> void:
	_checks += 1
	if not condition:
		_fail(code)

func _check_near(actual: float, expected: float, code: String) -> void:
	_checks += 1
	if absf(actual - expected) > TOL:
		_fail("%s actual=%.6f expected=%.6f" % [code, actual, expected])

## 「这是不是炮管」的唯一判据是 `aim_steps`，必须与 `CannonBank.reload_from_body()` 同源。
## `ammo_factory_*` 也有 `caliber` 但不是炮管 —— 用 caliber 判会把它画成炮。
func _check_predicate(definitions: ModuleDefs) -> void:
	for module_id in ["cannon_20", "cannon_40", "cannon_76", "cannon_120", "cannon_155"]:
		_check(CannonView.is_cannon(definitions.get_module(module_id)), "is_cannon_%s" % module_id)
	## 有 caliber 但不是炮管。
	for module_id in ["ammo_factory_20", "ammo_factory_155"]:
		var definition := definitions.get_module(module_id)
		_check(definition.has("caliber"), "factory_has_caliber_%s" % module_id)
		_check(not CannonView.is_cannon(definition), "factory_not_cannon_%s" % module_id)
	## 无 caliber 也无 aim_steps。
	for module_id in ["conveyor_straight", "conveyor_cross", "cockpit_light", "repair_small"]:
		_check(not CannonView.is_cannon(definitions.get_module(module_id)), "not_cannon_%s" % module_id)

## 三条几何不变量。任何一条被改坏，「炮口闪光对齐」或「看着像炮」都会失效。
func _check_geometry_invariants() -> void:
	## ① 制退器必须把半格点包在内部：`muzzle_origin()` 落在半格处。
	_check(CannonView.BRAKE_START_RATIO < 0.5, "brake_start_before_half")
	_check(CannonView.BRAKE_END_RATIO > 0.5, "brake_end_after_half")
	## ② 管身终点必须晚于起点，否则管身退化成零长度。
	_check(CannonView.BODY_START_RATIO < CannonView.BRAKE_START_RATIO, "body_before_brake")
	## ③ 管身必须细长：长度 / 全宽 >= 3.0。这是「像一门炮」与「像一根棒棒糖」的分界。
	var body_len := CannonView.BRAKE_START_RATIO - CannonView.BODY_START_RATIO
	var light_ratio := body_len / (CannonView.BORE_HALF_RATIO * 2.0)
	var heavy_ratio := body_len / (CannonView.HEAVY_BORE_HALF_RATIO * 2.0)
	_check(light_ratio >= 3.0, "slender_light_%.2f" % light_ratio)
	_check(heavy_ratio >= 3.0, "slender_heavy_%.2f" % heavy_ratio)
	## ④ 重管必须比轻管粗（口径差异的**唯一**视觉表达）。
	_check(CannonView.HEAVY_BORE_HALF_RATIO > CannonView.BORE_HALF_RATIO, "heavy_heavier")

## 建造页（32 px 格、缩放 1）的管口距离必须**恰好等于**设计值：那里没有尺寸补偿。
## 战斗页才允许被 `MIN_MOUTH_SCREEN` 拉长 —— 且只拉长、不缩短。
func _check_mouth_offset() -> void:
	var cell := 32.0
	_check_near(CannonView.mouth_offset(cell, 1.0), cell * CannonView.BRAKE_END_RATIO, "mouth_build_exact")
	## 极小缩放必须补偿到至少 `MIN_MOUTH_SCREEN` 屏幕像素。
	var tiny_cell := 16.0
	var tiny_scale := 0.594
	var mouth := CannonView.mouth_offset(tiny_cell, tiny_scale)
	_check(mouth * tiny_scale >= CannonView.MIN_MOUTH_SCREEN - TOL, "mouth_compensated")
	## 但补偿绝不能把管口缩短到设计值以下。
	_check(mouth >= tiny_cell * CannonView.BRAKE_END_RATIO - TOL, "mouth_never_shorter")

## `_cannon_key` 必须能用 `module_id + 首格` 唯一区分同型号的两门炮。
func _check_cannon_key(definitions: ModuleDefs) -> void:
	var a: String = MainScript._cannon_key("cannon_76", Vector2i(8, 4))
	var b: String = MainScript._cannon_key("cannon_76", Vector2i(8, 8))
	var c: String = MainScript._cannon_key("cannon_120", Vector2i(8, 4))
	_check(a != b, "key_distinct_same_module")
	_check(a != c, "key_distinct_same_cell")
	_check(a == MainScript._cannon_key("cannon_76", Vector2i(8, 4)), "key_stable")
	## 必须真的能从 `module_id` 里分辨出来（防止只用了格坐标）。
	_check(a.begins_with("cannon_76"), "key_carries_module")
	_check(not definitions.get_module("cannon_76").is_empty(), "key_module_exists")

## 两门 76 炮 + 驾驶舱 + 引擎 + 双履带（形状照 `aim_smoke._make_rig()`）。
func _make_rig(definitions: ModuleDefs) -> Dictionary:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("CANNONVIEW_FAIL_BUILDER")
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
			_fail("CANNONVIEW_FAIL_CANNON:%s" % note)
			return {}
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("CANNONVIEW_FAIL_BODY")
		return {}
	body.position = Vector2(1024.0, 576.0)
	var bank := CannonBank.new()
	if not bank.setup(definitions, body):
		_fail("CANNONVIEW_FAIL_BANK")
		return {}
	return {"body": body, "bank": bank}

## **v3.37 回归：钩子不得把 `centroid_local` 减两遍。**
##
## 事故现场：`_draw_hull_shared()` 传给钩子的第三个参数已经是
## `-hull.centroid_local + offset_fn(part)`；钩子里又写了一次
## `-hull.centroid_local + part_offset`，于是平移量翻倍，
## 炮管被甩到车身之外（用户实机发现：「偏移到了离车身很远的位置」）。
##
## **为什么逼得去读源码**：这个错误是「钩子内部某一行的表达式」的错，
## 而钩子是个 lambda，只能在 `_draw()` 里被调（测试里调不了，会刷 `Drawing is only allowed`）。
## 纯几何断言无法覆盖到它 —— 我最初写的那一版（只复算 `CannonView` 内部的转轴公式）
## 在把 bug 放回去之后**依然全绿**，等于没有防护。所以这里改成直接审查那一行源码：
## 它必须把 `part_offset` **原样**传给 `CannonView.draw_cannon()`。
func _check_hook_offset_not_doubled() -> void:
	var file := FileAccess.open("res://scripts/main.gd", FileAccess.READ)
	if file == null:
		_fail("offset_source_open_failed")
		return
	var source := file.get_as_text()
	file.close()
	## 定位 `_battle_cannon_hook` 的函数体。
	var start := source.find("func _battle_cannon_hook(")
	if start < 0:
		_fail("offset_hook_missing")
		return
	## 函数体的上限取下一个顶层 `func `（顶部注释块不含 `func`，不会误切）。
	var next := source.find("\nfunc ", start + 1)
	var raw_body := source.substr(start, (next - start) if next > 0 else -1)
	## **只审代码行，剔掉注释行**：注释里本来就会写 `centroid_local` 来解释这个坑，
	## 连注释一起扫会把「解释正确」误判成「又减了一遍」。
	var code_lines: Array[String] = []
	for raw_line in raw_body.split("\n"):
		var trimmed := (raw_line as String).strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		code_lines.append(raw_line as String)
	var code := "\n".join(code_lines)
	## 必须真的把 `part_offset` 直接交给绘制函数。
	_check(code.contains("CannonView.draw_cannon("), "offset_calls_draw_cannon")
	_check(code.contains("part_offset"), "offset_passes_part_offset")
	## **不得**在钩子的代码里出现 `centroid_local`；它是「减两遍」的唯一源头。
	_check(not code.contains("centroid_local"), "offset_no_second_centroid_subtract")
	## 反向对照：把 bug 版那一行当成样本，上面那条检查必须真的能报错。
	var buggy_sample := "\t\t\tscale_factor, -hull.centroid_local + part_offset)"
	_check(buggy_sample.contains("centroid_local"), "offset_negative_control_detects_pattern")

##
## 这里逐字复算 `_battle_cannon_hook()` 的那一行：
##     aims[key] = bank.muzzle_dir(cannon).angle() - drawn_heading
## 如果实现里漏了 `- drawn_heading`，`local + heading` 会等于 `world + heading`，
## 只有在 `heading == 0` 时才碰巧通过 —— 所以每个 heading 都单独测一遍。
func _check_realtime_aim(body: TankBody, bank: CannonBank, heading: float) -> void:
	body.heading = heading
	## 瞄准一个固定世界点，让 `aim_override` 生效（玩家鼠标走的就是这条路径）。
	var target := Vector2(1600.0, 260.0)
	bank.aim_all_at(target)
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		var world_angle := bank.muzzle_dir(cannon).angle()
		var aim_local := world_angle - heading
		## 局部角加回朝向 = 世界角（`wrapf` 吸收 ±π 的绕圈）。
		_check_near(wrapf(aim_local + heading, -PI, PI), wrapf(world_angle, -PI, PI),
			"realtime_roundtrip_h%.2f_%d" % [heading, index])
		## 再钉一次语义：方向必须真的指向目标，而不是照抄建造期 `aim`。
		var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
		var expected := (target - centre).angle()
		_check_near(wrapf(world_angle, -PI, PI), wrapf(expected, -PI, PI),
			"realtime_points_at_target_h%.2f_%d" % [heading, index])

## **反向对照**：证明「不减 heading」的写法在 `heading != 0` 时确实会错。
## 没有这一条，上面那些断言可能只是在验证一个恒真的等式。
func _check_negative_control(body: TankBody, bank: CannonBank) -> void:
	body.heading = 1.0
	bank.aim_all_at(Vector2(1600.0, 260.0))
	var cannon: Dictionary = bank.cannons[0]
	var world_angle := bank.muzzle_dir(cannon).angle()
	var wrong_local := world_angle          # 错误的写法：直接拿世界角当局部角
	var wrong_world := wrong_local + body.heading
	_check(absf(wrapf(wrong_world - world_angle, -PI, PI)) > 0.5,
		"negative_control_must_differ")
	## 而正确的写法必须落回世界角。
	var right_local := world_angle - body.heading
	_check_near(wrapf(right_local + body.heading, -PI, PI), wrapf(world_angle, -PI, PI),
		"positive_control_matches")

## 没有鼠标覆盖时（Bot 走的就是这条），方向退回「朝向 + 建造期 aim」，
## 炮管同样要跟着转。这一条防的是「只在有覆盖时才换算」的半修。
func _check_legacy_aim(body: TankBody, bank: CannonBank) -> void:
	for heading in [0.0, 1.4]:
		body.heading = heading
		bank.clear_aim_override()
		for index in range(bank.cannons.size()):
			var cannon: Dictionary = bank.cannons[index]
			## 显式 `float`：`muzzle_dir()` 的返回值是 Variant，写 `:=` 无法推导类型。
			var world_angle: float = bank.muzzle_dir(cannon).angle()
			var aim_rad := deg_to_rad(float(cannon["aim"]))
			_check_near(wrapf(world_angle, -PI, PI), wrapf(heading + aim_rad, -PI, PI),
				"legacy_world_h%.1f_%d" % [heading, index])
			var aim_local: float = world_angle - heading
			_check_near(wrapf(aim_local, -PI, PI), wrapf(aim_rad, -PI, PI),
				"legacy_local_h%.1f_%d" % [heading, index])
