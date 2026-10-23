extends RefCounted

## M9 单人肉鸽波次生存（design §3.4）。
##
## 一局 = 一次 run：玩家驾驶**同一台持续演进**的坦克，在固定竞技场里连续承受波次。
## 每波限时，**活到计时归零即通过**；驾驶舱被毁 = run 立即结束（不进入 RESULT 复盘）。
##
## 阶段：BATTLE → (LEVEL_UP →)? SHOP → BATTLE …；每 5 波为 Boss 波。
## 改装（MODIFY）是 LEVEL_UP / SHOP 的子阶段：只能从这两页进入，离开时回到进入时的阶段。
##
## 纪律（与 match_state / expedition_run 一致）：
## - 纯逻辑、无绘制，主场景与 headless smoke 共用同一份结算。
## - 全部玩法数值来自 `data/globals.json` 的 `survival` 块（经 `block_*` 读取），脚本内不内联。
## - 确定性：60 Hz 固定步、容器按 key 排序、随机只走显式 LCG（禁止 `randf`）。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const Duel := preload("res://scripts/duel.gd")
const BotAI := preload("res://scripts/bot_ai.gd")
const TankBody := preload("res://scripts/tank_body.gd")

const STAGE_BATTLE := "battle"
const STAGE_LEVEL_UP := "level_up"
const STAGE_SHOP := "shop"
## 改装子阶段：只能从 LEVEL_UP / SHOP 进入；战斗期（BATTLE）不可达（design §3.4 表格）。
const STAGE_MODIFY := "modify"
const STAGE_SUMMARY := "run_summary"

## 升级候选的三种类型（design §3.4.2）。
const CHOICE_MODULE := "module"
const CHOICE_UPGRADE := "upgrade"
const CHOICE_MASS_CAP := "mass_cap"

var definitions: ModuleDefs
var arena_id: String = "arena_standard"

var stage: String = STAGE_BATTLE
## 当前波次，从 1 开始。
var wave: int = 1
var wave_time_left: float = 0.0
var wave_time_limit: float = 0.0
## 本波是否已通过。通过条件（用户 2026-10-21 变更）：计时归零，**或**「本波配额已全部生成完」
## 且场上无敌人。旧规则「场上没敌人就立即通过」已废除——它会与持续补兵互斥。
var wave_passed: bool = false

var credit: float = 0.0
var experience: float = 0.0
var level: int = 1
var xp_into_level: float = 0.0

## 未贴装的配件（模块 id）。不计入 M / mass_cap，只在真正装上时校验（design §3.4.2）。
var inventory: Array[String] = []
## 升级菜单当前候选，每项 {kind, id, label, price}
var level_choices: Array = []
## 商店 6 格，每项 {kind, id, price, sold}
var shop_slots: Array = []
var shop_rerolls: int = 0
var collected_upgrades: Array[String] = []
## v3.24：上一次领奖的反馈文本（页面层直接显示）。升级现在是**实体**：
## 领到就立即装进某件改进装置的空槽；装不下才暂存到 `collected_upgrades`，
## 并在 UI 里明确说“没有空槽，已暂存”，绝不静默生效。
var upgrade_note: String = ""
## 还没发出去的升级次数：`_add_xp` 每升一级 +1，`take_level_choice` 领取一份 -1。
## 这是升级菜单的唯一触发依据（不能靠重算剩余经验——等级已经被抬完了）。
var pending_level_ups: int = 0
## 进入改装前的阶段（LEVEL_UP / SHOP），离开时回到这里。
var modify_return_stage: String = ""
## 进入改装时的 `builder.credits_spent()` 基线：改装支出按**净增**计算。
var modify_credit_baseline: float = 0.0
## 本次 run 累计已结算的改装支出（只做展示，不参与扣款）。
var modify_spent_total: float = 0.0
## 房屋在 `duel.obstacles` 里的起始下标（竞技场固定障碍在前）。
var _house_obstacle_offset: int = 0

## 本局的坦克与建造模型（run 期间始终是同一台）。
var builder: GridBuilder = null
var duel: Duel = null
## tag -> BotAI（敌方每台一个，各自独立决策）
var enemy_ai: Dictionary = {}
## tag -> 该敌方的档位
var enemy_tier: Dictionary = {}

## 房屋：{cell, rect, hp, hp_max, armor, alive}
var houses: Array = []
## 残骸：{cell, taken, payout_kind, is_house}
var debris: Array = []

var kills: int = 0
var houses_destroyed: int = 0
var debris_taken: int = 0
var total_damage: float = 0.0
## run 结束时置真（驾驶舱被毁）。
var run_over: bool = false

var _rng_state: int = 1
var _enemy_serial: int = 0
## 本波已生成过的敌人台数（含首批），用于配额判定。
var _enemies_spawned: int = 0
## 补兵倒计时：>0 时递减，归零且场上腾出空位就补一台并重置。
var _enemy_reinforce_timer: float = 0.0

var _wave_time_s: float = 45.0
var _wave_growth_s: float = 5.0
var _enemy_count_base: int = 2
var _enemy_count_per_wave: float = 0.34
var _enemy_count_max: int = 6
## 本波总配额 = 同屏上限 × 该倍数（Boss 波恒为 1 台，不补兵）。
var _enemy_quota_multiplier: float = 3.0
## 场上腾出空位后，隔多久补一台。
var _enemy_reinforce_delay_s: float = 5.0
var _boss_every: int = 5
var _xp_base: float = 60.0
var _xp_step: float = 45.0
var _xp_per_kill: float = 25.0
var _xp_per_house: float = 12.0
var _xp_per_debris: float = 8.0
var _choice_count: int = 3
var _credit_per_kill: float = 40.0
var _debris_credit_min: float = 15.0
var _debris_credit_max: float = 45.0
var _debris_xp_min: float = 4.0
var _debris_xp_max: float = 12.0
var _debris_credit_share: float = 0.5
var _credit_per_house: float = 55.0
var _house_hp: float = 260.0
var _house_armor: float = 5.0
var _house_debris_credit: float = 18.0
var _props_houses: int = 4
var _props_debris: int = 6
var _debris_drop_chance: float = 0.15
var _house_drop_chance: float = 0.30
var _enemy_drop_chance: float = 0.25
var _boss_credit_reward: float = 320.0
var _boss_xp_reward: float = 200.0
var _boss_drop_count: int = 3
var _shop_slot_count: int = 6
var _shop_reroll_cost: float = 60.0
var _shop_sell_rate: float = 0.5
var _shop_weights: Array = [60, 30, 10]
var _shop_common_max: float = 80.0
var _shop_rare_max: float = 160.0
var _wall_base: float = 4.0
var _wall_per_speed: float = 0.05
var _wall_min_speed: float = 20.0

func setup(module_defs: ModuleDefs, arena_name: String = "arena_standard", seed_value: int = 1) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	arena_id = arena_name
	_rng_state = maxi(seed_value, 1)
	_read_config()
	credit = definitions.global_number("default_build_credits", 2400.0)
	wave = 1
	level = 1
	xp_into_level = 0.0
	stage = STAGE_BATTLE
	run_over = false
	wave_passed = false
	return true

func _read_config() -> void:
	_wave_time_s = definitions.block_number("survival", "wave_time_s", 45.0)
	_wave_growth_s = definitions.block_number("survival", "wave_growth_s", 5.0)
	_enemy_count_base = definitions.block_int("survival", "enemy_count_base", 2)
	_enemy_count_per_wave = definitions.block_number("survival", "enemy_count_per_wave", 0.34)
	_enemy_count_max = definitions.block_int("survival", "enemy_count_max", 6)
	_enemy_quota_multiplier = maxf(definitions.block_number("survival", "enemy_quota_multiplier", 3.0), 1.0)
	_enemy_reinforce_delay_s = maxf(definitions.block_number("survival", "enemy_reinforce_delay_s", 5.0), 0.5)
	_boss_every = maxi(definitions.block_int("survival", "boss_every", 5), 1)
	_xp_base = definitions.block_number("survival", "xp_base", 60.0)
	_xp_step = definitions.block_number("survival", "xp_step", 45.0)
	_xp_per_kill = definitions.block_number("survival", "xp_per_kill", 25.0)
	_xp_per_house = definitions.block_number("survival", "xp_per_house", 12.0)
	_xp_per_debris = definitions.block_number("survival", "xp_per_debris", 8.0)
	_choice_count = maxi(definitions.block_int("survival", "choice_count", 3), 1)
	_credit_per_kill = definitions.block_number("survival", "credit_per_kill", 40.0)
	_debris_credit_min = definitions.block_number("survival", "debris_credit_min", 15.0)
	_debris_credit_max = definitions.block_number("survival", "debris_credit_max", 45.0)
	_debris_xp_min = definitions.block_number("survival", "debris_xp_min", 4.0)
	_debris_xp_max = definitions.block_number("survival", "debris_xp_max", 12.0)
	_debris_credit_share = definitions.block_number("survival", "debris_credit_share", 0.5)
	_credit_per_house = definitions.block_number("survival", "credit_per_house", 55.0)
	_house_hp = definitions.block_number("survival", "house_hp", 260.0)
	_house_armor = definitions.block_number("survival", "house_armor", 5.0)
	_house_debris_credit = definitions.block_number("survival", "house_debris_credit", 18.0)
	_props_houses = definitions.block_int("survival", "props_houses", 4)
	_props_debris = definitions.block_int("survival", "props_debris", 6)
	_debris_drop_chance = definitions.block_number("survival", "debris_drop_chance", 0.15)
	_house_drop_chance = definitions.block_number("survival", "house_drop_chance", 0.30)
	_enemy_drop_chance = definitions.block_number("survival", "enemy_drop_chance", 0.25)
	_boss_credit_reward = definitions.block_number("survival", "boss_credit_reward", 320.0)
	_boss_xp_reward = definitions.block_number("survival", "boss_xp_reward", 200.0)
	_boss_drop_count = definitions.block_int("survival", "boss_drop_count", 3)
	_shop_slot_count = maxi(definitions.block_int("survival", "shop_slot_count", 6), 1)
	_shop_reroll_cost = definitions.block_number("survival", "shop_reroll_cost", 60.0)
	_shop_sell_rate = definitions.block_number("survival", "shop_sell_rate", 0.5)
	var raw_weights: Variant = definitions.registry.globals.get("survival", {}).get("shop_rarity_weight", [])
	if raw_weights is Array and (raw_weights as Array).size() >= 3:
		_shop_weights = (raw_weights as Array).duplicate()
	_shop_common_max = definitions.block_number("survival", "shop_common_price_max", 80.0)
	_shop_rare_max = definitions.block_number("survival", "shop_rare_price_max", 160.0)
	_wall_base = definitions.global_number("wall_impact_damage_base", 4.0)
	_wall_per_speed = definitions.global_number("wall_impact_damage_per_speed", 0.05)
	_wall_min_speed = definitions.global_number("wall_impact_min_speed", 20.0)

## 玩家坦克在整次 run 中是同一台：builder 只绑一次，之后各波复用（design §3.4「坦克连续性」）。
func bind_player(tank_builder: GridBuilder) -> void:
	builder = tank_builder

# ─── 起始坦克（唯一来源）────────────────────────────────────────────────────

## 起始坦克的布局与建造顺序：`main.gd` 的生存页与 `tests/survival_smoke.gd` 共用这一处，
## 避免「测试用的最小合法车」与「实际开局车」再次分叉。
##
## 用户 2026-10-17 报告「发射炮弹似乎不能对敌人造成伤害」。实测根因之一就在这份布局：
## 早期版本直接照搬测试用的最小合法车（20mm 炮）。`cal_20` 对 armor 3 的手绘平台格
## 只有 `max(8×0.15, 8−3) = 5.0` 伤害，而当时的招募级 Bot 是 30 格平台 + 5 件模块 = 1835 总血量，
## 一波 45 s 内理论最大输出约 128 发 × 5 = 640，**数学上不可能击毁任何一台敌人**。
## 因此起始武装改为 76mm（`cannon_76` + `ammo_factory_76`），实测一波内可击毁 1 台。
##
## 用户 2026-10-21 又指出「配件、摆放更合理」：旧版是 8×2 的细长条，只有一条 `track_light`
## 贴在车身最左端。`TankBody.drive_metrics()` 逐条履带算 `side = signf(forward.cross(offset))`，
## 单条偏心履带会让 `axis = throttle − side·steer` 左右失衡，净推力与扭矩同时畸变。
##
## 现在改成 6×4：两条 `track_heavy`（fp2）分列 y=0 / y=3，横向占 (2..3)，
## 两条履带的中心都在 x=3.0 上，正好压在质心横坐标上——不再产生恒定偏转扭矩。
## 弹药链沿 y=1 从车头走到车尾，驾驶舱与引擎分居 y=2 左右，重心居中。
##
## 弹药链端口规则（`ammo_network.gd:28-34`）：factory 只出 E、直管 W→E、炮管只进 W，
## 所以三件必须横向逐格相邻；炮管是 2 格宽，起点必须紧贴直管右侧那一格。
##
## 为什么**不放弹药库**：`ammo_depot_small` 被摧毁时会按 `capacity_slots`（8 格）殉爆
## `6 × 8 = 48` 伤害、半径 2.5 格——在 6×4 的车里这等于把一颗雷埋在自己驾驶舱边上。
## 实测（probe_roster2）：带弹药库的版本殉爆连锁 13 次，step 2185（36.4 s）就被自己炸死。
## 而且工厂 1.5 s 造一发已经快过炮管 1.1 s 的装填，本来就不需要缓冲。
##
## 驾驶舱放在车体**中部**而不是尾部：驾驶舱一爆 run 立即结束（design §3.3），
## 放在边缘会让流弹轻易从侧面掏进去；实测把驾驶舱放到 (5,1) 的**试验布局**后，
## 一波 22.7 s 就被打爆（probe_roster5）——这是试验布局的数字，不是现在这版的。
const STARTER_SIZE := Vector2i(6, 4)
const STARTER_MOBILITY := [
	{"id": "track_heavy", "cell": Vector2i(2, 0), "rot": 0},
	{"id": "track_heavy", "cell": Vector2i(2, 3), "rot": 0},
]
const STARTER_MODULES := [
	{"id": "ammo_factory_76", "cell": Vector2i(0, 1), "rot": 0},
	{"id": "conveyor_straight", "cell": Vector2i(2, 1), "rot": 0},
	{"id": "cannon_76", "cell": Vector2i(3, 1), "rot": 0},
	{"id": "cockpit_light", "cell": Vector2i(2, 2), "rot": 0},
	{"id": "engine_small", "cell": Vector2i(3, 2), "rot": 0},
]

## 按 `STARTER_*` 摆一台合法起始车。返回空字符串表示成功，否则返回第一个拒绝原因。
static func build_starter(model: GridBuilder) -> String:
	if model == null:
		return "建造模型为空"
	model.budget_enabled = false
	model.credits_total = 1000000
	for y in range(STARTER_SIZE.y):
		for x in range(STARTER_SIZE.x):
			var cell_reason: String = model.place_platform_cell(Vector2i(x, y))
			if not cell_reason.is_empty():
				return "平台 (%d,%d) %s" % [x, y, cell_reason]
	for entry in STARTER_MOBILITY:
		var placed_mobility: String = model.place_mobility(String(entry["id"]), Vector2i(entry["cell"]), int(entry["rot"]))
		if not placed_mobility.is_empty():
			return "%s %s" % [String(entry["id"]), placed_mobility]
	for entry in STARTER_MODULES:
		var placed_module: String = model.place_module(String(entry["id"]), Vector2i(entry["cell"]), int(entry["rot"]), 0)
		if not placed_module.is_empty():
			return "%s %s" % [String(entry["id"]), placed_module]
	var report: Dictionary = model.validation_report()
	if not bool(report.get("ok", false)):
		var errors: Array = report.get("errors", [])
		if not errors.is_empty():
			return String(errors[0])
		return "校验未通过"
	return ""

# ─── 波次 ─────────────────────────────────────────────────────────────────────

## 当前波是否 Boss 波（design §3.4.5：每 5 波）。
func is_boss_wave() -> bool:
	return wave % _boss_every == 0

## 当前波的时限：基础值 + 每满 5 波递增一次（design §14.8 `SURVIVAL_WAVE_GROWTH`）。
func wave_time_for(current_wave: int) -> float:
	var steps := int(floorf(float(current_wave - 1) / float(_boss_every)))
	return _wave_time_s + _wave_growth_s * float(steps)

## 同屏上限（普通波按 `base + per_wave·(n−1)` 向下取整并封顶；Boss 波固定 1 台）。
## 注意：这**不再是本波总数**——本波总数见 `enemy_quota_for()`。
func enemy_count_for(current_wave: int) -> int:
	if current_wave % _boss_every == 0:
		return 1
	var raw := float(_enemy_count_base) + _enemy_count_per_wave * float(current_wave - 1)
	return clampi(int(floorf(raw)), 1, _enemy_count_max)

## 本波敌人总配额（用户 2026-10-21：「敌人不断地生成」）。
## 同屏上限 × `enemy_quota_multiplier`，向下取整且至少等于同屏上限；Boss 波恒为 1。
## 为什么分开两个函数：同屏上限控制「同时打几台」，配额控制「这一波总共要打几台」。
## 只用一个数字做不到「持续补兵」——要么同屏塞满、要么杀完就结束。
func enemy_quota_for(current_wave: int) -> int:
	if current_wave % _boss_every == 0:
		return 1
	var cap := enemy_count_for(current_wave)
	return maxi(cap, int(floorf(float(cap) * _enemy_quota_multiplier)))

## 当前波对应的敌人档位（design §14.8 敌人级别表）。
## Boss 波额外抬高到**至少精英**（design §3.4.5：“Boss 的 AI 档位取当前波次对应的最高档（≥ 精英）”）。
func tier_for(current_wave: int) -> String:
	var tier := BotAI.TIER_RECRUIT
	if current_wave > 4:
		tier = BotAI.TIER_VETERAN
	if current_wave > 9:
		tier = BotAI.TIER_ELITE
	if current_wave > 14:
		tier = BotAI.TIER_ACE
	if current_wave % _boss_every == 0 and BotAI.TIERS.find(tier) < BotAI.TIERS.find(BotAI.TIER_ELITE):
		tier = BotAI.TIER_ELITE
	return tier

## 开始一波：重建 duel、生成首批敌人、刷新道具。坦克与损伤沿用上一波（不回滚）。
## 首批只出「同屏上限」那么多台；剩下的配额由 `step_battle()` 在有空位时陆续补上。
func start_wave() -> bool:
	if builder == null or definitions == null:
		return false
	wave_passed = false
	wave_time_limit = wave_time_for(wave)
	wave_time_left = wave_time_limit
	duel = Duel.new()
	if not duel.setup(definitions):
		return false
	duel.load_arena(arena_id)
	var player_spawn := _player_spawn()
	if not duel.add_side(Duel.TAG_PLAYER, builder, player_spawn["pos"], player_spawn["rot"]):
		return false
	enemy_ai.clear()
	enemy_tier.clear()
	_enemy_serial = 0
	_enemies_spawned = 0
	_enemy_reinforce_timer = 0.0
	var count := mini(enemy_count_for(wave), enemy_quota_for(wave))
	var tier := tier_for(wave)
	for index in range(count):
		if _spawn_enemy(index, count, tier):
			_enemies_spawned += 1
	_generate_props()
	stage = STAGE_BATTLE
	return true

## 生成一台敌人。返回是否真的加入了 duel（配额计数只能用真实结果，不能预先 ++）。
func _spawn_enemy(index: int, total: int, tier: String) -> bool:
	_enemy_serial += 1
	var tag := "enemy_%d" % _enemy_serial
	var enemy_builder := GridBuilder.new()
	if not enemy_builder.setup(definitions):
		return false
	enemy_builder.budget_enabled = false
	enemy_builder.credits_total = 1000000
	## 蓝图自带 `economy.mass_cap_level`（Boss 蓝图是 Lv.5），
	## `load_blueprint()` 会拒绝高于当前等级的需求，所以先抬到上限。
	enemy_builder.mass_cap_level = definitions.global_int("mass_cap_max_level", 5)
	var blueprint := _blueprint_for(tier, _enemy_serial)
	if blueprint.is_empty():
		return false
	if not enemy_builder.load_blueprint(blueprint).is_empty():
		return false
	var spawn := _enemy_spawn(index, total)
	if not duel.add_side(tag, enemy_builder, spawn["pos"], spawn["rot"], Duel.TEAM_ENEMY):
		return false
	var brain := BotAI.new()
	brain.setup(definitions, tier, _rng_state + _enemy_serial * 7919)
	brain.self_tag = tag
	brain.target_tag = Duel.TAG_PLAYER
	enemy_ai[tag] = brain
	enemy_tier[tag] = tier
	return true

## 蓝图池：Boss 波优先 `boss_*`，否则按档位取 `bot_<tier>_*`，按序号取模循环。
func _blueprint_for(tier: String, serial: int) -> Dictionary:
	var prefix := "boss_" if is_boss_wave() else "bot_%s_" % tier
	var ids: Array = []
	for raw_id in definitions.registry.blueprints.keys():
		if String(raw_id).begins_with(prefix):
			ids.append(String(raw_id))
	ids.sort()
	if ids.is_empty():
		return {}
	return definitions.get_blueprint(String(ids[posmod(serial - 1, ids.size())]))

## 玩家出生点：竞技场 `expedition_spawns.player`，缺省退回 `spawns[0]`。
func _player_spawn() -> Dictionary:
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var data: Dictionary = arena.get("expedition_spawns", {})
	var player: Dictionary = data.get("player", {})
	if player.is_empty():
		var spawns: Array = arena.get("spawns", [])
		if not spawns.is_empty():
			player = spawns[0]
	var raw: Array = player.get("pos", [20, 36])
	return {"pos": Vector2(float(raw[0]), float(raw[1])) * cell, "rot": deg_to_rad(float(player.get("rot", 0)))}

## 敌人出生点：`spawns[1]` 为基准，多台敌人沿 y 轴等距展开，避免互相重叠。
func _enemy_spawn(index: int, total: int) -> Dictionary:
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var spawns: Array = arena.get("spawns", [])
	var base: Dictionary = spawns[1] if spawns.size() > 1 else {"pos": [108, 36], "rot": 180}
	var raw: Array = base.get("pos", [108, 36])
	var x := float(raw[0])
	var y := float(raw[1])
	if total > 1:
		## 以基准 y 为中心，按 14 格间距展开，并夹在竞技场内。
		var span := 14.0
		var offset := (float(index) - float(total - 1) * 0.5) * span
		var size: Array = arena.get("size", [128, 72])
		var margin := 8.0
		y = clampf(y + offset, margin, float(size[1]) - margin)
	return {"pos": Vector2(x, y) * cell, "rot": deg_to_rad(float(base.get("rot", 180)))}

# ─── 道具：房屋与残骸（design §3.4.4）────────────────────────────────────────

## 每波按竞技场 `props` 重新生成，上一波没吃完的不保留（避免跨波套利）。
func _generate_props() -> void:
	houses.clear()
	debris.clear()
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var props: Dictionary = arena.get("props", {})
	var house_cells: Array = props.get("houses", [])
	var debris_cells: Array = props.get("debris", [])
	var limit := mini(_props_houses, house_cells.size())
	for index in range(limit):
		var raw: Array = house_cells[index]
		var grid := Vector2i(int(raw[0]), int(raw[1]))
		houses.append({
			"cell": grid,
			"rect": Rect2(Vector2(grid) * cell, Vector2(cell * 2.0, cell * 2.0)),
			"hp": _house_hp,
			"hp_max": _house_hp,
			"armor": _house_armor,
			"alive": true,
		})
	var debris_limit := mini(_props_debris, debris_cells.size())
	for index in range(debris_limit):
		var raw: Array = debris_cells[index]
		debris.append({
			"cell": Vector2i(int(raw[0]), int(raw[1])),
			"taken": false,
			"payout_kind": "credit" if _next_unit() < _debris_credit_share else "xp",
			"is_house": false,
		})

## 房屋矩形并入 duel 的障碍表，使坦克撞上时被挡住（design §3.4.4 / Q33）。
func _sync_house_obstacles() -> void:
	if duel == null:
		return
	var merged: Array = []
	var arena: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	## 竞技场固定障碍先入表（下标 0..n-1），房屋追加在后面；
	## 命中事件里的 obstacle_index 能直接映射回这里。
	for raw_obstacle in arena.get("obstacles", []):
		var obstacle: Dictionary = raw_obstacle
		if obstacle.has("rect"):
			var r: Array = obstacle["rect"]
			merged.append({"shape": "rect", "rect": Rect2(Vector2(float(r[0]), float(r[1])) * cell, Vector2(float(r[2]), float(r[3])) * cell)})
		elif obstacle.has("circle"):
			var c: Array = obstacle["circle"]
			merged.append({"shape": "circle", "center": Vector2(float(c[0]), float(c[1])) * cell, "radius": float(c[2]) * cell})
	_house_obstacle_offset = merged.size()
	for house in houses:
		if not bool(house["alive"]):
			continue
		merged.append({"shape": "rect", "rect": Rect2(house["rect"])})
	duel.obstacles = merged

# ─── 战斗推进 ─────────────────────────────────────────────────────────────────

## 单帧推进。返回本帧事件（供 HUD 与统计）。
func step_battle(dt: float) -> Array[Dictionary]:
	var frame_events: Array[Dictionary] = []
	if stage != STAGE_BATTLE or duel == null or dt <= 0.0:
		return frame_events
	_sync_house_obstacles()
	var tags: Array = enemy_ai.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if duel.defeated(tag):
			continue
		var brain: BotAI = enemy_ai[tag]
		var decision := brain.think(dt, duel)
		duel.set_input(tag, float(decision["throttle"]), float(decision["steer"]))
		if bool(decision["fire"]):
			duel.fire(tag)
	duel.step(dt)
	total_damage = float(duel.damage_dealt.get(Duel.TAG_PLAYER, 0.0))
	frame_events.append_array(duel.drain_events())
	_resolve_house_hits(frame_events)
	_resolve_rammed_houses()
	_resolve_debris_crush()
	_reap_enemies(frame_events)
	_reinforce_enemies(dt)
	wave_time_left = maxf(0.0, wave_time_left - dt)
	if duel.defeated(Duel.TAG_PLAYER):
		run_over = true
		stage = STAGE_SUMMARY
		return frame_events
	if not wave_passed:
		## 通过条件（用户 2026-10-21 变更）：计时归零，**或**「本波配额已全部生成完」且场上无敌人。
		## 旧规则是「场上没敌人就立即通过」——那样补兵永远来不及发生：敌人一被杀光就过关。
		## 所以必须把「配额」与「场上」两个条件分开：配额未尽就不能提前结束。
		var quota_spent := _enemies_spawned >= enemy_quota_for(wave)
		var cleared := duel.alive_in_team(Duel.TEAM_ENEMY).is_empty()
		if wave_time_left <= 0.0 or (quota_spent and cleared):
			## 本波通过。未清完的敌人不跨波保留（design §3.4）：下一波 start_wave() 会重建 duel，
			## 所以这里不需要（也不能）改动当前 duel 的 sides。
			wave_passed = true
			_enemy_serial = 0
			_enemies_spawned = 0
			_enemy_reinforce_timer = 0.0
			_enter_intermission(frame_events)
	return frame_events

## 本波内持续补兵（用户 2026-10-21：「敌人不断地生成」）。
## 只在「场上存活 < 同屏上限」且「已生成 < 本波配额」时才补；满员时把倒计时重置，
## 空位一出现就从完整间隔开始计时，而不是立刻补一台。
## 用倒计时而不是「死了当场补」：一是给玩家吹口气的窗口，二是避免击杀与生成落在同一帧，
## 使事件顺序难以复现。
func _reinforce_enemies(dt: float) -> void:
	if is_boss_wave():
		return
	var quota := enemy_quota_for(wave)
	if _enemies_spawned >= quota:
		return
	var cap := enemy_count_for(wave)
	var alive := duel.alive_in_team(Duel.TEAM_ENEMY).size()
	if alive >= cap:
		_enemy_reinforce_timer = _enemy_reinforce_delay_s
		return
	_enemy_reinforce_timer -= dt
	if _enemy_reinforce_timer > 0.0:
		return
	## 补兵按 `_enemies_spawned` 轮换出生点：直接用「当前存活台数」做下标的话，
	## 玩家杀了哪台就影响下一台的落点，落点会随操作漂移。
	var slot := _enemies_spawned % maxi(cap, 1)
	if _spawn_enemy(slot, cap, tier_for(wave)):
		_enemies_spawned += 1
	_enemy_reinforce_timer = _enemy_reinforce_delay_s

## 炮击房屋：弹道命中障碍时，若该障碍是房屋则扣血。
func _resolve_house_hits(frame_events: Array[Dictionary]) -> void:
	for event in frame_events:
		if String(event.get("kind", "")) != "impact":
			continue
		if String(event.get("target", "")) != "obstacle":
			continue
		var index := int(event.get("obstacle_index", -1))
		## 房屋在 obstacles 表里排在竞技场固定障碍之后，需要减去偏移量。
		var house_index := index - _house_obstacle_offset
		if house_index < 0 or house_index >= houses.size():
			continue
		var house: Dictionary = houses[house_index]
		if not bool(house["alive"]):
			continue
		var ammo_id := String(event.get("ammo_id", ""))
		var ammo: Dictionary = definitions.get_ammo(ammo_id)
		var raw := float(ammo.get("base_damage", 0.0))
		var scale := float(event.get("damage_scale", 1.0))
		_damage_house(house, raw * scale, frame_events)

func _damage_house(house: Dictionary, raw: float, frame_events: Array[Dictionary]) -> void:
	if raw <= 0.0:
		return
	var armor := float(house["armor"])
	## design §8.3 同一条公式：`max(dmg·0.15, dmg − armor)`，与坦克部件一致。
	var dealt := maxf(raw * 0.15, raw - armor)
	house["hp"] = maxf(0.0, float(house["hp"]) - dealt)
	if float(house["hp"]) > 0.0:
		return
	## 归零即摧毁：给钱 + 给经验，并按概率掉落配件。
	house["alive"] = false
	houses_destroyed += 1
	credit += _credit_per_house
	_add_xp(_xp_per_house)
	frame_events.append({"kind": "house_destroyed", "cell": house["cell"]})
	if _next_unit() < _house_drop_chance:
		_grant_random_module()
	## 摧毁后留下残骸格，可再被碾过一次（二次收益，量小于直接摧毁）。
	debris.append({
		"cell": house["cell"],
		"taken": false,
		"payout_kind": "credit",
		"is_house": true,
	})

## 碾过残骸：玩家坦克格与残骸格重叠即拾取，不消耗时间也不减速（design §3.4.4）。
func _resolve_debris_crush() -> void:
	var tank: TankBody = duel.tank_of(Duel.TAG_PLAYER)
	if tank == null:
		return
	## 残骸用的是竞技场格坐标，坦克占用的是建造格坐标，两者不在同一坐标系：
	## 必须先把双方都换算成世界坐标再比较（旧码把竞技场格直接当成坦克局部格传入
	## `world_position_of_cell`，得到的根本不是残骸的世界位置）。
	## 判定取「任一所占格」而不是质心距离：6 格长的车车头已经压上残骸时，
	## 质心仍在 0.75 格之外，用质心距离会捡不到。
	var cell_size := tank.cell_size()
	var limit := cell_size * 0.75
	var centres: Array[Vector2] = []
	for entry in tank.cells:
		centres.append(tank.world_position_of_cell(Vector2i(entry["cell"])))
	for item in debris:
		if bool(item["taken"]):
			continue
		var world := (Vector2(Vector2i(item["cell"])) + Vector2(0.5, 0.5)) * cell_size
		var crushed := false
		for centre in centres:
			if centre.distance_to(world) <= limit:
				crushed = true
				break
		if not crushed:
			continue
		item["taken"] = true
		debris_taken += 1
		if bool(item["is_house"]):
			credit += _house_debris_credit
			continue
		if String(item["payout_kind"]) == "credit":
			credit += _roll_between(_debris_credit_min, _debris_credit_max)
		else:
			_add_xp(_roll_between(_debris_xp_min, _debris_xp_max))
		if _next_unit() < _debris_drop_chance:
			_grant_random_module()

## 撞击房屋：玩家坦克的**真实格轮廓**与房屋相交且速度足够时扣血（design §3.4.4）。
## 只有玩家会撞房屋——敌人 AI 的目标是玩家，不去拆房子。
## **v3.20 改用逐格**：旧版用 `world_bounds()` 外接框相交就扣血，车头没碰到房子
## （只是外接框的虚空角逼近了房子）也会扣血。现在要求至少有一个真实格压在房屋矩形上。
func _resolve_rammed_houses() -> void:
	var tank: TankBody = duel.tank_of(Duel.TAG_PLAYER)
	if tank == null:
		return
	var speed: float = tank.velocity.length()
	if speed <= _wall_min_speed:
		return
	for house in houses:
		if not bool(house["alive"]):
			continue
		var overlap := tank.cell_overlap_rect(Rect2(house["rect"]))
		if not bool(overlap["hit"]):
			continue
		var raw: float = _wall_base + _wall_per_speed * speed
		_damage_house(house, raw, [])

## 结算已被击毁的敌人：给钱、给经验、按概率掉落它自己的一个配件（design §3.4.4 / Q31）。
func _reap_enemies(frame_events: Array[Dictionary]) -> void:
	var tags: Array = enemy_ai.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if not duel.defeated(tag):
			continue
		if bool(duel.sides[tag].get("reaped", false)):
			continue
		duel.sides[tag]["reaped"] = true
		kills += 1
		if is_boss_wave():
			credit += _boss_credit_reward
			_add_xp(_boss_xp_reward)
			for index in range(_boss_drop_count):
				_grant_random_module()
		else:
			credit += _credit_per_kill
			_add_xp(_xp_per_kill)
			if _next_unit() < _enemy_drop_chance:
				_grant_enemy_module(tag)
		frame_events.append({"kind": "enemy_defeated", "tag": tag})

# ─── 资源与升级 ───────────────────────────────────────────────────────────────

## 升到下一级所需经验：`XP(n) = base + step × (n − 1)`（design §14.8）。
func xp_needed_for(current_level: int) -> float:
	return _xp_base + _xp_step * float(current_level - 1)

## 加经验并逐级结算；溢出到下一级，不丢弃（design §3.4.1）。
## 每升一级都记一笔 `pending_level_ups`——升级菜单的触发依据是这个计数，
## 不是再算一遍剩余经验（那样永远为 0，因为循环已经把等级抬完了，菜单永远弹不出来）。
func _add_xp(amount: float) -> void:
	if amount <= 0.0:
		return
	experience += amount
	xp_into_level += amount
	while xp_into_level >= xp_needed_for(level):
		xp_into_level -= xp_needed_for(level)
		level += 1
		pending_level_ups += 1

## 本波结束后：有未处理的升级就先弹升级菜单，否则直接进商店。
func _enter_intermission(frame_events: Array[Dictionary]) -> void:
	if _pending_level_ups() > 0:
		_open_level_up()
		frame_events.append({"kind": "level_up_opened", "level": level})
	else:
		_open_shop()

## 还没发出去的升级次数（每次领取一份就减一）。
func _pending_level_ups() -> int:
	return pending_level_ups

## 生成三选一候选：新配件 / 已装模块升级 / 免费质量上限 +1（design §3.4.2）。
func _open_level_up() -> void:
	stage = STAGE_LEVEL_UP
	level_choices.clear()
	var pool: Array = []
	for raw_id in definitions.registry.modules.keys():
		pool.append(String(raw_id))
	pool.sort()
	var attempts := 0
	while level_choices.size() < _choice_count and attempts < _choice_count * 8:
		attempts += 1
		var roll := _next_unit()
		var kind := CHOICE_MODULE
		if roll < 0.2:
			kind = CHOICE_MASS_CAP
		elif roll < 0.45:
			kind = CHOICE_UPGRADE
		if kind == CHOICE_MASS_CAP:
			if _has_choice(CHOICE_MASS_CAP, ""):
				continue
			level_choices.append({"kind": CHOICE_MASS_CAP, "id": "", "label": "质量上限 +1 级", "price": 0.0})
			continue
		if kind == CHOICE_UPGRADE:
			var upgrade_ids: Array = definitions.registry.upgrades.keys()
			upgrade_ids.sort()
			if upgrade_ids.is_empty():
				continue
			var pick := String(upgrade_ids[int(_next_unit() * float(upgrade_ids.size())) % upgrade_ids.size()])
			if _has_choice(CHOICE_UPGRADE, pick):
				continue
			var def: Dictionary = definitions.registry.get_upgrade(pick)
			level_choices.append({"kind": CHOICE_UPGRADE, "id": pick, "label": String(def.get("name", pick)), "price": 0.0})
			continue
		if pool.is_empty():
			continue
		var module_id := String(pool[int(_next_unit() * float(pool.size())) % pool.size()])
		if _has_choice(CHOICE_MODULE, module_id):
			continue
		var module: Dictionary = definitions.get_module(module_id)
		level_choices.append({"kind": CHOICE_MODULE, "id": module_id, "label": String(module.get("name", module_id)), "price": 0.0})

func _has_choice(kind: String, module_id: String) -> bool:
	for raw in level_choices:
		var entry: Dictionary = raw
		if String(entry["kind"]) == kind and String(entry["id"]) == module_id:
			return true
	return false

## 选一张卡。三选一**不可跳过**（Q23）：索引非法时返回 false，调用方必须重选。
func take_level_choice(index: int) -> bool:
	if stage != STAGE_LEVEL_UP:
		return false
	if index < 0 or index >= level_choices.size():
		return false
	var entry: Dictionary = level_choices[index]
	match String(entry["kind"]):
		CHOICE_MASS_CAP:
			if builder != null:
				builder.mass_cap_level += 1
			upgrade_note = "质量上限 +1 级"
		CHOICE_UPGRADE:
			upgrade_note = _install_upgrade(String(entry["id"]))
		_:
			inventory.append(String(entry["id"]))
			upgrade_note = "配件已进库存"
	level_choices.clear()
	## 每领一份就消耗一次待处理升级；还有剩余就继续三选一，否则进商店。
	pending_level_ups = maxi(pending_level_ups - 1, 0)
	if _pending_level_ups() > 0:
		_open_level_up()
	else:
		_open_shop()
	return true
# ─── 升级落地（v3.24）──────────────────────────────────────────────────────

## 把一张升级卡装进坦克上某个改进装置的空槽。返回给 UI 看的反馈文本。
##
## 设计约束（用户 2026-10-17 的原始需求）：升级是**实体模块上的槽配置**，
## 不是抽象的整台增益。所以这里必须真的写进某件 `modifier_mk1/2/3` 的 `part["upgrades"]`，
## 而且选择顺序是确定的：按 `module_parts` 数组顺序取第一件“还有空槽”的改进装置。
##
## 没有可用槽位时**不得凭空生效**：升级 id 进 `collected_upgrades` 暂存，
## 等玩家在改装页装了改进器后再用；同时返回明确文案，让玩家知道没装上。
func _install_upgrade(upgrade_id: String) -> String:
	if builder == null or definitions == null:
		collected_upgrades.append(upgrade_id)
		return "没有可用的改进装置，升级已暂存（%s）" % upgrade_id
	for part in builder.module_parts:
		var def: Dictionary = definitions.get_module(String(part.get("id", "")))
		if not def.has("upgrade_slots"):
			continue
		var slots := maxi(int(def.get("upgrade_slots", 1)), 1)
		var current: Array = (part.get("upgrades", []) as Array).duplicate()
		if current.size() >= slots:
			continue
		current.append(upgrade_id)
		part["upgrades"] = current
		return "已装入 %s（%d/%d）" % [String(def.get("name", part["id"])), current.size(), slots]
	collected_upgrades.append(upgrade_id)
	return "没有空槽的改进装置，升级已暂存（%s）" % upgrade_id

## 把暂存池里的升级尽量装进现有改进装置。改装页进出时调一次。
## 返回实际装上的数量；装不下的仍留在池里。
##
## 实现注意：`_install_upgrade()` 在装不下时**会自己 append 到 `collected_upgrades`**，
## 所以不能边遍历边让它写回同一个数组（会把失败项重复压入）。这里先清空、再逐条试。
func flush_collected_upgrades() -> int:
	if collected_upgrades.is_empty():
		return 0
	var pending: Array[String] = collected_upgrades.duplicate()
	collected_upgrades.clear()
	var installed := 0
	for upgrade_id in pending:
		var before := collected_upgrades.size()
		_install_upgrade(upgrade_id)
		if collected_upgrades.size() == before:
			installed += 1
	return installed

## 只读：本车当前装上的升级（按改进装置槽逐条展开），供 HUD / 改装页展示。
func installed_upgrades() -> Array:
	var result: Array = []
	if builder == null:
		return result
	for part in builder.module_parts:
		for raw in (part.get("upgrades", []) as Array):
			result.append(String(raw))
	return result

# ─── 商店（design §3.4.3）─────────────────────────────────────────────────────

func _open_shop() -> void:
	stage = STAGE_SHOP
	shop_rerolls = 0
	_roll_shop()

## 只读访问器：UI 需要展示刷新价与出售回收率，不应直接读缓存字段。
func shop_reroll_cost() -> float:
	return _shop_reroll_cost

func shop_sell_rate() -> float:
	return _shop_sell_rate

## 整体重掷 6 个商品位；同一次刷新内不重复（design §3.4.3）。
func _roll_shop() -> void:
	shop_slots.clear()
	var pool: Array = []
	for raw_id in definitions.registry.modules.keys():
		var def: Dictionary = definitions.get_module(String(raw_id))
		if float(def.get("price", 0.0)) <= 0.0:
			continue
		pool.append(String(raw_id))
	pool.sort()
	if pool.is_empty():
		return
	var chosen := {}
	var guard := 0
	while shop_slots.size() < _shop_slot_count and guard < _shop_slot_count * 16:
		guard += 1
		var module_id := String(pool[int(_next_unit() * float(pool.size())) % pool.size()])
		if chosen.has(module_id):
			continue
		chosen[module_id] = true
		var def: Dictionary = definitions.get_module(module_id)
		var price := float(def.get("price", 0.0)) * _rarity_multiplier(float(def.get("price", 0.0)))
		shop_slots.append({"kind": "module", "id": module_id, "price": price, "sold": false})

## 稀有度按价格分档加权（design §14.8 `SHOP_RARITY_WEIGHT`）：
## 普通 = 权重 0、稀有 = 权重 1、史诗 = 权重 2，取当前价所在档的倍率。
func _rarity_multiplier(price: float) -> float:
	var tier := 0
	if price > _shop_rare_max:
		tier = 2
	elif price > _shop_common_max:
		tier = 1
	var total := 0.0
	for raw in _shop_weights:
		total += float(raw)
	if total <= 0.0:
		return 1.0
	var weight := float(_shop_weights[mini(tier, _shop_weights.size() - 1)])
	return 1.0 + weight / total

## 花 `credit` 重掷全部商品位；价格不随次数递增（Q30）。
func reroll_shop() -> bool:
	if stage != STAGE_SHOP:
		return false
	if credit < _shop_reroll_cost:
		return false
	credit -= _shop_reroll_cost
	shop_rerolls += 1
	_roll_shop()
	return true

## 购买第 index 格：配件进 inventory，不自动贴装（design §3.4.2）。
func buy_shop_slot(index: int) -> bool:
	if stage != STAGE_SHOP:
		return false
	if index < 0 or index >= shop_slots.size():
		return false
	var slot: Dictionary = shop_slots[index]
	if bool(slot["sold"]):
		return false
	var price := float(slot["price"])
	if credit < price:
		return false
	credit -= price
	slot["sold"] = true
	inventory.append(String(slot["id"]))
	return true

## 出售 inventory 里的第 index 件，回收 `price × SHOP_SELL_RATE`。
## **已装在坦克上的配件不可出售**——想卖先拆（design §3.4.3）。
func sell_inventory(index: int) -> bool:
	if stage != STAGE_SHOP:
		return false
	if index < 0 or index >= inventory.size():
		return false
	var module_id := inventory[index]
	var def: Dictionary = definitions.get_module(module_id)
	var price := float(def.get("price", 0.0)) * _shop_sell_rate
	inventory.remove_at(index)
	credit += price
	return true

## 改装入口：只有 LEVEL_UP 与 SHOP 可以进（design §3.4 表格「战斗期禁止改装」）。
func enter_modification() -> bool:
	if builder == null:
		return false
	if stage != STAGE_LEVEL_UP and stage != STAGE_SHOP:
		return false
	modify_return_stage = stage
	## 生存 builder 的 `budget_enabled` 是 false（钱由 run 记，不交给 GridBuilder），
	## 所以这里必须自己取基线，不能指望 credits_total 兜底。
	modify_credit_baseline = builder.credits_spent()
	stage = STAGE_MODIFY
	## v3.24：进入改装就先把暂存池里能装的升级尽量装进现有改进装置。
	## 玩家刚刚可能在这一页之前买了/装了一台改进器，那时才有空槽。
	flush_collected_upgrades()
	return true

## 本次改装到目前为止的支出：按**净增**建造支出算。
## 拆下来的件退回库存、不返还金钱；同一件在原位换格再装回去等于零支出。
func modification_cost() -> float:
	if builder == null:
		return 0.0
	return maxf(builder.credits_spent() - modify_credit_baseline, 0.0)

## 离开改装页：结算支出并回到进入时的阶段。
func leave_modification() -> bool:
	if stage != STAGE_MODIFY:
		return false
	commit_modification()
	stage = modify_return_stage if not modify_return_stage.is_empty() else STAGE_SHOP
	modify_return_stage = ""
	return true

## 把 inventory 里的一件装到坦克上（只在改装期调用）。成功则从库存移除。
## 按模块自身的层分发：行进机构走 `place_mobility()`，其余走 `place_module()`。
func mount_from_inventory(index: int, cell: Vector2i, rot: int = 0, aim: int = 0) -> String:
	if stage != STAGE_MODIFY:
		return "只有在改装页才能贴装配件。"
	if builder == null:
		return "无建造模型"
	if index < 0 or index >= inventory.size():
		return "库存索引越界"
	var module_id := inventory[index]
	var layer := String(definitions.get_module(module_id).get("layer", "module"))
	var reason := builder.place_mobility(module_id, cell, rot) if layer == "mobility" else builder.place_module(module_id, cell, rot, aim)
	if not reason.is_empty():
		return reason
	## 付不起就撤回：`undo()` 连 `_credits_spent` 一起回滚，净支出口径保持一致。
	var cost := modification_cost()
	if cost > credit:
		builder.undo()
		return "拒绝：信用点不足（还差 %d cr）。" % int(ceilf(cost - credit))
	inventory.remove_at(index)
	return ""

## 改装页铺平台格：新配件需要有平台托着（I2）。价格走 `platform_cell_price`。
func place_platform_at(cell: Vector2i) -> String:
	if stage != STAGE_MODIFY:
		return "只有在改装页才能铺平台。"
	if builder == null:
		return "无建造模型"
	var reason := builder.place_platform_cell(cell)
	if not reason.is_empty():
		return reason
	var cost := modification_cost()
	if cost > credit:
		builder.undo()
		return "拒绝：信用点不足（还差 %d cr）。" % int(ceilf(cost - credit))
	return ""

## 改装页的拆解：模块 / 行进机构退回 inventory，平台格直接消失。
## 只按净增支出收费，所以拆解不返还金钱；但拆完结构必须仍然合法（I5 连通 / I8 至少一件行进机构）。
func dismantle_at(layer: String, cell: Vector2i) -> String:
	if stage != STAGE_MODIFY:
		return "只有在改装页才能拆解。"
	if builder == null:
		return "无建造模型"
	if layer == "platform":
		return builder.remove_at("platform", cell)
	var part_info: Dictionary = builder.part_at(layer, cell)
	if part_info.is_empty():
		return "当前层此格没有部件。"
	var module_id := String((part_info["part"] as Dictionary)["id"])
	var reason := builder.remove_at(layer, cell)
	if not reason.is_empty():
		return reason
	inventory.append(module_id)
	## `remove_at()` 只管同层占位，不管「最后一件行进机构」与「断开平台岛」——用完整报告兜底。
	var report: Dictionary = builder.validation_report()
	if not bool(report.get("ok", false)):
		var errors: Array = report.get("errors", [])
		inventory.pop_back()
		builder.undo()
		return "拒绝：拆解后结构非法 —— %s" % (String(errors[0]) if not errors.is_empty() else "校验未通过")
	return ""

## 改装结束：结算 credit 并推进基线。
## 结构本身由下一次 `start_wave()` 重建 Duel 时生效（`bind_player()` 只绑一次 builder，
## 布局与损伤因此天然跨波保留），所以这里不做坦克重建。
func commit_modification() -> void:
	if builder == null:
		return
	var cost := modification_cost()
	if cost > credit:
		cost = credit
	if cost > 0.0:
		credit -= cost
		modify_spent_total += cost
	modify_credit_baseline = builder.credits_spent()

# ─── 掉落 ─────────────────────────────────────────────────────────────────────

func _grant_random_module() -> void:
	var pool: Array = []
	for raw_id in definitions.registry.modules.keys():
		pool.append(String(raw_id))
	pool.sort()
	if pool.is_empty():
		return
	var module_id := String(pool[int(_next_unit() * float(pool.size())) % pool.size()])
	inventory.append(module_id)

## 掉落该敌人**蓝图里**已有的某个模块（Q31：与战损解耦，避免先打爆再杀就没得掉）。
func _grant_enemy_module(tag: String) -> void:
	if not duel.sides.has(tag):
		return
	var enemy_builder: GridBuilder = (duel.sides[tag] as Dictionary)["builder"]
	if enemy_builder == null:
		return
	var ids: Array = []
	for part in enemy_builder.module_parts:
		var module_id := String(part.get("id", ""))
		if module_id.is_empty():
			continue
		if not ids.has(module_id):
			ids.append(module_id)
	ids.sort()
	if ids.is_empty():
		return
	inventory.append(String(ids[int(_next_unit() * float(ids.size())) % ids.size()]))

# ─── 结算 ─────────────────────────────────────────────────────────────────────

## `RUN_SUMMARY` 数据：到达第几波、击杀、房屋、等级、资源（design §11.4.5）。
## **没有「通关」状态**——生存没有终点。
func summary() -> Dictionary:
	return {
		"wave_reached": wave,
		"wave_passed": wave_passed,
		"kills": kills,
		"houses": houses_destroyed,
		"debris": debris_taken,
		"level": level,
		"experience": experience,
		"credit": credit,
		"inventory": inventory.size(),
		"damage": total_damage,
		"boss_wave": is_boss_wave(),
	}

## run 结束：`credit`、`experience`、`inventory`、等级与质量上限等级**全部清零**（Q14 / Q20）。
func close_run() -> void:
	credit = 0.0
	experience = 0.0
	xp_into_level = 0.0
	level = 1
	inventory.clear()
	collected_upgrades.clear()
	upgrade_note = ""
	level_choices.clear()
	pending_level_ups = 0
	modify_return_stage = ""
	modify_credit_baseline = 0.0
	modify_spent_total = 0.0
	shop_slots.clear()
	shop_slots.clear()
	houses.clear()
	debris.clear()
	enemy_ai.clear()
	enemy_tier.clear()
	duel = null
	run_over = true
	stage = STAGE_SUMMARY

## 进入下一波（只在 SHOP 里调用）。
func start_next_wave() -> bool:
	if stage != STAGE_SHOP:
		return false
	wave += 1
	return start_wave()

# ─── 确定性随机 ───────────────────────────────────────────────────────────────

## 显式 LCG（数值取自 Numerical Recipes），状态完全由 seed 决定，录制种子即可复现。
func _next_unit() -> float:
	_rng_state = (_rng_state * 1664525 + 1013904223) % 4294967296
	return float(_rng_state) / 4294967296.0

func _roll_between(low: float, high: float) -> float:
	if high <= low:
		return low
	return low + (high - low) * _next_unit()
