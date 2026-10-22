extends SceneTree

## M6 远征冒烟：5 层 × 3 波推进、坦克跨层连续、INTERMISSION、升级三选一、scrap 经济
## （roadmap M6 验收 7–11 的逻辑层）。断言值全部来自 data/*.json。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const Duel := preload("res://scripts/duel.gd")
const MatchState := preload("res://scripts/match_state.gd")
const Expedition := preload("res://scripts/expedition_run.gd")
const BotAI := preload("res://scripts/bot_ai.gd")

var definitions: ModuleDefs
var failures := 0

func _init() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		printerr("EXP_DATA_FAILED")
		quit(1)
		return
	_check_config()
	_check_wave_flow()
	_check_scrap_economy()
	_check_reward_inventory()
	_check_core_destroyed_ends_run()
	_check_carry_over()
	_check_full_run()
	if failures > 0:
		printerr("EXPEDITION_FAIL count=%d" % failures)
		quit(1)
		return
	print("EXPEDITION_OK")
	quit(0)

func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("EXPEDITION_FAIL %s" % tag)

func _expect_near(value: float, expected: float, tag: String) -> void:
	_expect(absf(value - expected) <= 0.001, "%s %.4f != %.4f" % [tag, value, expected])

## 建造一台最小可玩船体，供远征复用（跨层就是同一台）。
func _make_rig() -> GridBuilder:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		return null
	builder.budget_enabled = false
	builder.credits_total = 1000000
	for y in range(2):
		for x in range(6):
			builder.place_platform_cell(Vector2i(x, y))
	builder.place_mobility("track_light", Vector2i(0, 0), 0)
	builder.place_module("cockpit_light", Vector2i(2, 1), 0, 0)
	builder.place_module("engine_small", Vector2i(1, 1), 0, 0)
	builder.place_module("ammo_factory_20", Vector2i(3, 0), 0, 0)
	builder.place_module("conveyor_straight", Vector2i(4, 0), 0, 0)
	builder.place_module("cannon_20", Vector2i(5, 0), 0, 0)
	return builder

func _check_config() -> void:
	var run := Expedition.new()
	_expect(run.setup(definitions, "arena_standard", 3), "config_setup")
	_expect(run.sectors_total == definitions.block_int("expedition", "default_run_sectors", 5), "config_sectors")
	_expect(run.waves_per_sector == definitions.block_int("expedition", "waves_per_sector", 3), "config_waves")
	_expect(run.sectors_total == 5 and run.waves_per_sector == 3, "config_five_by_three")
	_expect_near(run.credit, definitions.global_number("default_build_credits", 2400.0), "config_credit")

## 波次推进：3 波后进 INTERMISSION 而不是直接下一层（roadmap M6 验收 7）。
func _check_wave_flow() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 5)
	run.bind_player(_make_rig())
	_expect(run.start_wave(), "flow_start_wave_1")
	_expect(run.stage == Expedition.STAGE_BATTLE, "flow_in_battle")
	_expect(run.sector == 1 and run.wave == 1, "flow_first_wave")
	## 直接判玩家胜，走波次推进
	_force_player_win(run)
	_expect(run.wave == 2, "flow_wave_2_%d" % run.wave)
	_expect(run.stage == Expedition.STAGE_BUILD, "flow_back_to_build")
	_expect(run.start_wave(), "flow_start_wave_2")
	_force_player_win(run)
	_expect(run.wave == 3, "flow_wave_3_%d" % run.wave)
	run.start_wave()
	_force_player_win(run)
	_expect(run.stage == Expedition.STAGE_INTERMISSION or run.stage == Expedition.STAGE_REWARD, "flow_intermission_%s" % run.stage)
	_expect(run.sector == 1, "flow_sector_unchanged")

func _force_player_win(run: Expedition) -> void:
	var enemy_tank = run.session.duel.tank_of(Duel.TAG_ENEMY)
	var enemy_damage = run.session.duel.damage_of(Duel.TAG_ENEMY)
	for index in range(enemy_tank.parts.size()):
		var module_id := String(enemy_tank.parts[index]["module_id"])
		if bool(definitions.get_module(module_id).get("core", false)):
			enemy_damage.apply_part_damage(enemy_tank, index, 1.0e9, "destroyed")
			break
	run.session.step(1.0 / 60.0)
	run.step_battle(1.0 / 60.0)

## scrap 掉落：摧毁部件按 price × scrap_yield，击毁整机 +scrap_kill_bonus（验收 10）。
func _check_scrap_economy() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 7)
	run.bind_player(_make_rig())
	run.start_wave()
	var before := run.scrap
	var enemy_tank = run.session.duel.tank_of(Duel.TAG_ENEMY)
	var enemy_damage = run.session.duel.damage_of(Duel.TAG_ENEMY)
	## 打掉一个非驾驶舱部件，应只按价格折算，不给击杀奖励
	var target_index := -1
	for index in range(enemy_tank.parts.size()):
		var module_id := String(enemy_tank.parts[index]["module_id"])
		if not bool(definitions.get_module(module_id).get("core", false)):
			target_index = index
			break
	_expect(target_index >= 0, "scrap_target_found")
	var price := float(definitions.get_module(String(enemy_tank.parts[target_index]["module_id"])).get("price", 0.0))
	enemy_damage.apply_part_damage(enemy_tank, target_index, 1.0e9, "destroyed")
	run.step_battle(1.0 / 60.0)
	var gained := run.scrap - before
	var yield_rate := definitions.block_number("expedition", "scrap_yield", 0.35)
	_expect(gained >= price * yield_rate - 0.001, "scrap_part_drop %.3f >= %.3f" % [gained, price * yield_rate])
	_expect(run.kills == 0, "scrap_no_kill_yet")
	## 再击毁驾驶舱：应额外给击杀奖励
	var core_index := -1
	for index in range(enemy_tank.parts.size()):
		var module_id := String(enemy_tank.parts[index]["module_id"])
		if bool(definitions.get_module(module_id).get("core", false)):
			core_index = index
			break
	var before_kill := run.scrap
	enemy_damage.apply_part_damage(enemy_tank, core_index, 1.0e9, "destroyed")
	run.step_battle(1.0 / 60.0)
	_expect(run.kills == 1, "scrap_kill_counted_%d" % run.kills)
	var bonus := definitions.block_number("expedition", "scrap_kill_bonus", 60.0)
	_expect(run.scrap - before_kill >= bonus - 0.001, "scrap_kill_bonus %.3f" % (run.scrap - before_kill))

## 升级赠品进 inventory，不自动贴装（验收 11）。
func _check_reward_inventory() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 9)
	run.bind_player(_make_rig())
	run.start_wave()
	var mass_before := run.session.duel.tank_of(Duel.TAG_PLAYER).mass_total
	var parts_before := run.session.duel.tank_of(Duel.TAG_PLAYER).parts.size()
	## 强制进入三选一
	run.stage = Expedition.STAGE_REWARD
	run.reward_choices = ["up_damage", "up_burn", "up_slow"]
	_expect(run.reward_choices.size() == definitions.block_int("expedition", "expedition_choice_count", 3), "reward_choice_count")
	_expect(run.choose_reward(1), "reward_choose")
	_expect(run.inventory.size() == 1 and String(run.inventory[0]) == "up_burn", "reward_in_inventory_%s" % str(run.inventory))
	_expect(run.stage == Expedition.STAGE_INTERMISSION, "reward_to_intermission_%s" % run.stage)
	## 赠品不动坦克：部件数与质量都不变
	var mass_after := run.session.duel.tank_of(Duel.TAG_PLAYER).mass_total
	var parts_after := run.session.duel.tank_of(Duel.TAG_PLAYER).parts.size()
	_expect_near(mass_after, mass_before, "reward_mass_unchanged")
	_expect(parts_after == parts_before, "reward_parts_unchanged")

## 驾驶舱被毁 → 立即 RUN_SUMMARY，不进 RESULT（验收 8）。
func _check_core_destroyed_ends_run() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 11)
	run.bind_player(_make_rig())
	run.start_wave()
	var player_tank = run.session.duel.tank_of(Duel.TAG_PLAYER)
	var player_damage = run.session.duel.damage_of(Duel.TAG_PLAYER)
	var core_index := -1
	for index in range(player_tank.parts.size()):
		var module_id := String(player_tank.parts[index]["module_id"])
		if bool(definitions.get_module(module_id).get("core", false)):
			core_index = index
			break
	_expect(core_index >= 0, "core_destroyed_core_found")
	player_damage.apply_part_damage(player_tank, core_index, 1.0e9, "destroyed")
	run.step_battle(1.0 / 60.0)
	_expect(run.stage == Expedition.STAGE_SUMMARY, "core_destroyed_summary_%s" % run.stage)
	_expect(run.end_reason == "core_destroyed", "core_destroyed_reason_%s" % run.end_reason)
	_expect(run.session.phase != MatchState.PHASE_RESULT or run.session.outcome == MatchState.OUTCOME_ENEMY, "core_destroyed_not_victory")

## 跨层连续：同一台 builder 被复用，平台格数不回滚（验收 9）。
func _check_carry_over() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 13)
	var builder := _make_rig()
	run.bind_player(builder)
	run.start_wave()
	var cells_before := builder.platform_cells.size()
	## 打掉一块玩家平台格，制造一个破口
	run.session.duel.damage_of(Duel.TAG_PLAYER)
	var player_tank = run.session.duel.tank_of(Duel.TAG_PLAYER)
	var platform_index := -1
	for index in range(player_tank.parts.size()):
		if String(player_tank.parts[index]["kind"]) == "platform_cell":
			platform_index = index
			break
	_expect(platform_index >= 0, "carry_platform_found")
	run.session.duel.damage_of(Duel.TAG_PLAYER).apply_part_damage(player_tank, platform_index, 1.0e9, "destroyed")
	var cells_after := builder.platform_cells.size()
	_expect(cells_after < cells_before, "carry_breach_made %d -> %d" % [cells_before, cells_after])
	## 推进到下一层，破口必须保留
	run.stage = Expedition.STAGE_INTERMISSION
	_expect(run.advance_sector(), "carry_advance")
	_expect(run.sector == 2 and run.wave == 1, "carry_sector2")
	run.start_wave()
	_expect(builder.platform_cells.size() == cells_after, "carry_breach_kept %d vs %d" % [builder.platform_cells.size(), cells_after])

## 完整跑一次远征：应能推进到 SUMMARY 且汇总字段齐全（验收 7）。
func _check_full_run() -> void:
	var run := Expedition.new()
	run.setup(definitions, "arena_standard", 17)
	run.bind_player(_make_rig())
	var waves := 0
	var sectors_seen := 1
	while run.stage != Expedition.STAGE_SUMMARY and waves < 60:
		if run.stage == Expedition.STAGE_REWARD:
			run.choose_reward(0)
			continue
		if run.stage == Expedition.STAGE_INTERMISSION:
			sectors_seen = maxi(sectors_seen, run.sector)
			run.advance_sector()
			continue
		if not run.start_wave():
			break
		waves += 1
		_force_player_win(run)
	_expect(run.stage == Expedition.STAGE_SUMMARY, "full_run_summary_%s" % run.stage)
	_expect(run.end_reason == "cleared", "full_run_cleared_%s" % run.end_reason)
	_expect(run.sector == 5, "full_run_sector_%d" % run.sector)
	_expect(waves == 15, "full_run_waves_%d" % waves)
	var report := run.summary()
	for field in ["sector", "wave", "kills", "total_damage", "scrap", "credit", "inventory", "end_reason"]:
		_expect(report.has(field), "full_run_field_%s" % field)
	_expect(run.kills == 15, "full_run_kills_%d" % run.kills)
	_expect(run.inventory.size() == 4, "full_run_rewards_%d" % run.inventory.size())
	print("EXPEDITION_RUN waves=%d sectors=%d kills=%d scrap=%.1f credit=%.1f rewards=%d" % [
		waves, run.sector, run.kills, run.scrap, run.credit, run.inventory.size()
	])
	# 远征结束清零（§3.4 不跨局）
	run.close_run()
	_expect_near(run.scrap, 0.0, "full_run_scrap_cleared")
	_expect_near(run.credit, 0.0, "full_run_credit_cleared")
	_expect(run.inventory.is_empty(), "full_run_inventory_cleared")
