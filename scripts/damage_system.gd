extends RefCounted

## M5 战斗结算（design §8.2–§8.8）。
## 纯逻辑、无绘制、可无头驱动：主场景与 headless smoke 共用同一份结算，保证可测。
## 玩法数值全部来自 data/*.json 的 global 块（经 global_number 读取），脚本内不内联。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")

const SHIELD_ACTIVE := "ACTIVE"
const SHIELD_BROKEN := "BROKEN"

## detach 的 4-连通邻居遍历顺序固定，BFS 结果才可复现（design §8.5）。
const NEIGHBOURS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]

## 殉爆与引擎爆炸会互相引爆，连锁必须有界。
const CHAIN_LIMIT := 8

var definitions: ModuleDefs
var events: Array[Dictionary] = []
## 被摧毁的格 → 剩余残骸秒数（design §8.5 第 4 步）。
var debris: Dictionary = {}
## 驾驶舱被摧毁即置位；main 侧同帧处理并停止后续连锁（design §8.5 第 6 步）。
var defeated: bool = false

var _tank: TankBody
var _builder: GridBuilder
## part_key → {index, key, module_id, rot, cells, centre, hp, hp_max, recharge_s, charge, state}
var _shields: Dictionary = {}
## part_key → {remaining, duration, dps, cells}
var _burn: Dictionary = {}
## part_key → 已累积的维修周期时间
var _repair_clock: Dictionary = {}
## 延迟爆炸队列，按入队序号结算（design §8.6 up_delay）。
var _pending: Array[Dictionary] = []
var _sequence: int = 0

var _slow_remaining: float = 0.0
var _slow_power: float = 1.0
## part_key → Array[String]，供测试直接注入改进装置的升级列表。
var _modifier_upgrades: Dictionary = {}

var _damage_floor: float = 0.15
var _pierce_cap: float = 0.8
var _shield_cell_radius: float = 1.0
var _shield_plate_w: int = 3
var _shield_plate_h: int = 2
var _shield_dome_radius: float = 4.0
var _repair_small_radius: float = 1.0
var _repair_field_radius: float = 2.0
var _repair_core_factor: float = 0.5
var _explosive_radius: float = 1.5
var _burn_duration: float = 3.0
var _slow_duration: float = 2.5
var _slow_factor: float = 0.7
var _delay_s: float = 0.8
var _depot_radius: float = 2.5
var _depot_damage_per_slot: float = 6.0
var _engine_radius: float = 1.5
var _engine_damage: float = 25.0
var _debris_lifetime: float = 3.0

func setup(module_defs: ModuleDefs) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	_damage_floor = definitions.global_number("damage_floor", 0.15)
	_pierce_cap = definitions.global_number("pierce_cap", 0.8)
	_shield_cell_radius = definitions.global_number("shield_cell_radius_cells", 1)
	_shield_plate_w = maxi(definitions.global_int("shield_plate_w", 3), 1)
	_shield_plate_h = maxi(definitions.global_int("shield_plate_h", 2), 1)
	_shield_dome_radius = definitions.global_number("shield_dome_radius_cells", 4)
	_repair_small_radius = definitions.global_number("repair_small_radius_cells", 1)
	_repair_field_radius = definitions.global_number("repair_field_radius_cells", 2)
	_repair_core_factor = definitions.global_number("repair_core_factor", 0.5)
	_explosive_radius = definitions.global_number("upgrade_explosive_radius_cells", 1.5)
	_burn_duration = definitions.global_number("burn_duration_s", 3.0)
	_slow_duration = definitions.global_number("slow_duration_s", 2.5)
	_slow_factor = definitions.global_number("slow_thrust_factor", 0.7)
	_delay_s = definitions.global_number("delay_explosion_s", 0.8)
	_depot_radius = definitions.global_number("depot_explosion_radius_cells", 2.5)
	_depot_damage_per_slot = definitions.global_number("depot_explosion_damage_per_slot", 6.0)
	_engine_radius = definitions.global_number("engine_explosion_radius_cells", 1.5)
	_engine_damage = definitions.global_number("engine_explosion_damage", 25.0)
	_debris_lifetime = definitions.global_number("debris_lifetime_s", 3.0)
	return true

## 结构变化（进入战斗、detach 之后）后重建护盾表；同名护盾保留 hp 与充能进度。
func rebuild(tank: TankBody, builder: GridBuilder) -> void:
	_tank = tank
	if builder != null:
		_builder = builder
	var previous := _shields
	_shields = {}
	if tank == null:
		_burn.clear()
		_repair_clock.clear()
		_slow_remaining = 0.0
		_slow_power = 1.0
		return
	for index in range(tank.parts.size()):
		var part: Dictionary = tank.parts[index]
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("shield_hp"):
			continue
		var key := String(part.get("key", ""))
		var shield_max := float(def.get("shield_hp", 0.0))
		var record := {
			"index": index,
			"key": key,
			"module_id": String(part["module_id"]),
			"rot": int(part["rot"]),
			"cells": (part["cells"] as Array).duplicate(),
			"centre": _part_centre_cell(part),
			"hp": shield_max,
			"hp_max": shield_max,
			"recharge_s": float(def.get("recharge_s", 0.0)),
			"charge": 0.0,
			"state": SHIELD_ACTIVE,
		}
		if previous.has(key):
			var old: Dictionary = previous[key]
			record["hp"] = float(old.get("hp", shield_max))
			record["charge"] = float(old.get("charge", 0.0))
			record["state"] = String(old.get("state", SHIELD_ACTIVE))
		_shields[key] = record
	_prune_by_parts()

func reset() -> void:
	events.clear()
	debris.clear()
	_shields.clear()
	_burn.clear()
	_repair_clock.clear()
	_pending.clear()
	_modifier_upgrades.clear()
	defeated = false
	_slow_remaining = 0.0
	_slow_power = 1.0
	_sequence = 0

func drain_events() -> Array:
	var drained: Array = events.duplicate()
	events.clear()
	return drained

## 减速状态对推力的乘数（design §8.8：整台坦克推力 × 0.7）。
func thrust_scale() -> float:
	return _slow_power if _slow_remaining > 0.0 else 1.0

## 供 projectile_field 使用的坦克求交载荷；cells 的键名在此从 local 映射为 centre_local。
func target_payload(tank: TankBody, tag: String) -> Dictionary:
	var cell_entries: Array = []
	if tank == null:
		return {}
	for entry in tank.cells:
		cell_entries.append({
			"cell": Vector2i(entry["cell"]),
			"part_index": int(entry["part_index"]),
			"centre_local": Vector2(entry["local"]),
		})
	return {
		"tag": tag,
		"origin": tank.position,
		"heading": tank.heading,
		"centroid_local": tank.centroid_local,
		"cell_half": tank.cell_size() * 0.5,
		"cells": cell_entries,
	}

func shields() -> Array:
	var result: Array = []
	var keys: Array = _shields.keys()
	keys.sort()
	for key in keys:
		var record: Dictionary = _shields[key]
		result.append({
			"key": String(key),
			"module_id": String(record["module_id"]),
			"state": String(record["state"]),
			"hp": float(record["hp"]),
			"hp_max": float(record["hp_max"]),
			"charge": float(record["charge"]),
			"recharge_s": float(record["recharge_s"]),
			"cells": (record["cells"] as Array).duplicate(),
		})
	return result

func statuses() -> Array:
	var result: Array = []
	var keys: Array = _burn.keys()
	keys.sort()
	for key in keys:
		var entry: Dictionary = _burn[key]
		result.append({
			"kind": "burn",
			"key": String(key),
			"cells": (entry["cells"] as Array).duplicate(),
			"remaining": float(entry["remaining"]),
			"duration": float(entry["duration"]),
		})
	if _slow_remaining > 0.0:
		result.append({
			"kind": "slow",
			"remaining": _slow_remaining,
			"duration": _slow_duration,
			"factor": _slow_power,
		})
	return result

## 整台聚合的改进升级列表（design §7.1 的简化为「整台聚合」，见 design §8.9）。
func cannon_upgrades(tank: TankBody) -> Array[String]:
	var result: Array[String] = []
	if tank == null or definitions == null:
		return result
	for part in tank.parts:
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("upgrade_slots"):
			continue
		var key := String(part.get("key", ""))
		var payload: Array = []
		if _modifier_upgrades.has(key):
			payload = _modifier_upgrades[key]
		elif part.has("upgrades"):
			payload = part["upgrades"]
		for raw in payload:
			var upgrade_id := String(raw)
			if not result.has(upgrade_id):
				result.append(upgrade_id)
	return result

## 把坦克上改进装置自带的 upgrades 收进聚合表；测试也可先注入再调用。
func set_modifier_upgrades(tank: TankBody) -> void:
	_modifier_upgrades.clear()
	if tank == null:
		return
	for part in tank.parts:
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("upgrade_slots"):
			continue
		if not part.has("upgrades"):
			continue
		var payload: Array = []
		for raw in part["upgrades"]:
			payload.append(String(raw))
		_modifier_upgrades[String(part.get("key", ""))] = payload

## 供测试或建造期 UI 直接指定某个改进装置的升级列表。
func inject_upgrades(part_key_value: String, upgrades: Array) -> void:
	var payload: Array = []
	for raw in upgrades:
		payload.append(String(raw))
	_modifier_upgrades[part_key_value] = payload

## 由 main 在收到 projectile impact 时调用。damage_scale 供 up_split 的子弹丸按比例结算。
func apply_hit(tank: TankBody, cell: Vector2i, part_index: int, ammo_id: String, upgrades: Array, dir: Vector2, damage_scale: float = 1.0) -> Dictionary:
	var result := {"applied": false, "cell": cell, "damage": 0.0, "shield": 0.0, "destroyed": "", "core": false}
	if tank == null or definitions == null:
		return result
	_tank = tank
	var ammo := definitions.get_ammo(ammo_id)
	var base := float(ammo.get("base_damage", 0.0))
	if base <= 0.0:
		return result
	var profile := _upgrade_profile(upgrades)
	profile["damage_scale"] = maxf(damage_scale, 0.0)
	var raw := base * (1.0 + float(profile["damage_mult"])) * maxf(damage_scale, 0.0)
	if float(profile["delay"]) > 0.0:
		## R17-7：上报的 damage 必须与真实扣血一致（即过完护甲的 `_final_damage`），
		## 否则 duel 的 damage_dealt 会高估，超时判胜偏向带 up_delay 的一方。
		## 护甲取值需要在延迟期间保持稳定，所以这里用目标格当前的部件预先算一次。
		var preview_target := _resolve_target(tank, cell)
		var preview := raw
		if preview_target >= 0:
			preview = _final_damage(tank.parts[preview_target], raw, float(profile["armor_pierce"]))
		_pending.append({
			"seq": _sequence,
			"time_left": float(profile["delay"]),
			"tank": tank,
			"cell": cell,
			"ammo_id": ammo_id,
			"damage": raw,
			"profile": profile,
			"dir": dir,
		})
		_sequence += 1
		events.append({"kind": "delay_armed", "cell": cell, "ammo_id": ammo_id})
		result["applied"] = true
		result["damage"] = preview
		return result
	return _strike(tank, cell, raw, profile, ammo_id, dir, result)

## 撞墙等环境伤害也走同一条连锁，否则殉爆与 detach 会被静默跳过。
func apply_part_damage(tank: TankBody, part_index: int, amount: float, tag: String = "impact") -> Dictionary:
	if tank == null:
		return {"destroyed": false}
	_tank = tank
	var killed: Dictionary = tank.damage_part(part_index, amount)
	if not bool(killed.get("destroyed", false)):
		return killed
	events.append({"kind": tag, "module_id": String(killed["module_id"]), "cells": (killed["cells"] as Array).duplicate()})
	_on_destroyed(tank, killed, 0)
	return killed

func step(dt: float) -> void:
	if dt <= 0.0:
		return
	_tick_shields(dt)
	if defeated:
		return
	_tick_pending(dt)
	if defeated:
		return
	_tick_burn(dt)
	if defeated:
		return
	_tick_slow(dt)
	_tick_repair(dt)
	_tick_debris(dt)

## ===== 结算核心 =====

func _strike(tank: TankBody, cell: Vector2i, raw: float, profile: Dictionary, ammo_id: String, dir: Vector2, result: Dictionary) -> Dictionary:
	var target := _resolve_target(tank, cell)
	if target < 0:
		return result
	result["applied"] = true
	result["cell"] = cell
	var damage := raw
	var shield := _shield_for_cell(cell)
	var shield_pierce := clampf(float(profile["shield_pierce"]), 0.0, _pierce_cap)
	if not shield.is_empty():
		## design §8.4：护盾与本体同时结算；p = 0 时本体吃 0，等于整发被护盾吃掉。
		var to_shield := damage * (1.0 - shield_pierce)
		var to_body := damage * shield_pierce
		shield["hp"] = float(shield["hp"]) - to_shield
		result["shield"] = to_shield
		events.append({"kind": "shield_hit", "cell": cell, "key": String(shield["key"]), "damage": to_shield})
		if float(shield["hp"]) <= 0.0:
			shield["hp"] = 0.0
			shield["state"] = SHIELD_BROKEN
			shield["charge"] = float(shield["recharge_s"])
			events.append({"kind": "shield_broken", "cell": cell, "key": String(shield["key"])})
		damage = to_body
	if damage <= 0.0:
		return result
	var part: Dictionary = tank.parts[target]
	var final := _final_damage(part, damage, float(profile["armor_pierce"]))
	result["damage"] = final
	var target_key := String(part.get("key", ""))
	if float(profile["explosive"]) > 0.0:
		_area_damage(tank, [cell], _explosive_radius, final * float(profile["explosive"]), 0, "explosion", float(profile["armor_pierce"]), target_key)
		if defeated:
			return result
	if float(profile["burn"]) > 0.0:
		_apply_burn(part, final * float(profile["burn"]), cell)
	if float(profile["slow"]) > 0.0:
		_apply_slow(float(profile["slow"]))
	if int(profile["split"]) > 0:
		events.append({
			"kind": "split",
			"count": int(profile["split"]),
			"scale": float(profile["split_scale"]),
			"ammo_id": ammo_id,
			"pos": tank.world_position_of_cell(cell),
			"dir": dir,
			"damage_scale": float(profile["damage_scale"]),
		})
	## R17-6：AOE 可能删掉了若干低索引部件，target 下标已失效。
	## 必须用 part_key 重新定位，否则会把直接命中伤害扣到另一件无关部件上。
	var live_target := _index_of_key(tank, target_key)
	if live_target < 0:
		return result
	var killed: Dictionary = tank.damage_part(live_target, final)
	if bool(killed.get("destroyed", false)):
		result["destroyed"] = String(killed["module_id"])
		result["core"] = bool(killed.get("core", false))
		_on_destroyed(tank, killed, 0)
	return result

func _final_damage(part: Dictionary, damage: float, pierce: float) -> float:
	var armor := float(part.get("armor", 0.0))
	var armor_eff := armor * (1.0 - clampf(pierce, 0.0, 1.0))
	var value := maxf(damage * _damage_floor, damage - armor_eff)
	return floorf(value * 10.0) / 10.0

## design §8.2：命中格上按 module → platform → mobility 取第一个存活部件。
func _resolve_target(tank: TankBody, cell: Vector2i) -> int:
	var module_index := -1
	var platform_index := -1
	var mobility_index := -1
	for entry in tank.cells:
		if Vector2i(entry["cell"]) != cell:
			continue
		var index := int(entry["part_index"])
		if index < 0 or index >= tank.parts.size():
			continue
		var kind := String(tank.parts[index]["kind"])
		if kind == TankBody.KIND_MODULE:
			if module_index < 0:
				module_index = index
		elif kind == TankBody.KIND_MOBILITY:
			if mobility_index < 0:
				mobility_index = index
		elif platform_index < 0:
			platform_index = index
	if module_index >= 0:
		return module_index
	if platform_index >= 0:
		return platform_index
	return mobility_index

func _upgrade_profile(upgrades: Array) -> Dictionary:
	var profile := {
		"damage_mult": 0.0,
		"split": 0,
		"split_scale": 0.0,
		"explosive": 0.0,
		"burn": 0.0,
		"slow": 0,
		"delay": 0.0,
		"shield_pierce": 0.0,
		"armor_pierce": 0.0,
	}
	if definitions == null or definitions.registry == null:
		return profile
	var counts: Dictionary = {}
	for raw in upgrades:
		var upgrade_id := String(raw)
		var def: Dictionary = definitions.registry.get_upgrade(upgrade_id)
		if def.is_empty():
			continue
		var effect := String(def.get("effect", ""))
		var limit := maxi(int(def.get("stack_limit", 1)), 1)
		var count := int(counts.get(effect, 0))
		if count >= limit:
			continue
		counts[effect] = count + 1
		var value := float(def.get("value", 0.0))
		match effect:
			"damage_multiplier":
				profile["damage_mult"] = float(profile["damage_mult"]) + value
			"split":
				profile["split"] = int(profile["split"]) + 1
				if float(profile["split_scale"]) <= 0.0:
					profile["split_scale"] = value
			"explosive":
				profile["explosive"] = float(profile["explosive"]) + value
			"burn":
				profile["burn"] = float(profile["burn"]) + value
			"slow":
				## design §8.8：每层把推力乘 slow_thrust_factor，这里只累计层数。
				profile["slow"] = int(profile["slow"]) + 1
			"delayed_explosion":
				profile["delay"] = _delay_s
			"shield_pierce":
				profile["shield_pierce"] = minf(float(profile["shield_pierce"]) + value, _pierce_cap)
			"armor_pierce":
				profile["armor_pierce"] = minf(float(profile["armor_pierce"]) + value, 1.0)
	return profile

## ===== 摧毁与连锁（design §8.5） =====

func _on_destroyed(tank: TankBody, info: Dictionary, depth: int) -> void:
	if defeated:
		return
	if bool(info.get("core", false)):
		## 驾驶舱判负优先：不再算殉爆、脱落与质量重算。
		defeated = true
		tank.destroyed = true
		events.append({"kind": "core_destroyed", "cells": (info["cells"] as Array).duplicate()})
		return
	var kind := String(info["kind"])
	var module_id := String(info["module_id"])
	var cells: Array = (info["cells"] as Array).duplicate()
	events.append({"kind": "destroyed", "module_id": module_id, "part_kind": kind, "cells": cells.duplicate()})
	if depth < CHAIN_LIMIT:
		_death_effect(tank, module_id, cells, depth)
	if defeated:
		return
	for raw in cells:
		debris[Vector2i(raw)] = _debris_lifetime
	## R17-5：护盾本体被摧毁时，护盾记录必须立即从 `_shields` 里剪掉。
	## 原先只在 `rebuild()` 时重建护盾表，而摧毁护盾本体不走 rebuild，
	## 于是已不存在的护盾会继续充能、并在充能结束后“复活”挡伤害。
	_prune_shields()
	if kind == TankBody.KIND_PLATFORM_CELL or kind == TankBody.KIND_PLATFORM_SHAPE:
		if depth < CHAIN_LIMIT:
			_drop_upper(tank, cells, depth)
		if defeated:
			return
		_detach(tank)

func _death_effect(tank: TankBody, module_id: String, cells: Array, depth: int) -> void:
	var def := definitions.get_module(module_id)
	if def.is_empty():
		return
	if def.has("capacity_slots"):
		var slots := float(def.get("capacity_slots", 0))
		_area_damage(tank, cells, _depot_radius, _depot_damage_per_slot * slots, depth, "depot_explosion", 0.0, "")
	elif def.has("turn_assist"):
		_area_damage(tank, cells, _engine_radius, _engine_damage, depth, "engine_explosion", 0.0, "")

## 平台格被摧毁时，装在其上的模块与行进机构一并摧毁（design §8.5）。
func _drop_upper(tank: TankBody, cells: Array, depth: int) -> void:
	var keys: Array[String] = []
	for part in tank.parts:
		var kind := String(part["kind"])
		if kind != TankBody.KIND_MODULE and kind != TankBody.KIND_MOBILITY:
			continue
		var occupied: Array = part["cells"]
		for raw in occupied:
			if _contains_cell(cells, Vector2i(raw)):
				keys.append(String(part.get("key", "")))
				break
	keys.sort()
	for key in keys:
		var index := _index_of_key(tank, key)
		if index < 0:
			continue
		var killed: Dictionary = tank.damage_part(index, 1.0e9)
		if not bool(killed.get("destroyed", false)):
			continue
		_on_destroyed(tank, killed, depth + 1)
		if defeated:
			return

## 以驾驶舱所在格为锚点做 4-连通搜索，主块之外的一切立即摧毁（design §8.5）。
func _detach(tank: TankBody) -> void:
	if _builder == null:
		return
	var anchors := _builder.cockpit_cells()
	if anchors.is_empty():
		return
	var main_island := _flood(anchors)
	if main_island.is_empty():
		return
	var occupancy: Dictionary = _builder.platform_occupancy()
	var lost_platform: Array[Vector2i] = []
	for raw in occupancy.keys():
		var cell := Vector2i(raw)
		if not main_island.has(cell):
			lost_platform.append(cell)
	lost_platform.sort()
	var lost_parts: Array = []
	for entry in [["mobility", _builder.mobility_parts], ["module", _builder.module_parts]]:
		var layer := String(entry[0])
		for part in (entry[1] as Array):
			var cells: Array = _builder.part_cells(part)
			for raw in cells:
				if not main_island.has(Vector2i(raw)):
					lost_parts.append({"layer": layer, "start": Vector2i(part.get("start", Vector2i.ZERO)), "id": String(part.get("id", ""))})
					break
	if lost_platform.is_empty() and lost_parts.is_empty():
		return
	for cell in lost_platform:
		_builder.force_remove("platform", cell)
		debris[cell] = _debris_lifetime
	for entry in lost_parts:
		_builder.force_remove(String(entry["layer"]), Vector2i(entry["start"]))
	events.append({"kind": "detach", "cells": lost_platform.duplicate(), "parts": lost_parts.size()})
	tank.rebuild(_builder)
	rebuild(tank, null)

func _flood(anchors: Array) -> Dictionary:
	var occupancy: Dictionary = _builder.platform_occupancy()
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = []
	for raw in anchors:
		var cell := Vector2i(raw)
		if occupancy.has(cell) and not visited.has(cell):
			visited[cell] = true
			queue.append(cell)
	var head := 0
	while head < queue.size():
		var current: Vector2i = queue[head]
		head += 1
		for offset in NEIGHBOURS:
			var next: Vector2i = current + Vector2i(offset)
			if visited.has(next) or not occupancy.has(next):
				continue
			visited[next] = true
			queue.append(next)
	return visited

## AOE：目标集合先按 part_key 排序再结算，不依赖 Dictionary 迭代顺序。
func _area_damage(tank: TankBody, source_cells: Array, radius: float, damage: float, depth: int, tag: String, pierce: float, exclude_key: String) -> void:
	if damage <= 0.0:
		return
	var keys: Array[String] = []
	for part in tank.parts:
		var key := String(part.get("key", ""))
		if key == exclude_key:
			continue
		if _part_within(part, source_cells, radius):
			keys.append(key)
	keys.sort()
	for key in keys:
		var index := _index_of_key(tank, key)
		if index < 0:
			continue
		var part: Dictionary = tank.parts[index]
		var amount := _final_damage(part, damage, pierce)
		if amount <= 0.0:
			continue
		var killed: Dictionary = tank.damage_part(index, amount)
		events.append({"kind": tag, "module_id": String(part["module_id"]), "cell": _first_cell(part), "damage": amount})
		if not bool(killed.get("destroyed", false)):
			continue
		## R17-8：这里不能再 append 一条 destroyed——`_on_destroyed()` 内部已经会发。
		## 原先两条都发，导致一次 AOE 击杀产生重复的 destroyed 事件（HUD 与 scrap 统计会重复计数）。
		_on_destroyed(tank, killed, depth + 1)
		if defeated:
			return

## ===== 状态效果（design §8.8） =====

func _apply_burn(part: Dictionary, total: float, cell: Vector2i) -> void:
	if total <= 0.0:
		return
	var key := String(part.get("key", ""))
	var dps := total / maxf(_burn_duration, 0.1)
	var existing: Dictionary = _burn.get(key, {})
	if existing.is_empty():
		_burn[key] = {
			"remaining": _burn_duration,
			"duration": _burn_duration,
			"dps": dps,
			"cells": (part["cells"] as Array).duplicate(),
		}
	else:
		## design §8.8：刷新时长，不叠伤害。
		existing["remaining"] = _burn_duration
		existing["dps"] = maxf(float(existing["dps"]), dps)
	events.append({"kind": "burn_applied", "key": key, "cell": cell})

func _apply_slow(stacks: float) -> void:
	## design §8.8：取最强值，不叠乘。
	var power := clampf(1.0 - stacks * (1.0 - _slow_factor), 0.1, 1.0)
	if _slow_remaining <= 0.0:
		_slow_power = power
	else:
		_slow_power = minf(_slow_power, power)
	_slow_remaining = _slow_duration
	events.append({"kind": "slow_applied", "factor": _slow_power})

func _tick_shields(dt: float) -> void:
	var keys: Array = _shields.keys()
	keys.sort()
	for key in keys:
		var record: Dictionary = _shields[key]
		if String(record["state"]) != SHIELD_BROKEN:
			continue
		record["charge"] = maxf(float(record["charge"]) - dt, 0.0)
		if float(record["charge"]) > 0.0:
			continue
		record["state"] = SHIELD_ACTIVE
		record["hp"] = float(record["hp_max"])
		events.append({"kind": "shield_restored", "key": String(key)})

func _tick_burn(dt: float) -> void:
	if _tank == null or _burn.is_empty():
		return
	var keys: Array = _burn.keys()
	keys.sort()
	for key in keys:
		var entry: Dictionary = _burn[key]
		entry["remaining"] = float(entry["remaining"]) - dt
		var index := _index_of_key(_tank, String(key))
		if index >= 0:
			var amount := float(entry["dps"]) * dt
			if amount > 0.0:
				var killed: Dictionary = _tank.damage_part(index, amount)
				if bool(killed.get("destroyed", false)):
					events.append({"kind": "burn_kill", "module_id": String(killed["module_id"]), "cells": (killed["cells"] as Array).duplicate()})
					_on_destroyed(_tank, killed, 0)
		if float(entry["remaining"]) <= 0.0 or index < 0:
			_burn.erase(key)
			events.append({"kind": "burn_expired", "key": String(key)})
		if defeated:
			return

func _tick_slow(dt: float) -> void:
	if _slow_remaining <= 0.0:
		return
	_slow_remaining = maxf(_slow_remaining - dt, 0.0)
	if _slow_remaining <= 0.0:
		_slow_power = 1.0
		events.append({"kind": "slow_expired"})

func _tick_pending(dt: float) -> void:
	if _pending.is_empty():
		return
	var due: Array[Dictionary] = []
	var keep: Array[Dictionary] = []
	for entry in _pending:
		entry["time_left"] = float(entry["time_left"]) - dt
		if float(entry["time_left"]) <= 0.0:
			due.append(entry)
		else:
			keep.append(entry)
	_pending = keep
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["seq"]) < int(b["seq"]))
	for entry in due:
		var tank: TankBody = entry["tank"]
		if tank == null or tank.destroyed:
			continue
		var result := {"applied": false, "cell": entry["cell"], "damage": 0.0, "shield": 0.0, "destroyed": "", "core": false}
		_strike(tank, Vector2i(entry["cell"]), float(entry["damage"]), entry["profile"], String(entry["ammo_id"]), Vector2(entry["dir"]), result)
		if defeated:
			return

func _tick_repair(dt: float) -> void:
	if _tank == null:
		return
	for part in _tank.parts:
		var def := definitions.get_module(String(part["module_id"]))
		if not def.has("repair_hp") or not def.has("period_s"):
			continue
		var key := String(part.get("key", ""))
		var period := maxf(float(def.get("period_s", 1.0)), 0.05)
		var clock := float(_repair_clock.get(key, 0.0)) + dt
		while clock >= period:
			clock -= period
			_repair_once(part, def)
		_repair_clock[key] = clock

func _repair_once(repair_part: Dictionary, def: Dictionary) -> void:
	var module_id := String(repair_part["module_id"])
	var radius := _repair_field_radius
	if module_id == "repair_small":
		radius = _repair_small_radius
	var pool: Array[Dictionary] = []
	for part in _tank.parts:
		if String(part.get("key", "")) == String(repair_part.get("key", "")):
			continue
		if float(part["hp"]) >= float(part["hp_max"]) - 0.0001:
			continue
		if not _part_within(part, repair_part["cells"], radius):
			continue
		pool.append(part)
	if pool.is_empty():
		return
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _repair_less(a, b))
	var best: Dictionary = pool[0]
	var target_def := definitions.get_module(String(best["module_id"]))
	var amount := float(def.get("repair_hp", 0.0))
	var is_core := bool(target_def.get("core", false))
	if is_core:
		amount *= _repair_core_factor
	best["hp"] = minf(float(best["hp_max"]), float(best["hp"]) + amount)
	events.append({"kind": "repaired", "key": String(best.get("key", "")), "amount": amount, "core": is_core})

func _repair_less(a: Dictionary, b: Dictionary) -> bool:
	var ratio_a := float(a["hp"]) / maxf(float(a["hp_max"]), 0.0001)
	var ratio_b := float(b["hp"]) / maxf(float(b["hp_max"]), 0.0001)
	if absf(ratio_a - ratio_b) > 0.0001:
		return ratio_a < ratio_b
	var cell_a := _first_cell(a)
	var cell_b := _first_cell(b)
	if cell_a.y != cell_b.y:
		return cell_a.y < cell_b.y
	return cell_a.x < cell_b.x

func _tick_debris(dt: float) -> void:
	if debris.is_empty():
		return
	var expired: Array[Vector2i] = []
	for raw in debris.keys():
		var cell := Vector2i(raw)
		var left := float(debris[cell]) - dt
		if left <= 0.0:
			expired.append(cell)
		else:
			debris[cell] = left
	expired.sort()
	for cell in expired:
		debris.erase(cell)

## ===== 护盾几何（代码推导，不改 data/modules/systems.json；沿用 M4 _port_specs 先例） =====

func _shield_for_cell(cell: Vector2i) -> Dictionary:
	var best_key := ""
	var best_hp := INF
	var best_index := 1 << 30
	for key in _shields.keys():
		var record: Dictionary = _shields[key]
		if String(record["state"]) != SHIELD_ACTIVE:
			continue
		var hp := float(record["hp"])
		if hp <= 0.0:
			continue
		if not _shield_covers(record, cell):
			continue
		var index := int(record["index"])
		if hp < best_hp - 0.0001 or (absf(hp - best_hp) <= 0.0001 and index < best_index):
			best_hp = hp
			best_index = index
			best_key = String(key)
	if best_key.is_empty():
		return {}
	return _shields[best_key]

func _shield_covers(record: Dictionary, cell: Vector2i) -> bool:
	var module_id := String(record["module_id"])
	var centre := Vector2i(record["centre"])
	match module_id:
		"shield_cell":
			var reach := int(round(_shield_cell_radius))
			for raw in (record["cells"] as Array):
				var own := Vector2i(raw)
				var delta := cell - own
				if absi(delta.x) + absi(delta.y) <= reach:
					return true
			return false
		"shield_plate":
			var facing := _dir_cell(int(record["rot"]))
			var perpendicular := Vector2i(-facing.y, facing.x)
			var half_w := (_shield_plate_w - 1) / 2
			for i in range(_shield_plate_w):
				for j in range(_shield_plate_h):
					if centre + facing * (i - half_w) + perpendicular * j == cell:
						return true
			return false
		"shield_dome":
			return Vector2(cell - centre).length() <= _shield_dome_radius
	return false

## ===== 工具函数 =====

func _dir_cell(rot: int) -> Vector2i:
	match posmod(rot, 360):
		90:
			return Vector2i.DOWN
		180:
			return Vector2i.LEFT
		270:
			return Vector2i.UP
	return Vector2i.RIGHT

func _part_centre_cell(part: Dictionary) -> Vector2i:
	var cells: Array = part.get("cells", [])
	if cells.is_empty():
		return Vector2i.ZERO
	var sum := Vector2i.ZERO
	for raw in cells:
		sum += Vector2i(raw)
	return Vector2i(
		int(round(float(sum.x) / float(cells.size()))),
		int(round(float(sum.y) / float(cells.size())))
	)

func _first_cell(part: Dictionary) -> Vector2i:
	var cells: Array = part.get("cells", [])
	if cells.is_empty():
		return Vector2i.ZERO
	return Vector2i(cells[0])

func _contains_cell(cells: Array, cell: Vector2i) -> bool:
	for raw in cells:
		if Vector2i(raw) == cell:
			return true
	return false

func _part_within(part: Dictionary, source_cells: Array, radius: float) -> bool:
	for raw in part.get("cells", []):
		var cell := Vector2i(raw)
		for raw_source in source_cells:
			var source := Vector2i(raw_source)
			if Vector2(cell - source).length() <= radius:
				return true
	return false

func _index_of_key(tank: TankBody, key: String) -> int:
	for index in range(tank.parts.size()):
		if String(tank.parts[index].get("key", "")) == key:
			return index
	return -1

func _prune_by_parts() -> void:
	if _tank == null:
		_burn.clear()
		_repair_clock.clear()
		_shields.clear()
		return
	var alive: Dictionary = {}
	for part in _tank.parts:
		alive[String(part.get("key", ""))] = true
	var burn_keys: Array = _burn.keys()
	burn_keys.sort()
	for key in burn_keys:
		if not alive.has(String(key)):
			_burn.erase(key)
	var clock_keys: Array = _repair_clock.keys()
	clock_keys.sort()
	for key in clock_keys:
		if not alive.has(String(key)):
			_repair_clock.erase(key)
	_prune_shields()

## R17-5：把护盾表与当前存活部件对齐。护盾本体一旦不在，记录立刻移除，
## 避免已毁护盾继续充能并“复活”挡伤害（design §6.6：本体被打掉就永不再充能）。
func _prune_shields() -> void:
	if _tank == null:
		_shields.clear()
		return
	var alive: Dictionary = {}
	for part in _tank.parts:
		alive[String(part.get("key", ""))] = true
	var keys: Array = _shields.keys()
	keys.sort()
	for key in keys:
		if not alive.has(String(key)):
			_shields.erase(key)
