extends RefCounted

## M5 弹道（design §8.1 / §8.2）。投射物是实体：每帧位移速度·dt，用线段扫掠与边界、障碍、
## 坦克格集合求交，取参数 t 最小者为命中点。命中、出界、超出 max_range_px 或
## projectile_lifetime_s 即终止。伤害结算由 damage_system 负责，本模块只产出 impact 事件。

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
	shots.append({
		"ammo_id": ammo_id,
		"shooter": shooter_tag,
		"team": shooter_team,
		"pos": origin,
		"prev": origin,
		"dir": dir.normalized(),
		"speed": speed,
		"radius": radius,
		"age": 0.0,
		"travelled": 0.0,
		"upgrades": upgrades.duplicate(),
		"damage_scale": damage_scale,
	})
	return shots.size() - 1

## 推进一步；返回本帧产生的事件（同时累积到 events）。
func step(dt: float, arena_rect: Rect2, obstacles: Array = [], targets: Array = []) -> Array[Dictionary]:
	var frame_events: Array[Dictionary] = []
	if definitions == null or dt <= 0.0:
		return frame_events
	var survivors: Array[Dictionary] = []
	for shot in shots:
		var travelled := float(shot["travelled"])
		var remaining_range := _max_range - travelled
		var remaining_life := _lifetime - float(shot["age"])
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
		if float(shot["travelled"]) >= _max_range - 0.001:
			frame_events.append(_expire(shot, "range"))
			continue
		if float(shot["age"]) >= _lifetime - 0.001:
			frame_events.append(_expire(shot, "lifetime"))
			continue
		survivors.append(shot)
	shots = survivors
	events.append_array(frame_events)
	return frame_events

func _expire(shot: Dictionary, reason: String) -> Dictionary:
	return {"kind": "expire", "reason": reason, "pos": shot["pos"], "ammo_id": shot["ammo_id"], "target": ""}

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

## 从矩形内部出发、向外射出时求与矩形边界的第一交点。
func _clip_to_rect(start: Vector2, end: Vector2, rect: Rect2) -> Dictionary:
	var delta := end - start
	var t_max := 1.0
	var normal := Vector2.ZERO
	if delta.x != 0.0:
		var target_x := rect.end.x if delta.x > 0.0 else rect.position.x
		var t := (target_x - start.x) / delta.x
		if t >= 0.0 and t <= t_max:
			t_max = t
			normal = Vector2.LEFT if delta.x > 0.0 else Vector2.RIGHT
	if delta.y != 0.0:
		var target_y := rect.end.y if delta.y > 0.0 else rect.position.y
		var t := (target_y - start.y) / delta.y
		if t >= 0.0 and t <= t_max:
			t_max = t
			normal = Vector2.UP if delta.y > 0.0 else Vector2.DOWN
	if normal == Vector2.ZERO:
		return {"hit": false, "pos": end, "t": INF, "normal": Vector2.ZERO}
	return {"hit": true, "pos": start + delta * t_max, "t": t_max, "normal": normal}

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
