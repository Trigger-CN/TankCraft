extends SceneTree

## v3.24 冒烟：升级载荷**真的随弹药流动**。
##
## 这是本轮的核心验收 —— 之前 9 种升级效果在实战里完全不可达，因为
## `ammo_id` 进出改进器是同一个字符串、升级信息在物理上无处存放。
## 本测试用一条真实流水线证明载荷确实被写进弹药、随管路搬运、并交给炮管：
##
##   ammo_factory_20 → 直管 → modifier_mk1（槽里配 up_damage）→ 直管 → cannon_20
##
## 断言全部落在**数据层可观测的输出**上（`loaded_upgrades()` / `strand_positions()` /
## `cannon_states()`），不依赖任何绘制或页面状态。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")
## v3.41：起始坦克的验收必须走真实 `SurvivalRun`，不能再自己摆一台车。
const SurvivalRun := preload("res://scripts/survival_run.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("UPGRADE_DATA_FAILED")
		quit(1)
		return
	_check_ui_ports_cover_all_roles()
	_check_configure_modifier_validation()
	_check_payload_flows_into_cannon()
	_check_function_modules_carry_intrinsic()
	_check_starter_can_install_upgrade()
	if failures > 0:
		printerr("UPGRADE_FAIL count=%d" % failures)
		quit(1)
		return
	print("UPGRADE_OK")
	quit(0)

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		failures += 1
		printerr("UPGRADE_FAIL %s" % tag)

## 与 `tests/ammo_net_smoke.gd` 的同名助手一致：按全部占位的外接矩形铺平台，再放件。
## 铺平台必须 4-连通，所以不能按件零散铺。
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
				printerr("UPGRADE_PLATFORM_FAILED %d,%d %s" % [x, y, platform_reason])
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
			printerr("UPGRADE_PLACE_FAILED %s %s" % [entry["id"], reason])
			failures += 1
	return builder

# ─── 验收 1：端口推导覆盖全部五类带端口的角色 ────────────────────────────────

## 用户要求「不只是升级效果模块，其他所有有输出或者有输入的模块都要显示箭头」。
## 绘制函数在页面层，但**方向来源**是这里的 `ui_ports()`；只要它覆盖五类角色，
## 箭头就一定会被画出来（`_draw_grid()` 对每个 module part 都调一次）。
func _check_ui_ports_cover_all_roles() -> void:
	var cases := [
		{"id": "conveyor_straight", "in": 1, "out": 1},
		{"id": "conveyor_merge", "in": 2, "out": 1},
		{"id": "ammo_factory_76", "in": 0, "out": 1},
		{"id": "ammo_depot_small", "in": 1, "out": 1},
		{"id": "modifier_mk2", "in": 1, "out": 1},
		{"id": "cannon_76", "in": 1, "out": 0},
	]
	for raw in cases:
		var entry: Dictionary = raw
		var module_id := String(entry["id"])
		var def := definitions.get_module(module_id)
		_expect(not def.is_empty(), "ui_ports_def_%s" % module_id)
		var specs: Array = AmmoNetwork.ui_ports(module_id, def, 0)
		var ins := 0
		var outs := 0
		for raw_spec in specs:
			var spec: Dictionary = raw_spec
			if String(spec["kind"]) == "in":
				ins += 1
			else:
				outs += 1
		_expect(ins == int(entry["in"]), "ui_ports_in_%s_%d" % [module_id, ins])
		_expect(outs == int(entry["out"]), "ui_ports_out_%s_%d" % [module_id, outs])
	## 旋转 90° 后，直管的 in/out 必须变成 N/S（证明 side 真的跟着 rot 走）。
	var straight := definitions.get_module("conveyor_straight")
	var rotated: Array = AmmoNetwork.ui_ports("conveyor_straight", straight, 90)
	var sides: Array = []
	for raw_spec in rotated:
		sides.append(String((raw_spec as Dictionary)["side"]))
	_expect(sides.has("N") and sides.has("S"), "ui_ports_rotated_%s" % str(sides))
	## 无端口角色的模块必须返回空数组（不能凭空画出箭头）。
	var cockpit := definitions.get_module("cockpit_light")
	_expect(AmmoNetwork.ui_ports("cockpit_light", cockpit, 0).is_empty(), "ui_ports_cockpit_empty")

# ─── 验收 2：槽配置的校验规则 ───────────────────────────────────────────────

func _check_configure_modifier_validation() -> void:
	var builder := _make_builder([
		{"id": "modifier_mk1", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	_expect(network.parts.size() == 1, "configure_parts_%d" % network.parts.size())
	if network.parts.is_empty():
		return
	## mk1 只有 1 个槽：装 1 个合法，装 2 个必须被拒。
	_expect(network.configure_modifier(0, ["up_damage"]), "configure_one_slot")
	_expect(not network.configure_modifier(0, ["up_damage", "up_burn"]), "configure_too_many_slots")
	_expect(network.modifier_slots(0) == ["up_damage"], "configure_kept_after_reject_%s" % str(network.modifier_slots(0)))
	## 未知 id 必须被拒，且不改动原配置。
	_expect(not network.configure_modifier(0, ["up_does_not_exist"]), "configure_unknown_id")
	_expect(network.modifier_slots(0) == ["up_damage"], "configure_kept_after_unknown")
	## 非改进装置必须被拒。
	var builder2 := _make_builder([{"id": "conveyor_straight", "cell": Vector2i(4, 4)}])
	var network2 := AmmoNetwork.new()
	network2.setup(definitions)
	network2.rebuild(builder2)
	_expect(not network2.configure_modifier(0, ["up_damage"]), "configure_rejects_non_modifier")

# ─── 验收 3：升级载荷真的流进炮管 ─────────────────────────────────────────────

## 这条链的每一环都必须保留载荷：
##   factory（新造，无载荷）→ 直管 → modifier（加工时追加槽配置）→ 直管 → cannon（暂存待装填）
## 之后 `loaded_upgrades()` 必须能读到 `up_damage`。
func _check_payload_flows_into_cannon() -> void:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "cannon_20", "cell": Vector2i(8, 4)},
	])
	if builder == null:
		failures += 1
		return
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	var modifier_index := -1
	var cannon_index := -1
	for part in network.parts:
		var role := String(part["role"])
		if role == AmmoNetwork.ROLE_MODIFIER:
			modifier_index = int(part["index"])
		elif role == AmmoNetwork.ROLE_CANNON:
			cannon_index = int(part["index"])
	_expect(modifier_index >= 0, "flow_modifier_found")
	_expect(cannon_index >= 0, "flow_cannon_found")
	if modifier_index < 0 or cannon_index < 0:
		return
	_expect(network.configure_modifier(modifier_index, ["up_damage"]), "flow_configure")
	_expect(network.modifier_slots(modifier_index) == ["up_damage"], "flow_slots_%s" % str(network.modifier_slots(modifier_index)))

	var saw_payload_in_transit := false
	var saw_delivered := false
	for step in range(20 * 20):
		network.tick_once()
		for raw_event in network.drain_events():
			var event: Dictionary = raw_event
			if String(event["kind"]) == "delivered" and int(event["part"]) == cannon_index:
				saw_delivered = true
		## 在途弹药也要带载荷 —— 否则「管路搬运」这一环就丢了升级。
		for raw_round in network.strand_positions():
			var rnd: Dictionary = raw_round
			var payload: Array = rnd.get("upgrades", [])
			if payload.has("up_damage"):
				saw_payload_in_transit = true
		if saw_delivered:
			break
	_expect(saw_delivered, "flow_delivered")
	_expect(saw_payload_in_transit, "flow_payload_in_transit")
	## 再跑几 tick：`_accept()` 只是把弹登记为 queued，真正入膛发生在随后的
	## `_module_advance()` 里（无 CannonBank 的测试路径）。
	## 这里是**探针缺陷修正**：第一版在 delivered 那一 tick 就 break，于是读到的是
	## `queued=true / loaded=false` 的中间态，误报 `flow_loaded_upgrades_[]`。
	for _extra in range(3):
		network.tick_once()

	## 无 CannonBank 的测试路径：queued 在冷却结束后自行入膛，载荷一起搬过去。
	_expect(network.loaded_upgrades(cannon_index) == ["up_damage"], "flow_loaded_upgrades_%s" % str(network.loaded_upgrades(cannon_index)))
	## `cannon_states()` 必须把载荷暴露给页面层（HUD 可用它显示「这发带了什么」）。
	var found_state := false
	for raw_state in network.cannon_states():
		var state: Dictionary = raw_state
		if int(state["part"]) == cannon_index:
			found_state = true
			_expect((state.get("loaded_upgrades", []) as Array) == ["up_damage"], "flow_cannon_state_payload_%s" % str(state.get("loaded_upgrades", [])))
	_expect(found_state, "flow_cannon_state_found")
	## `module_states()` 必须把改进器的槽配置暴露给页面层。
	var found_modifier := false
	for raw_state in network.module_states():
		var state: Dictionary = raw_state
		if int(state["part"]) == modifier_index:
			found_modifier = true
			_expect((state.get("upgrades", []) as Array) == ["up_damage"], "flow_module_state_slots_%s" % str(state.get("upgrades", [])))
	_expect(found_modifier, "flow_module_state_found")
	_expect(found_modifier, "flow_module_state_found")

# ─── 验收 4（v3.41）：功能分化模块携带固有升级 ──────────────────

## 用户 2026-10-24：「弹药改进模块目前似乎没有实际效果，将这些模块改为有实际功能的模块，
## 例如爆破模块、火焰模块、增伤模块等等」。
##
## 之前三档改进器（mk1/mk2/mk3）**只差槽数与加工速度**，没有任何模块级功能差异，
## 玩家看到的只是「同一个改进器，三个更贵更快的版本」。
## v3.41 新增三种功能固定的模块（定义里带 `intrinsic_upgrades`），
## 本节断言它们的固有升级真的随弹药流到炮管 —— 否则就只是数据表多了一个字段。
func _check_function_modules_carry_intrinsic() -> void:
	## (模块 id, 它携带的固有升级)。表一定要同时包含全部三种：
	## 只验一种的话，另外两种的 `intrinsic_upgrades` 写错也不会被发现。
	var cases := [
		["modifier_blast", "up_explosive"],
		["modifier_flame", "up_burn"],
		["modifier_power", "up_damage"],
	]
	for raw in cases:
		var module_id := String(raw[0])
		var expected := String(raw[1])
		## 数据层：模块定义里真的声明了这个固有升级。
		var def: Dictionary = definitions.get_module(module_id)
		_expect((def.get("intrinsic_upgrades", []) as Array) == [expected], "intrinsic_declared_%s" % module_id)
		_expect(def.has("upgrade_slots"), "intrinsic_has_slots_%s" % module_id)
		## 流程层：工厂 → 直管 → 模块 → 炮管，炮管拿到的载荷里必须有它。
		var builder := _make_builder([
			{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
			{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
			{"id": module_id, "cell": Vector2i(6, 4)},
			{"id": "cannon_20", "cell": Vector2i(7, 4)},
		])
		if builder == null:
			_expect(false, "intrinsic_builder_%s" % module_id)
			continue
		var network := AmmoNetwork.new()
		network.setup(definitions)
		network.rebuild(builder)
		var cannon_index := -1
		for part in network.parts:
			if String(part["role"]) == AmmoNetwork.ROLE_CANNON:
				cannon_index = int(part["index"])
		_expect(cannon_index >= 0, "intrinsic_cannon_found_%s" % module_id)
		if cannon_index < 0:
			continue
		var payload: Array = []
		for _step in range(20 * 20):
			network.tick_once()
			payload = network.loaded_upgrades(cannon_index)
			if not payload.is_empty():
				break
		_expect(payload.has(expected), "intrinsic_reaches_cannon_%s_%s" % [module_id, str(payload)])

# ─── 验收 5（v3.41）：起始坦克能真的装上升级 ──────────────────────

## 这是用户「没有实际效果」的直接根因：`STARTER_MODULES` 里曾经**一件带
## `upgrade_slots` 的模块都没有**，`_install_upgrade()` 永远找不到容器，
## 每张升级卡都只能进 `collected_upgrades` 暂存 —— 玩家升到满级也看不到任何变化。
##
## 本节直接走真实 `SurvivalRun.build_starter()`，断言：
##   ① 起始车至少有一件改进模块；
##   ② `_install_upgrade()` 真的把它写进 `part["upgrades"]`（而不是暂存）；
##   ③ 起始车的弹药链真的能把它带到炮管（否则装了也白装）。
func _check_starter_can_install_upgrade() -> void:
	var run_state := SurvivalRun.new()
	_expect(run_state.setup(definitions, "arena_standard", 7), "starter_setup")
	var builder := GridBuilder.new()
	_expect(builder.setup(definitions), "starter_builder_setup")
	var reason: String = SurvivalRun.build_starter(builder)
	_expect(reason.is_empty(), "starter_built_%s" % reason)
	if not reason.is_empty():
		return
	run_state.bind_player(builder)
	## ① 有容器。
	var modifier_found := false
	for part in builder.module_parts:
		if definitions.get_module(String(part.get("id", ""))).has("upgrade_slots"):
			modifier_found = true
	_expect(modifier_found, "starter_has_modifier")
	## ② 装得上，而且不靠暂存。
	var note := run_state._install_upgrade("up_damage")
	_expect(run_state.installed_upgrades().has("up_damage"), "starter_installed_%s" % note)
	_expect(run_state.collected_upgrades.is_empty(), "starter_not_pended_%s" % str(run_state.collected_upgrades))
	## ③ 装上升级后，弹药链真的把它带到炮管。
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	var cannon_index := -1
	for part in network.parts:
		if String(part["role"]) == AmmoNetwork.ROLE_CANNON:
			cannon_index = int(part["index"])
	_expect(cannon_index >= 0, "starter_cannon_found")
	if cannon_index < 0:
		return
	var payload: Array = []
	for _step in range(20 * 30):
		network.tick_once()
		payload = network.loaded_upgrades(cannon_index)
		if not payload.is_empty():
			break
	_expect(payload.has("up_damage"), "starter_payload_reaches_cannon_%s" % str(payload))
