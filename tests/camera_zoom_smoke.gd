extends SceneTree

## v3.40 战斗场景相机推拉回归（design §11.4.2.20）。
##
## 为什么必须有这个测试：
## 相机改的是**一条几何变换**，而这条变换同时被「绘制」与「鼠标瞄准」两条路径使用。
## 只要它们不同源，玩家就会看到「炮管朝这里、炮弹朝那里」——这在 headless 探针里
## 完全看不出来（探针不画图），在截图上也要凑巧打中才看得出来。
##
## v3.38 的模型是「相机矩形 = 竞技场 ÷ 倍数」，倍数 < 1 时**相机比地图还大**：
## 实测 0.5× 时相机 4096×2304、四边各溢出 1024/576 世界像素、**视图 75% 是空白**，
## 整张地图缩成中间 608×342 的小方块。那不是相机，是「把地图在桌上缩放」。
## v3.40 换成真实相机模型：状态是**距离**（视野覆盖的世界高，px），
## 远 = 整图恰好铺满视野，近 = 一格 38 屏幕像素。
##
## 本测试的**核心断言是「相机永远不超出竞技场」**（`_check_never_exceeds_arena`）——
## 它直接来自用户要的镜头语言（相机不该看到世界之外），且旧模型会在这里成批失败。
## 这不是「复算一遍实现」：溢出判据只用到 Rect2 的四个边界，与 `camera_at_height()`
## 内部的夹取写法无关。配套的 `_check_negative_control` 把旧 0.5× 公式**独立重算**
## 一遍并断言它必须溢出，用来证明本测试对旧缺陷真的敏感。
##
## 覆盖：
##  - 最远端点 `height >= arena.size.y` 时 `camera_at_height()` **原样返回 arena**
##    （同一个 Rect2、零乘除）—— 这是「默认像素与 v3.37 逐字节相同」的构造性保证；
##  - 任意焦点 × 任意距离下相机都**完全包含于**竞技场，且尺寸不超过竞技场；
##  - 宽高比永不改变（宽 = 高 × 竞技场宽高比），相机在任何距离下恰好铺满视图；
##  - 任意距离下 `to_screen()` → `to_world()` 往返一致（含四角与中心）；
##  - 相机中心对应的屏幕点恒为视图中心；
##  - `fit_scale()` 随距离变小而变大，两端点可复算：最远 9.5 px/格、最近 38 px/格；
##  - 读数换算 `camera_mag()` / `camera_height_for_mag()` 的边界与单调；
##  - 滚轮步进在上下界处夹住（读数维夹取，不是距离维）；
##  - 负向对照：旧 0.5× 公式必须溢出竞技场，新模型同一位置必须正好等于竞技场。
##
## 硬约束：本测试**不调任何绘制函数**（在 `_draw()` 之外调绘制会刷屏上千行
## `Drawing is only allowed inside this node's _draw()`，把断言淹掉）。

const CombatView := preload("res://scripts/combat_view.gd")
const MainScript := preload("res://scripts/main.gd")
const TankBody := preload("res://scripts/tank_body.gd")
const CannonBank := preload("res://scripts/cannon_bank.gd")
## v3.42：战场渲染容器（`SubViewport` + `Camera2D`）。
const BattleViewport := preload("res://scripts/battle_viewport.gd")

const TOL := 0.0001

const VIEW := Rect2(320.0, 168.0, 1216.0, 684.0)
const ARENA := Rect2(0.0, 0.0, 2048.0, 1152.0)
## 最远 = 整张地图 = 竞技场高。这个数不是拍的：任何比它更大的距离都等价于它。
const FAR := 1152.0
const CENTRE := Vector2(1024.0, 576.0)

var _failures := 0
var _checks := 0

func _init() -> void:
	_check_far_identity()
	_check_never_exceeds_arena()
	_check_aspect_never_changes()
	_check_round_trip()
	_check_centre_maps_to_view_centre()
	_check_fit_scale_monotonic()
	_check_mag_bounds()
	_check_zoom_step_bounds()
	_check_aim_uses_camera()
	_check_aim_wiring()
	_check_battle_viewport_geometry()
	_check_battle_viewport_wiring()
	## v3.45：这一条从 v3.40 重写时就定义在文件里，但 **从未被 `_init()` 调用**。
	## 它是全文件唯一「对旧缺陷敏感度」的证明（独立重算 v3.38 的旧 0.5× 公式并断言它必须溢出），
	## 不接入的话，「本测试对旧缺陷真的敏感」就只是注释里的一句话。
	_check_negative_control()

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

## 最远端点必须**原样**返回 arena：不是「数值相等」，而是同一个 Rect2。
## 这一条是整个「默认像素不变」的根 —— 一旦改成返回「算出来的等值矩形」，
## 浮点乘除就可能让 `to_screen()` 的最后一位变掉，历史截图基线随之失效。
## 比对用 `==`（Rect2 逐字段相等），容差在这里是**错误**的做法。
func _check_far_identity() -> void:
	for focus in [CENTRE, Vector2(0.0, 0.0), Vector2(2048.0, 1152.0), Vector2(500.0, 900.0)]:
		_check(CombatView.camera_at_height(ARENA, focus, FAR) == ARENA,
			"far_identity_%.0f_%.0f" % [focus.x, focus.y])
	## 比最远更远（包括用户滚到底）也必须落在恒等分支上。
	_check(CombatView.camera_at_height(ARENA, CENTRE, FAR * 2.0) == ARENA, "far_identity_double")
	_check(CombatView.camera_at_height(ARENA, CENTRE, 99999.0) == ARENA, "far_identity_huge")
	## 退化竞技场（未进入战斗页时 arena 是空 Rect2）必须原样回退，而不是除零或崩溃。
	_check(CombatView.camera_at_height(Rect2(), CENTRE, 500.0) == Rect2(), "far_identity_empty_arena")
	_check(CombatView.camera_at_height(Rect2(), CENTRE, FAR) == Rect2(), "far_identity_empty_arena_far")

## 【核心断言】任意焦点、任意距离下，相机都不得越出竞技场一步。
##
## 这条判据只用到 Rect2 的四个边界，**不引用 `camera_at_height()` 的任何中间量**，
## 所以它不会像 v3.39 的弧管测试那样与实现同错。旧模型在这里会成批失败
## （0.5× 时四边各溢出 1024/576）。
##
## 距离表里同时放了「刚好比最远小一点点」（`FAR - 0.001`）—— 那是插值吸附之前
## 最容易踩到边界的一档；也放了 0 与负数这种不该出现的退化输入，
## 它们至少不能生成比竞技场更大的相机。
func _check_never_exceeds_arena() -> void:
	var focuss: Array = [
		Vector2(0.0, 0.0),
		Vector2(2048.0, 1152.0),
		CENTRE,
		Vector2(500.0, 900.0),
		Vector2(1024.0, 0.0),
	]
	var heights: Array = [
		FAR * 2.0,
		FAR * 1.5,
		99999.0,
		FAR,
		FAR - 0.001,
		FAR * 0.75,
		FAR * 0.5,
		FAR * 0.25,
		FAR * 0.1,
		1.0,
		0.0,
		-50.0,
	]
	for focus in focuss:
		for height in heights:
			var camera := CombatView.camera_at_height(ARENA, focus, float(height))
			var tag := "f%.0f_%.0f_h%.3f" % [focus.x, focus.y, float(height)]
			_check(camera.position.x >= ARENA.position.x - TOL, "inside_left_" + tag)
			_check(camera.position.y >= ARENA.position.y - TOL, "inside_top_" + tag)
			_check(camera.end.x <= ARENA.end.x + TOL, "inside_right_" + tag)
			_check(camera.end.y <= ARENA.end.y + TOL, "inside_bottom_" + tag)
			_check(camera.size.x <= ARENA.size.x + TOL, "not_wider_" + tag)
			_check(camera.size.y <= ARENA.size.y + TOL, "not_taller_" + tag)

## 宽高比永不改变，且相机恰好铺满视图（既无 letterbox 也无裁切）。
##
## 一旦宽高比漂移，`fit_scale()` 只按宽度算，画面在纵向就会错位 —— 地图的
## 上下边缘会被切掉或者露出空白。本项目视图与竞技场同为 16:9，所以「恒等」是可达的。
func _check_aspect_never_changes() -> void:
	var ratio := ARENA.size.x / ARENA.size.y
	var heights: Array = [FAR * 0.25, FAR * 0.5, FAR * 0.75, 700.0, 1000.0, FAR - 0.001, FAR]
	for height in heights:
		var h := float(height)
		var camera := CombatView.camera_at_height(ARENA, Vector2(300.0, 200.0), h)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		var tag := "h%.3f" % h
		_check_near(camera.size.y, h, "camera_height_is_distance_" + tag)
		_check_near(camera.size.x, h * ratio, "camera_width_follows_aspect_" + tag)
		_check_near(camera.size.x * scale_factor, VIEW.size.x, "covers_view_width_" + tag)
		_check_near(camera.size.y * scale_factor, VIEW.size.y, "covers_view_height_" + tag)
	## 退化相机必须回退 1.0，而不是除零。
	_check_near(CombatView.fit_scale(VIEW, Rect2()), 1.0, "fit_scale_degenerate")

## 任意距离下，世界点 → 屏幕 → 世界必须回到原点。
## 这是「画出来的炮管」与「真实开火方向」不脱节的形式化条件。
func _check_round_trip() -> void:
	var probes: Array = [
		ARENA.position,
		CENTRE,
		ARENA.end,
		Vector2(0.0, 1152.0),
		Vector2(2048.0, 0.0),
		Vector2(300.0, 700.0),
	]
	var heights: Array = [FAR, FAR * 0.75, FAR * 0.5, FAR * 0.25, 700.0, 900.0]
	for height in heights:
		var h := float(height)
		var camera := CombatView.camera_at_height(ARENA, Vector2(900.0, 420.0), h)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		for world in probes:
			var screen := CombatView.to_screen(VIEW, camera, world, scale_factor)
			var back: Vector2 = MainScript._screen_to_world(VIEW, camera, screen, scale_factor)
			_check_near(back.x, world.x, "round_trip_x_h%.1f_%.0f" % [h, world.x])
			_check_near(back.y, world.y, "round_trip_y_h%.1f_%.0f" % [h, world.y])

## 相机的中心必须落在这个视图的中心 —— 这是「拉近后看到的还是刚才那片区域」的定义。
## 焦点取竞技场中心：贴边时焦点会被夹住（不越界优先于永远居中），那属于设计取舍，
## 不能用「必须居中」去断言它。
func _check_centre_maps_to_view_centre() -> void:
	var heights: Array = [FAR, FAR * 0.5, FAR * 0.25, 400.0]
	for height in heights:
		var h := float(height)
		var camera := CombatView.camera_at_height(ARENA, CENTRE, h)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		var at := CombatView.to_screen(VIEW, camera, camera.get_center(), scale_factor)
		_check_near(at.x, VIEW.position.x + VIEW.size.x * 0.5, "centre_x_h%.1f" % h)
		_check_near(at.y, VIEW.position.y + VIEW.size.y * 0.5, "centre_y_h%.1f" % h)
		## 焦点在竞技场中心时相机中心就该等于焦点本身。
		_check_near(camera.get_center().x, CENTRE.x, "camera_centre_is_focus_x_h%.1f" % h)
		_check_near(camera.get_center().y, CENTRE.y, "camera_centre_is_focus_y_h%.1f" % h)

## 比例必须随距离变小而变大（推近），而且两端点要能复算成用户可理解的可读度。
##
## 最远：`16 × 1216 / 2048 = 9.5` 屏幕像素/格（整图铺满视图）；
## 最近：`16 × 684 / 288 = 38` 屏幕像素/格（与建造页 32 px 格同等级）。
## 这两个数是从 `DRIVE_VIEW` / `ARENA` / `CELL_SIZE` / `CAMERA_MAG_MAX` 独立推出的，
## 不是从实现里抄的。
func _check_fit_scale_monotonic() -> void:
	var base := CombatView.fit_scale(VIEW, ARENA)
	_check_near(16.0 * base, 9.5, "far_cell_px")
	var near_dist := CombatView.camera_height_for_mag(ARENA, MainScript.CAMERA_MAG_MAX)
	_check_near(near_dist, 288.0, "near_distance_is_camera_mag_max")
	var near_camera := CombatView.camera_at_height(ARENA, CENTRE, near_dist)
	_check_near(16.0 * CombatView.fit_scale(VIEW, near_camera), 38.0, "near_cell_px")
	## 距离变小 → 比例变大，单调且严格。
	var previous := -1.0
	for height in [FAR, FAR * 0.75, FAR * 0.5, FAR * 0.3, FAR * 0.25]:
		var camera := CombatView.camera_at_height(ARENA, CENTRE, float(height))
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		_check(scale_factor > previous, "fit_scale_monotonic_h%.1f" % float(height))
		previous = scale_factor
	## 读数与距离互为逆：任一读数折成距离再折回来必须相等。
	for mag in [1.0, 1.35, 2.0, 2.35, 3.0, 4.0]:
		var dist := CombatView.camera_height_for_mag(ARENA, float(mag))
		_check_near(CombatView.camera_mag(ARENA, dist), float(mag), "mag_round_trip_%.2f" % float(mag))

## 读数换算的边界。
##
## `mag < 1` 一律当成最远 —— 模型里**不存在**「比整张地图更远的视角」，
## 这正是 `CAMERA_ZOOM_MIN := 0.5` 被永久删除的原因：它表达的语义已经不可构造。
func _check_mag_bounds() -> void:
	_check_near(CombatView.camera_mag(ARENA, FAR), 1.0, "mag_at_far")
	_check_near(CombatView.camera_mag(ARENA, FAR * 0.5), 2.0, "mag_at_half")
	_check_near(CombatView.camera_mag(ARENA, FAR * 0.25), 4.0, "mag_at_quarter")
	_check_near(CombatView.camera_height_for_mag(ARENA, 1.0), FAR, "dist_at_mag_one")
	_check_near(CombatView.camera_height_for_mag(ARENA, 2.0), FAR * 0.5, "dist_at_mag_two")
	_check_near(CombatView.camera_height_for_mag(ARENA, 4.0), FAR * 0.25, "dist_at_mag_four")
	## 比整图更远不存在：0.5 / 0 / 负数一律折成最远。
	_check_near(CombatView.camera_height_for_mag(ARENA, 0.5), FAR, "dist_mag_below_one")
	_check_near(CombatView.camera_height_for_mag(ARENA, 0.0), FAR, "dist_mag_zero")
	_check_near(CombatView.camera_height_for_mag(ARENA, -3.0), FAR, "dist_mag_negative")
	## 退化输入回退，不除零。
	_check_near(CombatView.camera_height_for_mag(Rect2(), 2.0), 0.0, "dist_empty_arena")
	_check_near(CombatView.camera_mag(ARENA, 0.0), 1.0, "mag_zero_height")
	_check_near(CombatView.camera_mag(Rect2(), 100.0), 1.0, "mag_empty_arena")

## 滚轮步进：夹取发生在**读数维**（不是距离维，距离维的边界是非线性的）。
## 连续推拉到底必须收敛到两个端点，不能无限逼近。
func _check_zoom_step_bounds() -> void:
	var step: float = MainScript.CAMERA_ZOOM_STEP
	var high: float = MainScript.CAMERA_MAG_MAX
	_check(step > 1.0, "step_above_one")
	_check_near(high, 4.0, "mag_max_is_four")
	var mag := 1.0
	for _i in range(40):
		mag = clampf(mag * step, 1.0, high)
	_check_near(mag, high, "mag_ceiling")
	mag = high
	for _i in range(40):
		mag = clampf(mag / step, 1.0, high)
	_check_near(mag, 1.0, "mag_floor")
	## 从整图到最近应该是 8–12 档：太少则一滚就到底，太多则「滚半天还没拉近」。
	var bump := 0
	mag = 1.0
	while mag < high - 0.0001 and bump < 100:
		mag = clampf(mag * step, 1.0, high)
		bump += 1
	_check(bump >= 8 and bump <= 12, "mag_step_count_sane_actual_%d" % bump)
	## 最近端点必须真的比最远「看得清」：一格 >= 30 屏幕像素。
	var nearest := CombatView.camera_height_for_mag(ARENA, high)
	var nearest_camera := CombatView.camera_at_height(ARENA, CENTRE, nearest)
	_check(16.0 * CombatView.fit_scale(VIEW, nearest_camera) >= 30.0, "ceiling_readable_cell")

## 负向对照：**独立重算** v3.38 的旧公式（不是调用它，它已被删除），
## 断言它必须溢出竞技场。如果这条不成立，说明本测试对旧缺陷不敏感 ——
## 那它就是在替实现背书（v3.39 弧管测试连续四个版本假绿的教训）。
func _check_negative_control() -> void:
	var old_zoom := 0.5
	var old_half: Vector2 = ARENA.size * 0.5 / old_zoom
	var old_camera := Rect2(ARENA.get_center() - old_half, old_half * 2.0)
	var overflow_x: float = old_camera.end.x - ARENA.end.x
	var overflow_y: float = old_camera.end.y - ARENA.end.y
	_check(overflow_x > 1.0, "negative_old_overflows_right")
	_check(overflow_y > 1.0, "negative_old_overflows_bottom")
	_check(ARENA.position.x - old_camera.position.x > 1.0, "negative_old_overflows_left")
	## 旧相机比竞技场大 —— 这正是「视图 75% 是空白」的来源。
	_check(old_camera.size.y > ARENA.size.y + 1.0, "negative_old_taller_than_arena")
	## 同一「读数」在新模型里必须正好是整图（合法的极限），绝不溢出。
	var new_camera := CombatView.camera_at_height(
		ARENA, CENTRE, CombatView.camera_height_for_mag(ARENA, old_zoom))
	_check(new_camera == ARENA, "negative_new_is_identity_at_below_one_mag")
	## 旧相机与新相机对同一个屏幕点给出**不同**的世界点：本测试对相机模型敏感。
	var screen := Vector2(700.0, 500.0)
	var with_old: Vector2 = MainScript._screen_to_world(
		VIEW, old_camera, screen, CombatView.fit_scale(VIEW, old_camera))
	var with_new: Vector2 = MainScript._screen_to_world(
		VIEW, new_camera, screen, CombatView.fit_scale(VIEW, new_camera))
	_check(with_old.distance_to(with_new) > 1.0, "negative_models_disagree")

## 拉近后「鼠标瞄准」仍然打在准星下的世界点上：
## 用真实 `TankBody` + `CannonBank`，让炮管朝「某个屏幕点对应的世界点」，
## 再验证 `muzzle_dir()` 精确等于「炮管中心 → 那个世界点」。
##
## `TankBody` 不需要完整蓝图：`_cell_size` 缺省就是 16.0，`centroid_local` 缺省为 0，
## 而 `aim_at()` 只读 `heading` / `position` / `world_position_of_cell()`。
func _check_aim_uses_camera() -> void:
	var body := TankBody.new()
	body.position = CENTRE
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
	for height in [FAR, FAR * 0.5, FAR * 0.25, 700.0]:
		var h := float(height)
		var camera := CombatView.camera_at_height(ARENA, body.position, h)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		## 屏幕上一个明显偏离中心的点（用于区分不同距离的影响）。
		var screen := VIEW.position + Vector2(VIEW.size.x * 0.78, VIEW.size.y * 0.30)
		var world: Vector2 = MainScript._screen_to_world(VIEW, camera, screen, scale_factor)
		## 反向确认：把这个世界点画回屏幕必须回到原屏幕点。
		var back := CombatView.to_screen(VIEW, camera, world, scale_factor)
		_check_near(back.x, screen.x, "aim_screen_back_x_h%.1f" % h)
		_check_near(back.y, screen.y, "aim_screen_back_y_h%.1f" % h)
		## 再让炮管指过去，方向必须等于「炮管中心 → world」。
		var cannon: Dictionary = bank.cannons[0]
		var centre: Vector2 = body.world_position_of_cell(Vector2i(cannon["cell"]))
		var expected := (world - centre).normalized()
		bank.aim_at(0, world)
		var got := bank.muzzle_dir(cannon)
		_check_near(got.x, expected.x, "aim_dir_x_h%.1f" % h)
		_check_near(got.y, expected.y, "aim_dir_y_h%.1f" % h)

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
	## 相机必须来自 `_battle_camera()`（现算）而不是缓存的旧矩形。
	var camera_fn := source.find("func _battle_camera(")
	_check(camera_fn > 0, "aim_wiring_battle_camera_exists")
	if camera_fn > 0:
		var camera_tail := source.substr(camera_fn)
		var camera_end := camera_tail.find("\nfunc ", 1)
		if camera_end > 0:
			camera_tail = camera_tail.substr(0, camera_end)
		_check(camera_tail.contains("camera_at_height("), "aim_wiring_battle_camera_uses_distance")
		_check(camera_tail.contains("arena.size.y"), "aim_wiring_battle_camera_uses_arena_height")

## v3.42：引擎相机的几何断言（**不画图**，只算数）。
##
## `BattleViewport.apply()` 做的是两行换算：`camera.position = 相机中心`、
## `zoom = view宽 / 相机宽`。这两行必须满足：
##  - 相机中心对应的屏幕点是视窗中心；
##  - 相机矩形恰好铺满视窗（宽高都等于 `view.size / zoom`）；
##  - `zoom` 与 `fit_scale()` 逐字相等 —— 鼠标逆变换（解析式）与引擎相机（矩阵式）
##    必须从构造上就是同一个数，否则「画出来的炮管」与「真实开火方向」会分成两套推导。
##
## 判据只用到 `apply()` 之后读回的 `position` / `zoom`，**不引用 `apply()` 内部的中间量**，
## 所以它不会与实现同错（v3.39 假绿的教训）。
func _check_battle_viewport_geometry() -> void:
	var bvp := BattleViewport.new()
	bvp.configure(VIEW, Callable())
	## 探针环境里没有 `main`，`configure()` 只是建节点不挂树 —— `SubViewport` 的
	## canvas 变换在离树状态下不可靠，所以本测试只验证**换算本身**，不渲染。
	var heights: Array = [FAR, FAR * 0.75, FAR * 0.5, FAR * 0.25, 700.0, 400.0]
	for height in heights:
		var h := float(height)
		var camera := CombatView.camera_at_height(ARENA, CENTRE, h)
		var scale_factor := CombatView.fit_scale(VIEW, camera)
		bvp.apply(camera)
		var tag := "h%.3f" % h
		_check_near(bvp.camera.position.x, camera.get_center().x, "bvp_camera_centre_x_" + tag)
		_check_near(bvp.camera.position.y, camera.get_center().y, "bvp_camera_centre_y_" + tag)
		_check_near(bvp.camera.zoom.x, scale_factor, "bvp_zoom_is_fit_scale_x_" + tag)
		_check_near(bvp.camera.zoom.y, scale_factor, "bvp_zoom_is_fit_scale_y_" + tag)
		_check_near(bvp.scale_factor(), scale_factor, "bvp_scale_factor_" + tag)
		_check_near(bvp.pixel(), 1.0 / scale_factor, "bvp_pixel_" + tag)
		## 相机矩形的尺寸折回视窗：必须恰好铺满（既无 letterbox 也无裁切）。
		_check_near(camera.size.x * bvp.camera.zoom.x, VIEW.size.x, "bvp_covers_width_" + tag)
		_check_near(camera.size.y * bvp.camera.zoom.y, VIEW.size.y, "bvp_covers_height_" + tag)
	## 退化输入不得改写相机：未初始化（arena 空）时保持上一次的值。
	## 最后一次有效 apply 是 `h = 400`（本表最小），所以 zoom 应仍是它的 fit_scale。
	var last_camera := CombatView.camera_at_height(ARENA, CENTRE, 400.0)
	bvp.apply(Rect2())
	_check_near(bvp.camera.zoom.x, CombatView.fit_scale(VIEW, last_camera), "bvp_degenerate_keeps_camera")
	bvp.free()

## v3.42：接线断言 —— `_paint_battle_world()` 必须**先 apply 相机再 blit**，
## 且 `_draw_battle_world()` 必须存在。这是 v3.37「两套推导」缺陷的静态防护。
func _check_battle_viewport_wiring() -> void:
	var file := FileAccess.open("res://scripts/main.gd", FileAccess.READ)
	if file == null:
		_fail("bvp_wiring_cannot_open_main")
		return
	var source := file.get_as_text()
	file.close()
	var start := source.find("func _paint_battle_world(")
	if start < 0:
		_fail("bvp_wiring_missing_paint")
		return
	var tail := source.substr(start)
	var next_func := tail.find("\nfunc ", 1)
	if next_func > 0:
		tail = tail.substr(0, next_func)
	var code_lines: Array = []
	for line in tail.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue
		code_lines.append(trimmed)
	var body_code := "\n".join(code_lines)
	_check(body_code.contains(".apply("), "bvp_wiring_applies_camera")
	_check(body_code.contains(".blit("), "bvp_wiring_blits")
	_check(body_code.contains("_battle_camera("), "bvp_wiring_uses_battle_camera")
	## apply 必须出现在 blit 之前（先定相机再取纹理，顺序反了就是用旧相机贴图）。
	_check(body_code.find(".apply(") < body_code.find(".blit("), "bvp_wiring_apply_before_blit")
	_check(source.contains("func _draw_battle_world("), "bvp_wiring_world_painter_exists")
	## 内置反向对照：确认 `.blit(` 这个匹配模式真的有区分力。
	var bad := "_battle_viewport.refresh()"
	_check(not bad.contains(".blit("), "bvp_wiring_negative_control")
