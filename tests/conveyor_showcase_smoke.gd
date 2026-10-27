extends SceneTree

## v3.35 管道展示车蓝图校验：**蓝图本身能不能被读入、有没有真的形成一条通路**。
##
## 为什么先写这个再截图：截图只能说明「画面上出现了点东西」，
## 而这个探针能回答「六种管道每种都被实际摆进去了吗」「弹药真的从工厂流到炮管了吗」。
## 蓝图是给人看的，但闭着眼睛贴一张通不了的图只是自欺。

const GridBuilder := preload("res://scripts/grid_builder.gd")
const ModuleDefs := preload("res://scripts/module_defs.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")
const PipeView := preload("res://scripts/pipe_view.gd")

const BLUEPRINT := "res://data/blueprints/conveyor_showcase.json"

var fails: Array = []


func _init() -> void:
	var definitions := ModuleDefs.new()
	definitions.load_all()

	var file := FileAccess.open(BLUEPRINT, FileAccess.READ)
	if file == null:
		fail("blueprint_missing")
		report(definitions)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		fail("blueprint_not_json")
		report(definitions)
		return
	var data: Dictionary = parsed

	var builder := GridBuilder.new()
	builder.setup(definitions)
	var error: String = builder.load_blueprint(data)
	if not error.is_empty():
		fail("load_rejected:" + error)
		report(definitions)
		return
	print("SHOWCASE_LOADED modules=%d mobility=%d platform=%d spent=%.0f mass=%.1f"
		% [builder.module_parts.size(), builder.mobility_parts.size(),
			builder.platform_cells.size(), builder.credits_spent(), builder.build_mass()])

	# ① 六种管道必须全部出现至少一次
	var present: Dictionary = {}
	for part in builder.module_parts:
		var module_id := String(part["id"])
		if PipeView.has_shape(module_id):
			present[module_id] = int(present.get(module_id, 0)) + 1
	for module_id in ["conveyor_straight", "conveyor_arc_quarter", "conveyor_arc_half",
			"conveyor_tee", "conveyor_merge", "conveyor_cross"]:
		if not present.has(module_id):
			fail("showcase_missing_shape:" + module_id)
		else:
			print("SHAPE %-22s count=%d" % [module_id, int(present[module_id])])

	# ② 每个管道模块必须有可画的中心线，且长度为正
	for part in builder.module_parts:
		var module_id := String(part["id"])
		if not PipeView.has_shape(module_id):
			continue
		var definition: Dictionary = definitions.get_module(module_id)
		var specs := AmmoNetwork.ui_ports(module_id, definition, int(part.get("rot", 0)))
		var cells := builder.part_cells(part)
		var line := PipeView.centre_line(module_id, cells, specs, 16.0)
		if line.size() < 2:
			fail("no_centre_line:%s@%s" % [module_id, str(part["start"])])
			continue
		var length := 0.0
		for index in range(line.size() - 1):
			length += line[index].distance_to(line[index + 1])
		if length <= 0.01:
			fail("zero_length:%s@%s" % [module_id, str(part["start"])])
		if specs.is_empty():
			fail("no_ports:%s@%s" % [module_id, str(part["start"])])

	# ③ 端帽判定：展示车里应当既有「接上」也有「没接上」的端口
	var entries: Array = []
	for part in builder.module_parts:
		var module_id := String(part["id"])
		if not PipeView.has_shape(module_id):
			continue
		var definition: Dictionary = definitions.get_module(module_id)
		var specs := AmmoNetwork.ui_ports(module_id, definition, int(part.get("rot", 0)))
		entries.append({"cells": builder.part_cells(part), "ports": specs})
	var occupancy := PipeView.occupancy(entries)
	var connected_count := 0
	var open_count := 0
	for entry in entries:
		var cells: Array = entry["cells"]
		var specs: Array = entry["ports"]
		var connected := PipeView.connected_sides(cells, specs, occupancy)
		for raw in specs:
			if bool(connected.get(String((raw as Dictionary)["side"]), false)):
				connected_count += 1
			else:
				open_count += 1
	print("PORTS connected=%d open=%d" % [connected_count, open_count])
	if connected_count == 0:
		fail("no_seam_ever_detected")
	if open_count == 0:
		fail("no_open_end_ever_detected")

	# ④ 真的能流：跑网络，看是否有弹药到达炮管
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	var per_part: Dictionary = {}
	for part in network.parts:
		per_part[int(part["index"])] = part
	var max_in_flight := 0
	var saw_round_in_cross := false
	var saw_round_in_tee := false
	var saw_cross_at_segment_end := false
	var saw_cross_mid_segment := false
	var saw_blocked_exit := false
	var delivered := 0
	for _tick in range(600):
		network.tick_once()
		max_in_flight = maxi(max_in_flight, network.rounds_in_flight())
		for round_state in network.strand_positions():
			var module_id := String(round_state["module_id"])
			var at_end := float(round_state["progress"]) >= 1.0
			var is_junction := module_id in ["conveyor_tee", "conveyor_merge", "conveyor_cross"]
			## 汇流类模块的弹药**始终**必须有首选出口：方向由路由决定，与瞬时容量无关。
			## 空串会让画面上的弹头失去方向（或回退到错误地画成 out0）。
			if is_junction and bool(round_state["forward"]) and String(round_state["exit_port"]).is_empty():
				fail("junction_round_without_exit_port:%s" % module_id)
			if module_id == "conveyor_cross":
				saw_round_in_cross = true
				if at_end:
					saw_cross_at_segment_end = true
				else:
					saw_cross_mid_segment = true
			if module_id == "conveyor_tee":
				saw_round_in_tee = true
			if bool(round_state["exit_blocked"]):
				saw_blocked_exit = true
		for raw_event in network.drain_events():
			if String((raw_event as Dictionary).get("kind", "")) == "delivered":
				delivered += 1
	print("FLOW delivered=%d max_in_flight=%d cross=%s tee=%s cross_end=%s cross_mid=%s blocked=%s"
		% [delivered, max_in_flight, str(saw_round_in_cross), str(saw_round_in_tee),
			str(saw_cross_at_segment_end), str(saw_cross_mid_segment), str(saw_blocked_exit)])
	if max_in_flight == 0:
		fail("nothing_ever_moved")
	## 两个状态必须**都**被观察到，否则「段内只画到中心」这条分支就是没被测过的死代码。
	if not saw_cross_at_segment_end:
		fail("cross_never_reached_segment_end")
	if not saw_cross_mid_segment:
		fail("cross_never_observed_mid_segment")
	## 首出口被堵也必须至少出现一次，否则「阻塞变红」那条分支没被验过。
	if not saw_blocked_exit:
		fail("exit_blocked_never_observed")
	if not saw_round_in_cross:
		fail("cross_never_had_a_round")
	if not saw_round_in_tee:
		fail("tee_never_had_a_round")
	if delivered == 0:
		fail("nothing_ever_delivered_to_a_cannon")

	report(definitions)


func report(_definitions) -> void:
	print("SHOWCASE checks done failures=%d" % fails.size())
	for message in fails:
		printerr("SHOWCASE_FAIL " + String(message))
	if fails.is_empty():
		print("SHOWCASE_OK")
	quit(0 if fails.is_empty() else 1)


func fail(message: String) -> void:
	fails.append(message)
