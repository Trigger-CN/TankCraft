extends SceneTree

## 鼠标输入回归：把**真实的** `InputEventMouseButton` 灌进 `main.tscn` 的 `_input()`。
##
## 为什么必须走真实场景而不是直接调函数：`main.gd` 是 `extends Node2D`，
## `--script` 加载不了（只接受 `SceneTree` / `MainLoop` 子类），所以这里实例化
## `res://scenes/main.tscn` 并把事件交给它的 `_input()`——那才是玩家点鼠标时
## 真正走的入口，也只有这条路能复现「函数互调」这类只在调用链上成立的缺陷。
##
## 本测试守的是 v3.16 修掉的栈溢出：`_handle_mouse()` 曾在 `SCREEN_SURVIVAL` 时
## 回调 `_handle_survival_mouse()`，而后者结尾又调回 `_handle_mouse()`，
## 改装页里任何一次网格点击都会无限互调直到栈溢出。**纯函数级测试抓不到它**——
## 必须真的走一次 `_input()`。

var _main: Node = null
var _step := 0
var _failures := 0
## v3.25：第 ⑧ 条断言要直接用 `CannonBank` 类型标注（`_player_bank()` 的返回类型），
## 以及 `SurvivalRun.STAGE_BATTLE` 这个阶段常量。
const CannonBank := preload("res://scripts/cannon_bank.gd")
const SurvivalRun := preload("res://scripts/survival_run.gd")

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("MOUSE_SCENE_MISSING")
		_failures += 1
		return
	_main = packed.instantiate()
	get_root().add_child(_main)

func _process(_delta: float) -> bool:
	_step += 1
	## 等两帧让 `_ready()` 跑完（load_all 数据、建 builder、查窗口模式）。
	if _step < 3:
		return false
	if _main == null:
		printerr("MOUSE_MAIN_NULL")
		quit(1)
		return true
	_run_checks()
	if _failures == 0:
		print("MOUSE_OK")
		quit(0)
	else:
		printerr("MOUSE_FAIL count=%d" % _failures)
		quit(1)
	return true

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		_failures += 1
		printerr("MOUSE_FAIL %s" % tag)

func _send_button(position: Vector2, button: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = position
	event.global_position = position
	_main._input(event)

func _send_motion(position: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	_main._input(event)

func _run_checks() -> void:
	## 进生存页 → 进改装（走与截图钩子相同的正式入口，不硬赋 stage）。
	_main._enter_survival()
	_expect(_main.survival != null, "survival_entered")
	if _main.survival == null:
		return
	_main.survival._open_shop()
	_main._survival_enter_modify()
	_expect(_main._in_modify_mode(), "in_modify_mode")
	if not _main._in_modify_mode():
		return

	## ① 鼠标移动：`_input()` 的 motion 分支本来就不经 `_handle_survival_mouse`，
	##    这里确认它仍能正常更新 hover 而不炸。
	_send_motion(Vector2(652.0, 192.0))
	_expect(true, "modify_motion_survived")

	## ② 改装模式点网格：**旧代码正是在这一步栈溢出**。
	var grid_point := Vector2(652.0, 192.0)
	_send_button(grid_point, MOUSE_BUTTON_LEFT, true)
	_expect(_main._dragging, "modify_grid_press_started_drag")
	var cursor_after_press: Vector2i = _main._cursor
	## 期望值按公式算，不写死：(652-620)/32 = 1、(192-160)/32 = 1。
	_expect(cursor_after_press == Vector2i(1, 1), "modify_grid_cursor_%d_%d" % [cursor_after_press.x, cursor_after_press.y])

	## ③ 松开必须落笔并清掉 `_dragging`。旧代码把 release 在 `_handle_survival_mouse`
	##    里就 return 了，永远到不了 `_handle_mouse` 的拖拽提交分支。
	_send_button(grid_point, MOUSE_BUTTON_LEFT, false)
	_expect(not _main._dragging, "modify_release_clears_drag")

	## ④ 右键拆解也必须能穿到 `_handle_mouse`（同样曾触发栈溢出）。
	_send_button(grid_point, MOUSE_BUTTON_RIGHT, true)
	_send_button(grid_point, MOUSE_BUTTON_RIGHT, false)
	_expect(true, "modify_right_click_survived")

	## ⑤ 滚轮必须穿到 `_handle_mouse` 的模块列表滚动分支。
	var scroll_before: int = _main._option_scroll
	_send_button(Vector2(180.0, 500.0), MOUSE_BUTTON_WHEEL_DOWN, true)
	_expect(_main._option_scroll >= scroll_before, "modify_wheel_survived")

	## ⑥ 左键点「完成改装」必须真的退出改装（证明本页专属按钮仍然优先，
	##    修复没有把生存页自己的点击语义吞掉）。
	_main._survival_enter_modify()
	var leave: Rect2 = _main._modify_leave_button_rect()
	_send_button(leave.position + leave.size * 0.5, MOUSE_BUTTON_LEFT, true)
	_expect(not _main._in_modify_mode(), "modify_leave_button_works")

	## ⑦ 非改装阶段的生存页（战斗期）点鼠标也不能炸：此时 `_in_modify_mode()` 为假，
	##    旧代码会走到 `_handle_mouse()` 的 `_screen != SCREEN_BUILD` 早退分支。
	_main._survival_leave_modify()
	_send_button(grid_point, MOUSE_BUTTON_LEFT, true)
	_send_button(grid_point, MOUSE_BUTTON_LEFT, false)
	_expect(true, "battle_click_survived")

	## ⑧ v3.25：战斗期左键必须**真的开火且把炮口转向点击处**。
	##
	## 为什么这条必须存在：前七条只证明「点击不炸」，而本轮的核心需求是
	## 「鼠标瞄准 + 左键开火」。若 `_is_battle_screen()` 恒为假（例如 stage 判断
	## 写错），测试依旧全绿，玩家却点了没反应——那是一个会静默失效的回归。
	## 所以重新进入一局拿到真正的 `STAGE_BATTLE`，再断言两条可观察后果：
	## ① 炮管进入了 `aim_override` 模式；② 「最近事件」变成了开火反馈。
	_main._enter_survival()
	_expect(_main.survival != null, "battle_reentered")
	if _main.survival == null:
		return
	_expect(_main.survival.stage == SurvivalRun.STAGE_BATTLE, "battle_stage_battle")
	_expect(_main._is_battle_screen(), "battle_is_battle_screen")
	var player_bank: CannonBank = _main._player_bank()
	_expect(player_bank != null and not player_bank.cannons.is_empty(), "battle_has_player_bank")
	if player_bank == null or player_bank.cannons.is_empty():
		return
	var aim_before := bool(player_bank.cannons[0]["aim_override"])
	_expect(not aim_before, "battle_aim_override_starts_off")
	## 点在战场区中心的稍下方：`DRIVE_VIEW` 是 (320,168,1216,684)。
	var battle_point := Vector2(1100.0, 700.0)
	_send_button(battle_point, MOUSE_BUTTON_LEFT, true)
	_send_button(battle_point, MOUSE_BUTTON_LEFT, false)
	_expect(bool(player_bank.cannons[0]["aim_override"]), "battle_left_click_sets_aim_override")
	## 方向必须真的指向点击处：换算回世界后与 `aim_world` 一致（容差 0.02 rad）。
	var view := _main.DRIVE_VIEW as Rect2
	var arena: Rect2 = _main.survival.duel.arena
	var scale_factor: float = _main._survival_scale()
	var world: Vector2 = _main._screen_to_world(view, arena, battle_point, scale_factor)
	var cannon: Dictionary = player_bank.cannons[0]
	var centre: Vector2 = player_bank.body.world_position_of_cell(Vector2i(cannon["cell"]))
	var expected := (world - centre).angle()
	var delta := absf(wrapf(float(cannon["aim_world"]) - expected, -PI, PI))
	_expect(delta <= 0.02, "battle_aim_world_matches_click_delta=%.4f" % delta)
	## 事件文案：满装填时是「开火：N 发离膛」，冷却中是「未装填或冷却中」。
	## 两者都证明点击确实走到了开火入口（而不是被 `_handle_mouse()` 吞掉）。
	var event_text := String(_main._survival_event)
	_expect(event_text.begins_with("开火：") or event_text == "未装填或冷却中", "battle_fire_event_%s" % event_text)
