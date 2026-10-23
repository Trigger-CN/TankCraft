extends RefCounted

## M5 弹道（design §8.1 / §8.2）。投射物是实体：每帧位移速度·dt，用线段扫掠与边界、障碍、
## 坦克格集合求交，取参数 t 最小者为命中点。命中、出界、超出**该口径的射程**或
## projectile_lifetime_s 即终止。伤害结算由 damage_system 负责，本模块只产出 impact / expire 事件。
##
## **v3.23 射程口径化**：射程原来是全局单值 `max_range_px`，所有炮弹共用。现在每个弹药定义
## 带自己的 `range_px`，`spawn()` 把它写进 shot，`step()` 按 `shot["range"]` 判定。
## 为什么：① 用户说的是「所有口径…的默认射程」——射程是口径属性，不是全局常量；
## ② 不同口径有不同的初速与伤害，却共用同一条射程线，本身就是一处耦合。
## `max_range_px` 降级为**缺省回退值**（弹药定义漏写时使用），正常路径不应命中它。
##
## **寿命由射程反推**：旧版寿命固定 3.5 s，与射程各判各的、谁先到谁终止。
## 按现有速度，3.5 s 能飞的距离是 3150 / 2730 / 2170 / 1750 / 1470 px，
## 也就是说口径越大越先到寿命——只提高射程会让 76 / 120 / 155 **名义上升了、实际没有**。
## 现在 `shot["life"] = maxf(_lifetime, range / speed + 0.5)`：射程是设计意图，
## 全局寿命退化为「万一算错也不让弹丸永生」的安全阀。纯算术，无随机，确定性不变。

const ModuleDefs := preload("res://scripts/module_defs.gd")

var definitions: ModuleDefs
var shots: Array[Dictionary] = []
var events: Array[Dictionary] = []

var _max_range: float = 1400.0
var _lifetime: float = 3.5
var _total_travelled: float = 0.0

func setup(module_defs: ModuleDefs) -> bool:
	definitions = module_defs
	if definitions == null:
		return false
	_max_range = definitions.global_number("max_range_px", 1400.0)
	_lifetime = definitions.global_number("projectile_lifetime_s", 3.5)
	return true

## origin/dir 为世界像素坐标与单位方向；upgrades 为随弹携带的改进 id 列表（整台聚合，见 damage_system）。
## damage_scale 供 up_split 的子弹丸按 60% 伤害结算。返回新炮弹的下标。
## shooter_team 用于 R18 多侧：同队目标不会被命中（敌人之间不误伤），且同队时也不能伤自己。
func spawn(origin: Vector2, dir: Vector2, ammo_id: String, shooter_tag: String = "player", upgrades: Array = [], damage_scale: float = 1.0, shooter_team: String = "") -> int:
	var ammo := definitions.get_ammo(ammo_id) if definitions != null else {}
	var speed := float(ammo.get("speed_px_s", 900.0)) * _speed_multiplier(upgrades)
	var radius := float(ammo.get("radius_px", 2.0))
	## 射程是**口径属性**；弹药定义漏写时才回退到全局值。
	var range_px := float(ammo.get("range_px", _max_range))
	if range_px <= 0.0:
		range_px = _max_range
	## 寿命由射程反推（见文件头）：留 0.5 s 余量，避免浮点误差让弹丸在距射程 0.01 px 处过期。
	## 全局 `_lifetime` 只做**下限**，防止极近射程时寿命短到不合理。
	var life := maxf(_lifetime, range_px / maxf(speed, 0.001) + 0.5)
	shots.append({
		"ammo_id": ammo_id,
		"shooter": shooter_tag,
		"team": shooter_team,
		"pos": origin,
		"prev": origin,
		"dir": dir.normalized(),
		"speed": speed,
		"radius": radius,
		"range": range_px,
		"life": life,
		"age": 0.0,
		"travelled": 0.0,
		"upgrades": upgrades.duplicate(),
		"damage_scale": damage_scale,
	})
	return shots.size() - 1
	return shots.size() - 1

## 推进一步；返回本帧产生的事件（同时累积到 events）。
func step(dt: float, arena_rect: Rect2, obstacles: Array = [], targets: Array = []) -> Array[Dictionary]:
	var frame_events: Array[Dictionary] = []
	if definitions == null or dt <= 0.0:
		return frame_events
	var survivors: Array[Dictionary] = []
	for shot in shots:
		var travelled := float(shot["travelled"])
		## v3.23：射程与寿命都是**逐发**的（spawn 时按口径算出并写进 shot），不再读全局量。
		var shot_range := float(shot.get("range", _max_range))
		var shot_life := float(shot.get("life", _lifetime))
		var remaining_range := shot_range - travelled
		var remaining_life := shot_life - float(shot["age"])
		if remaining_range <= 0.0 or remaining_life <= 0.0:
			frame_events.append(_expire(shot, "range" if remaining_range <= 0.0 else "lifetime"))
			continue
		var step_time := minf(dt, remaining_life)
		var distance := minf(float(shot["speed"]) * step_time, remaining_range)
		var start: Vector2 = shot["pos"]
		var delta: Vector2 = Vector2(shot["dir"]) * distance
		var end := start + delta
		shot["prev"] = start
		shot["age"] = float(shot["age"]) + step_time
		shot["travelled"] = travelled + distance
		var hit := _sweep(start, end, arena_rect, obstacles, targets, String(shot["shooter"]), String(shot.get("team", "")))
		if bool(hit["hit"]):
			shot["pos"] = hit["pos"]
			frame_events.append(_hit_event(shot, hit))
			continue
		shot["pos"] = end
		if not arena_rect.has_point(end):
			shot["pos"] = end
			frame_events.append(_hit_event(shot, {"pos": end, "target": "boundary", "normal": -Vector2(shot["dir"])}))
			continue
		if float(shot["travelled"]) >= shot_range - 0.001:
			frame_events.append(_expire(shot, "range"))
			continue
		if float(shot["age"]) >= shot_life - 0.001:
			frame_events.append(_expire(shot, "lifetime"))
			continue
		survivors.append(shot)
	shots = survivors
	events.append_array(frame_events)
	return frame_events

## 炮弹自然消散（未命中）。**两种 reason 都算「消散」**：
## - `range`  = 飞满该口径射程；
## - `lifetime` = 安全阀先到（正常数据下不应发生，见文件头）。
## v3.23 补上 `shooter` / `travelled` / `range`：页面层需要按敌我上色，
## 测试需要断言「实际飞行距离 == 该口径射程」。
func _expire(shot: Dictionary, reason: String) -> Dictionary:
	return {
		"kind": "expire",
		"reason": reason,
		"pos": shot["pos"],
		"ammo_id": shot["ammo_id"],
		"target": "",
		"shooter": String(shot.get("shooter", "")),
		"travelled": float(shot.get("travelled", 0.0)),
		"range": float(shot.get("range", _max_range)),
	}

func _hit_event(shot: Dictionary, hit: Dictionary) -> Dictionary:
	return {
		"kind": "impact",
		"reason": "impact",
		"pos": hit["pos"],
		"ammo_id": shot["ammo_id"],
		"target": String(hit.get("target", "")),
		"normal": hit.get("normal", Vector2.ZERO),
		"tag": String(hit.get("tag", "")),
		"cell": hit.get("cell", Vector2i.ZERO),
		"part_index": int(hit.get("part_index", -1)),
		## obstacle_index 指向 obstacles 数组下标，供 M9 把命中映射回房屋。
		"obstacle_index": int(hit.get("obstacle_index", -1)),
		## shooter 是该弹丸的发射方 tag，供结算侧归因伤害（design §8）。
		"shooter": String(shot.get("shooter", "")),
		"upgrades": (shot.get("upgrades", []) as Array).duplicate(),
		"damage_scale": float(shot.get("damage_scale", 1.0)),
	}

## design §8.6 up_velocity：同类升级加法叠加，层数按 stack_limit 截断。
func _speed_multiplier(upgrades: Array) -> float:
	var stacks := 0
	var limit := 1
	var value := 0.0
	if definitions == null or definitions.registry == null:
		return 1.0
	for raw in upgrades:
		var def: Dictionary = definitions.registry.get_upgrade(String(raw))
		if def.is_empty() or String(def.get("effect", "")) != "velocity_multiplier":
			continue
		limit = maxi(int(def.get("stack_limit", 1)), 1)
		value = float(def.get("value", 0.0))
		if stacks < limit:
			stacks += 1
	return 1.0 + value * float(stacks)

## 线段扫掠：边界、障碍与坦克格统一按 t 最小者裁决（design §8.2 最近者优先）。
## shooter_tag 用于排除射手自己：炮口原点落在自身格边界上，若不过滤会以 t = 0 命中本体（M5 已实证）。
## shooter_team 用于 R18 多侧：同队目标不参与求交（敌人之间不误伤）。空串表示不区分阵营。
func _sweep(start: Vector2, end: Vector2, arena_rect: Rect2, obstacles: Array, targets: Array, shooter_tag: String = "", shooter_team: String = "") -> Dictionary:
	var best := {"hit": false, "pos": end, "t": INF, "target": "", "normal": Vector2.ZERO, "tag": "", "cell": Vector2i.ZERO, "part_index": -1, "obstacle_index": -1}
	var boundary := _clip_to_rect(start, end, arena_rect)
	if float(boundary["t"]) < float(best["t"]):
		best = {"hit": true, "pos": boundary["pos"], "t": boundary["t"], "target": "boundary", "normal": boundary["normal"], "tag": "", "cell": Vector2i.ZERO, "part_index": -1, "obstacle_index": -1}
	for obstacle_index in range(obstacles.size()):
		var obstacle: Dictionary = obstacles[obstacle_index]
		var shape := String(obstacle.get("shape", ""))
		var result := {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
		if shape == "rect":
			result = _clip_to_rect(start, end, Rect2(obstacle["rect"]))
		elif shape == "circle":
			result = _clip_to_circle(start, end, Vector2(obstacle["center"]), float(obstacle.get("radius", 0.0)))
		if bool(result["hit"]) and float(result["t"]) < float(best["t"]):
			## obstacle_index 供上层把命中映射回具体道具（M9 房屋）。
			best = {"hit": true, "pos": result["pos"], "t": result["t"], "target": "obstacle", "normal": result["normal"], "tag": "", "cell": Vector2i.ZERO, "part_index": -1, "obstacle_index": obstacle_index}
	for target in targets:
		var tag := String(target.get("tag", ""))
		## design §8.7：弹丸不会伤到发射者自身。
		if not shooter_tag.is_empty() and tag == shooter_tag:
			continue
		## R18：同队目标不参与求交（N 侧同屏时敌人之间不误伤）。
		if not shooter_team.is_empty() and String(target.get("team", "")) == shooter_team:
			continue
		var tank_hit := _clip_to_tank(start, end, target)
		if bool(tank_hit["hit"]) and float(tank_hit["t"]) < float(best["t"]):
			best = {"hit": true, "pos": tank_hit["pos"], "t": tank_hit["t"], "target": "tank", "normal": tank_hit["normal"], "tag": tag, "cell": tank_hit["cell"], "part_index": int(tank_hit["part_index"]), "obstacle_index": -1}
	return best

## 线段与矩形的第一交点。
##
## **v3.23 修复**：旧实现只算了 `rect.end`，等于假设「起点一定在矩形内部、向外射出」。
## 它本来是给**竞技场边界**写的（炮弹都在场内），但同一函数也被复用来求**障碍矩形**，
## 于是每个矩形障碍的右侧变成了一道**无限高的隐形墙**：任意 y 的炮弹只要跨过
## `rect.end.x` 就被判成命中。实测证据：一发 `cal_76` 沿 `y=200` 直飞，撞上了
## `rect(960,320,128,128)`（该矩形在 y 方向只覆盖 320..448）。后果是「炮弹未命中、
## 飞满射程后消散」这条需求在有矩形障碍的竞技场里永远触发不了。
##
## 现在用标准 slab 求交：起点在内部时取**退出点**（竞技场边界的旧行为，不变），
## 起点在外部时取**进入点**。两种情形都要先确认线段真的穿过矩形。
func _clip_to_rect(start: Vector2, end: Vector2, rect: Rect2) -> Dictionary:
	var missing := {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	var delta := end - start
	var t_enter := -INF
	var t_exit := INF
	var axis_enter := 0
	var axis_exit := 0
	for axis_index in range(2):
		var origin_axis := start.x if axis_index == 0 else start.y
		var delta_axis := delta.x if axis_index == 0 else delta.y
		var low := rect.position.x if axis_index == 0 else rect.position.y
		var high := rect.end.x if axis_index == 0 else rect.end.y
		if absf(delta_axis) <= 0.000001:
			## 平行于这一对边：起点必须已经落在 slab 内，否则整条线段都在外面。
			if origin_axis < low or origin_axis > high:
				return missing
			continue
		var t_low := (low - origin_axis) / delta_axis
		var t_high := (high - origin_axis) / delta_axis
		if t_low > t_high:
			var swap := t_low
			t_low = t_high
			t_high = swap
		if t_low > t_enter:
			t_enter = t_low
			axis_enter = axis_index
		if t_high < t_exit:
			t_exit = t_high
			axis_exit = axis_index
		if t_enter > t_exit:
			return missing
	## 起点在矩形内 → 取退出点（与旧行为一致）；起点在外 → 取进入点。
	var inside := start.x >= rect.position.x and start.x <= rect.end.x and start.y >= rect.position.y and start.y <= rect.end.y
	var t := t_exit if inside else t_enter
	var axis := axis_exit if inside else axis_enter
	if t < 0.0 or t > 1.0:
		return missing
	var normal := Vector2.ZERO
	if axis == 0:
		normal = Vector2.LEFT if delta.x > 0.0 else Vector2.RIGHT
	else:
		normal = Vector2.UP if delta.y > 0.0 else Vector2.DOWN
	return {"hit": true, "pos": start + delta * t, "t": t, "normal": normal}

## 线段与圆的最近交点（解二次方程，取参数最小正根）。
func _clip_to_circle(start: Vector2, end: Vector2, centre: Vector2, radius: float) -> Dictionary:
	if radius <= 0.0:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	var delta := end - start
	var offset := start - centre
	var a := delta.dot(delta)
	if a <= 0.000001:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	var b := 2.0 * offset.dot(delta)
	var c := offset.dot(offset) - radius * radius
	var discriminant := b * b - 4.0 * a * c
	if discriminant < 0.0:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	var sqrt_d := sqrt(discriminant)
	var t1 := (-b - sqrt_d) / (2.0 * a)
	var t2 := (-b + sqrt_d) / (2.0 * a)
	var t := t1
	if t < 0.0:
		t = t2
	if t < 0.0 or t > 1.0:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	var point := start + delta * t
	return {"hit": true, "pos": point, "t": t, "normal": (point - centre).normalized()}

## 坦克求交在坦克局部空间做：把线段两端变换到局部坐标，逐格做 AABB 求交，再把命中点变回
## 世界坐标 —— 避免对旋转后的坦克构造旋转 AABB。targets 每项含
## {tag, origin, heading, centroid_local, cell_half, cells:[{cell, part_index, centre_local}]}。
func _clip_to_tank(start: Vector2, end: Vector2, target: Dictionary) -> Dictionary:
	var origin: Vector2 = target.get("origin", Vector2.ZERO)
	var heading := float(target.get("heading", 0.0))
	var centroid_local: Vector2 = target.get("centroid_local", Vector2.ZERO)
	var half := float(target.get("cell_half", 8.0))
	var local_start := (start - origin).rotated(-heading) + centroid_local
	var local_end := (end - origin).rotated(-heading) + centroid_local
	var best := {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO, "cell": Vector2i.ZERO, "part_index": -1}
	var cells: Array = target.get("cells", [])
	for entry in cells:
		var centre: Vector2 = entry.get("centre_local", Vector2.ZERO)
		var box := _clip_to_aabb(local_start, local_end, centre, half)
		if not bool(box["hit"]) or float(box["t"]) >= float(best["t"]):
			continue
		var world_pos: Vector2 = (Vector2(box["pos"]) - centroid_local).rotated(heading) + origin
		best = {
			"hit": true,
			"pos": world_pos,
			"t": box["t"],
			"normal": Vector2(box["normal"]).rotated(heading),
			"cell": entry.get("cell", Vector2i.ZERO),
			"part_index": int(entry.get("part_index", -1)),
		}
	return best

## 线段进入轴对齐方格的第一个交点（slab 法）；起点已在格内时返回 t = 0。
func _clip_to_aabb(start: Vector2, end: Vector2, centre: Vector2, half: float) -> Dictionary:
	var delta := end - start
	var t_enter := 0.0
	var t_exit := 1.0
	var normal := Vector2.ZERO
	var axis_normals := [Vector2.LEFT, Vector2.UP]
	var lows := [centre.x - half, centre.y - half]
	var highs := [centre.x + half, centre.y + half]
	var origins := [start.x, start.y]
	var deltas := [delta.x, delta.y]
	for axis in range(2):
		var axis_origin := float(origins[axis])
		var axis_delta := float(deltas[axis])
		var lo := float(lows[axis])
		var hi := float(highs[axis])
		if absf(axis_delta) <= 0.000001:
			if axis_origin < lo or axis_origin > hi:
				return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
			continue
		var inv := 1.0 / axis_delta
		var t1 := (lo - axis_origin) * inv
		var t2 := (hi - axis_origin) * inv
		var t_lo := minf(t1, t2)
		var t_hi := maxf(t1, t2)
		var axis_normal: Vector2 = axis_normals[axis]
		if t1 > t2:
			axis_normal = -axis_normal
		if t_lo > t_enter:
			t_enter = t_lo
			normal = axis_normal
		if t_hi < t_exit:
			t_exit = t_hi
		if t_enter > t_exit:
			return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	if t_enter > 1.0:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	return {"hit": true, "pos": start + delta * t_enter, "t": t_enter, "normal": normal}
