extends RefCounted

## M3 炮管组（design §6.5）。每门炮独立：存一发、装填冷却、口径校验、后坐力回报。
## 弹药供应网络（M4）尚未实现，本阶段开火前由调用方按需直接给炮管装填。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")

var definitions: ModuleDefs
var body: TankBody
## 每门炮：{part_index, module_id, cell, caliber, reload_s, recoil_px, aim, loaded,
##   reload_remaining, shots_fired, upgrades, aim_override, aim_world}
## `upgrades` 是**已上膛那一发携带的升级载荷**（v3.24）。炮管只是搬运工：
## 载荷由弹药网络在装填时交来，开火时随发射事件交给 `Duel.fire()`。
## `aim` 是建造期锁定的相对角；`aim_override` / `aim_world` 是 v3.25 的**战斗期鼠标瞄准**：
## 为真时弹道方向直接用绝对世界角 `aim_world`，不再读 `aim`。玩家侧每帧调 `aim_at()`，
## Bot 侧永远不设，所以 AI 的「弹道方向 = heading + aim」判据完全不受影响。
var cannons: Array[Dictionary] = []

func setup(module_defs: ModuleDefs, tank: TankBody) -> bool:
	definitions = module_defs
	body = tank
	if definitions == null or body == null:
		return false
	reload_from_body()
	return not cannons.is_empty()

## 按刚体当前存活部件重建炮管列表；已装填/冷却状态按 module_id + 格子匹配保留。
func reload_from_body() -> void:
	var previous := cannons.duplicate(true)
	cannons.clear()
	for index in range(body.parts.size()):
		var part: Dictionary = body.parts[index]
		if String(part["kind"]) != TankBody.KIND_MODULE:
			continue
		var module_id := String(part["module_id"])
		var def := definitions.get_module(module_id)
		## design §6.5：炮管专属字段是 aim_steps；弹药制造装置也有 caliber，但不是炮管。
		if not def.has("aim_steps"):
			continue
		var occupied: Array = part["cells"]
		if occupied.is_empty():
			continue
		var snapshot := {
			"part_index": index,
			"module_id": module_id,
			"cell": Vector2i(occupied[0]),
			"caliber": String(def.get("caliber", "")),
			"reload_s": float(def.get("reload_s", 0.0)),
			"recoil_px": float(def.get("recoil_px", 0.0)),
			"aim": int(part.get("aim", 0)),
			"loaded": false,
			"reload_remaining": 0.0,
			"shots_fired": 0,
			"upgrades": [],
			## v3.25 鼠标瞄准的运行时覆盖。默认关闭，所以只有显式调 `aim_at()` 的玩家侧会用到；
			## Bot 侧永远不调，行为与 v3.24 完全一致（这也是 AI 的判据不被牵连的前提）。
			"aim_override": false,
			"aim_world": 0.0,
		}
		for old in previous:
			if String(old["module_id"]) == module_id and Vector2i(old["cell"]) == Vector2i(snapshot["cell"]):
				snapshot["loaded"] = bool(old["loaded"])
				snapshot["reload_remaining"] = float(old["reload_remaining"])
				snapshot["shots_fired"] = int(old["shots_fired"])
				snapshot["upgrades"] = (old.get("upgrades", []) as Array).duplicate()
				## 拓扑重建（波次刷新 / 部件摧毁）时保留瞄准覆盖，否则每波开局都要重新晃鼠标才能拾起瞄准。
				snapshot["aim_override"] = bool(old.get("aim_override", false))
				snapshot["aim_world"] = float(old.get("aim_world", 0.0))
				break
		cannons.append(snapshot)

func step(dt: float) -> void:
	if dt <= 0.0:
		return
	for cannon in cannons:
		if bool(cannon["loaded"]):
			continue
		var remaining := float(cannon["reload_remaining"]) - dt
		if remaining <= 0.0:
			cannon["reload_remaining"] = 0.0
		else:
			cannon["reload_remaining"] = remaining

## 直接装填一发（弹药网络落地前由 demo 代替供给）。
## `upgrades` 是这一发从改进装置那里攒到的升级载荷；由 `AmmoNetwork.fill_cannons()` 传入。
func load_round(index: int, upgrades: Array = []) -> bool:
	if index < 0 or index >= cannons.size():
		return false
	var cannon: Dictionary = cannons[index]
	if bool(cannon["loaded"]) or float(cannon["reload_remaining"]) > 0.0:
		return false
	cannon["loaded"] = true
	cannon["upgrades"] = (upgrades as Array).duplicate()
	return true

func load_all() -> int:
	var count := 0
	for index in range(cannons.size()):
		if load_round(index):
			count += 1
	return count

## 世界坐标下的炮口方向。
##
## 有运行时瞄准覆盖时直接用绝对世界角 `aim_world`——那是玩家鼠标指的方向，**与车体朝向无关**，
## 这正是「鼠标瞄准」与旧「靠车身转向瞄准」的本质区别。
## 没有覆盖时退回建造期语义：`hull 朝向 + aim 偏移`（design §6.5）。
func muzzle_dir(cannon: Dictionary) -> Vector2:
	if bool(cannon.get("aim_override", false)):
		return Vector2.RIGHT.rotated(float(cannon.get("aim_world", 0.0)))
	return Vector2.RIGHT.rotated(body.heading + deg_to_rad(float(cannon["aim"])))

## 把某门炮的瞄准方向设为指向世界点 `target`。返回是否真的改变了方向（用于 HUD 节流重绘）。
##
## 为什么在炮管组而不是页面层：方向要经过 `body.heading` 的换算才能变成 `aim` 相对角，
## 而这个换算属于炮管几何的一部分；放在页面层等于把同一套角度算术再写一遍，
## 一旦朝向定义变化（例如将来改成屏幕朝向）两边就会不一致。
func aim_at(index: int, target: Vector2) -> bool:
	if index < 0 or index >= cannons.size():
		return false
	var cannon: Dictionary = cannons[index]
	var centre := body.world_position_of_cell(Vector2i(cannon["cell"]))
	var to_target := target - centre
	## 目标与炮管中心重合时保持原方向：atan2(0,0) 没有意义，硬算会突然甩到 +X。
	if to_target.length_squared() <= 0.0001:
		return false
	var world_angle := atan2(to_target.y, to_target.x)
	var changed := not bool(cannon.get("aim_override", false))
	if not changed:
		var delta := absf(wrapf(world_angle - float(cannon.get("aim_world", 0.0)), -PI, PI))
		changed = delta > 0.0001
	## 始终写回：`changed` 只用于判断要不要重绘，不代表是否需要更新角度。
	cannon["aim_override"] = true
	cannon["aim_world"] = world_angle
	return changed

## 让某一侧所有炮管都指向同一个世界点（鼠标只瞄一个方向，多炮齐射就都朝那里）。
## 返回真正改变了方向的炮管数；0 表示「方向没变」，不要用它当失败。
func aim_all_at(target: Vector2) -> int:
	var moved := 0
	for index in range(cannons.size()):
		if aim_at(index, target):
			moved += 1
	return moved

## 关闭运行时覆盖，回到建造期 `aim` 语义。波次结束 / 退出战斗时调，
## 否则「上一局鼠标停在哪里」会跟着下一局的车走。
func clear_aim_override() -> void:
	for cannon in cannons:
		cannon["aim_override"] = false
		cannon["aim_world"] = 0.0

func muzzle_origin(cannon: Dictionary) -> Vector2:
	var centre := body.world_position_of_cell(Vector2i(cannon["cell"]))
	return centre + muzzle_dir(cannon) * (body.cell_size() * 0.5)

## 开火。ammo_id 口径必须与炮管 caliber 一致；未装填或冷却中拒发。
## 返回发射事件数组（可能一次齐射多门）：{cannon_index, origin, dir, ammo_id, recoil_px, world_r}
func fire(ammo_id: String) -> Array[Dictionary]:
	var fired: Array[Dictionary] = []
	for index in range(cannons.size()):
		var cannon: Dictionary = cannons[index]
		var event := _fire_one(index, cannon, ammo_id)
		if not event.is_empty():
			fired.append(event)
	return fired

func can_fire(ammo_id: String) -> bool:
	for cannon in cannons:
		if _allowed(cannon, ammo_id) and bool(cannon["loaded"]) and float(cannon["reload_remaining"]) <= 0.0:
			return true
	return false

func _allowed(cannon: Dictionary, ammo_id: String) -> bool:
	if definitions == null:
		return false
	var ammo := definitions.get_ammo(ammo_id)
	if ammo.is_empty():
		return false
	return String(ammo.get("caliber", ammo_id)) == String(cannon["caliber"])



func _fire_one(index: int, cannon: Dictionary, ammo_id: String) -> Dictionary:
	if not _allowed(cannon, ammo_id):
		return {}
	if not bool(cannon["loaded"]) or float(cannon["reload_remaining"]) > 0.0:
		return {}
	var dir := muzzle_dir(cannon)
	var origin := muzzle_origin(cannon)
	var payload: Array = (cannon.get("upgrades", []) as Array).duplicate()
	cannon["loaded"] = false
	cannon["upgrades"] = []
	cannon["reload_remaining"] = float(cannon["reload_s"])
	cannon["shots_fired"] = int(cannon["shots_fired"]) + 1
	return {
		"cannon_index": index,
		"origin": origin,
		"dir": dir,
		"ammo_id": ammo_id,
		"upgrades": payload,
		"recoil_px": float(cannon["recoil_px"]),
		"world_r": origin - body.position,
	}

func ammo_for_caliber(cannon_index: int) -> String:
	if cannon_index < 0 or cannon_index >= cannons.size():
		return ""
	var caliber := String(cannons[cannon_index]["caliber"])
	if caliber.is_empty():
		return ""
	if definitions != null and not definitions.get_ammo(caliber).is_empty():
		return caliber
	return ""
