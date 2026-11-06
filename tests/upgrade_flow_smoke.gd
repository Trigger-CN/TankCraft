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
	_check_processing_multiplier_affects_time()
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

## 浮点近似比较。容差 1e-4 而不是 1e-6：`processing_multiplier` 是 JSON 里的十进制数，
## 1.5 × 1.3 = 1.9500000000000002 这类误差必须容得下。
func _expect_near(value: float, expected: float, tag: String) -> void:
	if absf(value - expected) <= 0.0001:
		return
	failures += 1
	printerr("UPGRADE_FAIL %s %.6f != %.6f" % [tag, value, expected])

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

# ─── 验收 6（v3.48）：`processing_multiplier` 真的影响加工时间 ───────────────

## 背景（v3.47 排查轮 P1-3）：`upgrades.json` 9 条升级**每条都有** `processing_multiplier`，
## 但全仓只有 `data_validator.gd` 在**校验**它，**零运行时读取**。
## 玩家在改装页看到「加工速度 0.9」，那个数字对游戏没有任何影响。
##
## 本轮把它接进 `AmmoNetwork._processing_factor()`（加工时间的唯一乘数入口）。
## 本节验收三层：
##   ① **数据层**：9 条升级都有这个字段，且都是正数；
##   ② **纯函数层**：`_upgrade_processing_multiplier()` 对已知载荷返回可算出的值；
##   ③ **流程层**：同一发弹药带 / 不带升级，过改进器所需**真实 tick 数不同**。
##
## 第 ③ 层是关键 —— 前两层只证明「公式对了」，不证明「真的被用上了」。
## 只有测到「跑起来耗时不同」才能区分「接了」与「接了但没人在乎」。
func _check_processing_multiplier_affects_time() -> void:
	## ① 数据层：9 条升级全部有正数 `processing_multiplier`。
	var upgrade_ids: Array = definitions.registry.upgrades.keys()
	upgrade_ids.sort()
	_expect(upgrade_ids.size() >= 9, "pm_upgrade_count_%d" % upgrade_ids.size())
	for raw_id in upgrade_ids:
		var upgrade_id := String(raw_id)
		var def: Dictionary = definitions.registry.get_upgrade(upgrade_id)
		_expect(def.has("processing_multiplier"), "pm_field_present_%s" % upgrade_id)
		_expect(float(def.get("processing_multiplier", 0.0)) > 0.0, "pm_field_positive_%s" % upgrade_id)

	## ② 纯函数层：空载荷恒为 1.0（这是「白弹药时间不变」的根据）。
	var network := AmmoNetwork.new()
	network.setup(definitions)
	_expect_near(network._upgrade_processing_multiplier([]), 1.0, "pm_empty_is_one")
	## 单条 `up_delay` 的倍率是 1.5（data 里的值，不是测试自己算的）。
	var delay_mult := float(definitions.registry.get_upgrade("up_delay").get("processing_multiplier", 1.0))
	_expect_near(network._upgrade_processing_multiplier(["up_delay"]), delay_mult, "pm_single_delay_%.3f" % delay_mult)
	## 未知 id 被忽略（不能因为载荷里有垃圾就把时间乘成 0）。
	_expect_near(network._upgrade_processing_multiplier(["up_does_not_exist"]), 1.0, "pm_unknown_ignored")
	## `stack_limit` 去重：`up_delay` 上限 1，装两次只能算一次。
	_expect_near(network._upgrade_processing_multiplier(["up_delay", "up_delay"]), delay_mult, "pm_stack_limit_respected")
	## 两条不同升级相乘：1.5 × 1.3（`up_explosive`）= 1.95。
	var explosive_mult := float(definitions.registry.get_upgrade("up_explosive").get("processing_multiplier", 1.0))
	var product := delay_mult * explosive_mult
	_expect_near(network._upgrade_processing_multiplier(["up_delay", "up_explosive"]), product, "pm_product_%.3f" % product)
	## 夹取上限：把同一件升级按超过上限的次数塞进去仍然不会超过 4.0。
	var many: Array = []
	for _repeat in range(20):
		many.append("up_delay")
	_expect(network._upgrade_processing_multiplier(many) <= 4.0, "pm_clamped_high")

	## ③ 流程层：带 / 不带升级的加工 tick 数必须不同。
	## 用 `up_delay`（×1.5）与 `up_velocity`（×0.9）两个方向相反的升级，
	## 这样「变慢」与「变快」两个方向都有证据。
	## 测量对象是**第二级**改进器 —— 第一级只负责把升级染进弹药载荷，
	## 原因见 `_modifier_ticks_for()` 的注释（第一版写成单级，测错了对象）。
	var slow_ticks := _modifier_ticks_for(["up_delay"])
	var fast_ticks := _modifier_ticks_for(["up_velocity"])
	var base_ticks := _modifier_ticks_for([])
	_expect(base_ticks > 0, "pm_base_ticks_%d" % base_ticks)
	_expect(slow_ticks > base_ticks, "pm_slow_ticks_%d_gt_%d" % [slow_ticks, base_ticks])
	_expect(fast_ticks < base_ticks, "pm_fast_ticks_%d_lt_%d" % [fast_ticks, base_ticks])

## 构造「工厂 → 直管 → 改进器 A（染色）→ 直管 → 改进器 B（被测量）→ 炮管」，
## 返回**改进器 B 加工一发**所需的 tick 数。用真实 `AmmoNetwork`，不自己算时间。
##
## 为什么测 tick 数而不是测 `_processing_factor()` 的返回值：返回值只证明公式，
## tick 数证明**这条链真的走到了模拟里**。两者都要。
##
## 为什么必须两级（第一版写成单级，三种情况 tick 数全是 6 → `pm_slow_ticks_6_gt_6`）：
## 加工时间用的是「**进来那发弹药**的载荷」（`_module_advance()` 的 `next.get("upgrades", [])`），
## 而槽配置只影响**输出**载荷。工厂产出的是白弹药，所以单级布局下被测量的改进器
## 永远收到空载荷 —— 那不是实现没生效，是测错了对象。
func _modifier_ticks_for(upgrades: Array) -> int:
	var builder := _make_builder([
		{"id": "ammo_factory_20", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(5, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(6, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(7, 4)},
		{"id": "modifier_mk1", "cell": Vector2i(8, 4)},
		{"id": "cannon_20", "cell": Vector2i(9, 4)},
	])
	if builder == null:
		_expect(false, "pm_builder_null")
		return 0
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	## 按首格 x 坐标排序：左边是染色器、右边是被测量者。
	## 不依赖 `parts` 的枚举顺序 —— 那属于实现细节，不该被测试假设。
	var modifiers: Array = []
	for part in network.parts:
		if String(part["role"]) != AmmoNetwork.ROLE_MODIFIER:
			continue
		var cells: Array = part["cells"]
		var first_x := 0
		if not cells.is_empty():
			first_x = Vector2i(cells[0]).x
		modifiers.append({"index": int(part["index"]), "x": first_x})
	_expect(modifiers.size() == 2, "pm_modifier_count_%d" % modifiers.size())
	if modifiers.size() < 2:
		return 0
	modifiers.sort_custom(func(a, b): return int(a["x"]) < int(b["x"]))
	var dye_index := int(modifiers[0]["index"])
	var observer_index := int(modifiers[1]["index"])
	## 槽配置必须成功，否则观察者收到的是白弹药，测试会变成自证。
	var configured := network.configure_modifier(dye_index, upgrades)
	_expect(configured or upgrades.is_empty(), "pm_configure_%s" % str(upgrades))
	## 逐 tick 推进，数**观察者处于加工状态**的连续 tick 数。
	## 上限 2400 tick（20 Hz × 120 s）：足够走完任何合法倍率，也留足管道输送时间。
	var started := false
	var work_ticks := 0
	for _step in range(2400):
		network.tick_once()
		var working := false
		for raw_state in network.module_states():
			var state: Dictionary = raw_state
			if int(state["part"]) != observer_index:
				continue
			## `ratio >= 0` 表示这件改进器当前确实在加工（空转是 -1）。
			working = float(state["ratio"]) >= 0.0
			break
		if working:
			started = true
			work_ticks += 1
		elif started:
			break
	if not started:
		return 0
	return work_ticks
