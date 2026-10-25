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
## v3.25：横向（垂直于车头）阻力。履带车不会像冰球一样横滑，旧版只有一项二次阻力，
## 横向速度要 1.3 s 才衰减，这就是用户说的「摩擦力很低」。
var _k_lateral_drag: float = 0.05
var _k_ang_drag: float = 0.35
## v3.25：始终生效的线性角阻尼（履带横向磨擦）。旧版只在松手时才有线性制动，
## 按住转向时 ω 瞬间撞到 OMEGA_MAX，转向只有「满舵」与「停」两档。
var _k_ang_damp: float = 3.0
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

## v3.30 性能：世界坐标格矩形缓存。
##
## **为什么需要**：生存模式 wave12 实测 `_resolve_tank_collisions` 单帧 122.7 ms（占
## `Duel.step` 的 85%），而那一帧 15 对坦克的 AABB **一对都没重叠**。根因不是「碰撞判定
## 本身对」，而是每次判定都从零重建「每格四角」——258 个部件、每帧几十次，全是纯分配与旋转。
##
## 缓存键是 `(position, heading, cells.size(), parts.size())`：只要这一帧没动过、结构也没变，
## 重复调用就直接复用；一旦移动或 `_rebuild_cells()` 就失效。**判定结果与不缓存时完全一致**，
## 因此不改变任何玩法结果，也不破坏确定性（`step_battle(dt)` 连拍仍逐字节相同）。
##
## **返回的数组是共享只读的**：调用方只允许遍历，不得修改、不得保存后跨帧使用。
var _rect_cache: Array = []
var _rect_cache_valid: bool = false
var _rect_cache_position: Vector2 = Vector2.ZERO
var _rect_cache_heading: float = 0.0
var _rect_cache_cells: int = -1
var _rect_cache_parts: int = -1

## v3.30：整车 AABB 缓存。`world_bounds()` 每帧被对撞循环调 30 次（15 对 × 2），
## 即使格矩形已缓存，它仍要遍历 258 格 × 4 角。同样的失效条件。
var _bounds_cache: Rect2 = Rect2()
var _bounds_cache_valid: bool = false
var _bounds_cache_position: Vector2 = Vector2.ZERO
var _bounds_cache_heading: float = 0.0
var _bounds_cache_cells: int = -1
var _bounds_cache_parts: int = -1

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
	_k_lateral_drag = definitions.global_number("k_lateral_drag", 0.05)
	_k_ang_drag = definitions.global_number("k_ang_drag", 0.35)
	_k_ang_damp = definitions.global_number("k_ang_damp", 3.0)
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
	_rect_cache_valid = false
	_bounds_cache_valid = false
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
	## 质心变了，格世界的四角也跟着变；两份缓存必须失效。
	_rect_cache_valid = false
	_bounds_cache_valid = false
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
	_rect_cache_valid = false
	_bounds_cache_valid = false

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
	## v3.25：把速度拆成**纵向 / 横向**两个分量分别施加阻力。
	## 旧版只有一项二次阻力作用于整个速度向量，横向速度衰减时间常约 1.3 s——
	## 等于没有履带抓地力：松油门后长时间滑行，转弯时整台车跟着平移。
	## 拆开后 `max_speed()` 的闭式 sqrt(T/(M·k_drag)) 仍精确成立（直线行驶时横向分量为 0）。
	var lateral_axis := forward.orthogonal()
	var forward_speed := velocity.dot(forward)
	var lateral_speed := velocity.dot(lateral_axis)
	var accel_forward := thrust_total / mass_total - _k_drag * forward_speed * absf(forward_speed)
	var accel_lateral := -_k_lateral_drag * lateral_speed * absf(lateral_speed)
	var inertia_eff := maxf(inertia, _i_min)
	var alpha := torque_total / inertia_eff - _k_ang_drag * angular_velocity * absf(angular_velocity)
	## v3.25：线性角阻尼**始终**生效——它才是「转向有阻尼」的手感来源。
	## 旧版把线性项只放在「松手」分支里，于是按住转向时 ω 一路撞到 OMEGA_MAX。
	alpha -= _k_ang_damp * angular_velocity
	## 无转向输入时地面横摆阻尼占主导：角速度线性收敛，松手即停（design §5.2）。
	if absf(steer) <= 0.001:
		alpha -= _k_ang_brake * angular_velocity
	velocity += (forward * accel_forward + lateral_axis * accel_lateral) * dt
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

## v3.30：改为从 `cell_world_rects()` 的缓存四角求极值，并**把结果也缓存**。
## 两者在数学上完全等价（都是「所有格角点的 min/max」），但共享同一份缓存，
## 不再重复算旋转，也不重复遍历。
##
## **为什么要缓存**：wave12 的对撞循环每帧调 `world_bounds()` 30 次（15 对 × 2）；
## 即使格矩形已缓存，每次仍要遍历 258 个格 × 4 角 = 1032 个点。实测这一项就让
## `collisions` 卡在 11.6 ms 不降。
##
## 失效条件与 `cell_world_rects()` 完全一致（位置/朝向/格数/部件数/质心）。
func world_bounds() -> Rect2:
	if _bounds_cache_valid \
			and _rect_cache_valid \
			and _bounds_cache_cells == cells.size() \
			and _bounds_cache_parts == parts.size() \
			and _bounds_cache_position == position \
			and _bounds_cache_heading == heading:
		return _bounds_cache
	if cells.is_empty():
		_bounds_cache = Rect2(position, Vector2.ZERO)
		_bounds_cache_valid = true
		_bounds_cache_position = position
		_bounds_cache_heading = heading
		_bounds_cache_cells = 0
		_bounds_cache_parts = parts.size()
		return _bounds_cache
	var rects := cell_world_rects()
	if rects.is_empty():
		return Rect2(position, Vector2.ZERO)
	var min_p := Vector2(INF, INF)
	var max_p := Vector2(-INF, -INF)
	for entry in rects:
		var corners: Array = entry["corners"]
		for raw_corner in corners:
			var point: Vector2 = raw_corner
			min_p.x = minf(min_p.x, point.x)
			min_p.y = minf(min_p.y, point.y)
			max_p.x = maxf(max_p.x, point.x)
			max_p.y = maxf(max_p.y, point.y)
	_bounds_cache = Rect2(min_p, max_p - min_p)
	_bounds_cache_valid = true
	_bounds_cache_position = position
	_bounds_cache_heading = heading
	_bounds_cache_cells = cells.size()
	_bounds_cache_parts = parts.size()
	return _bounds_cache

## 逐格的世界坐标**旋转矩形**（OBB）四角。每个存活格一项：
## `{cell, part_index, corners:[四个 Vector2]}`，四角顺序为 左上/右上/右下/左下（已旋转）。
## 这是碰撞箱的唯一真相来源：坦克的体积就是这些格子的并集，格与格之间的凹口不是碰撞体。
## 与 `world_bounds()` 的区别：外接框会把两块分离的格之间的空白也算进去，而这里不会。
##
## v3.30：**带缓存**（见文件头 `_rect_cache` 的说明）。返回的数组是共享只读的，
## 调用方只可遍历。判定结果与不缓存时逐位相同。
func cell_world_rects() -> Array:
	if _rect_cache_valid \
			and _rect_cache_cells == cells.size() \
			and _rect_cache_parts == parts.size() \
			and _rect_cache_position == position \
			and _rect_cache_heading == heading:
		return _rect_cache
	var out: Array = []
	if cells.is_empty():
		_rect_cache = out
		_rect_cache_valid = true
		_rect_cache_position = position
		_rect_cache_heading = heading
		_rect_cache_cells = 0
		_rect_cache_parts = parts.size()
		return out
	var half := _cell_size * 0.5
	for unit in cells:
		var centre := position + (Vector2(unit["local"]) - centroid_local).rotated(heading)
		var corners: Array[Vector2] = []
		for offset in [Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)]:
			corners.append(centre + (offset as Vector2).rotated(heading))
		out.append({
			"cell": Vector2i(unit["cell"]),
			"part_index": int(unit["part_index"]),
			"centre": centre,
			"corners": corners,
		})
	_rect_cache = out
	_rect_cache_valid = true
	_rect_cache_position = position
	_rect_cache_heading = heading
	_rect_cache_cells = cells.size()
	_rect_cache_parts = parts.size()
	return out

## 逐格与轴对齐矩形的相交测试（分离轴定理，只需测两个矩形各自的边法线）。
## 返回**穿透最浅**的那一格：`{hit, depth, normal, cell, part_index}`。
## `normal` 是「从目标格指向 rect」的方向，推出时沿它反方向平移本体。
## 为什么不用外接框：外接框会把 L 形车的凹口当成实心，车明明能进去却被弹开。
func cell_overlap_rect(rect: Rect2) -> Dictionary:
	var best := {"hit": false, "depth": INF, "normal": Vector2.ZERO, "cell": Vector2i.ZERO, "part_index": -1}
	for entry in cell_world_rects():
		var corners: Array[Vector2] = entry["corners"]
		var centre: Vector2 = entry["centre"]
		## 格子的两条正交轴：u = 格子的「向右」向量（已旋转），v = 其垂直。
		var u: Vector2 = ((corners[1] - corners[0]) as Vector2).normalized()
		var v: Vector2 = ((corners[3] - corners[0]) as Vector2).normalized()
		var half_extent := _cell_size * 0.5
		var rect_centre := rect.get_center()
		var rect_half := rect.size * 0.5
		## 两个矩形的四条轴：格子的 u/v，与矩形自身的 X/Y。
		var axes: Array[Vector2] = [u, v, Vector2.RIGHT, Vector2.DOWN]
		var overlap := INF
		var axis_best := Vector2.ZERO
		var separated := false
		for axis in axes:
			var self_radius := half_extent * (absf(axis.dot(u)) + absf(axis.dot(v)))
			var other_radius := rect_half.x * absf(axis.dot(Vector2.RIGHT)) + rect_half.y * absf(axis.dot(Vector2.DOWN))
			var distance := absf((rect_centre - centre).dot(axis))
			var gap := self_radius + other_radius - distance
			if gap <= 0.0:
				separated = true
				break
			if gap < overlap:
				overlap = gap
				axis_best = axis if (rect_centre - centre).dot(axis) >= 0.0 else -axis
		if separated:
			continue
		if overlap < float(best["depth"]):
			best = {
				"hit": true,
				"depth": overlap,
				"normal": axis_best,
				"cell": entry["cell"],
				"part_index": entry["part_index"],
			}
	return best

## 逐格与圆的相交测试，返回**穿透最深**的那一格。
##
## 为什么是「最深」而不是「最浅」：一个半径大于格子的圆会同时压住几格，
## 取最浅的一格只能推出一点点，下一步又轮到相邻格，在格与格之间反复横跳、永不收敛
## （实测卡在 depth=0 的死循环）。取最深的一格可以一次推够。
## `depth` 的几何含义：要让这一格完全不与圆相交，需沿 `normal` 反方向移动的距离。
func cell_overlap_circle(centre: Vector2, radius: float) -> Dictionary:
	var best := {"hit": false, "depth": -INF, "normal": Vector2.ZERO, "cell": Vector2i.ZERO, "part_index": -1}
	if radius <= 0.0:
		return best
	var half := _cell_size * 0.5
	for entry in cell_world_rects():
		var cell_centre: Vector2 = entry["centre"]
		var relative := centre - cell_centre
		## 变换到格子局部轴（逆旋转，用两角构造正交基）。
		var corners: Array[Vector2] = entry["corners"]
		var u: Vector2 = ((corners[1] - corners[0]) as Vector2).normalized()
		var v := Vector2(-u.y, u.x)
		var local := Vector2(relative.dot(u), relative.dot(v))
		## 圆心到矩形的最近点（局部）。
		var closest := Vector2(clampf(local.x, -half, half), clampf(local.y, -half, half))
		var delta := local - closest
		var distance := delta.length()
		var depth := 0.0
		var local_normal := Vector2.ZERO
		if distance > 0.0001:
			if distance >= radius:
				continue
			depth = radius - distance
			local_normal = delta / distance
		else:
			## 圆心在格内：先出格边界（dx/dy），再退一个半径。
			var dx := half - absf(local.x)
			var dy := half - absf(local.y)
			if dx < 0.0 or dy < 0.0:
				continue
			if dx < dy:
				local_normal = Vector2(signf(local.x) if local.x != 0.0 else 1.0, 0.0)
				depth = dx + radius
			else:
				local_normal = Vector2(0.0, signf(local.y) if local.y != 0.0 else 1.0)
				depth = dy + radius
		if depth > float(best["depth"]):
			best = {
				"hit": true,
				"depth": depth,
				"normal": u * local_normal.x + v * local_normal.y,
				"cell": entry["cell"],
				"part_index": entry["part_index"],
			}
	return best

## 逐格的世界凸多边形是否与另一台坦克的逐格凸多边形相交（SAT，两套格的轴）。
## 返回 `{hit, depth, normal}`，`normal` 指向 other。
## 为什么不用外接框：两台车车角相对、中间隔两格虚空时，外接框判定为碰撞，逐格判定为不碰。
##
## **v3.30 宽相剔除（性能修复，不改变结果）**：先比整车 AABB。
## 数学依据：整车 AABB 是「所有格角点的 min/max」，因此**每一格的凸包必然完全落在
## 自己的整车 AABB 内**。若两个 AABB 不相交，则任何一格对都不可能相交。
## 为什么必须加：生存 wave12 实测单帧 122.7 ms，其中 15 对车里 **AABB 真正重叠的是 0 对**——
## 全花在「一定不相交」的逐格两两 SAT 上（O(n²)）。
##
## **为什么用自写的 `_aabb_apart()` 而不是 `Rect2.intersects()`**：实测发现一个 1.5e-5 px
## 的边界反例 —— float32 在坐标戳 1088 量级时，AABB 取极值舍入到 1088.0，而 SAT 的半径
## 算得 1087.999985，于是「AABB 说不碰、SAT 说碰」。虽然 1.5e-5 px 在物理上无意义，
## 但「纯加速」就该一位不变，所以剔除必须**保守**：留 `AABB_EPSILON` 的余量，
## 边界附近一律放行给精确算法。`Rect2.intersects()` 默认 `include_borders=false`，
## 本身也会把「刚刚贴上」当成不碰，不适合做剔除。
const AABB_EPSILON := 0.01

## 两个 AABB 是否确定「分开得很远」：只有完全确定不相交才返回 true。
## 保留 `AABB_EPSILON` 余量，宁可多算不可漏算。
static func _aabb_apart(a: Rect2, b: Rect2) -> bool:
	if a.position.x - AABB_EPSILON > b.end.x:
		return true
	if b.position.x - AABB_EPSILON > a.end.x:
		return true
	if a.position.y - AABB_EPSILON > b.end.y:
		return true
	if b.position.y - AABB_EPSILON > a.end.y:
		return true
	return false

func cells_overlap_tank(other) -> Dictionary:
	if destroyed or other == null or bool(other.destroyed):
		return {"hit": false, "depth": 0.0, "normal": Vector2.ZERO}
	if _aabb_apart(world_bounds(), other.world_bounds()):
		return {"hit": false, "depth": 0.0, "normal": Vector2.ZERO}
	var mine := cell_world_rects()
	var theirs: Array = other.cell_world_rects()
	if mine.is_empty() or theirs.is_empty():
		return {"hit": false, "depth": 0.0, "normal": Vector2.ZERO}
	## **v3.30 空间分桶**：把对方的格按 `_cell_bucket_key()` 装进字典，然后只查
	## 自己每格周围 3×3 个桶。桶边长取 `cell_size`（=格宽），而格 AABB 最大对角线
	## 为 `cell_size·√2`，所以真实相交的对方格中心必然落在自己的 ±1 桶内。
	## **为什么要这一步**：逐格 AABB 预筛把每条格对降到几纳秒，但格对总量是 n×m
	## （wave12 两组大车各 258 格 → 66k 对 × 15 车对 = 百万级），预筛本身就成了瓶颈。
	## 分桶后每格只查常数个候选，是真正的 O(n+m)。
	var buckets: Dictionary = {}
	for raw_b in theirs:
		var b_entry: Dictionary = raw_b
		var key := _cell_bucket_key(Vector2(b_entry["centre"]))
		if buckets.has(key):
			(buckets[key] as Array).append(b_entry)
		else:
			buckets[key] = [b_entry]
	var best := {"hit": false, "depth": INF, "normal": Vector2.ZERO}
	for raw_a in mine:
		var a: Dictionary = raw_a
		var a_centre: Vector2 = a["centre"]
		var a_corners: Array[Vector2] = a["corners"]
		var au: Vector2 = ((a_corners[1] - a_corners[0]) as Vector2).normalized()
		var av := Vector2(-au.y, au.x)
		var cell_key := _cell_bucket_key(a_centre)
		for dx in range(-CELL_BUCKET_RADIUS, CELL_BUCKET_RADIUS + 1):
			for dy in range(-CELL_BUCKET_RADIUS, CELL_BUCKET_RADIUS + 1):
				var probe: Vector2i = cell_key + Vector2i(dx, dy)
				if not buckets.has(probe):
					continue
				for raw_b in buckets[probe]:
					var b: Dictionary = raw_b
					var b_centre: Vector2 = b["centre"]
					var b_corners: Array[Vector2] = b["corners"]
					## 桶内仍保留一道保守 AABB 预筛（`_aabb_apart` 带 eps）：9 个桶里的候选
					## 大多仍相距一格以上，这一步几乎免费但能挡掉绝大多数。
					if _aabb_apart(_cell_aabb(a_corners), _cell_aabb(b_corners)):
						continue
					var bu: Vector2 = ((b_corners[1] - b_corners[0]) as Vector2).normalized()
					var bv := Vector2(-bu.y, bu.x)
					var separated := false
					var overlap := INF
					var axis_best := Vector2.ZERO
					for axis in [au, av, bu, bv]:
						var self_radius := half_extent_of(a_corners) * (absf(axis.dot(au)) + absf(axis.dot(av)))
						var other_radius := half_extent_of(b_corners) * (absf(axis.dot(bu)) + absf(axis.dot(bv)))
						var distance := absf((b_centre - a_centre).dot(axis))
						var gap := self_radius + other_radius - distance
						if gap <= 0.0:
							separated = true
							break
						if gap < overlap:
							overlap = gap
							axis_best = axis if (b_centre - a_centre).dot(axis) >= 0.0 else -axis
					if separated:
						continue
					if overlap < float(best["depth"]):
						best = {"hit": true, "depth": overlap, "normal": axis_best}
	return best

## 把世界坐标映射到 `_cell_size` 大小的桶下标（向下取整，跨负数也单调）。
## **桶边长必须等于格宽**，并在查询时扫 ±`CELL_BUCKET_RADIUS` 个桶：
## 两个格的 AABB 相交时中心距最大为 `cell_size·√2`（角对角），除以桶宽得 1.414，
## 再加上向下取整可能跨格一次，所以半径必须取 **2**。取 1 会漏掉真实碰撞。
const CELL_BUCKET_RADIUS := 2

func _cell_bucket_key(at: Vector2) -> Vector2i:
	return Vector2i(int(floorf(at.x / _cell_size)), int(floorf(at.y / _cell_size)))

## 格四角的轴对齐包围盒（**取真实四角的极值**，不是「中心 ± 半格」）。
## 只用于 `cells_overlap_tank()` 的逐格预筛；不参与任何精确判定。
##
## **为什么不能用「中心 ± 半格」**：格子随车体旋转，旋转后的 16×16 方块其 AABB 边长
## 最大可到 16√2 ≈ 22.6。用「中心 ± 8」会**低估**，于是把真实相交的格对判成分开。
## 这个错误被 `_tmp_verify.gd` 在 wave8 / wave12 各抓到 12 起（fast=false slow=true）。
func _cell_aabb(corners: Array) -> Rect2:
	if corners.size() < 1:
		return Rect2()
	var min_p: Vector2 = corners[0]
	var max_p: Vector2 = corners[0]
	for raw_corner in corners:
		var point: Vector2 = raw_corner
		min_p.x = minf(min_p.x, point.x)
		min_p.y = minf(min_p.y, point.y)
		max_p.x = maxf(max_p.x, point.x)
		max_p.y = maxf(max_p.y, point.y)
	return Rect2(min_p, max_p - min_p)

## 取四角构成的正方形的半边长（格子的边长恒为 cell_size，但保留通用写法）。
func half_extent_of(corners: Array) -> float:
	if corners.size() < 2:
		return _cell_size * 0.5
	return ((corners[1] as Vector2) - (corners[0] as Vector2)).length() * 0.5

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
	## 边界是轴对齐的，所以这里用 `world_bounds()` 是**精确的**：它的 min/max 就是
	## 所有格角点的极值，与逐格取极限结果完全一致，不存在「凹口被当成实心」的问题。
	## 逐格判定只在**非轴对齐形状**（旋转的格 vs 矩形/圆/另一台车）上才有意义，
	## 那几处见 `cell_overlap_rect()` / `cell_overlap_circle()` / `cells_overlap_tank()`。
	var bounds := world_bounds()
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
##
## v3.30 宽相剔除：障碍的 AABB 与整车 AABB 不相交就直接跳过。
## 数学依据与 `cells_overlap_tank()` 同：整车 AABB 是每格 AABB 的并集，
## 所以 AABB 不相交 ⇒ 没有任何一格能碰上该障碍。判定结果完全相同，只是不再白算。
## 生存 wave12 实测 `apply_obstacles` 15.9 ms/帧，其中绝大部分花在「车在场地另一端」的
## 远障碍上。
##
## 剔除用 `_aabb_apart()`（带 `AABB_EPSILON` 余量的保守判定），不用 `Rect2.intersects()`：
## 后者在边界上把自己当成「不碰」，且 float32 舍入已实测能在 1.5e-5 px 量级上
## 让「AABB 不碰」与「逐格 SAT 碰」同时成立。纯加速不允许这种事发生。
func apply_obstacles(obstacles: Array) -> float:
	if destroyed or cells.is_empty():
		return 0.0
	var before := impact_damage_total
	var bounds := world_bounds()
	for obstacle in obstacles:
		var shape := String(obstacle.get("shape", ""))
		if shape == "rect":
			var rect := Rect2(obstacle["rect"])
			if _aabb_apart(bounds, rect):
				continue
			var was_position := position
			_resolve_obstacle_rect(rect)
			## 被推开后 AABB 变了，后续障碍的剔除必须用新包围盒——否则会少判一个真实碰撞，
			## 那就不是纯加速而是改变玩法结果了。
			if position != was_position:
				bounds = world_bounds()
		elif shape == "circle":
			var centre := Vector2(obstacle["center"])
			var radius := float(obstacle.get("radius", 0.0))
			if radius <= 0.0:
				continue
			var circle_box := Rect2(centre - Vector2(radius, radius), Vector2(radius, radius) * 2.0)
			if _aabb_apart(bounds, circle_box):
				continue
			var was_circle_position := position
			_resolve_obstacle_circle(centre, radius)
			if position != was_circle_position:
				bounds = world_bounds()
	return impact_damage_total - before

## 矩形障碍：逐格求交，迭代推出。
## **v3.20 改用逐格**：旧实现拿整车外接框与障碍求交，斜放的细长车会用外接框的四角
## 去碰障碍，那些角其实是虚空；L 形车的凹口也会被当成实心，车明明能骑进去却被弹开。
## 现在只问「有没有某一个真实的格子压在障碍上」，并用 SAT 得到的**最短分离轴**推出。
##
## **为什么要迭代**：一次只按「当前最浅的那一格」推，推出后相邻的格子可能又压上了
## （比如圆半径大于半车宽时）。所以循环到逐格不再命中为止，最多 `MAX_PUSH_ITERATIONS` 次。
## 伤害只在**最后一次**结算，避免同一帧反复扣血（R17-4 的墙角双扣就是这个毛病）。
const MAX_PUSH_ITERATIONS := 8

func _resolve_obstacle_rect(rect: Rect2) -> void:
	var total_push := Vector2.ZERO
	var last_normal := Vector2.ZERO
	var last_depth := 0.0
	for iteration in range(MAX_PUSH_ITERATIONS):
		var overlap := cell_overlap_rect(rect)
		if not bool(overlap["hit"]):
			break
		var normal: Vector2 = overlap["normal"]
		var depth := float(overlap["depth"])
		## `normal` 由格指向矩形，推开本体要沿反方向；先累积位移，最后一次性应用。
		position -= normal * depth
		total_push += normal * depth
		last_normal = normal
		last_depth = depth
	if last_normal == Vector2.ZERO:
		return
	## 位移已经做过（在循环里），这里只结算速度与伤害，传 penetration = 0。
	_resolve_contact([last_normal], 0.0)

## 圆形障碍：逐格求交，迭代推出（理由同矩形，见 `MAX_PUSH_ITERATIONS`）。
## **v3.20 改用逐格**：旧实现用整车外接框与圆求最近点——外接框的四个角在斜放车上
## 是虚空，圆压到那个角也会把车推开；而真正的格子可能在圆外，实际没碰。
func _resolve_obstacle_circle(centre: Vector2, radius: float) -> void:
	if radius <= 0.0:
		return
	## **先判断圆是否埋在本体内部**（圆心落在某个格内）。
	## 这种退化情形不能用逐格求最小平移：圆心在车里时，任何一格都「命中且穿透很小」，
	## 逐格迭代会在格与格之间弹来弹去，永远推不干净（实测会卡在 depth=0 的死循环）。
	## 正确的语义是：**圆整个埋在车里，按整车轮廓把它推出**——这时外接框反而是对的。
	for entry in cell_world_rects():
		var corners: Array[Vector2] = entry["corners"]
		var u: Vector2 = ((corners[1] - corners[0]) as Vector2).normalized()
		var v := Vector2(-u.y, u.x)
		var local_rel := centre - (entry["centre"] as Vector2)
		var half := _cell_size * 0.5
		if absf(local_rel.dot(u)) <= half and absf(local_rel.dot(v)) <= half:
			_resolve_circle_inside_hull(centre, radius)
			return
	var last_normal := Vector2.ZERO
	for iteration in range(MAX_PUSH_ITERATIONS):
		var overlap := cell_overlap_circle(centre, radius)
		if not bool(overlap["hit"]):
			break
		var normal: Vector2 = overlap["normal"]
		var depth := float(overlap["depth"])
		if depth <= 0.0001:
			## 退化：已经贴住但没有可推的穿透，再迭代也是原地打转。
			break
		## `normal` 由格指向圆心，推开本体要沿反方向。
		position -= normal * depth
		last_normal = normal
	if last_normal == Vector2.ZERO:
		return
	_resolve_contact([last_normal], 0.0)

## 圆心落在车体**内部**时的兜底：把整车轮廓推到圆外。
## 这是旧的 R17-3 分支，语义仍然正确——只是不再用于「圆心在车外」的正常碰撞。
func _resolve_circle_inside_hull(centre: Vector2, radius: float) -> void:
	var bounds := world_bounds()
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
	## **v3.20 改用逐格 SAT**：旧实现拿两台车的外接框相交就判碰。两台 L 形车
	## 车角相对、中间隔着两格虚空时，外接框已经相交，于是它们会凭空互撞并扣血。
	## 现在要求至少存在一对**真实的格子**相交，并用最短分离轴推开。
	var contact := cells_overlap_tank(other)
	if not bool(contact["hit"]):
		return 0.0
	var other_position: Vector2 = other.position
	## `normal` 由本体指向对方，与下面的法向相对速度计算方向一致。
	var axis: Vector2 = contact["normal"]
	var depth := float(contact["depth"])
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
