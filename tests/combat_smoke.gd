extends SceneTree

## M5 验收：战斗结算与可拆解摧毁（roadmap M5 验收 1–8）。
## 每个阶段自建 definitions / builder / tank / damage_system，不继承上一阶段的状态。
## 断言里的基准值全部从 data/*.json 读出，测试不自带玩法数值。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const ProjectileField := preload("res://scripts/projectile_field.gd")
const DamageSystem := preload("res://scripts/damage_system.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("COMBAT_DATA_FAILED")
		quit(1)
		return
	_check_detach()
	_check_shield_absorbs_whole_shot()
	_check_shield_pierce_split()
	_check_cannon_reload_window()
	_check_depot_explosion()
	_check_burn_status()
	_check_slow_status()
	_check_projectile_load()
	_check_clip_to_tank()
	_check_no_self_hit()
	_check_damage_scale_and_upgrades()
	_check_repair()
	_check_shield_pruned_when_body_destroyed()
	_check_aoe_keeps_direct_target()
	_check_delayed_reports_post_armor()
	_check_aoe_single_destroyed_event()
	if failures > 0:
		printerr("COMBAT_FAIL count=%d" % failures)
		quit(1)
		return
	print("COMBAT_OK")
	quit(0)

# ─── 装置构造 ─────────────────────────────────────────────────────────────────

## 手工指定平台格（按 4-连通顺序传入），再放置模块。
## place_platform_cell() 要求新增格与现有平台 4-连通，且每格 1 u 会吃 Lv.0 的
## mass_cap 160 u，所以装置必须小而连通，不能"多铺一些保险"。
func _make_builder_cells(cells: Array, entries: Array) -> GridBuilder:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		failures += 1
		printerr("COMBAT_FAIL builder_setup")
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for raw in cells:
		var cell := Vector2i(raw)
		var platform_reason := builder.place_platform_cell(cell)
		if not platform_reason.is_empty():
			printerr("COMBAT_PLATFORM_FAILED %d,%d %s" % [cell.x, cell.y, platform_reason])
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
			printerr("COMBAT_PLACE_FAILED %s %s" % [entry["id"], reason])
			failures += 1
	return builder

func _tank_for(builder: GridBuilder) -> TankBody:
	var tank := TankBody.new()
	if not tank.setup(definitions, builder):
		failures += 1
		printerr("COMBAT_FAIL tank_setup")
	return tank

func _damage_for(builder: GridBuilder, tank: TankBody) -> DamageSystem:
	var damage := DamageSystem.new()
	if not damage.setup(definitions):
		failures += 1
		printerr("COMBAT_FAIL damage_setup")
	damage.rebuild(tank, builder)
	return damage

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		failures += 1
		printerr("COMBAT_FAIL %s" % tag)

func _expect_near(value: float, expected: float, tag: String) -> void:
	if absf(value - expected) > 0.001:
		failures += 1
		printerr("COMBAT_FAIL %s value=%.4f expected=%.4f" % [tag, value, expected])

func _events_of(events: Array, kind: String) -> Array:
	var result: Array = []
	for raw in events:
		if String(raw["kind"]) == kind:
			result.append(raw)
	return result

## 同格可能有平台与模块两层，kind 过滤是必需的。
func _part_index_at(tank: TankBody, cell: Vector2i, kind: String = "") -> int:
	for index in range(tank.parts.size()):
		var part: Dictionary = tank.parts[index]
		if not kind.is_empty() and String(part["kind"]) != kind:
			continue
		if cell in (part["cells"] as Array):
			return index
	return -1

## design §8.3：护甲减免 + 15% 保底，向下取整到 1 位小数。
func _expected_final(base: float, mult: float, armor: float, pierce: float) -> float:
	var raw := base * mult
	var armor_eff := armor * (1.0 - pierce)
	var floor_scale := definitions.global_number("damage_floor", 0.15)
	var value := maxf(raw * floor_scale, raw - armor_eff)
	return floorf(value * 10.0) / 10.0

func _base_damage(ammo_id: String) -> float:
	return float(definitions.get_ammo(ammo_id).get("base_damage", 0.0))

func _armor_of(module_id: String) -> float:
	return float(definitions.get_module(module_id).get("armor", 0.0))

# ─── 阶段 1（验收 1）：脖颈被打断 → 远端整块脱落并立即消失 ─────────────────────

func _check_detach() -> void:
	# 主块 2x2（驾驶舱在 (4,4)）+ 1 格宽脖颈 (6,4) + 远端 2x2（(7,4) 上有引擎）。
	var cells := [
		Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5),
		Vector2i(6, 4),
		Vector2i(7, 4), Vector2i(8, 4), Vector2i(7, 5), Vector2i(8, 5),
	]
	var builder := _make_builder_cells(cells, [
		{"id": "cockpit_light", "cell": Vector2i(4, 4)},
		{"id": "engine_small", "cell": Vector2i(7, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var parts_before := tank.parts.size()
	_expect(parts_before == 11, "detach_setup_parts_%d" % parts_before)

	var neck := _part_index_at(tank, Vector2i(6, 4), TankBody.KIND_PLATFORM_CELL)
	_expect(neck >= 0, "detach_neck_found")
	var hit := damage.apply_hit(tank, Vector2i(6, 4), neck, "cal_155", [], Vector2.RIGHT)
	_expect(not String(hit["destroyed"]).is_empty(), "detach_neck_destroyed")

	var events := damage.drain_events()
	var detach_events := _events_of(events, "detach")
	_expect(detach_events.size() == 1, "detach_event_count_%d" % detach_events.size())
	if detach_events.size() == 1:
		var record: Dictionary = detach_events[0]
		_expect_near(float((record["cells"] as Array).size()), 4.0, "detach_cells")
		_expect(int(record["parts"]) == 1, "detach_parts_%d" % int(record["parts"]))

	# 驾驶舱所在格必须保留；远端 4 格与远端模块必须从建造模型里消失。
	var occupancy: Dictionary = builder.platform_occupancy()
	_expect(occupancy.has(Vector2i(4, 4)), "detach_keeps_cockpit_cell")
	_expect(occupancy.has(Vector2i(5, 5)), "detach_keeps_main_island")
	_expect(not occupancy.has(Vector2i(7, 4)), "detach_removes_far_cell_a")
	_expect(not occupancy.has(Vector2i(8, 5)), "detach_removes_far_cell_b")
	_expect(not occupancy.has(Vector2i(6, 4)), "detach_removes_neck")
	_expect(tank.parts.size() == 5, "detach_parts_after_%d" % tank.parts.size())
	_expect(_part_index_at(tank, Vector2i(7, 4)) < 0, "detach_engine_gone")
	_expect(not damage.defeated, "detach_not_defeated")

# ─── 阶段 2（验收 2）：护盾 hp 归零吃下整发且无溢出，充能后回满 ─────────────────

func _check_shield_absorbs_whole_shot() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4)], [
		{"id": "shield_cell", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var shield_index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	_expect(shield_index >= 0, "shield_found")
	var body_hp_before := float(tank.parts[shield_index]["hp"])
	var shield_hp_max := float(definitions.get_module("shield_cell").get("shield_hp", 0.0))
	var recharge := float(definitions.get_module("shield_cell").get("recharge_s", 0.0))

	var hit := damage.apply_hit(tank, Vector2i(4, 4), shield_index, "cal_155", [], Vector2.RIGHT)
	_expect(bool(hit["applied"]), "shield_hit_applied")
	_expect_near(float(hit["damage"]), 0.0, "shield_body_untouched")
	_expect_near(float(hit["shield"]), _base_damage("cal_155"), "shield_ate_whole_round")
	_expect_near(float(tank.parts[shield_index]["hp"]), body_hp_before, "shield_body_hp_same")

	var broken := damage.shields()
	_expect(broken.size() == 1, "shield_record_count")
	if broken.size() == 1:
		var record: Dictionary = broken[0]
		_expect(String(record["state"]) == DamageSystem.SHIELD_BROKEN, "shield_state_broken")
		_expect_near(float(record["hp"]), 0.0, "shield_hp_zero_no_overflow")
		_expect_near(float(record["charge"]), recharge, "shield_charge_armed")

	var events := damage.drain_events()
	_expect(_events_of(events, "shield_broken").size() == 1, "shield_broken_event")

	# 充能期满必须恢复满盾并只推一条 shield_restored。
	damage.step(recharge)
	var restored := damage.shields()
	_expect(restored.size() == 1, "shield_record_after_charge")
	if restored.size() == 1:
		var record: Dictionary = restored[0]
		_expect(String(record["state"]) == DamageSystem.SHIELD_ACTIVE, "shield_state_restored")
		_expect_near(float(record["hp"]), shield_hp_max, "shield_hp_restored")
	var after := _events_of(damage.drain_events(), "shield_restored")
	_expect(after.size() == 1, "shield_restored_event_%d" % after.size())

# ─── 阶段 3（验收 3）：shield_pierce = 0.5 时护盾与本体各吃一半 ─────────────────

func _check_shield_pierce_split() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4)], [
		{"id": "shield_cell", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var shield_index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	var shield_hp_max := float(definitions.get_module("shield_cell").get("shield_hp", 0.0))

	# 每层 +0.25，两层即 0.5；用 76mm 让护盾存活，才能验证"各吃一半"。
	var hit := damage.apply_hit(
		tank, Vector2i(4, 4), shield_index, "cal_76",
		["up_shield_pierce", "up_shield_pierce"], Vector2.RIGHT
	)
	var base := _base_damage("cal_76")
	_expect_near(float(hit["shield"]), base * 0.5, "pierce_shield_half")
	_expect_near(
		float(hit["damage"]),
		_expected_final(base, 0.5, _armor_of("shield_cell"), 0.0),
		"pierce_body_half"
	)
	var records := damage.shields()
	if records.size() == 1:
		_expect_near(float(records[0]["hp"]), shield_hp_max - base * 0.5, "pierce_shield_hp_left")
		_expect(String(records[0]["state"]) == DamageSystem.SHIELD_ACTIVE, "pierce_shield_still_active")

# ─── 阶段 4（验收 4）：冷却中的炮管拒绝装填，冷却结束才可装填 ─────────────────

func _check_cannon_reload_window() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4)], [
		{"id": "cannon_20", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var bank := CannonBank.new()
	if not bank.setup(definitions, tank):
		failures += 1
		printerr("COMBAT_FAIL bank_setup")
		return
	_expect(bank.cannons.size() == 1, "reload_cannon_count_%d" % bank.cannons.size())
	var reload_s := float(bank.cannons[0]["reload_s"])

	_expect(bank.load_round(0), "reload_first_load")
	_expect(bool(bank.cannons[0]["loaded"]), "reload_loaded_flag")
	var before_fire := bool(bank.cannons[0]["loaded"])
	var fired := bank.fire("cal_20")
	_expect(fired.size() == 1, "reload_fire_count_%d" % fired.size())
	_expect_near(float(bank.cannons[0]["reload_remaining"]), reload_s, "reload_cooldown_armed")
	_expect(not bool(bank.cannons[0]["loaded"]), "reload_unloaded_after_fire")
	_expect(not bank.load_round(0), "reload_rejected_while_cooling")

	# 冷却未满仍拒绝，冷却结束后才允许装填 —— 即 loaded false → true 的一次边沿。
	bank.step(reload_s * 0.5)
	_expect(not bank.load_round(0), "reload_rejected_at_half")
	bank.step(reload_s * 0.5)
	var after_ready := bool(bank.cannons[0]["loaded"])
	_expect(not after_ready, "reload_edge_was_not_level")
	_expect(bank.load_round(0), "reload_allowed_after_cooldown")
	var now_loaded := bool(bank.cannons[0]["loaded"])
	_expect(before_fire and not after_ready and now_loaded, "reload_edge_false_to_true")

# ─── 阶段 5（验收 5）：弹药库殉爆按 6 × slot 结算 ─────────────────────────────

func _check_depot_explosion() -> void:
	var per_slot := definitions.global_number("depot_explosion_damage_per_slot", 6.0)
	var cases := [
		{"id": "ammo_depot_small", "slots": 8.0},
		{"id": "ammo_depot_large", "slots": 22.0},
	]
	for raw_case in cases:
		var entry: Dictionary = raw_case
		var depot_id := String(entry["id"])
		# 殉爆半径 2.5 格，把 0 护甲直管放在不与 2 格弹药库重叠的邻格，
		# 才能观察到未经护甲衰减的原始伤害。
		var builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4)], [
			{"id": depot_id, "cell": Vector2i(4, 4)},
			{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
		])
		if builder == null:
			return
		var tank := _tank_for(builder)
		var damage := _damage_for(builder, tank)
		var depot_index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
		_expect(depot_index >= 0, "depot_found_%s" % depot_id)
		var slots := float(definitions.get_module(depot_id).get("capacity_slots", 0.0))
		_expect_near(slots, float(entry["slots"]), "depot_slots_%s" % depot_id)

		damage.apply_part_damage(tank, depot_index, 1.0e9, "destroyed")
		var blasts := _events_of(damage.drain_events(), "depot_explosion")
		_expect(blasts.size() > 0, "depot_blast_events_%s_%d" % [depot_id, blasts.size()])
		var found := false
		for raw_blast in blasts:
			var blast: Dictionary = raw_blast
			if String(blast["module_id"]) != "conveyor_straight":
				continue
			found = true
			_expect_near(float(blast["damage"]), per_slot * slots, "depot_blast_damage_%s" % depot_id)
		_expect(found, "depot_blast_reached_neighbour_%s" % depot_id)

# ─── 阶段 6（验收 6 上半）：灼烧状态有剩余秒数并到期自动移除 ───────────────────

func _check_burn_status() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4)], [
		{"id": "cannon_155", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	var duration := definitions.global_number("burn_duration_s", 3.0)

	var hit := damage.apply_hit(tank, Vector2i(4, 4), index, "cal_20", ["up_burn"], Vector2.RIGHT)
	_expect(float(hit["damage"]) > 0.0, "burn_hit_dealt_damage")
	var events := damage.drain_events()
	_expect(_events_of(events, "burn_applied").size() == 1, "burn_applied_event")

	var list := damage.statuses()
	var burn_count := 0
	for raw in list:
		var entry: Dictionary = raw
		if String(entry["kind"]) != "burn":
			continue
		burn_count += 1
		_expect_near(float(entry["duration"]), duration, "burn_duration")
		_expect_near(float(entry["remaining"]), duration, "burn_remaining")
		_expect((entry["cells"] as Array).size() > 0, "burn_reports_cells")
	_expect(burn_count == 1, "burn_status_count_%d" % burn_count)

	damage.step(duration)
	var expired := _events_of(damage.drain_events(), "burn_expired")
	_expect(expired.size() == 1, "burn_expired_event_%d" % expired.size())
	var after := 0
	for raw in damage.statuses():
		if String(raw["kind"]) == "burn":
			after += 1
	_expect(after == 0, "burn_removed_%d" % after)

# ─── 阶段 6（验收 6 下半）：减速按层叠加推力惩罚并到期复位 ─────────────────────

func _check_slow_status() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4)], [
		{"id": "cannon_155", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	var factor := definitions.global_number("slow_thrust_factor", 0.7)
	var duration := definitions.global_number("slow_duration_s", 2.5)

	_expect_near(damage.thrust_scale(), 1.0, "slow_initially_clear")
	damage.apply_hit(tank, Vector2i(4, 4), index, "cal_20", ["up_slow"], Vector2.RIGHT)
	# 一层 = 推力 × 0.7（design §8.8）；value 0.3 是"每层 −30%"，不是可直接乘的系数。
	_expect_near(damage.thrust_scale(), factor, "slow_one_stack")
	damage.apply_hit(tank, Vector2i(4, 4), index, "cal_20", ["up_slow", "up_slow"], Vector2.RIGHT)
	_expect_near(damage.thrust_scale(), 1.0 - 2.0 * (1.0 - factor), "slow_two_stacks")

	var slow_count := 0
	for raw in damage.statuses():
		var entry: Dictionary = raw
		if String(entry["kind"]) != "slow":
			continue
		slow_count += 1
		_expect_near(float(entry["duration"]), duration, "slow_duration")
		_expect_near(float(entry["remaining"]), duration, "slow_remaining")
	_expect(slow_count == 1, "slow_status_count_%d" % slow_count)

	damage.step(duration)
	_expect(_events_of(damage.drain_events(), "slow_expired").size() == 1, "slow_expired_event")
	_expect_near(damage.thrust_scale(), 1.0, "slow_reset")

# ─── 阶段 7（验收 7）：200 发同屏，单步耗时必须在预算内 ───────────────────────

func _check_projectile_load() -> void:
	var field := ProjectileField.new()
	if not field.setup(definitions):
		failures += 1
		printerr("COMBAT_FAIL field_setup")
		return
	var arena := Rect2(0.0, 0.0, 2048.0, 1152.0)
	var total := 200
	for index in range(total):
		var direction := Vector2.RIGHT.rotated(TAU * float(index) / float(total))
		field.spawn(Vector2(1024.0, 576.0), direction, "cal_20", "player", [])
	_expect(field.shots.size() == total, "load_spawned_%d" % field.shots.size())

	var frames := 30
	var start_us := Time.get_ticks_usec()
	for frame in range(frames):
		field.step(1.0 / 60.0, arena, [], [])
	var elapsed_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
	var per_frame_ms := elapsed_ms / float(frames)
	# 只测逻辑步进（无渲染）；55 fps 对应 18.18 ms 的帧预算。
	_expect(per_frame_ms < 1000.0 / 55.0, "load_frame_budget_%.2fms" % per_frame_ms)
	_expect(field.shots.size() == total, "load_shots_survived_%d" % field.shots.size())
	print("COMBAT_LOAD shots=%d frames=%d per_frame_ms=%.2f" % [total, frames, per_frame_ms])

# ─── 阶段 8（额外）：线段扫掠真的命中坦克格 ───────────────────────────────────

func _check_clip_to_tank() -> void:
	var builder := _make_builder_cells(
		[Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4)],
		[{"id": "cockpit_light", "cell": Vector2i(4, 4)}]
	)
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	tank.position = Vector2(400.0, 400.0)
	tank.heading = 0.0
	var field := ProjectileField.new()
	field.setup(definitions)

	# 从右侧射向 (6,4)：该格只有平台层，part_index 必须指向平台格。
	var aim_cell := Vector2i(6, 4)
	var target_centre := tank.world_position_of_cell(aim_cell)
	var origin := target_centre + Vector2(200.0, 0.0)
	# 射手 tag 必须与目标 tag 不同，否则会被 §8.7 的防自击过滤排除（真实场景下是对手开火）。
	field.spawn(origin, Vector2.LEFT, "cal_20", "enemy", [])
	var impacts: Array = []
	for step_index in range(90):
		for raw_event in field.step(1.0 / 60.0, Rect2(0.0, 0.0, 2048.0, 1152.0), [], [damage.target_payload(tank, "player")]):
			var event: Dictionary = raw_event
			if String(event["kind"]) == "impact":
				impacts.append(event)
		if not impacts.is_empty():
			break
	_expect(impacts.size() == 1, "clip_impact_count_%d" % impacts.size())
	if impacts.size() != 1:
		return
	var impact: Dictionary = impacts[0]
	_expect(String(impact["target"]) == "tank", "clip_target_tank")
	_expect(String(impact["tag"]) == "player", "clip_tag")
	_expect(Vector2i(impact["cell"]) == aim_cell, "clip_cell_%s" % str(impact["cell"]))
	var part_index := int(impact["part_index"])
	_expect(part_index >= 0 and part_index < tank.parts.size(), "clip_part_index")
	if part_index >= 0 and part_index < tank.parts.size():
		_expect(String(tank.parts[part_index]["module_id"]) == "platform_cell", "clip_part_is_platform")
		var centre := tank.world_position_of_cell(aim_cell)
		var half := tank.cell_size() * 0.5
		var point: Vector2 = impact["pos"]
		_expect(absf(point.y - centre.y) <= half + 0.01, "clip_pos_y")
		_expect(point.x >= centre.x - half - 0.01 and point.x <= centre.x + half + 0.01, "clip_pos_x")

## 阶段 10（额外）：防自击。炮口原点落在自身格边界时，射手 tag 的弹丸不得命中自己。
## 这是 M5 已实证的缺陷（drive_m5_capture3.png 的「命中本体装甲」），此处提供直接断言。
func _check_no_self_hit() -> void:
	var builder := _make_builder_cells(
		[Vector2i(4, 4), Vector2i(5, 4)],
		[{"id": "cockpit_light", "cell": Vector2i(4, 4)}, {"id": "cannon_20", "cell": Vector2i(5, 4)}]
	)
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	tank.position = Vector2(400.0, 400.0)
	tank.heading = 0.0
	var field := ProjectileField.new()
	field.setup(definitions)
	var payload := damage.target_payload(tank, "player")
	# 炮口原点故意放在船体内某格的边界上，这是 M5 缺陷的真实几何。
	var centre := tank.world_position_of_cell(Vector2i(5, 4))
	var origin := centre + Vector2(tank.cell_size() * 0.5, 0.0)
	field.spawn(origin, Vector2.RIGHT, "cal_20", "player", [])
	var self_hits := 0
	for step_index in range(60):
		for raw_event in field.step(1.0 / 60.0, Rect2(0.0, 0.0, 2048.0, 1152.0), [], [payload]):
			var event: Dictionary = raw_event
			if String(event["kind"]) == "impact" and String(event["target"]) == "tank":
				self_hits += 1
	_expect(self_hits == 0, "self_hit_count_%d" % self_hits)
	# 反向对照：同一几何下，敌方弹丸仍能正常命中（证明过滤只排除射手自身）。
	var probe := ProjectileField.new()
	probe.setup(definitions)
	probe.spawn(origin, Vector2.RIGHT, "cal_20", "enemy", [])
	var enemy_hits := 0
	for step_index in range(60):
		for raw_event in probe.step(1.0 / 60.0, Rect2(0.0, 0.0, 2048.0, 1152.0), [], [payload]):
			var event: Dictionary = raw_event
			if String(event["kind"]) == "impact" and String(event["target"]) == "tank":
				enemy_hits += 1
	_expect(enemy_hits == 1, "enemy_hit_count_%d" % enemy_hits)

# ─── 阶段 9（额外）：damage_scale 与九种升级 / stack_limit ─────────────────────

func _platform_target():
	var builder := _make_builder_cells([Vector2i(4, 4)], [])
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	return {"tank": tank, "damage": damage, "cell": Vector2i(4, 4), "index": _part_index_at(tank, Vector2i(4, 4))}

func _hit_damage(ammo_id: String, upgrades: Array, scale: float) -> float:
	var build: Dictionary = _platform_target()
	var tank: TankBody = build["tank"]
	var damage: DamageSystem = build["damage"]
	var result := damage.apply_hit(tank, build["cell"], int(build["index"]), ammo_id, upgrades, Vector2.RIGHT, scale)
	return float(result["damage"])

func _check_damage_scale_and_upgrades() -> void:
	var armor := _armor_of("platform_cell")
	var base := _base_damage("cal_20")
	var full := _hit_damage("cal_20", [], 1.0)
	var scaled := _hit_damage("cal_20", [], 0.6)
	_expect_near(full, _expected_final(base, 1.0, armor, 0.0), "scale_full")
	_expect_near(scaled, _expected_final(base, 0.6, armor, 0.0), "scale_sixty_percent")

	# up_damage：每层 +0.18，stack_limit 4，第 5 层必须被截断。
	var dmg_value := float(definitions.registry.get_upgrade("up_damage").get("value", 0.0))
	var dmg_limit := int(definitions.registry.get_upgrade("up_damage").get("stack_limit", 1))
	var four: Array = []
	for index in range(dmg_limit):
		four.append("up_damage")
	var five := four.duplicate()
	five.append("up_damage")
	var four_damage := _hit_damage("cal_20", four, 1.0)
	var five_damage := _hit_damage("cal_20", five, 1.0)
	_expect_near(four_damage, _expected_final(base, 1.0 + dmg_value * float(dmg_limit), armor, 0.0), "upgrade_damage_limit")
	_expect_near(five_damage, four_damage, "upgrade_damage_capped")

	# up_pierce：每层 0.2 护甲穿透，armor_eff = armor × 0.8。
	var pierce_value := float(definitions.registry.get_upgrade("up_pierce").get("value", 0.0))
	_expect_near(
		_hit_damage("cal_20", ["up_pierce"], 1.0),
		_expected_final(base, 1.0, armor, pierce_value),
		"upgrade_armor_pierce"
	)

	# up_velocity：只在 projectile_field 侧解释，满层时弹速 ×1.6。
	var velocity := definitions.registry.get_upgrade("up_velocity")
	var velocity_limit := int(velocity.get("stack_limit", 1))
	var velocity_stacks: Array = []
	for index in range(velocity_limit):
		velocity_stacks.append("up_velocity")
	var field := ProjectileField.new()
	field.setup(definitions)
	field.spawn(Vector2(100.0, 100.0), Vector2.RIGHT, "cal_20", "player", velocity_stacks)
	var expected_speed := float(definitions.get_ammo("cal_20").get("speed_px_s", 0.0)) * (1.0 + float(velocity.get("value", 0.0)) * float(velocity_limit))
	_expect_near(float(field.shots[0]["speed"]), expected_speed, "upgrade_velocity")

	# up_split / up_explosive / up_delay 需要邻近目标，另建一套装置。
	var builder := _make_builder_cells(
		[Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4)],
		[
			{"id": "cannon_155", "cell": Vector2i(4, 4)},
			{"id": "conveyor_straight", "cell": Vector2i(3, 4)},
		]
	)
	if builder == null:
		return

	var split_tank := _tank_for(builder)
	var split_damage := _damage_for(builder, split_tank)
	var split_index := _part_index_at(split_tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	split_damage.apply_hit(split_tank, Vector2i(4, 4), split_index, "cal_20", ["up_split"], Vector2.RIGHT)
	var split_events := _events_of(split_damage.drain_events(), "split")
	_expect(split_events.size() == 1, "upgrade_split_event_%d" % split_events.size())
	if split_events.size() == 1:
		_expect(int(split_events[0]["count"]) == 1, "upgrade_split_count")
		_expect_near(
			float(split_events[0]["scale"]),
			float(definitions.registry.get_upgrade("up_split").get("value", 0.0)),
			"upgrade_split_scale"
		)

	var blast_tank := _tank_for(builder)
	var blast_damage := _damage_for(builder, blast_tank)
	var blast_index := _part_index_at(blast_tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	blast_damage.apply_hit(blast_tank, Vector2i(4, 4), blast_index, "cal_20", ["up_explosive"], Vector2.RIGHT)
	var blast_events := _events_of(blast_damage.drain_events(), "explosion")
	var reached_conveyor := false
	for raw_blast in blast_events:
		if String(raw_blast["module_id"]) == "conveyor_straight":
			reached_conveyor = true
	_expect(reached_conveyor, "upgrade_explosive_aoe")

	var delay_tank := _tank_for(builder)
	var delay_damage := _damage_for(builder, delay_tank)
	var delay_index := _part_index_at(delay_tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	var hp_before := float(delay_tank.parts[delay_index]["hp"])
	var delayed := delay_damage.apply_hit(delay_tank, Vector2i(4, 4), delay_index, "cal_20", ["up_delay"], Vector2.RIGHT)
	_expect(_events_of(delay_damage.drain_events(), "delay_armed").size() == 1, "upgrade_delay_armed")
	_expect_near(float(delay_tank.parts[delay_index]["hp"]), hp_before, "upgrade_delay_not_immediate")
	delay_damage.step(definitions.global_number("delay_explosion_s", 0.8))
	_expect(float(delay_tank.parts[delay_index]["hp"]) < hp_before, "upgrade_delay_settles")
	_expect(float(delayed["damage"]) > 0.0, "upgrade_delay_reports_raw")

	# up_burn 与 up_slow 在阶段 6 已各自断言，此处只核对 stack_limit 的共用规则。
	var slow_limit := int(definitions.registry.get_upgrade("up_slow").get("stack_limit", 1))
	_expect(slow_limit == 2, "upgrade_slow_stack_limit_%d" % slow_limit)

# ─── 阶段 10（验收 8）：维修量、驾驶舱减半、判负后不再维修 ─────────────────────

func _check_repair() -> void:
	var repair_def := definitions.get_module("repair_small")
	var repair_hp := float(repair_def.get("repair_hp", 0.0))
	var period := float(repair_def.get("period_s", 1.0))
	var core_factor := definitions.global_number("repair_core_factor", 0.5)

	# 普通目标：每周期恰好 repair_hp。
	var builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4)], [
		{"id": "repair_small", "cell": Vector2i(4, 4)},
		{"id": "cannon_20", "cell": Vector2i(5, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var target_index := _part_index_at(tank, Vector2i(5, 4), TankBody.KIND_MODULE)
	damage.apply_hit(tank, Vector2i(5, 4), target_index, "cal_20", [], Vector2.RIGHT)
	damage.drain_events()
	damage.step(period)
	var healed := _events_of(damage.drain_events(), "repaired")
	_expect(healed.size() == 1, "repair_normal_event_%d" % healed.size())
	if healed.size() == 1:
		_expect_near(float(healed[0]["amount"]), repair_hp, "repair_normal_amount")
		_expect(not bool(healed[0]["core"]), "repair_normal_not_core")

	# 驾驶舱目标：同样的周期只回 repair_core_factor × repair_hp。
	var core_builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4)], [
		{"id": "cockpit_light", "cell": Vector2i(4, 4)},
		{"id": "repair_small", "cell": Vector2i(5, 4)},
	])
	if core_builder == null:
		return
	var core_tank := _tank_for(core_builder)
	var core_damage := _damage_for(core_builder, core_tank)
	var core_index := _part_index_at(core_tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	core_damage.apply_hit(core_tank, Vector2i(4, 4), core_index, "cal_76", [], Vector2.RIGHT)
	core_damage.drain_events()
	core_damage.step(period)
	var core_healed := _events_of(core_damage.drain_events(), "repaired")
	_expect(core_healed.size() == 1, "repair_core_event_%d" % core_healed.size())
	if core_healed.size() == 1:
		_expect_near(float(core_healed[0]["amount"]), repair_hp * core_factor, "repair_core_amount")
		_expect(bool(core_healed[0]["core"]), "repair_core_flag")

	# 驾驶舱一旦被摧毁即判负，同帧之后不可能再被修回来。
	core_damage.apply_hit(core_tank, Vector2i(4, 4), core_index, "cal_155", [], Vector2.RIGHT)
	var killing := core_damage.drain_events()
	_expect(_events_of(killing, "core_destroyed").size() == 1, "repair_core_destroyed_event")
	_expect(core_damage.defeated, "repair_defeated_flag")
	core_damage.step(period * 3.0)
	core_damage.step(period * 3.0)
	_expect(_events_of(core_damage.drain_events(), "repaired").is_empty(), "repair_after_defeat_silent")

# ─── R17-5：护盾本体被毁后记录必须删除，不能继续充能并“复活” ─────────────

## 缺陷表现：摧毁护盾本体不走 rebuild()，旧的 _shields 记录会继续倒计时，
## 充能完毕后变为 ACTIVE 并再次挡伤害，违反 design §6.6。
func _check_shield_pruned_when_body_destroyed() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4)], [
		{"id": "shield_cell", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	_expect(damage.shields().size() == 1, "prune_initial_record")
	damage.apply_part_damage(tank, index, 1.0e9, "destroyed")
	_expect(_part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE) < 0, "prune_body_gone")
	_expect(damage.shields().is_empty(), "prune_record_removed")
	# 充能时长已过：即使给足时间也不能出现记录。
	damage.step(float(definitions.get_module("shield_cell").get("recharge_s", 6.0)) + 1.0)
	_expect(damage.shields().is_empty(), "prune_never_resurrects")

# ─── R17-6：AOE 删掉低索引部件后，直接命中必须仍落在原目标上 ──────────────

## 缺陷表现：_strike 先按 cell 解出 target 下标，再跑 AOE（可能删掉若干低索引部件），
## 最后用旧下标扣血。下标一起往后错位，伤害就落到下一件无关部件上。
## 装置：平台 x=4..10；弹药库在 (9,4)（受击目标，hp 55）；直管在 (4,4)（索引紧随其后，
## 但距目标 5 格，AOE 够不着）。先把平台 (8,4) 削到 1 hp，让它被 AOE 击杀从而删除低索引部件。
## 旧代码：下标 7 删一格后指向直管 → 直管死。新代码：按 part_key 重定位 → 弹药库hp 55−。
func _check_aoe_keeps_direct_target() -> void:
	var cells: Array = []
	for x in range(4, 11):
		cells.append(Vector2i(x, 4))
	var builder := _make_builder_cells(cells, [
		{"id": "ammo_depot_small", "cell": Vector2i(9, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(4, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var target_index := _part_index_at(tank, Vector2i(9, 4), TankBody.KIND_MODULE)
	var fragile := _part_index_at(tank, Vector2i(8, 4), TankBody.KIND_PLATFORM_CELL)
	var bystander := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	_expect(target_index >= 0 and fragile >= 0 and bystander >= 0, "aoe_setup_parts")
	_expect(fragile < target_index, "aoe_low_index_before_target")
	var depot_hp_max := float(tank.parts[target_index]["hp"])
	var conveyor_hp_max := float(tank.parts[bystander]["hp"])
	# 削到 1 hp：确保 AOE 一定能杀掉这格平台，从而删除一个低索引部件。
	tank.damage_part(fragile, float(tank.parts[fragile]["hp"]) - 1.0)
	var final := _expected_final(_base_damage("cal_76"), 1.0, _armor_of("ammo_depot_small"), 0.0)
	damage.apply_hit(tank, Vector2i(9, 4), target_index, "cal_76",
		["up_explosive"], Vector2.RIGHT)
	damage.drain_events()
	# AOE 必须真的删掉了低索引部件，否则本用例没有区分度。
	_expect(_part_index_at(tank, Vector2i(8, 4), TankBody.KIND_PLATFORM_CELL) < 0, "aoe_killed_low_index_part")
	var depot_now := _part_index_at(tank, Vector2i(9, 4), TankBody.KIND_MODULE)
	_expect(depot_now >= 0, "aoe_target_survived")
	if depot_now >= 0:
		_expect_near(float(tank.parts[depot_now]["hp"]), depot_hp_max - final, "aoe_direct_target_damaged")
	var conveyor_now := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	_expect(conveyor_now >= 0, "aoe_bystander_alive")
	if conveyor_now >= 0:
		_expect_near(float(tank.parts[conveyor_now]["hp"]), conveyor_hp_max, "aoe_bystander_untouched")

# ─── R17-7：延迟爆炸上报的 damage 必须是过完护甲的数值 ────────────────────

## 缺陷表现：延迟分支上报 raw（未过护甲），而立即分支上报 _final_damage。
## duel 用 damage_dealt 判超时胜负，因此带 up_delay 的一方会被系统性高估。
func _check_delayed_reports_post_armor() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4)], [])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_PLATFORM_CELL)
	_expect(index >= 0, "delay_platform_found")
	var base := _base_damage("cal_20")
	var armor := float(tank.parts[index].get("armor", 0.0))
	var hit := damage.apply_hit(tank, Vector2i(4, 4), index, "cal_20", ["up_delay"], Vector2.RIGHT)
	var expected := _expected_final(base, 1.0, armor, 0.0)
	_expect_near(float(hit["damage"]), expected, "delay_reports_post_armor")
	_expect(expected < base, "delay_platform_has_armor")
	# 真正扣血必须与上报一致。
	var hp_before := float(tank.parts[index]["hp"])
	damage.step(float(definitions.global_number("delay_explosion_s", 0.8)) + 0.1)
	var hp_after := 0.0
	var live := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_PLATFORM_CELL)
	if live >= 0:
		var hp_now := float(tank.parts[live]["hp"])
		var healed := 0.0
		for raw in _events_of(damage.drain_events(), "repaired"):
			healed += float(raw["amount"])
		hp_after = hp_now + healed
	_expect_near(hp_before - hp_after, expected, "delay_actual_matches_report")

# ─── R17-8：AOE 击杀的部件只能产生一条 destroyed 事件 ────────────────────

## 缺陷表现：_area_damage 自己 append 一条 destroyed，又调 _on_destroyed 再 append 一条，
## 于是被 AOE 打死的部件产生两条 destroyed（HUD 与 scrap 统计双倍计数）。
## 装置：弹药库 (4,4) 被直接打爆 → 殉爆半径 2.5 格 → 波及直管 (6,4) 把它也打爆。
## 直管是被 **AOE** 杀死的，正好走 _area_damage 这条路径。统计它的 destroyed 条数。
func _check_aoe_single_destroyed_event() -> void:
	var builder := _make_builder_cells([Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4)], [
		{"id": "ammo_depot_small", "cell": Vector2i(4, 4)},
		{"id": "conveyor_straight", "cell": Vector2i(6, 4)},
	])
	if builder == null:
		return
	var tank := _tank_for(builder)
	var damage := _damage_for(builder, tank)
	var depot_index := _part_index_at(tank, Vector2i(4, 4), TankBody.KIND_MODULE)
	_expect(depot_index >= 0, "dup_depot_found")
	# 殉爆伤害 = per_slot × slots，远超过直管 hp，因此直管必被 AOE 击杀。
	damage.apply_part_damage(tank, depot_index, 1.0e9, "destroyed")
	var events := damage.drain_events()
	var conveyor_kills := 0
	for raw in _events_of(events, "destroyed"):
		if String(raw["module_id"]) == "conveyor_straight":
			conveyor_kills += 1
	_expect(_part_index_at(tank, Vector2i(6, 4), TankBody.KIND_MODULE) < 0, "dup_conveyor_killed_by_aoe")
	_expect(conveyor_kills == 1, "dup_destroyed_event_count_%d" % conveyor_kills)
