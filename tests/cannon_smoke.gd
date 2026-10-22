extends SceneTree

## M3 炮管与弹道 smoke（design §6.5 / §8.1）。
## 覆盖：装填计时、连发拒收、口径不匹配拒收、后坐力回馈、弹道终止条件。

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const ProjectileField := preload("res://scripts/projectile_field.gd")

const ARENA := Rect2(0.0, 0.0, 2048.0, 1152.0)

func _init() -> void:
	var definitions := ModuleDefs.new()
	if not definitions.load_all("res://data"):
		_fail("CANNON_FAIL_DATA")
		return
	var rig := _make_rig(definitions)
	if rig == null:
		return
	var body: TankBody = rig["body"]
	var bank: CannonBank = rig["bank"]
	if not _check_data_fields(definitions):
		return
	if not _check_reload(bank):
		return
	if not _check_caliber(bank):
		return
	if not _check_recoil(body, bank):
		return
	var range_px := _check_projectile(definitions)
	if range_px < 0.0:
		return
	print("CANNON_OK shots=%d reload76=%.2f range=%.0f" % [
		int(bank.cannons[0]["shots_fired"]), float(bank.cannons[0]["reload_s"]), range_px
	])
	quit(0)

func _fail(code: String) -> void:
	print(code)
	quit(1)

## 一门 76 炮 + 驾驶舱 + 引擎 + 双履带的对称底盘。
func _make_rig(definitions: ModuleDefs) -> Dictionary:
	var builder := GridBuilder.new()
	if not builder.setup(definitions):
		_fail("CANNON_FAIL_BUILDER")
		return {}
	builder.budget_enabled = false
	builder.credits_total = 100000
	for y in range(4, 11):
		for x in range(4, 10):
			builder.place_platform_cell(Vector2i(x, y))
	builder.place_mobility("track_light", Vector2i(4, 4), 0)
	builder.place_mobility("track_light", Vector2i(4, 10), 0)
	builder.place_module("cockpit_light", Vector2i(4, 7), 0, 0)
	builder.place_module("engine_medium", Vector2i(5, 7), 0, 0)
	var note := builder.place_module("cannon_76", Vector2i(8, 7), 0, 0)
	if not note.is_empty():
		_fail("CANNON_FAIL_CANNON:%s" % note)
		return {}
	var body := TankBody.new()
	if not body.setup(definitions, builder):
		_fail("CANNON_FAIL_BODY")
		return {}
	body.position = Vector2(1024.0, 576.0)
	var bank := CannonBank.new()
	if not bank.setup(definitions, body):
		_fail("CANNON_FAIL_BANK")
		return {}
	return {"body": body, "bank": bank}

func _check_data_fields(definitions: ModuleDefs) -> bool:
	var expected := {
		"cannon_20": [0.35, 6.0],
		"cannon_40": [0.6, 10.0],
		"cannon_76": [1.1, 20.0],
		"cannon_120": [1.8, 34.0],
		"cannon_155": [2.6, 48.0],
	}
	for module_id in expected.keys():
		var def := definitions.get_module(String(module_id))
		if def.is_empty() or not def.has("reload_s") or not def.has("recoil_px"):
			_fail("CANNON_FAIL_MISSING_FIELD:%s" % module_id)
			return false
		var pair: Array = expected[module_id]
		if absf(float(def["reload_s"]) - float(pair[0])) > 0.001:
			_fail("CANNON_FAIL_RELOAD_DATA:%s" % module_id)
			return false
		if absf(float(def["recoil_px"]) - float(pair[1])) > 0.001:
			_fail("CANNON_FAIL_RECOIL_DATA:%s" % module_id)
			return false
	return true

## 装填 1.10 s：0 秒装填后立刻可发，冷却期间拒发，冷却结束后可再装填。
func _check_reload(bank: CannonBank) -> bool:
	if not bank.load_round(0):
		_fail("CANNON_FAIL_LOAD")
		return false
	if bank.fire("cal_76").size() != 1:
		_fail("CANNON_FAIL_FIRST_SHOT")
		return false
	if not bank.fire("cal_76").is_empty():
		_fail("CANNON_FAIL_BACK_TO_BACK")
		return false
	if bank.load_round(0):
		_fail("CANNON_FAIL_LOAD_WHILE_COOLING")
		return false
	## 1.10 s 装填：1.0 s 仍在冷却且拒绝装填，冷却结束后才允许装填。
	for step in range(60):
		bank.step(1.0 / 60.0)
	if float(bank.cannons[0]["reload_remaining"]) <= 0.0 or bank.load_round(0):
		_fail("CANNON_FAIL_COOLDOWN_TOO_SHORT")
		return false
	bank.step(0.2)
	if float(bank.cannons[0]["reload_remaining"]) > 0.0:
		_fail("CANNON_FAIL_COOLDOWN_TOO_LONG")
		return false
	if not bank.load_round(0):
		_fail("CANNON_FAIL_LOAD_AFTER_RELOAD")
		return false
	return true

## 口径必须匹配。
func _check_caliber(bank: CannonBank) -> bool:
	if bank.fire("cal_20").size() != 0:
		_fail("CANNON_FAIL_CALIBER_ACCEPTED")
		return false
	if bank.fire("cal_155").size() != 0:
		_fail("CANNON_FAIL_CALIBER_155")
		return false
	if bank.fire("nope").size() != 0:
		_fail("CANNON_FAIL_UNKNOWN_AMMO")
		return false
	## 上一步已装入一发：口径不匹配全部拒收后再用正确口径发射应成功。
	if bank.fire("cal_76").size() != 1:
		_fail("CANNON_FAIL_CALIBER_READY")
		return false
	return true

## 后坐：沿 -dir 施加，侧向炮管会明显改变角速度。
func _check_recoil(body: TankBody, bank: CannonBank) -> bool:
	## 上一项已经发射，先走完 1.10 s 装填冷却。
	bank.step(1.2)
	if not bank.load_round(0):
		_fail("CANNON_FAIL_RECOIL_LOAD")
		return false
	var before_velocity := body.velocity.length()
	var before_omega := body.angular_velocity
	var shots := bank.fire("cal_76")
	if shots.size() != 1:
		_fail("CANNON_FAIL_RECOIL_FIRE")
		return false
	var shot: Dictionary = shots[0]
	body.apply_recoil(float(shot["recoil_px"]), Vector2(shot["dir"]), Vector2(shot["world_r"]))
	if body.velocity.length() <= before_velocity:
		_fail("CANNON_FAIL_RECOIL_PUSH")
		return false
	## 正前方炮管（aim=0、位于质心线上）后坐是纯反向平移，不应产生自旋。
	if absf(body.angular_velocity - before_omega) > 0.01:
		_fail("CANNON_FAIL_RECOIL_SPIN %.4f" % body.angular_velocity)
		return false
	return true

## 弹道：超出 projectile_lifetime_s × speed 或 max_range_px 即终止；边界命中产生事件。
func _check_projectile(definitions: ModuleDefs) -> float:
	var field := ProjectileField.new()
	if not field.setup(definitions):
		_fail("CANNON_FAIL_FIELD")
		return -1.0
	var ammo := definitions.get_ammo("cal_76")
	var speed := float(ammo.get("speed_px_s", 620.0))
	var max_range := definitions.global_number("max_range_px", 1400.0)
	var lifetime := definitions.global_number("projectile_lifetime_s", 3.5)
	## 空旷竞技场内沿 +X 飞行，边界距离 > 弹道射程，因此应在射程/寿命处结束。
	var origin := Vector2(60.0, 576.0)
	field.spawn(origin, Vector2.RIGHT, "cal_76", "player")
	var travelled := 0.0
	var reason := ""
	for step in range(1200):
		var events := field.step(1.0 / 60.0, ARENA, [])
		if not events.is_empty():
			reason = String(events[0]["reason"])
			travelled = float(field.events[field.events.size() - 1].get("pos", origin).x) - origin.x
			break
	if reason.is_empty():
		_fail("CANNON_FAIL_NEVER_TERMINATED")
		return -1.0
	var max_travel := speed * lifetime
	if absf(travelled - minf(max_range, max_travel)) > 1.0:
		_fail("CANNON_FAIL_RANGE %.1f expected %.1f" % [travelled, minf(max_range, max_travel)])
		return -1.0
	## 朝边界短距离发射必须在边界命中并产生 impact 事件。
	var near := ProjectileField.new()
	near.setup(definitions)
	near.spawn(Vector2(ARENA.end.x - 200.0, 576.0), Vector2.RIGHT, "cal_76", "player")
	var hit_kind := ""
	for step in range(120):
		var events := near.step(1.0 / 60.0, ARENA, [])
		if not events.is_empty():
			hit_kind = String(events[0]["kind"])
			break
	if hit_kind != "impact":
		_fail("CANNON_FAIL_BOUNDARY_IMPACT:%s" % hit_kind)
		return -1.0
	## 障碍矩形必须被拦住。
	var blocked := ProjectileField.new()
	blocked.setup(definitions)
	var obstacle := {"shape": "rect", "rect": Rect2(400.0, 500.0, 120.0, 160.0)}
	blocked.spawn(Vector2(100.0, 576.0), Vector2.RIGHT, "cal_76", "player")
	var blocked_target := ""
	for step in range(120):
		var events := blocked.step(1.0 / 60.0, ARENA, [obstacle])
		if not events.is_empty():
			blocked_target = String(events[0]["target"])
			break
	if blocked_target != "obstacle":
		_fail("CANNON_FAIL_OBSTACLE:%s" % blocked_target)
		return -1.0
	## 高速弹以大 dt 也不能穿模。
	var tunnel := ProjectileField.new()
	tunnel.setup(definitions)
	tunnel.spawn(Vector2(100.0, 576.0), Vector2.RIGHT, "cal_76", "player")
	var tunnel_hit := ""
	for step in range(30):
		var events := tunnel.step(0.25, ARENA, [obstacle])
		if not events.is_empty():
			tunnel_hit = String(events[0]["target"])
			break
	if tunnel_hit != "obstacle":
		_fail("CANNON_FAIL_TUNNELING:%s" % tunnel_hit)
		return -1.0
	return travelled
