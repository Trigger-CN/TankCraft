extends RefCounted

## M6 对局状态机（design §3.1）：MATCH_SETUP → BUILD → DEPLOY → BATTLE → RESULT。
## 只负责阶段推进、计时与胜负判定，不碰绘制；EXPEDITION 的层/波推进由 expedition_run.gd 复用本类。
## 确定性：所有计时走固定步长，settle() 按 tag 排序裁决，不用 randf。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const Duel := preload("res://scripts/duel.gd")

const PHASE_SETUP := "MATCH_SETUP"
const PHASE_BUILD := "BUILD_PHASE"
const PHASE_DEPLOY := "DEPLOY_PHASE"
const PHASE_BATTLE := "BATTLE_PHASE"
const PHASE_RESULT := "RESULT"

const OUTCOME_NONE := ""
const OUTCOME_PLAYER := "player_win"
const OUTCOME_ENEMY := "enemy_win"
const OUTCOME_DRAW := "draw"
const OUTCOME_TIMEOUT_PLAYER := "timeout_player"
const OUTCOME_TIMEOUT_ENEMY := "timeout_enemy"

## design §3.1：DEPLOY_PHASE 倒计时 3 s。
const DEPLOY_COUNTDOWN_S := 3.0

var definitions: ModuleDefs
var duel: Duel
var phase: String = PHASE_SETUP
var outcome: String = OUTCOME_NONE
var build_time_left: float = 0.0
var deploy_time_left: float = 0.0
var battle_time_left: float = 0.0
var battle_time_limit: float = 300.0
var build_time_limit: float = 300.0
## 是否启用建造软时限（design §3.1「默认 300 s，可关」）
var build_time_enabled: bool = true
var paused: bool = false
var paused_time: float = 0.0

func setup(module_defs: ModuleDefs, arena_id: String) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	build_time_limit = definitions.global_number("build_time_limit_s", 300.0)
	battle_time_limit = definitions.global_number("match_time_limit_s", 300.0)
	duel = Duel.new()
	if not duel.setup(definitions):
		return false
	duel.load_arena(arena_id)
	phase = PHASE_BUILD
	build_time_left = build_time_limit
	outcome = OUTCOME_NONE
	return true

## 双方都已放入坦克后进入 DEPLOY_PHASE（design §3.1：出生点与朝向微调 + 3 s 倒计时）。
func enter_deploy() -> bool:
	if phase != PHASE_BUILD:
		return false
	phase = PHASE_DEPLOY
	deploy_time_left = DEPLOY_COUNTDOWN_S
	return true

## DEPLOY 倒计时结束转 BATTLE；对局计时从此刻开始（design §3.3 超时判定）。
func enter_battle() -> bool:
	if phase != PHASE_DEPLOY:
		return false
	phase = PHASE_BATTLE
	battle_time_left = battle_time_limit
	return true

func toggle_pause() -> bool:
	if phase != PHASE_BATTLE:
		return false
	paused = not paused
	return paused

## 单帧推进。only BATTLE 会跑战斗逻辑；RESULT 之后不再推进。
func step(delta: float) -> void:
	if phase == PHASE_BUILD:
		if build_time_enabled and build_time_left > 0.0:
			build_time_left = maxf(0.0, build_time_left - delta)
		return
	if phase == PHASE_DEPLOY:
		deploy_time_left = maxf(0.0, deploy_time_left - delta)
		if deploy_time_left <= 0.0:
			enter_battle()
		return
	if phase != PHASE_BATTLE:
		return
	if paused:
		paused_time += delta
		return
	battle_time_left = maxf(0.0, battle_time_left - delta)
	duel.step(delta)
	_resolve_outcome()

## design §3.3：驾驶舱被毁即判负。VERSUS 下仍按双方伤害比较，
## 但判负本身改为按 **team** 而非写死的 tag，使 N 侧（R18）也能用同一套逻辑。
func _resolve_outcome() -> void:
	if outcome != OUTCOME_NONE:
		return
	var player_down := duel.team_defeated(Duel.TEAM_PLAYER)
	var enemy_down := duel.team_defeated(Duel.TEAM_ENEMY)
	if player_down or enemy_down:
		if player_down and enemy_down:
			outcome = _compare_damage(OUTCOME_TIMEOUT_PLAYER, OUTCOME_TIMEOUT_ENEMY)
			if outcome == OUTCOME_NONE:
				outcome = OUTCOME_DRAW
		elif enemy_down:
			outcome = OUTCOME_PLAYER
		else:
			outcome = OUTCOME_ENEMY
		phase = PHASE_RESULT
		return
	if battle_time_left <= 0.0:
		outcome = _compare_damage(OUTCOME_TIMEOUT_PLAYER, OUTCOME_TIMEOUT_ENEMY)
		if outcome == OUTCOME_NONE:
			outcome = OUTCOME_DRAW
		phase = PHASE_RESULT

## 返回 player 胜 / enemy 胜 / OUTCOME_NONE（双方伤害相同）。
## N 侧（R18）下比的是**队总和**：同队多个敌人各自的伤害相加。
func _compare_damage(player_outcome: String, enemy_outcome: String) -> String:
	var player_dealt := duel.team_damage(Duel.TEAM_PLAYER)
	var enemy_dealt := duel.team_damage(Duel.TEAM_ENEMY)
	if player_dealt > enemy_dealt:
		return player_outcome
	if enemy_dealt > player_dealt:
		return enemy_outcome
	return OUTCOME_NONE

func is_over() -> bool:
	return phase == PHASE_RESULT

func player_won() -> bool:
	return outcome == OUTCOME_PLAYER or outcome == OUTCOME_TIMEOUT_PLAYER

## 结算面板数据（design §3.1 RESULT）：造成伤害、摧毁模块数、命中率、剩余质量、剩余信用点。
## N 侧（R18）下「enemy」字段代表敌方**队总和**；同队多个敌人时 `enemy_parts` 取存活侧的合计。
func result_panel() -> Dictionary:
	var player := duel.structure_summary(Duel.TAG_PLAYER)
	var player_dealt := duel.team_damage(Duel.TEAM_PLAYER)
	var enemy_dealt := duel.team_damage(Duel.TEAM_ENEMY)
	var enemy_parts := 0
	var enemy_mass := 0.0
	var enemy_tags: Array = duel.sides.keys()
	enemy_tags.sort()
	for raw_tag in enemy_tags:
		var tag := String(raw_tag)
		if duel.team_of(tag) != Duel.TEAM_ENEMY:
			continue
		var summary := duel.structure_summary(tag)
		## 已被击毁的敌人也计入（0 部件、0 质量），这样“敌人越少”能直接读出来。
		enemy_parts += int(summary["parts"])
		enemy_mass += float(summary["mass"])
	return {
		"outcome": outcome,
		"player_damage": player_dealt,
		"enemy_damage": enemy_dealt,
		"player_parts": int(player["parts"]),
		"enemy_parts": enemy_parts,
		"player_mass": float(player["mass"]),
		"enemy_mass": enemy_mass,
		"battle_time_left": battle_time_left,
		"paused_time": paused_time,
	}
