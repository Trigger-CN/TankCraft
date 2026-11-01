extends RefCounted

## 管道模块的几何与绘制（v3.35）。
##
## 用户要求：「在模块上绘制出管道形状，管道模块在拼接组装时，管道要显示完整不要有明显
## 接缝，炮弹在管道中传输可视化」。
##
## **为什么单独一个组件而不是塞进 `CombatView`**：管道要同时服务建造/改装页（那是文档
## 坐标下的网格，不经过 `CombatView` 的竞技场投影）与三个战斗页（车体局部坐标 + 旋转 +
## 缩放），把它放进 `CombatView` 会让那个组件同时知道两套坐标体系。管道几何与战斗特效
## 本来也是两件事。
##
## 约定与 `CombatView` 一致：**全部 `static`、无状态**；绘制函数接 `canvas: CanvasItem`；
## 只 preload `palette.gd`；零 preload 回 `main.gd`（依赖 DAG 保持单向）；
## **禁止 `randf` / `randi`**。
##
## ── 几何的唯一不变量 ──────────────────────────────────────────────────────
## **每个端口都落在某个格子的边中点上。** 端口格由 `AmmoNetwork._port_cell()` 给出，
## 再沿该侧方向偏移半格，就是端口坐标。因为 `_build_links()` 的接线规则是「A.out 与
## B.in 的端口格 4 邻接」，而两个相邻格共享同一条边界，所以两侧的边中点**必然是同一点** ——
## 相邻管道模块的中心线端点在几何上完全重合，**不需要任何吸附或对齐容差**。
##
## 「没有明显接缝」靠三条纪律，而不是靠调数值：
##   1. 端口处不画端帽（没接邻居时才画端帽）；
##   2. 端口处不描边 —— 描边只在模块内部收口，于是相邻两模块不会在接缝处各画一条线；
##   3. 弧管在端口处的**切线垂直于所在格边**，接上直管后中心线与切线都连续，不出现折角。

const Palette := preload("res://scripts/palette.gd")
const AmmoNetwork := preload("res://scripts/ammo_network.gd")

## 管宽 / 格宽。**不用 1.0**：留出边距才看得出「这是一根管」，否则相邻格会糊成整块。
const PIPE_WIDTH_RATIO := 0.52
## 内壁高光相对管宽的比例（表达「空心」）。
const PIPE_BORE_RATIO := 0.42
## 管壁描边的最小屏幕宽度（缩放很小时也要看得见）。
const PIPE_WALL_MIN_PX := 1.0
## 端帽相对管宽的半长（只在未接邻居的端口画）。
const PIPE_CAP_RATIO := 0.5
## 汇流接头的半径比例（三通/四通的臂在格中心汇聚处）。
const PIPE_JOINT_RATIO := 0.5
## 弧线分段数。16 段在 16 px 格、8 倍缩放下仍看不出多边形。
const ARC_SEGMENTS := 16
## 弹药弹头半径（相对格宽）与拖尾长度（相对中心线全长）。
const ROUND_HEAD_RATIO := 0.18
const ROUND_TRAIL_RATIO := 0.16
## 流动纹理：每格几个高光段、速度（rad/s）。相位取 `sin()`，零随机。
const PIPE_FLOW_SPEED := 5.0

## 通道种类：决定中心线形状。
const SHAPE_STRAIGHT := "straight"
const SHAPE_ARC_QUARTER := "arc_quarter"
const SHAPE_ARC_HALF := "arc_half"
const SHAPE_JUNCTION := "junction"

## 模块 id → 通道形状。表以外一律返回空串（不画）。
const SHAPES := {
	"conveyor_straight": SHAPE_STRAIGHT,
	"conveyor_arc_quarter": SHAPE_ARC_QUARTER,
	"conveyor_arc_half": SHAPE_ARC_HALF,
	"conveyor_tee": SHAPE_JUNCTION,
	"conveyor_merge": SHAPE_JUNCTION,
	"conveyor_cross": SHAPE_JUNCTION,
}


## 该模块 id 是否有可绘制的通道几何。
static func has_shape(module_id: String) -> bool:
	return SHAPES.has(module_id)


static func shape_of(module_id: String) -> String:
	return String(SHAPES.get(module_id, ""))


## side → 单位方向（+y 向下，与格坐标一致）。
static func side_vector(side: String) -> Vector2:
	match side:
		"E":
			return Vector2.RIGHT
		"S":
			return Vector2.DOWN
		"W":
			return Vector2.LEFT
	return Vector2.UP


## 端口在世界（或车体局部）坐标里的位置：端口格中心 + 该侧方向 × 半格。
##
## 这就是「无接缝」的几何根据：相邻模块的两个端口格 4 邻接，两格的边中点重合。
static func port_point(cells: Array, side: String, cell: float) -> Vector2:
	var port_cell := AmmoNetwork._port_cell(cells, side)
	var centre := (Vector2(port_cell) + Vector2(0.5, 0.5)) * cell
	return centre + side_vector(side) * (cell * 0.5)


## 某一格的中心。
static func cell_centre(raw_cell: Variant, cell: float) -> Vector2:
	return (Vector2(Vector2i(raw_cell)) + Vector2(0.5, 0.5)) * cell


## 部件占位格的包围盒（格坐标，含右/下边界）。
static func cells_bounds(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var lo := Vector2i(cells[0])
	var hi := Vector2i(cells[0])
	for raw in cells:
		var cell_value := Vector2i(raw)
		lo.x = mini(lo.x, cell_value.x)
		lo.y = mini(lo.y, cell_value.y)
		hi.x = maxi(hi.x, cell_value.x)
		hi.y = maxi(hi.y, cell_value.y)
	return Rect2i(lo, hi - lo + Vector2i.ONE)


## 中心线：按端口顺序给出折线/圆弧采样点。
##
## `ports` 是 `AmmoNetwork.ui_ports()` 的输出（已按 rot 旋转）。返回**有序点列**，
## 从第一个 in 端口走到最后一个 out 端口；汇流类模块返回的是「臂的并集」，
## 由 `junction_arms()` 单独取用，这里只给出主路径（in0 → out0）供通用插值使用。
##
## `offset` 是统一的像素平移：战斗页的变换以车体位姿为原点，而格坐标含质心，
## 所以要减 `-centroid_local`。把它做成参数而不是让调用方改格号——
## 改格号会在非整数质心时发生取整误差，管道就会错位半个像素以上。
static func centre_line(module_id: String, cells: Array, ports: Array, cell: float,
		offset: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	var shape := shape_of(module_id)
	var points := PackedVector2Array()
	if shape.is_empty() or cells.is_empty():
		return points
	match shape:
		SHAPE_STRAIGHT:
			var a := _first_port_point(ports, cells, cell, "in")
			var b := _first_port_point(ports, cells, cell, "out")
			points.append(a)
			points.append(b)
		SHAPE_ARC_QUARTER:
			points = _arc_quarter_points(ports, cells, cell)
		SHAPE_ARC_HALF:
			points = _arc_half_points(ports, cells, cell)
		SHAPE_JUNCTION:
			var a := _first_port_point(ports, cells, cell, "in")
			var b := _first_port_point(ports, cells, cell, "out")
			var hub := _junction_hub(cells, cell)
			points.append(a)
			points.append(hub)
			points.append(b)
	return _shift(points, offset)


## 整组点统一平移（`offset` 为零时原样返回，不产生任何浮点误差）。
static func _shift(points: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	if offset == Vector2.ZERO:
		return points
	var result := PackedVector2Array()
	result.resize(points.size())
	for index in range(points.size()):
		result[index] = points[index] + offset
	return result


## 三通 / 二合一 / 四通的逐臂点列：每条臂都是「端口 → 格中心」的直线。
##
## 这三类有 ≥3 个端口，不存在唯一的一条中心线；「每条臂各自到中心 + 中心画圆角接头」
## 是唯一能保证「任意端口都能与邻居对接、且任意两口之间都连通」的几何。
static func junction_arms(module_id: String, cells: Array, ports: Array, cell: float,
		offset: Vector2 = Vector2.ZERO) -> Array:
	var arms: Array = []
	if shape_of(module_id) != SHAPE_JUNCTION or cells.is_empty():
		return arms
	var hub := _junction_hub(cells, cell)
	for raw in ports:
		var side := String((raw as Dictionary).get("side", ""))
		if side.is_empty():
			continue
		var end := port_point(cells, side, cell)
		arms.append({
			"port": String((raw as Dictionary).get("id", "")),
			"kind": String((raw as Dictionary).get("kind", "")),
			"side": side,
			"points": _shift(PackedVector2Array([hub, end]), offset),
		})
	return arms


## 汇流处的圆角接头中心：单格是格中心；footprint 2 的取占位中心。
static func _junction_hub(cells: Array, cell: float) -> Vector2:
	var bounds := cells_bounds(cells)
	var centre_cell := Vector2(bounds.position) + Vector2(bounds.size) * 0.5
	return centre_cell * cell


static func _first_port_point(ports: Array, cells: Array, cell: float, kind: String) -> Vector2:
	for raw in ports:
		var port: Dictionary = raw
		if String(port.get("kind", "")) == kind:
			return port_point(cells, String(port.get("side", "")), cell)
	## 没有该种类的端口时退回占位中心：宁可画在中间，也不抛错（绘制路径不能中断）。
	return _junction_hub(cells, cell)


## 四分之一弧：N 边中点 → E 边中点，90° 圆角。
##
## **圆心必须在格角（NE 角），不能在格中心。** 这是「首尾相接」的真正几何要求，
## 而不只是「端点重合」：
##
##   - 圆心在格中心时，两端点到圆心的方向分别是「上」与「右」，而端口位置的切线恰好
##     **垂直于管轴** —— 实测 `tangent.dot(侧向) ≈ 1.0`，接上直管后中心线会拐一个 90° 折角，
##     看起来就是「弧管接不上直管」。
##   - 圆心在 NE 格角时，N 边中点到圆心的方向是「左下」、E 边中点是「右下」，两端切线
##     都**沿着**各自格边（N 端口处切线沿 x、E 端口处沿 y），与直管中心线相切。
##
## 半径因此是 `cell * sqrt(0.5)`（格角到边中点的距离），不是半格。
## 端点仍由 `port_point()` 决定，内圆角自然落在格子内部。
static func _arc_quarter_points(ports: Array, cells: Array, cell: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var from_side := _side_of_kind(ports, "in")
	var to_side := _side_of_kind(ports, "out")
	var a := port_point(cells, from_side, cell)
	var b := port_point(cells, to_side, cell)
	var bounds := cells_bounds(cells)
	var centre := _corner_between(Vector2(bounds.position), Vector2(bounds.size),
		side_vector(from_side), side_vector(to_side), cell)
	var radius := a.distance_to(centre)
	var start_angle := (a - centre).angle()
	var end_angle := (b - centre).angle()
	## 取绝对角差较小的那一侧，保证画的是 90° 而不是 270°。
	var delta := wrapf(end_angle - start_angle, -PI, PI)
	for index in range(ARC_SEGMENTS + 1):
		var t := float(index) / float(ARC_SEGMENTS)
		var angle := start_angle + delta * t
		points.append(centre + Vector2(cos(angle), sin(angle)) * radius)
	## 首尾**强制**等于端口点：`atan2 → cos/sin` 的往返会留下 1e-15 量级误差，
	## 而「无接缝」的定义是两个模块的端点**逐字节相同**，弧管不该是例外。
	points[0] = a
	points[points.size() - 1] = b
	return points


## 两个互相垂直的端口方向所夹的那个格角（世界/局部像素坐标）。
##
## `bounds_position` / `bounds_size` 是**格坐标**的包围盒左上角与尺寸；`cell` 换算成像素。
## 例：N 与 E → 右上角；W 与 S → 左下角。
static func _corner_between(bounds_position: Vector2, bounds_size: Vector2,
		dir_a: Vector2, dir_b: Vector2, cell: float) -> Vector2:
	var centre_cell := bounds_position + bounds_size * 0.5
	## 「方向」到格角的转换：x 取 +0.5（东侧）或 -0.5（西侧），y 同理。
	var corner := Vector2(
		centre_cell.x + (bounds_size.x * 0.5 * (1.0 if dir_a.x > 0.0 or dir_b.x > 0.0 else -1.0)),
		centre_cell.y + (bounds_size.y * 0.5 * (1.0 if dir_a.y > 0.0 or dir_b.y > 0.0 else -1.0)))
	return corner * cell


## 二分之一弧（180° 换向，footprint 2）。
##
## ── 先说清一个几何事实（v3.39 真正的教训）────────────────────────────
## footprint 2 的占位是两格首尾相接的一条直线，接缝在中间。`CONVEYOR_PORTS` 给它的端口
## 是 `in0 @ W`、`out0 @ E` —— **两个端口在同一条直线上、方向相反**。
##
## 在这种端口布局下，「两端切线都沿管轴」与「中间是一段圆弧」**不可兼得**：
##   - 若用 180° 半圆（圆心=接缝、半径=一格），两端点正好是 A/B，但那里的切线
##     **垂直于轴** —— 接上直管就是一个 90° 折角。
##   - 若用「直段 + 半圆 + 直段」，半圆两端切线仍与轴平行，直段长度必须为 0 才能落在端口，
##     于是又退回上一种情形。
##
## 所以这个模块的形状只能是**正交台阶 + 圆角**（这也是「换向 180°」在格子约束下的标准画法）：
##
##     A ══════╗                      ← 沿轴直走半格
##              ║                      ← 垂直横移一格（lift 侧）
##              ╙──────╮               ← 转角画圆弧过渡
##                     ║              ← 再垂直横移回来
##                     ╙══════════ B   ← 沿轴直走半格到端口
##
## 三段保证：首尾**逐字节**等于 `port_point()`；首尾切线**沿轴**（接上直管完全相切）；
## 整个形状留在两格占位内（横移距离 = 一格）。
##
## 弧只出现在**两个转角**上（半径 = ¼ 格），不是整条中心线都是弧。
##
## ── v3.39 修掉的真缺陷（用户实机发现：「弯曲的管道绘制有些问题，没法和其他管子对齐，
##    首尾相接」）──────────────────────────────────────────
##   ① 半径写死为 `cell * 0.5` 且以接缝为圆心**直接从端口起弧** —— 两端各缩回半格
##      （16 px 格下就是 8 px），管子比端口短一截，**任何相邻模块都接不上**。
##   ② 即使把半径改对，两个端口的半径向量共线反向，`wrapf` 归零 ⇒ 弧退化成直线。
##   ③ 探针盲区：v3.35 的 `pipe_geometry_smoke` 只比对「两个 `port_point()` 相等」
##      （两边都走同一个函数，恒等），且把同样的 `CELL * 0.5` 写进了测试自己的半径假设，
##      所以三个问题叠加了整整四个版本全绿也无人发现（**测试与实现共谋**）。
static func _arc_half_points(ports: Array, cells: Array, cell: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var from_side := _side_of_kind(ports, "in")
	var to_side := _side_of_kind(ports, "out")
	var a := port_point(cells, from_side, cell)
	var b := port_point(cells, to_side, cell)
	var bounds := cells_bounds(cells)
	## 管轴方向：从 a 指向 b（两格占位就是一条直线）。
	var axis := (b - a)
	if axis.length_squared() <= 0.000001:
		return PackedVector2Array([a, b])
	axis = axis.normalized()
	## 垂直于轴的方向：**按端口朝向确定「向内」是哪一侧**。
	## 不能靠点积判正反（`lift` 与轴恒垂直，点积恒为 0）。
	## W/E 轴（水平管）向内是 +y（下方），N/S 轴（竖直管）向内是 +x（右方）——
	## 因为 `bounds_centre - a` 在这两种情形下分别是 +x / +y，均与「向内」的那个候选垂直。
	var lift := Vector2(-axis.y, axis.x)
	if from_side == "W" or from_side == "E":
		if lift.y < 0.0:
			lift = -lift
	else:
		if lift.x < 0.0:
			lift = -lift
	## 横向偏移量：**用短边（厚度）**，不用长边。
	## 两格模块的长边是 2 格（32 px），短边是 1 格（16 px）；端口在短边中点，
	## 到占位边界只有半格（8 px），所以鼓幅上限是 8，而不是 16。
	var thickness := float(mini(bounds.size.x, bounds.size.y)) * cell
	var offset := thickness * 0.5
	## ── 中心线：`bulge = +offset * sin²(πt)`，t∈[0,1] ──────────────
	##
	## 为什么用这个函数而不是「半圆」或「直段+圆角」：
	##   - 两端 t=0/1 处 `d(bulge)/dt = offset·2·sin(πt)·cos(πt)·π = 0` ⇒ **切线精确沿轴**，
	##     接上直管完全相切，不会出现 90° 折角。这就是用户说的「接不上」的直接病根。
	##   - 中间 t=0.5 处偏移 = offset，形成明确的弧形；两格占位的厚度只有一格，
	##     所以鼓幅取半格，既看得出弧又不越界（16 px 格下 offset=8）。
	##   - 解析光滑、零随机、零时间依赖，任意朝向都只需旋转同一个公式。
	## 弧长参数由 `point_at()` 统一处理，弹药仍然沿真实中心线走。
	var steps := ARC_SEGMENTS * 2
	var length := a.distance_to(b)
	for index in range(steps + 1):
		var t := float(index) / float(steps)
		var bulge := offset * pow(sin(PI * t), 2.0)
		points.append(a + axis * (length * t) + lift * bulge)
	## 首尾强制等于端口点（`sin(0)=sin(π)=0` 已保证数值上成立，这里再钉一次）。
	points[0] = a
	points[points.size() - 1] = b
	return points


static func _side_of_kind(ports: Array, kind: String) -> String:
	for raw in ports:
		var port: Dictionary = raw
		if String(port.get("kind", "")) == kind:
			return String(port.get("side", ""))
	return "W" if kind == "in" else "E"


## 按弧长在中心线上取点。`t` 会被 clamp 到 [0, 1]。
##
## 这是弹药可视化的核心：**必须沿真实中心线走弧长**。旧实现用「首格中心 → 末格中心」
## 的直线插值，对弧管来说那条直线穿过格子的角落之外，圆点会飘出管子。
static func point_at(points: PackedVector2Array, t: float) -> Vector2:
	if points.is_empty():
		return Vector2.ZERO
	if points.size() == 1:
		return points[0]
	var clamped := clampf(t, 0.0, 1.0)
	var total := 0.0
	for index in range(points.size() - 1):
		total += points[index].distance_to(points[index + 1])
	if total <= 0.0001:
		return points[points.size() - 1]
	var want := total * clamped
	var walked := 0.0
	for index in range(points.size() - 1):
		var segment := points[index].distance_to(points[index + 1])
		if segment <= 0.0001:
			continue
		if walked + segment >= want:
			var local := (want - walked) / segment
			return points[index].lerp(points[index + 1], local)
		walked += segment
	return points[points.size() - 1]


## 绘制一个部件占位上的管道。
##
## `cells` 世界/局部格坐标列表；`ports` = `AmmoNetwork.ui_ports()`；`cell` 一格边长；
## `scale_factor` 只用于把线宽换算成「屏幕上至少 1 px」；`connected` 是
## `{side: true}` —— 哪些端口侧接了邻居，未接的那一侧才画端帽。
## `flow_phase` 由调用方用 `sin(_time * …)` 算好传入，本函数不读时间（便于截图复现）。
static func draw_pipe(canvas: CanvasItem, module_id: String, cells: Array, ports: Array, cell: float,
		colour: Color, alpha: float, scale_factor: float, connected: Dictionary = {},
		flow_phase: float = 0.0, offset: Vector2 = Vector2.ZERO) -> void:
	var shape := shape_of(module_id)
	if shape.is_empty() or cells.is_empty():
		return
	var width := cell * PIPE_WIDTH_RATIO
	var wall := maxf(PIPE_WALL_MIN_PX / maxf(scale_factor, 0.0001), width * 0.16)
	if shape == SHAPE_JUNCTION:
		var arms := junction_arms(module_id, cells, ports, cell, offset)
		for raw in arms:
			var arm: Dictionary = raw
			_stroke_band(canvas, arm["points"], width, colour, alpha, wall)
		## 汇流接头：把各臂在内端的折角盖住。
		var hub := _junction_hub(cells, cell) + offset
		canvas.draw_circle(hub, width * PIPE_JOINT_RATIO, Color(colour, alpha * 0.30))
		canvas.draw_arc(hub, width * PIPE_JOINT_RATIO, 0.0, TAU, 16, Color(colour, alpha * 0.85), wall)
		return
	var points := centre_line(module_id, cells, ports, cell, offset)
	if points.size() < 2:
		return
	_stroke_band(canvas, points, width, colour, alpha, wall)
	## 流动高光：沿中心线的一段短线，位置由 `flow_phase`（调用方给的 0..1）决定。
	if flow_phase > 0.0:
		var head := point_at(points, flow_phase)
		var tail := point_at(points, maxf(flow_phase - 0.22, 0.0))
		canvas.draw_line(tail, head, Color(colour, alpha * 0.55), width * PIPE_BORE_RATIO)
	## 端帽：只在没有邻居的端口画，表示「这里断了」。
	for raw in ports:
		var port: Dictionary = raw
		var side := String(port.get("side", ""))
		if bool(connected.get(side, false)):
			continue
		var end := port_point(cells, side, cell) + offset
		var outward := side_vector(side)
		var across := Vector2(-outward.y, outward.x)
		canvas.draw_line(end - across * (width * PIPE_CAP_RATIO), end + across * (width * PIPE_CAP_RATIO),
			Color(colour, alpha), wall * 1.2)


## 沿点列画一条「管」：外壁描边 + 管身填充 + 内壁高光。
##
## 用**折线段近似描边**而不是 `draw_polyline` 的单线：单线看不出管径，
## 而管径正是「这是管道」的主要视觉线索。
static func _stroke_band(canvas: CanvasItem, points: PackedVector2Array, width: float, colour: Color,
		alpha: float, wall: float) -> void:
	if points.size() < 2:
		return
	var half := width * 0.5
	## 管身：沿中心线逐段画粗线（round cap 自动把转角圆滑掉）。
	for index in range(points.size() - 1):
		canvas.draw_line(points[index], points[index + 1], Color(colour, alpha * 0.20), width)
	## 两侧管壁：把中心线逐点沿法线偏移半管宽，得到两条折线。
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for index in range(points.size()):
		var normal := _normal_at(points, index)
		left.append(points[index] + normal * half)
		right.append(points[index] - normal * half)
	canvas.draw_polyline(left, Color(colour, alpha * 0.85), wall)
	canvas.draw_polyline(right, Color(colour, alpha * 0.85), wall)
	canvas.draw_polyline(points, Color(colour, alpha * 0.42), width * PIPE_BORE_RATIO)


## 第 `index` 个点处的单位法线（取相邻两段方向的平均，转角处才不出现尖刺）。
static func _normal_at(points: PackedVector2Array, index: int) -> Vector2:
	var direction := Vector2.RIGHT
	if index + 1 < points.size():
		direction = points[index + 1] - points[index]
	elif index > 0:
		direction = points[index] - points[index - 1]
	if direction.length_squared() <= 0.000001:
		direction = Vector2.RIGHT
	direction = direction.normalized()
	return Vector2(-direction.y, direction.x)


## 判定哪些端口侧接了邻居：同侧相邻格里存在**方向相反**的端口。
##
## 判据与 `AmmoNetwork._build_links()` 完全同源（A.out 与 B.in 端口格 4 邻接且互为正反），
## 但这里只关心「有没有接上」用于决定是否画端帽，因此不区分 in/out。
## `occupied` 是 `{cell: {side: true, …}}`（由调用方按全部端口建好）。
static func connected_sides(cells: Array, ports: Array, occupied: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for raw in ports:
		var port: Dictionary = raw
		var side := String(port.get("side", ""))
		var port_cell := AmmoNetwork._port_cell(cells, side)
		var neighbour: Vector2i = port_cell + AmmoNetwork.SIDE_VECTORS.get(side, Vector2i.ZERO)
		var sides_here: Dictionary = occupied.get(neighbour, {})
		var wanted := AmmoNetwork._opposite(side)
		if bool(sides_here.get(wanted, false)):
			result[side] = true
	return result


## 把一辆车（或其占位集合）的全部端口登记成 `{cell: {side: true}}`。
## `entries` 每项需含 `cells` 与 `ports`。
static func occupancy(entries: Array) -> Dictionary:
	var result: Dictionary = {}
	for raw in entries:
		var entry: Dictionary = raw
		var cells: Array = entry.get("cells", [])
		for raw_port in (entry.get("ports", []) as Array):
			var side := String((raw_port as Dictionary).get("side", ""))
			if side.is_empty() or cells.is_empty():
				continue
			var port_cell := AmmoNetwork._port_cell(cells, side)
			var bucket: Dictionary = result.get(port_cell, {})
			bucket[side] = true
			result[port_cell] = bucket
	return result


## ── 弹药在管内的行进路径 ──────────────────────────────────────────────

## 一发弹药在某一段管路里走的那条路径（世界/车体局部坐标点列）。
##
##   - **三通 / 二合一 / 四通**：路径 = 「入口臂 → 格中心 → 出口臂」。
##     入口臂用 `entry_port`（这一发实际从那条 in 进来的），没有就取该类别的第一个；
##     出口臂用 `exit_port`（`_chosen_exit_port()` 给的**路由首选**出口）。
##
## **`exit_port` 为空串时只画到格中心**（只在极罕情况下发生：该模块所有 out 都没接线）。
## 正常情况下 `exit_port` 总是非空 —— 因为「走哪条臂」由 `_out_order()` 与拓扑决定，
## 与「现在收不收得下」是两件事（后者作为 `exit_blocked` 单独报，用于变红）。
##
## **两个端口都是领域层算好传进来的**，不是这里猜的。
static func round_path(module_id: String, cells: Array, ports: Array, cell: float,
		entry_port: String, exit_port: String, offset: Vector2 = Vector2.ZERO) -> PackedVector2Array:
	if shape_of(module_id) != SHAPE_JUNCTION:
		return centre_line(module_id, cells, ports, cell, offset)
	var points := PackedVector2Array()
	var inbound := _arm_end(ports, cells, cell, entry_port, "in") + offset
	var hub := _junction_hub(cells, cell) + offset
	points.append(inbound)
	points.append(hub)
	if not exit_port.is_empty():
		points.append(_arm_end(ports, cells, cell, exit_port, "out") + offset)
	return points

## 取某条臂的外端坐标：优先 `wanted_id`，否则回退到该种类的第一个端口。
static func _arm_end(ports: Array, cells: Array, cell: float, wanted_id: String, kind: String) -> Vector2:
	if not wanted_id.is_empty():
		for raw in ports:
			var port: Dictionary = raw
			if String(port.get("id", "")) == wanted_id:
				return port_point(cells, String(port.get("side", "")), cell)
	return _first_port_point(ports, cells, cell, kind)

## 在 `path` 上按 `t` 画一发弹药：实心弹头 + 拖尾。
##
## `t` 是**弧长参数**（`point_at()` 结算），所以弧管上的弹头真的沿着弧走。
## 拖尾取 [t - ROUND_TRAIL_RATIO, t] 的一段，逐段渐隐；颜色已由调用方选定。
static func draw_round(canvas: CanvasItem, path: PackedVector2Array, cell: float, t: float,
		colour: Color, alpha: float, scale_factor: float) -> void:
	if path.size() < 2:
		return
	var head := point_at(path, t)
	var tail_t := maxf(t - ROUND_TRAIL_RATIO, 0.0)
	var tail := point_at(path, tail_t)
	var thickness := cell * ROUND_HEAD_RATIO * 0.9
	canvas.draw_line(tail, head, Color(colour, alpha * 0.45), thickness)
	var radius := cell * ROUND_HEAD_RATIO
	canvas.draw_circle(head, radius, Color(colour, alpha))
	canvas.draw_arc(head, radius, 0.0, TAU, 14, Color(colour, alpha * 0.75),
		maxf(1.0 / maxf(scale_factor, 0.0001), 1.0))
