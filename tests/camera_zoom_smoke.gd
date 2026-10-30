extends SceneTree

## v3.38 战斗相机缩放回归（design §11.4.2.18）。
##
## 为什么必须有这个测试：
## 缩放改的是**一条几何变换**，而这条变换同时被「绘制」与「鼠标瞄准」两条路径使用。
## 只要它们不同源，玩家就会看到「炮管朝这里、炮弹朝那里」——而这在 headless 探针里
## 完全看不出来（探针不画图），在截图上也要凑巧打中才看得出来。
## 所以这里把「往返一致」钉成逐步断言，并且**逐个 zoom 值**都验一遍。
##
## 覆盖：
##  - `zoom == 1.0` 时 `camera_rect()` **原样返回 arena**（不算任何乘除）——
##    这是「默认像素与 v3.37 逐字节相同」的构造性保证；
##  - `camera_rect()` 的尺寸确实是 `arena.size / zoom`；
##  - 放大时相机比竞技场小、缩小时比竞技场大，且都夹在竞技场内（不露出多余空白）；
##  - 任意 zoom 下 `to_screen()` → `to_world()` 往返一致（含四个角与中心）；
##  - 相机中心对应的屏幕点恒为视图中心；
##  - `fit_scale()` 随 zoom 单调递增，且 `fit_scale(view, camera) == fit_scale(view, arena) * zoom`；
##  - 滚轮步进：`_camera_zoom_by()` 在上下界处夹住，`Z` 复位回到 1.0；
##  - 负向对照：故意用「旧版不带相机的 `to_screen`」换算同一个屏幕点，
##    在 zoom != 1 时必须得到**不同**的世界点——否则本测试对缩放根本不敏感。
##
## 硬约束：本测试**不调任何绘制函数**（在 `_draw()` 之外调绘制会刷屏上千行
## `Drawing is only allowed inside this node's _draw()`，把断言淹掉）。

const CombatView := preload("res://scripts/combat_view.gd")
const MainScript := preload("res://scripts/main.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")

const TOL := 0.0001

const VIEW := Rect2(320.0, 168.0, 1216.0, 684.0)
const ARENA := Rect2(0.0, 0.0, 2048.0, 1152.0)

var _failures := 0
var _checks := 0

func _init() -> void:
	_check_identity_camera()
	_check_camera_size()
	_check_camera_clamped()
	_check_round_trip()
	_check_centre_maps_to_view_centre()
	_check_fit_scale_scales()
	_check_zoom_step_bounds()
	_check_negative_control()
	_check_aim_uses_camera()
	_check_aim_wiring()

	if _failures == 0:
		print("CAMERA_OK checks=%d" % _checks)
		quit(0)
		return
	quit(1)

func _fail(code: String) -> void:
	_failures += 1
	printerr(code)

func _check(condition: bool, code: String) -> void:
	_checks += 1
	if not condition:
		_fail(code)

func _check_near(actual: float, expected: float, code: String) -> void:
	_checks += 1
	if absf(actual - expected) > TOL:
		_fail("%s actual=%.6f expected=%.6f" % [code, actual, expected])

## `zoom == 1.0` 必须**原样**返回 arena：不是「数值相等」，而是同一个 Rect2。
## 这一条是整个「默认像素不变」的根 —— 一旦变成返回「算出来的等值矩形」，
## 浮点乘除就可能让 `to_screen()` 的最后一位变掉，历史截图基线随之失效。
func _check_identity_camera() -> void:
	for focus in [ARENA.get_center(), Vector2(0.0, 0.0), Vector2(2048.0, 1152.0), Vector2(500.0, 900.0)]:
		var camera := CombatView.camera_rect(ARENA, focus, 1.0)
		_check(camera == ARENA, "identity_camera_%.0f_%.0f" % [focus.x, focus.y])
	## 退化 zoom（0 或负）也必须回退到 arena，而不是除零。
	_check(CombatView.camera_rect(ARENA, ARENA.get_center(), 0.0) == ARENA, "identity_camera_zero_zoom")
	_check(CombatView.camera_rect(ARENA, ARENA.get_center(), -2.0) == ARENA, "identity_camera_negative_zoom")

## 相机尺寸就是 `arena.size / zoom`，两个轴都要。
func _check_camera_size() -> void:
	for zoom in [0.5, 0.75, 1.5, 2.0, 4.0]:
		var camera := CombatView.camera_rect(ARENA, ARENA.get_center(), zoom)
		_check_near(camera.size.x, ARENA.size.x / zoom, "camera_width_z%.2f" % zoom)
		_check_near(camera.size.y, ARENA.size.y / zoom, "camera_height_z%.2f" % zoom)

## 放大时相机在竞技场内；不放大时中心不偏移（不能因为焦点在角落而露白）。
func _check_camera_clamped() -> void:
	## 放大 + 焦点在角落：相机必须被夹回竞技场内（完全包含于竞技场）。
	var corner := CombatView.camera_rect(ARENA, Vector2(0.0, 0.0), 4.0)
	_check(corner.position.x >= ARENA.position.x - TOL, "clamp_corner_left")
	_check(corner.position.y >= ARENA.position.y - TOL, "clamp_corner_top")
	_check(corner.end.x <= ARENA.end.x + TOL, "clamp_corner_right")
	_check(corner.end.y <= ARENA.end.y + TOL, "clamp_corner_bottom")
	## 缩小：相机比竞技场大，中心必须与竞技场中心重合（两侧空白一样多）。
	var wide := CombatView.camera_rect(ARENA, Vector2(10.0, 20.0), 0.5)
	_check_near(wide.get_center().x, ARENA.get_center().x, "wide_centre_x")
	_check_near(wide.get_center().y, ARENA.get_center().y, "wide_centre_y")
	_check(wide.size.x > ARENA.size.x, "wide_is_wider")

## 任意 zoom 下，世界点 → 屏幕 → 世界必须回到原点。
## 这是「画出来的炮管」与「真实开火方向」不脱节的形式化条件。
func _check_round_trip() -> void:
	var probes: Array = [
		ARENA.position,
		ARENA.get_center(),
		ARENA.end,
		Vector2(0.0, 1152.0),
		Vector2(2048.0, 0.0),
		Vector2(300.0, 700.0),
	]
	for zoom in [0.5, 0.75, 1.0, 1.35, 2.0, 3.0, 4.0]:
		var camera := CombatView.camera_rect(ARENA, Vector2(900.0, 420.0), zoom)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		for world in probes:
			var screen := CombatView.to_screen(VIEW, camera, world, scale_factor)
			var back: Vector2 = MainScript._screen_to_world(VIEW, camera, screen, scale_factor)
			_check_near(back.x, world.x, "round_trip_x_z%.2f_%.0f" % [zoom, world.x])
			_check_near(back.y, world.y, "round_trip_y_z%.2f_%.0f" % [zoom, world.y])

## 相机的中心必须落在这个视图的中心 —— 这是「放大时看到的还是刚才那片区域」的定义。
func _check_centre_maps_to_view_centre() -> void:
	for zoom in [0.5, 1.0, 2.0, 4.0]:
		var camera := CombatView.camera_rect(ARENA, Vector2(1100.0, 640.0), zoom)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		var at := CombatView.to_screen(VIEW, camera, camera.get_center(), scale_factor)
		_check_near(at.x, VIEW.position.x + VIEW.size.x * 0.5, "centre_x_z%.2f" % zoom)
		_check_near(at.y, VIEW.position.y + VIEW.size.y * 0.5, "centre_y_z%.2f" % zoom)

## 比例必须随 zoom 线性放大：`fit_scale(view, camera) == fit_scale(view, arena) * zoom`。
## 这条一旦不成立，炮口闪光的长度、进度条的厚度、格线的间距就会各走各的。
func _check_fit_scale_scales() -> void:
	var base := CombatView.fit_scale(VIEW, ARENA)
	for zoom in [0.5, 0.75, 1.0, 1.5, 2.0, 4.0]:
		var camera := CombatView.camera_rect(ARENA, ARENA.get_center(), zoom)
		_check_near(CombatView.fit_scale(VIEW, camera), base * zoom, "fit_scale_z%.2f" % zoom)
	## 退化相机必须回退 1.0，而不是除零。
	_check_near(CombatView.fit_scale(VIEW, Rect2()), 1.0, "fit_scale_degenerate")

## 滚轮步进与上下界（纯算术，不碰实例）。
func _check_zoom_step_bounds() -> void:
	var step := MainScript.CAMERA_ZOOM_STEP
	var low := MainScript.CAMERA_ZOOM_MIN
	var high := MainScript.CAMERA_ZOOM_MAX
	_check(step > 1.0, "step_above_one")
	_check(low < 1.0 and high > 1.0, "range_straddles_one")
	## 连续放大到底不能超过上界；连续缩小到底不能低于下界。
	var zoom := 1.0
	for _i in range(40):
		zoom = clampf(zoom * step, low, high)
	_check_near(zoom, high, "zoom_ceiling")
	zoom = 1.0
	for _i in range(40):
		zoom = clampf(zoom / step, low, high)
	_check_near(zoom, low, "zoom_floor")
	## 上界必须足以「看清细节」（一格 >= 30 屏幕像素），下界必须足以「看到整张图外带余量」。
	var base := CombatView.fit_scale(VIEW, ARENA)
	_check(16.0 * base * high >= 30.0, "ceiling_readable_cell")
	_check(ARENA.size.x / low > ARENA.size.x, "floor_shows_whole_map")

## 负向对照：把「无相机」的旧换算拿来比，zoom != 1 时必须得到不同结果。
## 如果这条不成立，说明本测试对缩放完全不敏感 —— 那它就是在自证。
func _check_negative_control() -> void:
	var screen := Vector2(700.0, 500.0)
	var zoom := 2.0
	var camera := CombatView.camera_rect(ARENA, ARENA.get_center(), zoom)
	var with_camera: Vector2 = MainScript._screen_to_world(VIEW, camera, screen, CombatView.fit_scale(VIEW, camera))
	var old_style: Vector2 = MainScript._screen_to_world(VIEW, ARENA, screen, CombatView.fit_scale(VIEW, ARENA))
	_check(with_camera.distance_to(old_style) > 1.0, "negative_control_detects_zoom")
	## 反向：zoom == 1 时两者必须**完全相等**（相机就是 arena）。
	var same_camera := CombatView.camera_rect(ARENA, ARENA.get_center(), 1.0)
	var a: Vector2 = MainScript._screen_to_world(VIEW, same_camera, screen, CombatView.fit_scale(VIEW, same_camera))
	var b: Vector2 = MainScript._screen_to_world(VIEW, ARENA, screen, CombatView.fit_scale(VIEW, ARENA))
	_check(a == b, "negative_control_identity_at_one")

## 缩放后「鼠标矄准」仍然打在矄星下的世界点上：
## 用真实 `TankBody` + `CannonBank`，让炮管朝「某个屏幕点对应的世界点」，
## 再验证 `muzzle_dir()` 精确等于「炮管中心 → 那个世界点」。
##
## `TankBody` 不需要完整蓝图：`_cell_size` 缺省就是 16.0，`centroid_local` 缺省为 0，
## 而 `aim_at()` 只读 `heading` / `position` / `world_position_of_cell()`。
func _check_aim_uses_camera() -> void:
	var body := TankBody.new()
	body.position = Vector2(1024.0, 576.0)
	body.heading = 0.0
	var bank := CannonBank.new()
	bank.body = body
	bank.cannons = [{
		"cell": Vector2i(0, 0),
		"module_id": "cannon_76",
		"aim": 0.0,
		"aim_override": false,
		"aim_world": 0.0,
	}]
	for zoom in [0.5, 1.0, 2.5, 4.0]:
		var camera := CombatView.camera_rect(ARENA, body.position, zoom)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		## 屏幕上一个明显偏离中心的点（用于区分 zoom 的影响）。
		var screen := VIEW.position + Vector2(VIEW.size.x * 0.78, VIEW.size.y * 0.30)
		var world: Vector2 = MainScript._screen_to_world(VIEW, camera, screen, scale_factor)
		## 反向确认：把这个世界点画回屏幕必须回到原屏幕点。
		var back := CombatView.to_screen(VIEW, camera, world, scale_factor)
		_check_near(back.x, screen.x, "aim_screen_back_x_z%.2f" % zoom)
		_check_near(back.y, screen.y, "aim_screen_back_y_z%.2f" % zoom)
		## 再让炮管指过去，方向必须等于「炮管中心 → world」。
		var cannon: Dictionary = bank.cannons[0]
		var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
		var expected := (world - centre).normalized()
		bank.aim_at(0, world)
		var got := bank.muzzle_dir(cannon)
		_check_near(got.x, expected.x, "aim_dir_x_z%.2f" % zoom)
		_check_near(got.y, expected.y, "aim_dir_y_z%.2f" % zoom)

## 接线断言：`_aim_with_mouse()` 必须把 `_battle_view()` 的 **camera** 传下去，
## 不能只传 arena。这是 v3.37 那类「两套推导」缺陷的静态版防护 ——
## 纯几何断言对它无效（几何全对，但页面没把相机接上）。
##
## 按 v3.37 的教训：**剔掉注释行**再审查，否则注释里解释相机的话会被当成违规。
func _check_aim_wiring() -> void:
	var file := FileAccess.open("res://scripts/main.gd", FileAccess.READ)
	if file == null:
		_fail("aim_wiring_cannot_open_main")
		return
	var source := file.get_as_text()
	file.close()
	var start := source.find("func _aim_with_mouse(")
	if start < 0:
		_fail("aim_wiring_missing_function")
		return
	var tail := source.substr(start)
	var next_func := tail.find("\nfunc ", 1)
	if next_func > 0:
		tail = tail.substr(0, next_func)
	## 剔掉注释行：只看真正会执行的代码。
	var code_lines: Array = []
	for line in tail.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		code_lines.append(trimmed)
	var body_code := "\n".join(code_lines)
	## 正向：必须把 `camera` 传下去，而不是只传 `arena`。
	_check(body_code.contains("info.get(\"camera\""), "aim_wiring_passes_camera")
	_check(body_code.contains("_aim_player_cannons("), "aim_wiring_calls_player_cannons")
	## 内置反向对照串：确认上面的匹配模式确实有区分力 ——
	## 这是一个「只传 arena」的旧版本代码，它必须**不**含 `info.get("camera"`。
	var bad := "return _aim_player_cannons(info.get(\"view\", Rect2()), info.get(\"arena\", Rect2()), float(info.get(\"scale\", 1.0)), position)"
	_check(not bad.contains("info.get(\"camera\""), "aim_wiring_negative_control")
