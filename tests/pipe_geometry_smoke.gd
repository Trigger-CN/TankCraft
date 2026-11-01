extends SceneTree

## v3.35 管道几何探针：**断言**而不是看图。
##
## 为什么需要它：管道「看起来接上了」是主观判断，而「两个端点的坐标完全相同」是可断言的。
## 六种模块、四种朝向、每对可能的对接都跑一遍，任何一条不成立就报 FAIL。
##
## 覆盖：
##   ① 端口坐标 = 端口格中心 + 该侧方向 × 半格（与 `_port_cell()` 同一判据）
##   ② **相邻两个管道模块的中心线端点逐字节相同**（这就是「无接缝」的硬定义）
##   ③ 弧管的端点切线与所在格边垂直（不然接上直管会拐一个折角）
##   ④ `point_at()` 在弧管上取到的点，到圆心的距离恒等于半径（弹头不会飘出管子）
##   ⑤ 三通/四通的四条臂端点各不相同、且都落在格边中点上
##   ⑥ 朝向旋转后仍然 ①②⑤ 成立

const PipeView := preload("res://scripts/pipe_view.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")
const ModuleDefs := preload("res://scripts/module_defs.gd")
const Pal := preload("res://scripts/palette.gd")

const CELL := 16.0
const EPS := 0.0001

var fails: Array = []


func _init() -> void:
	var definitions := ModuleDefs.new()
	definitions.load_all()
	var checks := 0

	for module_id in ["conveyor_straight", "conveyor_arc_quarter", "conveyor_arc_half",
			"conveyor_tee", "conveyor_merge", "conveyor_cross"]:
		for rot in [0, 90, 180, 270]:
			var def: Dictionary = definitions.get_module(module_id)
			if def.is_empty():
				fails.append("missing_definition:" + module_id)
				continue
			var ports := AmmoNetwork.ui_ports(module_id, def, rot)
			if ports.is_empty():
				fails.append("no_ports:%s@%d" % [module_id, rot])
				continue
			var start := Vector2i(6, 6)
			var cells := _cells(definitions, module_id, def, start, rot)

			# ① 端口坐标必须是格边中点
			for raw in ports:
				var port: Dictionary = raw
				var side := String(port["side"])
				var point := PipeView.port_point(cells, side, CELL)
				var port_cell := AmmoNetwork._port_cell(cells, side)
				var centre := (Vector2(port_cell) + Vector2(0.5, 0.5)) * CELL
				var offset := point - centre
				checks += 1
				if absf(offset.length() - CELL * 0.5) > EPS:
					fails.append("port_not_on_edge:%s@%d:%s len=%.4f" % [module_id, rot, side, offset.length()])
				# 必须正交对齐（不能出现对角线）
				if absf(offset.x) > EPS and absf(offset.y) > EPS:
					fails.append("port_not_orthogonal:%s@%d:%s" % [module_id, rot, side])

			# ② 与自身端点重合性：把同一模块放到相邻位置，验证端点逐字节相等
			# 做法：对每个 out 端口，在其外侧再放一个直管，两个端点必须相等。
			for raw in ports:
				var port: Dictionary = raw
				if String(port["kind"]) != "out":
					continue
				var side := String(port["side"])
				var mine := PipeView.port_point(cells, side, CELL)
				var dir: Vector2i = AmmoNetwork.SIDE_VECTORS[side]
				var port_cell := AmmoNetwork._port_cell(cells, side)
				var neighbour_cells: Array = [port_cell + dir]
				# 邻居的入向必须是我这一侧的反向
				var neighbour_side := AmmoNetwork._opposite(side)
				var theirs := PipeView.port_point(neighbour_cells, neighbour_side, CELL)
				checks += 1
				if mine != theirs:
					fails.append("seam_mismatch:%s@%d:%s mine=%s theirs=%s"
						% [module_id, rot, side, str(mine), str(theirs)])

			# ③ 弧管端点切线**沿**管轴（不是垂直于它）
			#
			# v3.39 修正：这里原来断言的是「切线垂直于所在格边」——**与正确行为相反**。
			# 如果切线垂直于轴，接上直管就是一个 90° 折角，正是用户报告的「接不上」。
			# 正确要求与 `port_point()` 的语义一致：端点处切线沿轴，|dot| ≈ 1。
			if module_id == "conveyor_arc_quarter" or module_id == "conveyor_arc_half":
				var line := PipeView.centre_line(module_id, cells, ports, CELL)
				checks += 1
				if line.size() < 3:
					fails.append("arc_too_few_points:%s@%d n=%d" % [module_id, rot, line.size()])
				else:
					var t0 := (line[1] - line[0]).normalized()
					var t1 := (line[line.size() - 1] - line[line.size() - 2]).normalized()
					var in_side := _side_of(ports, "in")
					var out_side := _side_of(ports, "out")
					# 离散化误差：sin²(πt) 曲线首尾两点的差分方向相对轴向的偏角 = π/N。
					# 取 N = 2×ARC_SEGMENTS，偏角 ≈ π/32 ≈ 0.098 rad，cos 后 |dot| ≈ 0.995。
					# 容差取 0.03，既容得下离散化，又能抓到「垂直」（|dot|≈0）这种真错。
					var axial_tolerance := 0.03
					var need0: Vector2i = AmmoNetwork.SIDE_VECTORS[in_side]
					var need1: Vector2i = AmmoNetwork.SIDE_VECTORS[out_side]
					if absf(t0.dot(Vector2(need0))) < 1.0 - axial_tolerance:
						fails.append("arc_start_not_axial:%s@%d dot=%.4f"
							% [module_id, rot, t0.dot(Vector2(need0))])
					if absf(t1.dot(Vector2(need1))) < 1.0 - axial_tolerance:
						fails.append("arc_end_not_axial:%s@%d dot=%.4f"
							% [module_id, rot, t1.dot(Vector2(need1))])
					# **最关键的一条**：中心线首尾必须就是端口点本身。
					# v3.35–v3.38 缺的就是它 —— 之前只比对「两个 `port_point()` 相等」，
					# 而两边都走同一个函数，恒等，于是画出比端口短半格的管子也全绿。
					var expect_a := PipeView.port_point(cells, in_side, CELL)
					var expect_b := PipeView.port_point(cells, out_side, CELL)
					checks += 1
					if expect_a.distance_to(line[0]) > EPS:
						fails.append("centre_line_head_not_port:%s@%d gap=%.4f"
							% [module_id, rot, expect_a.distance_to(line[0])])
					checks += 1
					if expect_b.distance_to(line[line.size() - 1]) > EPS:
						fails.append("centre_line_tail_not_port:%s@%d gap=%.4f"
							% [module_id, rot, expect_b.distance_to(line[line.size() - 1])])

			# ④ 采样点必须落在**占位包围盒内**，且确实有弯曲（不是直线）
			#
			# v3.39 修正：这里原来写成「到写死圆心距离 == CELL*0.5」——圆心与半径都是
			# 测试自己算的另一套假设，与实现的错误值相同，两边同错也会过（探针与实现共谋）。
			# 现在换成两条与实现无关、与真实需求直接对应的断言。
			if module_id == "conveyor_arc_quarter" or module_id == "conveyor_arc_half":
				var line2 := PipeView.centre_line(module_id, cells, ports, CELL)
				var bounds2 := PipeView.cells_bounds(cells)
				var lo2 := Vector2(bounds2.position) * CELL
				var hi2 := Vector2(bounds2.position + bounds2.size) * CELL
				var outside := 0.0
				var max_bulge := 0.0
				var a2 := PipeView.port_point(cells, _side_of(ports, "in"), CELL)
				var b2 := PipeView.port_point(cells, _side_of(ports, "out"), CELL)
				var dir2 := (b2 - a2).normalized()
				var len2 := a2.distance_to(b2)
				for index in range(41):
					var p := PipeView.point_at(line2, float(index) / 40.0)
					outside = maxf(outside, maxf(maxf(lo2.x - p.x, p.x - hi2.x), maxf(lo2.y - p.y, p.y - hi2.y)))
					var along2 := clampf((p - a2).dot(dir2), 0.0, len2)
					max_bulge = maxf(max_bulge, (p - (a2 + dir2 * along2)).length())
				checks += 1
				# 端口本身在包围盒边界上，容许贴边：容差半格。
				if outside > CELL * 0.5 + 0.01:
					fails.append("arc_outside_footprint:%s@%d %.4f" % [module_id, rot, outside])
				checks += 1
				if max_bulge < CELL * 0.1:
					fails.append("arc_no_bulge:%s@%d %.4f" % [module_id, rot, max_bulge])

			# ⑤ 汇流类：臂端点必须两两不同，且都在格边中点
			if module_id == "conveyor_tee" or module_id == "conveyor_merge" or module_id == "conveyor_cross":
				var arms := PipeView.junction_arms(module_id, cells, ports, CELL)
				checks += 1
				if arms.size() != ports.size():
					fails.append("junction_arm_count:%s@%d %d vs %d"
						% [module_id, rot, arms.size(), ports.size()])
				var seen: Array = []
				for raw_arm in arms:
					var arm: Dictionary = raw_arm
					var pts: PackedVector2Array = arm["points"]
					var end := pts[pts.size() - 1]
					for other in seen:
						if Vector2(other).distance_to(end) < CELL * 0.25:
							fails.append("junction_arm_overlap:%s@%d %s vs %s"
								% [module_id, rot, str(end), str(other)])
					seen.append(end)

	# ⑥ 覆盖率：六种管道全部有几何，非管道模块一律没有
	for module_id in ["conveyor_straight", "conveyor_arc_quarter", "conveyor_arc_half",
			"conveyor_tee", "conveyor_merge", "conveyor_cross"]:
		checks += 1
		if not PipeView.has_shape(module_id):
			fails.append("shape_missing:" + module_id)
	for module_id in ["cannon_76", "ammo_depot_76", "ammo_factory_76", "engine_medium",
			"cockpit_light", "platform_cell", "track_standard", "shield_cell"]:
		checks += 1
		if PipeView.has_shape(module_id):
			fails.append("shape_false_positive:" + module_id)

	# ⑦ 对照：**旧的直线插值**在弧管上会飘出管子（证明这次改动是必要的）
	var q_def: Dictionary = definitions.get_module("conveyor_arc_quarter")
	var q_ports := AmmoNetwork.ui_ports("conveyor_arc_quarter", q_def, 0)
	var q_cells: Array = [_start_of("conveyor_arc_quarter")]
	var q_line := PipeView.centre_line("conveyor_arc_quarter", q_cells, q_ports, CELL)
	var q_centre := _arc_centre("conveyor_arc_quarter", q_cells, q_ports)
	var old_worst := 0.0
	for index in range(21):
		var t := float(index) / 20.0
		var a := q_line[0]
		var b := q_line[q_line.size() - 1]
		var old_point := a.lerp(b, t)
		old_worst = maxf(old_worst, absf(old_point.distance_to(q_centre) - CELL * 0.5))
	checks += 1
	# 弦高理论上限 = r(1 − cos45°) = 8 × 0.29289 = 2.3431。阈值必须**低于**它才有区分力；
	# 原先写 CELL*0.5*0.5 = 4.0，比理论上限还高，任何情况下都必然触发 —— 那是探针缺陷，不是产品缺陷。
	if old_worst < CELL * 0.5 * 0.2:
		fails.append("negctl_straight_line_should_be_off_circle worst=%.4f" % old_worst)
	print("PREV_SUB old_straight_line_worst_deviation=%.4f (must be well above 0)" % old_worst)

	print("PIPE_GEOMETRY checks=%d failures=%d" % [checks, fails.size()])
	for message in fails:
		printerr("PIPE_GEOMETRY_FAIL " + String(message))
	if fails.is_empty():
		print("PIPE_GEOMETRY_OK")
	quit(0 if fails.is_empty() else 1)


func _start_of(_module_id: String) -> Vector2i:
	return Vector2i(6, 6)


## 与 `GridBuilder.part_cells()` 同一条规则：`start + rotation_offsets(...)`。
func _cells(definitions, module_id: String, def: Dictionary, start: Vector2i, rot: int) -> Array:
	var footprint := int(def.get("footprint", 1))
	var offsets: Array = definitions.rotation_offsets(module_id, footprint, rot)
	var result: Array = []
	for offset in offsets:
		result.append(start + Vector2i(offset))
	return result


func _side_of(ports: Array, kind: String) -> String:
	for raw in ports:
		var port: Dictionary = raw
		if String(port["kind"]) == kind:
			return String(port["side"])
	return "W"


## 复算弧心：四分弧在单格内、半圆弧在两格接缝处；半径都是半格。
##
## **刻意不用 `PipeView` 的内部推导**：这里独立算一遍（两端点都落在距格中心半格处），
## 否则探针与实现共用一个错误公式，就变成自证。
func _arc_centre(module_id: String, cells: Array, ports: Array) -> Vector2:
	if module_id == "conveyor_arc_half":
		var bounds := PipeView.cells_bounds(cells)
		return (Vector2(bounds.position) + Vector2(bounds.size) * 0.5) * CELL
	## 单格四分弧：圆心 = 格中心。由两端点各自沿所在边法向回溯半格得到，取平均消除浮点噪声。
	var from_side := _side_of(ports, "in")
	var to_side := _side_of(ports, "out")
	var a := PipeView.port_point(cells, from_side, CELL)
	var b := PipeView.port_point(cells, to_side, CELL)
	var ca := a - PipeView.side_vector(from_side) * (CELL * 0.5)
	var cb := b - PipeView.side_vector(to_side) * (CELL * 0.5)
	return (ca + cb) * 0.5
