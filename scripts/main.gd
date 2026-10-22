extends Node2D

const ModuleDefs := preload("res://scripts/module_defs.gd")
const GridBuilder := preload("res://scripts/grid_builder.gd")
const Palette := preload("res://scripts/palette.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
const ProjectileField := preload("res://scripts/projectile_field.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")
const DamageSystem := preload("res://scripts/damage_system.gd")
const Duel := preload("res://scripts/duel.gd")
const MatchState := preload("res://scripts/match_state.gd")
const BotAI := preload("res://scripts/bot_ai.gd")
const SurvivalRun := preload("res://scripts/survival_run.gd")
## v3.11：瞬时动效层抽成独立类（三页共用一份 push / step / draw 语义）。
const FxLayer := preload("res://scripts/fx_layer.gd")

## M2 正式建造编辑器入口。
## 菜单、输入与绘制留在单一场景；建造状态和规则由 GridBuilder 负责。

const SCREEN_MAIN := "main_menu"
const SCREEN_SETTINGS := "settings"
const SCREEN_BUILD := "build_phase"
const SCREEN_DRIVE := "drive_lab"
const SCREEN_MATCH := "match_battle"
const SCREEN_SURVIVAL := "survival_battle"
const LAYER_PLATFORM := "platform"
const LAYER_MOBILITY := "mobility"
const LAYER_MODULE := "module"
const TOOL_SELECT := "select"
const TOOL_RECTANGLE := "rectangle"
const TOOL_LINE := "line"

const GRID_SIZE_VISUAL := Vector2i(24, 24)
const GRID_CELL := 32.0
const GRID_ORIGIN := Vector2(620.0, 160.0)
const PANEL_LEFT := Rect2(72.0, 190.0, 480.0, 700.0)
const PANEL_RIGHT := Rect2(1460.0, 190.0, 380.0, 700.0)
const USER_BLUEPRINT_PATH := "user://tankcraft_blueprints/autosave.json"
const MENU_ROW_X := 160.0
const MENU_ROW_Y := 360.0
const MENU_ROW_WIDTH := 460.0
const MENU_ROW_HEIGHT := 48.0
const MENU_ROW_STEP := 56.0
const BUILD_LAYER_X := 100.0
const BUILD_LAYER_Y := 260.0
const BUILD_OPTION_Y := 402.0
const BUILD_OPTION_STEP := 54.0
const BUILD_OPTION_HEIGHT := 48.0
const BUILD_OPTION_VISIBLE := 6
## 工具按钮顶边。旧值 785 与「工具」标签（baseline 793）重叠——标签直接压在按钮里（v3.18 修的）。
const BUILD_TOOL_Y := 800.0
## 非选中层的透明度。用户要求「选中一层时其他两层要变得透明且无法操作」：
## 0.22 能看清轮廓又不至于让人误以为可以点。
## 注：操作隔离本来就已经成立（每个编辑操作都只作用于 `_build_layer`），
## 这一条补的是**看得见**的那一半——之前三层同样亮度，玩家分不出在编哪一层。
const LAYER_DIM_ALPHA := 0.22
const MENU_ITEM_COUNT := 6
## M6：对战难度档（对应 design §10.3 四档）。
const MATCH_DIFFICULTY := ["recruit", "veteran", "elite", "ace"]
const MATCH_DIFFICULTY_LABEL := ["新兵", "老兵", "精英", "王牌"]
const DRIVE_VIEW := Rect2(320.0, 168.0, 1216.0, 684.0)
const DRIVE_HUD_LEFT := Rect2(48.0, 168.0, 248.0, 684.0)
const DRIVE_HUD_RIGHT := Rect2(1560.0, 168.0, 312.0, 684.0)
const DRIVE_STATUS := Rect2(320.0, 872.0, 1216.0, 72.0)
const DRIVE_ARENA_ID := "arena_standard"
const DRIVE_MAX_STEPS := 8
const DRIVE_RELOAD_PULSE_TIME := 0.5
const UI_ENTER_TIME := 0.16
const FOCUS_RAIL_SPEED := 4.0
const POINTER_TRANSITION := 0.18

var definitions: ModuleDefs
var builder: GridBuilder
var _screen := SCREEN_MAIN
var _menu_index := 0
var _settings_index := 0
var _build_layer := LAYER_MODULE
var _tool := TOOL_SELECT
var _selected_index := 0
var _option_scroll := 0
var _rotation := 0
var _aim := 0
var _cursor := Vector2i(9, 8)
var _mouse_position := Vector2.ZERO
var _mouse_over_grid := false
var _hover_menu_index := -1
var _hover_settings_index := -1
var _hover_option_index := -1
var _hover_tool_index := -1
var _hover_layer_index := -1
## 生存页与改装页按钮的 hover 状态（此前这两页只有键盘，鼠标移上去毫无反馈）。
var _hover_survival_button := false
var _hover_modify_button := false
## 主菜单「难度」按钮的 hover 状态。
var _hover_menu_difficulty := false
var _dragging := false
var _drag_origin := Vector2i.ZERO
var _erase_drag := false
var _glow_enabled := true
var _motion_enabled := true
var _time := 0.0
var _screen_opacity := 0.0
var _focus_rail_y := MENU_ROW_Y
var _focus_rail_alpha := 0.0
var _status_message := ""
var _status_error := false
var _capture_target := ""
var _capture_wait_frames := 30
## 截图期间冻结模拟与 `_time`。
## 起因：`_capture_next_frame()` 要等 30 帧才取图，而 `_process()` 在这 30 帧里
## 仍按真实 delta 推进 `_*_simulate()` 并累加 `_time`——预热步数虽然是固定的，
## 但预热之后到取图之间又跑了不确定的步数，于是同一条 `--capture` 命令两次
## 可以产出不同字节。实测：同一命令连续两次得到 177682 B 与 177340 B，
## 逐像素差 12993 个、最大通道和 546。截图既然要用来做逐字节等价证明，
## 就必须让「取图那一刻」成为预热结果的确定函数。
var _capture_frozen := false
## `--steps=N`：把各页截图预热的总步数从写死的常量改成可传入。
## 为什么需要：验证「渲染是否回归」必须在**同一模拟状态**下比两帧。以前预热步数写死，
## 只能证明「同一命令两次相同」，无法证明「不同构建在同一状态下的绘制相同」。
## 传了 `--steps` 就能：① 同一 N 两次截图逐字节相同（可复现）；② 不同 N 必须产出不同图
## （反向对照，证明参数真的生效、不是被忽略）；③ 修 bug 前后用同一 N 比像素。
## -1 表示「用该页原来的默认值」，保证不带参数时的历史基线不被改变。
var _capture_steps := -1
var tank: TankBody
var bank: CannonBank
var field: ProjectileField
var network: AmmoNetwork
var damage: DamageSystem
var _drive_ready := false
var _drive_arena := Rect2()
var _drive_obstacles: Array = []
var _drive_throttle := 0.0
var _drive_steer := 0.0
var _drive_held: Dictionary = {}
var _drive_accumulator := 0.0
var _drive_track_phase := 0.0
var _drive_last_event := ""
## M5 战斗动效：残骸闪光、爆炸环与脱落撕裂的剩余秒数（全部只用于绘制）。
var _drive_fx := FxLayer.new()
## M5：装填完成是一次边沿（loaded false → true），电平本身无法表达「脉冲一次」。
var _drive_cannon_pulse: Dictionary = {}
var _drive_cannon_loaded: Array = []
## M6 对局：MatchState 包一层对局实体的 Duel，AI 驱动敌方侧。
var match_session: MatchState
var match_ai: BotAI
var match_enemy_builder: GridBuilder
var _match_ready := false
var _match_difficulty := 1
var _match_accumulator := 0.0
var _match_held: Dictionary = {}
var _match_event := ""
var _match_fx := FxLayer.new()
## M9 波次生存：SurvivalRun 承载 run 状态，玩家坦克由 survival_builder 持有（波间不回滚）。
var survival: SurvivalRun
var survival_builder: GridBuilder
var _survival_ready := false
var _survival_accumulator := 0.0
var _survival_held: Dictionary = {}
var _survival_event := ""
var _font_regular: SystemFont
var _font_mono: SystemFont

## 建造页与改装页共用同一套编辑器实现（网格、模块目录、工具、撤销/重做、蓝图存读）。
## 两页只差“模型来源”与“支付策略”：建造页用 `builder`（预算/质量上限由它自己管），
## 改装页用 `survival_builder`（budget_enabled = false，钱由 SurvivalRun 按净增结算）。
## 这也是为什么下面所有编辑器函数都走 `_editor_model()` 而不是直接拿 `builder`。
func _editor_model() -> GridBuilder:
	if _screen == SCREEN_SURVIVAL and survival != null and survival.stage == SurvivalRun.STAGE_MODIFY:
		return survival_builder
	return builder

func _in_build_editor() -> bool:
	return _screen == SCREEN_BUILD or _in_modify_mode()

## 改装模式：生存页且阶段是 STAGE_MODIFY。所有编辑器行为靠它分流，不另开一套页面代码。
func _in_modify_mode() -> bool:
	return _screen == SCREEN_SURVIVAL and survival != null and survival.stage == SurvivalRun.STAGE_MODIFY

## 「退出改装」按钮（网格右上角、抬到 y=80 避开网格上方的 GRID / cursor 读数行），与 Esc 等价。
func _modify_leave_button_rect() -> Rect2:
	return Rect2(GRID_ORIGIN.x + 24.0 * GRID_CELL - 176.0, 80.0, 176.0, 36.0)

func _ready() -> void:
	definitions = ModuleDefs.new()
	if not definitions.load_all():
		for message in definitions.errors():
			printerr("M1_DATA_ERROR " + message)
		get_tree().quit(1)
		return
	builder = GridBuilder.new()
	if not builder.setup(definitions):
		printerr("M2_BUILD_SETUP_ERROR")
		get_tree().quit(1)
		return
	builder.reset_demo()
	tank = TankBody.new()
	bank = CannonBank.new()
	field = ProjectileField.new()
	_load_fonts()
	## 用户要求启动即最大化。`project.godot` 里已写 `window/size/mode=2`（MAXIMIZED），
	## 但项目配置只在启动时读一次且可被覆盖；这里再显式确认一次并打印实际结果，
	## 不靠“配置写了就算做到了”。
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_MAXIMIZED and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MAXIMIZED)
	print("WINDOW_MODE mode=%d size=%s" % [DisplayServer.window_get_mode(), str(DisplayServer.window_get_size())])
	_status_message = "正式数据蓝图已载入：可用 A/D 选件，Enter 放置。"
	_handle_capture_request()
	queue_redraw()

func _process(delta: float) -> void:
	## 截图取图前冻结：预热步数固定，取图那一刻的状态也必须是确定的，
	## 否则等待的 30 帧会按真实 delta 继续推进模拟，同一命令两次产出不同图。
	if _capture_frozen:
		return
	_time += delta
	var menu_data: Dictionary = definitions.registry.globals.get("menu", {})
	var transition_time: float = float(menu_data.get("menu_transition_time_s", 0.18))
	var focus_time: float = float(menu_data.get("menu_focus_time_s", 0.12))
	_screen_opacity = move_toward(_screen_opacity, 1.0, delta / maxf(transition_time, 0.01))
	var focus_target: float = _focus_target_y()
	_focus_rail_y = move_toward(_focus_rail_y, focus_target, delta * MENU_ROW_STEP / maxf(focus_time, 0.01))
	_focus_rail_alpha = move_toward(_focus_rail_alpha, 1.0 if _hover_menu_index >= 0 or _hover_settings_index >= 0 else 0.72, delta / POINTER_TRANSITION)
	if _motion_enabled or not is_equal_approx(_screen_opacity, 1.0) or not is_equal_approx(_focus_rail_y, focus_target):
		queue_redraw()
	if _screen == SCREEN_DRIVE:
		_drive_simulate(delta)
		queue_redraw()

	if _screen == SCREEN_MATCH:
		_match_simulate(delta)
		queue_redraw()

	if _screen == SCREEN_SURVIVAL:
		_survival_simulate(delta)
		queue_redraw()

func _load_fonts() -> void:
	_font_regular = SystemFont.new()
	_font_regular.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans SC", "SimHei", "sans-serif"])
	_font_mono = SystemFont.new()
	_font_mono.font_names = PackedStringArray(["JetBrains Mono", "Consolas", "Cascadia Mono", "monospace"])

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		var design_position := _design_position(motion.position)
		_mouse_position = design_position
		_update_hover(design_position)
		if _screen == SCREEN_BUILD:
			if _grid_rect().has_point(design_position):
				_cursor = _mouse_to_cell(design_position)
				_mouse_over_grid = true
				queue_redraw()
			else:
				_mouse_over_grid = false
		if _dragging and _grid_rect().has_point(design_position):
			_cursor = _mouse_to_cell(design_position)
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var button_event: InputEventMouseButton = event as InputEventMouseButton
		## 生存页必须在**入口处**就分流：`_handle_survival_mouse()` 会单向转发给
		## `_handle_mouse()`，而 `_handle_mouse()` 不再回跳——否则两者互调会无限递归。
		if _screen == SCREEN_SURVIVAL:
			_handle_survival_mouse(button_event, _design_position(button_event.position))
		else:
			_handle_mouse(button_event)
		return
	if not event is InputEventKey:
		return
	var key_event: InputEventKey = event as InputEventKey
	if _screen == SCREEN_DRIVE:
		_handle_drive_key(key_event)
		return
	## M9：生存页同样需要 key-up（保持按键集），必须在 pressed/echo 过滤之前。
	if _screen == SCREEN_SURVIVAL:
		_handle_survival_key(key_event)
		return
	## M6：对局页需要 key-up 事件（保持按键集），所以放在 pressed/echo 过滤之前。
	if _screen == SCREEN_MATCH:
		_handle_match_key(key_event)
		return
	if not key_event.pressed or key_event.echo:
		return
	_handle_key(key_event)

func _handle_key(event: InputEventKey) -> void:
	var key: Key = event.keycode
	if _screen == SCREEN_MAIN:
		if key == KEY_UP or key == KEY_W:
			_menu_index = maxi(_menu_index - 1, 0)
		elif key == KEY_DOWN or key == KEY_S:
			_menu_index = mini(_menu_index + 1, MENU_ITEM_COUNT - 1)
		elif key == KEY_ENTER or key == KEY_KP_ENTER or key == KEY_SPACE:
			_activate_main_menu()
		elif key == KEY_A or key == KEY_LEFT:
			_cycle_match_difficulty(-1)
		elif key == KEY_D or key == KEY_RIGHT:
			_cycle_match_difficulty(1)
		queue_redraw()
		return
	if _screen == SCREEN_SETTINGS:
		if key == KEY_UP or key == KEY_W:
			_settings_index = maxi(_settings_index - 1, 0)
		elif key == KEY_DOWN or key == KEY_S:
			_settings_index = mini(_settings_index + 1, 2)
		elif key == KEY_ENTER or key == KEY_KP_ENTER or key == KEY_SPACE:
			_toggle_setting()
		elif key == KEY_ESCAPE:
			_set_screen(SCREEN_MAIN)
		queue_redraw()
		return
	if _screen != SCREEN_BUILD:
		return
	_handle_build_key(event)

func _set_screen(next_screen: String) -> void:
	if _screen == next_screen:
		return
	_screen = next_screen
	_screen = next_screen
	_screen_opacity = 0.0
	_mouse_over_grid = false
	_hover_option_index = -1
	_hover_tool_index = -1
	_hover_layer_index = -1
	_focus_rail_y = _focus_target_y()

func _menu_index_at(position: Vector2) -> int:
	for index in range(MENU_ITEM_COUNT):
		if _menu_row_rect(index).has_point(position):
			return index
	return -1

func _settings_index_at(position: Vector2) -> int:
	for index in range(3):
		if _settings_row_rect(index).has_point(position):
			return index
	return -1

func _build_option_index_at(position: Vector2) -> int:
	var options: PackedStringArray = _option_ids()
	var visible_count := maxi(mini(options.size() - _option_scroll, BUILD_OPTION_VISIBLE), 0)
	for visible_index in range(visible_count):
		if _build_option_rect(visible_index).has_point(position):
			return _option_scroll + visible_index
	return -1

func _menu_row_rect(index: int) -> Rect2:
	return Rect2(MENU_ROW_X, MENU_ROW_Y + float(index) * MENU_ROW_STEP, MENU_ROW_WIDTH, MENU_ROW_HEIGHT)

func _settings_row_rect(index: int) -> Rect2:
	return Rect2(220.0, 360.0 + float(index) * MENU_ROW_STEP, 620.0, MENU_ROW_HEIGHT)

func _build_layer_rect(index: int) -> Rect2:
	## 面板标题行占 y=210–232、分隔线在 y=248（`_draw_panel` 的 +58）。
	## 旧值 230 会让「1 平台层」直接压在分隔线甚至标题上（v3.18 修的）。
	return Rect2(BUILD_LAYER_X, 258.0 + float(index) * 44.0, 420.0, 38.0)

func _build_option_rect(visible_index: int) -> Rect2:
	return Rect2(BUILD_LAYER_X, BUILD_OPTION_Y + float(visible_index) * BUILD_OPTION_STEP, 420.0, BUILD_OPTION_HEIGHT)

func _build_tool_rect(index: int) -> Rect2:
	return Rect2(BUILD_LAYER_X + float(index) * 140.0, BUILD_TOOL_Y, 130.0, 38.0)

func _build_footer_layer_rect(index: int) -> Rect2:
	return Rect2(620.0 + float(index) * 170.0, 950.0, 150.0, 38.0)

func _option_list_rect() -> Rect2:
	return Rect2(BUILD_LAYER_X, BUILD_OPTION_Y, 420.0, BUILD_OPTION_STEP * float(BUILD_OPTION_VISIBLE))

func _scroll_options(direction: int) -> void:
	var max_scroll := maxi(_option_ids().size() - BUILD_OPTION_VISIBLE, 0)
	_option_scroll = clampi(_option_scroll + direction, 0, max_scroll)
	_hover_option_index = -1
	queue_redraw()

func _focus_target_y() -> float:
	if _screen == SCREEN_MAIN:
		return MENU_ROW_Y + float(_menu_index) * MENU_ROW_STEP
	if _screen == SCREEN_SETTINGS:
		return MENU_ROW_Y + float(_settings_index) * MENU_ROW_STEP
	return MENU_ROW_Y

func _activate_main_menu() -> void:
	if _menu_index == 0:
		_enter_survival()
	elif _menu_index == 1:
		_enter_drive()
	elif _menu_index == 2:
		_enter_match()
	elif _menu_index == 3:
		_set_screen(SCREEN_BUILD)
		builder.reset_demo()
		## 与改装页一致：整车居中，不要贴在 24×24 网格的左上角。
		builder.center_content()
		var seats: Array[Vector2i] = builder.cockpit_cells()
		_cursor = seats[0] if not seats.is_empty() else Vector2i(9, 8)
		_status_message = "正式 M2 建造编辑器：所有价格与质量来自 data/*.json。"
		_status_error = false
	elif _menu_index == 4:
		_settings_index = 0
		_set_screen(SCREEN_SETTINGS)
	else:
		get_tree().quit()
	queue_redraw()

func _toggle_setting() -> void:
	if _settings_index == 0:
		_glow_enabled = not _glow_enabled
		var environment_node: WorldEnvironment = get_node_or_null("WorldEnvironment") as WorldEnvironment
		if environment_node != null and environment_node.environment != null:
			environment_node.environment.glow_enabled = _glow_enabled
	elif _settings_index == 1:
		_motion_enabled = not _motion_enabled
	else:
		_set_screen(SCREEN_MAIN)
	queue_redraw()

func _handle_build_key(event: InputEventKey) -> void:
	var key: Key = event.keycode
	if key == KEY_ESCAPE:
		_set_screen(SCREEN_MAIN)
		queue_redraw()
		return
	if key == KEY_1:
		_select_layer(LAYER_PLATFORM)
	elif key == KEY_2:
		_select_layer(LAYER_MOBILITY)
	elif key == KEY_3:
		_select_layer(LAYER_MODULE)
	elif key == KEY_LEFT:
		_cursor.x = maxi(_cursor.x - 1, 0)
	elif key == KEY_RIGHT:
		_cursor.x = mini(_cursor.x + 1, _editor_model().grid_size.x - 1)
	elif key == KEY_UP:
		_cursor.y = maxi(_cursor.y - 1, 0)
	elif key == KEY_DOWN:
		_cursor.y = mini(_cursor.y + 1, _editor_model().grid_size.y - 1)
	elif key == KEY_A:
		_cycle_selection(-1)
	elif key == KEY_D:
		_cycle_selection(1)
	elif key == KEY_Q:
		_adjust_aim_or_selection(-1)
	elif key == KEY_E:
		_adjust_aim_or_selection(1)
	elif key == KEY_R:
		_rotate_current()
	elif key == KEY_X:
		_remove_current()
	elif key == KEY_M and event.shift_pressed:
		_set_status(_editor_model().refund_mass_upgrade())
	elif key == KEY_M:
		_set_status(_editor_model().buy_mass_upgrade())
	elif key == KEY_Z and event.ctrl_pressed:
		_set_status("" if _editor_model().undo() else "没有可撤销的操作。")
	elif key == KEY_Y and event.ctrl_pressed:
		_set_status("" if _editor_model().redo() else "没有可重做的操作。")
	elif key == KEY_S and event.ctrl_pressed:
		_save_blueprint()
	elif key == KEY_O and event.ctrl_pressed:
		_load_blueprint()
	elif key == KEY_C:
		_focus_cockpit()
	queue_redraw()

## 切层。三层的**操作隔离本来就成立**（每个编辑操作都只作用于 `_build_layer`），
## 这里额外做两件事（用户 2026-10-21：「光标所持的配件也要根据选中层切换」）：
## ① 把 `_selected_index` 归零——旧值是新层列表里的任意下标，切过去会拿着一个
##    看起来莫名其妙的件；归零后光标总是从该层第一个可选件开始。
## ② 重置 `_rotation` / `_aim`——上一个层的旋转/射向对下一个层没有意义。
func _select_layer(layer: String) -> void:
	_build_layer = layer
	_selected_index = 0
	_rotation = 0
	_aim = 0
	_ensure_option_visible()
	_status_error = false
	var selected: Dictionary = _selected_definition()
	if selected.is_empty():
		_set_status("当前层没有可选配件。")
	else:
		_set_status("层：%s · 光标件：%s" % [_layer_label(layer), String(selected.get("name", "配件"))])

func _cycle_selection(step: int) -> void:
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return
	_selected_index = posmod(_selected_index + step, options.size())
	_ensure_option_visible()
	_rotation = 0
	_aim = 0
	var definition: Dictionary = definitions.get_module(String(options[_selected_index]))
	_set_status("已选择：%s。" % String(definition.get("name", options[_selected_index])))

func _ensure_option_visible() -> void:
	var count := _option_ids().size()
	## `_selected_index` 是 **`_option_ids()` 的下标**，不是库存下标、也不是模块总数。
	## 库存会变（贴装 -1、拆解 +1、商店购买 +1），而 `_option_ids()` 在改装期是
	## 「按当前层过滤 + 去重」后的结果，**长度与库存不一致**。任何一处漏钳制，
	## 下一帧 `_draw_grid()` 里的 `_preview_cells()` 就会越界（用户报告的崩溃）。
	## 这里是所有「选项集合变化」之后的统一收口点，所以钳制放在最前面。
	_selected_index = clampi(_selected_index, 0, maxi(count - 1, 0))
	var max_scroll := maxi(count - BUILD_OPTION_VISIBLE, 0)
	_option_scroll = clampi(_option_scroll, 0, max_scroll)
	if _selected_index < _option_scroll:
		_option_scroll = _selected_index
	elif _selected_index >= _option_scroll + BUILD_OPTION_VISIBLE:
		_option_scroll = _selected_index - BUILD_OPTION_VISIBLE + 1

func _adjust_aim_or_selection(step: int) -> void:
	if _build_layer == LAYER_MODULE:
		var selected_part: Dictionary = _editor_model().part_at(LAYER_MODULE, _cursor)
		if not selected_part.is_empty() and String(selected_part["part"]["id"]).begins_with("cannon_"):
			_set_status(_editor_model().adjust_aim(_cursor, step))
			return
	_cycle_selection(step)

func _rotate_current() -> void:
	var existing: Dictionary = _editor_model().part_at(_build_layer, _cursor)
	if _build_layer != LAYER_PLATFORM and not existing.is_empty():
		_set_status(_editor_model().rotate_part(_build_layer, _cursor))
		return
	_rotation = posmod(_rotation + 90, 360)
	_set_status("预览朝向：%d°。确认后固定。" % _rotation)

func _remove_current() -> void:
	## 改装期的拆解必须退回库存并检查结构合法性，所以走 `SurvivalRun.dismantle_at()`；
	## 建造页直接走 `GridBuilder.remove_at()`。两者都是同一套 I1–I10 规则。
	if _in_modify_mode() and survival != null:
		_set_status(survival.dismantle_at(_build_layer, _cursor))
		_ensure_option_visible()
		return
	_set_status(_editor_model().remove_at(_build_layer, _cursor))

func _update_hover(position: Vector2) -> void:
	var old_menu := _menu_index
	var old_settings := _settings_index
	var old_hover_menu := _hover_menu_index
	var old_hover_settings := _hover_settings_index
	var old_option := _hover_option_index
	var old_tool := _hover_tool_index
	var old_layer := _hover_layer_index
	var old_survival_button := _hover_survival_button
	var old_modify_button := _hover_modify_button
	var old_menu_difficulty := _hover_menu_difficulty
	_hover_menu_index = -1
	_hover_settings_index = -1
	_hover_option_index = -1
	_hover_tool_index = -1
	_hover_layer_index = -1
	_hover_modify_button = false
	_hover_survival_button = false
	_hover_menu_difficulty = false
	if _screen == SCREEN_MAIN:
		_hover_menu_index = _menu_index_at(position)
		if _hover_menu_index >= 0:
			_menu_index = _hover_menu_index
	elif _screen == SCREEN_SETTINGS:
		_hover_settings_index = _settings_index_at(position)
		if _hover_settings_index >= 0:
			_settings_index = _hover_settings_index
	elif _in_build_editor():
		for index in range(3):
			if _build_layer_rect(index).has_point(position):
				_hover_layer_index = index
				break
		for index in range(3):
			if _build_footer_layer_rect(index).has_point(position):
				_hover_layer_index = index
				break
		for index in range(3):
			if _build_tool_rect(index).has_point(position):
				_hover_tool_index = index
				break
		_hover_option_index = _build_option_index_at(position)
		_hover_modify_button = _in_modify_mode() and _modify_leave_button_rect().has_point(position)
	elif _screen == SCREEN_SURVIVAL:
		_hover_survival_button = (survival != null and (survival.stage == SurvivalRun.STAGE_LEVEL_UP or survival.stage == SurvivalRun.STAGE_SHOP) and _survival_modify_button_rect().has_point(position))
	_mouse_position = position
	if old_menu != _menu_index or old_settings != _settings_index or old_hover_menu != _hover_menu_index or old_hover_settings != _hover_settings_index or old_option != _hover_option_index or old_tool != _hover_tool_index or old_layer != _hover_layer_index or old_survival_button != _hover_survival_button or old_modify_button != _hover_modify_button or old_menu_difficulty != _hover_menu_difficulty:
		queue_redraw()



func _handle_mouse(event: InputEventMouseButton) -> void:
	var position := _design_position(event.position)
	_mouse_position = position
	if (event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN) and event.pressed:
		if _in_build_editor() and _option_list_rect().has_point(position):
			_scroll_options(-1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
		return
	if not event.pressed:
		if _in_build_editor() and _dragging:
			_dragging = false
			if _tool == TOOL_RECTANGLE:
				_set_status(_editor_model().paint_rectangle(_drag_origin, _cursor, _erase_drag))
			elif _tool == TOOL_LINE:
				_set_status(_editor_model().paint_line(_drag_origin, _cursor, _erase_drag))
			elif _tool == TOOL_SELECT and _build_layer != LAYER_PLATFORM and _drag_origin != _cursor:
				_set_status(_editor_model().move_part(_build_layer, _drag_origin, _cursor))
			queue_redraw()
		return
	_update_hover(position)
	if _screen == SCREEN_MAIN:
		if event.button_index == MOUSE_BUTTON_LEFT and _menu_difficulty_rect().has_point(position):
			_cycle_match_difficulty(1)
			return
		var menu_hit: int = _menu_index_at(position)
		if menu_hit >= 0:
			_menu_index = menu_hit
			_activate_main_menu()
		return
	if _screen == SCREEN_SETTINGS:
		var setting_index: int = _settings_index_at(position)
		if setting_index >= 0:
			_settings_index = setting_index
			_toggle_setting()
	## 生存页的鼠标分流在 `_input()` 里做，这里**不再**回跳 `_handle_survival_mouse()`——
	## 两者互调会无限递归（v3.16 修过一次栈溢出），转发方向只能单向。
	if _screen != SCREEN_BUILD and not _in_modify_mode():
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if _grid_rect().has_point(position):
			_cursor = _mouse_to_cell(position)
			_remove_current()
		queue_redraw()
		return
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if _grid_rect().has_point(position):
			_cursor = _mouse_to_cell(position)
			_remove_current()
		queue_redraw()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	if _grid_rect().has_point(position):
		_cursor = _mouse_to_cell(position)
		_drag_origin = _cursor
		_dragging = true
		_erase_drag = event.shift_pressed
		if _tool == TOOL_SELECT and _erase_drag:
			_remove_current()
		elif _tool == TOOL_SELECT and _build_layer == LAYER_PLATFORM:
			_set_status(_place_current())
		elif _tool == TOOL_SELECT and _editor_model().part_at(_build_layer, _cursor).is_empty():
			_set_status(_place_current())
		queue_redraw()
		return
	_handle_build_panel_click(position)

func _remove_part_under_mouse() -> String:
	var existing: Dictionary = _editor_model().part_at(_build_layer, _cursor)
	if existing.is_empty():
		return "当前层此格没有部件。"
	return _editor_model().remove_at(_build_layer, _cursor)

func _handle_build_panel_click(position: Vector2) -> void:
	for index in range(3):
		if _build_layer_rect(index).has_point(position):
			_select_layer([LAYER_PLATFORM, LAYER_MOBILITY, LAYER_MODULE][index])
			queue_redraw()
			return
	for index in range(3):
		if _build_footer_layer_rect(index).has_point(position):
			_select_layer([LAYER_PLATFORM, LAYER_MOBILITY, LAYER_MODULE][index])
			queue_redraw()
			return
	for index in range(3):
		if _build_tool_rect(index).has_point(position):
			_tool = [TOOL_SELECT, TOOL_RECTANGLE, TOOL_LINE][index]
			if _tool != TOOL_SELECT:
				_select_layer(LAYER_PLATFORM)
				_tool = [TOOL_SELECT, TOOL_RECTANGLE, TOOL_LINE][index]
			_status_error = false
			queue_redraw()
			return
	var option_index := _build_option_index_at(position)
	if option_index >= 0:
		_selected_index = option_index
		_rotation = 0
		_aim = 0
		_set_status("已选择：%s。" % String(_selected_definition().get("name", "配件")))
		queue_redraw()


func _place_current() -> String:
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return "拒绝：当前层没有可用模块。"
	var module_id: String = String(options[clampi(_selected_index, 0, options.size() - 1)])
	if _build_layer == LAYER_PLATFORM:
		if module_id == "platform_cell":
			return _place_platform_cell_at(_cursor)
		return _editor_model().place_platform_shape(module_id, _cursor, _rotation)
	## 改装模式下配件来自库存：放置必须走 `mount_from_inventory()`，
	## 否则会绕开 SurvivalRun 的 credit 结算（builder 的 budget_enabled 是 false）。
	if _in_modify_mode():
		return _mount_selected_inventory()
	return _editor_model().place_mobility(module_id, _cursor, _rotation) if _build_layer == LAYER_MOBILITY else _editor_model().place_module(module_id, _cursor, _rotation, _aim)

## 铺一格平台：改装期走 `SurvivalRun.place_platform_at()`（带 credit 检查），
## 建造页直接走 `GridBuilder`（预算由它自己管）。
func _place_platform_cell_at(cell: Vector2i) -> String:
	if _in_modify_mode():
		return survival.place_platform_at(cell)
	return _editor_model().place_platform_cell(cell)

## 改装期把光标选中的那一件（`_selected_index` 指向 `_option_ids()` 的某个 id）贴到光标处。
##
## **为什么不能直接拿 `_selected_index` 当库存下标**：`_option_ids()` 在改装期是
## 「按当前层过滤 + 去重」后的结果，与 `survival.inventory` **长度不同、顺序也不同**。
## 旧实现写的是 `clampi(_selected_index, 0, inventory.size() - 1)`，于是：
## ① 下标 8 在库存 12 件时「合法」，但可选件只有 8 个 → 绘制时越界崩溃（用户报告）；
## ② 就算不越界，也会贴装**另一件**配件（下标语义错位）。
## 现在先用 `_option_ids()` 把下标翻成 module_id，再到库存里找它的**实际位置**。
func _mount_selected_inventory() -> String:
	if survival == null:
		return "拒绝：无生存 run。"
	if survival.inventory.is_empty():
		return "拒绝：库存为空。先购买或领取配件。"
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return "拒绝：当前层没有可选配件。"
	var module_id := String(options[clampi(_selected_index, 0, options.size() - 1)])
	var index := survival.inventory.find(module_id)
	if index < 0:
		return "拒绝：库存里找不到 %s。" % module_id
	var reason := survival.mount_from_inventory(index, _cursor, _rotation, _aim)
	if reason.is_empty():
		## 库存少了一件，**可选件列表也跟着少一件**——但两者长度不等（`_option_ids()`
		## 是按层过滤并去重后的结果）。旧代码把 `_selected_index` 钳制到
		## `inventory.size() - 1` 是错的：库存 12 件、模块层 9 个不同 id 时，
		## 贴装后库存 11、可选件 8，下标 8 就越界。统一交给 `_ensure_option_visible()`
		## 按**可选件数量**钳制，不要在这里再写一套口径。
		_ensure_option_visible()
		return "已贴装：%s" % module_id
	return reason

## 编辑器当前层的可选件：建造页是全部模块，改装页只有库存里本层的件。
func _option_ids() -> PackedStringArray:
	if _in_modify_mode():
		var ids := PackedStringArray()
		if survival == null:
			return ids
		var seen: Dictionary = {}
		for raw_id in survival.inventory:
			var module_id := String(raw_id)
			if seen.has(module_id):
				continue
			if String(definitions.get_module(module_id).get("layer", "")) != _build_layer:
				continue
			seen[module_id] = true
			ids.append(module_id)
		return ids
	return definitions.module_ids(_build_layer)

## 层的中文名。三个地方（侧边栏 / 底栏 / 状态提示）都用它，避免各写一份字符串。
func _layer_label(layer: String) -> String:
	if layer == LAYER_PLATFORM:
		return "平台层"
	if layer == LAYER_MOBILITY:
		return "行进机构层"
	return "功能模块层"

func _selected_definition() -> Dictionary:
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return {}
	var index := clampi(_selected_index, 0, options.size() - 1)
	return definitions.get_module(String(options[index]))

func _placement_error() -> String:
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return ""
	var module_id: String = String(options[clampi(_selected_index, 0, options.size() - 1)])
	return _editor_model().placement_error(_build_layer, module_id, _cursor, _rotation, _aim)

func _focus_cockpit() -> void:
	var cells: Array[Vector2i] = _editor_model().cockpit_cells()
	if not cells.is_empty():
		_cursor = cells[0]
		_set_status("已定位驾驶舱死穴。")
	else:
		_set_status("当前蓝图没有驾驶舱。")

func _set_status(message: String) -> void:
	if message.is_empty():
		_status_message = "操作完成。"
		_status_error = false
	else:
		_status_message = message
		_status_error = message.begins_with("拒绝") or message.begins_with("当前") or message.begins_with("这里") or message.begins_with("质量")

func _save_blueprint() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute("user://tankcraft_blueprints")
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		_set_status("拒绝保存：无法创建蓝图目录。")
		return
	var file := FileAccess.open(USER_BLUEPRINT_PATH, FileAccess.WRITE)
	if file == null:
		_set_status("拒绝保存：无法打开蓝图文件。")
		return
	file.store_string(JSON.stringify(_editor_model().to_blueprint("自动保存"), "  "))
	file.close()
	_set_status("蓝图已保存到用户存档。")

func _load_blueprint() -> void:
	if not FileAccess.file_exists(USER_BLUEPRINT_PATH):
		_set_status("没有找到已保存蓝图。先按 Ctrl+S 保存。")
		return
	var file := FileAccess.open(USER_BLUEPRINT_PATH, FileAccess.READ)
	if file == null:
		_set_status("拒绝读取：无法打开蓝图文件。")
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary:
		_set_status("拒绝读取：蓝图 JSON 格式错误。")
		return
	_set_status(_editor_model().load_blueprint(data))

## ===== M6 对人机对战（design §3.1 VERSUS 流程）=====

## 进入对局：用当前的建造蓝图作为玩家坦克，敌人取对应难度档的预置蓝图。
## 建造页的蓝图非法（驾驶舱不唯一 / 无行进机构）时拒绝开局。
func _enter_match() -> void:
	if builder == null or definitions == null:
		return
	var report: Dictionary = builder.validation_report()
	if not bool(report["ok"]):
		_set_status("拒绝对战：%s" % String(report["errors"][0]))
		_status_error = true
		return
	match_session = MatchState.new()
	if not match_session.setup(definitions, DRIVE_ARENA_ID):
		_set_status("拒绝对战：对局初始化失败。")
		_status_error = true
		return
	var player_spawn: Dictionary = match_session.duel.spawn_point(DRIVE_ARENA_ID, 0)
	var enemy_spawn: Dictionary = match_session.duel.spawn_point(DRIVE_ARENA_ID, 1)
	if not match_session.duel.add_side(Duel.TAG_PLAYER, builder, player_spawn["pos"], player_spawn["rot"]):
		_set_status("拒绝对战：玩家坦克装载失败。")
		_status_error = true
		return
	match_enemy_builder = GridBuilder.new()
	match_enemy_builder.setup(definitions)
	match_enemy_builder.budget_enabled = false
	match_enemy_builder.credits_total = 1000000
	var tier: String = MATCH_DIFFICULTY[_match_difficulty]
	var blueprint := _bot_blueprint_for(tier)
	if blueprint.is_empty():
		_set_status("拒绝对战：找不到 %s 难度的 Bot 蓝图。" % tier)
		_status_error = true
		return
	var reason: String = match_enemy_builder.load_blueprint(blueprint)
	if not reason.is_empty():
		_set_status("拒绝对战：Bot 蓝图 %s" % reason)
		_status_error = true
		return
	if not match_session.duel.add_side(Duel.TAG_ENEMY, match_enemy_builder, enemy_spawn["pos"], enemy_spawn["rot"]):
		_set_status("拒绝对战：Bot 坦克装载失败。")
		_status_error = true
		return
	match_ai = BotAI.new()
	match_ai.setup(definitions, tier, 1)
	## 出生点与朝向微调 + 3 s 倒计时（design §3.1 DEPLOY_PHASE）。
	match_session.enter_deploy()
	match_session.step(MatchState.DEPLOY_COUNTDOWN_S + 0.01)
	_match_accumulator = 0.0
	_match_held.clear()
	_match_event = "对局开始：难度 %s" % MATCH_DIFFICULTY_LABEL[_match_difficulty]
	_match_fx.clear()
	_match_ready = true
	_set_screen(SCREEN_MATCH)
	_status_error = false
	_status_message = "对战：W/S 油门 · A/D 转向 · 空格 开火 · Esc 返回 · R 重开"
	queue_redraw()

func _exit_match() -> void:
	_match_held.clear()
	_match_ready = false
	_set_screen(SCREEN_MAIN)
	queue_redraw()

func _bot_blueprint_for(tier: String) -> Dictionary:
	var ids: Array = []
	for raw_id in definitions.registry.blueprints.keys():
		if String(raw_id).begins_with("bot_%s_" % tier):
			ids.append(String(raw_id))
	ids.sort()
	if ids.is_empty():
		return {}
	return definitions.get_blueprint(String(ids[0]))

func _handle_match_key(event: InputEventKey) -> void:
	var key: Key = event.keycode
	var pressed := event.pressed and not event.echo
	if key == KEY_ESCAPE:
		if pressed:
			_exit_match()
		return
	if key == KEY_R:
		if pressed:
			_enter_match()
		return
	## design §3.1：BATTLE_PHASE 中 Esc 打开暂停面板（这里用 P 打开 / 关闭，Esc 逐层返回）。
	if key == KEY_P:
		if pressed and match_session != null:
			match_session.toggle_pause()
			_match_event = "暂停" if match_session.paused else "继续"
			queue_redraw()
		return
	if key == KEY_SPACE:
		if pressed and match_session != null and not match_session.paused:
			var fired: int = match_session.duel.fire(Duel.TAG_PLAYER)
			if fired > 0:
				_match_event = "开火：%d 发离膛" % fired
			else:
				_match_event = "未装填或冷却中"
			queue_redraw()
		return
	if key == KEY_W or key == KEY_UP:
		_match_held["throttle_up"] = event.pressed
	elif key == KEY_S or key == KEY_DOWN:
		_match_held["throttle_down"] = event.pressed
	elif key == KEY_A or key == KEY_LEFT:
		_match_held["steer_left"] = event.pressed
	elif key == KEY_D or key == KEY_RIGHT:
		_match_held["steer_right"] = event.pressed
	else:
		return
	var up := 1.0 if bool(_match_held.get("throttle_up", false)) else 0.0
	var down := 1.0 if bool(_match_held.get("throttle_down", false)) else 0.0
	var left := 1.0 if bool(_match_held.get("steer_left", false)) else 0.0
	var right := 1.0 if bool(_match_held.get("steer_right", false)) else 0.0
	if match_session != null:
		match_session.duel.set_input(Duel.TAG_PLAYER, up - down, right - left)
	queue_redraw()

## 固定步长推进；与试驾一致，绝不缩放 dt（design §5.3）。
func _match_simulate(delta: float) -> void:
	if not _match_ready or match_session == null:
		_match_accumulator = 0.0
		return
	if match_session.is_over():
		_match_accumulator = 0.0
		return
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	_match_accumulator += delta
	var steps := 0
	while _match_accumulator >= step_time and steps < DRIVE_MAX_STEPS:
		_match_accumulator -= step_time
		steps += 1
		_match_step(step_time)

func _match_step(step_time: float) -> void:
	if match_session.paused:
		match_session.step(step_time)
		return
	if match_ai != null:
		var decision := match_ai.think(step_time, match_session.duel)
		match_session.duel.set_input(Duel.TAG_ENEMY, float(decision["throttle"]), float(decision["steer"]))
		if bool(decision["fire"]):
			match_session.duel.fire(Duel.TAG_ENEMY)
	match_session.step(step_time)
	for raw_event in match_session.duel.drain_events():
		var battle_event: Dictionary = raw_event
		var kind := String(battle_event.get("kind", ""))
		if kind == "impact" and String(battle_event.get("target", "")) == "tank":
			## v3.20 悬浮数字：对局页同样「造成与承受都显示」。
			## 坐标是竞技场世界坐标，`_draw_match_fx` 会按 `DRIVE_VIEW.position + pos * scale` 转换。
			var at := Vector2(battle_event.get("pos", Vector2.ZERO))
			var dealt := float(battle_event.get("damage", 0.0))
			var absorbed := float(battle_event.get("shield", 0.0))
			var victim := String(battle_event.get("tag", ""))
			if victim == Duel.TAG_PLAYER:
				if dealt > 0.0:
					_push_match_damage(at, dealt, Palette.ACCENT_RED, "received")
				if absorbed > 0.0:
					_push_match_damage(at, absorbed, Palette.ACCENT_LIME, "shield")
				_match_event = "本体被命中"
			else:
				if dealt > 0.0:
					_push_match_damage(at, dealt, Palette.ACCENT_CYAN, "dealt")
				if absorbed > 0.0:
					_push_match_damage(at, absorbed, Palette.ACCENT_LIME, "shield")
				_match_event = "命中 %s" % victim
		elif kind == "core_destroyed":
			_match_event = "驾驶舱被摧毁"
		elif kind == "detach":
			_match_event = "整块脱落：%d 格被撕下" % (battle_event.get("cells", []) as Array).size()
			_push_match_fx("detach", Vector2(battle_event.get("pos", Vector2.ZERO)), 130.0, Palette.ACCENT_MAGENTA, 1.0)
		elif kind == "destroyed":
			_match_event = "击毁 %s" % String(battle_event.get("module_id", ""))
		elif kind == "depot_explosion" or kind == "engine_explosion" or kind == "explosion":
			_match_event = "殉爆 / 爆炸"
	if match_session.is_over():
		_match_event = "对局结束：%s" % _match_outcome_text()
	_match_tick_fx(step_time)

func _match_outcome_text() -> String:
	if match_session == null:
		return ""
	if match_session.outcome == MatchState.OUTCOME_PLAYER or match_session.outcome == MatchState.OUTCOME_TIMEOUT_PLAYER:
		return "胜利"
	if match_session.outcome == MatchState.OUTCOME_ENEMY or match_session.outcome == MatchState.OUTCOME_TIMEOUT_ENEMY:
		return "失败"
	return "平局"

func _push_match_fx(kind: String, at: Vector2, radius: float, colour: Color, life: float) -> void:
	_match_fx.push(kind, at, radius, colour, life)

## 对局页的伤害悬浮数字（与生存页同一套语义，但坐标系统不同）。
## 同侧同帧限流与生存页一致，避免多炮齐射时数字糊满屏。
func _push_match_damage(at: Vector2, amount: float, colour: Color, mode: String) -> void:
	if amount <= 0.0:
		return
	var shown := int(roundf(amount))
	if shown <= 0:
		return
	var counting := 0
	for raw_entry in _match_fx.entries:
		if String((raw_entry as Dictionary).get("kind", "")) == "damage":
			counting += 1
	if counting >= DAMAGE_POPUP_PER_SIDE:
		return
	## 符号语义与生存页一致：造成 `+N`，承受/护盾 `-N`。
	var label := "+%d" % shown if mode == "dealt" else "-%d" % shown
	_match_fx.push("damage", at, 0.0, colour, DAMAGE_POPUP_LIFE, label)

## 对局页的伤害数字绘制：与生存页同样的上浮 + 淡出，但坐标转换走 `_match_fx` 的规矩。
func _draw_match_damage_popups(scale_factor: float) -> void:
	var stack := 0
	for raw_entry in _match_fx.entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) != "damage":
			continue
		var text := String(entry.get("text", ""))
		if text.is_empty():
			continue
		var life := float(entry["life"])
		if life <= 0.0:
			continue
		var progress := clampf(1.0 - float(entry["left"]) / life, 0.0, 1.0)
		var rise := DAMAGE_POPUP_RISE * sqrt(progress) * scale_factor
		var at: Vector2 = DRIVE_VIEW.position + Vector2(entry["pos"]) * scale_factor + Vector2(0.0, -rise - float(stack) * 14.0)
		var colour: Color = entry["colour"]
		var alpha := 1.0 if progress < 0.7 else clampf((1.0 - progress) / 0.3, 0.0, 1.0)
		var size := int(roundf(20.0 - 4.0 * progress))
		_draw_text(text, at + Vector2(1.0, 1.0), size, Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
		_draw_text(text, at, size, Color(colour, alpha), true)
		stack += 1

## 对局页动效倒计时：只在 `_match_step` 的固定步长里累减。
## 递减逻辑已收归 `FxLayer.step()`（v3.11）——三页共用一份，不会再出现「调错 tick 对象」。
func _match_tick_fx(step_time: float) -> void:
	_match_fx.step(step_time)

## ===== 试驾沙盒（M3）：建造结果 → 自建刚体 → 差速操控与开火 =====

func _enter_drive() -> void:
	if builder == null or definitions == null or tank == null:
		return
	if not tank.setup(definitions, builder):
		_set_status("拒绝试驾：当前蓝图没有可驱动的部件。")
		_status_error = true
		queue_redraw()
		return
	bank.setup(definitions, tank)
	field.setup(definitions)
	_drive_load_arena()
	tank.velocity = Vector2.ZERO
	tank.angular_velocity = 0.0
	## M4：炮管不再自动装满，改由管路网络逐发装填（design §7.6）。
	network = AmmoNetwork.new()
	network.setup(definitions)
	network.rebuild(builder)
	network.bind_bank(bank)
	## M5：战斗结算实例；护盾表按部件重建，改进装置的升级整台聚合（design §8.9）。
	damage = DamageSystem.new()
	damage.setup(definitions)
	damage.rebuild(tank, builder)
	damage.set_modifier_upgrades(tank)
	## M6：撞墙 / 障碍撞击伤害也走 damage_system，殉爆 / detach / 判负才不会被静默跳过。
	tank.damage_router = Callable(damage, "apply_part_damage")
	_drive_fx.clear()
	_drive_cannon_pulse.clear()
	_drive_cannon_loaded.clear()
	_drive_throttle = 0.0
	_drive_steer = 0.0
	_drive_held.clear()
	_drive_accumulator = 0.0
	_drive_track_phase = 0.0
	_drive_last_event = ""
	_drive_ready = true
	_set_screen(SCREEN_DRIVE)
	_status_error = false
	_status_message = "试驾：W/S 油门 · A/D 转向 · 空格 开火 · R 重开 · Esc 返回"
	if tank.parts_of_kind(TankBody.KIND_MOBILITY).size() < 2:
		_status_message += "　（行进机构少于 2 组，design §5.2 会持续偏转）"
	queue_redraw()

func _exit_drive() -> void:
	_drive_held.clear()
	_drive_throttle = 0.0
	_drive_steer = 0.0
	_drive_ready = false
	_set_screen(SCREEN_MAIN)
	queue_redraw()

## 竞技场尺寸、障碍与刷出点全部来自 data/arenas/*.json。
func _drive_load_arena() -> void:
	var arena: Dictionary = definitions.get_arena(DRIVE_ARENA_ID)
	if arena.is_empty():
		var ids: Array = definitions.registry.arenas.keys()
		ids.sort()
		if not ids.is_empty():
			arena = definitions.get_arena(String(ids[0]))
	var cell: float = tank.cell_size()
	var size: Array = arena.get("size", [128, 72])
	var cells := Vector2(float(size[0]), float(size[1]))
	_drive_arena = Rect2(Vector2.ZERO, cells * cell)
	_drive_obstacles.clear()
	for raw_obstacle in arena.get("obstacles", []):
		var obstacle: Dictionary = raw_obstacle
		if obstacle.has("rect"):
			var r: Array = obstacle["rect"]
			_drive_obstacles.append({
				"shape": "rect",
				"rect": Rect2(Vector2(float(r[0]), float(r[1])) * cell, Vector2(float(r[2]), float(r[3])) * cell),
			})
		elif obstacle.has("circle"):
			var c: Array = obstacle["circle"]
			_drive_obstacles.append({
				"shape": "circle",
				"center": Vector2(float(c[0]), float(c[1])) * cell,
				"radius": float(c[2]) * cell,
			})
	var spawns: Array = arena.get("spawns", [])
	var spawn: Dictionary = {}
	if not spawns.is_empty():
		spawn = spawns[0]
	var spawn_pos: Array = spawn.get("pos", [int(size[0]) / 2, int(size[1]) / 2])
	tank.position = Vector2(float(spawn_pos[0]), float(spawn_pos[1])) * cell
	tank.heading = deg_to_rad(float(spawn.get("rot", 0)))

func _handle_drive_key(event: InputEventKey) -> void:
	var key: Key = event.keycode
	var pressed := event.pressed and not event.echo
	if key == KEY_ESCAPE:
		if pressed:
			_exit_drive()
		return
	if key == KEY_SPACE:
		if pressed:
			_drive_fire()
		return
	if key == KEY_R:
		if pressed:
			_enter_drive()
		return
	if key == KEY_W or key == KEY_UP:
		_drive_held["throttle_up"] = event.pressed
	elif key == KEY_S or key == KEY_DOWN:
		_drive_held["throttle_down"] = event.pressed
	elif key == KEY_A or key == KEY_LEFT:
		_drive_held["steer_left"] = event.pressed
	elif key == KEY_D or key == KEY_RIGHT:
		_drive_held["steer_right"] = event.pressed
	else:
		return
	var up := 1.0 if bool(_drive_held.get("throttle_up", false)) else 0.0
	var down := 1.0 if bool(_drive_held.get("throttle_down", false)) else 0.0
	var left := 1.0 if bool(_drive_held.get("steer_left", false)) else 0.0
	var right := 1.0 if bool(_drive_held.get("steer_right", false)) else 0.0
	_drive_throttle = up - down
	_drive_steer = right - left
	queue_redraw()

func _drive_simulate(delta: float) -> void:
	if not _drive_ready or tank == null or tank.destroyed:
		_drive_accumulator = 0.0
		return
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	_drive_accumulator += delta
	var steps := 0
	while _drive_accumulator >= step_time and steps < DRIVE_MAX_STEPS:
		_drive_accumulator -= step_time
		steps += 1
		_drive_step(step_time)

func _drive_step(step_time: float) -> void:
	## 减速状态直接乘在输入上，不改 tank_body 内部（design §8.8）。
	var throttle := _drive_throttle
	var steer := _drive_steer
	if damage != null:
		throttle *= damage.thrust_scale()
		steer *= damage.thrust_scale()
	tank.step(step_time, throttle, steer)
	tank.apply_obstacles(_drive_obstacles)
	tank.apply_boundary(_drive_arena)
	bank.step(step_time)
	## 20 Hz 独立累加器推进网络；fill_cannons 只把已送达的弹药压入膛室。
	network.step(step_time)
	network.fill_cannons(bank)
	_drive_track_cannon_pulse(step_time)
	_drive_track_phase += tank.velocity.length() * step_time
	var targets: Array = []
	if damage != null:
		targets.append(damage.target_payload(tank, "player"))
	var frame_events: Array[Dictionary] = field.step(step_time, _drive_arena, _drive_obstacles, targets)
	for raw_event in frame_events:
		var event: Dictionary = raw_event
		_drive_record_event(event)
		_drive_resolve_impact(event)
	if damage != null:
		damage.step(step_time)
		_drive_consume_damage_events(damage.drain_events())
	_drive_tick_fx(step_time)
	if tank.destroyed:
		_drive_throttle = 0.0
		_drive_steer = 0.0
		_set_status("驾驶舱已被摧毁：按 R 重开试驾。")

## 每种口径齐射一次；装填由 M4 管路网络完成，开火后炮管进入 reload_s 冷却。
func _drive_fire() -> void:
	if not _drive_ready or tank.destroyed:
		return
	var calibers: Array[String] = []
	for cannon in bank.cannons:
		var caliber := String(cannon["caliber"])
		if not calibers.has(caliber):
			calibers.append(caliber)
	var fired := 0
	for caliber in calibers:
		for raw_shot in bank.fire(caliber):
			var shot: Dictionary = raw_shot
			fired += 1
			var upgrades: Array = damage.cannon_upgrades(tank) if damage != null else []
			field.spawn(Vector2(shot["origin"]), Vector2(shot["dir"]), String(shot["ammo_id"]), "player", upgrades)
			tank.apply_recoil(float(shot["recoil_px"]), Vector2(shot["dir"]), Vector2(shot["world_r"]))
	if fired == 0:
		_set_status("炮管还在装填，或当前蓝图没有炮管。")
		return
	_set_status("开火：%d 发离膛。" % fired)

func _drive_record_event(event: Dictionary) -> void:
	if String(event.get("kind", "")) == "impact":
		var target := String(event.get("target", ""))
		if target == "boundary":
			_drive_last_event = "命中边界"
		elif target == "tank":
			_drive_last_event = "命中本体装甲"
		else:
			_drive_last_event = "命中障碍"
	elif String(event.get("reason", "")) == "range":
		_drive_last_event = "超出射程"
	else:
		_drive_last_event = "弹药寿命结束"

## 弹丸命中本体的格 → 交给 damage_system 结算（design §8.2 层序、§8.3 公式）。
func _drive_resolve_impact(event: Dictionary) -> void:
	if damage == null or tank == null:
		return
	if String(event.get("kind", "")) != "impact":
		return
	if String(event.get("target", "")) != "tank":
		return
	var part_index := int(event.get("part_index", -1))
	if part_index < 0:
		return
	var upgrades: Array = event.get("upgrades", [])
	damage.apply_hit(
		tank,
		Vector2i(event.get("cell", Vector2i.ZERO)),
		part_index,
		String(event.get("ammo_id", "")),
		upgrades,
		Vector2(event.get("normal", Vector2.ZERO)),
		float(event.get("damage_scale", 1.0))
	)

## damage_system 的事件 → 绘制动效 + 状态文案；动效倒计时只在 _drive_step 里推进。
func _drive_consume_damage_events(list: Array) -> void:
	if tank == null:
		return
	for raw_entry in list:
		var event: Dictionary = raw_entry
		var kind := String(event.get("kind", ""))
		match kind:
			"shield_hit":
				_push_drive_fx("shield_hit", tank.world_position_of_cell(Vector2i(event["cell"])), 12.0, Palette.ACCENT_LIME, 0.25)
			"shield_broken":
				_push_drive_fx("shield_broken", tank.position, 96.0, Palette.ACCENT_RED, 0.7)
				_drive_last_event = "护盾被击穿，进入充能"
			"shield_restored":
				_push_drive_fx("shield_restored", tank.position, 96.0, Palette.ACCENT_LIME, 0.7)
				_drive_last_event = "护盾充能完成"
			"explosion", "depot_explosion", "engine_explosion":
				_push_drive_fx("explosion", tank.world_position_of_cell(Vector2i(event.get("cell", Vector2i.ZERO))), 72.0, Palette.ACCENT_AMBER, 0.6)
				if kind == "depot_explosion":
					_drive_last_event = "弹药库殉爆"
				elif kind == "engine_explosion":
					_drive_last_event = "引擎爆炸"
				else:
					_drive_last_event = "爆炸溅射"
			"destroyed":
				_drive_last_event = "击毁 %s" % String(event.get("module_id", ""))
			"core_destroyed":
				_push_drive_fx("core", tank.position, 150.0, Palette.ACCENT_RED, 1.2)
				_drive_last_event = "驾驶舱被摧毁"
			"detach":
				var lost: Array = event.get("cells", [])
				var shown := mini(lost.size(), 12)
				for index in range(shown):
					_push_drive_fx("debris", tank.world_position_of_cell(Vector2i(lost[index])), 9.0, Palette.ACCENT_RED, 0.6)
				_push_drive_fx("detach", tank.position, 130.0, Palette.ACCENT_MAGENTA, 1.0)
				_drive_last_event = "整块脱落：%d 格 / %d 部件被撕下" % [lost.size(), int(event.get("parts", 0))]
			"repaired":
				_drive_last_event = "维修 %s +%.1f" % [String(event.get("key", "")), float(event.get("amount", 0.0))]
			"slow_applied":
				_drive_last_event = "减速：推力 × %.2f" % float(event.get("factor", 1.0))
			"burn_applied":
				_drive_last_event = "灼烧：持续 3 秒"
			"split":
				_drive_spawn_split(event)

## design §8.6 up_split：命中后向两侧分裂出 count 枚 scale 倍伤害的子弹丸。
func _drive_spawn_split(event: Dictionary) -> void:
	if field == null or tank == null:
		return
	var count := int(event.get("count", 0))
	if count <= 0:
		return
	var scale := float(event.get("scale", 0.0))
	var base_scale := float(event.get("damage_scale", 1.0))
	var origin := Vector2(event.get("pos", Vector2.ZERO))
	var direction := Vector2(event.get("dir", Vector2.RIGHT))
	if direction == Vector2.ZERO:
		direction = Vector2.RIGHT
	direction = direction.normalized()
	var ammo_id := String(event.get("ammo_id", ""))
	var upgrades: Array = damage.cannon_upgrades(tank) if damage != null else []
	for index in range(count):
		var offset := (float(index) - float(count - 1) * 0.5) * 0.35
		var child_dir := direction.rotated(offset)
		field.spawn(origin + child_dir * 6.0, child_dir, ammo_id, "player", upgrades, base_scale * scale)
	_drive_last_event = "弹丸分裂 ×%d" % count

func _push_drive_fx(kind: String, at: Vector2, radius: float, colour: Color, life: float) -> void:
	_drive_fx.push(kind, at, radius, colour, life)

## 动效倒计时在固定步长里累减，保持确定性（绝不放 _process，绝不用 randf）。
func _drive_tick_fx(step_time: float) -> void:
	_drive_fx.step(step_time)

## 预热步数的统一入口：传了 `--steps=N` 就用 N，否则用该页原本的默认值。
## 用函数而不是直接读变量，是为了让三个页面的默认值各自写在调用处、一眼能看出原值。
func _warmup_steps(default_steps: int) -> int:
	if _capture_steps > 0:
		return _capture_steps
	return default_steps

## --screen=drive 截图钩子：先跑固定步数再开一炮，画面里同时有运动姿态和飞行中的炮弹。
func _drive_capture_warmup() -> void:
	if not _drive_ready:
		return
	_drive_throttle = 1.0
	_drive_steer = 0.0
	_drive_held["throttle_up"] = true
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	for index in range(_warmup_steps(90)):
		_drive_step(step_time)
	_drive_fire()
	for index in range(6):
		_drive_step(step_time)

func _draw() -> void:
	_draw_background()
	if _screen == SCREEN_MAIN:
		_draw_main_menu()
	elif _screen == SCREEN_SETTINGS:
		_draw_settings()
	elif _screen == SCREEN_DRIVE:
		_draw_drive()
	elif _screen == SCREEN_MATCH:
		_draw_match()
	elif _screen == SCREEN_SURVIVAL:
		_draw_survival()
	else:
		_draw_build()
	if _screen_opacity < 1.0:
		draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), Color(Palette.BG_BASE, 1.0 - _screen_opacity), true)

func _draw_background() -> void:
	var view := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view), Palette.BG_BASE, true)
	var minor := Color(Palette.GRID_LINE, 0.28)
	var major := Color(Palette.GRID_LINE, 0.62)
	var x := 0.0
	var column := 0
	while x <= view.x:
		draw_line(Vector2(x, 0), Vector2(x, view.y), major if column % 4 == 0 else minor, 1.0)
		x += float(Palette.CELL_SIZE)
		column += 1
	var y := 0.0
	var row := 0
	while y <= view.y:
		draw_line(Vector2(0, y), Vector2(view.x, y), major if row % 4 == 0 else minor, 1.0)
		y += float(Palette.CELL_SIZE)
		row += 1

func _draw_main_menu() -> void:
	_draw_text("TANKCRAFT", Vector2(160, 190), 54, Palette.TEXT_HI, true)
	_draw_text("BUILD / SURVIVE / RECONFIGURE", Vector2(164, 238), 16, Palette.TEXT_LO, true)
	_draw_text("正式实现 · M5 战斗结算 + M6 机器人 AI 与完整对局", Vector2(160, 300), 18, Palette.ACCENT_CYAN, false)
	var labels := ["生存", "试驾", "对人机对战", "开始建造", "设置", "退出"]
	for index in range(labels.size()):
		var rect := _menu_row_rect(index)
		_draw_focus_row(rect, index == _menu_index)
		_draw_text(labels[index], rect.position + Vector2(22, 33), 24, Palette.TEXT_HI if index == _menu_index else Palette.TEXT_LO, false)
	## 难度按钮放在菜单**下方**：菜单最后一行结束于 MENU_ROW_Y + 5×STEP + HEIGHT = 688，
	## 旧代码把难度写在 y=654 且提示写在 y=700，两者都压在「退出」行上（用户报告的菜单重叠）。
	var difficulty := _menu_difficulty_rect()
	var hovered := _hover_menu_difficulty
	if hovered:
		draw_rect(difficulty, Color(Palette.ACCENT_AMBER, 0.10), true)
		draw_rect(difficulty, Palette.ACCENT_AMBER, false, 2.0)
	else:
		draw_rect(difficulty, Color(Palette.ACCENT_AMBER, 0.32), false, 1.0)
	_draw_text("难度  %s" % MATCH_DIFFICULTY_LABEL[_match_difficulty], difficulty.position + Vector2(18, 30), 18, Palette.ACCENT_AMBER, false)
	_draw_text("点击 / A·D 切换", difficulty.position + Vector2(difficulty.size.x - 148.0, 30), 13, Palette.TEXT_LO, false)
	_draw_text("方向键 / W S 或鼠标悬停选择    Enter / 点击确认", Vector2(160, 800), 16, Palette.TEXT_LO, false)
	_draw_text("单一场景 · 正式 JSON 数据 · 三层网格", Vector2(160, 965), 16, Palette.TEXT_LO, true)
	_draw_preview_tank(Vector2(1330, 520), 3.0)
	_draw_text("LIVE BLUEPRINT PREVIEW", Vector2(1110, 800), 16, Palette.TEXT_LO, true)
	_draw_text("驾驶舱 / 甲板 / 行进机构", Vector2(1110, 832), 18, Palette.ACCENT_CYAN, false)

## 难度按钮：菜单列表下方，与最后一行不重叠。
func _menu_difficulty_rect() -> Rect2:
	return Rect2(MENU_ROW_X, MENU_ROW_Y + float(MENU_ITEM_COUNT) * MENU_ROW_STEP + 16.0, MENU_ROW_WIDTH, 44.0)

func _cycle_match_difficulty(step: int) -> void:
	_match_difficulty = posmod(_match_difficulty + step, MATCH_DIFFICULTY.size())
	queue_redraw()

func _draw_settings() -> void:
	_draw_text("设置", Vector2(220, 190), 48, Palette.TEXT_HI, false)
	_draw_text("SETTINGS", Vector2(224, 230), 16, Palette.TEXT_LO, true)
	var labels := ["辉光", "动效", "返回"]
	var values := ["开启" if _glow_enabled else "关闭", "开启" if _motion_enabled else "关闭", ""]
	for index in range(labels.size()):
		var rect := _settings_row_rect(index)
		_draw_focus_row(rect, index == _settings_index)
		_draw_text(labels[index], rect.position + Vector2(22, 32), 22, Palette.TEXT_HI if index == _settings_index else Palette.TEXT_LO, false)
		if not values[index].is_empty():
			_draw_text(values[index], rect.position + Vector2(480, 32), 18, Palette.ACCENT_CYAN, true)
	_draw_text("辉光与动效是独立的可读性开关。", Vector2(220, 620), 17, Palette.TEXT_LO, false)
	_draw_text("Esc 返回", Vector2(220, 950), 16, Palette.TEXT_LO, true)

func _draw_build() -> void:
	## 同一套编辑器服务两页：建造页与生存改装页。只换标题与目录标题，布局完全一致。
	if _in_modify_mode():
		_draw_text("RECONFIGURE / MODIFY", Vector2(72, 64), 18, Palette.ACCENT_LIME, true)
		_draw_text("改装坦克", Vector2(72, 105), 32, Palette.TEXT_HI, false)
		_draw_text("与建造页同一套编辑器 · 支出按建造净增计 · 用 credit 支付 · Esc 完成", Vector2(72, 136), 15, Palette.TEXT_LO, false)
		_draw_panel(PANEL_LEFT, "库存配件（本层）")
		_draw_panel(PANEL_RIGHT, "属性 / 校验")
	else:
		_draw_text("BUILD PHASE / M2", Vector2(72, 64), 18, Palette.ACCENT_CYAN, true)
		_draw_text("正式三层建造编辑器", Vector2(72, 105), 32, Palette.TEXT_HI, false)
		_draw_text("数据源：data/*.json · 操作原子可撤销 · Ctrl+S/O 蓝图存读", Vector2(72, 136), 15, Palette.TEXT_LO, false)
		_draw_panel(PANEL_LEFT, "模块目录")
		_draw_panel(PANEL_RIGHT, "属性 / 校验")
	_draw_grid()
	_draw_build_sidebar()
	_draw_build_inspector()
	_draw_build_footer()

func _draw_panel(rect: Rect2, title: String) -> void:
	draw_rect(rect, Color(Palette.BG_BASE, 0.86), true)
	draw_rect(rect, Color(Palette.WIRE, 0.55), false, 1.0)
	draw_line(rect.position + Vector2(0, 58), Vector2(rect.end.x, rect.position.y + 58), Color(Palette.WIRE, 0.35), 1.0)
	_draw_text(title, rect.position + Vector2(22, 37), 20, Palette.TEXT_HI, false)

func _draw_build_sidebar() -> void:
	var layer_names := ["1  平台层", "2  行进机构层", "3  功能模块层"]
	var layers := [LAYER_PLATFORM, LAYER_MOBILITY, LAYER_MODULE]
	for index in range(3):
		var rect := _build_layer_rect(index)
		var selected: bool = layers[index] == _build_layer
		var hovered: bool = index == _hover_layer_index
		if selected or hovered:
			draw_rect(rect, Color(Palette.ACCENT_CYAN, 0.08 if hovered and not selected else 0.12), true)
			draw_rect(rect, Color(Palette.ACCENT_CYAN, 0.55 if hovered and not selected else 1.0), false, 2.0)
		_draw_text(layer_names[index], rect.position + Vector2(14, 26), 16, Palette.ACCENT_CYAN if selected or hovered else Palette.TEXT_LO, true)
	var options: PackedStringArray = _option_ids()
	var visible_count := maxi(mini(options.size() - _option_scroll, BUILD_OPTION_VISIBLE), 0)
	for visible_index in range(visible_count):
		var option_index := _option_scroll + visible_index
		var option_rect := _build_option_rect(visible_index)
		var selected: bool = option_index == _selected_index
		var hovered: bool = option_index == _hover_option_index
		var definition: Dictionary = definitions.get_module(String(options[option_index]))
		if selected or hovered:
			var highlight: Color = Palette.ACCENT_AMBER if _build_layer != LAYER_PLATFORM else Palette.ACCENT_CYAN
			draw_rect(option_rect, Color(highlight, 0.08 if hovered and not selected else 0.11), true)
			draw_rect(option_rect, Color(highlight, 0.55 if hovered and not selected else 1.0), false, 2.0)
		var accent: Color = Palette.WIRE if _build_layer == LAYER_PLATFORM else (Palette.ACCENT_CYAN if _build_layer == LAYER_MOBILITY else Palette.ACCENT_AMBER)
		_draw_text(_module_glyph(String(definition.get("name", "?"))), option_rect.position + Vector2(12, 30), 20, accent, true)
		_draw_text(String(definition.get("name", options[option_index])), option_rect.position + Vector2(48, 21), 15, Palette.TEXT_HI if selected or hovered else Palette.TEXT_LO, false)
		_draw_text("%d cr  /  %.1f u  /  %d格" % [int(definition.get("price", 0)), float(definition.get("mass", 0.0)), int(definition.get("footprint", 1))], option_rect.position + Vector2(48, 39), 11, Palette.TEXT_LO, true)
	if options.size() > BUILD_OPTION_VISIBLE:
		_draw_text("滚轮浏览配件  %d–%d / %d" % [_option_scroll + 1, _option_scroll + visible_count, options.size()], Vector2(BUILD_LAYER_X, 735), 12, Palette.TEXT_LO, true)
	_draw_text("A / D 选择    Q / E 选件或调炮管 aim", Vector2(BUILD_LAYER_X, 765), 12, Palette.TEXT_LO, true)
	_draw_text("工具", Vector2(BUILD_LAYER_X, 793), 13, Palette.TEXT_LO, false)
	var tool_names := ["选择", "矩形", "直线"]
	var tool_ids := [TOOL_SELECT, TOOL_RECTANGLE, TOOL_LINE]
	for index in range(3):
		var rect := _build_tool_rect(index)
		var selected: bool = tool_ids[index] == _tool
		var hovered: bool = index == _hover_tool_index
		if selected or hovered:
			var color: Color = Palette.ACCENT_CYAN
			draw_rect(rect, Color(color, 0.08 if hovered and not selected else 0.12), true)
			draw_rect(rect, Color(color, 0.55 if hovered and not selected else 1.0), false, 2.0)
		_draw_text(tool_names[index], rect.position + Vector2(30, 25), 14, Palette.ACCENT_CYAN if selected or hovered else Palette.TEXT_LO, false)
func _draw_grid() -> void:
	var rect := _grid_rect()
	draw_rect(rect, Color(Palette.BG_BASE, 0.58), true)
	for y in range(_editor_model().grid_size.y + 1):
		var line_color := Color(Palette.WIRE, 0.35) if y % 4 == 0 else Color(Palette.GRID_LINE, 0.7)
		draw_line(rect.position + Vector2(0, float(y) * GRID_CELL), rect.position + Vector2(rect.size.x, float(y) * GRID_CELL), line_color, 1.0)
	for x in range(_editor_model().grid_size.x + 1):
		var line_color := Color(Palette.WIRE, 0.35) if x % 4 == 0 else Color(Palette.GRID_LINE, 0.7)
		draw_line(rect.position + Vector2(float(x) * GRID_CELL, 0), rect.position + Vector2(float(x) * GRID_CELL, rect.size.y), line_color, 1.0)
	## 三层分开画，**非选中层降低 alpha**（用户 2026-10-21：「选中一个层时，其他两层要变得透明」）。
	## 绘制顺序固定为 平台 → 行进 → 模块，与图层的上下关系一致；
	## 每层用自己的 alpha，所以选中平台层时行进与模块会退到背景里。
	var platform_alpha: float = 1.0 if _build_layer == LAYER_PLATFORM else LAYER_DIM_ALPHA
	var mobility_alpha: float = 1.0 if _build_layer == LAYER_MOBILITY else LAYER_DIM_ALPHA
	var module_alpha: float = 1.0 if _build_layer == LAYER_MODULE else LAYER_DIM_ALPHA
	for raw_cell in _editor_model().platform_cells.keys():
		var cell: Vector2i = raw_cell
		_draw_cell(cell, Palette.WIRE, "", false, platform_alpha)
	for shape in _editor_model().platform_shapes:
		var definition: Dictionary = definitions.get_module(String(shape["id"]))
		for cell in _editor_model().part_cells(shape):
			_draw_cell(cell, Palette.WIRE, _module_glyph(String(definition.get("name", "板"))), false, platform_alpha)
	for part in _editor_model().mobility_parts:
		var definition: Dictionary = definitions.get_module(String(part["id"]))
		for cell in _editor_model().part_cells(part):
			_draw_cell(cell, Palette.ACCENT_CYAN, _module_glyph(String(definition.get("name", "行"))), false, mobility_alpha)
	for part in _editor_model().module_parts:
		var definition: Dictionary = definitions.get_module(String(part["id"]))
		var is_core: bool = bool(definition.get("core", false))
		var color: Color = Palette.ACCENT_CYAN if is_core else Palette.ACCENT_AMBER
		for cell in _editor_model().part_cells(part):
			_draw_cell(cell, color, _module_glyph(String(definition.get("name", "模"))), is_core, module_alpha)
		if String(part["id"]).begins_with("cannon_"):
			_draw_aim_line(part, module_alpha)
	var preview_cells: Array[Vector2i] = _preview_cells()
	var preview_error := _placement_error()
	for cell in preview_cells:
		if _editor_model()._inside_grid(cell):
			var preview_color: Color = Palette.ACCENT_CYAN if _build_layer == LAYER_PLATFORM else Palette.ACCENT_AMBER
			var valid: bool = preview_error.is_empty()
			draw_rect(_cell_rect(cell), Color(preview_color, 0.16 if valid else 0.08), true)
			draw_rect(_cell_rect(cell), preview_color if valid else Palette.ACCENT_RED, false, 2.0)
	_draw_text("GRID %d×%d" % [_editor_model().grid_size.x, _editor_model().grid_size.y], rect.position + Vector2(0, -16), 13, Palette.TEXT_LO, true)
	_draw_text("cursor %02d:%02d" % [_cursor.x, _cursor.y], rect.position + Vector2(rect.size.x - 150, -16), 13, Palette.TEXT_LO, true)

func _preview_cells() -> Array[Vector2i]:
	var options: PackedStringArray = _option_ids()
	if options.is_empty():
		return []
	## 防御式钳制：`_draw_grid()` **每帧**都会调到这里，一旦越界就会每帧刷屏
	## `SCRIPT ERROR: Out of bounds get index`（用户报告的就是这个）。真正的收口在
	## `_ensure_option_visible()`，但绘制路径不该依赖「上游一定调过它」。
	var index := clampi(_selected_index, 0, options.size() - 1)
	var definition: Dictionary = definitions.get_module(String(options[index]))
	var part := {"id": String(options[index]), "start": _cursor, "rot": _rotation, "aim": _aim}
	if _build_layer == LAYER_PLATFORM and String(options[index]) == "platform_cell":
		return [_cursor]
	return _editor_model().part_cells(part)

func _draw_aim_line(part: Dictionary, alpha: float = 1.0) -> void:
	var cells: Array[Vector2i] = _editor_model().part_cells(part)
	if cells.is_empty():
		return
	var center := _cell_rect(cells[0]).get_center()
	var angle := deg_to_rad(float(part.get("aim", 0)))
	var direction := Vector2(cos(angle), sin(angle))
	draw_line(center, center + direction * 24.0, Color(Palette.ACCENT_LIME, alpha), 2.0)

## `alpha` 控制整格的可见度：非选中层传 `LAYER_DIM_ALPHA`，文字一起变淡。
func _draw_cell(cell: Vector2i, color: Color, label: String, core: bool, alpha: float = 1.0) -> void:
	var rect := _cell_rect(cell)
	draw_rect(rect, Color(color, 0.12 * alpha), true)
	draw_rect(rect.grow(-1.0), Color(color, 0.82 * alpha), false, 1.5)
	if core:
		draw_rect(rect.grow(-4.0), Color(Palette.ACCENT_RED, alpha), false, 1.0)
	if not label.is_empty():
		_draw_text(label, rect.position + Vector2(8, 23), 15, Color(color, alpha), true)

func _draw_build_inspector() -> void:
	var report: Dictionary = _editor_model().validation_report()
	var errors: Array = report["errors"]
	var warnings: Array = report["warnings"]
	var volume: Vector2i = _editor_model().volume_size()
	## 改装期没有“预算额度”概念（钱在 SurvivalRun 里），改显示真实 credit 与本次支出。
	if _in_modify_mode() and survival != null:
		_draw_text("金钱 / 本次支出", Vector2(1490, 280), 15, Palette.TEXT_LO, false)
		_draw_text("%d cr  /  %d cr" % [int(roundf(survival.credit)), int(roundf(survival.modification_cost()))], Vector2(1490, 312), 26, Palette.ACCENT_LIME, true)
		var spent_ratio := clampf(survival.modification_cost() / maxf(survival.credit + survival.modification_cost(), 1.0), 0.0, 1.0)
		draw_rect(Rect2(1490, 324, 320, 8), Color(Palette.WIRE, 0.3), true)
		draw_rect(Rect2(1490, 324, 320.0 * spent_ratio, 8), Palette.ACCENT_AMBER, true)
	else:
		_draw_text("信用点", Vector2(1490, 280), 15, Palette.TEXT_LO, false)
		_draw_text("%d / %d cr" % [int(_editor_model().credits_spent()), _editor_model().credits_total], Vector2(1490, 312), 26, Palette.ACCENT_CYAN if _editor_model().credits_remaining() >= 0.0 else Palette.ACCENT_RED, true)
		_draw_bar(Rect2(1490, 324, 320, 8), _editor_model().credits_spent(), float(_editor_model().credits_total), Palette.ACCENT_CYAN)
	_draw_text("质量上限 Lv.%d" % _editor_model().mass_cap_level, Vector2(1490, 370), 15, Palette.TEXT_LO, false)
	_draw_text("%.1f / %.1f u" % [_editor_model().build_mass(), _editor_model().mass_cap()], Vector2(1490, 402), 26, Palette.ACCENT_CYAN if _editor_model().build_mass() <= _editor_model().mass_cap() else Palette.ACCENT_RED, true)
	_draw_bar(Rect2(1490, 414, 320, 8), _editor_model().build_mass(), _editor_model().mass_cap(), Palette.ACCENT_LIME)
	_draw_text("体积", Vector2(1490, 458), 15, Palette.TEXT_LO, false)
	_draw_text("%d×%d / %d×%d" % [volume.x, volume.y, _editor_model().grid_size.x, _editor_model().grid_size.y], Vector2(1490, 490), 22, Palette.ACCENT_CYAN, true)
	_draw_text("驾驶舱", Vector2(1490, 540), 15, Palette.TEXT_LO, false)
	var cockpit_count := _editor_model().cockpit_cells().size()
	_draw_text("%d / 1" % cockpit_count, Vector2(1490, 572), 24, Palette.ACCENT_CYAN if cockpit_count == 1 else Palette.ACCENT_RED, true)
	_draw_text("行进机构", Vector2(1640, 540), 15, Palette.TEXT_LO, false)
	_draw_text("%d" % _editor_model().mobility_parts.size(), Vector2(1640, 572), 24, Palette.ACCENT_CYAN if not _editor_model().mobility_parts.is_empty() else Palette.ACCENT_RED, true)
	draw_line(Vector2(1490, 610), Vector2(1810, 610), Color(Palette.WIRE, 0.35), 1.0)
	_draw_text("实时校验", Vector2(1490, 648), 18, Palette.TEXT_HI, false)
	if errors.is_empty():
		_draw_text("结构合法，可以部署。", Vector2(1490, 688), 16, Palette.ACCENT_CYAN, false)
	else:
		var error_y := 688.0
		for message in errors.slice(0, 4):
			_draw_text("× " + String(message), Vector2(1490, error_y), 13, Palette.ACCENT_RED, false)
			error_y += 30.0
	var warning_y := 810.0
	for warning in warnings.slice(0, 2):
		_draw_text("! " + String(warning), Vector2(1490, warning_y), 12, Palette.ACCENT_AMBER, false)
		warning_y += 22.0
	_draw_text("当前选择", Vector2(1490, 850), 14, Palette.TEXT_LO, false)
	var selected: Dictionary = _selected_definition()
	_draw_text(String(selected.get("name", "无")), Vector2(1490, 876), 16, Palette.ACCENT_AMBER if _build_layer != LAYER_PLATFORM else Palette.WIRE, false)

func _draw_build_footer() -> void:
	var footer_y := 950.0
	var labels := ["1 平台", "2 行进", "3 模块"]
	var layers := [LAYER_PLATFORM, LAYER_MOBILITY, LAYER_MODULE]
	for index in range(3):
		var rect := _build_footer_layer_rect(index)
		var selected: bool = layers[index] == _build_layer
		var hovered: bool = index == _hover_layer_index
		if selected or hovered:
			draw_rect(rect, Color(Palette.ACCENT_CYAN, 0.08 if hovered and not selected else 0.12), true)
			draw_rect(rect, Palette.ACCENT_CYAN, false, 2.0)
		_draw_text(labels[index], rect.position + Vector2(18, 25), 14, Palette.ACCENT_CYAN if selected or hovered else Palette.TEXT_LO, true)
	## 底部提示按页面切换：改装页不提供蓝图存读与质量上限购买（后者在 budget_enabled=false 时免费）。
	if _in_modify_mode():
		_draw_text("方向键 / 鼠标定位   Enter/左键贴装   R 旋转   X/右键拆解（退回库存）   Esc 完成", Vector2(620, 1018), 14, Palette.TEXT_LO, false)
	else:
		_draw_text("方向键 / 鼠标定位   Enter/左键放置   R 旋转   X/右键拆除   M 升级   Esc 返回", Vector2(620, 1018), 14, Palette.TEXT_LO, false)
	var message_color: Color = Palette.ACCENT_RED if _status_error else Palette.TEXT_HI
	_draw_text(_status_message, Vector2(620, 1048), 15, message_color, false)

func _draw_focus_row(rect: Rect2, focused: bool) -> void:
	var hovered := false
	if _screen == SCREEN_MAIN:
		hovered = _hover_menu_index >= 0 and rect == _menu_row_rect(_hover_menu_index)
	elif _screen == SCREEN_SETTINGS:
		hovered = _hover_settings_index >= 0 and rect == _settings_row_rect(_hover_settings_index)
	if focused or hovered:
		var row_offset := _focus_rail_y - rect.position.y
		var rail_height: float = rect.size.y + 8.0
		draw_rect(Rect2(rect.position + Vector2(-14.0, row_offset + 4.0), Vector2(4.0, rail_height)), Palette.ACCENT_CYAN, true)
		draw_rect(rect, Color(Palette.ACCENT_CYAN, 0.07 if not hovered else 0.11), true)
		draw_rect(rect, Color(Palette.ACCENT_CYAN, 0.55 if not hovered else 1.0), false, 2.0)

func _draw_bar(rect: Rect2, value: float, maximum: float, color: Color) -> void:
	draw_rect(rect, Color(Palette.WIRE, 0.22), true)
	if maximum > 0.0:
		var ratio: float = clampf(value / maximum, 0.0, 1.0)
		draw_rect(Rect2(rect.position, Vector2(rect.size.x * ratio, rect.size.y)), color, true)

func _draw_preview_tank(center: Vector2, scale: float) -> void:
	var width := 220.0 * scale
	var height := 130.0 * scale
	var plate := Rect2(center - Vector2(width, height) * 0.5, Vector2(width, height))
	draw_rect(plate, Color(Palette.WIRE, 0.08), true)
	draw_rect(plate, Palette.WIRE, false, 2.0)
	for offset in [-1.0, 1.0]:
		var track := Rect2(Vector2(plate.position.x, center.y + offset * height * 0.42 - 14.0), Vector2(width, 28.0))
		draw_rect(track, Color(Palette.WIRE, 0.08), true)
		draw_rect(track, Color(Palette.WIRE, 0.7), false, 1.0)
	var cockpit := Rect2(center - Vector2(24, 24), Vector2(48, 48))
	draw_rect(cockpit, Color(Palette.ACCENT_CYAN, 0.12), true)
	draw_rect(cockpit, Palette.ACCENT_CYAN, false, 2.0)
	draw_line(cockpit.get_center() - Vector2(12, 0), cockpit.get_center() + Vector2(12, 0), Palette.ACCENT_CYAN, 2.0)
	draw_line(cockpit.get_center() - Vector2(0, 12), cockpit.get_center() + Vector2(0, 12), Palette.ACCENT_CYAN, 2.0)
	var engine := Rect2(center - Vector2(100, 30), Vector2(42, 42))
	draw_rect(engine, Color(Palette.ACCENT_AMBER, 0.15), true)
	draw_rect(engine, Palette.ACCENT_AMBER, false, 2.0)
	var cannon_start := center + Vector2(24, 0)
	var cannon_end := cannon_start + Vector2(170, 0)
	draw_line(cannon_start, cannon_end, Palette.ACCENT_AMBER, 5.0)
	draw_circle(cannon_end, 5.0, Palette.ACCENT_AMBER)
	var radius := 210.0 * scale
	if _motion_enabled:
		radius += sin(_time * 1.5) * 4.0
	draw_arc(center, radius, 0, TAU, 64, Color(Palette.ACCENT_CYAN, 0.35), 2.0)

## ===== M6 对局绘制（design §3.1 BATTLE_PHASE）=====

## 两侧坦克、弹道、护盾覆盖与 HUD；全部复用试驾页的坐标与配色约定。
## 注意：不能复用 _drive_scale() —— 它读的是试驾页的 _drive_arena，对局页下为空会退回 1.0，导致地图 1:1 溢出。
func _match_scale() -> float:
	if match_session == null or match_session.duel.arena.size.x <= 0.0:
		return 1.0
	return DRIVE_VIEW.size.x / match_session.duel.arena.size.x

func _match_to_screen(world: Vector2, scale_factor: float) -> Vector2:
	return DRIVE_VIEW.position + (world - match_session.duel.arena.position) * scale_factor

func _draw_match() -> void:
	if match_session == null:
		return
	var duel: Duel = match_session.duel
	var scale_factor := _match_scale()
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.94), true)
	draw_rect(Rect2(DRIVE_VIEW.position, duel.arena.size * scale_factor), Palette.ACCENT_CYAN, false, 2.0)
	for raw_obstacle in duel.obstacles:
		var obstacle: Dictionary = raw_obstacle
		if String(obstacle["shape"]) == "rect":
			var rect: Rect2 = obstacle["rect"]
			var screen_rect := Rect2(DRIVE_VIEW.position + rect.position * scale_factor, rect.size * scale_factor)
			draw_rect(screen_rect, Color(Palette.ACCENT_RED, 0.16), true)
			draw_rect(screen_rect, Palette.ACCENT_RED, false, 1.5)
		else:
			var obstacle_centre: Vector2 = obstacle["center"]
			var centre: Vector2 = DRIVE_VIEW.position + obstacle_centre * scale_factor
			var radius := float(obstacle["radius"]) * scale_factor
			draw_circle(centre, radius, Color(Palette.ACCENT_RED, 0.16))
			draw_arc(centre, radius, 0.0, TAU, 48, Palette.ACCENT_RED, 1.5)
	for tag in [Duel.TAG_ENEMY, Duel.TAG_PLAYER]:
		_draw_match_hull(String(tag), scale_factor)
	for shot in duel.field.shots:
		var head: Vector2 = DRIVE_VIEW.position + Vector2(shot["pos"]) * scale_factor
		var tail: Vector2 = DRIVE_VIEW.position + Vector2(shot["prev"]) * scale_factor
		var colour := Palette.ACCENT_AMBER if String(shot["shooter"]) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
		draw_line(tail, head, Color(colour, 0.7), 1.5)
		draw_circle(head, maxf(float(shot["radius"]) * scale_factor, 2.0), colour)
	_draw_match_fx(scale_factor)
	_draw_match_hud()

## 坦克绘制的唯一实现：试驾 / 对局 / 生存三页原本各有一份逐行同构的副本，
## 差异只在「每部件颜色」「填充透明度」「部件格偏移」「额外的格装饰」。
## 抽成回调后，生存页那套按血量分档上色可以一处改动全页生效——旧版正是因为三份副本
## 各自演化，对局页始终没拿到血量上色，玩家才看不出敌人被打残了。
##
## `colour_fn(part) -> Color`    每部件主色（必需）
## `alpha_fn(part) -> float`     填充透明度（缺省 0.22，与试驾/对局页旧行为一致）
## `offset_fn(part) -> Vector2`  该部件所有格的额外偏移（缺省零）
## `cell_hook(box, colour, part)` 每格额外装饰，例如履带纹（缺省无）
func _draw_hull_shared(hull: TankBody, origin: Vector2, heading: float, scale_factor: float, colour_fn: Callable, alpha_fn: Callable = Callable(), offset_fn: Callable = Callable(), cell_hook: Callable = Callable()) -> void:
	if hull == null or hull.parts.is_empty():
		return
	var cell: float = hull.cell_size()
	draw_set_transform(origin, heading, Vector2(scale_factor, scale_factor))
	for part in hull.parts:
		var colour: Color = colour_fn.call(part)
		var alpha := 0.22
		if alpha_fn.is_valid():
			alpha = float(alpha_fn.call(part))
		var offset := Vector2.ZERO
		if offset_fn.is_valid():
			offset = Vector2(offset_fn.call(part))
		for raw_cell in part["cells"]:
			var cell_value: Vector2i = raw_cell
			var centre: Vector2 = (Vector2(cell_value) + Vector2(0.5, 0.5)) * cell - hull.centroid_local + offset
			var box := Rect2(centre - Vector2(cell, cell) * 0.5, Vector2(cell, cell))
			draw_rect(box, Color(colour, alpha), true)
			draw_rect(box, colour, false, maxf(1.0 / scale_factor, 1.0))
			if cell_hook.is_valid():
				cell_hook.call(box, colour, part)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## 对局页每部件颜色：驾驶舱恒为琥珀，其余按队伍色。`bind(base)` 后签名为 (part, base)。
func _match_part_colour(part: Dictionary, base: Color) -> Color:
	if bool(definitions.get_module(String(part["module_id"])).get("core", false)):
		return Palette.ACCENT_AMBER
	return base

func _draw_match_hull(tag: String, scale_factor: float) -> void:
	var duel: Duel = match_session.duel
	var hull: TankBody = duel.tank_of(tag)
	if hull == null or hull.parts.is_empty():
		return
	var base := Palette.ACCENT_CYAN if tag == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
	var origin: Vector2 = DRIVE_VIEW.position + (hull.position - duel.arena.position) * scale_factor
	_draw_hull_shared(hull, origin, hull.heading, scale_factor, _match_part_colour.bind(base))

func _draw_match_fx(scale_factor: float) -> void:
	for raw_entry in _match_fx.entries:
		var entry: Dictionary = raw_entry
		## 伤害数字由 `_draw_match_damage_popups()` 单独画，这里跳过，否则会多画一个小圆圈。
		if String(entry.get("kind", "")) == "damage":
			continue
		var at: Vector2 = DRIVE_VIEW.position + Vector2(entry["pos"]) * scale_factor
		var radius := float(entry["radius"]) * scale_factor
		var colour: Color = entry["colour"]
		var life := maxf(float(entry["life"]), 0.001)
		var ratio := clampf(float(entry["left"]) / life, 0.0, 1.0)
		var grow := 1.0 - ratio
		draw_arc(at, radius * (0.2 + 0.8 * grow), 0.0, TAU, 24, Color(colour, 0.8 * ratio), 2.0)
	_draw_match_damage_popups(scale_factor)

func _draw_match_hud() -> void:
	var duel: Duel = match_session.duel
	var left := DRIVE_HUD_LEFT.position.x
	var right := DRIVE_HUD_RIGHT.position.x
	_draw_text("对战 / %s" % MATCH_DIFFICULTY_LABEL[_match_difficulty], Vector2(left, 120), 16, Palette.ACCENT_CYAN, true)
	_draw_text("MATCH", Vector2(left, 152), 32, Palette.TEXT_HI, false)
	_draw_text("对局计时", Vector2(left, 220), 14, Palette.TEXT_LO, false)
	_draw_text("%05.1f s" % maxf(match_session.battle_time_left, 0.0), Vector2(left, 252), 26, Palette.ACCENT_AMBER, true)
	var player_dealt := float(duel.damage_dealt.get(Duel.TAG_PLAYER, 0.0))
	var enemy_dealt := float(duel.damage_dealt.get(Duel.TAG_ENEMY, 0.0))
	_draw_text("我方", Vector2(left, 320), 14, Palette.ACCENT_CYAN, false)
	_draw_text("已造成 %.1f" % player_dealt, Vector2(left, 348), 18, Palette.TEXT_HI, false)
	var player_parts := duel.structure_summary(Duel.TAG_PLAYER)
	_draw_text("部件 %d / 平台 %d" % [int(player_parts["parts"]), int(player_parts["cells"])], Vector2(left, 376), 14, Palette.TEXT_LO, false)
	_draw_text("敌方", Vector2(left, 424), 14, Palette.ACCENT_MAGENTA, false)
	_draw_text("已造成 %.1f" % enemy_dealt, Vector2(left, 452), 18, Palette.TEXT_HI, false)
	var enemy_parts := duel.structure_summary(Duel.TAG_ENEMY)
	_draw_text("部件 %d / 平台 %d" % [int(enemy_parts["parts"]), int(enemy_parts["cells"])], Vector2(left, 480), 14, Palette.TEXT_LO, false)
	_draw_text("最近事件", Vector2(left, 540), 14, Palette.TEXT_LO, false)
	_draw_text(_match_event, Vector2(left, 576), 15, Palette.ACCENT_LIME, false)
	if match_session.paused:
		_draw_text("暂停中", Vector2(right, 220), 24, Palette.ACCENT_RED, false)
	_draw_text("W / S    油门", Vector2(right, 260), 16, Palette.TEXT_HI, false)
	_draw_text("A / D    转向", Vector2(right, 290), 16, Palette.TEXT_HI, false)
	_draw_text("空格     开火", Vector2(right, 320), 16, Palette.TEXT_HI, false)
	_draw_text("P        暂停", Vector2(right, 350), 16, Palette.TEXT_HI, false)
	_draw_text("R        重开对局", Vector2(right, 380), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, 410), 16, Palette.TEXT_HI, false)
	var player_bank = duel.bank_of(Duel.TAG_PLAYER)
	if player_bank != null and not player_bank.cannons.is_empty():
		var cannon: Dictionary = player_bank.cannons[0]
		var reload := maxf(float(cannon["reload_s"]), 0.01)
		var progress := clampf(1.0 - float(cannon["reload_remaining"]) / reload, 0.0, 1.0)
		_draw_text("装填", Vector2(right, 470), 14, Palette.TEXT_LO, false)
		draw_rect(Rect2(right, 480.0, 272.0, 6.0), Color(Palette.WIRE, 0.35), true)
		draw_rect(Rect2(right, 480.0, 272.0 * progress, 6.0), Palette.ACCENT_AMBER if bool(cannon["loaded"]) else Palette.WIRE, true)
	if match_session.is_over():
		draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.92), true)
		draw_rect(DRIVE_STATUS, Palette.ACCENT_CYAN, false, 2.0)
		_draw_text("对局结束：%s（R 重开 / Esc 返回）" % _match_outcome_text(), Vector2(DRIVE_STATUS.position.x + 20.0, DRIVE_STATUS.position.y + 44.0), 20, Palette.TEXT_HI, false)
	else:
		draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.86), true)
		draw_rect(DRIVE_STATUS, Color(Palette.WIRE, 0.55), false, 1.0)
		_draw_text(_status_message, Vector2(DRIVE_STATUS.position.x + 20.0, DRIVE_STATUS.position.y + 42.0), 16, Palette.TEXT_HI, false)

## ===== 试驾沙盒绘制（M3）：世界缩放、刚体姿态、弹道与 HUD =====
func _drive_scale() -> float:
	if _drive_arena.size.x <= 0.0:
		return 1.0
	return DRIVE_VIEW.size.x / _drive_arena.size.x

func _drive_to_screen(world: Vector2) -> Vector2:
	return DRIVE_VIEW.position + (world - _drive_arena.position) * _drive_scale()

func _draw_drive() -> void:
	_draw_drive_field()
	_draw_drive_hull()
	_draw_drive_conveyors()
	_draw_drive_shots()
	_draw_drive_shields()
	_draw_drive_fx()
	_draw_drive_hud()

func _draw_drive_field() -> void:
	var scale_factor := _drive_scale()
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.94), true)
	var cell_step: float = tank.cell_size() * scale_factor * 4.0
	var x := DRIVE_VIEW.position.x
	var column := 0
	while x <= DRIVE_VIEW.end.x:
		draw_line(Vector2(x, DRIVE_VIEW.position.y), Vector2(x, DRIVE_VIEW.end.y), Color(Palette.GRID_LINE, 0.55 if column % 4 == 0 else 0.26), 1.0)
		x += cell_step
		column += 1
	var y := DRIVE_VIEW.position.y
	var row := 0
	while y <= DRIVE_VIEW.end.y:
		draw_line(Vector2(DRIVE_VIEW.position.x, y), Vector2(DRIVE_VIEW.end.x, y), Color(Palette.GRID_LINE, 0.55 if row % 4 == 0 else 0.26), 1.0)
		y += cell_step
		row += 1
	draw_rect(Rect2(_drive_to_screen(_drive_arena.position), _drive_arena.size * scale_factor), Palette.ACCENT_CYAN, false, 2.0)
	for raw_obstacle in _drive_obstacles:
		var obstacle: Dictionary = raw_obstacle
		if String(obstacle["shape"]) == "rect":
			var rect: Rect2 = obstacle["rect"]
			var screen_rect := Rect2(_drive_to_screen(rect.position), rect.size * scale_factor)
			draw_rect(screen_rect, Color(Palette.ACCENT_RED, 0.16), true)
			draw_rect(screen_rect, Palette.ACCENT_RED, false, 1.5)
		else:
			var centre := _drive_to_screen(Vector2(obstacle["center"]))
			var radius := float(obstacle["radius"]) * scale_factor
			draw_circle(centre, radius, Color(Palette.ACCENT_RED, 0.16))
			draw_arc(centre, radius, 0.0, TAU, 48, Palette.ACCENT_RED, 1.5)

## 整机绕质心旋转；design §5.5 的转向倾斜与加速滞后均为纯视觉量。
func _draw_drive_hull() -> void:
	if tank == null or tank.parts.is_empty():
		return
	var scale_factor := _drive_scale()
	var tilt := 0.0
	if _motion_enabled:
		tilt = clampf(tank.angular_velocity * deg_to_rad(0.7), -deg_to_rad(2.0), deg_to_rad(2.0))
	_draw_hull_shared(tank, _drive_to_screen(tank.position), tank.heading + tilt, scale_factor, _drive_part_color, Callable(), _drive_part_offset, _drive_cell_hook)

## 加速时行进机构整体向后拖一点，纯视觉量（design §5.5）。
func _drive_part_offset(part: Dictionary) -> Vector2:
	if String(part["kind"]) != TankBody.KIND_MOBILITY:
		return Vector2.ZERO
	if not _motion_enabled or is_zero_approx(_drive_throttle):
		return Vector2.ZERO
	return Vector2(-0.5 * signf(_drive_throttle), 0.0)

## 只在行进机构格上叠履带纹。
func _drive_cell_hook(box: Rect2, colour: Color, part: Dictionary) -> void:
	if String(part["kind"]) == TankBody.KIND_MOBILITY:
		_draw_drive_track_marks(box, colour)

func _draw_drive_track_marks(box: Rect2, colour: Color) -> void:
	var phase := fposmod(_drive_track_phase, 6.0)
	var mark := Color(colour, 0.8)
	var y := box.position.y + 3.0
	while y < box.end.y:
		var x := box.position.x + phase
		while x < box.end.x:
			draw_line(Vector2(x, y), Vector2(minf(x + 3.0, box.end.x), y), mark, 1.0)
			x += 6.0
		y += 5.0

func _draw_drive_shots() -> void:
	if field == null:
		return
	var scale_factor := _drive_scale()
	for shot in field.shots:
		var head := _drive_to_screen(Vector2(shot["pos"]))
		var tail := _drive_to_screen(Vector2(shot["prev"]))
		draw_line(tail, head, Color(Palette.ACCENT_AMBER, 0.7), 1.5)
		draw_circle(head, maxf(float(shot["radius"]) * scale_factor, 2.0), Palette.ACCENT_AMBER)

## M5 护盾可视化：ACTIVE 画覆盖格轮廓，BROKEN 画充能脉冲（相位取自 _time，不用 randf）。
func _draw_drive_shields() -> void:
	if damage == null or tank == null:
		return
	var scale_factor := _drive_scale()
	var cell: float = tank.cell_size()
	var pulse := 0.5 + 0.5 * sin(_time * 6.0)
	for raw_shield in damage.shields():
		var shield: Dictionary = raw_shield
		var active := String(shield["state"]) == DamageSystem.SHIELD_ACTIVE
		var colour := Palette.ACCENT_LIME if active else Palette.ACCENT_RED
		var alpha := 0.55 if active else 0.25 + 0.45 * pulse
		for raw_cell in (shield["cells"] as Array):
			var box := _drive_local_box(Vector2i(raw_cell), cell)
			draw_rect(box, Color(colour, alpha * 0.18), true)
			draw_rect(box, Color(colour, alpha), false, maxf(1.0 / scale_factor, 1.0))
		if active:
			continue
		## 充能进度条画在护盾首格下方。
		var anchor := _drive_local_box(Vector2i((shield["cells"] as Array)[0]), cell)
		var total := maxf(float(shield["recharge_s"]), 0.01)
		var progress := clampf(1.0 - float(shield["charge"]) / total, 0.0, 1.0)
		var bar := Rect2(anchor.position + Vector2(0.0, cell + 2.0), Vector2(cell, 3.0))
		draw_rect(bar, Color(Palette.BG_BASE, 0.8), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * progress, bar.size.y)), _drive_lime_pulse(pulse), true)

func _drive_lime_pulse(pulse: float) -> Color:
	return Color(Palette.ACCENT_LIME, 0.45 + 0.55 * pulse)

## M5 战斗动效：残骸、爆炸环、护盾、脱落撕裂与驾驶舱被毁；全部由 left/life 倒数驱动。
func _draw_drive_fx() -> void:
	if _drive_fx.is_empty():
		return
	var scale_factor := _drive_scale()
	for raw_entry in _drive_fx.entries:
		var entry: Dictionary = raw_entry
		var kind := String(entry["kind"])
		var at := _drive_to_screen(Vector2(entry["pos"]))
		var radius := float(entry["radius"]) * scale_factor
		var colour: Color = entry["colour"]
		var life := maxf(float(entry["life"]), 0.001)
		var ratio := clampf(float(entry["left"]) / life, 0.0, 1.0)
		var grow := 1.0 - ratio
		if kind == "debris":
			draw_circle(at, maxf(radius * ratio, 1.0), Color(colour, 0.7 * ratio))
			continue
		if kind == "shield_hit":
			draw_arc(at, maxf(radius, 2.0), 0.0, TAU, 12, Color(colour, ratio), 2.0)
			continue
		if kind == "detach" or kind == "core":
			draw_arc(at, radius * (0.35 + 0.65 * grow), 0.0, TAU, 32, Color(colour, 0.85 * ratio), 3.0)
			draw_arc(at, radius * (0.15 + 0.4 * grow), 0.0, TAU, 24, Color(colour, 0.55 * ratio), 2.0)
			continue
		draw_arc(at, radius * (0.2 + 0.8 * grow), 0.0, TAU, 24, Color(colour, 0.8 * ratio), 2.0)
		draw_circle(at, maxf(radius * 0.18 * ratio, 1.0), Color(colour, 0.5 * ratio))

## M4 管路可视化：底槽、在途炮弹、拥塞红色闪烁（design §7.4）。
## 闪烁相位取自 _time，不用 randf，保持确定性。
func _draw_drive_conveyors() -> void:
	if network == null or tank == null or tank.parts.is_empty():
		return
	var scale_factor := _drive_scale()
	var cell: float = tank.cell_size()
	var congested: Dictionary = {}
	for entry in network.congestion():
		congested[int(entry["part"])] = true
	var pulse := 0.5 + 0.5 * sin(_time * 9.0)
	draw_set_transform(_drive_to_screen(tank.position), tank.heading, Vector2(scale_factor, scale_factor))
	for part in network.parts:
		if String(part["role"]) != AmmoNetwork.ROLE_CONVEYOR:
			continue
		var hot := congested.has(int(part["index"]))
		var colour := Palette.ACCENT_RED if hot else Palette.ACCENT_CYAN
		var alpha := 0.35 + 0.6 * pulse if hot else 0.55
		for raw_cell in (part["cells"] as Array):
			var box := _drive_local_box(Vector2i(raw_cell), cell)
			draw_rect(box, Color(colour, alpha * 0.3), true)
			draw_rect(box, Color(colour, alpha), false, maxf(1.0 / scale_factor, 1.0))
	for round_state in network.strand_positions():
		var cells: Array = round_state["cells"]
		if cells.is_empty():
			continue
		var from_cell := Vector2(Vector2i(cells[0])) + Vector2(0.5, 0.5)
		var to_cell := Vector2(Vector2i(cells[cells.size() - 1])) + Vector2(0.5, 0.5)
		var progress := clampf(float(round_state["progress"]), 0.0, 1.0)
		var point := from_cell.lerp(to_cell, progress)
		if not bool(round_state["forward"]):
			point = to_cell.lerp(from_cell, progress)
		var centre := point * cell - tank.centroid_local
		var colour := Palette.ACCENT_AMBER if bool(round_state["forward"]) else Palette.ACCENT_MAGENTA
		if bool(round_state["congested"]):
			colour = Palette.ACCENT_RED
		draw_circle(centre, cell * 0.22, colour)
		draw_arc(centre, cell * 0.34, 0.0, TAU, 16, Color(colour, 0.6), maxf(1.0 / scale_factor, 1.0))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for entry in network.route_status():
		if bool(entry["reachable"]):
			continue
		var source_cell := Vector2i((network.parts[int(entry["part"])]["cells"] as Array)[0])
		_draw_drive_broken_link(_drive_local_to_screen(Vector2(source_cell) + Vector2(0.5, 0.5), cell))

func _drive_local_box(cell_value: Vector2i, cell: float) -> Rect2:
	var centre := (Vector2(cell_value) + Vector2(0.5, 0.5)) * cell - tank.centroid_local
	return Rect2(centre - Vector2(cell, cell) * 0.5, Vector2(cell, cell))

## 部件局部格中心 → 屏幕坐标（绕质心旋转后投影）。
func _drive_local_to_screen(local_cell: Vector2, cell: float) -> Vector2:
	var local := local_cell * cell - tank.centroid_local
	return _drive_to_screen(tank.position + local.rotated(tank.heading))

## 断链图标：红圈加斜杠，标在不可达的源模块上（design §7.5）。
func _draw_drive_broken_link(screen: Vector2) -> void:
	draw_arc(screen, 14.0, 0.0, TAU, 20, Palette.ACCENT_RED, 2.0)
	draw_line(screen + Vector2(-9.0, -9.0), screen + Vector2(9.0, 9.0), Palette.ACCENT_RED, 2.0)

func _drive_part_color(part: Dictionary) -> Color:
	var colour := Palette.WIRE
	var kind := String(part["kind"])
	if kind == TankBody.KIND_MOBILITY:
		colour = Palette.ACCENT_LIME
	elif kind == TankBody.KIND_MODULE:
		var definition: Dictionary = definitions.get_module(String(part["module_id"]))
		if bool(definition.get("core", false)):
			colour = Palette.ACCENT_CYAN
		elif definition.has("aim_steps"):
			colour = Palette.ACCENT_AMBER
		elif definition.has("caliber"):
			colour = Palette.ACCENT_MAGENTA
	if float(part["hp"]) < float(part["hp_max"]) - 0.001:
		colour = colour.lerp(Palette.ACCENT_RED, 0.5)
	return colour

## M5：装填完成脉冲。计时器只在固定步长里累减，保持确定性（绝不放 _process，绝不用 randf）。
func _drive_track_cannon_pulse(step_time: float) -> void:
	var next: Array = []
	for index in range(bank.cannons.size()):
		var loaded := bool(bank.cannons[index]["loaded"])
		next.append(loaded)
		var was := index < _drive_cannon_loaded.size() and bool(_drive_cannon_loaded[index])
		if loaded and not was:
			_drive_cannon_pulse[index] = DRIVE_RELOAD_PULSE_TIME
	for key in _drive_cannon_pulse.keys():
		var left := float(_drive_cannon_pulse[key]) - step_time
		if left <= 0.0:
			_drive_cannon_pulse.erase(key)
		else:
			_drive_cannon_pulse[key] = left
	_drive_cannon_loaded = next

## M5 护盾状态（design §6.6）：ACTIVE 报 hp，BROKEN 报充能剩余与进度条。
func _draw_drive_shield_rows(x: float, y: float) -> void:
	var list: Array = damage.shields() if damage != null else []
	if list.is_empty():
		_draw_text("护盾        本蓝图无护盾件", Vector2(x, y), 13, Palette.TEXT_LO, false)
		return
	_draw_text("护盾        %d 单元" % list.size(), Vector2(x, y), 13, Palette.TEXT_LO, false)
	y += 22.0
	var shown := 0
	for raw_shield in list:
		if shown >= 2:
			break
		shown += 1
		var shield: Dictionary = raw_shield
		var definition: Dictionary = definitions.get_module(String(shield["module_id"]))
		var label := String(definition.get("name", shield["module_id"]))
		if String(shield["state"]) == DamageSystem.SHIELD_ACTIVE:
			_draw_text("%s %.0f / %.0f" % [label, float(shield["hp"]), float(shield["hp_max"])], Vector2(x, y), 13, Palette.ACCENT_LIME, false)
		else:
			_draw_text("%s 充能 %.1fs" % [label, float(shield["charge"])], Vector2(x, y), 13, Palette.ACCENT_RED, false)
			var total := maxf(float(shield["recharge_s"]), 0.01)
			var progress := clampf(1.0 - float(shield["charge"]) / total, 0.0, 1.0)
			_draw_bar(Rect2(x, y + 5.0, 168.0, 4.0), progress, 1.0, Palette.ACCENT_LIME)
		y += 24.0

## M5 状态效果（design §8.8、roadmap M5 验收 6）：图标 + 剩余秒数必须可见。
func _draw_drive_status_rows(x: float, y: float) -> void:
	if damage == null:
		return
	var burn_count := 0
	var burn_left := 0.0
	var slow_left := 0.0
	var slow_factor := 1.0
	for raw_entry in damage.statuses():
		var entry: Dictionary = raw_entry
		if String(entry["kind"]) == "burn":
			burn_count += 1
			burn_left = maxf(burn_left, float(entry["remaining"]))
		elif String(entry["kind"]) == "slow":
			slow_left = maxf(slow_left, float(entry["remaining"]))
			slow_factor = minf(slow_factor, float(entry["factor"]))
	if burn_count <= 0 and slow_left <= 0.0:
		_draw_text("状态        无", Vector2(x, y), 13, Palette.TEXT_LO, false)
		return
	if burn_count > 0:
		_draw_text("▲ 灼烧 %d 处 · %.1fs" % [burn_count, burn_left], Vector2(x, y), 13, Palette.ACCENT_AMBER, false)
		y += 22.0
	if slow_left > 0.0:
		_draw_text("◆ 减速 %.1fs · 推力 ×%.2f" % [slow_left, slow_factor], Vector2(x, y), 13, Palette.ACCENT_MAGENTA, false)

func _draw_drive_hud() -> void:
	_draw_text("DRIVE LAB / M5", Vector2(48, 62), 18, Palette.ACCENT_CYAN, true)
	_draw_text("试驾沙盒", Vector2(48, 106), 34, Palette.TEXT_HI, false)
	_draw_text("自建刚体 · 差速驱动 · 管路供弹 · 护盾与状态效果 · 可拆解摧毁", Vector2(48, 138), 15, Palette.TEXT_LO, false)
	_draw_panel(DRIVE_HUD_LEFT, "刚体状态")
	_draw_panel(DRIVE_HUD_RIGHT, "炮管 / 操作")
	var metrics: Dictionary = tank.drive_metrics(_drive_throttle, _drive_steer)
	var left := DRIVE_HUD_LEFT.position.x + 20.0
	var y := DRIVE_HUD_LEFT.position.y + 96.0
	var rows: Array[String] = [
		"质量 M      %.1f u" % tank.mass_total,
		"惯量 I      %.0f" % tank.inertia,
		"质心        %.2f / %.2f 格" % [tank.centroid_cell.x, tank.centroid_cell.y],
		"速度        %.1f px/s" % tank.velocity.length(),
		"终端速度    %.1f px/s" % tank.max_speed(),
		"角速度      %.2f rad/s" % tank.angular_velocity,
		"朝向        %.0f°" % rad_to_deg(fposmod(tank.heading, TAU)),
		"推力 T      %.0f" % float(metrics["thrust"]),
		"扭矩 τ      %.0f" % float(metrics["torque"]),
		"撞墙伤害    %.1f" % tank.impact_damage_total,
		"部件数      %d" % tank.parts.size(),
	]
	for row_text in rows:
		_draw_text(row_text, Vector2(left, y), 16, Palette.TEXT_HI, false)
		y += 32.0
	_draw_bar(Rect2(left, y + 12.0, 208.0, 8.0), tank.velocity.length(), maxf(tank.max_speed(), 1.0), Palette.ACCENT_CYAN)
	var event_text := _drive_last_event if not _drive_last_event.is_empty() else "—"
	_draw_text("最近事件    %s" % event_text, Vector2(left, y + 58.0), 14, Palette.TEXT_LO, false)
	_draw_drive_shield_rows(left, y + 90.0)
	_draw_drive_status_rows(left, y + 154.0)
	var right := DRIVE_HUD_RIGHT.position.x + 20.0
	var cannon_y := DRIVE_HUD_RIGHT.position.y + 96.0
	var shown := 0
	for index in range(bank.cannons.size()):
		if shown >= 6:
			break
		shown += 1
		var cannon: Dictionary = bank.cannons[index]
		var definition: Dictionary = definitions.get_module(String(cannon["module_id"]))
		_draw_text(String(definition.get("name", cannon["module_id"])), Vector2(right, cannon_y), 16, Palette.TEXT_HI, false)
		var state := "装填 %.2fs" % float(cannon["reload_remaining"])
		if bool(cannon["loaded"]):
			state = "待发"
		elif float(cannon["reload_remaining"]) <= 0.0:
			state = "空膛"
		_draw_text("%s · 已发 %d" % [state, int(cannon["shots_fired"])], Vector2(right, cannon_y + 20.0), 13, Palette.ACCENT_AMBER, false)
		var reload := maxf(float(cannon["reload_s"]), 0.01)
		_draw_bar(Rect2(right, cannon_y + 26.0, 272.0, 6.0), reload - float(cannon["reload_remaining"]), reload, Palette.ACCENT_AMBER)
		## design §6.5：装填完成只脉冲一次，由边沿计时器驱动。
		var pulse_left := float(_drive_cannon_pulse.get(index, 0.0))
		if pulse_left > 0.0:
			var pulse_ratio := clampf(pulse_left / DRIVE_RELOAD_PULSE_TIME, 0.0, 1.0)
			var glow := 0.5 + 0.5 * sin(_time * 8.0)
			draw_rect(Rect2(right, cannon_y + 26.0, 272.0, 6.0), Color(Palette.ACCENT_LIME, (0.35 + 0.45 * glow) * pulse_ratio), false, 2.0)
		cannon_y += 58.0
	if bank.cannons.is_empty():
		_draw_text("当前蓝图没有炮管。", Vector2(right, cannon_y), 15, Palette.TEXT_LO, false)
	var hint_y := DRIVE_HUD_RIGHT.end.y - 178.0
	_draw_text("在飞弹药    %d" % field.shots.size(), Vector2(right, hint_y - 36.0), 14, Palette.ACCENT_AMBER, false)
	_draw_text("W / S    油门", Vector2(right, hint_y), 16, Palette.TEXT_HI, false)
	_draw_text("A / D    转向", Vector2(right, hint_y + 30.0), 16, Palette.TEXT_HI, false)
	_draw_text("空格     开火", Vector2(right, hint_y + 60.0), 16, Palette.TEXT_HI, false)
	_draw_text("R        重开试驾", Vector2(right, hint_y + 90.0), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, hint_y + 120.0), 16, Palette.TEXT_HI, false)
	var supply := "M4 管路：未初始化"
	if network != null:
		var broken := 0
		for entry in network.route_status():
			if not bool(entry["reachable"]):
				broken += 1
		supply = "M4 管路 · 在途 %d · 拥塞 %d · 断链 %d" % [network.rounds_in_flight(), network.congestion().size(), broken]
	_draw_text(supply, Vector2(right, hint_y + 150.0), 12, Palette.TEXT_LO, false)
	draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.86), true)
	draw_rect(DRIVE_STATUS, Color(Palette.WIRE, 0.55), false, 1.0)
	_draw_text(_status_message, Vector2(DRIVE_STATUS.position.x + 20.0, DRIVE_STATUS.position.y + 42.0), 16, Palette.TEXT_HI, false)

func _design_position(position: Vector2) -> Vector2:
	return position

func _grid_rect() -> Rect2:
	var model := _editor_model()
	var grid := model.grid_size if model != null else GRID_SIZE_VISUAL
	return Rect2(GRID_ORIGIN, Vector2(grid) * GRID_CELL)

func _cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(GRID_ORIGIN + Vector2(cell) * GRID_CELL, Vector2.ONE * GRID_CELL)

func _mouse_to_cell(position: Vector2) -> Vector2i:
	var model := _editor_model()
	var grid := model.grid_size if model != null else GRID_SIZE_VISUAL
	var local := (position - GRID_ORIGIN) / GRID_CELL
	return Vector2i(clampi(floori(local.x), 0, grid.x - 1), clampi(floori(local.y), 0, grid.y - 1))

func _option_window_start(option_count: int) -> int:
	if option_count <= BUILD_OPTION_VISIBLE:
		return 0
	return _option_scroll

func _module_glyph(name: String) -> String:
	return name.substr(0, 1) if not name.is_empty() else "?"

func _draw_text(text: String, position: Vector2, size: int, color: Color, mono: bool) -> void:
	var font: SystemFont = _font_mono if mono else _font_regular
	if font == null:
		return
	draw_string(font, position, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, color)

## 读取 `--steps=N`。用于把截图预热步数从写死改为可传入，从而能在同一模拟状态
## 下重截两帧（详见 `_capture_steps` 的声明注释）。非法值/未传时返回 -1，
## 调用方据此回退到该页原本的默认步数。
func _requested_capture_steps() -> int:
	for argument in OS.get_cmdline_user_args():
		if not argument.begins_with("--steps="):
			continue
		var raw := argument.substr("--steps=".length())
		if not raw.is_valid_int():
			printerr("CAPTURE_BAD_STEPS %s" % raw)
			return -1
		var parsed := int(raw)
		if parsed <= 0:
			printerr("CAPTURE_BAD_STEPS %s" % raw)
			return -1
		return parsed
	return -1

func _handle_capture_request() -> void:
	## 先解析 `--steps=N`，因为下面各页的预热函数会读它。
	_capture_steps = _requested_capture_steps()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_target = argument.substr("--capture=".length())
		elif argument == "--screen=drive":
			_enter_drive()
			_drive_capture_warmup()
		elif argument == "--screen=match":
			_enter_match()
			_match_capture_warmup()
		elif argument == "--screen=survival":
			_enter_survival()
			_survival_capture_warmup()
		elif argument == "--screen=survival_levelup":
			_enter_survival()
			_survival_capture_level_up()
		elif argument == "--screen=survival_shop":
			_enter_survival()
			_survival_capture_shop()
		elif argument == "--screen=survival_summary":
			_enter_survival()
			_survival_capture_summary()
		elif argument == "--screen=survival_modify":
			_enter_survival()
			_survival_capture_modify()
	if _capture_target.is_empty():
		return
	## 预热已经跑完，从这一刻起冻结 `_process()`，让取图结果成为预热步数的确定函数。
	## 冻结前必须把「过渡类」状态直接推到终值：`_screen_opacity` 的初始值是 0，
	## 它原本靠在 `_process` 里 `move_toward` 才涨到 1.0；一旦冻结，页面就停在
	## 淡入起点，实测截图只有 8587 B（几乎全黑）。这里显式置终值。
	_screen_opacity = 1.0
	_focus_rail_alpha = 1.0
	_capture_frozen = true
	_capture_next_frame()

func _capture_next_frame() -> void:
	if _capture_wait_frames > 0:
		_capture_wait_frames -= 1
		await RenderingServer.frame_post_draw
		_capture_next_frame()
		return
	var image: Image = get_viewport().get_texture().get_image()
	if image == null:
		printerr("CAPTURE_FAILED null image")
		get_tree().quit(1)
		return
	var error := image.save_png(_capture_target)
	if error != OK:
		printerr("CAPTURE_FAILED save_png err=%d path=%s" % [error, _capture_target])
		get_tree().quit(1)
		return
	print("CAPTURE_OK %s" % _capture_target)
	get_tree().quit(0)

## 截图专用固定预热：先跑 150 个固定步，让双方真正接火，而不是空场。
## 与试驾页的 _drive_capture_warmup 同理：预热路径固定，便于逐次比对。
## 步数可用 `--steps=N` 覆盖；不传时仍是 150。开火时机按步数比例缩放（原为 150 步里的第 60 步），
## 保证不同 N 下都是「先跑一段、中途开一炮」的同一个剧本。
func _match_capture_warmup() -> void:
	if not _match_ready or match_session == null:
		return
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	match_session.duel.set_input(Duel.TAG_PLAYER, 1.0, 0.0)
	var total_steps := _warmup_steps(150)
	var fire_step := maxi(total_steps * 2 / 5, 1)
	for step_index in range(total_steps):
		if step_index == fire_step:
			match_session.duel.fire(Duel.TAG_PLAYER)
		_match_step(step_time)



## ===== M9 波次生存（design §3.4）=====
##
## 单场景内的第四张战斗页：BATTLE → (LEVEL_UP)? → SHOP → 下一波；驾驶舱被毁直接 RUN_SUMMARY。
## 玩法逻辑全部在 scripts/survival_run.gd，这里只做输入、定步推进与绘制。
## 注意：本页必须用自己的世界→屏幕缩放函数；复用 _drive_scale() / _match_scale()
## 会读到别的页面的会话对象，静默返回错误比例（M6 已踩过一次）。

## 起始坦克的布局与摆放顺序**只有一份**：`SurvivalRun.STARTER_*` + `SurvivalRun.build_starter()`。
## 生存页与 `tests/survival_smoke.gd` 都调它，避免「测试用的最小合法车」与「实际开局车」分叉。
## 用户报告的「炮弹打不动人」就源于这份布局曾被写成 20mm（见 `survival_run.gd` 顶部说明）。
const SURVIVAL_CARD_WIDTH := 360.0
const SURVIVAL_CARD_HEIGHT := 300.0
const SURVIVAL_SHOP_COLUMNS := 3
const SURVIVAL_SHOP_WIDTH := 360.0
const SURVIVAL_SHOP_HEIGHT := 132.0
## 生存页的命中动效与镜像面板几何。镜像面板放在右 HUD 下半部（键位提示到 y=410 结束，
## `DRIVE_HUD_RIGHT` 到 y=852 结束），因此 436–836 区间不与任何现有元素重叠。
const SURVIVAL_MIRROR_RECT := Rect2(1560.0, 436.0, 312.0, 400.0)
## 命中闪光持续时间（秒，固定步长累减）。
const HIT_FLASH_TIME := 0.14
## 伤害悬浮数字：上浮速度（像素/秒，世界单位）与存活时长。
## 两者都是导出常量而不是魔法数，方便后续调手感；写成常量也便于 smoke 断言。
const DAMAGE_POPUP_RISE := 46.0
const DAMAGE_POPUP_LIFE := 0.85
## 同一帧同一侧最多显示几条数字：多炮齐射或殉爆时避免数字糊成一团。
const DAMAGE_POPUP_PER_SIDE := 6

var _survival_sell_index := 0

## 生存页的瞬时动效（命中 / 击毁 / 脱落）。倒计时只在 `_survival_step` 里推进，
## 与试驾页同一纪律：绝不放 `_process`，绝不用 `randf`。
var _survival_fx := FxLayer.new()
## 最近一次命中的世界坐标与剩余闪光时间：让“打中了”这件事在画面上无法被忽略。
var _hit_flash_at := Vector2.ZERO
var _hit_flash_left := 0.0

## 改装页复用建造页的整套编辑器（网格 / 模块目录 / 工具 / 属性校验）。
## 两页只差模型来源：建造页用 `builder`，改装页用 `survival_builder`；
## 由 `_editor_model()` 分流，因此这里不再保留任何改装页专属几何常量。
var _survival_modify_index := 0

func _survival_scale() -> float:
	if survival == null or survival.duel == null or survival.duel.arena.size.x <= 0.0:
		return 1.0
	return DRIVE_VIEW.size.x / survival.duel.arena.size.x

func _survival_to_screen(world: Vector2, scale_factor: float) -> Vector2:
	return DRIVE_VIEW.position + (world - survival.duel.arena.position) * scale_factor

## 摆放起始坦克：直接转调唯一来源，不在页面层重复一份布局。
func _build_survival_starter(model: GridBuilder) -> String:
	return SurvivalRun.build_starter(model)

func _enter_survival() -> void:
	if definitions == null:
		return
	survival_builder = GridBuilder.new()
	if not survival_builder.setup(definitions):
		printerr("SURVIVAL_ENTER_FAILED builder_setup")
		_set_status("拒绝生存：建造模型初始化失败。")
		_status_error = true
		return
	## 起始坦克用代码构建，不用 `example_assault.json`：
	## 那张示例蓝图本身不合法（模块落在 y=2、平台只有 y=3 一行，
	## `load_blueprint` 会以「engine_medium 未落在平台上」拒绝），且无任何代码/文档引用它。
	var reason: String = _build_survival_starter(survival_builder)
	if not reason.is_empty():
		printerr("SURVIVAL_ENTER_FAILED starter %s" % reason)
		_set_status("拒绝生存：起始坦克 %s" % reason)
		_status_error = true
		return
	survival = SurvivalRun.new()
	if not survival.setup(definitions, DRIVE_ARENA_ID, 20261017):
		printerr("SURVIVAL_ENTER_FAILED run_setup")
		_set_status("拒绝生存：run 初始化失败。")
		_status_error = true
		return
	survival.bind_player(survival_builder)
	if not survival.start_wave():
		printerr("SURVIVAL_ENTER_FAILED start_wave")
		_set_status("拒绝生存：第一波生成失败。")
		_status_error = true
		return
	printerr("SURVIVAL_ENTERED wave=%d enemies=%d houses=%d debris=%d" % [survival.wave, survival.duel.alive_in_team(Duel.TEAM_ENEMY).size(), survival.houses.size(), survival.debris.size()])
	_survival_accumulator = 0.0
	_survival_held.clear()
	_survival_sell_index = 0
	_survival_event = "第 1 波开始"
	_survival_ready = true
	_set_screen(SCREEN_SURVIVAL)
	_status_error = false
	_status_message = "生存：W/S 油门 · A/D 转向 · 空格 开火 · Esc 返回"
	queue_redraw()

func _exit_survival() -> void:
	_survival_held.clear()
	_survival_ready = false
	if survival != null:
		survival.close_run()
	_survival_event = ""
	_set_screen(SCREEN_MAIN)
	queue_redraw()

func _handle_survival_key(event: InputEventKey) -> void:
	if survival == null:
		return
	var key: Key = event.keycode
	var pressed := event.pressed and not event.echo
	if key == KEY_ESCAPE:
		if pressed:
			## 改装页的 Esc 先退出改装、回到进入时的阶段；再按一次才离开生存页。
			if survival.stage == SurvivalRun.STAGE_MODIFY:
				_survival_leave_modify()
			else:
				_exit_survival()
		return
	if survival.stage == SurvivalRun.STAGE_BATTLE:
		_survival_battle_key(key, event)
		return
	if not pressed:
		return
	if survival.stage == SurvivalRun.STAGE_MODIFY:
		## 改装页直接用建造页的键盘处理：方向键/WASD 光标、1/2/3 选层、A/D 选件、
		## Q/E 调炮管 aim、R 旋转、X 拆解、Ctrl+Z/Y 撤销重做、C 定位驾驶舱。
		## 只把 Esc（已在上方处理）与 Ctrl+S/O 蓝图存读屏蔽掉。
		if (key == KEY_S or key == KEY_O) and event.ctrl_pressed:
			_survival_event = "改装页不提供蓝图存读"
			queue_redraw()
			return
		_handle_build_key(event)
		return
	if survival.stage == SurvivalRun.STAGE_LEVEL_UP:
		_survival_level_key(key)
	elif survival.stage == SurvivalRun.STAGE_SHOP:
		_survival_shop_key(key)
	elif survival.stage == SurvivalRun.STAGE_SUMMARY:
		if key == KEY_R:
			_enter_survival()

func _survival_battle_key(key: Key, event: InputEventKey) -> void:
	if key == KEY_R:
		if event.pressed and not event.echo:
			_enter_survival()
		return
	if key == KEY_SPACE:
		if event.pressed and not event.echo:
			var fired := 0
			if survival.duel != null:
				fired = survival.duel.fire(Duel.TAG_PLAYER)
			if fired > 0:
				_survival_event = "开火：%d 发离膛" % fired
			else:
				_survival_event = "未装填或冷却中"
			queue_redraw()
		return
	if key == KEY_W or key == KEY_UP:
		_survival_held["throttle_up"] = event.pressed
	elif key == KEY_S or key == KEY_DOWN:
		_survival_held["throttle_down"] = event.pressed
	elif key == KEY_A or key == KEY_LEFT:
		_survival_held["steer_left"] = event.pressed
	elif key == KEY_D or key == KEY_RIGHT:
		_survival_held["steer_right"] = event.pressed
	else:
		return
	_survival_apply_input()
	queue_redraw()

func _survival_apply_input() -> void:
	if survival == null or survival.duel == null:
		return
	var up := 1.0 if bool(_survival_held.get("throttle_up", false)) else 0.0
	var down := 1.0 if bool(_survival_held.get("throttle_down", false)) else 0.0
	var left := 1.0 if bool(_survival_held.get("steer_left", false)) else 0.0
	var right := 1.0 if bool(_survival_held.get("steer_right", false)) else 0.0
	survival.duel.set_input(Duel.TAG_PLAYER, up - down, right - left)

## 三选一**不可跳过**（Q23）：只有合法索引才推进，非法索引不改变状态。
func _survival_level_key(key: Key) -> void:
	## 改装按钮：与三张卡并列的独立入口，不占卡位（design §3.4.2）。
	if key == KEY_M:
		_survival_enter_modify()
		return
	var index := -1
	if key == KEY_1:
		index = 0
	elif key == KEY_2:
		index = 1
	elif key == KEY_3:
		index = 2
	if index < 0:
		return
	if survival.take_level_choice(index):
		if survival.stage == SurvivalRun.STAGE_LEVEL_UP:
			_survival_event = "又升一级：继续三选一"
		else:
			_survival_event = "已领取升级奖励，进入商店"
		queue_redraw()

func _survival_shop_key(key: Key) -> void:
	## 改装按钮：商店页的独立入口（design §3.4.3）。
	if key == KEY_M:
		_survival_enter_modify()
		return
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		if survival.start_next_wave():
			_survival_accumulator = 0.0
			_survival_held.clear()
			_survival_sell_index = 0
			_survival_event = "第 %d 波开始" % survival.wave
			queue_redraw()
		return
	if key == KEY_F:
		if survival.reroll_shop():
			_survival_event = "商店已刷新"
		else:
			_survival_event = "信用点不足，无法刷新"
		queue_redraw()
		return
	if key == KEY_Q:
		_survival_sell_index = maxi(_survival_sell_index - 1, 0)
		queue_redraw()
		return
	if key == KEY_E:
		_survival_sell_index = mini(_survival_sell_index + 1, maxi(survival.inventory.size() - 1, 0))
		queue_redraw()
		return
	if key == KEY_X:
		if survival.sell_inventory(_survival_sell_index):
			_survival_sell_index = maxi(survival.inventory.size() - 1, 0)
			_survival_event = "已出售库存配件"
		else:
			_survival_event = "没有可出售的库存配件"
		queue_redraw()
		return
	var slot := int(key) - int(KEY_1)
	if slot < 0 or slot >= SURVIVAL_SHOP_COLUMNS * 2:
		return
	if survival.buy_shop_slot(slot):
		_survival_event = "已购买第 %d 件商品" % (slot + 1)
	else:
		_survival_event = "无法购买：已售出或信用点不足"
	queue_redraw()

## 固定步长推进；与试驾 / 对局一致，绝不缩放 dt（design §5.3）。
func _survival_simulate(delta: float) -> void:
	if not _survival_ready or survival == null:
		_survival_accumulator = 0.0
		return
	if survival.stage != SurvivalRun.STAGE_BATTLE:
		_survival_accumulator = 0.0
		return
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	_survival_accumulator += delta
	var steps := 0
	while _survival_accumulator >= step_time and steps < DRIVE_MAX_STEPS:
		_survival_accumulator -= step_time
		steps += 1
		_survival_step(step_time)

func _survival_step(step_time: float) -> void:
	if survival == null or survival.duel == null:
		return
	var events: Array = survival.step_battle(step_time)
	for raw_event in events:
		var entry: Dictionary = raw_event
		var kind := String(entry.get("kind", ""))
		## 命中反馈：这是用户报告「打上去没反应」的直接修补点。
		## 旧版这里只处理 house_destroyed / core_destroyed / detach / level_up_opened，
		## 命中坦克本体时屏幕上什么都没有——即使伤害真的算对了。
		if kind == "impact" and String(entry.get("target", "")) == "tank":
			var at := Vector2(entry.get("pos", Vector2.ZERO))
			_push_survival_fx("hit", at, 10.0, Palette.ACCENT_AMBER, 0.22)
			_hit_flash_at = at
			_hit_flash_left = HIT_FLASH_TIME
			var victim := String(entry.get("tag", ""))
			## v3.20 悬浮数字：**造成伤害与被击伤害都显示**。
			## 数值来自 `duel._resolve_impact()` 写回事件的真实结算值，不是弹药的 base_damage。
			## 打中敌人 → 白青色数字；自己被命中 → 红色数字；护盾吸收单独用绿色数字。
			var dealt := float(entry.get("damage", 0.0))
			var absorbed := float(entry.get("shield", 0.0))
			if victim == Duel.TAG_PLAYER:
				if dealt > 0.0:
					_push_damage_popup(at, dealt, Palette.ACCENT_RED, "received")
				if absorbed > 0.0:
					_push_damage_popup(at, absorbed, Palette.ACCENT_LIME, "shield")
				_survival_event = "本体被命中"
			else:
				if dealt > 0.0:
					_push_damage_popup(at, dealt, Palette.ACCENT_CYAN, "dealt")
				if absorbed > 0.0:
					_push_damage_popup(at, absorbed, Palette.ACCENT_LIME, "shield")
				_survival_event = "命中 %s" % victim
		elif kind == "shield_hit":
			_push_survival_fx("shield", Vector2.ZERO, 0.0, Palette.ACCENT_LIME, 0.25)
		elif kind == "destroyed":
			var side := String(entry.get("side", ""))
			var module_id := String(entry.get("module_id", ""))
			## 必须区分敌我：旧版只写「击毁 X」，玩家看不出是自己打掉的还是自己被打掉的。
			if side == Duel.TAG_PLAYER:
				_survival_event = "自损 %s" % module_id
			else:
				_survival_event = "击毁敌 %s" % module_id
			for raw_cell in entry.get("cells", []):
				_push_survival_fx("break", _survival_cell_world(Vector2i(raw_cell), side), 14.0, Palette.ACCENT_AMBER, 0.5)
		elif kind == "house_destroyed":
			_survival_event = "房屋被摧毁"
		elif kind == "core_destroyed":
			_survival_event = "驾驶舱被摧毁"
		elif kind == "detach":
			_survival_event = "整块脱落"
		elif kind == "level_up_opened":
			_survival_event = "升级：选择一项奖励"
	_survival_tick_fx(step_time)
	if survival.stage != SurvivalRun.STAGE_BATTLE:
		_survival_held.clear()

## 事件里的 `cell` 是坦克**建造格**坐标，必须先经该侧刚体转成世界坐标再画。
func _survival_cell_world(cell: Vector2i, tag: String) -> Vector2:
	if survival == null or survival.duel == null:
		return Vector2.ZERO
	var hull: TankBody = survival.duel.tank_of(tag if not tag.is_empty() else Duel.TAG_PLAYER)
	if hull == null:
		return Vector2.ZERO
	return hull.world_position_of_cell(cell)

func _push_survival_fx(kind: String, at: Vector2, radius: float, colour: Color, life: float) -> void:
	_survival_fx.push(kind, at, radius, colour, life)

## 伤害悬浮数字：把一次真实结算的数值推入动效层（`kind = "damage"`，带 `text`）。
## 四舍五入到整数并带正负记号：**造成**用 `+N`、**承受**用 `-N`，颜色区分敌我。
## 同侧同帧最多 `DAMAGE_POPUP_PER_SIDE` 条：多炮齐射时旧数字排队会让画面糊成一片，
## 超出就丢弃最新的一条——保先保稳，不保全。
func _push_damage_popup(at: Vector2, amount: float, colour: Color, mode: String) -> void:
	if amount <= 0.0:
		return
	var shown := int(roundf(amount))
	if shown <= 0:
		return
	var counting := 0
	for raw_entry in _survival_fx.entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) == "damage" and String(entry.get("mode", "")) == mode:
			counting += 1
	if counting >= DAMAGE_POPUP_PER_SIDE:
		return
	## 符号语义：**承受**与**护盾吸收**都是玩家损失，用负号；**造成**用正号。
	## （旧版一律 `%+d`，导致被击中时也显示 `+17`——看起来像加血，语义错误。）
	var label := ""
	if mode == "dealt":
		label = "+%d" % shown
	else:
		label = "-%d" % shown
	_survival_fx.push("damage", at, 0.0, colour, DAMAGE_POPUP_LIFE, label)
	## `mode` 在 push 之后补写：`push()` 的签名保持向后兼容（旧调用点不动），
	## 而模式信息只有绘制/限流需要，不进入通用字段。
	(_survival_fx.entries[_survival_fx.entries.size() - 1] as Dictionary)["mode"] = mode

## 动效倒计时在固定步长里累减，保持确定性（绝不放 `_process`，绝不用 `randf`）。
## 命中闪光的倒计时是生存页独有的（不属于通用动效列表），因此留在这里。
func _survival_tick_fx(step_time: float) -> void:
	if _hit_flash_left > 0.0:
		_hit_flash_left = maxf(_hit_flash_left - step_time, 0.0)
	_survival_fx.step(step_time)

func _draw_survival() -> void:
	if survival == null:
		return
	## 改装页**复用建造页整套绘制**（网格 / 模块目录 / 属性校验 / 底部工具），
	## 不再自写一套；只额外画一条改装页的标题、支出与退出按钮。
	if survival.stage == SurvivalRun.STAGE_MODIFY:
		_draw_build()
		_draw_modify_overlay()
		return
	if survival.duel != null:
		_draw_survival_arena()
		_draw_survival_hud()
	if survival.stage == SurvivalRun.STAGE_LEVEL_UP:
		_draw_survival_level_up()
	elif survival.stage == SurvivalRun.STAGE_SHOP:
		_draw_survival_shop()
	elif survival.stage == SurvivalRun.STAGE_SUMMARY:
		_draw_survival_summary()

func _draw_survival_arena() -> void:
	var duel: Duel = survival.duel
	var scale_factor := _survival_scale()
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.94), true)
	draw_rect(Rect2(DRIVE_VIEW.position, duel.arena.size * scale_factor), Palette.ACCENT_CYAN, false, 2.0)
	## 竞技场固定障碍直接读数据，避免与 duel.obstacles 里的房屋条目重复绘制。
	for raw_obstacle in definitions.get_arena(DRIVE_ARENA_ID).get("obstacles", []):
		var obstacle: Dictionary = raw_obstacle
		if obstacle.has("rect"):
			var r: Array = obstacle["rect"]
			var rect := Rect2(Vector2(float(r[0]), float(r[1])) * float(definitions.global_number("cell_size", 16.0)), Vector2(float(r[2]), float(r[3])) * float(definitions.global_number("cell_size", 16.0)))
			var screen_rect := Rect2(DRIVE_VIEW.position + rect.position * scale_factor, rect.size * scale_factor)
			draw_rect(screen_rect, Color(Palette.ACCENT_RED, 0.16), true)
			draw_rect(screen_rect, Palette.ACCENT_RED, false, 1.5)
		elif obstacle.has("circle"):
			var c: Array = obstacle["circle"]
			var centre := _survival_to_screen(Vector2(float(c[0]), float(c[1])) * float(definitions.global_number("cell_size", 16.0)), scale_factor)
			var radius := float(c[2]) * float(definitions.global_number("cell_size", 16.0)) * scale_factor
			draw_circle(centre, radius, Color(Palette.ACCENT_RED, 0.16))
			draw_arc(centre, radius, 0.0, TAU, 48, Palette.ACCENT_RED, 1.5)
	## 房屋：硬碰撞体，用琥珀色实心块 + 血条。
	for raw_house in survival.houses:
		var house: Dictionary = raw_house
		if not bool(house["alive"]):
			continue
		var house_rect: Rect2 = house["rect"]
		var screen_house := Rect2(DRIVE_VIEW.position + house_rect.position * scale_factor, house_rect.size * scale_factor)
		draw_rect(screen_house, Color(Palette.ACCENT_AMBER, 0.14), true)
		draw_rect(screen_house, Palette.ACCENT_AMBER, false, 1.5)
		var ratio := clampf(float(house["hp"]) / maxf(float(house["hp_max"]), 0.001), 0.0, 1.0)
		draw_rect(Rect2(screen_house.position + Vector2(0.0, -6.0), Vector2(screen_house.size.x, 3.0)), Color(Palette.WIRE, 0.4), true)
		draw_rect(Rect2(screen_house.position + Vector2(0.0, -6.0), Vector2(screen_house.size.x * ratio, 3.0)), Palette.ACCENT_AMBER, true)
	## 残骸：不是碰撞体，用青色小方块表示可碾过。
	var cell_px := float(definitions.global_number("cell_size", 16.0))
	for raw_debris in survival.debris:
		var item: Dictionary = raw_debris
		if bool(item["taken"]):
			continue
		var centre_world := (Vector2(Vector2i(item["cell"])) + Vector2(0.5, 0.5)) * cell_px
		var at := _survival_to_screen(centre_world, scale_factor)
		var half := cell_px * 0.35 * scale_factor
		var box := Rect2(at - Vector2(half, half), Vector2(half, half) * 2.0)
		draw_rect(box, Color(Palette.ACCENT_LIME, 0.30), true)
		draw_rect(box, Palette.ACCENT_LIME, false, 1.0)
	## 坦克：逐部件按血量上色（完好队伍色 / 中度琥珀 / 濒危红）。
	for raw_tag in duel.alive_tags():
		_draw_survival_hull(String(raw_tag), scale_factor)
	_draw_survival_fx(scale_factor)
	for shot in duel.field.shots:
		var head := _survival_to_screen(Vector2(shot["pos"]), scale_factor)
		var tail := _survival_to_screen(Vector2(shot["prev"]), scale_factor)
		var colour := Palette.ACCENT_AMBER if String(shot["shooter"]) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
		draw_line(tail, head, Color(colour, 0.7), 1.5)
		draw_circle(head, maxf(float(shot["radius"]) * scale_factor, 2.0), colour)
	## 命中闪光画在炮弹之上，确保不会被格线淹掉。
	_draw_survival_hit_flash(scale_factor)
	## 伤害数字画在最后：必须盖在炮弹、命中闪光与所有地形之上。
	_draw_damage_popups(scale_factor)

## 逐部件按**血量比例**上色：完好是队伍色、中度损伤转琥珀、濒危转红、已毁不留格。
## 旧版整台只有一种颜色、不看 HP，玩家看不见自己到底打掉了什么——这正是
## 「炮弹似乎不能对敌人造成伤害」的直接感知来源（即使伤害真的算对了）。
func _survival_hull_colour(tag: String, part: Dictionary) -> Color:
	var base := Palette.ACCENT_CYAN if tag == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
	if bool(definitions.get_module(String(part["module_id"])).get("core", false)):
		base = Palette.ACCENT_AMBER
	var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
	if ratio > 0.6:
		return base
	if ratio > 0.25:
		return base.lerp(Palette.ACCENT_AMBER, 0.55)
	return Palette.ACCENT_RED

## 生存页每部件颜色：`_survival_hull_colour(tag, part)` 的绑定包装（bind 追加在尾）。
func _survival_part_colour(part: Dictionary, tag: String) -> Color:
	return _survival_hull_colour(tag, part)

## 填充透明度随血量下降：一眼能看出哪块被打残了。
func _survival_hull_alpha(part: Dictionary) -> float:
	var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
	return 0.14 + 0.20 * ratio

func _draw_survival_hull(tag: String, scale_factor: float) -> void:
	var hull: TankBody = survival.duel.tank_of(tag)
	if hull == null or hull.parts.is_empty():
		return
	var origin := _survival_to_screen(hull.position, scale_factor)
	_draw_hull_shared(hull, origin, hull.heading, scale_factor, _survival_part_colour.bind(tag), _survival_hull_alpha)

## 命中 / 击毁 / 脱落的瞬时动效。所有半径用 `sin(_time)` 脉动，不用 `randf`。
func _draw_survival_fx(scale_factor: float) -> void:
	for raw_entry in _survival_fx.entries:
		var entry: Dictionary = raw_entry
		var life := float(entry["life"])
		var left := float(entry["left"])
		if life <= 0.0:
			continue
		var t := clampf(left / life, 0.0, 1.0)
		var colour: Color = entry["colour"]
		if String(entry["kind"]) == "shield":
			continue
		if String(entry["kind"]) == "damage":
			## 悬浮数字单独画：不画圆环，只画上浮的文字（详见 `_draw_damage_popups`）。
			continue
		var at := _survival_to_screen(Vector2(entry["pos"]), scale_factor)
		var radius := maxf(float(entry["radius"]) * scale_factor * (0.6 + 0.4 * t), 2.0)
		var alpha := 0.75 * t
		draw_circle(at, radius, Color(colour, alpha * 0.5))
		draw_arc(at, radius, 0.0, TAU, 20, Color(colour, alpha), 1.5)

## 伤害悬浮数字：从命中点向上飘升并淡出。
## `progress = 1 - left/life` 从 0 走到 1；上升距离先快后慢（`sqrt`），像真的被击飞。
## 字号随接近消失而略微缩小，强化「远离视线」的感觉；**不用随机偏移**，
## 否则两次跑同一模拟会得到不同像素，截图逐字节比对就失效了。
## 同一帧多条数字会在垂直方向按序号错开一行，避免完全重叠。
func _draw_damage_popups(scale_factor: float) -> void:
	var stack := 0
	for raw_entry in _survival_fx.entries:
		var entry: Dictionary = raw_entry
		if String(entry.get("kind", "")) != "damage":
			continue
		var text := String(entry.get("text", ""))
		if text.is_empty():
			continue
		var life := float(entry["life"])
		if life <= 0.0:
			continue
		var progress := clampf(1.0 - float(entry["left"]) / life, 0.0, 1.0)
		var rise := DAMAGE_POPUP_RISE * sqrt(progress) * scale_factor
		var offset := Vector2(0.0, -rise - float(stack) * 14.0)
		var at := _survival_to_screen(Vector2(entry["pos"]), scale_factor) + offset
		var colour: Color = entry["colour"]
		## 前 70% 保持不透明，后 30% 才淡出：数字要看得清，不能一出来就开始糊。
		var alpha := 1.0 if progress < 0.7 else clampf((1.0 - progress) / 0.3, 0.0, 1.0)
		var size := int(roundf(20.0 - 4.0 * progress))
		## 先画一层暗色底再画本体：霓虹背景下纯色小字容易被地形线淹掉。
		_draw_text(text, at + Vector2(1.0, 1.0), size, Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
		_draw_text(text, at, size, Color(colour, alpha), true)
		stack += 1

## 最近一次命中点的高亮圈：即便命中发生在缩放后只有几像素的敌车上，也能看见。
func _draw_survival_hit_flash(scale_factor: float) -> void:
	if _hit_flash_left <= 0.0:
		return
	var t := clampf(_hit_flash_left / HIT_FLASH_TIME, 0.0, 1.0)
	var at := _survival_to_screen(_hit_flash_at, scale_factor)
	var radius := 6.0 + 10.0 * (1.0 - t)
	draw_circle(at, radius, Color(Palette.ACCENT_AMBER, 0.30 * t))
	draw_arc(at, radius, 0.0, TAU, 24, Color(Palette.TEXT_HI, 0.9 * t), 2.0)

func _draw_survival_hud() -> void:
	var left := DRIVE_HUD_LEFT.position.x
	var right := DRIVE_HUD_RIGHT.position.x
	var boss_mark := " · BOSS" if survival.is_boss_wave() else ""
	var wave_colour := Palette.ACCENT_MAGENTA if survival.is_boss_wave() else Palette.ACCENT_CYAN
	_draw_text("波次 %d%s" % [survival.wave, boss_mark], Vector2(left, 120), 16, wave_colour, true)
	_draw_text("SURVIVE", Vector2(left, 152), 30, Palette.TEXT_HI, false)
	_draw_text("剩余时间", Vector2(left, 220), 14, Palette.TEXT_LO, false)
	var time_colour := Palette.ACCENT_AMBER if survival.wave_time_left > 10.0 else Palette.ACCENT_RED
	_draw_text("%04.1f s" % maxf(survival.wave_time_left, 0.0), Vector2(left, 252), 26, time_colour, true)
	_draw_text("金钱 %d cr" % int(roundf(survival.credit)), Vector2(left, 320), 16, Palette.ACCENT_LIME, true)
	_draw_text("等级 %d" % survival.level, Vector2(left, 356), 16, Palette.ACCENT_CYAN, false)
	var need := survival.xp_needed_for(survival.level)
	_draw_text("经验 %d / %d" % [int(roundf(survival.xp_into_level)), int(roundf(need))], Vector2(left, 386), 14, Palette.TEXT_LO, false)
	draw_rect(Rect2(left, 396.0, 232.0, 6.0), Color(Palette.WIRE, 0.3), true)
	draw_rect(Rect2(left, 396.0, 232.0 * clampf(survival.xp_into_level / maxf(need, 0.001), 0.0, 1.0), 6.0), Palette.ACCENT_CYAN, true)
	var alive_houses := 0
	for raw_house in survival.houses:
		if bool((raw_house as Dictionary)["alive"]):
			alive_houses += 1
	var left_debris := 0
	for raw_debris in survival.debris:
		if not bool((raw_debris as Dictionary)["taken"]):
			left_debris += 1
	_draw_text("房屋 %d · 残骸 %d" % [alive_houses, left_debris], Vector2(left, 440), 14, Palette.TEXT_LO, false)
	_draw_text("敌人 %d · 击杀 %d" % [survival.duel.alive_in_team(Duel.TEAM_ENEMY).size(), survival.kills], Vector2(left, 470), 14, Palette.TEXT_LO, false)
	## 累计已造成伤害：旧版从不显示这个值，玩家无从判断炮火到底有没有生效。
	_draw_text("总输出 %d" % int(roundf(survival.total_damage)), Vector2(left, 498), 14, Palette.ACCENT_AMBER, true)
	_draw_text("最近事件", Vector2(left, 540), 14, Palette.TEXT_LO, false)
	_draw_text(_survival_event, Vector2(left, 576), 15, Palette.ACCENT_LIME, false)
	_draw_text("W / S    油门", Vector2(right, 240), 16, Palette.TEXT_HI, false)
	_draw_text("A / D    转向", Vector2(right, 270), 16, Palette.TEXT_HI, false)
	_draw_text("空格     开火", Vector2(right, 300), 16, Palette.TEXT_HI, false)
	_draw_text("R        重开 run", Vector2(right, 330), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, 360), 16, Palette.TEXT_HI, false)
	_draw_text("战斗期禁止改装", Vector2(right, 410), 14, Palette.ACCENT_AMBER, false)
	_draw_survival_mirror()
	draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.86), true)
	draw_rect(DRIVE_STATUS, Color(Palette.WIRE, 0.55), false, 1.0)
	_draw_text(_status_message, DRIVE_STATUS.position + Vector2(20.0, 42.0), 16, Palette.TEXT_HI, false)

## 坦克镜像面板（用户 2026-10-17 要求：「要有一个小窗口显示一个坦克的镜像，展示坦克每个模块的状态」）。
##
## 三块内容：① 俯视镜像（正北朝上，不跟随车头旋转，便于对位置）；② 逐模块状态行
## （按血量比升序排，最残的排前面）；③ 平台格的汇总条。
## 位置在 `SURVIVAL_MIRROR_RECT`（右 HUD 下半部），与键位提示（到 y=410）和
## `DRIVE_HUD_RIGHT` 下边界（y=852）都不重叠。
const MIRROR_ROW_VISIBLE := 6
const MIRROR_ROW_HEIGHT := 22.0

func _survival_mirror_panel_rect() -> Rect2:
	return SURVIVAL_MIRROR_RECT

func _draw_survival_mirror() -> void:
	if survival == null or survival.duel == null:
		return
	var hull: TankBody = survival.duel.tank_of(Duel.TAG_PLAYER)
	if hull == null:
		return
	var panel := _survival_mirror_panel_rect()
	draw_rect(panel, Color(Palette.BG_BASE, 0.88), true)
	draw_rect(panel, Color(Palette.WIRE, 0.55), false, 1.0)
	var x := panel.position.x + 12.0
	_draw_text("坦克镜像", Vector2(x, panel.position.y + 20.0), 14, Palette.ACCENT_CYAN, false)
	## ② 镜像本体：把坦克格用局部坐标画到面板上部，正北朝上（heading 固定为 0）。
	var mirror_rect := Rect2(x, panel.position.y + 30.0, panel.size.x - 24.0, 132.0)
	_draw_survival_mirror_hull(hull, mirror_rect)
	## ③ 汇总行：平台格总血量 + 模块数量。
	var platform_hp := 0.0
	var platform_hp_max := 0.0
	var platform_cells := 0
	var module_count := 0
	var mobility_count := 0
	for part in hull.parts:
		var kind := String(part["kind"])
		if kind == TankBody.KIND_PLATFORM_CELL or kind == TankBody.KIND_PLATFORM_SHAPE:
			platform_hp += float(part["hp"])
			platform_hp_max += float(part["hp_max"])
			platform_cells += (part["cells"] as Array).size()
		elif kind == TankBody.KIND_MOBILITY:
			mobility_count += 1
		else:
			module_count += 1
	var info_y := mirror_rect.position.y + mirror_rect.size.y + 16.0
	_draw_text("平台 %d 格 · 模块 %d · 行进 %d" % [platform_cells, module_count, mobility_count], Vector2(x, info_y), 13, Palette.TEXT_LO, false)
	var platform_ratio := clampf(platform_hp / maxf(platform_hp_max, 0.001), 0.0, 1.0)
	## 注：被摧毁的平台格会整个从 `parts` 里消失，所以这个比例只反映**存活格**的平均血量。
	## 因此文案写「存活格均血」而不是「甲板完好度」，避免被误读为“一格没丢”。
	_draw_text("存活格均血 %d%%" % int(roundf(platform_ratio * 100.0)), Vector2(x, info_y + 20.0), 13, _survival_ratio_colour(platform_ratio), true)
	var bar := Rect2(x + 128.0, info_y + 10.0, panel.size.x - 152.0, 8.0)
	draw_rect(bar, Color(Palette.WIRE, 0.30), true)
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * platform_ratio, bar.size.y)), _survival_ratio_colour(platform_ratio), true)
	## ④ 逐模块状态行：按血量比升序，最残的排前面；只列模块与行进机构（平台已汇总）。
	var rows: Array = []
	for part in hull.parts:
		var kind := String(part["kind"])
		if kind == TankBody.KIND_PLATFORM_CELL or kind == TankBody.KIND_PLATFORM_SHAPE:
			continue
		var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
		rows.append({"part": part, "ratio": ratio})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ratio"]) < float(b["ratio"]))
	var row_y := info_y + 42.0
	_draw_text("部件状态", Vector2(x, row_y), 13, Palette.ACCENT_CYAN, false)
	row_y += 6.0
	var shown := mini(rows.size(), MIRROR_ROW_VISIBLE)
	for index in range(shown):
		var entry: Dictionary = rows[index]
		var part: Dictionary = entry["part"]
		var ratio := float(entry["ratio"])
		row_y += MIRROR_ROW_HEIGHT
		var definition := definitions.get_module(String(part["module_id"]))
		var label := String(definition.get("name", String(part["module_id"])))
		if bool(definition.get("core", false)):
			label = "★ " + label
		var colour := _survival_ratio_colour(ratio)
		_draw_text(label.substr(0, 6), Vector2(x, row_y), 12, colour, false)
		var row_bar := Rect2(x + 118.0, row_y - 9.0, panel.size.x - 190.0, 6.0)
		draw_rect(row_bar, Color(Palette.WIRE, 0.28), true)
		draw_rect(Rect2(row_bar.position, Vector2(row_bar.size.x * ratio, row_bar.size.y)), colour, true)
		_draw_text("%d%%" % int(roundf(ratio * 100.0)), Vector2(panel.position.x + panel.size.x - 62.0, row_y), 12, colour, true)
	if rows.size() > shown:
		row_y += MIRROR_ROW_HEIGHT
		_draw_text("…另有 %d 件完好" % (rows.size() - shown), Vector2(x, row_y), 12, Palette.TEXT_LO, false)

## 血量比 → 颜色：>60% 青（完好）、25–60% 琥珀（受损）、<25% 红（濒危）。
func _survival_ratio_colour(ratio: float) -> Color:
	if ratio > 0.6:
		return Palette.ACCENT_CYAN
	if ratio > 0.25:
		return Palette.ACCENT_AMBER
	return Palette.ACCENT_RED

## 把坦克格画进面板：正北朝上、等比缩放并居中；逐格填充透明度随血量降低。
func _draw_survival_mirror_hull(hull: TankBody, area: Rect2) -> void:
	if hull.cells.is_empty():
		return
	var min_local := Vector2(INF, INF)
	var max_local := Vector2(-INF, -INF)
	for entry in hull.cells:
		var local: Vector2 = entry["local"]
		min_local = Vector2(minf(min_local.x, local.x), minf(min_local.y, local.y))
		max_local = Vector2(maxf(max_local.x, local.x), maxf(max_local.y, local.y))
	var cell: float = hull.cell_size()
	## 格中心到格边界的半格外扩，得到真实包围盒。
	min_local -= Vector2(cell, cell) * 0.5
	max_local += Vector2(cell, cell) * 0.5
	var span := max_local - min_local
	if span.x <= 0.0 or span.y <= 0.0:
		return
	var fit := minf(area.size.x / span.x, area.size.y / span.y)
	var origin := area.position + (area.size - span * fit) * 0.5 - min_local * fit
	draw_rect(area, Color(Palette.WIRE, 0.18), false, 1.0)
	for part in hull.parts:
		var ratio := clampf(float(part["hp"]) / maxf(float(part["hp_max"]), 0.001), 0.0, 1.0)
		var colour := _survival_hull_colour(Duel.TAG_PLAYER, part)
		for raw_cell in part["cells"]:
			var cell_value: Vector2i = raw_cell
			var centre_local: Vector2 = (Vector2(cell_value) + Vector2(0.5, 0.5)) * cell
			var at := origin + centre_local * fit
			var box := Rect2(at - Vector2(cell, cell) * 0.5 * fit, Vector2(cell, cell) * fit)
			draw_rect(box, Color(colour, 0.16 + 0.26 * ratio), true)
			draw_rect(box, colour, false, 1.0)
	## 质心十字与朝头箭头：镜像与场上姿态的对应关系靠这两个标记维持。
	var centre_at := origin + (hull.centroid_local) * fit
	draw_line(centre_at + Vector2(-4, 0), centre_at + Vector2(4, 0), Color(Palette.TEXT_HI, 0.7), 1.0)
	draw_line(centre_at + Vector2(0, -4), centre_at + Vector2(0, 4), Color(Palette.TEXT_HI, 0.7), 1.0)
	var nose := origin + (hull.centroid_local + Vector2(cell * 2.0, 0.0)) * fit
	draw_line(centre_at, nose, Color(Palette.ACCENT_CYAN, 0.65), 1.0)

func _survival_card_rect(index: int) -> Rect2:
	var count := 3
	var gap := 40.0
	var total_width := float(count) * SURVIVAL_CARD_WIDTH + float(count - 1) * gap
	var origin_x := DRIVE_VIEW.get_center().x - total_width * 0.5
	return Rect2(origin_x + float(index) * (SURVIVAL_CARD_WIDTH + gap), DRIVE_VIEW.get_center().y - SURVIVAL_CARD_HEIGHT * 0.5, SURVIVAL_CARD_WIDTH, SURVIVAL_CARD_HEIGHT)

func _survival_shop_rect(index: int) -> Rect2:
	var gap := 24.0
	var rows := 2
	var total_width := float(SURVIVAL_SHOP_COLUMNS) * SURVIVAL_SHOP_WIDTH + float(SURVIVAL_SHOP_COLUMNS - 1) * gap
	var total_height := float(rows) * SURVIVAL_SHOP_HEIGHT + float(rows - 1) * gap
	var origin := DRIVE_VIEW.get_center() - Vector2(total_width, total_height) * 0.5
	var column := index % SURVIVAL_SHOP_COLUMNS
	var row := index / SURVIVAL_SHOP_COLUMNS
	return Rect2(origin + Vector2(float(column) * (SURVIVAL_SHOP_WIDTH + gap), float(row) * (SURVIVAL_SHOP_HEIGHT + gap)), Vector2(SURVIVAL_SHOP_WIDTH, SURVIVAL_SHOP_HEIGHT))

func _draw_survival_level_up() -> void:
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.86), true)
	_draw_text("升级 · 三选一（不可跳过）", Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + 52.0), 26, Palette.ACCENT_CYAN, false)
	for index in range(survival.level_choices.size()):
		var entry: Dictionary = survival.level_choices[index]
		var rect := _survival_card_rect(index)
		var kind := String(entry["kind"])
		var accent := Palette.ACCENT_CYAN
		if kind == SurvivalRun.CHOICE_UPGRADE:
			accent = Palette.ACCENT_MAGENTA
		elif kind == SurvivalRun.CHOICE_MASS_CAP:
			accent = Palette.ACCENT_LIME
		draw_rect(rect, Color(Palette.BG_BASE, 0.92), true)
		draw_rect(rect, accent, false, 2.0)
		_draw_text("%d" % (index + 1), rect.position + Vector2(18.0, 40.0), 28, accent, true)
		var kind_label := "新配件"
		if kind == SurvivalRun.CHOICE_UPGRADE:
			kind_label = "改进升级（即刻生效）"
		elif kind == SurvivalRun.CHOICE_MASS_CAP:
			kind_label = "免费质量上限 +1"
		_draw_text(kind_label, rect.position + Vector2(60.0, 34.0), 15, Palette.TEXT_LO, false)
		_draw_text(String(entry["label"]), rect.position + Vector2(60.0, 78.0), 22, Palette.TEXT_HI, false)
		if kind == SurvivalRun.CHOICE_MODULE:
			_draw_text("赠品进入库存，不自动贴装", rect.position + Vector2(18.0, rect.size.y - 40.0), 13, Palette.TEXT_LO, false)
		elif kind == SurvivalRun.CHOICE_MASS_CAP:
			_draw_text("立即提高可承载质量", rect.position + Vector2(18.0, rect.size.y - 40.0), 13, Palette.TEXT_LO, false)
		else:
			_draw_text("注入改装池，波间改装时可用", rect.position + Vector2(18.0, rect.size.y - 40.0), 13, Palette.TEXT_LO, false)
	_draw_text("按 1 / 2 / 3 选择 · M 或点击下方按钮进入改装", Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + DRIVE_VIEW.size.y - 28.0), 16, Palette.TEXT_LO, false)
	_draw_survival_modify_button()

func _draw_survival_shop() -> void:
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.92), true)
	_draw_text("商店 · 第 %d 波通过" % survival.wave, Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + 44.0), 24, Palette.ACCENT_CYAN, false)
	_draw_text("金钱 %d cr · 刷新价 %d cr · 已刷新 %d 次" % [int(roundf(survival.credit)), int(roundf(survival.shop_reroll_cost())), survival.shop_rerolls], Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + 74.0), 15, Palette.ACCENT_LIME, true)
	for index in range(survival.shop_slots.size()):
		var slot: Dictionary = survival.shop_slots[index]
		var rect := _survival_shop_rect(index)
		var sold := bool(slot["sold"])
		var affordable := survival.credit >= float(slot["price"])
		var accent := Palette.ACCENT_CYAN
		if sold:
			accent = Palette.WIRE
		elif not affordable:
			accent = Palette.ACCENT_RED
		draw_rect(rect, Color(Palette.BG_BASE, 0.92), true)
		draw_rect(rect, accent, false, 2.0)
		_draw_text("%d" % (index + 1), rect.position + Vector2(16.0, 34.0), 22, accent, true)
		_draw_text(String(definitions.get_module(String(slot["id"])).get("name", slot["id"])), rect.position + Vector2(50.0, 30.0), 17, Palette.TEXT_HI if not sold else Palette.TEXT_LO, false)
		var price_text := "已售出" if sold else "%d cr" % int(roundf(float(slot["price"])))
		_draw_text(price_text, rect.position + Vector2(50.0, 58.0), 15, accent, true)
		_draw_text(String(slot["id"]), rect.position + Vector2(16.0, rect.size.y - 18.0), 12, Palette.TEXT_LO, true)
	var inventory_y := DRIVE_VIEW.position.y + DRIVE_VIEW.size.y - 118.0
	_draw_text("库存 %d 件（Q / E 选择 · X 出售）" % survival.inventory.size(), Vector2(DRIVE_VIEW.position.x + 32.0, inventory_y), 15, Palette.TEXT_LO, false)
	if not survival.inventory.is_empty():
		var pick := clampi(_survival_sell_index, 0, survival.inventory.size() - 1)
		var module_id := String(survival.inventory[pick])
		var sell_price := float(definitions.get_module(module_id).get("price", 0.0)) * survival.shop_sell_rate()
		_draw_text("%d/%d  %s  →  %d cr" % [pick + 1, survival.inventory.size(), module_id, int(roundf(sell_price))], Vector2(DRIVE_VIEW.position.x + 32.0, inventory_y + 26.0), 16, Palette.ACCENT_AMBER, true)
	_draw_survival_modify_button()
	_draw_text("1–6 购买 · F 刷新 · Q/E 选库存 · X 出售 · M 改装 · Enter 开始下一波 · Esc 返回", Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + DRIVE_VIEW.size.y - 26.0), 15, Palette.TEXT_HI, false)

func _draw_survival_summary() -> void:
	draw_rect(DRIVE_VIEW, Color(Palette.BG_BASE, 0.94), true)
	var panel := Rect2(DRIVE_VIEW.get_center() - Vector2(360.0, 240.0), Vector2(720.0, 480.0))
	draw_rect(panel, Color(Palette.BG_BASE, 0.96), true)
	draw_rect(panel, Palette.ACCENT_MAGENTA, false, 2.0)
	var data: Dictionary = survival.summary()
	_draw_text("RUN SUMMARY", panel.position + Vector2(32.0, 56.0), 28, Palette.ACCENT_MAGENTA, true)
	_draw_text("到达第 %d 波" % int(data["wave_reached"]), panel.position + Vector2(32.0, 112.0), 24, Palette.TEXT_HI, false)
	var rows := [
		"击杀 %d" % int(data["kills"]),
		"摧毁房屋 %d" % int(data["houses"]),
		"碾过残骸 %d" % int(data["debris"]),
		"等级 %d" % int(data["level"]),
		"累计金钱 %d cr" % int(roundf(float(data["credit"]))),
		"累计经验 %d" % int(roundf(float(data["experience"]))),
		"造成伤害 %d" % int(roundf(float(data["damage"]))),
	]
	for index in range(rows.size()):
		_draw_text(String(rows[index]), panel.position + Vector2(32.0, 164.0 + float(index) * 30.0), 17, Palette.TEXT_LO, false)
	## 清零发生在离开本页时（close_run），所以这里只陈述规则，不声称已经清零。
	_draw_text("驾驶舱被毁，run 结束。退出本页后 credit / 经验 / 库存全部清零（不跨局）。", panel.position + Vector2(32.0, panel.size.y - 76.0), 15, Palette.ACCENT_AMBER, false)
	_draw_text("R 重开 · Esc 返回主菜单", panel.position + Vector2(32.0, panel.size.y - 40.0), 16, Palette.TEXT_HI, false)

## 截图专用固定预热：原地持续开火，让画面里同时有：损伤后的敌车、命中闪光、镜像面板。
## 旧版只在第 60 步开一炮，因此截图里看不到任何损伤——用户看到的「没伤害」有一部分
## 就是这种截图造成的印象。**不要在这里踩油门**：全速前撞会在几秒内把自己的炮管撞掉，
## 截图反而会停在「总输出 86」这种让人误以为没伤害的状态。
func _survival_capture_warmup() -> void:
	if not _survival_ready or survival == null or survival.duel == null:
		return
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	_survival_held.clear()
	_survival_apply_input()
	## 步数可用 `--steps=N` 覆盖；不传时仍是 420。
	for step_index in range(_warmup_steps(420)):
		## 只要装填好就开火：420 帧（7 s）能打出十几发，敌方必然掉多件部件，
		## 截图里能同时看到：损伤后的敌车、命中闪光、以及镜像面板里的玩家状态。
		if survival.duel.can_fire(Duel.TAG_PLAYER):
			survival.duel.fire(Duel.TAG_PLAYER)
		_survival_step(step_time)


## 截图钩子：把当前波直接判为通过，落到升级页 / 商店页。
## 用与正式流程相同的入口（_enter_intermission → _open_level_up / _open_shop），
## 不绕过任何阶段约束，因此截图看到的就是真实页面。
func _survival_capture_level_up() -> void:
	if not _survival_ready or survival == null:
		return
	_survival_force_wave_pass()
	## 三选一需要至少一次升级：给足当前级所需经验（_add_xp 会把 pending_level_ups 记上）。
	survival._add_xp(survival.xp_needed_for(survival.level))
	survival._enter_intermission([])
	_survival_event = "升级：选择一项奖励"

func _survival_capture_shop() -> void:
	if not _survival_ready or survival == null:
		return
	_survival_force_wave_pass()
	survival._open_shop()
	## 让商店页有库存可展示（出售行需要非空 inventory）。
	survival.inventory.append("cannon_40")
	survival.inventory.append("shield_cell")
	survival.credit += 240.0
	_survival_event = "第 1 波通过，进入商店"

func _survival_force_wave_pass() -> void:
	survival.wave_passed = true
	survival.wave_time_left = 0.0
	_survival_held.clear()

## 结算页：用真实失败路径（驾驶舱被毁）走到 RUN_SUMMARY，不直接赋 stage。
func _survival_capture_summary() -> void:
	if not _survival_ready or survival == null or survival.duel == null:
		return
	var hull: TankBody = survival.duel.tank_of(Duel.TAG_PLAYER)
	if hull == null:
		return
	var cockpit := -1
	for index in range(hull.parts.size()):
		if String(hull.parts[index]["module_id"]).begins_with("cockpit"):
			cockpit = index
			break
	if cockpit < 0:
		return
	## 先跑几十帧，让结算面板上的击杀/伤害等字段有真实数据。
	var step_time := 1.0 / float(maxi(definitions.global_int("physics_hz", 60), 1))
	for step_index in range(90):
		_survival_step(step_time)
	survival.duel.damage_of(Duel.TAG_PLAYER).apply_part_damage(hull, cockpit, 1.0e9, "destroyed")
	_survival_step(step_time)
	_survival_event = "驾驶舱被摧毁"


## ===== 改装页（design §3.4.2 / §3.4.3 的「改装坦克」入口）=====

## 「改装坦克」按钮：升级页在卡片下方，商店页在标题行右侧。
func _survival_modify_button_rect() -> Rect2:
	if survival != null and survival.stage == SurvivalRun.STAGE_SHOP:
		return Rect2(DRIVE_VIEW.end.x - 320.0, DRIVE_VIEW.position.y + 22.0, 288.0, 46.0)
	return Rect2(DRIVE_VIEW.get_center().x - 150.0, DRIVE_VIEW.end.y - 152.0, 300.0, 52.0)

func _draw_survival_modify_button() -> void:
	var rect := _survival_modify_button_rect()
	draw_rect(rect, Color(Palette.ACCENT_LIME, 0.16 if _hover_survival_button else 0.10), true)
	draw_rect(rect, Palette.ACCENT_LIME, false, 2.0)
	_draw_text("M  改装坦克", rect.position + Vector2(18.0, 32.0), 17, Palette.ACCENT_LIME, false)

## 进入改装：清空编辑器选择状态，光标落到驾驶舱（那里一定是有平台的合法格）。
func _survival_enter_modify() -> void:
	if survival == null or survival_builder == null:
		return
	if not survival.enter_modification():
		_survival_event = "战斗期不能改装"
		queue_redraw()
		return
	_survival_modify_index = 0
	_selected_index = 0
	_option_scroll = 0
	_build_layer = LAYER_MODULE
	_rotation = 0
	_aim = 0
	## 用户要求「坦克要默认在建造区域居中」：整车平移一次（三层一起搬，保持相对位置），
	## 否则起始车贴在 24×24 网格的左上角，右侧与下方大片空白。
	##
	## 为什么现在平移是安全的：`commit_modification()` 的注释已经说明「结构由下一次
	## `start_wave()` 重建 Duel 时生效」——改装期间 `TankBody` 不参与模拟，
	## 所以此刻 `survival_builder` 的格坐标与实际刚体不要求一致。
	## （战斗期绝不能这样搬：那时 `TankBody.parts` 与 builder 必须严格对应。）
	##
	## 平移只改位置、不改尺寸/价格/连通性，所以不需要 undo 记录，也不影响净支出口径。
	survival_builder.center_content()
	var seats: Array[Vector2i] = survival_builder.cockpit_cells()
	_cursor = seats[0] if not seats.is_empty() else Vector2i.ZERO
	_survival_event = "改装：选库存配件后回车贴装"
	_status_message = "改装：1/2/3 选层 · A/D 选件 · 回车贴装 · X 拆解 · Esc 完成"
	_status_error = false
	queue_redraw()

func _survival_leave_modify() -> void:
	if survival == null:
		return
	var spent := survival.modification_cost()
	survival.leave_modification()
	_survival_event = "改装结束：支出 %d cr" % int(roundf(spent))
	queue_redraw()

## 生存页鼠标：先处理本页独有的可点元素（升级卡 / 商品格 / 改装按钮 / 完成改装），
## 其余一律**单向**转发给共享编辑器 `_handle_mouse()`。
##
## v3.16 修的栈溢出就在这里：旧版 `_handle_mouse()` 在 `SCREEN_SURVIVAL` 时会回调本函数，
## 而本函数结尾又调回 `_handle_mouse()`——改装页里任何一次非「完成改装」的点击都会形成
## `_handle_mouse ↔ _handle_survival_mouse` 的无限互调。每层递归都会走一遍
## `_update_hover() → _build_option_index_at() → _option_ids()`，所以栈溢出最终炸在
## `data_registry.get_module()` 里，而不是炸在这两个函数本身。
## 现在方向是单向的：`_input()` → 本函数 → `_handle_mouse()`，**永不回跳**。
func _handle_survival_mouse(event: InputEventMouseButton, position: Vector2) -> void:
	if survival == null:
		return
	var is_wheel := event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN
	## 滚轮与「松开」没有生存页专属语义，必须继续往下走：滚轮给模块列表滚动，
	## 松开给拖拽落笔（矩形/直线铺平台靠它提交）。旧版在这里直接 return，
	## 所以改装页的滚轮与拖动铺一直是哑的。
	if is_wheel or not event.pressed:
		_handle_mouse(event)
		return
	var left := event.button_index == MOUSE_BUTTON_LEFT
	## 升级页：点卡片选奖励（与按 1/2/3 等价）。
	if survival.stage == SurvivalRun.STAGE_LEVEL_UP:
		_update_hover(position)
		if not left:
			return
		if _survival_modify_button_rect().has_point(position):
			_survival_enter_modify()
			return
		for index in range(survival.level_choices.size()):
			if _survival_card_rect(index).has_point(position):
				if survival.take_level_choice(index):
					_survival_event = "已领取升级奖励" if survival.stage != SurvivalRun.STAGE_LEVEL_UP else "又升一级：继续三选一"
					queue_redraw()
				return
		return
	## 商店页：点商品格购买，点「改装坦克」按钮进改装。
	if survival.stage == SurvivalRun.STAGE_SHOP:
		_update_hover(position)
		if not left:
			return
		if _survival_modify_button_rect().has_point(position):
			_survival_enter_modify()
			return
		for index in range(survival.shop_slots.size()):
			if _survival_shop_rect(index).has_point(position):
				if survival.buy_shop_slot(index):
					_survival_event = "已购买第 %d 件商品" % (index + 1)
				else:
					_survival_event = "无法购买：已售出或信用点不足"
				queue_redraw()
				return
		return
	## 改装阶段：「完成改装」按钮。
	if _in_modify_mode() and left and _modify_leave_button_rect().has_point(position):
		_survival_leave_modify()
		return
	## 其余（网格点击/拖拽、模块目录、工具按钮、层选择、列表滚动）全部复用建造页实现。
	_handle_mouse(event)


## 改装页只画建造页没有的东西：标题条、支出读数与「退出改装」按钮。
## 网格 / 模块目录 / 属性校验 / 底部工具全部来自 `_draw_build()`，
## 所以改装页与主菜单建造页永远是同一套编辑器和同一套布局。
func _draw_modify_overlay() -> void:
	if survival == null or survival_builder == null:
		return
	## 只补建造页没有的三项：支出/金钱/库存读数与「完成改装」按钮。
	## 标题与副标题由 `_draw_build()` 在改装模式下自己画，不在这里重复。
	var y := 40.0
	_draw_text("支出 %d cr" % int(roundf(survival.modification_cost())), Vector2(760, y), 15, Palette.ACCENT_AMBER, true)
	_draw_text("金钱 %d cr" % int(roundf(survival.credit)), Vector2(980, y), 15, Palette.ACCENT_LIME, true)
	_draw_text("库存 %d 件" % survival.inventory.size(), Vector2(1180, y), 15, Palette.TEXT_LO, true)
	## 退出按钮：与 Esc 等价，回到进入改装前的阶段（LEVEL_UP 或 SHOP）。
	var button := _modify_leave_button_rect()
	var hovered := _hover_modify_button
	draw_rect(button, Color(Palette.ACCENT_LIME, 0.14 if hovered else 0.06), true)
	draw_rect(button, Palette.ACCENT_LIME, false, 2.0)
	_draw_text("完成改装  Esc", button.position + Vector2(14, 26), 15, Palette.ACCENT_LIME, false)

## 截图钩子：走与正式流程相同的入口（_open_shop → enter_modification），不直接赋 stage。
func _survival_capture_modify() -> void:
	if not _survival_ready or survival == null or survival_builder == null:
		return
	_survival_force_wave_pass()
	survival._open_shop()
	survival.inventory.append("cannon_40")
	survival.inventory.append("shield_cell")
	survival.inventory.append("track_heavy")
	survival.credit += 600.0
	_survival_enter_modify()
	## 先给车体旁边铺一格平台，预览才有合法落点。
	## **不能写死格坐标**：v3.18 起坦克会先被居中，`(6,0)` 已经不在车体旁，
	## 连通性检查会拒绝铺格，光标就停在一个空地上、预览变成红色非法。
	## 改为从真实包围盒算：取右下角再向右一格。
	var bounds: Rect2i = survival_builder.content_bounds()
	var extra := Vector2i(bounds.end.x, bounds.position.y)
	if not survival_builder.platform_cells.has(extra):
		survival.place_platform_at(extra)
	_cursor = extra
	_survival_modify_index = 0
	_build_layer = LAYER_MODULE
	_survival_event = "改装：选库存配件后回车贴装"
