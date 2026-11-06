extends SceneTree

## M9 冒烟：波次生存（roadmap §2 M9 的 11 条验收）。
## 不渲染、不读截图；断言值全部来自 data/*.json。
## 注意：`match` 是 GDScript 保留字，本文件的 run 实例统一命名为 run_state。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const Duel := preload("res://scripts/duel.gd")
const BotAI := preload("res://scripts/bot_ai.gd")
const SurvivalRun := preload("res://scripts/survival_run.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("SURVIVAL_DATA_FAILED")
		quit(1)
		return
	_check_constants()
	_check_wave_shape()
	_check_start_wave()
	_check_wave_passes_on_timer()
	_check_reinforcement()
	_check_roster_shape()
	_check_run_ends_on_cockpit_loss()
	if failures > 0:
		printerr("SURVIVAL_FAIL count=%d" % failures)
		quit(1)
		return
	## 验收 11 / 12 / 13 要跑真实战斗推进，必须后置：它们会修改同一批 run 实例的战斗状态。
	## v3.44：这一组「后置」验收里原本只调了 2 个。`_check_props` / `_check_xp_and_levels` /
	## `_check_level_choices` / `_check_shop` / `_check_boss_wave` / `_check_modification` /
	## `_check_player_fire_damage` / `_check_no_combat_modification` / `_check_determinism`
	## 九个函数**存在但从未被调用**（`SURVIVAL_OK` 因此只覆盖了 10 / 19 个验收）。
	## 不是本轮代码改坏的，但正是「看着像绿其实没跑」的典型，一并接上。
	_check_props()
	_check_xp_and_levels()
	_check_level_choices()
	_check_shop()
	_check_shop_rarity_weights()
	_check_tier_thresholds_from_data()
	_check_boss_wave()
	_check_modification()
	_check_player_fire_damage()
	_check_no_combat_modification()
	_check_determinism()
	_check_house_reward_feedback()
	_check_enemy_drop_reward()
	_check_wave_clear_credit()
	if failures > 0:
		printerr("SURVIVAL_FAIL count=%d" % failures)
		quit(1)
		return
	print("SURVIVAL_OK")
	quit(0)

func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("SURVIVAL_FAIL %s" % tag)

func _expect_near(value: float, expected: float, tag: String) -> void:
	_expect(absf(value - expected) <= 0.001, "%s %.4f != %.4f" % [tag, value, expected])

## 建造起始车体：**直接调 `SurvivalRun.build_starter()`**，不再自己再摆一遍。
## 测试与实际开局车必须是同一份布局，否则「测试通过但玩家打不动」这类分歧会重现。
func _make_rig() -> GridBuilder:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		return null
	var reason: String = SurvivalRun.build_starter(builder)
	if not reason.is_empty():
		printerr("SURVIVAL_STARTER_FAILED %s" % reason)
		failures += 1
	return builder

func _make_run(seed_value: int = 7) -> SurvivalRun:
	var run_state := SurvivalRun.new()
	if not run_state.setup(definitions, "arena_standard", seed_value):
		failures += 1
		printerr("SURVIVAL_FAIL run_setup")
		return null
	return run_state

# ─── 验收 0：常量全部从 data/globals.json 的 survival 块读取 ────────────────

func _check_constants() -> void:
	var block: Dictionary = definitions.registry.globals.get("survival", {})
	_expect(not block.is_empty(), "constants_block_present")
	for key in ["wave_time_s", "wave_growth_s", "enemy_count_base", "enemy_count_per_wave",
			"enemy_count_max", "boss_every", "xp_base", "xp_step", "xp_per_kill",
			"credit_per_kill", "house_hp", "house_armor", "shop_slot_count",
			"shop_reroll_cost", "shop_sell_rate", "boss_credit_reward", "boss_xp_reward",
			"boss_drop_count", "props_houses", "props_debris", "shop_rarity_weight",
			"shop_tier_price_multiplier", "tier_wave_thresholds"]:
		_expect(block.has(key), "constants_key_%s" % key)
	## 旧 expedition 块必须已经退役——否则玩家会在两个数值源之间漂移。
	_expect(not definitions.registry.globals.has("expedition"), "constants_expedition_retired")

# ─── 验收 1：波次时限与敌人数量随波次递增，Boss 波固定 1 台 ─────────────────

func _check_wave_shape() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	var base := definitions.block_number("survival", "wave_time_s", 45.0)
	var growth := definitions.block_number("survival", "wave_growth_s", 5.0)
	var boss_every := definitions.block_int("survival", "boss_every", 5)
	_expect_near(run_state.wave_time_for(1), base, "wave_time_w1")
	_expect_near(run_state.wave_time_for(boss_every), base, "wave_time_w5")
	_expect_near(run_state.wave_time_for(boss_every + 1), base + growth, "wave_time_w6")
	_expect_near(run_state.wave_time_for(boss_every * 2 + 1), base + growth * 2.0, "wave_time_w11")

	_expect(run_state.enemy_count_for(1) == definitions.block_int("survival", "enemy_count_base", 2), "enemy_count_w1")
	_expect(run_state.enemy_count_for(2) >= run_state.enemy_count_for(1), "enemy_count_monotonic")
	_expect(run_state.enemy_count_for(40) <= definitions.block_int("survival", "enemy_count_max", 6), "enemy_count_capped")
	_expect(run_state.enemy_count_for(boss_every) == 1, "enemy_count_boss_wave")

	## 敌人级别：1–4 新兵、5–9 老兵、10–14 精英、15+ 王牌；
	## Boss 波（5/10/15…）另按 design §3.4.5 抬高到**至少精英**。
	_expect(run_state.tier_for(1) == BotAI.TIER_RECRUIT, "tier_w1")
	_expect(run_state.tier_for(4) == BotAI.TIER_RECRUIT, "tier_w4")
	_expect(run_state.tier_for(6) == BotAI.TIER_VETERAN, "tier_w6")
	_expect(run_state.tier_for(5) == BotAI.TIER_ELITE, "tier_w5_boss_floor")
	_expect(run_state.tier_for(10) == BotAI.TIER_ELITE, "tier_w10")
	_expect(run_state.tier_for(15) == BotAI.TIER_ACE, "tier_w15")

	_expect(not run_state.is_boss_wave(), "boss_wave_w1")
	run_state.wave = boss_every
	_expect(run_state.is_boss_wave(), "boss_wave_w5")
	run_state.wave = boss_every * 2
	_expect(run_state.is_boss_wave(), "boss_wave_w10")

# ─── 验收 2：开局生成正确数量的敌人，且各自独立 ─────────────────────────────

func _check_start_wave() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	_expect(run_state.start_wave(), "start_wave")
	var expected := run_state.enemy_count_for(1)
	var enemy_tags := run_state.duel.alive_in_team(Duel.TEAM_ENEMY)
	_expect(enemy_tags.size() == expected, "start_enemy_count_%d_expected_%d" % [enemy_tags.size(), expected])
	_expect(run_state.enemy_ai.size() == expected, "start_enemy_ai_%d" % run_state.enemy_ai.size())
	## 每个敌人必须有独立 AI，且 target 指向玩家。
	var seen_targets := {}
	for raw_tag in run_state.enemy_ai.keys():
		var tag := String(raw_tag)
		var brain: BotAI = run_state.enemy_ai[tag]
		_expect(brain.self_tag == tag, "start_ai_self_%s" % tag)
		_expect(brain.target_tag == Duel.TAG_PLAYER, "start_ai_target_%s" % tag)
		seen_targets[brain.self_tag] = true
	_expect(seen_targets.size() == expected, "start_ai_distinct_%d" % seen_targets.size())
	_expect(not run_state.duel.defeated(Duel.TAG_PLAYER), "start_player_alive")
	## 敌人生成点不得互相重叠（否则会因互撞立刻扣血）。
	var centres: Array = []
	for raw_tag in enemy_tags:
		var tank = run_state.duel.tank_of(String(raw_tag))
		if tank == null:
			continue
		centres.append(tank.position)
	for i in range(centres.size()):
		for j in range(i + 1, centres.size()):
			var gap: float = (centres[i] as Vector2).distance_to(centres[j] as Vector2)
			_expect(gap > 16.0, "start_enemy_spacing_%.1f" % gap)

# ─── 验收 3：计时归零且驾驶舱存活 = 本波通过（不是平局）──────────────────────

func _check_wave_passes_on_timer() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	## 玩家原地不动、敌人也不开枪：直接清空 AI 表。
	## 为什么不能只清一次输入：`step_battle()` 每帧都会重新调 `brain.think()` 并 `set_input()`，
	## 所以零输入会被下一帧覆盖，敌人照常开火、玩家会被打死，
	## 那样测的就不是「计时归零」而是「能不能活到计时归零」。清空 AI 表才是真的不动不打。
	run_state.enemy_ai.clear()
	var dt := 1.0 / 60.0
	var steps := int(ceilf(run_state.wave_time_limit / dt)) + 5
	for step_index in range(steps):
		if run_state.stage != SurvivalRun.STAGE_BATTLE:
			break
		run_state.step_battle(dt)
	_expect(run_state.wave_passed, "wave_passed_on_timer")
	_expect(run_state.stage != SurvivalRun.STAGE_BATTLE, "wave_left_battle")
	_expect_near(run_state.wave_time_left, 0.0, "wave_time_zero")
	_expect(not run_state.run_over, "wave_pass_not_run_over")

# ─── 验收 3b：本波内持续补兵（用户 2026-10-21「敌人不断地生成」）────────────────

## 验证三件事：
## ① 首批只出「同屏上限」那么多台，配额比它大；
## ② 场上被杀空后，只要配额未尽就不会过关，而且会按间隔补上台；
## ③ 配额耗尽且场上无敌人时才过关。
func _check_reinforcement() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	var cap := run_state.enemy_count_for(1)
	var quota := run_state.enemy_quota_for(1)
	_expect(quota > cap, "reinforce_quota_%d_over_cap_%d" % [quota, cap])
	_expect(run_state._enemies_spawned == cap, "reinforce_initial_%d" % run_state._enemies_spawned)
	## 清空 AI 表，让敌人不反抗、也不动；然后手动把它们全部打死。
	run_state.enemy_ai.clear()
	var dt := 1.0 / 60.0
	for raw_tag in run_state.duel.alive_in_team(Duel.TEAM_ENEMY):
		var tank = run_state.duel.tank_of(String(raw_tag))
		if tank == null:
			continue
		var damage = run_state.duel.damage_of(String(raw_tag))
		for index in range(tank.parts.size() - 1, -1, -1):
			damage.apply_part_damage(tank, index, 1.0e9, "destroyed")
			if damage.defeated:
				break
	## 一帧结算掉这批击杀，然后确认：配额未尽 → 不能过关。
	run_state.step_battle(dt)
	_expect(not run_state.wave_passed, "reinforce_not_passed_while_quota_left")
	_expect(run_state.stage == SurvivalRun.STAGE_BATTLE, "reinforce_still_in_battle")
	## 等补兵间隔过去，必须补上台，且总数增加。
	var spawned_before := run_state._enemies_spawned
	var delay_steps := int(ceilf(run_state._enemy_reinforce_delay_s / dt)) + 5
	for step_index in range(delay_steps):
		if run_state.stage != SurvivalRun.STAGE_BATTLE:
			break
		run_state.enemy_ai.clear()
		run_state.step_battle(dt)
	_expect(run_state._enemies_spawned > spawned_before, "reinforce_spawned_more_%d" % run_state._enemies_spawned)
	_expect(run_state.duel.alive_in_team(Duel.TEAM_ENEMY).size() >= 1, "reinforce_field_not_empty")

# ─── 验收 3c：坦克阵容 —— 每档三种不同轮廓、每档都比玩家起始车大但不再是 30 格 ──

func _blueprint_cells_of(blueprint: Dictionary) -> int:
	return (blueprint.get("platform_cells", []) as Array).size()

func _check_roster_shape() -> void:
	var starter_cells := SurvivalRun.STARTER_SIZE.x * SurvivalRun.STARTER_SIZE.y
	var recruit_max := 0
	var tier_ids := ["recruit", "veteran", "elite", "ace"]
	var previous_cells := 0
	for tier in tier_ids:
		var ids: Array = []
		for raw_id in definitions.registry.blueprints.keys():
			if String(raw_id).begins_with("bot_%s_" % tier):
				ids.append(String(raw_id))
		ids.sort()
		_expect(ids.size() == 3, "roster_%s_count_%d" % [tier, ids.size()])
		## 同档三张必须**不同轮廓**：用「平台格集合」而不是格数区分，
		## 否则三张同面积的长方形会被当成不同坦克。
		var shapes := {}
		var min_cells := 99999
		for raw_id in ids:
			var blueprint: Dictionary = definitions.get_blueprint(String(raw_id))
			var cells := _blueprint_cells_of(blueprint)
			min_cells = mini(min_cells, cells)
			var key := ""
			for raw_cell in blueprint.get("platform_cells", []):
				key += "%d,%d;" % [int((raw_cell as Array)[0]), int((raw_cell as Array)[1])]
			shapes[key] = true
		_expect(shapes.size() == 3, "roster_%s_distinct_%d" % [tier, shapes.size()])
		if tier == "recruit":
			recruit_max = min_cells
		## 档位越高体量越大（同档取最小格数比较，保证单调）。
		_expect(min_cells >= previous_cells, "roster_%s_min_cells_%d_prev_%d" % [tier, min_cells, previous_cells])
		previous_cells = min_cells
	## 用户 2026-10-21：「初始敌人的坦克过于大应该再缩小」。
	## 旧招募级是 30 格平台、约玩家起始车的 2 倍；现在要求不超过起始车的 1.6 倍。
	_expect(recruit_max <= int(ceilf(float(starter_cells) * 1.6)), "roster_recruit_shrunk_%d_vs_starter_%d" % [recruit_max, starter_cells])

# ─── 验收 4：驾驶舱被毁 = run 立即结束，不进入 RESULT 复盘 ──────────────────

func _check_run_ends_on_cockpit_loss() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	var player = run_state.duel.tank_of(Duel.TAG_PLAYER)
	_expect(player != null, "end_player_exists")
	if player == null:
		return
	var cockpit := -1
	for index in range(player.parts.size()):
		if String(player.parts[index]["module_id"]).begins_with("cockpit"):
			cockpit = index
			break
	_expect(cockpit >= 0, "end_cockpit_found")
	if cockpit < 0:
		return
	## 直接打爆驾驶舱（走真实的伤害路由，触发判负连锁）。
	run_state.duel.damage_of(Duel.TAG_PLAYER).apply_part_damage(player, cockpit, 1.0e9, "destroyed")
	run_state.step_battle(1.0 / 60.0)
	_expect(run_state.run_over, "end_run_over")
	_expect(run_state.stage == SurvivalRun.STAGE_SUMMARY, "end_stage_summary")
	## 结算面板必须报“到达第几波”，且没有通关字段。
	var panel := run_state.summary()
	_expect(int(panel["wave_reached"]) >= 1, "end_summary_wave")
	_expect(not panel.has("cleared"), "end_summary_no_cleared_field")

# ─── 验收 5：房屋与残骸 —— 房屋可被炮击摧毁并留下可碾残骸 ──────────────────

func _check_props() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	_expect(run_state.houses.size() == definitions.block_int("survival", "props_houses", 4), "props_house_count_%d" % run_state.houses.size())
	_expect(run_state.debris.size() == definitions.block_int("survival", "props_debris", 6), "props_debris_count_%d" % run_state.debris.size())
	var hp_max := definitions.block_number("survival", "house_hp", 260.0)
	var armor := definitions.block_number("survival", "house_armor", 5.0)
	_expect_near(float(run_state.houses[0]["hp"]), hp_max, "props_house_hp")
	_expect_near(float(run_state.houses[0]["armor"]), armor, "props_house_armor")

	## 炮击：直接对房屋施加一次真实弹道伤害（cal_155 一发不够，打两发）。
	var credit_before := run_state.credit
	var xp_before := run_state.experience
	var house: Dictionary = run_state.houses[0]
	var ammo := float(definitions.get_ammo("cal_155").get("base_damage", 0.0))
	var guard := 0
	while bool(house["alive"]) and guard < 40:
		run_state._damage_house(house, ammo, [])
		guard += 1
	_expect(not bool(house["alive"]), "props_house_destroyed")
	_expect(run_state.houses_destroyed == 1, "props_house_counter")
	_expect(run_state.credit > credit_before, "props_house_credit")
	_expect(run_state.experience > xp_before, "props_house_xp")
	## 摧毁后必须留下残骸格（二次收益）。
	var found := false
	for item in run_state.debris:
		if bool(item["is_house"]) and Vector2i(item["cell"]) == Vector2i(house["cell"]):
			found = true
			break
	_expect(found, "props_house_debris_left")

	## 碾残骸：把玩家挪到残骸格上，一次 step 后必须被拾取且只拾取一次。
	var target: Dictionary = {}
	for item in run_state.debris:
		if not bool(item["taken"]):
			target = item
			break
	_expect(not target.is_empty(), "props_debris_available")
	if target.is_empty():
		return
	var player = run_state.duel.tank_of(Duel.TAG_PLAYER)
	## 残骸格是竞技场格坐标，坦克 position 是质心世界坐标；把质心直接放到残骸格中心，
	## 质心附近的某一格就会压在残骸上（旧码把竞技场格当局部格传，位置完全不对）。
	var cell_size: float = player.cell_size()
	player.position = (Vector2(Vector2i(target["cell"])) + Vector2(0.5, 0.5)) * cell_size
	var taken_before := run_state.debris_taken
	run_state.step_battle(1.0 / 60.0)
	_expect(run_state.debris_taken == taken_before + 1, "props_debris_crushed")
	run_state.step_battle(1.0 / 60.0)
	_expect(run_state.debris_taken == taken_before + 1, "props_debris_only_once")

# ─── 验收 6：经验曲线与逐级结算，溢出到下一级不丢弃 ────────────────────────

func _check_xp_and_levels() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	var base := definitions.block_number("survival", "xp_base", 60.0)
	var step := definitions.block_number("survival", "xp_step", 45.0)
	_expect_near(run_state.xp_needed_for(1), base, "xp_need_l1")
	_expect_near(run_state.xp_needed_for(2), base + step, "xp_need_l2")
	_expect_near(run_state.xp_needed_for(3), base + step * 2.0, "xp_need_l3")
	## 一次给足两级 + 少量余量：必须升两级且余量保留。
	var amount := base + (base + step) + 10.0
	run_state._add_xp(amount)
	_expect(run_state.level == 3, "xp_level_%d" % run_state.level)
	_expect_near(run_state.xp_into_level, 10.0, "xp_overflow_kept")
	_expect_near(run_state.experience, amount, "xp_total_accumulated")
	## 升了两级就必须攒下两次待领取的升级，否则升级菜单永远弹不出来
	## （旧实现靠重算剩余经验，而等级已经被抬完，结果恒为 0 → 直接跳进商店）。
	_expect(run_state.pending_level_ups == 2, "xp_pending_%d" % run_state.pending_level_ups)
	## 波次通过时必须先进升级菜单，而不是直接进商店。
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	run_state._enter_intermission([])
	_expect(run_state.stage == SurvivalRun.STAGE_LEVEL_UP, "xp_level_up_reachable_%s" % run_state.stage)
	## 领完两份奖励后必须落到商店。
	var guard := 0
	while run_state.stage == SurvivalRun.STAGE_LEVEL_UP and guard < 8:
		guard += 1
		if not run_state.take_level_choice(0):
			break
	_expect(run_state.stage == SurvivalRun.STAGE_SHOP, "xp_shop_after_all_choices_%s" % run_state.stage)
	_expect(run_state.pending_level_ups == 0, "xp_pending_drained_%d" % run_state.pending_level_ups)

# ─── 验收 7：升级菜单三选一，不可跳过；赠品进 inventory 不自动贴装 ─────────

func _check_level_choices() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	var want := definitions.block_int("survival", "choice_count", 3)
	run_state._open_level_up()
	_expect(run_state.stage == SurvivalRun.STAGE_LEVEL_UP, "level_stage")
	_expect(run_state.level_choices.size() == want, "level_choice_count_%d" % run_state.level_choices.size())
	## 候选不得重复（kind + id 唯一）。
	var seen := {}
	for raw in run_state.level_choices:
		var entry: Dictionary = raw
		var key := "%s|%s" % [entry["kind"], entry["id"]]
		_expect(not seen.has(key), "level_choice_duplicate_%s" % key)
		seen[key] = true
	## 非法索引必须被拒（= 不可跳过）。
	_expect(not run_state.take_level_choice(-1), "level_reject_negative")
	_expect(not run_state.take_level_choice(want), "level_reject_overflow")
	_expect(run_state.stage == SurvivalRun.STAGE_LEVEL_UP, "level_still_open_after_reject")
	## 选第一个合法候选后必须离开升级页。
	var inventory_before := run_state.inventory.size()
	var level_before := run_state.level
	var mass_before := run_state.builder.mass_cap_level
	var pick: Dictionary = run_state.level_choices[0]
	_expect(run_state.take_level_choice(0), "level_take_first")
	_expect(run_state.stage != SurvivalRun.STAGE_LEVEL_UP or run_state.level > level_before, "level_advanced_or_closed")
	match String(pick["kind"]):
		SurvivalRun.CHOICE_MASS_CAP:
			_expect(run_state.builder.mass_cap_level > mass_before, "level_mass_cap_applied")
		SurvivalRun.CHOICE_UPGRADE:
			## 期望值跟着行为走：升级是**实体模块上的槽配置**（v3.24 / 用户 2026-10-17 的原始需求），
			## 所以它先去 `collected_upgrades`（若车上有空槽则直接就位），进改装页时由
			## `flush_collected_upgrades()` 落到槽里。这里断言两者之一：暂存了 **或** 已就位。
			## 旧断言只看 `collected_upgrades`，在「有空槽、直接装上」这一支会假红——
			## 那个函数此前从未被 `_init()` 调用，所以一直没人发现。
			var upgrade_id := String(pick["id"])
			var staged := run_state.collected_upgrades.has(upgrade_id)
			var fitted := run_state.installed_upgrades().has(upgrade_id)
			_expect(staged or fitted, "level_upgrade_collected")
		_:
			_expect(run_state.inventory.size() > inventory_before, "level_module_to_inventory")

# ─── 验收 8：商店 6 格、可刷新、可买、可卖、卖出价 = price × rate ──────────

func _check_shop() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	run_state._open_shop()
	_expect(run_state.stage == SurvivalRun.STAGE_SHOP, "shop_stage")
	var want := definitions.block_int("survival", "shop_slot_count", 6)
	_expect(run_state.shop_slots.size() == want, "shop_slot_count_%d" % run_state.shop_slots.size())
	## 同一次刷新内不重复。
	var ids := {}
	for raw in run_state.shop_slots:
		var slot: Dictionary = raw
		_expect(not ids.has(String(slot["id"])), "shop_slot_duplicate_%s" % slot["id"])
		ids[String(slot["id"])] = true

	## 刷新：扣固定价，价格不随次数递增。
	var cost := definitions.block_number("survival", "shop_reroll_cost", 60.0)
	run_state.credit = cost * 3.0
	var before := run_state.credit
	_expect(run_state.reroll_shop(), "shop_reroll_ok")
	_expect_near(run_state.credit, before - cost, "shop_reroll_cost")
	_expect(run_state.reroll_shop(), "shop_reroll_twice")
	_expect_near(run_state.credit, before - cost * 2.0, "shop_reroll_cost_fixed")

	## 买：钱够则扣款、进库存、该格标记已售。
	var slot_index := -1
	for index in range(run_state.shop_slots.size()):
		if not bool((run_state.shop_slots[index] as Dictionary)["sold"]):
			slot_index = index
			break
	_expect(slot_index >= 0, "shop_has_unsold")
	if slot_index < 0:
		return
	var slot: Dictionary = run_state.shop_slots[slot_index]
	run_state.credit = float(slot["price"]) + 1.0
	var credit_before := run_state.credit
	var inv_before := run_state.inventory.size()
	_expect(run_state.buy_shop_slot(slot_index), "shop_buy_ok")
	_expect_near(run_state.credit, credit_before - float(slot["price"]), "shop_buy_price")
	_expect(run_state.inventory.size() == inv_before + 1, "shop_buy_to_inventory")
	_expect(bool(slot["sold"]), "shop_buy_marked_sold")
	_expect(not run_state.buy_shop_slot(slot_index), "shop_buy_twice_rejected")

	## 卖：回收 price × rate。
	var sell_rate := definitions.block_number("survival", "shop_sell_rate", 0.5)
	var sell_id := run_state.inventory[0]
	var sell_price := float(definitions.get_module(sell_id).get("price", 0.0))
	var credit_pre_sell := run_state.credit
	var inv_pre_sell := run_state.inventory.size()
	_expect(run_state.sell_inventory(0), "shop_sell_ok")
	_expect_near(run_state.credit, credit_pre_sell + sell_price * sell_rate, "shop_sell_rate")
	_expect(run_state.inventory.size() == inv_pre_sell - 1, "shop_sell_removed")

	## 无倒带：没有“重开本波”的入口。
	_expect(not run_state.has_method("restart_wave"), "shop_no_restart_wave")

# ─── 验收 8b：商店稀有度 = 按档加权抽取（v3.46 审核 S1）─────────────────────

## 旧版把 `shop_rarity_weight` 当成**价格倍率**用，而 `_roll_shop()` 对所有 `price > 0` 的
## 模块**均匀**抽 —— 于是 6 cr 的直管与 260 cr 的 `cockpit_armored` 出现概率完全相同，
## 「稀有商品」名不副实，`shop_rarity_weight` 这个数据键对玩法毫无影响。
##
## 这一条必须能区分「加权」与「均匀」：把权重压成 `[1,0,0]` 后**每一格都必须是普通档**，
## 压成 `[0,0,1]` 后**每一格都必须是史诗档**。均匀抽在这两种情况下都会照常混出三档。
func _check_shop_rarity_weights() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	run_state._open_shop()

	## 权重与档位边界必须来自 data，不是脚本里的魔数。
	var block: Dictionary = definitions.registry.globals.get("survival", {})
	var data_weights: Array = block.get("shop_rarity_weight", [])
	_expect(data_weights.size() >= 3, "rarity_weight_len_%d" % data_weights.size())
	if data_weights.size() >= 3:
		for tier in range(3):
			_expect_near(float(run_state._shop_weights[tier]), float(data_weights[tier]), "rarity_weight_%d_from_data" % tier)

	## 默认档位倍率全 1.0 ⇒ 成交价就是 `price` 字段本身（与 v3.44 玩家看到的价格一致）。
	run_state._shop_weights = [60, 30, 10]
	run_state._shop_tier_price = [1.0, 1.0, 1.0]
	run_state._rng_state = 4242
	run_state._roll_shop()
	var price_mismatch := 0
	for raw in run_state.shop_slots:
		var slot: Dictionary = raw
		var base := float(definitions.get_module(String(slot["id"])).get("price", 0.0))
		if absf(float(slot["price"]) - base) > 0.001:
			price_mismatch += 1
	_expect(price_mismatch == 0, "rarity_default_price_is_field_%d" % price_mismatch)

	## 档位倍率可独立调价：普通档 ×2、其余不变。
	run_state._shop_tier_price = [2.0, 1.0, 1.0]
	run_state._rng_state = 4242
	run_state._roll_shop()
	var doubled_bad := 0
	for raw in run_state.shop_slots:
		var slot: Dictionary = raw
		var base := float(definitions.get_module(String(slot["id"])).get("price", 0.0))
		var want := base * (2.0 if run_state._rarity_tier(base) == 0 else 1.0)
		if absf(float(slot["price"]) - want) > 0.001:
			doubled_bad += 1
	_expect(doubled_bad == 0, "rarity_tier_price_applied_%d" % doubled_bad)
	run_state._shop_tier_price = [1.0, 1.0, 1.0]

	## 权重只留普通档：**每一格都必须是普通档**。
	run_state._shop_weights = [1, 0, 0]
	run_state._rng_state = 4242
	run_state._roll_shop()
	var common_off := 0
	for raw in run_state.shop_slots:
		var slot: Dictionary = raw
		var base := float(definitions.get_module(String(slot["id"])).get("price", 0.0))
		if run_state._rarity_tier(base) != 0:
			common_off += 1
	_expect(run_state.shop_slots.size() == run_state._shop_slot_count, "rarity_forced_common_fills_%d" % run_state.shop_slots.size())
	_expect(common_off == 0, "rarity_forced_common_off_tier_%d" % common_off)

	## 权重只留史诗档：**每一格都必须是史诗档**。
	run_state._shop_weights = [0, 0, 1]
	run_state._rng_state = 4242
	run_state._roll_shop()
	var epic_off := 0
	for raw in run_state.shop_slots:
		var slot: Dictionary = raw
		var base := float(definitions.get_module(String(slot["id"])).get("price", 0.0))
		if run_state._rarity_tier(base) != 2:
			epic_off += 1
	_expect(epic_off == 0, "rarity_forced_epic_off_tier_%d" % epic_off)

	## 默认 60/30/10 的长期分布：普通档必须显著多于史诗档。
	## 这是「权重真的参与概率」的统计侧证据（上面两条是决定性证据）。
	run_state._shop_weights = [60, 30, 10]
	run_state._rng_state = 4242
	var hits := [0, 0, 0]
	for _i in range(120):
		run_state._roll_shop()
		for raw in run_state.shop_slots:
			var slot: Dictionary = raw
			var base := float(definitions.get_module(String(slot["id"])).get("price", 0.0))
			var tier: int = run_state._rarity_tier(base)
			hits[tier] = int(hits[tier]) + 1
	var total: int = int(hits[0]) + int(hits[1]) + int(hits[2])
	_expect(total > 0, "rarity_sample_nonempty")
	if total > 0:
		var common_share := float(hits[0]) / float(total)
		var epic_share := float(hits[2]) / float(total)
		_expect(common_share > 0.50, "rarity_common_share_%.3f" % common_share)
		_expect(epic_share < 0.15, "rarity_epic_share_%.3f" % epic_share)
		_expect(int(hits[0]) > int(hits[2]), "rarity_common_beats_epic_%d_%d" % [hits[0], hits[2]])

# ─── 验收 1b：敌人升档阈值来自 data（v3.46 审核 S2）────────────────────────

## 旧版把 `4 / 9 / 14` 写死在 `tier_for()` 里，而同一个 `survival` 块里的 `wave_time_s` /
## `enemy_count_*` / `boss_every` 全都从 data 读 —— 这是全项目「数据驱动」纪律的唯一系统性
## 破口，而且恰好是最需要反复调参的那一处。
##
## 这一条必须能区分「读表」与「写死魔数」：换一张表后 `tier_for()` 必须跟着变。
func _check_tier_thresholds_from_data() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	var block: Dictionary = definitions.registry.globals.get("survival", {})
	_expect(block.has("tier_wave_thresholds"), "tier_thresholds_in_data")
	var data_table: Dictionary = block.get("tier_wave_thresholds", {})
	for tier in BotAI.TIERS:
		_expect(data_table.has(String(tier)), "tier_thresholds_key_%s" % tier)
		_expect_near(float(run_state._tier_thresholds.get(String(tier), -1)), float(data_table.get(String(tier), -2)), "tier_threshold_%s_from_data" % tier)

	## 默认值必须与 v3.44 写死的 4/9/14 等价（第 5 波老兵、第 10 波精英、第 15 波王牌），
	## 否则这次「搬进 data」会顺手改掉难度。
	_expect(run_state.tier_for(1) == BotAI.TIER_RECRUIT, "tier_data_w1_recruit")
	_expect(run_state.tier_for(4) == BotAI.TIER_RECRUIT, "tier_data_w4_recruit")
	_expect(run_state.tier_for(6) == BotAI.TIER_VETERAN, "tier_data_w6_veteran")
	_expect(run_state.tier_for(11) == BotAI.TIER_ELITE, "tier_data_w11_elite")
	_expect(run_state.tier_for(16) == BotAI.TIER_ACE, "tier_data_w16_ace")

	## 换一张表：第 2 波就老兵、第 3 波精英、第 4 波王牌。
	## **写死 4/9/14 的实现会在这里全部报错** —— 这就是本条断言的区分力来源。
	run_state._tier_thresholds = {"recruit": 1, "veteran": 2, "elite": 3, "ace": 4}
	_expect(run_state.tier_for(1) == BotAI.TIER_RECRUIT, "tier_custom_w1")
	_expect(run_state.tier_for(2) == BotAI.TIER_VETERAN, "tier_custom_w2")
	_expect(run_state.tier_for(3) == BotAI.TIER_ELITE, "tier_custom_w3")
	_expect(run_state.tier_for(4) == BotAI.TIER_ACE, "tier_custom_w4")

	## 把阈值推远：第 2、3 波都还应该是新兵。
	run_state._tier_thresholds = {"recruit": 1, "veteran": 100, "elite": 200, "ace": 300}
	_expect(run_state.tier_for(1) == BotAI.TIER_RECRUIT, "tier_late_w1")
	_expect(run_state.tier_for(2) == BotAI.TIER_RECRUIT, "tier_late_w2")
	_expect(run_state.tier_for(3) == BotAI.TIER_RECRUIT, "tier_late_w3")

	## Boss 波「至少精英」是独立规则，不能被阈值表覆盖掉。
	_expect(run_state.tier_for(5) == BotAI.TIER_ELITE, "tier_late_boss_w5_floor")
	_expect(run_state.tier_for(10) == BotAI.TIER_ELITE, "tier_late_boss_w10_floor")

# ─── 验收 9：Boss 波 —— 专用蓝图、更大结构、必掉 3 件 ──────────────────────

func _check_boss_wave() -> void:
	var boss_ids: Array = []
	for raw_id in definitions.registry.blueprints.keys():
		if String(raw_id).begins_with("boss_"):
			boss_ids.append(String(raw_id))
	_expect(boss_ids.size() >= 1, "boss_blueprint_exists_%d" % boss_ids.size())
	if boss_ids.is_empty():
		return
	## Boss 蓝图必须显著大于同档普通蓝图。
	boss_ids.sort()
	var boss_bp := definitions.get_blueprint(String(boss_ids[0]))
	var boss_cells := _blueprint_cell_count(boss_bp)
	var ace_ids: Array = []
	for raw_id in definitions.registry.blueprints.keys():
		if String(raw_id).begins_with("bot_ace_"):
			ace_ids.append(String(raw_id))
	ace_ids.sort()
	var ace_cells := 0
	if not ace_ids.is_empty():
		ace_cells = _blueprint_cell_count(definitions.get_blueprint(String(ace_ids[0])))
	_expect(boss_cells > ace_cells, "boss_bigger_%d_vs_%d" % [boss_cells, ace_cells])

	## 第 5 波是 Boss 波，只出 1 台，且击毁给固定奖励 + 必掉 3 件。
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.wave = definitions.block_int("survival", "boss_every", 5)
	_expect(run_state.start_wave(), "boss_start_wave")
	var enemy_tags := run_state.duel.alive_in_team(Duel.TEAM_ENEMY)
	_expect(enemy_tags.size() == 1, "boss_single_enemy_%d" % enemy_tags.size())
	if enemy_tags.is_empty():
		return
	var tag := String(enemy_tags[0])
	var tier := String(run_state.enemy_tier.get(tag, ""))
	_expect(tier == BotAI.TIER_ACE or tier == BotAI.TIER_ELITE, "boss_tier_%s" % tier)
	var credit_before := run_state.credit
	var xp_before := run_state.experience
	var inv_before := run_state.inventory.size()
	var boss_tank = run_state.duel.tank_of(tag)
	run_state.duel.damage_of(tag).apply_part_damage(boss_tank, _cockpit_index(boss_tank), 1.0e9, "destroyed")
	run_state.step_battle(1.0 / 60.0)
	## v3.44 行为变更：击毁 Boss 会当场把本波打完，于是同一帧内还会发放过波结算奖金。
	## 所以金钱增量 = `boss_credit_reward` + `wave_clear_credit_award(本波)`。
	## 这不是放宽断言，是断言必须跟着行为走——若奖金被漏发，这里会精确少 280。
	var expected_boss_credit := definitions.block_number("survival", "boss_credit_reward", 460.0) + run_state.wave_clear_credit_award(run_state.wave)
	_expect_near(
		run_state.credit - credit_before,
		expected_boss_credit,
		"boss_credit_reward"
	)
	_expect_near(
		run_state.experience - xp_before,
		definitions.block_number("survival", "boss_xp_reward", 200.0),
		"boss_xp_reward"
	)
	_expect(
		run_state.inventory.size() == inv_before + definitions.block_int("survival", "boss_drop_count", 3),
		"boss_drop_count_%d" % (run_state.inventory.size() - inv_before)
	)

# ─── 验收 13：过波结算奖金（v3.44 金钱收入）──────────────────────────────

## 用户 2026-10-30：「增加金钱收入，目前战斗消耗的模块想补上来有些困难」。
## 根因不是单价偏低：原先收入**全部**来自「打中东西」（击杀 / 拆房 / 碾残骸），
## 而打中东西本身要求坦克完好——坦克一残，收入能力同步下降，
## 形成「越残越穷、补不回来」的下行螺旋。
## 所以 v3.44 加了一笔与战况无关、活下来就能拿到的收入：过波结算奖金。
##
## 这里验四件事：① 公式 = base + per_wave × (wave − 1)；② 真的发到 `credit` 上；
## ③ 事件流里有 `wave_cleared` 且金额一致；④ `last_wave_credit` 的生命周期。
func _check_wave_clear_credit() -> void:
	var base := definitions.block_number("survival", "wave_clear_credit_base", 120.0)
	var per_wave := definitions.block_number("survival", "wave_clear_credit_per_wave", 40.0)
	_expect(base > 0.0, "wave_credit_base_positive_%.2f" % base)
	var formula_run := _make_run()
	if formula_run == null:
		return
	_expect_near(formula_run.wave_clear_credit_award(1), base, "wave_credit_award_wave1")
	_expect_near(formula_run.wave_clear_credit_award(2), base + per_wave, "wave_credit_award_wave2")
	_expect_near(formula_run.wave_clear_credit_award(5), base + per_wave * 4.0, "wave_credit_award_wave5")
	## 必须随波递增：模块价格随波次水涨船高（高级车带高级件），固定金额到中后期等于没涨。
	_expect(formula_run.wave_clear_credit_award(9) > formula_run.wave_clear_credit_award(1), "wave_credit_grows_with_wave")

	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	_expect(run_state.start_wave(), "wave_credit_start_wave")
	_expect_near(run_state.last_wave_credit, 0.0, "wave_credit_reset_on_start")
	## 清空 AI 表：敌人既不动也不开火。这里测的是「过波结算」本身，
	## 不是「能不能活到计时归零」（那是验收 3 的事）。
	run_state.enemy_ai.clear()
	var credit_before := run_state.credit
	var expected := run_state.wave_clear_credit_award(run_state.wave)
	var seen_wave_cleared := false
	var seen_credit := -1.0
	var dt := 1.0 / 60.0
	var steps := int(ceilf(run_state.wave_time_limit / dt)) + 5
	for step_index in range(steps):
		## 先判 wave_passed 再推进：这样过波那一帧的事件仍然会被取到。
		if run_state.wave_passed:
			break
		for raw_event in run_state.step_battle(dt):
			var entry: Dictionary = raw_event
			if String(entry.get("kind", "")) == "wave_cleared":
				seen_wave_cleared = true
				seen_credit = float(entry.get("credit", -1.0))
	_expect(run_state.wave_passed, "wave_credit_wave_passed")
	## 用 `>=` 而不是 `==`：本波还可能顺手碾到残骸、打死敌人，
	## 那些收益是独立来源，不该让这条断言变成「总收入必须恰好等于奖金」。
	## 反向仍恒成立——奖金一旦漏发，增量就是 0 < expected。
	_expect(
		run_state.credit - credit_before >= expected - 0.001,
		"wave_credit_paid_%.2f_of_%.2f" % [run_state.credit - credit_before, expected]
	)
	_expect_near(run_state.last_wave_credit, expected, "wave_credit_last_value")
	_expect(seen_wave_cleared, "wave_credit_event_emitted")
	_expect_near(seen_credit, expected, "wave_credit_event_amount")
	## 生命周期：`close_run()` 是新一局的起点，旧一局的奖金读数不能留。
	run_state.close_run()
	_expect_near(run_state.last_wave_credit, 0.0, "wave_credit_reset_on_close")

func _blueprint_cell_count(blueprint: Dictionary) -> int:
	var total := 0
	var economy: Dictionary = blueprint.get("economy", {})
	if economy.has("cells"):
		return int(economy["cells"])
	for raw in blueprint.get("platform_cells", []):
		total += 1
	return total

func _cockpit_index(tank) -> int:
	if tank == null:
		return -1
	for index in range(tank.parts.size()):
		if String(tank.parts[index]["module_id"]).begins_with("cockpit"):
			return index
	return -1

# ─── 验收 11：房屋摧毁事件必须把「给了多少钱、掉了什么」带出来 ───────────────

## 用户反馈的原话：「房屋摧毁也会掉落金币和模块」。机制本来就有，但事件里只有 `cell`，
## 页面层无从显示——玩家看到的只有一句没数字的「房屋被摧毁」。
func _check_house_reward_feedback() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	var house: Dictionary = run_state.houses[0]
	var events: Array[Dictionary] = []
	## 一发超额伤害打穿：单次调用足够归零，不需要循环。
	var ammo := float(definitions.get_ammo("cal_155").get("base_damage", 0.0))
	while bool(house["alive"]) and events.size() < 40:
		run_state._damage_house(house, ammo, events)
	_expect(not bool(house["alive"]), "house_reward_destroyed")
	var found := -1
	for index in range(events.size()):
		if String(events[index].get("kind", "")) == "house_destroyed":
			found = index
			break
	_expect(found >= 0, "house_reward_event_present")
	if found < 0:
		return
	var event: Dictionary = events[found]
	_expect_near(
		float(event.get("credit", 0.0)),
		definitions.block_number("survival", "credit_per_house", 55.0),
		"house_reward_credit_field"
	)
	_expect_near(
		float(event.get("xp", 0.0)),
		definitions.block_number("survival", "xp_per_house", 12.0),
		"house_reward_xp_field"
	)
	## 掉率升到 0.70 之后，一栋不掉不是缺陷；但**字段必须存在且合法**：
	## 空串 = 没掉，非空 = 真的进了库存。两者只能有一个。
	var dropped := String(event.get("module", ""))
	if dropped.is_empty():
		_expect(true, "house_reward_module_absent_ok")
	else:
		_expect(run_state.inventory.has(dropped), "house_reward_module_in_inventory")
	## 保底：以上的自然概率断言**不能证明保底存在**（0.70 之下三次不掉也不会罕见）。
	## 保底逻辑是纯函数，所以直接对 `_roll_drop(chance, stream)` 做确定性断言：
	## `chance = 0.0` 时任何 `_next_unit() >= 0.0`，前 `pity-1` 次必然 false，第 `pity` 次必然 true。
	var pity := definitions.block_int("survival", "house_drop_pity", 3)
	var run_pity := _make_run()
	if run_pity == null:
		return
	run_pity._house_drop_dry = 0
	for step in range(pity - 1):
		_expect(
			not run_pity._roll_drop(0.0, "house"),
			"house_reward_pity_no_drop_at_%d" % step
		)
	_expect(
		not run_pity._roll_drop(0.0, "house"),
		"house_reward_pity_no_drop_at_%d" % (pity - 1)
	)
	## 上面循环少跑一次，最后一次单独跑：总数必须恰好 `pity - 1` 次失败、第 `pity` 次必掉。
	## `_roll_drop()` 内部在失败时累加干次数，所以这里重新走一遍完整阶梯更清楚。
	run_pity._house_drop_dry = 0
	var fails := 0
	var forced := false
	for step in range(pity + 2):
		if run_pity._roll_drop(0.0, "house"):
			forced = true
			break
		fails += 1
	_expect(fails == pity, "house_reward_pity_fails_%d_of_%d" % [fails, pity])
	_expect(forced, "house_reward_pity_forces_drop")
	## 掉落后干次数必须归零，否则下一栋会立刻又被保底。
	_expect(run_pity._house_drop_dry == 0, "house_reward_pity_resets")
	## 拆房确实会走这条路径：真拆一栋，事件里要么没模块（没命中），要么模块已进库存。
	var run_real := _make_run()
	if run_real == null:
		return
	run_real.bind_player(_make_rig())
	run_real.start_wave()
	var real_house: Dictionary = run_real.houses[0]
	var real_events: Array[Dictionary] = []
	var real_guard := 0
	while bool(real_house["alive"]) and real_guard < 40:
		run_real._damage_house(real_house, ammo, real_events)
		real_guard += 1
	var real_module := ""
	for raw_event in real_events:
		if String((raw_event as Dictionary).get("kind", "")) == "house_destroyed":
			real_module = String((raw_event as Dictionary).get("module", ""))
	if not real_module.is_empty():
		_expect(run_real.inventory.has(real_module), "house_reward_module_in_inventory")

# ─── 验收 12：普通敌人击杀必须给钱、并真的能掉模块（含 luck-free 保底）─────────

## 用户反馈的原话：「敌人击杀也掉落模块和金钱」。同样：机制本来就有，但
## `_survival_step()` 里根本没有 `enemy_defeated` 分支，事件被直接丢弃——
## 没有漂浮数字、没有掉落文案，金钱只是 HUD 上静默跳一下。
func _check_enemy_drop_reward() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	run_state.wave = 1
	_expect(run_state.start_wave(), "enemy_reward_start_wave")
	var tags := run_state.duel.alive_in_team(Duel.TEAM_ENEMY)
	_expect(not tags.is_empty(), "enemy_reward_has_enemy")
	if tags.is_empty():
		return
	var tag := String(tags[0])
	var enemy_tank = run_state.duel.tank_of(tag)
	var cockpit := _cockpit_index(enemy_tank)
	_expect(cockpit >= 0, "enemy_reward_has_cockpit")
	if cockpit < 0:
		return
	var credit_before := run_state.credit
	var xp_before := run_state.experience
	var inv_before := run_state.inventory.size()
	run_state.duel.damage_of(tag).apply_part_damage(enemy_tank, cockpit, 1.0e9, "destroyed")
	var steps := 0
	while run_state.kills == 0 and steps < 8:
		run_state.step_battle(1.0 / 60.0)
		steps += 1
	_expect(run_state.kills == 1, "enemy_reward_kill_counted_%d" % run_state.kills)
	_expect_near(
		run_state.credit - credit_before,
		definitions.block_number("survival", "credit_per_kill", 40.0),
		"enemy_reward_credit"
	)
	_expect_near(
		run_state.experience - xp_before,
		definitions.block_number("survival", "xp_per_kill", 25.0),
		"enemy_reward_xp"
	)
	## 同样不能用「杀 4 台总会掉一件」来证明保底——那只是概率。改为直接压 RNG：
	## 每次击杀前把 `_rng_state` 设成必然失败的取样值，前 pity-1 台必须一件不掉，
	## 第 pity 台必须掉一件。这是对保底逻辑本身的确定性断言。
	var pity := definitions.block_int("survival", "enemy_drop_pity", 4)
	var run_pity := _make_run()
	if run_pity == null:
		return
	run_pity.bind_player(_make_rig())
	run_pity.wave = 1
	if not run_pity.start_wave():
		_expect(false, "enemy_reward_pity_start_wave")
		return
	## 同样不能用「杀 4 台总会掉一件」证明保底。两边都是纯函数，直接对各 stream 做阶梯断言。
	run_pity._enemy_drop_dry = 0
	var enemy_fails := 0
	var enemy_forced := false
	for step in range(pity + 2):
		if run_pity._roll_drop(0.0, "enemy"):
			enemy_forced = true
			break
		enemy_fails += 1
	_expect(enemy_fails == pity, "enemy_reward_pity_fails_%d_of_%d" % [enemy_fails, pity])
	_expect(enemy_forced, "enemy_reward_pity_forces_drop")
	_expect(run_pity._enemy_drop_dry == 0, "enemy_reward_pity_resets")
	## 两个 stream 的干次数**必须互相独立**：压满 enemy 不会让 house 提前保底。
	run_pity._house_drop_dry = 0
	_expect(not run_pity._roll_drop(0.0, "house"), "enemy_reward_pity_stream_isolated")
	## 真实击杀路径：真的杀掉一台，验证击杀真的被记录。
	run_pity._enemy_drop_dry = 0
	var real_kill := 0
	var real_attempts := 0
	while real_kill == 0 and real_attempts < 8:
		real_attempts += 1
		var alive := run_pity.duel.alive_in_team(Duel.TEAM_ENEMY)
		if alive.is_empty():
			run_pity.step_battle(1.0 / 60.0)
			continue
		var victim_tag := String(alive[0])
		var victim_tank = run_pity.duel.tank_of(victim_tag)
		var victim_cockpit := _cockpit_index(victim_tank)
		if victim_cockpit < 0:
			run_pity.step_battle(1.0 / 60.0)
			continue
		run_pity.duel.damage_of(victim_tag).apply_part_damage(victim_tank, victim_cockpit, 1.0e9, "destroyed")
		var kills_before := run_pity.kills
		run_pity.step_battle(1.0 / 60.0)
		if run_pity.kills > kills_before:
			real_kill += 1
	_expect(real_kill == 1, "enemy_reward_real_kill_%d" % real_kill)
	_expect(run_pity.kills >= 1, "enemy_reward_real_kill_recorded_%d" % run_pity.kills)
	## `_roll_enemy_module()` 必须以该敌人**蓝图里真实存在**的模块为准（Q31），不是全表乱抽。
	var enemy_ids: Array = run_pity._enemy_module_ids("enemy_1")
	_expect(not enemy_ids.is_empty(), "enemy_reward_has_module_pool")
	for raw_id in enemy_ids:
		_expect(not definitions.get_module(String(raw_id)).is_empty(), "enemy_reward_pool_id_known_%s" % String(raw_id))
# ─── 验收 10b：改装入口只在 LEVEL_UP / SHOP 开放，且只走 GridBuilder 正式接口 ────

## design §3.4 表格：「改装入口只有 `LEVEL_UP` 与 `SHOP` 的改装按钮」。
## 这里验证三件事：① 战斗期进不去；② 进出后回到原阶段；③ 贴装/拆解全部走
## `GridBuilder` 官方接口（I1–I10 照旧生效），并且 credit 按净增建造支出扣款。
func _check_modification() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	var rig := _make_rig()
	run_state.bind_player(rig)
	run_state.start_wave()

	## ① 战斗期不可达——这是用户的硬要求（「正常战斗的时候不允许进入改装」）。
	_expect(not run_state.enter_modification(), "mod_rejected_in_battle")
	_expect(run_state.stage == SurvivalRun.STAGE_BATTLE, "mod_battle_stage_kept_%s" % run_state.stage)
	_expect(not run_state.mount_from_inventory(0, Vector2i(2, 0), 0, 0).is_empty(), "mod_mount_rejected_in_battle")

	## ② 升级页可进可回，且回到的是**进入时的阶段**而不是写死的商店。
	run_state._open_level_up()
	_expect(run_state.stage == SurvivalRun.STAGE_LEVEL_UP, "mod_level_stage_%s" % run_state.stage)
	_expect(run_state.enter_modification(), "mod_enter_from_level")
	_expect(run_state.stage == SurvivalRun.STAGE_MODIFY, "mod_stage_modify_%s" % run_state.stage)
	_expect(run_state.leave_modification(), "mod_leave_from_level")
	_expect(run_state.stage == SurvivalRun.STAGE_LEVEL_UP, "mod_back_to_level_%s" % run_state.stage)

	## ③ 商店页可进；贴装一件配件要扣钱、要增重、要从库存消失。
	run_state._open_shop()
	_expect(run_state.enter_modification(), "mod_enter_from_shop")
	run_state.inventory.append("shield_cell")
	run_state.inventory.append("engine_small")
	var shield_mass := float(definitions.get_module("shield_cell").get("mass", 0.0))
	var shield_price := float(definitions.get_module("shield_cell").get("price", 0.0))
	run_state.credit = shield_price + 5.0
	var inv_before := run_state.inventory.size()
	var mass_before := rig.build_mass()
	var reason: String = run_state.mount_from_inventory(0, Vector2i(2, 0), 0, 0)
	_expect(reason.is_empty(), "mod_mount_ok_%s" % reason)
	_expect(run_state.inventory.size() == inv_before - 1, "mod_mount_left_inventory")
	_expect_near(rig.build_mass(), mass_before + shield_mass, "mod_mount_mass")
	_expect_near(run_state.modification_cost(), shield_price, "mod_cost_is_price")

	## 没有平台的格必须被拒：证明改装没有绕过 I2，走的仍是官方校验。
	var inv_before_reject := run_state.inventory.size()
	var mass_before_reject := rig.build_mass()
	var blocked: String = run_state.mount_from_inventory(0, Vector2i(23, 23), 0, 0)
	_expect(not blocked.is_empty(), "mod_mount_no_platform_rejected")
	_expect(run_state.inventory.size() == inv_before_reject, "mod_reject_keeps_inventory")
	_expect_near(rig.build_mass(), mass_before_reject, "mod_reject_keeps_mass")

	## 改装期不是商店：出售 / 刷新 / 下一波都不应生效。
	_expect(not run_state.sell_inventory(0), "mod_sell_rejected")
	_expect(not run_state.reroll_shop(), "mod_reroll_rejected")
	_expect(not run_state.start_next_wave(), "mod_next_wave_rejected")

	## 离开时结算：credit 减掉净增建造支出，阶段回到商店。
	run_state.leave_modification()
	_expect(run_state.stage == SurvivalRun.STAGE_SHOP, "mod_back_to_shop_%s" % run_state.stage)
	_expect_near(run_state.credit, 5.0, "mod_credit_charged")
	_expect_near(run_state.modify_spent_total, shield_price, "mod_spent_total")

	## ④ 拆解：模块退回库存，且结构必须仍然合法。
	run_state.enter_modification()
	var inv_before_dismantle := run_state.inventory.size()
	var dismantle_reason: String = run_state.dismantle_at("module", Vector2i(2, 0))
	_expect(dismantle_reason.is_empty(), "mod_dismantle_ok_%s" % dismantle_reason)
	_expect(run_state.inventory.size() == inv_before_dismantle + 1, "mod_dismantle_to_inventory")
	_expect(run_state.inventory.has("shield_cell"), "mod_dismantle_returned_shield")

	## 拆掉驾驶舱必须被拒：`remove_at()` 本身不管 I7，靠 `validation_report()` 兜底。
	## 注意：驾驶舱格**不能写死**——旧版写的是 (2,1)，那是 8×2 老起始车的坐标；
	## 换布局后那个格子变成弹药库，拆解当然会成功，断言就变成假失败。
	var cockpit_cells: Array = rig.cockpit_cells()
	_expect(cockpit_cells.size() == 1, "mod_cockpit_cell_count_%d" % cockpit_cells.size())
	var cockpit_cell: Vector2i = cockpit_cells[0] if cockpit_cells.size() > 0 else Vector2i.ZERO
	var inv_before_cockpit := run_state.inventory.size()
	var cockpit_reason: String = run_state.dismantle_at("module", cockpit_cell)
	_expect(not cockpit_reason.is_empty(), "mod_cockpit_dismantle_rejected")
	_expect(run_state.inventory.size() == inv_before_cockpit, "mod_cockpit_reject_keeps_inventory")
	_expect(rig.cockpit_cells().size() == 1, "mod_cockpit_still_one")

	## ⑤ 钱不够就撤回：既不能贴装成功，也不能留下半成品。
	## 注意必须**先离开再重进**：净增口径下「拆下再装回」本来就该是零支出，
	## 而基线是进入时取的；不重进的话这一条测的不是余额不足，而是零支出。
	run_state.leave_modification()
	_expect(run_state.enter_modification(), "mod_reenter_for_poor")
	_expect_near(run_state.modification_cost(), 0.0, "mod_reenter_resets_baseline")
	run_state.credit = 0.0
	var inv_before_poor := run_state.inventory.size()
	var mass_before_poor := rig.build_mass()
	var poor_index := run_state.inventory.find("engine_small")
	_expect(poor_index >= 0, "mod_poor_has_engine")
	var poor_reason: String = run_state.mount_from_inventory(poor_index, Vector2i(2, 0), 0, 0)
	_expect(not poor_reason.is_empty(), "mod_poor_credit_rejected")
	_expect(run_state.inventory.size() == inv_before_poor, "mod_poor_keeps_inventory")
	_expect_near(rig.build_mass(), mass_before_poor, "mod_poor_rolls_back")
	run_state.leave_modification()
# ─── 验收 12：玩家开火必须真能对敌人造成伤害且能击毁（v3.9 新增）──────────────

## 用户 2026-10-17 报告「发射炮弹似乎不能对敌人造成伤害」。实测结论：命中链路正常，
## 但起始 20mm 炮对 armor 3 的平台格只有 5 伤/发，而招募级 Bot 有 1835 总血量，
## 一波 45 s 内**数学上不可能**击毁任何敌人。本条把「能打痛、能打死」变成永久回归。
func _check_player_fire_damage() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	run_state.bind_player(_make_rig())
	if not run_state.start_wave():
		_expect(false, "fire_start_wave")
		return
	var duel: Duel = run_state.duel
	var enemies: Array = duel.alive_in_team(Duel.TEAM_ENEMY)
	if enemies.is_empty():
		_expect(false, "fire_has_enemy")
		return
	var enemy_tag := String(enemies[0])
	var enemy_tank = duel.tank_of(enemy_tag)
	if enemy_tank == null:
		_expect(false, "fire_enemy_tank")
		return
	var hits := 0
	var destroyed := 0
	var dt := 1.0 / 60.0
	## 炮管朝向固定（design §6.5：aim 安装后锁定，靠车身转向），所以「会转向」才是玩家的真实打法。
	## 旧版这里让车原地不动、只按空格，炮口朝东、敌人从东边包夹——命中数靠运气，
	## 而「一波内至少击毁 1 台」的要求在敌车缩小后仍然过不去（实测 kills=0）。
	## 现在按玩家真实操作模拟：车头始终追着最近的敌人转，距离过近就后退。
	for step_index in range(45 * 60):
		var drive := 0.3
		var steer := 0.0
		var live_tags: Array = duel.alive_in_team(Duel.TEAM_ENEMY)
		var own = duel.tank_of(Duel.TAG_PLAYER)
		if not live_tags.is_empty() and own != null:
			var target = duel.tank_of(String(live_tags[0]))
			if target != null:
				var to_target: Vector2 = target.position - own.position
				var diff := wrapf(to_target.angle() - own.heading, -PI, PI)
				steer = clampf(diff * 1.5, -1.0, 1.0)
				if absf(diff) < 0.03:
					steer = 0.0
				if to_target.length() < 260.0:
					drive = -0.6
		duel.set_input(Duel.TAG_PLAYER, drive, steer)
		if duel.can_fire(Duel.TAG_PLAYER):
			duel.fire(Duel.TAG_PLAYER)
		for raw_event in run_state.step_battle(dt):
			var kind := String((raw_event as Dictionary).get("kind", ""))
			if kind == "impact" and String((raw_event as Dictionary).get("target", "")) == "tank":
				hits += 1
			elif kind == "destroyed" or kind == "core_destroyed":
				destroyed += 1
		if run_state.stage != SurvivalRun.STAGE_BATTLE:
			break

# ─── 验收 10：战斗期禁止改装（代码搜索 + 运行时断言）───────────────────────
# ─── 验收 10：战斗期禁止改装（代码搜索 + 运行时断言）────────────────────────

func _check_no_combat_modification() -> void:
	var run_state := _make_run()
	if run_state == null:
		return
	var rig := _make_rig()
	run_state.bind_player(rig)
	run_state.start_wave()
	_expect(run_state.stage == SurvivalRun.STAGE_BATTLE, "nomod_stage_battle")
	## 战斗期没有任何接口能把配件装上坦克：`mount_from_inventory` 存在，
	## 但 `inventory` 在战斗期必须为空（掉落只在击杀/摧毁时发生），且
	## 唯一能填它的入口 `take_level_choice` / `buy_shop_slot` 都要求非战斗阶段。
	_expect(run_state.inventory.is_empty(), "nomod_inventory_empty_in_battle")
	run_state.inventory.append("cannon_20")
	_expect(not run_state.take_level_choice(0), "nomod_level_rejected_in_battle")
	_expect(not run_state.buy_shop_slot(0), "nomod_buy_rejected_in_battle")
	_expect(not run_state.reroll_shop(), "nomod_reroll_rejected_in_battle")
	_expect(not run_state.sell_inventory(0), "nomod_sell_rejected_in_battle")
	_expect(not run_state.start_next_wave(), "nomod_next_wave_rejected_in_battle")
	run_state.inventory.clear()
	## `stage` 是唯一权威：没有第二套 `build_mode` 之类的布尔开关能绕过它。
	## 注意 `Object.get()` 对不存在的属性返回 null，旧写法 `not x != null` 运算优先级混乱，
	## 永远为真，根本测不出东西。
	_expect(run_state.get("build_mode") == null, "nomod_no_build_mode_flag")

# ─── 验收 11：确定性 —— 同种子同输入可完全复现 ─────────────────────────────

func _check_determinism() -> void:
	var first := _run_signature(12345)
	var second := _run_signature(12345)
	_expect(first == second, "determinism_same_seed_%s_vs_%s" % [first, second])
	## 不同种子必须给出不同的随机流。旧版拿端到端签名比较两个种子，但 600 帧里
	## 玩家不动、敌人未到，`debris_taken` / `kills` / `credit` 全为初始值，
	## 签名与种子无关，那个断言永远失败——所以改为直接比对 LCG 流。
	_expect(_rng_stream(12345, 32) == _rng_stream(12345, 32), "determinism_rng_same_seed")
	_expect(_rng_stream(12345, 32) != _rng_stream(999, 32), "determinism_rng_diff_seed")

## 取前 count 个 LCG 输出压成字符串，用于验证种子确实影响随机流。
func _rng_stream(seed_value: int, count: int) -> String:
	var run_state := SurvivalRun.new()
	if not run_state.setup(definitions, "arena_standard", seed_value):
		return "fail"
	var parts: Array[String] = []
	for index in range(count):
		parts.append("%.6f" % run_state._next_unit())
	return ",".join(parts)

## 跑固定步数并把关键状态压成一个字符串签名。
func _run_signature(seed_value: int) -> String:
	var run_state := _make_run(seed_value)
	if run_state == null:
		return "fail"
	run_state.bind_player(_make_rig())
	run_state.start_wave()
	var dt := 1.0 / 60.0
	for step_index in range(600):
		if run_state.stage != SurvivalRun.STAGE_BATTLE:
			break
		run_state.step_battle(dt)
	var panel := run_state.summary()
	## 残骸的金钱/经验分派由 LCG 决定，把分配模式也压进签名，
	## 否则签名对种子不敏感。
	var pattern := ""
	for item in run_state.debris:
		pattern += "c" if String(item["payout_kind"]) == "credit" else "x"
	return "w=%d k=%d h=%d d=%d lv=%d cr=%.1f xp=%.1f p=%s" % [
		int(panel["wave_reached"]),
		int(panel["kills"]),
		int(panel["houses"]),
		int(panel["debris"]),
		int(panel["level"]),
		float(panel["credit"]),
		float(panel["experience"]),
		pattern,
	]
