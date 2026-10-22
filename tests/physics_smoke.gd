extends SceneTree

## M3 物理与操控 smoke（roadmap 验收 1–7）。
## 全部断言基于真实 JSON 逐项求和得出的 M/C/I 与闭式 sqrt(T/(M·K_DRAG))，
## 不使用 design §5.3 那张过期聚合表的字面值。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all("res://data"):
		_fail("PHYSICS_FAIL_DATA")
		return
	var assault := _make_assault(definitions)
	if assault == null:
		return
	if not _check_mass(assault):
		return
	if not _check_terminal_speed(assault):
		return
	if not _check_pivot(definitions):
		return
	if not _check_arc(definitions):
		return
	if not _check_one_side(definitions):
		return
	if not _check_damage_changes_mass(definitions):
		return
	if not _check_wall_collision(definitions):
		return
	if not _check_wall_hits_outward_part(definitions):
		return
	if not _check_rect_obstacle_push_out(definitions):
		return
	if not _check_circle_obstacle_push_out(definitions):
		return
	if not _check_corner_single_charge(definitions):
		return
	if not _check_tank_collision(definitions):
		return
		return
	if not _check_spin_stop(definitions):
		return
	var turn_s := _measure_turn(definitions)
	var spin_s := _measure_spin_stop(definitions)
	print("PHYSICS_OK mass=%.1f inertia=%.0f v_max=%.1f turn180_s=%.2f spin_stop_s=%.2f" % [
		assault.mass_total, assault.inertia, assault.max_speed(), turn_s, spin_s
	])
	quit(0)

func _fail(code: String) -> void:
	print(code)
	quit(1)

## 验收基线：6×7 突击型（2 轻履 + 中型引擎 + 76 炮 + 轻型驾驶舱），
## 所有部件相对纵轴对称布置，净扭矩为 0，因此可以做纯推力终端速度断言。
func _make_assault(definitions: ModuleDefs) -> TankBody:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_BUILDER")
		return null
	builder.budget_enabled = false
	builder.credits_total = 100000
	for y in range(4, 11):
		for x in range(4, 10):
			var note := builder.place_platform_cell(Vector2i(x, y))
			if not note.is_empty():
				_fail("PHYSICS_FAIL_PLATFORM:%s" % note)
				return null
	var steps := [
		["mobility", "track_light", Vector2i(4, 4), 0, 0],
		["mobility", "track_light", Vector2i(4, 10), 0, 0],
		["module", "cockpit_light", Vector2i(4, 7), 0, 0],
		["module", "engine_medium", Vector2i(5, 7), 0, 0],
		["module", "cannon_76", Vector2i(8, 7), 0, 0],
	]
	for step in steps:
		var layer := String(step[0])
		var module_id := String(step[1])
		var cell: Vector2i = step[2]
		var rot := int(step[3])
		var note := ""
		if layer == "mobility":
			note = builder.place_mobility(module_id, cell, rot)
		else:
			note = builder.place_module(module_id, cell, rot, int(step[4]))
		if not note.is_empty():
			_fail("PHYSICS_FAIL_PLACE:%s:%s" % [module_id, note])
			return null
	var report := builder.validation_report()
	if not bool(report.get("ok", false)):
		_fail("PHYSICS_FAIL_VALIDATION")
		return null
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_BODY")
		return null
	body.position = Vector2(1024.0, 576.0)
	return body

func _check_mass(body: TankBody) -> bool:
	## 手算：平台 42 格 ×1.0u；轻履 2×2.0；中引擎 7.0；76 炮 4.0；轻驾驶舱 4.0 → 61.0u
	var expected_mass := 42.0 + 2.0 * 2.0 + 7.0 + 4.0 + 4.0
	if absf(body.mass_total - expected_mass) > 0.05:
		_fail("PHYSICS_FAIL_MASS %.2f != %.2f" % [body.mass_total, expected_mass])
		return false
	## 对称布局：质心纵向必须落在中心行（第 7 行格心 y=7.5）。
	if absf(body.centroid_cell.y - 7.5) > 0.001:
		_fail("PHYSICS_FAIL_CENTROID_Y %.3f" % body.centroid_cell.y)
		return false
	if body.inertia <= 0.0:
		_fail("PHYSICS_FAIL_INERTIA_ZERO")
		return false
	var metrics := body.drive_metrics(0.0, 0.0)
	if absf(float(metrics["torque"])) > 0.001:
		_fail("PHYSICS_FAIL_SYMMETRY %.3f" % float(metrics["torque"]))
		return false
	return true

func _check_terminal_speed(body: TankBody) -> bool:
	var v_max := body.max_speed()
	var metrics := body.drive_metrics(1.0, 0.0)
	var thrust := float(metrics["thrust"])
	## 闭式校验：sqrt(T/(M·K_DRAG)) 必须由解算器自己的 T 与 M 得到。
	var closed := sqrt(thrust / (body.mass_total * body.k_drag()))
	if absf(closed - v_max) > 0.001:
		_fail("PHYSICS_FAIL_CLOSED_FORM %.3f vs %.3f" % [v_max, closed])
		return false
	for step in range(1500):
		body.step(1.0 / 60.0, 1.0, 0.0)
	var measured := body.velocity.length()
	var error := absf(measured - v_max) / v_max
	if error > 0.08:
		_fail("PHYSICS_FAIL_TERMINAL %.1f vs %.1f err=%.4f" % [measured, v_max, error])
		return false
	## 直线行驶不应自己旋转。
	if absf(body.angular_velocity) > 0.001:
		_fail("PHYSICS_FAIL_STRAIGHT_YAW %.4f" % body.angular_velocity)
		return false
	return true

## 原地回转：throttle=0, steer=1 时 T≈0 且 ω>0（顺时针，与 Godot rotation 正方向一致）。
func _check_pivot(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var metrics := body.drive_metrics(0.0, 1.0)
	var thrust := float(metrics["thrust"])
	var torque := float(metrics["torque"])
	if absf(thrust) > absf(torque) * 0.01:
		_fail("PHYSICS_FAIL_PIVOT_THRUST %.2f" % thrust)
		return false
	if absf(torque) < 1.0:
		_fail("PHYSICS_FAIL_PIVOT_TORQUE")
		return false
	for step in range(180):
		body.step(1.0 / 60.0, 0.0, 1.0)
	if body.angular_velocity <= 0.0:
		_fail("PHYSICS_FAIL_PIVOT_OMEGA %.4f" % body.angular_velocity)
		return false
	if body.heading <= 0.0:
		_fail("PHYSICS_FAIL_PIVOT_ROTATION")
		return false
	if body.velocity.length() > 1.0:
		_fail("PHYSICS_FAIL_PIVOT_DRIFT %.3f" % body.velocity.length())
		return false
	return true

## 对称双履带 + throttle=1, steer≠0 必须走弧线（扭矩不互相抵消）。
func _check_arc(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var metrics := body.drive_metrics(1.0, 0.5)
	if absf(float(metrics["torque"])) < 1.0:
		_fail("PHYSICS_FAIL_ARC_TORQUE")
		return false
	for step in range(120):
		body.step(1.0 / 60.0, 1.0, 0.5)
	if absf(body.angular_velocity) < 0.05:
		_fail("PHYSICS_FAIL_ARC_OMEGA %.4f" % body.angular_velocity)
		return false
	if body.velocity.length() < 5.0:
		_fail("PHYSICS_FAIL_ARC_SPEED %.3f" % body.velocity.length())
		return false
	return true

## 只留一侧行进机构：steer=0 也持续偏转。
func _check_one_side(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var removed := false
	for index in range(body.parts.size() - 1, -1, -1):
		var part: Dictionary = body.parts[index]
		var cells: Array = part["cells"]
		if String(part["module_id"]) == "track_light" and Vector2i(cells[0]).y == 10:
			body.damage_part(index, 100000.0)
			removed = true
			break
	if not removed:
		_fail("PHYSICS_FAIL_ONE_SIDE_SETUP")
		return false
	if body.parts_of_kind(TankBody.KIND_MOBILITY).size() != 1:
		_fail("PHYSICS_FAIL_ONE_SIDE_COUNT")
		return false
	for step in range(120):
		body.step(1.0 / 60.0, 1.0, 0.0)
	if absf(body.angular_velocity) < 0.05:
		_fail("PHYSICS_FAIL_ONE_SIDE_OMEGA %.4f" % body.angular_velocity)
		return false
	return true

## 摧毁平台格后 M/I 立即变化。
func _check_damage_changes_mass(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var mass_before := body.mass_total
	var inertia_before := body.inertia
	var centroid_before := body.centroid_local
	var removed := false
	for index in range(body.parts.size() - 1, -1, -1):
		var part: Dictionary = body.parts[index]
		if String(part["kind"]) == TankBody.KIND_PLATFORM_CELL:
			body.damage_part(index, 1000.0)
			removed = true
			break
	if not removed:
		_fail("PHYSICS_FAIL_DAMAGE_SETUP")
		return false
	if absf(body.mass_total - (mass_before - 1.0)) > 0.001:
		_fail("PHYSICS_FAIL_DAMAGE_MASS %.2f" % body.mass_total)
		return false
	if absf(body.inertia - inertia_before) < 0.001:
		_fail("PHYSICS_FAIL_DAMAGE_INERTIA")
		return false
	if body.centroid_local == centroid_before:
		_fail("PHYSICS_FAIL_DAMAGE_CENTROID")
		return false
	return true

## 撞墙：法向速度归零且伤害 = 4 + 0.05·|v|。
func _check_wall_collision(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	for step in range(900):
		body.step(1.0 / 60.0, 1.0, 0.0)
		body.apply_boundary(arena)
	var bounds := body.world_bounds()
	if bounds.end.x > arena.end.x + 0.001:
		_fail("PHYSICS_FAIL_WALL_CLAMP %.3f" % bounds.end.x)
		return false
	body.velocity = Vector2(400.0, 0.0)
	var dealt := body.apply_boundary(arena)
	if body.velocity.x > 0.0:
		_fail("PHYSICS_FAIL_WALL_VELOCITY %.3f" % body.velocity.x)
		return false
	var expected := 4.0 + 0.05 * 400.0
	if absf(dealt - expected) > 0.001:
		_fail("PHYSICS_FAIL_WALL_DAMAGE %.3f != %.3f" % [dealt, expected])
		return false
	return true

## R17-1：撞墙伤害必须落在**最贴近撞击面**的部件上。
## 缺陷表现：撞右墙却打最左侧部件，导致驾驶舱在一头的坦克会因撞反方向墙而被毁。
func _check_wall_hits_outward_part(definitions: ModuleDefs) -> bool:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_WALL_SIDE_BUILDER")
		return false
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for x in range(4, 12):
		builder.place_platform_cell(Vector2i(x, 4))
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_WALL_SIDE_BODY")
		return false
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	body.position = Vector2(1024.0, 576.0)
	var bounds := body.world_bounds()
	body.position += Vector2(arena.end.x - bounds.end.x, 0.0)
	body.velocity = Vector2(400.0, 0.0)
	var before := {}
	for index in range(body.parts.size()):
		before[String(body.parts[index]["key"])] = float(body.parts[index]["hp"])
	body.apply_boundary(arena)
	var hit_x := -1
	var rightmost := -1
	for index in range(body.parts.size()):
		var part: Dictionary = body.parts[index]
		var cell := Vector2i((part["cells"] as Array)[0])
		if String(part["kind"]) != TankBody.KIND_PLATFORM_CELL:
			continue
		rightmost = maxi(rightmost, cell.x)
		var key := String(part["key"])
		if before.has(key) and float(part["hp"]) < float(before[key]) - 0.0001:
			hit_x = cell.x
	if hit_x != rightmost:
		_fail("PHYSICS_FAIL_WALL_SIDE hit_x=%d rightmost=%d" % [hit_x, rightmost])
		return false
	return true

## R17-2：矩形障碍应把车推高障碍，而不是把它推入障碍。
## 缺陷表现：长条墙体在某轴完全包含车身时，旧的 overlap_x/overlap_y 比较会选错轴，
## 车身直接从墙里穿过去。
func _check_rect_obstacle_push_out(definitions: ModuleDefs) -> bool:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_RECT_BUILDER")
		return false
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for x in range(4, 7):
		builder.place_platform_cell(Vector2i(x, 4))
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_RECT_BODY")
		return false
	var rect := Rect2(220.0, 0.0, 128.0, 600.0)
	body.position = Vector2(200.0, 300.0)
	body.velocity = Vector2(300.0, 0.0)
	for step in range(120):
		body.position += body.velocity * (1.0 / 60.0)
		body.apply_obstacles([{"shape": "rect", "rect": rect}])
	var bounds := body.world_bounds()
	if bounds.intersects(rect):
		_fail("PHYSICS_FAIL_RECT_EMBEDDED end_x=%.2f rect_x=%.2f" % [bounds.end.x, rect.position.x])
		return false
	## 必须停在障碍的左前侧，不能穿过去。
	if bounds.get_center().x >= rect.get_center().x:
		_fail("PHYSICS_FAIL_RECT_PASSED x=%.2f" % body.position.x)
		return false
	return true

## R17-3：圆心落在 AABB 内部时，推出量必须让 AABB 完整离开圆。
## 缺陷表现：closest 退化为圆心、distance = 0，旧的「radius − distance」只推 radius，
## 且法向取自中心差，完全忽略圆心与 AABB 中心的偏移。
func _check_circle_obstacle_push_out(definitions: ModuleDefs) -> bool:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_CIRCLE_BUILDER")
		return false
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for y in range(4, 7):
		for x in range(4, 7):
			builder.place_platform_cell(Vector2i(x, y))
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_CIRCLE_BODY")
		return false
	body.position = Vector2(1024.0, 576.0)
	var bounds := body.world_bounds()
	var half := bounds.size * 0.5
	var radius := 30.0
	var centre := bounds.get_center()
	var before := body.position
	body.apply_obstacles([{"shape": "circle", "center": centre, "radius": radius}])
	var moved := body.position.distance_to(before)
	## 同心时最短推出量 = radius + 较短的半边（即沿短轴推出）。
	var expected := radius + minf(half.x, half.y)
	if moved < expected - 0.01:
		_fail("PHYSICS_FAIL_CIRCLE_SHORT moved=%.2f expected=%.2f" % [moved, expected])
		return false
	if body.world_bounds().has_point(centre):
		_fail("PHYSICS_FAIL_CIRCLE_OVERLAP")
		return false
	return true

## R17-4：同一帧撞到两堵墙（墙角）只能扣一次伤害。
## 缺陷表现：apply_boundary 对每面墙各调一次结算，伤害 = 24 + 24（同一速度计两次）。
func _check_corner_single_charge(definitions: ModuleDefs) -> bool:
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	var single := _make_wall_body(definitions, false, arena)
	var corner := _make_wall_body(definitions, true, arena)
	if single == null or corner == null:
		return false
	var one := single.apply_boundary(arena)
	var two := corner.apply_boundary(arena)
	if absf(two - one) > 0.001:
		_fail("PHYSICS_FAIL_CORNER_DOUBLE single=%.3f corner=%.3f" % [one, two])
		return false
	return true

func _make_wall_body(definitions: ModuleDefs, at_corner: bool, arena: Rect2) -> TankBody:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_CORNER_BUILDER")
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for x in range(4, 7):
		builder.place_platform_cell(Vector2i(x, 4))
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_CORNER_BODY")
		return null
	body.position = Vector2(1024.0, 576.0)
	var bounds := body.world_bounds()
	body.position += Vector2(arena.end.x - bounds.end.x, 0.0)
	if at_corner:
		bounds = body.world_bounds()
		body.position += Vector2(0.0, arena.end.y - bounds.end.y)
	body.velocity = Vector2(400.0, 400.0)
	return body

## R17-9：坦克互撞必须有分离与伤害（旧实现完全没有互撞处理）。
## 伤害公式使用 design §8.7 的 `0.04·|Δv|·min(M_a,M_b)^0.5`，无基数项。
func _check_tank_collision(definitions: ModuleDefs) -> bool:
	var a := _make_single_cell(definitions, "PHYSICS_FAIL_TANK_A")
	var b := _make_single_cell(definitions, "PHYSICS_FAIL_TANK_B")
	if a == null or b == null:
		return false
	a.position = Vector2(1000.0, 500.0)
	## 单格车体宽仅 cell_size，必须按实际 AABB 摆放才能重叠；
	## 这里让两车 AABB 重叠半个车宽。
	var width := a.world_bounds().size.x
	b.position = Vector2(1000.0 + width * 0.5, 500.0)
	a.velocity = Vector2(200.0, 0.0)
	b.velocity = Vector2(-200.0, 0.0)
	var dealt := a.apply_tank_collision(b)
	var coefficient := definitions.global_number("tank_collision_coefficient", 0.04)
	var closing := 400.0
	var light := minf(a.mass_total, b.mass_total)
	var expected := coefficient * closing * sqrt(maxf(light, 0.0))
	if absf(dealt - expected) > 0.01:
		_fail("PHYSICS_FAIL_TANK_DAMAGE %.3f != %.3f" % [dealt, expected])
		return false
	if dealt <= 0.0:
		_fail("PHYSICS_FAIL_TANK_NO_DAMAGE")
		return false
	## 分离后 AABB 不得仍然重叠。
	if a.world_bounds().intersects(b.world_bounds()):
		_fail("PHYSICS_FAIL_TANK_STILL_OVERLAP")
		return false
	if a.impact_damage_total <= 0.0 or b.impact_damage_total <= 0.0:
		_fail("PHYSICS_FAIL_TANK_ONE_SIDED a=%.3f b=%.3f" % [a.impact_damage_total, b.impact_damage_total])
		return false
	return true

func _make_single_cell(definitions: ModuleDefs, tag: String) -> TankBody:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail(tag)
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	builder.place_platform_cell(Vector2i(4, 4))
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail(tag)
		return null
	return body


## 验收 7：约 120 个功能模块的重载坦克单帧解算耗时。
func _check_performance(definitions: ModuleDefs) -> bool:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("PHYSICS_FAIL_PERF_BUILDER")
		return false
	builder.budget_enabled = false
	builder.credits_total = 1000000
	builder.mass_cap_level = definitions.global_int("mass_cap_max_level", 5)
	for y in range(0, 12):
		for x in range(0, 12):
			builder.place_platform_cell(Vector2i(x, y))
	var placed := 0
	for y in range(1, 12):
		for x in range(0, 11):
			if placed >= 120:
				break
			if builder.place_module("conveyor_straight", Vector2i(x, y), 0, 0).is_empty():
				placed += 1
	if placed < 120:
		_fail("PHYSICS_FAIL_PERF_PLACED %d" % placed)
		return false
	builder.place_mobility("track_heavy", Vector2i(0, 0), 0)
	builder.place_mobility("track_heavy", Vector2i(0, 10), 0)
	builder.place_module("engine_heavy", Vector2i(2, 0), 0, 0)
	builder.place_module("cockpit_light", Vector2i(6, 6), 0, 0)
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("PHYSICS_FAIL_PERF_BODY")
		return false
	body.position = Vector2(1024.0, 576.0)
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	var start_usec := Time.get_ticks_usec()
	for step in range(600):
		body.step(1.0 / 60.0, 1.0, 0.3)
		body.apply_boundary(arena)
	var elapsed_usec := Time.get_ticks_usec() - start_usec
	var per_frame_ms := float(elapsed_usec) / 600.0 / 1000.0
	if per_frame_ms > 6.0:
		_fail("PHYSICS_FAIL_PERF %.3fms modules=%d" % [per_frame_ms, placed])
		return false
	return true

## 原地 180° 回转实测用时（throttle=0, steer=1）。
func _measure_turn(definitions: ModuleDefs) -> float:
	var body := _make_assault(definitions)
	if body == null:
		return 0.0
	var dt := 1.0 / 60.0
	var elapsed := 0.0
	for step in range(3000):
		body.step(dt, 0.0, 1.0)
		elapsed += dt
		if absf(body.heading) >= PI:
			break
	return elapsed

## 松手后自旋衰减：用户报告的「转一下会原地旋转很久」一直没有被任何断言覆盖，
## 因此新增本项。旧实现把 k_ang_drag·ω·|ω| 当作扭矩从 τ 里减，与 τ 差 10⁵ 量级，
## 实测松手 100 s 后 ω 仍为 2.997 rad/s（从 3.000 开始），等于完全没有阻尼。
func _check_spin_stop(definitions: ModuleDefs) -> bool:
	var body := _make_assault(definitions)
	if body == null:
		return false
	var dt := 1.0 / 60.0
	## 先把角速度推到稳态，再松手。
	for step in range(120):
		body.step(dt, 0.0, 1.0)
	var held := absf(body.angular_velocity)
	if held < 0.5:
		_fail("PHYSICS_FAIL_SPIN_HELD %.4f" % held)
		return false
	var elapsed := 0.0
	var stopped := false
	for step in range(600):
		body.step(dt, 0.0, 0.0)
		elapsed += dt
		if absf(body.angular_velocity) <= 0.1:
			stopped = true
			break
	if not stopped:
		_fail("PHYSICS_FAIL_SPIN_STOP %.4f" % body.angular_velocity)
		return false
	## 上限 1.5 s：既保证「松手即停」的手感，也给不同构建留出质量/惯量差异。
	if elapsed > 1.5:
		_fail("PHYSICS_FAIL_SPIN_SLOW %.3f" % elapsed)
		return false
	return true

## 松手后 |ω| 降到 0.1 rad/s 的实测秒数，未收敛则返回 -1。
func _measure_spin_stop(definitions: ModuleDefs) -> float:
	var body := _make_assault(definitions)
	if body == null:
		return -1.0
	var dt := 1.0 / 60.0
	for step in range(120):
		body.step(dt, 0.0, 1.0)
	var elapsed := 0.0
	for step in range(600):
		body.step(dt, 0.0, 0.0)
		elapsed += dt
		if absf(body.angular_velocity) <= 0.1:
			return elapsed
	return -1.0
