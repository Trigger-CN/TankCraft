extends SceneTree

## v3.52：生存模式 **Esc 中途暂停** 的回归测试。
##
## 为什么必须单独一个测试：`survival_smoke.gd::_check_survival_pause()` 只验证
## `SurvivalRun`（领域层）的 `toggle_pause()` / `step_battle()`，**完全绕过键盘分派**。
## 而本轮改的恰恰是分派层——`main.gd::_handle_survival_key()` 的 `KEY_ESCAPE` 分支。
## 只断言"paused 能切换"证明不了"按 Esc 会暂停"，必须真的把 InputEventKey 喂进去。
##
## 被测对象：真实实例化的 `main.gd`（Node2D），不是复制一份逻辑。
## 进入方式：直接调 `_enter_survival()`——它就是 `--screen=survival` 截图钩子与
## 主菜单"单人远征"共用的入口，所以测的是正式流程。

const MainScene := preload("res://scripts/main.gd")
const SurvivalRun := preload("res://scripts/survival_run.gd")
const Duel := preload("res://scripts/duel.gd")

var failures := 0
var main: Node2D


func _expect(condition: bool, tag: String) -> void:
	if condition:
		return
	failures += 1
	printerr("ESC_PAUSE_FAIL %s" % tag)


func _key_event(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = pressed
	event.echo = false
	return event


func _tap(keycode: Key) -> void:
	## 一次完整的按下+松开。快捷键处理只认 pressed，但松开也要发，
	## 否则按键集里会留下一个永远不释放的键（`_survival_held`）。
	main._handle_survival_key(_key_event(keycode, true))
	main._handle_survival_key(_key_event(keycode, false))


func _init() -> void:
	main = MainScene.new()
	get_root().add_child(main)
	## `_ready()` 会读 data；等它跑完。
	await process_frame
	await process_frame

	_test_esc_pauses_in_battle()
	_test_esc_resumes_in_battle()
	_test_p_and_esc_are_equivalent()
	_test_esc_in_modify_leaves_modify_only()
	_test_esc_in_shop_still_exits()
	_test_pause_blocks_fire()

	main.queue_free()
	if failures > 0:
		printerr("ESC_PAUSE_FAIL count=%d" % failures)
		quit(1)
		return
	print("ESC_PAUSE_OK")
	quit(0)


## 进入一个真实的第一波战斗。
func _enter() -> bool:
	main._enter_survival()
	if main.survival == null:
		_expect(false, "survival_is_null")
		return false
	if main.survival.stage != SurvivalRun.STAGE_BATTLE:
		_expect(false, "not_in_battle_stage_%s" % main.survival.stage)
		return false
	_expect(main.survival.paused == false, "fresh_run_should_not_be_paused")
	return true


## 核心用例：战斗里按 Esc → 仍在生存页 + 已暂停 + 阶段仍是 STAGE_BATTLE。
func _test_esc_pauses_in_battle() -> void:
	if not _enter():
		return
	var screen_before: String = main._screen
	_tap(KEY_ESCAPE)
	_expect(main.survival != null, "esc_should_not_destroy_run")
	_expect(main.survival.paused == true, "esc_should_pause")
	_expect(main.survival.stage == SurvivalRun.STAGE_BATTLE, "esc_should_keep_battle_stage")
	## 这一条是本轮的核心：旧实现会 `_exit_survival()`，`_screen` 变成主菜单。
	_expect(main._screen == screen_before, "esc_should_not_leave_survival_screen")
	_expect(main.survival != null and main.survival.duel != null, "esc_should_keep_duel")


## 再按一次 Esc → 恢复，且仍在生存页。
func _test_esc_resumes_in_battle() -> void:
	if main.survival == null:
		return
	_expect(main.survival.paused == true, "resume_case_should_start_paused")
	_tap(KEY_ESCAPE)
	_expect(main.survival.paused == false, "esc_again_should_resume")
	_expect(main.survival.stage == SurvivalRun.STAGE_BATTLE, "resume_should_keep_battle_stage")


## P 和 Esc 必须是同一条路径 —— 断言"效果完全一致"，而不是只看两者都能切。
func _test_p_and_esc_are_equivalent() -> void:
	main._enter_survival()
	if main.survival == null:
		return
	_expect(main.survival.paused == false, "equiv_start_unpaused")
	_tap(KEY_P)
	var paused_by_p: bool = main.survival.paused
	_tap(KEY_P)
	var resumed_by_p: bool = main.survival.paused
	_tap(KEY_ESCAPE)
	var paused_by_esc: bool = main.survival.paused
	_tap(KEY_ESCAPE)
	var resumed_by_esc: bool = main.survival.paused
	_expect(paused_by_p == true, "p_should_pause")
	_expect(resumed_by_p == false, "p_again_should_resume")
	_expect(paused_by_esc == true, "esc_should_pause_equiv")
	_expect(resumed_by_esc == false, "esc_again_should_resume_equiv")
	_expect(paused_by_p == paused_by_esc and resumed_by_p == resumed_by_esc,
			"p_and_esc_must_have_identical_effect")


## 改装页的 Esc 必须仍然只"退出改装"，不暂停、不退出生存。
func _test_esc_in_modify_leaves_modify_only() -> void:
	main._enter_survival()
	if main.survival == null:
		return
	main.survival._open_shop()
	main.survival.inventory.append("cannon_40")
	main._survival_enter_modify()
	if main.survival.stage != SurvivalRun.STAGE_MODIFY:
		_expect(false, "modify_case_setup_failed_%s" % main.survival.stage)
		return
	var stage_before: String = main.survival.stage
	_tap(KEY_ESCAPE)
	_expect(main.survival != null, "esc_in_modify_should_not_exit_survival")
	_expect(main.survival.stage != stage_before, "esc_in_modify_should_leave_modify")
	_expect(main.survival.paused == false, "esc_in_modify_should_not_pause")


## 商店页不在战斗，Esc 退出生存保持原样（防止我这次改动把"逐层返回"扩大成"到处暂停"）。
func _test_esc_in_shop_still_exits() -> void:
	main._enter_survival()
	if main.survival == null:
		return
	main.survival._open_shop()
	if main.survival.stage != SurvivalRun.STAGE_SHOP:
		_expect(false, "shop_case_setup_failed_%s" % main.survival.stage)
		return
	_tap(KEY_ESCAPE)
	_expect(main.survival == null or main._screen != main.SCREEN_SURVIVAL,
			"esc_in_shop_should_still_exit_survival")


## 暂停期间开火必须被挡住：`_is_battle_screen()` 是单一拦截点，这里验它真的生效。
##
## 必须先把炮管摆成「已装填」：刚进第一波时弹药还没造出来，
## 不摆的话正对照也打不出弹 —— 那样「暂停挡住了」与「本来就没弹」无法区分，
## 断言就没有区分力（v3.39 的教训：期望值必须来自独立可分辨的构造）。
func _test_pause_blocks_fire() -> void:
	main._enter_survival()
	if main.survival == null or main.survival.duel == null:
		return
	var bank: Object = main.survival.duel.bank_of(Duel.TAG_PLAYER)
	if bank == null or bank.cannons.is_empty():
		_expect(false, "block_case_no_cannon")
		return
	## 逐门炮置为已装填、冷却归零。这是构造，不是断言。
	for index in range(bank.cannons.size()):
		var cannon: Dictionary = bank.cannons[index]
		cannon["loaded"] = true
		cannon["reload_remaining"] = 0.0
	_tap(KEY_ESCAPE)
	_expect(main.survival.paused == true, "block_case_should_be_paused")
	## `_fire_battle_player` 是左键与空格共用的开火入口。
	## 观测量用 `field.shots.size()`：`CannonBank` **没有** `shots_fired` 字段，
	## 我把测试先写成读它，结果 Runtime 报 Invalid access —— 是测试错，不是产品错。
	var field: Object = main.survival.duel.field
	if field == null:
		_expect(false, "block_case_no_field")
		return
	var before: int = field.shots.size()
	main._fire_battle_player(Vector2(600.0, 500.0))
	_tap(KEY_SPACE)
	var after: int = field.shots.size()
	_expect(after == before, "fire_should_be_blocked_while_paused_%d_%d" % [before, after])
	## 正对照：恢复后同一入口**能**开火。没有这一步的话，上面的「没增加」
	## 可能只是因为炮管没弹，而不是因为暂停拦住。
	_tap(KEY_ESCAPE)
	_expect(main.survival.paused == false, "block_case_resume_failed")
	main._fire_battle_player(Vector2(600.0, 500.0))
	var resumed: int = field.shots.size()
	_expect(resumed > before, "fire_should_work_after_resume_%d_%d" % [before, resumed])
	_expect(main._is_battle_screen() == true, "battle_screen_should_be_true_after_resume")
