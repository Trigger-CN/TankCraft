extends RefCounted

## M4 弹药输送网络（design §7）。纯逻辑：端口图、算路、20 Hz 四步定序调度、
## 在途容量 1 发/段、装填与拒绝、弹药库槽位、改进装置处理、拥塞与断链状态。
## 不绘制、不读输入，可由无头脚本直接驱动。
##
## 端口几何不在 data 里：data/modules/systems.json 的 ports 只有端口 id 字符串，
## 缺 kind/side/cell。方向一律由 _port_specs() 按模块 id + rot 推导，
## 具体格由 _port_cell() 按该侧在部件占位里的极值格算（design §7.8）。
##
## **v3.24 弹药携带升级载荷**：一发弹药不再只是 `ammo_id` 字符串，它还可以携带一个
## `upgrades` 数组（升级 id 列表）。改进装置逐个加工流经的弹药时，把**自己槽里配置的
## 升级**追加到这笔载荷上，于是「改进器 → 炮管」这条流水线真的改变了打出去的炮弹。
## 为什么必须这么做：在此之前 `ammo_id` 进出改进器完全相同，升级信息在物理上**无处存放**，
## 只能靠「整台坦克的抽象升级列表」凑，而那与实际流水线是脱节的。
## 载荷只在弹药对象上流转，一旦装膛就随炮弹一起被 `take_loaded_upgrades()` 取走。
## 不绘制、不读输入，可由无头脚本直接驱动。
##
## 端口几何不在 data 里：data/modules/systems.json 的 ports 只有端口 id 字符串，
## 缺 kind/side/cell。方向一律由 _port_specs() 按模块 id + rot 推导，
## 具体格由 _port_cell() 按该侧在部件占位里的极值格算（design §7.8）。

const ModuleDefs := preload("res://scripts/module_defs.gd")

const ROLE_CONVEYOR := "conveyor"
const ROLE_FACTORY := "factory"
const ROLE_DEPOT := "depot"
const ROLE_MODIFIER := "modifier"
const ROLE_CANNON := "cannon"
const ROLE_OTHER := "other"

const SIDE_VECTORS := {
	"E": Vector2i(1, 0),
	"S": Vector2i(0, 1),
	"W": Vector2i(-1, 0),
	"N": Vector2i(0, -1),
}

## 管路件基准朝向（rot = 0）的端口表：[port_id, kind, side]
const CONVEYOR_PORTS := {
	"conveyor_straight": [["in0", "in", "W"], ["out0", "out", "E"]],
	"conveyor_arc_quarter": [["in0", "in", "N"], ["out0", "out", "E"]],
	"conveyor_arc_half": [["in0", "in", "W"], ["out0", "out", "E"]],
	"conveyor_tee": [["in0", "in", "W"], ["out0", "out", "E"], ["out1", "out", "N"]],
	"conveyor_merge": [["in0", "in", "W"], ["in1", "in", "S"], ["out0", "out", "E"]],
	"conveyor_cross": [["in0", "in", "W"], ["in1", "in", "S"], ["out0", "out", "E"], ["out1", "out", "N"]],
}

const MAX_EVENTS := 1024

var definitions: ModuleDefs
var net_hz := 20.0
var speed_cells_s := 4.0
var grace_s := 1.0

## 每个模块部件一条：{index, module_id, role, rot, cells, specs, node_in, node_out, level, state, ...}
var parts: Array[Dictionary] = []
## 端口节点：key "x,y:port_id" -> {part, port, kind, side, cell}
var nodes: Dictionary = {}
## 事件流水。只含 tick 序号，不含墙钟时间，因此可逐条比对确定性。
var events: Array[Dictionary] = []

var _nodes_by_cell: Dictionary = {}
var _links_out: Dictionary = {}
var _links_in: Dictionary = {}
var _levels: Dictionary = {}
var _rounds: Dictionary = {}
## part_index -> uid，一个管路段同时只能有一发
var _owner: Dictionary = {}
var _tee_counters: Dictionary = {}
## 拓扑重建后失去宿主段的弹药：原地等宽限时间后消失，无位置可画。
var _orphans: Array = []
var _accum := 0.0
var _next_uid := 1
var _tick_count := 0
var _bank = null

func setup(module_defs: ModuleDefs) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	net_hz = maxf(definitions.global_number("ammo_net_hz", 20.0), 1.0)
	speed_cells_s = maxf(definitions.global_number("conveyor_speed_cells_s", 4.0), 0.001)
	grace_s = maxf(definitions.global_number("conveyor_strand_grace_s", 1.0), 0.0)
	return true

func tick_dt() -> float:
	return 1.0 / maxf(net_hz, 1.0)

## 按建造源重建拓扑。接受 GridBuilder（部件键 "id"）或 TankBody（部件键 "module_id"）。
## 在途弹药按 (module_id, 首格) 重新挂接；宿主段消失的转为孤儿，宽限后消失（design §7.5）。
func rebuild(source: Object) -> void:
	var survivor: Array = _snapshot_rounds()
	_reset_state()
	if source == null or definitions == null:
		return
	for raw in _collect_parts(source):
		var entry: Dictionary = raw
		var module_id := String(entry["module_id"])
		if module_id.is_empty():
			continue
		var def := definitions.get_module(module_id)
		if def.is_empty():
			continue
		var cells: Array = entry["cells"]
		if cells.is_empty():
			continue
		var role := _role_of(module_id, def)
		## 把该件在建造期配置的升级带进网络（只有改进器会真的用到）。
		parts.append(_make_part(parts.size(), module_id, def, role, int(entry["rot"]), cells, entry.get("upgrades", [])))
	_build_nodes()
	_build_links()
	_compute_levels()
	_reattach_rounds(survivor)
	if _bank != null:
		bind_bank(_bank)

# ─── 对外：调度与查询 ─────────────────────────────────────────────────────────

## 按 design §7.7 独立累加器推进；余量保留，绝不缩放 dt。
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	var period := tick_dt()
	_accum += delta
	var guard := 0
	while _accum >= period and guard < 16:
		_accum -= period
		tick_once()
		guard += 1
	if guard >= 16:
		_accum = fmod(_accum, period)

## 单次 20 Hz 步进，严格四步定序（design §7.7）。
func tick_once() -> void:
	var dt := tick_dt()
	_tick_count += 1
	_advance_orphans(dt)
	var order := _ordered_rounds()

	# 步骤 1：推进所有在途物品的 progress。本步不改变段归属。
	for uid in order:
		var r: Dictionary = _rounds[uid]
		var part: Dictionary = parts[int(r["part"])]
		var rate := speed_cells_s / float(maxi((part["cells"] as Array).size(), 1))
		if bool(r["forward"]):
			r["progress"] = minf(float(r["progress"]) + rate * dt, 1.0)
		else:
			r["progress"] = maxf(float(r["progress"]) - rate * dt, 0.0)

	# 步骤 2：按拓扑序（源 → 汇）收集移动请求，统一按目标节点 id 排序后应用。
	# 排序键是目标端口 id，因此二合一的 in0 天然优先于 in1，且与部件索引无关。
	var strand_requests: Array = []
	var module_requests: Array = []
	for uid in order:
		_collect_request(uid, dt, strand_requests, module_requests)
	_apply_strand_requests(strand_requests)

	# 步骤 3：模块输出（制造装置产出、弹药库/改进装置向管路投放）。
	for index in range(parts.size()):
		_module_emit(index)

	# 步骤 4：模块输入接收与内部处理（改进器加工计时、炮管装填冷却）。
	_apply_module_requests(module_requests)
	for index in range(parts.size()):
		_module_advance(index, dt)

## 每条管路段的在途状态与拥塞标记，供 HUD 绘制管路与红色闪烁。
func strand_positions() -> Array:
	var result: Array = []
	for uid in _rounds.keys():
		var r: Dictionary = _rounds[uid]
		var part_index := int(r["part"])
		var part: Dictionary = parts[part_index]
		result.append({
			"uid": int(uid),
			"part": part_index,
			"module_id": String(part["module_id"]),
			"cells": part["cells"],
			"progress": float(r["progress"]),
			"ammo_id": String(r["ammo_id"]),
			"upgrades": (r.get("upgrades", []) as Array).duplicate(),
			"forward": bool(r["forward"]),
			"congested": float(r["progress"]) >= 1.0 and not _downstream_open(part_index, String(r["ammo_id"])),
		})
	return result

func congestion() -> Array:
	var result: Array = []
	for uid in _rounds.keys():
		var r: Dictionary = _rounds[uid]
		var part_index := int(r["part"])
		if float(r["progress"]) < 1.0:
			continue
		if _downstream_open(part_index, String(r["ammo_id"])):
			continue
		result.append({"part": part_index, "module_id": String(parts[part_index]["module_id"])})
	return result

## 每个源（制造装置 / 弹药库 / 改进装置）是否有可达的下游接收端；false 即 UNREACHABLE。
func route_status() -> Array:
	var result: Array = []
	for part in parts:
		var role := String(part["role"])
		if role != ROLE_FACTORY and role != ROLE_DEPOT and role != ROLE_MODIFIER:
			continue
		var sinks := _reachable_sinks(int(part["index"]))
		result.append({
			"part": int(part["index"]),
			"module_id": String(part["module_id"]),
			"reachable": not sinks.is_empty(),
			"sinks": sinks,
		})
	return result

func cannon_states() -> Array:
	var result: Array = []
	for part in parts:
		if String(part["role"]) != ROLE_CANNON:
			continue
		var state: Dictionary = part["state"]
		result.append({
			"part": int(part["index"]),
			"caliber": String(part["caliber"]),
			"loaded": bool(state["loaded"]),
			"queued": bool(state["queued"]),
			"reload_remaining": float(state["reload_remaining"]),
			"loaded_upgrades": (state.get("loaded_upgrades", []) as Array).duplicate(),
			"delivered": int(state.get("delivered", 0)),
		})
	return result

## 逐模块的可视化状态（页面层唯一入口，**绝不导出原始 `state` 字典**）。
##
## 每项：`{part, role, module_id, cells, ratio, detail, loaded, queued}`。
## `ratio` 是**这一件模块当前进度的 0..1 比例**，语义按角色而定：
##   制造 = 1 - craft/craft_time_s（缓存满时 `craft` 不再递减，进度会诚实地停住）；
##   存量 = stored/capacity_slots；
##   加工 = 1 - work_remaining/(processing_time_s × processing_factor)；
##   装填 = 已上膛则 1.0，否则 1 - reload_remaining/reload_s。
## `-1.0` 表示该角色当前没有可画的进度（例如改进器空转）。
##
## 为什么由数据层算：`reload_s` / `craft_time_s` / `processing_time_s` 都是模块定义里的量，
## 页面层若自己拿 `reload_remaining` 去除，必须再去查一次模块表，等于把同一套算术写两遍。
## 管路件（conveyor）与其它件没有进度语义，直接跳过——传送带上的弹药由
## `strand_positions()` 提供位置。
func module_states() -> Array:
	var result: Array = []
	for part in parts:
		var role := String(part["role"])
		if role == ROLE_CONVEYOR or role == ROLE_OTHER:
			continue
		var state: Dictionary = part["state"]
		var entry := {
			"part": int(part["index"]),
			"role": role,
			"module_id": String(part["module_id"]),
			"cells": (part["cells"] as Array).duplicate(),
			"ratio": -1.0,
			"detail": "",
			"loaded": false,
			"queued": false,
			"upgrades": (part["upgrades"] as Array).duplicate(),
		}
		match role:
			ROLE_FACTORY:
				var craft_period := maxf(float(part["craft_time_s"]), 0.001)
				var buffer: Array = state["buffer"]
				entry["ratio"] = clampf(1.0 - float(state["craft"]) / craft_period, 0.0, 1.0)
				entry["detail"] = "%d/%d" % [buffer.size(), int(part["buffer_slots"])]
			ROLE_DEPOT:
				var stored: Array = state["stored"]
				var capacity := maxi(int(part["capacity_slots"]), 1)
				entry["ratio"] = clampf(float(stored.size()) / float(capacity), 0.0, 1.0)
				entry["detail"] = "%d/%d" % [stored.size(), capacity]
			ROLE_MODIFIER:
				var work: Dictionary = state["work"]
				var pending := (state["queue"] as Array).size() + (state["output"] as Array).size()
				if not work.is_empty():
					var work_total := maxf(float(part["processing_time_s"]) * _processing_factor(String(work["ammo_id"])), 0.001)
					entry["ratio"] = clampf(1.0 - float(state["work_remaining"]) / work_total, 0.0, 1.0)
					pending += 1
				entry["detail"] = "%d" % pending
			ROLE_CANNON:
				var reload := maxf(float(part["reload_s"]), 0.001)
				var loaded := bool(state["loaded"])
				entry["loaded"] = loaded
				entry["queued"] = bool(state["queued"])
				if loaded:
					entry["ratio"] = 1.0
				else:
					entry["ratio"] = clampf(1.0 - float(state["reload_remaining"]) / reload, 0.0, 1.0)
				entry["detail"] = "%.2fs" % reload
		result.append(entry)
	return result

func rounds_in_flight() -> int:
	return _rounds.size()

func orphans() -> Array:
	return _orphans.duplicate(true)

func drain_events() -> Array:
	var result: Array = events.duplicate(true)
	events.clear()
	return result

## 给某个改进装置设「槽里配了哪些升级」。校验：id 必须存在、数量不超过槽数、
## 同一 effect 的层数不超过该升级的 stack_limit（design §6.4 / §14）。
##
## 返回 false 表示参数非法（id 不存在或超出槽数），此时**不改动**原有配置。
func configure_modifier(part_index: int, upgrades: Array) -> bool:
	if part_index < 0 or part_index >= parts.size():
		return false
	var part: Dictionary = parts[part_index]
	if String(part["role"]) != ROLE_MODIFIER:
		return false
	var slots := int(part["upgrade_slots"])
	if upgrades.size() > slots:
		return false
	var accepted: Array = []
	var per_effect: Dictionary = {}
	for raw in upgrades:
		var upgrade_id := String(raw)
		## `ModuleDefs` 没有 `get_upgrade()` —— 升级表在 `registry` 上（`data_registry.gd`）。
		## 这里一度写成 `definitions.get_upgrade(...)`，运行期直接报 "Nonexistent function"。
		var def: Dictionary = definitions.registry.get_upgrade(upgrade_id) if (definitions != null and definitions.registry != null) else {}
		if def.is_empty():
			return false
		var effect := String(def.get("effect", upgrade_id))
		var limit := maxi(int(def.get("stack_limit", 1)), 1)
		var used := int(per_effect.get(effect, 0))
		if used >= limit:
			continue
		per_effect[effect] = used + 1
		accepted.append(upgrade_id)
	part["upgrades"] = accepted
	return true

## 只读：这件改进装置当前配置的升级 id 列表（UI 与测试用）。
func modifier_slots(part_index: int) -> Array:
	if part_index < 0 or part_index >= parts.size():
		return []
	var part: Dictionary = parts[part_index]
	if String(part["role"]) != ROLE_MODIFIER:
		return []
	return (part["upgrades"] as Array).duplicate()

## 只读：某门炮「已上膛那一发」携带的升级载荷。
func loaded_upgrades(part_index: int) -> Array:
	if part_index < 0 or part_index >= parts.size():
		return []
	var part: Dictionary = parts[part_index]
	if String(part["role"]) != ROLE_CANNON:
		return []
	return ((part["state"] as Dictionary).get("loaded_upgrades", []) as Array).duplicate()

# ─── 对外：与 CannonBank 的接缝 ───────────────────────────────────────────────

## 把炮管部件与 CannonBank 的条目配对（按 module_id + 首格），并同步装填状态。
func bind_bank(bank) -> void:
	_bank = bank
	for part in parts:
		part["bank_index"] = -1
		if String(part["role"]) != ROLE_CANNON or _bank == null:
			continue
		for index in range(_bank.cannons.size()):
			var cannon: Dictionary = _bank.cannons[index]
			if String(cannon["module_id"]) != String(part["module_id"]):
				continue
			if Vector2i(cannon["cell"]) == Vector2i((part["cells"] as Array)[0]):
				part["bank_index"] = index
				break

## 每帧调一次：把网络已送达（queued）的弹药真正压入 CannonBank 的膛室。
## 冷却中的炮管不抢跑，因此不会白占一段管路容量。
func fill_cannons(bank) -> int:
	if bank == null:
		return 0
	if _bank != bank:
		bind_bank(bank)
	var loaded := 0
	for part in parts:
		if String(part["role"]) != ROLE_CANNON:
			continue
		var index := int(part.get("bank_index", -1))
		if index < 0 or index >= bank.cannons.size():
			continue
		var cannon: Dictionary = bank.cannons[index]
		var state: Dictionary = part["state"]
		state["loaded"] = bool(cannon["loaded"])
		state["reload_remaining"] = float(cannon["reload_remaining"])
		if not bool(state["queued"]):
			continue
		if bool(state["loaded"]) or float(state["reload_remaining"]) > 0.0:
			continue
		var payload: Array = (state.get("queued_upgrades", []) as Array).duplicate()
		if bank.load_round(index, payload):
			state["queued"] = false
			state["queued_upgrades"] = []
			state["loaded"] = true
			state["loaded_upgrades"] = payload
			loaded += 1
	return loaded

## 无 CannonBank 的测试路径：把已装填的一发打掉，进入 reload_s 冷却。
func release_cannon(part_index: int) -> bool:
	if part_index < 0 or part_index >= parts.size():
		return false
	var part: Dictionary = parts[part_index]
	if String(part["role"]) != ROLE_CANNON:
		return false
	var state: Dictionary = part["state"]
	if not bool(state["loaded"]):
		return false
	state["loaded"] = false
	state["loaded_upgrades"] = []
	state["reload_remaining"] = float(part["reload_s"])
	state["fired"] = int(state.get("fired", 0)) + 1
	return true

# ─── 内部：拓扑 ───────────────────────────────────────────────────────────────

func _reset_state() -> void:
	parts.clear()
	nodes.clear()
	_nodes_by_cell.clear()
	_links_out.clear()
	_links_in.clear()
	_levels.clear()
	_rounds.clear()
	_owner.clear()
	_tee_counters.clear()
	_orphans.clear()
	events.clear()
	_accum = 0.0
	_next_uid = 1
	_tick_count = 0

func _collect_parts(source: Object) -> Array:
	var result: Array = []
	if source.has_method("part_cells"):
		for item in (source.module_parts as Array):
			var part: Dictionary = item
			## `upgrades` 是**这个改进器槽里配置的升级 id 列表**（v3.24）。
			## 只有改进器会带它；其它模块的 part 里根本没有这个键，所以这里用 `get` 取空数组。
			result.append({
				"module_id": String(part.get("id", "")),
				"rot": int(part.get("rot", 0)),
				"cells": source.part_cells(part),
				"upgrades": (part.get("upgrades", []) as Array).duplicate(),
			})
		return result
	for item in (source.parts as Array):
		var part: Dictionary = item
		if String(part.get("kind", "")) != "module":
			continue
		result.append({
			"module_id": String(part.get("module_id", "")),
			"rot": int(part.get("rot", 0)),
			"cells": part.get("cells", []),
			"upgrades": (part.get("upgrades", []) as Array).duplicate(),
		})
	return result

## 角色判据用各模块的专属字段，绝不用 caliber 或 ports（二者在多个角色上重叠）。
## 静态：页面层画端口箭头时要走**同一条**判据，不能自己再写一份会漂移的副本。
static func _role_of(module_id: String, def: Dictionary) -> String:
	if module_id.begins_with("conveyor_"):
		return ROLE_CONVEYOR
	if def.has("craft_time_s"):
		return ROLE_FACTORY
	if def.has("capacity_slots"):
		return ROLE_DEPOT
	if def.has("upgrade_slots"):
		return ROLE_MODIFIER
	if def.has("aim_steps"):
		return ROLE_CANNON
	return ROLE_OTHER

func _make_part(index: int, module_id: String, def: Dictionary, role: String, rot: int, cells: Array, configured_upgrades: Array = []) -> Dictionary:
	var state: Dictionary = {}
	match role:
		ROLE_FACTORY:
			state = {"craft": float(def.get("craft_time_s", 0.5)), "buffer": [], "blocked": {}}
		ROLE_DEPOT:
			state = {"stored": [], "blocked": {}}
		ROLE_MODIFIER:
			state = {"queue": [], "work": {}, "work_remaining": 0.0, "output": [], "blocked": {}}
		ROLE_CANNON:
			state = {"loaded": false, "queued": false, "reload_remaining": 0.0, "queued_upgrades": [], "loaded_upgrades": []}
	## `upgrades` 是改进装置**槽里配置的升级 id 列表**，只有 ROLE_MODIFIER 会带，其它角色恒为空。
	## 为什么挂在 part 而不在 state 里：它是**建造期配置**（改装页设的），不随模拟状态变化；
	## 而 `state` 是运行期可变状态，混在一起会让 undo/蓝图序列化多出无意义字段。
	return {
		"index": index,
		"module_id": module_id,
		"role": role,
		"rot": rot,
		"cells": cells,
		"specs": _port_specs(module_id, role, rot),
		"node_in": [],
		"node_out": [],
		"state": state,
		"caliber": String(def.get("caliber", "")),
		"craft_time_s": float(def.get("craft_time_s", 0.5)),
		"buffer_slots": maxi(int(def.get("buffer_slots", 1)), 1),
		"capacity_slots": int(def.get("capacity_slots", 0)),
		"upgrade_slots": maxi(int(def.get("upgrade_slots", 1)), 1),
		"processing_time_s": float(def.get("processing_time_s", 0.5)),
		"reload_s": float(def.get("reload_s", 0.0)),
		"bank_index": -1,
		"upgrades": (configured_upgrades as Array).duplicate(),
	}

## 端口只推导出「朝向」，具体落在哪一格由 _port_cell() 从部件占位反推。
## 这样 1/2 弧（占 2 格）和 2 格炮管的端口位置都不需要写死格序。
static func _port_specs(module_id: String, role: String, rot: int) -> Array:
	var specs: Array = []
	if role == ROLE_CONVEYOR:
		for entry in (CONVEYOR_PORTS.get(module_id, []) as Array):
			specs.append({
				"id": String(entry[0]),
				"kind": String(entry[1]),
				"side": _side_name(_rotate_vec(SIDE_VECTORS[String(entry[2])], rot)),
			})
		return specs
	if role == ROLE_FACTORY:
		specs.append({"id": "out0", "kind": "out", "side": _side_name(_rotate_vec(Vector2i(1, 0), rot))})
	elif role == ROLE_DEPOT or role == ROLE_MODIFIER:
		specs.append({"id": "in0", "kind": "in", "side": _side_name(_rotate_vec(Vector2i(-1, 0), rot))})
		specs.append({"id": "out0", "kind": "out", "side": _side_name(_rotate_vec(Vector2i(1, 0), rot))})
	elif role == ROLE_CANNON:
		specs.append({"id": "in0", "kind": "in", "side": _side_name(_rotate_vec(Vector2i(-1, 0), rot))})
	return specs

## 页面层（建造/改装 UI）画端口箭头的唯一入口。
##
## 它把 `_role_of()` + `_port_specs()` 包成一次调用，**保证 UI 与仿真看到的是同一套端口**。
## 之前 UI 里没有任何端口指示，玩家看不出弹药从哪进、往哪出；若页面层自己再判一次角色，
## 那么一旦判据变化（比如新增一种带端口的模块），箭头就会与真实连线对不上。
##
## 返回每项 `{id, kind: "in"|"out", side: "N"|"E"|"S"|"W"}`，已按 rot 旋转。
static func ui_ports(module_id: String, def: Dictionary, rot: int) -> Array:
	if def.is_empty():
		return []
	return _port_specs(module_id, _role_of(module_id, def), rot)

## 该侧最外沿的占位格：E 取 x 最大、W 取 x 最小、S 取 y 最大、N 取 y 最小；同值取小坐标保确定性。
## 静态：页面层画端口箭头时要用同一条取格规则，否则箭头会落在别的格上。
static func _port_cell(cells: Array, side: String) -> Vector2i:
	var best := Vector2i(cells[0])
	for raw in cells:
		var cell := Vector2i(raw)
		match side:
			"E":
				if cell.x > best.x or (cell.x == best.x and cell.y < best.y):
					best = cell
			"W":
				if cell.x < best.x or (cell.x == best.x and cell.y < best.y):
					best = cell
			"S":
				if cell.y > best.y or (cell.y == best.y and cell.x < best.x):
					best = cell
			_:
				if cell.y < best.y or (cell.y == best.y and cell.x < best.x):
					best = cell
	return best

func _build_nodes() -> void:
	for part in parts:
		var cells: Array = part["cells"]
		var ins: Array = []
		var outs: Array = []
		for spec in (part["specs"] as Array):
			var cell := _port_cell(cells, String(spec["side"]))
			var port_id := String(spec["id"])
			var key := "%d,%d:%s" % [cell.x, cell.y, port_id]
			nodes[key] = {
				"part": int(part["index"]),
				"port": port_id,
				"kind": String(spec["kind"]),
				"side": String(spec["side"]),
				"cell": cell,
			}
			if String(spec["kind"]) == "in":
				ins.append(key)
			else:
				outs.append(key)
			var bucket: Array = _nodes_by_cell.get(cell, [])
			bucket.append(key)
			_nodes_by_cell[cell] = bucket
		ins.sort()
		outs.sort()
		part["node_in"] = ins
		part["node_out"] = outs

## 连接规则（design §7.2）：A.out 与 B.in 所在格 4 邻接，且两侧互为反向。
## 同一目标格有多个候选时取 key 字典序第一条，保证确定性。
func _build_links() -> void:
	for part in parts:
		for key in (part["node_out"] as Array):
			var node: Dictionary = nodes[String(key)]
			var cell: Vector2i = Vector2i(node["cell"]) + SIDE_VECTORS[String(node["side"])]
			var candidates: Array = (_nodes_by_cell.get(cell, []) as Array).duplicate()
			if candidates.is_empty():
				continue
			candidates.sort()
			for other in candidates:
				var target: Dictionary = nodes[String(other)]
				if String(target["kind"]) != "in":
					continue
				if String(target["side"]) != _opposite(String(node["side"])):
					continue
				_links_out[String(key)] = String(other)
				_links_in[String(other)] = String(key)
				break

## 算路层级：源为 0，每经过一段管路 +1；用于决定推进顺序（源 → 汇）。
func _compute_levels() -> void:
	var queue: Array = []
	for part in parts:
		var role := String(part["role"])
		if role == ROLE_CONVEYOR:
			_levels[int(part["index"])] = 9999
		else:
			_levels[int(part["index"])] = 0
			queue.append(int(part["index"]))
	var head := 0
	while head < queue.size():
		var index := int(queue[head])
		head += 1
		for key in (parts[index]["node_out"] as Array):
			var link := String(_links_out.get(String(key), ""))
			if link.is_empty():
				continue
			var target := int(nodes[link]["part"])
			if int(_levels[target]) > int(_levels[index]) + 1:
				_levels[target] = int(_levels[index]) + 1
				queue.append(target)

func _reachable_sinks(part_index: int) -> Array:
	var sinks: Array = []
	var seen: Dictionary = {}
	var queue: Array = []
	for key in (parts[part_index]["node_out"] as Array):
		var link := String(_links_out.get(String(key), ""))
		if not link.is_empty():
			queue.append(int(nodes[link]["part"]))
	var head := 0
	while head < queue.size():
		var index := int(queue[head])
		head += 1
		if seen.has(index):
			continue
		seen[index] = true
		if String(parts[index]["role"]) != ROLE_CONVEYOR:
			for key in (parts[index]["node_in"] as Array):
				sinks.append(String(key))
			continue
		for key in (parts[index]["node_out"] as Array):
			var link := String(_links_out.get(String(key), ""))
			if not link.is_empty():
				queue.append(int(nodes[link]["part"]))
	sinks.sort()
	return sinks

# ─── 内部：调度 ───────────────────────────────────────────────────────────────

func _ordered_rounds() -> Array:
	var entries: Array = []
	for uid in _rounds.keys():
		var part_index := int((_rounds[uid] as Dictionary)["part"])
		entries.append({
			"uid": int(uid),
			"level": int(_levels.get(part_index, 9999)),
			"part": part_index,
		})
	entries.sort_custom(_order_before)
	var result: Array = []
	for entry in entries:
		result.append(int(entry["uid"]))
	return result

func _order_before(a: Dictionary, b: Dictionary) -> bool:
	if int(a["level"]) != int(b["level"]):
		return int(a["level"]) < int(b["level"])
	if int(a["part"]) != int(b["part"]):
		return int(a["part"]) < int(b["part"])
	return int(a["uid"]) < int(b["uid"])

func _request_before(a: Dictionary, b: Dictionary) -> bool:
	var key_a := String(a["link"])
	var key_b := String(b["link"])
	if key_a != key_b:
		return key_a < key_b
	return int(a["uid"]) < int(b["uid"])

func _collect_request(uid: int, dt: float, strand_requests: Array, module_requests: Array) -> void:
	var r: Dictionary = _rounds[uid]
	var part_index := int(r["part"])
	var part: Dictionary = parts[part_index]
	var ammo_id := String(r["ammo_id"])
	if bool(r["forward"]):
		if float(r["progress"]) < 1.0:
			return
		var viable := ""
		var reject_seen := false
		var linked := 0
		for key in _out_order(part, r):
			var link := String(_links_out.get(String(key), ""))
			if link.is_empty():
				continue
			linked += 1
			var probe := _probe(int(nodes[link]["part"]), ammo_id)
			if probe == "ok":
				viable = link
				break
			if probe == "reject":
				reject_seen = true
		if not viable.is_empty():
			r["grace"] = 0.0
			var target_part := int(nodes[viable]["part"])
			var request := {
				"uid": uid,
				"link": viable,
				"target": target_part,
				"from": part_index,
				"kind": "strand" if String(parts[target_part]["role"]) == ROLE_CONVEYOR else "module",
				"tee": part_index if String(part["module_id"]) == "conveyor_tee" else -1,
			}
			if String(request["kind"]) == "strand":
				strand_requests.append(request)
			else:
				module_requests.append(request)
			return
		if reject_seen:
			r["forward"] = false
			r["grace"] = 0.0
			_push_event("rejected", r, part_index)
			return
		if linked > 0:
			## 下游存在但当前装不下：原地等待，不丢失、不回头（design §7.4）。
			## 宽限只用于「前方根本没有路」，不能把拥塞当成路由失效。
			r["grace"] = 0.0
			return
		r["grace"] = float(r["grace"]) + dt
		if float(r["grace"]) >= grace_s:
			## 前方完全无路（含悬空出口）：宽限到期后消失并报警（design §7.5）。
			_lose_round(uid)
		return

	## 逆向退回中
	if float(r["progress"]) > 0.0:
		return
	var trail: Array = r["trail"]
	if trail.size() <= 1:
		module_requests.append({
			"uid": uid,
			"link": String(r["origin_port"]),
			"target": int(r["origin_part"]),
			"from": part_index,
			"kind": "origin",
			"tee": -1,
		})
		return
	var previous := int(trail[trail.size() - 2])
	if _owner.has(previous):
		return
	strand_requests.append({
		"uid": uid,
		"link": "%s" % _in_key_of(part_index),
		"target": previous,
		"from": part_index,
		"kind": "strand",
		"tee": -1,
		"reverse": true,
	})

func _out_order(part: Dictionary, r: Dictionary) -> Array:
	var outs: Array = part["node_out"]
	var ordered: Array = []
	if outs.size() <= 1:
		for key in outs:
			ordered.append(String(key))
		return ordered
	var module_id := String(part["module_id"])
	if module_id == "conveyor_tee":
		## 轮询交替：计数器决定本轮先试哪个出口（design §7.3）。
		var counter := int(_tee_counters.get(int(part["index"]), 0))
		var first := counter % outs.size()
		for offset in range(outs.size()):
			ordered.append(String(outs[(first + offset) % outs.size()]))
		return ordered
	if module_id == "conveyor_cross":
		## 直通优先：in0 → out0、in1 → out1；直通出口满则转另一侧。
		var preferred := 1 if String(r["entry_port"]) == "in1" else 0
		for offset in range(outs.size()):
			ordered.append(String(outs[(preferred + offset) % outs.size()]))
		return ordered
	for key in outs:
		ordered.append(String(key))
	return ordered

func _apply_strand_requests(requests: Array) -> void:
	requests.sort_custom(_request_before)
	for item in requests:
		var request: Dictionary = item
		var uid := int(request["uid"])
		if not _rounds.has(uid):
			continue
		var r: Dictionary = _rounds[uid]
		var target := int(request["target"])
		if _owner.has(target):
			continue
		var previous := int(r["part"])
		if int(_owner.get(previous, -1)) != uid:
			continue
		_owner.erase(previous)
		var trail: Array = r["trail"]
		if bool(request.get("reverse", false)) and trail.size() >= 2:
			trail.pop_back()
			r["part"] = target
			r["progress"] = 1.0
		else:
			r["part"] = target
			r["progress"] = 0.0
			trail.append(target)
		_owner[target] = uid
		var tee := int(request.get("tee", -1))
		if tee >= 0:
			_tee_counters[tee] = int(_tee_counters.get(tee, 0)) + 1

func _apply_module_requests(requests: Array) -> void:
	requests.sort_custom(_request_before)
	for item in requests:
		var request: Dictionary = item
		var uid := int(request["uid"])
		if not _rounds.has(uid):
			continue
		var r: Dictionary = _rounds[uid]
		var target := int(request["target"])
		var ammo_id := String(r["ammo_id"])
		## v3.24：弹药在途携带的升级载荷必须随它一起被接收，否则
		## 「改进器 → 炮管」这一段会把载荷丢在半路。
		var upgrades: Array = (r.get("upgrades", []) as Array).duplicate()
		if String(request["kind"]) == "origin":
			if not _accept(target, ammo_id, upgrades):
				## 源暂时装不下（例如缓存满）：本 tick 不处理，下 tick 重试，绝不丢弃。
				continue
			## 退回源头成功：记录该源不再向这条链投放同口径弹药，避免退回—重发的活锁。
			var blocked: Dictionary = parts[target]["state"]["blocked"]
			blocked[ammo_id] = true
			_owner.erase(int(r["part"]))
			_rounds.erase(uid)
			_push_event("returned", r, target)
			continue
		if not _accept(target, ammo_id, upgrades):
			continue
		var tee := int(request.get("tee", -1))
		if tee >= 0:
			_tee_counters[tee] = int(_tee_counters.get(tee, 0)) + 1
		_owner.erase(int(r["part"]))
		_rounds.erase(uid)
		var part: Dictionary = parts[target]
		_push_event(_delivery_kind(String(part["role"])), r, target)

# ─── 内部：模块行为 ───────────────────────────────────────────────────────────

func _module_emit(index: int) -> void:
	var part: Dictionary = parts[index]
	var role := String(part["role"])
	var state: Dictionary = part["state"]
	if role == ROLE_FACTORY:
		var buffer: Array = state["buffer"]
		if (buffer as Array).size() < int(part["buffer_slots"]):
			state["craft"] = float(state["craft"]) - tick_dt()
			if float(state["craft"]) <= 0.0:
				buffer.append(_make_round(String(part["caliber"])))
				state["craft"] = float(part["craft_time_s"])
		if not buffer.is_empty():
			var made: Dictionary = buffer[0]
			if _emit_from(index, String(made["ammo_id"]), made.get("upgrades", [])):
				buffer.pop_front()
		return
	if role == ROLE_DEPOT:
		var stored: Array = state["stored"]
		if not stored.is_empty():
			var held: Dictionary = stored[0]
			if _emit_from(index, String(held["ammo_id"]), held.get("upgrades", [])):
				stored.pop_front()
		return
	if role == ROLE_MODIFIER:
		var output: Array = state["output"]
		if not output.is_empty():
			## output 里存的是**弹药对象**（`{ammo_id, upgrades}`），不再是纯字符串 ——
			## 否则改进器加工后的升级载荷在投放到管路时就会丢掉。
			var head: Dictionary = output[0]
			if _emit_from(index, String(head["ammo_id"]), head.get("upgrades", [])):
				output.pop_front()

## `upgrades` 是这笔弹药已经携带的升级载荷；从工厂/仓库发起时为空数组。
func _emit_from(part_index: int, ammo_id: String, upgrades: Array = []) -> bool:
	var part: Dictionary = parts[part_index]
	var outs: Array = part["node_out"]
	if outs.is_empty():
		return false
	var blocked: Dictionary = part["state"].get("blocked", {})
	if bool(blocked.get(ammo_id, false)):
		return false
	var link := String(_links_out.get(String(outs[0]), ""))
	if link.is_empty():
		return false
	var target := int(nodes[link]["part"])
	if _probe(target, ammo_id) != "ok":
		return false
	if String(parts[target]["role"]) == ROLE_CONVEYOR:
		_spawn_round(ammo_id, part_index, target, String(outs[0]), upgrades)
		return true
	if not _accept(target, ammo_id, upgrades):
		return false
	_push_event(_delivery_kind(String(parts[target]["role"])), {"uid": 0, "ammo_id": ammo_id, "part": part_index, "upgrades": upgrades}, target)
	return true

## 投递事件的种类由目标角色决定：只有炮管是 delivered，弹药库是 stored。
func _delivery_kind(role: String) -> String:
	if role == ROLE_CANNON:
		return "delivered"
	if role == ROLE_DEPOT:
		return "stored"
	if role == ROLE_FACTORY:
		return "returned"
	return "queued"

func _module_advance(index: int, dt: float) -> void:
	var part: Dictionary = parts[index]
	var role := String(part["role"])
	var state: Dictionary = part["state"]
	if role == ROLE_MODIFIER:
		var queue: Array = state["queue"]
		var work: Dictionary = state["work"]
		if work.is_empty() and not queue.is_empty():
			var next: Dictionary = queue.pop_front()
			state["work"] = next
			state["work_remaining"] = float(part["processing_time_s"]) * _processing_factor(String(next["ammo_id"]))
			work = next
		if not work.is_empty():
			state["work_remaining"] = float(state["work_remaining"]) - dt
			if float(state["work_remaining"]) <= 0.0:
				## 加工完成：把这件改进器**槽里配置的升级**追加进这笔载荷（v3.24）。
				## 这里不去重 —— 同一升级可以占多个槽来叠层，最终由 `_upgrade_profile()` 按 stack_limit 封顶。
				var payload: Array = (work.get("upgrades", []) as Array).duplicate()
				payload.append_array((part["upgrades"] as Array).duplicate())
				(state["output"] as Array).append({"ammo_id": String(work["ammo_id"]), "upgrades": payload})
				state["work"] = {}
				state["work_remaining"] = 0.0
		return
	if role == ROLE_CANNON:
		if bool(state["loaded"]):
			return
		state["reload_remaining"] = maxf(float(state["reload_remaining"]) - dt, 0.0)
		if _bank == null and bool(state["queued"]) and float(state["reload_remaining"]) <= 0.0:
			## 无 CannonBank 的测试路径：冷却结束即自行入膛，不依赖外部装填器。
			state["queued"] = false
			state["loaded"] = true
			state["loaded_upgrades"] = (state.get("queued_upgrades", []) as Array).duplicate()
			state["queued_upgrades"] = []

# ─── 内部：接收判定 ───────────────────────────────────────────────────────────

## 返回 "ok" / "full" / "reject"。reject 专指口径不匹配，会触发原路退回。
func _probe(target: int, ammo_id: String) -> String:
	var part: Dictionary = parts[target]
	var role := String(part["role"])
	var state: Dictionary = part["state"]
	if role == ROLE_CONVEYOR:
		return "full" if _owner.has(target) else "ok"
	if role == ROLE_CANNON:
		if _caliber_of(ammo_id) != String(part["caliber"]):
			return "reject"
		if bool(state["loaded"]) or bool(state["queued"]) or float(state["reload_remaining"]) > 0.0:
			return "full"
		return "ok"
	if role == ROLE_DEPOT:
		return "ok" if _depot_has_room(part, ammo_id) else "full"
	if role == ROLE_MODIFIER:
		return "ok" if _modifier_has_room(part) else "full"
	if role == ROLE_FACTORY:
		return "ok" if _factory_has_room(part) else "full"
	return "reject"

func _accept(target: int, ammo_id: String, upgrades: Array = []) -> bool:
	var part: Dictionary = parts[target]
	var role := String(part["role"])
	var state: Dictionary = part["state"]
	if role == ROLE_CANNON:
		if _caliber_of(ammo_id) != String(part["caliber"]):
			return false
		if bool(state["loaded"]) or bool(state["queued"]) or float(state["reload_remaining"]) > 0.0:
			return false
		## 只登记「待装填」；真正入膛由 fill_cannons() 调 CannonBank.load_round() 完成。
		## 载荷随「待装填」一起暂存，装填那一刻交给炮管组（v3.24）。
		state["queued"] = true
		state["queued_upgrades"] = (upgrades as Array).duplicate()
		state["delivered"] = int(state.get("delivered", 0)) + 1
		return true
	if role == ROLE_DEPOT:
		if not _depot_has_room(part, ammo_id):
			return false
		(state["stored"] as Array).append(_make_round(ammo_id, upgrades))
		return true
	if role == ROLE_MODIFIER:
		if not _modifier_has_room(part):
			return false
		(state["queue"] as Array).append(_make_round(ammo_id, upgrades))
		return true
	if role == ROLE_FACTORY:
		if not _factory_has_room(part):
			return false
		(state["buffer"] as Array).append(_make_round(ammo_id, upgrades))
		return true
	return false

func _factory_has_room(part: Dictionary) -> bool:
	return (part["state"]["buffer"] as Array).size() < int(part["buffer_slots"])

## 弹药库按 slot 计容量：20/40 = 1、76 = 2、120 = 3、155 = 4（data/ammo/calibers.json）。
func _depot_has_room(part: Dictionary, ammo_id: String) -> bool:
	var capacity := int(part["capacity_slots"])
	if capacity <= 0:
		return false
	var used := _slot_of(ammo_id)
	for item in (part["state"]["stored"] as Array):
		used += _slot_of(_ammo_of(item))
	return used <= capacity

func _modifier_has_room(part: Dictionary) -> bool:
	var state: Dictionary = part["state"]
	var total := (state["queue"] as Array).size() + (state["output"] as Array).size()
	if not (state["work"] as Dictionary).is_empty():
		total += 1
	return total < int(part["upgrade_slots"]) + 1

func _downstream_open(part_index: int, ammo_id: String) -> bool:
	for key in (parts[part_index]["node_out"] as Array):
		var link := String(_links_out.get(String(key), ""))
		if link.is_empty():
			continue
		if _probe(int(nodes[link]["part"]), ammo_id) == "ok":
			return true
	return false

func _slot_of(ammo_id: String) -> int:
	if definitions == null:
		return 1
	return maxi(int(definitions.get_ammo(ammo_id).get("slot", 1)), 1)

func _processing_factor(ammo_id: String) -> float:
	if definitions == null:
		return 1.0
	return maxf(float(definitions.get_ammo(ammo_id).get("processing_factor", 1.0)), 0.01)

func _caliber_of(ammo_id: String) -> String:
	if definitions == null:
		return ammo_id
	var ammo := definitions.get_ammo(ammo_id)
	if ammo.is_empty():
		return ammo_id
	return String(ammo.get("caliber", ammo_id))

## 网络内部统一用 `{ammo_id, upgrades}` 表示一发弹药（v3.24）。
## 工厂新造出来的弹药没有载荷；仓库/改进器/管路里流转的都是这个形状。
static func _make_round(ammo_id: String, upgrades: Array = []) -> Dictionary:
	return {"ammo_id": ammo_id, "upgrades": (upgrades as Array).duplicate()}

## 兼容取法：条目可能是弹药对象，也可能是旧式纯字符串。
static func _ammo_of(entry: Variant) -> String:
	if entry is Dictionary:
		return String((entry as Dictionary).get("ammo_id", ""))
	return String(entry)

# ─── 内部：在途弹药 ───────────────────────────────────────────────────────────

func _spawn_round(ammo_id: String, origin_part: int, target: int, origin_port: String, upgrades: Array = []) -> int:
	if _owner.has(target):
		return 0
	var uid := _next_uid
	_next_uid += 1
	_rounds[uid] = {
		"uid": uid,
		"ammo_id": ammo_id,
		"upgrades": (upgrades as Array).duplicate(),
		"part": target,
		"progress": 0.0,
		"forward": true,
		"entry_port": _port_id_of(String(parts[target]["node_in"][0])) if not (parts[target]["node_in"] as Array).is_empty() else "",
		"trail": [target],
		"origin_part": origin_part,
		"origin_port": origin_port,
		"grace": 0.0,
	}
	_owner[target] = uid
	_push_event("emitted", _rounds[uid], origin_part)
	return uid

func _lose_round(uid: int) -> void:
	var r: Dictionary = _rounds[uid]
	_owner.erase(int(r["part"]))
	_rounds.erase(uid)
	_push_event("strand_lost", r, int(r["part"]))

func _advance_orphans(dt: float) -> void:
	var kept: Array = []
	for item in _orphans:
		var orphan: Dictionary = item
		orphan["grace"] = float(orphan["grace"]) + dt
		if float(orphan["grace"]) < grace_s:
			kept.append(orphan)
		else:
			_push_event("strand_lost", {"uid": 0, "ammo_id": String(orphan["ammo_id"]), "part": -1}, -1)
	_orphans = kept

func _snapshot_rounds() -> Array:
	var result: Array = []
	for uid in _rounds.keys():
		var r: Dictionary = _rounds[uid]
		var part_index := int(r["part"])
		result.append({
			"ammo_id": String(r["ammo_id"]),
			"upgrades": (r.get("upgrades", []) as Array).duplicate(),
			"module_id": String(parts[part_index]["module_id"]),
			"cell": Vector2i((parts[part_index]["cells"] as Array)[0]),
			"progress": float(r["progress"]),
			"forward": bool(r["forward"]),
			"entry_port": String(r["entry_port"]),
			"origin_part": int(r["origin_part"]),
			"origin_port": String(r["origin_port"]),
		})
	return result

func _reattach_rounds(survivor: Array) -> void:
	for item in survivor:
		var saved: Dictionary = item
		var part_index := _find_round_host(String(saved["module_id"]), Vector2i(saved["cell"]))
		if part_index < 0 or _owner.has(part_index):
			_orphans.append({"ammo_id": String(saved["ammo_id"]), "upgrades": (saved.get("upgrades", []) as Array).duplicate(), "grace": 0.0})
			continue
		var uid := _next_uid
		_next_uid += 1
		_rounds[uid] = {
			"uid": uid,
			"ammo_id": String(saved["ammo_id"]),
			"upgrades": (saved.get("upgrades", []) as Array).duplicate(),
			"part": part_index,
			"progress": float(saved["progress"]),
			"forward": bool(saved["forward"]),
			"entry_port": String(saved["entry_port"]),
			"trail": [part_index],
			"origin_part": int(saved["origin_part"]),
			"origin_port": String(saved["origin_port"]),
			"grace": 0.0,
		}
		_owner[part_index] = uid

func _find_round_host(module_id: String, cell: Vector2i) -> int:
	for part in parts:
		if String(part["module_id"]) != module_id:
			continue
		if String(part["role"]) != ROLE_CONVEYOR:
			continue
		if Vector2i((part["cells"] as Array)[0]) == cell:
			return int(part["index"])
	return -1

func _in_key_of(part_index: int) -> String:
	var ins: Array = parts[part_index]["node_in"]
	return String(ins[0]) if not ins.is_empty() else ""

func _push_event(kind: String, r: Dictionary, part_index: int) -> void:
	events.append({
		"tick": _tick_count,
		"kind": kind,
		"uid": int(r.get("uid", 0)),
		"ammo_id": String(r.get("ammo_id", "")),
		"part": part_index,
	})
	if events.size() > MAX_EVENTS:
		events = events.slice(events.size() - MAX_EVENTS)

# ─── 内部：几何小工具 ─────────────────────────────────────────────────────────

static func _rotate_vec(v: Vector2i, rot: int) -> Vector2i:
	match posmod(rot, 360):
		90:
			return Vector2i(-v.y, v.x)
		180:
			return Vector2i(-v.x, -v.y)
		270:
			return Vector2i(v.y, -v.x)
	return v

static func _side_name(v: Vector2i) -> String:
	if v.x > 0:
		return "E"
	if v.x < 0:
		return "W"
	if v.y > 0:
		return "S"
	return "N"

static func _opposite(side: String) -> String:
	match side:
		"E":
			return "W"
		"W":
			return "E"
		"S":
			return "N"
	return "S"

static func _port_id_of(key: String) -> String:
	var at := key.find(":")
	if at < 0:
		return ""
	return key.substr(at + 1)
