extends RefCounted

## 多侧对局（design §3.1 BATTLE_PHASE、§8）。
## 每一侧各自持有建造模型 / 刚体 / 炮管 / 弹药网络 / 伤害结算，共用一张弹道场；
## 弹道事件按被打方的 tag 路由到被打的一方。纯逻辑、无绘制，可无头驱动与确定性复现。
##
## **N 侧（R18）**：`sides` 是任意 tag 集合，不再是固定两侧。每个 tag 属于一个 `team`，
## 同 team 的 tag 不互相攻击、但**仍然物理碰撞**（物理不区分阵营）。
## 所有遍历均按 tag 排序，保证多侧情形下的确定性。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")
const DamageSystem := preload("res://scripts/damage_system.gd")
const ProjectileField := preload("res://scripts/projectile_field.gd")

const TAG_PLAYER := "player"
## VERSUS 模式下对手侧的固定 tag（多敌人时仍以它作为首个敌人的默认 tag）。
const TAG_ENEMY := "enemy"

## design §3.4：单人波次生存只有一个玩家侧，敌人可以有多个且各自独立。
const TEAM_PLAYER := "player"
const TEAM_ENEMY := "enemy"

var definitions: ModuleDefs
var field: ProjectileField
var arena: Rect2 = Rect2(0.0, 0.0, 2048.0, 1152.0)
var obstacles: Array = []
## tag -> {builder, tank, bank, network, damage, team, throttle, steer, alive}
var sides: Dictionary = {}
## tag -> 该方已造成的伤害（design §3.3 超时判定比这个值）
var damage_dealt: Dictionary = {}
## 本帧事件（含 tag），供调用方做 HUD 与统计
var events: Array[Dictionary] = []
var time: float = 0.0

func setup(module_defs: ModuleDefs) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	field = ProjectileField.new()
	if not field.setup(definitions):
		return false
	## damage_dealt 不再预置固定两侧：side 加入时自动登记（见 add_side）。
	damage_dealt = {}
	return true

## 竞技场尺寸、障碍与出生点全部来自 data/arenas/*.json（design §9.2）。
func load_arena(arena_id: String) -> void:
	var data: Dictionary = definitions.get_arena(arena_id)
	if data.is_empty():
		var ids: Array = definitions.registry.arenas.keys()
		ids.sort()
		if ids.is_empty():
			return
		data = definitions.get_arena(String(ids[0]))
	var cell := definitions.global_number("cell_size", 16.0)
	var size: Array = data.get("size", [128, 72])
	arena = Rect2(Vector2.ZERO, Vector2(float(size[0]), float(size[1])) * cell)
	obstacles.clear()
	for raw_obstacle in data.get("obstacles", []):
		var obstacle: Dictionary = raw_obstacle
		if obstacle.has("rect"):
			var r: Array = obstacle["rect"]
			obstacles.append({
				"shape": "rect",
				"rect": Rect2(Vector2(float(r[0]), float(r[1])) * cell, Vector2(float(r[2]), float(r[3])) * cell),
				"hp": float(obstacle.get("hp", 0.0)),
				"armor": float(obstacle.get("armor", 0.0)),
			})
		elif obstacle.has("circle"):
			var c: Array = obstacle["circle"]
			obstacles.append({
				"shape": "circle",
				"center": Vector2(float(c[0]), float(c[1])) * cell,
				"radius": float(c[2]) * cell,
				"hp": float(obstacle.get("hp", 0.0)),
				"armor": float(obstacle.get("armor", 0.0)),
			})

## 竞技场数据里的 spawns 顺序：0 = 玩家侧，1 = 对手侧（§9.2「对称分布，初始朝向相向」）。
func spawn_point(arena_id: String, index: int) -> Dictionary:
	var data: Dictionary = definitions.get_arena(arena_id)
	var cell := definitions.global_number("cell_size", 16.0)
	var spawns: Array = data.get("spawns", [])
	if spawns.is_empty():
		return {"pos": Vector2(arena.size * 0.5), "rot": 0.0}
	var spawn: Dictionary = spawns[mini(index, spawns.size() - 1)]
	var raw: Array = spawn.get("pos", [0, 0])
	return {
		"pos": Vector2(float(raw[0]), float(raw[1])) * cell,
		"rot": deg_to_rad(float(spawn.get("rot", 0))),
	}

## 加入一个侧。`team` 缺省时按 tag 推断：`player` 归玩家队，其余全部归敌方队。
## 多敌人同屏时调用方显式传 `team`（通常都是 TEAM_ENEMY），tag 则各自唯一。
func add_side(tag: String, builder: GridBuilder, spawn_pos: Vector2, spawn_heading: float, team: String = "") -> bool:
	if definitions == null or builder == null:
		return false
	if tag.is_empty() or sides.has(tag):
		return false
	var resolved_team := team
	if resolved_team.is_empty():
		resolved_team = TEAM_PLAYER if tag == TAG_PLAYER else TEAM_ENEMY
	var tank := TankBody.new()
	if not tank.setup(definitions, builder):
		return false
	var bank := CannonBank.new()
	bank.setup(definitions, tank)
	var network := AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	network.bind_bank(bank)
	var damage := DamageSystem.new()
	damage.setup(definitions)
	damage.rebuild(tank, builder)
	damage.set_modifier_upgrades(tank)
	## design §8.5：撞墙伤害也走同一条连锁，殉爆 / detach / 判负才不会被跳过。
	tank.damage_router = Callable(damage, "apply_part_damage")
	tank.position = spawn_pos
	tank.heading = spawn_heading
	tank.velocity = Vector2.ZERO
	tank.angular_velocity = 0.0
	sides[tag] = {
		"builder": builder,
		"tank": tank,
		"bank": bank,
		"network": network,
		"damage": damage,
		"team": resolved_team,
		"throttle": 0.0,
		"steer": 0.0,
		"alive": true,
	}
	if not damage_dealt.has(tag):
		damage_dealt[tag] = 0.0
	return true

## 移除一个侧（波次结束时敌人撤离、或某侧被彻底清出局）。
func remove_side(tag: String) -> void:
	sides.erase(tag)

func team_of(tag: String) -> String:
	if not sides.has(tag):
		return ""
	return String((sides[tag] as Dictionary).get("team", TEAM_ENEMY))

## 按 team 汇总已造成伤害（design §3.3 超时判定在 N 侧下比的是队总和）。
func team_damage(team: String) -> float:
	var total := 0.0
	var tags: Array = sides.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if team_of(tag) != team:
			continue
		total += float(damage_dealt.get(tag, 0.0))
	return total

## 某队是否已全部阵亡（驾驶舱被毁）。队里没有任何侧时返回 false（没参战不等于已阵亡）。
func team_defeated(team: String) -> bool:
	var found := false
	var tags: Array = sides.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if team_of(tag) != team:
			continue
		found = true
		if not defeated(tag):
			return false
	return found

## 某队仍存活的 tag 列表（按 tag 排序，保证确定性）。
func alive_in_team(team: String) -> Array[String]:
	var result: Array[String] = []
	var tags: Array = sides.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if team_of(tag) != team:
			continue
		if not defeated(tag):
			result.append(tag)
	return result

## 某队中的敌人：从 `attacker` 视角看，所有**其他队**的存活 tag。
func hostiles_of(attacker: String) -> Array[String]:
	var own := team_of(attacker)
	var result: Array[String] = []
	var tags: Array = sides.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		if team_of(tag) == own:
			continue
		if not defeated(tag):
			result.append(tag)
	return result

func set_input(tag: String, throttle: float, steer: float) -> void:
	if not sides.has(tag):
		return
	var side: Dictionary = sides[tag]
	side["throttle"] = clampf(throttle, -1.0, 1.0)
	side["steer"] = clampf(steer, -1.0, 1.0)

func tank_of(tag: String) -> TankBody:
	if not sides.has(tag):
		return null
	return (sides[tag] as Dictionary)["tank"]

func damage_of(tag: String) -> DamageSystem:
	if not sides.has(tag):
		return null
	return (sides[tag] as Dictionary)["damage"]

func bank_of(tag: String) -> CannonBank:
	if not sides.has(tag):
		return null
	return (sides[tag] as Dictionary)["bank"]

func builder_of(tag: String) -> GridBuilder:
	if not sides.has(tag):
		return null
	return (sides[tag] as Dictionary)["builder"]

## 某侧的弹药网络。逐模块进度（制造 / 存量 / 加工 / 装填）全在这里，
## 页面层必须经由这个查询拿，不要伸手进 `sides` 字典。
func network_of(tag: String) -> AmmoNetwork:
	if not sides.has(tag):
		return null
	return (sides[tag] as Dictionary)["network"]

## 驾驶舱被毁即该方判负（design §3.3）。
func defeated(tag: String) -> bool:
	if not sides.has(tag):
		return true
	var side: Dictionary = sides[tag]
	var tank: TankBody = side["tank"]
	var damage: DamageSystem = side["damage"]
	return bool(damage.defeated) or bool(tank.destroyed)

func alive_tags() -> Array[String]:
	var result: Array[String] = []
	for tag in sides.keys():
		if not defeated(String(tag)):
			result.append(String(tag))
	result.sort()
	return result

## 开火：走该方炮管组与口径校验，炮弹带该方的升级聚合（design §8.6）。
func fire(tag: String) -> int:
	if not sides.has(tag):
		return 0
	var side: Dictionary = sides[tag]
	var bank: CannonBank = side["bank"]
	var tank: TankBody = side["tank"]
	var damage: DamageSystem = side["damage"]
	var fired := 0
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		var ammo_id := String(cannon["caliber"])
		if ammo_id.is_empty():
			continue
		var upgrades: Array = damage.cannon_upgrades(tank)
		var team := team_of(tag)
		var shots := bank.fire(ammo_id)
		for shot in shots:
			field.spawn(Vector2(shot["origin"]), Vector2(shot["dir"]), String(shot["ammo_id"]), tag, upgrades, 1.0, team)
			tank.apply_recoil(float(shot["recoil_px"]), Vector2(shot["dir"]), Vector2(shot["world_r"]))
			fired += 1
	return fired

func can_fire(tag: String) -> bool:
	if not sides.has(tag):
		return false
	var bank: CannonBank = (sides[tag] as Dictionary)["bank"]
	for cannon in bank.cannons:
		if bool(cannon["loaded"]) and float(cannon["reload_remaining"]) <= 0.0:
			return true
	return false

## 单个固定步长。所有随机性为零，容器按 tag 排序遍历，保证可确定性复现（design §10.4）。
func step(dt: float) -> Array[Dictionary]:
	var frame_events: Array[Dictionary] = []
	if definitions == null or dt <= 0.0:
		return frame_events
	var tags := sides.keys()
	tags.sort()
	for raw_tag in tags:
		var tag := String(raw_tag)
		var side: Dictionary = sides[tag]
		var tank: TankBody = side["tank"]
		var damage: DamageSystem = side["damage"]
		var bank: CannonBank = side["bank"]
		var network: AmmoNetwork = side["network"]
		if defeated(tag):
			tank.step(dt, 0.0, 0.0)
			continue
		var scale := damage.thrust_scale()
		tank.step(dt, float(side["throttle"]) * scale, float(side["steer"]) * scale)
		tank.apply_obstacles(obstacles)
		tank.apply_boundary(arena)
		bank.step(dt)
		network.step(dt)
		network.fill_cannons(bank)
	## design §8.7：坦克互撞。按 tag 排序两两处理，保证确定性（R17-9）。
	_resolve_tank_collisions(tags, frame_events)
	## R18：targets 必须带 team，弹道才能区分敌我。
	var targets: Array = []
	for raw_tag in tags:
		var tag := String(raw_tag)
		var damage: DamageSystem = (sides[tag] as Dictionary)["damage"]
		var payload: Dictionary = damage.target_payload(tank_of(tag), tag)
		payload["team"] = team_of(tag)
		targets.append(payload)
	var impacts := field.step(dt, arena, obstacles, targets)
	for raw_event in impacts:
		var event: Dictionary = raw_event
		frame_events.append(event)
		_resolve_impact(event)
	for raw_tag in tags:
		var tag := String(raw_tag)
		var damage: DamageSystem = (sides[tag] as Dictionary)["damage"]
		damage.step(dt)
		for raw_damage_event in damage.drain_events():
			var damage_event: Dictionary = raw_damage_event
			damage_event["side"] = tag
			frame_events.append(damage_event)
	time += dt
	events.append_array(frame_events)
	return frame_events

## 弹道命中按被打方的 tag 结算（design §8.2）；命中障碍只记录。
func _resolve_impact(event: Dictionary) -> void:
	if String(event.get("kind", "")) != "impact":
		return
	if String(event.get("target", "")) != "tank":
		return
	var victim := String(event.get("tag", ""))
	if not sides.has(victim):
		return
	var shooter := String(event.get("shooter", ""))
	var part_index := int(event.get("part_index", -1))
	if part_index < 0:
		return
	var side: Dictionary = sides[victim]
	var tank: TankBody = side["tank"]
	var damage: DamageSystem = side["damage"]
	var hit := damage.apply_hit(
		tank,
		Vector2i(event.get("cell", Vector2i.ZERO)),
		part_index,
		String(event.get("ammo_id", "")),
		event.get("upgrades", []),
		Vector2(event.get("normal", Vector2.ZERO)),
		float(event.get("damage_scale", 1.0))
	)
	var dealt := float(hit.get("damage", 0.0)) + float(hit.get("shield", 0.0))
	## v3.20：把**真实结算后的伤害**写回事件，供页面层做悬浮数字。
	## 必须在结算之后写：`apply_hit()` 可能走延迟爆炸分支，那时 `damage` 已经是
	## 预先算好的「过完护甲」值；直接拿弹药的 base_damage 会显示得偏高。
	## `shield` 单列，页面层据此把护盾吸收的数字换个颜色，不与本体的混为一谈。
	event["damage"] = float(hit.get("damage", 0.0))
	event["shield"] = float(hit.get("shield", 0.0))
	event["victim"] = victim
	if not damage_dealt.has(shooter):
		damage_dealt[shooter] = 0.0
	damage_dealt[shooter] = float(damage_dealt[shooter]) + dealt
	if bool(hit.get("core", false)):
		side["alive"] = false

## design §8.7：坦克互撞。按 tag 排序两两处理，顺序固定，保证确定性。
## 对撞伤害归因到"另一方"（撞人者与被撞者各吃一次，与 §8.7 的"分摊"一致）。
func _resolve_tank_collisions(tags: Array, frame_events: Array[Dictionary]) -> void:
	for i in range(tags.size()):
		for j in range(i + 1, tags.size()):
			var tag_a := String(tags[i])
			var tag_b := String(tags[j])
			var tank_a: TankBody = (sides[tag_a] as Dictionary)["tank"]
			var tank_b: TankBody = (sides[tag_b] as Dictionary)["tank"]
			if tank_a == null or tank_b == null:
				continue
			if tank_a.destroyed or tank_b.destroyed:
				continue
			var dealt := tank_a.apply_tank_collision(tank_b)
			if dealt <= 0.0:
				continue
			damage_dealt[tag_a] = float(damage_dealt.get(tag_a, 0.0)) + dealt
			damage_dealt[tag_b] = float(damage_dealt.get(tag_b, 0.0)) + dealt
			frame_events.append({"kind": "tank_collision", "a": tag_a, "b": tag_b, "damage": dealt})
			## 对撞可能导致驾驶舱被毁，与弹道命中一样同帧标死。
			if tank_a.destroyed:
				(sides[tag_a] as Dictionary)["alive"] = false
			if tank_b.destroyed:
				(sides[tag_b] as Dictionary)["alive"] = false

func drain_events() -> Array[Dictionary]:
	var drained: Array[Dictionary] = events.duplicate(true)
	events.clear()
	return drained

## 该方剩余的部件与平台格数，供 HUD 与结算面板使用（design §3.1 RESULT）。
func structure_summary(tag: String) -> Dictionary:
	if not sides.has(tag):
		return {"parts": 0, "cells": 0, "mass": 0.0}
	var side: Dictionary = sides[tag]
	var tank: TankBody = side["tank"]
	var builder: GridBuilder = side["builder"]
	return {
		"parts": tank.parts.size(),
		"cells": builder.platform_cells.size(),
		"mass": tank.mass_total,
	}
