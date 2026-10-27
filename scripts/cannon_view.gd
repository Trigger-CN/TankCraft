extends RefCounted

## 炮管模块的几何与绘制（v3.37）。
##
## 用户要求：「炮管模组要绘制出炮管并实时指向所瞄准的地方」。拆成两件事：
##   ① 炮管不再和普通模块一样只画一个方块，而是画出**基座 + 管身 + 炮口**，让人一眼看出这是一门炮；
##   ② 形态方向必须跟随**当前瞄准方向**实时变化，而不是停在建造期定下的固定角度。
##
## 约定与 `CombatView` / `PipeView` 一致：全部 `static`、无状态；绘制函数接 `canvas: CanvasItem`；
## 只 preload `palette.gd`；零 preload 回 `main.gd`（依赖 DAG 保持单向）；
## **禁止 `randf` / `randi`**，不读时间 —— 截图冻结后同参数连拍逐字节相同。
##
## 坐标系与 `PipeView.draw_pipe()` 完全相同：`cells` 是**格坐标**，`cell` 是一格边长，
## 几何全部按「格坐标 × cell」算，最后一步才统一加 `offset`。于是建造/改装页传
## `offset = GRID_ORIGIN`、战斗页传 `offset = -centroid_local + part_offset`，两边共用一份几何。
##
## ── 三条几何不变量 ───────────────────────────────────────────────────────────
## 1. **转轴 = 首格中心。** `CannonBank.muzzle_origin()` 的实现就是
##    「首格中心 + 方向 × 半格」，说明仿真认为炮弹从首格中心射出；绘制必须以同一处为转轴，
##    否则按 `muzzle_origin()` 定位的炮口闪光会与炮管错开。
## 2. **炮口制退器必须跨过 `0.5 × cell`。** 那正是 `muzzle_origin()` 的距离：制退器把半格点
##    包在内部，闪光锥顶就落在炮口里侧，「从炮口喷出来」这件事才成立。
##    所以 `BRAKE_START_RATIO < 0.5 < BRAKE_END_RATIO`，**所有口径共用同一管长** ——
##    口径差异只体现在管径上。刻意不用「大口径 = 更长」：管长一变，固定在半格处的
##    炮口闪光就会跑到管子中段去，那比「管子看起来短」明显得多。
## 3. **管身必须明显细长。** 这是「像一门炮」与「像一根棒棒糖」的分界线：
##    管身长 `(BRAKE_START_RATIO - BODY_START_RATIO) ≈ 0.39 cell`，
##    而全宽只有 `2 × BORE_HALF_RATIO = 0.15 cell`，长细比约 **3.6**（含制退器的总长比约 4.9）。
##    实测把长细比压到 2 附近时，画面会被读成「一个疙瘩加一根棍」。
##
## 战斗页一格只有约 9.5 屏幕像素（生存页 16 px 格 × 0.594），纯比例算出来的管口离中心
## 不到 6 屏幕像素，看上去仍是一个点。所以管长与管径各有一条**屏幕下限**
## （`MIN_MOUTH_SCREEN` / `BORE_MIN_SCREEN_HALF`）—— 两个下限只保证「看得见」，
## 且只沿方向拉伸，不放大管宽与座圈，避免小尺寸下退化成一颗大疙瘩。

const Palette := preload("res://scripts/palette.gd")

## 炮塔座圈半径（相对格宽）。小圆台 = 「这门炮能自由转向」；方框表述不了，大圆会盖住管身。
const BASE_RATIO := 0.145
## 管身起点（相对首格中心、沿瞄准方向的格宽倍数）。从中心略外开始，座圈把根部盖住。
const BODY_START_RATIO := 0.02
## 炮口制退器起点。必须 `< 0.5`：半格点要落在制退器内部。
const BRAKE_START_RATIO := 0.46
## 炮口制退器末端。必须 `> 0.5`：`CannonBank.muzzle_origin()` 落在半格处。
const BRAKE_END_RATIO := 0.64
## 管口到首格中心的**最小屏幕像素**。战斗页缩放极小时靠它把炮管拉到可辨认的长度。
## 上限受「不能伸进隔壁格」约束：生存页一格只有 9.5 屏幕像素，而 `BRAKE_END_RATIO`
## 本身就是 0.64 格，所以补偿系数必须接近 1；设大了炮管会顶穿相邻模块。
const MIN_MOUTH_SCREEN := 9.0
## 炮口制退器相对管身半宽的放大倍数（「炮口粗一圈」，形成明显阶梯）。
const BRAKE_GAIN := 1.6
## 管身半宽（相对格宽）：1 格件细、2 格件粗。这是口径差异的唯一视觉表达。
## 重管不得越过 0.070：长细比降到 3 以下后，画面会被读成「一个疙瘩 + 一根棍」。
const BORE_HALF_RATIO := 0.060
const HEAVY_BORE_HALF_RATIO := 0.070
## 管身半宽的**屏幕**上下限。下限保证小缩放下看得见；上限防止尺寸补偿后变成一根粗棍 ——
## 不设上限时，战斗页（一格 9.5 屏幕像素）的管宽会追上一整格，读成「一块板」而不是「一根管」。
const BORE_MIN_SCREEN_HALF := 1.5
const BORE_MAX_SCREEN_HALF := 2.6
## 内膛（暗缝）半宽相对管身半宽的比例。**用暗色而不是亮色**：亮色线压在琥珀管身上会变成
## 一条米色带，读起来像木棍；暗缝才读得出「这是一根中空的管子」。
const BORE_SLIT_RATIO := 0.42
## 描边最小屏幕宽度。
const WALL_MIN_PX := 1.0
## 座圈圆周的折线段数。
const RING_SEGMENTS := 20
## 被炮管压住的格只留的极淡格底。与管道那套一致：方块会把炮管整个盖住，
## 但完全不留底又会让「这个部件占了几格」在非选中层降 alpha 时彻底看不出来。
const CELL_BASE_ALPHA := 0.05
## 各段的不透明度。管身是**实体**，填充必须够实，否则在深色甲板上读不出管形；
## 座圈是底座，比管身淡一档；制退器最亮，它是「炮口在哪」的落点。
const BODY_FILL_ALPHA := 0.55
const BODY_EDGE_ALPHA := 0.95
const BASE_FILL_ALPHA := 0.32
const BASE_EDGE_ALPHA := 0.88
const BRAKE_FILL_ALPHA := 0.68
const BRAKE_EDGE_ALPHA := 0.95
const SLIT_ALPHA := 0.62

## 判定「这是炮管」。**唯一判据是 `aim_steps`**，与 `CannonBank.reload_from_body()` 同源；
## 不能用 `caliber`（弹药制造装置也有 `caliber` 但不是炮管），也不能只按 id 前缀，
## 否则「能开火的炮」与「画出炮管的炮」迟早会对不上。
static func is_cannon(definition: Dictionary) -> bool:
	return definition.has("aim_steps")

## 管口（炮口制退器末端）到首格中心的距离，单位像素。建造页把瞄准线起点移到这里。
## `scale_factor` 必须与 `draw_cannon()` 传入的值一致，否则瞄准线起点会与炮口错开。
static func mouth_offset(cell: float, scale_factor: float = 1.0) -> float:
	return cell * BRAKE_END_RATIO * _stretch(cell, scale_factor)

## 小尺寸下的长度补偿系数：把管口拉长到至少 `MIN_MOUTH_SCREEN` 屏幕像素。
## `>= 1.0`，所以建造页（32 px 格、scale 1）永远是 1.0 —— 像素与设计值完全一致。
static func _stretch(cell: float, scale_factor: float) -> float:
	var screen_mouth := maxf(cell * BRAKE_END_RATIO * maxf(scale_factor, 0.0001), 0.001)
	return maxf(1.0, MIN_MOUTH_SCREEN / screen_mouth)

## 画一门炮。
##
## `cells` 是该炮全部格的**格坐标**（`hull.parts[i]["cells"]` / `_editor_model().part_cells(part)`）；
## `aim_local` 是 `offset` 所在坐标系下的瞄准角 —— **调用方负责把世界角换算成局部角**
## （战斗页必须减 `hull.heading`），这里只做纯几何，不碰朝向定义。
## 「是否重管」的判据是 `cells.size() > 1`：这是**布局事实**，不从 footprint / 口径反推。
static func draw_cannon(canvas: CanvasItem, cells: Array, aim_local: float, cell: float,
		colour: Color, alpha: float, scale_factor: float, offset: Vector2 = Vector2.ZERO) -> void:
	if cell <= 0.0 or alpha <= 0.0 or cells.is_empty():
		return
	var scale_guard := maxf(scale_factor, 0.0001)
	## ① 格底：极淡，只表达占位。**不描边** —— 方框会横跨在管身上，把管切断。
	for raw_cell in cells:
		var base_centre: Vector2 = (Vector2(Vector2i(raw_cell)) + Vector2(0.5, 0.5)) * cell + offset
		canvas.draw_rect(Rect2(base_centre - Vector2(cell, cell) * 0.5, Vector2(cell, cell)),
			Color(colour, CELL_BASE_ALPHA * alpha), true)
	var pivot: Vector2 = (Vector2(Vector2i(cells[0])) + Vector2(0.5, 0.5)) * cell + offset
	var wall := maxf(WALL_MIN_PX / scale_guard, cell * 0.02)
	var heavy := cells.size() > 1
	var half := clampf(cell * (HEAVY_BORE_HALF_RATIO if heavy else BORE_HALF_RATIO),
		BORE_MIN_SCREEN_HALF / scale_guard, BORE_MAX_SCREEN_HALF / scale_guard)
	## 长度补偿只作用在**沿方向的距离**上，不影响管宽与座圈半径 ——
	## 否则小尺寸下会变成一颗大疙瘩而不是一根管子。
	var reach := _stretch(cell, scale_factor)
	var dir := Vector2.RIGHT.rotated(aim_local)
	var side := dir.orthogonal()
	var body_from := cell * BODY_START_RATIO * reach
	var body_to := cell * BRAKE_START_RATIO * reach
	var mouth := cell * BRAKE_END_RATIO * reach
	## ② 管身：先画它，让座圈把根部接缝盖住。
	_band(canvas, pivot, dir, side, body_from, body_to, half,
		Color(colour, BODY_FILL_ALPHA * alpha), Color(colour, BODY_EDGE_ALPHA * alpha), wall)
	## ③ 内膛暗缝：贯穿管身到炮口，表达「中空的管子」。
	_band(canvas, pivot, dir, side, body_from, mouth, half * BORE_SLIT_RATIO,
		Color(Palette.BG_BASE, SLIT_ALPHA * alpha), Color(Palette.BG_BASE, SLIT_ALPHA * alpha), wall * 0.5)
	## ④ 炮口制退器：比管身宽一圈的短粗段，跨过半格。用近白描边，任何部件主色下都能分辨。
	_band(canvas, pivot, dir, side, body_to, mouth, half * BRAKE_GAIN,
		Color(Palette.ACCENT_AMBER, BRAKE_FILL_ALPHA * alpha),
		Color(Palette.TEXT_HI, BRAKE_EDGE_ALPHA * alpha), wall)
	## ⑤ 炮塔座圈：最后画，把管身根部的接缝盖住，形成「管子架在小转台上」的层次。
	canvas.draw_circle(pivot, cell * BASE_RATIO, Color(colour, BASE_FILL_ALPHA * alpha))
	canvas.draw_arc(pivot, cell * BASE_RATIO, 0.0, TAU, RING_SEGMENTS,
		Color(colour, BASE_EDGE_ALPHA * alpha), wall)

## 沿 `dir` 画一段以 `pivot` 为原点、从 `from` 到 `to`（像素距离）的矩形管段：
## 半宽 `half`，填充 `fill`、描边 `edge`。
static func _band(canvas: CanvasItem, pivot: Vector2, dir: Vector2, side: Vector2,
		from: float, to: float, half: float, fill: Color, edge: Color, wall: float) -> void:
	var a := pivot + dir * from
	var b := pivot + dir * to
	var quad := PackedVector2Array([
		a - side * half,
		b - side * half,
		b + side * half,
		a + side * half,
		a - side * half,
	])
	canvas.draw_colored_polygon(quad, fill)
	canvas.draw_polyline(quad, edge, wall)
