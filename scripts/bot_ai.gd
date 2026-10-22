extends RefCounted

## M6 机器人 AI（design §10）。三层：战略 2 Hz 选目标格、战术 10 Hz 走位、执行 60 Hz 转向与开火。
## 难度只改变反应延迟与瞄准误差，不改蓝图数值（§10.2「难度差异只体现在操作质量」）。
## 确定性：内部用显式 LCG 产生瞄准抖动，种子由外部传入；不使用 randf/randi，可完整复现（§10.4）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const Duel := preload("res://scripts/duel.gd")

const TIER_RECRUIT := "recruit"
const TIER_VETERAN := "veteran"
const TIER_ELITE := "elite"
const TIER_ACE := "ace"
const TIERS := [TIER_RECRUIT, TIER_VETERAN, TIER_ELITE, TIER_ACE]

var definitions: ModuleDefs
var tier: String = TIER_VETERAN
var self_tag: String = Duel.TAG_ENEMY
var target_tag: String = Duel.TAG_PLAYER

## 战略层输出：目标格（世界像素中心）与目标类型
var strategic_cell: Vector2i = Vector2i.ZERO
var strategic_kind: String = ""
## 战术层输出：期望油门与绕侧方向
var tactical_throttle: float = 0.0
var tactical_orbit: float = 0.0
## 执行层输出
var throttle: float = 0.0
var steer: float = 0.0
var want_fire: bool = false

var _reaction_s: float = 0.22
var _aim_error_deg: float = 3.0
var _strategic_period: float = 0.5
var _tactical_period: float = 0.1
var _preferred_range_px: float = 192.0
var _range_deadband_px: float = 48.0
var _fire_arc_rad: float = 0.105
var _neck_bias: float = 0.75

var _strategic_timer: float = 0.0
var _tactical_timer: float = 0.0
## 反应延迟：新决策先排队，过 _reaction_s 才生效（§10.3「反应延迟」列）
var _pending_cell: Vector2i = Vector2i.ZERO
var _pending_kind: String = ""
var _pending_wait: float = 0.0
var _has_pending: bool = false
var _rng_state: int = 1
## 该档是否使用驾驶舱结构分析（§10.3「结构分析」列：新兵/老兵不用，精英起分析）
var uses_structure_analysis: bool = false

func setup(module_defs: ModuleDefs, difficulty: String = TIER_VETERAN, seed_value: int = 1) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	tier = difficulty if TIERS.has(difficulty) else TIER_VETERAN
	uses_structure_analysis = tier == TIER_ELITE or tier == TIER_ACE
	_rng_state = maxi(seed_value, 1)
	_reaction_s = definitions.block_number("ai", "reaction_ms_%s" % tier, 220.0) / 1000.0
	_aim_error_deg = definitions.block_number("ai", "aim_error_deg_%s" % tier, 3.0)
	_strategic_period = 1.0 / maxf(definitions.block_number("ai", "strategic_hz", 2.0), 0.1)
	_tactical_period = 1.0 / maxf(definitions.block_number("ai", "tactical_hz", 10.0), 0.1)
	var cell := definitions.global_number("cell_size", 16.0)
	_preferred_range_px = definitions.block_number("ai", "bot_preferred_range_cells", 12.0) * cell
	_range_deadband_px = definitions.block_number("ai", "bot_range_deadband_cells", 3.0) * cell
	_fire_arc_rad = deg_to_rad(definitions.block_number("ai", "bot_fire_arc_deg", 6.0))
	_neck_bias = definitions.block_number("ai", "bot_strategic_neck_bias", 0.75)
	return true

## 单帧决策。duel 提供所有侧的状态；返回本帧采用的操作。
## R18：目标 tag 不再固定。若调用方没指定（或指定目标已死），每帧从「敌对且存活」
## 的 tag 中按确定性规则（距离最近，平局取 tag 字典序最小）选一个。
func think(dt: float, duel: Duel) -> Dictionary:
	var self_tank: TankBody = duel.tank_of(self_tag)
	if self_tank == null or dt <= 0.0:
		throttle = 0.0
		steer = 0.0
		want_fire = false
		return _output()
	_refresh_target(duel, self_tank)
	var target_tank: TankBody = duel.tank_of(target_tag)
	if target_tank == null:
		throttle = 0.0
		steer = 0.0
		want_fire = false
		return _output()
	_strategic_timer += dt
	_tactical_timer += dt
	if _strategic_timer >= _strategic_period:
		_strategic_timer = 0.0
		_choose_target(self_tank, target_tank, duel)
	_tick_pending(dt)
	if _tactical_timer >= _tactical_period:
		_tactical_timer = 0.0
		_plan_motion(self_tank, target_tank)
	_drive(self_tank, target_tank, duel, dt)
	return _output()

## 选定一个敌对且存活的目标 tag。只有当前目标失效时才重新选，避免每帧抖动。
## 优先级：距离平方最小 → tag 字典序最小（确定性）。
func _refresh_target(duel: Duel, self_tank: TankBody) -> void:
	if not target_tag.is_empty() and not duel.defeated(target_tag) and duel.sides.has(target_tag):
		return
	var hostiles := duel.hostiles_of(self_tag)
	if hostiles.is_empty():
		target_tag = ""
		return
	var best := ""
	var best_distance := INF
	for raw_tag in hostiles:
		var tag := String(raw_tag)
		var tank: TankBody = duel.tank_of(tag)
		if tank == null:
			continue
		var distance := self_tank.position.distance_squared_to(tank.position)
		if distance < best_distance - 0.0001:
			best_distance = distance
			best = tag
		elif absf(distance - best_distance) <= 0.0001 and (best.is_empty() or tag < best):
			best = tag
	target_tag = best

func _output() -> Dictionary:
	return {"throttle": throttle, "steer": steer, "fire": want_fire, "target_cell": strategic_cell, "target_kind": strategic_kind}

## 战略层：精英/王牌分析通往驾驶舱的最短平台链路并优先打断它（§10.1 战略层、§10.3 结构分析）。
## 新兵/老兵不读驾驶舱位置，只打最近的模块（§10.3）。
func _choose_target(self_tank: TankBody, target_tank: TankBody, duel: Duel) -> void:
	var chosen := Vector2i.ZERO
	var kind := ""
	if uses_structure_analysis:
		var neck := _find_neck(duel, target_tag)
		if not neck.is_empty():
			chosen = Vector2i(neck["cell"])
			kind = String(neck["kind"])
	if chosen == Vector2i.ZERO and kind.is_empty():
		var nearest := _nearest_part(self_tank, target_tank)
		chosen = Vector2i(nearest["cell"])
		kind = String(nearest["kind"])
	## 反应延迟：决策先挂起，过 _reaction_s 才生效。
	if _has_pending and _pending_cell == chosen and _pending_kind == kind:
		return
	_pending_cell = chosen
	_pending_kind = kind
	_pending_wait = _reaction_s
	_has_pending = true

func _tick_pending(dt: float) -> void:
	if not _has_pending:
		return
	_pending_wait -= dt
	if _pending_wait > 0.0:
		return
	_has_pending = false
	strategic_cell = _pending_cell
	strategic_kind = _pending_kind

## 找驾驶舱连通块的「割点」：删掉某格后若还有非驾驶舱格与驾驶舱不再连通，该格就是割点。
## 打掉它就会触发 §8.5 的 detach（整块脱落），这正是高难度 AI 的结构分析目标。
## 只统计「去掉该格会丢掉多少格」最多的那个，并列时取坐标最小者（确定性）。
func _find_neck(duel: Duel, tag: String) -> Dictionary:
	var builder = duel.builder_of(tag)
	if builder == null:
		return {}
	var anchors: Array = builder.cockpit_cells()
	if anchors.is_empty():
		return {}
	var occupancy: Dictionary = builder.platform_occupancy()
	var island := _flood(occupancy, anchors)
	if island.size() < 3:
		return {}
	var anchor_set := {}
	for raw_anchor in anchors:
		anchor_set[Vector2i(raw_anchor)] = true
	var cells: Array = island.keys()
	cells.sort()
	var best := {}
	var best_lost := 0
	for raw_cell in cells:
		var cell := Vector2i(raw_cell)
		if anchor_set.has(cell):
			continue
		## 拿掉这一格后，从驾驶舱重新连通，能到多少格。
		var reach := _flood_without(occupancy, anchors, cell)
		var lost := island.size() - reach - 1
		if lost <= 0:
			continue
		if lost > best_lost:
			best_lost = lost
			best = {"cell": cell, "kind": "neck/cut%d" % lost}
	return best

## 屏蔽一个格后的 4-连通可达集（从 anchors 出发）。
func _flood_without(occupancy: Dictionary, anchors: Array, blocked: Vector2i) -> int:
	var seen := {}
	var queue: Array[Vector2i] = []
	var neighbours := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]
	for raw_anchor in anchors:
		var anchor := Vector2i(raw_anchor)
		if anchor == blocked:
			continue
		if occupancy.has(anchor) and not seen.has(anchor):
			seen[anchor] = true
			queue.append(anchor)
	var head := 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		for dir in neighbours:
			var next: Vector2i = cell + dir
			if next == blocked or not occupancy.has(next) or seen.has(next):
				continue
			seen[next] = true
			queue.append(next)
	return seen.size()

func _flood(occupancy: Dictionary, anchors: Array) -> Dictionary:
	var seen := {}
	var queue: Array[Vector2i] = []
	var neighbours := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]
	for raw_anchor in anchors:
		var anchor := Vector2i(raw_anchor)
		if occupancy.has(anchor) and not seen.has(anchor):
			seen[anchor] = true
			queue.append(anchor)
	var head := 0
	while head < queue.size():
		var cell: Vector2i = queue[head]
		head += 1
		for dir in neighbours:
			var next: Vector2i = cell + dir
			if occupancy.has(next) and not seen.has(next):
				seen[next] = true
				queue.append(next)
	return seen

func _nearest_part(self_tank: TankBody, target_tank: TankBody) -> Dictionary:
	var best := {}
	var best_distance := INF
	for part in target_tank.parts:
		var cells: Array = part["cells"]
		if cells.is_empty():
			continue
		var cell := Vector2i(cells[0])
		var world: Vector2 = target_tank.world_position_of_cell(cell)
		var distance := self_tank.position.distance_squared_to(world)
		if distance < best_distance:
			best_distance = distance
			best = {"cell": cell, "kind": String(part["kind"]), "world": world}
	if best.is_empty():
		return {"cell": Vector2i.ZERO, "kind": "", "world": target_tank.position}
	return best

## 战术层：保持理想射程；远则前压、近则后退，并对退让方向做确定性绕侧（§10.1 战术层）。
func _plan_motion(self_tank: TankBody, target_tank: TankBody) -> void:
	var to_target := target_tank.position - self_tank.position
	var distance := to_target.length()
	if distance <= 0.001:
		tactical_throttle = 0.0
		tactical_orbit = 0.0
		return
	if distance > _preferred_range_px + _range_deadband_px:
		tactical_throttle = 1.0
	elif distance < _preferred_range_px - _range_deadband_px:
		tactical_throttle = -1.0
	else:
		tactical_throttle = 0.0
	## 绕侧方向由 LCG 决定一次，保持到下次战术更新，避免每帧抖动。
	tactical_orbit = 0.35 if _next_unit() < 0.5 else -0.35

## 执行层：把「期望朝向」翻译成差速转向，并在对准且在射程内时开火。
## 炮管 aim 是安装期锁定的相对角，所以实际弹道方向 = heading + aim（§6.5）。
func _drive(self_tank: TankBody, target_tank: TankBody, duel: Duel, dt: float) -> void:
	var aim_point := strategic_cell_vector(target_tank)
	var to_aim := aim_point - self_tank.position
	if to_aim.length_squared() <= 0.001:
		throttle = 0.0
		steer = 0.0
		want_fire = false
		return
	var desired := to_aim.angle()
	var error := wrapf(desired - self_tank.heading, -PI, PI)
	## 转向：误差大时满舵，误差小时按比例，避免来回摆振。
	steer = clampf(error * 2.2, -1.0, 1.0)
	## 朝目标时全速前压，需要掉头时先转向再走（油门随对准度衰减）。
	var alignment := clampf(1.0 - absf(error) / PI, 0.0, 1.0)
	throttle = clampf(tactical_throttle * alignment + tactical_orbit * (1.0 - alignment), -1.0, 1.0)
	## 开火时机：弹道方向与目标方向的夹角落在 fire_bot_arc 内，且已装填。
	var aim_offset := 0.0
	var bank = duel.bank_of(self_tag)
	if bank != null and not bank.cannons.is_empty():
		aim_offset = deg_to_rad(float(bank.cannons[0]["aim"]))
	var ballistic := wrapf(self_tank.heading + aim_offset - desired, -PI, PI)
	var jitter := deg_to_rad(_aim_error_deg) * (_next_unit() * 2.0 - 1.0)
	want_fire = absf(ballistic + jitter) <= _fire_arc_rad and duel.can_fire(self_tag)

## 战略目标格的世界中心；strategic_cell 为 (0,0) 时退回对方质心。
func strategic_cell_vector(target_tank: TankBody) -> Vector2:
	if strategic_cell == Vector2i.ZERO:
		return target_tank.position
	return target_tank.world_position_of_cell(strategic_cell)

## 显式 LCG（数值取自 Numerical Recipes），只用于瞄准抖动与绕侧选择；
## 因为状态完全由 seed 决定，录制种子即可完整复现（§10.4）。
func _next_unit() -> float:
	_rng_state = (_rng_state * 1664525 + 1013904223) % 4294967296
	return float(_rng_state) / 4294967296.0
