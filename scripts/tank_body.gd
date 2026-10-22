extends RefCounted

## M3 坦克自建刚体（design §5）。
## 只做纯逻辑：质量/质心/惯量重算、差速推力与扭矩、定步长积分、边界与障碍碰撞。
## 不绘制也不读取输入，主场景与 headless smoke 共用同一份解算，保证可测。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")

const KIND_PLATFORM_CELL := "platform_cell"
const KIND_PLATFORM_SHAPE := "platform_shape"
const KIND_MOBILITY := "mobility"
const KIND_MODULE := "module"

## design §6.1：多引擎收益递减，按 turn_assist 降序取用，第 4 个及以后固定 0.35。
const ENGINE_WEIGHTS := [1.0, 0.7, 0.5, 0.35]

var definitions: ModuleDefs
## 每个存活部件一项：{kind, module_id, rot, aim, hp, hp_max, cells, centre_local}
var parts: Array[Dictionary] = []
## 每个被占据的格子一项：{cell, part_index, mass, local}，供质量/惯量与碰撞轮廓使用。
var cells: Array[Dictionary] = []
var warnings: PackedStringArray = PackedStringArray()

var mass_total: float = 0.0
var centroid_local: Vector2 = Vector2.ZERO
var centroid_cell: Vector2 = Vector2.ZERO
var inertia: float = 0.0

## 世界像素坐标，锚点就是质心——旋转轴即质心。
var position: Vector2 = Vector2.ZERO
var heading: float = 0.0
var velocity: Vector2 = Vector2.ZERO
var angular_velocity: float = 0.0

## 最近一次解算的净推力与净扭矩，供 HUD 与 smoke 断言读取。
var thrust_total: float = 0.0
var torque_total: float = 0.0
var effective_turn: float = 0.0
var impact_damage_total: float = 0.0
var destroyed: bool = false
var collision_damage_enabled: bool = true

var _cell_size: float = 16.0
var _k_drag: float = 0.004
var _k_ang_drag: float = 0.35
var _k_ang_brake: float = 5.0
var _i_min: float = 12000.0
var _omega_max: float = 3.0
var _platform_cell_mass: float = 1.0
var _wall_base: float = 4.0
var _wall_per_speed: float = 0.05
var _wall_min_speed: float = 20.0
## design §8.7 的坦克对撞系数：dmg = C·|Δv|·sqrt(min(M_a,M_b))，**无基数项**。
## 注意：§6.8 的喷射冲撞是另一套公式（30 + 0.06·相对速度），属于 thruster，不得混用。
var _ram_per_speed: float = 0.04
## 最近一次 rebuild 的来源建造模型；摧毁部件时用它回写，避免 rebuild 复活已毁部件。
var _source: GridBuilder
## M6：环境伤害路由。非空时撞击伤害交给外部结算（damage_system 的殉爆 / detach / 判负连锁）。
## 为空时退回本地 damage_part——physics_smoke 等纯物理用例不设路由，行为与 M5 一致。
var damage_router: Callable = Callable()

func setup(module_defs: ModuleDefs, source: GridBuilder) -> bool:
	definitions = module_defs
	if definitions == null or source == null:
		return false
	_read_config()
	rebuild(source)
	return not parts.is_empty()

## 从 GridBuilder 状态重新收集存活部件。结构变化（建造/摧毁）后调用。
func rebuild(source: GridBuilder) -> void:
	_source = source
	parts.clear()
	cells.clear()
	warnings.clear()
	if source == null:
		_clear_mass()
		return
	var platform_keys: Array = source.platform_cells.keys()
	platform_keys.sort()
	for raw_cell in platform_keys:
		if bool(source.platform_cells[raw_cell]):
			_add_part(KIND_PLATFORM_CELL, "platform_cell", 0, 0, [Vector2i(raw_cell)])
	for shape_part in source.platform_shapes:
		_add_grid_part(source, KIND_PLATFORM_SHAPE, shape_part)
	for mobility_part in source.mobility_parts:
		_add_grid_part(source, KIND_MOBILITY, mobility_part)
	for module_part in source.module_parts:
		_add_grid_part(source, KIND_MODULE, module_part)
	_rebuild_cells()
	recompute()
	_update_effective_turn()

func _read_config() -> void:
	if definitions == null:
		return
	_cell_size = definitions.global_number("cell_size", 16.0)
	_k_drag = definitions.global_number("k_drag", 0.004)
	_k_ang_drag = definitions.global_number("k_ang_drag", 0.35)
	_k_ang_brake = definitions.global_number("k_ang_brake", 5.0)
	_i_min = definitions.global_number("i_min", 12000.0)
	_omega_max = definitions.global_number("omega_max", 3.0)
	_platform_cell_mass = definitions.global_number("platform_cell_mass", 1.0)
	_wall_base = definitions.global_number("wall_impact_damage_base", 4.0)
	_wall_per_speed = definitions.global_number("wall_impact_damage_per_speed", 0.05)
	_wall_min_speed = definitions.global_number("wall_impact_min_speed", 20.0)
	_ram_per_speed = definitions.global_number("tank_collision_coefficient", 0.04)

func _add_grid_part(source: GridBuilder, kind: String, source_part: Dictionary) -> void:
	var module_id := String(source_part.get("id", ""))
	var def := definitions.get_module(module_id)
	if def.is_empty():
		warnings.append("未知模块 %s" % module_id)
		return
	var occupied := source.part_cells(source_part)
	if occupied.is_empty():
		warnings.append("模块 %s 没有占用格" % module_id)
		return
	var rot := int(source_part.get("rot", 0))
	var aim := 0
	if source_part.has("aim"):
		aim = int(source_part.get("aim", 0))
	elif def.has("caliber"):
		## design §6.5：缺省 aim = rot × 90。
		aim = posmod(rot, 360)
	_add_part(kind, module_id, rot, aim, occupied)

func _add_part(kind: String, module_id: String, rot: int, aim: int, occupied: Array) -> void:
	var cells_occupied: Array[Vector2i] = []
	var centre := Vector2.ZERO
	for raw_cell in occupied:
		var cell: Vector2i = raw_cell
		cells_occupied.append(cell)
		centre += _cell_centre_local(cell)
	if cells_occupied.is_empty():
		return
	centre /= float(cells_occupied.size())
	var hp_max := 1.0
	var armor := 0.0
	if kind != KIND_PLATFORM_CELL:
		var def := definitions.get_module(module_id)
		hp_max = float(def.get("hp_max", 1.0))
		armor = float(def.get("armor", 0.0))
	else:
		var platform_def := definitions.get_module("platform_cell")
		hp_max = float(platform_def.get("hp_max", 45.0))
		armor = float(platform_def.get("armor", 0.0))
	parts.append({
		"kind": kind,
		"module_id": module_id,
		"rot": posmod(rot, 360),
		"aim": posmod(aim, 360),
		"hp": hp_max,
		"hp_max": hp_max,
		"armor": armor,
		"cells": cells_occupied,
		"centre_local": centre,
		"key": part_key(kind, module_id, cells_occupied),
	})

func _rebuild_cells() -> void:
	cells.clear()
	for index in range(parts.size()):
		var part: Dictionary = parts[index]
		var occupied: Array = part["cells"]
		var count := maxi(occupied.size(), 1)
		var unit_mass := _platform_cell_mass
		if String(part["kind"]) != KIND_PLATFORM_CELL:
			var def := definitions.get_module(String(part["module_id"]))
			unit_mass = float(def.get("mass", 1.0)) / float(count)
		for raw_cell in occupied:
			var cell: Vector2i = raw_cell
			cells.append({
				"cell": cell,
				"part_index": index,
				"mass": unit_mass,
				"local": _cell_centre_local(cell),
			})

func recompute() -> void:
	mass_total = 0.0
	var weighted := Vector2.ZERO
	for unit in cells:
		var mass := float(unit["mass"])
		mass_total += mass
		weighted += Vector2(unit["local"]) * mass
	if mass_total <= 0.0:
		_clear_mass()
		return
	centroid_local = weighted / mass_total
	centroid_cell = centroid_local / _cell_size
	## design §5.1：逐格 |q-C|² 加每格自身项，禁矩形近似。
	var self_term := _cell_size * _cell_size / 6.0
	var total := 0.0
	for unit in cells:
		var mass := float(unit["mass"])
		var offset := Vector2(unit["local"]) - centroid_local
		total += mass * offset.length_squared() + mass * self_term
	inertia = total

func _clear_mass() -> void:
	mass_total = 0.0
	centroid_local = Vector2.ZERO
	centroid_cell = Vector2.ZERO
	inertia = 0.0

func _update_effective_turn() -> void:
	var values: Array[float] = []
	for part in parts:
		if String(part["kind"]) != KIND_MODULE:
			continue
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("turn_assist"):
			continue
		values.append(float(def.get("turn_assist", 0.0)) * _engine_factor(part))
	values.sort()
	values.reverse()
	var total := 0.0
	for index in range(values.size()):
		total += values[index] * float(ENGINE_WEIGHTS[mini(index, ENGINE_WEIGHTS.size() - 1)])
	effective_turn = total

## design §5.2：行进机构耐久系数。
func _durability(part: Dictionary) -> float:
	var hp_max := float(part["hp_max"])
	if hp_max <= 0.0:
		return 1.0
	return 0.4 + 0.6 * (float(part["hp"]) / hp_max)

## design §6.1：引擎有效性随 HP 衰减。
func _engine_factor(part: Dictionary) -> float:
	var hp_max := float(part["hp_max"])
	if hp_max <= 0.0:
		return 1.0
	return 0.5 + 0.5 * (float(part["hp"]) / hp_max)

func dir_of(rot: int) -> Vector2:
	match posmod(rot, 360):
		90:
			return Vector2.DOWN
		180:
			return Vector2.LEFT
		270:
			return Vector2.UP
		_:
			return Vector2.RIGHT

## design §5.2 的净推力与净扭矩。纯查询，不改速度。
func drive_metrics(throttle: float, steer: float) -> Dictionary:
	var forward := Vector2.RIGHT.rotated(heading)
	var thrust := 0.0
	var torque := 0.0
	for part in parts:
		if String(part["kind"]) != KIND_MOBILITY:
			continue
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("thrust"):
			continue
		var offset := (Vector2(part["centre_local"]) - centroid_local).rotated(heading)
		var dir_world := dir_of(int(part["rot"])).rotated(heading)
		## cross(u, r) > 0 即顺时针，与 Godot rotation 正方向一致。
		var side := signf(forward.cross(offset))
		var axis := clampf(throttle - side * steer, -1.0, 1.0)
		var force := float(def.get("thrust", 0.0)) * float(def.get("grip", 1.0)) * _durability(part) * axis
		thrust += force * dir_world.dot(forward)
		torque += force * offset.cross(dir_world)
	return {"thrust": thrust, "torque": torque * (1.0 + effective_turn)}

## design §5.3 的定步长积分。
func step(dt: float, throttle: float, steer: float) -> void:
	if destroyed or dt <= 0.0 or mass_total <= 0.0:
		velocity = Vector2.ZERO
		angular_velocity = 0.0
		return
	var forward := Vector2.RIGHT.rotated(heading)
	var metrics := drive_metrics(throttle, steer)
	thrust_total = float(metrics["thrust"])
	torque_total = float(metrics["torque"])
	var accel := (thrust_total / mass_total) * forward - _k_drag * velocity * velocity.length()
	## design §5.2：角阻尼按「角减速度」量纲施加，τ/I 与 ω²、ω 同量纲才能互相抵消。
	## 旧写法把 k_ang_drag·ω·|ω| 当作扭矩从 τ 里减，与 τ 差 10⁵ 量级，等于没有阻尼。
	var inertia_eff := maxf(inertia, _i_min)
	var alpha := torque_total / inertia_eff - _k_ang_drag * angular_velocity * absf(angular_velocity)
	## 无转向输入时地面横摆阻尼占主导：角速度线性收敛，松手即停（design §5.2）。
	if absf(steer) <= 0.001:
		alpha -= _k_ang_brake * angular_velocity
	velocity += accel * dt
	angular_velocity = clampf(angular_velocity + alpha * dt, -_omega_max, _omega_max)
	position += velocity * dt
	heading += angular_velocity * dt

## 满油门前进的终端速度 sqrt(T/(M·K_DRAG))，供 HUD 与验收对照。
func max_speed() -> float:
	if mass_total <= 0.0 or _k_drag <= 0.0:
		return 0.0
	var metrics := drive_metrics(1.0, 0.0)
	var thrust := float(metrics["thrust"])
	if thrust <= 0.0:
		return 0.0
	return sqrt(thrust / (mass_total * _k_drag))

func k_drag() -> float:
	return _k_drag

func cell_size() -> float:
	return _cell_size

## 当前朝向下的世界轴对齐包围盒（已含旋转），用于边界与障碍碰撞。
func world_bounds() -> Rect2:
	if cells.is_empty():
		return Rect2(position, Vector2.ZERO)
	var half := _cell_size * 0.5
	var corners: Array[Vector2] = [
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(-half, half), Vector2(half, half),
	]
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for unit in cells:
		var centre := position + (Vector2(unit["local"]) - centroid_local).rotated(heading)
		for raw_corner in corners:
			var point: Vector2 = centre + raw_corner.rotated(heading)
			min_p.x = minf(min_p.x, point.x)
			min_p.y = minf(min_p.y, point.y)
			max_p.x = maxf(max_p.x, point.x)
			max_p.y = maxf(max_p.y, point.y)
	return Rect2(min_p, max_p - min_p)

func world_position_of_cell(cell: Vector2i) -> Vector2:
	return position + (_cell_centre_local(cell) - centroid_local).rotated(heading)

func world_position_of_part(part: Dictionary) -> Vector2:
	var centre: Vector2 = part["centre_local"]
	return position + (centre - centroid_local).rotated(heading)

## design §5.4：边界硬碰撞，法向速度归零并施加 4 + 0.05·|v| 伤害。
## 返回本次调用累计的伤害量。
## 一次调用内所有贴住的墙先合并为一次位置修正与一次伤害结算（避免墙角双扣，R17-4）。
func apply_boundary(arena_rect: Rect2) -> float:
	if destroyed or cells.is_empty():
		return 0.0
	var before := impact_damage_total
	var bounds := world_bounds()
	## 接触容差：贴墙静止时 penetration 恰为 0，仍需清零向墙内的法向速度。
	var contact := 0.001
	var normals: Array[Vector2] = []
	var deepest := 0.0
	var left := arena_rect.position.x - bounds.position.x
	var top := arena_rect.position.y - bounds.position.y
	var right := bounds.end.x - arena_rect.end.x
	var bottom := bounds.end.y - arena_rect.end.y
	if left > -contact:
		normals.append(Vector2.LEFT)
		deepest = maxf(deepest, maxf(left, 0.0))
	if right > -contact:
		normals.append(Vector2.RIGHT)
		deepest = maxf(deepest, maxf(right, 0.0))
	if top > -contact:
		normals.append(Vector2.UP)
		deepest = maxf(deepest, maxf(top, 0.0))
	if bottom > -contact:
		normals.append(Vector2.DOWN)
		deepest = maxf(deepest, maxf(bottom, 0.0))
	if normals.is_empty():
		return 0.0
	_resolve_contact(normals, deepest)
	return impact_damage_total - before

## 障碍物（矩形/圆）硬碰撞。obstacles 每项 {shape:"rect", rect:Rect2} 或 {shape:"circle", center, radius}。
func apply_obstacles(obstacles: Array) -> float:
	if destroyed or cells.is_empty():
		return 0.0
	var before := impact_damage_total
	for obstacle in obstacles:
		var shape := String(obstacle.get("shape", ""))
		if shape == "rect":
			_resolve_obstacle_rect(Rect2(obstacle["rect"]))
		elif shape == "circle":
			_resolve_obstacle_circle(Vector2(obstacle["center"]), float(obstacle.get("radius", 0.0)))
	return impact_damage_total - before

## 矩形障碍：取四个候选抽出方向中穿透最小的一个做最小平移。
## outward 语义："从本体指向障碍"的方向；_resolve_contact 内部用 position -= outward·d 推开。
## R17-2：原先的写法有两个错误：一是方向传反了（towards_left 时传 LEFT，把车推进障碍），
## 二是只比较 overlap_x / overlap_y——当长条墙体的某轴完全包含车身时，
## 两个 overlap 都等于车身尺寸，会选中与入撞方向无关的轴，车身就从墙里穿过去。
## 因此改成比较四个「抽出到各侧面」的穿透量，取最小。
func _resolve_obstacle_rect(rect: Rect2) -> void:
	var bounds := world_bounds()
	if not bounds.intersects(rect):
		return
	var overlap_x := minf(bounds.end.x, rect.end.x) - maxf(bounds.position.x, rect.position.x)
	var overlap_y := minf(bounds.end.y, rect.end.y) - maxf(bounds.position.y, rect.position.y)
	if overlap_x <= 0.0 or overlap_y <= 0.0:
		return
	## 从本体向各外侧抽出的距离；outward 指向障碍，所以推开方向取对应反向。
	var out_left := bounds.end.x - rect.position.x
	var out_right := rect.end.x - bounds.position.x
	var out_up := bounds.end.y - rect.position.y
	var out_down := rect.end.y - bounds.position.y
	var best := "left"
	var depth := out_left
	if out_right < depth:
		best = "right"
		depth = out_right
	if out_up < depth:
		best = "up"
		depth = out_up
	if out_down < depth:
		best = "down"
		depth = out_down
	match best:
		"left":
			_resolve_contact([Vector2.RIGHT], depth)
		"right":
			_resolve_contact([Vector2.LEFT], depth)
		"up":
			_resolve_contact([Vector2.DOWN], depth)
		_:
			_resolve_contact([Vector2.UP], depth)

## 圆形障碍：AABB 最近点法。
## R17-3：原实现只在圆心落在 AABB 内部时失效——closest 退化为圆心本身，
## distance = 0，随后用「中心差」当法向、把那个长度当穿透量，推出量不够，仍与圆重叠。
## 现在分成两种情形：
##   圆心在 AABB 外 → 穿透量就是 radius − distance（不需要再叠加任何支撑半径）；
##   圆心在 AABB 内 → 把圆当作「AABB 向外膨胀 radius」，取四个面中最大透入最小的一个面推出。
func _resolve_obstacle_circle(centre: Vector2, radius: float) -> void:
	if radius <= 0.0:
		return
	var bounds := world_bounds()
	var closest := Vector2(
		clampf(centre.x, bounds.position.x, bounds.end.x),
		clampf(centre.y, bounds.position.y, bounds.end.y)
	)
	var delta := closest - centre
	var distance := delta.length()
	if distance > 0.0001:
		if distance >= radius:
			return
		## normal 从圆心指向本体，所以推开本体用 -normal。
		_resolve_contact([-(delta / distance)], radius - distance)
		return
	## 圆心已在 AABB 内（也包含两车同心这种退化情形）。
	var half := bounds.size * 0.5
	var offset := centre - bounds.get_center()
	var limit := half + Vector2(radius, radius)
	var dx := limit.x - absf(offset.x)
	var dy := limit.y - absf(offset.y)
	if dx <= 0.0 or dy <= 0.0:
		return
	if dx < dy:
		var to_circle_x := Vector2.RIGHT if offset.x >= 0.0 else Vector2.LEFT
		_resolve_contact([-to_circle_x], dx)
	else:
		var to_circle_y := Vector2.DOWN if offset.y >= 0.0 else Vector2.UP
		_resolve_contact([-to_circle_y], dy)

## 统一的接触结算：先把所有法向的位置修正做完，再归零法向速度，最后只扣一次伤害。
## 伤害用结算前的合速度（design §5.4 的 4 + 0.05·|v|），因此墙角不会双扣。
func _resolve_contact(normals: Array[Vector2], penetration: float) -> void:
	if penetration > 0.0:
		for normal in normals:
			position -= normal * penetration
	var speed := velocity.length()
	var closing := false
	for normal in normals:
		var normal_speed := velocity.dot(normal)
		if normal_speed > 0.0:
			velocity -= normal * normal_speed
			closing = true
	if not closing:
		return
	if not collision_damage_enabled or speed <= _wall_min_speed:
		return
	var damage := _wall_base + _wall_per_speed * speed
	impact_damage_total += damage
	_apply_impact_damage(normals[0], damage)

## R17-1：撞击点应该是**最贴近撞击面**的部件，即 outward 方向投影最大者。
## 原实现传的是 -outward（向内），导致撞右墙却打最左侧的部件。
func _apply_impact_damage(outward: Vector2, damage: float) -> void:
	var best := -1
	var best_score := -INF
	for index in range(parts.size()):
		var score := world_position_of_part(parts[index]).dot(outward)
		if score > best_score:
			best_score = score
			best = index
	if best >= 0:
		if damage_router.is_valid():
			damage_router.call(self, best, damage)
		else:
			damage_part(best, damage)

## design §8.7：坦克对撞。由外部（duel）把两个已互相穿模的刚体传进来，
## 按最小平移分离，并对双方各施加一次 `0.04·|Δv|·min(M_a,M_b)^0.5` 伤害（无基数项）。
## 返回本次造成的伤害（单侧），双方相同。
## `other` 故意不加类型标注：本脚本没有 class_name，写 `other: TankBody` 会解析失败；
## 因此下面每个从 other 取值的局部变量都显式标注类型。
func apply_tank_collision(other) -> float:
	if destroyed or other == null:
		return 0.0
	if bool(other.destroyed):
		return 0.0
	var other_cells: Array = other.cells
	if cells.is_empty() or other_cells.is_empty():
		return 0.0
	var a := world_bounds()
	var b: Rect2 = other.world_bounds()
	if not a.intersects(b):
		return 0.0
	var overlap_x := minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	var overlap_y := minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	if overlap_x <= 0.0 or overlap_y <= 0.0:
		return 0.0
	var other_position: Vector2 = other.position
	## 分离方向：从本体的 AABB 中心指向对方。两车同心时用位置差，仍相同则取 +X（确定性）。
	var push := b.get_center() - a.get_center()
	if push.length_squared() <= 0.0001:
		push = other_position - position
	if push.length_squared() <= 0.0001:
		push = Vector2.RIGHT
	var axis := Vector2.RIGHT if absf(push.x) >= absf(push.y) else Vector2.DOWN
	if push.dot(axis) < 0.0:
		axis = -axis
	var depth := overlap_x if axis == Vector2.RIGHT else overlap_y
	## 按质量反比分配分离量：重的少动。M 为 0 时两侧各一半。
	var other_mass: float = float(other.mass_total)
	var total_mass: float = mass_total + other_mass
	var self_share := 0.5
	if total_mass > 0.0:
		self_share = other_mass / total_mass
	var other_share := 1.0 - self_share
	position -= axis * (depth * self_share)
	other.position = other_position + axis * (depth * other_share)
	## 法向相对速度：axis 由 A 指向 B，因此 relative·axis > 0 才是相互接近。
	## R17-9 修正：原实现写成 `-relative.dot(axis)`，导致任何对撞都被判为「正在远离」而直接返回 0，
	## 互撞伤害永远不会结算，两车也只会被位置分开而不减速。
	var other_velocity: Vector2 = other.velocity
	var relative := velocity - other_velocity
	var closing := relative.dot(axis)
	if closing <= 0.0:
		return 0.0
	## 完全非弹性碰撞：法向速度按质量反比吸收（重的少改变）。M 为 0 时两侧各一半。
	velocity -= axis * (closing * self_share)
	other.velocity = other_velocity + axis * (closing * other_share)
	if not collision_damage_enabled or closing <= _wall_min_speed:
		return 0.0
	## design §8.7：dmg = 0.04·|Δv|·min(M_a,M_b)^0.5，两条车各吃一份（无基数项）。
	var light := minf(mass_total, other_mass)
	var damage := _ram_per_speed * closing * sqrt(maxf(light, 0.0))
	if damage <= 0.0:
		return 0.0
	impact_damage_total += damage
	_apply_impact_damage(axis, damage)
	var other_total: float = float(other.impact_damage_total)
	other.impact_damage_total = other_total + damage
	other._apply_impact_damage(-axis, damage)
	return damage

## 扣血；归零即从 parts 移除该部件，并经 force_remove 回写 GridBuilder。
## 不回写会让后续 rebuild 把已毁部件复活，所以回写是必需的。
## 返回 {destroyed, key, kind, module_id, cells, core}；未归零时 destroyed=false。
## detach、殉爆、判负等连锁结算由 damage_system 负责，本函数只处理单部件。
func damage_part(index: int, amount: float) -> Dictionary:
	var result := {
		"destroyed": false,
		"key": "",
		"kind": "",
		"module_id": "",
		"cells": [],
		"core": false,
	}
	if index < 0 or index >= parts.size() or amount <= 0.0:
		return result
	var part: Dictionary = parts[index]
	part["hp"] = maxf(0.0, float(part["hp"]) - amount)
	if float(part["hp"]) > 0.0:
		return result
	var kind := String(part["kind"])
	var module_id := String(part["module_id"])
	var occupied: Array = (part["cells"] as Array).duplicate()
	var is_core := bool(definitions.get_module(module_id).get("core", false))
	result["destroyed"] = true
	result["key"] = String(part.get("key", ""))
	result["kind"] = kind
	result["module_id"] = module_id
	result["cells"] = occupied
	result["core"] = is_core
	if is_core:
		destroyed = true
		velocity = Vector2.ZERO
		angular_velocity = 0.0
	parts.remove_at(index)
	_remove_from_source(kind, occupied)
	_rebuild_cells()
	recompute()
	_update_effective_turn()
	return result

## 把被摧毁部件从建造模型里强制移除；detach 由 damage_system 负责。
func _remove_from_source(kind: String, occupied: Array) -> void:
	if _source == null or occupied.is_empty():
		return
	var layer := "module"
	if kind == KIND_PLATFORM_CELL or kind == KIND_PLATFORM_SHAPE:
		layer = "platform"
	elif kind == KIND_MOBILITY:
		layer = "mobility"
	_source.force_remove(layer, Vector2i(occupied[0]))

## 开火后坐：沿 -dir 施加冲量 recoil_px，同时产生 cross(r, J)/I 的角速度增量。
func apply_recoil(recoil_px: float, dir_world: Vector2, world_r: Vector2) -> void:
	if destroyed or mass_total <= 0.0 or recoil_px <= 0.0:
		return
	var impulse := -dir_world.normalized() * recoil_px
	velocity += impulse / mass_total
	angular_velocity = clampf(
		angular_velocity + world_r.cross(impulse) / maxf(inertia, _i_min),
		-_omega_max,
		_omega_max
	)

func parts_of_kind(kind: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for part in parts:
		if String(part["kind"]) == kind:
			result.append(part)
	return result

func _cell_centre_local(cell: Vector2i) -> Vector2:
	return (Vector2(cell) + Vector2(0.5, 0.5)) * _cell_size

## 稳定部件标识：跨 rebuild 不变，供 damage_system 的护盾表与升级表引用。
## 同一格上不同层的部件靠 kind 前缀区分。
static func part_key(kind: String, module_id: String, cells: Array) -> String:
	if cells.is_empty():
		return "%s|%s|" % [kind, module_id]
	var first: Vector2i = cells[0]
	return "%s|%s|%d,%d" % [kind, module_id, first.x, first.y]
