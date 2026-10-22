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
