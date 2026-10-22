extends RefCounted

## M6 单人 roguelike 远征（design §3.4）。5 层 × 3 波，坦克跨层连续，
## INTERMISSION 发放 credit 并给一次升级三选一，驾驶舱被毁立即转 RUN_SUMMARY。
## scrap 经济（§3.4.1）：摧毁部件掉 price × scrap_yield，击毁整机额外 +scrap_kill_bonus，远征结束清零。
## 纯逻辑、无绘制；随机只走显式 LCG，录制种子即可复现（§10.4）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const MatchState := preload("res://scripts/match_state.gd")
const Duel := preload("res://scripts/duel.gd")
const BotAI := preload("res://scripts/bot_ai.gd")

const STAGE_BUILD := "BUILD"
const STAGE_BATTLE := "BATTLE"
const STAGE_INTERMISSION := "INTERMISSION"
const STAGE_REWARD := "REWARD"
const STAGE_SUMMARY := "RUN_SUMMARY"

var definitions: ModuleDefs
var stage: String = STAGE_BUILD
var sector: int = 1
var wave: int = 1
var sectors_total: int = 5
var waves_per_sector: int = 3
var scrap: float = 0.0
var credit: float = 0.0
var inventory: Array = []
var kills: int = 0
var total_damage: float = 0.0
var end_reason: String = ""
var session: MatchState
var builder: GridBuilder
var ai: BotAI
var arena_id: String = "arena_standard"
## 升级三选一的候选（id 列表，长度 = expedition_choice_count）
var reward_choices: Array = []
var chosen_rewards: Array = []

var _scrap_yield: float = 0.35
var _scrap_kill_bonus: float = 60.0
var _intermission_credits: float = 600.0
var _choice_count: int = 3
var _rng_state: int = 1
var _previous_parts: Dictionary = {}
var _previous_enemy_alive: bool = true

func setup(module_defs: ModuleDefs, arena: String = "arena_standard", seed_value: int = 1) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	arena_id = arena
	_rng_state = maxi(seed_value, 1)
	sectors_total = definitions.block_int("expedition", "default_run_sectors", 5)
	waves_per_sector = definitions.block_int("expedition", "waves_per_sector", 3)
	_scrap_yield = definitions.block_number("expedition", "scrap_yield", 0.35)
	_scrap_kill_bonus = definitions.block_number("expedition", "scrap_kill_bonus", 60.0)
	_intermission_credits = definitions.block_number("expedition", "intermission_credits", 600.0)
	_choice_count = definitions.block_int("expedition", "expedition_choice_count", 3)
	credit = definitions.global_number("default_build_credits", 2400.0)
	sector = 1
	wave = 1
	stage = STAGE_BUILD
	return true

## 玩家坦克在整次远征中是同一台：builder 只建一次，之后各层复用（§3.4「坦克连续性」）。
func bind_player(tank_builder: GridBuilder) -> void:
	builder = tank_builder
	_previous_parts.clear()

## 开始一波：按层/波取竞技场出生点，生成 1–3 台敌方坦克（§3.4 波次）。
func start_wave() -> bool:
	if builder == null:
		return false
	var wave_index := (sector - 1) * waves_per_sector + (wave - 1)
	var spawns := _wave_spawns(wave_index)
	if spawns.is_empty():
		return false
	session = MatchState.new()
	if not session.setup(definitions, arena_id):
		return false
	var player_spawn: Dictionary = _player_spawn()
	session.duel.add_side(Duel.TAG_PLAYER, builder, player_spawn["pos"], player_spawn["rot"])
	## 本阶段只支持 1v1：每波只用第一个敌方出生点，其余按设计保留给后续波次扩展。
	var enemy_spawn: Dictionary = spawns[0]
	var enemy_builder := GridBuilder.new()
	if not enemy_builder.setup(definitions):
		return false
	enemy_builder.budget_enabled = false
	enemy_builder.credits_total = 1000000
	var tier := _tier_for(sector)
	var blueprint := _bot_blueprint(tier)
	if not blueprint.is_empty():
		var reason := enemy_builder.load_blueprint(blueprint)
		if not reason.is_empty():
			return false
	session.duel.add_side(Duel.TAG_ENEMY, enemy_builder, enemy_spawn["pos"], enemy_spawn["rot"])
	session.enter_deploy()
	session.step(MatchState.DEPLOY_COUNTDOWN_S + 0.01)
	ai = BotAI.new()
	ai.setup(definitions, tier, _rng_state + sector * 31 + wave)
	if not session.phase == MatchState.PHASE_BATTLE:
		return false
	stage = STAGE_BATTLE
	_previous_parts = _snapshot_parts(Duel.TAG_ENEMY)
	_previous_enemy_alive = true
	return true
	return true

## 单帧推进战斗，并把新摧毁的部件折算成 scrap（§3.4.1）。
func step_battle(dt: float) -> void:
	if stage != STAGE_BATTLE or session == null:
		return
	var decision := ai.think(dt, session.duel)
	session.duel.set_input(Duel.TAG_ENEMY, float(decision["throttle"]), float(decision["steer"]))
	if bool(decision["fire"]):
		session.duel.fire(Duel.TAG_ENEMY)
	session.step(dt)
	_accumulate_scrap()
	total_damage = float(session.duel.damage_dealt.get(Duel.TAG_PLAYER, 0.0))
	if session.is_over():
		_finish_wave()

## 摧毁部件按 price × scrap_yield 掉落；击毁整机额外 +scrap_kill_bonus。
## _previous_parts 记录的是**敌方**上一帧的存活部件集，用于算增量。
func _accumulate_scrap() -> void:
	var current := _snapshot_parts(Duel.TAG_ENEMY)
	var previous_enemy: Dictionary = _previous_parts
	var removed := 0
	for raw_key in previous_enemy.keys():
		if not current.has(raw_key):
			removed += 1
			scrap += _price_of_key(String(raw_key)) * _scrap_yield
	if removed > 0:
		_previous_parts = current
	var enemy_alive := not session.duel.defeated(Duel.TAG_ENEMY)
	if _previous_enemy_alive and not enemy_alive:
		scrap += _scrap_kill_bonus
		kills += 1
		_previous_enemy_alive = false

## part_key 形如 "module|cannon_20|x,y"，从中取出 module_id 再查价。
func _price_of_key(key: String) -> float:
	var pieces := key.split("|")
	if pieces.size() < 2:
		return 0.0
	var definition: Dictionary = definitions.get_module(String(pieces[1]))
	return float(definition.get("price", 0.0))

func _snapshot_parts(tag: String) -> Dictionary:
	var result := {}
	var tank = session.duel.tank_of(tag)
	if tank == null:
		return result
	for part in tank.parts:
		result[String(part.get("key", ""))] = true
	return result

func _finish_wave() -> void:
	if session.player_won() or session.outcome == MatchState.OUTCOME_DRAW:
		## 波次推进：同层内 wave+1，越层则进 INTERMISSION（§3.4）。
		if wave < waves_per_sector:
			wave += 1
			stage = STAGE_BUILD
			return
		if sector < sectors_total:
			stage = STAGE_INTERMISSION
			credit += _intermission_credits
			_grant_reward()
			return
		stage = STAGE_SUMMARY
		end_reason = "cleared"
		return
	## 驾驶舱被毁：远征立即结束，不进入 RESULT（§3.3 / roadmap M6 验收 8）。
	stage = STAGE_SUMMARY
	end_reason = "core_destroyed"

## 层间整备结束：进入下一层第 1 波（坦克状态不回滚）。
func advance_sector() -> bool:
	if stage != STAGE_INTERMISSION:
		return false
	sector += 1
	wave = 1
	stage = STAGE_BUILD
	return true

## 升级三选一（§3.4.2）：候选来自 upgrades 与模块池，赠品进 inventory 而非直接贴装。
func _grant_reward() -> void:
	reward_choices.clear()
	var pool: Array = []
	for raw_id in definitions.registry.upgrades.keys():
		pool.append(String(raw_id))
	pool.sort()
	if pool.is_empty():
		stage = STAGE_INTERMISSION
		return
	for index in range(mini(_choice_count, pool.size())):
		var pick := int(_next_unit() * float(pool.size())) % pool.size()
		var choice := String(pool[pick])
		## 去重：同一次三选一里不给重复候选。
		var guard := 0
		while reward_choices.has(choice) and guard < pool.size():
			pick = (pick + 1) % pool.size()
			choice = String(pool[pick])
			guard += 1
		reward_choices.append(choice)
	stage = STAGE_REWARD

## 选择一项奖励：只进 inventory，不自动贴装（§3.4.2，roadmap M6 验收 11）。
func choose_reward(index: int) -> bool:
	if stage != STAGE_REWARD or index < 0 or index >= reward_choices.size():
		return false
	var picked := String(reward_choices[index])
	inventory.append(picked)
	chosen_rewards.append(picked)
	reward_choices.clear()
	stage = STAGE_INTERMISSION
	return true

## 从 inventory 取出一件（装上时才计入 M / mass_cap 校验，由建造侧保证）。
func take_from_inventory(module_id: String) -> bool:
	var index := inventory.find(module_id)
	if index < 0:
		return false
	inventory.remove_at(index)
	return true

## 远征结束：credit / scrap / inventory 全部清零（§3.4「不跨局」）。
func summary() -> Dictionary:
	var result := {
		"sector": sector,
		"wave": wave,
		"kills": kills,
		"total_damage": total_damage,
		"scrap": scrap,
		"credit": credit,
		"inventory": inventory.duplicate(),
		"end_reason": end_reason,
		"stage": stage,
	}
	return result

func close_run() -> void:
	credit = 0.0
	scrap = 0.0
	inventory.clear()
	chosen_rewards.clear()
	reward_choices.clear()

## 竞技场 expedition_spawns：玩家固定一处；敌人按波次序号取用，超出长度时循环（§9.2）。
func _player_spawn() -> Dictionary:
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var data: Dictionary = arena.get("expedition_spawns", {})
	var player: Dictionary = data.get("player", {})
	var raw: Array = player.get("pos", [20, 36])
	return {"pos": Vector2(float(raw[0]), float(raw[1])) * cell, "rot": deg_to_rad(float(player.get("rot", 0)))}

func _wave_spawns(wave_index: int) -> Array:
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var data: Dictionary = arena.get("expedition_spawns", {})
	var waves: Array = data.get("waves", [])
	var result: Array = []
	if waves.is_empty():
		var spawns: Array = arena.get("spawns", [])
		if spawns.size() < 2:
			return result
		var raw_fallback: Array = spawns[1].get("pos", [108, 36])
		return [{"pos": Vector2(float(raw_fallback[0]), float(raw_fallback[1])) * cell, "rot": deg_to_rad(float(spawns[1].get("rot", 180)))}]
	var entry: Array = waves[posmod(wave_index, waves.size())]
	for raw_spawn in entry:
		var spawn: Dictionary = raw_spawn
		var raw: Array = spawn.get("pos", [108, 36])
		result.append({"pos": Vector2(float(raw[0]), float(raw[1])) * cell, "rot": deg_to_rad(float(spawn.get("rot", 180)))})
	return result

## 难度随层数递增（§3.4 波次）。
func _tier_for(current_sector: int) -> String:
	if current_sector <= 1:
		return BotAI.TIER_RECRUIT
	if current_sector == 2:
		return BotAI.TIER_VETERAN
	if current_sector <= 4:
		return BotAI.TIER_ELITE
	return BotAI.TIER_ACE

## 该难度档的蓝图池里按确定性顺序挑一张。
func _bot_blueprint(tier: String) -> Dictionary:
	var ids: Array = []
	for raw_id in definitions.registry.blueprints.keys():
		if String(raw_id).begins_with("bot_%s_" % tier):
			ids.append(String(raw_id))
	ids.sort()
	if ids.is_empty():
		return {}
	return definitions.get_blueprint(String(ids[0]))

func _next_unit() -> float:
	_rng_state = (_rng_state * 1664525 + 1013904223) % 4294967296
	return float(_rng_state) / 4294967296.0
