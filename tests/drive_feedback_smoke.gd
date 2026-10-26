extends SceneTree

## v3.33 试驾页战斗反馈探针（`tests/drive_feedback_smoke.gd`）。
##
## 守的是本轮新增的三条**可达性**断言。为什么必须有它：
## 静态截图只能证明「没画坏」，证明不了「撞墙真的会冒数字」。
## 而本轮最初把伤害数字写在了 `_drive_resolve_impact()` 里——
## 那条路径在试驾页**永远不可达**（`ProjectileField._sweep()` 排除射手自己，
## 而试驾页发射方恒为 "player"），只跑 smoke 是发现不了的。
##
## 所以这里实例化真实 `main.tscn`，用正式入口 `_enter_drive()` 进页，
## 再把坦克摆到贴着边界的位置并给它一个朝向墙的速度，逐帧跑 `_drive_step()`，
## 断言：① 撞墙产生了伤害；② `_drive_hit_flash_left > 0`；③ 动效层里出现了 `kind == "damage"`。

const TankBody := preload("res://scripts/tank_body.gd")
const CombatView := preload("res://scripts/combat_view.gd")

var _main: Node = null
var _step := 0
var _failures := 0

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("DRIVE_FEEDBACK_SCENE_MISSING")
		_failures += 1
		return
	_main = packed.instantiate()
	get_root().add_child(_main)

func _process(_delta: float) -> bool:
	_step += 1
	if _step < 3:
		return false
	if _main == null:
		printerr("DRIVE_FEEDBACK_MAIN_NULL")
		quit(1)
		return true
	_run_checks()
	if _failures == 0:
		print("DRIVE_FEEDBACK_OK")
		quit(0)
	else:
		printerr("DRIVE_FEEDBACK_FAIL count=%d" % _failures)
		quit(1)
	return true

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		_failures += 1
		printerr("DRIVE_FEEDBACK_FAIL %s" % tag)

func _damage_entries() -> int:
	var counting := 0
	for raw_entry in _main._drive_fx.entries:
		if String((raw_entry as Dictionary).get("kind", "")) == "damage":
			counting += 1
	return counting

func _run_checks() -> void:
	## ① 走正式入口进试驾页（与截图钩子同一条路）。
	_main._enter_drive()
	_expect(_main._drive_ready, "drive_ready")
	if not _main._drive_ready:
		return
	var tank: TankBody = _main.tank
	_expect(tank != null and not tank.parts.is_empty(), "drive_tank_present")
	if tank == null or tank.parts.is_empty():
		return

	## ② 基线：刚进页时没有任何伤害数字，也没有命中闪光。
	_expect(_damage_entries() == 0, "no_damage_before_impact")
	_expect(float(_main._drive_hit_flash_left) <= 0.0, "no_hit_flash_before_impact")

	## ③ 贴着左边界摆好，再给一个朝左的速度。
	##    `apply_boundary()` 只在法向速度为正（正在压向墙）时才扣伤害，
	##    所以必须同时满足「已贴住」与「速度朝向墙」两个条件。
	var cell: float = tank.cell_size()
	tank.position = _main._drive_arena.position + tank.world_bounds().size * 0.5 + Vector2(cell * 0.5, 0.0)
	tank.heading = 0.0
	tank.velocity = Vector2(-400.0, 0.0)
	tank.angular_velocity = 0.0
	_main._drive_throttle = -1.0
	_main._drive_steer = 0.0
	_main._drive_held["throttle_down"] = true

	## ④ 逐固定步长推进，直到撞出伤害或超时。
	var step_time := 1.0 / float(maxi(_main.definitions.global_int("physics_hz", 60), 1))
	var damage_seen := false
	var flash_seen := false
	for index in range(120):
		_main._drive_step(step_time)
		if _damage_entries() > 0:
			damage_seen = true
		if float(_main._drive_hit_flash_left) > 0.0:
			flash_seen = true
		if damage_seen and flash_seen:
			break

	_expect(damage_seen, "wall_impact_pushed_damage_popup")
	_expect(flash_seen, "wall_impact_set_hit_flash")
	_expect(float(tank.impact_damage_total) > 0.0, "wall_impact_dealt_damage")

	## ⑤ 数字必须是「承受」语义（`-N`），不是「造成」（`+N`）——
	##    试驾页只有玩家一辆车，任何自伤显示成 `+N` 会看起来像治疗。
	var label := ""
	for raw_entry in _main._drive_fx.entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) == "damage":
			label = String(entry.get("text", ""))
			break
	_expect(label.begins_with("-"), "damage_popup_is_negative_%s" % label)
