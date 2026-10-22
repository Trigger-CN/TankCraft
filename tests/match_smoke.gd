extends SceneTree

## M6 冒烟：双坦克对局 + 状态机 + AI（roadmap M6 验收 1–10 的逻辑层）。
## 不渲染、不读截图；断言值全部来自 data/*.json。
## 注意：`match` 是 GDScript 保留字，本文件的 MatchState 实例统一命名为 session。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const Duel := preload("res://scripts/duel.gd")
const MatchState := preload("res://scripts/match_state.gd")
const BotAI := preload("res://scripts/bot_ai.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("MATCH_DATA_FAILED")
		quit(1)
		return
	_check_bot_blueprints()
	_check_duel_setup()
	_check_damage_attribution()
	_check_defeat_ends_match()
	_check_timeout_compares_damage()
	_check_pause_freezes_timer()
	_check_ai_tiers()
	_check_ai_neck_analysis()
	_check_ai_determinism()
	_check_multi_side()
	_check_multi_side_friendly_fire()
	_check_multi_side_team_damage()
	_check_full_match()
	if failures > 0:
		printerr("MATCH_FAIL count=%d" % failures)
		quit(1)
		return
	print("MATCH_OK")
	quit(0)

func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("MATCH_FAIL %s" % tag)

func _expect_near(value: float, expected: float, tag: String) -> void:
	_expect(absf(value - expected) <= 0.001, "%s %.4f != %.4f" % [tag, value, expected])

## 蓝图池：每档 ≥ 3 张，且每张都能被真实 GridBuilder 读入并通过校验（roadmap M6 交付物）。
func _check_bot_blueprints() -> void:
	for tier in BotAI.TIERS:
		var count := 0
		for blueprint_id in definitions.registry.blueprints.keys():
			if not String(blueprint_id).begins_with("bot_%s_" % tier):
				continue
			var data := definitions.get_blueprint(String(blueprint_id))
			_expect(not data.is_empty(), "blueprint_missing_%s" % blueprint_id)
			var builder := GridBuilder.new()
			if not builder.setup(definitions):
				return
			builder.budget_enabled = false
			builder.credits_total = 1000000
			var reason := builder.load_blueprint(data)
			_expect(reason.is_empty(), "blueprint_load_%s %s" % [blueprint_id, reason])
			if not reason.is_empty():
				continue
			var report := builder.validation_report()
			_expect(bool(report["ok"]), "blueprint_valid_%s" % blueprint_id)
			count += 1
		_expect(count >= 3, "blueprint_tier_%s_%d" % [tier, count])

## 建造一个最小合法船体：平台 + 履带 + 驾驶舱 + 引擎 + 工厂/直管/炮管供弹链。
func _make_rig() -> GridBuilder:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for y in range(2):
		for x in range(6):
			var reason := builder.place_platform_cell(Vector2i(x, y))
			if not reason.is_empty():
				printerr("MATCH_PLATFORM_FAILED %d,%d %s" % [x, y, reason])
				failures += 1
				return builder
	builder.place_mobility("track_light", Vector2i(0, 0), 0)
	builder.place_module("cockpit_light", Vector2i(2, 1), 0, 0)
	builder.place_module("engine_small", Vector2i(1, 1), 0, 0)
	builder.place_module("ammo_factory_20", Vector2i(3, 0), 0, 0)
	builder.place_module("conveyor_straight", Vector2i(4, 0), 0, 0)
	builder.place_module("cannon_20", Vector2i(5, 0), 0, 0)
	return builder

func _check_duel_setup() -> void:
	var duel := Duel.new()
	_expect(duel.setup(definitions), "duel_setup")
	duel.load_arena("arena_standard")
	_expect(duel.arena.size.x > 0.0 and duel.arena.size.y > 0.0, "duel_arena")
	var player := _make_rig()
	var enemy := _make_rig()
	var player_spawn := duel.spawn_point("arena_standard", 0)
	var enemy_spawn := duel.spawn_point("arena_standard", 1)
	_expect(duel.add_side(Duel.TAG_PLAYER, player, player_spawn["pos"], player_spawn["rot"]), "duel_add_player")
	_expect(duel.add_side(Duel.TAG_ENEMY, enemy, enemy_spawn["pos"], enemy_spawn["rot"]), "duel_add_enemy")
	_expect(duel.tank_of(Duel.TAG_PLAYER) != null, "duel_tank_player")
	_expect(duel.tank_of(Duel.TAG_ENEMY) != null, "duel_tank_enemy")
	var summary := duel.structure_summary(Duel.TAG_PLAYER)
	_expect(int(summary["parts"]) > 0, "duel_parts")
	_expect(not duel.defeated(Duel.TAG_PLAYER), "duel_player_alive")
	_expect(not duel.defeated(Duel.TAG_ENEMY), "duel_enemy_alive")
	var p := duel.tank_of(Duel.TAG_PLAYER).position
	var e := duel.tank_of(Duel.TAG_ENEMY).position
	_expect(p.x < e.x, "duel_spawn_sides %.1f %.1f" % [p.x, e.x])

## 弹道命中必须记在射手头上（design §3.3 超时判定比「已造成伤害」）。
func _check_damage_attribution() -> void:
	var duel := Duel.new()
	duel.setup(definitions)
	duel.load_arena("arena_standard")
	duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	duel.field.spawn(Vector2(360.0, 400.0), Vector2.RIGHT, "cal_20", Duel.TAG_PLAYER, [])
	for step_index in range(240):
		duel.step(1.0 / 60.0)
		if float(duel.damage_dealt[Duel.TAG_PLAYER]) > 0.0:
			break
	_expect(float(duel.damage_dealt[Duel.TAG_PLAYER]) > 0.0, "attribution_player_dealt")
	_expect_near(float(duel.damage_dealt[Duel.TAG_ENEMY]), 0.0, "attribution_enemy_dealt_zero")

## 驾驶舱被毁 → 同一帧 RESULT，且不再推进（roadmap M6 验收 8 的对战侧语义）。
func _check_defeat_ends_match() -> void:
	var session := MatchState.new()
	_expect(session.setup(definitions, "arena_standard"), "defeat_setup")
	session.duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	session.duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	_expect(session.enter_deploy(), "defeat_deploy")
	_expect(session.enter_battle(), "defeat_battle")
	_expect(session.phase == MatchState.PHASE_BATTLE, "defeat_phase_battle")
	var enemy_tank := session.duel.tank_of(Duel.TAG_ENEMY)
	var enemy_damage := session.duel.damage_of(Duel.TAG_ENEMY)
	var core_index := _core_index(enemy_tank)
	_expect(core_index >= 0, "defeat_core_found")
	enemy_damage.apply_part_damage(enemy_tank, core_index, 1.0e9, "destroyed")
	session.step(1.0 / 60.0)
	_expect(session.phase == MatchState.PHASE_RESULT, "defeat_result_phase")
	_expect(session.outcome == MatchState.OUTCOME_PLAYER, "defeat_outcome_player")
	_expect(session.player_won(), "defeat_player_won")
	session.step(1.0)
	_expect(session.phase == MatchState.PHASE_RESULT, "defeat_stays_result")
	_expect(session.outcome == MatchState.OUTCOME_PLAYER, "defeat_outcome_stable")

func _core_index(tank: TankBody) -> int:
	for index in range(tank.parts.size()):
		var module_id := String(tank.parts[index]["module_id"])
		if bool(definitions.get_module(module_id).get("core", false)):
			return index
	return -1

## 超时比已造成伤害：玩家伤害更高 → 超时判玩家胜（design §3.3）。
func _check_timeout_compares_damage() -> void:
	var session := MatchState.new()
	session.setup(definitions, "arena_standard")
	session.duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	session.duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	session.enter_deploy()
	session.enter_battle()
	session.duel.damage_dealt[Duel.TAG_PLAYER] = 123.0
	session.duel.damage_dealt[Duel.TAG_ENEMY] = 45.0
	session.battle_time_left = 0.05
	session.step(0.1)
	_expect(session.phase == MatchState.PHASE_RESULT, "timeout_result_phase")
	_expect(session.outcome == MatchState.OUTCOME_TIMEOUT_PLAYER, "timeout_player_wins")
	var draw := MatchState.new()
	draw.setup(definitions, "arena_standard")
	draw.duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	draw.duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	draw.enter_deploy()
	draw.enter_battle()
	draw.duel.damage_dealt[Duel.TAG_PLAYER] = 10.0
	draw.duel.damage_dealt[Duel.TAG_ENEMY] = 10.0
	draw.battle_time_left = 0.05
	draw.step(0.1)
	_expect(draw.outcome == MatchState.OUTCOME_DRAW, "timeout_draw")

## roadmap M6 验收 13：暂停冻结对局计时器，且不推进战斗。
func _check_pause_freezes_timer() -> void:
	var session := MatchState.new()
	session.setup(definitions, "arena_standard")
	session.duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	session.duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	session.enter_deploy()
	session.enter_battle()
	var before := session.battle_time_left
	session.toggle_pause()
	_expect(session.paused, "pause_on")
	session.step(0.5)
	_expect_near(session.battle_time_left, before, "pause_timer_frozen")
	_expect_near(session.paused_time, 0.5, "pause_accumulated")
	session.toggle_pause()
	_expect(not session.paused, "pause_off")
	session.step(0.5)
	_expect(session.battle_time_left < before, "pause_resume_counts_down")

## 四档难度的反应延迟与瞄准误差必须与 data 一致，且难度确实递增（roadmap M6 验收 2/3）。
func _check_ai_tiers() -> void:
	var previous_reaction := 1.0e9
	var previous_error := 1.0e9
	for tier in BotAI.TIERS:
		var ai := BotAI.new()
		_expect(ai.setup(definitions, tier, 7), "ai_setup_%s" % tier)
		var expected_ms := definitions.block_number("ai", "reaction_ms_%s" % tier, 0.0)
		var expected_deg := definitions.block_number("ai", "aim_error_deg_%s" % tier, 0.0)
		_expect_near(ai._reaction_s * 1000.0, expected_ms, "ai_reaction_%s" % tier)
		_expect_near(ai._aim_error_deg, expected_deg, "ai_error_%s" % tier)
		_expect(ai._reaction_s < previous_reaction, "ai_reaction_monotonic_%s" % tier)
		_expect(ai._aim_error_deg < previous_error, "ai_error_monotonic_%s" % tier)
		previous_reaction = ai._reaction_s
		previous_error = ai._aim_error_deg
	var recruit := BotAI.new()
	recruit.setup(definitions, BotAI.TIER_RECRUIT, 1)
	_expect(not recruit.uses_structure_analysis, "ai_recruit_no_structure")
	var veteran := BotAI.new()
	veteran.setup(definitions, BotAI.TIER_VETERAN, 1)
	_expect(not veteran.uses_structure_analysis, "ai_veteran_no_structure")
	var elite := BotAI.new()
	elite.setup(definitions, BotAI.TIER_ELITE, 1)
	_expect(elite.uses_structure_analysis, "ai_elite_structure")
	var ace := BotAI.new()
	ace.setup(definitions, BotAI.TIER_ACE, 1)
	_expect(ace.uses_structure_analysis, "ai_ace_structure")

## 精英 AI 必须真的找到窄颈（roadmap M6 验收 2：难度差异体现在结构分析）。
func _check_ai_neck_analysis() -> void:
	var duel := Duel.new()
	duel.setup(definitions)
	duel.load_arena("arena_standard")
	var builder := GridBuilder.new()
	builder.setup(definitions)
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for cell in [Vector2i(4, 4), Vector2i(5, 4), Vector2i(4, 5), Vector2i(5, 5), Vector2i(6, 4), Vector2i(7, 4), Vector2i(8, 4), Vector2i(7, 5), Vector2i(8, 5)]:
		builder.place_platform_cell(cell)
	builder.place_module("cockpit_light", Vector2i(4, 4), 0, 0)
	builder.place_module("engine_small", Vector2i(7, 4), 0, 0)
	duel.add_side(Duel.TAG_ENEMY, builder, Vector2(700.0, 400.0), PI)
	duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	var elite := BotAI.new()
	elite.setup(definitions, BotAI.TIER_ELITE, 3)
	var neck := elite._find_neck(duel, Duel.TAG_ENEMY)
	_expect(not neck.is_empty(), "ai_neck_found")
	if neck.is_empty():
		return
	var cell := Vector2i(neck["cell"])
	_expect(builder.platform_cells.has(cell), "ai_neck_is_platform")
	# 该格必须是真割点：拿掉后无法从驾驶舱到达远块 (8,4)。
	_expect(not (cell == Vector2i(4, 4) or cell == Vector2i(7, 4) or cell == Vector2i(8, 4)), "ai_neck_not_endpoint_%s" % str(cell))
	var beyond := Vector2i(8, 4)
	_expect(not _reachable(builder, beyond, cell), "ai_neck_blocks_route_%s" % str(cell))
	_expect(_reachable(builder, beyond, Vector2i(0, 0)), "ai_neck_baseline_reachable")

## 屏蔽 blocked 后，target 是否仍能从驾驶舱 4-连通到。
func _reachable(builder: GridBuilder, target: Vector2i, blocked: Vector2i) -> bool:
	var occupancy: Dictionary = builder.platform_occupancy()
	if not occupancy.has(target) or target == blocked:
		return false
	var seen := {}
	var queue: Array[Vector2i] = []
	var neighbours := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]
	for raw_anchor in builder.cockpit_cells():
		var anchor := Vector2i(raw_anchor)
		if anchor == blocked or seen.has(anchor):
			continue
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
	return seen.has(target)

## 同种子两次运行必须给出完全相同的决策序列（roadmap M6 验收 4）。
func _check_ai_determinism() -> void:
	var first := _run_ai_sequence(11)
	var second := _run_ai_sequence(11)
	_expect(first == second, "ai_determinism")
	var other := _run_ai_sequence(12)
	_expect(first != other, "ai_seed_matters")

func _run_ai_sequence(seed_value: int) -> String:
	var duel := Duel.new()
	duel.setup(definitions)
	duel.load_arena("arena_standard")
	duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	var ai := BotAI.new()
	ai.setup(definitions, BotAI.TIER_VETERAN, seed_value)
	var trace := ""
	for step_index in range(120):
		ai.think(1.0 / 60.0, duel)
		if step_index % 30 == 0:
			trace += "%.3f,%.3f,%s;" % [ai.throttle, ai.steer, "1" if ai.want_fire else "0"]
	return trace

## 完整跑一局：AI 对 AI，必有结果且不卡死（roadmap M6 验收 1 的逻辑层）。
func _check_full_match() -> void:
	var session := MatchState.new()
	_expect(session.setup(definitions, "arena_standard"), "full_setup")
	session.duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	session.duel.add_side(Duel.TAG_ENEMY, _make_rig(), Vector2(700.0, 400.0), PI)
	session.enter_deploy()
	session.step(MatchState.DEPLOY_COUNTDOWN_S + 0.1)
	_expect(session.phase == MatchState.PHASE_BATTLE, "full_auto_battle")
	var ai := BotAI.new()
	ai.setup(definitions, BotAI.TIER_VETERAN, 5)
	session.duel.damage_dealt[Duel.TAG_PLAYER] = 500.0
	var steps := 0
	while not session.is_over() and steps < 20000:
		var decision := ai.think(1.0 / 60.0, session.duel)
		session.duel.set_input(Duel.TAG_ENEMY, float(decision["throttle"]), float(decision["steer"]))
		if bool(decision["fire"]):
			session.duel.fire(Duel.TAG_ENEMY)
		session.step(1.0 / 60.0)
		steps += 1
	_expect(session.is_over(), "full_match_over_%d" % steps)
	var panel := session.result_panel()
	_expect(not String(panel["outcome"]).is_empty(), "full_panel_outcome")
	_expect(float(panel["player_damage"]) > 0.0, "full_panel_damage")
	print("MATCH_RUN steps=%d outcome=%s player_dmg=%.1f enemy_dmg=%.1f player_parts=%d enemy_parts=%d" % [
		steps,
		String(panel["outcome"]),
		float(panel["player_damage"]),
		float(panel["enemy_damage"]),
		int(panel["player_parts"]),
		int(panel["enemy_parts"]),
	])

# ─── R18：多侧（多敌人同屏）─────────────────────────────────────────────

## 三个侧同屏：1 个玩家 + 2 个敌人（tag 各自独立、team 同为 enemy）。
## 验证：三方都能加入、step 不报错、存活集合与敌对集合正确、确定性不变。
func _check_multi_side() -> void:
	var duel := Duel.new()
	_expect(duel.setup(definitions), "multi_setup")
	duel.load_arena("arena_standard")
	_expect(duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0), "multi_add_player")
	_expect(duel.add_side("enemy_a", _make_rig(), Vector2(700.0, 400.0), PI), "multi_add_enemy_a")
	_expect(duel.add_side("enemy_b", _make_rig(), Vector2(900.0, 600.0), PI), "multi_add_enemy_b")
	_expect(duel.sides.size() == 3, "multi_side_count_%d" % duel.sides.size())
	_expect(duel.team_of("enemy_a") == Duel.TEAM_ENEMY, "multi_team_a")
	_expect(duel.team_of("enemy_b") == Duel.TEAM_ENEMY, "multi_team_b")
	_expect(duel.team_of(Duel.TAG_PLAYER) == Duel.TEAM_PLAYER, "multi_team_player")
	## 敌对集合：玩家看到 2 个敌人；敌人只看到玩家（同队不算敌对）。
	_expect(duel.hostiles_of(Duel.TAG_PLAYER).size() == 2, "multi_hostiles_player")
	_expect(duel.hostiles_of("enemy_a").size() == 1, "multi_hostiles_enemy_a")
	_expect(duel.hostiles_of("enemy_a")[0] == Duel.TAG_PLAYER, "multi_hostiles_enemy_a_target")
	## 重复 tag 必须被拒，否则会静默覆盖一侧。
	_expect(not duel.add_side("enemy_a", _make_rig(), Vector2(100.0, 100.0), 0.0), "multi_reject_duplicate_tag")
	_expect(duel.sides.size() == 3, "multi_side_count_after_dup_%d" % duel.sides.size())
	## 三方同时 step 不应报错，且时间推进。
	for step_index in range(120):
		duel.step(1.0 / 60.0)
	_expect(duel.time > 1.9, "multi_time_%.3f" % duel.time)
	_expect(duel.alive_in_team(Duel.TEAM_ENEMY).size() == 2, "multi_alive_enemies")
	_expect(not duel.team_defeated(Duel.TEAM_ENEMY), "multi_enemy_team_alive")
	_expect(not duel.team_defeated(Duel.TEAM_PLAYER), "multi_player_team_alive")
	## 空队不是“已阵亡”——否则波次一开始就会误判胜利。
	_expect(not duel.team_defeated("nonexistent"), "multi_empty_team_not_defeated")

## R18：同队之间不得互相造成伤害（弹道按 team 过滤），但物理碰撞仍然生效。
func _check_multi_side_friendly_fire() -> void:
	var duel := Duel.new()
	duel.setup(definitions)
	duel.load_arena("arena_standard")
	duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	duel.add_side("enemy_a", _make_rig(), Vector2(700.0, 400.0), PI)
	duel.add_side("enemy_b", _make_rig(), Vector2(900.0, 400.0), PI)
	## enemy_a 朝 enemy_b 方向开一发：必须穿过同队目标，不得造成任何伤害。
	duel.field.spawn(Vector2(660.0, 400.0), Vector2.RIGHT, "cal_20", "enemy_a", [], 1.0, Duel.TEAM_ENEMY)
	for step_index in range(240):
		duel.step(1.0 / 60.0)
	_expect_near(float(duel.damage_dealt.get("enemy_a", 0.0)), 0.0, "friendly_fire_no_damage")
	_expect_near(float(duel.team_damage(Duel.TEAM_ENEMY)), 0.0, "friendly_fire_team_total")
	## 反向对照：同一位置改由玩家发射，必须命中 enemy_b 并把伤害记在玩家队上。
	var duel2 := Duel.new()
	duel2.setup(definitions)
	duel2.load_arena("arena_standard")
	duel2.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	duel2.add_side("enemy_a", _make_rig(), Vector2(700.0, 400.0), PI)
	duel2.add_side("enemy_b", _make_rig(), Vector2(900.0, 400.0), PI)
	duel2.field.spawn(Vector2(660.0, 400.0), Vector2.RIGHT, "cal_20", Duel.TAG_PLAYER, [], 1.0, Duel.TEAM_PLAYER)
	for step_index in range(240):
		duel2.step(1.0 / 60.0)
		if float(duel2.damage_dealt.get(Duel.TAG_PLAYER, 0.0)) > 0.0:
			break
	_expect(float(duel2.damage_dealt.get(Duel.TAG_PLAYER, 0.0)) > 0.0, "friendly_fire_control_hit")

## R18：伤害归因与队总和。两个敌人各自命中时，队总伤害必须等于两者之和。
## 装置：玩家船体高 2 格（32 px，y 约 384..416），两发都沿 y≈400 向左飞，
## 分别归因到 enemy_a 与 enemy_b。enemy_b 摆在远处以免与 enemy_a 物理重叠。
func _check_multi_side_team_damage() -> void:
	var duel := Duel.new()
	duel.setup(definitions)
	duel.load_arena("arena_standard")
	duel.add_side(Duel.TAG_PLAYER, _make_rig(), Vector2(300.0, 400.0), 0.0)
	duel.add_side("enemy_a", _make_rig(), Vector2(700.0, 400.0), PI)
	duel.add_side("enemy_b", _make_rig(), Vector2(700.0, 700.0), PI)
	duel.field.spawn(Vector2(660.0, 394.0), Vector2.LEFT, "cal_20", "enemy_a", [], 1.0, Duel.TEAM_ENEMY)
	duel.field.spawn(Vector2(660.0, 406.0), Vector2.LEFT, "cal_20", "enemy_b", [], 1.0, Duel.TEAM_ENEMY)
	for step_index in range(300):
		duel.step(1.0 / 60.0)
	var a_dealt := float(duel.damage_dealt.get("enemy_a", 0.0))
	var b_dealt := float(duel.damage_dealt.get("enemy_b", 0.0))
	_expect(a_dealt > 0.0 and b_dealt > 0.0, "team_damage_both_hit a=%.2f b=%.2f" % [a_dealt, b_dealt])
	_expect_near(duel.team_damage(Duel.TEAM_ENEMY), a_dealt + b_dealt, "team_damage_sum")
	## 玩家队只该拿到 0（这两个敌人没有互相打）。
	_expect_near(duel.team_damage(Duel.TEAM_PLAYER), 0.0, "team_damage_player_zero")

