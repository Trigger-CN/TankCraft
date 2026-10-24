extends SceneTree

## v3.26 鼠标指针同步回归（`main.gd::_battle_pointer()`）。
##
## 守的是什么：「瞄准只在鼠标动了时才重算」。
##
## 修前实测（真实窗口，`stale1.txt`）：从菜单点进战斗页、玩家不动鼠标时，
## `_mouse_position` 仍是菜单上的 (390,400)，而真实光标在战场中心 (960,540)——
## 准星与炮口一起偏了 570×140 设计像素，且 (390,400) 落在 `DRIVE_VIEW` 内，
## 所以准星是**画出来的**、只是画错了地方——玩家看到的就是「错位」。
##
## 根因：`_mouse_position` 只由 `InputEventMouseMotion` 更新。
## 修法：战斗页每帧从 `get_viewport().get_mouse_position()` 取当前指针（`_battle_pointer()`），
## 并用它同时驱动准星绘制与炮口方向。
##
## **本测试的覆盖边界（必须如实）**：headless 下 `get_viewport().get_mouse_position()`
## 恒为 (0,0)，无法在这里模拟真实光标。所以本文件只断言「指针来源」这一条契约
## （① 不再读陈旧缓存；② 截图路径仍读缓存以保基线可比；③ 每帧同步是幂等的）。
## 「真实光标下准星与炮口逐像素对齐」由两个真实窗口探针
## （`stale2.txt` / `drift3.txt`）提供证据，**不是本测试**。

var _main: Node = null
var _step := 0
var _failures := 0

func _initialize() -> void:
	var packed: PackedScene = load("res://scenes/main.tscn")
	if packed == null:
		printerr("PTR_SCENE_MISSING")
		_failures += 1
		return
	_main = packed.instantiate()
	get_root().add_child(_main)

func _process(_delta: float) -> bool:
	_step += 1
	if _step < 3:
		return false
	if _main == null:
		printerr("PTR_MAIN_NULL")
		quit(1)
		return true
	_run_checks()
	if _failures == 0:
		print("POINTER_OK")
		quit(0)
	else:
		printerr("POINTER_FAIL count=%d" % _failures)
		quit(1)
	return true

func _expect(condition: bool, tag: String) -> void:
	if not condition:
		_failures += 1
		printerr("POINTER_FAIL %s" % tag)

func _run_checks() -> void:
	_main._enter_survival()
	_expect(_main.survival != null, "survival_entered")
	if _main.survival == null:
		return
	_expect(_main._is_battle_screen(), "is_battle_screen")
	var vp: Viewport = get_root()
	var live: Vector2 = vp.get_mouse_position()

	## ① 指针必须来自实时视口位置，而不是 `_mouse_position` 的陈旧缓存。
	##    这条正是修复的核心：改回 `return _mouse_position` 会立刻失败。
	_main._mouse_position = Vector2(700.0, 400.0)
	var pointer: Vector2 = _main._battle_pointer()
	_expect(pointer.is_equal_approx(live), "pointer_uses_live_viewport_%s_vs_%s" % [str(pointer), str(live)])
	_expect(not pointer.is_equal_approx(Vector2(700.0, 400.0)), "pointer_not_stale_cache")

	## ② 截图路径必须仍读 `_mouse_position`：`--capture` 会把它钉到 `--cursor=`，
	##    若这里改成读实时视口，截图会随桌面鼠标漂移，历史基线不再可比。
	_main._capture_target = "dummy.png"
	_main._mouse_position = Vector2(1234.0, 567.0)
	var frozen: Vector2 = _main._battle_pointer()
	_expect(frozen.is_equal_approx(Vector2(1234.0, 567.0)), "capture_path_uses_pinned_cursor")
	## 同一路径下每帧同步必须是**完全无操作**，否则截图帧也会漂。
	var before: Vector2 = _main._mouse_position
	_main._sync_battle_pointer()
	_expect(_main._mouse_position.is_equal_approx(before), "capture_path_sync_is_noop")
	_main._capture_target = ""

	## ③ 每帧同步幂等：连调两次，`_mouse_position` 必须停在同一个值（即实时指针）。
	_main._sync_battle_pointer()
	var first: Vector2 = _main._mouse_position
	_main._sync_battle_pointer()
	_expect(_main._mouse_position.is_equal_approx(first), "sync_is_idempotent")
	_expect(first.is_equal_approx(_main._battle_pointer()), "sync_writes_battle_pointer")

	## ④ 非战斗页不得改写指针：升级 / 商店 / 改装页上左键是别的语义，
	##    每帧同步若在那里也跑，会把 `_mouse_position` 从上一帧的点击位置改掉。
	_main.survival._open_shop()
	_expect(not _main._is_battle_screen(), "shop_is_not_battle_screen")
	var shop_mark: Vector2 = Vector2(222.0, 333.0)
	_main._mouse_position = shop_mark
	_main._sync_battle_pointer()
	_expect(_main._mouse_position.is_equal_approx(shop_mark), "non_battle_page_not_synced")
