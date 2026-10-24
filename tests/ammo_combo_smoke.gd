extends SceneTree

## M4.1 弹药「模块组合」矩阵测试（v3.27 新增，永久回归）。
##
## ## 为什么需要这个文件
##
## `tests/ammo_net_smoke.gd` 的 9 个阶段全部只覆盖 **rot = 0 水平一排**。用户报「改进模块和
## 管道模块不会继续传递弹药，导致阻塞通路」，而真实的坦克上管道几乎都是**拐弯**的：四分之一弧、
## 竖直链、二分一弧、一分二 / 二合一 / 四通。本文件把这些**组合**逐条搭出来跑，断言三件事：
##
##   1. **连通性**：凡是「有下游」的 out 端口，`_links_out` 里必须有条目。
##      这比看炮弹到没到更早暴露断点 —— 玩家说「管道不传」时，先要知道是「连错了」还是「卡住了」。
##   2. **流量**：N tick 内炮管 `delivered >= k`，且 `strand_lost == 0`。
##   3. **契约**：拒收必须上报、退弹必须回收到源头、坏支路不得饿死好支路。
##   4. **逐车道**（v3.28 新增）：多汇结构不能只断言「合计有弹」——
##      一条车道吞掉全部流量照样能过合计断言。必须逐炮管 / 逐源分开数。
##
## ## 覆盖边界（必须如实）
##
## - 这是**纯领域层**测试：`AmmoNetwork` 直接由 `GridBuilder` 搭建，**不经过主场景**、不经过
##   `Duel`、不经过 `CannonBank`。它证明的是「网络调度正确」，不是「游戏里真的能打出去」。
## - 开火用 `release_cannon()`（无 `CannonBank` 的测试路径），不是真实的 `CannonBank.fire()`。
## - 没有任何人工操作；所有布局都是脚本摆的。
## - **源模块只有一个出口**（factory / depot / modifier 在 `_port_specs()` 里只生成 `out0`），
##   所以 `_emit_from()` 取 `node_out[0]` 是取唯一出口，不是「多出口不选路」的缺陷。
##   真正的分叉只发生在管件（`conveyor_tee` / `conveyor_cross`）上。
##
## 输出 `AMMO_COMBO_OK` / `AMMO_COMBO_FAIL <tag>`。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("AMMO_COMBO_FAIL data_load")
		quit(1)
		return
	## ── A. 直管与长链 ────────────────────────────────────────────────────────
	_flow("straight_rot0", [
		{"id": "ammo_factory_20", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	], 8)
	_flow("straight_rot90", [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 3), "rot": 90},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4), "rot": 90},
		{"id": "cannon_20", "cell": Vector2i(4, 5), "rot": 90},
	], 8)
	_flow("straight_rot180", [
		{"id": "ammo_factory_20", "cell": Vector2i(6, 4), "rot": 180},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4), "rot": 180},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4), "rot": 180},
		{"id": "cannon_20", "cell": Vector2i(3, 4), "rot": 180},
	], 8)
	_flow("six_segment_chain", [
		{"id": "ammo_factory_20", "cell": Vector2i(0, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	], 8)
	## ── B. 弧管：四分之一弧四个朝向 + 二分之一弧两个朝向 ──────────────────────
	_flow("arc_quarter_rot0_N_to_E", [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 3), "rot": 90},
		{"id": "conveyor_arc_quarter", "cell": Vector2i(4, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	], 8)
	_flow("arc_quarter_rot90_E_to_S", [
		{"id": "ammo_factory_20", "cell": Vector2i(5, 4), "rot": 180},
		{"id": "conveyor_arc_quarter", "cell": Vector2i(4, 4), "rot": 90},
		{"id": "cannon_20", "cell": Vector2i(4, 5), "rot": 90},
	], 8)
	_flow("arc_quarter_rot180_S_to_W", [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 5), "rot": 270},
		{"id": "conveyor_arc_quarter", "cell": Vector2i(4, 4), "rot": 180},
		{"id": "cannon_20", "cell": Vector2i(3, 4), "rot": 180},
	], 8)
	_flow("arc_quarter_rot270_W_to_N", [
		{"id": "ammo_factory_20", "cell": Vector2i(3, 4)},
		{"id": "conveyor_arc_quarter", "cell": Vector2i(4, 4), "rot": 270},
		{"id": "cannon_20", "cell": Vector2i(4, 3), "rot": 270},
	], 8)
	_flow("arc_half_rot0_horizontal", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_arc_half", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	], 8)
	_flow("arc_half_rot90_vertical", [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 3), "rot": 90},
		{"id": "conveyor_arc_half", "cell": Vector2i(4, 4), "rot": 90},
		{"id": "cannon_20", "cell": Vector2i(4, 6), "rot": 90},
	], 8)
	## ── C. 分叉 / 合并 / 四通 ────────────────────────────────────────────────
	_flow("tee_rot0_feeds_both", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(3, 4)},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 8)
	_flow("tee_rot90_feeds_both", [
		{"id": "ammo_factory_20", "cell": Vector2i(4, 3), "rot": 90},
		{"id": "conveyor_tee", "cell": Vector2i(4, 4), "rot": 90},
		{"id": "cannon_20", "cell": Vector2i(4, 5), "rot": 90},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	], 8)
	_flow("merge_rot0_two_sources", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "ammo_factory_20", "cell": Vector2i(3, 5), "rot": 270},
		{"id": "conveyor_merge", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
	], 8)
	_flow("cross_rot0_two_sources_two_sinks", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "ammo_factory_20", "cell": Vector2i(3, 5), "rot": 270},
		{"id": "conveyor_cross", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 8)
	_flow("cross_rot180_two_sources_two_sinks", [
		{"id": "ammo_factory_20", "cell": Vector2i(5, 4), "rot": 180},
		{"id": "ammo_factory_20", "cell": Vector2i(4, 3), "rot": 90},
		{"id": "conveyor_cross", "cell": Vector2i(4, 4), "rot": 180},
		{"id": "cannon_20", "cell": Vector2i(3, 4), "rot": 180},
		{"id": "cannon_20", "cell": Vector2i(4, 5), "rot": 90},
	], 8)
	## ── D. 改进器与仓库的各种串联 ────────────────────────────────────────────
	_flow("modifier_between_straights", [
		{"id": "ammo_factory_20", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	], 8)
	_flow("modifier_after_arc_quarter", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_arc_quarter", "cell": Vector2i(3, 4), "rot": 270},
		{"id": "modifier_mk1", "cell": Vector2i(3, 3), "rot": 270},
		{"id": "cannon_20", "cell": Vector2i(3, 2), "rot": 270},
	], 8)
	_flow("modifier_directly_on_cannon", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	], 8)
	_flow("two_modifiers_in_series", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	], 6)
	_flow("modifier_to_depot_to_cannon", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "ammo_depot_small", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	], 8)
	_flow("depot_to_modifier_to_cannon", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "ammo_depot_small", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(5, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		{"id": "cannon_20", "cell": Vector2i(7, 4)},
	], 8)
	## ── E. 两格模块（footprint 2）：工厂与炮管都要能接上 ────────────────────
	_flow("two_cell_factory_to_modifier", [
		{"id": "ammo_factory_76", "cell": Vector2i(2, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(4, 4)},
		{"id": "cannon_76", "cell": Vector2i(5, 4)},
	], 4)
	_flow("two_cell_factory_vertical", [
		{"id": "ammo_factory_76", "cell": Vector2i(4, 4), "rot": 90},
		{"id": "conveyor_straight", "cell": Vector2i(4, 6), "rot": 90},
		{"id": "cannon_76", "cell": Vector2i(4, 7), "rot": 90},
	], 4)
	## ── F. 契约：拒收上报 / 退避到期 / 坏支路不饿死好支路 ────────────────────
	_check_reject_reports("reject_reports_event", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(4, 4)},
		{"id": "cannon_76", "cell": Vector2i(5, 4)},
	], 20 * 12)
	_check_source_recovers("reject_source_recovers", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		{"id": "cannon_76", "cell": Vector2i(4, 4)},
	], 20 * 12)
	_check_good_branch_alive("return_does_not_starve", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(3, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
		{"id": "cannon_76", "cell": Vector2i(5, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 20 * 18)
	## ── H. 逐车道（v3.28 新增）：合计断言看不见「一条车道吞掉全部流量」 ─────────
	## 四通：从 in1（南侧）进来的线，必须优先走 out1（北侧）—— design §7.3 直通优先。
	## 旧实现把 `entry_port` 硬写成 `node_in[0]`（永远是 in0），所以这条规则从未生效；
	## 修前实测两条用例结果完全相同：`cross_in1=23/0` 与 `cross_in0=23/0`。
	_check_lane("cross_in1_goes_out1", [
		{"id": "ammo_factory_20", "cell": Vector2i(3, 5), "rot": 270},
		{"id": "conveyor_cross", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 20 * 20, 3, 2)
	## 对称对照：从 in0（西侧）进来的线，必须优先走 out0（东侧）。
	## 两条必须同时存在 —— 只留一条的话，把 `_out_order()` 写成「恒返回 out1」也能过。
	_check_lane("cross_in0_goes_out0", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_cross", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 20 * 20, 2, 3)
	## 一分二：两侧都必须拿到弹（轮询交替）。若写成「永远先走 out0」，
	## out0 下游一直通气就永远不会轮到 out1，out1 侧炮管会 0 发。
	_check_two_lanes_alive("tee_feeds_both_lanes", [
		{"id": "ammo_factory_20", "cell": Vector2i(1, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(2, 4)},
		{"id": "conveyor_tee", "cell": Vector2i(3, 4)},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(3, 3), "rot": 270},
	], 20 * 20, 3, 4)
	## 二合一：in0 一直有货时，in1 的源不能被永久饿死。
	## 既有 `ammo_net_smoke._check_merge_priority()` 只验证「in0 优先」，
	## 没有验证「in1 还能不能出弹」—— 两者是不同命题。
	_check_both_sources_emit("merge_in1_not_starved", [
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "ammo_factory_20", "cell": Vector2i(3, 5), "rot": 270},
		{"id": "conveyor_merge", "cell": Vector2i(3, 4), "rot": 0},
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
	], 20 * 24)
	## ── G. 结构：断链必须被 route_status 报出来 ──────────────────────────────
	_check_unreachable_reported("modifier_orphan_out")
	if failures > 0:
		printerr("AMMO_COMBO_FAIL count=%d" % failures)
		quit(1)
		return
	print("AMMO_COMBO_OK")
	quit(0)

# ─── 装置构造 ────────────────────────────────────────────────────────────────

## 只为器械占位铺平台，再放置器械。
## 两条硬约束（与 ammo_net_smoke 一致）：
## 1. `place_platform_cell()` 要求新增平台与现有平台 4-连通，所以不能按部件零散铺，
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
			builder.place_platform_cell(Vector2i(x, y))
	for entry in entries:
		var reason := builder.place_module(
			String(entry["id"]), Vector2i(entry["cell"]),
			int(entry.get("rot", 0)), int(entry.get("aim", 0))
		)
		if not reason.is_empty():
			## 摆位失败说明是**测试装置**写错了（重叠 / 不在平台上），不是产品缺陷。
			## 直接让整个用例失败，绝不静默跳过 —— 否则会得到「假装通过的矩阵」。
			printerr("AMMO_COMBO_FAIL place_%s_%s" % [String(entry["id"]), reason])
			failures += 1
	return builder

func _network_for(builder: GridBuilder) -> AmmoNetwork:
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	return network

func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("AMMO_COMBO_FAIL %s" % tag)

## 每个 out 端口都必须真的连上。
## 本文件的每条用车布局都是**完整链路**，所以悬空出口就是测试装置写错了。
## （产品里悬空出口是合法结构，由 §7.5 报 UNREACHABLE，不在本断言的范围。）
func _missing_links(network: AmmoNetwork) -> Array:
	var missing: Array = []
	for part in network.parts:
		for key in (part["node_out"] as Array):
			if String(network._links_out.get(String(key), "")).is_empty():
				missing.append(String(key))
	return missing

## 一条正向组合：连通性 + 流量 + 无丢弹。
func _flow(label: String, entries: Array, expect_delivered: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var lost := 0
	for step in range(20 * 20):
		network.tick_once()
		for event in network.drain_events():
			if String(event["kind"]) == "strand_lost":
				lost += 1
		## 每 tick 都试着开火：膛空出来下一发才装得进去，否则会被 reload 挡住看不到吞吐。
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	var delivered := 0
	for state in network.cannon_states():
		delivered += int(state["delivered"])
	_expect(_missing_links(network).is_empty(), "%s_links" % label)
	_expect(delivered >= expect_delivered, "%s_delivered_%d" % [label, delivered])
	_expect(lost == 0, "%s_lost_%d" % [label, lost])
	if failures == 0:
		print("  flow %-32s delivered=%d" % [label, delivered])

## 模块出口直连一个**明确拒收**的模块：必须推 `rejected` 事件。
## 旧实现把 reject 与 full 一起 `return false`，事件流水里一条都没有 —— 玩家只看到「堵了」。
func _check_reject_reports(label: String, entries: Array, ticks: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var rejected := 0
	for step in range(ticks):
		network.tick_once()
		for event in network.drain_events():
			if String(event["kind"]) == "rejected":
				rejected += 1
	_expect(rejected > 0, "%s_no_rejected_event" % label)
	_expect(network.rejected_count() == rejected, "%s_counter_%d" % [label, network.rejected_count()])
	print("  reject %-31s rejected=%d" % [label, rejected])

## 退避必须**到期**：旧实现 `blocked[ammo_id] = true` 永不清除，
## 一件口径不符的支路会让那个源永久停发该口径（240 tick 内只 emit 过 1 发）。
func _check_source_recovers(label: String, entries: Array, ticks: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var emitted := 0
	for step in range(ticks):
		network.tick_once()
		for event in network.drain_events():
			if String(event["kind"]) == "emitted":
				emitted += 1
	## 20 Hz × 12 s = 240 tick，退避 20 tick：至少要重试 8 次才算「真的在重试」。
	_expect(emitted >= 5, "%s_emitted_%d" % [label, emitted])
	print("  retry  %-31s emitted=%d" % [label, emitted])

## 一分二：一支接 20mm 炮管（好），另一支接 76mm（必被拒收并退弹）。
## 退弹可能把源头缓存撑满 —— 这是 v3.27 修掉的**双向死锁**：
## 退弹等缓存腾位、缓存等退弹腾出第一段管路。好的一支炮管必须始终有弹。
func _check_good_branch_alive(label: String, entries: Array, ticks: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var good_delivered := 0
	for step in range(ticks):
		network.tick_once()
		for event in network.drain_events():
			pass
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	for state in network.cannon_states():
		if String(state["caliber"]) == "cal_20":
			good_delivered += int(state["delivered"])
	_expect(good_delivered >= 6, "%s_good_starved_%d" % [label, good_delivered])
	print("  branch %-31s good_delivered=%d" % [label, good_delivered])

## 改进器出口悬空：`route_status()` 必须把这个源标成不可达（HUD 的「断链」就靠它）。
func _check_unreachable_reported(label: String) -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(2, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var modifier_unreachable := false
	for entry in network.route_status():
		if String(entry["module_id"]) == "modifier_mk1" and not bool(entry["reachable"]):
			modifier_unreachable = true
	_expect(modifier_unreachable, "%s_not_reported" % label)
	print("  route  %-31s modifier_unreachable=%s" % [label, str(modifier_unreachable)])

## 逐车道断言：`primary` 号炮管必须显著多于 `secondary` 号炮管。
##
## 为什么不能只断言合计：一条车道吞掉全部流量时合计依然很高。
## 修前 `cross_in1` 与 `cross_in0` 两条用例合计都是 23、结果却完全一样，
## 正是因为旧实现根本没在区分入口方向。
func _check_lane(label: String, entries: Array, ticks: int, primary: int, secondary: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	for step in range(ticks):
		network.tick_once()
		network.drain_events()
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	var counts: Dictionary = {}
	for state in network.cannon_states():
		counts[int(state["part"])] = int(state["delivered"])
	var p := int(counts.get(primary, 0))
	var s := int(counts.get(secondary, 0))
	## 直通优先不是「严格独占」：`out0` 撑满时允许转 `out1`，所以只要主道明显多于副道。
	_expect(p >= 6, "%s_primary_%d" % [label, p])
	_expect(p >= s * 2, "%s_leak_%d_%d" % [label, p, s])
	print("  lane   %-31s primary=%d secondary=%d" % [label, p, s])

## 两源汇入同一汇：**两个源都必须真的 emit 过**。
##
## 既有 `ammo_net_smoke._check_merge_priority()` 只验证「in0 优先」，
## 那是「先走哪个」；这里是「另一个到底还会不会动」——不同命题。
func _check_both_sources_emit(label: String, entries: Array, ticks: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	var emitted: Dictionary = {}
	for step in range(ticks):
		network.tick_once()
		for event in network.drain_events():
			if String(event["kind"]) == "emitted":
				var key := int(event["part"])
				emitted[key] = int(emitted.get(key, 0)) + 1
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	## 两个工厂的 part 编号是 0 与 1（按 entries 顺序）。
	var a := int(emitted.get(0, 0))
	var b := int(emitted.get(1, 0))
	_expect(a >= 5, "%s_src0_%d" % [label, a])
	_expect(b >= 5, "%s_src1_%d" % [label, b])
	print("  both   %-31s src0=%d src1=%d" % [label, a, b])

## 两条车道都必须活：**各自都要拿到弹**，且不能一边倒。
##
## 用于 `conveyor_tee` / `conveyor_cross` 这类对称分叉。
## 直通优先的「主/副」关系不适用于 tee（它是轮询），所以单独一个判据。
func _check_two_lanes_alive(label: String, entries: Array, ticks: int, lane_a: int, lane_b: int) -> void:
	var builder := _make_builder(entries)
	if builder == null:
		_expect(false, "%s_builder" % label)
		return
	var network := _network_for(builder)
	for step in range(ticks):
		network.tick_once()
		network.drain_events()
		for part in network.parts:
			if String(part["role"]) == "cannon":
				network.release_cannon(int(part["index"]))
	var counts: Dictionary = {}
	for state in network.cannon_states():
		counts[int(state["part"])] = int(state["delivered"])
	var a := int(counts.get(lane_a, 0))
	var b := int(counts.get(lane_b, 0))
	## 两侧都必须真的收到弹；其中少的一侧不得低于多的一侧的一半（轮询应当接近均匀）。
	_expect(a >= 4, "%s_lane_a_%d" % [label, a])
	_expect(b >= 4, "%s_lane_b_%d" % [label, b])
	_expect(mini(a, b) >= maxi(a, b) / 2, "%s_skew_%d_%d" % [label, a, b])
	print("  lanes  %-31s a=%d b=%d" % [label, a, b])
