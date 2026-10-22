extends SceneTree

## M4 验收：弹药输送网络（roadmap M4 验收 1–7）。
## 每个阶段自建装置、重置网络，不继承上一阶段的在途炮弹或轮询计数器。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("AMMO_DATA_FAILED")
		quit(1)
		return

	_check_ports()
	_check_straight_chain()
	_check_tee_alternates()
	_check_tee_survives_blocked_side()
	_check_merge_priority()
	_check_reject_returns_to_depot()
	_check_unreachable_route()
	_check_decoupled_from_frame_rate()
	_check_determinism()

	if failures > 0:
		printerr("AMMO_FAIL count=%d" % failures)
		quit(1)
		return
	print("AMMO_OK")
	quit(0)

# ─── 装置构造 ─────────────────────────────────────────────────────────────────

## 只为器械占位铺平台，再放置器械。
## 两条硬约束：
## 1. place_platform_cell() 要求新增平台与现有平台 4-连通，所以不能按部件零散铺，
##    必须按全部部件占位的外接矩形逐行铺满。
## 2. 每个平台格 1 u 质量，而 Lv.0 质量上限只有 160 u，所以外接矩形必须细长。
func _make_builder(entries: Array) -> GridBuilder:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	var occupied: Array[Vector2i] = []
	for entry in entries:
		var shape := {
			"id": String(entry["id"]),
			"start": Vector2i(entry["cell"]),
			"rot": int(entry.get("rot", 0)),
		}
		for cell in builder.part_cells(shape):
			occupied.append(cell)
	if occupied.is_empty():
		return builder
	var min_x := occupied[0].x
	var max_x := occupied[0].x
	var min_y := occupied[0].y
	var max_y := occupied[0].y
	for cell in occupied:
		min_x = mini(min_x, cell.x)
		max_x = maxi(max_x, cell.x)
		min_y = mini(min_y, cell.y)
		max_y = maxi(max_y, cell.y)
	for y in range(min_y, max_y + 1):
		for x in range(min_x, max_x + 1):
			var platform_reason := builder.place_platform_cell(Vector2i(x, y))
			if not platform_reason.is_empty():
				printerr("AMMO_PLATFORM_FAILED %d,%d %s" % [x, y, platform_reason])
				failures += 1
				return builder
	for entry in entries:
		var reason := builder.place_module(
			String(entry["id"]),
			Vector2i(entry["cell"]),
			int(entry.get("rot", 0)),
			int(entry.get("aim", 0))
		)
		if not reason.is_empty():
			printerr("AMMO_PLACE_FAILED %s %s" % [entry["id"], reason])
			failures += 1
	return builder

func _network_for(builder: GridBuilder) -> AmmoNetwork:
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	return network

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		failures += 1
		printerr("AMMO_FAIL %s" % tag)

## 事件里的 part 是目标模块下标；取它的首格用于区分装置内的不同接收端。
func _cell_of(network: AmmoNetwork, part_index: int) -> Vector2i:
	if part_index < 0 or part_index >= network.parts.size():
		return Vector2i(-1, -1)
	return Vector2i((network.parts[part_index]["cells"] as Array)[0])

# ─── 阶段 1：端口几何推导 ─────────────────────────────────────────────────────

func _check_ports() -> void:
	var builder := _make_builder([
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(6, 4)},
	])
	if builder == null:
		failures += 1
		printerr("AMMO_FAIL builder")
		return
	var network := _network_for(builder)
	# straight 在 rot 0 时 in0@W(3,4) / out0@E(5,4)
	_expect(network.nodes.has("4,4:in0") and network.nodes.has("4,4:out0"), "ports_straight")
	_expect(String(network.nodes["4,4:in0"]["side"]) == "W", "ports_straight_in_side")
	_expect(String(network.nodes["4,4:out0"]["side"]) == "E", "ports_straight_out_side")
	# tee rot 0：in0@W / out0@E / out1@N
	_expect(network.nodes.has("6,4:out1"), "ports_tee_branch")
	_expect(String(network.nodes["6,4:out1"]["side"]) == "N", "ports_tee_branch_side")

	# 旋转 90° 后直达端口应改为 N / S
	var rotated := _make_builder([{"id": "conveyor_straight", "cell": Vector2i(4, 4), "rot": 90}])
	var rotated_net := _network_for(rotated)
	_expect(String(rotated_net.nodes["4,4:in0"]["side"]) == "N", "ports_rotate_in")
	_expect(String(rotated_net.nodes["4,4:out0"]["side"]) == "S", "ports_rotate_out")

	# 自动连接：straight(4,4).out0 与 straight(5,4).in0 互反且相邻
	var linked := _make_builder([
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
	])
	var linked_net := _network_for(linked)
	_expect(String(linked_net._links_out.get("4,4:out0", "")) == "5,4:in0", "ports_link")

# ─── 阶段 2（验收 1）：制造装置 → 直管 → 炮管，连续 10 发无丢失无重复 ──────────

func _check_straight_chain() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "cannon_20", "cell": Vector2i(6, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	var delivered := 0
	var fired := 0
	var lost := 0
	# 每 tick 前把已装填的弹打出去，模拟玩家持续开火（发射后进入 reload_s 冷却）。
	for step in range(20 * 20):
		network.tick_once()
		for event in network.drain_events():
			var kind := String(event["kind"])
			if kind == "delivered":
				delivered += 1
			elif kind == "strand_lost":
				lost += 1
		for part in network.parts:
			if String(part["role"]) != "cannon":
				continue
			if network.release_cannon(int(part["index"])):
				fired += 1
	_expect(delivered >= 10, "straight_delivered_%d" % delivered)
	_expect(fired == delivered, "straight_fired_matches_%d_%d" % [fired, delivered])
	_expect(lost == 0, "straight_no_loss_%d" % lost)
	_expect(network.rounds_in_flight() <= 1, "straight_no_burst")

# ─── 阶段 3（验收 2 上半）：一分二轮流交替，两侧都通时均衡 ─────────────────────

func _check_tee_alternates() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "cannon_20", "cell": Vector2i(8, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 3), "rot": 270},
		{"id": "cannon_20", "cell": Vector2i(6, 2), "rot": 270},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	var east := 0
	var north := 0
	var lost := 0
	for step in range(20 * 60):
		network.tick_once()
		for event in network.drain_events():
			var kind := String(event["kind"])
			if kind == "delivered":
				if _cell_of(network, int(event["part"])).y < 4:
					north += 1
				else:
					east += 1
			elif kind == "strand_lost":
				lost += 1
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	_expect(east > 3, "tee_east_flow_%d" % east)
	_expect(north > 3, "tee_north_flow_%d" % north)
	# 轮询交替：两侧数量不应严重失衡（少的一侧不少于多的一侧的一半）。
	_expect(mini(east, north) * 2 >= maxi(east, north), "tee_alternates_%d_%d" % [east, north])
	_expect(lost == 0, "tee_no_loss_%d" % lost)

# ─── 阶段 4（验收 2 下半）：一侧被堵时，另一侧连续接收而不卡死 ────────────────

func _check_tee_survives_blocked_side() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "cannon_20", "cell": Vector2i(8, 4)},
		{"id": "cannon_20", "cell": Vector2i(6, 3), "rot": 270},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	# (6,3) 的炮管永远不释放 → 装一发后长期 full，是真正的「堵住的一侧」。
	var open_hits := 0
	var blocked_hits := 0
	var lost := 0
	for step in range(20 * 60):
		network.tick_once()
		for event in network.drain_events():
			var kind := String(event["kind"])
			if kind == "delivered":
				if _cell_of(network, int(event["part"])).x >= 8:
					open_hits += 1
				else:
					blocked_hits += 1
			elif kind == "strand_lost":
				lost += 1
		for part in network.parts:
			if String(part["role"]) != "cannon":
				continue
			if _cell_of(network, int(part["index"])).x >= 8:
				network.release_cannon(int(part["index"]))
	_expect(open_hits > 5, "tee_blocked_side_still_flowed_%d" % open_hits)
	_expect(blocked_hits <= 1, "tee_blocked_side_capped_%d" % blocked_hits)
	_expect(lost == 0, "tee_blocked_side_no_loss_%d" % lost)

# ─── 阶段 5（验收 3）：二合一按 in0 优先，无对撞无丢失 ────────────────────────

func _check_merge_priority() -> void:
	# 两个源分别从 W(in0) 与 S(in1) 汇入同一个 merge，真正构造竞争。
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "ammo_factory_20", "cell": Vector2i(6, 6), "rot": 270},
		{"id": "conveyor_straight", "cell": Vector2i(6, 5), "rot": 270},
		{"id": "conveyor_merge", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "cannon_20", "cell": Vector2i(8, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	var delivered := 0
	var lost := 0
	var from_in0 := 0
	var from_in1 := 0
	var factory_a := -1
	var factory_b := -1
	for part in network.parts:
		if String(part["role"]) != "factory":
			continue
		if _cell_of(network, int(part["index"])).y >= 6:
			factory_b = int(part["index"])
		else:
			factory_a = int(part["index"])
	for step in range(20 * 60):
		network.tick_once()
		for event in network.drain_events():
			var kind := String(event["kind"])
			if kind == "delivered":
				delivered += 1
			elif kind == "strand_lost":
				lost += 1
			elif kind == "emitted":
				if int(event["part"]) == factory_a:
					from_in0 += 1
				elif int(event["part"]) == factory_b:
					from_in1 += 1
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	_expect(delivered > 5, "merge_in0_flow_%d" % delivered)
	_expect(lost == 0, "merge_no_collision_loss_%d" % lost)
	# in0 优先不等于 in1 饿死：in0 空出的时机必须让 in1 也能通过。
	_expect(from_in0 > 0 and from_in1 > 0, "merge_both_inputs_%d_%d" % [from_in0, from_in1])

# ─── 阶段 6（验收 4）：76mm 送进 155mm 炮管，被拒收并沿原路返回弹药库 ─────────

func _check_reject_returns_to_depot() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_76", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "ammo_depot_small", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_155", "cell": Vector2i(7, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	var returned := 0
	var accepted := 0
	var rejected := 0
	for step in range(20 * 60):
		network.tick_once()
		for event in network.drain_events():
			match String(event["kind"]):
				"returned":
					returned += 1
				"delivered":
					accepted += 1
				"rejected":
					rejected += 1
	_expect(rejected > 0, "reject_flagged_%d" % rejected)
	_expect(accepted == 0, "reject_nothing_accepted_%d" % accepted)
	_expect(returned > 0, "reject_returned_%d" % returned)
	# 退回后应停在弹药库里（depot 存了 cal_76），而不是凭空消失。
	var depot_stored := 0
	for part in network.parts:
		if String(part["role"]) == "depot":
			depot_stored = (part["state"]["stored"] as Array).size()
	_expect(depot_stored > 0, "reject_stored_in_depot_%d" % depot_stored)

# ─── 阶段 7（验收 5）：移除管路中段 → UNREACHABLE + 1 s 后消失 ────────────────

func _check_unreachable_route() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "cannon_20", "cell": Vector2i(6, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := _network_for(builder)
	# 先让一发炮弹进入管路
	for step in range(20 * 10):
		network.tick_once()
		if network.rounds_in_flight() > 0:
			break
	var before := network.rounds_in_flight()
	_expect(before > 0, "unreachable_setup_in_flight")

	# 拆掉中段直管
	builder.remove_at("module", Vector2i(5, 4))
	network.rebuild(builder)
	var status: Array = network.route_status()
	var unreachable := false
	for entry in status:
		if not bool(entry["reachable"]):
			unreachable = true
	_expect(unreachable, "unreachable_flagged")

	# 在途炮弹 1 s 后消失（grace_s = 1.0，20 Hz → 20 tick）
	var lost := 0
	for step in range(20 * 3):
		network.tick_once()
		for event in network.drain_events():
			if String(event["kind"]) == "strand_lost":
				lost += 1
	_expect(lost > 0, "unreachable_warning_event_%d" % lost)
	_expect(network.rounds_in_flight() == 0 and network.orphans().is_empty(), "unreachable_cleared")

# ─── 阶段 8（验收 6）：帧率降到 20 fps 时吞吐不变 ─────────────────────────────

func _check_decoupled_from_frame_rate() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "cannon_20", "cell": Vector2i(6, 4)},
	])
	if builder == null:
		failures += 1
		return
	# 60 fps 与 20 fps 各模拟 10 秒墙钟时间，产出的弹药数应一致（差 ≤ 1）。
	var fast := _network_for(builder)
	var slow := _network_for(builder)
	var fast_count := _run_for_seconds(fast, 1.0 / 60.0, 10.0)
	var slow_count := _run_for_seconds(slow, 1.0 / 20.0, 10.0)
	_expect(absi(fast_count - slow_count) <= 1, "fps_independent_%d_%d" % [fast_count, slow_count])
	_expect(fast_count > 5, "fps_throughput_nonzero_%d" % fast_count)

func _run_for_seconds(network: AmmoNetwork, frame_dt: float, seconds: float) -> int:
	var emitted := 0
	var elapsed := 0.0
	while elapsed < seconds:
		network.step(frame_dt)
		elapsed += frame_dt
		for event in network.drain_events():
			if String(event["kind"]) == "delivered" or String(event["kind"]) == "emitted":
				emitted += 1
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	return emitted

# ─── 阶段 9（验收 7）：同蓝图两次运行事件序列完全一致 ─────────────────────────

func _check_determinism() -> void:
	var entries: Array = [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "conveyor_merge", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "cannon_20", "cell": Vector2i(8, 4)},
	]
	var first := _network_for(_make_builder(entries))
	var second := _network_for(_make_builder(entries))
	var log_a := _event_log(first)
	var log_b := _event_log(second)
	_expect(not log_a.is_empty(), "determinism_has_events")
	_expect(JSON.stringify(log_a) == JSON.stringify(log_b), "determinism_identical")

func _event_log(network: AmmoNetwork) -> Array:
	var log: Array = []
	for step in range(20 * 30):
		network.tick_once()
		for event in network.drain_events():
			log.append("%d:%s:%s:%d" % [int(event["tick"]), String(event["kind"]), String(event["ammo_id"]), int(event["part"])])
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	return log
