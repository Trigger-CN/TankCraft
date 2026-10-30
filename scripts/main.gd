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
## v3.22：战斗视图（竞技场 / 障碍 / 中立物 / 弹道 / 动效 / 命中闪光 / 伤害数字）
## 抽成独立类，对局页与生存页共用同一份实现；模式差异由参数表达，不再各写一份。
const CombatView := preload("res://scripts/combat_view.gd")
## v3.35：管道几何与弹道内行进（建造/改装页与三个战斗页共用同一份）。
## 与 `CombatView` 同样全部 static、零状态、零 preload 回本文件。
const PipeView := preload("res://scripts/pipe_view.gd")
## v3.37：炮管几何与绘制（建造/改装页与三个战斗页共用同一份，全静态）。
const CannonView := preload("res://scripts/cannon_view.gd")

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
## v3.24 端口箭头（改装/建造 UI）：表示**物料流向**，与 `_draw_aim_line()` 的**弹道方向**是两件事。
## 输入用冷色（cyan）指向模块内部，输出用暖色（amber）背离模块；两者都短（13 px）且只沿四正交方向。
## 炮管同时有 in0 与 aim：如果画成同一种箭头，玩家会以为可以从炮口装弹。
const PORT_ARROW_LEN := 13.0
const PORT_ARROW_WIDTH := 2.0
const PORT_ARROW_WING := 5.0
const PORT_ARROW_WING_ANGLE := 0.6
## v3.25 鼠标瞄准：准星环的半径与线宽。与端口箭头（物料流向）、`_draw_aim_line`（弹道方向）
## 三个概念互不相干，但都是「短小几何图形」，所以用「空心圆环 + 十字」这种唯一可辨的形状。
const AIM_RETICLE_RADIUS := 9.0
const AIM_RETICLE_WIDTH := 1.5
const AIM_RETICLE_CROSS := 5.0
## v3.37：战斗页炮管的绘制不透明度。炮管是**实体**而不是格子的填充色块，所以用固定高不透明度，
## 让管形在任何缩放与任何队伍色下都读得出来；血量状态由部件主色（`hull_damage_colour`）表达，
## 不再让透明度也参与表达 —— 否则被打残的炮管会直接看不见。
const CANNON_BATTLE_ALPHA := 0.9
## v3.38：战斗场景鼠标滚轮缩放。
##
## `zoom` 是相机的**倍数**，不是像素比例：最终传给 `to_screen` 的比例是 `fit_scale(view, camera)`，
## 而 `camera.size = arena.size / zoom` 会自动把基准比例抬到 `fit * zoom`。
## 所以 `zoom == 1.0` 时的 `camera` **就是 `arena` 本身**（`camera_rect()` 直接返回入参，不做乘除），
## 默认像素与 v3.37 逐字相同。
##
## 范围 0.5–4.0：
##   0.5 —— 视野 2 倍宽（4096 世界像素 > 竞技场宽 2048），整张地图缩到中间、四周留背景网格，
##           这是「退远看全貌」的上限；再往外就只剩空白了。
##   4.0 —— 一格从 9.5 屏幕像素变成 38 px，6×4 的车 228×152 px，接近建造页（32 px 格）的可读度，
##           这是「清楚看到坦克细节」的下限；再往里 HUD 相对比例就失调了。
const CAMERA_ZOOM_MIN := 0.5
const CAMERA_ZOOM_MAX := 4.0
## 每格滚轮乘/除的倍数。从 0.5 到 4.0 恰好 log(8)/log(1.15) ≈ 14.6 格，
## 手感连续又不至于「滚半天还没放大」。
const CAMERA_ZOOM_STEP := 1.15
## 相机跟随玩家车的平滑系数（每秒）。焦点用 `1 - exp(-k·dt)` 插值，
## 与帧率无关；`dt` 走固定步长累加的 `_time`，不用 `randf`、不依赖引擎 delta。
const CAMERA_FOCUS_FOLLOW := 9.0

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
## v3.24：改装页「待装进改进器」的升级候选下标（`_upgrade_ids()` 的下标）。
## 玩家用 Q/E 在改进器上切换候选、T 追加到下一个空槽、Shift+T 清空。
var _upgrade_pick_index := 0
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
## `--cursor=x,y`：把设计坐标下的鼠标位置钉到指定点，供截图探针验证准星绘制（v3.25）。
## 不加这个参数时保持 `_mouse_position` 原值，**历史基线截图逐字节不变**。
var _capture_cursor := Vector2.INF
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
## v3.23：试驾页的炮口闪光与消散（多实例；与另两页共用同一套推进/绘制）。
var _drive_muzzles: Array = []
var _drive_expires: Array = []
## v3.33：命中闪光。与对局页 / 生存页同一套（`CombatView.draw_hit_flash`），
## 之前试驾页完全没有这一层——打中了屏幕上除了弹坑什么都没有。
var _drive_hit_flash_at := Vector2.ZERO
var _drive_hit_flash_left := 0.0
## v3.38：战斗场景鼠标滚轮缩放状态。**三个页共一份** —— 同一时刻只在一个战斗页上，
## 但切页时必须复位，否则上一页的放大倍数会带到下一页（也会让截图基线不可复现）。
var _camera_zoom := 1.0
## 相机焦点的**当前值**与**目标值**（世界坐标）。目标 = 玩家车中心；
## 当前值每帧向目标插值，避免坦克一动镜头就硬跳。
## `zoom == 1.0` 时焦点不是 `arena` 中心，`_battle_camera()` 会直接返回 `arena`，
## 所以这两个值在不缩放时对像素零影响。
var _camera_focus := Vector2.ZERO
var _camera_focus_ready := false
## 调试辅助：打开后车体按**模块种类**上色（试驾页 v3.33 之前的旧配色）。
## 默认关：三页统一走「驾驶舱琥珀 / 其余队伍色 + 血量分档」这一条唯一规则。
## 否则同一个模块在三个页面上是三种颜色，玩家学到的「红 = 快坏了」在试驾页不成立。
var _drive_kind_highlight := false
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
var _match_hit_flash_at := Vector2.ZERO
var _match_hit_flash_left := 0.0
## v3.23：炮口闪光与射程耗尽消散。都是**多实例**的（一次齐射会有多门炮、一轮弹幕会有
## 多发弹同时消散），所以用「数组 + 逐项倒计时」而不是像命中闪光那样只存最新一个。
## 为什么不用 FxLayer：这两个特效需要「方向」与「所属队伍」两个额外字段，
## 而 FxLayer 的公共字段集是给通用圆环用的；把方向塞进去会弄脏所有旧调用点。
var _match_muzzles: Array = []
var _match_expires: Array = []
## v3.36：被管道占据的格（局部格坐标）。`_network_pipe_hook()` 每帧重建一次，
## `_draw_hull_shared()` 用它给平台层「不描边」—— 否则平台格的方框会横跨在管身上，
## 把一根连续的管切成一段一段，看上去就是接缝。
var _pipe_covered_cells: Dictionary = {}
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

	## v3.38：相机焦点必须在**推进模拟之后**才更新 —— 目标取的是玩家车的新位置，
	## 提前更新会让镜头比车晚一帧。顺序：simulate → camera_follow → sync_pointer。
	_camera_follow(delta)
	## v3.26：战斗页每帧把准星与炮口同步到真实光标。
	## 不能只依赖 `InputEventMouseMotion`——切页后不动鼠标、或坦克行驶而鼠标静止时，
	## 矄准都会停在上一个状态（详见 `_sync_battle_pointer()`）。
	## v3.38：它现在必须在 `_camera_follow()` **之后**，因为缩放后同一个屏幕点
	## 对应的世界点取决于相机焦点；先同步就会用上一帧的焦点瞄一次。
	_sync_battle_pointer()

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
		## v3.25：战斗页把鼠标当作**瞄准器**——移动即转向炮口。三页共用 `_aim_player_cannons()`，
		## 只在战场区矩形内生效，鼠标飘到 HUD 上时不会把炮口拉向面板边缘。
		if _screen == SCREEN_SURVIVAL or _screen == SCREEN_MATCH or _screen == SCREEN_DRIVE:
			if _aim_with_mouse(design_position):
				queue_redraw()
		return
	if event is InputEventMouseButton:
		var button_event: InputEventMouseButton = event as InputEventMouseButton
		## v3.38：战斗页滚轮 = 相机缩放。**必须放在所有分流之前**：
		## 滚轮本来有「模块列表滚动」语义，而生存页的 `_handle_survival_mouse()` 会把滚轮
		## 继续下传给 `_handle_mouse()`（v3.18 修过：不下传则改装页列表不能滚）。
		## 用 `_is_battle_screen()` 限定，所以在改装页 / 升级页 / 商店页上滚轮仍旧滚列表 ——
		## 那些阶段 `_is_battle_screen()` 为 false，根本不会进这个分支。
		if button_event.pressed and _is_battle_screen():
			if button_event.button_index == MOUSE_BUTTON_WHEEL_UP:
				_camera_zoom_by(CAMERA_ZOOM_STEP)
				return
			if button_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_camera_zoom_by(1.0 / CAMERA_ZOOM_STEP)
				return
		## v3.25：战斗页左键 = 开火。放在分流之前，因为生存页的 `_handle_survival_mouse()`
		## 只处理升级卡 / 商品格 / 改装按钮，战斗期会把左键转发给 `_handle_mouse()` 然后早退。
		## 这里先截下战斗页左键，避免「点了没反应」。
		if button_event.pressed and button_event.button_index == MOUSE_BUTTON_LEFT:
			if _is_battle_screen():
				## 先瞄准再开火：同一帧内点下去时，炮口必须指向点击处而不是上一个鼠标位置。
				var click_position := _design_position(button_event.position)
				_aim_with_mouse(click_position)
				_fire_battle_player(click_position)
				return
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
	## v3.38：切页必须把相机退回默认。否则上一页的放大倍数会带到下一页，
	## 也会让同一组 `--capture` 参数因为上一次操作残留而拍出不同画面。
	_camera_zoom = 1.0
	_camera_focus_ready = false
	_camera_focus = Vector2.ZERO

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
	elif key == KEY_T and event.shift_pressed:
		_set_status(_clear_cursor_modifier())
	elif key == KEY_T:
		_set_status(_append_upgrade_to_cursor_modifier())
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
		if not selected_part.is_empty():
			var part: Dictionary = selected_part["part"]
			if String(part["id"]).begins_with("cannon_"):
				_set_status(_editor_model().adjust_aim(_cursor, step))
				return
			## v3.24：光标下是改进装置时，Q/E 改为切换「待装升级」候选。
			## 只在改装期开：建造期还没有升级可装，给一个空候选只会让人困惑。
			var def: Dictionary = definitions.get_module(String(part["id"]))
			if _in_modify_mode() and def.has("upgrade_slots"):
				var ids: PackedStringArray = _upgrade_ids()
				if ids.is_empty():
					_set_status("没有可用的升级类型。")
					return
				_upgrade_pick_index = posmod(_upgrade_pick_index + step, ids.size())
				var pick := String(ids[_upgrade_pick_index])
				var upgrade_def: Dictionary = definitions.registry.get_upgrade(pick)
				_set_status("待装升级：%s · T 装入 / Shift+T 清空" % String(upgrade_def.get("name", pick)))
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

## v3.24：可选升级类型（按 id 排序，保证确定性）。
## 改装页给改进器选槽时用它；不依赖 `collected_upgrades`，因为数据表就是权威清单。
func _upgrade_ids() -> PackedStringArray:
	var ids := PackedStringArray()
	if definitions == null or definitions.registry == null:
		return ids
	for raw_id in definitions.registry.upgrades.keys():
		ids.append(String(raw_id))
	ids.sort()
	return ids

## v3.24：把「待装升级」追加到光标下改进装置的下一个空槽。
##
## 为什么用 `GridBuilder.set_modifier_upgrades()` 而不是直接改 part：
## 那个入口带 `_push_undo()` 与同一套槽数 / stack_limit 校验，
## 所以这里不需要（也不应该）再写一遍规则。
func _append_upgrade_to_cursor_modifier() -> String:
	if not _in_modify_mode() or survival == null:
		return "建造期不能配置改进槽。"
	if _build_layer != LAYER_MODULE:
		return "切到功能模块层再配置改进槽。"
	var hit: Dictionary = _editor_model().part_at(LAYER_MODULE, _cursor)
	if hit.is_empty():
		return "光标下没有功能模块。"
	var part: Dictionary = hit["part"]
	var def: Dictionary = definitions.get_module(String(part["id"]))
	if not def.has("upgrade_slots"):
		return "光标下的模块不是改进装置。"
	var ids: PackedStringArray = _upgrade_ids()
	if ids.is_empty():
		return "数据里没有升级类型。"
	var pick := String(ids[clampi(_upgrade_pick_index, 0, ids.size() - 1)])
	var current: Array = (part.get("upgrades", []) as Array).duplicate()
	current.append(pick)
	var reason: String = _editor_model().set_modifier_upgrades(_cursor, current)
	if not reason.is_empty():
		return reason
	var name := String(definitions.registry.get_upgrade(pick).get("name", pick))
	return "改进器已加槽：%s（%d/%d）" % [name, current.size(), int(def.get("upgrade_slots", 1))]

## v3.24：清空光标下改进装置的所有槽（同样走 `_push_undo()`）。
func _clear_cursor_modifier() -> String:
	if not _in_modify_mode():
		return "建造期不能配置改进槽。"
	if _build_layer != LAYER_MODULE:
		return "切到功能模块层再配置改进槽。"
	var hit: Dictionary = _editor_model().part_at(LAYER_MODULE, _cursor)
	if hit.is_empty():
		return "光标下没有功能模块。"
	var part: Dictionary = hit["part"]
	var def: Dictionary = definitions.get_module(String(part["id"]))
	if not def.has("upgrade_slots"):
		return "光标下的模块不是改进装置。"
	var reason: String = _editor_model().set_modifier_upgrades(_cursor, [])
	if not reason.is_empty():
		return reason
	return "已清空改进器槽配置。"

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
	_status_message = "对战：W/S 油门 · A/D 转向 · 鼠标瞄准 · 左键开火（空格备选） · Esc 返回 · R 重开"
	queue_redraw()

func _exit_match() -> void:
	_match_held.clear()
	## v3.25：退出战斗时清掉鼠标瞄准覆盖，否则「上一局鼠标停在哪里」会跟着下一局的车走。
	if match_session != null:
		var player_bank := match_session.duel.bank_of(Duel.TAG_PLAYER)
		if player_bank != null:
			player_bank.clear_aim_override()
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
	## v3.38：Z 一键把相机退回 1.0（与试驾页 / 生存页一致）。
	if key == KEY_Z:
		if pressed:
			_camera_reset_zoom()
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
			## 悬浮数字与命中闪光：与生存页同一套（`CombatView.push_damage` / `draw_hit_flash`）。
			## 坐标是竞技场世界坐标，组件统一按 `view.position + (pos - arena.position) * scale` 转换。
			var at := Vector2(battle_event.get("pos", Vector2.ZERO))
			var dealt := float(battle_event.get("damage", 0.0))
			var absorbed := float(battle_event.get("shield", 0.0))
			var victim := String(battle_event.get("tag", ""))
			## 命中闪光也在页面层置位，与生存页一样画在自己那张图的坐标系里。
			_match_hit_flash_at = at
			_match_hit_flash_left = CombatView.HIT_FLASH_TIME
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
		elif kind == "muzzle":
			## 炮口闪光：位置/方向取自 `Duel.fire()` 的真实发射结果，不重新算炮口。
			var muzzle_at := Vector2(battle_event.get("pos", Vector2.ZERO))
			var muzzle_colour := Palette.ACCENT_CYAN if String(battle_event.get("tag", "")) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
			_match_muzzles.append({
				"pos": muzzle_at,
				"dir": Vector2(battle_event.get("dir", Vector2.RIGHT)),
				"colour": muzzle_colour,
				"left": CombatView.MUZZLE_FLASH_TIME,
			})
			## 同侧限流：多炮齐射时不要堆成一团（与伤害数字同一思路）。
			while _match_muzzles.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
				_match_muzzles.remove_at(0)
		elif kind == "expire":
			## 射程耗尽消散：与「打中了」必须能一眼区分（形状/时长/运动方向都不同）。
			var expire_at := Vector2(battle_event.get("pos", Vector2.ZERO))
			var expire_colour := Palette.ACCENT_CYAN if String(battle_event.get("shooter", "")) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
			_match_expires.append({
				"pos": expire_at,
				"colour": expire_colour,
				"left": CombatView.EXPIRE_FLASH_TIME,
			})
			_match_event = "炮弹飞满射程消散"
			while _match_expires.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
				_match_expires.remove_at(0)
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

## 对局页的伤害悬浮数字：实际逻辑已收归 `CombatView.push_damage()`（两页同一份）。
## 页面只负责指定自己的动效层实例，符号语义与限流全在组件里。
func _push_match_damage(at: Vector2, amount: float, colour: Color, mode: String) -> void:
	CombatView.push_damage(_match_fx, at, amount, colour, mode)

## 对局页动效倒计时：只在 `_match_step` 的固定步长里累减。
## 递减逻辑已收归 `FxLayer.step()`（v3.11）——三页共用一份，不会再出现「调错 tick 对象」。
## 命中闪光、炮口闪光与消散同样在固定步长内倒计时，绝不放 `_process`。
func _match_tick_fx(step_time: float) -> void:
	if _match_hit_flash_left > 0.0:
		_match_hit_flash_left = maxf(_match_hit_flash_left - step_time, 0.0)
	_match_fx.step(step_time)
	_advance_timed(_match_muzzles, step_time)
	_advance_timed(_match_expires, step_time)

## 通用「带剩余时间的瞬时特效列表」推进器。
##
## 为什么不塞进 `FxLayer`：`FxLayer.entries` 的字段集（kind / pos / radius / colour / left / life / text）
## 是三个页面共用的通用模型；炮口闪光需要 `dir` 与 `colour`、消散需要 `colour`，而它们都**不需要**
## `radius` / `text`。为了两种特效给公共模型加三个字段，会把所有旧调用点都卷进来。
## 这里只维护「`left` 递减、过期丢弃」这一件共同的事，字段由各自定义。
func _advance_timed(entries: Array, step_time: float) -> void:
	if entries.is_empty():
		return
	var kept: Array = []
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		entry["left"] = float(entry["left"]) - step_time
		if float(entry["left"]) > 0.0:
			kept.append(entry)
	entries.clear()
	entries.append_array(kept)

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
	## M5：战斗结算实例；护盾表按部件重建。v3.24：升级载荷随弹药走，不再整台聚合。
	damage = DamageSystem.new()
	damage.setup(definitions)
	damage.rebuild(tank, builder)
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
	_drive_hit_flash_at = Vector2.ZERO
	_drive_hit_flash_left = 0.0
	_drive_ready = true
	_set_screen(SCREEN_DRIVE)
	_status_error = false
	_status_message = "试驾：W/S 油门 · A/D 转向 · 鼠标瞄准 · 左键开火（空格备选） · R 重开 · Esc 返回"
	if tank.parts_of_kind(TankBody.KIND_MOBILITY).size() < 2:
		_status_message += "　（行进机构少于 2 组，design §5.2 会持续偏转）"
	queue_redraw()

func _exit_drive() -> void:
	_drive_held.clear()
	## v3.25：清掉鼠标瞄准覆盖，回到建造期 `aim` 语义。
	bank.clear_aim_override()
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
	if key == KEY_K:
		if pressed:
			_drive_kind_highlight = not _drive_kind_highlight
			_drive_last_event = "种类高亮：开" if _drive_kind_highlight else "种类高亮：关"
			queue_redraw()
		return
	## v3.38：Z 一键把相机退回 1.0。`R` 已被「重开」占用，所以另开一键；
	## 不用滚轮反滚十几格才能回到默认。
	if key == KEY_Z:
		if pressed:
			_camera_reset_zoom()
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
	## v3.33：撞墙 / 撞障碍的伤害是试驾页**唯一可达**的自伤来源，悬浮数字就补在这里。
	## 两个函数都返回「本次调用累计的伤害」，所以不需要再自己算一遍公式。
	var wall_damage := tank.apply_obstacles(_drive_obstacles)
	wall_damage += tank.apply_boundary(_drive_arena)
	if wall_damage > 0.0 and not tank.parts.is_empty():
		## 撞击点取「离车心最远的那一格」：`_apply_impact_damage()` 打的就是最贴近撞击面的部件，
		## 但那里没有回传具体是哪一件，所以这里取几何上最外侧的格作为数字落点。
		var impact_at := tank.position
		var furthest := -INF
		for part in tank.parts:
			var part_at := tank.world_position_of_part(part)
			var reach := part_at.distance_squared_to(tank.position)
			if reach > furthest:
				furthest = reach
				impact_at = part_at
		_drive_hit_flash_at = impact_at
		_drive_hit_flash_left = CombatView.HIT_FLASH_TIME
		_drive_push_damage(impact_at, wall_damage, Palette.ACCENT_RED, "received")
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
		## v3.23：试驾页的炮口闪光（这条路径绕过 Duel，所以要自己收集）。
		## 消散不在这里处理：`_drive_record_event()` 已经把 reason=range 写成「超出射程」，
		## 而特效状态统一在下面按同一份事件推入。
		_consume_combat_particles(event)
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
			var upgrades: Array = (shot.get("upgrades", []) as Array).duplicate()
			field.spawn(Vector2(shot["origin"]), Vector2(shot["dir"]), String(shot["ammo_id"]), "player", upgrades)
			tank.apply_recoil(float(shot["recoil_px"]), Vector2(shot["dir"]), Vector2(shot["world_r"]))
			## 试驾页不经过 `Duel.fire()`，所以炮口特效要在这里自己收。
			_consume_combat_particles({
				"kind": "muzzle",
				"tag": "player",
				"pos": Vector2(shot["origin"]),
				"dir": Vector2(shot["dir"]),
			})
	if fired == 0:
		_set_status("炮管还在装填，或当前蓝图没有炮管。")
		return
	_set_status("开火：%d 发离膛。" % fired)

## 试驾页的炮口/消散事件收集器。
##
## 为什么单独写一份而不直接复用另两页的分支：三个页面的**状态存放位置不同**
## （`_drive_*` / `_match_*` / `_survival_*` 三组变量），而 GDScript 没有引用传递的
## 字段名。真正该共用的是**绘制与推进**（已收归 `CombatView` 与 `_advance_timed`），
## 这里只剩「把两个字段塞进哪个数组」这行赋值，重复它比引入一套间接层便宜。
func _consume_combat_particles(event: Dictionary) -> void:
	var kind := String(event.get("kind", ""))
	if kind == "muzzle":
		_drive_muzzles.append({
			"pos": Vector2(event.get("pos", Vector2.ZERO)),
			"dir": Vector2(event.get("dir", Vector2.RIGHT)),
			"colour": Palette.ACCENT_CYAN,
			"left": CombatView.MUZZLE_FLASH_TIME,
		})
		while _drive_muzzles.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
			_drive_muzzles.remove_at(0)
	elif kind == "expire":
		_drive_expires.append({
			"pos": Vector2(event.get("pos", Vector2.ZERO)),
			"colour": Palette.ACCENT_CYAN,
			"left": CombatView.EXPIRE_FLASH_TIME,
		})
		while _drive_expires.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
			_drive_expires.remove_at(0)

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
	var at := Vector2(event.get("pos", Vector2.ZERO))
	var result := damage.apply_hit(
		tank,
		Vector2i(event.get("cell", Vector2i.ZERO)),
		part_index,
		String(event.get("ammo_id", "")),
		upgrades,
		Vector2(event.get("normal", Vector2.ZERO)),
		float(event.get("damage_scale", 1.0))
	)
	## 注意：试驾页的弹丸**永远打不到自己**（`ProjectileField._sweep()` 会排除射手自己的 tag，
	## 而这里的发射方恒为 "player"），所以这条分支在当前沙盒里不可达。
	## 试驾页真正的自伤来源是撞墙 / 撞障碍与殉爆，伤害数字放在那两处（见 `_drive_step`）。
	return

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
	var upgrades: Array = (event.get("upgrades", []) as Array).duplicate()
	for index in range(count):
		var offset := (float(index) - float(count - 1) * 0.5) * 0.35
		var child_dir := direction.rotated(offset)
		field.spawn(origin + child_dir * 6.0, child_dir, ammo_id, "player", upgrades, base_scale * scale)
	_drive_last_event = "弹丸分裂 ×%d" % count

func _push_drive_fx(kind: String, at: Vector2, radius: float, colour: Color, life: float) -> void:
	_drive_fx.push(kind, at, radius, colour, life)

## 动效倒计时在固定步长里累减，保持确定性（绝不放 _process，绝不用 randf）。
func _drive_tick_fx(step_time: float) -> void:
	if _drive_hit_flash_left > 0.0:
		_drive_hit_flash_left = maxf(_drive_hit_flash_left - step_time, 0.0)
	_drive_fx.step(step_time)
	_advance_timed(_drive_muzzles, step_time)
	_advance_timed(_drive_expires, step_time)

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

## ===== 三页共用的战斗 HUD 骨架（v3.33） =====
##
## 只统一**排版**，不统一内容：各模式仍然自己决定写什么、写几个值。
## 驾驶页是物理调试页（质量 / 惯量 / 推力），生存页带肉鸽进度（波次 / 金钱 / 等级），
## 所以 HUD 内容不同是**合理的**，不该被拉平；但「小标签 + 大标题」两行的字号与间距、
## 以及底部状态条的框与内边距，三页没有理由各不相同。
##
## 坐标由调用方传入而不是写死：试驾页标题在 (48,62)/(48,106)，另两页在 (left,120)/(left,152)，
## 这是各页的既有布局，写死任何一套都会改掉另两页的像素。
func _draw_battle_header(eyebrow: String, eyebrow_colour: Color, eyebrow_at: Vector2, eyebrow_size: int, title: String, title_at: Vector2, title_size: int) -> void:
	_draw_text(eyebrow, eyebrow_at, eyebrow_size, eyebrow_colour, true)
	_draw_text(title, title_at, title_size, Palette.TEXT_HI, false)

## 底部状态条。三页的框、边框与文字内边距完全一致，只有文字与强调色不同。
## `highlight` 是对局页「对局结束」用的强调版：更深的底、更粗的背光、更大的字。
func _draw_battle_status(text: String, text_colour: Color = Palette.TEXT_HI, highlight: bool = false) -> void:
	if highlight:
		draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.92), true)
		draw_rect(DRIVE_STATUS, Palette.ACCENT_CYAN, false, 2.0)
		_draw_text(text, DRIVE_STATUS.position + Vector2(20.0, 44.0), 20, text_colour, false)
		return
	draw_rect(DRIVE_STATUS, Color(Palette.BG_BASE, 0.86), true)
	draw_rect(DRIVE_STATUS, Color(Palette.WIRE, 0.55), false, 1.0)
	_draw_text(text, DRIVE_STATUS.position + Vector2(20.0, 42.0), 16, text_colour, false)

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
	## 被管道压住的格：平台/行进的方框不再描边（见 `_draw_cell` 的 `outlined`）。
	var pipe_cells := _editor_pipe_cells()
	for raw_cell in _editor_model().platform_cells.keys():
		var cell: Vector2i = raw_cell
		_draw_cell(cell, Palette.WIRE, "", false, platform_alpha, not pipe_cells.has(cell))
	for shape in _editor_model().platform_shapes:
		var definition: Dictionary = definitions.get_module(String(shape["id"]))
		for cell in _editor_model().part_cells(shape):
			_draw_cell(cell, Palette.WIRE, _module_glyph(String(definition.get("name", "板"))), false, platform_alpha, not pipe_cells.has(cell))
	for part in _editor_model().mobility_parts:
		var definition: Dictionary = definitions.get_module(String(part["id"]))
		for cell in _editor_model().part_cells(part):
			_draw_cell(cell, Palette.ACCENT_CYAN, _module_glyph(String(definition.get("name", "行"))), false, mobility_alpha, not pipe_cells.has(cell))
	## v3.35：先把全车端口登记一次，管道才能知道“哪一侧真的有邻居” —— 只有没接上
	## 的那一侧才画端帽，接上的那一侧不画，两节管子于是看起来是同一根。
	var occupancy := _editor_pipe_occupancy()
	var pipe_phase := fposmod(_time * PipeView.PIPE_FLOW_SPEED, TAU)
	for part in _editor_model().module_parts:
		var definition: Dictionary = definitions.get_module(String(part["id"]))
		var is_core: bool = bool(definition.get("core", false))
		var color: Color = Palette.ACCENT_CYAN if is_core else Palette.ACCENT_AMBER
		var module_id := String(part["id"])
		var cells: Array[Vector2i] = _editor_model().part_cells(part)
		if PipeView.has_shape(module_id):
			## 管道不再画成方块：方块会把内部抽成“填充色块”，看不见管子。
			## 但保留一个很淡的格底，否则非选中层降 alpha 时管道会彻底消失。
			for cell in cells:
				draw_rect(_cell_rect(cell), Color(color, 0.06 * module_alpha), true)
			var specs := AmmoNetwork.ui_ports(module_id, definition, int(part.get("rot", 0)))
			var connected := PipeView.connected_sides(cells, specs, occupancy)
			## **`offset` 必须传 `GRID_ORIGIN`**：`PipeView` 只认「格坐标 × cell」，而建造/改装页的
			## 网格是画在 `GRID_ORIGIN` 处的。漏了这个平移，管道会被画到画布左上角——
			## 而端口箭头走 `_cell_rect()`（已经含原点）就留在原地，于是画面里只剩箭头不见管子。
			PipeView.draw_pipe(self, module_id, cells, specs, GRID_CELL, color, module_alpha,
				1.0, connected, 0.5 + 0.5 * sin(pipe_phase), GRID_ORIGIN)
		else:
			## v3.37：炮管不再画成方块 + 汉字，而是画出基座 / 管身 / 炮口。
			## **`offset` 必须传 `GRID_ORIGIN`** —— 与管道同一条纪律（v3.36 的漏传教训）：
			## `CannonView` 只认「格坐标 × cell」，而建造/改装页的网格画在 `GRID_ORIGIN` 处；
			## 漏了这个平移，炮管会被画到画布左上角，而端口箭头走 `_cell_rect()`（已含原点）留在原地。
			## 方向取**建造期 `aim`**：那本来就是相对车体的角度，已经是局部的，不需要再减任何东西。
			if CannonView.is_cannon(definition):
				CannonView.draw_cannon(self, cells, deg_to_rad(float(part.get("aim", 0))),
					GRID_CELL, color, module_alpha, 1.0, GRID_ORIGIN)
			else:
				for cell in cells:
					_draw_cell(cell, color, _module_glyph(String(definition.get("name", "模"))), is_core, module_alpha)
		## v3.24：所有带端口的模块都要标出物料进出方向（用户：「不只是升级效果模块，
		## 其他所有有输出或者有输入的模块都要显示箭头，方便规划流水线」）。
		## 放在 `_draw_cell` 循环之后、`_draw_aim_line` 之前：箭头贴着格子边缘，
		## 而瞄准线从首格中心向外延伸，两者在几何上就不会混在一起。
		_draw_port_arrows(part, definition, module_alpha)
		## v3.37：判据与 `CannonView.is_cannon()` 同源（`aim_steps`），不再按 id 前缀 ——
		## 前缀判据在「炮管改名」或「新增以 cannon_ 开头的非炮管」时会静默失准。
		if CannonView.is_cannon(definition):
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

## 建造/改装页的端口占位表：`{cell: {side: true}}`。
##
## 只登记**模块层**（只有模块层带端口）。平台与行进机构没有端口，不参与。
## 每项用 `AmmoNetwork.ui_ports()` 取已旋转的端口表 —— 不在这里再判一次角色，
## 否则 UI 与仿真各有一套端口推导，迟早会对不上。
func _editor_pipe_occupancy() -> Dictionary:
	var entries: Array = []
	for part in _editor_model().module_parts:
		var module_id := String(part["id"])
		var definition: Dictionary = definitions.get_module(module_id)
		var specs := AmmoNetwork.ui_ports(module_id, definition, int(part.get("rot", 0)))
		if specs.is_empty():
			continue
		entries.append({"cells": _editor_model().part_cells(part), "ports": specs})
	return PipeView.occupancy(entries)

## 建造/改装页的「被管道压住的格」集合，供平台层/行进层跳过描边。
## 只算真能画出管道的模块（`PipeView.has_shape`），否则会把普通模块下方的平台也去掉框。
func _editor_pipe_cells() -> Dictionary:
	var result: Dictionary = {}
	for part in _editor_model().module_parts:
		if not PipeView.has_shape(String(part["id"])):
			continue
		for cell in _editor_model().part_cells(part):
			result[cell] = true
	return result


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

## 端口箭头：把 `AmmoNetwork.ui_ports()` 给出的每个端口画成一个小箭头。
##
## 为什么必须有它：改装/建造页此前只画炮管的瞄准线，玩家看不出弹药从哪进、往哪出，
## 也就无法规划流水线。用户要求「不只是升级效果模块，其他所有有输出或者有输入的模块
## 都要显示箭头，方便规划流水线」。
##
## 与 `_draw_aim_line()` 的区分（炮管同时有 in0 与 aim，两者必须一眼分开）：
##   - 端口箭头 = **物料流向**：只有四个正交方向、短（13 px）、贴端口格边缘；
##     输入用冷色 cyan 且箭头**指向模块内部**，输出用暖色 amber 且**背离模块**。
##   - 瞄准线 = **弹道方向**：可对角（8 档）、细长亮绿线段、从首格中心出发。
##
## 全部尺寸与位置由格坐标和常量算出：零随机、零时间依赖（确定性要求）。
func _draw_port_arrows(part: Dictionary, definition: Dictionary, alpha: float = 1.0) -> void:
	var specs: Array = AmmoNetwork.ui_ports(String(part.get("id", "")), definition, int(part.get("rot", 0)))
	if specs.is_empty():
		return
	var cells: Array[Vector2i] = _editor_model().part_cells(part)
	if cells.is_empty():
		return
	for raw in specs:
		var spec: Dictionary = raw
		var side := String(spec["side"])
		var kind := String(spec["kind"])
		## 取格规则直接复用 `AmmoNetwork._port_cell()`，绝不在页面层再写一份——
		## 两份推导一旦漂移，箭头就会指到没有端口的格子上。
		var cell := AmmoNetwork._port_cell(cells, side)
		var centre := _cell_rect(cell).get_center()
		## `side` 是「端口朝外」的方向；in 的箭头朝内，out 的箭头朝外。
		var outward := _side_direction(side)
		var arrow_dir := -outward if kind == "in" else outward
		var colour: Color = Palette.ACCENT_CYAN if kind == "in" else Palette.ACCENT_AMBER
		var edge := centre + outward * (GRID_CELL * 0.5 - 4.0)
		var tip := edge + arrow_dir * PORT_ARROW_LEN
		draw_line(edge, tip, Color(colour, alpha), PORT_ARROW_WIDTH)
		## 两片箭翼：固定角度，不用随机也不依赖时间。
		var wing_a := arrow_dir.rotated(PORT_ARROW_WING_ANGLE)
		var wing_b := arrow_dir.rotated(-PORT_ARROW_WING_ANGLE)
		draw_line(tip, tip - wing_a * PORT_ARROW_WING, Color(colour, alpha), PORT_ARROW_WIDTH)
		draw_line(tip, tip - wing_b * PORT_ARROW_WING, Color(colour, alpha), PORT_ARROW_WIDTH)

## side 名称 → 屏幕方向（+y 向下，与格坐标一致）。
static func _side_direction(side: String) -> Vector2:
	match side:
		"E":
			return Vector2.RIGHT
		"S":
			return Vector2.DOWN
		"W":
			return Vector2.LEFT
	return Vector2.UP

## 瞄准线：从**炮口末端之外**画一条细短线，指出这门炮往哪打。
##
## v3.37：炮管本体已由 `CannonView.draw_cannon()` 画出（基座 / 管身 / 炮口），
## 这条线于是从「唯一的炮管视觉」退化成**方向指示器**。起点必须从「首格中心」
## 挪到炮口末端（`CannonView.mouth_offset()`），否则它整根埋在管子里，画了等于没画。
##
## 传 `scale_factor = 1.0`：建造/改装页的网格不缩放（`GRID_CELL` 就是屏幕像素），
## 必须与 `CannonView.draw_cannon(..., 1.0, GRID_ORIGIN)` 的实参逐字一致，否则
## 小尺寸长度补偿会让瞄准线起点与炮口错开。
func _draw_aim_line(part: Dictionary, alpha: float = 1.0) -> void:
	var cells: Array[Vector2i] = _editor_model().part_cells(part)
	if cells.is_empty():
		return
	var center := _cell_rect(cells[0]).get_center()
	var angle := deg_to_rad(float(part.get("aim", 0)))
	var direction := Vector2(cos(angle), sin(angle))
	var mouth := center + direction * CannonView.mouth_offset(GRID_CELL, 1.0)
	draw_line(mouth, mouth + direction * 18.0, Color(Palette.ACCENT_LIME, alpha), 2.0)

## `alpha` 控制整格的可见度：非选中层传 `LAYER_DIM_ALPHA`，文字一起变淡。
## `outlined=false` 用于「被管道压住的平台格」：那道方框会横跨在管身上，把一根
## 连续的管切成一段一段 —— 在 32× 栽切里与「接缝」完全分不出来。
func _draw_cell(cell: Vector2i, color: Color, label: String, core: bool, alpha: float = 1.0, outlined: bool = true) -> void:
	var rect := _cell_rect(cell)
	draw_rect(rect, Color(color, (0.12 if outlined else 0.05) * alpha), true)
	if outlined:
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
		_draw_text("方向键 / 鼠标定位   Enter/左键贴装   R 旋转   X/右键拆解（退回库存）   T 给改进器加槽   Esc 完成", Vector2(620, 1018), 14, Palette.TEXT_LO, false)
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

## 缩放与坐标换算都委托 `CombatView`：三页原本各有一份逐字相同的副本，
## 现在的差别只在于「读哪个会话的竞技场」，而那正应该由页面自己决定。
## 注意：不能复用 _drive_scale() —— 它读的是试驾页的 _drive_arena，对局页下为空会退回 1.0。
## v3.38：比例来自 `fit_scale(view, camera)` 而**不是** `fit_scale(view, arena)`，
## 相机矩形已经含了 zoom，所以这里不需要（也不允许）再乘一次。
func _match_scale() -> float:
	if match_session == null:
		return 1.0
	return CombatView.fit_scale(DRIVE_VIEW, _battle_camera(match_session.duel.arena))

func _match_to_screen(world: Vector2, scale_factor: float) -> Vector2:
	return CombatView.to_screen(DRIVE_VIEW, _battle_camera(match_session.duel.arena), world, scale_factor)

## 对局页战斗视图：竞技场 / 障碍 / 车体 / 动效 / 弹道 / 命中闪光 / 伤害数字全部走
## `CombatView`，与生存页同一份实现。页面只负责组装参数与画自己的 HUD。
##
## 绘制顺序跟着统一后的规矩：动效在弹道**之下**、命中闪光与伤害数字在最上层。
## 旧版对局页把弹道画在动效之下，所以接通后层级会变——这是有意的，不是回归。
func _draw_match() -> void:
	if match_session == null:
		return
	var duel: Duel = match_session.duel
	var scale_factor := _match_scale()
	## v3.38：本函数内所有绘制共用**同一个相机矩形**（只算一次）。
	## 逐处重算会在缩放且焦点在插值中的那一帧拿到两个不同值，画面会抽一下。
	var camera := _battle_camera(duel.arena)
	CombatView.draw_arena(self, DRIVE_VIEW, duel.arena, camera, scale_factor, duel.obstacles, Palette.ACCENT_CYAN)
	## 中立物（房屋 / 残骸）是对局模式没有的，传空数组即可——
	## 这就是「同一份实现按模式配置」而不是「两套分支」的意思。
	CombatView.draw_neutrals(self, DRIVE_VIEW, duel.arena, camera, scale_factor, [], [], float(definitions.global_number("cell_size", 16.0)))
	for tag in [Duel.TAG_ENEMY, Duel.TAG_PLAYER]:
		_draw_match_hull(String(tag), scale_factor, camera)
	CombatView.draw_fx(self, DRIVE_VIEW, camera, scale_factor, _match_fx.entries, CombatView.FX_STYLE_MATCH)
	## 消散画在弹道**之下**：残余弹道残影不应该被遮住，而且消散本身没有实体。
	_draw_timed_expires(_match_expires, camera, scale_factor)
	CombatView.draw_shots(self, DRIVE_VIEW, camera, scale_factor, duel.field.shots, Duel.TAG_PLAYER)
	## 炮口闪光画在弹道**之上**：它是「刚刚发出这一发」的因果提示，必须盖在拖尾上。
	_draw_timed_muzzles(_match_muzzles, camera, scale_factor)
	CombatView.draw_hit_flash(self, DRIVE_VIEW, camera, scale_factor, _match_hit_flash_at, _match_hit_flash_left)
	CombatView.draw_damage_popups(self, DRIVE_VIEW, camera, scale_factor, _match_fx.entries, _draw_text)
	_draw_match_hud()
	## v3.25：准星画在最后——它必须盖在弹道 / 炮口闪光 / 命中闪光 / HUD 之上，
	## 否则鼠标压在特效上时准星会被遮住，玩家会以为鼠标丢了。
	_draw_aim_reticle()

## 炮口闪光与消散的绘制包装：两个页面共用同一个循环形状，只有相机与缩放不同。
##
## 为什么不把循环也搬进 `CombatView`：那需要把「颜色属于谁」的判据也搬进去，
## 而队伍色是**页面知识**（哪个 tag 是玩家）。组件只该知道「给我位置、方向、颜色」。
##
## v3.38：第二个参数从 `arena` 改成 `camera` —— 相机矩形已经含了缩放焦点，
## 传错了就会让光效与炮弹在缩放后分开（两者必须用同一个相机）。
func _draw_timed_muzzles(entries: Array, camera: Rect2, scale_factor: float) -> void:
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		CombatView.draw_muzzle_flash(self, DRIVE_VIEW, camera, scale_factor, Vector2(entry["pos"]), Vector2(entry["dir"]), float(entry["left"]), Color(entry["colour"]))

func _draw_timed_expires(entries: Array, camera: Rect2, scale_factor: float) -> void:
	for raw_entry in entries:
		var entry: Dictionary = raw_entry
		CombatView.draw_expire_flash(self, DRIVE_VIEW, camera, scale_factor, Vector2(entry["pos"]), float(entry["left"]), Color(entry["colour"]))

## 坦克绘制的唯一实现：试驾 / 对局 / 生存三页原本各有一份逐行同构的副本，
## 差异只在「每部件颜色」「填充透明度」「部件格偏移」「额外的格装饰」。
## 抽成回调后，生存页那套按血量分档上色可以一处改动全页生效——旧版正是因为三份副本
## 各自演化，对局页始终没拿到血量上色，玩家才看不出敌人被打残了。
##
## `colour_fn(part) -> Color`    每部件主色（必需）
## `alpha_fn(part) -> float`     填充透明度（缺省 0.22，与试驾/对局页旧行为一致）
## `offset_fn(part) -> Vector2`  该部件所有格的额外偏移（缺省零）
## `cell_hook(box, colour, part)` 每格额外装饰，例如履带纹（缺省无）
## `pipe_hook(part, colour, offset) -> bool` **整部件**钩子（v3.35）：
##   返回 `true` 表示「这个部件已经由钩子自己画完」，`_draw_hull_shared` 不再画它的方格。
##   管道模块走这条——管道必须按**整个占位**算中心线，逐格画不出弧与拐角。
##   `offset` 是已经算好的 `-centroid_local + offset_fn` 平移，钩子直接传给 `PipeView`。
## `pipe_cells` 被管道压住的格（v3.36，可选，缺省 `{}`）：这些格只保留淡填充、**不描边**。
##   为什么必需：平台层是逐格部件，每格都画方框；方框横跨在管身上会把一根连续的管
##   切成一段一段，看上去就是接缝。**调用方必须先构出钩子再调用本函数** ——
##   钩子负责填 `_pipe_covered_cells`，这里直接读它，不另算一份。
## `cannon_hook(part, colour, offset) -> bool` **整部件**钩子（v3.37）：炮管走这条 ——
##   管形是**沿瞄准方向伸出的旋转体**，不沿格网铺开，逐格画不出基座 / 管身 / 炮口。
##   返回 `true` 表示「已由钩子画完」。`offset` 与 `pipe_hook` 完全相同。
##   **缺省 `Callable()` 时不走任何分支**，像素与旧版逐字节相同。
## `effects` 逐模块特效（可选，缺省空字典）：
##   `effects["parts"]` : part_key → {fill, fill_colour, bar, bar_colour, outline, outline_colour}
##   `effects["links"]` : [{from: Vector2i, to: Vector2i, colour: Color}] 局部格坐标连线（维修）
## **缺省 `{}` 时一个绘制分支都不会走，像素与旧版逐字节相同**——这是截图基线可比的前提。
func _draw_hull_shared(hull: TankBody, origin: Vector2, heading: float, scale_factor: float, colour_fn: Callable, alpha_fn: Callable = Callable(), offset_fn: Callable = Callable(), cell_hook: Callable = Callable(), effects: Dictionary = {}, pipe_hook: Callable = Callable(), pipe_cells: Dictionary = {}, cannon_hook: Callable = Callable()) -> void:
	if hull == null or hull.parts.is_empty():
		return
	var cell: float = hull.cell_size()
	var effect_parts: Dictionary = effects.get("parts", {})
	var effect_links: Array = effects.get("links", [])
	draw_set_transform(origin, heading, Vector2(scale_factor, scale_factor))
	for part in hull.parts:
		var colour: Color = colour_fn.call(part)
		var alpha := 0.22
		if alpha_fn.is_valid():
			alpha = float(alpha_fn.call(part))
		var part_offset := Vector2.ZERO
		if offset_fn.is_valid():
			part_offset = Vector2(offset_fn.call(part))
		var pipe_drawn := false
		if pipe_hook.is_valid():
			pipe_drawn = bool(pipe_hook.call(part, colour, -hull.centroid_local + part_offset))
		## v3.37：炮管层。一个部件不可能同时是管道和炮管，但**保持「先管道后炮管」**
		## 可以避免将来两者语义交叉时出错（管道已经先占了 `pipe_drawn`）。
		var cannon_drawn := false
		if not pipe_drawn and cannon_hook.is_valid():
			cannon_drawn = bool(cannon_hook.call(part, colour, -hull.centroid_local + part_offset))
		if not pipe_drawn and not cannon_drawn:
			for raw_cell in part["cells"]:
				var cell_value: Vector2i = raw_cell
				var centre: Vector2 = (Vector2(cell_value) + Vector2(0.5, 0.5)) * cell - hull.centroid_local + part_offset
				var box := Rect2(centre - Vector2(cell, cell) * 0.5, Vector2(cell, cell))
				## 被管道压住的格（`pipe_cells` 命中）：只留填充、不描边。
				## 否则平台层逐格的方框会横跨在管身上，把一根连续的管切成一段一段 ——
				## 那在 32× 裁切里与「接缝」完全分不出来。缺省 `{}` 时不走这个分支。
				var under_pipe := pipe_cells.has(cell_value)
				draw_rect(box, Color(colour, alpha * (0.45 if under_pipe else 1.0)), true)
				if not under_pipe:
					draw_rect(box, colour, false, maxf(1.0 / scale_factor, 1.0))
				if cell_hook.is_valid():
					cell_hook.call(box, colour, part)
		var part_key := String(part.get("key", ""))
		if effect_parts.has(part_key):
			_draw_part_effect(part, effect_parts[part_key], cell, -hull.centroid_local + part_offset, scale_factor)
	## 维修连线：从维修装置首格指向「下一次真正会被修的那一件」首格。
	## 画在格之后、变换复位之前，所以自动随车体旋转与缩放。
	if not effect_links.is_empty():
		var link_pulse := 0.5 + 0.5 * sin(_time * MODULE_PULSE_SPEED)
		for raw_link in effect_links:
			var link: Dictionary = raw_link
			var link_from: Vector2 = (Vector2(Vector2i(link["from"])) + Vector2(0.5, 0.5)) * cell - hull.centroid_local
			var link_to: Vector2 = (Vector2(Vector2i(link["to"])) + Vector2(0.5, 0.5)) * cell - hull.centroid_local
			var link_colour: Color = link.get("colour", Palette.ACCENT_LIME)
			draw_line(link_from, link_to, Color(link_colour, 0.30 + 0.45 * link_pulse), maxf(1.0 / scale_factor, 1.0))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## 战斗页共用：在某张网的传送带上画管道与在途弹药。
##
## 调用时车体变换已经设好（原点 + 朝向 + 缩放），所以这里一律用格坐标 + `offset`。
## 返回的是 `_draw_hull_shared()` 的 `pipe_hook`：`false` 表示「这不是管道，照旧画方格」。
##
## **关键：不能从传入的 `part` 读 `specs` / `index`。**
## `hull.parts`（`TankBody`）只带 `kind/module_id/rot/aim/hp/cells/key`，
## 没有弹药网络那套 `specs`/`index`；端口必须重新按 `module_id + rot` 经
## `AmmoNetwork.ui_ports()` 推导（与仿真同一条函数），在途弹药则用**格数组做键**
## 去匹配 —— 两边的 `cells` 都是同一个 `part_cells()` 的结果，格集合一一对应。
func _network_pipe_hook(net: AmmoNetwork, cell: float, scale_factor: float) -> Callable:
	if net == null:
		return Callable()
	## 占位表与在途弹药每帧只算一次，所有部件共用同一份快照。
	var entries: Array = []
	var congested_cells: Dictionary = {}
	## 被管道占据的格：平台层那一格不要再描边（详见 `_draw_hull_shared` 的 `pipe_cells`）。
	## 存在实例字段上而不是靠调用方再算一遍：平台格与管道格的对应关系必须与钩子同源，
	## 两份推导一旦漂移，就会出现「管道盖在这格、描边却留在那格」。
	var pipe_cells: Dictionary = {}
	for entry in net.congestion():
		var hot_part: Dictionary = net.parts[int(entry["part"])]
		congested_cells[_cells_key(hot_part["cells"])] = true
	for part in net.parts:
		if String(part["role"]) != AmmoNetwork.ROLE_CONVEYOR:
			continue
		entries.append({"cells": part["cells"], "ports": part["specs"]})
		for raw_cell in part["cells"]:
			pipe_cells[Vector2i(raw_cell)] = true
	_pipe_covered_cells = pipe_cells
	var occupancy := PipeView.occupancy(entries)
	var flying: Dictionary = {}
	var phase_step := 0
	for round_state in net.strand_positions():
		flying[_cells_key(round_state["cells"])] = round_state
		phase_step += 1
	var phase := fposmod(_time * PipeView.PIPE_FLOW_SPEED, TAU)
	return func(part: Dictionary, colour: Color, part_offset: Vector2) -> bool:
		var module_id := String(part.get("module_id", ""))
		if not PipeView.has_shape(module_id):
			return false
		var cells: Array = part.get("cells", [])
		if cells.is_empty():
			return false
		var definition: Dictionary = definitions.get_module(module_id)
		var specs := AmmoNetwork.ui_ports(module_id, definition, int(part.get("rot", 0)))
		if specs.is_empty():
			return false
		var cells_key := _cells_key(cells)
		var hot := congested_cells.has(cells_key)
		## **管道不能用队伍色。** 队伍色与平台格同色时，管子会完全沉进甲板里看不出是管；
		## 这里一律用 `ACCENT_LIME`（调色板里的「能量 / 充能」色），与青/品红两支队伍
		## 和 Wire 灰的平台都能拉开。只在拥堵/出口阻塞时才换红。
		var tint: Color = Palette.ACCENT_RED if hot else Palette.ACCENT_LIME
		var alpha := 0.55 + 0.35 * (0.5 + 0.5 * sin(_time * 9.0)) if hot else 0.85
		var connected := PipeView.connected_sides(cells, specs, occupancy)
		var seed := float(cells_key.hash() % 97) / 97.0
		PipeView.draw_pipe(self, module_id, cells, specs, cell, tint, alpha, scale_factor,
			connected, 0.5 + 0.5 * sin(phase + seed), part_offset)
		if flying.has(cells_key):
			var round_state: Dictionary = flying[cells_key]
			var path := PipeView.round_path(module_id, cells, specs, cell,
				String(round_state["entry_port"]), String(round_state["exit_port"]), part_offset)
			var progress := clampf(float(round_state["progress"]), 0.0, 1.0)
			var t := progress if bool(round_state["forward"]) else 1.0 - progress
			var round_colour: Color = Palette.ACCENT_AMBER if bool(round_state["forward"]) else Palette.ACCENT_MAGENTA
			## 两种不同的「卡」：`congested` 是本格进度到顶（已停在本段末端），
			## `exit_blocked` 是**首选出口当前收不下**（还在走，但前面堵了）。
			## 两者都应是红色 —— 玩家看到红色就知道这条管线在堵，而不用区分是哪一种。
			if bool(round_state["congested"]) or bool(round_state.get("exit_blocked", false)):
				round_colour = Palette.ACCENT_RED
			PipeView.draw_round(self, path, cell, t, round_colour, 1.0, scale_factor)
		return true

## 格数组的稳定键：排序后拼串。两边的 `cells` 都来自同一个 `part_cells()`，
## 但顺序不保证一致，所以必须先排序。
static func _cells_key(cells: Array) -> String:
	var parts_out: Array = []
	for raw in cells:
		var value := Vector2i(raw)
		parts_out.append("%d:%d" % [value.x, value.y])
	parts_out.sort()
	return ",".join(parts_out)

## 炮管与部件的配对键：`module_id + 首格`。
##
## `CannonBank.cannons[]` 只存首格 `cell`（没有 `cells`、没有 `rot`），而 `hull.parts[]` 存 `cells`；
## 两边唯一稳定且唯一的共同标识就是这两项 —— 同型号两门炮靠首格区分。
static func _cannon_key(module_id: String, first_cell: Vector2i) -> String:
	return "%s|%d:%d" % [module_id, first_cell.x, first_cell.y]

## 战斗页共用：把炮管模块画成真炮管，并让它**实时指向当前瞄准方向**（v3.37）。
##
## 与 `_network_pipe_hook()` 同样的做法：**每帧只算一次快照**，所有部件共用同一份角度表。
## 方向取自 `CannonBank.muzzle_dir()` —— 瞄准的权威来源：有鼠标覆盖时是绝对世界角，
## 否则退回「`hull 朝向` + 建造期 `aim`」（Bot 走这条，永不调 `aim_at()`）。
## 页面层绝不自己算角度，否则「开火的方向」与「画出来的炮管」会各有一套推导。
##
## **必须减 `drawn_heading`。** `muzzle_dir()` 返回的是**世界**方向，而调用本钩子时
## `_draw_hull_shared()` 已经 `draw_set_transform(origin, heading, scale)`，
## 处在**车体局部坐标系**里。不减的话车体一转炮管就多转一个 `heading`；
## 这个错 headless 探针抓不到（探针不画图），只有截图或实机能发现。
##
## 传 `drawn_heading` 而不是直接用 `hull.heading`：试驾页额外叠了转向倾斜 `tilt`，
## 那里传给 `_draw_hull_shared()` 的是 `heading + tilt`，炮管必须跟着同一个值转，
## 否则高角速度下炮口会与炮口闪光错开几个像素。
##
## 返回 `false` 表示「这不是炮管」，交给 `_draw_hull_shared()` 照旧画方格。
func _battle_cannon_hook(bank: CannonBank, hull: TankBody, cell: float, scale_factor: float, drawn_heading: float) -> Callable:
	if bank == null or hull == null or bank.cannons.is_empty():
		return Callable()
	var aims: Dictionary = {}
	for cannon in bank.cannons:
		aims[_cannon_key(String(cannon["module_id"]), Vector2i(cannon["cell"]))] = bank.muzzle_dir(cannon).angle() - drawn_heading
	return func(part: Dictionary, colour: Color, part_offset: Vector2) -> bool:
		var module_id := String(part.get("module_id", ""))
		if not CannonView.is_cannon(definitions.get_module(module_id)):
			return false
		var cells: Array = part.get("cells", [])
		if cells.is_empty():
			return false
		var key := _cannon_key(module_id, Vector2i(cells[0]))
		if not aims.has(key):
			return false
		## **`part_offset` 已经是「车体局部坐标」的平移，不能再减 `centroid_local`。**
		## 调用方 `_draw_hull_shared()` 传进来的就是 `-hull.centroid_local + offset_fn(part)`；
		## 这里若再减一次，炮管就会多平移一个质心 —— 实测直接把炮管甩到车身之外（v3.37 修）。
		## 管道钩子同样直接把这个值转给 `PipeView`，两边口径必须一致。
		CannonView.draw_cannon(self, cells, float(aims[key]), cell, colour, CANNON_BATTLE_ALPHA,
			scale_factor, part_offset)
		return true

## 逐模块特效的常量。
## 进度条高度用**局部像素**，再夹一个最小**屏幕**厚度：生存页缩放系数只有 0.594，
## 纯局部 3 px 在屏幕上不足 2 px，会被霓虹格线淹掉；最小屏幕厚度保证任何缩放下都看得见。
const MODULE_BAR_LOCAL_HEIGHT := 3.2
const MODULE_BAR_MIN_SCREEN := 2.0
## 护盾/维修脉冲频率（rad/s）。相位取自 `_time`，不用 randf，截图冻结时 `_time` 不动。
const MODULE_PULSE_SPEED := 6.0

## 逐模块特效的唯一装配点（战场与镜像共用同一份结果）。
##
## 返回 `{parts: {part_key: {...}}, links: [{from, to, colour}]}`。每个部件的覆盖字段：
##   `fill` / `fill_colour`       整块格的覆盖填充（护盾生效时用，比例 = 护盾剩余血量）
##   `bar` / `bar_colour`         底部进度条 0..1（制造 / 存量 / 加工 / 装填 / 充能 / 维修）
##   `outline` / `outline_colour` 脉冲描边强度与颜色
##   `word` / `word_colour`       镜像面板用的 2–3 字状态词
##
## **所有比例都由数据层算好**：`module_states()` 用 `craft_time_s` / `reload_s` /
## `processing_time_s`，`shields()` 用 `recharge_s`，`repair_states()` 用 `period_s`。
## 页面层只做乘法和 clamp，不做任何时长除法——否则同一套分母会在两处各写一遍，迟早走偏。
func _hull_effects(hull: TankBody, damage: DamageSystem, net: AmmoNetwork) -> Dictionary:
	var parts_map: Dictionary = {}
	var links: Array = []
	if hull == null:
		return {"parts": parts_map, "links": links}
	var cell_index := _hull_cell_index(hull)
	if net != null:
		for raw in net.module_states():
			var entry: Dictionary = raw
			var cells: Array = entry["cells"]
			if cells.is_empty():
				continue
			var key := String(cell_index.get(Vector2i(cells[0]), ""))
			if key.is_empty():
				continue
			var role := String(entry["role"])
			var ratio := float(entry["ratio"])
			var overlay: Dictionary = parts_map.get(key, {})
			if role == AmmoNetwork.ROLE_FACTORY:
				overlay["bar"] = ratio
				overlay["bar_colour"] = Palette.ACCENT_AMBER
				overlay["word"] = "制造"
				overlay["word_colour"] = Palette.ACCENT_AMBER
			elif role == AmmoNetwork.ROLE_DEPOT:
				overlay["bar"] = ratio
				overlay["bar_colour"] = Palette.WIRE
				overlay["word"] = "存量"
				overlay["word_colour"] = Palette.WIRE
			elif role == AmmoNetwork.ROLE_MODIFIER:
				if ratio >= 0.0:
					overlay["bar"] = ratio
					overlay["bar_colour"] = Palette.ACCENT_AMBER
				overlay["word"] = "加工"
				overlay["word_colour"] = Palette.ACCENT_AMBER
			elif role == AmmoNetwork.ROLE_CANNON:
				var loaded := bool(entry["loaded"])
				overlay["bar"] = 1.0 if loaded else ratio
				overlay["bar_colour"] = Palette.ACCENT_LIME if loaded else Palette.ACCENT_AMBER
				overlay["word"] = "已上膛" if loaded else "装填"
				overlay["word_colour"] = Palette.ACCENT_LIME if loaded else Palette.ACCENT_AMBER
			parts_map[key] = overlay
	if damage != null:
		for raw in damage.shields():
			var shield: Dictionary = raw
			var shield_key := String(shield["key"])
			var shield_overlay: Dictionary = parts_map.get(shield_key, {})
			if String(shield["state"]) == DamageSystem.SHIELD_ACTIVE:
				shield_overlay["fill"] = clampf(float(shield["hp"]) / maxf(float(shield["hp_max"]), 0.001), 0.0, 1.0)
				shield_overlay["fill_colour"] = Palette.ACCENT_LIME
				shield_overlay["outline"] = 0.85
				shield_overlay["outline_colour"] = Palette.ACCENT_LIME
				shield_overlay["word"] = "护盾"
				shield_overlay["word_colour"] = Palette.ACCENT_LIME
			else:
				shield_overlay["bar"] = clampf(1.0 - float(shield["charge"]) / maxf(float(shield["recharge_s"]), 0.01), 0.0, 1.0)
				shield_overlay["bar_colour"] = Palette.ACCENT_LIME
				shield_overlay["outline"] = 0.55
				shield_overlay["outline_colour"] = Palette.ACCENT_RED
				shield_overlay["word"] = "充能"
				shield_overlay["word_colour"] = Palette.ACCENT_RED
			parts_map[shield_key] = shield_overlay
		for raw in damage.repair_states():
			var repair: Dictionary = raw
			var repair_key := String(repair["key"])
			var repair_overlay: Dictionary = parts_map.get(repair_key, {})
			repair_overlay["bar"] = float(repair["ratio"])
			repair_overlay["bar_colour"] = Palette.ACCENT_LIME
			repair_overlay["word"] = "维修"
			repair_overlay["word_colour"] = Palette.ACCENT_LIME
			parts_map[repair_key] = repair_overlay
			var own_cells: Array = repair["cells"]
			var target_cells: Array = repair["target_cells"]
			if not own_cells.is_empty() and not target_cells.is_empty():
				links.append({
					"from": Vector2i(own_cells[0]),
					"to": Vector2i(target_cells[0]),
					"colour": Palette.ACCENT_LIME,
				})
	return {"parts": parts_map, "links": links}

## 格坐标 → 部件 key。数据层导出的是格列表，页面层要用它把状态对回 `TankBody` 的部件。
## 用首格做键：同一辆车的部件不会共享格，而 `part_cells()` 的顺序在两条路径上一致。
func _hull_cell_index(hull: TankBody) -> Dictionary:
	var index: Dictionary = {}
	for part in hull.parts:
		var key := String(part["key"])
		for raw_cell in part["cells"]:
			index[Vector2i(raw_cell)] = key
	return index

## 单部件特效：覆盖填充 / 脉冲描边 / 底部进度条。
## 调用时车体变换已设好（原点 + 朝向 + 缩放），所以这里一律用**局部格坐标**，
## 随车体一起旋转与缩放，不需要再算一次世界坐标。
## `base` = `-centroid_local + offset`，把格坐标换算到车体局部系。
func _draw_part_effect(part: Dictionary, effect: Dictionary, cell: float, base: Vector2, scale_factor: float) -> void:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for raw_cell in part["cells"]:
		var value := Vector2(Vector2i(raw_cell))
		low = Vector2(minf(low.x, value.x), minf(low.y, value.y))
		high = Vector2(maxf(high.x, value.x), maxf(high.y, value.y))
	if low.x > high.x:
		return
	var box := Rect2(low * cell + base, (high - low + Vector2.ONE) * cell)
	var pulse := 0.5 + 0.5 * sin(_time * MODULE_PULSE_SPEED)
	var line_width := maxf(1.0 / scale_factor, 1.0)
	## ① 覆盖填充：护盾生效时整块格泛绿，强度随剩余护盾血量。
	if float(effect.get("fill", -1.0)) >= 0.0:
		var fill_colour: Color = effect.get("fill_colour", Palette.ACCENT_LIME)
		var fill_ratio := clampf(float(effect["fill"]), 0.0, 1.0)
		draw_rect(box, Color(fill_colour, 0.10 + 0.22 * fill_ratio), true)
	## ② 脉冲描边：护盾生效是绿，充能中是红。
	if float(effect.get("outline", 0.0)) > 0.0:
		var outline_colour: Color = effect.get("outline_colour", Palette.ACCENT_LIME)
		var strength := float(effect["outline"]) * (0.55 + 0.45 * pulse)
		draw_rect(box, Color(outline_colour, strength), false, line_width * 1.6)
	## ③ 底部进度条：制造 / 存量 / 加工 / 装填 / 充能 / 维修共用这一条。
	if float(effect.get("bar", -1.0)) >= 0.0:
		var bar_colour: Color = effect.get("bar_colour", Palette.ACCENT_AMBER)
		var bar_height := maxf(MODULE_BAR_LOCAL_HEIGHT, MODULE_BAR_MIN_SCREEN / maxf(scale_factor, 0.001))
		var bar := Rect2(Vector2(box.position.x + 0.5, box.end.y - bar_height - 0.5), Vector2(maxf(box.size.x - 1.0, 1.0), bar_height))
		draw_rect(bar, Color(Palette.BG_BASE, 0.85), true)
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(float(effect["bar"]), 0.0, 1.0), bar.size.y)), bar_colour, true)
		draw_rect(bar, Color(bar_colour, 0.55), false, maxf(0.5, line_width * 0.5))

## 对局页车体：坐标走 `CombatView.to_screen`，颜色走血量分档，特效走 `_hull_effects`。
## v3.38：`camera` 由 `_draw_match()` 算好传进来，与同帧其他绘制严格同源。
func _draw_match_hull(tag: String, scale_factor: float, camera: Rect2) -> void:
	var duel: Duel = match_session.duel
	var hull: TankBody = duel.tank_of(tag)
	if hull == null or hull.parts.is_empty():
		return
	var base := Palette.ACCENT_CYAN if tag == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
	var origin := CombatView.to_screen(DRIVE_VIEW, camera, hull.position, scale_factor)
	var effects := _hull_effects(hull, duel.damage_of(tag), duel.network_of(tag))
	## v3.35：管道层。钩子只看格坐标，质心平移由 `_draw_hull_shared` 自己算好传进来，
	## 所以这里不用关心车体在哪。
	var cell: float = hull.cell_size()
	var pipe_hook := _network_pipe_hook(duel.network_of(tag), cell, scale_factor)
	## v3.37：炮管层。对局页的车体朝向就是 `hull.heading`，没有额外的视觉倾斜。
	var cannon_hook := _battle_cannon_hook(duel.bank_of(tag), hull, cell, scale_factor, hull.heading)
	_draw_hull_shared(hull, origin, hull.heading, scale_factor, _match_part_colour.bind(base), CombatView.hull_damage_alpha, Callable(), Callable(), effects, pipe_hook, _pipe_covered_cells, cannon_hook)


## 对局页每部件颜色：驾驶舱恒为琥珀，其余按队伍色，再统一过血量分档。
## 分档判据与生存页是**同一个函数**（`CombatView.hull_damage_colour`），
## 这才是「复用」的实质：不是两页各自会变色，而是只改一处两页同时变。
## `bind(base)` 后签名为 (part, base)。
func _match_part_colour(part: Dictionary, base: Color) -> Color:
	var team := base
	if bool(definitions.get_module(String(part["module_id"])).get("core", false)):
		team = Palette.ACCENT_AMBER
	return CombatView.hull_damage_colour(part, team)

func _draw_match_hud() -> void:
	var duel: Duel = match_session.duel
	var left := DRIVE_HUD_LEFT.position.x
	var right := DRIVE_HUD_RIGHT.position.x
	_draw_battle_header("对战 / %s" % MATCH_DIFFICULTY_LABEL[_match_difficulty], Palette.ACCENT_CYAN, Vector2(left, 120), 16, "MATCH", Vector2(left, 152), 32)
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
	_draw_text("鼠标瞄准 · 左键开火", Vector2(right, 320), 16, Palette.TEXT_HI, false)
	_draw_text("滚轮缩放 · Z 复位  %.2f×" % _camera_zoom, Vector2(right, 350), 14, Palette.ACCENT_CYAN, false)
	_draw_text("P        暂停", Vector2(right, 380), 16, Palette.TEXT_HI, false)
	_draw_text("R        重开对局", Vector2(right, 410), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, 440), 16, Palette.TEXT_HI, false)
	var player_bank = duel.bank_of(Duel.TAG_PLAYER)
	if player_bank != null and not player_bank.cannons.is_empty():
		var cannon: Dictionary = player_bank.cannons[0]
		var reload := maxf(float(cannon["reload_s"]), 0.01)
		var progress := clampf(1.0 - float(cannon["reload_remaining"]) / reload, 0.0, 1.0)
		_draw_text("装填", Vector2(right, 470), 14, Palette.TEXT_LO, false)
		draw_rect(Rect2(right, 480.0, 272.0, 6.0), Color(Palette.WIRE, 0.35), true)
		draw_rect(Rect2(right, 480.0, 272.0 * progress, 6.0), Palette.ACCENT_AMBER if bool(cannon["loaded"]) else Palette.WIRE, true)
	if match_session.is_over():
		_draw_battle_status("对局结束：%s（R 重开 / Esc 返回）" % _match_outcome_text(), Palette.TEXT_HI, true)
	else:
		_draw_battle_status(_status_message)

## ===== 战斗场景相机（v3.38）：鼠标滚轮缩放 =====
##
## 相机状态只有两个：`_camera_zoom`（倍数）与 `_camera_focus`（世界焦点）。
## 相机矩形由 `CombatView.camera_rect(arena, focus, zoom)` 现算 —— **不缓存**，
## 因为缓存一旦与 arena 不同步，就会出现「画用旧相机、矄准用新相机」。
##
## `zoom == 1.0` 时 `camera_rect()` **直接返回 `arena`**，于是所有 `to_screen()` 的输入
## 与 v3.37 逐字相同，默认像素与历史截图基线继续可比。
func _battle_camera(arena: Rect2) -> Rect2:
	if arena.size.x <= 0.0:
		return arena
	return CombatView.camera_rect(arena, _camera_focus, _camera_zoom)

## 滚轮缩放。`factor` > 1 放大、< 1 缩小；结果夹在 `[CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX]`。
## 缩到 1.0 时顺手把焦点重置成竞技场中心（`_camera_focus_ready = false`），
## 让「刚好回到默认倍数」这一个状态只剩下一种可能取值，方便测试与截图。
func _camera_zoom_by(factor: float) -> void:
	var next := clampf(_camera_zoom * factor, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
	if is_equal_approx(next, _camera_zoom):
		return
	_camera_zoom = next
	if absf(_camera_zoom - 1.0) < 0.000001:
		_camera_zoom = 1.0
		_camera_focus_ready = false
	_set_status("缩放 %.2f×（滚轮调整 · Z 复位）" % _camera_zoom)
	queue_redraw()

## 把相机退回默认：倍数 1.0 + 焦点未就绪。`Z` 键走这条。
## 直接回 1.0 而不是「反滚十几格」，也不做平滑 —— 复位应当是瞬时且确定的。
func _camera_reset_zoom() -> void:
	if absf(_camera_zoom - 1.0) < 0.000001 and not _camera_focus_ready:
		return
	_camera_zoom = 1.0
	_camera_focus_ready = false
	_camera_focus = Vector2.ZERO
	if _screen == SCREEN_DRIVE:
		_drive_last_event = "缩放 1.00×"
	elif _screen == SCREEN_MATCH:
		_match_event = "缩放 1.00×"
	elif _screen == SCREEN_SURVIVAL:
		_survival_event = "缩放 1.00×"
	queue_redraw()

## 当前战斗页的竞技场（不管有没有缩放）。拿不到时返回空 `Rect2`。
## 抽出来是因为「取焦点目标」与「取相机」需要同一个 arena，而 `_battle_view()`
## 会顺带算 scale/camera —— 在只想拿 arena 的地方多算一次没必要。
func _battle_arena_now() -> Rect2:
	if _screen == SCREEN_SURVIVAL and survival != null and survival.duel != null:
		return survival.duel.arena
	if _screen == SCREEN_MATCH and match_session != null:
		return match_session.duel.arena
	if _screen == SCREEN_DRIVE:
		return _drive_arena
	return Rect2()

## 相机焦点每帧推进。`delta` 是本帧真实时长（与引擎帧率一致）。
##
## 目标优先取玩家车体中心；拿不到就退回竞技场中心。
## **不缩放时不追焦**（`zoom == 1.0` 直接把焦点标记为未就绪），
## 于是「从未缩放过」的截图路径不可能因为焦点漂移而改变像素。
func _camera_follow(delta: float) -> void:
	if absf(_camera_zoom - 1.0) < 0.000001:
		_camera_focus_ready = false
		return
	var arena := _battle_arena_now()
	if arena.size.x <= 0.0:
		return
	var target := _battle_focus_target(arena)
	if not _camera_focus_ready:
		_camera_focus = target
		_camera_focus_ready = true
		return
	## 与帧率无关的指数插值：`1 - exp(-k·dt)`。k 取 9.0 时几乎瞬到，但不硬跳。
	var t := 1.0 - exp(-CAMERA_FOCUS_FOLLOW * maxf(delta, 0.0))
	_camera_focus = _camera_focus.lerp(target, clampf(t, 0.0, 1.0))

## 相机应该看向的世界点：玩家车中心，否则竞技场中心。
func _battle_focus_target(arena: Rect2) -> Vector2:
	if _screen == SCREEN_SURVIVAL and survival != null and survival.duel != null:
		var alive: TankBody = survival.duel.tank_of(Duel.TAG_PLAYER)
		if alive != null:
			return alive.position
	elif _screen == SCREEN_MATCH and match_session != null:
		var matched: TankBody = match_session.duel.tank_of(Duel.TAG_PLAYER)
		if matched != null:
			return matched.position
	elif _screen == SCREEN_DRIVE and tank != null:
		return tank.position
	return arena.get_center()

## ===== 试驾沙盒绘制（M3）：世界缩放、刚体姿态、弹道与 HUD =====
func _drive_scale() -> float:
	return CombatView.fit_scale(DRIVE_VIEW, _battle_camera(_drive_arena))

func _drive_to_screen(world: Vector2) -> Vector2:
	var camera := _battle_camera(_drive_arena)
	return CombatView.to_screen(DRIVE_VIEW, camera, world, CombatView.fit_scale(DRIVE_VIEW, camera))

## 屏幕坐标 → 世界坐标。三个战斗页共用同一条逆变换公式（`to_world`）。
## 为什么不能三页各写一份：正向变换在 `CombatView` 里只写了一份，逆变换如果每页自己拼，
## 一旦相机不一致，三处就会同时错——而且错的是「看得见的炮管」与「真的弹道」之间的关系。
## `camera` 与同一个页面的 `to_screen()` 用的必须是**同一个** `_battle_camera()` 结果。
static func _screen_to_world(view: Rect2, camera: Rect2, screen: Vector2, scale_factor: float) -> Vector2:
	return CombatView.to_world(view, camera, screen, scale_factor)

## 把鼠标位置换成世界坐标并让该侧所有炮管指向它。三个战斗页共用。
##
## 只在 `view` 矩形内部生效：鼠标飘到 HUD 上时不应该把炮口拉向面板边缘。
## `camera` 必须是该页 `_battle_camera()` 的结果 —— 与绘制同源。
## 返回是否真的改动了方向（供调用方决定要不要重绘）。
func _aim_player_cannons(view: Rect2, camera: Rect2, scale_factor: float, position: Vector2) -> bool:
	if not view.has_point(position):
		return false
	var bank := _player_bank()
	if bank == null:
		return false
	var world := _screen_to_world(view, camera, position, scale_factor)
	return bank.aim_all_at(world) > 0

## 当前屏幕对应的玩家炮管组；非战斗页返回 null。
func _player_bank() -> CannonBank:
	if _screen == SCREEN_SURVIVAL and survival != null and survival.duel != null:
		return survival.duel.bank_of(Duel.TAG_PLAYER)
	if _screen == SCREEN_MATCH and match_session != null:
		return match_session.duel.bank_of(Duel.TAG_PLAYER)
	if _screen == SCREEN_DRIVE:
		return bank
	return null

## 当前屏幕是否处于**可瞄准 / 可开火**的战斗页。战斗期以外（升级页 / 商店页 / 改装页）
## 一律返回 false：那里左键是「选卡片 / 买商品 / 落格」，不能同时当开火键。
func _is_battle_screen() -> bool:
	if _screen == SCREEN_DRIVE:
		return _drive_ready
	if _screen == SCREEN_MATCH:
		return _match_ready and match_session != null and not match_session.is_over() and not match_session.paused
	if _screen == SCREEN_SURVIVAL:
		return _survival_ready and survival != null and survival.stage == SurvivalRun.STAGE_BATTLE
	return false

## 战斗页当前的鼠标位置（设计坐标）。
##
## v3.26：`_mouse_position` 只在 `InputEventMouseMotion` 到达时更新。实测两个可见后果：
## ① 从菜单点进战斗页（或改过窗口尺寸后）玩家不动鼠标，准星停在上一页的旧点上——最远偏 570×140 px；
## ② 坦克行驶而鼠标静止时，炮口保持旧角度，不再指向准星下的世界点——行驶 400 px 后偏 5.05°。
## 两者的根因相同：瞄准只在「鼠标动了」时重算。
func _battle_pointer() -> Vector2:
	## 截图路径例外：`--cursor=` 已经把鼠标位置钉死，这里必须原样返回，
	## 否则截图会随桌面上真实鼠标的位置漂移，历史基线也不再可比。
	if not _capture_target.is_empty():
		return _mouse_position
	return get_viewport().get_mouse_position()

## 战斗页每帧执行：同步准星位置，并让炮口重新指向「光标下的世界点」。
##
## 为什么必须每帧而不是只在鼠标动时：准星标的是**战场上的一个世界点**，不是屏幕上的一个角度。
## 坦克一移动，同一个屏幕点对应的世界点就变了；只在鼠标动时重算，准星就会「说谎」——
## 玩家看到准星压在敌人身上，弹道却按十几帧前的几何飞出去。
func _sync_battle_pointer() -> void:
	if not _is_battle_screen():
		return
	## 截图路径不参与：`--cursor=` 已经显式设过 `_mouse_position` 与炮口方向，
	## 这里再干预会让截图随桌面真实鼠标漂移。
	if not _capture_target.is_empty():
		return
	var pointer := _battle_pointer()
	_mouse_position = pointer
	if _aim_with_mouse(pointer):
		queue_redraw()

## 把鼠标位置换算成世界坐标并让玩家全部炮管指过去。三页共用。
## 返回是否真的改了方向（供调用方决定要不要重绘）。
## v3.38：`info["camera"]` 与绘制用的是同一个 `_battle_camera()` —— **不能只传 arena**，
## 否则缩放后「画出来的炮管」与「真实开火方向」会分成两套推导（v3.37 的教训）。
func _aim_with_mouse(position: Vector2) -> bool:
	var info := _battle_view()
	if info.is_empty():
		return false
	return _aim_player_cannons(info.get("view", Rect2()), info.get("camera", Rect2()), float(info.get("scale", 1.0)), position)

## v3.25：左键开火。三个战斗页共用一条路径，但开火后的 UI 反馈各写各的，
## 因为三个页面的「最近事件」字段与开火入口本来就不同（试驾页绕过 Duel）。
func _fire_battle_player(position: Vector2) -> void:
	if not _is_battle_screen():
		return
	## 先确保炮口已经指向点击处：同一帧内的「点下去」必须打向点击点，不能打上一个鼠标位置。
	_aim_with_mouse(position)
	if _screen == SCREEN_SURVIVAL:
		var fired := 0
		if survival.duel != null:
			fired = survival.duel.fire(Duel.TAG_PLAYER)
		_survival_event = ("开火：%d 发离膛" % fired) if fired > 0 else "未装填或冷却中"
		queue_redraw()
		return
	if _screen == SCREEN_MATCH:
		var fired_match := match_session.duel.fire(Duel.TAG_PLAYER)
		_match_event = ("开火：%d 发离膛" % fired_match) if fired_match > 0 else "未装填或冷却中"
		queue_redraw()
		return
	if _screen == SCREEN_DRIVE:
		_drive_fire()


## 当前屏幕对应玩家侧的竞技场：生存页 / 对局页各读自己的 `duel.arena`，
## 试驾页读 `_drive_arena`（它不经过 `Duel`）。
##
## 返回 `{view, arena, camera, scale}`，三页的鼠标瞄准与准星绘制都走这一份，
## 避免「某页用了别的页的竞技场」这类静默错位。
##
## **`camera` 与 `scale` 必须同时返回，且必须同步**：`scale` 是 `fit_scale(view, camera)`
## 的结果，`camera` 是 `_battle_camera(arena)` 的结果。只传其中一个（例如只传 arena
## 而丢掉 zoom）会让矄准与绘制各自推一套几何。
func _battle_view() -> Dictionary:
	if _screen == SCREEN_SURVIVAL and survival != null and survival.duel != null:
		var arena: Rect2 = survival.duel.arena
		return {"view": DRIVE_VIEW, "arena": arena, "camera": _battle_camera(arena), "scale": _survival_scale()}
	if _screen == SCREEN_MATCH and match_session != null:
		var match_arena: Rect2 = match_session.duel.arena
		return {"view": DRIVE_VIEW, "arena": match_arena, "camera": _battle_camera(match_arena), "scale": _match_scale()}
	if _screen == SCREEN_DRIVE:
		return {"view": DRIVE_VIEW, "arena": _drive_arena, "camera": _battle_camera(_drive_arena), "scale": _drive_scale()}
	return {}

## 准星：鼠标在战场区内时画一个空心环 + 十字）。
##
## 为什么用环 + 十字：端口箭头是「短线 + 箭翼」、瞄准线是「细长线段」、命中闪光是「实心圆向外扩张」、
## 消散是「三圈收缩 + 刻线」，四种已有图形都包围了「线」与「实心圆」，只剩空心环是空的。
func _draw_aim_reticle() -> void:
	## 只在战斗期画：升级页 / 商店页 / 改装页 / 结算页都有自己的左键语义，
	## 在那些页面上画准星会让人误以为「这里也能开火」。
	if not _is_battle_screen():
		return
	var info := _battle_view()
	if info.is_empty():
		return
	var view: Rect2 = info["view"]
	## v3.26：位置取自 `_battle_pointer()` 而不是缓存的 `_mouse_position`——
	## 准星必须与 OS 光标逐像素重合，哪怕这一帧根本没收到 motion 事件。
	var pointer := _battle_pointer()
	if not view.has_point(pointer):
		return
	var colour := Palette.ACCENT_LIME
	draw_arc(pointer, AIM_RETICLE_RADIUS, 0.0, TAU, 24, Color(colour, 0.85), AIM_RETICLE_WIDTH, true)
	draw_line(pointer - Vector2(AIM_RETICLE_CROSS, 0.0), pointer + Vector2(AIM_RETICLE_CROSS, 0.0), Color(colour, 0.55), 1.0)
	draw_line(pointer - Vector2(0.0, AIM_RETICLE_CROSS), pointer + Vector2(0.0, AIM_RETICLE_CROSS), Color(colour, 0.55), 1.0)

func _draw_drive() -> void:
	## v3.38：本函数内所有绘制共用**同一个相机矩形**（只算一次），理由与 `_draw_match()` 相同。
	var camera := _battle_camera(_drive_arena)
	_draw_drive_field(camera)
	_draw_drive_hull(camera)
	_draw_drive_broken_links()
	_draw_drive_fx(camera)
	_draw_timed_expires(_drive_expires, camera, _drive_scale())
	_draw_drive_shots(camera)
	_draw_timed_muzzles(_drive_muzzles, camera, _drive_scale())
	## 命中闪光画在炮弹之上，确保不会被格线淹掉。
	CombatView.draw_hit_flash(self, DRIVE_VIEW, camera, _drive_scale(), _drive_hit_flash_at, _drive_hit_flash_left)
	## 伤害数字画在最后：必须盖在炮弹、命中闪光与所有地形之上。
	CombatView.draw_damage_popups(self, DRIVE_VIEW, camera, _drive_scale(), _drive_fx.entries, _draw_text)
	_draw_drive_hud()
	## v3.25：准星必须最后画，盖住车体 / 弹道 / HUD。
	_draw_aim_reticle()

## 试驾页的竞技场：直接走 `CombatView.draw_arena`，只多传一个网格间距。
## 网格间距是「4 格宽」的屏幕像素（旧实现里 `cell_step` 就是 `cell_size·scale·4`），
## `draw_arena` 的 `grid_step_px = 0` 缺省值保证另两页不会因此多画一根线。
func _draw_drive_field(camera: Rect2) -> void:
	if tank == null:
		return
	var scale_factor := _drive_scale()
	CombatView.draw_arena(self, DRIVE_VIEW, _drive_arena, camera, scale_factor, _drive_obstacles, Palette.ACCENT_CYAN, tank.cell_size() * scale_factor * 4.0)

## 整机绕质心旋转；design §5.5 的转向倾斜与加速滞后均为纯视觉量。
func _draw_drive_hull(camera: Rect2) -> void:
	if tank == null or tank.parts.is_empty():
		return
	var scale_factor := _drive_scale()
	var tilt := 0.0
	if _motion_enabled:
		tilt = clampf(tank.angular_velocity * deg_to_rad(0.7), -deg_to_rad(2.0), deg_to_rad(2.0))
	var effects := _hull_effects(tank, damage, network)
	## v3.33：后拖与履带纹已收归 `CombatView`，试驾页只是把两个开关打开。
	## 另两页不传这两个回调，`_draw_hull_shared()` 的缺省分支与旧版逐字节相同。
	##
	## v3.36：管道必须走**车载层**的 `pipe_hook`，而不是另外在车体上面再画一遍。
	## 旧写法是 `_draw_drive_hull()` 画逐格方块 + `_draw_drive_conveyors()` 再画管道，
	## 两层叠在一起时每格都被方框描边，管子就被人为切成一小段一小段 —— 那正是
	## 「看得见接缝」的直接原因（16× 裁切里一目了然）。现在管道件走钩子、非管道件走方格，
	## 与对局页 / 生存页同一条路径。
	var pipe_hook := _network_pipe_hook(network, tank.cell_size(), scale_factor)
	## v3.37：炮管层。注意传的是**画出来**的朝向（含转向倾斜 `tilt`），
	## 而不是 `tank.heading` —— 炮管要与车体一起倾，否则炮口会与炮口闪光错开。
	var drawn_heading := tank.heading + tilt
	var cannon_hook := _battle_cannon_hook(bank, tank, tank.cell_size(), scale_factor, drawn_heading)
	## v3.38：坐标走**同一个相机**——`_drive_to_screen()` 会自己取 `_battle_camera()`，
	## 但这里已经有一份了，重算一次不保证逐位相同（相机焦点在插值中）。
	_draw_hull_shared(tank, CombatView.to_screen(DRIVE_VIEW, camera, tank.position, scale_factor), drawn_heading, scale_factor, _drive_part_color, CombatView.hull_damage_alpha, _drive_part_offset, _drive_cell_hook, effects, pipe_hook, _pipe_covered_cells, cannon_hook)

## 加速时行进机构整体向后拖一点（纯视觉量，design §5.5）。
## 只在试驾页启用：`_motion_enabled` 与油门都是试驾页的状态。
func _drive_part_offset(part: Dictionary) -> Vector2:
	return CombatView.track_offset(part, _drive_throttle, _motion_enabled)

## 只在行进机构格上叠履带纹。
func _drive_cell_hook(box: Rect2, colour: Color, part: Dictionary) -> void:
	if String(part["kind"]) == TankBody.KIND_MOBILITY:
		CombatView.track_marks(self, box, colour, _drive_track_phase)

## 弹道走 `CombatView.draw_shots`：颜色按 `shooter` 判，试驾页的发射方 tag 恒为 "player"。
## 旧实现写死琥珀色——一旦以后有敌人的弹道进入试驾页，就分不出谁在打谁。
func _draw_drive_shots(camera: Rect2) -> void:
	if field == null:
		return
	CombatView.draw_shots(self, DRIVE_VIEW, camera, _drive_scale(), field.shots, "player")

## M5 战斗动效：残骸、爆炸环、护盾、脱落撕裂与驾驶舱被毁；全部由 left/life 倒数驱动。
## v3.33：形状与推进全部走 `CombatView.draw_fx` + `FX_STYLE_DRIVE`。
## 残骸 / 护盾受击 / 脱落 / 驾驶舱这四种专用形状随 `FX_STYLE_DRIVE["special"]` 开关走，
## 另两页不开这个开关，所以它们的动效仍然是通用圆环——像素不变。
func _draw_drive_fx(camera: Rect2) -> void:
	if _drive_fx.is_empty():
		return
	CombatView.draw_fx(self, DRIVE_VIEW, camera, _drive_scale(), _drive_fx.entries, CombatView.FX_STYLE_DRIVE)

## 试驾页的伤害悬浮数字：逻辑全在 `CombatView.push_damage()`（三页同一份）。
func _drive_push_damage(at: Vector2, amount: float, colour: Color, mode: String) -> void:
	CombatView.push_damage(_drive_fx, at, amount, colour, mode)

## 试驾页的断链图标（design §7.5）：源模块不可达时标红圈加斜杠。
##
## v3.36 之前这一小段夹在 `_draw_drive_conveyors()` 里，因为那个函数要自己建变换。
## 现在管道与在途弹药全部走 `_draw_hull_shared()` 的 `pipe_hook`（与另两页同一条路径），
## 断链图标与管道无关，所以在这里单独留一个函数，由 `_draw_drive()` 直接调用。
func _draw_drive_broken_links() -> void:
	if network == null or tank == null or tank.parts.is_empty():
		return
	var cell: float = tank.cell_size()
	for entry in network.route_status():
		if bool(entry["reachable"]):
			continue
		var source_cell := Vector2i((network.parts[int(entry["part"])]["cells"] as Array)[0])
		_draw_drive_broken_link(_drive_local_to_screen(Vector2(source_cell) + Vector2(0.5, 0.5), cell))

## 部件局部格中心 → 屏幕坐标（绕质心旋转后投影）。
func _drive_local_to_screen(local_cell: Vector2, cell: float) -> Vector2:
	var local := local_cell * cell - tank.centroid_local
	return _drive_to_screen(tank.position + local.rotated(tank.heading))

## 断链图标：红圈加斜杠，标在不可达的源模块上（design §7.5）。
func _draw_drive_broken_link(screen: Vector2) -> void:
	draw_arc(screen, 14.0, 0.0, TAU, 20, Palette.ACCENT_RED, 2.0)
	draw_line(screen + Vector2(-9.0, -9.0), screen + Vector2(9.0, 9.0), Palette.ACCENT_RED, 2.0)

## 试驾页每部件颜色：与对局页 / 生存页**同一条规则**——驾驶舱琥珀、其余队伍色
## （试驾页的队伍色是青色，与竞技场边框同色），再统一过血量分档。
## 分档判据与另两页是同一个函数 `CombatView.hull_damage_colour`，改一处三页同时变。
## v3.33 之前这里按**模块种类**上色（机动青柠 / 核心青 / 炮管琥珀 / 弹道品红 / 平台导线色），
## 伤害只用一次性 `lerp(RED, 0.5)` 掺红，于是同一个模块在三个页面上是三种颜色，
## 且看不出「哪一块被打残了」。旧配色没有删，改成 `_drive_kind_highlight` 打开时的调试高亮层。
func _drive_part_color(part: Dictionary) -> Color:
	if _drive_kind_highlight:
		return _drive_kind_colour(part)
	var team := Palette.ACCENT_CYAN
	if bool(definitions.get_module(String(part["module_id"])).get("core", false)):
		team = Palette.ACCENT_AMBER
	return CombatView.hull_damage_colour(part, team)

## 调试高亮层：按模块种类上色，用来一眼看清「这台车由哪些种类拼成」。
## 用途是分类而不是看损伤，所以原样保留旧配色（含一次性掺红），不做血量分档。
func _drive_kind_colour(part: Dictionary) -> Color:
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
	_draw_battle_header("DRIVE LAB / M5", Palette.ACCENT_CYAN, Vector2(48, 62), 18, "试驾沙盒", Vector2(48, 106), 34)
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
	_draw_text("A / D    转向", Vector2(right, hint_y + 26.0), 16, Palette.TEXT_HI, false)
	_draw_text("鼠标瞄准 · 左键开火", Vector2(right, hint_y + 52.0), 16, Palette.TEXT_HI, false)
	## v3.38：三页 HUD 的缩放读数必须一致。试驾页行数最多，因此把行距从 30 收到 26，
	## 在不压到下方管路状态行的前提下把缩放行插进键位块。
	_draw_text("滚轮缩放 · Z 复位  %.2f×" % _camera_zoom, Vector2(right, hint_y + 78.0), 14, Palette.ACCENT_CYAN, false)
	_draw_text("R        重开试驾 · K 种类高亮", Vector2(right, hint_y + 104.0), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, hint_y + 130.0), 16, Palette.TEXT_HI, false)
	var supply := "M4 管路：未初始化"
	if network != null:
		var broken := 0
		for entry in network.route_status():
			if not bool(entry["reachable"]):
				broken += 1
		## v3.27：把「拒收」单列出来。之前模块出口遇到口径不符会静默重试、永不报告，
		## 玩家只能看到「管子堵了」；现在同一行里能直接看出是接错了口径还是真的拥塞。
		## 标签缩写是为了不超出 DRIVE_HUD_RIGHT 的 272 px 文本区。
		supply = "M4 在途%d 拥塞%d 断链%d 拒收%d" % [
			network.rounds_in_flight(), network.congestion().size(), broken, network.rejected_count(),
		]
	_draw_text(supply, Vector2(right, hint_y + 150.0), 12, Palette.TEXT_LO, false)
	_draw_battle_status(_status_message)

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

## 读取 `--blueprint=<res:// 路径>`：截图钩子专用，把指定蓝图读进 `builder`。
## 为什么必需：受支持的七个 `--screen=` 取值里**没有建造页**，而改装页的库存由生存
## 进度决定（默认那局没有管道件），试驾页又只会用**当前建造蓝图**——于是没有任何
## 截图路径能摆出一辆带管道的车。v3.36 就是在这里踩过：三张截图全都证明不了管道存在。
## 这是**测试钩子**，不参与玩法逻辑，也不读游戏数据以外的东西。
func _requested_capture_blueprint() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--blueprint="):
			return argument.substr("--blueprint=".length())
	return ""

func _apply_capture_blueprint(path: String) -> void:
	if path.is_empty():
		return
	if not FileAccess.file_exists(path):
		printerr("CAPTURE_BAD_BLUEPRINT missing=%s" % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		printerr("CAPTURE_BAD_BLUEPRINT open_failed=%s" % path)
		return
	var data: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not data is Dictionary:
		printerr("CAPTURE_BAD_BLUEPRINT json=%s" % path)
		return
	var reason: String = builder.load_blueprint(data)
	if not reason.is_empty():
		printerr("CAPTURE_BAD_BLUEPRINT %s" % reason)
		return
	print("CAPTURE_BLUEPRINT_OK %s cells=%d modules=%d" % [
		path, builder.platform_cells.size(), builder.module_parts.size()])

func _handle_capture_request() -> void:
	## 先解析 `--steps=N`，因为下面各页的预热函数会读它。
	_capture_steps = _requested_capture_steps()
	## `--blueprint=` 必须**早于**下面的 `--screen=` 生效：`--screen=drive` / `--screen=match`
	## 当场就会用 `builder` 把坦克装出来，晚一步读到的就是 `reset_demo()` 的默认演示车。
	_apply_capture_blueprint(_requested_capture_blueprint())
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture="):
			_capture_target = argument.substr("--capture=".length())
		elif argument.begins_with("--cursor="):
			## v3.25 探针参数：把设计坐标下的鼠标位置钉到指定点。
			## 为什么必需：`--capture` 路径**不产生任何 `InputEventMouseMotion`**，`_mouse_position`
			## 会停在 `Vector2.ZERO`（战场区外），于是 `_draw_aim_reticle()` 早退——
			## 截图上连准星都没有，就无法用像素证据证明它存在。
			## 这是**测试钩子**，不参与玩法逻辑，也不读游戏数据。
			var parts := argument.substr("--cursor=".length()).split(",")
			if parts.size() == 2:
				_capture_cursor = Vector2(float(parts[0]), float(parts[1]))
		elif argument.begins_with("--zoom="):
			## v3.38 探针参数：把相机倍数钉到指定值。
			## 为什么必需：`--capture` 路径**不产生任何滚轮事件**，不给钩子就只能拍到 1.0×，
			## 无法用像素证据证明「放大后细节更清楚 / 缩小后看得更远」。
			## 这是**测试钩子**，不参与玩法逻辑；夹在 `[CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX]` 里。
			var raw_zoom := argument.substr("--zoom=".length())
			if raw_zoom.is_valid_float():
				_camera_zoom = clampf(float(raw_zoom), CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
				_camera_focus_ready = false
			else:
				printerr("CAPTURE_BAD_ZOOM %s" % raw_zoom)
		elif argument == "--screen=build":
			## v3.36：受支持的截图取值里一直没有建造页，于是最该看管道的那个页面反而抓不到。
			## 这里只做「进建造页 + 居中」，不触碰 `builder` 内容 —— 蓝图由 `--blueprint=` 单独负责，
			## 两者可以分开用，也可以叠用。
			_set_screen(SCREEN_BUILD)
			builder.center_content()
			var seats: Array[Vector2i] = builder.cockpit_cells()
			if not seats.is_empty():
				_cursor = seats[0]
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
	## v3.25：如果传了 `--cursor=`，页面已经建好，现在才能真正应用鼠标位置。
	## 顺带把炮口也指向该点：截图里矄准与炮口方向一致，才能一眼看出「鼠标瞄准」生效。
	## v3.38：相机焦点必须在这里**显式钉一次** —— `_camera_follow()` 跑在 `_process` 里，
	## 而下三行就把 `_process` 冻结了；不在这里置焦点的话，带 `--zoom=` 的截图会
	## 永远拍到「焦点 = 世界原点」的画面（一个锚点都没夹住的错误视角）。
	## 焦点放到位之后才 `_aim_with_mouse()`，否则矄准算的是旧相机的世界点。
	_camera_focus = _battle_focus_target(_battle_arena_now())
	_camera_focus_ready = true
	if _capture_cursor.is_finite():
		_mouse_position = _capture_cursor
		_aim_with_mouse(_capture_cursor)
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
## 命中闪光与伤害数字的时长/限流常量原来在这里，v3.22 已随绘制实现一起收归
## `scripts/combat_view.gd`（`HIT_FLASH_TIME` / `DAMAGE_POPUP_LIFE` /
## `DAMAGE_POPUP_PER_SIDE` 等）。**不再在页面层重复定义** —— 同一套数值写两份，
## 迟早会有一份被改而另一份没改，两个战斗模式的数字就会不一样快。
## 需要时一律读 `CombatView.XXX`。

var _survival_sell_index := 0

## 生存页的瞬时动效（命中 / 击毁 / 脱落）。倒计时只在 `_survival_step` 里推进，
## 与试驾页同一纪律：绝不放 `_process`，绝不用 `randf`。
var _survival_fx := FxLayer.new()
## 最近一次命中的世界坐标与剩余闪光时间：让“打中了”这件事在画面上无法被忽略。
var _hit_flash_at := Vector2.ZERO
var _hit_flash_left := 0.0
## v3.23：炮口闪光与射程耗尽消散（多实例，与对局页同一套推进/绘制）。
## 生存页一次有多个敌人开火，所以必须逐条存，不能只存最新一个；
## 否则同一帧里第二个敌人的炮口会直接把第一个的抹掉。
var _survival_muzzles: Array = []
var _survival_expires: Array = []

## 改装页复用建造页的整套编辑器（网格 / 模块目录 / 工具 / 属性校验）。
## 两页只差模型来源：建造页用 `builder`，改装页用 `survival_builder`；
## 由 `_editor_model()` 分流，因此这里不再保留任何改装页专属几何常量。
var _survival_modify_index := 0

func _survival_scale() -> float:
	if survival == null or survival.duel == null:
		return 1.0
	return CombatView.fit_scale(DRIVE_VIEW, _battle_camera(survival.duel.arena))

func _survival_to_screen(world: Vector2, scale_factor: float) -> Vector2:
	return CombatView.to_screen(DRIVE_VIEW, _battle_camera(survival.duel.arena), world, scale_factor)

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
	_status_message = "生存：W/S 油门 · A/D 转向 · 鼠标瞄准 · 左键开火（空格备选） · Esc 返回"
	queue_redraw()

func _exit_survival() -> void:
	_survival_held.clear()
	_survival_ready = false
	if survival != null:
		## v3.25：离开生存页前清掉鼠标瞄准覆盖（炮管随 run 一起丢弃，但 `close_run()` 前先复位更清楚）。
		if survival.duel != null:
			var run_bank := survival.duel.bank_of(Duel.TAG_PLAYER)
			if run_bank != null:
				run_bank.clear_aim_override()
		survival.close_run()
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
	## v3.38：Z 一键把相机退回 1.0（仅战斗阶段；改装页的 Z 没有特殊语义）。
	if key == KEY_Z:
		if event.pressed and not event.echo:
			_camera_reset_zoom()
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
			_hit_flash_left = CombatView.HIT_FLASH_TIME
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
		elif kind == "muzzle":
			## 炮口闪光。**所有敌人与玩家走同一条分支**：颜色按 tag 判，不按谁开火。
			var muzzle_colour := Palette.ACCENT_CYAN if String(entry.get("tag", "")) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
			_survival_muzzles.append({
				"pos": Vector2(entry.get("pos", Vector2.ZERO)),
				"dir": Vector2(entry.get("dir", Vector2.RIGHT)),
				"colour": muzzle_colour,
				"left": CombatView.MUZZLE_FLASH_TIME,
			})
			## 同侧限流：生存页一次可能有好几个敌人同时开火，不限制会堆成一片。
			while _survival_muzzles.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
				_survival_muzzles.remove_at(0)
		elif kind == "expire":
			## 射程耗尽消散。`shooter` 是发射方 tag（v3.23 新补的字段）。
			var expire_colour := Palette.ACCENT_CYAN if String(entry.get("shooter", "")) == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
			_survival_expires.append({
				"pos": Vector2(entry.get("pos", Vector2.ZERO)),
				"colour": expire_colour,
				"left": CombatView.EXPIRE_FLASH_TIME,
			})
			while _survival_expires.size() > CombatView.DAMAGE_POPUP_PER_SIDE:
				_survival_expires.remove_at(0)
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

## 伤害悬浮数字：实际逻辑已收归 `CombatView.push_damage()`（与对局页同一份）。
## 符号语义（造成 `+N` / 承受与护盾 `-N`）与同模式限流全在组件里，页面不再维护副本。
func _push_damage_popup(at: Vector2, amount: float, colour: Color, mode: String) -> void:
	CombatView.push_damage(_survival_fx, at, amount, colour, mode)

## 动效倒计时在固定步长里累减，保持确定性（绝不放 `_process`，绝不用 `randf`）。
## 命中闪光、炮口闪光与消散都在固定步长里倒计时；后两者是多实例，走 `_advance_timed()`。
func _survival_tick_fx(step_time: float) -> void:
	if _hit_flash_left > 0.0:
		_hit_flash_left = maxf(_hit_flash_left - step_time, 0.0)
	_survival_fx.step(step_time)
	_advance_timed(_survival_muzzles, step_time)
	_advance_timed(_survival_expires, step_time)

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
		## v3.25：准星最后画。`_draw_aim_reticle()` 内部用 `_is_battle_screen()` 限定
		## 只在 `STAGE_BATTLE` 显示，所以升级页 / 商店页不会在战场上冒出一个环。
		_draw_aim_reticle()
	if survival.stage == SurvivalRun.STAGE_LEVEL_UP:
		_draw_survival_level_up()
	elif survival.stage == SurvivalRun.STAGE_SHOP:
		_draw_survival_shop()
	elif survival.stage == SurvivalRun.STAGE_SUMMARY:
		_draw_survival_summary()

## 生存页战斗视图：与对局页同一份实现的另一组配置——同样的竞技场 / 障碍 / 车体 /
## 动效 / 弹道 / 命中闪光 / 伤害数字函数，只是多传了房屋与残骸（生存模式独有的
## 中立物），并把障碍从格单位换算成像素。**逐项参数、颜色、系数、绘制顺序都与
## 抽取前一一对应**，所以幸存页的像素不应该有任何变化。
func _draw_survival_arena() -> void:
	var duel: Duel = survival.duel
	var scale_factor := _survival_scale()
	var cell_px := float(definitions.global_number("cell_size", 16.0))
	## v3.38：本函数内所有绘制共用**同一个相机矩形**（与另两页同一纪律）。
	var camera := _battle_camera(duel.arena)
	## 竞技场固定障碍直接读数据，避免与 duel.obstacles 里的房屋条目重复绘制。
	## 数据文件用**格单位**，进组件前统一换算成像素（对局页的 obstacles 已是像素）。
	var obstacles := CombatView.scale_obstacles(definitions.get_arena(DRIVE_ARENA_ID).get("obstacles", []), cell_px)
	CombatView.draw_arena(self, DRIVE_VIEW, duel.arena, camera, scale_factor, obstacles, Palette.ACCENT_CYAN)
	## 房屋与残骸是生存模式的专属中立物；同一函数传空数组就是「没有」。
	CombatView.draw_neutrals(self, DRIVE_VIEW, duel.arena, camera, scale_factor, survival.houses, survival.debris, cell_px)
	## 坦克：逐部件按血量上色（完好队伍色 / 中度琥珀 / 濒危红）。
	for raw_tag in duel.alive_tags():
		_draw_survival_hull(String(raw_tag), scale_factor, camera)
	CombatView.draw_fx(self, DRIVE_VIEW, camera, scale_factor, _survival_fx.entries, CombatView.FX_STYLE_SURVIVAL)
	## 消散画在弹道之下（与对局页同一层级）；炮口闪光画在弹道之上。
	_draw_timed_expires(_survival_expires, camera, scale_factor)
	CombatView.draw_shots(self, DRIVE_VIEW, camera, scale_factor, duel.field.shots, Duel.TAG_PLAYER)
	_draw_timed_muzzles(_survival_muzzles, camera, scale_factor)
	## 命中闪光画在炮弹之上，确保不会被格线淹掉。
	CombatView.draw_hit_flash(self, DRIVE_VIEW, camera, scale_factor, _hit_flash_at, _hit_flash_left)
	## 伤害数字画在最后：必须盖在炮弹、命中闪光与所有地形之上。
	CombatView.draw_damage_popups(self, DRIVE_VIEW, camera, scale_factor, _survival_fx.entries, _draw_text)

## 逐部件按**血量比例**上色：完好是队伍色、中度损伤转琥珀、濒危转红、已毁不留格。
## 分档阈值与透明度曲线已收归 `CombatView`，对局页用**同一个函数**——这才是复用的实质。
## 旧版整台只有一种颜色、不看 HP，玩家看不见自己到底打掉了什么——这正是
## 「炮弹似乎不能对敌人造成伤害」的直接感知来源（即使伤害真的算对了）。
func _survival_hull_colour(tag: String, part: Dictionary) -> Color:
	var base := Palette.ACCENT_CYAN if tag == Duel.TAG_PLAYER else Palette.ACCENT_MAGENTA
	if bool(definitions.get_module(String(part["module_id"])).get("core", false)):
		base = Palette.ACCENT_AMBER
	return CombatView.hull_damage_colour(part, base)

## 生存页每部件颜色：`_survival_hull_colour(tag, part)` 的绑定包装（bind 追加在尾）。
func _survival_part_colour(part: Dictionary, tag: String) -> Color:
	return _survival_hull_colour(tag, part)

## 填充透明度随血量下降：一眼能看出哪块被打残了。与对局页共用同一曲线。
func _survival_hull_alpha(part: Dictionary) -> float:
	return CombatView.hull_damage_alpha(part)

func _draw_survival_hull(tag: String, scale_factor: float, camera: Rect2) -> void:
	var hull: TankBody = survival.duel.tank_of(tag)
	if hull == null or hull.parts.is_empty():
		return
	var origin := CombatView.to_screen(DRIVE_VIEW, camera, hull.position, scale_factor)
	var effects := _hull_effects(hull, survival.duel.damage_of(tag), survival.duel.network_of(tag))
	var cell: float = hull.cell_size()
	var pipe_hook := _network_pipe_hook(survival.duel.network_of(tag), cell, scale_factor)
	var cannon_hook := _battle_cannon_hook(survival.duel.bank_of(tag), hull, cell, scale_factor, hull.heading)
	_draw_hull_shared(hull, origin, hull.heading, scale_factor, _survival_part_colour.bind(tag), _survival_hull_alpha, Callable(), Callable(), effects, pipe_hook, _pipe_covered_cells, cannon_hook)


func _draw_survival_hud() -> void:
	var left := DRIVE_HUD_LEFT.position.x
	var right := DRIVE_HUD_RIGHT.position.x
	var boss_mark := " · BOSS" if survival.is_boss_wave() else ""
	var wave_colour := Palette.ACCENT_MAGENTA if survival.is_boss_wave() else Palette.ACCENT_CYAN
	_draw_battle_header("波次 %d%s" % [survival.wave, boss_mark], wave_colour, Vector2(left, 120), 16, "SURVIVE", Vector2(left, 152), 30)
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
	_draw_text("鼠标瞄准 · 左键开火", Vector2(right, 300), 16, Palette.TEXT_HI, false)
	## v3.38：滚轮缩放读数。右 HUD 原键位块是 300 / 330 / 360，
	## 缩放行接到 390，「战斗期禁止改装」从 410 下推到 430 ——
	## 430 + 14 px 字高仍在镜像面板（`SURVIVAL_MIRROR_RECT` 从 y=436 开始）之上，不重叠。
	_draw_text("R        重开 run", Vector2(right, 330), 16, Palette.TEXT_HI, false)
	_draw_text("Esc      返回主菜单", Vector2(right, 360), 16, Palette.TEXT_HI, false)
	_draw_text("滚轮缩放 · Z 复位  %.2f×" % _camera_zoom, Vector2(right, 390), 14, Palette.ACCENT_CYAN, false)
	_draw_text("战斗期禁止改装", Vector2(right, 428), 14, Palette.ACCENT_AMBER, false)
	_draw_survival_mirror()
	_draw_battle_status(_status_message)

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
	## 逐模块特效只算一次，镜像本体与状态行共用同一份结果。
	## 这与战场上用的是同一个 `_hull_effects()`，所以两边显示的进度必然一致。
	var effects := _hull_effects(hull, survival.duel.damage_of(Duel.TAG_PLAYER), survival.duel.network_of(Duel.TAG_PLAYER))
	var effect_parts: Dictionary = effects.get("parts", {})
	var panel := _survival_mirror_panel_rect()
	draw_rect(panel, Color(Palette.BG_BASE, 0.88), true)
	draw_rect(panel, Color(Palette.WIRE, 0.55), false, 1.0)
	var x := panel.position.x + 12.0
	_draw_text("坦克镜像", Vector2(x, panel.position.y + 20.0), 14, Palette.ACCENT_CYAN, false)
	## ② 镜像本体：把坦克格用局部坐标画到面板上部，正北朝上（heading 固定为 0）。
	var mirror_rect := Rect2(x, panel.position.y + 30.0, panel.size.x - 24.0, 132.0)
	_draw_survival_mirror_hull(hull, mirror_rect, effect_parts)
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
	## 每行现在是**两行条**：上面是 HP，下面是模块进度（制造/存量/加工/装填/护盾/维修），
	## 右端有一个 2–3 字的状态词。行高仍是 `MIRROR_ROW_HEIGHT = 22`，没有把面板撑高。
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
	var row_width := panel.size.x - 24.0
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
		var effect: Dictionary = effect_parts.get(String(part.get("key", "")), {})
		_draw_text(label.substr(0, 6), Vector2(x, row_y), 12, colour, false)
		## 状态词：只有真的拿到模块状态时才画，否则留空（不编造“正常”字样）。
		var word := String(effect.get("word", ""))
		if not word.is_empty():
			var word_colour: Color = effect.get("word_colour", Palette.TEXT_LO)
			_draw_text(word, Vector2(x + 96.0, row_y), 11, word_colour, false)
		_draw_text("%d%%" % int(roundf(ratio * 100.0)), Vector2(panel.position.x + panel.size.x - 44.0, row_y), 11, colour, true)
		## HP 条（上）与模块进度条（下）。模块条只在有进度语义时画。
		var hp_bar := Rect2(x, row_y + 4.0, row_width, 2.5)
		draw_rect(hp_bar, Color(Palette.WIRE, 0.28), true)
		draw_rect(Rect2(hp_bar.position, Vector2(hp_bar.size.x * ratio, hp_bar.size.y)), colour, true)
		if float(effect.get("bar", -1.0)) >= 0.0:
			var module_bar := Rect2(x, row_y + 8.0, row_width, 2.5)
			var module_colour: Color = effect.get("bar_colour", Palette.ACCENT_AMBER)
			draw_rect(module_bar, Color(Palette.WIRE, 0.22), true)
			draw_rect(Rect2(module_bar.position, Vector2(module_bar.size.x * clampf(float(effect["bar"]), 0.0, 1.0), module_bar.size.y)), module_colour, true)
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
##
## v3.21：除 HP 底色外，有模块状态的格再叠一层**特效色**（护盾绿 / 装填琥珀 / 维修绿）
## 并在格底部画一条 2 px 迷你进度条——镜像窗口小，单靠颜色分不出“在装填”还是“在制造”，
## 进度条长度才能表达“还差多少”。
func _draw_survival_mirror_hull(hull: TankBody, area: Rect2, effect_parts: Dictionary = {}) -> void:
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
		var effect: Dictionary = effect_parts.get(String(part.get("key", "")), {})
		for raw_cell in part["cells"]:
			var cell_value: Vector2i = raw_cell
			var centre_local: Vector2 = (Vector2(cell_value) + Vector2(0.5, 0.5)) * cell
			var at := origin + centre_local * fit
			var box := Rect2(at - Vector2(cell, cell) * 0.5 * fit, Vector2(cell, cell) * fit)
			draw_rect(box, Color(colour, 0.16 + 0.26 * ratio), true)
			draw_rect(box, colour, false, 1.0)
			if float(effect.get("bar", -1.0)) >= 0.0:
				var mini_colour: Color = effect.get("bar_colour", Palette.ACCENT_AMBER)
				var mini_height := maxf(2.0, box.size.y * 0.22)
				var mini := Rect2(Vector2(box.position.x, box.end.y - mini_height), Vector2(box.size.x, mini_height))
				draw_rect(mini, Color(Palette.BG_BASE, 0.7), true)
				draw_rect(Rect2(mini.position, Vector2(mini.size.x * clampf(float(effect["bar"]), 0.0, 1.0), mini.size.y)), mini_colour, true)
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
			_draw_text("领到即装入改进装置的空槽；无空槽则暂存", rect.position + Vector2(18.0, rect.size.y - 40.0), 13, Palette.TEXT_LO, false)
	## v3.24：上一次领奖的实际去向（已装入哪件改进器 / 无空槽已暂存）。
	## 之前这里只写「注入改装池」，而那个注入从未实现——玩家永远看不到升级去哪了。
	if not survival.upgrade_note.is_empty():
		_draw_text(survival.upgrade_note, Vector2(DRIVE_VIEW.position.x + 32.0, DRIVE_VIEW.position.y + DRIVE_VIEW.size.y - 56.0), 15, Palette.ACCENT_AMBER, true)
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
	_status_message = "改装：1/2/3 选层 · A/D 选件 · 回车贴装 · X 拆解 · 改进器上 Q/E 选升级、T 加槽、Shift+T 清空 · Esc 完成"
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
	## v3.24：截图里必须能看见改进装置的端口箭头 —— 起始车本来没有改进器，
	## 这里给一张 `modifier_mk1` 并真的装到刚铺的那一格上（走 `mount_from_inventory`，
	## 与玩家手动装同一条路径），再给它配一个升级槽。**仅截图钩子如此，不改起始车。**
	if not survival.inventory.has("modifier_mk1"):
		survival.inventory.append("modifier_mk1")
	var modifier_index := survival.inventory.find("modifier_mk1")
	if modifier_index >= 0:
		survival.mount_from_inventory(modifier_index, extra, 0, 0)
		survival_builder.set_modifier_upgrades(extra, ["up_damage"])
	_cursor = extra
	_survival_modify_index = 0
	_build_layer = LAYER_MODULE
	_survival_event = "改装：选库存配件后回车贴装"
